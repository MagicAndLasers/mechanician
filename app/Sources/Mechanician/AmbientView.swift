import SwiftUI
import AppKit

/// The Schedule window: Mechanician's standing instructions. Left, the tasks grouped by what
/// fires them (watches / recurring / one-time / mail); right, a real calendar page — a month
/// grid with run markers and a per-day agenda of what ran and what will run. Tasks execute
/// unattended in the ambient daemon; results land as conversations + notifications.
struct AmbientView: View {
    @Environment(\.openWindow) private var openWindow
    @ObservedObject private var store = AmbientStore.shared
    @ObservedObject private var active = ActiveWorkspace.shared
    @ObservedObject private var projects = ProjectStore.shared
    @ObservedObject private var accounts = ProviderAccountStore.shared
    @ObservedObject private var conversations = ConversationStore.shared
    @ObservedObject private var background = BackgroundProcessStore.shared
    @AppStorage("ambientDaemonEnabled") private var daemonEnabled = false
    @State private var editing: ScheduledTask?
    /// A scheduled task is a configured automation, so deleting one asks first and is undoable —
    /// the same footing conversations, artifacts and workspace moves already have.
    @State private var confirmingDelete: ScheduledTask?
    @State private var installNote: String?
    @State private var daemonChangeInFlight = false
    @State private var allWorkspaces = false
    @State private var displayedMonth = Calendar.current.dateInterval(of: .month, for: Date())?.start ?? Date()
    @State private var selectedDay = Calendar.current.startOfDay(for: Date())

    private var cal: Calendar { Calendar.current }

    /// A toolbar invocation inherits the frontmost workspace. Menu-bar and Shortcuts-created
    /// tasks may be unassigned until the user chooses one in the editor.
    private var workspaceScope: WorkspaceUtilityScope {
        guard let bridge = active.bridge else { return .unavailable }
        return .current(
            projectID: bridge.projectID,
            cwd: bridge.cwd,
            resolvedFolderProjectID: projects.projectID(forCwd: bridge.cwd, createIfMissing: false))
    }

    private var activeWorkspaceID: UUID? { workspaceScope.workspaceID }
    private var inheritedTaskWorkspaceID: UUID? {
        AmbientTaskWorkspacePolicy.inheritedWorkspaceID(activeWorkspaceID)
    }

    private var ambientAccess: ModelAccess { AmbientDaemon.accountAccess }
    private var ambientUsesVertex: Bool { ambientAccess == .claudeVertex }
    private var ambientCredentialAvailable: Bool {
        accounts.operation(for: ambientAccess) == nil
            && accounts.state(for: ambientAccess).isAvailable
    }
    private var missingAmbientCredentialMessage: String {
        ambientUsesVertex
            ? "Connect Google Vertex in Accounts"
            : "Add an Anthropic API key in Accounts"
    }
    private var ambientLogHint: String { "~/Library/Logs/\(AmbientDaemon.label).log" }

    private var scopedTasks: [ScheduledTask] {
        guard !allWorkspaces else { return store.tasks }
        return store.tasks.filter { workspaceScope.contains(task: $0) }
    }

    private var scopedRuns: [AmbientRun] {
        guard !allWorkspaces else { return store.runs }
        let taskIDs = Set(scopedTasks.map(\.id))
        return store.runs.filter { taskIDs.contains($0.taskId) }
    }

    private var scopeLabel: String {
        allWorkspaces ? "All Workspaces" : workspaceScope.displayName(projects: projects.projects)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            credentialDisclosure
            Divider()
            // The calendar shows ALWAYS — an empty month still sells the feature; the left
            // column onboards when there are no tasks yet.
            HStack(spacing: 0) {
                taskColumn.frame(width: 340)
                Divider()
                calendarColumn
            }
        }
        .frame(minWidth: 860, minHeight: 560)
        .background(Color.nBg)
        .sheet(item: $editing) { task in
            TaskEditor(task: task,
                       onSave: { store.upsert($0); editing = nil },
                       onCancel: { editing = nil })
        }
        .confirmationDialog(
            "Delete \(confirmingDelete?.name ?? "this task")?",
            isPresented: Binding(get: { confirmingDelete != nil },
                                 set: { if !$0 { confirmingDelete = nil } }),
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                if let task = confirmingDelete,
                   let index = store.tasks.firstIndex(where: { $0.id == task.id }) {
                    store.delete(task.id)
                    AmbientTaskDeleteUndo.register(
                        task,
                        at: index,
                        store: store,
                        undoManager: workspaceUndoManager(for: active.bridge))
                }
                confirmingDelete = nil
            }
            Button("Cancel", role: .cancel) { confirmingDelete = nil }
        } message: {
            Text("Its schedule, prompt and run history go with it. "
               + "You can undo it with Undo in the Edit menu.")
        }
        .onAppear { consumePendingWatch(); consumePendingNewTask() }
        .onChange(of: store.pendingWatchPath) { _, _ in consumePendingWatch() }
        .onChange(of: store.pendingNewTaskRequest) { _, _ in consumePendingNewTask() }
        .onChange(of: accounts.states) { _, _ in store.syncInProcessRunner() }
    }

    /// "Watch This File/Folder…" from the file browser (or an intent) opens this window with a
    /// pre-filled watch draft — same handoff pattern as the Projects launcher's pending request.
    private func consumePendingWatch() {
        guard let path = store.pendingWatchPath else { return }
        store.pendingWatchPath = nil
        editing = AmbientStore.watchTask(path: path)
    }

    /// "New Task…" from the toolbar's Tasks menu — the window may still be opening when the
    /// request lands, so it arrives as published state rather than a call into this view.
    private func consumePendingNewTask() {
        guard store.pendingNewTaskRequest else { return }
        store.pendingNewTaskRequest = false
        editing = newDraft()
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 1) {
                Text("Schedule").font(.headline)
                Text("\(scopeLabel) · \(scopedTasks.count) task\(scopedTasks.count == 1 ? "" : "s")")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if let note = installNote {
                Text(note).font(.caption).foregroundStyle(Color.nWarningText)
            }
            healthPill
            Button { allWorkspaces.toggle() } label: {
                Image(systemName: allWorkspaces ? "square.stack.3d.up.fill" : "square.stack.3d.up")
            }
            .buttonStyle(.borderless)
            .help(allWorkspaces ? "Show current workspace" : "Show all workspaces")
            Toggle(isOn: Binding(get: { daemonEnabled }, set: { setDaemon($0) })) {
                Text("Run when closed").font(.system(size: 12))
            }
            .toggleStyle(.switch)
            .disabled(daemonChangeInFlight)
            .disabled(!ambientCredentialAvailable && !daemonEnabled)
            .help("Tasks already run while Mechanician is open. Turn this on to keep running them even after you quit (installs a background launch agent).")
            Button { editing = newDraft() } label: { Label("New Task", systemImage: "plus") }
                .buttonStyle(PillButtonStyle(kind: .accent))
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
    }

    private var credentialDisclosure: some View {
        HStack(spacing: 8) {
            Image(systemName: ambientCredentialAvailable
                  ? (ambientUsesVertex ? "building.2" : "dollarsign.circle")
                  : "exclamationmark.triangle")
                .foregroundStyle(
                    ambientCredentialAvailable ? Color.secondary : Color.nWarningText)
            Text(ambientUsesVertex
                 ? (ambientCredentialAvailable
                    // The organization names itself in its signed profile; the app must not.
                    ? "Scheduled runs use your managed Google Vertex connection and the \(TenantProfile.current.displayName) Vertex project."
                    : "Scheduled runs require the managed Google Vertex connection. Connect Google in Providers first.")
                 : (ambientCredentialAvailable
                    ? "Scheduled runs use a metered API connection and may incur usage charges. Each task picks its provider."
                    // Honest about WHY: this is a terms boundary, not a missing capability. Subscription
                    // access may not run unattended, so scheduling needs a metered credential.
                    : "Scheduled runs need a metered API key. Subscription access can't run unattended. Add one in Providers."))
                .font(.caption)
                .foregroundStyle(
                    ambientCredentialAvailable ? Color.secondary : Color.nWarningText)
            Spacer(minLength: 8)
            if !ambientCredentialAvailable {
                Button("Open Providers") { showProviders(using: openWindow) }
                    .buttonStyle(.link)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .background(Color.nElevated.opacity(0.65))
    }

    /// Live scheduler-liveness indicator, re-evaluated on a slow timeline so it decays to
    /// "off" when the daemon's heartbeat goes stale (no file event fires for silence).
    private var healthPill: some View {
        TimelineView(.periodic(from: .now, by: 15)) { ctx in
            let health = store.schedulerHealth(asOf: ctx.date)
            let hasEnabled = store.tasks.contains {
                $0.isEffectivelyEnabled && $0.hasSchedulableWorkspace
            }
            let (label, color): (String, Color) = {
                switch health {
                case .running: return ("Scheduler running", .green)
                case .stale:   return ("Scheduler stale", .orange)
                case .off:     return (hasEnabled ? "Starting scheduler…" : "Scheduler idle", .secondary)
                }
            }()
            HStack(spacing: 5) {
                Circle().fill(color).frame(width: 7, height: 7)
                Text(label).font(.caption).foregroundStyle(color == .secondary ? .secondary : .primary)
            }
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(Capsule().fill(Color.nElevated))
            .help(health == .running || health == .stale
                  ? "The scheduler is running and checking your tasks. Turn on \"Run when closed\" to keep it going after you quit."
                  : "Tasks run while Mechanician is open. If this stays idle with enabled tasks, check \(ambientLogHint).")
        }
    }

    private func newDraft() -> ScheduledTask {
        ScheduledTask(name: "", prompt: "", workspaceID: inheritedTaskWorkspaceID,
                      trigger: AmbientTrigger(type: "time",
                                              schedule: AmbientSchedule(kind: "daily", hour: 9, minute: 0)))
    }

    /// Shown in the task column when there are no tasks yet — an invitation with one-click
    /// starters, instead of a dead placeholder (the calendar still renders alongside).
    private var onboarding: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 5) {
                Image(systemName: "calendar.badge.clock").font(.system(size: 24)).foregroundStyle(Color.nAccent)
                Text("Standing instructions").font(.system(size: 15, weight: .semibold))
                Text("Give Mechanician work to do on its own: on a schedule, when a file changes, or when mail arrives. Results arrive as conversations, notifications, and auto-updating artifacts.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            .padding(.bottom, 2)
            Text("START WITH…").font(.system(size: 10, weight: .semibold)).kerning(0.6).foregroundStyle(.tertiary)
            starter("Morning briefing", "sun.max", "Daily at 8:00 — summarize my day",
                    ScheduledTask(name: "Morning briefing",
                                  prompt: "Give me a concise briefing for the day ahead: my calendar, any urgent mail, and 3 priorities.",
                                  workspaceID: inheritedTaskWorkspaceID,
                                  trigger: AmbientTrigger(type: "time", schedule: AmbientSchedule(kind: "daily", hour: 8, minute: 0))))
            starter("Watch a folder", "eye", "Act when files change",
                    ScheduledTask(name: "Watch Downloads",
                                  prompt: "Something changed in this folder. Summarize what's new and flag anything that needs my attention.",
                                  workspaceID: inheritedTaskWorkspaceID,
                                  trigger: AmbientTrigger(type: "file", path: NSHomeDirectory() + "/Downloads")))
            starter("Hourly check-in", "arrow.trianglehead.2.clockwise", "Every 60 min",
                    ScheduledTask(name: "Hourly check-in",
                                  prompt: "Check on anything I'm tracking and let me know if something needs action.",
                                  workspaceID: inheritedTaskWorkspaceID,
                                  trigger: AmbientTrigger(type: "time", schedule: AmbientSchedule(kind: "interval", minutes: 60))))
            Button { editing = newDraft() } label: { Label("New Task…", systemImage: "plus") }
                .buttonStyle(PillButtonStyle(kind: .accent))
                .padding(.top, 4)
            Spacer()
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func starter(_ title: String, _ icon: String, _ subtitle: String, _ draft: ScheduledTask) -> some View {
        Button { editing = draft } label: {
            HStack(spacing: 10) {
                Image(systemName: icon).font(.system(size: 14))
                    .foregroundStyle(Color.nInfoText).frame(width: 22)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.callout.weight(.medium)).foregroundStyle(Color.nText)
                    Text(subtitle).font(.caption2).foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "plus.circle").foregroundStyle(.tertiary)
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.nSurface))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.nMuted.opacity(0.35)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Task column (left)

    private struct TaskGroup: Identifiable {
        let id: String
        let title: String
        let tasks: [ScheduledTask]
    }

    private var groups: [TaskGroup] {
        func kind(_ t: ScheduledTask) -> String {
            if t.trigger.type == "file" { return "watch" }
            if t.trigger.type == "inbox" { return "mail" }
            return t.trigger.schedule?.kind == "once" ? "once" : "recurring"
        }
        let all = scopedTasks
        return [
            TaskGroup(id: "watch", title: "Watches", tasks: all.filter { kind($0) == "watch" }),
            TaskGroup(id: "recurring", title: "Recurring", tasks: all.filter { kind($0) == "recurring" }),
            TaskGroup(id: "once", title: "One-time", tasks: all.filter { kind($0) == "once" }),
            TaskGroup(id: "mail", title: "Mail", tasks: all.filter { kind($0) == "mail" }),
        ].filter { !$0.tasks.isEmpty }
    }

    @ViewBuilder private var taskColumn: some View {
        // Onboarding only when there is genuinely nothing here. An armed wait is real scheduled work
        // even with no saved tasks, and showing the empty state over it would hide live activity.
        if scopedTasks.isEmpty && armedWaits.isEmpty && background.processes.isEmpty {
            ScrollView { onboarding }
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    if !armedWaits.isEmpty {
                        Text("WAITING FOR A TRIGGER")
                            .font(.system(size: 10, weight: .semibold)).kerning(0.6)
                            .foregroundStyle(.tertiary)
                            .padding(.top, 6)
                        ForEach(armedWaits, id: \.id) { waitRow($0) }
                    }
                    if !background.processes.isEmpty {
                        Text("AGENT-STARTED PROCESSES")
                            .font(.system(size: 10, weight: .semibold)).kerning(0.6)
                            .foregroundStyle(.tertiary)
                            .padding(.top, 6)
                            .help("One background service can use more than one OS process.")
                        ForEach(background.processes) { processRow($0) }
                    }
                    ForEach(groups) { group in
                        Text(group.title.uppercased())
                            .font(.system(size: 10, weight: .semibold)).kerning(0.6)
                            .foregroundStyle(.tertiary)
                            .padding(.top, 6)
                        ForEach(group.tasks) { row($0) }
                    }
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    /// Conversations parked in wait-mode, scoped like the task list. These are armed by the agent
    /// mid-turn (WaitFor) and previously had no surface beyond the ⏳ chip on their own conversation
    /// — so several could be running and the only way to find them was to open each conversation.
    private var armedWaits: [Conversation] {
        conversations.summaries
            .filter { $0.armedWaitSummary != nil }
            .compactMap { conversations.residentConversation($0.id) }
            .filter { allWorkspaces || activeWorkspaceID == nil || $0.projectID == activeWorkspaceID }
            .sorted { ($0.armedTrigger?.armedAt ?? .distantPast) > ($1.armedTrigger?.armedAt ?? .distantPast) }
    }

    /// Work an agent left running outside a turn — a poll loop, a watcher, a detached chain. Until
    /// this existed the only way to find it was `ps`, and the only way to stop it was `kill`.
    private func processRow(_ process: BackgroundProcess) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.nElevated)
                    .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(Color.nMuted.opacity(0.5)))
                    .frame(width: 24, height: 24)
                    .overlay(Image(systemName: "gearshape.2")
                        .font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary))
                Text(process.label).font(.callout.weight(.semibold)).lineLimit(1)
                Spacer()
                // Explicit description: interpolating an Int applies locale grouping, which
                // rendered "pid 75,334" — not a number you can paste into `kill`.
                Text(verbatim: "pid \(String(process.pid))")
                    .font(.system(size: 10, design: .monospaced)).foregroundStyle(.tertiary)
            }
            // The full command, because a short label cannot distinguish two `bash -c` loops and the
            // user needs to know which one they are about to stop.
            if !process.command.isEmpty {
                Text(process.command)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.tertiary).lineLimit(2).truncationMode(.middle)
            }
            HStack(spacing: 8) {
                Label(durationLabel(process.ageSeconds), systemImage: "clock")
                if process.detached {
                    // Worth surfacing: a detached process survives the app, so quitting will not
                    // clean it up — stopping it here is the only tidy way out.
                    Label("detached", systemImage: "bolt.horizontal")
                }
                if process.adopted {
                    Label("matched", systemImage: "questionmark.circle")
                        .help("Identified by workspace and start time rather than observed directly.")
                }
                Spacer()
                Button("Stop") { AgentBridge.killBackgroundProcess(process) }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
                    .accessibilityLabel("Stop background process \(process.label), pid \(process.pid)")
            }
            .font(.system(size: 11))
            .foregroundStyle(.tertiary)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.nSurface))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.nMuted.opacity(0.4)))
        .accessibilityElement(children: .contain)
    }

    private func durationLabel(_ seconds: Double) -> String {
        if seconds < 90 { return "\(Int(seconds))s" }
        if seconds < 5400 { return "\(Int(seconds / 60))m" }
        return String(format: "%.1fh", seconds / 3600)
    }

    private func waitRow(_ conversation: Conversation) -> some View {
        let trigger = conversation.armedTrigger
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.nElevated)
                    .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(Color.nMuted.opacity(0.5)))
                    .frame(width: 24, height: 24)
                    .overlay(Image(systemName: "hourglass")
                        .font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary))
                Text(conversation.displayTitle).font(.callout.weight(.semibold)).lineLimit(1)
                Spacer()
            }
            if let summary = trigger?.summary, !summary.isEmpty {
                Text(summary).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            // The literal trigger, so a wait that will never fire is diagnosable from here rather
            // than by reading the conversation back.
            if let check = trigger?.check, !check.isEmpty {
                Text(check)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.tertiary).lineLimit(1).truncationMode(.middle)
            }
            HStack(spacing: 8) {
                if let armedAt = trigger?.armedAt {
                    Label("Waiting \(durationLabel(max(0, Date().timeIntervalSince(armedAt))))",
                          systemImage: "clock.arrow.circlepath")
                }
                if let deadline = trigger?.deadline {
                    Label(deadline.formatted(date: .omitted, time: .shortened), systemImage: "alarm")
                }
                if trigger?.check != nil {
                    if let checkedAt = trigger?.lastCheckedAt {
                        Label("Checked \(checkedAt.formatted(.relative(presentation: .numeric)))",
                              systemImage: "checkmark.circle")
                    } else if let every = trigger?.everySeconds {
                        Label("Checks every \(durationLabel(every))",
                              systemImage: "arrow.clockwise")
                    }
                }
                Spacer()
            }
            .font(.system(size: 11))
            .foregroundStyle(.tertiary)
            HStack(spacing: 8) {
                if let expiresAt = trigger?.expiresAt {
                    Label("expires \(expiresAt.formatted(.relative(presentation: .numeric)))",
                          systemImage: "hourglass.bottomhalf.filled")
                }
                Spacer()
                Button("Resume now") { AgentBridge.resumeWaitEverywhere(conversation.id) }
                    .buttonStyle(.plain).foregroundStyle(Color.nInfoText)
                    .accessibilityLabel("Resume \(conversation.displayTitle) now")
                Button("Cancel") { AgentBridge.cancelWaitEverywhere(conversation.id) }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
                    .accessibilityLabel("Cancel the wait on \(conversation.displayTitle)")
            }
            .font(.system(size: 11))
            .foregroundStyle(.tertiary)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.nSurface))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.nMuted.opacity(0.4)))
        .accessibilityElement(children: .contain)
    }

    private func row(_ task: ScheduledTask) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.nElevated)
                    .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(Color.nMuted.opacity(0.5)))
                    .frame(width: 24, height: 24)
                    .overlay(Image(systemName: icon(task.trigger))
                        .font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary))
                Text(task.name).font(.callout.weight(.semibold)).lineLimit(1)
                Spacer()
                Toggle("", isOn: Binding(get: { task.isEffectivelyEnabled }, set: { store.setEnabled(task.id, $0) }))
                    .toggleStyle(.switch).controlSize(.mini).labelsHidden()
                    .accessibilityLabel("Enable task")
                    .disabled(!task.hasSchedulableWorkspace)
            }
            if !task.prompt.isEmpty {
                Text(task.prompt).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            readiness(for: task)
            HStack(spacing: 8) {
                if task.hasSchedulableWorkspace,
                   let workspaceID = task.workspaceID,
                   let workspace = ProjectStore.shared.project(workspaceID) {
                    Text(workspace.displayName).font(.caption2).foregroundStyle(.secondary)
                } else {
                    Text("Choose workspace").font(.caption2)
                        .foregroundStyle(Color.nWarningText)
                }
                Text(task.triggerSummary).font(.caption2)
                    .padding(.horizontal, 6).padding(.vertical, 1)
                    .background(Capsule().fill(Color.nElevated))
                if let last = task.lastRun, let d = parseISO(last) {
                    Text("ran \(shortDate(d))").font(.caption2).foregroundStyle(.tertiary)
                }
                Spacer()
                Button { store.runNow(task.id) } label: { Image(systemName: "play.circle") }
                    .buttonStyle(.borderless)
                    .help(!ambientCredentialAvailable ? missingAmbientCredentialMessage
                          : task.hasSchedulableWorkspace ? "Run now" : "Choose a workspace first")
                    .accessibilityLabel("Run now")
                    .disabled(!task.hasSchedulableWorkspace || !ambientCredentialAvailable)
                Button { editing = task } label: { Image(systemName: "pencil") }
                    .buttonStyle(.borderless).help("Edit")
                    .accessibilityLabel("Edit task")
                Button(role: .destructive) { confirmingDelete = task } label: {
                    Image(systemName: "trash")
                }
                    .buttonStyle(.borderless).help("Delete")
                    .accessibilityLabel("Delete task")
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.nSurface))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .strokeBorder(Color.nMuted.opacity(0.35)))
        .opacity(task.isEffectivelyEnabled && task.hasSchedulableWorkspace ? 1 : 0.55)
    }

    /// What this task will and will not be able to do, BEFORE it ever runs.
    ///
    /// `TaskReadiness` was written for exactly this and never called. Its own note names the failure
    /// it exists to prevent: *"a task that looks correct, runs on schedule, and quietly does nothing
    /// useful — the failure the user has no way to foresee."* An unattended run is judged by rules
    /// the app knows and the person cannot see: some tools are withheld because nothing can answer
    /// them, writes and shell need Trust all, and each lane needs its own credential.
    ///
    /// Only what will actually bite. The `info` tier is deliberately not shown on the row — a card
    /// with three grey notes on it teaches people to stop reading the notes.
    @ViewBuilder
    private func readiness(for task: ScheduledTask) -> some View {
        let findings = TaskReadiness.evaluate(
            task: task,
            credentialReady: ambientCredentialAvailable,
            workspaceResolved: AmbientTaskWorkspacePolicy.resolves(
                task.workspaceID,
                in: ProjectStore.shared.projects))
        let worth = findings.filter { $0.severity > .info }
        if !worth.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(worth) { finding in
                    readinessRow(finding)
                }
            }
            .padding(.top, 1)
        }
    }

    /// Split out because the whole card would not type-check as one expression.
    private func readinessRow(_ finding: TaskReadiness.Finding) -> some View {
        let blocking = finding.severity == .blocking
        let symbol = blocking ? "exclamationmark.octagon.fill" : "exclamationmark.triangle.fill"
        let tint: Color = blocking ? .nErrorText : .nWarningText
        return HStack(alignment: .firstTextBaseline, spacing: 5) {
            Image(systemName: symbol)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(tint)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: finding.title).font(.caption2.weight(.medium))
                Text(verbatim: finding.detail)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func icon(_ trigger: AmbientTrigger) -> String {
        switch trigger.type {
        case "file": return "eye"
        case "inbox": return "envelope"
        default: return trigger.schedule?.kind == "once" ? "calendar.badge.clock" : "clock"
        }
    }

    // MARK: - Calendar column (right)

    private var calendarColumn: some View {
        VStack(spacing: 0) {
            monthHeader
            weekdayHeader
            monthGrid
            Divider().padding(.top, 6)
            agenda
        }
        .padding(.top, 8)
    }

    private var monthHeader: some View {
        HStack(spacing: 8) {
            Text(displayedMonth.formatted(.dateTime.month(.wide).year()))
                .font(.system(size: 15, weight: .semibold))
            Spacer()
            Button("Today") {
                displayedMonth = cal.dateInterval(of: .month, for: Date())?.start ?? Date()
                selectedDay = cal.startOfDay(for: Date())
            }
            .buttonStyle(PillButtonStyle(kind: .neutral))
            Button { shiftMonth(-1) } label: { Image(systemName: "chevron.left") }
                .buttonStyle(.borderless)
                .help("Previous month")
                .accessibilityLabel("Previous month")
            Button { shiftMonth(1) } label: { Image(systemName: "chevron.right") }
                .buttonStyle(.borderless)
                .help("Next month")
                .accessibilityLabel("Next month")
        }
        .padding(.horizontal, 14)
    }

    private func shiftMonth(_ delta: Int) {
        displayedMonth = cal.date(byAdding: .month, value: delta, to: displayedMonth) ?? displayedMonth
    }

    private var weekdaySymbols: [String] {
        let syms = cal.veryShortWeekdaySymbols
        let shift = cal.firstWeekday - 1
        return Array(syms[shift...] + syms[..<shift])
    }

    private var weekdayHeader: some View {
        HStack(spacing: 0) {
            ForEach(Array(weekdaySymbols.enumerated()), id: \.offset) { _, s in
                Text(s).font(.system(size: 10, weight: .medium)).foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 6)
    }

    /// The month laid out as 7-column rows: nil cells pad the first/last week.
    private var monthCells: [Date?] {
        guard let interval = cal.dateInterval(of: .month, for: displayedMonth) else { return [] }
        let first = interval.start
        let leading = (cal.component(.weekday, from: first) - cal.firstWeekday + 7) % 7
        let dayCount = cal.range(of: .day, in: .month, for: first)?.count ?? 30
        var cells: [Date?] = Array(repeating: nil, count: leading)
        for d in 0..<dayCount { cells.append(cal.date(byAdding: .day, value: d, to: first)) }
        while cells.count % 7 != 0 { cells.append(nil) }
        return cells
    }

    private var monthGrid: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 7), spacing: 4) {
            ForEach(Array(monthCells.enumerated()), id: \.offset) { _, day in
                if let day {
                    dayCell(day)
                } else {
                    Color.clear.frame(height: 40)
                }
            }
        }
        .padding(.horizontal, 12)
    }

    private func dayCell(_ day: Date) -> some View {
        let isToday = cal.isDateInToday(day)
        let isSelected = cal.isDate(day, inSameDayAs: selectedDay)
        let scheduled = scheduledCount(on: day)
        let ran = ranCount(on: day)
        return Button {
            selectedDay = cal.startOfDay(for: day)
        } label: {
            VStack(spacing: 3) {
                Text("\(cal.component(.day, from: day))")
                    .font(.system(size: 12, weight: isToday ? .bold : .regular))
                    .foregroundStyle(isToday ? Color.nInfoText : Color.nText)
                HStack(spacing: 3) {
                    ForEach(0..<min(scheduled, 3), id: \.self) { _ in
                        Circle().fill(Color.nAccent).frame(width: 4, height: 4)
                    }
                    if ran > 0 { Circle().fill(Color.nMuted).frame(width: 4, height: 4) }
                }
                .frame(height: 4)
            }
            .frame(maxWidth: .infinity).frame(height: 40)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(isSelected ? Color.nElevated : Color.clear))
            .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous)
                .strokeBorder(isSelected ? Color.nAccent.opacity(0.6) : Color.clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Occurrences

    /// Discrete occurrences (dots): dailies on today/future days, one-shots on their day.
    private func scheduledCount(on day: Date) -> Int {
        let today = cal.startOfDay(for: Date())
        let d = cal.startOfDay(for: day)
        var n = 0
        for t in scopedTasks where t.isEffectivelyEnabled && t.trigger.type == "time" {
            if let once = t.onceDate {
                if cal.isDate(once, inSameDayAs: d) { n += 1 }
            } else if t.trigger.schedule?.kind == "daily", d >= today {
                n += 1
            }
        }
        return n
    }

    private func ranCount(on day: Date) -> Int {
        // Prefer the daemon's real run history; fall back to each task's last-run stamp.
        if !scopedRuns.isEmpty {
            return scopedRuns.filter { $0.date.map { cal.isDate($0, inSameDayAs: day) } ?? false }.count
        }
        return scopedTasks.filter { t in
            guard let iso = t.lastRun, let d = parseISO(iso) else { return false }
            return cal.isDate(d, inSameDayAs: day)
        }.count
    }

    private struct AgendaItem: Identifiable {
        let id = UUID()
        let time: Date?
        let icon: String
        let title: String
        let detail: String
        let isPast: Bool
    }

    private var agendaItems: [AgendaItem] {
        let today = cal.startOfDay(for: Date())
        let day = cal.startOfDay(for: selectedDay)
        var timed: [AgendaItem] = []
        var standing: [AgendaItem] = []

        // What actually ran that day: prefer the real run history (multiple runs per day),
        // falling back to each task's single last-run stamp when history isn't available yet.
        let dayRuns = scopedRuns.filter { $0.date.map { cal.isDate($0, inSameDayAs: day) } ?? false }
        if !dayRuns.isEmpty {
            for run in dayRuns {
                let name = scopedTasks.first(where: { $0.id == run.taskId })?.name ?? "Scheduled task"
                timed.append(AgendaItem(time: run.date, icon: run.ok ? "checkmark.circle" : "xmark.octagon",
                                        title: name,
                                        detail: run.summary.isEmpty ? (run.ok ? "Ran." : "Failed.") : run.summary,
                                        isPast: true))
            }
        }
        for t in scopedTasks {
            if dayRuns.isEmpty, let iso = t.lastRun, let ran = parseISO(iso), cal.isDate(ran, inSameDayAs: day) {
                timed.append(AgendaItem(time: ran, icon: "checkmark.circle",
                                        title: t.name,
                                        detail: (t.lastResult ?? "Ran.").replacingOccurrences(of: "\n", with: " "),
                                        isPast: true))
            }
            guard t.isEffectivelyEnabled else { continue }
            // What's planned: one-shots on their day, dailies on any current/future day.
            if let once = t.onceDate, cal.isDate(once, inSameDayAs: day), once > Date() {
                timed.append(AgendaItem(time: once, icon: "calendar.badge.clock",
                                        title: t.name, detail: t.prompt, isPast: false))
            } else if day >= today, let daily = t.dailyDate(on: day, calendar: cal),
                      t.trigger.schedule?.kind == "daily", daily > Date() || day > today {
                timed.append(AgendaItem(time: daily, icon: "clock",
                                        title: t.name, detail: t.prompt, isPast: false))
            }
            // Standing triggers aren't date-bound — show them with today and the future.
            if day >= today {
                switch t.trigger.type {
                case "file":
                    standing.append(AgendaItem(time: nil, icon: "eye", title: t.name,
                                               detail: t.triggerSummary, isPast: false))
                case "inbox":
                    standing.append(AgendaItem(time: nil, icon: "envelope", title: t.name,
                                               detail: t.triggerSummary, isPast: false))
                default:
                    if t.trigger.schedule?.kind == "interval" {
                        standing.append(AgendaItem(time: nil, icon: "arrow.trianglehead.2.clockwise",
                                                   title: t.name, detail: t.triggerSummary, isPast: false))
                    }
                }
            }
        }
        return timed.sorted { ($0.time ?? .distantPast) < ($1.time ?? .distantPast) } + standing
    }

    private var agenda: some View {
        let items = agendaItems
        return ScrollView {
            VStack(alignment: .leading, spacing: 6) {
                Text(selectedDay.formatted(date: .complete, time: .omitted))
                    .font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
                    .padding(.bottom, 2)
                if items.isEmpty {
                    Text("Nothing scheduled this day.")
                        .font(.system(size: 12)).foregroundStyle(.tertiary)
                        .padding(.vertical, 10)
                } else {
                    ForEach(items) { item in agendaRow(item) }
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func agendaRow(_ item: AgendaItem) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(item.time.map { $0.formatted(date: .omitted, time: .shortened) } ?? "standing")
                .font(.system(size: 11, weight: .medium).monospacedDigit())
                .foregroundStyle(item.isPast ? Color.secondary : Color.nInfoText)
                .frame(width: 64, alignment: .trailing)
            Image(systemName: item.icon)
                .font(.system(size: 11))
                .foregroundStyle(item.isPast ? Color.secondary : Color.nInfoText)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.title).font(.system(size: 12, weight: .medium))
                if !item.detail.isEmpty {
                    Text(item.detail).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(2)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 4).padding(.horizontal, 8)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
            .fill(item.isPast ? Color.clear : Color.nSurface))
    }

    // MARK: - Plumbing

    private func setDaemon(_ on: Bool) {
        if on {
            guard ambientCredentialAvailable else {
                daemonEnabled = false
                installNote = ambientUsesVertex
                    ? "Connect Google Vertex before enabling background scheduling."
                    : "Add an Anthropic API key before enabling background scheduling."
                showProviders(using: openWindow)
                return
            }
            daemonChangeInFlight = true
            installNote = "Starting background scheduling…"
            AmbientDaemon.install { installed in
                daemonChangeInFlight = false
                daemonEnabled = installed
                installNote = installed
                    ? nil
                    : "Background scheduling needs the installed app (not the dev build)."
                // The in-process child steps aside only after launchd really owns the job.
                store.syncInProcessRunner()
            }
        } else {
            daemonChangeInFlight = true
            installNote = "Stopping background scheduling…"
            AmbientDaemon.uninstall {
                daemonChangeInFlight = false
                daemonEnabled = false
                installNote = nil
                // Once launchd is gone, resume the app-owned scheduler if tasks require it.
                store.syncInProcessRunner()
            }
        }
    }

    private func shortDate(_ d: Date) -> String {
        let out = DateFormatter(); out.dateStyle = .none; out.timeStyle = .short
        if !cal.isDateInToday(d) { out.dateStyle = .short }
        return out.string(from: d)
    }
}

/// Create/edit form for a scheduled task.
private struct TaskEditor: View {
    @State var task: ScheduledTask
    @ObservedObject private var projects = ProjectStore.shared
    let onSave: (ScheduledTask) -> Void
    let onCancel: () -> Void
    private enum PickTarget: String, Identifiable { case cwd, watch; var id: String { rawValue } }
    @State private var picking: PickTarget?

    private let triggerTypes = [("Schedule", "time"), ("File or folder change", "file"), ("New mail", "inbox")]

    init(
        task: ScheduledTask,
        onSave: @escaping (ScheduledTask) -> Void,
        onCancel: @escaping () -> Void
    ) {
        var initialTask = task
        if !AmbientLanePolicy.isAvailableToScheduler(
            initialTask.resolvedAccess,
            directAccess: AmbientDaemon.accountAccess),
           let firstAvailable = AmbientLanePolicy.selectableSchedulable.first {
            initialTask.access = firstAvailable.rawValue
        }
        _task = State(initialValue: initialTask)
        self.onSave = onSave
        self.onCancel = onCancel
    }

    var body: some View {
        Form {
            Section("Task") {
                TextField("Name", text: $task.name)
                TextField("What should the agent do?", text: $task.prompt, axis: .vertical).lineLimit(3...6)
                Picker("Workspace", selection: $task.workspaceID) {
                    Text("Choose workspace").tag(UUID?.none)
                    ForEach(AmbientTaskWorkspacePolicy.selectableProjects(projects.projects)) { project in
                        Text(project.displayName).tag(Optional(project.id))
                    }
                }
            }
            Section("Trigger") {
                Picker("When", selection: $task.trigger.type) {
                    ForEach(triggerTypes, id: \.1) { Text($0.0).tag($0.1) }
                }
                triggerFields
            }
            Section("Provider") {
                Picker("Run with", selection: taskAccess) {
                    ForEach(AmbientLanePolicy.selectableSchedulable, id: \.self) { lane in
                        Text(lane.displayName).tag(lane.rawValue)
                    }
                }
                // Subscription lanes appear as an explanation rather than being silently absent —
                // a missing option reads as a bug, a stated reason reads as a decision.
                ForEach(unavailableLanes, id: \.self) { lane in
                    Label(
                        "\(lane.displayName): \(AmbientLanePolicy.unavailableReason(lane) ?? "")",
                        systemImage: "info.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let missing = missingCredentialNote {
                    Label(missing, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(Color.nWarningText)
                }
            }
            Section("Access") {
                Picker("Unattended access", selection: permissionMode) {
                    Text("Read-only workspace access").tag("dontAsk")
                    Text("Trust all — full Mac access").tag("bypassPermissions")
                }
                Text(task.permissionMode == "bypassPermissions"
                     ? "Full access runs without prompts. Use only workspaces, triggers, and instructions you trust."
                    : "Can read the workspace and create artifacts, but cannot edit files, run shell commands, or control other apps.")
                    .font(.caption)
                    .foregroundStyle(
                        task.permissionMode == "bypassPermissions"
                            ? Color.nWarningText : Color.secondary)
            }
            Section("Will this run?") {
                // The rules an unattended run is judged by are ours, not the user's — so state them
                // against THIS task before it ever runs, rather than letting it fail on schedule.
                ForEach(readinessFindings) { finding in
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(finding.title).font(.caption).bold()
                            Text(finding.detail).font(.caption).foregroundStyle(.secondary)
                        }
                    } icon: {
                        Image(systemName: readinessIcon(finding.severity))
                            .foregroundStyle(readinessTint(finding.severity))
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .fileImporter(isPresented: Binding(get: { picking != nil }, set: { if !$0 { picking = nil } }),
                      allowedContentTypes: [.item, .folder],
                      allowsMultipleSelection: false) { result in
            if case .success(let urls) = result, let url = urls.first {
                task.trigger.path = url.path
            }
            picking = nil
        }
        .safeAreaInset(edge: .bottom) {
            HStack(spacing: 8) {
                Spacer()
                Button("Cancel", role: .cancel) { onCancel() }
                    .buttonStyle(PillButtonStyle(kind: .plain))
                    .keyboardShortcut(.cancelAction)
                Button("Save") { onSave(normalized()) }
                    .buttonStyle(PillButtonStyle(kind: .accent))
                    .keyboardShortcut(.defaultAction)
                    .disabled(task.name.trimmingCharacters(in: .whitespaces).isEmpty
                              || task.prompt.trimmingCharacters(in: .whitespaces).isEmpty
                              || !task.hasSchedulableWorkspace)
            }
            .padding(12).background(.bar)
        }
    }

    @ViewBuilder
    private var triggerFields: some View {
        switch task.trigger.type {
        case "time":
            Picker("Repeat", selection: scheduleKind) {
                Text("Every N minutes").tag("interval")
                Text("Daily at time").tag("daily")
                Text("Once, at a date").tag("once")
            }
            switch task.trigger.schedule?.kind ?? "daily" {
            case "interval":
                Stepper("Every \(task.trigger.schedule?.minutes ?? 60) minutes",
                        value: minutesBinding, in: 1...1440, step: 5)
            case "once":
                DatePicker("On", selection: onceBinding, displayedComponents: [.date, .hourAndMinute])
            default:
                DatePicker("At", selection: dailyTimeBinding, displayedComponents: .hourAndMinute)
            }
        case "file":
            HStack {
                Text("Watch").foregroundStyle(.secondary)
                Text(((task.trigger.path ?? "No file selected") as NSString).lastPathComponent).lineLimit(1)
                Spacer()
                Button("Choose…") { chooseWatchTarget() }
                    .buttonStyle(PillButtonStyle(kind: .neutral))
            }
            Text("Fires when the file changes. For a folder, it fires when anything directly inside it does.")
                .font(.caption).foregroundStyle(.secondary)
        case "inbox":
            TextField("Only if sender/subject contains (optional)",
                      text: Binding(get: { task.trigger.filter ?? "" }, set: { task.trigger.filter = $0.isEmpty ? nil : $0 }))
        default: EmptyView()
        }
    }

    private var scheduleKind: Binding<String> {
        Binding(get: { task.trigger.schedule?.kind ?? "daily" },
                set: { k in
                    switch k {
                    case "interval":
                        task.trigger.schedule = AmbientSchedule(kind: "interval", minutes: task.trigger.schedule?.minutes ?? 60)
                    case "once":
                        let at = task.trigger.schedule?.at
                            ?? ISO8601DateFormatter().string(from: Date().addingTimeInterval(3600))
                        task.trigger.schedule = AmbientSchedule(kind: "once", at: at)
                    default:
                        task.trigger.schedule = AmbientSchedule(kind: "daily", hour: task.trigger.schedule?.hour ?? 9, minute: task.trigger.schedule?.minute ?? 0)
                    }
                })
    }
    private var permissionMode: Binding<String> {
        Binding(get: { task.permissionMode ?? "dontAsk" },
                set: { task.permissionMode = $0 })
    }
    private var readinessFindings: [TaskReadiness.Finding] {
        TaskReadiness.evaluate(
            task: task,
            credentialReady: ProviderAccountStore.shared.state(for: task.resolvedAccess).isAvailable,
            workspaceResolved: AmbientTaskWorkspacePolicy.resolves(
                task.workspaceID,
                in: projects.projects))
    }
    private func readinessIcon(_ severity: TaskReadiness.Severity) -> String {
        switch severity {
        case .blocking: return "xmark.octagon"
        case .warning: return "exclamationmark.triangle"
        case .info: return "info.circle"
        }
    }
    private func readinessTint(_ severity: TaskReadiness.Severity) -> Color {
        switch severity {
        case .blocking: return .nErrorText
        case .warning: return .nWarningText
        case .info: return .secondary
        }
    }
    private var taskAccess: Binding<String> {
        Binding(get: { task.resolvedAccess.rawValue },
                set: { task.access = $0 })
    }
    /// Subscription lanes the user actually has connected — worth explaining; ones they have never
    /// used would just be noise in the editor.
    private var unavailableLanes: [ModelAccess] {
        [.claudeSubscription, .codexSubscription].filter {
            !AmbientLanePolicy.isSchedulable($0)
                && ProviderAccountStore.shared.state(for: $0).isAvailable
        }
    }
    /// The chosen lane needs its own credential; without it this one task cannot run even though
    /// others still will.
    private var missingCredentialNote: String? {
        let lane = task.resolvedAccess
        guard !ProviderAccountStore.shared.state(for: lane).isAvailable else { return nil }
        return "\(lane.displayName) isn't connected yet. This task won't run until it is. "
            + "Connect it in Providers."
    }
    private var minutesBinding: Binding<Int> {
        Binding(get: { task.trigger.schedule?.minutes ?? 60 },
                set: { task.trigger.schedule = AmbientSchedule(kind: "interval", minutes: $0) })
    }
    private var dailyTimeBinding: Binding<Date> {
        Binding(get: {
            var c = DateComponents(); c.hour = task.trigger.schedule?.hour ?? 9; c.minute = task.trigger.schedule?.minute ?? 0
            return Calendar.current.date(from: c) ?? Date()
        }, set: { d in
            let c = Calendar.current.dateComponents([.hour, .minute], from: d)
            task.trigger.schedule = AmbientSchedule(kind: "daily", hour: c.hour, minute: c.minute)
        })
    }
    private var onceBinding: Binding<Date> {
        Binding(get: {
            (task.trigger.schedule?.at).flatMap(parseISO) ?? Date().addingTimeInterval(3600)
        }, set: { d in
            task.trigger.schedule = AmbientSchedule(kind: "once", at: ISO8601DateFormatter().string(from: d))
        })
    }

    private func normalized() -> ScheduledTask {
        var t = task
        if t.trigger.type == "inbox", t.trigger.client == nil { t.trigger.client = "mail" }
        if t.trigger.type == "time", t.trigger.schedule?.kind == "once", t.trigger.schedule?.at == nil {
            t.trigger.schedule?.at = ISO8601DateFormatter().string(from: Date().addingTimeInterval(3600))
        }
        if t.createdAt == nil { t.createdAt = ISO8601DateFormatter().string(from: Date()) }
        t.permissionMode = t.permissionMode ?? "dontAsk"
        return t
    }

    // .fileImporter (not NSOpenPanel.runModal) — a nested modal panel run from inside a .sheet
    // in a scene window tears the window down (the Projects-launcher bug class, 9daa29c).
    private func chooseWatchTarget() { picking = .watch }
}
