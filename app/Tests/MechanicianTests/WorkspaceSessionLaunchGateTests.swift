import XCTest
@testable import Mechanician

@MainActor
final class WorkspaceSessionLaunchGateTests: XCTestCase {
    func testCallbacksWaitUntilSessionRestoreCompletes() {
        let gate = WorkspaceSessionLaunchGate()
        var didRun = false

        gate.whenOpen {
            didRun = true
        }

        XCTAssertFalse(gate.isOpen)
        XCTAssertFalse(didRun)

        gate.completeRestore()

        XCTAssertTrue(gate.isOpen)
        XCTAssertTrue(didRun)
    }

    func testCompletionDrainsCallbacksOnceInRegistrationOrder() {
        let gate = WorkspaceSessionLaunchGate()
        var events: [Int] = []

        gate.whenOpen { events.append(1) }
        gate.whenOpen { events.append(2) }
        gate.whenOpen { events.append(3) }

        gate.completeRestore()
        gate.completeRestore()

        XCTAssertEqual(events, [1, 2, 3])
    }

    func testCallbacksRegisteredAfterCompletionRunInline() {
        let gate = WorkspaceSessionLaunchGate()
        gate.completeRestore()
        var didRun = false

        gate.whenOpen {
            didRun = true
        }

        XCTAssertTrue(didRun)
    }

    func testWorkspaceCreatingCommandsUseTheRestoreFence() {
        let gate = WorkspaceSessionLaunchGate()
        var events: [String] = []

        performWorkspaceCreatingIngress(after: gate) {
            events.append("Home")
        }
        performWorkspaceCreatingIngress(after: gate) {
            events.append("Workspaces")
        }

        XCTAssertTrue(events.isEmpty)

        gate.completeRestore()

        XCTAssertEqual(events, ["Home", "Workspaces"])
    }
}
