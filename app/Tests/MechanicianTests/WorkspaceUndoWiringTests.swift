import AppKit
import XCTest
@testable import Mechanician

/// The wiring between a move and the Edit menu, assembled from the real objects.
///
/// Live testing showed a move registering successfully while Edit ▸ Undo stayed disabled, and the
/// UI could not be driven reliably enough to find out why. This builds the same chain headlessly:
/// bridge → window → `WorkspaceToolbarController` → undo manager, and asserts each link, so the
/// break has to show up as a specific failing assertion rather than a guess.
@MainActor
final class WorkspaceUndoWiringTests: XCTestCase {
    private var support: URL!
    private var store: ConversationStore!
    private var artifacts: ArtifactStore!

    override func setUp() async throws {
        try await super.setUp()
        _ = NSApplication.shared
        support = FileManager.default.temporaryDirectory
            .appendingPathComponent("undo-wiring-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        store = ConversationStore(appSupportBaseOverride: support, watchesDirectory: false)
        artifacts = ArtifactStore(appSupportBaseOverride: support, watchesDirectory: false)
    }

    override func tearDown() async throws {
        if let support { try? FileManager.default.removeItem(at: support) }
        try await super.tearDown()
    }

    /// Builds a workspace-shaped window: a bridge, a real controller as the window delegate, and the
    /// bridge pointing back at the window, exactly as `makeWorkspaceWindow` arranges it.
    private func makeWorkspace() -> (AgentBridge, WorkspaceWindow, WorkspaceToolbarController) {
        let bridge = AgentBridge(
            settingsBaseOverride: support.appendingPathComponent("bridge", isDirectory: true),
            environmentOverride: [:])
        let window = WorkspaceWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.titled], backing: .buffered, defer: false)
        let splitVC = NSSplitViewController()
        let controller = WorkspaceToolbarController(
            bridge: bridge, splitVC: splitVC, window: window)
        window.delegate = controller
        bridge.window = window
        return (bridge, window, controller)
    }

    /// Link 1: the resolver a move uses finds the controller's stack.
    func testTheResolverFindsTheControllersStack() {
        let (bridge, _, controller) = makeWorkspace()
        XCTAssertTrue(
            workspaceUndoManager(for: bridge) === controller.workspaceUndoManager,
            "a move registers on whatever this returns")
    }

    /// Link 2: the stack the menu validates against is the SAME object.
    ///
    /// These two resolve through different conditions — the resolver casts the window's delegate,
    /// while `windowWillReturnUndoManager` additionally requires window identity — so this asserts
    /// they cannot drift apart.
    func testTheMenuResolvesTheSameStackAsTheResolver() {
        let (bridge, window, controller) = makeWorkspace()
        let fromMenuPath = window.delegate?.windowWillReturnUndoManager?(window)
        XCTAssertNotNil(fromMenuPath, "the delegate must vend a manager for its own window")
        XCTAssertTrue(
            fromMenuPath === workspaceUndoManager(for: bridge),
            "the menu validates a different stack than the move registers on")
        XCTAssertTrue(fromMenuPath === controller.workspaceUndoManager)
    }

    /// The whole chain: a real move through the real resolver leaves the menu's stack undoable.
    /// This is the assertion the live check was trying to make.
    func testAMoveLeavesTheMenusStackUndoable() throws {
        let (bridge, window, _) = makeWorkspace()

        var conversation = Conversation(
            id: UUID(), title: "Move me", cwd: "/tmp/source",
            sdkSessionId: nil, messages: [], updatedAt: Date())
        conversation.projectID = nil
        store.upsert(conversation)

        let result = WorkspaceAdoption.adopt(
            conversations: [conversation.id],
            into: .project(Project(name: "Destination", cwd: "/tmp/destination")),
            conversations: store,
            artifactStore: artifacts,
            synchronizeLiveState: false,
            undoManager: workspaceUndoManager(for: bridge))
        XCTAssertTrue(result.succeeded)

        let menuStack = try XCTUnwrap(window.delegate?.windowWillReturnUndoManager?(window))
        XCTAssertTrue(
            menuStack.canUndo,
            "the move registered somewhere the Edit menu cannot see")
        XCTAssertTrue(menuStack.undoMenuItemTitle.contains(WorkspaceMoveUndo.actionName(conversations: 1)))
    }

    /// And the composer's hand-off resolves to that same stack, which is what makes ⌘Z reach it
    /// while the composer is focused — which it is, nearly always, in this app.
    func testTheComposerHandsOffToTheSameStack() throws {
        let (bridge, window, _) = makeWorkspace()
        let composer = ComposerTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 100))
        composer.allowsUndo = true
        _ = composer.layoutManager
        window.contentView?.addSubview(composer)
        window.makeFirstResponder(composer)

        var conversation = Conversation(
            id: UUID(), title: "Move me", cwd: "/tmp/source",
            sdkSessionId: nil, messages: [], updatedAt: Date())
        store.upsert(conversation)
        _ = WorkspaceAdoption.adopt(
            conversations: [conversation.id],
            into: .project(Project(name: "Destination", cwd: "/tmp/destination")),
            conversations: store,
            artifactStore: artifacts,
            synchronizeLiveState: false,
            undoManager: workspaceUndoManager(for: bridge))

        let item = NSMenuItem(
            title: "Undo", action: #selector(WorkspaceWindow.undo(_:)), keyEquivalent: "z")
        XCTAssertTrue(
            window.validateMenuItem(item),
            "with an empty composer the item must enable from the workspace stack")
        XCTAssertTrue(item.title.contains(WorkspaceMoveUndo.actionName(conversations: 1)))
    }

    /// The same move with live-state synchronization ON, which is what the real app runs and what
    /// the earlier tests deliberately skipped. The handoff selects the moved conversation and
    /// reassigns bridges; if any of that disturbs the stack, this is where it shows.
    func testTheStackSurvivesLiveStateSynchronization() throws {
        let (bridge, window, _) = makeWorkspace()

        var conversation = Conversation(
            id: UUID(), title: "Move me", cwd: "/tmp/source",
            sdkSessionId: nil, messages: [], updatedAt: Date())
        store.upsert(conversation)

        let result = WorkspaceAdoption.adopt(
            conversations: [conversation.id],
            into: .project(Project(name: "Destination", cwd: "/tmp/destination")),
            conversations: store,
            artifactStore: artifacts,
            synchronizeLiveState: true,
            receivingBridge: bridge,
            undoManager: workspaceUndoManager(for: bridge))
        XCTAssertTrue(result.succeeded, "the move must still land with live sync on")

        let menuStack = try XCTUnwrap(window.delegate?.windowWillReturnUndoManager?(window))
        XCTAssertTrue(
            menuStack.canUndo,
            "live-state synchronization lost the undo registration")
    }

    /// Moving an artifact is something you do *from* the Artifacts window, which is a plain utility
    /// window with no routing of its own. Sending `undo:` into its responder chain reaches NSWindow,
    /// which acts on an undo manager nothing registers on — so the action would be visible and its
    /// undo unreachable. A non-workspace key window falls back to the active workspace's stack.
    func testAUtilityWindowFallsBackToTheActiveWorkspacesStack() throws {
        let (bridge, _, controller) = makeWorkspace()
        let utility = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 200),
            styleMask: [.titled], backing: .buffered, defer: false)

        var undone = false
        controller.workspaceUndoManager.registerUndo(withTarget: self) { _ in undone = true }

        performWorkspaceUndo(keyWindow: utility, activeBridge: bridge)

        XCTAssertTrue(undone, "an artifact moved from the Artifacts window must still be undoable")
    }

    /// And a workspace window keeps deciding for itself, so the fallback cannot quietly take over
    /// the composer-versus-library rule.
    func testAWorkspaceWindowStillRoutesItsOwnUndo() throws {
        let (bridge, window, controller) = makeWorkspace()
        let composer = ComposerTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 100))
        composer.allowsUndo = true
        _ = composer.layoutManager
        window.contentView?.addSubview(composer)
        window.makeFirstResponder(composer)

        var libraryUndone = false
        controller.workspaceUndoManager.registerUndo(withTarget: self) { _ in libraryUndone = true }
        composer.insertText("hello", replacementRange: NSRange(location: 0, length: 0))

        performWorkspaceUndo(keyWindow: window, activeBridge: bridge)

        XCTAssertEqual(composer.string, "", "the composer had typing, so it wins")
        XCTAssertFalse(libraryUndone, "and the library stack is untouched")
    }
}
