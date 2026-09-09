import Foundation

/// One copy of the library left behind by a schema upgrade.
struct SupersededAuthorityCopy: Equatable, Sendable {
    /// The retained database file itself.
    let url: URL
    /// The schema version the retained file holds, from its name.
    let schemaVersion: Int
    /// When the upgrade that retained it ran, from its name.
    ///
    /// This is also, exactly, when the library that replaced it became live: the rename and the
    /// swap are the same moment. That equivalence is what lets the newest copy be aged without
    /// consulting the marker.
    let supersededAt: Date
    /// `-wal` and `-shm` beside it, when present. Released with the file, never separately.
    let sidecarURLs: [URL]

    var allURLs: [URL] { [url] + sidecarURLs }
}

/// Release the library copies that schema upgrades leave behind.
///
/// **Where they come from.** `SQLiteLibraryAuthorityUpgrade.migrate` copies the database, upgrades
/// the copy, proves it opens, swaps it in, and renames the original to
/// `library.db.superseded-v<N>-<timestamp>`. That retention is correct and deliberate: it is why a
/// schema bump is recoverable at all, and it is what preserves the memory wiki through the removal
/// release. Nothing in the codebase has ever released one.
///
/// **What that costs.** Seven copies on a developer machine, **5.8 GB**, from bumps between
/// 2026-08-14 and 2026-08-23, at roughly 900 MB each and growing with the library. It is the
/// largest reclaimable item in the support directory and it accrues once per schema version.
///
/// **Two rules, both derived entirely from the filenames.**
///
/// 1. **A copy with a newer superseded sibling is provably unnecessary.** `superseded-v6` was
///    retained when the library went v6 to v7. The existence of `superseded-v7` proves the library
///    later went v7 to v8, which it could only do by opening as the recognized active authority at
///    v7. So the v6 upgrade demonstrably succeeded, and going back to v6 now would discard every
///    conversation since. No timer, no backup and no integrity check can add anything to a proof
///    the successor already carries.
///
/// 2. **The newest copy is aged.** Nothing newer exists to vouch for the live schema, so it is kept
///    until the schema that replaced it has been live for `soak`. Its own timestamp is that clock,
///    because the rename and the swap are one operation.
///
/// Steady state is therefore one copy during the soak and none after it, rather than one per schema
/// version forever.
///
/// **Why this does not reuse `StorageRollbackReclaimPolicy`.** That policy governs the one-time
/// migration's rollback generation, and its gates (a verified backup, a coverage proof over frozen
/// sources, an integrity receipt) are about proving a *cutover* lost nothing. This releases the
/// predecessors of ordinary schema bumps, which recur. Rule 1's proof is stronger than any of those
/// gates and rule 2's clock is already in the name; borrowing the migration's machinery would add
/// preconditions that cannot fail usefully here and would strand gigabytes whenever a backup had
/// not yet been verified.
enum SupersededAuthorityReclaimPolicy {

    /// How long the replacing schema must have been live before its predecessor is released. The
    /// same week `StorageRollbackReclaimPolicy` uses, for the same reason: ordinary use, not a
    /// timer that starts hopeful.
    static let soak: TimeInterval = 7 * 24 * 60 * 60

    /// `library.db.superseded-v12-20260823T180634Z`, and nothing else. Anchored at both ends so the
    /// live `library.db`, its journals, and a backup someone renamed by hand cannot match.
    private static let namePattern = try? NSRegularExpression(
        pattern: "^\(NSRegularExpression.escapedPattern(for: StorageAuthorityProtocol.databaseName))"
            + "\\.superseded-v(\\d+)-(\\d{8}T\\d{6}Z)$")

    /// The filename-safe UTC stamp `SQLiteLibraryAuthorityUpgrade` writes.
    private static func parseTimestamp(_ raw: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        return formatter.date(from: raw)
    }

    /// Every retained copy in this root, oldest first.
    ///
    /// A file whose name does not parse is not returned, so it is never released. Unparseable means
    /// "something other than this code wrote it", and the safe response to that is to leave it.
    static func copies(
        supportRoot: URL,
        fileManager: FileManager = .default
    ) -> [SupersededAuthorityCopy] {
        let root = supportRoot.standardizedFileURL
        guard let pattern = namePattern,
              let names = try? fileManager.contentsOfDirectory(atPath: root.path)
        else { return [] }

        var found: [SupersededAuthorityCopy] = []
        for name in names {
            let range = NSRange(name.startIndex..<name.endIndex, in: name)
            guard let match = pattern.firstMatch(in: name, range: range),
                  match.numberOfRanges == 3,
                  let versionRange = Range(match.range(at: 1), in: name),
                  let stampRange = Range(match.range(at: 2), in: name),
                  let version = Int(name[versionRange]),
                  let supersededAt = parseTimestamp(String(name[stampRange]))
            else { continue }

            let url = root.appendingPathComponent(name).standardizedFileURL
            let sidecars = ["-wal", "-shm"]
                .map { URL(fileURLWithPath: url.path + $0) }
                .filter { fileManager.fileExists(atPath: $0.path) }
            found.append(SupersededAuthorityCopy(
                url: url, schemaVersion: version, supersededAt: supersededAt,
                sidecarURLs: sidecars))
        }
        // Chronological, not by version: restoring a copy and upgrading again would produce two
        // files carrying the same version, and the timestamp is the only unambiguous order.
        return found.sorted {
            ($0.supersededAt, $0.url.lastPathComponent) < ($1.supersededAt, $1.url.lastPathComponent)
        }
    }

    /// The copies that may be released now.
    ///
    /// `authorityIsActive` gates everything, including rule 1. A library that is not the recognized
    /// active authority is a library somebody may be about to recover, and that is not the moment to
    /// be tidying away its predecessors, however provably stale they are.
    static func releasable(
        supportRoot: URL,
        authorityIsActive: Bool,
        now: Date = Date(),
        fileManager: FileManager = .default
    ) -> [SupersededAuthorityCopy] {
        guard authorityIsActive else { return [] }
        let all = copies(supportRoot: supportRoot, fileManager: fileManager)
        guard let newest = all.last else { return [] }

        // Rule 1: everything with a successor.
        let releasable = all.dropLast()

        // Rule 2: the newest, once the schema that replaced it has been live for the soak. A clock
        // that moved backwards must not look like a completed soak.
        let age = now.timeIntervalSince(newest.supersededAt)
        if age >= soak {
            return Array(releasable) + [newest]
        }
        return Array(releasable)
    }
}

enum SupersededAuthorityReclaimError: Error, Equatable {
    /// A target that is not a parseable superseded copy for this root. Thrown rather than skipped,
    /// so a future change that widens the enumeration fails loudly in tests instead of quietly
    /// releasing something else.
    case notASupersededCopy(String)
}

struct SupersededAuthorityReclaimReport: Equatable, Sendable {
    var releasedNames: [String] = []
    var releasedBytes: Int64 = 0
    var trashedURLs: [URL] = []
    /// Kept rather than released, and why, so the launcher can say so instead of reporting silence
    /// that looks identical to having found nothing.
    var retainedNames: [String] = []

    var isEmpty: Bool { releasedNames.isEmpty || releasedBytes <= 0 }
}

enum SupersededAuthorityReclaimService {
    /// Move the retained copies to the Trash rather than unlinking them, matching
    /// `StorageRollbackReclaimService`. These are somebody's rollback material: the space returns
    /// when the Trash is emptied, and until then the analysis above can be second-guessed by hand.
    ///
    /// Each candidate is re-parsed against the pattern immediately before it is moved, so a caller
    /// passing its own list cannot widen what this releases.
    @discardableResult
    static func reclaim(
        supportRoot: URL,
        authorityIsActive: Bool,
        targets: [SupersededAuthorityCopy]? = nil,
        now: Date = Date(),
        fileManager: FileManager = .default
    ) throws -> SupersededAuthorityReclaimReport {
        let root = supportRoot.standardizedFileURL
        let all = SupersededAuthorityReclaimPolicy.copies(
            supportRoot: root, fileManager: fileManager)
        let known = Set(all.map { $0.url.path })
        let candidates = targets ?? SupersededAuthorityReclaimPolicy.releasable(
            supportRoot: root, authorityIsActive: authorityIsActive, now: now,
            fileManager: fileManager)

        var report = SupersededAuthorityReclaimReport()
        for copy in candidates {
            guard known.contains(copy.url.path) else {
                throw SupersededAuthorityReclaimError.notASupersededCopy(
                    copy.url.lastPathComponent)
            }
            // The database and its journals move together or the remainder is a torn copy that
            // looks restorable and is not.
            for url in copy.allURLs {
                guard fileManager.fileExists(atPath: url.path) else { continue }
                let bytes = allocatedBytes(of: url, fileManager: fileManager)
                var trashed: NSURL?
                try fileManager.trashItem(at: url, resultingItemURL: &trashed)
                report.releasedBytes += bytes
                if let trashed = trashed as URL? { report.trashedURLs.append(trashed) }
            }
            report.releasedNames.append(copy.url.lastPathComponent)
        }
        let releasedPaths = Set(candidates.map { $0.url.path })
        report.retainedNames = all
            .filter { !releasedPaths.contains($0.url.path) }
            .map { $0.url.lastPathComponent }
        return report
    }

    private static func allocatedBytes(of url: URL, fileManager: FileManager) -> Int64 {
        let keys: Set<URLResourceKey> = [.totalFileAllocatedSizeKey, .isRegularFileKey]
        if let values = try? url.resourceValues(forKeys: keys), values.isRegularFile == true {
            return Int64(values.totalFileAllocatedSize ?? 0)
        }
        guard let enumerator = fileManager.enumerator(
            at: url, includingPropertiesForKeys: Array(keys)) else { return 0 }
        var total: Int64 = 0
        for case let child as URL in enumerator {
            guard let values = try? child.resourceValues(forKeys: keys),
                  values.isRegularFile == true else { continue }
            total += Int64(values.totalFileAllocatedSize ?? 0)
        }
        return total
    }
}

/// The one production caller. Runs at most once per launch, never on the main actor.
enum SupersededAuthorityReclaimLauncher {
    private static let queue = DispatchQueue(
        label: "ai.mechanician.superseded-authority-reclaim", qos: .utility)
    private static let lock = NSLock()
    private static var hasRun = false

    static func runAfterLaunch(now: Date = Date()) {
        lock.lock()
        let alreadyRan = hasRun
        hasRun = true
        lock.unlock()
        guard !alreadyRan else { return }

        queue.async {
            let recognition = StorageAuthorityBootstrap.current
            // Only when this process recognized a live SQLite authority. Anything else is a root
            // somebody may be about to recover from one of these very files.
            guard case .sqlite = recognition.disposition else { return }
            let root = recognition.effectiveSupportRoot
            let report: SupersededAuthorityReclaimReport
            do {
                report = try SupersededAuthorityReclaimService.reclaim(
                    supportRoot: root, authorityIsActive: true, now: now)
            } catch {
                NSLog(
                    "[storage] superseded authority reclaim failed: %@", String(describing: error))
                return
            }
            guard !report.isEmpty else { return }
            NSLog(
                "[storage] released %@ of superseded library copies: %@%@",
                ByteCountFormatter.string(fromByteCount: report.releasedBytes, countStyle: .file),
                report.releasedNames.joined(separator: ", "),
                report.retainedNames.isEmpty
                    ? "" : "; retained \(report.retainedNames.joined(separator: ", "))")
        }
    }

    /// Test seam: the launcher runs at most once per process, which would make a second test
    /// silently pass.
    static func resetForTesting() {
        lock.lock()
        hasRun = false
        lock.unlock()
    }
}
