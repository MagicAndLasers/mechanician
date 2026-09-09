import Foundation

/// Provider-neutral activity retained for the Agents timeline. Records are deliberately small and
/// bounded: they describe when an agent changed execution state, used tokens, compacted context,
/// invoked a tool, or received user guidance. Provider-specific fields remain optional so an absent
/// metric is never rendered as a measured zero.
enum AgentActivityKind: String, Codable {
    case state
    case identity
    case tokens
    case context
    case tool
    case compaction
    case interjection
}

enum AgentActivityPhase: String, Codable {
    case model
    case tool
    case waiting
    case compacting
    case completed
    case failed
    case stopped

    var isTerminal: Bool {
        self == .completed || self == .failed || self == .stopped
    }
}

enum AgentInterjectionDisposition: String, Codable {
    case delivered
    case queued
}

/// Maintenance events that extend the established `.context` activity kind.
///
/// Keeping the wire kind as `context` is deliberate downgrade behavior: builds predating this
/// optional discriminator decode the record as an ordinary context sample with no token value and
/// do not draw it. A new raw `AgentActivityKind` would instead make those builds reject the whole
/// persisted activity ledger, while reusing `.compaction` or `.interjection` would mislabel it.
enum AgentContextEventKind: String, Codable {
    case historyReduction
    /// Something Mechanician took away from what the provider offered: a tool refused with no
    /// prompt, a server dropped, a skill hidden. It shares `.context` for the same downgrade reason
    /// as `historyReduction` above, and because it is the same category of fact: a thing the app
    /// did to the turn rather than a thing the model did.
    case subtraction
}

/// Allowlisted recovery causes. Raw provider or prompt text never belongs in activity persistence.
enum AgentHistoryReductionReason: String, Codable {
    case contextCompactionFailed = "context_compaction_failed"
    case providerSessionExpired = "provider_session_expired"
    case durableHistoryReplay = "durable_history_replay"
    case freshSessionReplay = "fresh_session_replay"
    case contextPreflightUnavailable = "context_preflight_unavailable"
    case preflightContextLimit = "preflight_context_limit"
    case providerNoOutput = "provider_no_output"
}

/// Why something was withheld. Mirrors SUBTRACTION_REASONS in agentd/src/agentd.mjs; a daemon
/// reason with no case here decodes as nil and the marker still draws, so a newer daemon degrades to
/// "withheld, cause unknown" rather than losing the event. `SubtractionVocabularyTests` asserts the
/// two lists stay in step, because a rename on either side is silent at runtime.
enum AgentSubtractionReason: String, Codable {
    case planModeReadonly = "plan_mode_readonly"
    case unattendedWithheld = "unattended_withheld"
    case unattendedDenied = "unattended_denied"
    case credentialsUnavailable = "credentials_unavailable"
    case networkUnreachable = "network_unreachable"
    case providerUnsupported = "provider_unsupported"
    case hostAppRequired = "host_app_required"
    case managedProfileUndeclared = "managed_profile_undeclared"
    case adapterUnimplemented = "adapter_unimplemented"
    case contextBudget = "context_budget"
    case malformedConfiguration = "malformed_configuration"
    case nameCollision = "name_collision"
    case displayBound = "display_bound"
    case credentialBoundary = "credential_boundary"

    /// The clause that follows "withheld" in a marker title. Deliberately plain, and deliberately
    /// not the daemon's sentence: this is the countable axis rendered, not prose.
    var label: String {
        switch self {
        case .planModeReadonly: return "Plan mode is read-only"
        case .unattendedWithheld: return "needs a person"
        case .unattendedDenied: return "not allowed for a scheduled run"
        case .credentialsUnavailable: return "credentials unavailable"
        case .networkUnreachable: return "not reachable"
        case .providerUnsupported: return "unsupported by this provider"
        case .hostAppRequired: return "needs the Mechanician app"
        case .managedProfileUndeclared: return "not offered by your organization"
        case .adapterUnimplemented: return "not implemented on this lane"
        case .contextBudget: return "too large for this conversation"
        case .malformedConfiguration: return "misconfigured"
        case .nameCollision: return "name already in use"
        case .displayBound: return "too large to display"
        case .credentialBoundary: return "reads a credential store"
        }
    }
}

/// What was taken away. Separate from the reason so a marker can answer both questions.
enum AgentSubtractionSubject: String, Codable {
    case tool, server, skill, model, effort, capability, plugin, request, output

    var singular: String {
        switch self {
        case .tool: return "tool"
        case .server: return "server"
        case .skill: return "skill"
        case .model: return "model"
        case .effort: return "effort level"
        case .capability: return "capability"
        case .plugin: return "plugin"
        case .request: return "request"
        case .output: return "output"
        }
    }

    var plural: String { self == .capability ? "capabilities" : "\(singular)s" }
}

/// User-authored events share the legacy `.interjection` activity kind for downgrade-safe
/// persistence. Older builds ignore this optional field and still render a generic user marker
/// instead of rejecting the conversation sidecar because it contains a new activity-kind value.
enum AgentUserEventKind: String, Codable {
    case initialPrompt
    case guidance
}

struct AgentActivityRecord: Identifiable, Codable, Equatable {
    var id = UUID()
    var at = Date()
    /// Record-local capture order; absent on legacy rows rather than inferred from `at`.
    var captureOrdinal: UInt64? = nil
    var turnID: String?
    /// Route ownership is stamped when the event enters AgentBridge. A conversation can switch
    /// providers between turns, and a child may finish after a later turn has already selected a
    /// different provider, so neither value can be inferred safely from the current conversation.
    var providerAccess: ModelAccess?
    var modelID: String?
    /// Stable view identity. Root is literal `root`; delegated identities are created through
    /// `AgentActivityIdentity` so provider ids cannot collide with one another.
    var agentID: String = AgentActivityIdentity.root
    var agentLabel: String?
    var kind: AgentActivityKind
    var phase: AgentActivityPhase?
    var detail: String?
    /// An authoritative provider retask starts a new execution lifecycle for this agent identity
    /// inside the same Mechanician turn. Ordinary progress after a terminal boundary leaves this
    /// absent, so buffered transport events cannot resurrect a completed lane.
    ///
    /// Optional is deliberate persistence compatibility: activity rows written before lifecycle
    /// generations existed decode as the original single generation.
    var startsNewLifecycleGeneration: Bool? = nil

    /// Provider-harness observability refines the established activity kinds rather than adding
    /// new persisted kind cases. The stable lane names the harness family (`claude`, `codex`),
    /// while `agentID` continues to distinguish root and delegated work inside that harness.
    var harnessLaneID: AgentHarnessLaneID? = nil
    var harnessPhase: AgentHarnessPhase? = nil
    var harnessEventKind: AgentHarnessEventKind? = nil
    var measurementProvenance: AgentMeasurementProvenance? = nil
    var measurementScope: AgentMeasurementScope? = nil
    var measurementAggregation: AgentMeasurementAggregation? = nil
    /// Positive sequence of one provider query inside a Mechanician turn. Recovery can issue more
    /// than one billable query; finals reconcile only the streamed samples from their own sequence.
    var providerQuerySequence: Int? = nil

    /// Timing samples retain their exact boundary instead of collapsing TTFT, first visible output,
    /// provider API time, and whole-turn wall time into one number.
    var elapsedMs: Int? = nil
    var durationMs: Int? = nil
    var apiDurationMs: Int? = nil
    var timeToFirstTokenMs: Int? = nil
    var timeToFirstOutputMs: Int? = nil
    var streamTimeToFirstOutputMs: Int? = nil
    var timeToRequestMs: Int? = nil
    var timeToRequestFromSpawnMs: Int? = nil
    var warm: Bool? = nil
    var threadAction: AgentHarnessThreadAction? = nil
    var outputKind: AgentHarnessOutputKind? = nil
    var terminalOutcome: AgentHarnessTerminalOutcome? = nil

    /// Per-event token amounts. Input includes cached input when the provider reports it; cachedInput
    /// is the subset that can be drawn separately. `totalTokens` is used only by providers that do
    /// not disclose an input/output breakdown.
    var inputTokens: Int?
    /// Explicit provider components. Zero is meaningful when the provider reported it; nil means
    /// the component was not reported. Cached input remains the cache-read subset of `inputTokens`.
    var uncachedInputTokens: Int? = nil
    var cachedInputTokens: Int?
    var cacheWriteInputTokens: Int? = nil
    var outputTokens: Int?
    var reasoningOutputTokens: Int?
    var totalTokens: Int?

    /// Latest context-window snapshot, distinct from billed/processed token amounts.
    var contextTokens: Int?
    var contextWindow: Int?
    var contextUsableWindowTokens: Int? = nil
    var contextRawWindowTokens: Int? = nil
    var contextComposition: AgentContextComposition? = nil

    /// A fresh bounded provider session may retain only a suffix of the durable transcript. Counts
    /// describe that provider-visible reduction without retaining any omitted message content.
    var contextEventKind: AgentContextEventKind?
    var historyOmittedMessages: Int?
    var historyShortenedMessages: Int?
    var historyReductionReason: AgentHistoryReductionReason?

    /// What Mechanician withheld from this turn, and why. Identifiers and a count only: these rows
    /// persist, so provider prose and file paths must never reach them.
    var subtractionSubject: AgentSubtractionSubject?
    var subtractionReason: AgentSubtractionReason?
    var subtractionNames: [String]?
    var subtractionCount: Int?

    /// Compaction metadata. Codex currently reports the boundary without before/after counts; nil
    /// stays visibly "not reported" instead of becoming a fictional zero-token compaction.
    var compactionTrigger: String?
    var compactionPreTokens: Int?
    var compactionPostTokens: Int?
    var compactionError: String?
    var compactionDurationMs: Int? = nil
    var compactionSequence: Int? = nil

    /// Retry, reroute, and safety facts are bounded, content-free metadata. Provider error prose,
    /// prompts, reasoning text, and safety explanations never belong in this persisted record.
    var retryDisposition: AgentRetryDisposition? = nil
    var retryAttempt: Int? = nil
    var retryAttempts: Int? = nil
    var retryMaxAttempts: Int? = nil
    var retryDelayMs: Int? = nil
    var retryWillContinue: Bool? = nil
    var errorKind: String? = nil
    var httpStatusCode: Int? = nil
    var rerouteOriginalModelID: String? = nil
    var rerouteModelID: String? = nil
    var rerouteReason: String? = nil
    var safetyOutcome: AgentSafetyOutcome? = nil
    var safetyReasons: [String]? = nil
    var safetyUseCases: [String]? = nil
    var modelVerifications: [String]? = nil
    var safetyFasterModelID: String? = nil
    var safetyShowsBufferingUI: Bool? = nil

    var interjectionDisposition: AgentInterjectionDisposition?
    var userEventKind: AgentUserEventKind?

    /// What a tool call acted on — the file it read, the command it ran. "Read" tells you the shape
    /// of the work; "Read AgentBridge.swift" tells you the work. Optional because not every tool has
    /// a meaningful single target, and no provider is required to disclose its input.
    var toolTarget: String?
    var toolUseID: String? = nil
    var toolKind: AgentHarnessToolKind? = nil
    var toolOutcome: AgentHarnessToolOutcome? = nil
    var toolDurationMs: Int? = nil
    var toolWaitDurationMs: Int? = nil
    var toolExecutionDurationMs: Int? = nil
}

/// Explicit tolerant decode keeps one future activity-field addition from quarantining an entire
/// conversation sidecar. This follows the same persistence rule as SubagentRun and WorkflowAgent.
extension AgentActivityRecord {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func tolerant<T: Decodable>(_ type: T.Type, _ key: CodingKeys) -> T? {
            (try? c.decodeIfPresent(type, forKey: key)) ?? nil
        }
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        at = try c.decodeIfPresent(Date.self, forKey: .at) ?? Date()
        captureOrdinal = (try? c.decodeIfPresent(UInt64.self, forKey: .captureOrdinal)) ?? nil
        turnID = try c.decodeIfPresent(String.self, forKey: .turnID)
        providerAccess = try c.decodeIfPresent(ModelAccess.self, forKey: .providerAccess)
        modelID = try c.decodeIfPresent(String.self, forKey: .modelID)
        agentID = try c.decodeIfPresent(String.self, forKey: .agentID)
            ?? AgentActivityIdentity.root
        agentLabel = try c.decodeIfPresent(String.self, forKey: .agentLabel)
        kind = try c.decodeIfPresent(AgentActivityKind.self, forKey: .kind) ?? .state
        phase = try c.decodeIfPresent(AgentActivityPhase.self, forKey: .phase)
        detail = try c.decodeIfPresent(String.self, forKey: .detail)
        startsNewLifecycleGeneration = tolerant(Bool.self, .startsNewLifecycleGeneration) == true
            ? true : nil
        harnessLaneID = tolerant(AgentHarnessLaneID.self, .harnessLaneID)
        harnessPhase = tolerant(AgentHarnessPhase.self, .harnessPhase)
        harnessEventKind = tolerant(AgentHarnessEventKind.self, .harnessEventKind)
        measurementProvenance = tolerant(
            AgentMeasurementProvenance.self, .measurementProvenance)
        measurementScope = tolerant(AgentMeasurementScope.self, .measurementScope)
        measurementAggregation = tolerant(
            AgentMeasurementAggregation.self, .measurementAggregation)
        providerQuerySequence = agentHarnessBoundedCount(
            tolerant(Int.self, .providerQuerySequence)).flatMap { $0 > 0 ? $0 : nil }
        elapsedMs = agentHarnessDuration(tolerant(Int.self, .elapsedMs))
        durationMs = agentHarnessDuration(tolerant(Int.self, .durationMs))
        apiDurationMs = agentHarnessDuration(tolerant(Int.self, .apiDurationMs))
        timeToFirstTokenMs = agentHarnessDuration(tolerant(Int.self, .timeToFirstTokenMs))
        timeToFirstOutputMs = agentHarnessDuration(tolerant(Int.self, .timeToFirstOutputMs))
        streamTimeToFirstOutputMs = agentHarnessDuration(
            tolerant(Int.self, .streamTimeToFirstOutputMs))
        timeToRequestMs = agentHarnessDuration(tolerant(Int.self, .timeToRequestMs))
        timeToRequestFromSpawnMs = agentHarnessDuration(
            tolerant(Int.self, .timeToRequestFromSpawnMs))
        warm = tolerant(Bool.self, .warm)
        threadAction = tolerant(AgentHarnessThreadAction.self, .threadAction)
        outputKind = tolerant(AgentHarnessOutputKind.self, .outputKind)
        terminalOutcome = tolerant(AgentHarnessTerminalOutcome.self, .terminalOutcome)
        inputTokens = try c.decodeIfPresent(Int.self, forKey: .inputTokens)
        uncachedInputTokens = agentHarnessTokenCount(tolerant(Int.self, .uncachedInputTokens))
        cachedInputTokens = try c.decodeIfPresent(Int.self, forKey: .cachedInputTokens)
        cacheWriteInputTokens = agentHarnessTokenCount(
            tolerant(Int.self, .cacheWriteInputTokens))
        outputTokens = try c.decodeIfPresent(Int.self, forKey: .outputTokens)
        reasoningOutputTokens = try c.decodeIfPresent(Int.self, forKey: .reasoningOutputTokens)
        totalTokens = try c.decodeIfPresent(Int.self, forKey: .totalTokens)
        contextTokens = try c.decodeIfPresent(Int.self, forKey: .contextTokens)
        contextWindow = try c.decodeIfPresent(Int.self, forKey: .contextWindow)
        contextUsableWindowTokens = agentHarnessTokenCount(
            tolerant(Int.self, .contextUsableWindowTokens))
        contextRawWindowTokens = agentHarnessTokenCount(
            tolerant(Int.self, .contextRawWindowTokens))
        let decodedComposition = tolerant(AgentContextComposition.self, .contextComposition)
        contextComposition = decodedComposition?.isEmpty == false ? decodedComposition : nil
        // Unknown future context-event subtypes are absence, not a reason to quarantine every
        // activity record in the conversation.
        contextEventKind = (try? c.decodeIfPresent(
            AgentContextEventKind.self, forKey: .contextEventKind)) ?? nil
        historyOmittedMessages = try c.decodeIfPresent(
            Int.self, forKey: .historyOmittedMessages)
        historyShortenedMessages = try c.decodeIfPresent(
            Int.self, forKey: .historyShortenedMessages)
        historyReductionReason = (try? c.decodeIfPresent(
            AgentHistoryReductionReason.self, forKey: .historyReductionReason)) ?? nil
        compactionTrigger = agentHarnessCompactionTrigger(
            tolerant(String.self, .compactionTrigger))
        compactionPreTokens = try c.decodeIfPresent(Int.self, forKey: .compactionPreTokens)
        compactionPostTokens = try c.decodeIfPresent(Int.self, forKey: .compactionPostTokens)
        compactionError = agentHarnessErrorKind(tolerant(String.self, .compactionError))
        compactionDurationMs = agentHarnessDuration(tolerant(Int.self, .compactionDurationMs))
        compactionSequence = agentHarnessBoundedCount(
            tolerant(Int.self, .compactionSequence)).flatMap { $0 > 0 ? $0 : nil }
        retryDisposition = tolerant(AgentRetryDisposition.self, .retryDisposition)
        retryAttempt = agentHarnessBoundedCount(tolerant(Int.self, .retryAttempt))
        retryAttempts = agentHarnessBoundedCount(tolerant(Int.self, .retryAttempts))
        retryMaxAttempts = agentHarnessBoundedCount(tolerant(Int.self, .retryMaxAttempts))
        retryDelayMs = agentHarnessDuration(tolerant(Int.self, .retryDelayMs))
        retryWillContinue = tolerant(Bool.self, .retryWillContinue)
        errorKind = agentHarnessErrorKind(tolerant(String.self, .errorKind))
        httpStatusCode = agentHarnessHTTPStatus(tolerant(Int.self, .httpStatusCode))
        rerouteOriginalModelID = agentHarnessBoundedLabel(
            tolerant(String.self, .rerouteOriginalModelID))
        rerouteModelID = agentHarnessBoundedLabel(tolerant(String.self, .rerouteModelID))
        rerouteReason = agentHarnessRerouteReason(tolerant(String.self, .rerouteReason))
        safetyOutcome = tolerant(AgentSafetyOutcome.self, .safetyOutcome)
        safetyReasons = agentHarnessSafetyReasonValues(
            tolerant([String].self, .safetyReasons))
        safetyUseCases = agentHarnessSafetyUseCaseValues(
            tolerant([String].self, .safetyUseCases))
        modelVerifications = agentHarnessModelVerificationValues(
            tolerant([String].self, .modelVerifications))
        safetyFasterModelID = agentHarnessBoundedLabel(
            tolerant(String.self, .safetyFasterModelID))
        safetyShowsBufferingUI = tolerant(Bool.self, .safetyShowsBufferingUI)
        interjectionDisposition = try c.decodeIfPresent(
            AgentInterjectionDisposition.self, forKey: .interjectionDisposition)
        userEventKind = try c.decodeIfPresent(
            AgentUserEventKind.self, forKey: .userEventKind)
        toolTarget = try c.decodeIfPresent(String.self, forKey: .toolTarget)
        toolUseID = agentHarnessBoundedLabel(tolerant(String.self, .toolUseID), maximum: 160)
        toolKind = tolerant(AgentHarnessToolKind.self, .toolKind)
        toolOutcome = tolerant(AgentHarnessToolOutcome.self, .toolOutcome)
        toolDurationMs = agentHarnessDuration(tolerant(Int.self, .toolDurationMs))
        toolWaitDurationMs = agentHarnessDuration(tolerant(Int.self, .toolWaitDurationMs))
        toolExecutionDurationMs = agentHarnessDuration(
            tolerant(Int.self, .toolExecutionDurationMs))
    }
}

enum AgentActivityIdentity {
    static let root = "root"
    static func subagent(_ key: String) -> String { "subagent:\(key)" }
    static func workflow(runKey: String, agentKey: String) -> String {
        "workflow:\(runKey):\(agentKey)"
    }
}

/// Stable visual ordinals shared by the agent cards and activity lanes. Start time is the durable
/// primary order; the key makes ties deterministic without exposing the provider id in the UI.
func agentActivitySubagentOrdinals(_ subagents: [String: SubagentRun]) -> [String: Int] {
    let ordered = subagents.values.sorted {
        if $0.startedAt != $1.startedAt { return $0.startedAt < $1.startedAt }
        return $0.key < $1.key
    }
    return Dictionary(uniqueKeysWithValues: ordered.enumerated().map {
        ($0.element.key, $0.offset + 1)
    })
}

/// Every identity an agent has been seen under, mapped onto the one the UI keys it by.
///
/// A provider may report a child under a provisional id and later reconcile it to a durable one, so
/// the same agent's activity arrives under two names. Both the trace lanes and the agent cards need
/// that mapping, and they had a copy each — which is exactly how they came to disagree: the lanes
/// reconciled, the cards did not, and every card lookup silently returned nothing. One definition,
/// used by both.
func agentActivityAliases(
    subagents: [String: SubagentRun],
    workflowRuns: [String: WorkflowRun] = [:]
) -> [String: String] {
    var aliases = [AgentActivityIdentity.root: AgentActivityIdentity.root]
    for subagent in subagents.values {
        let canonical = AgentActivityIdentity.subagent(subagent.key)
        aliases[canonical] = canonical
        if let taskID = subagent.taskId, !taskID.isEmpty, taskID != subagent.key {
            aliases[AgentActivityIdentity.subagent(taskID)] = canonical
        }
    }
    for run in workflowRuns.values {
        for (agentKey, agent) in run.agents {
            guard let providerID = agent.agentId,
                  let subagent = subagents.values.first(where: {
                      $0.taskId == providerID || $0.key == providerID
                  }) else { continue }
            aliases[AgentActivityIdentity.workflow(runKey: run.runKey, agentKey: agentKey)] =
                AgentActivityIdentity.subagent(subagent.key)
        }
    }
    return aliases
}

/// Reconciliation can replace a provisional provider id with the child thread/task id. Activity
/// already sampled under the old id must collapse into the card's canonical lane, not survive as a
/// second ghost lane.
func canonicalizedAgentActivityGroups(
    _ records: [AgentActivityRecord],
    aliases: [String: String]
) -> [String: [AgentActivityRecord]] {
    Dictionary(grouping: records) { aliases[$0.agentID] ?? $0.agentID }
}

extension AgentActivityRecord {
    func attributed(to selection: ModelSelection?) -> Self {
        guard let selection else { return self }
        var copy = self
        copy.providerAccess = selection.access
        copy.modelID = selection.modelID
        if copy.harnessLaneID == nil {
            copy.harnessLaneID = AgentHarnessLaneID.inferred(from: selection.access)
        }
        return copy
    }

    static func state(
        _ phase: AgentActivityPhase,
        turnID: String?,
        agentID: String = AgentActivityIdentity.root,
        agentLabel: String? = nil,
        detail: String? = nil,
        startsNewLifecycleGeneration: Bool = false,
        at: Date = Date()
    ) -> Self {
        var record = Self(
            at: at,
            turnID: turnID,
            agentID: agentID,
            agentLabel: agentLabel,
            kind: .state,
            phase: phase,
            detail: detail)
        if startsNewLifecycleGeneration {
            record.startsNewLifecycleGeneration = true
        }
        return record
    }

    /// Provider-reported agent identity metadata. It is retained in the same bounded ledger as
    /// state and usage, but does not manufacture a visible execution span of its own.
    static func identity(
        turnID: String?,
        agentID: String = AgentActivityIdentity.root,
        at: Date = Date()
    ) -> Self {
        Self(
            at: at,
            turnID: turnID,
            agentID: agentID,
            kind: .identity)
    }

    static func tokens(
        turnID: String?,
        agentID: String = AgentActivityIdentity.root,
        agentLabel: String? = nil,
        input: Int? = nil,
        uncachedInput: Int? = nil,
        cachedInput: Int? = nil,
        cacheWriteInput: Int? = nil,
        output: Int? = nil,
        reasoningOutput: Int? = nil,
        total: Int? = nil,
        at: Date = Date()
    ) -> Self {
        Self(
            at: at,
            turnID: turnID,
            agentID: agentID,
            agentLabel: agentLabel,
            kind: .tokens,
            inputTokens: agentHarnessTokenCount(input),
            uncachedInputTokens: agentHarnessTokenCount(uncachedInput),
            cachedInputTokens: agentHarnessTokenCount(cachedInput),
            cacheWriteInputTokens: agentHarnessTokenCount(cacheWriteInput),
            outputTokens: agentHarnessTokenCount(output),
            reasoningOutputTokens: agentHarnessTokenCount(reasoningOutput),
            totalTokens: agentHarnessTokenCount(total))
    }

    static func context(
        turnID: String?,
        tokens: Int?,
        window: Int?,
        usableWindow: Int? = nil,
        rawWindow: Int? = nil,
        composition: AgentContextComposition? = nil,
        at: Date = Date()
    ) -> Self {
        Self(
            at: at,
            turnID: turnID,
            kind: .context,
            contextTokens: agentHarnessTokenCount(tokens),
            contextWindow: agentHarnessTokenCount(window),
            contextUsableWindowTokens: agentHarnessTokenCount(usableWindow),
            contextRawWindowTokens: agentHarnessTokenCount(rawWindow),
            contextComposition: composition?.isEmpty == false ? composition : nil)
    }

    static func historyReduction(
        turnID: String?,
        omittedMessages: Int?,
        shortenedMessages: Int?,
        reason: String?,
        at: Date = Date()
    ) -> Self? {
        let omitted = omittedMessages.flatMap { $0 > 0 ? min($0, 1_000_000) : nil }
        let shortened = shortenedMessages.flatMap { $0 > 0 ? min($0, 1_000_000) : nil }
        guard omitted != nil || shortened != nil else { return nil }
        return Self(
            at: at,
            turnID: turnID,
            kind: .context,
            contextEventKind: .historyReduction,
            historyOmittedMessages: omitted,
            historyShortenedMessages: shortened,
            historyReductionReason: reason.flatMap(AgentHistoryReductionReason.init(rawValue:)))
    }

    /// A subtraction marker. Returns nil when the event carries no usable subject or reason, so a
    /// malformed report is dropped rather than drawn as an unexplained badge.
    static func subtraction(
        turnID: String?,
        subject: String?,
        reason: String?,
        names: [String]?,
        count: Int?,
        at: Date = Date()
    ) -> Self? {
        guard let subject = subject.flatMap(AgentSubtractionSubject.init(rawValue:)) else {
            return nil
        }
        let identifiers = (names ?? []).filter { !$0.isEmpty }
        let total = count.flatMap { $0 > 0 ? min($0, 1_000_000) : nil } ?? identifiers.count
        guard total > 0 else { return nil }
        return Self(
            at: at,
            turnID: turnID,
            kind: .context,
            contextEventKind: .subtraction,
            subtractionSubject: subject,
            subtractionReason: reason.flatMap(AgentSubtractionReason.init(rawValue:)),
            subtractionNames: identifiers.isEmpty ? nil : Array(identifiers.prefix(8)),
            subtractionCount: total)
    }

    static func tool(
        _ name: String,
        turnID: String?,
        agentID: String,
        agentLabel: String? = nil,
        target: String? = nil,
        toolUseID: String? = nil,
        toolKind: AgentHarnessToolKind? = nil,
        outcome: AgentHarnessToolOutcome? = nil,
        durationMs: Int? = nil,
        waitDurationMs: Int? = nil,
        executionDurationMs: Int? = nil,
        at: Date = Date()
    ) -> Self {
        Self(
            at: at,
            turnID: turnID,
            agentID: agentID,
            agentLabel: agentLabel,
            kind: .tool,
            detail: name,
            toolTarget: target,
            toolUseID: agentHarnessBoundedLabel(toolUseID, maximum: 160),
            toolKind: toolKind,
            toolOutcome: outcome,
            toolDurationMs: agentHarnessDuration(durationMs),
            toolWaitDurationMs: agentHarnessDuration(waitDurationMs),
            toolExecutionDurationMs: agentHarnessDuration(executionDurationMs))
    }

    static func compaction(
        turnID: String?,
        agentID: String = AgentActivityIdentity.root,
        trigger: String?,
        preTokens: Int?,
        postTokens: Int?,
        error: String? = nil,
        durationMs: Int? = nil,
        sequence: Int? = nil,
        at: Date = Date()
    ) -> Self {
        Self(
            at: at,
            turnID: turnID,
            agentID: agentID,
            kind: .compaction,
            detail: error == nil ? "Summarized earlier messages" : "Couldn’t summarize earlier messages",
            compactionTrigger: agentHarnessCompactionTrigger(trigger),
            compactionPreTokens: preTokens.flatMap { $0 > 0 ? $0 : nil },
            compactionPostTokens: postTokens.flatMap { $0 > 0 ? $0 : nil },
            compactionError: agentHarnessErrorKind(error),
            compactionDurationMs: agentHarnessDuration(durationMs),
            compactionSequence: agentHarnessBoundedCount(sequence).flatMap { $0 > 0 ? $0 : nil })
    }

    static func interjection(
        _ text: String,
        disposition: AgentInterjectionDisposition,
        turnID: String?,
        at: Date
    ) -> Self {
        Self(
            at: at,
            turnID: turnID,
            kind: .interjection,
            detail: String(text.prefix(240)),
            interjectionDisposition: disposition,
            userEventKind: .guidance)
    }

    /// The request that opened a provider turn. It uses the established user-event record kind so
    /// a downgrade sees an ordinary guidance marker rather than failing to decode the sidecar.
    static func initialPrompt(
        _ text: String,
        turnID: String?,
        at: Date
    ) -> Self {
        Self(
            at: at,
            turnID: turnID,
            kind: .interjection,
            detail: String(text.prefix(240)),
            userEventKind: .initialPrompt)
    }
}

/// The root state is published first so observers never see an event-only turn while the two
/// records are appended. Reviews have no user-authored opening prompt and keep the prior shape.
func agentActivityOpeningRecords(
    prompt: String,
    turnID: String,
    submittedAt: Date,
    includesInitialPrompt: Bool
) -> [AgentActivityRecord] {
    var records: [AgentActivityRecord] = [
        .state(.model, turnID: turnID, detail: "Turn started", at: submittedAt),
    ]
    if includesInitialPrompt {
        records.append(.initialPrompt(prompt, turnID: turnID, at: submittedAt))
    }
    return records
}

private let maximumPersistedAgentActivityRecords = 1_600
private let agentActivityCompactionMergeWindow: TimeInterval = 5

/// A visible tool boundary carries the human-readable name, target, and start time. Its provider
/// harness completion carries the exact outcome and duration. They can cross the transport in
/// either order, so correlate only by the complete agent-scoped identity and keep the visible
/// boundary as the canonical durable record.
private func mergedAgentActivityTool(
    _ existing: AgentActivityRecord,
    with companion: AgentActivityRecord
) -> AgentActivityRecord {
    let existingIsCompletion = existing.harnessEventKind == .tool
    let visible = existingIsCompletion ? companion : existing
    let completion = existingIsCompletion ? existing : companion
    var merged = visible
    merged.providerAccess = completion.providerAccess ?? merged.providerAccess
    merged.modelID = completion.modelID ?? merged.modelID
    merged.agentLabel = merged.agentLabel ?? completion.agentLabel
    merged.harnessLaneID = completion.harnessLaneID ?? merged.harnessLaneID
    merged.harnessPhase = completion.harnessPhase ?? merged.harnessPhase
    merged.harnessEventKind = completion.harnessEventKind ?? merged.harnessEventKind
    merged.measurementProvenance = completion.measurementProvenance
        ?? merged.measurementProvenance
    merged.measurementScope = completion.measurementScope ?? merged.measurementScope
    merged.measurementAggregation = completion.measurementAggregation
        ?? merged.measurementAggregation
    merged.toolKind = completion.toolKind ?? merged.toolKind
    merged.toolOutcome = completion.toolOutcome ?? merged.toolOutcome
    merged.toolDurationMs = completion.toolDurationMs ?? merged.toolDurationMs
    merged.toolWaitDurationMs = completion.toolWaitDurationMs ?? merged.toolWaitDurationMs
    merged.toolExecutionDurationMs = completion.toolExecutionDurationMs
        ?? merged.toolExecutionDurationMs
    return merged
}

private func agentActivityToolsAreCompanions(
    _ existing: AgentActivityRecord,
    _ candidate: AgentActivityRecord
) -> Bool {
    guard existing.kind == .tool,
          candidate.kind == .tool,
          existing.turnID == candidate.turnID,
          existing.agentID == candidate.agentID,
          let existingToolUseID = existing.toolUseID,
          let candidateToolUseID = candidate.toolUseID,
          !existingToolUseID.isEmpty,
          existingToolUseID == candidateToolUseID,
          (existing.harnessEventKind == .tool) != (candidate.harnessEventKind == .tool)
    else { return false }
    return true
}

/// `compact_boundary` is the durable provider-neutral boundary used by older builds; the harness
/// observation arriving beside it contributes exact timing/provenance. They are two reports of one
/// compaction, not two compactions. Keep the earlier record identity/order and enrich it with every
/// field the companion report knows.
private func mergedAgentActivityCompaction(
    _ existing: AgentActivityRecord,
    with companion: AgentActivityRecord
) -> AgentActivityRecord {
    var merged = existing
    merged.providerAccess = companion.providerAccess ?? merged.providerAccess
    merged.modelID = companion.modelID ?? merged.modelID
    merged.agentLabel = companion.agentLabel ?? merged.agentLabel
    merged.detail = companion.detail ?? merged.detail
    merged.harnessLaneID = companion.harnessLaneID ?? merged.harnessLaneID
    merged.harnessPhase = companion.harnessPhase ?? merged.harnessPhase
    merged.harnessEventKind = companion.harnessEventKind ?? merged.harnessEventKind
    merged.measurementProvenance = companion.measurementProvenance
        ?? merged.measurementProvenance
    merged.measurementScope = companion.measurementScope ?? merged.measurementScope
    merged.measurementAggregation = companion.measurementAggregation
        ?? merged.measurementAggregation
    merged.compactionTrigger = companion.compactionTrigger ?? merged.compactionTrigger
    merged.compactionPreTokens = companion.compactionPreTokens ?? merged.compactionPreTokens
    merged.compactionPostTokens = companion.compactionPostTokens ?? merged.compactionPostTokens
    merged.compactionError = companion.compactionError ?? merged.compactionError
    merged.compactionDurationMs = companion.compactionDurationMs ?? merged.compactionDurationMs
    merged.compactionSequence = companion.compactionSequence ?? merged.compactionSequence
    return merged
}

private func agentActivityCompactionsAreCompanions(
    _ existing: AgentActivityRecord,
    _ candidate: AgentActivityRecord
) -> Bool {
    guard existing.kind == .compaction,
          candidate.kind == .compaction,
          existing.turnID == candidate.turnID,
          existing.agentID == candidate.agentID,
          (existing.harnessEventKind == .compaction)
            != (candidate.harnessEventKind == .compaction),
          abs(existing.at.timeIntervalSince(candidate.at)) <= agentActivityCompactionMergeWindow
    else { return false }
    if let existingSequence = existing.compactionSequence,
       let candidateSequence = candidate.compactionSequence,
       existingSequence != candidateSequence {
        return false
    }
    if let existingTrigger = existing.compactionTrigger,
       let candidateTrigger = candidate.compactionTrigger {
        return existingTrigger == candidateTrigger
    }
    return true
}

/// Append with conservative de-duplication and a hard persistence bound. State/context notifications
/// can repeat verbatim at provider reconciliation boundaries; token events cannot be de-duplicated by
/// value because two real model calls may happen to use the same number of tokens.
func appendAgentActivityRecord(
    _ record: AgentActivityRecord,
    to records: inout [AgentActivityRecord]
) {
    if record.kind == .tokens,
       record.inputTokens == nil,
       record.uncachedInputTokens == nil,
       record.cachedInputTokens == nil,
       record.cacheWriteInputTokens == nil,
       record.outputTokens == nil,
       record.reasoningOutputTokens == nil,
       record.totalTokens == nil {
        return
    }
    if record.kind == .context,
       record.contextEventKind == nil,
       record.harnessEventKind == nil,
       record.contextTokens == nil,
       record.contextWindow == nil,
       record.contextUsableWindowTokens == nil,
       record.contextRawWindowTokens == nil,
       record.contextComposition == nil {
        return
    }
    if record.kind == .identity,
       record.harnessLaneID == nil,
       record.providerAccess == nil,
       record.modelID?.isEmpty != false {
        return
    }
    if record.kind == .tool,
       let companionIndex = records.lastIndex(where: {
           agentActivityToolsAreCompanions($0, record)
       }) {
        records[companionIndex] = mergedAgentActivityTool(
            records[companionIndex], with: record)
        return
    }
    if record.kind == .compaction,
       let companionIndex = records.lastIndex(where: {
           agentActivityCompactionsAreCompanions($0, record)
       }) {
        records[companionIndex] = mergedAgentActivityCompaction(
            records[companionIndex], with: record)
        return
    }
    if let last = records.last(where: {
        $0.turnID == record.turnID && $0.agentID == record.agentID && $0.kind == record.kind
    }) {
        if record.kind == .state,
           record.harnessEventKind == nil,
           last.harnessEventKind == nil,
           last.phase == record.phase,
           last.detail == record.detail,
           record.startsNewLifecycleGeneration != true {
            return
        }
        if record.kind == .context,
           last.contextTokens == record.contextTokens,
           last.contextWindow == record.contextWindow,
           last.contextUsableWindowTokens == record.contextUsableWindowTokens,
           last.contextRawWindowTokens == record.contextRawWindowTokens,
           last.contextComposition == record.contextComposition,
           last.harnessEventKind == record.harnessEventKind,
           last.contextEventKind == record.contextEventKind,
           last.historyOmittedMessages == record.historyOmittedMessages,
           last.historyShortenedMessages == record.historyShortenedMessages,
           last.historyReductionReason == record.historyReductionReason {
            return
        }
        if record.kind == .identity,
           last.providerAccess == record.providerAccess,
           last.modelID == record.modelID {
            return
        }
    }
    records.append(record)
    if records.count > maximumPersistedAgentActivityRecords {
        // Prefer dropping a complete oldest provider turn. A partially retained turn would imply
        // false token totals and can lose the root/provider boundary while leaving child samples.
        if let oldestTurnID = records.first?.turnID,
           records.contains(where: { $0.turnID != nil && $0.turnID != oldestTurnID }) {
            records.removeAll { $0.turnID == oldestTurnID }
        }
        if records.count > maximumPersistedAgentActivityRecords {
            records.removeFirst(records.count - maximumPersistedAgentActivityRecords)
        }
    }
}

/// A provider can stream provisional per-step usage and later publish an authoritative request
/// total. When that final sample is present, counting both would inflate the turn. A request-scoped
/// final replaces provisional samples only for the same agent and provider-query sequence; an
/// agent-tree final includes delegated and auxiliary calls and therefore replaces every provisional
/// sample in that query. Recovery queries in the same Mechanician turn remain independently billed.
/// Interrupted requests with no final retain their streamed fallback samples.
func agentActivityEffectiveTokenRecords(
    _ records: [AgentActivityRecord]
) -> [AgentActivityRecord] {
    func queryKey(_ record: AgentActivityRecord) -> String? {
        guard let turnID = record.turnID else { return nil }
        let sequence = record.providerQuerySequence.map(String.init) ?? "legacy"
        return "\(turnID)\u{0}\(sequence)"
    }
    let queriesWithAgentTreeFinalUsage = Set(records.compactMap { record -> String? in
        guard record.kind == .tokens,
              record.measurementAggregation == .final,
              record.measurementScope == .agentTree else { return nil }
        return queryKey(record)
    })
    let agentsWithFinalUsage = Set(records.compactMap { record -> String? in
        guard record.kind == .tokens,
              record.measurementAggregation == .final,
              let query = queryKey(record) else { return nil }
        return "\(query)\u{0}\(record.agentID)"
    })
    guard !queriesWithAgentTreeFinalUsage.isEmpty || !agentsWithFinalUsage.isEmpty else {
        return records
    }
    return records.filter { record in
        guard record.kind == .tokens,
              let query = queryKey(record) else { return true }
        if queriesWithAgentTreeFinalUsage.contains(query) {
            return record.measurementAggregation == .final
                && record.measurementScope == .agentTree
        }
        let key = "\(query)\u{0}\(record.agentID)"
        guard agentsWithFinalUsage.contains(key) else { return true }
        return record.measurementAggregation == .final
    }
}

/// Keep the user's durable selection immutable while attributing one provider-reported execution
/// record to the model that actually ran. Empty/malformed values are absence, never permission to
/// fall back to the requested model and call it provider truth.
func agentActivitySelection(
    reportingModel rawModel: String?,
    from requested: ModelSelection
) -> ModelSelection? {
    guard let model = rawModel?
        .trimmingCharacters(in: .whitespacesAndNewlines),
        !model.isEmpty else { return nil }
    return ModelSelection(access: requested.access, modelID: model)
}


struct AgentActivityTurnSummary: Identifiable, Equatable {
    var id: String
    var startedAt: Date
    var endedAt: Date
    var providerAccess: ModelAccess?
    var modelID: String?
    var isTerminal: Bool
    var inputTokens: Int
    var cachedInputTokens: Int
    var outputTokens: Int
    var reasoningOutputTokens: Int
    var aggregateOnlyTokens: Int
    /// Optional exact components preserve missing versus an observed zero across turn summaries.
    var uncachedInputTokens: Int? = nil
    var cacheWriteInputTokens: Int? = nil

    /// The single arithmetic projection shared by the Activity headline and compact conversation
    /// summary. Cached input stays a subset of `input`; it is never added to processed tokens.
    var tokenBreakdown: AgentActivityTokenBreakdown {
        var result = AgentActivityTokenBreakdown(
            input: inputTokens,
            cachedInput: cachedInputTokens,
            output: outputTokens,
            reasoningOutput: reasoningOutputTokens,
            unclassified: aggregateOnlyTokens)
        result.addExplicitInputComponents(
            uncached: uncachedInputTokens,
            cacheWrite: cacheWriteInputTokens)
        return result
    }
}

/// One summary per provider turn, newest first. Route fields are selected from the newest record
/// that reports them because startup events can precede model resolution while late child events
/// still carry the authoritative original route.
func agentActivityTurnSummaries(
    _ records: [AgentActivityRecord],
    aliases: [String: String] = [:]
) -> [AgentActivityTurnSummary] {
    Dictionary(grouping: records.compactMap { record in
        record.turnID.map { ($0, record) }
    }, by: \.0)
    .compactMap { turnID, pairs in
        // Keep both orders. Provider lifecycle events can arrive late with historical timestamps:
        // wall-clock order is right for chart bounds, while append order is the authoritative
        // lifecycle sequence observed by the app.
        let ledgerRecords = pairs.map(\.1)
        let turnRecords = ledgerRecords.enumerated().sorted {
            if $0.element.at != $1.element.at { return $0.element.at < $1.element.at }
            return $0.offset < $1.offset
        }.map(\.element)
        let usageRecords = agentActivityEffectiveTokenRecords(turnRecords)
        guard let first = turnRecords.first, let last = turnRecords.last else { return nil }
        // Delegate lifecycle updates can arrive late with their provider-authored historical
        // start/end timestamp. The record still belongs to the current parent turn, but that old
        // timestamp must not make this turn sort behind an earlier completed turn. Root state is
        // the authoritative parent-turn clock; fall back to the first record only for imported
        // ledgers that predate root-state sampling.
        let rootStates = turnRecords.filter {
            $0.agentID == AgentActivityIdentity.root
                && $0.kind == .state
                && $0.phase != nil
        }
        let rootStatesInLedgerOrder = ledgerRecords.filter {
            $0.agentID == AgentActivityIdentity.root
                && $0.kind == .state
                && $0.phase != nil
        }
        let startedAt = rootStates.first?.at ?? first.at
        let routed = turnRecords.last {
            $0.providerAccess != nil || ($0.modelID?.isEmpty == false)
        }
        // Ordinary activity retains the immutable requested route for ownership and diagnostics.
        // A root identity record is the provider's explicit answer about what actually ran, so it
        // wins only the display model without rewriting those historical route records.
        let providerReportedRoot = ledgerRecords.last {
            $0.agentID == AgentActivityIdentity.root
                && $0.kind == .identity
                && ($0.modelID?.isEmpty == false)
        }
        // Terminal activity is monotonic. Stop-and-Redirect can leave already-buffered progress
        // behind the synthetic `.stopped` boundary in the transport; append order must not let that
        // stale progress resurrect the parent turn.
        let rootTerminal = rootStatesInLedgerOrder.contains {
            $0.phase?.isTerminal == true
        }
        // A provider may finish the parent model before its delegated children publish their final
        // lifecycle boundary. Treat the complete provider turn as live until every known child
        // lane is terminal, otherwise the activity clock freezes and "Latest" shows a completed
        // root while the Agents list still shows running work.
        let delegatedActive = Dictionary(grouping: ledgerRecords.filter {
            $0.agentID != AgentActivityIdentity.root
                && $0.kind == .state
                && $0.phase != nil
        }, by: { aliases[$0.agentID] ?? $0.agentID })
        .values
        .contains(where: agentActivityLaneIsActive)
        return AgentActivityTurnSummary(
            id: turnID,
            startedAt: startedAt,
            endedAt: last.at,
            providerAccess: providerReportedRoot?.providerAccess ?? routed?.providerAccess,
            modelID: providerReportedRoot?.modelID ?? routed?.modelID,
            isTerminal: rootTerminal && !delegatedActive,
            inputTokens: usageRecords.compactMap(\.inputTokens).reduce(0, +),
            cachedInputTokens: usageRecords.compactMap(\.cachedInputTokens).reduce(0, +),
            outputTokens: usageRecords.compactMap(\.outputTokens).reduce(0, +),
            reasoningOutputTokens: usageRecords.compactMap(\.reasoningOutputTokens).reduce(0, +),
            aggregateOnlyTokens: usageRecords.compactMap(\.totalTokens).reduce(0, +),
            uncachedInputTokens: agentHarnessSumObserved(
                usageRecords.map(\.uncachedInputTokens)),
            cacheWriteInputTokens: agentHarnessSumObserved(
                usageRecords.map(\.cacheWriteInputTokens)))
    }
    .sorted { $0.startedAt > $1.startedAt }
}

/// The conversation-level default shared by the compact strip and Activity headline.
///
/// A parent can complete while one of its delegates intentionally continues in the background.
/// In that state the useful conversation turn is the newest still-live turn, not a newer completed
/// turn. Once no turn remains live, both surfaces fall back to the newest turn.
func agentActivityActiveOrLatestTurn(
    _ summaries: [AgentActivityTurnSummary]
) -> AgentActivityTurnSummary? {
    summaries.first(where: { !$0.isTerminal }) ?? summaries.first
}

private func activityPhase(for status: WorkflowStatus) -> AgentActivityPhase {
    switch status {
    case .pending, .paused: return .waiting
    case .running: return .model
    case .completed: return .completed
    case .failed: return .failed
    case .killed, .stopped: return .stopped
    }
}

private func activityPhase(for state: WorkflowAgentState) -> AgentActivityPhase {
    switch state {
    case .queued: return .waiting
    case .start, .progress: return .model
    case .done: return .completed
    case .failed: return .failed
    case .stopped: return .stopped
    }
}

private func matchingSubagent(
    for update: WorkflowUpdate,
    in subagents: [String: SubagentRun]
) -> SubagentRun? {
    if let toolUseID = update.toolUseId, let exact = subagents[toolUseID] { return exact }
    if !update.taskId.isEmpty {
        if let exact = subagents[update.taskId] { return exact }
        if let matched = subagents.values.first(where: { $0.taskId == update.taskId }) {
            return matched
        }
    }
    return nil
}

private func previousSubagent(
    matching current: SubagentRun,
    update: WorkflowUpdate,
    in subagents: [String: SubagentRun]
) -> SubagentRun? {
    subagents[current.key]
        ?? update.toolUseId.flatMap { subagents[$0] }
        ?? subagents.values.first {
            current.taskId != nil && $0.taskId == current.taskId
        }
}

private func positive(_ value: Int?) -> Int? {
    value.flatMap { $0 > 0 ? $0 : nil }
}

/// Translate one cumulative workflow reducer step into point-in-time timeline samples. This stays
/// pure so foreground and background turns produce identical lanes and provider reconciliation can
/// be tested without constructing an AgentBridge.
func agentActivityRecords(
    beforeSubagents: [String: SubagentRun],
    afterSubagents: [String: SubagentRun],
    beforeRuns: [String: WorkflowRun],
    afterRuns: [String: WorkflowRun],
    update: WorkflowUpdate,
    turnID: String?,
    observedAt: Date = Date()
) -> [AgentActivityRecord] {
    var records: [AgentActivityRecord] = []

    if let current = matchingSubagent(for: update, in: afterSubagents) {
        let previous = previousSubagent(matching: current, update: update, in: beforeSubagents)
        // Prefer the provider child/thread identity once known. A lifecycle update can first arrive
        // under a throwaway tool-use key (for example `activity-start`) that is later deleted during
        // reconciliation. `taskId` survives that merge and the panel's alias map can therefore
        // collapse every sample onto the durable card key.
        let activityIdentity = current.taskId.flatMap { $0.isEmpty ? nil : $0 } ?? current.key
        let agentID = AgentActivityIdentity.subagent(activityIdentity)
        let label = current.subagentType.isEmpty ? "Agent" : current.subagentType

        // `SubagentRun` is the latest lifecycle projection for one durable child thread. Its state
        // is terminal-monotonic inside a generation, while a provider-authored retask explicitly
        // resets both the card and this Activity lane. A new parent turn is already a distinct lane;
        // inside one turn only that authoritative boundary may start another generation.
        let startsNewGeneration = update.startsNewSubagentLifecycleGeneration
        let projectedStatus: WorkflowStatus? = {
            if startsNewGeneration { return .running }
            return previous == nil || previous?.status != current.status
                ? current.status : nil
        }()
        if let projectedStatus {
            // A reused generation starts at its actual local observation boundary. Provider event
            // timestamps from its prior generation cannot stretch this newly-opened trace span.
            let stateAt = startsNewGeneration
                ? observedAt
                : (projectedStatus.isTerminal
                    ? (current.endedAt ?? observedAt)
                    : current.startedAt)
            records.append(.state(
                activityPhase(for: projectedStatus),
                turnID: turnID,
                agentID: agentID,
                agentLabel: label,
                detail: current.summary,
                startsNewLifecycleGeneration: startsNewGeneration,
                at: stateAt))
        }

        let oldToolCount = min(previous?.toolEvents.count ?? 0, current.toolEvents.count)
        for tool in current.toolEvents.dropFirst(oldToolCount) {
            // Late provider metadata may arrive after the child is already terminal. Preserve the
            // tool sample, but never let it replace the terminal lifecycle state and resurrect the
            // lane as active.
            if !current.status.isTerminal {
                records.append(.state(
                    .tool,
                    turnID: turnID,
                    agentID: agentID,
                    agentLabel: label,
                    detail: tool.name,
                    at: tool.at))
            }
            records.append(.tool(
                tool.name,
                turnID: turnID,
                agentID: agentID,
                agentLabel: label,
                target: tool.target,
                toolUseID: tool.toolEventID,
                at: tool.at))
        }

        if let usage = update.usage {
            let hasBreakdown = [
                usage.inputTokens,
                usage.cachedInputTokens,
                usage.outputTokens,
                usage.reasoningOutputTokens,
            ].contains { positive($0) != nil }
            let previousTotal = previous?.reportedTokens ?? 0
            let cumulativeDelta = current.reportedTokens.map { max(0, $0 - previousTotal) }
            let aggregate = hasBreakdown ? nil : positive(cumulativeDelta)
            if hasBreakdown || aggregate != nil {
                if !current.status.isTerminal {
                    records.append(.state(
                        .model,
                        turnID: turnID,
                        agentID: agentID,
                        agentLabel: label,
                        detail: "Model call",
                        at: observedAt))
                }
                var record = AgentActivityRecord.tokens(
                    turnID: turnID,
                    agentID: agentID,
                    agentLabel: label,
                    input: usage.inputTokens,
                    cachedInput: usage.cachedInputTokens,
                    output: usage.outputTokens,
                    reasoningOutput: usage.reasoningOutputTokens,
                    total: aggregate,
                    at: observedAt)
                record.providerQuerySequence = update.providerQuerySequence
                record.measurementProvenance = .providerReport
                record.measurementScope = .agent
                record.measurementAggregation = .delta
                records.append(record)
            }
        }
    }

    for (runKey, currentRun) in afterRuns {
        let previousRun = beforeRuns[runKey]
        for (agentKey, current) in currentRun.agents {
            let previous = previousRun?.agents[agentKey]
            let mirroredSubagent = current.agentId.flatMap { providerID in
                afterSubagents.values.first { $0.taskId == providerID }
            }
            let agentID = mirroredSubagent.map {
                AgentActivityIdentity.subagent($0.key)
            } ?? AgentActivityIdentity.workflow(runKey: runKey, agentKey: agentKey)
            let label = current.label.isEmpty ? "Agent \(current.index)" : current.label

            if previous == nil || previous?.state != current.state {
                let stateAt: Date
                if current.state.isTerminal {
                    stateAt = current.endedAt ?? observedAt
                } else {
                    stateAt = current.startedAt ?? observedAt
                }
                // A stopped/failed aggregate can receive a final cumulative child snapshot after
                // reconciliation. Preserve its metadata below, but do not append a fresh nonterminal
                // state that would reopen the already-closed activity lane.
                if !currentRun.status.isTerminal || current.state.isTerminal {
                    records.append(.state(
                        activityPhase(for: current.state),
                        turnID: turnID,
                        agentID: agentID,
                        agentLabel: label,
                        detail: current.lastToolSummary,
                        at: stateAt))
                }
            }

            let oldToolCount = min(previous?.toolEvents.count ?? 0, current.toolEvents.count)
            for tool in current.toolEvents.dropFirst(oldToolCount) {
                if !currentRun.status.isTerminal && !current.state.isTerminal {
                    records.append(.state(
                        .tool,
                        turnID: turnID,
                        agentID: agentID,
                        agentLabel: label,
                        detail: tool.name,
                        at: tool.at))
                }
                records.append(.tool(
                    tool.name,
                    turnID: turnID,
                    agentID: agentID,
                    agentLabel: label,
                    toolUseID: tool.toolEventID,
                    at: tool.at))
            }

            let oldTokens = previous?.reportedTokens ?? 0
            if let cumulative = current.reportedTokens {
                let delta = cumulative - oldTokens
                if delta > 0 {
                    if !currentRun.status.isTerminal && !current.state.isTerminal {
                        records.append(.state(
                            .model,
                            turnID: turnID,
                            agentID: agentID,
                            agentLabel: label,
                            detail: "Model call",
                            at: observedAt))
                    }
                    var record = AgentActivityRecord.tokens(
                        turnID: turnID,
                        agentID: agentID,
                        agentLabel: label,
                        total: delta,
                        at: observedAt)
                    record.providerQuerySequence = update.providerQuerySequence
                    record.measurementProvenance = .providerReport
                    record.measurementScope = .agent
                    record.measurementAggregation = .delta
                    records.append(record)
                }
            }
        }
    }
    return records.sorted { $0.at < $1.at }
}

private struct OrphanedAgentActivityLaneKey: Hashable {
    var turnID: String
    var agentID: String
}

/// Close activity left open when a persisted conversation is loaded without the process that owned
/// it.
///
/// This is a cold-load repair, not a live liveness heuristic. A child may intentionally outlive its
/// parent turn while the app remains open, so callers must never run it against a live bridge. At
/// cold load no provider process from the saved session survives. Closing every remaining root or
/// delegated lane is therefore truthful even when a cumulative `SubagentRun` card was already
/// terminal and the ordinary delegate terminalizer had nothing left to mutate.
///
/// The boundary is the lane's own final persisted sample. Neither the cumulative card's older
/// `endedAt` nor the root turn's later end describes this reused generation, and using `Date()`
/// would make every restart lengthen the trace.
@discardableResult
func terminalizeColdLoadedAgentActivity(
    _ records: inout [AgentActivityRecord],
    aliases: [String: String]
) -> Bool {
    let original = records
    let lanes = Dictionary(grouping: records.compactMap {
        record -> (OrphanedAgentActivityLaneKey, AgentActivityRecord)? in
        guard let turnID = record.turnID, !turnID.isEmpty else { return nil }
        let canonicalID = aliases[record.agentID] ?? record.agentID
        return (OrphanedAgentActivityLaneKey(
            turnID: turnID,
            agentID: canonicalID), record)
    }, by: \.0)
    .mapValues { $0.map(\.1) }

    struct Repair {
        var key: OrphanedAgentActivityLaneKey
        var at: Date
        var attribution: AgentActivityRecord?
        var label: String?
    }
    let repairs = lanes.compactMap { key, lane -> Repair? in
        let generation = agentActivityCurrentLifecycleGenerationRecords(lane)
        // Harness milestones are persisted as `.state` records with `harnessPhase`, not the
        // ordinary `phase` consumed by `agentActivityLaneIsActive`. A lifecycle prefix can be
        // absent from an imported or bounded ledger while its provider milestones remain. Without
        // this cold-load-only fallback the turn summary has no root terminal, so the synthetic
        // Harness lane keeps ticking after relaunch even though its provider process is gone.
        let hasHarnessOnlyRootLifecycle = key.agentID == AgentActivityIdentity.root
            && generation.contains {
                $0.agentID == AgentActivityIdentity.root && $0.harnessPhase != nil
            }
            && !generation.contains {
                $0.agentID == AgentActivityIdentity.root
                    && $0.kind == .state
                    && $0.phase != nil
            }
        guard (agentActivityLaneIsActive(lane) || hasHarnessOnlyRootLifecycle),
              let laneEnd = generation.map(\.at).max() else { return nil }
        return Repair(
            key: key,
            at: laneEnd,
            attribution: generation.last {
                $0.providerAccess != nil || $0.modelID?.isEmpty == false
                    || $0.harnessLaneID != nil
            },
            label: generation.last { $0.agentLabel?.isEmpty == false }?.agentLabel)
    }.sorted {
        if $0.at != $1.at { return $0.at < $1.at }
        if $0.key.turnID != $1.key.turnID { return $0.key.turnID < $1.key.turnID }
        return $0.key.agentID < $1.key.agentID
    }

    for repair in repairs {
        var terminal = AgentActivityRecord.state(
            .stopped,
            turnID: repair.key.turnID,
            agentID: repair.key.agentID,
            agentLabel: repair.label,
            at: repair.at)
        if let attribution = repair.attribution {
            terminal.providerAccess = attribution.providerAccess
            terminal.modelID = attribution.modelID
            terminal.harnessLaneID = attribution.harnessLaneID
        }
        appendAgentActivityRecord(terminal, to: &records)
    }
    return records != original
}

// MARK: - Derived visualization model
//
// Everything below is provider-neutral derived data — lanes, trace spans, usage buckets — with no
// rendering attached. The Agents panel that draws it is native AppKit (`AppKitAgentsPanel.swift`),
// so this file deliberately imports no UI framework: a type here must stay renderer-agnostic.

enum AgentActivityVisualizationMode: String, CaseIterable {
    case trace
    case usage

    var title: String {
        switch self {
        case .trace: return "Trace"
        case .usage: return "Usage"
        }
    }

    var helpText: String {
        switch self {
        case .trace: return "Show what each agent did, in order"
        case .usage: return "Show provider-reported tokens and context"
        }
    }
}


/// A cached-input amount is a subset of input, not an additional quantity. Keeping the arithmetic
/// in one value type prevents the headline metrics, trace inspector, and throughput chart from
/// accidentally double-counting it in three different ways.
struct AgentActivityTokenBreakdown: Equatable {
    var input = 0
    var cachedInput = 0
    var output = 0
    var reasoningOutput = 0
    var unclassified = 0
    private(set) var reportedUncachedInput = 0
    private(set) var cacheWriteInput = 0
    private(set) var hasReportedUncachedInput = false
    private(set) var hasReportedCacheWriteInput = false

    var uncachedInput: Int {
        hasReportedUncachedInput
            ? reportedUncachedInput
            : max(0, input - min(input, cachedInput))
    }
    var generated: Int { output + reasoningOutput }
    var processed: Int { input + generated + unclassified }
    var isEmpty: Bool { processed == 0 }

    mutating func add(_ record: AgentActivityRecord) {
        input += max(0, record.inputTokens ?? 0)
        cachedInput += max(0, record.cachedInputTokens ?? 0)
        output += max(0, record.outputTokens ?? 0)
        reasoningOutput += max(0, record.reasoningOutputTokens ?? 0)
        unclassified += max(0, record.totalTokens ?? 0)
        addExplicitInputComponents(
            uncached: record.uncachedInputTokens,
            cacheWrite: record.cacheWriteInputTokens)
    }

    mutating func add(_ other: Self) {
        input += other.input
        cachedInput += other.cachedInput
        output += other.output
        reasoningOutput += other.reasoningOutput
        unclassified += other.unclassified
        if other.hasReportedUncachedInput {
            reportedUncachedInput += other.reportedUncachedInput
            hasReportedUncachedInput = true
        }
        if other.hasReportedCacheWriteInput {
            cacheWriteInput += other.cacheWriteInput
            hasReportedCacheWriteInput = true
        }
    }

    mutating func addExplicitInputComponents(uncached: Int?, cacheWrite: Int?) {
        if let uncached {
            reportedUncachedInput += max(0, uncached)
            hasReportedUncachedInput = true
        }
        if let cacheWrite {
            cacheWriteInput += max(0, cacheWrite)
            hasReportedCacheWriteInput = true
        }
    }
}

func agentActivityTokenBreakdown(
    _ records: [AgentActivityRecord]
) -> AgentActivityTokenBreakdown {
    agentActivityEffectiveTokenRecords(records).reduce(
        into: AgentActivityTokenBreakdown()
    ) { result, record in
        result.add(record)
    }
}

struct AgentActivityTraceSpan: Identifiable, Equatable {
    var id: UUID
    var start: Date
    var end: Date
    var phase: AgentActivityPhase
    var title: String
    var detail: String?
    var tokens: AgentActivityTokenBreakdown
    var toolNames: [String]
    var sourceCount: Int

    var duration: TimeInterval { max(0, end.timeIntervalSince(start)) }
}

private struct AgentActivityTraceMetadata {
    var tokens = AgentActivityTokenBreakdown()
    var toolNames: [String] = []
    private var seenToolNames: Set<String> = []

    mutating func add(_ record: AgentActivityRecord) {
        if record.kind == .tokens {
            tokens.add(record)
        } else if record.kind == .tool,
                  let rawName = record.detail.flatMap(activitySingleLine) {
            let displayName = traceToolDisplayName(
                toolName: rawName,
                target: record.toolTarget)
            if seenToolNames.insert(displayName).inserted {
                toolNames.append(displayName)
            }
        }
    }

    mutating func add(_ other: Self) {
        tokens.add(other.tokens)
        for name in other.toolNames where seenToolNames.insert(name).inserted {
            toolNames.append(name)
        }
    }
}

/// Convert state transitions into profiler-style intervals. Token and tool records inside an
/// interval become metadata on the span; they are intentionally not promoted to foreground glyphs.
/// Terminal states remain zero-duration milestones.
func agentActivityTraceSpans(
    _ records: [AgentActivityRecord],
    start: Date,
    end: Date
) -> [AgentActivityTraceSpan] {
    let effectiveRecords = agentActivityEffectiveTokenRecords(records)
    let ordered = effectiveRecords.enumerated().sorted {
        if $0.element.at != $1.element.at { return $0.element.at < $1.element.at }
        return $0.offset < $1.offset
    }.map(\.element)
    let states = ordered.filter { $0.kind == .state && $0.phase != nil }
    guard !states.isEmpty else { return [] }

    // Compaction is the one phase whose end the provider reports independently: `status: compacting`
    // opens the interval and the compaction boundary closes it. Ending it at "whatever state record
    // came next" threw that away — in a recorded run a stray assistant delta 53ms after the start
    // cut a 31-second compaction down to the 3-point minimum bar, and the false model span that
    // replaced it covered the entire real duration. Five of seven recorded compactions were
    // under-reported this way. Both endpoints are known, so use both.
    let compactionBoundaries = ordered.compactMap { $0.kind == .compaction ? $0 : nil }
    var absorbedStateIndices: Set<Int> = []
    var compactionSpanEnds: [Int: (end: Date, boundary: AgentActivityRecord?)] = [:]
    var cursor = 0
    while cursor < states.count {
        guard states[cursor].phase == .compacting else {
            cursor += 1
            continue
        }
        let openedAt = states[cursor].at
        let boundary = compactionBoundaries.first { $0.at >= openedAt }
        var scan = cursor + 1
        while scan < states.count {
            let candidate = states[scan]
            if let boundary, candidate.at >= boundary.at { break }
            // Only ordinary model activity is absorbed into the compaction. A provider liveness ping
            // and a summarization delta both arrive as `.model` and neither contradicts "compacting".
            // A tool call, a wait, or a terminal state is proof that ordinary work resumed, so it
            // closes the interval even when the boundary record never arrived.
            guard candidate.phase == .model else { break }
            absorbedStateIndices.insert(scan)
            scan += 1
        }
        let nextSurviving = scan < states.count ? states[scan].at : end
        compactionSpanEnds[cursor] = (
            end: max(openedAt, min(boundary?.at ?? nextSurviving, nextSurviving)),
            boundary: boundary)
        cursor = scan
    }

    // Each metadata record is consumed by at most one ordinary interval. The old implementation
    // filtered the entire ledger once per state, making a dense 1,600-record trace quadratic.
    // Exact-time metadata is retained separately only for terminal milestones and the inclusive
    // chart-end boundary, where the display semantics intentionally allow the same sample to be
    // described by adjacent zero-width milestones.
    var exactMetadataDates = Set(states.lazy.compactMap { state -> Date? in
        state.phase?.isTerminal == true ? state.at : nil
    })
    exactMetadataDates.insert(end)
    var metadata: [AgentActivityRecord] = []
    metadata.reserveCapacity(ordered.count / 2)
    var exactMetadata: [Date: AgentActivityTraceMetadata] = [:]
    for record in ordered where record.kind == .tokens || record.kind == .tool {
        metadata.append(record)
        if exactMetadataDates.contains(record.at) {
            exactMetadata[record.at, default: AgentActivityTraceMetadata()].add(record)
        }
    }

    var metadataIndex = 0
    var spans: [AgentActivityTraceSpan] = []
    spans.reserveCapacity(states.count)
    for (index, state) in states.enumerated() {
        guard let phase = state.phase, !absorbedStateIndices.contains(index) else { continue }
        let rawStart = state.at
        let rawEnd: Date
        if let compaction = compactionSpanEnds[index] {
            rawEnd = compaction.end
        } else {
            var next = index + 1
            while next < states.count, absorbedStateIndices.contains(next) { next += 1 }
            rawEnd = next < states.count ? states[next].at : end
        }
        if phase.isTerminal {
            guard rawStart >= start && rawStart <= end else { continue }
        } else {
            guard rawEnd >= start && rawStart <= end else { continue }
        }
        let spanStart = min(end, max(start, rawStart))
        let spanEnd = phase.isTerminal
            ? spanStart
            : min(end, max(spanStart, rawEnd))

        var enclosed = AgentActivityTraceMetadata()
        if phase.isTerminal {
            enclosed = exactMetadata[state.at] ?? AgentActivityTraceMetadata()
        } else {
            while metadataIndex < metadata.count, metadata[metadataIndex].at < spanStart {
                metadataIndex += 1
            }
            while metadataIndex < metadata.count, metadata[metadataIndex].at < spanEnd {
                enclosed.add(metadata[metadataIndex])
                metadataIndex += 1
            }
            if spanEnd == end, let atEnd = exactMetadata[end] {
                enclosed.add(atEnd)
            }
        }

        spans.append(AgentActivityTraceSpan(
            id: state.id,
            start: spanStart,
            end: spanEnd,
            phase: phase,
            title: traceSpanTitle(
                phase: phase,
                detail: state.detail,
                tools: enclosed.toolNames,
                tokens: enclosed.tokens,
                compaction: compactionSpanEnds[index]?.boundary),
            detail: activitySingleLine(state.detail ?? ""),
            tokens: enclosed.tokens,
            toolNames: enclosed.toolNames,
            sourceCount: 1))
    }
    return spans
}

/// At a full-turn zoom level, many short calls can fall within a few screen pixels. Merge only spans
/// that are genuinely too narrow to read, and split them again automatically as the user zooms in.
/// This is display aggregation only; the persisted event ledger remains exact.
///
/// Three rules keep aggregation from destroying the thing the trace exists to show:
///
///  1. **Adjacency.** Candidates must be neighbours in the whole ordered sequence, not merely the
///     next span of the same phase. A turn alternates model → tool → model, so merging "the next
///     model span" collapses straight across the intervening tool call. That is what turned a real
///     run of 35 requests into one unbroken bar labelled `Model activity ×35`, erasing every tool
///     boundary and the pacing between them.
///  2. **Legibility.** A span wide enough to carry its own label is never swallowed by its neighbour.
///  3. **A width ceiling.** A merged run stops growing at `maximumMergedFraction` of the track. Past
///     that a bar has stopped describing anything; it just says "busy".
func agentActivityCoalescedTraceSpans(
    _ spans: [AgentActivityTraceSpan],
    start: Date,
    end: Date,
    width: CGFloat,
    maximumGapPixels: CGFloat = 5,
    minimumLegibleWidth: CGFloat = traceSpanLabelMinimumWidth,
    maximumMergedFraction: CGFloat = 0.4
) -> [AgentActivityTraceSpan] {
    let duration = max(0.001, end.timeIntervalSince(start))
    let trackWidth = max(1, width)
    let mergeablePhases: Set<AgentActivityPhase> = [.model, .tool]
    func pixels(_ seconds: TimeInterval) -> CGFloat {
        CGFloat(seconds / duration) * trackWidth
    }

    // Terminal milestones are zero-duration points; they neither merge nor separate their neighbours.
    let milestones = spans.filter { $0.phase.isTerminal }
    let ordered = spans.filter { !$0.phase.isTerminal }.sorted {
        if $0.start != $1.start { return $0.start < $1.start }
        return traceTrackY($0.phase) < traceTrackY($1.phase)
    }

    var merged: [AgentActivityTraceSpan] = []
    for span in ordered {
        guard var previous = merged.last,
              mergeablePhases.contains(span.phase),
              previous.phase == span.phase else {
            merged.append(span)
            continue
        }
        let gap = max(0, span.start.timeIntervalSince(previous.end))
        let mergedWidth = pixels(max(previous.end, span.end).timeIntervalSince(previous.start))
        guard pixels(gap) <= maximumGapPixels,
              pixels(span.duration) < minimumLegibleWidth,
              pixels(previous.duration) < minimumLegibleWidth || previous.sourceCount > 1,
              mergedWidth <= trackWidth * maximumMergedFraction else {
            merged.append(span)
            continue
        }
        previous.end = max(previous.end, span.end)
        previous.tokens.add(span.tokens)
        previous.toolNames = deduplicatedStrings(previous.toolNames + span.toolNames)
        previous.sourceCount += span.sourceCount
        previous.detail = "Aggregated at this zoom; zoom in to inspect individual spans"
        previous.title = aggregatedTraceTitle(previous)
        merged[merged.count - 1] = previous
    }
    return (merged + milestones).sorted {
        if $0.start != $1.start { return $0.start < $1.start }
        return traceTrackY($0.phase) < traceTrackY($1.phase)
    }
}

struct AgentActivityUsageBucket: Identifiable, Equatable {
    var index: Int
    var start: Date
    var end: Date
    var tokens: AgentActivityTokenBreakdown

    var id: Int { index }
}

/// Fixed-duration buckets make dense provider samples comparable without implying that one sample
/// occupied an entire model/tool interval. Alias resolution keeps reconciled child identities in
/// the same bucket and allows the Usage view to filter by the A1/A2 lane shown on agent cards.
func agentActivityUsageBuckets(
    _ records: [AgentActivityRecord],
    start: Date,
    end: Date,
    count requestedCount: Int,
    agentID: String? = nil,
    aliases: [String: String] = [:]
) -> [AgentActivityUsageBucket] {
    let maximum = max(1, requestedCount)
    let duration = max(0.001, end.timeIntervalSince(start))
    // Bucket at a QUANTIZED width anchored to `start`, never at `duration / count`.
    //
    // Dividing the elapsed span into a fixed number of buckets re-bins every record each time the
    // trace extends: a token event sitting in bucket 40 is in bucket 39 a moment later, because the
    // boundaries themselves moved. On screen the bars slide left while the turn is still running
    // forwards, which reads as the graph going backwards.
    //
    // A quantized width holds a record in one bucket for as long as that width applies. When the
    // span outgrows it the width doubles, so bars merge exactly two-into-one instead of drifting to
    // new positions.
    let width = agentActivityUsageBucketWidth(forDuration: duration, maximum: maximum)
    let count = max(1, min(maximum, Int(ceil(duration / width))))
    var buckets = (0..<count).map { index in
        let bucketStart = start.addingTimeInterval(Double(index) * width)
        return AgentActivityUsageBucket(
            index: index,
            start: bucketStart,
            // Only the last bucket is clipped to the span, so the in-progress bucket grows at the
            // leading edge while every completed one keeps the width it was drawn with.
            end: index == count - 1
                ? max(bucketStart, end)
                : bucketStart.addingTimeInterval(width),
            tokens: AgentActivityTokenBreakdown())
    }
    for record in agentActivityEffectiveTokenRecords(records) where record.kind == .tokens {
        let canonicalID = aliases[record.agentID] ?? record.agentID
        guard agentID == nil || canonicalID == agentID else { continue }
        guard record.at >= start && record.at <= end else { continue }
        let index = min(count - 1, max(0, Int(floor(record.at.timeIntervalSince(start) / width))))
        buckets[index].tokens.add(record)
    }
    return buckets
}

/// The bucket width for a span, quantized so it only ever doubles.
///
/// Exposed rather than inlined because the stability this provides is the whole point: a test can
/// assert that a record keeps its bucket as the span grows, which is what a continuously-derived
/// width cannot offer.
func agentActivityUsageBucketWidth(
    forDuration duration: TimeInterval,
    maximum: Int
) -> TimeInterval {
    let target = max(0.001, duration) / Double(max(1, maximum))
    var width: TimeInterval = 0.25
    while width < target { width *= 2 }
    return width
}


/// Points per second at scale 1×. Chosen so an ordinary two-second call is wide enough to carry its
/// own label; everything else follows from powers of two around it.
let traceBasePointsPerSecond: CGFloat = 18


func activityPhaseLabel(_ phase: AgentActivityPhase) -> String {
    switch phase {
    case .model: return "Model"
    case .tool: return "Tool"
    case .waiting: return "Waiting"
    case .compacting: return "Compacting"
    case .completed: return "Completed"
    case .failed: return "Failed"
    case .stopped: return "Stopped"
    }
}


func activitySingleLine(_ value: String) -> String? {
    let collapsed = value
        .split(whereSeparator: { $0.isWhitespace })
        .joined(separator: " ")
    return collapsed.isEmpty ? nil : String(collapsed.prefix(512))
}

private func deduplicatedStrings(_ values: [String]) -> [String] {
    var seen: Set<String> = []
    return values.filter { seen.insert($0).inserted }
}

private func traceSpanTitle(
    phase: AgentActivityPhase,
    detail: String?,
    tools: [String],
    tokens: AgentActivityTokenBreakdown = AgentActivityTokenBreakdown(),
    compaction: AgentActivityRecord? = nil
) -> String {
    let normalizedDetail = detail.flatMap(activitySingleLine)
    switch phase {
    case .model:
        // The lane's colour already says "model". Repeating the runtime's internal state name on top
        // of it was noise at best, and for "Tool finished" it actively contradicted the colour — a
        // blue bar that claims to be about a tool. Say what the model produced instead, and stay
        // silent when there is nothing to report rather than inventing a word.
        var parts: [String] = []
        if let normalizedDetail, isDistinctiveModelDetail(normalizedDetail) {
            parts.append(normalizedDetail)
        }
        // Below a magnitude suffix a bare count reads as a span count next to the "×N" aggregates.
        if tokens.generated >= 1_000 {
            parts.append("\(formatTokens(tokens.generated)) out")
        }
        return parts.joined(separator: " · ")
    case .tool:
        if tools.count == 1 { return traceToolLabel(tools[0]) }
        if tools.count > 1 { return "Tools ×\(tools.count)" }
        return normalizedDetail.map(traceToolLabel) ?? "Tool"
    case .waiting:
        return normalizedDetail ?? "Waiting"
    case .compacting:
        // The bar now carries the compaction's real duration, so it has room for the one fact the
        // duration cannot express. Codex reports the boundary without counts, so an unreported
        // before/after stays absent rather than becoming a fictional zero.
        if let compaction,
           compaction.compactionError == nil,
           let before = compaction.compactionPreTokens,
           let after = compaction.compactionPostTokens {
            return "Summarized earlier messages · \(formatTokens(before)) → \(formatTokens(after))"
        }
        if compaction?.compactionError != nil { return "Couldn’t summarize earlier messages" }
        return "Summarized earlier messages"
    case .completed:
        return "Completed"
    case .failed:
        return "Failed"
    case .stopped:
        return "Stopped"
    }
}

/// State details that only restate "the model is running", which the lane colour already conveys.
/// "Tool finished" was the worst of them: it named the *previous* event, so a blue model bar read as
/// a tool. Anything genuinely distinctive — reasoning, delegation — still earns its label.
/// A label is only worth the pixels if it says something the mark does not. "Model call" on a bar
/// already coloured as the model phase is the word for the bar — and it slipped through because the
/// set held `model` while the producer emits `Model call`.
private let uninformativeModelDetails: Set<String> = [
    "responding", "turn started", "tool finished", "working", "model", "model call",
    "model response", "thinking", "assistant",
]

private func isDistinctiveModelDetail(_ detail: String) -> Bool {
    !uninformativeModelDetails.contains(detail.lowercased())
}

func traceToolLabel(_ name: String) -> String {
    traceToolDisplayName(toolName: name, target: nil)
}

private func aggregatedTraceTitle(_ span: AgentActivityTraceSpan) -> String {
    guard span.sourceCount > 1 else { return span.title }
    switch span.phase {
    case .tool:
        if span.toolNames.count == 1 {
            return "\(traceToolLabel(span.toolNames[0])) ×\(span.sourceCount)"
        }
        return "Tools ×\(span.sourceCount)"
    case .model:
        return "Model ×\(span.sourceCount)"
    default:
        return "\(span.title) ×\(span.sourceCount)"
    }
}

/// Below this a span cannot carry readable text, so it is drawn as an unlabelled block and explains
/// itself on hover instead. This remains the zoom-coalescing heuristic; actual label drawing uses
/// the measured title width through `traceSpanLabelPlacement`.
let traceSpanLabelMinimumWidth: CGFloat = 30

enum TraceSpanLabelPlacement: Equatable {
    case inside
    case hidden
}

/// A trace title is safe only when the complete measured string, plus its inset on both sides, fits
/// inside its own mark. A hidden title remains present in inspection, tooltips, keyboard navigation,
/// and accessibility; it is never moved beside a narrow bar where it can collide with the next mark.
func traceSpanLabelPlacement(
    textWidth: CGFloat,
    spanWidth: CGFloat,
    horizontalPadding: CGFloat = 8
) -> TraceSpanLabelPlacement {
    guard textWidth.isFinite,
          spanWidth.isFinite,
          horizontalPadding.isFinite,
          textWidth >= 0,
          spanWidth >= 0,
          horizontalPadding >= 0 else {
        return .hidden
    }
    return textWidth + horizontalPadding <= spanWidth ? .inside : .hidden
}

/// Condense an agent's task into a lane-width name, cutting on a word boundary so the label reads as
/// words rather than a severed sentence. The full task stays available in the row detail and tooltip.
func traceLaneTaskSummary(_ task: String, limit: Int = 26) -> String {
    let trimmed = task.trimmingCharacters(in: .whitespacesAndNewlines)
    guard trimmed.count > limit else { return trimmed }
    let clipped = trimmed.prefix(limit)
    let cut = clipped.lastIndex(of: " ").map { clipped[clipped.startIndex..<$0] } ?? clipped
    let word = cut.trimmingCharacters(in: CharacterSet(charactersIn: " ,.;:-—"))
    return (word.isEmpty ? String(clipped) : word) + "…"
}

private func traceTrackY(_ phase: AgentActivityPhase) -> CGFloat {
    phase == .model ? 17 : 41
}
