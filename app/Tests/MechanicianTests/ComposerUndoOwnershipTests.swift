import AppKit
import XCTest
@testable import Mechanician

/// Who owns ⌘Z in a workspace window.
///
/// Live verification caught this: a move registered on the workspace stack could not be undone,
/// because the composer holds first responder almost all the time in this app. Diagnosing it
/// turned up an AppKit fact worth pinning — `NSTextView` does **not** own an undo manager. Measured
/// directly: a text view with `allowsUndo` returns whatever the window delegate vends from
/// `windowWillReturnUndoManager`, and typing registers on that same object.
///
/// So vending the workspace manager from the delegate silently merged typing undo into the library
/// stack. The composer now keeps its own stack and hands the keystroke on only when that stack is
/// empty.
@MainActor
final class ComposerUndoOwnershipTests: XCTestCase {
    /// Stands in for `WorkspaceToolbarController` without booting a bridge, and pins the AppKit
    /// behaviour the design depends on.
    @MainActor private final class VendingDelegate: NSObject, NSWindowDelegate {
        let manager = UndoManager()
        func windowWillReturnUndoManager(_ window: NSWindow) -> UndoManager? { manager }
    }

    private func makeWindow() -> (WorkspaceWindow, VendingDelegate, ComposerTextView) {
        _ = NSApplication.shared
        let window = WorkspaceWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
            styleMask: [.titled], backing: .buffered, defer: false)
        let delegate = VendingDelegate()
        window.delegate = delegate
        let composer = ComposerTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 100))
        composer.allowsUndo = true
        _ = composer.layoutManager
        window.contentView?.addSubview(composer)
        window.makeFirstResponder(composer)
        return (window, delegate, composer)
    }

    /// The AppKit fact. A plain `NSTextView` takes the delegate's manager — which is why the
    /// composer needs its own, and why this is worth a regression test rather than a comment.
    func testAPlainTextViewTakesTheWindowDelegatesUndoManager() {
        _ = NSApplication.shared
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
            styleMask: [.titled], backing: .buffered, defer: false)
        let delegate = VendingDelegate()
        window.delegate = delegate
        let plain = NSTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 100))
        plain.allowsUndo = true
        window.contentView?.addSubview(plain)
        window.makeFirstResponder(plain)

        XCTAssertTrue(
            plain.undoManager === delegate.manager,
            "if this ever stops holding, ComposerTextView's override can be simplified")
    }

    /// Typing must not land on the workspace stack. This is the regression the override exists for.
    func testTypingRegistersOnTheComposersOwnStackNotTheWorkspaces() {
        let (_, delegate, composer) = makeWindow()

        composer.insertText("hello", replacementRange: NSRange(location: 0, length: 0))

        XCTAssertTrue(composer.ownUndoManager.canUndo, "typing belongs to the composer")
        XCTAssertFalse(
            delegate.manager.canUndo,
            "a typed word must never appear on the workspace's library stack")
    }

    /// `undoManager` must stay the composer's own unconditionally, because `NSTextView` registers
    /// typing through it. Handing back the workspace stack here is what sent the first keystroke on
    /// an empty composer to the library's stack.
    func testUndoManagerIsAlwaysTheComposersOwn() {
        let (_, delegate, composer) = makeWindow()

        XCTAssertTrue(composer.undoManager === composer.ownUndoManager)
        XCTAssertFalse(composer.undoManager === delegate.manager)

        composer.insertText("hello", replacementRange: NSRange(location: 0, length: 0))
        XCTAssertTrue(composer.undoManager === composer.ownUndoManager)
    }

    /// While there is typing to reverse, ⌘Z acts on the composer — ordinary Mac text-field
    /// behaviour — and leaves the library stack alone.
    func testUndoActsOnTheComposerWhileItHasTypingToReverse() {
        let (window, delegate, composer) = makeWindow()
        var workspaceUndone = false
        delegate.manager.registerUndo(withTarget: self) { _ in workspaceUndone = true }

        composer.insertText("hello", replacementRange: NSRange(location: 0, length: 0))
        window.undo(nil)

        XCTAssertEqual(composer.string, "", "the typing is what got reversed")
        XCTAssertFalse(workspaceUndone, "the library action must not be touched")
        XCTAssertTrue(delegate.manager.canUndo, "it is still there, waiting")
    }

    /// With nothing typed, ⌘Z reaches the workspace rather than dying in the composer. Without
    /// this, library undo is unreachable in practice, which is what shipped and failed live.
    func testUndoReachesTheWorkspaceWhenTheComposerHasNothingToReverse() {
        let (window, delegate, composer) = makeWindow()
        var workspaceUndone = false
        delegate.manager.registerUndo(withTarget: self) { _ in workspaceUndone = true }

        XCTAssertFalse(composer.ownUndoManager.canUndo)
        window.undo(nil)

        XCTAssertTrue(workspaceUndone, "an untouched composer must not swallow ⌘Z")
    }

    /// The hand-off is not a latch: once the composer's stack drains, ⌘Z reaches the workspace
    /// again rather than being captured for the rest of the session by one early keystroke.
    func testTheHandoffResumesAfterTheComposerStackIsCleared() {
        let (window, delegate, composer) = makeWindow()
        var workspaceUndone = false
        delegate.manager.registerUndo(withTarget: self) { _ in workspaceUndone = true }

        composer.insertText("hello", replacementRange: NSRange(location: 0, length: 0))
        composer.ownUndoManager.removeAllActions()
        window.undo(nil)

        XCTAssertTrue(workspaceUndone)
    }

    /// A composer holding only redo keeps ⇧⌘Z, so undo and redo stay a coherent pair over the text
    /// the user was editing rather than splitting across two stacks.
    func testRedoOfTypingIsNotStolenByTheWorkspace() {
        let (window, delegate, composer) = makeWindow()
        var workspaceRedone = false
        delegate.manager.registerUndo(withTarget: self) { _ in }
        delegate.manager.undo()
        delegate.manager.registerUndo(withTarget: self) { _ in workspaceRedone = true }

        composer.insertText("hello", replacementRange: NSRange(location: 0, length: 0))
        window.undo(nil)
        XCTAssertTrue(composer.ownUndoManager.canRedo)

        window.redo(nil)
        XCTAssertEqual(composer.string, "hello", "the typing came back")
        XCTAssertFalse(workspaceRedone)
    }

    /// The Edit menu says what ⌘Z will actually do, which is the whole point of routing on the
    /// command: with the composer empty, the title comes from the workspace's action name.
    func testTheMenuTitleFollowsWhicheverStackWillAct() {
        let (window, delegate, _) = makeWindow()
        delegate.manager.registerUndo(withTarget: self) { _ in }
        delegate.manager.setActionName("Move Conversation")

        let item = NSMenuItem(
            title: "Undo", action: #selector(WorkspaceWindow.undo(_:)), keyEquivalent: "z")
        XCTAssertTrue(window.validateMenuItem(item))
        XCTAssertEqual(item.title, delegate.manager.undoMenuItemTitle)
        XCTAssertTrue(item.title.contains("Move Conversation"))
    }

    /// `composerUndoManager` is what internal composer edits register through. It must always be
    /// the composer's own, even on an empty stack, or the first attachment edit would land on the
    /// library's.
    func testInternalComposerEditsAlwaysTargetTheComposersOwnStack() {
        let (_, delegate, composer) = makeWindow()

        XCTAssertTrue(composer.composerUndoManager === composer.ownUndoManager)
        XCTAssertFalse(composer.composerUndoManager === delegate.manager)
    }

    /// The fact that actually bit, pinned so it cannot bite again.
    ///
    /// `NSWindow.undoManager` consults the FIRST RESPONDER before the delegate. In the running app,
    /// with the composer focused and a move already registered, it resolved to the composer's stack
    /// rather than the workspace's:
    ///
    ///     windowUndoMgr=0x…f3a0  ctrlMgr=0x…6c30  same=false
    ///     ctrlCanUndo=false      firstResponder=ComposerTextView
    ///
    /// The menu validated the empty composer stack and disabled itself while the move sat unseen on
    /// the delegate's. That divergence needs a key window in a live responder chain and does not
    /// reproduce offscreen, so it is recorded here rather than asserted. What IS asserted is the
    /// property that makes `WorkspaceWindow` immune to it: routing never reads `window.undoManager`.
    func testRoutingNeverDependsOnWindowUndoManager() {
        let (window, delegate, composer) = makeWindow()
        var workspaceUndone = false
        delegate.manager.registerUndo(withTarget: self) { _ in workspaceUndone = true }

        // Routing must not consult `window.undoManager` at all, whatever it happens to resolve to.
        // Asserting its value here would be asserting the wrong thing: offscreen, with no key
        // window, it resolves to the delegate's manager, and the failure only appears in a real
        // window. So this asserts the property that makes the design immune either way.
        window.undo(nil)
        XCTAssertTrue(
            workspaceUndone,
            "the library stack must be reachable regardless of what window.undoManager returns")
        XCTAssertFalse(composer.ownUndoManager.canUndo, "and the composer was left alone")
    }
}
