import SwiftUI
import AppKit

// Opus workflows surface over the SDK as `system`/task_* messages. agentd flattens them into
// `workflow_update` events, and this reducer folds them into a map of runs, each a phase→agent tree.

enum WorkflowStatus: String, Codable, CaseIterable {
    case pending, running, completed, failed, killed, paused, stopped

    var label: String {
        switch self {
        case .pending: return "Pending"
        case .running: return "Running"
        case .completed: return "Completed"
        case .failed: return "Failed"
        case .killed: return "Killed"
        case .paused: return "Paused"
        case .stopped: return "Stopped"
        }
    }

    /// Ink for the badge's 10-point status label. System green/orange/red are designed primarily
    /// for filled marks and fall below small-text contrast on a white card, so text uses the
    /// appearance-tuned semantic palette shared by the rest of the activity UI.
    var badgeTextNSColor: NSColor {
        switch self {
        case .running: return .nInfoText
        case .completed: return .nSuccessText
        case .failed, .killed: return .nErrorText
        case .paused, .stopped: return .nWarningText
        case .pending: return .secondaryLabelColor
        }
    }

    /// Hue for the badge's broad, translucent capsule. Keep this separate from its ink: the vivid
    /// system colors remain useful as a quiet wash even though they are not legible small text.
    var badgeFillNSColor: NSColor {
        switch self {
        case .running: return .systemBlue
        case .completed: return .systemGreen
        case .failed, .killed: return .systemRed
        case .paused, .stopped: return .systemOrange
        case .pending: return .secondaryLabelColor
        }
    }

    var badgeTextColor: Color { Color(nsColor: badgeTextNSColor) }
    var badgeFillColor: Color { Color(nsColor: badgeFillNSColor) }

    /// Tint for the determinate progress bar — green as work advances and completes (progress is
    /// healthy), red only on an actual failure. Keeps a running bar from reading as alarming.
    var progressColor: Color {
        switch self {
        case .failed, .killed: return .red
        case .paused, .stopped: return .orange
        default: return .green // pending / running / completed
        }
    }

    var isTerminal: Bool {
        self == .completed || self == .failed || self == .killed || self == .stopped
    }

    var needsAttention: Bool { self == .failed || self == .killed }
}

enum WorkflowAgentState: String, Codable {
    case queued, start, progress, done, failed, stopped

    var color: Color {
        switch self {
        case .queued: return .secondary
        case .start, .progress: return .nAccent
        case .done: return .green
        case .failed: return .red
        case .stopped: return .orange
        }
    }

    var isRunning: Bool { self == .start || self == .progress }
    var isTerminal: Bool { self == .done || self == .failed || self == .stopped }

    var label: String {
        switch self {
        case .queued: return "Queued"
        case .start: return "Starting"
        case .progress: return "Working"
        case .done: return "Done"
        case .failed: return "Failed"
        case .stopped: return "Stopped"
        }
    }
}

struct WorkflowUsage: Codable, Equatable {
    /// Usage updates may be partial (Codex publishes thread tokens and observed tool items on
    /// separate notifications), so absence must remain distinct from a reported zero.
    var totalTokens: Int?
    var toolUses: Int?
    var durationMs: Int?
    /// Codex App Server does not publish a tool-call aggregate. When true, `toolUses` is the
    /// number of unique tool-like items Mechanician observed on that child thread.
    var toolUsesObserved: Bool?
    /// Per-model-call breakdown when the provider reports one. `totalTokens` remains the
    /// cumulative/aggregate fallback used by older Claude task events and Codex versions.
    var inputTokens: Int? = nil
    var cachedInputTokens: Int? = nil
    var outputTokens: Int? = nil
    var reasoningOutputTokens: Int? = nil
}

struct WorkflowPhase: Codable, Equatable, Identifiable {
    var index: Int
    var title: String
    var id: Int { index }
}

struct WorkflowAgent: Codable, Equatable, Identifiable {
    var index: Int          // 1-based within its phase
    var label: String
    var phaseIndex: Int
    var phaseTitle: String
    var state: WorkflowAgentState
    var agentId: String?
    var model: String?
    var attempt: Int?
    var lastToolName: String?
    var lastToolSummary: String?
    var promptPreview: String?
    var tokens: Int?
    var toolCalls: Int?
    var resultPreview: String?
    var error: String?
    var durationMs: Int?
    /// Client-observed run window (FR-101): agentd emits no per-agent timestamps, so these are set
    /// when Mechanician first sees the agent running and when it terminalizes — the same honest
    /// convention as `SubagentRun.startedAt` / `WorkflowRun.endedAt`. `durationMs` stays authoritative
    /// when the provider reports it (> 0).
    var startedAt: Date?
    var endedAt: Date?
    /// Ordered tool calls, sampled from `lastToolName` as it changes (FR-101) — the tool-by-tool
    /// timeline the standalone-subagent pane has. agentd forwards only the latest tool plus a count.
    var toolEvents: [SubagentToolEvent] = []

    var id: String { "\(phaseIndex):\(index)" }

    /// A completed provider turn cannot meaningfully consume zero tokens; treat a reported zero as
    /// unavailable rather than surfacing a misleading "0 tok" (mirrors SubagentRun.reportedTokens).
    var reportedTokens: Int? { tokens.flatMap { $0 > 0 ? $0 : nil } }
    var reportedToolCalls: Int? { toolCalls.flatMap { $0 > 0 ? $0 : nil } }
}

struct WorkflowRun: Codable, Equatable, Identifiable {
    var runKey: String
    var sessionId: String?
    var toolUseId: String?
    var runTaskId: String?
    var workflowName: String?
    var description: String = ""
    var summary: String?
    var status: WorkflowStatus = .running
    var usage: WorkflowUsage?
    var outputFile: String?
    var error: String?
    var startedAt: Date = Date()
    var endedAt: Date?
    /// When this run last reported anything at all.
    ///
    /// Every other way a delegate is settled is a process-death event: bridge teardown, runtime
    /// restart, runtime exit, or loading a sidecar with no live bridge. A delegate that simply goes
    /// SILENT — its owning run gone without agentd noticing, because from the daemon's side nothing
    /// died — matches none of them, so it stayed "running" indefinitely. One was observed still
    /// counted as active after eighteen hours, which also stretched the activity trace's time axis
    /// until the root turn's real work was an invisible sliver.
    ///
    /// Optional because this type is persisted: a non-optional addition would fail to decode every
    /// sidecar written before it existed. Absent on older records, which fall back to `startedAt`.
    var lastUpdateAt: Date?
    var phases: [String: WorkflowPhase] = [:]
    var agents: [String: WorkflowAgent] = [:]

    var id: String { runKey }

    /// The most recent evidence this run was alive. A run that has never reported past its own start
    /// is judged from `startedAt`, so a delegate that dies immediately is still reaped.
    var lastLivenessAt: Date { lastUpdateAt ?? startedAt }
}

/// One tool call in a subagent's timeline (FR-90).
struct SubagentToolEvent: Codable, Equatable {
    var name: String
    /// What the tool acted on — the command for a shell call, the path for an edit.
    ///
    /// Optional, and deliberately so: this type is persisted, and a non-optional addition would
    /// fail to decode every sidecar written before it existed. Absent on older records, which then
    /// simply fall back to the tool's own name.
    var target: String?
    /// Provider item identity used only to correlate this visible tool boundary with its separate
    /// harness completion. Optional for older sidecars and providers that do not report one.
    var toolEventID: String? = nil
    var at: Date = Date()
}

/// A standalone subagent (the `Task` tool: Explore, general-purpose, code-reviewer, …),
/// as opposed to a workflow orchestration run. Fed by the Task tool_use/tool_result plus
/// the SDK's task_* progress events.
struct SubagentRun: Identifiable, Equatable, Codable {
    var key: String            // tool_use id (correlates the tool call and its task_* events)
    var taskId: String?        // the SDK task id (for Stop), populated by task_* events
    /// Agent-tree linkage (FR-93). Codex supplies a full `/root/child` path; Claude supplies the
    /// parent subagent's tool_use id. Either resolves this subagent's parent for the tree.
    var agentPath: String?
    var parentToolUseId: String?
    var subagentType: String   // "Explore", "general-purpose", …
    /// The provider-reported model that actually ran this child. Nil is intentional: a child can
    /// inherit provider configuration through rules that differ from the visible parent turn, so
    /// callers must never fill this by guessing the parent's model.
    var model: String? = nil
    var task: String           // the description / prompt preview
    var summary: String?       // live progress line
    /// The subagent's full returned result (FR-90), captured from its Task tool_result. Nil until it
    /// finishes, and for providers that don't surface a tool_result (Codex) — the pane then falls
    /// back to `summary`.
    var resultPreview: String?
    var error: String?         // provider-owned unsupported/capacity/failure explanation
    var lastToolName: String?
    /// Ordered tool calls this subagent made — the tool-by-tool timeline (FR-90). Codex emits one per
    /// observed child tool; Claude samples its reported current tool as it changes.
    var toolEvents: [SubagentToolEvent] = []
    var status: WorkflowStatus = .running
    /// Nil means the provider has not reported this metric. Do not render missing data as zero.
    var tokens: Int?
    var toolUses: Int?
    var toolUsesObserved: Bool?
    var durationMs: Int = 0   // the SDK's own reported duration (authoritative when > 0)
    var startedAt: Date = Date()
    var endedAt: Date?
    /// When this child last reported anything. See `WorkflowRun.lastUpdateAt` for why this exists
    /// and why it is optional; a standalone subagent can go silent in exactly the same way.
    var lastUpdateAt: Date?
    /// Exact capture order for lifecycle boundaries represented by this latest-state projection.
    /// Older sidecars remain nil; converters never infer these values from timestamps.
    var startedCaptureOrdinal: UInt64? = nil
    var endedCaptureOrdinal: UInt64? = nil
    var id: String { key }
    var elapsed: TimeInterval { (endedAt ?? Date()).timeIntervalSince(startedAt) }

    /// The most recent evidence this child was alive. See `WorkflowRun.lastLivenessAt`.
    var lastLivenessAt: Date { lastUpdateAt ?? startedAt }

    /// A completed provider turn cannot meaningfully consume zero tokens. Treat legacy
    /// zero-initialized values as unavailable rather than preserving the old misleading UI.
    var reportedTokens: Int? { tokens.flatMap { $0 > 0 ? $0 : nil } }

    /// An observed Codex count can authoritatively be zero. Older provider aggregate fields are
    /// considered reported only when positive because legacy rows were initialized to zero.
    var reportedToolUses: Int? {
        if toolUsesObserved == true { return toolUses.flatMap { $0 >= 0 ? $0 : nil } }
        return toolUses.flatMap { $0 > 0 ? $0 : nil }
    }

    var toolMetricLabel: String { toolUsesObserved == true ? "observed tools" : "tool calls" }

    /// App Server reports the owning conversation agent through the same lifecycle channel as
    /// delegated children. It is already represented by `AgentActivityIdentity.root`; retaining it
    /// here manufactures an `A… · root` card and double-counts the root as a child.
    var isProviderRootPseudoAgent: Bool { agentPath == "/root" }
}

// MARK: - Tolerant persistence decode

// Swift's SYNTHESIZED `Decodable` calls `decode` (not `decodeIfPresent`) for every non-optional
// stored property and IGNORES its default value, so a delegate persisted by an older build — one
// missing a key added later (e.g. `SubagentRun.toolEvents`, FR-90) — throws `keyNotFound`. Because
// these decode INSIDE the `Conversation` graph, that single throw dropped the ENTIRE conversation on
// load (the 0.11.7 subagent quarantine). Decoding each defaulted field with `decodeIfPresent ?? default`
// keeps old sidecars readable and makes future field additions to these structs non-breaking. Defined
// in extensions so the synthesized memberwise initializer — used at many construction sites — survives.
extension SubagentRun {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(key: try c.decode(String.self, forKey: .key),
                  subagentType: try c.decode(String.self, forKey: .subagentType),
                  task: try c.decode(String.self, forKey: .task))
        taskId = try c.decodeIfPresent(String.self, forKey: .taskId)
        agentPath = try c.decodeIfPresent(String.self, forKey: .agentPath)
        parentToolUseId = try c.decodeIfPresent(String.self, forKey: .parentToolUseId)
        model = try c.decodeIfPresent(String.self, forKey: .model)
        summary = try c.decodeIfPresent(String.self, forKey: .summary)
        resultPreview = try c.decodeIfPresent(String.self, forKey: .resultPreview)
        error = try c.decodeIfPresent(String.self, forKey: .error)
        lastToolName = try c.decodeIfPresent(String.self, forKey: .lastToolName)
        toolEvents = try c.decodeIfPresent([SubagentToolEvent].self, forKey: .toolEvents) ?? []
        status = try c.decodeIfPresent(WorkflowStatus.self, forKey: .status) ?? .running
        tokens = try c.decodeIfPresent(Int.self, forKey: .tokens)
        toolUses = try c.decodeIfPresent(Int.self, forKey: .toolUses)
        toolUsesObserved = try c.decodeIfPresent(Bool.self, forKey: .toolUsesObserved)
        durationMs = try c.decodeIfPresent(Int.self, forKey: .durationMs) ?? 0
        startedAt = try c.decodeIfPresent(Date.self, forKey: .startedAt) ?? Date()
        endedAt = try c.decodeIfPresent(Date.self, forKey: .endedAt)
        lastUpdateAt = try c.decodeIfPresent(Date.self, forKey: .lastUpdateAt)
        startedCaptureOrdinal = (try? c.decodeIfPresent(
            UInt64.self, forKey: .startedCaptureOrdinal)) ?? nil
        endedCaptureOrdinal = (try? c.decodeIfPresent(
            UInt64.self, forKey: .endedCaptureOrdinal)) ?? nil
    }
}

extension WorkflowRun {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(runKey: try c.decode(String.self, forKey: .runKey))
        sessionId = try c.decodeIfPresent(String.self, forKey: .sessionId)
        toolUseId = try c.decodeIfPresent(String.self, forKey: .toolUseId)
        runTaskId = try c.decodeIfPresent(String.self, forKey: .runTaskId)
        workflowName = try c.decodeIfPresent(String.self, forKey: .workflowName)
        description = try c.decodeIfPresent(String.self, forKey: .description) ?? ""
        summary = try c.decodeIfPresent(String.self, forKey: .summary)
        status = try c.decodeIfPresent(WorkflowStatus.self, forKey: .status) ?? .running
        usage = try c.decodeIfPresent(WorkflowUsage.self, forKey: .usage)
        outputFile = try c.decodeIfPresent(String.self, forKey: .outputFile)
        error = try c.decodeIfPresent(String.self, forKey: .error)
        startedAt = try c.decodeIfPresent(Date.self, forKey: .startedAt) ?? Date()
        endedAt = try c.decodeIfPresent(Date.self, forKey: .endedAt)
        lastUpdateAt = try c.decodeIfPresent(Date.self, forKey: .lastUpdateAt)
        phases = try c.decodeIfPresent([String: WorkflowPhase].self, forKey: .phases) ?? [:]
        agents = try c.decodeIfPresent([String: WorkflowAgent].self, forKey: .agents) ?? [:]
    }
}

// WorkflowAgent decodes INSIDE the persisted WorkflowRun (which decodes inside the Conversation
// graph), so it is subject to the same Codable-default trap: a synthesized decoder would throw
// keyNotFound for any field a newer build added (e.g. `toolEvents`, FR-101), and — because the
// `agents` dictionary decode is not per-element tolerant — that single throw quarantines the whole
// conversation. Decode every field with decodeIfPresent so future additions stay non-breaking. The
// custom init lives in an extension so the memberwise initializer (used at construction sites) survives.
private func boundedWorkflowToolEventID(_ value: String?) -> String? {
    guard let value, value.utf8.count <= 160 else { return nil }
    return agentHarnessBoundedToken(value, maximum: 160)
}

extension SubagentToolEvent {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        target = (try? c.decodeIfPresent(String.self, forKey: .target)) ?? nil
        toolEventID = boundedWorkflowToolEventID(
            (try? c.decodeIfPresent(String.self, forKey: .toolEventID)) ?? nil)
        at = (try? c.decodeIfPresent(Date.self, forKey: .at)) ?? Date()
    }
}

extension WorkflowAgent {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(index: try c.decode(Int.self, forKey: .index),
                  label: try c.decodeIfPresent(String.self, forKey: .label) ?? "",
                  phaseIndex: try c.decode(Int.self, forKey: .phaseIndex),
                  phaseTitle: try c.decodeIfPresent(String.self, forKey: .phaseTitle) ?? "",
                  state: try c.decodeIfPresent(WorkflowAgentState.self, forKey: .state) ?? .queued)
        agentId = try c.decodeIfPresent(String.self, forKey: .agentId)
        model = try c.decodeIfPresent(String.self, forKey: .model)
        attempt = try c.decodeIfPresent(Int.self, forKey: .attempt)
        lastToolName = try c.decodeIfPresent(String.self, forKey: .lastToolName)
        lastToolSummary = try c.decodeIfPresent(String.self, forKey: .lastToolSummary)
        promptPreview = try c.decodeIfPresent(String.self, forKey: .promptPreview)
        tokens = try c.decodeIfPresent(Int.self, forKey: .tokens)
        toolCalls = try c.decodeIfPresent(Int.self, forKey: .toolCalls)
        resultPreview = try c.decodeIfPresent(String.self, forKey: .resultPreview)
        error = try c.decodeIfPresent(String.self, forKey: .error)
        durationMs = try c.decodeIfPresent(Int.self, forKey: .durationMs)
        startedAt = try c.decodeIfPresent(Date.self, forKey: .startedAt)
        endedAt = try c.decodeIfPresent(Date.self, forKey: .endedAt)
        toolEvents = try c.decodeIfPresent([SubagentToolEvent].self, forKey: .toolEvents) ?? []
    }
}

/// A provider child can appear both as a standalone subagent and inside a genuine provider workflow.
/// Count authoritative provider ids once, while keeping id-less standalone/workflow children
/// distinct. Mechanician does not synthesize a Codex workflow merely to group its children.
private enum RunningAgentIdentity: Hashable {
    case provider(String)
    case standalone(String)
    case workflow(run: String, agent: String)
    case workflowRun(String)
}

func runningDelegatedAgentCount(subagents: [String: SubagentRun],
                                workflowRuns: [String: WorkflowRun]) -> Int {
    var identities: Set<RunningAgentIdentity> = []

    for (storageKey, subagent) in subagents
    where subagent.status == .running && !subagent.isProviderRootPseudoAgent {
        if let taskId = subagent.taskId, !taskId.isEmpty {
            identities.insert(.provider(taskId))
        } else {
            identities.insert(.standalone(subagent.key.isEmpty ? storageKey : subagent.key))
        }
    }

    // An aggregate can arrive terminal before its final child update. The child remains live work
    // until its own state is terminal, so do not hide it behind the aggregate lifecycle.
    for (storageKey, run) in workflowRuns {
        let runKey = run.runKey.isEmpty ? storageKey : run.runKey
        for (agentKey, agent) in run.agents where agent.state.isRunning {
            if let agentId = agent.agentId, !agentId.isEmpty {
                identities.insert(.provider(agentId))
            } else {
                identities.insert(.workflow(run: runKey, agent: agentKey))
            }
        }
    }

    return identities.count
}

/// Conversation blockers count conceptual delegated workers, not storage rows.
///
/// Providers may mirror one child as both a standalone subagent and a workflow member; its provider
/// id collapses those records to one identity. A live top-level workflow with no nonterminal child
/// yet still owns work, so it contributes one fallback identity until its child graph appears.
func blockingDelegatedAgentCount(
    subagents: [String: SubagentRun],
    workflowRuns: [String: WorkflowRun]
) -> Int {
    var identities: Set<RunningAgentIdentity> = []

    for (storageKey, subagent) in subagents
    where !subagent.status.isTerminal && !subagent.isProviderRootPseudoAgent {
        if let taskID = subagent.taskId, !taskID.isEmpty {
            identities.insert(.provider(taskID))
        } else {
            identities.insert(.standalone(subagent.key.isEmpty ? storageKey : subagent.key))
        }
    }

    for (storageKey, run) in workflowRuns {
        let runKey = run.runKey.isEmpty ? storageKey : run.runKey
        var hasNonterminalChild = false
        for (agentKey, agent) in run.agents where !agent.state.isTerminal {
            hasNonterminalChild = true
            if let agentID = agent.agentId, !agentID.isEmpty {
                identities.insert(.provider(agentID))
            } else {
                identities.insert(.workflow(run: runKey, agent: agentKey))
            }
        }
        if !run.status.isTerminal && !hasNonterminalChild {
            identities.insert(.workflowRun(runKey))
        }
    }

    return identities.count
}

/// A single decoded `workflow_update` event from agentd.
struct WorkflowUpdate {
    var phase: String  // started | progress | updated | notification
    var taskId: String
    var toolUseId: String?
    var isWorkflowRun: Bool
    var workflowName: String?
    var taskType: String?
    var subagentType: String?
    var model: String?
    var description: String?
    var summary: String?
    var resultPreview: String?
    var agentPath: String?
    var parentToolUseId: String?
    var toolEvent: String?
    /// Bounded provider item identity for correlating the visible child-tool event with its
    /// separately reported harness completion.
    var toolEventID: String?
    /// Claude provider-query identity for reconciling child usage with an agent-tree final without
    /// erasing child work from an earlier recovery query in the same Mechanician turn.
    var providerQuerySequence: Int?
    /// What that tool acted on, when the provider reports it.
    var toolTarget: String?
    var lastToolName: String?
    var status: WorkflowStatus?
    var usage: WorkflowUsage?
    var outputFile: String?
    var error: String?
    var workflowProgress: [[String: Any]]?

    init(_ e: [String: Any]) {
        phase = e["phase"] as? String ?? ""
        taskId = e["taskId"] as? String ?? ""
        toolUseId = (e["toolUseId"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        isWorkflowRun = e["isWorkflowRun"] as? Bool ?? false
        workflowName = e["workflowName"] as? String
        taskType = e["taskType"] as? String
        subagentType = e["subagentType"] as? String
        model = (e["model"] as? String).flatMap {
            let value = $0.trimmingCharacters(in: .whitespacesAndNewlines)
            return value.isEmpty ? nil : value
        }
        description = e["description"] as? String
        summary = e["summary"] as? String
        resultPreview = e["resultPreview"] as? String
        agentPath = e["agentPath"] as? String
        parentToolUseId = e["parentToolUseId"] as? String
        toolEvent = e["toolEvent"] as? String
        toolEventID = boundedWorkflowToolEventID(e["toolEventID"] as? String)
        providerQuerySequence = agentHarnessBoundedCount(
            e["providerQuerySequence"] as? Int).flatMap { $0 > 0 ? $0 : nil }
        toolTarget = e["toolTarget"] as? String
        lastToolName = e["lastToolName"] as? String
        status = (e["status"] as? String).flatMap { WorkflowStatus(rawValue: $0) }
        outputFile = e["outputFile"] as? String
        error = e["error"] as? String
        if let u = e["usage"] as? [String: Any] {
            usage = WorkflowUsage(totalTokens: u["totalTokens"] as? Int,
                                  toolUses: u["toolUses"] as? Int,
                                  durationMs: u["durationMs"] as? Int,
                                  toolUsesObserved: u["toolUsesObserved"] as? Bool,
                                  inputTokens: u["inputTokens"] as? Int,
                                  cachedInputTokens: u["cachedInputTokens"] as? Int,
                                  outputTokens: u["outputTokens"] as? Int,
                                  reasoningOutputTokens: u["reasoningOutputTokens"] as? Int)
        }
        workflowProgress = e["workflowProgress"] as? [[String: Any]]
    }
}

extension WorkflowUpdate {
    /// Codex has two provider-authored retask boundaries. MultiAgentV2 reports `interacted`; the
    /// legacy collaboration shape reports `sendInput`. These are stronger evidence than an ordinary
    /// running notification and opens a new lifecycle generation for an existing child.
    var startsNewSubagentLifecycleGeneration: Bool {
        guard taskType == "codex_subagent", status == .running else { return false }
        switch lastToolName?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "interacted", "sendinput": return true
        default: return false
        }
    }
}

// MARK: Reducer

/// Terminal lifecycle is monotonic. The one intentional refinement is success -> failure when a
/// later provider event supplies authoritative failure evidence; cancellation/failure can never be
/// rewritten as success by buffered completion.
private func reconciledWorkflowStatus(
    current: WorkflowStatus,
    incoming: WorkflowStatus
) -> WorkflowStatus {
    guard current.isTerminal else { return incoming }
    if current == .completed, incoming == .failed || incoming == .killed {
        return incoming
    }
    return current
}

private func reconciledWorkflowAgentState(
    current: WorkflowAgentState,
    incoming: WorkflowAgentState
) -> WorkflowAgentState {
    guard current.isTerminal else { return incoming }
    if current == .done, incoming == .failed { return .failed }
    return current
}

/// Combine partial provider usage snapshots without erasing fields carried by an earlier event.
/// Aggregate counters are cumulative and therefore monotonic; the input/output breakdown describes
/// the provider's latest reported model call, so each present component replaces only itself.
private func mergedWorkflowUsage(
    _ current: WorkflowUsage?,
    _ incoming: WorkflowUsage
) -> WorkflowUsage {
    guard let current else { return incoming }
    return WorkflowUsage(
        totalTokens: maxOptional(current.totalTokens, incoming.totalTokens),
        toolUses: maxOptional(current.toolUses, incoming.toolUses),
        durationMs: maxOptional(current.durationMs, incoming.durationMs),
        toolUsesObserved: current.toolUsesObserved == true || incoming.toolUsesObserved == true
            ? true
            : (incoming.toolUsesObserved ?? current.toolUsesObserved),
        inputTokens: incoming.inputTokens ?? current.inputTokens,
        cachedInputTokens: incoming.cachedInputTokens ?? current.cachedInputTokens,
        outputTokens: incoming.outputTokens ?? current.outputTokens,
        reasoningOutputTokens:
            incoming.reasoningOutputTokens ?? current.reasoningOutputTokens)
}

/// Fold one update into the runs map:
/// mint a run only for genuine workflow starts, correlate by runTaskId/toolUseId,
/// and merge the phase/agent tree rather than replacing it.
func applyWorkflowUpdate(_ runs: [String: WorkflowRun], _ u: WorkflowUpdate,
                         sessionId: String?) -> [String: WorkflowRun] {
    var runs = runs
    let isRunStart = u.isWorkflowRun || u.taskType == "local_workflow"
        || (u.workflowProgress?.isEmpty == false)

    // Locate the owning run: by its run-level task id, else by tool_use key, else task id.
    var key = runs.first(where: { $0.value.runTaskId == u.taskId })?.key
    if key == nil, let tid = u.toolUseId, runs[tid] != nil { key = tid }
    if key == nil, runs[u.taskId] != nil { key = u.taskId }

    if key == nil {
        guard isRunStart else { return runs } // never synthesize a ghost run for a stray child
        let k = u.toolUseId ?? u.taskId
        runs[k] = WorkflowRun(runKey: k, sessionId: sessionId, toolUseId: u.toolUseId,
                              runTaskId: u.taskId, workflowName: u.workflowName,
                              description: u.description ?? "", status: .running)
        key = k
    }

    guard let k = key, var run = runs[k] else { return runs }

    if run.runTaskId == nil || run.runTaskId?.isEmpty == true { run.runTaskId = u.taskId }
    if run.toolUseId == nil, let tid = u.toolUseId { run.toolUseId = tid }
    if run.workflowName == nil, let n = u.workflowName { run.workflowName = n }
    if let d = u.description, !d.isEmpty { run.description = d }
    if let s = u.summary { run.summary = s }
    if let usage = u.usage { run.usage = mergedWorkflowUsage(run.usage, usage) }
    if let out = u.outputFile { run.outputFile = out }
    if let err = u.error, !err.isEmpty { run.error = err }

    if let wp = u.workflowProgress { ingestWorkflowProgress(&run, wp) }

    // Terminal provider state is monotonic. Buffered progress frequently arrives after a local
    // stop/provider-failure reconciliation; it may add metrics or result text above, but it cannot
    // put the aggregate run back into pending/running. A later terminal status remains an explicit
    // provider refinement (for example completed -> failed after a child error).
    if let st = u.status {
        run.status = reconciledWorkflowStatus(current: run.status, incoming: st)
    }
    // An error with no explicit status still forces failed.
    if run.error != nil, !run.status.isTerminal, u.status == nil, u.phase == "updated" {
        run.status = .failed
    }
    if run.status.isTerminal, run.endedAt == nil { run.endedAt = Date() }
    // Every fold, whatever it carried. This is the only evidence that the run is still alive, and
    // the staleness reaper reads nothing else — so it must be stamped for progress, notifications
    // and updates alike, not only for the ones that change status.
    run.lastUpdateAt = Date()

    runs[k] = run
    return runs
}

/// Merge the SDK's cumulative-by-event workflow_progress array: phases keyed by
/// index, agents by "phaseIndex:index", shallow-merging so unset fields persist.
func ingestWorkflowProgress(_ run: inout WorkflowRun, _ entries: [[String: Any]]) {
    for e in entries {
        switch e["type"] as? String {
        case "workflow_phase":
            guard let idx = e["index"] as? Int else { continue }
            run.phases[String(idx)] = WorkflowPhase(index: idx, title: e["title"] as? String ?? "")
        case "workflow_agent":
            guard let idx = e["index"] as? Int, let phaseIndex = e["phaseIndex"] as? Int else { continue }
            let key = "\(phaseIndex):\(idx)"
            // A terminal aggregate may still receive a cumulative metrics/result snapshot for a
            // child it already knows. It must not manufacture a brand-new live child after local
            // reconciliation closed the workflow.
            if run.status.isTerminal, run.agents[key] == nil { continue }
            var a = run.agents[key] ?? WorkflowAgent(index: idx, label: "", phaseIndex: phaseIndex,
                                                     phaseTitle: "", state: .queued)
            if let v = e["label"] as? String { a.label = v }
            if let v = e["phaseTitle"] as? String { a.phaseTitle = v }
            // The live CLI emits "error" for a failed workflow child, but WorkflowAgentState has
            // no "error" case, so the raw value was silently dropped and failed children stuck at
            // progress forever — leaving effectiveRunStatus's failed-child branch unreachable. Map
            // the wire alias onto the canonical .failed state at this one ingest boundary.
            if let v = e["state"] as? String {
                let next = WorkflowAgentState(rawValue: v) ?? (v == "error" ? .failed : nil)
                if let next {
                    // Once the aggregate has been terminalized, cumulative progress is metadata,
                    // not permission to replay a live lifecycle. An existing nonterminal child may
                    // still receive its authoritative terminal event after the aggregate terminal
                    // event (provider ordering is not guaranteed); active states remain ignored.
                    if run.status.isTerminal {
                        if a.state.isTerminal {
                            a.state = reconciledWorkflowAgentState(
                                current: a.state, incoming: next)
                        } else if next.isTerminal {
                            a.state = next
                        }
                    } else {
                        a.state = reconciledWorkflowAgentState(
                            current: a.state, incoming: next)
                    }
                }
            }
            if let v = e["agentId"] as? String { a.agentId = v }
            if let v = e["model"] as? String {
                let model = v.trimmingCharacters(in: .whitespacesAndNewlines)
                if !model.isEmpty { a.model = model }
            }
            if let v = e["attempt"] as? Int { a.attempt = v }
            if let v = e["lastToolName"] as? String {
                a.lastToolName = v
                // Sample the tool timeline as the current tool changes (FR-101), mirroring the
                // standalone-subagent sampler — agentd forwards only the latest tool plus a count.
                if !v.isEmpty, a.toolEvents.last?.name != v {
                    a.toolEvents.append(SubagentToolEvent(name: v))
                    if a.toolEvents.count > 200 { a.toolEvents.removeFirst(a.toolEvents.count - 200) }
                }
            }
            if let v = e["lastToolSummary"] as? String { a.lastToolSummary = v }
            if let v = e["promptPreview"] as? String { a.promptPreview = v }
            if let v = e["tokens"] as? Int { a.tokens = v }
            if let v = e["toolCalls"] as? Int { a.toolCalls = v }
            if let v = e["resultPreview"] as? String { a.resultPreview = v }
            if let v = e["error"] as? String { a.error = v }
            if let v = e["durationMs"] as? Int { a.durationMs = v }
            if a.error != nil, !a.state.isTerminal, !run.status.isTerminal {
                a.state = .failed
            }
            // Client-observed run window (FR-101): the first time we see it running (or already
            // terminal) stamps startedAt; a terminal state stamps endedAt. Set once (nil guards),
            // since workflow_progress arrays are cumulative and re-report the same agent repeatedly.
            let observedAt = Date()
            if a.startedAt == nil, a.state.isRunning || a.state.isTerminal {
                a.startedAt = observedAt
            }
            if a.endedAt == nil, a.state.isTerminal {
                a.endedAt = observedAt
            }
            run.agents[key] = a
        default:
            continue
        }
    }
}

/// Whether an update belongs to a workflow orchestration run (vs a standalone subagent).
func isWorkflowUpdate(_ u: WorkflowUpdate) -> Bool {
    u.isWorkflowRun || u.taskType == "local_workflow" || (u.workflowProgress?.isEmpty == false)
}

/// Retire the provisional standalone Task row once provider evidence identifies that same tool
/// call as a workflow aggregate.
///
/// A Task tool frame arrives before its workflow lifecycle update, so the app deliberately creates
/// a provisional subagent card for immediate feedback. If the later update proves that Task owns a
/// workflow, keeping both representations leaves the provisional card running forever: the
/// workflow terminalizes, while no standalone child notification will ever close the mirror. The
/// workflow run is the sole live representation from that point forward. Remove only the run's
/// exact tool-use identity; child agents nested inside the run have different provider identities.
@discardableResult
func collapseWorkflowAggregateMirrors(
    workflowRuns: [String: WorkflowRun],
    subagents: inout [String: SubagentRun],
    agentActivity: inout [AgentActivityRecord]
) -> Bool {
    let aggregateIDs = Set(workflowRuns.values.flatMap { run in
        [run.toolUseId, run.runTaskId].compactMap { raw -> String? in
            guard let value = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !value.isEmpty else { return nil }
            return value
        }
    })
    guard !aggregateIDs.isEmpty else { return false }

    var mirrorActivityIDs = Set(aggregateIDs.map(AgentActivityIdentity.subagent))
    let previousSubagentCount = subagents.count
    subagents = subagents.filter { storageKey, subagent in
        let isMirror = aggregateIDs.contains(storageKey)
            || aggregateIDs.contains(subagent.key)
            || subagent.taskId.map(aggregateIDs.contains) == true
        if isMirror {
            mirrorActivityIDs.insert(AgentActivityIdentity.subagent(storageKey))
            mirrorActivityIDs.insert(AgentActivityIdentity.subagent(subagent.key))
            if let taskID = subagent.taskId, !taskID.isEmpty {
                mirrorActivityIDs.insert(AgentActivityIdentity.subagent(taskID))
            }
        }
        return !isMirror
    }

    // Remove only transitions manufactured by the provisional Task card. Other state/tool/token
    // samples may describe real nested work attributed through this parent tool identity; deleting
    // them would turn a UI de-duplication repair into portable activity loss.
    let previousActivityCount = agentActivity.count
    agentActivity.removeAll {
        guard $0.kind == .state, mirrorActivityIDs.contains($0.agentID) else { return false }
        if $0.phase == .model, $0.detail == "Delegated" { return true }
        if $0.phase == .completed, $0.detail == "Delegated task completed" { return true }
        if $0.phase == .failed, $0.detail == "Delegated task failed" { return true }
        return false
    }
    return subagents.count != previousSubagentCount
        || agentActivity.count != previousActivityCount
}

/// Fold the metadata carried by an Agent/Task `tool_use` into its lifecycle row.
///
/// Claude can report `task_started` before the assistant frame containing the corresponding
/// `tool_use`. The lifecycle event knows the child id, but only the later assistant frame knows
/// which subagent authored a nested Agent call (`parentToolUseId`). Always revisit an existing row
/// so that out-of-order nested calls gain their parent edge instead of remaining false roots.
func applySubagentToolUse(
    _ subs: [String: SubagentRun],
    toolUseId: String,
    parentToolUseId: String?,
    subagentType: String,
    task: String,
    captureOrdinal: UInt64? = nil
) -> [String: SubagentRun] {
    let toolUseId = toolUseId.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !toolUseId.isEmpty else { return subs }

    var subs = subs
    let existed = subs[toolUseId] != nil
    var child = subs[toolUseId] ?? SubagentRun(
        key: toolUseId,
        subagentType: subagentType,
        task: task)
    if !existed, child.startedCaptureOrdinal == nil {
        child.startedCaptureOrdinal = captureOrdinal
    }

    let type = subagentType.trimmingCharacters(in: .whitespacesAndNewlines)
    if !type.isEmpty,
       (child.subagentType.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        || child.subagentType == "agent") {
        child.subagentType = type
    }
    if child.task.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !task.isEmpty {
        child.task = task
    }
    if let parent = parentToolUseId?.trimmingCharacters(in: .whitespacesAndNewlines),
       !parent.isEmpty, parent != toolUseId {
        child.parentToolUseId = parent
    }
    subs[toolUseId] = child
    return subs
}

/// Fold a standalone-subagent update into the subagents map. Correlates by tool_use id OR
/// task id (events may carry only one) so all of a subagent's events land on ONE card —
/// mirroring applyWorkflowUpdate. Without this, a taskId-only event spawns a duplicate
/// card with a fresh start time (0s elapsed) and a stop id the SDK doesn't recognize.
func applySubagentUpdate(
    _ subs: [String: SubagentRun],
    _ u: WorkflowUpdate,
    captureOrdinal: UInt64? = nil,
    observedAt: Date = Date()
) -> [String: SubagentRun] {
    // Defense in depth for older/future daemon adapters: `/root` is the provider's owning agent,
    // never a delegated child. Also remove a previously persisted pseudo-row when a later update
    // for the same provider thread omits the path.
    if u.agentPath == "/root" {
        return subs.filter { _, subagent in
            subagent.agentPath != "/root"
                && subagent.taskId != u.taskId
                && subagent.key != u.taskId
                && subagent.key != u.toolUseId
        }
    }
    var subs = subs.filter { !$0.value.isProviderRootPseudoAgent }
    let toolKey = u.toolUseId.flatMap { subs[$0] == nil ? nil : $0 }
    let taskKey: String? = {
        guard !u.taskId.isEmpty else { return nil }
        if subs[u.taskId] != nil { return u.taskId }
        return subs.first(where: { $0.value.taskId == u.taskId })?.key
    }()

    // App Server may publish the authoritative subAgentActivity identity before completing the
    // provisional spawnAgent item. Once an update contains both ids, collapse those two records
    // into the spawn-owned row instead of showing the same child twice.
    var key = toolKey ?? taskKey
    if let toolKey, let taskKey, toolKey != taskKey,
       var preferred = subs[toolKey], let duplicate = subs[taskKey] {
        if preferred.taskId == nil { preferred.taskId = duplicate.taskId }
        if preferred.subagentType.isEmpty || preferred.subagentType == "agent" {
            preferred.subagentType = duplicate.subagentType
        }
        if preferred.task.isEmpty { preferred.task = duplicate.task }
        if let summary = duplicate.summary, !summary.isEmpty { preferred.summary = summary }
        if let result = duplicate.resultPreview, !result.isEmpty { preferred.resultPreview = result }
        if let error = duplicate.error, !error.isEmpty { preferred.error = error }
        if let model = duplicate.model, !model.isEmpty { preferred.model = model }
        if let tool = duplicate.lastToolName, !tool.isEmpty { preferred.lastToolName = tool }
        if preferred.agentPath?.isEmpty != false,
           let path = duplicate.agentPath, !path.isEmpty {
            preferred.agentPath = path
        }
        if preferred.parentToolUseId?.isEmpty != false,
           let parent = duplicate.parentToolUseId, !parent.isEmpty {
            preferred.parentToolUseId = parent
        }
        preferred.tokens = maxOptional(preferred.tokens, duplicate.tokens)
        preferred.toolUses = maxOptional(preferred.toolUses, duplicate.toolUses)
        if duplicate.toolUsesObserved == true { preferred.toolUsesObserved = true }
        preferred.durationMs = max(preferred.durationMs, duplicate.durationMs)
        preferred.startedAt = min(preferred.startedAt, duplicate.startedAt)
        if let duplicateStart = duplicate.startedCaptureOrdinal {
            preferred.startedCaptureOrdinal = min(
                preferred.startedCaptureOrdinal ?? duplicateStart,
                duplicateStart)
        }
        if duplicate.status.isTerminal && !preferred.status.isTerminal {
            preferred.status = duplicate.status
        }
        if let ended = duplicate.endedAt {
            if let existingEnd = preferred.endedAt {
                if ended > existingEnd { preferred.endedAt = ended }
            } else {
                preferred.endedAt = ended
            }
        }
        if let duplicateEnd = duplicate.endedCaptureOrdinal {
            preferred.endedCaptureOrdinal = max(
                preferred.endedCaptureOrdinal ?? duplicateEnd,
                duplicateEnd)
        }
        subs[toolKey] = preferred
        subs.removeValue(forKey: taskKey)
        key = toolKey
    }
    let k = key ?? (u.toolUseId ?? u.taskId)
    guard !k.isEmpty else { return subs }
    let existed = subs[k] != nil
    var s = subs[k] ?? SubagentRun(key: k, subagentType: u.subagentType ?? "agent",
                                   task: u.description ?? "")
    if !existed, s.startedCaptureOrdinal == nil {
        s.startedCaptureOrdinal = captureOrdinal
    }
    // A provider-authored retask is the sole exception to cumulative terminal monotonicity. The
    // same durable child thread is doing new work, so safety projections must see it as live again,
    // not merely the Activity renderer. Preserve cumulative usage and tool evidence, but clear the
    // prior generation's terminal presentation and give the new generation its own local boundary.
    if u.startsNewSubagentLifecycleGeneration {
        s.status = .running
        s.startedAt = observedAt
        s.endedAt = nil
        s.lastUpdateAt = observedAt
        s.startedCaptureOrdinal = captureOrdinal
        s.endedCaptureOrdinal = nil
        s.summary = nil
        s.resultPreview = nil
        s.error = nil
    }
    if !u.taskId.isEmpty { s.taskId = u.taskId }
    if let t = u.subagentType, !t.isEmpty { s.subagentType = t }
    // Provider metadata is last-nonempty and remains enrichable after terminalization. A reroute
    // is authoritative new information, while an absent/empty future event must not erase it.
    if let model = u.model { s.model = model }
    if let d = u.description, !d.isEmpty { s.task = d }
    if let sm = u.summary { s.summary = sm }
    if let rp = u.resultPreview, !rp.isEmpty { s.resultPreview = rp }   // Codex FINAL_ANSWER (FR-90)
    if let ap = u.agentPath, !ap.isEmpty { s.agentPath = ap }           // agent tree (FR-93)
    if let pid = u.parentToolUseId, !pid.isEmpty { s.parentToolUseId = pid }
    if let error = u.error, !error.isEmpty { s.error = error }
    // Tool-by-tool timeline (FR-90): Codex sends an explicit per-tool event; Claude reports its real
    // current tool, so sample its changes. Capped so a long run can't grow unbounded.
    if let te = u.toolEvent, !te.isEmpty {
        s.toolEvents.append(SubagentToolEvent(
            name: te,
            target: u.toolTarget.flatMap { $0.isEmpty ? nil : $0 },
            toolEventID: u.toolEventID))
    }
    if let lt = u.lastToolName, !lt.isEmpty {
        if s.subagentType != "Codex", s.toolEvents.last?.name != lt {
            s.toolEvents.append(SubagentToolEvent(name: lt))
        }
        s.lastToolName = lt
    }
    if s.toolEvents.count > 200 { s.toolEvents.removeFirst(s.toolEvents.count - 200) }
    if let usage = u.usage {
        if let tokens = usage.totalTokens { s.tokens = tokens }
        if let toolUses = usage.toolUses { s.toolUses = toolUses }
        if usage.toolUsesObserved == true { s.toolUsesObserved = true }
        if let durationMs = usage.durationMs, durationMs > 0 { s.durationMs = durationMs }
    }
    // Within one provider-authored generation terminal state is monotonic. A late ordinary progress
    // notification must not resurrect a completed, failed, or stopped child after reconciliation.
    if let st = u.status {
        s.status = reconciledWorkflowStatus(current: s.status, incoming: st)
    }
    // A child that reported an error but carries no terminal status of its own has failed —
    // route it to Needs attention instead of leaving it in Active with a red label (symmetric
    // with the run reducer at :275). Never override an already-terminal status.
    if s.error != nil, !s.status.isTerminal { s.status = .failed }
    if s.status.isTerminal, s.endedAt == nil {
        s.endedAt = observedAt
        s.endedCaptureOrdinal = captureOrdinal
    }
    if s.isProviderRootPseudoAgent {
        subs.removeValue(forKey: k)
        return subs
    }
    // Every fold, for the same reason as the run reducer: this is the only evidence the child is
    // still alive, and the staleness reaper reads nothing else. Missing it here would let a healthy
    // long-running child be judged from `startedAt` and reaped while it was still working.
    s.lastUpdateAt = observedAt
    subs[k] = s
    return subs
}

private func maxOptional(_ lhs: Int?, _ rhs: Int?) -> Int? {
    switch (lhs, rhs) {
    case let (lhs?, rhs?): return max(lhs, rhs)
    case let (lhs?, nil): return lhs
    case let (nil, rhs?): return rhs
    case (nil, nil): return nil
    }
}

// MARK: Agent tree (FR-93)

/// One node in the delegated-agent tree: a subagent plus its children.
struct SubagentTreeNode: Identifiable, Equatable {
    let sub: SubagentRun
    var children: [SubagentTreeNode]
    var id: String { sub.id }
    /// Total subagents in this subtree (including self) — for a "3 agents" rollup on a collapsed node.
    var count: Int { 1 + children.reduce(0) { $0 + $1.count } }
    /// Subtree-wide status so a running/failed descendant buckets its whole tree correctly (and can't
    /// hide inside a collapsed Completed section).
    var hasRunning: Bool { !sub.status.isTerminal || children.contains { $0.hasRunning } }
    var hasAttention: Bool { sub.status.needsAttention || children.contains { $0.hasAttention } }

    /// The same subtree reduced to the agents that did not finish, plus the ancestors that lead to
    /// them.
    ///
    /// Bucketing is by subtree, so one failed grandchild puts its whole tree in the section — and
    /// the section then rendered every descendant, healthy ones included. A single failure read as a
    /// large tree of troubled agents. Keeping the ancestors preserves where the failure happened;
    /// dropping the branches that contain no failure keeps the section about what actually failed.
    func prunedToAttention() -> SubagentTreeNode? {
        let kept = children.compactMap { $0.prunedToAttention() }
        guard sub.status.needsAttention || !kept.isEmpty else { return nil }
        return SubagentTreeNode(sub: sub, children: kept)
    }
}

/// Resolve a subagent's parent key: Claude via `parentToolUseId` (the parent subagent's tool-use
/// id); Codex via `agentPath` (this path minus its last segment). Nil = spawned by the turn (a root).
func subagentParentKey(_ s: SubagentRun, in subs: [String: SubagentRun]) -> String? {
    if let pid = s.parentToolUseId, !pid.isEmpty, subs[pid] != nil { return pid }
    if let path = s.agentPath {
        let parts = path.split(separator: "/").filter { !$0.isEmpty }
        if parts.count >= 2 {
            let parentPath = "/" + parts.dropLast().joined(separator: "/")
            if let parent = subs.values.first(where: { $0.agentPath == parentPath }) { return parent.key }
        }
    }
    return nil
}

/// Build the parent→children forest from the flat subagent map. Roots (no resolvable parent) and
/// each level are ordered by start time; cycle-safe via a visited set. Pure, so it's unit-tested.
func subagentForest(_ subs: [String: SubagentRun]) -> [SubagentTreeNode] {
    let all = Array(subs.values)
    let childrenByParent = Dictionary(grouping: all.compactMap { s in
        subagentParentKey(s, in: subs).map { (parent: $0, child: s) }
    }, by: { $0.parent }).mapValues { $0.map(\.child) }
    func node(_ s: SubagentRun, _ visited: Set<String>) -> SubagentTreeNode {
        guard !visited.contains(s.key) else { return SubagentTreeNode(sub: s, children: []) }
        let seen = visited.union([s.key])
        let kids = (childrenByParent[s.key] ?? []).sorted { $0.startedAt < $1.startedAt }
        return SubagentTreeNode(sub: s, children: kids.map { node($0, seen) })
    }
    return all
        .filter { subagentParentKey($0, in: subs) == nil }
        .sorted { $0.startedAt < $1.startedAt }
        .map { node($0, []) }
}

// MARK: Aggregation helpers

struct RunStats {
    var agents = 0
    var done = 0
    var tokens = 0
    var toolUses = 0
}

func runStats(_ run: WorkflowRun) -> RunStats {
    var s = RunStats()
    s.agents = run.agents.count
    s.done = run.agents.values.filter { $0.state == .done }.count
    s.tokens = run.usage?.totalTokens ?? run.agents.values.reduce(0) { $0 + ($1.tokens ?? 0) }
    s.toolUses = run.usage?.toolUses ?? run.agents.values.reduce(0) { $0 + ($1.toolCalls ?? 0) }
    return s
}

/// A "completed" run that carries an error or a failed agent displays as failed.
func effectiveRunStatus(_ run: WorkflowRun) -> WorkflowStatus {
    if run.status == .completed,
       run.error != nil || run.agents.values.contains(where: { $0.state == .failed }) {
        return .failed
    }
    return run.status
}

/// Agents grouped under their phase, both sorted by index.
func runPhaseTree(_ run: WorkflowRun) -> [(phase: WorkflowPhase, agents: [WorkflowAgent])] {
    run.phases.values.sorted { $0.index < $1.index }.map { phase in
        let agents = run.agents.values
            .filter { $0.phaseIndex == phase.index }
            .sorted { $0.index < $1.index }
        return (phase, agents)
    }
}

func formatTokens(_ n: Int) -> String {
    if n >= 1_000_000 { return String(format: "%.1fM", Double(n) / 1_000_000) }
    if n >= 1_000 { return String(format: "%.1fK", Double(n) / 1_000) }
    return "\(n)"
}

/// Compact "when it ran" stamp shared across the agent surfaces (FR-101): time for today, else a
/// short date + time, so a long list stays scannable and runs are distinguishable.
func agentRowStamp(_ date: Date) -> String {
    Calendar.current.isDateInToday(date)
        ? agentStampTimeOnly.string(from: date)
        : agentStampDateTime.string(from: date)
}
private let agentStampTimeOnly: DateFormatter = {
    let f = DateFormatter(); f.dateFormat = "h:mm a"; return f
}()
private let agentStampDateTime: DateFormatter = {
    let f = DateFormatter(); f.dateFormat = "MMM d, h:mm a"; return f
}()

/// Compact elapsed string (FR-101). A provider-reported durationMs wins when > 0; otherwise measure
/// the client-observed start→(end ?? now) window. "done" for a finished zero-length run reads better
/// than "0s".
func agentElapsed(durationMs: Int, startedAt: Date, endedAt: Date?, now: Date) -> String {
    if durationMs > 0 {
        let s = durationMs / 1000
        return s < 60 ? "\(s)s" : String(format: "%d:%02d", s / 60, s % 60)
    }
    let end = endedAt ?? now
    let s = max(0, Int(end.timeIntervalSince(startedAt)))
    if endedAt != nil, s == 0 { return "done" }
    return s < 60 ? "\(s)s" : String(format: "%d:%02d", s / 60, s % 60)
}
