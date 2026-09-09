import Foundation

/// Local edits to a signed managed configuration.
///
/// The profile document is Ed25519-signed and the app holds only the public key, so it cannot
/// rewrite one — an in-place editor would either have to forge a signature or discard it, and
/// discarding it would mean any file could activate an enterprise route. Instead the signed
/// document stays exactly as the administrator published it and these overrides are layered on top
/// at resolution time, so `TenantProfile.current` is the EFFECTIVE configuration and every existing
/// consumer (`declaredModels`, `vertexConfig`, the daemon environment, `ExtensionsStore`) keeps
/// working with no knowledge that an override exists.
///
/// Overrides are per-user and per-install, take effect on the next launch exactly as an imported
/// profile does, and every overridden field can be reset back to what the profile says.
///
/// One rule is deliberately not negotiable: a source whose URL the user has changed loses its
/// managed `authentication`. `googleIdentity` hands the user's enterprise Google identity token to
/// the URL, and a token minted for a managed registry host must never be sent to a host someone typed in.
struct ManagedConfigurationOverrides: Codable, Equatable {
    /// Edits to one route, keyed by the profile's own `routeId`.
    struct Route: Codable, Equatable {
        var vertexProjectId: String?
        var vertexRegion: String?
        /// nil means "use the profile's declared list"; an empty array means "declare nothing",
        /// which is a meaningful choice — it returns the lane to Mechanician's built-in models.
        var models: [TenantProfile.Model]?

        var isEmpty: Bool {
            vertexProjectId == nil && vertexRegion == nil && models == nil
        }
    }

    /// Edits to one managed extension source, keyed by the profile's own source name.
    struct Source: Codable, Equatable {
        var disabled: Bool?
        var url: String?

        var isEmpty: Bool { disabled == nil && url == nil }
    }

    var routes: [String: Route] = [:]
    var sources: [String: Source] = [:]

    /// Routes and sources authored HERE rather than published by an administrator, so a user with
    /// no signed profile at all can still configure a Vertex connection. These are the same shapes
    /// a profile declares, which is what makes ``exportableProfile`` able to hand the result to an
    /// administrator to sign and distribute.
    var addedRoutes: [TenantProfile.Route] = []
    var addedSources: [TenantProfile.ManagedSource] = []
    /// Identifies a configuration that exists only on this machine. `TenantProfile.isDefault` is
    /// `tenantId == "default"`, and a great deal of the app keys off it, so a locally authored
    /// configuration has to claim an id of its own or it would be indistinguishable from having no
    /// configuration. It also participates in `routeIdentity`, which scopes credentials — so a
    /// local route and a later managed one never share a session or a token.
    var localTenantId: String?

    /// Adapters a locally authored route may name. This is not a formatting nicety: an adapter
    /// selects which audited runtime code path executes, and `ModelAccess(adapter:)` maps exactly
    /// one today. A route naming anything else activates nothing, so accepting it would only
    /// produce a configuration that silently does nothing.
    static let authorableAdapters = ["claude-vertex", "claude-bedrock"]

    var isEmpty: Bool {
        routes.values.allSatisfy(\.isEmpty) && sources.values.allSatisfy(\.isEmpty)
            && addedRoutes.isEmpty && addedSources.isEmpty
    }

    // MARK: Persistence

    static let fileName = "managed-overrides.json"

    static func fileURL(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL {
        // Deliberately the same base as the installed profile, so a dev instance's isolated support
        // directory keeps its own overrides instead of editing the real install's configuration.
        TenantProfile.installedProfileURL(environment: environment, homeDirectory: homeDirectory)
            .deletingLastPathComponent()
            .appendingPathComponent(fileName, isDirectory: false)
    }

    /// Never throws: a corrupt or unreadable override file must degrade to "no overrides" — the
    /// signed profile alone — rather than fail the launch that resolves the profile.
    static func load(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> ManagedConfigurationOverrides {
        let url = fileURL(environment: environment, homeDirectory: homeDirectory)
        guard let data = try? Data(contentsOf: url, options: [.mappedIfSafe]),
              let decoded = try? JSONDecoder().decode(Self.self, from: data)
        else { return ManagedConfigurationOverrides() }
        return decoded
    }

    func save(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) throws {
        let url = Self.fileURL(environment: environment, homeDirectory: homeDirectory)
        if isEmpty {
            try? FileManager.default.removeItem(at: url)
            return
        }
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: url, options: .atomic)
    }

    // MARK: Superseded overrides

    /// One local edit that a newly published revision took back, named for a human.
    struct Retirement: Equatable {
        /// The route or source the edit belonged to, as the profile names it.
        var scope: String
        /// The field, in the same words the managed-configuration editor uses.
        var field: String

        var sentence: String { "\(field) on \(scope)" }
    }

    /// Drop the parts of this override that the administrator has since changed.
    ///
    /// An override is an edit relative to a specific published value, and nothing recorded which
    /// value it was edited FROM — so an override outlived the fact it was answering. A tenant
    /// published a revision that withdrew a model, the Mac installed it and correctly reported the
    /// new revision, and the withdrawn model stayed on offer indefinitely because the local list
    /// still named it. The published document had no way to win.
    ///
    /// The rule is a three-way merge: `previous` is the base, these overrides are ours, `next` is
    /// theirs. A field the publisher left alone keeps its local edit, because the reason for that
    /// edit still stands. A field the publisher changed is theirs again, because they have since
    /// spoken about exactly the value being overridden.
    ///
    /// Two deliberate abstentions. `Source.disabled` has no published counterpart to compare, so a
    /// revision expresses no opinion about it and it always survives. And an override whose route or
    /// source is absent from `previous` is left alone: without a base there is no evidence the
    /// publisher changed anything, and guessing would discard an edit nobody superseded.
    func retiringSuperseded(
        previous: TenantProfile, next: TenantProfile
    ) -> (overrides: ManagedConfigurationOverrides, retired: [Retirement]) {
        var result = self
        var retired: [Retirement] = []

        var previousRoutes: [String: TenantProfile.Route] = [:]
        for route in previous.routes where previousRoutes[route.routeId] == nil {
            previousRoutes[route.routeId] = route
        }
        var nextRoutes: [String: TenantProfile.Route] = [:]
        for route in next.routes where nextRoutes[route.routeId] == nil {
            nextRoutes[route.routeId] = route
        }

        for (routeId, override) in routes.sorted(by: { $0.key < $1.key }) {
            guard let before = previousRoutes[routeId] else { continue }
            let scope = before.displayName?.nonEmpty ?? routeId
            guard let after = nextRoutes[routeId] else {
                // The route itself is gone. Whatever the edit said, there is nothing left to say it
                // about, and keeping it would resurrect the route's id in a later revision.
                result.routes[routeId] = nil
                retired.append(Retirement(scope: scope, field: "Local edits"))
                continue
            }
            var edited = override
            if override.models != nil, before.models != after.models {
                edited.models = nil
                retired.append(Retirement(scope: scope, field: "Models"))
            }
            if override.vertexProjectId != nil,
               Self.publishedProject(before) != Self.publishedProject(after) {
                edited.vertexProjectId = nil
                retired.append(Retirement(scope: scope, field: "Project"))
            }
            if override.vertexRegion != nil,
               Self.publishedRegion(before) != Self.publishedRegion(after) {
                edited.vertexRegion = nil
                retired.append(Retirement(scope: scope, field: "Region"))
            }
            result.routes[routeId] = edited.isEmpty ? nil : edited
        }

        var previousSources: [String: TenantProfile.ManagedSource] = [:]
        for source in previous.extensions.managedSources where previousSources[source.name] == nil {
            previousSources[source.name] = source
        }
        var nextSources: [String: TenantProfile.ManagedSource] = [:]
        for source in next.extensions.managedSources where nextSources[source.name] == nil {
            nextSources[source.name] = source
        }

        for (name, override) in sources.sorted(by: { $0.key < $1.key }) {
            guard let before = previousSources[name] else { continue }
            guard let after = nextSources[name] else {
                result.sources[name] = nil
                retired.append(Retirement(scope: name, field: "Local edits"))
                continue
            }
            var edited = override
            if override.url != nil, before.url != after.url {
                edited.url = nil
                retired.append(Retirement(scope: name, field: "Address"))
            }
            result.sources[name] = edited.isEmpty ? nil : edited
        }

        return (result, retired)
    }

    /// Matches ``applied(to:)``: one override field feeds a Vertex project or a Bedrock profile,
    /// so the published value it is compared against has to be read the same way.
    private static func publishedProject(_ route: TenantProfile.Route) -> String? {
        route.vertex?.projectId ?? route.bedrock?.profile
    }

    private static func publishedRegion(_ route: TenantProfile.Route) -> String? {
        route.vertex?.region ?? route.bedrock?.region
    }

    // MARK: Application

    /// Layer these overrides onto a signed profile, producing the configuration the app runs with.
    ///
    /// Values that select CODE rather than configuration — `adapter`, `routeId`, `tenantId`, a
    /// source's `format` — are never overridable. They choose which audited path executes, and a
    /// user-supplied value there would be a way to reach code the signed document did not select.
    func applied(to profile: TenantProfile) -> TenantProfile {
        guard !isEmpty else { return profile }
        var result = profile

        result.routes = profile.routes.map { route in
            guard let override = routes[route.routeId], !override.isEmpty else { return route }
            var edited = route
            if let vertex = route.vertex {
                edited.vertex = TenantProfile.Vertex(
                    projectId: override.vertexProjectId?.trimmed.nonEmpty ?? vertex.projectId,
                    region: override.vertexRegion?.trimmed.nonEmpty ?? vertex.region)
            }
            if let bedrock = route.bedrock {
                edited.bedrock = TenantProfile.Bedrock(
                    region: override.vertexRegion?.trimmed.nonEmpty ?? bedrock.region,
                    profile: override.vertexProjectId?.trimmed.nonEmpty ?? bedrock.profile)
            }
            if let models = override.models { edited.models = models }
            return edited
        }

        // Locally authored routes. Sanitized on the way in, not merely on the way to the UI: this
        // is the boundary an on-disk override file crosses, and a hand-edited one must not be able
        // to name an adapter the audit never covered.
        result.routes += addedRoutes
            .filter { Self.authorableAdapters.contains($0.adapter) && !$0.routeId.isEmpty }
            .map { route in
                var sanitized = route
                sanitized.models = route.models.filter { !$0.id.isEmpty }
                return sanitized
            }

        result.extensions.managedSources = profile.extensions.managedSources.compactMap { source in
            guard let override = sources[source.name], !override.isEmpty else { return source }
            if override.disabled == true { return nil }
            guard let replacement = override.url?.trimmed.nonEmpty,
                  replacement != source.url else { return source }
            var edited = source
            edited.url = replacement
            // The one non-negotiable rule. A managed sign-in is bound to the host the administrator
            // named; re-pointing the URL cannot carry that credential along.
            edited.authentication = nil
            return edited
        }

        // Locally authored sources never carry a managed sign-in, for the same reason a re-pointed
        // one loses it: `googleIdentity` sends the user's enterprise identity token to the URL, and
        // only an administrator's signature can vouch for the host that receives it.
        result.extensions.managedSources += addedSources
            .filter { !$0.name.isEmpty && $0.url?.hasPrefix("https://") == true }
            .map { source in
                var sanitized = source
                sanitized.authentication = nil
                return sanitized
            }

        // A configuration that exists has to say so. Everything that asks "is a configuration
        // active?" reads `isDefault`, which is purely `tenantId == "default"`.
        if result.isDefault, !result.routes.isEmpty || !result.extensions.managedSources.isEmpty {
            result.tenantId = localTenantId?.trimmed.nonEmpty ?? Self.defaultLocalTenantId
        }

        return result
    }

    static let defaultLocalTenantId = "local"

    /// The effective configuration as a profile document an administrator can sign and distribute.
    ///
    /// This is what makes authoring locally worth doing rather than a dead end: build a
    /// configuration on one machine, confirm it actually produces working turns, then export it,
    /// sign it with `scripts/sign-enterprise-profile.swift`, and hand the same configuration to
    /// everyone else. Exactly the fields `TenantProfile` decodes, so the round trip is closed.
    ///
    /// Deliberately omits `update`, `branding`, `bundleIdentifier` and `portal` — the app strips
    /// those from any profile it loads anyway, so writing them would produce a document whose
    /// contents do not match its behaviour. `managedServers` is carried through unchanged when the
    /// source profile had them, and can never be introduced here.
    static func exportableProfile(from profile: TenantProfile) -> [String: Any] {
        var document: [String: Any] = [
            "schemaVersion": profile.schemaVersion,
            "tenantId": profile.tenantId,
            "displayName": profile.displayName,
        ]
        document["routes"] = profile.routes.map { route -> [String: Any] in
            var entry: [String: Any] = ["routeId": route.routeId, "adapter": route.adapter]
            if let name = route.displayName { entry["displayName"] = name }
            if let vertex = route.vertex {
                entry["vertex"] = ["projectId": vertex.projectId, "region": vertex.region]
            }
            if let bedrock = route.bedrock {
                var block: [String: Any] = ["region": bedrock.region]
                // A profile NAME is a selector, never a credential — safe to distribute. AWS keys
                // are never in this document because they are never in the configuration at all.
                if let awsProfile = bedrock.profile, !awsProfile.isEmpty {
                    block["profile"] = awsProfile
                }
                entry["bedrock"] = block
            }
            if !route.models.isEmpty {
                entry["models"] = route.models.map { model -> [String: Any] in
                    var m: [String: Any] = ["id": model.id]
                    if let name = model.displayName { m["displayName"] = name }
                    if !model.supportedEfforts.isEmpty {
                        m["efforts"] = model.supportedEfforts
                    }
                    if model.isDefault { m["default"] = true }
                    return m
                }
            }
            if route.isDefault { entry["default"] = true }
            return entry
        }
        var extensions: [String: Any] = ["allowPublic": profile.extensions.allowPublic]
        extensions["managedSources"] = profile.extensions.managedSources.map { source -> [String: Any] in
            var entry: [String: Any] = ["kind": source.kind, "name": source.name]
            if let url = source.url { entry["url"] = url }
            if let repo = source.repo { entry["repo"] = repo }
            if let format = source.format { entry["format"] = format }
            if let authentication = source.authentication { entry["authentication"] = authentication }
            if let scope = source.networkScope { entry["networkScope"] = scope }
            if let sha = source.sha256 { entry["sha256"] = sha }
            if let governance = source.governance {
                entry["governance"] = ["approvedStatuses": governance.approvedStatuses]
            }
            return entry
        }
        extensions["managedServers"] = profile.extensions.managedServers.map { server -> [String: Any] in
            var entry: [String: Any] = ["name": server.name, "transport": server.transport]
            if let url = server.url { entry["url"] = url }
            if let command = server.command { entry["command"] = command }
            if let args = server.args { entry["args"] = args }
            if let env = server.env { entry["env"] = env }
            if let scope = server.networkScope { entry["networkScope"] = scope }
            return entry
        }
        document["extensions"] = extensions
        return document
    }
}

private extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
    var nonEmpty: String? { isEmpty ? nil : self }
}
