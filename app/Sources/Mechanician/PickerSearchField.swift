import SwiftUI
import AppKit

/// The model picker's search field, AppKit-backed so macOS text-intelligence services can be
/// switched off. SwiftUI's TextField offers no macOS control over inline predictions or the
/// text-completion list, and that completion list is an out-of-process ViewBridge NSRemoteView —
/// the party that asserts in the macOS 26/27 beta window-ordering regression (Apple bug
/// FB23642313). A search box over model names wants none of those services anyway.
struct PickerSearchField: NSViewRepresentable {
    @Binding var text: String
    let placeholder: String
    /// Increment to move first responder to the field (replaces @FocusState for this control).
    var focusRequest: Int
    var accessibilityHelp = String(localized:
        "Use the up and down arrow keys to move through matching models.")
    var onSubmit: () -> Void = {}
    var onMoveUp: () -> Void = {}
    var onMoveDown: () -> Void = {}
    var onCancel: () -> Void = {}
    var onWindowChange: @MainActor (NSWindow?) -> Void = { _ in }

    func makeNSView(context: Context) -> NSTextField {
        let field = TraitField()
        field.delegate = context.coordinator
        field.placeholderString = placeholder
        field.font = .systemFont(ofSize: 13)
        field.isBordered = false
        field.isBezeled = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.lineBreakMode = .byTruncatingTail
        field.maximumNumberOfLines = 1
        if let cell = field.cell as? NSTextFieldCell {
            cell.usesSingleLineMode = true
            cell.wraps = false
            cell.isScrollable = true
        }
        field.setAccessibilityLabel(placeholder)
        field.setAccessibilityHelp(accessibilityHelp)
        let coordinator = context.coordinator
        field.windowChangeHandler = { [weak coordinator] window in
            coordinator?.reportWindow(window)
        }
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self
        field.placeholderString = placeholder
        field.setAccessibilityLabel(placeholder)
        field.setAccessibilityHelp(accessibilityHelp)
        if field.stringValue != text { field.stringValue = text }
        if focusRequest != coordinator.handledFocusRequest {
            coordinator.handledFocusRequest = focusRequest
            field.window?.makeFirstResponder(field)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    /// Disables the remote text services on the popover window's shared field editor before any
    /// editing session can summon them. The editor instance is per-window, so configuring it once
    /// on attach covers every editing session in this (per-presentation) popover window.
    private final class TraitField: NSTextField {
        var windowChangeHandler: (@MainActor (NSWindow?) -> Void)?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window else { return }
            // NSViewRepresentable is still inside its update transaction here. Publishing SwiftUI
            // state synchronously is undefined; report on the next AppKit pass and ensure this
            // exact field is still attached so a stale detach cannot clear a newer presentation.
            DispatchQueue.main.async { [weak self, weak window] in
                guard let self, let window, self.window === window else { return }
                self.windowChangeHandler?(window)
            }
            guard let editor = window.fieldEditor(true, for: nil) as? NSTextView else { return }
            Coordinator.disableTextServices(editor)
        }
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: PickerSearchField
        var handledFocusRequest = 0
        weak var observedWindow: NSWindow?

        init(_ parent: PickerSearchField) { self.parent = parent }

        @MainActor
        func reportWindow(_ window: NSWindow?) {
            guard observedWindow !== window else { return }
            observedWindow = window
            parent.onWindowChange(window)
        }

        @MainActor
        static func disableTextServices(_ editor: NSTextView) {
            RemoteTextServiceSafety.disableRemoteCompletion(on: editor)
            editor.isAutomaticSpellingCorrectionEnabled = false
            editor.isAutomaticTextReplacementEnabled = false
            editor.isContinuousSpellCheckingEnabled = false
            editor.isGrammarCheckingEnabled = false
        }

        func controlTextDidBeginEditing(_ obj: Notification) {
            if let editor = (obj.object as? NSTextField)?.currentEditor() as? NSTextView {
                Self.disableTextServices(editor)
            }
        }

        func controlTextDidChange(_ obj: Notification) {
            guard let field = obj.object as? NSTextField else { return }
            parent.text = field.stringValue
        }

        func control(_ control: NSControl, textView: NSTextView,
                     doCommandBy commandSelector: Selector) -> Bool {
            switch commandSelector {
            case #selector(NSResponder.moveDown(_:)):
                parent.onMoveDown()
                return true
            case #selector(NSResponder.moveUp(_:)):
                parent.onMoveUp()
                return true
            case #selector(NSResponder.insertNewline(_:)):
                parent.onSubmit()
                return true
            case #selector(NSResponder.cancelOperation(_:)):
                parent.onCancel()
                return true
            default:
                return false
            }
        }
    }
}
