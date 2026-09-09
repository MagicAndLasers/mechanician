import XCTest
@testable import Mechanician

/// The context meter measured fill against the model's maximum while compaction answered to a
/// different, lower number the app was never sent.
///
/// Measured on a real library: one conversation on a 1,000,000-token window compacted **85 times**
/// without its context ever exceeding 516,178 tokens, about 52% full. Nothing was wrong with the
/// compaction; the meter was reporting against the wrong denominator, so routine maintenance looked
/// like a defect.
final class ContextCompactionThresholdTests: XCTestCase {
    func testAThresholdBelowTheWindowIsWhatTheMeterShouldUse() {
        XCTAssertEqual(
            AgentBridge.compactionThreshold(reported: 780_000, window: 1_000_000),
            780_000)
        XCTAssertEqual(
            AgentBridge.compactionThreshold(reported: 160_000, window: 200_000),
            160_000)
    }

    /// Most lanes report no threshold at all: Codex, the OpenAI lanes, and Claude on Vertex, which
    /// answers no context control. Those must keep measuring against the window exactly as before.
    func testNoThresholdLeavesTheWindowAsTheDenominator() {
        XCTAssertNil(AgentBridge.compactionThreshold(reported: nil, window: 1_000_000))
        XCTAssertNil(AgentBridge.compactionThreshold(reported: 0, window: 1_000_000))
        XCTAssertNil(AgentBridge.compactionThreshold(reported: -1, window: 1_000_000))
    }

    /// A threshold at or above the window explains nothing the window does not already, and using
    /// it would make a full conversation read as under-full.
    func testAThresholdThatIsNotBelowTheWindowIsIgnored() {
        XCTAssertNil(AgentBridge.compactionThreshold(reported: 1_000_000, window: 1_000_000))
        XCTAssertNil(AgentBridge.compactionThreshold(reported: 1_200_000, window: 1_000_000))
    }

    /// Without a window there is no denominator to correct, so there is nothing to report.
    func testAnUnknownWindowYieldsNoThreshold() {
        XCTAssertNil(AgentBridge.compactionThreshold(reported: 780_000, window: nil))
        XCTAssertNil(AgentBridge.compactionThreshold(reported: 780_000, window: 0))
    }

    /// The number a person reads. Against the window, the conversation that compacted 85 times
    /// looked half empty; against the threshold it reads as nearly full, which is the truth.
    func testTheObservedCaseNowReadsAsNearlyFull() {
        let observedTokens = 516_178
        let window = 1_000_000
        let threshold = try? XCTUnwrap(
            AgentBridge.compactionThreshold(reported: 520_000, window: window))
        let limit = threshold ?? window
        XCTAssertEqual(Int(Double(observedTokens) / Double(limit) * 100), 99)
        XCTAssertEqual(Int(Double(observedTokens) / Double(window) * 100), 51,
                       "the old denominator is what made this look like a bug")
    }
}
