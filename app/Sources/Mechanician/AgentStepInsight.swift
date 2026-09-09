import Foundation

/// What an agent is doing *now*, and what kind of work it has been doing.
///
/// The agent cards already answer "which agents exist" and "how long has this one been running".
/// These functions answer the two questions the cards could not: *how long has it been on the step
/// it is on* — the only figure that distinguishes healthy slow work from a stall — and *what mix of
/// tools has it actually used*, which the "9 tools" count deliberately hides.
///
/// All of it is derived from the existing activity ledger. Nothing here samples the provider.

/// A short, human-readable summary of the current step for one agent.
struct AgentStepSnapshot: Equatable {
    var phase: AgentActivityPhase
    /// The tool name, or the model's activity ("Responding", "Reasoning").
    var label: String
    /// What the tool acted on, when the provider disclosed it.
    var target: String?
    var since: Date
    var duration: TimeInterval

    var isTerminal: Bool { phase.isTerminal }
}

/// The agent's most recent state transition, and how long it has been sitting in it.
///
/// Records for `agentID` are expected to be pre-filtered/canonicalized by the caller (aliases are
/// resolved at the lane level), so this does no identity reconciliation of its own.
func agentCurrentStep(
    _ records: [AgentActivityRecord],
    agentID: String,
    now: Date = Date()
) -> AgentStepSnapshot? {
    AgentActivityLedgerIndex(records).currentStep(agentID: agentID, now: now)
}

/// Whether the current step has run long enough, relative to this agent's own completed steps, to be
/// worth flagging.
///
/// Compared against the agent's own median rather than a fixed threshold: a build agent's normal
/// step is minutes and a search agent's is seconds, so any absolute number would cry wolf on one and
/// stay silent on the other. Requires a real sample of finished steps, and a floor, so a fast agent's
/// sub-second median cannot make every ordinary step look stalled.
func agentStepIsStalled(
    _ records: [AgentActivityRecord],
    agentID: String,
    now: Date = Date(),
    factor: Double = 4,
    minimumSamples: Int = 4,
    floor: TimeInterval = 30
) -> Bool {
    AgentActivityLedgerIndex(records).stepIsStalled(
        agentID: agentID,
        now: now,
        factor: factor,
        minimumSamples: minimumSamples,
        floor: floor)
}

/// What to call a tool in the composition breakdown.
///
/// A provider that runs everything through a shell reports one tool name for every call, so the
/// breakdown collapses to a single bar reading "Bash 243" — literally true and of no use. Codex is
/// such a provider: reading a file is `cat`, searching is `rg`, listing is `find`. The command is
/// already on the record, so the breakdown names the program that actually ran.
///
/// This is naming, not interpretation: `rg` is reported as `rg`, not as "Grep". The emitted tool
/// name is deliberately left alone, because permission and policy decisions key off it.
func agentToolCompositionName(_ toolName: String, target: String?) -> String {
    // An MCP server's tools are one family of work. Counted individually they shatter the biggest
    // activity in a conversation into a dozen fragments, each too long to render — a real
    // conversation showed nine `mcp__computer__*` entries totalling 75 calls, displayed as two
    // truncated rows reading `mcp__computer__Comput…`. Counting them under their server says
    // "computer 75", which is the fact worth having.
    if let server = mcpServerName(toolName) { return server }
    guard isShellToolName(toolName), let command = target?.trimmingCharacters(in: .whitespaces),
          !command.isEmpty else {
        return toolName
    }
    return shellProgramName(command) ?? toolName
}

/// The one user-facing name for a tool mark, shared by cards, the conversation summary, and trace.
///
/// `agentToolCompositionName` does the provider-neutral target normalization. This final projection
/// also names delegation as an action: a tool named `Agent` is protocol truth, but an orange UI
/// mark labelled "Agent" reads like an identity rather than the work that happened.
func traceToolDisplayName(toolName: String, target: String?) -> String {
    let normalized = agentToolCompositionName(toolName, target: target)
    switch normalized.lowercased() {
    case "agent", "task", "subagent":
        return "Delegating"
    default:
        return normalized
    }
}

/// The server out of an `mcp__server__tool` name, when that is what this is.
private func mcpServerName(_ toolName: String) -> String? {
    guard toolName.hasPrefix("mcp__") else { return nil }
    let parts = toolName.dropFirst(5).components(separatedBy: "__")
    guard let server = parts.first, !server.isEmpty, parts.count >= 2 else { return nil }
    return server
}

private func isShellToolName(_ name: String) -> Bool {
    let lowered = name.lowercased()
    return lowered == "bash" || lowered == "shell" || lowered == "run" || lowered == "terminal"
}

/// The program a shell command actually runs, looking through the `sh -c` wrapper the provider
/// wraps around it and past any `cd` or environment prefix.
private func shellProgramName(_ command: String) -> String? {
    var text = command
    // Unwrap `/bin/zsh -lc "…"`, `bash -c '…'`, `sh -c …`.
    if let range = text.range(of: #"^\S*(zsh|bash|sh)\s+-[a-z]*c\s+"#, options: .regularExpression) {
        text = String(text[range.upperBound...])
        if let first = text.first, first == "\"" || first == "'" {
            text.removeFirst()
            if let close = text.lastIndex(of: first) { text = String(text[text.startIndex..<close]) }
        }
    }
    // Skip a leading `cd somewhere &&`, which is scaffolding rather than the work.
    while true {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("cd ") else { break }
        guard let separator = trimmed.range(of: "&&") ?? trimmed.range(of: ";") else { return "cd" }
        text = String(trimmed[separator.upperBound...])
    }
    for token in text.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" }) {
        let word = String(token)
        // Environment assignments precede the program.
        if word.contains("="), !word.hasPrefix("-") { continue }
        if word.hasPrefix("(") || word.hasPrefix("{") { continue }
        let program = word.split(separator: "/").last.map(String.init) ?? word
        let cleaned = program.trimmingCharacters(in: CharacterSet(charactersIn: "\"'`()"))
        // Shell commands nest quotes, redirections and subshells in ways this deliberately simple
        // scan will sometimes land in the middle of. A fragment like `conversations";` is not a
        // program name, and labelling a bar with it is worse than falling back to the tool's own
        // name. Only accept something that could actually be an executable.
        guard !cleaned.isEmpty,
              cleaned.rangeOfCharacter(from: CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ")) != nil,
              cleaned.unicodeScalars.allSatisfy({ scalar in
                  CharacterSet.alphanumerics.contains(scalar)
                      || scalar == "." || scalar == "_" || scalar == "-" || scalar == "+"
              }) else {
            return nil
        }
        return cleaned
    }
    return nil
}

struct AgentToolShare: Identifiable, Equatable {
    var name: String
    var count: Int
    /// Fraction of this agent's tool calls, 0...1.
    var share: Double

    var id: String { name }
}

/// Everything an agent card needs from one immutable ledger revision.
///
/// Time-dependent values are finalized when the card renders, while grouping, sorting, tool
/// counting, and token aggregation are performed once by `AgentActivityLedgerIndex`.
struct AgentActivityCardSnapshot: Equatable {
    var currentStep: AgentStepSnapshot?
    var toolComposition: [AgentToolShare]
    var tokenUsage: AgentActivityTokenBreakdown
    var isStalled: Bool
}

/// Root-only activity for the same selected turn used by the conversation summary.
///
/// This is intentionally distinct from ``AgentConversationActivitySnapshot``: the conversation
/// snapshot follows delegated tail work and reports turn-wide usage, while this value freezes at
/// the root terminal boundary and contains only records owned by ``AgentActivityIdentity/root``.
/// `requestedModelID` is the turn route stamped by `AgentBridge`. Provider-reported attribution
/// remains separate (and nil until a provider event supplies it) so a child model can never become
/// the root model by accident.
struct AgentRootActivitySnapshot: Equatable {
    var turnID: String?
    var providerAccess: ModelAccess?
    var requestedModelID: String?
    var providerReportedModelID: String?
    var phase: AgentActivityPhase?
    var startedAt: Date
    var terminalAt: Date?
    var currentStep: AgentStepSnapshot?
    var tokenUsage: AgentActivityTokenBreakdown
    var observedToolCount: Int
    var toolComposition: [AgentToolShare]
    var isStalled: Bool
    var isActive: Bool
    var duration: TimeInterval
}

/// The append-ordered records owned by the latest explicit lifecycle generation. This includes
/// tool and usage samples so cold recovery and trace projection can share the same boundary instead
/// of attaching an older generation's late metadata to a reopened span.
func agentActivityCurrentLifecycleGenerationRecords(
    _ records: [AgentActivityRecord]
) -> ArraySlice<AgentActivityRecord> {
    guard let boundary = records.lastIndex(where: {
        $0.kind == .state && $0.startsNewLifecycleGeneration == true
    }) else { return records[...] }
    return records[boundary...]
}

/// Partition one canonical lane in ledger append order. Rendering keeps completed generations as
/// history, while liveness and cold recovery intentionally consume only the final partition.
func agentActivityLifecycleGenerationRecords(
    _ records: [AgentActivityRecord]
) -> [[AgentActivityRecord]] {
    var generations: [[AgentActivityRecord]] = []
    var current: [AgentActivityRecord] = []
    for record in records {
        if record.kind == .state,
           record.startsNewLifecycleGeneration == true,
           !current.isEmpty {
            generations.append(current)
            current = []
        }
        current.append(record)
    }
    if !current.isEmpty { generations.append(current) }
    return generations
}

/// Reduce the current lifecycle generation in ledger append order. A synthetic or provider-authored
/// terminal boundary is monotonic: buffered progress may still arrive afterward, but cannot reopen
/// the lane. An explicit provider retask discards the prior generation from this projection and
/// starts a new terminal-monotonic suffix for the same agent and turn.
func terminalMonotonicActivityStates(
    _ records: [AgentActivityRecord]
) -> [AgentActivityRecord] {
    var states: [AgentActivityRecord] = []
    for record in agentActivityCurrentLifecycleGenerationRecords(records)
    where record.kind == .state && record.phase != nil {
        if states.last?.phase?.isTerminal == true, record.phase?.isTerminal != true {
            continue
        }
        states.append(record)
    }
    return states
}

/// One lifecycle projection shared by cards, turn summaries, and the profiler trace.
///
/// A lane is active only until the current generation's first terminal boundary. Buffered progress
/// may be observed after Stop/completion, but it cannot resurrect the agent merely because its
/// provider timestamp sorts later than the terminal record. Only an explicit generation boundary
/// moves the lifecycle projection past an older terminal.
func agentActivityLaneIsActive(_ records: [AgentActivityRecord]) -> Bool {
    let states = terminalMonotonicActivityStates(records)
    return !states.isEmpty && !states.contains { $0.phase?.isTerminal == true }
}

/// The first terminal point on the current generation's clock. Later terminal records may refine
/// the outcome, but the original boundary remains the point after which ordinary model/tool
/// geometry must stop until an explicit generation boundary arrives.
func agentActivityLaneTerminalBoundary(_ records: [AgentActivityRecord]) -> Date? {
    terminalMonotonicActivityStates(records).first {
        $0.phase?.isTerminal == true
    }?.at
}

/// Conversation-wide activity for the active provider turn, or the latest turn when none is live.
///
/// This is deliberately not a sum of card snapshots. Provider token records are already turn-wide,
/// cached input is a subset of input, and a reconciled child can have more than one provisional
/// identity. The selected `AgentActivityTurnSummary` remains the source of token truth while the
/// canonical lane index supplies current-step, composition, and stall information.
struct AgentConversationActivitySnapshot: Equatable {
    var turnID: String?
    var overallState: AgentActivityPhase?
    var activeAgentCount: Int
    var currentRootStep: AgentStepSnapshot?
    var toolComposition: [AgentToolShare]
    /// Present when delegation calls are the only tool activity. A 100% one-colour bar would convey
    /// less than the sentence and would make four launches look like one tool family dominating.
    var delegatedAgentCount: Int
    var tokenUsage: AgentActivityTokenBreakdown
    var contextTokens: Int?
    var contextWindow: Int?
    var duration: TimeInterval
    var isStalled: Bool
    var isActive: Bool

    var isEmpty: Bool {
        turnID == nil
            && overallState == nil
            && activeAgentCount == 0
            && currentRootStep == nil
            && toolComposition.isEmpty
            && delegatedAgentCount == 0
            && tokenUsage.isEmpty
            && contextTokens == nil
            && contextWindow == nil
    }

    var delegationSummary: String? {
        guard delegatedAgentCount > 0, toolComposition.isEmpty else { return nil }
        return "Delegated \(delegatedAgentCount) "
            + (delegatedAgentCount == 1 ? "agent" : "agents")
    }
}

/// Terminal projection for a persisted delegate graph.
///
/// Providers do not all emit activity-ledger samples for child lifecycle changes. The cards are
/// still authoritative in that case, so their final state keeps the conversation summary visible
/// after the active count reaches zero.
func terminalDelegatedConversationPhase(
    subagents: [String: SubagentRun],
    workflowRuns: [String: WorkflowRun]
) -> AgentActivityPhase? {
    var hasDelegate = false
    var hasFailure = false
    var hasStop = false

    for subagent in subagents.values where !subagent.isProviderRootPseudoAgent {
        hasDelegate = true
        guard subagent.status.isTerminal else { return nil }
        switch subagent.status {
        case .failed:
            hasFailure = true
        case .killed, .stopped:
            hasStop = true
        case .completed:
            break
        case .pending, .paused, .running:
            return nil
        }
    }

    for run in workflowRuns.values {
        hasDelegate = true
        guard run.status.isTerminal else { return nil }
        switch run.status {
        case .failed:
            hasFailure = true
        case .killed, .stopped:
            hasStop = true
        case .completed:
            break
        case .pending, .paused, .running:
            return nil
        }
        for agent in run.agents.values {
            guard agent.state.isTerminal else { return nil }
            switch agent.state {
            case .failed:
                hasFailure = true
            case .stopped:
                hasStop = true
            case .done:
                break
            case .queued, .start, .progress:
                return nil
            }
        }
    }

    guard hasDelegate else { return nil }
    if hasFailure { return .failed }
    if hasStop { return .stopped }
    return .completed
}

/// Immutable derivation retained across one-second UI ticks. Building it selects and canonicalizes
/// the turn once; asking for a snapshot only advances durations and re-evaluates stall thresholds.
struct AgentConversationActivityIndex {
    private let summary: AgentActivityTurnSummary?
    private let turnIndex: AgentActivityLedgerIndex
    private let canonicalAgentIDs: Set<String>
    private let latestStates: [String: AgentActivityPhase]
    private let latestActiveDelegateState: AgentActivityPhase?
    private let latestTerminalState: AgentActivityPhase?
    private let composition: [AgentToolShare]
    private let delegationCount: Int
    private let tokenUsage: AgentActivityTokenBreakdown
    private let contextTokens: Int?
    private let contextWindow: Int?
    private let selectedTurnContainsDelegatedActivity: Bool
    private let rootIsPresent: Bool
    private let rootStartedAt: Date?
    private let rootLastWorkAt: Date?
    private let rootTerminalAt: Date?
    private let rootTerminalPhase: AgentActivityPhase?
    private let rootProviderAccess: ModelAccess?
    private let rootRequestedModelID: String?
    private let rootProviderReportedModelID: String?
    private let rootProviderReportedAt: Date?

    init(
        _ records: [AgentActivityRecord],
        aliases: [String: String] = [:],
        compositionLimit: Int = 4
    ) {
        let summaries = agentActivityTurnSummaries(records, aliases: aliases)
        // A completed root may intentionally leave delegates running. Prefer that still-live turn;
        // otherwise the newest parent turn is the conversation's useful default.
        let selected = agentActivityActiveOrLatestTurn(summaries)
        summary = selected

        let selectedRecords: [AgentActivityRecord]
        if let selected {
            selectedRecords = records.filter { $0.turnID == selected.id }
        } else {
            // Imported pre-activity sidecars can contain unscoped records. Keeping those visible is
            // better than presenting an empty strip, but they are never mixed into a scoped turn.
            selectedRecords = records.filter { $0.turnID == nil }
        }
        turnIndex = AgentActivityLedgerIndex(selectedRecords, aliases: aliases)

        let rootRecords = selectedRecords.filter {
            (aliases[$0.agentID] ?? $0.agentID) == AgentActivityIdentity.root
        }
        let rootWorkRecords = rootRecords.filter { record in
            switch record.kind {
            case .tool, .tokens:
                return true
            case .state:
                // Maintenance has its own Activity lifecycle. Its transitional root states are
                // useful on the timeline but cannot manufacture a root-agent card by themselves.
                if record.phase == .compacting { return false }
                let detail = record.detail?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .lowercased() ?? ""
                return detail != "context compacted"
                    && detail != "compaction failed"
                    && detail != "compacting context"
            case .identity, .context, .compaction, .interjection:
                return false
            }
        }
        rootIsPresent = !rootWorkRecords.isEmpty
        rootStartedAt = rootWorkRecords.map(\.at).min()
        rootLastWorkAt = rootWorkRecords.map(\.at).max()
        let rootStates = terminalMonotonicActivityStates(rootRecords)
        let firstTerminal = rootStates.first { $0.phase?.isTerminal == true }
        rootTerminalAt = firstTerminal?.at
        rootTerminalPhase = rootStates.last(where: { $0.phase?.isTerminal == true })?.phase
        rootProviderAccess = rootRecords.last(where: { $0.providerAccess != nil })?.providerAccess
        rootRequestedModelID = rootRecords.last(where: {
            $0.kind != .identity
                && $0.modelID?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        })?.modelID
        let rootProviderReportedRecord = rootRecords.last(where: {
            $0.kind == .identity
                && $0.modelID?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        })
        rootProviderReportedModelID = rootProviderReportedRecord?.modelID
        rootProviderReportedAt = rootProviderReportedRecord?.at

        let groups = canonicalizedAgentActivityGroups(selectedRecords, aliases: aliases)
        canonicalAgentIDs = Set(groups.keys)
        var stateSamples: [String: (phase: AgentActivityPhase, at: Date, sequence: Int)] = [:]
        for (sequence, record) in selectedRecords.enumerated()
        where record.kind == .state {
            guard let phase = record.phase else { continue }
            let identity = aliases[record.agentID] ?? record.agentID
            if record.startsNewLifecycleGeneration == true {
                stateSamples[identity] = (phase, record.at, sequence)
                continue
            }
            if stateSamples[identity]?.phase.isTerminal == true, !phase.isTerminal {
                continue
            }
            stateSamples[identity] = (phase, record.at, sequence)
        }
        latestStates = stateSamples.mapValues(\.phase)
        let newestStateSamples = stateSamples.sorted {
                if $0.value.at != $1.value.at { return $0.value.at > $1.value.at }
                if $0.value.sequence != $1.value.sequence {
                    return $0.value.sequence > $1.value.sequence
                }
                return $0.key < $1.key
            }
        latestActiveDelegateState = newestStateSamples
            .first {
                $0.key != AgentActivityIdentity.root && !$0.value.phase.isTerminal
            }?
            .value.phase
        latestTerminalState = newestStateSamples
            .first(where: { $0.value.phase.isTerminal })?
            .value.phase

        var nonDelegationCounts: [String: Int] = [:]
        var delegated = 0
        // Iterate canonical groups so provisional and durable identities cannot manufacture two
        // conceptual agents. Calls remain calls; alias reconciliation does not discard real work.
        for laneRecords in groups.values {
            for record in laneRecords where record.kind == .tool {
                guard let rawName = record.detail.flatMap(activitySingleLine), !rawName.isEmpty
                else { continue }
                let name = traceToolDisplayName(toolName: rawName, target: record.toolTarget)
                if name == "Delegating" {
                    delegated += 1
                } else {
                    nonDelegationCounts[name, default: 0] += 1
                }
            }
        }
        delegationCount = delegated
        // Delegate cards persist across conversation turns. Their terminal aggregate can refine the
        // selected turn only when that turn actually contains delegation evidence; otherwise a
        // stopped older child graph would overwrite a later root-only turn's Completed state.
        selectedTurnContainsDelegatedActivity = selected == nil
            || delegated > 0
            || groups.keys.contains { $0 != AgentActivityIdentity.root }
        composition = agentRankedToolShares(
            counts: nonDelegationCounts,
            limit: compositionLimit)
        tokenUsage = selected?.tokenBreakdown
            ?? agentActivityTokenBreakdown(selectedRecords)

        let context = selectedRecords.last { $0.kind == .context }
        contextTokens = context?.contextTokens
        contextWindow = context?.contextWindow
    }

    func snapshot(
        subagents: [String: SubagentRun],
        workflowRuns: [String: WorkflowRun],
        isRootWorking: Bool,
        now: Date = Date()
    ) -> AgentConversationActivitySnapshot {
        // Match Stop/provider blocking exactly: a pending child or a live workflow between phases
        // is still one active unit of conversation work even when no child is executing a tool at
        // this instant.
        let modeledCount = blockingDelegatedAgentCount(
            subagents: subagents,
            workflowRuns: workflowRuns)
        // Old imported ledgers can have child activity but no persisted delegate graph. Only use the
        // lane fallback when there is no graph at all; a terminalized graph is authoritative over a
        // stale nonterminal sample.
        let ledgerCount = latestStates.filter {
            $0.key != AgentActivityIdentity.root && !$0.value.isTerminal
        }.count
        let hasPersistedDelegateGraph = !subagents.isEmpty || !workflowRuns.isEmpty
        let activeAgentCount = !hasPersistedDelegateGraph
            ? ledgerCount
            : modeledCount
        let modeledTerminalState = selectedTurnContainsDelegatedActivity
            ? terminalDelegatedConversationPhase(
                subagents: subagents,
                workflowRuns: workflowRuns)
            : nil

        let rootStep = turnIndex.currentStep(agentID: AgentActivityIdentity.root, now: now)
        let nonterminalRoot = rootStep?.isTerminal == false ? rootStep : nil
        // Once a persisted delegate graph exists it is authoritative over an old open ledger tail.
        // A genuinely active root is supplied separately by `isRootWorking`; without either source
        // of live state, elapsed time must not grow forever after recovery terminalized the graph.
        let ledgerFallbackIsActive = !hasPersistedDelegateGraph
            && nonterminalRoot != nil
        let isActive = isRootWorking || activeAgentCount > 0 || ledgerFallbackIsActive
        let overallState: AgentActivityPhase?
        if activeAgentCount > 0 {
            overallState = latestActiveDelegateState ?? .model
        } else if isRootWorking, let phase = nonterminalRoot?.phase {
            overallState = phase
        } else if isRootWorking {
            overallState = .model
        } else {
            // Some provider child lifecycles produce a complete card graph without a durable
            // activity lane. While work is live, `activeAgentCount` keeps the strip visible; once
            // the last child terminalizes that count becomes zero. Project the terminal graph here
            // so "This conversation" remains pinned instead of disappearing at completion.
            overallState = modeledTerminalState
                ?? rootStep?.phase
                ?? latestTerminalState
        }

        let end = isActive ? now : (summary?.endedAt ?? now)
        let duration = summary.map {
            max(0, end.timeIntervalSince($0.startedAt))
        } ?? 0
        let anyStalled = canonicalAgentIDs.contains {
            turnIndex.stepIsStalled(agentID: $0, now: now)
        }

        return AgentConversationActivitySnapshot(
            turnID: summary?.id,
            overallState: overallState,
            activeAgentCount: activeAgentCount,
            currentRootStep: nonterminalRoot,
            toolComposition: composition,
            delegatedAgentCount: delegationCount,
            tokenUsage: tokenUsage,
            contextTokens: contextTokens,
            contextWindow: contextWindow,
            duration: duration,
            isStalled: anyStalled,
            isActive: isActive)
    }

    /// Project the selected turn's root lane without rescanning the conversation ledger.
    ///
    /// `isRootWorking` is the owning bridge's authoritative live-work state. An open historical
    /// ledger tail is not enough to keep a recovered root active forever, and a terminal boundary
    /// always wins over buffered progress that arrives later.
    func rootSnapshot(
        isRootWorking: Bool,
        liveSelection: ModelSelection? = nil,
        liveStartedAt: Date? = nil,
        now: Date = Date()
    ) -> AgentRootActivitySnapshot? {
        // `turn_started` is deliberately the first event allowed to install ordinary activity.
        // During process/provider startup there is therefore a real provisional root but no ledger
        // row yet. If a previous turn is selected, its terminal root must not masquerade as this
        // new live turn; a later bridge-owned start time identifies that boundary without guessing
        // a provider turn id.
        let liveStartsAfterRecordedRoot = isRootWorking
            && liveStartedAt.map {
                $0 > (rootTerminalAt ?? rootLastWorkAt ?? .distantFuture)
            } == true
        if !rootIsPresent || liveStartsAfterRecordedRoot {
            guard isRootWorking else { return nil }
            let startedAt = liveStartedAt ?? now
            let reportedModelBelongsToLiveTurn = rootProviderReportedAt.map { reportedAt in
                liveStartedAt.map { reportedAt >= $0 } ?? true
            } == true
            return AgentRootActivitySnapshot(
                turnID: nil,
                providerAccess: liveSelection?.access,
                requestedModelID: liveSelection?.modelID,
                providerReportedModelID: !rootIsPresent && reportedModelBelongsToLiveTurn
                    ? rootProviderReportedModelID
                    : nil,
                phase: .model,
                startedAt: startedAt,
                terminalAt: nil,
                currentStep: nil,
                tokenUsage: AgentActivityTokenBreakdown(),
                observedToolCount: 0,
                toolComposition: [],
                isStalled: false,
                isActive: true,
                duration: max(0, now.timeIntervalSince(startedAt)))
        }
        guard let recordedStartedAt = rootStartedAt else { return nil }

        let card = turnIndex.cardSnapshot(
            agentID: AgentActivityIdentity.root,
            now: now)
        let terminalAt = rootTerminalAt
        let isActive = isRootWorking && terminalAt == nil
        let startedAt = isActive
            ? min(recordedStartedAt, liveStartedAt ?? recordedStartedAt)
            : recordedStartedAt
        let candidate = card.currentStep
        let currentStep = isActive && candidate?.isTerminal == false ? candidate : nil
        let end = terminalAt ?? (isActive ? now : (rootLastWorkAt ?? startedAt))
        let phase = rootTerminalPhase
            ?? (isActive ? (currentStep?.phase ?? .model) : candidate?.phase)
        let observedToolCount = card.toolComposition.reduce(0) { $0 + $1.count }

        return AgentRootActivitySnapshot(
            turnID: summary?.id,
            providerAccess: rootProviderAccess ?? (isActive ? liveSelection?.access : nil),
            requestedModelID: rootRequestedModelID
                ?? (isActive ? liveSelection?.modelID : nil),
            providerReportedModelID: rootProviderReportedModelID,
            phase: phase,
            startedAt: startedAt,
            terminalAt: terminalAt,
            currentStep: currentStep,
            tokenUsage: card.tokenUsage,
            observedToolCount: observedToolCount,
            toolComposition: card.toolComposition,
            isStalled: isActive && card.isStalled,
            isActive: isActive,
            duration: max(0, end.timeIntervalSince(startedAt)))
    }

}

/// A reusable, per-ledger index for the Agents list.
///
/// Previously every card repeatedly filtered the complete ledger for its current state, filtered
/// and sorted it again for stall detection, and scanned it once more for tool composition. A panel
/// with N cards therefore did O(N × ledger) work on every one-second tick. This index performs that
/// ledger work once, then serves each card from its own small entry.
struct AgentActivityLedgerIndex {
    private struct Entry {
        var currentState: AgentActivityRecord?
        var currentTool: AgentActivityRecord?
        var stateTransitionCount: Int
        var completedStepDurations: [TimeInterval]
        var rankedTools: [AgentToolShare]
        var tokenUsage: AgentActivityTokenBreakdown
    }

    private var entries: [String: Entry]

    /// - Parameter aliases: maps a provider's provisional identity onto the card's canonical one.
    ///   A Codex child is first seen under its tool-call id and later reconciled to its thread id,
    ///   so its activity lands under one identity while its card is keyed by the other. Without the
    ///   mapping the card looks up an id that holds nothing and shows no tools, no current step and
    ///   no stall — silently, because an agent that did nothing looks the same as one it cannot find.
    init(_ records: [AgentActivityRecord], aliases: [String: String] = [:]) {
        entries = Dictionary(grouping: records) { aliases[$0.agentID] ?? $0.agentID }
            .mapValues { records in
            let transitions = terminalMonotonicActivityStates(records)
                .sorted { $0.at < $1.at }
            let currentState = terminalMonotonicActivityStates(records).last

            // A tool step is named by the tool call that opened it; the state record only carries
            // the tool name, and the target lives on the paired `.tool` record.
            let currentTool = currentState?.phase == .tool
                ? records
                    .filter {
                        $0.kind == .tool
                            && $0.at >= currentState!.at.addingTimeInterval(-1)
                    }
                    .min(by: { $0.at < $1.at })
                : nil

            // Every completed step is the positive gap between consecutive state transitions. The
            // final in-flight step has no closing transition and is intentionally absent.
            let completedStepDurations = zip(transitions, transitions.dropFirst())
                .map { $1.at.timeIntervalSince($0.at) }
                .filter { $0 > 0 }
                .sorted()

            var toolCounts: [String: Int] = [:]
            var tokenUsage = AgentActivityTokenBreakdown()
            for record in records {
                if record.kind == .tool,
                   let name = record.detail.flatMap({ activitySingleLine($0) }),
                   !name.isEmpty {
                    toolCounts[
                        traceToolDisplayName(toolName: name, target: record.toolTarget),
                        default: 0
                    ] += 1
                }
                if record.kind == .tokens {
                    tokenUsage.add(record)
                }
            }
            let toolTotal = toolCounts.values.reduce(0, +)
            let rankedTools: [AgentToolShare]
            if toolTotal == 0 {
                rankedTools = []
            } else {
                rankedTools = toolCounts
                    .map {
                        AgentToolShare(
                            name: $0.key,
                            count: $0.value,
                            share: Double($0.value) / Double(toolTotal))
                    }
                    .sorted {
                        if $0.count != $1.count { return $0.count > $1.count }
                        return $0.name < $1.name
                    }
            }

            return Entry(
                currentState: currentState,
                currentTool: currentTool,
                stateTransitionCount: transitions.count,
                completedStepDurations: completedStepDurations,
                rankedTools: rankedTools,
                tokenUsage: tokenUsage)
        }
    }

    func currentStep(agentID: String, now: Date = Date()) -> AgentStepSnapshot? {
        guard let entry = entries[agentID],
              let state = entry.currentState,
              let phase = state.phase else { return nil }

        let label = entry.currentTool?.detail.flatMap { activitySingleLine($0) }
            ?? state.detail.flatMap { activitySingleLine($0) }
            ?? activityPhaseLabel(phase)

        return AgentStepSnapshot(
            phase: phase,
            label: label,
            target: entry.currentTool?.toolTarget.flatMap { activitySingleLine($0) },
            since: state.at,
            duration: max(0, now.timeIntervalSince(state.at)))
    }

    func stepIsStalled(
        agentID: String,
        now: Date = Date(),
        factor: Double = 4,
        minimumSamples: Int = 4,
        floor: TimeInterval = 30
    ) -> Bool {
        guard let entry = entries[agentID],
              let current = currentStep(agentID: agentID, now: now),
              !current.isTerminal,
              current.duration >= floor,
              entry.stateTransitionCount > minimumSamples,
              entry.completedStepDurations.count >= minimumSamples else { return false }

        let completed = entry.completedStepDurations
        let median = completed.count % 2 == 1
            ? completed[completed.count / 2]
            : (completed[completed.count / 2 - 1] + completed[completed.count / 2]) / 2
        guard median > 0 else { return false }
        return current.duration > median * factor
    }

    /// The tool mix, merged so that every segment drawn is big enough to see and to label.
    ///
    /// Taking the top N by rank put a quarter of all calls into "other" on a real conversation
    /// while drawing slivers for tools used once or twice. Merging by SHARE instead means a segment
    /// only survives if it is worth a segment: everything below the threshold folds into the
    /// residue, and what remains is legible.
    func toolComposition(
        agentID: String,
        limit: Int = 5,
        minimumShare: Double = 0.04
    ) -> [AgentToolShare] {
        guard let ranked = entries[agentID]?.rankedTools, !ranked.isEmpty else { return [] }
        let total = ranked.reduce(0) { $0 + $1.count }
        guard total > 0 else { return [] }

        // `rankedTools` is ordered by count, so the first tool below the threshold ends the head.
        var head: [AgentToolShare] = []
        for share in ranked {
            guard head.count < limit else { break }
            let fraction = Double(share.count) / Double(total)
            // Always keep the leader, even in a mix so flat that nothing clears the bar.
            if fraction < minimumShare, !head.isEmpty { break }
            head.append(share)
        }

        let tail = ranked.dropFirst(head.count)
        guard !tail.isEmpty else { return head }
        let tailCount = tail.reduce(0) { $0 + $1.count }
        return head + [AgentToolShare(
            name: "other",
            count: tailCount,
            share: Double(tailCount) / Double(total))]
    }

    func tokenUsage(agentID: String) -> AgentActivityTokenBreakdown {
        entries[agentID]?.tokenUsage ?? AgentActivityTokenBreakdown()
    }

    func cardSnapshot(
        agentID: String,
        now: Date = Date(),
        compositionLimit: Int = 5
    ) -> AgentActivityCardSnapshot {
        AgentActivityCardSnapshot(
            currentStep: currentStep(agentID: agentID, now: now),
            toolComposition: toolComposition(agentID: agentID, limit: compositionLimit),
            tokenUsage: tokenUsage(agentID: agentID),
            isStalled: stepIsStalled(agentID: agentID, now: now))
    }
}

/// Rank and fold exact tool counts using the same legibility contract as per-agent cards.
private func agentRankedToolShares(
    counts: [String: Int],
    limit: Int,
    minimumShare: Double = 0.04
) -> [AgentToolShare] {
    let total = counts.values.reduce(0, +)
    guard total > 0 else { return [] }
    let ranked = counts.map {
        AgentToolShare(
            name: $0.key,
            count: $0.value,
            share: Double($0.value) / Double(total))
    }
    .sorted {
        if $0.count != $1.count { return $0.count > $1.count }
        return $0.name < $1.name
    }

    var head: [AgentToolShare] = []
    for share in ranked {
        guard head.count < limit else { break }
        if share.share < minimumShare, !head.isEmpty { break }
        head.append(share)
    }
    let tail = ranked.dropFirst(head.count)
    guard !tail.isEmpty else { return head }
    let tailCount = tail.reduce(0) { $0 + $1.count }
    return head + [AgentToolShare(
        name: "other",
        count: tailCount,
        share: Double(tailCount) / Double(total))]
}

/// Retains the derived index across unrelated `AgentBridge` publications.
///
/// `Array` storage is copy-on-write, so retaining the last ledger value is cheap while it remains
/// unchanged. A real append/mutation gives the bridge new storage; full value equality then provides
/// a collision-free cache key before rebuilding the index.
final class AgentActivityLedgerIndexCache {
    private var records: [AgentActivityRecord]?
    private var aliases: [String: String] = [:]
    private var cached = AgentActivityLedgerIndex([])
    private(set) var rebuildCount = 0

    /// The alias map is part of the key: reconciliation changes what the same records mean.
    func index(
        for records: [AgentActivityRecord],
        aliases: [String: String] = [:]
    ) -> AgentActivityLedgerIndex {
        guard self.records != records || self.aliases != aliases else { return cached }
        self.records = records
        self.aliases = aliases
        cached = AgentActivityLedgerIndex(records, aliases: aliases)
        rebuildCount += 1
        return cached
    }
}

/// How this agent's tool calls break down by tool.
///
/// Deliberately counts **calls**, not elapsed time. Call counts are exact; per-tool durations would
/// have to be inferred from the gaps between records, and the last call of a run has no end at all —
/// so a "time spent" bar would look more precise than the data supports.
///
/// `limit` keeps the bar readable; everything past it folds into one "other" segment rather than
/// being silently dropped.
func agentToolComposition(
    _ records: [AgentActivityRecord],
    agentID: String,
    limit: Int = 5
) -> [AgentToolShare] {
    AgentActivityLedgerIndex(records).toolComposition(agentID: agentID, limit: limit)
}

/// A compact "3.2s" / "4:07" duration for the card's in-step timer.
func agentStepDurationLabel(_ interval: TimeInterval) -> String {
    let seconds = Int(max(0, interval))
    if seconds < 60 { return "\(seconds)s" }
    return String(format: "%d:%02d", seconds / 60, seconds % 60)
}

/// Reduce a tool's input to the one thing worth showing beside its name.
///
/// Tool inputs are arbitrary JSON and can be enormous (a whole file body on a write). This picks the
/// conventional "what it acted on" key, prefers the tail of a path over its directories, and bounds
/// the result — a card must never be able to grow to the size of a tool payload.
func agentToolTarget(_ input: Any?, limit: Int = 72) -> String? {
    guard let object = input as? [String: Any] else {
        guard let text = input as? String else { return nil }
        return boundedToolTarget(text, limit: limit)
    }
    // Ordered by how specifically each names the work, not alphabetically.
    let keys = [
        "command", "file_path", "path", "filePath", "notebook_path",
        "pattern", "query", "url", "prompt", "description",
    ]
    for key in keys {
        guard let raw = object[key] as? String else { continue }
        guard let value = boundedToolTarget(raw, limit: limit) else { continue }
        // A path is most recognizable by its last components; the leading directories are noise in a
        // control this narrow.
        if key.contains("path") || key == "file_path" {
            let parts = value.split(separator: "/")
            if parts.count > 2 { return parts.suffix(2).joined(separator: "/") }
        }
        return value
    }
    return nil
}

private func boundedToolTarget(_ raw: String, limit: Int) -> String? {
    let collapsed = raw
        .split(whereSeparator: { $0.isNewline || $0 == "\t" })
        .joined(separator: " ")
        .trimmingCharacters(in: .whitespacesAndNewlines)
    guard !collapsed.isEmpty else { return nil }
    guard collapsed.count > limit else { return collapsed }
    return String(collapsed.prefix(limit)) + "…"
}
