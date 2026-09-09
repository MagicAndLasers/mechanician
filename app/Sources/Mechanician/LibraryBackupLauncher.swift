import Foundation

/// The one production caller of the daily library backup.
///
/// **There was none for fifteen days.** `createBackupIfDue` is the only thing that creates a
/// backup, and its two call sites lived inside the migration: `626de3d` added them when the SQLite
/// authority was activated, and `4ea5560` — "retire completed migration" — removed them with the
/// migration they sat in. Nothing noticed, because the lifecycle's own tests kept passing.
///
/// The cost was invisible and total. `library.db` is the sole authority for every conversation,
/// and a real machine held exactly one generation, dated the day of the
/// activation, with an empty object pool — beside four hand-made copies its owner had taken during
/// risky operations, which is a person doing by hand what the app had stopped doing.
///
/// Modelled on `StorageRollbackReclaimLauncher` deliberately, and kept beside it for the same
/// reason: the decision to copy somebody's library is not something to bury in scene setup. At most
/// once per launch, never on the main actor.
///
/// **It runs BEFORE the reclaim.** `hasVerifiedBackup` is the reclaim's "there is still a way back"
/// precondition, so with no backups it can never open — the same symptom `bd36d4a` fixed once for a
/// different reason. Taking the backup first lets both happen in one launch instead of the reclaim
/// waiting for the next one.
enum LibraryBackupLauncher {
    private static let queue = DispatchQueue(
        label: "ai.mechanician.library-backup", qos: .utility)
    private static let lock = NSLock()
    private static var hasRun = false

    /// Take today's backup if one is due, then hand on to the reclaim.
    ///
    /// The continuation is called whatever happens, including on a refusal: a backup that could not
    /// be taken must not also stop the reclaim from evaluating its own preconditions, which it is
    /// perfectly able to answer for itself.
    static func runAfterLaunch(then next: @escaping () -> Void = {}) {
        lock.lock()
        let alreadyRan = hasRun
        hasRun = true
        lock.unlock()
        guard !alreadyRan else { return next() }

        queue.async {
            defer { next() }
            let recognition = StorageAuthorityBootstrap.current
            guard case .sqlite = recognition.disposition,
                  LibraryAuthorityRepository.sharedIfActive != nil else { return }
            // Only the process holding the writer lease. `createBackupIfDue` serialises across
            // instances with its own advisory lock, so this is not what makes it safe — it is what
            // stops a second instance spending minutes of disk on work the first one is already
            // doing and will win.
            guard StorageAuthorityBootstrap.ownsProcessLease else { return }
            // Off means off. A person who turned backups off has decided; the reclaim behind this
            // still runs and still answers its own precondition, which with no backup is "no".
            guard LibraryBackupSettings.isEnabled() else { return }
            do {
                // Before the copy, not after: an unreachable retained-byte row makes
                // `createBackupIfDue` throw on every launch, so a repair that ran afterwards
                // would never be reached. Silent when there is nothing to release, which is
                // every launch on a healthy library.
                if let repository = LibraryAuthorityRepository.sharedIfActive,
                   let released = try? repository.releaseOrphanedRetainedByteSources(),
                   released > 0 {
                    NSLog(
                        "[storage] released %d retained-byte source(s) owned by deleted conversations",
                        released)
                }
                let result = try LibraryBackupLifecycle.createBackupIfDue(
                    sourceSupportRoot: recognition.effectiveSupportRoot)
                switch result.disposition {
                case .created:
                    NSLog(
                        "[storage] library backup created: %@",
                        result.generationURL.lastPathComponent)
                case .skippedRecentGeneration:
                    break
                }
                LibraryBackupSettings.recordFailure(nil)
            } catch {
                // NEVER SILENT — and the previous version of this comment said exactly that while
                // being exactly that. `NSLog` from a packaged, signed app did not reach the unified
                // log, so a backup that threw on every launch left no trace anywhere a person or I
                // could find: the folder still held an old generation and Settings still showed its
                // date. A log line is not a report. This writes where the panel can read it.
                NSLog("[storage] library backup skipped: %@", String(describing: error))
                LibraryBackupSettings.recordFailure(String(describing: error))
            }
        }
    }

    /// Take a backup now, whatever the cadence says.
    ///
    /// The one place the 24-hour rule is deliberately not consulted: a person who presses "Back up
    /// now" is telling the app something it cannot work out from a clock, usually that they are
    /// about to do something they might regret.
    static func backUpNow(completion: @escaping (Result<URL, Error>) -> Void) {
        queue.async {
            let recognition = StorageAuthorityBootstrap.current
            guard case .sqlite = recognition.disposition else {
                return DispatchQueue.main.async {
                    completion(.failure(LibraryBackupServiceError.invalidInput(
                        "the library is not open")))
                }
            }
            do {
                let result = try LibraryBackupLifecycle.createBackupIfDue(
                    sourceSupportRoot: recognition.effectiveSupportRoot, force: true)
                DispatchQueue.main.async { completion(.success(result.generationURL)) }
            } catch {
                DispatchQueue.main.async { completion(.failure(error)) }
            }
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
