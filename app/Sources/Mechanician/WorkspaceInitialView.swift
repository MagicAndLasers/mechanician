import Foundation

/// The launch-order fence for every route that may construct or repurpose a workspace window.
///
/// Conversation inventory readiness is necessary but not sufficient: the saved session must replay
/// first, otherwise a Spotlight/Dock/File ingress can create a window and session replay can then
/// create a second native group for the same Workspace. The app delegate opens this gate exactly
/// once after authoritative validation and replay.
@MainActor
final class WorkspaceSessionLaunchGate {
    static let shared = WorkspaceSessionLaunchGate()

    private(set) var isOpen = false
    private var callbacks: [@MainActor () -> Void] = []

    func whenOpen(_ operation: @escaping @MainActor () -> Void) {
        if isOpen { operation() } else { callbacks.append(operation) }
    }

    func completeRestore() {
        guard !isOpen else { return }
        isOpen = true
        let pending = callbacks
        callbacks.removeAll()
        for callback in pending { callback() }
    }
}

/// The single entry point for commands that may create or repurpose a workspace window.
///
/// Menu commands are live while the launch splash is still covering inventory recovery. Routing
/// them through the same fence as Spotlight and Dock reopen prevents an eager Home/Workspace
/// command from racing saved-session replay into a second top-level native group.
@MainActor
func performWorkspaceCreatingIngress(_ operation: @escaping @MainActor () -> Void) {
    WorkspaceSessionLaunchGate.shared.whenOpen(operation)
}

/// Injectable form used to prove the command fence without mutating the process-wide launch gate.
@MainActor
func performWorkspaceCreatingIngress(
    after gate: WorkspaceSessionLaunchGate,
    _ operation: @escaping @MainActor () -> Void
) {
    gate.whenOpen(operation)
}

/// What a freshly-built workspace window opens on.
///
/// Pure, because the alternative is proving this rule by booting a bridge and a provider runtime.
/// The rule is small and its edges are exactly where the bugs were: a conversation that vanished
/// between the click and the window being built, a conversation another window already owns, and
/// the difference between the first window at launch and every window after it.
enum WorkspaceInitialView: Equatable {
    /// Show exactly this conversation. The window was opened for it.
    case requested(UUID)

    /// Mint a new conversation. Either this is an additional window with nothing specific asked
    /// for, or what was asked for is gone or already on screen in another window.
    case fresh

    /// First window at launch: the conversation the app was last left on.
    case lastViewed(UUID)

    /// First window at launch with no usable saved conversation: whatever the store lists first.
    case storeDefault

    /// - Parameters:
    ///   - requested: the conversation this window was built to show, bound per-window. Nil for an
    ///     ordinary new window.
    ///   - requestedIsAvailable: whether `requested` still exists and is not already owned by
    ///     another window. Resolved by the caller because checking ownership focuses that other
    ///     window, and a side effect does not belong in the rule.
    ///   - isFirstWindow: whether this is the only live bridge. Every window after the first
    ///     starts fresh rather than duplicating the shared last-viewed conversation.
    ///   - savedLastViewed: the persisted last conversation, already filtered to one the store
    ///     still holds.
    static func resolve(
        requested: UUID?,
        requestedIsAvailable: Bool,
        isFirstWindow: Bool,
        savedLastViewed: UUID?
    ) -> WorkspaceInitialView {
        // A window opened for one conversation shows that conversation or nothing in particular.
        // It never falls through to the last-viewed default: that is how a window opened for
        // conversation A used to end up showing conversation B.
        if let requested {
            return requestedIsAvailable ? .requested(requested) : .fresh
        }
        guard isFirstWindow else { return .fresh }
        if let savedLastViewed { return .lastViewed(savedLastViewed) }
        return .storeDefault
    }
}

/// Pure rules for the second half of a scoped window launch, when the provider becomes ready after
/// the sidebar is already usable. Launch-time identity must validate the folder, but it must never
/// overwrite a conversation the user selected or created during that delay.
enum WorkspaceBootstrapPolicy {
    static func conversationID(currentSelection: UUID?) -> UUID? {
        currentSelection
    }

    static func acceptsFolder(
        expectedProjectID: UUID?,
        resolvedScope: WorkspaceScope?
    ) -> Bool {
        guard let expectedProjectID else { return false }
        return resolvedScope == .project(expectedProjectID)
    }

    /// A requested row is an exact intent, not permission to fall back by recency. This matters for
    /// a pristine New Conversation placeholder: normal persistence may discard it just before the
    /// provider bootstrap chooses a row, in which case the correct result is another fresh row.
    static func acceptsPreferredConversation(
        requestedID: UUID?,
        preferredID: UUID?
    ) -> Bool {
        requestedID == nil || requestedID == preferredID
    }
}

/// The launch view has two independent readiness edges: the authoritative Conversation inventory
/// and the selected provider runtime. Provider warm-up intentionally starts in parallel with the
/// disk scan, but it cannot consume `pendingInitial*` until session restoration has resolved those
/// values against the loaded store. Otherwise a fast provider can mint a blank Conversation and
/// make the later restore yield to it.
enum WorkspaceBootstrapReadiness {
    static func shouldBegin(
        storeIsReady: Bool,
        initialViewResolved: Bool,
        runtimeIsReady: Bool,
        didBootstrap: Bool
    ) -> Bool {
        storeIsReady && initialViewResolved && runtimeIsReady && !didBootstrap
    }

    /// Capture the readiness state at the exact navigation mutation, not later when SwiftUI happens
    /// to deliver an observer. This generation lets a newer pre-ready ⌘N/navigation supersede an
    /// older projected-row click even if the store becomes ready between those two moments.
    static func preReadyNavigationGeneration(
        after current: UInt64,
        storeIsReady: Bool,
        destinationChanged: Bool
    ) -> UInt64 {
        guard destinationChanged, !storeIsReady else { return current }
        return current &+ 1
    }
}
