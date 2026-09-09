import XCTest
@testable import Mechanician

/// FR-219. Pressing Return while a provider lane was still starting did nothing at all: the
/// composer's gate required `hasUsableActiveAccount`, which is `isReady && !needsProviderSetup`,
/// and `submit()` returned without queueing, persisting, or acknowledging the prompt.
///
/// Two different facts wore one name. `needsProviderSetup(for:)` returns false for a lane that is
/// not ready yet, so it was never what blocked a cold start; `isReady` was. And `send()` already
/// had a queue-and-notify fallback, so the keystroke had somewhere to go the whole time.
@MainActor
final class ComposerColdStartTests: XCTestCase {
    private func makeBridge() -> (AgentBridge, URL) {
        let support = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "mechanician-composer-cold-start-\(UUID().uuidString)",
                isDirectory: true)
        return (AgentBridge(settingsBaseOverride: support, environmentOverride: [:]), support)
    }

    func testComposerAcceptsSubmissionWhileTheLaneIsStillStarting() {
        let (bridge, support) = makeBridge()
        defer {
            bridge.shutdown()
            try? FileManager.default.removeItem(at: support)
        }

        // A bridge with no lane state yet IS the cold start: nothing has reported ready.
        XCTAssertFalse(
            bridge.hasUsableActiveAccount,
            "no lane has reported ready, so the account is not usable yet")
        XCTAssertTrue(
            bridge.composerAcceptsSubmission,
            "a lane that has not finished starting must not swallow the keystroke")

        // The composer policy turns that into a real submission rather than a dropped Return.
        let policy = ComposerDeliveryPolicy(
            hasText: true,
            runtimeReady: bridge.composerAcceptsSubmission,
            turnReserved: false,
            canGuide: false)
        XCTAssertTrue(policy.canSubmit)

        // The half that must stay: a lane needing setup still refuses, so prompts cannot pile up
        // against a lane that can never start while the Connect banner sits above them.
        let needsSetup = ComposerDeliveryPolicy(
            hasText: true,
            runtimeReady: false,
            turnReserved: false,
            canGuide: false)
        XCTAssertFalse(needsSetup.canSubmit)
    }
}
