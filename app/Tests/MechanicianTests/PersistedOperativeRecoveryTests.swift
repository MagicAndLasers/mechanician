import XCTest
@testable import Mechanician

final class PersistedOperativeRecoveryTests: XCTestCase {
    private func managedPolicy(
        allowUnattendedTasks: Bool,
        minimumAppBuild: Int? = nil,
        maximumInteractivePermissionMode: String? = nil
    ) throws -> ManagedEnterprisePolicy {
        var policy: [String: Any] = ["allowUnattendedTasks": allowUnattendedTasks]
        if let minimumAppBuild { policy["minimumAppBuild"] = minimumAppBuild }
        if let maximumInteractivePermissionMode {
            policy["maximumInteractivePermissionMode"] = maximumInteractivePermissionMode
        }
        let suiteName = "PersistedOperativeRecoveryTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.set([
            "schemaVersion": 1,
            "policy": policy,
        ], forKey: ManagedEnterprisePolicy.preferenceKey)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        return try XCTUnwrap(ManagedEnterprisePolicy.resolve(
            defaults: defaults,
            forcedOverride: true).policy)
    }

    /// Multi-window session restoration constructs every bridge before the asynchronous SQLite and
    /// Workspace inventory callbacks finish. Claiming against process state, rather than requiring
    /// `live.count <= 1`, lets the first ready bridge recover the waits and makes every later callback
    /// a no-op for those same identities.
    func testMultipleRestoredWindowsClaimEachPersistedWaitExactlyOnce() {
        let firstWait = UUID()
        let secondWait = UUID()
        let persisted: Set<UUID> = [firstWait, secondWait]

        let firstWindowClaims = PersistedOperativeRecovery.unclaimedWaitIDs(
            persistedWaitIDs: persisted,
            processClaimedWaitIDs: [])
        let secondWindowClaims = PersistedOperativeRecovery.unclaimedWaitIDs(
            persistedWaitIDs: persisted,
            processClaimedWaitIDs: firstWindowClaims)

        XCTAssertEqual(firstWindowClaims, persisted)
        XCTAssertTrue(secondWindowClaims.isEmpty)
    }

    /// Provider readiness can beat selected-record hydration. Recovery must wait for the complete
    /// Conversation/Workspace inventory, but once operative records were adopted it must not also
    /// wait for an unrelated corrupt selected transcript to finish hydrating.
    func testQueueDrainRequiresCompleteInventoryButNotSelectedTranscriptHydration() {
        XCTAssertFalse(PersistedOperativeRecovery.canDrainQueues(
            storeIsReady: false,
            workspaceInventoryIsReady: false,
            operativeStateWasAdopted: false))
        XCTAssertFalse(PersistedOperativeRecovery.canDrainQueues(
            storeIsReady: true,
            workspaceInventoryIsReady: false,
            operativeStateWasAdopted: false))
        XCTAssertFalse(PersistedOperativeRecovery.canDrainQueues(
            storeIsReady: true,
            workspaceInventoryIsReady: true,
            operativeStateWasAdopted: false))
        XCTAssertTrue(PersistedOperativeRecovery.canDrainQueues(
            storeIsReady: true,
            workspaceInventoryIsReady: true,
            operativeStateWasAdopted: true))
    }

    func testClosingWaitOwnerSelectsOneReadySurvivorForImmediateHandoff() {
        let departingWait = UUID()
        let first = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let second = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!

        XCTAssertEqual(PersistedOperativeRecovery.waitHandoffRecipientID(
            departingWaitIDs: [departingWait],
            readySurvivingBridgeIDs: [second, first]), first)
        XCTAssertNil(PersistedOperativeRecovery.waitHandoffRecipientID(
            departingWaitIDs: [],
            readySurvivingBridgeIDs: [first]))
        XCTAssertNil(PersistedOperativeRecovery.waitHandoffRecipientID(
            departingWaitIDs: [departingWait],
            readySurvivingBridgeIDs: []),
            "A not-yet-ready survivor must claim the wait only after its inventory callback.")
    }

    func testAutomaticWaitPolicyHonorsUnattendedAndMinimumBuildRestrictions() throws {
        XCTAssertTrue(AutomaticWaitPolicy.isAllowed(
            managedPolicy: nil,
            currentBuild: 1))

        let disabled = try managedPolicy(allowUnattendedTasks: false)
        XCTAssertFalse(AutomaticWaitPolicy.isAllowed(
            managedPolicy: disabled,
            currentBuild: 100))

        let versionGated = try managedPolicy(
            allowUnattendedTasks: true,
            minimumAppBuild: 42)
        XCTAssertFalse(AutomaticWaitPolicy.isAllowed(
            managedPolicy: versionGated,
            currentBuild: 41))
        XCTAssertTrue(AutomaticWaitPolicy.isAllowed(
            managedPolicy: versionGated,
            currentBuild: 42))
    }

    func testPersistedShellCheckCannotRunUnderManagedPlanCeiling() throws {
        let plan = try managedPolicy(
            allowUnattendedTasks: true,
            maximumInteractivePermissionMode: "plan")
        XCTAssertTrue(AutomaticWaitPolicy.isAllowed(
            managedPolicy: plan,
            currentBuild: 100))
        XCTAssertFalse(AutomaticWaitPolicy.allowsShellChecks(
            managedPolicy: plan,
            currentBuild: 100))

        let defaultMode = try managedPolicy(
            allowUnattendedTasks: true,
            maximumInteractivePermissionMode: "default")
        XCTAssertTrue(AutomaticWaitPolicy.allowsShellChecks(
            managedPolicy: defaultMode,
            currentBuild: 100))
        XCTAssertTrue(AutomaticWaitPolicy.allowsShellChecks(
            managedPolicy: nil,
            currentBuild: 100))
    }
}
