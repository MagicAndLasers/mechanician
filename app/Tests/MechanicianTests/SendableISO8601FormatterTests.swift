import XCTest
@testable import Mechanician

/// The stores encode on `saveQueue` and decode off the main actor, so their date formatters are now
/// shared across threads deliberately. A wrong answer here is the data-loss class the conversation
/// sidecar exists to avoid: an unparseable date fails the decode, and the whole conversation
/// silently disappears on next launch.
final class SendableISO8601FormatterTests: XCTestCase {
    func testBothStampFormatsParseAndFractionalRoundTrips() throws {
        // The daemon (Node) stamps fractional seconds; Foundation's own `.iso8601` writes plain.
        let fractional = try XCTUnwrap(
            SendableISO8601Formatter.fractional.date(from: "2026-07-31T16:04:05.123Z"))
        let plain = try XCTUnwrap(
            SendableISO8601Formatter.plain.date(from: "2026-07-31T16:04:05Z"))
        XCTAssertEqual(fractional.timeIntervalSince1970, 1785513845.123, accuracy: 0.002)
        XCTAssertEqual(plain.timeIntervalSince1970, 1785513845, accuracy: 0.002)

        let stamped = SendableISO8601Formatter.fractional.string(from: fractional)
        XCTAssertEqual(
            SendableISO8601Formatter.fractional.date(from: stamped)?.timeIntervalSince1970 ?? 0,
            fractional.timeIntervalSince1970,
            accuracy: 0.002)

        // The strict formatter must reject the other form rather than silently returning a wrong
        // date — that rejection is what makes the store's fractional-then-plain fallback meaningful.
        XCTAssertNil(SendableISO8601Formatter.fractional.date(from: "2026-07-31T16:04:05Z"))
    }

    /// The whole premise of the wrapper is that concurrent use is safe. Hammer it from several
    /// queues at once: without serialization this is where a shared ICU formatter corrupts or
    /// crashes, and a passing run here is what justifies sharing one instance.
    func testConcurrentFormattingStaysCorrect() {
        let iterations = 500
        let dates = (0..<iterations).map { Date(timeIntervalSince1970: 1_700_000_000 + Double($0)) }
        let expected = dates.map { date -> String in
            SendableISO8601Formatter.fractional.string(from: date)
        }

        let results = NSMutableArray(array: Array(repeating: "", count: iterations))
        let guardLock = NSLock()
        let done = expectation(description: "concurrent formatting")
        done.expectedFulfillmentCount = iterations

        DispatchQueue.concurrentPerform(iterations: iterations) { index in
            let text = SendableISO8601Formatter.fractional.string(from: dates[index])
            let parsed = SendableISO8601Formatter.fractional.date(from: text)
            guardLock.lock()
            results[index] = (parsed != nil && text == expected[index]) ? "ok" : text
            guardLock.unlock()
            done.fulfill()
        }
        wait(for: [done], timeout: 30)

        let bad = (0..<iterations).filter { (results[$0] as? String) != "ok" }
        XCTAssertTrue(bad.isEmpty, "concurrent formatting disagreed at indices \(bad.prefix(5))")
    }

    /// The stores' coders must be usable from a background queue at all — that is why they are
    /// `nonisolated`. This would not compile if either regressed to main-actor isolation.
    func testStoreCodersRoundTripOffTheMainActor() throws {
        struct Stamped: Codable, Equatable {
            let when: Date
        }
        let original = Stamped(when: Date(timeIntervalSince1970: 1_785_513_845.5))
        let done = expectation(description: "background round trip")
        var decoded: Stamped?
        var failure: String?

        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let data = try ConversationStore.makeEncoder().encode(original)
                decoded = try ConversationStore.makeDecoder().decode(Stamped.self, from: data)
            } catch {
                failure = "\(error)"
            }
            done.fulfill()
        }
        wait(for: [done], timeout: 10)

        XCTAssertNil(failure)
        XCTAssertEqual(
            try XCTUnwrap(decoded).when.timeIntervalSince1970,
            original.when.timeIntervalSince1970,
            accuracy: 0.002)
    }
}
