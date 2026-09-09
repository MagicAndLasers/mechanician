import Foundation

/// Process-wide paths that must be established before any store or provider runtime is created.
///
/// A distinct bundle identity is the durable boundary between the installed public app, the Dev
/// build, and any explicitly parameterized non-public bundle. Opening one of those bundles directly
/// must never fall back to
/// another identity's conversations, credentials, or Codex home merely because the launcher did not
/// preserve shell environment variables. `dev.sh` still supplies these values explicitly for
/// source-tree development, but the bundle identity is the durable boundary.
enum MechanicianEnvironment {
    struct CredentialServices: Equatable {
        var anthropicAPIKey: String
        var openAIAPIKey: String
        var mcpSecret: String
        var mcpOAuth: String

        var processEnvironment: [String: String] {
            [
                "MECHANICIAN_ANTHROPIC_API_KEY_SERVICE": anthropicAPIKey,
                "MECHANICIAN_OPENAI_API_KEY_SERVICE": openAIAPIKey,
                "MECHANICIAN_MCP_SECRET_SERVICE": mcpSecret,
                "MECHANICIAN_MCP_OAUTH_SERVICE": mcpOAuth,
            ]
        }
    }

    /// The public app's bundle identifier. Dev and per-tenant builds append a `.<slug>` segment.
    static let baseBundleIdentifier = "ai.mechanician.app"
    static let devBundleIdentifier = baseBundleIdentifier + ".dev"

    /// The identity slug carried by a bundle id, or `nil` for the public app.
    /// `ai.mechanician.app` → nil · `ai.mechanician.app.dev` → "dev" · `ai.mechanician.app.acme` → "acme".
    static func identitySlug(for bundleIdentifier: String?) -> String? {
        guard let id = bundleIdentifier, id.hasPrefix(baseBundleIdentifier + ".") else { return nil }
        let suffix = id.dropFirst(baseBundleIdentifier.count + 1)          // drop "ai.mechanician.app."
        let slug = suffix.split(separator: ".").first.map(String.init) ?? String(suffix)
        return slug.isEmpty ? nil : slug
    }

    /// The Application Support folder name for a bundle id.
    /// Public → "Mechanician"; dev → "Mechanician-dev"; tenant → "Mechanician-<slug>".
    ///
    /// Stores fall back to the bare "Mechanician" directory when no `MECHANICIAN_SUPPORT_DIR` override
    /// is present; a non-public build must therefore always run `bootstrapProcessIfNeeded()` at launch
    /// so this derived name — not the public default — takes effect.
    static func supportDirectoryName(for bundleIdentifier: String?) -> String {
        guard let slug = identitySlug(for: bundleIdentifier) else { return "Mechanician" }
        return "Mechanician-\(slug)"
    }

    /// The `mechanician://` link scheme for a bundle id.
    /// Public → "mechanician"; dev → "mechanician-dev"; tenant → "mechanician-<slug>".
    ///
    /// The scheme belongs to the installed identity for exactly the reason the support directory and
    /// the Keychain services do. A link carries a bare UUID, and each identity resolves UUIDs against
    /// its own store — so one shared scheme would let LaunchServices hand a link minted by the public
    /// app to a tenant or Dev bundle, which would look the UUID up in a different store and silently
    /// find nothing. `app/Mechanician-Info.plist` declares the public scheme; `build-app.sh` and
    /// `dev.sh` rewrite it for a non-public bundle id, mirroring this rule.
    static func urlScheme(for bundleIdentifier: String?) -> String {
        guard let slug = identitySlug(for: bundleIdentifier) else { return "mechanician" }
        return "mechanician-\(slug)"
    }

    static var currentURLScheme: String { urlScheme(for: Bundle.main.bundleIdentifier) }

    /// Keychain services are part of the installed identity, just like the support directory.
    /// Preserve the public app's historical names exactly; suffix every non-public identity so a
    /// tenant build cannot discover, overwrite, or remove a credential saved by another bundle.
    static func credentialServices(for bundleIdentifier: String?) -> CredentialServices {
        guard let slug = identitySlug(for: bundleIdentifier) else {
            return CredentialServices(
                anthropicAPIKey: "ANTHROPIC_API_KEY",
                openAIAPIKey: "OPENAI_API_KEY",
                mcpSecret: "ai.mechanician.mcp-secret",
                mcpOAuth: "ai.mechanician.mcp-oauth")
        }
        return CredentialServices(
            anthropicAPIKey: "ANTHROPIC_API_KEY.\(slug)",
            openAIAPIKey: "OPENAI_API_KEY.\(slug)",
            mcpSecret: "ai.mechanician.mcp-secret.\(slug)",
            mcpOAuth: "ai.mechanician.mcp-oauth.\(slug)")
    }

    static var currentCredentialServices: CredentialServices {
        credentialServices(for: Bundle.main.bundleIdentifier)
    }

    /// Reverse-DNS identifiers owned by a background component need the same identity suffix. This
    /// prevents launchd from treating two installed apps' schedulers as one job.
    static func scopedIdentifier(_ base: String, for bundleIdentifier: String?) -> String {
        guard let slug = identitySlug(for: bundleIdentifier) else { return base }
        return "\(base).\(slug)"
    }

    /// Environment overrides that isolate a non-public build's on-disk state. Empty for the public
    /// app — it uses the bare "Mechanician" support directory every store already falls back to, so
    /// its environment is never rewritten.
    static func processDefaults(
        bundleIdentifier: String?,
        environment: [String: String],
        homeDirectory: URL
    ) -> [String: String] {
        guard identitySlug(for: bundleIdentifier) != nil else { return [:] }
        let folder = supportDirectoryName(for: bundleIdentifier)

        let support = environment["MECHANICIAN_SUPPORT_DIR"]?.nonEmpty
            ?? homeDirectory
                .appendingPathComponent("Library/Application Support/\(folder)", isDirectory: true)
                .path
        let config = environment["MECHANICIAN_CONFIG_DIR"]?.nonEmpty
            ?? URL(fileURLWithPath: support, isDirectory: true)
                .appendingPathComponent("claude", isDirectory: true)
                .path
        // A dev or tenant launch often originates inside an installed Mechanician terminal. Never
        // inherit that process's CODEX_HOME: it would let two app identities drive one Codex
        // credential and session store. MECHANICIAN_DEV_CODEX_HOME remains an explicit dev-fixture
        // override.
        let codex = environment["MECHANICIAN_DEV_CODEX_HOME"]?.nonEmpty
            ?? URL(fileURLWithPath: support, isDirectory: true)
                .appendingPathComponent("codex", isDirectory: true)
                .path

        var defaults = [
            "MECHANICIAN_SUPPORT_DIR": support,
            "MECHANICIAN_CONFIG_DIR": config,
            "CODEX_HOME": codex,
        ]
        defaults.merge(
            credentialServices(for: bundleIdentifier).processEnvironment,
            uniquingKeysWith: { _, derived in derived })
        return defaults
    }

    /// Whether this process is a test bundle rather than the app.
    ///
    /// Checked two ways because either alone has a hole: the environment variable is absent when a
    /// test target is driven directly, and the class lookup is the only signal that survives a
    /// sanitized environment. Cached, because this sits under every store's path resolution.
    static let isRunningUnderXCTest: Bool =
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
            || NSClassFromString("XCTestCase") != nil

    /// A per-process stand-in for the user's home while a test bundle is running.
    ///
    /// **This is not a convenience.** `ConversationStore.shared` and `ProjectStore.shared` take no
    /// override, so a test that touches either resolves the INSTALLED support root and writes to
    /// the person's own conversations. That happened: on 2026-09-02 a `swift test` run recreated a
    /// real `projections.db` at a schema version the installed app could not read. `library.db`
    /// survived only because the app was open and held the storage lease — closed, the same run
    /// would have executed an irreversible schema rung against 1.27 GB of real conversations.
    ///
    /// A redirect rather than a refusal, because a refusal turns an accidental `.shared` into a
    /// crash in an unrelated suite, and the point is that no test should be able to reach the
    /// installed root by accident whether or not anyone remembers this rule.
    static let testIsolationHome: URL = {
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent(
                "mechanician-xctest-home-\(ProcessInfo.processInfo.processIdentifier)",
                isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root.standardizedFileURL
    }()

    /// The home directory every default path derivation hangs off. Real for the app, isolated for a
    /// test bundle. Callers that pass an explicit home — the environment fixtures — are unaffected.
    static var currentHomeDirectory: URL {
        isRunningUnderXCTest ? testIsolationHome : FileManager.default.homeDirectoryForCurrentUser
    }

    /// The one resolution of the Application Support root. Every store calls this rather than
    /// repeating it: nine of the eleven copies it replaced hardcoded "Mechanician" and so ignored
    /// the bundle identity entirely.
    static func currentSupportRoot(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: URL = currentHomeDirectory,
        bundleIdentifier: String? = Bundle.main.bundleIdentifier
    ) -> URL {
        if let override = environment["MECHANICIAN_SUPPORT_DIR"], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true).standardizedFileURL
        }
        return homeDirectory
            .appendingPathComponent("Library/Application Support", isDirectory: true)
            .appendingPathComponent(
                supportDirectoryName(for: bundleIdentifier), isDirectory: true)
            .standardizedFileURL
    }

    static func bootstrapProcessIfNeeded(
        acquireStorageLease: Bool = true,
        provisionsPristineLibrary: Bool = true
    ) {
        let defaults = processDefaults(
            bundleIdentifier: Bundle.main.bundleIdentifier,
            environment: ProcessInfo.processInfo.environment,
            homeDirectory: FileManager.default.homeDirectoryForCurrentUser)
        for (name, value) in defaults {
            setenv(name, value, 1)
        }
        StorageAuthorityBootstrap.recognizeCurrentProcess(
            acquireLease: acquireStorageLease,
            provisionsPristineLibrary: provisionsPristineLibrary)
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
