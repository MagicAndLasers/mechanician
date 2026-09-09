import XCTest
import Darwin
@testable import Mechanician

private final class AgentdRuntimeDataBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Data?

    func store(_ data: Data) {
        lock.lock()
        stored = data
        lock.unlock()
    }

    func load() -> Data? {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }
}

@MainActor
final class AgentdRuntimeTests: XCTestCase {
    private func managedPolicy(_ fields: [String: Any]) throws -> ManagedEnterprisePolicy {
        let suiteName = "AgentdRuntimePolicyTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(
            ["schemaVersion": 1, "policy": fields],
            forKey: ManagedEnterprisePolicy.preferenceKey)
        return try XCTUnwrap(ManagedEnterprisePolicy.resolve(
            defaults: defaults,
            forcedOverride: true).policy)
    }

    func testAgentdPathResolverPrefersExplicitOverride() {
        let result = AgentdRuntime.resolvedAgentdPath(
            environment: ["MECHANICIAN_AGENTD": "/custom/agentd.mjs"],
            resourceURL: URL(fileURLWithPath: "/bundle/Resources", isDirectory: true),
            bundleURL: URL(fileURLWithPath: "/repo/build/Mechanician-dev.app", isDirectory: true),
            currentDirectoryURL: URL(fileURLWithPath: "/repo", isDirectory: true),
            fileExists: { _ in true })

        XCTAssertEqual(result, "/custom/agentd.mjs")
    }

    func testAgentdPathResolverPrefersBundledRuntimeOverRepository() {
        let bundled = "/bundle/Resources/agentd/src/agentd.mjs"
        let result = AgentdRuntime.resolvedAgentdPath(
            environment: [:],
            resourceURL: URL(fileURLWithPath: "/bundle/Resources", isDirectory: true),
            bundleURL: URL(fileURLWithPath: "/repo/build/Mechanician.app", isDirectory: true),
            currentDirectoryURL: URL(fileURLWithPath: "/repo", isDirectory: true),
            fileExists: { $0 == bundled || $0 == "/repo/agentd/src/agentd.mjs" })

        XCTAssertEqual(result, bundled)
    }

    func testAgentdPathResolverFindsRepositoryFromDevBundle() {
        let sourceRuntime = "/repo/agentd/src/agentd.mjs"
        let result = AgentdRuntime.resolvedAgentdPath(
            environment: [:],
            resourceURL: URL(fileURLWithPath: "/repo/build/Mechanician-dev.app/Contents/Resources"),
            bundleURL: URL(fileURLWithPath: "/repo/build/Mechanician-dev.app", isDirectory: true),
            currentDirectoryURL: URL(fileURLWithPath: "/unrelated", isDirectory: true),
            fileExists: { $0 == sourceRuntime })

        XCTAssertEqual(result, sourceRuntime)
    }

    func testAgentdPathResolverFindsRepositoryFromRepositoryWorkingDirectory() {
        let sourceRuntime = "/repo/agentd/src/agentd.mjs"
        let result = AgentdRuntime.resolvedAgentdPath(
            environment: ["MECHANICIAN_AGENTD": "   "],
            resourceURL: nil,
            bundleURL: URL(fileURLWithPath: "/Applications/Mechanician.app", isDirectory: true),
            currentDirectoryURL: URL(fileURLWithPath: "/repo", isDirectory: true),
            fileExists: { $0 == sourceRuntime })

        XCTAssertEqual(result, sourceRuntime)
    }

    func testChildEnvironmentAlwaysCarriesUserIdentityForSecureStorage() {
        XCTAssertEqual(
            AgentdRuntime.withUserIdentity([:], currentUser: "fixture-user"),
            ["USER": "fixture-user", "LOGNAME": "fixture-user"])
        XCTAssertEqual(
            AgentdRuntime.withUserIdentity(
                ["USER": "explicit-user", "LOGNAME": "explicit-login"],
                currentUser: "fixture-user"),
            ["USER": "explicit-user", "LOGNAME": "explicit-login"])
    }

    func testTenantProfileCanOnlySupplyAuditedVertexRouteMetadata() {
        let supportDirectory = URL(
            fileURLWithPath: "/Users/tester/Library/Application Support/Mechanician",
            isDirectory: true)
        let profile = TenantProfile(
            tenantId: "acme",
            displayName: "Mechanician for Acme",
            routes: [
                TenantProfile.Route(
                    routeId: "acme-vertex",
                    adapter: "claude-vertex",
                    vertex: .init(projectId: "acme-claude-code", region: "us-east5"),
                    models: [
                        TenantProfile.Model(
                            id: "claude-opus-4-8", displayName: "Opus 4.8", isDefault: true),
                    ]),
            ])
        XCTAssertEqual(
            AgentdRuntime.tenantRouteEnvironment(
                for: .claudeVertex,
                profile: profile,
                supportDirectory: supportDirectory),
            [
                "MECHANICIAN_VERTEX_PROJECT": "acme-claude-code",
                "MECHANICIAN_VERTEX_REGION": "us-east5",
                "MECHANICIAN_MANAGED_MODEL": "claude-opus-4-8",
                "MECHANICIAN_ROUTE_IDENTITY":
                    "route-v1:05f907d80a283fe013336ae8f15f76e4477e41a40817b259080736bed8c1a936",
                "MECHANICIAN_CONFIG_DIR":
                    "/Users/tester/Library/Application Support/Mechanician/provider-routes/"
                    + "05f907d80a283fe013336ae8f15f76e4477e41a40817b259080736bed8c1a936/claude",
            ])
        XCTAssertTrue(
            AgentdRuntime.tenantRouteEnvironment(
                for: .claudeSubscription,
                profile: profile,
                supportDirectory: supportDirectory).isEmpty)
        XCTAssertTrue(
            AgentdRuntime.tenantRouteEnvironment(
                for: .anthropicAPI,
                profile: profile,
                supportDirectory: supportDirectory).isEmpty)
    }

    func testFramerDecodesFragmentedEventsInWireOrder() {
        let framer = AgentdNDJSONFramer(maximumFrameBytes: 1024)
        var events: [[String: Any]] = []
        let deliver: (AgentdDecodedEvent) -> Bool = {
            events.append($0.value)
            return true
        }

        XCTAssertConsumed(framer.consume(Data(#"{"type":"one","value":1}"#.utf8), deliver: deliver))
        XCTAssertTrue(events.isEmpty)
        XCTAssertConsumed(framer.consume(Data("\n{\"type\":\"two\",\"value\":2}\n".utf8), deliver: deliver))

        XCTAssertEqual(events.compactMap { $0["type"] as? String }, ["one", "two"])
        XCTAssertEqual(events.compactMap { $0["value"] as? Int }, [1, 2])
    }

    func testFramerRejectsAnUnterminatedOversizedFrameAndReleasesStorage() {
        let framer = AgentdNDJSONFramer(maximumFrameBytes: 16)
        let result = framer.consume(Data(repeating: 0x61, count: 17)) { _ in true }
        guard case .frameTooLarge = result else {
            return XCTFail("expected an oversized-frame result")
        }

        var deliveredType: String?
        XCTAssertConsumed(framer.consume(Data("{\"type\":\"ok\"}\n".utf8)) {
            deliveredType = $0.value["type"] as? String
            return true
        })
        XCTAssertEqual(deliveredType, "ok")
    }

    func testFramerStopsBeforeQueuingMoreEventsAfterRuntimeDetaches() {
        let framer = AgentdNDJSONFramer(maximumFrameBytes: 1024)
        var deliveries = 0
        let result = framer.consume(Data("{\"type\":\"one\"}\n{\"type\":\"two\"}\n".utf8)) { _ in
            deliveries += 1
            return false
        }
        guard case .detached = result else {
            return XCTFail("expected detached result")
        }
        XCTAssertEqual(deliveries, 1)
    }

    func testOutboundRecordEscapesJavaScriptLineSeparatorsAndRoundTrips() throws {
        let separated = "before\u{2028}middle\u{2029}after"
        let escapedLooking = #"literal \u2028 and \u2029"#
        let record = try AgentdNDJSONRecordEncoder.encode([
            "type": "help_search_response",
            "text": separated,
            "nested": ["value": separated],
            "escapedLooking": escapedLooking,
        ])

        XCTAssertEqual(record.last, 0x0A, "the record needs exactly one NDJSON terminator")
        XCTAssertEqual(record.filter { $0 == 0x0A }.count, 1)
        let payload = Data(record.dropLast())
        let wire = try XCTUnwrap(String(data: payload, encoding: .utf8))
        XCTAssertFalse(wire.contains("\u{2028}"))
        XCTAssertFalse(wire.contains("\u{2029}"))
        XCTAssertTrue(wire.contains(#"\u2028"#))
        XCTAssertTrue(wire.contains(#"\u2029"#))

        let decoded = try XCTUnwrap(
            JSONSerialization.jsonObject(with: payload) as? [String: Any])
        XCTAssertEqual(decoded["text"] as? String, separated)
        XCTAssertEqual((decoded["nested"] as? [String: Any])?["value"] as? String, separated)
        XCTAssertEqual(decoded["escapedLooking"] as? String, escapedLooking)
    }

    func testRuntimeStartReturnsBeforeSlowExecutableValidationCompletes() async {
        let launchFailed = expectation(description: "asynchronous launch result")
        let runtime = AgentdRuntime(
            access: .codexSubscription,
            onEvent: { _, _ in },
            onLaunchFailure: { _, detail in
                XCTAssertEqual(detail, "fixture validation delay")
                launchFailed.fulfill()
            },
            onUnexpectedExit: { _, _ in
                XCTFail("the fixture never launches a process")
            },
            processStarter: { _ in
                Thread.sleep(forTimeInterval: 0.35)
                return "fixture validation delay"
            })

        let began = CFAbsoluteTimeGetCurrent()
        runtime.start()
        let elapsed = CFAbsoluteTimeGetCurrent() - began

        XCTAssertLessThan(elapsed, 0.1, "Process.run work escaped onto the main actor")
        await fulfillment(of: [launchFailed], timeout: 2)
    }

    func testRuntimeBindsMCPControlToTheSelectedProviderAccountInstance() async {
        let launched = expectation(description: "captured daemon environment")
        let access = ModelAccess.codexSubscription
        let expected = ProviderAccountStore.shared.accountInstanceID(for: access)
            .rawValue.uuidString.lowercased()
        let runtime = AgentdRuntime(
            access: access,
            onEvent: { _, _ in },
            onLaunchFailure: { _, detail in
                XCTAssertEqual(detail, "fixture captured environment")
                launched.fulfill()
            },
            onUnexpectedExit: { _, _ in },
            processStarter: { process in
                XCTAssertEqual(
                    process.environment?["MECHANICIAN_ACCOUNT_INSTANCE_ID"], expected)
                XCTAssertEqual(process.environment?["MECHANICIAN_PROVIDER"], "codex")
                return "fixture captured environment"
            })

        runtime.start()
        await fulfillment(of: [launched], timeout: 2)
    }

    func testAgentPathPrefersLoginShellAndAppendsBundledRuntimeLast() {
        let path = AgentdRuntime.agentPath(
            login: "/opt/homebrew/bin:/usr/bin:/bin",
            inherited: "/usr/bin:/bin:/usr/sbin:/sbin",
            runtime: "/Applications/Mechanician.app/Contents/Resources/runtime")

        // The person's own tools resolve first, exactly as they do in their Terminal.
        XCTAssertTrue(path.hasPrefix("/opt/homebrew/bin:/usr/bin:/bin"), path)
        // The bundled runtime is a fallback, never an override: a bundled `node` must not shadow theirs.
        XCTAssertTrue(
            path.hasSuffix(":/Applications/Mechanician.app/Contents/Resources/runtime"), path)
        // Inherited entries the login shell did not list still survive.
        XCTAssertTrue(path.split(separator: ":").contains("/usr/sbin"), path)
        // No entry is repeated, so relaunching cannot grow PATH without bound.
        let entries = path.split(separator: ":").map(String.init)
        XCTAssertEqual(entries.count, Set(entries).count, path)
    }

    func testAgentPathSurvivesAnUnreadableLoginShell() {
        let path = AgentdRuntime.agentPath(
            login: nil, inherited: "/usr/bin:/bin", runtime: "/bundle/runtime")

        XCTAssertEqual(path, "/usr/bin:/bin:/bundle/runtime")
    }

    func testAgentPathFallsBackWhenNoSourceProvidesAnything() {
        let path = AgentdRuntime.agentPath(login: nil, inherited: nil, runtime: nil)

        XCTAssertEqual(path, "/usr/local/bin:/usr/bin:/bin")
    }

    func testRuntimeGivesTheDaemonTheLoginShellPathAheadOfTheBundledRuntime() async {
        let launched = expectation(description: "captured daemon PATH")
        let runtime = AgentdRuntime(
            access: .claudeVertex,
            onEvent: { _, _ in },
            onLaunchFailure: { _, detail in
                XCTAssertEqual(detail, "fixture captured environment")
                launched.fulfill()
            },
            onUnexpectedExit: { _, _ in },
            processStarter: { process in
                let path = process.environment?["PATH"] ?? ""
                // A GUI launch inherits only the minimal launchd PATH. Without the login shell the
                // person's npm, gh and python3 are unreachable and the agent reports them blocked.
                XCTAssertTrue(path.hasPrefix("/opt/homebrew/bin:"), path)
                // The bundle's own directory must never come first — it shadowed the person's node.
                XCTAssertFalse(path.hasPrefix("/Applications"), path)
                XCTAssertTrue(path.split(separator: ":").contains("/opt/homebrew/bin"), path)
                return "fixture captured environment"
            },
            processEnvironment: { ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin"] },
            loginShellPath: { "/opt/homebrew/bin:/usr/bin:/bin" },
            managedPolicy: nil)

        runtime.start()
        await fulfillment(of: [launched], timeout: 2)
    }

    func testRuntimeIgnoresInheritedManagedPolicyVariables() async {
        let launched = expectation(description: "captured sanitized daemon environment")
        let managedKeys = [
            "MECHANICIAN_MANAGED_POLICY",
            "MECHANICIAN_MAX_PERMISSION_MODE",
            "MECHANICIAN_ALLOWED_PROVIDER_ACCESSES",
            "MECHANICIAN_ALLOW_USER_EXTENSIONS",
            "MECHANICIAN_MANAGED_EXTENSION_SERVERS",
            "MECHANICIAN_ALLOW_UNATTENDED_TASKS",
        ]
        let runtime = AgentdRuntime(
            access: .claudeVertex,
            onEvent: { _, _ in },
            onLaunchFailure: { _, detail in
                XCTAssertEqual(detail, "fixture captured environment")
                launched.fulfill()
            },
            onUnexpectedExit: { _, _ in },
            processStarter: { process in
                for key in managedKeys {
                    XCTAssertNil(
                        process.environment?[key],
                        "\(key) must come only from forced preferences")
                }
                return "fixture captured environment"
            },
            processEnvironment: {
                Dictionary(uniqueKeysWithValues: managedKeys.map { ($0, "attacker") })
            },
            managedPolicy: nil)

        runtime.start()
        await fulfillment(of: [launched], timeout: 2)
    }

    func testRuntimeCarriesExactManagedPolicyAndSignedServerSnapshot() async throws {
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
        let launched = expectation(description: "captured managed daemon environment")
        let runtime = AgentdRuntime(
            access: .claudeVertex,
            onEvent: { _, _ in },
            onLaunchFailure: { _, detail in
                XCTAssertEqual(detail, "fixture captured environment")
                launched.fulfill()
            },
            onUnexpectedExit: { _, _ in },
            processStarter: { process in
                let environment = process.environment ?? [:]
                XCTAssertEqual(environment["MECHANICIAN_MANAGED_POLICY"], "1")
                XCTAssertEqual(environment["MECHANICIAN_MAX_PERMISSION_MODE"], "default")
                XCTAssertEqual(
                    environment["MECHANICIAN_ALLOWED_PROVIDER_ACCESSES"],
                    "claude_vertex,openai_api")
                XCTAssertEqual(environment["MECHANICIAN_ALLOW_USER_EXTENSIONS"], "0")
                XCTAssertEqual(environment["MECHANICIAN_ALLOW_UNATTENDED_TASKS"], "0")
                let data = environment["MECHANICIAN_MANAGED_EXTENSION_SERVERS"]?
                    .data(using: .utf8)
                let servers = data.flatMap {
                    try? JSONDecoder().decode([TenantProfile.ManagedServer].self, from: $0)
                }
                XCTAssertEqual(servers?.map(\.name), ["managed-tools"])
                return "fixture captured environment"
            },
            processEnvironment: {
                [
                    "MECHANICIAN_MAX_PERMISSION_MODE": "bypassPermissions",
                    "MECHANICIAN_ALLOWED_PROVIDER_ACCESSES": "anthropic_api",
                    "MECHANICIAN_ALLOW_UNATTENDED_TASKS": "1",
                ]
            },
            managedPolicy: policy,
            tenantProfile: { profile })

        runtime.start()
        await fulfillment(of: [launched], timeout: 2)
    }

    func testRuntimeRejectsBlockedProviderBeforeStartingAChild() async throws {
        let policy = try managedPolicy([
            "allowedProviderAccesses": ["openai_api"],
        ])
        let rejected = expectation(description: "blocked provider rejected")
        let runtime = AgentdRuntime(
            access: .claudeVertex,
            onEvent: { _, _ in },
            onLaunchFailure: { access, detail in
                XCTAssertEqual(access, .claudeVertex)
                XCTAssertTrue(detail.contains("blocked by your organization"))
                rejected.fulfill()
            },
            onUnexpectedExit: { _, _ in },
            processStarter: { _ in
                XCTFail("a blocked provider must not start agentd")
                return "unexpected start"
            },
            managedPolicy: policy)

        runtime.start()
        await fulfillment(of: [rejected], timeout: 1)
    }

    func testRuntimeWriteReturnsBeforeSlowPipeConsumerCompletes() async {
        let launched = expectation(description: "fixture launched")
        let writeEntered = expectation(description: "background writer entered")
        let releaseWrite = DispatchSemaphore(value: 0)
        let captured = AgentdRuntimeDataBox()
        let request: [String: Any] = [
            "type": "send",
            "prompt": "hello\u{2028}still one record\u{2029}done",
        ]
        let runtime = AgentdRuntime(
            access: .claudeVertex,
            onEvent: { _, _ in },
            onLaunchFailure: { _, detail in
                XCTFail("fixture should launch: \(detail)")
            },
            onUnexpectedExit: { _, _ in },
            processStarter: { process in
                process.executableURL = URL(fileURLWithPath: "/bin/sh")
                process.arguments = ["-c", "sleep 30"]
                do {
                    try process.run()
                    launched.fulfill()
                    return nil
                } catch {
                    return error.localizedDescription
                }
            },
            recordWriter: { _, data in
                captured.store(data)
                writeEntered.fulfill()
                _ = releaseWrite.wait(timeout: .now() + 2)
            })

        runtime.start()
        await fulfillment(of: [launched], timeout: 2)

        let began = CFAbsoluteTimeGetCurrent()
        XCTAssertTrue(runtime.write(request))
        let elapsed = CFAbsoluteTimeGetCurrent() - began

        XCTAssertLessThan(elapsed, 0.1, "A blocked child pipe escaped onto the main actor")
        await fulfillment(of: [writeEntered], timeout: 1)
        XCTAssertEqual(captured.load(), try? AgentdNDJSONRecordEncoder.encode(request))
        releaseWrite.signal()
        runtime.stop()
    }

    func testUnexpectedExitCarriesProcessStatusAndReason() async {
        let exited = expectation(description: "unexpected exit")
        var received: AgentdUnexpectedExit?
        let runtime = AgentdRuntime(
            access: .claudeVertex,
            onEvent: { _, _ in },
            onLaunchFailure: { _, detail in
                XCTFail("fixture should launch: \(detail)")
            },
            onUnexpectedExit: { access, exit in
                XCTAssertEqual(access, .claudeVertex)
                received = exit
                exited.fulfill()
            },
            processStarter: { process in
                process.executableURL = URL(fileURLWithPath: "/bin/sh")
                process.arguments = ["-c", "exit 7"]
                do {
                    try process.run()
                    return nil
                } catch {
                    return error.localizedDescription
                }
            })

        runtime.start()
        await fulfillment(of: [exited], timeout: 2)

        XCTAssertEqual(received, AgentdUnexpectedExit(status: 7, reason: .exit))
        XCTAssertEqual(received?.diagnosticCode, "agentd_exit_7")
        XCTAssertEqual(received?.terminalReason, "Runtime exited with code 7")
    }

    func testImmediateRetirementCompletesOnlyAfterExactProcessExited() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("mechanician-runtime-retire-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let pidFile = root.appendingPathComponent("agentd.pid")
        let escapedPIDFile = pidFile.path.replacingOccurrences(of: "'", with: "'\\''")
        let launched = expectation(description: "fixture launched")
        let retired = expectation(description: "exact process retired")
        let runtime = AgentdRuntime(
            access: .claudeVertex,
            onEvent: { _, _ in },
            onLaunchFailure: { _, detail in XCTFail("fixture should launch: \(detail)") },
            onUnexpectedExit: { _, _ in XCTFail("intentional retirement is not unexpected") },
            processStarter: { process in
                process.executableURL = URL(fileURLWithPath: "/bin/sh")
                process.arguments = [
                    "-c",
                    "echo $$ > '\(escapedPIDFile)'; trap 'exit 0' TERM; while :; do sleep 1; done",
                ]
                do {
                    try process.run()
                    launched.fulfill()
                    return nil
                } catch {
                    return error.localizedDescription
                }
            })
        defer {
            runtime.stop()
            try? FileManager.default.removeItem(at: root)
        }

        runtime.start()
        await fulfillment(of: [launched], timeout: 2)
        let deadline = Date().addingTimeInterval(2)
        while !FileManager.default.fileExists(atPath: pidFile.path), Date() < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        let pid = try XCTUnwrap(
            Int(String(contentsOf: pidFile, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines)))

        runtime.retireImmediately {
            XCTAssertFalse(runtime.isRunning)
            retired.fulfill()
        }
        XCTAssertTrue(runtime.isRunning, "TERM delivery is not yet process-exit evidence")
        await fulfillment(of: [retired], timeout: 3)
        XCTAssertNotEqual(Darwin.kill(Int32(pid), 0), 0)
    }

    private func XCTAssertConsumed(
        _ result: AgentdFrameConsumeResult,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard case .consumed = result else {
            return XCTFail("expected consumed result", file: file, line: line)
        }
    }
}
