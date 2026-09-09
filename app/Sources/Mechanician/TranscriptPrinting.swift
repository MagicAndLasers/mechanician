import AppKit
import Foundation

/// Printing a conversation.
///
/// An `NSTextView` that is never installed in a window, handed straight to `NSPrintOperation`.
/// Measured on macOS 27 before this was written, because both were open questions:
///
/// - `NSPrintOperation(view:)` runs fine for a view with no window — a 60-paragraph document
///   produced a correct 15-page PDF with `window == nil` throughout.
/// - `NSPrintHeaderAndFooter` is honored, so the job title, date, and "Page 1 of 15" come from
///   AppKit rather than from pagination code written here.
///
/// The alternative design — render markdown to HTML and print an offscreen `WKWebView` — was
/// rejected on those measurements. It needed a second markdown renderer that could disagree with the
/// screen, an async load inside a synchronous print panel, and custom pagination if WebKit declined
/// the header. This needs none of them.
@MainActor
enum TranscriptPrinting {
    /// US Letter minus one-inch margins. The text container is sized to this so pagination breaks
    /// where the page does; `NSPrintOperation` scales nothing.
    private static let contentWidth: CGFloat = 468

    /// Build the view a print operation will paginate. Separated from `print` so a test can inspect
    /// the laid-out document without a print panel.
    static func makePrintView(title: String, entries: [TranscriptEntry]) -> NSTextView {
        let content = TranscriptPrintDocument.attributedDocument(title: title, entries: entries)
        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: contentWidth, height: 1))
        textView.textStorage?.setAttributedString(content)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.textContainerInset = .zero
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.containerSize = NSSize(
            width: contentWidth, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = true
        // Print is always on white with black ink. A dynamic colour resolved while the app is in
        // Dark Mode is exactly what makes today's artifact Save as PDF print white on white
        // (FR-177); this view is pinned to Aqua so nothing it draws can inherit that.
        textView.appearance = NSAppearance(named: .aqua)
        textView.backgroundColor = .white
        textView.drawsBackground = true
        textView.sizeToFit()
        return textView
    }

    /// Print info for a conversation. `headerAndFooter` is what gets the job title, the date, and
    /// the page numbering without writing any of them.
    static func makePrintInfo() -> NSPrintInfo {
        guard let info = NSPrintInfo.shared.copy() as? NSPrintInfo else { return NSPrintInfo.shared }
        info.topMargin = 72
        info.bottomMargin = 72
        info.leftMargin = 72
        info.rightMargin = 72
        info.isVerticallyCentered = false
        info.isHorizontallyCentered = false
        info.horizontalPagination = .fit
        info.verticalPagination = .automatic
        info.dictionary()[NSPrintInfo.AttributeKey.headerAndFooter] = true
        return info
    }

    /// Run the print panel for a conversation. No-op when there is nothing printable, so ⌘P on an
    /// empty conversation does nothing rather than opening a panel over a blank page.
    static func print(title: String, entries: [TranscriptEntry], in window: NSWindow?) {
        guard !TranscriptPrintDocument.printableEntries(entries).isEmpty else { return }
        let operation = NSPrintOperation(
            view: makePrintView(title: title, entries: entries),
            printInfo: makePrintInfo())
        operation.jobTitle = title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "Conversation" : title
        // Sheet when there is a window to hang it on, modal otherwise — ⌘P is reachable from the
        // menu bar with only a utility window up.
        if let window {
            operation.runModal(for: window, delegate: nil, didRun: nil, contextInfo: nil)
        } else {
            operation.run()
        }
    }
}
