import Darwin
import Foundation

/// One launch, measured on the user's own library rather than on a rehearsal corpus.
///
/// Both durations are measured from real process start, not from the first Swift line we happen to
/// run, so they include dyld and scene bootstrap: the wait a person actually experiences.
struct LaunchTimingRecord: Codable, Equatable, Sendable {
    let startedAt: Date
    /// Process start until the Conversation inventory is ready and the sidebar can paint.
    let inventoryMilliseconds: Int
    /// Process start until the restored transcript replaces the opening state. Absent when the
    /// launch never opened a Conversation.
    var conversationMilliseconds: Int?
    let usedSQLiteInventory: Bool
    let conversationCount: Int
    /// Cumulative milliseconds from process start for each reached stage, keyed by
    /// `LaunchStage.rawValue`. Optional so records written before stages existed still decode:
    /// a synthesized `Decodable` ignores property defaults, and a non-optional addition would
    /// quarantine every older record.
    var stages: [String: Int]?
}

/// Named points on the launch path, in order. Only the SQLite launch path reports the middle
/// three; a Legacy fallback launch simply omits them.
enum LaunchStage: String, Codable, CaseIterable, Sendable {
    /// Process start until the app's first line of Swift: dyld, framework loading, and whatever
    /// the OS does before us. We cannot optimize this from inside a phase we never run in.
    case appCode
    /// The app's own bootstrap before the store starts loading: environment, provenance, authority
    /// recognition, repository preflight, and SwiftUI scene construction.
    case storeOpen
    /// The SQLite launch inventory read returning its bundle.
    case libraryRead
    /// Conversations the launch must hold resident (intrinsic operative work, or every record in
    /// eager mode) decoded from the library.
    case residentsLoaded
    /// The filesystem-generation census proving that bundle still describes the sources.
    case sourceCensus
    /// Matching the search projection against that exact inventory.
    case searchCheck
    case inventoryReady
    /// Main-actor work that runs once the inventory is ready and before any window asks for its
    /// Conversation: Spotlight reindex, Workspace migration and binding repair, inbox adoption.
    /// It precedes the transcript rather than overlapping it, so its cost is the person's wait.
    case launchFollowUp
    /// The restored window asking the store for its Conversation. Measured here rather than at the
    /// session-planning call so it excludes plan and AppKit construction while retaining the actual
    /// record request boundary.
    case conversationRequested
    /// The launch Conversation's record reconstructed and handed back to its window.
    case conversationRecord
    /// The record installed into the window: model selection, workspace scope, and — for a record
    /// that is not mid-turn — staging a provider history replay built from every message. Separated
    /// from the paint that follows it so the two are not read as one presentation cost.
    case conversationInstalled
    case workspaceVisible

    var label: String {
        switch self {
        case .appCode: return "startup"
        case .storeOpen: return "app setup"
        case .libraryRead: return "library"
        case .residentsLoaded: return "conversations"
        case .sourceCensus: return "sources"
        case .searchCheck: return "search"
        case .inventoryReady: return "sidebar"
        case .launchFollowUp: return "follow-up"
        case .conversationRequested: return "requested"
        case .conversationRecord: return "record"
        case .conversationInstalled: return "install"
        case .workspaceVisible: return "transcript"
        }
    }
}

enum LaunchClock {
    /// Seconds between process start and now, or nil when the value cannot be trusted.
    ///
    /// `p_starttime` is wall clock, so a clock change during launch could otherwise produce a
    /// negative or absurd duration. Reject anything outside a plausible launch window and let the
    /// caller fall back to its in-process mark.
    static func plausibleElapsed(processStartEpoch: Double, nowEpoch: Double) -> Double? {
        let elapsed = nowEpoch - processStartEpoch
        guard elapsed.isFinite, elapsed >= 0, elapsed <= 600 else { return nil }
        return elapsed
    }

    /// The most any real launch can spend before the first Swift line runs. Beyond this, the
    /// process was not started as this app: `dev.sh` ends in `exec`, so the app inherits the
    /// shell's PID and `p_starttime` covers the whole build. Fall back to the in-process mark
    /// rather than reporting a launch that includes work the user never waited on.
    static let maximumPreLaunchSeconds: Double = 10

    static func trustsProcessStart(secondsElapsedAtAppStart: Double?) -> Bool {
        guard let seconds = secondsElapsedAtAppStart else { return false }
        return seconds <= maximumPreLaunchSeconds
    }

    static func processStartEpoch(pid: pid_t = getpid()) -> Double? {
        var name: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        let result = name.withUnsafeMutableBufferPointer { buffer -> Int32 in
            guard let base = buffer.baseAddress else { return -1 }
            return sysctl(base, UInt32(buffer.count), &info, &size, nil, 0)
        }
        guard result == 0, size > 0 else { return nil }
        let start = info.kp_proc.p_starttime
        guard start.tv_sec > 0 else { return nil }
        return Double(start.tv_sec) + Double(start.tv_usec) / 1_000_000
    }
}

enum LaunchTimingPresentation {
    static func duration(_ milliseconds: Int?) -> String? {
        guard let milliseconds, milliseconds >= 0 else { return nil }
        if milliseconds < 1_000 { return "\(milliseconds) ms" }
        return String(format: "%.1f s", Double(milliseconds) / 1_000)
    }

    /// "1.9 s to inventory · 2.4 s to conversation", or just the inventory half when the launch
    /// never opened one.
    static func summary(_ record: LaunchTimingRecord?) -> String {
        guard let record, let inventory = duration(record.inventoryMilliseconds) else {
            return "Not measured yet"
        }
        guard let conversation = duration(record.conversationMilliseconds) else {
            return "\(inventory) to inventory"
        }
        return "\(inventory) to inventory · \(conversation) to conversation"
    }

    /// "startup 1.2 s · library 0.3 s · search 0.8 s · transcript 1.7 s": the time spent *in* each
    /// segment, so the largest number names what to fix. Absent when no stages were recorded.
    static func breakdown(_ record: LaunchTimingRecord?) -> String? {
        guard let stages = record?.stages, !stages.isEmpty else { return nil }
        var previous = 0
        var parts: [String] = []
        for stage in LaunchStage.allCases {
            guard let reached = stages[stage.rawValue] else { continue }
            let delta = max(0, reached - previous)
            previous = reached
            guard let text = duration(delta) else { continue }
            parts.append("\(stage.label) \(text)")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// Median of the retained launches, which resists the one cold launch after an update.
    static func median(_ records: [LaunchTimingRecord]) -> String? {
        let values = records.map(\.inventoryMilliseconds).sorted()
        guard !values.isEmpty else { return nil }
        let middle = values[values.count / 2]
        guard let text = duration(middle) else { return nil }
        return "\(text) across \(values.count) launch\(values.count == 1 ? "" : "es")"
    }
}

/// Bounded, disposable launch telemetry. It holds no user content, is capped at the last few
/// launches, and is deliberately kept out of `library.db`: losing it must never matter.
@MainActor
final class LaunchMetrics: ObservableObject {
    static let shared = LaunchMetrics()
    static let retainedLaunches = 5
    private static let defaultsKey = "launchTimings.v2"

    @Published private(set) var history: [LaunchTimingRecord] = []

    private let defaults: UserDefaults
    private var fallbackStartUptime = ProcessInfo.processInfo.systemUptime
    private var trustsProcessStart = false
    private var inventoryRecorded = false
    private var conversationRecorded = false
    private var stages: [String: Int] = [:]

    init(defaults: UserDefaults = .standard, loadsHistory: Bool = true) {
        self.defaults = defaults
        if loadsHistory { history = Self.load(from: defaults) }
    }

    /// Called as early as the app can run code. Besides establishing the fallback mark, this is
    /// where we decide whether the kernel's process-start time describes this app's launch at all.
    func markAppStart() {
        fallbackStartUptime = ProcessInfo.processInfo.systemUptime
        let preLaunch = LaunchClock.processStartEpoch().flatMap {
            LaunchClock.plausibleElapsed(
                processStartEpoch: $0,
                nowEpoch: Date().timeIntervalSince1970)
        }
        trustsProcessStart = LaunchClock.trustsProcessStart(secondsElapsedAtAppStart: preLaunch)
        mark(.appCode)
    }

    /// Records when a stage was first reached. Later calls for the same stage are ignored, so a
    /// retried or repeated launch step cannot rewrite the segment a person already waited through.
    func mark(_ stage: LaunchStage) {
        guard stages[stage.rawValue] == nil else { return }
        stages[stage.rawValue] = elapsedMilliseconds()
        if inventoryRecorded, !history.isEmpty {
            history[history.count - 1].stages = stages
            persist()
        }
    }

    /// Background launch work reports through this. It is static and nonisolated so a `Sendable`
    /// worker closure never has to capture the main-actor singleton to record a stage.
    nonisolated static func markFromBackground(_ stage: LaunchStage) {
        DispatchQueue.main.async { MainActor.assumeIsolated { shared.mark(stage) } }
    }

    func markInventoryReady(usedSQLiteInventory: Bool, conversationCount: Int) {
        guard !inventoryRecorded else { return }
        inventoryRecorded = true
        let elapsed = elapsedMilliseconds()
        stages[LaunchStage.inventoryReady.rawValue] = elapsed
        let record = LaunchTimingRecord(
            startedAt: Date(),
            inventoryMilliseconds: elapsed,
            conversationMilliseconds: nil,
            usedSQLiteInventory: usedSQLiteInventory,
            conversationCount: conversationCount,
            stages: stages)
        history.append(record)
        history = Array(history.suffix(Self.retainedLaunches))
        persist()
    }

    /// The moment the opening state gives way to the restored transcript. Only the first one in a
    /// launch is the launch; later navigation is measured elsewhere.
    func markFirstConversationVisible() {
        guard inventoryRecorded, !conversationRecorded, !history.isEmpty else { return }
        conversationRecorded = true
        let elapsed = elapsedMilliseconds()
        stages[LaunchStage.workspaceVisible.rawValue] = elapsed
        history[history.count - 1].conversationMilliseconds = elapsed
        history[history.count - 1].stages = stages
        persist()
    }

    var lastLaunch: LaunchTimingRecord? { history.last }

    private func elapsedMilliseconds() -> Int {
        if trustsProcessStart,
           let start = LaunchClock.processStartEpoch(),
           let elapsed = LaunchClock.plausibleElapsed(
            processStartEpoch: start,
            nowEpoch: Date().timeIntervalSince1970) {
            return Int((elapsed * 1_000).rounded())
        }
        let elapsed = ProcessInfo.processInfo.systemUptime - fallbackStartUptime
        return Int((max(0, elapsed) * 1_000).rounded())
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(history) else { return }
        defaults.set(data, forKey: Self.defaultsKey)
    }

    private static func load(from defaults: UserDefaults) -> [LaunchTimingRecord] {
        guard let data = defaults.data(forKey: defaultsKey),
              let decoded = try? JSONDecoder().decode([LaunchTimingRecord].self, from: data)
        else { return [] }
        return Array(decoded.suffix(retainedLaunches))
    }
}
