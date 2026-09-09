import XCTest
@testable import Mechanician

/// Opt-in microbenchmarks for the bounded activity ledger. Keep these out of the default test run:
/// absolute timings vary too much across developer and CI hardware to make a useful correctness gate.
/// Run with:
///
///     MECHANICIAN_RUN_PERF_TESTS=1 swift test \
///       --filter AgentVisualizationPerformanceTests
///
final class AgentVisualizationPerformanceTests: XCTestCase {
    func testTraceSpanConstructionAtLedgerLimit() throws {
        try requirePerformanceRun()

        let start = Date(timeIntervalSince1970: 1_000)
        let records = maximumLedgerFixture(start: start)
        let end = start.addingTimeInterval(801)
        let options = XCTMeasureOptions()
        options.iterationCount = 10

        measure(metrics: [XCTClockMetric(), XCTCPUMetric()], options: options) {
            let spans = agentActivityTraceSpans(records, start: start, end: end)
            XCTAssertEqual(spans.count, 800)
        }
    }

    private func requirePerformanceRun() throws {
        guard ProcessInfo.processInfo.environment["MECHANICIAN_RUN_PERF_TESTS"] == "1" else {
            throw XCTSkip("Set MECHANICIAN_RUN_PERF_TESTS=1 to run visualization benchmarks.")
        }
    }

    /// Eight hundred alternating state transitions, each followed by a token sample: 1,600 records,
    /// matching the persistence ceiling used by the production ledger.
    private func maximumLedgerFixture(start: Date) -> [AgentActivityRecord] {
        var records: [AgentActivityRecord] = []
        records.reserveCapacity(1_600)
        for index in 0..<800 {
            let at = start.addingTimeInterval(Double(index))
            records.append(.state(
                index.isMultiple(of: 2) ? .model : .tool,
                turnID: "benchmark",
                detail: index.isMultiple(of: 2) ? "Reasoning" : "Read",
                at: at))
            records.append(.tokens(
                turnID: "benchmark",
                input: 120,
                output: 20,
                at: at.addingTimeInterval(0.1)))
        }
        return records
    }
}
