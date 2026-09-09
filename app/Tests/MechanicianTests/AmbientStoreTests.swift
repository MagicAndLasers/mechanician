import XCTest
@testable import Mechanician

@MainActor
final class AmbientStoreTests: XCTestCase {
    private func managedPolicy(_ fields: [String: Any]) throws -> ManagedEnterprisePolicy {
        let suiteName = "AmbientStorePolicyTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(
            ["schemaVersion": 1, "policy": fields],
            forKey: ManagedEnterprisePolicy.preferenceKey)
        return try XCTUnwrap(ManagedEnterprisePolicy.resolve(
            defaults: defaults,
            forcedOverride: true).policy)
    }

    func testDisabledTaskWithPendingRunRequestStartsInProcessScheduler() {
        let task = makeTask(enabled: false, requestID: "request-1")

        XCTAssertTrue(task.hasPendingRunRequest)
        XCTAssertTrue(task.needsSchedulerProcess)
        XCTAssertTrue(AmbientStore.shouldRunInProcess(
            tasks: [task],
            backgroundAgentInstalled: false,
            daemonAvailable: true,
            credentialAvailable: { _ in true }))
    }

    func testConsumedOrUnassignedManualRequestDoesNotStartScheduler() {
        let consumed = makeTask(
            enabled: false, requestID: "request-1", lastRequestID: "request-1")
        let unassigned = makeTask(enabled: false, assigned: false, requestID: "request-2")

        XCTAssertFalse(consumed.hasPendingRunRequest)
        XCTAssertFalse(consumed.needsSchedulerProcess)
        XCTAssertFalse(unassigned.needsSchedulerProcess)
    }

    func testManualRequestRearmsCompletedOneShotTask() {
        let task = makeTask(enabled: true, requestID: "request-1", onceCompleted: true)

        XCTAssertFalse(task.isEffectivelyEnabled)
        XCTAssertTrue(task.needsSchedulerProcess)
    }

    func testActiveDisabledRunKeepsSchedulerAliveUntilCompletion() {
        let task = makeTask(
            enabled: false,
            activeRun: AmbientActiveRun(
                id: "run-1", startedAt: "2026-07-18T12:00:00.000Z", trigger: "manual"))

        XCTAssertTrue(task.needsSchedulerProcess)
    }

    func testRunnerPolicyRequiresCredentialDaemonAndNoInstalledBackgroundAgent() {
        let pending = makeTask(enabled: false, requestID: "request-1")

        XCTAssertFalse(AmbientStore.shouldRunInProcess(
            tasks: [pending],
            backgroundAgentInstalled: true,
            daemonAvailable: true,
            credentialAvailable: { _ in true }))
        XCTAssertFalse(AmbientStore.shouldRunInProcess(
            tasks: [pending],
            backgroundAgentInstalled: false,
            daemonAvailable: false,
            credentialAvailable: { _ in true }))
        XCTAssertFalse(AmbientStore.shouldRunInProcess(
            tasks: [pending],
            backgroundAgentInstalled: false,
            daemonAvailable: true,
            credentialAvailable: { _ in false }))
    }

    func testRunnerPolicyRejectsInvalidEnterpriseConfiguration() {
        let pending = makeTask(enabled: false, requestID: "request-1")

        XCTAssertFalse(AmbientStore.shouldRunInProcess(
            tasks: [pending],
            backgroundAgentInstalled: false,
            daemonAvailable: true,
            credentialAvailable: { _ in true },
            enterpriseConfigurationAllowsRuntime: false))
    }

    func testInvalidEnterpriseConfigurationDoesNotInitializeOrMutateAmbientState() throws {
        let root = try makePrivateSupportRoot(prefix: "ambient-invalid-enterprise-config")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AmbientStore(
            appSupportBaseOverride: root,
            enterpriseConfigurationAllowsRuntime: false)

        XCTAssertTrue(store.tasks.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: root.appendingPathComponent("ambient").path))
        XCTAssertFalse(store.upsert(makeTask(enabled: true)))
        store.syncInProcessRunner()
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: root.appendingPathComponent("ambient").path))
    }

    func testInstalledDaemonRefreshesAcrossBuildOrProfileBoundary() {
        XCTAssertTrue(AmbientDaemon.shouldRefreshInstallation(
            isInstalled: true, installedIdentity: nil, currentIdentity: "132|anthropic_api|built-in"))
        XCTAssertTrue(AmbientDaemon.shouldRefreshInstallation(
            isInstalled: true,
            installedIdentity: "131|anthropic_api|built-in",
            currentIdentity: "132|anthropic_api|built-in"))
        XCTAssertTrue(AmbientDaemon.shouldRefreshInstallation(
            isInstalled: true,
            installedIdentity: "132|claude_vertex|route-v1:old",
            currentIdentity: "132|claude_vertex|route-v1:new"))
        XCTAssertFalse(AmbientDaemon.shouldRefreshInstallation(
            isInstalled: true,
            installedIdentity: "132|anthropic_api|built-in",
            currentIdentity: "132|anthropic_api|built-in"))
        XCTAssertFalse(AmbientDaemon.shouldRefreshInstallation(
            isInstalled: false,
            installedIdentity: "131|anthropic_api|built-in",
            currentIdentity: "132|anthropic_api|built-in"))
        XCTAssertTrue(AmbientDaemon.shouldRefreshInstallation(
            isInstalled: false,
            installedIdentity: nil,
            currentIdentity: "132|anthropic_api|built-in",
            installationEnabled: true),
            "relaxing managed policy must restore a background job the person left enabled")
        XCTAssertTrue(AmbientDaemon.shouldRefreshInstallation(
            isInstalled: true,
            installedIdentity: "132|anthropic_api|built-in",
            currentIdentity: "132|anthropic_api|built-in",
            cutoverFencePending: true))
        XCTAssertTrue(AmbientDaemon.shouldRefreshInstallation(
            isInstalled: false,
            installedIdentity: "132|anthropic_api|built-in",
            currentIdentity: "132|anthropic_api|built-in",
            cutoverFencePending: true))
    }

    func testAuthorityCutoverFenceStopsWriterAndPersistsCrashRestartIntent() throws {
        let root = try makePrivateSupportRoot(prefix: "ambient-cutover-fence")
        defer { try? FileManager.default.removeItem(at: root) }
        let lease = root.appendingPathComponent("ambient/.scheduler-lease", isDirectory: true)
        try FileManager.default.createDirectory(
            at: lease,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: NSNumber(value: 0o700)])
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o700)],
            ofItemAtPath: root.appendingPathComponent("ambient").path)
        let owner = lease.appendingPathComponent("owner.json")
        let ownerData = try JSONSerialization.data(withJSONObject: [
            "schemaVersion": 1,
            "pid": 4242,
            "token": UUID().uuidString,
        ])
        try ownerData.write(to: owner)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o600)], ofItemAtPath: owner.path)

        var commands: [[String]] = []
        var printCount = 0
        var processChecks = 0
        try AmbientDaemon.fenceForAuthorityCutover(
            supportRoot: root,
            installationConfigured: true,
            command: { arguments in
                commands.append(arguments)
                if arguments.first == "print" {
                    printCount += 1
                    return printCount == 1 ? 0 : 1
                }
                return 0
            },
            processAlive: { pid in
                XCTAssertEqual(pid, 4242)
                processChecks += 1
                return processChecks == 1
            },
            wait: { _ in })

        XCTAssertEqual(commands.first?.first, "bootout")
        XCTAssertGreaterThanOrEqual(printCount, 2)
        XCTAssertGreaterThanOrEqual(processChecks, 2)
        XCTAssertTrue(AmbientDaemon.authorityCutoverFenceIsPending(in: root))
        XCTAssertTrue(AmbientDaemon.shouldRefreshInstallation(
            isInstalled: true,
            installedIdentity: "same",
            currentIdentity: "same",
            cutoverFencePending: AmbientDaemon.authorityCutoverFenceIsPending(in: root)))

        try AmbientDaemon.clearAuthorityCutoverFence(in: root)
        XCTAssertFalse(AmbientDaemon.authorityCutoverFenceIsPending(in: root))
    }

    func testAuthorityCutoverFenceRefusesAStillRunningScheduler() throws {
        let root = try makePrivateSupportRoot(prefix: "ambient-cutover-live-writer")
        defer { try? FileManager.default.removeItem(at: root) }
        let lease = root.appendingPathComponent("ambient/.scheduler-lease", isDirectory: true)
        try FileManager.default.createDirectory(
            at: lease,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: NSNumber(value: 0o700)])
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o700)],
            ofItemAtPath: root.appendingPathComponent("ambient").path)
        let owner = lease.appendingPathComponent("owner.json")
        let ownerData = try JSONSerialization.data(withJSONObject: [
            "schemaVersion": 1,
            "pid": 5252,
            "token": UUID().uuidString,
        ])
        try ownerData.write(to: owner)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o600)], ofItemAtPath: owner.path)

        XCTAssertThrowsError(try AmbientDaemon.fenceForAuthorityCutover(
            supportRoot: root,
            installationConfigured: false,
            command: { arguments in arguments.first == "print" ? 1 : 0 },
            processAlive: { _ in true },
            wait: { _ in })) { error in
                XCTAssertEqual(
                    error as? AmbientDaemon.AuthorityCutoverFenceError,
                    .schedulerWriterStillRunning(5252))
        }
    }

    func testAmbientConfigurationIdentityChangesWhenProfileIsRemoved() {
        let profile = TenantProfile(
            tenantId: "acme",
            displayName: "Acme",
            routes: [
                .init(
                    routeId: "acme-vertex",
                    adapter: "claude-vertex",
                    vertex: .init(projectId: "acme-claude-code", region: "global"),
                    isDefault: true),
            ])

        XCTAssertNotEqual(
            AmbientDaemon.configurationIdentity(build: "132", profile: profile),
            AmbientDaemon.configurationIdentity(build: "132", profile: .default))
        XCTAssertTrue(
            AmbientDaemon.configurationIdentity(build: "132", profile: .default)
                .hasSuffix("|authority-inbox-v1"))
        XCTAssertEqual(
            AmbientDaemon.observedAuthorityGeneration(.legacyDefault(
                root: URL(fileURLWithPath: "/tmp/mechanician-authority-anchor"))),
            "legacy-unmarked")
    }

    func testAcmeAmbientRouteUsesProfileScopedVertexConfigInStandardApp() {
        let profile = TenantProfile(
            tenantId: "acme",
            displayName: "Mechanician for Acme",
            bundleIdentifier: "ai.mechanician.app.acme",
            routes: [
                .init(
                    routeId: "acme-claude-vertex",
                    adapter: "claude-vertex",
                    vertex: .init(projectId: "acme-claude-code", region: "global"),
                    isDefault: true),
            ])

        XCTAssertEqual(AmbientDaemon.accountAccess(for: .default), .anthropicAPI)
        XCTAssertEqual(AmbientDaemon.accountAccess(for: profile), .claudeVertex)

        let environment = AmbientDaemon.processEnvironment(
            profile: profile,
            bundleIdentifier: MechanicianEnvironment.baseBundleIdentifier,
            environment: [:],
            homeDirectory: URL(fileURLWithPath: "/Users/tester", isDirectory: true))
        XCTAssertEqual(environment["MECHANICIAN_AUTH"], "vertex")
        XCTAssertEqual(environment["MECHANICIAN_VERTEX_PROJECT"], "acme-claude-code")
        XCTAssertEqual(environment["MECHANICIAN_VERTEX_REGION"], "global")
        XCTAssertNil(environment["MECHANICIAN_SUPPORT_DIR"])
        XCTAssertEqual(
            environment["MECHANICIAN_CONFIG_DIR"],
            "/Users/tester/Library/Application Support/Mechanician/provider-routes/"
                + "7c86779685e856956be1b192d68366b7c89864c8a72282b85127c48858cba0f0/claude")
        XCTAssertEqual(
            environment["MECHANICIAN_MCP_SECRET_SERVICE"],
            "ai.mechanician.mcp-secret")
        XCTAssertNil(environment["ANTHROPIC_API_KEY"])
        XCTAssertNil(environment["GOOGLE_APPLICATION_CREDENTIALS"])
    }

    private func makePrivateSupportRoot(prefix: String) throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "\(prefix)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o700)], ofItemAtPath: root.path)
        return root
    }

    func testInstalledAmbientEnvironmentUsesSignedAppForNativeNotifications() {
        let environment = AmbientDaemon.processEnvironment(
            profile: .default,
            bundleIdentifier: MechanicianEnvironment.baseBundleIdentifier,
            environment: [:],
            homeDirectory: URL(fileURLWithPath: "/Users/tester", isDirectory: true),
            notificationExecutable: URL(
                fileURLWithPath: "/Applications/Mechanician.app/Contents/MacOS/Mechanician"))

        XCTAssertEqual(
            environment["MECHANICIAN_NOTIFICATION_EXECUTABLE"],
            "/Applications/Mechanician.app/Contents/MacOS/Mechanician")
    }

    func testAmbientEnvironmentIgnoresCallerSuppliedManagedPolicyVariables() {
        let managedKeys = [
            "MECHANICIAN_MANAGED_POLICY",
            "MECHANICIAN_MAX_PERMISSION_MODE",
            "MECHANICIAN_ALLOWED_PROVIDER_ACCESSES",
            "MECHANICIAN_ALLOW_USER_EXTENSIONS",
            "MECHANICIAN_MANAGED_EXTENSION_SERVERS",
            "MECHANICIAN_ALLOW_UNATTENDED_TASKS",
        ]
        let environment = AmbientDaemon.processEnvironment(
            profile: .default,
            bundleIdentifier: MechanicianEnvironment.devBundleIdentifier,
            environment: Dictionary(uniqueKeysWithValues: managedKeys.map { ($0, "attacker") }),
            homeDirectory: URL(fileURLWithPath: "/Users/tester", isDirectory: true),
            managedPolicy: nil)

        for key in managedKeys {
            XCTAssertNil(environment[key], "\(key) must come only from forced preferences")
        }
    }

    func testAmbientEnvironmentCarriesExactManagedPolicySnapshot() throws {
        let policy = try managedPolicy([
            "allowedProviderAccesses": ["openai_api", "claude_vertex"],
            "maximumInteractivePermissionMode": "default",
            "allowUserConfiguredExtensions": false,
            "allowUnattendedTasks": false,
        ])
        let server = TenantProfile.ManagedServer(
            name: "managed-tools",
            transport: "http",
            url: "https://tools.example.invalid/mcp",
            command: nil,
            args: nil,
            env: nil,
            networkScope: "vpnOnly")
        let profile = TenantProfile(
            tenantId: "acme",
            displayName: "Acme",
            extensions: .init(allowPublic: false, managedServers: [server]))
        let environment = AmbientDaemon.processEnvironment(
            profile: profile,
            bundleIdentifier: MechanicianEnvironment.baseBundleIdentifier,
            environment: [
                "MECHANICIAN_MAX_PERMISSION_MODE": "bypassPermissions",
                "MECHANICIAN_ALLOWED_PROVIDER_ACCESSES": "anthropic_api",
                "MECHANICIAN_ALLOW_UNATTENDED_TASKS": "1",
            ],
            homeDirectory: URL(fileURLWithPath: "/Users/tester", isDirectory: true),
            managedPolicy: policy)

        XCTAssertEqual(environment["MECHANICIAN_MANAGED_POLICY"], "1")
        XCTAssertEqual(environment["MECHANICIAN_MAX_PERMISSION_MODE"], "default")
        XCTAssertEqual(
            environment["MECHANICIAN_ALLOWED_PROVIDER_ACCESSES"],
            "claude_vertex,openai_api")
        XCTAssertEqual(environment["MECHANICIAN_ALLOW_USER_EXTENSIONS"], "0")
        XCTAssertEqual(environment["MECHANICIAN_ALLOW_UNATTENDED_TASKS"], "0")
        let serversData = try XCTUnwrap(
            environment["MECHANICIAN_MANAGED_EXTENSION_SERVERS"]?.data(using: .utf8))
        XCTAssertEqual(
            try JSONDecoder().decode([TenantProfile.ManagedServer].self, from: serversData),
            [server])
    }

    func testAmbientEnvironmentBlocksUnattendedTurnsBelowMinimumBuild() throws {
        let policy = try managedPolicy([
            "allowUnattendedTasks": true,
            "minimumAppBuild": 42,
        ])

        let blocked = AmbientDaemon.processEnvironment(
            profile: .default,
            bundleIdentifier: MechanicianEnvironment.baseBundleIdentifier,
            environment: [:],
            homeDirectory: URL(fileURLWithPath: "/Users/tester", isDirectory: true),
            managedPolicy: policy,
            currentBuild: 41)
        let allowed = AmbientDaemon.processEnvironment(
            profile: .default,
            bundleIdentifier: MechanicianEnvironment.baseBundleIdentifier,
            environment: [:],
            homeDirectory: URL(fileURLWithPath: "/Users/tester", isDirectory: true),
            managedPolicy: policy,
            currentBuild: 42)

        XCTAssertEqual(blocked["MECHANICIAN_ALLOW_UNATTENDED_TASKS"], "0")
        XCTAssertEqual(allowed["MECHANICIAN_ALLOW_UNATTENDED_TASKS"], "1")
    }

    private func makeTask(
        enabled: Bool,
        assigned: Bool = true,
        requestID: String? = nil,
        lastRequestID: String? = nil,
        onceCompleted: Bool? = nil,
        activeRun: AmbientActiveRun? = nil
    ) -> ScheduledTask {
        ScheduledTask(
            name: "Test task",
            prompt: "Test prompt",
            workspaceID: assigned ? UUID() : nil,
            enabled: enabled,
            trigger: AmbientTrigger(
                type: "time",
                schedule: AmbientSchedule(kind: "daily", hour: 9, minute: 0)),
            runRequestID: requestID,
            lastRunRequestID: lastRequestID,
            onceCompleted: onceCompleted,
            activeRun: activeRun)
    }
}

/// Deleting a scheduled task was one unconfirmed click onto a hard `removeAll` — no trash, no undo,
/// while conversations, artifacts and workspace moves were all recoverable. A configured automation
/// is exactly the thing a stray click should not be able to destroy.
@MainActor
final class AmbientTaskDeleteUndoTests: XCTestCase {
    private func store() throws -> (AmbientStore, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "ambient-undo-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return (AmbientStore(appSupportBaseOverride: root), root)
    }

    private func task(_ name: String) -> ScheduledTask {
        ScheduledTask(
            name: name,
            prompt: "do the thing",
            workspaceID: UUID(),
            trigger: AmbientTrigger(
                type: "time", schedule: AmbientSchedule(kind: "interval", minutes: 60)))
    }

    func testAnUndoneDeleteRestoresTheTaskToItsOwnPosition() throws {
        let (store, root) = try store()
        defer { try? FileManager.default.removeItem(at: root) }
        let tasks = ["first", "second", "third"].map(task)
        for one in tasks { store.upsert(one) }
        XCTAssertEqual(store.tasks.map(\.name), ["first", "second", "third"])

        let removed = tasks[1]
        let index = try XCTUnwrap(store.tasks.firstIndex(where: { $0.id == removed.id }))
        store.delete(removed.id)
        XCTAssertEqual(store.tasks.map(\.name), ["first", "third"])

        store.reinsert(removed, at: index)
        XCTAssertEqual(
            store.tasks.map(\.name), ["first", "second", "third"],
            "an undone delete puts the task back where it was, not on the end")
        XCTAssertEqual(store.tasks[1], removed, "and puts back the whole task, not a husk of it")
    }

    /// The undo registration captures an index. By the time it runs the list may be shorter, and a
    /// stale index must not trap or silently drop the task.
    func testAStaleIndexIsClampedRatherThanTrapped() throws {
        let (store, root) = try store()
        defer { try? FileManager.default.removeItem(at: root) }
        let one = task("only")
        store.upsert(one)
        store.delete(one.id)

        store.reinsert(one, at: 99)
        XCTAssertEqual(store.tasks.map(\.name), ["only"])
    }

    /// Redo re-deletes, so undo must not be able to double-insert if it runs twice.
    func testRestoringATaskThatIsAlreadyThereIsANoOp() throws {
        let (store, root) = try store()
        defer { try? FileManager.default.removeItem(at: root) }
        let one = task("only")
        store.upsert(one)

        store.reinsert(one, at: 0)
        XCTAssertEqual(store.tasks.count, 1)
    }
}
