import XCTest
@testable import Mechanician

final class ArtifactBrowserInteractionTests: XCTestCase {
    private let a = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    private let b = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
    private let c = UUID(uuidString: "00000000-0000-0000-0000-000000000003")!
    private let d = UUID(uuidString: "00000000-0000-0000-0000-000000000004")!

    private var order: [UUID] { [a, b, c, d] }

    func testPlainAndCommandClicksFollowMacSelectionSemantics() {
        var selection = ArtifactListSelection()

        selection.select(b, orderedIDs: order, extending: false, range: false)
        XCTAssertEqual(selection.ids, [b])
        XCTAssertEqual(selection.primary, b)

        selection.select(d, orderedIDs: order, extending: true, range: false)
        XCTAssertEqual(selection.ids, [b, d])
        XCTAssertEqual(selection.primary, d)

        selection.select(d, orderedIDs: order, extending: true, range: false)
        XCTAssertEqual(selection.ids, [b])
        XCTAssertEqual(selection.primary, b)
    }

    func testShiftClickSelectsAContiguousRangeFromTheAnchor() {
        var selection = ArtifactListSelection()
        selection.select(b, orderedIDs: order, extending: false, range: false)

        selection.select(d, orderedIDs: order, extending: false, range: true)

        XCTAssertEqual(selection.ids, [b, c, d])
        XCTAssertEqual(selection.primary, d)
        XCTAssertEqual(selection.anchor, b)
    }

    func testCommandShiftClickAddsRangeToExistingSelection() {
        var selection = ArtifactListSelection()
        selection.select(c, orderedIDs: order, extending: false, range: false)
        selection.select(a, orderedIDs: order, extending: true, range: false)

        selection.select(d, orderedIDs: order, extending: true, range: true)

        XCTAssertEqual(selection.ids, [a, b, c, d])
        XCTAssertEqual(selection.primary, d)
        XCTAssertEqual(selection.anchor, a)
    }

    func testReconcileDropsMovedOrFilteredRowsAndKeepsAVisiblePrimary() {
        var selection = ArtifactListSelection()
        selection.select(a, orderedIDs: order, extending: false, range: false)
        selection.select(c, orderedIDs: order, extending: true, range: false)

        selection.reconcile(orderedIDs: [a, b])

        XCTAssertEqual(selection.ids, [a])
        XCTAssertEqual(selection.primary, a)
        XCTAssertEqual(selection.anchor, a)
    }

    func testContextActionsUseTheGroupOnlyWhenTheClickedRowIsSelected() {
        var selection = ArtifactListSelection()
        selection.select(a, orderedIDs: order, extending: false, range: false)
        selection.select(c, orderedIDs: order, extending: true, range: false)

        XCTAssertEqual(selection.actionIDs(for: c), [a, c])
        XCTAssertEqual(selection.actionIDs(for: d), [d])
    }

    func testSuccessfulArtifactMoveRevealsTheStableFirstSelection() {
        XCTAssertEqual(
            ArtifactMoveRevealPolicy.artifactID(
                after: .moved(conversations: 0, artifacts: 3),
                moving: [c, a, b]),
            a)
        XCTAssertEqual(
            ArtifactMoveRevealPolicy.artifactID(
                after: .unchanged,
                moving: [d, b]),
            b)
    }

    func testFailedOrEmptyArtifactMoveDoesNotRequestAReveal() {
        XCTAssertNil(
            ArtifactMoveRevealPolicy.artifactID(
                after: .unavailable,
                moving: [a]))
        XCTAssertNil(
            ArtifactMoveRevealPolicy.artifactID(
                after: .busy,
                moving: [a]))
        XCTAssertNil(
            ArtifactMoveRevealPolicy.artifactID(
                after: .moved(conversations: 0, artifacts: 0),
                moving: []))
    }

    func testInlineArtifactRenameCommitsOnlyAMeaningfulTrimmedTitle() {
        XCTAssertEqual(
            ArtifactInlineTitleEditing.titleToCommit(
                draft: "  Renamed artifact  ",
                currentTitle: "Original artifact"),
            "Renamed artifact")
        XCTAssertNil(
            ArtifactInlineTitleEditing.titleToCommit(
                draft: "   \n\t ",
                currentTitle: "Original artifact"))
        XCTAssertNil(
            ArtifactInlineTitleEditing.titleToCommit(
                draft: " Original artifact ",
                currentTitle: "Original artifact"))
    }

    func testWorkspaceScopeControlUsesAWorkspaceGlyphInsteadOfTheArtifactStack() {
        XCTAssertEqual(
            ArtifactWorkspaceScopePresentation.symbolName(showingAllWorkspaces: false),
            ArtifactWorkspaceScopePresentation.currentWorkspaceSymbol)
        XCTAssertEqual(
            ArtifactWorkspaceScopePresentation.symbolName(showingAllWorkspaces: true),
            ArtifactWorkspaceScopePresentation.allWorkspacesSymbol)
        XCTAssertNotEqual(
            ArtifactWorkspaceScopePresentation.currentWorkspaceSymbol,
            "square.stack.3d.up")
        XCTAssertNotEqual(
            ArtifactWorkspaceScopePresentation.allWorkspacesSymbol,
            "square.stack.3d.up.fill")
    }

    func testArtifactMoveReResolvesTheCurrentProjectSnapshotAtActionTime() {
        let projectID = UUID()
        let stale = Project(id: projectID, name: "Old name", cwd: "/old")
        let current = Project(id: projectID, name: "Current name", cwd: "/current")

        let destination = ArtifactMoveDestinationPolicy.resolve(
            .project(stale),
            availableProjects: [current])

        guard case .project(let resolved)? = destination else {
            return XCTFail("expected the current project destination")
        }
        XCTAssertEqual(resolved.id, projectID)
        XCTAssertEqual(resolved.name, "Current name")
        XCTAssertEqual(resolved.cwd, "/current")
    }

    func testArtifactMoveRejectsAProjectDeletedWhileItsMenuWasOpen() {
        let stale = Project(name: "Deleted", cwd: "/gone")

        XCTAssertNil(
            ArtifactMoveDestinationPolicy.resolve(
                .project(stale),
                availableProjects: []))
    }

    func testArtifactMoveAlwaysAllowsTheHomeDestination() {
        guard case .home? = ArtifactMoveDestinationPolicy.resolve(
            .home,
            availableProjects: [])
        else {
            return XCTFail("Home should not depend on a project snapshot")
        }
    }

    func testLegacyPanelCacheCannotResolveToContentIdenticalUnrelatedArtifact() {
        let visibleConversationID = UUID()
        let unrelatedConversationID = UUID()
        let cached = Artifact(
            title: "Same title",
            type: "markdown",
            source: "Same source",
            origin: "interactive",
            conversationID: nil)
        let unrelated = Artifact(
            title: cached.title,
            type: cached.type,
            source: cached.source,
            origin: cached.origin,
            conversationID: unrelatedConversationID)

        XCTAssertNil(storedPanelArtifact(
            matching: cached,
            in: [unrelated],
            currentConversationID: visibleConversationID))

        let owned = Artifact(
            title: cached.title,
            type: cached.type,
            source: cached.source,
            origin: cached.origin,
            conversationID: visibleConversationID)
        XCTAssertEqual(
            storedPanelArtifact(
                matching: cached,
                in: [unrelated, owned],
                currentConversationID: visibleConversationID)?.uuid,
            owned.uuid)
    }

    func testOnlyBrowseLauncherConsumesAnAdoptionBackedNewWorkspaceRequest() {
        XCTAssertTrue(
            WorkspaceLauncherPendingNewPolicy.canConsume(
                purpose: .browse,
                hasPendingAdoption: true))
        XCTAssertFalse(
            WorkspaceLauncherPendingNewPolicy.canConsume(
                purpose: .newWindow,
                hasPendingAdoption: true))
        XCTAssertTrue(
            WorkspaceLauncherPendingNewPolicy.canConsume(
                purpose: .browse,
                hasPendingAdoption: false))
        XCTAssertTrue(
            WorkspaceLauncherPendingNewPolicy.canConsume(
                purpose: .newWindow,
                hasPendingAdoption: false),
            "ordinary New Workspace behavior remains available in a new-window chooser")
    }

    func testSpringLoaderActivatesAfterItsDelay() {
        let activated = expectation(description: "spring-loaded")
        let loader = InspectorTabSpringLoader()

        loader.setTargeted(true, delay: 0.02) {
            activated.fulfill()
        }

        XCTAssertTrue(loader.hasPendingActivation)
        wait(for: [activated], timeout: 1)
        XCTAssertFalse(loader.hasPendingActivation)
    }

    func testSpringLoaderCancelsWhenTheDragLeaves() {
        let activated = expectation(description: "must stay cancelled")
        activated.isInverted = true
        let loader = InspectorTabSpringLoader()

        loader.setTargeted(true, delay: 0.03) {
            activated.fulfill()
        }
        loader.setTargeted(false) {}

        XCTAssertFalse(loader.hasPendingActivation)
        wait(for: [activated], timeout: 0.12)
    }

    @MainActor
    func testArtifactDragRetentionSurvivesTheTabSwitchUntilTheDragEnds() {
        let retention = InspectorArtifactDragRetention()

        retention.begin(expirationDelay: 1, monitorEvents: false)
        XCTAssertTrue(retention.active)

        retention.end()
        XCTAssertFalse(retention.active)
    }

    @MainActor
    func testArtifactDragRetentionHasABoundedCancellationFallback() async throws {
        let retention = InspectorArtifactDragRetention()

        retention.begin(expirationDelay: 0.02, monitorEvents: false)
        XCTAssertTrue(retention.active)
        try await Task.sleep(for: .milliseconds(80))

        XCTAssertFalse(retention.active)
    }
}
