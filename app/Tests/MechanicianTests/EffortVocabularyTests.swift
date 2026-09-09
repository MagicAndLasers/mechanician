import XCTest
@testable import Mechanician

/// Effort levels are provider-REPORTED. The daemon's own comment says so, and then five call sites
/// did the opposite: each filtered the reported list against its own hardcoded array, and the arrays
/// had already drifted apart from one another. A level a provider shipped after a given build was
/// therefore invisible in the picker AND unsendable on the wire until an app release went out.
///
/// The rule these tests pin is: bound the shape, not the vocabulary.
@MainActor
final class EffortVocabularyTests: XCTestCase {
    // MARK: A level this build has never heard of

    func testAnUnfamiliarLevelSurvivesToThePicker() {
        let choices = AgentBridge.visibleEffortChoices(
            reported: ["low", "medium", "high", "extreme"])
        XCTAssertEqual(choices, ["low", "medium", "high", "extreme"],
                       "a level shipped after this build must reach a menu row, not be dropped")
    }

    func testKnownLevelsKeepLadderOrderRegardlessOfHowTheyWereReported() {
        // The provider is not obliged to report in cost order, and the picker is a ladder.
        let choices = AgentBridge.visibleEffortChoices(reported: ["max", "low", "high", "none"])
        XCTAssertEqual(choices, ["none", "low", "high", "max"])
    }

    func testUnfamiliarLevelsComeAfterEveryLevelWeCanPlace() {
        // We can order what we know. We cannot claim where an unknown one sits, so it goes last
        // rather than being interleaved on a guess.
        let choices = AgentBridge.visibleEffortChoices(
            reported: ["extreme", "medium", "glacial", "low"])
        XCTAssertEqual(choices, ["low", "medium", "extreme", "glacial"])
    }

    // MARK: The `ultra` carve-out

    /// On Claude, `ultra` is not an effort level: it maps to `xhigh` plus `settings.ultracode`.
    /// Rendering it as a raw selectable level would bypass `ultraTurnConfiguration` and put a value
    /// on the wire the route does not take. Opening the vocabulary must not open this.
    func testUltraIsNeverSurfacedAsAnOrdinaryLevel() {
        XCTAssertEqual(
            AgentBridge.visibleEffortChoices(reported: ["low", "ultra", "high"]),
            ["low", "high"])
        XCTAssertFalse(
            EffortLevels.ordered(reported: ["ultra", "medium"], includingReserved: false)
                .contains("ultra"))
    }

    func testTheSendingPathStillKeepsUltra() {
        // `ultraTurnConfiguration` reads it out of this list, so the carve-out is one-directional.
        XCTAssertEqual(
            EffortLevels.ordered(reported: ["medium", "ultra"], includingReserved: true),
            ["medium", "ultra"])
    }

    // MARK: Shape, since the vocabulary is no longer the bound

    func testMalformedNamesAreStillRefused() {
        for malformed in ["", "9high", "Very High", "high!", "high effort", String(repeating: "x", count: 33)] {
            XCTAssertFalse(EffortLevels.isWellFormed(malformed), "\(malformed) is not an identifier")
        }
        XCTAssertEqual(
            AgentBridge.visibleEffortChoices(reported: ["low", "Very High", "high!", "extreme"]),
            ["low", "extreme"],
            "unrecognized is carried; malformed is dropped")
    }

    func testWellFormedNamesAreAccepted() {
        for name in ["extreme", "x", "ultra-high", "level_9", "h9"] {
            XCTAssertTrue(EffortLevels.isWellFormed(name))
        }
    }

    func testABrokenCatalogCannotFloodTheMenu() {
        let flood = (0..<200).map { "level\($0)" }
        XCTAssertEqual(
            EffortLevels.ordered(reported: flood, includingReserved: false).count,
            EffortLevels.maximumReported)
    }

    func testDuplicatesAndCasingCollapse() {
        XCTAssertEqual(
            AgentBridge.visibleEffortChoices(reported: ["HIGH", "high", "Extreme", "extreme"]),
            ["high", "extreme"])
    }

    // MARK: What the UI is allowed to imply

    func testAnUnfamiliarLevelIsNotDescribedAsIfWeKnewIt() {
        let description = AgentBridge.effortDescription("extreme")
        XCTAssertTrue(description.contains("does not know how it compares"),
                      "the list is ordered, so an unexplained row would imply a cost position")
        XCTAssertFalse(AgentBridge.effortDescription("high").contains("does not know"))
    }

    /// The fallback ranking is deliberately NOT opened up: an unknown level has no defensible
    /// position, so it must never be auto-selected on someone's behalf. Returning nil lets the
    /// caller fall back explicitly.
    func testAnUnfamiliarLevelIsNeverChosenAutomatically() {
        XCTAssertNil(AgentBridge.preferredDefaultEffort(from: ["extreme", "glacial"]))
        XCTAssertEqual(AgentBridge.preferredDefaultEffort(from: ["extreme", "high"]), "high")
    }

    // MARK: FR-229 — which lanes offer Ultra

    /// Ultra was unreachable on the two managed Claude lanes because `showsUltraPill` was written as
    /// a Claude-versus-Codex distinction with a `default:` catch-all, which swept them up. Nothing
    /// else in the codebase agreed: `ultraTurnConfiguration` already returns a configuration for all
    /// four Claude lanes, and the daemon's "not available on this Claude route" gate is applied to
    /// the advisor and Fast mode and deliberately not to `ultracode`.
    func testEveryClaudeLaneOffersTheUltraPill() {
        for access in [ModelAccess.claudeSubscription, .anthropicAPI, .claudeVertex, .claudeBedrock] {
            XCTAssertTrue(AgentBridge.laneUsesUltraPill(access), "\(access) is a Claude lane")
        }
    }

    func testCodexAndTheOpenAIAPIDoNotUseThePill() {
        // Codex exposes Ultra inside the effort picker instead, and the OpenAI API has no Ultra.
        XCTAssertFalse(AgentBridge.laneUsesUltraPill(.codexSubscription))
        XCTAssertFalse(AgentBridge.laneUsesUltraPill(.openAIAPI))
    }

    func testTheManagedClaudeLanesResolveAnUltraTurn() {
        for access in [ModelAccess.claudeVertex, .claudeBedrock] {
            let configuration = AgentBridge.ultraTurnConfiguration(
                access: access, efforts: ["low", "medium", "high", "xhigh", "max"])
            XCTAssertEqual(configuration?.effort, "xhigh", "\(access)")
            XCTAssertEqual(configuration?.ultracode, true, "\(access)")
        }
    }

    func testAClaudeLaneWithoutXhighStillHasNoUltra() {
        XCTAssertFalse(AgentBridge.supportsUltra(
            access: .claudeVertex, efforts: ["low", "medium", "high"]))
    }
}
