import XCTest
@testable import Mechanician

@MainActor
final class UpdaterManagerTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "UpdaterManagerTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    private func managedPolicy(_ fields: [String: Any]) throws -> ManagedEnterprisePolicy {
        let policyDefaultsName = "UpdaterManagerPolicyTests.\(UUID().uuidString)"
        let policyDefaults = try XCTUnwrap(UserDefaults(suiteName: policyDefaultsName))
        defer { policyDefaults.removePersistentDomain(forName: policyDefaultsName) }
        policyDefaults.set(
            ["schemaVersion": 1, "policy": fields],
            forKey: ManagedEnterprisePolicy.preferenceKey)
        return try XCTUnwrap(ManagedEnterprisePolicy.resolve(
            defaults: policyDefaults,
            forcedOverride: true).policy)
    }

    func testMissingAndUnknownPreferencesFailClosedToStable() {
        XCTAssertEqual(UpdateChannel.load(from: defaults), .stable)
        XCTAssertEqual(UpdateChannel.load(from: defaults).allowedSparkleChannels, [])

        defaults.set("preview-from-the-future", forKey: UpdateChannel.preferenceKey)

        let manager = UpdaterManager(startUpdates: false, defaults: defaults)
        XCTAssertEqual(manager.updateChannel, .stable)
        XCTAssertEqual(manager.updateChannel.allowedSparkleChannels, [])
    }

    func testDailyAddsItsTaggedChannelWithoutReplacingSparklesDefaultChannel() {
        XCTAssertEqual(UpdateChannel.stable.allowedSparkleChannels, [])
        XCTAssertEqual(UpdateChannel.daily.allowedSparkleChannels, ["daily"])
        // Sparkle always includes untagged/default-channel items independently of this set. An
        // opted-in installation therefore sees both stable and daily entries.
    }

    func testOnlyDailyChannelItemsReceiveTheEarlyBuildLabel() {
        XCTAssertTrue(UpdateChannel.isDailySparkleChannel("daily"))
        XCTAssertFalse(UpdateChannel.isDailySparkleChannel(nil))
        XCTAssertFalse(UpdateChannel.isDailySparkleChannel("stable"))
        XCTAssertFalse(UpdateChannel.isDailySparkleChannel("Daily"))
    }

    func testMissingNetworkChoiceFailsClosedEvenWhenLegacySparklePreferenceIsTrue() {
        defaults.set(true, forKey: UpdaterManager.sparkleAutomaticChecksPreferenceKey)

        let decision = AppUpdateNetworkDecision.resolve(
            managedPolicy: nil,
            defaults: defaults)
        let manager = UpdaterManager(
            startUpdates: false,
            defaults: defaults,
            managedPolicy: nil,
            feedURLString: "https://updates.example.invalid/private/appcast.xml?token=hidden")

        XCTAssertEqual(decision.authority, .userChoiceRequired)
        XCTAssertTrue(decision.needsUserChoice)
        XCTAssertFalse(decision.automaticallyChecks)
        XCTAssertTrue(manager.needsUpdateNetworkChoice)
        XCTAssertFalse(manager.automaticallyChecksForUpdates)
        XCTAssertEqual(manager.updateFeedHost, "updates.example.invalid")
    }

    func testSparkleDoesNotStartUntilAnExplicitNetworkChoiceExists() {
        var startCount = 0
        let manager = UpdaterManager(
            startUpdates: true,
            defaults: defaults,
            managedPolicy: nil,
            feedConfigured: true,
            feedURLString: "https://updates.example.invalid/appcast.xml",
            updaterStartOverride: { startCount += 1 })

        XCTAssertEqual(startCount, 0)
        XCTAssertTrue(manager.needsUpdateNetworkChoice)
        XCTAssertEqual(
            defaults.object(forKey: UpdaterManager.sparkleAutomaticChecksPreferenceKey) as? Bool,
            false)

        manager.setUpdateNetworkChoice(.manual)

        XCTAssertEqual(startCount, 1)
        XCTAssertFalse(manager.needsUpdateNetworkChoice)
        manager.setUpdateNetworkChoice(.automatic)
        XCTAssertEqual(startCount, 1, "changing a recorded choice must not start a second updater")
    }

    func testExplicitManualChoicePersistsIndependentlyOfSparklePreference() {
        let manager = UpdaterManager(
            startUpdates: false,
            defaults: defaults,
            managedPolicy: nil)

        manager.setUpdateNetworkChoice(.manual)

        XCTAssertFalse(manager.needsUpdateNetworkChoice)
        XCTAssertEqual(manager.updateNetworkChoice, .manual)
        XCTAssertFalse(manager.automaticallyChecksForUpdates)
        XCTAssertEqual(
            defaults.string(forKey: AppUpdateNetworkChoice.preferenceKey),
            AppUpdateNetworkChoice.manual.rawValue)
        XCTAssertEqual(
            defaults.object(forKey: UpdaterManager.sparkleAutomaticChecksPreferenceKey) as? Bool,
            false)

        let reloaded = UpdaterManager(
            startUpdates: false,
            defaults: defaults,
            managedPolicy: nil)
        XCTAssertFalse(reloaded.needsUpdateNetworkChoice)
        XCTAssertEqual(reloaded.updateNetworkChoice, .manual)
    }

    func testExplicitAutomaticChoicePersistsAndCanBeChangedBackToManual() {
        let manager = UpdaterManager(
            startUpdates: false,
            defaults: defaults,
            managedPolicy: nil)

        manager.setUpdateNetworkChoice(.automatic)
        XCTAssertTrue(manager.automaticallyChecksForUpdates)
        XCTAssertEqual(manager.updateNetworkChoice, .automatic)
        XCTAssertEqual(
            defaults.object(forKey: UpdaterManager.sparkleAutomaticChecksPreferenceKey) as? Bool,
            true)

        manager.automaticallyChecksForUpdates = false
        XCTAssertFalse(manager.automaticallyChecksForUpdates)
        XCTAssertEqual(manager.updateNetworkChoice, .manual)
    }

    func testCorruptNetworkChoiceFailsClosedAndRequiresANewChoice() {
        defaults.set("future-value", forKey: AppUpdateNetworkChoice.preferenceKey)

        let decision = AppUpdateNetworkDecision.resolve(
            managedPolicy: nil,
            defaults: defaults)

        XCTAssertEqual(decision.authority, .userChoiceRequired)
        XCTAssertNil(decision.choice)
        XCTAssertFalse(decision.automaticallyChecks)
        XCTAssertTrue(decision.needsUserChoice)
    }

    func testFirstRunAlertDefaultsAndUnexpectedDismissalsToManual() {
        XCTAssertEqual(
            AppUpdateNetworkDecision.choice(forAlertResponse: .alertFirstButtonReturn),
            .manual)
        XCTAssertEqual(
            AppUpdateNetworkDecision.choice(forAlertResponse: .alertSecondButtonReturn),
            .automatic)
        XCTAssertEqual(
            AppUpdateNetworkDecision.choice(forAlertResponse: .abort),
            .manual)
    }

    func testChangingChannelPersistsAndResetsTheUpdateCycleOnce() {
        var resetCount = 0
        let manager = UpdaterManager(
            startUpdates: false,
            defaults: defaults,
            updateCycleReset: { resetCount += 1 })

        manager.setUpdateChannel(.daily)
        XCTAssertEqual(manager.updateChannel, .daily)
        XCTAssertEqual(defaults.string(forKey: UpdateChannel.preferenceKey), "daily")
        XCTAssertEqual(resetCount, 1)

        manager.setUpdateChannel(.daily)
        XCTAssertEqual(resetCount, 1, "reselecting the same channel must not churn Sparkle")

        let reloaded = UpdaterManager(startUpdates: false, defaults: defaults)
        XCTAssertEqual(reloaded.updateChannel, .daily)
    }

    func testReturningToStableChangesOnlyTheFilterAndDoesNotRequestADowngrade() {
        defaults.set(UpdateChannel.daily.rawValue, forKey: UpdateChannel.preferenceKey)
        var resetCount = 0
        let manager = UpdaterManager(
            startUpdates: false,
            defaults: defaults,
            updateCycleReset: { resetCount += 1 })

        manager.setUpdateChannel(.stable)

        XCTAssertEqual(manager.updateChannel, .stable)
        XCTAssertEqual(manager.updateChannel.allowedSparkleChannels, [])
        XCTAssertEqual(resetCount, 1,
                       "the only side effect is asking Sparkle to reevaluate its next cycle")
    }

    func testActiveUpdateSessionRejectsAChannelChange() {
        var resetCount = 0
        let manager = UpdaterManager(
            startUpdates: false,
            defaults: defaults,
            updateCycleReset: { resetCount += 1 })
        manager.phase = .checking

        XCTAssertFalse(manager.canChangeUpdateChannel)
        manager.setUpdateChannel(.daily)

        XCTAssertEqual(manager.updateChannel, .stable)
        XCTAssertNil(defaults.string(forKey: UpdateChannel.preferenceKey))
        XCTAssertEqual(resetCount, 0)
    }

    func testHiddenBackgroundUpdateSessionRejectsAChannelChange() {
        var sessionInProgress = true
        var resetCount = 0
        let manager = UpdaterManager(
            startUpdates: false,
            defaults: defaults,
            updateSessionInProgress: { sessionInProgress },
            updateCycleReset: { resetCount += 1 })

        XCTAssertTrue({ if case .idle = manager.phase { return true }; return false }())
        XCTAssertFalse(manager.canChangeUpdateChannel)
        manager.setUpdateChannel(.daily)
        XCTAssertEqual(manager.updateChannel, .stable)
        XCTAssertNil(defaults.string(forKey: UpdateChannel.preferenceKey))
        XCTAssertEqual(resetCount, 0)

        sessionInProgress = false
        manager.setUpdateChannel(.daily)
        XCTAssertEqual(manager.updateChannel, .daily)
        XCTAssertEqual(resetCount, 1)
    }

    func testMDMUpdateAuthorityDisablesAndLocksSparkle() throws {
        defaults.set(
            AppUpdateNetworkChoice.automatic.rawValue,
            forKey: AppUpdateNetworkChoice.preferenceKey)
        let policy = try managedPolicy(["updateAuthority": "mdm"])
        var resetCount = 0
        let manager = UpdaterManager(
            startUpdates: false,
            defaults: defaults,
            updateCycleReset: { resetCount += 1 },
            managedPolicy: policy)

        XCTAssertFalse(manager.automaticallyChecksForUpdates)
        XCTAssertFalse(manager.needsUpdateNetworkChoice)
        XCTAssertFalse(manager.canChangeAutomaticUpdateChecks)
        XCTAssertFalse(manager.canChangeUpdateChannel)

        manager.automaticallyChecksForUpdates = true
        manager.setUpdateChannel(.daily)

        XCTAssertFalse(manager.automaticallyChecksForUpdates)
        XCTAssertEqual(manager.updateChannel, .stable)
        XCTAssertNil(defaults.string(forKey: UpdateChannel.preferenceKey))
        XCTAssertEqual(resetCount, 0)
    }

    func testForcedSparkleSettingsOverrideAndLockLocalPreferences() throws {
        defaults.set(
            AppUpdateNetworkChoice.automatic.rawValue,
            forKey: AppUpdateNetworkChoice.preferenceKey)
        defaults.set(UpdateChannel.stable.rawValue, forKey: UpdateChannel.preferenceKey)
        let policy = try managedPolicy([
            "updateAuthority": "sparkle",
            "sparkleUpdateChannel": "daily",
            "sparkleAutomaticChecks": false,
        ])
        var resetCount = 0
        let manager = UpdaterManager(
            startUpdates: false,
            defaults: defaults,
            updateCycleReset: { resetCount += 1 },
            managedPolicy: policy)

        XCTAssertEqual(manager.updateChannel, .daily)
        XCTAssertFalse(manager.automaticallyChecksForUpdates)
        XCTAssertFalse(manager.canChangeUpdateChannel)
        XCTAssertFalse(manager.canChangeAutomaticUpdateChecks)

        manager.setUpdateChannel(.stable)
        manager.automaticallyChecksForUpdates = true

        XCTAssertEqual(manager.updateChannel, .daily)
        XCTAssertFalse(manager.automaticallyChecksForUpdates)
        XCTAssertEqual(defaults.string(forKey: UpdateChannel.preferenceKey), "stable")
        XCTAssertEqual(resetCount, 0)
    }

    func testManagedSparklePreferenceTakesPrecedenceOverLocalNetworkChoice() throws {
        defaults.set(
            AppUpdateNetworkChoice.manual.rawValue,
            forKey: AppUpdateNetworkChoice.preferenceKey)
        let policy = try managedPolicy([
            "updateAuthority": "sparkle",
            "sparkleAutomaticChecks": true,
        ])

        let decision = AppUpdateNetworkDecision.resolve(
            managedPolicy: policy,
            defaults: defaults)
        let manager = UpdaterManager(
            startUpdates: false,
            defaults: defaults,
            managedPolicy: policy)

        XCTAssertEqual(decision.authority, .managedSparkle)
        XCTAssertFalse(decision.needsUserChoice)
        XCTAssertTrue(manager.automaticallyChecksForUpdates)
        XCTAssertFalse(manager.canChangeAutomaticUpdateChecks)
        manager.setUpdateNetworkChoice(.manual)
        XCTAssertTrue(manager.automaticallyChecksForUpdates)
        XCTAssertEqual(
            defaults.string(forKey: AppUpdateNetworkChoice.preferenceKey),
            AppUpdateNetworkChoice.manual.rawValue)
    }

    func testPublicBundleDefaultsSparkleToNoAutomaticChecksBeforeAppChoice() throws {
        let plistURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Mechanician-Info.plist")
        let data = try Data(contentsOf: plistURL)
        let plist = try XCTUnwrap(try PropertyListSerialization.propertyList(
            from: data, options: [], format: nil) as? [String: Any])

        XCTAssertEqual(plist[UpdaterManager.sparkleAutomaticChecksPreferenceKey] as? Bool, false)
    }

    func testForcedAutomaticChecksRestoresExplicitUserPreferenceWhenPolicyIsRemoved() throws {
        defaults.set(true, forKey: UpdaterManager.sparkleAutomaticChecksPreferenceKey)
        let policy = try managedPolicy([
            "updateAuthority": "sparkle",
            "sparkleAutomaticChecks": false,
        ])

        _ = UpdaterManager(
            startUpdates: true,
            defaults: defaults,
            managedPolicy: policy,
            feedConfigured: false)

        XCTAssertFalse(defaults.bool(forKey: UpdaterManager.sparkleAutomaticChecksPreferenceKey))
        XCTAssertNotNil(defaults.dictionary(
            forKey: UpdaterManager.savedAutomaticChecksPreferenceKey))

        _ = UpdaterManager(
            startUpdates: true,
            defaults: defaults,
            managedPolicy: nil,
            feedConfigured: false)

        XCTAssertTrue(defaults.bool(forKey: UpdaterManager.sparkleAutomaticChecksPreferenceKey))
        XCTAssertNil(defaults.object(forKey: UpdaterManager.savedAutomaticChecksPreferenceKey))
    }

    func testForcedAutomaticChecksRestoresAnAbsentUserPreference() throws {
        XCTAssertNil(defaults.object(forKey: UpdaterManager.sparkleAutomaticChecksPreferenceKey))
        let policy = try managedPolicy([
            "updateAuthority": "sparkle",
            "sparkleAutomaticChecks": false,
        ])

        _ = UpdaterManager(
            startUpdates: true,
            defaults: defaults,
            managedPolicy: policy,
            feedConfigured: false)
        XCTAssertNotNil(defaults.object(forKey: UpdaterManager.sparkleAutomaticChecksPreferenceKey))

        _ = UpdaterManager(
            startUpdates: true,
            defaults: defaults,
            managedPolicy: nil,
            feedConfigured: false)

        XCTAssertNil(defaults.object(forKey: UpdaterManager.sparkleAutomaticChecksPreferenceKey))
        XCTAssertNil(defaults.object(forKey: UpdaterManager.savedAutomaticChecksPreferenceKey))
    }
}
