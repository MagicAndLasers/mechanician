import AppKit
import Combine
import XCTest
@testable import Mechanician

@MainActor
final class UtilityWindowVisibilityTests: XCTestCase {
    private final class ActionTarget: NSObject {
        var activations = 0
        @objc func activate(_ sender: Any?) { activations += 1 }
    }

    func testAbsentWindowRequestsOneSceneOpen() {
        _ = NSApplication.shared
        let store = UtilityWindowVisibility(windows: { [] })
        var opens = 0

        XCTAssertEqual(store.toggle(.extensions) { opens += 1 }, .requestedOpen)
        XCTAssertEqual(opens, 1)
        XCTAssertFalse(store.isVisible(.extensions))
    }

    func testRetainedHiddenWindowIsReusedWithoutSceneOpen() async {
        _ = NSApplication.shared
        let window = makeWindow()
        let store = UtilityWindowVisibility(windows: { [window] })
        store.register(window, as: .artifacts)
        var opens = 0

        XCTAssertEqual(store.toggle(.artifacts) { opens += 1 }, .showedExisting)
        await drainMainQueue()

        XCTAssertEqual(opens, 0)
        XCTAssertTrue(window.isVisible)
        XCTAssertTrue(store.isVisible(.artifacts))
        window.close()
    }

    func testVisibleWindowToggleClosesAndClearsPublishedState() async {
        _ = NSApplication.shared
        let window = makeWindow()
        window.orderFrontRegardless()
        let store = UtilityWindowVisibility(windows: { [window] })
        store.register(window, as: .ambient)
        XCTAssertTrue(store.isVisible(.ambient))

        XCTAssertEqual(store.toggle(.ambient) {}, .requestedClose)
        await drainMainQueue()

        XCTAssertFalse(window.isVisible)
        XCTAssertFalse(store.isVisible(.ambient))
    }

    func testContextualShowKeepsVisibleWindowOpen() async {
        _ = NSApplication.shared
        let window = makeWindow()
        window.orderFrontRegardless()
        let store = UtilityWindowVisibility(windows: { [window] })
        store.register(window, as: .accounts)
        var opens = 0

        XCTAssertEqual(store.show(.accounts) { opens += 1 }, .showedExisting)
        await drainMainQueue()

        XCTAssertEqual(opens, 0)
        XCTAssertTrue(window.isVisible)
        XCTAssertTrue(store.isVisible(.accounts))
        window.close()
    }

    func testNativeCloseUpdatesEveryVisibilityObserver() async {
        _ = NSApplication.shared
        let window = makeWindow()
        window.orderFrontRegardless()
        let store = UtilityWindowVisibility(windows: { [window] })
        var snapshots: [Set<UtilityWindowID>] = []
        let observation = store.$visibleIDs.sink { snapshots.append($0) }
        store.register(window, as: .extensions)
        XCTAssertEqual(window.identifier, UtilityWindowID.extensions.windowIdentifier)

        window.performClose(nil)
        await drainMainQueue()

        XCTAssertTrue(snapshots.contains([.extensions]))
        XCTAssertEqual(snapshots.last, [])
        withExtendedLifetime(observation) {}
    }

    func testNativeWindowNotificationsRecomputeActualVisibility() async {
        _ = NSApplication.shared
        let window = makeWindow()
        window.orderFrontRegardless()
        let store = UtilityWindowVisibility(windows: { [window] })
        store.register(window, as: .artifacts)

        window.orderOut(nil)
        NotificationCenter.default.post(name: NSWindow.didMiniaturizeNotification, object: window)
        await drainMainQueue()
        XCTAssertFalse(store.isVisible(.artifacts))

        window.orderFrontRegardless()
        NotificationCenter.default.post(name: NSWindow.didDeminiaturizeNotification, object: window)
        await drainMainQueue()
        XCTAssertTrue(store.isVisible(.artifacts))
        window.close()
    }

    func testToolbarToggleButtonPublishesNativeAndAccessibilityState() {
        let target = ActionTarget()
        let button = ToolbarToggleButton(
            symbol: "puzzlepiece.extension",
            target: target,
            action: #selector(ActionTarget.activate(_:)))

        button.setOn(true)
        XCTAssertEqual(button.state, .on)
        XCTAssertEqual(button.accessibilityValue() as? String, "On")

        button.setOn(false)
        XCTAssertEqual(button.state, .off)
        XCTAssertEqual(button.accessibilityValue() as? String, "Off")
    }

    func testToolbarToggleButtonAccessibilityPressUsesItsRealAction() {
        let target = ActionTarget()
        let button = ToolbarToggleButton(
            symbol: "brain",
            target: target,
            action: #selector(ActionTarget.activate(_:)))

        XCTAssertTrue(button.accessibilityPerformPress())
        XCTAssertEqual(target.activations, 1)

        button.isEnabled = false
        XCTAssertFalse(button.accessibilityPerformPress())
        XCTAssertEqual(target.activations, 1)
    }

    func testToolbarUtilityDeckUsesOneSharedSurfaceForGlobalAndWorkspaceTools() {
        let deck = makeToolbarDeck()
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 80))
        host.addSubview(deck)
        NSLayoutConstraint.activate([
            deck.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            deck.topAnchor.constraint(equalTo: host.topAnchor),
        ])
        host.layoutSubtreeIfNeeded()

        XCTAssertEqual(deck.buttons.count, 4)
        XCTAssertEqual(deck.layer?.cornerRadius, 9)
        XCTAssertEqual(deck.layer?.borderWidth, 0.5)
        XCTAssertNotNil(deck.layer?.backgroundColor)
        XCTAssertNotNil(deck.layer?.borderColor)

        let frames = deck.controls.compactMap { deck.button(for: $0)?.frame }
        XCTAssertEqual(frames.count, 4)
        // Every segment keeps its full 34pt. The deck's own width is derived from the control
        // count, so a new segment widens the deck rather than squeezing the last button.
        XCTAssertEqual(frames.map(\.width), Array(repeating: 34, count: 4))
        XCTAssertEqual(frames.map(\.height), Array(repeating: 28, count: 4))
        XCTAssertEqual(frames.map(\.midY), Array(repeating: frames[0].midY, count: 4))
    }

    /// A deck with no divider must not reserve a divider's width, or its segments drift off the
    /// 34pt grid the other deck sits on.
    func testPlacesDeckIsEqualSegmentsWithNoInternalDivider() {
        let deck = makePlacesDeck()
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 80))
        host.addSubview(deck)
        NSLayoutConstraint.activate([
            deck.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            deck.topAnchor.constraint(equalTo: host.topAnchor),
        ])
        host.layoutSubtreeIfNeeded()

        XCTAssertEqual(deck.controls, [.home, .help])
        XCTAssertEqual(deck.arrangedSubviewsForTesting.count, 2)
        XCTAssertNil(deck.semanticDivider.superview)
        let frames = deck.controls.compactMap { deck.button(for: $0)?.frame }
        XCTAssertEqual(frames.map(\.width), Array(repeating: 34, count: 2))
        XCTAssertEqual(frames.map(\.midY), Array(repeating: frames[0].midY, count: 2))
    }

    /// One place, one glyph, everywhere. The launcher card, the switcher row and this segment all
    /// read `WorkspacePlace`, so a place cannot end up wearing two icons across two surfaces again.
    func testEveryPlaceSegmentWearsTheGlyphItsWorkspaceUsesEverywhereElse() {
        for control in ToolbarUtilityDeck.Control.places {
            let place = try! XCTUnwrap(control.place)
            XCTAssertEqual(control.label, place.name)
            XCTAssertNil(control.windowID, "a place is a workspace, never a utility window")
        }
        XCTAssertEqual(WorkspacePlace.help.iconSymbol, HelpWorkspace.iconSymbol)
        // A house, and the same house the launcher card draws. Speech bubbles read as
        // "conversations" on a segment that has no label beside it, two slots from Help's bubble.
        XCTAssertEqual(WorkspacePlace.home.iconSymbol, "house")
        XCTAssertNotNil(NSImage(systemSymbolName: WorkspacePlace.home.iconSymbol,
                                accessibilityDescription: nil))
    }

    func testToolbarUtilityDeckSeparatesGlobalControlsFromWorkspaceTools() {
        let deck = makeToolbarDeck()
        deck.layoutSubtreeIfNeeded()
        let arranged = deck.arrangedSubviewsForTesting

        XCTAssertEqual(arranged.count, 5)
        // The global pair, the divider, and the workspace-scoped pair.
        XCTAssertTrue(arranged[0] === deck.button(for: .providers))
        XCTAssertTrue(arranged[1] === deck.button(for: .extensions))
        XCTAssertTrue(arranged[2] === deck.semanticDivider)
        XCTAssertTrue(arranged[3] === deck.button(for: .artifacts))
        XCTAssertTrue(arranged[4] === deck.button(for: .tasks))
        XCTAssertEqual(deck.semanticDivider.frame.width, 1)
        XCTAssertEqual(deck.semanticDivider.frame.height, 14)
        XCTAssertFalse(deck.semanticDivider.isAccessibilityElement())
    }

    func testToolbarUtilityDeckDoesNotOutlineIdleSegments() {
        let deck = makeToolbarDeck()
        for control in deck.controls {
            let button = try! XCTUnwrap(deck.button(for: control))
            XCTAssertEqual(button.layer?.borderWidth, 0)
            XCTAssertEqual(button.layer?.backgroundColor?.alpha, 0)
        }

        let outerBorder = deck.layer?.borderColor
        deck.setOn(true, for: .extensions)

        XCTAssertGreaterThan(deck.button(for: .extensions)?.layer?.backgroundColor?.alpha ?? 0, 0)
        for control in deck.controls where control != .extensions {
            XCTAssertEqual(deck.button(for: control)?.layer?.backgroundColor?.alpha, 0)
        }
        XCTAssertEqual(deck.layer?.borderColor, outerBorder)
    }

    func testToolbarUtilityDeckPublishesIndependentAccessibilityAndOverflowState() {
        let deck = makeToolbarDeck()
        XCTAssertFalse(deck.isAccessibilityElement())

        for control in deck.controls {
            let button = try! XCTUnwrap(deck.button(for: control))
            XCTAssertEqual(button.accessibilityValue() as? String, "Off")
            XCTAssertEqual(deck.overflowItem(for: control)?.state, .off)
        }

        deck.setOn(true, for: .tasks)
        XCTAssertEqual(deck.button(for: .tasks)?.state, .on)
        XCTAssertEqual(deck.button(for: .tasks)?.accessibilityValue() as? String, "On")
        XCTAssertEqual(deck.overflowItem(for: .tasks)?.state, .on)
        XCTAssertEqual(deck.button(for: .extensions)?.state, .off)

        deck.setEnabled(false, for: .extensions)
        XCTAssertFalse(deck.button(for: .extensions)?.isEnabled ?? true)
        XCTAssertFalse(deck.overflowItem(for: .extensions)?.isEnabled ?? true)
        XCTAssertEqual(deck.button(for: .extensions)?.accessibilityLabel(), "Extensions")

        let menu = try! XCTUnwrap(deck.makeMenuFormRepresentation().submenu)
        XCTAssertEqual(menu.items.map(\.title), ["Providers", "Extensions", "", "Artifacts", "Tasks"])
        // The separator follows the divider, which follows the global pair.
        XCTAssertTrue(menu.items[2].isSeparatorItem)
        // The overflow rows are the only way to reach these once the toolbar narrows, so the places
        // deck needs its own working set rather than borrowing the browsers'.
        let places = try! XCTUnwrap(makePlacesDeck().makeMenuFormRepresentation().submenu)
        XCTAssertEqual(places.items.map(\.title), ["Home", "Help"])
        XCTAssertTrue(places.items.allSatisfy { $0.action != nil })
    }

    func testToolbarUtilityDeckHitTargetsFillEverySegment() {
        let deck = makeToolbarDeck()
        deck.layoutSubtreeIfNeeded()

        for control in deck.controls {
            let button = try! XCTUnwrap(deck.button(for: control))
            let center = button.convert(NSPoint(x: button.bounds.midX, y: button.bounds.midY), to: deck)
            XCTAssertTrue(deck.hitTest(center) === button)
        }
    }

    func testToolbarControllerRetainsInsertedDeckInsteadOfPaletteCopy() {
        let (controller, toolbar, _) = makeToolbarController()

        let inserted = try! XCTUnwrap(controller.toolbar(
            toolbar,
            itemForItemIdentifier: NSToolbarItem.Identifier("workspace.utilityDeck"),
            willBeInsertedIntoToolbar: true)?.view as? ToolbarUtilityDeck)
        XCTAssertTrue(controller.utilityDeck === inserted)

        let palette = try! XCTUnwrap(controller.toolbar(
            toolbar,
            itemForItemIdentifier: NSToolbarItem.Identifier("workspace.utilityDeck"),
            willBeInsertedIntoToolbar: false)?.view as? ToolbarUtilityDeck)
        XCTAssertFalse(palette === inserted)
        XCTAssertTrue(controller.utilityDeck === inserted)
    }

    /// The Memory segment is a toggle even though Memory is a workspace. The fold replaced the old
    /// utility-window toggle with an open/focus route, so a second click could do nothing except
    /// focus the same window again. Exercise the real button and selector chain; testing the router
    /// or the generic utility-window owner separately did not catch that regression.
    func testPrimaryPlaceSegmentClosesAnOpenReservedWorkspace() async {
        _ = NSApplication.shared
        let (controller, toolbar, source) = makeToolbarController()
        let memory = AgentBridge(
            settingsBaseOverride: FileManager.default.temporaryDirectory
                .appendingPathComponent("memory-toolbar-\(UUID().uuidString)"),
            environmentOverride: [:])
        memory.projectID = HelpWorkspace.id
        let memoryWindow = makeWindow()
        memory.window = memoryWindow
        let memorySplit = NSSplitViewController()
        memorySplit.addSplitViewItem(NSSplitViewItem(viewController: NSViewController()))
        memorySplit.addSplitViewItem(NSSplitViewItem(viewController: NSViewController()))
        let memoryController = WorkspaceToolbarController(
            bridge: memory, splitVC: memorySplit, window: memoryWindow)
        memoryWindow.toolbar = memoryController.makeToolbar()
        AgentBridge.live.add(source)
        AgentBridge.live.add(memory)
        let closeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: memoryWindow,
            queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                AgentBridge.live.remove(memory)
                memory.window = nil
            }
        }
        defer {
            memoryController.invalidate()
            NotificationCenter.default.removeObserver(closeObserver)
            AgentBridge.live.remove(source)
            AgentBridge.live.remove(memory)
            memory.window = nil
            source.shutdown()
            memory.shutdown()
            memoryWindow.close()
            withExtendedLifetime((controller, source, memory, memoryWindow)) {}
        }

        let deck = try! XCTUnwrap(controller.toolbar(
            toolbar,
            itemForItemIdentifier: NSToolbarItem.Identifier("workspace.placesDeck"),
            willBeInsertedIntoToolbar: true)?.view as? ToolbarUtilityDeck)
        let button = try! XCTUnwrap(deck.button(for: .help))
        memoryWindow.orderFrontRegardless()
        NotificationCenter.default.post(
            name: NSWindow.didBecomeKeyNotification,
            object: memoryWindow)
        await drainMainQueue()
        XCTAssertTrue(memoryWindow.isVisible)
        XCTAssertEqual(button.state, .on, "an open reserved workspace is the toggle's on-state")

        button.performClick(nil)
        await drainMainQueue()
        XCTAssertFalse(memoryWindow.isVisible, "the primary segment closes the existing workspace")
        XCTAssertEqual(button.state, .off)
    }


    /// The places belong with the control that says WHERE YOU ARE, not with the browsers that say
    /// what is open. Ordering is the whole claim here: leading side, after the switcher and its
    /// actions, ahead of the flexible space that pushes the browsers to the trailing edge.
    func testPlacesDeckSitsWithTheWorkspaceSwitcherRatherThanTheBrowsers() {
        let (controller, toolbar, _) = makeToolbarController()
        let ids = controller.toolbarDefaultItemIdentifiers(toolbar)

        let places = try! XCTUnwrap(ids.firstIndex(of: NSToolbarItem.Identifier("workspace.placesDeck")))
        let actions = try! XCTUnwrap(ids.firstIndex(of: NSToolbarItem.Identifier("workspace.actions")))
        let flexible = try! XCTUnwrap(ids.firstIndex(of: .flexibleSpace))
        let browsers = try! XCTUnwrap(ids.firstIndex(of: NSToolbarItem.Identifier("workspace.utilityDeck")))
        XCTAssertGreaterThan(places, actions)
        XCTAssertLessThan(places, flexible)
        XCTAssertLessThan(flexible, browsers)

        let item = try! XCTUnwrap(controller.toolbar(
            toolbar,
            itemForItemIdentifier: NSToolbarItem.Identifier("workspace.placesDeck"),
            willBeInsertedIntoToolbar: true))
        let deck = try! XCTUnwrap(item.view as? ToolbarUtilityDeck)
        XCTAssertTrue(controller.placesDeck === deck)
        XCTAssertEqual(deck.controls, [.home, .help])
        // No place has a list behind it worth previewing; a menu whose single row repeats the
        // click teaches nothing.
        XCTAssertNil(deck.button(for: .home)?.menu)
        XCTAssertNil(deck.button(for: .help)?.menu)
    }

    /// David reported the right-panel toggle "sitting on the border of the two panels". It was
    /// placed by adding a constant to the region's own leading edge, which silently assumes the
    /// region begins exactly at the seam — it does not, because NSToolbar insets the item and the
    /// published inspector width does not include the detail column's own chrome. The region now
    /// corrects itself against the seam the resize handle actually draws.
    func testTheInspectorButtonLandsInsideTheSeamWhereverTheToolbarPutsTheRegion() {
        let window = makeWindow()
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 900, height: 60))
        window.contentView = host
        let target = ActionTarget()
        let region = InspectorToolbarRegionView(
            target: target, action: #selector(ActionTarget.activate(_:)))
        host.addSubview(region)
        defer { window.close() }

        // NSToolbar puts the region somewhere of its own choosing — here, 37pt shy of where a
        // width-plus-constant calculation would have assumed it starts.
        region.setWidth(400, leadingInset: InspectorToolbarRegionView.openLeadingInset)
        region.setFrameOrigin(NSPoint(x: 463, y: 0))
        region.desiredButtonWindowX = 540   // a seam at 516, plus the 24pt inset
        // The correction is applied during layout and takes effect on the pass after it changes the
        // constraint — the same two passes AppKit runs for it in a live window.
        settleLayout(region, in: host)

        let buttonWindowX = region.button.convert(NSPoint.zero, to: nil).x
        XCTAssertEqual(buttonWindowX, 540, accuracy: 0.5,
                       "the button follows the seam, not the region's own leading edge")

        // With no seam to correct against — the inspector closed, or expanded to the full width —
        // the constant remains the fallback rather than a wrong answer.
        region.desiredButtonWindowX = nil
        region.setWidth(400, leadingInset: 0)
        settleLayout(region, in: host)
        XCTAssertEqual(region.button.convert(NSPoint.zero, to: nil).x, 463, accuracy: 0.5)
    }

    /// The control that says WHERE YOU ARE must be the last thing a crowded toolbar gives up.
    ///
    /// The places deck shipped asking for `.high` while the switcher carried the default, so a
    /// window with a wide inspector dropped the workspace name and its menu — the only place the
    /// full workspace list lives — while keeping three shortcuts to places that menu also lists.
    func testACrowdedToolbarGivesUpThePlacesDeckBeforeTheWorkspaceSwitcher() {
        let (controller, toolbar, _) = makeToolbarController()
        func item(_ identifier: String) -> NSToolbarItem {
            try! XCTUnwrap(controller.toolbar(
                toolbar,
                itemForItemIdentifier: NSToolbarItem.Identifier(identifier),
                willBeInsertedIntoToolbar: true))
        }
        let switcher = item("workspace.folderMenu")
        let places = item("workspace.placesDeck")
        let browsers = item("workspace.utilityDeck")
        let inspector = item("window.inspectorRegion")

        XCTAssertEqual(places.visibilityPriority, .low)
        XCTAssertGreaterThan(switcher.visibilityPriority, places.visibilityPriority)
        XCTAssertGreaterThan(browsers.visibilityPriority, places.visibilityPriority)
        XCTAssertGreaterThan(inspector.visibilityPriority, places.visibilityPriority)
        // Every place it drops is still one click away in the switcher it just protected.
        XCTAssertNotNil(places.menuFormRepresentation?.submenu)
    }

    /// One rule, no exceptions: a lit segment closes the place's window, and it closes the window
    /// it is DRAWN IN like any other. The control used to switch jobs here — inside the place it
    /// toggled an inspector tab instead — which made one button mean two things depending on which
    /// window you were standing in.
    func testPressingALitPlaceClosesThatWindowEvenFromInsideIt() async {
        _ = NSApplication.shared
        let support = FileManager.default.temporaryDirectory
            .appendingPathComponent("mechanician-help-\(UUID().uuidString)", isDirectory: true)
        let bridge = AgentBridge(settingsBaseOverride: support, environmentOverride: [:])
        bridge.projectID = HelpWorkspace.id
        let split = NSSplitViewController()
        split.addSplitViewItem(NSSplitViewItem(viewController: NSViewController()))
        split.addSplitViewItem(NSSplitViewItem(viewController: NSViewController()))
        let window = makeWindow()
        bridge.window = window
        let controller = WorkspaceToolbarController(bridge: bridge, splitVC: split, window: window)
        let toolbar = controller.makeToolbar()
        defer {
            controller.invalidate()
            WorkspacePlaceWindowPresence.shared.unregister(window)
            bridge.window = nil
            bridge.shutdown()
            window.close()
            withExtendedLifetime((controller, bridge, window)) {}
        }

        let deck = try! XCTUnwrap(controller.toolbar(
            toolbar,
            itemForItemIdentifier: NSToolbarItem.Identifier("workspace.placesDeck"),
            willBeInsertedIntoToolbar: true)?.view as? ToolbarUtilityDeck)
        let help = try! XCTUnwrap(deck.button(for: .help))
        window.orderFrontRegardless()
        bridge.showInspector = false

        XCTAssertEqual(help.state, .on, "you are standing in Help, so Help is open")
        XCTAssertEqual(help.toolTip, "Hide Help")

        help.performClick(nil)
        await drainMainQueue()

        XCTAssertFalse(window.isVisible, "a lit place closes its window, including this one")
        XCTAssertFalse(
            bridge.showInspector,
            "the toolbar no longer doubles as a second way to press an inspector tab")
    }

    /// David: *"they should be consistently highlighted when they are open, the buttons should not
    /// have different states in different windows like they do now"*.
    ///
    /// Lit means one thing only — a window for that place exists — and every toolbar reads it from
    /// the same registry, so two windows open at once cannot disagree about which places are open.
    /// The old rule made the answer depend on where you were standing: Memory was lit in the Memory
    /// window only while its inspector showed the record, and dark everywhere else at the same time.
    func testEveryWindowReportsTheSamePlaceStates() {
        _ = NSApplication.shared
        let (homeController, homeToolbar, homeBridge) = makeToolbarController()

        let support = FileManager.default.temporaryDirectory
            .appendingPathComponent("mechanician-help-\(UUID().uuidString)", isDirectory: true)
        let helpBridge = AgentBridge(settingsBaseOverride: support, environmentOverride: [:])
        helpBridge.projectID = HelpWorkspace.id
        let split = NSSplitViewController()
        split.addSplitViewItem(NSSplitViewItem(viewController: NSViewController()))
        split.addSplitViewItem(NSSplitViewItem(viewController: NSViewController()))
        let helpWindow = makeWindow()
        helpBridge.window = helpWindow
        let helpController = WorkspaceToolbarController(
            bridge: helpBridge, splitVC: split, window: helpWindow)
        let helpToolbar = helpController.makeToolbar()
        defer {
            helpController.invalidate()
            WorkspacePlaceWindowPresence.shared.unregister(helpWindow)
            helpBridge.window = nil
            helpBridge.shutdown()
            homeBridge.shutdown()
            helpWindow.close()
            withExtendedLifetime((homeController, helpController, helpWindow)) {}
        }

        func deck(_ controller: WorkspaceToolbarController, _ toolbar: NSToolbar) -> ToolbarUtilityDeck {
            try! XCTUnwrap(controller.toolbar(
                toolbar,
                itemForItemIdentifier: NSToolbarItem.Identifier("workspace.placesDeck"),
                willBeInsertedIntoToolbar: true)?.view as? ToolbarUtilityDeck)
        }
        let fromHome = deck(homeController, homeToolbar)
        let fromHelp = deck(helpController, helpToolbar)

        for control in ToolbarUtilityDeck.Control.places {
            XCTAssertEqual(
                fromHome.button(for: control)?.state,
                fromHelp.button(for: control)?.state,
                "\(control.label) reads differently depending on which window you are in")
        }
        // And the shared answer is the true one: both of these places have a window open.
        XCTAssertEqual(fromHome.button(for: .help)?.state, .on)
        XCTAssertEqual(fromHome.button(for: .home)?.state, .on)
    }

    /// Home reads and behaves exactly like the other two, which is the whole point of the deck.
    /// It cannot do that while it converts the window you are in, so the segment opens Home's own
    /// window — `⇧⌘H` and the switcher row keep switching in place.
    func testHomeSegmentIsAWindowToggleLikeTheOtherTwo() {
        let (controller, toolbar, bridge) = makeToolbarController()
        defer { bridge.shutdown() }
        let deck = try! XCTUnwrap(controller.toolbar(
            toolbar,
            itemForItemIdentifier: NSToolbarItem.Identifier("workspace.placesDeck"),
            willBeInsertedIntoToolbar: true)?.view as? ToolbarUtilityDeck)
        let home = try! XCTUnwrap(deck.button(for: .home))

        XCTAssertNil(bridge.projectID)
        XCTAssertTrue(bridge.cwd.isEmpty)
        XCTAssertEqual(home.state, .on, "this window IS Home")
        // The same words the browsers deck uses, and the shortcut named only in the direction a
        // menu command actually performs.
        XCTAssertEqual(home.toolTip, "Hide Home")
        XCTAssertEqual(
            controller.placeToolTipForTesting(.home, on: false),
            "Show Home (⇧⌘H)")
    }

    /// The switcher opens on the same three places, in the same order, wearing the same glyphs as
    /// the deck beside it — and lists each of them exactly once. Memory and Help are ordinary rows
    /// in `projects` the moment they exist, so without the filter they appeared a second time
    /// among the workspaces the person made.
    func testWorkspaceSwitcherLeadsWithThePlacesAndListsThemOnce() {
        let (controller, toolbar, bridge) = makeToolbarController()
        defer { bridge.shutdown() }
        let item = try! XCTUnwrap(controller.toolbar(
            toolbar,
            itemForItemIdentifier: NSToolbarItem.Identifier("workspace.folderMenu"),
            willBeInsertedIntoToolbar: true) as? NSMenuToolbarItem)
        let menu = try! XCTUnwrap(item.menu)

        controller.menuNeedsUpdate(menu)

        // Item 0 is the identity header NSMenuToolbarItem consumes and never shows.
        XCTAssertFalse(menu.items[0].isEnabled)
        XCTAssertEqual(Array(menu.items[1...2].map(\.title)), ["Home", "Help"])
        XCTAssertEqual(menu.items[1].state, .on, "this window is Home")
        XCTAssertEqual(menu.items[2].state, .off)
        for (row, place) in zip(menu.items[1...2], WorkspacePlace.allCases) {
            XCTAssertNotNil(row.action, place.name)
            XCTAssertTrue(row.target === controller, place.name)
            XCTAssertNotNil(row.image, place.name)
        }

        let reserved = Set(ReservedWorkspace.allCases.map(\.id))
        for row in menu.items.dropFirst(3) {
            guard let id = row.representedObject as? UUID else { continue }
            XCTAssertFalse(reserved.contains(id), "\(row.title) is already in the places section")
        }

        // Rebuilding replaces the rows rather than appending to them.
        let count = menu.items.count
        controller.menuNeedsUpdate(menu)
        XCTAssertEqual(menu.items.count, count)
    }

    func testSidebarToolbarButtonPublishesVisibilityState() {
        let target = ActionTarget()
        let button = ToolbarToggleButton(
            symbol: "sidebar.left",
            target: target,
            action: #selector(ActionTarget.activate(_:)))

        button.setOn(true)
        XCTAssertEqual(button.state, .on)
        XCTAssertEqual(button.accessibilityValue() as? String, "On")
        XCTAssertGreaterThan(button.layer?.backgroundColor?.alpha ?? 0, 0)
    }

    /// The dot is an overlay, never a tile: an idle segment that needs attention must still leave the
    /// deck's shared surface as the only background in the group.
    func testSegmentStatusPaintsADotWithoutTintingTheSegment() {
        let deck = makeToolbarDeck()
        let button = try! XCTUnwrap(deck.button(for: .extensions))

        XCTAssertEqual(deck.status(for: .extensions), .none)
        deck.setStatus(.attention, for: .extensions)

        XCTAssertEqual(deck.status(for: .extensions), .attention)
        XCTAssertEqual(button.layer?.backgroundColor?.alpha, 0)
        XCTAssertEqual(button.layer?.borderWidth, 0)
        XCTAssertEqual(deck.status(for: .artifacts), .none)
    }

    /// A disabled control cannot be acted on, so it must not keep asking to be.
    func testDisabledSegmentDropsItsStatusDot() {
        let deck = makeToolbarDeck()
        deck.setStatus(.attention, for: .tasks)
        deck.setEnabled(false, for: .tasks)

        let dot = try! XCTUnwrap(deck.button(for: .tasks)?.layer?.sublayers?.last)
        XCTAssertTrue(dot.isHidden)
    }

    func testTasksSegmentBadgesAgentStartedProcessesWithoutScheduledTasks() async {
        let (controller, toolbar, bridge) = makeToolbarController()
        let deck = try! XCTUnwrap(controller.toolbar(
            toolbar,
            itemForItemIdentifier: NSToolbarItem.Identifier("workspace.utilityDeck"),
            willBeInsertedIntoToolbar: true)?.view as? ToolbarUtilityDeck)
        let source = BackgroundProcessSource(bridgeID: bridge.bridgeID, access: .codexSubscription)
        defer { BackgroundProcessStore.shared.clear(source) }

        BackgroundProcessStore.shared.replace([
            BackgroundProcess(
                pid: 987_654,
                label: "vite",
                command: "vite --port 5173",
                ageSeconds: 30,
                detached: true,
                adopted: false,
                source: source),
        ], for: source)
        await drainMainQueue()

        XCTAssertEqual(deck.status(for: .tasks), .active)
        XCTAssertTrue(
            deck.button(for: .tasks)?.toolTip?.contains("Agent-started background work") == true)
    }

    /// `NSButton` is a flipped view, so its backing layer is flipped too — the first cut of the dot
    /// used maxY and landed under the icon instead of above it.
    func testStatusDotSitsInTheSegmentsTopTrailingCorner() {
        let deck = makeToolbarDeck()
        deck.setStatus(.attention, for: .providers)
        let button = try! XCTUnwrap(deck.button(for: .providers))
        deck.layoutSubtreeIfNeeded()
        button.layoutSubtreeIfNeeded()

        let dot = try! XCTUnwrap(button.layer?.sublayers?.last)
        XCTAssertFalse(dot.isHidden)
        XCTAssertGreaterThan(dot.frame.minX, button.bounds.midX, "dot should be trailing")
        let topHalf = button.isFlipped
            ? dot.frame.maxY < button.bounds.midY
            : dot.frame.minY > button.bounds.midY
        XCTAssertTrue(topHalf, "dot should sit above the symbol, not below it")
    }

    /// `NSToolbarItem` builds its default overflow row from the ITEM's target/action, which is nil
    /// when a custom view owns the click — so every view-backed control here needs an explicit one
    /// or it silently does nothing once the window narrows.
    func testViewBackedPanelItemsCarryWorkingOverflowRows() {
        let (controller, toolbar, _) = makeToolbarController()

        for identifier in ["workspace.sidebarToggle", "window.terminal", "window.inspectorRegion"] {
            let item = try! XCTUnwrap(controller.toolbar(
                toolbar,
                itemForItemIdentifier: NSToolbarItem.Identifier(identifier),
                willBeInsertedIntoToolbar: true))
            let row = try! XCTUnwrap(item.menuFormRepresentation, identifier)
            XCTAssertFalse(row.title.isEmpty, identifier)
            XCTAssertNotNil(row.action, identifier)
            XCTAssertTrue(row.target === controller, identifier)
        }
    }

    /// Every segment's menu is rebuilt from the live stores when it opens, so the shape is what's
    /// worth pinning: a disabled header, actionable rows wired to the controller, and a trailing
    /// row that OPENS the window (never toggles it — a menu row that closed the window it names
    /// would be a trap).
    func testEverySegmentCarriesAContextMenuOfControllerBackedActions() {
        let (controller, toolbar, _) = makeToolbarController()
        let deck = try! XCTUnwrap(controller.toolbar(
            toolbar,
            itemForItemIdentifier: NSToolbarItem.Identifier("workspace.utilityDeck"),
            willBeInsertedIntoToolbar: true)?.view as? ToolbarUtilityDeck)

        for control in deck.controls {
            let menu = try! XCTUnwrap(
                deck.button(for: control)?.menu as? ToolbarSegmentMenu, control.label)
            XCTAssertEqual(menu.control, control)

            controller.rebuildSegmentMenu(menu)
            XCTAssertGreaterThan(menu.items.count, 1, control.label)
            XCTAssertFalse(menu.items[0].isEnabled, "\(control.label): leads with a header")
            XCTAssertEqual(menu.items.last?.title, "Open \(control.label)", control.label)
            for item in menu.items where item.action != nil {
                XCTAssertTrue(item.target === controller, "\(control.label): \(item.title)")
            }
            // Rebuilding must replace the rows, never append to them.
            let count = menu.items.count
            controller.rebuildSegmentMenu(menu)
            XCTAssertEqual(menu.items.count, count, control.label)
        }
    }

    func testProvidersSegmentMenuListsEveryLaneAndOffersARecheck() {
        let (controller, _, _) = makeToolbarController()
        let menu = ToolbarSegmentMenu(control: .providers)

        controller.rebuildSegmentMenu(menu)

        let titles = menu.items.map(\.title)
        for access in ModelAccess.allCases {
            // A lane reads either as its own name or as a verb applied to it ("Connect Claude
            // subscription…"), so match on containment rather than a prefix.
            XCTAssertTrue(titles.contains { $0.contains(access.displayName) }, access.displayName)
        }
        XCTAssertTrue(titles.contains("Check Accounts Again"))
    }

    /// A row that offers to connect an account carries the lane it means. A typo'd raw value would
    /// leave a row that looks live and silently does nothing.
    func testProviderActionRowsCarryADecodableLane() {
        let (controller, _, _) = makeToolbarController()
        let menu = ToolbarSegmentMenu(control: .providers)

        controller.rebuildSegmentMenu(menu)

        var actionRows = 0
        for item in menu.items {
            guard let raw = item.representedObject as? String else { continue }
            actionRows += 1
            XCTAssertNotNil(ModelAccess(rawValue: raw), item.title)
            XCTAssertTrue(item.title.hasPrefix("Connect ") || item.title.hasPrefix("Reconnect "),
                          item.title)
        }
        // Nothing to assert about the count — it depends on this machine's real accounts — but a
        // row carrying a lane must always be one of the two connect verbs.
        XCTAssertGreaterThanOrEqual(actionRows, 0)
    }

    /// The dot says an MCP server needs sign-in; this is the row that fixes it without a detour
    /// through the Extensions window.
    func testExtensionsMenuOffersSignInForAServerAwaitingOAuth() {
        let (controller, _, bridge) = makeToolbarController()
        let store = ExtensionsStore.shared
        let access = bridge.currentModelAccess
        let name = "toolbar-fixture-\(UUID().uuidString.prefix(8))"
        let saved = store.mcpServers
        defer {
            store.mcpServers = saved
            store.setConnState(name, .unknown, for: access)
        }
        store.mcpServers.append(MCPServer(name: name, enabled: true))
        store.setConnState(name, .needsAuth, for: access)

        let menu = ToolbarSegmentMenu(control: .extensions)
        controller.rebuildSegmentMenu(menu)

        let row = try! XCTUnwrap(menu.items.first { $0.representedObject as? String == name })
        XCTAssertEqual(row.title, "Sign In to \(name)…")
        XCTAssertTrue(row.target === controller)
        XCTAssertNotNil(row.action)

        // Connected instead: a status row that reveals it in the panel, carrying no payload.
        store.setConnState(name, .connected(3), for: access)
        controller.rebuildSegmentMenu(menu)
        let status = try! XCTUnwrap(menu.items.first { $0.title == name })
        XCTAssertNil(status.representedObject)
        XCTAssertEqual(status.state, .on)
    }

    /// The Extensions dot and the Extensions menu must describe the same lane — a warning the menu
    /// can neither explain nor clear is noise.
    func testMCPAttentionIsScopedToOneLane() {
        let store = ExtensionsStore.shared
        let name = "lane-fixture-\(UUID().uuidString.prefix(8))"
        defer {
            store.setConnState(name, .unknown, for: .anthropicAPI)
            store.setConnState(name, .unknown, for: .openAIAPI)
        }
        store.setConnState(name, .needsAuth, for: .anthropicAPI)

        XCTAssertEqual(store.mcpServersNeedingAttention(for: .anthropicAPI), [name])
        XCTAssertTrue(store.mcpServersNeedingAttention(for: .openAIAPI).isEmpty)
    }

    func testTasksSegmentMenuAlwaysOffersTaskCreation() {
        let (controller, _, _) = makeToolbarController()
        let menu = ToolbarSegmentMenu(control: .tasks)

        controller.rebuildSegmentMenu(menu)

        XCTAssertTrue(menu.items.map(\.title).contains("New Task…"))
    }

    /// A control that MOVES out from under a stationary pointer never receives `mouseExited`, so the
    /// grey hover fill used to stay painted after toggling a panel — the right-panel button slides
    /// with the inspector on every toggle. Moving the frame must re-derive hover from the pointer.
    func testMovingTheControlOutFromUnderThePointerClearsItsHoverFill() {
        let target = ActionTarget()
        let button = ToolbarToggleButton(
            symbol: "sidebar.right", target: target, action: #selector(ActionTarget.activate(_:)))
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 60))
        host.addSubview(button)

        button.applyHover(true)
        XCTAssertTrue(button.isShowingHoverSurface)
        XCTAssertGreaterThan(button.layer?.backgroundColor?.alpha ?? 0, 0, "hover paints a fill")

        // The move itself is the event: no pointer traffic, just a new frame.
        button.setFrameOrigin(NSPoint(x: 240, y: 0))

        XCTAssertFalse(button.isShowingHoverSurface, "hover must not survive the control moving")
        XCTAssertEqual(button.layer?.backgroundColor?.alpha, 0, "no stranded grey fill")
    }

    /// The same move must not disturb a real on-state tile.
    func testMovingTheControlKeepsItsSelectedTile() {
        let target = ActionTarget()
        let button = ToolbarToggleButton(
            symbol: "sidebar.right", target: target, action: #selector(ActionTarget.activate(_:)))
        NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 60)).addSubview(button)
        button.setOn(true)

        button.setFrameOrigin(NSPoint(x: 240, y: 0))

        XCTAssertEqual(button.state, .on)
        XCTAssertGreaterThan(button.layer?.backgroundColor?.alpha ?? 0, 0)
    }

    private func makeToolbarController() -> (WorkspaceToolbarController, NSToolbar, AgentBridge) {
        let support = FileManager.default.temporaryDirectory
            .appendingPathComponent("mechanician-toolbar-\(UUID().uuidString)", isDirectory: true)
        let bridge = AgentBridge(settingsBaseOverride: support, environmentOverride: [:])
        let split = NSSplitViewController()
        split.addSplitViewItem(NSSplitViewItem(viewController: NSViewController()))
        split.addSplitViewItem(NSSplitViewItem(viewController: NSViewController()))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 640),
                              styleMask: [.titled], backing: .buffered, defer: false)
        let controller = WorkspaceToolbarController(bridge: bridge, splitVC: split, window: window)
        return (controller, controller.makeToolbar(), bridge)
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 200),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false)
        window.alphaValue = 0
        window.isReleasedWhenClosed = false
        return window
    }

    /// Run layout to a fixed point, the way a live window's display cycle does.
    private func settleLayout(_ view: NSView, in host: NSView, passes: Int = 4) {
        for _ in 0..<passes {
            host.layoutSubtreeIfNeeded()
            view.needsLayout = true
            view.layoutSubtreeIfNeeded()
        }
    }

    private func makeToolbarDeck() -> ToolbarUtilityDeck {
        makeDeck(ToolbarUtilityDeck.Control.browsers, dividerBefore: .artifacts)
    }

    private func makePlacesDeck() -> ToolbarUtilityDeck {
        makeDeck(ToolbarUtilityDeck.Control.places)
    }

    private func makeDeck(
        _ controls: [ToolbarUtilityDeck.Control],
        dividerBefore: ToolbarUtilityDeck.Control? = nil
    ) -> ToolbarUtilityDeck {
        let target = ActionTarget()
        let action = #selector(ActionTarget.activate(_:))
        return ToolbarUtilityDeck(
            controls: controls,
            dividerBefore: dividerBefore,
            menuTitle: "Deck",
            target: target,
            actions: Dictionary(uniqueKeysWithValues: controls.map { ($0, action) }))
    }

    private func drainMainQueue(passes: Int = 4) async {
        for _ in 0..<passes { await Task.yield() }
    }

    /// Every toolbar button had a tooltip set in code, reported it correctly as accessibility help,
    /// and showed nothing on hover — for builds, while it was reported repeatedly. The cause was
    /// `updateTrackingAreas` calling `trackingAreas.forEach(removeTrackingArea)`, which took
    /// AppKit's own tracking with it, including whatever shows a tooltip.
    ///
    /// MEASURED, not assumed: setting `toolTip` on an `NSView` installs a tracking area (0 → 1),
    /// and `trackingAreas.forEach(removeTrackingArea)` removes it while leaving the STRING in
    /// place. That split is the whole bug — the accessibility layer reads the property directly, so
    /// VoiceOver reported every tip correctly while nothing appeared on hover.
    ///
    /// The five utility segments were the visible casualty, because they are the only toolbar
    /// buttons whose tip lives ONLY on the button. Sidebar, Terminal and Inspector kept theirs
    /// because it is also set on the `NSToolbarItem`, whose viewer is a different view.
    func testAToolbarButtonKeepsTheTrackingThatShowsItsTooltip() {
        let target = ActionTarget()
        let button = ToolbarToggleButton(
            symbol: "puzzlepiece.extension", target: target,
            action: #selector(ActionTarget.activate(_:)))
        button.frame = NSRect(x: 0, y: 0, width: 28, height: 28)

        button.toolTip = "Show Providers (⌥⌘A)"
        let withTooltip = button.trackingAreas.count
        XCTAssertGreaterThan(withTooltip, 0, "setting toolTip installs the tracking that shows it")

        button.updateTrackingAreas()

        XCTAssertGreaterThan(
            button.trackingAreas.count, 1,
            "laying the control out must leave the tooltip's tracking alongside its own hover "
            + "area — wiping both is why five icon-only segments never showed a tip")
    }

    /// And it must not leak its own: `updateTrackingAreas` runs on every layout pass.
    func testLayingOutRepeatedlyDoesNotAccumulateHoverTracking() {
        let target = ActionTarget()
        let button = ToolbarToggleButton(
            symbol: "sidebar.left", target: target, action: #selector(ActionTarget.activate(_:)))
        button.frame = NSRect(x: 0, y: 0, width: 28, height: 28)

        button.updateTrackingAreas()
        let afterFirst = button.trackingAreas.count
        for _ in 0..<5 { button.updateTrackingAreas() }

        XCTAssertEqual(
            button.trackingAreas.count, afterFirst,
            "one hover area per control, however many times it is laid out")
    }
}
