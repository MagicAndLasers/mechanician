import XCTest
@testable import Mechanician

final class ExtensionsBrowserTests: XCTestCase {
    func testMakerBadgeChoosesContrastingInkForEveryBrandAndFallbackColor() {
        let fills = Array(MakerBadge.brand.values) + MakerBadge.palette

        for fill in fills {
            let luminance = relativeLuminance(fill)
            let contrast = MakerBadge.usesLightInk(on: fill)
                ? 1.05 / (luminance + 0.05)
                : (luminance + 0.05) / 0.05
            XCTAssertGreaterThanOrEqual(
                contrast,
                4.5,
                "maker monogram ink must remain readable on \(fill)")
        }

        XCTAssertFalse(
            MakerBadge.usesLightInk(on: MakerBadge.rgb(for: "Amazon Web Services")),
            "pale brand orange needs black monogram ink")
        XCTAssertTrue(
            MakerBadge.usesLightInk(on: MakerBadge.rgb(for: "Apollo GraphQL")),
            "deep brand purple needs white monogram ink")
        XCTAssertTrue(
            MakerBadge.usesLightInk(on: MakerBadge.rgb(for: "Google")),
            "saturated brand blue needs white monogram ink")
        XCTAssertTrue(
            MakerBadge.usesLightInk(on: MakerBadge.rgb(for: "Microsoft")),
            "marginal brand blue should prefer readable white over black")
        XCTAssertTrue(
            MakerBadge.usesLightInk(on: MakerBadge.palette[0]),
            "fallback blue needs white monogram ink")
        XCTAssertTrue(
            MakerBadge.usesLightInk(on: MakerBadge.palette[4]),
            "fallback violet needs white monogram ink")
    }

    private func remoteServer(enabled: Bool = true) -> MCPServer {
        var server = MCPServer(name: "confluence")
        server.enabled = enabled
        server.transport = .http
        server.url = "https://confluence.example/mcp"
        return server
    }

    private func relativeLuminance(_ color: MakerBadge.RGB) -> Double {
        func linear(_ component: Double) -> Double {
            component <= 0.04045
                ? component / 12.92
                : pow((component + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(color.red)
            + 0.7152 * linear(color.green)
            + 0.0722 * linear(color.blue)
    }

    func testMCPAttentionMakesAuthenticationAndZeroToolsExplicit() {
        let server = remoteServer()

        XCTAssertEqual(
            MCPAttentionResolver.primary(
                servers: [server], authStates: [:],
                connectionStates: [server.name: .needsAuth]),
            MCPAttention(serverName: "confluence", kind: .needsAuthentication))
        XCTAssertEqual(
            MCPAttentionResolver.primary(
                servers: [server], authStates: [server.name: .preparing],
                connectionStates: [server.name: .needsAuth]),
            MCPAttention(serverName: "confluence", kind: .preparing))
        XCTAssertEqual(
            MCPAttentionResolver.primary(
                servers: [server], authStates: [server.name: .authorizing],
                connectionStates: [server.name: .needsAuth]),
            MCPAttention(serverName: "confluence", kind: .authorizing))
        XCTAssertEqual(
            MCPAttentionResolver.primary(
                servers: [server], authStates: [server.name: .waiting],
                connectionStates: [server.name: .needsAuth]),
            MCPAttention(serverName: "confluence", kind: .waitingForBrowser))
        XCTAssertEqual(
            MCPAttentionResolver.primary(
                servers: [server], authStates: [server.name: .authorized],
                connectionStates: [server.name: .connected(0)]),
            MCPAttention(serverName: "confluence", kind: .noTools))
        XCTAssertNil(
            MCPAttentionResolver.primary(
                servers: [server], authStates: [server.name: .authorized],
                connectionStates: [server.name: .connected(nil)]))
        XCTAssertNil(
            MCPAttentionResolver.primary(
                servers: [server], authStates: [server.name: .authorized],
                connectionStates: [server.name: .unknown]))
        XCTAssertNil(
            MCPAttentionResolver.primary(
                servers: [server], authStates: [server.name: .authorized],
                connectionStates: [server.name: .checking]))
    }

    func testMCPAttentionClearsOnlyAfterToolsAreUsable() {
        let server = remoteServer()
        XCTAssertNil(MCPAttentionResolver.primary(
            servers: [server], authStates: [server.name: .authorized],
            connectionStates: [server.name: .connected(28)]))
        XCTAssertNil(MCPAttentionResolver.primary(
            servers: [remoteServer(enabled: false)], authStates: [:],
            connectionStates: [server.name: .needsAuth]))
    }

    func testMCPAuthorizationProgressDistinguishesAcceptedClickFromOwnedBrowserFlow() {
        XCTAssertEqual(MCPAuthorizationProgressPhase(.preparing), .preparing)
        XCTAssertEqual(MCPAuthorizationProgressPhase(.authorizing), .authorizing)
        XCTAssertEqual(MCPAuthorizationProgressPhase(.waiting), .waitingForBrowser)
        XCTAssertNil(MCPAuthorizationProgressPhase(.idle))
        XCTAssertNil(MCPAuthorizationProgressPhase(.authorized))
    }

    func testDifferentServerReconciliationCannotClaimTheClickedRowsProgress() {
        XCTAssertEqual(
            MCPAuthorizationPreparationStateResolver.finishingState(
                clickedServer: "notion",
                reconciledServer: "github",
                launched: true,
                currentState: .preparing),
            .idle,
            "Only the server with the durable attempt may present cancel-capable progress.")
        XCTAssertEqual(
            MCPAuthorizationPreparationStateResolver.finishingState(
                clickedServer: "notion",
                reconciledServer: "notion",
                launched: true,
                currentState: .preparing),
            .authorizing)
        XCTAssertNil(
            MCPAuthorizationPreparationStateResolver.finishingState(
                clickedServer: "notion",
                reconciledServer: "github",
                launched: true,
                currentState: .waiting),
            "A later published state must never be overwritten by deferred preparation cleanup.")
    }

    func testAcceptedAuthorizationClickBlocksProviderExposureBeforeDurableAttempt() {
        XCTAssertTrue(
            MCPAuthorizationProviderExposurePolicy.isBlocked(
                preparationInFlight: true,
                hasPendingAttempt: false),
            "The click-to-write-ahead window must block a queued turn from the old provider session.")
        XCTAssertTrue(
            MCPAuthorizationProviderExposurePolicy.isBlocked(
                preparationInFlight: false,
                hasPendingAttempt: true))
        XCTAssertFalse(
            MCPAuthorizationProviderExposurePolicy.isBlocked(
                preparationInFlight: false,
                hasPendingAttempt: false))
    }

    @MainActor
    func testPreparingAuthorizationSurvivesStatusInvalidationAndStaysLaneScoped() {
        let store = ExtensionsStore.shared
        let name = "preparing-auth-\(UUID().uuidString)"
        let access = ModelAccess.claudeSubscription
        let otherAccess = ModelAccess.codexSubscription
        defer {
            store.setAuthState(name, .idle, for: access)
            store.setAuthState(name, .idle, for: otherAccess)
        }

        store.setAuthState(name, .preparing, for: access)
        store.invalidateConfiguredMCPStatus([name])

        XCTAssertEqual(store.authState(for: name, access: access), .preparing)
        XCTAssertTrue(store.authState(for: name, access: access).isInProgress)
        XCTAssertEqual(store.authState(for: name, access: otherAccess), .idle)
        XCTAssertFalse(store.authState(for: name, access: otherAccess).isInProgress)
    }

    func testRemotePATHeadersSelectManualCredentialsInsteadOfBrowserOAuth() {
        var jira = remoteServer()
        jira.name = "jira"
        jira.headers = ["X-API-Key": "jira-pat"]
        XCTAssertTrue(jira.hasManualHeaderCredentials)

        jira.headers = ["authorization": "Bearer jira-pat"]
        XCTAssertTrue(jira.hasManualHeaderCredentials)

        jira.headers = ["Authorization": "   "]
        XCTAssertFalse(jira.hasManualHeaderCredentials)

        var local = MCPServer(name: "local", transport: .stdio, command: "/bin/test")
        local.headers = ["Authorization": "Bearer unused"]
        XCTAssertFalse(local.hasManualHeaderCredentials)
    }

    func testIndeterminateProbeCannotEraseObservedToolAvailability() {
        XCTAssertEqual(
            MCPConnState.connected(nil).reconciled(with: .unknown),
            .connected(nil))
        XCTAssertEqual(
            MCPConnState.connected(nil).reconciled(with: .checking),
            .connected(nil))
        XCTAssertEqual(
            MCPConnState.authenticated.reconciled(with: .unknown),
            .authenticated)
        XCTAssertEqual(
            MCPConnState.authenticated.reconciled(with: .checking),
            .authenticated)
        XCTAssertEqual(
            MCPConnState.connected(12).reconciled(with: .authenticated),
            .connected(12))
        XCTAssertEqual(
            MCPConnState.failed("VPN unavailable").reconciled(with: .authenticated),
            .failed("VPN unavailable"))
        XCTAssertEqual(
            MCPConnState.needsAuth.reconciled(with: .unknown),
            .needsAuth)
        XCTAssertEqual(
            MCPConnState.connected(12).reconciled(with: .needsAuth),
            .needsAuth)
    }

    func testMCPAccessDefaultsToManagedProfileRouteInsteadOfVisibleConversation() {
        let selected = MCPAccessSelection.resolve(
            savedRawValue: nil,
            available: [.claudeSubscription, .anthropicAPI, .claudeVertex],
            profileDefault: .claudeVertex,
            conversationDefault: .codexSubscription,
            current: .codexSubscription)

        XCTAssertEqual(selected, .claudeVertex)
    }

    func testSavedMCPAccessRemainsExplicitAcrossConversationChanges() {
        let selected = MCPAccessSelection.resolve(
            savedRawValue: ModelAccess.claudeSubscription.rawValue,
            available: [.claudeSubscription, .anthropicAPI, .claudeVertex],
            profileDefault: .claudeVertex,
            conversationDefault: .claudeVertex,
            current: .openAIAPI)

        XCTAssertEqual(selected, .claudeSubscription)
    }

    func testRegistryPackageUsesItsDeclaredExactVersion() {
        let package = MCPRegistryServer.Package(
            registryType: "npm",
            identifier: "@example/server",
            version: "1.2.3",
            runtimeHint: "npx",
            transport: nil,
            environmentVariables: nil)
        let server = MCPRegistryServer(
            name: "com.example/server",
            description: "Example",
            packages: [package])

        XCTAssertEqual(server.packageSpecifier, "@example/server@1.2.3")
        XCTAssertEqual(server.stdioCommand, "npx -y @example/server@1.2.3")
    }

    func testCuratedPackageWithoutVersionKeepsExplicitSpecifier() {
        let package = MCPRegistryServer.Package(
            registryType: "npm",
            identifier: "@example/server@4.5.6",
            version: nil,
            runtimeHint: "npx",
            transport: nil,
            environmentVariables: nil)
        let server = MCPRegistryServer(
            name: "com.example/server",
            description: "Example",
            packages: [package])

        XCTAssertEqual(server.packageSpecifier, "@example/server@4.5.6")
    }

    func testAcmeRegistryAdapterNormalizesProductionRemotePackageAndGovernanceEntries() throws {
        let data = Data(#"""
        [
          { "name": "com.acme/query", "title": "Query", "description": "Internal data",
            "version": "1.2.3", "hosting": "Remote",
            "transports": [{ "type": "streamable-http", "url": "https://query.mcp.example.com" }],
            "auth": { "type": "oauth2", "authorizationServerUrl": "https://query.mcp.example.com" },
            "governanceReview": { "status": "Approved" },
            "websiteUrl": "https://mcp.example.com/query",
            "repository": { "url": "https://git.example/query" } },
          { "name": "com.acme/current-package", "title": "Current Package",
            "description": "Current array schema",
            "packages": [{ "registryType": "npm", "identifier": "@acme/current-mcp",
                           "version": "2.0.0", "transport": { "type": "stdio" } }],
            "governanceReview": { "status": "Wishlist" } },
          { "name": "com.acme/local", "title": "Local Tool", "description": "Package",
            "packages": { "npm": "@acme/local-mcp" } },
          { "name": "com.acme/inert", "title": "Inert", "command": "/tmp/untrusted" }
        ]
        """#.utf8)

        let servers = try GenericMCPRegistryAdapter.decode(data, endpointRule: TenantProfile.RegistryEndpointRule(hostSuffix: ".mcp.example.com", path: "/mcp"))
        XCTAssertEqual(servers.count, 3, "raw commands are not accepted from registry data")
        let remote = try XCTUnwrap(servers.first { $0.name == "com.acme/query" })
        XCTAssertEqual(remote.firstRemote?.url, "https://query.mcp.example.com/mcp")
        XCTAssertEqual(remote.declaredAuthentication, .oauth2)
        XCTAssertEqual(remote.authenticationBadge, "OAuth")
        XCTAssertEqual(remote.authenticationDescription, "OAuth: sign in after connecting")
        XCTAssertFalse(remote.remoteNeedsAuth)
        XCTAssertEqual(remote.governance?.status, "Approved")
        XCTAssertTrue(try XCTUnwrap(remote.governance?.isApproved))
        XCTAssertEqual(remote.repoURL?.absoluteString, "https://git.example/query")

        let current = try XCTUnwrap(servers.first { $0.name == "com.acme/current-package" })
        XCTAssertEqual(current.stdioCommand, "npx -y @acme/current-mcp@2.0.0")
        XCTAssertEqual(current.governance?.status, "Wishlist")
        XCTAssertFalse(try XCTUnwrap(current.governance?.isApproved),
                       "non-approved entries remain present and usable")

        let local = try XCTUnwrap(servers.first { $0.name == "com.acme/local" })
        XCTAssertEqual(local.stdioCommand, "npx -y @acme/local-mcp")
    }

    func testAcmeRegistryAdapterMapsManualRemoteCredentialsWithoutHidingEntries() throws {
        let data = Data(#"""
        [
          { "name": "com.acme/jira", "description": "Jira",
            "transports": [
              { "type": "streamable-http", "url": "http://insecure.example/mcp" },
              { "type": "streamable-http", "url": "https://jira.mcp.example.com/mcp" }
            ],
            "auth": { "type": "api-key", "apiKeyHeader": "X-Acme-PAT" },
            "governanceReview": { "status": "Not Approved" } }
        ]
        """#.utf8)

        let server = try XCTUnwrap(GenericMCPRegistryAdapter.decode(data).first)
        XCTAssertEqual(server.remotes?.count, 1, "only HTTPS transports may enter the catalog")
        XCTAssertEqual(server.firstRemote?.headers?.first?.name, "X-Acme-PAT")
        XCTAssertTrue(server.remoteNeedsAuth)
        XCTAssertEqual(server.authenticationBadge, "API key")
        XCTAssertEqual(server.governanceBadge, "Not approved")
    }

    func testAcmeRegistryAdapterToleratesSchemaDriftPerEntry() throws {
        let data = Data(#"""
        {
          "servers": [
            {
              "name": "com.acme/resilient-remote",
              "description": "Still usable",
              "version": 7,
              "transports": [
                "unexpected",
                { "type": "streamable-http", "url": "https://resilient.mcp.example.com" }
              ],
              "auth": "oauth2",
              "governanceReview": "Discovery",
              "repository": "https://git.example/resilient",
              "support": "unexpected"
            },
            {
              "name": "com.acme/resilient-package",
              "packages": {
                "registryType": "npm",
                "identifier": "@acme/resilient",
                "transport": "stdio"
              }
            },
            {
              "name": ["malformed"],
              "transports": "unexpected"
            },
            "not-an-entry"
          ]
        }
        """#.utf8)

        let servers = try GenericMCPRegistryAdapter.decode(data, endpointRule: TenantProfile.RegistryEndpointRule(hostSuffix: ".mcp.example.com", path: "/mcp"))
        XCTAssertEqual(servers.count, 2)

        let remote = try XCTUnwrap(servers.first { $0.name == "com.acme/resilient-remote" })
        XCTAssertEqual(remote.firstRemote?.url, "https://resilient.mcp.example.com/mcp")
        XCTAssertEqual(remote.declaredAuthentication, .oauth2)
        XCTAssertEqual(remote.governance?.status, "Discovery")
        XCTAssertEqual(remote.repoURL?.absoluteString, "https://git.example/resilient")
        // The inference adapter coerces a numeric version rather than discarding it: registries
        // disagree about types as well as spelling, and `"version": 7` is a value, not damage. What
        // matters — and is asserted above and below — is that the malformed `transports` element,
        // the malformed entry, and the non-object entry cost this server nothing.
        XCTAssertEqual(remote.version, "7")

        let package = try XCTUnwrap(servers.first { $0.name == "com.acme/resilient-package" })
        XCTAssertEqual(package.stdioCommand, "npx -y @acme/resilient")
    }

    func testRegistryGovernancePolicySupportsCompanySpecificApprovalStates() {
        let policy = TenantProfile.RegistryGovernancePolicy(
            approvedStatuses: ["Production", "Security Reviewed"])

        XCTAssertTrue(policy.isApproved(" production "))
        XCTAssertTrue(policy.isApproved("SECURITY REVIEWED"))
        XCTAssertFalse(policy.isApproved("Discovery"))
    }

    func testVPNGuidanceRequiresAnActualNetworkFailure() {
        let sourceID = UUID()
        let network = ExtensionSourceIssue(
            sourceID: sourceID, sourceName: "Company Registry",
            networkScope: .vpnOnly, authentication: nil,
            kind: .network, detail: "ENOTFOUND", status: nil)
        let forbidden = ExtensionSourceIssue(
            sourceID: sourceID, sourceName: "Company Registry",
            networkScope: .vpnOnly, authentication: nil,
            kind: .http, detail: "HTTP 403", status: 403)
        let malformed = ExtensionSourceIssue(
            sourceID: sourceID, sourceName: "Company Registry",
            networkScope: .vpnOnly, authentication: nil,
            kind: .invalidResponse, detail: "bad JSON", status: nil)
        let publicNetwork = ExtensionSourceIssue(
            sourceID: sourceID, sourceName: "Public Registry",
            networkScope: .public, authentication: nil,
            kind: .network, detail: "ENOTFOUND", status: nil)

        XCTAssertEqual(
            network.message,
            "Couldn’t reach Company Registry. Connect to your corporate VPN and retry.")
        XCTAssertEqual(
            forbidden.message,
            "Company Registry denied access (HTTP 403). Check the catalog’s access policy.")
        XCTAssertEqual(
            malformed.message,
            "Company Registry returned catalog data Mechanician couldn’t understand.")
        XCTAssertEqual(
            publicNetwork.message,
            "Couldn’t reach Public Registry. Check your network connection and retry.")
        XCTAssertTrue(network.isRetryable)
        XCTAssertTrue(forbidden.isRetryable)
        XCTAssertFalse(malformed.isRetryable)
    }

    func testManagedCatalogAuthenticationGuidanceNamesConfiguredIdentity() {
        let issue = ExtensionSourceIssue(
            sourceID: UUID(), sourceName: "Company Plugins",
            networkScope: .vpnOnly, authentication: .googleIdentity,
            kind: .authentication, detail: "token unavailable", status: 401)

        XCTAssertEqual(
            issue.message,
            "Company Plugins needs your Google account. Reconnect the configured provider and retry.")
        XCTAssertEqual(issue.systemImage, "person.crop.circle.badge.exclamationmark")
        XCTAssertTrue(issue.needsGoogleReconnect)
        XCTAssertFalse(issue.isRetryable)
    }

    func testExistingAcmeRootEndpointMigratesWithoutChangingOtherServers() {
        var confluence = MCPServer(name: "confluence.mcp.example.com")
        confluence.transport = .http
        confluence.url = "https://confluence.mcp.example.com"
        var publicServer = MCPServer(name: "public")
        publicServer.transport = .http
        publicServer.url = "https://example.com"

        let migrated = MCPEndpointNormalizer.migrateInstalledServers(
            [confluence, publicServer],
            rule: .init(hostSuffix: ".mcp.example.com", path: "/mcp"))

        XCTAssertEqual(migrated[0].url, "https://confluence.mcp.example.com/mcp")
        XCTAssertEqual(migrated[1].url, "https://example.com")
    }

    func testPluginArchiveRegistryNormalizesDeclaredContents() throws {
        let data = Data(#"""
        { "version": 1, "name": "Company Plugins", "plugins": [
          { "name": "flight-ops", "version": "2.0.0", "description": "Flight operations",
            "author": "Example Corp", "skills": ["flight-search"], "commands": ["brief"],
            "mcpServers": ["flight-data"], "archive": "https://plugins.example/flight.tar.gz" }
        ] }
        """#.utf8)

        let manifest = try PluginArchiveRegistryAdapter.decode(data)
        let plugin = try XCTUnwrap(manifest.plugins.first)
        XCTAssertEqual(manifest.name, "Company Plugins")
        XCTAssertEqual(plugin.skills, ["flight-search"])
        XCTAssertEqual(plugin.commands, ["brief"])
        XCTAssertEqual(plugin.mcpServers, ["flight-data"])
        XCTAssertEqual(plugin.archive, "https://plugins.example/flight.tar.gz")
    }

    @MainActor
    func testManagedPluginCatalogCarriesAnAuthenticatedArchiveInstall() throws {
        var source = MarketplaceSource()
        source.name = "Company Plugins"
        source.repo = "https://plugins.example/registry.json"
        source.format = .archiveRegistryV1
        source.source = .managed
        source.networkScope = .vpnOnly
        source.authentication = .googleIdentity

        let data = Data(#"""
        { "version": 1, "name": "Payload Cannot Rename This Tab", "plugins": [
          { "name": "operations", "description": "Internal operations",
            "version": "2.0.0",
            "author": "Example Corp", "skills": ["search"], "commands": ["brief"],
            "mcpServers": ["internal-data"],
            "archive": "https://plugins.example/operations.tar.gz",
            "sha256": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" }
        ] }
        """#.utf8)

        let decoded = try ClaudePluginStore.decodeManagedCatalog(source: source, data: data)
        XCTAssertEqual(decoded.marketplace.name, "Company Plugins")
        XCTAssertTrue(decoded.marketplace.isManaged)
        XCTAssertEqual(decoded.marketplace.networkScope, .vpnOnly)
        XCTAssertEqual(decoded.marketplace.detail, "Managed by your organization · VPN")

        let plugin = try XCTUnwrap(decoded.available.first)
        XCTAssertEqual(plugin.pluginId,
                       "operations@archive-\(source.id.uuidString.lowercased())")
        XCTAssertEqual(plugin.marketplaceName, decoded.marketplace.name)
        XCTAssertTrue(plugin.isManaged)
        XCTAssertTrue(plugin.canInstall)
        XCTAssertEqual(plugin.archiveInstall?.sourceID, source.id)
        XCTAssertEqual(plugin.archiveInstall?.sourceName, "Company Plugins")
        XCTAssertEqual(plugin.archiveInstall?.catalogURL, source.rawURL)
        XCTAssertEqual(plugin.archiveInstall?.archiveURL,
                       "https://plugins.example/operations.tar.gz")
        XCTAssertEqual(plugin.archiveInstall?.version, "2.0.0")
        XCTAssertEqual(plugin.archiveInstall?.expectedSHA256,
                       "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa")
        XCTAssertEqual(plugin.archiveInstall?.authentication, .googleIdentity)
        XCTAssertEqual(plugin.archiveInstall?.networkScope, .vpnOnly)
        let request = try XCTUnwrap(plugin.archiveInstall?
            .request(pluginID: plugin.pluginId, pluginName: plugin.name))
        XCTAssertEqual(request["action"] as? String, "installArchive")
        XCTAssertEqual(request["pluginId"] as? String, plugin.pluginId)
        XCTAssertEqual(request["authentication"] as? String, "googleIdentity")
        XCTAssertEqual(request["sourceId"] as? String, source.id.uuidString.lowercased())
        XCTAssertEqual(plugin.components?.skills, ["search"])
        XCTAssertEqual(plugin.components?.commands, ["brief"])
        XCTAssertEqual(plugin.components?.mcpServers, ["internal-data"])
    }

    @MainActor
    func testArchiveCatalogLeavesMalformedEntriesVisibleButUnavailable() throws {
        var source = MarketplaceSource()
        source.name = "Company Plugins"
        source.repo = "https://plugins.example/registry.json"
        source.format = .archiveRegistryV1

        let data = Data(#"""
        { "version": 1, "name": "Company Plugins", "plugins": [
          { "name": "missing", "archive": "" },
          { "name": "insecure", "archive": "http://plugins.example/insecure.tar.gz" },
          { "name": "bad-digest", "archive": "/bad.tar.gz", "sha256": "not-a-digest" },
          { "name": "bad-version", "version": " 1.0.0", "archive": "/version.tar.gz" },
          { "name": " padded-name ", "archive": "/padded.tar.gz" },
          { "name": "relative", "archive": "/relative.tar.gz" }
        ] }
        """#.utf8)

        let decoded = try ClaudePluginStore.decodeArchiveCatalog(source: source, data: data)
        XCTAssertEqual(decoded.available.map(\.name),
                       ["missing", "insecure", "bad-digest", "bad-version", "relative"])
        XCTAssertEqual(decoded.available.map(\.canInstall), [false, false, false, false, true])
        XCTAssertEqual(decoded.available[3].installUnavailableReason,
                       "This registry entry declares an invalid plugin version.")
        XCTAssertEqual(decoded.available.last?.archiveInstall?.archiveURL,
                       "https://plugins.example/relative.tar.gz")
    }

    @MainActor
    func testArchiveSourcesWithTheSameFriendlyNameKeepDistinctStableIdentities() throws {
        var first = MarketplaceSource()
        first.id = try XCTUnwrap(UUID(uuidString: "11111111-1111-4111-8111-111111111111"))
        first.name = "Company Plugins"
        first.repo = "https://plugins-one.example/registry.json"
        first.format = .archiveRegistryV1

        var second = MarketplaceSource()
        second.id = try XCTUnwrap(UUID(uuidString: "22222222-2222-4222-8222-222222222222"))
        second.name = first.name
        second.repo = "https://plugins-two.example/registry.json"
        second.format = .archiveRegistryV1

        let data = Data(#"""
        { "version": 1, "name": "Payload Name", "plugins": [
          { "name": "operations", "archive": "/operations.tar.gz" }
        ] }
        """#.utf8)

        let firstDecoded = try ClaudePluginStore.decodeArchiveCatalog(source: first, data: data)
        let firstRefresh = try ClaudePluginStore.decodeArchiveCatalog(source: first, data: data)
        let secondDecoded = try ClaudePluginStore.decodeArchiveCatalog(source: second, data: data)

        XCTAssertEqual(firstDecoded.marketplace.name, secondDecoded.marketplace.name)
        XCTAssertEqual(firstDecoded.marketplace.id, "11111111-1111-4111-8111-111111111111")
        XCTAssertEqual(secondDecoded.marketplace.id, "22222222-2222-4222-8222-222222222222")
        XCTAssertNotEqual(firstDecoded.marketplace.id, secondDecoded.marketplace.id)

        let firstPluginID = try XCTUnwrap(firstDecoded.available.first?.pluginId)
        let secondPluginID = try XCTUnwrap(secondDecoded.available.first?.pluginId)
        XCTAssertEqual(firstPluginID,
                       "operations@archive-11111111-1111-4111-8111-111111111111")
        XCTAssertEqual(secondPluginID,
                       "operations@archive-22222222-2222-4222-8222-222222222222")
        XCTAssertNotEqual(firstPluginID, secondPluginID)
        XCTAssertEqual(firstRefresh.marketplace.id, firstDecoded.marketplace.id)
        XCTAssertEqual(firstRefresh.available.first?.pluginId, firstPluginID)
    }

    func testSameNamedMarketplaceTabsExposeFormatAndArchiveLocation() {
        let firstSourceID = UUID()
        let secondSourceID = UUID()
        let native = ClaudePluginStore.Marketplace(
            name: "Company Plugins",
            source: "github",
            repo: "company/plugins",
            installLocation: nil,
            isManaged: false,
            networkScope: nil,
            archiveSourceID: nil)
        let firstArchive = ClaudePluginStore.Marketplace(
            name: "Company Plugins",
            source: "archive",
            repo: "https://plugins.example/teams/alpha/registry.json",
            installLocation: nil,
            isManaged: false,
            networkScope: nil,
            archiveSourceID: firstSourceID)
        let secondArchive = ClaudePluginStore.Marketplace(
            name: "Company Plugins",
            source: "archive",
            repo: "https://plugins.example/teams/beta/registry.json",
            installLocation: nil,
            isManaged: false,
            networkScope: nil,
            archiveSourceID: secondSourceID)
        let marketplaces = [native, firstArchive, secondArchive]

        XCTAssertEqual(
            resolvedClaudeMarketplaceTabTitle(native, among: marketplaces),
            "Company Plugins · Claude")
        XCTAssertEqual(
            resolvedClaudeMarketplaceTabTitle(firstArchive, among: marketplaces),
            "Company Plugins · plugins.example/teams/alpha/registry.json")
        XCTAssertEqual(
            resolvedClaudeMarketplaceTabTitle(secondArchive, among: marketplaces),
            "Company Plugins · plugins.example/teams/beta/registry.json")
    }

    @MainActor
    func testArchiveURLsWithFragmentsOrEmbeddedCredentialsAreUnavailable() throws {
        var source = MarketplaceSource()
        source.name = "Company Plugins"
        source.repo = "https://plugins.example/registry.json"
        source.format = .archiveRegistryV1

        let data = Data(#"""
        { "version": 1, "name": "Company Plugins", "plugins": [
          { "name": "fragment", "archive": "https://cdn.example/fragment.tar.gz#payload" },
          { "name": "credentials", "archive": "https://user:secret@cdn.example/plugin.tar.gz" }
        ] }
        """#.utf8)

        let decoded = try ClaudePluginStore.decodeArchiveCatalog(source: source, data: data)

        XCTAssertEqual(decoded.available.map(\.name), ["fragment", "credentials"])
        XCTAssertEqual(decoded.available.map(\.canInstall), [false, false])
        XCTAssertTrue(decoded.available.allSatisfy { $0.archiveInstall == nil })
        XCTAssertTrue(decoded.available.allSatisfy { $0.installUnavailableReason != nil })
    }

    @MainActor
    func testManagedSourcesAreSynthesizedOnlyForAuditedKindsAndFormats() throws {
        let archiveFormat = MarketplaceFormat.archiveRegistryV1.rawValue
        let profile = try JSONDecoder().decode(TenantProfile.self, from: Data("""
        {
          "tenantId": "acme", "displayName": "Mechanician for Acme",
          "extensions": { "allowPublic": true, "managedSources": [
            { "kind": "registry", "name": "Acme MCP", "url": "https://mcp.example.com/data/servers.json",
              "format": "generic", "networkScope": "vpnOnly",
              "governance": { "approvedStatuses": ["Approved", "Production"] } },
            { "kind": "marketplace", "name": "Acme Plugins", "url": "https://plugins.example/registry.json",
              "format": "\(archiveFormat)", "authentication": "googleIdentity", "networkScope": "vpnOnly" },
            { "kind": "registry", "name": "Unknown", "url": "https://example.com/servers",
              "format": "arbitrary-executable-adapter" },
            { "kind": "registry", "name": "Insecure", "url": "http://example.com/servers",
              "format": "officialV01" },
            { "kind": "marketplace", "name": "Insecure Plugins", "url": "http://example.com/plugins",
              "format": "\(archiveFormat)" }
          ] }
        }
        """.utf8))

        // Synthesis stays STRICT where stored user config is tolerant. A stored source naming a
        // retired format decodes to `generic` so an install is never orphaned; a signed profile
        // naming a format this build does not have is rejected outright, because a profile must not
        // be able to name an adapter that does not exist and have it silently become another one.
        let registries = ExtensionsStore.makeManagedRegistrySources(from: profile)
        let marketplaces = ExtensionsStore.makeManagedMarketplaceSources(from: profile)
        XCTAssertEqual(registries.count, 1)
        XCTAssertEqual(registries.first?.format, .generic)
        XCTAssertEqual(registries.first?.source, .managed)
        XCTAssertEqual(registries.first?.networkScope, .vpnOnly)
        XCTAssertEqual(registries.first?.governance?.approvedStatuses, ["Approved", "Production"])
        XCTAssertEqual(marketplaces.count, 1)
        XCTAssertEqual(marketplaces.first?.format, .archiveRegistryV1)
        XCTAssertEqual(marketplaces.first?.source, .managed)
        XCTAssertEqual(marketplaces.first?.authentication, .googleIdentity)

        let secondPass = ExtensionsStore.makeManagedRegistrySources(from: profile)
        XCTAssertEqual(registries.first?.id, secondPass.first?.id,
                       "managed identities must remain stable across view refreshes")
    }

    @MainActor
    func testManagedArchiveMarketplaceIdentitySurvivesEndpointRotation() throws {
        let archiveFormat = MarketplaceFormat.archiveRegistryV1.rawValue
        let installedProfile = try JSONDecoder().decode(TenantProfile.self, from: Data("""
        {
          "tenantId": "example-corp", "displayName": "Example Corp",
          "extensions": { "managedSources": [
            { "kind": "marketplace", "name": "Company Plugins",
              "url": "https://plugins-old.example/registry.json", "format": "\(archiveFormat)" }
          ] }
        }
        """.utf8))
        var rotatedProfile = installedProfile
        rotatedProfile.extensions.managedSources[0].url =
            "https://plugins-new.example/registry.json"

        let installedSource = try XCTUnwrap(
            ExtensionsStore.makeManagedMarketplaceSources(from: installedProfile).first)
        let rotatedSource = try XCTUnwrap(
            ExtensionsStore.makeManagedMarketplaceSources(from: rotatedProfile).first)
        XCTAssertNotEqual(installedSource.repo, rotatedSource.repo)
        XCTAssertEqual(installedSource.id, rotatedSource.id,
                       "rotating a managed endpoint must not orphan installed catalog plugins")

        let catalog = Data(#"""
        { "version": 1, "name": "Company Plugins", "plugins": [
          { "name": "operations", "archive": "/operations.tar.gz" }
        ] }
        """#.utf8)
        let installed = try ClaudePluginStore.decodeArchiveCatalog(
            source: installedSource, data: catalog)
        let rotated = try ClaudePluginStore.decodeArchiveCatalog(
            source: rotatedSource, data: catalog)
        XCTAssertEqual(installed.marketplace.id, rotated.marketplace.id)
        XCTAssertEqual(installed.available.first?.pluginId, rotated.available.first?.pluginId)
    }

    func testLegacyCatalogSourceDecodeDefaultsToPublicFormats() throws {
        let registry = try JSONDecoder().decode(
            RegistrySource.self,
            from: Data(#"{ "name": "Old", "url": "https://example.com/v0.1/servers", "enabled": true }"#.utf8))
        let marketplace = try JSONDecoder().decode(
            MarketplaceSource.self,
            from: Data(#"{ "name": "Old", "repo": "owner/repo", "enabled": true }"#.utf8))

        XCTAssertEqual(registry.format, .officialV01)
        XCTAssertNil(registry.source)
        XCTAssertNil(registry.networkScope)
        XCTAssertEqual(marketplace.format, .claudeMarketplace)
        XCTAssertNil(marketplace.source)
        XCTAssertNil(marketplace.networkScope)
    }

    /// MCP is a standard both providers implement, and the Codex lane now configures, mounts and
    /// reports servers of its own — so a maker filter is no longer the gate. `available` is.
    func testCodexLanesCanBeChosenForExtensions() {
        let selected = MCPAccessSelection.resolve(
            savedRawValue: ModelAccess.codexSubscription.rawValue,
            available: ModelAccess.allCases,
            profileDefault: nil,
            conversationDefault: nil,
            current: .claudeSubscription)

        XCTAssertEqual(selected, .codexSubscription)
    }

    /// A Codex conversation should land on the Codex lane rather than silently showing Claude's
    /// servers, which is what the old maker filter did.
    func testExtensionsFollowACodexConversationInsteadOfFallingBackToClaude() {
        let selected = MCPAccessSelection.resolve(
            savedRawValue: nil,
            available: ModelAccess.allCases,
            profileDefault: nil,
            conversationDefault: .codexSubscription,
            current: .codexSubscription)

        XCTAssertEqual(selected, .codexSubscription)
    }

    /// A lane the caller did not offer must never be selected, whatever was saved.
    func testAnUnavailableLaneIsNeverSelected() {
        let selected = MCPAccessSelection.resolve(
            savedRawValue: ModelAccess.codexSubscription.rawValue,
            available: [.claudeSubscription, .anthropicAPI],
            profileDefault: nil,
            conversationDefault: .codexSubscription,
            current: .codexSubscription)

        XCTAssertEqual(selected, .claudeSubscription)
    }
}
