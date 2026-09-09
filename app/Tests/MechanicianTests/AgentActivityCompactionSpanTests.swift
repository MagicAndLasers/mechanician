import XCTest
@testable import Mechanician

/// Compaction is the only phase whose end the provider reports independently, and the trace used to
/// discard that: a `.compacting` span ended at the next state record of any kind. Every case below is
/// taken from a shape found in a real recorded ledger.
final class AgentActivityCompactionSpanTests: XCTestCase {
    private let turn = "turn"

    private func compactingRun(
        strayDeltaAfter: TimeInterval?,
        boundaryAfter: TimeInterval,
        preTokens: Int? = nil,
        postTokens: Int? = nil
    ) -> (records: [AgentActivityRecord], start: Date, end: Date) {
        let start = Date(timeIntervalSince1970: 100_000)
        var records: [AgentActivityRecord] = [
            .state(.model, turnID: turn, detail: "Responding", at: start),
            .state(.compacting, turnID: turn, detail: "Compacting context", at: start
                .addingTimeInterval(5)),
        ]
        if let strayDeltaAfter {
            records.append(.state(
                .model,
                turnID: turn,
                detail: "Responding",
                at: start.addingTimeInterval(5 + strayDeltaAfter)))
        }
        records.append(.compaction(
            turnID: turn,
            trigger: "provider",
            preTokens: preTokens,
            postTokens: postTokens,
            at: start.addingTimeInterval(5 + boundaryAfter)))
        records.append(.state(
            .model,
            turnID: turn,
            detail: "Context compacted",
            at: start.addingTimeInterval(5 + boundaryAfter)))
        return (records, start, start.addingTimeInterval(5 + boundaryAfter + 20))
    }

    /// The exact recorded failure: `Compacting context` at 14:18:34.008, a stray `Responding` delta
    /// 53ms later, and the boundary 31.2s after that. The compaction drew as a 0.05s stub while a
    /// false 31-second model bar covered its real duration.
    func testStrayModelDeltaDoesNotTruncateTheCompaction() {
        let fixture = compactingRun(strayDeltaAfter: 0.053, boundaryAfter: 31.2)

        let spans = agentActivityTraceSpans(
            fixture.records,
            start: fixture.start,
            end: fixture.end)

        let compaction = try? XCTUnwrap(spans.first { $0.phase == .compacting })
        XCTAssertEqual(compaction?.duration ?? 0, 31.2, accuracy: 0.001)
        // The absorbed delta must not also survive as its own bar, or the model track still claims
        // 31 seconds of work that never happened.
        XCTAssertEqual(spans.filter { $0.phase == .model }.map(\.detail), ["Responding", "Context compacted"])
    }

    /// A provider liveness ping arrives as `.model` roughly 45s into a long compaction. Same rule.
    func testLivenessPingDoesNotTruncateTheCompaction() {
        let fixture = compactingRun(strayDeltaAfter: 45, boundaryAfter: 97.2)

        let spans = agentActivityTraceSpans(
            fixture.records,
            start: fixture.start,
            end: fixture.end)

        XCTAssertEqual(
            spans.first { $0.phase == .compacting }?.duration ?? 0,
            97.2,
            accuracy: 0.001)
    }

    /// The case that already rendered correctly must keep rendering correctly.
    func testCompactionWithNoInterveningRecordIsUnchanged() {
        let fixture = compactingRun(strayDeltaAfter: nil, boundaryAfter: 128.6)

        let spans = agentActivityTraceSpans(
            fixture.records,
            start: fixture.start,
            end: fixture.end)

        XCTAssertEqual(
            spans.first { $0.phase == .compacting }?.duration ?? 0,
            128.6,
            accuracy: 0.001)
    }

    /// A tool call proves ordinary work resumed, so it closes the interval even though no boundary
    /// record ever arrived. Without this, a lost boundary would let compaction swallow the turn.
    func testToolCallClosesAnUnterminatedCompaction() {
        let start = Date(timeIntervalSince1970: 200_000)
        let records: [AgentActivityRecord] = [
            .state(.compacting, turnID: turn, detail: "Compacting context", at: start),
            .state(.model, turnID: turn, detail: "Responding", at: start.addingTimeInterval(1)),
            .state(.tool, turnID: turn, detail: "Bash", at: start.addingTimeInterval(12)),
            .state(.model, turnID: turn, detail: "Responding", at: start.addingTimeInterval(14)),
        ]

        let spans = agentActivityTraceSpans(
            records,
            start: start,
            end: start.addingTimeInterval(30))

        XCTAssertEqual(spans.map(\.phase), [.compacting, .tool, .model])
        XCTAssertEqual(spans[0].duration, 12, accuracy: 0.001)
        XCTAssertEqual(spans[1].duration, 2, accuracy: 0.001)
    }

    /// A compaction still in flight has no end to report, so it grows to the live edge rather than
    /// freezing at whatever delta happened to land first.
    func testInFlightCompactionRunsToTheLiveEdge() {
        let start = Date(timeIntervalSince1970: 300_000)
        let now = start.addingTimeInterval(40)
        let records: [AgentActivityRecord] = [
            .state(.compacting, turnID: turn, detail: "Compacting context", at: start),
            .state(.model, turnID: turn, detail: "Responding", at: start.addingTimeInterval(0.05)),
        ]

        let spans = agentActivityTraceSpans(records, start: start, end: now)

        XCTAssertEqual(spans.map(\.phase), [.compacting])
        XCTAssertEqual(spans[0].end, now)
    }

    /// Tokens spent summarising belong to the compaction, not to a phantom model span beside it.
    func testCompactionAbsorbsTheTokensSpentInsideIt() {
        let start = Date(timeIntervalSince1970: 400_000)
        let records: [AgentActivityRecord] = [
            .state(.compacting, turnID: turn, detail: "Compacting context", at: start),
            .state(.model, turnID: turn, detail: "Responding", at: start.addingTimeInterval(0.05)),
            .tokens(turnID: turn, input: 180_000, output: 4_000, at: start.addingTimeInterval(10)),
            .compaction(
                turnID: turn,
                trigger: "provider",
                preTokens: nil,
                postTokens: nil,
                at: start.addingTimeInterval(20)),
            .state(.model, turnID: turn, detail: "Responding", at: start.addingTimeInterval(20)),
        ]

        let spans = agentActivityTraceSpans(
            records,
            start: start,
            end: start.addingTimeInterval(30))

        XCTAssertEqual(spans[0].phase, .compacting)
        XCTAssertEqual(spans[0].tokens.input, 180_000)
        XCTAssertEqual(spans[0].tokens.generated, 4_000)
    }

    /// The wider bar has room for the one fact its duration cannot express — but only when the
    /// provider actually reported it. Codex reports the boundary without counts.
    func testTitleCarriesReportedBeforeAndAfterOnly() {
        let reported = compactingRun(
            strayDeltaAfter: 0.05,
            boundaryAfter: 30,
            preTokens: 182_000,
            postTokens: 51_000)
        let reportedSpans = agentActivityTraceSpans(
            reported.records,
            start: reported.start,
            end: reported.end)
        XCTAssertEqual(
            reportedSpans.first { $0.phase == .compacting }?.title,
            "Summarized earlier messages · 182.0K → 51.0K")

        let silent = compactingRun(strayDeltaAfter: 0.05, boundaryAfter: 30)
        let silentSpans = agentActivityTraceSpans(
            silent.records,
            start: silent.start,
            end: silent.end)
        XCTAssertEqual(
            silentSpans.first { $0.phase == .compacting }?.title,
            "Summarized earlier messages")
    }

    /// Back-to-back compactions in one turn must each get their own interval.
    func testConsecutiveCompactionsEachGetTheirOwnInterval() {
        let start = Date(timeIntervalSince1970: 500_000)
        let records: [AgentActivityRecord] = [
            .state(.compacting, turnID: turn, detail: "Compacting context", at: start),
            .state(.model, turnID: turn, detail: "Responding", at: start.addingTimeInterval(0.1)),
            .compaction(
                turnID: turn,
                trigger: "provider",
                preTokens: nil,
                postTokens: nil,
                at: start.addingTimeInterval(10)),
            .state(.model, turnID: turn, detail: "Responding", at: start.addingTimeInterval(10)),
            .state(
                .compacting,
                turnID: turn,
                detail: "Compacting context",
                at: start.addingTimeInterval(30)),
            .state(.model, turnID: turn, detail: "Responding", at: start.addingTimeInterval(30.1)),
            .compaction(
                turnID: turn,
                trigger: "provider",
                preTokens: nil,
                postTokens: nil,
                at: start.addingTimeInterval(50)),
            .state(.model, turnID: turn, detail: "Responding", at: start.addingTimeInterval(50)),
        ]

        let spans = agentActivityTraceSpans(
            records,
            start: start,
            end: start.addingTimeInterval(60))

        let compactions = spans.filter { $0.phase == .compacting }
        XCTAssertEqual(compactions.count, 2)
        XCTAssertEqual(compactions[0].duration, 10, accuracy: 0.001)
        XCTAssertEqual(compactions[1].duration, 20, accuracy: 0.001)
    }

    /// Spans must stay ordered and non-overlapping — the metadata cursor walking them is monotonic,
    /// so an overlap would silently misattribute tokens to the wrong span.
    func testSpansRemainOrderedAndNonOverlapping() {
        let fixture = compactingRun(strayDeltaAfter: 0.05, boundaryAfter: 31.2)

        let spans = agentActivityTraceSpans(
            fixture.records,
            start: fixture.start,
            end: fixture.end)

        for (previous, next) in zip(spans, spans.dropFirst()) {
            XCTAssertLessThanOrEqual(previous.start, next.start)
            XCTAssertLessThanOrEqual(previous.end, next.start)
        }
    }
}
