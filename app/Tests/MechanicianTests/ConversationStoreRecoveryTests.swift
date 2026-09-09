import XCTest
@testable import Mechanician

@MainActor
final class ConversationStoreRecoveryTests: XCTestCase {
    func testNestedWorkflowAndSubagentStateRoundTripsThroughRelaunch() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let store = ConversationStore(appSupportBaseOverride: base, watchesDirectory: false)

        let started = Date(timeIntervalSince1970: 1_786_000_000)
        let ended = started.addingTimeInterval(12)
        var run = WorkflowRun(
            runKey: "workflow-private-alias",
            toolUseId: "workflow-tool-alias",
            runTaskId: "workflow-task-alias",
            workflowName: "Evidence sweep",
            description: "Verify the workflow lifecycle",
            summary: "All checks complete",
            status: .completed,
            usage: WorkflowUsage(
                totalTokens: 1_200,
                toolUses: 3,
                durationMs: 12_000,
                toolUsesObserved: false,
                inputTokens: 900,
                cachedInputTokens: 400,
                outputTokens: 300,
                reasoningOutputTokens: 50),
            error: nil,
            startedAt: started,
            endedAt: ended)
        run.phases["0"] = WorkflowPhase(index: 0, title: "Inspect")
        var workflowAgent = WorkflowAgent(
            index: 0,
            label: "Researcher",
            phaseIndex: 0,
            phaseTitle: "Inspect",
            state: .done,
            agentId: "provider-child-alias",
            model: "fixture-model",
            attempt: 2,
            lastToolName: "Read",
            lastToolSummary: "Read the relevant files",
            promptPreview: "Inspect the lifecycle",
            tokens: 1_200,
            toolCalls: 3,
            resultPreview: "Lifecycle verified",
            durationMs: 12_000,
            startedAt: started,
            endedAt: ended)
        workflowAgent.toolEvents = [
            SubagentToolEvent(name: "Read", target: "WorkflowStore.swift", at: started)]
        run.agents["0:0"] = workflowAgent

        var parent = SubagentRun(
            key: "parent", subagentType: "Explore", task: "Coordinate evidence")
        parent.taskId = "parent-task"
        parent.status = .completed
        parent.startedAt = started
        parent.endedAt = ended
        parent.resultPreview = "Parent complete"
        var child = SubagentRun(
            key: "child", subagentType: "Explore", task: "Inspect nested evidence")
        child.taskId = "child-task"
        child.parentToolUseId = "parent"
        child.status = .completed
        child.startedAt = started.addingTimeInterval(1)
        child.endedAt = ended
        child.resultPreview = "Child complete"

        let conversation = Conversation(
            title: "Workflow persistence",
            cwd: "",
            sdkSessionId: nil,
            messages: [TranscriptEntry(kind: .user, text: "Run the workflow")],
            updatedAt: ended,
            workflowRuns: [run.runKey: run],
            subagents: [parent.key: parent, child.key: child])
        store.upsert(conversation)
        store.flushSaves()

        let relaunched = ConversationStore(
            appSupportBaseOverride: base,
            watchesDirectory: false)
        let loaded = try XCTUnwrap(relaunched.conversation(conversation.id))
        XCTAssertEqual(loaded.workflowRuns, conversation.workflowRuns)
        XCTAssertEqual(loaded.subagents, conversation.subagents)

        let forest = subagentForest(loaded.subagents)
        XCTAssertEqual(forest.map(\.sub.key), ["parent"])
        XCTAssertEqual(forest.first?.children.map(\.sub.key), ["child"])
        XCTAssertEqual(
            loaded.workflowRuns[run.runKey]?.agents["0:0"]?.attempt,
            2,
            "an attempt ordinal is retained as provider evidence, not inferred retry lineage")
    }

    func testRelaunchHealsAWorkflowAggregateTaskMirrorWithoutDroppingToolEvidence() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let store = ConversationStore(appSupportBaseOverride: base, watchesDirectory: false)

        let ended = Date(timeIntervalSince1970: 1_786_000_100)
        let run = WorkflowRun(
            runKey: "workflow-tool",
            toolUseId: "workflow-tool",
            runTaskId: "workflow-task",
            workflowName: "Evidence workflow",
            status: .failed,
            endedAt: ended)
        var aggregateMirror = SubagentRun(
            key: "workflow-tool",
            subagentType: "workflow",
            task: "Run the workflow")
        aggregateMirror.taskId = "workflow-task"
        var parent = SubagentRun(
            key: "parent-tool",
            subagentType: "Explore",
            task: "Own the workflow")
        parent.taskId = "parent-task"
        parent.status = .completed
        let aggregateID = AgentActivityIdentity.subagent("workflow-tool")
        let conversation = Conversation(
            title: "Workflow mirror repair",
            cwd: "",
            sdkSessionId: nil,
            messages: [TranscriptEntry(kind: .user, text: "Run it")],
            updatedAt: ended,
            workflowRuns: [run.runKey: run],
            subagents: [aggregateMirror.key: aggregateMirror, parent.key: parent],
            agentActivity: [
                .state(
                    .model,
                    turnID: "turn",
                    agentID: aggregateID,
                    detail: "Delegated"),
                .tool(
                    "Read",
                    turnID: "turn",
                    agentID: aggregateID,
                    target: "relative/evidence.txt"),
            ])
        store.upsert(conversation)
        store.flushSaves()

        let relaunched = ConversationStore(
            appSupportBaseOverride: base,
            watchesDirectory: false)
        let healed = try XCTUnwrap(relaunched.conversation(conversation.id))
        XCTAssertNil(healed.subagents["workflow-tool"])
        XCTAssertEqual(healed.subagents["parent-tool"]?.status, .completed)
        XCTAssertFalse(healed.agentActivity.contains {
            $0.kind == .state && $0.agentID == aggregateID
        })
        XCTAssertTrue(healed.agentActivity.contains {
            $0.kind == .tool && $0.agentID == aggregateID
        })

        relaunched.flushSaves()
        let secondRelaunch = ConversationStore(
            appSupportBaseOverride: base,
            watchesDirectory: false)
        let persisted = try XCTUnwrap(secondRelaunch.conversation(conversation.id))
        XCTAssertNil(persisted.subagents["workflow-tool"])
        XCTAssertTrue(persisted.agentActivity.contains {
            $0.kind == .tool && $0.agentID == aggregateID
        })
    }

    func testCaptureOrdinalHighWatermarkSurvivesRemovalAndRelaunch() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let store = ConversationStore(appSupportBaseOverride: base, watchesDirectory: false)

        var retained = TranscriptEntry(kind: .user, text: "captured")
        retained.captureOrdinal = 40
        let conversation = Conversation(
            title: "Ordered", cwd: "", sdkSessionId: nil,
            messages: [retained], updatedAt: Date())
        store.upsert(conversation)
        store.flushSaves()

        let next = store.nextCaptureOrdinal(for: conversation.id)
        XCTAssertEqual(next, 41)
        store.update(conversation.id) { value in
            var transient = TranscriptEntry(kind: .assistant, text: "later withdrawn")
            transient.captureOrdinal = next
            value.messages.append(transient)
        }
        store.flushSaves()
        store.update(conversation.id) { value in
            value.messages.removeAll { $0.captureOrdinal == next }
        }
        store.flushSaves()

        let relaunched = ConversationStore(
            appSupportBaseOverride: base,
            watchesDirectory: false)
        XCTAssertEqual(
            relaunched.conversation(conversation.id)?.captureOrdinalHighWatermark,
            41,
            "removing a retained fact must not make its record-local order reusable")
        XCTAssertEqual(relaunched.nextCaptureOrdinal(for: conversation.id), 42)
    }

    func testCaptureOrdinalAllocationAloneAddsNoSaveBoundary() {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let store = ConversationStore(appSupportBaseOverride: base, watchesDirectory: false)
        let conversationID = UUID()

        XCTAssertEqual(store.nextCaptureOrdinal(for: conversationID), 1)
        store.flushSaves()

        let directory = base.appendingPathComponent("conversations", isDirectory: true)
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: directory.appendingPathComponent(
                    "\(conversationID.uuidString).json").path),
            "the allocator must ride an existing durable mutation, never create its own rewrite")
    }

    func testRepeatedCaptureOrdinalAllocationDoesNotRescanLargeResidentTranscript() {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let store = ConversationStore(appSupportBaseOverride: base, watchesDirectory: false)

        var messages = (0..<9_421).map { index in
            TranscriptEntry(kind: index.isMultiple(of: 2) ? .user : .assistant, text: "")
        }
        messages[messages.count - 1].toolResultCaptureOrdinal = 50_000
        let conversation = Conversation(
            title: "Large legacy record", cwd: "", sdkSessionId: nil,
            messages: messages, updatedAt: Date())

        store.upsert(conversation)
        let scansAfterInstall = store.captureOrdinalSeedScanCount
        XCTAssertGreaterThan(scansAfterInstall, 0)
        XCTAssertEqual(store.nextCaptureOrdinal(for: conversation.id), 50_001)
        for expected in 50_002...51_001 {
            XCTAssertEqual(store.nextCaptureOrdinal(for: conversation.id), UInt64(expected))
        }
        XCTAssertEqual(
            store.captureOrdinalSeedScanCount,
            scansAfterInstall,
            "provider-event allocations must stay O(1) after the resident generation is seeded")
    }

    func testReplacementCaptureOrdinalEvidenceOnlyAdvancesSeed() {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let store = ConversationStore(appSupportBaseOverride: base, watchesDirectory: false)
        let id = UUID()

        var firstEntry = TranscriptEntry(kind: .user, text: "first")
        firstEntry.captureOrdinal = 40
        var first = Conversation(
            id: id, title: "First", cwd: "", sdkSessionId: nil,
            messages: [firstEntry], updatedAt: Date())
        first.captureOrdinalHighWatermark = 45
        store.upsert(first)
        XCTAssertEqual(store.nextCaptureOrdinal(for: id), 46)

        var replacementEntry = TranscriptEntry(kind: .assistant, text: "replacement")
        replacementEntry.supersessionCaptureOrdinal = 80
        var replacement = Conversation(
            id: id, title: "Replacement", cwd: "", sdkSessionId: nil,
            messages: [replacementEntry], updatedAt: Date())
        replacement.captureOrdinalHighWatermark = 90
        store.upsert(replacement)
        XCTAssertEqual(store.nextCaptureOrdinal(for: id), 91)

        // A stale/lower replacement may never reuse chronology already allocated in this process.
        store.upsert(first)
        XCTAssertEqual(store.nextCaptureOrdinal(for: id), 92)
    }

    func testCaptureOrdinalAllocationSaturatesAtUInt64Maximum() {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let store = ConversationStore(appSupportBaseOverride: base, watchesDirectory: false)

        var conversation = Conversation(
            title: "Saturated", cwd: "", sdkSessionId: nil,
            messages: [TranscriptEntry(kind: .user, text: "captured")], updatedAt: Date())
        conversation.captureOrdinalHighWatermark = UInt64.max
        store.upsert(conversation)

        XCTAssertEqual(store.nextCaptureOrdinal(for: conversation.id), UInt64.max)
        XCTAssertEqual(store.nextCaptureOrdinal(for: conversation.id), UInt64.max)
    }

    func testColdLoadedQueueIsQuarantinedUntilExplicitResume() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let directory = base.appendingPathComponent("conversations", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let conversation = Conversation(
            title: "Recovered",
            cwd: "",
            sdkSessionId: nil,
            modelSelection: ModelSelection(
                access: .codexSubscription,
                modelID: "model-a"),
            messages: [TranscriptEntry(kind: .user, text: "Earlier work")],
            updatedAt: Date(),
            queuedPrompts: ["Continue after restart"])
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(conversation).write(
            to: directory.appendingPathComponent("\(conversation.id.uuidString).json"))

        let store = ConversationStore(
            appSupportBaseOverride: base,
            watchesDirectory: false)

        XCTAssertTrue(store.isQueuePaused(conversation.id))
        XCTAssertEqual(store.conversation(conversation.id)?.queuedPrompts, ["Continue after restart"])
        XCTAssertTrue(store.resumeQueue(conversation.id))
        XCTAssertFalse(store.isQueuePaused(conversation.id))
        XCTAssertFalse(store.resumeQueue(conversation.id))
    }

    func testUnconfirmedGuidanceBecomesVisibleQueuedRecoveryWork() {
        var guidance = TranscriptEntry(kind: .user, text: "Use the smaller layout")
        guidance.guidanceState = .sending
        var conversation = Conversation(
            title: "Recovered",
            cwd: "",
            sdkSessionId: nil,
            modelSelection: ModelSelection(
                access: .claudeSubscription,
                modelID: "claude"),
            messages: [guidance],
            updatedAt: Date())

        XCTAssertTrue(ConversationStore.healStaleState(&conversation))
        XCTAssertTrue(conversation.messages.isEmpty)
        XCTAssertEqual(conversation.queuedPrompts, ["Use the smaller layout"])
    }

    func testColdLoadStopsWorkflowAggregateChildrenAndClosesActivityLanes() {
        var run = WorkflowRun(runKey: "run-1", status: .running)
        run.agents["0:0"] = WorkflowAgent(
            index: 0,
            label: "finder",
            phaseIndex: 0,
            phaseTitle: "Find",
            state: .progress)
        var conversation = Conversation(
            title: "Recovered",
            cwd: "",
            sdkSessionId: nil,
            messages: [TranscriptEntry(kind: .user, text: "Delegate this")],
            updatedAt: Date(),
            workflowRuns: ["run-1": run],
            agentActivity: [
                .state(
                    .model,
                    turnID: "turn-1",
                    agentID: AgentActivityIdentity.workflow(
                        runKey: "run-1",
                        agentKey: "0:0")),
            ])

        XCTAssertTrue(ConversationStore.healStaleState(&conversation))
        XCTAssertEqual(conversation.workflowRuns["run-1"]?.status, .stopped)
        XCTAssertEqual(
            conversation.workflowRuns["run-1"]?.agents["0:0"]?.state,
            .stopped)
        XCTAssertNotNil(conversation.workflowRuns["run-1"]?.endedAt)
        XCTAssertNotNil(
            conversation.workflowRuns["run-1"]?.agents["0:0"]?.endedAt)
        XCTAssertTrue(conversation.agentActivity.contains {
            $0.agentID == AgentActivityIdentity.workflow(
                runKey: "run-1",
                agentKey: "0:0")
                && $0.turnID == "turn-1"
                && $0.phase == .stopped
        })
    }

    func testColdLoadStopsNonterminalSubagentAtItsLatestPersistedLaneObservation() throws {
        let startedAt = Date(timeIntervalSince1970: 10_000)
        let laneEndedAt = startedAt.addingTimeInterval(12)
        let rootEndedAt = startedAt.addingTimeInterval(30)
        let restartedAt = startedAt.addingTimeInterval(86_400)
        let selection = ModelSelection(
            access: .codexSubscription,
            modelID: "gpt-5")
        let priorSelection = ModelSelection(
            access: .codexSubscription,
            modelID: "gpt-old")
        var subagent = SubagentRun(
            key: "spawn-call",
            subagentType: "Codex",
            task: "Inspect the persisted lane",
            startedAt: startedAt)
        subagent.taskId = "child-thread"
        subagent.lastUpdateAt = startedAt.addingTimeInterval(5)
        let canonicalID = AgentActivityIdentity.subagent("spawn-call")
        let providerID = AgentActivityIdentity.subagent("child-thread")
        var mirroredRun = WorkflowRun(
            runKey: "prior-workflow",
            status: .completed,
            startedAt: startedAt.addingTimeInterval(-30),
            endedAt: startedAt.addingTimeInterval(-10))
        mirroredRun.agents["0:0"] = WorkflowAgent(
            index: 0,
            label: "Codex",
            phaseIndex: 0,
            phaseTitle: "Inspect",
            state: .done,
            agentId: "child-thread",
            startedAt: startedAt.addingTimeInterval(-30),
            endedAt: startedAt.addingTimeInterval(-10))
        let workflowID = AgentActivityIdentity.workflow(
            runKey: mirroredRun.runKey,
            agentKey: "0:0")
        let saved = Conversation(
            title: "Interrupted subagent",
            cwd: "",
            sdkSessionId: nil,
            modelSelection: selection,
            messages: [TranscriptEntry(kind: .user, text: "Delegate this")],
            updatedAt: restartedAt,
            workflowRuns: [mirroredRun.runKey: mirroredRun],
            subagents: [subagent.key: subagent],
            agentActivity: [
                AgentActivityRecord.state(
                    .model,
                    turnID: "owned-turn",
                    agentID: providerID,
                    detail: "Prior generation",
                    at: startedAt.addingTimeInterval(-20))
                    .attributed(to: priorSelection),
                AgentActivityRecord.tool(
                    "Build",
                    turnID: "owned-turn",
                    agentID: providerID,
                    at: startedAt.addingTimeInterval(50))
                    .attributed(to: priorSelection),
                AgentActivityRecord.state(
                    .completed,
                    turnID: "owned-turn",
                    agentID: providerID,
                    at: startedAt.addingTimeInterval(-10))
                    .attributed(to: priorSelection),
                AgentActivityRecord.state(
                    .model,
                    turnID: "owned-turn",
                    agentID: canonicalID,
                    detail: "Responding",
                    startsNewLifecycleGeneration: true,
                    at: startedAt.addingTimeInterval(1))
                    .attributed(to: selection),
                AgentActivityRecord.tool(
                    "Read",
                    turnID: "owned-turn",
                    agentID: workflowID,
                    at: laneEndedAt)
                    .attributed(to: selection),
                // Persisted append order can lag event time. The boundary is the maximum timestamp
                // in the current generation, not the last append or an older same-turn generation.
                AgentActivityRecord.state(
                    .model,
                    turnID: "owned-turn",
                    agentID: providerID,
                    detail: "Historical replay",
                    at: startedAt.addingTimeInterval(4))
                    .attributed(to: selection),
                AgentActivityRecord.state(
                    .completed,
                    turnID: "owned-turn",
                    at: rootEndedAt)
                    .attributed(to: selection),
            ])
        var restarted = try JSONDecoder().decode(
            Conversation.self,
            from: JSONEncoder().encode(saved))

        XCTAssertTrue(ConversationStore.healStaleState(&restarted))
        XCTAssertEqual(restarted.subagents[subagent.key]?.status, .stopped)
        XCTAssertEqual(restarted.subagents[subagent.key]?.endedAt, laneEndedAt)
        let terminal = try XCTUnwrap(restarted.agentActivity.last {
            $0.turnID == "owned-turn"
                && $0.agentID == providerID
                && $0.kind == .state
                && $0.phase == .stopped
        })
        XCTAssertEqual(terminal.at, laneEndedAt)
        XCTAssertEqual(terminal.providerAccess, selection.access)
        XCTAssertEqual(terminal.modelID, selection.modelID)
        XCTAssertEqual(
            terminal.harnessLaneID,
            AgentHarnessLaneID.inferred(from: selection.access))
        XCTAssertNotEqual(terminal.at, rootEndedAt)
        XCTAssertNotEqual(terminal.at, restartedAt)

        let healedCount = restarted.agentActivity.count
        XCTAssertFalse(ConversationStore.healStaleState(&restarted))
        XCTAssertEqual(restarted.agentActivity.count, healedCount)
    }

    func testColdLoadStopsWorkflowChildAtItsLatestPersistedLaneObservation() throws {
        let startedAt = Date(timeIntervalSince1970: 20_000)
        let laneEndedAt = startedAt.addingTimeInterval(18)
        let rootEndedAt = startedAt.addingTimeInterval(45)
        let restartedAt = startedAt.addingTimeInterval(86_400)
        let selection = ModelSelection(
            access: .claudeSubscription,
            modelID: "claude")
        var run = WorkflowRun(
            runKey: "evidence-run",
            status: .running,
            startedAt: startedAt)
        run.lastUpdateAt = startedAt.addingTimeInterval(7)
        run.agents["0:0"] = WorkflowAgent(
            index: 0,
            label: "Researcher",
            phaseIndex: 0,
            phaseTitle: "Inspect",
            state: .progress,
            agentId: "provider-child",
            startedAt: startedAt.addingTimeInterval(1))
        let workflowID = AgentActivityIdentity.workflow(
            runKey: run.runKey,
            agentKey: "0:0")
        let saved = Conversation(
            title: "Interrupted workflow",
            cwd: "",
            sdkSessionId: nil,
            modelSelection: selection,
            messages: [TranscriptEntry(kind: .user, text: "Run the workflow")],
            updatedAt: restartedAt,
            workflowRuns: [run.runKey: run],
            agentActivity: [
                AgentActivityRecord.state(
                    .model,
                    turnID: "workflow-turn",
                    agentID: workflowID,
                    detail: "Responding",
                    at: startedAt.addingTimeInterval(2))
                    .attributed(to: selection),
                AgentActivityRecord.tool(
                    "Build",
                    turnID: "workflow-turn",
                    agentID: workflowID,
                    at: laneEndedAt)
                    .attributed(to: selection),
                AgentActivityRecord.state(
                    .model,
                    turnID: "workflow-turn",
                    agentID: workflowID,
                    detail: "Historical replay",
                    at: startedAt.addingTimeInterval(6))
                    .attributed(to: selection),
                AgentActivityRecord.state(
                    .completed,
                    turnID: "workflow-turn",
                    at: rootEndedAt)
                    .attributed(to: selection),
            ])
        var restarted = try JSONDecoder().decode(
            Conversation.self,
            from: JSONEncoder().encode(saved))

        XCTAssertTrue(ConversationStore.healStaleState(&restarted))
        XCTAssertEqual(restarted.workflowRuns[run.runKey]?.status, .stopped)
        XCTAssertEqual(restarted.workflowRuns[run.runKey]?.endedAt, laneEndedAt)
        XCTAssertEqual(
            restarted.workflowRuns[run.runKey]?.agents["0:0"]?.state,
            .stopped)
        XCTAssertEqual(
            restarted.workflowRuns[run.runKey]?.agents["0:0"]?.endedAt,
            laneEndedAt)
        let terminal = try XCTUnwrap(restarted.agentActivity.last {
            $0.turnID == "workflow-turn"
                && $0.agentID == workflowID
                && $0.kind == .state
                && $0.phase == .stopped
        })
        XCTAssertEqual(terminal.at, laneEndedAt)
        XCTAssertEqual(terminal.providerAccess, selection.access)
        XCTAssertEqual(terminal.modelID, selection.modelID)
        XCTAssertEqual(
            terminal.harnessLaneID,
            AgentHarnessLaneID.inferred(from: selection.access))
        XCTAssertNotEqual(terminal.at, rootEndedAt)
        XCTAssertNotEqual(terminal.at, restartedAt)

        let healedCount = restarted.agentActivity.count
        XCTAssertFalse(ConversationStore.healStaleState(&restarted))
        XCTAssertEqual(restarted.agentActivity.count, healedCount)
    }

    func testColdLoadHealsLiveChildBeneathTerminalWorkflow() {
        var run = WorkflowRun(runKey: "legacy", status: .completed)
        run.agents["0:0"] = WorkflowAgent(
            index: 0,
            label: "legacy child",
            phaseIndex: 0,
            phaseTitle: "Work",
            state: .progress)
        var conversation = Conversation(
            title: "Recovered",
            cwd: "",
            sdkSessionId: nil,
            messages: [TranscriptEntry(kind: .user, text: "Earlier work")],
            updatedAt: Date(),
            workflowRuns: ["legacy": run])

        XCTAssertTrue(ConversationStore.healStaleState(&conversation))
        XCTAssertEqual(conversation.workflowRuns["legacy"]?.status, .completed)
        XCTAssertEqual(
            conversation.workflowRuns["legacy"]?.agents["0:0"]?.state,
            .stopped)
    }

    func testRestartClosesNewerOpenActivityForAnAlreadyCompletedReusableSubagent() throws {
        let originalStart = Date(timeIntervalSince1970: 800)
        let originalEnd = originalStart.addingTimeInterval(10)
        var completed = SubagentRun(
            key: "spawn-call",
            subagentType: "Codex",
            task: "Audit the activity panel",
            status: .completed,
            startedAt: originalStart,
            endedAt: originalEnd)
        completed.taskId = "child-thread"
        completed.startedCaptureOrdinal = 10
        completed.endedCaptureOrdinal = 20

        let newTurnStart = Date(timeIntervalSince1970: 1_000)
        let laneEnd = newTurnStart.addingTimeInterval(7)
        let newTurnEnd = newTurnStart.addingTimeInterval(12)
        let selection = ModelSelection(
            access: .codexSubscription,
            modelID: "gpt-5")
        var newerActivity = [
            AgentActivityRecord.state(
                .model,
                turnID: "new-turn",
                at: newTurnStart)
                .attributed(to: selection),
            AgentActivityRecord.state(
                .model,
                turnID: "new-turn",
                agentID: AgentActivityIdentity.subagent("child-thread"),
                agentLabel: "Codex",
                detail: "Responding",
                at: newTurnStart.addingTimeInterval(2))
                .attributed(to: selection),
            AgentActivityRecord.tool(
                "RecallMemory",
                turnID: "new-turn",
                agentID: AgentActivityIdentity.subagent("child-thread"),
                agentLabel: "Codex",
                at: laneEnd)
                .attributed(to: selection),
            AgentActivityRecord.state(
                .completed,
                turnID: "new-turn",
                at: newTurnEnd)
                .attributed(to: selection),
        ]
        for index in newerActivity.indices {
            newerActivity[index].captureOrdinal = UInt64(30 + index)
        }
        var conversation = Conversation(
            title: "Recovered reusable agent",
            cwd: "",
            sdkSessionId: nil,
            modelSelection: selection,
            messages: [TranscriptEntry(kind: .user, text: "Verify the release")],
            updatedAt: newTurnEnd,
            subagents: [completed.key: completed],
            agentActivity: newerActivity)
        let aliases = agentActivityAliases(subagents: conversation.subagents)
        XCTAssertFalse(
            agentActivityTurnSummaries(
                conversation.agentActivity,
                aliases: aliases)[0].isTerminal)

        // Persist and decode first: this is the same entry path SQLite reconstruction exercises
        // before ConversationStore performs its cold-load healing pass.
        conversation = try JSONDecoder().decode(
            Conversation.self,
            from: JSONEncoder().encode(conversation))
        XCTAssertTrue(ConversationStore.healStaleState(&conversation))

        XCTAssertEqual(conversation.subagents["spawn-call"]?.status, .completed)
        XCTAssertEqual(conversation.subagents["spawn-call"]?.endedAt, originalEnd)
        XCTAssertEqual(conversation.subagents["spawn-call"]?.endedCaptureOrdinal, 20)
        let repairedAliases = agentActivityAliases(subagents: conversation.subagents)
        let repairedLane = canonicalizedAgentActivityGroups(
            conversation.agentActivity.filter { $0.turnID == "new-turn" },
            aliases: repairedAliases)[AgentActivityIdentity.subagent("spawn-call")] ?? []
        let repair = try XCTUnwrap(repairedLane.last {
            $0.kind == .state && $0.phase == .stopped
        })
        XCTAssertEqual(repair.at, laneEnd)
        XCTAssertEqual(repair.providerAccess, selection.access)
        XCTAssertEqual(repair.modelID, selection.modelID)
        XCTAssertTrue(agentActivityTurnSummaries(
            conversation.agentActivity,
            aliases: repairedAliases)[0].isTerminal)

        // The healed ledger is durable and reprojects as done after another restart. The second
        // cold-load pass must not append another synthetic terminal boundary.
        var restarted = try JSONDecoder().decode(
            Conversation.self,
            from: JSONEncoder().encode(conversation))
        let repairedCount = restarted.agentActivity.count
        XCTAssertFalse(ConversationStore.healStaleState(&restarted))
        XCTAssertEqual(restarted.agentActivity.count, repairedCount)
        XCTAssertTrue(agentActivityTurnSummaries(
            restarted.agentActivity,
            aliases: agentActivityAliases(subagents: restarted.subagents))[0].isTerminal)
    }

    func testRestartClosesAnOpenRootLaneAtItsLastPersistedObservation() throws {
        let turnStart = Date(timeIntervalSince1970: 2_000)
        let laneEnd = turnStart.addingTimeInterval(4)
        let selection = ModelSelection(
            access: .claudeSubscription,
            modelID: "claude")
        let saved = Conversation(
            title: "Interrupted root turn",
            cwd: "",
            sdkSessionId: nil,
            modelSelection: selection,
            messages: [TranscriptEntry(kind: .user, text: "Inspect the workspace")],
            updatedAt: turnStart.addingTimeInterval(30),
            agentActivity: [
                AgentActivityRecord.state(
                    .model,
                    turnID: "interrupted-turn",
                    detail: "Responding",
                    at: turnStart)
                    .attributed(to: selection),
                AgentActivityRecord.tool(
                    "Read",
                    turnID: "interrupted-turn",
                    agentID: AgentActivityIdentity.root,
                    at: laneEnd)
                    .attributed(to: selection),
            ])
        var restarted = try JSONDecoder().decode(
            Conversation.self,
            from: JSONEncoder().encode(saved))

        XCTAssertTrue(ConversationStore.healStaleState(&restarted))
        let rootTerminal = try XCTUnwrap(restarted.agentActivity.last {
            $0.turnID == "interrupted-turn"
                && $0.agentID == AgentActivityIdentity.root
                && $0.kind == .state
                && $0.phase == .stopped
        })
        XCTAssertEqual(rootTerminal.at, laneEnd)
        XCTAssertEqual(rootTerminal.providerAccess, selection.access)
        XCTAssertTrue(agentActivityTurnSummaries(restarted.agentActivity)[0].isTerminal)
    }

    func testRestartClosesHarnessOnlyRootLaneAtItsLastPersistedObservation() throws {
        let turnID = "interrupted-harness-only-turn"
        let turnStart = Date(timeIntervalSince1970: 3_000)
        let laneEnd = turnStart.addingTimeInterval(4)
        let selection = ModelSelection(
            access: .claudeSubscription,
            modelID: "claude")
        let saved = Conversation(
            title: "Interrupted harness-only turn",
            cwd: "",
            sdkSessionId: nil,
            modelSelection: selection,
            messages: [TranscriptEntry(kind: .user, text: "Inspect the workspace")],
            updatedAt: turnStart.addingTimeInterval(30),
            agentActivity: [
                AgentActivityRecord.harnessObservation(
                    turnID: turnID,
                    lane: .claude,
                    event: .phase,
                    phase: .providerReady,
                    provenance: .mechanicianClock,
                    at: turnStart)
                    .attributed(to: selection),
                AgentActivityRecord.harnessObservation(
                    turnID: turnID,
                    lane: .claude,
                    event: .phase,
                    phase: .requestAccepted,
                    provenance: .mechanicianClock,
                    at: laneEnd)
                    .attributed(to: selection),
            ])
        let savedSummary = try XCTUnwrap(agentActivityTurnSummaries(saved.agentActivity).first)
        XCTAssertFalse(savedSummary.isTerminal)
        XCTAssertTrue(appKitHarnessTraceSpans(
            records: saved.agentActivity,
            summary: savedSummary).contains(where: \.isOpen))

        var restarted = try JSONDecoder().decode(
            Conversation.self,
            from: JSONEncoder().encode(saved))

        XCTAssertTrue(ConversationStore.healStaleState(&restarted))
        let rootTerminal = try XCTUnwrap(restarted.agentActivity.last {
            $0.turnID == turnID
                && $0.agentID == AgentActivityIdentity.root
                && $0.kind == .state
                && $0.phase == .stopped
        })
        XCTAssertEqual(rootTerminal.at, laneEnd)
        XCTAssertEqual(rootTerminal.providerAccess, selection.access)
        XCTAssertEqual(rootTerminal.harnessLaneID, .claude)
        let restartedSummary = try XCTUnwrap(
            agentActivityTurnSummaries(restarted.agentActivity).first)
        XCTAssertTrue(restartedSummary.isTerminal)
        XCTAssertFalse(appKitHarnessTraceSpans(
            records: restarted.agentActivity,
            summary: restartedSummary).contains(where: \.isOpen))

        let repairedCount = restarted.agentActivity.count
        XCTAssertFalse(ConversationStore.healStaleState(&restarted))
        XCTAssertEqual(restarted.agentActivity.count, repairedCount)
    }

    // Regression: FR-90 added the non-optional `SubagentRun.toolEvents` (default []). Swift's
    // synthesized Decodable ignores defaults, so a pre-0.11.7 subagent (no `toolEvents` key) threw
    // keyNotFound and — decoding inside the Conversation graph — quarantined the WHOLE conversation.
    func testSubagentRunDecodesWhenToolEventsKeyMissing() throws {
        let json = #"{"key":"tool-1","subagentType":"Explore","task":"search","status":"stopped","durationMs":7,"startedAt":"2026-07-21T18:37:04.000Z"}"#
        let sub = try ConversationStore.makeDecoder().decode(SubagentRun.self, from: Data(json.utf8))
        XCTAssertEqual(sub.key, "tool-1")
        XCTAssertEqual(sub.subagentType, "Explore")
        XCTAssertEqual(sub.toolEvents, [])
        XCTAssertEqual(sub.status, .stopped)
        XCTAssertEqual(sub.durationMs, 7)
    }

    // End-to-end: a full sidecar whose subagent predates `toolEvents` must LOAD, not be quarantined.
    func testLegacySubagentSidecarWithoutToolEventsStillLoads() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let directory = base.appendingPathComponent("conversations", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        var conversation = Conversation(
            title: "Legacy", cwd: "/tmp", sdkSessionId: nil,
            messages: [TranscriptEntry(kind: .user, text: "Delegate please")],
            updatedAt: Date())
        conversation.subagents = [
            "tool-1": SubagentRun(key: "tool-1", subagentType: "Explore", task: "search")]

        // Encode with the store's own coder, then strip `toolEvents` to mimic a pre-0.11.7 sidecar.
        var json = String(data: try ConversationStore.makeEncoder().encode(conversation), encoding: .utf8)!
        XCTAssertTrue(json.contains("\"toolEvents\""))
        json = json.replacingOccurrences(
            of: ",?\"toolEvents\":\\[\\]", with: "", options: .regularExpression)
        XCTAssertFalse(json.contains("\"toolEvents\""), "test setup must remove the toolEvents key")
        try Data(json.utf8).write(
            to: directory.appendingPathComponent("\(conversation.id.uuidString).json"))

        let store = ConversationStore(appSupportBaseOverride: base, watchesDirectory: false)
        let loaded = store.conversation(conversation.id)
        XCTAssertNotNil(loaded, "legacy subagent sidecar must load, not be quarantined")
        XCTAssertEqual(loaded?.subagents["tool-1"]?.subagentType, "Explore")
        XCTAssertEqual(loaded?.subagents["tool-1"]?.toolEvents, [])
    }

    // Backstop: even a single structurally-broken delegate row must not drop the conversation.
    func testConversationSurvivesOneUndecodableSubagent() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let directory = base.appendingPathComponent("conversations", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        var conversation = Conversation(
            title: "Mixed", cwd: "/tmp", sdkSessionId: nil,
            messages: [TranscriptEntry(kind: .user, text: "Delegate please")],
            updatedAt: Date())
        conversation.subagents = [
            "tool-1": SubagentRun(key: "tool-1", subagentType: "Explore", task: "search")]

        var json = String(data: try ConversationStore.makeEncoder().encode(conversation), encoding: .utf8)!
        // Splice a garbage sibling with no required keys — its SubagentRun decode must fail.
        json = json.replacingOccurrences(
            of: "\"subagents\":{", with: "\"subagents\":{\"broken\":{\"note\":\"no required keys\"},")
        try Data(json.utf8).write(
            to: directory.appendingPathComponent("\(conversation.id.uuidString).json"))

        let store = ConversationStore(appSupportBaseOverride: base, watchesDirectory: false)
        let loaded = store.conversation(conversation.id)
        XCTAssertNotNil(loaded, "a bad delegate row must not quarantine the conversation")
        XCTAssertEqual(loaded?.subagents.count, 1)
        XCTAssertNotNil(loaded?.subagents["tool-1"])
        XCTAssertNil(loaded?.subagents["broken"])
    }

    func testCancelledGuidanceIsRemovedFromRecoveredTranscript() {
        var cancelled = TranscriptEntry(kind: .user, text: "Never mind")
        cancelled.guidanceState = .cancelled
        cancelled.guidanceFailureReason = "The turn finished before guidance could be delivered."
        var delivered = TranscriptEntry(kind: .user, text: "Keep this")
        delivered.guidanceState = .delivered
        var conversation = Conversation(
            title: "Recovery", cwd: "/tmp", sdkSessionId: nil,
            messages: [cancelled, delivered], updatedAt: Date())

        XCTAssertTrue(ConversationStore.healStaleState(&conversation))
        XCTAssertEqual(conversation.messages.map(\.id), [delivered.id])
        XCTAssertTrue(conversation.queuedPrompts.isEmpty)
    }

    // MARK: Deleting a conversation that does not live under its canonical filename

    /// Writes a conversation twice: once as `<id>.json` and once under `name`, with the second copy
    /// newer so load()'s dedupe keeps it and discards the canonical file.
    private func seedDuplicateSidecars(
        in directory: URL, nonCanonicalName name: String
    ) throws -> Conversation {
        let conversation = Conversation(
            title: "Older", cwd: "/tmp", sdkSessionId: nil,
            messages: [TranscriptEntry(kind: .user, text: "Real content")],
            updatedAt: Date(timeIntervalSince1970: 1_000_000))
        var newer = conversation
        newer.title = "Newer twin"
        newer.updatedAt = Date(timeIntervalSince1970: 2_000_000)

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(conversation)
            .write(to: directory.appendingPathComponent("\(conversation.id.uuidString).json"))
        try encoder.encode(newer).write(to: directory.appendingPathComponent(name))
        return newer
    }

    /// The resurrect-after-delete case. A duplicate sidecar (Finder's "… copy.json", a restored
    /// backup, or an external writer) that is NEWER wins the load-time dedupe, and the canonical
    /// file is removed as the loser — so from then on the conversation lives only under a name
    /// `deleteFile` never looked at. Deleting it removed the row but left the bytes, and the next
    /// launch read them straight back in: a conversation the user deleted, returning forever.
    func testDeletingAConversationRemovesTheFileItActuallyLivesIn() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let directory = base.appendingPathComponent("conversations", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let duplicate = "duplicate copy.json"
        let conversation = try seedDuplicateSidecars(in: directory, nonCanonicalName: duplicate)

        let store = ConversationStore(appSupportBaseOverride: base, watchesDirectory: false)
        XCTAssertEqual(store.conversations.filter { $0.id == conversation.id }.count, 1,
                       "the duplicate must load as ONE row")
        XCTAssertEqual(store.conversation(conversation.id)?.title, "Newer twin")

        store.remove(conversation.id)
        store.flushSaves()

        XCTAssertFalse(
            FileManager.default.fileExists(atPath: directory.appendingPathComponent(duplicate).path),
            "the file the conversation actually lived in must be deleted")

        // The real proof: a fresh store over the same directory is exactly what the next launch does.
        let relaunched = ConversationStore(appSupportBaseOverride: base, watchesDirectory: false)
        XCTAssertFalse(relaunched.contains(conversation.id),
                       "a deleted conversation must not come back after relaunch")
    }

    /// The same deletion, seen by the directory watcher's adopt pass rather than by a relaunch.
    /// `deleteFile` runs behind the save queue, so the file can still be on disk when the watcher
    /// looks — and adoption reads any id it does not already hold. Without a tombstone the delete
    /// undoes itself while the user is still looking at the window.
    func testAdoptionDoesNotResurrectAConversationTheUserJustDeleted() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let directory = base.appendingPathComponent("conversations", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let conversation = try seedDuplicateSidecars(in: directory, nonCanonicalName: "external.json")

        let store = ConversationStore(appSupportBaseOverride: base, watchesDirectory: false)
        store.remove(conversation.id)
        // Re-create the file underneath the store, standing in for the delete not having landed yet.
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(conversation)
            .write(to: directory.appendingPathComponent("external.json"))

        store.adoptExternalConversationsForTesting()

        XCTAssertFalse(store.contains(conversation.id),
                       "the watcher must not read back a conversation the user deleted")
    }

    func testCanonicalSaveSupersedesStaleNoncanonicalHydrationSource() async throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let directory = base.appendingPathComponent("conversations", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let conversation = try seedDuplicateSidecars(
            in: directory, nonCanonicalName: "newer copy.json")
        let store = ConversationStore(
            appSupportBaseOverride: base,
            watchesDirectory: false,
            residencyMode: .boundedAfterRecovery)
        await awaitReady(store)
        for _ in 0..<10_000 {
            if store.activeResidencyMode == .boundedAfterRecovery { break }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTAssertEqual(store.activeResidencyMode, .boundedAfterRecovery)
        XCTAssertEqual(store.residentConversation(conversation.id)?.title, "Newer twin")

        store.update(conversation.id) {
            $0.title = "Canonical winner"
            $0.updatedAt = Date(timeIntervalSince1970: 3_000_000)
        }
        store.flushSaves()
        for _ in 0..<1_000 {
            await Task.yield()
            store.trimResidencyIfNeeded(evictAllEligible: true)
            if store.residentConversation(conversation.id) == nil { break }
        }
        XCTAssertNil(
            store.residentConversation(conversation.id),
            "the saved record must become clean and evictable before testing its hydration source")

        let hydrated = try await withCheckedThrowingContinuation { continuation in
            store.acquireConversation(conversation.id) { continuation.resume(with: $0) }
        }
        XCTAssertEqual(
            hydrated.title, "Canonical winner",
            "hydration must follow the generation published by the canonical save, not the stale "
                + "load-time duplicate")
    }

    // MARK: - P0 persistence hardening (visible failures, coalescing, commit-before-send)

    func testArmedTriggerThrottleStampIsNotPersisted() throws {
        var conversation = Conversation(
            title: "Waiting", cwd: "/tmp", sdkSessionId: nil,
            messages: [TranscriptEntry(kind: .user, text: "wait for the build")],
            updatedAt: Date())
        var trigger = ArmedTrigger(
            note: "waiting for the build", check: "true", deadline: nil,
            armedAt: Date(), expiresAt: Date().addingTimeInterval(3600))
        trigger.lastCheckedAt = Date()
        conversation.armedTrigger = trigger

        let json = String(
            data: try ConversationStore.makeEncoder().encode(conversation), encoding: .utf8)!
        XCTAssertFalse(
            json.contains("lastCheckedAt"),
            "the poll throttle is runtime-only; persisting it rewrote the whole sidecar per poll")

        // A sidecar written by an older build still carries the key; it must decode (ignored).
        let legacy = json.replacingOccurrences(
            of: "\"armedAt\"",
            with: "\"lastCheckedAt\":\"2026-08-02T09:00:00.000Z\",\"armedAt\"")
        let decoded = try ConversationStore.makeDecoder().decode(
            Conversation.self, from: Data(legacy.utf8))
        XCTAssertNotNil(decoded.armedTrigger)
        XCTAssertNil(decoded.armedTrigger?.lastCheckedAt)
    }

    func testSaveCoalescingStagesNewestSnapshotUnderOneDrain() {
        let state = ConversationSaveState()
        var conversation = Conversation(
            title: "One", cwd: "", sdkSessionId: nil, messages: [], updatedAt: Date())
        XCTAssertTrue(
            state.stage(ConversationSaveSnapshot(conversation: conversation, revision: 1)),
            "first stage must request a drain")
        conversation.title = "Two"
        XCTAssertFalse(
            state.stage(ConversationSaveSnapshot(conversation: conversation, revision: 2)),
            "a staged burst rides the already-queued drain")
        conversation.title = "Three"
        XCTAssertFalse(state.stage(ConversationSaveSnapshot(conversation: conversation, revision: 3)))
        XCTAssertEqual(
            state.take(conversation.id)?.conversation.title, "Three",
            "the drain writes the newest snapshot, not the one that queued it")
        XCTAssertNil(state.take(conversation.id), "one queued drain gets exactly one snapshot")
        XCTAssertTrue(
            state.stage(ConversationSaveSnapshot(conversation: conversation, revision: 4)),
            "after a drain has taken its snapshot, the next mutation needs a fresh drain")
        state.cancel(conversation.id)
        XCTAssertNil(state.take(conversation.id), "cancel drops the undrained snapshot")
    }

    func testBurstOfUpdatesPersistsFinalState() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let store = ConversationStore(appSupportBaseOverride: base, watchesDirectory: false)
        let conversation = Conversation(
            title: "Burst", cwd: "/tmp", sdkSessionId: nil,
            messages: [TranscriptEntry(kind: .user, text: "hello")], updatedAt: Date())
        store.upsert(conversation)
        for i in 1...50 {
            store.update(conversation.id) { $0.title = "Burst \(i)" }
        }
        store.flushSaves()
        let url = base.appendingPathComponent("conversations", isDirectory: true)
            .appendingPathComponent("\(conversation.id.uuidString).json")
        let onDisk = try ConversationStore.makeDecoder().decode(
            Conversation.self, from: Data(contentsOf: url))
        XCTAssertEqual(onDisk.title, "Burst 50", "the final state must be what survives")
        XCTAssertGreaterThanOrEqual(store.completedDiskWrites, 1)
        XCTAssertLessThanOrEqual(
            store.completedDiskWrites, 51,
            "writes can never exceed mutations; coalescing typically collapses far below this")
    }

    func testFailedSaveSurfacesErrorAndRetryRecovers() async throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let store = ConversationStore(appSupportBaseOverride: base, watchesDirectory: false)
        let conversation = Conversation(
            title: "Fragile", cwd: "/tmp", sdkSessionId: nil,
            messages: [TranscriptEntry(kind: .user, text: "keep me")], updatedAt: Date())
        store.upsert(conversation)
        store.flushSaves()

        let directory = base.appendingPathComponent("conversations", isDirectory: true)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o555], ofItemAtPath: directory.path)
        store.update(conversation.id) { $0.title = "Must not vanish silently" }
        store.flushSaves()
        try await waitUntil("the failed save surfaces a visible error") {
            store.persistenceError != nil
        }

        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: directory.path)
        store.retryFailedSaves()
        store.flushSaves()
        try await waitUntil("a successful retry clears the error") {
            store.persistenceError == nil
        }
        let url = directory.appendingPathComponent("\(conversation.id.uuidString).json")
        let onDisk = try ConversationStore.makeDecoder().decode(
            Conversation.self, from: Data(contentsOf: url))
        XCTAssertEqual(
            onDisk.title, "Must not vanish silently",
            "retry must write the mutation that originally failed")
    }

    func testPendingTurnPromptHealsToQueueFront() {
        var conversation = Conversation(
            title: "Crash", cwd: "/tmp", sdkSessionId: nil,
            messages: [TranscriptEntry(kind: .user, text: "earlier turn")], updatedAt: Date())
        conversation.queuedPrompts = ["later work"]
        conversation.pendingTurnPrompt = "the words that were in flight"

        XCTAssertTrue(ConversationStore.healStaleState(&conversation))
        XCTAssertNil(conversation.pendingTurnPrompt)
        XCTAssertEqual(
            conversation.queuedPrompts, ["the words that were in flight", "later work"],
            "a crash-interrupted send recovers to the head of the queue")
    }

    func testPendingTurnPromptDoesNotDuplicateALandedEntry() {
        var conversation = Conversation(
            title: "Landed", cwd: "/tmp", sdkSessionId: nil,
            messages: [TranscriptEntry(kind: .user, text: "the words that were in flight")],
            updatedAt: Date())
        conversation.pendingTurnPrompt = "the words that were in flight"

        XCTAssertTrue(ConversationStore.healStaleState(&conversation))
        XCTAssertNil(conversation.pendingTurnPrompt)
        XCTAssertTrue(
            conversation.queuedPrompts.isEmpty,
            "when the durable transcript already ends with this text, queueing it again would show it twice")
    }

    func testPendingTurnPromptDoesNotCollapseAnIdenticalQueuedAction() {
        var conversation = Conversation(
            title: "Two identical actions", cwd: "/tmp", sdkSessionId: nil,
            messages: [TranscriptEntry(kind: .assistant, text: "Ready")],
            updatedAt: Date(),
            queuedPrompts: ["do this"])
        conversation.pendingTurnPrompt = "do this"

        XCTAssertTrue(ConversationStore.healStaleState(&conversation))
        XCTAssertNil(conversation.pendingTurnPrompt)
        XCTAssertEqual(conversation.queuedPrompts, ["do this", "do this"])
    }

    func testPendingTurnCrashHealingPreservesSuggestionOnlyForSyntheticWait() {
        let root = TranscriptEntry(kind: .user, text: "Finish the durable suggestion path")
        let assistant = TranscriptEntry(kind: .assistant, text: "The build is ready to install.")
        let suggestion = ConversationSuggestedPrompt(
            text: "Install the build and continue.",
            source: .onDevice,
            rootPromptEntryID: root.id,
            assistantEntryID: assistant.id)

        var synthetic = Conversation(
            title: "Synthetic resume", cwd: "/tmp", sdkSessionId: nil,
            messages: [root, assistant], updatedAt: Date(), suggestedPrompt: suggestion)
        synthetic.pendingTurnPrompt = "[wait-mode] The build was installed. Continue where you left off."

        XCTAssertTrue(ConversationStore.healStaleState(&synthetic))
        XCTAssertEqual(synthetic.suggestedPrompt, suggestion)

        var genuine = Conversation(
            title: "Genuine send", cwd: "/tmp", sdkSessionId: nil,
            messages: [root, assistant], updatedAt: Date(), suggestedPrompt: suggestion)
        genuine.pendingTurnPrompt = "Continue with the next task."

        XCTAssertTrue(ConversationStore.healStaleState(&genuine))
        XCTAssertNil(genuine.suggestedPrompt)
    }

    func testFirstSendCrashSidecarSurvivesLoadPaused() throws {
        // A first send in a brand-new conversation persists ONLY pendingTurnPrompt before the
        // provider request. That sidecar must load — not be swept as an empty placeholder — with
        // the words recovered into a paused queue that never auto-sends.
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let directory = base.appendingPathComponent("conversations", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        var conversation = Conversation(
            title: "New Conversation", cwd: "", sdkSessionId: nil, messages: [], updatedAt: Date())
        conversation.pendingTurnPrompt = "first words ever typed here"
        try ConversationStore.makeEncoder().encode(conversation).write(
            to: directory.appendingPathComponent("\(conversation.id.uuidString).json"))

        let store = ConversationStore(appSupportBaseOverride: base, watchesDirectory: false)
        let loaded = store.conversation(conversation.id)
        XCTAssertNotNil(
            loaded,
            "pendingTurnPrompt alone is durable content; the empty-placeholder sweep must not delete it")
        XCTAssertEqual(loaded?.queuedPrompts, ["first words ever typed here"])
        XCTAssertNil(loaded?.pendingTurnPrompt)
        XCTAssertTrue(
            store.isQueuePaused(conversation.id),
            "recovered work is crash evidence, never permission to auto-send")
    }

    // MARK: - File-first interaction response publication

    func testAwaitingPersistenceReleasesOnlyAfterSelectedResponseIsOnDisk() async throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let store = ConversationStore(appSupportBaseOverride: base, watchesDirectory: false)
        var request = TranscriptEntry(kind: .permission, text: "Allow the command?")
        request.permissionId = "permission-1"
        let conversation = Conversation(
            title: "Guarded", cwd: "/tmp", sdkSessionId: nil,
            messages: [request], updatedAt: Date())
        store.upsert(conversation)
        store.flushSaves()

        let url = base.appendingPathComponent("conversations", isDirectory: true)
            .appendingPathComponent("\(conversation.id.uuidString).json")
        var completionResult: Bool?
        var statusObservedAtCompletion: InteractionResponseStatus?
        var allowedObservedAtCompletion: Bool?
        store.updateAwaitingPersistence(conversation.id, { value in
            value.messages[0].permAllowed = true
            value.messages[0].permAlways = false
            value.messages[0].interactionResponseStatus = .selected
            value.messages[0].interactionResponseObservedAt = Date()
        }, completion: { succeeded in
            completionResult = succeeded
            let onDisk = try? ConversationStore.makeDecoder().decode(
                Conversation.self, from: Data(contentsOf: url))
            statusObservedAtCompletion = onDisk?.messages.first?.interactionResponseStatus
            allowedObservedAtCompletion = onDisk?.messages.first?.permAllowed
        })

        store.flushSaves()
        try await waitUntil("the publication callback runs") { completionResult != nil }
        XCTAssertEqual(completionResult, true)
        XCTAssertEqual(
            statusObservedAtCompletion, .selected,
            "the callback that releases the provider must observe the selected response on disk")
        XCTAssertEqual(allowedObservedAtCompletion, true)
    }

    func testAwaitingPersistenceFailureDoesNotReleaseGuardedSideEffect() async throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let store = ConversationStore(appSupportBaseOverride: base, watchesDirectory: false)
        var request = TranscriptEntry(kind: .permission, text: "Allow the command?")
        request.permissionId = "permission-2"
        let conversation = Conversation(
            title: "Guarded", cwd: "/tmp", sdkSessionId: nil,
            messages: [request], updatedAt: Date())
        store.upsert(conversation)
        store.flushSaves()

        let directory = base.appendingPathComponent("conversations", isDirectory: true)
        let url = directory.appendingPathComponent("\(conversation.id.uuidString).json")
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o555], ofItemAtPath: directory.path)
        var completionResult: Bool?
        var releasedGuardedSideEffect = false
        store.updateAwaitingPersistence(conversation.id, { value in
            value.messages[0].permAllowed = true
            value.messages[0].interactionResponseStatus = .selected
        }, completion: { succeeded in
            completionResult = succeeded
            if succeeded { releasedGuardedSideEffect = true }
        })

        store.flushSaves()
        try await waitUntil("the failed publication callback runs") { completionResult != nil }
        XCTAssertEqual(completionResult, false)
        XCTAssertFalse(
            releasedGuardedSideEffect,
            "a failed file publication must never release the guarded provider response")
        let onDisk = try ConversationStore.makeDecoder().decode(
            Conversation.self, from: Data(contentsOf: url))
        XCTAssertNil(onDisk.messages.first?.interactionResponseStatus)
        XCTAssertFalse(onDisk.messages.first?.permAllowed ?? true)

        // Restore permissions so deferred cleanup and any diagnostic retry remain recoverable.
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: directory.path)
    }

    func testFreshRetryPersistenceFailureRetainsOneVisiblePausedPrompt() async throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let store = ConversationStore(appSupportBaseOverride: base, watchesDirectory: false)
        let selection = ModelSelection(
            access: .claudeVertex,
            modelID: "claude-opus-4-8[1m]")
        let prior = TranscriptEntry(kind: .assistant, text: "Retained answer")
        let prompt = TranscriptEntry(kind: .user, text: "Retry me exactly once")
        var failure = TranscriptEntry(kind: .system, text: "error: No response")
        failure.providerFailure = try XCTUnwrap(ProviderFailure.from(event: [
            "type": "error",
            "errorKind": "network",
            "provider": "anthropic",
            "access": "claude_vertex",
            "message": "No response",
            "providerError": [
                "providerType": "provider_no_output",
                "code": "no_output_after_fresh_replay",
                "diagnosticCode": "claude_no_output_after_fresh_replay",
                "resumed": true,
                "noProviderWork": true,
                "freshReplayAttempted": true,
            ],
        ], authoritativeAccess: .claudeVertex))
        failure.providerFailurePromptID = prompt.id
        let conversation = Conversation(
            title: "Failed retry persistence",
            cwd: "/tmp",
            sdkSessionId: "wedged-session",
            modelSelection: selection,
            messages: [prior, prompt, failure],
            updatedAt: Date())
        store.upsert(conversation)
        store.flushSaves()

        let directory = base.appendingPathComponent("conversations", isDirectory: true)
        let url = directory.appendingPathComponent("\(conversation.id.uuidString).json")
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o555], ofItemAtPath: directory.path)
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o755], ofItemAtPath: directory.path)
        }

        var completionResult: Bool?
        var applied = false
        _ = store.updateAwaitingPersistence(conversation.id, { value in
            applied = AgentBridge.stageFreshSessionProviderFailureRetry(
                for: failure,
                selection: selection,
                in: &value) != nil
        }) { succeeded in
            completionResult = succeeded
            guard applied, !succeeded else { return }
            AgentBridge.quarantineCommittedFreshRetryPrompt(
                prompt.text,
                conversationID: conversation.id,
                store: store)
        }

        store.flushSaves()
        try await waitUntil("the failed retry persistence callback runs") {
            completionResult != nil
        }
        XCTAssertEqual(completionResult, false)
        let live = try XCTUnwrap(store.conversation(conversation.id))
        XCTAssertEqual(live.messages.map(\.id), [prior.id])
        XCTAssertNil(live.sdkSessionId)
        XCTAssertNil(live.pendingTurnPrompt)
        XCTAssertEqual(live.queuedPrompts, [prompt.text])
        XCTAssertTrue(store.isQueuePaused(conversation.id))
        let onDisk = try ConversationStore.makeDecoder().decode(
            Conversation.self,
            from: Data(contentsOf: url))
        XCTAssertEqual(onDisk.messages.last?.id, failure.id)
        XCTAssertTrue(
            onDisk.queuedPrompts.isEmpty,
            "failed writes must not claim that the visible recovery queue reached disk")
    }

    func testNewerCoalescedPublicationSatisfiesEveryEarlierWaiter() async throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let store = ConversationStore(appSupportBaseOverride: base, watchesDirectory: false)
        let conversation = Conversation(
            title: "Original", cwd: "/tmp", sdkSessionId: nil,
            messages: [TranscriptEntry(kind: .user, text: "hello")], updatedAt: Date())
        store.upsert(conversation)
        store.flushSaves()

        var results: [String: Bool] = [:]
        store.updateAwaitingPersistence(conversation.id, { $0.title = "First" }) {
            results["first"] = $0
        }
        store.updateAwaitingPersistence(conversation.id, { $0.title = "Newest" }) {
            results["newest"] = $0
        }

        store.flushSaves()
        try await waitUntil("both publication waiters resolve") { results.count == 2 }
        XCTAssertEqual(results, ["first": true, "newest": true])
        let url = base.appendingPathComponent("conversations", isDirectory: true)
            .appendingPathComponent("\(conversation.id.uuidString).json")
        let onDisk = try ConversationStore.makeDecoder().decode(
            Conversation.self, from: Data(contentsOf: url))
        XCTAssertEqual(onDisk.title, "Newest")
    }

    func testPublishedSnapshotDoesNotReacquireNewerProvisionalLiveState() async throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let store = ConversationStore(appSupportBaseOverride: base, watchesDirectory: false)
        let conversation = Conversation(
            title: "Original", cwd: "/tmp", sdkSessionId: nil,
            messages: [TranscriptEntry(kind: .user, text: "hello")], updatedAt: Date())
        store.upsert(conversation)
        store.flushSaves()

        // Keep this entire sequence on the main actor. The disk queue may finish in parallel, but
        // `finishSave` cannot resolve its callback until this frame yields, so the live-only advance
        // deterministically happens between registration and publication acknowledgement.
        store.update(conversation.id) { $0.title = "Published revision" }
        var published: PublishedConversationSnapshot?
        store.awaitPublishedSnapshot(conversation.id) { published = $0 }
        store.updateLive(conversation.id) { $0.title = "Newer provisional revision" }

        store.flushSaves()
        try await waitUntil("the exact published snapshot callback runs") { published != nil }

        let url = base.appendingPathComponent("conversations", isDirectory: true)
            .appendingPathComponent("\(conversation.id.uuidString).json")
        let onDisk = try ConversationStore.makeDecoder().decode(
            Conversation.self, from: Data(contentsOf: url))
        XCTAssertEqual(published?.conversation.title, "Published revision")
        XCTAssertEqual(
            published?.conversation.title, onDisk.title,
            "export acknowledgement must return the value that actually crossed the file boundary")
        XCTAssertEqual(
            store.conversation(conversation.id)?.title, "Newer provisional revision",
            "the regression requires resident state to advance beyond the published snapshot")
    }

    func testAwaitPublishedSnapshotPublishesAnOtherwiseLiveOnlyRevision() async throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let store = ConversationStore(appSupportBaseOverride: base, watchesDirectory: false)
        let conversation = Conversation(
            title: "Original", cwd: "/tmp", sdkSessionId: nil,
            messages: [TranscriptEntry(kind: .user, text: "hello")], updatedAt: Date())
        store.upsert(conversation)
        store.flushSaves()

        store.updateLive(conversation.id) { $0.title = "Live-only revision" }
        var published: PublishedConversationSnapshot?
        store.awaitPublishedSnapshot(conversation.id) { published = $0 }

        store.flushSaves()
        try await waitUntil("the live-only revision is published") { published != nil }
        let url = base.appendingPathComponent("conversations", isDirectory: true)
            .appendingPathComponent("\(conversation.id.uuidString).json")
        let onDisk = try ConversationStore.makeDecoder().decode(
            Conversation.self, from: Data(contentsOf: url))
        XCTAssertEqual(published?.conversation.title, "Live-only revision")
        XCTAssertEqual(onDisk.title, "Live-only revision")
    }

    func testDeletingConversationRejectsPendingPublishedSnapshotExactlyOnce() async throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let store = ConversationStore(appSupportBaseOverride: base, watchesDirectory: false)
        let conversation = Conversation(
            title: "Delete while exporting", cwd: "/tmp", sdkSessionId: nil,
            messages: [TranscriptEntry(kind: .user, text: "hello")], updatedAt: Date())
        store.upsert(conversation)
        store.flushSaves()

        store.update(conversation.id) { $0.title = "Pending publication" }
        var completionResults: [PublishedConversationSnapshot?] = []
        store.awaitPublishedSnapshot(conversation.id) { completionResults.append($0) }
        store.remove(conversation.id, permanently: true)

        XCTAssertEqual(completionResults.count, 1)
        XCTAssertNil(completionResults[0])
        store.flushSaves()
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(
            completionResults.count, 1,
            "a late write completion must not resolve a deleted export snapshot twice")
    }

    func testNewerQueuedSuccessSupersedesAnOlderFailedPublication() async throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let store = ConversationStore(appSupportBaseOverride: base, watchesDirectory: false)
        let conversation = Conversation(
            title: "Original", cwd: "/tmp", sdkSessionId: nil,
            messages: [TranscriptEntry(kind: .user, text: "hello")], updatedAt: Date())
        store.upsert(conversation)
        store.flushSaves()

        let directory = base.appendingPathComponent("conversations", isDirectory: true)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o555], ofItemAtPath: directory.path)
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o755], ofItemAtPath: directory.path)
        }
        var results: [String: Bool] = [:]
        store.updateAwaitingPersistence(conversation.id, { $0.title = "Older" }) {
            results["older"] = $0
        }
        // The first attempt is now inside its bounded retry loop. Stage a newer snapshot while its
        // drain owns the queue; that next snapshot contains and therefore supersedes the first.
        try await Task.sleep(nanoseconds: 20_000_000)
        store.updateAwaitingPersistence(conversation.id, { $0.title = "Recovered by newer" }) {
            results["newer"] = $0
        }

        try await waitUntil("the older write exhausts retries") {
            store.persistenceError != nil
        }
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: directory.path)
        store.flushSaves()
        try await waitUntil("the newer publication resolves both waiters") { results.count == 2 }

        XCTAssertEqual(
            results, ["older": true, "newer": true],
            "a queued newer publication contains the older mutation and must release both waiters")
        let url = directory.appendingPathComponent("\(conversation.id.uuidString).json")
        let onDisk = try ConversationStore.makeDecoder().decode(
            Conversation.self, from: Data(contentsOf: url))
        XCTAssertEqual(onDisk.title, "Recovered by newer")
    }

    func testDeletingConversationRejectsPendingPublicationExactlyOnce() async throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let store = ConversationStore(appSupportBaseOverride: base, watchesDirectory: false)
        let conversation = Conversation(
            title: "Delete while saving", cwd: "/tmp", sdkSessionId: nil,
            messages: [TranscriptEntry(kind: .permission, text: "Run?")], updatedAt: Date())
        store.upsert(conversation)
        store.flushSaves()

        var completionResults: [Bool] = []
        store.updateAwaitingPersistence(conversation.id, { value in
            value.messages[0].interactionResponseStatus = .selected
        }, completion: { completionResults.append($0) })
        store.remove(conversation.id, permanently: true)

        XCTAssertEqual(
            completionResults, [false],
            "deleting the record must synchronously reject, never strand, its guarded response")
        store.flushSaves()
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(
            completionResults, [false],
            "a late save completion must not release or resolve the deleted response twice")
    }

    // MARK: - Asynchronous launch load (the launch-paint slice)

    private func awaitReady(_ store: ConversationStore) async {
        await withCheckedContinuation { continuation in
            store.whenReady { continuation.resume() }
        }
    }

    func testAsynchronousLoadPublishesAfterReady() async throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let directory = base.appendingPathComponent("conversations", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let seeded = Conversation(
            title: "On disk", cwd: "", sdkSessionId: nil,
            messages: [TranscriptEntry(kind: .user, text: "hello")], updatedAt: Date())
        try ConversationStore.makeEncoder().encode(seeded).write(
            to: directory.appendingPathComponent("\(seeded.id.uuidString).json"))

        let store = ConversationStore(
            appSupportBaseOverride: base, watchesDirectory: false, loadsAsynchronously: true)
        // Init returns before the background decode lands: not ready, nothing published.
        XCTAssertFalse(store.isReady)
        XCTAssertTrue(store.conversations.isEmpty)
        var launchResolutionReported = false
        store.whenLaunchInventoryResolved { launchResolutionReported = true }
        XCTAssertFalse(launchResolutionReported)

        await awaitReady(store)
        XCTAssertTrue(store.isReady)
        XCTAssertTrue(launchResolutionReported)
        XCTAssertEqual(store.conversations.map(\.id), [seeded.id])

        // Once ready, whenReady runs inline — the ordering every synchronous consumer relies on.
        var ranInline = false
        store.whenReady { ranInline = true }
        XCTAssertTrue(ranInline)
    }

    func testAsyncPublicationAdvancesAProvisionalOrdinalAboveRetainedEvidence() async throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let directory = base.appendingPathComponent("conversations", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var retained = TranscriptEntry(kind: .assistant, text: "retained")
        retained.captureOrdinal = 400
        let seeded = Conversation(
            title: "Chronology on disk", cwd: "", sdkSessionId: nil,
            messages: [retained], updatedAt: Date())
        try ConversationStore.makeEncoder().encode(seeded).write(
            to: directory.appendingPathComponent("\(seeded.id.uuidString).json"))

        let store = ConversationStore(
            appSupportBaseOverride: base, watchesDirectory: false, loadsAsynchronously: true)
        XCTAssertFalse(store.isReady)
        XCTAssertEqual(
            store.nextCaptureOrdinal(for: seeded.id),
            1,
            "an unknown id may be provisionally reserved while launch is still decoding")

        await awaitReady(store)

        XCTAssertEqual(
            store.nextCaptureOrdinal(for: seeded.id),
            401,
            "publication must still seed retained evidence even when the numeric cache is non-nil")
        XCTAssertEqual(
            store.captureOrdinalSeedScanCount,
            0,
            "Legacy launch computes retained maxima on its background scan, not the MainActor")
    }

    func testConversationCreatedDuringAsyncLoadSurvivesTheMerge() async throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let directory = base.appendingPathComponent("conversations", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let seeded = Conversation(
            title: "From last session", cwd: "", sdkSessionId: nil,
            messages: [TranscriptEntry(kind: .user, text: "old work")], updatedAt: Date())
        try ConversationStore.makeEncoder().encode(seeded).write(
            to: directory.appendingPathComponent("\(seeded.id.uuidString).json"))

        let store = ConversationStore(
            appSupportBaseOverride: base, watchesDirectory: false, loadsAsynchronously: true)
        // The apply hop is a main-actor task; it cannot run until this test yields, so this
        // upsert deterministically lands BEFORE the load result — the ⌘N-during-launch case.
        let typed = Conversation(
            title: "Typed during launch", cwd: "", sdkSessionId: nil,
            messages: [TranscriptEntry(kind: .user, text: "new words")], updatedAt: Date())
        store.upsert(typed)

        await awaitReady(store)
        XCTAssertEqual(
            Set(store.conversations.map(\.id)), [seeded.id, typed.id],
            "the disk snapshot must merge with, never wipe, what the user created mid-load")
    }

    func testLaunchSummariesFollowCanonicalOrder() async throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let projections = ConversationProjectionStore(appSupportBase: base)
        var older = Conversation(
            title: "Older favorite", cwd: "", sdkSessionId: nil,
            messages: [TranscriptEntry(kind: .user, text: "a")],
            updatedAt: Date(timeIntervalSinceNow: -3600))
        older.favorite = true
        let newer = Conversation(
            title: "Newer plain", cwd: "", sdkSessionId: nil,
            messages: [TranscriptEntry(kind: .user, text: "b")], updatedAt: Date())
        projections.index(older)
        projections.index(newer)
        projections.drain()

        let rows: [ConversationProjectionStore.LaunchSummary] =
            await withCheckedContinuation { continuation in
                projections.launchSummaries { continuation.resume(returning: $0) }
            }
        XCTAssertEqual(
            rows.map(\.id), [older.id, newer.id],
            "skeleton order pins favorites first, exactly like the real sidebar, so nothing "
                + "reshuffles when the store takes over")
    }

    private func waitUntil(
        _ what: String,
        timeout: TimeInterval = 5,
        _ condition: () -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline {
                XCTFail("timed out waiting until \(what)")
                return
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
    }
}
