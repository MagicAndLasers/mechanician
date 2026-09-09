import XCTest
@testable import Mechanician

/// Reported from a live window: the root agent read "completed" while the conversation still said
/// "1 agent active", and a workflow whose 12th agent never returned had been counted as running for
/// eighteen hours. The runaway run also stretched the activity trace's time axis until the root
/// turn's real 38 minutes of work was an invisible sliver — "we lost the root activity".
///
/// Every existing way a delegate settles is a PROCESS-DEATH event: bridge teardown, runtime restart,
/// runtime exit, or loading a sidecar with no live bridge. This one matched none of them, because
/// from the daemon's side nothing died. The run simply stopped reporting, and nothing anywhere
/// checked for silence.
@MainActor
final class SilentDelegateReaperTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_000_000)

    private func run(
        _ key: String,
        status: WorkflowStatus = .running,
        lastUpdate: Date?,
        startedAt: Date? = nil
    ) -> WorkflowRun {
        var run = WorkflowRun(runKey: key)
        run.status = status
        run.startedAt = startedAt ?? now.addingTimeInterval(-10 * 60 * 60)
        run.lastUpdateAt = lastUpdate
        return run
    }

    private func subagent(
        _ key: String,
        status: WorkflowStatus = .running,
        lastUpdate: Date?
    ) -> SubagentRun {
        var subagent = SubagentRun(key: key, subagentType: "Explore", task: "look")
        subagent.status = status
        subagent.startedAt = now.addingTimeInterval(-10 * 60 * 60)
        subagent.lastUpdateAt = lastUpdate
        return subagent
    }

    // MARK: The reported case

    func testARunThatHasReportedNothingForHoursIsSilent() {
        let silent = run("w1", lastUpdate: now.addingTimeInterval(-18 * 60 * 60))
        XCTAssertTrue(delegatedWorkHasGoneSilent(
            workflowRuns: ["w1": silent], subagents: [:], now: now))
    }

    /// The expensive half of the asymmetry. Stopping a run that was still working destroys work the
    /// user is waiting on, so anything reporting inside the window keeps running.
    func testARunReportingInsideTheWindowIsLeftAlone() {
        let ages: [TimeInterval] = [0, 60, 29 * 60, delegatedWorkSilenceTimeout - 1]
        for age in ages {
            let live = run("w1", lastUpdate: now.addingTimeInterval(-age))
            XCTAssertFalse(
                delegatedWorkHasGoneSilent(workflowRuns: ["w1": live], subagents: [:], now: now),
                "a run last seen \(Int(age))s ago must not be reaped")
        }
    }

    func testOneLiveDelegateKeepsTheSilentOnes() {
        // All-or-nothing is what lets this reuse the conversation-scoped reducer untouched. The
        // mixed case then self-heals: once the live one finishes, the silent one is judged again.
        let runs = [
            "w1": run("w1", lastUpdate: now.addingTimeInterval(-18 * 60 * 60)),
            "w2": run("w2", lastUpdate: now.addingTimeInterval(-30)),
        ]
        XCTAssertFalse(delegatedWorkHasGoneSilent(workflowRuns: runs, subagents: [:], now: now))

        // …and with the live one finished, the silent one is now reapable.
        var settled = runs
        settled["w2"]?.status = .completed
        XCTAssertTrue(delegatedWorkHasGoneSilent(workflowRuns: settled, subagents: [:], now: now))
    }

    func testAConversationWithNothingRunningIsNeverReported() {
        // Otherwise an idle conversation would be "settled" on every tick forever.
        XCTAssertFalse(delegatedWorkHasGoneSilent(workflowRuns: [:], subagents: [:], now: now))
        let done = run("w1", status: .completed, lastUpdate: now.addingTimeInterval(-18 * 60 * 60))
        XCTAssertFalse(delegatedWorkHasGoneSilent(
            workflowRuns: ["w1": done], subagents: [:], now: now))
    }

    // MARK: Fallbacks and edges

    func testARunThatNeverReportedIsJudgedFromItsStart() {
        // A delegate that dies immediately never gets a `lastUpdateAt`, and older persisted rows
        // predate the field entirely. Neither may be immortal.
        let neverReported = run("w1", lastUpdate: nil)
        XCTAssertTrue(delegatedWorkHasGoneSilent(
            workflowRuns: ["w1": neverReported], subagents: [:], now: now))

        let justStarted = run("w2", lastUpdate: nil, startedAt: now.addingTimeInterval(-60))
        XCTAssertFalse(delegatedWorkHasGoneSilent(
            workflowRuns: ["w2": justStarted], subagents: [:], now: now))
    }

    func testAClockThatMovedBackwardsNeverReaps() {
        // Negative elapsed must fail safe. Reaping on a rollback would stop live work.
        let future = run("w1", lastUpdate: now.addingTimeInterval(60 * 60))
        XCTAssertFalse(delegatedWorkHasGoneSilent(
            workflowRuns: ["w1": future], subagents: [:], now: now))
    }

    func testStandaloneSubagentsAreJudgedTheSameWay() {
        let silent = subagent("s1", lastUpdate: now.addingTimeInterval(-18 * 60 * 60))
        XCTAssertTrue(delegatedWorkHasGoneSilent(
            workflowRuns: [:], subagents: ["s1": silent], now: now))

        let live = subagent("s2", lastUpdate: now.addingTimeInterval(-30))
        XCTAssertFalse(delegatedWorkHasGoneSilent(
            workflowRuns: [:], subagents: ["s1": silent, "s2": live], now: now))
    }

    // MARK: The stamp the whole rule depends on

    func testEveryFoldStampsLiveness() {
        // If a progress update did not stamp, a healthy long-running run would be judged from
        // `startedAt` and reaped while it was still working. That is the dangerous direction.
        let started = WorkflowUpdate([
            "phase": "started", "taskId": "t1", "toolUseId": "u1",
            "isWorkflowRun": true, "workflowName": "probe", "status": "running",
        ])
        var runs = applyWorkflowUpdate([:], started, sessionId: "s")
        XCTAssertNotNil(runs["u1"]?.lastUpdateAt)

        // A progress update carrying nothing but a summary still counts as evidence of life.
        let progress = WorkflowUpdate([
            "phase": "progress", "taskId": "t1", "toolUseId": "u1", "summary": "still working",
        ])
        runs = applyWorkflowUpdate(runs, progress, sessionId: "s")
        XCTAssertNotNil(runs["u1"]?.lastUpdateAt)
        XCTAssertEqual(runs["u1"]?.status, .running)
        XCTAssertFalse(delegatedWorkHasGoneSilent(
            workflowRuns: runs, subagents: [:], now: Date()))
    }

    // MARK: What the user is left with

    func testAReapedRunReadsAsStoppedAndStopsCountingAsActive() {
        var runs = ["w1": run("w1", lastUpdate: now.addingTimeInterval(-18 * 60 * 60))]
        var subagents: [String: SubagentRun] = [:]
        var activity: [AgentActivityRecord] = []

        let changed = terminalizeDelegatedWorkState(
            workflowRuns: &runs,
            subagents: &subagents,
            agentActivity: &activity,
            outcome: .userStopped,
            turnID: nil,
            at: now)

        XCTAssertTrue(changed)
        XCTAssertEqual(runs["w1"]?.status, .stopped, "David chose stopped, not failed")
        XCTAssertNotNil(runs["w1"]?.endedAt, "an ended run must stop accruing elapsed time")
        XCTAssertFalse(hasNonterminalDelegatedWork(workflowRuns: runs, subagents: subagents))
    }
}
