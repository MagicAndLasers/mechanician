import AppKit
import SwiftUI

/// A plain-text editor for source, as opposed to prose.
///
/// SwiftUI's `TextEditor` is a prose editor: it inherits the system's automatic substitutions, so
/// typing `-->` into it produces `–>`, `"x"` becomes `"x"`, and `...` becomes `…`. That is correct
/// for a sentence and wrong for every artifact type Mechanician has — a Mermaid arrow, an HTML
/// attribute, a CSV quote, a JSON string. The corruption is silent and happens at the keystroke, so
/// the source that is saved is not the source that was typed (FR-335). Pasting was never affected,
/// which is why this survived: anyone who pasted a diagram saw it work.
///
/// `TextEditor` exposes none of those settings, so this is an `NSTextView` with all of them off.
/// It stays deliberately small — no syntax highlighting, no completion, no drag handling. The
/// composer's `ComposerTextView` is the rich editor; this is the opposite of that on purpose.
struct SourceTextEditor: NSViewRepresentable {
    @Binding var text: String
    var fontSize: CGFloat = 12
    /// Matches the inset SwiftUI's `TextEditor` applies, so replacing one with the other does not
    /// visibly shift the text.
    var insets = NSSize(width: 5, height: 6)

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true

        guard let textView = scrollView.documentView as? NSTextView else { return scrollView }
        Self.configureAsSourceEditor(textView, fontSize: fontSize, insets: insets)
        textView.delegate = context.coordinator
        textView.string = text
        context.coordinator.textView = textView
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }
        context.coordinator.parent = self
        // Only when it actually differs: assigning `string` collapses the selection, so echoing the
        // value back on every SwiftUI update would move the caret to the end mid-edit.
        if textView.string != text {
            let selected = textView.selectedRange()
            textView.string = text
            let end = (text as NSString).length
            textView.setSelectedRange(NSRange(
                location: min(selected.location, end),
                length: min(selected.length, max(0, end - min(selected.location, end)))))
        }
        if textView.font?.pointSize != fontSize {
            textView.font = .monospacedSystemFont(ofSize: fontSize, weight: .regular)
        }
    }

    /// Every automatic substitution AppKit can apply to typed text, turned off in one place.
    ///
    /// `isAutomaticTextReplacementEnabled` is not a superset of the others — dashes, quotes and
    /// periods each have their own switch, and dash substitution is the one that breaks Mermaid.
    /// `smartInsertDeleteEnabled` is included because smart insert also adjusts surrounding spaces.
    @MainActor
    static func configureAsSourceEditor(
        _ textView: NSTextView,
        fontSize: CGFloat = 12,
        insets: NSSize = NSSize(width: 5, height: 6)
    ) {
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isAutomaticLinkDetectionEnabled = false
        textView.isAutomaticDataDetectionEnabled = false
        textView.smartInsertDeleteEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.isGrammarCheckingEnabled = false
        // The individual switches above are the ones AppKit consults while typing; this closes the
        // same door at the text-checking layer, which is where any future substitution type would
        // arrive. Zero means "check for nothing".
        textView.enabledTextCheckingTypes = 0
        // The same remote-completion service the composer already avoids (FB23642313). A source
        // editor has no use for it either way.
        RemoteTextServiceSafety.disableRemoteCompletion(on: textView)

        textView.isRichText = false
        textView.usesFontPanel = false
        textView.allowsUndo = true
        textView.font = .monospacedSystemFont(ofSize: fontSize, weight: .regular)
        textView.textColor = .labelColor
        textView.drawsBackground = false
        textView.textContainerInset = insets
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: SourceTextEditor
        weak var textView: NSTextView?

        init(_ parent: SourceTextEditor) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            parent.text = textView.string
        }
    }
}
