import XCTest
@testable import Mechanician

/// Provenance answers "where did this server come from?" — the question that made a list of seven
/// configured servers unrecognisable to their owner, because nothing recorded it.
///
/// The persistence half of these tests guards the trap this codebase has now hit twice: adding a
/// field to a persisted struct can silently quarantine every older record (0.11.7 subagents, and
/// `CapabilityParam` this week). A dropped MCP server is worse than a missing badge.
final class ExtensionProvenanceTests: XCTestCase {

    // MARK: persistence

    func testServerWrittenBeforeProvenanceExistedStillDecodes() throws {
        // Exactly the shape on disk before `source`/`publisher` were introduced.
        let legacy = """
        {"id":"6C7C6E5E-1E7E-4B2E-9E2B-2E7E5E6C7C6E","name":"github","enabled":true,
         "transport":"http","command":"","args":[],"env":{},
         "url":"https://api.githubcopilot.com/mcp/","headers":{}}
        """.data(using: .utf8)!

        let server = try JSONDecoder().decode(MCPServer.self, from: legacy)

        XCTAssertEqual(server.name, "github")
        XCTAssertNil(server.source, "an older record has no recorded origin")
        XCTAssertNil(server.publisher)
    }

    func testUnknownSourceValueDoesNotDropTheServer() throws {
        // A newer build could write a case this one has never heard of. Losing the whole server
        // over an unrecognised label would be the quarantine bug all over again.
        let future = """
        {"id":"7D8D7F6F-2F8F-4C3F-8F3C-3F8F6F7D8D7F","name":"future","enabled":true,
         "transport":"stdio","command":"npx","args":[],"env":{},"url":"","headers":{},
         "source":"notAKnownCase"}
        """.data(using: .utf8)!

        let server = try? JSONDecoder().decode(MCPServer.self, from: future)
        XCTAssertNotNil(server, "an unknown source value must not cost us the server record")
        XCTAssertNil(server?.source, "and it decodes as unknown rather than guessing")
    }

    func testProvenanceSurvivesARoundTrip() throws {
        var server = MCPServer(name: "notion")
        server.source = .verified
        server.publisher = "Notion"

        let data = try JSONEncoder().encode(server)
        let back = try JSONDecoder().decode(MCPServer.self, from: data)

        XCTAssertEqual(back.source, .verified)
        XCTAssertEqual(back.publisher, "Notion")
    }

    // MARK: the catalog's claim

    /// "Verified" means the vendor whose service it exposes published it. If an entry claims that
    /// without naming a publisher, the badge is asserting something it cannot support.
    func testEveryVerifiedCatalogEntryNamesItsPublisher() {
        for server in MCPCatalog.servers where server.source == .verified {
            XCTAssertNotNil(server.publisher, "\(server.name) claims verified with no publisher")
            XCTAssertFalse(server.publisher?.isEmpty ?? true,
                           "\(server.name) claims verified with an empty publisher")
        }
    }

    /// The community Outlook server needs the user to register their own Entra application. It is
    /// emphatically not first-party, and sitting unmarked beside GitHub and Notion is how a
    /// curated list stops meaning anything.
    func testCommunityEntriesAreNotMarkedVerified() {
        let community = MCPCatalog.servers.first { $0.name.contains("microsoft-outlook-mcp") }
        XCTAssertNotNil(community, "the community entry should still be offered")
        XCTAssertNotEqual(community?.source, .verified,
                          "a community server must never carry the Verified badge")
    }

    func testCatalogIsEntirelyFirstPartyOrExplicitlyNot() {
        // No entry may be left with no opinion recorded: either we vouch via a named publisher, or
        // we deliberately do not. Silence is what made the old list read as arbitrary.
        for server in MCPCatalog.servers {
            let decided = server.source == .verified || server.source == nil
            XCTAssertTrue(decided, "\(server.name) has an unexpected catalog provenance")
        }
        XCTAssertGreaterThan(
            MCPCatalog.servers.filter { $0.source == .verified }.count, 0,
            "the catalog should contain verified entries or it is not a curated list")
    }
}
