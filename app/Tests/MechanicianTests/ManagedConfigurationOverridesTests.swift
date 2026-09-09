import XCTest
@testable import Mechanician

/// Local edits to a signed managed configuration.
///
/// The signed document is never rewritten — the app holds only the public key. These overrides are
/// layered on at resolution time so `TenantProfile.current` is the effective configuration. The
/// tests that matter most are the ones asserting what an override CANNOT do: the signature exists
/// to protect the fields that select code (an adapter, a source format, a stdio server's command)
/// and the credential binding that hands an enterprise identity token to a named host.
final class ManagedConfigurationOverridesTests: XCTestCase {
    private var temporaryDirectories: [URL] = []

    override func tearDownWithError() throws {
        for directory in temporaryDirectories {
            try? FileManager.default.removeItem(at: directory)
        }
        temporaryDirectories.removeAll()
    }

    private func temporarySupportDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MechanicianOverrides-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        temporaryDirectories.append(directory)
        return directory
    }

    private var acmeProfile: TenantProfile {
        TenantProfile(
            tenantId: "acme",
            displayName: "Mechanician",
            routes: [
                TenantProfile.Route(
                    routeId: "acme-claude-vertex",
                    displayName: "Claude (Acme · Vertex)",
                    adapter: "claude-vertex",
                    vertex: TenantProfile.Vertex(projectId: "acme-claude-code", region: "global"),
                    models: [TenantProfile.Model(
                        id: "claude-opus-4-8", displayName: "Opus 4.8", isDefault: true)],
                    isDefault: true),
            ],
            extensions: TenantProfile.ExtensionPolicy(
                allowPublic: true,
                managedSources: [
                    TenantProfile.ManagedSource(
                        kind: "registry", name: "Acme MCP Registry",
                        url: "https://mcp.example.com/data/servers.json", repo: nil,
                        format: "acmeV1", authentication: nil, networkScope: "vpnOnly"),
                    TenantProfile.ManagedSource(
                        kind: "marketplace", name: "Acme Plugins",
                        url: "https://plugins.acme.example/registry.json", repo: nil,
                        format: MarketplaceFormat.archiveRegistryV1.rawValue,
                        authentication: "googleIdentity",
                        networkScope: "vpnOnly"),
                ],
                managedServers: [
                    TenantProfile.ManagedServer(
                        name: "acme-tools", transport: "stdio", url: nil,
                        command: "/usr/local/bin/acme-mcp", args: ["--serve"], env: nil,
                        networkScope: "vpnOnly"),
                ]))
    }

    // MARK: What an override is for

    /// The case that started this: an administrator's project is wrong or stale and the user cannot
    /// wait for a newly signed document to get a working turn.
    func testTheVertexProjectAndRegionCanBeCorrectedLocally() {
        var overrides = ManagedConfigurationOverrides()
        overrides.routes["acme-claude-vertex"] = .init(
            vertexProjectId: "acme-claude-code-staging", vertexRegion: "us-east5", models: nil)

        let vertex = overrides.applied(to: acmeProfile).vertexConfig

        XCTAssertEqual(vertex?.projectId, "acme-claude-code-staging")
        XCTAssertEqual(vertex?.region, "us-east5")
    }

    /// The other half of the Opus 5 problem: when the deployment DOES gain a model, the user should
    /// be able to use it immediately rather than wait for a re-signed profile.
    func testAModelTheDeploymentGainsCanBeDeclaredLocally() {
        var overrides = ManagedConfigurationOverrides()
        overrides.routes["acme-claude-vertex"] = .init(
            vertexProjectId: nil, vertexRegion: nil,
            models: [
                TenantProfile.Model(id: "claude-opus-4-8", displayName: "Opus 4.8", isDefault: true),
                TenantProfile.Model(id: "claude-opus-5", displayName: "Opus 5", isDefault: false),
            ])

        let declared = overrides.applied(to: acmeProfile).declaredModels(for: .claudeVertex)

        XCTAssertEqual(declared.map(\.id), ["claude-opus-4-8", "claude-opus-5"])
        XCTAssertEqual(declared.first?.id, "claude-opus-4-8", "the default still leads")
    }

    /// Declaring nothing is a real choice, not an empty override: it returns the lane to the
    /// built-in list. It must therefore survive as an empty array rather than collapse to "unset".
    func testDeclaringNoModelsIsDistinctFromNotOverridingModels() {
        var cleared = ManagedConfigurationOverrides()
        cleared.routes["acme-claude-vertex"] = .init(
            vertexProjectId: nil, vertexRegion: nil, models: [])
        XCTAssertTrue(cleared.applied(to: acmeProfile).declaredModels(for: .claudeVertex).isEmpty)

        let untouched = ManagedConfigurationOverrides()
        XCTAssertEqual(
            untouched.applied(to: acmeProfile).declaredModels(for: .claudeVertex).map(\.id),
            ["claude-opus-4-8"])
    }

    func testAManagedSourceCanBeDisabledWithoutTouchingTheOthers() {
        var overrides = ManagedConfigurationOverrides()
        overrides.sources["Acme MCP Registry"] = .init(disabled: true, url: nil)

        let sources = overrides.applied(to: acmeProfile).extensions.managedSources

        XCTAssertEqual(sources.map(\.name), ["Acme Plugins"])
    }

    func testNoOverridesLeavesTheProfileExactlyAsSigned() {
        XCTAssertEqual(ManagedConfigurationOverrides().applied(to: acmeProfile), acmeProfile)
    }

    // MARK: What an override must never do

    /// The non-negotiable rule. `googleIdentity` sends the user's enterprise Google identity token
    /// to the URL. A token minted for the host an administrator published must never follow a URL
    /// someone typed into a text field — that would turn an editable field into credential
    /// exfiltration.
    func testRepointingAnAuthenticatedSourceStripsItsManagedSignIn() {
        var overrides = ManagedConfigurationOverrides()
        overrides.sources["Acme Plugins"] = .init(
            disabled: nil, url: "https://attacker.invalid/registry.json")

        let source = overrides.applied(to: acmeProfile)
            .extensions.managedSources.first { $0.name == "Acme Plugins" }

        XCTAssertEqual(source?.url, "https://attacker.invalid/registry.json")
        XCTAssertNil(source?.authentication, "the identity token must not follow a user-typed host")
    }

    /// Editing something else about the same source, or re-typing the SAME url, is not a re-point
    /// and must not cost the managed sign-in.
    func testAnUnchangedURLKeepsItsManagedSignIn() {
        var overrides = ManagedConfigurationOverrides()
        overrides.sources["Acme Plugins"] = .init(
            disabled: nil, url: "https://plugins.acme.example/registry.json")

        let source = overrides.applied(to: acmeProfile)
            .extensions.managedSources.first { $0.name == "Acme Plugins" }

        XCTAssertEqual(source?.authentication, "googleIdentity")
    }

    /// A stdio managed server names a COMMAND to launch. That is the single most dangerous thing a
    /// profile can carry, and it is the reason the document is signed at all — no override may add,
    /// remove or alter one.
    func testManagedServersAreNotOverridable() {
        var overrides = ManagedConfigurationOverrides()
        overrides.routes["acme-claude-vertex"] = .init(
            vertexProjectId: "elsewhere", vertexRegion: nil, models: [])
        overrides.sources["Acme Plugins"] = .init(disabled: true, url: nil)

        let applied = overrides.applied(to: acmeProfile)

        XCTAssertEqual(applied.extensions.managedServers, acmeProfile.extensions.managedServers)
        XCTAssertEqual(applied.extensions.managedServers.first?.command,
                       "/usr/local/bin/acme-mcp")
    }

    /// Values that select which audited code path runs are fixed by the signature.
    func testAdapterRouteIdAndSourceFormatAreNotOverridable() {
        var overrides = ManagedConfigurationOverrides()
        overrides.routes["acme-claude-vertex"] = .init(
            vertexProjectId: "p", vertexRegion: "r", models: [])
        overrides.sources["Acme MCP Registry"] = .init(
            disabled: nil, url: "https://elsewhere.example/servers.json")

        let applied = overrides.applied(to: acmeProfile)

        XCTAssertEqual(applied.routes.first?.adapter, "claude-vertex")
        XCTAssertEqual(applied.routes.first?.routeId, "acme-claude-vertex")
        XCTAssertEqual(applied.extensions.managedSources.first?.format, "acmeV1")
        XCTAssertEqual(applied.tenantId, "acme")
    }

    // MARK: Persistence

    func testOverridesRoundTripThroughTheirOwnFile() throws {
        let directory = try temporarySupportDirectory()
        let environment = ["MECHANICIAN_SUPPORT_DIR": directory.path]
        var overrides = ManagedConfigurationOverrides()
        overrides.routes["acme-claude-vertex"] = .init(
            vertexProjectId: "other-project", vertexRegion: nil, models: nil)

        try overrides.save(environment: environment, homeDirectory: directory)
        let loaded = ManagedConfigurationOverrides.load(
            environment: environment, homeDirectory: directory)

        XCTAssertEqual(loaded, overrides)
    }

    /// Saving an empty set removes the file rather than leaving `{}` behind, so "no overrides" and
    /// "never had overrides" are the same state on disk.
    func testResettingEverythingRemovesTheOverrideFile() throws {
        let directory = try temporarySupportDirectory()
        let environment = ["MECHANICIAN_SUPPORT_DIR": directory.path]
        var overrides = ManagedConfigurationOverrides()
        overrides.sources["Acme Plugins"] = .init(disabled: true, url: nil)
        try overrides.save(environment: environment, homeDirectory: directory)

        try ManagedConfigurationOverrides().save(
            environment: environment, homeDirectory: directory)

        let url = ManagedConfigurationOverrides.fileURL(
            environment: environment, homeDirectory: directory)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        XCTAssertTrue(ManagedConfigurationOverrides.load(
            environment: environment, homeDirectory: directory).isEmpty)
    }

    /// A corrupt override file must degrade to "the signed profile alone", never fail the launch
    /// that resolves the configuration.
    func testACorruptOverrideFileLeavesTheSignedProfileIntact() throws {
        let directory = try temporarySupportDirectory()
        let environment = ["MECHANICIAN_SUPPORT_DIR": directory.path]
        let url = ManagedConfigurationOverrides.fileURL(
            environment: environment, homeDirectory: directory)
        try Data("{ not json at all".utf8).write(to: url)

        let loaded = ManagedConfigurationOverrides.load(
            environment: environment, homeDirectory: directory)

        XCTAssertTrue(loaded.isEmpty)
        XCTAssertEqual(loaded.applied(to: acmeProfile), acmeProfile)
    }
}

// MARK: - Authoring a configuration with no profile to start from
//
// Until this existed, the ONLY way to get a Vertex lane was a signed profile someone else
// published — so a user starting from nothing had no path at all. Authoring locally produces the
// same shapes a profile declares, which is what lets the result be exported, signed and handed out.

extension ManagedConfigurationOverridesTests {
    private var vertexRoute: TenantProfile.Route {
        TenantProfile.Route(
            routeId: "local-claude-vertex-1",
            displayName: "Claude (Vertex)",
            adapter: "claude-vertex",
            vertex: TenantProfile.Vertex(projectId: "my-gcp-project", region: "us-east5"),
            models: [TenantProfile.Model(
                id: "claude-opus-4-8", displayName: "Opus 4.8",
                supportedEfforts: ["low", "medium", "high", "xhigh", "max"],
                isDefault: true)],
            isDefault: true)
    }

    func testARouteCanBeAuthoredWithNoProfileAtAll() {
        var overrides = ManagedConfigurationOverrides()
        overrides.addedRoutes = [vertexRoute]

        let applied = overrides.applied(to: .default)

        XCTAssertEqual(applied.vertexConfig?.projectId, "my-gcp-project")
        XCTAssertEqual(applied.vertexConfig?.region, "us-east5")
        XCTAssertEqual(applied.declaredModels(for: .claudeVertex).map(\.id), ["claude-opus-4-8"])
    }

    /// `ModelAccess.allCases` is `builtInCases + enterpriseAccesses`, so this assertion is what
    /// makes the lane exist in the picker at all — the whole point of authoring one.
    func testAnAuthoredRouteActivatesItsLane() {
        var overrides = ManagedConfigurationOverrides()
        overrides.addedRoutes = [vertexRoute]

        XCTAssertTrue(overrides.applied(to: .default).enterpriseAccesses.contains(.claudeVertex))
        XCTAssertFalse(TenantProfile.default.enterpriseAccesses.contains(.claudeVertex))
    }

    /// `isDefault` is purely `tenantId == "default"` and a great deal of the app keys off it, so a
    /// configuration that exists must stop claiming to be the empty one.
    func testAnAuthoredConfigurationStopsLookingLikeNoConfiguration() {
        XCTAssertTrue(TenantProfile.default.isDefault)

        var overrides = ManagedConfigurationOverrides()
        overrides.addedRoutes = [vertexRoute]
        let applied = overrides.applied(to: .default)

        XCTAssertFalse(applied.isDefault)
        XCTAssertEqual(applied.tenantId, ManagedConfigurationOverrides.defaultLocalTenantId)
    }

    /// An adapter selects which audited runtime executes. Only one is implemented, so anything else
    /// would produce a configuration that silently does nothing — refuse it at the boundary rather
    /// than let a hand-edited override file introduce it.
    func testAnAuthoredRouteCannotNameAnUnauditedAdapter() {
        var overrides = ManagedConfigurationOverrides()
        overrides.addedRoutes = [
            TenantProfile.Route(routeId: "r", adapter: "claude-subscription"),
            TenantProfile.Route(routeId: "s", adapter: "anything-else"),
            vertexRoute,
        ]

        let applied = overrides.applied(to: .default)

        XCTAssertEqual(applied.routes.map(\.adapter), ["claude-vertex"])
    }

    /// Same rule as re-pointing a published source: an authored source never receives the user's
    /// enterprise Google identity token, whatever the override file says.
    func testAnAuthoredSourceNeverCarriesAManagedSignIn() {
        var overrides = ManagedConfigurationOverrides()
        overrides.addedSources = [TenantProfile.ManagedSource(
            kind: "marketplace", name: "Mine", url: "https://mine.example/registry.json",
            repo: nil, format: "claudeMarketplace", authentication: "googleIdentity",
            networkScope: "public")]

        let source = overrides.applied(to: .default).extensions.managedSources.first

        XCTAssertEqual(source?.name, "Mine")
        XCTAssertNil(source?.authentication)
    }

    func testAnAuthoredSourceMustBeHTTPS() {
        var overrides = ManagedConfigurationOverrides()
        overrides.addedSources = [
            TenantProfile.ManagedSource(kind: "registry", name: "Insecure",
                                        url: "http://plain.example/servers.json", repo: nil,
                                        format: "officialV01", authentication: nil,
                                        networkScope: "public"),
            TenantProfile.ManagedSource(kind: "registry", name: "Fine",
                                        url: "https://secure.example/servers.json", repo: nil,
                                        format: "officialV01", authentication: nil,
                                        networkScope: "public"),
        ]

        XCTAssertEqual(
            overrides.applied(to: .default).extensions.managedSources.map(\.name), ["Fine"])
    }

    /// Authoring is only worth doing if the result can leave the machine. The export has to decode
    /// back into the same configuration, or "build it here, sign it, hand it out" is a dead end.
    func testAnAuthoredConfigurationRoundTripsThroughItsExportedDocument() throws {
        var overrides = ManagedConfigurationOverrides()
        overrides.addedRoutes = [vertexRoute]
        overrides.addedSources = [TenantProfile.ManagedSource(
            kind: "registry", name: "Team Registry",
            url: "https://registry.example/servers.json", repo: nil,
            format: "officialV01", authentication: nil, networkScope: "public")]
        let authored = overrides.applied(to: .default)

        let document = ManagedConfigurationOverrides.exportableProfile(from: authored)
        let data = try JSONSerialization.data(withJSONObject: document)
        let decoded = try JSONDecoder().decode(TenantProfile.self, from: data)

        XCTAssertEqual(decoded.tenantId, authored.tenantId)
        XCTAssertEqual(decoded.routes.map(\.routeId), authored.routes.map(\.routeId))
        XCTAssertEqual(decoded.vertexConfig, authored.vertexConfig)
        XCTAssertEqual(decoded.declaredModels(for: .claudeVertex),
                       authored.declaredModels(for: .claudeVertex))
        XCTAssertEqual(decoded.extensions.managedSources.map(\.name),
                       authored.extensions.managedSources.map(\.name))
        XCTAssertEqual(decoded.extensions.allowPublic, authored.extensions.allowPublic)
    }

    /// The bug that made authoring look broken: with no profile file, `resolve` returned early and
    /// never loaded overrides, so "create a configuration from nothing" saved a document the app
    /// then ignored on every launch. Caught only by running it, not by any unit test.
    @MainActor
    func testAnAuthoredConfigurationAppliesWhenNoProfileIsInstalled() throws {
        let directory = try temporarySupportDirectory()
        let environment = ["MECHANICIAN_SUPPORT_DIR": directory.path]
        var overrides = ManagedConfigurationOverrides()
        overrides.addedRoutes = [vertexRoute]
        try overrides.save(environment: environment, homeDirectory: directory)

        let resolution = TenantProfile.resolve(
            bundleIdentifier: MechanicianEnvironment.baseBundleIdentifier,
            environment: environment,
            homeDirectory: directory,
            publicKey: TenantProfile.profileSigningPublicKey)

        XCTAssertEqual(resolution.profile.vertexConfig?.projectId, "my-gcp-project")
        XCTAssertTrue(resolution.profile.enterpriseAccesses.contains(.claudeVertex))
        XCTAssertFalse(resolution.profile.isDefault)
        // The signed side stays empty: nothing was published, so there is nothing to diff against.
        XCTAssertTrue(resolution.signed.isDefault)
        XCTAssertNil(resolution.sourceURL)
    }

    /// Exporting a PUBLISHED profile must carry its managed servers through untouched — otherwise
    /// re-signing an exported document would quietly strip capability an administrator relies on.
    func testExportingAPublishedProfileKeepsItsManagedServers() throws {
        let document = ManagedConfigurationOverrides.exportableProfile(from: acmeProfile)
        let data = try JSONSerialization.data(withJSONObject: document)
        let decoded = try JSONDecoder().decode(TenantProfile.self, from: data)

        XCTAssertEqual(decoded.extensions.managedServers, acmeProfile.extensions.managedServers)
        XCTAssertEqual(decoded.extensions.managedSources.first { $0.name == "Acme Plugins" }?
            .authentication, "googleIdentity")
    }
}

// MARK: - Claude on AWS Bedrock
//
// The second backend a configuration can add. Bedrock differs from Vertex in the way that matters
// most for this app: it needs no credential broker at all. Vertex required an OAuth loopback and an
// app-managed ADC file; Bedrock resolves the ordinary AWS chain inside the engine process, exactly
// as the `aws` CLI does. So the configuration carries endpoint SELECTION only, never a secret.

extension ManagedConfigurationOverridesTests {
    private var bedrockRoute: TenantProfile.Route {
        TenantProfile.Route(
            routeId: "local-claude-bedrock-1",
            displayName: "Claude (Bedrock)",
            adapter: "claude-bedrock",
            bedrock: TenantProfile.Bedrock(region: "us-west-2", profile: "engineering"),
            models: [TenantProfile.Model(
                id: "global.anthropic.claude-opus-4-8", displayName: "Opus 4.8", isDefault: true)],
            isDefault: true)
    }

    func testABedrockRouteCanBeAuthoredAndActivatesItsLane() {
        var overrides = ManagedConfigurationOverrides()
        overrides.addedRoutes = [bedrockRoute]

        let applied = overrides.applied(to: .default)

        XCTAssertEqual(applied.bedrockConfig?.region, "us-west-2")
        XCTAssertEqual(applied.bedrockConfig?.profile, "engineering")
        XCTAssertTrue(applied.enterpriseAccesses.contains(.claudeBedrock))
        XCTAssertEqual(applied.declaredModels(for: .claudeBedrock).map(\.id),
                       ["global.anthropic.claude-opus-4-8"])
    }

    /// The whole reason a configuration is safe to email: it selects an endpoint and names a profile
    /// the user already has. If AWS keys could live here, every exported document would be a
    /// credential leak waiting to happen.
    func testAnExportedBedrockConfigurationCarriesNoCredentials() throws {
        var overrides = ManagedConfigurationOverrides()
        overrides.addedRoutes = [bedrockRoute]

        let document = ManagedConfigurationOverrides.exportableProfile(
            from: overrides.applied(to: .default))
        let json = String(decoding: try JSONSerialization.data(withJSONObject: document), as: UTF8.self)

        XCTAssertTrue(json.contains("us-west-2"))
        XCTAssertTrue(json.contains("engineering"), "a profile NAME is a selector, not a secret")
        for secret in ["aws_access_key", "AWS_ACCESS_KEY_ID", "secretAccessKey", "sessionToken"] {
            XCTAssertFalse(json.lowercased().contains(secret.lowercased()),
                           "a configuration must never carry \(secret)")
        }
    }

    func testABedrockConfigurationRoundTripsThroughItsExportedDocument() throws {
        var overrides = ManagedConfigurationOverrides()
        overrides.addedRoutes = [bedrockRoute]
        let authored = overrides.applied(to: .default)

        let data = try JSONSerialization.data(
            withJSONObject: ManagedConfigurationOverrides.exportableProfile(from: authored))
        let decoded = try JSONDecoder().decode(TenantProfile.self, from: data)

        XCTAssertEqual(decoded.bedrockConfig, authored.bedrockConfig)
        XCTAssertEqual(decoded.routes.first?.adapter, "claude-bedrock")
    }

    /// Two AWS profiles are two accounts. A session or cached credential from one must never be
    /// reused under the other, which is what makes the profile part of the route identity.
    func testTheAWSProfileParticipatesInRouteIdentity() {
        var engineering = ManagedConfigurationOverrides()
        engineering.addedRoutes = [bedrockRoute]
        var production = ManagedConfigurationOverrides()
        var other = bedrockRoute
        other.bedrock = TenantProfile.Bedrock(region: "us-west-2", profile: "production")
        production.addedRoutes = [other]

        let a = engineering.applied(to: .default).routeIdentity(for: .claudeBedrock)
        let b = production.applied(to: .default).routeIdentity(for: .claudeBedrock)

        XCTAssertNotNil(a)
        XCTAssertNotEqual(a, b)
        // And a Bedrock route never collides with a Vertex one.
        var vertex = ManagedConfigurationOverrides()
        vertex.addedRoutes = [vertexRoute]
        XCTAssertNil(vertex.applied(to: .default).routeIdentity(for: .claudeBedrock))
    }

    /// Bedrock uses its own model ids. A route declaring Anthropic-style ids would offer ids AWS has
    /// never heard of — the same class of failure as `default` on Vertex.
    ///
    /// These were WRONG on first write: `us.anthropic.claude-opus-5-v1:0` and friends were guessed
    /// from the cross-region inference-profile convention, and a live account has no such profile —
    /// `list-inference-profiles` carries only older models, while the current generation is
    /// published as bare foundation ids. Corrected from the API, which is the only authority.
    @MainActor
    func testBedrockBuiltInModelsUseBedrockIDsNotAnthropicIDs() {
        let ids = AgentBridge.builtInModels(for: .claudeBedrock).map(\.1)

        // Verified by invoking against a live account: the invokable id is a cross-region
        // inference profile. A bare `anthropic.*` foundation id fails with "on-demand throughput
        // isn't supported", and Anthropic's own id is unknown to Bedrock entirely.
        XCTAssertTrue(ids.allSatisfy { $0.hasPrefix("global.anthropic.") || $0.hasPrefix("us.anthropic.") })
        XCTAssertFalse(ids.contains("claude-opus-4-8"), "that is the Anthropic API id, not Bedrock's")
        XCTAssertFalse(ids.contains("anthropic.claude-opus-4-8"),
                       "a bare foundation id is not invokable on demand")
        XCTAssertEqual(ids.first, "global.anthropic.claude-opus-4-8",
                       "the conservative generation leads, as it does for Vertex")
    }

    /// Bedrock is credential-brokered by AWS, not by Mechanician, so it must not be dragged into the
    /// interactive connect/reconnect state machine that Claude, Codex and Vertex share.
    func testBedrockIsNotAnInteractiveAccountLane() {
        XCTAssertFalse(ModelAccess.claudeBedrock.usesInteractiveAccountFlow)
        XCTAssertTrue(ModelAccess.claudeVertex.usesInteractiveAccountFlow)
        XCTAssertEqual(ModelAccess.claudeBedrock.maker, .anthropic)
        XCTAssertEqual(ModelAccess(adapter: "claude-bedrock"), .claudeBedrock)
        XCTAssertEqual(ModelAccess(provider: "anthropic", authMode: "bedrock"), .claudeBedrock)
    }
}
