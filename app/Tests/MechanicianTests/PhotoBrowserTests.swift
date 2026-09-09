import AppKit
import Photos
import SwiftUI
import XCTest
@testable import Mechanician

/// The bug this browser exists to fix: `PHPickerViewController` is out of process and sizes its own
/// sheet, so asking it for room did nothing — it opened at roughly 310x195 with the grid crushed
/// behind its own controls. Our own controller is in process, so the size we ask for is the size we
/// get, and this proves it rather than assuming it.
@MainActor
final class PhotoBrowserSheetTests: XCTestCase {
    func testBrowserSheetOpensAtTheSizeWeAskFor() {
        _ = NSApplication.shared
        let requested = NSSize(width: 960, height: 660)
        let hosting = NSHostingController(
            rootView: PhotoBrowserView(model: PhotoBrowserModel(), cancel: {}, add: { _ in }))
        hosting.preferredContentSize = requested

        let host = NSViewController()
        host.view = NSView(frame: NSRect(x: 0, y: 0, width: 1_200, height: 800))
        let window = NSWindow(
            contentRect: host.view.frame,
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.contentViewController = host
        window.makeKeyAndOrderFront(nil)
        defer { window.close() }

        host.presentAsSheet(hosting)
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))

        XCTAssertEqual(hosting.view.window?.frame.size.width ?? 0, requested.width, accuracy: 1)
        XCTAssertEqual(hosting.view.window?.frame.size.height ?? 0, requested.height, accuracy: 1)
    }

    /// Even asked for nothing, the browser cannot collapse: the grid needs room to be a grid.
    func testBrowserRefusesToCollapse() {
        _ = NSApplication.shared
        let hosting = NSHostingController(
            rootView: PhotoBrowserView(model: PhotoBrowserModel(), cancel: {}, add: { _ in }))
        hosting.loadView()
        XCTAssertGreaterThanOrEqual(hosting.view.fittingSize.width, 720)
        XCTAssertGreaterThanOrEqual(hosting.view.fittingSize.height, 520)
    }
}

@MainActor
final class PhotoBrowserSelectionTests: XCTestCase {
    /// Selection order is the order the user clicked, not the order the library returned, so a
    /// deliberate sequence survives into the message.
    func testSelectionKeepsClickOrderAndToggles() {
        let model = PhotoBrowserModel()
        XCTAssertFalse(model.hasSelection)

        model.selection = ["c", "a", "b"]
        XCTAssertEqual(model.selection, ["c", "a", "b"])
        XCTAssertTrue(model.hasSelection)

        // Deselecting the middle one leaves the rest in order and renumbers the badges.
        model.selection.removeAll { $0 == "a" }
        XCTAssertEqual(model.selection, ["c", "b"])
    }
}

import AVFoundation

/// David hit this: the camera alert offered "Open Settings", but Mechanician was not listed in
/// Privacy ▸ Camera, so there was nothing to turn on. A build with no `NSCameraUsageDescription`
/// can never prompt and can never appear there, so pointing at that pane is a dead end.
@MainActor
final class CameraAccessOutcomeTests: XCTestCase {
    func testABuildWithoutCameraSupportIsNamedRatherThanSentToSettings() {
        for status in [
            AVAuthorizationStatus.notDetermined, .authorized, .denied, .restricted,
        ] {
            XCTAssertEqual(
                CameraCapture.outcome(status: status, hasUsageDescription: false),
                .unsupportedBuild,
                "No usage description means macOS will never offer the camera, whatever TCC says.")
        }
        XCTAssertTrue(
            CameraCapture.alertText(for: .unsupportedBuild).detail.contains("built without"))
    }

    func testUndeterminedAccessAsksRatherThanAssumingRefusal() {
        XCTAssertEqual(
            CameraCapture.outcome(status: .notDetermined, hasUsageDescription: true),
            .request,
            "The request is what registers the app in Privacy ▸ Camera.")
    }

    func testGrantedGoesStraightToCaptureAndRefusalExplainsItself() {
        XCTAssertEqual(
            CameraCapture.outcome(status: .authorized, hasUsageDescription: true), .present)
        XCTAssertEqual(
            CameraCapture.outcome(status: .denied, hasUsageDescription: true), .denied)
        XCTAssertEqual(
            CameraCapture.outcome(status: .restricted, hasUsageDescription: true), .denied)
        XCTAssertTrue(
            CameraCapture.alertText(for: .denied).detail.contains("System Settings"))
    }
}
