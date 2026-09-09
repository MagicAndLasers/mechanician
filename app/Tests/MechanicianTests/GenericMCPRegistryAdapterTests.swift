import XCTest
@testable import Mechanician

/// Reading a registry nobody wrote an adapter for.
///
/// The claim being tested is specific: a per-tenant decoder is unnecessary because registries
/// disagree about SPELLING far more than about structure. The load-bearing test is
/// `testInferenceMatchesTheHandWrittenAcmeAdapter` — if inference reproduces what a bespoke
/// adapter produces from the same bytes, the bespoke adapter was never buying anything.
final class GenericMCPRegistryAdapterTests: XCTestCase {
    private func decode(_ json: String) throws -> [MCPRegistryServer] {
        try GenericMCPRegistryAdapter.decode(Data(json.utf8))
    }

    /// The shape `AcmeMCPAdapter` was written for.
    private let acmeShaped = """
    [
      { "name": "io.acme/telemetry",
        "title": "Telemetry",
        "description": "Fleet telemetry queries.",
        "version": "1.4.0",
        "websiteUrl": "https://docs.acme.example/telemetry",
        "repository": { "url": "https://github.example/acme/telemetry" },
        "transports": [ { "type": "streamable-http", "url": "https://mcp.acme.example/telemetry" } ],
        "auth": { "type": "bearer" },
        "governanceReview": { "status": "Approved" } },
      { "name": "io.acme/billing",
        "description": "Billing lookups.",
        "packages": [ { "registryType": "npm", "identifier": "@acme/billing-mcp", "version": "2.0.1",
                        "transport": { "type": "stdio" } } ],
        "governanceReview": { "status": "In review" } }
    ]
    """

    func testInferenceMatchesTheHandWrittenAcmeAdapter() throws {
        let data = Data(acmeShaped.utf8)
        let bespoke = try GenericMCPRegistryAdapter.decode(data, endpointRule: TenantProfile.RegistryEndpointRule(hostSuffix: ".mcp.example.com", path: "/mcp"))
        let inferred = try GenericMCPRegistryAdapter.decode(data)

        XCTAssertEqual(inferred.map(\.name), bespoke.map(\.name))
        XCTAssertEqual(inferred.map(\.description), bespoke.map(\.description))
        XCTAssertEqual(inferred.map(\.title), bespoke.map(\.title))
        XCTAssertEqual(inferred.map(\.version), bespoke.map(\.version))
        XCTAssertEqual(inferred.map { $0.remotes?.map(\.url) },
                       bespoke.map { $0.remotes?.map(\.url) })
        XCTAssertEqual(inferred.map { $0.packages?.map(\.identifier) },
                       bespoke.map { $0.packages?.map(\.identifier) })
        XCTAssertEqual(inferred.map(\.declaredAuthentication), bespoke.map(\.declaredAuthentication))
        XCTAssertEqual(inferred.map(\.governance?.status), bespoke.map(\.governance?.status))
        XCTAssertEqual(inferred.map(\.governance?.isApproved), bespoke.map(\.governance?.isApproved))
    }

    // MARK: The spellings that would otherwise each need an adapter

    func testFieldNamesAreMatchedIgnoringCaseAndSeparators() throws {
        let servers = try decode("""
        { "Servers": [
            { "Server_Name": "acme.db", "Summary": "Query the warehouse.",
              "Endpoints": [ { "URI": "https://mcp.acme.example/db" } ] }
        ] }
        """)

        XCTAssertEqual(servers.count, 1)
        XCTAssertEqual(servers.first?.name, "acme.db")
        XCTAssertEqual(servers.first?.description, "Query the warehouse.")
        XCTAssertEqual(servers.first?.remotes?.first?.url, "https://mcp.acme.example/db")
    }

    func testTheServerListIsFoundUnderAnyUsualKey() throws {
        for key in ["servers", "data", "items", "results", "entries", "mcpServers"] {
            let servers = try decode("""
            { "\(key)": [ { "name": "a", "url": "https://mcp.example/a" } ] }
            """)
            XCTAssertEqual(servers.map(\.name), ["a"], "list under “\(key)”")
        }
    }

    func testATopLevelArrayIsAServerList() throws {
        XCTAssertEqual(
            try decode(#"[ { "id": "a", "endpoint": "https://mcp.example/a" } ]"#).map(\.name),
            ["a"])
    }

    /// A registry keyed BY server name is still a list of servers; the key is the name.
    func testAnObjectKeyedByServerNameIsAlsoAList() throws {
        let servers = try decode("""
        { "io.acme/db": { "description": "DB", "url": "https://mcp.acme.example/db" },
          "io.acme/fs": { "description": "FS", "url": "https://mcp.acme.example/fs" } }
        """)

        XCTAssertEqual(Set(servers.map(\.name)), ["io.acme/db", "io.acme/fs"])
    }

    func testAFlatEntryCarryingItsOwnEndpointWorks() throws {
        let servers = try decode("""
        [ { "title": "Acme Search", "href": "https://mcp.acme.example/search", "type": "sse" } ]
        """)

        XCTAssertEqual(servers.first?.title, "Acme Search")
        XCTAssertEqual(servers.first?.name, "acme-search", "a missing name is slugged from the title")
        XCTAssertEqual(servers.first?.remotes?.first?.type, "sse")
    }

    // MARK: What it refuses to guess

    /// The safety rule. Recognizing fields flexibly must not become inventing capability: an entry
    /// with nothing to connect to is dropped, not shown as connectable.
    func testAnEntryWithNoUsableEndpointIsDropped() throws {
        let servers = try decode("""
        [ { "name": "no-endpoint", "description": "Nothing to connect to." },
          { "name": "insecure", "url": "http://plain.example/mcp" },
          { "name": "usable", "url": "https://mcp.example/ok" } ]
        """)

        XCTAssertEqual(servers.map(\.name), ["usable"], "http and endpoint-less entries are dropped")
    }

    /// A registry must never be able to name an arbitrary command. Only ecosystems Mechanician can
    /// launch itself survive, and only over stdio.
    func testOnlyLaunchableEcosystemsBecomePackages() throws {
        let servers = try decode("""
        [ { "name": "shell", "packages": [ { "registryType": "binary", "identifier": "/bin/sh" } ] },
          { "name": "node", "packages": [ { "registryType": "npm", "identifier": "@acme/x" } ] } ]
        """)

        XCTAssertEqual(servers.map(\.name), ["node"])
        XCTAssertEqual(servers.first?.packages?.first?.runtimeHint, "npx")
    }

    func testOneMalformedEntryDoesNotHideTheRest() throws {
        let servers = try decode("""
        [ "not an object",
          { "name": "good", "url": "https://mcp.example/good" },
          { "description": "no name and no endpoint" } ]
        """)

        XCTAssertEqual(servers.map(\.name), ["good"])
    }

    func testAnUnrecognizableDocumentIsAnErrorRatherThanAnEmptyRegistry() {
        XCTAssertThrowsError(try decode(#"{ "message": "not a registry" }"#))
    }

    // MARK: Governance

    func testAReviewStatusIsFoundWhateverItIsCalled() throws {
        for key in ["status", "state", "approvalStatus", "reviewStatus"] {
            let servers = try decode("""
            [ { "name": "a", "url": "https://mcp.example/a", "\(key)": "Approved" } ]
            """)
            XCTAssertEqual(servers.first?.governance?.status, "Approved", "status under “\(key)”")
            XCTAssertTrue(servers.first?.governance?.isApproved == true)
        }
    }

    func testGovernancePolicyDecidesWhatCountsAsApproved() throws {
        let data = Data("""
        [ { "name": "a", "url": "https://mcp.example/a", "status": "Cleared" } ]
        """.utf8)
        let policy = try JSONDecoder().decode(
            TenantProfile.RegistryGovernancePolicy.self,
            from: Data(#"{ "approvedStatuses": ["Cleared"] }"#.utf8))

        let servers = try GenericMCPRegistryAdapter.decode(data, governancePolicy: policy)

        XCTAssertTrue(servers.first?.governance?.isApproved == true)
        // The default policy approves only "Approved", so the same document reads differently.
        XCTAssertFalse(try GenericMCPRegistryAdapter.decode(data).first?.governance?.isApproved == true)
    }

    func testCanonicalKeyCollapsesSeparatorsAndCase() {
        XCTAssertEqual(GenericMCPRegistryAdapter.canonicalKey("Server_Name"), "servername")
        XCTAssertEqual(GenericMCPRegistryAdapter.canonicalKey("server-name"), "servername")
        XCTAssertEqual(GenericMCPRegistryAdapter.canonicalKey("serverName"), "servername")
    }

    /// The user-facing point of the whole thing: it can be chosen without an app release.
    func testEveryRegistryFormatIsSelectableByAUser() {
        XCTAssertTrue(RegistryFormat.userSelectableCases.contains(.generic))
        // No format is withheld from the picker any more. A per-organization case used to be, and
        // withholding it was correct — offering one company's private schema to everyone implies a
        // generality it did not have. The answer was to stop having such a case at all: a private
        // catalog is now a signed profile pointing `generic` at its URL.
        XCTAssertEqual(
            Set(RegistryFormat.userSelectableCases),
            Set(RegistryFormat.allCases),
            "a format nobody may pick is a format that should not exist")
    }
}
