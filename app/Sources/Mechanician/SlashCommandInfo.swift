import Foundation

/// A skill / slash-command the SDK exposes for the current session. Codable so the last-known list
/// can be cached to disk and preloaded on the next launch (see AgentBridge), making the composer's
/// "/" autocomplete available before the first turn of a session.
///
/// This outlived the Skills window it used to live beside. Skills are inventory — the provider
/// supplies them, you do not add them — so they now appear in Extensions ▸ What it can do, with the
/// Insert and Run actions the window used to carry. The type stays because the composer's
/// autocomplete and the bridge's cache both depend on it, and always did.
struct SlashCommandInfo: Identifiable, Hashable, Codable {
    var id: String { invocation }
    let name: String
    let description: String
    let argumentHint: String
    /// Claude reports slash commands; Codex skills are invoked with `$name`. Optional keeps every
    /// pre-0.12.7 cache decodable and defaults those historical records to Claude's `/`.
    var invocationPrefix: String? = nil
    /// False when this lane demoted the skill to user-invocable-only: you can still run it, the
    /// agent cannot reach for it on its own. `claude-api` is demoted on every model whose context
    /// window is too small to hold its reference, which is every 200K lane.
    ///
    /// Optional for the same reason as `invocationPrefix`: an older cache decodes with no opinion,
    /// and no opinion means the ordinary case where the agent can use it.
    var agentInvocable: Bool? = nil

    var prefix: String { invocationPrefix == "$" ? "$" : "/" }
    var invocation: String { prefix + name }
    /// The agent can reach for this unless the lane said otherwise.
    var isAgentInvocable: Bool { agentInvocable ?? true }
}
