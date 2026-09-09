import XCTest
@testable import Mechanician

/// FR-238. On a fresh install every NEW conversation was blocked on a provider the user had never
/// connected, and connecting the one they did have fixed only the conversation in front of them.
///
/// `defaultConversationAccess` starts at `.anthropicAPI` and changed only through an explicit
/// Settings action, so connecting an account never moved it. The loop had no exit from the UI: the
/// Providers window labelled the unconnected lane DEFAULT, and the next new conversation blocked
/// again on that same lane.
final class DefaultConversationAccessAdoptionTests: XCTestCase {

    func testConnectingAProviderTakesOverAnUnusableDefault() {
        // The reported case: default is the metered API lane with no key, user connects Codex.
        XCTAssertTrue(
            DefaultConversationAccessAdoption.shouldAdopt(
                connected: .codexSubscription,
                currentDefault: .anthropicAPI,
                currentDefaultIsAvailable: false))
    }

    func testAWorkingDefaultIsNeverTakenOver() {
        // The counterweight, and the reason this rule is narrow. Connecting a second provider must
        // not silently re-route future conversations away from the one already working.
        XCTAssertFalse(
            DefaultConversationAccessAdoption.shouldAdopt(
                connected: .codexSubscription,
                currentDefault: .claudeSubscription,
                currentDefaultIsAvailable: true))
    }

    func testAdoptingTheAccountThatIsAlreadyDefaultIsANoOp() {
        for available in [true, false] {
            XCTAssertFalse(
                DefaultConversationAccessAdoption.shouldAdopt(
                    connected: .anthropicAPI,
                    currentDefault: .anthropicAPI,
                    currentDefaultIsAvailable: available),
                "available=\(available)")
        }
    }

    /// An explicitly chosen default that has since stopped working is still adopted over. Leaving it
    /// would honour a preference at the cost of blocking every new conversation, which is the exact
    /// trade that produced this bug. The user can always set it back in Settings.
    func testABrokenDefaultIsReplacedRatherThanHonoured() {
        XCTAssertTrue(
            DefaultConversationAccessAdoption.shouldAdopt(
                connected: .claudeSubscription,
                currentDefault: .openAIAPI,
                currentDefaultIsAvailable: false))
    }

    func testEveryProviderCanRescueAnUnusableDefault() {
        // No lane is privileged here: whichever account the user actually connected is the one that
        // should carry new conversations when the default cannot.
        for connected in [ModelAccess.claudeSubscription, .codexSubscription,
                          .anthropicAPI, .openAIAPI, .claudeVertex, .claudeBedrock] {
            guard connected != .openAIAPI else { continue }
            XCTAssertTrue(
                DefaultConversationAccessAdoption.shouldAdopt(
                    connected: connected,
                    currentDefault: .openAIAPI,
                    currentDefaultIsAvailable: false),
                "\(connected)")
        }
    }
}
