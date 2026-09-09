import AppKit
import XCTest
@testable import Mechanician

/// The ledger on disk. Every failure mode has to degrade to "fall back to the single-window keys",
/// because the alternative — throwing, or opening nothing — is the state-loss invariant failing on
/// the one path where the user is watching for it.
final class WorkspaceSessionLedgerTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "WorkspaceSessionLedgerTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    private func entry(
        _ project: UUID?,
        conversation: UUID? = nil,
        group: Int = 0,
        tab: Int = 0,
        key: Bool = false,
        selected: Bool = false,
        layout: WorkspaceWindowLayout? = nil,
        blank: Bool = false
    ) -> WorkspaceSessionLedger.Entry {
        WorkspaceSessionLedger.Entry(projectID: project, cwd: "", conversationID: conversation,
                                     groupIndex: group, tabIndex: tab, wasKey: key,
                                     wasSelected: selected, layout: layout,
                                     restoresBlankTab: blank)
    }

    func testALedgerRoundTrips() {
        let firstLayout = WorkspaceWindowLayout(
            frame: WorkspaceWindowFrame(NSRect(x: 40, y: 50, width: 1200, height: 800)),
            showsSidebar: true,
            sidebarWidth: 318,
            showsInspector: false,
            inspectorPreferredWidth: 460,
            showsTerminal: true,
            terminalHeight: 280)
        let secondLayout = WorkspaceWindowLayout(
            frame: WorkspaceWindowFrame(NSRect(x: 90, y: 100, width: 960, height: 720)),
            showsSidebar: false,
            sidebarWidth: 250,
            showsInspector: true,
            inspectorPreferredWidth: 640,
            showsTerminal: false,
            terminalHeight: 190)
        let original = WorkspaceSessionLedger(windows: [
            entry(UUID(), conversation: UUID(), group: 0, tab: 0, key: true,
                  selected: true, layout: firstLayout),
            entry(nil, conversation: UUID(), group: 0, tab: 1, layout: secondLayout),
            entry(UUID(), group: 1, selected: true, layout: secondLayout, blank: true),
        ])
        original.save(to: defaults)
        XCTAssertEqual(WorkspaceSessionLedger.load(from: defaults), original)
    }

    /// Absent, empty, and unreadable all mean the same thing to the caller: use the old keys.
    func testEveryUnusableLedgerReadsAsNoLedger() {
        XCTAssertNil(WorkspaceSessionLedger.load(from: defaults), "absent")

        WorkspaceSessionLedger(windows: []).save(to: defaults)
        XCTAssertNil(WorkspaceSessionLedger.load(from: defaults), "empty window list")

        defaults.set(Data("not json".utf8), forKey: WorkspaceSessionLedger.defaultsKey)
        XCTAssertNil(WorkspaceSessionLedger.load(from: defaults), "corrupt")

        defaults.set(Data(#"{"version":99,"windows":[{"cwd":""}]}"#.utf8),
                     forKey: WorkspaceSessionLedger.defaultsKey)
        XCTAssertNil(WorkspaceSessionLedger.load(from: defaults),
                     "a ledger from a future version must not be guessed at")
    }

    /// The Codable default trap, which cost a whole conversation store in 0.11.7: a synthesized
    /// `Decodable` ignores property defaults, so one added field makes every older record fail to
    /// decode. Here that would silently cost a session on upgrade, so the decoding is hand-written
    /// and this is the test that says so.
    func testALedgerWrittenBeforeLaterFieldsExistedStillDecodes() throws {
        let projectID = UUID()
        let older = """
            {"version":1,"windows":[{"projectID":"\(projectID.uuidString)","cwd":""}]}
            """
        defaults.set(Data(older.utf8), forKey: WorkspaceSessionLedger.defaultsKey)

        let ledger = try XCTUnwrap(WorkspaceSessionLedger.load(from: defaults))
        XCTAssertEqual(ledger.windows.count, 1)
        XCTAssertEqual(ledger.windows[0].projectID, projectID)
        XCTAssertEqual(ledger.windows[0].groupIndex, 0)
        XCTAssertEqual(ledger.windows[0].tabIndex, 0)
        XCTAssertFalse(ledger.windows[0].wasKey)
        XCTAssertFalse(ledger.windows[0].wasSelected)
        XCTAssertNil(ledger.windows[0].layout)
        XCTAssertFalse(ledger.windows[0].restoresBlankTab)
    }

    func testMalformedOptionalLayoutFieldDoesNotCostTheWindowOrItsOtherLayout() throws {
        let projectID = UUID(), conversationID = UUID()
        let json = """
            {"version":1,"windows":[{
              "projectID":"\(projectID.uuidString)",
              "conversationID":"\(conversationID.uuidString)",
              "layout":{"showsSidebar":true,"sidebarWidth":"bad","terminalHeight":275}
            }]}
            """
        defaults.set(Data(json.utf8), forKey: WorkspaceSessionLedger.defaultsKey)

        let entry = try XCTUnwrap(WorkspaceSessionLedger.load(from: defaults)?.windows.first)
        XCTAssertEqual(entry.layout?.showsSidebar, true)
        XCTAssertNil(entry.layout?.sidebarWidth)
        XCTAssertEqual(entry.layout?.terminalHeight, 275)
    }

    func testClearingWindowLayoutsPreservesSessionTopology() throws {
        let original = WorkspaceSessionLedger(windows: [
            entry(UUID(), conversation: UUID(), group: 0, tab: 0, key: true,
                  selected: true, layout: WorkspaceWindowLayout(showsSidebar: false)),
            entry(nil, group: 1, selected: true,
                  layout: WorkspaceWindowLayout(showsTerminal: true), blank: true),
        ])
        original.save(to: defaults)

        WorkspaceSessionLedger.clearWindowLayouts(from: defaults)

        let cleared = try XCTUnwrap(WorkspaceSessionLedger.load(from: defaults))
        XCTAssertEqual(cleared.windows.map(\.projectID), original.windows.map(\.projectID))
        XCTAssertEqual(cleared.windows.map(\.conversationID), original.windows.map(\.conversationID))
        XCTAssertEqual(cleared.windows.map(\.wasSelected), [true, true])
        XCTAssertEqual(cleared.windows.map(\.restoresBlankTab), [false, true])
        XCTAssertTrue(cleared.windows.allSatisfy { $0.layout == nil })
    }

    /// Deleting the key must leave behavior byte-for-byte what it was, which is also what the first
    /// launch after upgrade does.
    func testClearingTheLedgerRestoresTheOldWorld() {
        WorkspaceSessionLedger(windows: [entry(UUID())]).save(to: defaults)
        WorkspaceSessionLedger.clear(from: defaults)
        XCTAssertNil(WorkspaceSessionLedger.load(from: defaults))
    }
}

final class WorkspaceSidebarWidthMigrationTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "WorkspaceSidebarWidthMigrationTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    func testMigratesOnlyConstructionMinimumAcrossWorkspaceAndSessionPreferences() throws {
        let constructionKey = WorkspaceSidebarWidthMigration.preferenceKeyPrefix + "construction"
        let explicitKey = WorkspaceSidebarWidthMigration.preferenceKeyPrefix + "explicit"
        defaults.set(220.0, forKey: constructionKey)
        defaults.set(286.0, forKey: explicitKey)
        WorkspaceSessionLedger(windows: [
            entry(layout: WorkspaceWindowLayout(sidebarWidth: 220)),
            entry(layout: WorkspaceWindowLayout(sidebarWidth: 286)),
        ]).save(to: defaults)

        WorkspaceSidebarWidthMigration.migrateIfNeeded(in: defaults)

        XCTAssertNil(
            defaults.object(forKey: constructionKey),
            "The persisted construction minimum must fall through to the new product default.")
        XCTAssertEqual(
            defaults.double(forKey: explicitKey),
            286,
            accuracy: 0.001,
            "A nondefault divider width is evidence of a deliberate prior choice.")
        let ledger = try XCTUnwrap(WorkspaceSessionLedger.load(from: defaults))
        XCTAssertNil(
            ledger.windows[0].layout?.sidebarWidth,
            "A session snapshot of the construction minimum must not defeat the wider default.")
        XCTAssertEqual(
            ledger.windows[1].layout?.sidebarWidth,
            286,
            "An explicit session width remains the most exact window state.")
        XCTAssertEqual(
            defaults.integer(forKey: WorkspaceSidebarWidthMigration.markerKey),
            1)
    }

    func testOneTimeMigrationPreservesAnIntentionalMinimumChosenLater() throws {
        // First launch after update records the marker after inspecting every pre-existing sidebar
        // preference and session tab. A later 220-point resize is no longer ambiguous legacy data.
        WorkspaceSidebarWidthMigration.migrateIfNeeded(in: defaults)

        let intentionalKey = WorkspaceSidebarWidthMigration.preferenceKeyPrefix + "intentional"
        defaults.set(220.0, forKey: intentionalKey)
        WorkspaceSessionLedger(windows: [
            entry(layout: WorkspaceWindowLayout(sidebarWidth: 220)),
        ]).save(to: defaults)

        WorkspaceSidebarWidthMigration.migrateIfNeeded(in: defaults)

        XCTAssertEqual(defaults.double(forKey: intentionalKey), 220, accuracy: 0.001)
        let ledger = try XCTUnwrap(WorkspaceSessionLedger.load(from: defaults))
        XCTAssertEqual(ledger.windows[0].layout?.sidebarWidth, 220)
    }

    private func entry(layout: WorkspaceWindowLayout) -> WorkspaceSessionLedger.Entry {
        WorkspaceSessionLedger.Entry(
            projectID: UUID(),
            cwd: "",
            conversationID: UUID(),
            layout: layout)
    }
}

final class WorkspaceWindowLayoutTests: XCTestCase {
    func testFrameRoundTripsThroughValidatedRect() throws {
        let rect = NSRect(x: 35, y: 70, width: 1440, height: 920)
        let frame = WorkspaceWindowFrame(rect)
        XCTAssertEqual(try XCTUnwrap(frame.rect), rect)
    }

    func testInvalidFrameAndPanelExtentsAreRejectedAtUseBoundary() {
        XCTAssertNil(WorkspaceWindowFrame(
            NSRect(x: 0, y: 0, width: 0, height: 600)).rect)
        let layout = WorkspaceWindowLayout(
            sidebarWidth: .nan,
            inspectorPreferredWidth: 400,
            terminalHeight: 900)
        XCTAssertNil(layout.validSidebarWidth(220...420))
        XCTAssertEqual(layout.validInspectorWidth(180...2_000), 400)
        XCTAssertNil(layout.validTerminalHeight(120...400))
    }
}

/// The drop / keep / dedupe / never-empty rules.
final class WorkspaceSessionPlanTests: XCTestCase {
    private let liveProject = UUID()
    private let otherProject = UUID()
    private let goneProject = UUID()
    private let liveConversation = UUID()
    private let goneConversation = UUID()

    private func plan(
        _ windows: [WorkspaceSessionLedger.Entry],
        conversations: Set<UUID>? = nil,
        conversationBelongsToWorkspace: (UUID, UUID?) -> Bool = { _, _ in true }
    ) -> [WorkspaceSessionPlan.Group]? {
        let conversations = conversations ?? [liveConversation]
        return WorkspaceSessionPlan.restore(
            ledger: WorkspaceSessionLedger(windows: windows),
            projectExists: { [liveProject, otherProject].contains($0) },
            conversationExists: { conversations.contains($0) },
            conversationBelongsToWorkspace: conversationBelongsToWorkspace)
    }

    private func entry(
        _ project: UUID?,
        conversation: UUID? = nil,
        cwd: String = "",
        group: Int = 0,
        tab: Int = 0,
        key: Bool = false,
        selected: Bool = false,
        layout: WorkspaceWindowLayout? = nil,
        blank: Bool = false
    ) -> WorkspaceSessionLedger.Entry {
        WorkspaceSessionLedger.Entry(projectID: project, cwd: cwd, conversationID: conversation,
                                     groupIndex: group, tabIndex: tab, wasKey: key,
                                     wasSelected: selected, layout: layout,
                                     restoresBlankTab: blank)
    }

    /// Distinct durable conversations survive, while every Workspace gets exactly one native group.
    func testAHealthySessionSurvivesPlanningIntact() throws {
        let second = UUID(), home = UUID(), other = UUID()
        let windows = [
            entry(liveProject, conversation: liveConversation, group: 0, tab: 0),
            entry(liveProject, conversation: second, group: 0, tab: 1),
            entry(nil, conversation: home, group: 1, tab: 0),
            entry(otherProject, conversation: other, group: 2, tab: 0),
        ]
        let groups = try XCTUnwrap(plan(
            windows, conversations: [liveConversation, second, home, other]))
        XCTAssertEqual(groups.count, 3, "one tab group per Workspace")
        XCTAssertEqual(groups.flatMap(\.windows).count, windows.count, "planning dropped a window")
        XCTAssertEqual(groups[0].windows.count, 2)
        XCTAssertEqual(groups[1].windows.count, 1)
        XCTAssertEqual(groups[2].windows.count, 1)
    }

    func testAWorkspaceDeletedSinceQuitIsNotReopened() throws {
        let groups = try XCTUnwrap(plan([
            entry(liveProject, conversation: liveConversation, group: 0),
            entry(goneProject, conversation: liveConversation, group: 1),
        ]))
        XCTAssertEqual(groups.flatMap(\.windows).map(\.projectID), [liveProject])
    }

    /// Home has no id, so it can never be "deleted" — and it is the destination that must always be
    /// reachable when it still names a durable Conversation.
    func testHomeWithAConversationSurvives() throws {
        let groups = try XCTUnwrap(plan([entry(nil, conversation: liveConversation)]))
        XCTAssertEqual(groups.flatMap(\.windows).count, 1)
        XCTAssertTrue(groups[0].windows[0].isHome)
    }

    func testHomeCannotRestoreAProjectScopedConversation() {
        XCTAssertNil(plan(
            [entry(nil, conversation: liveConversation)],
            conversationBelongsToWorkspace: { conversationID, projectID in
                conversationID == self.liveConversation && projectID == self.liveProject
            }))
    }

    func testProjectScopedConversationRecordedUnderHomeAndProjectRestoresOnlyProject() throws {
        let groups = try XCTUnwrap(plan(
            [
                entry(nil, conversation: liveConversation, group: 0),
                entry(liveProject, conversation: liveConversation, group: 1),
            ],
            conversationBelongsToWorkspace: { conversationID, projectID in
                conversationID == self.liveConversation && projectID == self.liveProject
            }))
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups[0].windows.count, 1)
        XCTAssertEqual(groups[0].windows[0].projectID, liveProject)
        XCTAssertFalse(groups[0].windows[0].isHome)
    }

    /// A ledger row without a durable Conversation is an empty placeholder, not a second Workspace.
    func testAMissingConversationDropsItsTab() {
        XCTAssertNil(plan([entry(liveProject, conversation: goneConversation)]))
    }

    /// Regression: an old session contained one real Project tab plus two stale Home placeholders.
    /// Relaunch must not manufacture two Home windows from those missing rows.
    func testStaleHomePlaceholdersCannotRestoreDuplicateHomeWindows() throws {
        let groups = try XCTUnwrap(plan([
            entry(liveProject, conversation: liveConversation, group: 0, tab: 0),
            entry(nil, conversation: goneConversation, group: 1, tab: 0),
            entry(nil, group: 2, tab: 0),
        ]))
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups[0].windows.map(\.projectID), [liveProject])
    }

    func testExplicitBlankTabsSurviveAndLegacyPlaceholdersStillDrop() throws {
        let firstLayout = WorkspaceWindowLayout(
            frame: WorkspaceWindowFrame(NSRect(x: 20, y: 30, width: 1100, height: 760)),
            showsSidebar: true,
            sidebarWidth: 305)
        let blankLayout = WorkspaceWindowLayout(
            frame: WorkspaceWindowFrame(NSRect(x: 80, y: 90, width: 980, height: 700)),
            showsSidebar: false,
            showsTerminal: true,
            terminalHeight: 260)
        let groups = try XCTUnwrap(plan([
            entry(liveProject, conversation: liveConversation, group: 2, tab: 0,
                  layout: firstLayout),
            entry(liveProject, group: 2, tab: 1, selected: true,
                  layout: blankLayout, blank: true),
            entry(liveProject, group: 2, tab: 2), // pre-marker legacy placeholder
            entry(liveProject, group: 2, tab: 3, layout: firstLayout, blank: true),
        ]))

        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups[0].windows.map(\.conversationID), [liveConversation, nil, nil])
        XCTAssertEqual(groups[0].windows.map(\.layout), [firstLayout, blankLayout, firstLayout])
        XCTAssertEqual(groups[0].windows.map(\.restoresBlankTab), [false, true, true])
        XCTAssertEqual(groups[0].windows.map(\.wasSelected), [false, true, false])
    }

    func testASelectedStaleTabTransfersSelectionWithinItsWorkspace() throws {
        let groups = try XCTUnwrap(plan([
            entry(liveProject, conversation: liveConversation, group: 4, tab: 0),
            entry(liveProject, conversation: goneConversation, group: 4, tab: 1,
                  selected: true),
            entry(otherProject, conversation: UUID(), group: 7, tab: 0, selected: true),
        ], conversations: [liveConversation]))

        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups[0].windows.map(\.wasSelected), [true])
    }

    func testKeyTabWinsAConflictingSelectionAndKeepsItsOwnLayout() throws {
        let first = UUID(), focused = UUID()
        let firstLayout = WorkspaceWindowLayout(showsInspector: false)
        let focusedLayout = WorkspaceWindowLayout(
            showsInspector: true, inspectorPreferredWidth: 720)
        let groups = try XCTUnwrap(plan([
            entry(liveProject, conversation: first, group: 0, tab: 0,
                  selected: true, layout: firstLayout),
            entry(liveProject, conversation: focused, group: 0, tab: 1, key: true,
                  layout: focusedLayout),
        ], conversations: [first, focused]))

        XCTAssertEqual(groups[0].windows.map(\.conversationID), [first, focused])
        XCTAssertEqual(groups[0].windows.map(\.layout), [firstLayout, focusedLayout])
        XCTAssertEqual(groups[0].windows.map(\.wasKey), [false, true])
        XCTAssertEqual(groups[0].windows.map(\.wasSelected), [false, true])
    }

    func testAHomeSessionContainingOnlyMarkedBlankTabsIsRestorable() throws {
        let groups = try XCTUnwrap(plan([
            entry(nil, group: 0, tab: 0, selected: true, blank: true),
            entry(nil, group: 0, tab: 1, blank: true),
        ]))
        XCTAssertEqual(groups[0].windows.count, 2)
        XCTAssertTrue(groups[0].windows.allSatisfy(\.isHome))
        XCTAssertEqual(groups[0].windows.map(\.wasSelected), [true, false])
    }

    func testDuplicateConversationTabsCollapseAcrossFormerGroups() throws {
        let groups = try XCTUnwrap(plan([
            entry(liveProject, conversation: liveConversation, group: 0, tab: 0),
            entry(liveProject, conversation: liveConversation, group: 1, tab: 0),
        ]))
        XCTAssertEqual(groups.flatMap(\.windows).count, 1)
    }

    func testTheSameWorkspaceInTwoFormerGroupsBecomesOneTabGroup() throws {
        let second = UUID()
        let groups = try XCTUnwrap(plan([
            entry(liveProject, conversation: liveConversation, group: 0),
            entry(liveProject, conversation: second, group: 1),
        ], conversations: [liveConversation, second]))
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups.flatMap(\.windows).count, 2)
        XCTAssertEqual(groups[0].windows.map(\.conversationID), [liveConversation, second])
    }

    func testHomeInTwoFormerGroupsBecomesOneTabGroup() throws {
        let second = UUID()
        let groups = try XCTUnwrap(plan([
            entry(nil, conversation: liveConversation, group: 0),
            entry(nil, conversation: second, group: 1),
        ], conversations: [liveConversation, second]))
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups[0].windows.map(\.conversationID), [liveConversation, second])
        XCTAssertTrue(groups[0].windows.allSatisfy(\.isHome))
    }

    /// One Workspace can still have several real Conversation tabs; only blank/missing tabs vanish.
    func testAThreeTabGroupOnOneWorkspaceComesBackWhole() throws {
        let second = UUID(), third = UUID()
        let groups = WorkspaceSessionPlan.restore(
            ledger: WorkspaceSessionLedger(windows: [
                entry(liveProject, conversation: liveConversation, group: 0, tab: 0),
                entry(liveProject, conversation: second, group: 0, tab: 1),
                entry(liveProject, conversation: third, group: 0, tab: 2),
            ]),
            projectExists: { $0 == self.liveProject },
            conversationExists: { _ in true },
            conversationBelongsToWorkspace: { _, _ in true })
        XCTAssertEqual(groups?.count, 1)
        XCTAssertEqual(groups?[0].windows.map(\.conversationID), [liveConversation, second, third])
    }

    func testTabsComeBackInRecordedOrderWhenFormerGroupsMerge() throws {
        let a = UUID(), b = UUID(), c = UUID()
        let groups = WorkspaceSessionPlan.restore(
            ledger: WorkspaceSessionLedger(windows: [
                entry(liveProject, conversation: c, group: 9, tab: 0),
                entry(liveProject, conversation: a, group: 7, tab: 0),
                entry(liveProject, conversation: b, group: 7, tab: 1),
            ]),
            projectExists: { $0 == self.liveProject },
            conversationExists: { _ in true },
            conversationBelongsToWorkspace: { _, _ in true })
        // Sparse, non-zero group indices must work too: replay renumbers rather than trusting them.
        XCTAssertEqual(groups?.count, 1)
        XCTAssertEqual(groups?[0].windows.map(\.conversationID), [a, b, c])
    }

    func testEqualRecordedIndicesPreserveLedgerOrder() throws {
        let first = UUID(), second = UUID(), third = UUID()
        let groups = try XCTUnwrap(plan([
            entry(liveProject, conversation: first, group: 2, tab: 4),
            entry(liveProject, conversation: second, group: 2, tab: 4),
            entry(liveProject, conversation: third, group: 2, tab: 4),
        ], conversations: [first, second, third]))
        XCTAssertEqual(groups[0].windows.map(\.conversationID), [first, second, third])
    }

    func testARecordedGroupMixingWorkspacesIsSplitByCanonicalWorkspace() throws {
        let homeConversation = UUID()
        let groups = try XCTUnwrap(plan([
            entry(liveProject, conversation: liveConversation, group: 0, tab: 0),
            entry(nil, conversation: homeConversation, group: 0, tab: 1),
        ], conversations: [liveConversation, homeConversation]))
        XCTAssertEqual(groups.count, 2)
        XCTAssertEqual(groups[0].windows.map(\.projectID), [liveProject])
        XCTAssertTrue(groups[1].windows.allSatisfy(\.isHome))
    }

    func testFocusTransfersFromAStaleTabToItsSurvivingWorkspace() throws {
        let projectConversation = UUID()
        let groups = try XCTUnwrap(plan([
            entry(liveProject, conversation: projectConversation, group: 0),
            entry(nil, conversation: goneConversation, group: 1, key: true),
            entry(nil, conversation: liveConversation, group: 2),
        ], conversations: [projectConversation, liveConversation]))
        let keyed = groups.flatMap(\.windows).filter(\.wasKey)
        XCTAssertEqual(keyed.count, 1)
        XCTAssertTrue(try XCTUnwrap(keyed.first).isHome)
        XCTAssertEqual(keyed.first?.conversationID, liveConversation)
    }

    func testExactDurableKeyTabKeepsFocusWhenGroupsMerge() throws {
        let first = UUID(), focused = UUID(), last = UUID()
        let groups = try XCTUnwrap(plan([
            entry(liveProject, conversation: first, group: 0),
            entry(liveProject, conversation: focused, group: 1, key: true),
            entry(liveProject, conversation: last, group: 2),
        ], conversations: [first, focused, last]))
        let keyed = groups.flatMap(\.windows).filter(\.wasKey)
        XCTAssertEqual(keyed.count, 1)
        XCTAssertEqual(keyed.first?.conversationID, focused)
    }

    /// The never-empty guarantee: when nothing in the ledger still exists, the caller falls back to
    /// `openLastLocationOrHome()` rather than opening a session of zero windows.
    func testALedgerNamingOnlyDeletedWorkspacesPlansNothing() {
        XCTAssertNil(plan([
            entry(goneProject, conversation: liveConversation, group: 0),
            entry(goneProject, conversation: liveConversation, group: 1),
        ]))
    }

    func testALedgerContainingOnlyStaleTabsPlansNothing() {
        XCTAssertNil(plan([
            entry(nil, conversation: goneConversation, group: 0),
            entry(liveProject, group: 1),
        ]))
    }

    /// A legacy cwd-only record is upgraded to the existing Project id and then joins any explicit
    /// entry for that same canonical Workspace.
    func testAFolderWorkspaceKeepsItsWorkingDirectory() throws {
        let second = UUID()
        let groups = try XCTUnwrap(WorkspaceSessionPlan.restore(
            ledger: WorkspaceSessionLedger(windows: [
                entry(liveProject, conversation: liveConversation, group: 0),
                entry(nil, conversation: second, cwd: "/Users/x/dev/acorn", group: 1),
            ]),
            projectExists: { $0 == self.liveProject },
            conversationExists: { _ in true },
            projectIDForLegacyCwd: { $0 == "/Users/x/dev/acorn" ? self.liveProject : nil },
            conversationBelongsToWorkspace: { _, _ in true }))
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups[0].windows.map(\.projectID), [liveProject, liveProject])
        XCTAssertEqual(groups[0].windows[1].cwd, "/Users/x/dev/acorn")
        XCTAssertFalse(groups[0].windows[1].isHome, "a cwd-only entry is a folder workspace, not Home")
    }

    func testUnknownLegacyFolderDoesNotRecreateARemovedWorkspace() {
        XCTAssertNil(WorkspaceSessionPlan.restore(
            ledger: WorkspaceSessionLedger(windows: [
                entry(nil, conversation: liveConversation, cwd: "/removed/workspace"),
            ]),
            projectExists: { _ in false },
            conversationExists: { _ in true },
            projectIDForLegacyCwd: { _ in nil },
            conversationBelongsToWorkspace: { _, _ in true }))
    }
}

final class WorkspaceSessionCaptureTests: XCTestCase {
    func testPendingDurableConversationSurvivesWithoutACurrentSelection() {
        let pending = UUID()
        XCTAssertEqual(WorkspaceSessionCapture.durableConversationID(
            currentID: nil,
            pendingSelectionID: pending,
            openingConversationID: nil,
            isDurable: { $0 == pending }), pending)
    }

    func testOpeningDurableConversationSurvivesAStaleCurrentPlaceholder() {
        let placeholder = UUID()
        let opening = UUID()
        XCTAssertEqual(WorkspaceSessionCapture.durableConversationID(
            currentID: placeholder,
            pendingSelectionID: nil,
            openingConversationID: opening,
            isDurable: { $0 == opening }), opening)
    }

    func testDurableCurrentConversationWinsOverPendingAndOpeningCandidates() {
        let current = UUID()
        let pending = UUID()
        let opening = UUID()
        XCTAssertEqual(WorkspaceSessionCapture.durableConversationID(
            currentID: current,
            pendingSelectionID: pending,
            openingConversationID: opening,
            isDurable: { _ in true }), current)
    }

    func testNoDurableCaptureCandidateReturnsNil() {
        XCTAssertNil(WorkspaceSessionCapture.durableConversationID(
            currentID: UUID(),
            pendingSelectionID: UUID(),
            openingConversationID: UUID(),
            isDurable: { _ in false }))
    }

    func testASettledEmptyWindowAndAPrunedPlaceholderRestoreAsBlankTabs() {
        XCTAssertTrue(WorkspaceSessionCapture.restoresBlankTab(
            currentID: nil,
            pendingSelectionID: nil,
            openingConversationID: nil,
            initialViewResolutionPending: false,
            isDurable: { _ in false }))

        let prunedPlaceholder = UUID()
        XCTAssertTrue(WorkspaceSessionCapture.restoresBlankTab(
            currentID: prunedPlaceholder,
            pendingSelectionID: nil,
            openingConversationID: nil,
            initialViewResolutionPending: false,
            isDurable: { $0 != prunedPlaceholder }))
    }

    func testDurableOrStillResolvingWindowsAreNeverReclassifiedAsBlank() {
        let durable = UUID(), pending = UUID(), opening = UUID()
        XCTAssertFalse(WorkspaceSessionCapture.restoresBlankTab(
            currentID: durable,
            pendingSelectionID: nil,
            openingConversationID: nil,
            initialViewResolutionPending: false,
            isDurable: { $0 == durable }))
        XCTAssertFalse(WorkspaceSessionCapture.restoresBlankTab(
            currentID: nil,
            pendingSelectionID: pending,
            openingConversationID: nil,
            initialViewResolutionPending: false,
            isDurable: { _ in false }))
        XCTAssertFalse(WorkspaceSessionCapture.restoresBlankTab(
            currentID: nil,
            pendingSelectionID: nil,
            openingConversationID: opening,
            initialViewResolutionPending: false,
            isDurable: { _ in false }))
        XCTAssertFalse(WorkspaceSessionCapture.restoresBlankTab(
            currentID: nil,
            pendingSelectionID: nil,
            openingConversationID: nil,
            initialViewResolutionPending: true,
            isDurable: { _ in false }))
    }
}
