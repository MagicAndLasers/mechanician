import XCTest
@testable import Mechanician

/// Which lanes may run unattended is a POLICY boundary (Anthropic Consumer Terms §3: no automated
/// access except via an API key or where explicitly permitted). These tests pin the decision so it
/// cannot be widened by accident.
@MainActor
final class AmbientLanePolicyTests: XCTestCase {
    private func managedPolicy(_ fields: [String: Any]) throws -> ManagedEnterprisePolicy {
        let suiteName = "AmbientLanePolicyTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(
            ["schemaVersion": 1, "policy": fields],
            forKey: ManagedEnterprisePolicy.preferenceKey)
        return try XCTUnwrap(ManagedEnterprisePolicy.resolve(
            defaults: defaults,
            forcedOverride: true).policy)
    }

    /// Must be workspace-assigned, or `needsSchedulerProcess` is false for reasons unrelated to
    /// the lane under test.
    private func task(access: String?) -> ScheduledTask {
        ScheduledTask(
            name: "t", prompt: "p", workspaceID: UUID(),
            trigger: AmbientTrigger(type: "time", schedule: AmbientSchedule(kind: "interval", minutes: 60)),
            access: access)
    }

    func testOnlyMeteredLanesMaySchedule() {
        XCTAssertEqual(AmbientLanePolicy.schedulable, [.anthropicAPI, .claudeVertex, .openAIAPI])
        for lane in AmbientLanePolicy.schedulable {
            XCTAssertNil(AmbientLanePolicy.unavailableReason(lane))
        }
    }

    func testSubscriptionLanesAreRefusedWithAReason() {
        for lane in [ModelAccess.claudeSubscription, .codexSubscription] {
            XCTAssertFalse(AmbientLanePolicy.isSchedulable(lane))
            let reason = AmbientLanePolicy.unavailableReason(lane)
            XCTAssertNotNil(reason, "a refused lane must explain itself, not vanish from the UI")
            XCTAssertFalse(reason!.isEmpty)
        }
    }

    func testSubscriptionLanesStillAppearInThePicker() {
        // Silently omitting them is what made this confusing in the first place.
        let lanes = AmbientLanePolicy.pickerLanes(
            includingUnavailable: [.claudeSubscription, .codexSubscription])
        XCTAssertTrue(lanes.contains(.claudeSubscription))
        XCTAssertTrue(lanes.contains(.codexSubscription))
        XCTAssertEqual(Array(lanes.prefix(2)), [.anthropicAPI, .openAIAPI])
    }

    func testPickerOffersOnlyTheSchedulerActualDirectSDKRoute() {
        XCTAssertEqual(
            AmbientLanePolicy.selectableSchedulable(
                directAccess: .anthropicAPI,
                managedPolicy: nil),
            [.anthropicAPI, .openAIAPI])
        XCTAssertEqual(
            AmbientLanePolicy.selectableSchedulable(
                directAccess: .claudeVertex,
                managedPolicy: nil),
            [.claudeVertex, .openAIAPI])
        XCTAssertFalse(AmbientLanePolicy.isAvailableToScheduler(
            .claudeVertex,
            directAccess: .anthropicAPI))
        XCTAssertFalse(AmbientLanePolicy.isAvailableToScheduler(
            .anthropicAPI,
            directAccess: .claudeVertex))
    }

    func testATaskWithNoLaneKeepsTheHistoricalRoute() {
        XCTAssertEqual(task(access: nil).resolvedAccess, .anthropicAPI)
        XCTAssertEqual(
            task(access: nil).resolvedAccess(directAccess: .claudeVertex),
            .claudeVertex)
    }

    func testATaskNamingAnUnschedulableLaneFallsBackRatherThanRunningThere() {
        // Defence in depth: a hand-edited tasks.json must not smuggle a subscription lane past the
        // picker into an unattended run.
        XCTAssertEqual(task(access: "claude_subscription").resolvedAccess, .anthropicAPI)
        XCTAssertEqual(task(access: "codex_subscription").resolvedAccess, .anthropicAPI)
        XCTAssertEqual(task(access: "nonsense").resolvedAccess, .anthropicAPI)
        XCTAssertEqual(
            task(access: "nonsense").resolvedAccess(directAccess: .claudeVertex),
            .claudeVertex)
    }

    func testASchedulableLaneIsHonored() {
        XCTAssertEqual(task(access: "openai_api").resolvedAccess, .openAIAPI)
        XCTAssertEqual(task(access: "claude_vertex").resolvedAccess, .claudeVertex)
    }

    func testAnOlderTaskJSONWithoutTheLaneFieldStillDecodes() throws {
        // The 0.11.7 quarantine class of bug: a non-Optional new field would drop every existing
        // task on the floor. This is the regression guard for that.
        let json = """
        {"id":"a","name":"n","prompt":"p","cwd":"/tmp","enabled":true,
         "trigger":{"type":"time","schedule":{"kind":"interval","minutes":60}}}
        """
        let decoded = try JSONDecoder().decode(ScheduledTask.self, from: Data(json.utf8))
        XCTAssertNil(decoded.access)
        XCTAssertEqual(decoded.resolvedAccess, .anthropicAPI)
    }

    func testOneUnconnectedLaneDoesNotStopEveryOtherTask() {
        // A task on a provider you haven't connected must not prevent the scheduler starting for
        // the tasks that CAN run.
        let runnable = task(access: "anthropic_api")
        let blocked = task(access: "openai_api")
        XCTAssertTrue(AmbientStore.shouldRunInProcess(
            tasks: [blocked, runnable],
            backgroundAgentInstalled: false,
            daemonAvailable: true,
            credentialAvailable: { $0 == .anthropicAPI }))
    }

    func testNoRunnableLaneMeansNoScheduler() {
        XCTAssertFalse(AmbientStore.shouldRunInProcess(
            tasks: [task(access: "openai_api")],
            backgroundAgentInstalled: false,
            daemonAvailable: true,
            credentialAvailable: { $0 == .anthropicAPI }))
    }

    func testRequiredLanesReportsWhatTheDaemonMustCredential() {
        XCTAssertEqual(
            AmbientStore.requiredLanes(tasks: [task(access: "openai_api"), task(access: nil)]),
            [.openAIAPI, .anthropicAPI])
    }

    func testManagedProviderAllowlistFiltersSchedulerAndCredentialHandoff() throws {
        let policy = try managedPolicy([
            "allowedProviderAccesses": ["openai_api"],
            "allowUnattendedTasks": true,
        ])
        let anthropic = task(access: nil)
        let openAI = task(access: "openai_api")

        XCTAssertFalse(AmbientStore.shouldRunInProcess(
            tasks: [anthropic],
            backgroundAgentInstalled: false,
            daemonAvailable: true,
            credentialAvailable: { _ in true },
            managedPolicy: policy))
        XCTAssertTrue(AmbientStore.shouldRunInProcess(
            tasks: [anthropic, openAI],
            backgroundAgentInstalled: false,
            daemonAvailable: true,
            credentialAvailable: { _ in true },
            managedPolicy: policy))
        XCTAssertEqual(
            AmbientStore.requiredLanes(
                tasks: [anthropic, openAI],
                managedPolicy: policy),
            [.openAIAPI])
    }

    func testManagedUnattendedTaskBanStopsSchedulerAndCredentialHandoff() throws {
        let policy = try managedPolicy([
            "allowedProviderAccesses": ["anthropic_api"],
            "allowUnattendedTasks": false,
        ])
        let anthropic = task(access: nil)

        XCTAssertFalse(AmbientStore.shouldRunInProcess(
            tasks: [anthropic],
            backgroundAgentInstalled: false,
            daemonAvailable: true,
            credentialAvailable: { _ in true },
            managedPolicy: policy))
        XCTAssertTrue(AmbientStore.requiredLanes(
            tasks: [anthropic],
            managedPolicy: policy).isEmpty)
    }

    func testMinimumBuildStopsSchedulerAndCredentialHandoff() throws {
        let policy = try managedPolicy([
            "allowedProviderAccesses": ["anthropic_api"],
            "allowUnattendedTasks": true,
            "minimumAppBuild": 42,
        ])
        let anthropic = task(access: nil)

        XCTAssertFalse(AmbientStore.shouldRunInProcess(
            tasks: [anthropic],
            backgroundAgentInstalled: false,
            daemonAvailable: true,
            credentialAvailable: { _ in true },
            managedPolicy: policy,
            currentBuild: 41))
        XCTAssertTrue(AmbientStore.requiredLanes(
            tasks: [anthropic],
            managedPolicy: policy,
            currentBuild: 41).isEmpty)
        XCTAssertTrue(AmbientStore.shouldRunInProcess(
            tasks: [anthropic],
            backgroundAgentInstalled: false,
            daemonAvailable: true,
            credentialAvailable: { _ in true },
            managedPolicy: policy,
            currentBuild: 42))
    }
}
