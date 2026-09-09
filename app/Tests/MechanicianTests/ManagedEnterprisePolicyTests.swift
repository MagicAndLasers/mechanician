import XCTest
@testable import Mechanician

final class ManagedEnterprisePolicyTests: XCTestCase {
    private func resolve(
        _ document: [String: Any],
        forced: Bool = true
    ) -> ManagedEnterprisePolicy.Resolution {
        let suiteName = "ManagedEnterprisePolicyTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.set(document, forKey: ManagedEnterprisePolicy.preferenceKey)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        return ManagedEnterprisePolicy.resolve(
            defaults: defaults,
            forcedOverride: forced)
    }

    func testUnforcedPreferenceIsIgnored() {
        let resolution = resolve([
            "schemaVersion": 1,
            "policyIdentifier": "example-policy",
            "policy": ["allowUnattendedTasks": false],
        ], forced: false)

        XCTAssertNil(resolution.policy)
        XCTAssertNil(resolution.error)
    }

    func testForcedPreferenceParsesPolicyAndPreservesUnspecifiedDefaults() throws {
        let resolution = resolve([
            "schemaVersion": 1,
            "policyIdentifier": " example-policy ",
            "revision": 4,
            "policy": [
                "allowedProviderAccesses": ["anthropic_api", "claude_vertex"],
                "maximumInteractivePermissionMode": "acceptEdits",
                "allowUnattendedTasks": false,
                "allowLocalProfile": false,
            ],
        ])

        let policy = try XCTUnwrap(resolution.policy)
        XCTAssertNil(resolution.error)
        XCTAssertEqual(policy.policyIdentifier, "example-policy")
        XCTAssertEqual(policy.revision, 4)
        XCTAssertEqual(policy.allowedProviderAccesses, ["anthropic_api", "claude_vertex"])
        XCTAssertTrue(policy.allows(.anthropicAPI))
        XCTAssertTrue(policy.allows(.claudeVertex))
        XCTAssertFalse(policy.allows(.openAIAPI))
        XCTAssertEqual(policy.maximumInteractivePermissionMode, "acceptEdits")
        XCTAssertFalse(policy.allowUnattendedTasks)
        XCTAssertFalse(policy.allowLocalProfile)
        XCTAssertTrue(policy.allowLocalConfigurationOverrides)
        XCTAssertTrue(policy.allowUserConfiguredExtensions)
        XCTAssertTrue(policy.allowPublicExtensionDiscovery)
        XCTAssertEqual(policy.updateAuthority, .sparkle)
    }

    func testMalformedForcedPreferenceFailsClosed() {
        let missingRequiredField = resolve([
            "policyIdentifier": "missing-required-schema-version",
        ])

        XCTAssertNil(missingRequiredField.policy)
        XCTAssertEqual(
            missingRequiredField.error,
            ManagedEnterprisePolicy.PolicyError.malformedDocument.localizedDescription)

        let wrongKnownFieldType = resolve([
            "schemaVersion": [1],
        ])
        XCTAssertNil(wrongKnownFieldType.policy)
        XCTAssertEqual(
            wrongKnownFieldType.error,
            ManagedEnterprisePolicy.PolicyError.malformedDocument.localizedDescription)

        let misspelledRestriction = resolve([
            "schemaVersion": 1,
            "policy": ["allowUnattendedTask": false],
        ])
        XCTAssertNil(misspelledRestriction.policy)
        XCTAssertEqual(
            misspelledRestriction.error,
            ManagedEnterprisePolicy.PolicyError.unknownField(
                "policy.allowUnattendedTask").localizedDescription)
    }

    func testUnsupportedForcedPolicyFailsClosed() {
        let resolution = resolve([
            "schemaVersion": 2,
            "policyIdentifier": "future-policy",
        ])

        XCTAssertNil(resolution.policy)
        XCTAssertEqual(
            resolution.error,
            ManagedEnterprisePolicy.PolicyError.unsupportedSchemaVersion(2).localizedDescription)
    }

    func testInvalidRestrictionsFailTheWholeForcedPolicy() {
        let emptyAllowlist = resolve([
            "schemaVersion": 1,
            "policy": ["allowedProviderAccesses": []],
        ])
        XCTAssertNil(emptyAllowlist.policy)
        XCTAssertEqual(
            emptyAllowlist.error,
            ManagedEnterprisePolicy.PolicyError.emptyProviderAllowlist.localizedDescription)

        let incompatibleUpdates = resolve([
            "schemaVersion": 1,
            "policy": [
                "updateAuthority": "mdm",
                "sparkleAutomaticChecks": true,
            ],
        ])
        XCTAssertNil(incompatibleUpdates.policy)
        XCTAssertEqual(
            incompatibleUpdates.error,
            ManagedEnterprisePolicy.PolicyError.incompatibleUpdateSettings.localizedDescription)

        let injectedAllowlist = resolve([
            "schemaVersion": 1,
            "policy": ["allowedProviderAccesses": ["anthropic_api,openai_api"]],
        ])
        XCTAssertNil(injectedAllowlist.policy)
        XCTAssertEqual(
            injectedAllowlist.error,
            ManagedEnterprisePolicy.PolicyError.invalidProviderAccess(
                "anthropic_api,openai_api").localizedDescription)
    }

    func testPermissionCeilingClampsOnlyLessRestrictiveInteractiveModes() throws {
        let policy = try XCTUnwrap(resolve([
            "schemaVersion": 1,
            "policy": ["maximumInteractivePermissionMode": "acceptEdits"],
        ]).policy)

        XCTAssertEqual(policy.clampedPermissionMode("plan"), "plan")
        XCTAssertEqual(policy.clampedPermissionMode("default"), "default")
        XCTAssertEqual(policy.clampedPermissionMode("acceptEdits"), "acceptEdits")
        XCTAssertEqual(policy.clampedPermissionMode("bypassPermissions"), "acceptEdits")
        XCTAssertEqual(policy.clampedPermissionMode("not-a-mode"), "default")
        XCTAssertTrue(policy.allowsPermissionMode("plan"))
        XCTAssertTrue(policy.allowsPermissionMode("acceptEdits"))
        XCTAssertFalse(policy.allowsPermissionMode("bypassPermissions"))
    }

    func testDefaultPermissionCeilingStillAllowsPlanMode() throws {
        let policy = try XCTUnwrap(resolve([
            "schemaVersion": 1,
            "policy": ["maximumInteractivePermissionMode": "default"],
        ]).policy)

        XCTAssertEqual(policy.clampedPermissionMode("plan"), "plan")
        XCTAssertEqual(policy.clampedPermissionMode("acceptEdits"), "default")
        XCTAssertEqual(policy.clampedPermissionMode("bypassPermissions"), "default")
    }

    func testPlanPermissionCeilingClampsEveryInteractiveModeToPlan() throws {
        let policy = try XCTUnwrap(resolve([
            "schemaVersion": 1,
            "policy": ["maximumInteractivePermissionMode": "plan"],
        ]).policy)

        XCTAssertEqual(policy.clampedPermissionMode("plan"), "plan")
        XCTAssertEqual(policy.clampedPermissionMode("default"), "plan")
        XCTAssertEqual(policy.clampedPermissionMode("acceptEdits"), "plan")
        XCTAssertEqual(policy.clampedPermissionMode("bypassPermissions"), "plan")
        XCTAssertTrue(policy.allowsPermissionMode("plan"))
        XCTAssertFalse(policy.allowsPermissionMode("default"))
    }

    func testMinimumBuildBlocksUnattendedWorkAsWellAsInteractiveTurns() throws {
        let policy = try XCTUnwrap(resolve([
            "schemaVersion": 1,
            "policy": [
                "allowUnattendedTasks": true,
                "minimumAppBuild": 42,
            ],
        ]).policy)

        XCTAssertFalse(policy.allowsUnattendedWork(currentBuild: 41))
        XCTAssertTrue(policy.allowsUnattendedWork(currentBuild: 42))
        XCTAssertNotNil(policy.turnBlockReason(for: .anthropicAPI, currentBuild: 41))
    }
}
