import Foundation
import XCTest
@testable import Mechanician

/// Per-workspace inspector tabs: the cheap half of the extension question.
///
/// What is pinned hardest here is the pair of rules that are NOT preferences, because both fail
/// silently and one of them fails destructively.
final class InspectorTabPreferenceTests: XCTestCase {
    private var store: UserDefaults!
    private var suite: String!

    override func setUpWithError() throws {
        suite = "inspector-tabs-\(UUID().uuidString)"
        store = try XCTUnwrap(UserDefaults(suiteName: suite))
    }

    override func tearDownWithError() throws {
        store.removePersistentDomain(forName: suite)
    }

    private let workspace = UUID()

    // MARK: - Defaults

    /// A record panel belongs to the app-owned workspace it is the record for and nowhere else by
    /// default. A tab present in every workspace is a tab most workspaces do not want.
    func testTheDefaultTabsFollowWhetherTheWorkspaceHasAFolder() {
        XCTAssertEqual(
            InspectorTabPreference.defaults(cwd: "/tmp/repo", workspaceID: workspace),
            [.files, .changes, .artifacts, .agents, .skills])
        XCTAssertEqual(
            InspectorTabPreference.defaults(cwd: "", workspaceID: workspace),
            [.artifacts, .agents, .skills])
    }


    func testHelpIsTheHelpWorkspaceDefaultAndNowhereElse() {
        XCTAssertEqual(
            InspectorTabPreference.defaults(cwd: "", workspaceID: HelpWorkspace.id),
            [.help],
            "the closed Help expert starts with its signed product record, not empty tool panels")
        XCTAssertFalse(
            InspectorTabPreference.defaults(cwd: "", workspaceID: workspace).contains(.help))
        XCTAssertEqual(InspectorTab.help.rawValue, "help")
        XCTAssertEqual(InspectorTab.help.label, "Help")
        XCTAssertEqual(InspectorTab.help.icon, HelpWorkspace.iconSymbol)
    }

    // MARK: - The two rules that are not preferences

    /// THE DESTRUCTIVE ONE. Git in a folder-less workspace runs in agentd's global cwd — the
    /// last-opened project — so Changes would stage, commit and push against the wrong repository.
    /// A person may hide those tabs and may never conjure them.
    func testFilesAndChangesCannotBeTurnedOnWithoutAFolder() {
        InspectorTabPreference.setVisible(
            true, tab: .changes, cwd: "", workspaceID: workspace, store: store)
        InspectorTabPreference.setVisible(
            true, tab: .files, cwd: "", workspaceID: workspace, store: store)
        let visible = InspectorTabPreference.visible(
            cwd: "", workspaceID: workspace, store: store)
        XCTAssertFalse(visible.contains(.changes))
        XCTAssertFalse(visible.contains(.files))
    }

    /// And the read applies it too, so a workspace that HAD a folder and lost it cannot keep drawing
    /// them from a stored value.
    func testAStoredChoiceCannotSurviveLosingTheFolder() {
        InspectorTabPreference.setVisible(
            true, tab: .changes, cwd: "/tmp/repo", workspaceID: workspace, store: store)
        XCTAssertTrue(
            InspectorTabPreference
                .visible(cwd: "/tmp/repo", workspaceID: workspace, store: store)
                .contains(.changes))
        XCTAssertFalse(
            InspectorTabPreference
                .visible(cwd: "", workspaceID: workspace, store: store)
                .contains(.changes),
            "the folder rule is applied at the read, not only at the write")
    }

    /// An empty bar is an inspector that looks broken, and the way out of it would be the menu it
    /// just hid.
    func testAWorkspaceCanNeverShowNothing() {
        for tab in InspectorTab.allCases {
            InspectorTabPreference.setVisible(
                false, tab: tab, cwd: "/tmp/repo", workspaceID: workspace, store: store)
        }
        let visible = InspectorTabPreference.visible(
            cwd: "/tmp/repo", workspaceID: workspace, store: store)
        XCTAssertFalse(visible.isEmpty)
    }

    // MARK: - Choosing

    func testHidingAndShowingOneTabPersistsForThatWorkspaceOnly() {
        let other = UUID()
        InspectorTabPreference.setVisible(
            false, tab: .agents, cwd: "/tmp/repo", workspaceID: workspace, store: store)

        XCTAssertFalse(
            InspectorTabPreference
                .visible(cwd: "/tmp/repo", workspaceID: workspace, store: store)
                .contains(.agents))
        XCTAssertTrue(
            InspectorTabPreference
                .visible(cwd: "/tmp/repo", workspaceID: other, store: store).contains(.agents),
            "a choice is per workspace, not global")
    }


    func testHelpCanBeAddedToAnyWorkspace() {
        InspectorTabPreference.setVisible(
            true, tab: .help, cwd: "/tmp/repo", workspaceID: workspace, store: store)
        XCTAssertTrue(
            InspectorTabPreference
                .visible(cwd: "/tmp/repo", workspaceID: workspace, store: store).contains(.help))
    }

    /// The bar is drawn in groups separated by dividers, so a stored list must not be able to put it
    /// in an arrangement the groups do not expect.
    func testTheOrderIsCanonicalRatherThanTheOrderTheyWereToggled() {
        InspectorTabPreference.setVisible(
            false, tab: .files, cwd: "/tmp/repo", workspaceID: workspace, store: store)
        InspectorTabPreference.setVisible(
            true, tab: .help, cwd: "/tmp/repo", workspaceID: workspace, store: store)
        InspectorTabPreference.setVisible(
            true, tab: .files, cwd: "/tmp/repo", workspaceID: workspace, store: store)
        XCTAssertEqual(
            InspectorTabPreference.visible(cwd: "/tmp/repo", workspaceID: workspace, store: store),
            InspectorTab.allCases,
            "canonical order, whatever order the person clicked")
    }

    func testResetGoesBackToTheDefaultsForThatKindOfWorkspace() {
        InspectorTabPreference.setVisible(
            false, tab: .skills, cwd: "/tmp/repo", workspaceID: workspace, store: store)
        XCTAssertTrue(InspectorTabPreference.isCustomized(workspaceID: workspace, store: store))

        InspectorTabPreference.reset(workspaceID: workspace, store: store)
        XCTAssertFalse(InspectorTabPreference.isCustomized(workspaceID: workspace, store: store))
        XCTAssertEqual(
            InspectorTabPreference.visible(cwd: "/tmp/repo", workspaceID: workspace, store: store),
            InspectorTabPreference.defaults(cwd: "/tmp/repo", workspaceID: workspace))
    }

    /// A tab retired in a later build must not turn a customised bar into the defaults without
    /// explanation, and a build that ADDS one must not be blocked by a list that predates it.
    func testAnUnknownStoredTabIsIgnoredRatherThanFailingTheWholeList() {
        store.set(["artifacts", "telepathy", "skills"], forKey: InspectorTabPreference.key(workspace))
        XCTAssertEqual(
            InspectorTabPreference.visible(cwd: "/tmp/repo", workspaceID: workspace, store: store),
            [.artifacts, .skills])
    }

    /// HOME IS A WORKSPACE and it carries `projectID == nil`. Treating nil as "nowhere to store
    /// this" would have made the default workspace — where most people start — the one whose tabs
    /// could not be chosen.
    func testHomeCanChooseItsTabsEvenThoughItHasNoProjectID() {
        InspectorTabPreference.setVisible(
            false, tab: .agents, cwd: "", workspaceID: nil, store: store)
        XCTAssertFalse(
            InspectorTabPreference
                .visible(cwd: "", workspaceID: nil, store: store).contains(.agents))
        XCTAssertEqual(
            InspectorTabPreference.key(nil),
            InspectorTabPreference.key(SQLiteLibraryStore.homeWorkspaceID),
            "nil resolves to the id the library already uses for Home, not a nameless bucket")
    }

    // MARK: - Remembering the selected tab

    func testEachWorkspaceRestoresTheTabThePersonChose() {
        let other = UUID()
        InspectorTabPreference.setSelected(
            .changes, cwd: "/tmp/repo", workspaceID: workspace, store: store)
        InspectorTabPreference.setSelected(
            .skills, cwd: "/tmp/other", workspaceID: other, store: store)

        XCTAssertEqual(
            InspectorTabPreference.selected(
                cwd: "/tmp/repo", workspaceID: workspace, store: store),
            .changes)
        XCTAssertEqual(
            InspectorTabPreference.selected(
                cwd: "/tmp/other", workspaceID: other, store: store),
            .skills)
    }

    /// A folder window can receive its cwd before its Project UUID. It must not read or overwrite
    /// Home's selected tab during that transient edge.
    func testAProjectlessFolderSelectionIsDistinctFromHome() {
        InspectorTabPreference.setSelected(
            .files, cwd: "/tmp/repo", workspaceID: nil, store: store)
        InspectorTabPreference.setSelected(
            .agents, cwd: "", workspaceID: nil, store: store)

        XCTAssertNotEqual(
            InspectorTabPreference.selectionKey(nil, cwd: "/tmp/repo"),
            InspectorTabPreference.selectionKey(nil, cwd: ""))
        XCTAssertEqual(
            InspectorTabPreference.selected(
                cwd: "/tmp/repo", workspaceID: nil, store: store),
            .files)
        XCTAssertEqual(
            InspectorTabPreference.selected(cwd: "", workspaceID: nil, store: store),
            .agents)
    }

    func testASelectionMadeBeforeTheWorkspaceIDArrivesMovesToThatWorkspace() {
        InspectorTabPreference.setSelected(
            .files, cwd: "/tmp/repo", workspaceID: nil, store: store)
        // Prove this is the cwd-specific carry-over, not the retired global fallback.
        store.set(InspectorTab.agents.rawValue, forKey: "panel.inspectorTab")

        XCTAssertEqual(
            InspectorTabPreference.selected(
                cwd: "/tmp/repo", workspaceID: workspace, store: store),
            .files)
        XCTAssertEqual(
            store.string(forKey: InspectorTabPreference.selectionKey(workspace)),
            InspectorTab.files.rawValue)
    }


    func testHelpDefaultsToHelpThenRestoresAnExplicitVisibleChoice() {
        XCTAssertEqual(
            InspectorTabPreference.selected(
                cwd: "", workspaceID: HelpWorkspace.id, store: store),
            .help)

        InspectorTabPreference.setVisible(
            true, tab: .agents, cwd: "", workspaceID: HelpWorkspace.id, store: store)
        InspectorTabPreference.setSelected(
            .agents, cwd: "", workspaceID: HelpWorkspace.id, store: store)
        XCTAssertEqual(
            InspectorTabPreference.selected(
                cwd: "", workspaceID: HelpWorkspace.id, store: store),
            .agents)
    }

    // MARK: - Adding Help to existing Help workspaces

    func testMigrationAddsHelpToAnExistingCustomizedHelpWorkspaceWithoutReorderingIt() {
        let key = InspectorTabPreference.key(HelpWorkspace.id)
        store.set(["skills", "future-tab", "artifacts"], forKey: key)

        InspectorTabPreference.migrateExistingHelpWorkspaceTabIfNeeded(store: store)

        XCTAssertEqual(
            store.stringArray(forKey: key),
            ["skills", "future-tab", "artifacts", "help"],
            "migration preserves the raw preference, including values this build does not know")
        let visible = InspectorTabPreference.visible(
            cwd: "", workspaceID: HelpWorkspace.id, store: store)
        XCTAssertEqual(
            visible,
            [.skills, .artifacts, .help],
            "the preference reader preserves known choices while dropping the future value")
        XCTAssertEqual(
            InspectorTab.allCases.filter(visible.contains),
            [.artifacts, .skills, .help],
            "the tab bar still renders those choices in canonical order")
        XCTAssertTrue(store.bool(forKey: InspectorTabPreference.helpTabMigrationKey))
    }

    func testMigrationLeavesAnUncustomizedHelpWorkspaceOnEvolvingDefaults() {
        let key = InspectorTabPreference.key(HelpWorkspace.id)

        InspectorTabPreference.migrateExistingHelpWorkspaceTabIfNeeded(store: store)

        XCTAssertNil(store.array(forKey: key), "an app default must not become a user preference")
        XCTAssertEqual(
            InspectorTabPreference.visible(cwd: "", workspaceID: HelpWorkspace.id, store: store),
            [.help])
    }

    func testMigrationIsIdempotentAndDoesNotReAddHelpAfterThePersonHidesIt() {
        let key = InspectorTabPreference.key(HelpWorkspace.id)
        store.set(["artifacts"], forKey: key)
        InspectorTabPreference.migrateExistingHelpWorkspaceTabIfNeeded(store: store)
        InspectorTabPreference.setVisible(
            false, tab: .help, cwd: "", workspaceID: HelpWorkspace.id, store: store)

        InspectorTabPreference.migrateExistingHelpWorkspaceTabIfNeeded(store: store)

        XCTAssertEqual(store.stringArray(forKey: key), ["artifacts"])
        XCTAssertFalse(
            InspectorTabPreference.visible(cwd: "", workspaceID: HelpWorkspace.id, store: store)
                .contains(.help))
    }

    func testFreshHelpDefaultsToAClosedInspector() {
        XCTAssertFalse(HelpWorkspaceInspectorVisibilityPolicy.resolve(restoredVisibility: nil))
    }

    func testRestoredHelpVisibilityWinsOverTheClosedDefault() {
        XCTAssertFalse(HelpWorkspaceInspectorVisibilityPolicy.resolve(restoredVisibility: false))
        XCTAssertTrue(HelpWorkspaceInspectorVisibilityPolicy.resolve(restoredVisibility: true))
    }

    func testMigrationDoesNotDuplicateAnAlreadyPresentHelpTab() {
        let key = InspectorTabPreference.key(HelpWorkspace.id)
        store.set(["artifacts", "help"], forKey: key)

        InspectorTabPreference.migrateExistingHelpWorkspaceTabIfNeeded(store: store)

        XCTAssertEqual(store.stringArray(forKey: key), ["artifacts", "help"])
    }

    /// ACROSS THE SEAM, not just the pure function.
    ///
    /// David reported the tabs still there after the default changed. That turned out to be an
    /// install lag, but the test that existed could not have told the difference: it asserted
    /// `defaults(cwd:workspaceID:)` directly, and the inspector does not call that — it goes
    /// through the bridge's own `inspectorPreferenceWorkspaceID`, which resolves a workspace id
    /// from `projectID`/`cwd` before any of this is consulted. If that resolution ever stopped
    /// returning the reserved id, the default would be correct and dead at the same time.
    @MainActor
    func testTheHelpWorkspaceBridgeOffersOnlyTheRecordItIsFor() throws {
        let support = FileManager.default.temporaryDirectory
            .appendingPathComponent("inspector-help-tabs-\(UUID().uuidString)", isDirectory: true)
        let bridge = AgentBridge(settingsBaseOverride: support, environmentOverride: [:])
        bridge.projectID = HelpWorkspace.id
        bridge.cwd = ""
        defer {
            bridge.shutdown()
            try? FileManager.default.removeItem(at: support)
        }

        XCTAssertEqual(
            bridge.inspectorPreferenceWorkspaceID,
            HelpWorkspace.id,
            "the preference key the inspector reads must be the Help workspace itself")
        XCTAssertEqual(bridge.visibleInspectorTabs(store: store), [.help])
        XCTAssertEqual(bridge.visibleInspectorTabs(store: store).contains(.artifacts), false)
        XCTAssertEqual(bridge.visibleInspectorTabs(store: store).contains(.skills), false)

        // And a Home window in the same process is untouched by it.
        let home = AgentBridge(settingsBaseOverride: support, environmentOverride: [:])
        home.projectID = nil
        home.cwd = ""
        defer { home.shutdown() }
        XCTAssertEqual(home.visibleInspectorTabs(store: store), [.artifacts, .agents, .skills])
    }

    /// Selecting a visible tab is an explicit action even when it is already selected. A record
    /// panel uses this token as its return-to-top action, while automatic restoration must leave
    /// it untouched.
    @MainActor
    func testExplicitTabPressesPublishFreshActivationsButRestoreDoesNot() throws {
        let support = FileManager.default.temporaryDirectory
            .appendingPathComponent("inspector-tab-activation-\(UUID().uuidString)", isDirectory: true)
        let bridge = AgentBridge(settingsBaseOverride: support, environmentOverride: [:])
        bridge.projectID = HelpWorkspace.id
        bridge.cwd = ""
        defer {
            bridge.shutdown()
            try? FileManager.default.removeItem(at: support)
        }

        bridge.userSelectedInspectorTab(.help, store: store)
        let first = try XCTUnwrap(bridge.inspectorTabUserActivation)
        XCTAssertEqual(first.tab, .help)

        bridge.userSelectedInspectorTab(.help, store: store)
        let second = try XCTUnwrap(bridge.inspectorTabUserActivation)
        XCTAssertEqual(second.tab, .help)
        XCTAssertGreaterThan(second.revision, first.revision)

        bridge.restoreInspectorTabSelection(store: store)
        XCTAssertEqual(bridge.inspectorTab, .help)
        XCTAssertEqual(
            bridge.inspectorTabUserActivation,
            second,
            "automatic restoration is selection, not an explicit tab activation")
    }

    /// Folder-backed Workspace windows are keyed by cwd, so their live bridges carry a nil
    /// `projectID`. That nil means Home only at the window-routing layer: Inspector preferences
    /// must resolve the folder back to its durable Workspace id before they draw, toggle, reset,
    /// or select a tab. Otherwise a Home-only tab appears in every folder Workspace but its own
    /// activation guard rejects it.
    @MainActor
    func testFolderWorkspaceNeverDrawsAHomeOnlyTabAndCanSelectItsOwn() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("inspector-folder-tabs-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let workspace = Project(name: "Inspector tabs", cwd: root.path)
        ProjectStore.shared.upsert(workspace)
        let bridge = AgentBridge(
            settingsBaseOverride: root.appendingPathComponent("settings", isDirectory: true),
            environmentOverride: [:])
        bridge.projectID = nil
        bridge.cwd = root.path
        defer {
            bridge.shutdown()
            ProjectStore.shared.remove(workspace.id)
            ProjectStore.shared.flushSaves()
            try? FileManager.default.removeItem(at: root)
        }

        // The old InspectorView read this Home preference through `bridge.projectID == nil`, while
        // userSelectedInspectorTab resolved `root` to `workspace.id` and silently refused the tap.
        InspectorTabPreference.setVisible(
            true, tab: .help, cwd: "", workspaceID: nil, store: store)
        XCTAssertTrue(
            InspectorTabPreference.visible(cwd: root.path, workspaceID: nil, store: store)
                .contains(.help))
        XCTAssertFalse(
            InspectorTabPreference.visible(cwd: root.path, workspaceID: workspace.id, store: store)
                .contains(.help))
        XCTAssertFalse(
            bridge.visibleInspectorTabs(store: store).contains(.help),
            "the rendered tab set must use the same resolved Workspace as activation")

        bridge.setInspectorTabVisible(true, tab: .help, store: store)
        XCTAssertTrue(bridge.visibleInspectorTabs(store: store).contains(.help))
        XCTAssertTrue(
            InspectorTabPreference.visible(cwd: root.path, workspaceID: workspace.id, store: store)
                .contains(.help),
            "customizing a folder Workspace must not write into Home")

        bridge.userSelectedInspectorTab(.help, store: store)
        XCTAssertEqual(bridge.inspectorTab, .help)

        bridge.resetInspectorTabVisibility(store: store)
        XCTAssertFalse(bridge.visibleInspectorTabs(store: store).contains(.help))
        XCTAssertTrue(
            InspectorTabPreference.visible(cwd: "", workspaceID: nil, store: store)
                .contains(.help),
            "resetting a folder Workspace must preserve Home's own customization")
    }

    @MainActor
    func testAnAutomaticTabDoesNotReplaceTheRememberedUserSelection() {
        let support = FileManager.default.temporaryDirectory
            .appendingPathComponent("mechanician-tab-selection-\(UUID().uuidString)")
        let bridge = AgentBridge(settingsBaseOverride: support, environmentOverride: [:])
        bridge.cwd = "/tmp/repo"
        bridge.projectID = workspace
        bridge.userSelectedInspectorTab(.skills, store: store)

        bridge.inspectorTab = .agents // an automatic multi-agent announcement
        bridge.restoreInspectorTabSelection(store: store)

        XCTAssertEqual(bridge.inspectorTab, .skills)
    }
}
