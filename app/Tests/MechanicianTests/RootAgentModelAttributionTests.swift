import XCTest
@testable import Mechanician

@MainActor
final class RootAgentModelAttributionTests: XCTestCase {
    func testProviderReportedModelCreatesANewAttributionWithoutMutatingRequest() {
        let requested = ModelSelection(
            access: .codexSubscription,
            modelID: "gpt-requested")

        let reported = agentActivitySelection(
            reportingModel: "  gpt-provider-effective  ",
            from: requested)

        XCTAssertEqual(reported, ModelSelection(
            access: .codexSubscription,
            modelID: "gpt-provider-effective"))
        XCTAssertEqual(requested.modelID, "gpt-requested")
        XCTAssertNil(agentActivitySelection(reportingModel: "  ", from: requested))
        XCTAssertNil(agentActivitySelection(reportingModel: nil, from: requested))
    }

    func testEffectiveIdentityPersistsAndOwnsLaterTurnSummaryRecords() throws {
        let requested = ModelSelection(
            access: .codexSubscription,
            modelID: "gpt-requested")
        let effective = try XCTUnwrap(agentActivitySelection(
            reportingModel: "gpt-provider-effective",
            from: requested))
        let start = Date(timeIntervalSince1970: 100)
        let records = [
            AgentActivityRecord.state(
                .model,
                turnID: "turn-1",
                detail: "Turn started",
                at: start)
                .attributed(to: requested),
            AgentActivityRecord.identity(
                turnID: "turn-1",
                at: start.addingTimeInterval(1))
                .attributed(to: effective),
            AgentActivityRecord.state(
                .completed,
                turnID: "turn-1",
                at: start.addingTimeInterval(2))
                .attributed(to: requested),
        ]

        let decoded = try JSONDecoder().decode(
            [AgentActivityRecord].self,
            from: JSONEncoder().encode(records))
        let summary = try XCTUnwrap(agentActivityTurnSummaries(decoded).first)

        XCTAssertEqual(decoded[1].kind, .identity)
        XCTAssertEqual(summary.providerAccess, .codexSubscription)
        XCTAssertEqual(summary.modelID, "gpt-provider-effective")
        XCTAssertTrue(summary.isTerminal)
    }

    func testDuplicateIdentitySamplesAreDeduplicated() {
        let effective = ModelSelection(
            access: .codexSubscription,
            modelID: "gpt-provider-effective")
        var records: [AgentActivityRecord] = []
        appendAgentActivityRecord(
            .identity(turnID: "turn-1").attributed(to: effective),
            to: &records)
        appendAgentActivityRecord(
            .identity(turnID: "turn-1").attributed(to: effective),
            to: &records)

        XCTAssertEqual(records.count, 1)
    }

    func testAgentModelIsTurnScoped() {
        XCTAssertTrue(AgentBridge.turnScopedEventTypes.contains("agent_model"))
    }
}
