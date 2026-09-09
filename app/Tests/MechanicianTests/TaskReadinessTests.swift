import XCTest
@testable import Mechanician

/// A scheduled task is judged by rules the user cannot see: interactive tools are withheld
/// entirely, writes and shell need Trust all, and each lane needs its own credential. Left
/// implicit, those produce a task that looks right, runs on schedule, and quietly does nothing.
final class TaskReadinessTests: XCTestCase {
    private func task(prompt: String, mode: String? = nil, access: String? = nil) -> ScheduledTask {
        ScheduledTask(
            name: "t", prompt: prompt, workspaceID: UUID(),
            trigger: AmbientTrigger(type: "time", schedule: AmbientSchedule(kind: "interval", minutes: 60)),
            access: access, permissionMode: mode)
    }

    private func evaluate(_ t: ScheduledTask, credential: Bool = true, workspace: Bool = true)
    -> [TaskReadiness.Finding] {
        TaskReadiness.evaluate(task: t, credentialReady: credential, workspaceResolved: workspace)
    }

    func testAMissingCredentialBlocksThisTaskOnly() {
        let findings = evaluate(task(prompt: "summarize the repo"), credential: false)
        XCTAssertFalse(TaskReadiness.canRun(findings))
        let blocking = findings.first { $0.severity == .blocking }
        XCTAssertTrue(blocking?.detail.contains("Other tasks are unaffected") == true,
                      "the user should know the scheduler still runs their other work")
    }

    func testAnUnassignedWorkspaceBlocks() {
        XCTAssertFalse(TaskReadiness.canRun(evaluate(task(prompt: "do it"), workspace: false)))
    }

    func testAnEmptyPromptBlocks() {
        XCTAssertFalse(TaskReadiness.canRun(evaluate(task(prompt: "   "))))
    }

    func testAPromptThatExpectsAPersonIsFlagged() {
        // The exact failure the user described: written as if someone were watching.
        for prompt in ["ask me which branch to use", "wait for the build to finish",
                       "take a screenshot of the result", "run the shortcut then report"] {
            let findings = evaluate(task(prompt: prompt, mode: "bypassPermissions"))
            XCTAssertTrue(
                findings.contains { $0.title.contains("can't do") },
                "“\(prompt)” should warn that a scheduled run has nobody to answer")
        }
    }

    func testInteractiveWarningsSurviveTrustAll() {
        // Trust all does NOT bring back interactive tools; nothing can answer them either way.
        let findings = evaluate(task(prompt: "ask me before deleting", mode: "bypassPermissions"))
        XCTAssertTrue(findings.contains { $0.title.contains("can't do") })
    }

    func testAWritingTaskOnReadOnlyAccessIsFlagged() {
        let findings = evaluate(task(prompt: "update the changelog with today's commits"))
        XCTAssertTrue(findings.contains { $0.title.contains("change something") })
        XCTAssertTrue(TaskReadiness.canRun(findings), "it can still run — it just won't do that")
    }

    func testTheSameTaskOnTrustAllIsNotFlagged() {
        let findings = evaluate(task(prompt: "update the changelog", mode: "bypassPermissions"))
        XCTAssertFalse(findings.contains { $0.title.contains("change something") })
    }

    func testAReadOnlyTaskOnReadOnlyAccessIsClean() {
        let findings = evaluate(task(prompt: "summarize what the docs folder covers"))
        XCTAssertEqual(TaskReadiness.worst(findings), .info)
        XCTAssertTrue(TaskReadiness.canRun(findings))
    }

    func testFindingsLeadWithTheMostSevere() {
        let findings = evaluate(task(prompt: "update the files"), credential: false)
        XCTAssertEqual(findings.first?.severity, .blocking)
        XCTAssertEqual(TaskReadiness.worst(findings), .blocking)
    }

    func testEveryTaskLearnsWhatItsAccessModeAllows() {
        XCTAssertTrue(evaluate(task(prompt: "read things"))
            .contains { $0.title == "Read-only access" })
        XCTAssertTrue(evaluate(task(prompt: "read things", mode: "bypassPermissions"))
            .contains { $0.title == "Full access" })
    }
}
