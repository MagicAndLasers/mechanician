import Foundation
import XCTest
@testable import Mechanician

/// The inspector's width belongs to the workspace, not to the app.
///
/// It was one number for every workspace, which is only defensible while every tab wants the same
/// room. A document panel ended that: an article at 360pt is left about 230pt of text, and widening
/// the one shared number would widen the folder workspace someone was working in — so nobody did.
final class InspectorWidthPreferenceTests: XCTestCase {

    private var store: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "inspector-width-\(UUID().uuidString)"
        store = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        store.removePersistentDomain(forName: suiteName)
        store = nil
        suiteName = nil
        super.tearDown()
    }

    func testDocumentWorkspacesOpenWider() {
        XCTAssertEqual(InspectorWidthPreference.default(workspaceID: HelpWorkspace.id), 560)
        // Not wider than that by default: 720 left a 1566pt window's chat at about 500pt, which
        // pushed the composer's control bar into the tier meant for narrow windows.
        XCTAssertGreaterThanOrEqual(
            InspectorWidthPreference.default(workspaceID: HelpWorkspace.id), 560,
            "and not narrower than an article panel's own minimum")
        XCTAssertEqual(InspectorWidthPreference.default(workspaceID: UUID()), 420)
        XCTAssertEqual(InspectorWidthPreference.default(workspaceID: nil), 420)
    }

    /// HOME IS A WORKSPACE. `projectID == nil` is the default workspace, not "nowhere to store
    /// this" — the same reasoning the tab preference already records.
    func testHomeGetsARealKeyRatherThanABucket() {
        XCTAssertEqual(
            InspectorWidthPreference.key(nil),
            InspectorWidthPreference.key(SQLiteLibraryStore.homeWorkspaceID))
        XCTAssertNotEqual(
            InspectorWidthPreference.key(nil), InspectorWidthPreference.key(HelpWorkspace.id))
    }

    func testEachWorkspaceKeepsItsOwnWidth() {
        let a = UUID(), b = UUID()
        InspectorWidthPreference.setWidth(500, workspaceID: a, store: store)
        InspectorWidthPreference.setWidth(900, workspaceID: b, store: store)
        XCTAssertEqual(InspectorWidthPreference.width(workspaceID: a, store: store), 500)
        XCTAssertEqual(InspectorWidthPreference.width(workspaceID: b, store: store), 900)
        XCTAssertEqual(
            InspectorWidthPreference.width(workspaceID: UUID(), store: store), 420,
            "a workspace nobody has dragged opens at its default")
    }

    func testTheFormerDefaultRemainsAStoredUserWidth() {
        let workspaceID = UUID()
        InspectorWidthPreference.setWidth(360, workspaceID: workspaceID, store: store)

        XCTAssertEqual(
            InspectorWidthPreference.width(workspaceID: workspaceID, store: store), 360,
            "changing the product default must not replace a width the person already chose")
    }

    func testFolderWorkspaceResolvesItsProjectInsteadOfUsingHome() {
        let folderProject = UUID()
        let resolved = InspectorWidthPreference.workspaceID(
            projectID: nil,
            cwd: "/Users/example/dev/project",
            projectIDForCwd: { $0 == "/Users/example/dev/project" ? folderProject : nil })

        XCTAssertEqual(resolved, folderProject)
        XCTAssertNotEqual(
            InspectorWidthPreference.key(resolved),
            InspectorWidthPreference.key(nil))
        XCTAssertEqual(
            InspectorWidthPreference.workspaceID(
                projectID: nil,
                cwd: "",
                projectIDForCwd: { _ in folderProject }),
            nil,
            "Home never asks the folder resolver for an identity")
    }

    func testTheDisplayedMinimumCanBePersistedWithoutJumpingBackOnRelaunch() {
        let workspaceID = UUID()
        InspectorWidthPreference.setWidth(InspectorWidthPreference.minimum,
                                          workspaceID: workspaceID, store: store)
        XCTAssertEqual(
            InspectorWidthPreference.width(workspaceID: workspaceID, store: store),
            InspectorWidthPreference.minimum)

        store.set(InspectorWidthPreference.minimum - 1,
                  forKey: InspectorWidthPreference.key(workspaceID))
        XCTAssertEqual(
            InspectorWidthPreference.width(workspaceID: workspaceID, store: store), 420)
    }

    /// A stored width outside the sane range is treated as ABSENT rather than clamped. A 0 or a NaN
    /// from a damaged plist should open the workspace at a usable size, not at a sliver the person
    /// then has to find and drag.
    func testAnUnusableStoredWidthIsIgnoredRatherThanHonoured() {
        for bad in [0.0, -100.0, 5.0, 99_000.0, Double.nan, Double.infinity] {
            store.set(bad, forKey: InspectorWidthPreference.key(HelpWorkspace.id))
            XCTAssertEqual(
                InspectorWidthPreference.width(workspaceID: HelpWorkspace.id, store: store), 560,
                "\(bad) must not open Help at an unusable size")
        }
        for bad in [0.0, -1.0, Double.nan] {
            InspectorWidthPreference.setWidth(bad, workspaceID: nil, store: store)
            XCTAssertEqual(InspectorWidthPreference.width(workspaceID: nil, store: store), 420)
        }
    }

    /// The one-time carry-over, applied to HOME ONLY. Spraying the old shared value across every
    /// workspace would also give it to the Help workspace, whose whole point is to open wider.
    func testTheOldSharedWidthIsCarriedOverToHomeAndNowhereElse() {
        store.set(520.0, forKey: "inspectorWidth")
        InspectorWidthPreference.migrateLegacyWidthIfNeeded(store: store)

        XCTAssertEqual(InspectorWidthPreference.width(workspaceID: nil, store: store), 520)
        XCTAssertEqual(
            InspectorWidthPreference.width(workspaceID: HelpWorkspace.id, store: store), 560,
            "Help keeps its own default")
        XCTAssertNil(store.object(forKey: "inspectorWidth"), "and the old key is retired")
    }

    /// Run twice — on every launch — it must not overwrite a width the person has since chosen.
    func testTheCarryOverNeverOverwritesAChoiceMadeAfterIt() {
        store.set(520.0, forKey: "inspectorWidth")
        InspectorWidthPreference.migrateLegacyWidthIfNeeded(store: store)
        InspectorWidthPreference.setWidth(400, workspaceID: nil, store: store)

        store.set(520.0, forKey: "inspectorWidth")
        InspectorWidthPreference.migrateLegacyWidthIfNeeded(store: store)
        XCTAssertEqual(InspectorWidthPreference.width(workspaceID: nil, store: store), 400)
    }

    func testResetClearsWorkspaceGeometryButPreservesUnrelatedPreferences() {
        store.set(420.0, forKey: InspectorWidthPreference.key(UUID()))
        store.set("agents", forKey: InspectorTabPreference.selectionKey(UUID()))
        store.set(310.0, forKey: "mech.ws.sidebar.fixture")
        store.set("saved frame", forKey: "NSWindow Frame mech.ws.frame.fixture")
        store.set(240.0, forKey: "terminalHeight")
        store.set(640.0, forKey: ArtifactWindowSplitSizing.preferenceKey)
        store.set("keep", forKey: "unrelated.preference")

        LayoutPreferenceReset.reset(store: store)

        XCTAssertFalse(store.dictionaryRepresentation().keys.contains {
            $0.hasPrefix(InspectorWidthPreference.keyPrefix)
                || $0.hasPrefix(InspectorTabPreference.selectionKeyPrefix)
                || $0.hasPrefix("mech.ws.sidebar.")
                || $0.hasPrefix("NSWindow Frame mech.ws.frame.")
        })
        XCTAssertNil(store.object(forKey: "terminalHeight"))
        XCTAssertNil(store.object(forKey: ArtifactWindowSplitSizing.preferenceKey))
        XCTAssertEqual(store.string(forKey: "unrelated.preference"), "keep")
    }
}
