import Foundation
import XCTest
@testable import Mechanician

final class WorkspaceUtilityScopeTests: XCTestCase {
    func testFolderWorkspaceIncludesDurableAndLegacyArtifactsOnly() {
        let workspaceID = UUID()
        let otherWorkspaceID = UUID()
        let scope = WorkspaceUtilityScope.current(
            projectID: nil,
            cwd: "/private/tmp/mechanician-utility-scope",
            resolvedFolderProjectID: workspaceID)

        XCTAssertTrue(scope.contains(artifact: artifact(workspaceID: workspaceID)))
        XCTAssertTrue(scope.contains(artifact: artifact(cwd: "/private/tmp/mechanician-utility-scope")))
        XCTAssertFalse(scope.contains(artifact: artifact(workspaceID: otherWorkspaceID)))
        XCTAssertFalse(scope.contains(artifact: artifact()))
    }

    func testTopicWorkspaceDoesNotAbsorbLooseHomeArtifacts() {
        let workspaceID = UUID()
        let scope = WorkspaceUtilityScope.current(
            projectID: workspaceID,
            cwd: "",
            resolvedFolderProjectID: nil)

        XCTAssertTrue(scope.contains(artifact: artifact(workspaceID: workspaceID)))
        XCTAssertFalse(scope.contains(artifact: artifact()))
    }

    func testHomeScopeShowsOnlyLooseArtifactsAndUnassignedTasks() {
        let workspaceID = UUID()
        let scope = WorkspaceUtilityScope.current(projectID: nil, cwd: "", resolvedFolderProjectID: nil)

        XCTAssertEqual(scope, .home)
        XCTAssertTrue(scope.contains(artifact: artifact()))
        XCTAssertFalse(scope.contains(artifact: artifact(cwd: "/private/tmp/other-workspace")))
        XCTAssertFalse(scope.contains(artifact: artifact(workspaceID: workspaceID)))
        XCTAssertTrue(scope.contains(task: task()))
        XCTAssertFalse(scope.contains(task: task(workspaceID: workspaceID)))
    }

    func testUnavailableScopeNeverWidensToEveryWorkspace() {
        let scope = WorkspaceUtilityScope.unavailable

        XCTAssertFalse(scope.contains(artifact: artifact()))
        XCTAssertFalse(scope.contains(task: task()))
    }

    private func artifact(workspaceID: UUID? = nil, cwd: String = "") -> Artifact {
        Artifact(title: "Artifact", type: "html", source: "", workspaceID: workspaceID, cwd: cwd)
    }

    private func task(workspaceID: UUID? = nil) -> ScheduledTask {
        ScheduledTask(
            name: "Task",
            prompt: "",
            workspaceID: workspaceID,
            trigger: AmbientTrigger(type: "time", schedule: AmbientSchedule(kind: "daily", hour: 9, minute: 0)))
    }
}
