import Darwin
import Foundation
import XCTest
@testable import Mechanician

@MainActor
final class TranscriptCheckpointAbnormalExitTests: XCTestCase {
    private static let childModeKey = "MECHANICIAN_CHECKPOINT_CHILD_MODE"
    private static let supportKey = "MECHANICIAN_CHECKPOINT_SUPPORT_ROOT"
    private static let readyKey = "MECHANICIAN_CHECKPOINT_READY_FILE"
    private static let foregroundID = UUID(
        uuidString: "7C56019C-2042-4A39-AF2E-000000000001")!
    private static let backgroundID = UUID(
        uuidString: "7C56019C-2042-4A39-AF2E-000000000002")!
    private static let foregroundTail = "foreground partial survived"
    private static let backgroundTail = "background partial survived"

    /// This one test re-enters itself in a child xctest process. The child first observes both
    /// checkpoint COMMITs through an independent authority read, then dies without lifecycle hooks.
    /// The parent opens the marked root as a new process would and proves both exact tails survived.
    func testSIGKILLRelaunchRetainsBothTranscriptTails() async throws {
        let environment = ProcessInfo.processInfo.environment
        if environment[Self.childModeKey] == "sigkill" {
            let support = URL(fileURLWithPath: try XCTUnwrap(environment[Self.supportKey]))
            let ready = URL(fileURLWithPath: try XCTUnwrap(environment[Self.readyKey]))
            try await runChild(support: support, ready: ready)
            XCTFail("the abnormal-exit child returned")
            Darwin._exit(126)
        }

        let selector = "\(NSStringFromClass(type(of: self)))"
            + "/testSIGKILLRelaunchRetainsBothTranscriptTails"
        try runParent(selector: selector)
    }

    private func runParent(selector: String) throws {
        let container = FileManager.default.temporaryDirectory.appendingPathComponent(
            "checkpoint-abnormal-sigkill-\(UUID().uuidString)",
            isDirectory: true)
        let support = container.appendingPathComponent("support", isDirectory: true)
        let ready = container.appendingPathComponent("ready")
        let log = container.appendingPathComponent("child.log")
        try FileManager.default.createDirectory(at: container, withIntermediateDirectories: true)
        XCTAssertTrue(FileManager.default.createFile(atPath: log.path, contents: nil))
        let logHandle = try FileHandle(forWritingTo: log)
        defer {
            try? logHandle.close()
            LibraryAuthorityRepository.forget(supportRoot: support)
            try? FileManager.default.removeItem(at: container)
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = [
            "xctest",
            "-XCTest",
            selector,
            Bundle(for: type(of: self)).bundleURL.path,
        ]
        var childEnvironment = ProcessInfo.processInfo.environment
        childEnvironment[Self.childModeKey] = "sigkill"
        childEnvironment[Self.supportKey] = support.path
        childEnvironment[Self.readyKey] = ready.path
        childEnvironment["MECHANICIAN_SUPPORT_DIR"] = support.path
        childEnvironment["CRASH_REPORTER_DISABLE"] = "1"
        childEnvironment.removeValue(forKey: "XCTestConfigurationFilePath")
        process.environment = childEnvironment
        process.standardOutput = logHandle
        process.standardError = logHandle
        let terminated = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in terminated.signal() }
        try process.run()
        if terminated.wait(timeout: .now() + 15) != .success {
            _ = Darwin.kill(process.processIdentifier, SIGKILL)
            _ = terminated.wait(timeout: .now() + 2)
            let childLog = (try? String(contentsOf: log, encoding: .utf8)) ?? ""
            XCTFail("SIGKILL child timed out:\n\(childLog)")
            return
        }

        XCTAssertEqual(process.terminationReason, .uncaughtSignal)
        XCTAssertEqual(process.terminationStatus, SIGKILL)
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: ready.path),
            "the child died before independently observing both checkpoint commits")

        let recognition = StorageAuthorityRecognizer.inspect(supportRoot: support)
        guard case .sqlite = recognition.disposition else {
            return XCTFail("the child did not leave a recognized SQLite authority")
        }
        let repository = try XCTUnwrap(
            LibraryAuthorityRepository.open(recognition: recognition))
        let relaunched = ConversationStore(
            appSupportBaseOverride: support,
            watchesDirectory: false,
            residencyMode: .eager,
            libraryAuthorityRepository: repository,
            liveCheckpointMaximumLatency: 3_600)
        XCTAssertEqual(
            relaunched.conversation(Self.foregroundID)?.messages.map(\.text),
            ["foreground prompt", Self.foregroundTail])
        XCTAssertEqual(
            relaunched.conversation(Self.backgroundID)?.messages.map(\.text),
            ["background prompt", Self.backgroundTail])
    }

    private func runChild(support: URL, ready: URL) async throws {
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        let recognition = try SQLiteLibraryBootstrapService.provisionIfNeeded(
            recognition: StorageAuthorityRecognizer.inspect(supportRoot: support),
            ownsProcessLease: true,
            now: { Date(timeIntervalSince1970: 1_788_000_000) })
        let repository = try XCTUnwrap(
            LibraryAuthorityRepository.open(recognition: recognition))
        let store = ConversationStore(
            appSupportBaseOverride: support,
            watchesDirectory: false,
            residencyMode: .eager,
            libraryAuthorityRepository: repository,
            liveCheckpointMaximumLatency: 0.05)
        let foreground = Conversation(
            id: Self.foregroundID,
            title: "Foreground abnormal exit",
            cwd: "/tmp",
            sdkSessionId: nil,
            messages: [TranscriptEntry(kind: .user, text: "foreground prompt")],
            updatedAt: Date())
        let background = Conversation(
            id: Self.backgroundID,
            title: "Background abnormal exit",
            cwd: "/tmp",
            sdkSessionId: nil,
            messages: [TranscriptEntry(kind: .user, text: "background prompt")],
            updatedAt: Date())
        store.upsert(foreground)
        store.upsert(background)
        store.flushSaves() // setup only; no flush or lifecycle hook follows the live mutations

        let bridge = AgentBridge(
            settingsBaseOverride: support.appendingPathComponent("settings", isDirectory: true),
            environmentOverride: [:],
            conversationStoreOverride: store)
        bridge.currentID = foreground.id
        bridge.cwd = foreground.cwd
        bridge.entries = foreground.messages
        bridge.bufferAssistantTextForTesting(Self.foregroundTail)
        store.updateLive(background.id) {
            $0.messages.append(
                TranscriptEntry(kind: .assistant, text: Self.backgroundTail))
        }

        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            let foregroundPersisted = try repository.conversation(id: foreground.id)?
                .messages.last?.text == Self.foregroundTail
            let backgroundPersisted = try repository.conversation(id: background.id)?
                .messages.last?.text == Self.backgroundTail
            if foregroundPersisted && backgroundPersisted {
                try Data().write(to: ready, options: .atomic)
                _ = Darwin.kill(getpid(), SIGKILL)
                Darwin._exit(125)
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        Darwin._exit(124)
    }
}
