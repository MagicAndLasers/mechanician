import AppKit
import XCTest
@testable import Mechanician

@MainActor
final class HelpDemonstrationRouteTests: XCTestCase {
    private func conversation(
        id: UUID,
        projectID: UUID? = nil,
        draft: String = ""
    ) -> Conversation {
        Conversation(
            id: id,
            title: "Help demonstration route",
            cwd: "",
            sdkSessionId: nil,
            messages: [],
            updatedAt: Date(),
            draft: draft,
            projectID: projectID)
    }

    private func bridge(named name: String) -> (AgentBridge, URL, NSWindow) {
        let support = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(name)-\(UUID().uuidString)", isDirectory: true)
        let bridge = AgentBridge(settingsBaseOverride: support, environmentOverride: [:])
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
            styleMask: [.titled],
            backing: .buffered,
            defer: false)
        bridge.window = window
        return (bridge, support, window)
    }

    private func removeConversations(_ ids: [UUID?]) {
        let store = ConversationStore.shared
        for id in ids.compactMap({ $0 }) { store.remove(id) }
        store.flushSaves()
    }

    func testSignedOutDraftIsCreatedLocallyAndNeverSent() {
        _ = NSApplication.shared
        let store = ConversationStore.shared
        let destinationSeedID = UUID()
        let otherSeedID = UUID()
        let (destination, destinationSupport, destinationWindow) = bridge(
            named: "help-demo-destination")
        let (other, otherSupport, otherWindow) = bridge(named: "help-demo-other")
        var createdID: UUID?
        defer {
            destination.currentID = nil
            other.currentID = nil
            destination.window = nil
            other.window = nil
            destination.shutdown()
            other.shutdown()
            destinationWindow.orderOut(nil)
            otherWindow.orderOut(nil)
            removeConversations([destinationSeedID, otherSeedID, createdID])
            try? FileManager.default.removeItem(at: destinationSupport)
            try? FileManager.default.removeItem(at: otherSupport)
        }

        store.upsert(conversation(id: destinationSeedID))
        store.upsert(conversation(id: otherSeedID))
        destination.currentID = destinationSeedID
        destination.isReady = false
        other.currentID = otherSeedID
        other.isReady = true

        let active = ActiveWorkspace(
            productAccessRequest: { true },
            whenProductReady: { $0() })
        active.bridge = destination
        XCTAssertTrue(active.open(.newStandardConversationDraft("Show me saved capabilities")))
        createdID = destination.currentID

        XCTAssertNil(active.pendingPrompt)
        XCTAssertNil(active.pendingDraft)
        XCTAssertEqual(other.currentID, otherSeedID)
        XCTAssertEqual(store.conversation(otherSeedID)?.draft, "")

        XCTAssertNotEqual(createdID, destinationSeedID)
        XCTAssertEqual(store.conversation(createdID)?.draft, "Show me saved capabilities")
        XCTAssertEqual(store.conversation(createdID)?.messages, [])
        XCTAssertFalse(destination.isReady)
        XCTAssertNil(active.pendingPrompt)
    }

    func testPendingDraftIsConsumedOnlyByItsExactBridge() {
        _ = NSApplication.shared
        let store = ConversationStore.shared
        let otherSeedID = UUID()
        let (destination, destinationSupport, destinationWindow) = bridge(
            named: "help-demo-pending-destination")
        let (other, otherSupport, otherWindow) = bridge(named: "help-demo-pending-other")
        var createdID: UUID?
        defer {
            destination.currentID = nil
            other.currentID = nil
            destination.window = nil
            other.window = nil
            destination.shutdown()
            other.shutdown()
            destinationWindow.orderOut(nil)
            otherWindow.orderOut(nil)
            removeConversations([otherSeedID, createdID])
            try? FileManager.default.removeItem(at: destinationSupport)
            try? FileManager.default.removeItem(at: otherSupport)
        }

        store.upsert(conversation(id: otherSeedID))
        destination.isReady = false
        other.currentID = otherSeedID
        other.isReady = true

        let active = ActiveWorkspace(
            productAccessRequest: { true },
            whenProductReady: { $0() })
        active.bridge = destination
        active.pendingPrompt = "Keep this provider-gated"
        XCTAssertTrue(active.open(.newStandardConversationDraft("Show me saved capabilities")))

        // Readiness in another standard lane is not authority to take this Help handoff.
        active.consumePendingStandardConversationDrafts(other)
        XCTAssertNil(destination.currentID)
        XCTAssertEqual(other.currentID, otherSeedID)
        XCTAssertEqual(store.conversation(otherSeedID)?.draft, "")
        XCTAssertEqual(active.pendingPrompt, "Keep this provider-gated")

        // Local presentation can consume the draft while the provider remains signed out.
        active.consumePendingStandardConversationDrafts(destination)
        createdID = destination.currentID
        XCTAssertNotNil(createdID)
        XCTAssertEqual(store.conversation(createdID)?.draft, "Show me saved capabilities")
        XCTAssertEqual(store.conversation(createdID)?.messages, [])
        XCTAssertFalse(destination.isReady)
        XCTAssertEqual(active.pendingPrompt, "Keep this provider-gated")
    }

    func testMemoryTargetFallsBackToHomeWithoutWideningMemoryProfile() {
        _ = NSApplication.shared
        let store = ConversationStore.shared
        let helpID = UUID()
        let homeSeedID = UUID()
        let (help, helpSupport, helpWindow) = bridge(named: "help-demo-help")
        let (home, homeSupport, homeWindow) = bridge(named: "help-demo-home")
        var createdHomeID: UUID?
        defer {
            help.currentID = nil
            home.currentID = nil
            help.window = nil
            home.window = nil
            help.shutdown()
            home.shutdown()
            helpWindow.orderOut(nil)
            homeWindow.orderOut(nil)
            removeConversations([helpID, homeSeedID, createdHomeID])
            try? FileManager.default.removeItem(at: helpSupport)
            try? FileManager.default.removeItem(at: homeSupport)
        }

        store.upsert(conversation(id: helpID, projectID: HelpWorkspace.id))
        store.upsert(conversation(id: homeSeedID))
        help.projectID = HelpWorkspace.id
        help.currentID = helpID
        help.isReady = true
        home.currentID = homeSeedID
        home.isReady = true
        AgentBridge.live.add(help)
        AgentBridge.live.add(home)

        let active = ActiveWorkspace(
            productAccessRequest: { true },
            whenProductReady: { $0() })
        active.bridge = help
        XCTAssertTrue(active.open(.newStandardConversationDraft("Demonstrate a Shortcut")))
        createdHomeID = home.currentID

        XCTAssertEqual(help.currentID, helpID)
        XCTAssertEqual(store.conversation(helpID)?.draft, "")
        XCTAssertEqual(
            AgentBridge.toolProfile(for: try! XCTUnwrap(store.conversation(helpID))),
            .helpExpert)
        XCTAssertNotEqual(createdHomeID, homeSeedID)
        XCTAssertEqual(store.conversation(createdHomeID)?.draft, "Demonstrate a Shortcut")
        XCTAssertEqual(
            AgentBridge.toolProfile(for: try! XCTUnwrap(store.conversation(createdHomeID))),
            .standard)
        XCTAssertEqual(store.conversation(createdHomeID)?.messages, [])
    }

    func testPendingHomeDraftRejectsSwitchToOrdinaryProject() {
        _ = NSApplication.shared
        let store = ConversationStore.shared
        let homeSeedID = UUID()
        let project = Project(name: "Help draft switch target")
        let (destination, destinationSupport, destinationWindow) = bridge(
            named: "help-demo-switch-destination")
        let (home, homeSupport, homeWindow) = bridge(named: "help-demo-switch-home")
        var createdHomeID: UUID?
        var madeFreshHome = false
        ProjectStore.shared.upsert(project)
        defer {
            ProjectStore.shared.remove(project.id)
            destination.currentID = nil
            home.currentID = nil
            destination.window = nil
            home.window = nil
            destination.shutdown()
            home.shutdown()
            destinationWindow.orderOut(nil)
            homeWindow.orderOut(nil)
            removeConversations([homeSeedID, createdHomeID])
            try? FileManager.default.removeItem(at: destinationSupport)
            try? FileManager.default.removeItem(at: homeSupport)
        }

        store.upsert(conversation(id: homeSeedID))
        home.currentID = homeSeedID
        home.isReady = false

        let active = ActiveWorkspace(
            productAccessRequest: { true },
            whenProductReady: { $0() },
            makeFreshHomeWorkspace: {
                madeFreshHome = true
                return home
            })
        active.bridge = destination
        XCTAssertTrue(active.open(.newStandardConversationDraft("Demonstrate a Shortcut")))
        XCTAssertNil(destination.currentID)

        // The request was bound to Home. Retargeting the same bridge/window to another ordinary
        // standard-profile Project must not transfer the pending Help request into that Project.
        destination.projectID = project.id
        destination.cwd = ""
        active.consumePendingStandardConversationDrafts(destination)
        createdHomeID = home.currentID

        XCTAssertTrue(madeFreshHome)
        XCTAssertNil(destination.currentID)
        XCTAssertNotEqual(createdHomeID, homeSeedID)
        XCTAssertEqual(store.conversation(createdHomeID)?.projectID, nil)
        XCTAssertEqual(store.conversation(createdHomeID)?.draft, "Demonstrate a Shortcut")
        XCTAssertEqual(store.conversation(createdHomeID)?.messages, [])
    }

    func testHelpOnlyFallbackUsesExplicitFreshHomeFactory() {
        _ = NSApplication.shared
        let store = ConversationStore.shared
        let homeSeedID = UUID()
        let (home, homeSupport, homeWindow) = bridge(named: "help-demo-help-only-home")
        var createdHomeID: UUID?
        var madeFreshHome = false
        defer {
            home.currentID = nil
            home.window = nil
            home.shutdown()
            homeWindow.orderOut(nil)
            removeConversations([homeSeedID, createdHomeID])
            try? FileManager.default.removeItem(at: homeSupport)
        }

        store.upsert(conversation(id: homeSeedID))
        home.currentID = homeSeedID
        home.isReady = false

        let active = ActiveWorkspace(
            productAccessRequest: { true },
            whenProductReady: { $0() },
            makeFreshHomeWorkspace: {
                madeFreshHome = true
                return home
            })
        XCTAssertNil(active.bridge)
        XCTAssertTrue(active.open(.newStandardConversationDraft("Show me app actions")))
        createdHomeID = home.currentID

        XCTAssertTrue(madeFreshHome)
        XCTAssertNotEqual(createdHomeID, homeSeedID)
        XCTAssertEqual(store.conversation(createdHomeID)?.projectID, nil)
        XCTAssertEqual(store.conversation(createdHomeID)?.draft, "Show me app actions")
        XCTAssertEqual(store.conversation(createdHomeID)?.messages, [])
        XCTAssertFalse(home.isReady)
    }

    func testUnresolvedProjectLeavesOldDraftUntouchedAndFallsBackHome() {
        _ = NSApplication.shared
        let store = ConversationStore.shared
        let unresolvedProjectID = UUID()
        let oldID = UUID()
        let homeSeedID = UUID()
        let (unresolved, unresolvedSupport, unresolvedWindow) = bridge(
            named: "help-demo-unresolved")
        let (home, homeSupport, homeWindow) = bridge(named: "help-demo-unresolved-home")
        var createdHomeID: UUID?
        defer {
            unresolved.currentID = nil
            home.currentID = nil
            unresolved.window = nil
            home.window = nil
            unresolved.shutdown()
            home.shutdown()
            unresolvedWindow.orderOut(nil)
            homeWindow.orderOut(nil)
            removeConversations([oldID, homeSeedID, createdHomeID])
            try? FileManager.default.removeItem(at: unresolvedSupport)
            try? FileManager.default.removeItem(at: homeSupport)
        }

        store.upsert(conversation(
            id: oldID,
            projectID: unresolvedProjectID,
            draft: "Keep this draft"))
        store.upsert(conversation(id: homeSeedID))
        unresolved.projectID = unresolvedProjectID
        unresolved.currentID = oldID
        unresolved.isReady = false
        home.currentID = homeSeedID
        home.isReady = false

        let active = ActiveWorkspace(
            productAccessRequest: { true },
            whenProductReady: { $0() },
            makeFreshHomeWorkspace: { home })
        active.bridge = unresolved
        XCTAssertTrue(active.open(.newStandardConversationDraft("Demonstrate an artifact")))
        createdHomeID = home.currentID

        XCTAssertEqual(unresolved.currentID, oldID)
        XCTAssertEqual(store.conversation(oldID)?.draft, "Keep this draft")
        XCTAssertNotEqual(createdHomeID, homeSeedID)
        XCTAssertEqual(store.conversation(createdHomeID)?.draft, "Demonstrate an artifact")
        XCTAssertEqual(store.conversation(createdHomeID)?.messages, [])
    }

    func testDraftCreationRequiresANewDistinctConversationID() {
        let oldID = UUID()
        let newID = UUID()

        XCTAssertNil(standardConversationDraftCreatedID(previousID: nil, currentID: nil))
        XCTAssertNil(standardConversationDraftCreatedID(previousID: oldID, currentID: oldID))
        XCTAssertEqual(
            standardConversationDraftCreatedID(previousID: oldID, currentID: newID),
            newID)
    }

    func testInternalStandardDraftHasNoURLSpelling() throws {
        let scheme = "mechanician"
        XCTAssertNil(MechanicianURL.link(
            for: .newStandardConversationDraft("Demonstrate a capability"),
            scheme: scheme))

        let url = try XCTUnwrap(URL(
            string: "mechanician://conversation/new?text=Demonstrate%20a%20capability"))
        guard case .newConversationDraft(let text)? = MechanicianURL.route(
            for: url,
            scheme: scheme) else {
            return XCTFail("External URL prefill must remain on the external draft route")
        }
        XCTAssertEqual(text, "Demonstrate a capability")
    }
}
