import XCTest
@testable import Mechanician

final class AgentBridgeManagedPolicyTests: XCTestCase {
    private func managedPolicy(_ values: [String: Any]) throws -> ManagedEnterprisePolicy {
        let suiteName = "AgentBridgeManagedPolicyTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.set([
            "schemaVersion": 1,
            "policy": values,
        ], forKey: ManagedEnterprisePolicy.preferenceKey)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let resolution = ManagedEnterprisePolicy.resolve(defaults: defaults, forcedOverride: true)
        XCTAssertNil(resolution.error)
        return try XCTUnwrap(resolution.policy)
    }

    @MainActor
    func testManagedPermissionCeilingPreservesRawPreferenceAcrossRelaunch() throws {
        let defaultAccessKey = "providerAccounts.defaultConversationAccess.v1"
        let defaults = UserDefaults.standard
        let priorDefaultAccess = defaults.object(forKey: defaultAccessKey)
        defaults.removeObject(forKey: defaultAccessKey)
        defer {
            if let priorDefaultAccess {
                defaults.set(priorDefaultAccess, forKey: defaultAccessKey)
            } else {
                defaults.removeObject(forKey: defaultAccessKey)
            }
        }

        let support = FileManager.default.temporaryDirectory.appendingPathComponent(
            "Mechanician-managed-permission-restart-\(UUID().uuidString)",
            isDirectory: true)
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: support) }

        let unmanaged = AgentBridge(
            settingsBaseOverride: support,
            environmentOverride: [:],
            managedEnterprisePolicy: nil)
        unmanaged.loadSettings()
        unmanaged.permissionMode = "bypassPermissions"

        let planPolicy = try managedPolicy([
            "maximumInteractivePermissionMode": "plan",
        ])
        let managed = AgentBridge(
            settingsBaseOverride: support,
            environmentOverride: [:],
            managedEnterprisePolicy: planPolicy)
        managed.loadSettings()
        XCTAssertEqual(managed.permissionMode, "plan", "Dispatch must see the managed ceiling.")
        XCTAssertFalse(managed.canExitPlanMode)

        // The plan banner and an ExitPlanMode callback both request Default. Under a forced Plan
        // ceiling that request is unavailable, so it must neither escape Plan nor replace the raw
        // preference that should return after management is relaxed.
        managed.permissionMode = "default"
        XCTAssertEqual(managed.permissionMode, "plan")

        let data = try Data(contentsOf: support.appendingPathComponent("settings.json"))
        let persisted = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(
            persisted["permissionMode"] as? String,
            "bypassPermissions",
            "Loading under management must not overwrite the person's raw preference.")

        let relaxed = AgentBridge(
            settingsBaseOverride: support,
            environmentOverride: [:],
            managedEnterprisePolicy: nil)
        relaxed.loadSettings()
        XCTAssertEqual(relaxed.permissionMode, "bypassPermissions")
    }

    @MainActor
    func testMinimumBuildRejectsRuntimeAccountCommandsBeforeTheyBecomePending() throws {
        let policy = try managedPolicy([
            "minimumAppBuild": Int.max,
        ])
        let accesses: [ModelAccess] = [
            .claudeSubscription,
            .codexSubscription,
            .claudeVertex,
        ]
        let accounts = ProviderAccountStore.shared
        for access in accesses {
            accounts.finish(access)
            accounts.clearError(for: access)
        }
        defer {
            for access in accesses {
                accounts.finish(access)
                accounts.clearError(for: access)
            }
        }

        let bridge = AgentBridge(
            environmentOverride: [:],
            managedEnterprisePolicy: policy)
        bridge.connectAccount(.claudeSubscription)
        bridge.reconnectAccount(.codexSubscription)
        bridge.disconnectAccount(.claudeVertex)

        let expected = try XCTUnwrap(policy.turnBlockReason(for: .anthropicAPI))
        for access in accesses {
            XCTAssertNil(accounts.operation(for: access))
            XCTAssertFalse(bridge.hasPendingAccountCommandForTesting(access))
            XCTAssertEqual(accounts.error(for: access), expected)
        }
        XCTAssertEqual(bridge.entries.last?.text, expected)
    }
}
