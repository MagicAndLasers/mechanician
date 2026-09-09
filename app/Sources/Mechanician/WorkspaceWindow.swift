import AppKit

/// A workspace window, which owns ⌘Z routing.
///
/// This exists because of a measured AppKit behaviour, not a preference. `NSWindow` implements
/// `undo:` and `redo:` (`NSTextView` does not), and its implementation acts on `window.undoManager`
/// — a property that consults the **first responder** before the window delegate. The composer
/// supplies its own stack so typing cannot pollute the library's, which means `window.undoManager`
/// resolves to the composer's stack whenever the composer has focus, and in this app it nearly
/// always does. The library stack was therefore unreachable through AppKit's own `undo:`.
///
/// Measured live at the moment the Edit menu opened, with a move already registered:
///
///     windowUndoMgr=0x…f3a0   ctrlMgr=0x…6c30   same=false
///     ctrlCanUndo=false       firstResponder=ComposerTextView
///
/// Two different objects. The menu validated the composer's empty stack and disabled itself while
/// the move sat on the delegate's stack, unseen.
///
/// So the routing decision lives here instead of on `undoManager`. The window is the one responder
/// guaranteed to be in the chain and to receive `undo:`, and it can read both stacks rather than
/// being handed one of them.
final class WorkspaceWindow: NSWindow {
    /// The composer, when it is what the user is editing.
    private var focusedComposer: ComposerTextView? { firstResponder as? ComposerTextView }

    /// This workspace's library stack, from the delegate that vends it.
    private var libraryUndoManager: UndoManager? {
        delegate?.windowWillReturnUndoManager?(self)
    }

    /// Whichever stack ⌘Z should act on: the composer while it has typing to reverse, exactly as any
    /// Mac text field, otherwise the workspace's library stack.

    private var undoTarget: UndoManager? {
        if let own = focusedComposer?.ownUndoManager, own.canUndo { return own }
        guard !WorkspaceAdoption.isPlacementOperationInProgress else { return nil }
        return libraryUndoManager
    }

    /// The redo counterpart. A composer holding redo keeps ⇧⌘Z, so undo and redo stay a coherent
    /// pair over the text being edited rather than splitting across two stacks.
    private var redoTarget: UndoManager? {
        if let own = focusedComposer?.ownUndoManager, own.canRedo { return own }
        guard !WorkspaceAdoption.isPlacementOperationInProgress else { return nil }
        return libraryUndoManager
    }

    /// The property AppKit's own undo machinery reads.
    ///
    /// This is the crux. AppKit validates the standard Undo item through neither `validateMenuItem`
    /// nor `validateUserInterfaceItem` — measured: it resolves `undo:` to this window and then calls
    /// neither hook — so the only lever on enablement is `undoManager` itself. Left inherited, it
    /// resolves to the first responder's, which is the composer's own stack, and the Edit item
    /// disabled itself against an empty stack while the move sat on the library's.
    ///
    /// Routing it here fixes enablement, the menu title, and ⌘Z in one place, and costs nothing on
    /// the typing side: `NSTextView` registers through *its own* `undoManager`, which
    /// `ComposerTextView` keeps pointed at `ownUndoManager`.
    override var undoManager: UndoManager? { undoTarget }

    /// `NSWindow`'s `undo:` is not exposed to Swift, so this is declared rather than overridden; at
    /// runtime it replaces AppKit's implementation for this class.


    @objc func undo(_ sender: Any?) {
        undoTarget?.undo()
    }

    @objc func redo(_ sender: Any?) {
        redoTarget?.redo()
    }


    /// The titles Edit ▸ Undo/Redo should carry, from the same stacks the keystroke will act on.
    ///
    /// `validateMenuItem` below cannot supply these: the shipped Edit items are SwiftUI buttons, so
    /// they never dispatch `undo:` and this override never runs for them. They are deliberately
    /// SwiftUI buttons — see the comment at `CommandGroup(replacing: .undoRedo)` — so the titles are
    /// pushed from `EditMenuActionNames` instead. Both paths read these properties, so they agree.
    var undoMenuTitle: String {
        guard let target = undoTarget, target.canUndo else { return String(localized: "Undo") }
        return target.undoMenuItemTitle
    }

    var redoMenuTitle: String {
        guard let target = redoTarget, target.canRedo else { return String(localized: "Redo") }
        return target.redoMenuItemTitle
    }

    /// Enablement and the menu title follow whichever stack will actually act, so Edit reads
    /// "Undo Move Conversation" when that is what the keystroke does.
    override func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(undo(_:)):
            menuItem.title = undoTarget?.undoMenuItemTitle ?? String(localized: "Undo")
            return undoTarget?.canUndo ?? false
        case #selector(redo(_:)):
            menuItem.title = redoTarget?.redoMenuItemTitle ?? String(localized: "Redo")
            return redoTarget?.canRedo ?? false
        default:
            return super.validateMenuItem(menuItem)
        }
    }
}
