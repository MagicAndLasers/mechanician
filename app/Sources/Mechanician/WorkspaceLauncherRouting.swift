import Foundation

/// One window's identity as the launcher sees it. Kept as a plain value so the routing rules below
/// are decidable without AppKit, a live bridge, or a Space.
struct WorkspaceWindowIdentity: Equatable, Sendable {
    let bridgeID: UUID
    let projectID: UUID?
    let cwd: String
    let hasWindow: Bool

    init(bridgeID: UUID, projectID: UUID?, cwd: String, hasWindow: Bool = true) {
        self.bridgeID = bridgeID
        self.projectID = projectID
        self.cwd = cwd
        self.hasWindow = hasWindow
    }
}

/// Everything one newly-built tab needs, bound to that tab rather than published through a
/// process-global handoff. Two rapid tab requests therefore cannot overwrite each other's scope or
/// collapse two fresh-conversation requests into one Boolean.
struct WorkspaceTabIntent: Equatable, Sendable {
    let initialFolder: String?
    let initialProjectID: UUID?
    let initialConversationID: UUID?
    let startsFreshConversation: Bool
    /// The source Conversation's provider/model pair. It is present only for a fresh tab in the
    /// same canonical WorkspaceScope; named tabs and source-less tabs deliberately retain their
    /// ordinary bootstrap/default behavior.
    let initialFreshModelSelection: ModelSelection?
}

/// What the Workspaces gallery should do with a chosen destination.
enum WorkspaceLauncherRoute: Equatable, Sendable {
    /// A window already shows this workspace. Go to it.
    case focus(UUID)
    /// No window shows it, but the window the user opened the gallery *from* is still alive, so
    /// that window changes workspace in place.
    case replaceOrigin(UUID)
    /// Nothing safe to reuse. Focus-or-create, which can never repurpose an unrelated window.
    case openWorkspace
}

/// The gallery is one shared scene reached from any window, so "which window am I acting on?" is
/// not obvious from the scene itself. It used to read the process-wide "last key workspace window",
/// which is frequently not the window the user is looking at: picking a workspace then rewrote an
/// unrelated window in place and pulled focus to it, ending in two windows bound to one workspace.
///
/// The origin is now captured when the gallery opens and re-resolved here. If it is gone, the route
/// falls through to focus-or-create rather than mutating whatever window happens to be key.
enum WorkspaceLauncherRouting {
    /// The single answer to "does an open window already show this workspace?"
    ///
    /// This predicate was written four different ways across the launcher, the toolbar, and the
    /// active-workspace lookup, and one spelling omitted the `projectID == nil` guard for folder
    /// workspaces. Disagreement is what allowed one path to decide a workspace had no window while
    /// another found one, so both a switch and a create could happen for the same workspace.
    static func owner(
        ofProjectID projectID: UUID,
        cwd: String,
        among windows: [WorkspaceWindowIdentity]
    ) -> WorkspaceWindowIdentity? {
        windows.first { window in
            guard window.hasWindow else { return false }
            if cwd.isEmpty { return window.projectID == projectID }
            // A folder Workspace owns a window only when that window is not already bound to a
            // topic Workspace that merely happens to sit in the same directory.
            return window.cwd == cwd && window.projectID == nil
        }
    }

    static func homeOwner(among windows: [WorkspaceWindowIdentity]) -> WorkspaceWindowIdentity? {
        windows.first { $0.hasWindow && $0.projectID == nil && $0.cwd.isEmpty }
    }

    static func route(
        projectID: UUID,
        cwd: String,
        originBridgeID: UUID?,
        among windows: [WorkspaceWindowIdentity]
    ) -> WorkspaceLauncherRoute {
        if let owner = owner(ofProjectID: projectID, cwd: cwd, among: windows) {
            return .focus(owner.bridgeID)
        }
        return originRoute(originBridgeID: originBridgeID, among: windows)
    }

    static func homeRoute(
        originBridgeID: UUID?,
        among windows: [WorkspaceWindowIdentity]
    ) -> WorkspaceLauncherRoute {
        if let owner = homeOwner(among: windows) { return .focus(owner.bridgeID) }
        return originRoute(originBridgeID: originBridgeID, among: windows)
    }

    private static func originRoute(
        originBridgeID: UUID?,
        among windows: [WorkspaceWindowIdentity]
    ) -> WorkspaceLauncherRoute {
        guard let originBridgeID,
              windows.contains(where: { $0.bridgeID == originBridgeID && $0.hasWindow })
        else { return .openWorkspace }
        return .replaceOrigin(originBridgeID)
    }
}

/// Chooses the existing workspace window that should host File ▸ New Tab.
///
/// A utility window can be key while the command is invoked, so key-window identity alone is not a
/// sufficient source. Prefer it when it really is a live workspace; otherwise retain the last active
/// workspace, then any surviving workspace. Kept pure so this Space-sensitive routing does not need
/// an AppKit integration test.
enum WorkspaceTabRouting {
    static func sourceBridgeID(
        keyWindowBridgeID: UUID?,
        activeBridgeID: UUID?,
        among windows: [WorkspaceWindowIdentity]
    ) -> UUID? {
        let liveIDs = Set(windows.lazy.filter(\.hasWindow).map(\.bridgeID))
        if let keyWindowBridgeID, liveIDs.contains(keyWindowBridgeID) {
            return keyWindowBridgeID
        }
        if let activeBridgeID, liveIDs.contains(activeBridgeID) {
            return activeBridgeID
        }
        return windows.first(where: \.hasWindow)?.bridgeID
    }

    static func intent(
        source: WorkspaceWindowIdentity?,
        initialConversationID: UUID?,
        sourceModelSelection: ModelSelection? = nil
    ) -> WorkspaceTabIntent {
        WorkspaceTabIntent(
            initialFolder: source?.cwd.isEmpty == false ? source?.cwd : nil,
            initialProjectID: source?.projectID,
            initialConversationID: initialConversationID,
            startsFreshConversation: initialConversationID == nil,
            initialFreshModelSelection: initialConversationID == nil ? sourceModelSelection : nil)
    }

    /// A tab inherits a model only from the Conversation actually displayed by its source window,
    /// and only when both values name the same canonical Workspace. Comparing the canonical scopes
    /// (rather than raw cwd/project fields) keeps folder-backed workspaces correct and rejects a
    /// transition-race where a bridge's visible Conversation belongs somewhere else. Legacy rows
    /// without a durable stamp use the source bridge's effective selection, which is what that row
    /// is currently running on.
    static func freshConversationModelSelection(
        source: WorkspaceWindowIdentity?,
        sourceConversation: Conversation?,
        sourceProjectedSelection: ModelSelection? = nil,
        projects: [Project]
    ) -> ModelSelection? {
        guard let source,
              source.hasWindow,
              let sourceConversation,
              let targetScope = WorkspaceScope.resolve(
                projectID: source.projectID,
                cwd: source.cwd,
                projects: projects),
              let conversationScope = WorkspaceScope.resolve(
                conversation: sourceConversation,
                projects: projects),
              targetScope == conversationScope
        else { return nil }
        return sourceConversation.modelSelection ?? sourceProjectedSelection
    }
}
