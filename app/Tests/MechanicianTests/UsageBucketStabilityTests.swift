import XCTest
@testable import Mechanician

/// While a turn runs, the trace's end keeps advancing. Dividing that growing span into a fixed
/// number of buckets moved every boundary on every frame, so a token event changed buckets as time
/// passed and the bars slid left — the graph appeared to run backwards while the turn ran forwards.
final class UsageBucketStabilityTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_700_000_000)

    private func tokenRecord(at offset: TimeInterval, processed: Int) -> AgentActivityRecord {
        AgentActivityRecord(
            at: start.addingTimeInterval(offset),
            agentID: AgentActivityIdentity.root,
            kind: .tokens,
            inputTokens: processed)
    }

    private func bucketIndex(of offset: TimeInterval, spanSeconds: TimeInterval) -> Int? {
        let buckets = agentActivityUsageBuckets(
            [tokenRecord(at: offset, processed: 100)],
            start: start,
            end: start.addingTimeInterval(spanSeconds),
            count: 52)
        return buckets.firstIndex { $0.tokens.processed > 0 }
    }

    func testARecordKeepsItsBucketAsTheTurnExtends() throws {
        // One event 30s in, watched while the turn grows from 60s to 100s. The width holds across
        // that range — it next doubles at 52 × 2s = 104s — so the event must not move at all.
        let width = agentActivityUsageBucketWidth(forDuration: 60, maximum: 52)
        XCTAssertEqual(agentActivityUsageBucketWidth(forDuration: 100, maximum: 52), width)

        let first = try XCTUnwrap(bucketIndex(of: 30, spanSeconds: 60))
        for span in stride(from: 61.0, through: 100.0, by: 1.0) {
            XCTAssertEqual(
                bucketIndex(of: 30, spanSeconds: span),
                first,
                "the event moved buckets at span \(span)s — this is the sliding graph")
        }
    }

    /// Crossing a width boundary is the one time a record may change bucket, and even then the move
    /// is a merge: two adjacent buckets become one, so its index halves rather than drifting.
    func testCrossingAWidthBoundaryMergesBucketsRatherThanReshufflingThem() throws {
        let narrow = agentActivityUsageBucketWidth(forDuration: 100, maximum: 52)
        let wide = agentActivityUsageBucketWidth(forDuration: 110, maximum: 52)
        XCTAssertEqual(wide, narrow * 2, "the width should double, not drift")

        for offset in stride(from: 1.0, through: 99.0, by: 3.0) {
            let before = try XCTUnwrap(bucketIndex(of: offset, spanSeconds: 100))
            let after = try XCTUnwrap(bucketIndex(of: offset, spanSeconds: 110))
            XCTAssertEqual(after, before / 2, "event at \(offset)s did not merge cleanly")
        }
    }

    func testABucketsStartTimeNeverMovesWhileItsWidthHolds() {
        // Same range as above: the width holds from 60s to 100s, so no boundary may move in it.
        var seen: [Int: Date] = [:]
        for span in stride(from: 60.0, through: 100.0, by: 5.0) {
            let buckets = agentActivityUsageBuckets(
                [], start: start, end: start.addingTimeInterval(span), count: 52)
            // Every bucket except the last one, which is the in-progress edge.
            for bucket in buckets.dropLast() {
                if let previous = seen[bucket.index] {
                    XCTAssertEqual(
                        bucket.start.timeIntervalSince1970,
                        previous.timeIntervalSince1970,
                        accuracy: 0.0001,
                        "bucket \(bucket.index) moved at span \(span)s")
                }
                seen[bucket.index] = bucket.start
            }
        }
        XCTAssertFalse(seen.isEmpty)
    }

    /// When the span finally outgrows the width, buckets must merge cleanly rather than land on
    /// arbitrary new boundaries: the new width is exactly double, so two old buckets become one.
    func testOutgrowingTheWidthDoublesItRatherThanDriftingIt() {
        var widths: Set<TimeInterval> = []
        var previous = agentActivityUsageBucketWidth(forDuration: 1, maximum: 52)
        for span in stride(from: 1.0, through: 4000.0, by: 7.0) {
            let width = agentActivityUsageBucketWidth(forDuration: span, maximum: 52)
            if width != previous {
                XCTAssertEqual(width, previous * 2, accuracy: 1e-9, "width jumped at \(span)s")
                previous = width
            }
            widths.insert(width)
        }
        XCTAssertGreaterThan(widths.count, 1, "the width should grow over a wide span range")
    }

    func testBucketCountStaysWithinTheRequestedMaximum() {
        for span in [1.0, 60.0, 600.0, 36_000.0] {
            let buckets = agentActivityUsageBuckets(
                [], start: start, end: start.addingTimeInterval(span), count: 52)
            XCTAssertLessThanOrEqual(buckets.count, 52, "span \(span)s")
            XCTAssertGreaterThanOrEqual(buckets.count, 1)
        }
    }
}
