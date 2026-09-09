import Foundation

/// The one production caller of the post-soak reclaim.
///
/// Kept apart from `MechanicianApp` so the decision to release somebody's pre-migration copy is not
/// buried in scene setup, and so it can be reasoned about on its own: it runs at most once per
/// launch and never on the main actor.
///
/// A completed reclaim is recorded as a receipt and announced, so an open window can show the note
/// in the same session rather than leaving the person to find gigabytes in their Trash and wait
/// until the next launch for the explanation.
enum StorageRollbackReclaimLauncher {
    private static let queue = DispatchQueue(
        label: "ai.mechanician.storage-reclaim", qos: .utility)
    private static let lock = NSLock()
    private static var hasRun = false

    static func runAfterLaunch() {
        lock.lock()
        let alreadyRan = hasRun
        hasRun = true
        lock.unlock()
        guard !alreadyRan else { return }

        queue.async {
            let recognition = StorageAuthorityBootstrap.current
            guard case .sqlite = recognition.disposition,
                  let repository = LibraryAuthorityRepository.sharedIfActive else { return }
            let outcome = StorageRollbackReclaimCoordinator.runIfDue(
                supportRoot: recognition.effectiveSupportRoot,
                recognition: recognition,
                repository: repository)
            guard let report = outcome.report, !report.isEmpty else { return }
            NSLog(
                "[storage] released %@ from the previous library: %@",
                ByteCountFormatter.string(fromByteCount: report.releasedBytes, countStyle: .file),
                report.releasedNames.joined(separator: ", "))
            DispatchQueue.main.async {
                NotificationCenter.default.post(
                    name: StorageRollbackReclaimNotice.didReclaim, object: nil)
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
