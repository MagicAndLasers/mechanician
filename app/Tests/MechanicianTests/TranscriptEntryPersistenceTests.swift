import XCTest
@testable import Mechanician

final class TranscriptEntryPersistenceTests: XCTestCase {
    private func encodedObject(_ entry: TranscriptEntry) throws -> [String: Any] {
        let data = try ConversationStore.makeEncoder().encode(entry)
        return try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func decodedEntry(from object: [String: Any]) throws -> TranscriptEntry {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return try ConversationStore.makeDecoder().decode(TranscriptEntry.self, from: data)
    }

    func testNewEntryGetsLocalObservationTimestampAndRoundTrips() throws {
        let before = Date()
        let entry = TranscriptEntry(kind: .assistant, text: "Captured locally")
        let after = Date()

        let observedAt = try XCTUnwrap(entry.observedAt)
        XCTAssertGreaterThanOrEqual(observedAt, before)
        XCTAssertLessThanOrEqual(observedAt, after)

        let data = try ConversationStore.makeEncoder().encode(entry)
        let persistedObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any])
        let persistedStamp = try XCTUnwrap(persistedObject["observedAt"] as? String)
        XCTAssertNotNil(
            SendableISO8601Formatter.fractional.date(from: persistedStamp),
            "store timestamps retain fractional seconds")

        let decoded = try ConversationStore.makeDecoder().decode(TranscriptEntry.self, from: data)
        XCTAssertEqual(decoded.id, entry.id)
        XCTAssertEqual(decoded.observedAt?.timeIntervalSince1970 ?? 0,
                       observedAt.timeIntervalSince1970,
                       accuracy: 0.002)
    }

    func testLegacyEntryWithoutObservationTimestampDecodesNil() throws {
        var object = try encodedObject(TranscriptEntry(kind: .user, text: "Historical row"))
        object.removeValue(forKey: "observedAt")

        let decoded = try decodedEntry(from: object)

        XCTAssertNil(decoded.observedAt, "loading history must not fabricate an observation time")
    }

    func testLegacyEntryWithoutCaptureOrdinalsOrLocalSupersessionLinksDecodesNil() throws {
        var entry = TranscriptEntry(kind: .tool, text: "Historical tool")
        entry.captureOrdinal = 11
        entry.supersessionEventID = UUID()
        entry.supersededByEntryID = UUID()
        entry.supersessionCaptureOrdinal = 12
        entry.toolResultCaptureOrdinal = 13
        entry.toolTerminalCaptureOrdinal = 14
        entry.interactionResponseCaptureOrdinal = 15
        entry.interactionAcknowledgedCaptureOrdinal = 16
        entry.interactionClosure = InteractionClosure(
            outcome: "cancelled",
            reason: "turn_interrupted",
            observedAt: Date(timeIntervalSince1970: 1_785_513_847),
            captureOrdinal: 17)
        var object = try encodedObject(entry)
        for key in [
            "captureOrdinal",
            "supersessionEventID",
            "supersededByEntryID",
            "supersessionCaptureOrdinal",
            "toolResultCaptureOrdinal",
            "toolTerminalCaptureOrdinal",
            "interactionResponseCaptureOrdinal",
            "interactionAcknowledgedCaptureOrdinal",
        ] {
            object.removeValue(forKey: key)
        }
        var closure = try XCTUnwrap(object["interactionClosure"] as? [String: Any])
        closure.removeValue(forKey: "captureOrdinal")
        object["interactionClosure"] = closure

        let decoded = try decodedEntry(from: object)

        XCTAssertNil(decoded.captureOrdinal)
        XCTAssertNil(decoded.supersessionEventID)
        XCTAssertNil(decoded.supersededByEntryID)
        XCTAssertNil(decoded.supersessionCaptureOrdinal)
        XCTAssertNil(decoded.toolResultCaptureOrdinal)
        XCTAssertNil(decoded.toolTerminalCaptureOrdinal)
        XCTAssertNil(decoded.interactionResponseCaptureOrdinal)
        XCTAssertNil(decoded.interactionAcknowledgedCaptureOrdinal)
        XCTAssertNil(decoded.interactionClosure?.captureOrdinal)
        XCTAssertEqual(decoded.text, "Historical tool")
    }

    func testLegacyCompactionRowsDecodeWithoutContextEpochFields() throws {
        var entry = TranscriptEntry(kind: .compaction, text: "Summarized earlier messages")
        entry.compactionSummary = "Provider continuity summary"
        entry.compactionSummarySource = "claude_post_compact"
        entry.compactionSummaryTruncated = false
        entry.compactionAccess = .claudeSubscription
        entry.compactionSequence = 3
        var object = try encodedObject(entry)
        for key in [
            "compactionSummary",
            "compactionSummarySource",
            "compactionSummaryTruncated",
            "compactionAccess",
            "compactionSequence",
        ] {
            object.removeValue(forKey: key)
        }

        let decoded = try decodedEntry(from: object)

        XCTAssertEqual(decoded.kind, .compaction)
        XCTAssertNil(decoded.compactionSummary)
        XCTAssertNil(decoded.compactionSummarySource)
        XCTAssertNil(decoded.compactionSummaryTruncated)
        XCTAssertNil(decoded.compactionAccess)
        XCTAssertNil(decoded.compactionSequence)
    }


    func testClaudeSummaryAndBoundaryMergeInEitherSDKOrder() {
        let summary: [String: Any] = [
            "type": "compaction_summary",
            "id": "turn-1",
            "trigger": "auto",
            "compactionSequence": 1,
            "summary": "Preserve the canonical transcript and continue after the boundary.",
            "summarySource": "claude_post_compact",
            "summaryTruncated": false,
        ]
        let boundary: [String: Any] = [
            "type": "compact_boundary",
            "id": "turn-1",
            "trigger": "auto",
            "compactionSequence": 1,
            "preTokens": 170_000,
            "postTokens": 18_000,
        ]

        for summaryFirst in [true, false] {
            var entries: [TranscriptEntry] = []
            if summaryFirst {
                AgentBridge.applyCompactionSummary(
                    summary,
                    to: &entries,
                    access: .claudeSubscription)
                AgentBridge.applyCompactionBoundary(
                    boundary,
                    to: &entries,
                    access: .claudeSubscription)
            } else {
                AgentBridge.applyCompactionBoundary(
                    boundary,
                    to: &entries,
                    access: .claudeSubscription)
                AgentBridge.applyCompactionSummary(
                    summary,
                    to: &entries,
                    access: .claudeSubscription)
            }

            XCTAssertEqual(entries.count, 1, "summaryFirst=\(summaryFirst)")
            XCTAssertEqual(entries[0].compactionPreTokens, 170_000)
            XCTAssertEqual(entries[0].compactionPostTokens, 18_000)
            XCTAssertEqual(entries[0].compactionSummary, summary["summary"] as? String)
            XCTAssertEqual(entries[0].compactionSummarySource, "claude_post_compact")
            XCTAssertEqual(entries[0].compactionAccess, .claudeSubscription)
            XCTAssertEqual(entries[0].compactionSequence, 1)
        }
    }

    func testMultipleCompactionsInOneTurnPairBySequenceInEitherSurfaceOrder() {
        func summary(_ sequence: Int) -> [String: Any] {[
            "type": "compaction_summary",
            "id": "turn-many",
            "trigger": "auto",
            "compactionSequence": sequence,
            "summary": "Summary \(sequence)",
            "summarySource": "claude_post_compact",
            "summaryTruncated": false,
        ]}
        func boundary(_ sequence: Int) -> [String: Any] {[
            "type": "compact_boundary",
            "id": "turn-many",
            "trigger": "auto",
            "compactionSequence": sequence,
            "preTokens": 100_000 + sequence,
            "postTokens": 10_000 + sequence,
        ]}

        for summariesFirst in [true, false] {
            var entries: [TranscriptEntry] = []
            let first = summariesFirst ? [summary(1), summary(2)] : [boundary(1), boundary(2)]
            let second = summariesFirst ? [boundary(1), boundary(2)] : [summary(1), summary(2)]
            for event in first + second {
                if event["type"] as? String == "compaction_summary" {
                    AgentBridge.applyCompactionSummary(
                        event, to: &entries, access: .claudeSubscription)
                } else {
                    AgentBridge.applyCompactionBoundary(
                        event, to: &entries, access: .claudeSubscription)
                }
            }

            XCTAssertEqual(entries.count, 2, "summariesFirst=\(summariesFirst)")
            for sequence in 1...2 {
                guard let entry = entries.first(where: {
                    $0.compactionSequence == sequence
                }) else {
                    XCTFail("missing compaction sequence \(sequence)")
                    continue
                }
                XCTAssertEqual(entry.compactionSummary, "Summary \(sequence)")
                XCTAssertEqual(entry.compactionPreTokens, 100_000 + sequence)
                XCTAssertEqual(entry.compactionPostTokens, 10_000 + sequence)
            }
        }
    }

    func testCompactionSummaryHandoffIsReadOnceAndDeleted() throws {
        let summary = "Keep the complete transcript while continuing from this provider summary."
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(
            "mechanician-compaction-\(UUID().uuidString).summary")
        try Data(summary.utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let resolved = try XCTUnwrap(AgentBridge.resolvingCompactionSummaryHandoff([
            "type": "compaction_summary",
            "id": "turn-handoff",
            "compactionSequence": 1,
            "summaryPath": url.path,
            "summaryBytes": summary.utf8.count,
        ]))

        XCTAssertEqual(resolved["summary"] as? String, summary)
        XCTAssertNil(resolved["summaryPath"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testCompactionSummaryHandoffWithMismatchedSizeIsRejectedAndDeleted() throws {
        let summary = "Provider summary"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(
            "mechanician-compaction-\(UUID().uuidString).summary")
        try Data(summary.utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        XCTAssertNil(AgentBridge.resolvingCompactionSummaryHandoff([
            "type": "compaction_summary",
            "id": "turn-handoff",
            "compactionSequence": 1,
            "summaryPath": url.path,
            "summaryBytes": summary.utf8.count + 1,
        ]))
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testToolOwnerAndTurnAliasesRoundTripAndRemainTolerantForLegacyRows() throws {
        var entry = TranscriptEntry(kind: .tool, text: "Captured tool")
        entry.toolOwnerAgentID = "subagent:provider-child-private"
        entry.toolTurnID = "provider-turn-private"

        let object = try encodedObject(entry)
        XCTAssertEqual(object["toolOwnerAgentID"] as? String, entry.toolOwnerAgentID)
        XCTAssertEqual(object["toolTurnID"] as? String, entry.toolTurnID)
        let decoded = try decodedEntry(from: object)
        XCTAssertEqual(decoded.toolOwnerAgentID, entry.toolOwnerAgentID)
        XCTAssertEqual(decoded.toolTurnID, entry.toolTurnID)

        var legacy = object
        legacy.removeValue(forKey: "toolOwnerAgentID")
        legacy.removeValue(forKey: "toolTurnID")
        let decodedLegacy = try decodedEntry(from: legacy)
        XCTAssertNil(decodedLegacy.toolOwnerAgentID)
        XCTAssertNil(decodedLegacy.toolTurnID)
    }

    func testCaptureRefinementOrdinalsAndLocalSupersessionLinksRoundTrip() throws {
        let eventID = try XCTUnwrap(UUID(uuidString: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"))
        let replacementID = try XCTUnwrap(
            UUID(uuidString: "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"))
        var entry = TranscriptEntry(kind: .tool, text: "Captured tool")
        entry.captureOrdinal = 101
        entry.supersessionEventID = eventID
        entry.supersededByEntryID = replacementID
        entry.supersessionCaptureOrdinal = 102
        entry.toolResultCaptureOrdinal = 103
        entry.toolTerminalCaptureOrdinal = 104
        entry.interactionResponseCaptureOrdinal = 105
        entry.interactionAcknowledgedCaptureOrdinal = 106
        entry.interactionClosure = InteractionClosure(
            outcome: "cancelled",
            reason: "turn_interrupted",
            observedAt: Date(timeIntervalSince1970: 1_785_513_847),
            captureOrdinal: 107)

        let object = try encodedObject(entry)
        let closure = try XCTUnwrap(object["interactionClosure"] as? [String: Any])
        for (key, ordinal) in [
            "captureOrdinal": UInt64(101),
            "supersessionCaptureOrdinal": 102,
            "toolResultCaptureOrdinal": 103,
            "toolTerminalCaptureOrdinal": 104,
            "interactionResponseCaptureOrdinal": 105,
            "interactionAcknowledgedCaptureOrdinal": 106,
        ] {
            XCTAssertEqual((object[key] as? NSNumber)?.uint64Value, ordinal, key)
        }
        XCTAssertEqual((closure["captureOrdinal"] as? NSNumber)?.uint64Value, 107)

        let decoded = try decodedEntry(from: object)

        XCTAssertEqual(decoded.captureOrdinal, 101)
        XCTAssertEqual(decoded.supersessionEventID, eventID)
        XCTAssertEqual(decoded.supersededByEntryID, replacementID)
        XCTAssertEqual(decoded.supersessionCaptureOrdinal, 102)
        XCTAssertEqual(decoded.toolResultCaptureOrdinal, 103)
        XCTAssertEqual(decoded.toolTerminalCaptureOrdinal, 104)
        XCTAssertEqual(decoded.interactionResponseCaptureOrdinal, 105)
        XCTAssertEqual(decoded.interactionAcknowledgedCaptureOrdinal, 106)
        XCTAssertEqual(decoded.interactionClosure?.captureOrdinal, 107)
    }

    func testObservationTimestampAcceptsFractionalAndPlainISO8601() throws {
        var object = try encodedObject(TranscriptEntry(kind: .system, text: "Timestamp fixture"))

        object["observedAt"] = "2026-07-31T16:04:05.123Z"
        let fractional = try decodedEntry(from: object)
        XCTAssertEqual(fractional.observedAt?.timeIntervalSince1970 ?? 0,
                       1_785_513_845.123,
                       accuracy: 0.002)

        object["observedAt"] = "2026-07-31T16:04:05Z"
        let plain = try decodedEntry(from: object)
        XCTAssertEqual(plain.observedAt?.timeIntervalSince1970 ?? 0,
                       1_785_513_845,
                       accuracy: 0.002)
    }

    func testInteractionSelectionFreeTextAndClosureRoundTrip() throws {
        let selectedAt = Date(timeIntervalSince1970: 1_785_513_845.123)
        let acknowledgedAt = Date(timeIntervalSince1970: 1_785_513_846.456)
        let closedAt = Date(timeIntervalSince1970: 1_785_513_847.789)
        var entry = TranscriptEntry(kind: .question, text: "Choose a destination")
        entry.questionId = "question-1"
        entry.questionAnswers = ["Destination": "Other"]
        entry.questionFreeTextResponse = "A folder with spaces"
        entry.interactionResponseStatus = .accepted
        entry.interactionResponseObservedAt = selectedAt
        entry.interactionAcknowledgedAt = acknowledgedAt
        entry.interactionClosure = InteractionClosure(
            outcome: "cancelled",
            reason: "turn_interrupted",
            observedAt: closedAt,
            captureOrdinal: 44)

        let data = try ConversationStore.makeEncoder().encode(entry)
        let decoded = try ConversationStore.makeDecoder().decode(TranscriptEntry.self, from: data)

        XCTAssertEqual(decoded.questionAnswers, ["Destination": "Other"])
        XCTAssertEqual(decoded.questionFreeTextResponse, "A folder with spaces")
        XCTAssertEqual(decoded.interactionResponseStatus, .accepted)
        XCTAssertEqual(
            decoded.interactionResponseObservedAt?.timeIntervalSince1970 ?? 0,
            selectedAt.timeIntervalSince1970,
            accuracy: 0.002)
        XCTAssertEqual(
            decoded.interactionAcknowledgedAt?.timeIntervalSince1970 ?? 0,
            acknowledgedAt.timeIntervalSince1970,
            accuracy: 0.002)
        XCTAssertEqual(decoded.interactionClosure?.outcome, "cancelled")
        XCTAssertEqual(decoded.interactionClosure?.reason, "turn_interrupted")
        XCTAssertEqual(decoded.interactionClosure?.captureOrdinal, 44)
        XCTAssertEqual(
            decoded.interactionClosure?.observedAt.timeIntervalSince1970 ?? 0,
            closedAt.timeIntervalSince1970,
            accuracy: 0.002)
    }

    func testLegacyEntryWithoutInteractionLifecycleFieldsStillDecodes() throws {
        var object = try encodedObject(TranscriptEntry(kind: .permission, text: "Run command?"))
        object.removeValue(forKey: "interactionResponseStatus")
        object.removeValue(forKey: "interactionResponseObservedAt")
        object.removeValue(forKey: "interactionAcknowledgedAt")
        object.removeValue(forKey: "interactionClosure")
        object.removeValue(forKey: "questionFreeTextResponse")

        let decoded = try decodedEntry(from: object)

        XCTAssertNil(decoded.interactionResponseStatus)
        XCTAssertNil(decoded.interactionResponseObservedAt)
        XCTAssertNil(decoded.interactionAcknowledgedAt)
        XCTAssertNil(decoded.interactionClosure)
        XCTAssertNil(decoded.questionFreeTextResponse)
    }

    func testFutureInteractionStatusDoesNotDropTheTranscriptEntry() throws {
        var object = try encodedObject(TranscriptEntry(kind: .permission, text: "Keep this row"))
        object["interactionResponseStatus"] = "deliveryDeferredByFutureBuild"

        let decoded = try decodedEntry(from: object)

        XCTAssertEqual(decoded.text, "Keep this row")
        XCTAssertEqual(decoded.kind, .permission)
        XCTAssertEqual(
            decoded.interactionResponseStatus,
            .unknown("deliveryDeferredByFutureBuild"))
        XCTAssertEqual(
            try encodedObject(decoded)["interactionResponseStatus"] as? String,
            "deliveryDeferredByFutureBuild",
            "an older build must retain an unknown future lifecycle value when it rewrites the row")
    }

    func testFutureClosureVocabularyRoundTripsWithoutAnAppUpdate() throws {
        var object = try encodedObject(TranscriptEntry(kind: .question, text: "Keep this too"))
        object["interactionClosure"] = [
            "outcome": "superseded_by_policy",
            "reason": "future_provider_reason",
            "observedAt": "2026-07-31T16:04:05.123Z",
        ]

        let decoded = try decodedEntry(from: object)

        XCTAssertEqual(decoded.interactionClosure?.outcome, "superseded_by_policy")
        XCTAssertEqual(decoded.interactionClosure?.reason, "future_provider_reason")
        XCTAssertEqual(decoded.text, "Keep this too")
    }
}
