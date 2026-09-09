import XCTest
@testable import Mechanician

// Claude Opus 5 adoption, plan Phase 1B (O5-007): the canonical-replacement reducer.
//
// A safety refusal cannot be produced on demand — the only way to make a model refuse is to ask it
// for harm, which neither CI nor a developer should be doing to get a test to pass. So this behavior
// is defined entirely by events shaped to the daemon's normalizer output, and those events are the
// contract. The reducer is pure and shared by the foreground and background paths precisely so there
// is only one implementation to hold to it.

final class ClaudeRefusalFallbackTests: XCTestCase {
    private func assistant(_ text: String, frame: String?) -> TranscriptEntry {
        var entry = TranscriptEntry(kind: .assistant, text: text)
        entry.providerFrameUUID = frame
        return entry
    }

    private func tool(_ name: String, frame: String?) -> TranscriptEntry {
        var entry = TranscriptEntry(kind: .tool, text: "ran \(name)")
        entry.toolName = name
        entry.toolUseId = "use-\(name)"
        entry.providerFrameUUID = frame
        return entry
    }

    private func fallbackEvent(
        retracting: [String] = ["frame-1"],
        persistent: Bool = true,
        notice: String = "notice-1",
        requestID: String? = "req_01"
    ) -> [String: Any] {
        var event: [String: Any] = [
            "type": "model_refusal",
            "outcome": "fallback",
            "originalModel": "claude-opus-5",
            "fallbackModel": "claude-opus-4-8",
            "category": "cyber",
            "explanation": "Asked for exploit code.",
            "persistent": persistent,
            "retractedMessageUUIDs": retracting,
            "frameUUID": notice,
        ]
        if let requestID { event["requestId"] = requestID }
        return event
    }

    // MARK: - Replacement

    func testRefusedTextIsEvictedAndReplacedExactlyOnce() {
        var messages = [
            TranscriptEntry(kind: .user, text: "do the thing"),
            assistant("Here is how you would ", frame: "frame-1"),
        ]

        // The replacement arrives with the frame that supersedes the refused one.
        ClaudeSupersession.apply(event: [
            "type": "assistant_frame", "frameUUID": "frame-2", "supersedes": ["frame-1"],
        ], to: &messages)
        messages.append(assistant("I can't help with that, but here's what I can do.", frame: "frame-2"))
        ClaudeSupersession.apply(event: fallbackEvent(), to: &messages)

        let assistantTexts = messages.filter { $0.kind == .assistant }.map(\.text)
        XCTAssertEqual(assistantTexts, ["I can't help with that, but here's what I can do."])
        XCTAssertEqual(messages.filter { $0.refusal != nil }.count, 1)
    }

    func testARefusalBeforeAnyAssistantTextJustReportsItself() {
        var messages = [TranscriptEntry(kind: .user, text: "do the thing")]

        ClaudeSupersession.apply(event: fallbackEvent(retracting: []), to: &messages)

        XCTAssertEqual(messages.count, 2)
        XCTAssertEqual(messages.last?.kind, .system)
        XCTAssertEqual(messages.last?.refusal?.outcome, .fallback)
    }

    func testANoFallbackRefusalKeepsWhateverTextTheUserAlreadySaw() {
        // Nothing replaced it, so evicting it would leave a hole where the user watched text appear.
        var messages = [assistant("Partial answer", frame: "frame-1")]

        ClaudeSupersession.apply(event: [
            "type": "model_refusal", "outcome": "no_fallback",
            "originalModel": "claude-opus-5", "retractedMessageUUIDs": [], "frameUUID": "notice-1",
        ], to: &messages)

        XCTAssertEqual(messages.first?.text, "Partial answer")
        XCTAssertNil(messages.first?.supersededByFrameUUID)
        XCTAssertEqual(messages.last?.refusal?.outcome, .noFallback)
    }

    // MARK: - Audit evidence

    func testARetractedToolRowSurvivesAsAuditEvidence() {
        // The call may already have written a file or sent a request. Deleting the row would erase
        // evidence of something that actually happened on the user's Mac.
        var messages = [
            assistant("Let me run that", frame: "frame-1"),
            tool("Write", frame: "frame-1"),
        ]

        ClaudeSupersession.apply(
            event: fallbackEvent(retracting: ["frame-1"]), to: &messages)

        let toolRows = messages.filter { $0.kind == .tool }
        XCTAssertEqual(toolRows.count, 1, "the executed call must remain visible")
        XCTAssertEqual(toolRows.first?.supersededByFrameUUID, "notice-1")
        XCTAssertFalse(messages.contains { $0.kind == .assistant },
                       "the refused text has no such excuse")
    }

    // MARK: - Idempotence

    func testApplyingBothRetractionMechanismsLandsInTheSamePlace() {
        // `supersedes` arrives with the replacement; `retracted_message_uuids` arrives at end of turn
        // as the complete audit record. The SDK documents them as idempotent with each other.
        var viaBoth = [assistant("refused text", frame: "frame-1"), tool("Read", frame: "frame-1")]
        ClaudeSupersession.apply(event: [
            "type": "assistant_frame", "frameUUID": "frame-2", "supersedes": ["frame-1"],
        ], to: &viaBoth)
        ClaudeSupersession.apply(event: fallbackEvent(retracting: ["frame-1"]), to: &viaBoth)

        var viaNoticeOnly = [assistant("refused text", frame: "frame-1"), tool("Read", frame: "frame-1")]
        ClaudeSupersession.apply(
            event: fallbackEvent(retracting: ["frame-1"]), to: &viaNoticeOnly)

        XCTAssertEqual(viaBoth.count, viaNoticeOnly.count)
        XCTAssertEqual(viaBoth.map(\.kind), viaNoticeOnly.map(\.kind))
        XCTAssertEqual(viaBoth.filter { $0.refusal != nil }.count, 1)
    }

    func testLocalSupersessionLinksStayStableAcrossDuplicateAndReorderedEvents() throws {
        // Provider frame handles can themselves be UUID-shaped. Local links must still point to
        // record entries and locally minted events, never reinterpret a provider handle as one.
        let retractedFrame = "11111111-1111-4111-8111-111111111111"
        let replacementFrame = "22222222-2222-4222-8222-222222222222"
        let noticeFrame = "33333333-3333-4333-8333-333333333333"
        let rawProviderIDs = Set(try [retractedFrame, replacementFrame, noticeFrame].map {
            try XCTUnwrap(UUID(uuidString: $0))
        })
        let replacementID = try XCTUnwrap(
            UUID(uuidString: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"))
        let assistantEvent: [String: Any] = [
            "type": "assistant_frame",
            "frameUUID": replacementFrame,
            "supersedes": [retractedFrame],
        ]
        let noticeEvent = fallbackEvent(
            retracting: [retractedFrame],
            notice: noticeFrame)

        // Replacement-frame first: its actual transcript entry becomes the local replacement.
        var replacement = assistant("Safer replacement", frame: replacementFrame)
        replacement.id = replacementID
        var frameFirst = [tool("Write", frame: retractedFrame), replacement]
        XCTAssertTrue(ClaudeSupersession.apply(
            event: assistantEvent,
            to: &frameFirst,
            captureOrdinal: 51))
        let frameFirstToolID = try XCTUnwrap(
            frameFirst.first(where: { $0.kind == .tool })?.id)
        let frameFirstEventID = try XCTUnwrap(
            frameFirst.first(where: { $0.id == frameFirstToolID })?.supersessionEventID)
        XCTAssertEqual(
            frameFirst.first(where: { $0.id == frameFirstToolID })?.supersededByEntryID,
            replacementID)

        // Exercise a relaunch boundary before the alternate notice and duplicate callbacks replay.
        frameFirst = try ConversationStore.makeDecoder().decode(
            [TranscriptEntry].self,
            from: ConversationStore.makeEncoder().encode(frameFirst))
        XCTAssertTrue(ClaudeSupersession.apply(
            event: noticeEvent,
            to: &frameFirst,
            captureOrdinal: 52),
            "the first refusal notice adds its durable presentation row")
        XCTAssertFalse(ClaudeSupersession.apply(
            event: assistantEvent,
            to: &frameFirst,
            captureOrdinal: 53))
        XCTAssertFalse(ClaudeSupersession.apply(
            event: noticeEvent,
            to: &frameFirst,
            captureOrdinal: 54))
        let stableFrameFirst = try XCTUnwrap(
            frameFirst.first(where: { $0.id == frameFirstToolID }))
        XCTAssertEqual(stableFrameFirst.supersessionEventID, frameFirstEventID)
        XCTAssertEqual(stableFrameFirst.supersededByEntryID, replacementID)
        XCTAssertEqual(stableFrameFirst.supersessionCaptureOrdinal, 51)
        XCTAssertFalse(rawProviderIDs.contains(frameFirstEventID))
        XCTAssertFalse(rawProviderIDs.contains(replacementID))
        XCTAssertTrue(frameFirst.contains { $0.id == replacementID })
        XCTAssertEqual(frameFirst.filter { $0.refusal != nil }.count, 1)

        // Notice-first is the inverse legal order. Its notice row establishes the local edge; the
        // later replacement frame and duplicates may enrich raw correlation, but cannot rewrite it.
        var noticeFirst = [tool("Write", frame: retractedFrame)]
        XCTAssertTrue(ClaudeSupersession.apply(
            event: noticeEvent,
            to: &noticeFirst,
            captureOrdinal: 61))
        let noticeEntryID = try XCTUnwrap(noticeFirst.first { $0.refusal != nil }?.id)
        let noticeFirstToolID = try XCTUnwrap(
            noticeFirst.first(where: { $0.kind == .tool })?.id)
        let noticeFirstEventID = try XCTUnwrap(
            noticeFirst.first(where: { $0.id == noticeFirstToolID })?.supersessionEventID)
        noticeFirst.append(replacement)
        XCTAssertFalse(ClaudeSupersession.apply(
            event: assistantEvent,
            to: &noticeFirst,
            captureOrdinal: 62))
        XCTAssertFalse(ClaudeSupersession.apply(
            event: noticeEvent,
            to: &noticeFirst,
            captureOrdinal: 63))
        let stableNoticeFirst = try XCTUnwrap(
            noticeFirst.first(where: { $0.id == noticeFirstToolID }))
        XCTAssertEqual(stableNoticeFirst.supersessionEventID, noticeFirstEventID)
        XCTAssertEqual(stableNoticeFirst.supersededByEntryID, noticeEntryID)
        XCTAssertEqual(stableNoticeFirst.supersessionCaptureOrdinal, 61)
        XCTAssertFalse(rawProviderIDs.contains(noticeFirstEventID))
        XCTAssertFalse(rawProviderIDs.contains(noticeEntryID))
        XCTAssertTrue(noticeFirst.contains { $0.id == noticeEntryID })
        XCTAssertEqual(noticeFirst.filter { $0.refusal != nil }.count, 1)
    }

    func testReapplyingTheSameNoticeDoesNotStackCards() {
        // A relaunch replaying the tail must not produce two identical refusal rows.
        var messages = [assistant("refused", frame: "frame-1")]
        ClaudeSupersession.apply(event: fallbackEvent(), to: &messages)
        let afterFirst = messages.count

        ClaudeSupersession.apply(event: fallbackEvent(), to: &messages)

        XCTAssertEqual(messages.count, afterFirst)
        XCTAssertEqual(messages.filter { $0.refusal != nil }.count, 1)
    }

    func testAnUnknownRetractionIdIsANoOp() {
        var messages = [assistant("kept", frame: "frame-9")]

        ClaudeSupersession.apply(
            event: fallbackEvent(retracting: ["frame-does-not-exist"]), to: &messages)

        XCTAssertEqual(messages.first?.text, "kept")
        XCTAssertNil(messages.first?.supersededByFrameUUID)
    }

    func testOnlyTheNamedFrameIsRetractedWhenATurnHadSeveral() {
        var messages = [
            assistant("first frame", frame: "frame-1"),
            assistant("second frame", frame: "frame-2"),
            assistant("third frame", frame: "frame-3"),
        ]

        ClaudeSupersession.apply(
            event: fallbackEvent(retracting: ["frame-2"]), to: &messages)

        XCTAssertEqual(
            messages.filter { $0.kind == .assistant }.map(\.text),
            ["first frame", "third frame"])
    }

    // MARK: - Frame attribution

    func testACompletedFrameReattributesTheRowItsPartialsBuilt() {
        // The SDK does not guarantee a partial's uuid survives to completion. Without the daemon's
        // provisional pairing, this row would carry an id no retraction could ever name.
        var messages = [assistant("streamed text", frame: "partial-1")]

        ClaudeSupersession.apply(event: [
            "type": "assistant_frame", "frameUUID": "frame-1", "provisionalFrameUUID": "partial-1",
        ], to: &messages)

        XCTAssertEqual(messages.first?.providerFrameUUID, "frame-1")

        ClaudeSupersession.apply(
            event: fallbackEvent(retracting: ["frame-1"]), to: &messages)
        XCTAssertFalse(messages.contains { $0.kind == .assistant })
    }

    func testACompletedFrameWithNoTextDoesNotStealThePreviousFramesRow() {
        // The bug that guessing "the last assistant row" would cause: a tool-only frame completing
        // right after a text frame would silently re-label the text frame's row, and a later
        // retraction would then delete the wrong thing.
        var messages = [assistant("frame one text", frame: "frame-1")]

        ClaudeSupersession.apply(event: [
            "type": "assistant_frame", "frameUUID": "frame-2",
        ], to: &messages)

        XCTAssertEqual(messages.first?.providerFrameUUID, "frame-1")
    }

    func testAnUnattributedTrailingRowAdoptsTheCompletedFrame() {
        var messages = [assistant("streamed text", frame: nil)]

        ClaudeSupersession.apply(event: [
            "type": "assistant_frame", "frameUUID": "frame-1",
        ], to: &messages)

        XCTAssertEqual(messages.first?.providerFrameUUID, "frame-1")
    }

    // MARK: - Refused content must not leave the app

    func testRetractedRowsAreExcludedFromExportedMarkdown() {
        var messages = [
            TranscriptEntry(kind: .user, text: "ask"),
            assistant("refused text", frame: "frame-1"),
            tool("Write", frame: "frame-1"),
        ]
        ClaudeSupersession.apply(
            event: fallbackEvent(retracting: ["frame-1"]), to: &messages)
        messages.append(assistant("replacement", frame: "frame-2"))

        let markdown = AgentBridge.transcriptMarkdown(messages)

        XCTAssertFalse(markdown.contains("refused text"))
        XCTAssertTrue(markdown.contains("replacement"))
        // The superseded tool row is audit evidence inside the app, not part of an export.
        XCTAssertFalse(markdown.contains("Write"))
    }

    // MARK: - Effective session model

    func testAPersistentFallbackNamesTheModelNowAnswering() {
        let record = ClaudeRefusalRecord(event: fallbackEvent(persistent: true))
        XCTAssertEqual(record?.persistentFallbackModel, "claude-opus-4-8")
    }

    func testAOneShotFallbackChangesNothingDurable() {
        // A retry that does not outlive the turn says nothing about the next one.
        let record = ClaudeRefusalRecord(event: fallbackEvent(persistent: false))
        XCTAssertNil(record?.persistentFallbackModel)
    }

    func testANoFallbackRefusalNeverNamesAnEffectiveModel() {
        let record = ClaudeRefusalRecord(event: [
            "type": "model_refusal", "outcome": "no_fallback", "originalModel": "claude-opus-5",
        ])
        XCTAssertNil(record?.persistentFallbackModel)
    }

    func testTheProvidersExplanationIsShownOnTheRow() {
        // Displayed, never parsed: the user is entitled to know why they were declined, and the app
        // is entitled to no opinion about the wording.
        var messages: [TranscriptEntry] = []
        ClaudeSupersession.apply(event: fallbackEvent(retracting: []), to: &messages)

        let row = try? XCTUnwrap(messages.last)
        XCTAssertEqual(row?.refusal?.explanation, "Asked for exploit code.")
        XCTAssertTrue(row?.text.contains("Asked for exploit code.") ?? false)
        XCTAssertTrue(row?.text.contains("claude-opus-4-8 answered instead.") ?? false)
    }

    func testTheHeadlineNamesBothModels() {
        // "The model declined" without saying which model is not attribution — the user chose a
        // specific model and is entitled to know what actually answered.
        let record = ClaudeRefusalRecord(event: fallbackEvent())
        XCTAssertEqual(
            record?.headline,
            "claude-opus-5 declined this request. claude-opus-4-8 answered instead.")
    }

    // MARK: - Ownership (plan case 15)

    func testInteractionRowsAreNotCollateralDamageOfARetraction() {
        // Permission, question and guidance rows belong to the TURN, not to a provider frame. A
        // refusal retracts model output; it must not quietly delete the record of a permission the
        // user granted or a question they answered inside the same turn.
        var permission = TranscriptEntry(kind: .permission, text: "Allow Write?")
        permission.permissionId = "perm-1"
        permission.permDecided = true
        permission.permAllowed = true
        var question = TranscriptEntry(kind: .question, text: "Which target?")
        question.questionId = "q-1"
        var guidance = TranscriptEntry(kind: .user, text: "actually, use the other file")
        guidance.guidanceState = .delivered

        var messages = [
            assistant("refused text", frame: "frame-1"),
            permission, question, guidance,
        ]

        ClaudeSupersession.apply(
            event: fallbackEvent(retracting: ["frame-1"]), to: &messages)

        XCTAssertEqual(messages.filter { $0.kind == .permission }.count, 1)
        XCTAssertEqual(messages.filter { $0.kind == .question }.count, 1)
        XCTAssertEqual(messages.first(where: { $0.guidanceState != nil })?.text,
                       "actually, use the other file")
        XCTAssertFalse(messages.contains { $0.kind == .assistant })
    }

    // MARK: - Late and misrouted events (plan cases 11 and 16)

    @MainActor
    func testSupersessionEventsAreTurnScoped() {
        // The invariant, asserted rather than assumed: anything that can mutate a conversation's
        // transcript must be turn-scoped, or `handle` will apply it to whichever conversation is on
        // screen. That is how a refusal arriving after its turn ended — or belonging to a background
        // turn whose route was already released — would land in the wrong conversation. It is also
        // what makes a Stop mid-retry safe: the route stops being active, so the late notice fails
        // closed through the same gate.
        let turnScopedEventTypes = AgentBridge.turnScopedEventTypes
        for eventType in ["assistant_frame", "model_refusal"] {
            XCTAssertTrue(turnScopedEventTypes.contains(eventType), eventType)
        }
        // Guard the general rule too, so a future transcript-mutating event is not added without it.
        for eventType in ["delta", "tool_use", "tool_result", "done", "error"] {
            XCTAssertTrue(turnScopedEventTypes.contains(eventType), eventType)
        }
    }

    // MARK: - Foreground and background agree (plan case 12)

    func testBackgroundStreamingClosesRowsOnCompletedFrames() {
        // Partial UUIDs identify events, so explicit open-row state coalesces them. The completed
        // frame re-attributes and closes that row before a later provider message starts.
        var messages: [TranscriptEntry] = []
        var openEntryID = AgentBridge.appendBackgroundAssistantText(
            &messages, "first ", frameUUID: "partial-1", openEntryID: nil)
        openEntryID = AgentBridge.appendBackgroundAssistantText(
            &messages, "frame", frameUUID: "partial-2", openEntryID: openEntryID)
        ClaudeSupersession.apply(event: [
            "type": "assistant_frame",
            "frameUUID": "frame-1",
            "provisionalFrameUUID": "partial-1",
        ], to: &messages)
        openEntryID = nil
        openEntryID = AgentBridge.appendBackgroundAssistantText(
            &messages, "second frame", frameUUID: "partial-3", openEntryID: openEntryID)

        XCTAssertEqual(messages.map(\.text), ["first frame", "second frame"])
        XCTAssertEqual(messages.map(\.providerFrameUUID), ["frame-1", "partial-3"])
        XCTAssertEqual(openEntryID, messages.last?.id)

        ClaudeSupersession.apply(
            event: fallbackEvent(retracting: ["frame-1"]), to: &messages)
        XCTAssertEqual(messages.filter { $0.kind == .assistant }.map(\.text), ["second frame"])
    }

    // MARK: - Conversations that switch between Claude and Codex

    func testCodexTextStillCoalescesBecauseItCarriesNoFrame() {
        // Only the Claude lane emits `frameUUID`. Every other provider's deltas carry none, so both
        // sides are nil and the pre-1B coalescing behavior is exactly preserved.
        var messages: [TranscriptEntry] = []
        var openEntryID = AgentBridge.appendBackgroundAssistantText(
            &messages, "Codex ", openEntryID: nil)
        openEntryID = AgentBridge.appendBackgroundAssistantText(
            &messages, "answer", openEntryID: openEntryID)

        XCTAssertEqual(messages.map(\.text), ["Codex answer"])
        XCTAssertNil(messages.first?.providerFrameUUID)
        XCTAssertEqual(openEntryID, messages.first?.id)
    }

    func testSwitchingProviderMidConversationStartsAFreshRow() {
        // A Claude row carries a frame; the Codex text that follows carries none. They must not be
        // merged into one bubble attributed to a frame that did not produce it.
        var messages = [assistant("Claude said this", frame: "frame-1")]
        AgentBridge.appendBackgroundAssistantText(
            &messages, "Codex said this", openEntryID: nil)

        XCTAssertEqual(messages.map(\.text), ["Claude said this", "Codex said this"])
        XCTAssertNil(messages.last?.providerFrameUUID)
    }

    func testARefusalNeverRetractsAnotherProvidersRows() {
        // The load-bearing cross-provider case. Retraction is keyed on provider frame ids, and a
        // Codex row has none, so it cannot be named by a Claude retraction even accidentally.
        var messages = [
            assistant("Claude refused text", frame: "frame-1"),
            TranscriptEntry(kind: .user, text: "switch to codex"),
        ]
        AgentBridge.appendBackgroundAssistantText(
            &messages, "Codex answer", openEntryID: nil)

        ClaudeSupersession.apply(
            event: fallbackEvent(retracting: ["frame-1"]), to: &messages)

        XCTAssertTrue(messages.contains { $0.text == "Codex answer" })
        XCTAssertFalse(messages.contains { $0.text == "Claude refused text" })
        XCTAssertTrue(AgentBridge.transcriptMarkdown(messages).contains("Codex answer"))
    }

    // MARK: - Persistence tolerance

    func testAnUnknownFutureOutcomeCostsOneRowNotTheConversation() throws {
        // Same family as the 0.11.7 quarantine bug: an unknown enum value in a persisted struct is a
        // decode failure that propagates all the way up to the conversation.
        let json = Data("""
        {"outcome":"some_future_outcome","originalModel":"claude-opus-5","persistent":true}
        """.utf8)

        let record = try JSONDecoder().decode(ClaudeRefusalRecord.self, from: json)

        XCTAssertEqual(record.outcome, .unknown)
        XCTAssertEqual(record.originalModel, "claude-opus-5")
    }

    func testARefusalRowRoundTripsThroughAConversationSidecar() throws {
        var messages = [assistant("refused", frame: "frame-1")]
        ClaudeSupersession.apply(event: fallbackEvent(), to: &messages)
        let conversation = Conversation(
            title: "t", cwd: "/tmp", sdkSessionId: nil, messages: messages, updatedAt: Date())

        let data = try JSONEncoder().encode(conversation)
        let restored = try JSONDecoder().decode(Conversation.self, from: data)

        XCTAssertEqual(restored.messages.last?.refusal?.fallbackModel, "claude-opus-4-8")
        XCTAssertEqual(restored.messages.last?.refusal?.category, "cyber")
    }

    func testAConversationWrittenBeforeTheseFieldsStillDecodes() throws {
        // The whole reason every new field here is Optional.
        let json = Data("""
        {"id":"\(UUID().uuidString)","title":"old","cwd":"/tmp",
         "messages":[{"id":"\(UUID().uuidString)","kind":"assistant","text":"hi","toolIsError":false,
                      "permDecided":false,"permAllowed":false}],
         "updatedAt":0}
        """.utf8)

        let restored = try JSONDecoder().decode(Conversation.self, from: json)

        XCTAssertEqual(restored.messages.count, 1)
        XCTAssertNil(restored.messages.first?.providerFrameUUID)
        XCTAssertNil(restored.claudeEffectiveModel)
    }
}
