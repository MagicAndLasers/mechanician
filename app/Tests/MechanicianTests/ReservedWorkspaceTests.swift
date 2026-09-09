import Foundation
import XCTest
@testable import Mechanician

@MainActor
final class ReservedWorkspaceTests: XCTestCase {
    /// The retired Memory workspace id `3E3B9C4A-6A1E-4E9C-9C51-7B1D2A5F0E44` is deliberately NOT
    /// asserted absent here. Existing installs still hold that row; it is simply no longer
    /// reserved, so it behaves as an ordinary Workspace the person can rename or delete.
    func testRegistryOwnsTheFixedProductWorkspaceIdentity() {
        XCTAssertEqual(
            ReservedWorkspace.help.id.uuidString.uppercased(),
            "D353F793-FC8A-497C-BF64-BD396EF2F367")
        XCTAssertEqual(HelpWorkspace.id, ReservedWorkspace.help.id)
        XCTAssertTrue(ReservedWorkspace.owns(HelpWorkspace.id))
        XCTAssertFalse(
            ReservedWorkspace.owns(UUID(uuidString: "3E3B9C4A-6A1E-4E9C-9C51-7B1D2A5F0E44")!),
            "the retired Memory workspace must be an ordinary editable row now")
        XCTAssertFalse(ReservedWorkspace.owns(UUID()))
        XCTAssertFalse(ReservedWorkspace.owns(nil))
        XCTAssertFalse(ReservedWorkspace.owns(.home))
        XCTAssertTrue(ReservedWorkspace.owns(.project(HelpWorkspace.id)))
    }

    func testReservedWorkspacesAreCanonicalFolderlessProjects() {
        for workspace in ReservedWorkspace.allCases {
            let project = workspace.canonicalProject()
            XCTAssertEqual(project.id, workspace.id)
            XCTAssertEqual(project.name, workspace.name)
            XCTAssertEqual(project.goal, workspace.goal)
            XCTAssertEqual(project.iconSymbol, workspace.iconSymbol)
            XCTAssertEqual(project.cwd, "")
            XCTAssertEqual(project.instructions, "")
            XCTAssertFalse(project.favorite)
            XCTAssertNil(project.sortIndex)
            XCTAssertNil(project.colorHex)
        }
    }

    func testHelpEnsureIsLazyAndIdempotent() async throws {
        let (store, root) = try makeStore()
        defer {
            store.flushSaves()
            try? FileManager.default.removeItem(at: root)
        }

        XCTAssertFalse(store.contains(HelpWorkspace.id))
        let firstValue = await ensure(.help, in: store)
        let first = try XCTUnwrap(firstValue)
        let secondValue = await ensure(.help, in: store)
        let second = try XCTUnwrap(secondValue)

        XCTAssertEqual(first.id, HelpWorkspace.id)
        XCTAssertEqual(first.cwd, "")
        XCTAssertEqual(second.id, first.id)
        XCTAssertEqual(second.createdAt, first.createdAt)
        XCTAssertEqual(store.projects.filter { $0.id == HelpWorkspace.id }.count, 1)
    }

    func testLegacyLoadRepairsEveryReservedWorkspaceAndPersistsTheRepair() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "reserved-workspace-legacy-load-\(UUID().uuidString)",
                isDirectory: true)
        let directory = root.appendingPathComponent("workspaces", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let drifted = driftedReservedProjects()
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        for project in drifted {
            try encoder.encode(project).write(
                to: directory.appendingPathComponent("\(project.id.uuidString).json"),
                options: .atomic)
        }

        let store = ProjectStore(appSupportBaseOverride: root)
        for source in drifted {
            assertCanonicalRepair(
                try XCTUnwrap(store.project(source.id)),
                preserving: source)
        }

        store.flushSaves()
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        for source in drifted {
            let data = try Data(contentsOf: directory.appendingPathComponent(
                "\(source.id.uuidString).json"))
            assertCanonicalRepair(
                try decoder.decode(Project.self, from: data),
                preserving: source)
        }
    }

    func testSQLiteLoadRepairsEveryReservedWorkspaceAndCommitsTheRepair() throws {
        let authority = try makeAuthority()
        defer { try? FileManager.default.removeItem(at: authority.root) }
        let drifted = driftedReservedProjects()
        for project in drifted {
            _ = try authority.repository.commit(workspace: project)
        }

        let store = ProjectStore(
            appSupportBaseOverride: authority.root,
            libraryAuthorityRepository: authority.repository)
        for source in drifted {
            assertCanonicalRepair(
                try XCTUnwrap(store.project(source.id)),
                preserving: source)
        }

        store.flushSaves()
        let persisted = try authority.repository.workspaceInventory().workspaces
        for source in drifted {
            assertCanonicalRepair(
                try XCTUnwrap(persisted.first { $0.id == source.id }),
                preserving: source)
        }
    }

    func testReservedIdentityRejectsEveryWorkspaceManagementMutationBelowTheUI() throws {
        let (store, root) = try makeStore()
        defer {
            store.flushSaves()
            try? FileManager.default.removeItem(at: root)
        }

        for workspace in ReservedWorkspace.allCases {
            store.upsert(Project(
                id: workspace.id,
                name: "User rename",
                goal: "User goal",
                instructions: "User instructions",
                cwd: "/private/tmp/reserved-must-stay-folderless",
                favorite: true,
                sortIndex: 4,
                iconSymbol: "folder",
                colorHex: "#ff0000"))
            let canonical = try XCTUnwrap(store.project(workspace.id))
            XCTAssertEqual(canonical.name, workspace.name)
            XCTAssertEqual(canonical.goal, workspace.goal)
            XCTAssertEqual(canonical.instructions, "")
            XCTAssertEqual(canonical.cwd, "")
            XCTAssertEqual(canonical.iconSymbol, workspace.iconSymbol)
            let unchangedUpdatedAt = canonical.updatedAt

            XCTAssertFalse(store.setInstructions(
                "Hidden edit",
                for: .project(workspace.id)))
            _ = store.update(workspace.id) {
                $0.name = "Another rename"
                $0.goal = "Another goal"
                $0.instructions = "Another instruction"
                $0.cwd = "/private/tmp/another-folder"
                $0.favorite = true
                $0.sortIndex = 12
                $0.iconSymbol = "folder.fill"
                $0.colorHex = "#00ff00"
            }
            let afterUpdate = try XCTUnwrap(store.project(workspace.id))
            XCTAssertEqual(afterUpdate.name, workspace.name)
            XCTAssertEqual(afterUpdate.goal, workspace.goal)
            XCTAssertEqual(afterUpdate.instructions, "")
            XCTAssertEqual(afterUpdate.cwd, "")
            XCTAssertEqual(afterUpdate.iconSymbol, workspace.iconSymbol)
            XCTAssertFalse(afterUpdate.favorite)
            XCTAssertNil(afterUpdate.sortIndex)
            XCTAssertNil(afterUpdate.colorHex)
            XCTAssertEqual(afterUpdate.updatedAt, unchangedUpdatedAt)

            XCTAssertEqual(
                store.setCwd(workspace.id, to: "/private/tmp/forbidden"),
                .reserved)
            var folderCompletion: Bool?
            XCTAssertFalse(WorkspaceFolderAssignment.assign(
                "/private/tmp/forbidden",
                to: afterUpdate
            ) { folderCompletion = $0 })
            XCTAssertEqual(folderCompletion, false)

            var lowerLayerResult: WorkspaceFolderReassignmentResult?
            XCTAssertFalse(WorkspaceAdoption.reassignWorkspaceFolderAfterAcquiring(
                WorkspaceFolderReassignmentRequest(
                    projectID: workspace.id,
                    expectedCwd: "",
                    destinationCwd: "/private/tmp/forbidden"),
                projects: store,
                synchronizeLiveState: false
            ) { lowerLayerResult = $0 })
            XCTAssertEqual(lowerLayerResult, .unavailable)

            XCTAssertNil(WorkspaceInstructionsPresentation.target(
                projectID: workspace.id,
                cwd: "",
                projects: store.projects))
            XCTAssertNil(WorkspaceManagementPresentation.folderActionTitle(
                projectID: workspace.id,
                cwd: "",
                projects: store.projects))
            XCTAssertFalse(WorkspaceManagementPresentation.canEditWorkspace(
                projectID: workspace.id,
                cwd: "",
                projects: store.projects))

            store.remove(workspace.id)
            XCTAssertTrue(store.contains(workspace.id))
        }
    }

    func testReservedScopesNeverEnterStandardDemonstrationDrafts() {
        let userWorkspaceID = UUID()
        XCTAssertTrue(standardConversationDraftAllowsWorkspace(.home))
        XCTAssertTrue(standardConversationDraftAllowsWorkspace(.project(userWorkspaceID)))
        XCTAssertFalse(standardConversationDraftAllowsWorkspace(.project(HelpWorkspace.id)))
    }

    private func makeStore() throws -> (ProjectStore, URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "reserved-workspace-tests-\(UUID().uuidString)",
                isDirectory: true)
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true)
        return (ProjectStore(appSupportBaseOverride: root), root)
    }

    private func driftedReservedProjects() -> [Project] {
        ReservedWorkspace.allCases.enumerated().map { index, workspace in
            Project(
                id: workspace.id,
                name: "Editable name \(index)",
                goal: "Editable goal \(index)",
                instructions: "Editable instructions \(index)",
                cwd: "/private/tmp/legacy-reserved-\(index)",
                favorite: true,
                sortIndex: index + 4,
                iconSymbol: "folder.fill",
                colorHex: "#ff0000",
                defaultModelSelection: ModelSelection(
                    access: .codexSubscription,
                    modelID: "reserved-model-\(index)"),
                createdAt: Date(timeIntervalSince1970: TimeInterval(1_700_000_000 + index)),
                updatedAt: Date(timeIntervalSince1970: TimeInterval(1_710_000_000 + index)))
        }
    }

    private func assertCanonicalRepair(
        _ repaired: Project,
        preserving source: Project,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let workspace = ReservedWorkspace.workspace(for: source.id)
        XCTAssertNotNil(workspace, file: file, line: line)
        XCTAssertTrue(workspace?.hasCanonicalIdentity(repaired) == true, file: file, line: line)
        XCTAssertEqual(
            repaired.defaultModelSelection,
            source.defaultModelSelection,
            file: file,
            line: line)
        XCTAssertEqual(repaired.createdAt, source.createdAt, file: file, line: line)
        XCTAssertEqual(repaired.updatedAt, source.updatedAt, file: file, line: line)
    }

    private func makeAuthority() throws -> (
        root: URL,
        repository: LibraryAuthorityRepository
    ) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "reserved-workspace-sqlite-load-\(UUID().uuidString)",
            isDirectory: true)
        let home = HomeWorkspaceSettings(
            instructions: "Home",
            updatedAt: Date(timeIntervalSince1970: 1_700_000_000))
        let homeBytes = try ConversationStore.makeEncoder().encode(home)
        var importStore: SQLiteLibraryStore? = try SQLiteLibraryStore(supportRoot: root)
        _ = try XCTUnwrap(importStore).reconcile(ShadowLibraryImportSnapshot(
            home: LibraryWorkspaceAdapter.capture(
                home: home,
                source: ShadowLibrarySourceFingerprint(
                    identity: "home-workspace.json",
                    revision: "legacy-home",
                    sourceBytes: homeBytes)),
            workspaces: [],
            conversations: []))
        let frontier = try XCTUnwrap(importStore).status()
        try XCTUnwrap(importStore).acknowledgeExactProjectionSnapshot(
            databaseInstanceID: frontier.databaseInstanceID,
            through: frontier.shadowChangeSequence,
            projectionSchemaVersion: Int(ConversationProjectionStore.schemaVersion))
        let activationID = UUID()
        try XCTUnwrap(importStore).prepareAuthority(
            activationID: activationID,
            minimumWriterBuild: StorageAuthorityProtocol.recognitionID)
        try XCTUnwrap(importStore).activatePreparedAuthority(activationID: activationID)
        let metadata = try XCTUnwrap(importStore).authorityMetadata()
        let marker = StorageAuthorityMarker(
            mode: .sqlite,
            activationID: activationID,
            databaseInstanceID: metadata.databaseInstanceID,
            schemaVersion: metadata.schemaVersion,
            createdAt: "2026-08-25T12:00:00Z")
        importStore = nil
        let activeStore = try SQLiteLibraryStore.openActiveAuthority(
            supportRoot: root,
            marker: marker)
        return (
            root,
            try LibraryAuthorityRepository(
                store: activeStore,
                supportRoot: root,
                marker: marker))
    }

    private func ensure(
        _ workspace: ReservedWorkspace,
        in store: ProjectStore
    ) async -> Project? {
        await withCheckedContinuation { continuation in
            workspace.ensure(in: store) { project in
                continuation.resume(returning: project)
            }
        }
    }
}
