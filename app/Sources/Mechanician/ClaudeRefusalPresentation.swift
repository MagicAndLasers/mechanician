import Foundation

/// What the provider told us about one safety refusal, kept durably on the transcript row that
/// reports it. This is presentation evidence, not policy input: `category` and `explanation` are
/// provider prose on an open vocabulary, displayed and never branched on.
struct ClaudeRefusalRecord: Codable, Equatable {
    /// Whether a retry actually ran. Decoded tolerantly on purpose — a future build shipping a third
    /// outcome must cost this one row's precision, not the whole conversation. (Same family as the
    /// 0.11.7 quarantine bug: an unknown enum value in a persisted struct is a decode failure that
    /// propagates all the way up.)
    enum Outcome: String, Codable {
        case fallback
        case noFallback
        /// An outcome this build does not know. Renders as a plain refusal.
        case unknown

        init(from decoder: Decoder) throws {
            let raw = try decoder.singleValueContainer().decode(String.self)
            self = Outcome(rawValue: raw) ?? .unknown
        }
    }

    var outcome: Outcome
    /// The model that refused — the one the user asked for.
    var originalModel: String?
    /// The model that answered instead. Nil when no retry ran.
    var fallbackModel: String?
    var category: String?
    /// Unstable provider prose. Display only.
    var explanation: String?
    var requestID: String?
    /// Whether the swap outlives this turn. See `fallbackIsPersistent` in the daemon: upstream emits
    /// only `retry`, which is documented as persistent for the session.
    var persistent: Bool = false

    enum CodingKeys: String, CodingKey {
        case outcome, originalModel, fallbackModel, category, explanation, requestID, persistent
    }

    /// Every field defaulted so a row written by a newer build still decodes here, and a row written
    /// before any given field existed still decodes at all.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        outcome = ((try? c.decodeIfPresent(Outcome.self, forKey: .outcome)) ?? nil) ?? .unknown
        originalModel = try? c.decodeIfPresent(String.self, forKey: .originalModel)
        fallbackModel = try? c.decodeIfPresent(String.self, forKey: .fallbackModel)
        category = try? c.decodeIfPresent(String.self, forKey: .category)
        explanation = try? c.decodeIfPresent(String.self, forKey: .explanation)
        requestID = try? c.decodeIfPresent(String.self, forKey: .requestID)
        persistent = ((try? c.decodeIfPresent(Bool.self, forKey: .persistent)) ?? nil) ?? false
    }

    init(
        outcome: Outcome,
        originalModel: String? = nil,
        fallbackModel: String? = nil,
        category: String? = nil,
        explanation: String? = nil,
        requestID: String? = nil,
        persistent: Bool = false
    ) {
        self.outcome = outcome
        self.originalModel = originalModel
        self.fallbackModel = fallbackModel
        self.category = category
        self.explanation = explanation
        self.requestID = requestID
        self.persistent = persistent
    }

    /// Build from the daemon's `model_refusal` event. Returns nil for anything that is not one.
    init?(event: [String: Any]) {
        guard event["type"] as? String == "model_refusal" else { return nil }
        let outcomeRaw = event["outcome"] as? String
        outcome = outcomeRaw == "fallback" ? .fallback
            : outcomeRaw == "no_fallback" ? .noFallback : .unknown
        originalModel = event["originalModel"] as? String
        fallbackModel = event["fallbackModel"] as? String
        category = event["category"] as? String
        explanation = event["explanation"] as? String
        requestID = event["requestId"] as? String
        persistent = event["persistent"] as? Bool ?? false
    }

    /// The model that should be shown as actually answering for the rest of this session, or nil if
    /// nothing durable changed. Only a persistent fallback qualifies: a one-shot retry says nothing
    /// about the next turn, and claiming otherwise would misreport the session.
    var persistentFallbackModel: String? {
        guard outcome == .fallback, persistent else { return nil }
        return fallbackModel.flatMap { $0.isEmpty ? nil : $0 }
    }

    /// What the transcript row says. The provider's explanation is shown verbatim beneath the
    /// attribution — the user is entitled to know why their request was declined — but it is only
    /// ever rendered. Nothing in the app branches on it; see `explanation`.
    var displayText: String {
        guard let explanation, !explanation.isEmpty else { return headline }
        return "\(headline)\n\n\(explanation)"
    }

    /// One sentence naming both models, because "the model declined" without saying which model is
    /// not attribution — the user picked a specific model and is entitled to know what answered.
    var headline: String {
        switch outcome {
        case .fallback:
            let original = originalModel ?? "The selected model"
            let fallback = fallbackModel ?? "another model"
            return "\(original) declined this request. \(fallback) answered instead."
        case .noFallback, .unknown:
            let original = originalModel ?? "The selected model"
            return "\(original) declined this request."
        }
    }
}

/// The canonical-replacement reducer.
///
/// Upstream describes a retraction twice on purpose: `SDKAssistantMessage.supersedes` arrives WITH
/// the replacement text, and `model_refusal_fallback.retracted_message_uuids` arrives at end of turn
/// as the complete audit record. The SDK documents them as idempotent with each other, so this must
/// be safe to apply repeatedly, in either order, with overlapping or unknown ids.
enum ClaudeSupersession {
    /// Retract everything named, and return whether anything changed.
    ///
    /// The two row kinds are treated differently, and the difference is the whole point:
    ///
    /// - **Assistant text is evicted.** The user must never be able to export, replay or scroll back
    ///   to text the provider retracted. There is a replacement for it, so removing it leaves no gap.
    /// - **Tool rows are kept and marked.** A tool call in the refused leg may have already RUN — it
    ///   may have written a file or sent a request. Deleting that row would erase evidence of
    ///   something that actually happened to the user's machine. It stays, visibly superseded, and is
    ///   excluded from provider history so the model is not re-told about it.
    @discardableResult
    static func retract(
        _ uuids: [String],
        replacedBy replacement: String?,
        replacementEntryID: UUID? = nil,
        captureOrdinal: UInt64? = nil,
        in messages: inout [TranscriptEntry]
    ) -> Bool {
        let targets = Set(uuids.filter { !$0.isEmpty })
        guard !targets.isEmpty else { return false }
        var changed = false

        // Mark first, then evict, so indices stay valid and the operation reads as one step.
        for index in messages.indices {
            guard let frame = messages[index].providerFrameUUID, targets.contains(frame) else {
                continue
            }
            if messages[index].supersededByFrameUUID == nil {
                messages[index].supersededByFrameUUID = replacement ?? frame
                changed = true
            }
            // Enrich an earlier raw-frame retraction when the later audit notice finally supplies a
            // retained local replacement. Never replace an already-established local edge.
            if messages[index].supersessionEventID == nil {
                messages[index].supersessionEventID = UUID()
                changed = true
            }
            if messages[index].supersededByEntryID == nil,
               replacementEntryID != messages[index].id {
                messages[index].supersededByEntryID = replacementEntryID
                changed = replacementEntryID != nil || changed
            }
            if messages[index].supersessionCaptureOrdinal == nil,
               let captureOrdinal {
                messages[index].supersessionCaptureOrdinal = captureOrdinal
                changed = true
            }
        }

        let survivors = messages.filter { entry in
            guard entry.supersededByFrameUUID != nil,
                  let frame = entry.providerFrameUUID,
                  targets.contains(frame) else { return true }
            // Keep anything that is evidence of work that may have executed.
            return entry.kind != .assistant
        }
        if survivors.count != messages.count {
            messages = survivors
            changed = true
        }
        return changed
    }

    /// The single entry point for both the foreground and the background event path.
    ///
    /// There is deliberately one reducer rather than two similar ones: a refusal is rare, hard to
    /// reproduce, and impossible to exercise with a live model, so two implementations would mean
    /// one of them is permanently unverified. Returns whether anything changed.
    @discardableResult
    static func apply(
        event: [String: Any],
        to messages: inout [TranscriptEntry],
        captureOrdinal: UInt64? = nil
    ) -> Bool {
        switch event["type"] as? String {
        case "assistant_frame":
            guard let frameUUID = event["frameUUID"] as? String, !frameUUID.isEmpty else {
                return false
            }
            attribute(
                completedFrame: frameUUID,
                replacingProvisional: event["provisionalFrameUUID"] as? String,
                in: &messages)
            let replacementEntryID = messages.last {
                $0.providerFrameUUID == frameUUID && $0.supersededByFrameUUID == nil
            }?.id
            // `supersedes` arrives WITH the replacement text, so the swap can happen the moment a
            // replacement exists rather than at end of turn.
            return retract(
                event["supersedes"] as? [String] ?? [],
                replacedBy: frameUUID,
                replacementEntryID: replacementEntryID,
                captureOrdinal: captureOrdinal,
                in: &messages)

        case "model_refusal":
            guard let record = ClaudeRefusalRecord(event: event) else { return false }
            let noticeUUID = event["frameUUID"] as? String
            // One notice per refusal. Both mechanisms can describe the same event, and a relaunch
            // replaying the tail must not stack duplicate cards.
            let existingNotice = messages.first { entry in
                entry.refusal != nil
                    && (noticeUUID == nil || entry.providerFrameUUID == noticeUUID)
                    && entry.refusal?.requestID == record.requestID
            }
            var notice = existingNotice
            if notice == nil {
                var entry = TranscriptEntry(kind: .system, text: record.displayText)
                entry.refusal = record
                entry.providerFrameUUID = noticeUUID
                entry.captureOrdinal = captureOrdinal
                notice = entry
            }
            // The end-of-turn audit record. Idempotent with any `supersedes` already applied, and
            // able to enrich an earlier raw-only edge with this notice's durable local identity.
            var changed = retract(
                event["retractedMessageUUIDs"] as? [String] ?? [],
                replacedBy: noticeUUID,
                replacementEntryID: notice?.id,
                captureOrdinal: captureOrdinal,
                in: &messages)
            if existingNotice == nil, let notice {
                messages.append(notice)
                changed = true
            }
            return changed

        default:
            return false
        }
    }

    /// Attribute a completed provider frame to the row its deltas built.
    ///
    /// The SDK does not guarantee that a partial's uuid survives to completion, so a row built from
    /// deltas may carry an id that no retraction will ever name. The daemon knows which provisional
    /// id preceded each completed frame and sends it, so the correlation is exact — the app must not
    /// guess by re-stamping "the last assistant row", which silently mis-attributes whenever a
    /// completed frame produced no text of its own (a tool-only frame right after a text frame).
    ///
    /// With no provisional id, only an unattributed trailing assistant row is adopted.
    static func attribute(
        completedFrame frameUUID: String,
        replacingProvisional provisional: String?,
        in messages: inout [TranscriptEntry]
    ) {
        guard !frameUUID.isEmpty else { return }

        if let provisional, !provisional.isEmpty, provisional != frameUUID {
            for index in messages.indices
            where messages[index].providerFrameUUID == provisional
                && messages[index].supersededByFrameUUID == nil {
                messages[index].providerFrameUUID = frameUUID
            }
            return
        }

        guard let last = messages.indices.last,
              messages[last].kind == .assistant,
              messages[last].providerFrameUUID == nil else { return }
        messages[last].providerFrameUUID = frameUUID
    }
}
