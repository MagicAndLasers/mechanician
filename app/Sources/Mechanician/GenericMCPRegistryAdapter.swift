import Foundation

/// Read an MCP registry nobody wrote an adapter for.
///
/// `RegistryFormat` is a closed enum with one bespoke decoder per catalog — `officialV01`,
/// `pulseBeta`, and once a per-organization case — so every new registry meant an app release and a per-tenant
/// mapping. That does not scale, and it is not necessary: registries disagree about SPELLING far
/// more than about structure. They all publish a list of servers, each with a name, something to
/// connect to, and usually a description; they just call them `name`/`server_name`/`id`,
/// `url`/`endpoint`/`uri`, `description`/`summary`.
///
/// So this infers instead of mapping. Keys are matched case- and separator-insensitively
/// (`server_name`, `serverName` and `Server-Name` are one key), against a ranked list of aliases per
/// field. Anything it cannot recognize is skipped, never guessed at: a server with no usable
/// endpoint is dropped rather than presented as connectable.
///
/// It is deliberately NOT the default for the official registry. `officialV01` and `pulseBeta` have
/// exact schemas and paged query semantics that inference would only approximate. This exists for
/// the long tail — an organization's own catalog — where the alternative today is shipping code.
enum GenericMCPRegistryAdapter {
    enum AdapterError: LocalizedError {
        case noServerList
        var errorDescription: String? {
            "This catalog did not contain a recognizable list of MCP servers."
        }
    }

    /// Keys that may hold the server list when the document is an object rather than an array.
    private static let rootAliases = [
        "servers", "data", "items", "results", "entries", "mcpservers", "registry", "catalog",
    ]

    private static let nameAliases = ["name", "servername", "id", "identifier", "slug", "key"]
    private static let titleAliases = ["title", "displayname", "label", "friendlyname"]
    private static let descriptionAliases = ["description", "summary", "desc", "about", "details"]
    private static let versionAliases = ["version", "latestversion", "currentversion"]
    private static let websiteAliases = [
        "websiteurl", "website", "homepage", "documentation", "docs", "docsurl", "infourl",
    ]
    private static let repositoryAliases = [
        "repository", "repo", "repositoryurl", "repourl", "sourceurl", "github", "source",
    ]
    private static let transportListAliases = ["transports", "remotes", "endpoints", "connections"]
    private static let urlAliases = ["url", "endpoint", "uri", "href", "address", "serverurl"]
    private static let statusAliases = [
        "status", "state", "approval", "approvalstatus", "reviewstatus", "governancestatus",
    ]
    private static let governanceAliases = ["governancereview", "governance", "review", "approval"]
    private static let authAliases = ["auth", "authentication", "authtype", "security"]
    private static let packageListAliases = ["packages", "package", "installs", "distributions"]

    static func decode(
        _ data: Data,
        governancePolicy: TenantProfile.RegistryGovernancePolicy? = nil,
        endpointRule: TenantProfile.RegistryEndpointRule? = nil
    ) throws -> [MCPRegistryServer] {
        let root = try JSONSerialization.jsonObject(with: data)
        guard let entries = serverList(from: root) else { throw AdapterError.noServerList }
        // One malformed entry must never hide every usable one: an enterprise catalog is edited by
        // many hands and is routinely partly wrong.
        return entries.compactMap { entry in
            (entry as? [String: Any]).flatMap {
                map($0, policy: governancePolicy, endpointRule: endpointRule)
            }
        }
    }

    private static func serverList(from root: Any) -> [Any]? {
        if let array = root as? [Any] { return array }
        guard let object = root as? [String: Any] else { return nil }
        let normalized = normalize(object)
        for alias in rootAliases {
            if let array = normalized[alias] as? [Any] { return array }
        }
        // A registry keyed by server name — { "io.acme/db": { … } } — is still a list of servers.
        let values = object.values.compactMap { $0 as? [String: Any] }
        if values.count == object.count, !values.isEmpty,
           values.allSatisfy({ !normalize($0).isEmpty }) {
            return object.map { key, value in
                var entry = value as? [String: Any] ?? [:]
                if lookup(normalize(entry), nameAliases) == nil { entry["name"] = key }
                return entry
            }
        }
        return nil
    }

    // MARK: Mapping

    private static func map(
        _ raw: [String: Any],
        policy: TenantProfile.RegistryGovernancePolicy?,
        endpointRule: TenantProfile.RegistryEndpointRule?
    ) -> MCPRegistryServer? {
        let entry = normalize(raw)
        let title = string(lookup(entry, titleAliases))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let rawName = string(lookup(entry, nameAliases))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !rawName.isEmpty || !title.isEmpty else { return nil }
        let name = rawName.isEmpty ? slug(title) : rawName

        let declaredAuthentication = authentication(entry)
        let remotes = self.remotes(
            entry,
            authentication: declaredAuthentication,
            endpointRule: endpointRule)
        let packages = self.packages(entry)
        // Nothing to connect to is not a server. Presenting one would offer an install that cannot
        // work, which is worse than omitting it.
        guard !remotes.isEmpty || !packages.isEmpty else { return nil }

        return MCPRegistryServer(
            name: name,
            description: string(lookup(entry, descriptionAliases)) ?? "",
            title: title.isEmpty ? nil : title,
            version: string(lookup(entry, versionAliases)),
            websiteUrl: httpsString(lookup(entry, websiteAliases)),
            repository: repository(entry).map { .init(url: $0) },
            packages: packages.isEmpty ? nil : packages,
            remotes: remotes.isEmpty ? nil : remotes,
            declaredAuthentication: declaredAuthentication,
            governance: governance(entry, policy: policy))
    }

    private static func remotes(
        _ entry: [String: Any],
        authentication: MCPRegistryServer.DeclaredAuthentication?,
        endpointRule: TenantProfile.RegistryEndpointRule?
    ) -> [MCPRegistryServer.Remote] {
        let header = self.header(entry, authentication: authentication)
        var found: [MCPRegistryServer.Remote] = []
        var seen = Set<String>()

        func append(_ rawURL: String?, type rawType: String?) {
            guard let rawURL, let url = URL(string: rawURL.trimmingCharacters(in: .whitespaces)),
                  url.scheme?.lowercased() == "https", seen.insert(url.absoluteString).inserted
            else { return }
            let type = rawType?.lowercased() == "sse" ? "sse" : "streamable-http"
            // A catalog may list only the service's host root; the tenant's rule, if any, says
            // where its MCP endpoint actually lives. Without a rule this is the URL as published.
            let endpoint = MCPEndpointNormalizer.normalized(
                url.absoluteString,
                rule: endpointRule)
            found.append(.init(type: type, url: endpoint,
                               headers: header.map { [$0] }))
        }

        for alias in transportListAliases {
            for transport in dictionaries(entry[alias]) {
                let t = normalize(transport)
                append(string(lookup(t, urlAliases)), type: string(t["type"]))
            }
            // A single transport object rather than a list.
            if let single = entry[alias] as? [String: Any] {
                let t = normalize(single)
                append(string(lookup(t, urlAliases)), type: string(t["type"]))
            }
        }
        // A flat entry that simply carries its endpoint at the top level.
        append(string(lookup(entry, urlAliases)), type: string(entry["type"]))
        return found
    }

    private static func packages(_ entry: [String: Any]) -> [MCPRegistryServer.Package] {
        var found: [MCPRegistryServer.Package] = []
        for alias in packageListAliases {
            // A catalog may publish one package as a bare object rather than a single-element
            // list, the same way it may publish one transport that way. Both spellings mean the
            // same thing, and dropping the object form silently loses the whole server.
            var candidates = dictionaries(entry[alias])
            if candidates.isEmpty, let single = entry[alias] as? [String: Any] {
                candidates = [single]
            }
            for package in candidates {
                let p = normalize(package)
                let registryType = string(lookup(p, ["registrytype", "registry", "type", "kind"]))?
                    .lowercased()
                guard let identifier = string(lookup(p, ["identifier", "name", "package", "id"]))?
                    .trimmingCharacters(in: .whitespacesAndNewlines), !identifier.isEmpty
                else { continue }
                // Only ecosystems Mechanician can actually launch, and only over stdio. A registry
                // must never be able to name an arbitrary command.
                let runtimeHint: String
                switch registryType {
                case "npm", "npmjs", "node": runtimeHint = "npx"
                case "pypi", "python", "pip": runtimeHint = "uvx"
                default: continue
                }
                found.append(.init(
                    registryType: registryType, identifier: identifier,
                    version: string(lookup(p, versionAliases)), runtimeHint: runtimeHint,
                    transport: .init(type: "stdio"), environmentVariables: nil))
            }
            // The shorthand shape: { "npm": "@acme/server" }.
            if let object = entry[alias] as? [String: Any] {
                let o = normalize(object)
                for (key, hint) in [("npm", "npx"), ("pypi", "uvx")] {
                    guard let identifier = string(o[key])?
                        .trimmingCharacters(in: .whitespacesAndNewlines), !identifier.isEmpty
                    else { continue }
                    found.append(.init(
                        registryType: key, identifier: identifier, version: nil,
                        runtimeHint: hint, transport: .init(type: "stdio"),
                        environmentVariables: nil))
                }
            }
        }
        return found
    }

    private static func authentication(
        _ entry: [String: Any]
    ) -> MCPRegistryServer.DeclaredAuthentication? {
        let raw = lookup(entry, authAliases)
        let type = string(dictionary(raw).map { normalize($0) }?["type"]) ?? string(raw)
        switch type?.lowercased().replacingOccurrences(of: "_", with: "-") {
        case "oauth", "oauth2", "oauth-2": return .oauth2
        case "bearer", "bearer-token", "token": return .bearerToken
        case "api-key", "apikey": return .apiKey
        default: return nil
        }
    }

    private static func header(
        _ entry: [String: Any], authentication: MCPRegistryServer.DeclaredAuthentication?
    ) -> MCPRegistryServer.Remote.Header? {
        switch authentication {
        case .bearerToken:
            return .init(name: "Authorization", isRequired: true, isSecret: true)
        case .apiKey:
            let auth = dictionary(lookup(entry, authAliases)).map { normalize($0) }
            let name = string(auth.flatMap { lookup($0, ["apikeyheader", "header", "headername"]) })
            return .init(name: name ?? "X-API-Key", isRequired: true, isSecret: true)
        case .oauth2, .none:
            return nil
        }
    }

    private static func repository(_ entry: [String: Any]) -> String? {
        let raw = lookup(entry, repositoryAliases)
        if let url = httpsString(raw) { return url }
        guard let object = dictionary(raw) else { return nil }
        return httpsString(lookup(normalize(object), urlAliases))
    }

    private static func governance(
        _ entry: [String: Any], policy: TenantProfile.RegistryGovernancePolicy?
    ) -> MCPRegistryServer.Governance? {
        let raw = lookup(entry, governanceAliases)
        let status = string(dictionary(raw).map { normalize($0) }.flatMap { lookup($0, statusAliases) })
            ?? string(raw)
            ?? string(lookup(entry, statusAliases))
        guard let status, !status.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        let effective = policy ?? TenantProfile.RegistryGovernancePolicy()
        return .init(status: status, isApproved: effective.isApproved(status))
    }

    // MARK: Key inference

    /// Collapse a key to its comparable form: lowercase, with separators removed. This is the whole
    /// trick — `server_name`, `serverName` and `Server-Name` become one key, so a registry's casing
    /// convention stops being something anyone has to encode.
    static func canonicalKey(_ key: String) -> String {
        key.lowercased().filter { $0.isLetter || $0.isNumber }
    }

    private static func normalize(_ object: [String: Any]) -> [String: Any] {
        var result: [String: Any] = [:]
        for (key, value) in object {
            let canonical = canonicalKey(key)
            // First spelling wins, so a document carrying both `name` and `Name` is deterministic.
            if result[canonical] == nil { result[canonical] = value }
        }
        return result
    }

    private static func lookup(_ normalized: [String: Any], _ aliases: [String]) -> Any? {
        for alias in aliases {
            if let value = normalized[canonicalKey(alias)],
               !(value is NSNull) { return value }
        }
        return nil
    }

    private static func string(_ value: Any?) -> String? {
        if let text = value as? String { return text.isEmpty ? nil : text }
        if let number = value as? NSNumber { return number.stringValue }
        return nil
    }

    private static func httpsString(_ value: Any?) -> String? {
        guard let text = string(value)?.trimmingCharacters(in: .whitespacesAndNewlines),
              let url = URL(string: text), url.scheme?.lowercased() == "https" else { return nil }
        return text
    }

    private static func dictionary(_ value: Any?) -> [String: Any]? { value as? [String: Any] }

    private static func dictionaries(_ value: Any?) -> [[String: Any]] {
        (value as? [Any])?.compactMap { $0 as? [String: Any] } ?? []
    }

    private static func slug(_ text: String) -> String {
        let cleaned = text.lowercased().map { $0.isLetter || $0.isNumber ? $0 : "-" }
        return String(cleaned).split(separator: "-").joined(separator: "-")
    }
}
