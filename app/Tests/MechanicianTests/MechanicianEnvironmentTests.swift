import XCTest
@testable import Mechanician

final class MechanicianEnvironmentTests: XCTestCase {
    private let home = URL(fileURLWithPath: "/Users/tester", isDirectory: true)

    func testDevBundleDerivesAllPrivateRootsWithoutLauncherEnvironment() {
        XCTAssertEqual(
            MechanicianEnvironment.processDefaults(
                bundleIdentifier: MechanicianEnvironment.devBundleIdentifier,
                environment: [:],
                homeDirectory: home),
            [
                "MECHANICIAN_SUPPORT_DIR": "/Users/tester/Library/Application Support/Mechanician-dev",
                "MECHANICIAN_CONFIG_DIR": "/Users/tester/Library/Application Support/Mechanician-dev/claude",
                "CODEX_HOME": "/Users/tester/Library/Application Support/Mechanician-dev/codex",
                "MECHANICIAN_ANTHROPIC_API_KEY_SERVICE": "ANTHROPIC_API_KEY.dev",
                "MECHANICIAN_OPENAI_API_KEY_SERVICE": "OPENAI_API_KEY.dev",
                "MECHANICIAN_MCP_SECRET_SERVICE": "ai.mechanician.mcp-secret.dev",
                "MECHANICIAN_MCP_OAUTH_SERVICE": "ai.mechanician.mcp-oauth.dev",
            ])
    }

    func testInstalledBundleDoesNotRewriteItsEnvironment() {
        XCTAssertTrue(
            MechanicianEnvironment.processDefaults(
                bundleIdentifier: "ai.mechanician.app",
                environment: ["CODEX_HOME": "/existing"],
                homeDirectory: home).isEmpty)
    }

    func testDevBundleHonorsExplicitSupportAndConfigButRejectsInheritedCodexHome() {
        XCTAssertEqual(
            MechanicianEnvironment.processDefaults(
                bundleIdentifier: MechanicianEnvironment.devBundleIdentifier,
                environment: [
                    "MECHANICIAN_SUPPORT_DIR": "/tmp/mechanician-fixture",
                    "MECHANICIAN_CONFIG_DIR": "/tmp/claude-fixture",
                    "CODEX_HOME": "/production/codex",
                ],
                homeDirectory: home),
            [
                "MECHANICIAN_SUPPORT_DIR": "/tmp/mechanician-fixture",
                "MECHANICIAN_CONFIG_DIR": "/tmp/claude-fixture",
                "CODEX_HOME": "/tmp/mechanician-fixture/codex",
                "MECHANICIAN_ANTHROPIC_API_KEY_SERVICE": "ANTHROPIC_API_KEY.dev",
                "MECHANICIAN_OPENAI_API_KEY_SERVICE": "OPENAI_API_KEY.dev",
                "MECHANICIAN_MCP_SECRET_SERVICE": "ai.mechanician.mcp-secret.dev",
                "MECHANICIAN_MCP_OAUTH_SERVICE": "ai.mechanician.mcp-oauth.dev",
            ])
    }

    func testDevSpecificCodexOverrideRemainsAvailableToFixtures() {
        let defaults = MechanicianEnvironment.processDefaults(
            bundleIdentifier: MechanicianEnvironment.devBundleIdentifier,
            environment: ["MECHANICIAN_DEV_CODEX_HOME": "/tmp/codex-fixture"],
            homeDirectory: home)
        XCTAssertEqual(defaults["CODEX_HOME"], "/tmp/codex-fixture")
    }

    // MARK: - Tenant identity (FR-103 M0)

    func testIdentitySlugForKnownBundleIdentifiers() {
        XCTAssertNil(MechanicianEnvironment.identitySlug(for: "ai.mechanician.app"))
        XCTAssertNil(MechanicianEnvironment.identitySlug(for: nil))
        XCTAssertEqual(MechanicianEnvironment.identitySlug(for: "ai.mechanician.app.dev"), "dev")
        XCTAssertEqual(MechanicianEnvironment.identitySlug(for: "ai.mechanician.app.acme"), "acme")
        // A deeper reverse-DNS id keeps only the first segment as the isolation slug.
        XCTAssertEqual(MechanicianEnvironment.identitySlug(for: "ai.mechanician.app.acme.beta"), "acme")
        // An unrelated bundle id is treated as the public identity, never a false tenant.
        XCTAssertNil(MechanicianEnvironment.identitySlug(for: "com.someone.else"))
    }

    func testSupportDirectoryNameDerivation() {
        XCTAssertEqual(MechanicianEnvironment.supportDirectoryName(for: "ai.mechanician.app"), "Mechanician")
        XCTAssertEqual(MechanicianEnvironment.supportDirectoryName(for: "ai.mechanician.app.dev"), "Mechanician-dev")
        XCTAssertEqual(MechanicianEnvironment.supportDirectoryName(for: "ai.mechanician.app.acme"), "Mechanician-acme")
    }

    func testCurrentSupportRootHonorsExplicitOverrideAndBundleIdentity() {
        XCTAssertEqual(
            MechanicianEnvironment.currentSupportRoot(
                environment: ["MECHANICIAN_SUPPORT_DIR": "/tmp/mechanician-fixture/../selected"],
                homeDirectory: home,
                bundleIdentifier: MechanicianEnvironment.devBundleIdentifier).path,
            "/tmp/selected")
        XCTAssertEqual(
            MechanicianEnvironment.currentSupportRoot(
                environment: [:],
                homeDirectory: home,
                bundleIdentifier: MechanicianEnvironment.devBundleIdentifier).path,
            "/Users/tester/Library/Application Support/Mechanician-dev")
        XCTAssertEqual(
            MechanicianEnvironment.currentSupportRoot(
                environment: [:],
                homeDirectory: home,
                bundleIdentifier: MechanicianEnvironment.baseBundleIdentifier).path,
            "/Users/tester/Library/Application Support/Mechanician")
    }

    func testTenantBundleDerivesIsolatedRootsWithoutLauncherEnvironment() {
        XCTAssertEqual(
            MechanicianEnvironment.processDefaults(
                bundleIdentifier: "ai.mechanician.app.acme",
                environment: [:],
                homeDirectory: home),
            [
                "MECHANICIAN_SUPPORT_DIR": "/Users/tester/Library/Application Support/Mechanician-acme",
                "MECHANICIAN_CONFIG_DIR": "/Users/tester/Library/Application Support/Mechanician-acme/claude",
                "CODEX_HOME": "/Users/tester/Library/Application Support/Mechanician-acme/codex",
                "MECHANICIAN_ANTHROPIC_API_KEY_SERVICE": "ANTHROPIC_API_KEY.acme",
                "MECHANICIAN_OPENAI_API_KEY_SERVICE": "OPENAI_API_KEY.acme",
                "MECHANICIAN_MCP_SECRET_SERVICE": "ai.mechanician.mcp-secret.acme",
                "MECHANICIAN_MCP_OAUTH_SERVICE": "ai.mechanician.mcp-oauth.acme",
            ])
    }

    func testTenantBundleNeverInheritsAnotherIdentitysCodexHome() {
        let defaults = MechanicianEnvironment.processDefaults(
            bundleIdentifier: "ai.mechanician.app.acme",
            environment: ["CODEX_HOME": "/production/codex"],
            homeDirectory: home)
        XCTAssertEqual(defaults["CODEX_HOME"], "/Users/tester/Library/Application Support/Mechanician-acme/codex")
    }

    func testCredentialAndBackgroundNamespacesFollowBundleIdentity() {
        XCTAssertEqual(
            MechanicianEnvironment.credentialServices(for: "ai.mechanician.app"),
            .init(
                anthropicAPIKey: "ANTHROPIC_API_KEY",
                openAIAPIKey: "OPENAI_API_KEY",
                mcpSecret: "ai.mechanician.mcp-secret",
                mcpOAuth: "ai.mechanician.mcp-oauth"))
        XCTAssertEqual(
            MechanicianEnvironment.credentialServices(for: "ai.mechanician.app.acme"),
            .init(
                anthropicAPIKey: "ANTHROPIC_API_KEY.acme",
                openAIAPIKey: "OPENAI_API_KEY.acme",
                mcpSecret: "ai.mechanician.mcp-secret.acme",
                mcpOAuth: "ai.mechanician.mcp-oauth.acme"))
        XCTAssertEqual(
            MechanicianEnvironment.scopedIdentifier(
                "ai.mechanician.ambient", for: "ai.mechanician.app"),
            "ai.mechanician.ambient")
        XCTAssertEqual(
            MechanicianEnvironment.scopedIdentifier(
                "ai.mechanician.ambient", for: "ai.mechanician.app.acme"),
            "ai.mechanician.ambient.acme")
    }

    // MARK: - Test isolation

    /// The one that matters. `ConversationStore.shared` and `ProjectStore.shared` take no override,
    /// so before this a test that touched either resolved the INSTALLED support root and wrote to
    /// the person's own conversations. On 2026-09-02 a `swift test` run recreated a real
    /// `projections.db` at a schema version the installed app could not read, and `library.db`
    /// escaped an irreversible rung only because the app happened to be open holding the lease.
    ///
    /// If the XCTest detection ever stops working, this fails rather than quietly writing to a real
    /// Mac again — which is the whole reason it asserts against the actual home rather than a fixture.
    func testDefaultSupportRootNeverResolvesTheInstalledStoreUnderTest() {
        XCTAssertTrue(
            MechanicianEnvironment.isRunningUnderXCTest,
            "the isolation is gated on this; if it is false, every store below writes to real data")

        let resolved = MechanicianEnvironment.currentSupportRoot(environment: [:])
        let installed = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support", isDirectory: true)
            .standardizedFileURL

        XCTAssertFalse(
            resolved.path.hasPrefix(installed.path),
            "a test resolved \(resolved.path), which is inside the installed store")
        XCTAssertTrue(
            resolved.path.hasPrefix(MechanicianEnvironment.testIsolationHome.path),
            "the default root must sit under the per-process isolation home")
    }

    /// The isolation replaces one default argument and nothing else: an explicit home still derives
    /// the real layout, so the fixtures above keep testing production behaviour rather than the guard.
    func testTestIsolationDoesNotLeakIntoExplicitArguments() {
        XCTAssertEqual(
            MechanicianEnvironment.currentSupportRoot(
                environment: [:],
                homeDirectory: home,
                bundleIdentifier: MechanicianEnvironment.baseBundleIdentifier).path,
            "/Users/tester/Library/Application Support/Mechanician")
        XCTAssertEqual(
            MechanicianEnvironment.currentSupportRoot(
                environment: ["MECHANICIAN_SUPPORT_DIR": "/tmp/explicit"]).path,
            "/tmp/explicit",
            "dev.sh's override must still win, test bundle or not")
    }

    /// Eleven stores each carried their own copy of this resolution. Nine hardcoded "Mechanician"
    /// and so ignored the bundle identity, and all eleven bypassed the isolation above. A twelfth
    /// copy would reopen both holes silently, so the rule is asserted against the source itself.
    func testNoSourceFileResolvesTheApplicationSupportDirectoryDirectly() throws {
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()      // MechanicianTests
            .deletingLastPathComponent()      // Tests
            .deletingLastPathComponent()      // app
            .appendingPathComponent("Sources/Mechanician", isDirectory: true)
        let files = try FileManager.default.contentsOfDirectory(
            at: sources, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" }
        XCTAssertGreaterThan(files.count, 100, "the scan must actually be reading the sources")

        var offenders: [String] = []
        for file in files where file.lastPathComponent != "MechanicianEnvironment.swift" {
            let text = try String(contentsOf: file, encoding: .utf8)
            if text.contains(".applicationSupportDirectory") {
                offenders.append(file.lastPathComponent)
            }
        }
        XCTAssertEqual(
            offenders, [],
            "resolve the support root through MechanicianEnvironment.currentSupportRoot()")
    }
}
