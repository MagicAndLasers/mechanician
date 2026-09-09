import XCTest
@testable import Mechanician

/// Existing-Workspace folder reassignment over P1b's bounded Conversation working set.
///
/// Folder assignment is a graph mutation, not a Project-only edit: every Workspace member and
/// every foreign Conversation holding a moved artifact snapshot must be resident and pinned before
/// anything changes. These tests begin with that entire graph evicted so a synchronous-hydration
/// regression cannot hide behind the eager test store.
@MainActor
final class WorkspaceFolderAssignmentAsyncTests: XCTestCase {
    private struct Fixture {
        let project: Project
        let foreignProject: Project
        let owner: Conversation
        let member: Conversation
        let foreignHolder: Conversation
        let artifact: Artifact

        var conversationIDs: Set<UUID> {
            [owner.id, member.id, foreignHolder.id]
        }
    }

    private var support: URL!
    private var conversations: ConversationStore!
    private var artifacts: ArtifactStore!
    private var projects: ProjectStore!

    override func setUp() async throws {
        try await super.setUp()
        support = FileManager.default.temporaryDirectory.appendingPathComponent(
            "workspace-folder-assignment-async-\(UUID().uuidString)",
            isDirectory: true)
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        conversations = ConversationStore(
            appSupportBaseOverride: support,
            watchesDirectory: false,
            residencyMode: .boundedAfterRecovery)
        artifacts = ArtifactStore(
            appSupportBaseOverride: support,
            watchesDirectory: false)
        projects = ProjectStore(appSupportBaseOverride: support)
        await awaitBoundedResidency()
    }

    override func tearDown() async throws {
        conversations?.flushSaves()
        artifacts?.flushSaves()
        projects?.flushSaves()
        if let support { try? FileManager.default.removeItem(at: support) }
        conversations = nil
        artifacts = nil
        projects = nil
        support = nil
        try await super.tearDown()
    }

    func testEvictedWorkspaceGraphMovesMembersAndConvergesForeignArtifactHolder() async throws {
        let seeded = fixture()
        await evict(seeded.conversationIDs)
        XCTAssertTrue(seeded.conversationIDs.isDisjoint(with: conversations.residentConversationIDs))

        let result = await reassign(seeded.project, to: "/destination/reassigned")

        XCTAssertEqual(result, .changed)
        XCTAssertEqual(conversations.synchronousHydrationCount, 0)
        for id in seeded.conversationIDs {
            XCTAssertEqual(
                conversations.hydrationDecodeCounts[id],
                1,
                "each evicted member or foreign holder should be decoded exactly once")
        }

        let owner = try await acquire(seeded.owner.id)
        let member = try await acquire(seeded.member.id)
        let foreign = try await acquire(seeded.foreignHolder.id)
        let durable = try XCTUnwrap(
            artifacts.artifacts.first { $0.uuid == seeded.artifact.uuid })
        XCTAssertEqual(projects.project(seeded.project.id)?.cwd, "/destination/reassigned")
        XCTAssertEqual(owner.projectID, seeded.project.id)
        XCTAssertEqual(owner.cwd, "/destination/reassigned")
        XCTAssertEqual(member.projectID, seeded.project.id)
        XCTAssertEqual(member.cwd, "/destination/reassigned")
        XCTAssertEqual(durable.workspaceID, seeded.project.id)
        XCTAssertEqual(durable.cwd, "/destination/reassigned")
        XCTAssertEqual(owner.artifacts.first, durable)

        XCTAssertEqual(foreign.projectID, seeded.foreignProject.id)
        XCTAssertEqual(foreign.cwd, seeded.foreignHolder.cwd)
        XCTAssertEqual(foreign.artifacts.first, durable)

        conversations.flushSaves()
        artifacts.flushSaves()
        projects.flushSaves()
        let reloadedProjects = ProjectStore(appSupportBaseOverride: support)
        let reloadedArtifacts = ArtifactStore(
            appSupportBaseOverride: support,
            watchesDirectory: false)
        XCTAssertEqual(
            reloadedProjects.project(seeded.project.id)?.cwd,
            "/destination/reassigned")
        XCTAssertEqual(
            reloadedArtifacts.artifacts.first { $0.uuid == seeded.artifact.uuid }?.cwd,
            "/destination/reassigned")
        XCTAssertEqual(
            try sidecarConversation(seeded.owner.id).cwd,
            "/destination/reassigned")
        let reloadedForeign = try sidecarConversation(seeded.foreignHolder.id)
        XCTAssertEqual(reloadedForeign.cwd, seeded.foreignHolder.cwd)
        XCTAssertEqual(reloadedForeign.artifacts.first?.cwd, "/destination/reassigned")
    }

    func testMissingForeignHolderAbortsEveryStoreAndReleasesPlacementLease() async throws {
        let seeded = fixture()
        await evict(seeded.conversationIDs)
        let projectBefore = try data(at: projectSidecar(seeded.project.id))
        let ownerBefore = try data(at: conversationSidecar(seeded.owner.id))
        let memberBefore = try data(at: conversationSidecar(seeded.member.id))
        let artifactBefore = try data(at: artifactSidecar(seeded.artifact.uuid))
        let foreignURL = conversationSidecar(seeded.foreignHolder.id)
        let foreignBefore = try data(at: foreignURL)
        try FileManager.default.removeItem(at: foreignURL)

        let result = await reassign(seeded.project, to: "/destination/missing-holder")

        XCTAssertEqual(result, .bindingUnavailable(.missing))
        XCTAssertFalse(WorkspaceAdoption.isPlacementOperationInProgress)
        XCTAssertEqual(conversations.synchronousHydrationCount, 0)
        XCTAssertEqual(try data(at: projectSidecar(seeded.project.id)), projectBefore)
        XCTAssertEqual(try data(at: conversationSidecar(seeded.owner.id)), ownerBefore)
        XCTAssertEqual(try data(at: conversationSidecar(seeded.member.id)), memberBefore)
        XCTAssertEqual(try data(at: artifactSidecar(seeded.artifact.uuid)), artifactBefore)
        XCTAssertEqual(projects.project(seeded.project.id)?.cwd, seeded.project.cwd)
        XCTAssertEqual(
            artifacts.artifacts.first { $0.uuid == seeded.artifact.uuid },
            seeded.artifact)

        // A failed graph acquisition must not strand the process-wide placement lease. Restore the
        // authoritative sidecar and prove an immediate retry can own and complete the operation.
        try foreignBefore.write(to: foreignURL, options: .atomic)
        let retry = await reassign(seeded.project, to: "/destination/retry")
        XCTAssertEqual(retry, .changed)
        XCTAssertFalse(WorkspaceAdoption.isPlacementOperationInProgress)
    }

    func testCorruptForeignHolderAbortsWithoutPartialPlacement() async throws {
        let seeded = fixture()
        await evict(seeded.conversationIDs)
        let projectBefore = try data(at: projectSidecar(seeded.project.id))
        let ownerBefore = try data(at: conversationSidecar(seeded.owner.id))
        let artifactBefore = try data(at: artifactSidecar(seeded.artifact.uuid))
        try Data("not-json".utf8).write(
            to: conversationSidecar(seeded.foreignHolder.id),
            options: .atomic)

        let result = await reassign(seeded.project, to: "/destination/corrupt-holder")

        XCTAssertEqual(result, .bindingUnavailable(.unreadable))
        XCTAssertFalse(WorkspaceAdoption.isPlacementOperationInProgress)
        XCTAssertEqual(conversations.synchronousHydrationCount, 0)
        XCTAssertEqual(try data(at: projectSidecar(seeded.project.id)), projectBefore)
        XCTAssertEqual(try data(at: conversationSidecar(seeded.owner.id)), ownerBefore)
        XCTAssertEqual(try data(at: artifactSidecar(seeded.artifact.uuid)), artifactBefore)
        XCTAssertEqual(projects.project(seeded.project.id)?.cwd, seeded.project.cwd)
    }

    func testCollisionIntroducedDuringHydrationAbortsPreparedMove() async throws {
        let seeded = fixture()
        await evict(seeded.conversationIDs)
        let artifactBefore = try XCTUnwrap(
            artifacts.artifacts.first { $0.uuid == seeded.artifact.uuid })
        let destination = "/destination/concurrent-collision"
        let collision = Project(name: "Claimed in another window", cwd: destination)

        let result = await withCheckedContinuation {
            (continuation: CheckedContinuation<WorkspaceFolderReassignmentResult, Never>) in
            XCTAssertTrue(WorkspaceAdoption.reassignWorkspaceFolderAfterAcquiring(
                request(seeded.project, destination: destination),
                projects: projects,
                conversations: conversations,
                artifactStore: artifacts,
                synchronizeLiveState: false
            ) { continuation.resume(returning: $0) })
            projects.upsert(collision)
        }

        XCTAssertEqual(result, .collision(collision.displayName))
        XCTAssertEqual(projects.project(seeded.project.id)?.cwd, seeded.project.cwd)
        XCTAssertEqual(
            artifacts.artifacts.first { $0.uuid == seeded.artifact.uuid },
            artifactBefore)
        let owner = try await acquire(seeded.owner.id)
        XCTAssertEqual(owner.cwd, seeded.owner.cwd)
        XCTAssertEqual(conversations.synchronousHydrationCount, 0)
        XCTAssertFalse(WorkspaceAdoption.isPlacementOperationInProgress)
    }

    func testSourceBindingChangedDuringHydrationAbortsPreparedMove() async throws {
        let seeded = fixture()
        await evict(seeded.conversationIDs)
        let artifactBefore = try XCTUnwrap(
            artifacts.artifacts.first { $0.uuid == seeded.artifact.uuid })
        let concurrentCwd = "/source/changed-elsewhere"

        let result = await withCheckedContinuation {
            (continuation: CheckedContinuation<WorkspaceFolderReassignmentResult, Never>) in
            XCTAssertTrue(WorkspaceAdoption.reassignWorkspaceFolderAfterAcquiring(
                request(seeded.project, destination: "/destination/stale-request"),
                projects: projects,
                conversations: conversations,
                artifactStore: artifacts,
                synchronizeLiveState: false
            ) { continuation.resume(returning: $0) })
            projects.update(seeded.project.id) { $0.cwd = concurrentCwd }
        }

        XCTAssertEqual(result, .sourceChanged)
        XCTAssertEqual(projects.project(seeded.project.id)?.cwd, concurrentCwd)
        XCTAssertEqual(
            artifacts.artifacts.first { $0.uuid == seeded.artifact.uuid },
            artifactBefore)
        let owner = try await acquire(seeded.owner.id)
        XCTAssertEqual(owner.cwd, seeded.owner.cwd)
        XCTAssertEqual(conversations.synchronousHydrationCount, 0)
        XCTAssertFalse(WorkspaceAdoption.isPlacementOperationInProgress)
    }

    func testConcurrentProjectMetadataEditSurvivesFolderCommitAndReload() async throws {
        let seeded = fixture()
        await evict(seeded.conversationIDs)

        let result = await withCheckedContinuation {
            (continuation: CheckedContinuation<WorkspaceFolderReassignmentResult, Never>) in
            XCTAssertTrue(WorkspaceAdoption.reassignWorkspaceFolderAfterAcquiring(
                request(seeded.project, destination: "/destination/metadata"),
                projects: projects,
                conversations: conversations,
                artifactStore: artifacts,
                synchronizeLiveState: false
            ) { continuation.resume(returning: $0) })
            projects.update(seeded.project.id) {
                $0.name = "Edited while Conversations load"
                $0.goal = "Preserve the newest goal"
            }
        }
        projects.flushSaves()

        XCTAssertEqual(result, .changed)
        XCTAssertEqual(projects.project(seeded.project.id)?.cwd, "/destination/metadata")
        XCTAssertEqual(
            projects.project(seeded.project.id)?.name,
            "Edited while Conversations load")
        XCTAssertEqual(
            projects.project(seeded.project.id)?.goal,
            "Preserve the newest goal")
        let reloaded = ProjectStore(appSupportBaseOverride: support)
        XCTAssertEqual(reloaded.project(seeded.project.id)?.cwd, "/destination/metadata")
        XCTAssertEqual(
            reloaded.project(seeded.project.id)?.name,
            "Edited while Conversations load")
        XCTAssertEqual(
            reloaded.project(seeded.project.id)?.goal,
            "Preserve the newest goal")
        XCTAssertEqual(conversations.synchronousHydrationCount, 0)
    }

    func testMemberAddedWhileInitialGraphHydratesJoinsTheStableCommit() async throws {
        let seeded = fixture()
        await evict(seeded.conversationIDs)
        var lateMember = Conversation(
            id: UUID(uuidString: "10000000-0000-0000-0000-000000000004")!,
            title: "Joined during preparation",
            cwd: seeded.project.cwd,
            sdkSessionId: nil,
            messages: [TranscriptEntry(kind: .user, text: "Include this late member")],
            updatedAt: Date())
        lateMember.projectID = seeded.project.id

        let result = await withCheckedContinuation {
            (continuation: CheckedContinuation<WorkspaceFolderReassignmentResult, Never>) in
            XCTAssertTrue(WorkspaceAdoption.reassignWorkspaceFolderAfterAcquiring(
                request(seeded.project, destination: "/destination/stabilized"),
                projects: projects,
                conversations: conversations,
                artifactStore: artifacts,
                synchronizeLiveState: false
            ) { continuation.resume(returning: $0) })
            conversations.upsert(lateMember)
        }

        XCTAssertEqual(result, .changed)
        let committedLateMember = try await acquire(lateMember.id)
        XCTAssertEqual(committedLateMember.projectID, seeded.project.id)
        XCTAssertEqual(committedLateMember.cwd, "/destination/stabilized")
        XCTAssertEqual(conversations.synchronousHydrationCount, 0)
    }

    func testSecondPlacementRequestIsRejectedWhileFolderGraphHydrates() async throws {
        let seeded = fixture()
        await evict(seeded.conversationIDs)
        var secondResult: WorkspaceFolderReassignmentResult?

        let firstResult = await withCheckedContinuation {
            (continuation: CheckedContinuation<WorkspaceFolderReassignmentResult, Never>) in
            XCTAssertTrue(WorkspaceAdoption.reassignWorkspaceFolderAfterAcquiring(
                request(seeded.project, destination: "/destination/first"),
                projects: projects,
                conversations: conversations,
                artifactStore: artifacts,
                synchronizeLiveState: false
            ) { continuation.resume(returning: $0) })
            let secondAccepted = WorkspaceAdoption.reassignWorkspaceFolderAfterAcquiring(
                request(seeded.project, destination: "/destination/second"),
                projects: projects,
                conversations: conversations,
                artifactStore: artifacts,
                synchronizeLiveState: false
            ) { secondResult = $0 }
            XCTAssertFalse(secondAccepted)
            XCTAssertEqual(secondResult, .moveInProgress)
        }

        XCTAssertEqual(firstResult, .changed)
        XCTAssertEqual(projects.project(seeded.project.id)?.cwd, "/destination/first")
        XCTAssertFalse(WorkspaceAdoption.isPlacementOperationInProgress)
        XCTAssertEqual(conversations.synchronousHydrationCount, 0)
    }

    private func fixture() -> Fixture {
        let project = Project(
            id: UUID(uuidString: "30000000-0000-0000-0000-000000000001")!,
            name: "Source Workspace",
            goal: "Preserve metadata",
            cwd: "/source/workspace")
        let foreignProject = Project(
            id: UUID(uuidString: "30000000-0000-0000-0000-000000000002")!,
            name: "Foreign Workspace",
            cwd: "/foreign/workspace")
        projects.upsert(project)
        projects.upsert(foreignProject)

        var owner = Conversation(
            id: UUID(uuidString: "10000000-0000-0000-0000-000000000001")!,
            title: "Artifact owner",
            cwd: project.cwd,
            sdkSessionId: nil,
            messages: [TranscriptEntry(kind: .user, text: "Create the shared plan")],
            updatedAt: Date())
        owner.projectID = project.id
        let artifact = artifacts.upsertFromAgent(
            title: "Shared plan",
            type: "markdown",
            source: "# Exact shared plan",
            workspaceID: project.id,
            conversationID: owner.id,
            conversationTitle: owner.title,
            cwd: project.cwd,
            preferredID: UUID(uuidString: "20000000-0000-0000-0000-000000000001")!)
        owner.artifacts = [artifact]

        var member = Conversation(
            id: UUID(uuidString: "10000000-0000-0000-0000-000000000002")!,
            title: "Second member",
            cwd: project.cwd,
            sdkSessionId: nil,
            messages: [TranscriptEntry(kind: .assistant, text: "Workspace member")],
            updatedAt: Date())
        member.projectID = project.id
        member.draft = "Member state must survive"

        var foreignHolder = Conversation(
            id: UUID(uuidString: "10000000-0000-0000-0000-000000000003")!,
            title: "Foreign holder",
            cwd: foreignProject.cwd,
            sdkSessionId: nil,
            messages: [TranscriptEntry(kind: .user, text: "Review the shared plan")],
            updatedAt: Date())
        foreignHolder.projectID = foreignProject.id
        foreignHolder.draft = "Foreign placement must not move"
        foreignHolder.artifacts = [artifact]

        conversations.upsert(owner)
        conversations.upsert(member)
        conversations.upsert(foreignHolder)
        conversations.flushSaves()
        artifacts.flushSaves()
        projects.flushSaves()
        return Fixture(
            project: project,
            foreignProject: foreignProject,
            owner: owner,
            member: member,
            foreignHolder: foreignHolder,
            artifact: artifact)
    }

    private func request(
        _ project: Project,
        destination: String
    ) -> WorkspaceFolderReassignmentRequest {
        WorkspaceFolderReassignmentRequest(
            projectID: project.id,
            expectedCwd: project.cwd,
            destinationCwd: destination)
    }

    private func reassign(
        _ project: Project,
        to destination: String
    ) async -> WorkspaceFolderReassignmentResult {
        await withCheckedContinuation { continuation in
            _ = WorkspaceAdoption.reassignWorkspaceFolderAfterAcquiring(
                request(project, destination: destination),
                projects: projects,
                conversations: conversations,
                artifactStore: artifacts,
                synchronizeLiveState: false
            ) { continuation.resume(returning: $0) }
        }
    }

    private func awaitBoundedResidency() async {
        await withCheckedContinuation { continuation in
            conversations.whenReady { continuation.resume() }
        }
        for _ in 0..<10_000 {
            if conversations.activeResidencyMode == .boundedAfterRecovery { return }
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTFail("bounded residency did not activate after projection reconciliation")
    }

    private func evict(_ ids: Set<UUID>) async {
        for _ in 0..<10_000 {
            conversations.trimResidencyIfNeeded(evictAllEligible: true)
            if ids.isDisjoint(with: conversations.residentConversationIDs) { return }
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTFail("records did not become eviction-eligible after their saves completed")
    }

    private func acquire(_ id: UUID) async throws -> Conversation {
        try await withCheckedThrowingContinuation { continuation in
            conversations.acquireConversation(id) { continuation.resume(with: $0) }
        }
    }

    private func conversationSidecar(_ id: UUID) -> URL {
        support
            .appendingPathComponent("conversations", isDirectory: true)
            .appendingPathComponent("\(id.uuidString).json")
    }

    private func projectSidecar(_ id: UUID) -> URL {
        support
            .appendingPathComponent("workspaces", isDirectory: true)
            .appendingPathComponent("\(id.uuidString).json")
    }

    private func artifactSidecar(_ id: UUID) -> URL {
        support
            .appendingPathComponent("artifacts", isDirectory: true)
            .appendingPathComponent("\(id.uuidString).json")
    }

    private func data(at url: URL) throws -> Data {
        try Data(contentsOf: url)
    }

    private func sidecarConversation(_ id: UUID) throws -> Conversation {
        try ConversationStore.makeDecoder().decode(
            Conversation.self,
            from: data(at: conversationSidecar(id)))
    }
}
