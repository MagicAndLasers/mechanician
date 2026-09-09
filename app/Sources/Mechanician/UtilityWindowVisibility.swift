import AppKit
import SwiftUI

/// The app-wide utility windows controlled by the workspace toolbar. These are singleton
/// SwiftUI `Window` scenes, but their toolbar controls behave like native visibility toggles.
enum UtilityWindowID: String, CaseIterable, Sendable {
    case accounts
    case extensions
    case artifacts
    case ambient

    var windowIdentifier: NSUserInterfaceItemIdentifier {
        NSUserInterfaceItemIdentifier("Mechanician.Utility.\(rawValue)")
    }
}

/// Every non-toolbar Providers entry point focuses the same global Provider Center. The toolbar
/// remains a visible show/hide affordance; links and recovery actions must never accidentally close
/// the center merely because it is already onscreen.
@MainActor func showProviders(using openWindow: OpenWindowAction? = nil) {
    UtilityWindowVisibility.shared.show(.accounts) {
        (openWindow ?? appOpenWindow)?(id: "accounts")
    }
}

/// App-wide truth for utility-window visibility. Every workspace toolbar observes the same set, so
/// closing a shared utility window updates every toolbar instead of only the window that opened it.
///
/// SwiftUI can retain a closed `Window` scene's native window. Stable identifiers let us reopen that
/// retained window directly rather than asking SwiftUI to create a duplicate scene.
@MainActor
final class UtilityWindowVisibility: ObservableObject {
    enum ToggleResult: Equatable {
        case requestedClose
        case showedExisting
        case requestedOpen
    }

    static let shared = UtilityWindowVisibility()

    @Published private(set) var visibleIDs: Set<UtilityWindowID> = []

    private let notificationCenter: NotificationCenter
    private let windows: @MainActor () -> [NSWindow]
    private var observers: [NSObjectProtocol] = []

    init(
        notificationCenter: NotificationCenter = .default,
        windows: @MainActor @escaping () -> [NSWindow] = { NSApp.windows }
    ) {
        self.notificationCenter = notificationCenter
        self.windows = windows

        let windowNotifications: [Notification.Name] = [
            NSWindow.willCloseNotification,
            NSWindow.didMiniaturizeNotification,
            NSWindow.didDeminiaturizeNotification,
            NSWindow.didChangeOcclusionStateNotification,
        ]
        for name in windowNotifications {
            observers.append(notificationCenter.addObserver(
                forName: name,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                Task { @MainActor [weak self] in
                    self?.windowStateDidChange(notification)
                }
            })
        }
        observers.append(notificationCenter.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.refreshAll() }
        })
    }

    deinit {
        for observer in observers { notificationCenter.removeObserver(observer) }
    }

    func register(_ window: NSWindow, as id: UtilityWindowID) {
        window.identifier = id.windowIdentifier
        refresh(id)
        // SwiftUI can attach the marker before ordering its scene window onscreen. A second pass
        // captures that normal creation sequence even when the window was opened outside the toolbar.
        refreshOnNextRunLoop(id)
    }

    func isVisible(_ id: UtilityWindowID) -> Bool {
        visibleIDs.contains(id)
    }

    /// Posted when a toolbar toggle wants a utility window closed while a sheet is attached to it.
    ///
    /// AppKit REFUSES `performClose` on a window with a sheet, so the control did nothing at all
    /// while a dialog was up — pressing a deck segment with a sheet up was a dead button. The
    /// sheet cannot simply be ended from here either: these are SwiftUI sheets driven by a binding,
    /// and dismissing the window's sheet without clearing that binding re-presents it immediately.
    /// So the view is asked to put its own dialogs away, and the close follows on the next turn of
    /// the run loop once the sheet has actually detached.
    static let dismissSheets = Notification.Name("MechanicianDismissUtilitySheets")

    /// Toggle one shared utility window. A retained hidden/minimized scene is reused; only a truly
    /// absent scene asks SwiftUI to open a window.
    @discardableResult
    func toggle(_ id: UtilityWindowID, open: () -> Void) -> ToggleResult {
        if let window = window(for: id) {
            if window.isVisible && !window.isMiniaturized {
                if window.attachedSheet != nil {
                    NotificationCenter.default.post(
                        name: Self.dismissSheets, object: nil,
                        userInfo: ["window": id.rawValue])
                    DispatchQueue.main.async { [weak window] in
                        guard let window else { return }
                        if window.attachedSheet == nil { window.performClose(nil) }
                    }
                    refreshOnNextRunLoop(id)
                    return .requestedClose
                }
                window.performClose(nil)
                refresh(id)
                refreshOnNextRunLoop(id)
                return .requestedClose
            }

            return show(id, open: open)
        }

        return show(id, open: open)
    }

    /// Focus one shared utility window without treating an already-visible window as a request to
    /// close it. Contextual entry points (model picker, setup errors, Settings links) use this;
    /// only the persistent toolbar control retains native toggle behavior.
    @discardableResult
    func show(_ id: UtilityWindowID, open: () -> Void) -> ToggleResult {
        if let window = window(for: id) {
            NSApp.activate(ignoringOtherApps: true)
            if window.isMiniaturized { window.deminiaturize(nil) }
            window.makeKeyAndOrderFront(nil)
            refresh(id)
            refreshOnNextRunLoop(id)
            return .showedExisting
        }

        NSApp.activate(ignoringOtherApps: true)
        open()
        refreshOnNextRunLoop(id)
        return .requestedOpen
    }

    func refreshAll() {
        let current = Set(UtilityWindowID.allCases.filter { actualVisibility(of: $0) })
        if visibleIDs != current { visibleIDs = current }
    }

    private func window(for id: UtilityWindowID) -> NSWindow? {
        windows().first { $0.identifier == id.windowIdentifier }
    }

    private func actualVisibility(of id: UtilityWindowID) -> Bool {
        guard let window = window(for: id) else { return false }
        return window.isVisible && !window.isMiniaturized
    }

    private func refresh(_ id: UtilityWindowID) {
        var next = visibleIDs
        if actualVisibility(of: id) { next.insert(id) }
        else { next.remove(id) }
        if visibleIDs != next { visibleIDs = next }
    }

    private func refreshOnNextRunLoop(_ id: UtilityWindowID) {
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated { self?.refresh(id) }
        }
    }

    private func windowStateDidChange(_ notification: Notification) {
        guard let window = notification.object as? NSWindow,
              let id = UtilityWindowID.allCases.first(where: {
                  window.identifier == $0.windowIdentifier
              }) else { return }

        // `willClose` fires before AppKit clears `isVisible`; defer that refresh. The other native
        // notifications can update immediately, and a deferred pass covers SwiftUI ordering.
        if notification.name == NSWindow.willCloseNotification {
            refreshOnNextRunLoop(id)
        } else {
            refresh(id)
            refreshOnNextRunLoop(id)
        }
    }
}

/// Marks a SwiftUI utility-window scene with its stable native identity and registers it with the
/// shared visibility owner as soon as AppKit attaches the hosted view to an `NSWindow`.
private struct UtilityWindowMarker: NSViewRepresentable {
    let id: UtilityWindowID

    final class MarkerView: NSView {
        let id: UtilityWindowID

        init(id: UtilityWindowID) {
            self.id = id
            super.init(frame: .zero)
        }

        required init?(coder: NSCoder) { fatalError() }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let window { UtilityWindowVisibility.shared.register(window, as: id) }
        }
    }

    func makeNSView(context: Context) -> NSView { MarkerView(id: id) }

    func updateNSView(_ nsView: NSView, context: Context) {
        guard let marker = nsView as? MarkerView, let window = marker.window else { return }
        UtilityWindowVisibility.shared.register(window, as: id)
    }
}

extension View {
    func tracksUtilityWindow(_ id: UtilityWindowID) -> some View {
        background(UtilityWindowMarker(id: id).frame(width: 0, height: 0))
    }
}
