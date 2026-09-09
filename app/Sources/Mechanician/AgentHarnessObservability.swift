import Foundation

// MARK: - Bounded provider-harness vocabulary

private let agentHarnessMaximumDurationMs = 30 * 24 * 60 * 60 * 1_000
private let agentHarnessMaximumTokenCount = 4_000_000_000
private let agentHarnessMaximumCount = 1_000_000
private let agentHarnessMaximumMetadataValues = 8

private let agentHarnessErrorKinds: Set<String> = [
    "authentication", "authorization", "rate_limit", "usage_limit", "timeout",
    "connection", "network", "unavailable", "overloaded", "server", "invalid_request",
    "context_limit", "compaction", "interrupted", "other",
]
private let agentHarnessRerouteReasons: Set<String> = [
    "safety", "capacity", "performance", "availability", "other",
]
private let agentHarnessSafetyReasons: Set<String> = [
    "safety", "capacity", "performance", "availability", "other",
]
private let agentHarnessSafetyUseCases: Set<String> = [
    "security", "research", "coding", "other",
]
private let agentHarnessModelVerifications: Set<String> = [
    "trusted_access", "policy", "capability", "other",
]
private let agentHarnessCompactionTriggers: Set<String> = ["auto", "manual", "provider"]

func agentHarnessDuration(_ value: Int?) -> Int? {
    guard let value, value >= 0 else { return nil }
    return min(value, agentHarnessMaximumDurationMs)
}

func agentHarnessTokenCount(_ value: Int?) -> Int? {
    guard let value, value >= 0 else { return nil }
    return min(value, agentHarnessMaximumTokenCount)
}

func agentHarnessBoundedCount(_ value: Int?) -> Int? {
    guard let value, value >= 0 else { return nil }
    return min(value, agentHarnessMaximumCount)
}

func agentHarnessHTTPStatus(_ value: Int?) -> Int? {
    guard let value, (100...999).contains(value) else { return nil }
    return value
}

func agentHarnessBoundedLabel(_ value: String?, maximum: Int = 256) -> String? {
    guard let value else { return nil }
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty,
          !trimmed.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
    else { return nil }
    return String(trimmed.prefix(max(1, maximum)))
}

func agentHarnessBoundedToken(_ value: String?, maximum: Int = 96) -> String? {
    guard let value = agentHarnessBoundedLabel(value, maximum: maximum),
          value.unicodeScalars.allSatisfy({ scalar in
              CharacterSet.alphanumerics.contains(scalar)
                  || "-_.:/".unicodeScalars.contains(scalar)
          })
    else { return nil }
    return value
}

func agentHarnessBoundedTokens(_ values: [String]?) -> [String]? {
    guard let values else { return nil }
    var seen: Set<String> = []
    let bounded = values.compactMap { agentHarnessBoundedToken($0) }.filter {
        seen.insert($0).inserted
    }
    guard !bounded.isEmpty else { return nil }
    return Array(bounded.prefix(agentHarnessMaximumMetadataValues))
}

/// Second-boundary validation for values the daemon has already coarsened. A future or compromised
/// daemon cannot turn a nominal category into persisted provider text: scalar unknowns become the
/// constant `other`, while arrays coalesce all unknown values into one `other` entry.
private func agentHarnessClosedCategory(
    _ value: String?,
    allowed: Set<String>
) -> String? {
    guard let value else { return nil }
    return allowed.contains(value) ? value : "other"
}

private func agentHarnessClosedCategories(
    _ values: [String]?,
    allowed: Set<String>
) -> [String]? {
    guard let values else { return nil }
    var seen: Set<String> = []
    let categories = values.prefix(64).compactMap { value -> String? in
        let category = allowed.contains(value) ? value : "other"
        return seen.insert(category).inserted ? category : nil
    }
    return categories.isEmpty ? nil : Array(categories.prefix(agentHarnessMaximumMetadataValues))
}

func agentHarnessErrorKind(_ value: String?) -> String? {
    agentHarnessClosedCategory(value, allowed: agentHarnessErrorKinds)
}

func agentHarnessRerouteReason(_ value: String?) -> String? {
    agentHarnessClosedCategory(value, allowed: agentHarnessRerouteReasons)
}

func agentHarnessSafetyReasonValues(_ values: [String]?) -> [String]? {
    agentHarnessClosedCategories(values, allowed: agentHarnessSafetyReasons)
}

func agentHarnessSafetyUseCaseValues(_ values: [String]?) -> [String]? {
    agentHarnessClosedCategories(values, allowed: agentHarnessSafetyUseCases)
}

func agentHarnessModelVerificationValues(_ values: [String]?) -> [String]? {
    agentHarnessClosedCategories(values, allowed: agentHarnessModelVerifications)
}

func agentHarnessCompactionTrigger(_ value: String?) -> String? {
    guard let value else { return nil }
    return agentHarnessCompactionTriggers.contains(value) ? value : nil
}

struct AgentHarnessLaneID: RawRepresentable, Hashable, Codable {
    let rawValue: String

    init?(rawValue: String) {
        guard let bounded = agentHarnessBoundedToken(rawValue, maximum: 48) else { return nil }
        self.rawValue = bounded
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        guard let value = Self(rawValue: raw) else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Harness lane identity is not a bounded token.")
        }
        self = value
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    static let claude = Self(rawValue: "claude")!
    static let codex = Self(rawValue: "codex")!
    static let openAI = Self(rawValue: "openai")!

    static func inferred(from access: ModelAccess) -> Self {
        switch access {
        case .claudeSubscription, .anthropicAPI, .claudeVertex, .claudeBedrock:
            return .claude
        case .codexSubscription:
            return .codex
        case .openAIAPI:
            return .openAI
        }
    }
}

enum AgentHarnessPhase: String, Codable, CaseIterable {
    case providerReady = "provider_ready"
    case threadReady = "thread_ready"
    case requestAccepted = "request_accepted"
    case firstOutput = "first_output"
    case terminal
}

enum AgentHarnessEventKind: String, Codable, CaseIterable {
    case phase
    case retry
    case retryRecovered = "retry_recovered"
    case retryExhausted = "retry_exhausted"
    case tool
    case modelRerouted = "model_rerouted"
    case modelSafety = "model_safety"
    case modelVerification = "model_verification"
    case result
    case context
    case compaction
    case permission
    case hook
    case mcpConnection = "mcp_connection"
    case interrupt
    case internalError = "internal_error"
}

enum AgentMeasurementProvenance: String, Codable, CaseIterable {
    case mechanicianClock = "mechanician_clock"
    case providerReport = "provider_report"
    case derived
    case estimated
}

enum AgentMeasurementScope: String, Codable, CaseIterable {
    case event
    case request
    case turn
    case session
    case thread
    case agent
    case agentTree = "agent_tree"
}

enum AgentMeasurementAggregation: String, Codable, CaseIterable {
    case point
    case delta
    case cumulative
    case snapshot
    case final
}

enum AgentHarnessThreadAction: String, Codable, CaseIterable {
    case start
    case resume
}

enum AgentHarnessOutputKind: String, Codable, CaseIterable {
    case text
    case thinking
}

enum AgentHarnessTerminalOutcome: String, Codable, CaseIterable {
    case completed
    case failed
    case interrupted
}

enum AgentRetryDisposition: String, Codable, CaseIterable {
    case scheduled
    case recovered
    case exhausted
}

enum AgentHarnessToolKind: String, Codable, CaseIterable {
    case command
    case mcp
    case dynamic
    case builtIn = "built_in"
    case web
    case fileChange = "file_change"
    case other
}

enum AgentHarnessToolOutcome: String, Codable, CaseIterable {
    case success
    case error
    case declined
    case cancelled
    case timedOut = "timed_out"
    case blocked
}

enum AgentSafetyOutcome: String, Codable, CaseIterable {
    case allowed
    case blocked
    case buffered
    case refused
}

// MARK: - Context composition

enum AgentContextCompositionCategory: String, Codable, CaseIterable {
    case systemPrompt = "system_prompt"
    case systemTools = "system_tools"
    case mcpTools = "mcp_tools"
    case deferredTools = "deferred_tools"
    case memory
    case agents
    case skills
    case commands
    case messages
    case compactionBuffer = "compaction_buffer"
    case free
    case other
}

private struct AgentHarnessDynamicCodingKey: CodingKey {
    let stringValue: String
    let intValue: Int? = nil

    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { return nil }
}

/// A closed set of aggregate token categories. Unknown future keys are ignored, negative values are
/// rejected, and each value is capped, so one provider observation cannot grow the durable record
/// without bound. Presence with value zero remains distinct from absence.
struct AgentContextComposition: Codable, Equatable {
    private(set) var tokensByCategory: [AgentContextCompositionCategory: Int]

    init(_ values: [AgentContextCompositionCategory: Int]) {
        var bounded: [AgentContextCompositionCategory: Int] = [:]
        for category in AgentContextCompositionCategory.allCases {
            if let value = agentHarnessTokenCount(values[category]) {
                bounded[category] = value
            }
        }
        tokensByCategory = bounded
    }

    var isEmpty: Bool { tokensByCategory.isEmpty }

    var reportedCategories: [AgentContextCompositionCategory] {
        AgentContextCompositionCategory.allCases.filter { tokensByCategory[$0] != nil }
    }

    var totalReportedTokens: Int {
        tokensByCategory.values.reduce(0) { partial, value in
            let (sum, overflow) = partial.addingReportingOverflow(value)
            return overflow ? Int.max : sum
        }
    }

    subscript(category: AgentContextCompositionCategory) -> Int? {
        tokensByCategory[category]
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: AgentHarnessDynamicCodingKey.self)
        var bounded: [AgentContextCompositionCategory: Int] = [:]
        for key in container.allKeys {
            guard let category = AgentContextCompositionCategory(rawValue: key.stringValue),
                  let decoded = try? container.decode(Int.self, forKey: key),
                  let value = agentHarnessTokenCount(decoded)
            else { continue }
            bounded[category] = value
        }
        tokensByCategory = bounded
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: AgentHarnessDynamicCodingKey.self)
        for category in AgentContextCompositionCategory.allCases {
            guard let value = tokensByCategory[category],
                  let key = AgentHarnessDynamicCodingKey(stringValue: category.rawValue)
            else { continue }
            try container.encode(value, forKey: key)
        }
    }
}

extension AgentActivityRecord {
    /// Legacy rows predate `harnessLaneID`, but their persisted route still yields the same stable
    /// harness family. This is a read-only fallback; encoding an old row does not manufacture data.
    var resolvedHarnessLaneID: AgentHarnessLaneID? {
        harnessLaneID ?? providerAccess.map(AgentHarnessLaneID.inferred(from:))
    }

    static func harnessObservation(
        turnID: String?,
        lane: AgentHarnessLaneID,
        event: AgentHarnessEventKind,
        phase: AgentHarnessPhase? = nil,
        provenance: AgentMeasurementProvenance,
        at: Date = Date()
    ) -> Self {
        let kind: AgentActivityKind
        switch event {
        case .tool: kind = .tool
        case .context: kind = .context
        case .compaction: kind = .compaction
        default: kind = .state
        }
        return Self(
            at: at,
            turnID: turnID,
            kind: kind,
            harnessLaneID: lane,
            harnessPhase: phase,
            harnessEventKind: event,
            measurementProvenance: provenance)
    }
}

// MARK: - Missing-versus-zero coverage

struct AgentMeasurementCoverage: Equatable {
    var sampleCount: Int
    var observedCount: Int
    var explicitZeroCount: Int

    var missingCount: Int { max(0, sampleCount - observedCount) }
    var hasObservations: Bool { observedCount > 0 }
    var fraction: Double? {
        sampleCount > 0 ? Double(observedCount) / Double(sampleCount) : nil
    }
}

func agentMeasurementCoverage(_ values: [Int?]) -> AgentMeasurementCoverage {
    AgentMeasurementCoverage(
        sampleCount: values.count,
        observedCount: values.compactMap { $0 }.count,
        explicitZeroCount: values.compactMap { $0 }.filter { $0 == 0 }.count)
}

func agentHarnessSumObserved(_ values: [Int?]) -> Int? {
    let observed = values.compactMap { $0 }
    guard !observed.isEmpty else { return nil }
    return observed.reduce(0) { partial, value in
        let (sum, overflow) = partial.addingReportingOverflow(max(0, value))
        return overflow ? Int.max : sum
    }
}

// MARK: - Pure reliability and trend summaries

struct AgentHarnessTurnReliabilitySummary: Identifiable, Equatable {
    var id: String
    var startedAt: Date
    var endedAt: Date
    var harnessLaneIDs: [AgentHarnessLaneID]
    var providerAccess: ModelAccess?
    var modelID: String?
    var terminalOutcome: AgentHarnessTerminalOutcome?
    var wallDurationMs: Int
    var reportedDurationMs: Int?
    var apiDurationMs: Int?
    var timeToFirstTokenMs: Int?
    var timeToFirstOutputMs: Int?
    var retryEventCount: Int
    var retryAttempts: Int?
    var recoveredRetryCount: Int
    var exhaustedRetryCount: Int
    var observedRetryDelayMs: Int?
    var rerouteCount: Int
    var safetyEventCount: Int
    var safetyBlockedCount: Int
    var toolCallCount: Int
    var toolFailureCount: Int
    var toolDeclineCount: Int
    var observedToolDurationMs: Int?
    var toolDurationCoverage: AgentMeasurementCoverage
    var toolOutcomeCoverage: AgentMeasurementCoverage
    var compactionCount: Int
    var compactionFailureCount: Int
    var observedCompactionDurationMs: Int?
    var compactionDurationCoverage: AgentMeasurementCoverage
    var contextPeakTokens: Int?
    var contextLimitTokens: Int?
    var contextPeakFraction: Double?
    var contextComposition: AgentContextComposition?

    var isTerminal: Bool { terminalOutcome != nil }
    var hadRetries: Bool { retryEventCount > 0 || recoveredRetryCount > 0 }
    var wasRerouted: Bool { rerouteCount > 0 }
}

private func agentHarnessTerminalOutcome(
    in records: [AgentActivityRecord]
) -> AgentHarnessTerminalOutcome? {
    if let explicit = records.reversed().compactMap(\.terminalOutcome).first {
        return explicit
    }
    guard let terminal = records.reversed().first(where: {
        $0.agentID == AgentActivityIdentity.root
            && $0.kind == .state
            && $0.phase?.isTerminal == true
    })?.phase else { return nil }
    switch terminal {
    case .completed: return .completed
    case .failed: return .failed
    case .stopped: return .interrupted
    default: return nil
    }
}

private func agentHarnessToolRecords(
    _ records: [AgentActivityRecord]
) -> [AgentActivityRecord] {
    var ordered: [AgentActivityRecord] = []
    var indices: [String: Int] = [:]
    for record in records where record.kind == .tool || record.harnessEventKind == .tool {
        let key = record.toolUseID.map { "\(record.agentID)\u{0}\($0)" }
            ?? "record:\(record.id.uuidString)"
        if let index = indices[key] {
            ordered[index] = record
        } else {
            indices[key] = ordered.count
            ordered.append(record)
        }
    }
    return ordered
}

private func agentHarnessWallDurationMs(start: Date, end: Date) -> Int {
    let milliseconds = max(0, end.timeIntervalSince(start) * 1_000)
    return min(Int(milliseconds.rounded()), agentHarnessMaximumDurationMs)
}

private func agentHarnessLatest(
    _ records: [AgentActivityRecord],
    _ keyPath: KeyPath<AgentActivityRecord, Int?>
) -> Int? {
    records.reversed().compactMap { $0[keyPath: keyPath] }.first
}

private func agentHarnessSummary(
    turnID: String,
    records ledgerRecords: [AgentActivityRecord]
) -> AgentHarnessTurnReliabilitySummary? {
    let chronological = ledgerRecords.enumerated().sorted {
        if $0.element.at != $1.element.at { return $0.element.at < $1.element.at }
        return $0.offset < $1.offset
    }.map(\.element)
    guard let first = chronological.first, let last = chronological.last else { return nil }
    let rootStates = chronological.filter {
        $0.agentID == AgentActivityIdentity.root && $0.kind == .state && $0.phase != nil
    }
    let startedAt = rootStates.first?.at ?? first.at
    let endedAt = max(startedAt, last.at)
    let routed = ledgerRecords.reversed().first {
        $0.providerAccess != nil || $0.modelID?.isEmpty == false
    }
    let lanes = Set(ledgerRecords.compactMap(\.resolvedHarnessLaneID)).sorted {
        $0.rawValue < $1.rawValue
    }

    let retryRecords = ledgerRecords.filter {
        $0.harnessEventKind == .retry || $0.retryDisposition == .scheduled
    }
    let recovered = ledgerRecords.filter {
        $0.harnessEventKind == .retryRecovered || $0.retryDisposition == .recovered
    }
    let exhausted = ledgerRecords.filter {
        $0.harnessEventKind == .retryExhausted || $0.retryDisposition == .exhausted
    }
    let attemptValues = ledgerRecords.flatMap { [$0.retryAttempt, $0.retryAttempts] }.compactMap { $0 }
    let toolRecords = agentHarnessToolRecords(ledgerRecords)
    let toolDurations = toolRecords.map(\.toolDurationMs)
    let toolOutcomes: [Int?] = toolRecords.map { record in
        guard let outcome = record.toolOutcome else { return nil }
        return [.error, .timedOut, .blocked].contains(outcome) ? 1 : 0
    }
    let compactions = ledgerRecords.filter {
        $0.kind == .compaction || $0.harnessEventKind == .compaction
    }
    let compactionDurations = compactions.map(\.compactionDurationMs)
    let contextPeak = chronological.compactMap(\.contextTokens).max()
    let contextLimit = chronological.reversed().compactMap {
        $0.contextUsableWindowTokens ?? $0.contextWindow
    }.first
    let peakFraction: Double?
    if let contextPeak, let contextLimit, contextLimit > 0 {
        peakFraction = Double(max(0, contextPeak)) / Double(contextLimit)
    } else {
        peakFraction = nil
    }
    let safetyRecords = ledgerRecords.filter {
        $0.harnessEventKind == .modelSafety || $0.safetyOutcome != nil
            || $0.safetyReasons?.isEmpty == false
    }
    let explicitFirstOutput = agentHarnessLatest(ledgerRecords, \.timeToFirstOutputMs)
    let milestoneFirstOutput = ledgerRecords.reversed().first {
        $0.harnessPhase == .firstOutput && $0.elapsedMs != nil
    }?.elapsedMs

    return AgentHarnessTurnReliabilitySummary(
        id: turnID,
        startedAt: startedAt,
        endedAt: endedAt,
        harnessLaneIDs: lanes,
        providerAccess: routed?.providerAccess,
        modelID: routed?.modelID,
        terminalOutcome: agentHarnessTerminalOutcome(in: ledgerRecords),
        wallDurationMs: agentHarnessWallDurationMs(start: startedAt, end: endedAt),
        reportedDurationMs: agentHarnessLatest(ledgerRecords, \.durationMs),
        apiDurationMs: agentHarnessLatest(ledgerRecords, \.apiDurationMs),
        timeToFirstTokenMs: agentHarnessLatest(ledgerRecords, \.timeToFirstTokenMs),
        timeToFirstOutputMs: explicitFirstOutput ?? milestoneFirstOutput,
        retryEventCount: retryRecords.count,
        retryAttempts: attemptValues.max(),
        recoveredRetryCount: recovered.count,
        exhaustedRetryCount: exhausted.count,
        observedRetryDelayMs: agentHarnessSumObserved(retryRecords.map(\.retryDelayMs)),
        rerouteCount: ledgerRecords.filter {
            $0.harnessEventKind == .modelRerouted
                || $0.rerouteOriginalModelID != nil || $0.rerouteModelID != nil
        }.count,
        safetyEventCount: safetyRecords.count,
        safetyBlockedCount: safetyRecords.filter {
            $0.safetyOutcome == .blocked || $0.safetyOutcome == .refused
        }.count,
        toolCallCount: toolRecords.count,
        toolFailureCount: toolRecords.filter {
            $0.toolOutcome == .error || $0.toolOutcome == .timedOut
                || $0.toolOutcome == .blocked
        }.count,
        toolDeclineCount: toolRecords.filter { $0.toolOutcome == .declined }.count,
        observedToolDurationMs: agentHarnessSumObserved(toolDurations),
        toolDurationCoverage: agentMeasurementCoverage(toolDurations),
        toolOutcomeCoverage: agentMeasurementCoverage(toolOutcomes),
        compactionCount: compactions.count,
        compactionFailureCount: compactions.filter {
            $0.compactionError?.isEmpty == false
        }.count,
        observedCompactionDurationMs: agentHarnessSumObserved(compactionDurations),
        compactionDurationCoverage: agentMeasurementCoverage(compactionDurations),
        contextPeakTokens: contextPeak,
        contextLimitTokens: contextLimit,
        contextPeakFraction: peakFraction,
        contextComposition: chronological.reversed().compactMap(\.contextComposition).first)
}

/// One provider-neutral reliability point per Mechanician turn, oldest first for trend charts.
func agentHarnessReliabilityTrend(
    _ records: [AgentActivityRecord]
) -> [AgentHarnessTurnReliabilitySummary] {
    Dictionary(grouping: records.compactMap { record in
        record.turnID.map { ($0, record) }
    }, by: \.0)
    .compactMap { turnID, pairs in
        agentHarnessSummary(turnID: turnID, records: pairs.map(\.1))
    }
    .sorted {
        if $0.startedAt != $1.startedAt { return $0.startedAt < $1.startedAt }
        return $0.id < $1.id
    }
}

struct AgentHarnessReliabilityRollup: Equatable {
    var turnCount: Int
    var terminalTurnCount: Int
    var completedTurnCount: Int
    var failedTurnCount: Int
    var interruptedTurnCount: Int
    var retryTurnCount: Int
    var recoveredRetryTurnCount: Int
    var exhaustedRetryTurnCount: Int
    var reroutedTurnCount: Int
    var safetyBlockedTurnCount: Int
    var toolCallCount: Int
    var toolFailureCount: Int
    var compactionCount: Int
    var compactionFailureCount: Int
    var reportedDurationCoverage: AgentMeasurementCoverage
    var apiDurationCoverage: AgentMeasurementCoverage
    var firstOutputCoverage: AgentMeasurementCoverage
    var contextPeakCoverage: AgentMeasurementCoverage
    var toolDurationCoverage: AgentMeasurementCoverage

    var completionRate: Double? {
        terminalTurnCount > 0 ? Double(completedTurnCount) / Double(terminalTurnCount) : nil
    }
}

func agentHarnessReliabilityRollup(
    _ turns: [AgentHarnessTurnReliabilitySummary]
) -> AgentHarnessReliabilityRollup {
    AgentHarnessReliabilityRollup(
        turnCount: turns.count,
        terminalTurnCount: turns.filter(\.isTerminal).count,
        completedTurnCount: turns.filter { $0.terminalOutcome == .completed }.count,
        failedTurnCount: turns.filter { $0.terminalOutcome == .failed }.count,
        interruptedTurnCount: turns.filter { $0.terminalOutcome == .interrupted }.count,
        retryTurnCount: turns.filter(\.hadRetries).count,
        recoveredRetryTurnCount: turns.filter { $0.recoveredRetryCount > 0 }.count,
        exhaustedRetryTurnCount: turns.filter { $0.exhaustedRetryCount > 0 }.count,
        reroutedTurnCount: turns.filter(\.wasRerouted).count,
        safetyBlockedTurnCount: turns.filter { $0.safetyBlockedCount > 0 }.count,
        toolCallCount: turns.reduce(0) { $0 + $1.toolCallCount },
        toolFailureCount: turns.reduce(0) { $0 + $1.toolFailureCount },
        compactionCount: turns.reduce(0) { $0 + $1.compactionCount },
        compactionFailureCount: turns.reduce(0) { $0 + $1.compactionFailureCount },
        reportedDurationCoverage: agentMeasurementCoverage(turns.map(\.reportedDurationMs)),
        apiDurationCoverage: agentMeasurementCoverage(turns.map(\.apiDurationMs)),
        firstOutputCoverage: agentMeasurementCoverage(turns.map(\.timeToFirstOutputMs)),
        contextPeakCoverage: agentMeasurementCoverage(turns.map(\.contextPeakTokens)),
        toolDurationCoverage: agentMeasurementCoverage(turns.map(\.observedToolDurationMs)))
}
