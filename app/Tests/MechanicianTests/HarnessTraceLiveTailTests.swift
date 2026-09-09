import XCTest
@testable import Mechanician

final class HarnessTraceLiveTailTests: XCTestCase {
    private let turnID = "harness-live-tail"
    private let harnessLaneID = "harness"
    private let start = Date(timeIntervalSince1970: 20_000)

    private func summary(
        endedAt: Date,
        isTerminal: Bool
    ) -> AgentActivityTurnSummary {
        AgentActivityTurnSummary(
            id: turnID,
            startedAt: start,
            endedAt: endedAt,
            providerAccess: .codexSubscription,
            modelID: "gpt-test",
            isTerminal: isTerminal,
            inputTokens: 0,
            cachedInputTokens: 0,
            outputTokens: 0,
            reasoningOutputTokens: 0,
            aggregateOnlyTokens: 0)
    }

    private func harnessPhase(
        _ phase: AgentHarnessPhase,
        at date: Date
    ) -> AgentActivityRecord {
        .harnessObservation(
            turnID: turnID,
            lane: .codex,
            event: .phase,
            phase: phase,
            provenance: .mechanicianClock,
            at: date)
    }

    private func harnessLane(
        in model: AppKitAgentActivityRenderModel
    ) throws -> AppKitAgentActivityLane {
        try XCTUnwrap(model.lanes.first { $0.id == harnessLaneID })
    }

    func testNewestRequestAcceptedCreatesOpenZeroDurationTailThatTicksContinuously() throws {
        let acceptedAt = start.addingTimeInterval(2)
        let records: [AgentActivityRecord] = [
            .state(.model, turnID: turnID, at: start),
            harnessPhase(.requestAccepted, at: acceptedAt),
        ]
        let turn = summary(endedAt: acceptedAt, isTerminal: false)
        let harnessSpans = appKitHarnessTraceSpans(records: records, summary: turn)

        let derivedTail = try XCTUnwrap(harnessSpans.last)
        XCTAssertEqual(derivedTail.span.title, "First output wait")
        XCTAssertEqual(derivedTail.span.start, acceptedAt)
        XCTAssertEqual(derivedTail.span.end, acceptedAt)
        XCTAssertTrue(derivedTail.isOpen)

        let model = AppKitAgentActivityRenderModel()
        XCTAssertTrue(model.rebuild(
            AppKitAgentActivityRenderInput(
                records: records,
                summary: turn,
                aliases: [:],
                labels: [:],
                harnessSpans: harnessSpans),
            now: start.addingTimeInterval(5)))

        var lane = try harnessLane(in: model)
        XCTAssertTrue(lane.isActive)
        XCTAssertTrue(try XCTUnwrap(lane.spans.last).isOpen)
        XCTAssertEqual(
            try XCTUnwrap(lane.spans.last).span.end,
            start.addingTimeInterval(5))

        let firstTick = try XCTUnwrap(model.tick(now: start.addingTimeInterval(6)))
        XCTAssertTrue(firstTick.openLaneIDs.contains(harnessLaneID))
        lane = try harnessLane(in: model)
        XCTAssertEqual(
            try XCTUnwrap(lane.spans.last).span.end,
            start.addingTimeInterval(6))

        let secondTick = try XCTUnwrap(model.tick(now: start.addingTimeInterval(9)))
        XCTAssertTrue(secondTick.openLaneIDs.contains(harnessLaneID))
        lane = try harnessLane(in: model)
        XCTAssertEqual(
            try XCTUnwrap(lane.spans.last).span.end,
            start.addingTimeInterval(9))
        XCTAssertEqual(model.rebuildCount, 1)
    }

    func testHarnessTerminalClosesTailBeforeRootSummaryTerminalizes() throws {
        let terminalAt = start.addingTimeInterval(5)
        let records: [AgentActivityRecord] = [
            .state(.model, turnID: turnID, at: start),
            harnessPhase(.requestAccepted, at: start.addingTimeInterval(1)),
            harnessPhase(.firstOutput, at: start.addingTimeInterval(2)),
            harnessPhase(.terminal, at: terminalAt),
        ]
        let turn = summary(endedAt: terminalAt, isTerminal: false)
        let harnessSpans = appKitHarnessTraceSpans(records: records, summary: turn)

        let terminalSpan = try XCTUnwrap(harnessSpans.last)
        XCTAssertEqual(terminalSpan.span.title, "Provider response")
        XCTAssertEqual(terminalSpan.span.end, terminalAt)
        XCTAssertFalse(harnessSpans.contains(where: \.isOpen))

        let model = AppKitAgentActivityRenderModel()
        XCTAssertTrue(model.rebuild(
            AppKitAgentActivityRenderInput(
                records: records,
                summary: turn,
                aliases: [:],
                labels: [:],
                harnessSpans: harnessSpans),
            now: start.addingTimeInterval(8)))

        var lane = try harnessLane(in: model)
        XCTAssertFalse(lane.isActive)
        XCTAssertEqual(try XCTUnwrap(lane.spans.last).span.end, terminalAt)

        let tick = try XCTUnwrap(model.tick(now: start.addingTimeInterval(9)))
        XCTAssertFalse(tick.openLaneIDs.contains(harnessLaneID))
        lane = try harnessLane(in: model)
        XCTAssertEqual(try XCTUnwrap(lane.spans.last).span.end, terminalAt)
    }

    func testRootTerminalClosesHarnessAtRootBoundaryWhileChildKeepsTurnLive() throws {
        let rootTerminalAt = start.addingTimeInterval(5)
        let child = AgentActivityIdentity.subagent("child")
        let records: [AgentActivityRecord] = [
            .state(.model, turnID: turnID, at: start),
            harnessPhase(.requestAccepted, at: start.addingTimeInterval(1)),
            harnessPhase(.firstOutput, at: start.addingTimeInterval(2)),
            .state(.model, turnID: turnID, agentID: child, at: start.addingTimeInterval(3)),
            .state(.completed, turnID: turnID, at: rootTerminalAt),
            .tokens(
                turnID: turnID,
                agentID: child,
                input: 1,
                output: 1,
                at: start.addingTimeInterval(8)),
        ]
        let turn = summary(endedAt: start.addingTimeInterval(8), isTerminal: false)
        let harnessSpans = appKitHarnessTraceSpans(records: records, summary: turn)

        let closedTail = try XCTUnwrap(harnessSpans.last)
        XCTAssertEqual(closedTail.span.title, "Streaming response")
        XCTAssertEqual(closedTail.span.start, start.addingTimeInterval(2))
        XCTAssertEqual(closedTail.span.end, rootTerminalAt)
        XCTAssertFalse(closedTail.isOpen)

        let model = AppKitAgentActivityRenderModel()
        XCTAssertTrue(model.rebuild(
            AppKitAgentActivityRenderInput(
                records: records,
                summary: turn,
                aliases: [:],
                labels: [:],
                harnessSpans: harnessSpans),
            now: start.addingTimeInterval(12)))

        var lane = try harnessLane(in: model)
        XCTAssertFalse(lane.isActive)
        XCTAssertEqual(try XCTUnwrap(lane.spans.last).span.end, rootTerminalAt)

        let tick = try XCTUnwrap(model.tick(now: start.addingTimeInterval(13)))
        XCTAssertTrue(tick.openLaneIDs.contains(child))
        XCTAssertFalse(tick.openLaneIDs.contains(harnessLaneID))
        lane = try harnessLane(in: model)
        XCTAssertEqual(try XCTUnwrap(lane.spans.last).span.end, rootTerminalAt)
    }
}
