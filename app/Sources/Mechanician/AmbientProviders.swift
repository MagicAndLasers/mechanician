import Foundation

/// Which provider lanes may run a scheduled task, and why the others may not.
///
/// This is a POLICY boundary, not a capability one, and the distinction cost real investigation —
/// so it is recorded here rather than left implicit in a credential check.
///
/// Anthropic's Consumer Terms §3 prohibit accessing the service "through automated or non-human
/// means, whether through a bot, script, or otherwise", *except* via an API key "or where we
/// otherwise explicitly permit it". Anthropic satisfies that carve-out with their own first-party
/// scheduler (Routines, on Pro/Max/Team/Enterprise, running on Anthropic-managed infrastructure) —
/// not by third-party apps driving the local CLI against a user's OAuth token on a timer. The
/// Claude Code headless documentation points the same way: bare mode "skips OAuth and keychain
/// reads", requires `ANTHROPIC_API_KEY` or an `apiKeyHelper`, and is stated to become the default
/// for `-p`, so subscription-OAuth scripted runs would eventually break on mechanics alone.
///
/// The same reasoning applies to a ChatGPT/Codex subscription. So unattended work runs only on
/// METERED credentials the user owns — which is exactly the shape the terms' exception describes.
///
/// Subscription lanes are still LISTED in the picker, deliberately. Silently omitting them reads as
/// a missing feature and invites exactly the "why can't I schedule this?" confusion this type
/// exists to answer.
enum AmbientLanePolicy {
    /// Lanes a scheduled task may run on, in the order the picker shows them.
    static let schedulable: [ModelAccess] = [.anthropicAPI, .claudeVertex, .openAIAPI]

    static var selectableSchedulable: [ModelAccess] {
        selectableSchedulable(
            directAccess: AmbientDaemon.accountAccess,
            managedPolicy: ManagedEnterprisePolicy.current)
    }

    /// ambientd has one process-wide Claude credential route. OpenAI uses its isolated agentd
    /// child, but an Anthropic API task cannot run in a Vertex scheduler (or vice versa) without
    /// making the task's displayed provider disagree with the provider used on the wire.
    static func isAvailableToScheduler(
        _ access: ModelAccess,
        directAccess: ModelAccess
    ) -> Bool {
        switch access {
        case .anthropicAPI, .claudeVertex:
            return access == directAccess
        default:
            return true
        }
    }

    static func selectableSchedulable(
        directAccess: ModelAccess,
        managedPolicy: ManagedEnterprisePolicy?
    ) -> [ModelAccess] {
        guard managedPolicy?.allowsUnattendedWork() ?? true else { return [] }
        return schedulable.filter {
            (managedPolicy?.allows($0) ?? true)
                && isAvailableToScheduler($0, directAccess: directAccess)
        }
    }

    static func isSchedulable(_ access: ModelAccess) -> Bool { schedulable.contains(access) }

    /// Why this lane cannot run unattended, phrased for the user. `nil` when it can.
    static func unavailableReason(_ access: ModelAccess) -> String? {
        guard !isSchedulable(access) else { return nil }
        switch access {
        case .claudeSubscription:
            return "Anthropic's terms don't allow subscription access to run unattended. "
                + "Use an Anthropic API key here, or Anthropic's own Routines feature."
        case .codexSubscription:
            return "A ChatGPT subscription can't run unattended tasks. Use an OpenAI API key here."
        default:
            return "This provider can't run unattended tasks."
        }
    }

    /// Every lane the picker shows — schedulable ones first, then the rest as explained-unavailable.
    static func pickerLanes(includingUnavailable extras: [ModelAccess]) -> [ModelAccess] {
        let allowed = extras.filter(\.isAllowedByEnterprisePolicy)
        return selectableSchedulable + allowed.filter { !isSchedulable($0) }
    }
}

extension ScheduledTask {
    /// The lane this task runs on. Absent or invalid legacy state inherits this scheduler's one
    /// direct Claude route, keeping old public tasks on Anthropic API and managed tasks on Vertex.
    var resolvedAccess: ModelAccess {
        resolvedAccess(directAccess: AmbientDaemon.accountAccess)
    }

    func resolvedAccess(directAccess: ModelAccess) -> ModelAccess {
        access.flatMap(ModelAccess.init(rawValue:)).map {
            AmbientLanePolicy.isSchedulable($0) ? $0 : directAccess
        } ?? directAccess
    }
}
