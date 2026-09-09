import XCTest
@testable import Mechanician

/// The window a conversation runs in, and what the product says about it.
///
/// These cover a real incident. A conversation moved from a 1M lane to a 200K lane, kept its
/// session, and then auto-compacted ten times at two to four minutes each while the UI showed only
/// "Thinking". Nothing in the product ever said the window had changed, and the window itself was a
/// static derivation that had never been checked against what the provider actually served.
final class ContextWindowMeasurementTests: XCTestCase {

    // MARK: A measurement beats the derivation

    func testAMeasuredWindowOverridesTheAssumptionInBothDirections() {
        // DOWN. We believed 1M, the route really serves 200K. Believing the measurement is what
        // makes the meter honest and the oversized-skill demotion fire.
        let down = AgentBridge.claudeContextWindow(
            selectedModelID: "claude-opus-4-8",
            resolvedModelID: "claude-opus-4-8[1m]",
            use1M: true,
            automaticallyUpgradesBareOpus: false,
            thirdPartyRoute: true,
            measured: ["claude-opus-4-8[1m]": 200_000])
        XCTAssertEqual(down.window, 200_000)
        XCTAssertTrue(down.isMeasured)

        // UP. We assumed 200K, the route really serves 1M. This is the managed-tenant direction:
        // refusing the measurement would take away a window the account genuinely has.
        let up = AgentBridge.claudeContextWindow(
            selectedModelID: "claude-opus-5",
            resolvedModelID: "claude-opus-5",
            use1M: true,
            automaticallyUpgradesBareOpus: false,
            thirdPartyRoute: true,
            measured: ["claude-opus-5": 1_000_000])
        XCTAssertEqual(up.window, 1_000_000)
        XCTAssertTrue(up.isMeasured)
    }

    func testWithoutAMeasurementTheAnswerIsTheDerivationAndSaysSo() {
        let assumed = AgentBridge.claudeContextWindow(
            selectedModelID: "claude-opus-5",
            resolvedModelID: nil,
            use1M: true,
            automaticallyUpgradesBareOpus: false,
            thirdPartyRoute: true,
            measured: [:])
        XCTAssertEqual(assumed.window, 200_000)
        XCTAssertFalse(assumed.isMeasured, "an unchecked derivation must not present as observed")

        // A measurement for a DIFFERENT model must not leak across. The bare and variant ids are
        // separate selections with a 5x gap, and that is exactly the pair a tenant profile declares.
        let other = AgentBridge.claudeContextWindow(
            selectedModelID: "claude-opus-4-8",
            resolvedModelID: "claude-opus-4-8",
            use1M: true,
            automaticallyUpgradesBareOpus: false,
            thirdPartyRoute: true,
            measured: ["claude-opus-4-8[1m]": 1_000_000])
        XCTAssertEqual(other.window, 200_000)
        XCTAssertFalse(other.isMeasured)
    }

    func testTheResolvedIDIsPreferredAsTheJoinKey() {
        // The provider reports usage for the id we sent, which is the resolved one. A first-party
        // Opus 4.8 turn is requested bare and sent as the variant, so keying on the selected id
        // would miss every time.
        let measured = ["claude-opus-4-8[1m]": 900_000, "claude-opus-4-8": 100_000]
        let joined = AgentBridge.claudeContextWindow(
            selectedModelID: "claude-opus-4-8",
            resolvedModelID: "claude-opus-4-8[1m]",
            use1M: true,
            automaticallyUpgradesBareOpus: true,
            thirdPartyRoute: false,
            measured: measured)
        XCTAssertEqual(joined.window, 900_000)

        // Case and padding come from a wire payload, so they must not decide identity.
        XCTAssertEqual(
            AgentBridge.measuredContextWindow(
                for: "  CLAUDE-OPUS-4-8[1M]  ", in: measured),
            900_000)
        // A route that has measured nothing yields nil rather than a zero that reads as a window.
        XCTAssertNil(AgentBridge.measuredContextWindow(for: "claude-opus-5", in: measured))
        XCTAssertNil(AgentBridge.measuredContextWindow(for: nil, in: measured))
        XCTAssertNil(AgentBridge.measuredContextWindow(for: "claude-opus-5", in: [:]))
        XCTAssertNil(AgentBridge.measuredContextWindow(for: "bad", in: ["bad": 0]))
        XCTAssertNil(AgentBridge.measuredContextWindow(for: "bad", in: ["bad": -1]))
    }

    // MARK: The downshift warning

    func testADownshiftPastTheThresholdWarnsWithItsNumbers() {
        // The incident shape: a conversation sized for the 1M lane moving to the 200K lane.
        let warning = AgentBridge.contextDownshiftWarning(
            modelName: "Opus 4.8",
            currentWindow: 1_000_000,
            newWindow: 200_000,
            contextTokens: 400_000)
        XCTAssertEqual(warning, AgentBridge.ContextDownshiftWarning(
            modelName: "Opus 4.8",
            currentWindow: 1_000_000,
            newWindow: 200_000,
            contextTokens: 400_000))
    }

    func testAnUpshiftOrEqualWindowIsSilent() {
        // Moving to a bigger window costs nothing worth interrupting for, even though the provider
        // session is retired either way.
        XCTAssertNil(AgentBridge.contextDownshiftWarning(
            modelName: "Opus 4.8 (1M)",
            currentWindow: 200_000,
            newWindow: 1_000_000,
            contextTokens: 190_000))
        XCTAssertNil(AgentBridge.contextDownshiftWarning(
            modelName: "Sonnet 5",
            currentWindow: 200_000,
            newWindow: 200_000,
            contextTokens: 190_000))
    }

    func testASmallConversationSwitchesWithoutADialog() {
        // The noise case. A dialog on every model change trains the user to dismiss the one that
        // matters, so a conversation that can re-establish itself in the smaller window is silent.
        XCTAssertNil(AgentBridge.contextDownshiftWarning(
            modelName: "Opus 4.8",
            currentWindow: 1_000_000,
            newWindow: 200_000,
            contextTokens: 4_000))

        // The boundary is the share of the NEW window at which it begins compacting immediately.
        let threshold = Int(200_000 * AgentBridge.contextDownshiftWarningFill)
        XCTAssertNil(AgentBridge.contextDownshiftWarning(
            modelName: "Opus 4.8", currentWindow: 1_000_000,
            newWindow: 200_000, contextTokens: threshold))
        XCTAssertNotNil(AgentBridge.contextDownshiftWarning(
            modelName: "Opus 4.8", currentWindow: 1_000_000,
            newWindow: 200_000, contextTokens: threshold + 1))
    }

    func testNothingIsClaimedWhenTheNumbersAreUnknown() {
        // A warning built on a guess is worse than silence, so every missing input fails closed.
        for (current, next, tokens) in [(0, 200_000, 400_000),
                                        (1_000_000, 0, 400_000),
                                        (1_000_000, 200_000, 0),
                                        (-1, 200_000, 400_000)] {
            XCTAssertNil(AgentBridge.contextDownshiftWarning(
                modelName: "Opus 4.8",
                currentWindow: current,
                newWindow: next,
                contextTokens: tokens),
                "current=\(current) new=\(next) tokens=\(tokens)")
        }
    }

    // MARK: Shared formatting

    func testTokenCountsFormatOnceForEverySurface() {
        // The meter, the picker badge and the warning all read from this, so "1.0M" cannot mean two
        // different things in two places.
        XCTAssertEqual(AgentBridge.formattedTokenCount(1_000_000), "1.0M")
        XCTAssertEqual(AgentBridge.formattedTokenCount(200_000), "200.0K")
        XCTAssertEqual(AgentBridge.formattedTokenCount(999), "999")
        XCTAssertEqual(AgentBridge.formattedTokenCount(0), "0")
    }
}
