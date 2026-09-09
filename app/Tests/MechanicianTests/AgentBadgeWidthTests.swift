import XCTest
@testable import Mechanician

/// The header pills clipped `Claude subscrip` and `Requested · opus`, losing the model version —
/// the one thing on the row that cannot be inferred from anything else.
final class AgentBadgeWidthTests: XCTestCase {
    // Root card: [provider .type] [model .model]. Measured widths from the reported screenshot.
    private let routeAndModel: ([CGFloat], [AppKitAgentBadgeTone]) = (
        [103, 118],
        [.type, .model])

    func testEverythingKeepsItsIdealWidthWhenThereIsRoom() {
        let widths = appKitAgentBadgeWidths(
            ideals: routeAndModel.0,
            tones: routeAndModel.1,
            available: 400)

        XCTAssertEqual(widths, routeAndModel.0)
    }

    func testTheModelBadgeIsProtectedBeforeTheRouteBadge() {
        let widths = appKitAgentBadgeWidths(
            ideals: routeAndModel.0,
            tones: routeAndModel.1,
            available: 180)

        // 41 points short: the route absorbs all of it, the model version stays fully legible.
        XCTAssertEqual(widths[1], 118, accuracy: 0.001)
        XCTAssertEqual(widths[0], 62, accuracy: 0.001)
        XCTAssertEqual(widths.reduce(0, +), 180, accuracy: 0.001)
    }

    func testTheModelBadgeOnlyShrinksOnceTheOthersAreAtTheirFloor() {
        let widths = appKitAgentBadgeWidths(
            ideals: routeAndModel.0,
            tones: routeAndModel.1,
            available: 120)

        // The route is down to its 24-point floor before the model gives up a single point.
        XCTAssertEqual(widths[0], 24, accuracy: 0.001)
        XCTAssertEqual(widths[1], 96, accuracy: 0.001)
        XCTAssertEqual(widths.reduce(0, +), 120, accuracy: 0.001)
    }

    /// Subagent cards are [A1 .neutral] [type .type] [model .model]. The tiny ordinal must not be
    /// the thing that funds the deficit just because it is cheap to shrink.
    func testOrdinalSurvivesWhileTheTypeAbsorbsTheDeficit() {
        let widths = appKitAgentBadgeWidths(
            ideals: [26, 70, 96],
            tones: [.neutral, .type, .model],
            available: 150)

        XCTAssertEqual(widths[0], 26, accuracy: 0.001)
        XCTAssertEqual(widths[1], 28, accuracy: 0.001)
        XCTAssertEqual(widths[2], 96, accuracy: 0.001)
    }

    func testAllocationNeverExceedsTheSpaceAvailable() {
        for available in stride(from: CGFloat(10), through: 260, by: 7) {
            let widths = appKitAgentBadgeWidths(
                ideals: [26, 70, 96, 22],
                tones: [.neutral, .type, .model, .warning],
                available: available)
            XCTAssertLessThanOrEqual(widths.reduce(0, +), max(available, 214) + 0.001)
            XCTAssertFalse(widths.contains { $0 < 0 }, "no badge may be allocated a negative width")
        }
    }

    func testDegenerateInputsAreReturnedUnchanged() {
        XCTAssertEqual(appKitAgentBadgeWidths(ideals: [], tones: [], available: 100), [])
        XCTAssertEqual(
            appKitAgentBadgeWidths(ideals: [50], tones: [.type, .model], available: 10),
            [50],
            "a tone/ideal mismatch must not silently reallocate")
    }
}
