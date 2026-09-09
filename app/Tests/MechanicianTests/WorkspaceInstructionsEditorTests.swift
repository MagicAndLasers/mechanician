import AppKit
import XCTest
@testable import Mechanician

@MainActor
final class WorkspaceInstructionsEditorTests: XCTestCase {
    func testPresentationUsesOneConstantActionTitleAndResolvesEveryWorkspaceKind() {
        let topic = Project(name: "Research")
        let folder = Project(name: "Code", cwd: "/private/tmp/code-\(UUID().uuidString)")
        let projects = [topic, folder]

        XCTAssertEqual(WorkspaceInstructionsPresentation.actionTitle, "Workspace Instructions…")
        XCTAssertEqual(
            WorkspaceInstructionsPresentation.target(projectID: nil, cwd: "", projects: projects),
            .home)
        XCTAssertEqual(
            WorkspaceInstructionsPresentation.target(
                projectID: topic.id, cwd: "", projects: projects),
            .project(topic.id))
        XCTAssertEqual(
            WorkspaceInstructionsPresentation.target(
                projectID: nil, cwd: folder.cwd, projects: projects),
            .project(folder.id))
        XCTAssertNil(
            WorkspaceInstructionsPresentation.target(
                projectID: UUID(), cwd: "", projects: projects),
            "A dangling project must not fall through to Home")
        XCTAssertNil(
            WorkspaceInstructionsPresentation.target(
                projectID: nil, cwd: "/missing", projects: projects),
            "An unregistered folder must not fall through to Home")
        XCTAssertNil(
            WorkspaceInstructionsPresentation.target(
                projectID: nil, cwd: " \n ", projects: projects),
            "Only exact empty cwd is Home identity")
    }

    func testWorkspaceManagementPresentationDistinguishesHomeTopicFolderAndDangling() {
        let topic = Project(name: "Research")
        let folder = Project(name: "Code", cwd: "/private/tmp/code-\(UUID().uuidString)")
        let projects = [topic, folder]

        XCTAssertEqual(
            WorkspaceManagementPresentation.folderActionTitle(
                projectID: nil, cwd: "", projects: projects),
            "Open Folder as Workspace…")
        XCTAssertEqual(
            WorkspaceManagementPresentation.folderActionTitle(
                projectID: topic.id, cwd: "", projects: projects),
            "Add Folder…")
        XCTAssertEqual(
            WorkspaceManagementPresentation.folderActionTitle(
                projectID: nil, cwd: folder.cwd, projects: projects),
            "Change Folder…")
        XCTAssertEqual(
            WorkspaceManagementPresentation.folderPath(
                projectID: nil, cwd: folder.cwd, projects: projects),
            folder.cwd)
        XCTAssertNil(
            WorkspaceManagementPresentation.folderActionTitle(
                projectID: UUID(), cwd: "", projects: projects))
        XCTAssertNil(
            WorkspaceManagementPresentation.folderActionTitle(
                projectID: nil, cwd: "/missing", projects: projects))
    }

    func testInspectingRepositoryInstructionFilesDoesNotCreateThem() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        for file in RepositoryInstructionFile.allCases {
            let status = RepositoryInstructionFileOperations.status(of: file, in: root.path)
            guard case .missing(let url) = status else {
                return XCTFail("Expected \(file.rawValue) to be missing, got \(status)")
            }
            XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        }
    }

    func testExplicitCreateMakesOnlyTheSelectedPlainRootFile() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let contents = Data("# Repository guidance\n".utf8)
        let created = try RepositoryInstructionFileOperations.create(
            .claude, in: root.path, contents: contents)

        XCTAssertEqual(
            created.deletingLastPathComponent().standardizedFileURL,
            root.standardizedFileURL)
        XCTAssertEqual(created.lastPathComponent, "CLAUDE.md")
        XCTAssertEqual(try Data(contentsOf: created), contents)
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: root.appendingPathComponent("AGENTS.md").path))
        guard case .regularFile(let statusURL) =
                RepositoryInstructionFileOperations.status(of: .claude, in: root.path) else {
            return XCTFail("The created file must be reported as a regular file")
        }
        XCTAssertEqual(statusURL, created)
    }

    func testCreateRefusesToOverwriteExistingFile() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let original = Data("keep this".utf8)
        let url = root.appendingPathComponent("AGENTS.md")
        try original.write(to: url)

        XCTAssertThrowsError(
            try RepositoryInstructionFileOperations.create(
                .agents, in: root.path, contents: Data("replacement".utf8))
        ) { error in
            XCTAssertEqual(
                error as? RepositoryInstructionFileOperations.CreationError,
                .alreadyExists("AGENTS.md"))
        }
        XCTAssertEqual(try Data(contentsOf: url), original)
    }

    func testCreateRefusesToReplaceSymlink() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let destination = root.appendingPathComponent("outside.md")
        try Data("outside".utf8).write(to: destination)
        let link = root.appendingPathComponent("CLAUDE.md")
        try FileManager.default.createSymbolicLink(
            at: link, withDestinationURL: destination)

        guard case .unsupported(_, let detail) =
                RepositoryInstructionFileOperations.status(of: .claude, in: root.path) else {
            return XCTFail("A symlink must not be treated as an editable regular file")
        }
        XCTAssertTrue(detail.contains("Symbolic link"))
        XCTAssertThrowsError(
            try RepositoryInstructionFileOperations.create(.claude, in: root.path)
        ) { error in
            XCTAssertEqual(
                error as? RepositoryInstructionFileOperations.CreationError,
                .alreadyExists("CLAUDE.md"))
        }
        XCTAssertEqual(try String(contentsOf: destination, encoding: .utf8), "outside")
    }

    func testDedicatedToolbarWorkspaceActionsAreDiscoverableAndRouteEveryWorkspaceKind() {
        _ = NSApplication.shared
        let topic = Project(name: "Instructions \(UUID().uuidString)")
        let folder = Project(
            name: "Folder \(UUID().uuidString)",
            cwd: "/private/tmp/workspace-actions-\(UUID().uuidString)")
        ProjectStore.shared.upsert(topic)
        ProjectStore.shared.upsert(folder)
        let support = FileManager.default.temporaryDirectory
            .appendingPathComponent("workspace-instructions-toolbar-\(UUID().uuidString)")
        let bridge = AgentBridge(settingsBaseOverride: support, environmentOverride: [:])
        let split = NSSplitViewController()
        split.addSplitViewItem(NSSplitViewItem(viewController: NSViewController()))
        split.addSplitViewItem(NSSplitViewItem(viewController: NSViewController()))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 640),
            styleMask: [.titled], backing: .buffered, defer: false)
        let controller = WorkspaceToolbarController(
            bridge: bridge, splitVC: split, window: window)
        let toolbar = controller.makeToolbar()
        let identifier = NSToolbarItem.Identifier("workspace.actions")
        defer {
            controller.invalidate()
            bridge.shutdown()
            ProjectStore.shared.remove(topic.id)
            ProjectStore.shared.remove(folder.id)
            ProjectStore.shared.flushSaves()
            try? FileManager.default.removeItem(at: support)
            withExtendedLifetime((controller, bridge, split, window)) {}
        }

        let defaultItems = controller.toolbarDefaultItemIdentifiers(toolbar)
        guard let switcherIndex = defaultItems.firstIndex(
            of: NSToolbarItem.Identifier("workspace.folderMenu")),
              let actionsIndex = defaultItems.firstIndex(of: identifier) else {
            return XCTFail("Workspace switcher and actions must both be default toolbar items")
        }
        XCTAssertEqual(actionsIndex, switcherIndex + 1)
        guard let item = controller.toolbar(
            toolbar,
            itemForItemIdentifier: identifier,
            willBeInsertedIntoToolbar: true
        ) as? NSMenuToolbarItem else {
            return XCTFail("The default toolbar must include a workspace actions menu")
        }
        let menu = item.menu
        XCTAssertEqual(item.paletteLabel, "Workspace Actions")
        XCTAssertTrue(item.toolTip?.contains("instructions") == true)
        XCTAssertEqual(
            item.image?.accessibilityDescription,
            "Workspace actions for Home")
        XCTAssertTrue(menu is WorkspaceActionsMenu)

        controller.menuNeedsUpdate(menu)
        assertInstructionsImmediatelyPrecede(
            WorkspaceManagementPresentation.homeFolderActionTitle,
            in: menu)
        XCTAssertFalse(menu.items.contains {
            $0.title == WorkspaceManagementPresentation.revealFolderActionTitle
                || $0.title == WorkspaceManagementPresentation.editWorkspaceActionTitle
        })
        activateInstructionsItem(in: menu)
        XCTAssertEqual(bridge.workspaceInstructionsEditorTarget, .home)

        bridge.workspaceInstructionsEditorTarget = nil
        bridge.projectID = topic.id
        bridge.cwd = ""
        controller.menuNeedsUpdate(menu)
        assertInstructionsImmediatelyPrecede("Add Folder…", in: menu)
        XCTAssertTrue(menu.items.contains {
            $0.title == WorkspaceManagementPresentation.editWorkspaceActionTitle
        })
        XCTAssertFalse(menu.items.contains {
            $0.title == WorkspaceManagementPresentation.revealFolderActionTitle
        })
        activateInstructionsItem(in: menu)
        XCTAssertEqual(bridge.workspaceInstructionsEditorTarget, .project(topic.id))

        bridge.workspaceInstructionsEditorTarget = nil
        bridge.projectID = nil
        bridge.cwd = folder.cwd
        controller.menuNeedsUpdate(menu)
        assertInstructionsImmediatelyPrecede("Change Folder…", in: menu)
        XCTAssertTrue(menu.items.contains {
            $0.title == WorkspaceManagementPresentation.revealFolderActionTitle
        })
        XCTAssertTrue(menu.items.contains {
            $0.title == WorkspaceManagementPresentation.editWorkspaceActionTitle
        })
        activateInstructionsItem(in: menu)
        XCTAssertEqual(bridge.workspaceInstructionsEditorTarget, .project(folder.id))

        bridge.workspaceInstructionsEditorTarget = nil
        bridge.projectID = UUID()
        bridge.cwd = ""
        controller.menuNeedsUpdate(menu)
        let unresolved = menu.items.first {
            $0.title == WorkspaceInstructionsPresentation.actionTitle
        }
        XCTAssertEqual(unresolved?.isEnabled, false)
        XCTAssertFalse(bridge.presentWorkspaceInstructions())
        XCTAssertNil(bridge.workspaceInstructionsEditorTarget)
    }

    private func assertInstructionsImmediatelyPrecede(
        _ folderAction: String,
        in menu: NSMenu,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let titles = menu.items.map(\.title)
        guard let instructions = titles.firstIndex(
            of: WorkspaceInstructionsPresentation.actionTitle),
              let folder = titles.firstIndex(of: folderAction) else {
            return XCTFail(
                "Workspace management menu is missing its paired actions",
                file: file,
                line: line)
        }
        XCTAssertEqual(folder, instructions + 1, file: file, line: line)
    }

    private func activateInstructionsItem(in menu: NSMenu) {
        guard let item = menu.items.first(where: {
            $0.title == WorkspaceInstructionsPresentation.actionTitle
        }), let action = item.action else {
            return XCTFail("Workspace menu is missing the shared instructions action")
        }
        XCTAssertTrue(item.isEnabled)
        XCTAssertTrue(NSApp.sendAction(action, to: item.target, from: item))
    }

    private func makeTemporaryDirectory() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "mechanician-workspace-instructions-\(UUID().uuidString)",
                isDirectory: true)
        try FileManager.default.createDirectory(
            at: root, withIntermediateDirectories: true)
        return root
    }
}
