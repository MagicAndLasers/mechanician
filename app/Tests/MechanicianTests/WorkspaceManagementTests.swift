import AppKit
import SwiftUI
import XCTest
@testable import Mechanician

@MainActor
final class WorkspaceManagementTests: XCTestCase {
    func testFolderReassignmentRebasesOnlyWindowsStillDisplayingTheSourceWorkspace() {
        let projectID = UUID()
        let memberID = UUID()
        let topicWindowID = UUID()
        let folderWindowID = UUID()
        let memberWindowID = UUID()
        let foreignHolderWindowID = UUID()
        let closedWindowID = UUID()
        let snapshots = [
            WorkspaceAdoptionLiveBridgeSnapshot(
                bridgeID: topicWindowID, hasWindow: true, currentConversationID: nil,
                projectID: projectID, cwd: ""),
            WorkspaceAdoptionLiveBridgeSnapshot(
                bridgeID: folderWindowID, hasWindow: true, currentConversationID: nil,
                projectID: nil, cwd: "/source"),
            WorkspaceAdoptionLiveBridgeSnapshot(
                bridgeID: memberWindowID, hasWindow: true, currentConversationID: memberID,
                projectID: nil, cwd: "/source"),
            WorkspaceAdoptionLiveBridgeSnapshot(
                bridgeID: foreignHolderWindowID, hasWindow: true,
                currentConversationID: UUID(), projectID: nil, cwd: "/foreign"),
            WorkspaceAdoptionLiveBridgeSnapshot(
                bridgeID: closedWindowID, hasWindow: false, currentConversationID: memberID,
                projectID: nil, cwd: "/source"),
        ]

        XCTAssertEqual(
            workspaceFolderSourceBridgeIDs(
                projectID: projectID,
                previousCwd: "/source",
                memberConversationIDs: [memberID],
                bridges: snapshots),
            [topicWindowID, folderWindowID, memberWindowID])
    }

    func testAsyncWorkspaceRoutingRejectsAClosedOriginBridge() {
        _ = NSApplication.shared
        let origin = AgentBridge(
            settingsBaseOverride: FileManager.default.temporaryDirectory
                .appendingPathComponent("launcher-closed-origin-\(UUID().uuidString)"),
            environmentOverride: [:])
        let window = NSWindow()
        window.isReleasedWhenClosed = false
        origin.window = window
        AgentBridge.live.add(origin)
        defer {
            AgentBridge.live.remove(origin)
            origin.window = nil
            origin.shutdown()
            window.close()
            withExtendedLifetime((origin, window)) {}
        }

        XCTAssertTrue(liveWorkspaceBridge(origin.bridgeID) === origin)
        origin.window = nil
        XCTAssertNil(
            liveWorkspaceBridge(origin.bridgeID),
            "a late completion must open a live destination instead of routing into a closed bridge")
    }

    func testWorkspaceHostingDoesNotExportDynamicContentBounds() {
        let controller = makeWorkspaceHostingController(rootView: EmptyView())
        XCTAssertTrue(controller.sizingOptions.isEmpty)
    }

    func testEnteringWorkspacePrimesItsSelectedCatalogBeforeEitherPickerOpens() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("mechanician-catalog-prime-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let project = Project(name: "Vertex-shaped workspace", cwd: folder.path)
        let selection = ModelSelection(access: .claudeSubscription, modelID: "")
        let conversation = Conversation(
            title: "New conversation", cwd: folder.path, sdkSessionId: nil,
            modelSelection: selection, messages: [], updatedAt: Date(), projectID: project.id)
        ProjectStore.shared.upsert(project)
        ConversationStore.shared.upsert(conversation)
        let bridge = AgentBridge(settingsBaseOverride: FileManager.default.temporaryDirectory
            .appendingPathComponent("catalog-prime-settings-\(UUID().uuidString)"), environmentOverride: [:])
        defer {
            bridge.shutdown()
            ConversationStore.shared.remove(conversation.id, permanently: true)
            ProjectStore.shared.remove(project.id)
            ConversationStore.shared.flushSaves()
            ProjectStore.shared.flushSaves()
            try? FileManager.default.removeItem(at: folder)
        }

        bridge.enterWorkspace(project)

        XCTAssertEqual(bridge.currentID, conversation.id)
        XCTAssertEqual(
            ModelCatalogStore.shared.snapshot(
                for: selection.access, scope: folder.path).phase,
            .loading)
    }

    func testStartingWorkspaceQueuesItsSelectedCatalogBeforeRuntimeReadiness() throws {
        let defaultAccessKey = "providerAccounts.defaultConversationAccess.v1"
        let defaults = UserDefaults.standard
        let priorDefaultAccess = defaults.object(forKey: defaultAccessKey)
        defaults.set(ModelAccess.claudeSubscription.rawValue, forKey: defaultAccessKey)
        defer {
            if let priorDefaultAccess {
                defaults.set(priorDefaultAccess, forKey: defaultAccessKey)
            } else {
                defaults.removeObject(forKey: defaultAccessKey)
            }
        }
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("mechanician-startup-catalog-\(UUID().uuidString)", isDirectory: true)
        let support = root.appendingPathComponent("support", isDirectory: true)
        let folder = root.appendingPathComponent("workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let settings = try JSONSerialization.data(withJSONObject: [
            "provider": "anthropic",
            "authMode": "subscription",
            "model": "claude-opus-4-8",
            "effort": "high",
        ])
        try settings.write(to: support.appendingPathComponent("settings.json"), options: .atomic)
        let project = Project(name: "Startup catalog", cwd: folder.path)
        ProjectStore.shared.upsert(project)
        let bridge = AgentBridge(initialFolder: folder.path, settingsBaseOverride: support, environmentOverride: [:])
        defer {
            bridge.shutdown()
            ProjectStore.shared.remove(project.id)
            ProjectStore.shared.flushSaves()
            try? FileManager.default.removeItem(at: root)
        }

        bridge.start()

        let selectedAccess = bridge.currentModelAccess
        XCTAssertEqual(
            ModelCatalogStore.shared.snapshot(
                for: selectedAccess, scope: bridge.catalogScope(for: selectedAccess)).phase,
            .loading)
    }

    func testConversationOwnerPreventsIdleDuplicateSelection() {
        _ = NSApplication.shared
        let conversation = Conversation(
            title: "Single owner", cwd: "", sdkSessionId: nil, messages: [], updatedAt: Date())
        ConversationStore.shared.upsert(conversation)

        let first = AgentBridge(settingsBaseOverride: FileManager.default.temporaryDirectory
            .appendingPathComponent("owner-a-\(UUID().uuidString)"), environmentOverride: [:])
        let second = AgentBridge(settingsBaseOverride: FileManager.default.temporaryDirectory
            .appendingPathComponent("owner-b-\(UUID().uuidString)"), environmentOverride: [:])
        let firstWindow = NSWindow()
        let secondWindow = NSWindow()
        firstWindow.isReleasedWhenClosed = false
        secondWindow.isReleasedWhenClosed = false
        first.window = firstWindow
        second.window = secondWindow
        first.currentID = conversation.id
        AgentBridge.live.add(first)
        AgentBridge.live.add(second)
        defer {
            AgentBridge.live.remove(first)
            AgentBridge.live.remove(second)
            first.window = nil
            second.window = nil
            first.shutdown()
            second.shutdown()
            ConversationStore.shared.remove(conversation.id, permanently: true)
            ConversationStore.shared.flushSaves()
            firstWindow.close()
            secondWindow.close()
            withExtendedLifetime((first, second, firstWindow, secondWindow)) {}
        }

        second.select(conversation.id)

        XCTAssertEqual(first.currentID, conversation.id)
        XCTAssertNil(second.currentID)
        XCTAssertTrue(AgentBridge.owner(of: conversation.id) === first)
    }

    func testLauncherRoutesToExistingWorkspaceBridgeThenRevealsMovedConversationThere() {
        _ = NSApplication.shared
        let project = Project(name: "Existing destination")
        let moved = Conversation(
            title: "Reveal this conversation",
            cwd: "",
            sdkSessionId: nil,
            messages: [],
            updatedAt: Date(),
            projectID: project.id)
        ProjectStore.shared.upsert(project)
        ConversationStore.shared.upsert(moved)

        let origin = AgentBridge(
            settingsBaseOverride: FileManager.default.temporaryDirectory
                .appendingPathComponent("launcher-existing-origin-\(UUID().uuidString)"),
            environmentOverride: [:])
        let destination = AgentBridge(
            settingsBaseOverride: FileManager.default.temporaryDirectory
                .appendingPathComponent("launcher-existing-destination-\(UUID().uuidString)"),
            environmentOverride: [:])
        destination.projectID = project.id
        let originWindow = NSWindow()
        let destinationWindow = NSWindow()
        originWindow.isReleasedWhenClosed = false
        destinationWindow.isReleasedWhenClosed = false
        origin.window = originWindow
        destination.window = destinationWindow
        AgentBridge.live.add(origin)
        AgentBridge.live.add(destination)
        defer {
            AgentBridge.live.remove(origin)
            AgentBridge.live.remove(destination)
            origin.window = nil
            destination.window = nil
            origin.shutdown()
            destination.shutdown()
            ConversationStore.shared.remove(moved.id, permanently: true)
            ProjectStore.shared.remove(project.id)
            ConversationStore.shared.flushSaves()
            ProjectStore.shared.flushSaves()
            originWindow.close()
            destinationWindow.close()
            withExtendedLifetime((origin, destination, originWindow, destinationWindow)) {}
        }

        let routed = routeToWorkspaceProject(project, replacing: origin)

        XCTAssertTrue(routed === destination)
        XCTAssertNil(origin.projectID)
        var revealResult: WorkspaceConversationRevealResult?
        revealWorkspaceConversation(
            moved.id,
            in: .project(project),
            on: routed) { revealResult = $0 }
        XCTAssertEqual(revealResult, .selectedDestination)
        XCTAssertEqual(destination.currentID, moved.id)
        XCTAssertTrue(AgentBridge.owner(of: moved.id) === destination)
    }

    func testLauncherRoutesInPlaceThenRevealsExactMovedConversation() {
        _ = NSApplication.shared
        let project = Project(name: "In-place destination")
        let moved = Conversation(
            title: "Moved conversation",
            cwd: "",
            sdkSessionId: nil,
            messages: [],
            updatedAt: Date().addingTimeInterval(-60),
            projectID: project.id)
        let newer = Conversation(
            title: "Newer destination conversation",
            cwd: "",
            sdkSessionId: nil,
            messages: [],
            updatedAt: Date(),
            projectID: project.id)
        ProjectStore.shared.upsert(project)
        ConversationStore.shared.upsert(moved)
        ConversationStore.shared.upsert(newer)

        let origin = AgentBridge(
            settingsBaseOverride: FileManager.default.temporaryDirectory
                .appendingPathComponent("launcher-in-place-origin-\(UUID().uuidString)"),
            environmentOverride: [:])
        let originWindow = NSWindow()
        originWindow.isReleasedWhenClosed = false
        origin.window = originWindow
        AgentBridge.live.add(origin)
        defer {
            AgentBridge.live.remove(origin)
            origin.window = nil
            origin.shutdown()
            ConversationStore.shared.remove(moved.id, permanently: true)
            ConversationStore.shared.remove(newer.id, permanently: true)
            ProjectStore.shared.remove(project.id)
            ConversationStore.shared.flushSaves()
            ProjectStore.shared.flushSaves()
            originWindow.close()
            withExtendedLifetime((origin, originWindow)) {}
        }

        let routed = routeToWorkspaceProject(project, replacing: origin)
        XCTAssertTrue(routed === origin)
        XCTAssertEqual(origin.projectID, project.id)
        XCTAssertEqual(
            origin.currentID,
            newer.id,
            "enterWorkspace chooses its normal most-recent destination before the explicit reveal")

        var revealResult: WorkspaceConversationRevealResult?
        revealWorkspaceConversation(
            moved.id,
            in: .project(project),
            on: routed) { revealResult = $0 }
        XCTAssertEqual(revealResult, .selectedDestination)
        XCTAssertEqual(origin.currentID, moved.id)
        XCTAssertTrue(AgentBridge.owner(of: moved.id) === origin)
    }

    func testConversationRevealFocusesExistingOwnerInsteadOfDuplicatingSelection() {
        _ = NSApplication.shared
        let project = Project(name: "Ownership destination")
        let moved = Conversation(
            title: "Already owned",
            cwd: "",
            sdkSessionId: nil,
            messages: [],
            updatedAt: Date(),
            projectID: project.id)
        ProjectStore.shared.upsert(project)
        ConversationStore.shared.upsert(moved)

        let owner = AgentBridge(
            settingsBaseOverride: FileManager.default.temporaryDirectory
                .appendingPathComponent("launcher-reveal-owner-\(UUID().uuidString)"),
            environmentOverride: [:])
        let destination = AgentBridge(
            settingsBaseOverride: FileManager.default.temporaryDirectory
                .appendingPathComponent("launcher-reveal-destination-\(UUID().uuidString)"),
            environmentOverride: [:])
        owner.projectID = project.id
        owner.currentID = moved.id
        destination.projectID = project.id
        let ownerWindow = NSWindow()
        let destinationWindow = NSWindow()
        ownerWindow.isReleasedWhenClosed = false
        destinationWindow.isReleasedWhenClosed = false
        owner.window = ownerWindow
        destination.window = destinationWindow
        AgentBridge.live.add(owner)
        AgentBridge.live.add(destination)
        defer {
            AgentBridge.live.remove(owner)
            AgentBridge.live.remove(destination)
            owner.window = nil
            destination.window = nil
            owner.shutdown()
            destination.shutdown()
            ConversationStore.shared.remove(moved.id, permanently: true)
            ProjectStore.shared.remove(project.id)
            ConversationStore.shared.flushSaves()
            ProjectStore.shared.flushSaves()
            ownerWindow.close()
            destinationWindow.close()
            withExtendedLifetime((owner, destination, ownerWindow, destinationWindow)) {}
        }

        var revealResult: WorkspaceConversationRevealResult?
        revealWorkspaceConversation(
            moved.id,
            in: .project(project),
            on: destination) { revealResult = $0 }
        XCTAssertEqual(revealResult, .focusedExistingOwner)
        XCTAssertEqual(owner.currentID, moved.id)
        XCTAssertNil(destination.currentID)
        XCTAssertTrue(AgentBridge.owner(of: moved.id) === owner)
    }

    func testFolderActionNamesAttachmentAndReplacementHonestly() {
        XCTAssertEqual(
            WorkspaceFolderAssignment.actionTitle(for: Project(name: "Planning")),
            "Add Folder…")
        XCTAssertEqual(
            WorkspaceFolderAssignment.actionTitle(
                for: Project(name: "Code", cwd: "/private/tmp/code")),
            "Change Folder…")
    }

    func testWorkspacePickerKeepsNavigationSeparateFromCurrentWorkspaceManagement() {
        _ = NSApplication.shared
        let project = Project(name: "Planning")
        ProjectStore.shared.upsert(project)
        defer {
            ProjectStore.shared.remove(project.id)
            ProjectStore.shared.flushSaves()
        }

        let support = FileManager.default.temporaryDirectory
            .appendingPathComponent("mechanician-workspace-menu-\(UUID().uuidString)", isDirectory: true)
        let bridge = AgentBridge(settingsBaseOverride: support, environmentOverride: [:])
        bridge.projectID = project.id
        let split = NSSplitViewController()
        split.addSplitViewItem(NSSplitViewItem(viewController: NSViewController()))
        split.addSplitViewItem(NSSplitViewItem(viewController: NSViewController()))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 640),
            styleMask: [.titled], backing: .buffered, defer: false)
        let controller = WorkspaceToolbarController(bridge: bridge, splitVC: split, window: window)
        let menu = NSMenu()

        controller.menuNeedsUpdate(menu)

        let titles = menu.items.map(\.title)
        XCTAssertTrue(titles.contains("New Workspace…"))
        XCTAssertTrue(titles.contains("All Workspaces…"))
        XCTAssertFalse(titles.contains(WorkspaceInstructionsPresentation.actionTitle))
        XCTAssertFalse(titles.contains("Add Folder…"))
        XCTAssertFalse(titles.contains(
            WorkspaceManagementPresentation.editWorkspaceActionTitle))
        menu.removeAllItems()
        controller.invalidate()
        withExtendedLifetime((controller, window, bridge, split)) {}
    }

    func testWorkspaceWindowTitleUsesProjectNameAndTabUsesConversationName() {
        _ = NSApplication.shared
        let path = "/private/tmp/mechanician-window-title-\(UUID().uuidString)"
        let project = Project(name: "Release Desk", cwd: path)
        let conversation = Conversation(
            title: "Investigate Ultra toggle", cwd: path, sdkSessionId: nil, messages: [],
            updatedAt: Date(), projectID: project.id)
        ProjectStore.shared.upsert(project)
        ConversationStore.shared.upsert(conversation)
        defer { remove(project: project.id, conversation: conversation.id) }

        let support = FileManager.default.temporaryDirectory
            .appendingPathComponent("mechanician-workspace-title-\(UUID().uuidString)", isDirectory: true)
        let bridge = AgentBridge(settingsBaseOverride: support, environmentOverride: [:])
        bridge.cwd = path
        bridge.projectID = nil
        bridge.currentID = conversation.id
        let split = NSSplitViewController()
        split.addSplitViewItem(NSSplitViewItem(viewController: NSViewController()))
        split.addSplitViewItem(NSSplitViewItem(viewController: NSViewController()))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 640),
            styleMask: [.titled], backing: .buffered, defer: false)
        let controller = WorkspaceToolbarController(bridge: bridge, splitVC: split, window: window)
        window.toolbar = controller.makeToolbar()

        XCTAssertEqual(window.title, "Release Desk")
        XCTAssertEqual(window.tab.title, "Investigate Ultra toggle")

        ConversationStore.shared.update(conversation.id) { $0.title = "Ship tab naming" }
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))

        XCTAssertEqual(window.title, "Release Desk")
        XCTAssertEqual(window.tab.title, "Ship tab naming")

        controller.invalidate()
        withExtendedLifetime((controller, window, bridge, split)) {}
    }

    func testTopicWorkspaceCanGainFolderAndRekeysItsConversations() {
        let project = Project(name: "Research")
        let conversation = Conversation(
            title: "Notes", cwd: "", sdkSessionId: nil, messages: [], updatedAt: Date(),
            projectID: project.id)
        let path = "/private/tmp/mechanician-workspace-\(UUID().uuidString)"
        ProjectStore.shared.upsert(project)
        ConversationStore.shared.upsert(conversation)
        defer { remove(project: project.id, conversation: conversation.id) }

        XCTAssertEqual(ProjectStore.shared.setCwd(project.id, to: path), .ok)
        XCTAssertEqual(ProjectStore.shared.project(project.id)?.cwd, path)
        XCTAssertEqual(ConversationStore.shared.conversation(conversation.id)?.cwd, path)
        XCTAssertEqual(ConversationStore.shared.conversation(conversation.id)?.projectID, project.id)
    }

    func testFolderCollisionLeavesTopicWorkspaceAndConversationUnchanged() {
        let path = "/private/tmp/mechanician-owned-\(UUID().uuidString)"
        let topic = Project(name: "Research")
        let owner = Project(name: "Code", cwd: path)
        let conversation = Conversation(
            title: "Notes", cwd: "", sdkSessionId: nil, messages: [], updatedAt: Date(),
            projectID: topic.id)
        ProjectStore.shared.upsert(topic)
        ProjectStore.shared.upsert(owner)
        ConversationStore.shared.upsert(conversation)
        defer {
            ProjectStore.shared.remove(owner.id)
            remove(project: topic.id, conversation: conversation.id)
        }

        XCTAssertEqual(ProjectStore.shared.setCwd(topic.id, to: path), .collision("Code"))
        XCTAssertEqual(ProjectStore.shared.project(topic.id)?.cwd, "")
        XCTAssertEqual(ConversationStore.shared.conversation(conversation.id)?.cwd, "")
    }

    func testWorkspaceClaudeInstructionsAreBoundedAndRejectSymlinks() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("mechanician-instructions-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let instructions = root.appendingPathComponent("CLAUDE.md")
        try "  Keep releases reproducible.  \n".write(to: instructions, atomically: true, encoding: .utf8)

        XCTAssertEqual(
            AgentBridge.folderClaudeInstructions(at: root.path),
            "Keep releases reproducible.")
        XCTAssertNil(AgentBridge.folderClaudeInstructions(at: root.path, maximumBytes: 4))

        try FileManager.default.removeItem(at: instructions)
        let target = root.appendingPathComponent("outside.md")
        try "untrusted".write(to: target, atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(at: instructions, withDestinationURL: target)
        XCTAssertNil(AgentBridge.folderClaudeInstructions(at: root.path))
    }

    private func remove(project: UUID, conversation: UUID) {
        ConversationStore.shared.remove(conversation, permanently: true)
        ProjectStore.shared.remove(project)
        ConversationStore.shared.flushSaves()
        ProjectStore.shared.flushSaves()
    }
}
