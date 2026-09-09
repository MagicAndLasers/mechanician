import Foundation

/// How many daily copies of the library to keep, and what that costs.
///
/// **The default is 3, not the 7 the lifecycle used to hard-code.** Measured on a real library, one
/// generation is about 2.4 GB — and only 651 MB of that is the database. The other 1.7 GB is
/// retained media, copied whole into every generation because the shared object pool beside them is
/// empty. So seven daily copies is roughly 17 GB, almost all of it the same photographs and files
/// written out seven times.
///
/// Three is where the value is. Recovery from a working library is almost always "yesterday, or the
/// day before" — a copy from six days ago is a copy of a library you have since changed a great deal
/// — and three keeps the cost near 7 GB, which is defensible on a laptop. Anyone who wants the old
/// behaviour can ask for it; that is what the setting is for.
enum LibraryBackupSettings {

    /// The choices offered, in the order they are offered.
    ///
    /// Deliberately not free-form. A number field invites 30, and thirty copies of a 2.4 GB
    /// generation is 72 GB of somebody's disk spent on a value they typed without the arithmetic in
    /// front of them.
    static let choices = [1, 3, 7, 14]

    static let defaultGenerations = 3
    static let key = "libraryBackupGenerations"

    /// Whether backups are taken at all. On, because the alternative is what shipped for fifteen
    /// days by accident, and a person who turns it off has decided rather than been defaulted.
    static let enabledKey = "libraryBackupEnabled"

    static func isEnabled(store: UserDefaults = .standard) -> Bool {
        store.object(forKey: enabledKey) as? Bool ?? true
    }

    static func setEnabled(_ enabled: Bool, store: UserDefaults = .standard) {
        store.set(enabled, forKey: enabledKey)
    }

    /// A stored value outside the offered choices is ignored rather than clamped. A 0 would mean
    /// "keep nothing", which reads as a policy and is really a way to lose everything, and this is
    /// the one setting whose failure has no undo.
    static func generations(store: UserDefaults = .standard) -> Int {
        guard let raw = store.object(forKey: key) as? Int, choices.contains(raw) else {
            return defaultGenerations
        }
        return raw
    }

    static func setGenerations(_ count: Int, store: UserDefaults = .standard) {
        guard choices.contains(count) else { return }
        store.set(count, forKey: key)
    }

    /// What the copies occupy right now, and when the newest was taken.
    ///
    /// Read from disk rather than from a receipt: a receipt says what the app believes, and the
    /// number a person wants is what is actually on their disk.
    struct Usage: Equatable {
        var bytes: Int64
        var generations: Int
        var newest: Date?

        var isEmpty: Bool { generations == 0 }
    }

    // MARK: - What happened the last time one was attempted

    private static let lastFailureKey = "libraryBackupLastFailure"
    private static let lastFailureAtKey = "libraryBackupLastFailureAt"

    /// Why the most recent attempt did not produce a generation, in a place a person can see.
    ///
    /// **A backup that fails is worse than one that never runs**, because everything still looks
    /// arranged: the folder holds an older generation and this panel shows its date. On a real
    /// machine the daily backup threw on every single launch and nothing anywhere said so — the
    /// `NSLog` in the launcher never reached the unified log from a packaged app, and the panel went
    /// on reporting a generation from sixteen days earlier as though that were the schedule.
    ///
    /// Cleared by the next success, so it describes the present rather than accumulating history.
    static func recordFailure(
        _ reason: String?,
        at date: Date = Date(),
        store: UserDefaults = .standard
    ) {
        guard let reason, !reason.isEmpty else {
            store.removeObject(forKey: lastFailureKey)
            store.removeObject(forKey: lastFailureAtKey)
            return
        }
        store.set(reason, forKey: lastFailureKey)
        store.set(date.timeIntervalSince1970, forKey: lastFailureAtKey)
    }

    static func lastFailure(store: UserDefaults = .standard) -> (reason: String, at: Date)? {
        guard let reason = store.string(forKey: lastFailureKey), !reason.isEmpty else { return nil }
        let stamp = store.object(forKey: lastFailureAtKey) as? Double
        return (reason, stamp.map(Date.init(timeIntervalSince1970:)) ?? Date())
    }

    static func usage(for supportRoot: URL) -> Usage {
        let root = LibraryBackupLifecycle.backupRoot(for: supportRoot)
            .appendingPathComponent("generations", isDirectory: true)
        let manager = FileManager.default
        guard let entries = try? manager.contentsOfDirectory(
            at: root, includingPropertiesForKeys: [.contentModificationDateKey, .isDirectoryKey])
        else { return Usage(bytes: 0, generations: 0, newest: nil) }

        var bytes: Int64 = 0
        var count = 0
        var newest: Date?
        for entry in entries where entry.lastPathComponent.hasPrefix("generation-") {
            count += 1
            if let modified = try? entry.resourceValues(forKeys: [.contentModificationDateKey])
                .contentModificationDate {
                if newest == nil || modified > newest! { newest = modified }
            }
            bytes += directorySize(entry, manager: manager)
        }
        return Usage(bytes: bytes, generations: count, newest: newest)
    }

    /// Bounded on purpose. This runs to draw a settings pane, and a library with a great many
    /// retained files should cost a slow number rather than a hung window.
    private static func directorySize(_ url: URL, manager: FileManager) -> Int64 {
        guard let walker = manager.enumerator(
            at: url, includingPropertiesForKeys: [.fileAllocatedSizeKey, .totalFileAllocatedSizeKey])
        else { return 0 }
        var total: Int64 = 0
        var visited = 0
        for case let file as URL in walker {
            visited += 1
            if visited > 200_000 { break }
            let values = try? file.resourceValues(
                forKeys: [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey])
            total += Int64(values?.totalFileAllocatedSize ?? values?.fileAllocatedSize ?? 0)
        }
        return total
    }
}
