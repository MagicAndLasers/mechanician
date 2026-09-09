import AppKit
import XCTest
@testable import Mechanician

/// Focus is a responder-chain concern, so these drive a real `NSWindow` rather than asserting that
/// a counter advanced — which is exactly what the old token could do while nothing was focused.
@MainActor
final class ComposerFocusControllerTests: XCTestCase {

    /// Pumps the main run loop until `condition` holds, or the timeout elapses.
    ///
    /// Replaces a fixed 50 ms wait. Focus lands through an async hop, so 50 ms is plenty on an idle
    /// machine and not necessarily on a loaded CI runner: `testDetachOnlyReleasesTheEditorItWasGiven`
    /// failed exactly that way on the macOS 26 runner while passing 12 of 12 here. Waiting on the
    /// condition rather than the clock is also faster in the common case, because it returns as soon
    /// as focus has landed. It does not assert — the test's own assertion still decides.
    private func settle(until condition: () -> Bool, timeout: TimeInterval = 2) {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
    }

    private func makeWindow() -> (NSWindow, ComposerTextView) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 120),
            styleMask: [.titled], backing: .buffered, defer: false)
        let textView = ComposerTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 40))
        textView.isEditable = true
        textView.isSelectable = true
        window.contentView?.addSubview(textView)
        return (window, textView)
    }

    func testAttachingMakesTheComposerTheWindowsPreferredResponder() {
        let (window, textView) = makeWindow()
        let controller = ComposerFocusController()

        XCTAssertNil(window.initialFirstResponder)
        controller.attach(textView)

        // This is what focuses a freshly launched window without a timed request, and what stops
        // the sidebar's search field winning the race at startup.
        XCTAssertIdentical(window.initialFirstResponder, textView)
    }

    func testTakeFocusMakesTheComposerFirstResponder() {
        let (window, textView) = makeWindow()
        let controller = ComposerFocusController()
        controller.attach(textView)

        XCTAssertFalse(controller.isFocused)
        controller.takeFocus()
        settle { controller.isFocused }

        XCTAssertTrue(controller.isFocused)
        XCTAssertTrue(window.firstResponder === textView
            || (window.firstResponder as? NSView)?.isDescendant(of: textView) == true)
    }

    /// A focused `NSTextView` is represented in the responder chain by its field editor, so an
    /// identity check against the text view alone reports "not focused" while it plainly is.
    func testFocusIsDetectedThroughTheFieldEditor() {
        let (window, textView) = makeWindow()
        let controller = ComposerFocusController()
        controller.attach(textView)
        window.makeFirstResponder(textView)

        XCTAssertTrue(controller.isFocused)
    }

    func testTakeFocusIsIdempotentAndSafeToRepeat() {
        let (_, textView) = makeWindow()
        let controller = ComposerFocusController()
        controller.attach(textView)

        for _ in 0..<5 { controller.takeFocus() }
        settle { controller.isFocused }

        XCTAssertTrue(controller.isFocused)
    }

    func testFocusRequestsWithoutAWindowAreIgnoredRatherThanCrashing() {
        let controller = ComposerFocusController()
        let orphan = ComposerTextView(frame: NSRect(x: 0, y: 0, width: 100, height: 20))

        controller.attach(orphan)
        controller.takeFocus()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))

        XCTAssertFalse(controller.isFocused)
    }

    /// Scoped to its own window: a background window adopting a conversation must move its own
    /// responder without pulling focus away from the window in front.
    func testFocusIsScopedToTheControllersOwnWindow() {
        let (foreground, foregroundText) = makeWindow()
        let (_, backgroundText) = makeWindow()
        let foregroundFocus = ComposerFocusController()
        let backgroundFocus = ComposerFocusController()
        foregroundFocus.attach(foregroundText)
        backgroundFocus.attach(backgroundText)

        foreground.makeFirstResponder(foregroundText)
        XCTAssertTrue(foregroundFocus.isFocused)

        backgroundFocus.takeFocus()
        settle { foregroundFocus.isFocused && backgroundFocus.isFocused }

        XCTAssertTrue(
            foregroundFocus.isFocused,
            "The front window's editor must keep focus when another window adopts a conversation.")
        XCTAssertTrue(backgroundFocus.isFocused)
    }

    func testDetachOnlyReleasesTheEditorItWasGiven() {
        let (_, textView) = makeWindow()
        let (_, other) = makeWindow()
        let controller = ComposerFocusController()
        controller.attach(textView)

        controller.detach(other)
        controller.takeFocus()
        settle { controller.isFocused }
        XCTAssertTrue(controller.isFocused, "Detaching a different editor must be a no-op.")

        controller.detach(textView)
        XCTAssertFalse(controller.isFocused)
    }

    // MARK: bridge wiring

    /// The bug this stage exists to remove: `select` changed conversations without ever asking for
    /// focus, so the sidebar kept first responder. Focus now hangs off `currentID` itself, which is
    /// the one place every navigation route passes through.
    func testChangingConversationFocusesTheComposer() {
        let support = FileManager.default.temporaryDirectory
            .appendingPathComponent("Mechanician-focus-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: support) }

        let bridge = AgentBridge(settingsBaseOverride: support, environmentOverride: [:])
        let (window, textView) = makeWindow()
        bridge.composerFocusOwner.attach(textView)
        window.makeFirstResponder(window.contentView)
        XCTAssertFalse(bridge.isComposerFocused)

        bridge.currentID = UUID()
        settle { bridge.isComposerFocused }

        XCTAssertTrue(bridge.isComposerFocused)
    }

    /// Taking the suggested follow-up loads it into the composer, and the click that loaded it moved
    /// first responder to the suggestion button. Before this, the prompt appeared in a composer the
    /// user had to click again before they could type.
    func testAcceptingTheSuggestedPromptReturnsFocusToTheComposer() {
        let support = FileManager.default.temporaryDirectory
            .appendingPathComponent("Mechanician-focus-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: support) }

        let store = ConversationStore(
            appSupportBaseOverride: support,
            watchesDirectory: false)
        let user = TranscriptEntry(kind: .user, text: "Explain the failing test")
        let assistant = TranscriptEntry(kind: .assistant, text: "The failure is isolated.")
        let record = ConversationSuggestedPrompt(
            text: "Explain the remaining edge case.",
            source: .onDevice,
            rootPromptEntryID: user.id,
            assistantEntryID: assistant.id)
        let conversation = Conversation(
            title: "Focus",
            cwd: "",
            sdkSessionId: nil,
            messages: [user, assistant],
            updatedAt: Date(),
            suggestedPrompt: record)
        store.upsert(conversation)
        let bridge = AgentBridge(
            settingsBaseOverride: support,
            environmentOverride: [:],
            conversationStoreOverride: store)
        defer {
            bridge.currentID = nil
            bridge.shutdown()
            store.flushSaves()
        }
        let (window, textView) = makeWindow()
        bridge.composerFocusOwner.attach(textView)
        bridge.currentID = conversation.id
        bridge.entries = conversation.messages
        bridge.suggestedPrompt = record.text
        // The click that loads the suggestion is what takes the editor's first responder away.
        window.makeFirstResponder(window.contentView)
        XCTAssertFalse(bridge.isComposerFocused)

        XCTAssertTrue(bridge.acceptSuggestedPrompt(record, draft: "Continue"))
        settle(until: { bridge.isComposerFocused })

        XCTAssertNil(bridge.suggestedPrompt, "An accepted suggestion must not stay on offer.")
        XCTAssertTrue(bridge.isComposerFocused)
    }

    func testReassigningTheSameConversationDoesNotDisturbFocus() {
        let support = FileManager.default.temporaryDirectory
            .appendingPathComponent("Mechanician-focus-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: support) }

        let bridge = AgentBridge(settingsBaseOverride: support, environmentOverride: [:])
        let (window, textView) = makeWindow()
        bridge.composerFocusOwner.attach(textView)
        let id = UUID()
        bridge.currentID = id
        settle(until: { bridge.isComposerFocused })

        // The user deliberately moves somewhere else in the same conversation.
        window.makeFirstResponder(window.contentView)
        bridge.currentID = id
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))

        XCTAssertFalse(
            bridge.isComposerFocused,
            "Re-setting the same conversation is not navigation and must not steal focus back.")
    }
}
