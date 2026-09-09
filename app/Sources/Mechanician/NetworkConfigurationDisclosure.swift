import Foundation

/// Host-only inventory for the network locations an enterprise configuration can cause the app to
/// contact. It is deliberately lossy: URL paths, query strings, fragments, and user information
/// never leave this boundary for display or diagnostics.
struct NetworkConfigurationDisclosure: Equatable {
    let profileUpdateHost: String?
    let profileUpdateMode: TenantProfile.Update.ProfileUpdateMode?
    let managedSourceHosts: [String]
    let managedMCPHosts: [String]

    init(profile: TenantProfile) {
        if let feed = profile.update?.profileFeedURL,
           let host = Self.host(fromHTTPSURL: feed) {
            profileUpdateHost = host
            profileUpdateMode = profile.update?.effectiveProfileUpdateMode
        } else {
            profileUpdateHost = nil
            profileUpdateMode = nil
        }

        managedSourceHosts = Self.sortedUniqueHosts(
            profile.extensions.managedSources.compactMap(Self.host(for:)))
        managedMCPHosts = Self.sortedUniqueHosts(
            profile.extensions.managedServers.compactMap {
                Self.host(fromHTTPSURL: $0.url)
            })
    }

    /// Returns only an HTTPS hostname. Even a malformed authored URL carrying credentials cannot
    /// leak them through this API; the caller receives either its hostname or no value at all.
    static func host(fromHTTPSURL rawValue: String?) -> String? {
        guard let rawValue,
              let components = URLComponents(
                  string: rawValue.trimmingCharacters(in: .whitespacesAndNewlines)),
              components.scheme?.lowercased() == "https",
              let host = components.host?.trimmingCharacters(in: .whitespacesAndNewlines),
              !host.isEmpty else { return nil }
        return host.lowercased()
    }

    private static func host(for source: TenantProfile.ManagedSource) -> String? {
        if let url = source.url { return host(fromHTTPSURL: url) }
        guard source.kind == "marketplace",
              let repo = source.repo?.trimmingCharacters(in: .whitespacesAndNewlines),
              !repo.isEmpty else { return nil }
        if repo.contains("://") { return host(fromHTTPSURL: repo) }

        // Claude marketplace shorthand is fetched from this exact host by
        // `MarketplaceSource.rawURL`; name that real connection instead of presenting owner/repo as
        // though it were a hostname.
        return "raw.githubusercontent.com"
    }

    private static func sortedUniqueHosts(_ hosts: [String]) -> [String] {
        Array(Set(hosts)).sorted()
    }
}
