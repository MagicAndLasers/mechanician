import Foundation
import XCTest
@testable import Mechanician

@MainActor
final class StorageProductAccessGateTests: XCTestCase {
    private let root = URL(fileURLWithPath: "/tmp/storage-product-access-gate")

    func testRecoveryDecisionNeverRunsProductOperation() {
        let state = StorageAuthorityLaunchState()
        XCTAssertTrue(state.configure(
            recognition: .legacyDefault(root: root), decision: .recovery))
        var operationCount = 0
        var blockedCount = 0

        XCTAssertFalse(StorageProductAccessGate.perform(
            state: state,
            ownsProcessLease: true,
            blocked: { blockedCount += 1 },
            { operationCount += 1 }))
        XCTAssertEqual(operationCount, 0)
        XCTAssertEqual(blockedCount, 1)
    }

    func testLaunchDecisionAcceptsOnlyActiveSQLiteWithTheProcessLease() {
        XCTAssertEqual(
            StorageAuthorityLaunchDecision.resolve(
                recognition: sqliteRecognition(), ownsProcessLease: true),
            .product)
        XCTAssertEqual(
            StorageAuthorityLaunchDecision.resolve(
                recognition: sqliteRecognition(), ownsProcessLease: false),
            .recovery)
        XCTAssertEqual(
            StorageAuthorityLaunchDecision.resolve(
                recognition: .legacyDefault(root: root), ownsProcessLease: true),
            .recovery)
        XCTAssertEqual(
            StorageAuthorityLaunchDecision.resolve(
                recognition: rollbackRecognition(), ownsProcessLease: true),
            .recovery)
    }

    func testConfiguredSQLiteProductRunsOperationExactlyOnce() {
        let state = StorageAuthorityLaunchState()
        XCTAssertTrue(state.configure(recognition: sqliteRecognition(), decision: .product))
        var operationCount = 0

        XCTAssertTrue(StorageProductAccessGate.perform(
            state: state,
            ownsProcessLease: true,
            blocked: { XCTFail("product must not be blocked") },
            { operationCount += 1 }))
        XCTAssertEqual(operationCount, 1)
    }

    func testLegacyAndRollbackCanNeverRunEvenWithAProductDecision() {
        for recognition in [StorageAuthorityRecognition.legacyDefault(root: root),
                            rollbackRecognition()] {
            let state = StorageAuthorityLaunchState()
            XCTAssertTrue(state.configure(recognition: recognition, decision: .product))
            XCTAssertFalse(StorageProductAccessGate.allows(state, ownsProcessLease: true))
        }
    }

    func testUnconfiguredStateFailsClosed() {
        let state = StorageAuthorityLaunchState()
        XCTAssertFalse(StorageProductAccessGate.allows(state, ownsProcessLease: true))
    }

    func testProductWithoutTheProcessLeaseFailsClosed() {
        let state = StorageAuthorityLaunchState()
        XCTAssertTrue(state.configure(
            recognition: .legacyDefault(root: root), decision: .product))
        XCTAssertFalse(StorageProductAccessGate.allows(state, ownsProcessLease: false))
    }

    func testExternalProductAccessRejectsMalformedForcedManagedPolicy() throws {
        let managed = try forcedManagedResolution(["schemaVersion": "one"])
        let profile = TenantProfile.resolve(
            bundleIdentifier: MechanicianEnvironment.baseBundleIdentifier,
            environment: [:],
            homeDirectory: root,
            publicKey: TenantProfile.profileSigningPublicKey,
            managedConfiguration: managed)
        let state = configuredProductState()

        XCTAssertNotNil(managed.error)
        XCTAssertNotNil(profile.error)
        XCTAssertFalse(StorageProductAccessGate.allows(
            state,
            ownsProcessLease: true,
            enterpriseConfigurationAllowsRuntime:
                EnterpriseConfigurationStartupGate.allowsRuntime(
                    managedPolicyStartupError: managed.error,
                    tenantProfileStartupError: profile.error)))
    }

    func testExternalProductAccessRejectsInvalidMDMSignedProfile() throws {
        let managed = try forcedManagedResolution([
            "schemaVersion": 1,
            "signedProfile": Data("not a signed profile".utf8),
        ])
        let profile = TenantProfile.resolve(
            bundleIdentifier: MechanicianEnvironment.baseBundleIdentifier,
            environment: [:],
            homeDirectory: root,
            publicKey: TenantProfile.profileSigningPublicKey,
            managedConfiguration: managed)
        let state = configuredProductState()

        XCTAssertNil(managed.error)
        XCTAssertNotNil(profile.error)
        XCTAssertFalse(StorageProductAccessGate.allows(
            state,
            ownsProcessLease: true,
            enterpriseConfigurationAllowsRuntime:
                EnterpriseConfigurationStartupGate.allowsRuntime(
                    managedPolicyStartupError: managed.error,
                    tenantProfileStartupError: profile.error)))
    }

    private func forcedManagedResolution(
        _ document: [String: Any]
    ) throws -> ManagedEnterprisePolicy.Resolution {
        let suiteName = "StorageProductAccessGateTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(document, forKey: ManagedEnterprisePolicy.preferenceKey)
        return ManagedEnterprisePolicy.resolve(defaults: defaults, forcedOverride: true)
    }

    private func configuredProductState() -> StorageAuthorityLaunchState {
        let state = StorageAuthorityLaunchState()
        XCTAssertTrue(state.configure(recognition: sqliteRecognition(), decision: .product))
        return state
    }

    private func sqliteRecognition() -> StorageAuthorityRecognition {
        let marker = StorageAuthorityMarker(
            mode: .sqlite,
            activationID: UUID(),
            databaseInstanceID: UUID(),
            createdAt: "2026-08-12T12:00:00Z")
        let probe = StorageAuthorityDatabaseProbe(
            databaseInstanceID: marker.databaseInstanceID,
            schemaVersion: marker.schemaVersion,
            authorityState: .active,
            activationID: marker.activationID,
            rollbackID: nil,
            minimumWriterBuild: marker.minimumWriterBuild,
            committedSequence: 42)
        return StorageAuthorityRecognition(
            anchorRoot: root,
            effectiveSupportRoot: root,
            marker: .valid(marker),
            disposition: .sqlite(marker: marker, database: probe))
    }

    private func rollbackRecognition() -> StorageAuthorityRecognition {
        let generation = root.appendingPathComponent("rollback", isDirectory: true)
        let marker = StorageAuthorityMarker(
            mode: .legacy,
            activationID: UUID(),
            databaseInstanceID: UUID(),
            generationName: generation.lastPathComponent,
            rollbackID: UUID(),
            createdAt: "2026-08-12T12:00:00Z")
        return StorageAuthorityRecognition(
            anchorRoot: root,
            effectiveSupportRoot: generation,
            marker: .valid(marker),
            disposition: .legacyGeneration(marker: marker, root: generation))
    }
}
