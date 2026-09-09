import Combine
import XCTest
@testable import Mechanician

@MainActor
final class AgentActivityPublicationTests: XCTestCase {
    private func makeBridge() -> (AgentBridge, URL) {
        let support = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "mechanician-agent-activity-publication-\(UUID().uuidString)",
                isDirectory: true)
        return (
            AgentBridge(settingsBaseOverride: support, environmentOverride: [:]),
            support
        )
    }

    func testDuplicateActivityDoesNotPublishLedger() {
        let (bridge, support) = makeBridge()
        defer {
            bridge.shutdown()
            try? FileManager.default.removeItem(at: support)
        }
        let initial = AgentActivityRecord.state(
            .model, turnID: "turn", detail: "Reasoning")
        bridge.agentActivity = [initial]
        var publications = 0
        let subscription = bridge.$agentActivity.dropFirst().sink { _ in
            publications += 1
        }

        XCTAssertFalse(bridge.appendCurrentAgentActivityRecord(
            .state(.model, turnID: "turn", detail: "Reasoning")))
        XCTAssertEqual(bridge.agentActivity, [initial])
        XCTAssertEqual(publications, 0)
        withExtendedLifetime(subscription) {}
    }

    func testCappedAppendPublishesWhenCountDoesNotChange() {
        let (bridge, support) = makeBridge()
        defer {
            bridge.shutdown()
            try? FileManager.default.removeItem(at: support)
        }
        let initial = (0..<1_600).map {
            AgentActivityRecord.tokens(turnID: "turn", input: $0 + 1)
        }
        bridge.agentActivity = initial
        let appended = AgentActivityRecord.tokens(turnID: "turn", input: 1)
        var publications = 0
        let subscription = bridge.$agentActivity.dropFirst().sink { _ in
            publications += 1
        }

        XCTAssertTrue(bridge.appendCurrentAgentActivityRecord(appended))
        XCTAssertEqual(bridge.agentActivity.count, initial.count)
        XCTAssertEqual(bridge.agentActivity.last?.id, appended.id)
        XCTAssertNotEqual(bridge.agentActivity.first?.id, initial.first?.id)
        XCTAssertEqual(publications, 1)
        withExtendedLifetime(subscription) {}
    }
}
