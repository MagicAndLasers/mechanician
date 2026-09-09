import SwiftUI
import Combine
import AppKit

/// One clock source shared by every live agent visualization.
///
/// Views still redraw only where elapsed time is visible, but they no longer create one run-loop
/// timer per row. `AgentCardClockReader` is placed around the active-list subtree; terminal rows do
/// not observe the clock at all.
private final class AgentCardClock: ObservableObject {
    static let shared = AgentCardClock()

    @Published private(set) var now = Date()
    private var ticker: AnyCancellable?
    private var readerCount = 0

    private init() {}

    /// Connect lazily while at least one elapsed-time surface is mounted. This retains the benefit
    /// of one shared timer without leaving an idle one running after the Agents UI disappears.
    func addReader() {
        readerCount += 1
        guard readerCount == 1 else { return }
        now = Date()
        ticker = Timer.publish(every: 1, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] in self?.now = $0 }
    }

    func removeReader() {
        readerCount = max(0, readerCount - 1)
        guard readerCount == 0 else { return }
        ticker?.cancel()
        ticker = nil
    }
}

private struct AgentCardClockReader<Content: View>: View {
    @ObservedObject private var clock = AgentCardClock.shared
    @State private var isConnected = false
    private let content: (Date) -> Content

    init(@ViewBuilder content: @escaping (Date) -> Content) {
        self.content = content
    }

    var body: some View {
        content(clock.now)
            .onAppear {
                guard !isConnected else { return }
                isConnected = true
                clock.addReader()
            }
            .onDisappear {
                guard isConnected else { return }
                isConnected = false
                clock.removeReader()
            }
    }
}

/// Small colored status pill shared by the inline card and the panel.
struct WorkflowStatusBadge: View {
    let status: WorkflowStatus
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Text(status.label)
            .scaledFont(10, weight: .semibold)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(Capsule().fill(
                status.badgeFillColor.opacity(colorScheme == .dark ? 0.07 : 0.14)))
            .foregroundStyle(status.badgeTextColor)
    }
}

/// The phase→agent tree: each phase heading with its agents' live state.
struct WorkflowAgentTree: View {
    let run: WorkflowRun
    /// When set (the Agents panel), tapping an agent opens its detail pane (FR-101). Nil inline in the
    /// transcript card, where a row just expands in place.
    var onOpenAgent: ((WorkflowRun, WorkflowAgent) -> Void)? = nil

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 8) {
            ForEach(runPhaseTree(run), id: \.phase.index) { entry in
                let failed = entry.agents.contains { $0.state == .failed }
                let done = entry.agents.filter { $0.state == .done }.count
                LazyVStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(entry.phase.title.isEmpty ? "Phase \(entry.phase.index + 1)" : entry.phase.title)
                            .scaledFont(11, weight: .semibold)
                        Spacer()
                        Text("\(done)/\(entry.agents.count)")
                            .scaledFont(10)
                            .foregroundStyle(failed ? Color.nErrorText : Color.secondary)
                    }
                    ForEach(entry.agents) { agent in
                        WorkflowAgentRow(agent: agent,
                                         onOpen: onOpenAgent.map { cb in { cb(run, agent) } })
                    }
                }
            }
        }
    }
}

/// Unambiguous agent status — an animated spinner while WORKING, a green check when DONE, a red
/// mark on failure, a dim dotted ring while queued. The motion (spinner) vs. stillness (check) is
/// what makes "still working" vs "finished" read instantly, which a same-size colored dot didn't.
struct WorkflowAgentStatusIcon: View {
    let state: WorkflowAgentState
    var body: some View {
        switch state {
        case .queued:
            Image(systemName: "circle.dotted").font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary).help("Queued")
        case .start, .progress:
            OrbitingDots(diameter: 13).help("Working…")
        case .done:
            Image(systemName: "checkmark.circle.fill").font(.system(size: 12))
                .foregroundStyle(Color.nSuccessText).help("Done")
        case .failed:
            Image(systemName: "xmark.octagon.fill").font(.system(size: 12))
                .foregroundStyle(Color.nErrorText).help("Failed")
        case .stopped:
            Image(systemName: "stop.circle.fill").font(.system(size: 12))
                .foregroundStyle(Color.nWarningText).help("Stopped")
        }
    }
}

/// Same idea for a run/subagent's WorkflowStatus — spinner while running, check when completed.
struct WorkflowStatusIcon: View {
    let status: WorkflowStatus
    var body: some View {
        switch status {
        case .running:
            OrbitingDots(diameter: 13).help("Working…")
        case .completed:
            Image(systemName: "checkmark.circle.fill").font(.system(size: 12))
                .foregroundStyle(Color.nSuccessText).help("Completed")
        case .failed, .killed:
            Image(systemName: "xmark.octagon.fill").font(.system(size: 12))
                .foregroundStyle(Color.nErrorText).help(status.label)
        case .paused, .stopped:
            Image(systemName: "pause.circle.fill").font(.system(size: 12))
                .foregroundStyle(Color.nWarningText).help(status.label)
        case .pending:
            Image(systemName: "circle.dotted").font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary).help("Pending")
        }
    }
}

/// One agent row: status icon, label, live tool activity, click to drill in.
struct WorkflowAgentRow: View {
    @Environment(\.invalidateTranscriptRowHeight)
    private var invalidateTranscriptRowHeight
    let agent: WorkflowAgent
    /// Set in the Agents panel: the whole row opens the full detail pane (FR-101). Nil inline in the
    /// transcript, where the row expands its details in place instead.
    var onOpen: (() -> Void)? = nil
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                WorkflowAgentStatusIcon(state: agent.state).frame(width: 16, height: 16)
                Text(agent.label.isEmpty ? "agent \(agent.index)" : agent.label)
                    .scaledFont(11, weight: agent.state.isRunning ? .medium : .regular)
                    .foregroundStyle(agent.state == .queued ? .secondary : .primary)
                    .lineLimit(1)
                if let attempt = agent.attempt, attempt > 1 {
                    Text("↻\(attempt)").scaledFont(10).foregroundStyle(Color.nWarningText)
                }
                Spacer()
                if let started = agent.startedAt {
                    Text(agentRowStamp(started)).scaledFont(9).foregroundStyle(.tertiary)
                        .help("Started \(agentRowStamp(started))")
                }
                if agent.state == .done {
                    Text("done").scaledFont(9).foregroundStyle(Color.nSuccessText)
                }
                if let t = agent.tokens, t > 0 {
                    Text(formatTokens(t)).scaledFont(10).foregroundStyle(.secondary)
                }
                if onOpen != nil {
                    Image(systemName: "chevron.right").scaledFont(9).foregroundStyle(.tertiary)
                }
            }
            if agent.state.isRunning, let tool = agent.lastToolName {
                Text("· \(tool)\(agent.lastToolSummary.map { ": \($0)" } ?? "")")
                    .scaledFont(10).foregroundStyle(.secondary).lineLimit(1)
                    .padding(.leading, 13)
            }
            if onOpen == nil, expanded {
                VStack(alignment: .leading, spacing: 2) {
                    if let m = agent.model { detail("model", m) }
                    if let c = agent.toolCalls { detail("tool calls", "\(c)") }
                    if let p = agent.promptPreview, !p.isEmpty { detail("prompt", p) }
                    if let r = agent.resultPreview, !r.isEmpty { detail("result", r) }
                    if let e = agent.error, !e.isEmpty {
                        Text(e).scaledFont(10).foregroundStyle(Color.nErrorText)
                    }
                }
                .padding(.leading, 13).padding(.top, 1)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            if let onOpen { onOpen() }
            else {
                withAnimation(.easeOut(duration: 0.12)) { expanded.toggle() }
                DispatchQueue.main.async { invalidateTranscriptRowHeight() }
            }
        }
        .accessibilityAddTraits(onOpen != nil ? .isButton : [])
        .accessibilityHint(onOpen != nil ? "Opens agent details" : "")
    }

    private func detail(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top, spacing: 4) {
            Text("\(label):").foregroundStyle(.tertiary)
            Text(value).foregroundStyle(.secondary).lineLimit(3)
        }
        .scaledFont(10)
    }
}

/// The inline workflow card keeps its text label and action while sharing the composer's road-sign
/// artwork. Keeping this as a real Button preserves the existing hit target and keyboard behavior.
struct WorkflowStopControl: View {
    let taskID: String
    let onStop: (String) -> Void

    var body: some View {
        Button { onStop(taskID) } label: {
            HStack(spacing: 4) {
                ComposerRoadSign(kind: .stop, size: 14, highlighted: false, raised: false)
                Text("Stop")
            }
            .scaledFont(10)
        }
        .buttonStyle(.borderless)
        .foregroundStyle(Color.nErrorText)
        .accessibilityLabel("Stop")
    }
}

/// Header + progress + tree for a single run — shared by the inline card and panel.
struct WorkflowRunView: View {
    @Environment(\.invalidateTranscriptRowHeight)
    private var invalidateTranscriptRowHeight
    let run: WorkflowRun
    /// When set (the Agents panel), tapping an agent in the tree opens its detail pane (FR-101).
    var onOpenAgent: ((WorkflowRun, WorkflowAgent) -> Void)? = nil
    /// Supplied by the Agents panel's shared active-list clock. Nil for a standalone transcript card,
    /// which installs its own reader of the same shared clock source only while running.
    var now: Date? = nil
    var onStopTask: ((String) -> Void)? = nil
    @State private var expanded: Bool
    @State private var initialNow = Date()

    init(run: WorkflowRun, startExpanded: Bool = false,
         onOpenAgent: ((WorkflowRun, WorkflowAgent) -> Void)? = nil,
         now: Date? = nil,
         onStopTask: ((String) -> Void)? = nil) {
        self.run = run
        self.onOpenAgent = onOpenAgent
        self.now = now
        self.onStopTask = onStopTask
        _expanded = State(initialValue: startExpanded)
    }

    @ViewBuilder
    var body: some View {
        let stats = runStats(run)
        let status = effectiveRunStatus(run)
        if status == .running, now == nil {
            AgentCardClockReader { clockNow in
                runBody(stats: stats, status: status, now: clockNow)
            }
        } else {
            runBody(
                stats: stats,
                status: status,
                now: status == .running ? (now ?? initialNow) : initialNow)
        }
    }

    private func runBody(stats: RunStats, status: WorkflowStatus, now: Date) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "flowchart.fill").foregroundStyle(Color.nInfoText)
                Text(run.workflowName ?? "Workflow").scaledFont(12, weight: .semibold).lineLimit(1)
                WorkflowStatusBadge(status: status)
                if status == .running {
                    // The Mechanician spinner carries "live" while a run has no progress bar yet
                    // (before its first agents report) and alongside it after.
                    OrbitingDots(diameter: 13)
                }
                Spacer()
                // FR-101: when the run started + how long it's run, so workflows carry the same time
                // metadata standalone agents do.
                Text(agentRowStamp(run.startedAt)).scaledFont(9).foregroundStyle(.tertiary)
                    .help("Started \(agentRowStamp(run.startedAt))")
                Text(agentElapsed(durationMs: run.usage?.durationMs ?? 0,
                                  startedAt: run.startedAt, endedAt: run.endedAt, now: now))
                    .scaledFont(10).foregroundStyle(.secondary).monospacedDigit()
                if (status == .running || status == .paused),
                   let tid = run.runTaskId,
                   let onStopTask {
                    WorkflowStopControl(taskID: tid, onStop: onStopTask)
                }
                Image(systemName: expanded ? "chevron.down" : "chevron.right")
                    .scaledFont(10).foregroundStyle(.secondary)
            }
            .contentShape(Rectangle()) // whole header row is the expand target
            .onTapGesture {
                withAnimation(.easeOut(duration: 0.12)) { expanded.toggle() }
                DispatchQueue.main.async { invalidateTranscriptRowHeight() }
            }

            Text(workflowStatsSummary(stats))
                .scaledFont(10).foregroundStyle(.secondary)

            if stats.agents > 0 {
                // A filling progress bar reads as forward progress — green as it advances, red only
                // when the run actually failed. (The status badge/dots still carry running=accent.)
                ProgressView(value: Double(stats.done), total: Double(max(stats.agents, 1)))
                    .tint(status.progressColor)
            }

            if !run.description.isEmpty {
                Text(run.description).scaledFont(11).foregroundStyle(.secondary)
                    .lineLimit(expanded ? nil : 2)
            }

            if expanded {
                if !run.agents.isEmpty { WorkflowAgentTree(run: run, onOpenAgent: onOpenAgent) }
                if let summary = run.summary, !summary.isEmpty {
                    Text(summary).scaledFont(11).padding(.top, 2)
                }
                if let out = run.outputFile, !out.isEmpty {
                    HStack(spacing: 6) {
                        Image(systemName: "doc.text")
                        Text((out as NSString).lastPathComponent).scaledFont(10, design: .monospaced).lineLimit(1)
                        Button("Open") { NSWorkspace.shared.open(URL(fileURLWithPath: out)) }
                            .scaledFont(10).buttonStyle(.link)
                    }
                    .foregroundStyle(.secondary)
                }
                if let err = run.error, !err.isEmpty {
                    Text(err).scaledFont(11).foregroundStyle(Color.nErrorText)
                }
            }
        }
        .padding(12)
        .cardSurface(cornerRadius: 10)
    }
}

private func workflowStatsSummary(_ stats: RunStats) -> String {
    var parts = ["\(stats.done)/\(stats.agents) agents"]
    if stats.tokens > 0 { parts.append("\(formatTokens(stats.tokens)) tok") }
    if stats.toolUses > 0 { parts.append("\(stats.toolUses) tools") }
    return parts.joined(separator: " · ")
}

/// Rendered inline in the transcript for a `Workflow` tool call, keyed by its
/// tool_use id so it live-updates as the run streams.
struct WorkflowCard: View {
    @EnvironmentObject private var bridge: AgentBridge
    let toolUseId: String?

    private var run: WorkflowRun? {
        guard let id = toolUseId else { return nil }
        return bridge.workflowRuns[id] ?? bridge.workflowRuns.values.first { $0.toolUseId == id }
    }

    var body: some View {
        if let run = run {
            WorkflowRunView(
                run: run,
                startExpanded: true,
                onStopTask: { bridge.stopTask($0) })
        } else {
            HStack(spacing: 6) {
                Image(systemName: "flowchart.fill").foregroundStyle(Color.nInfoText)
                Text("Workflow").scaledFont(12, weight: .medium)
                Spacer()
                OrbitingDots(diameter: 15)   // the Mechanician spinner, not the system ProgressView
            }
            .padding(12)
            .cardSurface(cornerRadius: 10)
        }
    }
}

/// The Agents inspector tab: live subagents (the Task tool) and workflow orchestration runs.
/// Provider-truthful activity appears once in one surface: standalone children as agent rows and
/// genuine provider workflow objects as workflow cards. Grouped by status with optional search.
struct AgentsEmptyStateCopy: Equatable {
    var title: String
    var detail: String
    var systemImage: String
}

func agentsEmptyStateCopy(for access: ModelAccess, ultraEnabled: Bool) -> AgentsEmptyStateCopy {
    switch access {
    case .codexSubscription:
        return AgentsEmptyStateCopy(
            title: "No delegated agents yet",
            detail: ultraEnabled
                ? "Ultra may delegate suitable independent work automatically. You can also ask Codex to delegate a bounded task explicitly."
                : "Ask Codex to delegate a bounded task explicitly. Eligible models in Ultra may also delegate suitable independent work proactively.",
            systemImage: "person.2")
    case .claudeSubscription, .anthropicAPI, .claudeVertex, .claudeBedrock:
        return AgentsEmptyStateCopy(
            title: "No delegated agents yet",
            detail: "Ask Claude to delegate a bounded task. Native Claude workflows also appear here when the provider reports them.",
            systemImage: "person.2")
    case .openAIAPI:
        return AgentsEmptyStateCopy(
            title: "Delegated agents aren’t available on this route",
            detail: "Mechanician’s direct OpenAI API lane does not currently receive provider-managed child agents. Choose a Codex or Claude model to use the Agents panel.",
            systemImage: "person.2.slash")
    }
}
