import AppKit
import CryptoKit
import Darwin
import Foundation

// Ambient state has a strict single-writer split:
//   tasks.json   — user-owned definitions, written only by the app
//   runtime.json — scheduler state, written only by ambientd
// Keeping those ownership domains separate prevents an editor save from rewinding a trigger
// watermark and prevents the daemon from overwriting a concurrent user edit.

struct AmbientSchedule: Codable, Equatable, Hashable {
    var kind: String        // "interval" | "daily" | "once"
    var minutes: Int?       // interval
    var hour: Int?          // daily
    var minute: Int?
    var at: String?         // once: ISO8601 date-time of the single run
}

struct AmbientTrigger: Codable, Equatable, Hashable {
    var type: String        // "time" | "file" | "inbox"
    var schedule: AmbientSchedule?
    var path: String?       // file
    var client: String?     // inbox: "mail"
    var filter: String?     // inbox substring filter
}

/// Scheduled work may run only in a user Workspace. Reserved Workspaces are interactive product
/// surfaces with their own closed agent profiles; treating one as ordinary unattended context
/// would silently replace that profile with the ambient runner's much broader execution surface.
enum AmbientTaskWorkspacePolicy {
    static func allowsAssignment(_ workspaceID: UUID?) -> Bool {
        workspaceID != nil && !ReservedWorkspace.owns(workspaceID)
    }

    /// A new task may inherit an ordinary active Workspace, but never a reserved product surface.
    /// Returning nil leaves the draft visibly unassigned so the person makes an explicit choice.
    static func inheritedWorkspaceID(_ workspaceID: UUID?) -> UUID? {
        allowsAssignment(workspaceID) ? workspaceID : nil
    }

    static func selectableProjects(_ projects: [Project]) -> [Project] {
        projects.filter { allowsAssignment($0.id) }
    }

    static func resolves(_ workspaceID: UUID?, in projects: [Project]) -> Bool {
        guard allowsAssignment(workspaceID), let workspaceID else { return false }
        return projects.contains { $0.id == workspaceID }
    }
}

struct ScheduledTask: Identifiable, Codable, Equatable {
    var id: String = UUID().uuidString
    var name: String
    var prompt: String
    /// Durable ownership. A topic workspace deliberately has no working directory but remains a
    /// valid home for ambient work and its artifacts.
    var workspaceID: UUID? = nil
    /// Read only for migration from the pre-workspace task contract. `AmbientStore.load()` either
    /// resolves this to a workspace or clears it and holds the task for user assignment.
    var cwd: String = ""
    var enabled: Bool = true
    var trigger: AmbientTrigger
    /// Which provider lane runs this task, as a `ModelAccess` raw value. Optional, and absent means
    /// the scheduler's configured direct route (Anthropic API publicly, or a tenant's Vertex route),
    /// so every task written before per-task providers keeps working — a non-Optional field here
    /// would quarantine every existing tasks.json.
    var access: String?
    var model: String?
    var effort: String?
    var permissionMode: String?
    var createdAt: String?
    /// Changes whenever the user edits the definition. ambientd uses it to reset trigger baselines
    /// without making the daemon a writer of tasks.json.
    var definitionRevision: String?
    /// A durable, idempotent "run now" request. The daemon records the last consumed id in
    /// runtime.json before executing it, so a crash cannot replay the request.
    var runRequestID: String?
    // daemon-owned runtime (merged from runtime.json for display; never encoded into tasks.json)
    var lastRun: String?
    var lastResult: String?
    var nextRun: Double?
    var lastMtime: Double?
    var lastMailId: String?
    var runNow: Bool?
    var lastRunRequestID: String?
    var onceCompleted: Bool?
    var activeRun: AmbientActiveRun?

    var isAssignedToWorkspace: Bool { workspaceID != nil }
    var hasSchedulableWorkspace: Bool {
        AmbientTaskWorkspacePolicy.allowsAssignment(workspaceID)
    }
    var isEffectivelyEnabled: Bool { enabled && onceCompleted != true }
    var hasPendingRunRequest: Bool {
        if let runRequestID { return runRequestID != lastRunRequestID }
        return runNow == true   // migration from the pre-request-id boolean contract
    }
    /// Disabling a schedule suppresses automatic triggers, but it must not suppress an explicit
    /// Run now request or kill the child while that manual run is already active.
    var needsSchedulerProcess: Bool {
        hasSchedulableWorkspace
            && (isEffectivelyEnabled || hasPendingRunRequest || activeRun != nil)
    }

    var triggerSummary: String {
        switch trigger.type {
        case "time":
            if let s = trigger.schedule {
                if s.kind == "interval" { return "Every \(s.minutes ?? 60) min" }
                if s.kind == "daily" { return String(format: "Daily at %02d:%02d", s.hour ?? 9, s.minute ?? 0) }
                if s.kind == "once" {
                    if let d = onceDate {
                        return "Once, " + d.formatted(date: .abbreviated, time: .shortened)
                    }
                    return "Once"
                }
            }
            return "Scheduled"
        case "file": return "On change: \((trigger.path as NSString?)?.lastPathComponent ?? "folder")"
        case "inbox": return "New mail" + (trigger.filter.map { " · \($0)" } ?? "")
        default: return trigger.type
        }
    }

    /// The single fire time of a one-shot ("once") task, when that's what this is.
    var onceDate: Date? {
        guard trigger.type == "time", let s = trigger.schedule, s.kind == "once",
              let at = s.at else { return nil }
        return ISO8601DateFormatter().date(from: at)
    }

    /// The daily fire time (hour/minute) applied to `day`, when this is a daily task.
    func dailyDate(on day: Date, calendar: Calendar = .current) -> Date? {
        guard trigger.type == "time", let s = trigger.schedule, s.kind == "daily" else { return nil }
        return calendar.date(bySettingHour: s.hour ?? 9, minute: s.minute ?? 0, second: 0, of: day)
    }

    /// `lastRun` parsed (the daemon writes JS toISOString — fractional seconds).
    var lastRunDate: Date? { lastRun.flatMap(parseISO) }

    /// The daemon's next-run timestamp (epoch seconds) as a Date.
    var nextRunDate: Date? {
        guard let ts = nextRun, ts > 0 else { return nil }
        return Date(timeIntervalSince1970: ts)
    }

    /// Short human form shared by every "Last run"/"Next" surface: time if today,
    /// date + time otherwise. Never show the raw ISO string in UI.
    static func shortDisplay(_ d: Date) -> String {
        let f = DateFormatter()
        f.timeStyle = .short
        f.dateStyle = Calendar.current.isDateInToday(d) ? .none : .short
        return f.string(from: d)
    }

    var lastRunDisplay: String? { lastRunDate.map(Self.shortDisplay) }
    var nextRunDisplay: String? { nextRunDate.map(Self.shortDisplay) }
}

struct AmbientActiveRun: Codable, Equatable {
    var id: String
    var startedAt: String
    var trigger: String?
}

/// Exact user-owned shape persisted to tasks.json. Runtime fields intentionally do not appear.
private struct AmbientTaskDefinition: Codable {
    var id: String
    var name: String
    var prompt: String
    var workspaceID: UUID?
    var cwd: String
    var enabled: Bool
    var trigger: AmbientTrigger
    var access: String?
    var model: String?
    var effort: String?
    var permissionMode: String?
    var createdAt: String?
    var definitionRevision: String?
    var runRequestID: String?

    init(_ task: ScheduledTask) {
        id = task.id
        name = task.name
        prompt = task.prompt
        workspaceID = task.workspaceID
        cwd = task.cwd
        enabled = task.enabled
        trigger = task.trigger
        access = task.access
        model = task.model
        effort = task.effort
        permissionMode = task.permissionMode
        createdAt = task.createdAt
        definitionRevision = task.definitionRevision
        runRequestID = task.runRequestID
    }

    var scheduledTask: ScheduledTask {
        ScheduledTask(
            id: id,
            name: name,
            prompt: prompt,
            workspaceID: workspaceID,
            cwd: cwd,
            enabled: enabled,
            trigger: trigger,
            access: access,
            model: model,
            effort: effort,
            permissionMode: permissionMode,
            createdAt: createdAt,
            definitionRevision: definitionRevision,
            runRequestID: runRequestID)
    }
}

/// Daemon-owned value in runtime.json, keyed by task id.
private struct AmbientTaskRuntime: Codable {
    var definitionRevision: String?
    var lastRun: String?
    var lastResult: String?
    var nextRun: Double?
    var lastMtime: Double?
    var lastMailId: String?
    var lastRunRequestID: String?
    var onceCompleted: Bool?
    var activeRun: AmbientActiveRun?
}

/// ISO8601 tolerant of the daemon's fractional seconds (JS toISOString) AND the plain form.
func parseISO(_ s: String) -> Date? {
    let frac = ISO8601DateFormatter(); frac.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let d = frac.date(from: s) { return d }
    return ISO8601DateFormatter().date(from: s)
}

/// One entry of `ambient/runs.json` — the daemon's append-only run history
/// ({taskId, at, ok, summary, conversationID}), oldest-first, capped at 500 by the daemon.
struct AmbientRun: Codable, Equatable, Identifiable {
    var taskId: String
    var at: String          // ISO8601
    var ok: Bool
    var summary: String
    var conversationID: String?

    var id: String { taskId + "|" + at }
    var date: Date? { parseISO(at) }
}

/// How alive the ambient daemon looks, judged by the age of its heartbeat.
enum SchedulerHealth {
    case running   // heartbeat < 90s old
    case stale     // 90s – 10m
    case off       // older, or no heartbeat file at all
}

@MainActor
final class AmbientStore: ObservableObject {
    static let shared = AmbientStore()
    @Published private(set) var tasks: [ScheduledTask] = []
    @Published private(set) var persistenceError: String?
    /// Real run history from `ambient/runs.json` (oldest-first). Empty when the daemon
    /// hasn't written it yet — views fall back to each task's `lastRun`.
    @Published var runs: [AmbientRun] = []
    /// The daemon's last tick from `ambient/heartbeat.json`; nil when it's never run.
    @Published var heartbeat: Date?

    private var dirWatch: DispatchSourceFileSystemObject?
    private var heartbeatTimer: Timer?
    /// Run ids seen at the last runs.json load; nil until the initial load so a cold
    /// start never fires catch-up notifications.
    private var knownRunIDs: Set<String>?
    /// The scheduler running as a CHILD of the app (so tasks fire while it's open, without the
    /// launchd agent). Mutually exclusive with the installed background agent.
    private var inProcessRunner: Process?
    /// Invalidates a cold `Process.run()` that is still waiting on macOS executable validation.
    /// The UUID lets disable/quit win even when the child does not exist yet and cannot be killed.
    private var inProcessLaunchID: UUID?
    private let selectedSQLiteAuthority: Bool
    private let authorityRepository: LibraryAuthorityRepository?
    private let authorityRepositoryOpenFailure: String?
    private let appSupportBaseOverride: URL?
    /// Enterprise policy/profile resolution is immutable for the process. Retaining the launch
    /// decision makes every later timer and daemon callback honor the same fail-closed answer.
    private let enterpriseConfigurationAllowsRuntime: Bool

    private var supportBase: URL {
        // Honor MECHANICIAN_SUPPORT_DIR (dev isolation) so the app and an in-process ambientd
        // child — which inherits that env — read/write the SAME ambient store.
        return appSupportBaseOverride ?? MechanicianEnvironment.currentSupportRoot()
    }

    private var dir: URL {
        // After activation these files are an explicit daemon projection/inbox, physically separate
        // from the frozen Legacy authority sources.
        let directoryName = selectedSQLiteAuthority ? "ambient-projection" : "ambient"
        let d = supportBase.appendingPathComponent(directoryName, isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }
    private var file: URL { dir.appendingPathComponent("tasks.json") }
    private var runtimeFile: URL { dir.appendingPathComponent("runtime.json") }
    private var runsFile: URL { dir.appendingPathComponent("runs.json") }
    private var heartbeatFile: URL { dir.appendingPathComponent("heartbeat.json") }

    init(
        appSupportBaseOverride: URL? = nil,
        libraryAuthorityRepository: LibraryAuthorityRepository? = nil,
        enterpriseConfigurationAllowsRuntime: Bool =
            EnterpriseConfigurationStartupGate.currentAllowsRuntime
    ) {
        self.appSupportBaseOverride = appSupportBaseOverride
        self.enterpriseConfigurationAllowsRuntime = enterpriseConfigurationAllowsRuntime
        let processSelectedSQLite: Bool
        if enterpriseConfigurationAllowsRuntime,
           case .sqlite = StorageAuthorityBootstrap.current.disposition {
            processSelectedSQLite = appSupportBaseOverride == nil
                && NSClassFromString("XCTestCase") == nil
        } else {
            processSelectedSQLite = false
        }
        selectedSQLiteAuthority = libraryAuthorityRepository != nil || processSelectedSQLite
        if let libraryAuthorityRepository {
            authorityRepository = libraryAuthorityRepository
            authorityRepositoryOpenFailure = nil
        } else if processSelectedSQLite {
            authorityRepository = LibraryAuthorityRepository.sharedIfActive
            authorityRepositoryOpenFailure = authorityRepository == nil
                ? "The SQLite authority repository was not available for the selected root."
                : nil
        } else {
            authorityRepository = nil
            authorityRepositoryOpenFailure = nil
        }
        // Scene-owned singletons can be materialized before applicationDidFinishLaunching presents
        // the fatal configuration alert. Do not touch ambient state or start any scheduler in that
        // interval when either the forced policy or its signed profile failed validation.
        guard enterpriseConfigurationAllowsRuntime else { return }
        load(); loadRuns(); loadHeartbeat()
        watchDir()
        // The pill must decay when the daemon goes silent — no file event arrives for
        // "nothing was written", so poll the tiny heartbeat file on a slow timer.
        heartbeatTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.loadHeartbeat(); self?.loadRuns(); self?.syncInProcessRunner() }
        }
        // A Sparkle update replaces the app bundle while launchd may still hold the old Node process.
        // Refresh only across an actual build boundary, and never make SwiftUI scene construction
        // wait for launchctl or first-execution validation of the bundled Node runtime.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            AmbientDaemon.refreshAfterAppUpdateIfNeeded()
        }
        syncInProcessRunner()  // start running tasks now if there are any and the daemon isn't installed
    }

    func load() {
        guard enterpriseConfigurationAllowsRuntime else { return }
        if selectedSQLiteAuthority {
            loadSQLiteAmbientState(ingestingDaemonState: true)
            syncInProcessRunner()
            return
        }
        guard let data = try? Data(contentsOf: file) else { return }
        guard let list = try? JSONDecoder().decode([ScheduledTask].self, from: data) else {
            // Corrupt (non-empty, undecodable) tasks.json: preserve it aside rather than silently
            // running with an empty schedule that the next save() would make permanent. Both writers
            // (app + daemon) write atomically, so a decode failure here is genuine corruption, not a
            // mid-write partial.
            if !data.isEmpty {
                let dest = file.appendingPathExtension("corrupt-\(Int(Date().timeIntervalSince1970))")
                try? FileManager.default.moveItem(at: file, to: dest)
            }
            return
        }
        let runtime = loadRuntime()
        var migrated = list
        var changed = false
        for index in migrated.indices {
            // The former folder owner is only a migration hint. Do not invent projects for old
            // watch paths: an unmatched task stays visible and waits for an explicit assignment.
            if migrated[index].workspaceID == nil, !migrated[index].cwd.isEmpty {
                migrated[index].workspaceID = ProjectStore.shared.projectID(
                    forCwd: migrated[index].cwd, createIfMissing: false)
                migrated[index].cwd = ""
                changed = true
            }
            if migrated[index].definitionRevision == nil {
                migrated[index].definitionRevision = UUID().uuidString
                changed = true
            }
            // Migrate the old shared boolean command into an idempotent request id.
            if migrated[index].runNow == true, migrated[index].runRequestID == nil {
                migrated[index].runRequestID = UUID().uuidString
                changed = true
            }
            if let state = runtime[migrated[index].id] {
                migrated[index].lastRun = state.lastRun
                migrated[index].lastResult = state.lastResult
                migrated[index].nextRun = state.nextRun
                migrated[index].lastMtime = state.lastMtime
                migrated[index].lastMailId = state.lastMailId
                migrated[index].lastRunRequestID = state.lastRunRequestID
                migrated[index].onceCompleted = state.onceCompleted
                migrated[index].activeRun = state.activeRun
                migrated[index].runNow = state.activeRun != nil
                    || migrated[index].runRequestID != state.lastRunRequestID
            } else {
                migrated[index].runNow = migrated[index].runRequestID != nil
            }
        }
        tasks = migrated
        if changed { save() }
        syncInProcessRunner()
    }

    private func loadRuntime() -> [String: AmbientTaskRuntime] {
        guard let data = try? Data(contentsOf: runtimeFile) else { return [:] }
        return (try? JSONDecoder().decode([String: AmbientTaskRuntime].self, from: data)) ?? [:]
    }

    // MARK: - In-process runner (run tasks while the app is open, no launchd agent needed)

    /// Reconcile the in-process scheduler with current state. Runs it iff there's at least one
    /// enabled task AND the launchd background agent ISN'T installed (that one already runs, even
    /// when the app is quit) — so tasks fire the moment the app is open, which is the #1 reason
    /// scheduled tasks silently never ran before. Idempotent; safe to call on every mutation.
    func syncInProcessRunner() {
        let shouldRun = Self.shouldRunInProcess(
            tasks: tasks,
            backgroundAgentInstalled: AmbientDaemon.isInstalled,
            daemonAvailable: AmbientDaemon.ambientdPath != nil,
            credentialAvailable: Self.laneCredentialReady,
            enterpriseConfigurationAllowsRuntime: enterpriseConfigurationAllowsRuntime,
            schedulingAllowed: ManagedEnterprisePolicy.current?.allowsUnattendedWork() ?? true)
        if shouldRun {
            guard inProcessRunner?.isRunning != true, inProcessLaunchID == nil else { return }
            inProcessRunner = nil
            let launchID = UUID()
            inProcessLaunchID = launchID
            AmbientDaemon.startInProcess { [weak self] process in
                guard let self else {
                    if process?.isRunning == true { process?.terminate() }
                    return
                }
                guard self.inProcessLaunchID == launchID else {
                    if process?.isRunning == true { process?.terminate() }
                    return
                }
                self.inProcessLaunchID = nil
                let stillShouldRun = Self.shouldRunInProcess(
                    tasks: self.tasks,
                    backgroundAgentInstalled: AmbientDaemon.isInstalled,
                    daemonAvailable: AmbientDaemon.ambientdPath != nil,
                    credentialAvailable: Self.laneCredentialReady,
                    enterpriseConfigurationAllowsRuntime:
                        self.enterpriseConfigurationAllowsRuntime,
                    schedulingAllowed: ManagedEnterprisePolicy.current?.allowsUnattendedWork() ?? true)
                guard stillShouldRun else {
                    if process?.isRunning == true { process?.terminate() }
                    return
                }
                self.inProcessRunner = process?.isRunning == true ? process : nil
            }
        } else {
            inProcessLaunchID = nil
            if inProcessRunner?.isRunning == true { inProcessRunner?.terminate() }
            inProcessRunner = nil
        }
    }

    /// Start the scheduler when ANY task that needs it has a usable credential for ITS OWN lane.
    /// Judging one global credential would let a single task on an unconnected provider keep every
    /// other task from ever running — the per-task gap belongs in that task's row, not here.
    static func shouldRunInProcess(
        tasks: [ScheduledTask],
        backgroundAgentInstalled: Bool,
        daemonAvailable: Bool,
        credentialAvailable: (ModelAccess) -> Bool,
        enterpriseConfigurationAllowsRuntime: Bool =
            EnterpriseConfigurationStartupGate.currentAllowsRuntime,
        schedulingAllowed: Bool = true,
        managedPolicy: ManagedEnterprisePolicy? = ManagedEnterprisePolicy.current,
        currentBuild: Int = ManagedEnterprisePolicy.currentAppBuild
    ) -> Bool {
        guard enterpriseConfigurationAllowsRuntime,
              schedulingAllowed,
              managedPolicy?.allowsUnattendedWork(currentBuild: currentBuild) ?? true,
              !backgroundAgentInstalled,
              daemonAvailable else { return false }
        return tasks.contains {
            $0.needsSchedulerProcess
                && (managedPolicy?.allows($0.resolvedAccess) ?? true)
                && credentialAvailable($0.resolvedAccess)
        }
    }

    /// Lanes the enabled tasks actually name, so the daemon is handed only the credentials it needs.
    static func requiredLanes(
        tasks: [ScheduledTask],
        enterpriseConfigurationAllowsRuntime: Bool =
            EnterpriseConfigurationStartupGate.currentAllowsRuntime,
        managedPolicy: ManagedEnterprisePolicy? = ManagedEnterprisePolicy.current,
        currentBuild: Int = ManagedEnterprisePolicy.currentAppBuild
    ) -> Set<ModelAccess> {
        guard enterpriseConfigurationAllowsRuntime,
              managedPolicy?.allowsUnattendedWork(currentBuild: currentBuild) ?? true else {
            return []
        }
        return Set(tasks.lazy
            .filter { $0.needsSchedulerProcess }
            .map(\.resolvedAccess)
            .filter { managedPolicy?.allows($0) ?? true })
    }

    /// A lane is usable when it is connected and not mid-account-operation.
    @MainActor static func laneCredentialReady(_ access: ModelAccess) -> Bool {
        EnterpriseConfigurationStartupGate.currentAllowsRuntime
            && (ManagedEnterprisePolicy.current?.allowsUnattendedWork() ?? true)
            && access.isAllowedByEnterprisePolicy
            && ProviderAccountStore.shared.operation(for: access) == nil
            && ProviderAccountStore.shared.state(for: access).isAvailable
    }

    /// Stop the child scheduler (app is quitting) so it isn't orphaned.
    func stopInProcessRunner() {
        inProcessLaunchID = nil
        if inProcessRunner?.isRunning == true { inProcessRunner?.terminate() }
        inProcessRunner = nil
    }

    // MARK: - Run history + heartbeat (daemon-written; may not exist yet)

    /// Health for the header pill, judged at `now` (pass a timeline date so it re-evaluates).
    func schedulerHealth(asOf now: Date = Date()) -> SchedulerHealth {
        guard let hb = heartbeat else { return .off }
        let age = now.timeIntervalSince(hb)
        if age < 90 { return .running }
        if age < 600 { return .stale }
        return .off
    }

    private struct Heartbeat: Codable { var lastTick: String }

    func loadHeartbeat() {
        guard enterpriseConfigurationAllowsRuntime else { return }
        let d = (try? Data(contentsOf: heartbeatFile))
            .flatMap { try? JSONDecoder().decode(Heartbeat.self, from: $0) }
            .flatMap { parseISO($0.lastTick) }
        if heartbeat != d { heartbeat = d }
    }

    func loadRuns() {
        guard enterpriseConfigurationAllowsRuntime else { return }
        if selectedSQLiteAuthority {
            loadSQLiteAmbientState(ingestingDaemonState: true)
            return
        }
        let list = (try? Data(contentsOf: runsFile))
            .flatMap { try? JSONDecoder().decode([AmbientRun].self, from: $0) } ?? []
        let previous = knownRunIDs
        knownRunIDs = Set(list.map(\.id))
        if runs != list { runs = list }

        notifyForNewRuns(previous: previous, runs: list)
    }

    private func notifyForNewRuns(previous: Set<String>?, runs list: [AmbientRun]) {
        // Notify for genuinely new entries — never on the initial load, and never for
        // stale catch-up (the daemon may have run plenty while the app was closed). An installed
        // launchd scheduler delivers through the signed app's native relay itself; only the
        // in-process scheduler leaves delivery to this observer.
        guard let previous else { return }
        guard !AmbientDaemon.isInstalled else { return }
        for run in list where !previous.contains(run.id) {
            guard let at = run.date, Date().timeIntervalSince(at) < 600 else { continue }
            let task = tasks.first(where: { $0.id == run.taskId })
            let conversation = run.conversationID.flatMap(UUID.init(uuidString:))
                .flatMap { ConversationStore.shared.summary($0) }
            let workspace = task?.workspaceID.flatMap { ProjectStore.shared.project($0)?.displayName }
                ?? "Mechanician"
            let name = conversation?.displayTitle ?? task?.name ?? "Scheduled task"
            let body = run.summary.isEmpty ? (run.ok ? "Completed." : "Failed.") : run.summary
            NotificationManager.shared.notify(
                title: "\(workspace) — \(name)", body: body, openWindowID: "ambient")
        }
    }

    private func save() {
        guard enterpriseConfigurationAllowsRuntime else { return }
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted]
        guard let data = try? enc.encode(tasks.map(AmbientTaskDefinition.init)) else { return }
        if selectedSQLiteAuthority {
            guard let authorityRepository else {
                persistenceError = authorityRepositoryOpenFailure
                    ?? "The SQLite authority repository is unavailable."
                return
            }
            do {
                var snapshots = try authorityRepository.ambientState()
                let definition = try Self.ambientSnapshot(
                    data: data,
                    kind: .taskDefinitions,
                    identity: "ambient-projection/tasks.json")
                snapshots.removeAll { $0.kind == .taskDefinitions }
                snapshots.append(definition)
                _ = try authorityRepository.commitAmbientState(snapshots)
                // ambientd remains a separate process and cannot open library.db. This is a
                // disposable read projection written only after the authoritative DB commit.
                try data.write(to: file, options: .atomic)
                persistenceError = nil
            } catch {
                persistenceError = "Scheduled tasks couldn’t be saved (\(error.localizedDescription))."
            }
            return
        }
        // .atomic so a crash mid-write can't truncate tasks.json — a corrupt schedule file reads as
        // an empty task list in both the app and the daemon, and the user's next add persists only
        // that one task, dropping the rest.
        do {
            try data.write(to: file, options: .atomic)
        } catch {
            // The existing Ambient editor owns user-facing save behavior. Crucially, a failed
            // legacy write never advances the SQLite candidate.
        }
    }

    @discardableResult
    func upsert(_ task: ScheduledTask) -> Bool {
        guard enterpriseConfigurationAllowsRuntime,
              ManagedEnterprisePolicy.current?.allowsUnattendedWork() ?? true else { return false }
        guard task.resolvedAccess.isAllowedByEnterprisePolicy else { return false }
        guard task.hasSchedulableWorkspace else { return false }
        var merged = task
        // Preserve the current daemon snapshot for the UI, but persist only the definition. Bumping
        // the revision tells ambientd to reset baselines for the newly edited trigger.
        if let fresh = tasks.first(where: { $0.id == task.id }) {
            merged.lastRun = fresh.lastRun
            merged.lastResult = fresh.lastResult
            merged.nextRun = fresh.nextRun
            merged.lastMtime = fresh.lastMtime
            merged.lastMailId = fresh.lastMailId
            merged.lastRunRequestID = fresh.lastRunRequestID
            merged.activeRun = fresh.activeRun
        }
        merged.definitionRevision = UUID().uuidString
        merged.onceCompleted = nil
        if let i = tasks.firstIndex(where: { $0.id == merged.id }) { tasks[i] = merged } else { tasks.append(merged) }
        save(); syncInProcessRunner()
        return true
    }

    /// Apply a model-requested definition through the app-owned store. The provider supplies a
    /// stable id for idempotence, but it cannot choose a workspace or an unattended permission
    /// profile: those remain trusted app context and default to read-only.
    func createFromAgent(_ proposed: ScheduledTask, workspaceID: UUID) -> (ok: Bool, message: String) {
        guard enterpriseConfigurationAllowsRuntime,
              ManagedEnterprisePolicy.current?.allowsUnattendedWork() ?? true else {
            return (false, String(localized: "Scheduled tasks are disabled by your organization."))
        }
        guard proposed.resolvedAccess.isAllowedByEnterprisePolicy else {
            return (false, String(localized: "That provider is blocked by your organization."))
        }
        guard AmbientTaskWorkspacePolicy.allowsAssignment(workspaceID) else {
            return (false, "Scheduled tasks need a regular workspace, not a reserved product workspace.")
        }
        if let existing = tasks.first(where: { $0.id == proposed.id }) {
            return (true, "Scheduled \"\(existing.name)\".")
        }
        var task = proposed
        task.workspaceID = workspaceID
        task.cwd = ""
        task.permissionMode = "dontAsk"
        task.definitionRevision = UUID().uuidString
        task.runRequestID = nil
        task.lastRun = nil
        task.lastResult = nil
        task.nextRun = nil
        task.lastMtime = nil
        task.lastMailId = nil
        task.runNow = nil
        task.lastRunRequestID = nil
        task.onceCompleted = nil
        task.activeRun = nil
        tasks.append(task)
        save(); syncInProcessRunner()
        return (true, "Scheduled \"\(task.name)\".")
    }

    func setEnabledFromAgent(_ id: String, _ enabled: Bool) -> (ok: Bool, message: String) {
        guard let index = tasks.firstIndex(where: { $0.id == id }) else {
            return (false, "No scheduled task has id \(id).")
        }
        let name = tasks[index].name
        guard setEnabled(id, enabled) else {
            return (false, "\"\(name)\" needs a regular Workspace before it can be changed.")
        }
        return (true, "\(enabled ? "Enabled" : "Disabled") \"\(name)\".")
    }

    func deleteFromAgent(_ id: String) -> (ok: Bool, message: String) {
        guard let task = tasks.first(where: { $0.id == id }) else {
            return (false, "No scheduled task has id \(id).")
        }
        delete(id)
        return (true, "Deleted \"\(task.name)\".")
    }

    func delete(_ id: String) { tasks.removeAll { $0.id == id }; save(); syncInProcessRunner() }

    /// Put a deleted task back where it was. The task value is its own receipt — a scheduled task
    /// has no bytes on disk to relocate — so restoring is re-inserting at the position it held.
    /// A stale index is clamped rather than trapped: the list may have changed while it was gone.
    func reinsert(_ task: ScheduledTask, at index: Int) {
        guard enterpriseConfigurationAllowsRuntime,
              ManagedEnterprisePolicy.current?.allowsUnattendedWork() ?? true else { return }
        guard task.resolvedAccess.isAllowedByEnterprisePolicy else { return }
        guard !tasks.contains(where: { $0.id == task.id }) else { return }
        tasks.insert(task, at: min(max(0, index), tasks.count))
        save()
        syncInProcessRunner()
    }

    @discardableResult
    func setEnabled(_ id: String, _ on: Bool) -> Bool {
        guard let i = tasks.firstIndex(where: { $0.id == id }),
              tasks[i].hasSchedulableWorkspace else { return false }
        if on {
            guard enterpriseConfigurationAllowsRuntime,
                  ManagedEnterprisePolicy.current?.allowsUnattendedWork() ?? true,
                  tasks[i].resolvedAccess.isAllowedByEnterprisePolicy else { return false }
        }
        tasks[i].enabled = on
        tasks[i].onceCompleted = nil
        tasks[i].definitionRevision = UUID().uuidString
        save(); syncInProcessRunner()
        return true
    }

    /// Ask the daemon to run this task immediately (it clears the flag when done).
    @discardableResult
    func runNow(_ id: String) -> Bool {
        guard enterpriseConfigurationAllowsRuntime,
              ManagedEnterprisePolicy.current?.allowsUnattendedWork() ?? true else { return false }
        guard let i = tasks.firstIndex(where: { $0.id == id }),
              tasks[i].hasSchedulableWorkspace,
              tasks[i].resolvedAccess.isAllowedByEnterprisePolicy else { return false }
        tasks[i].runRequestID = UUID().uuidString
        tasks[i].runNow = true
        save(); syncInProcessRunner()
        return true
    }

    /// Set by "Watch This File/Folder…" (file browser, intents) before opening the schedule
    /// window; AmbientView consumes it into a pre-filled watch-task editor. A published value —
    /// not a Notification — so it survives the window still being created when the request lands.
    @Published var pendingWatchPath: String?

    /// Set by "New Task…" in the toolbar's Tasks menu before opening the window; AmbientView
    /// consumes it into an empty editor. Same handoff contract as `pendingWatchPath` — the window
    /// may not exist yet when the request lands.
    @Published var pendingNewTaskRequest = false

    /// Build the standard watch task for a path (file or folder) — shared by the file-browser
    /// context menu, the editor default, and the AddWatchIntent.
    static func watchTask(path: String, workspaceID: UUID? = nil, prompt: String = "") -> ScheduledTask {
        let url = URL(fileURLWithPath: path)
        var isDir: ObjCBool = false
        FileManager.default.fileExists(atPath: path, isDirectory: &isDir)
        return ScheduledTask(
            name: "Watch \(url.lastPathComponent)",
            prompt: prompt,
            workspaceID: workspaceID,
            trigger: AmbientTrigger(type: "file", path: path))
    }

    // Watch the directory, not individual files: every writer uses atomic rename, which replaces
    // the inode and would strand a file-descriptor watcher on the old object.
    private func watchDir() {
        let fd = open(dir.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let src = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write], queue: .main)
        src.setEventHandler { [weak self] in
            self?.load()
            if self?.selectedSQLiteAuthority != true { self?.loadRuns() }
            self?.loadHeartbeat()
        }
        src.setCancelHandler { close(fd) }
        src.resume()
        dirWatch = src
    }

    /// Read durable task/runtime/run facts from SQLite. The daemon still owns its runtime and run
    /// output files as an external producer, so any complete atomic publication is first committed
    /// into SQLite and only then exposed to the UI. `tasks.json` is never read on this path.
    private func loadSQLiteAmbientState(ingestingDaemonState: Bool) {
        guard let authorityRepository else {
            persistenceError = authorityRepositoryOpenFailure
                ?? "The SQLite authority repository is unavailable."
            return
        }
        do {
            var snapshots = try authorityRepository.ambientState()
            if ingestingDaemonState {
                var changed = false
                for (url, kind, identity) in [
                    (runtimeFile, LibraryAmbientAuthoritySourceKind.schedulerRuntime,
                     "ambient-projection/runtime.json"),
                    (runsFile, LibraryAmbientAuthoritySourceKind.runReceipts,
                     "ambient-projection/runs.json"),
                ] {
                    guard let data = try? Data(contentsOf: url) else { continue }
                    let candidate = try Self.ambientSnapshot(
                        data: data, kind: kind, identity: identity)
                    let existing = snapshots.first(where: { $0.kind == kind })
                    if existing?.payloadVersion != candidate.payloadVersion
                        || existing?.payload != candidate.payload {
                        snapshots.removeAll { $0.kind == kind }
                        snapshots.append(candidate)
                        changed = true
                    }
                }
                if changed {
                    _ = try authorityRepository.commitAmbientState(snapshots)
                    snapshots = try authorityRepository.ambientState()
                }
            }

            let byKind = Dictionary(uniqueKeysWithValues: snapshots.map { ($0.kind, $0) })
            let definitions: [AmbientTaskDefinition]
            let definitionProjectionData: Data
            if let snapshot = byKind[.taskDefinitions] {
                let data = try LibraryAmbientAuthorityAdapter.freshLegacyData(
                    version: snapshot.payloadVersion,
                    payload: snapshot.payload,
                    expectedKind: .taskDefinitions)
                definitions = try JSONDecoder().decode([AmbientTaskDefinition].self, from: data)
                definitionProjectionData = data
            } else {
                definitions = []
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted]
                definitionProjectionData = try encoder.encode(definitions)
            }
            let runtime: [String: AmbientTaskRuntime]
            let runtimeProjectionData: Data
            if let snapshot = byKind[.schedulerRuntime] {
                let data = try LibraryAmbientAuthorityAdapter.freshLegacyData(
                    version: snapshot.payloadVersion,
                    payload: snapshot.payload,
                    expectedKind: .schedulerRuntime)
                runtime = try JSONDecoder().decode([String: AmbientTaskRuntime].self, from: data)
                runtimeProjectionData = data
            } else {
                runtime = [:]
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted]
                runtimeProjectionData = try encoder.encode(runtime)
            }
            let committedRuns: [AmbientRun]
            let runsProjectionData: Data
            if let snapshot = byKind[.runReceipts] {
                let data = try LibraryAmbientAuthorityAdapter.freshLegacyData(
                    version: snapshot.payloadVersion,
                    payload: snapshot.payload,
                    expectedKind: .runReceipts)
                committedRuns = try JSONDecoder().decode([AmbientRun].self, from: data)
                runsProjectionData = data
            } else {
                committedRuns = []
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted]
                runsProjectionData = try encoder.encode(committedRuns)
            }

            tasks = definitions.map { definition in
                var task = definition.scheduledTask
                if let state = runtime[task.id] {
                    task.lastRun = state.lastRun
                    task.lastResult = state.lastResult
                    task.nextRun = state.nextRun
                    task.lastMtime = state.lastMtime
                    task.lastMailId = state.lastMailId
                    task.lastRunRequestID = state.lastRunRequestID
                    task.onceCompleted = state.onceCompleted
                    task.activeRun = state.activeRun
                    task.runNow = state.activeRun != nil
                        || task.runRequestID != state.lastRunRequestID
                } else {
                    task.runNow = task.runRequestID != nil
                }
                return task
            }
            // Seed all three daemon projections from one committed DB snapshot before `load()` can
            // start the in-process runner or the delayed launchd refresh can reinstall ambientd.
            // Omitting runtime would rearm once/manual work; omitting runs would lose the daemon's
            // crash-recovery evidence exactly at cutover.
            for (url, data) in [
                (file, definitionProjectionData),
                (runtimeFile, runtimeProjectionData),
                (runsFile, runsProjectionData),
            ] where (try? Data(contentsOf: url)) != data {
                try data.write(to: url, options: .atomic)
            }
            let previous = knownRunIDs
            knownRunIDs = Set(committedRuns.map(\.id))
            runs = committedRuns
            // Preserve the existing cold-start/no-catch-up rule while keeping the in-process
            // scheduler's notification behavior after the run projection has reached SQLite.
            notifyForNewRuns(previous: previous, runs: committedRuns)
            persistenceError = nil
        } catch {
            persistenceError = "Scheduled task state couldn’t be loaded (\(error.localizedDescription))."
        }
    }

    nonisolated private static func ambientSnapshot(
        data: Data,
        kind: LibraryAmbientAuthoritySourceKind,
        identity: String
    ) throws -> ShadowLibraryAmbientSnapshot {
        let captured = try LibraryAmbientAuthorityAdapter.capture(sourceData: data, kind: kind)
        return ShadowLibraryAmbientSnapshot(
            kind: kind,
            payloadVersion: captured.version,
            payload: captured.payload,
            source: ShadowLibrarySourceFingerprint(
                identity: identity,
                revision: "sqlite-authority",
                sourceBytes: captured.payload))
    }
}

/// Installs/removes the ambient daemon as a launchd LaunchAgent so scheduled tasks
/// run even when the app is quit.
enum AmbientDaemon {
    /// Bump independently of CFBundleVersion whenever the bundled scheduler's durable handoff
    /// contract changes. Dogfood builds intentionally keep the public build number stable, so the
    /// build alone cannot tell an installed launchd job to stop using an older direct writer.
    static let inboxProtocolIdentity = "authority-inbox-v1"
    /// Public scheduling keeps its historical metered Anthropic API route. A tenant whose signed
    /// profile defaults to Vertex runs unattended work through that same enterprise route instead.
    static func accountAccess(for profile: TenantProfile) -> ModelAccess {
        profile.defaultAccess == .claudeVertex ? .claudeVertex : .anthropicAPI
    }

    static var accountAccess: ModelAccess { accountAccess(for: TenantProfile.current) }

    static var label: String {
        MechanicianEnvironment.scopedIdentifier(
            "ai.mechanician.ambient", for: Bundle.main.bundleIdentifier)
    }
    private static let legacyInstalledBuildPreferenceKey = "ambientDaemon.installedBuild.v1"
    private static let installedConfigurationPreferenceKey =
        "ambientDaemon.installedConfiguration.v2"
    /// Durable handoff flag written before launchd's Legacy writer is stopped for authority
    /// activation. It survives a process crash: a later Legacy launch restarts the old generation,
    /// while a successful SQLite relaunch installs the generation-scoped projection writer.
    private static let authorityCutoverFenceName = ".ambient-authority-cutover-fence-v1"
    private static let authorityCutoverFenceBytes = Data("ambient-authority-cutover-fence-v1\n".utf8)
    private static let controlQueue = DispatchQueue(
        label: "ai.mechanician.ambient-daemon.control", qos: .userInitiated)
    private static let childLaunchQueue = DispatchQueue(
        label: "ai.mechanician.ambient-daemon.child-launch", qos: .userInitiated)
    private static var domainTarget: String { "gui/\(getuid())" }
    private static var serviceTarget: String { "\(domainTarget)/\(label)" }

    /// Secret-free environment for both the in-process scheduler and its launchd installation.
    /// The profile may select only the audited Vertex adapter; it cannot inject arbitrary names.
    static func processEnvironment(
        profile: TenantProfile,
        bundleIdentifier: String?,
        environment: [String: String],
        homeDirectory: URL,
        notificationExecutable: URL? = nil,
        managedPolicy: ManagedEnterprisePolicy? = ManagedEnterprisePolicy.current,
        currentBuild: Int = ManagedEnterprisePolicy.currentAppBuild
    ) -> [String: String] {
        var derived = MechanicianEnvironment.processDefaults(
            bundleIdentifier: bundleIdentifier,
            environment: environment,
            homeDirectory: homeDirectory)
        // The scheduler may be started from a shell or a retained launchd job. Policy transport is
        // always reconstructed from the forced preference snapshot; similarly named inherited
        // values are never accepted as enterprise provenance.
        derived["MECHANICIAN_MANAGED_POLICY"] = nil
        derived["MECHANICIAN_MAX_PERMISSION_MODE"] = nil
        derived["MECHANICIAN_ALLOWED_PROVIDER_ACCESSES"] = nil
        derived["MECHANICIAN_ALLOW_USER_EXTENSIONS"] = nil
        derived["MECHANICIAN_MANAGED_EXTENSION_SERVERS"] = nil
        derived["MECHANICIAN_ALLOW_UNATTENDED_TASKS"] = nil
        derived.merge(
            MechanicianEnvironment.credentialServices(for: bundleIdentifier).processEnvironment,
            uniquingKeysWith: { _, signedIdentity in signedIdentity })
        let access = accountAccess(for: profile)
        derived["MECHANICIAN_AUTH"] = access == .claudeVertex ? "vertex" : "apikey"
        if access == .claudeVertex {
            let supportDirectory = AgentdRuntime.supportDirectory(
                environment: environment.merging(derived, uniquingKeysWith: { _, value in value }),
                homeDirectory: homeDirectory)
            derived.merge(
                AgentdRuntime.tenantRouteEnvironment(
                    for: access,
                    profile: profile,
                    supportDirectory: supportDirectory),
                uniquingKeysWith: { _, profileValue in profileValue })
        }
        if let notificationExecutable,
           notificationExecutable.isFileURL,
           notificationExecutable.path.hasPrefix("/") {
            derived["MECHANICIAN_NOTIFICATION_EXECUTABLE"] = notificationExecutable.path
        }
        if let managedPolicy {
            derived["MECHANICIAN_MANAGED_POLICY"] = "1"
            if let maximum = managedPolicy.maximumInteractivePermissionMode {
                derived["MECHANICIAN_MAX_PERMISSION_MODE"] = maximum
            }
            if let allowed = managedPolicy.allowedProviderAccesses {
                derived["MECHANICIAN_ALLOWED_PROVIDER_ACCESSES"] = allowed.sorted()
                    .joined(separator: ",")
            }
            derived["MECHANICIAN_ALLOW_USER_EXTENSIONS"] =
                managedPolicy.allowUserConfiguredExtensions ? "1" : "0"
            if !managedPolicy.allowUserConfiguredExtensions,
               let data = try? JSONEncoder().encode(profile.extensions.managedServers),
               data.count <= ManagedEnterprisePolicy.maximumManagedExtensionServerBytes {
                derived["MECHANICIAN_MANAGED_EXTENSION_SERVERS"] =
                    String(decoding: data, as: UTF8.self)
            }
            derived["MECHANICIAN_ALLOW_UNATTENDED_TASKS"] =
                managedPolicy.allowsUnattendedWork(currentBuild: currentBuild) ? "1" : "0"
        }
        return derived
    }

    private static var currentProcessEnvironment: [String: String] {
        var result = processEnvironment(
            profile: TenantProfile.current,
            bundleIdentifier: Bundle.main.bundleIdentifier,
            environment: ProcessInfo.processInfo.environment,
            homeDirectory: FileManager.default.homeDirectoryForCurrentUser,
            notificationExecutable: Bundle.main.bundleURL.pathExtension != "app"
                ? nil
                : Bundle.main.executableURL)
        let recognition = StorageAuthorityBootstrap.current
        result["MECHANICIAN_AUTHORITY_ANCHOR_DIR"] = recognition.anchorRoot.path
        result["MECHANICIAN_AUTHORITY_GENERATION"] = observedAuthorityGeneration(recognition)
        if case .sqlite = recognition.disposition {
            result["MECHANICIAN_AMBIENT_DIR"] = recognition.anchorRoot
                .appendingPathComponent("ambient-projection", isDirectory: true).path
        }
        let marketingVersion = Bundle.main.object(
            forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
        result["MECHANICIAN_PRODUCER_BUILD"] =
            "mechanician-\(marketingVersion)-\(currentBuild)-\(inboxProtocolIdentity)"
        return result
    }

    /// Diagnostic provenance only; the adopter always writes into the authority selected by its
    /// own process recognition. Keeping this value path-free also makes it safe in a strict inbox
    /// envelope when a rollback generation lives at an arbitrary filesystem location.
    static func observedAuthorityGeneration(_ recognition: StorageAuthorityRecognition) -> String {
        switch recognition.disposition {
        case .legacyUnmarked:
            return "legacy-unmarked"
        case .legacyGeneration(let marker, _):
            return "legacy-\(marker.activationID.uuidString.lowercased())"
        case .sqlite(let marker, _):
            return "sqlite-\(marker.activationID.uuidString.lowercased())"
        case .blocked:
            return "blocked"
        }
    }

    private static var currentBuild: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "dev"
    }

    static func configurationIdentity(
        build: String,
        profile: TenantProfile,
        authorityGeneration: String = "legacy-unmarked",
        managedPolicyIdentity: String? = nil
    ) -> String {
        let access = accountAccess(for: profile)
        let routeIdentity = profile.routeIdentity(for: access) ?? "built-in"
        let legacyIdentity =
            "\(build)|\(access.rawValue)|\(routeIdentity)|\(inboxProtocolIdentity)"
        // Preserve the installed Legacy identity byte-for-byte. The activated generation suffix is
        // the cutover signal that forces launchd to replace the direct-Legacy writer even when a
        // dogfood build intentionally keeps the same CFBundleVersion.
        let authorityIdentity = authorityGeneration == "legacy-unmarked"
            ? legacyIdentity
            : legacyIdentity + "|\(authorityGeneration)"
        guard let managedPolicyIdentity else { return authorityIdentity }
        return authorityIdentity + "|mdm|\(managedPolicyIdentity)"
    }

    private static var currentConfigurationIdentity: String {
        let profile = TenantProfile.current
        let managedPolicyIdentity = ManagedEnterprisePolicy.current.map { policy in
            let encodedServers = (try? JSONEncoder().encode(profile.extensions.managedServers))
                ?? Data()
            let serverDigest = SHA256.hash(data: encodedServers)
                .map { String(format: "%02x", $0) }
                .joined()
            return policy.runtimeIdentity + "|managed-servers:" + serverDigest
        }
        return configurationIdentity(
            build: currentBuild,
            profile: profile,
            authorityGeneration: observedAuthorityGeneration(StorageAuthorityBootstrap.current),
            managedPolicyIdentity: managedPolicyIdentity)
    }

    static var plistURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(label).plist")
    }

    static var isInstalled: Bool { FileManager.default.fileExists(atPath: plistURL.path) }

    /// Resolve the bundled (or env-overridden) ambientd.mjs; nil in a dev run.
    static var ambientdPath: String? {
        if let env = ProcessInfo.processInfo.environment["MECHANICIAN_AMBIENTD"] { return env }
        if let res = Bundle.main.resourceURL?.appendingPathComponent("agentd/src/ambientd.mjs").path,
           FileManager.default.fileExists(atPath: res) { return res }
        return nil
    }

    private static func nodePath() -> String {
        if let n = ProcessInfo.processInfo.environment["MECHANICIAN_NODE"] { return n }
        if let bundled = Bundle.main.resourceURL?.appendingPathComponent("node").path,
           FileManager.default.isExecutableFile(atPath: bundled) { return bundled }
        for c in ["/opt/homebrew/bin/node", "/usr/local/bin/node", "/usr/bin/node"]
        where FileManager.default.isExecutableFile(atPath: c) { return c }
        return "/usr/bin/node"
    }

    /// Install/reload the launchd job away from AppKit. `launchctl kickstart` may wait for macOS to
    /// validate the bundled runtime on its first execution; callers must never pay that cost on the
    /// main actor.
    static func install(completion: (@MainActor (Bool) -> Void)? = nil) {
        controlQueue.async {
            let installed = installSynchronously()
            guard let completion else { return }
            DispatchQueue.main.async {
                MainActor.assumeIsolated { completion(installed) }
            }
        }
    }

    /// Sparkle updates in place, so a launchd-owned process can retain the previous bundle's code.
    /// Refresh once per new build rather than bootout/bootstrap/kickstart on every app launch.
    static func refreshAfterAppUpdateIfNeeded() {
        guard EnterpriseConfigurationStartupGate.currentAllowsRuntime,
              ManagedEnterprisePolicy.current?.allowsUnattendedWork() ?? true else {
            uninstall()
            return
        }
        let supportRoot = StorageAuthorityBootstrap.current.anchorRoot
        let cutoverFencePending = authorityCutoverFenceIsPending(in: supportRoot)
        guard shouldRefreshInstallation(
            isInstalled: isInstalled,
            installedIdentity: UserDefaults.standard.string(
                forKey: installedConfigurationPreferenceKey)
                ?? UserDefaults.standard.string(forKey: legacyInstalledBuildPreferenceKey),
            currentIdentity: currentConfigurationIdentity,
            installationEnabled: UserDefaults.standard.bool(forKey: "ambientDaemonEnabled"),
            cutoverFencePending: cutoverFencePending)
        else { return }
        controlQueue.async {
            // A user may enable/disable scheduling while this deferred refresh waits behind another
            // launchd operation. Re-read both durable facts on the serialized queue before acting.
            guard shouldRefreshInstallation(
                isInstalled: isInstalled,
                installedIdentity: UserDefaults.standard.string(
                    forKey: installedConfigurationPreferenceKey)
                    ?? UserDefaults.standard.string(forKey: legacyInstalledBuildPreferenceKey),
                currentIdentity: currentConfigurationIdentity,
                installationEnabled: UserDefaults.standard.bool(forKey: "ambientDaemonEnabled"),
                cutoverFencePending: authorityCutoverFenceIsPending(in: supportRoot))
            else { return }
            _ = installSynchronously()
        }
    }

    static func shouldRefreshInstallation(
        isInstalled: Bool,
        installedIdentity: String?,
        currentIdentity: String,
        installationEnabled: Bool = false,
        cutoverFencePending: Bool = false
    ) -> Bool {
        cutoverFencePending
            || (!isInstalled && installationEnabled)
            || (isInstalled && installedIdentity != currentIdentity)
    }

    enum AuthorityCutoverFenceError: Error, Equatable, LocalizedError {
        case unsafeSupportRoot
        case receipt(String)
        case launchdWriterStillLoaded
        case schedulerWriterStillRunning(Int32?)

        var errorDescription: String? {
            switch self {
            case .unsafeSupportRoot:
                return "The ambient authority root is not an owner-only directory."
            case .receipt(let detail):
                return "The ambient cutover receipt could not be secured (\(detail))."
            case .launchdWriterStillLoaded:
                return "The Legacy ambient launch agent is still loaded."
            case .schedulerWriterStillRunning(let pid):
                return pid.map { "The Legacy ambient scheduler (pid \($0)) is still running." }
                    ?? "A Legacy ambient scheduler may still be running."
            }
        }
    }

    /// Stop and prove the absence of every ambient scheduler that can mutate Legacy runtime/run
    /// sources. Authority activation calls this before its final source census. The retained plist
    /// records user intent; the durable receipt forces either a same-generation restart after an
    /// aborted cutover or a generation-scoped reinstall after successful marker publication.
    static func fenceForAuthorityCutover(
        supportRoot: URL = StorageAuthorityBootstrap.current.anchorRoot
    ) throws {
        try controlQueue.sync {
            try fenceForAuthorityCutover(
                supportRoot: supportRoot,
                installationConfigured: isInstalled,
                command: launchctl,
                processAlive: processIsAlive,
                wait: { usleep($0) })
        }
    }

    /// Injectable seam for the cutover proof. Kept internal so focused tests never touch the user's
    /// launchd domain or signal an unrelated process.
    static func fenceForAuthorityCutover(
        supportRoot: URL,
        installationConfigured: Bool,
        command: ([String]) -> Int32,
        processAlive: (Int32) -> Bool,
        wait: (useconds_t) -> Void
    ) throws {
        let root = supportRoot.standardizedFileURL
        if installationConfigured { try publishAuthorityCutoverFence(in: root) }

        // `bootout` returning nonzero is harmless only when the subsequent read proves the service
        // absent. Poll because launchd may still be completing process teardown when bootout returns.
        _ = command(["bootout", serviceTarget])
        var serviceLoaded = command(["print", serviceTarget]) == 0
        for _ in 0..<100 where serviceLoaded {
            wait(50_000)
            serviceLoaded = command(["print", serviceTarget]) == 0
        }
        guard !serviceLoaded else {
            throw AuthorityCutoverFenceError.launchdWriterStillLoaded
        }

        let leaseDirectory = root.appendingPathComponent(
            "ambient/.scheduler-lease", isDirectory: true)
        for _ in 0..<100 {
            switch try schedulerLeaseOwnerPID(at: leaseDirectory) {
            case nil:
                return
            case .some(let pid) where !processAlive(pid):
                return
            case .some:
                wait(50_000)
            }
        }
        let pid = try schedulerLeaseOwnerPID(at: leaseDirectory)
        throw AuthorityCutoverFenceError.schedulerWriterStillRunning(pid)
    }

    static func authorityCutoverFenceIsPending(in supportRoot: URL) -> Bool {
        let url = authorityCutoverFenceURL(in: supportRoot)
        guard let data = try? protectedSmallFile(at: url) else { return false }
        return data == authorityCutoverFenceBytes
    }

    /// Called only after bootstrap + kickstart succeed. A failed reinstall keeps the durable receipt
    /// so every later launch retries instead of silently leaving background automation stopped.
    static func clearAuthorityCutoverFence(in supportRoot: URL) throws {
        let root = supportRoot.standardizedFileURL
        let url = authorityCutoverFenceURL(in: root)
        guard Darwin.unlink(url.path) == 0 else {
            if errno == ENOENT { return }
            throw AuthorityCutoverFenceError.receipt("unlink failed")
        }
        try synchronizeDirectory(root)
    }

    @discardableResult
    private static func installSynchronously() -> Bool {
        guard EnterpriseConfigurationStartupGate.currentAllowsRuntime,
              ManagedEnterprisePolicy.current?.allowsUnattendedWork() ?? true else { return false }
        guard let ambientd = ambientdPath else { return false }
        let identity = currentProcessEnvironment
        let logPath = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/\(label).log").path
        var plist: [String: Any] = [
            "Label": label,
            "ProgramArguments": [nodePath(), ambientd],
            "RunAtLoad": true,
            // Restart crashes, but throttle credential/config failures instead of a hot KeepAlive loop.
            "KeepAlive": ["SuccessfulExit": false],
            "ThrottleInterval": 60,
            "StandardErrorPath": logPath,
            "StandardOutPath": logPath,
        ]
        if !identity.isEmpty { plist["EnvironmentVariables"] = identity }
        try? FileManager.default.createDirectory(
            at: plistURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        do {
            let data = try PropertyListSerialization.data(
                fromPropertyList: plist, format: .xml, options: 0)
            try data.write(to: plistURL, options: .atomic)
        } catch { return false }
        _ = launchctl("bootout", serviceTarget) // absent is harmless
        guard launchctl("bootstrap", domainTarget, plistURL.path) == 0 else { return false }
        guard launchctl("kickstart", "-k", serviceTarget) == 0 else { return false }
        UserDefaults.standard.set(
            currentConfigurationIdentity,
            forKey: installedConfigurationPreferenceKey)
        UserDefaults.standard.removeObject(forKey: legacyInstalledBuildPreferenceKey)
        do {
            try clearAuthorityCutoverFence(in: StorageAuthorityBootstrap.current.anchorRoot)
        } catch {
            // The job is correctly installed, but retain the retry signal when its durable cleanup
            // cannot be proven. The next launch performs one harmless reinstall rather than losing
            // the user's scheduler after a later aborted cutover.
            return false
        }
        return true
    }

    static func uninstall(completion: (@MainActor () -> Void)? = nil) {
        controlQueue.async {
            _ = launchctl("bootout", serviceTarget)
            try? FileManager.default.removeItem(at: plistURL)
            UserDefaults.standard.removeObject(forKey: installedConfigurationPreferenceKey)
            UserDefaults.standard.removeObject(forKey: legacyInstalledBuildPreferenceKey)
            guard let completion else { return }
            DispatchQueue.main.async {
                MainActor.assumeIsolated { completion() }
            }
        }
    }

    /// Stop a credential-less KeepAlive job without forgetting that the user enabled background
    /// automation. `install()` will reload this retained plist after a new API key is added.
    static func stopKeepingConfiguration() {
        controlQueue.async { _ = launchctl("bootout", serviceTarget) }
    }

    /// Spawn ambientd as a CHILD of the app so scheduled tasks run while Mechanician is open —
    /// without needing the launchd background agent. Returns nil in a dev run (no bundled ambientd).
    /// The child inherits the app's environment (incl. MECHANICIAN_SUPPORT_DIR / _NODE if set), so it
    /// reads/writes the SAME store; logs to the same file the launchd agent uses.
    @MainActor
    static func startInProcess(completion: @escaping @MainActor (Process?) -> Void) {
        guard EnterpriseConfigurationStartupGate.currentAllowsRuntime,
              ManagedEnterprisePolicy.current?.allowsUnattendedWork() ?? true else {
            completion(nil)
            return
        }
        guard let ambientd = ambientdPath else {
            completion(nil)
            return
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: nodePath())
        p.arguments = [ambientd]
        // Inherit the app's non-provider env, then force the signed bundle/profile's route metadata
        // so a launching terminal cannot redirect unattended work to another backend.
        var env = ProcessInfo.processInfo.environment
        env["MECHANICIAN_MANAGED_POLICY"] = nil
        env["MECHANICIAN_MAX_PERMISSION_MODE"] = nil
        env["MECHANICIAN_ALLOWED_PROVIDER_ACCESSES"] = nil
        env["MECHANICIAN_ALLOW_USER_EXTENSIONS"] = nil
        env["MECHANICIAN_MANAGED_EXTENSION_SERVERS"] = nil
        env["MECHANICIAN_ALLOW_UNATTENDED_TASKS"] = nil
        env["MECHANICIAN_VERTEX_PROJECT"] = nil
        env["MECHANICIAN_VERTEX_REGION"] = nil
        env.merge(currentProcessEnvironment, uniquingKeysWith: { _, derived in derived })
        // Flag the in-process child so ambientd leaves notification delivery to the app's run-file
        // observer — no duplicate native banner. Never inherit alternate provider bearer tokens.
        env["ANTHROPIC_AUTH_TOKEN"] = nil
        env["CLAUDE_CODE_OAUTH_TOKEN"] = nil
        env["MECHANICIAN_AMBIENT_INPROCESS"] = "1"
        p.environment = env
        let log = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/\(label).log")
        if !FileManager.default.fileExists(atPath: log.path) {
            FileManager.default.createFile(atPath: log.path, contents: nil)
        }
        if let fh = try? FileHandle(forWritingTo: log) {
            fh.seekToEndOfFile(); p.standardOutput = fh; p.standardError = fh
        }
        childLaunchQueue.async {
            let launched: Process?
            do {
                try p.run()
                launched = p
            } catch {
                launched = nil
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated { completion(launched) }
            }
        }
    }

    @discardableResult
    private static func launchctl(_ args: [String]) -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        p.arguments = args
        do {
            try p.run()
            p.waitUntilExit()
            return p.terminationStatus
        } catch {
            return -1
        }
    }

    @discardableResult
    private static func launchctl(_ args: String...) -> Int32 {
        launchctl(args)
    }

    private static func processIsAlive(_ pid: Int32) -> Bool {
        guard pid > 1 else { return false }
        if kill(pid, 0) == 0 { return true }
        return errno == EPERM
    }

    private struct SchedulerLeaseOwner: Decodable {
        let schemaVersion: Int
        let pid: Int32
        let token: UUID
    }

    private static func schedulerLeaseOwnerPID(at directory: URL) throws -> Int32? {
        var directoryStatus = stat()
        guard lstat(directory.path, &directoryStatus) == 0 else {
            if errno == ENOENT { return nil }
            throw AuthorityCutoverFenceError.schedulerWriterStillRunning(nil)
        }
        guard directoryStatus.st_mode & S_IFMT == S_IFDIR,
              directoryStatus.st_uid == geteuid(),
              directoryStatus.st_mode & 0o077 == 0 else {
            throw AuthorityCutoverFenceError.schedulerWriterStillRunning(nil)
        }
        let ownerURL = directory.appendingPathComponent("owner.json", isDirectory: false)
        let data: Data
        do { data = try protectedSmallFile(at: ownerURL) }
        catch {
            throw AuthorityCutoverFenceError.schedulerWriterStillRunning(nil)
        }
        guard let owner = try? JSONDecoder().decode(SchedulerLeaseOwner.self, from: data),
              owner.schemaVersion == 1,
              owner.pid > 1 else {
            throw AuthorityCutoverFenceError.schedulerWriterStillRunning(nil)
        }
        return owner.pid
    }

    private static func authorityCutoverFenceURL(in supportRoot: URL) -> URL {
        supportRoot.standardizedFileURL.appendingPathComponent(
            authorityCutoverFenceName, isDirectory: false)
    }

    private static func publishAuthorityCutoverFence(in supportRoot: URL) throws {
        var rootStatus = stat()
        guard lstat(supportRoot.path, &rootStatus) == 0,
              rootStatus.st_mode & S_IFMT == S_IFDIR,
              rootStatus.st_uid == geteuid(),
              rootStatus.st_mode & 0o077 == 0 else {
            throw AuthorityCutoverFenceError.unsafeSupportRoot
        }
        let destination = authorityCutoverFenceURL(in: supportRoot)
        if FileManager.default.fileExists(atPath: destination.path) {
            guard authorityCutoverFenceIsPending(in: supportRoot) else {
                throw AuthorityCutoverFenceError.receipt("an invalid receipt already exists")
            }
            return
        }
        let temporary = supportRoot.appendingPathComponent(
            ".\(authorityCutoverFenceName).\(UUID().uuidString).tmp", isDirectory: false)
        let descriptor = Darwin.open(
            temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
            mode_t(0o600))
        guard descriptor >= 0 else {
            throw AuthorityCutoverFenceError.receipt("temporary file could not open")
        }
        var published = false
        defer {
            Darwin.close(descriptor)
            if !published { _ = Darwin.unlink(temporary.path) }
        }
        try authorityCutoverFenceBytes.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { return }
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(
                    descriptor, base.advanced(by: offset), bytes.count - offset)
                if count < 0, errno == EINTR { continue }
                guard count > 0 else {
                    throw AuthorityCutoverFenceError.receipt("write failed")
                }
                offset += count
            }
        }
        guard Darwin.fsync(descriptor) == 0,
              Darwin.rename(temporary.path, destination.path) == 0 else {
            throw AuthorityCutoverFenceError.receipt("publication failed")
        }
        published = true
        try synchronizeDirectory(supportRoot)
    }

    private static func protectedSmallFile(at url: URL) throws -> Data {
        var status = stat()
        guard lstat(url.path, &status) == 0,
              status.st_mode & S_IFMT == S_IFREG,
              status.st_uid == geteuid(),
              status.st_mode & 0o077 == 0,
              status.st_nlink == 1,
              status.st_size >= 0,
              status.st_size <= 4 * 1_024 else {
            throw AuthorityCutoverFenceError.receipt("file is not protected")
        }
        let descriptor = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else {
            throw AuthorityCutoverFenceError.receipt("file could not open")
        }
        defer { Darwin.close(descriptor) }
        var data = Data(count: Int(status.st_size))
        let expected = data.count
        let readCount = data.withUnsafeMutableBytes { bytes -> Int in
            guard let base = bytes.baseAddress else { return expected == 0 ? 0 : -1 }
            var offset = 0
            while offset < expected {
                let count = Darwin.read(descriptor, base.advanced(by: offset), expected - offset)
                if count < 0, errno == EINTR { continue }
                if count <= 0 { return -1 }
                offset += count
            }
            return offset
        }
        guard readCount == expected else {
            throw AuthorityCutoverFenceError.receipt("file changed while reading")
        }
        return data
    }

    private static func synchronizeDirectory(_ directory: URL) throws {
        let descriptor = Darwin.open(
            directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else {
            throw AuthorityCutoverFenceError.receipt("directory could not open")
        }
        defer { Darwin.close(descriptor) }
        guard Darwin.fsync(descriptor) == 0 else {
            throw AuthorityCutoverFenceError.receipt("directory sync failed")
        }
    }
}
