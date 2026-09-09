import XCTest
@testable import Mechanician

private actor OnDeviceGateProbe {
    struct Snapshot {
        let startOrder: [Int]
        let maximumConcurrent: Int
        let active: Int
    }

    private var active = 0
    private var maximumConcurrent = 0
    private var startOrder: [Int] = []

    func started(_ identifier: Int) {
        active += 1
        maximumConcurrent = max(maximumConcurrent, active)
        startOrder.append(identifier)
    }

    func finished() {
        active -= 1
    }

    func snapshot() -> Snapshot {
        Snapshot(
            startOrder: startOrder,
            maximumConcurrent: maximumConcurrent,
            active: active)
    }
}

private actor OnDeviceGateLatch {
    private var isOpen = false
    private var waiter: CheckedContinuation<Void, Never>?

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { waiter = $0 }
    }

    func open() {
        guard !isOpen else { return }
        isOpen = true
        let continuation = waiter
        waiter = nil
        continuation?.resume()
    }
}

final class OnDeviceModelExecutionGateTests: XCTestCase {
    func testPermitIsFIFOAndNeverRunsOperationsConcurrently() async {
        let gate = OnDeviceModelExecutionGate()
        let probe = OnDeviceGateProbe()
        let firstRelease = OnDeviceGateLatch()
        let firstStarted = expectation(description: "first operation acquired permit")

        let first = Task {
            await gate.withPermit {
                await probe.started(1)
                firstStarted.fulfill()
                await firstRelease.wait()
                await probe.finished()
                return 1
            }
        }
        await fulfillment(of: [firstStarted], timeout: 2)

        let second = Task {
            await gate.withPermit {
                await probe.started(2)
                await Task.yield()
                await probe.finished()
                return 2
            }
        }
        let secondQueued = await waitForQueuedOperations(1, in: gate)
        XCTAssertTrue(secondQueued)

        let third = Task {
            await gate.withPermit {
                await probe.started(3)
                await Task.yield()
                await probe.finished()
                return 3
            }
        }
        let thirdQueued = await waitForQueuedOperations(2, in: gate)
        XCTAssertTrue(thirdQueued)

        let blocked = await probe.snapshot()
        XCTAssertEqual(blocked.startOrder, [1])
        XCTAssertEqual(blocked.maximumConcurrent, 1)
        XCTAssertEqual(blocked.active, 1)

        await firstRelease.open()
        let values = await [first.value, second.value, third.value]
        XCTAssertEqual(values, [1, 2, 3])

        let completed = await probe.snapshot()
        XCTAssertEqual(completed.startOrder, [1, 2, 3])
        XCTAssertEqual(completed.maximumConcurrent, 1)
        XCTAssertEqual(completed.active, 0)
        XCTAssertEqual(gate.queuedOperationCount, 0)
    }

    private func waitForQueuedOperations(
        _ expected: Int,
        in gate: OnDeviceModelExecutionGate
    ) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(2))
        while clock.now < deadline {
            if gate.queuedOperationCount == expected { return true }
            await Task.yield()
        }
        return gate.queuedOperationCount == expected
    }
}
