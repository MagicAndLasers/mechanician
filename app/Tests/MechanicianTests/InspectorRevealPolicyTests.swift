import XCTest
@testable import Mechanician

/// The inspector may announce delegated work, but it may not take the panel away from the user.
@MainActor
final class InspectorRevealPolicyTests: XCTestCase {
    private func makeBridge() -> AgentBridge {
        let support = FileManager.default.temporaryDirectory
            .appendingPathComponent("mechanician-reveal-\(UUID().uuidString)", isDirectory: true)
        return AgentBridge(settingsBaseOverride: support, environmentOverride: [:])
    }

    private func runningAgent(_ key: String) -> SubagentRun {
        var run = SubagentRun(key: key, subagentType: "Explore", task: "inspect the workspace")
        run.status = .running
        return run
    }

    func testAClosedInspectorOpensOnAgentsWhenAnAgentStarts() {
        let bridge = makeBridge()
        bridge.showInspector = false
        bridge.inspectorTab = .files

        bridge.revealAgentsInspector()

        XCTAssertTrue(bridge.showInspector)
        XCTAssertEqual(bridge.inspectorTab, .agents)
    }

    func testAnOpenInspectorSwitchesToAgentsWhenDelegationBegins() {
        let bridge = makeBridge()
        bridge.showInspector = true
        bridge.inspectorTab = .changes

        bridge.revealAgentsInspector()

        XCTAssertTrue(bridge.showInspector)
        XCTAssertEqual(bridge.inspectorTab, .agents)
    }

    func testClosingAnIdleInspectorDoesNotSilenceTheFirstFutureAgent() {
        let bridge = makeBridge()
        bridge.showInspector = true

        bridge.userToggledInspector()   // the user closes it

        XCTAssertFalse(bridge.showInspector)
        XCTAssertTrue(bridge.inspectorAutoRevealSuppressed)

        bridge.revealAgentsInspector()
        XCTAssertTrue(bridge.showInspector, "an idle close must not permanently silence Agents")
        XCTAssertEqual(bridge.inspectorTab, .agents)
        XCTAssertFalse(bridge.inspectorAutoRevealSuppressed)
    }

    func testClosingDuringDelegationSuppressesThatWholeOverlappingActivityCycle() {
        let bridge = makeBridge()
        bridge.showInspector = true
        bridge.subagents["agent-a"] = runningAgent("agent-a")

        bridge.userToggledInspector()   // dismiss agent-a
        bridge.revealAgentsInspector()
        XCTAssertFalse(bridge.showInspector, "the dismissed agent must not reopen the panel")

        bridge.subagents["agent-b"] = runningAgent("agent-b")
        bridge.revealAgentsInspector()
        XCTAssertFalse(
            bridge.showInspector,
            "an overlapping child belongs to the activity cycle the user already dismissed")

        bridge.subagents["agent-a"]?.status = .completed
        bridge.revealAgentsInspector()
        XCTAssertFalse(
            bridge.showInspector,
            "the panel must stay closed while an overlapping dismissed child is still running")

        bridge.subagents["agent-b"]?.status = .completed
        bridge.subagents["agent-c"] = runningAgent("agent-c")
        bridge.revealAgentsInspector()

        XCTAssertTrue(bridge.showInspector, "a later disjoint delegation may announce itself")
        XCTAssertEqual(bridge.inspectorTab, .agents)
    }

    func testReopeningByHandRestoresAutomaticReveals() {
        let bridge = makeBridge()
        bridge.showInspector = true
        bridge.subagents["agent-a"] = runningAgent("agent-a")
        bridge.userToggledInspector()          // closed by the user
        XCTAssertTrue(bridge.inspectorAutoRevealSuppressed)

        bridge.userToggledInspector()          // and opened again by the user
        XCTAssertTrue(bridge.showInspector)
        XCTAssertFalse(bridge.inspectorAutoRevealSuppressed)

        // Closing it programmatically is not a user decision, so it must not suppress anything.
        bridge.showInspector = false
        bridge.revealAgentsInspector()
        XCTAssertTrue(bridge.showInspector)
        XCTAssertEqual(bridge.inspectorTab, .agents)
    }

    func testWorkflowEventIngressRevealsOnlyWhenTheMultiAgentCycleBegins() {
        let bridge = makeBridge()
        bridge.showInspector = false
        bridge.inspectorTab = .files

        bridge.applyForegroundWorkflowIngress(WorkflowUpdate([
            "phase": "started",
            "taskId": "workflow-task",
            "toolUseId": "workflow-tool",
            "isWorkflowRun": true,
            "status": "running",
        ]))

        XCTAssertTrue(bridge.showInspector)
        XCTAssertEqual(bridge.inspectorTab, .agents)

        // Once announced, the person may choose another tab. Repeated metadata and later children
        // in the same multi-agent cycle must preserve that choice.
        bridge.inspectorTab = .changes
        bridge.applyForegroundWorkflowIngress(WorkflowUpdate([
            "phase": "progress",
            "taskId": "workflow-task",
            "isWorkflowRun": true,
            "status": "running",
        ]))
        XCTAssertTrue(bridge.showInspector)
        XCTAssertEqual(bridge.inspectorTab, .changes)

        // A newly observed child is still part of the already-announced cycle.
        bridge.applyForegroundWorkflowIngress(WorkflowUpdate([
            "phase": "progress",
            "taskId": "workflow-task",
            "workflowProgress": [[
                "type": "workflow_agent",
                "index": 0,
                "phaseIndex": 0,
                "phaseTitle": "Research",
                "label": "Researcher",
                "state": "progress",
            ]],
        ]))
        XCTAssertTrue(bridge.showInspector)
        XCTAssertEqual(bridge.inspectorTab, .changes)
    }

    func testWorkflowPromotionCollapsesTaskMirrorWithoutReopeningDismissedInspector() {
        let bridge = makeBridge()
        bridge.subagents = applySubagentToolUse(
            [:],
            toolUseId: "workflow-tool",
            parentToolUseId: nil,
            subagentType: "workflow",
            task: "Run the workflow")
        bridge.activeAgents = 1
        bridge.agentActivity = [.state(
            .model,
            turnID: "turn",
            agentID: AgentActivityIdentity.subagent("workflow-tool"),
            detail: "Delegated")]
        bridge.showInspector = true
        bridge.userToggledInspector()
        XCTAssertFalse(bridge.showInspector)

        bridge.applyForegroundWorkflowIngress(WorkflowUpdate([
            "phase": "started",
            "taskId": "workflow-task",
            "toolUseId": "workflow-tool",
            "isWorkflowRun": true,
            "status": "running",
        ]))

        XCTAssertNil(bridge.subagents["workflow-tool"])
        XCTAssertEqual(bridge.activeAgents, 0)
        XCTAssertFalse(bridge.agentActivity.contains {
            $0.kind == .state
                && $0.agentID == AgentActivityIdentity.subagent("workflow-tool")
        })
        XCTAssertFalse(
            bridge.showInspector,
            "promoting a Task mirror into its workflow is not a second announcement")

        // A child joining that still-active dismissed workflow belongs to the same activity cycle.
        bridge.applyForegroundWorkflowIngress(WorkflowUpdate([
            "phase": "progress",
            "taskId": "workflow-task",
            "workflowProgress": [[
                "type": "workflow_agent",
                "index": 0,
                "phaseIndex": 0,
                "phaseTitle": "Research",
                "label": "Researcher",
                "state": "progress",
            ]],
        ]))
        XCTAssertFalse(bridge.showInspector)

        bridge.applyForegroundWorkflowIngress(WorkflowUpdate([
            "phase": "notification",
            "taskId": "workflow-task",
            "toolUseId": "workflow-tool",
            "status": "failed",
            "workflowProgress": [[
                "type": "workflow_agent",
                "index": 0,
                "phaseIndex": 0,
                "phaseTitle": "Research",
                "label": "Researcher",
                "state": "error",
                "error": "Synthetic failure",
            ]],
        ]))
        // A final cumulative snapshot may repeat stale progress. Neither the child nor the removed
        // Task mirror may become live again.
        bridge.applyForegroundWorkflowIngress(WorkflowUpdate([
            "phase": "updated",
            "taskId": "workflow-task",
            "toolUseId": "workflow-tool",
            "status": "failed",
            "workflowProgress": [[
                "type": "workflow_agent",
                "index": 0,
                "phaseIndex": 0,
                "phaseTitle": "Research",
                "label": "Researcher",
                "state": "progress",
            ]],
        ]))
        XCTAssertEqual(bridge.workflowRuns["workflow-tool"]?.status, .failed)
        XCTAssertEqual(bridge.workflowRuns["workflow-tool"]?.agents["0:0"]?.state, .failed)
        XCTAssertNil(bridge.delegateStatus)
        XCTAssertEqual(runningDelegatedAgentCount(
            subagents: bridge.subagents,
            workflowRuns: bridge.workflowRuns), 0)
        XCTAssertFalse(hasNonterminalDelegatedWork(
            workflowRuns: bridge.workflowRuns,
            subagents: bridge.subagents))
    }

    func testTerminalWorkflowAggregateDoesNotReannounceAChildInTheSameCycle() {
        let bridge = makeBridge()
        bridge.showInspector = false
        bridge.applyForegroundWorkflowIngress(WorkflowUpdate([
            "phase": "started",
            "taskId": "workflow",
            "isWorkflowRun": true,
            "status": "running",
        ]))
        XCTAssertTrue(bridge.showInspector)

        // A provider can publish the cumulative child snapshot and terminal aggregate together.
        // The child remains live, so this event is a new delegated identity even though its parent
        // already says completed.
        bridge.showInspector = false
        bridge.applyForegroundWorkflowIngress(WorkflowUpdate([
            "phase": "updated",
            "taskId": "workflow",
            "status": "completed",
            "workflowProgress": [[
                "type": "workflow_agent",
                "index": 0,
                "phaseIndex": 0,
                "phaseTitle": "Research",
                "label": "Researcher",
                "state": "progress",
            ]],
        ]))

        XCTAssertEqual(bridge.workflowRuns["workflow"]?.status, .completed)
        XCTAssertEqual(bridge.workflowRuns["workflow"]?.agents["0:0"]?.state, .progress)
        XCTAssertFalse(bridge.showInspector)
    }
}
