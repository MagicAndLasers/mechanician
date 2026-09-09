import XCTest
@testable import Mechanician

@MainActor
final class RootAgentStopTests: XCTestCase {
    private func runningDelegateState() -> (
        workflowRuns: [String: WorkflowRun],
        subagents: [String: SubagentRun]
    ) {
        var run = WorkflowRun(runKey: "workflow", status: .running)
        run.runTaskId = "workflow-task"
        run.agents = [
            "0:0": WorkflowAgent(
                index: 0,
                label: "researcher",
                phaseIndex: 0,
                phaseTitle: "Research",
                state: .progress),
        ]
        var child = SubagentRun(
            key: "child",
            subagentType: "Explore",
            task: "Keep researching")
        child.taskId = "child-task"
        return (["workflow": run], ["child": child])
    }

    private func activity(
        turnID: String,
        selection: ModelSelection
    ) -> [AgentActivityRecord] {
        [
            AgentActivityRecord.state(
                .model,
                turnID: turnID,
                detail: "Turn started",
                at: Date(timeIntervalSince1970: 1_000))
                .attributed(to: selection),
            AgentActivityRecord.state(
                .tool,
                turnID: turnID,
                agentID: AgentActivityIdentity.subagent("child-task"),
                detail: "Still working",
                at: Date(timeIntervalSince1970: 1_001))
                .attributed(to: selection),
        ]
    }

    func testDuplicateViewerForwardsActiveRootStopAndLeavesDelegatesRunning() {
        let support = FileManager.default.temporaryDirectory
            .appendingPathComponent("mechanician-root-stop-\(UUID().uuidString)")
        let owner = AgentBridge(
            settingsBaseOverride: support.appendingPathComponent("owner"),
            environmentOverride: [:])
        let viewer = AgentBridge(
            settingsBaseOverride: support.appendingPathComponent("viewer"),
            environmentOverride: [:])
        let conversationID = UUID()
        let turnID = "active-root"
        let selection = ModelSelection(
            access: .codexSubscription,
            modelID: "gpt-root")
        let delegates = runningDelegateState()
        let initialActivity = activity(turnID: turnID, selection: selection)
        let conversation = Conversation(
            id: conversationID,
            title: "Root stop",
            cwd: "",
            sdkSessionId: nil,
            modelSelection: selection,
            messages: [TranscriptEntry(kind: .user, text: "Do the work")],
            updatedAt: Date(),
            workflowRuns: delegates.workflowRuns,
            subagents: delegates.subagents,
            agentActivity: initialActivity)
        ConversationStore.shared.upsert(conversation)
        for bridge in [owner, viewer] {
            bridge.currentID = conversationID
            bridge.entries = conversation.messages
            bridge.workflowRuns = conversation.workflowRuns
            bridge.subagents = conversation.subagents
            bridge.agentActivity = conversation.agentActivity
            bridge.activeAgents = 2
            AgentBridge.live.add(bridge)
        }
        owner.stageRootWorkForTesting(
            conversationID: conversationID,
            turnID: turnID,
            selection: selection)
        defer {
            AgentBridge.live.remove(owner)
            AgentBridge.live.remove(viewer)
            owner.currentID = nil
            viewer.currentID = nil
            owner.shutdown()
            viewer.shutdown()
            ConversationStore.shared.remove(conversationID, permanently: true)
            ConversationStore.shared.flushSaves()
            try? FileManager.default.removeItem(at: support)
        }

        XCTAssertTrue(owner.currentConversationHasReservedTurn)
        XCTAssertFalse(viewer.currentConversationHasReservedTurn)

        viewer.stopRootWork()

        let rootStops = owner.agentActivity.filter {
            $0.turnID == turnID
                && $0.agentID == AgentActivityIdentity.root
                && $0.phase == .stopped
        }
        XCTAssertEqual(rootStops.count, 1)
        XCTAssertEqual(rootStops.first?.providerAccess, selection.access)
        XCTAssertEqual(rootStops.first?.modelID, selection.modelID)
        XCTAssertEqual(viewer.agentActivity, owner.agentActivity)
        XCTAssertEqual(owner.workflowRuns["workflow"]?.status, .running)
        XCTAssertEqual(
            owner.workflowRuns["workflow"]?.agents["0:0"]?.state,
            .progress)
        XCTAssertEqual(owner.subagents["child"]?.status, .running)
        XCTAssertEqual(viewer.subagents["child"]?.status, .running)
        XCTAssertEqual(owner.activeAgents, 2)
        XCTAssertEqual(viewer.activeAgents, 2)
        XCTAssertTrue(
            owner.currentConversationHasReservedTurn,
            "the provider owns the route until its interrupted terminal event arrives")

        let persisted = ConversationStore.shared.conversation(conversationID)
        XCTAssertEqual(persisted?.workflowRuns["workflow"]?.status, .running)
        XCTAssertEqual(persisted?.subagents["child"]?.status, .running)
        XCTAssertEqual(persisted?.agentActivity.filter {
            $0.turnID == turnID
                && $0.agentID == AgentActivityIdentity.root
                && $0.phase == .stopped
        }.count, 1)

        viewer.stopRootWork()
        XCTAssertEqual(owner.agentActivity.filter {
            $0.turnID == turnID
                && $0.agentID == AgentActivityIdentity.root
                && $0.phase == .stopped
        }.count, 1, "root Stop is idempotent while the terminal event is pending")
    }

    func testViewerStopsBackgroundRootOnOwnerWithoutChangingOwnersVisibleConversation() {
        let support = FileManager.default.temporaryDirectory
            .appendingPathComponent("mechanician-background-root-stop-\(UUID().uuidString)")
        let owner = AgentBridge(
            settingsBaseOverride: support.appendingPathComponent("owner"),
            environmentOverride: [:])
        let viewer = AgentBridge(
            settingsBaseOverride: support.appendingPathComponent("viewer"),
            environmentOverride: [:])
        let targetID = UUID()
        let visibleID = UUID()
        let turnID = "background-root"
        let selection = ModelSelection(
            access: .openAIAPI,
            modelID: "gpt-background")
        let delegates = runningDelegateState()
        let target = Conversation(
            id: targetID,
            title: "Background target",
            cwd: "",
            sdkSessionId: nil,
            modelSelection: selection,
            messages: [TranscriptEntry(kind: .user, text: "Background work")],
            updatedAt: Date(),
            workflowRuns: delegates.workflowRuns,
            subagents: delegates.subagents,
            agentActivity: activity(turnID: turnID, selection: selection))
        let visibleActivity = [
            AgentActivityRecord.state(
                .completed,
                turnID: "visible-turn",
                detail: "Visible turn completed")
        ]
        let visible = Conversation(
            id: visibleID,
            title: "Owner visible",
            cwd: "",
            sdkSessionId: nil,
            messages: [TranscriptEntry(kind: .user, text: "Visible work")],
            updatedAt: Date(),
            agentActivity: visibleActivity)
        ConversationStore.shared.upsert(target)
        ConversationStore.shared.upsert(visible)
        owner.currentID = visibleID
        owner.entries = visible.messages
        owner.agentActivity = visible.agentActivity
        viewer.currentID = targetID
        viewer.entries = target.messages
        viewer.workflowRuns = target.workflowRuns
        viewer.subagents = target.subagents
        viewer.agentActivity = target.agentActivity
        viewer.activeAgents = 2
        AgentBridge.live.add(owner)
        AgentBridge.live.add(viewer)
        owner.stageRootWorkForTesting(
            conversationID: targetID,
            turnID: turnID,
            selection: selection)
        defer {
            AgentBridge.live.remove(owner)
            AgentBridge.live.remove(viewer)
            owner.currentID = nil
            viewer.currentID = nil
            owner.shutdown()
            viewer.shutdown()
            ConversationStore.shared.remove(targetID, permanently: true)
            ConversationStore.shared.remove(visibleID, permanently: true)
            ConversationStore.shared.flushSaves()
            try? FileManager.default.removeItem(at: support)
        }

        viewer.stopRootWork()

        XCTAssertEqual(owner.currentID, visibleID)
        XCTAssertEqual(owner.agentActivity, visibleActivity)
        XCTAssertEqual(viewer.workflowRuns["workflow"]?.status, .running)
        XCTAssertEqual(viewer.subagents["child"]?.status, .running)
        XCTAssertEqual(viewer.activeAgents, 2)
        XCTAssertTrue(viewer.agentActivity.contains {
            $0.turnID == turnID
                && $0.agentID == AgentActivityIdentity.root
                && $0.phase == .stopped
        })
        let persisted = ConversationStore.shared.conversation(targetID)
        XCTAssertEqual(persisted?.workflowRuns["workflow"]?.status, .running)
        XCTAssertEqual(persisted?.subagents["child"]?.status, .running)
        XCTAssertTrue(persisted?.agentActivity.contains {
            $0.turnID == turnID
                && $0.agentID == AgentActivityIdentity.root
                && $0.phase == .stopped
        } ?? false)
    }

    func testDuplicateViewerCancelsProvisionalRootWithoutRequeuingPrompt() {
        let support = FileManager.default.temporaryDirectory
            .appendingPathComponent("mechanician-pending-root-stop-\(UUID().uuidString)")
        let owner = AgentBridge(
            settingsBaseOverride: support.appendingPathComponent("owner"),
            environmentOverride: [:])
        let viewer = AgentBridge(
            settingsBaseOverride: support.appendingPathComponent("viewer"),
            environmentOverride: [:])
        let conversationID = UUID()
        let turnID = "pending-root"
        let prompt = "Cancel this provisional prompt"
        let selection = ModelSelection(
            access: .claudeSubscription,
            modelID: "claude-root")
        let delegates = runningDelegateState()
        let conversation = Conversation(
            id: conversationID,
            title: "Pending root stop",
            cwd: "",
            sdkSessionId: nil,
            modelSelection: selection,
            messages: [TranscriptEntry(kind: .user, text: "Earlier work")],
            updatedAt: Date(),
            workflowRuns: delegates.workflowRuns,
            subagents: delegates.subagents,
            queuedPrompts: ["Keep this queued prompt"])
        ConversationStore.shared.upsert(conversation)
        for bridge in [owner, viewer] {
            bridge.currentID = conversationID
            bridge.entries = conversation.messages
            bridge.workflowRuns = conversation.workflowRuns
            bridge.subagents = conversation.subagents
            bridge.queuedPrompts = conversation.queuedPrompts
            AgentBridge.live.add(bridge)
        }
        owner.stageRootWorkForTesting(
            conversationID: conversationID,
            turnID: turnID,
            selection: selection,
            pendingPrompt: prompt)
        owner.activeAgents = 2
        viewer.activeAgents = 2
        defer {
            AgentBridge.live.remove(owner)
            AgentBridge.live.remove(viewer)
            owner.currentID = nil
            viewer.currentID = nil
            owner.shutdown()
            viewer.shutdown()
            ConversationStore.shared.remove(conversationID, permanently: true)
            ConversationStore.shared.flushSaves()
            try? FileManager.default.removeItem(at: support)
        }

        XCTAssertTrue(owner.currentConversationHasReservedTurn)
        XCTAssertEqual(owner.provisionalUserEntryForCurrentConversation?.text, prompt)

        viewer.stopRootWork()

        XCTAssertFalse(owner.currentConversationHasReservedTurn)
        XCTAssertFalse(owner.isWorking)
        XCTAssertFalse(owner.isStreaming)
        XCTAssertNil(owner.provisionalUserEntryForCurrentConversation)
        XCTAssertEqual(owner.queuedPrompts, ["Keep this queued prompt"])
        XCTAssertEqual(viewer.queuedPrompts, ["Keep this queued prompt"])
        XCTAssertFalse(owner.entries.contains { $0.text == prompt })
        XCTAssertEqual(owner.workflowRuns["workflow"]?.status, .running)
        XCTAssertEqual(owner.subagents["child"]?.status, .running)
        XCTAssertEqual(owner.activeAgents, 2)
        XCTAssertEqual(viewer.activeAgents, 2)

        let persisted = ConversationStore.shared.conversation(conversationID)
        XCTAssertEqual(persisted?.queuedPrompts, ["Keep this queued prompt"])
        XCTAssertFalse(persisted?.messages.contains { $0.text == prompt } ?? true)
        XCTAssertEqual(persisted?.workflowRuns["workflow"]?.status, .running)
        XCTAssertEqual(persisted?.subagents["child"]?.status, .running)
        XCTAssertFalse(persisted?.agentActivity.contains {
            $0.turnID == turnID && $0.phase == .stopped
        } ?? true, "an unacknowledged root has no activity lane to close")
    }

    func testStreamingDeltaKeepsRootCardStopVisible() throws {
        _ = NSApplication.shared
        let support = FileManager.default.temporaryDirectory
            .appendingPathComponent("mechanician-streaming-root-card-\(UUID().uuidString)")
        let bridge = AgentBridge(
            settingsBaseOverride: support,
            environmentOverride: [:])
        let conversationID = UUID()
        bridge.currentID = conversationID
        AgentBridge.live.add(bridge)
        bridge.stageRootWorkForTesting(
            conversationID: conversationID,
            turnID: "streaming-root",
            selection: ModelSelection(
                access: .codexSubscription,
                modelID: "gpt-root"))
        defer {
            AgentBridge.live.remove(bridge)
            bridge.currentID = nil
            bridge.shutdown()
            try? FileManager.default.removeItem(at: support)
        }

        // This is the bridge projection immediately after a provider `delta`: text is still
        // streaming, but `isWorking` is intentionally false because the thinking indicator stops.
        bridge.isWorking = false
        XCTAssertTrue(bridge.isStreaming)
        XCTAssertFalse(bridge.isWorking)
        XCTAssertTrue(bridge.currentConversationHasRootWork)

        let panel = AppKitAgentsPanelView(bridge: bridge)
        panel.frame = NSRect(x: 0, y: 0, width: 480, height: 640)
        panel.layoutSubtreeIfNeeded()
        defer { panel.shutdown() }

        let stopButton = try XCTUnwrap(panel.rootStopButtonForTesting)
        XCTAssertFalse(stopButton.isHidden)
        XCTAssertEqual(stopButton.toolTip, "Stop root agent")
        XCTAssertEqual(stopButton.accessibilityLabel(), "Stop root agent")
    }

    func testUnacknowledgedRootStopEscalatesExactOwnedGenerationOnce() async {
        let support = FileManager.default.temporaryDirectory
            .appendingPathComponent("mechanician-stop-escalation-\(UUID().uuidString)")
        let bridge = AgentBridge(
            settingsBaseOverride: support,
            environmentOverride: [:])
        let conversationID = UUID()
        let turnID = "wedged-root"
        let selection = ModelSelection(
            access: .claudeVertex,
            modelID: "claude-opus-4-8")
        let generation = UUID()
        let conversation = Conversation(
            id: conversationID,
            title: "Wedged root",
            cwd: "",
            sdkSessionId: "stale-session",
            modelSelection: selection,
            messages: [TranscriptEntry(kind: .user, text: "Continue")],
            updatedAt: Date(),
            queuedPrompts: ["Continue safely"])
        ConversationStore.shared.upsert(conversation)
        bridge.currentID = conversationID
        bridge.entries = conversation.messages
        bridge.queuedPrompts = conversation.queuedPrompts
        AgentBridge.live.add(bridge)
        bridge.stageRootWorkForTesting(
            conversationID: conversationID,
            turnID: turnID,
            selection: selection)
        let launched = expectation(description: "fixture runtime launched")
        let replaced = expectation(description: "retirement and durable fence completed")
        replaced.assertForOverFulfill = true
        let runtime = AgentdRuntime(
            access: selection.access,
            onEvent: { _, _ in },
            onLaunchFailure: { _, detail in XCTFail("fixture launch failed: \(detail)") },
            onUnexpectedExit: { _, _ in XCTFail("forced retirement is intentional") },
            processStarter: { process in
                process.executableURL = URL(fileURLWithPath: "/bin/sh")
                process.arguments = ["-c", "trap 'exit 0' TERM; while :; do sleep 1; done"]
                do {
                    try process.run()
                    launched.fulfill()
                    return nil
                } catch {
                    return error.localizedDescription
                }
            })
        bridge.installStopRecoveryRuntimeForTesting(
            access: selection.access,
            generation: generation,
            runtime: runtime
        ) { observedAccess in
            XCTAssertEqual(observedAccess, selection.access)
            replaced.fulfill()
        }
        defer {
            AgentBridge.live.remove(bridge)
            bridge.currentID = nil
            bridge.shutdown()
            ConversationStore.shared.remove(conversationID, permanently: true)
            ConversationStore.shared.flushSaves()
            try? FileManager.default.removeItem(at: support)
        }

        await fulfillment(of: [launched], timeout: 2)

        bridge.stopRootWork()
        bridge.stopRootWork()

        await fulfillment(of: [replaced], timeout: 3)
        XCTAssertFalse(bridge.currentConversationHasReservedTurn)
        let recovered = ConversationStore.shared.conversation(conversationID)
        XCTAssertNil(recovered?.sdkSessionId)
        XCTAssertTrue(recovered?.messages.contains {
            $0.runtimeRecoveryNotice == true && $0.text.contains("fresh provider session")
        } ?? false)
        XCTAssertEqual(recovered?.queuedPrompts, ["Continue safely"])
        XCTAssertTrue(ConversationStore.shared.isQueuePaused(conversationID))
        let refolded = expectation(description: "visible transcript refolded")
        bridge.persistCurrentForStopRecoveryTesting { published in
            XCTAssertTrue(published)
            refolded.fulfill()
        }
        await fulfillment(of: [refolded], timeout: 2)
        XCTAssertTrue(ConversationStore.shared.conversation(conversationID)?.messages.contains {
            $0.runtimeRecoveryNotice == true
        } ?? false, "ordinary foreground persistence must retain the recovery fact")
        if let persisted = ConversationStore.shared.conversation(conversationID),
           let bytes = try? ConversationStore.makeEncoder().encode(persisted),
           let relaunched = try? ConversationStore.makeDecoder().decode(
               Conversation.self,
               from: bytes) {
            XCTAssertTrue(relaunched.messages.contains { $0.runtimeRecoveryNotice == true })
        } else {
            XCTFail("recovery fact must round-trip through relaunch decoding")
        }
    }

    func testTerminalAcknowledgementCancelsStopEscalation() async {
        let support = FileManager.default.temporaryDirectory
            .appendingPathComponent("mechanician-stop-ack-\(UUID().uuidString)")
        let bridge = AgentBridge(
            settingsBaseOverride: support,
            environmentOverride: [:])
        let conversationID = UUID()
        let turnID = "acknowledged-root"
        let selection = ModelSelection(
            access: .claudeVertex,
            modelID: "claude-opus-4-8")
        let conversation = Conversation(
            id: conversationID,
            title: "Acknowledged stop",
            cwd: "",
            sdkSessionId: "session",
            modelSelection: selection,
            messages: [TranscriptEntry(kind: .user, text: "Stop")],
            updatedAt: Date())
        ConversationStore.shared.upsert(conversation)
        bridge.currentID = conversationID
        bridge.entries = conversation.messages
        AgentBridge.live.add(bridge)
        bridge.stageRootWorkForTesting(
            conversationID: conversationID,
            turnID: turnID,
            selection: selection)
        let launched = expectation(description: "fixture runtime launched")
        let unexpectedReplacement = expectation(description: "stop must stay acknowledged")
        unexpectedReplacement.isInverted = true
        let runtime = AgentdRuntime(
            access: selection.access,
            onEvent: { _, _ in },
            onLaunchFailure: { _, detail in XCTFail("fixture launch failed: \(detail)") },
            onUnexpectedExit: { _, _ in },
            processStarter: { process in
                process.executableURL = URL(fileURLWithPath: "/bin/sh")
                process.arguments = ["-c", "trap 'exit 0' TERM; while :; do sleep 1; done"]
                do {
                    try process.run()
                    launched.fulfill()
                    return nil
                } catch {
                    return error.localizedDescription
                }
            })
        bridge.installStopRecoveryRuntimeForTesting(
            access: selection.access,
            generation: UUID(),
            runtime: runtime
        ) { _ in
            unexpectedReplacement.fulfill()
        }
        defer {
            AgentBridge.live.remove(bridge)
            bridge.currentID = nil
            bridge.shutdown()
            ConversationStore.shared.remove(conversationID, permanently: true)
            ConversationStore.shared.flushSaves()
            try? FileManager.default.removeItem(at: support)
        }

        await fulfillment(of: [launched], timeout: 2)
        bridge.stopRootWork()
        bridge.acknowledgeRootStopForTesting(turnID: turnID)

        await fulfillment(of: [unexpectedReplacement], timeout: 0.2)
        XCTAssertFalse(bridge.currentConversationHasRootWork)
    }

    func testStopRetirementFencesSameLaneCollateralAndLeavesOtherLaneRunning() async {
        let support = FileManager.default.temporaryDirectory
            .appendingPathComponent("mechanician-stop-lane-transaction-\(UUID().uuidString)")
        let bridge = AgentBridge(settingsBaseOverride: support, environmentOverride: [:])
        let targetID = UUID()
        let collateralID = UUID()
        let otherLaneID = UUID()
        let targetTurnID = "target-turn"
        let collateralTurnID = "collateral-turn"
        let otherTurnID = "other-lane-turn"
        let stoppedSelection = ModelSelection(
            access: .claudeVertex,
            modelID: "claude-opus-4-8")
        let otherSelection = ModelSelection(
            access: .openAIAPI,
            modelID: "gpt-other")
        var collateralWorkflow = WorkflowRun(runKey: "collateral-work", status: .running)
        collateralWorkflow.runTaskId = "collateral-task"
        collateralWorkflow.agents = [
            "0:0": WorkflowAgent(
                index: 0,
                label: "collateral-agent",
                phaseIndex: 0,
                phaseTitle: "Work",
                state: .progress),
        ]
        let target = Conversation(
            id: targetID,
            title: "Stop target",
            cwd: "",
            sdkSessionId: "target-stale-session",
            modelSelection: stoppedSelection,
            messages: [TranscriptEntry(kind: .user, text: "Stop this")],
            updatedAt: Date(),
            queuedPrompts: ["target queued"])
        let collateral = Conversation(
            id: collateralID,
            title: "Same lane sibling",
            cwd: "",
            sdkSessionId: "collateral-stale-session",
            modelSelection: stoppedSelection,
            messages: [TranscriptEntry(kind: .user, text: "Keep working")],
            updatedAt: Date(),
            workflowRuns: ["collateral-work": collateralWorkflow],
            agentActivity: [
                AgentActivityRecord.state(
                    .tool,
                    turnID: collateralTurnID,
                    agentID: AgentActivityIdentity.workflow(
                        runKey: "collateral-work",
                        agentKey: "0:0"),
                    detail: "Still working")
                    .attributed(to: stoppedSelection),
            ],
            queuedPrompts: ["collateral queued"])
        let otherLane = Conversation(
            id: otherLaneID,
            title: "Other lane",
            cwd: "",
            sdkSessionId: "other-session",
            modelSelection: otherSelection,
            messages: [TranscriptEntry(kind: .user, text: "Stay running")],
            updatedAt: Date(),
            queuedPrompts: ["other queued"])
        for conversation in [target, collateral, otherLane] {
            ConversationStore.shared.upsert(conversation)
        }
        bridge.currentID = targetID
        bridge.entries = target.messages
        bridge.queuedPrompts = target.queuedPrompts
        AgentBridge.live.add(bridge)
        bridge.stageRootWorkForTesting(
            conversationID: targetID,
            turnID: targetTurnID,
            selection: stoppedSelection)
        bridge.stageRootWorkForTesting(
            conversationID: collateralID,
            turnID: collateralTurnID,
            selection: stoppedSelection)
        bridge.stageRootWorkForTesting(
            conversationID: otherLaneID,
            turnID: otherTurnID,
            selection: otherSelection)
        let launched = expectation(description: "fixture lane launched")
        let replaced = expectation(description: "lane transaction completed")
        let runtime = AgentdRuntime(
            access: stoppedSelection.access,
            onEvent: { _, _ in },
            onLaunchFailure: { _, detail in XCTFail("fixture launch failed: \(detail)") },
            onUnexpectedExit: { _, _ in XCTFail("forced retirement is intentional") },
            processStarter: { process in
                process.executableURL = URL(fileURLWithPath: "/bin/sh")
                process.arguments = ["-c", "trap 'exit 0' TERM; while :; do sleep 1; done"]
                do {
                    try process.run()
                    launched.fulfill()
                    return nil
                } catch {
                    return error.localizedDescription
                }
            })
        bridge.installStopRecoveryRuntimeForTesting(
            access: stoppedSelection.access,
            generation: UUID(),
            runtime: runtime
        ) { access in
            XCTAssertEqual(access, stoppedSelection.access)
            replaced.fulfill()
        }
        defer {
            AgentBridge.live.remove(bridge)
            bridge.currentID = nil
            bridge.shutdown()
            for id in [targetID, collateralID, otherLaneID] {
                ConversationStore.shared.remove(id, permanently: true)
            }
            ConversationStore.shared.flushSaves()
            try? FileManager.default.removeItem(at: support)
        }

        await fulfillment(of: [launched], timeout: 2)
        bridge.stopRootWork()
        await fulfillment(of: [replaced], timeout: 3)

        guard let recoveredTarget = ConversationStore.shared.conversation(targetID),
              let recoveredCollateral = ConversationStore.shared.conversation(collateralID),
              let untouchedOther = ConversationStore.shared.conversation(otherLaneID)
        else { return XCTFail("all lane transaction records must remain resident") }
        XCTAssertNil(recoveredTarget.sdkSessionId)
        XCTAssertNil(recoveredCollateral.sdkSessionId)
        XCTAssertEqual(untouchedOther.sdkSessionId, "other-session")
        XCTAssertTrue(recoveredTarget.messages.contains {
            $0.runtimeRecoveryNotice == true && $0.text.hasPrefix("Stop did not finish")
        })
        XCTAssertTrue(recoveredCollateral.messages.contains {
            $0.runtimeRecoveryNotice == true && $0.text.contains("another conversation")
        })
        XCTAssertEqual(
            recoveredCollateral.workflowRuns["collateral-work"]?.status,
            .failed,
            "collateral provider loss must not be represented as a user Stop")
        XCTAssertTrue(ConversationStore.shared.isQueuePaused(targetID))
        XCTAssertTrue(ConversationStore.shared.isQueuePaused(collateralID))
        XCTAssertFalse(ConversationStore.shared.isQueuePaused(otherLaneID))
        XCTAssertTrue(bridge.hasReservedTurnForTesting(conversationID: otherLaneID))
    }

    func testSimultaneousStopTimeoutsCoalesceIntoOneGenerationRetirement() async {
        let support = FileManager.default.temporaryDirectory
            .appendingPathComponent("mechanician-stop-coalesce-\(UUID().uuidString)")
        let bridge = AgentBridge(settingsBaseOverride: support, environmentOverride: [:])
        let ids = [UUID(), UUID()]
        let selection = ModelSelection(
            access: .claudeVertex,
            modelID: "claude-opus-4-8")
        for (index, id) in ids.enumerated() {
            ConversationStore.shared.upsert(Conversation(
                id: id,
                title: "Stop \(index)",
                cwd: "",
                sdkSessionId: "stale-\(index)",
                modelSelection: selection,
                messages: [TranscriptEntry(kind: .user, text: "Stop \(index)")],
                updatedAt: Date()))
            bridge.stageRootWorkForTesting(
                conversationID: id,
                turnID: "turn-\(index)",
                selection: selection)
        }
        bridge.currentID = ids[0]
        bridge.entries = ConversationStore.shared.conversation(ids[0])?.messages ?? []
        AgentBridge.live.add(bridge)
        let launched = expectation(description: "fixture lane launched")
        let replaced = expectation(description: "one replacement boundary")
        replaced.assertForOverFulfill = true
        let runtime = AgentdRuntime(
            access: selection.access,
            onEvent: { _, _ in },
            onLaunchFailure: { _, detail in XCTFail("fixture launch failed: \(detail)") },
            onUnexpectedExit: { _, _ in XCTFail("forced retirement is intentional") },
            processStarter: { process in
                process.executableURL = URL(fileURLWithPath: "/bin/sh")
                process.arguments = ["-c", "trap 'exit 0' TERM; while :; do sleep 1; done"]
                do {
                    try process.run()
                    launched.fulfill()
                    return nil
                } catch {
                    return error.localizedDescription
                }
            })
        bridge.installStopRecoveryRuntimeForTesting(
            access: selection.access,
            generation: UUID(),
            runtime: runtime
        ) { _ in replaced.fulfill() }
        defer {
            AgentBridge.live.remove(bridge)
            bridge.currentID = nil
            bridge.shutdown()
            for id in ids { ConversationStore.shared.remove(id, permanently: true) }
            ConversationStore.shared.flushSaves()
            try? FileManager.default.removeItem(at: support)
        }

        await fulfillment(of: [launched], timeout: 2)
        for id in ids { bridge.stopRootWorkForTesting(conversationID: id) }
        await fulfillment(of: [replaced], timeout: 3)
        for id in ids {
            let recovered = ConversationStore.shared.conversation(id)
            XCTAssertNil(recovered?.sdkSessionId)
            XCTAssertTrue(recovered?.messages.contains {
                $0.runtimeRecoveryNotice == true && $0.text.hasPrefix("Stop did not finish")
            } ?? false)
        }
    }

    func testFailedRecoverySaveKeepsLaneUnavailableUntilDurableRetry() async {
        let support = FileManager.default.temporaryDirectory
            .appendingPathComponent("mechanician-stop-save-failure-\(UUID().uuidString)")
        let bridge = AgentBridge(settingsBaseOverride: support, environmentOverride: [:])
        let conversationID = UUID()
        let selection = ModelSelection(
            access: .claudeVertex,
            modelID: "claude-opus-4-8")
        let conversation = Conversation(
            id: conversationID,
            title: "Recovery save failure",
            cwd: "",
            sdkSessionId: "must-not-resume",
            modelSelection: selection,
            messages: [TranscriptEntry(kind: .user, text: "Stop")],
            updatedAt: Date(),
            queuedPrompts: ["preserve me"])
        ConversationStore.shared.upsert(conversation)
        ConversationStore.shared.flushSaves()
        bridge.currentID = conversationID
        bridge.entries = conversation.messages
        bridge.queuedPrompts = conversation.queuedPrompts
        AgentBridge.live.add(bridge)
        bridge.stageRootWorkForTesting(
            conversationID: conversationID,
            turnID: "save-failure-turn",
            selection: selection)
        let launched = expectation(description: "fixture lane launched")
        var replacementCount = 0
        let runtime = AgentdRuntime(
            access: selection.access,
            onEvent: { _, _ in },
            onLaunchFailure: { _, detail in XCTFail("fixture launch failed: \(detail)") },
            onUnexpectedExit: { _, _ in XCTFail("forced retirement is intentional") },
            processStarter: { process in
                process.executableURL = URL(fileURLWithPath: "/bin/sh")
                process.arguments = ["-c", "trap 'exit 0' TERM; while :; do sleep 1; done"]
                do {
                    try process.run()
                    launched.fulfill()
                    return nil
                } catch {
                    return error.localizedDescription
                }
            })
        bridge.installStopRecoveryRuntimeForTesting(
            access: selection.access,
            generation: UUID(),
            runtime: runtime
        ) { _ in replacementCount += 1 }
        defer {
            ConversationStore.persistenceWriteTestHook = nil
            AgentBridge.live.remove(bridge)
            bridge.currentID = nil
            bridge.shutdown()
            ConversationStore.shared.remove(conversationID, permanently: true)
            ConversationStore.shared.flushSaves()
            try? FileManager.default.removeItem(at: support)
        }
        await fulfillment(of: [launched], timeout: 2)
        ConversationStore.persistenceWriteTestHook = {
            throw CocoaError(.fileWriteUnknown)
        }

        bridge.stopRootWork()
        // Poll rather than sleep a fixed second. The notice is appended asynchronously, so a fixed
        // wait asserts on whatever the machine happened to finish in that time: this failed
        // intermittently once the suite grew, having passed for months at the same one second. The
        // durability wait below already uses this shape.
        let noticeDeadline = Date().addingTimeInterval(5)
        let hasNotice: () -> Bool = {
            ConversationStore.shared.conversation(conversationID)?.messages.contains {
                $0.runtimeRecoveryNotice == true && $0.text.contains("remains unavailable")
            } ?? false
        }
        while !hasNotice(), Date() < noticeDeadline {
            try? await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(replacementCount, 0)
        XCTAssertNotNil(ConversationStore.shared.persistenceError)
        XCTAssertTrue(ConversationStore.shared.isQueuePaused(conversationID))
        XCTAssertTrue(hasNotice())

        ConversationStore.persistenceWriteTestHook = nil
        ConversationStore.shared.retryFailedSaves()
        ConversationStore.shared.flushSaves()
        let durabilityDeadline = Date().addingTimeInterval(2)
        while !ConversationStore.shared.isDurablyCurrent(conversationID),
              Date() < durabilityDeadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(ConversationStore.shared.isDurablyCurrent(conversationID))
        bridge.retryBlockedStopRecoveryForTesting(access: selection.access)
        XCTAssertEqual(replacementCount, 1)
        XCTAssertNil(ConversationStore.shared.conversation(conversationID)?.sdkSessionId)
    }
}
