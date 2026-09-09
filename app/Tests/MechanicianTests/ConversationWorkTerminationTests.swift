import XCTest
@testable import Mechanician

@MainActor
final class ConversationWorkTerminationTests: XCTestCase {
    private let stoppedAt = Date(timeIntervalSince1970: 2_000)

    func testUsageLimitDelegateReasonIsACompleteSentence() {
        let limit = UsageLimitError(rateLimitType: "five_hour")

        XCTAssertEqual(
            limit.delegatedFailureReason,
            "Stopped because Claude’s usage limit ended the parent turn.")
        XCTAssertFalse(limit.delegatedFailureReason.contains("reached ended"))
    }

    private func runningWorkflow(
        runKey: String = "run-1",
        childState: WorkflowAgentState = .progress
    ) -> WorkflowRun {
        var run = WorkflowRun(runKey: runKey, status: .running)
        run.runTaskId = "\(runKey)-task"
        run.agents = [
            "0:0": WorkflowAgent(
                index: 0,
                label: "finder",
                phaseIndex: 0,
                phaseTitle: "Find",
                state: childState),
        ]
        return run
    }

    func testDeleteRefusesConversationWithDelegateOnlyWork() {
        let support = FileManager.default.temporaryDirectory
            .appendingPathComponent("mechanician-delete-live-delegate-\(UUID().uuidString)")
        let bridge = AgentBridge(settingsBaseOverride: support, environmentOverride: [:])
        let id = UUID()
        var child = SubagentRun(
            key: "delegate-only-child",
            subagentType: "Explore",
            task: "continue after the root turn")
        child.taskId = "delegate-only-task"
        let conversation = Conversation(
            id: id,
            title: "Delegate still running",
            cwd: "",
            sdkSessionId: nil,
            messages: [TranscriptEntry(kind: .user, text: "keep this record")],
            updatedAt: Date(),
            subagents: [child.key: child])
        ConversationStore.shared.upsert(conversation)
        defer {
            bridge.currentID = nil
            bridge.shutdown()
            ConversationStore.shared.remove(id, permanently: true)
            ConversationStore.shared.flushSaves()
            try? FileManager.default.removeItem(at: support)
        }

        bridge.currentID = id
        bridge.entries = conversation.messages
        bridge.subagents = conversation.subagents
        bridge.activeAgents = 1
        XCTAssertTrue(bridge.hasStoppableConversationWork)

        bridge.deleteConversation(id)

        XCTAssertTrue(
            ConversationStore.shared.contains(id),
            "Delete must wait until delegate-only work is stopped and durably terminalized")
        XCTAssertEqual(bridge.currentID, id)
    }

    func testProviderFailureTerminalizesRunsChildrenAndSubagentsTogether() {
        var preserved = SubagentRun(key: "preserved", subagentType: "Explore", task: "scan")
        preserved.taskId = "child-preserved"
        preserved.error = "Provider-owned child error"
        var filled = SubagentRun(key: "filled", subagentType: "Codex", task: "inspect")
        filled.taskId = "child-filled"
        var subagents = ["preserved": preserved, "filled": filled]

        var inconsistent = runningWorkflow(runKey: "legacy")
        inconsistent.status = .completed
        inconsistent.endedAt = Date(timeIntervalSince1970: 1_900)
        var workflowRuns = [
            "run-1": runningWorkflow(),
            "legacy": inconsistent,
        ]
        var activity: [AgentActivityRecord] = [
            .state(
                .model,
                turnID: "turn-1",
                agentID: AgentActivityIdentity.subagent("child-filled"),
                detail: "Working",
                at: Date(timeIntervalSince1970: 1_950)),
        ]
        let reason = "Stopped because Claude’s usage limit ended the parent turn."

        XCTAssertTrue(terminalizeDelegatedWorkState(
            workflowRuns: &workflowRuns,
            subagents: &subagents,
            agentActivity: &activity,
            outcome: .providerFailure(reason),
            turnID: "turn-1",
            at: stoppedAt))

        XCTAssertEqual(workflowRuns["run-1"]?.status, .failed)
        XCTAssertEqual(workflowRuns["run-1"]?.agents["0:0"]?.state, .failed)
        XCTAssertEqual(workflowRuns["run-1"]?.error, reason)
        XCTAssertEqual(workflowRuns["run-1"]?.agents["0:0"]?.error, reason)
        XCTAssertEqual(workflowRuns["run-1"]?.endedAt, stoppedAt)
        XCTAssertEqual(workflowRuns["run-1"]?.agents["0:0"]?.endedAt, stoppedAt)

        XCTAssertEqual(
            workflowRuns["legacy"]?.status,
            .completed,
            "a terminal aggregate stays monotonic while its inconsistent live child is healed")
        XCTAssertEqual(workflowRuns["legacy"]?.agents["0:0"]?.state, .failed)
        XCTAssertEqual(workflowRuns["legacy"]?.agents["0:0"]?.endedAt, stoppedAt)

        XCTAssertEqual(subagents["preserved"]?.status, .failed)
        XCTAssertEqual(subagents["preserved"]?.error, "Provider-owned child error")
        XCTAssertEqual(subagents["filled"]?.status, .failed)
        XCTAssertEqual(subagents["filled"]?.error, reason)
        XCTAssertEqual(subagents["filled"]?.endedAt, stoppedAt)

        let terminalRecords = activity.filter {
            $0.kind == .state && $0.phase == .failed && $0.at == stoppedAt
        }
        XCTAssertEqual(terminalRecords.count, 4)
        XCTAssertTrue(terminalRecords.allSatisfy { $0.turnID == "turn-1" })

        let recordCount = activity.count
        XCTAssertFalse(terminalizeDelegatedWorkState(
            workflowRuns: &workflowRuns,
            subagents: &subagents,
            agentActivity: &activity,
            outcome: .providerFailure(reason),
            turnID: "turn-1",
            at: stoppedAt.addingTimeInterval(10)))
        XCTAssertEqual(activity.count, recordCount, "reconciliation is idempotent")
    }

    func testProviderFailureSettlesOnlyDelegatesOwnedByItsTurnAndProviderLane() {
        let claude = ModelSelection(
            access: .claudeSubscription,
            modelID: "claude-child")
        let codex = ModelSelection(
            access: .codexSubscription,
            modelID: "gpt-failing")
        var claudeChild = SubagentRun(
            key: "claude-tool",
            subagentType: "Explore",
            task: "continue after the parent succeeds")
        claudeChild.taskId = "claude-child"
        var codexChild = SubagentRun(
            key: "codex-tool",
            subagentType: "Explore",
            task: "belongs to the failing turn")
        codexChild.taskId = "codex-child"
        var subagents = [
            claudeChild.key: claudeChild,
            codexChild.key: codexChild,
        ]
        var workflowRuns: [String: WorkflowRun] = [:]
        var activity: [AgentActivityRecord] = [
            AgentActivityRecord.state(
                .model,
                turnID: "turn-claude",
                agentID: AgentActivityIdentity.subagent("claude-child"))
                .attributed(to: claude),
            AgentActivityRecord.state(
                .completed,
                turnID: "turn-claude")
                .attributed(to: claude),
            AgentActivityRecord.state(
                .model,
                turnID: "turn-codex",
                agentID: AgentActivityIdentity.subagent("codex-child"))
                .attributed(to: codex),
        ]
        let reason = "Stopped because the provider ended the parent turn."

        XCTAssertTrue(terminalizeDelegatedWorkState(
            workflowRuns: &workflowRuns,
            subagents: &subagents,
            agentActivity: &activity,
            outcome: .providerFailure(reason),
            scope: terminalTurnDelegatedWorkScope(
                turnID: "turn-codex",
                selection: codex,
                agentActivity: activity),
            turnID: "turn-codex",
            selection: codex,
            at: stoppedAt))

        XCTAssertEqual(
            subagents["claude-tool"]?.status,
            .running,
            "a later provider failure cannot fail a delegate from a successful earlier turn")
        XCTAssertNil(subagents["claude-tool"]?.endedAt)
        XCTAssertEqual(subagents["codex-tool"]?.status, .failed)
        XCTAssertEqual(subagents["codex-tool"]?.error, reason)
        XCTAssertTrue(activity.contains {
            $0.agentID == AgentActivityIdentity.subagent("codex-child")
                && $0.turnID == "turn-codex"
                && $0.providerAccess == codex.access
                && $0.phase == .failed
        })
        XCTAssertFalse(activity.contains {
            $0.agentID == AgentActivityIdentity.subagent("claude-child")
                && $0.phase == .failed
        })
    }

    func testAmbiguousLaneLessDelegateIsNotClaimedByLaterProviderFailure() {
        let claude = ModelSelection(
            access: .claudeSubscription,
            modelID: "claude")
        let codex = ModelSelection(
            access: .codexSubscription,
            modelID: "gpt")
        var child = SubagentRun(
            key: "legacy-child",
            subagentType: "Explore",
            task: "legacy lane-less work")
        child.taskId = "legacy-task"
        var subagents = [child.key: child]
        var workflowRuns: [String: WorkflowRun] = [:]
        var activity: [AgentActivityRecord] = [
            AgentActivityRecord.tool(
                "Agent",
                turnID: "turn-claude",
                agentID: AgentActivityIdentity.root)
                .attributed(to: claude),
            AgentActivityRecord.tool(
                "Agent",
                turnID: "turn-codex",
                agentID: AgentActivityIdentity.root)
                .attributed(to: codex),
        ]

        XCTAssertFalse(terminalizeDelegatedWorkState(
            workflowRuns: &workflowRuns,
            subagents: &subagents,
            agentActivity: &activity,
            outcome: .providerFailure("provider failed"),
            scope: terminalTurnDelegatedWorkScope(
                turnID: "turn-codex",
                selection: codex,
                agentActivity: activity),
            turnID: "turn-codex",
            selection: codex,
            at: stoppedAt))
        XCTAssertEqual(subagents[child.key]?.status, .running)
    }

    func testUserStopUsesStoppedForWorkflowChildrenAndClosesEveryLane() {
        var workflowRuns = ["run-1": runningWorkflow()]
        var child = SubagentRun(key: "spawn-1", subagentType: "Explore", task: "scan")
        child.taskId = "child-1"
        var subagents = ["spawn-1": child]
        var activity: [AgentActivityRecord] = [
            .state(
                .model,
                turnID: "turn-1",
                agentID: AgentActivityIdentity.workflow(runKey: "run-1", agentKey: "0:0"),
                at: stoppedAt.addingTimeInterval(-5)),
            .state(
                .tool,
                turnID: "turn-1",
                agentID: AgentActivityIdentity.subagent("child-1"),
                at: stoppedAt.addingTimeInterval(-4)),
        ]

        XCTAssertTrue(terminalizeDelegatedWorkState(
            workflowRuns: &workflowRuns,
            subagents: &subagents,
            agentActivity: &activity,
            outcome: .userStopped,
            turnID: "turn-1",
            at: stoppedAt))

        XCTAssertEqual(workflowRuns["run-1"]?.status, .stopped)
        XCTAssertEqual(workflowRuns["run-1"]?.agents["0:0"]?.state, .stopped)
        XCTAssertEqual(workflowRuns["run-1"]?.agents["0:0"]?.endedAt, stoppedAt)
        XCTAssertNil(workflowRuns["run-1"]?.error)
        XCTAssertNil(workflowRuns["run-1"]?.agents["0:0"]?.error)
        XCTAssertEqual(subagents["spawn-1"]?.status, .stopped)
        XCTAssertNil(subagents["spawn-1"]?.error)

        let stoppedIDs = Set(activity.filter {
            $0.kind == .state && $0.phase == .stopped && $0.at == stoppedAt
        }.map(\.agentID))
        XCTAssertEqual(stoppedIDs, [
            AgentActivityIdentity.workflow(runKey: "run-1", agentKey: "0:0"),
            AgentActivityIdentity.subagent("child-1"),
        ])
    }

    func testLateToolResultsEnrichTerminalChildrenWithoutContradictoryCompletion() {
        let originalEnd = Date(timeIntervalSince1970: 1_500)
        var stopped = SubagentRun(
            key: "stopped",
            subagentType: "Explore",
            task: "scan")
        stopped.status = .stopped
        stopped.endedAt = originalEnd
        var failed = SubagentRun(
            key: "failed",
            subagentType: "Explore",
            task: "scan")
        failed.status = .failed
        failed.endedAt = originalEnd
        var completed = SubagentRun(
            key: "completed",
            subagentType: "Explore",
            task: "scan")
        completed.status = .completed
        completed.endedAt = originalEnd
        let running = SubagentRun(
            key: "running",
            subagentType: "Explore",
            task: "scan")
        var subagents = [
            "stopped": stopped,
            "failed": failed,
            "completed": completed,
            "running": running,
        ]

        XCTAssertNil(applySubagentToolResultState(
            subagents: &subagents,
            toolUseID: "stopped",
            failed: false,
            result: "late stopped result",
            at: stoppedAt))
        XCTAssertEqual(subagents["stopped"]?.status, .stopped)
        XCTAssertEqual(subagents["stopped"]?.endedAt, originalEnd)
        XCTAssertEqual(subagents["stopped"]?.resultPreview, "late stopped result")

        XCTAssertNil(applySubagentToolResultState(
            subagents: &subagents,
            toolUseID: "failed",
            failed: false,
            result: "late failed result",
            at: stoppedAt))
        XCTAssertEqual(subagents["failed"]?.status, .failed)
        XCTAssertEqual(subagents["failed"]?.resultPreview, "late failed result")

        XCTAssertEqual(applySubagentToolResultState(
            subagents: &subagents,
            toolUseID: "completed",
            failed: true,
            result: "authoritative failure",
            at: stoppedAt), .failed)
        XCTAssertEqual(subagents["completed"]?.status, .failed)
        XCTAssertEqual(
            subagents["completed"]?.endedAt,
            originalEnd,
            "terminal-to-terminal refinement preserves the original completion time")

        XCTAssertEqual(applySubagentToolResultState(
            subagents: &subagents,
            toolUseID: "running",
            failed: false,
            result: "ordinary result",
            at: stoppedAt), .completed)
        XCTAssertEqual(subagents["running"]?.status, .completed)
        XCTAssertEqual(subagents["running"]?.endedAt, stoppedAt)
    }

    func testAsyncAgentLaunchStaysActiveUntilAuthoritativeTaskNotification() {
        let toolUseID = "tool-agent"
        let taskID = "provider-child"
        var subagents = applySubagentToolUse(
            [:],
            toolUseId: toolUseID,
            parentToolUseId: nil,
            subagentType: "Explore",
            task: "Inspect the lifecycle")
        let internalLaunchText = """
        Async agent launched successfully.
        The agent is working in the background. You will be notified automatically when it completes.
        """
        let disposition = subagentToolResultDisposition(
            wireDisposition: "launched",
            failed: false,
            legacyResultText: internalLaunchText)

        XCTAssertEqual(disposition, .launched)
        XCTAssertNil(applySubagentToolResultState(
            subagents: &subagents,
            toolUseID: toolUseID,
            failed: false,
            result: internalLaunchText,
            disposition: disposition,
            taskID: taskID,
            at: stoppedAt))
        XCTAssertEqual(subagents[toolUseID]?.status, .running)
        XCTAssertEqual(subagents[toolUseID]?.taskId, taskID)
        XCTAssertNil(subagents[toolUseID]?.endedAt)
        XCTAssertNil(
            subagents[toolUseID]?.resultPreview,
            "model-directed launch metadata is not the child agent's result")

        subagents = applySubagentUpdate(subagents, WorkflowUpdate([
            "phase": "progress",
            "taskId": taskID,
            "toolUseId": toolUseID,
            "status": "running",
            "summary": "Still inspecting",
        ]))
        XCTAssertEqual(subagents[toolUseID]?.status, .running)
        XCTAssertNil(subagents[toolUseID]?.endedAt)

        subagents = applySubagentUpdate(subagents, WorkflowUpdate([
            "phase": "notification",
            "taskId": taskID,
            "toolUseId": toolUseID,
            "status": "completed",
            "summary": "Inspection complete",
        ]))
        XCTAssertEqual(subagents[toolUseID]?.status, .completed)
        XCTAssertNotNil(subagents[toolUseID]?.endedAt)
        XCTAssertEqual(subagents[toolUseID]?.summary, "Inspection complete")
    }

    func testSubagentLaunchDispositionUsesStructuredTruthWithNarrowLegacyFallback() {
        XCTAssertEqual(subagentToolResultDisposition(
            wireDisposition: "launched",
            failed: false,
            legacyResultText: "unrelated"), .launched)
        XCTAssertEqual(subagentToolResultDisposition(
            wireDisposition: "completed",
            failed: false,
            legacyResultText: nil), .terminal)
        XCTAssertEqual(subagentToolResultDisposition(
            wireDisposition: "launched",
            failed: true,
            legacyResultText: nil), .terminal)
        XCTAssertEqual(subagentToolResultDisposition(
            wireDisposition: nil,
            failed: false,
            legacyResultText: """
            Async agent launched successfully.
            The agent is working in the background.
            """), .launched)
        XCTAssertEqual(subagentToolResultDisposition(
            wireDisposition: nil,
            failed: false,
            legacyResultText: "Agent completed successfully."), .terminal)
    }

    func testTerminalizationClosesEachChildsOwnTurnAndProviderLane() {
        let standaloneSelection = ModelSelection(
            access: .claudeSubscription,
            modelID: "claude-child")
        let workflowSelection = ModelSelection(
            access: .anthropicAPI,
            modelID: "claude-workflow")
        let unrelatedLatestSelection = ModelSelection(
            access: .codexSubscription,
            modelID: "gpt-latest")

        var standalone = SubagentRun(
            key: "spawn-a",
            subagentType: "Explore",
            task: "scan")
        standalone.taskId = "task-a"
        let workflow = runningWorkflow(runKey: "workflow-a")
        var workflowRuns = ["workflow-a": workflow]
        var subagents = ["spawn-a": standalone]
        var activity: [AgentActivityRecord] = [
            AgentActivityRecord.state(
                .model,
                turnID: "turn-a",
                agentID: AgentActivityIdentity.subagent("spawn-a"),
                at: stoppedAt.addingTimeInterval(-20))
                .attributed(to: standaloneSelection),
            AgentActivityRecord.state(
                .tool,
                turnID: "turn-workflow",
                agentID: AgentActivityIdentity.workflow(
                    runKey: "workflow-a",
                    agentKey: "0:0"),
                at: stoppedAt.addingTimeInterval(-15))
                .attributed(to: workflowSelection),
            AgentActivityRecord.state(
                .completed,
                turnID: "turn-b",
                at: stoppedAt.addingTimeInterval(-5))
                .attributed(to: unrelatedLatestSelection),
        ]

        XCTAssertTrue(terminalizeDelegatedWorkState(
            workflowRuns: &workflowRuns,
            subagents: &subagents,
            agentActivity: &activity,
            outcome: .userStopped,
            turnID: "turn-b",
            selection: unrelatedLatestSelection,
            at: stoppedAt))

        let standaloneClose = activity.last {
            $0.agentID == AgentActivityIdentity.subagent("task-a")
                && $0.phase == .stopped
        }
        XCTAssertEqual(standaloneClose?.turnID, "turn-a")
        XCTAssertEqual(standaloneClose?.providerAccess, standaloneSelection.access)
        XCTAssertEqual(standaloneClose?.modelID, standaloneSelection.modelID)

        let workflowClose = activity.last {
            $0.agentID == AgentActivityIdentity.workflow(
                runKey: "workflow-a",
                agentKey: "0:0")
                && $0.phase == .stopped
        }
        XCTAssertEqual(workflowClose?.turnID, "turn-workflow")
        XCTAssertEqual(workflowClose?.providerAccess, workflowSelection.access)
        XCTAssertEqual(workflowClose?.modelID, workflowSelection.modelID)
    }

    func testProcessTerminationIncludesCompletedRoutesOnlyWhileDelegatesRemainActive() {
        let active = UUID()
        let completedWithDelegate = UUID()
        let completedIdle = UUID()

        let affected = conversationIDsAffectedByProcessTermination([
            (
                conversationID: active,
                reservesConversation: true,
                hasRunningDelegates: false
            ),
            (
                conversationID: completedWithDelegate,
                reservesConversation: false,
                hasRunningDelegates: true
            ),
            (
                conversationID: completedIdle,
                reservesConversation: false,
                hasRunningDelegates: false
            ),
        ])

        XCTAssertEqual(affected, [active, completedWithDelegate])
    }

    func testConversationStopSettlesDelegateOnlyWorkAndDoesNotTouchAnotherConversation() {
        let support = FileManager.default.temporaryDirectory
            .appendingPathComponent("mechanician-conversation-stop-\(UUID().uuidString)")
        let bridge = AgentBridge(settingsBaseOverride: support, environmentOverride: [:])
        let currentID = UUID()
        let otherID = UUID()

        var currentChild = SubagentRun(
            key: "current-child",
            subagentType: "Explore",
            task: "scan current")
        currentChild.taskId = "current-task"
        var otherChild = SubagentRun(
            key: "other-child",
            subagentType: "Explore",
            task: "scan other")
        otherChild.taskId = "other-task"
        let current = Conversation(
            id: currentID,
            title: "Current",
            cwd: "",
            sdkSessionId: nil,
            modelSelection: ModelSelection(
                access: .claudeSubscription,
                modelID: "claude-test"),
            messages: [TranscriptEntry(kind: .user, text: "work")],
            updatedAt: Date(),
            subagents: ["current-child": currentChild])
        let other = Conversation(
            id: otherID,
            title: "Other",
            cwd: "",
            sdkSessionId: nil,
            messages: [TranscriptEntry(kind: .user, text: "other work")],
            updatedAt: Date(),
            subagents: ["other-child": otherChild])
        ConversationStore.shared.upsert(current)
        ConversationStore.shared.upsert(other)
        defer {
            bridge.currentID = nil
            bridge.shutdown()
            ConversationStore.shared.remove(currentID, permanently: true)
            ConversationStore.shared.remove(otherID, permanently: true)
            ConversationStore.shared.flushSaves()
            try? FileManager.default.removeItem(at: support)
        }

        bridge.currentID = currentID
        bridge.entries = current.messages
        bridge.subagents = current.subagents
        bridge.workflowRuns = current.workflowRuns
        bridge.agentActivity = current.agentActivity
        bridge.activeAgents = 1
        let nextSelection = ModelSelection(
            access: .codexSubscription,
            modelID: "gpt-test")
        XCTAssertTrue(bridge.hasStoppableConversationWork)
        XCTAssertEqual(
            bridge.modelSelectionBlocker(for: nextSelection),
            .delegatedWork(count: 1))

        bridge.stopConversationWork()

        XCTAssertEqual(bridge.subagents["current-child"]?.status, .stopped)
        XCTAssertEqual(bridge.activeAgents, 0)
        XCTAssertFalse(bridge.hasStoppableConversationWork)
        XCTAssertNil(
            bridge.modelSelectionBlocker(for: nextSelection),
            "provider selection must be immediately unblocked after stale work reconciles")
        XCTAssertEqual(
            ConversationStore.shared.conversation(currentID)?
                .subagents["current-child"]?.status,
            .stopped)
        XCTAssertEqual(
            ConversationStore.shared.conversation(otherID)?
                .subagents["other-child"]?.status,
            .running,
            "conversation recovery is scoped and cannot settle another window/provider lane")
        XCTAssertTrue(bridge.agentActivity.contains {
            $0.agentID == AgentActivityIdentity.subagent("current-task")
                && $0.phase == .stopped
        })

        let activityCount = bridge.agentActivity.count
        bridge.stopConversationWork()
        XCTAssertEqual(bridge.agentActivity.count, activityCount, "repeated Stop is idempotent")
    }

    func testStopAndRedirectSettlesDelegateOnlyWorkAndStagesReplacementExactlyOnce() {
        let support = FileManager.default.temporaryDirectory
            .appendingPathComponent("mechanician-orphan-redirect-\(UUID().uuidString)")
        let bridge = AgentBridge(settingsBaseOverride: support, environmentOverride: [:])
        let currentID = UUID()
        let otherID = UUID()
        let replacement = "Continue with the corrected direction"

        var currentChild = SubagentRun(
            key: "current-child",
            subagentType: "Explore",
            task: "abandoned direction")
        currentChild.taskId = "current-task"
        var otherChild = SubagentRun(
            key: "other-child",
            subagentType: "Explore",
            task: "unrelated work")
        otherChild.taskId = "other-task"
        let current = Conversation(
            id: currentID,
            title: "Current",
            cwd: "",
            sdkSessionId: nil,
            modelSelection: ModelSelection(
                access: .claudeSubscription,
                modelID: "claude-test"),
            messages: [TranscriptEntry(kind: .user, text: "original direction")],
            updatedAt: Date(),
            subagents: [currentChild.key: currentChild])
        let other = Conversation(
            id: otherID,
            title: "Other",
            cwd: "",
            sdkSessionId: nil,
            messages: [TranscriptEntry(kind: .user, text: "other direction")],
            updatedAt: Date(),
            subagents: [otherChild.key: otherChild])
        ConversationStore.shared.upsert(current)
        ConversationStore.shared.upsert(other)
        defer {
            bridge.currentID = nil
            bridge.shutdown()
            ConversationStore.shared.remove(currentID, permanently: true)
            ConversationStore.shared.remove(otherID, permanently: true)
            ConversationStore.shared.flushSaves()
            try? FileManager.default.removeItem(at: support)
        }

        bridge.currentID = currentID
        bridge.entries = current.messages
        bridge.subagents = current.subagents
        bridge.activeAgents = 1

        bridge.stopAndRedirect(replacement)

        XCTAssertEqual(bridge.subagents[currentChild.key]?.status, .stopped)
        XCTAssertEqual(bridge.activeAgents, 0)
        XCTAssertFalse(bridge.hasStoppableConversationWork)
        XCTAssertEqual(bridge.queuedPrompts, [replacement])
        XCTAssertEqual(
            ConversationStore.shared.conversation(currentID)?.queuedPrompts,
            [replacement])
        let visibleReplacementCount = bridge.queuedPrompts.filter {
            $0 == replacement
        }.count + bridge.entries.filter {
            $0.kind == .user && $0.text == replacement
        }.count
        XCTAssertEqual(
            visibleReplacementCount,
            1,
            "an unavailable delegate-only lane stages the exact redirect once")

        XCTAssertEqual(
            ConversationStore.shared.conversation(otherID)?
                .subagents[otherChild.key]?.status,
            .running)
        XCTAssertTrue(
            ConversationStore.shared.conversation(otherID)?.queuedPrompts.isEmpty == true)
        XCTAssertEqual(
            ConversationStore.shared.conversation(otherID)?.messages.map(\.text),
            ["other direction"])
    }

    func testDuplicateViewerRoutesStopToLiveConversationOwnerOnly() {
        let exactLaneOwnerRank = stoppableWorkOwnershipRank(
            hasReservation: false,
            retainedTurnIDs: ["child-turn"],
            exactDelegateOwnerTurnIDs: ["child-turn"],
            conservativeDelegateOwnerTurnIDs: ["child-turn"],
            hasActiveAgentProjection: false,
            hasDelegatedWork: true,
            isCurrentViewer: false)
        let unrelatedCompletedRouteRank = stoppableWorkOwnershipRank(
            hasReservation: false,
            retainedTurnIDs: ["unrelated-turn"],
            exactDelegateOwnerTurnIDs: ["child-turn"],
            conservativeDelegateOwnerTurnIDs: ["child-turn"],
            hasActiveAgentProjection: false,
            hasDelegatedWork: true,
            isCurrentViewer: false)
        XCTAssertEqual(exactLaneOwnerRank, 1)
        XCTAssertEqual(unrelatedCompletedRouteRank, 4)
        XCTAssertLessThan(
            exactLaneOwnerRank ?? .max,
            unrelatedCompletedRouteRank ?? .max,
            "the child-lane owner must receive stop_task ahead of a stale provider route")

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("mechanician-duplicate-stop-\(UUID().uuidString)")
        let owner = AgentBridge(
            settingsBaseOverride: root.appendingPathComponent("owner"),
            environmentOverride: [:])
        let viewer = AgentBridge(
            settingsBaseOverride: root.appendingPathComponent("viewer"),
            environmentOverride: [:])
        let otherOwner = AgentBridge(
            settingsBaseOverride: root.appendingPathComponent("other"),
            environmentOverride: [:])
        let conversationID = UUID()
        let otherID = UUID()

        var ownedChild = SubagentRun(
            key: "owned-child",
            subagentType: "Explore",
            task: "scan owned conversation")
        ownedChild.taskId = "owned-task"
        var otherChild = SubagentRun(
            key: "other-child",
            subagentType: "Explore",
            task: "scan other conversation")
        otherChild.taskId = "other-task"
        let conversation = Conversation(
            id: conversationID,
            title: "Owned",
            cwd: "",
            sdkSessionId: nil,
            modelSelection: ModelSelection(
                access: .claudeSubscription,
                modelID: "claude-test"),
            messages: [TranscriptEntry(kind: .user, text: "work")],
            updatedAt: Date())
        let otherConversation = Conversation(
            id: otherID,
            title: "Other",
            cwd: "",
            sdkSessionId: nil,
            modelSelection: ModelSelection(
                access: .codexSubscription,
                modelID: "gpt-test"),
            messages: [TranscriptEntry(kind: .user, text: "other work")],
            updatedAt: Date(),
            subagents: ["other-child": otherChild])
        ConversationStore.shared.upsert(conversation)
        ConversationStore.shared.upsert(otherConversation)
        owner.currentID = conversationID
        owner.entries = conversation.messages
        owner.subagents = ["owned-child": ownedChild]
        owner.activeAgents = 1
        viewer.currentID = conversationID
        viewer.entries = conversation.messages
        otherOwner.currentID = otherID
        otherOwner.entries = otherConversation.messages
        otherOwner.subagents = otherConversation.subagents
        otherOwner.activeAgents = 1
        AgentBridge.live.add(owner)
        AgentBridge.live.add(viewer)
        AgentBridge.live.add(otherOwner)
        defer {
            AgentBridge.live.remove(owner)
            AgentBridge.live.remove(viewer)
            AgentBridge.live.remove(otherOwner)
            owner.currentID = nil
            viewer.currentID = nil
            otherOwner.currentID = nil
            owner.shutdown()
            viewer.shutdown()
            otherOwner.shutdown()
            ConversationStore.shared.remove(conversationID, permanently: true)
            ConversationStore.shared.remove(otherID, permanently: true)
            ConversationStore.shared.flushSaves()
            try? FileManager.default.removeItem(at: root)
        }

        XCTAssertTrue(viewer.hasStoppableConversationWork)
        XCTAssertEqual(
            viewer.currentConversationAccessChangeBlocker,
            .delegatedWork(count: 1))

        viewer.stopConversationWork()

        XCTAssertEqual(owner.subagents["owned-child"]?.status, .stopped)
        XCTAssertEqual(viewer.subagents["owned-child"]?.status, .stopped)
        XCTAssertEqual(owner.activeAgents, 0)
        XCTAssertFalse(viewer.hasStoppableConversationWork)
        XCTAssertNil(viewer.currentConversationAccessChangeBlocker)
        XCTAssertEqual(
            ConversationStore.shared.conversation(conversationID)?
                .subagents["owned-child"]?.status,
            .stopped)
        XCTAssertEqual(otherOwner.subagents["other-child"]?.status, .running)
        XCTAssertEqual(
            ConversationStore.shared.conversation(otherID)?
                .subagents["other-child"]?.status,
            .running)

        let activityCount = owner.agentActivity.count
        viewer.stopConversationWork()
        XCTAssertEqual(owner.agentActivity.count, activityCount)
    }

    func testConversationSpecificStopSettlesBackgroundSnapshotWithoutChangingVisibleWork() {
        let support = FileManager.default.temporaryDirectory
            .appendingPathComponent("mechanician-background-stop-\(UUID().uuidString)")
        let bridge = AgentBridge(settingsBaseOverride: support, environmentOverride: [:])
        let visibleID = UUID()
        let backgroundID = UUID()
        var visibleChild = SubagentRun(
            key: "visible-child",
            subagentType: "Explore",
            task: "visible")
        visibleChild.taskId = "visible-task"
        var backgroundChild = SubagentRun(
            key: "background-child",
            subagentType: "Explore",
            task: "background")
        backgroundChild.taskId = "background-task"
        let visible = Conversation(
            id: visibleID,
            title: "Visible",
            cwd: "",
            sdkSessionId: nil,
            messages: [],
            updatedAt: Date(),
            subagents: ["visible-child": visibleChild])
        let background = Conversation(
            id: backgroundID,
            title: "Background",
            cwd: "",
            sdkSessionId: nil,
            messages: [],
            updatedAt: Date(),
            subagents: ["background-child": backgroundChild])
        ConversationStore.shared.upsert(visible)
        ConversationStore.shared.upsert(background)
        bridge.currentID = visibleID
        bridge.subagents = visible.subagents
        bridge.activeAgents = 1
        defer {
            bridge.currentID = nil
            bridge.shutdown()
            ConversationStore.shared.remove(visibleID, permanently: true)
            ConversationStore.shared.remove(backgroundID, permanently: true)
            ConversationStore.shared.flushSaves()
            try? FileManager.default.removeItem(at: support)
        }

        bridge.stopConversationWork(for: backgroundID)

        XCTAssertEqual(bridge.currentID, visibleID)
        XCTAssertEqual(bridge.subagents["visible-child"]?.status, .running)
        XCTAssertEqual(
            ConversationStore.shared.conversation(visibleID)?
                .subagents["visible-child"]?.status,
            .running)
        XCTAssertEqual(
            ConversationStore.shared.conversation(backgroundID)?
                .subagents["background-child"]?.status,
            .stopped)
        let activityCount = ConversationStore.shared.conversation(backgroundID)?
            .agentActivity.count
        bridge.stopConversationWork(for: backgroundID)
        XCTAssertEqual(
            ConversationStore.shared.conversation(backgroundID)?.agentActivity.count,
            activityCount)
    }

    func testEmptyViewerCanRecoverDurablyRecordedOrphan() {
        let support = FileManager.default.temporaryDirectory
            .appendingPathComponent("mechanician-durable-orphan-stop-\(UUID().uuidString)")
        let bridge = AgentBridge(settingsBaseOverride: support, environmentOverride: [:])
        let conversationID = UUID()
        var child = SubagentRun(
            key: "durable-child",
            subagentType: "Explore",
            task: "recover")
        child.taskId = "durable-task"
        let conversation = Conversation(
            id: conversationID,
            title: "Recover",
            cwd: "",
            sdkSessionId: nil,
            messages: [TranscriptEntry(kind: .user, text: "work")],
            updatedAt: Date(),
            subagents: ["durable-child": child])
        ConversationStore.shared.upsert(conversation)
        bridge.currentID = conversationID
        bridge.entries = conversation.messages
        defer {
            bridge.currentID = nil
            bridge.shutdown()
            ConversationStore.shared.remove(conversationID, permanently: true)
            ConversationStore.shared.flushSaves()
            try? FileManager.default.removeItem(at: support)
        }

        XCTAssertTrue(bridge.subagents.isEmpty, "the viewer intentionally has a stale empty map")
        XCTAssertTrue(bridge.hasStoppableConversationWork)
        XCTAssertEqual(
            bridge.currentConversationAccessChangeBlocker,
            .delegatedWork(count: 1))

        bridge.stopConversationWork()

        XCTAssertEqual(bridge.subagents["durable-child"]?.status, .stopped)
        XCTAssertEqual(
            ConversationStore.shared.conversation(conversationID)?
                .subagents["durable-child"]?.status,
            .stopped)
        XCTAssertFalse(bridge.hasStoppableConversationWork)
        XCTAssertNil(bridge.currentConversationAccessChangeBlocker)
    }
}
