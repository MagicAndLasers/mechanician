import XCTest
@testable import Mechanician

/// FR-236. Double-clicking a conversation opened a blank conversation in Home instead of that
/// conversation in the current workspace.
///
/// Two owner checks disagreed about whether "already open" included the window you double-clicked
/// in. The first excluded it, so a conversation already on screen there looked closed and a tab was
/// built. The second did not exclude it, found the source window, and blanked the tab. The blank
/// conversation then inherited no workspace, because the workspace seed was only set for tabs that
/// did NOT name a conversation, so it landed in Home.
final class ConversationOpenPlanTests: XCTestCase {

    // MARK: The double-click decision

    func testAConversationAlreadyOnScreenIsFocusedRatherThanOpenedAgain() {
        // The exact regression. "Shown in any window" includes the window doing the asking, so a
        // double-click here has nothing to open and must not build a tab that the tab's own owner
        // check would immediately blank.
        XCTAssertEqual(
            ConversationOpenPlan.resolve(conversationID: UUID(), isShownInAnyWindow: true),
            .focusExistingWindow)
    }

    func testAConversationNoWindowIsShowingOpensInANewTab() {
        let id = UUID()
        XCTAssertEqual(
            ConversationOpenPlan.resolve(conversationID: id, isShownInAnyWindow: false),
            .openInNewTab(id))
    }

    // MARK: What the new tab then shows

    func testANewTabShowsTheConversationItWasOpenedFor() {
        let id = UUID()
        XCTAssertEqual(
            NewTabContent.resolve(requested: id, existsInStore: true, isOwnedByAnotherWindow: false),
            .conversation(id))
    }

    func testATargetDeletedBetweenTheClickAndTheWindowDoesNotStrandABlankTab() {
        XCTAssertEqual(
            NewTabContent.resolve(
                requested: UUID(), existsInStore: false, isOwnedByAnotherWindow: false),
            .freshConversationInSourceWorkspace)
    }

    func testATargetClaimedByAnotherWindowFallsBackRatherThanDuplicating() {
        // One conversation, one window. This branch is correct; what was wrong is that the branch
        // was reachable at all from a double-click, and that its fallback lost the workspace.
        XCTAssertEqual(
            NewTabContent.resolve(
                requested: UUID(), existsInStore: true, isOwnedByAnotherWindow: true),
            .freshConversationInSourceWorkspace)
    }

    /// The Home half of the bug, stated as a rule rather than as a coordinate: every fallback is a
    /// fresh conversation IN THE SOURCE WORKSPACE, never a rootless one.
    func testEveryFallbackKeepsTheSourceWorkspace() {
        for (exists, owned) in [(false, false), (false, true), (true, true)] {
            XCTAssertEqual(
                NewTabContent.resolve(
                    requested: UUID(), existsInStore: exists, isOwnedByAnotherWindow: owned),
                .freshConversationInSourceWorkspace,
                "exists=\(exists) owned=\(owned)")
        }
    }

    /// The two decisions have to agree, or the pair reproduces FR-236: the first says "open a tab"
    /// while the second says "that tab cannot show it". Asking the same question of both is what
    /// makes that combination unreachable from a double-click.
    func testTheTwoDecisionsCannotDisagreeAboutAnOnScreenConversation() {
        let id = UUID()
        let plan = ConversationOpenPlan.resolve(conversationID: id, isShownInAnyWindow: true)
        XCTAssertEqual(plan, .focusExistingWindow, "no tab is built…")
        // …so the blanking branch below is never reached from this path, even though it remains
        // correct for the races it exists for.
        XCTAssertEqual(
            NewTabContent.resolve(requested: id, existsInStore: true, isOwnedByAnotherWindow: true),
            .freshConversationInSourceWorkspace)
    }
}
