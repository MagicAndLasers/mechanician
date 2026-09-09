import Foundation

/// What a scheduled task will and will not be able to do, worked out BEFORE it ever runs.
///
/// An unattended run is judged by rules the app knows and the user cannot see: some tools are
/// withheld entirely because nothing can answer them, writes and shell need "Trust all", and each
/// lane needs its own credential. Left implicit, those rules produce a task that looks correct,
/// runs on schedule, and quietly does nothing useful — the failure the user has no way to foresee.
///
/// So the rules are stated up front, against this task's actual prompt and settings.
enum TaskReadiness {
    enum Severity: Comparable {
        case info      // worth knowing
        case warning   // will probably not do what was asked
        case blocking  // cannot run at all
    }

    struct Finding: Identifiable, Equatable {
        var id: String { title }
        var severity: Severity
        var title: String
        var detail: String
    }

    /// Capabilities no scheduled task can have, whatever its permission mode, because they need a
    /// person or a foreground Mac session. Mirrors `UNATTENDED_WITHHELD_TOOLS` in runtime-policy.mjs.
    static let neverAvailable = [
        "asking you a question", "waiting for something to happen",
        "Shortcuts", "AppleScript", "saved capabilities", "screenshots or clicking",
    ]

    /// Words in a prompt that imply the task intends to change something. Deliberately generous:
    /// a false warning costs a sentence, a missed one costs a task that silently does nothing.
    private static let mutatingIntent = [
        "write", "create", "edit", "modify", "update", "change", "delete", "remove",
        "commit", "push", "install", "run ", "execute", "build", "fix", "rename", "move",
    ]
    private static let interactiveIntent = [
        "ask me", "ask you", "confirm with", "wait for", "wait until", "screenshot",
        "click", "shortcut", "applescript",
    ]

    /// - Parameters:
    ///   - credentialReady: whether this task's lane is connected.
    ///   - workspaceResolved: whether the task has a workspace whose folder exists.
    static func evaluate(
        task: ScheduledTask,
        credentialReady: Bool,
        workspaceResolved: Bool
    ) -> [Finding] {
        var findings: [Finding] = []
        let lane = task.resolvedAccess
        let trusted = task.permissionMode == "bypassPermissions"
        let prompt = task.prompt.lowercased()

        if !credentialReady {
            findings.append(Finding(
                severity: .blocking,
                title: "\(lane.displayName) isn't connected",
                detail: "This task can't run until that provider has a key in Providers. "
                    + "Other tasks are unaffected."))
        }
        if ReservedWorkspace.owns(task.workspaceID) {
            findings.append(Finding(
                severity: .blocking,
                title: "Choose a regular workspace",
                detail: "This reserved product workspace is interactive. Reassign this task to a "
                    + "regular workspace before it can run."))
        } else if !workspaceResolved {
            findings.append(Finding(
                severity: .blocking,
                title: "No workspace folder",
                detail: "Pick a workspace so the agent knows where to work."))
        }
        if task.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            findings.append(Finding(
                severity: .blocking,
                title: "Nothing to do",
                detail: "Add instructions describing what the agent should do."))
        }

        // The case that actually bites: a task written as if someone were watching.
        if let hit = interactiveIntent.first(where: { prompt.contains($0) }) {
            findings.append(Finding(
                severity: .warning,
                title: "Asks for something a scheduled run can't do",
                detail: "The instructions mention “\(hit.trimmingCharacters(in: .whitespaces))”. "
                    + "A scheduled run has nobody to answer and no foreground session, so "
                    + "\(neverAvailable.joined(separator: ", ")) are unavailable, whatever the "
                    + "access setting. Rewrite it to finish on its own."))
        }
        if !trusted, let hit = mutatingIntent.first(where: { prompt.contains($0) }) {
            findings.append(Finding(
                severity: .warning,
                title: "Looks like it needs to change something",
                detail: "The instructions mention “\(hit.trimmingCharacters(in: .whitespaces))”, but "
                    + "read-only access can't edit files or run commands. It can only read the "
                    + "workspace and create artifacts. Switch to Trust all if that's intended."))
        }
        findings.append(Finding(
            severity: .info,
            title: trusted ? "Full access" : "Read-only access",
            detail: trusted
                ? "Can edit files and run commands unattended. Interactive tools stay unavailable."
                : "Can read the workspace and create artifacts. No file edits, no shell commands."))
        return findings.sorted { $0.severity > $1.severity }
    }

    /// The worst thing found, for a one-glance badge on a task row.
    static func worst(_ findings: [Finding]) -> Severity? {
        findings.map(\.severity).max()
    }

    /// True when nothing blocks the task from running at all.
    static func canRun(_ findings: [Finding]) -> Bool {
        !findings.contains { $0.severity == .blocking }
    }
}
