import XCTest
@testable import Mechanician

/// FR-240. New conversations default to the biggest context window a route actually offers.
///
/// A managed Vertex deployment can declare both `Opus 4.8` and `Opus 4.8 (1M)`, and new
/// conversations were defaulting to the 200K one because third-party routes never auto-upgrade. The
/// difference is invisible until a long conversation starts compacting every few minutes, which is
/// exactly how a 27-minute stall got misread as a provider problem.
final class LargestContextWindowVariantTests: XCTestCase {

    private func entry(
        _ modelID: String,
        access: ModelAccess = .claudeVertex,
        isDefault: Bool = false,
        resolved: String? = nil
    ) -> ModelCatalogEntry {
        ModelCatalogEntry(
            selection: ModelSelection(access: access, modelID: modelID),
            displayName: modelID,
            description: "",
            resolvedModelID: resolved,
            isDefault: isDefault,
            supportedEfforts: [],
            capabilities: [])
    }

    /// Windows keyed off the `[1m]` marker, which is what the real computation reduces to for the
    /// pair this rule exists for.
    private func window(_ e: ModelCatalogEntry) -> Int {
        (e.resolvedModelID ?? e.selection.modelID).contains("[1m]") ? 1_000_000 : 200_000
    }

    private func family(_ id: String) -> String {
        AgentBridge.canonicalClaudeModelID(id)
    }

    func testTheOneMillionVariantWinsOverTheBareDefault() {
        // The reported deployment shape: both declared, the bare one marked default.
        let bare = entry("claude-opus-4-8", isDefault: true)
        let big = entry("claude-opus-4-8[1m]")
        let picked = LargestContextWindowVariant.preferred(
            among: [bare, big], chosen: bare, family: family, window: window)
        XCTAssertEqual(picked.selection.modelID, "claude-opus-4-8[1m]")
    }

    func testADeploymentWithoutTheVariantIsUnchanged() {
        // The safety property. A route that does not publish the variant has nothing to select, and
        // this rule must never invent the id — a 1M variant is enabled per project on these routes.
        let bare = entry("claude-opus-4-8", isDefault: true)
        let picked = LargestContextWindowVariant.preferred(
            among: [bare, entry("claude-sonnet-4-6")],
            chosen: bare, family: family, window: window)
        XCTAssertEqual(picked.selection.modelID, "claude-opus-4-8")
    }

    func testADifferentModelFamilyIsNeverSubstituted() {
        // Sonnet having a bigger window is not a reason to move the user off Opus.
        let opus = entry("claude-opus-4-8", isDefault: true)
        let otherFamily = entry("claude-sonnet-5[1m]")
        let picked = LargestContextWindowVariant.preferred(
            among: [opus, otherFamily], chosen: opus, family: family, window: window)
        XCTAssertEqual(picked.selection.modelID, "claude-opus-4-8")
    }

    func testAnotherAccountsEntryIsNeverSubstituted() {
        let vertexBare = entry("claude-opus-4-8", isDefault: true)
        let firstPartyBig = entry("claude-opus-4-8[1m]", access: .claudeSubscription)
        let picked = LargestContextWindowVariant.preferred(
            among: [vertexBare, firstPartyBig],
            chosen: vertexBare, family: family, window: window)
        XCTAssertEqual(picked.selection.access, .claudeVertex)
        XCTAssertEqual(picked.selection.modelID, "claude-opus-4-8")
    }

    func testAnEqualWindowKeepsTheProvidersOwnDefault() {
        // Ties are not upgrades. Preferring the incumbent keeps a declared default meaningful.
        let first = entry("claude-opus-4-8", isDefault: true)
        let second = entry("claude-opus-4-8")
        let picked = LargestContextWindowVariant.preferred(
            among: [first, second], chosen: first, family: family, window: window)
        XCTAssertTrue(picked.isDefault)
    }

    func testAlreadyOnTheLargestVariantIsANoOp() {
        let big = entry("claude-opus-4-8[1m]", isDefault: true)
        let picked = LargestContextWindowVariant.preferred(
            among: [big, entry("claude-opus-4-8")],
            chosen: big, family: family, window: window)
        XCTAssertEqual(picked.selection.modelID, "claude-opus-4-8[1m]")
    }

    func testAResolvedVariantIDIsMatchedAsTheSameFamily() {
        // A catalog may name the family in `modelID` and the served variant in `resolvedModelID`.
        let bare = entry("opus", isDefault: true, resolved: "claude-opus-4-8")
        let big = entry("opus-1m", resolved: "claude-opus-4-8[1m]")
        let picked = LargestContextWindowVariant.preferred(
            among: [bare, big], chosen: bare, family: family, window: window)
        XCTAssertEqual(picked.selection.modelID, "opus-1m")
    }

    func testAnEmptyModelIDIsNeverSelected() {
        let bare = entry("claude-opus-4-8", isDefault: true)
        let placeholder = entry("")
        let picked = LargestContextWindowVariant.preferred(
            among: [bare, placeholder], chosen: bare, family: family, window: window)
        XCTAssertEqual(picked.selection.modelID, "claude-opus-4-8")
    }
}
