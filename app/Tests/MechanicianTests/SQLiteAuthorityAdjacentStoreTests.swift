import CryptoKit
import Foundation
import XCTest
@testable import Mechanician

@MainActor
final class SQLiteAuthorityAdjacentStoreTests: XCTestCase {
    private struct Fixture {
        let root: URL
        let repository: LibraryAuthorityRepository
        let workspace: Project
        let artifact: Artifact
    }

    private var roots: [URL] = []

    override func tearDown() {
        for root in roots { try? FileManager.default.removeItem(at: root) }
        roots.removeAll()
        super.tearDown()
    }

    /// The scheduler daemon cannot open `library.db`, so it resolves a task's working directory and
    /// Workspace Instructions from files. Once SQLite owns the library the files it used to read are
    /// frozen, and a Workspace edited or created after the cutover resolved to nothing — the task
    /// then ran from the user's home directory. The app publishes a projection for it instead.
    func testWorkspaceProjectionCarriesLiveFactsTheFrozenSourcesNoLongerHave() throws {
        let fixture = try makeFixture()
        let projection = fixture.root
            .appendingPathComponent("ambient-projection", isDirectory: true)
            .appendingPathComponent("workspaces.json", isDirectory: false)

        let workspaces = ProjectStore(
            appSupportBaseOverride: fixture.root,
            libraryAuthorityRepository: fixture.repository)
        workspaces.flushSaves()

        // Published at launch, so the first run after the cutover already has current facts even if
        // nothing has been edited to trigger a save.
        XCTAssertEqual(
            try published(projection).workspaces.first { $0.id == fixture.workspace.id }?.cwd,
            fixture.workspace.cwd)

        workspaces.update(fixture.workspace.id) {
            $0.cwd = "/tmp/moved-after-the-cutover"
            $0.instructions = "Edited after the cutover"
        }
        workspaces.flushSaves()
        let edited = try XCTUnwrap(
            try published(projection).workspaces.first { $0.id == fixture.workspace.id })
        XCTAssertEqual(edited.cwd, "/tmp/moved-after-the-cutover")
        XCTAssertEqual(edited.instructions, "Edited after the cutover")

        workspaces.setInstructions("Home policy after the cutover", for: .home)
        workspaces.flushSaves()
        XCTAssertEqual(
            try published(projection).home.instructions,
            "Home policy after the cutover")

        workspaces.remove(fixture.workspace.id)
        workspaces.flushSaves()
        XCTAssertNil(
            try published(projection).workspaces.first { $0.id == fixture.workspace.id },
            "a deleted Workspace must stop resolving for the scheduler too")

        // The projection carries only what a scheduled run needs to resolve its Workspace.
        let raw = try XCTUnwrap(
            JSONSerialization.jsonObject(with: try Data(contentsOf: projection))
                as? [String: Any])
        XCTAssertEqual(Set(raw.keys), ["home", "workspaces"])
    }

    private struct PublishedWorkspaceProjection: Decodable {
        struct Home: Decodable { let instructions: String }
        struct Workspace: Decodable {
            let id: UUID
            let cwd: String
            let instructions: String
        }

        let home: Home
        let workspaces: [Workspace]
    }

    private func published(_ url: URL) throws -> PublishedWorkspaceProjection {
        try JSONDecoder().decode(
            PublishedWorkspaceProjection.self, from: try Data(contentsOf: url))
    }

    func testWorkspaceAndArtifactStoresNeverRewriteFrozenLegacySources() throws {
        let fixture = try makeFixture()
        let workspaceDirectory = fixture.root.appendingPathComponent("workspaces", isDirectory: true)
        let artifactDirectory = fixture.root.appendingPathComponent("artifacts", isDirectory: true)
        try FileManager.default.createDirectory(
            at: workspaceDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: artifactDirectory, withIntermediateDirectories: true)
        let workspaceLegacyURL = workspaceDirectory.appendingPathComponent(
            "\(fixture.workspace.id.uuidString).json")
        let artifactLegacyURL = artifactDirectory.appendingPathComponent(
            "\(fixture.artifact.uuid.uuidString).json")
        let frozenWorkspace = Data("frozen-workspace".utf8)
        let frozenArtifact = Data("frozen-artifact".utf8)
        try frozenWorkspace.write(to: workspaceLegacyURL)
        try frozenArtifact.write(to: artifactLegacyURL)

        let workspaces = ProjectStore(
            appSupportBaseOverride: fixture.root,
            libraryAuthorityRepository: fixture.repository)
        XCTAssertEqual(workspaces.project(fixture.workspace.id)?.name, fixture.workspace.name)
        workspaces.update(fixture.workspace.id) { $0.name = "SQLite Workspace" }
        workspaces.flushSaves()
        guard case .named(let committedWorkspace) = try XCTUnwrap(
            fixture.repository.workspace(id: fixture.workspace.id)) else {
            return XCTFail("named Workspace did not reconstruct")
        }
        XCTAssertEqual(committedWorkspace.name, "SQLite Workspace")
        XCTAssertEqual(try Data(contentsOf: workspaceLegacyURL), frozenWorkspace)

        let artifacts = ArtifactStore(
            appSupportBaseOverride: fixture.root,
            watchesDirectory: false,
            libraryAuthorityRepository: fixture.repository)
        XCTAssertEqual(artifacts.artifacts.map(\.uuid), [fixture.artifact.uuid])
        let isolatedConversations = ConversationStore(
            appSupportBaseOverride: fixture.root.appendingPathComponent(
                "isolated-conversations", isDirectory: true))
        artifacts.rename(
            fixture.artifact.uuid,
            to: "SQLite Artifact",
            conversations: isolatedConversations,
            synchronizeLiveState: false)
        artifacts.flushSaves()
        XCTAssertEqual(
            try fixture.repository.artifact(id: fixture.artifact.uuid)?.title,
            "SQLite Artifact")
        XCTAssertEqual(try Data(contentsOf: artifactLegacyURL), frozenArtifact)
    }

    func testAmbientTasksCommitToSQLiteAndUseSeparateDaemonProjection() throws {
        let fixture = try makeFixture()
        let legacyDirectory = fixture.root.appendingPathComponent("ambient", isDirectory: true)
        try FileManager.default.createDirectory(
            at: legacyDirectory, withIntermediateDirectories: true)
        let legacyURL = legacyDirectory.appendingPathComponent("tasks.json")
        let frozenLegacy = Data("[{\"legacy\":\"frozen\"}]".utf8)
        try frozenLegacy.write(to: legacyURL)

        let ambient = AmbientStore(
            appSupportBaseOverride: fixture.root,
            libraryAuthorityRepository: fixture.repository)
        XCTAssertEqual(ambient.tasks.map(\.name), ["Before activation"])
        let projectionURL = fixture.root
            .appendingPathComponent("ambient-projection", isDirectory: true)
            .appendingPathComponent("tasks.json")
        XCTAssertEqual(
            try JSONDecoder().decode(
                [LibraryAmbientTaskDefinition].self,
                from: Data(contentsOf: projectionURL)).first?.name,
            "Before activation")
        let runtimeProjectionURL = projectionURL.deletingLastPathComponent()
            .appendingPathComponent("runtime.json")
        let projectedRuntime = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(contentsOf: runtimeProjectionURL))
                as? [String: [String: Any]])
        XCTAssertEqual(projectedRuntime["task-1"]?["onceCompleted"] as? Bool, true)
        XCTAssertEqual(
            (projectedRuntime["task-1"]?["activeRun"] as? [String: Any])?["id"] as? String,
            "active-before-cutover")
        let runsProjectionURL = projectionURL.deletingLastPathComponent()
            .appendingPathComponent("runs.json")
        let projectedRuns = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(contentsOf: runsProjectionURL))
                as? [[String: Any]])
        XCTAssertEqual(projectedRuns.first?["summary"] as? String, "Committed before cutover")
        var changed = try XCTUnwrap(ambient.tasks.first)
        changed.name = "SQLite task"
        ambient.upsert(changed)

        XCTAssertEqual(try Data(contentsOf: legacyURL), frozenLegacy)
        XCTAssertTrue(FileManager.default.fileExists(atPath: projectionURL.path))
        let definitions = try ambientDefinitions(in: fixture.repository)
        XCTAssertEqual(definitions.first?.name, "SQLite task")
        ambient.stopInProcessRunner()
    }

    func testAmbientDaemonConfigurationChangesAtSQLiteCutover() {
        let profile = TenantProfile.default
        let legacy = AmbientDaemon.configurationIdentity(
            build: "209",
            profile: profile,
            authorityGeneration: "legacy-unmarked")
        let sqlite = AmbientDaemon.configurationIdentity(
            build: "209",
            profile: profile,
            authorityGeneration: "sqlite-11111111-1111-1111-1111-111111111111")
        XCTAssertNotEqual(legacy, sqlite)
    }

    private func makeFixture() throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "sqlite-adjacent-stores-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o700)], ofItemAtPath: root.path)
        roots.append(root)

        let workspace = Project(
            name: "Before activation",
            goal: "Exercise SQLite authority",
            cwd: "/tmp/sqlite-authority")
        let artifact = Artifact(
            title: "Before activation",
            type: "markdown",
            source: "fixture",
            origin: "user",
            workspaceID: workspace.id,
            createdAt: Date(timeIntervalSinceReferenceDate: 20),
            updatedAt: Date(timeIntervalSinceReferenceDate: 30))
        var shadow: SQLiteLibraryStore? = try SQLiteLibraryStore(supportRoot: root)
        let home = HomeWorkspaceSettings(
            instructions: "Home instructions",
            updatedAt: Date(timeIntervalSinceReferenceDate: 10))
        _ = try shadow?.upsert(workspace: LibraryWorkspaceAdapter.capture(
            home: home,
            source: fingerprint("home-workspace.json", Data("home".utf8))))
        _ = try shadow?.upsert(workspace: LibraryWorkspaceAdapter.capture(
            workspace,
            source: fingerprint(
                "workspaces/\(workspace.id.uuidString).json", Data("workspace".utf8))))
        let artifactSource = try ArtifactStore.persistedEncoder().encode(artifact)
        _ = try shadow?.upsert(artifact: LibraryArtifactAdapter.capture(
            artifact,
            source: fingerprint(
                "artifacts/\(artifact.uuid.uuidString).json", artifactSource)))

        let taskData = try JSONSerialization.data(withJSONObject: [[
            "id": "task-1",
            "name": "Before activation",
            "prompt": "Do nothing",
            "workspaceID": workspace.id.uuidString,
            "cwd": "",
            "enabled": false,
            "trigger": ["type": "time", "schedule": ["kind": "interval", "minutes": 60]],
        ]], options: [.sortedKeys])
        let capturedTask = try LibraryAmbientAuthorityAdapter.capture(
            sourceData: taskData, kind: .taskDefinitions)
        let taskSnapshot = ShadowLibraryAmbientSnapshot(
            kind: .taskDefinitions,
            payloadVersion: capturedTask.version,
            payload: capturedTask.payload,
            source: fingerprint("ambient/tasks.json", taskData))
        let runtimeData = try JSONSerialization.data(withJSONObject: [
            "task-1": [
                "lastRunRequestID": "request-before-cutover",
                "onceCompleted": true,
                "activeRun": [
                    "id": "active-before-cutover",
                    "startedAt": "2026-08-05T12:00:00.000Z",
                    "trigger": "manual",
                ],
            ],
        ], options: [.sortedKeys])
        let capturedRuntime = try LibraryAmbientAuthorityAdapter.capture(
            sourceData: runtimeData, kind: .schedulerRuntime)
        let runtimeSnapshot = ShadowLibraryAmbientSnapshot(
            kind: .schedulerRuntime,
            payloadVersion: capturedRuntime.version,
            payload: capturedRuntime.payload,
            source: fingerprint("ambient/runtime.json", runtimeData))
        let runsData = try JSONSerialization.data(withJSONObject: [[
            "taskId": "task-1",
            "at": "2026-08-05T11:00:00.000Z",
            "ok": true,
            "summary": "Committed before cutover",
            "conversationID": NSNull(),
        ]], options: [.sortedKeys])
        let capturedRuns = try LibraryAmbientAuthorityAdapter.capture(
            sourceData: runsData, kind: .runReceipts)
        let runsSnapshot = ShadowLibraryAmbientSnapshot(
            kind: .runReceipts,
            payloadVersion: capturedRuns.version,
            payload: capturedRuns.payload,
            source: fingerprint("ambient/runs.json", runsData))
        _ = try shadow?.reconcileAmbient(ShadowLibraryAmbientInventory(
            sources: [taskSnapshot, runtimeSnapshot, runsSnapshot]))

        let status = try XCTUnwrap(shadow).status()
        try XCTUnwrap(shadow).acknowledgeExactProjectionSnapshot(
            databaseInstanceID: status.databaseInstanceID,
            through: status.shadowChangeSequence,
            projectionSchemaVersion: Int(ConversationProjectionStore.schemaVersion))
        let activationID = UUID()
        try shadow?.prepareAuthority(
            activationID: activationID,
            minimumWriterBuild: StorageAuthorityProtocol.recognitionID)
        try shadow?.activatePreparedAuthority(activationID: activationID)
        let metadata = try XCTUnwrap(shadow).authorityMetadata()
        let marker = StorageAuthorityMarker(
            mode: .sqlite,
            activationID: activationID,
            databaseInstanceID: metadata.databaseInstanceID,
            schemaVersion: metadata.schemaVersion,
            minimumWriterBuild: try XCTUnwrap(metadata.minimumWriterBuild),
            createdAt: "2026-08-05T12:00:00Z")
        shadow = nil
        let active = try SQLiteLibraryStore.openActiveAuthority(
            supportRoot: root, marker: marker)
        let repository = try LibraryAuthorityRepository(
            store: active, supportRoot: root, marker: marker)
        return Fixture(
            root: root,
            repository: repository,
            workspace: workspace,
            artifact: artifact)
    }

    private func ambientDefinitions(
        in repository: LibraryAuthorityRepository
    ) throws -> [LibraryAmbientTaskDefinition] {
        let snapshot = try XCTUnwrap(
            repository.ambientState().first { $0.kind == .taskDefinitions })
        let data = try LibraryAmbientAuthorityAdapter.freshLegacyData(
            version: snapshot.payloadVersion,
            payload: snapshot.payload,
            expectedKind: .taskDefinitions)
        return try JSONDecoder().decode([LibraryAmbientTaskDefinition].self, from: data)
    }

    nonisolated private func fingerprint(
        _ identity: String,
        _ data: Data
    ) -> ShadowLibrarySourceFingerprint {
        ShadowLibrarySourceFingerprint(
            identity: identity,
            revision: "fixture",
            sourceBytes: data)
    }
}
