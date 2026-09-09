import Foundation

/// App-owned Workspaces that hold ordinary Conversations but are not user-created Workspaces.
///
/// A reserved Workspace deliberately remains an ordinary, folderless `Project` in storage. Its
/// fixed identity lets the existing window, Conversation, search, and persistence machinery carry
/// it without adding another persisted Workspace kind. This registry is the one place that answers
/// whether a Workspace is product-owned, so new reserved destinations cannot be missed by one of
/// the user-Workspace lists or mutation guards.
enum ReservedWorkspace: CaseIterable, Identifiable {
    case help

    var id: UUID {
        switch self {
        case .help:
            // Never regenerate. Help Conversations persist this exact Workspace id.
            UUID(uuidString: "D353F793-FC8A-497C-BF64-BD396EF2F367")!
        }
    }

    var name: String {
        switch self {
        case .help: String(localized: "Help")
        }
    }

    var goal: String {
        switch self {
        case .help:
            String(
                localized: "Ask Mechanician how the app works, why it works that way, and how to troubleshoot or extend it.")
        }
    }

    var iconSymbol: String {
        switch self {
        case .help: "questionmark.bubble"
        }
    }

    static func workspace(for projectID: UUID?) -> Self? {
        guard let projectID else { return nil }
        return allCases.first { $0.id == projectID }
    }

    static func owns(_ projectID: UUID?) -> Bool {
        workspace(for: projectID) != nil
    }

    static func owns(_ scope: WorkspaceScope) -> Bool {
        guard case .project(let projectID) = scope else { return false }
        return owns(projectID)
    }

    /// Preserve only the per-Workspace provider preference from an incoming value. Everything a
    /// person can normally edit on a Workspace card is part of this reserved identity.
    func canonicalProject(preservingRuntimePreferenceFrom source: Project? = nil) -> Project {
        Project(
            id: id,
            name: name,
            goal: goal,
            instructions: "",
            cwd: "",
            favorite: false,
            sortIndex: nil,
            iconSymbol: iconSymbol,
            colorHex: nil,
            defaultModelSelection: source?.defaultModelSelection,
            createdAt: source?.createdAt ?? Date(),
            updatedAt: source?.updatedAt ?? Date())
    }

    /// Whether a loaded record still has the identity owned by the app. Provider preference and
    /// timestamps are intentionally omitted: those are durable runtime/history fields and are
    /// preserved when an older editable reserved row is repaired at launch.
    func hasCanonicalIdentity(_ project: Project) -> Bool {
        project.id == id
            && project.name == name
            && project.goal == goal
            && project.instructions.isEmpty
            && project.cwd.isEmpty
            && !project.favorite
            && project.sortIndex == nil
            && project.iconSymbol == iconSymbol
            && project.colorHex == nil
    }

    /// A normal runtime model preference may still evolve, but generic Project mutation cannot
    /// rename, decorate, instruct, folder-bind, reorder, or otherwise edit a reserved Workspace.
    func preservingIdentity(of current: Project, after proposed: Project) -> Project {
        var protected = current
        protected.defaultModelSelection = proposed.defaultModelSelection
        protected.updatedAt = proposed.updatedAt
        return protected
    }

    /// Create on first use and return the existing row thereafter. Creation uses the same staged
    /// publication path as an ordinary Workspace, so no Conversation can point at an unpublished
    /// identity and a repeated call can never duplicate it.
    @MainActor
    func ensure(in store: ProjectStore, then completion: @escaping (Project?) -> Void) {
        if let existing = store.project(id) {
            completion(existing)
            return
        }
        let project = canonicalProject()
        store.prepareWorkspaceProject(project) { prepared in
            guard case let .success(staged) = prepared else {
                completion(nil)
                return
            }
            // Another caller may have completed the same lazy ensure while this one was staging.
            // Reuse that row and discard our unpublished staging file rather than reporting a
            // spurious failure or attempting a second publication.
            if let existing = store.project(id) {
                store.discardPreparedWorkspaceProject(staged)
                completion(existing)
                return
            }
            guard case let .success(published) = store.publishPreparedWorkspaceProject(staged)
            else {
                store.discardPreparedWorkspaceProject(staged)
                completion(store.project(id))
                return
            }
            completion(published)
        }
    }
}
