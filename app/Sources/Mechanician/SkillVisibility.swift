import Foundation

/// Which of Claude Code's built-in slash commands are worth showing inside Mechanician.
///
/// The SDK reports a session-dependent command table — 41 built-ins in our 2.1.220 probe — and many
/// of them exist to drive a terminal UI this app does not have. `/color` sets the CLI's prompt-bar
/// colour. `/config` writes settings agentd explicitly refuses to load (`settingSources: []`).
/// `/fast` answers "Fast mode is not available in the Agent SDK". Listing those beside
/// `/code-review` implies they do something here.
///
/// **A reviewed list, not a heuristic.** `SlashCommand` carries only `name`, `description`,
/// `argumentHint` and `aliases` — there is no `isBuiltin` or `source` to rule on. Every candidate
/// rule was tried and failed: "no `plugin:` namespace" would hide all 27 keepers, since
/// `/code-review`, `/dataviz`, `/deep-research` and `/security-review` are built-ins too; "empty
/// argumentHint" would hide `/dataviz` and `/security-review`; descriptions do not reliably identify
/// terminal-only commands such as `/color`. So the names are enumerated, and anything unlisted stays
/// VISIBLE — a new Claude Code release adds commands rather than silently losing them.
///
/// Claude Code already does this itself: `/vim`, `/terminal-setup`, `/status`, `/theme`, `/login`
/// and friends are withheld from SDK clients upstream. This continues that filtering rather than
/// fighting it.
///
/// Hiding is a default, never a deletion: the panel offers "Show terminal commands", and typing `/`
/// in the composer still reaches every one of them.
enum SkillVisibility {
    static let denied: Set<String> = [
        // Internal — not meant for users at all.
        "workflow-launch-exec",   // server-launched workflow handoff; claude.ai sessions only
        "heapdump",               // dumps the SDK subprocess's JS heap to ~/Desktop

        // Terminal-only. Each of these was executed against the bundled binary and is a verified
        // no-op, an error, or a setting this app cannot see.
        "color",                  // "Session color set to: blue" — the CLI's prompt bar
        "config",                 // CLI TUI settings; agentd sets settingSources: []
        "clear",                  // resets SDK context while our transcript still shows it
        "fast",                   // "Fast mode is not available in the Agent SDK"
        "extra-usage",            // conditional rename stub: "/extra-usage is now /usage-credits"
        "doctor",                 // audits a CLI installation Mechanician bundles and owns
        "team-onboarding",        // a ramp-up guide for a product the user is not running

        // Duplicates a first-class Mechanician control. `model` and `effort` are worse than
        // redundant: streamOnce re-imposes the picker's values on every turn, so the command
        // reports success and silently reverts.
        "model",                  // ModelPickerView
        "effort",                 // ConversationEffortControl
        "mcp",                    // the Extensions window (⌘⌥E)
        "agents",                 // the Agents inspector tab — and upstream removed the wizard
        "rename",                 // renames a CLI session title we never render
        "usage-credits",          // conditional account flow; app links claude.ai/settings/usage
    ]

    /// The one sound RULE. `__` is the SDK's own internal marker, so it catches `/__remote-workflow`
    /// and anything future-internal without us having to notice it.
    ///
    /// The namespace is stripped before matching so a plugin shipping its own `/config` is judged on
    /// its own name, and so a future SDK that namespaces built-ins cannot silently unhide the list.
    static func isTerminalOnly(_ name: String) -> Bool {
        let bare = name.contains(":")
            ? String(name[name.index(after: name.firstIndex(of: ":")!)...])
            : name
        return bare.hasPrefix("__") || denied.contains(bare)
    }
}
