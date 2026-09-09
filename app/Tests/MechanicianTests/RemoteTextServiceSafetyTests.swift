import AppKit
import XCTest
@testable import Mechanician

@MainActor
final class RemoteTextServiceSafetyTests: XCTestCase {
    func testRemoteCompletionTraitsAreDisabled() {
        let editor = NSTextView()
        editor.isAutomaticTextCompletionEnabled = true
        editor.inlinePredictionType = .yes
        editor.writingToolsBehavior = .default

        RemoteTextServiceSafety.disableRemoteCompletion(on: editor)

        XCTAssertFalse(editor.isAutomaticTextCompletionEnabled)
        XCTAssertEqual(editor.inlinePredictionType, .no)
        XCTAssertEqual(editor.writingToolsBehavior, .none)
    }

    func testRetiringTheActiveEditorEndsItBeforeAnotherWindowCanOrder() {
        _ = NSApplication.shared
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 200),
            styleMask: [.titled],
            backing: .buffered,
            defer: false)
        let editor = NSTextView(frame: window.contentView?.bounds ?? .zero)
        window.contentView?.addSubview(editor)
        XCTAssertTrue(window.makeFirstResponder(editor))

        XCTAssertTrue(RemoteTextServiceSafety.retireActiveEditor(in: window, force: true))

        XCTAssertFalse(window.firstResponder === editor)
        XCTAssertFalse(editor.isAutomaticTextCompletionEnabled)
        XCTAssertEqual(editor.inlinePredictionType, .no)
        XCTAssertEqual(editor.writingToolsBehavior, .none)
    }

    func testRetirementConfiguresSharedFieldEditorAfterFocusMovesAway() {
        _ = NSApplication.shared
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 200),
            styleMask: [.titled],
            backing: .buffered,
            defer: false)
        let field = NSTextField(frame: NSRect(x: 20, y: 20, width: 200, height: 24))
        window.contentView?.addSubview(field)
        XCTAssertTrue(window.makeFirstResponder(field))
        guard let editor = window.fieldEditor(false, for: field) as? NSTextView else {
            return XCTFail("Expected the window's shared field editor")
        }
        editor.isAutomaticTextCompletionEnabled = true
        editor.inlinePredictionType = .yes
        editor.writingToolsBehavior = .default
        XCTAssertTrue(window.makeFirstResponder(window.contentView))
        XCTAssertFalse(window.firstResponder === editor)

        XCTAssertTrue(RemoteTextServiceSafety.retireActiveEditor(in: window, force: true))

        XCTAssertFalse(editor.isAutomaticTextCompletionEnabled)
        XCTAssertEqual(editor.inlinePredictionType, .no)
        XCTAssertEqual(editor.writingToolsBehavior, .none)
    }

    func testPresentationDelayIsConfinedToTheAffectedOSGeneration() {
        XCTAssertEqual(
            RemoteTextServiceSafety.presentationDelayNanoseconds(forMajorVersion: 27),
            RemoteTextServiceSafety.retirementDelayNanoseconds)
        XCTAssertEqual(
            RemoteTextServiceSafety.presentationDelayNanoseconds(forMajorVersion: 26),
            0)
        XCTAssertEqual(
            RemoteTextServiceSafety.presentationDelayNanoseconds(forMajorVersion: 28),
            0)
    }

    func testWindowOrderSensitiveMutationRunsAfterAMainQueueBoundary() async {
        var didRun = false
        let completed = expectation(description: "deferred mutation")

        _ = RemoteTextServiceSafety.deferWindowOrderSensitiveMutation(
            from: nil,
            majorVersion: 26
        ) {
            didRun = true
            completed.fulfill()
        }

        XCTAssertFalse(didRun)
        await fulfillment(of: [completed], timeout: 1)
        XCTAssertTrue(didRun)
    }

    func testWindowOrderSensitivePresentationRetiresAnActiveEditorBeforeScheduling() async {
        _ = NSApplication.shared
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 200),
            styleMask: [.titled],
            backing: .buffered,
            defer: false)
        let editor = NSTextView(frame: window.contentView?.bounds ?? .zero)
        window.contentView?.addSubview(editor)
        XCTAssertTrue(window.makeFirstResponder(editor))

        let completed = expectation(description: "deferred presentation")
        _ = RemoteTextServiceSafety.deferWindowOrderSensitiveMutation(
            from: window,
            majorVersion: 27
        ) {
            completed.fulfill()
        }

        // Retirement is synchronous; presentation remains deferred to a later AppKit pass.
        XCTAssertFalse(window.firstResponder === editor)
        await fulfillment(of: [completed], timeout: 1)
    }

    func testCancelledWindowOrderSensitiveMutationDoesNotRun() async {
        var didRun = false
        let task = RemoteTextServiceSafety.deferWindowOrderSensitiveMutation(
            from: nil,
            majorVersion: 27
        ) {
            didRun = true
        }

        task.cancel()
        try? await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertFalse(didRun)
    }

    func testDismissalFenceRunsOnlyAfterExactWindowOrdersOff() async {
        _ = NSApplication.shared
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 200),
            styleMask: [.titled],
            backing: .buffered,
            defer: false)
        window.orderFront(nil)
        XCTAssertTrue(window.isVisible)
        var observedVisible: Bool?
        let completed = expectation(description: "native window ordered off")

        _ = RemoteTextServiceSafety.deferUntilWindowIsNoLongerVisible(
            from: window,
            majorVersion: 26
        ) { didOrderOff in
            observedVisible = window.isVisible
            XCTAssertTrue(didOrderOff)
            completed.fulfill()
        }
        await Task.yield()
        XCTAssertNil(observedVisible)
        window.orderOut(nil)

        await fulfillment(of: [completed], timeout: 1)
        XCTAssertEqual(observedVisible, false)
    }

    func testDismissalFenceFailsClosedWithoutExactWindow() async {
        let completed = expectation(description: "missing window refused")
        _ = RemoteTextServiceSafety.deferUntilWindowIsNoLongerVisible(
            from: nil,
            majorVersion: 26
        ) { didOrderOff in
            XCTAssertFalse(didOrderOff)
            completed.fulfill()
        }
        await fulfillment(of: [completed], timeout: 1)
    }
}
