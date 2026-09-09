import SwiftUI

// The Extensions utility is installed-first, with explicit discovery tabs for public MCP registries
// and plugin marketplaces. Command-based MCP servers show their exact launch command and require
// confirmation before being recorded or started.

// MARK: - Browse fetch (routed through agentd)

/// Routes browse HTTP GETs through agentd, whose network path is the one that reaches Anthropic for
/// every turn — the app process's OWN `URLSession` can be blocked by a corporate proxy / VPN / firewall
/// (that's the "Couldn't reach the MCP registry" a non-sandboxed app still hits). Request/response is
/// correlated by id over NDJSON; agentd accepts only bounded HTTPS responses.
@MainActor final class BrowseFetcher {
    static let shared = BrowseFetcher()
    struct BrowseError: LocalizedError {
        enum Kind: String {
            case network, timeout, authentication, http, configuration
            case invalidResponse = "invalid_response"
            case unavailable, unknown
        }
        let kind: Kind
        let message: String
        let status: Int?
        let code: String?
        var errorDescription: String? { message }

        init(kind: Kind, message: String, status: Int? = nil, code: String? = nil) {
            self.kind = kind
            self.message = message
            self.status = status
            self.code = code
        }
    }
    private var pending: [String: CheckedContinuation<Data, Error>] = [:]

    func get(
        _ url: String,
        via bridge: AgentBridge?,
        authentication: ExtensionSourceAuthentication? = nil
    ) async throws -> Data {
        // Readiness is judged by `browseFetch`, which alone knows WHICH lane will serve this URL —
        // a managed catalog authenticated with the enterprise Google identity is served by the
        // Vertex daemon regardless of the lane this window is showing. Gating on the visible lane's
        // readiness here hid managed catalogs behind an unrelated provider's connection state.
        guard let bridge else {
            throw BrowseError(kind: .unavailable, message: "The provider isn't ready yet.")
        }
        let id = UUID().uuidString
        return try await withCheckedThrowingContinuation { cont in
            pending[id] = cont
            bridge.browseFetch(id: id, url: url, authentication: authentication)
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: 20 * NSEC_PER_SEC)
                if let c = self?.pending.removeValue(forKey: id) {
                    c.resume(throwing: BrowseError(
                        kind: .timeout, message: "The catalog request timed out."))
                }
            }
        }
    }
    func resolve(
        id: String,
        body: Data?,
        error: String?,
        errorType: String? = nil,
        status: Int? = nil,
        code: String? = nil
    ) {
        guard let cont = pending.removeValue(forKey: id) else { return }
        if let error {
            cont.resume(throwing: BrowseError(
                kind: BrowseError.Kind(rawValue: errorType ?? "") ?? .unknown,
                message: error,
                status: status,
                code: code))
        }
        else if let body { cont.resume(returning: body) }
        else {
            cont.resume(throwing: BrowseError(
                kind: .invalidResponse, message: "The catalog returned an empty response."))
        }
    }
}

// MARK: - Maker badge (real brand colors + monogram, no network needed)

/// A colored monogram badge for a maker — real brand colors for known makers, a stable deterministic
/// color otherwise. Replaces the generic puzzle/cloud glyph so brands read at a glance (and it never
/// depends on the network, which can be proxy-blocked here).
struct MakerBadge: View {
    let text: String
    var size: CGFloat = 40

    typealias RGB = (red: Double, green: Double, blue: Double)

    static let brand: [String: RGB] = [
        // Google blue is deepened to its darker brand-family blue so a white monogram clears 4.5:1
        // instead of putting black lettering on a saturated blue tile.
        "google": (0.10, 0.40, 0.82), "google llc": (0.10, 0.40, 0.82), "google cloud": (0.10, 0.40, 0.82),
        "adobe": (0.92, 0.10, 0.09), "microsoft": (0.0, 0.47, 0.83),
        "amazon web services": (1.0, 0.6, 0.0), "aws": (1.0, 0.6, 0.0), "amazon": (1.0, 0.6, 0.0),
        "anthropic": (0.83, 0.47, 0.35), "anthropic official": (0.83, 0.47, 0.35),
        "github": (0.42, 0.46, 0.51), "gitlab": (0.98, 0.40, 0.13),
        "stripe": (0.39, 0.36, 1.0), "cloudflare": (0.95, 0.50, 0.13),
        "apollo graphql": (0.20, 0.11, 0.53), "atlassian": (0.0, 0.32, 0.8),
        "sentry": (0.44, 0.30, 0.62), "linear": (0.37, 0.42, 0.82), "figma": (0.95, 0.31, 0.12),
        "slack": (0.29, 0.08, 0.29), "paypal": (0.0, 0.19, 0.53), "openai": (0.06, 0.64, 0.5),
        "mongodb": (0.28, 0.64, 0.28), "docker": (0.14, 0.59, 0.93), "notion": (0.22, 0.22, 0.24),
        "vercel": (0.10, 0.10, 0.12), "databricks": (1.0, 0.21, 0.13), "snowflake": (0.16, 0.71, 0.91),
        "hashicorp": (0.48, 0.26, 0.74), "twilio": (0.94, 0.15, 0.20), "elastic": (0.0, 0.74, 0.61),
        "datadog": (0.39, 0.20, 0.56), "canva": (0.0, 0.78, 0.87), "airtable": (0.20, 0.42, 0.92),
    ]
    static let palette: [RGB] = [
        (0.19, 0.36, 0.75), (0.80, 0.42, 0.42), (0.30, 0.62, 0.50), (0.72, 0.55, 0.25),
        (0.41, 0.28, 0.66), (0.28, 0.60, 0.70), (0.78, 0.44, 0.56), (0.48, 0.55, 0.33),
    ]

    static func stableHash(_ string: String) -> Int {
        string.unicodeScalars.reduce(5381) { ($0 &* 33) &+ Int($1.value) }
    }

    static func rgb(for text: String) -> RGB {
        if let brand = brand[text.lowercased()] { return brand }
        let index = Int(stableHash(text).magnitude % UInt(palette.count))
        return palette[index]
    }

    /// Prefer white whenever it clears small-text contrast, so saturated blue and violet badges do
    /// not get the technically marginal but visually hostile black-on-color treatment. Truly light
    /// fills such as AWS orange and Canva cyan fall back to black.
    static func usesLightInk(on fill: RGB) -> Bool {
        func linear(_ component: Double) -> Double {
            component <= 0.04045
                ? component / 12.92
                : pow((component + 0.055) / 1.055, 2.4)
        }
        let luminance = 0.2126 * linear(fill.red)
            + 0.7152 * linear(fill.green)
            + 0.0722 * linear(fill.blue)
        let blackContrast = (luminance + 0.05) / 0.05
        let whiteContrast = 1.05 / (luminance + 0.05)
        assert(max(blackContrast, whiteContrast) >= 4.5)
        return whiteContrast >= 4.5
    }

    private var rgb: RGB { Self.rgb(for: text) }
    private var color: Color {
        Color(red: rgb.red, green: rgb.green, blue: rgb.blue)
    }
    private var ink: Color {
        Self.usesLightInk(on: rgb) ? .white : .black
    }
    private var initials: String {
        let words = text.split(whereSeparator: { " -._/".contains($0) }).filter { !$0.isEmpty }
        guard let f = words.first?.first else { return "?" }
        if words.count > 1, let s = words[1].first { return (String(f) + String(s)).uppercased() }
        return String(f).uppercased()
    }
    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.26, style: .continuous)
            .fill(color)
            .frame(width: size, height: size)
            .overlay(Text(initials).font(.system(size: size * 0.4, weight: .bold, design: .rounded)).foregroundStyle(ink))
            .overlay(RoundedRectangle(cornerRadius: size * 0.26, style: .continuous).strokeBorder(.white.opacity(0.14)))
    }
}

/// Registry governance is informational, not an installation gate. Enterprise catalogs often expose
/// useful servers while their internal review is still in progress, so only non-approved entries need
/// a warning badge; they remain fully connectable.
struct RegistryGovernanceBadge: View {
    let governance: MCPRegistryServer.Governance?

    @ViewBuilder var body: some View {
        if let governance, !governance.isApproved {
            Text("Not approved")
                .font(.caption2)
                .foregroundStyle(Color.nWarningText)
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(Capsule().fill(Color.orange.opacity(0.16)))
                .help("Registry governance status: \(governance.status). You can still connect this server.")
                .accessibilityLabel("Not approved. Registry status: \(governance.status)")
        }
    }
}

// MARK: - Featured (trusted) makers

/// Curated list of well-known makers whose extensions we surface first + badge as trusted. Heuristic —
/// there's no "verified" flag in the public data, so we match maker names / registry namespaces.
enum FeaturedMakers {
    static let names: Set<String> = [
        "anthropic", "anthropic official", "model context protocol", "microsoft", "github", "google",
        "google cloud", "amazon web services", "aws", "adobe", "atlassian", "notion", "stripe",
        "cloudflare", "vercel", "mongodb", "elastic", "datadog", "sentry", "linear", "figma", "gitlab",
        "hashicorp", "openai", "slack", "shopify", "paypal", "apollo graphql", "auth0", "canva",
        "airtable", "docker", "postman", "jetbrains", "redis", "snowflake", "databricks", "supabase",
        "netlify", "twilio", "okta", "salesforce", "sap", "ibm", "oracle", "nvidia", "apple", "grafana",
    ]
    static func featured(_ maker: String) -> Bool {
        let m = maker.lowercased()
        if names.contains(m) { return true }
        return ["anthropic", "microsoft", "google", "amazon", "adobe"].contains { m.hasPrefix($0) }
    }
    /// Recognized orgs — matched EXACTLY (not substring, so "elasticflow" never passes as "elastic").
    static let trustedOrgs: Set<String> = [
        "anthropic", "anthropics", "modelcontextprotocol", "microsoft", "google", "googleapis",
        "aws", "awslabs", "amazon", "stripe", "cloudflare", "notion", "makenotion", "notionhq",
        "atlassian", "sentry", "getsentry", "linear", "paypal", "mongodb", "mongodb-js", "figma",
        "grafana", "elastic", "vercel", "supabase", "asana", "slack", "intercom", "square", "block",
        "huggingface", "github", "gitlab", "netlify", "hashicorp", "openai", "adobe", "canva",
        "airtable", "twilio", "datadog", "snowflake", "databricks", "shopify", "auth0", "okta",
    ]
    /// For MCP: trust ONLY the reverse-DNS NAME namespace, which the registry validates as owned by
    /// that org (io.github.OWNER = that GitHub owner; com.stripe = owns stripe.com). The repo URL is
    /// NOT trusted — anyone can point it at a big-name repo — which is how look-alikes slipped in.
    static func featuredServer(name: String, repo: String?) -> Bool {
        let ns = name.split(separator: "/").first.map(String.init) ?? name
        let parts = ns.split(separator: ".").map(String.init)
        // Only a 2-component company domain (com.stripe = owns stripe.com) or io.github.<org> is
        // trusted. A 3+-component name like app.vercel.<x> is a platform SUBDOMAIN (x.vercel.app) —
        // owned by a rando, NOT the platform — so it never qualifies.
        if parts.count == 2 { return trustedOrgs.contains(parts[1].lowercased()) }
        if parts.count >= 3, parts[0] == "io", parts[1] == "github" { return trustedOrgs.contains(parts[2].lowercased()) }
        return false
    }
}

/// A small, HAND-CURATED catalog of genuinely good servers, headlined by MCP reference servers.
/// npm entries use Mechanician's bundled npx; uvx entries state their external runtime requirement.
/// The default view therefore leads with recognizable, reviewable commands regardless of the feed.
/// Merged ABOVE the live ranked feed (deduped by name); the full registry is one search away.
/// The list shown by "Add Server". Every entry here is VERIFIED — published by the vendor whose
/// service it exposes — with one deliberate exception marked below. The bar is not "servers we
/// think are good"; it is "companies you already have an account with", because that is the only
/// judgement a user can make without auditing a stranger's code.
///
/// This is a stopgap: the list is compiled into the binary, so it cannot be updated without
/// shipping a build, and it is nobody's registry. It should become a signed manifest fetched out
/// of band (see EXTENSIONS-MODEL-PLAN.md, Phase 4). Marking provenance now is what makes that
/// migration invisible when it happens.
enum MCPCatalog {
    private static func stdio(_ name: String, _ title: String, _ desc: String, _ runtime: String, _ id: String,
                              repo: String? = nil, publisher: String) -> MCPRegistryServer {
        MCPRegistryServer(
            name: name, description: desc, title: title,
            repository: repo.map { MCPRegistryServer.Repo(url: $0) },
            packages: [MCPRegistryServer.Package(
                registryType: nil, identifier: id, version: nil, runtimeHint: runtime,
                transport: MCPRegistryServer.Package.Transport(type: "stdio"), environmentVariables: nil)],
            source: .verified, publisher: publisher)
    }
    private static func remote(_ name: String, _ title: String, _ desc: String, _ url: String,
                               home: String? = nil, publisher: String) -> MCPRegistryServer {
        MCPRegistryServer(name: name, description: desc, title: title, websiteUrl: home,
                          remotes: [MCPRegistryServer.Remote(type: "streamable-http", url: url, headers: nil)],
                          source: .verified, publisher: publisher)
    }
    private static let mcpRepo = "https://github.com/modelcontextprotocol/servers"
    static let servers: [MCPRegistryServer] = [
        // First-party REMOTE servers with real MCP OAuth (verified live 2026-07-10: each answers
        // 401 + WWW-Authenticate resource_metadata, the RFC 9728 discovery our Sign-in flow drives).
        remote("com.github/mcp", "GitHub", "GitHub's official remote MCP server: repos, issues, PRs, actions. GitHub requires a personal access token in the connection's Authorization header.", "https://api.githubcopilot.com/mcp/", home: "https://github.com/github/github-mcp-server", publisher: "GitHub"),
        remote("com.notion/mcp", "Notion", "Official Notion MCP server: search, read, and write your workspace. OAuth sign-in.", "https://mcp.notion.com/mcp", home: "https://developers.notion.com/docs/mcp", publisher: "Notion"),
        remote("app.linear/mcp", "Linear", "Official Linear MCP server: issues, projects, and team workflows. OAuth sign-in.", "https://mcp.linear.app/mcp", home: "https://linear.app/docs/mcp", publisher: "Linear"),
        remote("dev.sentry/mcp", "Sentry", "Official Sentry MCP server: issues, errors, and traces. OAuth sign-in.", "https://mcp.sentry.dev/mcp", home: "https://docs.sentry.io/product/sentry-mcp/", publisher: "Sentry"),
        // Community Outlook server — stdio with its OWN Microsoft login (Entra client ID + one-time
        // `login` run), NOT MCP OAuth. The env schema below drives the setup form.
        MCPRegistryServer(
            name: "io.github.0xka13b/microsoft-outlook-mcp",
            description: "Read, search, and send Outlook mail via Microsoft Graph. Community server: needs your own Entra ID app's client ID, then a one-time `login` in a terminal.",
            title: "Microsoft Outlook (community)",
            repository: MCPRegistryServer.Repo(url: "https://github.com/0xka13b/microsoft-mcps"),
            packages: [MCPRegistryServer.Package(
                registryType: "npm", identifier: "microsoft-outlook-mcp", version: nil, runtimeHint: "npx",
                transport: MCPRegistryServer.Package.Transport(type: "stdio"),
                environmentVariables: [
                    .init(name: "MICROSOFT_CLIENT_ID", description: "Your Entra ID app's Application (client) ID. Register at entra.microsoft.com (public client, Mail.ReadWrite + Mail.Send).", isRequired: true, isSecret: false, defaultValue: nil),
                    .init(name: "MICROSOFT_TENANT_ID", description: "Optional: common (default), consumers, organizations, or a tenant GUID.", isRequired: false, isSecret: false, defaultValue: nil),
                ])]),
        stdio("com.anthropic/fetch", "Fetch", "Fetch any URL and hand the agent clean markdown. Requires uv/uvx.", "uvx", "mcp-server-fetch", repo: mcpRepo, publisher: "Anthropic"),
        stdio("com.anthropic/everything", "Everything (reference)", "Anthropic's MCP reference server. Exercises every protocol feature, so it is a good one to try first.", "npx", "@modelcontextprotocol/server-everything", repo: mcpRepo, publisher: "Anthropic"),
        stdio("com.anthropic/sequential-thinking", "Sequential Thinking", "Structured, step-by-step reasoning exposed as a tool.", "npx", "@modelcontextprotocol/server-sequential-thinking", repo: mcpRepo, publisher: "Anthropic"),
        stdio("com.anthropic/memory", "Memory", "A persistent knowledge-graph memory the agent can read and write.", "npx", "@modelcontextprotocol/server-memory", repo: mcpRepo, publisher: "Anthropic"),
        stdio("com.anthropic/time", "Time", "Current time and timezone conversions. Requires uv/uvx.", "uvx", "mcp-server-time", repo: mcpRepo, publisher: "Anthropic"),
        stdio("com.anthropic/git", "Git", "Inspect and operate on a local git repository. Requires uv/uvx.", "uvx", "mcp-server-git", repo: mcpRepo, publisher: "Anthropic"),
        stdio("com.anthropic/filesystem", "Filesystem", "Read and write files in folders you allow (add a path after connecting).", "npx", "@modelcontextprotocol/server-filesystem", repo: mcpRepo, publisher: "Anthropic"),
        stdio("com.microsoft/playwright", "Playwright", "Drive a real browser: navigate, click, and extract page content.", "npx", "@playwright/mcp@latest", repo: "https://github.com/microsoft/playwright-mcp", publisher: "Microsoft"),
    ]
}

// MARK: - Official MCP Registry client (registry.modelcontextprotocol.io)

/// One list page: { servers: [{ server }], metadata: { nextCursor, count } }.
struct MCPRegistryResponse: Decodable {
    let servers: [Item]
    let metadata: Meta?
    struct Item: Decodable { let server: MCPRegistryServer }
    struct Meta: Decodable { let nextCursor: String?; let count: Int? }
}

/// A registry entry. `packages` → local/stdio launch; `remotes` → hosted server (+ OAuth). Both carry
/// enough to auto-configure a connection (see the registry's server.json schema).
struct MCPRegistryServer: Decodable, Identifiable {
    enum DeclaredAuthentication: String {
        case oauth2
        case bearerToken = "bearer-token"
        case apiKey = "api-key"
    }

    struct Governance: Equatable {
        let status: String
        var isApproved: Bool
    }

    let name: String                 // reverse-DNS, e.g. "io.github.owner/repo"
    let description: String
    let title: String?
    let version: String?
    let websiteUrl: String?
    let repository: Repo?
    let packages: [Package]?
    let remotes: [Remote]?
    let declaredAuthentication: DeclaredAuthentication?
    var governance: Governance?
    // Quality signals — NOT in the official schema; filled by enrichment adapters (e.g. PulseMCP) and
    // merged across sources by the same-name dedupe. `var` so a later source can fill what an earlier
    // one lacked.
    var stars: Int?
    var downloads: Int?
    /// Catalog provenance is attached after decoding so a connected server retains its VPN scope.
    var source: ExtensionSource?
    /// Who published it. Only meaningful alongside `source == .verified`, where it is the whole
    /// basis of the claim: this came from the vendor whose service it exposes.
    var publisher: String?
    var networkScope: ExtensionNetworkScope?
    var sha256: String?

    init(name: String, description: String, title: String? = nil, version: String? = nil,
         websiteUrl: String? = nil, repository: Repo? = nil, packages: [Package]? = nil,
         remotes: [Remote]? = nil, declaredAuthentication: DeclaredAuthentication? = nil,
         governance: Governance? = nil, stars: Int? = nil, downloads: Int? = nil,
         source: ExtensionSource? = nil, publisher: String? = nil,
         networkScope: ExtensionNetworkScope? = nil, sha256: String? = nil) {
        self.name = name; self.description = description; self.title = title; self.version = version
        self.websiteUrl = websiteUrl; self.repository = repository; self.packages = packages; self.remotes = remotes
        self.declaredAuthentication = declaredAuthentication; self.governance = governance
        self.stars = stars; self.downloads = downloads
        self.source = source; self.publisher = publisher
        self.networkScope = networkScope; self.sha256 = sha256
    }
    /// Sort key for popularity — downloads dominate stars (starring ≠ using). Missing → 0.
    var popularity: (Int, Int) { (downloads ?? 0, stars ?? 0) }

    var id: String { name }
    var shortName: String { name.split(separator: "/").last.map(String.init) ?? name }
    /// A human title. Many registry entries are named `com.stripe/mcp` → shortName "mcp"; fall back
    /// to the capitalized maker/org so brands read clearly (Stripe, Notion, Cloudflare…).
    var displayTitle: String {
        if let t = title, !t.isEmpty { return t }
        let generic: Set<String> = ["mcp", "server", "mcp-server", "mcp_server", "mcpserver", "main", "index", "app"]
        if generic.contains(shortName.lowercased()) { return maker.prefix(1).uppercased() + maker.dropFirst() }
        return shortName
    }
    var isRemote: Bool { !(remotes?.isEmpty ?? true) }
    var firstRemote: Remote? { remotes?.first }
    var firstPackage: Package? { packages?.first }

    // Detail helpers so a user can judge a server before connecting.
    var repoURL: URL? { (repository?.url).flatMap { URL(string: $0) } }
    var websiteURL: URL? { websiteUrl.flatMap { URL(string: $0) } }
    var maker: String {   // parse the real owner out of the reverse-DNS name
        let ns = name.split(separator: "/").first.map(String.init) ?? name
        let parts = ns.split(separator: ".").map(String.init)
        if parts.count >= 3, parts[0] == "io", parts[1] == "github" { return parts[2] }   // io.github.OWNER
        // platform subdomains (x.vercel.app, x.herokuapp.com…) → the deployer x, not the platform
        let platforms: Set<String> = ["vercel", "github", "herokuapp", "netlify", "fly", "railway",
                                      "web", "pages", "workers", "onrender", "render", "appspot"]
        if parts.count >= 3, platforms.contains(parts[1].lowercased()) { return parts[2] }
        if parts.count >= 2 { return parts[1] }                                            // com.notion -> notion
        return parts.first ?? ns
    }
    var isFeatured: Bool { FeaturedMakers.featuredServer(name: name, repo: repository?.url) }

    /// Nine of Microsoft Azure's ninety entries are Foundry built-in tools whose remote points at
    /// `placeholder.mcp.microsoft.com` — they describe capabilities of the Foundry service, not
    /// endpoints anything can connect to. Offering them would be offering a dead Add button.
    var isUnconnectablePlaceholder: Bool {
        remotes?.contains { URL(string: $0.url)?.host?.contains("placeholder.") == true } ?? false
    }
    var packageSpecifier: String? {
        guard let package = firstPackage,
              let identifier = package.identifier?.trimmingCharacters(in: .whitespacesAndNewlines),
              !identifier.isEmpty else { return nil }
        guard let version = package.version?.trimmingCharacters(in: .whitespacesAndNewlines),
              !version.isEmpty else { return identifier }
        return "\(identifier)@\(version)"
    }
    var stdioCommand: String? {
        guard let p = firstPackage, let id = packageSpecifier else { return nil }
        let cmd = p.runtimeHint ?? "npx"
        return cmd == "npx" ? "npx -y \(id)" : "\(cmd) \(id)"
    }
    var requiredEnv: [String] {
        (firstPackage?.environmentVariables ?? []).filter { $0.isRequired == true || $0.isSecret == true }.map(\.name)
    }
    var remoteNeedsAuth: Bool {
        (firstRemote?.headers ?? []).contains { $0.isRequired == true || $0.isSecret == true }
    }
    var governanceBadge: String? {
        governance.map { $0.isApproved ? "Approved" : "Not approved" }
    }
    var authenticationBadge: String? {
        switch declaredAuthentication {
        case .oauth2: return "OAuth"
        case .bearerToken: return "Token"
        case .apiKey: return "API key"
        case .none: return nil
        }
    }
    var authenticationDescription: String {
        switch declaredAuthentication {
        case .oauth2:
            return "OAuth: sign in after connecting"
        case .bearerToken:
            return "Bearer token: enter it when connecting"
        case .apiKey:
            return "API key: enter it when connecting"
        case .none:
            return remoteNeedsAuth
                ? "Token or API key: enter it when connecting"
                : "Server-defined: Mechanician checks when connecting"
        }
    }
    /// Whether connecting needs sign-in / config. Remote servers are assumed to need OAuth (it's
    /// negotiated at connect and not reliably declared in the registry), so only zero-config stdio
    /// servers count as "no sign-in" — those are the ones you can install and try immediately.
    var needsSetup: Bool { isRemote ? true : !requiredEnv.isEmpty }

    // Tolerant decode: a single unexpected field on ONE server must not fail the whole page (that
    // surfaced as "Couldn't reach the MCP registry"). Every field is best-effort; a server that
    // can't yield a name is dropped by the client. packages/remotes fall to nil on any mismatch.
    enum CodingKeys: String, CodingKey {
        case name, description, title, version, websiteUrl, repository, packages, remotes
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = (try? c.decode(String.self, forKey: .name)) ?? ""
        description = (try? c.decode(String.self, forKey: .description)) ?? ""
        title = (try? c.decodeIfPresent(String.self, forKey: .title)) ?? nil
        version = (try? c.decodeIfPresent(String.self, forKey: .version)) ?? nil
        websiteUrl = (try? c.decodeIfPresent(String.self, forKey: .websiteUrl)) ?? nil
        repository = (try? c.decodeIfPresent(Repo.self, forKey: .repository)) ?? nil
        packages = (try? c.decodeIfPresent([Package].self, forKey: .packages)) ?? nil
        remotes = (try? c.decodeIfPresent([Remote].self, forKey: .remotes)) ?? nil
        declaredAuthentication = nil
        governance = nil
        stars = nil; downloads = nil   // official schema carries no popularity; enrichment fills these
        source = nil; networkScope = nil; sha256 = nil
    }

    struct Repo: Decodable { let url: String? }
    struct Package: Decodable {
        let registryType: String?
        let identifier: String?
        let version: String?
        let runtimeHint: String?     // npx / uvx / docker …
        let transport: Transport?
        let environmentVariables: [EnvVar]?
        struct Transport: Decodable { let type: String? }
        struct EnvVar: Decodable {
            let name: String
            let description: String?
            let isRequired: Bool?
            let isSecret: Bool?
            let defaultValue: String?
            enum CodingKeys: String, CodingKey {
                case name, description, isRequired, isSecret, defaultValue = "default"
            }
        }
    }
    struct Remote: Decodable {
        let type: String             // streamable-http | sse
        let url: String
        let headers: [Header]?
        struct Header: Decodable { let name: String; let isRequired: Bool?; let isSecret: Bool? }
    }
}

// MARK: - Registry adapters (per-format query params + decode → the app's normalized model)

/// Adapts each `RegistryFormat` to a set of URL query items and a decoder into `[MCPRegistryServer]`.
/// The official schema is the identity/launch spine; other formats (e.g. PulseMCP) enrich it with
/// popularity signals. Nothing is hardcoded here — servers come from the live sources in Settings.
enum RegistryAdapter {
    static func queryItems(_ format: RegistryFormat, search: String, limit: Int) -> [URLQueryItem] {
        switch format {
        case .officialV01:
            // `version=latest` is not optional. Without it the registry returns EVERY published
            // version of every server, so a page spends its budget on duplicates — a limit=2 probe
            // came back as ac.inference.sh/mcp 1.0.0 AND 1.0.1, the same server twice.
            var q = [URLQueryItem(name: "limit", value: String(limit)),
                     URLQueryItem(name: "version", value: "latest")]
            // Worth knowing when reading results: this `search` is a NAME-substring match, not
            // full text. `search=github` does not surface `com.github/mcp`. The client filters
            // locally over name+title+description as well, which is what makes the box usable.
            if !search.isEmpty { q.append(URLQueryItem(name: "search", value: search)) }
            return q
        case .pulseBeta:
            var q = [URLQueryItem(name: "count_per_page", value: String(min(limit, 100)))]
            if !search.isEmpty { q.append(URLQueryItem(name: "query", value: search)) }
            return q
        case .generic:
            return [] // static catalogs; search is filtered locally after normalization
        }
    }

    static func decode(
        _ data: Data,
        format: RegistryFormat,
        governancePolicy: TenantProfile.RegistryGovernancePolicy? = nil,
        endpointRule: TenantProfile.RegistryEndpointRule? = nil
    ) throws -> [MCPRegistryServer] {
        switch format {
        case .officialV01:
            return try JSONDecoder().decode(MCPRegistryResponse.self, from: data).servers.map(\.server)
        case .pulseBeta:
            return try PulseMCPAdapter.decode(data)
        case .generic:
            return try GenericMCPRegistryAdapter.decode(
                data,
                governancePolicy: governancePolicy,
                endpointRule: endpointRule)
        }
    }

    static func filtersLocally(_ format: RegistryFormat) -> Bool {
        format == .generic
    }
}

/// PulseMCP's `/v0beta/servers` payload → the app model. Normalizes each entry's identity to the SAME
/// reverse-DNS scheme the official registry uses (from the GitHub source URL), so cross-source dedupe
/// merges duplicates and the verified-namespace check applies uniformly. Carries stars + downloads.
enum PulseMCPAdapter {
    private struct Resp: Decodable { let servers: [Srv]? }
    private struct Srv: Decodable {
        let name: String?
        let short_description: String?
        let external_url: String?
        let source_code_url: String?
        let github_stars: Int?
        let package_registry: String?
        let package_name: String?
        let package_download_count: Int?
    }

    static func decode(_ data: Data) throws -> [MCPRegistryServer] {
        (try JSONDecoder().decode(Resp.self, from: data).servers ?? []).compactMap(map)
    }

    private static func map(_ s: Srv) -> MCPRegistryServer? {
        let display = (s.name ?? "").trimmingCharacters(in: .whitespaces)
        // Prefer a DNS-verifiable identity from the GitHub repo (io.github.owner/repo); else a package
        // or display-derived namespace (unverified, so it won't pass the first-party filter).
        let name: String
        if let gh = githubName(s.source_code_url) { name = gh }
        else if let pkg = s.package_name, !pkg.isEmpty { name = "pkg.\(pkg)" }
        else if !display.isEmpty { name = "pulse.\(slug(display))" }
        else { return nil }

        var packages: [MCPRegistryServer.Package]?
        if let pkg = s.package_name, !pkg.isEmpty {
            packages = [MCPRegistryServer.Package(
                registryType: s.package_registry, identifier: pkg, version: nil,
                runtimeHint: runtime(for: s.package_registry),
                transport: MCPRegistryServer.Package.Transport(type: "stdio"), environmentVariables: nil)]
        }
        return MCPRegistryServer(
            name: name, description: s.short_description ?? "",
            title: display.isEmpty ? nil : display, websiteUrl: s.external_url,
            repository: s.source_code_url.map { MCPRegistryServer.Repo(url: $0) },
            packages: packages, remotes: nil, stars: s.github_stars, downloads: s.package_download_count)
    }

    /// `https://github.com/OWNER/REPO` → `io.github.owner/repo` (lowercased for stable dedupe).
    static func githubName(_ url: String?) -> String? {
        guard let url, let comps = URLComponents(string: url), (comps.host ?? "").contains("github.com") else { return nil }
        let p = comps.path.split(separator: "/").map(String.init)
        guard p.count >= 2 else { return nil }
        let repo = p[1].replacingOccurrences(of: ".git", with: "")
        return "io.github.\(p[0].lowercased())/\(repo.lowercased())"
    }
    private static func runtime(for registry: String?) -> String {
        switch (registry ?? "").lowercased() {
        case "pypi": return "uvx"
        case "docker", "oci": return "docker"
        default: return "npx"   // npm and unknowns
        }
    }
    private static func slug(_ s: String) -> String {
        s.lowercased()
            .replacingOccurrences(of: "[^a-z0-9]+", with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }
}

struct ExtensionSourceIssue: Identifiable, Equatable {
    let sourceID: UUID
    let sourceName: String
    let networkScope: ExtensionNetworkScope?
    let authentication: ExtensionSourceAuthentication?
    let kind: BrowseFetcher.BrowseError.Kind
    let detail: String
    let status: Int?
    var id: UUID { sourceID }
    var isRetryable: Bool {
        switch kind {
        case .network, .timeout, .http, .unavailable, .unknown: return true
        case .authentication, .configuration, .invalidResponse: return false
        }
    }
    var needsGoogleReconnect: Bool {
        kind == .authentication && authentication == .googleIdentity
    }
    var systemImage: String {
        switch kind {
        case .network, .timeout:
            return networkScope == .vpnOnly ? "network.slash" : "wifi.exclamationmark"
        case .authentication: return "person.crop.circle.badge.exclamationmark"
        case .http: return "exclamationmark.icloud"
        case .configuration: return "gear.badge.xmark"
        case .invalidResponse: return "doc.badge.ellipsis"
        case .unavailable, .unknown: return "exclamationmark.triangle"
        }
    }
    var message: String {
        switch kind {
        case .network where networkScope == .vpnOnly,
             .timeout where networkScope == .vpnOnly:
            return "Couldn’t reach \(sourceName). Connect to your corporate VPN and retry."
        case .network:
            return "Couldn’t reach \(sourceName). Check your network connection and retry."
        case .timeout:
            return "\(sourceName) took too long to respond. Check your connection and retry."
        case .authentication:
            if authentication == .googleIdentity {
                return "\(sourceName) needs your Google account. Reconnect the configured provider and retry."
            }
            return "\(sourceName) requires authentication before its catalog can be loaded."
        case .http where status == 403:
            return "\(sourceName) denied access (HTTP 403). Check the catalog’s access policy."
        case .http:
            return "\(sourceName) returned \(status.map { "HTTP \($0)" } ?? "an HTTP error")."
        case .configuration:
            return "\(sourceName) is misconfigured: \(detail)"
        case .invalidResponse:
            return "\(sourceName) returned catalog data Mechanician couldn’t understand."
        case .unavailable:
            return "\(sourceName) is temporarily unavailable: \(detail)"
        case .unknown:
            return "\(sourceName) is unavailable: \(detail)"
        }
    }
}

@MainActor final class MCPRegistryClient: ObservableObject {
    @Published var servers: [MCPRegistryServer] = []
    @Published var loading = false
    @Published var error: String?
    @Published var sourceIssues: [ExtensionSourceIssue] = []

    /// Fetch across ALL enabled configured sources (via agentd; the app's own URLSession can be
    /// proxy/VPN-blocked), decode via each source's `RegistryAdapter`, and merge by reverse-DNS name —
    /// filling popularity signals (stars/downloads) from whichever source has them. An unreachable
    /// source (e.g. PulseMCP's flaky keyless endpoint) is skipped; the others still populate the list.
    private func fetchMerged(search: String, limit: Int, via bridge: AgentBridge?,
                             sources: [RegistrySource]) async -> (servers: [MCPRegistryServer], issues: [ExtensionSourceIssue]) {
        let active = sources.filter { $0.enabled && $0.isValid }
        guard !active.isEmpty else {
            return ([], [])
        }
        var byName: [String: MCPRegistryServer] = [:]
        var order: [String] = []
        var issues: [ExtensionSourceIssue] = []
        let s = search.trimmingCharacters(in: .whitespaces)
        for src in active {
            guard var comps = URLComponents(string: src.url) else { continue }
            comps.queryItems = (comps.queryItems ?? []) + RegistryAdapter.queryItems(src.format, search: s, limit: limit)
            guard let url = comps.url else { continue }
            do {
                let data = try await BrowseFetcher.shared.get(
                    url.absoluteString, via: bridge,
                    authentication: src.isManaged ? src.authentication : nil)
                let decoded = try RegistryAdapter.decode(
                    data,
                    format: src.format,
                    governancePolicy: src.governance,
                    endpointRule: TenantProfile.current.registryEndpointRule)
                for var srv in decoded where !srv.name.isEmpty && !srv.isUnconnectablePlaceholder {
                    if RegistryAdapter.filtersLocally(src.format), !s.isEmpty {
                        let needle = s.lowercased()
                        let haystack = [srv.name, srv.displayTitle, srv.description, srv.maker]
                            .joined(separator: " ").lowercased()
                        guard haystack.contains(needle) else { continue }
                    }
                    // A registry entry inherits its SOURCE's trust: you vouched for the registry,
                    // so its servers carry that and no more. A registry cannot promote itself to
                    // verified — that word means the vendor published it, and only the built-in
                    // manifest can assert it.
                    srv.source = src.source == .verified ? .user : src.source
                    srv.publisher = src.displayName
                    srv.networkScope = src.networkScope
                    srv.sha256 = src.sha256
                    if var governance = srv.governance {
                        governance.isApproved = (src.governance ?? .init())
                            .isApproved(governance.status)
                        srv.governance = governance
                    }
                    if var existing = byName[srv.name] {
                        existing.stars = maxOpt(existing.stars, srv.stars)
                        existing.downloads = maxOpt(existing.downloads, srv.downloads)
                        byName[srv.name] = existing
                    } else {
                        byName[srv.name] = srv; order.append(srv.name)
                    }
                }
            } catch is CancellationError {
                return (order.compactMap { byName[$0] }, issues)   // superseded by a newer search
            } catch let e as BrowseFetcher.BrowseError {
                issues.append(.init(sourceID: src.id, sourceName: src.displayName,
                                    networkScope: src.networkScope, authentication: src.authentication,
                                    kind: e.kind, detail: e.message, status: e.status))
                NSLog("registry \(src.url) failed: \(e.message)")
            } catch {
                issues.append(.init(sourceID: src.id, sourceName: src.displayName,
                                    networkScope: src.networkScope, authentication: src.authentication,
                                    kind: .invalidResponse, detail: "returned unexpected data",
                                    status: nil))
                NSLog("registry \(src.url) decode failed: \(error)")
            }
        }
        return (order.compactMap { byName[$0] }, issues)
    }

    private func maxOpt(_ a: Int?, _ b: Int?) -> Int? {
        if let a, let b { return max(a, b) }
        return a ?? b
    }

    /// Full-registry search across all enabled sources.
    func load(search: String = "", via bridge: AgentBridge?, sources: [RegistrySource]) async {
        loading = true; error = nil; sourceIssues = []
        defer { loading = false }
        let (result, issues) = await fetchMerged(search: search, limit: 50, via: bridge, sources: sources)
        servers = result
        sourceIssues = issues
        if servers.isEmpty {
            error = issues.first?.message ?? "No servers found."
        }
    }

    // Featured = the live feed from every enabled source (no hardcoded brand list). The view ranks it
    // verified-namespace + popularity first, and the "Verified" toggle narrows it to first-party servers.
    @Published var featured: [MCPRegistryServer] = []
    @Published var loadingFeatured = false

    func loadFeatured(via bridge: AgentBridge?, sources: [RegistrySource]) async {
        guard featured.isEmpty, !loadingFeatured else { return }
        loadingFeatured = true; defer { loadingFeatured = false }
        let (result, issues) = await fetchMerged(search: "", limit: 100, via: bridge, sources: sources)
        // A failed or empty fetch must never blank a list the user is already reading. The issues
        // still surface, so a stale list is never passed off as a fresh one.
        if !result.isEmpty { featured = result }
        sourceIssues = issues
    }

    /// Reload the feed even though `featured` is already populated — the Refresh affordance.
    /// Same rule: a failure leaves the previous list in place and reports itself.
    func reloadFeatured(via bridge: AgentBridge?, sources: [RegistrySource]) async {
        guard !loadingFeatured else { return }
        loadingFeatured = true; defer { loadingFeatured = false }
        let (result, issues) = await fetchMerged(search: "", limit: 100, via: bridge, sources: sources)
        if !result.isEmpty { featured = result }
        sourceIssues = issues
    }
}

// MARK: - Public plugin marketplaces (Claude Code .claude-plugin/marketplace.json)

// RegistrySource + MarketplaceSource now live in ExtensionsStore — they're user-editable + persisted.

struct PluginMarketplaceManifest: Decodable {
    let name: String
    let plugins: [PluginEntry]
    struct PluginEntry: Decodable {
        let name: String
        let description: String?
        let displayName: String?
        let category: String?
        let homepage: String?
        let keywords: [String]?
        let author: Author?
        let source: PluginSource?
        /// Archive-registry metadata. Claude marketplaces leave these nil and are inspected via
        /// their source tree instead.
        let version: String?
        let skills: [String]?
        let commands: [String]?
        let mcpServers: [String]?
        let archive: String?
        let sha256: String?
        struct Author: Decodable { let name: String? }

        init(name: String, description: String? = nil, displayName: String? = nil,
             category: String? = nil, homepage: String? = nil, keywords: [String]? = nil,
             author: Author? = nil, source: PluginSource? = nil, version: String? = nil,
             skills: [String]? = nil, commands: [String]? = nil,
             mcpServers: [String]? = nil, archive: String? = nil, sha256: String? = nil) {
            self.name = name; self.description = description; self.displayName = displayName
            self.category = category; self.homepage = homepage; self.keywords = keywords
            self.author = author; self.source = source; self.version = version
            self.skills = skills; self.commands = commands; self.mcpServers = mcpServers
            self.archive = archive; self.sha256 = sha256
        }
    }
}

enum PluginMarketplaceAdapter {
    static func decode(_ data: Data, source: MarketplaceSource) throws -> PluginMarketplaceManifest {
        switch source.format {
        case .claudeMarketplace:
            return try JSONDecoder().decode(PluginMarketplaceManifest.self, from: data)
        case .archiveRegistryV1:
            return try PluginArchiveRegistryAdapter.decode(data)
        }
    }
}

/// Normalize a static plugin archive registry. Installation remains an explicit user action;
/// agentd authenticates, verifies and safely materializes the selected archive.
enum PluginArchiveRegistryAdapter {
    private struct Registry: Decodable {
        let name: String?
        let plugins: [Entry]?
    }
    private struct Entry: Decodable {
        let name: String
        let version: String?
        let description: String?
        let author: String?
        let skills: [String]?
        let commands: [String]?
        let mcpServers: [String]?
        let archive: String?
        let sha256: String?
    }

    static func decode(_ data: Data) throws -> PluginMarketplaceManifest {
        let registry = try JSONDecoder().decode(Registry.self, from: data)
        return PluginMarketplaceManifest(
            name: registry.name ?? "Archive Plugins",
            plugins: (registry.plugins ?? []).map { entry in
                .init(name: entry.name, description: entry.description, displayName: entry.name,
                      author: entry.author.map { .init(name: $0) },
                      version: entry.version, skills: entry.skills, commands: entry.commands,
                      mcpServers: entry.mcpServers, archive: entry.archive, sha256: entry.sha256)
            })
    }
}

/// A plugin's source in marketplace.json — polymorphic: a dict (git-subdir / url / github) or a
/// string (relative path in the marketplace repo). Used to locate the plugin's repo tree so we can
/// list what it actually contains (commands / skills / agents / MCP servers).
struct PluginSource: Decodable {
    let kind: String
    let url: String?; let repo: String?; let path: String?; let ref: String?; let sha: String?; let relative: String?

    init(from decoder: Decoder) throws {
        if let s = try? decoder.singleValueContainer().decode(String.self) {
            kind = "relative"; relative = s; url = nil; repo = nil; path = nil; ref = nil; sha = nil; return
        }
        let c = try decoder.container(keyedBy: CodingKeys.self)
        kind = (try? c.decode(String.self, forKey: .source)) ?? "url"
        url = (try? c.decodeIfPresent(String.self, forKey: .url)) ?? nil
        repo = (try? c.decodeIfPresent(String.self, forKey: .repo)) ?? nil
        path = (try? c.decodeIfPresent(String.self, forKey: .path)) ?? nil
        ref = (try? c.decodeIfPresent(String.self, forKey: .ref)) ?? nil
        sha = (try? c.decodeIfPresent(String.self, forKey: .sha)) ?? nil
        relative = nil
    }
    enum CodingKeys: String, CodingKey { case source, url, repo, path, ref, sha }

    /// GitHub tree API URL to list this plugin's files (+ the subpath within the repo), or nil if
    /// the source isn't github-hosted.
    func treeURL(marketplaceRepo: String) -> (api: String, subpath: String)? {
        func gh(_ u: String) -> (String, String)? {
            guard let comps = URLComponents(string: u), (comps.host ?? "").contains("github.com") else { return nil }
            let p = comps.path.split(separator: "/").map(String.init)
            guard p.count >= 2 else { return nil }
            return (p[0], p[1].replacingOccurrences(of: ".git", with: ""))
        }
        let owner: String, name: String, r: String, sub: String
        switch kind {
        case "git-subdir": guard let url, let g = gh(url) else { return nil }; owner = g.0; name = g.1; r = ref ?? sha ?? "main"; sub = path ?? ""
        case "url":        guard let url, let g = gh(url) else { return nil }; owner = g.0; name = g.1; r = ref ?? sha ?? "main"; sub = ""
        case "github":     guard let repo, repo.contains("/") else { return nil }; let p = repo.split(separator: "/").map(String.init); owner = p[0]; name = p[1]; r = ref ?? sha ?? "main"; sub = ""
        case "relative":   let p = marketplaceRepo.split(separator: "/").map(String.init); guard p.count == 2, let rel = relative else { return nil }; owner = p[0]; name = p[1]; r = "main"; sub = rel.replacingOccurrences(of: "./", with: "")
        default: return nil
        }
        return ("https://api.github.com/repos/\(owner)/\(name)/git/trees/\(r)?recursive=1", sub)
    }

    /// The plugin's source repo, for a "View source" link (lets the user inspect the code before install).
    var repoURL: URL? {
        switch kind {
        case "git-subdir", "url": return url.flatMap { URL(string: $0.replacingOccurrences(of: ".git", with: "")) }
        case "github": return repo.flatMap { URL(string: "https://github.com/\($0)") }
        default: return nil
        }
    }
}

@MainActor enum ExtensionsBrowserIntent { static var pendingTab: String? }
extension Notification.Name {
    static let mechShowExtensionsTab = Notification.Name("mech.showExtensionsTab")
}

/// Stable scene entry point. The scene id remains "extensions" so restored windows and notification
/// click-through stay compatible.
///
/// Three destinations, all of them SHOPPING: find an MCP server, find a Claude plugin, find a Codex
/// plugin. The "What it can do" inventory used to sit here as a fourth tab and has moved to the Help
/// window — an inventory is not shopping, and "what can this thing do?" is a help question.
struct ExtensionsBrowserView: View {
    @State private var tab: Tab = .mcp

    // Two questions, in the order a person asks them. "What can it do?" comes FIRST and is the
    // default, because it is the question this window exists to answer and the one no tab used to
    // answer at all. The rest are things you ADD — the only real distinction in this panel.
    // Three tabs, down from four, and each is a different QUESTION rather than a different
    // technology. "What it can do" is inventory — already there, nothing to configure.
    // "Extensions" is things you add from a source; MCP servers and plugins were only ever
    // separate because each grew its own pipeline. "Automation" survives because it is the one
    // real management surface — run a saved verb, edit its arguments, delete it — and that does
    // not fit inside a read-only inventory.
    // TWO tabs, and they are the two questions in the model: what is already there, and what you
    // added. Automation is gone — it was a management surface for a library that, measured over
    // nineteen days, was never once added to (SaveCapability: 0 invocations) and run once total.
    // Saved automations still appear under "What it can do", where they are inventory like
    // everything else the agent already has.
    // MCP Servers is now its own destination with its own tabs (Browse / Configured / Add Server),
    // per EXTENSIONS-DESIGN.md. This window keeps only what has no other home yet: the inventory,
    // and the plugin folders that the Claude/Codex marketplace screens will replace.
    private enum Tab: String, CaseIterable, Identifiable {
        case mcp = "MCP Servers"
        case claudePlugins = "Claude Plugins"
        case codexPlugins = "Codex Plugins"

        var id: String { rawValue }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 2) {
                ForEach(Tab.allCases) { item in
                    Button { tab = item } label: {
                        Text(item.rawValue)
                            .font(.system(size: 14, weight: tab == item ? .semibold : .medium))
                            .foregroundStyle(tab == item ? Color.nText : .secondary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 7)
                            .background(RoundedRectangle(cornerRadius: 6).fill(
                                tab == item ? Color.nAccent.opacity(0.30) : .clear))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(3)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.nSurface))
            .frame(maxWidth: 560)
            .padding(14)

            Divider()

            switch tab {
            case .mcp: ExtensionsSettings(embedded: true)
            case .claudePlugins: ClaudePluginsView()
            case .codexPlugins: CodexPluginsView()
            }
        }
        .frame(minWidth: 820, maxWidth: .infinity,
               minHeight: 620, maxHeight: .infinity)
            .background(Color.nBg)
    }
}

/// Retained as a dormant catalog-browser implementation while external profile loading is
/// refactored. It is not reachable from the product UI.
