import XCTest
@testable import Mechanician

/// A Workflow, or a Task started in the background, keeps running inside the provider session after
/// the turn that started it ends — but the session's permission context does not, so every tool call
/// they make afterwards is refused by the engine with a message that reads as though the person
/// denied it. Nothing in Mechanician denies them and nothing logs it. Say so instead.
@MainActor
final class BackgroundAgentsOutlivingTurnTests: XCTestCase {
    private var roots: [URL] = []

    override func tearDown() {
        for root in roots { try? FileManager.default.removeItem(at: root) }
        roots = []
        super.tearDown()
    }

    private func makeBridge() -> (AgentBridge, ConversationStore) {
        let storeRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("bg-outlive-store-\(UUID().uuidString)")
        let bridgeRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("bg-outlive-bridge-\(UUID().uuidString)")
        roots.append(contentsOf: [storeRoot, bridgeRoot])
        let store = ConversationStore(
            appSupportBaseOverride: storeRoot,
            watchesDirectory: false)
        let bridge = AgentBridge(
            settingsBaseOverride: bridgeRoot,
            environmentOverride: [:],
            conversationStoreOverride: store)
        bridge.currentID = UUID()
        return (bridge, store)
    }

    private func run(
        _ key: String,
        _ status: WorkflowStatus,
        agents: [String: WorkflowAgent] = [:]
    ) -> WorkflowRun {
        var run = WorkflowRun(runKey: key)
        run.status = status
        run.agents = agents
        return run
    }

    private func agent(
        _ index: Int,
        _ state: WorkflowAgentState,
        agentId: String? = nil
    ) -> WorkflowAgent {
        WorkflowAgent(
            index: index,
            label: "agent-\(index)",
            phaseIndex: 0,
            phaseTitle: "Review",
            state: state,
            agentId: agentId)
    }

    private func child(
        _ key: String,
        _ status: WorkflowStatus,
        taskId: String? = nil
    ) -> SubagentRun {
        var child = SubagentRun(key: key, subagentType: "Explore", task: "research")
        child.status = status
        child.taskId = taskId
        return child
    }

    private func said(_ bridge: AgentBridge) -> [TranscriptEntry] {
        bridge.entries.filter { $0.kind == .system }
    }

    // MARK: - What counts

    /// The shape that produced the bug report. A workflow aggregate can arrive terminal before its
    /// last child does, so reading aggregate statuses alone reports zero in exactly the case this
    /// disclosure exists to describe.
    func testAWorkflowWhoseAggregateWentTerminalBeforeItsChildrenStillCounts() {
        let (bridge, _) = makeBridge()
        bridge.workflowRuns = [
            "a": run("a", .completed, agents: [
                "0:1": agent(1, .progress),
                "0:2": agent(2, .progress),
                "0:3": agent(3, .done),
            ]),
        ]

        XCTAssertEqual(bridge.outstandingBackgroundAgentCount(in: bridge.currentID!), 2)
    }

    /// A live run that has not reported its child graph yet still owns work.
    func testALiveRunWithNoChildrenYetCountsAsOne() {
        let (bridge, _) = makeBridge()
        bridge.workflowRuns = ["a": run("a", .running)]

        XCTAssertEqual(bridge.outstandingBackgroundAgentCount(in: bridge.currentID!), 1)
    }

    /// Providers mirror one child as both a standalone subagent and a workflow member. Counting
    /// storage rows would say "2 background agents" about one agent.
    func testOneAgentMirroredTwiceIsCountedOnce() {
        let (bridge, _) = makeBridge()
        bridge.subagents = ["c": child("c", .running, taskId: "provider-1")]
        bridge.workflowRuns = [
            "a": run("a", .completed, agents: [
                "0:1": agent(1, .progress, agentId: "provider-1"),
            ]),
        ]

        XCTAssertEqual(bridge.outstandingBackgroundAgentCount(in: bridge.currentID!), 1)
    }

    func testAFinishedRunCountsForNothing() {
        let (bridge, _) = makeBridge()
        bridge.workflowRuns = [
            "a": run("a", .completed, agents: ["0:1": agent(1, .done)]),
        ]
        bridge.subagents = ["c": child("c", .completed)]

        XCTAssertEqual(bridge.outstandingBackgroundAgentCount(in: bridge.currentID!), 0)
    }

    // MARK: - What it says

    func testATurnEndingWithBackgroundAgentsRunningSaysSo() {
        let (bridge, _) = makeBridge()
        bridge.workflowRuns = ["a": run("a", .running)]
        bridge.subagents = ["c": child("c", .running)]

        bridge.discloseBackgroundAgentsOutlivingTurnForTesting(conversationID: bridge.currentID!)

        XCTAssertEqual(said(bridge).count, 1)
        let text = said(bridge).first?.text ?? ""
        XCTAssertTrue(text.hasPrefix("2 background agents were still running"), text)
        XCTAssertTrue(text.contains("will be refused"), text)
        // The person needs the remedy, not just the diagnosis.
        XCTAssertTrue(text.contains("stays open until it finishes"), text)
    }

    func testASingleAgentReadsAsOne() {
        let (bridge, _) = makeBridge()
        bridge.workflowRuns = ["a": run("a", .running)]

        bridge.discloseBackgroundAgentsOutlivingTurnForTesting(conversationID: bridge.currentID!)

        XCTAssertTrue(
            (said(bridge).first?.text ?? "").hasPrefix("1 background agent was still running"),
            said(bridge).first?.text ?? "")
    }

    func testTheOrdinaryTurnSaysNothing() {
        let (bridge, _) = makeBridge()
        bridge.workflowRuns = ["a": run("a", .completed)]
        bridge.subagents = ["c": child("c", .completed)]

        bridge.discloseBackgroundAgentsOutlivingTurnForTesting(conversationID: bridge.currentID!)

        XCTAssertTrue(
            said(bridge).isEmpty,
            "a turn whose background work finished is not worth a row")
    }

    /// The run outlives the turn, so it is still outstanding when the next turn ends, and the one
    /// after that. Keying the disclosure to the turn would append an identical row every time.
    func testItIsSaidOncePerConversationNotOncePerTurn() {
        let (bridge, _) = makeBridge()
        bridge.workflowRuns = ["a": run("a", .running)]

        for _ in 0..<3 {
            bridge.discloseBackgroundAgentsOutlivingTurnForTesting(conversationID: bridge.currentID!)
        }

        XCTAssertEqual(said(bridge).count, 1)
    }

    /// A turn that had nothing to disclose must not consume the conversation's one chance to say it.
    func testAQuietTurnDoesNotSpendTheDisclosure() {
        let (bridge, _) = makeBridge()
        bridge.workflowRuns = ["a": run("a", .completed)]

        bridge.discloseBackgroundAgentsOutlivingTurnForTesting(conversationID: bridge.currentID!)
        XCTAssertTrue(said(bridge).isEmpty)

        bridge.workflowRuns = ["b": run("b", .running)]
        bridge.discloseBackgroundAgentsOutlivingTurnForTesting(conversationID: bridge.currentID!)

        XCTAssertEqual(said(bridge).count, 1)
    }

    // MARK: - Where it lands

    /// Every backgrounded turn takes this branch: `handle` routes an event whose conversation is not
    /// the visible one into the background handler, so its `done` can never match `currentID`.
    func testABackgroundedConversationIsToldInItsOwnTranscript() {
        let (bridge, store) = makeBridge()
        let backgrounded = UUID()
        var conversation = Conversation(
            id: backgrounded,
            title: "Backgrounded",
            cwd: "",
            sdkSessionId: nil,
            messages: [TranscriptEntry(kind: .assistant, text: "Done.")],
            updatedAt: Date(),
            workflowRuns: ["a": run("a", .running)],
            subagents: [:],
            agentActivity: [],
            queuedPrompts: [])
        conversation.updatedAt = Date()
        store.upsert(conversation)

        XCTAssertNotEqual(backgrounded, bridge.currentID)
        XCTAssertEqual(bridge.outstandingBackgroundAgentCount(in: backgrounded), 1)

        bridge.discloseBackgroundAgentsOutlivingTurnForTesting(conversationID: backgrounded)

        let stored = store.conversation(backgrounded)?.messages ?? []
        XCTAssertEqual(stored.filter { $0.kind == .system }.count, 1)
        XCTAssertTrue(
            said(bridge).isEmpty,
            "a background conversation's row must not land in the visible transcript")
    }

    func testAConversationThatIsNotThereCountsForNothing() {
        let (bridge, _) = makeBridge()

        XCTAssertEqual(bridge.outstandingBackgroundAgentCount(in: UUID()), 0)
    }

    /// The row is the only record of why that run's later tool calls were refused. `persistCurrent`
    /// drops ordinary `.system` notices on navigation, so an unmarked row would vanish when the
    /// person switched conversations — while the background branch, which writes straight to the
    /// store, kept its copy. Same situation, two different transcripts.
    func testTheRowSurvivesNavigationAndRelaunch() {
        let (bridge, _) = makeBridge()
        bridge.workflowRuns = ["a": run("a", .running)]

        bridge.discloseBackgroundAgentsOutlivingTurnForTesting(conversationID: bridge.currentID!)

        let row = try? XCTUnwrap(said(bridge).first)
        guard let row else { return XCTFail("no row") }
        XCTAssertEqual(row.backgroundWorkOutlivedTurn, true)
        XCTAssertTrue(
            AgentBridge.isDurableSystemTranscriptEntry(row),
            "persistCurrent filters every .system row this predicate rejects")
        XCTAssertTrue(Conversation.isDurableMessage(row))
    }

    // MARK: - Wiring

    func testBothDonePathsAskTheDisclosure() throws {
        // The tests above exercise the disclosure; this one pins that a finishing turn reaches it.
        // A turn reaches `done` on two paths — the foreground handler and the background-conversation
        // handler — and a turn that ends on the unwired one fails exactly the way the silent bug did.
        let source = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // MechanicianTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // app
            .appendingPathComponent("Sources/Mechanician/AgentBridge.swift")
        let text = try String(contentsOf: source, encoding: .utf8)

        let doneHandlers = text.components(separatedBy: "case \"done\":")
        XCTAssertEqual(doneHandlers.count - 1, 2, "a new done path needs the disclosure too")
        for (index, handler) in doneHandlers.dropFirst().enumerated() {
            // A commented-out call still contains the name, so require a live statement.
            let called = handler.prefix(600).split(separator: "\n").contains { line in
                line.trimmingCharacters(in: .whitespaces)
                    .hasPrefix("discloseBackgroundAgentsOutlivingTurn(")
            }
            XCTAssertTrue(
                called,
                "done path \(index) finalizes a turn without disclosing outstanding background agents")
        }
    }
}
