import XCTest
import CryptoKit
@testable import Mechanician

final class TenantProfileTests: XCTestCase {
    private var temporaryDirectories: [URL] = []

    override func tearDownWithError() throws {
        for directory in temporaryDirectories {
            try? FileManager.default.removeItem(at: directory)
        }
        temporaryDirectories.removeAll()
    }

    private func decode(_ json: String) throws -> TenantProfile {
        try JSONDecoder().decode(TenantProfile.self, from: Data(json.utf8))
    }

    private func temporaryHome() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MechanicianTenantProfileTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        temporaryDirectories.append(directory)
        return directory
    }

    private func signedEnvelope(
        profileJSON: String,
        privateKey: Curve25519.Signing.PrivateKey,
        documentVersion: Int = 1
    ) throws -> Data {
        let profileData = Data(profileJSON.utf8)
        let profileObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: profileData) as? [String: Any])
        let payload = try TenantProfile.canonicalSignedPayload(
            documentVersion: documentVersion,
            profileJSONObject: profileObject)
        let signature = try privateKey.signature(for: payload).base64EncodedString()
        return try JSONSerialization.data(withJSONObject: [
            "documentVersion": documentVersion,
            "profile": profileObject,
            "signature": signature,
        ], options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    }

    private func defaultProfileURL(home: URL) -> URL {
        home.appendingPathComponent("Library/Application Support/Mechanician", isDirectory: true)
            .appendingPathComponent(TenantProfile.profileFileName)
    }

    private func managedConfiguration(
        _ document: [String: Any]
    ) -> ManagedEnterprisePolicy.Resolution {
        let suiteName = "TenantProfileManagedConfigurationTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.set(document, forKey: ManagedEnterprisePolicy.preferenceKey)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        return ManagedEnterprisePolicy.resolve(defaults: defaults, forcedOverride: true)
    }

    func testDefaultProfileIsPublicEquivalent() {
        let p = TenantProfile.default
        XCTAssertTrue(p.isDefault)
        XCTAssertTrue(p.routes.isEmpty)
        XCTAssertTrue(p.extensions.allowPublic)
        XCTAssertTrue(p.extensions.managedSources.isEmpty)
        XCTAssertTrue(p.extensions.managedServers.isEmpty)
    }

    func testFullAcmeShapedProfileDecodes() throws {
        let p = try decode(#"""
        {
          "schemaVersion": 1,
          "tenantId": "acme",
          "displayName": "Mechanician for Acme",
          "bundleIdentifier": "ai.mechanician.app.acme",
          "branding": { "iconRef": "acme.icns", "dmgVolumeName": "Mechanician for Acme",
                        "supportURL": "https://claude-code.example.com", "copyright": "© 2026 Magic & Lasers" },
          "update": { "feedURL": "https://storage.googleapis.com/mechanician-acme-updates/appcast.xml",
                      "publicEDKey": "TENANTKEY=" },
          "routes": [
            { "routeId": "acme-claude-vertex", "displayName": "Claude (Acme · Vertex)",
              "adapter": "claude-vertex", "vertex": { "projectId": "acme-claude-code", "region": "global" },
              "default": true }
          ],
          "extensions": {
            "allowPublic": true,
            "managedSources": [
              { "kind": "registry", "name": "Acme MCP Registry", "url": "https://vpn.acme/v0.1/servers",
                "format": "officialV01", "networkScope": "vpnOnly" }
            ],
            "managedServers": [
              { "name": "acme-internal", "transport": "http", "url": "https://vpn.acme/mcp",
                "networkScope": "vpnOnly" }
            ]
          },
          "portal": { "downloadDomain": "acme.com", "url": "https://magicandlasers.example/acme" }
        }
        """#)

        XCTAssertFalse(p.isDefault)
        XCTAssertEqual(p.tenantId, "acme")
        XCTAssertEqual(p.bundleIdentifier, "ai.mechanician.app.acme")
        XCTAssertEqual(p.routes.count, 1)
        let route = try XCTUnwrap(p.routes.first)
        XCTAssertEqual(route.routeId, "acme-claude-vertex")
        XCTAssertEqual(route.adapter, "claude-vertex")
        XCTAssertTrue(route.isDefault)                              // "default" key → isDefault
        XCTAssertEqual(route.vertex?.projectId, "acme-claude-code")
        XCTAssertEqual(route.vertex?.region, "global")
        XCTAssertEqual(p.defaultAccess, .claudeVertex)
        XCTAssertTrue(p.extensions.allowPublic)
        XCTAssertEqual(p.extensions.managedSources.first?.networkScope, "vpnOnly")
        XCTAssertEqual(p.extensions.managedServers.first?.name, "acme-internal")
        XCTAssertEqual(p.portal?.downloadDomain, "acme.com")
    }

    func testPartialProfileDegradesTowardPublic() throws {
        // Only the two required fields — every section omitted must fall back to public-equivalent.
        let p = try decode(#"{ "tenantId": "acme", "displayName": "Mechanician for Acme" }"#)
        XCTAssertEqual(p.schemaVersion, 1)
        XCTAssertEqual(p.tenantId, "acme")
        XCTAssertTrue(p.routes.isEmpty)
        XCTAssertTrue(p.extensions.allowPublic)
        XCTAssertNil(p.update)
        XCTAssertNil(p.portal)
        XCTAssertNil(p.branding.iconRef)
    }

    func testRouteDefaultsToNonDefaultWhenKeyOmitted() throws {
        let p = try decode(#"""
        { "tenantId": "acme", "displayName": "Acme",
          "routes": [ { "routeId": "acme-vertex", "adapter": "claude-vertex" } ] }
        """#)
        XCTAssertEqual(p.routes.first?.isDefault, false)
        XCTAssertNil(p.routes.first?.displayName)
    }

    func testEnterpriseRouteStorageIsStableAndTenantScoped() {
        let route = TenantProfile.Route(
            routeId: "shared-vertex",
            adapter: "claude-vertex",
            vertex: .init(projectId: "project", region: "global"))
        let northwind = TenantProfile(
            tenantId: "northwind", displayName: "Northwind", routes: [route])
        let acme = TenantProfile(
            tenantId: "acme", displayName: "Acme", routes: [route])
        let support = URL(fileURLWithPath: "/tmp/Mechanician", isDirectory: true)

        XCTAssertTrue(northwind.routeIdentity(for: .claudeVertex)?.hasPrefix("route-v1:") == true)
        XCTAssertNotEqual(
            northwind.routeStorageComponent(for: .claudeVertex),
            acme.routeStorageComponent(for: .claudeVertex))
        XCTAssertTrue(northwind.routeConfigDirectory(
            for: .claudeVertex, supportDirectory: support)?.path.hasPrefix(
                "/tmp/Mechanician/provider-routes/") == true)
        XCTAssertNil(northwind.routeConfigDirectory(
            for: .claudeSubscription, supportDirectory: support))

        var changedBackend = acme
        changedBackend.routes[0].vertex?.projectId = "another-project"
        XCTAssertNotEqual(
            northwind.routeIdentity(for: .claudeVertex),
            changedBackend.routeIdentity(for: .claudeVertex))

        var changedExtensions = northwind
        changedExtensions.extensions.managedSources = [
            .init(kind: "registry", name: "Catalog", url: "https://example.com/catalog.json"),
        ]
        XCTAssertEqual(
            northwind.routeIdentity(for: .claudeVertex),
            changedExtensions.routeIdentity(for: .claudeVertex))
    }

    func testMissingRequiredFieldThrows() {
        XCTAssertThrowsError(try decode(#"{ "displayName": "no tenant id" }"#))
    }

    func testEnterpriseBundleRequiresMatchingProfileIdentity() throws {
        let profile = try decode(#"""
        { "tenantId": "acme", "displayName": "Acme",
          "bundleIdentifier": "ai.mechanician.app.acme" }
        """#)
        XCTAssertNil(TenantProfile.configurationError(
            profile: profile, bundleIdentifier: "ai.mechanician.app.acme"))
        XCTAssertNotNil(TenantProfile.configurationError(
            profile: .default, bundleIdentifier: "ai.mechanician.app.acme"))
        XCTAssertNotNil(TenantProfile.configurationError(
            profile: profile, bundleIdentifier: "ai.mechanician.app.other"))
        XCTAssertNil(TenantProfile.configurationError(
            profile: .default, bundleIdentifier: "ai.mechanician.app"))
        XCTAssertNil(TenantProfile.configurationError(
            profile: .default, bundleIdentifier: "ai.mechanician.app.dev"))
        XCTAssertNil(TenantProfile.configurationError(
            profile: profile, bundleIdentifier: "ai.mechanician.app"))
    }

    func testMissingOptionalProfileLeavesStandardAppUnconfigured() throws {
        let home = try temporaryHome()
        let key = Curve25519.Signing.PrivateKey()

        let resolution = TenantProfile.resolve(
            bundleIdentifier: MechanicianEnvironment.baseBundleIdentifier,
            environment: [:],
            homeDirectory: home,
            publicKey: key.publicKey.rawRepresentation)

        XCTAssertTrue(resolution.profile.isDefault)
        XCTAssertNil(resolution.sourceURL)
        XCTAssertNil(resolution.error)
    }

    func testValidSignedProfileLoadsFromStandardAppSupportDirectory() throws {
        let home = try temporaryHome()
        let key = Curve25519.Signing.PrivateKey()
        let profileURL = defaultProfileURL(home: home)
        try FileManager.default.createDirectory(
            at: profileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try signedEnvelope(profileJSON: #"""
        {
          "schemaVersion": 1,
          "tenantId": "acme",
          "displayName": "Mechanician for Acme",
          "bundleIdentifier": "ai.mechanician.app.acme",
          "branding": { "iconRef": "Other.icns", "supportURL": "https://example.invalid" },
          "update": { "feedURL": "https://example.invalid/appcast.xml", "publicEDKey": "wrong" },
          "routes": [
            { "routeId": "acme-vertex", "displayName": "Claude (Acme · Vertex)",
              "adapter": "claude-vertex",
              "vertex": { "projectId": "acme-claude-code", "region": "global" },
              "default": true }
          ],
          "extensions": {
            "allowPublic": true,
            "managedSources": [
              { "kind": "registry", "name": "Acme MCP Registry",
                "url": "https://mcp.example.com/data/servers.json", "format": "acmeV1",
                "networkScope": "vpnOnly" }
            ]
          },
          "portal": { "url": "https://example.invalid/acme" }
        }
        """#, privateKey: key).write(to: profileURL)

        let resolution = TenantProfile.resolve(
            bundleIdentifier: MechanicianEnvironment.baseBundleIdentifier,
            environment: [:],
            homeDirectory: home,
            publicKey: key.publicKey.rawRepresentation)

        XCTAssertNil(resolution.error)
        XCTAssertEqual(resolution.sourceURL, profileURL)
        XCTAssertEqual(resolution.profile.tenantId, "acme")
        XCTAssertEqual(resolution.profile.displayName, "Mechanician")
        XCTAssertNil(resolution.profile.bundleIdentifier)
        XCTAssertEqual(resolution.profile.branding, TenantProfile.default.branding)
        XCTAssertNil(resolution.profile.update)
        XCTAssertNil(resolution.profile.portal)
        XCTAssertEqual(resolution.profile.defaultAccess, .claudeVertex)
        XCTAssertEqual(resolution.profile.vertexConfig?.projectId, "acme-claude-code")
        XCTAssertEqual(resolution.profile.extensions.managedSources.count, 1)
    }

    func testSettingsInstallerUsesLaunchProfileLocationAndCanRemoveIt() throws {
        let home = try temporaryHome()
        let key = Curve25519.Signing.PrivateKey()
        let data = try signedEnvelope(profileJSON: #"""
        {
          "tenantId": "acme",
          "displayName": "Acme",
          "routes": [
            { "routeId": "acme-vertex", "adapter": "claude-vertex",
              "vertex": { "projectId": "acme-claude-code", "region": "global" } }
          ]
        }
        """#, privateKey: key)

        let installed = try TenantProfile.installSignedProfile(
            data,
            environment: [:],
            homeDirectory: home,
            publicKey: key.publicKey.rawRepresentation)

        XCTAssertEqual(installed.tenantId, "acme")
        XCTAssertTrue(FileManager.default.fileExists(atPath: defaultProfileURL(home: home).path))
        XCTAssertEqual(
            try TenantProfile.loadInstalledProfile(
                environment: [:],
                homeDirectory: home,
                publicKey: key.publicKey.rawRepresentation)?.vertexConfig?.projectId,
            "acme-claude-code")

        let resolution = TenantProfile.resolve(
            bundleIdentifier: MechanicianEnvironment.baseBundleIdentifier,
            environment: [:],
            homeDirectory: home,
            publicKey: key.publicKey.rawRepresentation)
        XCTAssertEqual(resolution.profile.tenantId, "acme")

        try TenantProfile.removeInstalledProfile(environment: [:], homeDirectory: home)
        XCTAssertFalse(FileManager.default.fileExists(atPath: defaultProfileURL(home: home).path))
    }

    func testInvalidImportCannotReplaceInstalledProfile() throws {
        let home = try temporaryHome()
        let key = Curve25519.Signing.PrivateKey()
        let validData = try signedEnvelope(
            profileJSON: #"{ "tenantId": "acme", "displayName": "Acme" }"#,
            privateKey: key)
        try TenantProfile.installSignedProfile(
            validData,
            environment: [:],
            homeDirectory: home,
            publicKey: key.publicKey.rawRepresentation)

        XCTAssertThrowsError(try TenantProfile.installSignedProfile(
            Data("not a signed profile".utf8),
            environment: [:],
            homeDirectory: home,
            publicKey: key.publicKey.rawRepresentation))

        XCTAssertEqual(try Data(contentsOf: defaultProfileURL(home: home)), validData)
    }

    func testTamperedSignedProfileFailsClosed() throws {
        let home = try temporaryHome()
        let key = Curve25519.Signing.PrivateKey()
        let profileURL = defaultProfileURL(home: home)
        try FileManager.default.createDirectory(
            at: profileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        var envelope = try signedEnvelope(
            profileJSON: #"{ "tenantId": "acme", "displayName": "Acme" }"#,
            privateKey: key)
        let original = try XCTUnwrap(String(data: envelope, encoding: .utf8))
        envelope = Data(original.replacingOccurrences(of: "acme", with: "attacker").utf8)
        try envelope.write(to: profileURL)

        let resolution = TenantProfile.resolve(
            bundleIdentifier: MechanicianEnvironment.baseBundleIdentifier,
            environment: [:],
            homeDirectory: home,
            publicKey: key.publicKey.rawRepresentation)

        XCTAssertTrue(resolution.profile.isDefault)
        XCTAssertNotNil(resolution.sourceURL)
        XCTAssertTrue(resolution.error?.contains("signature is invalid") == true)
    }

    func testMDMSignedProfileTakesPrecedenceOverExplicitLocalProfile() throws {
        let home = try temporaryHome()
        let key = Curve25519.Signing.PrivateKey()
        let localURL = defaultProfileURL(home: home)
        try FileManager.default.createDirectory(
            at: localURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let localData = try signedEnvelope(
            profileJSON: #"{ "tenantId": "local", "displayName": "Local" }"#,
            privateKey: key)
        try localData.write(to: localURL)

        let managedData = try signedEnvelope(
            profileJSON: #"{ "tenantId": "managed", "displayName": "Managed" }"#,
            privateKey: key)
        let managed = managedConfiguration([
            "schemaVersion": 1,
            "signedProfile": managedData,
            "policy": ["allowLocalConfigurationOverrides": false],
        ])

        let resolution = TenantProfile.resolve(
            bundleIdentifier: MechanicianEnvironment.baseBundleIdentifier,
            environment: [TenantProfile.profilePathEnvironmentVariable: localURL.path],
            homeDirectory: home,
            publicKey: key.publicKey.rawRepresentation,
            managedConfiguration: managed)

        XCTAssertNil(resolution.error)
        XCTAssertTrue(resolution.managedByMDM)
        XCTAssertNil(resolution.sourceURL)
        XCTAssertEqual(resolution.profile.tenantId, "managed")
        XCTAssertEqual(resolution.signed.tenantId, "managed")
        XCTAssertEqual(try Data(contentsOf: localURL), localData)
    }

    func testManagedOnlyProfileRejectsServerSnapshotTooLargeForDaemonTransport() throws {
        let home = try temporaryHome()
        let key = Curve25519.Signing.PrivateKey()
        let servers: [[String: Any]] = (0..<100).map { index in
            [
                "name": "managed-server-\(index)",
                "transport": "http",
                "url": "https://tools.example.invalid/managed/\(index)/"
                    + String(repeating: "x", count: 800),
            ]
        }
        let profileObject: [String: Any] = [
            "tenantId": "managed",
            "displayName": "Managed",
            "extensions": [
                "allowPublic": false,
                "managedServers": servers,
            ],
        ]
        let profileData = try JSONSerialization.data(
            withJSONObject: profileObject,
            options: [.sortedKeys, .withoutEscapingSlashes])
        let profileJSON = try XCTUnwrap(String(data: profileData, encoding: .utf8))
        let managedData = try signedEnvelope(profileJSON: profileJSON, privateKey: key)
        let managed = managedConfiguration([
            "schemaVersion": 1,
            "signedProfile": managedData,
            "policy": ["allowUserConfiguredExtensions": false],
        ])

        let resolution = TenantProfile.resolve(
            bundleIdentifier: MechanicianEnvironment.baseBundleIdentifier,
            environment: [:],
            homeDirectory: home,
            publicKey: key.publicKey.rawRepresentation,
            managedConfiguration: managed)

        XCTAssertTrue(resolution.profile.isDefault)
        XCTAssertTrue(resolution.managedByMDM)
        XCTAssertTrue(resolution.error?.contains("too much managed extension") == true)
    }

    func testSignedProfileRejectsManagedServersTheDaemonWouldSkip() throws {
        let key = Curve25519.Signing.PrivateKey()
        let duplicateServers: [[String: Any]] = [
            [
                "name": "duplicate",
                "transport": "http",
                "url": "https://tools.example.invalid/one",
            ],
            [
                "name": "duplicate",
                "transport": "sse",
                "url": "https://tools.example.invalid/two",
            ],
        ]
        let builtInCollision: [[String: Any]] = [[
            "name": "artifacts",
            "transport": "http",
            "url": "https://tools.example.invalid/replacement",
        ]]
        let normalizedBuiltInCollision: [[String: Any]] = [[
            "name": "provider.access",
            "transport": "http",
            "url": "https://tools.example.invalid/normalized-replacement",
        ]]
        let builtInNamespacePrefixCollision: [[String: Any]] = [[
            "name": "artifacts__evil",
            "transport": "http",
            "url": "https://tools.example.invalid/prefixed-replacement",
        ]]
        let builtInTrailingUnderscoreCollision: [[String: Any]] = [[
            "name": "artifacts_",
            "transport": "http",
            "url": "https://tools.example.invalid/trailing-underscore-replacement",
        ]]
        for invalidServers in [
            duplicateServers, builtInCollision, normalizedBuiltInCollision,
            builtInNamespacePrefixCollision, builtInTrailingUnderscoreCollision,
        ] {
            let profile: [String: Any] = [
                "tenantId": "managed",
                "displayName": "Managed",
                "extensions": ["managedServers": invalidServers],
            ]
            let data = try JSONSerialization.data(
                withJSONObject: profile,
                options: [.sortedKeys, .withoutEscapingSlashes])
            let envelope = try signedEnvelope(
                profileJSON: try XCTUnwrap(String(data: data, encoding: .utf8)),
                privateKey: key)

            XCTAssertThrowsError(try TenantProfile.loadSignedProfile(
                envelope, publicKey: key.publicKey.rawRepresentation)) { error in
                XCTAssertEqual(
                    error.localizedDescription,
                    TenantProfile.SignedProfileError.invalidManagedServerConfiguration
                        .localizedDescription)
            }
        }
    }

    func testInvalidMDMSignedProfileDoesNotFallBackToValidLocalProfile() throws {
        let home = try temporaryHome()
        let key = Curve25519.Signing.PrivateKey()
        let localURL = defaultProfileURL(home: home)
        try FileManager.default.createDirectory(
            at: localURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let localData = try signedEnvelope(
            profileJSON: #"{ "tenantId": "local", "displayName": "Local" }"#,
            privateKey: key)
        try localData.write(to: localURL)

        let validManagedData = try signedEnvelope(
            profileJSON: #"{ "tenantId": "managed", "displayName": "Managed" }"#,
            privateKey: key)
        let json = try XCTUnwrap(String(data: validManagedData, encoding: .utf8))
        let tamperedManagedData = Data(
            json.replacingOccurrences(of: "managed", with: "tampered").utf8)
        let managed = managedConfiguration([
            "schemaVersion": 1,
            "signedProfile": tamperedManagedData,
        ])

        let resolution = TenantProfile.resolve(
            bundleIdentifier: MechanicianEnvironment.baseBundleIdentifier,
            environment: [TenantProfile.profilePathEnvironmentVariable: localURL.path],
            homeDirectory: home,
            publicKey: key.publicKey.rawRepresentation,
            managedConfiguration: managed)

        XCTAssertTrue(resolution.profile.isDefault)
        XCTAssertTrue(resolution.managedByMDM)
        XCTAssertNil(resolution.sourceURL)
        XCTAssertTrue(resolution.error?.contains("supplied by MDM") == true)
        XCTAssertTrue(resolution.error?.contains("signature is invalid") == true)
    }

    func testInvalidForcedPolicyBlocksLocalProfileFallback() throws {
        let home = try temporaryHome()
        let key = Curve25519.Signing.PrivateKey()
        let localURL = defaultProfileURL(home: home)
        try FileManager.default.createDirectory(
            at: localURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try signedEnvelope(
            profileJSON: #"{ "tenantId": "local", "displayName": "Local" }"#,
            privateKey: key).write(to: localURL)
        let invalidManaged = managedConfiguration(["schemaVersion": 99])

        let resolution = TenantProfile.resolve(
            bundleIdentifier: MechanicianEnvironment.baseBundleIdentifier,
            environment: [:],
            homeDirectory: home,
            publicKey: key.publicKey.rawRepresentation,
            managedConfiguration: invalidManaged)

        XCTAssertTrue(resolution.profile.isDefault)
        XCTAssertTrue(resolution.managedByMDM)
        XCTAssertNil(resolution.sourceURL)
        XCTAssertTrue(resolution.error?.contains("schema version 99") == true)
    }

    func testManagedMarkerSurvivesLocalProfileLoadErrors() throws {
        let home = try temporaryHome()
        let key = Curve25519.Signing.PrivateKey()
        let localURL = home.appendingPathComponent("explicit.mechanician-profile")
        let managed = managedConfiguration(["schemaVersion": 1])

        let missing = TenantProfile.resolve(
            bundleIdentifier: MechanicianEnvironment.baseBundleIdentifier,
            environment: [TenantProfile.profilePathEnvironmentVariable: localURL.path],
            homeDirectory: home,
            publicKey: key.publicKey.rawRepresentation,
            managedConfiguration: managed)
        XCTAssertTrue(missing.managedByMDM)
        XCTAssertTrue(missing.error?.contains("does not exist") == true)

        try Data("not a profile".utf8).write(to: localURL)
        let malformed = TenantProfile.resolve(
            bundleIdentifier: MechanicianEnvironment.baseBundleIdentifier,
            environment: [TenantProfile.profilePathEnvironmentVariable: localURL.path],
            homeDirectory: home,
            publicKey: key.publicKey.rawRepresentation,
            managedConfiguration: managed)
        XCTAssertTrue(malformed.managedByMDM)
        XCTAssertTrue(malformed.error?.contains("could not load") == true)
    }

    func testWrongSigningKeyFailsClosed() throws {
        let signingKey = Curve25519.Signing.PrivateKey()
        let otherKey = Curve25519.Signing.PrivateKey()
        let data = try signedEnvelope(
            profileJSON: #"{ "tenantId": "acme", "displayName": "Acme" }"#,
            privateKey: signingKey)

        XCTAssertThrowsError(try TenantProfile.loadSignedProfile(
            data, publicKey: otherKey.publicKey.rawRepresentation)) { error in
            XCTAssertEqual(error.localizedDescription, "The enterprise profile signature is invalid.")
        }
    }

    func testMalformedExistingProfileFailsClosed() throws {
        let home = try temporaryHome()
        let key = Curve25519.Signing.PrivateKey()
        let profileURL = defaultProfileURL(home: home)
        try FileManager.default.createDirectory(
            at: profileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: profileURL)

        let resolution = TenantProfile.resolve(
            bundleIdentifier: MechanicianEnvironment.baseBundleIdentifier,
            environment: [:],
            homeDirectory: home,
            publicKey: key.publicKey.rawRepresentation)

        XCTAssertTrue(resolution.profile.isDefault)
        XCTAssertNotNil(resolution.error)
    }

    func testMissingExplicitProfilePathFailsClosed() throws {
        let home = try temporaryHome()
        let missing = home.appendingPathComponent("missing.mechanician-profile")
        let key = Curve25519.Signing.PrivateKey()

        let resolution = TenantProfile.resolve(
            bundleIdentifier: nil,
            environment: [TenantProfile.profilePathEnvironmentVariable: missing.path],
            homeDirectory: home,
            publicKey: key.publicKey.rawRepresentation)

        XCTAssertTrue(resolution.profile.isDefault)
        XCTAssertEqual(resolution.sourceURL, missing)
        XCTAssertTrue(resolution.error?.contains("does not exist") == true)
    }

    func testUnrelatedExecutableDoesNotReadInstalledProfileLocation() throws {
        let home = try temporaryHome()
        let key = Curve25519.Signing.PrivateKey()
        let profileURL = defaultProfileURL(home: home)
        try FileManager.default.createDirectory(
            at: profileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try signedEnvelope(
            profileJSON: #"{ "tenantId": "acme", "displayName": "Acme" }"#,
            privateKey: key).write(to: profileURL)

        let resolution = TenantProfile.resolve(
            bundleIdentifier: "org.swift.swiftpm.xctest",
            environment: [:],
            homeDirectory: home,
            publicKey: key.publicKey.rawRepresentation)

        XCTAssertTrue(resolution.profile.isDefault)
        XCTAssertNil(resolution.sourceURL)
        XCTAssertNil(resolution.error)
    }

    func testUnsupportedEnvelopeAndProfileVersionsAreRejected() throws {
        let key = Curve25519.Signing.PrivateKey()
        let unsupportedEnvelope = try signedEnvelope(
            profileJSON: #"{ "tenantId": "acme", "displayName": "Acme" }"#,
            privateKey: key,
            documentVersion: 2)
        XCTAssertThrowsError(try TenantProfile.loadSignedProfile(
            unsupportedEnvelope, publicKey: key.publicKey.rawRepresentation))

        let unsupportedProfile = try signedEnvelope(
            profileJSON: #"{ "schemaVersion": 2, "tenantId": "acme", "displayName": "Acme" }"#,
            privateKey: key)
        XCTAssertThrowsError(try TenantProfile.loadSignedProfile(
            unsupportedProfile, publicKey: key.publicKey.rawRepresentation))
    }

    /// Effort levels are provider-reported, so a profile naming one this build has not heard of is
    /// an ordinary forward-compatibility case, not a malformed document. This used to require
    /// membership in a fixed set, which meant one unfamiliar string rejected the ENTIRE profile:
    /// every route, every model, the whole managed lane gone until an app release shipped.
    func testSignedProfileAcceptsAnEffortLevelThisBuildDoesNotKnow() throws {
        let key = Curve25519.Signing.PrivateKey()
        let unfamiliar = try signedEnvelope(profileJSON: #"""
        {
          "tenantId": "acme", "displayName": "Acme",
          "routes": [{
            "routeId": "acme-vertex", "adapter": "claude-vertex",
            "vertex": { "projectId": "p", "region": "global" },
            "models": [{ "id": "claude-opus-4-8", "efforts": ["low", "high", "extreme"] }]
          }]
        }
        """#, privateKey: key)

        let loaded = try TenantProfile.loadSignedProfile(
            unfamiliar, publicKey: key.publicKey.rawRepresentation)

        // Carried through intact, not silently pruned: an administrator who declares a level their
        // deployment carries must get that level, not a quietly shortened list.
        XCTAssertEqual(loaded.routes.first?.models.first?.supportedEfforts,
                       ["low", "high", "extreme"])
    }

    func testSignedProfileRejectsAmbiguousVertexRoutes() throws {
        let key = Curve25519.Signing.PrivateKey()
        let duplicateRoutes = try signedEnvelope(profileJSON: #"""
        {
          "tenantId": "acme",
          "displayName": "Acme",
          "routes": [
            { "routeId": "one", "adapter": "claude-vertex",
              "vertex": { "projectId": "project-one", "region": "global" } },
            { "routeId": "two", "adapter": "claude-vertex",
              "vertex": { "projectId": "project-two", "region": "global" } }
          ]
        }
        """#, privateKey: key)

        XCTAssertThrowsError(try TenantProfile.loadSignedProfile(
            duplicateRoutes, publicKey: key.publicKey.rawRepresentation)) { error in
            XCTAssertTrue(error.localizedDescription.contains("exactly one complete identity"))
        }
    }

    func testSignedProfileCarriesExactManagedModelEfforts() throws {
        let key = Curve25519.Signing.PrivateKey()
        let data = try signedEnvelope(profileJSON: #"""
        {
          "tenantId": "acme",
          "displayName": "Acme",
          "routes": [
            { "routeId": "vertex", "adapter": "claude-vertex",
              "vertex": { "projectId": "project", "region": "global" },
              "models": [
                { "id": "claude-opus-4-8", "efforts": ["low", "medium", "high", "xhigh", "max"] },
                { "id": "claude-haiku-4-5" }
              ] }
          ]
        }
        """#, privateKey: key)

        let profile = try TenantProfile.loadSignedProfile(
            data, publicKey: key.publicKey.rawRepresentation)

        XCTAssertEqual(
            profile.declaredModels(for: .claudeVertex).map(\.supportedEfforts),
            [["low", "medium", "high", "xhigh", "max"], []])
    }

    /// This asserted that an UNKNOWN effort name rejected the profile, and used `["extreme"]` to say
    /// so. That was the defect, not the policy: effort levels are provider-reported, so the first
    /// time a provider shipped a new tier, every administrator who declared it would have had their
    /// whole profile refused — all routes, all models, the managed lane gone — until an app release.
    /// The bound is now the SHAPE of the name. A malformed one is still refused, as is a duplicate.
    func testSignedProfileRejectsMalformedOrDuplicateModelEfforts() throws {
        let key = Curve25519.Signing.PrivateKey()
        for efforts in [#"["high", "high"]"#, #"["Very High"]"#, #"["9high"]"#, #"[""]"#] {
            let data = try signedEnvelope(profileJSON: #"""
            {
              "tenantId": "acme",
              "displayName": "Acme",
              "routes": [
                { "routeId": "vertex", "adapter": "claude-vertex",
                  "vertex": { "projectId": "project", "region": "global" },
                  "models": [{ "id": "claude-opus-4-8", "efforts": \#(efforts) }] }
              ]
            }
            """#, privateKey: key)

            XCTAssertThrowsError(try TenantProfile.loadSignedProfile(
                data, publicKey: key.publicKey.rawRepresentation)) { error in
                XCTAssertEqual(
                    error.localizedDescription,
                    "The enterprise profile contains an invalid model effort declaration.")
            }
        }
    }

    func testPublicRepositoryDoesNotContainTenantProfileSource() throws {
        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        // The whole enterprise tree now lives in the private configuration repository, so this is
        // stronger than it was: not "the tenant source is ignored" but "no tenant deployment
        // material exists here at all". A customer's name, icon, hostnames, and rollout notes are
        // theirs, and this repository is public.
        let enterprise = repository.appendingPathComponent("enterprise", isDirectory: true)
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: enterprise.path),
            "tenant deployment material belongs in the private configuration repository")

        // A signed profile artifact must never be committed either, wherever it lands. Only what
        // git tracks is checked: `build/` legitimately holds generated profiles and is ignored.
        let git = Process()
        git.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        git.arguments = ["-C", repository.path, "ls-files"]
        let pipe = Pipe()
        git.standardOutput = pipe
        git.standardError = Pipe()
        try git.run()
        let listing = String(
            data: pipe.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8) ?? ""
        git.waitUntilExit()
        let committed = listing.split(separator: "\n").filter {
            $0.hasSuffix(".mechanician-profile") || $0.hasPrefix("enterprise/")
        }
        XCTAssertTrue(
            committed.isEmpty,
            "tenant deployment material is committed: \(committed)")
    }

    func testGeneratedEnterpriseProfileArtifactLoadsWithProductionTrustKey() throws {
        guard let path = ProcessInfo.processInfo.environment["MECHANICIAN_TEST_PROFILE_PATH"],
              !path.isEmpty
        else {
            throw XCTSkip("Set MECHANICIAN_TEST_PROFILE_PATH to verify a generated profile artifact")
        }
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        let publicKey = try XCTUnwrap(Data(
            base64Encoded: TenantProfile.profileSigningPublicKeyBase64))
        let profile = try TenantProfile.loadSignedProfile(data, publicKey: publicKey)

        XCTAssertFalse(profile.isDefault)
        XCTAssertEqual(profile.displayName, "Mechanician")
        XCTAssertNil(profile.bundleIdentifier)
        XCTAssertEqual(profile.update?.profileFeedURL?.hasPrefix("https://"), true)
        XCTAssertGreaterThan(profile.update?.revision ?? 0, 0)
        XCTAssertFalse(profile.enterpriseAccesses.isEmpty)
    }

    // MARK: - Declared models

    /// A managed deployment may not carry the newest generation: the Acme Vertex project answers
    /// `claude-opus-5` with a 404. A route can now say what it actually has.
    func testRouteDeclaredModelsPutTheDefaultFirst() {
        let profile = TenantProfile(
            tenantId: "acme",
            displayName: "Acme",
            routes: [
                TenantProfile.Route(
                    routeId: "acme-claude-vertex",
                    adapter: "claude-vertex",
                    models: [
                        TenantProfile.Model(id: "claude-sonnet-5"),
                        TenantProfile.Model(id: "claude-opus-4-8", displayName: "Opus 4.8", isDefault: true),
                    ])
            ])

        let declared = profile.declaredModels(for: .claudeVertex)

        XCTAssertEqual(declared.map(\.id), ["claude-opus-4-8", "claude-sonnet-5"])
        XCTAssertTrue(profile.declaredModels(for: .claudeSubscription).isEmpty)
    }

    /// Declaring nothing must keep the generic built-in list, never produce an empty lane.
    @MainActor
    func testRouteWithoutDeclaredModelsFallsBackToTheBuiltInList() {
        let profile = TenantProfile(
            tenantId: "acme", displayName: "Acme",
            routes: [TenantProfile.Route(routeId: "r", adapter: "claude-vertex")])

        XCTAssertTrue(profile.declaredModels(for: .claudeVertex).isEmpty)
        XCTAssertFalse(AgentBridge.builtInModels(for: .claudeVertex).isEmpty)
    }

    /// A managed deployment can pin the generation it actually carries without exposing a tenant
    /// source document in the public repository.
    func testManagedVertexProfileDeclaresOnlyItsWorkingModel() {
        let profile = TenantProfile(
            tenantId: "example-corp",
            displayName: "Example Corp",
            routes: [
                TenantProfile.Route(
                    routeId: "example-vertex",
                    adapter: "claude-vertex",
                    models: [
                        TenantProfile.Model(
                            id: "claude-opus-4-8",
                            displayName: "Opus 4.8",
                            isDefault: true),
                    ])
            ])

        let ids = profile.declaredModels(for: .claudeVertex).map(\.id)
        XCTAssertTrue(ids.contains("claude-opus-4-8"), "declared: \(ids)")
        XCTAssertFalse(ids.contains("claude-opus-5"), "that deployment 404s opus-5")
    }
}

// MARK: - A managed configuration must be able to update itself
//
// `profileFeedURL` is the ONLY reason an administrator can rotate a Vertex project, a registry
// hostname or a model list without asking every user to re-import the profile by hand. Sanitization
// dropped `update` wholesale, which took `profileFeedURL` with it — so `TenantProfileUpdater` read
// nil on every launch and managed configuration could never self-update. The app's own Sparkle
// channel must still be untouchable.

extension TenantProfileTests {
    private var profileWithBothUpdateHalves: String {
        """
        { "schemaVersion": 1, "tenantId": "acme", "displayName": "Mechanician for Acme",
          "update": {
            "feedURL": "https://attacker.invalid/appcast.xml",
            "publicEDKey": "ATTACKERKEY=",
            "profileFeedURL": "https://profiles.example.com/mechanician.profile",
            "profileUpdateMode": "manual",
            "revision": 7
          },
          "routes": [] }
        """
    }

    func testAProfileKeepsItsOwnUpdateFeedSoItCanBeRotatedWithoutAReimport() throws {
        let key = Curve25519.Signing.PrivateKey()
        let envelope = try signedEnvelope(profileJSON: profileWithBothUpdateHalves, privateKey: key)

        let profile = try TenantProfile.loadSignedProfile(
            envelope, publicKey: key.publicKey.rawRepresentation)

        XCTAssertEqual(profile.update?.profileFeedURL,
                       "https://profiles.example.com/mechanician.profile")
        XCTAssertEqual(profile.update?.effectiveProfileUpdateMode, .manual)
        XCTAssertEqual(profile.update?.revision, 7)
    }

    /// The dangerous half. A profile that could name the app's Sparkle feed and its signing key
    /// would be able to replace the BINARY, which is a different and much larger power than
    /// replacing its own configuration document.
    func testAProfileStillCannotRedirectTheAppsOwnUpdateChannel() throws {
        let key = Curve25519.Signing.PrivateKey()
        let envelope = try signedEnvelope(profileJSON: profileWithBothUpdateHalves, privateKey: key)

        let profile = try TenantProfile.loadSignedProfile(
            envelope, publicKey: key.publicKey.rawRepresentation)

        XCTAssertNil(profile.update?.feedURL)
        XCTAssertNil(profile.update?.publicEDKey)
        // Everything else sanitization strips stays stripped.
        XCTAssertEqual(profile.displayName, TenantProfile.default.displayName)
        XCTAssertNil(profile.bundleIdentifier)
        XCTAssertEqual(profile.branding, TenantProfile.default.branding)
        XCTAssertNil(profile.portal)
    }

    /// A profile declaring no feed of its own must not grow one.
    func testAProfileWithNoFeedOfItsOwnStillHasNoUpdateSection() throws {
        let key = Curve25519.Signing.PrivateKey()
        let json = """
        { "schemaVersion": 1, "tenantId": "acme", "displayName": "Acme",
          "update": { "feedURL": "https://example.invalid/appcast.xml" }, "routes": [] }
        """
        let envelope = try signedEnvelope(profileJSON: json, privateKey: key)

        let profile = try TenantProfile.loadSignedProfile(
            envelope, publicKey: key.publicKey.rawRepresentation)

        XCTAssertNil(profile.update)
    }

    func testRevisionAndManualModeSurviveWithoutAProfileFeed() throws {
        let key = Curve25519.Signing.PrivateKey()
        let json = """
        { "schemaVersion": 1, "tenantId": "acme", "displayName": "Acme",
          "update": { "profileUpdateMode": "manual", "revision": 12 }, "routes": [] }
        """
        let envelope = try signedEnvelope(profileJSON: json, privateKey: key)

        let profile = try TenantProfile.loadSignedProfile(
            envelope, publicKey: key.publicKey.rawRepresentation)

        XCTAssertNil(profile.update?.profileFeedURL)
        XCTAssertEqual(profile.update?.effectiveProfileUpdateMode, .manual)
        XCTAssertEqual(profile.update?.revision, 12)
    }

    func testProfileWithoutAnUpdateModeRetainsLegacyAutomaticBehavior() throws {
        let decoded = try decode("""
        { "tenantId": "acme", "displayName": "Acme",
          "update": { "profileFeedURL": "https://profiles.example.com/profile", "revision": 4 } }
        """)

        XCTAssertNil(decoded.update?.profileUpdateMode)
        XCTAssertEqual(decoded.update?.effectiveProfileUpdateMode, .automatic)
    }
}
