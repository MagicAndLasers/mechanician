import Foundation

/// What double-clicking a conversation in the sidebar should do.
///
/// Pure, for the same reason as `WorkspaceInitialView`: the alternative is proving the rule by
/// booting two windows and a provider runtime, so the rule that produced a user-visible bug had no
/// test at all.
///
/// The bug (FR-236). Two owner checks disagreed about whether "already open" included the window you
/// double-clicked in. `openInNewTab` asked the question EXCLUDING its own window, so a conversation
/// already showing there looked closed and a tab was created for it. The new tab then asked the same
/// question WITHOUT that exclusion, found the source window, and fell back to a blank conversation.
/// The result was a double-click producing an empty tab instead of the conversation, every time the
/// target was already on screen somewhere.
///
/// Ownership here means "some window is currently showing it", which is a property of windows and
/// not of the row that was clicked. There is no version of that question whose answer should depend
/// on which window is asking, so both call sites now ask the same one.
enum ConversationOpenPlan: Equatable {
    /// A window already shows this conversation. Focus it; do not build a tab that the new tab's own
    /// owner check would immediately blank.
    case focusExistingWindow
    /// No window shows it, so open a tab on it.
    case openInNewTab(UUID)

    static func resolve(conversationID: UUID, isShownInAnyWindow: Bool) -> ConversationOpenPlan {
        isShownInAnyWindow ? .focusExistingWindow : .openInNewTab(conversationID)
    }
}

/// What a newly-built workspace tab should contain once its bridge is ready.
///
/// Separate from `WorkspaceInitialView`, which answers what a WINDOW opens on at launch. This
/// answers the narrower question a tab faces after being asked to show one specific conversation,
/// where the answer can still change between the click and the bridge becoming ready.
enum NewTabContent: Equatable {
    /// Show the conversation that was asked for.
    case conversation(UUID)
    /// Start a blank conversation instead, because the target is gone or is now owned elsewhere.
    ///
    /// This case is why the bug put the tab in Home. A blank conversation created here inherits
    /// whatever workspace the new bridge happens to have, which is none, so it landed in Home rather
    /// than beside the conversation the user was looking at. A tab must inherit the workspace of the
    /// window it was opened from whether or not it ends up showing the requested conversation.
    case freshConversationInSourceWorkspace

    static func resolve(
        requested: UUID,
        existsInStore: Bool,
        isOwnedByAnotherWindow: Bool
    ) -> NewTabContent {
        guard existsInStore, !isOwnedByAnotherWindow else { return .freshConversationInSourceWorkspace }
        return .conversation(requested)
    }
}
