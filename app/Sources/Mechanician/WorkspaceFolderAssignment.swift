import AppKit
import Foundation

/// Pure current-workspace presentation shared by the toolbar and the macOS Workspace menu.
/// Home intentionally opens a separate folder workspace; it never mutates into a folder-backed
/// Project. Topic and folder Projects use the coordinated assignment path below.
@MainActor
enum WorkspaceManagementPresentation {
    static let homeFolderActionTitle = "Open Folder as Workspace…"
    static let revealFolderActionTitle = "Show Workspace Folder in Finder"
    static let editWorkspaceActionTitle = "Workspace Details…"
    static let allWorkspacesActionTitle = "All Workspaces…"

    static func project(
        projectID: UUID?,
        cwd: String,
        projects: [Project]
    ) -> Project? {
        if let projectID {
            return projects.first { $0.id == projectID }
        }
        guard !cwd.isEmpty else { return nil }
        return projects.first { $0.cwd == cwd }
    }

    static func folderActionTitle(
        projectID: UUID?,
        cwd: String,
        projects: [Project]
    ) -> String? {
        if projectID == nil && cwd.isEmpty {
            return homeFolderActionTitle
        }
        guard let project = project(
            projectID: projectID,
            cwd: cwd,
            projects: projects
        ), !ReservedWorkspace.owns(project.id) else { return nil }
        return WorkspaceFolderAssignment.actionTitle(for: project)
    }

    static func folderPath(
        projectID: UUID?,
        cwd: String,
        projects: [Project]
    ) -> String? {
        guard let project = project(
            projectID: projectID,
            cwd: cwd,
            projects: projects
        ), !ReservedWorkspace.owns(project.id), !project.cwd.isEmpty else { return nil }
        return project.cwd
    }

    static func canEditWorkspace(
        projectID: UUID?,
        cwd: String,
        projects: [Project]
    ) -> Bool {
        guard let project = project(
            projectID: projectID,
            cwd: cwd,
            projects: projects
        ) else { return false }
        return !ReservedWorkspace.owns(project.id)
    }
}

/// One user-facing path for attaching or changing a workspace folder. The project record,
/// conversations, open windows, and provider cwd must move together or the workspace can split into
/// two identities after the next persistence pass.
@MainActor
enum WorkspaceFolderAssignment {
    /// A second click while the authoritative inventory is loading or a folder graph is being
    /// acquired must not open a second confirmation sheet for the same Workspace. The placement
    /// coordinator has its own process-wide lease; this small UI set lets us explain the wait at
    /// the point of the duplicate action instead of falling through to a generic failure later.
    private static var activeRequestsByProject: [UUID: UUID] = [:]

    static func actionTitle(for project: Project) -> String {
        project.cwd.isEmpty ? "Add Folder…" : "Change Folder…"
    }

    @discardableResult
    static func chooseFolder(
        for project: Project,
        completion: (@MainActor (Bool) -> Void)? = nil
    ) -> Bool {
        guard !ReservedWorkspace.owns(project.id) else {
            completion?(false)
            return false
        }
        guard activeRequestsByProject[project.id] == nil else {
            showAlert(
                title: "Workspace folder change in progress",
                message: "Wait for the current folder change to finish, then try again.")
            completion?(false)
            return false
        }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.directoryURL = project.cwd.isEmpty ? nil : URL(fileURLWithPath: project.cwd)
        panel.prompt = project.cwd.isEmpty ? "Add Folder" : "Change Folder"
        guard panel.runModal() == .OK, let url = panel.url else {
            completion?(false)
            return false
        }
        return assign(url.path, to: project, completion: completion)
    }

    @discardableResult
    static func assign(
        _ path: String,
        to project: Project,
        completion: (@MainActor (Bool) -> Void)? = nil
    ) -> Bool {
        guard !ReservedWorkspace.owns(project.id) else {
            completion?(false)
            return false
        }
        let newPath = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !newPath.isEmpty else {
            completion?(false)
            return false
        }
        if newPath == project.cwd {
            completion?(true)
            return true
        }

        guard activeRequestsByProject[project.id] == nil else {
            showAlert(
                title: "Workspace folder change in progress",
                message: "Wait for the current folder change to finish, then try again.")
            completion?(false)
            return false
        }

        let request = WorkspaceFolderReassignmentRequest(
            projectID: project.id,
            expectedCwd: project.cwd,
            destinationCwd: newPath)
        activeRequestsByProject[project.id] = request.id
        let conversations = ConversationStore.shared
        conversations.whenReady {
            beginReadyAssignment(
                request,
                projects: .shared,
                conversations: conversations,
                completion: completion)
        }
        return true
    }

    /// Confirmation deliberately happens only after the authoritative Conversation scan has
    /// completed. Before readiness, SQLite summaries are a disposable launch projection and may
    /// undercount the exact graph whose location will change.
    private static func beginReadyAssignment(
        _ request: WorkspaceFolderReassignmentRequest,
        projects: ProjectStore,
        conversations: ConversationStore,
        completion: (@MainActor (Bool) -> Void)?
    ) {
        guard activeRequestsByProject[request.projectID] == request.id else {
            completion?(false)
            return
        }
        guard !ReservedWorkspace.owns(request.projectID) else {
            finish(.unavailable, request: request, completion: completion)
            return
        }
        guard let current = projects.project(request.projectID) else {
            finish(.unavailable, request: request, completion: completion)
            return
        }
        guard current.cwd == request.expectedCwd else {
            finish(.sourceChanged, request: request, completion: completion)
            return
        }
        if let clash = projects.projects.first(where: {
            $0.id != request.projectID && $0.cwd == request.destinationCwd
        }) {
            finish(
                .collision(clash.displayName),
                request: request,
                completion: completion)
            return
        }
        if AgentBridge.live.allObjects.contains(where: { $0.hasReservedTurn(in: current) }) {
            finish(.activeWork, request: request, completion: completion)
            return
        }

        let scope = WorkspaceScope.project(request.projectID)
        let affected = conversations.summaries.filter {
            scope.contains($0, projects: projects.projects)
        }.count
        if affected > 0 {
            let adding = request.expectedCwd.isEmpty
            let alert = NSAlert()
            alert.messageText = adding
                ? "Add a working folder to this Workspace?"
                : "Change this Workspace’s working folder?"
            alert.informativeText = "\(affected) Conversation\(affected == 1 ? "" : "s") will use the selected folder, and future turns will run there."
            alert.addButton(withTitle: adding ? "Add Folder" : "Change Folder")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else {
                if activeRequestsByProject[request.projectID] == request.id {
                    activeRequestsByProject[request.projectID] = nil
                }
                completion?(false)
                return
            }
        }

        _ = WorkspaceAdoption.reassignWorkspaceFolderAfterAcquiring(
            request,
            projects: projects,
            conversations: conversations,
            artifactStore: .shared
        ) { result in
            finish(result, request: request, completion: completion)
        }
    }

    private static func finish(
        _ result: WorkspaceFolderReassignmentResult,
        request: WorkspaceFolderReassignmentRequest,
        completion: (@MainActor (Bool) -> Void)?
    ) {
        guard activeRequestsByProject[request.projectID] == request.id else {
            completion?(false)
            return
        }
        activeRequestsByProject[request.projectID] = nil
        if !result.succeeded {
            showAlert(title: failureTitle(for: result), message: result.failureMessage ?? "Nothing changed.")
        }
        completion?(result.succeeded)
    }

    private static func failureTitle(for result: WorkspaceFolderReassignmentResult) -> String {
        switch result {
        case .collision:
            return "Folder already in use"
        case .unavailable, .bindingUnavailable:
            return "Workspace unavailable"
        case .sourceChanged:
            return "Workspace changed"
        case .activeWork:
            return "Workspace is busy"
        case .moveInProgress:
            return "Workspace move in progress"
        case .changed, .unchanged:
            return "Folder changed"
        }
    }

    private static func showAlert(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}
