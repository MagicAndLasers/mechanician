import AppKit

/// Owns first-responder state for one window's composer.
///
/// The composer's editor is an `NSTextView`, but focus used to be requested from SwiftUI by bumping
/// an integer token that `ChatInput.updateNSView` watched, then hopping through
/// `DispatchQueue.main.async` to call `makeFirstResponder`. That seam caused real bugs: nothing
/// could ask whether the composer *had* focus, every navigation path had to remember to bump the
/// token (selecting a conversation silently did not), and the async hop raced AppKit's own
/// responder handling when a window became key.
///
/// Focus is a responder-chain concern, so it belongs on this side of the bridge. SwiftUI keeps
/// declaring the view; AppKit decides who is typing.
@MainActor
final class ComposerFocusController {
    private weak var textView: NSTextView?

    /// Whether the composer is the active editor of its own window. Callers that want to avoid
    /// stealing focus from somewhere the user deliberately went can consult this rather than
    /// guessing.
    var isFocused: Bool {
        guard let textView, let window = textView.window else { return false }
        // A focused text view is represented in the responder chain by its field editor, so an
        // identity check against the text view alone reports false while it is genuinely focused.
        guard let responder = window.firstResponder else { return false }
        if responder === textView { return true }
        guard let view = responder as? NSView else { return false }
        return view.isDescendant(of: textView)
    }

    func attach(_ textView: NSTextView) {
        self.textView = textView
        adoptAsInitialResponder()
    }

    func detach(_ textView: NSTextView) {
        guard self.textView === textView else { return }
        self.textView = nil
    }

    /// Make the composer the responder AppKit picks when the window first becomes key. This is what
    /// focuses a freshly launched or newly opened window without a timed request, and it is why
    /// the sidebar's search field no longer wins the race at startup.
    func adoptAsInitialResponder() {
        guard let textView, let window = textView.window else { return }
        window.initialFirstResponder = textView
    }

    /// Idempotent, and safe to call from anywhere — including during a SwiftUI update, where
    /// synchronously reshuffling the responder chain can re-enter view updates.
    ///
    /// Scoped to the text view's own window: a background window adopting a conversation moves its
    /// own responder without pulling focus away from the window in front.
    func takeFocus() {
        adoptAsInitialResponder()
        guard !isFocused, let textView, textView.window != nil else { return }
        // Coalesced to the next turn of the run loop so a focus request raised while SwiftUI is
        // committing an update lands after that update, not inside it.
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.isFocused,
                  let textView = self.textView,
                  let window = textView.window,
                  textView.acceptsFirstResponder else { return }
            window.makeFirstResponder(textView)
        }
    }
}
