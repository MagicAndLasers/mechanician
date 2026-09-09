import AppKit
import Combine

/// The destinations Mechanician always owns: **Home** and **Help**.
///
/// They are two different things in storage — Home is the folderless front door, Help is a
/// `ReservedWorkspace` with a fixed id — and one thing to a person: places the app put there, which
/// no workspace list may lose and which every surface should name, draw and route to identically.
/// The launcher already calls them out as rows above the workspace grid; this type is that same
/// set, so the toolbar and the workspace switcher cannot drift into a different one, a different
/// order, or a second glyph for the same place.
enum WorkspacePlace: String, CaseIterable, Identifiable {
    case home
    case help

    var id: String { rawValue }

    /// The reserved Workspace behind this place. Home has none — Home *is* the absence of one.
    var reserved: ReservedWorkspace? {
        switch self {
        case .home: nil
        case .help: .help
        }
    }

    /// The persisted Workspace id, or nil for Home.
    var workspaceID: UUID? { reserved?.id }

    var name: String {
        switch self {
        case .home: String(localized: "Home")
        case .help: ReservedWorkspace.help.name
        }
    }

    /// A HOUSE for Home, in the launcher card as well as the toolbar segment.
    ///
    /// It was the launcher's two speech bubbles, on the rule that a place wears one glyph
    /// everywhere. The rule is right and it was applied backwards: the launcher card carries the
    /// word "Home" and a line of description beside its glyph, while a toolbar segment is the glyph
    /// ALONE — and alone, two speech bubbles say "conversations", two slots from Help's own bubble.
    var iconSymbol: String {
        switch self {
        case .home: "house"
        case .help: ReservedWorkspace.help.iconSymbol
        }
    }

    /// The command that OPENS this place, shown in the toolbar help tag the way Apple's own
    /// toolbars do. Only the opening direction: nothing in the menus closes a place, so tagging the
    /// close direction with a shortcut would name a key that does something else.
    var openShortcutHint: String? {
        switch self {
        case .home: "⇧⌘H"
        case .help: nil
        }
    }

    /// Whether a window showing this `projectID`/`cwd` pair is standing in this place.
    func isShowing(projectID: UUID?, cwd: String) -> Bool {
        switch self {
        case .home: projectID == nil && cwd.isEmpty
        case .help: projectID != nil && projectID == workspaceID
        }
    }

    /// The place a window is standing in, if any. A folder or topic Workspace is in none of them.
    static func showing(projectID: UUID?, cwd: String) -> WorkspacePlace? {
        allCases.first { $0.isShowing(projectID: projectID, cwd: cwd) }
    }

    /// Create the Workspace on first use and return the existing row thereafter. Home completes
    /// with nil because it has no row: its ingress is `goHome(from:)`.
    @MainActor
    func ensure(in store: ProjectStore, then completion: @escaping (Project?) -> Void) {
        guard let reserved else {
            completion(nil)
            return
        }
        reserved.ensure(in: store, then: completion)
    }
}

/// One weak, published owner per place.
///
/// A workspace window can be open behind another window or as an inactive native tab. Neither
/// `NSWindow.isVisible` nor `NSApp.windows` is a reliable open/closed signal in those states, while
/// retaining the window here would keep a closed workspace alive. Each workspace toolbar registers
/// its window at creation and whenever it changes workspace, unregisters at the native close
/// boundary, and observes only the revision — so a place opened in one window lights up in every
/// other window's toolbar.
@MainActor
final class WorkspacePlaceWindowPresence: ObservableObject {
    static let shared = WorkspacePlaceWindowPresence()

    @Published private(set) var revision = 0
    private var owners: [WorkspacePlace: WeakWindow] = [:]

    func window(for place: WorkspacePlace) -> NSWindow? { owners[place]?.window }

    /// Claim `place` for this window, releasing whichever place it held before. A window that
    /// switches from Help to Home must not leave Help looking open.
    func register(_ window: NSWindow, for place: WorkspacePlace) {
        var changed = release(window, keeping: place)
        if owners[place]?.window !== window {
            owners[place] = WeakWindow(window)
            changed = true
        }
        if changed { revision &+= 1 }
    }

    func unregister(_ window: NSWindow) {
        if release(window, keeping: nil) { revision &+= 1 }
    }

    /// Drops every entry this window owns except `keeping`, and prunes entries whose window has
    /// already deallocated. Only a live removal is a change worth publishing; pruning a dead weak
    /// reference does not alter any answer this registry gives.
    private func release(_ window: NSWindow, keeping: WorkspacePlace?) -> Bool {
        var changed = false
        for (place, box) in owners where place != keeping {
            if box.window === window {
                owners[place] = nil
                changed = true
            } else if box.window == nil {
                owners[place] = nil
            }
        }
        return changed
    }
}

@MainActor
private final class WeakWindow {
    weak var window: NSWindow?
    init(_ window: NSWindow) { self.window = window }
}
