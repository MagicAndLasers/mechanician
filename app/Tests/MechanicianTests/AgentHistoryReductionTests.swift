import XCTest
@testable import Mechanician

@MainActor
final class AgentHistoryReductionTests: XCTestCase {
    func testDaemonMetadataMapsToContentFreeDowngradeSafeActivityRecord() throws {
        let at = Date(timeIntervalSince1970: 12_345)
        let event: [String: Any] = [
            "type": "history_reduced",
            "omittedMessages": 4,
            "shortenedMessages": 1,
            "reason": "context_compaction_failed",
            // A future daemon field must never be copied into the durable activity record.
            "omittedContent": "private transcript content",
        ]

        let record = try XCTUnwrap(AgentBridge.historyReductionActivityRecord(
            from: event,
            turnID: "turn",
            at: at))
        XCTAssertEqual(record.kind, .context)
        XCTAssertEqual(record.contextEventKind, .historyReduction)
        XCTAssertEqual(record.historyOmittedMessages, 4)
        XCTAssertEqual(record.historyShortenedMessages, 1)
        XCTAssertEqual(record.historyReductionReason, .contextCompactionFailed)
        XCTAssertNil(record.detail)

        let data = try JSONEncoder().encode(record)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object["kind"] as? String, "context")
        XCTAssertNil(
            AgentActivityKind(rawValue: "history_reduction"),
            "history reduction must not add an activity-kind value older builds cannot decode")
        XCTAssertFalse(
            String(decoding: data, as: UTF8.self).contains("private transcript content"))

        var ledger: [AgentActivityRecord] = []
        appendAgentActivityRecord(record, to: &ledger)
        let persisted = try JSONDecoder().decode(
            [AgentActivityRecord].self,
            from: JSONEncoder().encode(ledger))
        XCTAssertEqual(persisted, [record])
    }

    func testNoMarkerIsManufacturedWithoutPositiveReductionCounts() {
        XCTAssertNil(AgentBridge.historyReductionActivityRecord(
            from: [
                "type": "history_reduced",
                "omittedMessages": 0,
                "shortenedMessages": -1,
                "reason": "provider_session_expired",
            ],
            turnID: "turn"))
    }

    func testUnknownReasonAndFutureContextSubtypeFailClosedWithoutDroppingRecord() throws {
        let unknownReason = try XCTUnwrap(AgentBridge.historyReductionActivityRecord(
            from: [
                "type": "history_reduced",
                "omittedMessages": 2,
                "reason": "prompt text does not belong here",
            ],
            turnID: "turn"))
        XCTAssertNil(unknownReason.historyReductionReason)

        let future = try JSONDecoder().decode(
            AgentActivityRecord.self,
            from: Data(
                #"{"kind":"context","contextEventKind":"futureMaintenance","historyOmittedMessages":2}"#
                    .utf8))
        XCTAssertEqual(future.kind, .context)
        XCTAssertNil(future.contextEventKind)
        XCTAssertEqual(future.historyOmittedMessages, 2)
    }

    func testHistoryReductionIsTurnScopedForBackgroundPersistence() {
        XCTAssertTrue(AgentBridge.turnScopedEventTypes.contains("history_reduced"))
    }

    func testProviderNoOutputReplayUsesAllowlistedRecoveryReason() throws {
        let record = try XCTUnwrap(AgentBridge.historyReductionActivityRecord(
            from: [
                "type": "history_reduced",
                "omittedMessages": 1,
                "reason": "provider_no_output",
            ],
            turnID: "turn"))

        XCTAssertEqual(record.historyReductionReason, .providerNoOutput)
    }
}
