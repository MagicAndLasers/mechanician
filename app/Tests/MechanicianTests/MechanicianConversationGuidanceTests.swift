import AppKit
import XCTest
@testable import Mechanician

/// The agent-directed guides that leave Help.
///
/// The Memory tour proved one reserved destination. These cover the ordinary conversation window,
/// which is what "show me the Changes panel" actually means: the surface is presented where the
/// person is already working, no workspace is created, and a tab the guide had to reveal is put
/// back when it ends.
@MainActor
final class MechanicianConversationGuidanceTests: XCTestCase {
    private struct OwnedWindowFixture {
        let bridge: AgentBridge
        let window: NSWindow
        let support: URL
        let conversationID: UUID

        @MainActor
        func cleanUp() {
            bridge.window = nil
            bridge.shutdown()
            ConversationStore.shared.remove(conversationID, permanently: true)
            window.orderOut(nil)
            window.contentView = nil
            try? FileManager.default.removeItem(at: support)
        }
    }

    private let metadata = MechanicianHelpMetadata(
        schemaVersion: 4,
        corpusID: "mechanician.public",
        applicationVersion: "9.9.9",
        applicationBuild: "999",
        bundleIdentifier: "ai.mechanician.tests",
        tenantID: "default",
        sourceCommit: "source",
        sourceDiffSHA256: String(repeating: "b", count: 64),
        contentSHA256: String(repeating: "a", count: 64))

    private func ownedWindow(
        projectID: UUID? = nil,
        cwd: String = "",
        name: String = #function
    ) -> OwnedWindowFixture {
        _ = NSApplication.shared
        let support = FileManager.default.temporaryDirectory
            .appendingPathComponent("conversation-guidance-\(name)-\(UUID().uuidString)",
                                  isDirectory: true)
        let bridge = AgentBridge(settingsBaseOverride: support, environmentOverride: [:])
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 640),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false)
        window.contentView = NSView(frame: NSRect(x: 0, y: 0, width: 900, height: 640))
        bridge.window = window
        bridge.projectID = projectID
        bridge.cwd = cwd
        let conversation = Conversation(
            title: "Conversation guidance fixture",
            cwd: cwd,
            sdkSessionId: nil,
            messages: [],
            updatedAt: Date(),
            draft: "retained test fixture",
            projectID: projectID)
        ConversationStore.shared.upsert(conversation)
        bridge.currentID = conversation.id
        return OwnedWindowFixture(
            bridge: bridge,
            window: window,
            support: support,
            conversationID: conversation.id)
    }

    private func admission(
        for fixture: OwnedWindowFixture,
        profile: ProviderToolProfile = .standard,
        guideID: String
    ) -> MechanicianGuidanceSourceAdmission {
        MechanicianGuidanceSourceAdmission(
            bridge: fixture.bridge,
            window: fixture.window,
            conversationID: fixture.bridge.currentID!,
            toolProfile: profile,
            guideID: guideID,
            corpusContentSHA256: metadata.contentSHA256,
            revalidateTurn: { true })!
    }

    private func step(
        _ target: MechanicianHelpGuideTarget,
        _ revealAction: MechanicianHelpGuideRevealAction,
        ordinal: Int,
        completion: MechanicianHelpGuideCompletion = .userAdvance
    ) -> MechanicianHelpGuideStep {
        MechanicianHelpGuideStep(
            id: "step-\(ordinal)-\(target.rawValue)",
            title: "Step \(ordinal)",
            instruction: "Look at the highlighted control.",
            target: target,
            revealAction: revealAction,
            completion: completion,
            ordinal: ordinal)
    }

    private func conversationGuide(
        id: String = "inspector.changes-tour",
        articleID: String = "inspector",
        surface: MechanicianHelpGuideSurface = .conversationWorkspace,
        lifecycle: MechanicianHelpLifecycle = .current,
        steps: [MechanicianHelpGuideStep]? = nil
    ) -> MechanicianHelpGuide {
        MechanicianHelpGuide(
            id: id,
            articleID: articleID,
            title: "Show the Changes panel",
            summary: "Show the Changes tab in this conversation's own window.",
            surface: surface,
            lifecycle: lifecycle,
            ordinal: 0,
            claimKeys: ["inspector.changes"],
            steps: steps ?? [step(.conversationChangesTab, .showChangesInspector, ordinal: 0)],
            evidence: [])
    }

    private func router(
        source: MechanicianHelpGuidanceSource?,
        destination: OwnedWindowFixture?,
        resolverCalls: ResolverCounter = ResolverCounter(),
        attempts: Int = 40
    ) -> MechanicianGuidanceRouter {
        MechanicianGuidanceRouter(
            loadGuide: { _ in source },
            productAccessAllowed: { true },
            routeWorkspace: { _ in
                XCTFail("a conversation guide must never route to another workspace")
                return nil
            },
            resolveConversationWorkspace: { _ in
                resolverCalls.count += 1
                return destination?.bridge
            },
            targetIsReady: { bridge, window in
                bridge === destination?.bridge && window === destination?.window
            },
            monotonicNow: { ProcessInfo.processInfo.systemUptime },
            requestTimeout: 12,
            targetRegistrationAttempts: attempts,
            targetRegistrationDelayNanoseconds: 0)
    }

    final class ResolverCounter {
        var count = 0
    }

    private func registerTargets(
        _ targets: [GuidedHelpPresentationTarget],
        in registry: GuidedHelpTargetRegistry,
        window: NSWindow
    ) {
        guard let content = window.contentView else { return }
        for (index, target) in targets.enumerated() {
            let view = NSView(frame: NSRect(
                x: 40 + CGFloat(index) * 90,
                y: 500,
                width: 80,
                height: 30))
            content.addSubview(view)
            XCTAssertTrue(registry.register(target, view: view))
        }
    }

    private func startAndRegister(
        router: MechanicianGuidanceRouter,
        source: MechanicianGuidanceSourceAdmission,
        destination: OwnedWindowFixture,
        guideID: String,
        targets: [GuidedHelpPresentationTarget]
    ) async -> MechanicianGuidanceStartResult {
        let priorCoordinator = router.targetCoordinator
        let task = Task { await router.start(guideID: guideID, source: source) }
        for _ in 0..<100 {
            if router.targetCoordinator !== priorCoordinator,
               let registry = router.registry(for: destination.bridge) {
                registerTargets(targets, in: registry, window: destination.window)
                break
            }
            await Task.yield()
        }
        return await task.value
    }

    private func restoreDefault(_ key: String, to value: Any?) {
        if let value {
            UserDefaults.standard.set(value, forKey: key)
        } else {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }

    // MARK: - Signed admission

    func testAgentAdmissionAcceptsConversationStepsAndRejectsMismatchedRevealActions() {
        XCTAssertTrue(MechanicianGuidanceRouter.isAdmissibleAgentGuide(conversationGuide()))
        XCTAssertTrue(MechanicianGuidanceRouter.isAdmissibleAgentGuide(conversationGuide(steps: [
            step(.conversationModelControl, .showConversationControls, ordinal: 0),
            step(.conversationEffortControl, .showConversationControls, ordinal: 1),
            step(.conversationPermissionControl, .showConversationControls, ordinal: 2),
            step(.conversationComposer, .showConversationControls, ordinal: 3),
        ])))

        // A Help-local tour is still manual, so it is never admitted through the agent path.
        XCTAssertFalse(MechanicianGuidanceRouter.isAdmissibleAgentGuide(
            conversationGuide(surface: .helpWorkspaceInspector)))
        XCTAssertFalse(MechanicianGuidanceRouter.isAdmissibleAgentGuide(
            conversationGuide(lifecycle: .historical)))
        // Reveal actions and targets must agree: revealing Agents cannot spotlight Changes.
        XCTAssertFalse(MechanicianGuidanceRouter.isAdmissibleAgentGuide(conversationGuide(steps: [
            step(.conversationChangesTab, .showAgentsInspector, ordinal: 0),
        ])))
        // A Help-reader target cannot be smuggled onto a conversation guide.
        XCTAssertFalse(MechanicianGuidanceRouter.isAdmissibleAgentGuide(conversationGuide(steps: [
            step(.helpTopics, .showHelpTopics, ordinal: 0),
        ])))
        XCTAssertFalse(MechanicianGuidanceRouter.isAdmissibleAgentGuide(conversationGuide(steps: [
            step(.conversationChangesTab, .showChangesInspector, ordinal: 0,
                 completion: .targetActivated),
        ])))
        XCTAssertTrue(MechanicianHelpGuideSurface.conversationWorkspace.isAgentCallable)
        XCTAssertFalse(MechanicianHelpGuideSurface.helpWorkspaceInspector.isAgentCallable)
    }

    func testEveryConversationTargetResolvesToTheTabItNames() {
        XCTAssertEqual(
            MechanicianGuidanceRouter.inspectorTab(for: .conversationChangesTab), .changes)
        XCTAssertEqual(MechanicianGuidanceRouter.inspectorTab(for: .conversationFilesTab), .files)
        XCTAssertEqual(
            MechanicianGuidanceRouter.inspectorTab(for: .conversationArtifactsTab), .artifacts)
        XCTAssertEqual(MechanicianGuidanceRouter.inspectorTab(for: .conversationAgentsTab), .agents)
        XCTAssertEqual(MechanicianGuidanceRouter.inspectorTab(for: .conversationSkillsTab), .skills)
        // Composer controls belong to no tab, so a guide about them must not open the inspector.
        for target in [
            GuidedHelpPresentationTarget.conversationModelControl,
            .conversationEffortControl,
            .conversationPermissionControl,
            .conversationComposer,
        ] {
            XCTAssertNil(MechanicianGuidanceRouter.inspectorTab(for: target))
        }
    }

    // MARK: - Destination

    func testReservedWorkspacesAreNeverAConversationDestination() {
        let ordinary = ownedWindow()
        let memory = ownedWindow(projectID: HelpWorkspace.id)
        let help = ownedWindow(projectID: HelpWorkspace.id)
        defer {
            ordinary.cleanUp()
            memory.cleanUp()
            help.cleanUp()
        }
        XCTAssertTrue(
            MechanicianGuidanceRouter.conversationDestinationIsEligible(ordinary.bridge))
        XCTAssertFalse(MechanicianGuidanceRouter.conversationDestinationIsEligible(memory.bridge))
        XCTAssertFalse(MechanicianGuidanceRouter.conversationDestinationIsEligible(help.bridge))

        ordinary.bridge.window = nil
        XCTAssertFalse(
            MechanicianGuidanceRouter.conversationDestinationIsEligible(ordinary.bridge))
    }

    func testConversationGuidePresentsInTheAskingWindowWithoutResolvingAnother() async {
        let tabKey = InspectorTabPreference.key(nil)
        let panelKey = "panel.inspector"
        let priorTabs = UserDefaults.standard.object(forKey: tabKey)
        let priorPanel = UserDefaults.standard.object(forKey: panelKey)
        defer {
            restoreDefault(tabKey, to: priorTabs)
            restoreDefault(panelKey, to: priorPanel)
        }
        UserDefaults.standard.removeObject(forKey: tabKey)

        let fixture = ownedWindow()
        defer { fixture.cleanUp() }
        fixture.bridge.inspectorTab = .artifacts
        fixture.bridge.showInspector = false
        UserDefaults.standard.set(false, forKey: panelKey)

        let counter = ResolverCounter()
        let signed = MechanicianHelpGuidanceSource(guide: conversationGuide(), metadata: metadata)
        let subject = router(source: signed, destination: fixture, resolverCalls: counter)
        let result = await startAndRegister(
            router: subject,
            source: admission(for: fixture, guideID: "inspector.changes-tour"),
            destination: fixture,
            guideID: "inspector.changes-tour",
            targets: [.conversationChangesTab])
        guard case .started = result else { return XCTFail("expected started, got \(result)") }

        // The resolver is consulted, and the window it returns is the one that asked.
        XCTAssertEqual(counter.count, 1)
        XCTAssertNotNil(subject.registry(for: fixture.bridge))
        XCTAssertEqual(subject.forcedInspectorTab(for: fixture.bridge), .changes)
        XCTAssertTrue(fixture.bridge.showInspector)
        XCTAssertEqual(fixture.bridge.inspectorTab, .changes)
        // Presentation only: the person's stored tab set is untouched.
        XCTAssertNil(UserDefaults.standard.stringArray(forKey: tabKey))
        XCTAssertFalse(UserDefaults.standard.bool(forKey: panelKey))

        subject.targetCoordinator?.advance()
        XCTAssertNil(subject.targetCoordinator)
        XCTAssertTrue(subject.forcedInspectorTabs(for: fixture.bridge).isEmpty)
        XCTAssertFalse(fixture.bridge.showInspector)
        XCTAssertEqual(fixture.bridge.inspectorTab, .artifacts)
        XCTAssertFalse(UserDefaults.standard.bool(forKey: panelKey))
    }

    func testHelpWorkspaceSourceCrossesIntoTheResolvedConversationWindow() async {
        let helpFixture = ownedWindow(projectID: HelpWorkspace.id)
        let destination = ownedWindow()
        defer {
            helpFixture.cleanUp()
            destination.cleanUp()
        }
        destination.bridge.inspectorTab = .artifacts
        let helpTabBeforeGuide = helpFixture.bridge.inspectorTab
        let helpInspectorVisibleBeforeGuide = helpFixture.bridge.showInspector

        let signed = MechanicianHelpGuidanceSource(
            guide: conversationGuide(
                id: "inspector.agents-tour",
                steps: [step(.conversationAgentsTab, .showAgentsInspector, ordinal: 0)]),
            metadata: metadata)
        let subject = router(source: signed, destination: destination)
        let result = await startAndRegister(
            router: subject,
            source: admission(
                for: helpFixture,
                profile: .helpExpert,
                guideID: "inspector.agents-tour"),
            destination: destination,
            guideID: "inspector.agents-tour",
            targets: [.conversationAgentsTab])
        guard case .started = result else { return XCTFail("expected started, got \(result)") }

        XCTAssertNotNil(subject.registry(for: destination.bridge))
        XCTAssertNil(subject.registry(for: helpFixture.bridge))
        XCTAssertEqual(subject.forcedInspectorTab(for: destination.bridge), .agents)
        XCTAssertEqual(destination.bridge.inspectorTab, .agents)
        // The Help window it was asked from is never navigated.
        XCTAssertEqual(helpFixture.bridge.inspectorTab, helpTabBeforeGuide)
        XCTAssertEqual(helpFixture.bridge.showInspector, helpInspectorVisibleBeforeGuide)
        subject.targetCoordinator?.exit()
    }

    func testNoEligibleConversationWindowFailsInsteadOfOpeningOne() async {
        let helpFixture = ownedWindow(projectID: HelpWorkspace.id)
        defer { helpFixture.cleanUp() }
        let signed = MechanicianHelpGuidanceSource(guide: conversationGuide(), metadata: metadata)
        let subject = router(source: signed, destination: nil)

        let result = await subject.start(
            guideID: "inspector.changes-tour",
            source: admission(
                for: helpFixture,
                profile: .helpExpert,
                guideID: "inspector.changes-tour"))
        XCTAssertEqual(result, .failed(.destinationUnavailable))
        XCTAssertNil(subject.targetCoordinator)
    }

    // MARK: - Tab visibility

    func testForcedTabsRevealHiddenTabsAndStillRefuseFolderTabsWithoutAFolder() {
        XCTAssertEqual(
            MechanicianGuidanceInspectorTabs.visible(
                stored: [.artifacts, .agents],
                forced: [.changes],
                allowsFolderTabs: true),
            [.changes, .artifacts, .agents])
        // Files and Changes run git in the workspace folder. A folderless workspace has none, so
        // the guide fails visibly instead of spotlighting a panel with no repository behind it.
        XCTAssertEqual(
            MechanicianGuidanceInspectorTabs.visible(
                stored: [.artifacts, .agents],
                forced: [.changes],
                allowsFolderTabs: false),
            [.artifacts, .agents])
        XCTAssertEqual(
            MechanicianGuidanceInspectorTabs.visible(
                stored: [.artifacts],
                forced: [.skills, .changes],
                allowsFolderTabs: false),
            [.artifacts, .skills])
        XCTAssertEqual(
            MechanicianGuidanceInspectorTabs.visible(
                stored: [.artifacts, .agents],
                forced: [],
                allowsFolderTabs: true),
            [.artifacts, .agents])
        XCTAssertEqual(
            MechanicianGuidanceInspectorTabs.visible(
                stored: [.artifacts, .agents],
                forced: [.agents],
                allowsFolderTabs: true),
            [.artifacts, .agents])
    }

    func testDoneLeavesAnAlreadyVisibleTabAndPutsAForcedTabBack() {
        let tabKey = InspectorTabPreference.key(nil)
        let panelKey = "panel.inspector"
        let priorTabs = UserDefaults.standard.object(forKey: tabKey)
        let priorPanel = UserDefaults.standard.object(forKey: panelKey)
        defer {
            restoreDefault(tabKey, to: priorTabs)
            restoreDefault(panelKey, to: priorPanel)
        }
        let fixture = ownedWindow()
        defer { fixture.cleanUp() }

        // Agents is in the folderless default set, so Done may leave it selected.
        UserDefaults.standard.removeObject(forKey: tabKey)
        fixture.bridge.inspectorTab = .artifacts
        fixture.bridge.showInspector = false
        UserDefaults.standard.set(true, forKey: panelKey)
        let visible = ConversationGuidanceNavigationSnapshot(bridge: fixture.bridge)
        visible.reveal(tab: .agents)
        XCTAssertTrue(visible.leavesRevealedTabInPlace)
        XCTAssertTrue(UserDefaults.standard.bool(forKey: panelKey))

        // Skills hidden by this workspace's own choice: the guide reveals it, then puts it back.
        UserDefaults.standard.set(["artifacts"], forKey: tabKey)
        fixture.bridge.inspectorTab = .artifacts
        fixture.bridge.showInspector = false
        let forced = ConversationGuidanceNavigationSnapshot(bridge: fixture.bridge)
        forced.reveal(tab: .skills)
        XCTAssertFalse(forced.leavesRevealedTabInPlace)
        XCTAssertTrue(fixture.bridge.showInspector)
        XCTAssertEqual(fixture.bridge.inspectorTab, .skills)
        forced.restoreIfUnchanged()
        XCTAssertFalse(fixture.bridge.showInspector)
        XCTAssertEqual(fixture.bridge.inspectorTab, .artifacts)
        XCTAssertEqual(UserDefaults.standard.stringArray(forKey: tabKey), ["artifacts"])
    }

    func testAComposerOnlyGuideNeverOpensOrRestoresTheInspector() async {
        let panelKey = "panel.inspector"
        let priorPanel = UserDefaults.standard.object(forKey: panelKey)
        defer { restoreDefault(panelKey, to: priorPanel) }

        let fixture = ownedWindow()
        defer { fixture.cleanUp() }
        fixture.bridge.inspectorTab = .artifacts
        fixture.bridge.showInspector = false
        UserDefaults.standard.set(false, forKey: panelKey)

        let signed = MechanicianHelpGuidanceSource(
            guide: conversationGuide(
                id: "composer.controls-tour",
                articleID: "composer",
                steps: [
                    step(.conversationModelControl, .showConversationControls, ordinal: 0),
                    step(.conversationComposer, .showConversationControls, ordinal: 1),
                ]),
            metadata: metadata)
        let subject = router(source: signed, destination: fixture)
        let result = await startAndRegister(
            router: subject,
            source: admission(for: fixture, guideID: "composer.controls-tour"),
            destination: fixture,
            guideID: "composer.controls-tour",
            targets: [.conversationModelControl, .conversationComposer])
        guard case .started = result else { return XCTFail("expected started, got \(result)") }

        XCTAssertTrue(subject.forcedInspectorTabs(for: fixture.bridge).isEmpty)
        XCTAssertNil(subject.forcedInspectorTab(for: fixture.bridge))
        XCTAssertFalse(fixture.bridge.showInspector)
        XCTAssertEqual(fixture.bridge.inspectorTab, .artifacts)

        subject.targetCoordinator?.advance()
        subject.targetCoordinator?.advance()
        XCTAssertNil(subject.targetCoordinator)
        XCTAssertFalse(fixture.bridge.showInspector)
        XCTAssertEqual(fixture.bridge.inspectorTab, .artifacts)
        XCTAssertFalse(UserDefaults.standard.bool(forKey: panelKey))
    }

    func testEveryStepOfAMultiTabGuideKeepsItsOwnTabsRegistered() async {
        let tabKey = InspectorTabPreference.key(nil)
        let priorTabs = UserDefaults.standard.object(forKey: tabKey)
        defer { restoreDefault(tabKey, to: priorTabs) }
        UserDefaults.standard.removeObject(forKey: tabKey)

        let fixture = ownedWindow()
        defer { fixture.cleanUp() }
        fixture.bridge.inspectorTab = .artifacts

        let signed = MechanicianHelpGuidanceSource(
            guide: conversationGuide(
                id: "inspector.skills-tour",
                steps: [
                    step(.conversationSkillsTab, .showSkillsInspector, ordinal: 0),
                    step(.conversationComposer, .showConversationControls, ordinal: 1),
                ]),
            metadata: metadata)
        let subject = router(source: signed, destination: fixture)
        let result = await startAndRegister(
            router: subject,
            source: admission(for: fixture, guideID: "inspector.skills-tour"),
            destination: fixture,
            guideID: "inspector.skills-tour",
            targets: [.conversationSkillsTab, .conversationComposer])
        guard case .started = result else { return XCTFail("expected started, got \(result)") }

        XCTAssertEqual(subject.forcedInspectorTabs(for: fixture.bridge), [.skills])
        XCTAssertEqual(subject.forcedInspectorTab(for: fixture.bridge), .skills)
        XCTAssertEqual(fixture.bridge.inspectorTab, .skills)

        // Advancing to the composer step keeps Skills in the forced set, so the tab the guide
        // revealed cannot vanish from the bar underneath the person mid-guide.
        subject.targetCoordinator?.advance()
        XCTAssertEqual(subject.forcedInspectorTabs(for: fixture.bridge), [.skills])
        XCTAssertNil(subject.forcedInspectorTab(for: fixture.bridge))
        subject.targetCoordinator?.exit()
        XCTAssertNil(subject.targetCoordinator)
    }
}
