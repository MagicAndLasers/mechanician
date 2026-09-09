import XCTest
@testable import Mechanician

final class WorkflowStoreTests: XCTestCase {
    func testDeliveredGuidancePersistsAsAnOrderedUserMessage() throws {
        var entry = TranscriptEntry(kind: .user, text: "Keep the current layout.")
        entry.guidanceState = .delivered

        let decoded = try JSONDecoder().decode(
            TranscriptEntry.self,
            from: JSONEncoder().encode(entry))

        XCTAssertEqual(decoded.kind, .user)
        XCTAssertEqual(decoded.text, "Keep the current layout.")
        XCTAssertEqual(decoded.guidanceState, .delivered)
    }

    func testFailedGuidanceStateAndReasonPersist() throws {
        var entry = TranscriptEntry(kind: .user, text: "Keep investigating")
        entry.guidanceState = .queued
        entry.guidanceFailureReason = "The provider did not confirm guidance."

        let decoded = try JSONDecoder().decode(
            TranscriptEntry.self,
            from: JSONEncoder().encode(entry))

        XCTAssertEqual(decoded.guidanceState, .queued)
        XCTAssertEqual(decoded.guidanceFailureReason, "The provider did not confirm guidance.")
    }

    @MainActor
    func testQueuedGuidanceRowsMapOldestFirstWithoutDuplicateReuse() {
        // Fallbacks now append in typed order, so the queue matches the transcript order: the first
        // queued copy maps to the older row and the second to the newer, never reusing one row.
        var older = TranscriptEntry(kind: .user, text: "Same prompt")
        older.guidanceState = .queued
        var newer = TranscriptEntry(kind: .user, text: "Same prompt")
        newer.guidanceState = .queued

        XCTAssertEqual(
            AgentBridge.queuedGuidanceEntryIDs(
                prompts: ["Same prompt", "Same prompt"],
                messages: [older, newer]),
            [older.id, newer.id])
    }

    @MainActor
    func testCancellingUndeliveredGuidanceRemovesOnlyItsProvisionalRow() {
        var guidance = TranscriptEntry(kind: .user, text: "Keep the layout")
        guidance.guidanceState = .sending
        var delivered = TranscriptEntry(kind: .user, text: "Use the Mac screenshot")
        delivered.guidanceState = .delivered
        var messages = [guidance, delivered]

        XCTAssertTrue(AgentBridge.removeUndeliveredGuidanceEntry(guidance.id, from: &messages))
        XCTAssertEqual(messages.map(\.id), [delivered.id])
        XCTAssertFalse(AgentBridge.removeUndeliveredGuidanceEntry(delivered.id, from: &messages))
    }

    func testCodexChildLifecycleProducesOneVisibleSubagent() {
        let started = WorkflowUpdate([
            "phase": "started",
            "taskId": "spawn-call",
            "toolUseId": "spawn-call",
            "taskType": "codex_subagent",
            "subagentType": "Codex",
            "description": "Inspect the transcript host",
            "summary": "Reading files",
            "status": "running",
        ])
        var subagents = applySubagentUpdate([:], started)

        XCTAssertEqual(subagents.count, 1)
        XCTAssertEqual(subagents["spawn-call"]?.status, .running)
        XCTAssertEqual(subagents["spawn-call"]?.task, "Inspect the transcript host")
        XCTAssertEqual(runningDelegatedAgentCount(subagents: subagents, workflowRuns: [:]), 1)

        let identified = WorkflowUpdate([
            "phase": "progress",
            "taskId": "child-thread",
            "toolUseId": "spawn-call",
            "taskType": "codex_subagent",
            "subagentType": "Codex",
            "summary": "Running tests",
            "status": "running",
        ])
        subagents = applySubagentUpdate(subagents, identified)

        XCTAssertEqual(subagents.count, 1, "The provisional spawn and real child are one Agents row.")
        XCTAssertEqual(subagents["spawn-call"]?.taskId, "child-thread")
        XCTAssertEqual(subagents["spawn-call"]?.summary, "Running tests")

        let completed = WorkflowUpdate([
            "phase": "notification",
            "taskId": "child-thread",
            "taskType": "codex_subagent",
            "subagentType": "Codex",
            "status": "completed",
        ])
        subagents = applySubagentUpdate(subagents, completed)

        XCTAssertEqual(subagents.count, 1)
        XCTAssertEqual(subagents["spawn-call"]?.status, .completed)
        XCTAssertNotNil(subagents["spawn-call"]?.endedAt)
        XCTAssertEqual(runningDelegatedAgentCount(subagents: subagents, workflowRuns: [:]), 0)
    }

    func testAliasCollapsePreservesHierarchyFromAuthoritativeChildRow() {
        var provisional = SubagentRun(
            key: "spawn-call",
            subagentType: "Codex",
            task: "Inspect cards")
        provisional.status = .running
        var authoritative = SubagentRun(
            key: "child-thread",
            subagentType: "Codex",
            task: "Inspect cards")
        authoritative.taskId = "child-thread"
        authoritative.agentPath = "/root/parent/child"
        authoritative.parentToolUseId = "parent-spawn"
        authoritative.status = .running

        let identified = WorkflowUpdate([
            "phase": "progress",
            "taskId": "child-thread",
            "toolUseId": "spawn-call",
            "taskType": "codex_subagent",
            "subagentType": "Codex",
            "status": "running",
        ])
        let collapsed = applySubagentUpdate(
            [provisional.key: provisional, authoritative.key: authoritative],
            identified)

        XCTAssertEqual(collapsed.count, 1)
        XCTAssertEqual(collapsed["spawn-call"]?.taskId, "child-thread")
        XCTAssertEqual(collapsed["spawn-call"]?.agentPath, "/root/parent/child")
        XCTAssertEqual(collapsed["spawn-call"]?.parentToolUseId, "parent-spawn")
    }

    func testLateNestedAgentToolUseEnrichesExistingLifecycleRowWithoutResettingIt() {
        let startedAt = Date(timeIntervalSince1970: 1_234)
        var lifecycle = SubagentRun(
            key: "tool-child",
            subagentType: "general-purpose",
            task: "Provider lifecycle description")
        lifecycle.taskId = "task-child"
        lifecycle.model = "claude-opus-5"
        lifecycle.status = .completed
        lifecycle.startedAt = startedAt
        lifecycle.endedAt = startedAt.addingTimeInterval(20)
        let parent = SubagentRun(
            key: "tool-parent",
            subagentType: "general-purpose",
            task: "Delegate one child")

        let updated = applySubagentToolUse(
            ["tool-parent": parent, "tool-child": lifecycle],
            toolUseId: "tool-child",
            parentToolUseId: "tool-parent",
            subagentType: "general-purpose",
            task: "Agent call description")

        XCTAssertEqual(updated.count, 2, "the late tool frame enriches rather than duplicates")
        XCTAssertEqual(updated["tool-child"]?.parentToolUseId, "tool-parent")
        XCTAssertEqual(updated["tool-child"]?.taskId, "task-child")
        XCTAssertEqual(updated["tool-child"]?.model, "claude-opus-5")
        XCTAssertEqual(updated["tool-child"]?.status, .completed)
        XCTAssertEqual(updated["tool-child"]?.startedAt, startedAt)
        XCTAssertEqual(
            updated["tool-child"]?.task,
            "Provider lifecycle description",
            "lifecycle copy remains authoritative when it is already populated")
        XCTAssertEqual(subagentForest(updated).map(\.id), ["tool-parent"])
        XCTAssertEqual(
            subagentForest(updated).first?.children.map(\.id),
            ["tool-child"],
            "the AppKit/SwiftUI shared tree projection now indents the nested child")
    }

    func testAgentToolUseStillSeedsALifecycleRowWhenItArrivesFirst() {
        let seeded = applySubagentToolUse(
            [:],
            toolUseId: "tool-child",
            parentToolUseId: "tool-parent",
            subagentType: "Explore",
            task: "Inspect the hierarchy")

        XCTAssertEqual(seeded.count, 1)
        XCTAssertEqual(seeded["tool-child"]?.parentToolUseId, "tool-parent")
        XCTAssertEqual(seeded["tool-child"]?.subagentType, "Explore")
        XCTAssertEqual(seeded["tool-child"]?.task, "Inspect the hierarchy")
        XCTAssertEqual(seeded["tool-child"]?.status, .running)
    }

    func testProviderRootLifecycleDoesNotCreateADelegatedAgent() {
        let root = WorkflowUpdate([
            "phase": "started",
            "taskId": "root-thread",
            "toolUseId": "root-thread",
            "taskType": "codex_subagent",
            "subagentType": "Codex",
            "agentPath": "/root",
            "description": "root",
            "status": "running",
        ])
        XCTAssertTrue(applySubagentUpdate([:], root).isEmpty)

        let child = WorkflowUpdate([
            "phase": "started",
            "taskId": "child-thread",
            "toolUseId": "spawn-call",
            "taskType": "codex_subagent",
            "subagentType": "Codex",
            "agentPath": "/root/child",
            "description": "real child",
            "status": "running",
        ])
        let subagents = applySubagentUpdate([:], child)
        XCTAssertEqual(subagents.count, 1)
        XCTAssertEqual(subagents["spawn-call"]?.agentPath, "/root/child")
        XCTAssertEqual(runningDelegatedAgentCount(subagents: subagents, workflowRuns: [:]), 1)
    }

    func testConversationDecodeHealsPersistedProviderRootPseudoAgent() throws {
        var pseudoRoot = SubagentRun(
            key: "root-thread",
            subagentType: "Codex",
            task: "root",
            startedAt: Date(timeIntervalSince1970: 10))
        pseudoRoot.taskId = "root-task"
        pseudoRoot.agentPath = "/root"
        pseudoRoot.status = .failed
        pseudoRoot.endedAt = Date(timeIntervalSince1970: 20)

        var child = SubagentRun(
            key: "spawn-call",
            subagentType: "Codex",
            task: "real child",
            startedAt: Date(timeIntervalSince1970: 12))
        child.taskId = "child-thread"
        child.agentPath = "/root/child"

        let conversation = Conversation(
            title: "Root migration",
            cwd: "/tmp",
            sdkSessionId: nil,
            messages: [],
            updatedAt: Date(timeIntervalSince1970: 30),
            subagents: [
                "root-storage": pseudoRoot,
                "spawn-call": child,
            ],
            agentActivity: [
                .state(
                    .failed,
                    turnID: "turn",
                    agentID: AgentActivityIdentity.subagent("root-storage"),
                    at: Date(timeIntervalSince1970: 20)),
                .state(
                    .failed,
                    turnID: "turn",
                    agentID: AgentActivityIdentity.subagent("root-thread"),
                    at: Date(timeIntervalSince1970: 20)),
                .state(
                    .failed,
                    turnID: "turn",
                    agentID: AgentActivityIdentity.subagent("root-task"),
                    at: Date(timeIntervalSince1970: 20)),
                .state(
                    .model,
                    turnID: "turn",
                    agentID: AgentActivityIdentity.subagent("spawn-call"),
                    at: Date(timeIntervalSince1970: 21)),
            ])

        let decoded = try JSONDecoder().decode(
            Conversation.self,
            from: JSONEncoder().encode(conversation))

        XCTAssertEqual(decoded.subagents.keys.sorted(), ["spawn-call"])
        XCTAssertEqual(
            decoded.agentActivity.map(\.agentID),
            [AgentActivityIdentity.subagent("spawn-call")])
        XCTAssertTrue(decoded.needsStaleStatePersistence)
    }

    func testSubagentResultPreviewSurvivesLaterUpdates() {
        // resultPreview is captured from the Task tool_result; a later task_* progress/notification
        // update must merge onto the same record without wiping the captured result (FR-90).
        var subs = ["child": SubagentRun(key: "child", subagentType: "Explore", task: "Find X")]
        subs["child"]?.resultPreview = "the full returned result"
        let progress = WorkflowUpdate([
            "phase": "progress", "taskId": "child", "toolUseId": "child",
            "subagentType": "Explore", "summary": "still going", "status": "running",
        ])
        subs = applySubagentUpdate(subs, progress)
        XCTAssertEqual(subs["child"]?.resultPreview, "the full returned result")
        XCTAssertEqual(subs["child"]?.summary, "still going")
    }

    func testSubagentModelPersistsAndOlderRowsDecodeWithoutIt() throws {
        var child = SubagentRun(
            key: "spawn-1",
            subagentType: "Explore",
            task: "Inspect the reducer",
            startedAt: Date(timeIntervalSince1970: 100))
        child.taskId = "task-1"
        child.model = "claude-sonnet-4-5-20250929"

        let decoded = try JSONDecoder().decode(
            SubagentRun.self,
            from: JSONEncoder().encode(child))
        XCTAssertEqual(decoded.model, "claude-sonnet-4-5-20250929")

        let legacy = Data("""
        {"key":"legacy","subagentType":"Explore","task":"Inspect old state",
         "status":"completed","durationMs":1200}
        """.utf8)
        let legacyDecoded = try JSONDecoder().decode(SubagentRun.self, from: legacy)
        XCTAssertNil(legacyDecoded.model)
        XCTAssertEqual(legacyDecoded.status, .completed)
    }

    func testSubagentModelMergesAcrossAliasesAndEnrichesATerminalRow() {
        let provisional = WorkflowUpdate([
            "phase": "started",
            "taskId": "spawn-call",
            "toolUseId": "spawn-call",
            "taskType": "codex_subagent",
            "subagentType": "Codex",
            "status": "running",
        ])
        let authoritativeLane = WorkflowUpdate([
            "phase": "progress",
            "taskId": "child-thread",
            "toolUseId": "activity-call",
            "taskType": "codex_subagent",
            "subagentType": "Codex",
            "model": "gpt-5.3-codex",
            "status": "running",
        ])
        let correlated = WorkflowUpdate([
            "phase": "progress",
            "taskId": "child-thread",
            "toolUseId": "spawn-call",
            "taskType": "codex_subagent",
            "subagentType": "Codex",
            "status": "running",
        ])

        var children = applySubagentUpdate([:], provisional)
        children = applySubagentUpdate(children, authoritativeLane)
        children = applySubagentUpdate(children, correlated)

        XCTAssertEqual(children.count, 1)
        XCTAssertEqual(children["spawn-call"]?.model, "gpt-5.3-codex")

        children = applySubagentUpdate(children, WorkflowUpdate([
            "phase": "notification",
            "taskId": "child-thread",
            "taskType": "codex_subagent",
            "subagentType": "Codex",
            "status": "completed",
        ]))
        children = applySubagentUpdate(children, WorkflowUpdate([
            "phase": "progress",
            "taskId": "child-thread",
            "taskType": "codex_subagent",
            "subagentType": "Codex",
            "model": "  ",
            "status": "running",
        ]))
        XCTAssertEqual(children["spawn-call"]?.status, .completed)
        XCTAssertEqual(
            children["spawn-call"]?.model,
            "gpt-5.3-codex",
            "empty and late-active events neither erase model metadata nor resurrect lifecycle")

        children = applySubagentUpdate(children, WorkflowUpdate([
            "phase": "progress",
            "taskId": "child-thread",
            "taskType": "codex_subagent",
            "subagentType": "Codex",
            "model": "gpt-5.4-codex",
        ]))
        XCTAssertEqual(children["spawn-call"]?.status, .completed)
        XCTAssertEqual(
            children["spawn-call"]?.model,
            "gpt-5.4-codex",
            "an explicit provider reroute can enrich an already-terminal child")
    }

    func testSubagentToolTimelineAccumulatesPerProvider() {
        // Codex: explicit per-tool events, in order.
        var codex = applySubagentUpdate([:], WorkflowUpdate([
            "phase": "started", "taskId": "c", "toolUseId": "c",
            "taskType": "codex_subagent", "subagentType": "Codex", "status": "running",
        ]))
        for tool in ["Bash", "Edit"] {
            codex = applySubagentUpdate(codex, WorkflowUpdate([
                "phase": "progress", "taskId": "c", "subagentType": "Codex",
                "toolEvent": tool, "status": "running",
            ]))
        }
        XCTAssertEqual(codex["c"]?.toolEvents.map(\.name), ["Bash", "Edit"])

        // Claude: sample lastToolName changes; consecutive identical collapse.
        var claude = applySubagentUpdate([:], WorkflowUpdate([
            "phase": "started", "taskId": "x", "toolUseId": "x",
            "subagentType": "general-purpose", "status": "running",
        ]))
        for tool in ["Read", "Read", "Bash"] {
            claude = applySubagentUpdate(claude, WorkflowUpdate([
                "phase": "progress", "taskId": "x", "subagentType": "general-purpose",
                "lastToolName": tool, "status": "running",
            ]))
        }
        XCTAssertEqual(claude["x"]?.toolEvents.map(\.name), ["Read", "Bash"])
    }

    func testCodexToolEventIDFlowsFromWorkflowUpdateIntoActivity() throws {
        let started = WorkflowUpdate([
            "phase": "started", "taskId": "child-thread", "toolUseId": "spawn-call",
            "taskType": "codex_subagent", "subagentType": "Codex", "status": "running",
        ])
        let before = applySubagentUpdate([:], started)
        let toolUpdate = WorkflowUpdate([
            "phase": "progress", "taskId": "child-thread", "subagentType": "Codex",
            "toolEvent": "Bash", "toolTarget": "swift test", "toolEventID": "call-17",
            "status": "running",
        ])
        let after = applySubagentUpdate(before, toolUpdate)

        let event = try XCTUnwrap(after["spawn-call"]?.toolEvents.last)
        XCTAssertEqual(event.name, "Bash")
        XCTAssertEqual(event.target, "swift test")
        XCTAssertEqual(event.toolEventID, "call-17")

        let records = agentActivityRecords(
            beforeSubagents: before,
            afterSubagents: after,
            beforeRuns: [:],
            afterRuns: [:],
            update: toolUpdate,
            turnID: "turn")
        let activity = try XCTUnwrap(records.first { $0.kind == .tool })
        XCTAssertEqual(activity.agentID, AgentActivityIdentity.subagent("child-thread"))
        XCTAssertEqual(activity.toolUseID, "call-17")
        XCTAssertEqual(activity.detail, "Bash")
        XCTAssertEqual(activity.toolTarget, "swift test")
    }

    func testSubagentToolEventTolerantlyDecodesLegacyAndMalformedIDs() throws {
        let legacy = Data(#"{"name":"Read","target":"README.md","at":0}"#.utf8)
        let legacyEvent = try JSONDecoder().decode(SubagentToolEvent.self, from: legacy)
        XCTAssertEqual(legacyEvent.name, "Read")
        XCTAssertEqual(legacyEvent.target, "README.md")
        XCTAssertNil(legacyEvent.toolEventID)

        let malformed = Data(
            #"{"name":"Bash","toolEventID":42,"at":0}"#.utf8)
        XCTAssertNil(
            try JSONDecoder().decode(SubagentToolEvent.self, from: malformed).toolEventID)

        let maximumID = String(repeating: "a", count: 160)
        XCTAssertEqual(
            WorkflowUpdate(["toolEventID": maximumID]).toolEventID,
            maximumID)
        XCTAssertNil(WorkflowUpdate([
            "toolEventID": String(repeating: "a", count: 161),
        ]).toolEventID)
    }

    func testSubagentForestBuildsCodexPathTree() {
        var root = SubagentRun(key: "ta", subagentType: "Codex", task: "root",
                               startedAt: Date(timeIntervalSince1970: 1))
        root.agentPath = "/root/a"
        var child = SubagentRun(key: "tb", subagentType: "Codex", task: "child",
                                startedAt: Date(timeIntervalSince1970: 2))
        child.agentPath = "/root/a/b"
        let forest = subagentForest(["ta": root, "tb": child])
        XCTAssertEqual(forest.map(\.sub.key), ["ta"])
        XCTAssertEqual(forest.first?.children.map(\.sub.key), ["tb"])
        XCTAssertEqual(forest.first?.count, 2)
    }

    func testSubagentForestBuildsClaudeParentTree() {
        let parent = SubagentRun(key: "X", subagentType: "general-purpose", task: "parent",
                                 startedAt: Date(timeIntervalSince1970: 1))
        var childY = SubagentRun(key: "Y", subagentType: "Explore", task: "child",
                                 startedAt: Date(timeIntervalSince1970: 2))
        childY.parentToolUseId = "X"
        let forest = subagentForest(["X": parent, "Y": childY])
        XCTAssertEqual(forest.map(\.sub.key), ["X"])
        XCTAssertEqual(forest.first?.children.map(\.sub.key), ["Y"])
    }

    func testSubagentForestKeepsTopLevelAgentsAsOrderedRoots() {
        var a = SubagentRun(key: "a", subagentType: "Codex", task: "a",
                            startedAt: Date(timeIntervalSince1970: 2))
        a.agentPath = "/root/a"
        var b = SubagentRun(key: "b", subagentType: "Codex", task: "b",
                            startedAt: Date(timeIntervalSince1970: 1))
        b.agentPath = "/root/b"
        let forest = subagentForest(["a": a, "b": b])
        XCTAssertEqual(forest.map(\.sub.key), ["b", "a"])   // ordered by start time
        XCTAssertTrue(forest.allSatisfy { $0.children.isEmpty })
    }

    func testMissingSubagentMetricsRemainUnknownInsteadOfZero() {
        let update = WorkflowUpdate([
            "phase": "started", "taskId": "child", "taskType": "codex_subagent",
            "subagentType": "Codex", "status": "running",
        ])
        let child = applySubagentUpdate([:], update)["child"]

        XCTAssertNil(child?.reportedTokens)
        XCTAssertNil(child?.reportedToolUses)
        XCTAssertEqual(child?.toolMetricLabel, "tool calls")
    }

    func testCodexChildUsageDistinguishesReportedTokensFromObservedTools() {
        var children = applySubagentUpdate([:], WorkflowUpdate([
            "phase": "progress", "taskId": "child", "taskType": "codex_subagent",
            "subagentType": "Codex", "status": "running",
            "usage": [
                "totalTokens": 12_345,
            ],
        ]))
        children = applySubagentUpdate(children, WorkflowUpdate([
            "phase": "progress", "taskId": "child", "taskType": "codex_subagent",
            "subagentType": "Codex", "status": "running",
            "usage": [
                "toolUses": 0,
                "toolUsesObserved": true,
            ],
        ]))
        let child = children["child"]

        XCTAssertEqual(child?.reportedTokens, 12_345)
        XCTAssertEqual(child?.reportedToolUses, 0)
        XCTAssertEqual(child?.toolMetricLabel, "observed tools")
    }

    func testLegacyZeroMetricsRenderAsUnknown() {
        var child = SubagentRun(key: "legacy", subagentType: "Codex", task: "Old row")
        child.tokens = 0
        child.toolUses = 0

        XCTAssertNil(child.reportedTokens)
        XCTAssertNil(child.reportedToolUses)

        child.toolUses = nil
        child.toolUsesObserved = true
        XCTAssertNil(child.reportedToolUses,
                     "An observed marker without a count is malformed, not an observed zero.")
    }

    func testOutOfOrderCodexIdentityCollapsesToOneVisibleSubagent() {
        let provisional = WorkflowUpdate([
            "phase": "started", "taskId": "spawn-call", "toolUseId": "spawn-call",
            "taskType": "codex_subagent", "subagentType": "Codex",
            "description": "Inspect the transcript host", "status": "running",
        ])
        let activity = WorkflowUpdate([
            "phase": "started", "taskId": "child-thread", "toolUseId": "activity-start",
            "taskType": "codex_subagent", "subagentType": "Codex",
            "description": "reviewer", "summary": "Reading files", "status": "running",
        ])
        let identified = WorkflowUpdate([
            "phase": "progress", "taskId": "child-thread", "toolUseId": "spawn-call",
            "taskType": "codex_subagent", "subagentType": "Codex", "status": "running",
        ])

        var subagents = applySubagentUpdate([:], provisional)
        subagents = applySubagentUpdate(subagents, activity)
        XCTAssertEqual(subagents.count, 2, "Both provider identities can arrive before correlation.")
        subagents = applySubagentUpdate(subagents, identified)

        XCTAssertEqual(subagents.count, 1)
        XCTAssertEqual(subagents["spawn-call"]?.taskId, "child-thread")
        XCTAssertEqual(subagents["spawn-call"]?.task, "Inspect the transcript host")
        XCTAssertEqual(subagents["spawn-call"]?.summary, "Reading files")
    }

    func testOutOfOrderCodexIdentityKeepsOneTerminalActivityLane() {
        let provisional = WorkflowUpdate([
            "phase": "started", "taskId": "spawn-call", "toolUseId": "spawn-call",
            "taskType": "codex_subagent", "subagentType": "Codex",
            "description": "Inspect the transcript host", "status": "running",
        ])
        let activity = WorkflowUpdate([
            "phase": "started", "taskId": "child-thread", "toolUseId": "activity-start",
            "taskType": "codex_subagent", "subagentType": "Codex",
            "summary": "Reading files", "status": "running",
        ])
        let identified = WorkflowUpdate([
            "phase": "progress", "taskId": "child-thread", "toolUseId": "spawn-call",
            "taskType": "codex_subagent", "subagentType": "Codex", "status": "running",
        ])
        let terminal = WorkflowUpdate([
            "phase": "notification", "taskId": "child-thread",
            "taskType": "codex_subagent", "subagentType": "Codex", "status": "completed",
        ])

        let rootStart = Date(timeIntervalSince1970: 800)
        var ledger: [AgentActivityRecord] = [
            .state(.model, turnID: "turn", at: rootStart),
        ]
        var subagents: [String: SubagentRun] = [:]
        for update in [provisional, activity, identified, terminal] {
            let before = subagents
            subagents = applySubagentUpdate(subagents, update)
            ledger.append(contentsOf: agentActivityRecords(
                beforeSubagents: before,
                afterSubagents: subagents,
                beforeRuns: [:],
                afterRuns: [:],
                update: update,
                turnID: "turn",
                observedAt: rootStart.addingTimeInterval(Double(ledger.count + 1))))
        }
        ledger.append(.state(
            .completed,
            turnID: "turn",
            at: rootStart.addingTimeInterval(20)))

        let canonical = AgentActivityIdentity.subagent("spawn-call")
        let childThread = AgentActivityIdentity.subagent("child-thread")
        let aliases = [
            canonical: canonical,
            childThread: canonical,
        ]
        let delegated = canonicalizedAgentActivityGroups(
            ledger.filter { $0.agentID != AgentActivityIdentity.root },
            aliases: aliases)

        XCTAssertEqual(subagents.keys.sorted(), ["spawn-call"])
        XCTAssertFalse(ledger.contains {
            $0.agentID == AgentActivityIdentity.subagent("activity-start")
        })
        XCTAssertEqual(delegated.keys.sorted(), [canonical])
        XCTAssertEqual(delegated[canonical]?.last?.phase, .completed)
        XCTAssertTrue(agentActivityTurnSummaries(ledger, aliases: aliases)[0].isTerminal)
    }

    func testLateToolMetadataDoesNotResurrectATerminalAgentLane() {
        let start = Date(timeIntervalSince1970: 900)
        var before = SubagentRun(
            key: "spawn-call",
            subagentType: "Codex",
            task: "Finished child",
            status: .completed,
            startedAt: start,
            endedAt: start.addingTimeInterval(5))
        before.taskId = "child-thread"
        var after = before
        after.toolEvents = [
            SubagentToolEvent(name: "Read", at: start.addingTimeInterval(8)),
        ]
        let update = WorkflowUpdate([
            "phase": "progress",
            "taskId": "child-thread",
            "toolUseId": "spawn-call",
            "taskType": "codex_subagent",
            "subagentType": "Codex",
            "toolEvent": "Read",
        ])

        let lateRecords = agentActivityRecords(
            beforeSubagents: [before.key: before],
            afterSubagents: [after.key: after],
            beforeRuns: [:],
            afterRuns: [:],
            update: update,
            turnID: "turn",
            observedAt: start.addingTimeInterval(8))
        let childID = AgentActivityIdentity.subagent("child-thread")
        let ledger: [AgentActivityRecord] = [
            .state(.model, turnID: "turn", at: start),
            .state(
                .completed,
                turnID: "turn",
                agentID: childID,
                at: start.addingTimeInterval(5)),
            .state(.completed, turnID: "turn", at: start.addingTimeInterval(6)),
        ] + lateRecords

        XCTAssertEqual(lateRecords.map(\.kind), [.tool])
        XCTAssertTrue(agentActivityTurnSummaries(ledger)[0].isTerminal)
    }

    func testAuthoritativeRetaskProjectsFreshLifecycleIntoNewParentTurn() {
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
        var subagents = [completed.key: completed]

        let newTurnStart = Date(timeIntervalSince1970: 1_000)
        let runningUpdate = WorkflowUpdate([
            "phase": "progress",
            "taskId": "child-thread",
            "toolUseId": "spawn-call",
            "taskType": "codex_subagent",
            "subagentType": "Codex",
            "status": "running",
            "lastToolName": "interacted",
            "summary": "Checking the new release",
        ])
        let beforeRunning = subagents
        subagents = applySubagentUpdate(
            subagents,
            runningUpdate,
            observedAt: newTurnStart.addingTimeInterval(2))
        let runningRecords = agentActivityRecords(
            beforeSubagents: beforeRunning,
            afterSubagents: subagents,
            beforeRuns: [:],
            afterRuns: [:],
            update: runningUpdate,
            turnID: "new-turn",
            observedAt: newTurnStart.addingTimeInterval(2))

        XCTAssertEqual(subagents["spawn-call"]?.status, .running)
        XCTAssertEqual(subagents["spawn-call"]?.startedAt, newTurnStart.addingTimeInterval(2))
        XCTAssertNil(subagents["spawn-call"]?.endedAt)
        XCTAssertEqual(runningRecords.map(\.phase), [.model])
        XCTAssertEqual(runningRecords.first?.at, newTurnStart.addingTimeInterval(2))

        let terminalUpdate = WorkflowUpdate([
            "phase": "notification",
            "taskId": "child-thread",
            "toolUseId": "spawn-call",
            "taskType": "codex_subagent",
            "subagentType": "Codex",
            "status": "completed",
            "summary": "Release verified",
        ])
        let beforeTerminal = subagents
        subagents = applySubagentUpdate(
            subagents,
            terminalUpdate,
            observedAt: newTurnStart.addingTimeInterval(8))
        let terminalRecords = agentActivityRecords(
            beforeSubagents: beforeTerminal,
            afterSubagents: subagents,
            beforeRuns: [:],
            afterRuns: [:],
            update: terminalUpdate,
            turnID: "new-turn",
            observedAt: newTurnStart.addingTimeInterval(8))

        XCTAssertEqual(subagents["spawn-call"]?.status, .completed)
        XCTAssertEqual(subagents["spawn-call"]?.endedAt, newTurnStart.addingTimeInterval(8))
        XCTAssertNotEqual(subagents["spawn-call"]?.endedAt, originalEnd)
        XCTAssertEqual(terminalRecords.map(\.phase), [.completed])
        XCTAssertEqual(terminalRecords.first?.at, newTurnStart.addingTimeInterval(8))

        let ledger = [
            AgentActivityRecord.state(.model, turnID: "new-turn", at: newTurnStart),
        ] + runningRecords + terminalRecords + [
            AgentActivityRecord.state(
                .completed,
                turnID: "new-turn",
                at: newTurnStart.addingTimeInterval(9)),
        ]
        let aliases = agentActivityAliases(subagents: subagents)
        XCTAssertTrue(agentActivityTurnSummaries(ledger, aliases: aliases)[0].isTerminal)
    }

    func testAuthoritativeRetaskReopensActivityWithinTheSameParentTurn() throws {
        let start = Date(timeIntervalSince1970: 1_100)
        let childID = AgentActivityIdentity.subagent("child-thread")
        var completed = SubagentRun(
            key: "spawn-call",
            subagentType: "Codex",
            task: "Inspect the activity panel",
            status: .completed,
            startedAt: start.addingTimeInterval(1),
            endedAt: start.addingTimeInterval(2))
        completed.taskId = "child-thread"
        completed.tokens = 1_200
        completed.toolUses = 2
        completed.toolUsesObserved = true
        completed.toolEvents = [SubagentToolEvent(name: "Read", at: start)]
        completed.resultPreview = "Prior result"
        completed.error = "Prior failure"
        completed.durationMs = 500
        var subagents = [completed.key: completed]
        let originalEnd = try XCTUnwrap(completed.endedAt)
        var ledger: [AgentActivityRecord] = [
            .state(.model, turnID: "same-turn", at: start),
            .state(
                .model,
                turnID: "same-turn",
                agentID: childID,
                detail: "Checking",
                at: start.addingTimeInterval(1)),
            .state(
                .completed,
                turnID: "same-turn",
                agentID: childID,
                at: start.addingTimeInterval(2)),
            .state(.completed, turnID: "same-turn", at: start.addingTimeInterval(2.5)),
        ]

        func project(_ fields: [String: Any], at observedAt: Date) -> [AgentActivityRecord] {
            let update = WorkflowUpdate(fields)
            let before = subagents
            subagents = applySubagentUpdate(subagents, update, observedAt: observedAt)
            return agentActivityRecords(
                beforeSubagents: before,
                afterSubagents: subagents,
                beforeRuns: [:],
                afterRuns: [:],
                update: update,
                turnID: "same-turn",
                observedAt: observedAt)
        }

        let ordinaryBuffered = project([
            "phase": "progress",
            "taskId": "child-thread",
            "taskType": "codex_subagent",
            "subagentType": "Codex",
            "status": "running",
            "summary": "Checking",
        ], at: start.addingTimeInterval(3))
        ordinaryBuffered.forEach { appendAgentActivityRecord($0, to: &ledger) }
        XCTAssertTrue(ordinaryBuffered.isEmpty)
        XCTAssertEqual(subagents["spawn-call"]?.status, .completed)
        XCTAssertEqual(subagents["spawn-call"]?.endedAt, originalEnd)
        XCTAssertFalse(ordinaryBuffered.contains { $0.startsNewLifecycleGeneration == true })
        XCTAssertFalse(agentActivityLaneIsActive(ledger.filter { $0.agentID == childID }))
        XCTAssertTrue(agentActivityTurnSummaries(ledger)[0].isTerminal)

        let retask = project([
            "phase": "progress",
            "taskId": "child-thread",
            "taskType": "codex_subagent",
            "subagentType": "Codex",
            "status": "running",
            "lastToolName": "interacted",
            "summary": "Checking",
        ], at: start.addingTimeInterval(4))
        retask.forEach { appendAgentActivityRecord($0, to: &ledger) }
        let boundary = try XCTUnwrap(retask.first { $0.startsNewLifecycleGeneration == true })
        XCTAssertEqual(boundary.phase, .model)
        XCTAssertEqual(boundary.at, start.addingTimeInterval(4))
        XCTAssertEqual(subagents["spawn-call"]?.status, .running)
        XCTAssertEqual(subagents["spawn-call"]?.startedAt, start.addingTimeInterval(4))
        XCTAssertNil(subagents["spawn-call"]?.endedAt)
        XCTAssertNil(subagents["spawn-call"]?.resultPreview)
        XCTAssertNil(subagents["spawn-call"]?.error)
        XCTAssertEqual(subagents["spawn-call"]?.durationMs, 500)
        XCTAssertEqual(subagents["spawn-call"]?.tokens, 1_200)
        XCTAssertEqual(subagents["spawn-call"]?.toolUses, 2)
        XCTAssertEqual(subagents["spawn-call"]?.toolEvents.map(\.name), ["Read"])
        XCTAssertEqual(
            terminalMonotonicActivityStates(ledger.filter { $0.agentID == childID }).map(\.id),
            [boundary.id])
        XCTAssertTrue(agentActivityLaneIsActive(ledger.filter { $0.agentID == childID }))
        XCTAssertNil(agentActivityLaneTerminalBoundary(ledger.filter { $0.agentID == childID }))
        XCTAssertFalse(agentActivityTurnSummaries(ledger)[0].isTerminal)

        let countAfterBoundary = ledger.count
        let ordinaryCurrentProgress = project([
            "phase": "progress",
            "taskId": "child-thread",
            "taskType": "codex_subagent",
            "subagentType": "Codex",
            "status": "running",
            "lastToolName": "Bash",
            "summary": "Checking",
        ], at: start.addingTimeInterval(5))
        ordinaryCurrentProgress.forEach { appendAgentActivityRecord($0, to: &ledger) }
        XCTAssertEqual(
            ledger.count,
            countAfterBoundary,
            "ordinary same-state progress after the boundary is redundant, not another span")

        let secondRetask = project([
            "phase": "progress",
            "taskId": "child-thread",
            "taskType": "codex_subagent",
            "subagentType": "Codex",
            "status": "running",
            "lastToolName": "sendInput",
            "summary": "Checking",
        ], at: start.addingTimeInterval(5.5))
        secondRetask.forEach { appendAgentActivityRecord($0, to: &ledger) }
        let secondBoundary = try XCTUnwrap(
            secondRetask.first { $0.startsNewLifecycleGeneration == true })
        XCTAssertEqual(
            agentActivityLifecycleGenerationRecords(
                ledger.filter { $0.agentID == childID }).count,
            3,
            "a distinct authoritative retask while already running remains a new generation")
        XCTAssertEqual(
            terminalMonotonicActivityStates(
                ledger.filter { $0.agentID == childID }).map(\.id),
            [secondBoundary.id])

        let terminal = project([
            "phase": "notification",
            "taskId": "child-thread",
            "taskType": "codex_subagent",
            "subagentType": "Codex",
            "status": "completed",
            "lastToolName": "completed",
            "summary": "Checked",
        ], at: start.addingTimeInterval(6))
        terminal.forEach { appendAgentActivityRecord($0, to: &ledger) }
        XCTAssertEqual(subagents["spawn-call"]?.status, .completed)
        XCTAssertEqual(subagents["spawn-call"]?.endedAt, start.addingTimeInterval(6))
        XCTAssertNotEqual(subagents["spawn-call"]?.endedAt, originalEnd)
        XCTAssertFalse(agentActivityLaneIsActive(ledger.filter { $0.agentID == childID }))
        XCTAssertEqual(
            agentActivityLaneTerminalBoundary(ledger.filter { $0.agentID == childID }),
            start.addingTimeInterval(6))
        XCTAssertTrue(agentActivityTurnSummaries(ledger)[0].isTerminal)

        let decoded = try JSONDecoder().decode(
            AgentActivityRecord.self,
            from: JSONEncoder().encode(boundary))
        XCTAssertEqual(decoded.startsNewLifecycleGeneration, true)
    }

    func testOnlyAuthoritativeCodexRetasksStartActivityGenerations() {
        for name in ["interacted", "sendInput"] {
            XCTAssertTrue(WorkflowUpdate([
                "taskId": "child",
                "taskType": "codex_subagent",
                "status": "running",
                "lastToolName": name,
            ]).startsNewSubagentLifecycleGeneration)
        }
        XCTAssertFalse(WorkflowUpdate([
            "taskId": "child",
            "taskType": "codex_subagent",
            "status": "running",
            "lastToolName": "Bash",
        ]).startsNewSubagentLifecycleGeneration)
        XCTAssertFalse(WorkflowUpdate([
            "taskId": "child",
            "taskType": "claude_subagent",
            "status": "running",
            "lastToolName": "sendInput",
        ]).startsNewSubagentLifecycleGeneration)
    }

    func testParallelCodexChildrenRemainDistinctAndTerminalizeIndependently() {
        var subagents: [String: SubagentRun] = [:]
        for (spawn, child, task) in [
            ("spawn-a", "child-a", "Inspect persistence"),
            ("spawn-b", "child-b", "Inspect rendering"),
        ] {
            subagents = applySubagentUpdate(subagents, WorkflowUpdate([
                "phase": "started", "taskId": spawn, "toolUseId": spawn,
                "taskType": "codex_subagent", "subagentType": "Codex",
                "description": task, "status": "running",
            ]))
            subagents = applySubagentUpdate(subagents, WorkflowUpdate([
                "phase": "progress", "taskId": child, "toolUseId": spawn,
                "taskType": "codex_subagent", "subagentType": "Codex", "status": "running",
            ]))
        }

        XCTAssertEqual(subagents.count, 2)
        XCTAssertEqual(runningDelegatedAgentCount(subagents: subagents, workflowRuns: [:]), 2)

        subagents = applySubagentUpdate(subagents, WorkflowUpdate([
            "phase": "notification", "taskId": "child-a",
            "taskType": "codex_subagent", "subagentType": "Codex", "status": "completed",
        ]))
        XCTAssertEqual(runningDelegatedAgentCount(subagents: subagents, workflowRuns: [:]), 1)
        XCTAssertEqual(subagents["spawn-b"]?.status, .running)

        subagents = applySubagentUpdate(subagents, WorkflowUpdate([
            "phase": "notification", "taskId": "child-b",
            "taskType": "codex_subagent", "subagentType": "Codex",
            "status": "failed", "error": "Parallel agent capacity was exhausted.",
        ]))
        XCTAssertEqual(runningDelegatedAgentCount(subagents: subagents, workflowRuns: [:]), 0)
        XCTAssertEqual(subagents["spawn-b"]?.status, .failed)
        XCTAssertEqual(subagents["spawn-b"]?.error, "Parallel agent capacity was exhausted.")
        XCTAssertEqual(subagents.values.filter { $0.status.needsAttention }.count, 1)

        // A late progress notification cannot resurrect a terminal child.
        subagents = applySubagentUpdate(subagents, WorkflowUpdate([
            "phase": "progress", "taskId": "child-b",
            "taskType": "codex_subagent", "subagentType": "Codex", "status": "running",
        ]))
        XCTAssertEqual(subagents["spawn-b"]?.status, .failed)
    }

    func testBlockingDelegateCountCollapsesMirrorsAndCountsChildlessWorkflows() {
        var standalone = SubagentRun(
            key: "spawn-child",
            subagentType: "Explore",
            task: "Inspect")
        standalone.taskId = "provider-child"

        var mirroredAgent = WorkflowAgent(
            index: 0,
            label: "finder",
            phaseIndex: 0,
            phaseTitle: "Find",
            state: .progress)
        mirroredAgent.agentId = "provider-child"
        var mirroredRun = WorkflowRun(runKey: "mirrored", status: .running)
        mirroredRun.agents = ["0:0": mirroredAgent]

        XCTAssertEqual(
            blockingDelegatedAgentCount(
                subagents: ["spawn-child": standalone],
                workflowRuns: ["mirrored": mirroredRun]),
            1,
            "one provider child mirrored in two stores is one blocker")
        XCTAssertEqual(
            runningDelegatedAgentCount(
                subagents: ["spawn-child": standalone],
                workflowRuns: ["mirrored": mirroredRun]),
            1)

        let childless = WorkflowRun(runKey: "childless", status: .pending)
        XCTAssertEqual(
            blockingDelegatedAgentCount(
                subagents: [:],
                workflowRuns: ["childless": childless]),
            1,
            "a top-level workflow owns work before its child graph arrives")

        mirroredRun.status = .completed
        XCTAssertEqual(
            blockingDelegatedAgentCount(
                subagents: [:],
                workflowRuns: ["mirrored": mirroredRun]),
            1,
            "a terminal aggregate cannot hide its nonterminal child")
        XCTAssertEqual(
            runningDelegatedAgentCount(
                subagents: [:],
                workflowRuns: ["mirrored": mirroredRun]),
            1)
    }

    func testWorkflowAggregateRetiresItsProvisionalTaskMirrorAndActivityLane() {
        var run = WorkflowRun(
            runKey: "workflow-tool",
            toolUseId: "workflow-tool",
            runTaskId: "workflow-task",
            status: .failed)
        run.agents["0:0"] = WorkflowAgent(
            index: 0,
            label: "Inspector",
            phaseIndex: 0,
            phaseTitle: "Inspect",
            state: .failed,
            agentId: "provider-child")

        var aggregateMirror = SubagentRun(
            key: "workflow-tool",
            subagentType: "workflow",
            task: "Run the workflow")
        aggregateMirror.taskId = "workflow-task"
        var child = SubagentRun(
            key: "spawn-child",
            subagentType: "Explore",
            task: "Inspect evidence")
        child.taskId = "provider-child"
        var subagents = [
            aggregateMirror.key: aggregateMirror,
            child.key: child,
        ]
        var activity = [
            AgentActivityRecord.state(
                .model,
                turnID: "turn",
                agentID: AgentActivityIdentity.subagent("workflow-tool"),
                detail: "Delegated"),
            AgentActivityRecord.state(
                .failed,
                turnID: "turn",
                agentID: AgentActivityIdentity.subagent("provider-child"),
                detail: "Child failed"),
            AgentActivityRecord.tool(
                "Read",
                turnID: "turn",
                agentID: AgentActivityIdentity.subagent("workflow-tool"),
                target: "relative/evidence.txt"),
        ]

        XCTAssertTrue(collapseWorkflowAggregateMirrors(
            workflowRuns: [run.runKey: run],
            subagents: &subagents,
            agentActivity: &activity))
        XCTAssertNil(subagents["workflow-tool"])
        XCTAssertEqual(subagents["spawn-child"]?.taskId, "provider-child")
        XCTAssertEqual(activity.count, 2)
        XCTAssertTrue(activity.contains {
            $0.kind == .state
                && $0.agentID == AgentActivityIdentity.subagent("provider-child")
        })
        XCTAssertTrue(activity.contains {
            $0.kind == .tool
                && $0.agentID == AgentActivityIdentity.subagent("workflow-tool")
        }, "a child tool observation attributed through the aggregate remains evidence")
        XCTAssertFalse(collapseWorkflowAggregateMirrors(
            workflowRuns: [run.runKey: run],
            subagents: &subagents,
            agentActivity: &activity),
            "aggregate mirror cleanup is idempotent")

        // Providers may identify the workflow before its assistant Task frame arrives. Re-seeding
        // that late tool frame must be collapsed just as deterministically.
        subagents = applySubagentToolUse(
            subagents,
            toolUseId: "workflow-tool",
            parentToolUseId: nil,
            subagentType: "workflow",
            task: "Run the workflow")
        activity.append(.state(
            .model,
            turnID: "turn",
            agentID: AgentActivityIdentity.subagent("workflow-tool"),
            detail: "Delegated"))
        XCTAssertTrue(collapseWorkflowAggregateMirrors(
            workflowRuns: [run.runKey: run],
            subagents: &subagents,
            agentActivity: &activity))
        XCTAssertNil(subagents["workflow-tool"])
        XCTAssertFalse(activity.contains { $0.kind == .state
            && $0.agentID == AgentActivityIdentity.subagent("workflow-tool") })
    }

    func testAgentsEmptyStateExplainsRouteAndUltraBehavior() {
        let codex = agentsEmptyStateCopy(for: .codexSubscription, ultraEnabled: false)
        XCTAssertTrue(codex.detail.contains("delegate a bounded task explicitly"))

        let codexUltra = agentsEmptyStateCopy(for: .codexSubscription, ultraEnabled: true)
        XCTAssertTrue(codexUltra.detail.contains("automatically"))

        let directOpenAI = agentsEmptyStateCopy(for: .openAIAPI, ultraEnabled: false)
        XCTAssertTrue(directOpenAI.title.contains("aren’t available"))
        XCTAssertTrue(directOpenAI.detail.contains("Codex or Claude"))
    }

    @MainActor
    func testProviderEffortLabelsStayRouteTruthful() {
        XCTAssertEqual(AgentBridge.effortLabel("low", access: .codexSubscription), "Light")
        XCTAssertEqual(AgentBridge.effortLabel("low", access: .claudeSubscription), "Low")
        XCTAssertEqual(AgentBridge.effortLabel("xhigh", access: .codexSubscription), "Extra High")
        XCTAssertEqual(AgentBridge.effortLabel("max", access: .claudeSubscription), "Max")
        XCTAssertEqual(AgentBridge.effortLabel("ultra", access: .codexSubscription), "Ultra")
        XCTAssertEqual(AgentBridge.effortLabel("none", access: .openAIAPI), "None")
        XCTAssertTrue(AgentBridge.supportsUltra(
            access: .claudeSubscription,
            efforts: ["low", "medium", "high", "xhigh", "max"]))
        XCTAssertTrue(AgentBridge.supportsUltra(
            access: .codexSubscription,
            efforts: ["low", "medium", "high", "xhigh", "max", "ultra"]))
        XCTAssertFalse(AgentBridge.supportsUltra(
            access: .codexSubscription,
            efforts: ["low", "medium", "high", "xhigh", "max"]))
        XCTAssertFalse(AgentBridge.supportsUltra(
            access: .openAIAPI,
            efforts: ["low", "medium", "high", "xhigh", "max"]))
        XCTAssertTrue(AgentBridge.supportsUltra(
            access: .anthropicAPI,
            efforts: ["low", "medium", "high", "xhigh", "max"]))
        XCTAssertFalse(AgentBridge.supportsUltra(
            access: .claudeSubscription,
            efforts: ["low", "medium", "high"]))

        let claude = AgentBridge.ultraTurnConfiguration(
            access: .claudeSubscription, efforts: ["high", "xhigh"])
        XCTAssertEqual(claude?.effort, "xhigh")
        XCTAssertEqual(claude?.ultracode, true)
        let anthropicAPI = AgentBridge.ultraTurnConfiguration(
            access: .anthropicAPI, efforts: ["high", "xhigh"])
        XCTAssertEqual(anthropicAPI?.effort, "xhigh")
        XCTAssertEqual(anthropicAPI?.ultracode, true)
        let codex = AgentBridge.ultraTurnConfiguration(
            access: .codexSubscription, efforts: ["high", "max", "ultra"])
        XCTAssertEqual(codex?.effort, "ultra")
        XCTAssertEqual(codex?.ultracode, false)

        let legacyClaude = AgentBridge.migratedLegacyUltraPreference(
            access: .claudeSubscription, effort: "high", enabled: true)
        XCTAssertEqual(legacyClaude.effort, "xhigh")
        XCTAssertEqual(legacyClaude.enabled, true)
        let legacyAnthropicAPI = AgentBridge.migratedLegacyUltraPreference(
            access: .anthropicAPI, effort: "high", enabled: true)
        XCTAssertEqual(legacyAnthropicAPI.effort, "xhigh")
        XCTAssertEqual(legacyAnthropicAPI.enabled, true)
        let legacyCodex = AgentBridge.migratedLegacyUltraPreference(
            access: .codexSubscription, effort: "high", enabled: true)
        XCTAssertEqual(legacyCodex.effort, "high")
        XCTAssertEqual(legacyCodex.enabled, false)
    }

    @MainActor
    func testEffortMenuNeverTreatsPersistedPreferenceAsProviderCatalog() {
        XCTAssertEqual(AgentBridge.visibleEffortChoices(reported: nil), [])
        XCTAssertEqual(
            AgentBridge.visibleEffortChoices(
                reported: ["max", "high", "low", "medium", "xhigh", "ultra"]),
            ["low", "medium", "high", "xhigh", "max"])
    }

    @MainActor
    func testFirstUseEffortPrefersMediumOrStrongerWithoutEnablingUltra() {
        XCTAssertEqual(
            AgentBridge.preferredDefaultEffort(
                from: ["low", "medium", "high", "xhigh", "max", "ultra"]),
            "medium")
        XCTAssertEqual(
            AgentBridge.preferredDefaultEffort(from: ["minimal", "low", "high", "ultra"]),
            "high")
        XCTAssertEqual(
            AgentBridge.preferredDefaultEffort(from: ["none", "minimal", "low"]),
            "low")
        XCTAssertNil(AgentBridge.preferredDefaultEffort(from: ["ultra"]))
    }

    @MainActor
    func testModelEffortUltraAndPermissionRestoreFromSettingsAfterRelaunch() throws {
        let defaultAccessKey = "providerAccounts.defaultConversationAccess.v1"
        let defaults = UserDefaults.standard
        let priorDefaultAccess = defaults.object(forKey: defaultAccessKey)
        defaults.removeObject(forKey: defaultAccessKey)
        defer {
            if let priorDefaultAccess {
                defaults.set(priorDefaultAccess, forKey: defaultAccessKey)
            } else {
                defaults.removeObject(forKey: defaultAccessKey)
            }
        }
        let support = FileManager.default.temporaryDirectory
            .appendingPathComponent("Mechanician-preference-restart-\(UUID().uuidString)",
                                  isDirectory: true)
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: support) }

        // An EMPTY launch environment, not the process's. `loadSettings()` treats MECHANICIAN_AUTH /
        // MECHANICIAN_PROVIDER as a deliberate dev override that outranks the persisted lane, so a
        // suite running with them exported — which is what happens when the app or dev.sh is the
        // parent process — would see the saved provider rewritten and fail here for a reason that
        // has nothing to do with persistence. It passed or failed purely on which lane happened to
        // be exported.
        let firstLaunch = AgentBridge(settingsBaseOverride: support, environmentOverride: [:])
        firstLaunch.loadSettings()
        XCTAssertEqual(firstLaunch.effort, "medium", "A fresh install must not begin at Light.")

        firstLaunch.provider = "codex"
        firstLaunch.authMode = "subscription"
        firstLaunch.model = "gpt-5.6-sol"
        firstLaunch.effort = "max"
        firstLaunch.ultracode = true
        firstLaunch.permissionMode = "bypassPermissions"

        let secondLaunch = AgentBridge(settingsBaseOverride: support, environmentOverride: [:])
        secondLaunch.loadSettings()

        XCTAssertEqual(secondLaunch.provider, "codex")
        XCTAssertEqual(secondLaunch.authMode, "subscription")
        XCTAssertEqual(secondLaunch.model, "gpt-5.6-sol")
        XCTAssertEqual(secondLaunch.effort, "max")
        XCTAssertTrue(secondLaunch.ultracode)
        XCTAssertEqual(secondLaunch.permissionMode, "bypassPermissions")

        // Medium is only a default. A deliberate lighter choice remains authoritative.
        secondLaunch.effort = "low"
        let thirdLaunch = AgentBridge(settingsBaseOverride: support, environmentOverride: [:])
        thirdLaunch.loadSettings()
        XCTAssertEqual(thirdLaunch.effort, "low")
        XCTAssertFalse(thirdLaunch.ultracode)
    }

    // MARK: FR-91 — errored agents must reach Needs attention, not linger in Active/Completed

    func testSubagentErrorWithoutTerminalStatusRoutesToNeedsAttention() {
        // A child reports an error while its own status is still running. It must move to Needs
        // attention (.failed) instead of sitting in Active with a red error label.
        let update = WorkflowUpdate([
            "phase": "progress", "taskId": "child", "toolUseId": "child",
            "taskType": "codex_subagent", "subagentType": "Codex",
            "status": "running", "error": "The tool crashed.",
        ])
        let subs = applySubagentUpdate([:], update)

        XCTAssertEqual(subs["child"]?.status, .failed)
        XCTAssertEqual(subs["child"]?.error, "The tool crashed.")
        XCTAssertTrue(subs["child"]?.status.needsAttention ?? false)
        XCTAssertNotNil(subs["child"]?.endedAt)
    }

    func testWorkflowChildErrorStateMakesCompletedRunNeedAttention() {
        // The live CLI reports a failed workflow child with state "error" (not "failed"); the run
        // then reports itself completed. effectiveRunStatus must surface the failed child so the
        // monitor files the run under Needs attention rather than Completed.
        let start: [[String: Any]] = [
            ["type": "workflow_phase", "index": 0, "title": "Find"],
            ["type": "workflow_agent", "index": 0, "phaseIndex": 0, "label": "finder", "state": "progress"],
        ]
        var runs = applyWorkflowUpdate([:], WorkflowUpdate([
            "phase": "progress", "taskId": "run-1", "toolUseId": "run-1",
            "workflowProgress": start,
        ]), sessionId: "s")
        XCTAssertEqual(runs.count, 1)

        let fail: [[String: Any]] = [
            ["type": "workflow_agent", "index": 0, "phaseIndex": 0, "state": "error"],
        ]
        runs = applyWorkflowUpdate(runs, WorkflowUpdate([
            "phase": "progress", "taskId": "run-1", "toolUseId": "run-1",
            "workflowProgress": fail,
        ]), sessionId: "s")
        XCTAssertTrue(runs["run-1"]!.agents.values.contains { $0.state == .failed },
                      "state:\"error\" must map to the canonical .failed child state, not be dropped.")

        runs = applyWorkflowUpdate(runs, WorkflowUpdate([
            "phase": "updated", "taskId": "run-1", "toolUseId": "run-1", "status": "completed",
        ]), sessionId: "s")

        XCTAssertEqual(runs["run-1"]!.status, .completed)
        XCTAssertEqual(effectiveRunStatus(runs["run-1"]!), .failed)
        XCTAssertTrue(effectiveRunStatus(runs["run-1"]!).needsAttention)
    }

    // FR-101: a workflow agent gets the same tool-by-tool timeline + run-window the standalone
    // subagent pane has. The timeline samples lastToolName as it changes (no duplicates); the window
    // stamps startedAt on first-running and endedAt on terminal.
    func testWorkflowAgentToolTimelineAndRunWindowAccumulate() {
        func step(_ tool: String, _ state: String) -> WorkflowUpdate {
            WorkflowUpdate([
                "phase": "progress", "taskId": "run-1", "toolUseId": "run-1",
                "workflowProgress": [["type": "workflow_agent", "index": 0, "phaseIndex": 0,
                                      "label": "finder", "state": state, "lastToolName": tool]],
            ])
        }
        var runs = applyWorkflowUpdate([:], step("Read", "progress"), sessionId: "s")
        runs = applyWorkflowUpdate(runs, step("Read", "progress"), sessionId: "s") // repeat → no dup
        runs = applyWorkflowUpdate(runs, step("Bash", "progress"), sessionId: "s")

        let running = runs["run-1"]!.agents["0:0"]!
        XCTAssertEqual(running.toolEvents.map(\.name), ["Read", "Bash"])
        XCTAssertNotNil(running.startedAt)
        XCTAssertNil(running.endedAt)

        runs = applyWorkflowUpdate(runs, step("Bash", "done"), sessionId: "s")
        let done = runs["run-1"]!.agents["0:0"]!
        XCTAssertEqual(done.toolEvents.map(\.name), ["Read", "Bash"], "same tool must not re-append")
        XCTAssertNotNil(done.startedAt)
        XCTAssertNotNil(done.endedAt)
    }

    // FR-101: a reported zero for a completed provider turn is unavailable, not a measured zero —
    // mirroring SubagentRun.reportedTokens, so the detail pane shows "Not reported", never "0".
    func testWorkflowAgentReportedMetricsTreatZeroAsUnknown() {
        var runs = applyWorkflowUpdate([:], WorkflowUpdate([
            "phase": "progress", "taskId": "run-1", "toolUseId": "run-1",
            "workflowProgress": [["type": "workflow_agent", "index": 0, "phaseIndex": 0,
                                  "state": "done", "tokens": 0, "toolCalls": 0]],
        ]), sessionId: "s")
        let zeroed = runs["run-1"]!.agents["0:0"]!
        XCTAssertNil(zeroed.reportedTokens)
        XCTAssertNil(zeroed.reportedToolCalls)

        runs = applyWorkflowUpdate(runs, WorkflowUpdate([
            "phase": "progress", "taskId": "run-1", "toolUseId": "run-1",
            "workflowProgress": [["type": "workflow_agent", "index": 0, "phaseIndex": 0,
                                  "tokens": 1200, "toolCalls": 3]],
        ]), sessionId: "s")
        let positive = runs["run-1"]!.agents["0:0"]!
        XCTAssertEqual(positive.reportedTokens, 1200)
        XCTAssertEqual(positive.reportedToolCalls, 3)
    }

    func testWorkflowUsageMergesComplementaryPartialUpdates() {
        var runs = applyWorkflowUpdate([:], WorkflowUpdate([
            "phase": "started",
            "taskId": "run",
            "isWorkflowRun": true,
            "status": "running",
            "usage": [
                "totalTokens": 120,
                "durationMs": 4_000,
                "inputTokens": 90,
            ],
        ]), sessionId: "session")
        runs = applyWorkflowUpdate(runs, WorkflowUpdate([
            "phase": "progress",
            "taskId": "run",
            "isWorkflowRun": true,
            "status": "running",
            "usage": [
                "toolUses": 7,
                "toolUsesObserved": true,
                "outputTokens": 30,
            ],
        ]), sessionId: "session")

        let usage = runs["run"]?.usage
        XCTAssertEqual(usage?.totalTokens, 120)
        XCTAssertEqual(usage?.durationMs, 4_000)
        XCTAssertEqual(usage?.toolUses, 7)
        XCTAssertEqual(usage?.toolUsesObserved, true)
        XCTAssertEqual(usage?.inputTokens, 90)
        XCTAssertEqual(usage?.outputTokens, 30)
    }

    // FR-101 + the Codable-default trap: a WorkflowRun persisted before the timeline field must still
    // decode. Its agents lack toolEvents/startedAt/endedAt; a synthesized decoder would throw
    // keyNotFound and quarantine the whole conversation. The tolerant WorkflowAgent init recovers it.
    func testLegacyWorkflowRunDecodesWhenAgentsPredateTimelineField() throws {
        let json = """
        {"runKey":"run-1","status":"completed",
         "agents":{"0:0":{"index":0,"phaseIndex":0,"label":"finder","state":"done",
                          "model":"claude-opus-4-8","tokens":900}}}
        """.data(using: .utf8)!
        let run = try JSONDecoder().decode(WorkflowRun.self, from: json)
        let agent = try XCTUnwrap(run.agents["0:0"])
        XCTAssertEqual(agent.toolEvents, [])
        XCTAssertNil(agent.startedAt)
        XCTAssertEqual(agent.state, .done)
        XCTAssertEqual(agent.model, "claude-opus-4-8")
        XCTAssertEqual(agent.reportedTokens, 900)
    }

    func testCompactionEntryRoundTripsAsItsOwnTranscriptKind() throws {
        var entry = TranscriptEntry(kind: .compaction, text: "Context compacted")
        entry.compactionTrigger = "auto"
        entry.compactionPreTokens = 180_000
        entry.compactionPostTokens = 52_000
        entry.compactionSummary = "Keep the storage invariant and continue the migration test."
        entry.compactionSummarySource = "claude_post_compact"
        entry.compactionSummaryTruncated = false
        entry.compactionAccess = .claudeSubscription
        entry.compactionSequence = 4

        let data = try JSONEncoder().encode(entry)
        let decoded = try JSONDecoder().decode(TranscriptEntry.self, from: data)

        XCTAssertEqual(decoded.kind, .compaction)
        XCTAssertEqual(decoded.compactionTrigger, "auto")
        XCTAssertEqual(decoded.compactionPreTokens, 180_000)
        XCTAssertEqual(decoded.compactionPostTokens, 52_000)
        XCTAssertEqual(decoded.compactionSummary, entry.compactionSummary)
        XCTAssertEqual(decoded.compactionSummarySource, "claude_post_compact")
        XCTAssertEqual(decoded.compactionSummaryTruncated, false)
        XCTAssertEqual(decoded.compactionAccess, .claudeSubscription)
        XCTAssertEqual(decoded.compactionSequence, 4)
    }

    func testAgentActivityTurnSummariesKeepProviderUsageSeparate() {
        let first = Date(timeIntervalSince1970: 100)
        let second = Date(timeIntervalSince1970: 200)
        let claude = ModelSelection(
            access: .claudeSubscription,
            modelID: "claude-opus")
        let codex = ModelSelection(
            access: .codexSubscription,
            modelID: "gpt-codex")
        let records: [AgentActivityRecord] = [
            .state(.model, turnID: "claude-turn", at: first).attributed(to: claude),
            .tokens(
                turnID: "claude-turn",
                input: 1_000,
                cachedInput: 800,
                output: 100,
                at: first.addingTimeInterval(1))
                .attributed(to: claude),
            .state(
                .completed,
                turnID: "claude-turn",
                at: first.addingTimeInterval(2))
                .attributed(to: claude),
            .state(.model, turnID: "codex-turn", at: second).attributed(to: codex),
            .tokens(
                turnID: "codex-turn",
                input: 400,
                output: 80,
                reasoningOutput: 20,
                at: second.addingTimeInterval(1))
                .attributed(to: codex),
        ]

        let summaries = agentActivityTurnSummaries(records)

        XCTAssertEqual(summaries.map(\.id), ["codex-turn", "claude-turn"])
        XCTAssertEqual(summaries[0].providerAccess, .codexSubscription)
        XCTAssertEqual(summaries[0].inputTokens, 400)
        XCTAssertEqual(summaries[0].outputTokens, 80)
        XCTAssertEqual(summaries[0].reasoningOutputTokens, 20)
        XCTAssertFalse(summaries[0].isTerminal)
        XCTAssertEqual(summaries[1].providerAccess, .claudeSubscription)
        XCTAssertEqual(summaries[1].cachedInputTokens, 800)
        XCTAssertTrue(summaries[1].isTerminal)
    }

    func testAgentActivityTurnSummaryUsesRootClockWhenALateChildRecordIsBackdated() {
        let oldTurnStart = Date(timeIntervalSince1970: 100)
        let currentTurnStart = Date(timeIntervalSince1970: 300)
        let records: [AgentActivityRecord] = [
            .state(.model, turnID: "old", at: oldTurnStart),
            .state(.completed, turnID: "old", at: oldTurnStart.addingTimeInterval(20)),
            .state(.model, turnID: "current", at: currentTurnStart),
            // A provider lifecycle update observed during the current turn can retain the child's
            // historical timestamp. It belongs to this turn but cannot define when the turn began.
            .state(
                .failed,
                turnID: "current",
                agentID: AgentActivityIdentity.subagent("provider-root"),
                at: oldTurnStart.addingTimeInterval(5)),
        ]

        let summaries = agentActivityTurnSummaries(records)

        XCTAssertEqual(summaries.map(\.id), ["current", "old"])
        XCTAssertEqual(summaries[0].startedAt, currentTurnStart)
    }

    func testAgentActivityTurnRemainsLiveUntilDelegatedLanesAreTerminal() {
        let start = Date(timeIntervalSince1970: 500)
        let childID = AgentActivityIdentity.subagent("child")
        var records: [AgentActivityRecord] = [
            .state(.model, turnID: "turn", at: start),
            .state(
                .model,
                turnID: "turn",
                agentID: childID,
                at: start.addingTimeInterval(1)),
            .state(.completed, turnID: "turn", at: start.addingTimeInterval(2)),
        ]

        XCTAssertFalse(agentActivityTurnSummaries(records)[0].isTerminal)

        records.append(.state(
            .completed,
            turnID: "turn",
            agentID: childID,
            at: start.addingTimeInterval(3)))
        XCTAssertTrue(agentActivityTurnSummaries(records)[0].isTerminal)
    }

    func testAgentActivityTurnTerminalStateCanonicalizesReconciledChildIDs() {
        let start = Date(timeIntervalSince1970: 600)
        let provisional = AgentActivityIdentity.subagent("child-thread")
        let canonical = AgentActivityIdentity.subagent("spawn-call")
        let records: [AgentActivityRecord] = [
            .state(.model, turnID: "turn", at: start),
            .state(
                .model,
                turnID: "turn",
                agentID: provisional,
                at: start.addingTimeInterval(1)),
            .state(
                .completed,
                turnID: "turn",
                agentID: canonical,
                at: start.addingTimeInterval(2)),
            .state(.completed, turnID: "turn", at: start.addingTimeInterval(3)),
        ]

        XCTAssertTrue(agentActivityTurnSummaries(
            records,
            aliases: [
                provisional: canonical,
                canonical: canonical,
        ])[0].isTerminal)
    }

    func testAgentActivityTurnUsesLifecycleArrivalOrderForBackdatedTerminalState() {
        let start = Date(timeIntervalSince1970: 700)
        let child = AgentActivityIdentity.subagent("child")
        let records: [AgentActivityRecord] = [
            .state(.model, turnID: "turn", at: start),
            .state(
                .tool,
                turnID: "turn",
                agentID: child,
                at: start.addingTimeInterval(20)),
            .state(.completed, turnID: "turn", at: start.addingTimeInterval(30)),
            // App Server supplied the child's historical end time after the newer-looking tool
            // sample. Append order is the lifecycle truth even though wall-clock sorting puts this
            // record first.
            .state(
                .completed,
                turnID: "turn",
                agentID: child,
                at: start.addingTimeInterval(10)),
        ]

        XCTAssertTrue(agentActivityTurnSummaries(records)[0].isTerminal)
    }

    func testAgentActivityRecordRoundTripsRouteAndInterjection() throws {
        let selection = ModelSelection(access: .openAIAPI, modelID: "gpt-5")
        let record = AgentActivityRecord.interjection(
            "Please also inspect the provider boundary.",
            disposition: .delivered,
            turnID: "turn-1",
            at: Date(timeIntervalSince1970: 123))
            .attributed(to: selection)

        let decoded = try JSONDecoder().decode(
            AgentActivityRecord.self,
            from: JSONEncoder().encode(record))

        XCTAssertEqual(decoded, record)
        XCTAssertEqual(decoded.providerAccess, .openAIAPI)
        XCTAssertEqual(decoded.modelID, "gpt-5")
        XCTAssertEqual(decoded.interjectionDisposition, .delivered)
        XCTAssertEqual(decoded.userEventKind, .guidance)
    }

    func testInitialPromptActivityRoundTripsAndLegacyGuidanceStillDecodes() throws {
        let record = AgentActivityRecord.initialPrompt(
            "Map the repository.",
            turnID: "turn-1",
            at: Date(timeIntervalSince1970: 456))
        let decoded = try JSONDecoder().decode(
            AgentActivityRecord.self,
            from: JSONEncoder().encode(record))

        XCTAssertEqual(decoded, record)
        XCTAssertEqual(decoded.kind, .interjection)
        XCTAssertEqual(decoded.userEventKind, .initialPrompt)
        XCTAssertNil(decoded.interjectionDisposition)

        let legacy = try JSONDecoder().decode(
            AgentActivityRecord.self,
            from: Data(#"{"kind":"interjection","detail":"Older guidance"}"#.utf8))
        XCTAssertEqual(legacy.kind, .interjection)
        XCTAssertNil(legacy.userEventKind)
    }

    func testOpeningActivityPublishesRootStateBeforePromptAndExcludesReviews() {
        let submittedAt = Date(timeIntervalSince1970: 789)
        let conversation = agentActivityOpeningRecords(
            prompt: "Trace the request.",
            turnID: "turn",
            submittedAt: submittedAt,
            includesInitialPrompt: true)

        XCTAssertEqual(conversation.map(\.kind), [.state, .interjection])
        XCTAssertEqual(conversation.first?.phase, .model)
        XCTAssertEqual(conversation.last?.userEventKind, .initialPrompt)
        XCTAssertEqual(conversation.map(\.at), [submittedAt, submittedAt])

        let review = agentActivityOpeningRecords(
            prompt: "Review uncommitted changes",
            turnID: "review",
            submittedAt: submittedAt,
            includesInitialPrompt: false)
        XCTAssertEqual(review.map(\.kind), [.state])
    }

    func testAgentActivityAliasesCollapseProvisionalAndAuthoritativeChildLanes() {
        let records: [AgentActivityRecord] = [
            .state(
                .model,
                turnID: "turn",
                agentID: AgentActivityIdentity.subagent("child-thread"),
                at: Date(timeIntervalSince1970: 1)),
            .state(
                .tool,
                turnID: "turn",
                agentID: AgentActivityIdentity.subagent("spawn-call"),
                at: Date(timeIntervalSince1970: 2)),
            .state(.model, turnID: "turn", at: Date(timeIntervalSince1970: 3)),
        ]
        let canonical = AgentActivityIdentity.subagent("spawn-call")
        let groups = canonicalizedAgentActivityGroups(records, aliases: [
            AgentActivityIdentity.subagent("child-thread"): canonical,
            canonical: canonical,
        ])

        XCTAssertEqual(Set(groups.keys), Set([AgentActivityIdentity.root, canonical]))
        XCTAssertEqual(groups[canonical]?.count, 2)
    }

    func testAgentActivityOrdinalsMatchCardsByStableStartOrder() {
        var later = SubagentRun(
            key: "later",
            subagentType: "general-purpose",
            task: "Later")
        later.startedAt = Date(timeIntervalSince1970: 20)
        var firstTie = SubagentRun(
            key: "a-first",
            subagentType: "general-purpose",
            task: "First")
        firstTie.startedAt = Date(timeIntervalSince1970: 10)
        var secondTie = SubagentRun(
            key: "b-second",
            subagentType: "general-purpose",
            task: "Second")
        secondTie.startedAt = Date(timeIntervalSince1970: 10)

        let ordinals = agentActivitySubagentOrdinals([
            later.key: later,
            secondTie.key: secondTie,
            firstTie.key: firstTie,
        ])

        XCTAssertEqual(ordinals[firstTie.key], 1)
        XCTAssertEqual(ordinals[secondTie.key], 2)
        XCTAssertEqual(ordinals[later.key], 3)
    }

    func testAgentActivityTraceBuildsIntervalsAndMovesTokensIntoSpanMetadata() {
        let start = Date(timeIntervalSince1970: 100)
        let agentID = AgentActivityIdentity.subagent("agent-1")
        let records: [AgentActivityRecord] = [
            .state(
                .model,
                turnID: "turn",
                agentID: agentID,
                detail: "Planning",
                at: start),
            .tokens(
                turnID: "turn",
                agentID: agentID,
                input: 100,
                cachedInput: 70,
                output: 10,
                at: start.addingTimeInterval(2)),
            .state(
                .tool,
                turnID: "turn",
                agentID: agentID,
                detail: "web.run",
                at: start.addingTimeInterval(5)),
            .tool(
                "web.run",
                turnID: "turn",
                agentID: agentID,
                at: start.addingTimeInterval(5)),
            .state(
                .model,
                turnID: "turn",
                agentID: agentID,
                detail: "Synthesis",
                at: start.addingTimeInterval(8)),
            .state(
                .completed,
                turnID: "turn",
                agentID: agentID,
                at: start.addingTimeInterval(10)),
        ]

        let spans = agentActivityTraceSpans(
            records,
            start: start,
            end: start.addingTimeInterval(10))

        XCTAssertEqual(spans.map(\.phase), [.model, .tool, .model, .completed])
        XCTAssertEqual(spans[0].duration, 5)
        XCTAssertEqual(spans[0].tokens.input, 100)
        XCTAssertEqual(spans[0].tokens.cachedInput, 70)
        XCTAssertEqual(spans[0].tokens.uncachedInput, 30)
        XCTAssertEqual(spans[0].tokens.processed, 110)
        XCTAssertEqual(spans[1].toolNames, ["web.run"])
        XCTAssertEqual(spans[1].title, "web.run")
        XCTAssertEqual(spans.last?.duration, 0)
    }

    /// Regression: aggregation used to merge "the next span of the same phase", which reached
    /// straight across the tool call sitting between two model spans. A real run of 35 requests
    /// collapsed into one unbroken bar labelled `Model activity ×35`, destroying every tool boundary
    /// — the alternation the trace exists to show.
    func testAgentActivityTraceNeverMergesModelSpansAcrossAnInterveningTool() {
        let start = Date(timeIntervalSince1970: 150)
        let records: [AgentActivityRecord] = [
            .state(.model, turnID: "turn", detail: "Plan", at: start),
            .state(
                .tool,
                turnID: "turn",
                detail: "Read",
                at: start.addingTimeInterval(10)),
            .state(
                .model,
                turnID: "turn",
                detail: "Synthesize",
                at: start.addingTimeInterval(12)),
            .state(
                .completed,
                turnID: "turn",
                at: start.addingTimeInterval(20)),
        ]
        let spans = agentActivityTraceSpans(
            records,
            start: start,
            end: start.addingTimeInterval(100))

        // The tool is only 2 seconds — two pixels at this zoom, well inside the old merge gap.
        let fit = agentActivityCoalescedTraceSpans(
            spans,
            start: start,
            end: start.addingTimeInterval(100),
            width: 100)

        XCTAssertEqual(fit.filter { $0.phase == .model }.count, 2)
        XCTAssertEqual(fit.filter { $0.phase == .model }.allSatisfy { $0.sourceCount == 1 }, true)
        XCTAssertEqual(fit.filter { $0.phase == .tool }.count, 1)
        XCTAssertEqual(fit.map(\.phase), [.model, .tool, .model, .completed])
    }

    func testAgentActivityTraceAggregatesAdjacentDenseSpansAndRevealsThemWhenZoomed() {
        let start = Date(timeIntervalSince1970: 150)
        // Parallel tool calls: genuinely consecutive, and far too short to draw separately at fit.
        let records: [AgentActivityRecord] = [
            .state(.tool, turnID: "turn", detail: "Read", at: start),
            .state(.tool, turnID: "turn", detail: "Grep", at: start.addingTimeInterval(1)),
            .state(.tool, turnID: "turn", detail: "Glob", at: start.addingTimeInterval(2)),
            .state(.model, turnID: "turn", detail: "Plan", at: start.addingTimeInterval(3)),
        ]
        let spans = agentActivityTraceSpans(
            records,
            start: start,
            end: start.addingTimeInterval(100))

        let fit = agentActivityCoalescedTraceSpans(
            spans, start: start, end: start.addingTimeInterval(100), width: 100)
        let zoomed = agentActivityCoalescedTraceSpans(
            spans, start: start, end: start.addingTimeInterval(100), width: 10_000)

        let fitTools = fit.filter { $0.phase == .tool }
        XCTAssertEqual(fitTools.count, 1)
        XCTAssertEqual(fitTools[0].sourceCount, 3)
        XCTAssertEqual(fitTools[0].title, "Tools ×3")
        // Zoomed in, every call is wide enough to read and stands on its own again.
        XCTAssertEqual(zoomed.filter { $0.phase == .tool }.count, 3)
    }

    func testAgentActivityTraceNeverSwallowsALegibleSpanOrGrowsPastTheWidthCap() {
        let start = Date(timeIntervalSince1970: 150)
        // Ten back-to-back model spans of 10s each, over a 100s window.
        let records: [AgentActivityRecord] = (0..<10).map { index in
            .state(
                .model,
                turnID: "turn",
                detail: "Step \(index)",
                at: start.addingTimeInterval(Double(index) * 10))
        }
        let spans = agentActivityTraceSpans(
            records, start: start, end: start.addingTimeInterval(100))
        XCTAssertEqual(spans.count, 10)

        // At 1000px each span is 100px — comfortably legible, so nothing may be merged away.
        let wide = agentActivityCoalescedTraceSpans(
            spans, start: start, end: start.addingTimeInterval(100), width: 1_000)
        XCTAssertEqual(wide.count, 10)
        XCTAssertEqual(wide.allSatisfy { $0.sourceCount == 1 }, true)

        // At 100px each span is 10px and merging begins, but a merged run must stop at the width
        // ceiling instead of becoming one featureless bar across the whole track.
        let narrow = agentActivityCoalescedTraceSpans(
            spans, start: start, end: start.addingTimeInterval(100), width: 100)
        XCTAssertGreaterThan(narrow.count, 1, "a single bar spanning the turn describes nothing")
        let duration = start.addingTimeInterval(100).timeIntervalSince(start)
        for span in narrow {
            let fraction = span.duration / duration
            XCTAssertLessThanOrEqual(
                fraction, 0.4 + 0.0001,
                "no aggregate may exceed the width cap")
        }
        XCTAssertEqual(narrow.reduce(0) { $0 + $1.sourceCount }, 10, "no span may be dropped")
    }

    func testAgentActivityTraceLabelsModelSpansWithWhatTheyProduced() {
        let start = Date(timeIntervalSince1970: 150)
        let records: [AgentActivityRecord] = [
            .state(.model, turnID: "turn", detail: "Responding", at: start),
            .tokens(turnID: "turn", input: 900, output: 3_400, at: start.addingTimeInterval(1)),
            .state(.tool, turnID: "turn", detail: "Read", at: start.addingTimeInterval(5)),
        ]
        let spans = agentActivityTraceSpans(
            records, start: start, end: start.addingTimeInterval(10))

        // What the model produced. "Responding" is dropped as noise — the lane colour says "model".
        XCTAssertEqual(spans[0].title, "3.4K out")
        XCTAssertEqual(spans[1].title, "Read")
    }

    /// The lane's colour already says "model". Repeating the runtime's state name on the bar was
    /// noise, and "Tool finished" — which names the *previous* event — made a blue model bar claim to
    /// be about a tool. That was the reported "blue bars say tool finished" confusion.
    func testAgentActivityTraceDoesNotLabelModelSpansWithRuntimeStateNames() {
        let start = Date(timeIntervalSince1970: 150)
        for noise in ["Tool finished", "Responding", "Turn started"] {
            let records: [AgentActivityRecord] = [
                .state(.model, turnID: "t", detail: noise, at: start),
                .state(.tool, turnID: "t", detail: "Read", at: start.addingTimeInterval(5)),
            ]
            let spans = agentActivityTraceSpans(
                records, start: start, end: start.addingTimeInterval(10))
            XCTAssertEqual(spans[0].title, "", noise)
        }

        // A genuinely distinctive state still earns its label.
        let reasoning: [AgentActivityRecord] = [
            .state(.model, turnID: "t", detail: "Reasoning", at: start),
            .state(.tool, turnID: "t", detail: "Read", at: start.addingTimeInterval(5)),
        ]
        XCTAssertEqual(
            agentActivityTraceSpans(reasoning, start: start, end: start.addingTimeInterval(10))[0]
                .title,
            "Reasoning")
    }

    /// The delegation tool is named `Agent`, so an orange "tool" bar labelled "Agent" read as a
    /// contradiction. Name the act, not the tool's identifier.
    func testAgentActivityTraceNamesDelegationRatherThanTheToolIdentifier() {
        XCTAssertEqual(traceToolLabel("Agent"), "Delegating")
        XCTAssertEqual(traceToolLabel("Task"), "Delegating")
        XCTAssertEqual(traceToolLabel("Bash"), "Bash")

        let start = Date(timeIntervalSince1970: 150)
        let records: [AgentActivityRecord] = [
            .state(.tool, turnID: "t", detail: "Agent", at: start),
            .tool("Agent", turnID: "t", agentID: AgentActivityIdentity.root, at: start),
            .state(.model, turnID: "t", detail: "Reasoning", at: start.addingTimeInterval(5)),
        ]
        let spans = agentActivityTraceSpans(
            records, start: start, end: start.addingTimeInterval(10))
        XCTAssertEqual(spans[0].title, "Delegating")
    }

    /// A bare "Responding · 2" sits beside "Tools ×3" and reads as a span count, not a token count.
    func testAgentActivityTraceOmitsTokenSuffixWhenItWouldReadAsACount() {
        let start = Date(timeIntervalSince1970: 150)
        let records: [AgentActivityRecord] = [
            .state(.model, turnID: "turn", detail: "Responding", at: start),
            .tokens(turnID: "turn", output: 2, at: start.addingTimeInterval(1)),
            .state(.tool, turnID: "turn", detail: "Read", at: start.addingTimeInterval(5)),
        ]
        let spans = agentActivityTraceSpans(
            records, start: start, end: start.addingTimeInterval(10))

        // Two generated tokens is not worth a label, and "· 2" beside "×3" aggregates would read as
        // a span count anyway. "Responding" itself is suppressed as noise.
        XCTAssertEqual(spans[0].title, "")
    }

    func testTraceLaneTaskSummaryCutsOnAWordBoundary() {
        XCTAssertEqual(traceLaneTaskSummary("Map the app architecture and data flows"),
                       "Map the app architecture…")
        XCTAssertEqual(traceLaneTaskSummary("Short task"), "Short task")
    }

    /// Regression: on a long turn the provider re-sends the same context on every call, so cached
    /// input dwarfed everything else (28.8M of 29.9M in one measured run) and the throughput chart
    /// became a picture of cache reads with real work reduced to invisible slivers.
    func testUsageBucketBreakdownSeparatesNewWorkFromCacheReads() {
        var tokens = AgentActivityTokenBreakdown()
        tokens.add(AgentActivityRecord.tokens(
            turnID: "t", input: 1_000_000, cachedInput: 980_000, output: 500))

        // What the bars must plot: the work, not the re-reads.
        XCTAssertEqual(tokens.uncachedInput, 20_000)
        XCTAssertEqual(tokens.generated, 500)
        // Cache stays available as a number even though it no longer drives the scale.
        XCTAssertEqual(tokens.cachedInput, 980_000)
        // And it is still counted exactly once inside input, never added on top.
        XCTAssertEqual(tokens.processed, 1_000_500)
    }

    func testAgentActivityUsageBucketsRespectAliasesAndDoNotDoubleCountCache() {
        let start = Date(timeIntervalSince1970: 200)
        let provisional = AgentActivityIdentity.subagent("child-thread")
        let canonical = AgentActivityIdentity.subagent("spawn-call")
        let records: [AgentActivityRecord] = [
            .tokens(
                turnID: "turn",
                agentID: provisional,
                input: 100,
                cachedInput: 70,
                output: 10,
                at: start.addingTimeInterval(2)),
            .tokens(
                turnID: "turn",
                total: 50,
                at: start.addingTimeInterval(7)),
        ]

        let filtered = agentActivityUsageBuckets(
            records,
            start: start,
            end: start.addingTimeInterval(10),
            count: 2,
            agentID: canonical,
            aliases: [provisional: canonical])
        let all = agentActivityUsageBuckets(
            records,
            start: start,
            end: start.addingTimeInterval(10),
            count: 2,
            aliases: [provisional: canonical])

        // Summed across buckets rather than read from a chosen index: this test is about aliasing
        // and not double-counting cache, and bucket boundaries are no longer an exact proportional
        // split of the span. They are quantized and anchored to `start` so a record keeps its
        // bucket while a turn runs — splitting proportionally is what made the graph slide.
        func total(_ buckets: [AgentActivityUsageBucket]) -> AgentActivityTokenBreakdown {
            buckets.reduce(into: AgentActivityTokenBreakdown()) { sum, bucket in
                sum.input += bucket.tokens.input
                sum.cachedInput += bucket.tokens.cachedInput
                sum.output += bucket.tokens.output
                sum.reasoningOutput += bucket.tokens.reasoningOutput
                sum.unclassified += bucket.tokens.unclassified
            }
        }
        let filteredTotal = total(filtered)
        XCTAssertEqual(filteredTotal.input, 100)
        XCTAssertEqual(filteredTotal.cachedInput, 70)
        XCTAssertEqual(filteredTotal.uncachedInput, 30)
        XCTAssertEqual(filteredTotal.processed, 110)
        XCTAssertEqual(filteredTotal.unclassified, 0, "the other agent's record must be excluded")
        XCTAssertEqual(total(all).unclassified, 50, "and included when unfiltered")
    }

    func testSubagentActivityUsesPerCallTokenBreakdownWhenAvailable() {
        let started = WorkflowUpdate([
            "phase": "started",
            "taskId": "child-1",
            "toolUseId": "spawn-1",
            "taskType": "codex_subagent",
            "subagentType": "Codex",
            "status": "running",
        ])
        let before: [String: SubagentRun] = [:]
        let running = applySubagentUpdate(before, started)
        let usage = WorkflowUpdate([
            "phase": "progress",
            "taskId": "child-1",
            "toolUseId": "spawn-1",
            "taskType": "codex_subagent",
            "subagentType": "Codex",
            "providerQuerySequence": 4,
            "usage": [
                "totalTokens": 1_500,
                "inputTokens": 200,
                "cachedInputTokens": 50,
                "outputTokens": 100,
            ],
        ])
        let after = applySubagentUpdate(running, usage)

        let records = agentActivityRecords(
            beforeSubagents: running,
            afterSubagents: after,
            beforeRuns: [:],
            afterRuns: [:],
            update: usage,
            turnID: "root-turn",
            observedAt: Date(timeIntervalSince1970: 456))
        let sample = records.first { $0.kind == .tokens }

        XCTAssertEqual(sample?.agentID, AgentActivityIdentity.subagent("child-1"))
        XCTAssertEqual(sample?.inputTokens, 200)
        XCTAssertEqual(sample?.cachedInputTokens, 50)
        XCTAssertEqual(sample?.outputTokens, 100)
        XCTAssertEqual(sample?.providerQuerySequence, 4)
        XCTAssertEqual(sample?.measurementProvenance, .providerReport)
        XCTAssertEqual(sample?.measurementScope, .agent)
        XCTAssertEqual(sample?.measurementAggregation, .delta)
        XCTAssertNil(sample?.totalTokens, "A real breakdown must not also be plotted as aggregate-only.")
    }

    func testTargetedStopHealsTerminalWorkflowWithLiveChildAndClosesOnlyItsLane() {
        let stoppedAt = Date(timeIntervalSince1970: 2_000)
        var liveChild = WorkflowAgent(
            index: 0,
            label: "finder",
            phaseIndex: 0,
            phaseTitle: "Find",
            state: .progress)
        liveChild.startedAt = Date(timeIntervalSince1970: 1_900)
        var inconsistent = WorkflowRun(runKey: "target", status: .completed)
        inconsistent.runTaskId = "target-task"
        inconsistent.agents = ["0:0": liveChild]

        var siblingChild = WorkflowAgent(
            index: 0,
            label: "reader",
            phaseIndex: 0,
            phaseTitle: "Read",
            state: .progress)
        siblingChild.startedAt = Date(timeIntervalSince1970: 1_910)
        var sibling = WorkflowRun(runKey: "sibling", status: .running)
        sibling.runTaskId = "sibling-task"
        sibling.agents = ["0:0": siblingChild]

        var runs = ["target": inconsistent, "sibling": sibling]
        var subagents: [String: SubagentRun] = [:]
        var activity: [AgentActivityRecord] = [
            .state(
                .tool,
                turnID: "target-turn",
                agentID: AgentActivityIdentity.workflow(
                    runKey: "target",
                    agentKey: "0:0"),
                detail: "Read",
                at: Date(timeIntervalSince1970: 1_950)),
            .state(
                .model,
                turnID: "sibling-turn",
                agentID: AgentActivityIdentity.workflow(
                    runKey: "sibling",
                    agentKey: "0:0"),
                at: Date(timeIntervalSince1970: 1_960)),
        ]

        XCTAssertTrue(stopDelegatedRunState(
            matching: "target-task",
            workflowRuns: &runs,
            subagents: &subagents,
            agentActivity: &activity,
            at: stoppedAt))

        XCTAssertEqual(
            runs["target"]?.status,
            .completed,
            "the terminal aggregate remains monotonic while its stale live child is healed")
        XCTAssertEqual(runs["target"]?.endedAt, stoppedAt)
        XCTAssertEqual(runs["target"]?.agents["0:0"]?.state, .stopped)
        XCTAssertEqual(runs["target"]?.agents["0:0"]?.endedAt, stoppedAt)
        XCTAssertEqual(runs["sibling"]?.status, .running)
        XCTAssertEqual(runs["sibling"]?.agents["0:0"]?.state, .progress)
        XCTAssertNil(runs["sibling"]?.endedAt)

        let stoppedRecords = activity.filter {
            $0.kind == .state && $0.phase == .stopped
        }
        XCTAssertEqual(stoppedRecords.count, 1)
        XCTAssertEqual(stoppedRecords.first?.turnID, "target-turn")
        XCTAssertEqual(
            stoppedRecords.first?.agentID,
            AgentActivityIdentity.workflow(runKey: "target", agentKey: "0:0"))

        let activityCount = activity.count
        XCTAssertFalse(stopDelegatedRunState(
            matching: "target-task",
            workflowRuns: &runs,
            subagents: &subagents,
            agentActivity: &activity,
            at: stoppedAt.addingTimeInterval(10)))
        XCTAssertEqual(activity.count, activityCount, "a repeated targeted Stop is idempotent")

        runs = applyWorkflowUpdate(
            runs,
            WorkflowUpdate([
                "phase": "progress",
                "taskId": "target-task",
                "status": "running",
                "workflowProgress": [[
                    "type": "workflow_agent",
                    "index": 0,
                    "phaseIndex": 0,
                    "state": "progress",
                    "resultPreview": "late metadata",
                ]],
            ]),
            sessionId: "s")
        XCTAssertEqual(runs["target"]?.status, .completed)
        XCTAssertEqual(runs["target"]?.agents["0:0"]?.state, .stopped)
        XCTAssertEqual(
            runs["target"]?.agents["0:0"]?.resultPreview,
            "late metadata",
            "late metadata is retained without reopening the stopped child")
    }

    func testStoppedWorkflowAndChildAbsorbLateMetadataWithoutResurrection() {
        var child = WorkflowAgent(
            index: 0,
            label: "finder",
            phaseIndex: 0,
            phaseTitle: "Find",
            state: .stopped)
        child.endedAt = Date(timeIntervalSince1970: 100)
        var run = WorkflowRun(runKey: "run-1", status: .stopped)
        run.endedAt = Date(timeIntervalSince1970: 100)
        run.agents = ["0:0": child]

        var runs = applyWorkflowUpdate(
            ["run-1": run],
            WorkflowUpdate([
                "phase": "progress",
                "taskId": "run-1",
                "toolUseId": "run-1",
                "status": "running",
                "summary": "late detail",
                "usage": ["totalTokens": 1_200],
                "workflowProgress": [[
                    "type": "workflow_agent",
                    "index": 0,
                    "phaseIndex": 0,
                    "state": "progress",
                    "tokens": 900,
                    "resultPreview": "buffered result",
                ]],
            ]),
            sessionId: "s")

        XCTAssertEqual(runs["run-1"]?.status, .stopped)
        XCTAssertEqual(runs["run-1"]?.agents["0:0"]?.state, .stopped)
        XCTAssertEqual(runs["run-1"]?.summary, "late detail")
        XCTAssertEqual(runs["run-1"]?.usage?.totalTokens, 1_200)
        XCTAssertEqual(runs["run-1"]?.agents["0:0"]?.tokens, 900)
        XCTAssertEqual(runs["run-1"]?.agents["0:0"]?.resultPreview, "buffered result")

        runs = applyWorkflowUpdate(
            runs,
            WorkflowUpdate([
                "phase": "updated",
                "taskId": "run-1",
                "toolUseId": "run-1",
                "status": "completed",
                "workflowProgress": [[
                    "type": "workflow_agent",
                    "index": 0,
                    "phaseIndex": 0,
                    "state": "done",
                ]],
            ]),
            sessionId: "s")
        XCTAssertEqual(runs["run-1"]?.status, .stopped)
        XCTAssertEqual(runs["run-1"]?.agents["0:0"]?.state, .stopped)
    }

    func testTerminalAggregateAllowsLateTerminalChildButIgnoresLateActiveState() {
        var run = WorkflowRun(runKey: "run-1", status: .completed)
        run.runTaskId = "run-1"
        run.agents = [
            "0:0": WorkflowAgent(
                index: 0,
                label: "first",
                phaseIndex: 0,
                phaseTitle: "Run",
                state: .start),
            "0:1": WorkflowAgent(
                index: 1,
                label: "second",
                phaseIndex: 0,
                phaseTitle: "Run",
                state: .progress),
        ]

        var runs = applyWorkflowUpdate(
            ["run-1": run],
            WorkflowUpdate([
                "phase": "updated",
                "taskId": "run-1",
                "status": "completed",
                "workflowProgress": [
                    [
                        "type": "workflow_agent",
                        "index": 0,
                        "phaseIndex": 0,
                        "state": "progress",
                        "tokens": 400,
                    ],
                    [
                        "type": "workflow_agent",
                        "index": 1,
                        "phaseIndex": 0,
                        "state": "failed",
                        "resultPreview": "late failure",
                    ],
                ],
            ]),
            sessionId: "s")

        XCTAssertEqual(
            runs["run-1"]?.agents["0:0"]?.state,
            .start,
            "a terminal aggregate rejects buffered active lifecycle replay")
        XCTAssertEqual(
            runs["run-1"]?.agents["0:0"]?.tokens,
            400,
            "late metadata is still absorbed")
        XCTAssertEqual(runs["run-1"]?.agents["0:1"]?.state, .failed)
        XCTAssertNotNil(runs["run-1"]?.agents["0:1"]?.endedAt)

        runs = applyWorkflowUpdate(
            runs,
            WorkflowUpdate([
                "phase": "updated",
                "taskId": "run-1",
                "status": "completed",
                "workflowProgress": [[
                    "type": "workflow_agent",
                    "index": 0,
                    "phaseIndex": 0,
                    "state": "done",
                    "resultPreview": "late success",
                ]],
            ]),
            sessionId: "s")
        XCTAssertEqual(runs["run-1"]?.agents["0:0"]?.state, .done)
        XCTAssertEqual(runs["run-1"]?.agents["0:0"]?.resultPreview, "late success")
        XCTAssertNotNil(runs["run-1"]?.agents["0:0"]?.endedAt)
    }

    func testStoppedSubagentAbsorbsLateMetricsButNotCompletion() {
        var child = SubagentRun(key: "spawn-1", subagentType: "Codex", task: "inspect")
        child.taskId = "child-1"
        child.status = .stopped
        child.endedAt = Date(timeIntervalSince1970: 100)

        let updated = applySubagentUpdate(
            ["spawn-1": child],
            WorkflowUpdate([
                "phase": "updated",
                "taskId": "child-1",
                "toolUseId": "spawn-1",
                "taskType": "codex_subagent",
                "status": "completed",
                "summary": "late summary",
                "resultPreview": "late result",
                "usage": ["totalTokens": 700, "toolUses": 4],
            ]))

        XCTAssertEqual(updated["spawn-1"]?.status, .stopped)
        XCTAssertEqual(updated["spawn-1"]?.summary, "late summary")
        XCTAssertEqual(updated["spawn-1"]?.resultPreview, "late result")
        XCTAssertEqual(updated["spawn-1"]?.tokens, 700)
        XCTAssertEqual(updated["spawn-1"]?.toolUses, 4)
        XCTAssertEqual(updated["spawn-1"]?.endedAt, Date(timeIntervalSince1970: 100))
    }

    func testCompletedWorkflowMayRefineToFailureButFailedCannotBecomeCompleted() {
        var completed = WorkflowRun(runKey: "run-1", status: .completed)
        completed.endedAt = Date(timeIntervalSince1970: 100)
        var runs = applyWorkflowUpdate(
            ["run-1": completed],
            WorkflowUpdate([
                "phase": "updated",
                "taskId": "run-1",
                "status": "failed",
                "error": "late authoritative failure",
            ]),
            sessionId: "s")
        XCTAssertEqual(runs["run-1"]?.status, .failed)

        runs = applyWorkflowUpdate(
            runs,
            WorkflowUpdate([
                "phase": "updated",
                "taskId": "run-1",
                "status": "completed",
            ]),
            sessionId: "s")
        XCTAssertEqual(runs["run-1"]?.status, .failed)
    }
}

/// A child's tool call has to carry what it acted on, all the way to the record.
///
/// `WorkflowUpdate` is parsed by hand from a dictionary, so adding a property does not make it
/// arrive — the field was declared and read while the parse line was missing, and every child tool
/// record came through with no target. The compiler cannot catch that, so a test must.
final class SubagentToolTargetTests: XCTestCase {
    func testWorkflowUpdateParsesTheToolTarget() {
        let update = WorkflowUpdate([
            "phase": "progress",
            "taskId": "thread-1",
            "taskType": "codex_subagent",
            "subagentType": "Codex",
            "toolEvent": "Bash",
            "toolTarget": "/bin/zsh -lc 'git log --oneline -2'",
        ])
        XCTAssertEqual(update.toolEvent, "Bash")
        XCTAssertEqual(
            update.toolTarget,
            "/bin/zsh -lc 'git log --oneline -2'",
            "the command has to survive the hand-rolled parse")
    }

    func testAToolEventWithoutATargetStaysNil() {
        let update = WorkflowUpdate([
            "phase": "progress",
            "taskId": "thread-1",
            "toolEvent": "Bash",
        ])
        XCTAssertEqual(update.toolEvent, "Bash")
        XCTAssertNil(update.toolTarget)
    }

    /// The target is what lets a child's mix name real programs instead of one flat "Bash".
    func testChildToolEventsNameTheProgramTheyRan() {
        let events = [
            SubagentToolEvent(name: "Bash", target: "/bin/zsh -lc 'git log --oneline -2'"),
            SubagentToolEvent(name: "Bash", target: #"/bin/zsh -lc "find app -name '*.swift'""#),
            SubagentToolEvent(name: "Bash", target: "/bin/zsh -lc 'wc -l Package.swift'"),
        ]
        let names = events.map { agentToolCompositionName($0.name, target: $0.target) }
        XCTAssertEqual(names, ["git", "find", "wc"])
    }

    /// An older persisted event has no target and must still decode and label.
    func testLegacyToolEventWithoutTargetStillDecodes() throws {
        let json = Data(#"{"name":"Bash","at":760000000}"#.utf8)
        let event = try JSONDecoder().decode(SubagentToolEvent.self, from: json)
        XCTAssertEqual(event.name, "Bash")
        XCTAssertNil(event.target)
        XCTAssertEqual(agentToolCompositionName(event.name, target: event.target), "Bash")
    }
}

/// FR-202 — one failed descendant used to drag its whole tree into the section, so a single failure
/// read as a large group of troubled agents. The section is about what did not finish.
final class SubagentAttentionPruningTests: XCTestCase {
    private func agent(
        _ key: String, parent: String? = nil, status: WorkflowStatus = .completed
    ) -> SubagentRun {
        var run = SubagentRun(
            key: key, subagentType: "Explore", task: key,
            startedAt: Date(timeIntervalSince1970: 1))
        run.status = status
        run.parentToolUseId = parent
        return run
    }

    func testOnlyTheFailedAgentAndItsAncestorsSurvive() throws {
        // parent → (healthy, failing → (grandchild)) plus a healthy sibling branch.
        let subs = [
            "p": agent("p"),
            "healthy": agent("healthy", parent: "p"),
            "failing": agent("failing", parent: "p", status: .failed),
            "grandchild": agent("grandchild", parent: "failing"),
            "other": agent("other", parent: "p"),
        ]
        let root = try XCTUnwrap(subagentForest(subs).first)
        XCTAssertEqual(root.count, 5)
        XCTAssertTrue(root.hasAttention)

        let pruned = try XCTUnwrap(root.prunedToAttention())
        XCTAssertEqual(pruned.sub.key, "p", "the ancestor stays, so the failure has a place")
        XCTAssertEqual(
            pruned.children.map(\.sub.key), ["failing"],
            "healthy siblings are not what this section is about")
        XCTAssertTrue(
            pruned.children.first?.children.isEmpty == true,
            "a healthy child of the failed agent is not itself a failure")
        XCTAssertEqual(pruned.count, 2, "the count reflects what is shown, not the whole tree")
    }

    func testATreeWithNothingFailedPrunesAway() {
        let subs = ["p": agent("p"), "c": agent("c", parent: "p")]
        XCTAssertNil(subagentForest(subs).first?.prunedToAttention())
    }

    func testAFailedRootWithHealthyChildrenKeepsOnlyItself() throws {
        let subs = [
            "p": agent("p", status: .failed),
            "c": agent("c", parent: "p"),
        ]
        let pruned = try XCTUnwrap(subagentForest(subs).first?.prunedToAttention())
        XCTAssertEqual(pruned.sub.key, "p")
        XCTAssertTrue(pruned.children.isEmpty)
    }

    func testEveryFailureIsKeptWhenSeveralBranchesFail() throws {
        let subs = [
            "p": agent("p"),
            "a": agent("a", parent: "p", status: .failed),
            "b": agent("b", parent: "p"),
            "b1": agent("b1", parent: "b", status: .killed),
        ]
        let pruned = try XCTUnwrap(subagentForest(subs).first?.prunedToAttention())
        XCTAssertEqual(pruned.children.map(\.sub.key).sorted(), ["a", "b"])
        XCTAssertEqual(
            pruned.children.first(where: { $0.sub.key == "b" })?.children.map(\.sub.key), ["b1"],
            "a stopped grandchild is reached through its parent, not dropped")
    }

    /// The section name must not promise an action nobody can take.
    func testTheSectionSaysWhatHappenedRatherThanAskingForAnAction() {
        XCTAssertEqual(AppKitAgentsGroup.attention.title, "Didn't finish")
        XCTAssertNotEqual(AppKitAgentsGroup.attention.title, "Needs attention")
    }
}
