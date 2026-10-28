import Foundation

/// The one status a configured connection shows in the Extensions list, derived from the auth and
/// connection state the store already tracks. A row is in exactly one of these states and offers at
/// most one primary action; saved-login and lane detail belong to the inspector, not the row.
///
/// Pure on purpose: no store, no view, no clock. `ConnectionRowState.resolve` is a deterministic
/// function of its inputs, and `ConnectionRowGroup` is a deterministic sort on the result.
enum ConnectionRowState: Equatable {
    case ready(toolCount: Int?)
    case needsSignIn
    case signingIn(MCPAuthorizationProgressPhase)
    case problem(Problem)
    /// A probe is actually in flight.
    case checking
    /// The last probe came back indeterminate (or none has run). The status check re-reads the
    /// Keychain and does not connect, so this can persist; a real tool call is authoritative.
    case unverified
    case off

    enum Problem: Equatable {
        case invalidConfiguration
        case authenticationFailed(MCPAuthorizationFailure)
        case connectionFailed(String)
        case noTools
    }

    /// The single verb vocabulary: Sign in, Retry, Cancel. Editing a server that cannot start is a
    /// different act, so it is named separately rather than hidden behind Retry.
    enum PrimaryAction: Equatable {
        case signIn
        case retry
        case cancel
        case editServer
    }

    static func resolve(
        server: MCPServer,
        auth: MCPAuthState,
        connection: MCPConnState
    ) -> Self {
        guard server.enabled else { return .off }
        guard server.isValid else { return .problem(.invalidConfiguration) }

        // An attempt in flight outranks any older terminal state, matching `MCPAttentionResolver`.
        if let phase = MCPAuthorizationProgressPhase(auth) { return .signingIn(phase) }
        if case .failed(let failure) = auth { return .problem(.authenticationFailed(failure)) }

        switch connection {
        case .needsAuth:
            return .needsSignIn
        case .failed(let message):
            return .problem(.connectionFailed(message))
        case .connected(let count):
            // nil is "the SDK omitted its tools array", not "no tools".
            if count == 0 { return .problem(.noTools) }
            return .ready(toolCount: count)
        case .checking:
            return .checking
        case .unknown, .authenticated, .disabled:
            // A saved login whose tools are not verified here. `needsStatusRefresh` tells the
            // caller to go and find out, but the probe may stay indeterminate, so this must never
            // render as an endless spinner. It names itself and offers Retry instead.
            return .unverified
        }
    }

    /// True when the row is waiting on a status probe nobody has run, so the panel should start
    /// one instead of leaving the row in a silent gray state.
    static func needsStatusRefresh(connection: MCPConnState, auth: MCPAuthState) -> Bool {
        guard !auth.isInProgress else { return false }
        switch connection {
        case .unknown, .authenticated: return true
        case .checking, .connected, .needsAuth, .failed, .disabled: return false
        }
    }

    var primaryAction: PrimaryAction? {
        switch self {
        case .needsSignIn: .signIn
        case .signingIn(.preparing): nil // no owned attempt exists yet, so Cancel would be a lie
        case .signingIn: .cancel
        case .problem(.invalidConfiguration): .editServer
        case .problem, .unverified: .retry
        case .ready, .checking, .off: nil
        }
    }

    /// One short line for the row. Full text, never truncated by this layer; the inspector shows
    /// `detail` in full.
    var summary: String {
        switch self {
        case .ready(let count?):
            String(localized: "\(count) tools")
        case .ready(nil):
            String(localized: "Ready")
        case .needsSignIn:
            String(localized: "Sign in to use")
        case .signingIn(.preparing):
            String(localized: "Preparing sign-in…")
        case .signingIn(.authorizing):
            String(localized: "Starting sign-in…")
        case .signingIn(.waitingForBrowser):
            String(localized: "Finish in your browser")
        case .problem(.invalidConfiguration):
            String(localized: "Setup incomplete")
        case .problem(.authenticationFailed):
            String(localized: "Sign-in failed")
        case .problem(.connectionFailed):
            String(localized: "Can't connect")
        case .problem(.noTools):
            String(localized: "Connected, but offers no tools")
        case .checking:
            String(localized: "Checking…")
        case .unverified:
            String(localized: "Not checked yet")
        case .off:
            String(localized: "Off")
        }
    }

    /// The full reason behind a problem, for the inspector. Nil when the summary already says it all.
    var detail: String? {
        switch self {
        case .problem(.authenticationFailed(let failure)): failure.message
        case .problem(.connectionFailed(let message)): message
        default: nil
        }
    }

    /// Status spoken as one phrase: "Slack, problem: sign-in failed, Retry available".
    func accessibilitySummary(serverName: String) -> String {
        let status = summary
        let base = switch self {
        case .problem: String(localized: "\(serverName), problem: \(status)")
        default: String(localized: "\(serverName), \(status)")
        }
        guard let action = primaryAction else { return base }
        return String(localized: "\(base), \(action.label) available")
    }
}

extension ConnectionRowState.PrimaryAction {
    var label: String {
        switch self {
        case .signIn: String(localized: "Sign in")
        case .retry: String(localized: "Retry")
        case .cancel: String(localized: "Cancel")
        case .editServer: String(localized: "Edit server…")
        }
    }
}

/// The list sections, in display order. Membership is a deterministic function of state, so a row
/// never moves because something scored it differently, only because its state changed.
enum ConnectionRowGroup: Int, CaseIterable, Comparable {
    case needsAttention
    case ready
    case off

    init(_ state: ConnectionRowState) {
        switch state {
        case .needsSignIn, .problem, .signingIn: self = .needsAttention
        // Checking and unverified sit with Ready so a first paint does not put a row at the top
        // and then drop it.
        case .ready, .checking, .unverified: self = .ready
        case .off: self = .off
        }
    }

    static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }

    var title: String {
        switch self {
        case .needsAttention: String(localized: "Needs attention")
        case .ready: String(localized: "Ready")
        case .off: String(localized: "Off")
        }
    }
}
