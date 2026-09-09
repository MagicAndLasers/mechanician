import Foundation
import XCTest
@testable import Mechanician

@MainActor
final class WorkspaceInstructionsTests: XCTestCase {
    private func conversation(
        cwd: String = "",
        projectID: UUID? = nil,
        sessionID: String? = nil
    ) -> Conversation {
        Conversation(
            title: "Test",
            cwd: cwd,
            sdkSessionId: sessionID,
            messages: [],
            updatedAt: Date(),
            projectID: projectID)
    }

    private func temporarySupport(_ prefix: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func encodedProject(_ project: Project) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(project)
    }

    func testConversationAuthoritativeTargetResolutionMatrixNeverMintsOrFallsThrough() {
        let topic = Project(name: "Topic")
        let folder = Project(name: "Folder", cwd: "/private/tmp/workspace")
        let projects = [topic, folder]

        XCTAssertEqual(
            WorkspaceInstructionResolver.target(
                for: conversation(), projects: projects),
            .home)
        XCTAssertEqual(
            WorkspaceInstructionResolver.target(
                for: conversation(projectID: topic.id), projects: projects),
            .project(topic.id))
        XCTAssertEqual(
            WorkspaceInstructionResolver.target(
                for: conversation(cwd: "/stale", projectID: folder.id), projects: projects),
            .project(folder.id),
            "A persisted project id is more authoritative than stale conversation cwd")
        XCTAssertEqual(
            WorkspaceInstructionResolver.target(
                for: conversation(cwd: folder.cwd), projects: projects),
            .project(folder.id),
            "Legacy folder conversations can recognize an existing Project")
        XCTAssertNil(
            WorkspaceInstructionResolver.target(
                for: conversation(cwd: folder.cwd, projectID: UUID()), projects: projects),
            "A dangling persisted id must not fall through by cwd or to Home")
        XCTAssertNil(
            WorkspaceInstructionResolver.target(
                for: conversation(cwd: " \n "), projects: projects),
            "Only exact empty cwd is Home identity")
        XCTAssertNil(
            WorkspaceInstructionResolver.target(
                for: conversation(cwd: "/unknown"), projects: projects))
        XCTAssertEqual(projects.count, 2, "Resolution is pure and cannot mint a Project")
    }

    func testProviderSnapshotMatrixUsesOnlyTheSupportedInstructionSources() {
        let folder = Project(
            name: "Folder",
            instructions: "  App policy  ",
            cwd: "/private/tmp/canonical-project")
        let conversation = conversation(
            cwd: "/private/tmp/stale-conversation",
            projectID: folder.id)

        for access in [
            ModelAccess.claudeSubscription,
            .anthropicAPI,
            .claudeVertex,
            .claudeBedrock,
        ] {
            var reads: [String] = []
            let snapshot = WorkspaceInstructionResolver.snapshot(
                for: conversation,
                access: access,
                projects: [folder],
                homeInstructions: "Home policy",
                claudeFileReader: {
                    reads.append($0)
                    return "Repository policy"
                })
            XCTAssertEqual(reads, [folder.cwd])
            XCTAssertEqual(
                snapshot?.effectiveText(for: access),
                "Repository instructions (CLAUDE.md):\nRepository policy\n\n"
                    + "Workspace Instructions (Mechanician):\nApp policy")
            XCTAssertTrue(snapshot?.allowsCodexRepositoryInstructions == true)
        }

        for access in [ModelAccess.codexSubscription, .openAIAPI] {
            var didReadRepository = false
            let snapshot = WorkspaceInstructionResolver.snapshot(
                for: conversation,
                access: access,
                projects: [folder],
                homeInstructions: "Home policy",
                claudeFileReader: { _ in
                    didReadRepository = true
                    return "Must not load"
                })
            XCTAssertFalse(didReadRepository, "\(access) should add no per-turn CLAUDE.md I/O")
            XCTAssertEqual(snapshot?.effectiveText(for: access), "App policy")
        }
    }

    func testHomeAndTopicNeverImportTheFallbackHomeClaudeFile() {
        let topic = Project(name: "Topic", instructions: "Topic policy")
        for subject in [
            conversation(),
            conversation(projectID: topic.id),
        ] {
            var didReadRepository = false
            let snapshot = WorkspaceInstructionResolver.snapshot(
                for: subject,
                access: .anthropicAPI,
                projects: [topic],
                homeInstructions: "Home policy",
                claudeFileReader: { _ in
                    didReadRepository = true
                    return "Leaked home file"
                })
            XCTAssertFalse(didReadRepository)
            XCTAssertFalse(snapshot?.allowsCodexRepositoryInstructions ?? true)
            XCTAssertFalse(
                snapshot?.effectiveText(for: .anthropicAPI)?.contains("Leaked home file") ?? false)
        }
    }

    func testFolderlessConversationNeverInheritsTheVisibleWindowFolder() {
        let bridge = AgentBridge(
            settingsBaseOverride: FileManager.default.temporaryDirectory
                .appendingPathComponent("instruction-cwd-\(UUID().uuidString)"),
            environmentOverride: [:])
        defer { bridge.shutdown() }
        bridge.cwd = "/private/tmp/visible-project"

        XCTAssertEqual(
            bridge.turnCwd(for: conversation()),
            FileManager.default.homeDirectoryForCurrentUser.path)
        XCTAssertEqual(
            bridge.turnCwd(for: conversation(cwd: "/private/tmp/conversation-project")),
            "/private/tmp/conversation-project")
    }

    func testWireProjectionKeepsCodexDiscoveryNativeAndOpenAIAppOnly() throws {
        let folder = Project(name: "Folder", instructions: "App policy", cwd: "/tmp/project")
        let subject = conversation(cwd: folder.cwd, projectID: folder.id)
        let snapshot = try XCTUnwrap(WorkspaceInstructionResolver.snapshot(
            for: subject,
            access: .codexSubscription,
            projects: [folder],
            homeInstructions: "",
            claudeFileReader: { _ in XCTFail("Codex should not read CLAUDE.md"); return nil }))
        let revision = snapshot.sessionRevision(for: .codexSubscription)

        var codex: [String: Any] = [:]
        AgentBridge.applyWorkspaceInstructionSnapshot(
            snapshot,
            revision: revision,
            access: .codexSubscription,
            to: &codex)
        XCTAssertEqual(codex["projectInstructions"] as? String, "App policy")
        XCTAssertEqual(codex["workspaceInstructionsRevision"] as? String, revision)
        XCTAssertEqual(codex["allowRepositoryInstructions"] as? Bool, true)

        var openAI: [String: Any] = [:]
        AgentBridge.applyWorkspaceInstructionSnapshot(
            snapshot,
            revision: revision,
            access: .openAIAPI,
            to: &openAI)
        XCTAssertEqual(openAI["projectInstructions"] as? String, "App policy")
        XCTAssertNil(openAI["allowRepositoryInstructions"])
    }

    func testSessionRevisionChangesWithWorkspaceOrInstructionText() throws {
        let id = UUID()
        let first = Project(id: id, name: "One", instructions: "First", cwd: "/tmp/one")
        let changed = Project(id: id, name: "One", instructions: "Second", cwd: "/tmp/one")
        let subject = conversation(cwd: first.cwd, projectID: id)
        let a = try XCTUnwrap(WorkspaceInstructionResolver.snapshot(
            for: subject, access: .codexSubscription, projects: [first],
            homeInstructions: "", claudeFileReader: { _ in nil }))
        let b = try XCTUnwrap(WorkspaceInstructionResolver.snapshot(
            for: subject, access: .codexSubscription, projects: [changed],
            homeInstructions: "", claudeFileReader: { _ in nil }))

        XCTAssertNotEqual(
            a.sessionRevision(for: .codexSubscription),
            b.sessionRevision(for: .codexSubscription))
        XCTAssertEqual(
            a.sessionRevision(for: .codexSubscription),
            a.sessionRevision(for: .codexSubscription))
    }



    func testOpaqueSessionResumesOnlyAtTheInstructionRevisionThatCreatedIt() {
        let revision = "revision-a"
        let conversation = Conversation(
            title: "Session",
            cwd: "",
            sdkSessionId: "opaque-session",
            sdkSessionWorkspaceInstructionsRevision: revision,
            messages: [],
            updatedAt: Date())
        let profile = TenantProfile.default

        XCTAssertEqual(
            AgentBridge.resumableSessionID(
                for: conversation,
                access: .codexSubscription,
                profile: profile,
                workspaceInstructionsRevision: revision),
            "opaque-session")
        XCTAssertNil(
            AgentBridge.resumableSessionID(
                for: conversation,
                access: .codexSubscription,
                profile: profile,
                workspaceInstructionsRevision: "revision-b"))
        XCTAssertEqual(
            AgentBridge.resumableSessionID(
                for: conversation,
                access: .anthropicAPI,
                profile: profile,
                workspaceInstructionsRevision: "revision-b"),
            "opaque-session",
            "Claude accepts a changed preset append on resume; only its spare-process identity changes")
    }

    func testWorkspaceInstructionSessionRevisionPersistsAndLegacySidecarsDecodeNil() throws {
        let original = Conversation(
            title: "Persisted revision",
            cwd: "",
            sdkSessionId: "opaque-session",
            sdkSessionWorkspaceInstructionsRevision: "workspace-revision",
            messages: [],
            updatedAt: Date(timeIntervalSinceReferenceDate: 123))
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        let data = try encoder.encode(original)

        XCTAssertEqual(
            try decoder.decode(Conversation.self, from: data)
                .sdkSessionWorkspaceInstructionsRevision,
            "workspace-revision")

        var legacyObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any])
        legacyObject.removeValue(forKey: "sdkSessionWorkspaceInstructionsRevision")
        let legacyData = try JSONSerialization.data(withJSONObject: legacyObject)
        XCTAssertNil(
            try decoder.decode(Conversation.self, from: legacyData)
                .sdkSessionWorkspaceInstructionsRevision)
    }

    func testHomeSettingsPersistSeparatelyWithoutCreatingAProject() throws {
        let support = try temporarySupport("mechanician-home-instructions")
        defer { try? FileManager.default.removeItem(at: support) }
        var store: ProjectStore? = ProjectStore(appSupportBaseOverride: support)

        XCTAssertTrue(store?.setInstructions("Home policy", for: .home) == true)
        store?.flushSaves()
        XCTAssertEqual(store?.projects.count, 0)
        store = nil

        let reloaded = ProjectStore(appSupportBaseOverride: support)
        XCTAssertEqual(reloaded.homeSettings.instructions, "Home policy")
        XCTAssertTrue(reloaded.projects.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: support.appendingPathComponent("home-workspace.json").path))
    }

    func testRemovingAProjectDoesNotRemoveHomeSettings() throws {
        let support = try temporarySupport("mechanician-home-project-isolation")
        defer { try? FileManager.default.removeItem(at: support) }
        let store = ProjectStore(appSupportBaseOverride: support)
        let project = Project(name: "Disposable", instructions: "Project policy")
        XCTAssertTrue(store.setInstructions("Home policy", for: .home))
        store.upsert(project)
        store.flushSaves()

        store.remove(project.id)
        store.flushSaves()

        let reloaded = ProjectStore(appSupportBaseOverride: support)
        XCTAssertEqual(reloaded.homeSettings.instructions, "Home policy")
        XCTAssertTrue(reloaded.projects.isEmpty)
    }

    func testCorruptHomeSettingsAreQuarantinedAndDefaultSafely() throws {
        let support = try temporarySupport("mechanician-home-corrupt")
        defer { try? FileManager.default.removeItem(at: support) }
        let homeFile = support.appendingPathComponent("home-workspace.json")
        try Data("{not-json".utf8).write(to: homeFile)

        let store = ProjectStore(appSupportBaseOverride: support)
        store.flushSaves()

        XCTAssertEqual(store.homeSettings.instructions, "")
        XCTAssertFalse(FileManager.default.fileExists(atPath: homeFile.path))
        let quarantined = try FileManager.default.contentsOfDirectory(
            at: support, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("home-workspace.json.corrupt-") }
        XCTAssertEqual(quarantined.count, 1)
    }

    func testLegacyProjectsDirectoryMovesToWorkspacesWithoutRewritingRecords() throws {
        let support = try temporarySupport("mechanician-workspace-directory-migration")
        defer { try? FileManager.default.removeItem(at: support) }
        let legacy = support.appendingPathComponent("projects", isDirectory: true)
        try FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: true)
        let project = Project(
            name: "Existing Workspace",
            instructions: "Preserve this policy",
            cwd: "/private/tmp/existing-workspace",
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            updatedAt: Date(timeIntervalSince1970: 1_700_000_100))
        let original = try encodedProject(project)
        let filename = "\(project.id.uuidString).json"
        try original.write(to: legacy.appendingPathComponent(filename), options: .atomic)

        var store: ProjectStore? = ProjectStore(appSupportBaseOverride: support)

        let canonical = support.appendingPathComponent("workspaces", isDirectory: true)
        XCTAssertEqual(store?.project(project.id)?.instructions, "Preserve this policy")
        XCTAssertEqual(try Data(contentsOf: canonical.appendingPathComponent(filename)), original)
        XCTAssertEqual(
            try FileManager.default.destinationOfSymbolicLink(atPath: legacy.path),
            "workspaces")

        XCTAssertNotNil(store?.update(project.id) { $0.name = "Renamed Workspace" })
        store?.flushSaves()
        store = nil

        let reloaded = ProjectStore(appSupportBaseOverride: support)
        XCTAssertEqual(reloaded.project(project.id)?.name, "Renamed Workspace")
        XCTAssertEqual(
            try Data(contentsOf: legacy.appendingPathComponent(filename)),
            try Data(contentsOf: canonical.appendingPathComponent(filename)),
            "the legacy path is an alias to the canonical bytes, not a duplicate authority")
    }

    func testInterruptedDualDirectoryMigrationPreservesDivergenceAndConvergesToOneAuthority() throws {
        let support = try temporarySupport("mechanician-workspace-directory-interrupted")
        defer { try? FileManager.default.removeItem(at: support) }
        let canonical = support.appendingPathComponent("workspaces", isDirectory: true)
        let legacy = support.appendingPathComponent("projects", isDirectory: true)
        try FileManager.default.createDirectory(at: canonical, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: true)

        let sharedID = UUID()
        let canonicalProject = Project(id: sharedID, name: "Canonical Workspace")
        let legacyConflict = Project(id: sharedID, name: "Legacy Divergence")
        let legacyOnly = Project(name: "Recovered Workspace")
        let sharedFilename = "\(sharedID.uuidString).json"
        try encodedProject(canonicalProject)
            .write(to: canonical.appendingPathComponent(sharedFilename), options: .atomic)
        try encodedProject(legacyConflict)
            .write(to: legacy.appendingPathComponent(sharedFilename), options: .atomic)
        try encodedProject(legacyOnly)
            .write(to: legacy.appendingPathComponent("\(legacyOnly.id.uuidString).json"), options: .atomic)

        let store = ProjectStore(appSupportBaseOverride: support)

        XCTAssertEqual(store.project(sharedID)?.name, "Canonical Workspace")
        XCTAssertEqual(store.project(legacyOnly.id)?.name, "Recovered Workspace")
        XCTAssertEqual(
            try FileManager.default.destinationOfSymbolicLink(atPath: legacy.path),
            "workspaces")
        let preserved = try FileManager.default.contentsOfDirectory(
            at: canonical, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("\(sharedFilename).legacy-conflict-") }
        XCTAssertEqual(preserved.count, 1, "a divergent record must remain recoverable")
        XCTAssertEqual(try Data(contentsOf: preserved[0]), try encodedProject(legacyConflict))
    }

    func testFreshWorkspaceStoreUsesCanonicalDirectoryAndCreatesDowngradeAlias() throws {
        let support = try temporarySupport("mechanician-workspace-directory-fresh")
        defer { try? FileManager.default.removeItem(at: support) }
        let store = ProjectStore(appSupportBaseOverride: support)
        let project = Project(name: "Fresh Workspace")

        store.upsert(project)
        store.flushSaves()

        let canonical = support.appendingPathComponent("workspaces", isDirectory: true)
        let legacy = support.appendingPathComponent("projects", isDirectory: true)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: canonical.appendingPathComponent("\(project.id.uuidString).json").path))
        XCTAssertEqual(
            try FileManager.default.destinationOfSymbolicLink(atPath: legacy.path),
            "workspaces")
    }
}
