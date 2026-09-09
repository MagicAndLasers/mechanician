import AppKit
import XCTest
@testable import Mechanician

/// Pins the shared router's vocabulary. Spotlight, the App Intents, notifications and Finder drops
/// all funnel through `MechanicianRoute`; before the extraction, Spotlight carried its own parallel
/// `SpotlightIndex.Target` enum and `AppDelegate` held the only switch over it.
///
/// The rejection cases matter as much as the accepting ones: this is the parser a `mechanician://`
/// URL will reuse, and a URL arrives from anywhere, including a web page. A malformed identifier
/// must produce nothing rather than a partially applied route.
final class MechanicianRouteTests: XCTestCase {
    func testConversationUIDRoundTripsThroughTheSharedRouter() {
        let id = UUID()
        XCTAssertEqual(
            SpotlightIndex.route(for: SpotlightIndex.conversationUID(id)),
            .conversation(id))
    }

    func testArtifactUIDRoundTripsThroughTheSharedRouter() {
        let id = UUID()
        XCTAssertEqual(
            SpotlightIndex.route(for: SpotlightIndex.artifactUID(id)),
            .artifact(id))
    }

    func testUnknownNounIsRefused() {
        // "project" is retired user-facing vocabulary and was never a Spotlight domain. A noun the
        // router does not know must be refused outright, not guessed at.
        XCTAssertNil(SpotlightIndex.route(for: "project:\(UUID().uuidString)"))
        XCTAssertNil(SpotlightIndex.route(for: "workspace:\(UUID().uuidString)"))
    }

    func testMalformedIdentifiersAreRefused() {
        XCTAssertNil(SpotlightIndex.route(for: ""))
        XCTAssertNil(SpotlightIndex.route(for: "conversation"))
        XCTAssertNil(SpotlightIndex.route(for: "conversation:"))
        XCTAssertNil(SpotlightIndex.route(for: "conversation:not-a-uuid"))
        XCTAssertNil(SpotlightIndex.route(for: UUID().uuidString))
    }

    func testColonsInsideTheIdentifierDoNotSplitTheNoun() {
        // maxSplits: 1 means only the first colon separates noun from identifier. A trailing
        // fragment must invalidate the UUID rather than being silently trimmed off.
        XCTAssertNil(SpotlightIndex.route(for: "conversation:\(UUID().uuidString):extra"))
    }

    func testSendingCaseCarriesItsPromptDistinctly() {
        // `.newConversation(sending:)` is the one case that submits to a provider. nil and empty
        // both mean "open a conversation and stop there"; they must not compare equal to a real
        // prompt, because that distinction is what keeps a prefill-only caller from sending.
        XCTAssertNotEqual(
            MechanicianRoute.newConversation(sending: nil),
            .newConversation(sending: "ship it"))
        XCTAssertNotEqual(
            MechanicianRoute.newConversation(sending: ""),
            .newConversation(sending: "ship it"))
        XCTAssertEqual(
            MechanicianRoute.newConversation(sending: nil),
            .newConversation(sending: nil))
    }
}

/// Covers the routing wiring that needs a live `NSApplication`.
@MainActor
final class ArtifactRevealRoutingTests: XCTestCase {
    /// The `.artifact` route must record its selection with no workspace window in existence. This
    /// is the cold-launch shape: a Spotlight result or notification click arriving before any
    /// window has mounted.
    ///
    /// This pins the routing half only. The other half of that fix — that surfacing the Artifacts
    /// window no longer depends on a `DetailView.onChange`, and no longer bypasses
    /// `UtilityWindowVisibility` — is window lifecycle and needs live verification, not a unit test.
    func testArtifactRouteRecordsItsSelectionWithNoWindowMounted() {
        _ = NSApplication.shared
        let active = ActiveWorkspace(
            productAccessRequest: { true },
            whenProductReady: { $0() })
        let id = UUID()

        XCTAssertNil(active.pendingSelectArtifact)
        active.open(.artifact(id))
        XCTAssertEqual(active.pendingSelectArtifact, id)
    }

    /// `revealArtifact` is the single funnel: routing and the in-app move/launcher call sites all
    /// land on the same method, so there is one place that decides how an artifact is surfaced.
    func testRevealAndRouteAgreeOnTheSelection() {
        _ = NSApplication.shared
        let active = ActiveWorkspace(
            productAccessRequest: { true },
            whenProductReady: { $0() })
        let routed = UUID()
        let revealed = UUID()

        active.open(.artifact(routed))
        XCTAssertEqual(active.pendingSelectArtifact, routed)

        active.revealArtifact(revealed)
        XCTAssertEqual(active.pendingSelectArtifact, revealed)
    }
}
