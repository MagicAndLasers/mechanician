import XCTest
@testable import Mechanician

@MainActor
final class AgentBridgePendingWorkTests: XCTestCase {
    private func runningSubagent(
        key: String = "child",
        status: WorkflowStatus = .running
    ) -> SubagentRun {
        var child = SubagentRun(
            key: key,
            subagentType: "Explore",
            task: "Inspect lifecycle ownership")
        child.status = status
        return child
    }

    private func conversation(
        id: UUID,
        subagents: [String: SubagentRun] = [:],
        workflowRuns: [String: WorkflowRun] = [:],
        messages: [TranscriptEntry] = [],
        agentActivity: [AgentActivityRecord] = [],
        queuedPrompts: [String] = []
    ) -> Conversation {
        Conversation(
            id: id,
            title: "Lifecycle",
            cwd: "",
            sdkSessionId: nil,
            messages: messages,
            updatedAt: Date(),
            workflowRuns: workflowRuns,
            subagents: subagents,
            agentActivity: agentActivity,
            queuedPrompts: queuedPrompts)
    }

    private func makeBridge() -> (AgentBridge, ConversationStore, URL, URL) {
        let storeRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("post-terminal-store-\(UUID().uuidString)")
        let bridgeRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("post-terminal-bridge-\(UUID().uuidString)")
        let store = ConversationStore(
            appSupportBaseOverride: storeRoot,
            watchesDirectory: false)
        let bridge = AgentBridge(
            settingsBaseOverride: bridgeRoot,
            environmentOverride: [:],
            conversationStoreOverride: store)
        return (bridge, store, storeRoot, bridgeRoot)
    }

    private func tearDown(
        bridge: AgentBridge,
        store: ConversationStore,
        roots: [URL]
    ) {
        AgentBridge.live.remove(bridge)
        bridge.currentID = nil
        bridge.shutdown()
        store.flushSaves()
        for root in roots { try? FileManager.default.removeItem(at: root) }
    }

    func testPostTerminalDelegateOwnerRequiresOneLiveCurrentGenerationOnExactTurn() {
        let ownerTurnID = "owner-turn"
        let childIdentity = AgentActivityIdentity.subagent("provider-child")
        var child = runningSubagent(key: "launch-tool")
        child.taskId = "provider-child"
        var subagents = [child.key: child]
        var activity: [AgentActivityRecord] = [
            .state(
                .model,
                turnID: ownerTurnID,
                agentID: childIdentity,
                agentLabel: child.subagentType),
        ]

        XCTAssertEqual(
            postTerminalDelegateActivityOwner(
                matchingAgentID: childIdentity,
                turnID: ownerTurnID,
                subagents: subagents,
                agentActivity: activity),
            PostTerminalDelegateActivityOwner(
                subagentKey: child.key,
                agentID: AgentActivityIdentity.subagent(child.key),
                label: child.subagentType,
                generationStartRecordID: activity[0].id))

        activity.append(.state(
            .completed,
            turnID: ownerTurnID,
            agentID: childIdentity))
        XCTAssertNil(postTerminalDelegateActivityOwner(
            matchingAgentID: childIdentity,
            turnID: ownerTurnID,
            subagents: subagents,
            agentActivity: activity),
            "a terminal current generation cannot accept buffered child detail")

        activity.append(.state(
            .model,
            turnID: ownerTurnID,
            agentID: childIdentity,
            startsNewLifecycleGeneration: true))
        XCTAssertNotNil(postTerminalDelegateActivityOwner(
            matchingAgentID: childIdentity,
            turnID: ownerTurnID,
            subagents: subagents,
            agentActivity: activity),
            "an authoritative retask is the only way to reopen the same child lane")

        activity.append(.state(
            .model,
            turnID: "newer-turn",
            agentID: childIdentity))
        XCTAssertNil(postTerminalDelegateActivityOwner(
            matchingAgentID: childIdentity,
            turnID: ownerTurnID,
            subagents: subagents,
            agentActivity: activity),
            "a late event from an older route cannot mutate a child now owned by a newer turn")

        var collision = runningSubagent(key: "other-launch")
        collision.taskId = child.taskId
        collision.status = .completed
        subagents[collision.key] = collision
        XCTAssertNil(postTerminalDelegateActivityOwner(
            matchingAgentID: childIdentity,
            turnID: "newer-turn",
            subagents: subagents,
            agentActivity: activity),
            "a terminal collision is still ambiguous and must fail closed")

        subagents[collision.key]?.status = .running
        XCTAssertNil(postTerminalDelegateActivityOwner(
            matchingAgentID: childIdentity,
            turnID: "newer-turn",
            subagents: subagents,
            agentActivity: activity),
            "two active provider child-id matches must fail closed")

        subagents[collision.key] = nil
        subagents[child.key]?.status = .completed
        XCTAssertNil(postTerminalDelegateActivityOwner(
            matchingAgentID: childIdentity,
            turnID: "newer-turn",
            subagents: subagents,
            agentActivity: activity),
            "a terminal child card cannot admit more Activity")
    }

    func testPostTerminalChildEventsPersistOnlyActivityAndDedupeToolReplay() throws {
        let (bridge, store, storeRoot, bridgeRoot) = makeBridge()
        defer {
            tearDown(
                bridge: bridge,
                store: store,
                roots: [storeRoot, bridgeRoot])
        }
        let conversationID = UUID()
        let turnID = "completed-parent"
        let selection = ModelSelection(
            access: .claudeSubscription,
            modelID: "claude-child")
        let message = TranscriptEntry(kind: .assistant, text: "Root response is complete.")
        let child = runningSubagent(key: "child-launch")
        let opening = AgentActivityRecord.state(
            .model,
            turnID: turnID,
            agentID: AgentActivityIdentity.subagent(child.key),
            agentLabel: child.subagentType)
            .attributed(to: selection)
        let original = conversation(
            id: conversationID,
            subagents: [child.key: child],
            messages: [message],
            agentActivity: [opening])
        store.upsert(original)
        bridge.currentID = conversationID
        bridge.entries = original.messages
        bridge.subagents = original.subagents
        bridge.agentActivity = original.agentActivity
        bridge.stageRootWorkForTesting(
            conversationID: conversationID,
            turnID: turnID,
            selection: selection)
        bridge.acknowledgeRootStopForTesting(turnID: turnID)

        let toolUse: [String: Any] = [
            "type": "tool_use",
            "id": turnID,
            "toolUseId": "child-read",
            "parentToolUseId": child.key,
            "name": "Read",
            "input": ["file_path": "/tmp/example.swift"],
        ]
        XCTAssertTrue(bridge.applyPostTerminalDelegateActivityForTesting(
            toolUse,
            turnID: turnID))
        XCTAssertEqual(bridge.entries, [message])
        XCTAssertEqual(store.conversation(conversationID)?.messages, [message])
        XCTAssertEqual(bridge.agentActivity.suffix(2).map(\.kind), [.state, .tool])
        XCTAssertEqual(bridge.agentActivity.suffix(2).first?.phase, .tool)
        XCTAssertEqual(bridge.agentActivity.last?.toolUseID, "child-read")
        XCTAssertEqual(bridge.agentActivity.last?.agentID,
                       AgentActivityIdentity.subagent(child.key))
        XCTAssertEqual(bridge.agentActivity.last?.providerAccess, selection.access)
        XCTAssertEqual(bridge.agentActivity.last?.modelID, selection.modelID)
        XCTAssertEqual(
            Set(bridge.agentActivity.suffix(2).compactMap(\.captureOrdinal)).count,
            1,
            "one provider callback must retain one capture-order batch")

        let afterTool = bridge.agentActivity
        XCTAssertFalse(bridge.applyPostTerminalDelegateActivityForTesting(
            toolUse,
            turnID: turnID))
        XCTAssertEqual(bridge.agentActivity, afterTool,
                       "a replayed toolUseId must not reopen or duplicate the tool span")

        XCTAssertTrue(bridge.applyPostTerminalDelegateActivityForTesting([
            "type": "usage",
            "id": turnID,
            "agentToolUseId": child.key,
            "input": 21,
            "output": 8,
        ], turnID: turnID))
        XCTAssertEqual(bridge.agentActivity.last?.kind, .tokens)
        XCTAssertEqual(bridge.agentActivity.last?.inputTokens, 21)
        XCTAssertEqual(bridge.agentActivity.last?.outputTokens, 8)

        let result: [String: Any] = [
            "type": "tool_result",
            "id": turnID,
            "toolUseId": "child-read",
            "status": "success",
            "result": "read complete",
        ]
        XCTAssertTrue(bridge.applyPostTerminalDelegateActivityForTesting(
            result,
            turnID: turnID))
        XCTAssertEqual(bridge.agentActivity.last?.kind, .state)
        XCTAssertEqual(bridge.agentActivity.last?.phase, .model)
        XCTAssertEqual(bridge.agentActivity.last?.agentID,
                       AgentActivityIdentity.subagent(child.key))
        let afterResult = bridge.agentActivity
        XCTAssertFalse(bridge.applyPostTerminalDelegateActivityForTesting(
            result,
            turnID: turnID))
        XCTAssertEqual(bridge.agentActivity, afterResult,
                       "a consumed result owner makes result replay inert")
        XCTAssertEqual(store.conversation(conversationID)?.agentActivity, bridge.agentActivity,
                       "post-terminal trace detail must be durable immediately")
        XCTAssertEqual(store.conversation(conversationID)?.messages, [message])

        let rejectedEvents: [[String: Any]] = [
            ["type": "tool_use", "id": turnID, "toolUseId": "root-tool", "name": "Read"],
            ["type": "usage", "id": turnID, "input": 999],
            ["type": "delta", "id": turnID, "text": "late root text"],
            ["type": "thinking", "id": turnID, "text": "late root thought"],
            ["type": "future_event", "id": turnID],
        ]
        for event in rejectedEvents {
            XCTAssertFalse(bridge.applyPostTerminalDelegateActivityForTesting(
                event,
                turnID: turnID))
        }
        XCTAssertEqual(bridge.agentActivity, afterResult)
        XCTAssertEqual(bridge.entries, [message])
        XCTAssertEqual(store.conversation(conversationID)?.messages, [message])
    }

    func testPreterminalChildToolResultClosesActivityAfterSuccessfulRootCompletion() {
        let (bridge, store, storeRoot, bridgeRoot) = makeBridge()
        defer {
            tearDown(
                bridge: bridge,
                store: store,
                roots: [storeRoot, bridgeRoot])
        }
        let conversationID = UUID()
        let turnID = "root-finishes-before-child-tool"
        let toolUseID = "child-tool-in-flight"
        let selection = ModelSelection(
            access: .claudeSubscription,
            modelID: "claude-child")
        let child = runningSubagent(key: "child")
        let childAgentID = AgentActivityIdentity.subagent(child.key)
        let message = TranscriptEntry(
            kind: .assistant,
            text: "The root response is complete while its child finishes work.")
        let activity: [AgentActivityRecord] = [
            .state(
                .model,
                turnID: turnID,
                agentID: childAgentID,
                agentLabel: child.subagentType),
            .state(
                .tool,
                turnID: turnID,
                agentID: childAgentID,
                agentLabel: child.subagentType,
                detail: "Read"),
            .tool(
                "Read",
                turnID: turnID,
                agentID: childAgentID,
                agentLabel: child.subagentType,
                toolUseID: toolUseID),
        ]
        let original = conversation(
            id: conversationID,
            subagents: [child.key: child],
            messages: [message],
            agentActivity: activity)
        store.upsert(original)
        bridge.currentID = conversationID
        bridge.entries = original.messages
        bridge.subagents = original.subagents
        bridge.agentActivity = original.agentActivity
        bridge.stageRootWorkForTesting(
            conversationID: conversationID,
            turnID: turnID,
            selection: selection)

        bridge.stageAgentActivityToolOwnerForTesting(
            turnID: turnID,
            toolUseID: toolUseID,
            agentID: childAgentID,
            label: child.subagentType)
        bridge.stageAgentActivityToolOwnerForTesting(
            turnID: turnID,
            toolUseID: "root-tool",
            agentID: AgentActivityIdentity.root)
        bridge.acknowledgeRootCompletionForTesting(turnID: turnID)

        XCTAssertTrue(bridge.hasAgentActivityToolOwnerForTesting(
            turnID: turnID,
            toolUseID: toolUseID),
            "successful root completion must preserve one exact live-child correlation")
        XCTAssertFalse(bridge.hasAgentActivityToolOwnerForTesting(
            turnID: turnID,
            toolUseID: "root-tool"),
            "root-owned tools are never admissible after root completion")
        XCTAssertTrue(bridge.applyPostTerminalDelegateActivityForTesting([
            "type": "tool_result",
            "id": turnID,
            "toolUseId": toolUseID,
            "status": "success",
        ], turnID: turnID))
        XCTAssertFalse(bridge.hasAgentActivityToolOwnerForTesting(
            turnID: turnID,
            toolUseID: toolUseID))
        XCTAssertEqual(bridge.agentActivity.last?.phase, .model)
        XCTAssertEqual(bridge.agentActivity.last?.agentID, childAgentID)
        XCTAssertEqual(store.conversation(conversationID)?.agentActivity, bridge.agentActivity)
        XCTAssertEqual(bridge.entries, [message])
        XCTAssertEqual(store.conversation(conversationID)?.messages, [message],
                       "a post-terminal child result must never reopen transcript handling")
    }

    func testPostTerminalResultCannotCrossGenerationOrNewerTurnOwnership() {
        let (bridge, store, storeRoot, bridgeRoot) = makeBridge()
        defer {
            tearDown(
                bridge: bridge,
                store: store,
                roots: [storeRoot, bridgeRoot])
        }
        let conversationID = UUID()
        let turnID = "old-parent"
        let child = runningSubagent(key: "child")
        let opening = AgentActivityRecord.state(
            .model,
            turnID: turnID,
            agentID: AgentActivityIdentity.subagent(child.key))
        let original = conversation(
            id: conversationID,
            subagents: [child.key: child],
            agentActivity: [opening])
        store.upsert(original)
        bridge.currentID = conversationID
        bridge.subagents = original.subagents
        bridge.agentActivity = original.agentActivity
        bridge.stageRootWorkForTesting(
            conversationID: conversationID,
            turnID: turnID,
            selection: .init(access: .codexSubscription, modelID: "gpt-child"))
        bridge.acknowledgeRootStopForTesting(turnID: turnID)

        XCTAssertTrue(bridge.applyPostTerminalDelegateActivityForTesting([
            "type": "tool_use",
            "id": turnID,
            "toolUseId": "generation-one-tool",
            "parentToolUseId": child.key,
            "name": "Read",
        ], turnID: turnID))
        bridge.appendCurrentAgentActivityRecord(.state(
            .model,
            turnID: turnID,
            agentID: AgentActivityIdentity.subagent(child.key),
            startsNewLifecycleGeneration: true))
        store.update(conversationID) { $0.agentActivity = bridge.agentActivity }
        XCTAssertFalse(bridge.applyPostTerminalDelegateActivityForTesting([
            "type": "tool_result",
            "id": turnID,
            "toolUseId": "generation-one-tool",
            "status": "success",
        ], turnID: turnID),
            "a result staged in generation one cannot append Model state to generation two")

        XCTAssertTrue(bridge.applyPostTerminalDelegateActivityForTesting([
            "type": "tool_use",
            "id": turnID,
            "toolUseId": "stale-tool",
            "parentToolUseId": child.key,
            "name": "Read",
        ], turnID: turnID))
        bridge.appendCurrentAgentActivityRecord(.state(
            .model,
            turnID: "newer-turn",
            agentID: AgentActivityIdentity.subagent(child.key)))
        store.update(conversationID) { $0.agentActivity = bridge.agentActivity }

        let result: [String: Any] = [
            "type": "tool_result",
            "id": turnID,
            "toolUseId": "stale-tool",
            "status": "success",
        ]
        XCTAssertFalse(bridge.applyPostTerminalDelegateActivityForTesting(
            result,
            turnID: turnID),
            "the old route is stale once this child's newest lane belongs to another turn")
        bridge.appendCurrentAgentActivityRecord(.state(
            .model,
            turnID: turnID,
            agentID: AgentActivityIdentity.subagent(child.key),
            startsNewLifecycleGeneration: true))
        store.update(conversationID) { $0.agentActivity = bridge.agentActivity }
        let beforeReplay = bridge.agentActivity
        XCTAssertFalse(bridge.applyPostTerminalDelegateActivityForTesting(
            result,
            turnID: turnID),
            "stale-result cleanup must prevent later retask from reviving its old owner entry")
        XCTAssertEqual(bridge.agentActivity, beforeReplay)
    }

    func testPostTerminalChildTerminalClearsOnlyThatChildsToolOwners() {
        let (bridge, store, storeRoot, bridgeRoot) = makeBridge()
        defer {
            tearDown(
                bridge: bridge,
                store: store,
                roots: [storeRoot, bridgeRoot])
        }
        let conversationID = UUID()
        let turnID = "shared-parent"
        var first = runningSubagent(key: "first-launch")
        first.taskId = "first-task"
        var second = runningSubagent(key: "second-launch")
        second.taskId = "second-task"
        let activity: [AgentActivityRecord] = [
            .state(
                .model,
                turnID: turnID,
                agentID: AgentActivityIdentity.subagent(first.key)),
            .state(
                .model,
                turnID: turnID,
                agentID: AgentActivityIdentity.subagent(second.key)),
        ]
        let original = conversation(
            id: conversationID,
            subagents: [first.key: first, second.key: second],
            agentActivity: activity)
        store.upsert(original)
        bridge.currentID = conversationID
        bridge.subagents = original.subagents
        bridge.agentActivity = original.agentActivity
        bridge.stageRootWorkForTesting(
            conversationID: conversationID,
            turnID: turnID,
            selection: .init(access: .claudeSubscription, modelID: "claude-child"))
        bridge.acknowledgeRootStopForTesting(turnID: turnID)

        for (child, toolUseID) in [(first, "first-tool"), (second, "second-tool")] {
            XCTAssertTrue(bridge.applyPostTerminalDelegateActivityForTesting([
                "type": "tool_use",
                "id": turnID,
                "toolUseId": toolUseID,
                "parentToolUseId": child.taskId ?? child.key,
                "name": "Read",
            ], turnID: turnID))
            XCTAssertTrue(bridge.hasAgentActivityToolOwnerForTesting(
                turnID: turnID,
                toolUseID: toolUseID))
        }

        XCTAssertTrue(bridge.clearPostTerminalAgentActivityToolOwnersForTesting([
            "type": "workflow_update",
            "id": turnID,
            "phase": "notification",
            "taskId": "first-task",
            "status": "completed",
        ], turnID: turnID))
        XCTAssertFalse(bridge.hasAgentActivityToolOwnerForTesting(
            turnID: turnID,
            toolUseID: "first-tool"))
        XCTAssertTrue(bridge.hasAgentActivityToolOwnerForTesting(
            turnID: turnID,
            toolUseID: "second-tool"),
            "one child terminal must not destroy a sibling's result correlation")
        XCTAssertFalse(bridge.applyPostTerminalDelegateActivityForTesting([
            "type": "tool_result",
            "id": turnID,
            "toolUseId": "first-tool",
            "status": "success",
        ], turnID: turnID))
        XCTAssertTrue(bridge.applyPostTerminalDelegateActivityForTesting([
            "type": "tool_result",
            "id": turnID,
            "toolUseId": "second-tool",
            "status": "success",
        ], turnID: turnID))
    }

    func testCompletedRoutePruningClearsStrandedPostTerminalToolOwner() {
        let (bridge, store, storeRoot, bridgeRoot) = makeBridge()
        defer {
            tearDown(
                bridge: bridge,
                store: store,
                roots: [storeRoot, bridgeRoot])
        }
        let conversationID = UUID()
        let turnID = "old-delegate-parent"
        let selection = ModelSelection(
            access: .claudeSubscription,
            modelID: "claude-child")
        let child = runningSubagent(key: "child")
        let original = conversation(
            id: conversationID,
            subagents: [child.key: child],
            agentActivity: [
                .state(
                    .model,
                    turnID: turnID,
                    agentID: AgentActivityIdentity.subagent(child.key)),
            ])
        store.upsert(original)
        bridge.currentID = conversationID
        bridge.subagents = original.subagents
        bridge.agentActivity = original.agentActivity
        bridge.stageRootWorkForTesting(
            conversationID: conversationID,
            turnID: turnID,
            selection: selection)
        bridge.acknowledgeRootStopForTesting(turnID: turnID)
        XCTAssertTrue(bridge.applyPostTerminalDelegateActivityForTesting([
            "type": "tool_use",
            "id": turnID,
            "toolUseId": "stranded-tool",
            "parentToolUseId": child.key,
            "name": "Read",
        ], turnID: turnID))
        bridge.subagents[child.key]?.status = .completed
        store.update(conversationID) { $0.subagents = bridge.subagents }

        for index in 0..<33 {
            let laterTurnID = "later-\(String(format: "%02d", index))"
            bridge.stageRootWorkForTesting(
                conversationID: conversationID,
                turnID: laterTurnID,
                selection: selection)
            bridge.acknowledgeRootStopForTesting(turnID: laterTurnID)
        }

        XCTAssertFalse(bridge.hasAgentActivityToolOwnerForTesting(
            turnID: turnID,
            toolUseID: "stranded-tool"),
            "bounded tombstone pruning must retire its runtime-only tool correlations")
    }

    func testPostTerminalBackgroundUsagePersistsWithoutTouchingTranscript() {
        let (bridge, store, storeRoot, bridgeRoot) = makeBridge()
        defer {
            tearDown(
                bridge: bridge,
                store: store,
                roots: [storeRoot, bridgeRoot])
        }
        let conversationID = UUID()
        let turnID = "background-parent"
        let child = runningSubagent(key: "background-child")
        let message = TranscriptEntry(kind: .assistant, text: "Finished root")
        let opening = AgentActivityRecord.state(
            .model,
            turnID: turnID,
            agentID: AgentActivityIdentity.subagent(child.key))
        let original = conversation(
            id: conversationID,
            subagents: [child.key: child],
            messages: [message],
            agentActivity: [opening])
        store.upsert(original)
        bridge.stageRootWorkForTesting(
            conversationID: conversationID,
            turnID: turnID,
            selection: .init(access: .claudeSubscription, modelID: "claude-child"))
        bridge.acknowledgeRootStopForTesting(turnID: turnID)

        XCTAssertTrue(bridge.applyPostTerminalDelegateActivityForTesting([
            "type": "usage",
            "id": turnID,
            "agentToolUseId": child.key,
            "input": 13,
            "output": 5,
        ], turnID: turnID))
        let persisted = store.conversation(conversationID)
        XCTAssertEqual(persisted?.messages, [message])
        XCTAssertEqual(persisted?.agentActivity.last?.kind, .tokens)
        XCTAssertEqual(persisted?.agentActivity.last?.inputTokens, 13)
        XCTAssertTrue(bridge.entries.isEmpty)
        XCTAssertTrue(bridge.agentActivity.isEmpty,
                      "a background trace update must not bleed into the visible conversation")
    }

    func testBridgeReportsDelegateOnlyLiveMapsAsPendingWork() {
        let support = FileManager.default.temporaryDirectory
            .appendingPathComponent("pending-delegate-\(UUID().uuidString)")
        let bridge = AgentBridge(settingsBaseOverride: support, environmentOverride: [:])
        defer {
            bridge.shutdown()
            try? FileManager.default.removeItem(at: support)
        }

        let child = runningSubagent()
        bridge.subagents = [child.key: child]

        XCTAssertTrue(
            bridge.hasPendingWork,
            "quit/window-close must not abandon a child after its parent route stops reserving the conversation")
    }

    func testDelegateOnlyLiveBridgeBlocksWorkspaceAdoptionPreflight() {
        let support = FileManager.default.temporaryDirectory
            .appendingPathComponent("workspace-move-delegate-\(UUID().uuidString)")
        let storeSupport = FileManager.default.temporaryDirectory
            .appendingPathComponent("workspace-move-store-\(UUID().uuidString)")
        let bridge = AgentBridge(settingsBaseOverride: support, environmentOverride: [:])
        let store = ConversationStore(
            appSupportBaseOverride: storeSupport,
            watchesDirectory: false)
        let projects = ProjectStore(appSupportBaseOverride: storeSupport)
        let artifacts = ArtifactStore(
            appSupportBaseOverride: storeSupport,
            watchesDirectory: false)
        let id = UUID()
        let project = Project(name: "Delegate source", cwd: "/delegate/source")
        projects.upsert(project)
        var storedConversation = conversation(id: id)
        storedConversation.projectID = project.id
        storedConversation.cwd = project.cwd
        store.upsert(storedConversation)
        let previousLastConversationID = UserDefaults.standard.object(
            forKey: "lastConversationID")
        defer {
            AgentBridge.live.remove(bridge)
            bridge.currentID = nil
            bridge.activeAgents = 0
            bridge.subagents = [:]
            bridge.shutdown()
            store.flushSaves()
            artifacts.flushSaves()
            projects.flushSaves()
            if let previousLastConversationID {
                UserDefaults.standard.set(
                    previousLastConversationID,
                    forKey: "lastConversationID")
            } else {
                UserDefaults.standard.removeObject(forKey: "lastConversationID")
            }
            try? FileManager.default.removeItem(at: support)
            try? FileManager.default.removeItem(at: storeSupport)
        }

        bridge.currentID = id
        bridge.activeAgents = 1
        let child = runningSubagent()
        bridge.subagents = [child.key: child]
        AgentBridge.live.add(bridge)

        XCTAssertTrue(bridge.runningConvs.isEmpty)
        XCTAssertTrue(
            AgentBridge.hasBlockingWorkspaceMoveWork(for: id),
            "a child that outlives its root still owns the conversation's working directory")
        XCTAssertEqual(
            WorkspaceAdoption.preflight(
                conversations: [id],
                conversations: store,
                synchronizeLiveState: true),
            .busy,
            "production live-state preflight must use the delegate-aware ownership guard")
        var folderResult: WorkspaceFolderReassignmentResult?
        XCTAssertFalse(WorkspaceAdoption.reassignWorkspaceFolderAfterAcquiring(
            WorkspaceFolderReassignmentRequest(
                projectID: project.id,
                expectedCwd: project.cwd,
                destinationCwd: "/delegate/destination"),
            projects: projects,
            conversations: store,
            artifactStore: artifacts,
            synchronizeLiveState: true
        ) { folderResult = $0 })
        XCTAssertEqual(folderResult, .activeWork)
        XCTAssertEqual(projects.project(project.id)?.cwd, project.cwd)
    }

    func testPendingProjectionIncludesOnlyBackgroundDelegatesOwnedByARoute() {
        let currentID = UUID()
        let ownedID = UUID()
        let unrelatedID = UUID()
        let ownedChild = runningSubagent(key: "owned")
        let unrelatedChild = runningSubagent(key: "unrelated")
        let stored = [
            conversation(id: currentID),
            conversation(id: ownedID, subagents: [ownedChild.key: ownedChild]),
            conversation(
                id: unrelatedID,
                subagents: [unrelatedChild.key: unrelatedChild]),
        ]

        XCTAssertTrue(agentBridgeHasPendingWork(
            hasRunningConversations: false,
            hasPendingTurnStarts: false,
            currentConversationID: currentID,
            currentWorkflowRuns: [:],
            currentSubagents: [:],
            currentQueuedPrompts: [],
            storedConversations: stored,
            routedConversationIDs: [ownedID]))
        XCTAssertFalse(agentBridgeHasPendingWork(
            hasRunningConversations: false,
            hasPendingTurnStarts: false,
            currentConversationID: currentID,
            currentWorkflowRuns: [:],
            currentSubagents: [:],
            currentQueuedPrompts: [],
            storedConversations: stored,
            routedConversationIDs: []),
            "a bridge cannot claim another window's background delegate without a route")
    }

    func testPendingProjectionSeesLiveChildUnderTerminalWorkflowAggregate() {
        var workflow = WorkflowRun(runKey: "inconsistent")
        workflow.status = .completed
        workflow.agents = [
            "0:1": WorkflowAgent(
                index: 1,
                label: "child",
                phaseIndex: 0,
                phaseTitle: "Run",
                state: .progress),
        ]

        XCTAssertTrue(hasNonterminalDelegatedWork(
            workflowRuns: [workflow.runKey: workflow],
            subagents: [:]))
        XCTAssertTrue(
            conversation(
                id: UUID(),
                workflowRuns: [workflow.runKey: workflow])
                .hasRunningDelegate,
            "sidebar/store projections must see the same inconsistent live child")
        workflow.agents["0:1"]?.state = .stopped
        XCTAssertFalse(hasNonterminalDelegatedWork(
            workflowRuns: [workflow.runKey: workflow],
            subagents: [:]))
        XCTAssertFalse(
            conversation(
                id: UUID(),
                workflowRuns: [workflow.runKey: workflow])
                .hasRunningDelegate)
    }

    func testCompletedRootRouteStaysProtectedWhileAuthoritativelyReusedChildRuns() {
        let conversationID = UUID()
        let rootTurnID = "completed-root"
        let retaskAt = Date(timeIntervalSince1970: 20_100)
        var child = runningSubagent(key: "spawn", status: .completed)
        child.taskId = "durable-child"
        child.endedAt = retaskAt.addingTimeInterval(-10)
        var subagents = [child.key: child]

        subagents = applySubagentUpdate(
            subagents,
            WorkflowUpdate([
                "phase": "progress",
                "taskId": "durable-child",
                "taskType": "codex_subagent",
                "subagentType": "Codex",
                "status": "running",
                "lastToolName": "interacted",
            ]),
            captureOrdinal: 40,
            observedAt: retaskAt)

        XCTAssertTrue(hasNonterminalDelegatedWork(
            workflowRuns: [:],
            subagents: subagents))
        XCTAssertTrue(
            conversation(id: conversationID, subagents: subagents).hasRunningDelegate,
            "the durable residency projection must retain a reused child after its root is done")
        XCTAssertTrue(agentBridgeHasPendingWork(
            hasRunningConversations: false,
            hasPendingTurnStarts: false,
            currentConversationID: conversationID,
            currentWorkflowRuns: [:],
            currentSubagents: subagents,
            currentQueuedPrompts: [],
            storedConversations: [],
            routedConversationIDs: []))
        let activity = [AgentActivityRecord.state(
            .model,
            turnID: rootTurnID,
            agentID: AgentActivityIdentity.subagent("durable-child"),
            startsNewLifecycleGeneration: true,
            at: retaskAt)]
        let activeOwners = activeDelegateOwnerTurnProjection(
            workflowRuns: [:],
            subagents: subagents,
            agentActivity: activity,
            fallbackTurnID: nil)
        XCTAssertEqual(activeOwners.turnIDs, [rootTurnID])
        XCTAssertEqual(
            completedTurnRouteIDsToPrune([
                CompletedTurnRoutePruningCandidate(
                    turnID: rootTurnID,
                    completedAt: retaskAt,
                    protectsRunningDelegates: activeOwners.turnIDs.contains(rootTurnID)),
            ], unprotectedLimit: 0),
            [],
            "the completed root route remains available for the reused child's terminal event")

        subagents = applySubagentUpdate(
            subagents,
            WorkflowUpdate([
                "phase": "notification",
                "taskId": "durable-child",
                "taskType": "codex_subagent",
                "subagentType": "Codex",
                "status": "completed",
            ]),
            captureOrdinal: 41,
            observedAt: retaskAt.addingTimeInterval(5))

        XCTAssertFalse(hasNonterminalDelegatedWork(
            workflowRuns: [:],
            subagents: subagents))
        XCTAssertFalse(
            conversation(id: conversationID, subagents: subagents).hasRunningDelegate)
        XCTAssertFalse(agentBridgeHasPendingWork(
            hasRunningConversations: false,
            hasPendingTurnStarts: false,
            currentConversationID: conversationID,
            currentWorkflowRuns: [:],
            currentSubagents: subagents,
            currentQueuedPrompts: [],
            storedConversations: [],
            routedConversationIDs: []))
        let terminalOwners = activeDelegateOwnerTurnProjection(
            workflowRuns: [:],
            subagents: subagents,
            agentActivity: activity,
            fallbackTurnID: nil)
        XCTAssertTrue(terminalOwners.turnIDs.isEmpty)
        XCTAssertEqual(
            completedTurnRouteIDsToPrune([
                CompletedTurnRoutePruningCandidate(
                    turnID: rootTurnID,
                    completedAt: retaskAt,
                    protectsRunningDelegates: terminalOwners.turnIDs.contains(rootTurnID)),
            ], unprotectedLimit: 0),
            [rootTurnID])
    }

    func testCompletedRoutePruningRetainsOldDelegateOwnerPastThirtyTwoLaterTurns() {
        let start = Date(timeIntervalSince1970: 10_000)
        let protectedID = "delegate-parent"
        var candidates = [
            CompletedTurnRoutePruningCandidate(
                turnID: protectedID,
                completedAt: start,
                protectsRunningDelegates: true),
        ]
        candidates += (0..<40).map { index in
            CompletedTurnRoutePruningCandidate(
                turnID: "later-\(String(format: "%02d", index))",
                completedAt: start.addingTimeInterval(Double(index + 1)),
                protectsRunningDelegates: false)
        }

        let pruned = completedTurnRouteIDsToPrune(candidates)

        XCTAssertFalse(pruned.contains(protectedID))
        XCTAssertEqual(pruned.count, 8)
        XCTAssertEqual(
            pruned,
            Set((0..<8).map { "later-\(String(format: "%02d", $0))" }))

        candidates[0].protectsRunningDelegates = false
        let afterDelegateFinished = completedTurnRouteIDsToPrune(candidates)
        XCTAssertTrue(
            afterDelegateFinished.contains(protectedID),
            "the old tombstone becomes ordinarily prunable once its child terminalizes")
        XCTAssertEqual(afterDelegateFinished.count, 9)
    }

    func testCompletedRoutePruningBreaksTimestampTiesDeterministically() {
        let date = Date(timeIntervalSince1970: 20_000)
        let candidates = ["z", "a", "m"].map {
            CompletedTurnRoutePruningCandidate(
                turnID: $0,
                completedAt: date,
                protectsRunningDelegates: false)
        }

        XCTAssertEqual(
            completedTurnRouteIDsToPrune(candidates, unprotectedLimit: 2),
            ["a"])
    }

    func testExactDelegateOwnerTurnDoesNotProtectAnotherProviderRoute() {
        let conversationID = UUID()
        let claudeTurnID = "turn-claude"
        let codexTurnID = "turn-codex"
        let claude = ModelSelection(
            access: .claudeSubscription,
            modelID: "claude-child")
        let codex = ModelSelection(
            access: .codexSubscription,
            modelID: "gpt-later")

        var workflow = WorkflowRun(runKey: "run-a")
        workflow.status = .completed
        workflow.agents = [
            "0:0": WorkflowAgent(
                index: 0,
                label: "child",
                phaseIndex: 0,
                phaseTitle: "Run",
                state: .progress),
        ]
        let activity: [AgentActivityRecord] = [
            AgentActivityRecord.tool(
                "Agent",
                turnID: claudeTurnID,
                agentID: AgentActivityIdentity.root)
                .attributed(to: claude),
            AgentActivityRecord.state(
                .model,
                turnID: claudeTurnID,
                agentID: AgentActivityIdentity.workflow(
                    runKey: "run-a",
                    agentKey: "0:0"))
                .attributed(to: claude),
            AgentActivityRecord.tool(
                "Read",
                turnID: codexTurnID,
                agentID: AgentActivityIdentity.root)
                .attributed(to: codex),
        ]

        let fallback = conservativeDelegateFallbackTurnID(
            agentActivity: activity,
            completedRoutes: [
                (
                    claudeTurnID,
                    Date(timeIntervalSince1970: 100),
                    ModelAccess.claudeSubscription
                ),
                (
                    codexTurnID,
                    Date(timeIntervalSince1970: 200),
                    ModelAccess.codexSubscription
                ),
            ])
        XCTAssertEqual(
            fallback,
            claudeTurnID,
            "a newer non-delegating provider turn is not a conservative child owner")

        let projection = activeDelegateOwnerTurnProjection(
            workflowRuns: [workflow.runKey: workflow],
            subagents: [:],
            agentActivity: activity,
            fallbackTurnID: fallback)
        XCTAssertEqual(projection.turnIDs, [claudeTurnID])
        XCTAssertEqual(projection.unmatchedDelegateGroups, 0)
        XCTAssertFalse(projection.usedFallback)

        let owners = [conversationID: projection.turnIDs]
        XCTAssertEqual(
            conversationIDsAffectedByScopedProcessTermination(
                [(
                    conversationID: conversationID,
                    turnID: claudeTurnID,
                    reservesConversation: false
                )],
                delegateOwnerTurnIDs: owners),
            [conversationID])
        XCTAssertTrue(
            conversationIDsAffectedByScopedProcessTermination(
                [(
                    conversationID: conversationID,
                    turnID: codexTurnID,
                    reservesConversation: false
                )],
                delegateOwnerTurnIDs: owners)
                .isEmpty,
            "the unrelated Codex lane may exit without terminalizing Claude's active child")

        XCTAssertEqual(
            completedTurnRouteIDsToPrune([
                CompletedTurnRoutePruningCandidate(
                    turnID: claudeTurnID,
                    completedAt: Date(timeIntervalSince1970: 100),
                    protectsRunningDelegates: projection.turnIDs.contains(claudeTurnID)),
                CompletedTurnRoutePruningCandidate(
                    turnID: codexTurnID,
                    completedAt: Date(timeIntervalSince1970: 200),
                    protectsRunningDelegates: projection.turnIDs.contains(codexTurnID)),
            ], unprotectedLimit: 0),
            [codexTurnID])
    }

    func testLaneLessAggregateUsesOnlyOneEvidenceBackedFallbackTurn() {
        var workflow = WorkflowRun(runKey: "waiting-run")
        workflow.status = .running
        let activity: [AgentActivityRecord] = [
            .tool(
                "Task",
                turnID: "delegating-turn",
                agentID: AgentActivityIdentity.root),
            .tool(
                "Read",
                turnID: "newer-turn",
                agentID: AgentActivityIdentity.root),
        ]
        let fallback = conservativeDelegateFallbackTurnID(
            agentActivity: activity,
            completedRoutes: [
                (
                    "delegating-turn",
                    Date(timeIntervalSince1970: 100),
                    ModelAccess.claudeSubscription
                ),
                (
                    "newer-turn",
                    Date(timeIntervalSince1970: 200),
                    ModelAccess.codexSubscription
                ),
            ])

        let projection = activeDelegateOwnerTurnProjection(
            workflowRuns: [workflow.runKey: workflow],
            subagents: [:],
            agentActivity: activity,
            fallbackTurnID: fallback)

        XCTAssertEqual(projection.turnIDs, ["delegating-turn"])
        XCTAssertEqual(projection.unmatchedDelegateGroups, 1)
        XCTAssertTrue(projection.usedFallback)
    }

    func testLaneLessAggregateDoesNotGuessBetweenProviderFallbacks() {
        var workflow = WorkflowRun(runKey: "ambiguous-run")
        workflow.status = .running
        let activity: [AgentActivityRecord] = [
            AgentActivityRecord.tool(
                "Task",
                turnID: "claude-turn",
                agentID: AgentActivityIdentity.root)
                .attributed(to: ModelSelection(
                    access: .claudeSubscription,
                    modelID: "claude")),
            AgentActivityRecord.tool(
                "Agent",
                turnID: "codex-turn",
                agentID: AgentActivityIdentity.root)
                .attributed(to: ModelSelection(
                    access: .codexSubscription,
                    modelID: "gpt")),
        ]
        let fallback = conservativeDelegateFallbackTurnID(
            agentActivity: activity,
            completedRoutes: [
                (
                    "claude-turn",
                    Date(timeIntervalSince1970: 100),
                    ModelAccess.claudeSubscription
                ),
                (
                    "codex-turn",
                    Date(timeIntervalSince1970: 200),
                    ModelAccess.codexSubscription
                ),
            ])
        XCTAssertNil(fallback)

        let projection = activeDelegateOwnerTurnProjection(
            workflowRuns: [workflow.runKey: workflow],
            subagents: [:],
            agentActivity: activity,
            fallbackTurnID: fallback)
        XCTAssertTrue(projection.turnIDs.isEmpty)
        XCTAssertEqual(projection.unmatchedDelegateGroups, 1)
        XCTAssertFalse(projection.usedFallback)
    }
}
