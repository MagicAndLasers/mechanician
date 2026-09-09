import Foundation

/// Collapses nearby Git invalidations into one status request. This is deliberately event-driven:
/// edits, turn terminals, and window focus schedule one delayed read, while no timer remains active
/// after that read fires. Keeping the debounce outside SwiftUI also lets the Changes badge stay
/// current while its inspector tab is closed.
final class GitRefreshScheduler {
    private let delay: DispatchTimeInterval
    private var workItem: DispatchWorkItem?
    private var pendingAction: (() -> Void)?
    private var generation = 0

    init(delay: DispatchTimeInterval = .milliseconds(180)) {
        self.delay = delay
    }

    var hasPendingRefresh: Bool { pendingAction != nil }

    func schedule(_ action: @escaping () -> Void) {
        pendingAction = action
        workItem?.cancel()
        generation &+= 1
        let scheduledGeneration = generation
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.generation == scheduledGeneration else { return }
            self.flush()
        }
        workItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    /// Run the most recent request once. Internal so focused tests can exercise coalescing without
    /// depending on wall-clock timing; production reaches this through the one-shot work item.
    func flush() {
        workItem = nil
        let action = pendingAction
        pendingAction = nil
        action?()
    }

    func cancel() {
        generation &+= 1
        workItem?.cancel()
        workItem = nil
        pendingAction = nil
    }

    static func shouldRefreshAfterSuccessfulTool(
        name: String,
        toolWorkspace: String,
        visibleWorkspace: String
    ) -> Bool {
        guard ["Edit", "Write", "MultiEdit", "NotebookEdit"].contains(name),
              !visibleWorkspace.isEmpty else { return false }
        return standardized(toolWorkspace) == standardized(visibleWorkspace)
    }

    static func workspacesMatch(_ lhs: String, _ rhs: String) -> Bool {
        guard !lhs.isEmpty, !rhs.isEmpty else { return false }
        return standardized(lhs) == standardized(rhs)
    }

    /// A background/visible-panel tick must not continuously supersede a slow status request.
    /// Explicit user refresh remains an escape hatch for a request that appears stuck.
    static func shouldBeginRefresh(silently: Bool, statusRequestInFlight: Bool) -> Bool {
        !silently || !statusRequestInFlight
    }

    /// Silent refresh keeps a trustworthy snapshot on screen while its replacement is fetched.
    /// A first load and an explicit refresh still expose the checking state.
    static func shouldReplaceVisibleSnapshot(silently: Bool, hasCurrentSnapshot: Bool) -> Bool {
        !silently || !hasCurrentSnapshot
    }

    private static func standardized(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.path
    }
}
