import Foundation

/// Locates the pinned Codex App Server included in release bundles.
///
/// The environment override is intentionally first for local adapter development. Downloaded apps
/// use the package-lock-pinned Darwin arm64 binary under Resources/agentd; legacy ChatGPT and PATH
/// installations remain compatibility fallbacks only.
enum CodexRuntime {
    static let bundledVersion = "0.148.0"
    static let bundledRelativePath =
        "agentd/node_modules/@openai/codex-darwin-arm64/" +
        "vendor/aarch64-apple-darwin/bin/codex"

    static func candidatePaths(
        environment: [String: String],
        resourceURL: URL?,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> [String] {
        var candidates: [String] = []
        if let explicit = environment["MECHANICIAN_CODEX_BIN"], !explicit.isEmpty {
            candidates.append(explicit)
        }
        if let resourceURL {
            candidates.append(resourceURL.appendingPathComponent(bundledRelativePath).path)
        }
        candidates.append(contentsOf: [
            "/Applications/ChatGPT.app/Contents/Resources/codex",
            "/opt/homebrew/bin/codex",
            "/usr/local/bin/codex",
            homeDirectory.appendingPathComponent(".local/bin/codex").path,
        ])
        var seen = Set<String>()
        return candidates.filter { seen.insert($0).inserted }
    }

    static func resolveBinary(
        environment: [String: String],
        resourceURL: URL? = Bundle.main.resourceURL,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        isExecutable: (String) -> Bool = FileManager.default.isExecutableFile(atPath:)
    ) -> URL? {
        candidatePaths(
            environment: environment,
            resourceURL: resourceURL,
            homeDirectory: homeDirectory
        )
        .first(where: isExecutable)
        .map(URL.init(fileURLWithPath:))
    }
}
