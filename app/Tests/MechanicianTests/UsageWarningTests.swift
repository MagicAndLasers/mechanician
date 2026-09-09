import Foundation
import XCTest
@testable import Mechanician

/// The state where nothing is blocked and things quietly stop happening.
///
/// `allowed_warning` means every request still succeeds. Claude stops offering follow-up prompt
/// suggestions there, so at a usage threshold a feature disappears with no message and no setting.
/// It was reported as a bug twice, and blamed on the SDK version twice, before the account's own
/// usage turned out to be the cause. A warning nobody sees is the same as no warning.
final class UsageWarningTests: XCTestCase {

    private let event: [String: Any] = [
        "type": "usage_status",
        "status": "allowed_warning",
        "rateLimitType": "seven_day",
        "utilization": NSNumber(value: 0.87),
        "resetsAt": NSNumber(value: 1787281200),
        "isUsingOverage": false,
    ]

    func testAWarningEventDecodesEveryPartOfWhatItSays() throws {
        let warning = try XCTUnwrap(UsageWarning.from(event: event))
        XCTAssertEqual(warning.rateLimitType, "seven_day")
        XCTAssertEqual(warning.utilization, 0.87)
        XCTAssertEqual(warning.percentUsed, 87)
        XCTAssertEqual(warning.isUsingOverage, false)
        XCTAssertEqual(
            warning.resetsAt, Date(timeIntervalSince1970: 1787281200))
        XCTAssertEqual(warning.title, "Most of your weekly Claude allowance is used")
    }

    /// Only the warning state. `allowed` is not worth a row, and `rejected` already has a terminal
    /// error with its own card — saying it twice in two shapes is worse than saying it once.
    func testOnlyTheWarningStateProducesOne() {
        for status in ["allowed", "rejected", "", "something_new"] {
            var other = event
            other["status"] = status
            XCTAssertNil(
                UsageWarning.from(event: other), "\(status) must not produce a warning row")
        }
    }

    /// Never rounded up to 100. A person told they are at 100% while still working would reasonably
    /// conclude the number is wrong, and the number is the only part of this they can check.
    func testTheShareIsWholePerCentAndNeverReadsAsExhausted() {
        func percent(_ utilization: Double) -> Int? {
            var e = event
            e["utilization"] = NSNumber(value: utilization)
            return UsageWarning.from(event: e)?.percentUsed
        }
        XCTAssertEqual(percent(0.751), 75)
        XCTAssertEqual(percent(0.876), 88)
        XCTAssertEqual(percent(0.999), 99)
        XCTAssertEqual(percent(1.0), 99, "still working, so never 100")
        XCTAssertNil(percent(0), "no number is better than a made-up one")
    }

    /// Milliseconds or seconds, the same tolerance the terminal error already applies, so an SDK
    /// wire-format change cannot show a reset date in 1970 or the year 58000.
    func testAResetTimeIsReadInEitherUnit() throws {
        var millis = event
        millis["resetsAt"] = NSNumber(value: 1787281200000)
        XCTAssertEqual(
            try XCTUnwrap(UsageWarning.from(event: millis)).resetsAt,
            Date(timeIntervalSince1970: 1787281200))
    }

    /// Every limit Claude names has words of its own, because "usage limit" alone does not tell a
    /// person whether to wait five hours or a week.
    func testEachLimitSaysWhichAllowanceItIs() {
        func title(_ type: String?) -> String {
            var e = event
            if let type { e["rateLimitType"] = type } else { e.removeValue(forKey: "rateLimitType") }
            return UsageWarning.from(event: e)?.title ?? ""
        }
        XCTAssertTrue(title("five_hour").contains("5-hour"))
        XCTAssertTrue(title("seven_day_opus").contains("Opus"))
        XCTAssertTrue(title("seven_day_sonnet").contains("Sonnet"))
        XCTAssertTrue(title("seven_day").contains("weekly"))
        XCTAssertTrue(title("overage").contains("credits"))
        XCTAssertFalse(title(nil).isEmpty, "an unknown limit still says something true")
    }

    /// It rides on the transcript entry, and every older transcript must still decode. Adding a
    /// non-optional field to a persisted struct once quarantined every sidecar in the library.
    func testATranscriptWrittenBeforeThisFieldStillDecodes() throws {
        // The real persisted shape, taken from a live transcript, minus this field.
        let json = #"""
        {"captureOrdinal":35595,"id":"E9C4D8F0-7A1B-4C3D-9E2F-1A2B3C4D5E6F","kind":"system",
         "observedAt":777000000.0,"permAllowed":false,"permDecided":false,
         "text":"hello","toolIsError":false}
        """#
        let entry = try JSONDecoder().decode(
            TranscriptEntry.self, from: Data(json.utf8))
        XCTAssertNil(entry.usageWarning)
        XCTAssertEqual(entry.text, "hello")

        var carrying = entry
        carrying.usageWarning = UsageWarning.from(event: event)
        let round = try JSONDecoder().decode(
            TranscriptEntry.self, from: JSONEncoder().encode(carrying))
        XCTAssertEqual(round.usageWarning?.percentUsed, 87)
    }
}
