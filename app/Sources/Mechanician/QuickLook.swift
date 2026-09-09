import SwiftUI
import Quartz

/// A zero-size AppKit view that drives the native Quick Look panel for the file browser.
/// It sits in the window's responder chain so `QLPreviewPanel` routes its data-source
/// callbacks here. Quick Look is a top-level *system* window, so it is unbounded by the
/// inspector's width — and it renders far more than the inline peek (Office/iWork, syntax-
/// highlighted source, audio/video with transport, 3D, archives, and files past the inline
/// 2 MB text gate). Space-to-preview is the most ingrained Finder gesture on macOS; an
/// Electron app can't invoke it at all.
final class QLBridgeView: NSView, QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    /// The currently-selected file (nil for a folder / no selection); Quick Look previews its
    /// whole folder, positioned here, so ←/→ walks the folder exactly like Finder. When it
    /// changes to a file we grab keyboard focus, so Space reliably previews it (Finder's
    /// gesture) regardless of which SwiftUI subview last had focus.
    var target: URL? {
        didSet {
            guard target != oldValue, target != nil, let window else { return }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.target != nil else { return }
                window.makeFirstResponder(self)
            }
        }
    }

    private var urls: [URL] = []
    private var currentIndex = 0
    private weak var priorResponder: NSResponder?

    override var acceptsFirstResponder: Bool { true }

    /// Space → Quick Look (Finder). Other keys fall through to normal handling.
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 49 { // space
            toggle()
        } else {
            super.keyDown(with: event)
        }
    }

    /// Open Quick Look on the current target — or close it if it's already showing ours.
    /// Markdown routes to the RENDERED preview (this view owns the Space key as first responder, so
    /// without this a Space-preview of a `.md` would fall through to the system panel's raw source).
    func toggle() {
        if let t = target, QuickLookController.isMarkdown(t) {
            MarkdownQuickLook.shared.toggle(t)
            return
        }
        if QLPreviewPanel.sharedPreviewPanelExists(),
           let panel = QLPreviewPanel.shared(), panel.isVisible, panel.dataSource === self {
            panel.orderOut(nil)
        } else {
            open()
        }
    }

    /// Open Quick Look on a specific file now (e.g. a right-clicked row) without waiting for
    /// the selection to round-trip through SwiftUI.
    func present(_ url: URL) {
        if QuickLookController.isMarkdown(url) {
            target = url
            MarkdownQuickLook.shared.show(url)
            return
        }
        target = url
        open()
    }

    private func open() {
        guard let target, let window else { return }
        let parent = target.deletingLastPathComponent()
        let files = ((try? FileManager.default.contentsOfDirectory(
            at: parent, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])) ?? [])
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == false }
            .sorted { $0.lastPathComponent.localizedCaseInsensitiveCompare($1.lastPathComponent) == .orderedAscending }
        urls = files.isEmpty ? [target] : files
        currentIndex = urls.firstIndex(of: target) ?? 0

        priorResponder = window.firstResponder
        window.makeFirstResponder(self) // Quick Look walks the responder chain from here
        guard let panel = QLPreviewPanel.shared() else { return }
        panel.updateController()
        panel.makeKeyAndOrderFront(nil)
        panel.reloadData()
        panel.currentPreviewItemIndex = min(max(currentIndex, 0), urls.count - 1)
    }

    /// Keep the panel positioned on the current selection while it's open.
    func syncSelection() {
        guard QLPreviewPanel.sharedPreviewPanelExists(),
              let panel = QLPreviewPanel.shared(), panel.isVisible,
              panel.dataSource === self,
              let target, let i = urls.firstIndex(of: target) else { return }
        panel.currentPreviewItemIndex = i
    }

    // MARK: Responder-chain control (informal QLPreviewPanelController on NSResponder)

    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool { true }

    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        panel.dataSource = self
        panel.delegate = self
    }

    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
        if let priorResponder { window?.makeFirstResponder(priorResponder) }
        priorResponder = nil
    }

    // MARK: Data source

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { urls.count }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
        urls.indices.contains(index) ? urls[index] as NSURL : nil
    }
}

/// SwiftUI handle to the Quick Look bridge — `toggle()` from a button, menu, or Space key.
/// Markdown files are routed to a RENDERED preview (same MarkdownText renderer as the inline
/// preview pane) instead of the system QLPreviewPanel, which shows `.md` as raw source.
@MainActor final class QuickLookController: ObservableObject {
    fileprivate weak var bridge: QLBridgeView?

    func toggle() {
        if let url = bridge?.target, Self.isMarkdown(url) {
            MarkdownQuickLook.shared.toggle(url)
        } else {
            MarkdownQuickLook.shared.hide()
            bridge?.toggle()
        }
    }

    func preview(_ url: URL) {
        if Self.isMarkdown(url) {
            MarkdownQuickLook.shared.show(url)
        } else {
            MarkdownQuickLook.shared.hide()
            bridge?.present(url)
        }
    }

    static func isMarkdown(_ url: URL) -> Bool {
        let e = url.pathExtension.lowercased()
        return e == "md" || e == "markdown" || e == "mdown" || e == "mkd"
    }
}

/// A floating panel that renders a markdown file with the app's MarkdownText, so Quick Look on a
/// `.md` shows it formatted (headings, code, lists) rather than as plain source.
@MainActor final class MarkdownQuickLook {
    static let shared = MarkdownQuickLook()
    private var panel: NSPanel?

    func toggle(_ url: URL) {
        if let p = panel, p.isVisible { p.orderOut(nil) } else { show(url) }
    }
    func hide() { panel?.orderOut(nil) }

    func show(_ url: URL) {
        let text = (try? String(contentsOf: url, encoding: .utf8)) ?? "*(could not read this file)*"
        let host = NSHostingController(rootView: MarkdownQuickLookView(text: text))
        let p: NSPanel
        if let existing = panel {
            p = existing
        } else {
            // Default to a tall panel — most previewed docs are long, so favor height. Sized to the
            // screen (up to ~92% tall) so it's genuinely tall on any display, not a fixed 820pt.
            let vf = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1200, height: 900)
            let w = min(820, vf.width * 0.6)
            let h = min(1100, vf.height * 0.92)
            p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: w, height: h),
                        styleMask: [.titled, .closable, .resizable, .utilityWindow, .nonactivatingPanel],
                        backing: .buffered, defer: false)
            p.isFloatingPanel = true
            p.hidesOnDeactivate = false
            p.center()
            panel = p
        }
        p.title = url.lastPathComponent
        p.contentViewController = host
        p.makeKeyAndOrderFront(nil)
    }
}

private struct MarkdownQuickLookView: View {
    let text: String
    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                MarkdownText(text: text)
                    .textSelection(.enabled)
                    .frame(maxWidth: 780, alignment: .leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(24)
                    .id(Self.topAnchor)
            }
            // Always open at the TOP of the document (a fresh hosted ScrollView can otherwise settle
            // mid-content). Deferred a runloop so the content has laid out first.
            .onAppear { DispatchQueue.main.async { proxy.scrollTo(Self.topAnchor, anchor: .top) } }
        }
        .frame(minWidth: 420, minHeight: 320)
        .background(Color.nBg)
        .background(WindowConfigurator())
    }
    private static let topAnchor = "md-quicklook-top"
}

/// Mounts a zero-size `QLBridgeView` in the view tree and keeps its target in sync with the
/// browser's selection.
struct QuickLookHost: NSViewRepresentable {
    let selected: URL?
    let controller: QuickLookController

    func makeNSView(context: Context) -> QLBridgeView {
        let v = QLBridgeView()
        controller.bridge = v
        return v
    }

    func updateNSView(_ nsView: QLBridgeView, context: Context) {
        controller.bridge = nsView
        nsView.target = selected
        nsView.syncSelection()
    }
}
