import Foundation

/// The workspace context shared by utility windows. Home is intentionally distinct from an
/// unavailable active window: the former owns loose content, while the latter must not expose
/// every workspace by accident.
enum WorkspaceUtilityScope: Equatable {
    case workspace(id: UUID, legacyCwd: String)
    case folder(cwd: String)
    case home
    case unavailable

    static func current(projectID: UUID?, cwd: String, resolvedFolderProjectID: UUID?) -> Self {
        let normalizedCwd = cwd.trimmingCharacters(in: .whitespacesAndNewlines)
        if let projectID {
            return .workspace(id: projectID, legacyCwd: normalizedCwd)
        }
        if let resolvedFolderProjectID {
            return .workspace(id: resolvedFolderProjectID, legacyCwd: normalizedCwd)
        }
        return normalizedCwd.isEmpty ? .home : .folder(cwd: normalizedCwd)
    }

    var workspaceID: UUID? {
        guard case let .workspace(id, _) = self else { return nil }
        return id
    }

    func contains(artifact: Artifact) -> Bool {
        switch self {
        case let .workspace(id, legacyCwd):
            if artifact.workspaceID == id { return true }
            return artifact.workspaceID == nil
                && !legacyCwd.isEmpty
                && artifact.cwd == legacyCwd
        case let .folder(cwd):
            return artifact.workspaceID == nil && artifact.cwd == cwd
        case .home:
            return artifact.workspaceID == nil
                && artifact.cwd.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .unavailable:
            return false
        }
    }

    func contains(task: ScheduledTask) -> Bool {
        switch self {
        case let .workspace(id, _):
            return task.workspaceID == id
        case .home:
            // Tasks created outside a workspace remain unassigned until the user chooses one.
            // Surface them only in Home rather than leaking them into every workspace.
            return task.workspaceID == nil
        case .folder, .unavailable:
            return false
        }
    }

    func displayName(projects: [Project]) -> String {
        switch self {
        case let .workspace(id, _):
            return projects.first(where: { $0.id == id })?.displayName ?? "Workspace"
        case let .folder(cwd):
            return URL(fileURLWithPath: cwd).lastPathComponent
        case .home:
            return "Home"
        case .unavailable:
            return "No Active Workspace"
        }
    }
}
