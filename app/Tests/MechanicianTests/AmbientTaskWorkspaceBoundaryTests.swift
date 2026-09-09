import XCTest
@testable import Mechanician

@MainActor
final class AmbientTaskWorkspaceBoundaryTests: XCTestCase {
    func testReservedWorkspacesAreNeitherInheritedNorOfferedForScheduledTasks() {
        let ordinary = Project(name: "Ordinary", cwd: "/tmp/ordinary")
        let projects = [
            ordinary,
            ReservedWorkspace.help.canonicalProject(),
        ]

        XCTAssertNil(AmbientTaskWorkspacePolicy.inheritedWorkspaceID(HelpWorkspace.id))
        XCTAssertNil(AmbientTaskWorkspacePolicy.inheritedWorkspaceID(nil))
        XCTAssertEqual(
            AmbientTaskWorkspacePolicy.inheritedWorkspaceID(ordinary.id),
            ordinary.id)
        XCTAssertEqual(
            AmbientTaskWorkspacePolicy.selectableProjects(projects).map(\.id),
            [ordinary.id])
    }

    func testLegacyReservedTaskRemainsVisibleButIsUnresolvedAndCannotStartScheduler() throws {
        let (root, task) = try legacyStoreFixture(workspaceID: HelpWorkspace.id, enabled: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AmbientStore(appSupportBaseOverride: root)
        defer { store.stopInProcessRunner() }

        let loaded = try XCTUnwrap(store.tasks.first)
        XCTAssertEqual(loaded.id, task.id)
        XCTAssertEqual(loaded.workspaceID, HelpWorkspace.id, "load must not silently remap it")
        XCTAssertTrue(loaded.enabled, "load must preserve the legacy definition for repair")
        XCTAssertFalse(loaded.hasSchedulableWorkspace)
        XCTAssertFalse(loaded.needsSchedulerProcess)
        XCTAssertFalse(AmbientStore.shouldRunInProcess(
            tasks: [loaded],
            backgroundAgentInstalled: false,
            daemonAvailable: true,
            credentialAvailable: { _ in true }))

        let findings = TaskReadiness.evaluate(
            task: loaded,
            credentialReady: true,
            workspaceResolved: AmbientTaskWorkspacePolicy.resolves(
                loaded.workspaceID,
                in: [ReservedWorkspace.help.canonicalProject()]))
        XCTAssertFalse(TaskReadiness.canRun(findings))
        XCTAssertTrue(findings.contains {
            $0.severity == .blocking
                && $0.title == "Choose a regular workspace"
                && $0.detail == "This reserved product workspace is interactive. Reassign this task "
                    + "to a regular workspace before it can run."
        })
    }

    func testStoreRejectsReservedCreatesEditsEnablesAndManualRuns() throws {
        let (root, original) = try legacyStoreFixture(
            workspaceID: HelpWorkspace.id,
            enabled: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let definitions = root.appendingPathComponent("ambient/tasks.json")
        let originalBytes = try Data(contentsOf: definitions)
        let store = AmbientStore(appSupportBaseOverride: root)
        defer { store.stopInProcessRunner() }

        var edited = original
        edited.prompt = "changed through the editor"
        XCTAssertFalse(store.upsert(edited))
        XCTAssertFalse(store.setEnabled(original.id, true))
        XCTAssertFalse(store.runNow(original.id))
        let create = store.createFromAgent(
            task(id: "agent-created", workspaceID: nil, enabled: true),
            workspaceID: HelpWorkspace.id)
        XCTAssertFalse(create.ok)
        XCTAssertEqual(
            create.message,
            "Scheduled tasks need a regular workspace, not a reserved product workspace.")

        let unchanged = try XCTUnwrap(store.tasks.first)
        XCTAssertEqual(unchanged.prompt, original.prompt)
        XCTAssertFalse(unchanged.enabled)
        XCTAssertNil(unchanged.runRequestID)
        XCTAssertEqual(try Data(contentsOf: definitions), originalBytes)

        // Reassigning the visible legacy definition to an ordinary Workspace is its repair path.
        let ordinaryWorkspaceID = UUID()
        var repaired = unchanged
        repaired.workspaceID = ordinaryWorkspaceID
        XCTAssertTrue(store.upsert(repaired))
        XCTAssertTrue(store.setEnabled(original.id, true))
        XCTAssertTrue(store.runNow(original.id))
        XCTAssertEqual(store.tasks.first?.workspaceID, ordinaryWorkspaceID)
        XCTAssertNotNil(store.tasks.first?.runRequestID)
    }

    private func legacyStoreFixture(
        workspaceID: UUID,
        enabled: Bool
    ) throws -> (root: URL, task: ScheduledTask) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "ambient-reserved-workspace-\(UUID().uuidString)",
            isDirectory: true)
        let ambient = root.appendingPathComponent("ambient", isDirectory: true)
        try FileManager.default.createDirectory(at: ambient, withIntermediateDirectories: true)
        let task = task(id: "legacy-reserved", workspaceID: workspaceID, enabled: enabled)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode([task]).write(to: ambient.appendingPathComponent("tasks.json"))
        return (root, task)
    }

    private func task(
        id: String,
        workspaceID: UUID?,
        enabled: Bool
    ) -> ScheduledTask {
        ScheduledTask(
            id: id,
            name: "Legacy reserved task",
            prompt: "do not run",
            workspaceID: workspaceID,
            enabled: enabled,
            trigger: AmbientTrigger(
                type: "time",
                schedule: AmbientSchedule(kind: "daily", hour: 9, minute: 0)),
            permissionMode: "dontAsk",
            definitionRevision: "legacy-revision-1")
    }
}
