import AppKit
import Foundation
import SwiftUI

/// The closed set of interface operations an agent may perform on the person's behalf.
///
/// This is deliberately not computer control. The provider names one operation from this
/// vocabulary and, where the operation needs one, one target the app re-resolves against its own
/// authority. It can never supply a coordinate, selector, script, window, workspace, conversation,
/// or route, and no operation here changes what the agent itself is allowed to do: permission mode,
/// provider accounts and anything destructive are absent on purpose, because an agent that can
/// widen its own authority has no boundary left to enforce.
enum MechanicianOperationKind: String, CaseIterable, Sendable {
    case showInspectorTab
    case hideInspector
    case openWindow
    case focusComposer
    case newConversation
    case setModel
    case setReasoningEffort
    case enableExtension
    case disableExtension

    /// What the operation does to the app, which decides where it may run and how it is reported.
    var effect: MechanicianOperationEffect {
        switch self {
        case .showInspectorTab, .hideInspector, .openWindow, .focusComposer:
            .presentation
        case .newConversation:
            .additive
        case .setModel, .setReasoningEffort:
            .conversationSetting
        case .enableExtension, .disableExtension:
            .appSetting
        }
    }

    /// Whether the person must approve this operation before anything changes.
    ///
    /// Everything else in the vocabulary is scoped to a window or a conversation and is undone by
    /// looking at it. An app setting outlives the conversation that changed it and applies to every
    /// other one, so it is the person's decision to make each time, not a class the agent is
    /// trusted with once.
    var requiresConfirmation: Bool {
        effect == .appSetting
    }

    /// Whether the operation runs inside an ordinary conversation window or on an app-wide surface.
    var needsConversationWindow: Bool {
        switch self {
        case .openWindow, .enableExtension, .disableExtension: false
        default: true
        }
    }

    var requiresTarget: Bool {
        switch self {
        case .showInspectorTab, .openWindow, .setModel, .setReasoningEffort,
             .enableExtension, .disableExtension: true
        case .hideInspector, .focusComposer, .newConversation: false
        }
    }
}

enum MechanicianOperationEffect: Equatable, Sendable {
    /// Reveals or focuses something already in the app. Reversible by looking away.
    case presentation
    /// Adds something the person can remove. Never replaces or deletes.
    case additive
    /// Changes a setting that belongs to one conversation, not to the app or the account.
    case conversationSetting
    /// Changes a setting that outlives this conversation and applies to every other one.
    case appSetting
}

/// Inspector tabs an operation may select.
enum MechanicianOperationInspectorTab: String, CaseIterable, Sendable {
    case files, changes, artifacts, agents, skills, help

    var inspectorTab: InspectorTab {
        switch self {
        case .files: .files
        case .changes: .changes
        case .artifacts: .artifacts
        case .agents: .agents
        case .skills: .skills
        case .help: .help
        }
    }
}

/// App-wide surfaces an operation may open. Every one of these is a window the person can close.
enum MechanicianOperationWindow: String, CaseIterable, Sendable {
    case help, artifacts, tasks, extensions, providers, settings
}

enum MechanicianOperationRefusal: Equatable, Sendable {
    case storageUnavailable
    case sourceInvalidated
    case unsupportedOperation
    case unsupportedTarget
    case destinationUnavailable
    case targetUnavailable(String)
    /// The person was asked and said no, or never answered. Reported as unsuccessful so the agent
    /// does not narrate a change that did not happen, but it is their decision, not a fault.
    case declined(String)
    /// A change is already on screen waiting, so this one was never put to the person at all.
    case alreadyAwaitingAnswer(String)

    /// What the agent is told. Every refusal names a reason the agent can act on, because a tool
    /// that fails without saying why is one a model retries verbatim.
    var text: String {
        switch self {
        case .storageUnavailable:
            "Mechanician is in storage recovery, so it cannot operate its own interface."
        case .sourceInvalidated:
            "That request is no longer current for this conversation, so nothing was changed."
        case .unsupportedOperation:
            "Mechanician does not perform that operation."
        case .unsupportedTarget:
            "That is not one of the targets Mechanician accepts for this operation."
        case .destinationUnavailable:
            "There is no open conversation window to operate, and Mechanician does not open one to satisfy a request."
        case .targetUnavailable(let reason):
            reason
        case .declined(let reason):
            reason
        case .alreadyAwaitingAnswer(let reason):
            reason
        }
    }
}

enum MechanicianOperationOutcome: Equatable, Sendable {
    case performed(String)
    case refused(MechanicianOperationRefusal)

    var ok: Bool {
        if case .performed = self { return true }
        return false
    }

    /// Whether the tool call should be reported to the provider as an error.
    ///
    /// A decline is not a failure. The person was asked, they answered, and the answer was no — the
    /// interaction did exactly what it was built to do. Reporting it as an error paints the tool
    /// card red for their own decision and invites the model to treat it as something to work
    /// around. The text still says plainly that nothing changed.
    var reportsAsError: Bool {
        switch self {
        case .performed: false
        case .refused(.declined): false
        case .refused: true
        }
    }

    var text: String {
        switch self {
        case .performed(let text): text
        case .refused(let refusal): refusal.text
        }
    }
}

/// The exact live conversation and window that asked Mechanician to operate its interface.
///
/// The provider cannot name a destination. `AgentBridge` builds this receipt from the accepted root
/// turn; weak ownership means an operation that resolves asynchronously can never fall through to
/// whichever window is key later.
@MainActor
final class MechanicianOperationAdmission {
    private weak var bridge: AgentBridge?
    private weak var window: NSWindow?
    private let revalidateTurn: @MainActor () -> Bool

    let conversationID: UUID
    let toolProfile: ProviderToolProfile
    let bridgeID: UUID
    let windowID: ObjectIdentifier
    /// The exact turn that asked. A confirmation belongs to it, so a card cannot be answered on
    /// behalf of a turn that has since ended.
    let turnID: String

    init?(
        bridge: AgentBridge,
        window: NSWindow,
        conversationID: UUID,
        toolProfile: ProviderToolProfile,
        turnID: String,
        revalidateTurn: @escaping @MainActor () -> Bool
    ) {
        guard bridge.window === window,
              bridge.currentID == conversationID,
              toolProfile.permitsMechanicianGuidance else { return nil }
        self.bridge = bridge
        self.window = window
        self.conversationID = conversationID
        self.toolProfile = toolProfile
        self.turnID = turnID
        bridgeID = bridge.bridgeID
        windowID = ObjectIdentifier(window)
        self.revalidateTurn = revalidateTurn
    }

    var isCurrent: Bool {
        guard let bridge, let window,
              bridge.bridgeID == bridgeID,
              ObjectIdentifier(window) == windowID,
              bridge.window === window,
              bridge.currentID == conversationID,
              toolProfile.permitsMechanicianGuidance else { return false }
        return revalidateTurn()
    }

    var currentBridge: AgentBridge? { isCurrent ? bridge : nil }
}

/// App-owned execution for the agent's bounded `OperateMechanician` tool.
///
/// The router shares the guidance router's idea of which window is an ordinary conversation
/// window, so "show me the Changes panel" and "open the Changes panel" cannot disagree about where
/// they mean. Nothing here opens a workspace: a request with no eligible conversation window is
/// refused rather than satisfied by creating one.
@MainActor
final class MechanicianOperationRouter {
    static let shared = MechanicianOperationRouter()

    typealias ProductAccessCheck = @MainActor () -> Bool
    typealias ConversationWorkspaceResolver = @MainActor (
        _ source: AgentBridge?
    ) -> AgentBridge?
    typealias WindowOpener = @MainActor (_ window: MechanicianOperationWindow) -> Bool
    typealias ConfiguredServerLookup = @MainActor (_ name: String) -> MCPServer?
    typealias ExtensionEnabler = @MainActor (_ server: MCPServer, _ enabled: Bool) -> Void
    /// Whether the window is actually on screen now. `before` is the set of window numbers that
    /// existed when the operation started, so a surface with no tracked identity can still be
    /// verified by the fact that something new appeared.
    typealias WindowVerifier = @MainActor (
        _ window: MechanicianOperationWindow,
        _ before: Set<Int>
    ) -> Bool

    private let productAccessAllowed: ProductAccessCheck
    private let resolveConversationWorkspace: ConversationWorkspaceResolver
    private let openWindow: WindowOpener
    private let windowIsOpen: WindowVerifier
    private let configuredServer: ConfiguredServerLookup
    private let setExtensionEnabled: ExtensionEnabler
    private let settleAttempts: Int
    private let settleDelayNanoseconds: UInt64

    init(
        productAccessAllowed: @escaping ProductAccessCheck = {
            StorageProductAccessGate.allows(
                .shared,
                ownsProcessLease: StorageAuthorityBootstrap.ownsProcessLease)
        },
        resolveConversationWorkspace: @escaping ConversationWorkspaceResolver = { source in
            if let source, MechanicianGuidanceRouter.conversationDestinationIsEligible(source) {
                return source
            }
            guard let frontmost =
                    MechanicianGuidanceRouter.frontmostEligibleConversationBridge() else {
                return nil
            }
            focusWorkspaceWindow(of: frontmost)
            return frontmost
        },
        openWindow: @escaping WindowOpener = { window in
            MechanicianOperationRouter.openProductWindow(window)
        },
        windowIsOpen: @escaping WindowVerifier = { window, before in
            MechanicianOperationRouter.productWindowIsOpen(window, notAmong: before)
        },
        configuredServer: @escaping ConfiguredServerLookup = { name in
            MechanicianOperationRouter.configuredServer(named: name)
        },
        setExtensionEnabled: @escaping ExtensionEnabler = { server, enabled in
            var updated = server
            updated.enabled = enabled
            ExtensionsStore.shared.upsert(updated)
        },
        settleAttempts: Int = 60,
        settleDelayNanoseconds: UInt64 = 50_000_000
    ) {
        self.productAccessAllowed = productAccessAllowed
        self.resolveConversationWorkspace = resolveConversationWorkspace
        self.openWindow = openWindow
        self.windowIsOpen = windowIsOpen
        self.configuredServer = configuredServer
        self.setExtensionEnabled = setExtensionEnabled
        self.settleAttempts = max(1, settleAttempts)
        self.settleDelayNanoseconds = settleDelayNanoseconds
    }

    func perform(
        _ kind: MechanicianOperationKind,
        target: String?,
        source: MechanicianOperationAdmission
    ) async -> MechanicianOperationOutcome {
        guard productAccessAllowed() else { return .refused(.storageUnavailable) }
        guard source.isCurrent else { return .refused(.sourceInvalidated) }
        if kind.requiresTarget {
            guard let target, !target.isEmpty else { return .refused(.unsupportedTarget) }
            return await performChecked(kind, target: target, source: source)
        }
        guard target == nil else { return .refused(.unsupportedTarget) }
        return await performChecked(kind, target: nil, source: source)
    }

    private func performChecked(
        _ kind: MechanicianOperationKind,
        target: String?,
        source: MechanicianOperationAdmission
    ) async -> MechanicianOperationOutcome {
        if case .openWindow = kind {
            guard let raw = target,
                  let window = MechanicianOperationWindow(rawValue: raw) else {
                return .refused(.unsupportedTarget)
            }
            return await open(window)
        }
        if kind == .enableExtension || kind == .disableExtension {
            guard let name = target else { return .refused(.unsupportedTarget) }
            return await setExtension(
                named: name,
                enabled: kind == .enableExtension,
                source: source)
        }

        guard let destination = resolveConversationWorkspace(source.currentBridge),
              MechanicianGuidanceRouter.conversationDestinationIsEligible(destination),
              destination.window != nil else {
            return .refused(.destinationUnavailable)
        }

        switch kind {
        case .showInspectorTab:
            guard let raw = target,
                  let requested = MechanicianOperationInspectorTab(rawValue: raw) else {
                return .refused(.unsupportedTarget)
            }
            return showInspectorTab(requested, in: destination)
        case .hideInspector:
            guard destination.showInspector else {
                return .performed("The inspector was already hidden in this conversation window.")
            }
            destination.showInspector = false
            return .performed("Mechanician hid the inspector in this conversation window.")
        case .focusComposer:
            destination.composerFocusOwner.takeFocus()
            return .performed("Mechanician put the cursor in the message box.")
        case .newConversation:
            destination.newConversation()
            return .performed(
                "Mechanician started a new conversation in this workspace. It is empty and unsent.")
        case .setModel:
            guard let modelID = target else { return .refused(.unsupportedTarget) }
            return setModel(modelID, in: destination)
        case .setReasoningEffort:
            guard let level = target else { return .refused(.unsupportedTarget) }
            guard destination.availableEfforts.contains(level) else {
                return .refused(.targetUnavailable(
                    "\(destination.currentModelAccess.displayName) did not report \"\(level)\" for the selected model."))
            }
            destination.effort = level
            return .performed("Mechanician set this conversation's reasoning effort to "
                + AgentBridge.effortLabel(
                    destination.effortSelectionID,
                    access: destination.currentModelAccess) + ".")
        case .openWindow, .enableExtension, .disableExtension:
            return .refused(.unsupportedOperation)
        }
    }

    /// Turn one configured connection on or off, once the person has said so.
    ///
    /// The name is re-resolved against the configured connections, never trusted as given, and the
    /// card the person reads is composed here from the app's own state — a provider supplies no
    /// copy, so a change cannot be dressed up as something milder than it is. A connection already
    /// in the requested state is reported, not confirmed: there is nothing to decide.
    private func setExtension(
        named name: String,
        enabled: Bool,
        source: MechanicianOperationAdmission
    ) async -> MechanicianOperationOutcome {
        guard let server = configuredServer(name) else {
            return .refused(.targetUnavailable(
                "\"\(name)\" is not one of this Mac's configured connections."))
        }
        guard server.enabled != enabled else {
            return .performed("The \(server.name) connection is already "
                + (enabled ? "on." : "off."))
        }
        if enabled, !server.isValid {
            return .refused(.targetUnavailable(
                "The \(server.name) connection is not fully configured yet, so turning it on would not give it to any conversation. Finish it in Extensions first."))
        }
        guard let bridge = source.currentBridge else { return .refused(.sourceInvalidated) }

        let verb = enabled ? "Turn on" : "Turn off"
        let request = MechanicianSettingChangeRequest(
            turnID: source.turnID,
            title: "\(verb) the \(server.name) connection",
            detail: enabled
                ? "It is off now. Turning it on makes its tools available to every conversation from the next message, not only this one."
                : "It is on now. Turning it off takes its tools away from every conversation from the next message, not only this one.",
            confirmLabel: verb,
            approveText: "You approved it. The \(server.name) connection is now "
                + (enabled ? "on" : "off")
                + ", and every conversation sees that from its next message.",
            declineText: "You declined, so nothing changed. The \(server.name) connection is still "
                + (server.enabled ? "on." : "off."))

        switch await bridge.requestSettingChangeConfirmation(request) {
        case .approved:
            // Re-resolve rather than reusing the value captured before the person answered: the
            // connection may have been edited, renamed, or removed in Extensions while the card
            // was up, and applying a stale copy would undo that silently.
            guard let current = configuredServer(name) else {
                return .refused(.targetUnavailable(
                    "The \(server.name) connection was removed while you were deciding, so nothing changed."))
            }
            guard current.enabled != enabled else {
                return .performed("The \(current.name) connection is already "
                    + (enabled ? "on." : "off."))
            }
            setExtensionEnabled(current, enabled)
            return .performed(request.approveText)
        case .declined:
            return .refused(.declined(request.declineText))
        case .abandoned:
            return .refused(.declined(
                "Nothing changed. The conversation moved on before you answered, so the \(server.name) connection is untouched."))
        case .notAsked:
            // Never shown, so nobody decided anything. Saying "declined" here is what turned a
            // duplicate call into a refusal the person never made.
            return .refused(.alreadyAwaitingAnswer(
                "Mechanician is already waiting on an answer for another change, so this one was not put to the person and nothing changed. Wait for that card to be answered before asking again."))
        }
    }

    static func configuredServer(named name: String) -> MCPServer? {
        let servers = ExtensionsStore.shared.mcpServers
        if let exact = servers.first(where: { $0.name == name }) { return exact }
        let folded = name.lowercased()
        let matches = servers.filter { $0.name.lowercased() == folded }
        return matches.count == 1 ? matches[0] : nil
    }

    /// Open a window and then prove it. Reporting the attempt is not reporting the result: the first
    /// live run of this tool answered "Mechanician opened Extensions" while no window existed,
    /// because invoking the opener was mistaken for the window appearing. A scene opens on a later
    /// run-loop pass, so the outcome is decided by watching for it, and one retry covers the case
    /// where the first request lands before the app is ready to service it.
    private func open(_ window: MechanicianOperationWindow) async -> MechanicianOperationOutcome {
        let before = Self.currentWindowNumbers()
        guard openWindow(window) else {
            return .refused(.targetUnavailable(
                "Mechanician could not open \(Self.windowName(window))."))
        }
        if await windowSettles(window, notAmong: before) {
            return .performed("Mechanician opened \(Self.windowName(window)).")
        }
        // Second and last attempt, on a later pass. If this one does not land either, say so rather
        // than leaving the person looking for a window that was never there.
        guard openWindow(window), await windowSettles(window, notAmong: before) else {
            return .refused(.targetUnavailable(
                "Mechanician asked for \(Self.windowName(window)) and it did not open."))
        }
        return .performed("Mechanician opened \(Self.windowName(window)).")
    }

    private func windowSettles(
        _ window: MechanicianOperationWindow,
        notAmong before: Set<Int>
    ) async -> Bool {
        for _ in 0..<settleAttempts {
            if windowIsOpen(window, before) { return true }
            if settleDelayNanoseconds > 0 {
                try? await Task.sleep(nanoseconds: settleDelayNanoseconds)
            } else {
                await Task.yield()
            }
        }
        return windowIsOpen(window, before)
    }

    static func currentWindowNumbers() -> Set<Int> {
        Set(NSApp.windows.map(\.windowNumber))
    }

    /// Per-surface proof, because these windows do not share one identity. The tracked utility
    /// scenes report their own visibility; Help and Settings have no shared visibility record, so
    /// the honest test is that a window exists now that did not exist when the operation started.
    static func productWindowIsOpen(
        _ window: MechanicianOperationWindow,
        notAmong before: Set<Int>
    ) -> Bool {
        switch window {
        case .artifacts:
            return UtilityWindowVisibility.shared.visibleIDs.contains(.artifacts)
        case .tasks:
            return UtilityWindowVisibility.shared.visibleIDs.contains(.ambient)
        case .extensions:
            return UtilityWindowVisibility.shared.visibleIDs.contains(.extensions)
        case .providers:
            return UtilityWindowVisibility.shared.visibleIDs.contains(.accounts)
        case .help, .settings:
            return NSApp.windows.contains { candidate in
                candidate.isVisible && !before.contains(candidate.windowNumber)
            }
        }
    }

    /// The model name is the one identifier the provider supplies, so it is re-resolved against the
    /// account's own reported catalog before anything is applied.
    ///
    /// `AgentBridge.selectModel(_ modelID:)` deliberately accepts a name the catalog has not
    /// confirmed, because a person choosing from a stale or failed picker still has to be able to
    /// pick. That latitude is right for a person and wrong here: it would let a provider name any
    /// string and have the conversation adopt it. An operation therefore requires a ready catalog
    /// that actually lists the model, and says so plainly when it cannot get one.
    private func setModel(
        _ modelID: String,
        in bridge: AgentBridge
    ) -> MechanicianOperationOutcome {
        let access = bridge.currentModelAccess
        let candidate = ModelSelection(access: access, modelID: modelID)
        if bridge.selectedModelSelection == candidate {
            return .performed("This conversation was already on "
                + bridge.modelDisplayName(for: candidate) + ".")
        }
        let snapshot = ModelCatalogStore.shared.snapshot(
            for: access, scope: bridge.catalogScope(for: access))
        guard snapshot.phase == .ready else {
            return .refused(.targetUnavailable(
                "\(access.displayName) has not reported its model list yet, so Mechanician cannot confirm \"\(modelID)\" is one of them."))
        }
        guard snapshot.entries.contains(where: { $0.selection == candidate }) else {
            return .refused(.targetUnavailable(
                "\(access.displayName) does not offer \"\(modelID)\" in this workspace."))
        }
        let before = bridge.selectedModelSelection
        bridge.selectModel(candidate)
        guard bridge.selectedModelSelection == candidate else {
            return .refused(.targetUnavailable(
                "Mechanician did not change the model; the conversation says what blocked it."))
        }
        _ = before
        return .performed("Mechanician set this conversation's model to "
            + bridge.modelDisplayName(for: candidate) + ".")
    }

    /// Selecting a tab the workspace does not currently show is different from a guide borrowing
    /// one. The person asked for this surface, so the operation may add it to the tab set, which is
    /// visible in the tab bar and reversible from the same menu that hid it. The folder rule still
    /// wins: Files and Changes run git in the workspace folder, and a folderless workspace has none.
    private func showInspectorTab(
        _ requested: MechanicianOperationInspectorTab,
        in bridge: AgentBridge
    ) -> MechanicianOperationOutcome {
        let tab = requested.inspectorTab
        if InspectorTabPreference.requiresFolder.contains(tab), bridge.cwd.isEmpty {
            return .refused(.targetUnavailable(
                "\(tab.label) needs a workspace folder and this workspace has none, so there is no \(tab.label) tab to open here."))
        }
        var added = false
        if !bridge.visibleInspectorTabs().contains(tab) {
            bridge.setInspectorTabVisible(true, tab: tab)
            bridge.inspectorTabRevision &+= 1
            added = true
        }
        bridge.userSelectedInspectorTab(tab)
        bridge.showInspector = true
        return .performed(added
            ? "Mechanician showed the \(tab.label) tab in this workspace and opened it."
            : "Mechanician opened the \(tab.label) tab in this conversation window.")
    }

    nonisolated static func windowName(_ window: MechanicianOperationWindow) -> String {
        switch window {
        case .help: "Help"
        case .artifacts: "the Artifacts window"
        case .tasks: "Scheduled & Ambient Tasks"
        case .extensions: "Extensions"
        case .providers: "Providers"
        case .settings: "Settings"
        }
    }

    static func openProductWindow(_ window: MechanicianOperationWindow) -> Bool {
        switch window {
        case .help:
            guard let open = appOpenWindow else { return false }
            NSApp.activate(ignoringOtherApps: true)
            open(id: "help")
            return true
        case .artifacts:
            return utilityWindow(.artifacts, id: "artifacts")
        case .tasks:
            return utilityWindow(.ambient, id: "ambient")
        case .extensions:
            return utilityWindow(.extensions, id: "extensions")
        case .providers:
            showProviders()
            return true
        case .settings:
            showSettings()
            return true
        }
    }

    private static func utilityWindow(_ id: UtilityWindowID, id sceneID: String) -> Bool {
        guard let open = appOpenWindow else { return false }
        _ = UtilityWindowVisibility.shared.show(id) { open(id: sceneID) }
        return true
    }
}
