import SwiftUI
import SwiftTerm

/// The terminal dock: a tab strip over a stack of PTY-backed terminals. All tabs stay
/// alive (hidden with opacity) so switching preserves each shell's scrollback.
struct TerminalPanelView: View {
    @EnvironmentObject private var bridge: AgentBridge
    @AppStorage("uiTypeStep") private var typeStep = 0
    // Inline tab rename: double-click, right-click ▸ Rename, or click an already-active tab
    // (select-then-click, Finder-style) swaps the title for a field.
    @State private var editingTabId: String?
    @State private var pendingTabEdit: DispatchWorkItem?
    @State private var editText = ""
    @FocusState private var editorFocused: Bool

    /// Footprint of the per-tab close control. The tab reserves this whether or not the control is
    /// currently actionable, so a tab never changes width as tabs come and go.
    private let closeControlWidth: CGFloat = 12
    @Environment(\.colorScheme) private var colorScheme

    /// Matches TerminalEmulatorView.applyColors so the leading padding reads as the terminal's own
    /// inset rather than a seam against a different panel background.
    private var terminalBg: SwiftUI.Color {
        colorScheme == .dark
            ? SwiftUI.Color(nsColor: NSColor(srgbRed: 0.153, green: 0.157, blue: 0.169, alpha: 1))
            : .white
    }

    var body: some View {
        VStack(spacing: 0) {
            tabBar
                .environment(\.uiScale, uiScale(typeStep)) // scale the tab titles with ⌘+/-
            Divider()
            ZStack {
                terminalBg   // fills behind the leading inset so it reads as the terminal's own margin
                ForEach(bridge.terminals) { tab in
                    // The shell output is a native SwiftTerm view (ignores Dynamic Type),
                    // so scale its monospace font directly.
                    TerminalEmulatorView(termId: tab.id,
                                         isActive: tab.id == bridge.activeTerminalId,
                                         fontScale: uiScale(typeStep))
                        .opacity(tab.id == bridge.activeTerminalId ? 1 : 0)
                        .allowsHitTesting(tab.id == bridge.activeTerminalId)
                        .padding(.leading, 8)   // breathing room so the prompt doesn't jam the panel edge
                }
                if let id = bridge.activeTerminalId,
                   let location = bridge.terminalStartupLocation(for: id) {
                    VStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Starting terminal in \(location)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(terminalBg.opacity(0.94))
                    .allowsHitTesting(false)
                }
            }
        }
        .onAppear { bridge.ensureTerminal() }
    }

    private var tabBar: some View {
        HStack(spacing: 6) {
            ForEach(bridge.terminals) { tab in terminalTab(tab) }
            Button { bridge.addTerminal() } label: { Image(systemName: "plus").scaledFont(11) }
                .buttonStyle(.borderless).tint(.secondary).help("New terminal tab")
                .accessibilityLabel("New terminal tab")
            Spacer()
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Color.nSurface)
    }

    private func terminalTab(_ tab: TerminalTab) -> some View {
        let active = tab.id == bridge.activeTerminalId
        let editing = editingTabId == tab.id
        return HStack(spacing: 5) {
            Image(systemName: "terminal").scaledFont(10).foregroundStyle(.secondary)
            if editing {
                TextField("Tab name", text: $editText)
                    .textFieldStyle(.plain)
                    .scaledFont(11)
                    .focused($editorFocused)
                    .frame(minWidth: 36, maxWidth: 140)
                    .fixedSize(horizontal: true, vertical: false)
                    .onSubmit { commitRename(tab) }
                    .onExitCommand { editingTabId = nil } // esc cancels
                    .onChange(of: editorFocused) { _, focused in if !focused { commitRename(tab) } }
            } else {
                Text(tab.title).scaledFont(11).lineLimit(1)
                    .foregroundStyle(tab.exited ? .secondary : .primary)
            }
            // Reserve the close control's footprint even when it is not actionable. It used to be
            // added and removed with the tab count, so closing down to one tab resized the
            // survivor and closing among several reflowed the strip under the pointer mid-click.
            if !editing { Color.clear.frame(width: closeControlWidth, height: 1) }
        }
        .padding(.horizontal, 8).padding(.vertical, 3)
        // Selected tab: a subtle raised fill, not a loud accent outline.
        .background(RoundedRectangle(cornerRadius: 6)
            .fill(active ? Color.nAccent.opacity(0.16) : Color.nElevated))
        .contentShape(Rectangle())
        // Click a non-active tab → activate it. Click an ALREADY-active tab → inline rename after a
        // short delay (select-then-click). Double-click renames immediately (cancels the delay).
        .onTapGesture {
            guard !editing else { return }
            if active {
                let work = DispatchWorkItem { beginRename(tab) }
                pendingTabEdit?.cancel(); pendingTabEdit = work
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
            } else {
                bridge.activeTerminalId = tab.id
            }
        }
        .simultaneousGesture(TapGesture(count: 2).onEnded {
            pendingTabEdit?.cancel(); pendingTabEdit = nil; beginRename(tab)
        })
        // Layered after the tab's own gestures so the button hit-tests first. Previously the close
        // control sat inside the HStack under `.contentShape(Rectangle())` + `.onTapGesture`, so the
        // tab gesture frequently ate the first click — and on an already-active tab that click
        // scheduled a rename, which then fought the close.
        .overlay(alignment: .trailing) {
            if !editing, bridge.terminals.count > 1 {
                Button {
                    pendingTabEdit?.cancel()
                    pendingTabEdit = nil
                    bridge.closeTerminal(tab.id)
                } label: {
                    Image(systemName: "xmark")
                        .scaledFont(8)
                        .frame(width: closeControlWidth, height: closeControlWidth)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .padding(.trailing, 6)
                .help("Close tab")
                .accessibilityLabel("Close \(tab.title)")
            }
        }
        .contextMenu {
            Button("Rename…") { beginRename(tab) }
            if bridge.terminals.count > 1 {
                Button("Close Tab") { bridge.closeTerminal(tab.id) }
            }
        }
        .help(tab.exited ? "\(tab.title) (exited)" : tab.starting ? "\(tab.title) (starting)" : tab.title)
        .accessibilityLabel("\(tab.title)\(tab.exited ? ", exited" : tab.starting ? ", starting" : "")")
    }

    private func beginRename(_ tab: TerminalTab) {
        editText = tab.title
        editingTabId = tab.id
        bridge.activeTerminalId = tab.id
        DispatchQueue.main.async { editorFocused = true }
    }

    private func commitRename(_ tab: TerminalTab) {
        guard editingTabId == tab.id else { return } // ignore a stale blur after esc/switch
        bridge.renameTerminal(tab.id, to: editText)
        editingTabId = nil
    }
}

/// A `TerminalView` that grabs ⌘T while it holds keyboard focus and opens a new terminal
/// tab — the universal terminal convention. The key-window view hierarchy gets
/// `performKeyEquivalent` before the main menu, so this wins over the ⌘T "New Tab" menu
/// item, but only when the terminal is actually focused (otherwise it passes through and the
/// menu creates a workspace tab).
final class KeyInterceptTerminalView: TerminalView {
    var onNewTab: (() -> Void)?

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
           event.charactersIgnoringModifiers == "t",
           isTerminalFocused {
            onNewTab?()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    private var isTerminalFocused: Bool {
        guard let responder = window?.firstResponder else { return false }
        if responder === self { return true }
        return (responder as? NSView)?.isDescendant(of: self) ?? false
    }
}

/// A single PTY-backed terminal: SwiftTerm renders, agentd runs the shell keyed on
/// `termId`. User keystrokes go out as term_input; PTY output arrives via the feed.
struct TerminalEmulatorView: NSViewRepresentable {
    @EnvironmentObject private var bridge: AgentBridge
    @Environment(\.colorScheme) private var colorScheme
    let termId: String
    let isActive: Bool
    var fontScale: CGFloat = 1

    func makeCoordinator() -> Coordinator { Coordinator(bridge: bridge, termId: termId) }

    /// Terminal background/foreground that follow the app's Light/Dark appearance.
    private func applyColors(to tv: TerminalView, scheme: ColorScheme) {
        if scheme == .dark {
            tv.nativeBackgroundColor = NSColor(srgbRed: 0.153, green: 0.157, blue: 0.169, alpha: 1) // #272930
            tv.nativeForegroundColor = NSColor(srgbRed: 216 / 255, green: 222 / 255, blue: 233 / 255, alpha: 1) // #D8DEE9
        } else {
            tv.nativeBackgroundColor = .white
            tv.nativeForegroundColor = NSColor(srgbRed: 0.11, green: 0.11, blue: 0.13, alpha: 1) // #1C1C21
        }
        tv.needsDisplay = true
    }

    func makeNSView(context: Context) -> TerminalView {
        let tv = KeyInterceptTerminalView(frame: CGRect(x: 0, y: 0, width: 640, height: 220))
        tv.terminalDelegate = context.coordinator
        // ⌘T while the terminal is focused → a new terminal tab (terminal-app convention),
        // handled before the menu's ⌘T (new workspace tab).
        let bridge = context.coordinator.bridge
        tv.onNewTab = { Task { @MainActor in bridge.addTerminal() } }

        applyColors(to: tv, scheme: colorScheme)
        context.coordinator.lastScheme = colorScheme
        tv.font = NSFont.monospacedSystemFont(ofSize: 12 * fontScale, weight: .regular)
        context.coordinator.fontScale = fontScale

        // Feed this terminal's PTY output into the emulator as it arrives.
        bridge.registerTerminalFeed(termId) { [weak tv] text in tv?.feed(text: text) }

        // Start the shell at the emulator's current geometry.
        let terminal = tv.getTerminal()
        bridge.termStart(termId: termId, cols: terminal.cols, rows: terminal.rows)
        return tv
    }

    func updateNSView(_ nsView: TerminalView, context: Context) {
        let c = context.coordinator
        // Re-apply colors when the app's Light/Dark appearance flips.
        if c.lastScheme != colorScheme {
            c.lastScheme = colorScheme
            applyColors(to: nsView, scheme: colorScheme)
        }
        // Re-apply the monospace size when ⌘+/- changes the zoom; SwiftTerm reflows and
        // reports the new cols/rows via the delegate, which resizes the PTY.
        if c.fontScale != fontScale {
            c.fontScale = fontScale
            nsView.font = NSFont.monospacedSystemFont(ofSize: 12 * fontScale, weight: .regular)
        }
        // On becoming the active tab, take keyboard focus so typing goes here — but only
        // on the transition, so we don't fight other views for focus every render.
        if isActive, !c.wasActive, let win = nsView.window, win.firstResponder !== nsView {
            win.makeFirstResponder(nsView)
        }
        c.wasActive = isActive
    }

    /// Tab closed or panel hidden → drop the feed and kill this terminal's PTY.
    static func dismantleNSView(_ nsView: TerminalView, coordinator: Coordinator) {
        coordinator.bridge.unregisterTerminalFeed(coordinator.termId)
        coordinator.bridge.termKill(termId: coordinator.termId)
    }

    final class Coordinator: NSObject, TerminalViewDelegate {
        let bridge: AgentBridge
        let termId: String
        var wasActive = false
        var fontScale: CGFloat = 1
        var lastScheme: ColorScheme?
        init(bridge: AgentBridge, termId: String) { self.bridge = bridge; self.termId = termId }

        func send(source: TerminalView, data: ArraySlice<UInt8>) {
            let text = String(decoding: data, as: UTF8.self)
            Task { @MainActor in bridge.termInput(termId: termId, text) }
        }

        func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
            Task { @MainActor in bridge.termResize(termId: termId, cols: newCols, rows: newRows) }
        }

        func setTerminalTitle(source: TerminalView, title: String) {}
        func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
        func scrolled(source: TerminalView, position: Double) {}
        func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {}
        func bell(source: TerminalView) {}
        func clipboardCopy(source: TerminalView, content: Data) {}
        func iTermContent(source: TerminalView, content: ArraySlice<UInt8>) {}
        func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
    }
}
