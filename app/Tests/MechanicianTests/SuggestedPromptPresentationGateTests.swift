import XCTest
@testable import Mechanician

/// FR-369. The app showed a finished turn and an unfinished turn in the same frame: the assistant
/// answer carrying its copy/retry/fork row and a suggested follow-up bar reading "now do the flow
/// rework", directly above a "Running command…" strip, a Stop button, and a Workflow card at
/// 7 of 9 agents.
///
/// Nothing about the suggestion itself was wrong. The provider authors it from the root agent's
/// closing text and delivers it at that root turn's terminal, and the root agent really had
/// finished. But the Workflow and Agent tools run in the background, so the root turn reaches
/// terminal while the agents it started keep working — and the presentation gate only asked about
/// *user* work (a reserved turn, a queued prompt), never about delegated work.
///
/// These pin the distinction: the record stays published and durable; only the offer waits.
@MainActor
final class SuggestedPromptPresentationGateTests: XCTestCase {
    private func makeBridge() -> (AgentBridge, URL) {
        let support = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "mechanician-suggestion-gate-\(UUID().uuidString)", isDirectory: true)
        return (AgentBridge(settingsBaseOverride: support, environmentOverride: [:]), support)
    }

    private func runningWorkflow() -> WorkflowRun {
        var run = WorkflowRun(runKey: "run-key")
        run.toolUseId = "tool-use"
        run.runTaskId = "run-task"
        run.status = .running
        return run
    }

    /// An idle conversation offers its suggestion. This is the control: without it, a gate that
    /// simply never presents anything would pass the test below.
    func testSuggestionIsOfferedWhenNothingIsRunning() {
        let (bridge, support) = makeBridge()
        defer { bridge.shutdown(); try? FileManager.default.removeItem(at: support) }

        XCTAssertTrue(
            bridge.mayPresentSuggestedPrompt,
            "a finished, idle conversation is exactly when a follow-up should be offered")
    }

    /// The reported bug. The root turn is over — nothing is streaming, no turn is reserved — but a
    /// workflow it started is still running, so the same frame is still showing Stop.
    func testSuggestionIsWithheldWhileAWorkflowTheTurnStartedIsStillRunning() {
        let (bridge, support) = makeBridge()
        defer { bridge.shutdown(); try? FileManager.default.removeItem(at: support) }

        bridge.workflowRuns = ["run-key": runningWorkflow()]

        XCTAssertTrue(
            bridge.hasRunningDelegate,
            "precondition: the conversation is showing a running workflow")
        XCTAssertFalse(
            bridge.mayPresentSuggestedPrompt,
            "asking for the next thing while something is still doing the last thing is the app "
                + "contradicting itself in one frame")
    }

    /// A subagent counts for the same reason a workflow does.
    func testSuggestionIsWithheldWhileASubagentIsStillRunning() {
        let (bridge, support) = makeBridge()
        defer { bridge.shutdown(); try? FileManager.default.removeItem(at: support) }

        var run = SubagentRun(key: "k1", subagentType: "Explore", task: "sweep the repo")
        run.status = .running
        bridge.subagents = ["k1": run]

        XCTAssertFalse(bridge.mayPresentSuggestedPrompt)
    }

    /// The offer is deferred, not destroyed. When the delegated work settles, the same record
    /// becomes presentable again with no new turn and no regeneration.
    func testSuggestionBecomesOfferableAgainOnceDelegatedWorkSettles() {
        let (bridge, support) = makeBridge()
        defer { bridge.shutdown(); try? FileManager.default.removeItem(at: support) }

        bridge.workflowRuns = ["run-key": runningWorkflow()]
        XCTAssertFalse(bridge.mayPresentSuggestedPrompt)

        var settled = runningWorkflow()
        settled.status = .completed
        bridge.workflowRuns = ["run-key": settled]

        XCTAssertTrue(
            bridge.mayPresentSuggestedPrompt,
            "withholding must be a wait, not a discard — the record was never wrong")
    }
}
