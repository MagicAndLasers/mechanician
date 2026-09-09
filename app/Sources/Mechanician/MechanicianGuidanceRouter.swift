import AppKit
import Foundation
import SwiftUI

/// The exact live conversation/window that asked Mechanician to show a signed product surface.
///
/// The provider cannot name a destination window. `AgentBridge` constructs this receipt from the
/// accepted root turn and supplies the final route reproof closure; weak object ownership prevents
/// an async corpus read or first-use workspace creation from falling through to whichever window is
/// key later.
@MainActor
final class MechanicianGuidanceSourceAdmission {
    private weak var bridge: AgentBridge?
    private weak var window: NSWindow?
    private let revalidateTurn: @MainActor () -> Bool

    let conversationID: UUID
    let toolProfile: ProviderToolProfile
    let bridgeID: UUID
    let windowID: ObjectIdentifier
    let guideID: String
    let corpusContentSHA256: String

    init?(
        bridge: AgentBridge,
        window: NSWindow,
        conversationID: UUID,
        toolProfile: ProviderToolProfile,
        guideID: String,
        corpusContentSHA256: String,
        revalidateTurn: @escaping @MainActor () -> Bool
    ) {
        guard bridge.window === window,
              bridge.currentID == conversationID,
              !guideID.isEmpty,
              corpusContentSHA256.range(
                of: #"^[0-9a-f]{64}$"#,
                options: .regularExpression) != nil,
              toolProfile.permitsMechanicianGuidance else { return nil }
        self.bridge = bridge
        self.window = window
        self.conversationID = conversationID
        self.toolProfile = toolProfile
        self.guideID = guideID
        self.corpusContentSHA256 = corpusContentSHA256
        bridgeID = bridge.bridgeID
        windowID = ObjectIdentifier(window)
        self.revalidateTurn = revalidateTurn
    }

    /// The exact live conversation window that asked to be shown something.
    ///
    /// A destination resolver may prefer this window when the surface is an ordinary conversation
    /// surface. It is nil the moment the receipt stops being current, so a delayed resolution can
    /// never fall back to whichever window happens to be key.
    var currentBridge: AgentBridge? {
        isCurrent ? bridge : nil
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
}

/// App-private proof that one exact signed guide summary crossed Help search on this root turn.
///
/// The provider never supplies this receipt. Search acknowledgement adds the guide IDs selected by
/// the byte-bounded authority projection; Show reserves one ID before any asynchronous navigation.
/// A failed presentation may restore that reservation only while the same turn route, profile,
/// corpus digest, and admission generation remain current.
struct MechanicianGuidanceSearchAdmissionLedger {
    static let maximumGuideIDsPerTurn = 16

    struct Route: Equatable {
        let conversationID: UUID
        let selection: ModelSelection
        let toolProfile: ProviderToolProfile
    }

    struct Reservation: Equatable {
        let turnID: String
        let route: Route
        let guideID: String
        let corpusContentSHA256: String
        fileprivate let generation: UUID
    }

    private struct State {
        let route: Route
        let corpusContentSHA256: String
        let generation: UUID
        var guideIDs: [String]
    }

    private var states: [String: State] = [:]

    mutating func acknowledge(
        _ admission: MechanicianHelpGuideAdmission,
        turnID: String,
        route: Route
    ) {
        guard Self.digestIsAdmissible(admission.corpusContentSHA256),
              admission.guideIDs.allSatisfy(Self.guideIDIsAdmissible) else {
            states[turnID] = nil
            return
        }
        var ordered: [String]
        let generation: UUID
        if let current = states[turnID],
           current.route == route,
           current.corpusContentSHA256 == admission.corpusContentSHA256 {
            ordered = current.guideIDs
            generation = current.generation
        } else {
            ordered = []
            generation = UUID()
        }
        for guideID in admission.guideIDs where !ordered.contains(guideID) {
            ordered.append(guideID)
        }
        if ordered.count > Self.maximumGuideIDsPerTurn {
            ordered.removeFirst(ordered.count - Self.maximumGuideIDsPerTurn)
        }
        states[turnID] = State(
            route: route,
            corpusContentSHA256: admission.corpusContentSHA256,
            generation: generation,
            guideIDs: ordered)
    }

    mutating func reserve(
        guideID: String,
        turnID: String,
        route: Route
    ) -> Reservation? {
        guard var current = states[turnID],
              current.route == route,
              let index = current.guideIDs.firstIndex(of: guideID) else { return nil }
        current.guideIDs.remove(at: index)
        states[turnID] = current
        return Reservation(
            turnID: turnID,
            route: route,
            guideID: guideID,
            corpusContentSHA256: current.corpusContentSHA256,
            generation: current.generation)
    }

    mutating func restore(_ reservation: Reservation) {
        guard var current = states[reservation.turnID],
              current.route == reservation.route,
              current.generation == reservation.generation,
              current.corpusContentSHA256 == reservation.corpusContentSHA256,
              !current.guideIDs.contains(reservation.guideID),
              current.guideIDs.count < Self.maximumGuideIDsPerTurn else { return }
        current.guideIDs.append(reservation.guideID)
        states[reservation.turnID] = current
    }

    func isCurrent(_ reservation: Reservation) -> Bool {
        guard let current = states[reservation.turnID] else { return false }
        return current.route == reservation.route
            && current.generation == reservation.generation
            && current.corpusContentSHA256 == reservation.corpusContentSHA256
    }

    mutating func remove(turnID: String) {
        states[turnID] = nil
    }

    mutating func remove(turnIDs: Set<String>) {
        for turnID in turnIDs { states[turnID] = nil }
    }

    mutating func removeAll() {
        states.removeAll()
    }

    private static func guideIDIsAdmissible(_ value: String) -> Bool {
        value.utf8.prefix(97).count <= 96
            && value.range(
                of: #"^[a-z0-9][a-z0-9.-]{0,95}$"#,
                options: .regularExpression) != nil
    }

    private static func digestIsAdmissible(_ value: String) -> Bool {
        value.range(of: #"^[0-9a-f]{64}$"#, options: .regularExpression) != nil
    }
}

enum MechanicianGuidanceStartFailure: Equatable {
    case storageUnavailable
    case sourceInvalidated
    case guideUnavailable
    case unsupportedSurface
    case destinationUnavailable
    case targetUnavailable
    case presentationRejected
    case requestExpired
}

enum MechanicianGuidanceStartResult: Equatable {
    case started(title: String, sessionToken: UUID)
    case failed(MechanicianGuidanceStartFailure)
}

enum MechanicianGuidanceInspectorTabs {
    static func visible(
        stored: [InspectorTab],
        forced: InspectorTab?,
        allowsFolderTabs: Bool = true
    ) -> [InspectorTab] {
        visible(
            stored: stored,
            forced: forced.map { Set([$0]) } ?? [],
            allowsFolderTabs: allowsFolderTabs)
    }

    /// A guide may reveal tabs the person has hidden for the length of the presentation. It never
    /// manufactures a tab this workspace cannot show: Files and Changes need a working folder, and
    /// forcing either into a folderless workspace would spotlight a panel with no repository behind
    /// it. An unshowable target fails the guide visibly instead.
    static func visible(
        stored: [InspectorTab],
        forced: Set<InspectorTab>,
        allowsFolderTabs: Bool = true
    ) -> [InspectorTab] {
        let admissible = forced.filter { tab in
            allowsFolderTabs || !InspectorTabPreference.requiresFolder.contains(tab)
        }
        guard !admissible.isEmpty, !admissible.isSubset(of: Set(stored)) else { return stored }
        let admitted = Set(stored).union(admissible)
        return InspectorTab.allCases.filter(admitted.contains)
    }
}

/// App-owned navigation for the agent's bounded `ShowMechanician` tool.
///
/// The caller chooses a stable guide id, not a workspace, window, tab, view selector, coordinate,
/// script, URL, or synthetic input. The signed guide's closed `surface` enum chooses the
/// destination, and the app resolves an exact window/bridge before publishing a semantic target
/// registry to SwiftUI.
///
/// A guide destination is agent-callable. A Help guide crosses into the canonical Help workspace
/// and may create it on first use. A conversation guide stays in the person's own conversation
/// window — the source window when it is an ordinary standard workspace, otherwise the frontmost
/// one that is. Asking the closed Help expert to show the Changes panel therefore lands in the
/// window the person actually works in, and nothing here ever opens a workspace to satisfy it.
@MainActor
final class MechanicianGuidanceRouter: ObservableObject {
    static let shared = MechanicianGuidanceRouter()

    typealias GuideLoader = @Sendable (
        _ guideID: String
    ) async throws -> MechanicianHelpGuidanceSource?
    typealias ProductAccessCheck = @MainActor () -> Bool
    typealias WorkspaceRoute = @MainActor (_ project: Project) -> AgentBridge?
    typealias ConversationWorkspaceResolver = @MainActor (
        _ source: AgentBridge?
    ) -> AgentBridge?
    typealias TargetReadiness = @MainActor (_ bridge: AgentBridge, _ window: NSWindow) -> Bool
    typealias MonotonicNow = @MainActor () -> TimeInterval

    /// Tabs one active presentation may reveal in one exact window, and the one it has selected.
    /// This is presentation state; it never edits the person's per-workspace tab preference.
    struct ForcedInspectorTabs: Equatable {
        let bridgeID: UUID
        var tabs: Set<InspectorTab>
        var selected: InspectorTab?
    }

    @Published private(set) var targetCoordinator: GuidedHelpPresentationCoordinator?
    @Published private var forcedInspector: ForcedInspectorTabs?

    private let loadGuide: GuideLoader
    private let productAccessAllowed: ProductAccessCheck
    private let routeWorkspace: WorkspaceRoute
    private let resolveConversationWorkspace: ConversationWorkspaceResolver
    private let targetIsReady: TargetReadiness
    private let monotonicNow: MonotonicNow
    private let requestTimeout: TimeInterval
    private let targetRegistrationAttempts: Int
    private let targetRegistrationDelayNanoseconds: UInt64
    private var latestRequestToken: UUID?
    private var activeSessionToken: UUID?

    init(
        loadGuide: @escaping GuideLoader = { guideID in
            try await MechanicianHelpProviderRetrieval.shared.guidanceGuide(id: guideID)
        },
        productAccessAllowed: @escaping ProductAccessCheck = {
            StorageProductAccessGate.allows(
                .shared,
                ownsProcessLease: StorageAuthorityBootstrap.ownsProcessLease)
        },
        routeWorkspace: @escaping WorkspaceRoute = { project in
            routeToWorkspaceProject(project, replacing: nil)
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
        targetIsReady: @escaping TargetReadiness = { bridge, window in
            bridge.window === window
                && AgentBridge.live.allObjects.contains(where: { $0 === bridge })
                && !bridge.initialViewResolutionPending
        },
        monotonicNow: @escaping MonotonicNow = {
            ProcessInfo.processInfo.systemUptime
        },
        requestTimeout: TimeInterval = 12,
        targetRegistrationAttempts: Int = 120,
        targetRegistrationDelayNanoseconds: UInt64 = 25_000_000
    ) {
        self.loadGuide = loadGuide
        self.productAccessAllowed = productAccessAllowed
        self.routeWorkspace = routeWorkspace
        self.resolveConversationWorkspace = resolveConversationWorkspace
        self.targetIsReady = targetIsReady
        self.monotonicNow = monotonicNow
        self.requestTimeout = min(max(0.1, requestTimeout), 12)
        self.targetRegistrationAttempts = max(1, targetRegistrationAttempts)
        self.targetRegistrationDelayNanoseconds = targetRegistrationDelayNanoseconds
    }

    /// The one registry an inspector belonging to `bridge` may use. Never fall back to the key
    /// window or `ActiveWorkspace`: the coordinator's frozen owner must still match this bridge's
    /// exact window, workspace, and conversation.
    func registry(for bridge: AgentBridge) -> GuidedHelpTargetRegistry? {
        guard let window = bridge.window,
              let coordinator = targetCoordinator,
              coordinator.owner.matches(bridge: bridge, window: window) else { return nil }
        return coordinator.registry
    }

    /// Every tab the active presentation needs visible in this exact window.
    func forcedInspectorTabs(for bridge: AgentBridge) -> Set<InspectorTab> {
        guard let forcedInspector, forcedInspector.bridgeID == bridge.bridgeID else { return [] }
        return forcedInspector.tabs
    }

    /// The one tab the current step is pointing at, if any.
    func forcedInspectorTab(for bridge: AgentBridge) -> InspectorTab? {
        guard let forcedInspector, forcedInspector.bridgeID == bridge.bridgeID else { return nil }
        return forcedInspector.selected
    }

    /// Resolve and start one current signed guide. Success means the modal overlay is installed in
    /// the exact target window; it never means the person advanced or completed the guide.
    func start(
        guideID: String,
        source: MechanicianGuidanceSourceAdmission
    ) async -> MechanicianGuidanceStartResult {
        guard productAccessAllowed() else { return .failed(.storageUnavailable) }
        guard source.isCurrent,
              source.guideID == guideID else { return .failed(.sourceInvalidated) }

        let token = UUID()
        let deadline = monotonicNow() + requestTimeout
        latestRequestToken = token

        let signedSource: MechanicianHelpGuidanceSource
        do {
            guard let loaded = try await loadGuide(guideID) else {
                clearPendingRequest(token: token)
                return .failed(.guideUnavailable)
            }
            signedSource = loaded
        } catch {
            clearPendingRequest(token: token)
            return .failed(.guideUnavailable)
        }

        guard requestIsCurrent(token, source: source, deadline: deadline) else {
            let failure = requestFailure(source: source, deadline: deadline)
            clearPendingRequest(token: token)
            return .failed(failure)
        }
        let signedGuide = signedSource.guide
        guard signedGuide.id == source.guideID,
              signedSource.metadata.contentSHA256 == source.corpusContentSHA256 else {
            clearPendingRequest(token: token)
            return .failed(.guideUnavailable)
        }
        let surface = signedGuide.surface
        guard surface.isAgentCallable,
              Self.isAdmissibleAgentGuide(signedGuide),
              let presentation = GuidedHelpPresentationGuide(
                signedGuide: signedGuide,
                corpusDigest: signedSource.metadata.contentSHA256)
        else {
            clearPendingRequest(token: token)
            return .failed(.unsupportedSurface)
        }

        // Loading and signed admission are intentionally non-disruptive. An unknown, historical,
        // or non-agent-callable id must not dismiss a valid guide the person is already following.
        replaceActivePresentation()
        activeSessionToken = token

        guard let destination = await destination(
            for: surface,
            token: token,
            source: source,
            deadline: deadline) else {
            let requestStillCurrent = requestIsCurrent(
                token, source: source, deadline: deadline)
            let failure = requestFailure(source: source, deadline: deadline)
            clearPendingRequest(token: token)
            return requestStillCurrent
                ? .failed(.destinationUnavailable)
                : .failed(failure)
        }
        let targetBridge = destination.bridge
        let targetWindow = destination.window

        guard await targetBridgeIsReady(
            targetBridge,
            window: targetWindow,
            surface: surface,
            token: token,
            source: source,
            deadline: deadline
        ) else {
            let requestStillCurrent = requestIsCurrent(
                token, source: source, deadline: deadline)
            let failure = requestFailure(source: source, deadline: deadline)
            clearPendingRequest(token: token)
            return requestStillCurrent
                ? .failed(.destinationUnavailable)
                : .failed(failure)
        }
        guard let coordinator = GuidedHelpPresentationCoordinator(
            bridge: targetBridge,
            window: targetWindow)
        else {
            clearPendingRequest(token: token)
            return .failed(.destinationUnavailable)
        }

        let navigation = navigationPlan(
            surface: surface,
            bridge: targetBridge,
            steps: presentation.steps)
        navigation.reveal(presentation.steps.first)
        targetCoordinator = coordinator

        let targets = Set(presentation.steps.map(\.target))
        guard await targetsAreRegistered(
            targets,
            coordinator: coordinator,
            token: token,
            source: source,
            deadline: deadline
        ) else {
            let requestStillCurrent = requestIsCurrent(
                token, source: source, deadline: deadline)
            let failure = requestFailure(source: source, deadline: deadline)
            navigation.restoreIfUnchanged()
            clearPendingRequest(token: token, coordinator: coordinator)
            return requestStillCurrent
                ? .failed(.targetUnavailable)
                : .failed(failure)
        }

        let hooks = GuidedHelpPresentationHooks(
            prepareStep: { [weak coordinator, weak navigation] step, temporaryState in
                guard let navigation, navigation.admits(step) else {
                    coordinator?.exit()
                    return
                }
                _ = temporaryState.restoreOnEnd(key: .init(navigation.restorationKey)) {
                    navigation.restoreIfUnchanged()
                }
                navigation.reveal(step)
            },
            didFinish: { [weak self, weak coordinator] _ in
                guard let self,
                      self.activeSessionToken == token,
                      self.targetCoordinator === coordinator else { return }
                self.targetCoordinator = nil
                self.forcedInspector = nil
                self.activeSessionToken = nil
                if self.latestRequestToken == token { self.latestRequestToken = nil }
            },
            // Done leaves a surface the workspace already showed in place. Exit, replacement, owner
            // drift, and a tab the guide had to force back into the bar restore only the app-owned
            // navigation that is still unchanged.
            restoresTemporaryState: { reason in
                reason != .completed || !navigation.keepsRevealedSurfaceOnCompletion
            })

        guard requestIsCurrent(token, source: source, deadline: deadline) else {
            let failure = requestFailure(source: source, deadline: deadline)
            navigation.restoreIfUnchanged()
            clearPendingRequest(token: token, coordinator: coordinator)
            return .failed(failure)
        }
        guard coordinator.present(presentation, hooks: hooks) == .started else {
            navigation.restoreIfUnchanged()
            clearPendingRequest(token: token, coordinator: coordinator)
            return .failed(.presentationRejected)
        }
        return .started(title: signedGuide.title, sessionToken: token)
    }

    /// A tool-result write failure may cancel only the session it started. A stale response from an
    /// older request cannot dismiss a newer guide.
    func cancel(sessionToken: UUID) {
        guard sessionToken == activeSessionToken else { return }
        targetCoordinator?.exit()
        targetCoordinator = nil
        forcedInspector = nil
        activeSessionToken = nil
        if latestRequestToken == sessionToken { latestRequestToken = nil }
    }

    private func replaceActivePresentation() {
        let replacedToken = activeSessionToken
        activeSessionToken = nil
        targetCoordinator?.exit()
        targetCoordinator = nil
        forcedInspector = nil
        if latestRequestToken == replacedToken { latestRequestToken = nil }
    }

    private func clearPendingRequest(
        token: UUID,
        coordinator: GuidedHelpPresentationCoordinator? = nil
    ) {
        if latestRequestToken == token { latestRequestToken = nil }
        guard activeSessionToken == token else { return }
        if coordinator == nil || targetCoordinator === coordinator {
            targetCoordinator?.exit()
            targetCoordinator = nil
            forcedInspector = nil
        }
        activeSessionToken = nil
    }

    private func requestIsCurrent(
        _ token: UUID,
        source: MechanicianGuidanceSourceAdmission,
        deadline: TimeInterval
    ) -> Bool {
        monotonicNow() <= deadline
            && latestRequestToken == token
            && source.isCurrent
            && productAccessAllowed()
    }

    private func requestFailure(
        source: MechanicianGuidanceSourceAdmission,
        deadline: TimeInterval
    ) -> MechanicianGuidanceStartFailure {
        if monotonicNow() > deadline { return .requestExpired }
        return .sourceInvalidated
    }

    /// Resolve the one window a signed surface may be presented in.
    ///
    /// Help may be created on first use because it is an app-owned reserved workspace with a
    /// canonical identity. A conversation surface is never created: it is the person's own window,
    /// and inventing a workspace to satisfy a demonstration would be a product change, not a
    /// demonstration.
    private func destination(
        for surface: MechanicianHelpGuideSurface,
        token: UUID,
        source: MechanicianGuidanceSourceAdmission,
        deadline: TimeInterval
    ) async -> (bridge: AgentBridge, window: NSWindow)? {
        switch surface {
        case .helpWorkspaceInspector:
            return nil
        case .conversationWorkspace:
            guard requestIsCurrent(token, source: source, deadline: deadline),
                  let bridge = resolveConversationWorkspace(source.currentBridge),
                  Self.conversationDestinationIsEligible(bridge),
                  let window = bridge.window else { return nil }
            return (bridge, window)
        }
    }

    private func navigationPlan(
        surface: MechanicianHelpGuideSurface,
        bridge: AgentBridge,
        steps: [GuidedHelpPresentationStep]
    ) -> MechanicianGuidanceNavigationPlan {
        switch surface {
        case .conversationWorkspace:
            let snapshot = ConversationGuidanceNavigationSnapshot(bridge: bridge)
            let tabs = Set(steps.compactMap { Self.inspectorTab(for: $0.target) })
            return MechanicianGuidanceNavigationPlan(
                restorationKey: "show-mechanician-conversation-navigation",
                admits: { Self.isAdmissibleConversationStep($0) },
                onReveal: { [weak self] step in
                    let tab = step.flatMap { Self.inspectorTab(for: $0.target) }
                    guard !tabs.isEmpty else { return }
                    self?.forcedInspector = ForcedInspectorTabs(
                        bridgeID: bridge.bridgeID,
                        tabs: tabs,
                        selected: tab)
                    guard let tab else { return }
                    snapshot.reveal(tab: tab)
                },
                onRestore: { snapshot.restoreIfUnchanged() },
                keepsRevealedSurface: { snapshot.leavesRevealedTabInPlace })
        case .helpWorkspaceInspector:
            // Unreachable: a Help-local tour is never agent-callable and never reaches a plan.
            return MechanicianGuidanceNavigationPlan(
                restorationKey: "show-mechanician-unsupported-navigation",
                admits: { _ in false },
                onReveal: { _ in },
                onRestore: {},
                keepsRevealedSurface: { false })
        }
    }

    /// Which inspector tab a semantic target lives on, if any. Composer controls belong to no tab
    /// and must never make a guide reveal the inspector.
    static func inspectorTab(for target: GuidedHelpPresentationTarget) -> InspectorTab? {
        switch target {
        case .conversationFilesTab: .files
        case .conversationChangesTab: .changes
        case .conversationArtifactsTab: .artifacts
        case .conversationAgentsTab: .agents
        case .conversationSkillsTab: .skills
        case .helpInspectorTab, .helpTopics, .helpSearchField, .helpArticleContent,
             .helpArticleEvidence, .helpDemonstrations: .help
        case .conversationModelControl, .conversationEffortControl,
             .conversationPermissionControl, .conversationComposer: nil
        }
    }

    /// A conversation guide may only be presented in an ordinary standard conversation window.
    /// Help is a reserved workspace with a deliberately closed provider profile; a demonstration
    /// must not turn it into a general-purpose destination.
    static func conversationDestinationIsEligible(_ bridge: AgentBridge) -> Bool {
        guard bridge.window != nil else { return false }
        guard !ReservedWorkspace.owns(bridge.projectID) else { return false }
        if let conversation = bridge.currentConversation,
           AgentBridge.toolProfile(for: conversation) != .standard {
            return false
        }
        return true
    }

    /// The frontmost eligible conversation window in the app's own window order. Order matters:
    /// `AgentBridge.live` has no ordering, and picking arbitrarily would present the guide in
    /// whichever window the runtime happened to hand back.
    static func frontmostEligibleConversationBridge() -> AgentBridge? {
        let eligible = AgentBridge.live.allObjects.filter(conversationDestinationIsEligible)
        guard !eligible.isEmpty else { return nil }
        for window in NSApp.orderedWindows {
            if let match = eligible.first(where: { $0.window === window }) { return match }
        }
        // Every candidate is off screen or miniaturized. Choose deterministically rather than
        // taking whichever object the runtime happened to hand back; focusing deminiaturizes it.
        return eligible.min(by: { $0.bridgeID.uuidString < $1.bridgeID.uuidString })
    }

    private static func destinationRemainsValid(
        _ bridge: AgentBridge,
        surface: MechanicianHelpGuideSurface
    ) -> Bool {
        switch surface {
        case .helpWorkspaceInspector: false
        case .conversationWorkspace: conversationDestinationIsEligible(bridge)
        }
    }

    private func targetBridgeIsReady(
        _ bridge: AgentBridge,
        window: NSWindow,
        surface: MechanicianHelpGuideSurface,
        token: UUID,
        source: MechanicianGuidanceSourceAdmission,
        deadline: TimeInterval
    ) async -> Bool {
        for _ in 0..<targetRegistrationAttempts {
            guard requestIsCurrent(token, source: source, deadline: deadline),
                  bridge.window === window,
                  Self.destinationRemainsValid(bridge, surface: surface) else {
                return false
            }
            if targetIsReady(bridge, window) { return true }
            if targetRegistrationDelayNanoseconds > 0 {
                try? await Task.sleep(nanoseconds: targetRegistrationDelayNanoseconds)
            } else {
                await Task.yield()
            }
        }
        return false
    }

    private func targetsAreRegistered(
        _ targets: Set<GuidedHelpPresentationTarget>,
        coordinator: GuidedHelpPresentationCoordinator,
        token: UUID,
        source: MechanicianGuidanceSourceAdmission,
        deadline: TimeInterval
    ) async -> Bool {
        for _ in 0..<targetRegistrationAttempts {
            guard requestIsCurrent(token, source: source, deadline: deadline),
                  targetCoordinator === coordinator,
                  coordinator.owner.currentWindow != nil else { return false }
            if targets.allSatisfy({ target in
                if case .available = coordinator.registry.resolve(target) { return true }
                return false
            }) {
                return true
            }
            if targetRegistrationDelayNanoseconds > 0 {
                try? await Task.sleep(nanoseconds: targetRegistrationDelayNanoseconds)
            } else {
                await Task.yield()
            }
        }
        return false
    }

    /// Signed admission for every agent-callable surface. The surface decides which
    /// target/reveal pairs are meaningful; a step that names a pair its surface cannot perform is
    /// a corpus defect and fails the whole guide rather than being skipped.
    nonisolated static func isAdmissibleAgentGuide(_ guide: MechanicianHelpGuide) -> Bool {
        guard guide.surface.isAgentCallable,
              guide.lifecycle == .current,
              !guide.steps.isEmpty else { return false }
        return guide.steps.allSatisfy { step in
            guard let mapped = GuidedHelpPresentationStep(signedStep: step) else { return false }
            switch guide.surface {
            case .conversationWorkspace: return isAdmissibleConversationStep(mapped)
            case .helpWorkspaceInspector: return false
            }
        }
    }

    nonisolated static func isAdmissibleConversationStep(
        _ step: GuidedHelpPresentationStep
    ) -> Bool {
        guard step.completion == .userAdvance else { return false }
        switch (step.target, step.revealAction) {
        case (.conversationFilesTab, .showFilesInspector),
             (.conversationChangesTab, .showChangesInspector),
             (.conversationArtifactsTab, .showArtifactsInspector),
             (.conversationAgentsTab, .showAgentsInspector),
             (.conversationSkillsTab, .showSkillsInspector),
             (.conversationModelControl, .showConversationControls),
             (.conversationEffortControl, .showConversationControls),
             (.conversationPermissionControl, .showConversationControls),
             (.conversationComposer, .showConversationControls),
             (.conversationFilesTab, .none),
             (.conversationChangesTab, .none),
             (.conversationArtifactsTab, .none),
             (.conversationAgentsTab, .none),
             (.conversationSkillsTab, .none),
             (.conversationModelControl, .none),
             (.conversationEffortControl, .none),
             (.conversationPermissionControl, .none),
             (.conversationComposer, .none):
            return true
        default:
            return false
        }
    }

}

/// One surface's reveal-and-restore behavior, resolved once per presentation.
///
/// The plan exists so the router's session, timeout, and drift rules stay in one place while each
/// destination keeps its own idea of what "reveal" and "put it back" mean.
@MainActor
final class MechanicianGuidanceNavigationPlan {
    let restorationKey: String
    private let admitsStep: (GuidedHelpPresentationStep) -> Bool
    private let onReveal: @MainActor (GuidedHelpPresentationStep?) -> Void
    private let onRestore: @MainActor () -> Void
    private let keepsRevealedSurface: @MainActor () -> Bool

    init(
        restorationKey: String,
        admits: @escaping (GuidedHelpPresentationStep) -> Bool,
        onReveal: @escaping @MainActor (GuidedHelpPresentationStep?) -> Void,
        onRestore: @escaping @MainActor () -> Void,
        keepsRevealedSurface: @escaping @MainActor () -> Bool
    ) {
        self.restorationKey = restorationKey
        admitsStep = admits
        self.onReveal = onReveal
        self.onRestore = onRestore
        self.keepsRevealedSurface = keepsRevealedSurface
    }

    func admits(_ step: GuidedHelpPresentationStep) -> Bool { admitsStep(step) }

    func reveal(_ step: GuidedHelpPresentationStep?) { onReveal(step) }

    func restoreIfUnchanged() { onRestore() }

    var keepsRevealedSurfaceOnCompletion: Bool { keepsRevealedSurface() }
}

/// State a conversation guide changed before installing its overlay.
///
/// Conditional restoration: a later choice by the person wins. The difference
/// is that a conversation guide may point at several tabs, so it records the one it actually
/// selected rather than assuming a single destination.
@MainActor
final class ConversationGuidanceNavigationSnapshot {
    private static let inspectorFallbackKey = "panel.inspector"
    private weak var bridge: AgentBridge?
    private let preferences: UserDefaults
    private let projectID: UUID?
    private let conversationID: UUID?
    private let initialInspectorVisible: Bool
    private let initialTab: InspectorTab
    private let initialActivation: InspectorTabUserActivation?
    private let inspectorFallbackExisted: Bool
    private let inspectorFallbackValue: Bool
    let initialVisibleTabs: Set<InspectorTab>
    private(set) var revealedTab: InspectorTab?

    init(bridge: AgentBridge, preferences: UserDefaults = .standard) {
        self.bridge = bridge
        self.preferences = preferences
        projectID = bridge.projectID
        conversationID = bridge.currentID
        initialInspectorVisible = bridge.showInspector
        initialTab = bridge.inspectorTab
        initialActivation = bridge.inspectorTabUserActivation
        inspectorFallbackExisted = preferences.object(
            forKey: Self.inspectorFallbackKey) != nil
        inspectorFallbackValue = preferences.bool(forKey: Self.inspectorFallbackKey)
        initialVisibleTabs = Set(bridge.visibleInspectorTabs(store: preferences))
    }

    func reveal(tab: InspectorTab) {
        guard let bridge,
              bridge.projectID == projectID,
              bridge.currentID == conversationID,
              !ReservedWorkspace.owns(bridge.projectID) else { return }
        bridge.showInspector = true
        restoreInspectorFallback()
        bridge.inspectorTab = tab
        revealedTab = tab
    }

    func restoreIfUnchanged() {
        guard let revealedTab,
              let bridge,
              bridge.projectID == projectID,
              bridge.currentID == conversationID else { return }
        if bridge.inspectorTabUserActivation == initialActivation,
           bridge.inspectorTab == revealedTab {
            bridge.inspectorTab = initialTab
        }
        if bridge.showInspector { bridge.showInspector = initialInspectorVisible }
        restoreInspectorFallback()
    }

    /// True when the guide selected a tab this workspace already showed. Leaving that on screen is
    /// the point of the demonstration; leaving a tab the guide had to force into the bar would edit
    /// the person's tab set by side effect.
    var leavesRevealedTabInPlace: Bool {
        guard let revealedTab else { return false }
        return initialVisibleTabs.contains(revealedTab)
    }

    /// `showInspector` persists a process-wide new-window fallback in `didSet`. A guide is
    /// per-window presentation, so put that exact prior fallback back around every owned write.
    private func restoreInspectorFallback() {
        if inspectorFallbackExisted {
            preferences.set(inspectorFallbackValue, forKey: Self.inspectorFallbackKey)
        } else {
            preferences.removeObject(forKey: Self.inspectorFallbackKey)
        }
    }
}
