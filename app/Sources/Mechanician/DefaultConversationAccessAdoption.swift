import Foundation

/// Whether an account that just became usable should become the route NEW conversations inherit.
///
/// `defaultConversationAccess` starts at `.anthropicAPI` and, before this rule, changed only when
/// the user picked a default in Settings. Connecting an account did not touch it. On a fresh install
/// that produced a loop with no exit: the first message is blocked because the default lane has no
/// credentials, connecting the provider you actually have resumes that ONE conversation, and the
/// next new conversation is blocked again on the same unconnected lane. The Providers window even
/// labels it DEFAULT while showing it as not connected.
///
/// The rule is deliberately narrow, because the default is a user preference and hijacking it would
/// be its own bug: adopt ONLY when the current default cannot be used. An available default is left
/// alone, so connecting a second provider never silently re-routes future conversations away from
/// the one you chose.
enum DefaultConversationAccessAdoption {
    static func shouldAdopt(
        connected: ModelAccess,
        currentDefault: ModelAccess,
        currentDefaultIsAvailable: Bool
    ) -> Bool {
        // Already the default: nothing to do.
        guard connected != currentDefault else { return false }
        // A usable default is a real choice, whether the user made it explicitly or inherited it.
        // Adopting over it would move future conversations off a working provider.
        guard !currentDefaultIsAvailable else { return false }
        return true
    }
}
