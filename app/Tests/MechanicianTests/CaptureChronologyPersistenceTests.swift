import XCTest
@testable import Mechanician

@MainActor
final class CaptureChronologyPersistenceTests: XCTestCase {
    func testActivityAndSubagentProjectionOrdinalsRoundTripTolerantly() throws {
        var activity = AgentActivityRecord.state(
            .model,
            turnID: "turn-1",
            agentID: AgentActivityIdentity.subagent("child-1"),
            detail: "Working",
            at: Date(timeIntervalSince1970: 1_785_513_847))
        activity.captureOrdinal = 21
        var child = SubagentRun(
            key: "child-1",
            subagentType: "Explore",
            task: "Inspect ordering")
        child.startedCaptureOrdinal = 20
        child.endedCaptureOrdinal = 22

        let encoder = ConversationStore.makeEncoder()
        let decoder = ConversationStore.makeDecoder()
        let decodedActivity = try decoder.decode(
            AgentActivityRecord.self,
            from: encoder.encode(activity))
        let decodedChild = try decoder.decode(
            SubagentRun.self,
            from: encoder.encode(child))

        XCTAssertEqual(decodedActivity.captureOrdinal, 21)
        XCTAssertEqual(decodedChild.startedCaptureOrdinal, 20)
        XCTAssertEqual(decodedChild.endedCaptureOrdinal, 22)

        var legacyActivity = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoder.encode(activity)) as? [String: Any])
        legacyActivity.removeValue(forKey: "captureOrdinal")
        let legacyActivityData = try JSONSerialization.data(withJSONObject: legacyActivity)
        XCTAssertNil(try decoder.decode(
            AgentActivityRecord.self,
            from: legacyActivityData).captureOrdinal)

        var legacyChild = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoder.encode(child)) as? [String: Any])
        legacyChild.removeValue(forKey: "startedCaptureOrdinal")
        legacyChild.removeValue(forKey: "endedCaptureOrdinal")
        let legacyChildData = try JSONSerialization.data(withJSONObject: legacyChild)
        let decodedLegacyChild = try decoder.decode(SubagentRun.self, from: legacyChildData)
        XCTAssertNil(decodedLegacyChild.startedCaptureOrdinal)
        XCTAssertNil(decodedLegacyChild.endedCaptureOrdinal)
    }

    func testSameCaptureBatchTerminalizesSeveralToolsWithoutInventingOrder() {
        var first = TranscriptEntry(kind: .tool, text: "one")
        first.toolUseId = "tool-1"
        first.toolState = .running
        var second = TranscriptEntry(kind: .tool, text: "two")
        second.toolUseId = "tool-2"
        second.toolState = .running
        var entries = [first, second]

        XCTAssertTrue(stopUnfinishedToolEntries(&entries, captureOrdinal: 30))
        XCTAssertEqual(entries.map(\.toolTerminalCaptureOrdinal), [30, 30])
        XCTAssertTrue(entries.allSatisfy { $0.toolState == .stopped })
    }

    func testDuplicateToolResultKeepsFirstCaptureOrdinal() {
        var entry = TranscriptEntry(kind: .tool, text: "read")
        AgentBridge.applyToolResult(
            ["status": "success", "result": "first"],
            to: &entry,
            captureOrdinal: 41)
        AgentBridge.applyToolResult(
            ["status": "success", "result": "first"],
            to: &entry,
            captureOrdinal: 42)

        XCTAssertEqual(entry.toolResultCaptureOrdinal, 41)
    }

    func testProviderToolEntryCarriesFrameAndPrivateOwnerCorrelationThroughBothEventPaths() {
        let event: [String: Any] = [
            "type": "tool_use",
            "toolUseId": "tool-1",
            "name": "Bash",
            "input": ["command": "swift test"],
            "frameUUID": "claude-frame-1",
        ]

        let entry = AgentBridge.toolEntry(
            from: event,
            captureOrdinal: 50,
            ownerAgentID: AgentActivityIdentity.subagent("provider-child-private"),
            turnID: "provider-turn-private")

        XCTAssertEqual(entry.providerFrameUUID, "claude-frame-1")
        XCTAssertEqual(entry.toolUseId, "tool-1")
        XCTAssertEqual(entry.toolName, "Bash")
        XCTAssertEqual(entry.captureOrdinal, 50)
        XCTAssertEqual(entry.toolOwnerAgentID, "subagent:provider-child-private")
        XCTAssertEqual(entry.toolTurnID, "provider-turn-private")
        XCTAssertEqual(entry.toolState, .running)
    }
}
