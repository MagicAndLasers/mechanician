import AppKit
import Combine
import Foundation
import SQLite3
import XCTest
@testable import Mechanician

private final class ProviderAccessRuntimeRecordBox: @unchecked Sendable {
    private let lock = NSLock()
    private var records: [Data] = []

    func append(_ record: Data) {
        lock.lock()
        records.append(record)
        lock.unlock()
    }

    func snapshot() -> [Data] {
        lock.lock()
        defer { lock.unlock() }
        return records
    }
}

private final class TranscriptReadCancellationProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var rows = 0

    func observeRowAndCancel() {
        lock.lock()
        rows += 1
        cancelled = true
        lock.unlock()
    }

    func isCancelled() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    func observedRowCount() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return rows
    }
}

@MainActor
final class SQLiteAuthorityConversationStoreTests: XCTestCase {
    private struct Fixture {
        let root: URL
        let repository: LibraryAuthorityRepository
        let conversation: Conversation
        let legacyURL: URL
    }

    /// Transcript paging. Painting the restored Conversation used to require reconstructing the
    /// whole record: 1,209 ms warm for the largest live one, because 8,349 of its 9,421 transcript
    /// events are tool entries totalling 104 MB. The last page is 123 KB and reads in ~1.4 ms.
    ///
    /// The preview must be exactly the tail of the record it previews, and it must be entries only
    /// — a truncated Conversation value could reach a save path and destroy a transcript.
    func testRecentTranscriptIsExactlyTheTailOfTheFullRecord() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let id = fixture.conversation.id

        var conversation = try XCTUnwrap(try fixture.repository.conversation(id: id))
        for index in 0..<40 {
            conversation.messages.append(
                TranscriptEntry(kind: index.isMultiple(of: 2) ? .user : .assistant,
                                text: "paged entry \(index)"))
        }
        conversation.updatedAt = Date()
        _ = try fixture.repository.commit(conversation: conversation)

        let full = try XCTUnwrap(try fixture.repository.conversation(id: id)).messages
        XCTAssertGreaterThan(full.count, 10)

        for limit in [1, 5, 10] {
            let read = try fixture.repository.recentTranscriptRead(id: id, limit: limit)
            let page = read.entries
            XCTAssertEqual(page.count, min(limit, full.count))
            XCTAssertEqual(
                page.map(\.id), Array(full.suffix(limit)).map(\.id),
                "a page of \(limit) must be the last \(limit) entries, oldest-first")
            XCTAssertEqual(page.map(\.text), Array(full.suffix(limit)).map(\.text))
            XCTAssertGreaterThanOrEqual(read.timing.queueWaitSeconds, 0)
            XCTAssertGreaterThanOrEqual(read.timing.readSeconds, 0)
        }

        // Asking for more than exists yields the whole transcript, not an error or a short page.
        XCTAssertEqual(
            try fixture.repository.recentTranscript(id: id, limit: full.count + 500).map(\.id),
            full.map(\.id))
        XCTAssertTrue(try fixture.repository.recentTranscript(id: id, limit: 0).isEmpty)
    }

    func testCancelingTranscriptPageSuppressesItsReadAndCallback() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let store = ConversationStore(
            appSupportBaseOverride: fixture.root,
            watchesDirectory: false,
            residencyMode: .boundedAfterRecovery,
            libraryAuthorityRepository: fixture.repository)

        let reachedReadBoundary = expectation(description: "page reached read boundary")
        let releaseReadBoundary = DispatchSemaphore(value: 0)
        ConversationStore.transcriptPageWillReadTestHook = { id in
            guard id == fixture.conversation.id else { return }
            reachedReadBoundary.fulfill()
            releaseReadBoundary.wait()
        }
        defer { releaseReadBoundary.signal() }

        let readFinished = expectation(description: "canceled page read finished")
        readFinished.isInverted = true
        ConversationStore.transcriptPageDidReadTestHook = { id in
            guard id == fixture.conversation.id else { return }
            readFinished.fulfill()
        }
        let callback = expectation(description: "canceled page callback")
        callback.isInverted = true
        let request = try XCTUnwrap(store.recentTranscriptPage(fixture.conversation.id) { _ in
            callback.fulfill()
        })

        await fulfillment(of: [reachedReadBoundary], timeout: 2)
        store.cancelRecentTranscriptPage(request)
        releaseReadBoundary.signal()
        await fulfillment(of: [readFinished, callback], timeout: 0.2)
    }

    func testColdSelectionHydratesBesideBlockedPageAndCanonicalInstallWins() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        var source = fixture.conversation
        source.cwd = ""
        _ = try fixture.repository.commit(conversation: source)
        let store = ConversationStore(
            appSupportBaseOverride: fixture.root,
            watchesDirectory: false,
            residencyMode: .boundedAfterRecovery,
            libraryAuthorityRepository: fixture.repository)
        XCTAssertNil(store.residentConversation(source.id))

        let pageStarted = expectation(description: "bounded page started")
        let hydrationStarted = expectation(description: "whole hydration started")
        let releasePage = DispatchSemaphore(value: 0)
        let releaseHydration = DispatchSemaphore(value: 0)
        ConversationStore.transcriptPageWillReadTestHook = { id in
            guard id == source.id else { return }
            pageStarted.fulfill()
            releasePage.wait()
        }
        ConversationStore.hydrationWillReadTestHook = { id in
            guard id == source.id else { return }
            hydrationStarted.fulfill()
            releaseHydration.wait()
        }
        defer {
            releasePage.signal()
            releaseHydration.signal()
        }

        let stalePageFinished = expectation(description: "stale page finished")
        stalePageFinished.isInverted = true
        ConversationStore.transcriptPageDidReadTestHook = { id in
            guard id == source.id else { return }
            stalePageFinished.fulfill()
        }
        let bridge = AgentBridge(
            settingsBaseOverride: fixture.root.appendingPathComponent(
                "concurrent-selection-settings", isDirectory: true),
            environmentOverride: [:],
            conversationStoreOverride: store)
        AgentBridge.live.add(bridge)
        defer {
            bridge.currentID = nil
            AgentBridge.live.remove(bridge)
            bridge.shutdown()
        }

        let selected = expectation(description: "canonical conversation installed")
        var selectionResult: Bool?
        bridge.select(source.id) { result in
            selectionResult = result
            selected.fulfill()
        }
        XCTAssertEqual(bridge.pendingSelectionID, source.id)
        XCTAssertEqual(bridge.conversationTranscriptPreview?.conversationID, source.id)
        XCTAssertNil(bridge.conversationTranscriptPreview?.entries)

        // Both boundaries must be reachable while neither worker is released. In the old flow the
        // hydration request did not even exist until the page callback returned.
        await fulfillment(of: [pageStarted, hydrationStarted], timeout: 2)
        releaseHydration.signal()
        await fulfillment(of: [selected], timeout: 3)

        XCTAssertEqual(selectionResult, true)
        XCTAssertEqual(bridge.currentID, source.id)
        XCTAssertEqual(bridge.entries.map(\.id), source.messages.map(\.id))
        XCTAssertNil(bridge.conversationTranscriptPreview)
        XCTAssertNotNil(bridge.conversationSelectionTimingMetrics.lastHydrationMilliseconds)
        XCTAssertNotNil(bridge.conversationSelectionTimingMetrics.lastInstallMilliseconds)
        XCTAssertNil(
            bridge.conversationSelectionTimingMetrics.lastPreviewMilliseconds,
            "the canonical install canceled the still-blocked page before it could publish")

        bridge.transcriptNativePresentationDidSynchronize(conversationID: UUID())
        XCTAssertNil(
            bridge.conversationSelectionTimingMetrics.lastNativePresentationSyncMilliseconds,
            "a native sync for another Conversation must not satisfy this selection")
        bridge.transcriptNativePresentationDidSynchronize(conversationID: source.id)
        let firstNativeSync = try XCTUnwrap(
            bridge.conversationSelectionTimingMetrics.lastNativePresentationSyncMilliseconds)
        bridge.transcriptNativePresentationDidSynchronize(conversationID: source.id)
        XCTAssertEqual(
            bridge.conversationSelectionTimingMetrics.lastNativePresentationSyncMilliseconds,
            firstNativeSync,
            "only the first matching native row synchronization belongs to this selection")

        releasePage.signal()
        await fulfillment(of: [stalePageFinished], timeout: 0.2)
        XCTAssertNil(bridge.conversationTranscriptPreview)
    }

    func testColdSelectionHydratesWhileBackgroundPrimarySnapshotIsBlocked() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        var source = fixture.conversation
        source.cwd = ""
        _ = try fixture.repository.commit(conversation: source)
        let background = Conversation(
            title: "Background hydration",
            cwd: "",
            sdkSessionId: nil,
            messages: [TranscriptEntry(kind: .user, text: "background transcript")],
            updatedAt: source.updatedAt.addingTimeInterval(1))
        _ = try fixture.repository.commit(conversation: background)
        let store = ConversationStore(
            appSupportBaseOverride: fixture.root,
            watchesDirectory: false,
            residencyMode: .boundedAfterRecovery,
            libraryAuthorityRepository: fixture.repository)
        XCTAssertNil(store.residentConversation(source.id))
        XCTAssertNil(store.residentConversation(background.id))

        let bridge = AgentBridge(
            settingsBaseOverride: fixture.root.appendingPathComponent(
                "interactive-selection-settings", isDirectory: true),
            environmentOverride: [:],
            conversationStoreOverride: store)
        AgentBridge.live.add(bridge)

        let backgroundSnapshotEntered = expectation(description: "background primary snapshot entered")
        let releaseBackgroundSnapshot = DispatchSemaphore(value: 0)
        let backgroundID = background.id
        fixture.repository.setConversationSnapshotQueueTestHook { id in
            guard id == backgroundID else { return }
            backgroundSnapshotEntered.fulfill()
            releaseBackgroundSnapshot.wait()
        }
        defer {
            releaseBackgroundSnapshot.signal()
            fixture.repository.setConversationSnapshotQueueTestHook(nil)
            bridge.currentID = nil
            AgentBridge.live.remove(bridge)
            bridge.shutdown()
        }

        let backgroundHydrated = expectation(description: "background hydration completed")
        var backgroundResult: Result<Conversation, ConversationHydrationError>?
        let backgroundRequest = store.acquireConversation(background.id) { result in
            backgroundResult = result
            backgroundHydrated.fulfill()
        }
        XCTAssertNotNil(backgroundRequest)
        await fulfillment(of: [backgroundSnapshotEntered], timeout: 2)

        let selected = expectation(description: "canonical conversation installed")
        var selectionResult: Bool?
        bridge.select(source.id) { result in
            selectionResult = result
            selected.fulfill()
        }

        // The background request owns the primary snapshot queue and remains deliberately blocked.
        // A selected record must nevertheless traverse its interactive admission/read lane and
        // install canonically, rather than leaving the preview state stuck at "Opening…".
        await fulfillment(of: [selected], timeout: 3)
        XCTAssertEqual(selectionResult, true)
        XCTAssertEqual(bridge.currentID, source.id)
        XCTAssertEqual(bridge.entries.map(\.id), source.messages.map(\.id))
        XCTAssertNil(bridge.conversationTranscriptPreview)
        XCTAssertNil(backgroundResult)
        XCTAssertNotNil(
            bridge.conversationSelectionTimingMetrics.lastHydrationQueueWaitMilliseconds)
        XCTAssertNotNil(
            bridge.conversationSelectionTimingMetrics.lastHydrationReadMilliseconds)

        releaseBackgroundSnapshot.signal()
        await fulfillment(of: [backgroundHydrated], timeout: 3)
        XCTAssertEqual(try backgroundResult?.get().id, background.id)
    }

    func testInteractiveAcquirePromotesBlockedBackgroundJobWithoutDuplicatePublication() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        var source = fixture.conversation
        source.cwd = ""
        _ = try fixture.repository.commit(conversation: source)
        let store = ConversationStore(
            appSupportBaseOverride: fixture.root,
            watchesDirectory: false,
            residencyMode: .boundedAfterRecovery,
            libraryAuthorityRepository: fixture.repository)
        XCTAssertNil(store.residentConversation(source.id))

        let primarySnapshotEntered = expectation(description: "background snapshot entered")
        let primarySnapshotReleased = expectation(description: "background snapshot released")
        let releasePrimarySnapshot = DispatchSemaphore(value: 0)
        let sourceID = source.id
        fixture.repository.setConversationSnapshotQueueTestHook { id in
            guard id == sourceID else { return }
            primarySnapshotEntered.fulfill()
            releasePrimarySnapshot.wait()
            primarySnapshotReleased.fulfill()
        }
        let completedReconstructions = expectation(description: "only promoted job reconstructs")
        completedReconstructions.expectedFulfillmentCount = 1
        ConversationStore.hydrationDidReadTestHook = { id in
            guard id == sourceID else { return }
            completedReconstructions.fulfill()
        }
        defer {
            releasePrimarySnapshot.signal()
            fixture.repository.setConversationSnapshotQueueTestHook(nil)
        }

        let backgroundFinished = expectation(description: "background waiter completed")
        var backgroundResult: Result<Conversation, ConversationHydrationError>?
        let backgroundRequest = store.acquireConversation(source.id) { result in
            backgroundResult = result
            backgroundFinished.fulfill()
        }
        XCTAssertNotNil(backgroundRequest)
        await fulfillment(of: [primarySnapshotEntered], timeout: 2)

        let interactiveFinished = expectation(description: "interactive waiter completed")
        var interactiveResult: Result<Conversation, ConversationHydrationError>?
        var interactiveTiming: ConversationHydrationTiming?
        let interactiveRequest = store.acquireConversation(
            source.id,
            priority: .interactive,
            timing: { timing in interactiveTiming = timing }
        ) { result in
            interactiveResult = result
            interactiveFinished.fulfill()
        }
        XCTAssertNotNil(interactiveRequest)
        await fulfillment(
            of: [backgroundFinished, interactiveFinished, completedReconstructions],
            timeout: 3)

        XCTAssertEqual(try backgroundResult?.get().id, source.id)
        XCTAssertEqual(try interactiveResult?.get().id, source.id)
        XCTAssertEqual(interactiveTiming?.priority, .interactive)
        XCTAssertEqual(store.hydrationDecodeCounts[source.id], 1)

        // The canceled primary job is allowed to leave its SQLite hook, but its identity and
        // cancellation checks must keep it from rebuilding or publishing over the promoted job.
        releasePrimarySnapshot.signal()
        await fulfillment(of: [primarySnapshotReleased], timeout: 2)
        await Task.yield()
        XCTAssertEqual(store.hydrationDecodeCounts[source.id], 1)
    }

    func testRecentTranscriptReadDoesNotWaitForPrimarySnapshotQueue() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let repository = fixture.repository
        let conversationID = fixture.conversation.id
        let fullSnapshotEntered = DispatchSemaphore(value: 0)
        let releaseFullSnapshot = DispatchSemaphore(value: 0)
        let fullSnapshotFinished = DispatchSemaphore(value: 0)

        repository.setConversationSnapshotQueueTestHook { id in
            guard id == conversationID else { return }
            fullSnapshotEntered.signal()
            releaseFullSnapshot.wait()
        }
        defer {
            releaseFullSnapshot.signal()
            repository.setConversationSnapshotQueueTestHook(nil)
        }

        let fullRead = Task.detached {
            defer { fullSnapshotFinished.signal() }
            return try repository.conversation(id: conversationID) != nil
        }
        XCTAssertEqual(
            fullSnapshotEntered.wait(timeout: .now() + 2),
            .success,
            "the full authority snapshot never occupied the primary queue")

        let previewFinished = expectation(description: "interactive preview finished")
        let previewRead = Task.detached {
            defer { previewFinished.fulfill() }
            let result = try repository.recentTranscriptRead(
                id: conversationID,
                limit: 100)
            return (result.entries.map(\.id), result.timing)
        }
        await fulfillment(of: [previewFinished], timeout: 2)
        XCTAssertEqual(
            fullSnapshotFinished.wait(timeout: .now()),
            .timedOut,
            "the preview should finish while the primary queue is still deliberately occupied")

        releaseFullSnapshot.signal()
        let fullReadSucceeded = try await fullRead.value
        XCTAssertTrue(fullReadSucceeded)
        let preview = try await previewRead.value
        XCTAssertEqual(preview.0, fixture.conversation.messages.map(\.id))
        XCTAssertGreaterThanOrEqual(preview.1.queueWaitSeconds, 0)
        XCTAssertGreaterThanOrEqual(preview.1.readSeconds, 0)
        repository.setConversationSnapshotQueueTestHook(nil)
    }

    func testRecentTranscriptReadCancellationAbortsBetweenRows() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let probe = TranscriptReadCancellationProbe()
        fixture.repository.setRecentTranscriptRowTestHook {
            probe.observeRowAndCancel()
        }
        defer { fixture.repository.setRecentTranscriptRowTestHook(nil) }

        XCTAssertThrowsError(
            try fixture.repository.recentTranscriptRead(
                id: fixture.conversation.id,
                limit: 100,
                isCancelled: { probe.isCancelled() })
        ) { error in
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertEqual(
            probe.observedRowCount(),
            1,
            "cancellation after the first decoded row must suppress the remaining page")
    }

    func testInteractiveTranscriptReaderRejectsMismatchedActivationIdentity() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let mismatchedMarker = StorageAuthorityMarker(
            mode: .sqlite,
            activationID: UUID(),
            databaseInstanceID: fixture.repository.databaseInstanceID,
            schemaVersion: SQLiteLibraryStore.schemaVersion,
            createdAt: "2026-08-31T12:00:00Z")

        XCTAssertThrowsError(
            try SQLiteLibraryStore.openActiveAuthorityInteractiveReader(
                supportRoot: fixture.root,
                marker: mismatchedMarker)
        ) { error in
            guard case SQLiteLibraryStoreError.protectedDatabase = error else {
                return XCTFail("a mismatched activation must fail closed, got \(error)")
            }
        }
    }




    override func tearDown() {
        ConversationStore.authorityCommitTestHook = nil
        ConversationStore.persistenceWriteTestHook = nil
        ConversationStore.conversationWorkEvidenceWriteTestHook = nil
        ConversationStore.conversationWorkEvidenceReadTestHook = nil
        ConversationStore.hydrationWillReadTestHook = nil
        ConversationStore.hydrationDidReadTestHook = nil
        ConversationStore.transcriptPageWillReadTestHook = nil
        ConversationStore.transcriptPageDidReadTestHook = nil
        super.tearDown()
    }

    private func source(
        identity: String,
        bytes: Data
    ) -> ShadowLibrarySourceFingerprint {
        ShadowLibrarySourceFingerprint(
            identity: identity,
            revision: "legacy-test",
            sourceBytes: bytes)
    }

    /// **The test that proves compression is wired end to end, not just at the edges.**
    ///
    /// A large tool payload is committed through the real authority path and read back through the
    /// real reader. Two things are asserted, and the second is the one that matters: that the bytes
    /// survive exactly, AND that they were actually stored compressed. Without the second assertion
    /// this test would pass just as happily if the codec silently did nothing.
    func testALargeToolPayloadIsStoredCompressedAndReadBackExactly() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        var conversation = try XCTUnwrap(
            try fixture.repository.conversation(id: fixture.conversation.id))
        var tool = TranscriptEntry(kind: .tool, text: "Bash")
        tool.toolName = "Bash"
        // Shaped like the real 972 MB: a grep dump.
        let output = String(
            repeating: "app/Sources/Mechanician/AgentBridge.swift:1912: let entry = record\n",
            count: 3_000)
        tool.toolResult = output
        conversation.messages.append(tool)
        _ = try fixture.repository.commit(conversation: conversation)

        // 1. It round-trips through the ordinary reader.
        let reloaded = try XCTUnwrap(
            try fixture.repository.conversation(id: fixture.conversation.id))
        let reloadedTool = try XCTUnwrap(reloaded.messages.last)
        XCTAssertEqual(reloadedTool.kind, .tool)
        XCTAssertEqual(reloadedTool.toolName, "Bash")
        XCTAssertEqual(
            reloadedTool.toolResult, output,
            "the tool output must survive byte for byte through compression")

        // 2. It was really compressed on disk, and the smaller kinds were not touched.
        let databases = try FileManager.default
            .subpathsOfDirectory(atPath: fixture.root.path)
            .filter { $0.hasSuffix(".db") }
        let databasePath = try XCTUnwrap(
            databases.first { $0.contains("library") } ?? databases.first,
            "no authority database found under the fixture root")
        var handle: OpaquePointer?
        guard sqlite3_open_v2(
            fixture.root.appendingPathComponent(databasePath).path,
            &handle, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let handle else {
            throw XCTSkip("could not open the authority for inspection")
        }
        defer { sqlite3_close(handle) }

        var compressedToolRows = 0
        var compressedOtherRows = 0
        var statement: OpaquePointer?
        XCTAssertEqual(
            sqlite3_prepare_v2(
                handle, "SELECT kind, payload FROM conversation_events", -1, &statement, nil),
            SQLITE_OK)
        defer { sqlite3_finalize(statement) }
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let rawKind = sqlite3_column_text(statement, 0) else { continue }
            let kind = String(cString: rawKind)
            let count = Int(sqlite3_column_bytes(statement, 1))
            guard count > 0, let bytes = sqlite3_column_blob(statement, 1) else { continue }
            let stored = Data(bytes: bytes, count: count)
            guard ConversationEventPayloadCodec.hasHeader(stored) else { continue }
            if kind == "transcript.tool" { compressedToolRows += 1 } else { compressedOtherRows += 1 }
        }

        XCTAssertGreaterThan(
            compressedToolRows, 0,
            "the large tool payload must be compressed on disk, or the codec is inert")
        XCTAssertEqual(
            compressedOtherRows, 0,
            "no other event kind may be compressed; SQL parses some of them as JSON")
    }

    private func makeFixture() throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "sqlite-authority-conversation-\(UUID().uuidString)",
            isDirectory: true)
        let conversations = root.appendingPathComponent("conversations", isDirectory: true)
        try FileManager.default.createDirectory(
            at: conversations,
            withIntermediateDirectories: true)

        let conversation = Conversation(
            title: "SQLite is authoritative",
            cwd: "/tmp/sqlite-authority",
            sdkSessionId: nil,
            messages: [
                TranscriptEntry(kind: .user, text: "database prompt"),
                TranscriptEntry(kind: .assistant, text: "database answer"),
            ],
            updatedAt: Date(timeIntervalSinceReferenceDate: 42_000),
            draft: "database draft",
            favorite: true)
        let conversationBytes = try ConversationStore.makeEncoder().encode(conversation)
        let home = HomeWorkspaceSettings(
            instructions: "Home authority",
            updatedAt: Date(timeIntervalSinceReferenceDate: 41_000))
        let homeBytes = try ConversationStore.makeEncoder().encode(home)
        var shadowStore: SQLiteLibraryStore? = try SQLiteLibraryStore(supportRoot: root)
        _ = try XCTUnwrap(shadowStore).reconcile(ShadowLibraryImportSnapshot(
            home: LibraryWorkspaceAdapter.capture(
                home: home,
                source: source(identity: "home-workspace.json", bytes: homeBytes)),
            workspaces: [],
            conversations: [try LibraryConversationAdapter.capture(
                conversation,
                source: source(
                    identity: "conversations/\(conversation.id.uuidString).json",
                    bytes: conversationBytes))]))
        let frontier = try XCTUnwrap(shadowStore).status()
        try XCTUnwrap(shadowStore).acknowledgeExactProjectionSnapshot(
            databaseInstanceID: frontier.databaseInstanceID,
            through: frontier.shadowChangeSequence,
            projectionSchemaVersion: Int(ConversationProjectionStore.schemaVersion))
        let activationID = UUID()
        try XCTUnwrap(shadowStore).prepareAuthority(
            activationID: activationID,
            minimumWriterBuild: StorageAuthorityProtocol.recognitionID)
        try XCTUnwrap(shadowStore).activatePreparedAuthority(activationID: activationID)
        let metadata = try XCTUnwrap(shadowStore).authorityMetadata()
        let marker = StorageAuthorityMarker(
            mode: .sqlite,
            activationID: activationID,
            databaseInstanceID: metadata.databaseInstanceID,
            schemaVersion: metadata.schemaVersion,
            createdAt: "2026-08-05T12:00:00Z")
        shadowStore = nil
        let activeStore = try SQLiteLibraryStore.openActiveAuthority(
            supportRoot: root,
            marker: marker)
        let repository = try LibraryAuthorityRepository(
            store: activeStore,
            supportRoot: root,
            marker: marker)
        return Fixture(
            root: root,
            repository: repository,
            conversation: conversation,
            legacyURL: conversations.appendingPathComponent(
                "\(conversation.id.uuidString).json"))
    }

    private func makeWorkEvidence(
        conversationID: UUID,
        suffix: String = UUID().uuidString
    ) -> ConversationWorkEvidence {
        let repositoryID = "/tmp/sqlite-authority/.git"
        let observedAt = Date(timeIntervalSinceReferenceDate: 54_000)
        let toolUseID = "tool-\(suffix)"
        let observation = ConversationRepositoryObservation(
            id: UUID(),
            conversationID: conversationID,
            turnID: "turn-\(suffix)",
            toolUseID: toolUseID,
            reason: .toolCompleted,
            rootPromptEntryID: nil,
            finalAssistantEntryID: nil,
            rootPromptExcerpt: nil,
            rootPromptExcerptWasTruncated: nil,
            finalAssistantExcerpt: nil,
            finalAssistantExcerptWasTruncated: nil,
            repositoryID: repositoryID,
            gitCommonDirectory: repositoryID,
            worktreePath: "/tmp/sqlite-authority",
            workspaceID: nil,
            canonicalCWD: "/tmp/sqlite-authority",
            headState: .attached,
            symbolicRef: "refs/heads/dev",
            headOID: String(repeating: "c", count: 40),
            statusAvailability: .available,
            indexChangeCount: 0,
            worktreeChangeCount: 1,
            untrackedCount: 0,
            attribution: .directTool,
            observedAt: observedAt)
        let file = ConversationFileObservation(
            id: UUID(),
            repositoryObservationID: observation.id,
            conversationID: conversationID,
            turnID: observation.turnID,
            toolUseID: toolUseID,
            repositoryID: repositoryID,
            repositoryRelativePath: "app/Sources/Feature.swift",
            operation: .edit,
            attribution: .directTool,
            beforeDigest: String(repeating: "d", count: 64),
            afterDigest: String(repeating: "e", count: 64),
            beforeExists: true,
            afterExists: true,
            boundedPatch: "- old\n+ new",
            patchWasTruncated: false,
            observedAt: observedAt)
        return ConversationWorkEvidence(repository: observation, files: [file])
    }

    private func acquire(
        _ id: UUID,
        from store: ConversationStore
    ) async throws -> Conversation {
        try await withCheckedThrowingContinuation { continuation in
            store.acquireConversation(id) { result in
                continuation.resume(with: result)
            }
        }
    }

    private func select(_ id: UUID, in bridge: AgentBridge) async -> Bool {
        await withCheckedContinuation { continuation in
            bridge.select(id) { continuation.resume(returning: $0) }
        }
    }

    func testMarkedAuthorityLaunchAndHydrationIgnoreConflictingLegacyJSON() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        var legacy = fixture.conversation
        legacy.title = "WRONG legacy title"
        legacy.messages = [TranscriptEntry(kind: .user, text: "WRONG legacy prompt")]
        let legacyBytes = try ConversationStore.makeEncoder().encode(legacy)
        try legacyBytes.write(to: fixture.legacyURL)

        let store = ConversationStore(
            appSupportBaseOverride: fixture.root,
            watchesDirectory: true,
            residencyMode: .boundedAfterRecovery,
            libraryAuthorityRepository: fixture.repository)

        XCTAssertTrue(store.isReady, store.persistenceError ?? "SQLite authority launch did not finish")
        XCTAssertTrue(store.usesSQLiteAuthority)
        XCTAssertEqual(store.summary(fixture.conversation.id)?.title, "SQLite is authoritative")
        XCTAssertEqual(store.directoryWatcherStartCount, 0)
        let hydrated = try await acquire(fixture.conversation.id, from: store)
        XCTAssertEqual(hydrated.title, "SQLite is authoritative")
        XCTAssertEqual(hydrated.messages.first?.text, "database prompt")

        store.trimResidencyIfNeeded(evictAllEligible: true)
        XCTAssertNil(store.residentConversation(fixture.conversation.id))
        var laterLegacy = legacy
        laterLegacy.title = "EVEN NEWER wrong Legacy title"
        try ConversationStore.makeEncoder().encode(laterLegacy).write(
            to: fixture.legacyURL,
            options: .atomic)
        let rehydrated = try await acquire(fixture.conversation.id, from: store)
        XCTAssertEqual(rehydrated.title, "SQLite is authoritative")
        XCTAssertEqual(store.sqliteReadMetrics.sqliteReads, 2)
    }

    func testUnloadedTitleFastPathHydratesOffMainAndPersistsWithoutTranscriptScans() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        var source = fixture.conversation
        source.title = "Large fallback title"
        source.titleSource = .fallback
        source.messages = (0..<12_000).map { index in
            var entry = TranscriptEntry(
                kind: index.isMultiple(of: 2) ? .user : .assistant,
                text: "authority row \(index)")
            if index == 11_999 { entry.captureOrdinal = 70_000 }
            return entry
        }
        _ = try fixture.repository.commit(conversation: source)

        let store = ConversationStore(
            appSupportBaseOverride: fixture.root,
            watchesDirectory: false,
            residencyMode: .boundedAfterRecovery,
            libraryAuthorityRepository: fixture.repository)
        XCTAssertNil(
            store.residentConversation(source.id),
            "the regression requires the inventory-only rename path")
        let summaryBefore = try XCTUnwrap(store.summary(source.id))
        let derivationsBefore = store.fullSummaryDerivationCount
        let seedScansBefore = store.captureOrdinalSeedScanCount
        let saveScansBefore = store.saveCaptureOrdinalScanCount

        let renamed = await withCheckedContinuation { continuation in
            store.updateTitleAfterAcquiring(
                source.id,
                to: "Renamed without a beach ball",
                source: .manual,
                completion: { continuation.resume(returning: $0) })
        }

        XCTAssertEqual(renamed?.title, "Renamed without a beach ball")
        XCTAssertEqual(renamed?.titleSource, .manual)
        XCTAssertEqual(renamed?.updatedAt, source.updatedAt)
        XCTAssertEqual(renamed?.messages.count, source.messages.count)
        var expectedSummary = summaryBefore
        expectedSummary.title = "Renamed without a beach ball"
        XCTAssertEqual(store.summary(source.id), expectedSummary)
        XCTAssertEqual(store.synchronousHydrationCount, 0)
        XCTAssertEqual(store.fullSummaryDerivationCount, derivationsBefore)
        XCTAssertEqual(store.captureOrdinalSeedScanCount, seedScansBefore)
        XCTAssertEqual(store.saveCaptureOrdinalScanCount, saveScansBefore)

        store.flushSaves()
        let committed = try XCTUnwrap(try fixture.repository.conversation(id: source.id))
        XCTAssertEqual(committed.title, "Renamed without a beach ball")
        XCTAssertEqual(committed.titleSource, .manual)
        XCTAssertEqual(committed.messages.count, source.messages.count)

        let relaunched = ConversationStore(
            appSupportBaseOverride: fixture.root,
            watchesDirectory: false,
            residencyMode: .boundedAfterRecovery,
            libraryAuthorityRepository: fixture.repository)
        let restored = try await acquire(source.id, from: relaunched)
        XCTAssertEqual(restored.title, "Renamed without a beach ball")
        XCTAssertEqual(restored.titleSource, .manual)
        XCTAssertEqual(restored.updatedAt, source.updatedAt)
        XCTAssertEqual(restored.messages.count, source.messages.count)
        XCTAssertEqual(relaunched.nextCaptureOrdinal(for: source.id), 70_001)
    }

    func testSuggestedPromptPersistsAcrossMarkedAuthorityStoreRelaunch() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let record = ConversationSuggestedPrompt(
            text: "Continue the persisted conversation.",
            source: .onDevice,
            rootPromptEntryID: fixture.conversation.messages.first?.id,
            assistantEntryID: fixture.conversation.messages.last?.id)

        do {
            let store = ConversationStore(
                appSupportBaseOverride: fixture.root,
                watchesDirectory: false,
                residencyMode: .boundedAfterRecovery,
                libraryAuthorityRepository: fixture.repository)
            _ = try await acquire(fixture.conversation.id, from: store)
            store.update(fixture.conversation.id) { $0.suggestedPrompt = record }
            store.flushSaves()
            XCTAssertEqual(
                try fixture.repository.conversation(id: fixture.conversation.id)?.suggestedPrompt,
                record)
        }

        let relaunched = ConversationStore(
            appSupportBaseOverride: fixture.root,
            watchesDirectory: false,
            residencyMode: .boundedAfterRecovery,
            libraryAuthorityRepository: fixture.repository)
        let restored = try await acquire(fixture.conversation.id, from: relaunched)
        XCTAssertEqual(restored.suggestedPrompt, record)
    }

    func testSuggestedPromptSurvivesSyntheticWaitRowsAcrossMarkedAuthorityRelaunch() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        var source = fixture.conversation
        let record = ConversationSuggestedPrompt(
            text: "Continue the persisted conversation.",
            source: .onDevice,
            rootPromptEntryID: source.messages.first?.id,
            assistantEntryID: source.messages.last?.id)
        source.suggestedPrompt = record
        source.messages.append(TranscriptEntry(
            kind: .user,
            text: "[wait-mode] The installed provenance now matches."))
        source.messages.append(TranscriptEntry(
            kind: .assistant,
            text: "The resumed turn is preparing a replacement."))
        _ = try fixture.repository.commit(conversation: source)

        let relaunched = ConversationStore(
            appSupportBaseOverride: fixture.root,
            watchesDirectory: false,
            residencyMode: .boundedAfterRecovery,
            libraryAuthorityRepository: fixture.repository)
        let restored = try await acquire(source.id, from: relaunched)
        XCTAssertEqual(restored.suggestedPrompt, record)

        relaunched.update(source.id) {
            $0.messages.append(TranscriptEntry(kind: .user, text: "Start real new work."))
        }
        relaunched.flushSaves()
        let afterGenuineTurn = ConversationStore(
            appSupportBaseOverride: fixture.root,
            watchesDirectory: false,
            residencyMode: .boundedAfterRecovery,
            libraryAuthorityRepository: fixture.repository)
        let afterGenuineTurnConversation = try await acquire(source.id, from: afterGenuineTurn)
        XCTAssertNil(afterGenuineTurnConversation.suggestedPrompt)
    }

    func testSyntheticWaitRetirementKeepsDurablePromptPresentedUntilAuthorityCommit() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        var source = fixture.conversation
        source.cwd = ""
        let old = ConversationSuggestedPrompt(
            text: "Keep this visible while the resumed turn resolves.",
            source: .onDevice,
            rootPromptEntryID: source.messages.first?.id,
            assistantEntryID: source.messages.last?.id)
        source.suggestedPrompt = old
        _ = try fixture.repository.commit(conversation: source)
        let other = Conversation(
            title: "Other conversation",
            cwd: "",
            sdkSessionId: nil,
            messages: [TranscriptEntry(kind: .user, text: "Keep this separate")],
            updatedAt: source.updatedAt.addingTimeInterval(-1))
        _ = try fixture.repository.commit(conversation: other)

        let store = ConversationStore(
            appSupportBaseOverride: fixture.root,
            watchesDirectory: false,
            residencyMode: .boundedAfterRecovery,
            libraryAuthorityRepository: fixture.repository)
        _ = try await acquire(source.id, from: store)
        let bridge = AgentBridge(
            settingsBaseOverride: fixture.root.appendingPathComponent("retirement-owner"),
            environmentOverride: [:],
            conversationStoreOverride: store)
        AgentBridge.live.add(bridge)
        defer {
            bridge.currentID = nil
            AgentBridge.live.remove(bridge)
            bridge.shutdown()
        }
        let openedSource = await select(source.id, in: bridge)
        XCTAssertTrue(openedSource)
        XCTAssertEqual(bridge.suggestedPrompt, old.text)

        let commitEntered = expectation(description: "retirement commit entered")
        let commitMayProceed = DispatchSemaphore(value: 0)
        ConversationStore.authorityCommitTestHook = {
            commitEntered.fulfill()
            commitMayProceed.wait()
        }
        defer {
            commitMayProceed.signal()
            ConversationStore.authorityCommitTestHook = nil
        }
        let resolved = expectation(description: "retirement resolved")
        var results: [Bool] = []
        bridge.persistGeneratedSuggestedPromptForTesting(
            nil,
            for: source.id,
            replacing: old
        ) { committed in
            results.append(committed)
            resolved.fulfill()
        }

        await fulfillment(of: [commitEntered], timeout: 2)
        XCTAssertNil(store.conversation(source.id)?.suggestedPrompt)
        XCTAssertEqual(store.presentedSuggestedPrompt(for: source.id), old)
        XCTAssertEqual(bridge.suggestedPrompt, old.text)
        XCTAssertEqual(
            try fixture.repository.conversation(id: source.id)?.suggestedPrompt,
            old)

        let openedOther = await select(other.id, in: bridge)
        XCTAssertTrue(openedOther)
        let reopenedSource = await select(source.id, in: bridge)
        XCTAssertTrue(reopenedSource)
        XCTAssertEqual(
            bridge.suggestedPrompt,
            old.text,
            "navigation must keep projecting the last durable value before COMMIT")

        commitMayProceed.signal()
        await fulfillment(of: [resolved], timeout: 3)
        ConversationStore.authorityCommitTestHook = nil
        XCTAssertEqual(results, [true])
        XCTAssertNil(store.presentedSuggestedPrompt(for: source.id))
        XCTAssertNil(bridge.suggestedPrompt)
        XCTAssertNil(try fixture.repository.conversation(id: source.id)?.suggestedPrompt)

        let relaunched = ConversationStore(
            appSupportBaseOverride: fixture.root,
            watchesDirectory: false,
            residencyMode: .boundedAfterRecovery,
            libraryAuthorityRepository: fixture.repository)
        let restored = try await acquire(source.id, from: relaunched)
        XCTAssertNil(restored.suggestedPrompt)
    }

    func testNewerSuggestionSupersedesBlockedSyntheticWaitRetirement() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        var source = fixture.conversation
        let old = ConversationSuggestedPrompt(
            text: "The old wait suggestion.",
            source: .onDevice,
            rootPromptEntryID: source.messages.first?.id,
            assistantEntryID: source.messages.last?.id)
        source.suggestedPrompt = old
        _ = try fixture.repository.commit(conversation: source)

        let store = ConversationStore(
            appSupportBaseOverride: fixture.root,
            watchesDirectory: false,
            residencyMode: .boundedAfterRecovery,
            libraryAuthorityRepository: fixture.repository)
        _ = try await acquire(source.id, from: store)

        let firstCommitEntered = expectation(description: "retirement commit entered")
        let firstCommitMayProceed = DispatchSemaphore(value: 0)
        let hookLock = NSLock()
        var didBlockFirstCommit = false
        ConversationStore.authorityCommitTestHook = {
            hookLock.lock()
            let shouldBlock = !didBlockFirstCommit
            didBlockFirstCommit = true
            hookLock.unlock()
            if shouldBlock {
                firstCommitEntered.fulfill()
                firstCommitMayProceed.wait()
            }
        }
        defer {
            firstCommitMayProceed.signal()
            ConversationStore.authorityCommitTestHook = nil
        }
        let retirementResolved = expectation(description: "retirement rejected")
        var retirementResults: [Bool] = []
        _ = store.updateAwaitingSuggestedPromptPublication(
            source.id,
            expected: old,
            replacement: nil,
            mutation: { _ in }
        ) {
            retirementResults.append($0)
            retirementResolved.fulfill()
        }

        await fulfillment(of: [firstCommitEntered], timeout: 2)
        let newer = ConversationSuggestedPrompt(
            text: "Use the newer grounded suggestion.",
            source: .provider,
            rootPromptEntryID: source.messages.first?.id,
            assistantEntryID: source.messages.last?.id)
        let newerResolved = expectation(description: "newer suggestion committed")
        var newerResults: [Bool] = []
        _ = store.updateAwaitingSuggestedPromptPublication(
            source.id,
            expected: old,
            replacement: newer,
            mutation: { _ in }
        ) {
            newerResults.append($0)
            newerResolved.fulfill()
        }
        XCTAssertEqual(store.presentedSuggestedPrompt(for: source.id), old)

        firstCommitMayProceed.signal()
        await fulfillment(of: [retirementResolved, newerResolved], timeout: 3)
        ConversationStore.authorityCommitTestHook = nil
        XCTAssertEqual(retirementResults, [false])
        XCTAssertEqual(newerResults, [true])
        XCTAssertEqual(store.presentedSuggestedPrompt(for: source.id), newer)
        XCTAssertEqual(
            try fixture.repository.conversation(id: source.id)?.suggestedPrompt,
            newer)
    }

    func testNewerUserClearSupersedesBlockedSyntheticWaitRetirementWithSameNilValue() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        var source = fixture.conversation
        let old = ConversationSuggestedPrompt(
            text: "The old wait suggestion.",
            source: .onDevice,
            rootPromptEntryID: source.messages.first?.id,
            assistantEntryID: source.messages.last?.id)
        source.suggestedPrompt = old
        _ = try fixture.repository.commit(conversation: source)

        let store = ConversationStore(
            appSupportBaseOverride: fixture.root,
            watchesDirectory: false,
            residencyMode: .boundedAfterRecovery,
            libraryAuthorityRepository: fixture.repository)
        _ = try await acquire(source.id, from: store)
        let bridge = AgentBridge(
            settingsBaseOverride: fixture.root.appendingPathComponent("retirement-clear-owner"),
            environmentOverride: [:],
            conversationStoreOverride: store)
        bridge.currentID = source.id
        bridge.entries = source.messages
        bridge.suggestedPrompt = old.text
        AgentBridge.live.add(bridge)
        defer {
            bridge.currentID = nil
            AgentBridge.live.remove(bridge)
            bridge.shutdown()
        }

        let commitEntered = expectation(description: "retirement commit entered")
        let commitMayProceed = DispatchSemaphore(value: 0)
        ConversationStore.authorityCommitTestHook = {
            commitEntered.fulfill()
            commitMayProceed.wait()
        }
        defer {
            commitMayProceed.signal()
            ConversationStore.authorityCommitTestHook = nil
        }
        let retirementResolved = expectation(description: "retirement superseded")
        var retirementResults: [Bool] = []
        bridge.persistGeneratedSuggestedPromptForTesting(
            nil,
            for: source.id,
            replacing: old
        ) {
            retirementResults.append($0)
            retirementResolved.fulfill()
        }

        await fulfillment(of: [commitEntered], timeout: 2)
        XCTAssertEqual(store.presentedSuggestedPrompt(for: source.id), old)
        bridge.clearSuggestedPromptForTesting(source.id)
        XCTAssertNil(
            store.presentedSuggestedPrompt(for: source.id),
            "a newer user-owned clear must invalidate an indistinguishable provisional nil")
        XCTAssertNil(bridge.suggestedPrompt)

        commitMayProceed.signal()
        await fulfillment(of: [retirementResolved], timeout: 3)
        ConversationStore.authorityCommitTestHook = nil
        XCTAssertEqual(retirementResults, [false])
        XCTAssertNil(store.presentedSuggestedPrompt(for: source.id))
        XCTAssertNil(try fixture.repository.conversation(id: source.id)?.suggestedPrompt)
    }

    func testGeneratedReplacementProjectsOnlyAfterAuthorityCommit() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        var source = fixture.conversation
        source.cwd = ""
        let old = ConversationSuggestedPrompt(
            text: "Keep this until a replacement commits.",
            source: .onDevice,
            rootPromptEntryID: source.messages.first?.id,
            assistantEntryID: source.messages.last?.id)
        let wait = TranscriptEntry(
            kind: .user,
            text: "[wait-mode] The installed provenance now matches.")
        let assistant = TranscriptEntry(
            kind: .assistant,
            text: "The replacement can now be generated.")
        source.messages.append(wait)
        source.messages.append(assistant)
        source.suggestedPrompt = old
        _ = try fixture.repository.commit(conversation: source)
        let other = Conversation(
            title: "Other conversation",
            cwd: "",
            sdkSessionId: nil,
            messages: [TranscriptEntry(kind: .user, text: "Keep this separate")],
            updatedAt: source.updatedAt.addingTimeInterval(-1))
        _ = try fixture.repository.commit(conversation: other)

        let store = ConversationStore(
            appSupportBaseOverride: fixture.root,
            watchesDirectory: false,
            residencyMode: .boundedAfterRecovery,
            libraryAuthorityRepository: fixture.repository)
        _ = try await acquire(source.id, from: store)
        let bridge = AgentBridge(
            settingsBaseOverride: fixture.root.appendingPathComponent("generated-owner"),
            environmentOverride: [:],
            conversationStoreOverride: store)
        bridge.currentID = source.id
        bridge.entries = source.messages
        bridge.suggestedPrompt = old.text
        AgentBridge.live.add(bridge)
        let secondBridge = AgentBridge(
            settingsBaseOverride: fixture.root.appendingPathComponent("generated-second-window"),
            environmentOverride: [:],
            conversationStoreOverride: store)
        AgentBridge.live.add(secondBridge)
        defer {
            bridge.currentID = nil
            secondBridge.currentID = nil
            AgentBridge.live.remove(bridge)
            AgentBridge.live.remove(secondBridge)
            bridge.shutdown()
            secondBridge.shutdown()
        }

        let replacement = ConversationSuggestedPrompt(
            text: "Implement the grounded next action.",
            source: .onDevice,
            rootPromptEntryID: wait.id,
            assistantEntryID: assistant.id)
        let commitEntered = expectation(description: "generated replacement commit entered")
        let hookLock = NSLock()
        var didBlockCommit = false
        let commitMayProceed = DispatchSemaphore(value: 0)
        ConversationStore.authorityCommitTestHook = {
            hookLock.lock()
            let shouldBlock = !didBlockCommit
            didBlockCommit = true
            hookLock.unlock()
            if shouldBlock {
                commitEntered.fulfill()
                commitMayProceed.wait()
            }
        }
        defer {
            commitMayProceed.signal()
            ConversationStore.authorityCommitTestHook = nil
        }
        let firstResolved = expectation(description: "older generated replacement resolved")
        var firstResults: [Bool] = []
        bridge.persistGeneratedSuggestedPromptForTesting(
            replacement,
            for: source.id,
            replacing: old
        ) { succeeded in
            firstResults.append(succeeded)
            firstResolved.fulfill()
        }

        await fulfillment(of: [commitEntered], timeout: 2)
        XCTAssertEqual(bridge.suggestedPrompt, old.text)
        XCTAssertEqual(
            try fixture.repository.conversation(id: source.id)?.suggestedPrompt,
            old)
        XCTAssertEqual(store.conversation(source.id)?.suggestedPrompt, replacement)
        XCTAssertEqual(
            store.presentedSuggestedPrompt(for: source.id),
            old,
            "the shared presentation value must not expose the provisional resident mutation")

        let openedOther = await select(other.id, in: bridge)
        XCTAssertTrue(openedOther)
        let reopenedSource = await select(source.id, in: bridge)
        XCTAssertTrue(reopenedSource)
        XCTAssertEqual(
            bridge.suggestedPrompt,
            old.text,
            "navigating away and back while COMMIT is blocked must restore the durable value")
        let returnedToOther = await select(other.id, in: bridge)
        XCTAssertTrue(returnedToOther)
        let openedSourceInSecondWindow = await select(source.id, in: secondBridge)
        XCTAssertTrue(openedSourceInSecondWindow)
        XCTAssertEqual(
            secondBridge.suggestedPrompt,
            old.text,
            "another window must observe the same fenced value")

        let competingReplacement = ConversationSuggestedPrompt(
            text: "The newest provisional value must win.",
            source: .onDevice,
            rootPromptEntryID: wait.id,
            assistantEntryID: assistant.id)
        let newestPublished = expectation(description: "newest replacement published")
        var competingResults: [Bool] = []
        secondBridge.persistGeneratedSuggestedPromptForTesting(
            competingReplacement,
            for: source.id,
            replacing: old
        ) {
            competingResults.append($0)
            newestPublished.fulfill()
        }
        XCTAssertTrue(
            competingResults.isEmpty,
            "the newer publication owns a fresh fence and still waits for authority")
        XCTAssertEqual(store.presentedSuggestedPrompt(for: source.id), old)

        commitMayProceed.signal()
        await fulfillment(of: [firstResolved, newestPublished], timeout: 3)
        ConversationStore.authorityCommitTestHook = nil
        XCTAssertEqual(firstResults, [false])
        XCTAssertEqual(competingResults, [true])
        XCTAssertEqual(secondBridge.suggestedPrompt, competingReplacement.text)
        XCTAssertEqual(store.presentedSuggestedPrompt(for: source.id), competingReplacement)
        XCTAssertEqual(
            try fixture.repository.conversation(id: source.id)?.suggestedPrompt,
            competingReplacement)

        let relaunched = ConversationStore(
            appSupportBaseOverride: fixture.root,
            watchesDirectory: false,
            residencyMode: .boundedAfterRecovery,
            libraryAuthorityRepository: fixture.repository)
        let relaunchedConversation = try await acquire(source.id, from: relaunched)
        XCTAssertEqual(relaunchedConversation.suggestedPrompt, competingReplacement)
    }

    func testGenuineClearSupersedesBlockedPublicationAcrossNavigation() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        var source = fixture.conversation
        source.cwd = ""
        let old = ConversationSuggestedPrompt(
            text: "Retire this when genuine work starts.",
            source: .onDevice,
            rootPromptEntryID: source.messages.first?.id,
            assistantEntryID: source.messages.last?.id)
        source.suggestedPrompt = old
        _ = try fixture.repository.commit(conversation: source)
        let other = Conversation(
            title: "Navigation target",
            cwd: "",
            sdkSessionId: nil,
            messages: [TranscriptEntry(kind: .user, text: "Other work")],
            updatedAt: source.updatedAt.addingTimeInterval(-1))
        _ = try fixture.repository.commit(conversation: other)

        let store = ConversationStore(
            appSupportBaseOverride: fixture.root,
            watchesDirectory: false,
            residencyMode: .boundedAfterRecovery,
            libraryAuthorityRepository: fixture.repository)
        _ = try await acquire(source.id, from: store)
        let bridge = AgentBridge(
            settingsBaseOverride: fixture.root.appendingPathComponent("clear-supersession-owner"),
            environmentOverride: [:],
            conversationStoreOverride: store)
        bridge.currentID = source.id
        bridge.entries = source.messages
        bridge.suggestedPrompt = old.text
        AgentBridge.live.add(bridge)
        defer {
            bridge.currentID = nil
            AgentBridge.live.remove(bridge)
            bridge.shutdown()
        }

        let replacement = ConversationSuggestedPrompt(
            text: "This older publication must stay retired.",
            source: .onDevice,
            rootPromptEntryID: source.messages.first?.id,
            assistantEntryID: source.messages.last?.id)
        let commitEntered = expectation(description: "older publication commit entered")
        let hookLock = NSLock()
        var didBlockCommit = false
        let commitMayProceed = DispatchSemaphore(value: 0)
        ConversationStore.authorityCommitTestHook = {
            hookLock.lock()
            let shouldBlock = !didBlockCommit
            didBlockCommit = true
            hookLock.unlock()
            if shouldBlock {
                commitEntered.fulfill()
                commitMayProceed.wait()
            }
        }
        defer {
            commitMayProceed.signal()
            ConversationStore.authorityCommitTestHook = nil
        }
        let oldResolved = expectation(description: "older publication rejected")
        var oldResults: [Bool] = []
        bridge.persistGeneratedSuggestedPromptForTesting(
            replacement,
            for: source.id,
            replacing: old
        ) {
            oldResults.append($0)
            oldResolved.fulfill()
        }

        await fulfillment(of: [commitEntered], timeout: 2)
        bridge.clearSuggestedPromptForTesting(source.id)
        XCTAssertNil(store.presentedSuggestedPrompt(for: source.id))
        XCTAssertNil(store.conversation(source.id)?.suggestedPrompt)
        XCTAssertNil(bridge.suggestedPrompt)

        let openedOther = await select(other.id, in: bridge)
        XCTAssertTrue(openedOther)
        let reopenedSource = await select(source.id, in: bridge)
        XCTAssertTrue(reopenedSource)
        XCTAssertNil(
            bridge.suggestedPrompt,
            "navigation must show the later clear even while the older COMMIT remains blocked")

        let clearPublished = expectation(description: "clear reached authority")
        store.awaitPublishedSnapshot(source.id) { snapshot in
            XCTAssertNil(snapshot?.conversation.suggestedPrompt)
            clearPublished.fulfill()
        }
        commitMayProceed.signal()
        await fulfillment(of: [oldResolved, clearPublished], timeout: 3)
        ConversationStore.authorityCommitTestHook = nil

        XCTAssertEqual(oldResults, [false])
        XCTAssertNil(store.presentedSuggestedPrompt(for: source.id))
        XCTAssertNil(try fixture.repository.conversation(id: source.id)?.suggestedPrompt)
    }

    func testCommittedPublicationProjectsAfterInitiatingBridgeCloses() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        var source = fixture.conversation
        source.cwd = ""
        let old = ConversationSuggestedPrompt(
            text: "Keep showing the durable value.",
            source: .onDevice,
            rootPromptEntryID: source.messages.first?.id,
            assistantEntryID: source.messages.last?.id)
        source.suggestedPrompt = old
        _ = try fixture.repository.commit(conversation: source)
        let other = Conversation(
            title: "Initiator destination",
            cwd: "",
            sdkSessionId: nil,
            messages: [TranscriptEntry(kind: .user, text: "Move here")],
            updatedAt: source.updatedAt.addingTimeInterval(-1))
        _ = try fixture.repository.commit(conversation: other)

        let store = ConversationStore(
            appSupportBaseOverride: fixture.root,
            watchesDirectory: false,
            residencyMode: .boundedAfterRecovery,
            libraryAuthorityRepository: fixture.repository)
        _ = try await acquire(source.id, from: store)
        var initiatingBridge: AgentBridge? = AgentBridge(
            settingsBaseOverride: fixture.root.appendingPathComponent("closing-initiator"),
            environmentOverride: [:],
            conversationStoreOverride: store)
        initiatingBridge?.currentID = source.id
        initiatingBridge?.entries = source.messages
        initiatingBridge?.suggestedPrompt = old.text
        AgentBridge.live.add(try XCTUnwrap(initiatingBridge))

        let observingBridge = AgentBridge(
            settingsBaseOverride: fixture.root.appendingPathComponent("remaining-observer"),
            environmentOverride: [:],
            conversationStoreOverride: store)
        AgentBridge.live.add(observingBridge)
        defer {
            initiatingBridge?.currentID = nil
            if let initiatingBridge { AgentBridge.live.remove(initiatingBridge) }
            initiatingBridge?.shutdown()
            observingBridge.currentID = nil
            AgentBridge.live.remove(observingBridge)
            observingBridge.shutdown()
        }

        let replacement = ConversationSuggestedPrompt(
            text: "Project this from the shared store boundary.",
            source: .onDevice,
            rootPromptEntryID: source.messages.first?.id,
            assistantEntryID: source.messages.last?.id)
        let commitEntered = expectation(description: "publication commit entered")
        let hookLock = NSLock()
        var didBlockCommit = false
        let commitMayProceed = DispatchSemaphore(value: 0)
        ConversationStore.authorityCommitTestHook = {
            hookLock.lock()
            let shouldBlock = !didBlockCommit
            didBlockCommit = true
            hookLock.unlock()
            if shouldBlock {
                commitEntered.fulfill()
                commitMayProceed.wait()
            }
        }
        defer {
            commitMayProceed.signal()
            ConversationStore.authorityCommitTestHook = nil
        }
        let resolved = expectation(description: "publication resolved after initiator closed")
        var completionResults: [Bool] = []
        initiatingBridge?.persistGeneratedSuggestedPromptForTesting(
            replacement,
            for: source.id,
            replacing: old
        ) {
            completionResults.append($0)
            resolved.fulfill()
        }

        await fulfillment(of: [commitEntered], timeout: 2)
        let initiatorOpenedOther = await select(other.id, in: try XCTUnwrap(initiatingBridge))
        XCTAssertTrue(initiatorOpenedOther)
        let observerOpenedSource = await select(source.id, in: observingBridge)
        XCTAssertTrue(observerOpenedSource)
        XCTAssertEqual(observingBridge.suggestedPrompt, old.text)

        initiatingBridge?.currentID = nil
        if let initiatingBridge { AgentBridge.live.remove(initiatingBridge) }
        initiatingBridge?.shutdown()
        initiatingBridge = nil
        commitMayProceed.signal()
        await fulfillment(of: [resolved], timeout: 3)
        ConversationStore.authorityCommitTestHook = nil

        XCTAssertEqual(completionResults, [true])
        XCTAssertEqual(observingBridge.suggestedPrompt, replacement.text)
        XCTAssertEqual(store.presentedSuggestedPrompt(for: source.id), replacement)
        XCTAssertEqual(
            try fixture.repository.conversation(id: source.id)?.suggestedPrompt,
            replacement)
    }

    func testFailedGeneratedPublicationRestoresNilFenceAndRetryNeverPublishesReplacement() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let store = ConversationStore(
            appSupportBaseOverride: fixture.root,
            watchesDirectory: false,
            residencyMode: .boundedAfterRecovery,
            libraryAuthorityRepository: fixture.repository)
        let source = try await acquire(fixture.conversation.id, from: store)
        XCTAssertNil(source.suggestedPrompt)

        let bridge = AgentBridge(
            settingsBaseOverride: fixture.root.appendingPathComponent("generated-failure-owner"),
            environmentOverride: [:],
            conversationStoreOverride: store)
        bridge.currentID = source.id
        bridge.entries = source.messages
        bridge.suggestedPrompt = nil
        AgentBridge.live.add(bridge)
        defer {
            bridge.currentID = nil
            AgentBridge.live.remove(bridge)
            bridge.shutdown()
        }

        let replacement = ConversationSuggestedPrompt(
            text: "This failed value must never appear.",
            source: .onDevice,
            rootPromptEntryID: source.messages.first?.id,
            assistantEntryID: source.messages.last?.id)
        ConversationStore.persistenceWriteTestHook = {
            throw CocoaError(.fileWriteUnknown)
        }
        let failed = expectation(description: "suggestion publication failed")
        var completionResults: [Bool] = []
        bridge.persistGeneratedSuggestedPromptForTesting(
            replacement,
            for: source.id,
            replacing: nil
        ) { succeeded in
            completionResults.append(succeeded)
            failed.fulfill()
        }

        XCTAssertNil(
            store.presentedSuggestedPrompt(for: source.id),
            "a concrete fence must retain an expected nil while the resident value is provisional")
        XCTAssertEqual(store.conversation(source.id)?.suggestedPrompt, replacement)
        XCTAssertNil(bridge.suggestedPrompt)

        await fulfillment(of: [failed], timeout: 3)
        XCTAssertEqual(completionResults, [false])
        XCTAssertNil(store.presentedSuggestedPrompt(for: source.id))
        XCTAssertNil(store.conversation(source.id)?.suggestedPrompt)
        XCTAssertNil(bridge.suggestedPrompt)
        XCTAssertNil(try fixture.repository.conversation(id: source.id)?.suggestedPrompt)
        XCTAssertNotNil(store.persistenceError)

        ConversationStore.persistenceWriteTestHook = nil
        let retried = expectation(description: "restored expected value retried")
        store.retryFailedSaves()
        store.awaitPublishedSnapshot(source.id) { snapshot in
            XCTAssertNil(snapshot?.conversation.suggestedPrompt)
            retried.fulfill()
        }
        await fulfillment(of: [retried], timeout: 3)

        XCTAssertEqual(completionResults, [false], "retry must not resolve publication twice")
        XCTAssertNil(store.persistenceError)
        XCTAssertNil(store.presentedSuggestedPrompt(for: source.id))
        XCTAssertNil(store.conversation(source.id)?.suggestedPrompt)
        XCTAssertNil(try fixture.repository.conversation(id: source.id)?.suggestedPrompt)
    }

    func testFailedOlderPublicationDoesNotRestoreOverLaterClear() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        var source = fixture.conversation
        let old = ConversationSuggestedPrompt(
            text: "This is the durable starting value.",
            source: .onDevice,
            rootPromptEntryID: source.messages.first?.id,
            assistantEntryID: source.messages.last?.id)
        source.suggestedPrompt = old
        _ = try fixture.repository.commit(conversation: source)

        let store = ConversationStore(
            appSupportBaseOverride: fixture.root,
            watchesDirectory: false,
            residencyMode: .boundedAfterRecovery,
            libraryAuthorityRepository: fixture.repository)
        _ = try await acquire(source.id, from: store)
        let bridge = AgentBridge(
            settingsBaseOverride: fixture.root.appendingPathComponent("failed-clear-owner"),
            environmentOverride: [:],
            conversationStoreOverride: store)
        bridge.currentID = source.id
        bridge.entries = source.messages
        bridge.suggestedPrompt = old.text
        AgentBridge.live.add(bridge)
        defer {
            bridge.currentID = nil
            AgentBridge.live.remove(bridge)
            bridge.shutdown()
        }

        let failedReplacement = ConversationSuggestedPrompt(
            text: "The failed older replacement.",
            source: .onDevice,
            rootPromptEntryID: source.messages.first?.id,
            assistantEntryID: source.messages.last?.id)
        ConversationStore.persistenceWriteTestHook = {
            throw CocoaError(.fileWriteUnknown)
        }
        let failed = expectation(description: "older publication and later clear failed")
        var completionResults: [Bool] = []
        bridge.persistGeneratedSuggestedPromptForTesting(
            failedReplacement,
            for: source.id,
            replacing: old
        ) {
            completionResults.append($0)
            failed.fulfill()
        }
        bridge.clearSuggestedPromptForTesting(source.id)

        XCTAssertNil(store.presentedSuggestedPrompt(for: source.id))
        XCTAssertNil(store.conversation(source.id)?.suggestedPrompt)
        XCTAssertNil(bridge.suggestedPrompt)
        await fulfillment(of: [failed], timeout: 3)

        XCTAssertEqual(completionResults, [false])
        XCTAssertNil(
            store.conversation(source.id)?.suggestedPrompt,
            "failed rollback must compare-and-swap instead of resurrecting the old value")
        XCTAssertNil(store.presentedSuggestedPrompt(for: source.id))
        XCTAssertNil(bridge.suggestedPrompt)
        XCTAssertEqual(
            try fixture.repository.conversation(id: source.id)?.suggestedPrompt,
            old,
            "the clear is still awaiting an explicit retry after its forced failure")

        ConversationStore.persistenceWriteTestHook = nil
        let retried = expectation(description: "later clear retried")
        store.retryFailedSaves()
        store.awaitPublishedSnapshot(source.id) { snapshot in
            XCTAssertNil(snapshot?.conversation.suggestedPrompt)
            retried.fulfill()
        }
        await fulfillment(of: [retried], timeout: 3)

        XCTAssertEqual(completionResults, [false])
        XCTAssertNil(store.persistenceError)
        XCTAssertNil(store.presentedSuggestedPrompt(for: source.id))
        XCTAssertNil(try fixture.repository.conversation(id: source.id)?.suggestedPrompt)
    }

    func testMarkedAuthorityHydrationDropsSuggestionWithMissingTurnEndpoints() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        var source = fixture.conversation
        source.suggestedPrompt = ConversationSuggestedPrompt(
            text: "This orphan must not return.",
            source: .onDevice,
            rootPromptEntryID: UUID(),
            assistantEntryID: UUID())
        _ = try fixture.repository.commit(conversation: source)

        let relaunched = ConversationStore(
            appSupportBaseOverride: fixture.root,
            watchesDirectory: false,
            residencyMode: .boundedAfterRecovery,
            libraryAuthorityRepository: fixture.repository)
        let restored = try await acquire(source.id, from: relaunched)
        XCTAssertNil(restored.suggestedPrompt)
        XCTAssertEqual(restored.messages.map(\.id), source.messages.map(\.id))
    }

    func testAcceptingSuggestedPromptCommitsDraftAndClearAsOneAuthorityState() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let record = ConversationSuggestedPrompt(
            text: "Continue the persisted conversation.",
            source: .onDevice,
            rootPromptEntryID: fixture.conversation.messages.first?.id,
            assistantEntryID: fixture.conversation.messages.last?.id)
        var source = fixture.conversation
        source.suggestedPrompt = record
        _ = try fixture.repository.commit(conversation: source)

        let store = ConversationStore(
            appSupportBaseOverride: fixture.root,
            watchesDirectory: false,
            residencyMode: .boundedAfterRecovery,
            libraryAuthorityRepository: fixture.repository)
        _ = try await acquire(source.id, from: store)
        let bridge = AgentBridge(
            settingsBaseOverride: fixture.root.appendingPathComponent("accept-owner"),
            environmentOverride: [:],
            conversationStoreOverride: store)
        bridge.currentID = source.id
        bridge.entries = source.messages
        bridge.suggestedPrompt = record.text
        defer {
            bridge.currentID = nil
            bridge.shutdown()
        }

        let commitEntered = expectation(description: "accepted suggestion commit entered")
        let hookLock = NSLock()
        var didBlockCommit = false
        let commitMayProceed = DispatchSemaphore(value: 0)
        ConversationStore.authorityCommitTestHook = {
            hookLock.lock()
            let shouldBlock = !didBlockCommit
            didBlockCommit = true
            hookLock.unlock()
            if shouldBlock {
                commitEntered.fulfill()
                commitMayProceed.wait()
            }
        }
        defer {
            commitMayProceed.signal()
            ConversationStore.authorityCommitTestHook = nil
        }

        let acceptedDraft = "Existing draft\n\nContinue the persisted conversation."
        XCTAssertTrue(bridge.acceptSuggestedPrompt(draft: acceptedDraft))
        await fulfillment(of: [commitEntered], timeout: 2)

        let beforeCommit = try XCTUnwrap(
            try fixture.repository.conversation(id: source.id))
        XCTAssertEqual(beforeCommit.suggestedPrompt, record)
        XCTAssertNotEqual(beforeCommit.draft, acceptedDraft)
        XCTAssertEqual(store.conversation(source.id)?.draft, acceptedDraft)
        XCTAssertNil(store.conversation(source.id)?.suggestedPrompt)

        let published = expectation(description: "accepted suggestion published")
        store.awaitPublishedSnapshot(source.id) { snapshot in
            XCTAssertEqual(snapshot?.conversation.draft, acceptedDraft)
            XCTAssertNil(snapshot?.conversation.suggestedPrompt)
            published.fulfill()
        }
        commitMayProceed.signal()
        await fulfillment(of: [published], timeout: 3)
        ConversationStore.authorityCommitTestHook = nil

        let afterCommit = try XCTUnwrap(
            try fixture.repository.conversation(id: source.id))
        XCTAssertEqual(afterCommit.draft, acceptedDraft)
        XCTAssertNil(afterCommit.suggestedPrompt)

        let relaunched = ConversationStore(
            appSupportBaseOverride: fixture.root,
            watchesDirectory: false,
            residencyMode: .boundedAfterRecovery,
            libraryAuthorityRepository: fixture.repository)
        let restored = try await acquire(source.id, from: relaunched)
        XCTAssertEqual(restored.draft, acceptedDraft)
        XCTAssertNil(restored.suggestedPrompt)
    }

    func testAuthorityCommitResolvesWaiterAfterDatabaseCommitAndNeverRewritesSidecar() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let frozenLegacy = Data("frozen rollback evidence".utf8)
        try frozenLegacy.write(to: fixture.legacyURL)
        let store = ConversationStore(
            appSupportBaseOverride: fixture.root,
            watchesDirectory: false,
            residencyMode: .boundedAfterRecovery,
            libraryAuthorityRepository: fixture.repository)
        _ = try await acquire(fixture.conversation.id, from: store)

        let commitEntered = expectation(description: "authority commit entered")
        let commitMayProceed = DispatchSemaphore(value: 0)
        ConversationStore.authorityCommitTestHook = {
            commitEntered.fulfill()
            commitMayProceed.wait()
        }
        var callbackFired = false
        var databaseWasCurrentInsideCallback = false
        let waiter = expectation(description: "persistence waiter")
        _ = store.updateAwaitingPersistence(fixture.conversation.id, {
            $0.title = "Committed SQLite title"
        }) { succeeded in
            callbackFired = true
            databaseWasCurrentInsideCallback = succeeded
                && (try? fixture.repository.conversation(id: fixture.conversation.id)?.title)
                    == "Committed SQLite title"
            waiter.fulfill()
        }

        await fulfillment(of: [commitEntered], timeout: 2)
        XCTAssertFalse(callbackFired, "provider-facing waiter must remain closed before COMMIT")
        XCTAssertEqual(
            try fixture.repository.conversation(id: fixture.conversation.id)?.title,
            "SQLite is authoritative")
        commitMayProceed.signal()
        await fulfillment(of: [waiter], timeout: 3)
        ConversationStore.authorityCommitTestHook = nil

        XCTAssertTrue(databaseWasCurrentInsideCallback)
        XCTAssertEqual(try Data(contentsOf: fixture.legacyURL), frozenLegacy)

        XCTAssertNotNil(store.remove(fixture.conversation.id))
        XCTAssertNil(try fixture.repository.conversation(id: fixture.conversation.id))
        XCTAssertEqual(
            try Data(contentsOf: fixture.legacyURL),
            frozenLegacy,
            "SQLite delete must leave the frozen rollback generation untouched")
    }

    func testFreshRetryRewindCommitsBeforeExposureAndCrashRecoversPromptExactlyOnce() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let selection = ModelSelection(
            access: .claudeVertex,
            modelID: "claude-opus-4-8[1m]")
        var source = fixture.conversation
        source.modelSelection = selection
        source.sdkSessionId = "wedged-session"
        source.sdkSessionRouteIdentity = "route"
        source.sdkSessionExtensionRevision = UUID()
        source.sdkSessionWorkspaceInstructionsRevision = "instructions"
        source.contextTokens = 118_927
        source.contextWindow = 1_000_000
        source.contextModel = selection.modelID
        let prior = source.messages
        let prompt = TranscriptEntry(kind: .user, text: "Retry this exactly once")
        var failure = TranscriptEntry(kind: .system, text: "error: No response")
        failure.providerFailure = try XCTUnwrap(ProviderFailure.from(event: [
            "type": "error",
            "errorKind": "network",
            "provider": "anthropic",
            "access": "claude_vertex",
            "message": "No response",
            "providerError": [
                "providerType": "provider_no_output",
                "code": "no_output_after_fresh_replay",
                "diagnosticCode": "claude_no_output_after_fresh_replay",
                "resumed": true,
                "noProviderWork": true,
                "freshReplayAttempted": true,
            ],
        ], authoritativeAccess: .claudeVertex))
        failure.providerFailurePromptID = prompt.id
        source.messages = prior + [prompt, failure]
        _ = try fixture.repository.commit(conversation: source)

        let store = ConversationStore(
            appSupportBaseOverride: fixture.root,
            watchesDirectory: false,
            residencyMode: .boundedAfterRecovery,
            libraryAuthorityRepository: fixture.repository)
        _ = try await acquire(source.id, from: store)

        let commitEntered = expectation(description: "fresh retry commit entered")
        let commitMayProceed = DispatchSemaphore(value: 0)
        ConversationStore.authorityCommitTestHook = {
            commitEntered.fulfill()
            commitMayProceed.wait()
        }
        defer {
            commitMayProceed.signal()
            ConversationStore.authorityCommitTestHook = nil
        }
        var mutationApplied = false
        var completionSucceeded = false
        var committedSnapshot: Conversation?
        let waiter = expectation(description: "fresh retry persistence waiter")
        _ = store.updateAwaitingPersistence(source.id, { conversation in
            mutationApplied = AgentBridge.stageFreshSessionProviderFailureRetry(
                for: failure,
                selection: selection,
                in: &conversation) != nil
        }) { succeeded in
            completionSucceeded = succeeded
            committedSnapshot = try? fixture.repository.conversation(id: source.id)
            waiter.fulfill()
        }

        await fulfillment(of: [commitEntered], timeout: 2)
        XCTAssertTrue(mutationApplied)
        let beforeCommit = try XCTUnwrap(fixture.repository.conversation(id: source.id))
        XCTAssertEqual(beforeCommit.messages.last?.id, failure.id)
        XCTAssertEqual(beforeCommit.sdkSessionId, "wedged-session")
        XCTAssertNil(beforeCommit.pendingTurnPrompt)
        let provisional = try XCTUnwrap(store.conversation(source.id))
        XCTAssertEqual(provisional.messages.map(\.id), prior.map(\.id))
        XCTAssertNil(provisional.sdkSessionId)
        XCTAssertEqual(provisional.pendingTurnPrompt, prompt.text)

        commitMayProceed.signal()
        await fulfillment(of: [waiter], timeout: 3)
        ConversationStore.authorityCommitTestHook = nil
        XCTAssertTrue(completionSucceeded)
        let committed = try XCTUnwrap(committedSnapshot)
        XCTAssertEqual(committed.messages.map(\.id), prior.map(\.id))
        XCTAssertNil(committed.sdkSessionId)
        XCTAssertNil(committed.sdkSessionRouteIdentity)
        XCTAssertNil(committed.sdkSessionExtensionRevision)
        XCTAssertNil(committed.sdkSessionWorkspaceInstructionsRevision)
        XCTAssertNil(committed.contextTokens)
        XCTAssertNil(committed.contextWindow)
        XCTAssertNil(committed.contextModel)
        XCTAssertEqual(committed.pendingTurnPrompt, prompt.text)

        // This is both crash-before-start and synchronous start-failure recovery: the provider has
        // no authority to clear the slot, so cold launch quarantines one copy at the queue head and
        // never restores the removed failed prompt/error rows.
        var recovered = committed
        XCTAssertTrue(ConversationStore.healStaleState(&recovered))
        XCTAssertNil(recovered.pendingTurnPrompt)
        XCTAssertEqual(recovered.messages.map(\.id), prior.map(\.id))
        XCTAssertEqual(recovered.queuedPrompts, [prompt.text])
    }

    func testManualSendOwnerLossDuringCommitQuarantinesPromptWithoutRelaunch() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let suggestion = ConversationSuggestedPrompt(
            text: "This must retire with the next turn.",
            source: .onDevice,
            rootPromptEntryID: fixture.conversation.messages.first?.id,
            assistantEntryID: fixture.conversation.messages.last?.id)
        var source = fixture.conversation
        source.suggestedPrompt = suggestion
        _ = try fixture.repository.commit(conversation: source)
        let store = ConversationStore(
            appSupportBaseOverride: fixture.root,
            watchesDirectory: false,
            residencyMode: .boundedAfterRecovery,
            libraryAuthorityRepository: fixture.repository)
        _ = try await acquire(fixture.conversation.id, from: store)

        let commitEntered = expectation(description: "manual send commit entered")
        let commitMayProceed = DispatchSemaphore(value: 0)
        ConversationStore.authorityCommitTestHook = {
            commitEntered.fulfill()
            commitMayProceed.wait()
        }
        defer {
            commitMayProceed.signal()
            ConversationStore.authorityCommitTestHook = nil
        }

        let prompt = "Keep this manual prompt after its window closes"
        var bridge: AgentBridge? = AgentBridge(
            settingsBaseOverride: fixture.root.appendingPathComponent("manual-owner"),
            environmentOverride: [:],
            conversationStoreOverride: store)
        weak let weakBridge = bridge
        let quarantined = expectation(description: "manual prompt quarantined")
        XCTAssertTrue(bridge?.stageManualPromptForOwnerLossTesting(
            prompt,
            conversationID: fixture.conversation.id,
            selection: .init(access: .anthropicAPI, modelID: "claude-opus-4-8"),
            resolution: { started in
                XCTAssertFalse(started)
                quarantined.fulfill()
            }) == true)

        await fulfillment(of: [commitEntered], timeout: 2)
        XCTAssertEqual(
            try fixture.repository.conversation(id: source.id)?.suggestedPrompt,
            suggestion)
        XCTAssertNil(store.conversation(source.id)?.suggestedPrompt)
        bridge = nil
        XCTAssertNil(weakBridge)
        commitMayProceed.signal()
        ConversationStore.authorityCommitTestHook = nil

        await fulfillment(of: [quarantined], timeout: 2)
        let live = try XCTUnwrap(store.conversation(fixture.conversation.id))
        XCTAssertNil(live.pendingTurnPrompt)
        XCTAssertNil(live.suggestedPrompt)
        XCTAssertEqual(live.queuedPrompts.first, prompt)
        XCTAssertTrue(store.isQueuePaused(fixture.conversation.id))
        store.flushSaves()
        XCTAssertNil(try fixture.repository.conversation(id: source.id)?.suggestedPrompt)
    }

    func testManualSendDuringSlowCommitHasVisibleStoppableRootAndStopCannotDuplicatePrompt() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        var source = fixture.conversation
        source.modelSelection = .init(
            access: .anthropicAPI,
            modelID: "claude-opus-4-8")
        _ = try fixture.repository.commit(conversation: source)
        let store = ConversationStore(
            appSupportBaseOverride: fixture.root,
            watchesDirectory: false,
            residencyMode: .boundedAfterRecovery,
            libraryAuthorityRepository: fixture.repository)
        _ = try await acquire(source.id, from: store)

        let commitEntered = expectation(description: "manual prompt commit entered")
        let commitMayProceed = DispatchSemaphore(value: 0)
        let hookLock = NSLock()
        var didBlockCommit = false
        ConversationStore.authorityCommitTestHook = {
            hookLock.lock()
            let shouldBlock = !didBlockCommit
            didBlockCommit = true
            hookLock.unlock()
            if shouldBlock {
                commitEntered.fulfill()
                commitMayProceed.wait()
            }
        }
        defer {
            commitMayProceed.signal()
            ConversationStore.authorityCommitTestHook = nil
        }

        let bridge = AgentBridge(
            settingsBaseOverride: fixture.root.appendingPathComponent("bounded-root-owner"),
            environmentOverride: [:],
            conversationStoreOverride: store)
        bridge.currentID = source.id
        bridge.entries = source.messages
        defer {
            bridge.currentID = nil
            bridge.shutdown()
        }

        let prompt = "Keep this exact prompt while its commit is pending"
        let resolved = expectation(description: "manual prompt persistence resolved")
        var didDispatch = true
        XCTAssertTrue(bridge.stageBoundedManualPromptForPersistenceTesting(
            prompt,
            conversationID: source.id,
            selection: source.modelSelection!,
            resolution: { started in
                didDispatch = started
                resolved.fulfill()
            }))

        await fulfillment(of: [commitEntered], timeout: 2)
        // SQLite's own busy retries can legitimately outlast the provider's three-second start
        // acknowledgement window. No provider byte exists yet, so that watchdog must not fire or
        // install a same-generation retry barrier while persistence still owns the fence.
        try await Task.sleep(nanoseconds: 3_250_000_000)
        XCTAssertEqual(store.conversation(source.id)?.pendingTurnPrompt, prompt)
        XCTAssertTrue(bridge.currentConversationHasReservedTurn)
        XCTAssertTrue(bridge.currentConversationHasRootWork)
        XCTAssertTrue(bridge.isWorking)

        bridge.stopRootWorkForTesting(conversationID: source.id)

        XCTAssertFalse(bridge.currentConversationHasReservedTurn)
        XCTAssertFalse(bridge.currentConversationHasRootWork)
        XCTAssertNil(store.conversation(source.id)?.pendingTurnPrompt)
        XCTAssertTrue(
            store.conversation(source.id)?.queuedPrompts.isEmpty == true,
            "explicit Stop cancels the provisional prompt")

        commitMayProceed.signal()
        ConversationStore.authorityCommitTestHook = nil
        await fulfillment(of: [resolved], timeout: 3)
        XCTAssertFalse(didDispatch)
        XCTAssertTrue(
            store.conversation(source.id)?.queuedPrompts.isEmpty == true,
            "the late COMMIT callback must not resurrect a prompt cancelled by Stop")
    }

    func testPostCommitDispatchFailureRetainsRootBeforeBufferedGuidanceExactlyOnce() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        var source = fixture.conversation
        source.modelSelection = .init(
            access: .anthropicAPI,
            modelID: "claude-opus-4-8")
        _ = try fixture.repository.commit(conversation: source)
        let store = ConversationStore(
            appSupportBaseOverride: fixture.root,
            watchesDirectory: false,
            residencyMode: .boundedAfterRecovery,
            libraryAuthorityRepository: fixture.repository)
        _ = try await acquire(source.id, from: store)

        let commitEntered = expectation(description: "manual prompt commit entered")
        let commitMayProceed = DispatchSemaphore(value: 0)
        let hookLock = NSLock()
        var didBlockCommit = false
        ConversationStore.authorityCommitTestHook = {
            hookLock.lock()
            let shouldBlock = !didBlockCommit
            didBlockCommit = true
            hookLock.unlock()
            if shouldBlock {
                commitEntered.fulfill()
                commitMayProceed.wait()
            }
        }
        defer {
            commitMayProceed.signal()
            ConversationStore.authorityCommitTestHook = nil
        }

        let bridge = AgentBridge(
            settingsBaseOverride: fixture.root.appendingPathComponent("failed-dispatch-owner"),
            environmentOverride: [:],
            conversationStoreOverride: store)
        bridge.currentID = source.id
        bridge.entries = source.messages
        defer {
            bridge.currentID = nil
            bridge.shutdown()
        }

        let rootPrompt = "Keep the root ahead of its buffered guidance"
        let guidance = "Then retain this guidance exactly once"
        let resolved = expectation(description: "failed dispatch quarantined")
        var didDispatch = true
        XCTAssertTrue(bridge.stageBoundedManualPromptForPersistenceTesting(
            rootPrompt,
            conversationID: source.id,
            selection: source.modelSelection!,
            dispatchSucceeds: false,
            resolution: { started in
                didDispatch = started
                resolved.fulfill()
            }))

        await fulfillment(of: [commitEntered], timeout: 2)
        bridge.bufferStartSteerForPersistenceTesting(guidance)
        XCTAssertEqual(
            bridge.provisionalGuidanceEntriesForCurrentConversation.map(\.text),
            [guidance])

        commitMayProceed.signal()
        ConversationStore.authorityCommitTestHook = nil
        await fulfillment(of: [resolved], timeout: 3)

        XCTAssertFalse(didDispatch)
        let live = try XCTUnwrap(store.conversation(source.id))
        XCTAssertNil(live.pendingTurnPrompt)
        XCTAssertEqual(live.queuedPrompts, [rootPrompt, guidance])
        XCTAssertTrue(store.isQueuePaused(source.id))
        XCTAssertTrue(bridge.provisionalGuidanceEntriesForCurrentConversation.isEmpty)
        store.flushSaves()
        XCTAssertEqual(
            try fixture.repository.conversation(id: source.id)?.queuedPrompts,
            [rootPrompt, guidance])
    }

    func testProductionManualSendStagesItsVisibleOwnerBeforeSQLitePersistence() throws {
        let tests = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let source = tests
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/Mechanician/AgentBridge.swift")
        let text = try String(contentsOf: source, encoding: .utf8)
        let performStart = try XCTUnwrap(text.range(of: "private func performSend("))
        let performEnd = try XCTUnwrap(text.range(
            of: "private func stageManualPromptAwaitingPersistence(",
            range: performStart.upperBound..<text.endIndex))
        let body = text[performStart.lowerBound..<performEnd.lowerBound]

        let route = try XCTUnwrap(body.range(of: "turnRoutes[turnId] = route"))
        let provisionalStart = try XCTUnwrap(body.range(
            of: "stagePendingTurnStart(",
            range: route.upperBound..<body.endIndex))
        let sqliteFence = try XCTUnwrap(body.range(
            of: "if case .manual = origin, store.usesSQLiteAuthority"))
        XCTAssertLessThan(provisionalStart.lowerBound, sqliteFence.lowerBound)
        XCTAssertTrue(body[provisionalStart.lowerBound..<sqliteFence.lowerBound].contains(
            "armsProviderAcknowledgementTimeout: false"))

        let providerWrite = try XCTUnwrap(body.range(
            of: "guard self.write(req, to: selection.access)"))
        let acknowledgedStart = try XCTUnwrap(body.range(
            of: "self.stagePendingTurnStart(",
            range: providerWrite.upperBound..<sqliteFence.lowerBound))
        XCTAssertLessThan(providerWrite.lowerBound, acknowledgedStart.lowerBound)
    }

    func testProviderAccessRecoveryConvergesForegroundBeforePromptAcknowledgement() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let selection = ModelSelection(
            access: .claudeVertex,
            modelID: "claude-opus-4-8")
        var source = fixture.conversation
        source.modelSelection = selection
        let prior = source.messages
        let rejected = TranscriptEntry(
            kind: .user,
            text: "Resume this Vertex prompt exactly once")
        var failure = TranscriptEntry(kind: .system, text: "Google sign-in is required")
        failure.providerFailure = try XCTUnwrap(ProviderFailure.from(event: [
            "type": "error",
            "errorKind": "authentication",
            "provider": "anthropic",
            "access": "claude_vertex",
            "message": "Google requires a fresh sign-in.",
            "reconnectRequired": true,
        ], authoritativeAccess: .claudeVertex))
        failure.providerFailurePromptID = rejected.id
        source.messages = prior + [rejected, failure]
        source.providerAccessRequest = ProviderAccessRequest(
            maker: .anthropic,
            reason: "Google requires a fresh sign-in.",
            resumePrompts: [rejected.text],
            selectedAccess: .claudeVertex,
            recoveryAccess: .claudeVertex,
            recoveryPromptEntryID: rejected.id)
        source.errored = true
        _ = try fixture.repository.commit(conversation: source)

        let store = ConversationStore(
            appSupportBaseOverride: fixture.root,
            watchesDirectory: false,
            residencyMode: .boundedAfterRecovery,
            libraryAuthorityRepository: fixture.repository)
        _ = try await acquire(source.id, from: store)
        let bridge = AgentBridge(
            settingsBaseOverride: fixture.root.appendingPathComponent("provider-recovery-viewer"),
            environmentOverride: [:],
            conversationStoreOverride: store)
        bridge.currentID = source.id
        bridge.cwd = source.cwd
        bridge.entries = source.messages
        bridge.queuedPrompts = []
        AgentBridge.live.add(bridge)
        let recoveryTurnID = "provider-recovery-foreground"
        defer {
            bridge.stopRootWorkForTesting(conversationID: source.id)
            bridge.acknowledgeRootStopForTesting(turnID: recoveryTurnID)
            bridge.currentID = nil
            AgentBridge.live.remove(bridge)
            store.flushSaves()
        }

        var fulfilled = try XCTUnwrap(store.conversation(source.id))
        let requestID = try XCTUnwrap(fulfilled.providerAccessRequest?.id)
        XCTAssertTrue(fulfilled.fulfillProviderAccess(
            requestID: requestID,
            access: .claudeVertex,
            modelID: selection.modelID))
        store.upsert(fulfilled)
        let updated = try XCTUnwrap(store.conversation(source.id))

        bridge.adoptFulfilledProviderAccessState(updated)

        XCTAssertEqual(bridge.entries.map(\.id), prior.map(\.id))
        XCTAssertEqual(updated.messages.map(\.id), prior.map(\.id))
        XCTAssertEqual(bridge.queuedPrompts, [rejected.text])
        XCTAssertNil(updated.providerAccessRequest)
        XCTAssertFalse(bridge.pendingHistoryReplayForTesting().contains { payload in
            payload.values.contains { $0.contains(rejected.text) }
        })

        store.update(source.id) { conversation in
            conversation.queuedPrompts.removeAll()
            conversation.pendingTurnPrompt = rejected.text
        }
        bridge.queuedPrompts.removeAll()
        bridge.stageRootWorkForTesting(
            conversationID: source.id,
            turnID: recoveryTurnID,
            selection: selection,
            pendingPrompt: rejected.text)
        bridge.acknowledgeRootStartForTesting(
            turnID: recoveryTurnID,
            access: .claudeVertex)

        let live = try XCTUnwrap(store.conversation(source.id))
        XCTAssertEqual(
            bridge.entries.filter { $0.kind == .user && $0.text == rejected.text }.count,
            1)
        XCTAssertEqual(
            live.messages.filter { $0.kind == .user && $0.text == rejected.text }.count,
            1)
        XCTAssertFalse(bridge.entries.contains { $0.id == failure.id })
        XCTAssertFalse(live.messages.contains { $0.id == failure.id })
        XCTAssertNil(live.providerAccessRequest)
        XCTAssertTrue(live.queuedPrompts.isEmpty)
        XCTAssertNil(live.pendingTurnPrompt)
    }

    func testParkingBlockedQueueSynchronizesEveryViewerBeforeEitherCanRefold() async throws {
        _ = NSApplication.shared
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let access = ModelAccess.claudeVertex
        let prompt = "Preserve this queued prompt once"
        var source = fixture.conversation
        source.modelSelection = ModelSelection(
            access: access,
            modelID: "claude-opus-4-8")
        source.queuedPrompts = [prompt]
        _ = try fixture.repository.commit(conversation: source)

        let store = ConversationStore(
            appSupportBaseOverride: fixture.root,
            watchesDirectory: false,
            residencyMode: .boundedAfterRecovery,
            libraryAuthorityRepository: fixture.repository)
        _ = try await acquire(source.id, from: store)
        let first = AgentBridge(
            settingsBaseOverride: fixture.root.appendingPathComponent("provider-park-first"),
            environmentOverride: [:],
            conversationStoreOverride: store)
        let second = AgentBridge(
            settingsBaseOverride: fixture.root.appendingPathComponent("provider-park-second"),
            environmentOverride: [:],
            conversationStoreOverride: store)
        for bridge in [first, second] {
            bridge.currentID = source.id
            bridge.cwd = source.cwd
            bridge.entries = source.messages
            bridge.queuedPrompts = [prompt]
            AgentBridge.live.add(bridge)
        }
        defer {
            for bridge in [first, second] {
                bridge.currentID = nil
                AgentBridge.live.remove(bridge)
                bridge.shutdown()
            }
            store.flushSaves()
        }

        XCTAssertTrue(first.parkBlockedQueuedWorkForTesting(
            conversationID: source.id,
            access: access))
        let parked = try XCTUnwrap(store.conversation(source.id))
        XCTAssertTrue(parked.queuedPrompts.isEmpty)
        XCTAssertEqual(parked.providerAccessRequest?.resumePrompts, [prompt])
        XCTAssertTrue(first.queuedPrompts.isEmpty)
        XCTAssertTrue(second.queuedPrompts.isEmpty)

        let refolded = expectation(description: "second viewer refolded canonical queue")
        second.persistCurrentForStopRecoveryTesting { persisted in
            XCTAssertTrue(persisted)
            refolded.fulfill()
        }
        await fulfillment(of: [refolded], timeout: 2)

        let afterRefold = try XCTUnwrap(store.conversation(source.id))
        XCTAssertTrue(afterRefold.queuedPrompts.isEmpty)
        XCTAssertEqual(afterRefold.providerAccessRequest?.resumePrompts, [prompt])
    }

    func testCancellingAuthenticationRecoveryReleasesUsableLaneQueueInFIFOOrder() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let access = ModelAccess.anthropicAPI
        let selection = ModelSelection(access: access, modelID: "claude-api")
        let rejected = TranscriptEntry(kind: .user, text: "Rejected API root")
        var failure = TranscriptEntry(kind: .system, text: "error: API authentication failed")
        failure.providerFailure = ProviderFailure(
            kind: .authentication,
            provider: .anthropic,
            access: access,
            message: "The API credential was rejected.")
        failure.providerFailurePromptID = rejected.id
        let request = ProviderAccessRequest(
            maker: .anthropic,
            reason: "Choose a working Anthropic route.",
            resumePrompts: [rejected.text],
            selectedAccess: access,
            recoveryAccess: access,
            recoveryPromptEntryID: rejected.id)
        let firstFollowup = "Run follow-up A"
        let secondFollowup = "Run follow-up B"
        var source = fixture.conversation
        source.modelSelection = selection
        source.messages = [rejected, failure]
        source.providerAccessRequest = request
        source.queuedPrompts = []
        _ = try fixture.repository.commit(conversation: source)

        let store = ConversationStore(
            appSupportBaseOverride: fixture.root,
            watchesDirectory: false,
            residencyMode: .boundedAfterRecovery,
            libraryAuthorityRepository: fixture.repository)
        _ = try await acquire(source.id, from: store)
        store.update(source.id) {
            $0.queuedPrompts = [firstFollowup, secondFollowup]
        }
        let bridge = AgentBridge(
            settingsBaseOverride: fixture.root.appendingPathComponent("provider-cancel-runtime"),
            environmentOverride: [:],
            conversationStoreOverride: store)
        bridge.currentID = source.id
        bridge.cwd = source.cwd
        bridge.entries = source.messages
        bridge.queuedPrompts = [firstFollowup, secondFollowup]
        AgentBridge.live.add(bridge)

        let runtimeLaunched = expectation(description: "provider cancellation runtime launched")
        let firstPromptWritten = expectation(description: "first retained follow-up written once")
        firstPromptWritten.assertForOverFulfill = true
        let records = ProviderAccessRuntimeRecordBox()
        let runtime = AgentdRuntime(
            access: access,
            onEvent: { _, _ in },
            onLaunchFailure: { _, detail in XCTFail("fixture launch failed: \(detail)") },
            onUnexpectedExit: { _, _ in XCTFail("fixture runtime is stopped intentionally") },
            processStarter: { process in
                process.executableURL = URL(fileURLWithPath: "/bin/sh")
                process.arguments = ["-c", "trap 'exit 0' TERM; while :; do sleep 1; done"]
                do {
                    try process.run()
                    runtimeLaunched.fulfill()
                    return nil
                } catch {
                    return error.localizedDescription
                }
            },
            recordWriter: { _, data in
                records.append(data)
                guard let payload = try? JSONSerialization.jsonObject(
                    with: Data(data.dropLast())) as? [String: Any],
                    payload["type"] as? String == "send" else { return }
                firstPromptWritten.fulfill()
            })
        runtime.start()
        defer {
            bridge.stopRootWorkForTesting(conversationID: source.id)
            bridge.currentID = nil
            AgentBridge.live.remove(bridge)
            bridge.shutdown()
            store.flushSaves()
        }

        await fulfillment(of: [runtimeLaunched], timeout: 2)
        bridge.installUsableProviderRuntimeForTesting(
            access: access,
            generation: UUID(),
            runtime: runtime)

        bridge.cancelProviderAccessRequest(request.id)

        await fulfillment(of: [firstPromptWritten], timeout: 3)
        let sends = records.snapshot().compactMap { data -> [String: Any]? in
            guard let payload = try? JSONSerialization.jsonObject(
                with: Data(data.dropLast())) as? [String: Any],
                payload["type"] as? String == "send" else { return nil }
            return payload
        }
        XCTAssertEqual(sends.count, 1)
        let payload = try XCTUnwrap(sends.first)
        XCTAssertEqual(payload["prompt"] as? String, firstFollowup)
        let turnID = try XCTUnwrap(payload["id"] as? String)
        bridge.acknowledgeRootStartForTesting(turnID: turnID, access: access)

        try await Task.sleep(nanoseconds: 100_000_000)
        let sendsAfterAcknowledgement = records.snapshot().compactMap { data -> [String: Any]? in
            guard let payload = try? JSONSerialization.jsonObject(
                with: Data(data.dropLast())) as? [String: Any],
                payload["type"] as? String == "send" else { return nil }
            return payload
        }
        XCTAssertEqual(sendsAfterAcknowledgement.count, 1)
        let updated = try XCTUnwrap(store.conversation(source.id))
        XCTAssertNil(updated.providerAccessRequest)
        XCTAssertEqual(updated.queuedPrompts, [secondFollowup])
        XCTAssertNil(updated.pendingTurnPrompt)
        XCTAssertEqual(
            updated.messages.filter { $0.kind == .user && $0.text == firstFollowup }.count,
            1)
        XCTAssertTrue(updated.messages.contains { $0.id == rejected.id })
        XCTAssertTrue(updated.messages.contains { $0.id == failure.id })
    }

    func testRelaunchPausedAuthenticationRecoveryReleasesOnlyFulfilledQueue() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let access = ModelAccess.anthropicAPI
        let selection = ModelSelection(access: access, modelID: "claude-api")
        let rejected = TranscriptEntry(kind: .user, text: "Resume rejected root")
        var failure = TranscriptEntry(kind: .system, text: "error: API authentication failed")
        failure.providerFailure = ProviderFailure(
            kind: .authentication,
            provider: .anthropic,
            access: access,
            message: "The API credential was rejected.")
        failure.providerFailurePromptID = rejected.id
        let request = ProviderAccessRequest(
            maker: .anthropic,
            reason: "Choose a working Anthropic route.",
            resumePrompts: [rejected.text],
            selectedAccess: access,
            recoveryAccess: access,
            recoveryPromptEntryID: rejected.id)
        let followup = "Run this after the recovered root"
        var source = fixture.conversation
        source.modelSelection = selection
        source.messages += [rejected, failure]
        source.providerAccessRequest = request
        source.queuedPrompts = [followup]
        source.errored = true
        _ = try fixture.repository.commit(conversation: source)

        let unrelatedPrompt = "Keep this unrelated launch queue paused"
        let unrelated = Conversation(
            title: "Unrelated recovered queue",
            cwd: source.cwd,
            sdkSessionId: nil,
            modelSelection: selection,
            messages: [],
            updatedAt: source.updatedAt,
            queuedPrompts: [unrelatedPrompt])
        _ = try fixture.repository.commit(conversation: unrelated)

        // Loading a SQLite authority deliberately quarantines both nonempty queues. Provider
        // recovery must release only the exact request it fulfills, never every queue on the lane.
        let store = ConversationStore(
            appSupportBaseOverride: fixture.root,
            watchesDirectory: false,
            residencyMode: .boundedAfterRecovery,
            libraryAuthorityRepository: fixture.repository)
        _ = try await acquire(source.id, from: store)
        _ = try await acquire(unrelated.id, from: store)
        XCTAssertTrue(store.isQueuePaused(source.id))
        XCTAssertTrue(store.isQueuePaused(unrelated.id))

        let bridge = AgentBridge(
            settingsBaseOverride: fixture.root.appendingPathComponent("provider-relaunch-runtime"),
            environmentOverride: [:],
            conversationStoreOverride: store)
        bridge.currentID = source.id
        bridge.cwd = source.cwd
        bridge.entries = source.messages
        bridge.queuedPrompts = [followup]
        AgentBridge.live.add(bridge)

        let runtimeLaunched = expectation(description: "recovered provider runtime launched")
        let recoveredPromptWritten = expectation(description: "recovered root written once")
        recoveredPromptWritten.assertForOverFulfill = true
        let records = ProviderAccessRuntimeRecordBox()
        let runtime = AgentdRuntime(
            access: access,
            onEvent: { _, _ in },
            onLaunchFailure: { _, detail in XCTFail("fixture launch failed: \(detail)") },
            onUnexpectedExit: { _, _ in XCTFail("fixture runtime is stopped intentionally") },
            processStarter: { process in
                process.executableURL = URL(fileURLWithPath: "/bin/sh")
                process.arguments = ["-c", "trap 'exit 0' TERM; while :; do sleep 1; done"]
                do {
                    try process.run()
                    runtimeLaunched.fulfill()
                    return nil
                } catch {
                    return error.localizedDescription
                }
            },
            recordWriter: { _, data in
                records.append(data)
                guard let payload = try? JSONSerialization.jsonObject(
                    with: Data(data.dropLast())) as? [String: Any],
                    payload["type"] as? String == "send" else { return }
                recoveredPromptWritten.fulfill()
            })
        runtime.start()
        defer {
            bridge.stopRootWorkForTesting(conversationID: source.id)
            bridge.currentID = nil
            AgentBridge.live.remove(bridge)
            bridge.shutdown()
            store.flushSaves()
        }

        await fulfillment(of: [runtimeLaunched], timeout: 2)
        bridge.installUsableProviderRuntimeForTesting(
            access: access,
            generation: UUID(),
            runtime: runtime,
            providerAccessModelID: selection.modelID)

        bridge.resumeProviderAccessRequests(for: access)

        XCTAssertFalse(store.isQueuePaused(source.id))
        XCTAssertTrue(store.isQueuePaused(unrelated.id))
        await fulfillment(of: [recoveredPromptWritten], timeout: 3)
        let sends = records.snapshot().compactMap { data -> [String: Any]? in
            guard let payload = try? JSONSerialization.jsonObject(
                with: Data(data.dropLast())) as? [String: Any],
                payload["type"] as? String == "send" else { return nil }
            return payload
        }
        XCTAssertEqual(sends.count, 1)
        XCTAssertEqual(sends.first?["prompt"] as? String, rejected.text)
        XCTAssertFalse(sends.contains { $0["prompt"] as? String == unrelatedPrompt })
        let turnID = try XCTUnwrap(sends.first?["id"] as? String)
        bridge.acknowledgeRootStartForTesting(turnID: turnID, access: access)

        try await Task.sleep(nanoseconds: 100_000_000)
        let updated = try XCTUnwrap(store.conversation(source.id))
        XCTAssertNil(updated.providerAccessRequest)
        XCTAssertEqual(updated.queuedPrompts, [followup])
        XCTAssertNil(updated.pendingTurnPrompt)
        XCTAssertEqual(
            updated.messages.filter { $0.kind == .user && $0.text == rejected.text }.count,
            1)
        XCTAssertFalse(updated.messages.contains { $0.id == failure.id })
        XCTAssertEqual(store.conversation(unrelated.id)?.queuedPrompts, [unrelatedPrompt])
    }

    func testVertexReauthenticationResumesItsPreservedPromptExactlyOnce() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let access = ModelAccess.claudeVertex
        let selection = ModelSelection(access: access, modelID: "claude-opus-4-8")
        let rejected = TranscriptEntry(
            kind: .user,
            text: "Resume this preserved Vertex prompt exactly once")
        var failure = TranscriptEntry(kind: .system, text: "Google sign-in is required")
        failure.providerFailure = try XCTUnwrap(ProviderFailure.from(event: [
            "type": "error",
            "errorKind": "authentication",
            "provider": "anthropic",
            "access": "claude_vertex",
            "message": "Google requires a fresh sign-in.",
            "reconnectRequired": true,
        ], authoritativeAccess: access))
        failure.providerFailurePromptID = rejected.id
        var source = fixture.conversation
        source.modelSelection = selection
        source.messages += [rejected, failure]
        source.providerAccessRequest = ProviderAccessRequest(
            maker: .anthropic,
            reason: "Google requires a fresh sign-in.",
            resumePrompts: [rejected.text],
            selectedAccess: access,
            recoveryAccess: access,
            recoveryPromptEntryID: rejected.id)
        source.errored = true
        _ = try fixture.repository.commit(conversation: source)

        let store = ConversationStore(
            appSupportBaseOverride: fixture.root,
            watchesDirectory: false,
            residencyMode: .boundedAfterRecovery,
            libraryAuthorityRepository: fixture.repository)
        _ = try await acquire(source.id, from: store)

        let bridge = AgentBridge(
            settingsBaseOverride: fixture.root.appendingPathComponent("vertex-reauth-runtime"),
            environmentOverride: [:],
            conversationStoreOverride: store)
        bridge.currentID = source.id
        bridge.cwd = source.cwd
        bridge.entries = source.messages
        bridge.queuedPrompts = []
        AgentBridge.live.add(bridge)

        let runtimeLaunched = expectation(description: "re-authenticated Vertex runtime launched")
        let promptWritten = expectation(description: "preserved Vertex prompt written once")
        promptWritten.assertForOverFulfill = true
        let records = ProviderAccessRuntimeRecordBox()
        let runtime = AgentdRuntime(
            access: access,
            onEvent: { _, _ in },
            onLaunchFailure: { _, detail in XCTFail("fixture launch failed: \(detail)") },
            onUnexpectedExit: { _, _ in XCTFail("fixture runtime is stopped intentionally") },
            processStarter: { process in
                process.executableURL = URL(fileURLWithPath: "/bin/sh")
                process.arguments = ["-c", "trap 'exit 0' TERM; while :; do sleep 1; done"]
                do {
                    try process.run()
                    runtimeLaunched.fulfill()
                    return nil
                } catch {
                    return error.localizedDescription
                }
            },
            recordWriter: { _, data in
                records.append(data)
                guard let payload = try? JSONSerialization.jsonObject(
                    with: Data(data.dropLast())) as? [String: Any],
                    payload["type"] as? String == "send" else { return }
                promptWritten.fulfill()
            })
        runtime.start()
        defer {
            bridge.stopRootWorkForTesting(conversationID: source.id)
            bridge.currentID = nil
            AgentBridge.live.remove(bridge)
            bridge.shutdown()
            store.flushSaves()
        }

        await fulfillment(of: [runtimeLaunched], timeout: 2)
        bridge.installUsableProviderRuntimeForTesting(
            access: access,
            generation: UUID(),
            runtime: runtime,
            providerAccessModelID: selection.modelID)

        // A Google reauthentication can yield both an account-ready edge and the signed Vertex
        // catalog edge. Replaying either callback must not duplicate the rejected root.
        bridge.resumeProviderAccessRequests(for: access)
        bridge.resumeProviderAccessRequests(for: access)

        await fulfillment(of: [promptWritten], timeout: 3)
        let sends = records.snapshot().compactMap { data -> [String: Any]? in
            guard let payload = try? JSONSerialization.jsonObject(
                with: Data(data.dropLast())) as? [String: Any],
                payload["type"] as? String == "send" else { return nil }
            return payload
        }
        XCTAssertEqual(sends.count, 1)
        XCTAssertEqual(sends.first?["prompt"] as? String, rejected.text)
        let turnID = try XCTUnwrap(sends.first?["id"] as? String)
        bridge.acknowledgeRootStartForTesting(turnID: turnID, access: access)

        try await Task.sleep(nanoseconds: 100_000_000)
        let updated = try XCTUnwrap(store.conversation(source.id))
        XCTAssertNil(updated.providerAccessRequest)
        XCTAssertTrue(updated.queuedPrompts.isEmpty)
        XCTAssertNil(updated.pendingTurnPrompt)
        XCTAssertEqual(
            updated.messages.filter { $0.kind == .user && $0.text == rejected.text }.count,
            1)
        XCTAssertFalse(updated.messages.contains { $0.id == failure.id })
    }

    func testQueuedSendOwnerLossDuringCommitQuarantinesExactHeadWithoutRelaunch() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        var source = fixture.conversation
        source.modelSelection = .init(access: .anthropicAPI, modelID: "claude-opus-4-8")
        source.queuedPrompts = ["reserved head", "second prompt"]
        source.suggestedPrompt = ConversationSuggestedPrompt(
            text: "Retire this when the queued turn starts.",
            source: .onDevice,
            rootPromptEntryID: source.messages.first?.id,
            assistantEntryID: source.messages.last?.id)
        _ = try fixture.repository.commit(conversation: source)
        let store = ConversationStore(
            appSupportBaseOverride: fixture.root,
            watchesDirectory: false,
            residencyMode: .boundedAfterRecovery,
            libraryAuthorityRepository: fixture.repository)
        _ = try await acquire(source.id, from: store)

        let commitEntered = expectation(description: "queue reservation commit entered")
        let commitMayProceed = DispatchSemaphore(value: 0)
        ConversationStore.authorityCommitTestHook = {
            commitEntered.fulfill()
            commitMayProceed.wait()
        }
        defer {
            commitMayProceed.signal()
            ConversationStore.authorityCommitTestHook = nil
        }

        var bridge: AgentBridge? = AgentBridge(
            settingsBaseOverride: fixture.root.appendingPathComponent("queue-owner"),
            environmentOverride: [:],
            conversationStoreOverride: store)
        weak let weakBridge = bridge
        let quarantined = expectation(description: "reserved head quarantined")
        bridge?.reserveQueuedPromptForOwnerLossTesting(
            conversationID: source.id,
            completion: { started in
                XCTAssertFalse(started)
                quarantined.fulfill()
            })

        await fulfillment(of: [commitEntered], timeout: 2)
        XCTAssertNotNil(try fixture.repository.conversation(id: source.id)?.suggestedPrompt)
        XCTAssertNil(store.conversation(source.id)?.suggestedPrompt)
        bridge = nil
        XCTAssertNil(weakBridge)
        commitMayProceed.signal()
        ConversationStore.authorityCommitTestHook = nil

        await fulfillment(of: [quarantined], timeout: 2)
        let live = try XCTUnwrap(store.conversation(source.id))
        XCTAssertNil(live.pendingTurnPrompt)
        XCTAssertNil(live.suggestedPrompt)
        XCTAssertEqual(live.queuedPrompts, ["reserved head", "second prompt"])
        XCTAssertTrue(store.isQueuePaused(source.id))
        store.flushSaves()
        XCTAssertNil(try fixture.repository.conversation(id: source.id)?.suggestedPrompt)
    }

    func testCrossAccessRetargetDoesNotPublishProviderBoundaryBeforeCommit() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        var source = fixture.conversation
        source.modelSelection = .init(
            access: .anthropicAPI,
            modelID: "claude-opus-4-8")
        source.sdkSessionId = "old-provider-session"
        source.sdkSessionExtensionRevision = UUID()
        _ = try fixture.repository.commit(conversation: source)
        let store = ConversationStore(
            appSupportBaseOverride: fixture.root,
            watchesDirectory: false,
            residencyMode: .boundedAfterRecovery,
            libraryAuthorityRepository: fixture.repository)
        _ = try await acquire(source.id, from: store)
        let bridge = AgentBridge(
            settingsBaseOverride: fixture.root.appendingPathComponent("retarget-owner"),
            environmentOverride: [:],
            conversationStoreOverride: store)
        bridge.currentID = source.id
        bridge.entries = source.messages

        let commitEntered = expectation(description: "retarget commit entered")
        let hookLock = NSLock()
        var didHoldCommit = false
        let commitMayProceed = DispatchSemaphore(value: 0)
        ConversationStore.authorityCommitTestHook = {
            hookLock.lock()
            let shouldHold = !didHoldCommit
            didHoldCommit = true
            hookLock.unlock()
            if shouldHold {
                commitEntered.fulfill()
                commitMayProceed.wait()
            }
        }
        defer {
            commitMayProceed.signal()
            ConversationStore.authorityCommitTestHook = nil
            bridge.currentID = nil
            bridge.shutdown()
        }

        let replacement = ModelSelection(
            access: .openAIAPI,
            modelID: "gpt-5.4")
        var persistenceResolved = false
        let committed = expectation(description: "retarget persistence resolved")
        bridge.retargetCurrentConversationForPersistenceTesting(to: replacement) { succeeded in
            persistenceResolved = succeeded
            committed.fulfill()
        }

        await fulfillment(of: [commitEntered], timeout: 2)
        XCTAssertFalse(persistenceResolved)
        XCTAssertFalse(
            store.isDurablyCurrent(source.id),
            "provider prewarm and native Review must stay closed while retarget is provisional")
        let beforeCommit = try XCTUnwrap(
            try fixture.repository.conversation(id: source.id))
        XCTAssertEqual(beforeCommit.modelSelection, source.modelSelection)
        XCTAssertEqual(beforeCommit.sdkSessionId, "old-provider-session")

        commitMayProceed.signal()
        await fulfillment(of: [committed], timeout: 3)
        ConversationStore.authorityCommitTestHook = nil
        XCTAssertTrue(persistenceResolved)
        XCTAssertTrue(store.isDurablyCurrent(source.id))
        let afterCommit = try XCTUnwrap(
            try fixture.repository.conversation(id: source.id))
        XCTAssertEqual(afterCommit.modelSelection, replacement)
        XCTAssertNil(afterCommit.sdkSessionId)
        XCTAssertNil(afterCommit.sdkSessionExtensionRevision)
    }

    func testSelectedAuthorityWithoutRepositoryFailsClosedInsteadOfScanningOrWritingJSON() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "sqlite-authority-fail-closed-\(UUID().uuidString)",
            isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("conversations", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let legacy = Conversation(
            title: "Legacy must stay fenced",
            cwd: "",
            sdkSessionId: nil,
            messages: [TranscriptEntry(kind: .user, text: "do not load me")],
            updatedAt: Date(timeIntervalSinceReferenceDate: 43_000))
        let url = directory.appendingPathComponent("\(legacy.id.uuidString).json")
        let bytes = try ConversationStore.makeEncoder().encode(legacy)
        try bytes.write(to: url)

        let store = ConversationStore(
            appSupportBaseOverride: root,
            watchesDirectory: true,
            loadsAsynchronously: false,
            residencyMode: .boundedAfterRecovery,
            libraryAuthorityRepository: nil,
            selectsSQLiteAuthorityForTesting: true)
        XCTAssertTrue(store.usesSQLiteAuthority)
        XCTAssertFalse(store.isReady)
        XCTAssertFalse(store.hasConversation(legacy.id))
        XCTAssertEqual(store.directoryWatcherStartCount, 0)
        var launchResolutionReported = false
        store.whenLaunchInventoryResolved { launchResolutionReported = true }
        XCTAssertTrue(
            launchResolutionReported,
            "fail-closed launch must still release the app to present its error surface")

        var replacement = legacy
        replacement.title = "must not overwrite frozen Legacy"
        store.upsert(replacement)
        store.flushSaves()
        XCTAssertEqual(try Data(contentsOf: url), bytes)
        XCTAssertNotNil(store.persistenceError)
    }

    func testConversationWorkEvidenceAsyncReadReturnsFailureInsteadOfEmptySuccess() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let evidence = makeWorkEvidence(conversationID: fixture.conversation.id, suffix: "read")
        _ = try fixture.repository.recordConversationWorkEvidence(
            repository: evidence.repository,
            files: evidence.files)
        let store = ConversationStore(
            appSupportBaseOverride: fixture.root,
            watchesDirectory: false,
            libraryAuthorityRepository: fixture.repository)

        ConversationStore.conversationWorkEvidenceReadTestHook = {
            throw CocoaError(.fileReadUnknown)
        }
        let failed = expectation(description: "evidence read reported its failure")
        store.loadConversationWorkEvidence(repositoryID: evidence.repository.repositoryID) { result in
            guard case .failure = result else {
                XCTFail("a read failure was converted into an empty authoritative result")
                failed.fulfill()
                return
            }
            failed.fulfill()
        }
        await fulfillment(of: [failed], timeout: 2)

        ConversationStore.conversationWorkEvidenceReadTestHook = nil
        let recovered = expectation(description: "evidence read recovered")
        store.loadConversationWorkEvidence(repositoryID: evidence.repository.repositoryID) { result in
            XCTAssertEqual(try? result.get(), [evidence])
            recovered.fulfill()
        }
        await fulfillment(of: [recovered], timeout: 2)
    }

    func testFailedConversationWorkEvidenceSurvivesUnrelatedSaveAndRetriesExactly() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let store = ConversationStore(
            appSupportBaseOverride: fixture.root,
            watchesDirectory: false,
            libraryAuthorityRepository: fixture.repository)
        let evidence = makeWorkEvidence(conversationID: fixture.conversation.id, suffix: "retry")
        ConversationStore.conversationWorkEvidenceWriteTestHook = {
            throw CocoaError(.fileWriteUnknown)
        }
        let failurePublished = expectation(description: "evidence failure retained")
        var cancellables = Set<AnyCancellable>()
        store.$persistenceError
            .compactMap { $0 }
            .prefix(1)
            .sink { _ in failurePublished.fulfill() }
            .store(in: &cancellables)

        store.recordConversationWorkEvidence(
            repository: evidence.repository,
            files: evidence.files)
        await fulfillment(of: [failurePublished], timeout: 3)
        XCTAssertEqual(store.failedConversationWorkEvidenceWriteCountForTesting, 1)
        XCTAssertTrue(
            try fixture.repository.conversationWorkEvidence(
                conversationID: fixture.conversation.id).isEmpty)

        ConversationStore.conversationWorkEvidenceWriteTestHook = nil
        let unrelatedSave = expectation(description: "unrelated Conversation save completed")
        _ = store.updateAwaitingPersistence(fixture.conversation.id, {
            $0.title = "Unrelated successful save"
        }) { succeeded in
            XCTAssertTrue(succeeded)
            unrelatedSave.fulfill()
        }
        await fulfillment(of: [unrelatedSave], timeout: 3)
        XCTAssertNotNil(
            store.persistenceError,
            "an unrelated successful save must not clear retained evidence failure")
        XCTAssertEqual(store.failedConversationWorkEvidenceWriteCountForTesting, 1)

        store.retryFailedSaves()
        let retried = expectation(description: "retained evidence committed")
        store.loadConversationWorkEvidence(repositoryID: evidence.repository.repositoryID) { result in
            XCTAssertEqual(try? result.get(), [evidence])
            retried.fulfill()
        }
        await fulfillment(of: [retried], timeout: 3)
        XCTAssertEqual(store.failedConversationWorkEvidenceWriteCountForTesting, 0)
        XCTAssertNil(store.persistenceError)
        _ = cancellables
    }

    func testSQLiteDeleteUndoRestoresExactConversationWorkEvidence() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let store = ConversationStore(
            appSupportBaseOverride: fixture.root,
            watchesDirectory: false,
            libraryAuthorityRepository: fixture.repository)
        let evidence = makeWorkEvidence(conversationID: fixture.conversation.id, suffix: "undo")
        _ = try fixture.repository.recordConversationWorkEvidence(
            repository: evidence.repository,
            files: evidence.files)

        let receipt = try XCTUnwrap(store.remove(fixture.conversation.id))
        XCTAssertEqual(receipt.workEvidence, [evidence])
        XCTAssertTrue(
            try fixture.repository.conversationWorkEvidence(
                conversationID: fixture.conversation.id).isEmpty,
            "the cascading delete should remove live evidence until Undo")

        XCTAssertTrue(store.restore(receipt))
        store.flushSaves()
        XCTAssertEqual(
            try fixture.repository.conversationWorkEvidence(
                conversationID: fixture.conversation.id),
            [evidence])
    }

    func testSQLitePermanentDeleteDoesNotRetainConversationWorkEvidence() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let store = ConversationStore(
            appSupportBaseOverride: fixture.root,
            watchesDirectory: false,
            libraryAuthorityRepository: fixture.repository)
        let evidence = makeWorkEvidence(
            conversationID: fixture.conversation.id,
            suffix: "permanent")
        _ = try fixture.repository.recordConversationWorkEvidence(
            repository: evidence.repository,
            files: evidence.files)

        XCTAssertNil(store.remove(fixture.conversation.id, permanently: true))
        store.flushSaves()
        XCTAssertTrue(
            try fixture.repository.conversationWorkEvidence(
                conversationID: fixture.conversation.id).isEmpty)
    }

    func testActiveAuthorityPersistsTransientOperationProvenance() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let store = ConversationStore(
            appSupportBaseOverride: fixture.root,
            watchesDirectory: false,
            residencyMode: .boundedAfterRecovery,
            libraryAuthorityRepository: fixture.repository)
        let capture = try LibraryTransientOperationCaptureFactory.artifactDelete(
            artifactID: UUID(), ownerConversationID: nil)

        XCTAssertTrue(store.recordsTransientOperations)
        store.recordTransientOperations([capture])
        store.flushSaves()

        var database: OpaquePointer?
        let databaseURL = fixture.root.appendingPathComponent("library.db")
        XCTAssertEqual(
            sqlite3_open_v2(databaseURL.path, &database, SQLITE_OPEN_READONLY, nil),
            SQLITE_OK)
        defer { if let database { sqlite3_close_v2(database) } }
        var statement: OpaquePointer?
        XCTAssertEqual(
            sqlite3_prepare_v2(
                database,
                "SELECT COUNT(*) FROM operations WHERE id = ?1",
                -1,
                &statement,
                nil),
            SQLITE_OK)
        defer { if let statement { sqlite3_finalize(statement) } }
        sqlite3_bind_text(
            statement,
            1,
            capture.operation.id.uuidString,
            -1,
            unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        XCTAssertEqual(sqlite3_step(statement), SQLITE_ROW)
        XCTAssertEqual(sqlite3_column_int(statement, 0), 1)
    }
}
