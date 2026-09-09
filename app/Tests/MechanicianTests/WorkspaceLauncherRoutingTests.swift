import Foundation
import XCTest
@testable import Mechanician

/// Issue #45: the shared Workspaces gallery routed through the process-wide "last key workspace
/// window", so picking a Workspace could rewrite a window the user was not looking at and pull
/// focus to it across Spaces, ending with two windows bound to one Workspace.
final class WorkspaceLauncherRoutingTests: XCTestCase {
    private let sdi = UUID()
    private let mechanician = UUID()

    private func window(
        _ projectID: UUID? = nil,
        cwd: String = "",
        hasWindow: Bool = true
    ) -> WorkspaceWindowIdentity {
        WorkspaceWindowIdentity(
            bridgeID: UUID(), projectID: projectID, cwd: cwd, hasWindow: hasWindow)
    }

    func testAnOpenWindowForTheWorkspaceIsAlwaysPreferred() {
        let owner = window(sdi)
        let other = window(mechanician)
        XCTAssertEqual(
            WorkspaceLauncherRouting.route(
                projectID: sdi,
                cwd: "",
                originBridgeID: other.bridgeID,
                among: [other, owner]),
            .focus(owner.bridgeID),
            "one Workspace, one native group: never repurpose a second group for it")
    }

    /// The reproduction from the issue. The user acts from one window while a different window was
    /// key last; the gallery must not rewrite that other window.
    func testTheCapturedOriginIsReplacedRatherThanWhicheverWindowWasKeyLast() {
        let acting = window(mechanician)
        let unrelated = window(nil, cwd: "/tmp/unrelated")
        let route = WorkspaceLauncherRouting.route(
            projectID: sdi,
            cwd: "",
            originBridgeID: acting.bridgeID,
            among: [unrelated, acting])
        XCTAssertEqual(route, .replaceOrigin(acting.bridgeID))
        if case .replaceOrigin(let id) = route {
            XCTAssertNotEqual(id, unrelated.bridgeID)
        }
    }

    func testAMissingOrClosedOriginOpensInsteadOfMutatingAnArbitraryWindow() {
        let unrelated = window(mechanician)
        XCTAssertEqual(
            WorkspaceLauncherRouting.route(
                projectID: sdi, cwd: "", originBridgeID: nil, among: [unrelated]),
            .openWorkspace)
        XCTAssertEqual(
            WorkspaceLauncherRouting.route(
                projectID: sdi, cwd: "", originBridgeID: UUID(), among: [unrelated]),
            .openWorkspace,
            "a closed origin must fall through to focus-or-create")
        let closedOrigin = window(mechanician, hasWindow: false)
        XCTAssertEqual(
            WorkspaceLauncherRouting.route(
                projectID: sdi,
                cwd: "",
                originBridgeID: closedOrigin.bridgeID,
                among: [closedOrigin]),
            .openWorkspace)
    }

    /// The predicate had four spellings and one omitted this guard, so a folder Workspace could
    /// claim a window already bound to a topic Workspace that merely sits in the same directory.
    func testAFolderWorkspaceDoesNotClaimATopicWindowInTheSameDirectory() {
        let topicWindowInFolder = window(mechanician, cwd: "/code/sdi")
        XCTAssertNil(
            WorkspaceLauncherRouting.owner(
                ofProjectID: sdi, cwd: "/code/sdi", among: [topicWindowInFolder]))
        let folderWindow = window(nil, cwd: "/code/sdi")
        XCTAssertEqual(
            WorkspaceLauncherRouting.owner(
                ofProjectID: sdi, cwd: "/code/sdi", among: [topicWindowInFolder, folderWindow]),
            folderWindow)
    }

    func testATopicWorkspaceMatchesOnIdentityNotDirectory() {
        let sameFolderDifferentTopic = window(mechanician, cwd: "/code/sdi")
        let topicWindow = window(sdi, cwd: "/code/sdi")
        XCTAssertEqual(
            WorkspaceLauncherRouting.owner(
                ofProjectID: sdi, cwd: "", among: [sameFolderDifferentTopic, topicWindow]),
            topicWindow)
    }

    func testClosedWindowsAreNeverOffered() {
        let closed = window(sdi, hasWindow: false)
        XCTAssertNil(
            WorkspaceLauncherRouting.owner(ofProjectID: sdi, cwd: "", among: [closed]))
        XCTAssertNil(WorkspaceLauncherRouting.homeOwner(among: [closed]))
    }

    func testHomeFollowsTheSameRules() {
        let home = window(nil, cwd: "")
        let folder = window(nil, cwd: "/code/sdi")
        XCTAssertEqual(
            WorkspaceLauncherRouting.homeRoute(
                originBridgeID: folder.bridgeID, among: [folder, home]),
            .focus(home.bridgeID))
        XCTAssertEqual(
            WorkspaceLauncherRouting.homeRoute(
                originBridgeID: folder.bridgeID, among: [folder]),
            .replaceOrigin(folder.bridgeID))
        XCTAssertEqual(
            WorkspaceLauncherRouting.homeRoute(originBridgeID: nil, among: [folder]),
            .openWorkspace,
            "Home must not be forced onto whichever window was key last")
    }
}

final class WorkspaceTabRoutingTests: XCTestCase {
    private func window(
        _ projectID: UUID? = nil,
        cwd: String = "",
        hasWindow: Bool = true
    ) -> WorkspaceWindowIdentity {
        WorkspaceWindowIdentity(
            bridgeID: UUID(), projectID: projectID, cwd: cwd, hasWindow: hasWindow)
    }

    private func conversation(
        cwd: String,
        projectID: UUID? = nil,
        modelSelection: ModelSelection? = nil
    ) -> Conversation {
        Conversation(
            title: "Source",
            cwd: cwd,
            sdkSessionId: nil,
            modelSelection: modelSelection,
            messages: [],
            updatedAt: Date(),
            projectID: projectID)
    }

    func testTheKeyWorkspaceWinsOverThePreviouslyActiveWorkspace() {
        let key = window(), active = window()
        XCTAssertEqual(
            WorkspaceTabRouting.sourceBridgeID(
                keyWindowBridgeID: key.bridgeID,
                activeBridgeID: active.bridgeID,
                among: [active, key]),
            key.bridgeID)
    }

    func testAUtilityKeyWindowFallsBackToTheActiveWorkspace() {
        let active = window(), other = window()
        XCTAssertEqual(
            WorkspaceTabRouting.sourceBridgeID(
                keyWindowBridgeID: nil,
                activeBridgeID: active.bridgeID,
                among: [other, active]),
            active.bridgeID)
    }

    func testAClosedActiveWorkspaceFallsBackToAnotherLiveWorkspace() {
        let closed = window(hasWindow: false), live = window()
        XCTAssertEqual(
            WorkspaceTabRouting.sourceBridgeID(
                keyWindowBridgeID: closed.bridgeID,
                activeBridgeID: closed.bridgeID,
                among: [closed, live]),
            live.bridgeID)
    }

    func testNoLiveWorkspaceProducesNoTabHost() {
        let closed = window(hasWindow: false)
        XCTAssertNil(
            WorkspaceTabRouting.sourceBridgeID(
                keyWindowBridgeID: nil,
                activeBridgeID: closed.bridgeID,
                among: [closed]))
    }

    /// Each new window receives its own immutable launch payload. A second ⌘T must not overwrite
    /// the first tab's source workspace while either bridge is still starting.
    func testTwoRapidFreshTabIntentsKeepTheirDistinctSourceScopes() {
        let folder = window(cwd: "/code/folder")
        let topicID = UUID()
        let topic = window(topicID)
        let folderSelection = ModelSelection(access: .claudeSubscription, modelID: "claude-folder")
        let topicSelection = ModelSelection(access: .openAIAPI, modelID: "gpt-topic")

        let folderIntent = WorkspaceTabRouting.intent(
            source: folder,
            initialConversationID: nil,
            sourceModelSelection: folderSelection)
        let topicIntent = WorkspaceTabRouting.intent(
            source: topic,
            initialConversationID: nil,
            sourceModelSelection: topicSelection)

        XCTAssertEqual(folderIntent.initialFolder, "/code/folder")
        XCTAssertNil(folderIntent.initialProjectID)
        XCTAssertTrue(folderIntent.startsFreshConversation)
        XCTAssertEqual(folderIntent.initialFreshModelSelection, folderSelection)

        XCTAssertNil(topicIntent.initialFolder)
        XCTAssertEqual(topicIntent.initialProjectID, topicID)
        XCTAssertTrue(topicIntent.startsFreshConversation)
        XCTAssertEqual(topicIntent.initialFreshModelSelection, topicSelection)
    }

    func testAHomeTabCarriesAnExplicitHomeScopeInItsOwnIntent() {
        let intent = WorkspaceTabRouting.intent(
            source: window(),
            initialConversationID: nil)

        XCTAssertNil(intent.initialFolder)
        XCTAssertNil(intent.initialProjectID)
        XCTAssertNil(intent.initialConversationID)
        XCTAssertTrue(intent.startsFreshConversation)
        XCTAssertNil(intent.initialFreshModelSelection)
    }

    func testAFreshTabCarriesTheCurrentConversationModelOnlyForItsCanonicalWorkspace() {
        let workspace = Project(name: "Workspace", cwd: "/code/workspace")
        let source = window(cwd: workspace.cwd)
        let selection = ModelSelection(access: .claudeSubscription, modelID: "claude-source")
        let current = conversation(
            cwd: workspace.cwd,
            projectID: workspace.id,
            modelSelection: selection)

        let carried = WorkspaceTabRouting.freshConversationModelSelection(
            source: source,
            sourceConversation: current,
            projects: [workspace])
        let intent = WorkspaceTabRouting.intent(
            source: source,
            initialConversationID: nil,
            sourceModelSelection: carried)

        XCTAssertEqual(carried, selection)
        XCTAssertEqual(intent.initialFreshModelSelection, selection)
    }

    func testAFreshTabUsesTheProjectedModelForALegacyConversationInTheSameWorkspace() {
        let workspace = Project(name: "Workspace", cwd: "/code/workspace")
        let source = window(cwd: workspace.cwd)
        let legacy = conversation(cwd: workspace.cwd, projectID: workspace.id)
        let projected = ModelSelection(access: .openAIAPI, modelID: "gpt-current")

        XCTAssertEqual(
            WorkspaceTabRouting.freshConversationModelSelection(
                source: source,
                sourceConversation: legacy,
                sourceProjectedSelection: projected,
                projects: [workspace]),
            projected)
    }

    func testAFreshTabFallsBackWhenTheVisibleConversationIsElsewhereOrNoSourceExists() {
        let workspace = Project(name: "Workspace", cwd: "/code/workspace")
        let source = window(cwd: workspace.cwd)
        let elsewhere = conversation(
            cwd: "",
            modelSelection: ModelSelection(access: .openAIAPI, modelID: "gpt-elsewhere"))

        XCTAssertNil(WorkspaceTabRouting.freshConversationModelSelection(
            source: source,
            sourceConversation: elsewhere,
            sourceProjectedSelection: ModelSelection(access: .claudeSubscription, modelID: "claude-source"),
            projects: [workspace]))
        XCTAssertNil(WorkspaceTabRouting.freshConversationModelSelection(
            source: nil,
            sourceConversation: elsewhere,
            sourceProjectedSelection: ModelSelection(access: .claudeSubscription, modelID: "claude-source"),
            projects: [workspace]))
    }

    /// A named request is bound to this one new window and suppresses the ordinary fresh-tab rule.
    func testANamedConversationRequestIsPerWindowAndNotFresh() {
        let conversationID = UUID()
        let folder = window(cwd: "/code/folder")

        let intent = WorkspaceTabRouting.intent(
            source: folder,
            initialConversationID: conversationID,
            sourceModelSelection: ModelSelection(access: .claudeSubscription, modelID: "ignored"))

        XCTAssertEqual(intent.initialFolder, "/code/folder")
        XCTAssertNil(intent.initialProjectID)
        XCTAssertEqual(intent.initialConversationID, conversationID)
        XCTAssertFalse(intent.startsFreshConversation)
        XCTAssertNil(intent.initialFreshModelSelection)
    }
}
