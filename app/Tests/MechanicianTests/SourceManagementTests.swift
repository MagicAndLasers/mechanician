import XCTest
@testable import Mechanician

/// Sources are where extensions come from. The model has existed for a long time — `RegistrySource`
/// and `MarketplaceSource` both carry a URL, a format adapter and a trust marker, and the store has
/// always had `upsert`/`remove`. What never existed was a way for a person to reach any of it, so a
/// registry could only arrive via a signed tenant profile.
///
/// These pin the rules that make the surface safe to expose.
final class SourceManagementTests: XCTestCase {

    // MARK: trust

    /// A user-added registry vouches for itself and no further. `verified` means the vendor whose
    /// service it exposes published the entry — a claim only the built-in manifest can make. If a
    /// registry could mint that badge, anyone who talks you into adding a URL could mint it too.
    func testAUserAddedRegistryCannotClaimVerified() {
        var source = RegistrySource()
        source.url = "https://registry.example.com/v0/servers"
        source.source = .user

        XCTAssertNotEqual(source.source, .verified)
        XCTAssertFalse(source.isManaged)
    }

    func testManagedSourcesAreRecognisedAsManaged() {
        var source = RegistrySource()
        source.url = "https://mcp.example.com/data/servers.json"
        source.source = .managed
        source.format = .generic

        XCTAssertTrue(source.isManaged, "a managed source must be non-removable in the UI")
    }

    // MARK: validation

    func testOnlyHTTPSRegistriesAreValid() {
        // A registry decides which servers you are offered, so anything on the path could choose
        // them for you over plaintext.
        var insecure = RegistrySource(); insecure.url = "http://registry.example.com/v0/servers"
        XCTAssertFalse(insecure.isValid)

        var secure = RegistrySource(); secure.url = "https://registry.example.com/v0/servers"
        XCTAssertTrue(secure.isValid)

        var empty = RegistrySource(); empty.url = "   "
        XCTAssertFalse(empty.isValid)
    }

    func testMarketplaceRepoBecomesAFetchableURL() {
        var source = MarketplaceSource()
        source.repo = "anthropics/knowledge-work-plugins"

        XCTAssertTrue(source.rawURL.hasPrefix("https://"),
                      "a plugin source must resolve to an https URL, got \(source.rawURL)")
        XCTAssertTrue(source.rawURL.contains("anthropics/knowledge-work-plugins"))
    }

    func testArchiveMarketplaceSourcesRequireCredentialFreeFragmentFreeHTTPSWithoutRestrictingNativeForms() {
        var archive = MarketplaceSource()
        archive.format = .archiveRegistryV1

        archive.repo = "https://plugins.example/catalog.json"
        XCTAssertTrue(archive.isValid)

        for invalid in [
            "http://plugins.example/catalog.json",
            "https://user:secret@plugins.example/catalog.json",
            "https://plugins.example/catalog.json#alternate",
        ] {
            archive.repo = invalid
            XCTAssertFalse(archive.isValid, "\(invalid) must not be accepted as an archive registry")
        }

        var native = MarketplaceSource()
        native.format = .claudeMarketplace
        for supported in [
            "anthropics/knowledge-work-plugins",
            "https://github.com/anthropics/knowledge-work-plugins.git",
            "/Users/example/local-plugin-marketplace",
        ] {
            native.repo = supported
            XCTAssertTrue(native.isValid, "\(supported) must remain a valid native Claude marketplace")
        }
    }

    func testDisplayNameFallsBackToSomethingRecognisable() {
        var unnamed = RegistrySource(); unnamed.url = "https://registry.example.com/v0/servers"
        XCTAssertEqual(unnamed.displayName, "registry.example.com",
                       "an unnamed registry should show its host, not a blank row")

        var unnamedRepo = MarketplaceSource(); unnamedRepo.repo = "anthropics/claude-plugins-official"
        XCTAssertEqual(unnamedRepo.displayName, "anthropics/claude-plugins-official")
    }

    func testArchivePluginCatalogIdentitySurvivesPersistence() throws {
        let sourceID = UUID()
        var plugin = LocalPlugin()
        plugin.name = "operations"
        plugin.path = "/private/plugin-archives/operations"
        plugin.source = .managed
        plugin.networkScope = .vpnOnly
        plugin.sha256 = String(repeating: "a", count: 64)
        plugin.catalogPluginID = "operations@archive-\(sourceID.uuidString.lowercased())"
        plugin.marketplaceSourceID = sourceID
        plugin.marketplaceName = "Company Plugins"
        plugin.version = "2.0.0"

        let decoded = try JSONDecoder().decode(
            LocalPlugin.self,
            from: JSONEncoder().encode(plugin))

        XCTAssertEqual(decoded, plugin)
    }

    @MainActor
    func testGenericFolderManagementClassifiesCatalogRowsAndRejectsArchiveBypasses() {
        let store = ExtensionsStore.shared
        let saved = store.plugins
        defer { store.plugins = saved }

        var local = LocalPlugin()
        local.path = "/private/local-tools"
        XCTAssertFalse(local.isCatalogBacked)

        var archive = local
        archive.id = UUID()
        archive.catalogPluginID = "operations@archive-\(UUID().uuidString.lowercased())"
        XCTAssertTrue(archive.isCatalogBacked)
        XCTAssertFalse(store.upsert(archive),
                       "a generic folder mutation must not install a new archive plugin")
        XCTAssertEqual(store.plugins, saved)

        store.plugins.append(archive)
        var stripped = archive
        stripped.catalogPluginID = nil
        XCTAssertFalse(store.upsert(stripped),
                       "incoming data cannot strip a persisted row's catalog provenance")
        XCTAssertEqual(store.plugins.last?.catalogPluginID, archive.catalogPluginID)
    }

    func testArchiveCleanupRequiresAnExactInstallerAcceptedIdentity() throws {
        let sourceID = UUID()
        func plugin() -> LocalPlugin {
            var plugin = LocalPlugin()
            plugin.name = "operations"
            plugin.path = "/private/plugin-archives/operations"
            plugin.sha256 = String(repeating: "a", count: 64)
            plugin.catalogPluginID = "operations@archive-\(sourceID.uuidString.lowercased())"
            plugin.marketplaceSourceID = sourceID
            plugin.version = "2.0.0"
            return plugin
        }
        func assertRejected(
            _ mutation: (inout LocalPlugin) -> Void,
            file: StaticString = #filePath,
            line: UInt = #line
        ) {
            var candidate = plugin()
            mutation(&candidate)
            XCTAssertNil(ArchivePluginCleanup(plugin: candidate), file: file, line: line)
        }

        let cleanup = try XCTUnwrap(ArchivePluginCleanup(plugin: plugin()))
        XCTAssertTrue(cleanup.isValid)

        var boundary = plugin()
        boundary.name = String(repeating: "n", count: 256)
        boundary.version = String(repeating: "v", count: 128)
        boundary.path = String(repeating: "p", count: 4096)
        XCTAssertNotNil(ArchivePluginCleanup(plugin: boundary))

        assertRejected { $0.marketplaceSourceID = nil }
        assertRejected { $0.catalogPluginID = " operations" }
        assertRejected { $0.name = "operations\u{0007}" }
        assertRejected { $0.name = String(repeating: "n", count: 257) }
        assertRejected { $0.version = "" }
        assertRejected { $0.version = String(repeating: "v", count: 129) }
        assertRejected { $0.sha256 = String(repeating: "a", count: 63) + "g" }
        assertRejected { $0.path += " " }
        assertRejected { $0.path = String(repeating: "p", count: 4097) }

        var invalidPersistedCleanup = cleanup
        invalidPersistedCleanup.sourceID = nil
        XCTAssertFalse(invalidPersistedCleanup.isValid)
    }

    func testArchiveFinalizationRequiresAnExactIdentityAndUUIDV4Lease() throws {
        let sourceID = UUID()
        var plugin = LocalPlugin()
        plugin.name = "operations"
        plugin.path = "/private/plugin-archives/operations"
        plugin.sha256 = String(repeating: "a", count: 64)
        plugin.catalogPluginID = "operations@archive-\(sourceID.uuidString.lowercased())"
        plugin.marketplaceSourceID = sourceID
        plugin.version = "2.0.0"
        let lease = "550e8400-e29b-41d4-a716-446655440000"

        let finalization = try XCTUnwrap(
            PendingArchiveFinalization(plugin: plugin, leaseToken: lease.uppercased()))
        XCTAssertTrue(finalization.isValid)
        XCTAssertEqual(finalization.leaseToken, lease)
        XCTAssertEqual(finalization.archiveCleanup?.leaseToken, lease)

        let decoded = try JSONDecoder().decode(
            PendingArchiveFinalization.self,
            from: JSONEncoder().encode(finalization))
        XCTAssertEqual(decoded, finalization)

        XCTAssertNil(PendingArchiveFinalization(
            plugin: plugin,
            leaseToken: "550e8400-e29b-11d4-a716-446655440000"),
            "a UUID of the wrong version is not an install lease")
        XCTAssertNil(PendingArchiveFinalization(
            plugin: plugin,
            leaseToken: "550e8400-e29b-41d4-4716-446655440000"),
            "a UUID without an RFC 4122 variant is not an install lease")
        XCTAssertNil(ArchivePluginCleanup(
            plugin: plugin,
            leaseToken: "not-a-capability"))

        let malformed = try JSONDecoder().decode(
            PendingArchiveFinalization.self,
            from: Data(#"""
            {
              "pluginID": 42,
              "sourceID": "not-a-uuid",
              "pluginName": "operations",
              "version": "2.0.0",
              "sha256": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
              "installPath": "/private/plugin-archives/operations",
              "leaseToken": "not-a-v4-uuid"
            }
            """#.utf8))
        XCTAssertFalse(malformed.isValid,
                       "one malformed queue row should decode for load-time filtering")
    }

    @MainActor
    func testUnmountTransfersEveryPendingInstallLeaseIntoDurableCleanup() throws {
        let sourceID = UUID()
        func plugin(path: String, digest: Character) -> LocalPlugin {
            var plugin = LocalPlugin()
            plugin.name = "operations"
            plugin.path = path
            plugin.sha256 = String(repeating: String(digest), count: 64)
            plugin.catalogPluginID = "operations@archive-\(sourceID.uuidString.lowercased())"
            plugin.marketplaceSourceID = sourceID
            plugin.version = "2.0.0"
            return plugin
        }
        let oldPlugin = plugin(path: "/private/plugin-archives/v2", digest: "a")
        let otherPlugin = plugin(path: "/private/plugin-archives/v3", digest: "b")
        let oldLeases = [
            "550e8400-e29b-41d4-a716-446655440000",
            "d9428888-122b-4c67-8f9c-6a14f8bb7c41",
        ]
        let otherLease = "6ba7b810-9dad-41d1-80b4-00c04fd430c8"
        var pending = try oldLeases.map {
            try XCTUnwrap(PendingArchiveFinalization(plugin: oldPlugin, leaseToken: $0))
        }
        let unrelated = try XCTUnwrap(
            PendingArchiveFinalization(plugin: otherPlugin, leaseToken: otherLease))
        pending.append(unrelated)
        let oldFinalizationIDs = Set(pending.dropLast().map(\.id))

        let cleanups = try XCTUnwrap(ExtensionsStore.archiveCleanupsForUnmounting(
            oldPlugin,
            pendingFinalizations: &pending))

        XCTAssertEqual(Set(cleanups.compactMap(\.leaseToken)), Set(oldLeases))
        XCTAssertEqual(Set(cleanups.map(\.id)), oldFinalizationIDs,
                       "a transferred cleanup keeps the finalization correlation ID")
        XCTAssertTrue(cleanups.allSatisfy(\.isValid))
        XCTAssertEqual(pending, [unrelated],
                       "only finalizations for the unmounted exact identity are consumed")

        var noPending: [PendingArchiveFinalization] = []
        let ordinaryCleanup = try XCTUnwrap(ExtensionsStore.archiveCleanupsForUnmounting(
            oldPlugin,
            pendingFinalizations: &noPending))
        XCTAssertEqual(ordinaryCleanup.count, 1)
        XCTAssertNil(ordinaryCleanup[0].leaseToken)
    }

    func testMalformedOptionalArchiveMetadataDoesNotInvalidateALocalPlugin() throws {
        let plugin = try JSONDecoder().decode(LocalPlugin.self, from: Data(#"""
        {
          "name": "local-tools",
          "enabled": true,
          "path": "/private/local-tools",
          "source": "future-source",
          "networkScope": "future-scope",
          "marketplaceSourceID": "not-a-uuid",
          "catalogPluginID": 42
        }
        """#.utf8))

        XCTAssertEqual(plugin.name, "local-tools")
        XCTAssertEqual(plugin.path, "/private/local-tools")
        XCTAssertNil(plugin.source)
        XCTAssertNil(plugin.networkScope)
        XCTAssertNil(plugin.marketplaceSourceID)
        XCTAssertNil(plugin.catalogPluginID)
    }

    func testIncompleteStringArchiveIdentityFallsBackToAnOrdinaryRemovableFolder() throws {
        let sourceID = UUID()
        let plugin = try JSONDecoder().decode(LocalPlugin.self, from: Data(#"""
        {
          "name": "recoverable-tools",
          "enabled": true,
          "path": "/private/recoverable-tools",
          "catalogPluginID": "recoverable-tools@archive-fixture",
          "marketplaceSourceID": "\#(sourceID.uuidString)",
          "marketplaceName": "Fixture",
          "version": "1.0.0",
          "sha256": "not-a-digest"
        }
        """#.utf8))

        XCTAssertEqual(plugin.name, "recoverable-tools")
        XCTAssertEqual(plugin.path, "/private/recoverable-tools")
        XCTAssertFalse(plugin.isCatalogBacked)
        XCTAssertNil(plugin.catalogPluginID)
        XCTAssertNil(plugin.marketplaceSourceID)
        XCTAssertNil(plugin.marketplaceName)
        XCTAssertNil(plugin.version)
    }

    @MainActor
    func testRemountingAContentAddressedVersionCancelsItsPendingDeletion() throws {
        let sourceID = UUID()
        func plugin(path: String, digest: Character) -> LocalPlugin {
            var plugin = LocalPlugin()
            plugin.name = "operations"
            plugin.path = path
            plugin.sha256 = String(repeating: String(digest), count: 64)
            plugin.catalogPluginID = "operations@archive-\(sourceID.uuidString.lowercased())"
            plugin.marketplaceSourceID = sourceID
            plugin.version = "1.0.0"
            return plugin
        }
        let v1 = plugin(path: "/private/plugin-archives/v1", digest: "a")
        let v2 = plugin(path: "/private/plugin-archives/v2", digest: "b")
        let oldLease = "550e8400-e29b-41d4-a716-446655440000"
        let newLease = "d9428888-122b-4c67-8f9c-6a14f8bb7c41"
        let v1Cleanup = try XCTUnwrap(
            ArchivePluginCleanup(plugin: v1, leaseToken: oldLease))
        let v2Cleanup = try XCTUnwrap(ArchivePluginCleanup(plugin: v2))
        let newFinalization = try XCTUnwrap(
            PendingArchiveFinalization(plugin: v1, leaseToken: newLease))

        var cleanups = [v1Cleanup, v2Cleanup]
        var finalizations = [newFinalization]
        XCTAssertTrue(ExtensionsStore.reconcileArchiveMount(
            v1,
            pendingCleanups: &cleanups,
            pendingFinalizations: &finalizations))

        XCTAssertEqual(cleanups, [v2Cleanup])
        XCTAssertEqual(Set(finalizations.map(\.leaseToken)), [oldLease, newLease],
                       "canceling a deletion must preserve both the old and new install leases")
    }

    @MainActor
    func testStableManagedSourceIdentityDeduplicatesSignedCollisionsAfterValidation() {
        func source(
            kind: String,
            name: String,
            url: String,
            format: String
        ) -> TenantProfile.ManagedSource {
            TenantProfile.ManagedSource(
                kind: kind,
                name: name,
                url: url,
                repo: nil,
                format: format,
                authentication: nil,
                networkScope: "public")
        }
        let profile = TenantProfile(
            tenantId: "acme",
            displayName: "Acme",
            extensions: TenantProfile.ExtensionPolicy(managedSources: [
                // Invalid entries do not reserve the stable identity.
                source(kind: "registry", name: "Acme Tools",
                       url: "http://invalid.example/registry.json", format: "officialV01"),
                source(kind: "registry", name: "Acme Tools",
                       url: "https://first.example/registry.json", format: "officialV01"),
                source(kind: "registry", name: "Acme Tools",
                       url: "https://second.example/registry.json", format: "officialV01"),
                source(kind: "marketplace", name: "Acme Plugins",
                       url: "http://invalid.example/catalog.json",
                       format: MarketplaceFormat.archiveRegistryV1.rawValue),
                source(kind: "marketplace", name: "Acme Plugins",
                       url: "https://first.example/catalog.json",
                       format: MarketplaceFormat.archiveRegistryV1.rawValue),
                source(kind: "marketplace", name: "Acme Plugins",
                       url: "https://second.example/catalog.json",
                       format: MarketplaceFormat.archiveRegistryV1.rawValue),
            ]))

        let registries = ExtensionsStore.makeManagedRegistrySources(from: profile)
        let marketplaces = ExtensionsStore.makeManagedMarketplaceSources(from: profile)
        XCTAssertEqual(registries.map(\.url), ["https://first.example/registry.json"])
        XCTAssertEqual(marketplaces.map(\.repo), ["https://first.example/catalog.json"])

        let rotated = TenantProfile(
            tenantId: "acme",
            displayName: "Acme",
            extensions: TenantProfile.ExtensionPolicy(managedSources: [
                source(kind: "registry", name: "Acme Tools",
                       url: "https://rotated.example/registry.json", format: "officialV01"),
                source(kind: "marketplace", name: "Acme Plugins",
                       url: "https://rotated.example/catalog.json",
                       format: MarketplaceFormat.archiveRegistryV1.rawValue),
            ]))
        XCTAssertEqual(
            registries.first?.id,
            ExtensionsStore.makeManagedRegistrySources(from: rotated).first?.id)
        XCTAssertEqual(
            marketplaces.first?.id,
            ExtensionsStore.makeManagedMarketplaceSources(from: rotated).first?.id)
    }

    // MARK: adapters

    /// Registries genuinely differ in shape. Decoding one as another yields an empty list that
    /// looks exactly like an empty registry — the "denial reads as empty" failure that has bitten
    /// this app repeatedly — so the format is chosen explicitly and every option is presentable.
    func testEveryRegistryFormatIsSelectableAndExplained() {
        XCTAssertGreaterThanOrEqual(RegistryFormat.allCases.count, 3)
        for format in RegistryFormat.allCases {
            XCTAssertFalse(format.label.isEmpty, "\(format) needs a label for the picker")
            XCTAssertFalse(format.hint.isEmpty, "\(format) needs a hint explaining what it is")
        }
    }

    func testAPrivateRegistryIsSupportedDeclarativelyRatherThanByACodePath() {
        // An enterprise registry is served behind a VPN and its schema differs from the public one.
        // Supporting that declaratively — rather than as a per-organization code path — is what
        // lets any other organisation's registry be added by URL instead of by an app release.
        XCTAssertTrue(RegistryFormat.allCases.contains(.generic))
        XCTAssertTrue(RegistryFormat.generic.hint.lowercased().contains("detect"))
    }

    // MARK: merging

    /// A public or user registry must not be able to shadow a same-named managed entry: the
    /// organisation's answer wins on machines the organisation manages.
    @MainActor
    func testManagedSourcesLeadTheMerge() {
        let store = ExtensionsStore.shared
        let effective = store.effectiveRegistrySources
        let managedIndexes = effective.enumerated().filter { $0.element.isManaged }.map(\.offset)
        let userIndexes = effective.enumerated().filter { !$0.element.isManaged }.map(\.offset)

        if let lastManaged = managedIndexes.max(), let firstUser = userIndexes.min() {
            XCTAssertLessThan(lastManaged, firstUser,
                              "managed sources must precede user sources in the merge")
        }
    }
}

/// A general-purpose app must not offer one organization's private schema as if it were a choice
/// anyone could sensibly make — while the adapter itself has to keep working for the signed
/// profiles that select it, and for configurations already on disk.
extension SourceManagementTests {

    /// The retired per-organization case must not orphan anything that names it.
    ///
    /// `RegistryFormat` is a plain `String` enum, so an unknown raw value would fail the enclosing
    /// source's decode and take an installed registry with it. A stored source, or a signed profile
    /// written before the case was retired, still names it; it has to keep working, and the
    /// inference adapter reads the same documents. The retired name is not special to the decoder —
    /// any unrecognized format takes this path — so it need not be spelled out here.
    func testARetiredTenantFormatDecodesToTheGenericAdapter() throws {
        let stored = Data(#"{"format":"retiredTenantV1"}"#.utf8)
        struct Holder: Decodable { let format: RegistryFormat }
        XCTAssertEqual(try JSONDecoder().decode(Holder.self, from: stored).format, .generic)

        // The same tolerance covers a format this build simply has not heard of.
        let unknown = Data(#"{"format":"somethingElseEntirely"}"#.utf8)
        XCTAssertEqual(try JSONDecoder().decode(Holder.self, from: unknown).format, .generic)
    }

    func testEveryRemainingFormatIsOfferedForManualSelection() {
        XCTAssertTrue(RegistryFormat.userSelectableCases.contains(.officialV01))
        XCTAssertTrue(RegistryFormat.userSelectableCases.contains(.pulseBeta))
        XCTAssertTrue(RegistryFormat.userSelectableCases.contains(.generic))
    }

    func testTenantSpecificFormatStillDecodesAndFunctions() {
        // Removing it from the picker must not orphan the profiles and stored sources using it.
        var managed = RegistrySource()
        managed.url = "https://mcp.example.com/data/servers.json"
        managed.format = .generic
        managed.source = .managed

        let data = try! JSONEncoder().encode(managed)
        let back = try! JSONDecoder().decode(RegistrySource.self, from: data)
        XCTAssertEqual(back.format, .generic, "an existing managed source must keep working")
        XCTAssertTrue(RegistryFormat.allCases.contains(.generic))
    }

    func testEverySelectableFormatIsDocumented() {
        // Choosing wrong is SILENT — a mismatched schema decodes to an empty list, not an error —
        // so the difference has to be explained where the choice is made.
        for format in RegistryFormat.userSelectableCases {
            XCTAssertGreaterThan(format.documentation.count, 80,
                                 "\(format) needs real documentation, not a label")
            XCTAssertFalse(format.label.isEmpty)
        }
    }
}
