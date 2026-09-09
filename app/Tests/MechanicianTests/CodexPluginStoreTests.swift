import XCTest
@testable import Mechanician

@MainActor
final class CodexPluginStoreTests: XCTestCase {
    private func plugin(
        remote: Bool,
        interstitial: Bool?,
        availability: String = "AVAILABLE",
        installPolicy: String = "AVAILABLE"
    ) -> CodexPluginStore.Plugin {
        CodexPluginStore.Plugin(
            pluginId: "test@marketplace",
            name: "Test Plugin",
            description: "A test plugin",
            marketplaceName: remote ? "remote" : "local",
            installed: false,
            enabled: true,
            version: "1.0.0",
            category: nil,
            developerName: "Test Developer",
            logoUrl: nil,
            availability: availability,
            installPolicy: installPolicy,
            remote: remote,
            mustShowInstallationInterstitial: interstitial,
            longDescription: nil,
            websiteUrl: nil,
            privacyPolicyUrl: nil,
            termsOfServiceUrl: nil,
            screenshotUrls: [],
            defaultPrompt: [],
            capabilities: []
        )
    }

    func testInstallationDecisionPreservesRemotePolicySemantics() {
        XCTAssertEqual(
            plugin(remote: false, interstitial: nil).installationDecision,
            .install
        )
        XCTAssertEqual(
            plugin(remote: true, interstitial: false).installationDecision,
            .install
        )
        XCTAssertEqual(
            plugin(remote: true, interstitial: true).installationDecision,
            .reviewDetails
        )

        let unavailable = plugin(remote: true, interstitial: nil)
        XCTAssertEqual(unavailable.installationDecision, .unavailable)
        XCTAssertFalse(unavailable.installable)
        XCTAssertTrue(unavailable.installationUnavailableReason.contains("could not verify"))
    }

    func testUnavailableAndUnknownInstallPoliciesFailClosed() {
        XCTAssertEqual(
            plugin(
                remote: true,
                interstitial: false,
                installPolicy: "INSTALLED_BY_DEFAULT"
            ).installationDecision,
            .install
        )
        XCTAssertEqual(
            plugin(
                remote: true,
                interstitial: false,
                installPolicy: "NOT_AVAILABLE"
            ).installationDecision,
            .unavailable
        )
        XCTAssertEqual(
            plugin(
                remote: true,
                interstitial: false,
                installPolicy: "FUTURE_POLICY"
            ).installationDecision,
            .unavailable
        )
        XCTAssertEqual(
            plugin(
                remote: true,
                interstitial: false,
                availability: "DISABLED_BY_ADMIN"
            ).installationDecision,
            .unavailable
        )
    }

    func testApplyPreservesNullablePolicyAndRemoteMarketplaceProvenance() throws {
        let store = CodexPluginStore()
        store.apply([
            "ok": true,
            "marketplaces": [
                ["name": "remote", "remote": true],
                ["name": "local", "remote": false],
            ],
            "plugins": [
                [
                    "pluginId": "review@remote",
                    "marketplaceName": "remote",
                    "mustShowInstallationInterstitial": true,
                ],
                [
                    "pluginId": "direct@remote",
                    "marketplaceName": "remote",
                    "mustShowInstallationInterstitial": false,
                ],
                [
                    "pluginId": "unknown@remote",
                    "marketplaceName": "remote",
                ],
                [
                    "pluginId": "local@local",
                    "marketplaceName": "local",
                ],
            ],
        ])

        let plugins = Dictionary(uniqueKeysWithValues: store.plugins.map { ($0.pluginId, $0) })
        XCTAssertEqual(
            try XCTUnwrap(plugins["review@remote"]).installationDecision,
            .reviewDetails
        )
        XCTAssertEqual(
            try XCTUnwrap(plugins["direct@remote"]).installationDecision,
            .install
        )
        XCTAssertEqual(
            try XCTUnwrap(plugins["unknown@remote"]).installationDecision,
            .unavailable
        )
        XCTAssertEqual(
            try XCTUnwrap(plugins["local@local"]).installationDecision,
            .install
        )
    }
}
