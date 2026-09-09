import AppKit
import Foundation

/// Every way something outside a workspace window can ask Mechanician to show something: a
/// Spotlight result, an App Intent, a notification click, a Finder drop, a `mechanician://` link,
/// and a selection or folder sent from another app through the Services menu.
///
/// One enum with one handler (`ActiveWorkspace.open(_:)`) instead of a routing rule per entry
/// point. Before this existed, Spotlight's rule was inlined in `AppDelegate`, the App Intents
/// called `ActiveWorkspace` directly, and each new entry point would have grown its own copy.
///
/// Cases are added when a real caller exists, never speculatively. An unimplemented case is a
/// routing rule that has never run.
enum MechanicianRoute: Equatable {
    /// Show a conversation, focusing the window that already owns it when there is one.
    case conversation(UUID)

    /// Show an artifact in the Artifacts window.
    case artifact(UUID)

    /// Show a workspace: focus its window if one is open, otherwise open one. `nil` is Home, the
    /// default workspace, which is why this is not `case home` plus `case workspace(UUID)` — Home is
    /// the workspace you have when you haven't made one, not a separate destination.
    case workspace(UUID?)

    /// Start a conversation, and send `sending` when it is neither nil nor empty.
    ///
    /// **This case sends.** It exists for App Intents, where the user explicitly ran a shortcut.
    /// The URL scheme and the Services menu must not use it: those may only put text in the
    /// composer, never submit it, because the caller there can be a web page rather than a person.
    /// They use `newConversationDraft` and `appendToComposer` instead.
    ///
    /// `MechanicianURL.route(for:scheme:)` never constructs this case — not with a nil prompt
    /// either — so the rule is a property of the parser rather than something to remember. The
    /// Services provider never constructs it either.
    case newConversation(sending: String?)

    /// Start a conversation with `text` already in the composer, and **do not submit it**.
    ///
    /// This is the Services counterpart to `newConversation(sending:)`. Text selected in another app
    /// is material, not an instruction — the gesture picked a destination, not a prompt — and the
    /// selection may be something the user merely had on screen. Apple's own precedent is prefill:
    /// "New Email With Selection" composes and never sends.
    case newConversationDraft(String)

    /// Start a standard-profile conversation with `text` in the composer, and **do not submit it**.
    ///
    /// This is an internal Help handoff, not an external input surface. It deliberately has no URL
    /// spelling: a Help demonstration may draft into the active workspace when that workspace has
    /// the standard tool profile, but it must fall back to Home rather than widening a closed
    /// workspace such as Memory.
    case newStandardConversationDraft(String)

    /// Add `text` to a composer, and **do not submit it**. `conversationID` names the conversation
    /// to open and add to; `nil` means the one already on screen, which is what a Services selection
    /// wants and what a link naming a conversation does not.
    case appendToComposer(String, conversationID: UUID?)

    /// Attach files delivered by Launch Services: a Finder drop, or a drop on the Dock icon.
    case files([URL])
}

// The handler is `ActiveWorkspace.open(_:)` in RootView.swift, next to the window and pending-state
// rules it dispatches to, so those stay private to the one type that owns them.
