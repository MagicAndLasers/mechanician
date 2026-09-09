import SwiftUI
import AppKit

/// Inline slash-command autocomplete for the composer. As the user types "/…" at the start
/// of an empty prompt, a non-activating panel floats just above the composer listing the
/// matching skills (from the SDK's `supportedCommands()`, surfaced as `bridge.slashCommands`).
///
/// The panel deliberately never becomes key, so the NSTextView keeps first responder and the
/// user keeps typing to narrow the list. Navigation (↑/↓), accept (⏎/⇥) and dismiss (esc) are
/// routed from the text view's `doCommandBy` into this controller — see ChatInput.Coordinator.
/// This is the compose-time companion to the Skills window (Window ▸ Skills, ⌥⌘S).
final class SlashCompletionController {
    private var panel: NSPanel?
    let model = SlashCompletionModel()

    var isVisible: Bool { panel?.isVisible ?? false }
    var selected: SlashCommandInfo? { model.selectedCommand }

    /// Called when the user clicks or accepts a row; the coordinator inserts the command.
    var onAccept: (() -> Void)? {
        get { model.onAccept }
        set { model.onAccept = newValue }
    }

    /// Show or refresh the list with `matches`, anchored just above `anchor` (the text view).
    func show(_ matches: [SlashCommandInfo], anchor: NSView, prefix: String = "/") {
        model.prefixSymbol = prefix
        model.set(matches)
        guard let window = anchor.window else { return }
        let panel = ensurePanel()

        // Size to the list's natural height (capped), width tracking the composer.
        let width = max(340, min(560, anchor.convert(anchor.bounds, to: nil).width))
        panel.setContentSize(NSSize(width: width, height: 10))            // let it lay out…
        let fitH = panel.contentView?.fittingSize.height ?? 220
        let height = min(max(fitH, 44), 300)
        panel.setContentSize(NSSize(width: width, height: height))

        // Place the panel's bottom edge a few points above the composer's top edge.
        let rectInWindow = anchor.convert(anchor.bounds, to: nil)
        let screenRect = window.convertToScreen(rectInWindow)
        panel.setFrameOrigin(NSPoint(x: screenRect.minX, y: screenRect.maxY + 6))

        if panel.parent == nil { window.addChildWindow(panel, ordered: .above) }
        panel.orderFront(nil)
    }

    func hide() {
        guard let p = panel else { return }
        // `hidesOnDeactivate` can order the panel out before hide() runs. Detach it from the
        // workspace window unconditionally so its ordering group never keeps a stale child.
        p.parent?.removeChildWindow(p)
        if p.isVisible { p.orderOut(nil) }
    }

    func moveSelection(_ delta: Int) { model.move(delta) }

    private func ensurePanel() -> NSPanel {
        if let p = panel { return p }
        let hosting = NSHostingView(rootView: SlashCompletionList(model: model))
        hosting.autoresizingMask = [.width, .height]
        let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 420, height: 220),
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: true)
        p.isFloatingPanel = true
        p.level = .popUpMenu
        p.hasShadow = true
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hidesOnDeactivate = true
        p.contentView = hosting
        panel = p
        return p
    }
}

/// Observable state shared between the controller and its SwiftUI list.
final class SlashCompletionModel: ObservableObject {
    @Published var matches: [SlashCommandInfo] = []
    @Published var selection: Int = 0
    /// Glyph shown before each item's name — "/" for commands, "" for @-path completion.
    @Published var prefixSymbol: String = "/"
    var onAccept: (() -> Void)?

    var selectedCommand: SlashCommandInfo? {
        matches.indices.contains(selection) ? matches[selection] : nil
    }

    /// Replace the visible matches. Keep the highlight on the same command if it survived the
    /// narrowing (feels stable while typing); otherwise reset to the top.
    func set(_ m: [SlashCommandInfo]) {
        let prior = selectedCommand?.name
        matches = m
        if let prior, let i = m.firstIndex(where: { $0.name == prior }) {
            selection = i
        } else {
            selection = 0
        }
    }

    func move(_ delta: Int) {
        guard !matches.isEmpty else { return }
        selection = (selection + delta + matches.count) % matches.count
    }
}

/// The completion list itself — one row per match, the selected row accented. Rows are
/// click-to-accept; the height is driven by content (the controller caps and scrolls it).
struct SlashCompletionList: View {
    @ObservedObject var model: SlashCompletionModel

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 1) {
                    ForEach(Array(model.matches.enumerated()), id: \.element.id) { idx, cmd in
                        row(cmd, selected: idx == model.selection)
                            .id(idx)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                model.selection = idx
                                model.onAccept?()
                            }
                    }
                }
                .padding(.vertical, 5)
            }
            .onChange(of: model.selection) { _, sel in
                withAnimation(.linear(duration: 0.08)) { proxy.scrollTo(sel, anchor: .center) }
            }
        }
        .background(Color.nSurface)
        .overlay(RoundedRectangle(cornerRadius: 11).strokeBorder(Color.nMuted.opacity(0.45)))
        .clipShape(RoundedRectangle(cornerRadius: 11))
    }

    private func row(_ cmd: SlashCommandInfo, selected: Bool) -> some View {
        HStack(spacing: 8) {
            // Command name never truncates; the hint gives way first, then the description.
            Text(model.prefixSymbol + cmd.name)
                .font(.system(size: 12.5, weight: .medium, design: .monospaced))
                .foregroundStyle(selected ? .white : Color.nInfoText)
                .lineLimit(1).truncationMode(.middle)
            if !cmd.argumentHint.isEmpty {
                Text(cmd.argumentHint)
                    .font(.system(size: 11.5, design: .monospaced))
                    .lineLimit(1).truncationMode(.tail)
                    .foregroundStyle(selected ? Color.white.opacity(0.7) : Color.secondary.opacity(0.75))
                    .layoutPriority(-1)
            }
            if cmd.description.isEmpty {
                Spacer(minLength: 0)
            } else {
                // Description flows immediately after the command, left-aligned, filling the
                // rest of the row (no far-right gap for short commands).
                Text(cmd.description)
                    .font(.system(size: 12))
                    .lineLimit(1).truncationMode(.tail)
                    .foregroundStyle(selected ? Color.white.opacity(0.9) : Color.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.leading, 2)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .frame(maxWidth: .infinity, alignment: .leading)
        // Inset, rounded selection pill — calmer than an edge-to-edge accent bar. Uses the
        // system selection color (stays saturated) so the white text is legible for ANY accent
        // (a pale accent like Yellow/Graphite would wash out white text on Color.nAccent).
        .background(RoundedRectangle(cornerRadius: 6)
            .fill(selected ? Color(nsColor: .selectedContentBackgroundColor) : Color.clear))
        .padding(.horizontal, 5)
    }
}
