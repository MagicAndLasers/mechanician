import AppKit
import SwiftUI

/// Pure routing policy for the artifact revealed after a successful workspace move. Bulk moves
/// choose one stable row so the result does not depend on Set iteration order.
enum ArtifactMoveRevealPolicy {
    static func artifactID(
        after result: WorkspaceAdoptionResult,
        moving artifactIDs: Set<UUID>
    ) -> UUID? {
        guard result.succeeded else { return nil }
        return artifactIDs.min { $0.uuidString < $1.uuidString }
    }
}

/// Menu rows hold value snapshots while their actions remain open. Re-resolve a project by identity
/// at click time so a deleted workspace cannot receive a move and an edited workspace uses its
/// current folder rather than the stale row value.
enum ArtifactMoveDestinationPolicy {
    static func resolve(
        _ requested: WorkspaceDestination,
        availableProjects: [Project]
    ) -> WorkspaceDestination? {
        switch requested {
        case .home:
            return .home
        case .project(let snapshot):
            guard let current = availableProjects.first(where: { $0.id == snapshot.id }) else {
                return nil
            }
            return .project(current)
        }
    }
}

/// Shared routing behind both the SwiftUI inspector menu and the AppKit artifact browser menu.
/// Destination rows are snapshots, so every invocation re-resolves the Workspace by identity before
/// moving and once more before revealing the result.
@MainActor
enum ArtifactWorkspaceMoveActions {
    static func beginNewWorkspaceMove(
        artifactIDs: Set<UUID>,
        openProjectsWindow: () -> Void
    ) {
        guard ProjectStore.shared.beginWorkspaceAdoption(
            .artifacts(artifactIDs),
            originBridgeID: ActiveWorkspace.shared.bridge?.bridgeID) != nil
        else { return }
        ProjectStore.shared.pendingNewProjectRequest = true
        NSApp.activate(ignoringOtherApps: true)
        openProjectsWindow()
    }

    static func move(
        artifactIDs: Set<UUID>,
        to requestedDestination: WorkspaceDestination
    ) {
        let projects = ProjectStore.shared
        guard let destination = ArtifactMoveDestinationPolicy.resolve(
            requestedDestination,
            availableProjects: projects.projects)
        else {
            presentIfNeeded(.unavailable, count: artifactIDs.count)
            return
        }

        WorkspaceAdoption.adoptAfterAcquiring(
            artifacts: artifactIDs,
            into: destination,
            undoManager: workspaceUndoManager(for: ActiveWorkspace.shared.bridge)
        ) { result in
            presentIfNeeded(result, count: artifactIDs.count)

            guard let artifactID = ArtifactMoveRevealPolicy.artifactID(
                after: result,
                moving: artifactIDs),
                  let revealDestination = ArtifactMoveDestinationPolicy.resolve(
                    requestedDestination,
                    availableProjects: projects.projects)
            else { return }

            switch revealDestination {
            case .home:
                openHome()
            case .project(let project):
                openProject(project)
            }
            ActiveWorkspace.shared.revealArtifact(artifactID)
        }
    }

    private static func presentIfNeeded(_ result: WorkspaceAdoptionResult, count: Int) {
        guard let message = result.failureMessage else { return }
        let alert = NSAlert()
        if result == .busy {
            alert.messageText = count == 1
                ? String(localized: "Artifact can’t be moved yet")
                : String(localized: "Artifacts can’t be moved yet")
        } else if result == .moveInProgress {
            alert.messageText = String(localized: "Move already in progress")
        } else {
            alert.messageText = count == 1
                ? String(localized: "Artifact unavailable")
                : String(localized: "Artifacts unavailable")
        }
        alert.informativeText = message
        alert.addButton(withTitle: String(localized: "OK"))
        alert.runModal()
    }
}

/// The one Move to Workspace submenu shared by the inspector and global artifact browser.
/// Keeping destination construction and New Workspace adoption here prevents the two surfaces from
/// acquiring subtly different Home/folder-less/cancellation behavior.
struct ArtifactWorkspaceMoveMenu: View {
    let artifactIDs: Set<UUID>

    @ObservedObject private var projects = ProjectStore.shared
    @ObservedObject private var artifactStore = ArtifactStore.shared
    @Environment(\.openWindow) private var openWindow

    init(artifact: Artifact) {
        artifactIDs = [artifact.uuid]
    }

    init(artifacts: Set<UUID>) {
        artifactIDs = artifacts
    }

    private var artifacts: [Artifact] {
        artifactStore.artifacts.filter { artifactIDs.contains($0.uuid) }
    }

    var body: some View {
        Menu {
            Button {
                beginNewWorkspaceMove()
            } label: {
                Label("New Workspace…", systemImage: "plus")
            }

            Divider()
            destinationButton(.home)
            ForEach(projects.projects) { project in
                destinationButton(.project(project))
            }
        } label: {
            Label("Move to Workspace", systemImage: "folder")
        }
    }

    @ViewBuilder
    private func destinationButton(_ destination: WorkspaceDestination) -> some View {
        let current = isCurrent(destination)
        Button {
            move(to: destination)
        } label: {
            if current {
                Label(destination.displayName, systemImage: "checkmark")
            } else {
                Text(destination.displayName)
            }
        }
        .disabled(current || artifactIDs.isEmpty)
    }

    private func isCurrent(_ destination: WorkspaceDestination) -> Bool {
        artifacts.count == artifactIDs.count
            && artifacts.allSatisfy {
                $0.workspaceID == destination.projectID && $0.cwd == destination.cwd
            }
    }

    private func beginNewWorkspaceMove() {
        ArtifactWorkspaceMoveActions.beginNewWorkspaceMove(artifactIDs: artifactIDs) {
            openWindow(id: "projects")
        }
    }

    /// Existing destinations use the same focus-or-create policy as the workspace launcher. Route
    /// first, then publish the reveal request: the source global browser must not consume a
    /// destination-scoped selection while it is still the active workspace.
    private func move(to requestedDestination: WorkspaceDestination) {
        ArtifactWorkspaceMoveActions.move(
            artifactIDs: artifactIDs,
            to: requestedDestination)
    }
}
