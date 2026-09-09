import Foundation

/// Pure presentation reduction for the route-bound abilities reader.
///
/// `AgentBridge` owns route admission. This reducer owns only what the user may see while that
/// exact route is absent, changing, being discovered, or ready. In particular, opening wins over
/// an old ready snapshot so selecting another Conversation cannot leave the prior route painted
/// while the destination hydrates.
struct AgentAbilityPresentation: Equatable {
    struct Input: Equatable {
        let hasConversation: Bool
        let isOpeningConversation: Bool
        let needsProviderSetup: Bool
        let providerDisplayName: String
        let snapshot: AgentToolSurfaceSnapshot?
    }

    enum State: Equatable {
        case noConversation
        case openingConversation
        case setupRequired(providerDisplayName: String)
        case discovering(providerDisplayName: String)
        case readyEmpty(AgentToolSurfaceSnapshot)
        case ready(AgentToolSurfaceSnapshot)
        case unavailable(message: String)
        case unverified
    }

    let state: State

    static func reduce(_ input: Input) -> Self {
        // During A → B hydration, `hasConversation` and `snapshot` can still describe A. The
        // pending destination is the newer user intent and must retire that presentation at once.
        if input.isOpeningConversation {
            return Self(state: .openingConversation)
        }
        guard input.hasConversation else {
            return Self(state: .noConversation)
        }
        if input.needsProviderSetup {
            return Self(state: .setupRequired(
                providerDisplayName: input.providerDisplayName))
        }
        guard let snapshot = input.snapshot else {
            return Self(state: .unverified)
        }
        switch snapshot.phase {
        case .discovering:
            return Self(state: .discovering(
                providerDisplayName: input.providerDisplayName))
        case .ready:
            return Self(state: snapshot.rawToolNames.isEmpty
                ? .readyEmpty(snapshot)
                : .ready(snapshot))
        case .failed(let message):
            return Self(state: .unavailable(message: message))
        }
    }

    /// Route/profile headers are meaningful only after one concrete Conversation has resolved.
    /// Hiding them while opening also prevents an A → B switch from labelling A as B's route.
    var showsResolvedRoute: Bool {
        switch state {
        case .noConversation, .openingConversation:
            false
        case .setupRequired, .discovering, .readyEmpty, .ready, .unavailable, .unverified:
            true
        }
    }

    /// Only an admitted ready state may drive secondary inventory such as saved capabilities.
    var readySnapshot: AgentToolSurfaceSnapshot? {
        switch state {
        case .readyEmpty(let snapshot), .ready(let snapshot): snapshot
        case .noConversation, .openingConversation, .setupRequired, .discovering,
             .unavailable, .unverified: nil
        }
    }

    /// A reported execution tool is still not runnable from the exact accepted Plan turn. This is
    /// presentation only; the daemon remains the authorization authority for every later call.
    static func canRequestSavedCapabilityRun(
        reportedRun: Bool,
        from snapshot: AgentToolSurfaceSnapshot
    ) -> Bool {
        snapshot.route.toolProfile == .standard
            && snapshot.route.permissionMode != "plan"
            && reportedRun
    }

    static func permissionModeTitle(for snapshot: AgentToolSurfaceSnapshot) -> String {
        PermissionPresentation.option(
            mode: snapshot.route.permissionMode,
            access: snapshot.route.selection.access).title
    }
}
