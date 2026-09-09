import XCTest
@testable import Mechanician

/// A call the person declined never ran, so the transcript must not report it as a failure.
///
/// The transport says otherwise: a declined call still returns a `tool_result` carrying an error,
/// because from its point of view the call did not succeed. Taking that at face value put a red
/// "1 failed" on a command that never executed, directly above the card saying it was denied, and
/// made a refusal indistinguishable from something genuinely breaking.
///
/// Every assertion here has a control running the same shape WITHOUT the refusal, so a change that
/// simply stopped reporting failures would fail these tests rather than pass them.
@MainActor
final class RefusedToolCallTests: XCTestCase {

    private func resultEvent(_ toolUseID: String, status: String) -> [String: Any] {
        ["type": "tool_result", "toolUseId": toolUseID, "status": status, "result": "denied"]
    }

    private func toolEntry(_ name: String, input: String) -> TranscriptEntry {
        AgentBridge.toolEntry(
            from: ["type": "tool_use", "name": name, "toolUseId": "t1", "input": ["command": input]],
            fallbackToolUseID: "t1",
            fallbackToolName: name,
            turnID: "turn-1")
    }

    private func action(state: AppKitActivityAction.State) -> AppKitActivityAction {
        AppKitActivityAction(
            id: AnyHashable("a1"),
            sourceIndex: 0,
            toolName: "Bash",
            rawInput: #"{"command":"mkdir -p /tmp/x"}"#,
            state: state)
    }

    // MARK: - The row

    func testADeclinedCallIsMarkedRefusedWithoutLosingWhatTheTransportSaid() {
        var entry = toolEntry("Bash", input: "mkdir -p /tmp/x")
        AgentBridge.applyToolResult(resultEvent("t1", status: "error"), to: &entry, refused: true)

        XCTAssertEqual(entry.toolRefused, true)
        // The transport's own report is preserved rather than rewritten. Only the reading changes.
        XCTAssertTrue(entry.toolIsError)
        XCTAssertEqual(entry.resolvedToolState, .failed)
    }

    func testAnOrdinaryFailureIsNeverMarkedRefused() {
        var entry = toolEntry("Bash", input: "swift build")
        AgentBridge.applyToolResult(resultEvent("t1", status: "error"), to: &entry, refused: false)

        XCTAssertNil(entry.toolRefused)
        XCTAssertTrue(entry.toolIsError)
    }

    func testTheRefusalMarkSurvivesAnEncodeDecodeRoundTrip() throws {
        // The card the person complained about was restored from history, not live, so a mark that
        // only existed in memory would fix nothing for any transcript they reopen.
        var entry = toolEntry("Bash", input: "mkdir -p /tmp/x")
        AgentBridge.applyToolResult(resultEvent("t1", status: "error"), to: &entry, refused: true)

        let data = try JSONEncoder().encode(entry)
        let restored = try JSONDecoder().decode(TranscriptEntry.self, from: data)
        XCTAssertEqual(restored.toolRefused, true)
    }

    func testATranscriptWrittenBeforeThisFieldStillDecodes() throws {
        // Optional, so an older row decodes to nil rather than costing the whole entry.
        var entry = toolEntry("Bash", input: "ls")
        AgentBridge.applyToolResult(resultEvent("t1", status: "error"), to: &entry)
        var object = try XCTUnwrap(
            try JSONSerialization.jsonObject(
                with: try JSONEncoder().encode(entry)) as? [String: Any])
        object.removeValue(forKey: "toolRefused")

        let restored = try JSONDecoder().decode(
            TranscriptEntry.self,
            from: try JSONSerialization.data(withJSONObject: object))
        XCTAssertNil(restored.toolRefused)
    }

    // MARK: - The group header

    func testARefusedCallIsCountedAsDeniedAndNotAsFailed() {
        let group = AppKitActivityGroup(
            id: AnyHashable("g"), actions: [action(state: .refused)], chatScale: 1)

        XCTAssertEqual(group.refusedCount, 1)
        XCTAssertEqual(group.failedCount, 0, "a refusal must never reach the red failure count")
        XCTAssertEqual(group.stoppedCount, 0)
    }

    func testAGenuineFailureStillCountsAsFailed() {
        let group = AppKitActivityGroup(
            id: AnyHashable("g"), actions: [action(state: .failed)], chatScale: 1)

        XCTAssertEqual(group.failedCount, 1)
        XCTAssertEqual(group.refusedCount, 0)
    }

    func testAGroupSeparatesARefusalFromARealFailureInTheSameTurn() {
        // The case the learning fix conceded it could confuse. Both must be reported, distinctly.
        let group = AppKitActivityGroup(
            id: AnyHashable("g"),
            actions: [action(state: .refused), action(state: .failed)],
            chatScale: 1)

        XCTAssertEqual(group.refusedCount, 1)
        XCTAssertEqual(group.failedCount, 1)
    }

    // MARK: - The row title

    func testARefusedCallDoesNotClaimItRan() {
        let title = activityActionTitle(action(state: .refused))

        XCTAssertTrue(title.hasPrefix("Denied "), title)
        XCTAssertFalse(title.hasPrefix("Ran "), "a declined command never ran")
    }

    func testAnAllowedCallStillSaysItRan() {
        XCTAssertTrue(activityActionTitle(action(state: .succeeded)).hasPrefix("Ran "))
        XCTAssertTrue(activityActionTitle(action(state: .running)).hasPrefix("Running "))
        XCTAssertTrue(activityActionTitle(action(state: .stopped)).hasPrefix("Stopped "))
    }
}
