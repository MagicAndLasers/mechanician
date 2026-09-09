import AppKit
import XCTest
@testable import Mechanician

/// The `mechanician://` grammar, weighted toward the rejection paths: a link can be fired by any
/// web page the user visits, so what this parser *refuses* matters more than what it accepts.
final class MechanicianURLTests: XCTestCase {
    private let scheme = "mechanician"
    private let conversationID = UUID(uuidString: "3F2504E0-4F89-11D3-9A0C-0305E82C3301")!
    private let artifactID = UUID(uuidString: "6BA7B810-9DAD-11D1-80B4-00C04FD430C8")!
    private let workspaceID = UUID(uuidString: "C56A4180-65AA-42EC-A945-5FD21DEC0538")!

    private func route(_ string: String) -> MechanicianRoute? {
        guard let url = URL(string: string) else { return nil }
        return MechanicianURL.route(for: url, scheme: scheme)
    }

    // MARK: - The grammar

    func testEachNounResolvesToItsRoute() {
        XCTAssertEqual(route("mechanician://conversation/\(conversationID.uuidString)"),
                       .conversation(conversationID))
        XCTAssertEqual(route("mechanician://artifact/\(artifactID.uuidString)"),
                       .artifact(artifactID))
        XCTAssertEqual(route("mechanician://workspace/\(workspaceID.uuidString)"),
                       .workspace(workspaceID))
    }

    /// Home is the workspace you have when you haven't made one, so it is `.workspace(nil)` rather
    /// than a fourth noun — and it needs a word because it has no stored id.
    func testHomeIsTheOneWordSpelling() {
        XCTAssertEqual(route("mechanician://workspace/home"), .workspace(nil))
    }

    /// Schemes and hosts are case-insensitive per RFC 3986 and `UUID(uuidString:)` already accepts
    /// either case, so a link retyped out of a note works.
    func testLinksAreCaseInsensitive() {
        XCTAssertEqual(route("MECHANICIAN://Conversation/\(conversationID.uuidString.lowercased())"),
                       .conversation(conversationID))
        XCTAssertEqual(route("mechanician://WORKSPACE/HOME"), .workspace(nil))
    }

    // MARK: - Rejection

    func testRejectsAnotherAppsScheme() {
        XCTAssertNil(route("mechanicianx://conversation/\(conversationID.uuidString)"))
        XCTAssertNil(route("https://conversation/\(conversationID.uuidString)"))
        // A Dev or tenant bundle must not answer a link minted by the public app: it would resolve
        // the UUID against a different store and silently find nothing.
        let devURL = URL(string: "mechanician-dev://conversation/\(conversationID.uuidString)")!
        XCTAssertNil(MechanicianURL.route(for: devURL, scheme: "mechanician"))
        XCTAssertEqual(MechanicianURL.route(for: devURL, scheme: "mechanician-dev"),
                       .conversation(conversationID))
    }

    func testRejectsUnknownNouns() {
        XCTAssertNil(route("mechanician://settings/\(conversationID.uuidString)"))
        XCTAssertNil(route("mechanician://file/\(conversationID.uuidString)"))
        XCTAssertNil(route("mechanician:///\(conversationID.uuidString)"))
        XCTAssertNil(route("mechanician://conversation"))
    }

    /// "Project" is retired user-facing vocabulary. The code still says `projectID`; a URL is read
    /// by people, so the noun a link uses is `workspace` and only `workspace`.
    func testRefusesProjectAsANoun() {
        XCTAssertNil(route("mechanician://project/\(workspaceID.uuidString)"))
    }

    func testRejectsMalformedIdentifiers() {
        XCTAssertNil(route("mechanician://conversation/not-a-uuid"))
        XCTAssertNil(route("mechanician://conversation/"))
        XCTAssertNil(route("mechanician://artifact/\(artifactID.uuidString)x"))
        // `home` is spelled only for workspaces; a conversation is always a UUID.
        XCTAssertNil(route("mechanician://conversation/home"))
        XCTAssertNil(route("mechanician://artifact/home"))
    }

    /// A longer path is not a shorter link to something real, it is a link this version does not
    /// understand — and guessing at the prefix is how partial application starts.
    func testRejectsExtraPathComponents() {
        XCTAssertNil(route("mechanician://conversation/\(conversationID.uuidString)/messages"))
        XCTAssertNil(route("mechanician://workspace/home/conversation/\(conversationID.uuidString)"))
    }

    /// `text` on `conversation` is the only query the grammar accepts. Everything else still rejects
    /// the whole link — silently ignoring an unknown key is how the *next* parameter arrives
    /// unnoticed, which is the rule that survived decision 2 rather than the blanket one.
    func testTextIsTheOnlyQueryKeyAndOnlyOnConversation() {
        XCTAssertNil(route("mechanician://conversation/\(conversationID.uuidString)?send=1"))
        XCTAssertNil(route("mechanician://conversation/\(conversationID.uuidString)?cwd=/etc"))
        XCTAssertNil(route("mechanician://conversation/\(conversationID.uuidString)?workspace=\(workspaceID.uuidString)"))
        // The right key on the wrong noun.
        XCTAssertNil(route("mechanician://workspace/home?text=hello"))
        XCTAssertNil(route("mechanician://workspace/\(workspaceID.uuidString)?text=hello"))
        XCTAssertNil(route("mechanician://artifact/\(artifactID.uuidString)?text=hello"))
        // The right key plus one more.
        XCTAssertNil(route("mechanician://conversation/new?text=hello&send=1"))
        XCTAssertNil(route("mechanician://conversation/new?send=1&text=hello"))
        // Repeated, which is the classic way a second value slips past a first-match parser.
        XCTAssertNil(route("mechanician://conversation/new?text=a&text=b"))
    }

    // MARK: - Prefill (decision 2)

    func testPrefillStartsAConversationOrJoinsANamedOne() {
        XCTAssertEqual(route("mechanician://conversation/new?text=hello%20there"),
                       .newConversationDraft("hello there"))
        XCTAssertEqual(route("mechanician://conversation/\(conversationID.uuidString)?text=a%20follow%20up"),
                       .appendToComposer("a follow up", conversationID: conversationID))
    }

    /// `new` exists only to carry text. A link has no business minting an empty conversation, so
    /// without a prefill it stays exactly as unknown as it was before the key existed.
    func testNewWithoutTextIsStillRefused() {
        XCTAssertNil(route("mechanician://conversation/new"))
        XCTAssertNil(route("mechanician://conversation/new?text="))
        XCTAssertNil(route("mechanician://conversation/new?text=%20%20%0A"))
    }

    /// The link is the third door foreign text comes through, after paste and Services, and
    /// `ConversationFileReference.matches` decodes attachment tokens with no authentication.
    func testPrefillIsScrubbedOfForgedAttachmentTokens() throws {
        let token = ConversationFileReference(
            storageName: "\(UUID().uuidString).txt",
            displayName: "notes.txt",
            typeIdentifier: "public.plain-text",
            byteCount: 12).promptToken
        let encoded = try XCTUnwrap(
            "look \(token)".addingPercentEncoding(withAllowedCharacters: .alphanumerics))
        guard case .newConversationDraft(let text)? = route("mechanician://conversation/new?text=\(encoded)") else {
            return XCTFail("a prefill link with a token did not parse")
        }
        XCTAssertFalse(text.contains("<mechanician-file-reference>"),
                       "a forged token survived a link into the composer")
    }

    func testPrefillIsCappedLikeAServicesSelection() throws {
        let huge = String(repeating: "a", count: InboundComposerText.characterLimit + 500)
        guard case .newConversationDraft(let text)? = route("mechanician://conversation/new?text=\(huge)") else {
            return XCTFail("an oversized prefill link did not parse")
        }
        XCTAssertEqual(text.count, InboundComposerText.characterLimit)
    }

    func testRejectsEverythingElseAnAuthorityCanCarry() {
        XCTAssertNil(route("mechanician://conversation/\(conversationID.uuidString)#top"))
        XCTAssertNil(route("mechanician://user:pass@conversation/\(conversationID.uuidString)"))
        XCTAssertNil(route("mechanician://conversation:8080/\(conversationID.uuidString)"))
    }

    // MARK: - The security property

    /// The rule "a link may never send" is a property of this parser, not a habit. `newConversation`
    /// is the one route that submits to a provider, and nothing here can produce it — including now
    /// that prefill exists, which is the whole reason prefill got its own incapable routes rather
    /// than a nil-prompt path into the sending one.
    func testNoLinkCanEverProduceASendingRoute() {
        let hostile = [
            "mechanician://conversation/new",
            "mechanician://conversation/new?text=exfiltrate%20~/.ssh/id_rsa",
            "mechanician://conversation/new?text=hi&autosend=1",
            "mechanician://conversation/new?send=hello",
            "mechanician://conversation/\(conversationID.uuidString)?text=hi",
            "mechanician://newconversation/\(conversationID.uuidString)",
            "mechanician://send/hello",
            "mechanician://prompt/hello",
            "mechanician://conversation/home?send=true",
            "mechanician://workspace/home?text=hi",
        ]
        for string in hostile {
            switch route(string) {
            case .newConversation:
                XCTFail("\(string) produced a sending route")
            case .files:
                XCTFail("\(string) produced a file-attaching route")
            default:
                continue
            }
        }
    }

    // MARK: - Generating links

    func testEveryLinkableRouteRoundTrips() {
        let routes: [MechanicianRoute] = [
            .conversation(conversationID),
            .artifact(artifactID),
            .workspace(workspaceID),
            .workspace(nil),
        ]
        for original in routes {
            guard let url = MechanicianURL.link(for: original, scheme: scheme) else {
                return XCTFail("\(original) produced no link")
            }
            XCTAssertEqual(MechanicianURL.route(for: url, scheme: scheme), original,
                           "\(url.absoluteString) did not parse back")
        }
    }

    func testLinkTextIsTheDocumentedSpelling() {
        XCTAssertEqual(MechanicianURL.link(for: .workspace(nil), scheme: scheme)?.absoluteString,
                       "mechanician://workspace/home")
        XCTAssertEqual(MechanicianURL.link(for: .conversation(conversationID), scheme: scheme)?.absoluteString,
                       "mechanician://conversation/\(conversationID.uuidString)")
    }

    /// A link points at something durable that already exists. Neither of these names one, so
    /// neither is addressable — and `newConversation` must have no generator either.
    func testRoutesWithNothingDurableToNameHaveNoLink() {
        XCTAssertNil(MechanicianURL.link(for: .newConversation(sending: "hi"), scheme: scheme))
        XCTAssertNil(MechanicianURL.link(for: .newConversation(sending: nil), scheme: scheme))
        XCTAssertNil(MechanicianURL.link(for: .files([URL(fileURLWithPath: "/tmp/a.txt")]), scheme: scheme))
    }

    // MARK: - Copy Link

    @MainActor
    func testCopyLinkWritesBothPasteboardFlavors() {
        let pasteboard = NSPasteboard(name: .init(rawValue: "MechanicianURLTests.copy"))
        XCTAssertTrue(MechanicianURL.copyLink(
            to: .conversation(conversationID), scheme: scheme, pasteboard: pasteboard))
        let expected = "mechanician://conversation/\(conversationID.uuidString)"
        // The string flavor is what survives a paste into a note or a chat message, which is where
        // these get kept; the URL flavor is what a drop on Safari or a Finder window needs.
        XCTAssertEqual(pasteboard.string(forType: .string), expected)
        XCTAssertEqual(pasteboard.string(forType: .URL), expected)
    }

    /// Staying quiet beats clearing what the user already had on the pasteboard.
    @MainActor
    func testCopyLinkLeavesThePasteboardAloneForAnUnaddressableRoute() {
        let pasteboard = NSPasteboard(name: .init(rawValue: "MechanicianURLTests.noop"))
        pasteboard.clearContents()
        pasteboard.setString("something the user copied", forType: .string)
        XCTAssertFalse(MechanicianURL.copyLink(
            to: .newConversation(sending: nil), scheme: scheme, pasteboard: pasteboard))
        XCTAssertEqual(pasteboard.string(forType: .string), "something the user copied")
    }
}

/// The scheme is part of the installed identity, and it is declared in three places that must agree:
/// `MechanicianEnvironment`, `app/Mechanician-Info.plist`, and the two build scripts. Drift there is
/// silent — the app would declare one scheme to LaunchServices and mint links with another.
final class URLSchemeIdentityTests: XCTestCase {
    private var repository: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // MechanicianTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // app
            .deletingLastPathComponent()   // repository root
    }

    func testSchemeFollowsBundleIdentity() {
        XCTAssertEqual(MechanicianEnvironment.urlScheme(for: "ai.mechanician.app"), "mechanician")
        XCTAssertEqual(MechanicianEnvironment.urlScheme(for: "ai.mechanician.app.dev"), "mechanician-dev")
        XCTAssertEqual(MechanicianEnvironment.urlScheme(for: "ai.mechanician.app.acme"), "mechanician-acme")
        // Same slug rule as the support directory: the first component after the prefix.
        XCTAssertEqual(MechanicianEnvironment.urlScheme(for: "ai.mechanician.app.acme.internal"),
                       "mechanician-acme")
        // An unrecognized or absent identity is the public app, matching `supportDirectoryName`.
        XCTAssertEqual(MechanicianEnvironment.urlScheme(for: nil), "mechanician")
        XCTAssertEqual(MechanicianEnvironment.urlScheme(for: "com.example.other"), "mechanician")
    }

    /// Every identity gets its own scheme, or a link minted by one bundle opens another bundle's
    /// store. This is the same isolation `supportDirectoryName` and `credentialServices` provide.
    func testEveryIdentityGetsADistinctScheme() {
        let identities = ["ai.mechanician.app", "ai.mechanician.app.dev", "ai.mechanician.app.acme"]
        let schemes = identities.map(MechanicianEnvironment.urlScheme(for:))
        XCTAssertEqual(Set(schemes).count, identities.count, "two identities share a URL scheme")
    }

    func testShippedInfoPlistDeclaresTheSchemeForItsOwnBundleIdentifier() throws {
        let plistURL = repository
            .appendingPathComponent("app/Mechanician-Info.plist")
        let data = try Data(contentsOf: plistURL)
        let plist = try XCTUnwrap(
            try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])

        let bundleIdentifier = try XCTUnwrap(plist["CFBundleIdentifier"] as? String)
        let types = try XCTUnwrap(plist["CFBundleURLTypes"] as? [[String: Any]])
        let declared = try XCTUnwrap(types.first?["CFBundleURLSchemes"] as? [String])

        // LaunchServices reads this plist; `MechanicianURL.link` mints links from the Swift rule.
        // If these two ever disagree, Copy Link produces a link nothing on the Mac can open.
        XCTAssertEqual(declared, [MechanicianEnvironment.urlScheme(for: bundleIdentifier)])
    }

    /// `dev.sh` patches the scheme for the Dev bundle in shell, so the rule lives in two languages.
    /// This is the assertion that catches the one drifting from the other.
    func testDevScriptPatchesTheSchemeItsBundleIdentifierImplies() throws {
        let script = try String(contentsOf: repository.appendingPathComponent("dev.sh"), encoding: .utf8)
        let expected = MechanicianEnvironment.urlScheme(for: "ai.mechanician.app.dev")
        XCTAssertTrue(
            script.contains("Set :CFBundleURLTypes:0:CFBundleURLSchemes:0 \(expected)"),
            "dev.sh does not write the \(expected) scheme its bundle id implies")
    }
}

/// Arrival policy: what happens between a link landing and a window opening.
final class URLArrivalPolicyTests: XCTestCase {
    private let first = MechanicianRoute.workspace(nil)
    private let second = MechanicianRoute.conversation(UUID())

    // MARK: - Rate limiting

    /// A page the user is merely visiting can fire links in a loop, and every destination opens or
    /// focuses a window. Without this, a hundred hidden iframes are a hundred windows.
    func testOneRoutePerSecond() {
        var limiter = URLRouteRateLimiter(interval: 1.0)
        let start = Date(timeIntervalSinceReferenceDate: 1_000)
        XCTAssertTrue(limiter.allows(at: start))
        XCTAssertFalse(limiter.allows(at: start.addingTimeInterval(0.001)))
        XCTAssertFalse(limiter.allows(at: start.addingTimeInterval(0.999)))
        XCTAssertTrue(limiter.allows(at: start.addingTimeInterval(1.0)))
        XCTAssertFalse(limiter.allows(at: start.addingTimeInterval(1.5)))
        XCTAssertTrue(limiter.allows(at: start.addingTimeInterval(2.0)))
    }

    /// A rejected link must not extend the window it was rejected in, or a page firing continuously
    /// could hold the limiter shut forever and block a link the user then clicks themselves.
    func testARejectedLinkDoesNotPushTheNextOneBack() {
        var limiter = URLRouteRateLimiter(interval: 1.0)
        let start = Date(timeIntervalSinceReferenceDate: 1_000)
        XCTAssertTrue(limiter.allows(at: start))
        for tick in stride(from: 0.1, through: 0.9, by: 0.1) {
            XCTAssertFalse(limiter.allows(at: start.addingTimeInterval(tick)))
        }
        XCTAssertTrue(limiter.allows(at: start.addingTimeInterval(1.0)))
    }

    /// A clock that has gone backwards should read as "too soon", not "long enough ago".
    func testAClockGoingBackwardsIsTreatedAsTooSoon() {
        var limiter = URLRouteRateLimiter(interval: 1.0)
        let start = Date(timeIntervalSinceReferenceDate: 1_000)
        XCTAssertTrue(limiter.allows(at: start))
        XCTAssertFalse(limiter.allows(at: start.addingTimeInterval(-60)))
    }

    // MARK: - Launch ordering

    /// Restore runs first and unchanged. A link must never be the reason your last workspace failed
    /// to come back — that is the state-loss invariant, and a deep link is not worth spending it.
    func testLinksArrivingBeforeRestoreAreParked() {
        var queue = LaunchLinkQueue()
        XCTAssertNil(queue.accept(first))
        XCTAssertNil(queue.accept(second))
        XCTAssertFalse(queue.isRestored)
        XCTAssertEqual(queue.restored(), [first, second])
        XCTAssertTrue(queue.isRestored)
    }

    func testLinksArrivingAfterRestoreActImmediately() {
        var queue = LaunchLinkQueue()
        _ = queue.restored()
        XCTAssertEqual(queue.accept(second), second)
        // Nothing was parked, so a second drain has nothing to replay.
        XCTAssertEqual(queue.restored(), [])
    }

    /// Draining twice must not open the same window twice.
    func testParkedLinksDrainExactlyOnce() {
        var queue = LaunchLinkQueue()
        XCTAssertNil(queue.accept(first))
        XCTAssertEqual(queue.restored(), [first])
        XCTAssertEqual(queue.restored(), [])
    }
}
