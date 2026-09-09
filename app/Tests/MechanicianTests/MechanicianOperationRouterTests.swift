import AppKit
import XCTest
@testable import Mechanician

/// The agent operating the interface, rather than pointing at it.
///
/// These cover the boundary rather than the mechanics: what the vocabulary admits, where an
/// operation is allowed to land, and what it refuses with a reason the agent can repeat to the
/// person instead of retrying.
@MainActor
final class MechanicianOperationRouterTests: XCTestCase {
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

    private final class ConfiguredExtensions {
        var servers: [MCPServer] = []
        var applied: [(name: String, enabled: Bool)] = []
    }

    private final class OpenedWindows {
        var opened: [MechanicianOperationWindow] = []
        var succeeds = true
        /// Whether the window is considered to have actually appeared. The first live run reported
        /// a window it never opened, so the tests now separate "asked" from "appeared".
        var appears = true
    }

    private func ownedWindow(
        projectID: UUID? = nil,
        cwd: String = "",
        name: String = #function
    ) -> OwnedWindowFixture {
        _ = NSApplication.shared
        let support = FileManager.default.temporaryDirectory
            .appendingPathComponent("operate-\(name)-\(UUID().uuidString)", isDirectory: true)
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
            title: "Operation fixture",
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
        turnID: String = "turn-1",
        valid: @escaping @MainActor () -> Bool = { true }
    ) -> MechanicianOperationAdmission {
        MechanicianOperationAdmission(
            bridge: fixture.bridge,
            window: fixture.window,
            conversationID: fixture.bridge.currentID!,
            toolProfile: profile,
            turnID: turnID,
            revalidateTurn: valid)!
    }

    private func server(
        _ name: String,
        enabled: Bool = false,
        valid: Bool = true
    ) -> MCPServer {
        var server = MCPServer()
        server.name = name
        server.enabled = enabled
        server.transport = .stdio
        server.command = valid ? "/usr/bin/true" : ""
        return server
    }

    /// Drive one confirmation to its answer. The router parks on the bridge's continuation, so the
    /// card has to appear before anything can answer it — which is the seam worth testing.
    private func answerPendingChange(
        on bridge: AgentBridge,
        with answer: @escaping @MainActor (AgentBridge) -> Void
    ) async {
        for _ in 0..<200 {
            if bridge.pendingSettingChange != nil {
                answer(bridge)
                return
            }
            await Task.yield()
        }
        XCTFail("no settings card appeared")
    }

    private func router(
        destination: OwnedWindowFixture?,
        productAccessAllowed: @escaping @MainActor () -> Bool = { true },
        windows: OpenedWindows = OpenedWindows(),
        extensions: ConfiguredExtensions = ConfiguredExtensions()
    ) -> MechanicianOperationRouter {
        MechanicianOperationRouter(
            productAccessAllowed: productAccessAllowed,
            resolveConversationWorkspace: { _ in destination?.bridge },
            openWindow: { window in
                windows.opened.append(window)
                return windows.succeeds
            },
            windowIsOpen: { _, _ in windows.appears },
            configuredServer: { name in
                extensions.servers.first { $0.name == name }
            },
            setExtensionEnabled: { server, enabled in
                extensions.applied.append((server.name, enabled))
                if let index = extensions.servers.firstIndex(where: { $0.id == server.id }) {
                    extensions.servers[index].enabled = enabled
                }
            },
            settleAttempts: 2,
            settleDelayNanoseconds: 0)
    }

    private func restoreDefault(_ key: String, to value: Any?) {
        if let value {
            UserDefaults.standard.set(value, forKey: key)
        } else {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }

    // MARK: - Vocabulary

    func testTheVocabularyExcludesEveryAuthorityChangingOperation() {
        let names = Set(MechanicianOperationKind.allCases.map(\.rawValue))
        XCTAssertEqual(names, [
            "showInspectorTab", "hideInspector", "openWindow", "focusComposer",
            "newConversation", "setModel", "setReasoningEffort",
            "enableExtension", "disableExtension",
        ])
        // Only a setting every conversation shares needs the person's answer first. Anything scoped
        // to a window or one conversation is undone by looking at it.
        XCTAssertEqual(
            Set(MechanicianOperationKind.allCases.filter(\.requiresConfirmation).map(\.rawValue)),
            ["enableExtension", "disableExtension"])
        // The boundary is the vocabulary itself. Nothing here changes permission mode, connects or
        // disconnects an account, sends a message, or deletes anything, so no operation can widen
        // what the agent is allowed to do next.
        for forbidden in [
            "setPermissionMode", "connectAccount", "disconnectAccount", "sendMessage",
            "deleteConversation", "deleteWorkspace", "quit", "runShell",
        ] {
            XCTAssertNil(MechanicianOperationKind(rawValue: forbidden), forbidden)
        }
        // App-wide surfaces need no conversation window; everything scoped to a conversation does.
        let appWide: Set<MechanicianOperationKind> = [
            .openWindow, .enableExtension, .disableExtension,
        ]
        for kind in appWide {
            XCTAssertFalse(kind.needsConversationWindow, kind.rawValue)
        }
        for kind in MechanicianOperationKind.allCases where !appWide.contains(kind) {
            XCTAssertTrue(kind.needsConversationWindow, kind.rawValue)
        }
        XCTAssertEqual(MechanicianOperationKind.setModel.effect, .conversationSetting)
        XCTAssertEqual(MechanicianOperationKind.setReasoningEffort.effect, .conversationSetting)
        XCTAssertEqual(MechanicianOperationKind.newConversation.effect, .additive)
        for kind in [
            MechanicianOperationKind.showInspectorTab, .hideInspector, .openWindow, .focusComposer,
        ] {
            XCTAssertEqual(kind.effect, .presentation, kind.rawValue)
        }
    }

    func testTargetArityIsEnforcedInBothDirections() async {
        let fixture = ownedWindow()
        defer { fixture.cleanUp() }
        let subject = router(destination: fixture)
        let source = admission(for: fixture)

        let outcome1 = await subject.perform(.showInspectorTab, target: nil, source: source)
        XCTAssertEqual(outcome1, .refused(.unsupportedTarget))
        let outcome2 = await subject.perform(.hideInspector, target: "artifacts", source: source)
        XCTAssertEqual(outcome2, .refused(.unsupportedTarget))
        let outcome3 = await subject.perform(.showInspectorTab, target: "terminal", source: source)
        XCTAssertEqual(outcome3, .refused(.unsupportedTarget))
        let outcome4 = await subject.perform(.openWindow, target: "finder", source: source)
        XCTAssertEqual(outcome4, .refused(.unsupportedTarget))
    }

    // MARK: - Admission

    func testStorageRecoveryAndTurnDriftRefuseBeforeAnythingMoves() async {
        let fixture = ownedWindow()
        defer { fixture.cleanUp() }
        fixture.bridge.showInspector = false

        let blocked = router(destination: fixture, productAccessAllowed: { false })
        let refusedForStorage = await blocked.perform(
            .focusComposer, target: nil, source: admission(for: fixture))
        XCTAssertEqual(refusedForStorage, .refused(.storageUnavailable))

        let subject = router(destination: fixture)
        let stale = admission(for: fixture, valid: { false })
        let outcome5 = await subject.perform(.focusComposer, target: nil, source: stale)
        XCTAssertEqual(outcome5, .refused(.sourceInvalidated))
        XCTAssertFalse(fixture.bridge.showInspector)
    }

    /// The closed Memory editor was the one profile `permitsMechanicianGuidance` refused, and it
    /// is gone. Both surviving profiles are admitted, so what is left to pin is that the closed
    /// Help profile is one of them rather than being refused along with it.
    func testTheClosedHelpProfileStillBuildsAnAdmission() {
        let fixture = ownedWindow()
        defer { fixture.cleanUp() }
        XCTAssertNotNil(MechanicianOperationAdmission(
            bridge: fixture.bridge,
            window: fixture.window,
            conversationID: fixture.bridge.currentID!,
            toolProfile: .helpExpert,
            turnID: "turn-1",
            revalidateTurn: { true }))
    }

    func testNoEligibleConversationWindowRefusesInsteadOfOpeningOne() async {
        let fixture = ownedWindow()
        defer { fixture.cleanUp() }
        let subject = router(destination: nil)
        let outcome6 = await subject.perform(.focusComposer, target: nil, source: admission(for: fixture))
        XCTAssertEqual(outcome6, .refused(.destinationUnavailable))
    }

    // MARK: - Inspector

    func testOpeningATabTheWorkspaceHidesShowsItAndSaysSo() async {
        let tabKey = InspectorTabPreference.key(nil)
        let prior = UserDefaults.standard.object(forKey: tabKey)
        defer { restoreDefault(tabKey, to: prior) }
        UserDefaults.standard.set(["artifacts"], forKey: tabKey)

        let fixture = ownedWindow()
        defer { fixture.cleanUp() }
        fixture.bridge.showInspector = false
        fixture.bridge.inspectorTab = .artifacts
        let subject = router(destination: fixture)

        let outcome = await subject.perform(
            .showInspectorTab, target: "skills", source: admission(for: fixture))
        guard case .performed(let text) = outcome else {
            return XCTFail("expected performed, got \(outcome)")
        }
        XCTAssertTrue(text.contains("showed the Skills tab"), text)
        XCTAssertEqual(fixture.bridge.inspectorTab, .skills)
        XCTAssertTrue(fixture.bridge.showInspector)
        // The person asked for this surface, so the tab set really changes and the tab bar shows it.
        XCTAssertTrue(fixture.bridge.visibleInspectorTabs().contains(.skills))

        let again = await subject.perform(
            .showInspectorTab, target: "artifacts", source: admission(for: fixture))
        guard case .performed(let secondText) = again else {
            return XCTFail("expected performed, got \(again)")
        }
        XCTAssertTrue(secondText.contains("opened the Artifacts tab"), secondText)
        XCTAssertEqual(fixture.bridge.inspectorTab, .artifacts)
    }

    func testFilesAndChangesAreRefusedWithTheFolderReasonRatherThanForced() async {
        let fixture = ownedWindow()
        defer { fixture.cleanUp() }
        let subject = router(destination: fixture)

        for target in ["files", "changes"] {
            let outcome = await subject.perform(
                .showInspectorTab, target: target, source: admission(for: fixture))
            guard case .refused(.targetUnavailable(let reason)) = outcome else {
                return XCTFail("expected a folder refusal for \(target), got \(outcome)")
            }
            XCTAssertTrue(reason.contains("workspace folder"), reason)
        }
        XCTAssertFalse(fixture.bridge.visibleInspectorTabs().contains(.changes))
    }

    func testHidingAnAlreadyHiddenInspectorReportsThatRatherThanClaimingAChange() async {
        let fixture = ownedWindow()
        defer { fixture.cleanUp() }
        let subject = router(destination: fixture)
        fixture.bridge.showInspector = true

        guard case .performed(let hidden) = await subject.perform(
            .hideInspector, target: nil, source: admission(for: fixture)) else {
            return XCTFail("expected performed")
        }
        XCTAssertTrue(hidden.contains("hid the inspector"), hidden)
        XCTAssertFalse(fixture.bridge.showInspector)

        guard case .performed(let already) = await subject.perform(
            .hideInspector, target: nil, source: admission(for: fixture)) else {
            return XCTFail("expected performed")
        }
        XCTAssertTrue(already.contains("already hidden"), already)
    }

    // MARK: - Windows

    func testEveryWindowTargetRoutesThroughTheAppOwnedOpener() async {
        let fixture = ownedWindow()
        defer { fixture.cleanUp() }
        let windows = OpenedWindows()
        let subject = router(destination: nil, windows: windows)

        for window in MechanicianOperationWindow.allCases {
            let outcome = await subject.perform(
                .openWindow, target: window.rawValue, source: admission(for: fixture))
            guard case .performed(let text) = outcome else {
                return XCTFail("expected performed for \(window.rawValue), got \(outcome)")
            }
            XCTAssertTrue(
                text.contains(MechanicianOperationRouter.windowName(window)),
                text)
        }
        XCTAssertEqual(windows.opened, MechanicianOperationWindow.allCases)

        // A window request never needs a conversation window, which is why it resolved with none.
        windows.succeeds = false
        let refused = await subject.perform(
            .openWindow, target: "settings", source: admission(for: fixture))
        guard case .refused(.targetUnavailable(let reason)) = refused else {
            return XCTFail("expected a refusal, got \(refused)")
        }
        XCTAssertTrue(reason.contains("Settings"), reason)

        // The defect the first live run exposed: the opener was invoked, reported success, and no
        // window ever appeared. Asking is not opening, and the tool now says which happened.
        windows.succeeds = true
        windows.appears = false
        windows.opened.removeAll()
        let never = await subject.perform(
            .openWindow, target: "extensions", source: admission(for: fixture))
        guard case .refused(.targetUnavailable(let text)) = never else {
            return XCTFail("expected a refusal, got \(never)")
        }
        XCTAssertTrue(text.contains("did not open"), text)
        // One retry, then an honest refusal rather than a third attempt or a false success.
        XCTAssertEqual(windows.opened, [.extensions, .extensions])
    }

    // MARK: - Conversation settings

    func testAnUnreportedEffortLevelIsRefusedWithTheProviderThatDidNotOfferIt() async {
        let fixture = ownedWindow()
        defer { fixture.cleanUp() }
        let subject = router(destination: fixture)
        let before = fixture.bridge.effort

        let outcome = await subject.perform(
            .setReasoningEffort, target: "telepathic", source: admission(for: fixture))
        guard case .refused(.targetUnavailable(let reason)) = outcome else {
            return XCTFail("expected a refusal, got \(outcome)")
        }
        XCTAssertTrue(reason.contains("telepathic"), reason)
        XCTAssertEqual(fixture.bridge.effort, before)
    }

    /// `AgentBridge.selectModel(_ modelID:)` accepts a name the catalog has not confirmed, which is
    /// correct for a person choosing from a stale picker and wrong for a provider-supplied string.
    /// Without the operation's own catalog check this test set the conversation to a model that
    /// does not exist.
    func testAModelTheAccountDoesNotOfferLeavesTheConversationAlone() async {
        let fixture = ownedWindow()
        defer { fixture.cleanUp() }
        let subject = router(destination: fixture)
        let before = fixture.bridge.selectedModelSelection

        let outcome = await subject.perform(
            .setModel, target: "not-a-real-model", source: admission(for: fixture))
        guard case .refused(.targetUnavailable(let reason)) = outcome else {
            return XCTFail("expected a refusal, got \(outcome)")
        }
        XCTAssertTrue(
            reason.contains("not reported its model list") || reason.contains("does not offer"),
            reason)
        XCTAssertEqual(fixture.bridge.selectedModelSelection, before)
    }

    // MARK: - App settings

    func testAConnectionAlreadyInTheRequestedStateIsReportedRatherThanConfirmed() async {
        let fixture = ownedWindow()
        defer { fixture.cleanUp() }
        let extensions = ConfiguredExtensions()
        extensions.servers = [server("GitHub", enabled: true)]
        let subject = router(destination: fixture, extensions: extensions)

        let outcome = await subject.perform(
            .enableExtension, target: "GitHub", source: admission(for: fixture))
        guard case .performed(let text) = outcome else {
            return XCTFail("expected performed, got \(outcome)")
        }
        XCTAssertTrue(text.contains("already on"), text)
        // Nothing to decide, so nothing was asked and nothing was written.
        XCTAssertNil(fixture.bridge.pendingSettingChange)
        XCTAssertTrue(extensions.applied.isEmpty)
    }

    func testAnUnknownOrUnfinishedConnectionIsRefusedBeforeAnyoneIsAsked() async {
        let fixture = ownedWindow()
        defer { fixture.cleanUp() }
        let extensions = ConfiguredExtensions()
        extensions.servers = [server("Halfway", enabled: false, valid: false)]
        let subject = router(destination: fixture, extensions: extensions)

        let missing = await subject.perform(
            .enableExtension, target: "Nowhere", source: admission(for: fixture))
        guard case .refused(.targetUnavailable(let missingReason)) = missing else {
            return XCTFail("expected a refusal, got \(missing)")
        }
        XCTAssertTrue(missingReason.contains("configured connections"), missingReason)

        let unfinished = await subject.perform(
            .enableExtension, target: "Halfway", source: admission(for: fixture))
        guard case .refused(.targetUnavailable(let unfinishedReason)) = unfinished else {
            return XCTFail("expected a refusal, got \(unfinished)")
        }
        XCTAssertTrue(unfinishedReason.contains("not fully configured"), unfinishedReason)
        XCTAssertNil(fixture.bridge.pendingSettingChange)
        XCTAssertTrue(extensions.applied.isEmpty)
    }

    func testTheChangeHappensOnlyAfterThePersonApproves() async {
        let fixture = ownedWindow()
        defer { fixture.cleanUp() }
        let extensions = ConfiguredExtensions()
        extensions.servers = [server("GitHub", enabled: false)]
        let subject = router(destination: fixture, extensions: extensions)

        async let outcome = subject.perform(
            .enableExtension, target: "GitHub", source: admission(for: fixture))
        await answerPendingChange(on: fixture.bridge) { bridge in
            // Nothing may have been written at the moment the card is on screen.
            XCTAssertTrue(extensions.applied.isEmpty)
            XCTAssertEqual(bridge.pendingSettingChange?.confirmLabel, "Turn on")
            XCTAssertTrue(
                bridge.pendingSettingChange?.title.contains("GitHub") == true,
                bridge.pendingSettingChange?.title ?? "")
            bridge.approvePendingSettingChange()
        }
        guard case .performed(let text) = await outcome else {
            return XCTFail("expected performed")
        }
        XCTAssertTrue(text.contains("You approved"), text)
        XCTAssertEqual(extensions.applied.map(\.name), ["GitHub"])
        XCTAssertEqual(extensions.applied.map(\.enabled), [true])
        XCTAssertNil(fixture.bridge.pendingSettingChange)
    }

    func testDecliningChangesNothingAndSaysSoAsTheirDecision() async {
        let fixture = ownedWindow()
        defer { fixture.cleanUp() }
        let extensions = ConfiguredExtensions()
        extensions.servers = [server("GitHub", enabled: true)]
        let subject = router(destination: fixture, extensions: extensions)

        async let outcome = subject.perform(
            .disableExtension, target: "GitHub", source: admission(for: fixture))
        await answerPendingChange(on: fixture.bridge) { $0.declinePendingSettingChange() }
        guard case .refused(.declined(let reason)) = await outcome else {
            return XCTFail("expected a decline")
        }
        XCTAssertTrue(reason.contains("nothing changed"), reason)
        XCTAssertTrue(reason.contains("still on"), reason)
        XCTAssertTrue(extensions.applied.isEmpty)
        // Answering "no" is not a failure. It reports as unsuccessful so the agent cannot narrate a
        // change that did not happen, but it is not an error the transcript should paint red.
        let declined = await outcome
        XCTAssertFalse(declined.ok)
        XCTAssertFalse(declined.reportsAsError)
        XCTAssertTrue(
            MechanicianOperationOutcome.refused(.destinationUnavailable).reportsAsError)
    }

    /// A turn that ends under an unanswered card is not a refusal. Reporting it as one would put a
    /// decision in the person's mouth that they never made.
    func testATurnEndingUnderTheCardIsNotADecline() async {
        let fixture = ownedWindow()
        defer { fixture.cleanUp() }
        let extensions = ConfiguredExtensions()
        extensions.servers = [server("GitHub", enabled: false)]
        let subject = router(destination: fixture, extensions: extensions)

        async let outcome = subject.perform(
            .enableExtension, target: "GitHub", source: admission(for: fixture, turnID: "turn-9"))
        await answerPendingChange(on: fixture.bridge) { bridge in
            // A different turn's cleanup must leave this card alone.
            bridge.abandonPendingSettingChange(turnID: "turn-other")
            XCTAssertNotNil(bridge.pendingSettingChange)
            bridge.abandonPendingSettingChange(turnID: "turn-9")
        }
        guard case .refused(.declined(let reason)) = await outcome else {
            return XCTFail("expected an abandoned outcome")
        }
        XCTAssertTrue(reason.contains("before you answered"), reason)
        XCTAssertTrue(extensions.applied.isEmpty)
    }

    func testASecondProposalCannotStackOnAnUnansweredOne() async {
        let fixture = ownedWindow()
        defer { fixture.cleanUp() }
        let extensions = ConfiguredExtensions()
        extensions.servers = [server("GitHub", enabled: false), server("Linear", enabled: false)]
        let subject = router(destination: fixture, extensions: extensions)

        async let first = subject.perform(
            .enableExtension, target: "GitHub", source: admission(for: fixture))
        await answerPendingChange(on: fixture.bridge) { _ in }
        let second = await subject.perform(
            .enableExtension, target: "Linear", source: admission(for: fixture))
        // Never shown means nobody decided. Folding this into a decline is what made a duplicate
        // call report "you declined the confirmation" in a conversation with one card on screen.
        guard case .refused(.alreadyAwaitingAnswer(let reason)) = second else {
            return XCTFail("expected the second proposal to be refused, got \(second)")
        }
        XCTAssertTrue(reason.contains("was not put to the person"), reason)
        XCTAssertFalse(reason.lowercased().contains("declin"), reason)
        // The first card is still the one on screen, unreplaced.
        XCTAssertTrue(
            fixture.bridge.pendingSettingChange?.title.contains("GitHub") == true,
            fixture.bridge.pendingSettingChange?.title ?? "")
        fixture.bridge.declinePendingSettingChange()
        _ = await first
    }

    /// The exact shape David hit: the model called the same operation twice, one card appeared, and
    /// the answer to the whole turn came back reading as a decline he never made.
    func testADuplicateCallIsNeverReportedAsSomethingThePersonDecided() async {
        let fixture = ownedWindow()
        defer { fixture.cleanUp() }
        let extensions = ConfiguredExtensions()
        extensions.servers = [server("Echo Fixture", enabled: true)]
        let subject = router(destination: fixture, extensions: extensions)

        async let first = subject.perform(
            .disableExtension, target: "Echo Fixture", source: admission(for: fixture))
        await answerPendingChange(on: fixture.bridge) { _ in }
        let duplicate = await subject.perform(
            .disableExtension, target: "Echo Fixture", source: admission(for: fixture))
        guard case .refused(.alreadyAwaitingAnswer) = duplicate else {
            return XCTFail("a duplicate call must not report a decision, got \(duplicate)")
        }
        // Exactly one card was ever shown, and it is still the one waiting.
        XCTAssertNotNil(fixture.bridge.pendingSettingChange)
        fixture.bridge.approvePendingSettingChange()
        guard case .performed = await first else { return XCTFail("expected the first to apply") }
        XCTAssertEqual(extensions.applied.count, 1)
    }
}
