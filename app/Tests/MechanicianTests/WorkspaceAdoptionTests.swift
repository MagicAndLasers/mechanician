import XCTest
@testable import Mechanician

/// Re-filing a conversation into a workspace must move BOTH things that bind it: the id the sidebar
/// files it under, and the working directory its tools act in. Moving one without the other leaves a
/// conversation listed in one workspace while still operating in the previous folder.
@MainActor
final class WorkspaceAdoptionTests: XCTestCase {
    func testAStalePlacementLeaseCannotReleaseItsSuccessor() throws {
        let first = try XCTUnwrap(WorkspaceAdoption.beginPlacementOperation())
        XCTAssertTrue(WorkspaceAdoption.endPlacementOperation(first))
        let second = try XCTUnwrap(WorkspaceAdoption.beginPlacementOperation())

        XCTAssertFalse(WorkspaceAdoption.endPlacementOperation(first))
        XCTAssertTrue(WorkspaceAdoption.isPlacementOperationInProgress)
        XCTAssertTrue(WorkspaceAdoption.endPlacementOperation(second))
        XCTAssertFalse(WorkspaceAdoption.isPlacementOperationInProgress)
    }
    private typealias IsolatedStores = (
        support: URL,
        conversations: ConversationStore,
        artifacts: ArtifactStore
    )

    private func makeStore() -> ConversationStore {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("mechanician-adopt-\(UUID().uuidString)", isDirectory: true)
        return ConversationStore(appSupportBaseOverride: base, watchesDirectory: false)
    }

    private func makeIsolatedStores() -> IsolatedStores {
        let support = FileManager.default.temporaryDirectory
            .appendingPathComponent("mechanician-adopt-all-\(UUID().uuidString)", isDirectory: true)
        return (
            support,
            ConversationStore(appSupportBaseOverride: support, watchesDirectory: false),
            ArtifactStore(appSupportBaseOverride: support, watchesDirectory: false))
    }

    private func cleanUp(_ stores: IsolatedStores) {
        stores.conversations.flushSaves()
        stores.artifacts.flushSaves()
        try? FileManager.default.removeItem(at: stores.support)
    }

    private func seed(_ store: ConversationStore) -> UUID {
        var conversation = Conversation(
            title: "Outgrew its workspace",
            cwd: "/old/folder",
            sdkSessionId: nil,
            modelSelection: ModelSelection(access: .claudeSubscription, modelID: "model-a"),
            messages: [],
            updatedAt: Date())
        conversation.projectID = UUID()
        store.upsert(conversation)
        return conversation.id
    }

    private func seedConversationWithArtifact(
        conversations: ConversationStore,
        artifacts: ArtifactStore,
        workspaceID: UUID,
        cwd: String,
        title: String = "Outgrew its workspace"
    ) -> (conversation: Conversation, artifact: Artifact) {
        var conversation = Conversation(
            title: title,
            cwd: cwd,
            sdkSessionId: nil,
            modelSelection: ModelSelection(access: .claudeSubscription, modelID: "model-a"),
            messages: [],
            updatedAt: Date())
        conversation.projectID = workspaceID
        let artifactID = UUID()
        conversation.artifacts = [
            Artifact(
                title: "Plan",
                type: "markdown",
                source: "# Plan",
                workspaceID: workspaceID,
                conversationID: conversation.id,
                conversationTitle: title,
                cwd: cwd,
                uuid: artifactID)
        ]
        conversations.upsert(conversation)
        let durable = artifacts.upsertFromAgent(
            title: "Plan",
            type: "markdown",
            source: "# Plan",
            workspaceID: workspaceID,
            conversationID: conversation.id,
            conversationTitle: title,
            cwd: cwd,
            preferredID: artifactID)
        return (conversation, durable)
    }

    func testAdoptionMovesBothTheWorkspaceIdAndTheWorkingDirectory() {
        let store = makeStore()
        let id = seed(store)
        let destination = Project(name: "Acorn", cwd: "/new/folder")

        WorkspaceAdoption.adopt(conversation: id, into: destination, conversations: store)

        let moved = store.conversation(id)
        XCTAssertEqual(moved?.projectID, destination.id)
        XCTAssertEqual(moved?.cwd, "/new/folder",
                       "a conversation left in its old folder would still run tools there")
    }

    /// A topic workspace has no folder. Adoption must clear the previous cwd rather than leaving the
    /// conversation acting in a directory its new workspace has nothing to do with.
    func testMovingIntoAFolderlessWorkspaceClearsTheOldWorkingDirectory() {
        let store = makeStore()
        let id = seed(store)
        let topic = Project(name: "Reading notes", cwd: "")

        WorkspaceAdoption.adopt(conversation: id, into: topic, conversations: store)

        XCTAssertEqual(store.conversation(id)?.projectID, topic.id)
        XCTAssertEqual(store.conversation(id)?.cwd, "")
    }

    func testGenericMovePresentationNeverOffersAReservedProfileTransition() throws {
        let standardProject = Project(name: "Ordinary", cwd: "/ordinary")
        let projects = [
            standardProject,
            ReservedWorkspace.help.canonicalProject(),
        ]
        let standard = Conversation(
            title: "Standard", cwd: "", sdkSessionId: nil,
            messages: [], updatedAt: Date(), projectID: nil)
        let help = Conversation(
            title: "Help", cwd: "", sdkSessionId: nil,
            messages: [], updatedAt: Date(), projectID: HelpWorkspace.id)
        let summaries = [ConversationSummary(standard), ConversationSummary(help)]

        XCTAssertEqual(
            try XCTUnwrap(ConversationMovePresentation.destinationProjects(
                for: [standard.id],
                conversations: summaries,
                projects: projects)).map(\.id),
            [standardProject.id])
        XCTAssertNil(ConversationMovePresentation.destinationProjects(
            for: [help.id],
            conversations: summaries,
            projects: projects),
            "a reserved-source Conversation must not offer a generic handoff out")
        XCTAssertNil(ConversationMovePresentation.destinationProjects(
            for: [standard.id, help.id],
            conversations: summaries,
            projects: projects),
            "one reserved member closes the whole bulk menu")
    }

    func testAdoptionRejectsReservedProfileChangesBeforeMutatingAnyBatchMember() {
        let store = makeStore()
        let ordinarySource = UUID()
        let standard = Conversation(
            title: "Standard",
            cwd: "/standard",
            sdkSessionId: nil,
            messages: [],
            updatedAt: Date(),
            projectID: ordinarySource)
        let help = Conversation(
            title: "Help",
            cwd: "",
            sdkSessionId: nil,
            messages: [],
            updatedAt: Date(),
            projectID: HelpWorkspace.id)
        store.upsert(standard)
        store.upsert(help)
        let ordinaryDestination = Project(name: "Destination", cwd: "/destination")
        let helpDestination = ReservedWorkspace.help.canonicalProject()

        XCTAssertEqual(WorkspaceAdoption.adopt(
            conversations: [standard.id],
            into: .project(helpDestination),
            conversations: store,
            synchronizeLiveState: false), .unavailable)
        XCTAssertEqual(WorkspaceAdoption.adopt(
            conversations: [help.id],
            into: .project(ordinaryDestination),
            conversations: store,
            synchronizeLiveState: false), .unavailable)

        XCTAssertEqual(WorkspaceAdoption.adopt(
            conversations: [standard.id, help.id],
            into: .project(ordinaryDestination),
            conversations: store,
            synchronizeLiveState: false), .unavailable)
        XCTAssertEqual(store.conversation(standard.id)?.projectID, ordinarySource)
        XCTAssertEqual(store.conversation(standard.id)?.cwd, "/standard")
        XCTAssertEqual(store.conversation(help.id)?.projectID, HelpWorkspace.id)
        XCTAssertEqual(store.conversation(help.id)?.cwd, "")

        XCTAssertEqual(WorkspaceAdoption.adopt(
            conversations: [help.id],
            into: .project(helpDestination),
            conversations: store,
            synchronizeLiveState: false), .unchanged)
    }

    func testAdoptingAConversationThatNoLongerExistsIsANoOp() {
        let store = makeStore()
        let before = store.conversations.count

        WorkspaceAdoption.adopt(
            conversation: UUID(), into: Project(name: "Gone", cwd: "/x"), conversations: store)

        XCTAssertEqual(store.conversations.count, before)
    }

    func testConversationAdoptionPreflightRejectsMissingAndAcceptsValidIsolatedTargets() {
        let store = makeStore()
        let id = seed(store)

        XCTAssertEqual(
            WorkspaceAdoption.preflight(
                conversations: [id, UUID()],
                conversations: store,
                synchronizeLiveState: false),
            .unavailable)
        XCTAssertNil(
            WorkspaceAdoption.preflight(
                conversations: [id],
                conversations: store,
                synchronizeLiveState: false))
    }

    func testCrossWindowHandoffLeavesSourcesInPlaceAndGivesDestinationOneDeterministicOwner() throws {
        let sourceWorkspaceID = UUID(uuidString: "10000000-0000-0000-0000-000000000000")!
        let destination = Project(
            id: UUID(uuidString: "20000000-0000-0000-0000-000000000000")!,
            name: "Destination",
            cwd: "/destination")
        let movedFirst = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let movedSecond = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
        let sourceBridgeID = UUID(uuidString: "30000000-0000-0000-0000-000000000001")!
        let duplicateSourceBridgeID =
            UUID(uuidString: "30000000-0000-0000-0000-000000000002")!
        let receivingBridgeID =
            UUID(uuidString: "40000000-0000-0000-0000-000000000001")!
        let alternateReceiverID =
            UUID(uuidString: "40000000-0000-0000-0000-000000000002")!
        let hiddenReceiverID =
            UUID(uuidString: "05000000-0000-0000-0000-000000000001")!
        let snapshots = [
            WorkspaceAdoptionLiveBridgeSnapshot(
                bridgeID: sourceBridgeID,
                hasWindow: true,
                currentConversationID: movedSecond,
                projectID: sourceWorkspaceID,
                cwd: ""),
            WorkspaceAdoptionLiveBridgeSnapshot(
                bridgeID: duplicateSourceBridgeID,
                hasWindow: true,
                currentConversationID: movedFirst,
                projectID: sourceWorkspaceID,
                cwd: ""),
            WorkspaceAdoptionLiveBridgeSnapshot(
                bridgeID: receivingBridgeID,
                hasWindow: true,
                currentConversationID: UUID(),
                projectID: nil,
                cwd: destination.cwd),
            WorkspaceAdoptionLiveBridgeSnapshot(
                bridgeID: alternateReceiverID,
                hasWindow: true,
                currentConversationID: UUID(),
                projectID: nil,
                cwd: destination.cwd),
            WorkspaceAdoptionLiveBridgeSnapshot(
                bridgeID: hiddenReceiverID,
                hasWindow: false,
                currentConversationID: UUID(),
                projectID: nil,
                cwd: destination.cwd),
        ]
        let movedIDs: Set<UUID> = [movedSecond, movedFirst]

        let plan = try XCTUnwrap(workspaceAdoptionLiveHandoffPlan(
            movedConversationIDs: movedIDs,
            destination: .project(destination),
            bridges: snapshots))

        XCTAssertEqual(plan.receivingBridgeID, receivingBridgeID)
        XCTAssertEqual(
            plan.sourceBridgeIDs,
            [sourceBridgeID, duplicateSourceBridgeID],
            "every stale source viewer must relinquish the moved conversation")
        XCTAssertEqual(
            plan.revealConversationID,
            movedFirst,
            "batch handoff must not depend on Set iteration order")

        let sourceSnapshots = snapshots.filter {
            Set(plan.sourceBridgeIDs).contains($0.bridgeID)
        }
        XCTAssertTrue(sourceSnapshots.allSatisfy {
            $0.projectID == sourceWorkspaceID && $0.cwd.isEmpty
        }, "handoff relinquishes conversation ownership, not the source window's workspace")

        let sourceIDs = Set(plan.sourceBridgeIDs)
        let movedOwnersAfterPlan = snapshots.compactMap { snapshot -> UUID? in
            if snapshot.bridgeID == plan.receivingBridgeID {
                return plan.receivingBridgeID
            }
            if sourceIDs.contains(snapshot.bridgeID) { return nil }
            return snapshot.currentConversationID.map(movedIDs.contains) == true
                ? snapshot.bridgeID
                : nil
        }
        XCTAssertEqual(
            movedOwnersAfterPlan,
            [receivingBridgeID],
            "the handoff plan leaves exactly one live owner for the moved batch")
    }

    func testCoordinatorMovesConversationNestedAndDurableArtifactsButLeavesUnrelatedArtifact() {
        let stores = makeIsolatedStores()
        defer { cleanUp(stores) }
        let oldWorkspaceID = UUID()
        let seeded = seedConversationWithArtifact(
            conversations: stores.conversations,
            artifacts: stores.artifacts,
            workspaceID: oldWorkspaceID,
            cwd: "/old")
        let unrelatedConversationID = UUID()
        let unrelated = stores.artifacts.upsertFromAgent(
            title: "Plan",
            type: "markdown",
            source: "# Unrelated",
            workspaceID: oldWorkspaceID,
            conversationID: unrelatedConversationID,
            conversationTitle: "Other conversation",
            cwd: "/old")
        let unrelatedBefore = stores.artifacts.artifacts.first { $0.uuid == unrelated.uuid }
        let destination = Project(name: "Destination", cwd: "/new")

        let result = WorkspaceAdoption.adopt(
            conversations: [seeded.conversation.id],
            into: .project(destination),
            conversations: stores.conversations,
            artifactStore: stores.artifacts,
            synchronizeLiveState: false)

        XCTAssertEqual(result, .moved(conversations: 1, artifacts: 1))
        let movedConversation = stores.conversations.conversation(seeded.conversation.id)
        XCTAssertEqual(movedConversation?.projectID, destination.id)
        XCTAssertEqual(movedConversation?.cwd, "/new")
        XCTAssertEqual(movedConversation?.artifacts.first?.workspaceID, destination.id)
        XCTAssertEqual(movedConversation?.artifacts.first?.cwd, "/new")
        let movedDurable = stores.artifacts.artifacts.first {
            $0.uuid == seeded.artifact.uuid
        }
        XCTAssertEqual(movedDurable?.workspaceID, destination.id)
        XCTAssertEqual(movedDurable?.cwd, "/new")
        XCTAssertEqual(
            stores.artifacts.artifacts.first { $0.uuid == unrelated.uuid },
            unrelatedBefore)
    }

    func testCoordinatorMovingConversationHomeClearsConversationAndArtifactWorkspaceMetadata() {
        let stores = makeIsolatedStores()
        defer { cleanUp(stores) }
        let seeded = seedConversationWithArtifact(
            conversations: stores.conversations,
            artifacts: stores.artifacts,
            workspaceID: UUID(),
            cwd: "/old")

        let result = WorkspaceAdoption.adopt(
            conversations: [seeded.conversation.id],
            into: .home,
            conversations: stores.conversations,
            artifactStore: stores.artifacts,
            synchronizeLiveState: false)

        XCTAssertEqual(result, .moved(conversations: 1, artifacts: 1))
        let movedConversation = stores.conversations.conversation(seeded.conversation.id)
        XCTAssertNil(movedConversation?.projectID)
        XCTAssertEqual(movedConversation?.cwd, "")
        XCTAssertNil(movedConversation?.artifacts.first?.workspaceID)
        XCTAssertEqual(movedConversation?.artifacts.first?.cwd, "")
        let movedDurable = stores.artifacts.artifacts.first {
            $0.uuid == seeded.artifact.uuid
        }
        XCTAssertNil(movedDurable?.workspaceID)
        XCTAssertEqual(movedDurable?.cwd, "")
    }

    func testLaterConversationMoveWinsOverAnEarlierIndependentArtifactMove() {
        let stores = makeIsolatedStores()
        defer { cleanUp(stores) }
        let oldWorkspaceID = UUID()
        let seeded = seedConversationWithArtifact(
            conversations: stores.conversations,
            artifacts: stores.artifacts,
            workspaceID: oldWorkspaceID,
            cwd: "/old")
        let artifactDestination = Project(name: "Artifact filing", cwd: "/artifact")
        let conversationDestination = Project(name: "Conversation filing", cwd: "/conversation")

        let artifactResult = WorkspaceAdoption.adopt(
            artifacts: [seeded.artifact.uuid],
            into: .project(artifactDestination),
            conversations: stores.conversations,
            artifactStore: stores.artifacts,
            synchronizeLiveState: false)

        XCTAssertEqual(artifactResult, .moved(conversations: 0, artifacts: 1))
        XCTAssertEqual(
            stores.conversations.conversation(seeded.conversation.id)?.projectID,
            oldWorkspaceID,
            "moving one artifact must not move its originating conversation")
        XCTAssertEqual(
            stores.artifacts.artifacts.first { $0.uuid == seeded.artifact.uuid }?.workspaceID,
            artifactDestination.id)

        let revised = stores.artifacts.upsertFromAgent(
            title: seeded.artifact.title,
            type: seeded.artifact.type,
            source: "# Revised while independently filed",
            workspaceID: oldWorkspaceID,
            conversationID: seeded.conversation.id,
            conversationTitle: seeded.conversation.title,
            cwd: "/old",
            preferredID: seeded.artifact.uuid)
        XCTAssertEqual(revised.workspaceID, artifactDestination.id)
        XCTAssertEqual(revised.cwd, "/artifact")
        XCTAssertEqual(revised.source, "# Revised while independently filed")

        let conversationResult = WorkspaceAdoption.adopt(
            conversations: [seeded.conversation.id],
            into: .project(conversationDestination),
            conversations: stores.conversations,
            artifactStore: stores.artifacts,
            synchronizeLiveState: false)

        XCTAssertEqual(conversationResult, .moved(conversations: 1, artifacts: 1))
        let movedConversation = stores.conversations.conversation(seeded.conversation.id)
        XCTAssertEqual(movedConversation?.projectID, conversationDestination.id)
        XCTAssertEqual(movedConversation?.artifacts.first?.workspaceID, conversationDestination.id)
        XCTAssertEqual(
            stores.artifacts.artifacts.first { $0.uuid == seeded.artifact.uuid }?.workspaceID,
            conversationDestination.id,
            "the canonical rule is that a later conversation move brings its artifacts along")
    }

    func testMissingTargetsMakeConversationAndArtifactBatchesAllOrNothingNoOps() {
        let stores = makeIsolatedStores()
        defer { cleanUp(stores) }
        let seeded = seedConversationWithArtifact(
            conversations: stores.conversations,
            artifacts: stores.artifacts,
            workspaceID: UUID(),
            cwd: "/old")
        let conversationBefore = stores.conversations.conversation(seeded.conversation.id)
        let artifactBefore = stores.artifacts.artifacts.first {
            $0.uuid == seeded.artifact.uuid
        }
        let destination = WorkspaceDestination.project(
            Project(name: "Should not receive anything", cwd: "/new"))

        let conversationResult = WorkspaceAdoption.adopt(
            conversations: [seeded.conversation.id, UUID()],
            into: destination,
            conversations: stores.conversations,
            artifactStore: stores.artifacts,
            synchronizeLiveState: false)
        XCTAssertEqual(conversationResult, .unavailable)
        XCTAssertEqual(
            stores.conversations.conversation(seeded.conversation.id)?.projectID,
            conversationBefore?.projectID)
        XCTAssertEqual(
            stores.artifacts.artifacts.first { $0.uuid == seeded.artifact.uuid },
            artifactBefore)

        let artifactResult = WorkspaceAdoption.adopt(
            artifacts: [seeded.artifact.uuid, UUID()],
            into: destination,
            conversations: stores.conversations,
            artifactStore: stores.artifacts,
            synchronizeLiveState: false)
        XCTAssertEqual(artifactResult, .unavailable)
        XCTAssertEqual(
            stores.conversations.conversation(seeded.conversation.id)?.artifacts,
            conversationBefore?.artifacts)
        XCTAssertEqual(
            stores.artifacts.artifacts.first { $0.uuid == seeded.artifact.uuid },
            artifactBefore)
    }

    /// The sidebar's `Move to Workspace` used to carry only the right-clicked row, so a
    /// multi-selection moved one conversation and silently stranded the rest. This is the end-to-end
    /// cover for the batch the menu now passes.
    func testConversationBatchMoveRelocatesEveryConversationInTheSelection() {
        let stores = makeIsolatedStores()
        defer { cleanUp(stores) }
        let origin = UUID()
        let cocktail = seedConversationWithArtifact(
            conversations: stores.conversations,
            artifacts: stores.artifacts,
            workspaceID: origin,
            cwd: "/old",
            title: "Not Easy Being Green")
        let dinner = seedConversationWithArtifact(
            conversations: stores.conversations,
            artifacts: stores.artifacts,
            workspaceID: origin,
            cwd: "/old",
            title: "Dinner for six")
        let party = Project(name: "Not Easy Being Green", cwd: "/party")

        let result = WorkspaceAdoption.adopt(
            conversations: [cocktail.conversation.id, dinner.conversation.id],
            into: .project(party),
            conversations: stores.conversations,
            artifactStore: stores.artifacts,
            synchronizeLiveState: false)

        XCTAssertTrue(result.succeeded)
        for id in [cocktail.conversation.id, dinner.conversation.id] {
            XCTAssertEqual(
                stores.conversations.conversation(id)?.projectID,
                party.id,
                "every conversation in the selection must land in the destination workspace")
            XCTAssertEqual(stores.conversations.conversation(id)?.cwd, "/party")
        }
        for uuid in [cocktail.artifact.uuid, dinner.artifact.uuid] {
            XCTAssertEqual(
                stores.artifacts.artifacts.first { $0.uuid == uuid }?.workspaceID,
                party.id,
                "each moved conversation must bring its own artifacts along")
        }
    }

    /// The artifact browser's bulk action passes its whole selection the same way. A batch that
    /// moved only one row would strand the rest with no visible sign it happened.
    func testArtifactBatchMoveRelocatesEveryArtifactInTheSelection() {
        let stores = makeIsolatedStores()
        defer { cleanUp(stores) }
        let origin = UUID()
        let menu = seedConversationWithArtifact(
            conversations: stores.conversations,
            artifacts: stores.artifacts,
            workspaceID: origin,
            cwd: "/old",
            title: "Menu card")
        let seating = seedConversationWithArtifact(
            conversations: stores.conversations,
            artifacts: stores.artifacts,
            workspaceID: origin,
            cwd: "/old",
            title: "Seating chart")
        let party = Project(name: "Not Easy Being Green", cwd: "/party")

        let result = WorkspaceAdoption.adopt(
            artifacts: [menu.artifact.uuid, seating.artifact.uuid],
            into: .project(party),
            conversations: stores.conversations,
            artifactStore: stores.artifacts,
            synchronizeLiveState: false)

        XCTAssertTrue(result.succeeded)
        for uuid in [menu.artifact.uuid, seating.artifact.uuid] {
            let moved = stores.artifacts.artifacts.first { $0.uuid == uuid }
            XCTAssertEqual(moved?.workspaceID, party.id)
            XCTAssertEqual(moved?.cwd, "/party")
        }
        // The nested copies each conversation carries must converge too, or reopening a conversation
        // would show its artifact still filed in the old workspace.
        for seeded in [menu, seating] {
            let nested = stores.conversations
                .conversation(seeded.conversation.id)?
                .artifacts
                .first { $0.uuid == seeded.artifact.uuid }
            XCTAssertEqual(nested?.workspaceID, party.id)
            XCTAssertEqual(nested?.cwd, "/party")
        }
    }

    func testLauncherRejectsADeletedArtifactBeforeCreatingOrRenamingItsWorkspace() throws {
        let support = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "mechanician-launcher-artifact-preflight-\(UUID().uuidString)",
                isDirectory: true)
        let conversations = ConversationStore(
            appSupportBaseOverride: support,
            watchesDirectory: false)
        let artifacts = ArtifactStore(
            appSupportBaseOverride: support,
            watchesDirectory: false)
        let projects = ProjectStore(appSupportBaseOverride: support)
        defer {
            conversations.flushSaves()
            artifacts.flushSaves()
            projects.flushSaves()
            try? FileManager.default.removeItem(at: support)
        }

        let requestID = try XCTUnwrap(
            projects.beginWorkspaceAdoption(.artifacts([UUID()])))
        let newDraft = Project(name: "Must not be created")
        switch persistWorkspaceLauncherDraft(
            newDraft,
            adoption: projects.pendingWorkspaceAdoption,
            adoptionRequestID: requestID,
            projects: projects,
            conversations: conversations,
            artifacts: artifacts,
            synchronizeLiveState: false) {
        case .blocked(.unavailable):
            break
        case .blocked(let failure):
            XCTFail("unexpected preflight failure: \(failure)")
        case .committed:
            XCTFail("a deleted artifact must not leave an empty workspace")
        }
        XCTAssertTrue(projects.projects.isEmpty)
        XCTAssertEqual(
            projects.pendingWorkspaceAdoption?.id,
            requestID,
            "a blocked draft remains retryable and still owns its move request")

        let existing = Project(name: "Original", cwd: "/already-filed")
        projects.upsert(existing)
        var renamedDraft = existing
        renamedDraft.name = "Must not rename"
        switch persistWorkspaceLauncherDraft(
            renamedDraft,
            adoption: projects.pendingWorkspaceAdoption,
            adoptionRequestID: requestID,
            projects: projects,
            conversations: conversations,
            artifacts: artifacts,
            synchronizeLiveState: false) {
        case .blocked(.unavailable):
            break
        case .blocked(let failure):
            XCTFail("unexpected preflight failure: \(failure)")
        case .committed:
            XCTFail("a deleted artifact must not mutate an existing destination")
        }
        XCTAssertEqual(projects.project(existing.id)?.name, "Original")
    }

    func testSupersededLauncherEditorCannotPersistAWorkspace() throws {
        let support = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "mechanician-launcher-stale-editor-\(UUID().uuidString)",
                isDirectory: true)
        let conversations = ConversationStore(
            appSupportBaseOverride: support,
            watchesDirectory: false)
        let artifacts = ArtifactStore(
            appSupportBaseOverride: support,
            watchesDirectory: false)
        let projects = ProjectStore(appSupportBaseOverride: support)
        defer {
            conversations.flushSaves()
            artifacts.flushSaves()
            projects.flushSaves()
            try? FileManager.default.removeItem(at: support)
        }

        let staleRequestID = try XCTUnwrap(
            projects.beginWorkspaceAdoption(.artifacts([UUID()])))
        let currentRequestID = try XCTUnwrap(
            projects.beginWorkspaceAdoption(.conversations([UUID()])))
        let outcome = persistWorkspaceLauncherDraft(
            Project(name: "Stale editor must not create this"),
            adoption: projects.pendingWorkspaceAdoption,
            adoptionRequestID: staleRequestID,
            projects: projects,
            conversations: conversations,
            artifacts: artifacts,
            synchronizeLiveState: false)

        switch outcome {
        case .blocked(.unavailable):
            break
        case .blocked(let failure):
            XCTFail("unexpected stale-editor failure: \(failure)")
        case .committed:
            XCTFail("a superseded adoption editor must not persist its draft")
        }
        XCTAssertTrue(projects.projects.isEmpty)
        XCTAssertEqual(projects.pendingWorkspaceAdoption?.id, currentRequestID)

        let existing = Project(name: "Current name", cwd: "/stale-editor-destination")
        projects.upsert(existing)
        var renamed = existing
        renamed.name = "Stale rename"
        switch persistWorkspaceLauncherDraft(
            renamed,
            adoption: projects.pendingWorkspaceAdoption,
            adoptionRequestID: staleRequestID,
            projects: projects,
            conversations: conversations,
            artifacts: artifacts,
            synchronizeLiveState: false) {
        case .blocked(.unavailable):
            break
        case .blocked(let failure):
            XCTFail("unexpected stale-editor failure: \(failure)")
        case .committed:
            XCTFail("a superseded adoption editor must not mutate an existing workspace")
        }
        XCTAssertEqual(projects.project(existing.id)?.name, "Current name")
        XCTAssertEqual(projects.pendingWorkspaceAdoption?.id, currentRequestID)
    }

    func testNewWorkspaceAdoptionCanOnlyBeCancelledOrConsumedByItsOwningRequest() throws {
        let support = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "mechanician-pending-adoption-\(UUID().uuidString)",
                isDirectory: true)
        let projects = ProjectStore(appSupportBaseOverride: support)
        defer {
            projects.flushSaves()
            try? FileManager.default.removeItem(at: support)
        }

        let staleOrigin = UUID()
        let staleRequest = try XCTUnwrap(
            projects.beginWorkspaceAdoption(
                .artifacts([UUID()]),
                originBridgeID: staleOrigin))
        XCTAssertEqual(projects.pendingWorkspaceAdoption?.originBridgeID, staleOrigin)
        let currentTarget = WorkspaceAdoptionTarget.conversations([UUID()])
        let currentRequest = try XCTUnwrap(
            projects.beginWorkspaceAdoption(currentTarget))

        projects.cancelWorkspaceAdoption(staleRequest)
        XCTAssertEqual(projects.pendingWorkspaceAdoption?.id, currentRequest)
        XCTAssertNil(
            projects.takeWorkspaceAdoption(nil),
            "an editor that never captured a request must not consume another window's move")
        XCTAssertEqual(projects.pendingWorkspaceAdoption?.id, currentRequest)

        let consumed = projects.takeWorkspaceAdoption(currentRequest)
        XCTAssertEqual(consumed?.target, currentTarget)
        XCTAssertNil(projects.pendingWorkspaceAdoption)
    }

    func testAbandoningLauncherDraftCannotLeakItsAdoptionIntoALaterWorkspace() throws {
        let support = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "mechanician-abandoned-adoption-\(UUID().uuidString)",
                isDirectory: true)
        let projects = ProjectStore(appSupportBaseOverride: support)
        defer {
            projects.flushSaves()
            try? FileManager.default.removeItem(at: support)
        }
        let staleRequest = try XCTUnwrap(
            projects.beginWorkspaceAdoption(.artifacts([UUID()])))

        let clearedRequest = abandonWorkspaceLauncherAdoption(
            staleRequest,
            projects: projects)

        XCTAssertNil(clearedRequest)
        XCTAssertNil(
            projects.pendingWorkspaceAdoption,
            "editing another workspace or starting an ordinary draft must abandon the old move")

        let newerRequest = try XCTUnwrap(
            projects.beginWorkspaceAdoption(.conversations([UUID()])))
        _ = abandonWorkspaceLauncherAdoption(staleRequest, projects: projects)
        XCTAssertEqual(
            projects.pendingWorkspaceAdoption?.id,
            newerRequest,
            "a stale launcher transition must not cancel another window's newer move")
    }

    func testWorkspaceFolderChangePreservesAnArtifactFiledInAnotherWorkspaceAcrossAllCopies() {
        let stores = makeIsolatedStores()
        defer { cleanUp(stores) }
        let sourceWorkspaceID = UUID()
        let seeded = seedConversationWithArtifact(
            conversations: stores.conversations,
            artifacts: stores.artifacts,
            workspaceID: sourceWorkspaceID,
            cwd: "/source")
        let filingWorkspace = Project(name: "Independent filing", cwd: "/filed")

        XCTAssertEqual(
            WorkspaceAdoption.adopt(
                artifacts: [seeded.artifact.uuid],
                into: .project(filingWorkspace),
                conversations: stores.conversations,
                artifactStore: stores.artifacts,
                synchronizeLiveState: false),
            .moved(conversations: 0, artifacts: 1))

        WorkspaceAdoption.reassignWorkspaceFolder(
            projectID: sourceWorkspaceID,
            previousCwd: "/source",
            cwd: "/source-renamed",
            conversationIDs: [seeded.conversation.id],
            conversations: stores.conversations,
            artifactStore: stores.artifacts)

        let durable = stores.artifacts.artifacts.first {
            $0.uuid == seeded.artifact.uuid
        }
        let nested = stores.conversations.conversation(seeded.conversation.id)?
            .artifacts.first { $0.uuid == seeded.artifact.uuid }
        XCTAssertEqual(durable?.workspaceID, filingWorkspace.id)
        XCTAssertEqual(durable?.cwd, "/filed")
        XCTAssertEqual(nested, durable)
        XCTAssertEqual(
            stores.conversations.conversation(seeded.conversation.id)?.cwd,
            "/source-renamed")
    }

    func testWorkspaceFolderChangePreservesAnArtifactExplicitlyFiledInHomeAcrossAllCopies() {
        let stores = makeIsolatedStores()
        defer { cleanUp(stores) }
        let sourceWorkspaceID = UUID()
        let seeded = seedConversationWithArtifact(
            conversations: stores.conversations,
            artifacts: stores.artifacts,
            workspaceID: sourceWorkspaceID,
            cwd: "/source")

        XCTAssertEqual(
            WorkspaceAdoption.adopt(
                artifacts: [seeded.artifact.uuid],
                into: .home,
                conversations: stores.conversations,
                artifactStore: stores.artifacts,
                synchronizeLiveState: false),
            .moved(conversations: 0, artifacts: 1))

        WorkspaceAdoption.reassignWorkspaceFolder(
            projectID: sourceWorkspaceID,
            previousCwd: "/source",
            cwd: "/source-renamed",
            conversationIDs: [seeded.conversation.id],
            conversations: stores.conversations,
            artifactStore: stores.artifacts)

        let durable = stores.artifacts.artifacts.first {
            $0.uuid == seeded.artifact.uuid
        }
        let nested = stores.conversations.conversation(seeded.conversation.id)?
            .artifacts.first { $0.uuid == seeded.artifact.uuid }
        XCTAssertNil(durable?.workspaceID)
        XCTAssertEqual(durable?.cwd, "")
        XCTAssertEqual(nested, durable)
        XCTAssertEqual(
            stores.conversations.conversation(seeded.conversation.id)?.cwd,
            "/source-renamed")
    }

    func testMovingAReferencingConversationDoesNotMoveAnotherConversationsArtifact() {
        let stores = makeIsolatedStores()
        defer { cleanUp(stores) }
        let ownerWorkspaceID = UUID()
        let owner = seedConversationWithArtifact(
            conversations: stores.conversations,
            artifacts: stores.artifacts,
            workspaceID: ownerWorkspaceID,
            cwd: "/owner",
            title: "Owner")
        var reference = Conversation(
            title: "Reference",
            cwd: "/reference",
            sdkSessionId: nil,
            messages: [],
            updatedAt: Date())
        reference.projectID = UUID()
        reference.artifacts = [owner.artifact]
        stores.conversations.upsert(reference)
        let destination = Project(name: "Reference destination", cwd: "/new-reference")

        let result = WorkspaceAdoption.adopt(
            conversations: [reference.id],
            into: .project(destination),
            conversations: stores.conversations,
            artifactStore: stores.artifacts,
            synchronizeLiveState: false)

        XCTAssertEqual(result, .moved(conversations: 1, artifacts: 0))
        let durable = stores.artifacts.artifacts.first {
            $0.uuid == owner.artifact.uuid
        }
        let nested = stores.conversations.conversation(reference.id)?
            .artifacts.first { $0.uuid == owner.artifact.uuid }
        XCTAssertEqual(durable?.workspaceID, ownerWorkspaceID)
        XCTAssertEqual(durable?.cwd, "/owner")
        XCTAssertEqual(nested, durable)
        XCTAssertEqual(
            stores.conversations.conversation(reference.id)?.cwd,
            "/new-reference")
    }

    func testMissingDurableFallbackOnlyClaimsOwnedOrLegacyInteractiveArtifacts() {
        let stores = makeIsolatedStores()
        defer { cleanUp(stores) }
        let sourceWorkspaceID = UUID()
        var conversation = Conversation(
            title: "Legacy snapshots",
            cwd: "/source",
            sdkSessionId: nil,
            messages: [],
            updatedAt: Date())
        conversation.projectID = sourceWorkspaceID
        let otherConversationID = UUID()
        let legacyInteractive = Artifact(
            title: "Legacy agent output",
            type: "markdown",
            source: "# Legacy",
            origin: "interactive",
            workspaceID: sourceWorkspaceID,
            conversationID: nil,
            cwd: "/source")
        let explicitlyOwnedUser = Artifact(
            title: "Imported here",
            type: "markdown",
            source: "# Imported",
            origin: "user",
            workspaceID: sourceWorkspaceID,
            conversationID: conversation.id,
            cwd: "/source")
        let standaloneUser = Artifact(
            title: "Standalone user artifact",
            type: "markdown",
            source: "# User",
            origin: "user",
            workspaceID: sourceWorkspaceID,
            conversationID: nil,
            cwd: "/source")
        let standaloneAmbient = Artifact(
            title: "Ambient reference",
            type: "markdown",
            source: "# Ambient",
            origin: "ambient",
            workspaceID: sourceWorkspaceID,
            conversationID: nil,
            cwd: "/source")
        let ownedElsewhere = Artifact(
            title: "Other conversation",
            type: "markdown",
            source: "# Other",
            origin: "interactive",
            workspaceID: sourceWorkspaceID,
            conversationID: otherConversationID,
            cwd: "/source")
        conversation.artifacts = [
            legacyInteractive,
            explicitlyOwnedUser,
            standaloneUser,
            standaloneAmbient,
            ownedElsewhere,
        ]
        stores.conversations.upsert(conversation)
        let destination = Project(name: "Destination", cwd: "/destination")

        XCTAssertEqual(
            WorkspaceAdoption.adopt(
                conversations: [conversation.id],
                into: .project(destination),
                conversations: stores.conversations,
                artifactStore: stores.artifacts,
                synchronizeLiveState: false),
            .moved(conversations: 1, artifacts: 2))

        let moved = stores.conversations.conversation(conversation.id)
        let movedByID = Dictionary(
            uniqueKeysWithValues: (moved?.artifacts ?? []).map { ($0.uuid, $0) })
        XCTAssertEqual(movedByID[legacyInteractive.uuid]?.workspaceID, destination.id)
        XCTAssertEqual(movedByID[legacyInteractive.uuid]?.cwd, destination.cwd)
        XCTAssertEqual(movedByID[legacyInteractive.uuid]?.conversationID, conversation.id)
        XCTAssertEqual(movedByID[explicitlyOwnedUser.uuid]?.workspaceID, destination.id)
        XCTAssertEqual(movedByID[explicitlyOwnedUser.uuid]?.cwd, destination.cwd)
        XCTAssertEqual(movedByID[standaloneUser.uuid], standaloneUser)
        XCTAssertEqual(movedByID[standaloneAmbient.uuid], standaloneAmbient)
        XCTAssertEqual(movedByID[ownedElsewhere.uuid], ownedElsewhere)
    }

    func testFolderReassignmentMissingDurableFallbackPreservesUnprovenancedReferences() {
        let stores = makeIsolatedStores()
        defer { cleanUp(stores) }
        let workspaceID = UUID()
        var conversation = Conversation(
            title: "Folder legacy snapshots",
            cwd: "/source",
            sdkSessionId: nil,
            messages: [],
            updatedAt: Date())
        conversation.projectID = workspaceID
        let legacyInteractive = Artifact(
            title: "Legacy agent output",
            type: "markdown",
            source: "# Legacy",
            origin: "interactive",
            workspaceID: workspaceID,
            conversationID: nil,
            cwd: "/source")
        let standaloneUser = Artifact(
            title: "Standalone user artifact",
            type: "markdown",
            source: "# User",
            origin: "user",
            workspaceID: workspaceID,
            conversationID: nil,
            cwd: "/source")
        let ownedElsewhere = Artifact(
            title: "Other conversation",
            type: "markdown",
            source: "# Other",
            origin: "interactive",
            workspaceID: workspaceID,
            conversationID: UUID(),
            cwd: "/source")
        conversation.artifacts = [legacyInteractive, standaloneUser, ownedElsewhere]
        stores.conversations.upsert(conversation)

        WorkspaceAdoption.reassignWorkspaceFolder(
            projectID: workspaceID,
            previousCwd: "/source",
            cwd: "/destination",
            conversationIDs: [conversation.id],
            conversations: stores.conversations,
            artifactStore: stores.artifacts)

        let moved = stores.conversations.conversation(conversation.id)
        let movedByID = Dictionary(
            uniqueKeysWithValues: (moved?.artifacts ?? []).map { ($0.uuid, $0) })
        XCTAssertEqual(moved?.cwd, "/destination")
        XCTAssertEqual(movedByID[legacyInteractive.uuid]?.workspaceID, workspaceID)
        XCTAssertEqual(movedByID[legacyInteractive.uuid]?.cwd, "/destination")
        XCTAssertEqual(movedByID[standaloneUser.uuid], standaloneUser)
        XCTAssertEqual(movedByID[ownedElsewhere.uuid], ownedElsewhere)
    }

    func testMovingAnArtifactConvergesEveryClosedConversationReference() {
        let stores = makeIsolatedStores()
        defer { cleanUp(stores) }
        let owner = seedConversationWithArtifact(
            conversations: stores.conversations,
            artifacts: stores.artifacts,
            workspaceID: UUID(),
            cwd: "/owner",
            title: "Owner")
        var reference = Conversation(
            title: "Closed reference",
            cwd: "/reference",
            sdkSessionId: nil,
            messages: [],
            updatedAt: Date())
        reference.projectID = UUID()
        reference.artifacts = [owner.artifact]
        stores.conversations.upsert(reference)
        let destination = Project(name: "Filed artifact", cwd: "/filed")

        XCTAssertEqual(
            WorkspaceAdoption.adopt(
                artifacts: [owner.artifact.uuid],
                into: .project(destination),
                conversations: stores.conversations,
                artifactStore: stores.artifacts,
                synchronizeLiveState: false),
            .moved(conversations: 0, artifacts: 1))

        let durable = stores.artifacts.artifacts.first {
            $0.uuid == owner.artifact.uuid
        }
        let ownerNested = stores.conversations.conversation(owner.conversation.id)?
            .artifacts.first { $0.uuid == owner.artifact.uuid }
        let referenceNested = stores.conversations.conversation(reference.id)?
            .artifacts.first { $0.uuid == owner.artifact.uuid }
        XCTAssertEqual(durable?.workspaceID, destination.id)
        XCTAssertEqual(durable?.cwd, "/filed")
        XCTAssertEqual(ownerNested, durable)
        XCTAssertEqual(referenceNested, durable)
    }

    func testMovingOwnerConversationConvergesEveryClosedConversationReference() throws {
        let stores = makeIsolatedStores()
        defer { cleanUp(stores) }
        let ownerWorkspaceID = UUID()
        let owner = seedConversationWithArtifact(
            conversations: stores.conversations,
            artifacts: stores.artifacts,
            workspaceID: ownerWorkspaceID,
            cwd: "/owner",
            title: "Owner")
        var reference = Conversation(
            title: "Closed reference",
            cwd: "/reference",
            sdkSessionId: nil,
            messages: [],
            updatedAt: Date())
        let referenceWorkspaceID = UUID()
        reference.projectID = referenceWorkspaceID
        reference.draft = "Durable reference fixture"
        reference.artifacts = [owner.artifact]
        stores.conversations.upsert(reference)
        let destination = Project(name: "Owner destination", cwd: "/moved-owner")

        XCTAssertEqual(
            WorkspaceAdoption.adopt(
                conversations: [owner.conversation.id],
                into: .project(destination),
                conversations: stores.conversations,
                artifactStore: stores.artifacts,
                synchronizeLiveState: false),
            .moved(conversations: 1, artifacts: 1))

        let durable = try XCTUnwrap(stores.artifacts.artifacts.first {
            $0.uuid == owner.artifact.uuid
        })
        let referenceAfterMove = try XCTUnwrap(
            stores.conversations.conversation(reference.id))
        XCTAssertEqual(durable.workspaceID, destination.id)
        XCTAssertEqual(durable.cwd, destination.cwd)
        XCTAssertEqual(referenceAfterMove.projectID, referenceWorkspaceID)
        XCTAssertEqual(referenceAfterMove.cwd, "/reference")
        XCTAssertEqual(referenceAfterMove.artifacts.first, durable)

        stores.conversations.flushSaves()
        stores.artifacts.flushSaves()
        let relaunchedConversations = ConversationStore(
            appSupportBaseOverride: stores.support,
            watchesDirectory: false)
        let relaunchedArtifacts = ArtifactStore(
            appSupportBaseOverride: stores.support,
            watchesDirectory: false)
        XCTAssertEqual(
            relaunchedConversations.conversation(reference.id)?.artifacts.first,
            relaunchedArtifacts.artifacts.first { $0.uuid == durable.uuid },
            "the converged referencing snapshot must survive relaunch")
    }
}
