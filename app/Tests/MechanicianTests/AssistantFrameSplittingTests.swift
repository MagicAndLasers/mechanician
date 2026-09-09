import XCTest
@testable import Mechanician

/// One provider message must stay one transcript row even while its conversation is backgrounded.
///
/// Claude partials carry the UUID of the STREAM EVENT, not the completed text frame. Comparing those
/// UUIDs produced the exact persisted corruption seen in “user journey”: "Now the respon" and
/// "sive rules…" became separate assistant bubbles after the user switched conversations.
@MainActor
final class AssistantFrameSplittingTests: XCTestCase {
    func testBackgroundDeltasWithDifferentEventUUIDsStayInOneRow() {
        var messages: [TranscriptEntry] = []
        var openEntryID: UUID?

        openEntryID = AgentBridge.appendBackgroundAssistantText(
            &messages,
            "Now the respon",
            frameUUID: "partial-first",
            openEntryID: openEntryID)
        openEntryID = AgentBridge.appendBackgroundAssistantText(
            &messages,
            "sive rules for the new sections:",
            frameUUID: "partial-last",
            openEntryID: openEntryID)

        XCTAssertEqual(messages.count, 1)
        XCTAssertEqual(messages.first?.text, "Now the responsive rules for the new sections:")
        XCTAssertEqual(messages.first?.providerFrameUUID, "partial-first")
        XCTAssertEqual(openEntryID, messages.first?.id)
    }

    func testCompletedFrameClosesTheBackgroundRow() {
        var messages: [TranscriptEntry] = []
        var openEntryID = AgentBridge.appendBackgroundAssistantText(
            &messages,
            "first frame",
            frameUUID: "partial-first",
            openEntryID: nil)

        ClaudeSupersession.apply(event: [
            "type": "assistant_frame",
            "frameUUID": "frame-1",
            "provisionalFrameUUID": "partial-first",
        ], to: &messages)
        openEntryID = nil

        openEntryID = AgentBridge.appendBackgroundAssistantText(
            &messages,
            "second frame",
            frameUUID: "partial-second",
            openEntryID: openEntryID)

        XCTAssertEqual(messages.map(\.text), ["first frame", "second frame"])
        XCTAssertEqual(messages.map(\.providerFrameUUID), ["frame-1", "partial-second"])
        XCTAssertEqual(openEntryID, messages.last?.id)
    }

    func testAnUnknownOpenRowStartsFreshInsteadOfMutatingAnotherEntry() {
        var messages = [TranscriptEntry(kind: .assistant, text: "historical")]

        let openEntryID = AgentBridge.appendBackgroundAssistantText(
            &messages,
            "new response",
            frameUUID: "partial-new",
            openEntryID: UUID())

        XCTAssertEqual(messages.map(\.text), ["historical", "new response"])
        XCTAssertEqual(openEntryID, messages.last?.id)
    }
}
