import AppKit
import SwiftUI
import XCTest
@testable import Mechanician

/// The Stop button on an agent card, end to end: the id it carries, when it is offered, and what
/// pressing it does.
///
/// It was dead in the field for two compounding reasons, and neither produced any feedback:
///
/// - `stopTask` addressed the request to `currentTurnId` and bailed out entirely when no turn was
///   current — including the optimistic flip that makes the card stop spinning. A run left running
///   after its turn ended is precisely when a user reaches for Stop, and that is exactly when the
///   button did nothing at all.
/// - The button was shown only when the run carried a `taskId`, which arrives with the SDK's
///   `task_*` events and can stay nil for a run's whole life. Those cards spun forever with no
///   affordance to clear them.
@MainActor
final class AgentStopButtonTests: XCTestCase {
    private func descendants(of view: NSView) -> [NSView] {
        view.subviews + view.subviews.flatMap(descendants(of:))
    }

    private func assertRoadSignStyle(
        _ button: NSButton,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let expected = ComposerRoadSignImage.image(
            kind: .stop,
            size: AppKitAgentStopStyle.imageSize)
        XCTAssertNotNil(expected, file: file, line: line)
        XCTAssertTrue(button.image === expected, file: file, line: line)
        XCTAssertEqual(button.imageScaling, .scaleProportionallyDown, file: file, line: line)
        XCTAssertEqual(button.imagePosition, .imageOnly, file: file, line: line)
        XCTAssertNil(button.contentTintColor, file: file, line: line)
        XCTAssertEqual(button.image?.isTemplate, false, file: file, line: line)
    }

    private func makeBridge() -> (AgentBridge, URL) {
        let support = FileManager.default.temporaryDirectory
            .appendingPathComponent("mechanician-agent-stop-\(UUID().uuidString)", isDirectory: true)
        return (AgentBridge(settingsBaseOverride: support, environmentOverride: [:]), support)
    }

    private func running(key: String, taskId: String?) -> SubagentRun {
        var run = SubagentRun(key: key, subagentType: "Explore", task: "sweep the repo")
        run.taskId = taskId
        run.status = .running
        return run
    }

    // MARK: - Pressing Stop settles the card

    /// With no active turn there is nothing to send the request to, and the run is orphaned — it has
    /// no turn left to ever report a terminal event. Stop must still settle the card.
    func testStopSettlesAnOrphanedRunWithNoActiveTurn() {
        let (bridge, support) = makeBridge()
        defer { bridge.shutdown(); try? FileManager.default.removeItem(at: support) }

        bridge.subagents = ["k1": running(key: "k1", taskId: "task-1")]
        bridge.stopTask("task-1")

        XCTAssertEqual(
            bridge.subagents["k1"]?.status, .stopped,
            "the user asked for it to stop; a card that keeps spinning says the button is broken")
        XCTAssertNotNil(bridge.subagents["k1"]?.endedAt, "and its elapsed time stops climbing")
    }

    /// A run that never received `task_*` events is identified by its tool-use key instead.
    func testStopSettlesARunAddressedByItsKey() {
        let (bridge, support) = makeBridge()
        defer { bridge.shutdown(); try? FileManager.default.removeItem(at: support) }

        bridge.subagents = ["k2": running(key: "k2", taskId: nil)]
        bridge.stopTask("k2")

        XCTAssertEqual(bridge.subagents["k2"]?.status, .stopped)
    }

    /// A workflow run answers to any of the three ids its card might carry.
    func testStopSettlesAWorkflowByAnyOfItsIDs() {
        for id in ["run-task", "tool-use", "run-key"] {
            let (bridge, support) = makeBridge()
            defer { bridge.shutdown(); try? FileManager.default.removeItem(at: support) }

            var run = WorkflowRun(runKey: "run-key")
            run.toolUseId = "tool-use"
            run.runTaskId = "run-task"
            run.status = .running
            bridge.workflowRuns = ["run-key": run]

            bridge.stopTask(id)
            XCTAssertEqual(
                bridge.workflowRuns["run-key"]?.status, .stopped,
                "Stop must work whichever id the card had available")
        }
    }

    /// Workflow Stop is an aggregate operation: every live nested child (and a standalone mirror of
    /// that child) settles in the same snapshot, while another workflow in the conversation keeps
    /// running. Synthetic terminal states close the exact historical child lanes.
    func testStopWorkflowSettlesChildrenClosesTheirLanesAndPersistsCoherently() {
        let (bridge, support) = makeBridge()
        let conversationID = UUID()
        let stoppedTurnID = "turn-target"
        let startedAt = Date(timeIntervalSince1970: 1_000)

        var mirrored = running(key: "mirror-key", taskId: "provider-child")
        mirrored.startedAt = startedAt

        var firstChild = WorkflowAgent(
            index: 0,
            label: "finder",
            phaseIndex: 0,
            phaseTitle: "Find",
            state: .progress)
        firstChild.agentId = "provider-child"
        firstChild.startedAt = startedAt
        var secondChild = WorkflowAgent(
            index: 1,
            label: "reader",
            phaseIndex: 0,
            phaseTitle: "Find",
            state: .queued)
        secondChild.startedAt = startedAt
        var target = WorkflowRun(runKey: "run-target", status: .running)
        target.runTaskId = "run-target-task"
        target.agents = ["0:0": firstChild, "0:1": secondChild]

        var siblingChild = WorkflowAgent(
            index: 0,
            label: "sibling",
            phaseIndex: 0,
            phaseTitle: "Keep going",
            state: .progress)
        siblingChild.startedAt = startedAt
        var sibling = WorkflowRun(runKey: "run-sibling", status: .running)
        sibling.runTaskId = "run-sibling-task"
        sibling.agents = ["0:0": siblingChild]

        var mirroredLane = AgentActivityRecord.state(
            .model,
            turnID: stoppedTurnID,
            agentID: AgentActivityIdentity.workflow(
                runKey: "run-target",
                agentKey: "0:0"),
            detail: "Searching",
            at: startedAt)
        mirroredLane.providerAccess = .claudeSubscription
        mirroredLane.modelID = "claude-test"
        var secondLane = AgentActivityRecord.state(
            .waiting,
            turnID: stoppedTurnID,
            agentID: AgentActivityIdentity.workflow(
                runKey: "run-target",
                agentKey: "0:1"),
            detail: "Queued",
            at: startedAt)
        secondLane.providerAccess = .claudeSubscription
        secondLane.modelID = "claude-test"
        let siblingLane = AgentActivityRecord.state(
            .model,
            turnID: "turn-sibling",
            agentID: AgentActivityIdentity.workflow(
                runKey: "run-sibling",
                agentKey: "0:0"),
            at: startedAt)
        let activity = [mirroredLane, secondLane, siblingLane]
        let conversation = Conversation(
            id: conversationID,
            title: "Workflow",
            cwd: "",
            sdkSessionId: nil,
            messages: [TranscriptEntry(kind: .user, text: "run both")],
            updatedAt: startedAt,
            workflowRuns: [
                "run-target": target,
                "run-sibling": sibling,
            ],
            subagents: ["mirror-key": mirrored],
            agentActivity: activity)
        ConversationStore.shared.upsert(conversation)
        defer {
            bridge.currentID = nil
            bridge.shutdown()
            ConversationStore.shared.remove(conversationID, permanently: true)
            ConversationStore.shared.flushSaves()
            try? FileManager.default.removeItem(at: support)
        }

        bridge.currentID = conversationID
        bridge.entries = conversation.messages
        bridge.workflowRuns = conversation.workflowRuns
        bridge.subagents = conversation.subagents
        bridge.agentActivity = conversation.agentActivity
        bridge.activeAgents = 1

        bridge.stopTask("run-target-task")

        let stoppedRun = bridge.workflowRuns["run-target"]
        XCTAssertEqual(stoppedRun?.status, .stopped)
        XCTAssertEqual(stoppedRun?.agents["0:0"]?.state, .stopped)
        XCTAssertEqual(stoppedRun?.agents["0:1"]?.state, .stopped)
        XCTAssertNotNil(stoppedRun?.endedAt)
        XCTAssertEqual(stoppedRun?.agents["0:0"]?.endedAt, stoppedRun?.endedAt)
        XCTAssertEqual(stoppedRun?.agents["0:1"]?.endedAt, stoppedRun?.endedAt)
        XCTAssertEqual(bridge.subagents["mirror-key"]?.status, .stopped)
        XCTAssertEqual(bridge.subagents["mirror-key"]?.endedAt, stoppedRun?.endedAt)
        XCTAssertEqual(bridge.activeAgents, 0)

        XCTAssertEqual(bridge.workflowRuns["run-sibling"]?.status, .running)
        XCTAssertEqual(bridge.workflowRuns["run-sibling"]?.agents["0:0"]?.state, .progress)
        XCTAssertNil(bridge.workflowRuns["run-sibling"]?.endedAt)

        let stoppedRecords = bridge.agentActivity.filter {
            $0.kind == .state
                && $0.phase == .stopped
                && $0.at == stoppedRun?.endedAt
        }
        XCTAssertEqual(Set(stoppedRecords.map(\.agentID)), [
            AgentActivityIdentity.subagent("provider-child"),
            AgentActivityIdentity.workflow(runKey: "run-target", agentKey: "0:1"),
        ])
        XCTAssertTrue(stoppedRecords.allSatisfy {
            $0.turnID == stoppedTurnID
                && $0.providerAccess == .claudeSubscription
                && $0.modelID == "claude-test"
        })
        XCTAssertFalse(bridge.agentActivity.contains {
            $0.agentID == AgentActivityIdentity.workflow(
                runKey: "run-sibling",
                agentKey: "0:0")
                && $0.phase == .stopped
        })

        let persisted = ConversationStore.shared.conversation(conversationID)
        XCTAssertEqual(persisted?.workflowRuns, bridge.workflowRuns)
        XCTAssertEqual(persisted?.subagents, bridge.subagents)
        XCTAssertEqual(persisted?.agentActivity, bridge.agentActivity)

        let persistedCount = persisted?.agentActivity.count
        let persistedEnd = persisted?.workflowRuns["run-target"]?.endedAt
        bridge.stopTask("run-target-task")
        XCTAssertEqual(bridge.agentActivity.count, persistedCount)
        XCTAssertEqual(bridge.workflowRuns["run-target"]?.endedAt, persistedEnd)
        XCTAssertEqual(
            ConversationStore.shared.conversation(conversationID)?.agentActivity.count,
            persistedCount,
            "a repeated card Stop is a no-op rather than another durable terminal event")
    }

    /// Stopping one run must not touch its siblings, and must not resurrect a finished one.
    func testStopIsNarrowAndIdempotent() {
        let (bridge, support) = makeBridge()
        defer { bridge.shutdown(); try? FileManager.default.removeItem(at: support) }

        var done = running(key: "k-done", taskId: "task-done")
        done.status = .completed
        done.endedAt = Date(timeIntervalSince1970: 1_000)
        bridge.subagents = [
            "k-live": running(key: "k-live", taskId: "task-live"),
            "k-other": running(key: "k-other", taskId: "task-other"),
            "k-done": done,
        ]

        bridge.stopTask("task-live")
        XCTAssertEqual(bridge.subagents["k-live"]?.status, .stopped)
        XCTAssertEqual(bridge.subagents["k-other"]?.status, .running, "siblings keep running")

        bridge.stopTask("task-done")
        XCTAssertEqual(bridge.subagents["k-done"]?.status, .completed, "a finished run stays finished")
        XCTAssertEqual(bridge.subagents["k-done"]?.endedAt, Date(timeIntervalSince1970: 1_000))
    }

    // MARK: - The button is offered whenever the run is running

    /// The card offers Stop for any running subagent, with or without a `taskId`.
    func testCardOffersStopForARunningSubagentWithoutATaskID() throws {
        _ = NSApplication.shared
        for taskID in [nil, "task-1"] {
            let cell = AppKitAgentTableCellView(
                frame: NSRect(x: 0, y: 0, width: 320, height: 64))
            var stopped: [String] = []
            var rowActivations = 0
            cell.pressHandler = { rowActivations += 1 }
            cell.configure(
                subagent: running(key: "k1", taskId: taskID),
                ordinal: 1,
                depth: 0,
                compact: false,
                activityIndex: AgentActivityLedgerIndex([]),
                now: Date(),
                onStop: { stopped.append($0) })

            let button = try XCTUnwrap(cell.stopButtonForTesting)
            XCTAssertEqual(
                button.isHidden, false,
                "a running agent always needs a way to be stopped (taskId: \(taskID ?? "nil"))")
            assertRoadSignStyle(button)
            XCTAssertEqual(button.toolTip, "Stop this agent")
            XCTAssertEqual(button.accessibilityLabel(), "Stop this agent")

            let window = NSWindow(
                contentRect: cell.frame,
                styleMask: [.borderless],
                backing: .buffered,
                defer: false)
            window.contentView = cell
            window.alphaValue = 0
            window.orderFrontRegardless()
            cell.layoutSubtreeIfNeeded()
            let stopPoint = NSPoint(x: button.frame.midX, y: button.frame.midY)
            let hitPoint = cell.convert(stopPoint, to: cell.superview)
            let hit = cell.hitTest(hitPoint)
            let directHit = button.hitTest(stopPoint)
            let hitDescription = hit.map { "\(type(of: $0)) frame=\($0.frame)" } ?? "nil"
            XCTAssertTrue(
                directHit === button,
                "Direct button hit failed: hidden=\(button.isHidden), enabled=\(button.isEnabled), "
                    + "alpha=\(button.alphaValue), bounds=\(button.bounds), "
                    + "window=\(String(describing: button.window)).")
            XCTAssertTrue(
                hit === button,
                "The nested Stop button, not \(hitDescription), "
                    + "must own clicks at \(hitPoint) over its frame \(button.frame).")
            button.performClick(nil)
            XCTAssertEqual(
                stopped, [taskID ?? "k1"],
                "and Stop carries the task id when there is one, else the run's own key")
            XCTAssertEqual(
                rowActivations, 0,
                "Stopping an agent must not also activate/open its card.")
            window.orderOut(nil)
            window.contentView = nil
        }
    }

    /// A finished agent offers no Stop.
    func testCardHidesStopForATerminalSubagent() {
        var run = running(key: "k1", taskId: "task-1")
        run.status = .completed
        let cell = AppKitAgentTableCellView(frame: NSRect(x: 0, y: 0, width: 320, height: 64))
        cell.configure(
            subagent: run, ordinal: 1, depth: 0, compact: false,
            activityIndex: AgentActivityLedgerIndex([]), now: Date(), onStop: { _ in })
        XCTAssertEqual(cell.stopButtonForTesting?.isHidden, true)
    }

    func testWorkflowCardStopUsesRoadSignAndPreservesItsFallbackID() throws {
        var workflow = WorkflowRun(runKey: "workflow-key")
        workflow.toolUseId = "workflow-tool"
        workflow.status = .running
        var stopped: [String] = []
        let cell = AppKitAgentTableCellView(
            frame: NSRect(x: 0, y: 0, width: 320, height: 64))
        cell.configure(
            workflow: workflow,
            expanded: false,
            compact: false,
            now: Date(),
            onStop: { stopped.append($0) })

        let button = try XCTUnwrap(cell.stopButtonForTesting)
        assertRoadSignStyle(button)
        XCTAssertFalse(button.isHidden)
        XCTAssertEqual(button.toolTip, "Stop this workflow")
        XCTAssertEqual(button.accessibilityLabel(), "Stop this workflow")
        button.performClick(nil)

        XCTAssertEqual(stopped, ["workflow-tool"])
    }

    func testDetailStopUsesRoadSignAndRefreshesCopyWhenTheSelectionChanges() throws {
        let now = Date(timeIntervalSince1970: 12_000)
        let detail = AppKitAgentDetailView(
            frame: NSRect(x: 0, y: 0, width: 420, height: 500))
        var stopped: [String] = []
        detail.onStopTask = { stopped.append($0) }

        let subagent = running(key: "child-key", taskId: "child-task")
        detail.configure(subagent: subagent, ordinal: 1, activity: [], now: now)
        let button = detail.stopButtonForTesting
        assertRoadSignStyle(button)
        XCTAssertFalse(button.isHidden)
        XCTAssertEqual(button.toolTip, "Stop this agent")
        XCTAssertEqual(button.accessibilityLabel(), "Stop this agent")
        button.performClick(nil)
        XCTAssertEqual(stopped, ["child-task"])

        var workflow = WorkflowRun(runKey: "workflow-key")
        workflow.runTaskId = "workflow-task"
        workflow.status = .running
        detail.configure(workflow: workflow, now: now)
        XCTAssertFalse(button.isHidden)
        XCTAssertEqual(button.toolTip, "Stop this workflow")
        XCTAssertEqual(button.accessibilityLabel(), "Stop this workflow")
        button.performClick(nil)
        XCTAssertEqual(stopped, ["child-task", "workflow-task"])

        let workflowAgent = WorkflowAgent(
            index: 1,
            label: "reviewer",
            phaseIndex: 0,
            phaseTitle: "Review",
            state: .progress)
        workflow.agents = [workflowAgent.id: workflowAgent]
        detail.configure(
            workflowAgent: workflowAgent,
            in: workflow,
            activity: [],
            now: now)
        XCTAssertFalse(button.isHidden)
        XCTAssertEqual(button.toolTip, "Stop this workflow")
        XCTAssertEqual(button.accessibilityLabel(), "Stop this workflow")
        button.performClick(nil)
        XCTAssertEqual(stopped, ["child-task", "workflow-task", "workflow-task"])

        // The detail view is one recycled surface. Returning to an agent must not retain the
        // workflow copy installed by the previous selection.
        detail.configure(subagent: subagent, ordinal: 1, activity: [], now: now)
        XCTAssertEqual(button.toolTip, "Stop this agent")
        XCTAssertEqual(button.accessibilityLabel(), "Stop this agent")
    }

    func testInlineWorkflowStopControlRetainsItsTargetID() throws {
        _ = NSApplication.shared
        var stopped: [String] = []
        let host = NSHostingView(rootView: WorkflowStopControl(
            taskID: "workflow-task",
            onStop: { stopped.append($0) }))
        let frame = NSRect(x: 0, y: 0, width: 100, height: 32)
        host.frame = frame
        let window = NSWindow(
            contentRect: frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false)
        window.contentView = host
        window.alphaValue = 0
        window.orderFrontRegardless()
        defer {
            window.orderOut(nil)
            window.contentView = nil
        }

        host.layoutSubtreeIfNeeded()
        let button = try XCTUnwrap(descendants(of: host).compactMap { $0 as? NSButton }.first)
        button.performClick(nil)

        XCTAssertEqual(stopped, ["workflow-task"])
    }
}
