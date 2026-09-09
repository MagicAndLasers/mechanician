import Foundation
import XCTest
@testable import Mechanician

final class BackgroundNotificationRelayTests: XCTestCase {
    private var temporaryDirectory: URL!

    override func setUpWithError() throws {
        temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("mechanician-notification-relay-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: temporaryDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: temporaryDirectory)
    }

    func testConversationAlertPolicyUsesExactEventOwnerAcrossWindows() {
        let backgroundQuestionOwner = UUID()
        let keyWindowConversation = UUID()

        XCTAssertTrue(
            ConversationNotificationPolicy.shouldNotify(
                for: backgroundQuestionOwner,
                applicationIsActive: true,
                keyWindowConversationIDs: [keyWindowConversation]),
            "a different key conversation must not suppress the background owner's question alert")
        XCTAssertFalse(
            ConversationNotificationPolicy.shouldNotify(
                for: backgroundQuestionOwner,
                applicationIsActive: true,
                keyWindowConversationIDs: [keyWindowConversation, backgroundQuestionOwner]),
            "any key window showing the exact owner makes a duplicate alert unnecessary")
        XCTAssertTrue(
            ConversationNotificationPolicy.shouldNotify(
                for: backgroundQuestionOwner,
                applicationIsActive: false,
                keyWindowConversationIDs: [backgroundQuestionOwner]),
            "an inactive app must notify even if its last key-window snapshot names the owner")
    }

    func testForegroundAndBackgroundQuestionRoutesShareAttentionState() {
        var foreground = Conversation(
            id: UUID(), title: "Foreground", cwd: "/tmp",
            sdkSessionId: nil, messages: [], updatedAt: Date())
        var background = Conversation(
            id: UUID(), title: "Background", cwd: "/tmp",
            sdkSessionId: nil, messages: [], updatedAt: Date())

        AgentBridge.applyQuestionAttention(to: &foreground, activelyWatched: false)
        AgentBridge.applyQuestionAttention(to: &background, activelyWatched: false)

        XCTAssertTrue(foreground.awaitingQuestion)
        XCTAssertTrue(foreground.unread)
        XCTAssertEqual(foreground.awaitingQuestion, background.awaitingQuestion)
        XCTAssertEqual(foreground.unread, background.unread)

        var watched = Conversation(
            id: UUID(), title: "Watched", cwd: "/tmp",
            sdkSessionId: nil, messages: [], updatedAt: Date())
        AgentBridge.applyQuestionAttention(to: &watched, activelyWatched: true)
        XCTAssertTrue(watched.awaitingQuestion)
        XCTAssertFalse(watched.unread)
    }

    func testValidRequestIsConsumedExactlyOnce() throws {
        let payload = BackgroundNotificationPayload(
            title: "Task complete",
            body: "The report is ready.",
            openWindowID: "ambient",
            conversationID: UUID())
        let request = temporaryDirectory.appendingPathComponent("request.json")
        try JSONEncoder().encode(payload).write(to: request)

        XCTAssertEqual(
            BackgroundNotificationRelay.consume(
                arguments: ["/Applications/Mechanician.app/Contents/MacOS/Mechanician",
                            BackgroundNotificationRelay.argument, request.path],
                requestDirectory: temporaryDirectory),
            .deliver(payload))
        XCTAssertFalse(FileManager.default.fileExists(atPath: request.path))
        XCTAssertEqual(
            BackgroundNotificationRelay.consume(
                arguments: ["Mechanician", BackgroundNotificationRelay.argument, request.path],
                requestDirectory: temporaryDirectory),
            .invalid)
    }

    func testUnrequestedLaunchDoesNotTouchARequest() throws {
        let request = temporaryDirectory.appendingPathComponent("request.json")
        try Data("{}".utf8).write(to: request)

        XCTAssertEqual(
            BackgroundNotificationRelay.consume(
                arguments: ["Mechanician"], requestDirectory: temporaryDirectory),
            .notRequested)
        XCTAssertTrue(FileManager.default.fileExists(atPath: request.path))
    }

    func testRequestOutsideRelayDirectoryIsRejectedWithoutRemoval() throws {
        let outside = temporaryDirectory.deletingLastPathComponent()
            .appendingPathComponent("outside-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: outside) }
        try Data("{}".utf8).write(to: outside)

        XCTAssertEqual(
            BackgroundNotificationRelay.consume(
                arguments: ["Mechanician", BackgroundNotificationRelay.argument, outside.path],
                requestDirectory: temporaryDirectory),
            .invalid)
        XCTAssertTrue(FileManager.default.fileExists(atPath: outside.path))
    }

    func testSymlinkAndOversizedRequestsAreRejectedAndConsumed() throws {
        let target = temporaryDirectory.deletingLastPathComponent()
            .appendingPathComponent("target-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: target) }
        try Data(#"{"title":"x","body":"y"}"#.utf8).write(to: target)
        let symlink = temporaryDirectory.appendingPathComponent("symlink.json")
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: target)

        XCTAssertEqual(
            BackgroundNotificationRelay.consume(
                arguments: ["Mechanician", BackgroundNotificationRelay.argument, symlink.path],
                requestDirectory: temporaryDirectory),
            .invalid)
        XCTAssertFalse(FileManager.default.fileExists(atPath: symlink.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: target.path))

        let oversized = temporaryDirectory.appendingPathComponent("oversized.json")
        try Data(repeating: 0x61, count: BackgroundNotificationRelay.maximumRequestBytes + 1)
            .write(to: oversized)
        XCTAssertEqual(
            BackgroundNotificationRelay.consume(
                arguments: ["Mechanician", BackgroundNotificationRelay.argument, oversized.path],
                requestDirectory: temporaryDirectory),
            .invalid)
        XCTAssertFalse(FileManager.default.fileExists(atPath: oversized.path))
    }

    func testPayloadRejectsUnexpectedWindowTargets() throws {
        let request = temporaryDirectory.appendingPathComponent("request.json")
        let payload = BackgroundNotificationPayload(
            title: "Task complete", body: "Done.", openWindowID: "settings", conversationID: nil)
        try JSONEncoder().encode(payload).write(to: request)

        XCTAssertEqual(
            BackgroundNotificationRelay.consume(
                arguments: ["Mechanician", BackgroundNotificationRelay.argument, request.path],
                requestDirectory: temporaryDirectory),
            .invalid)
    }
}
