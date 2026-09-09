import AppKit
import SwiftUI

/// Provider-neutral presentation rules shared by the launcher and every workspace window.
///
/// Keeping the action title here prevents folder workspaces from drifting back to provider-specific
/// labels such as "Edit CLAUDE.md" while Home and topic workspaces say something different.
enum WorkspaceInstructionsPresentation {
    static let actionTitle = "Workspace Instructions…"
    static let systemImage = "text.book.closed"

    /// Resolve the workspace currently represented by a window without minting a Project as a side
    /// effect. A dangling project/folder is unavailable rather than silently falling through to Home.
    static func target(
        projectID: UUID?,
        cwd: String,
        projects: [Project]
    ) -> WorkspaceInstructionsTarget? {
        guard !ReservedWorkspace.owns(projectID),
              let target = WorkspaceInstructionResolver.target(
            projectID: projectID,
            cwd: cwd,
            projects: projects),
              !ReservedWorkspace.owns(target) else { return nil }
        return target
    }
}

@MainActor
extension AgentBridge {
    /// Every user-facing entry point routes through one resolver so Home, topic, folder, and
    /// unavailable workspaces cannot disagree about which instructions are being edited.
    @discardableResult
    func presentWorkspaceInstructions() -> Bool {
        guard let target = WorkspaceInstructionsPresentation.target(
            projectID: projectID,
            cwd: cwd,
            projects: ProjectStore.shared.projects
        ) else { return false }
        workspaceInstructionsEditorTarget = target
        return true
    }
}

/// The only repository instruction files the editor may address. An enum rather than an arbitrary
/// filename keeps create/open/reveal operations pinned to the workspace root.
enum RepositoryInstructionFile: String, CaseIterable, Identifiable {
    case claude = "CLAUDE.md"
    case agents = "AGENTS.md"

    var id: String { rawValue }
}

/// File-system boundary for the editor's explicit repository-file actions.
///
/// Merely presenting the editor only calls `status`; it never creates or edits a repository file.
/// `create` refuses every existing node (including a symlink or directory), writes without
/// overwriting, and verifies that the resulting root-level item is a plain regular file.
enum RepositoryInstructionFileOperations {
    enum Status: Equatable {
        case missing(URL)
        case regularFile(URL)
        case unsupported(URL, String)
        case unavailable(URL, String)

        var url: URL {
            switch self {
            case .missing(let url), .regularFile(let url),
                 .unsupported(let url, _), .unavailable(let url, _):
                return url
            }
        }
    }

    enum CreationError: LocalizedError, Equatable {
        case folderUnavailable
        case alreadyExists(String)
        case didNotCreateRegularFile(String)

        var errorDescription: String? {
            switch self {
            case .folderUnavailable:
                return "The workspace folder is unavailable."
            case .alreadyExists(let name):
                return "\(name) already exists. Mechanician did not replace it."
            case .didNotCreateRegularFile(let name):
                return "\(name) could not be created as a regular file in the workspace root."
            }
        }
    }

    static func fileURL(_ file: RepositoryInstructionFile, in folder: String) -> URL {
        URL(fileURLWithPath: folder, isDirectory: true)
            .standardizedFileURL
            .appendingPathComponent(file.rawValue, isDirectory: false)
    }

    static func status(
        of file: RepositoryInstructionFile,
        in folder: String,
        fileManager: FileManager = .default
    ) -> Status {
        let url = fileURL(file, in: folder)
        var rootIsDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: url.deletingLastPathComponent().path,
                                     isDirectory: &rootIsDirectory),
              rootIsDirectory.boolValue else {
            return .unavailable(url, "Workspace folder unavailable")
        }

        do {
            let attributes = try fileManager.attributesOfItem(atPath: url.path)
            switch attributes[.type] as? FileAttributeType {
            case .typeRegular:
                return .regularFile(url)
            case .typeSymbolicLink:
                return .unsupported(url, "Symbolic link, not managed by Mechanician")
            case .typeDirectory:
                return .unsupported(url, "A folder already uses this name")
            default:
                return .unsupported(url, "Not a regular file")
            }
        } catch {
            let nsError = error as NSError
            if nsError.domain == NSCocoaErrorDomain
                && (nsError.code == NSFileNoSuchFileError
                    || nsError.code == NSFileReadNoSuchFileError) {
                return .missing(url)
            }
            NSLog("[instructions] %@ could not be read: %@",
                  url.lastPathComponent, error.localizedDescription)
            return .unavailable(url, "This file could not be read.")
        }
    }

    @discardableResult
    static func create(
        _ file: RepositoryInstructionFile,
        in folder: String,
        contents: Data = Data(),
        fileManager: FileManager = .default
    ) throws -> URL {
        let initial = status(of: file, in: folder, fileManager: fileManager)
        let url: URL
        switch initial {
        case .missing(let missingURL):
            url = missingURL
        case .regularFile, .unsupported:
            throw CreationError.alreadyExists(file.rawValue)
        case .unavailable:
            throw CreationError.folderUnavailable
        }

        do {
            try contents.write(to: url, options: .withoutOverwriting)
        } catch {
            // A competing creator between the status check and exclusive write is still an ordinary
            // no-overwrite result, not permission to retry destructively.
            if fileManager.fileExists(atPath: url.path) {
                throw CreationError.alreadyExists(file.rawValue)
            }
            throw error
        }

        guard case .regularFile = status(of: file, in: folder, fileManager: fileManager) else {
            throw CreationError.didNotCreateRegularFile(file.rawValue)
        }
        return url
    }
}

private struct WorkspaceInstructionsEditorNotice: Identifiable {
    let id = UUID()
    let title: String
    let message: String
}

/// One in-app editor for Home, chat-only projects, and folder-backed projects. Folder workspaces get
/// separate, explicitly labeled repository-file controls; those files are never conflated with the
/// Mechanician-owned text being edited here.
struct WorkspaceInstructionsEditor: View {
    let target: WorkspaceInstructionsTarget
    let onClose: () -> Void

    @ObservedObject private var store = ProjectStore.shared
    @State private var text: String
    @State private var repositoryFileRevision = 0
    @State private var notice: WorkspaceInstructionsEditorNotice?

    init(target: WorkspaceInstructionsTarget, onClose: @escaping () -> Void) {
        self.target = target
        self.onClose = onClose
        _text = State(initialValue: ProjectStore.shared.instructions(for: target) ?? "")
    }

    private var displayName: String {
        store.displayName(for: target) ?? "Workspace"
    }

    private var folder: String? {
        store.folder(for: target)
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Workspace Instructions")
                    .font(.system(size: 17, weight: .semibold))
                Text("Standing instructions for “\(displayName)”. Mechanician adds them to future turns in every conversation in this workspace.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Label {
                    Text("Stored in Mechanician’s app data, not in a repository or workspace folder.")
                } icon: {
                    Image(systemName: "internaldrive")
                }
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.nSurface))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(Color.nMuted.opacity(0.4)))
                .accessibilityIdentifier("workspaceInstructions.storageDisclosure")

                TextEditor(text: $text)
                    .font(.system(size: 13, design: .monospaced))
                    .scrollContentBackground(.hidden)
                    .padding(8)
                    .frame(minHeight: 230)
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.nSurface))
                    .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(Color.nMuted.opacity(0.5)))
                    .accessibilityLabel("Workspace instructions")
                    .accessibilityIdentifier("workspaceInstructions.editor")

                if let folder {
                    repositoryFilesSection(folder: folder)
                }
            }
            .padding(20)

            Divider()
            HStack(spacing: 10) {
                Spacer()
                Button("Cancel", role: .cancel) { onClose() }
                    .buttonStyle(PillButtonStyle(kind: .plain))
                    .keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("workspaceInstructions.cancel")
                Button("Save") { save() }
                    .buttonStyle(PillButtonStyle(kind: .accent))
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("workspaceInstructions.save")
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(.bar)
        }
        .frame(width: 600)
        .background(Color.nBg)
        .alert(item: $notice) { notice in
            Alert(
                title: Text(notice.title),
                message: Text(notice.message),
                dismissButton: .default(Text("OK")))
        }
    }

    private func repositoryFilesSection(folder: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Divider()
            Text("Repository instruction files")
                .font(.system(size: 12.5, weight: .semibold))
            Text("These stay separate from the app-owned text above. Mechanician safely imports the root CLAUDE.md for Claude; Codex discovers AGENTS.md natively.")
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            ForEach(RepositoryInstructionFile.allCases) { file in
                repositoryFileRow(file, folder: folder)
            }
        }
        .padding(.top, 2)
        .accessibilityIdentifier("workspaceInstructions.repositoryFiles")
    }

    @ViewBuilder
    private func repositoryFileRow(
        _ file: RepositoryInstructionFile,
        folder: String
    ) -> some View {
        let status = RepositoryInstructionFileOperations.status(of: file, in: folder)
        HStack(spacing: 10) {
            Image(systemName: "doc.text")
                .foregroundStyle(.secondary)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 1) {
                Text(file.rawValue)
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                Text(statusDescription(status))
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            switch status {
            case .missing:
                Button("Create") { create(file, in: folder) }
                    .buttonStyle(PillButtonStyle(kind: .neutral))
                    .controlSize(.small)
            case .regularFile(let url):
                Button("Open") { open(url, named: file.rawValue) }
                    .buttonStyle(PillButtonStyle(kind: .plain))
                    .controlSize(.small)
                Button("Reveal") { reveal(url) }
                    .buttonStyle(PillButtonStyle(kind: .neutral))
                    .controlSize(.small)
            case .unsupported(let url, _):
                Button("Reveal") { reveal(url) }
                    .buttonStyle(PillButtonStyle(kind: .neutral))
                    .controlSize(.small)
            case .unavailable:
                EmptyView()
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(Color.nSurface))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
            .strokeBorder(Color.nMuted.opacity(0.35)))
        .accessibilityIdentifier("workspaceInstructions.repositoryFile.\(file.rawValue)")
    }

    private func statusDescription(
        _ status: RepositoryInstructionFileOperations.Status
    ) -> String {
        switch status {
        case .missing:
            return "Not created"
        case .regularFile:
            return "Regular file in workspace root"
        case .unsupported(_, let detail), .unavailable(_, let detail):
            return detail
        }
    }

    private func create(_ file: RepositoryInstructionFile, in folder: String) {
        do {
            _ = try RepositoryInstructionFileOperations.create(file, in: folder)
            repositoryFileRevision += 1
        } catch {
            NSLog("[instructions] %@ could not be created: %@",
                  file.rawValue, error.localizedDescription)
            notice = WorkspaceInstructionsEditorNotice(
                title: "Couldn’t Create \(file.rawValue)",
                message: "Mechanician could not create the file in this folder. Check that the "
                    + "folder still exists and that you can write to it.")
        }
    }

    private func open(_ url: URL, named name: String) {
        guard NSWorkspace.shared.open(url) else {
            notice = WorkspaceInstructionsEditorNotice(
                title: "Couldn’t Open \(name)",
                message: "No application was available to open this file.")
            return
        }
    }

    private func reveal(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    private func save() {
        guard store.setInstructions(text, for: target) else {
            notice = WorkspaceInstructionsEditorNotice(
                title: "Workspace Unavailable",
                message: "This workspace no longer exists. Your draft has not been discarded.")
            return
        }
        onClose()
    }
}
