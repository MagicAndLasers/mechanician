import XCTest
@testable import Mechanician

final class HelpWindowTests: XCTestCase {
    func testSelectedSidebarIconInheritsTheNativeSelectionForeground() {
        XCTAssertEqual(
            helpSidebarIconForegroundPolicy(isSelected: true),
            .inherited)
        XCTAssertEqual(
            helpSidebarIconForegroundPolicy(isSelected: false),
            .info)
    }

    func testArticleIdentifierCannotCollideWithLiveInventorySelection() {
        XCTAssertNotEqual(
            HelpSelection.article("what-it-can-do"),
            HelpSelection.liveInventory)
        XCTAssertNotEqual(
            HelpSelection.searchResult("what-it-can-do"),
            HelpSelection.liveInventory)
    }

    func testSearchExcerptCentersTheMatchingTermAndStaysBounded() {
        let prefix = String(repeating: "Earlier context. ", count: 30)
        let body = prefix + "Scheduled tasks use read-only workspace access by default. "
            + String(repeating: "Later context. ", count: 30)

        let excerpt = HelpLibrary.excerpt(body, matching: "read-only", limit: 140)

        XCTAssertTrue(excerpt.localizedCaseInsensitiveContains("read-only"))
        XCTAssertLessThanOrEqual(excerpt.count, 142) // leading and trailing ellipses
        XCTAssertTrue(excerpt.hasPrefix("…"))
        XCTAssertTrue(excerpt.hasSuffix("…"))
    }

    func testSearchTypedBeforeCorpusReadyDoesNotOpenAnUnrelatedFirstTopic() {
        var navigation = HelpReaderNavigationState()

        navigation.queryChanged(
            wasEmpty: true,
            isEmpty: false,
            firstArticleID: nil)
        navigation.corpusBecameReady(
            firstArticleID: "getting-started",
            queryIsEmpty: false)

        XCTAssertNil(navigation.selection)

        navigation.reconcileSearch(
            .results(["claim-inspector"]),
            queryIsEmpty: false)
        XCTAssertEqual(navigation.selection, .searchResult("claim-inspector"))

        navigation.corpusBecameReady(
            firstArticleID: "getting-started",
            queryIsEmpty: false)
        XCTAssertEqual(navigation.selection, .searchResult("claim-inspector"))
    }

    func testCompactSearchKeepsTheResultListUntilThePersonChoosesAHit() {
        var navigation = HelpReaderNavigationState(selection: .article("workspaces"))
        navigation.queryChanged(
            wasEmpty: true,
            isEmpty: false,
            firstArticleID: "getting-started")

        navigation.reconcileSearch(
            .results(["claim-one", "claim-two"]),
            queryIsEmpty: false,
            automaticallySelectFirstResult: false)
        XCTAssertNil(navigation.selection)

        navigation.select(.searchResult("claim-two"))
        XCTAssertEqual(navigation.selection, .searchResult("claim-two"))
    }

    func testClearingSearchRestoresTheCatalogTopicFromBeforeSearch() {
        var navigation = HelpReaderNavigationState(selection: .article("workspaces"))

        navigation.queryChanged(
            wasEmpty: true,
            isEmpty: false,
            firstArticleID: "getting-started")
        navigation.reconcileSearch(
            .results(["claim-tools"]),
            queryIsEmpty: false)
        XCTAssertEqual(navigation.selection, .searchResult("claim-tools"))

        navigation.queryChanged(
            wasEmpty: false,
            isEmpty: true,
            firstArticleID: "getting-started")
        XCTAssertEqual(navigation.selection, .article("workspaces"))
    }

    func testEmptyAndFailedSearchesClearTransientResultSelection() {
        var navigation = HelpReaderNavigationState(selection: .article("workspaces"))
        navigation.queryChanged(
            wasEmpty: true,
            isEmpty: false,
            firstArticleID: "getting-started")
        navigation.reconcileSearch(.results(["old-result"]), queryIsEmpty: false)

        navigation.reconcileSearch(.empty, queryIsEmpty: false)
        XCTAssertNil(navigation.selection)

        navigation.select(.searchResult("stale-result"))
        navigation.reconcileSearch(.failed, queryIsEmpty: false)
        XCTAssertNil(navigation.selection)
    }

    func testRestartingSearchClearsAnAnswerFromThePreviousRequest() {
        var navigation = HelpReaderNavigationState(selection: .article("workspaces"))
        navigation.queryChanged(
            wasEmpty: true,
            isEmpty: false,
            firstArticleID: "getting-started")
        navigation.reconcileSearch(.results(["old-result"]), queryIsEmpty: false)

        navigation.searchRestarted()

        XCTAssertNil(navigation.selection)
    }

    func testClearingSearchAlsoClearsTheOtherwiseHiddenHistoryFilter() {
        XCTAssertTrue(helpHistorySelection(
            query: "provider history",
            currentValue: true))
        XCTAssertFalse(helpHistorySelection(
            query: "",
            currentValue: true))
        XCTAssertFalse(helpHistorySelection(
            query: "  \n ",
            currentValue: true))
        XCTAssertFalse(helpHistorySelection(
            query: "",
            currentValue: false))
    }

    func testRequestGenerationRejectsACompletionAfterReplacement() {
        var requests = HelpRequestGeneration()
        let stale = requests.advance()
        let current = requests.advance()

        XCTAssertFalse(requests.accepts(stale))
        XCTAssertTrue(requests.accepts(current))
    }

    func testLifecycleLabelsAreExact() {
        XCTAssertEqual(helpLifecycleLabel(.current), "Current")
        XCTAssertEqual(helpLifecycleLabel(.historical), "Historical")
        XCTAssertEqual(helpLifecycleLabel(.superseded), "Superseded")
        XCTAssertEqual(helpLifecycleLabel(.retired), "Retired")
    }

    func testRecoveryHelpOmitsLiveProductInventory() {
        XCTAssertFalse(helpLiveInventoryIsVisible(allowsLiveInventory: false))
        XCTAssertTrue(helpLiveInventoryIsVisible(allowsLiveInventory: true))
    }

    func testRecoveryHelpKeepsTheExpertWorkspaceHandoffReaderOnly() {
        XCTAssertFalse(helpAgentWorkspaceIsAvailable(allowsProductActions: false))
        XCTAssertTrue(helpAgentWorkspaceIsAvailable(allowsProductActions: true))
    }

    func testHelpBrowserHostsKeepTheirAuthoritySurfacesSeparate() {
        let normal = HelpBrowserHost.standalone(allowsProductActions: true)
        XCTAssertTrue(normal.showsLiveInventory)
        XCTAssertTrue(normal.showsExpertHandoff)
        XCTAssertTrue(normal.allowsDemonstrations)
        XCTAssertFalse(normal.allowsGuides)

        let recovery = HelpBrowserHost.standalone(allowsProductActions: false)
        XCTAssertFalse(recovery.showsLiveInventory)
        XCTAssertFalse(recovery.showsExpertHandoff)
        XCTAssertFalse(recovery.allowsDemonstrations)
        XCTAssertFalse(recovery.allowsGuides)

        let inspector = HelpBrowserHost.workspaceInspector
        XCTAssertFalse(inspector.showsLiveInventory)
        XCTAssertFalse(inspector.showsExpertHandoff)
        XCTAssertTrue(inspector.allowsDemonstrations)
        XCTAssertTrue(inspector.allowsGuides)
    }

    func testGuidedHelpIsExactInspectorOnlyAndRevealActionsStayClosed() {
        let current = guideFixture()
        XCTAssertTrue(helpGuideIsAvailable(
            current,
            host: .workspaceInspector,
            hasExactCoordinator: true))
        XCTAssertFalse(helpGuideIsAvailable(
            current,
            host: .workspaceInspector,
            hasExactCoordinator: false))
        XCTAssertFalse(helpGuideIsAvailable(
            current,
            host: .standalone(allowsProductActions: true),
            hasExactCoordinator: true))
        XCTAssertFalse(helpGuideIsAvailable(
            guideFixture(lifecycle: .historical),
            host: .workspaceInspector,
            hasExactCoordinator: true))
        // A conversation guide points at controls that live in a workspace window. Offering the
        // reader's own Start tour for one installs an overlay that stalls on its first step with
        // "this step's control isn't available in this window" and can never recover. Those guides
        // belong to ShowMechanician, which resolves a real destination window first.
        XCTAssertFalse(helpGuideIsAvailable(
            guideFixture(surface: .conversationWorkspace),
            host: .workspaceInspector,
            hasExactCoordinator: true))

        XCTAssertEqual(helpGuideRevealDestination(for: .none), .unchanged)
        XCTAssertEqual(helpGuideRevealDestination(for: .showHelpInspector), .unchanged)
        XCTAssertEqual(helpGuideRevealDestination(for: .showHelpTopics), .topics)
        XCTAssertEqual(helpGuideRevealDestination(for: .showGuideArticle), .article(.content))
        XCTAssertEqual(helpGuideRevealDestination(for: .showGuideEvidence), .article(.evidence))
        XCTAssertEqual(
            helpGuideRevealDestination(for: .showGuideDemonstrations),
            .article(.demonstrations))
    }

    @MainActor
    func testGuideReaderRestorationLeasePreservesLaterUserChoices() {
        let initial = HelpReaderNavigationState(selection: .article("getting-started"))
        let guideOwned = HelpGuideReaderSession(navigation: initial)
        guideOwned.expect(selection: nil)
        guideOwned.observe(selection: nil)
        guideOwned.expect(selection: .article("mechanician-help"))
        guideOwned.observe(selection: .article("mechanician-help"))
        guideOwned.observe(query: "", includeHistory: false)
        XCTAssertTrue(guideOwned.canRestore)
        XCTAssertEqual(guideOwned.initialNavigation, initial)

        let userSelectedTopic = HelpGuideReaderSession(navigation: initial)
        userSelectedTopic.expect(selection: nil)
        userSelectedTopic.observe(selection: .article("workspaces"))
        XCTAssertFalse(userSelectedTopic.canRestore)

        let userSearched = HelpGuideReaderSession(navigation: initial)
        userSearched.observe(query: "scheduled tasks", includeHistory: false)
        XCTAssertFalse(userSearched.canRestore)

        let userEnabledHistory = HelpGuideReaderSession(navigation: initial)
        userEnabledHistory.observe(query: "", includeHistory: true)
        XCTAssertFalse(userEnabledHistory.canRestore)
    }

    func testHelpInspectorUsesBoundedAndCompactLayoutsWithoutChangingStandaloneHelp() {
        XCTAssertEqual(
            helpBrowserLayout(width: 900, host: .standalone(allowsProductActions: true)),
            .split)
        XCTAssertEqual(
            helpBrowserContainer(
                width: 439,
                host: .standalone(allowsProductActions: true)),
            .nativeNavigationSplit)
        XCTAssertEqual(
            helpBrowserLayout(width: 560, host: .workspaceInspector),
            .split)
        XCTAssertEqual(
            helpBrowserLayout(width: 439, host: .workspaceInspector),
            .compact)
        XCTAssertEqual(
            helpBrowserContainer(width: 439, host: .workspaceInspector),
            .compactInspector)
        XCTAssertEqual(
            helpBrowserContainer(width: 440, host: .workspaceInspector),
            .boundedInspectorSplit)
        XCTAssertEqual(
            HelpBrowserHost.workspaceInspector.sidebarWidths.minimum,
            180)
        XCTAssertEqual(
            HelpBrowserHost.workspaceInspector.sidebarWidths.ideal,
            200)
    }

    func testHelpInspectorNeverChoosesWindowNativeNavigationSplit() {
        for width in [CGFloat(0), 180, 439, 440, 560, 634, 2_000] {
            XCTAssertNotEqual(
                helpBrowserContainer(width: width, host: .workspaceInspector),
                .nativeNavigationSplit,
                "embedded Help at width \(width) must remain bounded by the inspector")
        }
    }

    func testHelpInspectorSplitBudgetsEveryPointAtBoundaryAndWideWidths() {
        let widths = HelpBrowserHost.workspaceInspector.sidebarWidths
        for width in [CGFloat(440), 560, 634, 2_000] {
            let layout = HelpInspectorSplitLayout(
                width: width,
                sidebarWidths: widths)
            XCTAssertEqual(layout.containerWidth, width, accuracy: 0.001)
            XCTAssertEqual(layout.sidebarWidth, 200, accuracy: 0.001)
            XCTAssertEqual(layout.dividerWidth, 1, accuracy: 0.001)
            XCTAssertEqual(layout.allocatedWidth, width, accuracy: 0.001)
            XCTAssertEqual(
                layout.detailWidth,
                width - 201,
                accuracy: 0.001)
        }
    }

    func testOnlyAnExplicitHelpTabPressReturnsTheInspectorToItsCatalog() {
        XCTAssertTrue(HelpInspectorTabActivationPolicy.shouldReturnToCatalog(
            activation: InspectorTabUserActivation(tab: .help, revision: 1)))
        XCTAssertFalse(HelpInspectorTabActivationPolicy.shouldReturnToCatalog(
            activation: InspectorTabUserActivation(tab: .artifacts, revision: 2)))
        XCTAssertFalse(HelpInspectorTabActivationPolicy.shouldReturnToCatalog(
            activation: nil))

        var navigation = HelpReaderNavigationState()
        navigation.corpusBecameReady(firstArticleID: "getting-started", queryIsEmpty: true)
        XCTAssertEqual(navigation.selection, .article("getting-started"))

        navigation.queryChanged(
            wasEmpty: true,
            isEmpty: false,
            firstArticleID: "getting-started")
        navigation.reconcileSearch(
            .results(["scheduled-tasks#automation"]),
            queryIsEmpty: false)
        navigation.select(.searchResult("scheduled-tasks#automation"))
        XCTAssertEqual(
            navigation.selection,
            .searchResult("scheduled-tasks#automation"))

        navigation.returnToCatalog()
        navigation.queryChanged(
            wasEmpty: false,
            isEmpty: true,
            firstArticleID: "getting-started")
        navigation.corpusBecameReady(firstArticleID: "getting-started", queryIsEmpty: true)
        XCTAssertNil(
            navigation.selection,
            "Clearing the query and observing ready state must not reopen detail after Home.")

        navigation.select(.article("mechanician-help"))
        XCTAssertEqual(navigation.selection, .article("mechanician-help"))
    }

    func testEvidenceKindLabelsAreHumanReadable() {
        XCTAssertEqual(helpEvidenceKindLabel(.source), "Source")
        XCTAssertEqual(helpEvidenceKindLabel(.test), "Test")
        XCTAssertEqual(helpEvidenceKindLabel(.canonicalDoc), "Canonical document")
        XCTAssertEqual(helpEvidenceKindLabel(.history), "History")
    }

    func testDemonstrationPromptCarriesTheReviewedRecipeAndSafetyBoundary() throws {
        let demonstration = demonstrationFixture()

        let prompt = helpDemonstrationDraftPrompt(for: demonstration)

        XCTAssertTrue(prompt.contains(demonstration.id))
        XCTAssertTrue(prompt.contains(demonstration.title))
        XCTAssertTrue(prompt.contains(demonstration.outcome))
        XCTAssertTrue(prompt.contains("ListCapabilities, RunCapability"))
        XCTAssertTrue(prompt.contains("List only the saved capabilities."))
        XCTAssertTrue(prompt.contains("Run only the capability the user chose."))
        XCTAssertTrue(prompt.contains("RunCapability"))
        XCTAssertTrue(prompt.contains("Depends on the selected action"))
        XCTAssertTrue(prompt.contains("Before acting"))
        XCTAssertTrue(prompt.contains("The selected capability owns its effects; do not promise an undo unless the live capability or user supplies one."))
        XCTAssertTrue(prompt.contains("fallback.read-only"))
        XCTAssertTrue(prompt.contains("Fallback action: Stop and ask the user to launch the named Help demonstration"))
        XCTAssertTrue(prompt.contains("Fallback Help demonstration: fallback.read-only"))
        XCTAssertTrue(prompt.contains("This reference is not an executable recipe."))
        XCTAssertTrue(prompt.contains("do not reconstruct, improvise, or run the fallback from its ID"))
        XCTAssertTrue(prompt.contains("return to Mechanician Help and choose Try workflow"))
        XCTAssertTrue(prompt.contains("Only the separate reviewed draft created by Help may continue it."))
        XCTAssertFalse(prompt.contains("Offer the named fallback recipe"))
        XCTAssertTrue(prompt.contains("this exact conversation"))
        XCTAssertTrue(prompt.contains("Explain the demonstration plan before calling any tool."))
        XCTAssertTrue(prompt.contains("This request grants no app approval or macOS permission."))
        XCTAssertTrue(prompt.contains("call RecommendMechanicianWorkflow with the goal above and demonstrationID exactly \(demonstration.id)"))
        XCTAssertTrue(prompt.contains("returned workflow ID exactly matches \(demonstration.id)"))
        XCTAssertTrue(prompt.contains("Ready to try here"))
        XCTAssertTrue(prompt.contains("Sending this request is not confirmation to act."))
        XCTAssertTrue(prompt.contains("obtain fresh user confirmation immediately before calling the action tool"))
        XCTAssertTrue(prompt.contains("A readiness label is advice, never authorization."))
        XCTAssertTrue(prompt.contains("Do not send messages, make purchases, delete data, change privacy or security settings, or create scheduled, delegated, or otherwise unattended work."))

        let explain = try XCTUnwrap(prompt.range(of: "Explain the demonstration plan"))
        let liveCheck = try XCTUnwrap(prompt.range(of: "check the live tool inventory"))
        let steps = try XCTUnwrap(prompt.range(of: "Reviewed steps"))
        let verification = try XCTUnwrap(prompt.range(of: "Verification"))
        let cleanup = try XCTUnwrap(prompt.range(of: "Cleanup and reversibility"))
        let fallback = try XCTUnwrap(prompt.range(of: "Reviewed fallbacks"))
        XCTAssertLessThan(explain.lowerBound, liveCheck.lowerBound)
        XCTAssertLessThan(liveCheck.lowerBound, steps.lowerBound)
        XCTAssertLessThan(steps.lowerBound, verification.lowerBound)
        XCTAssertLessThan(verification.lowerBound, cleanup.lowerBound)
        XCTAssertLessThan(cleanup.lowerBound, fallback.lowerBound)
    }

    func testEligibleDemonstrationCanOnlyCreateAnUnsentDraftRoute() throws {
        let demonstration = demonstrationFixture()

        let route = try XCTUnwrap(
            helpDemonstrationDraftRoute(
                for: demonstration,
                allowsProductActions: true))

        guard case .newStandardConversationDraft(let prompt) = route else {
            return XCTFail("Help demonstrations must only open an unsent standard-profile draft")
        }
        XCTAssertEqual(prompt, helpDemonstrationDraftPrompt(for: demonstration))
        XCTAssertNotEqual(route, .newConversation(sending: prompt))
    }

    func testRecoveryHelpAndNoncurrentRecipesRefuseDemonstrationRoutes() {
        XCTAssertNil(
            helpDemonstrationDraftRoute(
                for: demonstrationFixture(),
                allowsProductActions: false))
        XCTAssertNil(
            helpDemonstrationDraftRoute(
                for: demonstrationFixture(lifecycle: .historical),
                allowsProductActions: true))
        XCTAssertFalse(
            helpDemonstrationIsAvailable(
                demonstrationFixture(),
                allowsProductActions: false))
    }

    func testAdditiveBeforeDemoDraftKeepsConfirmationNarrow() {
        let prompt = helpDemonstrationDraftPrompt(
            for: demonstrationFixture(userConfirmation: .beforeDemo))

        XCTAssertTrue(prompt.contains(
            "Sending this reviewed request confirms only the named additive in-app demonstration after you explain it."))
        XCTAssertTrue(prompt.contains("It does not approve a broader or different action."))
        XCTAssertFalse(prompt.contains("Sending this request is not confirmation to act."))
    }

    func testEveryShippedShowMeDraftBindsItsExactSignedDemonstration() async throws {
        let fixture = try HelpCorpusFixture.make()
        defer { fixture.remove() }
        let store = try MechanicianHelpStore(databaseURL: fixture.databaseURL)
        let summaries = try await store.listSections().flatMap(\.articles)
        var demonstrations: [MechanicianHelpDemonstration] = []
        for summary in summaries {
            demonstrations += try await store.demonstrations(articleID: summary.id)
        }

        XCTAssertEqual(demonstrations.count, 5)
        for demonstration in demonstrations {
            let prompt = helpDemonstrationDraftPrompt(for: demonstration)
            XCTAssertTrue(prompt.contains(
                "demonstrationID exactly \(demonstration.id)"), demonstration.id)
            XCTAssertTrue(prompt.contains(
                "returned workflow ID exactly matches \(demonstration.id)"), demonstration.id)
        }
    }

    private func demonstrationFixture(
        lifecycle: MechanicianHelpLifecycle = .current,
        userConfirmation: MechanicianHelpDemoConfirmation = .beforeAct
    ) -> MechanicianHelpDemonstration {
        MechanicianHelpDemonstration(
            id: "demo.run-capability",
            articleID: "mac",
            title: "Run one saved capability",
            outcome: "Show the observed result of exactly one user-chosen capability.",
            lifecycle: lifecycle,
            ordinal: 0,
            claimKeys: ["mac.capabilities"],
            requirements: MechanicianHelpDemoRequirements(
                session: .interactive,
                mode: .executionEnabled,
                tools: ["ListCapabilities", "RunCapability"]),
            risk: .dynamic,
            reversibility: MechanicianHelpDemoReversibility(
                kind: .dynamic,
                instructions: "The selected capability owns its effects; do not promise an undo unless the live capability or user supplies one."),
            userConfirmation: userConfirmation,
            steps: [
                MechanicianHelpDemoStep(
                    id: "list",
                    kind: .observe,
                    tool: "ListCapabilities",
                    instruction: "List only the saved capabilities."),
                MechanicianHelpDemoStep(
                    id: "choose",
                    kind: .ask,
                    tool: nil,
                    instruction: "Ask the user to choose one capability."),
                MechanicianHelpDemoStep(
                    id: "run",
                    kind: .act,
                    tool: "RunCapability",
                    instruction: "Run only the capability the user chose."),
            ],
            verification: [
                MechanicianHelpDemoVerification(
                    kind: .toolSucceeded,
                    stepID: "run",
                    instruction: "Treat only a successful tool result as completion."),
            ],
            fallback: [
                MechanicianHelpDemoFallback(
                    when: .toolUnavailable,
                    action: .useDemo,
                    demoID: "fallback.read-only",
                    instruction: "Offer the read-only recipe instead."),
            ],
            evidence: [])
    }

    private func guideFixture(
        lifecycle: MechanicianHelpLifecycle = .current,
        surface: MechanicianHelpGuideSurface = .helpWorkspaceInspector
    ) -> MechanicianHelpGuide {
        let step = surface == .helpWorkspaceInspector
            ? MechanicianHelpGuideStep(
                id: "search",
                title: "Search Help",
                instruction: "Enter a product term.",
                target: .helpSearchField,
                revealAction: .showHelpTopics,
                completion: .userAdvance,
                ordinal: 0)
            : MechanicianHelpGuideStep(
                id: "open-agents",
                title: "Open Agents",
                instruction: "Look at the Agents tab.",
                target: .conversationAgentsTab,
                revealAction: .showAgentsInspector,
                completion: .userAdvance,
                ordinal: 0)
        return MechanicianHelpGuide(
            id: surface == .helpWorkspaceInspector
                ? "mechanician-help.inspector-tour"
                : "inspector.agents-tour",
            articleID: surface == .helpWorkspaceInspector ? "mechanician-help" : "inspector",
            title: "Tour the Help inspector",
            summary: "Learn the Help inspector.",
            surface: surface,
            lifecycle: lifecycle,
            ordinal: 0,
            claimKeys: ["mechanician-help.search"],
            steps: [step],
            evidence: [])
    }
}
