import Foundation

/// Release the on-disk residue of the reverted Runtime Service.
///
/// **What this is.** ADR-001 proposed a per-user `MechanicianRuntimeService` LaunchAgent. It was
/// built, shipped, and reverted on 2026-07-20; the ADR's own header says so and records that what
/// replaced it was nothing. The app talks to `agentd` over stdio, as it did before.
///
/// What the revert did not do is take the service's storage with it, and
/// `docs/architecture/STORAGE-AND-PERSISTENCE.md` has said so plainly ever since:
///
/// > `runtime/`, `runtime-resources/`, `runtime-service.sqlite` — residue of a reverted design.
/// > **nothing reads them.**
///
/// **Why it is worth code.** `runtime-resources/` stages a copy of the app's `Resources` per build,
/// keyed by build number, and nothing ever removed an old one. Measured on a developer machine six
/// weeks after the revert: six directories at roughly 696 MB each, **4.1 GB**, beside an 87 MB
/// `runtime/` holding the service's SQLite stores, every file dated to the day of the revert. For
/// anyone who takes frequent builds this grows by about 700 MB per build with no ceiling.
///
/// **Why it needs no preconditions.** `StorageRollbackReclaimPolicy` is gated on a soak, a verified
/// backup, an integrity check and every frozen source being accounted for, because it releases
/// somebody's pre-migration library and being wrong would cost conversations. This releases storage
/// that no code path reads. The proof is mechanical and repeatable:
///
/// ```
/// grep -rn "runtime-resources\|runtime-service\|RuntimeService" app/Sources agentd/src | wc -l   # 0
/// ```
///
/// `docs/architecture/OVERVIEW.md` already publishes that grep as a standing invariant.
///
/// **Relationship to `StorageRollbackReclaimPolicy.isProtected`.** That list names `runtime`, and
/// deliberately: it is a second guard over the support root's children, and the *rollback* reclaim
/// has no business releasing any of them. It is left exactly as it is. This is a different
/// operation with its own enumeration, which is why it does not widen that one.
enum RuntimeResidueReclaimPolicy {

    /// The complete, explicit set of names this may release, enumerated rather than derived, so a
    /// future directory appearing next to them cannot be swept in. Every entry is named in
    /// `STORAGE-AND-PERSISTENCE.md` as residue of the reverted design.
    static let residueNames = [
        "runtime-resources",
        "runtime",
        "runtime-service.sqlite",
        "runtime-service.sqlite-wal",
        "runtime-service.sqlite-shm",
    ]

    /// Existing residue, as direct children of this support root.
    ///
    /// Resolved through the root every time rather than accepting a caller's URL, so nothing
    /// outside the root can be named, and a `..` in a component cannot escape it.
    static func residueTargets(
        supportRoot: URL,
        fileManager: FileManager = .default
    ) -> [URL] {
        let root = supportRoot.standardizedFileURL
        return residueNames
            .map { root.appendingPathComponent($0).standardizedFileURL }
            .filter { isResidue($0, supportRoot: root) }
            .filter { fileManager.fileExists(atPath: $0.path) }
    }

    /// A path may be released only if it is a direct child of the support root **and** carries one
    /// of the enumerated names. Compares resolved paths rather than URLs, because a caller naming a
    /// directory gets a trailing slash that `==` on `URL` treats as a different value.
    static func isResidue(_ url: URL, supportRoot: URL) -> Bool {
        let root = supportRoot.standardizedFileURL
        let candidate = url.standardizedFileURL.path
        return residueNames.contains {
            candidate == root.appendingPathComponent($0).standardizedFileURL.path
        }
    }
}

enum RuntimeResidueReclaimError: Error, Equatable {
    /// A target that is not enumerated residue for this root. Never expected; thrown rather than
    /// skipped so a future change that widens the enumeration fails loudly in tests.
    case notResidue(String)
}

struct RuntimeResidueReclaimReport: Equatable, Sendable {
    var releasedNames: [String] = []
    var releasedBytes: Int64 = 0
    /// Where each released item landed, for the same two reasons the rollback report records it:
    /// "you can put it back" is only true if something can still name the copy, and a test that
    /// exercises the real `trashItem` has no other way to clean up after itself.
    var trashedURLs: [URL] = []

    /// Zero bytes counts as nothing even when a name was moved, so an empty directory that
    /// something recreated is not announced on every launch as "Zero KB released".
    var isEmpty: Bool { releasedNames.isEmpty || releasedBytes <= 0 }
}

enum RuntimeResidueReclaimService {
    /// Move the residue to the Trash rather than unlinking it.
    ///
    /// The space returns when the Trash is emptied, and until then anyone who doubts this analysis
    /// can put it back by hand. Unlinking 4 GB on the strength of a grep would be faster and
    /// unrecoverable, and the difference costs nothing here.
    ///
    /// Every target is re-checked against the enumeration immediately before it is moved, so a
    /// caller passing its own list cannot quietly widen what this releases.
    @discardableResult
    static func reclaim(
        supportRoot: URL,
        targets: [URL]? = nil,
        fileManager: FileManager = .default
    ) throws -> RuntimeResidueReclaimReport {
        let root = supportRoot.standardizedFileURL
        let candidates = targets ?? RuntimeResidueReclaimPolicy.residueTargets(
            supportRoot: root, fileManager: fileManager)
        var report = RuntimeResidueReclaimReport()
        for target in candidates {
            guard RuntimeResidueReclaimPolicy.isResidue(target, supportRoot: root) else {
                throw RuntimeResidueReclaimError.notResidue(target.lastPathComponent)
            }
            guard fileManager.fileExists(atPath: target.path) else { continue }
            let bytes = allocatedBytes(of: target, fileManager: fileManager)
            var trashed: NSURL?
            try fileManager.trashItem(at: target, resultingItemURL: &trashed)
            report.releasedNames.append(target.lastPathComponent)
            report.releasedBytes += bytes
            if let trashed = trashed as URL? { report.trashedURLs.append(trashed) }
        }
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

/// The one production caller.
///
/// Kept apart from `MechanicianApp` for the same reason `StorageRollbackReclaimLauncher` is: a
/// decision to release gigabytes of somebody's disk should be readable on its own rather than
/// buried in scene setup. Runs at most once per launch, never on the main actor.
enum RuntimeResidueReclaimLauncher {
    private static let queue = DispatchQueue(
        label: "ai.mechanician.runtime-residue-reclaim", qos: .utility)
    private static let lock = NSLock()
    private static var hasRun = false

    static func runAfterLaunch() {
        lock.lock()
        let alreadyRan = hasRun
        hasRun = true
        lock.unlock()
        guard !alreadyRan else { return }

        queue.async {
            // Only ever operate on the root this process actually recognized. A half-bootstrapped
            // root has no business being tidied, and this way a dev or tenant instance cleans its
            // own support directory rather than the released app's.
            let recognition = StorageAuthorityBootstrap.current
            let root = recognition.effectiveSupportRoot
            let report: RuntimeResidueReclaimReport
            do {
                report = try RuntimeResidueReclaimService.reclaim(supportRoot: root)
            } catch {
                NSLog("[storage] runtime residue reclaim failed: %@", String(describing: error))
                return
            }
            guard !report.isEmpty else { return }
            NSLog(
                "[storage] released %@ of reverted runtime-service residue: %@",
                ByteCountFormatter.string(fromByteCount: report.releasedBytes, countStyle: .file),
                report.releasedNames.joined(separator: ", "))
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
