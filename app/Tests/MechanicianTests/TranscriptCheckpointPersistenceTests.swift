import Darwin
import Foundation
import XCTest
@testable import Mechanician

private final class TranscriptCheckpointCommitGate: @unchecked Sendable {
    private let lock = NSLock()
    private var hasBlocked = false
    private let entered = DispatchSemaphore(value: 0)
    private let release = DispatchSemaphore(value: 0)

    func blockFirstCommit() {
        lock.lock()
        let shouldBlock = !hasBlocked
        hasBlocked = true
        lock.unlock()
        guard shouldBlock else { return }
        entered.signal()
        release.wait()
    }

    func waitUntilEntered(timeout: TimeInterval = 2) -> Bool {
        entered.wait(timeout: .now() + timeout) == .success
    }

    func allowCommit() { release.signal() }
}

@MainActor
final class TranscriptCheckpointPersistenceTests: XCTestCase {
    private struct Fixture {
        let root: URL
        let store: ConversationStore
        let conversation: Conversation
    }

    private struct SQLiteFixture {
        let root: URL
        let repository: LibraryAuthorityRepository
        let store: ConversationStore
        let first: Conversation
        let second: Conversation
    }

    func testBackgroundLiveBurstPersistsAtOneFixedCheckpoint() async throws {
        let fixture = makeFixture(checkpointLatency: 0.02)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let baselineWrites = fixture.store.completedDiskWrites

        for index in 0..<100 {
            fixture.store.updateLive(fixture.conversation.id) { conversation in
                if conversation.messages.count == 1 {
                    conversation.messages.append(
                        TranscriptEntry(kind: .assistant, text: "chunk-\(index)"))
                } else {
                    conversation.messages[1].text += " chunk-\(index)"
                }
            }
        }

        try await waitUntil("the fixed live checkpoint reaches disk") {
            fixture.store.flushSaves()
            return fixture.store.completedDiskWrites == baselineWrites + 1
                && self.persistedConversation(fixture)?.messages.last?.text
                    .hasSuffix("chunk-99") == true
        }
        XCTAssertEqual(
            fixture.store.completedDiskWrites,
            baselineWrites + 1,
            "a token burst must stage one bounded checkpoint, not one full write per mutation")
        XCTAssertEqual(
            fixture.store.saveCaptureOrdinalScanCount,
            1,
            "checkpointing a seeded live record must preserve chronology without a MainActor scan")
    }

    func testContinuousStreamCannotSlideCheckpointDeadline() async throws {
        let fixture = makeFixture(checkpointLatency: 0.06)
        defer {
            fixture.store.prepareForTermination()
            fixture.store.flushSaves()
            try? FileManager.default.removeItem(at: fixture.root)
        }
        let baselineWrites = fixture.store.completedDiskWrites
        fixture.store.updateLive(fixture.conversation.id) {
            $0.messages.append(TranscriptEntry(kind: .assistant, text: "start"))
        }

        var checkpointLandedWhileMutationsContinued = false
        for index in 0..<6 {
            try await Task.sleep(nanoseconds: 20_000_000)
            fixture.store.updateLive(fixture.conversation.id) {
                $0.messages[$0.messages.count - 1].text += " \(index)"
            }
            // Let the authority lane finish a checkpoint whose fixed deadline became ready on the
            // main queue. A reset-on-every-token debounce would not write until this loop stops.
            try await Task.sleep(nanoseconds: 5_000_000)
            if fixture.store.completedDiskWrites > baselineWrites {
                checkpointLandedWhileMutationsContinued = true
            }
        }

        XCTAssertTrue(
            checkpointLandedWhileMutationsContinued,
            "continuous token arrival must not postpone recovery indefinitely")
    }

    func testForegroundBufferedAssistantPersistsBeforeTerminalAndFinalFoldReusesRow() async throws {
        let fixture = makeFixture(checkpointLatency: 0.02)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let bridge = AgentBridge(
            settingsBaseOverride: fixture.root.appendingPathComponent("settings"),
            environmentOverride: [:],
            conversationStoreOverride: fixture.store)
        bridge.currentID = fixture.conversation.id
        bridge.cwd = fixture.conversation.cwd
        bridge.entries = fixture.conversation.messages
        defer {
            bridge.currentID = nil
            bridge.shutdown()
            fixture.store.flushSaves()
        }

        bridge.bufferAssistantTextForTesting("partial ")
        bridge.bufferAssistantTextForTesting("answer")

        try await waitUntil("the foreground partial assistant reaches disk") {
            fixture.store.flushSaves()
            let assistants = self.persistedConversation(fixture)?.messages.filter {
                $0.kind == .assistant
            }
            return assistants?.map(\.text) == ["partial answer"]
        }
        let checkpointedAssistantID = try XCTUnwrap(
            persistedConversation(fixture)?.messages.first { $0.kind == .assistant }?.id)

        bridge.bufferAssistantTextForTesting(" final")
        bridge.flushAssistantTextForTesting()
        let finalPublished = expectation(description: "final foreground snapshot published")
        bridge.persistCurrentForStopRecoveryTesting { succeeded in
            XCTAssertTrue(succeeded)
            finalPublished.fulfill()
        }
        await fulfillment(of: [finalPublished], timeout: 2)
        fixture.store.flushSaves()

        let assistants = try XCTUnwrap(persistedConversation(fixture)).messages.filter {
            $0.kind == .assistant
        }
        XCTAssertEqual(assistants.map(\.text), ["partial answer final"])
        XCTAssertEqual(
            assistants.first?.id,
            checkpointedAssistantID,
            "the terminal fold must retain the checkpointed open row's identity")
        XCTAssertEqual(
            Set(assistants.map(\.id)).count,
            1,
            "the terminal fold must update the checkpointed open row, not append a duplicate")
    }

    func testTerminationCheckpointReconcilesEveryBackgroundConversation() throws {
        let fixture = makeFixture(checkpointLatency: 3_600)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let second = Conversation(
            title: "Second background turn",
            cwd: "/tmp",
            sdkSessionId: nil,
            messages: [TranscriptEntry(kind: .user, text: "second prompt")],
            updatedAt: Date())
        fixture.store.upsert(second)
        fixture.store.flushSaves()

        fixture.store.updateLive(fixture.conversation.id) {
            $0.messages.append(TranscriptEntry(kind: .assistant, text: "first partial"))
        }
        fixture.store.updateLive(second.id) {
            $0.messages.append(TranscriptEntry(kind: .assistant, text: "second partial"))
        }

        fixture.store.prepareForTermination()
        fixture.store.flushSaves()

        let relaunched = ConversationStore(
            appSupportBaseOverride: fixture.root,
            watchesDirectory: false,
            liveCheckpointMaximumLatency: 3_600)
        XCTAssertEqual(
            relaunched.conversation(fixture.conversation.id)?.messages.last?.text,
            "first partial")
        XCTAssertEqual(relaunched.conversation(second.id)?.messages.last?.text, "second partial")
    }

    func testBridgePrepareForTerminationStopsOwnedBackgroundWorkDurably() throws {
        let fixture = makeFixture(checkpointLatency: 3_600)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let turnID = "background-turn-at-quit"
        let selection = ModelSelection(
            access: .codexSubscription,
            modelID: "gpt-checkpoint-fixture")
        var child = SubagentRun(
            key: "background-child",
            subagentType: "Explore",
            task: "keep running until quit")
        child.taskId = "background-child-task"
        var tool = TranscriptEntry(kind: .tool, text: "Bash")
        tool.toolName = "Bash"
        tool.toolUseId = "unfinished-tool"
        tool.toolState = .running
        fixture.store.update(fixture.conversation.id) { conversation in
            conversation.modelSelection = selection
            conversation.subagents[child.key] = child
            conversation.messages.append(tool)
        }
        fixture.store.flushSaves()
        let bridge = AgentBridge(
            settingsBaseOverride: fixture.root.appendingPathComponent("quit-settings"),
            environmentOverride: [:],
            conversationStoreOverride: fixture.store)
        defer {
            bridge.currentID = nil
            bridge.shutdown()
            fixture.store.flushSaves()
        }
        bridge.stageRootWorkForTesting(
            conversationID: fixture.conversation.id,
            turnID: turnID,
            selection: selection)

        bridge.prepareForTermination()
        fixture.store.flushSaves()

        let persisted = try XCTUnwrap(persistedConversation(fixture))
        XCTAssertEqual(persisted.subagents[child.key]?.status, .stopped)
        XCTAssertEqual(
            persisted.messages.first { $0.toolUseId == tool.toolUseId }?.resolvedToolState,
            .stopped,
            "Cmd-Q must not relaunch into a phantom running tool card")
    }

    func testMutationDuringInFlightCheckpointPublishesNewerGeneration() async throws {
        let fixture = makeFixture(checkpointLatency: 3_600)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let baselineWrites = fixture.store.completedDiskWrites
        let firstWriteEntered = expectation(description: "first checkpoint entered persistence")
        let firstWriteMayFinish = DispatchSemaphore(value: 0)
        let hookLock = NSLock()
        var shouldBlock = true
        ConversationStore.persistenceWriteTestHook = {
            hookLock.lock()
            let blockThisAttempt = shouldBlock
            shouldBlock = false
            hookLock.unlock()
            if blockThisAttempt {
                firstWriteEntered.fulfill()
                firstWriteMayFinish.wait()
            }
        }
        defer {
            firstWriteMayFinish.signal()
            ConversationStore.persistenceWriteTestHook = nil
        }

        fixture.store.updateLive(fixture.conversation.id) {
            $0.messages.append(TranscriptEntry(kind: .assistant, text: "first generation"))
        }
        fixture.store.checkpointLiveMutationsNow()
        await fulfillment(of: [firstWriteEntered], timeout: 2)

        fixture.store.updateLive(fixture.conversation.id) {
            $0.messages[$0.messages.count - 1].text += " + newer generation"
        }
        fixture.store.checkpointLiveMutationsNow()
        firstWriteMayFinish.signal()
        fixture.store.flushSaves()
        ConversationStore.persistenceWriteTestHook = nil

        XCTAssertEqual(
            persistedConversation(fixture)?.messages.last?.text,
            "first generation + newer generation")
        XCTAssertEqual(
            fixture.store.completedDiskWrites,
            baselineWrites + 2,
            "a mutation after snapshot capture must queue a successor generation")
    }

    func testSQLiteCheckpointOrdersNewerAndSecondConversationBehindBlockedCommit() throws {
        let fixture = try makeSQLiteFixture(checkpointLatency: 3_600)
        defer {
            ConversationStore.authorityCommitTestHook = nil
            LibraryAuthorityRepository.forget(supportRoot: fixture.root)
            try? FileManager.default.removeItem(at: fixture.root)
        }
        let gate = TranscriptCheckpointCommitGate()
        ConversationStore.authorityCommitTestHook = { gate.blockFirstCommit() }

        fixture.store.updateLive(fixture.first.id) {
            $0.messages.append(TranscriptEntry(kind: .assistant, text: "first generation"))
        }
        fixture.store.checkpointLiveMutationsNow()
        XCTAssertTrue(gate.waitUntilEntered(), "the first SQLite checkpoint never reached COMMIT")

        fixture.store.updateLive(fixture.first.id) {
            $0.messages[$0.messages.count - 1].text += " + second generation"
        }
        fixture.store.updateLive(fixture.second.id) {
            $0.messages.append(TranscriptEntry(kind: .assistant, text: "independent generation"))
        }
        fixture.store.checkpointLiveMutationsNow()
        gate.allowCommit()
        fixture.store.flushSaves()
        ConversationStore.authorityCommitTestHook = nil

        XCTAssertEqual(
            try fixture.repository.conversation(id: fixture.first.id)?.messages.last?.text,
            "first generation + second generation")
        XCTAssertEqual(
            try fixture.repository.conversation(id: fixture.second.id)?.messages.last?.text,
            "independent generation")
    }

    private func makeFixture(checkpointLatency: TimeInterval) -> Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "transcript-checkpoint-\(UUID().uuidString)",
            isDirectory: true)
        let store = ConversationStore(
            appSupportBaseOverride: root,
            watchesDirectory: false,
            liveCheckpointMaximumLatency: checkpointLatency)
        let conversation = Conversation(
            title: "Checkpoint fixture",
            cwd: "/tmp",
            sdkSessionId: nil,
            messages: [TranscriptEntry(kind: .user, text: "prompt")],
            updatedAt: Date())
        store.upsert(conversation)
        store.flushSaves()
        return Fixture(root: root, store: store, conversation: conversation)
    }

    private func makeSQLiteFixture(checkpointLatency: TimeInterval) throws -> SQLiteFixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "sqlite-transcript-checkpoint-\(UUID().uuidString)",
            isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let recognition = try SQLiteLibraryBootstrapService.provisionIfNeeded(
            recognition: StorageAuthorityRecognizer.inspect(supportRoot: root),
            ownsProcessLease: true,
            now: { Date(timeIntervalSince1970: 1_788_000_000) })
        let repository = try XCTUnwrap(
            LibraryAuthorityRepository.open(recognition: recognition))
        let store = ConversationStore(
            appSupportBaseOverride: root,
            watchesDirectory: false,
            residencyMode: .eager,
            libraryAuthorityRepository: repository,
            liveCheckpointMaximumLatency: checkpointLatency)
        let first = Conversation(
            title: "First SQLite checkpoint",
            cwd: "/tmp",
            sdkSessionId: nil,
            messages: [TranscriptEntry(kind: .user, text: "first prompt")],
            updatedAt: Date())
        let second = Conversation(
            title: "Second SQLite checkpoint",
            cwd: "/tmp",
            sdkSessionId: nil,
            messages: [TranscriptEntry(kind: .user, text: "second prompt")],
            updatedAt: Date())
        store.upsert(first)
        store.upsert(second)
        store.flushSaves()
        return SQLiteFixture(
            root: root,
            repository: repository,
            store: store,
            first: first,
            second: second)
    }

    private func persistedConversation(_ fixture: Fixture) -> Conversation? {
        let url = fixture.root
            .appendingPathComponent("conversations", isDirectory: true)
            .appendingPathComponent("\(fixture.conversation.id.uuidString).json")
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? ConversationStore.makeDecoder().decode(Conversation.self, from: data)
    }

    private func waitUntil(
        _ description: String,
        timeout: TimeInterval = 2,
        condition: () -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            guard Date() < deadline else {
                XCTFail("Timed out waiting for \(description)")
                return
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }
}
