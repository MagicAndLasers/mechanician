import XCTest
@testable import Mechanician

@MainActor
final class ComposerResponsivenessTests: XCTestCase {
    func testActivityOnlyBridgeChangesDoNotInvalidateComposerPresentation() {
        let support = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: support) }
        let store = ConversationStore(
            appSupportBaseOverride: support,
            watchesDirectory: false)
        let bridge = AgentBridge(
            settingsBaseOverride: support,
            environmentOverride: [:],
            conversationStoreOverride: store)
        let baseline = ComposerPresentationState(bridge: bridge)

        // Harness and delegated-agent observations publish through this ledger while work runs.
        // A settled record changes none of the editor's rendered controls and must therefore not
        // make SwiftUI update the native text view.
        bridge.agentActivity = [
            .state(.stopped, turnID: "settled-activity", detail: "Finished"),
        ]
        let afterActivity = ComposerPresentationState(bridge: bridge)

        XCTAssertEqual(afterActivity, baseline)

        bridge.cwd = "/tmp/a-different-workspace"
        XCTAssertNotEqual(
            ComposerPresentationState(bridge: bridge),
            baseline,
            "a real composer render input must still cross the equatable update gate")
        store.flushSaves()
    }
}
