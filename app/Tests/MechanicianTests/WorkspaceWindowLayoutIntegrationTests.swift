import AppKit
import XCTest
@testable import Mechanician

/// The AppKit seam around the otherwise-value-based workspace layout ledger.
///
/// `WorkspaceSessionLedgerTests` pins the Codable contract. These tests pin the two integration
/// edges that contract cannot see: a bridge must expose its restored state before any hosted view
/// starts observing it, and the native split/window shell must both apply and recapture that state.
@MainActor
final class WorkspaceWindowLayoutIntegrationTests: XCTestCase {
    private static let legacyDefaultsKeys = [
        "panel.sidebar",
        "panel.inspector",
        "panel.terminal",
        "terminalHeight",
    ]

    func testSidebarWidthAccountsForArrangedContainerOverhead() {
        XCTAssertEqual(
            WorkspaceToolbarController.sidebarDividerPosition(
                forExpandedWidth: 337,
                arrangedContainerFrame: NSRect(x: 0, y: 0, width: 337, height: 700),
                contentFrame: NSRect(x: 0, y: 0, width: 329, height: 700),
                splitBoundsMinX: 0),
            345)
        XCTAssertEqual(
            WorkspaceToolbarController.sidebarDividerPosition(
                forExpandedWidth: 337,
                arrangedContainerFrame: nil,
                contentFrame: nil,
                splitBoundsMinX: 4),
            341)
        XCTAssertEqual(
            WorkspaceToolbarController.sidebarDividerPosition(
                forExpandedWidth: 337,
                arrangedContainerFrame: NSRect(x: 0, y: 0, width: 500, height: 700),
                contentFrame: NSRect(x: 0, y: 0, width: 329, height: 700),
                splitBoundsMinX: 4),
            341,
            "implausible container overhead must use the split-bounds fallback")
    }

    func testAgentBridgeInitializationSeedsOppositeWindowLayoutsBeforeStart() throws {
        let defaultsBackup = DefaultsBackup(keys: Self.legacyDefaultsKeys)
        defer { defaultsBackup.restore() }

        // Make every legacy value disagree with the first restored window. `start()` is what reads
        // those fallbacks; construction must already expose the exact per-window snapshot so the
        // hosting controllers never paint one frame of the app-wide state.
        UserDefaults.standard.set(true, forKey: "panel.sidebar")
        UserDefaults.standard.set(false, forKey: "panel.inspector")
        UserDefaults.standard.set(true, forKey: "panel.terminal")
        UserDefaults.standard.set(121.0, forKey: "terminalHeight")

        let firstSupport = try makeSupportDirectory()
        let secondSupport = try makeSupportDirectory()
        defer {
            try? FileManager.default.removeItem(at: firstSupport)
            try? FileManager.default.removeItem(at: secondSupport)
        }

        let first = AgentBridge(
            initialProjectID: UUID(),
            initialWindowLayout: WorkspaceWindowLayout(
                showsSidebar: false,
                showsInspector: true,
                inspectorPreferredWidth: 610,
                showsTerminal: false,
                terminalHeight: 330),
            settingsBaseOverride: firstSupport,
            environmentOverride: [:])
        let second = AgentBridge(
            initialProjectID: UUID(),
            initialWindowLayout: WorkspaceWindowLayout(
                showsSidebar: true,
                showsInspector: false,
                inspectorPreferredWidth: 780,
                showsTerminal: true,
                terminalHeight: 190),
            settingsBaseOverride: secondSupport,
            environmentOverride: [:])
        defer {
            first.shutdown()
            second.shutdown()
        }

        XCTAssertFalse(first.showSidebar)
        XCTAssertTrue(first.showInspector)
        XCTAssertFalse(first.showTerminal)
        XCTAssertEqual(first.inspectorPreferredWidth, 610)
        XCTAssertEqual(first.terminalHeight, 330)

        XCTAssertTrue(second.showSidebar)
        XCTAssertFalse(second.showInspector)
        XCTAssertTrue(second.showTerminal)
        XCTAssertEqual(second.inspectorPreferredWidth, 780)
        XCTAssertEqual(second.terminalHeight, 190)
    }

    func testFreshBridgeStartsWithInspectorClosedWithoutSavedState() throws {
        let defaultsBackup = DefaultsBackup(keys: Self.legacyDefaultsKeys)
        defer { defaultsBackup.restore() }
        UserDefaults.standard.removeObject(forKey: "panel.inspector")

        let support = try makeSupportDirectory()
        defer { try? FileManager.default.removeItem(at: support) }
        let bridge = AgentBridge(
            initialProjectID: UUID(),
            settingsBaseOverride: support,
            environmentOverride: [:])
        defer { bridge.shutdown() }

        XCTAssertFalse(bridge.showInspector)
    }

    func testFreshHelpBridgeStartsWithInspectorClosedAndRestoredStateWins() throws {
        let defaultsBackup = DefaultsBackup(keys: Self.legacyDefaultsKeys)
        defer { defaultsBackup.restore() }
        UserDefaults.standard.removeObject(forKey: "panel.inspector")
        let freshSupport = try makeSupportDirectory()
        let laterSupport = try makeSupportDirectory()
        let restoredSupport = try makeSupportDirectory()
        defer {
            try? FileManager.default.removeItem(at: freshSupport)
            try? FileManager.default.removeItem(at: laterSupport)
            try? FileManager.default.removeItem(at: restoredSupport)
        }

        let fresh = AgentBridge(
            initialProjectID: HelpWorkspace.id,
            settingsBaseOverride: freshSupport,
            environmentOverride: [:])
        XCTAssertFalse(fresh.showInspector)
        XCTAssertNil(
            UserDefaults.standard.object(forKey: "panel.inspector"),
            "A fresh Help window must not invent a global user preference.")

        let later = AgentBridge(
            initialProjectID: HelpWorkspace.id,
            settingsBaseOverride: laterSupport,
            environmentOverride: [:])
        XCTAssertFalse(
            later.showInspector,
            "A genuinely fresh Help window should remain closed without a restored layout.")
        XCTAssertNil(UserDefaults.standard.object(forKey: "panel.inspector"))

        UserDefaults.standard.set(true, forKey: "panel.inspector")
        let restored = AgentBridge(
            initialProjectID: HelpWorkspace.id,
            initialWindowLayout: WorkspaceWindowLayout(
                showsInspector: false),
            settingsBaseOverride: restoredSupport,
            environmentOverride: [:])
        XCTAssertFalse(restored.showInspector)
        XCTAssertTrue(
            UserDefaults.standard.bool(forKey: "panel.inspector"),
            "A restored Help-only layout must not overwrite another workspace's global fallback.")

        fresh.shutdown()
        later.shutdown()
        restored.shutdown()
    }

    func testEnteringHelpInPlaceStartsClosedThenPreservesThisWindowsChoice() throws {
        let defaultsBackup = DefaultsBackup(keys: Self.legacyDefaultsKeys)
        defer { defaultsBackup.restore() }
        UserDefaults.standard.removeObject(forKey: "panel.inspector")

        let support = try makeSupportDirectory()
        defer { try? FileManager.default.removeItem(at: support) }
        let existingHelp = ProjectStore.shared.project(HelpWorkspace.id)
        let help = ReservedWorkspace.help.canonicalProject(
            preservingRuntimePreferenceFrom: existingHelp)
        ProjectStore.shared.upsert(help)

        let bridge = AgentBridge(
            settingsBaseOverride: support,
            environmentOverride: [:])
        defer {
            if let conversationID = bridge.currentID {
                ConversationStore.shared.remove(conversationID, permanently: true)
            }
            bridge.shutdown()
            if let existingHelp {
                ProjectStore.shared.upsert(existingHelp)
            } else {
                ProjectStore.shared.remove(HelpWorkspace.id)
            }
            ConversationStore.shared.flushSaves()
            ProjectStore.shared.flushSaves()
        }

        bridge.enterWorkspace(help)
        XCTAssertFalse(bridge.showInspector)
        XCTAssertNil(
            UserDefaults.standard.object(forKey: "panel.inspector"),
            "The in-place Help default must not become a global user preference.")

        bridge.userToggledInspector()
        bridge.enterWorkspace(help)
        XCTAssertTrue(
            bridge.showInspector,
            "Re-entering Help in the same bridge must preserve the person's current choice.")
    }

    func testVisibleLayoutAppliesAndSnapshotsTheNativeFrameAndSidebarWidth() async throws {
        let defaultsBackup = DefaultsBackup(keys: Self.legacyDefaultsKeys)
        defer { defaultsBackup.restore() }

        let projectID = UUID()
        defer { clearLayoutDefaults(projectID: projectID) }
        // A session snapshot is the most exact state for a window and must beat an older
        // per-workspace fallback stored in UserDefaults.
        UserDefaults.standard.set(318.0, forKey: "mech.ws.sidebar.\(projectID.uuidString)")

        let support = try makeSupportDirectory()
        defer { try? FileManager.default.removeItem(at: support) }

        let proposedFrame = frameInsideMainScreen(width: 1_080, height: 720)
        let layout = WorkspaceWindowLayout(
            frame: WorkspaceWindowFrame(proposedFrame),
            showsSidebar: true,
            sidebarWidth: 337,
            showsInspector: false,
            inspectorPreferredWidth: 515,
            showsTerminal: true,
            terminalHeight: 287)
        let fixture = makeFixture(
            projectID: projectID,
            layout: layout,
            support: support)
        defer { fixture.tearDown() }

        let expectedFrame = NSScreen.screens.max { lhs, rhs in
            intersectionArea(proposedFrame, lhs.visibleFrame)
                < intersectionArea(proposedFrame, rhs.visibleFrame)
        }.map { fixture.window.constrainFrameRect(proposedFrame, to: $0) } ?? proposedFrame

        fixture.controller.applyInitialLayout(restoring: layout)
        fixture.layoutViews()
        await drainMainQueue()
        fixture.layoutViews()

        XCTAssertEqual(fixture.window.frame.origin.x, expectedFrame.origin.x, accuracy: 1)
        XCTAssertEqual(fixture.window.frame.origin.y, expectedFrame.origin.y, accuracy: 1)
        XCTAssertEqual(fixture.window.frame.width, expectedFrame.width, accuracy: 1)
        XCTAssertEqual(fixture.window.frame.height, expectedFrame.height, accuracy: 1)
        XCTAssertEqual(fixture.sidebarItem?.isCollapsed, false)
        XCTAssertEqual(try XCTUnwrap(fixture.sidebarWidth), 337, accuracy: 1)

        let snapshot = fixture.controller.windowLayoutSnapshot()
        let snapshotFrame = try XCTUnwrap(snapshot.frame?.rect)
        XCTAssertEqual(snapshotFrame.origin.x, fixture.window.frame.origin.x, accuracy: 1)
        XCTAssertEqual(snapshotFrame.origin.y, fixture.window.frame.origin.y, accuracy: 1)
        XCTAssertEqual(snapshotFrame.width, fixture.window.frame.width, accuracy: 1)
        XCTAssertEqual(snapshotFrame.height, fixture.window.frame.height, accuracy: 1)
        XCTAssertEqual(snapshot.showsSidebar, true)
        XCTAssertEqual(try XCTUnwrap(snapshot.sidebarWidth), 337, accuracy: 1)
        XCTAssertEqual(snapshot.showsInspector, false)
        XCTAssertEqual(snapshot.inspectorPreferredWidth, 515)
        XCTAssertEqual(snapshot.showsTerminal, true)
        XCTAssertEqual(snapshot.terminalHeight, 287)
    }

    func testFreshSidebarUsesTheWiderDefaultWithoutReplacingAPersistedWidth() {
        let range = 220.0...420.0

        XCTAssertEqual(
            WorkspaceToolbarController.resolvedSidebarWidth(
                preferred: nil,
                legacy: nil,
                range: range),
            340)
        XCTAssertEqual(
            WorkspaceToolbarController.resolvedSidebarWidth(
                preferred: nil,
                legacy: 286,
                range: range),
            286,
            "A person's old per-workspace divider width beats the revised product default.")
        XCTAssertEqual(
            WorkspaceToolbarController.resolvedSidebarWidth(
                preferred: 337,
                legacy: 286,
                range: range),
            337,
            "A session snapshot remains the most exact record of a native window.")
        XCTAssertEqual(
            WorkspaceToolbarController.resolvedSidebarWidth(
                preferred: 500,
                legacy: 286,
                range: range),
            286,
            "An invalid session width falls back to the person's valid older divider choice.")
        XCTAssertEqual(
            WorkspaceToolbarController.resolvedSidebarWidth(
                preferred: nil,
                legacy: 500,
                range: range),
            340,
            "An invalid saved width falls back safely instead of applying an unbounded divider.")
    }

    func testInitialLayoutKeepsLegacySidebarWidthDuringFrameSetup() async throws {
        let defaultsBackup = DefaultsBackup(keys: Self.legacyDefaultsKeys)
        defer { defaultsBackup.restore() }

        let projectID = UUID()
        defer { clearLayoutDefaults(projectID: projectID) }
        let legacyWidth = 318.0
        let sidebarKey = "mech.ws.sidebar.\(projectID.uuidString)"
        UserDefaults.standard.set(legacyWidth, forKey: sidebarKey)

        let support = try makeSupportDirectory()
        defer { try? FileManager.default.removeItem(at: support) }
        let fixture = makeFixture(
            projectID: projectID,
            layout: WorkspaceWindowLayout(showsSidebar: true),
            support: support)
        defer { fixture.tearDown() }

        // A fresh frame/content-size mutation can synchronously call `windowDidResize`. That
        // notification must not save the controller's construction fallback over an older
        // per-workspace divider width before the initial restore reads it.
        fixture.controller.applyInitialLayout(restoring: nil)
        fixture.layoutViews()
        await drainMainQueue()
        fixture.layoutViews()

        XCTAssertEqual(
            UserDefaults.standard.double(forKey: sidebarKey),
            legacyWidth,
            accuracy: 1,
            "Initial frame setup must leave the saved per-workspace divider width intact.")
        XCTAssertEqual(
            try XCTUnwrap(fixture.controller.windowLayoutSnapshot().sidebarWidth),
            legacyWidth,
            accuracy: 1)
    }

    func testPreKeyWorkspaceRebindKeepsBothSavedSidebarWidthsBeforeDividerApplication() async throws {
        let defaultsBackup = DefaultsBackup(keys: Self.legacyDefaultsKeys)
        defer { defaultsBackup.restore() }

        let outgoingProjectID = UUID()
        let incomingProjectID = UUID()
        defer {
            clearLayoutDefaults(projectID: outgoingProjectID)
            clearLayoutDefaults(projectID: incomingProjectID)
        }
        let outgoingSidebarKey = "mech.ws.sidebar.\(outgoingProjectID.uuidString)"
        let incomingSidebarKey = "mech.ws.sidebar.\(incomingProjectID.uuidString)"
        UserDefaults.standard.set(318.0, forKey: outgoingSidebarKey)
        UserDefaults.standard.set(286.0, forKey: incomingSidebarKey)

        let support = try makeSupportDirectory()
        defer { try? FileManager.default.removeItem(at: support) }
        let fixture = makeFixture(
            projectID: outgoingProjectID,
            layout: WorkspaceWindowLayout(showsSidebar: true),
            support: support)
        defer { fixture.tearDown() }
        // Give the incoming workspace an existing frame so `setFrameUsingName` performs the
        // synchronous resize that otherwise races its saved divider width.
        fixture.window.saveFrame(usingName: "mech.ws.frame.\(incomingProjectID.uuidString)")

        fixture.controller.applyInitialLayout(restoring: nil)
        // Rebind before the initial `DispatchQueue.main.async` divider application drains. This
        // models launch routing selecting a different workspace before the first window becomes
        // key, while both legacy divider choices must remain authoritative.
        fixture.bridge.projectID = incomingProjectID
        fixture.controller.rebindLayoutForWorkspaceChange()
        fixture.controller.windowDidResize(
            Notification(name: NSWindow.didResizeNotification, object: fixture.window))
        fixture.layoutViews()
        await drainMainQueue()
        fixture.layoutViews()

        XCTAssertEqual(UserDefaults.standard.double(forKey: outgoingSidebarKey), 318, accuracy: 1)
        XCTAssertEqual(UserDefaults.standard.double(forKey: incomingSidebarKey), 286, accuracy: 1)
        XCTAssertEqual(
            try XCTUnwrap(fixture.controller.windowLayoutSnapshot().sidebarWidth),
            286,
            accuracy: 1)

        // Once this window reaches its first key event, the scoped guard must release after the
        // retry. A later ordinary save is then allowed to refresh the incoming workspace's key.
        fixture.controller.windowDidBecomeKey(
            Notification(name: NSWindow.didBecomeKeyNotification, object: fixture.window))
        await drainMainQueue()
        UserDefaults.standard.set(299.0, forKey: incomingSidebarKey)
        fixture.controller.saveWindowLayout()
        XCTAssertEqual(UserDefaults.standard.double(forKey: incomingSidebarKey), 286, accuracy: 1)
    }

    func testSupersededPostKeyDividerApplicationReleasesSidebarPersistenceSuppression() async throws {
        let defaultsBackup = DefaultsBackup(keys: Self.legacyDefaultsKeys)
        defer { defaultsBackup.restore() }

        let projectID = UUID()
        defer { clearLayoutDefaults(projectID: projectID) }
        let sidebarKey = "mech.ws.sidebar.\(projectID.uuidString)"
        UserDefaults.standard.set(286.0, forKey: sidebarKey)

        let support = try makeSupportDirectory()
        defer { try? FileManager.default.removeItem(at: support) }
        let fixture = makeFixture(
            projectID: projectID,
            layout: WorkspaceWindowLayout(showsSidebar: true),
            support: support)
        defer { fixture.tearDown() }

        fixture.controller.applyInitialLayout(restoring: nil)
        fixture.controller.windowDidBecomeKey(
            Notification(name: NSWindow.didBecomeKeyNotification, object: fixture.window))
        // The post-key retry owns the suppression release. Queue a normal restore immediately
        // after it, before that retry reaches its divider closure, to model a live layout event
        // superseding the original application generation.
        DispatchQueue.main.async {
            fixture.controller.applySidebarWidth()
        }
        await drainMainQueue()
        fixture.layoutViews()

        // A later person-driven resize/save must persist normally rather than remain suppressed
        // because the post-key retry was superseded.
        UserDefaults.standard.set(299.0, forKey: sidebarKey)
        fixture.controller.windowDidResize(
            Notification(name: NSWindow.didResizeNotification, object: fixture.window))
        XCTAssertEqual(UserDefaults.standard.double(forKey: sidebarKey), 286, accuracy: 1)
    }

    func testCollapsedSidebarSnapshotRetainsWidthForTheNextExpansion() async throws {
        let defaultsBackup = DefaultsBackup(keys: Self.legacyDefaultsKeys)
        defer { defaultsBackup.restore() }

        let projectID = UUID()
        defer { clearLayoutDefaults(projectID: projectID) }

        let collapsedSupport = try makeSupportDirectory()
        let reopenedSupport = try makeSupportDirectory()
        defer {
            try? FileManager.default.removeItem(at: collapsedSupport)
            try? FileManager.default.removeItem(at: reopenedSupport)
        }

        let collapsedLayout = WorkspaceWindowLayout(
            frame: WorkspaceWindowFrame(frameInsideMainScreen(width: 1_040, height: 700)),
            showsSidebar: false,
            sidebarWidth: 346,
            showsInspector: true,
            inspectorPreferredWidth: 540,
            showsTerminal: false,
            terminalHeight: 240)
        let collapsed = makeFixture(
            projectID: projectID,
            layout: collapsedLayout,
            support: collapsedSupport,
            includesSidebar: false)
        defer { collapsed.tearDown() }

        collapsed.controller.applyInitialLayout(restoring: collapsedLayout)
        collapsed.layoutViews()
        await drainMainQueue()

        // A collapsed NSSplitViewItem exposes no useful divider width. Omitting that item models the
        // same measurement boundary without asking AppKit to animate a hidden test window.
        XCTAssertNil(collapsed.sidebarItem)
        let snapshot = collapsed.controller.windowLayoutSnapshot()
        XCTAssertEqual(snapshot.showsSidebar, false)
        XCTAssertEqual(try XCTUnwrap(snapshot.sidebarWidth), 346, accuracy: 1)

        // Rebuild the native shell as launch replay does. The collapsed view itself has no useful
        // width, so this proves the retained expanded width—not a live divider measurement—is what
        // the next expansion consumes.
        var reopenedLayout = snapshot
        reopenedLayout.showsSidebar = true
        let reopened = makeFixture(
            projectID: projectID,
            layout: reopenedLayout,
            support: reopenedSupport)
        defer { reopened.tearDown() }

        reopened.controller.applyInitialLayout(restoring: reopenedLayout)
        reopened.layoutViews()
        await drainMainQueue()
        reopened.layoutViews()

        XCTAssertEqual(reopened.sidebarItem?.isCollapsed, false)
        XCTAssertEqual(try XCTUnwrap(reopened.sidebarWidth), 346, accuracy: 1)
        XCTAssertEqual(
            try XCTUnwrap(reopened.controller.windowLayoutSnapshot().sidebarWidth),
            346,
            accuracy: 1)
    }

    // MARK: - Fixture

    @MainActor
    private final class Fixture {
        let bridge: AgentBridge
        let window: WorkspaceWindow
        let splitViewController: NSSplitViewController
        let sidebarItem: NSSplitViewItem?
        let controller: WorkspaceToolbarController

        init(
            bridge: AgentBridge,
            window: WorkspaceWindow,
            splitViewController: NSSplitViewController,
            sidebarItem: NSSplitViewItem?,
            controller: WorkspaceToolbarController
        ) {
            self.bridge = bridge
            self.window = window
            self.splitViewController = splitViewController
            self.sidebarItem = sidebarItem
            self.controller = controller
        }

        var sidebarWidth: CGFloat? { sidebarItem?.viewController.view.frame.width }

        func layoutViews() {
            window.contentView?.layoutSubtreeIfNeeded()
            splitViewController.view.layoutSubtreeIfNeeded()
        }

        func tearDown() {
            controller.invalidate()
            bridge.shutdown()
            window.delegate = nil
            // These windows are never ordered on screen. Calling `close()` on an unpresented
            // full-size-content AppKit split window schedules private teardown work beyond the test
            // method and can over-release that graph when XCTest drains its autorelease pool.
            withExtendedLifetime((controller, bridge, splitViewController, window)) {}
        }
    }

    private func makeFixture(
        projectID: UUID,
        layout: WorkspaceWindowLayout,
        support: URL,
        includesSidebar: Bool = true
    ) -> Fixture {
        _ = NSApplication.shared
        let bridge = AgentBridge(
            initialProjectID: projectID,
            initialWindowLayout: layout,
            settingsBaseOverride: support,
            environmentOverride: [:])

        let sidebarController = NSViewController()
        sidebarController.view = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 700))
        let detailController = NSViewController()
        detailController.view = NSView(frame: NSRect(x: 0, y: 0, width: 740, height: 700))

        let sidebarItem: NSSplitViewItem? = includesSidebar
            ? NSSplitViewItem(sidebarWithViewController: sidebarController)
            : nil
        let contentItem = NSSplitViewItem(viewController: detailController)

        let splitViewController = NSSplitViewController()
        if let sidebarItem {
            sidebarItem.minimumThickness = 220
            sidebarItem.maximumThickness = 420
            sidebarItem.canCollapse = true
            splitViewController.addSplitViewItem(sidebarItem)
            splitViewController.addSplitViewItem(contentItem)
        }

        let window = WorkspaceWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1_040, height: 700),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false)
        window.toolbarStyle = .unified
        window.titlebarAppearsTransparent = true
        window.contentViewController = splitViewController
        let controller = WorkspaceToolbarController(
            bridge: bridge,
            splitVC: splitViewController,
            window: window)
        window.delegate = controller
        bridge.window = window
        return Fixture(
            bridge: bridge,
            window: window,
            splitViewController: splitViewController,
            sidebarItem: sidebarItem,
            controller: controller)
    }

    private struct DefaultsBackup {
        let keys: [String]
        let values: [String: Any]

        init(keys: [String]) {
            self.keys = keys
            values = Dictionary(uniqueKeysWithValues: keys.compactMap { key in
                UserDefaults.standard.object(forKey: key).map { (key, $0) }
            })
        }

        func restore() {
            for key in keys { UserDefaults.standard.removeObject(forKey: key) }
            for (key, value) in values { UserDefaults.standard.set(value, forKey: key) }
        }
    }

    private func makeSupportDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("workspace-layout-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func clearLayoutDefaults(projectID: UUID) {
        let key = projectID.uuidString
        UserDefaults.standard.removeObject(forKey: "mech.ws.sidebar.\(key)")
        UserDefaults.standard.removeObject(forKey: "NSWindow Frame mech.ws.frame.\(key)")
        UserDefaults.standard.removeObject(forKey: "inspectorWidth.\(key)")
    }

    private func frameInsideMainScreen(width: CGFloat, height: CGFloat) -> NSRect {
        guard let visibleFrame = NSScreen.main?.visibleFrame ?? NSScreen.screens.first?.visibleFrame
        else { return NSRect(x: 80, y: 80, width: width, height: height) }
        let fittedWidth = min(width, max(640, visibleFrame.width - 80))
        let fittedHeight = min(height, max(420, visibleFrame.height - 80))
        return NSRect(
            x: visibleFrame.midX - fittedWidth / 2,
            y: visibleFrame.midY - fittedHeight / 2,
            width: fittedWidth,
            height: fittedHeight)
    }

    private func intersectionArea(_ lhs: NSRect, _ rhs: NSRect) -> CGFloat {
        let intersection = lhs.intersection(rhs)
        guard !intersection.isNull else { return 0 }
        return intersection.width * intersection.height
    }

    private func drainMainQueue(passes: Int = 8) async {
        for _ in 0..<passes { await Task.yield() }
    }
}
