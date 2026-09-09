import XCTest
@testable import Mechanician

@MainActor
final class AgentAbilityPresentationTests: XCTestCase {
    func testNoConversationHasNoResolvedRouteOrReadyInventory() {
        let presentation = reduce(hasConversation: false)

        XCTAssertEqual(presentation.state, .noConversation)
        XCTAssertFalse(presentation.showsResolvedRoute)
        XCTAssertNil(presentation.readySnapshot)
    }

    func testInitialHydrationShowsOpeningInsteadOfAnEmptyConversation() {
        let presentation = reduce(
            hasConversation: false,
            isOpeningConversation: true)

        XCTAssertEqual(presentation.state, .openingConversation)
        XCTAssertFalse(presentation.showsResolvedRoute)
        XCTAssertNil(presentation.readySnapshot)
    }

    func testRouteSwitchImmediatelyHidesThePriorReadySnapshot() {
        let prior = snapshot(phase: .ready, tools: ["Read"])

        let presentation = reduce(
            hasConversation: true,
            isOpeningConversation: true,
            snapshot: prior)

        XCTAssertEqual(presentation.state, .openingConversation)
        XCTAssertFalse(presentation.showsResolvedRoute)
        XCTAssertNil(
            presentation.readySnapshot,
            "A pending destination is newer authority than the prior Conversation's tools")
    }

    func testProviderSetupTakesPrecedenceOverAPreviouslyObservedSnapshot() {
        let observed = snapshot(phase: .ready, tools: ["Read"])

        let presentation = reduce(
            needsProviderSetup: true,
            providerDisplayName: "OpenAI API",
            snapshot: observed)

        XCTAssertEqual(
            presentation.state,
            .setupRequired(providerDisplayName: "OpenAI API"))
        XCTAssertTrue(presentation.showsResolvedRoute)
        XCTAssertNil(presentation.readySnapshot)
    }

    func testDiscoveringNamesTheExactProviderAndExposesNoToolsYet() {
        let discovering = snapshot(phase: .discovering)

        let presentation = reduce(
            providerDisplayName: "Claude subscription",
            snapshot: discovering)

        XCTAssertEqual(
            presentation.state,
            .discovering(providerDisplayName: "Claude subscription"))
        XCTAssertTrue(presentation.showsResolvedRoute)
        XCTAssertNil(presentation.readySnapshot)
    }

    func testReadyEmptyIsDifferentFromUnverified() throws {
        let empty = snapshot(phase: .ready, tools: [])

        let presentation = reduce(snapshot: empty)

        guard case .readyEmpty(let admitted) = presentation.state else {
            return XCTFail("An explicit empty report must be a ready state")
        }
        XCTAssertEqual(admitted, empty)
        XCTAssertEqual(try XCTUnwrap(presentation.readySnapshot), empty)
    }

    func testReadyCarriesOnlyTheAdmittedSnapshot() throws {
        let ready = snapshot(
            phase: .ready,
            tools: ["SearchMechanicianHelp", "ListCapabilities"])

        let presentation = reduce(snapshot: ready)

        guard case .ready(let admitted) = presentation.state else {
            return XCTFail("A nonempty ready report must render its admitted inventory")
        }
        XCTAssertEqual(admitted, ready)
        XCTAssertEqual(try XCTUnwrap(presentation.readySnapshot), ready)
    }

    func testFailedDiscoveryBecomesUnavailableWithoutSecondaryInventory() {
        let failed = snapshot(
            phase: .failed("The provider did not report its callable tools."))

        let presentation = reduce(snapshot: failed)

        XCTAssertEqual(
            presentation.state,
            .unavailable(message: "The provider did not report its callable tools."))
        XCTAssertTrue(presentation.showsResolvedRoute)
        XCTAssertNil(presentation.readySnapshot)
    }

    func testResolvedConversationWithoutAnExactSnapshotIsUnverified() {
        let presentation = reduce(snapshot: nil)

        XCTAssertEqual(presentation.state, .unverified)
        XCTAssertTrue(presentation.showsResolvedRoute)
        XCTAssertNil(presentation.readySnapshot)
    }

    func testPlanRouteMayInspectButCannotRequestSavedCapabilityRun() {
        let plan = snapshot(
            phase: .ready,
            tools: ["ListCapabilities", "RunCapability"],
            permissionMode: "plan")

        XCTAssertFalse(AgentAbilityPresentation.canRequestSavedCapabilityRun(
            reportedRun: true,
            from: plan))
        XCTAssertEqual(AgentAbilityPresentation.permissionModeTitle(for: plan), "Plan (read-only)")
    }

    func testExecutionRouteMayRequestReportedSavedCapabilityRun() {
        let execution = snapshot(
            phase: .ready,
            tools: ["ListCapabilities", "RunCapability"],
            permissionMode: "bypassPermissions")

        XCTAssertTrue(AgentAbilityPresentation.canRequestSavedCapabilityRun(
            reportedRun: true,
            from: execution))
        XCTAssertEqual(AgentAbilityPresentation.permissionModeTitle(for: execution), "Bypass permissions")
        XCTAssertFalse(AgentAbilityPresentation.canRequestSavedCapabilityRun(
            reportedRun: false,
            from: execution))
    }

    private func reduce(
        hasConversation: Bool = true,
        isOpeningConversation: Bool = false,
        needsProviderSetup: Bool = false,
        providerDisplayName: String = "Anthropic API",
        snapshot: AgentToolSurfaceSnapshot? = nil
    ) -> AgentAbilityPresentation {
        AgentAbilityPresentation.reduce(.init(
            hasConversation: hasConversation,
            isOpeningConversation: isOpeningConversation,
            needsProviderSetup: needsProviderSetup,
            providerDisplayName: providerDisplayName,
            snapshot: snapshot))
    }

    private func snapshot(
        phase: AgentToolSurfaceSnapshot.Phase,
        tools: [String] = [],
        permissionMode: String = "default"
    ) -> AgentToolSurfaceSnapshot {
        AgentToolSurfaceSnapshot(
            route: AgentToolSurfaceRoute(
                bridgeID: UUID(),
                runtimeGeneration: UUID(),
                conversationID: UUID(),
                turnID: UUID().uuidString,
                selection: ModelSelection(access: .anthropicAPI, modelID: "model"),
                accountInstanceID: ProviderAccountInstanceID(),
                credentialEpoch: 1,
                providerRouteIdentity: "anthropic:apikey:builtin",
                workspaceIdentity: "home",
                canonicalCWD: "/private/tmp/mechanician-abilities",
                toolProfile: .standard,
                permissionMode: permissionMode,
                providerSessionRevision: UUID(),
                workspaceInstructionsRevision: "workspace-v1"),
            phase: phase,
            rawToolNames: tools,
            coverage: .complete,
            provenance: .providerInit,
            adapterRevision: AgentToolCatalog.adapterRevision,
            updatedAt: Date(timeIntervalSinceReferenceDate: 100),
            isActiveEvidence: true)
    }
}
