import XCTest
@testable import Mechanician

final class NetworkConfigurationDisclosureTests: XCTestCase {
    func testDisclosureReturnsOnlySortedUniqueHosts() {
        let profile = TenantProfile(
            tenantId: "acme",
            displayName: "Acme",
            update: .init(
                profileFeedURL: "https://publisher:secret@Profiles.Example.invalid/v4/profile?token=hidden#fragment",
                profileUpdateMode: .manual,
                revision: 4),
            extensions: .init(
                managedSources: [
                    source(
                        kind: "registry",
                        url: "https://Catalog.Example.invalid/registry.json?key=hidden"),
                    source(
                        kind: "marketplace",
                        url: "https://catalog.example.invalid/plugins.json#private"),
                    source(kind: "marketplace", url: "https://plugins.example.invalid/list"),
                    source(kind: "marketplace", repo: "publisher/plugins"),
                ],
                managedServers: [
                    server("https://Tools.Example.invalid/mcp?authorization=hidden"),
                    server("https://tools.example.invalid/events"),
                ]))

        let disclosure = NetworkConfigurationDisclosure(profile: profile)

        XCTAssertEqual(disclosure.profileUpdateHost, "profiles.example.invalid")
        XCTAssertEqual(disclosure.profileUpdateMode, .manual)
        XCTAssertEqual(disclosure.managedSourceHosts, [
            "catalog.example.invalid",
            "plugins.example.invalid",
            "raw.githubusercontent.com",
        ])
        XCTAssertEqual(disclosure.managedMCPHosts, ["tools.example.invalid"])
        let displayed = ([disclosure.profileUpdateHost].compactMap { $0 }
            + disclosure.managedSourceHosts
            + disclosure.managedMCPHosts).joined(separator: " ")
        XCTAssertFalse(displayed.contains("secret"))
        XCTAssertFalse(displayed.contains("hidden"))
        XCTAssertFalse(displayed.contains("/"))
        XCTAssertFalse(displayed.contains("@"))
    }

    func testInvalidOrNonNetworkLocationsAreNotPresentedAsHosts() {
        let profile = TenantProfile(
            tenantId: "acme",
            displayName: "Acme",
            update: .init(profileFeedURL: "http://insecure.example.invalid/profile"),
            extensions: .init(
                managedSources: [
                    source(kind: "registry", url: "not a URL"),
                    source(kind: "marketplace", repo: "file:///tmp/catalog"),
                ],
                managedServers: [server("http://insecure.example.invalid/mcp")]))

        let disclosure = NetworkConfigurationDisclosure(profile: profile)

        XCTAssertNil(disclosure.profileUpdateHost)
        XCTAssertNil(disclosure.profileUpdateMode)
        XCTAssertTrue(disclosure.managedSourceHosts.isEmpty)
        XCTAssertTrue(disclosure.managedMCPHosts.isEmpty)
    }

    private func source(
        kind: String,
        url: String? = nil,
        repo: String? = nil
    ) -> TenantProfile.ManagedSource {
        TenantProfile.ManagedSource(
            kind: kind,
            name: "Company source",
            url: url,
            repo: repo,
            format: nil,
            authentication: nil,
            networkScope: "public")
    }

    private func server(_ url: String) -> TenantProfile.ManagedServer {
        TenantProfile.ManagedServer(
            name: "company-tools",
            transport: "http",
            url: url,
            command: nil,
            args: nil,
            env: nil,
            networkScope: "public")
    }
}
