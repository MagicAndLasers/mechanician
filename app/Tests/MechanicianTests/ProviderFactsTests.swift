import XCTest
@testable import Mechanician

/// FR-223. Provider facts were hand-mirrored in JavaScript and Swift, with comments in both telling
/// the reader to keep them identical. One pair drifted: the daemon withheld the Opus 5 preview
/// surfaces on Vertex only, while this side withheld them on Vertex AND Bedrock, so the daemon's own
/// "last gate before the wire" was open on Bedrock and Foundry.
///
/// They now come from `shared/provider-facts.json` through a generator, and `scripts/check.sh` fails
/// when a generated file does not match the source. These tests cover the half that a file-level
/// drift check cannot: that this language still USES the shared facts, and still uses them correctly.
@MainActor
final class ProviderFactsTests: XCTestCase {
    // MARK: The fact that drifted

    func testPreviewSurfacesAreWithheldOnEveryThirdPartyRoute() {
        for access in [ModelAccess.claudeVertex, .claudeBedrock] {
            XCTAssertFalse(
                ClaudeSessionPreferences.routeSupportsPreviewSurfaces(access),
                "\(access) is a managed cloud and must not receive a first-party preview setting")
        }
    }

    func testPreviewSurfacesRemainAvailableOnFirstPartyRoutes() {
        // The counterpart, so an over-correction that withholds everything everywhere is caught.
        for access in [ModelAccess.claudeSubscription, .anthropicAPI] {
            XCTAssertTrue(ClaudeSessionPreferences.routeSupportsPreviewSurfaces(access), "\(access)")
        }
    }

    func testNonClaudeLanesHaveNoClaudePreviewSurfaces() {
        for access in [ModelAccess.codexSubscription, .openAIAPI] {
            XCTAssertFalse(ClaudeSessionPreferences.routeSupportsPreviewSurfaces(access), "\(access)")
        }
    }

    /// The lookup is by the daemon's route NAME, so a wrong name would silently grant a managed lane
    /// the preview surfaces rather than fail loudly.
    func testEveryLaneReportsTheRouteNameTheDaemonUses() {
        XCTAssertEqual(ModelAccess.claudeVertex.daemonAuthMode, "vertex")
        XCTAssertEqual(ModelAccess.claudeBedrock.daemonAuthMode, "bedrock")
        XCTAssertEqual(ModelAccess.claudeSubscription.daemonAuthMode, "subscription")
        XCTAssertEqual(ModelAccess.anthropicAPI.daemonAuthMode, "apikey")
    }

    func testTheRouteNameRoundTripsThroughTheProviderInitializer() {
        for access in [ModelAccess.claudeSubscription, .anthropicAPI, .claudeVertex, .claudeBedrock] {
            XCTAssertEqual(
                ModelAccess(provider: "anthropic", authMode: access.daemonAuthMode), access,
                "\(access) must survive the name it is looked up by")
        }
        XCTAssertEqual(
            ModelAccess(provider: "codex", authMode: ModelAccess.codexSubscription.daemonAuthMode),
            .codexSubscription)
        XCTAssertEqual(
            ModelAccess(provider: "openai", authMode: ModelAccess.openAIAPI.daemonAuthMode),
            .openAIAPI)
    }

    // MARK: The generated facts themselves

    func testTheGeneratedFactsArePresent() {
        // A generator that silently produced empty sets would make every gate here fail open while
        // the drift check still passed, since the two languages would agree on nothing.
        XCTAssertFalse(ProviderFacts.thirdPartyRoutes.isEmpty)
        XCTAssertFalse(ProviderFacts.routesWithoutPreviewSurfaces.isEmpty)
        XCTAssertFalse(ProviderFacts.nativeMillionTokenModels.isEmpty)
        XCTAssertFalse(ProviderFacts.thirdPartyMillionTokenModels.isEmpty)
        XCTAssertFalse(ProviderFacts.thirdPartyModelIDPrefixes.isEmpty)
        XCTAssertFalse(ProviderFacts.millionTokenSuffixUpgrades.isEmpty)
    }

    func testAThirdPartyMillionTokenModelIsAlsoANativeOne() {
        // Enforced in the generator too, but a runtime violation would mean a model reported as 1M
        // on Vertex while the first-party check says it is 200K, which is the shape of issue 47.
        XCTAssertTrue(
            ProviderFacts.thirdPartyMillionTokenModels
                .isSubset(of: ProviderFacts.nativeMillionTokenModels))
    }

    func testEveryRouteWithoutPreviewSurfacesIsAThirdPartyRoute() {
        XCTAssertTrue(
            ProviderFacts.routesWithoutPreviewSurfaces.isSubset(of: ProviderFacts.thirdPartyRoutes),
            "withholding a preview surface on a first-party route would be a different decision")
    }

    // MARK: The window computation still reads them

    func testGeneratedThirdPartyRoutesClassifyEveryCurrentClaudeLane() {
        for access in [ModelAccess.claudeVertex, .claudeBedrock] {
            XCTAssertTrue(
                ProviderFacts.thirdPartyRoutes.contains(access.daemonAuthMode), "\(access)")
        }
        for access in [ModelAccess.claudeSubscription, .anthropicAPI] {
            XCTAssertFalse(
                ProviderFacts.thirdPartyRoutes.contains(access.daemonAuthMode), "\(access)")
        }
    }

    func testEveryGeneratedSuffixUpgradeDrivesTheFirstPartyWindowFallback() {
        for modelID in ProviderFacts.millionTokenSuffixUpgrades {
            XCTAssertEqual(
                AgentBridge.anthropicContextWindow(
                    selectedModelID: modelID,
                    resolvedModelID: nil,
                    use1M: true,
                    automaticallyUpgradesBareOpus: true),
                1_000_000,
                modelID)
        }
    }

    func testOpusFiveIsA200KLaneOnAThirdPartyRouteAndOneMillionOnFirstParty() {
        // The live bug this data was extracted from. Kept here as well as in the daemon because the
        // two implementations are still structured differently on purpose.
        XCTAssertEqual(
            AgentBridge.anthropicContextWindow(
                selectedModelID: "claude-opus-5", resolvedModelID: nil, use1M: true,
                automaticallyUpgradesBareOpus: false, thirdPartyRoute: true),
            200_000)
        XCTAssertEqual(
            AgentBridge.anthropicContextWindow(
                selectedModelID: "claude-opus-5", resolvedModelID: nil, use1M: true,
                automaticallyUpgradesBareOpus: true, thirdPartyRoute: false),
            1_000_000)
    }

    func testSonnetFiveKeepsOneMillionOnAThirdPartyRouteIncludingAQualifiedID() {
        for id in ["claude-sonnet-5", "global.anthropic.claude-sonnet-5",
                   "publishers/anthropic/models/claude-sonnet-5"] {
            XCTAssertEqual(
                AgentBridge.anthropicContextWindow(
                    selectedModelID: id, resolvedModelID: nil, use1M: true,
                    automaticallyUpgradesBareOpus: false, thirdPartyRoute: true),
                1_000_000, id)
        }
    }

    /// MEASURED, not inferred. On 2026-08-13 a managed tenant profile declared
    /// `claude-opus-4-8[1m]` on a Vertex route and the provider served a confirmed 1M window. That
    /// deployment reached a 1M Opus window only through that suffixed entry.
    ///
    /// The mistake this guards against has already been made once: reading
    /// `thirdPartyMillionTokenModels` (which governs BARE ids) as a claim about named variants, and
    /// concluding the tenant's working entry should be deleted or clamped to 200K.
    func testAnExplicitOneMillionVariantKeepsItsWindowOnAThirdPartyRoute() {
        for id in ["claude-opus-4-8[1m]", "claude-opus-4-6[1m]"] {
            XCTAssertEqual(
                AgentBridge.anthropicContextWindow(
                    selectedModelID: id, resolvedModelID: nil, use1M: true,
                    automaticallyUpgradesBareOpus: false, thirdPartyRoute: true),
                1_000_000, id)
            // The same variant named as the RESOLVED id takes the early return, which is the path a
            // profile-declared selection actually follows.
            XCTAssertEqual(
                AgentBridge.anthropicContextWindow(
                    selectedModelID: "claude-opus-4-8", resolvedModelID: id, use1M: true,
                    automaticallyUpgradesBareOpus: false, thirdPartyRoute: true),
                1_000_000, id)
        }
        // The bare id is a different selection and stays 200K, because the suffix is never
        // synthesized on these routes. Both entries coexist in the tenant profile for that reason,
        // and the 5x gap between them is what the picker and the downshift warning have to show.
        XCTAssertEqual(
            AgentBridge.anthropicContextWindow(
                selectedModelID: "claude-opus-4-8", resolvedModelID: nil, use1M: true,
                automaticallyUpgradesBareOpus: false, thirdPartyRoute: true),
            200_000)
    }
}
