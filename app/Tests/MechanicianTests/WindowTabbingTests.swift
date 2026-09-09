import AppKit
import XCTest
@testable import Mechanician

private final class MenuTrackingSpy: NSMenu {
    private(set) var cancellationCount = 0

    override func cancelTrackingWithoutAnimation() {
        cancellationCount += 1
    }
}

@MainActor
final class WindowTabbingTests: XCTestCase {
    func testLaunchDisablesAutomaticWindowTabbing() {
        _ = NSApplication.shared
        let original = NSWindow.allowsAutomaticWindowTabbing
        defer { NSWindow.allowsAutomaticWindowTabbing = original }

        NSWindow.allowsAutomaticWindowTabbing = true
        AppDelegate().applicationWillFinishLaunching(
            Notification(name: NSApplication.willFinishLaunchingNotification))
        XCTAssertFalse(NSWindow.allowsAutomaticWindowTabbing)
    }

    func testResigningActiveEndsMenuTracking() {
        let application = NSApplication.shared
        let originalMainMenu = application.mainMenu
        let menu = MenuTrackingSpy(title: "")
        application.mainMenu = menu
        defer { application.mainMenu = originalMainMenu }

        AppDelegate().applicationWillResignActive(
            Notification(name: NSApplication.willResignActiveNotification))

        XCTAssertEqual(menu.cancellationCount, 1)
    }
}
