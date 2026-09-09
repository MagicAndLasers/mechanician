import XCTest
@testable import Mechanician

final class AgentActivityTraceSweepTests: XCTestCase {
    func testSweepPreservesBoundaryAndTerminalMetadataSemantics() {
        let start = Date(timeIntervalSince1970: 10_000)
        let end = start.addingTimeInterval(10)
        let records: [AgentActivityRecord] = [
            // Deliberately unordered: trace construction promises chronological, stable output.
            .tokens(turnID: "turn", output: 30, at: end),
            .state(.completed, turnID: "turn", at: end),
            .tool(
                "Read",
                turnID: "turn",
                agentID: AgentActivityIdentity.root,
                at: start.addingTimeInterval(5)),
            .state(.model, turnID: "turn", detail: "Reasoning", at: start),
            .tokens(
                turnID: "turn",
                input: 20,
                at: start.addingTimeInterval(4)),
            .state(
                .tool,
                turnID: "turn",
                detail: "Read",
                at: start.addingTimeInterval(5)),
        ]

        let spans = agentActivityTraceSpans(records, start: start, end: end)

        XCTAssertEqual(spans.map(\.phase), [.model, .tool, .completed])
        XCTAssertEqual(spans[0].tokens.input, 20)
        XCTAssertEqual(spans[0].tokens.output, 0)
        XCTAssertEqual(spans[1].toolNames, ["Read"])
        XCTAssertEqual(spans[1].tokens.output, 30)
        // The chart end is inclusive, and a terminal milestone at that exact instant describes the
        // same sample. This matches the pre-sweep inspector behavior.
        XCTAssertEqual(spans[2].tokens.output, 30)
    }

    func testSweepClipsMetadataToTheVisibleWindow() {
        let origin = Date(timeIntervalSince1970: 20_000)
        let start = origin.addingTimeInterval(5)
        let end = origin.addingTimeInterval(15)
        let records: [AgentActivityRecord] = [
            .state(.model, turnID: "turn", at: origin),
            .tokens(turnID: "turn", input: 10, at: origin.addingTimeInterval(4)),
            .tokens(turnID: "turn", input: 20, at: start),
            .state(.tool, turnID: "turn", detail: "Bash", at: origin.addingTimeInterval(10)),
            .tokens(turnID: "turn", output: 30, at: end),
            .state(.completed, turnID: "turn", at: origin.addingTimeInterval(20)),
        ]

        let spans = agentActivityTraceSpans(records, start: start, end: end)

        XCTAssertEqual(spans.map(\.phase), [.model, .tool])
        XCTAssertEqual(spans[0].start, start)
        XCTAssertEqual(spans[0].tokens.input, 20)
        XCTAssertEqual(spans[1].end, end)
        XCTAssertEqual(spans[1].tokens.output, 30)
    }

    func testSweepAssociatesEachDenseSampleWithItsState() {
        let start = Date(timeIntervalSince1970: 30_000)
        let count = 800
        var records: [AgentActivityRecord] = []
        records.reserveCapacity(count * 2)
        for index in 0..<count {
            let stateAt = start.addingTimeInterval(Double(index))
            records.append(.state(
                index.isMultiple(of: 2) ? .model : .tool,
                turnID: "turn",
                detail: "Step \(index)",
                at: stateAt))
            records.append(.tokens(
                turnID: "turn",
                output: index + 1,
                at: stateAt.addingTimeInterval(0.5)))
        }

        let spans = agentActivityTraceSpans(
            records,
            start: start,
            end: start.addingTimeInterval(Double(count)))

        XCTAssertEqual(spans.count, count)
        XCTAssertEqual(spans.map(\.tokens.output), Array(1...count))
    }
}
