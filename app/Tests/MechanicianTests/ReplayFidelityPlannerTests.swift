import XCTest
@testable import Mechanician

final class ReplayFidelityPlannerTests: XCTestCase {
    private func conversation(
        messages: [TranscriptEntry],
        artifacts: [Artifact] = [],
        workflowRuns: [String: WorkflowRun] = [:],
        subagents: [String: SubagentRun] = [:],
        agentActivity: [AgentActivityRecord] = []
    ) -> Conversation {
        Conversation(
            title: "Replay fixture",
            cwd: "",
            sdkSessionId: nil,
            messages: messages,
            updatedAt: Date(timeIntervalSinceReferenceDate: 100),
            artifacts: artifacts,
            workflowRuns: workflowRuns,
            subagents: subagents,
            agentActivity: agentActivity)
    }

    func testPayloadExactlyRetainsCurrentRoleTextSelectionAndArrayOrder() {
        var queued = TranscriptEntry(kind: .user, text: "queued")
        queued.guidanceState = .queued
        var sending = TranscriptEntry(kind: .user, text: "sending")
        sending.guidanceState = .sending
        var cancelled = TranscriptEntry(kind: .user, text: "cancelled")
        cancelled.guidanceState = .cancelled
        var delivered = TranscriptEntry(kind: .user, text: "delivered")
        delivered.guidanceState = .delivered
        var sentNext = TranscriptEntry(kind: .user, text: "sent next")
        sentNext.guidanceState = .sentNext
        var supersededUser = TranscriptEntry(kind: .user, text: "withdrawn user")
        supersededUser.supersessionEventID = UUID()
        var supersededAssistant = TranscriptEntry(kind: .assistant, text: "withdrawn assistant")
        supersededAssistant.supersededByEntryID = UUID()

        let fixture = conversation(messages: [
            TranscriptEntry(kind: .system, text: "system context"),
            TranscriptEntry(kind: .user, text: "first"),
            TranscriptEntry(kind: .assistant, text: "answer"),
            queued,
            sending,
            cancelled,
            delivered,
            TranscriptEntry(kind: .tool, text: "Bash"),
            sentNext,
            supersededUser,
            supersededAssistant,
            TranscriptEntry(kind: .assistant, text: ""),
        ])
        var projectedUserTexts: [String] = []

        let plan = ReplayFidelityPlanner.plan(for: fixture) { text in
            projectedUserTexts.append(text)
            return "projected:\(text)"
        }

        XCTAssertEqual(projectedUserTexts, ["first", "delivered", "sent next"])
        XCTAssertEqual(plan.providerPayload, [
            ["role": "user", "text": "projected:first"],
            ["role": "assistant", "text": "answer"],
            ["role": "user", "text": "projected:delivered"],
            ["role": "user", "text": "projected:sent next"],
            ["role": "assistant", "text": ""],
        ])
    }

    func testPlainDialogIsEquivalent() {
        let fixture = conversation(messages: [
            TranscriptEntry(kind: .user, text: "Question"),
            TranscriptEntry(kind: .assistant, text: "Answer"),
        ])

        let plan = ReplayFidelityPlanner.plan(for: fixture)

        XCTAssertTrue(plan.isEquivalent)
        XCTAssertEqual(plan.degradationCategories, [])
    }


    func testExplicitReplaySliceUsesOnlyThoseRowsWhileRetainingOtherFactDiagnostics() {
        let retained = [
            TranscriptEntry(kind: .user, text: "Retained question"),
            TranscriptEntry(kind: .assistant, text: "Retained answer"),
        ]
        let fixture = conversation(messages: retained + [
            TranscriptEntry(kind: .tool, text: "Read"),
            TranscriptEntry(kind: .assistant, text: "Discarded branch"),
        ])

        let plan = ReplayFidelityPlanner.plan(for: fixture, replaying: retained)

        XCTAssertEqual(plan.providerPayload, [
            ["role": "user", "text": "Retained question"],
            ["role": "assistant", "text": "Retained answer"],
        ])
        XCTAssertEqual(plan.degradationCategories, [.toolLifecycle])
    }

    func testContinuationDiagnosticNeverChangesPayloadAndFailsClosedOnDrift() {
        let payload = [["role": "user", "text": "Retained question"]]
        let plan = ReplayFidelityPlan(
            providerPayload: payload,
            degradationCategories: [.toolLifecycle])

        XCTAssertNil(AgentBridge.continuationDiagnosticCategories(
            planned: plan,
            providerPayload: payload,
            isFreshSessionReplay: false))
        XCTAssertEqual(AgentBridge.continuationDiagnosticCategories(
            planned: plan,
            providerPayload: payload,
            isFreshSessionReplay: true), [.toolLifecycle])
        XCTAssertEqual(AgentBridge.continuationDiagnosticCategories(
            planned: plan,
            providerPayload: [["role": "user", "text": "Preserved staged bytes"]],
            isFreshSessionReplay: true), [
                .toolLifecycle,
                .unknown("provider-replay-source-diverged"),
            ])
        XCTAssertEqual(plan.providerPayload, payload)
    }

    func testAllRetainedButUnreplayedFactClassesProduceStableExactCategories() throws {
        var withdrawn = TranscriptEntry(kind: .assistant, text: "withdrawn")
        withdrawn.supersessionEventID = UUID()
        var composerMedia = TranscriptEntry(kind: .user, text: "attached image")
        composerMedia.imagePaths = ["image.png"]
        var tool = TranscriptEntry(kind: .tool, text: "Screenshot")
        tool.toolImage = ToolImageReference(
            fileName: "00000000-0000-0000-0000-000000000001.png",
            width: 800,
            height: 600)
        let review = TranscriptEntry(kind: .review, text: "review finding")
        let reduction = try XCTUnwrap(AgentActivityRecord.historyReduction(
            turnID: "turn",
            omittedMessages: 3,
            shortenedMessages: nil,
            reason: "fresh_session_replay"))
        let activityTool = AgentActivityRecord.tool(
            "Read",
            turnID: "turn",
            agentID: AgentActivityIdentity.root)
        let subagent = SubagentRun(
            key: "child",
            subagentType: "Explore",
            task: "Inspect files",
            toolEvents: [SubagentToolEvent(name: "Glob", target: "*.swift")])
        let workflow = WorkflowRun(
            runKey: "workflow",
            agents: [
                "1:1": WorkflowAgent(
                    index: 1,
                    label: "Child",
                    phaseIndex: 1,
                    phaseTitle: "Inspect",
                    state: .done,
                    toolEvents: [SubagentToolEvent(name: "Read", target: "README")]),
            ])
        let artifact = Artifact(title: "Report", type: "markdown", source: "# Result")

        let fixture = conversation(
            messages: [
                TranscriptEntry(kind: .system, text: "provider failure"),
                TranscriptEntry(kind: .user, text: "Question"),
                withdrawn,
                review,
                tool,
                TranscriptEntry(kind: .permission, text: "Allow Write?"),
                TranscriptEntry(kind: .question, text: "Which target?"),
                TranscriptEntry(kind: .compaction, text: "Context compacted"),
                composerMedia,
            ],
            artifacts: [artifact],
            workflowRuns: [workflow.runKey: workflow],
            subagents: [subagent.key: subagent],
            agentActivity: [reduction, activityTool])

        let plan = ReplayFidelityPlanner.plan(for: fixture)

        XCTAssertFalse(plan.isEquivalent)
        XCTAssertEqual(plan.degradationCategories, [
            .withdrawnOrSupersededContent,
            .systemContext,
            .providerReview,
            .toolLifecycle,
            .interactionLifecycle,
            .compaction,
            .historyReduction,
            .agentLifecycle,
            .workflowLifecycle,
            .artifactContent,
            .media,
        ])
    }

    func testCategoriesDeduplicateAcrossMirrorsAndStayDeterministic() {
        let toolActivity = AgentActivityRecord.tool(
            "Read",
            turnID: "turn",
            agentID: AgentActivityIdentity.root)
        let fixture = conversation(
            messages: [
                TranscriptEntry(kind: .tool, text: "Read one"),
                TranscriptEntry(kind: .tool, text: "Read two"),
                TranscriptEntry(kind: .permission, text: "Allow?"),
                TranscriptEntry(kind: .question, text: "Choose?"),
            ],
            agentActivity: [toolActivity, toolActivity])

        let first = ReplayFidelityPlanner.plan(for: fixture).degradationCategories
        let second = ReplayFidelityPlanner.plan(for: fixture).degradationCategories

        XCTAssertEqual(first, [
            .toolLifecycle,
            .interactionLifecycle,
            .agentLifecycle,
        ])
        XCTAssertEqual(second, first)
    }

    func testLegacyAbsentOptionalFactsDoNotInventDegradation() throws {
        let original = conversation(messages: [
            TranscriptEntry(kind: .user, text: "Legacy question"),
            TranscriptEntry(kind: .assistant, text: "Legacy answer"),
        ])
        let encoded = try JSONEncoder().encode(original)
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        for key in ["artifacts", "workflowRuns", "subagents", "agentActivity"] {
            object.removeValue(forKey: key)
        }
        let legacy = try JSONSerialization.data(withJSONObject: object)
        let decoded = try JSONDecoder().decode(Conversation.self, from: legacy)

        let plan = ReplayFidelityPlanner.plan(for: decoded)

        XCTAssertTrue(plan.isEquivalent)
        XCTAssertEqual(plan.providerPayload, [
            ["role": "user", "text": "Legacy question"],
            ["role": "assistant", "text": "Legacy answer"],
        ])
    }

    func testUnknownFutureCategoryRoundTripsAndSortsAfterKnownCategories() throws {
        let data = Data("\"future-provider-state-omitted\"".utf8)
        let decoded = try JSONDecoder().decode(ReplayDegradationCategory.self, from: data)

        XCTAssertEqual(decoded, .unknown("future-provider-state-omitted"))
        XCTAssertEqual(try JSONEncoder().encode(decoded), data)
        XCTAssertEqual(
            ReplayDegradationCategory.ordered([
                decoded,
                .media,
                .toolLifecycle,
                .unknown("another-future-category"),
                .toolLifecycle,
            ]),
            [
                .toolLifecycle,
                .media,
                .unknown("another-future-category"),
                .unknown("future-provider-state-omitted"),
            ])
    }

    func testDecodedPlanToleratesLegacyMissingDiagnosticsAndNormalizesNewOnes() throws {
        let legacy = Data(#"{"providerPayload":[{"role":"user","text":"hello"}]}"#.utf8)
        let legacyPlan = try JSONDecoder().decode(ReplayFidelityPlan.self, from: legacy)
        XCTAssertTrue(legacyPlan.isEquivalent)

        let unordered = Data(
            #"{"providerPayload":[],"degradationCategories":["media-omitted","tool-lifecycle-omitted","media-omitted"]}"#.utf8)
        let normalized = try JSONDecoder().decode(ReplayFidelityPlan.self, from: unordered)
        XCTAssertEqual(normalized.degradationCategories, [.toolLifecycle, .media])
    }
}
