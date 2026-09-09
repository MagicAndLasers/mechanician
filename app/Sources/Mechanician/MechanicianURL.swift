import AppKit
import Foundation

/// The `mechanician://` link grammar, in both directions.
///
/// Host is the noun, path is the durable identifier. `conversation` and `workspace` are the two
/// doctrinal nouns; `artifact` is not a third one, it is the same leaf Spotlight and
/// `OpenArtifactIntent` already address. `project` is refused as a host even though the code still
/// says `projectID`, because "Project" is retired user-facing vocabulary and a URL is user-facing.
///
/// | Link | Meaning |
/// | --- | --- |
/// | `mechanician://conversation/<uuid>` | Open that conversation, focusing its owning window |
/// | `mechanician://workspace/<uuid>` | Focus or open that workspace's window |
/// | `mechanician://workspace/home` | Home, the default workspace |
/// | `mechanician://artifact/<uuid>` | Open the Artifacts window and select it |
/// | `mechanician://conversation/new?text=…` | Start a conversation with that text in the composer |
/// | `mechanician://conversation/<uuid>?text=…` | Open it and add that text to its composer |
///
/// **Every verb is OPEN, FOCUS, SELECT, or PREFILL. None of them is SEND.** Any web page the user
/// merely visits can fire a `mechanician://` link, so the grammar carries no working directory, no
/// permission mode, and no way to start a turn. That guarantee is structural rather than a rule to
/// remember: this parser never constructs `MechanicianRoute.newConversation`, the one case that can
/// submit to a provider. The prefill routes it does construct are incapable of submitting.
///
/// **`text` is the only query key, and only on `conversation`.** Any other key, more than one key,
/// or a query on any other noun rejects the whole link. Prefill was the one thing here with a real
/// remote-attack story — a page opens a link whose text reads like something you asked for, and you
/// hit Send reflexively — and David chose to ship it (decision 2, 2026-08-01) against my
/// recommendation to close it. The residual risk is exactly that reflex; what the app can do about
/// it, it does: the text is capped, scrubbed of forged attachment tokens, arrives unsent and
/// visible, and appends on its own line rather than merging into what you were writing.
///
/// Rejection is silent and total. There is no partial application (a malformed link does nothing
/// rather than opening the workspace and skipping the conversation) and no alert, because an alert
/// would let a page spam the user with modal dialogs it did not have to earn.
enum MechanicianURL {
    /// The one path component that is a word rather than a UUID. Home has no stored id — it is the
    /// absence of a project — so it needs a spelling, and this is the only one.
    static let homePathComponent = "home"

    /// The other word: `conversation/new`, which exists **only** to carry `?text=`. Without a
    /// prefill it is refused, because a link has no business minting an empty conversation.
    static let newPathComponent = "new"

    /// Parse a link into a route, or `nil` if it is not one of ours or not well formed.
    ///
    /// `scheme` is passed in rather than read from the bundle so the grammar is testable without a
    /// bundle identity, and so a Dev build cannot accidentally answer a public link.
    static func route(for url: URL, scheme: String) -> MechanicianRoute? {
        guard let parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        // Scheme and host are case-insensitive per RFC 3986; `UUID(uuidString:)` already accepts
        // either case, so folding the whole link is both consistent and what a person retyping one
        // out of a note would expect.
        guard parts.scheme?.lowercased() == scheme.lowercased() else { return nil }
        // Nothing the authority component can carry beyond the noun. A link is a noun, an
        // identifier, and at most the one query key below.
        guard parts.fragment == nil,
              parts.user == nil, parts.password == nil, parts.port == nil else { return nil }
        guard let host = parts.host?.lowercased(), !host.isEmpty else { return nil }
        // Exactly one component: `conversation/<uuid>/messages` is not a shorter link to something
        // real, it is a link this version does not understand.
        let path = parts.path.split(separator: "/").map { $0.lowercased() }
        guard path.count == 1 else { return nil }
        let identifier = path[0]

        // `text` is the only query key in the grammar, and only on `conversation`. Every other key,
        // and any query at all on the other nouns, still rejects the whole link: silently ignoring
        // an unknown key is how the *next* parameter arrives unnoticed. Absent is not the same as
        // empty — `?text=` with nothing in it is a malformed caller, not a bare open.
        var prefill: String?
        if let items = parts.queryItems {
            guard host == "conversation",
                  items.count == 1, items[0].name == "text",
                  let raw = items[0].value,
                  let text = InboundComposerText.sanitized(raw) else { return nil }
            prefill = text
        } else if parts.query != nil {
            return nil   // a query string that parses to no items at all
        }

        switch host {
        case "conversation":
            // `new` exists only to carry text. A link has no business minting an empty conversation,
            // so without a prefill it stays as unknown as it was before this key existed.
            if identifier == newPathComponent {
                return prefill.map(MechanicianRoute.newConversationDraft)
            }
            guard let id = UUID(uuidString: identifier) else { return nil }
            if let prefill { return .appendToComposer(prefill, conversationID: id) }
            return .conversation(id)
        case "artifact":
            return UUID(uuidString: identifier).map(MechanicianRoute.artifact)
        case "workspace":
            if identifier == homePathComponent { return .workspace(nil) }
            return UUID(uuidString: identifier).map(MechanicianRoute.workspace)
        default:
            return nil
        }
    }

    /// The link for a route, or `nil` for a route no link can express.
    ///
    /// The composer and file routes are deliberately unaddressable. None of them names something
    /// durable that already exists, which is the whole basis of the grammar: a link points at a
    /// thing, it does not ask for one to be made or carry a payload into it.
    static func link(for route: MechanicianRoute, scheme: String) -> URL? {
        var parts = URLComponents()
        parts.scheme = scheme
        switch route {
        case .conversation(let id):
            parts.host = "conversation"
            parts.path = "/\(id.uuidString)"
        case .artifact(let id):
            parts.host = "artifact"
            parts.path = "/\(id.uuidString)"
        case .workspace(let id):
            parts.host = "workspace"
            parts.path = "/\(id?.uuidString ?? homePathComponent)"
        case .newConversation, .newConversationDraft, .newStandardConversationDraft,
             .appendToComposer, .files:
            return nil
        }
        return parts.url
    }
}

// MARK: - Copy Link

extension MechanicianURL {
    /// Put a route's link on the pasteboard, in both the URL and plain-text flavors: the URL flavor
    /// so it can be dropped on Safari or a Finder window, the string flavor so it survives a paste
    /// into a note or a chat message, which is where these actually get kept.
    ///
    /// Returns whether anything was written, so a caller can stay quiet rather than clearing the
    /// pasteboard for a route with no link.
    @MainActor @discardableResult
    static func copyLink(to route: MechanicianRoute,
                         scheme: String = MechanicianEnvironment.currentURLScheme,
                         pasteboard: NSPasteboard = .general) -> Bool {
        guard let url = link(for: route, scheme: scheme) else { return false }
        pasteboard.clearContents()
        pasteboard.setString(url.absoluteString, forType: .URL)
        pasteboard.setString(url.absoluteString, forType: .string)
        return true
    }
}

// MARK: - Arrival policy

/// One route per second.
///
/// Every destination in the grammar opens or focuses a window, and a page the user is merely
/// visiting can fire links in a loop. Without this, a hundred hidden iframes are a hundred windows.
struct URLRouteRateLimiter {
    private let interval: TimeInterval
    private var lastAccepted: Date?

    init(interval: TimeInterval = 1.0) { self.interval = interval }

    /// Whether to act on a link arriving at `now`. A clock that has gone backwards reads as "too
    /// soon" rather than "long enough ago", which is the safe way round.
    mutating func allows(at now: Date) -> Bool {
        if let last = lastAccepted, now.timeIntervalSince(last) < interval { return false }
        lastAccepted = now
        return true
    }
}

/// Holds links that arrive before launch restore has run.
///
/// `application(_:open:)` can fire before the async block that runs `migrateIfNeeded()` and
/// `openLastLocationOrHome()`. Restore has to run first and unchanged: a link must never be the
/// reason your last workspace failed to come back — that is the state-loss invariant, and a deep
/// link is not worth spending it. Because every destination is focus-or-create, a link naming the
/// workspace restore just opened produces no second window when this drains.
struct LaunchLinkQueue {
    private(set) var isRestored = false
    private var parked: [MechanicianRoute] = []

    /// The route to act on now, or `nil` when it has been parked until restore finishes.
    mutating func accept(_ route: MechanicianRoute) -> MechanicianRoute? {
        if isRestored { return route }
        parked.append(route)
        return nil
    }

    /// Launch restore has finished: everything parked, in arrival order, exactly once.
    mutating func restored() -> [MechanicianRoute] {
        isRestored = true
        defer { parked = [] }
        return parked
    }
}
