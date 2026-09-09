import Darwin.Mach
import XCTest
@testable import Mechanician

/// Opt-in, process-isolated probe used by the P1b checkpoint gate. Ordinary test runs skip it.
/// Run eager and bounded modes in separate `swift test` processes against separate copied corpora;
/// the printed JSON is then comparable without one allocator run contaminating the other.
@MainActor
final class ConversationResidencyFootprintProbeTests: XCTestCase {
    private func physicalFootprint() throws -> UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(
                    mach_task_self_,
                    task_flavor_t(TASK_VM_INFO),
                    $0,
                    &count)
            }
        }
        guard result == KERN_SUCCESS else {
            throw NSError(
                domain: NSMachErrorDomain,
                code: Int(result),
                userInfo: [NSLocalizedDescriptionKey: "task_info failed: \(result)"])
        }
        return info.phys_footprint
    }

    private func ready(_ store: ConversationStore) async {
        await withCheckedContinuation { continuation in
            store.whenReady { continuation.resume() }
        }
    }

    func testCopiedCorpusFootprintAndHydration() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let rawBase = environment["MECHANICIAN_RESIDENCY_PROBE_BASE"],
              let rawMode = environment["MECHANICIAN_RESIDENCY_PROBE_MODE"],
              let mode = ConversationResidencyMode(rawValue: rawMode) else {
            throw XCTSkip("Set MECHANICIAN_RESIDENCY_PROBE_BASE and _MODE to run the probe.")
        }
        let base = URL(fileURLWithPath: rawBase, isDirectory: true)
        let before = try physicalFootprint()
        let started = ContinuousClock.now
        let store = ConversationStore(
            appSupportBaseOverride: base,
            watchesDirectory: false,
            loadsAsynchronously: true,
            residencyMode: mode)
        await ready(store)
        let readyDuration = ContinuousClock.now - started
        if mode == .boundedAfterRecovery {
            for _ in 0..<120_000 {
                if store.activeResidencyMode == .boundedAfterRecovery { break }
                try await Task.sleep(nanoseconds: 1_000_000)
            }
            XCTAssertEqual(store.activeResidencyMode, .boundedAfterRecovery)
        } else {
            // Queue behind the eager store's fire-and-forget launch reconciliation so both mode
            // measurements describe the same steady projection state.
            await withCheckedContinuation { continuation in
                store.projections.summaries { _ in continuation.resume() }
            }
        }
        let activationDuration = ContinuousClock.now - started
        store.trimResidencyIfNeeded()
        // Let reconciliation inputs and the evicted COW graph leave their queues/autorelease pools.
        try await Task.sleep(nanoseconds: 5_000_000_000)
        let afterReady = try physicalFootprint()

        let target = store.summaries.max { $0.messageCount < $1.messageCount }
        var completedInline = false
        let hydrationStarted = ContinuousClock.now
        if let target {
            await withCheckedContinuation { continuation in
                store.acquireConversation(target.id) { _ in
                    completedInline = true
                    continuation.resume()
                }
                if store.activeResidencyMode == .boundedAfterRecovery,
                   !store.residentConversationIDs.contains(target.id) {
                    XCTAssertFalse(completedInline)
                }
            }
        }
        let hydrationDuration = ContinuousClock.now - hydrationStarted
        let afterHydration = try physicalFootprint()

        let milliseconds: (Duration) -> Double = { duration in
            let components = duration.components
            return Double(components.seconds) * 1_000
                + Double(components.attoseconds) / 1_000_000_000_000_000
        }
        let result: [String: Any] = [
            "mode": mode.rawValue,
            "conversationCount": store.summaries.count,
            "residentCount": store.residentConversationIDs.count,
            "inventorySourceBytes": store.inventorySourceBytes,
            "residentSourceBytes": store.residentSourceBytes,
            "footprintBefore": before,
            "footprintAfterReady": afterReady,
            "footprintDelta": afterReady > before ? afterReady - before : 0,
            "footprintAfterHydration": afterHydration,
            "readyMilliseconds": milliseconds(readyDuration),
            "activationMilliseconds": milliseconds(activationDuration),
            "hydrationMilliseconds": milliseconds(hydrationDuration),
            "synchronousHydrationCount": store.synchronousHydrationCount,
            "evictionCount": store.evictionCount,
        ]
        let data = try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys])
        print("RESIDENCY_PROBE " + String(decoding: data, as: UTF8.self))
    }
}
