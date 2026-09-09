import XCTest
@testable import Mechanician

final class AgentActivityLedgerIndexTests: XCTestCase {
    private let first = AgentActivityIdentity.subagent("first")
    private let second = AgentActivityIdentity.subagent("second")
    private let start = Date(timeIntervalSince1970: 10_000)

    private func at(_ offset: TimeInterval) -> Date {
        start.addingTimeInterval(offset)
    }

    func testOneIndexKeepsCardDataIsolatedAndAggregated() {
        let records: [AgentActivityRecord] = [
            .state(.model, turnID: "t", agentID: first, detail: "Reasoning", at: at(0)),
            .tool("Read", turnID: "t", agentID: first, at: at(1)),
            .tool("Read", turnID: "t", agentID: first, at: at(2)),
            .tokens(
                turnID: "t",
                agentID: first,
                input: 100,
                cachedInput: 80,
                output: 20,
                reasoningOutput: 5,
                at: at(3)),
            .state(.tool, turnID: "t", agentID: first, detail: "Bash", at: at(10)),
            .tool(
                "Bash",
                turnID: "t",
                agentID: first,
                target: "swift test",
                at: at(10)),
            .state(.tool, turnID: "t", agentID: second, detail: "Grep", at: at(20)),
            .tool("Grep", turnID: "t", agentID: second, target: "AgentBridge", at: at(20)),
            .tokens(turnID: "t", agentID: second, total: 900, at: at(21)),
        ]

        let index = AgentActivityLedgerIndex(records)
        let firstCard = index.cardSnapshot(agentID: first, now: at(40))
        let secondCard = index.cardSnapshot(agentID: second, now: at(40))

        XCTAssertEqual(firstCard.currentStep?.label, "Bash")
        XCTAssertEqual(firstCard.currentStep?.target, "swift test")
        XCTAssertEqual(firstCard.currentStep?.duration, 30)
        // A shell call is counted under the program it ran, not under the shell. Grouping every
        // command as "Bash" collapsed the whole breakdown to one bar on any provider that runs its
        // tools through a shell.
        XCTAssertEqual(firstCard.toolComposition.map(\.name), ["Read", "swift"])
        XCTAssertEqual(firstCard.toolComposition.map(\.count), [2, 1])
        XCTAssertEqual(firstCard.tokenUsage.processed, 125)

        XCTAssertEqual(secondCard.currentStep?.label, "Grep")
        XCTAssertEqual(secondCard.currentStep?.target, "AgentBridge")
        XCTAssertEqual(secondCard.toolComposition.map(\.name), ["Grep"])
        XCTAssertEqual(secondCard.tokenUsage.processed, 900)
    }

    func testIndexReusesPreprocessedLedgerForChangingClockValues() {
        let records: [AgentActivityRecord] = [
            .state(.tool, turnID: "t", agentID: first, detail: "Read", at: at(10)),
            .tool("Read", turnID: "t", agentID: first, target: "File.swift", at: at(10)),
        ]
        let index = AgentActivityLedgerIndex(records)

        XCTAssertEqual(index.currentStep(agentID: first, now: at(15))?.duration, 5)
        XCTAssertEqual(index.currentStep(agentID: first, now: at(75))?.duration, 65)
        XCTAssertEqual(index.toolComposition(agentID: first), [
            AgentToolShare(name: "Read", count: 1, share: 1),
        ])
    }

    func testIndexedStallDetectionAndCompositionFoldingMatchCardSemantics() {
        var records: [AgentActivityRecord] = (0..<6).map { index in
            .state(
                .tool,
                turnID: "t",
                agentID: first,
                detail: "Step \(index)",
                at: at(Double(index) * 2))
        }
        records += [
            .tool("Read", turnID: "t", agentID: first),
            .tool("Read", turnID: "t", agentID: first),
            .tool("Bash", turnID: "t", agentID: first),
            .tool("Grep", turnID: "t", agentID: first),
        ]

        let index = AgentActivityLedgerIndex(records)
        let card = index.cardSnapshot(
            agentID: first,
            now: at(310),
            compositionLimit: 2)

        XCTAssertTrue(card.isStalled)
        XCTAssertEqual(card.toolComposition.map(\.name), ["Read", "Bash", "other"])
        XCTAssertEqual(card.toolComposition.map(\.count), [2, 1, 1])
        XCTAssertEqual(card.toolComposition.reduce(0) { $0 + $1.share }, 1, accuracy: 0.0001)
    }

    func testUnknownAgentProducesAnEmptySnapshot() {
        let card = AgentActivityLedgerIndex([])
            .cardSnapshot(agentID: first, now: at(20))

        XCTAssertNil(card.currentStep)
        XCTAssertTrue(card.toolComposition.isEmpty)
        XCTAssertTrue(card.tokenUsage.isEmpty)
        XCTAssertFalse(card.isStalled)
    }

    func testCacheRebuildsOnlyWhenTheLedgerValueChanges() {
        let cache = AgentActivityLedgerIndexCache()
        let records: [AgentActivityRecord] = [
            .state(.model, turnID: "t", agentID: first, at: at(0)),
        ]

        _ = cache.index(for: records)
        _ = cache.index(for: Array(records))
        XCTAssertEqual(cache.rebuildCount, 1, "equal COW arrays must reuse the derived index")

        _ = cache.index(for: records + [
            .tool("Read", turnID: "t", agentID: first, at: at(1)),
        ])
        XCTAssertEqual(cache.rebuildCount, 2)
    }

    func testConversationSnapshotPrefersChildWorkOverDelegationCalls() {
        let children = (1...4).map { AgentActivityIdentity.subagent("child-\($0)") }
        var records: [AgentActivityRecord] = [
            .state(.model, turnID: "turn", detail: "Responding", at: at(0)),
        ]
        records += (0..<4).map { index in
            .tool(
                "Agent",
                turnID: "turn",
                agentID: AgentActivityIdentity.root,
                target: "Explore child \(index + 1)",
                at: at(Double(index) + 1))
        }
        records += [
            .state(.tool, turnID: "turn", agentID: children[0], detail: "Read", at: at(6)),
            .tool("Read", turnID: "turn", agentID: children[0], at: at(6)),
            .tool("Read", turnID: "turn", agentID: children[0], at: at(7)),
            .tool("Read", turnID: "turn", agentID: children[1], at: at(8)),
            .state(.tool, turnID: "turn", agentID: children[2], detail: "Bash", at: at(9)),
            .tool("Bash", turnID: "turn", agentID: children[2], target: "rg TODO", at: at(9)),
            .tool("Bash", turnID: "turn", agentID: children[3], target: "rg FIXME", at: at(10)),
            .tool("Grep", turnID: "turn", agentID: children[1], target: "AgentBridge", at: at(11)),
            .tokens(
                turnID: "turn",
                input: 100,
                cachedInput: 80,
                output: 20,
                reasoningOutput: 5,
                total: 10,
                at: at(12)),
        ]
        var subagents: [String: SubagentRun] = [:]
        for index in 1...4 {
            var run = SubagentRun(
                key: "child-\(index)",
                subagentType: "Explore",
                task: "Explore \(index)")
            run.status = .running
            subagents[run.key] = run
        }

        let snapshot = AgentConversationActivityIndex(records).snapshot(
            subagents: subagents,
            workflowRuns: [:],
            isRootWorking: false,
            now: at(20))
        let headline = try! XCTUnwrap(agentActivityTurnSummaries(records).first)

        XCTAssertEqual(snapshot.activeAgentCount, 4)
        XCTAssertEqual(snapshot.toolComposition.map(\.name), ["Read", "rg", "Grep"])
        XCTAssertEqual(snapshot.toolComposition.map(\.count), [3, 2, 1])
        XCTAssertFalse(snapshot.toolComposition.map(\.name).contains("Delegating"))
        XCTAssertNil(snapshot.delegationSummary)
        XCTAssertEqual(snapshot.tokenUsage, headline.tokenBreakdown)
        XCTAssertEqual(snapshot.tokenUsage.processed, 135)
        XCTAssertEqual(snapshot.tokenUsage.cachedInput, 80)
    }

    func testConversationSnapshotNamesDelegationWhenItIsTheOnlyToolActivity() {
        let records = (0..<4).map { index in
            AgentActivityRecord.tool(
                index.isMultiple(of: 2) ? "Agent" : "Task",
                turnID: "turn",
                agentID: AgentActivityIdentity.root,
                target: "Explore \(index)",
                at: at(Double(index)))
        }

        let snapshot = AgentConversationActivityIndex(records).snapshot(
            subagents: [:],
            workflowRuns: [:],
            isRootWorking: false,
            now: at(10))

        XCTAssertTrue(snapshot.toolComposition.isEmpty)
        XCTAssertEqual(snapshot.delegatedAgentCount, 4)
        XCTAssertEqual(snapshot.delegationSummary, "Delegated 4 agents")
    }

    func testConversationSnapshotCollapsesAliasMirrorsForActiveAgentCount() {
        var child = SubagentRun(
            key: "provisional",
            subagentType: "Explore",
            task: "Inspect")
        child.taskId = "provider-child"
        child.status = .running
        var workflow = WorkflowRun(runKey: "workflow")
        workflow.status = .running
        workflow.agents = [
            "0:1": WorkflowAgent(
                index: 1,
                label: "Explore",
                phaseIndex: 0,
                phaseTitle: "Explore",
                state: .progress,
                agentId: "provider-child"),
        ]
        let aliases = agentActivityAliases(
            subagents: [child.key: child],
            workflowRuns: [workflow.runKey: workflow])
        let records: [AgentActivityRecord] = [
            .state(
                .model,
                turnID: "turn",
                agentID: AgentActivityIdentity.subagent("provider-child"),
                at: at(1)),
            .tool(
                "Read",
                turnID: "turn",
                agentID: AgentActivityIdentity.subagent("provider-child"),
                at: at(2)),
            .state(
                .tool,
                turnID: "turn",
                agentID: AgentActivityIdentity.workflow(
                    runKey: workflow.runKey,
                    agentKey: "0:1"),
                at: at(3)),
            .tool(
                "Bash",
                turnID: "turn",
                agentID: AgentActivityIdentity.workflow(
                    runKey: workflow.runKey,
                    agentKey: "0:1"),
                target: "sed -n '1,40p' File.swift",
                at: at(3)),
        ]

        let snapshot = AgentConversationActivityIndex(records, aliases: aliases).snapshot(
            subagents: [child.key: child],
            workflowRuns: [workflow.runKey: workflow],
            isRootWorking: false,
            now: at(10))

        XCTAssertEqual(snapshot.activeAgentCount, 1)
        XCTAssertEqual(snapshot.toolComposition.map(\.name), ["Read", "sed"])
    }

    func testConversationSnapshotUsesTheLiveTurnBeforeTheLatestCompletedTurn() {
        let childID = AgentActivityIdentity.subagent("older-live-child")
        let records: [AgentActivityRecord] = [
            .state(.model, turnID: "live", at: at(0)),
            .state(.tool, turnID: "live", agentID: childID, detail: "Read", at: at(1)),
            .tool("Read", turnID: "live", agentID: childID, at: at(1)),
            .tokens(turnID: "live", input: 50, at: at(2)),
            .state(.model, turnID: "latest", at: at(100)),
            .tool("Bash", turnID: "latest", agentID: AgentActivityIdentity.root,
                  target: "git status", at: at(101)),
            .tokens(turnID: "latest", input: 900, at: at(102)),
            .state(.completed, turnID: "latest", at: at(103)),
        ]

        let snapshot = AgentConversationActivityIndex(records).snapshot(
            subagents: [:],
            workflowRuns: [:],
            isRootWorking: false,
            now: at(120))

        let summaries = agentActivityTurnSummaries(records)
        XCTAssertEqual(
            agentActivityActiveOrLatestTurn(summaries)?.id,
            "live",
            "the Activity headline and conversation strip must follow the same turn")
        XCTAssertEqual(snapshot.turnID, "live")
        XCTAssertEqual(snapshot.activeAgentCount, 1)
        XCTAssertEqual(snapshot.toolComposition.map(\.name), ["Read"])
        XCTAssertEqual(snapshot.tokenUsage.processed, 50)
    }

    func testStoppedDelegatedTurnCannotReplaceLaterCompletedRootOnlyTurn() {
        var stoppedChild = SubagentRun(
            key: "stopped-child",
            subagentType: "Explore",
            task: "Old direction")
        stoppedChild.taskId = "provider-child"
        stoppedChild.status = .stopped
        stoppedChild.endedAt = at(4)
        let childID = AgentActivityIdentity.subagent("provider-child")
        let records: [AgentActivityRecord] = [
            .state(.model, turnID: "delegated", at: at(0)),
            .tool(
                "Agent",
                turnID: "delegated",
                agentID: AgentActivityIdentity.root,
                at: at(1)),
            .state(.model, turnID: "delegated", agentID: childID, at: at(2)),
            .state(.stopped, turnID: "delegated", at: at(3)),
            .state(.stopped, turnID: "delegated", agentID: childID, at: at(4)),
            // Reproduces the live Stop-and-Redirect ordering: provider progress was already buffered
            // when the local terminal boundary closed the child lane.
            .state(.model, turnID: "delegated", agentID: childID, at: at(5)),
            .state(.model, turnID: "redirected", at: at(10)),
            .tool(
                "Read",
                turnID: "redirected",
                agentID: AgentActivityIdentity.root,
                at: at(11)),
            .tokens(turnID: "redirected", input: 80, output: 20, at: at(12)),
            .state(.completed, turnID: "redirected", at: at(13)),
        ]
        let aliases = agentActivityAliases(subagents: [stoppedChild.key: stoppedChild])

        let summaries = agentActivityTurnSummaries(records, aliases: aliases)
        XCTAssertTrue(summaries.first(where: { $0.id == "delegated" })?.isTerminal == true)
        XCTAssertEqual(agentActivityActiveOrLatestTurn(summaries)?.id, "redirected")

        let snapshot = AgentConversationActivityIndex(records, aliases: aliases).snapshot(
            subagents: [stoppedChild.key: stoppedChild],
            workflowRuns: [:],
            isRootWorking: false,
            now: at(20))

        XCTAssertEqual(snapshot.turnID, "redirected")
        XCTAssertEqual(snapshot.overallState, .completed)
        XCTAssertEqual(snapshot.activeAgentCount, 0)
        XCTAssertEqual(snapshot.toolComposition.map(\.name), ["Read"])
        XCTAssertEqual(snapshot.tokenUsage.processed, 100)
        XCTAssertEqual(snapshot.duration, 3, accuracy: 0.001)
    }

    func testTerminalDelegateGraphOverridesAStaleOpenLedgerTail() {
        var child = SubagentRun(
            key: "recovered-child",
            subagentType: "Explore",
            task: "Inspect")
        child.status = .stopped
        child.endedAt = at(3)
        let records: [AgentActivityRecord] = [
            .state(.model, turnID: "turn", at: at(0)),
            .state(
                .tool,
                turnID: "turn",
                agentID: AgentActivityIdentity.subagent(child.key),
                detail: "Read",
                at: at(1)),
            .state(.completed, turnID: "turn", at: at(2)),
        ]

        let snapshot = AgentConversationActivityIndex(records).snapshot(
            subagents: [child.key: child],
            workflowRuns: [:],
            isRootWorking: false,
            now: at(10_000))

        XCTAssertEqual(snapshot.activeAgentCount, 0)
        XCTAssertFalse(snapshot.isActive)
        XCTAssertEqual(snapshot.duration, 2, accuracy: 0.001)
    }

    func testGraphlessTerminalLanesIgnoreLateBufferedProgress() {
        let childID = AgentActivityIdentity.subagent("buffered-child")
        let records: [AgentActivityRecord] = [
            .state(.model, turnID: "turn", at: at(0)),
            .state(.model, turnID: "turn", agentID: childID, at: at(1)),
            .state(.stopped, turnID: "turn", agentID: childID, at: at(2)),
            .state(.stopped, turnID: "turn", at: at(3)),
            // Both updates were buffered before Stop but arrived after the synthetic terminal
            // boundaries. With no persisted card graph, the ledger projection is the only source
            // of truth and must remain terminal-monotonic on its own.
            .state(.tool, turnID: "turn", agentID: childID, detail: "Read", at: at(4)),
            .state(.model, turnID: "turn", at: at(5)),
        ]

        let index = AgentActivityLedgerIndex(records)
        XCTAssertEqual(index.currentStep(agentID: childID, now: at(100))?.phase, .stopped)
        XCTAssertEqual(
            index.currentStep(agentID: AgentActivityIdentity.root, now: at(100))?.phase,
            .stopped)

        let snapshot = AgentConversationActivityIndex(records).snapshot(
            subagents: [:],
            workflowRuns: [:],
            isRootWorking: false,
            now: at(100))

        XCTAssertEqual(snapshot.activeAgentCount, 0)
        XCTAssertEqual(snapshot.overallState, .stopped)
        XCTAssertFalse(snapshot.isActive)
        XCTAssertNil(snapshot.currentRootStep)
    }

    func testChildlessRunningWorkflowCountsAsActiveConversationWork() {
        var workflow = WorkflowRun(runKey: "between-phases")
        workflow.status = .running

        let snapshot = AgentConversationActivityIndex([]).snapshot(
            subagents: [:],
            workflowRuns: [workflow.runKey: workflow],
            isRootWorking: false,
            now: at(10))

        XCTAssertEqual(snapshot.activeAgentCount, 1)
        XCTAssertEqual(snapshot.overallState, .model)
        XCTAssertTrue(snapshot.isActive)
    }

    func testCompletedDelegateGraphKeepsConversationSummaryVisibleWithoutLedgerSamples() {
        var first = SubagentRun(
            key: "first-complete",
            subagentType: "Explore",
            task: "Inspect cards")
        first.status = .completed
        var second = SubagentRun(
            key: "second-complete",
            subagentType: "Explore",
            task: "Inspect trace")
        second.status = .completed

        let snapshot = AgentConversationActivityIndex([]).snapshot(
            subagents: [first.key: first, second.key: second],
            workflowRuns: [:],
            isRootWorking: false,
            now: at(10))

        XCTAssertEqual(snapshot.activeAgentCount, 0)
        XCTAssertEqual(snapshot.overallState, .completed)
        XCTAssertFalse(snapshot.isActive)
        XCTAssertFalse(
            snapshot.isEmpty,
            "terminalizing the last card must not make This conversation disappear")
    }

    func testFailedDelegateGraphWinsOverCompletedSiblingForConversationSummary() {
        var completed = SubagentRun(
            key: "complete",
            subagentType: "Explore",
            task: "Done")
        completed.status = .completed
        var failed = SubagentRun(
            key: "failed",
            subagentType: "Explore",
            task: "Failed")
        failed.status = .failed

        let snapshot = AgentConversationActivityIndex([]).snapshot(
            subagents: [completed.key: completed, failed.key: failed],
            workflowRuns: [:],
            isRootWorking: false,
            now: at(10))

        XCTAssertEqual(snapshot.overallState, .failed)
        XCTAssertFalse(snapshot.isEmpty)
    }

    func testTerminalFallbackStateUsesLatestLedgerOrderDeterministically() {
        let records: [AgentActivityRecord] = [
            .state(
                .failed,
                turnID: "turn",
                agentID: AgentActivityIdentity.subagent("first"),
                at: at(5)),
            .state(
                .completed,
                turnID: "turn",
                agentID: AgentActivityIdentity.subagent("second"),
                at: at(5)),
        ]

        for _ in 0..<20 {
            let snapshot = AgentConversationActivityIndex(records).snapshot(
                subagents: [:],
                workflowRuns: [:],
                isRootWorking: false,
                now: at(100))
            XCTAssertEqual(snapshot.overallState, .completed)
            XCTAssertFalse(snapshot.isActive)
        }
    }
}
