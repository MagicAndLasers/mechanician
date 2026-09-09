import Foundation

// MARK: - Provider harness wire normalization

private enum AgentHarnessWireBounds {
    static let maximumMetricSamples = 512
    static let maximumRateLimitBuckets = 16
    static let maximumDailyBuckets = 366
    static let maximumCount = 1_000_000
    static let maximumMetricCount = 1_000_000_000_000
    static let maximumEpochSeconds = 10_000_000_000
}

private let agentHarnessClaudeRuntimeMetricNames: Set<String> = [
    "claude_code.session.count",
    "claude_code.lines_of_code.count",
    "claude_code.pull_request.count",
    "claude_code.commit.count",
    "claude_code.cost.usage",
    "claude_code.token.usage",
    "claude_code.code_edit_tool.decision",
    "claude_code.active_time.total",
]

private let agentHarnessCodexRuntimeMetricFamilies: Set<String> = [
    "codex.api.request", "codex.sse.event", "codex.websocket", "codex.responses.api",
    "codex.transport", "codex.remote.models", "codex.startup.prewarm",
    "codex.cloud.requirements", "codex.turn", "codex.conversation.turn", "codex.tool",
    "codex.approval", "codex.mcp", "codex.hooks", "codex.skill", "codex.skills",
    "codex.plugin", "codex.plugins", "codex.memory", "codex.memories", "codex.task.compact",
    "codex.compaction", "codex.multi.agent", "codex.state.db", "codex.db", "codex.sqlite",
    "codex.shell.snapshot", "codex.apps", "codex.thread.skills", "codex.thread.started",
    "codex.retry", "codex.process.start", "codex.guardian", "codex.exec.server",
    "codex.request", "codex.usage", "codex.rollout",
]

private let agentHarnessRuntimeMetricSemantics: Set<String> = [
    "bytes", "cost", "count", "decision", "duration", "e2e", "error", "event", "other",
    "ratio", "status", "tbt", "ttfm", "ttft", "tokens",
]

private let agentHarnessRuntimeMetricCategoryValues: Set<String> = [
    "accept", "accepted", "allowed", "api", "api_key", "approved", "assistant", "auto",
    "automatic", "blocked", "buffered", "cache_creation", "cache_read", "cached", "cancelled",
    "chatgpt", "child", "cli", "cold", "complete", "completed", "counter", "declined",
    "denied", "disabled", "dynamic", "enabled", "error", "event", "exhausted", "failed",
    "failure", "files", "gauge", "high", "histogram", "hit", "input", "interrupted", "local",
    "low", "manual", "max", "mcp", "media", "medium", "miss", "none", "oauth", "other",
    "output", "orchestration", "partial", "pending", "provider", "read", "reasoning",
    "recovered", "refused", "reject", "rejected", "remote", "request", "response", "retry",
    "root", "scheduled", "shell", "snapshot", "startup", "success", "system", "timed_out",
    "tool", "turn", "ultra", "uncached", "unknown", "user", "vertex", "warm", "web", "write",
    "xhigh", "claude", "codex", "gpt", "o_series",
]

private let agentHarnessRuntimeMetricModelValues: Set<String> = [
    "claude", "codex", "gpt", "o_series", "other",
]

private func agentHarnessRuntimeMetricName(_ value: Any?) -> String? {
    guard let name = agentHarnessWireToken(value, maximum: 160) else { return nil }
    if agentHarnessClaudeRuntimeMetricNames.contains(name) { return name }
    for family in agentHarnessCodexRuntimeMetricFamilies.sorted(by: { $0.count > $1.count }) {
        let prefix = "\(family)."
        guard name.hasPrefix(prefix) else { continue }
        let semantic = String(name.dropFirst(prefix.count))
        return agentHarnessRuntimeMetricSemantics.contains(semantic) ? name : nil
    }
    return nil
}

private func agentHarnessRuntimeMetricCategory(_ value: Any?) -> String? {
    guard let token = agentHarnessWireToken(value, maximum: 128),
          agentHarnessRuntimeMetricCategoryValues.contains(token)
    else { return nil }
    return token
}

/// Decode one turn-scoped, content-free provider-harness observation.
///
/// The daemon has already reduced provider payloads to a closed vocabulary, but this is a second
/// trust boundary: only explicitly named fields are copied, every scalar is bounded again, and
/// prompt/response text, paths, commands, provider error prose, and opaque provider ids are never
/// inspected. The array return leaves room for a wire observation to normalize into multiple
/// established activity kinds without adding another persisted `AgentActivityKind` case.
func agentHarnessActivityRecords(
    from event: [String: Any],
    receivedAt: Date = Date(),
    expectedLane: AgentHarnessLaneID? = nil
) -> [AgentActivityRecord] {
    guard event["type"] as? String == "harness_observation",
          let turnID = agentHarnessWireToken(event["id"], maximum: 160),
          let rawLane = event["lane"] as? String,
          let lane = AgentHarnessLaneID(rawValue: rawLane),
          let rawEvent = event["event"] as? String,
          let eventKind = AgentHarnessEventKind(rawValue: rawEvent),
          let rawProvenance = event["provenance"] as? String,
          let provenance = AgentMeasurementProvenance(rawValue: rawProvenance),
          expectedLane == nil || expectedLane == lane
    else { return [] }

    let observedAt = agentHarnessWireDate(event["at"]) ?? receivedAt
    let phase = (event["phase"] as? String).flatMap(AgentHarnessPhase.init(rawValue:))
    if eventKind == .phase, phase == nil { return [] }

    var record = AgentActivityRecord.harnessObservation(
        turnID: turnID,
        lane: lane,
        event: eventKind,
        phase: phase,
        provenance: provenance,
        at: observedAt)
    record.measurementScope = (event["scope"] as? String)
        .flatMap(AgentMeasurementScope.init(rawValue:))
    record.measurementAggregation = (event["aggregation"] as? String)
        .flatMap(AgentMeasurementAggregation.init(rawValue:))
    record.providerQuerySequence = agentHarnessBoundedCount(
        agentHarnessWireInteger(event["providerQuerySequence"])).flatMap { $0 > 0 ? $0 : nil }

    if let rawAgentID = agentHarnessWireToken(event["agentID"], maximum: 160) {
        record.agentID = rawAgentID == AgentActivityIdentity.root
            ? AgentActivityIdentity.root
            : AgentActivityIdentity.subagent(rawAgentID)
    }

    switch eventKind {
    case .phase:
        record.elapsedMs = agentHarnessDuration(agentHarnessWireInteger(event["elapsedMs"]))
        record.warm = agentHarnessWireBoolean(event["warm"])
        record.threadAction = (event["threadAction"] as? String)
            .flatMap(AgentHarnessThreadAction.init(rawValue:))
        record.outputKind = (event["outputKind"] as? String)
            .flatMap(AgentHarnessOutputKind.init(rawValue:))
        record.terminalOutcome = (event["terminalOutcome"] as? String)
            .flatMap(AgentHarnessTerminalOutcome.init(rawValue:))

    case .result:
        record.durationMs = agentHarnessDuration(agentHarnessWireInteger(event["durationMs"]))
        record.apiDurationMs = agentHarnessDuration(
            agentHarnessWireInteger(event["apiDurationMs"]))
        record.timeToFirstTokenMs = agentHarnessDuration(
            agentHarnessWireInteger(event["timeToFirstTokenMs"]))
        record.timeToFirstOutputMs = agentHarnessDuration(
            agentHarnessWireInteger(event["timeToFirstOutputMs"]))
        record.streamTimeToFirstOutputMs = agentHarnessDuration(
            agentHarnessWireInteger(event["streamTimeToFirstOutputMs"]))
        record.timeToRequestMs = agentHarnessDuration(
            agentHarnessWireInteger(event["timeToRequestMs"]))
        record.timeToRequestFromSpawnMs = agentHarnessDuration(
            agentHarnessWireInteger(event["timeToRequestFromSpawnMs"]))
        record.warm = agentHarnessWireBoolean(event["warm"])
        record.inputTokens = agentHarnessTokenCount(
            agentHarnessWireInteger(event["inputTokens"]))
        record.uncachedInputTokens = agentHarnessTokenCount(
            agentHarnessWireInteger(event["uncachedInputTokens"]))
        record.cachedInputTokens = agentHarnessTokenCount(
            agentHarnessWireInteger(event["cacheReadInputTokens"])
                ?? agentHarnessWireInteger(event["cachedInputTokens"]))
        record.cacheWriteInputTokens = agentHarnessTokenCount(
            agentHarnessWireInteger(event["cacheWriteInputTokens"]))
        record.outputTokens = agentHarnessTokenCount(
            agentHarnessWireInteger(event["outputTokens"]))
        record.reasoningOutputTokens = agentHarnessTokenCount(
            agentHarnessWireInteger(event["reasoningOutputTokens"]))
        record.totalTokens = agentHarnessTokenCount(
            agentHarnessWireInteger(event["totalTokens"]))
        // Claude's final result usage is provider-authoritative for one provider query. `modelUsage`
        // yields an agent-tree total; its absence leaves a request/root total. Keeping both in the
        // established token kind lets usage reconciliation replace only provisional samples from
        // the same provider-query sequence.
        if [
            record.inputTokens,
            record.uncachedInputTokens,
            record.cachedInputTokens,
            record.cacheWriteInputTokens,
            record.outputTokens,
            record.reasoningOutputTokens,
            record.totalTokens,
        ].contains(where: { $0 != nil }) {
            record.kind = .tokens
        }

    case .retry, .retryRecovered, .retryExhausted:
        record.retryDisposition = (event["retryDisposition"] as? String)
            .flatMap(AgentRetryDisposition.init(rawValue:))
        record.retryAttempt = agentHarnessBoundedCount(
            agentHarnessWireInteger(event["retryAttempt"]))
        record.retryAttempts = agentHarnessBoundedCount(
            agentHarnessWireInteger(event["retryAttempts"]))
        record.retryMaxAttempts = agentHarnessBoundedCount(
            agentHarnessWireInteger(event["retryMaxAttempts"]))
        record.retryDelayMs = agentHarnessDuration(
            agentHarnessWireInteger(event["retryDelayMs"]))
        record.retryWillContinue = agentHarnessWireBoolean(event["willContinue"])
            ?? agentHarnessWireBoolean(event["retryWillContinue"])
        record.errorKind = agentHarnessErrorKind(agentHarnessWireToken(event["errorKind"]))
        record.httpStatusCode = agentHarnessHTTPStatus(
            agentHarnessWireInteger(event["httpStatusCode"]))

    case .modelRerouted:
        record.rerouteOriginalModelID = agentHarnessWireLabel(event["originalModelID"])
        record.rerouteModelID = agentHarnessWireLabel(event["model"])
        record.rerouteReason = agentHarnessRerouteReason(
            agentHarnessWireToken(event["rerouteReason"]))

    case .modelSafety:
        record.safetyOutcome = (event["safetyOutcome"] as? String)
            .flatMap(AgentSafetyOutcome.init(rawValue:))
        record.safetyReasons = agentHarnessSafetyReasonValues(
            agentHarnessWireTokens(event["safetyReasons"]))
        record.safetyUseCases = agentHarnessSafetyUseCaseValues(
            agentHarnessWireTokens(event["safetyUseCases"]))
        record.safetyFasterModelID = agentHarnessWireLabel(event["fasterModel"])
        record.safetyShowsBufferingUI = agentHarnessWireBoolean(event["showBuffering"])

    case .modelVerification:
        record.modelVerifications = agentHarnessModelVerificationValues(
            agentHarnessWireTokens(event["modelVerifications"]))

    case .tool:
        record.toolUseID = agentHarnessWireToken(event["toolUseID"], maximum: 160)
        record.toolKind = (event["toolKind"] as? String)
            .flatMap(AgentHarnessToolKind.init(rawValue:))
        guard record.toolUseID != nil, record.toolKind != nil else { return [] }
        record.toolOutcome = (event["toolOutcome"] as? String)
            .flatMap(AgentHarnessToolOutcome.init(rawValue:))
        record.toolDurationMs = agentHarnessDuration(
            agentHarnessWireInteger(event["toolDurationMs"]))
        record.toolWaitDurationMs = agentHarnessDuration(
            agentHarnessWireInteger(event["toolWaitDurationMs"]))
        record.toolExecutionDurationMs = agentHarnessDuration(
            agentHarnessWireInteger(event["toolExecutionDurationMs"]))

    case .context:
        record.contextTokens = agentHarnessTokenCount(
            agentHarnessWireInteger(event["contextTokens"]))
        record.contextWindow = agentHarnessTokenCount(
            agentHarnessWireInteger(event["contextWindow"]))
        record.contextUsableWindowTokens = agentHarnessTokenCount(
            agentHarnessWireInteger(event["contextUsableWindow"])
                ?? agentHarnessWireInteger(event["contextUsableWindowTokens"]))
        record.contextRawWindowTokens = agentHarnessTokenCount(
            agentHarnessWireInteger(event["contextRawWindowTokens"]))
        record.contextComposition = agentHarnessWireContextComposition(
            event["contextComposition"])

    case .compaction:
        record.compactionTrigger = agentHarnessCompactionTrigger(
            agentHarnessWireToken(event["compactionTrigger"]))
        record.compactionPreTokens = agentHarnessTokenCount(
            agentHarnessWireInteger(event["compactionPreTokens"]))
        record.compactionPostTokens = agentHarnessTokenCount(
            agentHarnessWireInteger(event["compactionPostTokens"]))
        record.compactionDurationMs = agentHarnessDuration(
            agentHarnessWireInteger(event["compactionDurationMs"]))
        // Only a closed error kind is safe. Provider-authored compaction prose is omitted.
        record.compactionError = agentHarnessErrorKind(
            agentHarnessWireToken(event["compactionErrorKind"]))
        record.compactionSequence = agentHarnessBoundedCount(
            agentHarnessWireInteger(event["compactionSequence"])).flatMap { $0 > 0 ? $0 : nil }

    case .internalError:
        record.errorKind = agentHarnessErrorKind(agentHarnessWireToken(event["errorKind"]))

    case .permission, .hook, .mcpConnection, .interrupt:
        break
    }

    return [record]
}

/// Decode short-lived provider-wide runtime metrics, including safe account-usage aggregates.
/// These samples never inherit a turn id: OTLP batches and account snapshots are not turn truth.
func agentHarnessMetricSamples(
    from event: [String: Any],
    receivedAt: Date = Date()
) -> [HarnessMetricSample] {
    agentHarnessMetricBatch(from: event, receivedAt: receivedAt)?.samples ?? []
}

struct AgentHarnessMetricBatch: Equatable {
    var samples: [HarnessMetricSample]
    var accountFamily: HarnessMetricAccountFamily?
    var replacesAccountFamily: Bool
}

/// Retain snapshot completeness even when the decoded sample list is empty. The bridge needs that
/// boundary to remove gauges which a complete account response no longer contains.
func agentHarnessMetricBatch(
    from event: [String: Any],
    receivedAt: Date = Date()
) -> AgentHarnessMetricBatch? {
    switch event["type"] as? String {
    case "harness_metrics":
        return AgentHarnessMetricBatch(
            samples: agentHarnessRuntimeMetricSamples(from: event, receivedAt: receivedAt),
            accountFamily: nil,
            replacesAccountFamily: false)
    case "harness_account_usage":
        return agentHarnessAccountMetricBatch(from: event, receivedAt: receivedAt)
    default:
        return nil
    }
}

// MARK: - Runtime metrics

private func agentHarnessRuntimeMetricSamples(
    from event: [String: Any],
    receivedAt: Date
) -> [HarnessMetricSample] {
    guard let rawSamples = event["samples"] as? [Any] else { return [] }
    let provider = agentHarnessWireToken(event["provider"])
    var result: [HarnessMetricSample] = []
    result.reserveCapacity(min(rawSamples.count, AgentHarnessWireBounds.maximumMetricSamples))

    for rawSample in rawSamples.prefix(AgentHarnessWireBounds.maximumMetricSamples) {
        guard let sample = rawSample as? [String: Any],
              let name = agentHarnessRuntimeMetricName(sample["name"]),
              let rawKind = sample["kind"] as? String,
              let kind = HarnessMetricKind(rawValue: rawKind),
              let lane = agentHarnessMetricLane(name: name, provider: provider)
        else { continue }

        let unit = agentHarnessMetricUnit(raw: sample["unit"] as? String, name: name)
        let at = agentHarnessWireDate(sample["at"]) ?? receivedAt
        let value = agentHarnessWireDouble(sample["value"])
        let count = agentHarnessWireInteger(
            sample["count"], maximum: AgentHarnessWireBounds.maximumMetricCount)
        let sum = agentHarnessWireDouble(sample["sum"])
        let minimum = agentHarnessWireDouble(sample["minimum"])
            ?? agentHarnessWireDouble(sample["min"])
        let maximum = agentHarnessWireDouble(sample["maximum"])
            ?? agentHarnessWireDouble(sample["max"])
        let attributes = agentHarnessMetricAttributes(sample["attributes"], lane: lane)

        if let normalized = HarnessMetricSample(
            name: name,
            kind: kind,
            at: at,
            unit: unit,
            harnessLaneID: lane,
            value: value,
            count: count,
            sum: sum,
            min: minimum,
            max: maximum,
            attributes: attributes) {
            result.append(normalized)
        }
    }
    return result
}

private func agentHarnessMetricLane(
    name: String,
    provider: String?
) -> AgentHarnessLaneID? {
    if name.hasPrefix("claude_code.") { return .claude }
    if name.hasPrefix("codex.") { return .codex }
    switch provider {
    case "claude", "anthropic": return .claude
    case "codex": return .codex
    case "openai": return .openAI
    default: return nil
    }
}

private func agentHarnessMetricUnit(raw: String?, name: String) -> HarnessMetricUnit {
    let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
    if raw == HarnessMetricUnit.unixSeconds.rawValue { return .unixSeconds }
    if raw == "ms" || raw.contains("millisecond") { return .milliseconds }
    if raw == "s" || raw.contains("second") { return .seconds }
    if raw.contains("token") { return .tokens }
    if raw == "by" || raw.contains("byte") { return .bytes }
    if raw == "usd" || raw.contains("dollar") { return .usd }
    if raw == "%" || raw.contains("percent") { return .percent }
    if raw.contains("ratio") { return .ratio }
    if raw.contains("line") { return .lines }
    if raw == "1" || raw.contains("count") || (raw.hasPrefix("{") && raw.hasSuffix("}")) {
        return .count
    }

    let lowerName = name.lowercased()
    if lowerName.contains("resets_at") || lowerName.contains("unix_seconds") {
        return .unixSeconds
    }
    if lowerName.contains("duration_ms") || lowerName.hasSuffix("_ms")
        || lowerName.contains(".duration.ms") || lowerName.hasSuffix(".ms")
        || lowerName.hasSuffix(".duration") || lowerName.contains(".ttft")
        || lowerName.contains(".ttfm") || lowerName.contains(".tbt")
        || lowerName.contains(".e2e") {
        return .milliseconds
    }
    if lowerName.contains("active_time") || lowerName.contains("duration_seconds") {
        return .seconds
    }
    if lowerName.contains("token") { return .tokens }
    if lowerName.contains("cost") { return .usd }
    if lowerName.contains("byte") { return .bytes }
    if lowerName.contains("line") { return .lines }
    if lowerName.contains("percent") { return .percent }
    if lowerName.contains("ratio") { return .ratio }
    return .count
}

private func agentHarnessMetricAttributes(
    _ value: Any?,
    lane: AgentHarnessLaneID?
) -> [HarnessMetricAttributeKey: HarnessMetricAttributeValue] {
    let raw = value as? [String: Any] ?? [:]
    var result: [HarnessMetricAttributeKey: HarnessMetricAttributeValue] = [:]
    if let lane { result[.provider] = .string(lane.rawValue) }

    func putCategory(_ rawKey: String, _ key: HarnessMetricAttributeKey) {
        guard result[key] == nil, let token = agentHarnessRuntimeMetricCategory(raw[rawKey])
        else { return }
        result[key] = .string(token)
    }
    func putModel(_ rawKey: String, _ key: HarnessMetricAttributeKey) {
        guard result[key] == nil,
              let label = agentHarnessWireToken(raw[rawKey], maximum: 128),
              agentHarnessRuntimeMetricModelValues.contains(label)
        else { return }
        result[key] = .string(label)
    }
    func putBoolean(_ rawKey: String, _ key: HarnessMetricAttributeKey) {
        guard result[key] == nil, let flag = agentHarnessWireBoolean(raw[rawKey]) else { return }
        result[key] = .bool(flag)
    }
    func putNumber(_ rawKey: String, _ key: HarnessMetricAttributeKey) {
        guard result[key] == nil, let number = agentHarnessWireDouble(raw[rawKey]) else { return }
        result[key] = .number(number)
    }

    putModel("model", .model)
    putCategory("auth_mode", .access)
    putCategory("status", .status)
    putNumber("http.response.status_code", .status)
    putCategory("outcome", .outcome)
    putCategory("decision", .outcome)
    putCategory("terminal.type", .outcome)
    putCategory("source", .querySource)
    putCategory("session_source", .querySource)
    putCategory("originator", .querySource)
    putCategory("tool", .toolKind)
    putCategory("tool_name", .toolKind)
    putCategory("reason", .errorKind)
    putNumber("attempt", .retryAttempt)
    putBoolean("success", .success)
    putBoolean("cache", .cached)
    putCategory("kind", .event)
    putCategory("type", .event)
    putCategory("trigger", .event)
    putCategory("hook_name", .event)
    putCategory("token_type", .scope)
    return result
}

// MARK: - Account usage

private func agentHarnessAccountMetricBatch(
    from event: [String: Any],
    receivedAt: Date
) -> AgentHarnessMetricBatch? {
    guard event["provider"] as? String == "codex",
          let kind = event["kind"] as? String,
          event["provenance"] as? String == AgentMeasurementProvenance.providerReport.rawValue
    else { return nil }

    let source = event["source"] as? String == "notification" ? "notification" : "read"
    switch kind {
    case "rate_limits":
        return AgentHarnessMetricBatch(
            samples: agentHarnessRateLimitMetricSamples(
                from: event, source: source, receivedAt: receivedAt),
            accountFamily: .rateLimits,
            replacesAccountFamily: agentHarnessWireBoolean(event["complete"]) == true)
    case "token_usage":
        // Token-usage reads were complete snapshots before the daemon grew an explicit marker.
        // Preserve that safe compatibility while refusing malformed present markers as complete.
        let complete = event["complete"].map { agentHarnessWireBoolean($0) == true } ?? true
        return AgentHarnessMetricBatch(
            samples: agentHarnessAccountTokenMetricSamples(
                from: event, source: source, receivedAt: receivedAt),
            accountFamily: .tokenUsage,
            replacesAccountFamily: complete)
    default:
        return nil
    }
}

private func agentHarnessAccountAttributes(
    source: String,
    status: String? = nil,
    scope: String = "account"
) -> [HarnessMetricAttributeKey: HarnessMetricAttributeValue] {
    var attributes: [HarnessMetricAttributeKey: HarnessMetricAttributeValue] = [
        .provider: .string(AgentHarnessLaneID.codex.rawValue),
        .provenance: .string(AgentMeasurementProvenance.providerReport.rawValue),
        .querySource: .string(source),
        .event: .string(AgentMeasurementAggregation.snapshot.rawValue),
        .scope: .string(scope),
    ]
    if let status { attributes[.status] = .string(status) }
    return attributes
}

private func agentHarnessAppendGauge(
    name: String,
    value: Double?,
    unit: HarnessMetricUnit,
    at: Date,
    attributes: [HarnessMetricAttributeKey: HarnessMetricAttributeValue],
    to samples: inout [HarnessMetricSample]
) {
    guard let value,
          let sample = HarnessMetricSample(
              name: name,
              kind: .gauge,
              at: at,
              unit: unit,
              harnessLaneID: .codex,
              value: value,
              attributes: attributes)
    else { return }
    samples.append(sample)
}

private func agentHarnessRateLimitMetricSamples(
    from event: [String: Any],
    source: String,
    receivedAt: Date
) -> [HarnessMetricSample] {
    let complete = agentHarnessWireBoolean(event["complete"]) == true
    let attributes = agentHarnessAccountAttributes(
        source: source, status: complete ? "complete" : "partial")
    let buckets = (event["buckets"] as? [Any] ?? [])
        .prefix(AgentHarnessWireBounds.maximumRateLimitBuckets)

    var primaryUsed: [Int] = []
    var secondaryUsed: [Int] = []
    var individualRemaining: [Int] = []
    var primaryWindows: [Int] = []
    var secondaryWindows: [Int] = []
    var primaryResets: [Int] = []
    var secondaryResets: [Int] = []
    var individualResets: [Int] = []
    var hasCredits: [Bool] = []
    var unlimitedCredits: [Bool] = []
    var spendControlReached: [Bool] = []
    var rateLimitReached: [Bool] = []

    for rawBucket in buckets {
        guard let bucket = rawBucket as? [String: Any] else { continue }
        if let primary = bucket["primary"] as? [String: Any] {
            if let value = agentHarnessWireInteger(primary["usedPercent"], maximum: 100) {
                primaryUsed.append(value)
            }
            if let value = agentHarnessWireInteger(
                primary["windowDurationMins"], maximum: AgentHarnessWireBounds.maximumCount) {
                primaryWindows.append(value)
            }
            if let value = agentHarnessWireInteger(
                primary["resetsAt"], maximum: AgentHarnessWireBounds.maximumEpochSeconds) {
                primaryResets.append(value)
            }
        }
        if let secondary = bucket["secondary"] as? [String: Any] {
            if let value = agentHarnessWireInteger(secondary["usedPercent"], maximum: 100) {
                secondaryUsed.append(value)
            }
            if let value = agentHarnessWireInteger(
                secondary["windowDurationMins"], maximum: AgentHarnessWireBounds.maximumCount) {
                secondaryWindows.append(value)
            }
            if let value = agentHarnessWireInteger(
                secondary["resetsAt"], maximum: AgentHarnessWireBounds.maximumEpochSeconds) {
                secondaryResets.append(value)
            }
        }
        if let individual = bucket["individualLimit"] as? [String: Any] {
            if let value = agentHarnessWireInteger(individual["remainingPercent"], maximum: 100) {
                individualRemaining.append(value)
            }
            if let value = agentHarnessWireInteger(
                individual["resetsAt"], maximum: AgentHarnessWireBounds.maximumEpochSeconds) {
                individualResets.append(value)
            }
        }
        if let credits = bucket["credits"] as? [String: Any] {
            if let value = agentHarnessWireBoolean(credits["hasCredits"]) {
                hasCredits.append(value)
            }
            if let value = agentHarnessWireBoolean(credits["unlimited"]) {
                unlimitedCredits.append(value)
            }
        }
        if let value = agentHarnessWireBoolean(bucket["spendControlReached"]) {
            spendControlReached.append(value)
        }
        if let value = agentHarnessWireBoolean(bucket["rateLimitReached"]) {
            rateLimitReached.append(value)
        }
    }

    var samples: [HarnessMetricSample] = []
    func append(_ name: String, _ value: Double?, _ unit: HarnessMetricUnit) {
        agentHarnessAppendGauge(
            name: name,
            value: value,
            unit: unit,
            at: receivedAt,
            attributes: attributes,
            to: &samples)
    }
    append(
        "codex.account.rate_limits.bucket_count",
        agentHarnessWireInteger(
            event["bucketCount"], maximum: AgentHarnessWireBounds.maximumCount).map(Double.init),
        .count)
    append(
        "codex.account.rate_limits.primary.used_percent.max",
        primaryUsed.max().map(Double.init),
        .percent)
    append(
        "codex.account.rate_limits.secondary.used_percent.max",
        secondaryUsed.max().map(Double.init),
        .percent)
    append(
        "codex.account.rate_limits.individual.remaining_percent.min",
        individualRemaining.min().map(Double.init),
        .percent)
    append(
        "codex.account.rate_limits.primary.window_seconds.max",
        primaryWindows.max().map { Double($0) * 60 },
        .seconds)
    append(
        "codex.account.rate_limits.secondary.window_seconds.max",
        secondaryWindows.max().map { Double($0) * 60 },
        .seconds)
    append(
        "codex.account.rate_limits.primary.resets_at.earliest",
        primaryResets.min().map(Double.init),
        .unixSeconds)
    append(
        "codex.account.rate_limits.secondary.resets_at.earliest",
        secondaryResets.min().map(Double.init),
        .unixSeconds)
    append(
        "codex.account.rate_limits.individual.resets_at.earliest",
        individualResets.min().map(Double.init),
        .unixSeconds)
    if !hasCredits.isEmpty {
        append("codex.account.rate_limits.credits.has_credits.any", hasCredits.contains(true) ? 1 : 0, .count)
    }
    if !unlimitedCredits.isEmpty {
        append("codex.account.rate_limits.credits.unlimited.any", unlimitedCredits.contains(true) ? 1 : 0, .count)
    }
    if !spendControlReached.isEmpty {
        append(
            "codex.account.rate_limits.spend_control_reached.any",
            spendControlReached.contains(true) ? 1 : 0,
            .count)
    }
    if !rateLimitReached.isEmpty {
        append(
            "codex.account.rate_limits.reached.any",
            rateLimitReached.contains(true) ? 1 : 0,
            .count)
    }
    append(
        "codex.account.rate_limits.reset_credits.available",
        agentHarnessWireInteger(
            event["resetCreditsAvailable"],
            maximum: AgentHarnessWireBounds.maximumCount).map(Double.init),
        .count)
    return Array(samples.prefix(AgentHarnessWireBounds.maximumMetricSamples))
}

private func agentHarnessAccountTokenMetricSamples(
    from event: [String: Any],
    source: String,
    receivedAt: Date
) -> [HarnessMetricSample] {
    let attributes = agentHarnessAccountAttributes(source: source)
    let summary = event["summary"] as? [String: Any] ?? [:]
    var samples: [HarnessMetricSample] = []
    func appendSummary(
        _ rawKey: String,
        name: String,
        unit: HarnessMetricUnit,
        maximum: Int = 4_000_000_000
    ) {
        agentHarnessAppendGauge(
            name: name,
            value: agentHarnessWireInteger(summary[rawKey], maximum: maximum).map(Double.init),
            unit: unit,
            at: receivedAt,
            attributes: attributes,
            to: &samples)
    }
    appendSummary("lifetimeTokens", name: "codex.account.tokens.lifetime", unit: .tokens)
    appendSummary("peakDailyTokens", name: "codex.account.tokens.daily.peak", unit: .tokens)
    appendSummary(
        "longestRunningTurnSec", name: "codex.account.turn.longest_running", unit: .seconds)
    appendSummary(
        "currentStreakDays",
        name: "codex.account.streak.current_days",
        unit: .count,
        maximum: AgentHarnessWireBounds.maximumCount)
    appendSummary(
        "longestStreakDays",
        name: "codex.account.streak.longest_days",
        unit: .count,
        maximum: AgentHarnessWireBounds.maximumCount)

    agentHarnessAppendGauge(
        name: "codex.account.tokens.daily.bucket_count",
        value: agentHarnessWireInteger(
            event["dailyBucketCount"],
            maximum: AgentHarnessWireBounds.maximumCount).map(Double.init),
        unit: .count,
        at: receivedAt,
        attributes: attributes,
        to: &samples)

    let dailyAttributes = agentHarnessAccountAttributes(source: source, scope: "account_daily")
    var dailyValues: [String: Int] = [:]
    for rawBucket in (event["dailyUsage"] as? [Any] ?? [])
        .prefix(AgentHarnessWireBounds.maximumDailyBuckets) {
        guard let bucket = rawBucket as? [String: Any],
              let startDate = agentHarnessWireDay(bucket["startDate"]),
              let tokens = agentHarnessTokenCount(agentHarnessWireInteger(bucket["tokens"]))
        else { continue }
        dailyValues[startDate] = tokens
    }
    for startDate in dailyValues.keys.sorted() {
        agentHarnessAppendGauge(
            name: "codex.account.tokens.daily.\(startDate)",
            value: dailyValues[startDate].map(Double.init),
            unit: .tokens,
            at: receivedAt,
            attributes: dailyAttributes,
            to: &samples)
    }
    return Array(samples.prefix(AgentHarnessWireBounds.maximumMetricSamples))
}

// MARK: - Strict scalar helpers

private func agentHarnessWireNumber(_ value: Any?) -> NSNumber? {
    guard let number = value as? NSNumber,
          CFGetTypeID(number) != CFBooleanGetTypeID(),
          number.doubleValue.isFinite
    else { return nil }
    return number
}

private func agentHarnessWireInteger(
    _ value: Any?,
    maximum: Int = Int.max
) -> Int? {
    guard maximum >= 0, let number = agentHarnessWireNumber(value) else { return nil }
    let double = number.doubleValue
    guard let integer = Int(exactly: double), integer >= 0, integer <= maximum else { return nil }
    return integer
}

private func agentHarnessWireDouble(_ value: Any?) -> Double? {
    guard let number = agentHarnessWireNumber(value) else { return nil }
    let double = number.doubleValue
    guard abs(double) <= 1e18 else { return nil }
    return double
}

private func agentHarnessWireBoolean(_ value: Any?) -> Bool? {
    guard let number = value as? NSNumber,
          CFGetTypeID(number) == CFBooleanGetTypeID()
    else { return nil }
    return number.boolValue
}

private func agentHarnessWireLabel(
    _ value: Any?,
    maximum: Int = 256
) -> String? {
    guard let string = value as? String,
          string.utf8.count <= max(1, maximum) * 4 else { return nil }
    return agentHarnessBoundedLabel(string, maximum: maximum)
}

private func agentHarnessWireToken(
    _ value: Any?,
    maximum: Int = 96
) -> String? {
    guard let string = value as? String,
          string.utf8.count <= max(1, maximum) else { return nil }
    return agentHarnessBoundedToken(string, maximum: maximum)
}

private func agentHarnessWireTokens(_ value: Any?) -> [String]? {
    guard let raw = value as? [Any] else { return nil }
    return agentHarnessBoundedTokens(raw.prefix(64).compactMap { $0 as? String })
}

private func agentHarnessWireContextComposition(_ value: Any?) -> AgentContextComposition? {
    guard let raw = value as? [String: Any] else { return nil }
    var values: [AgentContextCompositionCategory: Int] = [:]
    for category in AgentContextCompositionCategory.allCases {
        if let value = agentHarnessTokenCount(agentHarnessWireInteger(raw[category.rawValue])) {
            values[category] = value
        }
    }
    let composition = AgentContextComposition(values)
    return composition.isEmpty ? nil : composition
}

private func agentHarnessWireDate(_ value: Any?) -> Date? {
    guard let text = value as? String, text.utf8.count <= 64 else { return nil }
    return SendableISO8601Formatter.fractional.date(from: text)
        ?? SendableISO8601Formatter.plain.date(from: text)
}

private func agentHarnessWireDay(_ value: Any?) -> String? {
    guard let text = value as? String, text.utf8.count == 10 else { return nil }
    let parts = text.split(separator: "-", omittingEmptySubsequences: false)
    guard parts.count == 3,
          parts[0].count == 4,
          parts[1].count == 2,
          parts[2].count == 2,
          let year = Int(parts[0]),
          let month = Int(parts[1]),
          let day = Int(parts[2]),
          (1...9999).contains(year),
          let date = Calendar(identifier: .gregorian).date(
              from: DateComponents(
                  calendar: Calendar(identifier: .gregorian),
                  timeZone: TimeZone(secondsFromGMT: 0),
                  year: year,
                  month: month,
                  day: day))
    else { return nil }
    let components = Calendar(identifier: .gregorian).dateComponents(
        in: TimeZone(secondsFromGMT: 0)!, from: date)
    guard components.year == year, components.month == month, components.day == day else {
        return nil
    }
    return text
}
