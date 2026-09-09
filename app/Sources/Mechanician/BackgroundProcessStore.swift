import Foundation
import Combine

/// Background work an agent left running — poll loops, watchers, detached chains started by a Bash
/// tool call that outlived its turn (FR-117).
///
/// Reported by agentd, which both walks its own descendants and adopts orphans that pass a strict
/// identity check. `detached` means the process is no longer a child of agentd (it reparented to
/// launchd to survive), which is precisely the kind that used to be invisible.
struct BackgroundProcess: Identifiable, Equatable {
    var pid: Int
    /// Short label — usually the script being run, since a raw `bash -c` payload is unreadable.
    var label: String
    /// The full command, so a wait that will never finish is diagnosable from the panel.
    var command: String
    var ageSeconds: Double
    var detached: Bool
    /// Adopted by the orphan scan rather than seen as a descendant. Worth distinguishing: an adopted
    /// process was identified by heuristic (same user, started after the daemon, running from this
    /// workspace) rather than observed being spawned.
    var adopted: Bool
    /// Which daemon reported it. Not merely which lane: every window runs its OWN agentd per lane,
    /// and the kill control has to reach the one process that is actually tracking this pid.
    var source: BackgroundProcessSource
    /// The conversation whose turn was running when this process first appeared, when the daemon
    /// could attribute it unambiguously. Nil for work started outside any turn, or while several
    /// turns ran at once — a guess here would put someone else's process on your conversation's
    /// count. Unattributed processes stay visible in the process-wide panel.
    var conversationID: UUID?

    var access: ModelAccess { source.access }

    var id: Int { pid }
}

/// One agentd instance: a lane within a window's bridge. Two windows on the same lane are two
/// separate daemons with separate trackers, so the lane alone cannot identify a report.
struct BackgroundProcessSource: Hashable {
    var bridgeID: UUID
    var access: ModelAccess
}

extension BackgroundProcess {
    init?(event: [String: Any], source: BackgroundProcessSource) {
        guard let pid = event["pid"] as? Int else { return nil }
        self.pid = pid
        self.command = event["command"] as? String ?? ""
        self.label = (event["label"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "process \(pid)"
        self.ageSeconds = ((event["ageMs"] as? Double) ?? 0) / 1000
        self.detached = event["detached"] as? Bool ?? false
        self.adopted = event["adopted"] as? Bool ?? false
        self.source = source
        self.conversationID = (event["conversationId"] as? String).flatMap(UUID.init(uuidString:))
    }
}

/// Process-wide, because the Schedule panel is a single window that must show work started by any
/// window's daemon. Keyed by REPORTING DAEMON so one daemon's report never erases another's.
@MainActor
final class BackgroundProcessStore: ObservableObject {
    static let shared = BackgroundProcessStore()

    @Published private(set) var processes: [BackgroundProcess] = []
    private var bySource: [BackgroundProcessSource: [BackgroundProcess]] = [:]

    /// A daemon reports its complete current set, so this replaces that daemon's entry rather than
    /// merging — a process that ended must disappear, and a merge would strand it forever.
    func replace(_ processes: [BackgroundProcess], for source: BackgroundProcessSource) {
        if processes.isEmpty {
            guard bySource.removeValue(forKey: source) != nil else { return }
        } else {
            guard bySource[source] != processes else { return }
            bySource[source] = processes
        }
        republish()
    }

    /// A daemon going away takes its processes with it: the process that could report on them (and
    /// kill them) is gone, so listing them would offer a Stop button that cannot work.
    func clear(_ source: BackgroundProcessSource) {
        guard bySource.removeValue(forKey: source) != nil else { return }
        republish()
    }

    /// A successful Stop acknowledgement means this daemon delivered the signal. Remove its row
    /// immediately, but retain another daemon's independently tracked copy until that daemon's next
    /// snapshot proves the process exited. This keeps a SIGTERM-resistant orphan visible and
    /// stoppable even if the acknowledging daemon closes before it can report again.
    @discardableResult
    func acknowledgeStop(pid: Int, from source: BackgroundProcessSource) -> Bool {
        guard let reported = bySource[source] else { return false }
        let remaining = reported.filter { $0.pid != pid }
        guard remaining.count != reported.count else { return false }
        if remaining.isEmpty {
            bySource.removeValue(forKey: source)
        } else {
            bySource[source] = remaining
        }
        republish()
        return true
    }

    /// A window closing stops every lane it owned.
    func clearBridge(_ bridgeID: UUID) {
        let doomed = bySource.keys.filter { $0.bridgeID == bridgeID }
        guard !doomed.isEmpty else { return }
        doomed.forEach { bySource.removeValue(forKey: $0) }
        republish()
    }

    /// Work this conversation started. The control bar reports this rather than the process-wide
    /// total: one daemon serves every conversation on its lane, so the total answers "what has this
    /// window ever adopted", which is not a question anyone asked while reading one conversation.
    func processes(for conversationID: UUID?) -> [BackgroundProcess] {
        guard let conversationID else { return [] }
        return processes.filter { $0.conversationID == conversationID }
    }

    private func republish() {
        // Deduplicate by pid: two windows open on the same workspace will each adopt the same
        // detached orphan, and the user should see one row for one process, not one per daemon.
        var seen = Set<Int>()
        processes = bySource.values
            .flatMap { $0 }
            .sorted { $0.ageSeconds > $1.ageSeconds }
            .filter { seen.insert($0.pid).inserted }
    }
}
