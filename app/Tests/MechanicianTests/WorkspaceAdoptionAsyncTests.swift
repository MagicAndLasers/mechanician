import XCTest
@testable import Mechanician

/// Workspace moves over P1b's bounded Conversation working set.
///
/// These cover the seam that the eager-store adoption tests cannot: every affected full record is
/// absent from memory when the gesture begins. The coordinator must hydrate the complete impact
/// set off-main, converge durable and nested artifact copies exactly, and refuse the whole move if
/// even one referenced sidecar cannot be read.
@MainActor
final class WorkspaceAdoptionAsyncTests: XCTestCase {
    private struct Fixture {
        var owner: Conversation
        var reference: Conversation
        var artifact: Artifact
    }

    private var support: URL!
    private var conversations: ConversationStore!
    private var artifacts: ArtifactStore!
    private var projects: ProjectStore!

    override func setUp() async throws {
        try await super.setUp()
        support = FileManager.default.temporaryDirectory.appendingPathComponent(
            "workspace-adoption-async-\(UUID().uuidString)",
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

    private func fixture() -> Fixture {
        let sourceWorkspaceID = UUID()
        var owner = Conversation(
            id: UUID(uuidString: "10000000-0000-0000-0000-000000000001")!,
            title: "Artifact owner",
            cwd: "/source/owner",
            sdkSessionId: nil,
            messages: [TranscriptEntry(kind: .user, text: "Create the plan")],
            updatedAt: Date())
        owner.projectID = sourceWorkspaceID

        let artifact = artifacts.upsertFromAgent(
            title: "Plan",
            type: "markdown",
            source: "# Exact plan",
            workspaceID: sourceWorkspaceID,
            conversationID: owner.id,
            conversationTitle: owner.title,
            cwd: owner.cwd,
            preferredID: UUID(uuidString: "20000000-0000-0000-0000-000000000001")!)
        owner.artifacts = [artifact]

        var reference = Conversation(
            id: UUID(uuidString: "10000000-0000-0000-0000-000000000002")!,
            title: "External reference",
            cwd: "/source/reference",
            sdkSessionId: nil,
            messages: [TranscriptEntry(kind: .user, text: "Review the shared plan")],
            updatedAt: Date())
        reference.projectID = UUID()
        reference.draft = "Reference draft must not move"
        reference.artifacts = [artifact]

        conversations.upsert(owner)
        conversations.upsert(reference)
        conversations.flushSaves()
        artifacts.flushSaves()
        return Fixture(owner: owner, reference: reference, artifact: artifact)
    }

    private func evict(_ ids: Set<UUID>) async {
        for _ in 0..<10_000 {
            conversations.trimResidencyIfNeeded(evictAllEligible: true)
            if ids.isDisjoint(with: conversations.residentConversationIDs) { return }
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTFail("records did not become eviction-eligible after their saves completed")
    }

    private func awaitUndoOperation(_ undoManager: UndoManager) async {
        for _ in 0..<10_000 {
            if !WorkspaceMoveUndo.isApplying(on: undoManager),
               !WorkspaceAdoption.isPlacementOperationInProgress { return }
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTFail("Workspace Undo/Redo did not finish")
    }

    private func moveConversations(
        _ ids: Set<UUID>,
        into destination: WorkspaceDestination,
        undoManager: UndoManager? = nil
    ) async -> WorkspaceAdoptionResult {
        await withCheckedContinuation { continuation in
            WorkspaceAdoption.adoptAfterAcquiring(
                conversations: ids,
                into: destination,
                conversations: conversations,
                artifactStore: artifacts,
                synchronizeLiveState: false,
                undoManager: undoManager
            ) { continuation.resume(returning: $0) }
        }
    }

    private func moveArtifacts(
        _ ids: Set<UUID>,
        into destination: WorkspaceDestination,
        undoManager: UndoManager? = nil
    ) async -> WorkspaceAdoptionResult {
        await withCheckedContinuation { continuation in
            WorkspaceAdoption.adoptAfterAcquiring(
                artifacts: ids,
                into: destination,
                conversations: conversations,
                artifactStore: artifacts,
                synchronizeLiveState: false,
                undoManager: undoManager
            ) { continuation.resume(returning: $0) }
        }
    }

    private func createWorkspace(
        for pending: PendingWorkspaceAdoption,
        draft: Project,
        undoManager: UndoManager? = nil
    ) async -> (WorkspaceAdoptionResult, Project?) {
        await withCheckedContinuation { continuation in
            let accepted = WorkspaceAdoption.adoptAfterAcquiring(
                pending,
                intoNewWorkspace: draft,
                projects: projects,
                conversations: conversations,
                artifactStore: artifacts,
                synchronizeLiveState: false,
                undoManager: undoManager
            ) { result, project in
                continuation.resume(returning: (result, project))
            }
            XCTAssertTrue(accepted)
        }
    }

    func testNewWorkspaceConversationMovePublishesAfterOffMainImpactHydration() async throws {
        let seeded = fixture()
        let affectedIDs = Set([seeded.owner.id, seeded.reference.id])
        await evict(affectedIDs)
        let requestID = try XCTUnwrap(
            projects.beginWorkspaceAdoption(.conversations([seeded.owner.id])))
        let pending = try XCTUnwrap(projects.pendingWorkspaceAdoption)
        let draft = Project(
            id: UUID(uuidString: "30000000-0000-0000-0000-000000000001")!,
            name: "New destination",
            goal: "Prepared before publication",
            cwd: "/destination/new")
        let undoManager = UndoManager()
        var competingResult: WorkspaceAdoptionResult?

        let outcome = await withCheckedContinuation {
            (continuation: CheckedContinuation<(WorkspaceAdoptionResult, Project?), Never>) in
            let accepted = WorkspaceAdoption.adoptAfterAcquiring(
                pending,
                intoNewWorkspace: draft,
                projects: projects,
                conversations: conversations,
                artifactStore: artifacts,
                synchronizeLiveState: false,
                undoManager: undoManager
            ) { result, project in
                continuation.resume(returning: (result, project))
            }
            XCTAssertTrue(accepted)
            XCTAssertTrue(WorkspaceAdoption.isPlacementOperationInProgress)
            XCTAssertTrue(
                projects.projects.isEmpty,
                "the destination must stay invisible while staging and hydration are suspended")
            let secondAccepted = WorkspaceAdoption.adoptAfterAcquiring(
                conversations: [seeded.reference.id],
                into: .home,
                conversations: conversations,
                artifactStore: artifacts,
                synchronizeLiveState: false
            ) { competingResult = $0 }
            XCTAssertFalse(secondAccepted)
            XCTAssertEqual(competingResult, .moveInProgress)
        }

        XCTAssertEqual(outcome.0, .moved(conversations: 1, artifacts: 1))
        XCTAssertEqual(outcome.1?.id, draft.id)
        XCTAssertNil(projects.pendingWorkspaceAdoption)
        XCTAssertFalse(WorkspaceAdoption.isPlacementOperationInProgress)
        XCTAssertEqual(conversations.synchronousHydrationCount, 0)
        XCTAssertTrue(undoManager.canUndo)
        XCTAssertTrue(undoManager.undoMenuItemTitle.contains(WorkspaceMoveUndo.actionName(conversations: 1)))

        let projectSidecar = support
            .appendingPathComponent("workspaces", isDirectory: true)
            .appendingPathComponent("\(draft.id.uuidString).json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: projectSidecar.path))
        let reloadedProjects = ProjectStore(appSupportBaseOverride: support)
        XCTAssertEqual(reloadedProjects.project(draft.id)?.name, draft.name)
        XCTAssertEqual(reloadedProjects.project(draft.id)?.cwd, draft.cwd)

        let owner = try await acquire(seeded.owner.id)
        let reference = try await acquire(seeded.reference.id)
        XCTAssertEqual(owner.projectID, draft.id)
        XCTAssertEqual(owner.cwd, draft.cwd)
        XCTAssertEqual(reference.projectID, seeded.reference.projectID)
        XCTAssertEqual(reference.artifacts.first?.workspaceID, draft.id)
        XCTAssertEqual(reference.artifacts.first?.cwd, draft.cwd)
        XCTAssertEqual(
            artifacts.artifacts.first { $0.uuid == seeded.artifact.uuid }?.workspaceID,
            draft.id)

        undoManager.undo()
        await awaitUndoOperation(undoManager)
        XCTAssertEqual(
            conversations.residentConversation(seeded.owner.id)?.projectID,
            seeded.owner.projectID)
        XCTAssertNotNil(
            projects.project(draft.id),
            "Undo reverses the move, not the explicit Workspace creation")
        XCTAssertEqual(projects.pendingWorkspaceAdoption?.id, nil)
        XCTAssertEqual(requestID, pending.id)
    }

    func testNewWorkspaceArtifactMoveHydratesEveryEvictedHolderOffMain() async throws {
        let seeded = fixture()
        await evict([seeded.owner.id, seeded.reference.id])
        _ = try XCTUnwrap(
            projects.beginWorkspaceAdoption(.artifacts([seeded.artifact.uuid])))
        let pending = try XCTUnwrap(projects.pendingWorkspaceAdoption)
        let draft = Project(name: "Artifact destination")
        let undoManager = UndoManager()

        let outcome = await createWorkspace(
            for: pending,
            draft: draft,
            undoManager: undoManager)

        XCTAssertEqual(outcome.0, .moved(conversations: 0, artifacts: 1))
        XCTAssertEqual(outcome.1?.id, draft.id)
        XCTAssertEqual(conversations.synchronousHydrationCount, 0)
        XCTAssertNil(projects.pendingWorkspaceAdoption)
        XCTAssertTrue(undoManager.undoMenuItemTitle.contains(WorkspaceMoveUndo.actionName(artifacts: 1)))
        XCTAssertEqual(
            artifacts.artifacts.first { $0.uuid == seeded.artifact.uuid }?.workspaceID,
            draft.id)
        let owner = try await acquire(seeded.owner.id)
        let reference = try await acquire(seeded.reference.id)
        XCTAssertEqual(owner.artifacts.first?.workspaceID, draft.id)
        XCTAssertEqual(reference.artifacts.first?.workspaceID, draft.id)
    }

    func testNewWorkspaceReusesFolderDestinationWithoutOverwritingItsMetadata() async throws {
        let seeded = fixture()
        await evict([seeded.owner.id, seeded.reference.id])
        let existing = Project(name: "Existing", goal: "Old goal", cwd: "/shared/folder")
        projects.upsert(existing)
        projects.flushSaves()
        _ = try XCTUnwrap(
            projects.beginWorkspaceAdoption(.conversations([seeded.owner.id])))
        let pending = try XCTUnwrap(projects.pendingWorkspaceAdoption)
        let draft = Project(name: "Renamed at commit", goal: "New goal", cwd: existing.cwd)

        let outcome = await withCheckedContinuation {
            (continuation: CheckedContinuation<(WorkspaceAdoptionResult, Project?), Never>) in
            XCTAssertTrue(WorkspaceAdoption.adoptAfterAcquiring(
                pending,
                intoNewWorkspace: draft,
                projects: projects,
                conversations: conversations,
                artifactStore: artifacts,
                synchronizeLiveState: false
            ) { result, project in
                continuation.resume(returning: (result, project))
            })
            projects.update(existing.id) {
                $0.name = "Edited while records hydrate"
                $0.goal = "Newest goal"
            }
        }
        projects.flushSaves()

        XCTAssertEqual(outcome.0, .moved(conversations: 1, artifacts: 1))
        XCTAssertEqual(outcome.1?.id, existing.id)
        XCTAssertNil(projects.project(draft.id))
        XCTAssertEqual(projects.project(existing.id)?.name, "Edited while records hydrate")
        XCTAssertEqual(projects.project(existing.id)?.goal, "Newest goal")
        let owner = try await acquire(seeded.owner.id)
        XCTAssertEqual(owner.projectID, existing.id)
        XCTAssertEqual(conversations.synchronousHydrationCount, 0)
    }

    func testNewWorkspaceReusesAConcurrentlyCreatedFolderWithoutRenamingIt() async throws {
        let seeded = fixture()
        await evict([seeded.owner.id, seeded.reference.id])
        _ = try XCTUnwrap(
            projects.beginWorkspaceAdoption(.conversations([seeded.owner.id])))
        let pending = try XCTUnwrap(projects.pendingWorkspaceAdoption)
        let draft = Project(name: "Stale draft name", cwd: "/concurrent/folder")
        let competing = Project(
            name: "Created in another window",
            goal: "Keep this metadata",
            cwd: draft.cwd)

        let outcome = await withCheckedContinuation {
            (continuation: CheckedContinuation<(WorkspaceAdoptionResult, Project?), Never>) in
            XCTAssertTrue(WorkspaceAdoption.adoptAfterAcquiring(
                pending,
                intoNewWorkspace: draft,
                projects: projects,
                conversations: conversations,
                artifactStore: artifacts,
                synchronizeLiveState: false
            ) { result, project in
                continuation.resume(returning: (result, project))
            })
            projects.upsert(competing)
        }
        projects.flushSaves()

        XCTAssertEqual(outcome.0, .moved(conversations: 1, artifacts: 1))
        XCTAssertEqual(outcome.1?.id, competing.id)
        XCTAssertNil(projects.project(draft.id))
        XCTAssertEqual(projects.project(competing.id)?.name, competing.name)
        XCTAssertEqual(projects.project(competing.id)?.goal, competing.goal)
        let owner = try await acquire(seeded.owner.id)
        XCTAssertEqual(owner.projectID, competing.id)
    }

    func testMissingHolderLeavesNewWorkspaceAbsentAndRequestRetryable() async throws {
        let seeded = fixture()
        await evict([seeded.owner.id, seeded.reference.id])
        let ownerBefore = try sidecarConversation(seeded.owner.id)
        let durableBefore = try XCTUnwrap(
            artifacts.artifacts.first { $0.uuid == seeded.artifact.uuid })
        let missingSidecar = support
            .appendingPathComponent("conversations", isDirectory: true)
            .appendingPathComponent("\(seeded.reference.id.uuidString).json")
        try FileManager.default.removeItem(at: missingSidecar)
        let requestID = try XCTUnwrap(
            projects.beginWorkspaceAdoption(.conversations([seeded.owner.id])))
        let pending = try XCTUnwrap(projects.pendingWorkspaceAdoption)
        let draft = Project(name: "Must not exist", cwd: "/destination/missing")
        let undoManager = UndoManager()

        let outcome = await createWorkspace(
            for: pending,
            draft: draft,
            undoManager: undoManager)
        projects.flushSaves()

        XCTAssertEqual(outcome.0, .bindingUnavailable(.missing))
        XCTAssertNil(outcome.1)
        XCTAssertNil(projects.project(draft.id))
        XCTAssertEqual(projects.pendingWorkspaceAdoption?.id, requestID)
        XCTAssertFalse(undoManager.canUndo)
        XCTAssertEqual(conversations.synchronousHydrationCount, 0)
        XCTAssertEqual(
            artifacts.artifacts.first { $0.uuid == seeded.artifact.uuid },
            durableBefore)
        let owner = try await acquire(seeded.owner.id)
        XCTAssertEqual(
            try ConversationStore.makeEncoder().encode(owner),
            try ConversationStore.makeEncoder().encode(ownerBefore))

        let reloadedProjects = ProjectStore(appSupportBaseOverride: support)
        XCTAssertNil(reloadedProjects.project(draft.id))
        let projectFiles = try FileManager.default.contentsOfDirectory(
            atPath: support.appendingPathComponent("workspaces", isDirectory: true).path)
        XCTAssertFalse(projectFiles.contains { $0.hasSuffix(".preparing") })
    }

    func testMissingHolderDoesNotRenameAReusedFolderWorkspace() async throws {
        let seeded = fixture()
        await evict([seeded.owner.id, seeded.reference.id])
        let missingSidecar = support
            .appendingPathComponent("conversations", isDirectory: true)
            .appendingPathComponent("\(seeded.reference.id.uuidString).json")
        try FileManager.default.removeItem(at: missingSidecar)
        let existing = Project(name: "Keep this name", goal: "Keep this goal", cwd: "/reuse")
        projects.upsert(existing)
        projects.flushSaves()
        let requestID = try XCTUnwrap(
            projects.beginWorkspaceAdoption(.conversations([seeded.owner.id])))
        let pending = try XCTUnwrap(projects.pendingWorkspaceAdoption)
        let draft = Project(name: "Must not rename", goal: "Must not replace", cwd: existing.cwd)

        let outcome = await createWorkspace(for: pending, draft: draft)
        projects.flushSaves()

        XCTAssertEqual(outcome.0, .bindingUnavailable(.missing))
        XCTAssertNil(outcome.1)
        XCTAssertEqual(projects.project(existing.id)?.name, existing.name)
        XCTAssertEqual(projects.project(existing.id)?.goal, existing.goal)
        XCTAssertEqual(projects.pendingWorkspaceAdoption?.id, requestID)
        XCTAssertEqual(conversations.synchronousHydrationCount, 0)
        let reloaded = ProjectStore(appSupportBaseOverride: support)
        XCTAssertEqual(reloaded.project(existing.id)?.name, existing.name)
        XCTAssertEqual(reloaded.project(existing.id)?.goal, existing.goal)
    }

    func testCancellingNewWorkspaceDuringPreparationPublishesAndMovesNothing() async throws {
        let seeded = fixture()
        await evict([seeded.owner.id, seeded.reference.id])
        let requestID = try XCTUnwrap(
            projects.beginWorkspaceAdoption(.conversations([seeded.owner.id])))
        let pending = try XCTUnwrap(projects.pendingWorkspaceAdoption)
        let draft = Project(name: "Cancelled destination")
        let ownerBefore = try sidecarConversation(seeded.owner.id)

        let outcome = await withCheckedContinuation {
            (continuation: CheckedContinuation<(WorkspaceAdoptionResult, Project?), Never>) in
            let accepted = WorkspaceAdoption.adoptAfterAcquiring(
                pending,
                intoNewWorkspace: draft,
                projects: projects,
                conversations: conversations,
                artifactStore: artifacts,
                synchronizeLiveState: false
            ) { result, project in
                continuation.resume(returning: (result, project))
            }
            XCTAssertTrue(accepted)
            projects.cancelWorkspaceAdoption(requestID)
        }

        XCTAssertEqual(outcome.0, .requestChanged)
        XCTAssertNil(outcome.1)
        XCTAssertTrue(projects.projects.isEmpty)
        XCTAssertNil(projects.pendingWorkspaceAdoption)
        XCTAssertFalse(WorkspaceAdoption.isPlacementOperationInProgress)
        XCTAssertEqual(conversations.synchronousHydrationCount, 0)
        let owner = try await acquire(seeded.owner.id)
        XCTAssertEqual(
            try ConversationStore.makeEncoder().encode(owner),
            try ConversationStore.makeEncoder().encode(ownerBefore))
    }

    func testSupersedingNewWorkspaceDuringPreparationPreservesTheNewRequest() async throws {
        let seeded = fixture()
        await evict([seeded.owner.id, seeded.reference.id])
        _ = try XCTUnwrap(
            projects.beginWorkspaceAdoption(.conversations([seeded.owner.id])))
        let stale = try XCTUnwrap(projects.pendingWorkspaceAdoption)
        let draft = Project(name: "Stale destination")
        var successorID: UUID?

        let outcome = await withCheckedContinuation {
            (continuation: CheckedContinuation<(WorkspaceAdoptionResult, Project?), Never>) in
            let accepted = WorkspaceAdoption.adoptAfterAcquiring(
                stale,
                intoNewWorkspace: draft,
                projects: projects,
                conversations: conversations,
                artifactStore: artifacts,
                synchronizeLiveState: false
            ) { result, project in
                continuation.resume(returning: (result, project))
            }
            XCTAssertTrue(accepted)
            successorID = projects.beginWorkspaceAdoption(
                .artifacts([seeded.artifact.uuid]))
        }

        XCTAssertEqual(outcome.0, .requestChanged)
        XCTAssertNil(outcome.1)
        XCTAssertEqual(projects.pendingWorkspaceAdoption?.id, successorID)
        XCTAssertEqual(
            projects.pendingWorkspaceAdoption?.target,
            .artifacts([seeded.artifact.uuid]))
        XCTAssertTrue(projects.projects.isEmpty)
        XCTAssertFalse(WorkspaceAdoption.isPlacementOperationInProgress)
        XCTAssertEqual(conversations.synchronousHydrationCount, 0)
    }

    func testUndoAndRedoHydrateEvictedMoveRecordsOffMain() async throws {
        let seeded = fixture()
        let ids = Set([seeded.owner.id, seeded.reference.id])
        let destination = Project(name: "Destination", cwd: "/destination")
        let undoManager = UndoManager()

        let moveResult = await moveConversations(
            [seeded.owner.id],
            into: .project(destination),
            undoManager: undoManager)
        XCTAssertTrue(moveResult.succeeded)
        conversations.flushSaves()
        artifacts.flushSaves()
        await evict(ids)
        let synchronousBefore = conversations.synchronousHydrationCount

        undoManager.undo()
        XCTAssertTrue(undoManager.canRedo, "AppKit must receive Redo before async hydration returns")
        XCTAssertTrue(WorkspaceMoveUndo.isApplying(on: undoManager))
        await awaitUndoOperation(undoManager)

        XCTAssertEqual(conversations.synchronousHydrationCount, synchronousBefore)
        XCTAssertEqual(conversations.residentConversation(seeded.owner.id)?.cwd, seeded.owner.cwd)
        XCTAssertEqual(
            conversations.residentConversation(seeded.reference.id)?.artifacts.first?.cwd,
            seeded.artifact.cwd)
        XCTAssertEqual(artifacts.artifacts.first { $0.uuid == seeded.artifact.uuid }, seeded.artifact)

        conversations.flushSaves()
        await evict(ids)
        undoManager.redo()
        XCTAssertTrue(undoManager.canUndo, "AppKit must receive Undo before async hydration returns")
        await awaitUndoOperation(undoManager)

        XCTAssertEqual(conversations.synchronousHydrationCount, synchronousBefore)
        XCTAssertEqual(
            conversations.residentConversation(seeded.owner.id)?.cwd,
            destination.cwd)
        XCTAssertEqual(
            conversations.residentConversation(seeded.reference.id)?.artifacts.first?.cwd,
            destination.cwd)
        XCTAssertEqual(
            artifacts.artifacts.first { $0.uuid == seeded.artifact.uuid }?.cwd,
            destination.cwd)

        conversations.flushSaves()
        await evict(ids)
        undoManager.undo()
        await awaitUndoOperation(undoManager)
        XCTAssertEqual(
            conversations.residentConversation(seeded.owner.id)?.cwd,
            seeded.owner.cwd,
            "the dynamically captured inverse must survive a second eviction")
    }

    func testArtifactMoveUndoAndRedoHydrateEvictedHoldersOffMain() async throws {
        let seeded = fixture()
        let ids = Set([seeded.owner.id, seeded.reference.id])
        let destination = Project(name: "Destination", cwd: "/destination")
        let undoManager = UndoManager()

        let moveResult = await moveArtifacts(
            [seeded.artifact.uuid],
            into: .project(destination),
            undoManager: undoManager)
        XCTAssertTrue(moveResult.succeeded)
        conversations.flushSaves()
        artifacts.flushSaves()
        await evict(ids)
        let synchronousBefore = conversations.synchronousHydrationCount

        undoManager.undo()
        XCTAssertTrue(undoManager.canRedo)
        await awaitUndoOperation(undoManager)
        XCTAssertEqual(conversations.synchronousHydrationCount, synchronousBefore)
        XCTAssertEqual(
            artifacts.artifacts.first { $0.uuid == seeded.artifact.uuid }?.cwd,
            seeded.artifact.cwd)
        XCTAssertEqual(
            conversations.residentConversation(seeded.reference.id)?.artifacts.first?.cwd,
            seeded.artifact.cwd)

        conversations.flushSaves()
        await evict(ids)
        undoManager.redo()
        XCTAssertTrue(undoManager.canUndo)
        await awaitUndoOperation(undoManager)
        XCTAssertEqual(conversations.synchronousHydrationCount, synchronousBefore)
        XCTAssertEqual(
            artifacts.artifacts.first { $0.uuid == seeded.artifact.uuid }?.cwd,
            destination.cwd)
        XCTAssertEqual(
            conversations.residentConversation(seeded.reference.id)?.artifacts.first?.cwd,
            destination.cwd)
    }

    func testMissingHolderMakesUndoAtomicAndRestoresUndoStack() async throws {
        let seeded = fixture()
        let ids = Set([seeded.owner.id, seeded.reference.id])
        let destination = Project(name: "Destination", cwd: "/destination")
        let undoManager = UndoManager()

        let moveResult = await moveConversations(
            [seeded.owner.id],
            into: .project(destination),
            undoManager: undoManager)
        XCTAssertTrue(moveResult.succeeded)
        conversations.flushSaves()
        artifacts.flushSaves()
        let movedArtifact = try XCTUnwrap(
            artifacts.artifacts.first { $0.uuid == seeded.artifact.uuid })
        await evict(ids)
        let missingURL = support
            .appendingPathComponent("conversations", isDirectory: true)
            .appendingPathComponent("\(seeded.reference.id.uuidString).json")
        try FileManager.default.removeItem(at: missingURL)
        let synchronousBefore = conversations.synchronousHydrationCount

        undoManager.undo()
        XCTAssertTrue(undoManager.canRedo)
        await awaitUndoOperation(undoManager)

        XCTAssertEqual(conversations.synchronousHydrationCount, synchronousBefore)
        XCTAssertTrue(undoManager.canUndo, "a failed Undo must remain retryable")
        XCTAssertFalse(undoManager.canRedo)
        XCTAssertEqual(undoManager.undoActionName, WorkspaceMoveUndo.actionName(conversations: 1))
        XCTAssertEqual(artifacts.artifacts.first { $0.uuid == seeded.artifact.uuid }, movedArtifact)
        let owner = await withCheckedContinuation { continuation in
            conversations.acquireConversation(seeded.owner.id) {
                continuation.resume(returning: try? $0.get())
            }
        }
        XCTAssertEqual(owner?.cwd, destination.cwd, "no earlier member may be partially restored")
        XCTAssertNotNil(conversations.hydrationError)
    }

    func testMoveUndoPreservesLaterArtifactAndConversationEdits() async throws {
        let seeded = fixture()
        let unrelatedWorkspace = UUID()
        let unrelated = Artifact(
            title: "Unrelated",
            type: "markdown",
            source: "# Independent",
            origin: "user",
            workspaceID: unrelatedWorkspace,
            cwd: "/unrelated")
        conversations.updateResident(seeded.reference.id) {
            $0.artifacts.append(unrelated)
        }
        let ids = Set([seeded.owner.id, seeded.reference.id])
        let destination = Project(name: "Destination", cwd: "/destination")
        let undoManager = UndoManager()

        let moveResult = await moveConversations(
            [seeded.owner.id],
            into: .project(destination),
            undoManager: undoManager)
        XCTAssertTrue(moveResult.succeeded)
        artifacts.rename(
            seeded.artifact.uuid,
            to: "Renamed after move",
            conversations: conversations,
            synchronizeLiveState: false)
        conversations.updateResident(seeded.reference.id) {
            $0.draft = "Edited after move"
            $0.projectID = UUID()
            $0.cwd = "/reference-moved-later"
            if let index = $0.artifacts.firstIndex(where: { $0.uuid == unrelated.uuid }) {
                $0.artifacts[index].workspaceID = UUID()
                $0.artifacts[index].cwd = "/moved-later"
            }
        }
        conversations.flushSaves()
        artifacts.flushSaves()
        await evict(ids)

        undoManager.undo()
        await awaitUndoOperation(undoManager)

        XCTAssertEqual(
            artifacts.artifacts.first { $0.uuid == seeded.artifact.uuid }?.title,
            "Renamed after move")
        XCTAssertEqual(
            conversations.residentConversation(seeded.owner.id)?.artifacts.first?.title,
            "Renamed after move")
        XCTAssertEqual(
            conversations.residentConversation(seeded.reference.id)?.draft,
            "Edited after move")
        XCTAssertEqual(
            conversations.residentConversation(seeded.reference.id)?.cwd,
            "/reference-moved-later",
            "Undo must not move a reference holder whose location the original move left alone")
        XCTAssertEqual(
            conversations.residentConversation(seeded.reference.id)?.artifacts.first {
                $0.uuid == unrelated.uuid
            }?.cwd,
            "/moved-later",
            "Undo must not restore placement for an artifact the original move did not change")
        XCTAssertEqual(
            conversations.residentConversation(seeded.owner.id)?.cwd,
            seeded.owner.cwd)
    }

    private func acquire(_ id: UUID) async throws -> Conversation {
        try await withCheckedThrowingContinuation { continuation in
            conversations.acquireConversation(id) { result in
                continuation.resume(with: result)
            }
        }
    }

    /// Compare abort behavior to the authoritative encoded value. `Date()` can carry finer
    /// precision than the sidecar's ISO-8601 representation, so comparing a post-hydration value
    /// to the pre-encode fixture would diagnose harmless coder precision as a move mutation.
    private func sidecarConversation(_ id: UUID) throws -> Conversation {
        let url = support
            .appendingPathComponent("conversations", isDirectory: true)
            .appendingPathComponent("\(id.uuidString).json")
        return try ConversationStore.makeDecoder().decode(
            Conversation.self,
            from: Data(contentsOf: url))
    }

    func testEvictedOwnerMoveHydratesItsReferenceAndConvergesEveryArtifactCopy() async throws {
        let seeded = fixture()
        await evict([seeded.owner.id, seeded.reference.id])
        XCTAssertNil(conversations.residentConversation(seeded.owner.id))
        XCTAssertNil(conversations.residentConversation(seeded.reference.id))
        let destination = Project(name: "Destination", cwd: "/destination")

        let result = await moveConversations(
            [seeded.owner.id],
            into: .project(destination))

        XCTAssertEqual(result, .moved(conversations: 1, artifacts: 1))
        XCTAssertEqual(conversations.synchronousHydrationCount, 0)
        XCTAssertEqual(conversations.hydrationDecodeCounts[seeded.owner.id], 1)
        XCTAssertEqual(conversations.hydrationDecodeCounts[seeded.reference.id], 1)

        let movedOwner = try await acquire(seeded.owner.id)
        let unchangedReference = try await acquire(seeded.reference.id)
        let durable = try XCTUnwrap(
            artifacts.artifacts.first { $0.uuid == seeded.artifact.uuid })
        XCTAssertEqual(movedOwner.projectID, destination.id)
        XCTAssertEqual(movedOwner.cwd, destination.cwd)
        XCTAssertEqual(durable.workspaceID, destination.id)
        XCTAssertEqual(durable.cwd, destination.cwd)
        XCTAssertEqual(movedOwner.artifacts.first, durable)
        XCTAssertEqual(unchangedReference.artifacts.first, durable)
        XCTAssertEqual(unchangedReference.projectID, seeded.reference.projectID)
        XCTAssertEqual(unchangedReference.cwd, seeded.reference.cwd)
        XCTAssertEqual(unchangedReference.draft, seeded.reference.draft)
        XCTAssertEqual(conversations.synchronousHydrationCount, 0)
    }

    func testEvictedArtifactHoldersHydrateOffMainAndConvergeExactly() async throws {
        let seeded = fixture()
        await evict([seeded.owner.id, seeded.reference.id])
        let destination = Project(name: "Artifact destination", cwd: "/filed")

        let result = await moveArtifacts(
            [seeded.artifact.uuid],
            into: .project(destination))

        XCTAssertEqual(result, .moved(conversations: 0, artifacts: 1))
        XCTAssertEqual(conversations.synchronousHydrationCount, 0)
        XCTAssertEqual(conversations.hydrationDecodeCounts[seeded.owner.id], 1)
        XCTAssertEqual(conversations.hydrationDecodeCounts[seeded.reference.id], 1)

        let owner = try await acquire(seeded.owner.id)
        let reference = try await acquire(seeded.reference.id)
        let durable = try XCTUnwrap(
            artifacts.artifacts.first { $0.uuid == seeded.artifact.uuid })
        XCTAssertEqual(durable.workspaceID, destination.id)
        XCTAssertEqual(durable.cwd, destination.cwd)
        XCTAssertEqual(owner.artifacts.first, durable)
        XCTAssertEqual(reference.artifacts.first, durable)
        XCTAssertEqual(owner.projectID, seeded.owner.projectID)
        XCTAssertEqual(owner.cwd, seeded.owner.cwd)
        XCTAssertEqual(reference.projectID, seeded.reference.projectID)
        XCTAssertEqual(reference.cwd, seeded.reference.cwd)
        XCTAssertEqual(conversations.synchronousHydrationCount, 0)
    }

    func testMissingEvictedArtifactHolderAbortsBeforeAnyStoreMutationOrUndo() async throws {
        let seeded = fixture()
        await evict([seeded.owner.id, seeded.reference.id])
        let ownerBefore = try sidecarConversation(seeded.owner.id)
        let missingSidecar = support
            .appendingPathComponent("conversations", isDirectory: true)
            .appendingPathComponent("\(seeded.reference.id.uuidString).json")
        try FileManager.default.removeItem(at: missingSidecar)
        let durableBefore = try XCTUnwrap(
            artifacts.artifacts.first { $0.uuid == seeded.artifact.uuid })
        let undoManager = UndoManager()
        let destination = Project(name: "Must not receive artifact", cwd: "/must-not-land")

        let result = await moveArtifacts(
            [seeded.artifact.uuid],
            into: .project(destination),
            undoManager: undoManager)

        XCTAssertEqual(result, .bindingUnavailable(.missing))
        XCTAssertEqual(conversations.synchronousHydrationCount, 0)
        XCTAssertEqual(
            artifacts.artifacts.first { $0.uuid == seeded.artifact.uuid },
            durableBefore)
        XCTAssertFalse(undoManager.canUndo)
        XCTAssertNotNil(
            conversations.summary(seeded.reference.id),
            "the missing binding must remain visible and repairable")

        let owner = try await acquire(seeded.owner.id)
        XCTAssertEqual(
            try ConversationStore.makeEncoder().encode(owner),
            try ConversationStore.makeEncoder().encode(ownerBefore),
            "a failed impact-set hydration must leave the successfully read owner byte-equivalent")
        XCTAssertEqual(conversations.synchronousHydrationCount, 0)
    }

    func testDestinationEditedDuringHydrationIsResolvedAgainAtTheCommitEdge() async throws {
        let seeded = fixture()
        await evict([seeded.owner.id, seeded.reference.id])
        let destination = Project(name: "Original destination", cwd: "/destination/original")
        projects.upsert(destination)

        let result = await withCheckedContinuation {
            (continuation: CheckedContinuation<WorkspaceAdoptionResult, Never>) in
            let accepted = WorkspaceAdoption.adoptAfterAcquiring(
                conversations: [seeded.owner.id],
                into: .project(destination),
                conversations: conversations,
                artifactStore: artifacts,
                projectStore: projects,
                synchronizeLiveState: false
            ) { continuation.resume(returning: $0) }
            XCTAssertTrue(accepted)
            projects.update(destination.id) {
                $0.name = "Edited while loading"
                $0.cwd = "/destination/edited"
            }
        }

        XCTAssertEqual(result, .moved(conversations: 1, artifacts: 1))
        let owner = try await acquire(seeded.owner.id)
        let durable = try XCTUnwrap(
            artifacts.artifacts.first { $0.uuid == seeded.artifact.uuid })
        XCTAssertEqual(owner.projectID, destination.id)
        XCTAssertEqual(owner.cwd, "/destination/edited")
        XCTAssertEqual(durable.workspaceID, destination.id)
        XCTAssertEqual(durable.cwd, "/destination/edited")
        XCTAssertEqual(conversations.synchronousHydrationCount, 0)
    }

    func testDestinationDeletedDuringHydrationAbortsBeforeAnyMoveMutation() async throws {
        let seeded = fixture()
        await evict([seeded.owner.id, seeded.reference.id])
        let ownerBefore = try sidecarConversation(seeded.owner.id)
        let referenceBefore = try sidecarConversation(seeded.reference.id)
        let artifactBefore = try XCTUnwrap(
            artifacts.artifacts.first { $0.uuid == seeded.artifact.uuid })
        let destination = Project(name: "Deleted destination", cwd: "/destination/deleted")
        projects.upsert(destination)
        let undoManager = UndoManager()

        let result = await withCheckedContinuation {
            (continuation: CheckedContinuation<WorkspaceAdoptionResult, Never>) in
            let accepted = WorkspaceAdoption.adoptAfterAcquiring(
                conversations: [seeded.owner.id],
                into: .project(destination),
                conversations: conversations,
                artifactStore: artifacts,
                projectStore: projects,
                synchronizeLiveState: false,
                undoManager: undoManager
            ) { continuation.resume(returning: $0) }
            XCTAssertTrue(accepted)
            projects.remove(destination.id)
        }

        XCTAssertEqual(result, .unavailable)
        XCTAssertFalse(undoManager.canUndo)
        XCTAssertEqual(
            artifacts.artifacts.first { $0.uuid == seeded.artifact.uuid },
            artifactBefore)
        let owner = try await acquire(seeded.owner.id)
        let reference = try await acquire(seeded.reference.id)
        XCTAssertEqual(
            try ConversationStore.makeEncoder().encode(owner),
            try ConversationStore.makeEncoder().encode(ownerBefore))
        XCTAssertEqual(
            try ConversationStore.makeEncoder().encode(reference),
            try ConversationStore.makeEncoder().encode(referenceBefore))
        XCTAssertEqual(conversations.synchronousHydrationCount, 0)
    }

    func testConcurrentMoveIsRejectedWhileFirstMoveIsPreparingWithoutInterleaving() async throws {
        let seeded = fixture()
        await evict([seeded.owner.id, seeded.reference.id])
        let firstDestination = Project(name: "First", cwd: "/destination/first")
        let secondDestination = Project(name: "Second", cwd: "/destination/second")
        projects.upsert(firstDestination)
        projects.upsert(secondDestination)
        var secondResult: WorkspaceAdoptionResult?

        let firstResult = await withCheckedContinuation {
            (continuation: CheckedContinuation<WorkspaceAdoptionResult, Never>) in
            let firstAccepted = WorkspaceAdoption.adoptAfterAcquiring(
                conversations: [seeded.owner.id],
                into: .project(firstDestination),
                conversations: conversations,
                artifactStore: artifacts,
                projectStore: projects,
                synchronizeLiveState: false
            ) { continuation.resume(returning: $0) }
            XCTAssertTrue(firstAccepted)

            let secondAccepted = WorkspaceAdoption.adoptAfterAcquiring(
                conversations: [seeded.reference.id],
                into: .project(secondDestination),
                conversations: conversations,
                artifactStore: artifacts,
                projectStore: projects,
                synchronizeLiveState: false
            ) { secondResult = $0 }
            XCTAssertFalse(secondAccepted)
            XCTAssertEqual(secondResult, .moveInProgress)
        }

        XCTAssertEqual(firstResult, .moved(conversations: 1, artifacts: 1))
        XCTAssertEqual(secondResult, .moveInProgress)
        let owner = try await acquire(seeded.owner.id)
        let reference = try await acquire(seeded.reference.id)
        XCTAssertEqual(owner.projectID, firstDestination.id)
        XCTAssertEqual(owner.cwd, firstDestination.cwd)
        XCTAssertEqual(reference.projectID, seeded.reference.projectID)
        XCTAssertEqual(reference.cwd, seeded.reference.cwd)
        XCTAssertNotEqual(reference.projectID, secondDestination.id)
        XCTAssertEqual(conversations.synchronousHydrationCount, 0)
    }
}
