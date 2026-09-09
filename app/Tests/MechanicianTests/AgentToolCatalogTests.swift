import XCTest
@testable import Mechanician

@MainActor
final class AgentToolCatalogTests: XCTestCase {
    private func bridgeSource() throws -> String {
        try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Sources/Mechanician/AgentBridge.swift"),
            encoding: .utf8)
    }

    private func catalogSource() throws -> String {
        try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Sources/Mechanician/AgentToolCatalog.swift"),
            encoding: .utf8)
    }

    private func bridgeBody(
        _ source: String,
        from start: String,
        until end: String
    ) throws -> Substring {
        let startRange = try XCTUnwrap(source.range(of: start))
        let endRange = try XCTUnwrap(
            source.range(of: end, range: startRange.upperBound..<source.endIndex))
        return source[startRange.lowerBound..<endRange.lowerBound]
    }

    private func route(
        bridgeID: UUID = UUID(),
        runtimeGeneration: UUID = UUID(),
        conversationID: UUID = UUID(),
        turnID: String = UUID().uuidString,
        access: ModelAccess = .anthropicAPI,
        modelID: String = "model",
        accountInstanceID: ProviderAccountInstanceID = ProviderAccountInstanceID(),
        credentialEpoch: Int = 1,
        providerRouteIdentity: String = "route",
        workspaceIdentity: String = "home",
        canonicalCWD: String = "/tmp/workspace",
        toolProfile: ProviderToolProfile = .standard,
        permissionMode: String = "default",
        providerSessionRevision: UUID = UUID(),
        workspaceInstructionsRevision: String = "instructions"
    ) -> AgentToolSurfaceRoute {
        AgentToolSurfaceRoute(
            bridgeID: bridgeID,
            runtimeGeneration: runtimeGeneration,
            conversationID: conversationID,
            turnID: turnID,
            selection: ModelSelection(access: access, modelID: modelID),
            accountInstanceID: accountInstanceID,
            credentialEpoch: credentialEpoch,
            providerRouteIdentity: providerRouteIdentity,
            workspaceIdentity: workspaceIdentity,
            canonicalCWD: canonicalCWD,
            toolProfile: toolProfile,
            permissionMode: permissionMode,
            providerSessionRevision: providerSessionRevision,
            workspaceInstructionsRevision: workspaceInstructionsRevision)
    }

    @discardableResult
    private func ready(
        _ catalog: AgentToolCatalog,
        route: AgentToolSurfaceRoute,
        tools: [String],
        coverage: AgentToolSurfaceCoverage = .complete
    ) -> AgentToolSurfaceSnapshot {
        catalog.begin(route: route)
        XCTAssertTrue(catalog.publish(
            tools: tools,
            coverage: coverage,
            provenance: coverage == .complete ? .providerInit : .mechanicianCodexThread,
            adapterRevision: AgentToolCatalog.adapterRevision,
            for: route))
        return try! XCTUnwrap(catalog.snapshot(for: route.conversationID))
    }

    func testToolsAreGroupedByWhatTheyDoForYou() {
        let catalog = AgentToolCatalog()
        let snapshot = ready(
            catalog,
            route: route(),
            tools: ["Read", "Edit", "Bash", "WebSearch", "mcp__automation__RunAppleScript"])

        let titles = AgentToolCatalog.groups(for: snapshot).map(\.title)
        XCTAssertTrue(titles.contains("Read and change files"))
        XCTAssertTrue(titles.contains("Run commands"))
        XCTAssertTrue(titles.contains("Search and read the web"))
        XCTAssertTrue(titles.contains("Work the apps on this Mac"))
    }

    func testOnlyReportedGroupsAppear() {
        let catalog = AgentToolCatalog()
        let snapshot = ready(catalog, route: route(), tools: ["Read", "Bash"])
        let ids = AgentToolCatalog.groups(for: snapshot).map(\.id)
        XCTAssertTrue(ids.contains("files"))
        XCTAssertTrue(ids.contains("shell"))
        XCTAssertFalse(ids.contains("web"))
        XCTAssertFalse(ids.contains("mac"))
    }

    func testUnknownToolsRemainVisible() {
        let catalog = AgentToolCatalog()
        let snapshot = ready(
            catalog,
            route: route(),
            tools: ["Read", "SomeBrandNewTool", "mcp__github__create_pull_request"])
        XCTAssertEqual(
            AgentToolCatalog.ungroupedTools(in: snapshot),
            ["SomeBrandNewTool", "mcp__github__create_pull_request"])
    }

    func testOnlyExactAppOwnedMCPAliasesSatisfyCanonicalCapabilities() {
        XCTAssertEqual(
            AgentToolCatalog.canonicalCapabilityID(for: "mcp__computer__ComputerClick"),
            "ComputerClick")
        XCTAssertEqual(
            AgentToolCatalog.canonicalCapabilityID(for: "mcp__help__SearchMechanicianHelp"),
            "SearchMechanicianHelp")
        XCTAssertEqual(
            AgentToolCatalog.canonicalCapabilityID(for: "mcp__help__ShowMechanician"),
            "ShowMechanician")
        XCTAssertEqual(
            AgentToolCatalog.canonicalCapabilityID(
                for: "mcp__help__RecommendMechanicianWorkflow"),
            "RecommendMechanicianWorkflow")
        XCTAssertNil(
            AgentToolCatalog.canonicalCapabilityID(for: "mcp__untrusted__Read"))
        XCTAssertNil(
            AgentToolCatalog.canonicalCapabilityID(for: "mcp__evil__SearchMechanicianHelp"))
        XCTAssertNil(
            AgentToolCatalog.canonicalCapabilityID(for: "mcp__evil__ShowMechanician"))
        XCTAssertNil(AgentToolCatalog.canonicalCapabilityID(
            for: "mcp__evil__RecommendMechanicianWorkflow"))
        XCTAssertNil(
            AgentToolCatalog.canonicalCapabilityID(for: "mcp__github__create_pull_request"))
    }

    func testExplicitReadyEmptyDiffersFromNeverReported() {
        let catalog = AgentToolCatalog()
        let identity = route()
        XCTAssertNil(catalog.snapshot(for: identity.conversationID))
        let snapshot = ready(catalog, route: identity, tools: [])
        XCTAssertEqual(snapshot.phase, .ready)
        XCTAssertEqual(snapshot.rawToolNames, [])
    }

    func testASecondConversationDoesNotOverwriteTheFirst() {
        let catalog = AgentToolCatalog()
        let bridge = UUID()
        let first = route(bridgeID: bridge, conversationID: UUID())
        let second = route(bridgeID: bridge, conversationID: UUID())
        _ = ready(catalog, route: first, tools: ["Read"])
        _ = ready(catalog, route: second, tools: ["SearchMechanicianHelp"])
        XCTAssertEqual(catalog.snapshot(for: first.conversationID)?.rawToolNames, ["Read"])
        XCTAssertEqual(
            catalog.snapshot(for: second.conversationID)?.rawToolNames,
            ["SearchMechanicianHelp"])
    }

    func testTwoWindowCatalogsAreIsolated() {
        let conversation = UUID()
        let firstCatalog = AgentToolCatalog()
        let secondCatalog = AgentToolCatalog()
        let first = route(bridgeID: UUID(), conversationID: conversation)
        let second = route(bridgeID: UUID(), conversationID: conversation)
        _ = ready(firstCatalog, route: first, tools: ["Read"])
        _ = ready(secondCatalog, route: second, tools: ["Bash"])
        XCTAssertEqual(firstCatalog.snapshot(for: conversation)?.rawToolNames, ["Read"])
        XCTAssertEqual(secondCatalog.snapshot(for: conversation)?.rawToolNames, ["Bash"])
    }

    func testLatePriorTurnCannotPublishOverNewRoute() {
        let catalog = AgentToolCatalog()
        let conversation = UUID()
        let prior = route(conversationID: conversation, turnID: "prior")
        let current = route(conversationID: conversation, turnID: "current")
        catalog.begin(route: prior)
        catalog.begin(route: current)
        XCTAssertFalse(catalog.publish(
            tools: ["Read"], coverage: .complete, provenance: .providerInit,
            adapterRevision: AgentToolCatalog.adapterRevision, for: prior))
        XCTAssertEqual(catalog.snapshot(for: conversation)?.route, current)
        XCTAssertEqual(catalog.snapshot(for: conversation)?.phase, .discovering)
    }

    func testEveryRouteIdentityBoundaryRejectsStalePublication() {
        let catalog = AgentToolCatalog()
        let current = route()
        catalog.begin(route: current)
        let variants = [
            route(bridgeID: UUID(), conversationID: current.conversationID),
            route(runtimeGeneration: UUID(), conversationID: current.conversationID),
            route(conversationID: current.conversationID, turnID: "other"),
            route(conversationID: current.conversationID, access: .openAIAPI),
            route(conversationID: current.conversationID, modelID: "other"),
            route(conversationID: current.conversationID, accountInstanceID: ProviderAccountInstanceID()),
            route(conversationID: current.conversationID, credentialEpoch: 2),
            route(conversationID: current.conversationID, providerRouteIdentity: "other-route"),
            route(conversationID: current.conversationID, workspaceIdentity: "project:other"),
            route(conversationID: current.conversationID, canonicalCWD: "/tmp/other-workspace"),
            route(conversationID: current.conversationID, toolProfile: .helpExpert),
            route(conversationID: current.conversationID, permissionMode: "plan"),
            route(conversationID: current.conversationID, providerSessionRevision: UUID()),
            route(
                conversationID: current.conversationID,
                workspaceInstructionsRevision: "other-instructions"),
        ]
        for stale in variants {
            XCTAssertFalse(catalog.publish(
                tools: ["Read"], coverage: .complete, provenance: .providerInit,
                adapterRevision: AgentToolCatalog.adapterRevision, for: stale))
        }
    }

    func testWorkflowReadinessKeepsPartialMissingDistinctFromUnavailable() {
        let catalog = AgentToolCatalog()
        let complete = ready(catalog, route: route(), tools: ["Read"])
        XCTAssertEqual(
            catalog.readiness(
                requiring: ["RunCapability"], requiresExecutionMode: true, snapshot: complete),
            .unavailableHere)

        let partial = ready(
            catalog,
            route: route(access: .codexSubscription),
            tools: ["SearchMechanicianHelp"],
            coverage: .mechanicianSupplied)
        XCTAssertEqual(
            catalog.readiness(
                requiring: ["Bash"], requiresExecutionMode: true, snapshot: partial),
            .notVerified)
    }

    func testWorkflowReadinessRequiresARealStandardProfileRequirement() {
        let catalog = AgentToolCatalog()
        let standard = ready(catalog, route: route(), tools: ["Read"])
        XCTAssertEqual(
            catalog.readiness(
                requiring: [], requiresExecutionMode: false, snapshot: standard),
            .notVerified,
            "an empty requirement set must not prove every workflow ready")

        // One closed profile remains. The loop that used to run two is not worth keeping for it.
        let closed = ready(
            catalog,
            route: route(toolProfile: .helpExpert),
            tools: ["mcp__help__SearchMechanicianHelp"])
        XCTAssertEqual(
            catalog.readiness(
                requiring: ["SearchMechanicianHelp"],
                requiresExecutionMode: false,
                snapshot: closed),
            .unavailableHere)
    }

    func testTotalRetainedAndCompleteWirePayloadsAreBounded() {
        let catalog = AgentToolCatalog()
        let identity = route()
        catalog.begin(route: identity)
        let individuallyValidButOversized = (0..<140).map { index in
            "tool-\(index)-" + String(repeating: "x", count: 490)
        }
        XCTAssertTrue(individuallyValidButOversized.allSatisfy {
            $0.lengthOfBytes(using: .utf8) <= AgentToolCatalog.maximumToolNameBytes
        })
        XCTAssertFalse(catalog.publish(
            tools: individuallyValidButOversized,
            coverage: .complete,
            provenance: .providerInit,
            adapterRevision: AgentToolCatalog.adapterRevision,
            for: identity))

        let validEvent: [String: Any] = [
            "type": "tool_surface",
            "id": "turn", "lane": "claude", "toolProfile": "standard",
            "permissionMode": "default", "coverage": "complete",
            "provenance": "provider-init",
            "adapterRevision": AgentToolCatalog.adapterRevision,
            "tools": ["Read"],
        ]
        XCTAssertTrue(AgentToolCatalog.wirePayloadIsWithinBounds(validEvent))
        XCTAssertTrue(AgentToolCatalog.wireShapeIsAdmissible(validEvent))
        let decode: ([String: Any]) -> AgentToolCatalog.WireReport? = { event in
            AgentToolCatalog.decodeWireReport(
                event,
                expectedTurnID: "turn",
                expectedLane: "claude",
                expectedToolProfile: .standard,
                expectedPermissionMode: "default",
                expectedCoverage: .complete,
                expectedProvenance: .providerInit)
        }
        XCTAssertEqual(
            decode(validEvent),
            .init(tools: ["Read"], coverage: .complete, provenance: .providerInit))
        var forgedRouteEvent = validEvent
        forgedRouteEvent["conversationID"] = UUID().uuidString
        XCTAssertFalse(AgentToolCatalog.wireShapeIsAdmissible(forgedRouteEvent))
        XCTAssertNil(decode(forgedRouteEvent))
        for (field, value) in [
            ("type", "other"), ("id", "other-turn"), ("lane", "openai"),
            ("toolProfile", "help-expert"), ("permissionMode", "plan"),
            ("coverage", "mechanician-supplied"),
            ("provenance", "mechanician-api-request"),
            ("adapterRevision", "future-revision"),
        ] {
            var mismatch = validEvent
            mismatch[field] = value
            XCTAssertNil(decode(mismatch), "mismatched \(field) must fail closed")
        }
        var oversizedEvent = validEvent
        oversizedEvent["ignoredFutureField"] = String(
            repeating: "x", count: AgentToolCatalog.maximumWirePayloadBytes)
        XCTAssertFalse(AgentToolCatalog.wirePayloadIsWithinBounds(oversizedEvent))
    }

    func testMalformedExactToolNamesFailClosedWithoutNormalization() {
        for malformed in [" Read", "Read ", "Read\nWrite", "Read\u{7F}Write"] {
            let catalog = AgentToolCatalog()
            let identity = route()
            catalog.begin(route: identity)
            XCTAssertFalse(catalog.publish(
                tools: [malformed],
                coverage: .complete,
                provenance: .providerInit,
                adapterRevision: AgentToolCatalog.adapterRevision,
                for: identity))
            XCTAssertEqual(
                catalog.snapshot(for: identity.conversationID)?.phase,
                .discovering,
                "invalid names must not be trimmed or retained as authority")
        }

        let duplicateCatalog = AgentToolCatalog()
        let duplicateIdentity = route()
        duplicateCatalog.begin(route: duplicateIdentity)
        XCTAssertFalse(duplicateCatalog.publish(
            tools: ["Read", "Read"],
            coverage: .complete,
            provenance: .providerInit,
            adapterRevision: AgentToolCatalog.adapterRevision,
            for: duplicateIdentity))
    }

    func testBridgeDecodesTheCompleteWireEventBeforeSurfaceAdmission() throws {
        let body = try bridgeBody(
            bridgeSource(),
            from: "private func applyAgentToolSurface(",
            until: "var currentAgentToolSurfaceSnapshot:")
        XCTAssertTrue(body.contains("AgentToolCatalog.decodeWireReport("))
    }

    func testRuntimeAndAccessInvalidationRemoveOnlyOwnedEvidence() {
        let catalog = AgentToolCatalog()
        let retiredGeneration = UUID()
        let survivingGeneration = UUID()
        let retired = route(
            runtimeGeneration: retiredGeneration,
            conversationID: UUID(),
            access: .anthropicAPI)
        let sameAccessOtherGeneration = route(
            runtimeGeneration: survivingGeneration,
            conversationID: UUID(),
            access: .anthropicAPI)
        let otherAccess = route(
            runtimeGeneration: retiredGeneration,
            conversationID: UUID(),
            access: .openAIAPI)
        _ = ready(catalog, route: retired, tools: ["Read"])
        _ = ready(catalog, route: sameAccessOtherGeneration, tools: ["Read"])
        _ = ready(catalog, route: otherAccess, tools: ["Read"])

        catalog.invalidate(access: .anthropicAPI, generation: retiredGeneration)
        XCTAssertNil(catalog.snapshot(for: retired.conversationID))
        XCTAssertNotNil(catalog.snapshot(for: sameAccessOtherGeneration.conversationID))
        XCTAssertNotNil(catalog.snapshot(for: otherAccess.conversationID))

        catalog.invalidate(access: .anthropicAPI)
        XCTAssertNil(catalog.snapshot(for: sameAccessOtherGeneration.conversationID))
        XCTAssertNotNil(catalog.snapshot(for: otherAccess.conversationID))
    }

    func testBridgeInvalidatesEvidenceAtRuntimeAndAccountRetirementEdges() throws {
        let source = try bridgeSource()
        for (start, end) in [
            ("private static func requireAccountReconnect(",
             "private static func reportBlockedQueuedWorkProcessWide("),
            ("private func handleDaemonLaunchFailure(", "private func restartRuntime("),
            ("private func restartRuntime(", "private func beginUnacknowledgedStopRetirement("),
            ("private func beginUnacknowledgedStopRetirement(",
             "private func handleDaemonExit("),
            ("private func handleDaemonExit(", "private func queuedConversations("),
        ] {
            XCTAssertTrue(
                try bridgeBody(source, from: start, until: end).contains(
                    "agentToolCatalog.invalidate(access: access"),
                "\(start) must retire exact-route capability evidence")
        }

        let ready = try bridgeBody(
            source, from: "private func recordReady(", until: "private func cacheCodexModels(")
        XCTAssertGreaterThanOrEqual(
            ready.components(separatedBy: "agentToolCatalog.invalidate(access: access)").count - 1,
            2,
            "account-owner adoption and logged-out readiness must both invalidate evidence")
    }

    func testMissingTerminalReportUsesLocalizedFailureText() throws {
        let catalog = AgentToolCatalog()
        let identity = route()
        catalog.begin(route: identity)
        catalog.finish(route: identity)
        XCTAssertEqual(
            catalog.snapshot(for: identity.conversationID)?.phase,
            .failed(String(
                localized: "The provider finished without reporting its callable tools.")))

        let source = try catalogSource()
        let finish = try bridgeBody(
            source, from: "func finish(route:", until: "func snapshot(for conversationID:")
        XCTAssertTrue(finish.contains("current.phase = .failed(String("))
        XCTAssertTrue(finish.contains("localized:"))
    }

    func testWorkflowReadinessSeparatesPresenceFromPermissionMode() {
        let catalog = AgentToolCatalog()
        let plan = ready(
            catalog,
            route: route(permissionMode: "plan"),
            tools: ["mcp__capabilities__RunCapability"])
        XCTAssertEqual(
            catalog.readiness(
                requiring: ["RunCapability"], requiresExecutionMode: true, snapshot: plan),
            .needsModeChange)
        XCTAssertEqual(
            catalog.readiness(
                requiring: ["RunCapability"], requiresExecutionMode: false, snapshot: plan),
            .ready(mayRequestApproval: true))
    }

    func testDefaultHelpProfileProjectsOnlyItsSignedAndBoundedProductTools() {
        let catalog = AgentToolCatalog()
        let snapshot = ready(
            catalog,
            route: route(toolProfile: .helpExpert),
            tools: [
                "mcp__help__SearchMechanicianHelp",
                "mcp__help__ShowMechanician",
                "mcp__help__OperateMechanician",
            ])
        XCTAssertEqual(AgentToolCatalog.groups(for: snapshot).map(\.id), ["help"])
        XCTAssertTrue(AgentToolCatalog.ungroupedTools(in: snapshot).isEmpty)
    }

    func testTurnScopedContractIncludesToolSurfaceAndRejectsLegacyCatalogAuthority() throws {
        XCTAssertTrue(AgentBridge.turnScopedEventTypes.contains("tool_surface"))
        let source = try bridgeSource()
        XCTAssertFalse(source.contains("AgentToolCatalog.shared"))
        let legacy = try bridgeBody(
            source,
            from: "case \"tool_catalog\":",
            until: "case \"claude_plugins_result\":")
        XCTAssertTrue(legacy.contains("break"))
        XCTAssertFalse(legacy.contains("update("))
    }
}
