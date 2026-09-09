import XCTest
@testable import Mechanician

/// The rule deciding what a freshly-built workspace window opens on.
///
/// This existed only as inline branches inside `AgentBridge.restoreLastViewed`, which cannot run
/// without booting a bridge and a provider runtime, so the rule that produced a real user-visible
/// bug had no test. The bug: `ActiveWorkspace.pendingOpenConversation` was one process-global slot,
/// so opening two conversations in new windows in quick succession left one of them showing a blank
/// conversation. `AgentBridge.swift` documented the symptom and worked around it by minting a fresh
/// conversation rather than fixing the binding.
final class WorkspaceInitialViewTests: XCTestCase {
    func testAWindowOpenedForAConversationShowsThatConversation() {
        let id = UUID()
        XCTAssertEqual(
            WorkspaceInitialView.resolve(
                requested: id,
                requestedIsAvailable: true,
                isFirstWindow: true,
                savedLastViewed: UUID()),
            .requested(id))
    }

    /// The regression that motivated the change. Two windows are built in quick succession, each
    /// bound to its own conversation. The second window being built does not change what the first
    /// one opens on, because the binding is a parameter rather than shared state.
    func testTwoWindowsInFlightEachKeepTheirOwnConversation() {
        let first = UUID()
        let second = UUID()

        let firstView = WorkspaceInitialView.resolve(
            requested: first,
            requestedIsAvailable: true,
            isFirstWindow: true,
            savedLastViewed: nil)
        let secondView = WorkspaceInitialView.resolve(
            requested: second,
            requestedIsAvailable: true,
            isFirstWindow: false,
            savedLastViewed: nil)

        XCTAssertEqual(firstView, .requested(first))
        XCTAssertEqual(secondView, .requested(second))
    }

    /// A window opened for one conversation must never fall through to the last-viewed default.
    /// That fall-through is how a window opened for A ended up showing B.
    func testAnUnavailableRequestStartsFreshRatherThanFallingBackToLastViewed() {
        let requested = UUID()
        let lastViewed = UUID()

        let view = WorkspaceInitialView.resolve(
            requested: requested,
            requestedIsAvailable: false,
            isFirstWindow: true,
            savedLastViewed: lastViewed)

        XCTAssertEqual(view, .fresh)
        XCTAssertNotEqual(view, .lastViewed(lastViewed))
    }

    /// "Unavailable" covers both a conversation deleted between the click and the window being
    /// built, and one another window already owns. Both resolve the same way: this window starts
    /// fresh instead of showing the conversation twice.
    func testOwnedOrDeletedRequestsBothStartFresh() {
        XCTAssertEqual(
            WorkspaceInitialView.resolve(
                requested: UUID(),
                requestedIsAvailable: false,
                isFirstWindow: false,
                savedLastViewed: nil),
            .fresh)
    }

    func testTheFirstWindowRestoresTheLastViewedConversation() {
        let saved = UUID()
        XCTAssertEqual(
            WorkspaceInitialView.resolve(
                requested: nil,
                requestedIsAvailable: false,
                isFirstWindow: true,
                savedLastViewed: saved),
            .lastViewed(saved))
    }

    func testTheFirstWindowWithNoSavedConversationFallsBackToTheStore() {
        XCTAssertEqual(
            WorkspaceInitialView.resolve(
                requested: nil,
                requestedIsAvailable: false,
                isFirstWindow: true,
                savedLastViewed: nil),
            .storeDefault)
    }

    /// Every window after the first starts fresh rather than duplicating the shared last-viewed
    /// conversation across windows.
    func testAdditionalWindowsNeverInheritTheLastViewedConversation() {
        XCTAssertEqual(
            WorkspaceInitialView.resolve(
                requested: nil,
                requestedIsAvailable: false,
                isFirstWindow: false,
                savedLastViewed: UUID()),
            .fresh)
    }

    /// `requestedIsAvailable` is only meaningful alongside a request. With no conversation asked
    /// for it must not influence the outcome, or a stale flag could hijack an ordinary new window.
    func testAvailabilityIsIgnoredWithoutARequest() {
        let saved = UUID()
        XCTAssertEqual(
            WorkspaceInitialView.resolve(
                requested: nil,
                requestedIsAvailable: true,
                isFirstWindow: true,
                savedLastViewed: saved),
            .lastViewed(saved))
    }

    /// The sidebar is usable before a slow provider reports ready. A local select, New Conversation,
    /// or fork made during that interval supersedes the row captured when the window was built.
    func testProviderBootstrapKeepsTheUsersCurrentConversationSelection() {
        let selectedWhileStarting = UUID()
        XCTAssertEqual(
            WorkspaceBootstrapPolicy.conversationID(
                currentSelection: selectedWhileStarting),
            selectedWhileStarting)
        XCTAssertNil(WorkspaceBootstrapPolicy.conversationID(currentSelection: nil))
    }

    /// A path is not workspace identity. Removing a Project and creating another at the same path
    /// must not let the old launch request attach to the replacement Project when its daemon readies.
    func testFolderBootstrapRequiresTheSameCanonicalProject() {
        let original = UUID()
        let replacement = UUID()

        XCTAssertTrue(WorkspaceBootstrapPolicy.acceptsFolder(
            expectedProjectID: original,
            resolvedScope: .project(original)))
        XCTAssertFalse(WorkspaceBootstrapPolicy.acceptsFolder(
            expectedProjectID: original,
            resolvedScope: .project(replacement)))
        XCTAssertFalse(WorkspaceBootstrapPolicy.acceptsFolder(
            expectedProjectID: original,
            resolvedScope: nil))
        XCTAssertFalse(WorkspaceBootstrapPolicy.acceptsFolder(
            expectedProjectID: nil,
            resolvedScope: .project(original)))
    }

    /// Persisting an untouched placeholder can remove it from the store. The bootstrap must create
    /// another fresh row instead of treating an older recency fallback as the user's selection.
    func testMissingExactBootstrapSelectionNeverFallsBackToAnOlderConversation() {
        let requested = UUID()
        let older = UUID()

        XCTAssertTrue(WorkspaceBootstrapPolicy.acceptsPreferredConversation(
            requestedID: requested,
            preferredID: requested))
        XCTAssertFalse(WorkspaceBootstrapPolicy.acceptsPreferredConversation(
            requestedID: requested,
            preferredID: older))
        XCTAssertFalse(WorkspaceBootstrapPolicy.acceptsPreferredConversation(
            requestedID: requested,
            preferredID: nil))
        XCTAssertTrue(WorkspaceBootstrapPolicy.acceptsPreferredConversation(
            requestedID: nil,
            preferredID: older))
    }

    /// Regression: provider warm-up can finish before the asynchronous 400+ MB Conversation scan.
    /// It may advertise readiness, but it must not consume a folder bootstrap or mint a blank row
    /// until session restoration has resolved the exact Conversation and canonical Workspace.
    func testProviderReadyBeforeStoreCannotBootstrapTheWindow() {
        XCTAssertFalse(WorkspaceBootstrapReadiness.shouldBegin(
            storeIsReady: false,
            initialViewResolved: false,
            runtimeIsReady: true,
            didBootstrap: false))
        XCTAssertFalse(WorkspaceBootstrapReadiness.shouldBegin(
            storeIsReady: true,
            initialViewResolved: false,
            runtimeIsReady: true,
            didBootstrap: false))
        XCTAssertTrue(WorkspaceBootstrapReadiness.shouldBegin(
            storeIsReady: true,
            initialViewResolved: true,
            runtimeIsReady: true,
            didBootstrap: false))
    }

    func testStoreReadyBeforeProviderWaitsAndBootstrapIsOneShot() {
        XCTAssertFalse(WorkspaceBootstrapReadiness.shouldBegin(
            storeIsReady: true,
            initialViewResolved: true,
            runtimeIsReady: false,
            didBootstrap: false))
        XCTAssertTrue(WorkspaceBootstrapReadiness.shouldBegin(
            storeIsReady: true,
            initialViewResolved: true,
            runtimeIsReady: true,
            didBootstrap: false))
        XCTAssertFalse(WorkspaceBootstrapReadiness.shouldBegin(
            storeIsReady: true,
            initialViewResolved: true,
            runtimeIsReady: true,
            didBootstrap: true))
    }

    func testPreReadyNavigationGenerationCapturesTheMutationEdge() {
        XCTAssertEqual(
            WorkspaceBootstrapReadiness.preReadyNavigationGeneration(
                after: 7,
                storeIsReady: false,
                destinationChanged: true),
            8)
        XCTAssertEqual(
            WorkspaceBootstrapReadiness.preReadyNavigationGeneration(
                after: 7,
                storeIsReady: true,
                destinationChanged: true),
            7,
            "Store-ready session restoration must not supersede an earlier projected click.")
        XCTAssertEqual(
            WorkspaceBootstrapReadiness.preReadyNavigationGeneration(
                after: 7,
                storeIsReady: false,
                destinationChanged: false),
            7)
    }

    func testAlternateFirstClickSupersedesSavedConversationHydration() {
        let saved = UUID()
        let alternate = UUID()
        let savedToken = UUID()
        let alternateToken = UUID()

        XCTAssertFalse(InitialConversationHydrationPublication.isCurrent(
            targetID: saved,
            token: savedToken,
            pendingID: alternate,
            pendingToken: alternateToken,
            currentID: nil))
        XCTAssertTrue(InitialConversationHydrationPublication.isCurrent(
            targetID: alternate,
            token: alternateToken,
            pendingID: alternate,
            pendingToken: alternateToken,
            currentID: nil))
    }

    func testExplicitConversationBeatsAnyLateLaunchHydration() {
        let saved = UUID()
        let token = UUID()
        XCTAssertFalse(InitialConversationHydrationPublication.isCurrent(
            targetID: saved,
            token: token,
            pendingID: saved,
            pendingToken: token,
            currentID: UUID()))
    }

    func testWorkspaceInventoryFollowsConversationLaunchSource() {
        XCTAssertTrue(InitialConversationHydrationPublication
            .shouldPrepareSQLiteWorkspaceInventory(
                conversationUsedSQLiteLaunchInventory: true))
        XCTAssertFalse(InitialConversationHydrationPublication
            .shouldPrepareSQLiteWorkspaceInventory(
                conversationUsedSQLiteLaunchInventory: false),
            "A Legacy Conversation fallback must not mix in a cached SQLite Workspace snapshot.")
    }

    func testFailedInitialHydrationCanReenterOnlyWhileStillOpening() {
        let opening = UUID()
        XCTAssertTrue(InitialConversationHydrationPublication.shouldRetryOpeningHydration(
            initialViewResolutionPending: true,
            openingID: opening,
            pendingSelectionID: nil,
            currentID: nil))
        XCTAssertFalse(InitialConversationHydrationPublication.shouldRetryOpeningHydration(
            initialViewResolutionPending: true,
            openingID: opening,
            pendingSelectionID: UUID(),
            currentID: nil))
        XCTAssertFalse(InitialConversationHydrationPublication.shouldRetryOpeningHydration(
            initialViewResolutionPending: false,
            openingID: opening,
            pendingSelectionID: nil,
            currentID: UUID()))
    }

    func testSameScopedConversationStillRequiresProviderHistoryLoad() {
        let selected = UUID()
        XCTAssertTrue(InitialConversationHydrationPublication
            .scopedBootstrapRequiresProviderLoad(
                preferredID: selected,
                currentID: selected,
                hasResidentValue: true))
        XCTAssertFalse(InitialConversationHydrationPublication
            .scopedBootstrapRequiresProviderLoad(
                preferredID: selected,
                currentID: UUID(),
                hasResidentValue: true))
        XCTAssertFalse(InitialConversationHydrationPublication
            .scopedBootstrapRequiresProviderLoad(
                preferredID: selected,
                currentID: selected,
                hasResidentValue: false))
    }
}
