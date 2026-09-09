import Foundation

/// Compatibility-style facade for the reserved Workspace that holds product-help Conversations.
enum HelpWorkspace {
    static let id = ReservedWorkspace.help.id
    static let name = ReservedWorkspace.help.name
    static let goal = ReservedWorkspace.help.goal
    static let iconSymbol = ReservedWorkspace.help.iconSymbol

    static func owns(_ projectID: UUID?) -> Bool { projectID == id }

    @MainActor
    static func ensure(in store: ProjectStore, then completion: @escaping (Project?) -> Void) {
        ReservedWorkspace.help.ensure(in: store, then: completion)
    }
}

/// Open or focus Help through the ordinary Workspace router. The launch gate prevents this utility-
/// window action from racing saved-session restoration on a cold launch.
@MainActor
func openHelpWorkspace() {
    performWorkspaceCreatingIngress {
        HelpWorkspace.ensure(in: ProjectStore.shared) { project in
            guard let project else { return }
            _ = routeToWorkspaceProject(project, replacing: nil)
        }
    }
}
