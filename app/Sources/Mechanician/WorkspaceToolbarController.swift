import AppKit
import SwiftUI
import Combine

/// A SwiftUI `openWindow` action captured from the view tree so AppKit code (this toolbar) can open
/// the utility Window scenes (Artifacts / Ambient) — there's no AppKit equivalent for a SwiftUI
/// `Window(id:)`. Set once from `DetailView.onAppear`; it's the same app-level action for every view.
@MainActor var appOpenWindow: OpenWindowAction?

/// The undo stack a library action should register on: the one belonging to the window the action
/// happened in.
///
/// Resolved from the bridge's own window rather than `NSApp.keyWindow`, so it is safe to call from
/// a menu action and from a view alike. The keyWindow read that is unsafe is the one during
/// command-body evaluation; see the note on `activeMenuBridge`.
///
/// Deliberately **not** `window.undoManager`. That consults the first responder first, and the
/// composer is an `NSTextView` with its own undo, so a move performed while the composer had focus
/// would register on the composer's text-editing stack and ⌘Z would undo the wrong thing.
@MainActor func workspaceUndoManager(for bridge: AgentBridge?) -> UndoManager? {
    (bridge?.window?.delegate as? WorkspaceToolbarController)?.workspaceUndoManager
}

/// `appOpenWindow` is only wired once `DetailView.onAppear` has run, so anything that can fire
/// before a workspace window has mounted must not assume it exists: a notification click, a
/// Spotlight result, and soon a `mechanician://` link can all arrive on a cold launch. Retry
/// briefly rather than dropping the request.
///
/// Prefer `UtilityWindowVisibility.show(_:open:)` with this as the `open` body when the target is a
/// utility scene, so an already-retained window is reused instead of duplicated.
@MainActor func openAppWindowWhenReady(id: String, attemptsLeft: Int = 12) {
    if let open = appOpenWindow {
        open(id: id)
    } else if attemptsLeft > 0 {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            openAppWindowWhenReady(id: id, attemptsLeft: attemptsLeft - 1)
        }
    }
}

/// Owns a workspace window's `NSToolbar` and the sidebar-collapse wiring. This is the genuinely
/// Mac-native toolbar the SwiftUI bridge couldn't express: a real `NSTrackingSeparatorToolbarItem`
/// against OUR `NSSplitView` (Mail-style split — sidebar toggle over the sidebar, folder + title over
/// the content), active-panel highlight, and user customization. Retained by `makeWorkspaceWindow`
/// (NSToolbar.delegate is weak); `invalidate()` on window close drops the Combine subscriptions.
@MainActor
final class WorkspaceToolbarController: NSObject, NSToolbarDelegate, NSMenuDelegate, NSWindowDelegate {
    private let bridge: AgentBridge
    private weak var splitVC: NSSplitViewController?
    private weak var window: NSWindow?
    private var cancellables = Set<AnyCancellable>()

    /// This workspace's undo stack, for library actions: moving a conversation between workspaces
    /// today, deleting one later. One per window, because a workspace window is the thing a person
    /// thinks they are acting in, and a shared stack would let ⌘Z in one window reverse something
    /// that happened in another.
    ///
    /// Vended through `windowWillReturnUndoManager`, which AppKit consults **only** when the first
    /// responder does not supply its own. The composer is an `NSTextView` with `allowsUndo`, so
    /// while you are typing, ⌘Z still undoes typing — exactly as it does in every other Mac app.
    /// Register library actions against this object directly (see `workspaceUndoManager(for:)`)
    /// rather than through `window.undoManager`, or a move performed while the composer has focus
    /// would land on the composer's stack.
    ///
    /// The rule this stack enforces, stated once in GUIDE.md: ⌘Z puts back anything Mechanician
    /// removed or moved, and never touches what an agent did.
    let workspaceUndoManager = UndoManager()

    private(set) var utilityDeck: ToolbarUtilityDeck?
    /// Home and Help as their own deck beside the workspace switcher.
    ///
    /// Deliberately not three more segments in the browsers deck. A browser segment means "show me
    /// that panel"; these mean "take me there", and they are the same three places the launcher
    /// already calls out above its grid. Sitting them next to the switcher — the control that says
    /// where you are — is what makes "you are here" the obvious reading of a lit segment.
    private(set) var placesDeck: ToolbarUtilityDeck?
    private var sidebarItem: NSToolbarItem?
    private var sidebarButton: ToolbarToggleButton?
    private var folderItem: NSMenuToolbarItem?
    private var workspaceActionsItem: NSMenuToolbarItem?
    private var titleLabel: NSTextField?
    private var terminalItem: NSToolbarItem?
    private var terminalButton: ToolbarToggleButton?
    private var inspectorButton: ToolbarToggleButton?
    // The overflow rows for the three view-backed panel controls, kept so their checkmarks track
    // the panels they toggle.
    private var sidebarMenuItem: NSMenuItem?
    private var terminalMenuItem: NSMenuItem?
    private var inspectorMenuItem: NSMenuItem?
    private var inspectorRegionItem: NSToolbarItem?
    private var inspectorRegionView: InspectorToolbarRegionView?
    private weak var toolbar: NSToolbar?

    private static let sidebarToggle = NSToolbarItem.Identifier("workspace.sidebarToggle")
    private static let convTitle     = NSToolbarItem.Identifier("workspace.title")
    private static let folderMenu    = NSToolbarItem.Identifier("workspace.folderMenu")
    private static let workspaceActions = NSToolbarItem.Identifier("workspace.actions")
    private static let trackingSep   = NSToolbarItem.Identifier("workspace.trackingSeparator")
    private static let utilityDeck   = NSToolbarItem.Identifier("workspace.utilityDeck")
    private static let placesDeck    = NSToolbarItem.Identifier("workspace.placesDeck")
    private static let terminal      = NSToolbarItem.Identifier("window.terminal")
    private static let inspectorRegion = NSToolbarItem.Identifier("window.inspectorRegion")

    private var sidebarSplitItem: NSSplitViewItem? { splitVC?.splitViewItems.first }

    init(bridge: AgentBridge, splitVC: NSSplitViewController, window: NSWindow) {
        self.bridge = bridge
        self.splitVC = splitVC
        self.window = window
        super.init()
    }

    func makeToolbar() -> NSToolbar {
        let tb = NSToolbar(identifier: "MechanicianWorkspaceToolbar")
        tb.delegate = self
        tb.allowsUserCustomization = true
        // Icon-only. The sidebar toggle carries its own "Sidebar" title on the BUTTON (not the item
        // caption), so it still reads as text even in icon-only mode; everything else is just an icon.
        // (No autosavesConfiguration: it would restore a stale display mode over this fixed design.)
        tb.displayMode = .iconOnly
        self.toolbar = tb
        updatePlaceWindowRegistration(projectID: bridge.projectID, cwd: bridge.cwd)
        observe()
        return tb
    }

    func invalidate() { cancellables.removeAll() }

    /// AppKit asks the delegate for an undo manager only when the first responder does not supply
    /// one, so this hands library actions a stack without taking ⌘Z away from the composer.
    ///
    /// Deliberately not `CommandGroup(replacing: .undoRedo)`. That moves menu-item enablement off
    /// AppKit's own validation and onto published state, and a disabled menu item does not perform
    /// its key equivalent — which would break ⌘Z for every text field in the app. Vending the
    /// manager here keeps AppKit's titles ("Undo Move Conversation") and validation for free.
    func windowWillReturnUndoManager(_ window: NSWindow) -> UndoManager? {
        self.window === window ? workspaceUndoManager : nil
    }

    /// SwiftUI's layer-backed hosting surface can occasionally retain an empty backing store after
    /// a native live resize, even though the transcript model and scroll view are still intact. Ask
    /// AppKit to perform one normal layout/display pass when the drag ends. This deliberately does
    /// not mutate transcript state or scrolling; TranscriptPinController remains the sole scroll
    /// authority.
    func windowDidEndLiveResize(_ notification: Notification) {
        publishContentSize()
        guard let window, notification.object as? NSWindow === window else { return }
        let splitView = splitVC?.view
        splitView?.needsLayout = true
        splitView?.layoutSubtreeIfNeeded()
        for item in splitVC?.splitViewItems ?? [] {
            let hostedView = item.viewController.view
            hostedView.needsLayout = true
            hostedView.layoutSubtreeIfNeeded()
            hostedView.needsDisplay = true
        }
        window.contentView?.needsDisplay = true
        window.contentView?.displayIfNeeded()
        saveWindowLayout()
    }

    // Non-drag size/position changes (green-button zoom, full-screen exit, tiling, programmatic)
    // never fire windowDidEndLiveResize, so capture them here too — otherwise the remembered frame
    // reflects only the last *drag*, not the size the window is actually left at.
    func windowDidResize(_ notification: Notification) {
        publishContentSize()
        guard let window, !window.inLiveResize else { return }   // live drag handled above
        saveWindowLayout()
    }

    /// The size the status bar shows. Published on every resize INCLUDING live ones, because a
    /// number that only catches up when you let go of the mouse is not a readout, it is a lag.
    func publishContentSize() {
        guard let window else { return }
        let size = window.contentLayoutRect.size
        // The titlebar's height, from the window rather than from a SwiftUI safe area: these columns
        // are hosted inside an AppKit split view and have no safe area of their own, so the inset
        // read as 0 and a background meant to stop below the toolbar painted right through it.
        // From the FRAME, not from `contentView.bounds`: the content view is not laid out when this
        // first runs, so bounds was 0 and the inset computed to 0 — which is why an overlay sized by
        // it covered nothing and the seam survived a third attempt.
        let inset = max(0, window.frame.height - size.height)
        if bridge.titlebarInset != inset { bridge.titlebarInset = inset }
        guard bridge.windowContentSize != size else { return }
        bridge.windowContentSize = size
    }

    // MARK: - FR-96: per-workspace window frame + sidebar width persistence
    //
    // Window frame (size + position) and sidebar width are remembered per workspace, so reopening a
    // workspace restores it exactly as left instead of the fixed 1440×920 / 340 defaults. Keyed by the
    // same per-workspace identity as launch-restore (a topic project by id, a folder by its project id
    // or cwd, else Home). Off-screen recovery is free: AppKit's setFrameUsingName constrains a restored
    // frame to the currently visible screens.

    private static let defaultContentSize = NSSize(width: 1440, height: 920)
    // Fresh windows start just wide enough for the conversation header and a readable transcript
    // preview. This is a fallback only: a saved session or the person's per-workspace divider
    // width still wins unchanged in `applySidebarWidth`.
    private static let defaultSidebarWidth: CGFloat = 340
    private var appliedLayoutKey: String?
    /// The divider has no useful width while its item is collapsed. Retain the last expanded value
    /// so closing a sidebar does not also forget how wide it should be when it opens again.
    private var lastExpandedSidebarWidth = defaultSidebarWidth
    /// Split-view notifications also fire while an initial/restored divider position is being
    /// installed. Suppress that edge so an intermediate AppKit minimum cannot overwrite the value
    /// that is still being restored.
    private var isApplyingSidebarWidth = false
    private var sidebarWidthApplicationGeneration = 0
    /// SwiftUI can finish establishing the hosted sidebar's constraints only after the native
    /// window becomes key. Retry the initial width once at that point, so a fresh 340-point
    /// default is not overwritten by the split item's 220-point construction minimum.
    private var initialSidebarWidthRetry: (
        layoutKey: String,
        preferred: Double?,
        persistenceSuppressionGeneration: Int
    )?
    private var isCompletingInitialSidebarWidth = false
    /// Frame restoration and split construction both emit resize notifications. Suppress sidebar
    /// preference writes until the intended divider has been installed, so neither a 220-point
    /// construction minimum nor an outgoing workspace's width can become the incoming preference.
    private var isSuppressingSidebarWidthPersistence = false
    private var sidebarWidthPersistenceSuppressionGeneration = 0

    private var workspaceLayoutKey: String {
        if let pid = bridge.inspectorPreferenceWorkspaceID { return pid.uuidString }
        if !bridge.cwd.isEmpty {
            return "cwd:\(bridge.cwd)"
        }
        return "home"
    }
    private func frameName(_ key: String) -> String { "mech.ws.frame.\(key)" }
    private func sidebarKey(_ key: String) -> String { "mech.ws.sidebar.\(key)" }

    private var sidebarWidthRange: ClosedRange<Double> {
        let minimum = Double(sidebarSplitItem?.minimumThickness ?? 220)
        let maximum = Double(sidebarSplitItem?.maximumThickness ?? 420)
        return minimum...max(minimum, maximum)
    }

    /// Resolve only the width preference, separate from the AppKit divider mutation below so the
    /// fallback precedence stays testable: exact session state, then the person's older saved
    /// width, then the product default for genuinely fresh windows.
    static func resolvedSidebarWidth(
        preferred: Double?,
        legacy: Double?,
        range: ClosedRange<Double>
    ) -> CGFloat {
        if let preferred, range.contains(preferred) { return CGFloat(preferred) }
        if let legacy, range.contains(legacy) { return CGFloat(legacy) }
        return defaultSidebarWidth
    }

    @discardableResult
    private func beginSidebarWidthPersistenceSuppression() -> Int {
        sidebarWidthPersistenceSuppressionGeneration &+= 1
        isSuppressingSidebarWidthPersistence = true
        return sidebarWidthPersistenceSuppressionGeneration
    }

    /// Keep the guard through one more main-queue turn: AppKit can publish its split resize just
    /// after `setPosition`, and that notification should observe the installed divider, not race it.
    private func finishSidebarWidthPersistenceSuppression(_ generation: Int) {
        DispatchQueue.main.async { [weak self] in
            guard let self,
                  self.sidebarWidthPersistenceSuppressionGeneration == generation else { return }
            // A newer divider application can supersede the one that requested this release.
            // Let that newest queued application finish first, then release the same guard rather
            // than stranding persistence suppression on a stale generation.
            guard !self.isApplyingSidebarWidth else {
                self.finishSidebarWidthPersistenceSuppression(generation)
                return
            }
            self.isSuppressingSidebarWidthPersistence = false
        }
    }

    private static let maximumSidebarContainerOverhead: CGFloat = 64

    /// The ledger stores the sidebar content view's width, while `NSSplitView.setPosition` accepts
    /// the trailing coordinate of AppKit's arranged container. On macOS 26 that container is eight
    /// points wider than its content, so treating the content width as the divider coordinate
    /// shrinks the restored sidebar on every relaunch.
    static func sidebarDividerPosition(
        forExpandedWidth width: CGFloat,
        arrangedContainerFrame: NSRect?,
        contentFrame: NSRect?,
        splitBoundsMinX: CGFloat
    ) -> CGFloat {
        let fallback = splitBoundsMinX + width
        guard let arrangedContainerFrame, let contentFrame,
              arrangedContainerFrame.minX.isFinite,
              arrangedContainerFrame.width.isFinite,
              contentFrame.width.isFinite else { return fallback }
        let overhead = arrangedContainerFrame.width - contentFrame.width
        guard overhead >= 0,
              overhead <= maximumSidebarContainerOverhead else { return fallback }
        let position = arrangedContainerFrame.minX + width + overhead
        return position.isFinite ? position : fallback
    }

    /// Restore this workspace's saved frame + sidebar width, or fall back to the defaults. Called once
    /// after the window is built and its delegate is set, before `observe()` and before ordering front.
    func applyInitialLayout(restoring layout: WorkspaceWindowLayout? = nil) {
        // Before the first frame, so the inspector never paints one frame of surface under the
        // toolbar on the way in.
        defer { publishContentSize() }
        guard let window else { return }

        // Arm this before setting a frame/content size. AppKit can synchronously send a resize
        // notification during that mutation, and the resulting startup minimum must not overwrite
        // a real legacy sidebar width before `applySidebarWidth` has read it below.
        let initialLayoutKey = workspaceLayoutKey
        let preferredSidebarWidth = layout?.validSidebarWidth(sidebarWidthRange)
        let suppressionGeneration = beginSidebarWidthPersistenceSuppression()
        let waitsForFirstKey = !window.isKeyWindow
        initialSidebarWidthRetry = waitsForFirstKey
            ? (initialLayoutKey, preferredSidebarWidth, suppressionGeneration)
            : nil
        isCompletingInitialSidebarWidth = false

        // A session snapshot is the exact state of this native window. The existing per-workspace
        // preferences remain the compatibility/fallback path for an older ledger and for a window
        // opened outside session replay.
        if let restoredFrame = layout?.frame?.rect {
            applyRestoredFrame(restoredFrame, to: window)
        } else if !window.setFrameUsingName(frameName(workspaceLayoutKey)) {
            window.setContentSize(Self.defaultContentSize)
        }
        appliedLayoutKey = initialLayoutKey
        if waitsForFirstKey {
            applySidebarWidth(preferred: preferredSidebarWidth)
        } else {
            applySidebarWidth(preferred: preferredSidebarWidth) { [weak self] in
                self?.finishSidebarWidthPersistenceSuppression(suppressionGeneration)
            }
        }
    }

    /// Capture only a normal (non-miniaturized, non-full-screen) frame. Native tabs can be hidden
    /// while still being live session windows, so visibility is deliberately not a precondition.
    /// `frameWindow` lets session capture use one representative frame for every tab in a group.
    func windowLayoutSnapshot(frameWindow: NSWindow? = nil) -> WorkspaceWindowLayout {
        captureExpandedSidebarWidth()
        let frameSource = frameWindow ?? window
        let normalFrame: WorkspaceWindowFrame?
        if let frameSource,
           !frameSource.isMiniaturized,
           !frameSource.styleMask.contains(.fullScreen) {
            normalFrame = WorkspaceWindowFrame(frameSource.frame)
        } else {
            normalFrame = nil
        }
        return WorkspaceWindowLayout(
            frame: normalFrame,
            showsSidebar: bridge.showSidebar,
            sidebarWidth: Double(lastExpandedSidebarWidth),
            showsInspector: bridge.showInspector,
            inspectorPreferredWidth: bridge.inspectorPreferredWidth,
            showsTerminal: bridge.showTerminal,
            terminalHeight: bridge.terminalHeight)
    }

    private func applyRestoredFrame(_ frame: NSRect, to window: NSWindow) {
        // Pick the screen containing most of the old frame. If the display disappeared, AppKit's
        // normal frame constraint on the remaining screen keeps the titlebar reachable.
        let screen = NSScreen.screens.max { lhs, rhs in
            intersectionArea(frame, lhs.visibleFrame) < intersectionArea(frame, rhs.visibleFrame)
        }
        let reachable = screen.map { window.constrainFrameRect(frame, to: $0) } ?? frame
        window.setFrame(reachable, display: false)
    }

    private func intersectionArea(_ lhs: NSRect, _ rhs: NSRect) -> CGFloat {
        let intersection = lhs.intersection(rhs)
        guard !intersection.isNull else { return 0 }
        return intersection.width * intersection.height
    }

    /// Persist the current frame + sidebar width under the active workspace's key.
    func saveWindowLayout() { persistLayout(forKey: workspaceLayoutKey) }

    private func persistLayout(forKey key: String) {
        persistLastExpandedSidebarWidth(forKey: key)
        guard let window, window.isVisible, !window.isMiniaturized,
              !window.styleMask.contains(.fullScreen) else { return }
        window.saveFrame(usingName: frameName(key))
    }

    private func persistLastExpandedSidebarWidth(forKey key: String) {
        // A frame/content-size mutation can fire before the split has installed the retained
        // width. Do not turn its temporary 220-point construction minimum—or the pre-apply
        // fallback in `lastExpandedSidebarWidth`—into a saved user preference.
        guard !isSuppressingSidebarWidthPersistence else { return }
        captureExpandedSidebarWidth()
        let width = Double(lastExpandedSidebarWidth)
        guard sidebarWidthRange.contains(width) else { return }
        UserDefaults.standard.set(width, forKey: sidebarKey(key))
    }

    private func captureExpandedSidebarWidth() {
        guard !isApplyingSidebarWidth,
              !isSuppressingSidebarWidthPersistence,
              let item = sidebarSplitItem,
              !item.isCollapsed else { return }
        let width = Double(item.viewController.view.frame.width)
        guard sidebarWidthRange.contains(width) else { return }
        lastExpandedSidebarWidth = CGFloat(width)
    }

    private func splitViewDidResize() {
        // The hosted SwiftUI sidebar first lays out at the native 220-point minimum. That is not a
        // user resize and must never be persisted over the initial restored/default width before
        // the first-key retry below can install it.
        guard !isApplyingSidebarWidth,
              !isSuppressingSidebarWidthPersistence else { return }
        let before = lastExpandedSidebarWidth
        captureExpandedSidebarWidth()
        guard lastExpandedSidebarWidth != before else { return }
        UserDefaults.standard.set(
            Double(lastExpandedSidebarWidth),
            forKey: sidebarKey(workspaceLayoutKey))
    }

    /// Kept internal so the native-layout integration test can reproduce a queued live restore
    /// superseding the post-key retry; app code reaches this through the lifecycle paths below.
    func applySidebarWidth(
        preferred: Double? = nil,
        completion: (() -> Void)? = nil
    ) {
        guard let splitVC else {
            completion?()
            return
        }
        let legacy = UserDefaults.standard.object(forKey: sidebarKey(workspaceLayoutKey)) as? Double
        let target = Self.resolvedSidebarWidth(
            preferred: preferred,
            legacy: legacy,
            range: sidebarWidthRange)
        lastExpandedSidebarWidth = target
        guard bridge.showSidebar else {
            completion?()
            return
        }
        sidebarWidthApplicationGeneration &+= 1
        let generation = sidebarWidthApplicationGeneration
        isApplyingSidebarWidth = true
        // Set after the split view has laid out; AppKit clamps to the sidebar item's min/max thickness.
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                guard generation == self.sidebarWidthApplicationGeneration else {
                    completion?()
                    return
                }
                defer {
                    self.isApplyingSidebarWidth = false
                    completion?()
                }
                guard self.bridge.showSidebar else { return }
                let splitView = splitVC.splitView
                // Resolve the initial split frames before calculating any container overhead for
                // the divider coordinate. This is especially important immediately after a window
                // receives its restored or fresh content size.
                splitVC.view.layoutSubtreeIfNeeded()
                splitView.layoutSubtreeIfNeeded()
                let sidebarItem = self.sidebarSplitItem
                let sidebarIndex = sidebarItem.flatMap { item in
                    splitVC.splitViewItems.firstIndex { $0 === item }
                }
                let arrangedContainerFrame = sidebarIndex.flatMap { index in
                    splitView.arrangedSubviews.indices.contains(index)
                        ? splitView.arrangedSubviews[index].frame
                        : nil
                }
                splitView.setPosition(
                    Self.sidebarDividerPosition(
                        forExpandedWidth: target,
                        arrangedContainerFrame: arrangedContainerFrame,
                        contentFrame: sidebarItem?.viewController.view.frame,
                        splitBoundsMinX: splitView.bounds.minX),
                    ofDividerAt: 0)
                // AppKit is still authoritative and may clamp to min/max. Retain the value it
                // actually installed, but do not treat this programmatic restore as a user resize.
                if let item = self.sidebarSplitItem, !item.isCollapsed {
                    let installed = Double(item.viewController.view.frame.width)
                    if self.sidebarWidthRange.contains(installed) {
                        self.lastExpandedSidebarWidth = CGFloat(installed)
                    }
                }
            }
        }
    }

    /// When a window switches workspace in place, save the outgoing workspace's layout under its own
    /// key, then apply the incoming workspace's saved frame if it has one (otherwise keep the current
    /// size). This keeps each workspace's remembered layout scoped to itself.
    func rebindLayoutForWorkspaceChange() {
        let newKey = workspaceLayoutKey
        guard newKey != appliedLayoutKey else { return }
        // Preserve the outgoing width while the startup guard is still armed. A launch-time
        // workspace switch can otherwise save the temporary split construction width over the
        // departing workspace before its queued divider application has run.
        if let old = appliedLayoutKey { persistLayout(forKey: old) }
        // The late first-key retry belongs only to the workspace that created this native window.
        // Cancel its queued divider application before binding the incoming workspace, then let
        // the normal rebind below own that incoming width.
        initialSidebarWidthRetry = nil
        isCompletingInitialSidebarWidth = false
        sidebarWidthApplicationGeneration &+= 1
        isApplyingSidebarWidth = false
        // A frame restore for the incoming workspace can synchronously resize the window. Protect
        // its saved divider while that resize and the queued divider application settle.
        let suppressionGeneration = beginSidebarWidthPersistenceSuppression()
        let waitsForFirstKey = window?.isKeyWindow == false
        if waitsForFirstKey {
            initialSidebarWidthRetry = (newKey, nil, suppressionGeneration)
        }
        if let window { _ = window.setFrameUsingName(frameName(newKey)) }
        appliedLayoutKey = newKey
        if waitsForFirstKey {
            applySidebarWidth()
        } else {
            applySidebarWidth { [weak self] in
                self?.finishSidebarWidthPersistenceSuppression(suppressionGeneration)
            }
        }
    }

    func windowDidBecomeKey(_ notification: Notification) {
        guard let window,
              notification.object as? NSWindow === window,
              let retry = initialSidebarWidthRetry,
              !isCompletingInitialSidebarWidth else { return }
        guard retry.layoutKey == workspaceLayoutKey else { return }
        isCompletingInitialSidebarWidth = true
        // `makeKeyAndOrderFront` has completed, and one more main-queue turn lets the hosted
        // SwiftUI sidebar publish its final constraints before we install the preserved/default
        // divider position. This is intentionally once-only: later focus changes must not undo a
        // width the person has adjusted.
        DispatchQueue.main.async { [weak self] in
            guard let self, retry.layoutKey == self.workspaceLayoutKey else { return }
            self.applySidebarWidth(preferred: retry.preferred) { [weak self] in
                // The divider mutation itself is queued by `applySidebarWidth`. Keep construction
                // resize notifications suppressed through one additional turn so that mutation—not
                // the initial 220-point split layout—becomes the first width we retain.
                DispatchQueue.main.async { [weak self] in
                    guard let self,
                          self.initialSidebarWidthRetry?.persistenceSuppressionGeneration
                            == retry.persistenceSuppressionGeneration else { return }
                    self.initialSidebarWidthRetry = nil
                    self.isCompletingInitialSidebarWidth = false
                    self.finishSidebarWidthPersistenceSuppression(
                        retry.persistenceSuppressionGeneration)
                }
            }
        }
    }

    func windowDidMove(_ notification: Notification) {
        guard let window, notification.object as? NSWindow === window else { return }
        saveWindowLayout()
    }

    // MARK: - State observation

    private func observe() {
        // Seed the split from the persisted flag, then keep both directions in sync.
        sidebarSplitItem?.isCollapsed = !bridge.showSidebar
        if let splitView = splitVC?.splitView {
            NotificationCenter.default.publisher(
                for: NSSplitView.didResizeSubviewsNotification,
                object: splitView
            )
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.splitViewDidResize() }
            .store(in: &cancellables)
        }
        bridge.$showSidebar.receive(on: RunLoop.main).sink { [weak self] show in
            guard let self, let item = self.sidebarSplitItem else { return }
            self.applyPanelState(show, item: self.sidebarItem, button: self.sidebarButton,
                                 menuItem: self.sidebarMenuItem, name: "Sidebar", shortcut: "⌃⌘S")
            self.setSidebarCollapsed(!show, on: item)
        }.store(in: &cancellables)
        updateSidebarSpacing()
        bridge.$showTerminal.receive(on: RunLoop.main).sink { [weak self] on in
            guard let self else { return }
            self.applyPanelState(on, item: self.terminalItem, button: self.terminalButton,
                                 menuItem: self.terminalMenuItem, name: "Terminal", shortcut: "⌃⌘T")
        }.store(in: &cancellables)
        bridge.$showInspector.receive(on: RunLoop.main).sink { [weak self] on in
            guard let self else { return }
            self.applyPanelState(on, item: self.inspectorRegionItem, button: self.inspectorButton,
                                 menuItem: self.inspectorMenuItem, name: "Inspector", shortcut: "⌥⌘I")
            self.updateInspectorToolbarPosition()
            self.refreshUtilityControls()
        }.store(in: &cancellables)
        bridge.$inspectorExpanded.receive(on: RunLoop.main).sink { [weak self] _ in
            self?.updateInspectorToolbarPosition()
        }.store(in: &cancellables)
        bridge.$inspectorTab.receive(on: RunLoop.main).sink { [weak self] _ in
            self?.refreshUtilityControls()
        }.store(in: &cancellables)
        bridge.$inspectorWidth.receive(on: RunLoop.main).sink { [weak self] _ in
            self?.updateInspectorToolbarPosition()
        }.store(in: &cancellables)
        bridge.$inspectorSeamX.receive(on: RunLoop.main).sink { [weak self] _ in
            self?.updateInspectorToolbarPosition()
        }.store(in: &cancellables)
        UtilityWindowVisibility.shared.$visibleIDs.receive(on: RunLoop.main).sink { [weak self] _ in
            self?.refreshUtilityControls()
        }.store(in: &cancellables)
        WorkspacePlaceWindowPresence.shared.$revision
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.refreshUtilityControls() }
            .store(in: &cancellables)
        // A place is a workspace window, not a retained utility scene. Its presence changes when a
        // newly opened owner becomes key and when that owner closes; refresh every workspace's
        // segment at those native lifecycle boundaries. Close is deferred so the app's will-close
        // observer can remove the departing bridge from `AgentBridge.live` first.
        NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.refreshUtilityControls() }
            .store(in: &cancellables)
        NotificationCenter.default.publisher(for: NSWindow.willCloseNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] note in
                if let closing = note.object as? NSWindow {
                    WorkspacePlaceWindowPresence.shared.unregister(closing)
                }
                DispatchQueue.main.async { [weak self] in self?.refreshUtilityControls() }
            }
            .store(in: &cancellables)
        // Everything the segment dots report. Each store is cheap to read and the recompute touches
        // four buttons, so one shared handler beats four bespoke subscriptions.
        for signal in utilityStatusSignals() {
            signal.receive(on: RunLoop.main).sink { [weak self] _ in
                self?.refreshUtilityControls()
            }.store(in: &cancellables)
        }
        // Home is identified by an EMPTY cwd as well as a nil projectID, so a folder assignment
        // moves this window out of Home without the project id ever changing.
        bridge.$cwd.receive(on: RunLoop.main).sink { [weak self] cwd in
            guard let self else { return }
            self.updatePlaceWindowRegistration(projectID: self.bridge.projectID, cwd: cwd)
            self.refreshFolder()
            self.updateTitle()
            self.rebindLayoutForWorkspaceChange()
            self.refreshUtilityControls()   // artifacts/tasks are scoped to the workspace
        }.store(in: &cancellables)
        bridge.$projectID.receive(on: RunLoop.main).sink { [weak self] projectID in
            guard let self else { return }
            self.updatePlaceWindowRegistration(projectID: projectID, cwd: self.bridge.cwd)
            self.refreshFolder()
            self.updateTitle()
            self.rebindLayoutForWorkspaceChange()
            self.refreshUtilityControls()   // artifacts/tasks are scoped to the workspace
        }.store(in: &cancellables)
        // A native tab identifies the conversation, while the window itself identifies the
        // workspace. Listen to both selection and shared-store changes so tab text follows switching,
        // manual renames, and an asynchronous generated title even when another window made the edit.
        // Use the publisher values directly: @Published emits from willSet, before a synchronous read
        // through bridge/store is guaranteed to see the new value.
        bridge.$currentID
            .combineLatest(ConversationStore.shared.$summaries)
            .receive(on: RunLoop.main)
            .sink { [weak self] conversationID, summaries in
                self?.refreshFolder()
                self?.updateTitle(
                    conversationTitle: summaries.first(where: {
                        $0.id == conversationID
                    })?.displayTitle ?? "Mechanician")
            }
            .store(in: &cancellables)
        refreshUtilityControls()
        // A project renamed in the launcher must update an already-open window's switcher label live.
        ProjectStore.shared.$projects.receive(on: RunLoop.main).sink { [weak self] _ in
            self?.refreshFolder()
            self?.updateTitle()
        }.store(in: &cancellables)
        refreshFolder()
        updateTitle()
    }

    /// Every store the segment dots read from, as bare change signals. `schedulerHealth` is judged
    /// from the heartbeat's AGE, so app activation is included: returning to the app is exactly when
    /// a daemon that died while you were away should start showing its dot. The provider/auth-mode
    /// pair is here because the Extensions dot is scoped to the current lane — switching lanes can
    /// change the answer without any store mutating.
    private func utilityStatusSignals() -> [AnyPublisher<Void, Never>] {
        [
            bridge.$provider.map { _ in () }.eraseToAnyPublisher(),
            bridge.$authMode.map { _ in () }.eraseToAnyPublisher(),
            ProviderAccountStore.shared.$errors.map { _ in () }.eraseToAnyPublisher(),
            ExtensionsStore.shared.objectWillChange.map { _ in () }.eraseToAnyPublisher(),
            ArtifactStore.shared.$artifacts.map { _ in () }.eraseToAnyPublisher(),
            AmbientStore.shared.$tasks.map { _ in () }.eraseToAnyPublisher(),
            AmbientStore.shared.$runs.map { _ in () }.eraseToAnyPublisher(),
            AmbientStore.shared.$heartbeat.map { _ in () }.eraseToAnyPublisher(),
            // Agent-started watchers and dev servers are reported by agentd, not AmbientStore.
            // Without this signal the Tasks button can stay visually idle while its own panel
            // contains live processes, and it will not refresh when the last one exits.
            BackgroundProcessStore.shared.$processes.map { _ in () }.eraseToAnyPublisher(),
            NotificationCenter.default
                .publisher(for: NSApplication.didBecomeActiveNotification)
                .map { _ in () }.eraseToAnyPublisher(),
        ]
    }

    /// One phrasing for every panel control, matching the View menu's words and carrying the same
    /// shortcut the menu shows. Apple's own toolbars put the shortcut in the help tag; ours didn't.
    private static func panelToolTip(_ name: String, shown: Bool, shortcut: String) -> String {
        "\(shown ? "Hide" : "Show") \(name) (\(shortcut))"
    }

    /// View-backed toolbar items get no usable overflow row for free: `NSToolbarItem` builds its
    /// default menu form from the item's own target/action, which is nil when a custom view owns the
    /// click. Without this, every one of these controls is inert once the window narrows.
    private func makePanelMenuItem(_ name: String, action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: name, action: action, keyEquivalent: "")
        item.target = self
        return item
    }

    private func applyPanelState(
        _ shown: Bool,
        item: NSToolbarItem?,
        button: ToolbarToggleButton?,
        menuItem: NSMenuItem?,
        name: String,
        shortcut: String
    ) {
        let tip = Self.panelToolTip(name, shown: shown, shortcut: shortcut)
        button?.setOn(shown)
        button?.toolTip = tip
        item?.toolTip = tip
        menuItem?.state = shown ? .on : .off
    }

    /// Collapse/expand the sidebar on one consistent eased curve, coordinating the toolbar's toggle so
    /// it GLIDES with the divider instead of snapping (the source of the toggle-side jiggle). Expanding:
    /// pin the toggle beside the divider up front, so it slides right as the sidebar opens. Collapsing:
    /// let it ride the divider all the way left, then drop the leading space once closed so it settles
    /// at the leading edge with no mid-animation jump.
    private func setSidebarCollapsed(_ collapsed: Bool, on item: NSSplitViewItem) {
        if collapsed { persistLastExpandedSidebarWidth(forKey: workspaceLayoutKey) }
        guard item.isCollapsed != collapsed else {
            updateSidebarSpacing()
            if !collapsed { applySidebarWidth(preferred: Double(lastExpandedSidebarWidth)) }
            return
        }
        if !collapsed { updateSidebarSpacing() }   // add the leading space BEFORE expanding
        // On collapse, drop the leading space only once closed so the toggle settles without a jump.
        // On expansion, put back the retained divider width only after AppKit has reopened the item;
        // setting the position against a collapsed item is ignored.
        // NSAnimationContext runs its completion handler on the main thread, so the isolation here is
        // an assertion rather than a dispatch. The parameter is `@Sendable` in the current SDK, and a
        // `@MainActor` class is already Sendable, so only the isolation of the call needs stating.
        var onDone: (@Sendable () -> Void)?
        if collapsed {
            onDone = { [weak self] in MainActor.assumeIsolated { self?.updateSidebarSpacing() } }
        } else {
            onDone = { [weak self] in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.applySidebarWidth(preferred: Double(self.lastExpandedSidebarWidth))
                }
            }
        }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.22
            ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            ctx.allowsImplicitAnimation = true
            item.animator().isCollapsed = collapsed
        }, completionHandler: onDone)
    }

    /// Mail-style toggle placement: a leading flexible space right-aligns the toggle near the divider
    /// when the sidebar is open; remove it when collapsed so the toggle snaps to the leading edge
    /// instead of drifting toward the middle.
    private func updateSidebarSpacing() {
        guard let tb = toolbar else { return }
        let hasLeadingSpace = tb.items.first?.itemIdentifier == .flexibleSpace
        if bridge.showSidebar, !hasLeadingSpace {
            tb.insertItem(withItemIdentifier: .flexibleSpace, at: 0)
        } else if !bridge.showSidebar, hasLeadingSpace {
            tb.removeItem(at: 0)
        }
    }

    private var conversationTitle: String {
        bridge.currentConversation?.displayTitle ?? "Mechanician"
    }
    private func updateTitle(conversationTitle selectedConversationTitle: String? = nil) {
        let t = bridge.workspaceDisplayTitle
        let tabTitle = selectedConversationTitle ?? conversationTitle
        titleLabel?.stringValue = tabTitle
        window?.title = t       // titlebar text is hidden, but the Window menu / Mission Control use this
        window?.tab.title = tabTitle
        if let stamp = MechanicianBuildStamp.current {
            window?.subtitle = stamp
        }
    }

    /// The project this window is showing: a topic project by projectID, else the folder's project by cwd.
    private func currentProject() -> Project? {
        WorkspaceManagementPresentation.project(
            projectID: bridge.projectID,
            cwd: bridge.cwd,
            projects: ProjectStore.shared.projects)
    }

    // The toolbar identity control shows WHERE you are: a Project's name, or "Home" (the project-less
    // front door). Never "Scratch" — that word is retired.
    private var folderLabel: String {
        bridge.workspaceDisplayTitle
    }

    private func refreshFolder() {
        folderItem?.title = folderLabel
        workspaceActionsItem?.toolTip =
            "Manage \(folderLabel): instructions, folder, and workspace details"
        workspaceActionsItem?.image?.accessibilityDescription =
            "Workspace actions for \(folderLabel)"
    }

    // MARK: - Actions

    @objc private func didToggleSidebar()   { bridge.showSidebar.toggle() }
    @objc private func didToggleTerminal() {
        bridge.showTerminal.toggle()
        if bridge.showTerminal { bridge.ensureTerminal() }
        // Home can have no transcript growth to trigger a later AppKit layout pass. Force the split
        // host to honor the newly inserted lower panel immediately.
        window?.contentView?.needsLayout = true
        window?.contentView?.layoutSubtreeIfNeeded()
    }
    @objc private func didToggleInspector() {
        // Goes through the bridge so closing by hand also stops auto-reveals from reopening it.
        bridge.userToggledInspector()
        if bridge.showInspector && bridge.inspectorTab == .changes { bridge.refreshGit() }
    }
    @objc private func didToggleArtifacts() {
        UtilityWindowVisibility.shared.toggle(.artifacts) { appOpenWindow?(id: "artifacts") }
    }
    @objc private func didToggleAmbient() {
        UtilityWindowVisibility.shared.toggle(.ambient) { appOpenWindow?(id: "ambient") }
    }
    @objc private func didToggleExtensions() {
        UtilityWindowVisibility.shared.toggle(.extensions) { appOpenWindow?(id: "extensions") }
    }
    // MARK: - Places (Home · Help)
    //
    // ONE RULE, NO EXCEPTIONS: the segment shows and hides that place's window.
    //
    // Lit means the place has a window open — this one or another. Press a lit segment and that
    // window closes, INCLUDING when it is the window you are standing in; press a dark one and the
    // place opens, or comes forward if it is already open behind something.
    //
    // It read different ways before, and David asked what kind of behavior that was. From another
    // window Help closed, Home never did, and from inside either of them the control silently
    // switched jobs and toggled an inspector tab instead. One control that means two things
    // depending on which window you are in is a mode, and this app does not have modes. The
    // inspector already owns its Help tab; the toolbar does not need to be a second way to press
    // it.
    //
    // The consequence to keep in mind: Home must open its OWN window rather than converting this
    // one, or a lit Home segment would have nothing to close. `⇧⌘H` and the switcher row still
    // switch in place — a menu navigates, this deck shows and hides windows.

    @objc private func didToggleHome()   { activatePlace(.home) }
    @objc private func didToggleHelp()   { activatePlace(.help) }

    private func activatePlace(_ place: WorkspacePlace) {
        // `ToolbarToggleButton` is a momentary push button: AppKit clears the pressed state on
        // mouse-up, so a press whose effect lands asynchronously would flash the tile off and leave
        // it wrong. Re-assert every segment from the truth after any press.
        defer { refreshPlaceControls() }
        if let window = placeWindow(place) {
            closePlaceWindow(window, for: place)
        } else {
            openPlace(place)
        }
    }

    /// The window this place is open in, if any.
    ///
    /// Presence is the cross-window answer, but this window's own bridge is the authority for
    /// itself: a window registers as it mounts and as it changes workspace, and the registry must
    /// never be the reason a segment fails to close the very window it is drawn in.
    private func placeWindow(_ place: WorkspacePlace) -> NSWindow? {
        if isStanding(in: place), let window { return window }
        return WorkspacePlaceWindowPresence.shared.window(for: place)
    }

    /// Through the same routing every other workspace uses, so the one-window-per-workspace
    /// invariant, the new-window picker and the replace-origin behaviour are not a second set of
    /// rules to keep in step.
    ///
    /// `replacing: nil` for all three, `openHome()` for Home: a place the deck can close is a place
    /// that owns a window, never one that took over yours.
    private func openPlace(_ place: WorkspacePlace) {
        guard place != .home else {
            performWorkspaceCreatingIngress { openHome() }
            return
        }
        place.ensure(in: ProjectStore.shared) { project in
            guard let project,
                  let owner = routeToWorkspaceProject(project, replacing: nil),
                  let window = owner.window else { return }
            WorkspacePlaceWindowPresence.shared.register(window, for: place)
        }
    }

    private func closePlaceWindow(_ window: NSWindow, for place: WorkspacePlace) {
        guard window.attachedSheet != nil else {
            window.performClose(nil)
            return
        }
        DispatchQueue.main.async { [weak window] in
            guard let window, window.attachedSheet == nil else { return }
            window.performClose(nil)
        }
    }

    private func updatePlaceWindowRegistration(projectID: UUID?, cwd: String) {
        guard let window else { return }
        if let place = WorkspacePlace.showing(projectID: projectID, cwd: cwd) {
            WorkspacePlaceWindowPresence.shared.register(window, for: place)
        } else {
            WorkspacePlaceWindowPresence.shared.unregister(window)
        }
    }

    private func isStanding(in place: WorkspacePlace) -> Bool {
        place.isShowing(projectID: bridge.projectID, cwd: bridge.cwd)
    }

    /// Presence, not visibility, is the truthful state for a workspace window that may be behind
    /// another window or an inactive native tab.
    private func placeIsOn(_ place: WorkspacePlace) -> Bool {
        placeWindow(place) != nil
    }

    /// What the press will do, in the browsers deck's own words so the whole toolbar reads alike.
    /// The shortcut is named only in the opening direction, because that is the only direction any
    /// menu command performs.
    private func placeToolTip(_ place: WorkspacePlace, on: Bool) -> String {
        guard !on else { return "Hide \(place.name)" }
        guard let hint = place.openShortcutHint else { return "Show \(place.name)" }
        return "Show \(place.name) (\(hint))"
    }

    /// Exposed for tests: the help tag a segment shows in either direction.
    func placeToolTipForTesting(_ place: WorkspacePlace, on: Bool) -> String {
        placeToolTip(place, on: on)
    }
    @objc private func didToggleProviders() {
        UtilityWindowVisibility.shared.toggle(.accounts) { appOpenWindow?(id: "accounts") }
    }
    @objc private func didSwitchProject(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID, let p = ProjectStore.shared.project(id) else { return }
        // The toolbar picker switches THIS window's workspace in place — unless the workspace already
        // has its own window, in which case move focus there.
        if focusWorkspaceWindow(where: { p.cwd.isEmpty ? ($0.projectID == p.id) : ($0.cwd == p.cwd && $0.projectID == nil) }) { return }
        bridge.enterWorkspace(p)
    }
    /// Go Home — switch THIS window to Home in place, unless a Home window already exists (→ focus it).
    @objc private func didGoHome() {
        goHome(from: bridge)
    }
    /// Focus another window already showing the matching workspace; true if one was focused.
    private func focusWorkspaceWindow(where match: (AgentBridge) -> Bool) -> Bool {
        guard let owner = AgentBridge.live.allObjects.first(where: { $0 !== bridge && match($0) }),
              let win = owner.window else { return false }
        if win.isMiniaturized { win.deminiaturize(nil) }
        win.makeKeyAndOrderFront(nil)
        NSApp.activate()
        return true
    }
    @objc private func didOpenProjects() {
        // Capture the window the gallery is being opened from, so picking a Workspace acts on this
        // window rather than on whichever workspace window happened to be key last.
        ActiveWorkspace.shared.launcherOriginBridgeID = bridge.bridgeID
        NSApp.activate()
        appOpenWindow?(id: "projects")
    }
    @objc private func didCreateWorkspace() {
        ProjectStore.shared.pendingNewProjectRequest = true
        didOpenProjects()
    }
    @objc private func didEditWorkspaceInstructions() {
        bridge.presentWorkspaceInstructions()
    }
    @objc private func didEditCurrentWorkspace() {
        guard let project = currentProject(), !ReservedWorkspace.owns(project.id) else { return }
        ProjectStore.shared.pendingEditProjectRequest = project.id
        didOpenProjects()
    }
    @objc private func didChooseCurrentWorkspaceFolder() {
        if let project = currentProject() {
            _ = WorkspaceFolderAssignment.chooseFolder(for: project)
        } else if bridge.projectID == nil && bridge.cwd.isEmpty {
            bridge.chooseFolder()
        }
    }
    @objc private func didRevealCurrentWorkspaceFolder() {
        guard let path = WorkspaceManagementPresentation.folderPath(
            projectID: bridge.projectID,
            cwd: bridge.cwd,
            projects: ProjectStore.shared.projects
        ) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([
            URL(fileURLWithPath: path, isDirectory: true),
        ])
    }

    // MARK: - Segment context menus (rebuilt on open)
    //
    // Right-click any browser segment for the work you'd otherwise open the window to do: run a
    // task, re-check accounts, jump to a recent artifact. Every row is rebuilt from the live stores
    // when the menu opens, so it can never show a stale list.

    private func makeSegmentMenus(
        for deck: ToolbarUtilityDeck,
        controls: [ToolbarUtilityDeck.Control]
    ) {
        for control in controls {
            let menu = ToolbarSegmentMenu(control: control)
            menu.delegate = self
            menu.autoenablesItems = false   // header and status rows stay deliberately disabled
            deck.setContextMenu(menu, for: control)
        }
    }

    /// Exposed for tests: build a segment's menu exactly as opening it would.
    func rebuildSegmentMenu(_ menu: ToolbarSegmentMenu) {
        menu.removeAllItems()
        switch menu.control {
        case .providers: buildProvidersMenu(menu)
        case .extensions: buildExtensionsMenu(menu)
        case .artifacts: buildArtifactsMenu(menu)
        case .tasks: buildTasksMenu(menu)
        // Home and Help are deliberately given no context menu — there is no list behind them to
        // jump into — so nothing ever asks for one to be built.
        case .home, .help: break
        }
    }

    private func buildProvidersMenu(_ menu: NSMenu) {
        menu.addItem(sectionHeader("Providers"))
        let store = ProviderAccountStore.shared
        for access in ModelAccess.selectableCases {
            menu.addItem(providerRow(access, store: store))
        }
        menu.addItem(.separator())
        menu.addItem(menuRow("Check Accounts Again", #selector(didRecheckAccounts)))
        menu.addItem(menuRow("Open Providers", #selector(didShowProvidersFromMenu)))
    }

    /// A lane the user can act on says so with a verb and does the thing; a healthy lane is a status
    /// row that reveals itself in the panel. This is the whole point of the segment's dot — the fix
    /// is where the warning is, instead of a trip to a window to press the same button.
    private func providerRow(_ access: ModelAccess, store: ProviderAccountStore) -> NSMenuItem {
        // A connect already in flight is neither a status nor an action — say so and stay put.
        if let operation = store.operation(for: access) {
            return disabledRow("\(access.displayName) — \(operation.progressLabel)")
        }
        if let action = providerConnectionAction(access, store: store) {
            let row = menuRow("\(action.label) \(access.displayName)…",
                              #selector(didConnectProviderFromMenu(_:)))
            row.representedObject = access.rawValue
            return row
        }
        var title = access.displayName
        // Only worth saying when there's no verb above already saying it.
        if store.errors[access] != nil { title += " — needs attention" }
        let row = menuRow(title, #selector(didShowProvidersFromMenu))
        switch store.state(for: access) {
        case .connected: row.state = .on
        // An externally-supplied credential is usable, but a runtime that has definitively
        // rejected it is not — don't tick it.
        case .managed(_, let usable): row.state = usable == false ? .off : .on
        // Configured but unverified: a dash, not a tick. It hasn't proven itself yet.
        case .configured: row.state = .mixed
        case .checking, .disconnected, .unavailable: row.state = .off
        }
        return row
    }

    /// Deliberately the model picker's policy, not a second opinion: the two surfaces offer the same
    /// account the same action, or one of them is lying.
    private func providerConnectionAction(
        _ access: ModelAccess,
        store: ProviderAccountStore
    ) -> ProviderAccountStore.SubscriptionConnectionAction? {
        ModelPickerProviderPolicy.connectionAction(
            for: access,
            state: store.state(for: access),
            requiresReconnect: bridge.providerNeedsReconnect(access),
            isEnvironmentManaged: store.isEnvironmentManaged(access))
    }

    private func buildExtensionsMenu(_ menu: NSMenu) {
        menu.addItem(sectionHeader("Extensions"))
        let store = ExtensionsStore.shared
        let access = bridge.currentModelAccess
        let servers = store.mcpServers.filter {
            !$0.name.trimmingCharacters(in: .whitespaces).isEmpty
        }
        if servers.isEmpty {
            menu.addItem(disabledRow("No servers configured"))
        } else {
            for server in servers.prefix(Self.segmentMenuRowLimit) {
                menu.addItem(extensionRow(server, store: store, access: access))
            }
            if servers.count > Self.segmentMenuRowLimit {
                menu.addItem(disabledRow("…and \(servers.count - Self.segmentMenuRowLimit) more"))
            }
        }
        menu.addItem(.separator())
        menu.addItem(menuRow("Check Connections", #selector(didCheckExtensionConnections)))
        menu.addItem(menuRow("Open Extensions", #selector(didShowExtensionsFromMenu)))
    }

    /// A server waiting on OAuth is the one MCP problem the user can fix in one click, and the only
    /// one this menu offers to do — "Sign In", the same words and the same call as the panel's
    /// button. A failed server needs its config looked at, so that row just opens the panel.
    private func extensionRow(
        _ server: MCPServer,
        store: ExtensionsStore,
        access: ModelAccess
    ) -> NSMenuItem {
        guard server.enabled else { return statusRow("\(server.name) — off") }
        switch store.connState(for: server.name, access: access) {
        case .needsAuth:
            let row = menuRow("Sign In to \(server.name)…", #selector(didAuthorizeServerFromMenu(_:)))
            row.representedObject = server.name
            return row
        case .connected, .authenticated:
            let row = statusRow(server.name)
            row.state = .on
            return row
        case .failed:
            return statusRow("\(server.name) — failed")
        case .disabled:
            return statusRow("\(server.name) — off")
        case .unknown, .checking:
            let row = statusRow(server.name)
            row.state = .mixed
            return row
        }
    }

    /// A row that reports rather than acts: clicking it reveals the thing in its panel.
    private func statusRow(_ title: String) -> NSMenuItem {
        menuRow(title, #selector(didShowExtensionsFromMenu))
    }


    /// A switcher row OPENS its destination; it never closes it. A menu row that closed the window
    /// it names would be a trap — you cannot see a toggle's state while the menu is what is on
    /// screen. The toolbar segment beside it is the toggle.
    private func placeMenuAction(_ place: WorkspacePlace) -> Selector {
        switch place {
        case .home: #selector(didGoHome)
        case .help: #selector(didOpenHelpFromMenu)
        }
    }

    @objc private func didOpenHelpFromMenu() {
        openPlace(.help)
    }

    private func buildArtifactsMenu(_ menu: NSMenu) {
        menu.addItem(sectionHeader("Artifacts"))
        let scope = utilityScope
        let recent = ArtifactStore.shared.artifacts
            .filter { scope.contains(artifact: $0) }
            .sorted { max($0.createdAt, $0.updatedAt) > max($1.createdAt, $1.updatedAt) }
            .prefix(Self.segmentMenuRowLimit)
        if recent.isEmpty {
            menu.addItem(disabledRow("No artifacts in this workspace"))
        } else {
            // Text only, deliberately: AppKit suppresses menu-item images in this right-click
            // presentation (verified live — the images were set with valid sizes and no image
            // column was laid out, while the Providers menu's checkmarks rendered fine). Setting
            // `item.image` here would be a line that silently does nothing.
            for artifact in recent {
                let item = menuRow(artifact.title.isEmpty ? "Untitled" : artifact.title,
                                   #selector(didOpenArtifactFromMenu(_:)))
                item.representedObject = artifact.uuid
                menu.addItem(item)
            }
        }
        menu.addItem(.separator())
        menu.addItem(menuRow("Open Artifacts", #selector(didShowArtifactsFromMenu)))
    }

    private func buildTasksMenu(_ menu: NSMenu) {
        menu.addItem(sectionHeader("Tasks"))
        let scope = utilityScope
        let tasks = AmbientStore.shared.tasks.filter { scope.contains(task: $0) }
        if tasks.isEmpty {
            menu.addItem(disabledRow("No tasks in this workspace"))
        } else {
            for task in tasks.prefix(Self.segmentMenuRowLimit) {
                let row = NSMenuItem(title: task.name.isEmpty ? "Untitled task" : task.name,
                                     action: nil, keyEquivalent: "")
                let running = task.activeRun != nil
                row.state = running ? .mixed : (task.isEffectivelyEnabled ? .on : .off)
                let submenu = NSMenu()
                submenu.autoenablesItems = false
                let run = menuRow(running ? "Running…" : "Run Now", #selector(didRunTaskNow(_:)))
                run.representedObject = task.id
                run.isEnabled = !running && task.hasSchedulableWorkspace
                submenu.addItem(run)
                let pause = menuRow(task.isEffectivelyEnabled ? "Pause" : "Resume",
                                    #selector(didToggleTaskEnabled(_:)))
                pause.representedObject = task.id
                pause.isEnabled = task.hasSchedulableWorkspace
                submenu.addItem(pause)
                submenu.addItem(.separator())
                submenu.addItem(menuRow("Show in Tasks", #selector(didShowTasksFromMenu)))
                row.submenu = submenu
                menu.addItem(row)
            }
        }
        menu.addItem(.separator())
        menu.addItem(menuRow("New Task…", #selector(didCreateAmbientTask)))
        menu.addItem(menuRow("Open Tasks", #selector(didShowTasksFromMenu)))
    }

    private static let segmentMenuRowLimit = 8

    private func menuRow(_ title: String, _ action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        return item
    }
    private func disabledRow(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    // Menu actions FOCUS their window; they never close it. Only the persistent toolbar toggle
    // is a show/hide control — a menu row named "Open Extensions" that closed the window would be
    // a trap (same rule `showProviders` documents).
    @objc private func didShowProvidersFromMenu() { showProviders() }
    @objc private func didRecheckAccounts() { ProviderAccountStore.shared.refresh() }
    /// One entry point for both verbs — the same call the model picker makes, so a lane can't be
    /// connected one way here and another way there.
    @objc private func didConnectProviderFromMenu(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let access = ModelAccess(rawValue: raw) else { return }
        bridge.connectOrReconnectAccount(access)
    }
    @objc private func didAuthorizeServerFromMenu(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String else { return }
        bridge.mcpAuthorize(name, for: bridge.currentModelAccess)
    }
    @objc private func didShowExtensionsFromMenu() {
        UtilityWindowVisibility.shared.show(.extensions) { appOpenWindow?(id: "extensions") }
    }
    @objc private func didCheckExtensionConnections() { bridge.refreshMcpStatus() }
    @objc private func didShowArtifactsFromMenu() {
        UtilityWindowVisibility.shared.show(.artifacts) { appOpenWindow?(id: "artifacts") }
    }
    @objc private func didOpenArtifactFromMenu(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID else { return }
        ActiveWorkspace.shared.open(.artifact(id))
        didShowArtifactsFromMenu()
    }
    @objc private func didShowTasksFromMenu() {
        UtilityWindowVisibility.shared.show(.ambient) { appOpenWindow?(id: "ambient") }
    }
    @objc private func didCreateAmbientTask() {
        AmbientStore.shared.pendingNewTaskRequest = true
        didShowTasksFromMenu()
    }
    @objc private func didRunTaskNow(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        AmbientStore.shared.runNow(id)
    }
    @objc private func didToggleTaskEnabled(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String,
              let task = AmbientStore.shared.tasks.first(where: { $0.id == id }) else { return }
        AmbientStore.shared.setEnabled(id, !task.isEffectivelyEnabled)
    }

    // MARK: - Folder menu (rebuilt on open)

    func menuNeedsUpdate(_ menu: NSMenu) {
        if let segment = menu as? ToolbarSegmentMenu {
            rebuildSegmentMenu(segment)
            return
        }
        if menu is WorkspaceActionsMenu {
            rebuildWorkspaceActionsMenu(menu)
            return
        }
        menu.removeAllItems()
        // NSMenuToolbarItem consumes item-0 as the title placeholder and doesn't show it, so a
        // disabled identity header leads and the real navigation and management rows follow.
        menu.addItem(sectionHeader(bridge.projectID == nil && bridge.cwd.isEmpty
                                   ? "Home" : (currentProject()?.displayName ?? "Workspace")))
        // The ones the app owns, called out ahead of the ones you made — the same set, in the same
        // order, wearing the same glyphs as the toolbar deck beside this control and the launcher's
        // own rows. Help is an ordinary row in `projects` once it exists, so it is filtered out
        // below rather than listed twice under two different headings.
        for place in WorkspacePlace.allCases {
            let item = NSMenuItem(
                title: place.name,
                action: placeMenuAction(place),
                keyEquivalent: "")
            item.target = self
            item.image = NSImage(
                systemSymbolName: place.iconSymbol,
                accessibilityDescription: place.name)
            if isStanding(in: place) { item.state = .on }
            menu.addItem(item)
        }
        // Quick-switch to a kept Project → focus/open its ONE window (never re-home this one).
        let projects = ProjectStore.shared.projects.filter { !ReservedWorkspace.owns($0.id) }
        if !projects.isEmpty {
            menu.addItem(.separator())
            menu.addItem(sectionHeader("Your Workspaces"))
            for p in projects.prefix(12) {
                let i = NSMenuItem(title: p.displayName, action: #selector(didSwitchProject(_:)), keyEquivalent: "")
                i.target = self
                i.representedObject = p.id
                let isCurrent = p.cwd.isEmpty ? (p.id == bridge.projectID) : (p.cwd == bridge.cwd && bridge.projectID == nil)
                if isCurrent { i.state = .on }
                menu.addItem(i)
            }
        }
        menu.addItem(.separator())
        let create = NSMenuItem(title: "New Workspace…", action: #selector(didCreateWorkspace), keyEquivalent: "")
        create.target = self; menu.addItem(create)
        menu.addItem(.separator())
        let all = NSMenuItem(
            title: WorkspaceManagementPresentation.allWorkspacesActionTitle,
            action: #selector(didOpenProjects),
            keyEquivalent: "")
        all.target = self; menu.addItem(all)
    }

    /// Management is a persistent control beside the workspace switcher rather than a few rows
    /// buried after up to twelve navigation destinations.
    func rebuildWorkspaceActionsMenu(_ menu: NSMenu) {
        menu.removeAllItems()
        let projects = ProjectStore.shared.projects
        menu.addItem(sectionHeader("Manage \(folderLabel)"))

        let instructions = NSMenuItem(
            title: WorkspaceInstructionsPresentation.actionTitle,
            action: #selector(didEditWorkspaceInstructions),
            keyEquivalent: "i")
        instructions.keyEquivalentModifierMask = [.command, .shift]
        instructions.image = NSImage(
            systemSymbolName: WorkspaceInstructionsPresentation.systemImage,
            accessibilityDescription: WorkspaceInstructionsPresentation.actionTitle)
        instructions.target = self
        instructions.isEnabled = WorkspaceInstructionsPresentation.target(
            projectID: bridge.projectID,
            cwd: bridge.cwd,
            projects: projects) != nil
        menu.addItem(instructions)

        if let folderTitle = WorkspaceManagementPresentation.folderActionTitle(
            projectID: bridge.projectID,
            cwd: bridge.cwd,
            projects: projects
        ) {
            let folder = NSMenuItem(
                title: folderTitle,
                action: #selector(didChooseCurrentWorkspaceFolder),
                keyEquivalent: "")
            folder.image = NSImage(
                systemSymbolName: currentProject()?.cwd.isEmpty == false
                    ? "folder" : "folder.badge.plus",
                accessibilityDescription: folderTitle)
            folder.target = self
            menu.addItem(folder)
        }

        if WorkspaceManagementPresentation.folderPath(
            projectID: bridge.projectID,
            cwd: bridge.cwd,
            projects: projects
        ) != nil {
            let reveal = NSMenuItem(
                title: WorkspaceManagementPresentation.revealFolderActionTitle,
                action: #selector(didRevealCurrentWorkspaceFolder),
                keyEquivalent: "")
            reveal.image = NSImage(
                systemSymbolName: "folder",
                accessibilityDescription:
                    WorkspaceManagementPresentation.revealFolderActionTitle)
            reveal.target = self
            menu.addItem(reveal)
        }

        if WorkspaceManagementPresentation.canEditWorkspace(
            projectID: bridge.projectID,
            cwd: bridge.cwd,
            projects: projects
        ) {
            let edit = NSMenuItem(
                title: WorkspaceManagementPresentation.editWorkspaceActionTitle,
                action: #selector(didEditCurrentWorkspace),
                keyEquivalent: "")
            edit.image = NSImage(
                systemSymbolName: "slider.horizontal.3",
                accessibilityDescription:
                    WorkspaceManagementPresentation.editWorkspaceActionTitle)
            edit.target = self
            menu.addItem(edit)
        }

        menu.addItem(.separator())
        let all = NSMenuItem(
            title: WorkspaceManagementPresentation.allWorkspacesActionTitle,
            action: #selector(didOpenProjects),
            keyEquivalent: "")
        all.image = NSImage(
            systemSymbolName: "square.grid.2x2",
            accessibilityDescription:
                WorkspaceManagementPresentation.allWorkspacesActionTitle)
        all.target = self
        menu.addItem(all)
    }
    private func sectionHeader(_ t: String) -> NSMenuItem {
        let i = NSMenuItem(title: t, action: nil, keyEquivalent: ""); i.isEnabled = false; return i
    }

    // MARK: - NSToolbarDelegate

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        // The leading flexible space that right-aligns the toggle near the divider (Mail-style) is
        // inserted/removed DYNAMICALLY by updateSidebarSpacing() — present when the sidebar is open
        // (toggle near the divider), gone when it's collapsed (toggle snaps to the leading edge instead
        // of drifting to center). Everything after the tracking separator sits over the content.
        // The prominent title is now the PROJECT (the folderMenu switcher); the conversation name lives
        // in the sidebar and transcript context, not the window chrome.
        // Workspace visibility controls live in ONE view-backed toolbar item. AppKit independently
        // aligns separate custom items, which made the build-115 controls drift vertically and left
        // native gaps between individually outlined buttons. The deck owns one outer surface, equal
        // segments, and its internal semantic divider as a single layout unit.
        [Self.sidebarToggle, Self.trackingSep, Self.folderMenu, Self.workspaceActions, Self.placesDeck,
         .flexibleSpace, Self.utilityDeck, Self.terminal, Self.inspectorRegion]
    }
    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar) + [.space, .flexibleSpace]
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        switch id {
        case Self.sidebarToggle:
            let it = NSToolbarItem(itemIdentifier: id)
            // It moves independently with the split divider, but still reflects the sidebar's
            // visibility state like the other panel controls.
            let btn = ToolbarToggleButton(
                symbol: "sidebar.left",
                target: self,
                action: #selector(didToggleSidebar))
            it.view = btn
            btn.setAccessibilityLabel("Sidebar")   // view-based item: name the button so VoiceOver isn't just "button"
            // …the "Sidebar" caption comes from the toolbar item label, so it appears exactly ONCE and
            // only in "icon and text" display mode — never doubled, never in icon-only mode.
            it.label = "Sidebar"; it.paletteLabel = "Sidebar"
            it.menuFormRepresentation = makePanelMenuItem("Sidebar", action: #selector(didToggleSidebar))
            // Through the shared helper like the other two panel toggles, so the tip lands on the
            // BUTTON as well as the item. A view-backed item's own `toolTip` is accessibility help
            // only — nothing hovers an item, you hover the view it hosts.
            applyPanelState(bridge.showSidebar, item: it, button: btn,
                            menuItem: it.menuFormRepresentation, name: "Sidebar", shortcut: "⌃⌘S")
            if flag { sidebarItem = it; sidebarButton = btn; sidebarMenuItem = it.menuFormRepresentation }
            return it
        case Self.folderMenu:
            let it = NSMenuToolbarItem(itemIdentifier: id)
            it.title = folderLabel
            // A project switcher, not a folder picker — a distinct glyph so it doesn't read as "folder".
            it.image = NSImage(systemSymbolName: "square.grid.2x2", accessibilityDescription: "Switch workspace")
            it.showsIndicator = true
            let m = NSMenu(); m.delegate = self
            it.menu = m
            it.label = ""; it.paletteLabel = "Workspace"   // no caption — the workspace name is shown
            it.toolTip = "Switch workspace"
            // The control that says WHERE YOU ARE outranks everything else in the strip. Without
            // this it carried the default priority while the two decks asked for `.high`, so a
            // toolbar under pressure dropped the workspace name and kept a row of shortcuts to
            // somewhere else — and the menu it dropped is the only place the full workspace list
            // lives.
            it.visibilityPriority = .high
            folderItem = it; return it
        case Self.workspaceActions:
            let it = NSMenuToolbarItem(itemIdentifier: id)
            it.image = NSImage(
                systemSymbolName: "ellipsis.circle",
                accessibilityDescription: "Workspace actions for \(folderLabel)")
            it.showsIndicator = false
            let menu = WorkspaceActionsMenu()
            menu.delegate = self
            menu.autoenablesItems = false
            it.menu = menu
            it.label = "Workspace Actions"
            it.paletteLabel = "Workspace Actions"
            it.toolTip = "Manage \(folderLabel): instructions, folder, and workspace details"
            workspaceActionsItem = it
            return it
        case Self.trackingSep:
            guard let split = splitVC?.splitView else { return nil }
            return NSTrackingSeparatorToolbarItem(identifier: id, splitView: split, dividerIndex: 0)
        case Self.convTitle:
            let it = NSToolbarItem(itemIdentifier: id)
            let label = NSTextField(labelWithString: conversationTitle)
            label.font = .systemFont(ofSize: NSFont.systemFontSize(for: .regular), weight: .semibold)
            label.lineBreakMode = .byTruncatingTail
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            titleLabel = label
            it.view = label
            it.visibilityPriority = .low   // yield first when the toolbar is tight
            it.label = ""; it.paletteLabel = "Conversation Title"   // no caption — the title text IS the label
            return it
        case Self.placesDeck:
            let deck = ToolbarUtilityDeck(
                controls: ToolbarUtilityDeck.Control.places,
                menuTitle: "Places",
                target: self,
                actions: [
                    .home: #selector(didToggleHome),
                    .help: #selector(didToggleHelp),
                ])
            let it = NSToolbarItem(itemIdentifier: id)
            it.view = deck
            // The ones the app always owns, beside the switcher that says where you are.
            it.label = "Places"
            it.paletteLabel = "Places"
            it.menuFormRepresentation = deck.makeMenuFormRepresentation()
            // The FIRST thing to yield when the toolbar runs out of room. Every place in this deck
            // is also a row in the switcher menu one control to its left, so it is the only group
            // here whose loss costs a person nothing but a click — and its overflow row keeps even
            // that. It shipped at `.high`, which is how a wide inspector could push the workspace
            // switcher out of a toolbar that still had room for three shortcuts.
            it.visibilityPriority = .low
            if flag {
                placesDeck = deck
                refreshPlaceControls()
            } else {
                // The offscreen copy still has to look right in the palette.
                refreshPlaceControls(deck)
            }
            return it
        case Self.utilityDeck:
            let deck = ToolbarUtilityDeck(
                controls: ToolbarUtilityDeck.Control.browsers,
                dividerBefore: .artifacts,
                menuTitle: "Workspace Controls",
                target: self,
                actions: [
                    .providers: #selector(didToggleProviders),
                    .extensions: #selector(didToggleExtensions),
                    .artifacts: #selector(didToggleArtifacts),
                    .tasks: #selector(didToggleAmbient),
                ])
            let it = NSToolbarItem(itemIdentifier: id)
            it.view = deck
            // These are app-wide browsers, not workspace-scoped switches — the deck's divider is
            // what separates the global pair from the workspace pair.
            it.label = "Browsers"
            it.paletteLabel = "Browsers"
            it.menuFormRepresentation = deck.makeMenuFormRepresentation()
            it.visibilityPriority = .high
            // A customizable NSToolbar also asks its delegate for offscreen palette/overflow
            // representations (`flag == false`). Retaining one of those would silently redirect
            // every later Combine state update away from the deck the user can actually see.
            if flag {
                utilityDeck = deck
                makeSegmentMenus(for: deck, controls: deck.controls)
                refreshUtilityControls()
            } else {
                // The offscreen copy still has to look right in the palette.
                applyVisibility(UtilityWindowVisibility.shared.visibleIDs, to: deck)
            }
            return it
        case Self.terminal:
            let it = NSToolbarItem(itemIdentifier: id)
            let button = ToolbarToggleButton(symbol: "rectangle.bottomthird.inset.filled",
                                             target: self, action: #selector(didToggleTerminal))
            button.setAccessibilityLabel("Terminal")
            button.setOn(bridge.showTerminal)
            it.view = button
            it.label = "Terminal"
            it.paletteLabel = "Terminal"
            it.menuFormRepresentation = makePanelMenuItem("Terminal", action: #selector(didToggleTerminal))
            // A view-backed item publishes the ITEM's tooltip as its accessibility help, not the
            // hosted button's — set both or VoiceOver gets nothing.
            applyPanelState(bridge.showTerminal, item: it, button: button,
                            menuItem: it.menuFormRepresentation, name: "Terminal", shortcut: "⌃⌘T")
            if flag { terminalItem = it; terminalButton = button; terminalMenuItem = it.menuFormRepresentation }
            return it
        case Self.inspectorRegion:
            let it = NSToolbarItem(itemIdentifier: id)
            let region = InspectorToolbarRegionView(
                target: self,
                action: #selector(didToggleInspector))
            region.button.setOn(bridge.showInspector)
            it.view = region
            it.label = "Inspector"
            it.paletteLabel = "Inspector"
            it.visibilityPriority = .high
            it.menuFormRepresentation = makePanelMenuItem("Inspector", action: #selector(didToggleInspector))
            applyPanelState(bridge.showInspector, item: it, button: region.button,
                            menuItem: it.menuFormRepresentation, name: "Inspector", shortcut: "⌥⌘I")
            if flag {
                inspectorRegionItem = it
                inspectorRegionView = region
                inspectorButton = region.button
                inspectorMenuItem = it.menuFormRepresentation
                updateInspectorToolbarPosition()
            }
            return it
        default:
            return nil
        }
    }

    // MARK: - Utility segment state
    //
    // Each browser's segment carries two independent facts: whether its window is open (the toggle)
    // and whether the thing behind it needs the user (the dot). A signed-out provider, an MCP server
    // stuck on OAuth, and a schedule whose daemon died are all invisible today until a turn quietly
    // fails, so the toolbar is where they surface.

    private func applyVisibility(_ visible: Set<UtilityWindowID>, to deck: ToolbarUtilityDeck) {
        for control in deck.controls {
            guard let windowID = control.windowID else { continue }
            deck.setOn(visible.contains(windowID), for: control)
        }
    }

    /// One pass over every segment in both decks: on-state, dot, and the help tag that spells out
    /// both. Places first, and unconditionally, so a window whose browsers deck has not been built
    /// (the palette copy, a narrowed toolbar) still keeps Home and Help truthful.
    private func refreshUtilityControls() {
        refreshPlaceControls()
        guard let deck = utilityDeck else { return }
        let visible = UtilityWindowVisibility.shared.visibleIDs
        for control in deck.controls {
            guard let windowID = control.windowID else { continue }
            let on = visible.contains(windowID)
            let (status, detail) = utilityStatus(for: control, windowIsOpen: on)
            deck.setOn(on, for: control)
            deck.setStatus(status, for: control)
            var tip = "\(on ? "Hide" : "Show") \(control.label)"
            if let hint = control.shortcutHint { tip += " (\(hint))" }
            if let detail { tip += "\n\(detail)" }
            deck.setToolTip(tip, for: control)
        }
    }

    private func refreshPlaceControls(_ target: ToolbarUtilityDeck? = nil) {
        guard let deck = target ?? placesDeck else { return }
        for control in deck.controls {
            guard let place = control.place else { continue }
            let on = placeIsOn(place)
            deck.setOn(on, for: control)
            deck.setToolTip(placeToolTip(place, on: on), for: control)
        }
    }

    /// The workspace whose artifacts and tasks this window's segments describe.
    private var utilityScope: WorkspaceUtilityScope {
        .current(
            projectID: bridge.projectID,
            cwd: bridge.cwd,
            resolvedFolderProjectID: ProjectStore.shared.projectID(forCwd: bridge.cwd, createIfMissing: false))
    }

    private func utilityStatus(
        for control: ToolbarUtilityDeck.Control,
        windowIsOpen: Bool
    ) -> (ToolbarUtilityDeck.SegmentStatus, String?) {
        switch control {
        case .providers:
            // Only lanes the user actually engaged with record an error, so this never nags about
            // providers they have simply never set up.
            let failing = ProviderAccountStore.shared.errors.count
            guard failing > 0 else { return (.none, nil) }
            return (.attention, failing == 1
                    ? "One account needs attention"
                    : "\(failing) accounts need attention")
        case .extensions:
            let blocked = ExtensionsStore.shared
                .mcpServersNeedingAttention(for: bridge.currentModelAccess)
            guard !blocked.isEmpty else { return (.none, nil) }
            return (.attention, blocked.count == 1
                    ? "\(blocked[0]) needs attention"
                    : "\(blocked.count) servers need attention")
        case .artifacts:
            return artifactsStatus(windowIsOpen: windowIsOpen)
        case .tasks:
            return tasksStatus()
        case .home, .help:
            // No dot. A place is somewhere you go, not a queue that fills up behind you; nothing
            // here is waiting on the user.
            return (.none, nil)
        }
    }

    /// Artifacts is the one segment whose dot is an "unread" mark rather than a fault: work the
    /// agent produced while the browser was closed. Seen-ness is per workspace, and only the window
    /// showing THIS workspace clears it.
    private func artifactsStatus(windowIsOpen: Bool) -> (ToolbarUtilityDeck.SegmentStatus, String?) {
        let scope = utilityScope
        let showingThisWorkspace = windowIsOpen && ActiveWorkspace.shared.bridge === bridge
        if showingThisWorkspace {
            UserDefaults.standard.set(Date().timeIntervalSinceReferenceDate, forKey: artifactsSeenKey)
            return (.none, nil)
        }
        let seen = Date(timeIntervalSinceReferenceDate:
                            UserDefaults.standard.double(forKey: artifactsSeenKey))
        let fresh = ArtifactStore.shared.artifacts.filter {
            scope.contains(artifact: $0) && max($0.createdAt, $0.updatedAt) > seen
        }.count
        guard fresh > 0 else { return (.none, nil) }
        return (.unseen, fresh == 1 ? "1 new artifact" : "\(fresh) new artifacts")
    }

    private var artifactsSeenKey: String { "mech.artifacts.seenAt.\(workspaceLayoutKey)" }

    private func tasksStatus() -> (ToolbarUtilityDeck.SegmentStatus, String?) {
        let scope = utilityScope
        let store = AmbientStore.shared
        let tasks = store.tasks.filter { scope.contains(task: $0) }
        let runningTasks = tasks.filter { $0.activeRun != nil }.count
        let trackedProcesses = BackgroundProcessStore.shared.processes.count
        if runningTasks > 0 || trackedProcesses > 0 {
            var details: [String] = []
            if runningTasks > 0 {
                details.append(runningTasks == 1 ? "1 task running" : "\(runningTasks) tasks running")
            }
            if trackedProcesses > 0 {
                details.append(
                    trackedProcesses == 1
                        ? "Agent-started background work (1 tracked process)"
                        : "Agent-started background work (\(trackedProcesses) tracked processes; "
                            + "one service may use several)")
            }
            return (.active, details.joined(separator: "\n"))
        }
        guard !tasks.isEmpty else { return (.none, nil) }
        // runs.json is oldest-first, so the last entry per task id is its most recent run.
        let ids = Set(tasks.map(\.id))
        var latest: [String: AmbientRun] = [:]
        for run in store.runs where ids.contains(run.taskId) { latest[run.taskId] = run }
        let failed = latest.values.filter { !$0.ok }.count
        if failed > 0 {
            return (.attention, failed == 1 ? "Last run failed" : "\(failed) tasks failed their last run")
        }
        // A schedule that silently is not running is the failure users never notice on their own.
        let scheduled = tasks.filter(\.isEffectivelyEnabled).count
        if scheduled > 0, store.schedulerHealth() == .off {
            return (.attention, scheduled == 1
                    ? "1 scheduled task, but the scheduler is not running"
                    : "\(scheduled) scheduled tasks, but the scheduler is not running")
        }
        return (.none, nil)
    }

    /// The inspector lives inside DetailView's SwiftUI HStack, not the AppKit split controller, so
    /// a native tracking separator cannot follow it. Its toolbar region reserves the panel width and
    /// anchors the right-panel button at the region's leading edge, just inside the inspector.
    static func inspectorToolbarButtonWindowX(
        showsInspector: Bool,
        inspectorIsFullWidth: Bool,
        seamX: CGFloat?
    ) -> CGFloat? {
        guard showsInspector, !inspectorIsFullWidth, let seamX else { return nil }
        return seamX + InspectorToolbarRegionView.openLeadingInset
    }

    private func updateInspectorToolbarPosition() {
        let width = bridge.showInspector ? bridge.inspectorWidth : ToolbarUtilityDeck.segmentSize.width
        let leadingInset = bridge.showInspector ? InspectorToolbarRegionView.openLeadingInset : 0
        // Where the button must land, in window coordinates: just inside the seam that is ACTUALLY
        // drawn between the conversation and the inspector.
        //
        // The inset alone cannot answer that. It is one constant standing in for three numbers —
        // the published inspector width, the detail column's own insets, and NSToolbar's trailing
        // inset — each of which can be right while the sum is wrong, and the visible result is a
        // right-panel toggle sitting on the divider instead of inside the panel it opens. The
        // resize handle is a real view over the real seam, so when it reports a position the region
        // corrects itself against it and the constant is only a fallback (no seam exists at all
        // when the inspector is closed, or expanded to the full width).
        inspectorRegionView?.desiredButtonWindowX = Self.inspectorToolbarButtonWindowX(
            showsInspector: bridge.showInspector,
            inspectorIsFullWidth: bridge.inspectorExpanded,
            seamX: bridge.inspectorSeamX)
        // The region view carries its own width and height constraints — the same two numbers
        // `minSize`/`maxSize` used to repeat — which is how NSToolbarItem has been meant to size a
        // custom view since macOS 12, and why those properties are deprecated. Setting both was
        // duplication, not belt-and-braces: a constraint the item disagreed with would have been an
        // unsatisfiable layout, not a safety net.
        inspectorRegionView?.setWidth(width, leadingInset: leadingInset)
        // Constraint and intrinsic-size invalidation already schedule the toolbar's native layout.
        // Forcing the entire content view to lay out synchronously on every drag delta made AppKit
        // re-enter the hosted SwiftUI tree and starved later mouseDragged events. Let AppKit
        // coalesce the toolbar update in its normal display pass.
    }
}

/// The toolbar projection of the SwiftUI inspector. Its button stays at the leading edge, making it
/// clear that it controls the panel to its right rather than the transcript to its left.
@MainActor
final class InspectorToolbarRegionView: NSView {
    static let openLeadingInset: CGFloat = 24
    private var widthConstraint: NSLayoutConstraint!
    private var buttonLeadingConstraint: NSLayoutConstraint!
    let button: ToolbarToggleButton

    /// Where the button should begin, in window coordinates, when the live seam position is known.
    /// `layout()` converts it into this view's own coordinates, so it stays right however NSToolbar
    /// chooses to place the region itself.
    var desiredButtonWindowX: CGFloat? {
        didSet {
            guard desiredButtonWindowX != oldValue else { return }
            needsLayout = true
        }
    }

    init(target: AnyObject, action: Selector) {
        // 16pt is deliberate and calibrated — do NOT "normalize" it to the 13pt the other controls
        // use. `sidebar.right` renders shorter than its neighbours at a matched point size, and at
        // 13 the right-panel toggle visibly reads smaller than the left-panel one.
        button = ToolbarToggleButton(
            symbol: "sidebar.right",
            target: target,
            action: action,
            symbolPointSize: 16)
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        widthConstraint = widthAnchor.constraint(equalToConstant: 0)
        widthConstraint.isActive = true
        heightAnchor.constraint(equalToConstant: ToolbarUtilityDeck.outerHeight).isActive = true
        button.setAccessibilityLabel("Inspector")
        addSubview(button)
        buttonLeadingConstraint = button.leadingAnchor.constraint(equalTo: leadingAnchor)
        NSLayoutConstraint.activate([
            buttonLeadingConstraint,
            button.centerYAnchor.constraint(equalTo: centerYAnchor),
            button.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
        ])
        setAccessibilityElement(false)
    }

    required init?(coder: NSCoder) { fatalError() }

    @discardableResult
    func setWidth(_ width: CGFloat, leadingInset: CGFloat) -> Bool {
        let boundedWidth = max(0, width)
        guard widthConstraint.constant != boundedWidth
                || buttonLeadingConstraint.constant != leadingInset else { return false }
        widthConstraint.constant = boundedWidth
        // Closed, the region is exactly one control wide so the transcript controls can sit beside
        // it. Open, compensate for NSToolbar's alignment offset to put the button in the inspector.
        buttonLeadingConstraint.constant = leadingInset
        invalidateIntrinsicContentSize()
        // These are constraint changes; the button has not moved yet. Ask once the layout that
        // actually repositions it has run — `setFrameOrigin` covers the move itself, and this
        // covers a region that resizes around a button whose local origin never changes.
        DispatchQueue.main.async { [weak button] in
            MainActor.assumeIsolated { button?.syncHoverWithPointer() }
        }
        return true
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: widthConstraint.constant, height: ToolbarUtilityDeck.outerHeight)
    }

    /// Correct the button against the seam once this view's own position is known.
    ///
    /// Safe to do here: the region's origin does not depend on where the button sits inside it, so
    /// this converges in one further pass rather than feeding itself.
    override func layout() {
        super.layout()
        guard let desiredButtonWindowX, window != nil else { return }
        let inset = max(0, desiredButtonWindowX - convert(NSPoint.zero, to: nil).x)
        guard abs(buttonLeadingConstraint.constant - inset) > 0.5 else { return }
        buttonLeadingConstraint.constant = inset
        DispatchQueue.main.async { [weak button] in
            MainActor.assumeIsolated { button?.syncHoverWithPointer() }
        }
    }
}

/// A segment's right-click menu. Subclassed purely to carry which control it belongs to, so one
/// `NSMenuDelegate` (the toolbar controller) can rebuild any of them from the live stores.
@MainActor
/// Distinguishes the persistent current-workspace management popup from the adjacent navigation
/// popup while both are delegated to the same toolbar controller.
final class WorkspaceActionsMenu: NSMenu {}

final class ToolbarSegmentMenu: NSMenu {
    let control: ToolbarUtilityDeck.Control

    init(control: ToolbarUtilityDeck.Control) {
        self.control = control
        super.init(title: control.label)
    }

    required init(coder: NSCoder) { fatalError() }
}

/// One toolbar item that keeps global tools and workspace-scoped utility switches together,
/// separated by one semantic divider.
@MainActor
final class ToolbarUtilityDeck: NSView {
    enum Control: CaseIterable, Hashable {
        // The places, in the order the launcher lists them. These live in their own deck beside the
        // workspace switcher: they are destinations, not panels.
        case home
        case help
        // The browsers. Global pair first, workspace-scoped pair after the semantic divider.
        case providers
        case extensions
        case artifacts
        case tasks

        /// The three app-owned destinations, in launcher order.
        static let places: [Control] = [.home, .help]

        /// The panel browsers, in deck order. `dividerBefore` splits the global pair from the
        /// workspace-scoped pair.
        static let browsers: [Control] = [.providers, .extensions, .artifacts, .tasks]

        /// The destination this control goes to, for the three that are places.
        var place: WorkspacePlace? {
            switch self {
            case .home: .home
            case .help: .help
            case .providers, .extensions, .artifacts, .tasks: nil
            }
        }

        fileprivate var symbol: String {
            switch self {
            case .providers: "person.crop.circle"
            case .extensions: "puzzlepiece.extension"
            case .artifacts: "square.stack.3d.up"
            // Plain `clock`, not `clock.badge`: a glyph that always carries an empty badge cannot
            // then MEAN anything when tasks actually need the user. The badge is the status dot.
            case .tasks: "clock"
            // THE SAME GLYPH EACH PLACE WEARS EVERYWHERE ELSE — the launcher card, the inspector
            // tab, the switcher row. A place is the same place in every surface, or it is not one.
            case .home, .help: place?.iconSymbol ?? "questionmark"
            }
        }

        /// The one place a control's user-facing name lives. The window it toggles, its tooltip and
        /// its overflow row all read this, so they cannot drift into three different words.
        var label: String {
            switch self {
            case .providers: "Providers"
            case .extensions: "Extensions"
            case .artifacts: "Artifacts"
            case .tasks: "Tasks"
            case .home, .help: place?.name ?? ""
            }
        }

        /// The utility window this segment shows and hides. Nil for a place: a place is a workspace
        /// window the app routes to, never a retained utility scene.
        var windowID: UtilityWindowID? {
            switch self {
            case .providers: .accounts
            case .extensions: .extensions
            case .artifacts: .artifacts
            case .tasks: .ambient
            case .home, .help: nil
            }
        }

        /// The menu equivalent, shown in the help tag the way Apple's own toolbars do. Nil where no
        /// command exists: a tag that names a shortcut must name one that works.
        var shortcutHint: String? {
            switch self {
            case .providers: "⌥⌘A"
            case .extensions: "⌥⌘E"
            case .artifacts: "⌥⌘Y"
            case .tasks: "⌥⌘T"
            case .home, .help: place?.openShortcutHint
            }
        }
    }

    /// What a segment says about the thing behind it, beyond whether its window happens to be open.
    /// `attention` is the only state that competes for the eye; the other two stay quiet.
    enum SegmentStatus: Equatable {
        case none
        /// Blocked or broken, and only the user can clear it (a signed-out provider, an MCP server
        /// awaiting OAuth, a schedule whose daemon is not running).
        case attention
        /// Work is running right now.
        case active
        /// New content arrived while this window was closed.
        case unseen

        /// Color carries SEVERITY, nothing else. `unseen` is deliberately neutral: it was the same
        /// accent blue as a segment's own on-state tile, which made "there is news" and "this window
        /// is open" look like the same fact.
        fileprivate var color: NSColor? {
            switch self {
            case .none: nil
            case .attention: .systemOrange
            case .active: .systemGreen
            case .unseen: .secondaryLabelColor
            }
        }
    }

    static let segmentSize = NSSize(width: 34, height: 28)
    static let outerHeight: CGFloat = 32
    // Shorter and quieter than the deck's own 0.5pt/0.34-alpha outline was: a separator inside a
    // container should never out-weigh the container.
    static let dividerSize = NSSize(width: 1, height: 14)
    static let internalSpacing: CGFloat = 2
    static let horizontalInset: CGFloat = 2

    private(set) var buttons: [Control: ToolbarToggleButton] = [:]
    /// The segments this deck holds, in display order. The toolbar iterates THIS rather than
    /// `Control.allCases`: there are two decks now, and a pass over every case would light a
    /// segment the deck in front of you does not contain.
    let controls: [Control]
    let semanticDivider = NSView()
    private var visualViews: [NSView] = []
    private let overflowMenu = NSMenu()
    private var overflowItems: [Control: NSMenuItem] = [:]
    private let menuTitle: String

    /// - Parameter dividerBefore: the segment the deck's one semantic divider precedes, when the
    ///   deck groups two kinds of control. A deck whose segments all mean the same thing passes nil
    ///   and gets no divider — an internal rule that separates nothing is just a line.
    init(
        controls: [Control],
        dividerBefore: Control? = nil,
        menuTitle: String,
        target: AnyObject,
        actions: [Control: Selector]
    ) {
        self.controls = controls
        self.menuTitle = menuTitle
        let divider = dividerBefore.flatMap { controls.contains($0) ? $0 : nil }
        let segmentWidth = Self.segmentSize.width * CGFloat(controls.count)
        // One gap between each pair of arranged views: buttons plus the divider, minus one. This was
        // hardcoded to 4 against "four buttons plus one divider"; adding a fifth segment left the
        // deck 2pt short and silently squeezed the last button to 32pt instead of 34.
        let dividerWidth = divider == nil ? 0 : Self.dividerSize.width
        let viewCount = controls.count + (divider == nil ? 0 : 1)
        let gaps = Self.internalSpacing * CGFloat(max(0, viewCount - 1))
        let width = segmentWidth + dividerWidth + gaps + Self.horizontalInset * 2
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: Self.outerHeight))

        wantsLayer = true
        layer?.cornerRadius = 9
        layer?.cornerCurve = .continuous
        layer?.borderWidth = 0.5
        setAccessibilityElement(false)

        semanticDivider.translatesAutoresizingMaskIntoConstraints = false
        semanticDivider.wantsLayer = true
        semanticDivider.setAccessibilityElement(false)

        for control in controls {
            if control == divider {
                addSubview(semanticDivider)
                visualViews.append(semanticDivider)
            }
            guard let action = actions[control] else {
                assertionFailure("Missing toolbar action for \(control)")
                continue
            }
            let button = ToolbarToggleButton(
                symbol: control.symbol,
                target: target,
                action: action)
            button.setAccessibilityLabel(control.label)
            buttons[control] = button
            addSubview(button)
            visualViews.append(button)

            if control == divider {
                overflowMenu.addItem(.separator())
            }
            let overflowItem = NSMenuItem(title: control.label, action: action, keyEquivalent: "")
            overflowItem.target = target
            overflowItem.image = NSImage(systemSymbolName: control.symbol, accessibilityDescription: control.label)
            overflowItems[control] = overflowItem
            overflowMenu.addItem(overflowItem)
        }

        translatesAutoresizingMaskIntoConstraints = false
        var layoutConstraints = [
            widthAnchor.constraint(equalToConstant: width),
            heightAnchor.constraint(equalToConstant: Self.outerHeight),
        ]
        if divider != nil {
            layoutConstraints.append(
                semanticDivider.widthAnchor.constraint(equalToConstant: Self.dividerSize.width))
            layoutConstraints.append(
                semanticDivider.heightAnchor.constraint(equalToConstant: Self.dividerSize.height))
        }
        for (index, view) in visualViews.enumerated() {
            layoutConstraints.append(view.centerYAnchor.constraint(equalTo: centerYAnchor))
            if index == 0 {
                layoutConstraints.append(
                    view.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.horizontalInset))
            } else {
                layoutConstraints.append(
                    view.leadingAnchor.constraint(
                        equalTo: visualViews[index - 1].trailingAnchor,
                        constant: Self.internalSpacing))
            }
        }
        if let last = visualViews.last {
            layoutConstraints.append(
                last.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Self.horizontalInset))
        }
        NSLayoutConstraint.activate(layoutConstraints)
        refreshSurface()
    }

    required init?(coder: NSCoder) { fatalError() }

    func setOn(_ on: Bool, for control: Control) {
        buttons[control]?.setOn(on)
        overflowItems[control]?.state = on ? .on : .off
    }

    func setStatus(_ status: SegmentStatus, for control: Control) {
        buttons[control]?.setStatus(status)
    }

    /// The segment's right-click / Control-click menu. Built by the controller, which owns the
    /// stores these menus read.
    func setContextMenu(_ menu: NSMenu, for control: Control) {
        buttons[control]?.menu = menu
    }

    func status(for control: Control) -> SegmentStatus {
        buttons[control]?.status ?? .none
    }

    func setEnabled(_ enabled: Bool, for control: Control) {
        buttons[control]?.isEnabled = enabled
        overflowItems[control]?.isEnabled = enabled
    }

    func setToolTip(_ toolTip: String, for control: Control) {
        buttons[control]?.toolTip = toolTip
    }

    func button(for control: Control) -> ToolbarToggleButton? {
        buttons[control]
    }

    func makeMenuFormRepresentation() -> NSMenuItem {
        let root = NSMenuItem(title: menuTitle, action: nil, keyEquivalent: "")
        root.submenu = overflowMenu
        return root
    }

    /// Focused regression seam: global controls remain visibly separate from workspace tools.
    var arrangedSubviewsForTesting: [NSView] { visualViews }

    // MARK: - Per-segment context menus
    //
    // NSToolbar claims right-clicks anywhere in the toolbar for its own "Icon Only / Customize
    // Toolbar…" menu: the event never reaches the hosted view, so an overridden `rightMouseDown`
    // (or a `menu` on the button) is silently dead — verified by instrumenting the running app.
    // A local monitor sees the event before `sendEvent(_:)` dispatches it, so the segment can claim
    // its own menu and swallow the event; anything outside a segment falls through to the toolbar's
    // menu, which is still the right behavior for the rest of the strip.

    private var contextMenuMonitor: Any?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { removeContextMenuMonitor() } else { installContextMenuMonitor() }
    }

    private func installContextMenuMonitor() {
        guard contextMenuMonitor == nil else { return }
        contextMenuMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.rightMouseDown, .leftMouseDown]
        ) { [weak self] event in
            // Control-click is the other way to ask for a context menu; a plain left click must
            // pass straight through to the button.
            guard event.type == .rightMouseDown || event.modifierFlags.contains(.control) else {
                return event
            }
            // Only plain values cross into the isolated region — NSEvent and NSWindow are not
            // Sendable, and capturing them here is a hard error under the Swift 6 language mode.
            let location = event.locationInWindow
            let windowNumber = event.windowNumber
            let claimed = MainActor.assumeIsolated { () -> Bool in
                guard let self, self.window?.windowNumber == windowNumber else { return false }
                let local = self.convert(location, from: nil)
                guard let button = self.segment(at: local),
                      button.isEnabled, button.menu != nil else { return false }
                button.showContextMenu()
                return true
            }
            return claimed ? nil : event
        }
    }

    private func removeContextMenuMonitor() {
        if let monitor = contextMenuMonitor { NSEvent.removeMonitor(monitor) }
        contextMenuMonitor = nil
    }

    private func segment(at point: NSPoint) -> ToolbarToggleButton? {
        buttons.values.first { $0.frame.contains(point) }
    }

    func overflowItem(for control: Control) -> NSMenuItem? { overflowItems[control] }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refreshSurface()
    }

    private func refreshSurface() {
        let appearance = effectiveAppearance
        layer?.backgroundColor = NSColor.nSurface
            .mechanicianCGColor(in: appearance, alpha: 0.72)
        layer?.borderColor = NSColor.separatorColor
            .mechanicianCGColor(in: appearance, alpha: 0.34)
        semanticDivider.layer?.backgroundColor = NSColor.separatorColor
            .mechanicianCGColor(in: appearance, alpha: 0.5)
    }
}

/// A segment inside `ToolbarUtilityDeck`. Idle segments have no independent outline or tile; only
/// hover, press, and selected state paint inside the deck's shared surface.
@MainActor
final class ToolbarToggleButton: NSButton {
    private static let statusDotSize: CGFloat = 5.5
    private static let statusDotInset: CGFloat = 4

    private var isOn = false
    private var hovering = false
    private var pressing = false
    private(set) var status: ToolbarUtilityDeck.SegmentStatus = .none
    /// Drawn as a layer rather than a composed image so the idle segment's own background stays
    /// fully transparent — the deck's shared surface must remain the only tile at rest.
    private let statusDot = CALayer()

    init(
        symbol: String,
        target: AnyObject,
        action: Selector,
        symbolPointSize: CGFloat = 13
    ) {
        super.init(frame: NSRect(origin: .zero, size: ToolbarUtilityDeck.segmentSize))
        let configuration = NSImage.SymbolConfiguration(pointSize: symbolPointSize, weight: .medium)
        self.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(configuration)
        self.imagePosition = .imageOnly
        self.imageScaling = .scaleProportionallyDown
        self.target = target
        self.action = action
        self.isBordered = false
        self.bezelStyle = .toolbar
        self.focusRingType = .default
        self.wantsLayer = true
        self.layer?.cornerRadius = 7
        self.layer?.cornerCurve = .continuous
        self.layer?.borderWidth = 0
        statusDot.cornerRadius = Self.statusDotSize / 2
        statusDot.isHidden = true
        layer?.addSublayer(statusDot)
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: ToolbarUtilityDeck.segmentSize.width).isActive = true
        heightAnchor.constraint(equalToConstant: ToolbarUtilityDeck.segmentSize.height).isActive = true
        setAccessibilityValue("Off")
        refresh()
    }
    required init?(coder: NSCoder) { fatalError() }

    /// AppKit normally maps AXPress through an `NSButtonCell`, but these borderless segments live
    /// inside one custom toolbar view and did not reliably forward the accessibility action. Make
    /// the same target/action path explicit so VoiceOver and UI automation exercise the real click.
    override func accessibilityPerformPress() -> Bool {
        guard isEnabled else { return false }
        performClick(nil)
        return true
    }

    /// `NSButton`'s default toolbar alignment rect varies with the SF Symbol/bezel and inflated the
    /// five nominally equal 28-point segments to visibly different 33–37-point frames in build 115.
    /// The deck supplies the optical surface, so every segment must use its literal frame.
    override var alignmentRectInsets: NSEdgeInsets {
        NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)
    }

    /// Full Keyboard Access draws the ring from this mask; without it AppKit rings the default
    /// square cell instead of the 7-point tile the segment actually paints.
    override func drawFocusRingMask() {
        NSBezierPath(roundedRect: bounds, xRadius: 7, yRadius: 7).fill()
    }
    override var focusRingMaskBounds: NSRect { bounds }

    override func layout() {
        super.layout()
        // Top-trailing, clear of the centered symbol. `NSButton` is a FLIPPED view, so AppKit gives
        // its backing layer flipped geometry too and the top edge is minY, not maxY.
        let top = isFlipped
            ? Self.statusDotInset
            : bounds.maxY - Self.statusDotSize - Self.statusDotInset
        statusDot.frame = NSRect(
            x: bounds.maxX - Self.statusDotSize - Self.statusDotInset,
            y: top,
            width: Self.statusDotSize,
            height: Self.statusDotSize)
    }

    func setOn(_ on: Bool) {
        isOn = on
        state = on ? .on : .off
        setAccessibilityValue(on ? "On" : "Off")
        refresh()
    }

    /// The dot is deliberately silent to VoiceOver: the controller states the same condition in the
    /// tooltip, which AppKit already surfaces as the control's accessibility help.
    func setStatus(_ status: ToolbarUtilityDeck.SegmentStatus) {
        guard status != self.status else { return }
        self.status = status
        refresh()
    }

    override var isEnabled: Bool { didSet { refresh() } }

    /// The hover area this control installs, kept so it can be removed WITHOUT removing anyone
    /// else's.
    ///
    /// `trackingAreas.forEach(removeTrackingArea)` used to run here, and it took AppKit's own areas
    /// with it — including the one that shows a tooltip. That is why every toolbar button had a
    /// `toolTip` set in code, reported it correctly to VoiceOver as accessibility help, and never
    /// showed anything on hover: the property is read directly by the accessibility layer, but the
    /// visible tooltip needs the tracking AppKit installs and this method deleted.
    private var hoverTracking: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTracking { removeTrackingArea(hoverTracking) }
        let area = NSTrackingArea(rect: bounds,
            options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self)
        addTrackingArea(area)
        hoverTracking = area
        syncHoverWithPointer()
    }

    /// The control moved. Its new frame is what decides whether the pointer is still over it, so
    /// this is the hook that matters — constraint changes alone are too early to ask.
    override func setFrameOrigin(_ newOrigin: NSPoint) {
        super.setFrameOrigin(newOrigin)
        syncHoverWithPointer()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        syncHoverWithPointer()
    }

    /// `mouseExited` only fires when the POINTER leaves; a control that moves out from under a
    /// stationary pointer never gets one. Both panel toggles do exactly that — the right-panel
    /// button slides with the inspector and the sidebar button rides the split divider — so
    /// toggling a panel used to strand the grey hover fill until the next mouse move. Re-derive
    /// hover from where the pointer actually is whenever this control is laid out or moved.
    func syncHoverWithPointer() {
        guard let window, NSApp.isActive else {
            applyHover(false)
            return
        }
        applyHover(bounds.contains(convert(window.mouseLocationOutsideOfEventStream, from: nil)))
    }

    /// Seam for tests: the decision is "is the pointer inside my CURRENT frame", independent of
    /// where the real cursor happens to be while the suite runs.
    func applyHover(_ inside: Bool) {
        guard inside != hovering else { return }
        hovering = inside
        refresh()
    }

    var isShowingHoverSurface: Bool { hovering }

    override func mouseEntered(with event: NSEvent) { hovering = true; refresh() }
    override func mouseExited(with event: NSEvent) { hovering = false; refresh() }
    override func mouseDown(with event: NSEvent) {
        pressing = true
        refresh()
        super.mouseDown(with: event)
        pressing = false
        refresh()
    }

    /// Hang the segment's menu off its bottom edge like a pull-down rather than dropping it at the
    /// pointer, so it reads as belonging to this control. Driven by the deck's event monitor, not
    /// `rightMouseDown` — see `ToolbarUtilityDeck.installContextMenuMonitor`.
    func showContextMenu() {
        guard let menu, isEnabled else { return }
        pressing = true
        refresh()
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: bounds.maxY + 4), in: self)
        pressing = false
        refresh()
    }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refresh()
    }

    private func refresh() {
        let bg: NSColor
        if !isEnabled {
            bg = .clear
        } else if pressing {
            bg = isOn
                ? NSColor.controlAccentColor.withAlphaComponent(0.22)
                : NSColor.nElevated.withAlphaComponent(0.92)
        } else if isOn {
            bg = NSColor.controlAccentColor.withAlphaComponent(hovering ? 0.19 : 0.14)
        } else if hovering {
            bg = NSColor.nElevated.withAlphaComponent(0.82)
        } else {
            bg = .clear
        }
        let appearance = effectiveAppearance
        layer?.backgroundColor = bg.mechanicianCGColor(in: appearance)
        contentTintColor = !isEnabled ? .tertiaryLabelColor
            : (isOn ? .controlAccentColor : .secondaryLabelColor)
        // A disabled control cannot be acted on, so it must not claim attention either.
        let dot = isEnabled ? status.color : nil
        statusDot.isHidden = dot == nil
        statusDot.backgroundColor = dot?.mechanicianCGColor(in: appearance)
    }
}
