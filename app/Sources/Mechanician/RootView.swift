import SwiftUI
import AppKit

/// Help demonstrations always draft into a person-controlled standard Workspace. Product-owned
/// expert Workspaces remain closed destinations even before their provider profile is selected.
func standardConversationDraftAllowsWorkspace(_ scope: WorkspaceScope) -> Bool {
    !ReservedWorkspace.owns(scope)
}

struct LaunchServicesAttachmentBatch {
    var payloads: [String]
    var artifacts: [ArtifactDragReference]
}

/// A Finder/Dock open belongs to the workspace that was active when Launch Services delivered it.
/// Keep that identity even while the bridge is still booting: another window becoming ready first
/// must not steal the files. `conversationID` is captured when one already exists so a navigation
/// before delivery still targets the conversation the user was looking at.
@MainActor
private final class PendingLaunchServicesDelivery {
    let files: [URL]
    weak var bridge: AgentBridge?
    var conversationID: UUID?
    var isBound: Bool

    init(files: [URL], bridge: AgentBridge?, conversationID: UUID?) {
        self.files = files
        self.bridge = bridge
        self.conversationID = conversationID
        isBound = bridge != nil
    }

    func bind(to bridge: AgentBridge) {
        guard !isBound else { return }
        self.bridge = bridge
        conversationID = conversationID ?? bridge.currentID
        isBound = true
    }

    func targets(_ bridge: AgentBridge) -> Bool {
        isBound && self.bridge === bridge
    }
}

/// A Help demonstration belongs to the exact standard-profile workspace lane selected when the
/// user asks to try it. Unlike the process-global Services draft slot, this cannot be consumed by
/// whichever bridge happens to become ready first. Retaining the window identity as well as the
/// bridge keeps tabbed workspace lanes isolated too.
@MainActor
private final class PendingStandardConversationDraft {
    let text: String
    let workspaceScope: WorkspaceScope
    weak var bridge: AgentBridge?
    weak var window: NSWindow?

    init(text: String, workspaceScope: WorkspaceScope, bridge: AgentBridge) {
        self.text = text
        self.workspaceScope = workspaceScope
        self.bridge = bridge
        window = bridge.window
    }

    func belongs(to bridge: AgentBridge) -> Bool {
        self.bridge === bridge
    }

    func targets(_ bridge: AgentBridge) -> Bool {
        guard self.bridge === bridge else { return false }
        guard let window else { return bridge.window == nil }
        return bridge.window === window
    }
}

/// A local Help handoff must mint a new Conversation. If workspace resolution made
/// `newConversation()` a no-op, the old id is not authority to receive the demonstration draft.
func standardConversationDraftCreatedID(previousID: UUID?, currentID: UUID?) -> UUID? {
    guard let currentID, currentID != previousID else { return nil }
    return currentID
}

/// Launch Services, whole-chat drops, the paperclip picker, and composer drops all share the same
/// one-gesture cap. Keeping this as a focused function also makes the app-delegate route testable
/// without mutating the process-wide active-window singleton.
@MainActor
func ingestLaunchServicesAttachments(
    _ files: [URL],
    conversationID: UUID,
    store: ConversationStore? = nil
) -> LaunchServicesAttachmentBatch {
    let store = store ?? .shared
    var budget = ConversationAttachmentImportBudget()
    var payloads: [String] = []
    var artifacts: [ArtifactDragReference] = []
    for url in files where url.isFileURL {
        guard let maximumBytes = budget.beginAttachment() else {
            if let message = budget.takeLimitMessage() {
                payloads.append(message)
            }
            break
        }
        let intake = ConversationAttachmentIntake.ingest(
            url,
            conversationID: conversationID,
            maximumBytes: maximumBytes,
            store: store)
        budget.recordCommittedBytes(intake.committedByteCount)
        if case .artifact(let reference) = intake {
            artifacts.append(reference)
        }
        payloads.append(intake.promptPayload)
    }
    return LaunchServicesAttachmentBatch(
        payloads: payloads,
        artifacts: artifacts)
}

/// Tracks the most-recently-active window's bridge so app-level scenes (Settings)
/// can reach it — `@FocusedObject` goes nil once the Settings window takes focus.
@MainActor
final class ActiveWorkspace: ObservableObject {
    static let shared = ActiveWorkspace(productAccessRequest: {
        StorageProductAccessGate.request()
    }, whenProductReady: { operation in
        WorkspaceSessionLaunchGate.shared.whenOpen(operation)
    })

    /// External routes must cross the storage cutover fence before they can construct a product
    /// store. The dependency is explicit so routing tests can exercise their isolated state
    /// machines without configuring the process-global launch authority; the production singleton
    /// always uses `StorageProductAccessGate`.
    private let productAccessRequest: () -> Bool
    private let whenProductReady: (@escaping @MainActor () -> Void) -> Void
    /// Construct a Home window with a per-window fresh-conversation intent. Injected so routing
    /// tests can prove that Help never falls through the generic last-viewed restoration path.
    private let makeFreshHomeWorkspace: @MainActor () -> AgentBridge?

    init(
        productAccessRequest: @escaping () -> Bool,
        whenProductReady: @escaping (@escaping @MainActor () -> Void) -> Void,
        makeFreshHomeWorkspace: @escaping @MainActor () -> AgentBridge? = {
            let window = makeWorkspaceWindow(startsFreshConversation: true)
            return AgentBridge.live.allObjects.first { $0.window === window }
        }
    ) {
        self.productAccessRequest = productAccessRequest
        self.whenProductReady = whenProductReady
        self.makeFreshHomeWorkspace = makeFreshHomeWorkspace
    }
    /// The workspace window that opened the shared Workspaces gallery. The gallery is one reusable
    /// scene reachable from any window, so without this it acted on `bridge` — the last workspace
    /// window that became key — and could rewrite a window the user was not looking at.
    var launcherOriginBridgeID: UUID?
    @Published var bridge: AgentBridge? {
        didSet {
            guard let bridge else { return }
            bindUnassignedFileDeliveries(to: bridge)
        }
    }

    /// Utility windows observe this owner rather than the workspace bridge directly. Republish the
    /// rare provider-route change so account-keyed Extensions state immediately projects the newly
    /// selected conversation without subscribing those windows to every transcript mutation.
    func accessDidChange(_ changed: AgentBridge) {
        if bridge === changed { objectWillChange.send() }
    }
    /// A Services selection held until a window is ready, because a service can be the reason the
    /// app launched at all.
    struct PendingComposerDraft: Equatable {
        let text: String
        /// New Conversation With Selection mints its own; Add Selection to Conversation joins the
        /// one the window restores to.
        let startsNewConversation: Bool
    }

    /// A prompt an App Intent (Siri/Spotlight/Shortcuts) wants delivered — consumed by a
    /// window's bridge once it's ready (covers the app-was-not-running case). Empty string =
    /// "just open a new conversation".
    @Published var pendingPrompt: String?
    /// A Services selection waiting for a window, and whether it starts its own conversation.
    ///
    /// Deliberately **not** `pendingPrompt`: that slot is consumed by `send`, and the rule that a
    /// Services selection is never submitted has to survive the queue as well as the route. Two
    /// slots with two consumers is what keeps a prefill from ever reaching the sending path.
    @Published var pendingDraft: PendingComposerDraft?
    /// Finder/Dock file opens can arrive before `applicationDidFinishLaunching`. Retain each batch
    /// with its exact destination; readiness in a different window is not authority to consume it.
    private var pendingFileDeliveries: [PendingLaunchServicesDelivery] = []
    /// Internal Help handoffs are draft-only and bound to an exact standard-profile bridge/window.
    /// They do not share either externally writable composer slot above.
    private var pendingStandardConversationDrafts: [PendingStandardConversationDraft] = []

    /// A conversation to open in the next window that becomes ready, for the one case where the
    /// destination genuinely is not known yet: a route arriving before the store has loaded it.
    ///
    /// Every caller that builds the window itself passes `initialConversationID` to
    /// `makeWorkspaceWindow` instead, which binds the conversation to that specific bridge. This
    /// slot is process-global, so two in-flight requests overwrite each other and whichever bridge
    /// readies first consumes it; that is a correctness bug everywhere the destination IS known.
    @Published var pendingOpenConversation: UUID?

    /// The union of in-flight conversations across ALL windows' bridges. Each bridge's own
    /// `runningConvs` is per-window, so a turn started in one window/tab wouldn't light the
    /// spinner on the same conversation listed in another window. Every sidebar observes this
    /// instead, so the "running" mark shows everywhere the conversation appears.
    @Published var runningConversations: Set<UUID> = []

    /// The cross-window union of conversations parked in wait-mode — drives the ⏳ indicator
    /// everywhere the conversation appears, mirroring `runningConversations`.
    @Published var waitingConversations: Set<UUID> = []

    /// Recompute the global running set from every live bridge. Cheap (a handful of bridges);
    /// called from each bridge's `runningConvs` didSet.
    @MainActor func recomputeRunning() {
        var union: Set<UUID> = []
        for b in AgentBridge.live.allObjects { union.formUnion(b.runningConvs) }
        if union != runningConversations { runningConversations = union }
    }

    /// Recompute the global waiting set from every live bridge (from each bridge's `waitingConvs` didSet).
    @MainActor func recomputeWaiting() {
        var union: Set<UUID> = []
        for b in AgentBridge.live.allObjects { union.formUnion(b.waitingConvs) }
        if union != waitingConversations { waitingConversations = union }
    }

    /// Stop routing app-level actions to a bridge whose workspace has closed. If that bridge was
    /// active, prefer another key/main workspace and otherwise retain any surviving live bridge.
    @MainActor func workspaceDidClose(_ closingBridge: AgentBridge) {
        // Closing the exact destination cancels an undelivered Help handoff. It must never float to
        // a surviving lane merely because that lane becomes ready next.
        pendingStandardConversationDrafts.removeAll { $0.belongs(to: closingBridge) }

        // Preserve an exact already-existing destination even if its window closes before readiness.
        // A bridge-less delivery (cold launch before the first conversation exists) can instead bind
        // to the surviving active workspace below.
        let closingDeliveries = pendingFileDeliveries.filter { $0.targets(closingBridge) }
        pendingFileDeliveries.removeAll { delivery in
            closingDeliveries.contains { $0 === delivery }
        }
        var retained: [PendingLaunchServicesDelivery] = []
        for delivery in closingDeliveries {
            if let conversationID = delivery.conversationID,
               closingBridge.store.contains(conversationID) {
                deliver(
                    files: delivery.files,
                    to: closingBridge,
                    conversationID: conversationID)
            } else {
                delivery.bridge = nil
                delivery.isBound = false
                retained.append(delivery)
            }
        }
        pendingFileDeliveries.append(contentsOf: retained)

        guard bridge === closingBridge else {
            if let bridge { bindUnassignedFileDeliveries(to: bridge) }
            return
        }
        let survivors = AgentBridge.live.allObjects.filter { $0 !== closingBridge }
        bridge = survivors.first(where: { $0.window?.isKeyWindow == true })
            ?? survivors.first(where: { $0.window?.isMainWindow == true })
            ?? survivors.first
    }

    /// An artifact a Spotlight result / App Intent asked to open — consumed by the Artifacts
    /// window (RootView opens that window when this is set).
    @Published var pendingSelectArtifact: UUID?

    /// A newly-ready generic bridge consumes the one process-global request whose destination was
    /// genuinely unknown when it arrived. Windows built with a per-window conversation/fresh intent
    /// reject this handoff so an unrelated cold route cannot clobber their exact destination.
    @MainActor func consumeOpenConversation(_ b: AgentBridge) {
        guard b.acceptsProcessGlobalOpenConversation,
              let id = pendingOpenConversation else { return }
        pendingOpenConversation = nil
        // TOCTOU: the target may have been deleted between the click and this window becoming ready,
        // or an owner window may have appeared. Either way this tab cannot show it.
        let owner = AgentBridge.owner(of: id, excluding: b)
        switch NewTabContent.resolve(
            requested: id,
            existsInStore: b.store.hasConversation(id),
            isOwnedByAnotherWindow: owner != nil) {
        case .conversation(let target):
            b.select(target)
        case .freshConversationInSourceWorkspace:
            if owner != nil { _ = AgentBridge.focusOwner(of: id, excluding: b) }
            b.newConversation()
        }
    }

    /// The single entry point for every outside-the-window request to show something: Spotlight,
    /// App Intents, a notification click, a Finder drop. Callers state what they want shown; the
    /// rules for how to show it live below and nowhere else. See `MechanicianRoute`.
    ///
    /// Gated on the store being loaded: a Spotlight hit or notification click can arrive while
    /// the launch decode is still running, and routing to a conversation the store hasn't
    /// published yet would silently drop the request. Once ready, the gate is inline.
    @MainActor @discardableResult func open(_ route: MechanicianRoute) -> Bool {
        guard productAccessRequest() else { return false }
        whenProductReady { [weak self] in
            guard let self else { return }
            switch route {
            case .conversation(let id): self.openConversation(route: id)
            case .artifact(let id): self.openArtifact(route: id)
            case .workspace(let id): self.openWorkspace(route: id)
            case .newConversation(let prompt): self.newConversation(sending: prompt)
            case .newConversationDraft(let text): self.draft(text, startingNewConversation: true)
            case .newStandardConversationDraft(let text): self.draftStandardConversation(text)
            case .appendToComposer(let text, let id): self.draft(text, into: id)
            case .files(let urls): self.attach(files: urls)
            }
        }
        return true
    }

    /// Open a conversation from Spotlight / an App Intent. If a window is open, its bridge opens
    /// the conversation (loading it from disk first if this window hasn't seen it). If the app
    /// wasn't running, queue it for the first window that becomes ready.
    @MainActor private func openConversation(route id: UUID) {
        NSApp.activate(ignoringOtherApps: true)
        // One conversation, one window: if it's already open/running somewhere, focus that window.
        if let owner = AgentBridge.owner(of: id), let win = owner.window {
            owner.select(id)
            win.makeKeyAndOrderFront(nil)
            return
        }
        guard let summary = ConversationStore.shared.summary(id) else {
            pendingOpenConversation = id
            return
        }
        let projects = ProjectStore.shared.projects
        guard let scope = WorkspaceScope.resolve(
            summary: summary,
            projects: projects)
        else { return }
        if let target = AgentBridge.live.allObjects.first(where: {
            Self.workspace($0, matches: scope, projects: projects)
        }), let win = target.window {
            target.openConversation(id)
            win.makeKeyAndOrderFront(nil)
            return
        }

        // A notification for another workspace must not replace the active workspace's conversation.
        let window: NSWindow
        switch scope {
        case .home:
            window = makeWorkspaceWindow(initialConversationID: id)
        case .project(let projectID):
            guard let project = projects.first(where: { $0.id == projectID }) else { return }
            window = makeWorkspaceWindow(
                initialFolder: project.isWorkspace ? project.cwd : nil,
                initialProjectID: project.isWorkspace ? nil : project.id,
                initialConversationID: id)
        }
        window.makeKeyAndOrderFront(nil)
    }

    private static func workspace(
        _ bridge: AgentBridge,
        matches scope: WorkspaceScope,
        projects: [Project]
    ) -> Bool {
        WorkspaceScope.resolve(
            projectID: bridge.projectID,
            cwd: bridge.cwd,
            projects: projects) == scope
    }

    /// Open a workspace from a `mechanician://workspace/…` link. `nil` is Home.
    ///
    /// Both destinations delegate to the policies the launcher, the toolbar switcher, and ⇧⌘H
    /// already share, so a link navigates the way every other route to the same place does — it
    /// focuses an open window rather than opening a second one. `openHome()` rather than
    /// `goHome(from:)` because a link has no originating workspace to replace in place.
    ///
    /// A workspace that has since been removed is a silent no-op: the link named something that no
    /// longer exists, and the alternative is letting any web page raise a dialog.
    @MainActor private func openWorkspace(route id: UUID?) {
        NSApp.activate(ignoringOtherApps: true)
        guard let id else { openHome(); return }
        guard let project = ProjectStore.shared.project(id) else { return }
        openProject(project)
    }

    /// Open an artifact from Spotlight / an App Intent.
    @MainActor private func openArtifact(route id: UUID) {
        NSApp.activate(ignoringOtherApps: true)
        revealArtifact(id)
    }

    /// Surface the Artifacts window and mark `id` for selection; `GlobalArtifactsView` consumes it
    /// once the artifact has loaded. The one way to reveal an artifact, from anywhere.
    ///
    /// This used to be a bare `pendingSelectArtifact` assignment at three call sites, with the
    /// window opened by a `.onChange` inside `DetailView`. That had two problems. A cold launch can
    /// set the property before `DetailView` mounts, and `onChange` never fires for a change that
    /// happened before the view existed, so the request was dropped. And the `onChange` called
    /// `openWindow` directly, bypassing `UtilityWindowVisibility` — the machinery that exists
    /// precisely because SwiftUI retains a closed `Window` scene's native window and will otherwise
    /// build a duplicate.
    @MainActor func revealArtifact(_ id: UUID) {
        pendingSelectArtifact = id
        UtilityWindowVisibility.shared.show(.artifacts) {
            openAppWindowWhenReady(id: UtilityWindowID.artifacts.rawValue)
        }
    }

    /// Deliver a prompt from an App Intent: to the active window now if ready, else queue it
    /// for the next window that becomes ready.
    @MainActor private func newConversation(sending prompt: String?) {
        NSApp.activate(ignoringOtherApps: true)
        if let b = bridge, b.isReady {
            b.newConversation()
            if let p = prompt, !p.isEmpty { b.send(p) }
        } else {
            pendingPrompt = prompt ?? ""
        }
    }

    /// Draft a Help demonstration in a new standard-profile conversation without sending it.
    ///
    /// The active workspace is eligible only when both its durable conversation and its workspace
    /// binding resolve to the standard profile. Memory therefore cannot gain standard tools through
    /// a Help handoff. If the active lane is closed-profile, use an existing Home lane or construct
    /// one, then bind any readiness handoff to that exact bridge and native window.
    @MainActor private func draftStandardConversation(_ text: String) {
        NSApp.activate(ignoringOtherApps: true)
        guard let target = standardConversationDraftTarget() else { return }
        presentStandardConversationDraft(
            text,
            to: target.bridge,
            workspaceScope: target.workspaceScope)
    }

    private typealias StandardConversationDraftTarget = (
        bridge: AgentBridge,
        workspaceScope: WorkspaceScope
    )

    @MainActor private func standardConversationDraftTarget() -> StandardConversationDraftTarget? {
        if let bridge,
           let workspaceScope = Self.standardConversationDraftScope(bridge) {
            return (bridge, workspaceScope)
        }
        return homeStandardConversationDraftTarget()
    }

    @MainActor private func homeStandardConversationDraftTarget(
        excluding excluded: AgentBridge? = nil
    ) -> StandardConversationDraftTarget? {
        let projects = ProjectStore.shared.projects
        if let home = AgentBridge.live.allObjects.first(where: {
            $0 !== excluded
                && $0.window != nil
                && Self.workspace($0, matches: .home, projects: projects)
                && Self.standardConversationDraftScope($0) == .home
        }) {
            return (home, .home)
        }

        guard let home = makeFreshHomeWorkspace(), home !== excluded,
              Self.standardConversationDraftScope(home) == .home else { return nil }
        return (home, .home)
    }

    /// Resolve both the durable current conversation and the bridge's prospective workspace. The
    /// identities must agree: a delayed handoff may not float from Home/project A into project B,
    /// and an unresolved/deleted Project is never widened to Home by guesswork.
    private static func standardConversationDraftScope(
        _ bridge: AgentBridge
    ) -> WorkspaceScope? {
        let projects = ProjectStore.shared.projects
        guard let workspaceScope = WorkspaceScope.resolve(
            projectID: bridge.projectID,
            cwd: bridge.cwd,
            projects: projects),
              standardConversationDraftAllowsWorkspace(workspaceScope) else { return nil }
        guard let conversation = bridge.currentConversation else { return workspaceScope }
        guard AgentBridge.toolProfile(for: conversation) == .standard,
              WorkspaceScope.resolve(conversation: conversation, projects: projects)
                == workspaceScope else { return nil }
        return workspaceScope
    }

    @MainActor private func presentStandardConversationDraft(
        _ text: String,
        to target: AgentBridge,
        workspaceScope: WorkspaceScope
    ) {
        // Provider readiness is irrelevant to a local unsent draft. An already-installed
        // Conversation is sufficient; otherwise wait only for this window's local initial view.
        if target.currentConversation != nil || !target.initialViewResolutionPending {
            deliverStandardConversationDraft(
                text,
                to: target,
                workspaceScope: workspaceScope)
        } else {
            pendingStandardConversationDrafts.append(
                PendingStandardConversationDraft(
                    text: text,
                    workspaceScope: workspaceScope,
                    bridge: target))
        }
        if let window = target.window {
            if window.isMiniaturized { window.deminiaturize(nil) }
            window.makeKeyAndOrderFront(nil)
        }
    }

    /// There is intentionally no `send` path here. Revalidate at consumption because a workspace
    /// can be switched while its local initial view is resolving; a late handoff may never float to
    /// another standard workspace or turn a closed-profile lane into a standard conversation.
    @MainActor private func deliverStandardConversationDraft(
        _ text: String,
        to target: AgentBridge,
        workspaceScope: WorkspaceScope
    ) {
        guard Self.standardConversationDraftScope(target) == workspaceScope else {
            rerouteStandardConversationDraftToHome(text, excluding: target)
            return
        }
        let previousID = target.currentID
        target.newConversation()
        guard let id = standardConversationDraftCreatedID(
                previousID: previousID,
                currentID: target.currentID),
              let conversation = target.currentConversation,
              AgentBridge.toolProfile(for: conversation) == .standard,
              Self.standardConversationDraftScope(target) == workspaceScope else {
            // `newConversation()` deliberately no-ops for an unresolved/deleted Project. Never append
            // the Help request to the old Conversation merely because its id remained current.
            rerouteStandardConversationDraftToHome(text, excluding: target)
            return
        }
        target.inject(text, into: id)
        target.focusComposer()
    }

    @MainActor private func rerouteStandardConversationDraftToHome(
        _ text: String,
        excluding target: AgentBridge
    ) {
        guard let home = homeStandardConversationDraftTarget(excluding: target) else { return }
        presentStandardConversationDraft(
            text,
            to: home.bridge,
            workspaceScope: home.workspaceScope)
    }

    /// Put a Services selection in a composer without submitting it.
    ///
    /// `startingNewConversation` is the difference between the two text services: New Conversation
    /// With Selection mints one and matches ⌘N exactly (`newConversation()` never reuses an empty
    /// conversation and already ends by focusing the composer), while Add Selection to Conversation
    /// joins whatever is on screen. When nothing is ready this parks, and the parked copy carries the
    /// same distinction — see `pendingDraft`.
    ///
    /// `inject(_:into:)` rather than a direct draft write: it is the existing external-writer path,
    /// and it already handles both delivery orders, appends on its own line, and reaches the live
    /// composer object when the conversation is the visible one.
    /// **Only the new-conversation service comes to the front** (decision 3, David 2026-08-01: split
    /// them). Asking for a new conversation is asking to see it, so that one activates and matches
    /// Mail's New Email With Selection. Adding to a conversation is collecting material while you
    /// read, so it stays quiet like Add to Reading List — clipping four passages out of Safari should
    /// not yank you out of Safari four times. The composer is still focused either way, so the text is
    /// ready to type after when you do come back.
    @MainActor private func draft(_ text: String, startingNewConversation: Bool) {
        if startingNewConversation { NSApp.activate(ignoringOtherApps: true) }
        guard let b = bridge, b.isReady else {
            pendingDraft = PendingComposerDraft(text: text, startsNewConversation: startingNewConversation)
            return
        }
        if startingNewConversation || b.currentID == nil { b.newConversation() }
        guard let id = b.currentID else { return }
        b.inject(text, into: id)
        if startingNewConversation, let window = b.window {
            if window.isMiniaturized { window.deminiaturize(nil) }
            window.makeKeyAndOrderFront(nil)
        }
        b.focusComposer()
    }

    /// Add text to a named conversation's composer, opening it first.
    ///
    /// A link that names a conversation is asking to be taken there, so this always activates —
    /// unlike the quiet Services append, whose whole point is not moving you. `openConversation`
    /// does the focus-or-open, and the inject targets that exact id rather than "whatever is current
    /// now", so it lands correctly whichever order those two resolve in.
    @MainActor private func draft(_ text: String, into conversationID: UUID?) {
        guard let conversationID else { return draft(text, startingNewConversation: false) }
        openConversation(route: conversationID)
        guard let b = AgentBridge.owner(of: conversationID) ?? bridge, b.isReady else {
            // The window is still coming up. `inject` writes through to the durable draft, so this
            // is safe to do without a live composer; the store carries it until one appears.
            ConversationStore.shared.updateAfterAcquiring(conversationID) { conversation in
                let base = conversation.draft
                conversation.draft = base + (base.isEmpty ? "" : "\n") + text
            }
            return
        }
        b.inject(text, into: conversationID)
        b.focusComposer()
    }

    /// Accept Finder items delivered through Launch Services (including a drop on the Dock icon).
    /// `LSHandlerRank=None` means the app accepts this drop without appearing as an Open With app.
    @MainActor private func attach(files urls: [URL]) {
        let files = urls.filter {
            $0.isFileURL && FileManager.default.fileExists(atPath: $0.path)
        }
        guard !files.isEmpty else { return }
        NSApp.activate(ignoringOtherApps: true)
        guard let bridge, bridge.isReady, let conversationID = bridge.currentID else {
            pendingFileDeliveries.append(PendingLaunchServicesDelivery(
                files: files,
                bridge: bridge,
                conversationID: bridge?.currentID))
            return
        }
        deliver(files: files, to: bridge, conversationID: conversationID)
    }

    nonisolated static func attachmentPrompt(for urls: [URL]) -> String? {
        let paths = urls.filter(\.isFileURL).map(\.path)
        return paths.isEmpty ? nil : paths.joined(separator: "\n")
    }

    @MainActor private func deliver(
        files: [URL],
        to bridge: AgentBridge,
        conversationID: UUID
    ) {
        guard bridge.store.contains(conversationID) else { return }
        let batch = ingestLaunchServicesAttachments(
            files,
            conversationID: conversationID)
        for artifact in batch.artifacts {
            bridge.referenceArtifact(artifact, in: conversationID)
        }
        guard !batch.payloads.isEmpty else { return }
        let payload = batch.payloads.joined(separator: "\n")
        bridge.inject(payload, into: conversationID)
        if bridge.currentID == conversationID, let window = bridge.window {
            if window.isMiniaturized { window.deminiaturize(nil) }
            window.makeKeyAndOrderFront(nil)
        }
        if bridge.currentID == conversationID {
            bridge.focusComposer()
        }
    }

    /// Consume only local Help composer handoffs. This separate entry point lets initial-view
    /// readiness unblock a signed-out draft without accidentally consuming an App-Intent prompt,
    /// whose `send` path must remain behind provider readiness.
    @MainActor func consumePendingStandardConversationDrafts(_ b: AgentBridge) {
        let standardDrafts = pendingStandardConversationDrafts.filter { $0.targets(b) }
        pendingStandardConversationDrafts.removeAll { draft in
            standardDrafts.contains { $0 === draft }
        }
        for draft in standardDrafts {
            deliverStandardConversationDraft(
                draft.text,
                to: b,
                workspaceScope: draft.workspaceScope)
        }
    }

    /// A newly-ready bridge consumes any queued intent prompt and Finder attachments.
    @MainActor func consumePending(_ b: AgentBridge) {
        if let p = pendingPrompt {
            pendingPrompt = nil
            b.newConversation()
            if !p.isEmpty { b.send(p) }
        }
        // A parked Services selection. Separate from the branch above on purpose: this one has no
        // `send` in it, and that is the whole reason the two slots are not one.
        if let parked = pendingDraft {
            pendingDraft = nil
            if parked.startsNewConversation || b.currentID == nil { b.newConversation() }
            if let id = b.currentID {
                b.inject(parked.text, into: id)
                b.focusComposer()
            }
        }
        consumePendingStandardConversationDrafts(b)
        if bridge === b {
            bindUnassignedFileDeliveries(to: b)
        }
        let deliveries = pendingFileDeliveries.filter { $0.targets(b) }
        guard !deliveries.isEmpty else { return }
        for delivery in deliveries {
            if delivery.conversationID == nil {
                if b.currentID == nil { b.newConversation() }
                delivery.conversationID = b.currentID
            }
            guard let conversationID = delivery.conversationID,
                  b.store.contains(conversationID) else { continue }
            deliver(
                files: delivery.files,
                to: b,
                conversationID: conversationID)
        }
        pendingFileDeliveries.removeAll { delivery in
            deliveries.contains { $0 === delivery }
        }
    }

    private func bindUnassignedFileDeliveries(to bridge: AgentBridge) {
        for delivery in pendingFileDeliveries where !delivery.isBound {
            delivery.bind(to: bridge)
        }
    }
}

/// Sidebar (conversation list) + chat detail.
/// The detail side of a workspace window — the transcript (ContentView) + optional inspector — hosted
/// in the AppKit NSSplitViewController's content item. The sidebar is a separate hosted SidebarView;
/// the window chrome (toolbar, tracking separator, sidebar collapse, tab title) is owned by
/// WorkspaceToolbarController. The bridge is created by makeWorkspaceWindow and injected here.
struct DetailColumnLayout: Equatable {
    static let minimumChatWidth: CGFloat = 300
    static let minimumInspectorWidth = CGFloat(InspectorWidthPreference.minimum)
    static let resizeSeamWidth: CGFloat = 1

    /// THERE IS NO FIXED CAP. The only limit is the composer's floor.
    ///
    /// It used to be a flat 520 so a file tree could not eat the transcript, then briefly 520 for
    /// lists and 700 for the Wiki. David: *"can we just let all inspector panes expand more fully
    /// like the memory window. I see no advantage in preventing the pane from getting wider."* He is
    /// right, and the per-tab version was a rule that had to be explained rather than felt — the
    /// person dragging the handle knows what they want to see.
    ///
    /// What remains is the constraint that actually protects something: the chat keeps 300pt, so the
    /// composer can never be squeezed however far the handle is dragged. Everything past that was
    /// the app deciding on someone's behalf.
    static func maximumInspectorWidth(availableWidth: CGFloat) -> CGFloat {
        max(minimumInspectorWidth, availableWidth - minimumChatWidth - resizeSeamWidth)
    }

    /// A resize cursor must never advertise a drag when the protected chat floor leaves no range.
    /// At exactly 481pt the inspector can be 180pt, but both ends of its range are 180pt; the old
    /// handle appeared there and then ignored every drag, which read as a frozen panel.
    static func hasInspectorResizeRange(availableWidth: CGFloat) -> Bool {
        maximumInspectorWidth(availableWidth: availableWidth) > minimumInspectorWidth
    }

    let chatWidth: CGFloat
    let inspectorWidth: CGFloat

    /// The conversation is not on screen, so there is nothing on the other side of the seam to
    /// drag against and nothing to draw a divider between.
    var inspectorIsFullWidth: Bool { chatWidth == 0 && inspectorWidth > 0 }

    var inspectorIsResizable: Bool {
        inspectorWidth >= Self.minimumInspectorWidth
    }

    /// The inspector taking the whole window, with the conversation stepped aside.
    ///
    /// NOT A SECOND WINDOW. What made two wiki views bad was two EDITORS — a window and a workspace
    /// both changing the same record and drifting apart. This is the one record, temporarily wider:
    /// same view, same state, nothing to keep in step, and one press to put the conversation back.
    ///
    /// It exists because the fold left the record in a column, and a column that must also carry a
    /// header of controls has very little height and width left for the article it is FOR.
    static func expanded(availableWidth: CGFloat) -> DetailColumnLayout {
        DetailColumnLayout(chatWidth: 0, inspectorWidth: max(0, availableWidth))
    }

    static func resolve(
        availableWidth: CGFloat,
        preferredInspectorWidth: CGFloat,
        showsInspector: Bool,
        expanded: Bool = false
    ) -> DetailColumnLayout {
        let available = max(0, availableWidth)
        guard showsInspector else {
            return DetailColumnLayout(chatWidth: available, inspectorWidth: 0)
        }
        if expanded { return Self.expanded(availableWidth: available) }
        let preferred = max(preferredInspectorWidth, minimumInspectorWidth)
        // The preferred inspector width is durable, but the displayed width yields first when the
        // window gets short. This protects the command composer without permanently changing what
        // the inspector grows back to when space returns.
        let maximumDisplayedInspector = max(
            0,
            available - minimumChatWidth - resizeSeamWidth)
        let displayedInspector = min(preferred, maximumDisplayedInspector)
        return DetailColumnLayout(
            chatWidth: max(
                0,
                available - displayedInspector - resizeSeamWidth),
            inspectorWidth: displayedInspector)
    }
}

/// Resolve a drag against the width the user can actually see, while retaining a larger durable
/// preference when the chat's protected minimum is what currently limits the inspector.
enum ResponsiveResizeDrag {
    static func preferredSize(
        preferredSize: Double,
        displayedSize: Double,
        translation: Double,
        range: ClosedRange<Double>
    ) -> Double {
        let preferred = min(max(preferredSize, range.lowerBound), range.upperBound)
        let displayed = max(0, displayedSize)

        // A negative translation asks the trailing panel to grow. When responsive layout has
        // already reduced that panel below its preference there is no available room to reveal,
        // so preserve the preference that should return when the window grows.
        if displayed < preferred, translation <= 0 {
            return preferred
        }

        // A positive translation shrinks from the visible edge immediately. Starting from the
        // stored preference would create a dead zone equal to the responsive reduction.
        return min(
            max(displayed - translation, range.lowerBound),
            range.upperBound)
    }
}

struct DetailView: View {
    @ObservedObject var bridge: AgentBridge
    @ObservedObject private var elicitations = ElicitationStore.shared
    @ObservedObject private var active = ActiveWorkspace.shared
    @ObservedObject private var projects = ProjectStore.shared
    @ObservedObject private var conversationStore = ConversationStore.shared
    @Environment(\.openWindow) private var openWindow
    @AppStorage("uiTypeStep") private var typeStep = 0
    /// One combined disk-failure line: conversation saves first (they carry user words), then
    /// workspace saves. Retry re-enqueues both — partial recovery clears each side on its own.
    private var persistenceBannerMessage: String? {
        conversationStore.persistenceError
            ?? conversationStore.hydrationError
            ?? projects.persistenceError
    }

    var body: some View {
        Magnifier(scale: uiScale(typeStep)) {
            VStack(spacing: 0) {
                if let message = persistenceBannerMessage {
                    PersistenceErrorBanner(message: message) {
                        conversationStore.retryFailedSaves()
                        conversationStore.retryFailedHydrations()
                        bridge.retryOpeningConversationHydration()
                        projects.retryFailedSaves()
                    }
                    Divider()
                }
                detailColumns
            }
        }
        // Contextual titlebar: one native tab group represents one workspace, so every tab title
        // follows the workspace/project rather than whichever conversation is selected inside it.
        .navigationTitle(workspaceTitle)   // bridged to win.title via sceneBridgingOptions[.title]
        // An MCP server's mid-turn question (FR-116). Hosted here rather than in ContentView
        // because it belongs to the lane, not the visible conversation — the provider is blocked
        // until it is answered, so it must be reachable regardless of what is on screen.
        .sheet(item: $elicitations.pending) { request in
            ElicitationSheet(request: request) { action, answers in
                bridge.respondToElicitation(request, action: action, answers: answers)
                elicitations.pending = nil
            }
        }
        .sheet(item: $bridge.workspaceInstructionsEditorTarget) { target in
            WorkspaceInstructionsEditor(target: target) {
                bridge.workspaceInstructionsEditorTarget = nil
            }
        }
        .tint(.nAccent)
        .environmentObject(bridge)       // inject into ContentView / InspectorView
        .focusedObject(bridge)           // menus reach the frontmost workspace (+ activeMenuBridge fallback)
        .onAppear {
            appOpenWindow = openWindow   // let the AppKit toolbar open the utility Window scenes
        }
        // Deliver an App-Intent prompt (Siri/Spotlight/Shortcuts) once this window is ready.
        .onChange(of: bridge.isReady) { _, isReady in
            if isReady {
                active.consumePending(bridge)
                active.consumeOpenConversation(bridge)
            }
        }
        // Help composer handoffs are local state and must also resolve while signed out. Provider
        // readiness above remains the trigger for App-Intent sends; initial-view completion is the
        // independent trigger for an unsent demonstration that arrived during local hydration.
        .onChange(of: bridge.initialViewResolutionPending) { _, isPending in
            if !isPending { active.consumePendingStandardConversationDrafts(bridge) }
        }
        // Spotlight continuation is handled by AppDelegate.application(_:continue:…) —
        // workspace windows are hand-built NSWindows, not SwiftUI scenes, so the SwiftUI
        // .onContinueUserActivity modifier here both misfired and logged a repeating
        // "Cannot use Scene methods … without SwiftUI Lifecycle" fault.
        // Revealing an artifact used to be a .onChange here that called openWindow directly. It now
        // lives in ActiveWorkspace.revealArtifact, which does not depend on this view being mounted
        // and does not bypass UtilityWindowVisibility.
    }

    private var detailColumns: some View {
        // Until this window has resolved and hydrated its exact initial Conversation, show a quiet
        // loading state instead of flashing the new-conversation view. Inventory readiness may
        // precede that edge; a user who already navigated (⌘N) keeps their composer because a real
        // currentID always wins.
        if ConversationOpeningPresentation.shouldShow(
            storeIsReady: conversationStore.isReady,
            currentID: bridge.currentID,
            openingConversationID: bridge.openingConversationID,
            initialViewResolutionPending: bridge.initialViewResolutionPending
        ) {
            return AnyView(ConversationOpeningView())
        }
        // The launch ends, for a person, when the detail pane becomes their workspace. Marking it
        // here rather than on the opening state's disappearance also measures the fast launches
        // that never showed a loading pane at all. Only the first mark in a process counts.
        return AnyView(detailColumnsBody
            .onAppear { LaunchMetrics.shared.markFirstConversationVisible() })
    }

    /// A reference-model binding rather than `@State`/`@AppStorage`: every native workspace window
    /// owns its preferred width, and only a user drag writes the workspace fallback preference.
    private var inspectorWidthBinding: Binding<Double> {
        Binding(
            get: { bridge.inspectorPreferredWidth },
            set: { bridge.userSetInspectorPreferredWidth($0) })
    }

    private var detailColumnsBody: some View {
        GeometryReader { geometry in
            let layout = DetailColumnLayout.resolve(
                availableWidth: geometry.size.width,
                preferredInspectorWidth: CGFloat(bridge.inspectorPreferredWidth),
                showsInspector: bridge.showInspector,
                expanded: bridge.inspectorExpanded)
            HStack(spacing: 0) {
                // Not rendered at all when the inspector is expanded. A zero-width `ContentView` is
                // still a transcript being laid out and measured behind nothing.
                if !layout.inspectorIsFullWidth {
                    ContentView()
                        .frame(width: layout.chatWidth)
                }
                if bridge.showInspector {
                    // Keep the user's preferred width, but let the displayed inspector yield to
                    // a usable composer at the supported minimum window size.
                    if layout.inspectorIsFullWidth {
                        EmptyView()
                    } else {
                        // Geometry always accounts for one seam. The actual 10pt drag target is a
                        // final overlay below, above BOTH columns; putting it here as a sibling let
                        // the later InspectorView win hit testing on half of the visible divider.
                        Color.clear
                            .frame(width: DetailColumnLayout.resizeSeamWidth)
                            .accessibilityHidden(true)
                    }
                    InspectorView()
                        .frame(width: layout.inspectorWidth)
                }
            }
            .overlay(alignment: .leading) {
                if bridge.showInspector,
                   !layout.inspectorIsFullWidth,
                   layout.inspectorIsResizable,
                   DetailColumnLayout.hasInspectorResizeRange(
                    availableWidth: geometry.size.width) {
                    // THE RANGE THE DRAG ACTUALLY HONOURS. It comes from the window rather than a
                    // fixed cap: drag until the composer reaches its floor, and no sooner.
                    let lower = Double(DetailColumnLayout.minimumInspectorWidth)
                    let upper = Double(DetailColumnLayout.maximumInspectorWidth(
                        availableWidth: geometry.size.width))
                    AppKitInspectorResizeHandle(
                        size: inspectorWidthBinding,
                        range: lower...upper,
                        displayedSize: Double(layout.inspectorWidth),
                        onSeamMove: { x in bridge.inspectorSeamX = x })
                        .frame(
                            width: AppKitInspectorResizeHandle.hitSlabWidth,
                            height: geometry.size.height)
                        // Centre the native ten-point hit slab over the one-point seam so an
                        // ordinary grab works equally well from the chat and inspector sides.
                        .offset(
                            x: layout.chatWidth
                                + DetailColumnLayout.resizeSeamWidth / 2
                                - AppKitInspectorResizeHandle.hitSlabWidth / 2)
                        .zIndex(1)
                }
            }
            .background(Color.nBg)
            .onAppear {
                bridge.inspectorWidth = layout.inspectorWidth
            }
            .onChange(of: layout.inspectorWidth) { _, width in
                bridge.inspectorWidth = width
            }
            // Entering another workspace loads ITS width. Without this the width the person dragged
            // for the wiki would follow them into the next workspace and be saved there as if they
            // had chosen it.
            .onChange(of: bridge.inspectorPreferenceWorkspaceID) { _, _ in
                bridge.restoreInspectorPreferredWidth()
            }
        }
    }

    private var workspaceTitle: String {
        AgentBridge.workspaceDisplayTitle(
            projectID: bridge.projectID,
            cwd: bridge.cwd,
            projects: projects.projects)
    }
}

enum ConversationOpeningPresentation {
    static let spinnerDiameter: CGFloat = 68
    static let accessibilityLabel = String(localized: "Opening conversation…")

    static func shouldShow(
        storeIsReady: Bool,
        currentID: UUID?,
        openingConversationID: UUID?,
        initialViewResolutionPending: Bool
    ) -> Bool {
        openingConversationID != nil
            || (currentID == nil && (initialViewResolutionPending || !storeIsReady))
    }
}

/// A per-window hydration state, not a second app launch. Keep the Workspace/sidebar visible while
/// the established three-dot Mechanician mark identifies the work happening in the detail pane.
struct ConversationOpeningView: View {
    var body: some View {
        VStack(spacing: 18) {
            OrbitingDots(
                diameter: ConversationOpeningPresentation.spinnerDiameter,
                scalesDotsWithDiameter: true)
            Text(verbatim: ConversationOpeningPresentation.accessibilityLabel)
                .scaledFont(13, weight: .medium)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.nBg)
        .allowsHitTesting(false)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: ConversationOpeningPresentation.accessibilityLabel))
        .accessibilityIdentifier("conversationLoading")
    }
}

/// What the index knows about a search beyond "these matched": how well, and on what text.
struct ConversationSearchRelevance: Equatable {
    /// Position in `bm25()` order. Lower is a better match.
    var rank: [UUID: Int] = [:]
    /// The text that matched, where it could be located. Absent is normal, not an error.
    var excerpt: [UUID: String] = [:]

    init(hits: [ConversationProjectionStore.SearchHit]) {
        for (position, hit) in hits.enumerated() {
            rank[hit.id] = position
            if let excerpt = hit.excerpt { self.excerpt[hit.id] = excerpt }
        }
    }
}

/// The durable sidebar view filter. The raw value is stored in `@AppStorage`, so an intentionally
/// chosen filter follows the person across launches and native workspace windows; the filtering
/// itself remains a presentation concern and never changes the authoritative conversation list.
enum ConversationSidebarFilter: String, CaseIterable, Identifiable {
    case all
    case unread
    case working

    static let preferenceKey = "conversationSidebarFilter"

    var id: String { rawValue }

    /// The filter button follows Mail's convention: a neutral icon means the complete view is
    /// shown, while a filled icon makes a narrowed list visible even before the menu is opened.
    var isActive: Bool { self != .all }

    var accessibilityValue: String {
        switch self {
        case .all:
            return String(localized: "All conversations")
        case .unread:
            return String(localized: "Unread conversations")
        case .working:
            return String(localized: "Actively working conversations")
        }
    }

    /// Future builds must treat an unknown persisted value as the least-surprising, complete view.
    /// Keeping this at the filter boundary makes a renamed case incapable of hiding the sidebar.
    static func restored(from rawValue: String) -> Self {
        Self(rawValue: rawValue) ?? .all
    }

    /// Match the sidebar's existing activity mark: an in-flight root turn or nonterminal delegated
    /// work both mean the conversation is actively working. Cold-load recovery terminalizes stale
    /// delegates before publishing summaries, so this retains background workflows without reviving
    /// work from a prior process.
    func includes(
        _ summary: ConversationSummary,
        runningConversationIDs: Set<UUID>
    ) -> Bool {
        switch self {
        case .all:
            return true
        case .unread:
            return summary.unread
        case .working:
            return runningConversationIDs.contains(summary.id) || summary.hasRunningDelegate
        }
    }
}

/// Copy and stable identifiers for the compact, Mail-style conversation filter. Keeping this
/// separate from the sidebar's filtering policy lets accessibility tests pin the icon-only control
/// without coupling them to the SwiftUI layout around it.
enum ConversationSidebarFilterPresentation {
    static let accessibilityIdentifier = "conversationSidebar.filter"
    static let symbolName = "line.3.horizontal.decrease"
    static let headerActionSize: CGFloat = 34

    static var accessibilityLabel: String {
        String(localized: "Filter conversations")
    }

    static var accessibilityHint: String {
        String(localized: "Choose which conversations appear in the sidebar")
    }

    static func help(for filter: ConversationSidebarFilter) -> String {
        switch filter {
        case .all:
            return String(localized: "Filter conversations")
        case .unread:
            return String(localized: "Filter conversations — showing unread")
        case .working:
            return String(localized: "Filter conversations — showing actively working")
        }
    }

    static func menuOptionAccessibilityLabel(for filter: ConversationSidebarFilter) -> String {
        switch filter {
        case .all:
            return String(localized: "Show all conversations")
        case .unread:
            return String(localized: "Show unread conversations")
        case .working:
            return String(localized: "Show actively working conversations")
        }
    }

    static func selectionAccessibilityValue(selected: Bool) -> String {
        selected
            ? String(localized: "Selected")
            : String(localized: "Not selected")
    }
}

/// Copy and stable identifiers for the non-filter actions in the sidebar's compact toolbar. These
/// actions intentionally use familiar SF Symbols, while their tooltips and accessibility labels
/// name the effect precisely enough that an icon never asks people to guess.
enum ConversationSidebarHeaderActionPresentation {
    static let moreActionsAccessibilityIdentifier = "conversationSidebar.moreActions"
    static let selectAllAccessibilityIdentifier = "conversationSidebar.selectAll"
    static let deleteAllAccessibilityIdentifier = "conversationSidebar.deleteAll"
    static let newConversationAccessibilityIdentifier = "conversationSidebar.newConversation"
    static let moreActionsSymbolName = "ellipsis.circle"
    static let newConversationSymbolName = "square.and.pencil"

    static var moreActionsAccessibilityLabel: String {
        String(localized: "Conversation actions")
    }

    static var moreActionsAccessibilityHint: String {
        String(localized: "Select visible conversations or delete all conversations")
    }

    static var moreActionsHelp: String {
        String(localized: "Conversation actions")
    }

    static var selectAllAccessibilityLabel: String {
        String(localized: "Select all visible conversations")
    }

    static var selectAllAccessibilityHint: String {
        String(localized: "Selects every conversation currently shown in the sidebar")
    }

    static var deleteAllAccessibilityLabel: String {
        String(localized: "Delete all conversations")
    }

    static var deleteAllAccessibilityHint: String {
        String(localized: "Opens a confirmation before deleting every conversation")
    }

    static var deleteAllHelp: String {
        String(localized: "Delete all conversations…")
    }

    static var newConversationAccessibilityLabel: String {
        String(localized: "New conversation")
    }

    static var newConversationAccessibilityHint: String {
        String(localized: "Create a new conversation in this workspace")
    }

    static var newConversationHelp: String {
        String(localized: "New conversation")
    }
}

/// A compact Mac-toolbar affordance: familiar unbordered symbols at rest, a transient system-like
/// hover surface, and an accent only for the selected filter. The 34-point target remains
/// comfortable at the sidebar's narrowest width without making New look permanently selected.
private struct ConversationSidebarHeaderActionLabel: View {
    enum Tone {
        case standard
        case activeFilter
        case destructive
    }

    let systemImage: String
    var tone: Tone = .standard
    @State private var isHovered = false

    var body: some View {
        Image(systemName: systemImage)
            .font(.system(size: 15, weight: .medium))
            .foregroundStyle(foreground)
            .frame(
                width: ConversationSidebarFilterPresentation.headerActionSize,
                height: ConversationSidebarFilterPresentation.headerActionSize)
            .background {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(background)
            }
            .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
            .onHover { isHovered = $0 }
            .animation(.easeOut(duration: 0.12), value: isHovered)
            .accessibilityHidden(true)
    }

    private var foreground: Color {
        switch tone {
        case .standard:
            return .primary
        case .activeFilter:
            return .accentColor
        case .destructive:
            return .red
        }
    }

    private var background: Color {
        switch tone {
        case .activeFilter:
            return .accentColor.opacity(isHovered ? 0.20 : 0.12)
        case .standard, .destructive:
            return isHovered ? .primary.opacity(0.10) : .clear
        }
    }
}

/// Keeps the ordinary `Button` controls responsive in the same way as native toolbar symbols:
/// the label provides the hover surface and a press briefly compresses/fades it rather than leaving
/// a permanent beveled button behind.
private struct ConversationSidebarHeaderActionButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.92 : 1)
            .opacity(configuration.isPressed ? 0.68 : 1)
            .animation(.easeOut(duration: 0.10), value: configuration.isPressed)
    }
}

struct ConversationSidebarSnapshot {
    let scopedConversations: [ConversationSummary]
    /// The workspace-scoped inventory after the durable view filter, before text search narrows it.
    let filteredConversations: [ConversationSummary]
    let visibleConversations: [ConversationSummary]

    var scopedCount: Int { scopedConversations.count }
    var filteredCount: Int { filteredConversations.count }

    /// Exact eager-search fallback used while resident content is newer than the disposable FTS
    /// projection. Keeping it pure makes the summary-neutral live-content seam directly testable.
    static func residentContentMatches(
        in conversations: [Conversation],
        query: String
    ) -> Set<UUID> {
        let normalizedQuery = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !normalizedQuery.isEmpty else { return [] }
        return Set(conversations.compactMap { conversation in
            conversation.messages.contains {
                !$0.isSuperseded && $0.text.lowercased().contains(normalizedQuery)
            }
                ? conversation.id : nil
        })
    }

    static func make(
        orderedConversations: [ConversationSummary],
        scope: WorkspaceScope?,
        projects: [Project],
        query: String,
        contentMatches: Set<UUID>? = nil,
        relevance: ConversationSearchRelevance? = nil,
        filter: ConversationSidebarFilter = .all,
        runningConversationIDs: Set<UUID> = []
    ) -> Self {
        guard let scope else {
            return Self(
                scopedConversations: [],
                filteredConversations: [],
                visibleConversations: [])
        }
        let scoped = orderedConversations.filter { scope.contains($0, projects: projects) }
        // A durable filter scopes the inventory just like the workspace does; search can narrow it
        // but may never use a global content hit to widen either boundary.
        let filtered = scoped.filter {
            filter.includes($0, runningConversationIDs: runningConversationIDs)
        }
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else {
            return Self(
                scopedConversations: scoped,
                filteredConversations: filtered,
                visibleConversations: filtered)
        }
        // Summary text keeps type-ahead instant. `contentMatches` is the union of the disposable
        // FTS result (including tool output) and, while the current eager fallback is active, the
        // legacy full-transcript substring scan. Scope still bounds every global match.
        var visible = filtered.filter { summary in
            summary.displayTitle.lowercased().contains(q)
                || summary.snippet.lowercased().contains(q)
                || contentMatches?.contains(summary.id) == true
        }

        guard let relevance else {
            return Self(
                scopedConversations: scoped,
                filteredConversations: filtered,
                visibleConversations: visible)
        }

        // Relevance order, in three bands. A title match is the most direct answer to what was
        // typed and the index cannot score it, since only content is indexed; then everything the
        // index ranked, best first; then whatever matched some other way. Ties keep the canonical
        // order, so the list never reshuffles arbitrarily between keystrokes.
        //
        // The table splits Pinned from Previous itself, so ordering here survives that grouping
        // rather than fighting it.
        func band(_ summary: ConversationSummary) -> (Int, Int) {
            if summary.displayTitle.lowercased().contains(q) { return (0, 0) }
            if let rank = relevance.rank[summary.id] { return (1, rank) }
            return (2, 0)
        }
        visible.sort { a, b in
            let (aBand, aRank) = band(a), (bBand, bRank) = band(b)
            if aBand != bBand { return aBand < bBand }
            if aRank != bRank { return aRank < bRank }
            return ConversationSummary.canonicalOrder(a, b)
        }

        // Show the text that matched rather than the newest message. A conversation can match on
        // tool output from weeks ago, and its ordinary snippet then explains nothing about why it
        // is in the list.
        for index in visible.indices {
            if let excerpt = relevance.excerpt[visible[index].id] {
                visible[index].snippet = excerpt
            }
        }
        return Self(
            scopedConversations: scoped,
            filteredConversations: filtered,
            visibleConversations: visible)
    }
}

enum ConversationSidebarLoadPresentation {
    static func showsLoading(isReady: Bool, rowCount: Int) -> Bool {
        !isReady && rowCount == 0
    }

    static func countLabel(isReady: Bool, rowCount: Int) -> String {
        if showsLoading(isReady: isReady, rowCount: rowCount) {
            return "Loading conversations…"
        }
        return "\(rowCount) conversation\(rowCount == 1 ? "" : "s")"
    }
}

/// The zero-state must distinguish a genuinely empty workspace from an intentionally narrow
/// filter. Offering "New Conversation" after the person chose Unread used to imply that their
/// existing conversations had vanished.
enum ConversationSidebarEmptyPresentation {
    static func message(query: String, filter: ConversationSidebarFilter) -> String {
        guard query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return String(localized: "No matches")
        }
        switch filter {
        case .all:
            return String(localized: "No conversations yet")
        case .unread:
            return String(localized: "No unread conversations")
        case .working:
            return String(localized: "No actively working conversations")
        }
    }

    static func showsNewConversationAction(
        query: String,
        filter: ConversationSidebarFilter
    ) -> Bool {
        query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && filter == .all
    }
}

enum ConversationSidebarInteractionPolicy {
    enum SelectionAction: Equatable {
        case none
        case cancelPending
        case retainUntilReady(UUID)
        case select(UUID, cancelPending: Bool)
    }

    /// One rule for projected launch rows and hydrated navigation. A click back to the active row
    /// is meaningful while another row is decoding: it cancels that pending destination.
    static func selectionAction(
        selection: Set<UUID>,
        currentID: UUID?,
        pendingSelectionID: UUID?,
        storeIsReady: Bool,
        targetIsValid: Bool
    ) -> SelectionAction {
        guard selection.count == 1, let target = selection.first, targetIsValid else {
            return .none
        }
        if target == currentID {
            return pendingSelectionID == nil ? .none : .cancelPending
        }
        return storeIsReady
            ? .select(target, cancelPending: pendingSelectionID != nil)
            : .retainUntilReady(target)
    }

    static func projectedSelectionIsCurrent(
        capturedNavigationGeneration: UInt64?,
        currentNavigationGeneration: UInt64
    ) -> Bool {
        capturedNavigationGeneration == currentNavigationGeneration
    }

    /// Filtering changes the table's visible identity set, not the current conversation. Keep only
    /// visible rows in the native selection so a hidden id cannot later receive a keyboard delete,
    /// context-menu bulk action, or a surprise re-selection when the filter is cleared.
    static func selectionAfterFiltering(
        _ selection: Set<UUID>,
        visibleConversationIDs: Set<UUID>
    ) -> Set<UUID> {
        selection.intersection(visibleConversationIDs)
    }

    /// A pending hydration is canceled only when it was initiated by the sidebar selection that
    /// the new filter removed. An unrelated launch restoration may also be hydrating, and a filter
    /// must never steal that explicit initial destination.
    static func shouldCancelPendingSidebarSelection(
        removedSelection: Set<UUID>,
        pendingSelectionID: UUID?
    ) -> Bool {
        pendingSelectionID.map(removedSelection.contains) ?? false
    }

    /// The pre-ready counterpart remains local to a sidebar click. It can be withdrawn as soon as
    /// that exact selected row no longer appears in the filtered list.
    static func shouldClearPreReadySidebarSelection(
        removedSelection: Set<UUID>,
        pendingSelectionID: UUID?
    ) -> Bool {
        pendingSelectionID.map(removedSelection.contains) ?? false
    }

    static func allowsReordering(
        query: String,
        filter: ConversationSidebarFilter = .all
    ) -> Bool {
        filter == .all && query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

struct SidebarView: View {
    @EnvironmentObject private var bridge: AgentBridge
    @ObservedObject private var projects = ProjectStore.shared
    // The cross-window running set — so a conversation's spinner shows in every window that
    // lists it, not only the one whose bridge is running the turn.
    @ObservedObject private var active = ActiveWorkspace.shared
    @Environment(\.openWindow) private var openWindow
    @AppStorage("uiTypeStep") private var typeStep = 0
    @State private var editingID: UUID?
    @State private var editText = ""
    @State private var showClearConfirm = false
    @State private var searchText = ""
    @AppStorage(ConversationSidebarFilter.preferenceKey)
    private var conversationFilterRaw = ConversationSidebarFilter.all.rawValue
    /// Multi-select: a Set powers native Cmd/Shift-click selection for bulk actions. The ACTIVE
    /// conversation is decoupled — we only switch when the selection resolves to a single row.
    @State private var listSelection: Set<UUID> = []
    /// A header-menu Select All request crosses the SwiftUI/AppKit boundary as a monotonic token.
    /// The table owns the actual native selection so section headers can never become targets.
    @State private var selectAllVisibleRequest: UInt64 = 0
    /// A filter/search update may reduce a multi-selection to one visible row. That is a display
    /// repair, not a click, so it must not navigate to the remaining row just because it became a
    /// singleton after hidden ids were discarded. Retaining the repaired value (rather than a
    /// Boolean) prevents a coalesced SwiftUI update from suppressing a later real click.
    @State private var pendingFilteredSelectionRepair: Set<UUID>?
    /// The most recent single row clicked while only disposable projected summaries are available.
    /// It remains selection intent—not authority—until store readiness validates the exact id.
    @State private var pendingPreReadySelectionID: UUID?
    @State private var pendingPreReadyNavigationGeneration: UInt64?
    /// Non-nil → a multi-delete is awaiting confirmation (see bulkDeletePresented). The
    /// confirmation stays even though delete is undoable: it stops the accident, and undo covers
    /// confirming on autopilot.
    @State private var pendingBulkDelete: Set<UUID>?
    @FocusState private var searchFocused: Bool

    private var workspaceScope: WorkspaceScope? {
        WorkspaceScope.resolve(
            projectID: bridge.projectID,
            cwd: bridge.cwd,
            projects: projects.projects)
    }

    private var conversationFilter: ConversationSidebarFilter {
        ConversationSidebarFilter.restored(from: conversationFilterRaw)
    }

    private var conversationFilterBinding: Binding<ConversationSidebarFilter> {
        Binding(
            get: { ConversationSidebarFilter.restored(from: conversationFilterRaw) },
            set: { conversationFilterRaw = $0.rawValue })
    }

    /// The count and rows share one workspace scope; the durable state filter and text search can
    /// narrow it but never widen it.
    private var sidebarSnapshot: ConversationSidebarSnapshot {
        ConversationSidebarSnapshot.make(
            orderedConversations: conversationStore.summaries,
            scope: workspaceScope,
            projects: projects.projects,
            query: searchText,
            contentMatches: combinedContentMatches,
            relevance: searchHits.map(ConversationSearchRelevance.init(hits:)),
            filter: conversationFilter,
            runningConversationIDs: active.runningConversations)
    }

    /// Ranked FTS hits from projections.db for the current search text — most visibly, tool output
    /// that the substring scan can't see. nil while unavailable (the scan alone is the old
    /// behavior). Cleared alongside the query so stale hits never widen or reorder a new search.
    @State private var searchHits: [ConversationProjectionStore.SearchHit]?
    /// Only the sidebar's eager full-transcript fallback consumes this pulse. It avoids turning
    /// hidden streaming content into process-wide ObservableObject fan-out while keeping an active
    /// search current at the store's existing quarter-second presentation boundary.
    @State private var liveResidentContentRevision = 0

    private var contentMatches: Set<UUID>? {
        searchHits.map { Set($0.map(\.id)) }
    }

    /// Resident content supplements FTS immediately. If the projection fails, the callback below
    /// switches the whole session back to eager residency before this becomes the sole fallback.
    private var eagerContentMatches: Set<UUID>? {
        _ = liveResidentContentRevision
        guard !searchText.trimmingCharacters(in: .whitespaces).isEmpty,
              conversationStore.isReady else { return nil }
        return ConversationSidebarSnapshot.residentContentMatches(
            in: conversationStore.conversations,
            query: searchText)
    }

    private var combinedContentMatches: Set<UUID>? {
        switch (contentMatches, eagerContentMatches) {
        case (nil, nil): return nil
        case (let indexed?, nil): return indexed
        case (nil, let eager?): return eager
        case (let indexed?, let eager?): return indexed.union(eager)
        }
    }

    private func refreshContentMatches(for query: String) {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else {
            searchHits = nil
            return
        }
        guard conversationStore.searchIndexState == .current else {
            // Title filtering and already-resident content remain honest while the durable library
            // outbox catches up. Never query stale FTS rows and present their misses as complete.
            searchHits = nil
            return
        }
        // Never let an answer for the previous query widen or reorder this one while the projection
        // queue catches up. The eager transcript scan below remains available immediately.
        searchHits = nil
        ConversationStore.shared.projections.searchConversations(matching: trimmed) { hits in
            if hits == nil { conversationStore.noteSearchProjectionUnavailable() }
            // Deliveries are queue-ordered, so answer only the query still on screen.
            if searchText.trimmingCharacters(in: .whitespaces) == trimmed,
               conversationStore.searchIndexState == .current {
                searchHits = hits
            }
        }
    }

    @ObservedObject private var conversationStore = ConversationStore.shared

    var body: some View {
        let ready = conversationStore.isReady
        let snapshot = sidebarSnapshot
        let rows = snapshot.visibleConversations
        let visibleConversationIDs = Set(rows.map(\.id))
        return Magnifier(scale: uiScale(typeStep)) {
        VStack(spacing: 0) {
        sidebarHeader(count: ready ? snapshot.filteredCount : rows.count, isReady: ready)
        searchField
            .disabled(!ready)
        Divider()
        // A real AppKit NSTableView (ConversationPanel.swift) — Mail-like sections + rich rows, with
        // native double-click (→ window; ⌘ → tab), multi-select, drag-and-drop incl. drag-to-Trash,
        // and a context menu. It reports selection through $listSelection, so the single-vs-multi
        // switch + cross-window owner routing below are unchanged.
        ConversationTable(
            conversations: rows,
            selection: $listSelection,
            selectAllVisibleRequest: selectAllVisibleRequest,
            scale: uiScale(typeStep),
            active: active,
            now: Date(),
            activeConversationID: bridge.currentID,
            allowsActions: ready,
            requestExportDocument: { id, completion in
                ConversationMarkdownExport.document(
                    for: id,
                    in: conversationStore,
                    completion: completion)
            },
            onOpenInWindow: { id in if let c = convo(for: id) { openInNewWindow(c) } },
            onOpenInTab:    { id in if let c = convo(for: id) { openInNewTab(c) } },
            onOpenInTabWithIntent: { intent in
                if let c = convo(for: intent.conversationID) {
                    openInNewTab(c, intent: intent)
                }
            },
            onDelete:       { requestDelete(ids: $0) },
            onReorder:      {
                bridge.reorderConversations(
                    $0.orderedIDs,
                    orderChanged: $0.orderChanged,
                    pinning: $0.pinningIDs,
                    unpinning: $0.unpinningIDs)
            },
            allowsReordering: ConversationSidebarInteractionPolicy.allowsReordering(
                query: searchText,
                filter: conversationFilter),
            onSetFavorite: { bridge.setConversationsFavorite($0, to: $1) },
            onRename:       { id in if let c = convo(for: id) { beginRename(c) } },
            onRegenerateTitle: { bridge.regenerateConversationTitle($0) },
            onCopyTranscript: { id in
                conversationStore.acquireConversation(id) { result in
                    guard case .success(let c) = result else { return }
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(
                        AgentBridge.transcriptMarkdown(c.messages),
                        forType: .string)
                    conversationStore.trimResidencyIfNeeded()
                }
            },
            onMarkRead: { bridge.markConversationsRead($0) },
            onMarkUnread: { bridge.markConversationsUnread($0) },
            onResumeWait: { bridge.resumeWaitNow($0) },
            onCancelWait: { bridge.cancelWait($0) },
            onMoveToProject: { convIDs, projectID in
                guard let project = ProjectStore.shared.project(projectID) else {
                    presentWorkspaceMoveFailure(.unavailable, count: convIDs.count)
                    return
                }
                WorkspaceAdoption.adoptAfterAcquiring(
                    conversations: convIDs,
                    into: .project(project),
                    undoManager: workspaceUndoManager(for: bridge)
                ) { result in
                    presentWorkspaceMoveFailure(result, count: convIDs.count)
                }
            },
            onMoveToNewProject: { convIDs in
                // The destination does not exist yet — it is what the user is about to configure — so
                // carry the conversations alongside the request and let the editor adopt them on commit.
                _ = ProjectStore.shared.beginWorkspaceAdoption(
                    .conversations(convIDs),
                    originBridgeID: bridge.bridgeID)
                ProjectStore.shared.pendingNewProjectRequest = true
                NSApp.activate(ignoringOtherApps: true)
                openWindow(id: "projects")
            },
            onMoveToWorkspace: { ids in moveConversationsToCurrentWorkspace(ids) },
            editingID: $editingID,
            editText: $editText,
            onCommitRename: { commitRename($0) }
        )
        // Projected rows accept selection only. ConversationTable holds every mutation, export,
        // drag, rename, context menu, and double-click action until the authoritative store is
        // ready; the latest single click is retained below and validated at that edge.
        // A fresh/empty project shows a blank list otherwise — invite the first conversation.
        // Gated on ready: "No conversations yet" flashing before the decode lands would be the
        // state-loss appearance this whole phase exists to prevent.
        .overlay {
            if ConversationSidebarLoadPresentation.showsLoading(
                isReady: ready,
                rowCount: rows.count
            ) {
                VStack(spacing: 8) {
                    OrbitingDots(diameter: 26, scalesDotsWithDiameter: true)
                    Text("Loading conversations…")
                        .scaledFont(11)
                        .foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
            } else if ready, snapshot.visibleConversations.isEmpty {
                sidebarEmptyState
            }
        }
        // Drive selection through @State, then bridge both directions.
        .onAppear {
            listSelection = visibleSelection(for: bridge.currentID)
        }
        .onChange(of: visibleConversationIDs) { _, visibleConversationIDs in
            reconcileSidebarSelection(visibleConversationIDs: visibleConversationIDs)
        }
        .onChange(of: listSelection) { _, sel in
            if let repaired = pendingFilteredSelectionRepair {
                pendingFilteredSelectionRepair = nil
                if repaired == sel { return }
            }
            pendingPreReadySelectionID = nil
            pendingPreReadyNavigationGeneration = nil
            bridge.retainPreReadyConversationSelection(nil)
            let target = sel.count == 1 ? sel.first : nil
            let targetIsValid = target.flatMap(conversationStore.summary).map {
                workspaceScope?.contains($0, projects: projects.projects) == true
            } ?? false
            switch ConversationSidebarInteractionPolicy.selectionAction(
                selection: sel,
                currentID: bridge.currentID,
                pendingSelectionID: bridge.pendingSelectionID,
                storeIsReady: conversationStore.isReady,
                targetIsValid: targetIsValid
            ) {
            case .none:
                return
            case .cancelPending:
                guard let id = target else { return }
                bridge.select(id, allowingWorkspaceChange: false)
            case .retainUntilReady(let id):
                // Last intent wins: another click overwrites this exact id; multi/empty selection
                // above clears it. Mirror the identity onto the bridge so its when-ready restore
                // callback cannot race SwiftUI observation and hydrate the older saved row first.
                pendingPreReadySelectionID = id
                pendingPreReadyNavigationGeneration = bridge.preReadyNavigationGeneration
                bridge.retainPreReadyConversationSelection(id)
            case .select(let id, let cancelPending):
                if cancelPending { bridge.cancelPendingConversationSelection() }
                // AppKit has already disambiguated the native row selection. Start hydration now;
                // delaying every single click to guess whether a second click might follow made
                // even resident conversations feel sluggish. A real double-click carries the
                // displaced selection back through ConversationTabOpenIntent and rolls it back.
                commitConversationSelection(id) { selected in
                    guard listSelection == [id] else { return }
                    if !selected {
                        listSelection = visibleSelection(for: bridge.currentID)
                    }
                }
            }
        }
        .onChange(of: ready) { _, isReady in
            guard isReady, let id = pendingPreReadySelectionID else { return }
            // Keep the intent live until hydration completes so the restored currentID cannot
            // rewrite the table selection and then cancel the user's newer click.
            guard ConversationSidebarInteractionPolicy.projectedSelectionIsCurrent(
                    capturedNavigationGeneration: pendingPreReadyNavigationGeneration,
                    currentNavigationGeneration: bridge.preReadyNavigationGeneration),
                  listSelection == [id], isLocalConversation(id) else {
                pendingPreReadySelectionID = nil
                pendingPreReadyNavigationGeneration = nil
                listSelection = visibleSelection(for: bridge.currentID)
                return
            }
            commitConversationSelection(id) { selected in
                pendingPreReadySelectionID = nil
                pendingPreReadyNavigationGeneration = nil
                guard listSelection == [id] else { return }
                if !selected {
                    listSelection = visibleSelection(for: bridge.currentID)
                }
            }
        }
        .onChange(of: bridge.currentID) { _, id in
            // Follow a programmatic active change (new / delete / switch) to a single selection,
            // WITHOUT clobbering an in-progress multi-select (that never moves currentID, so this
            // won't fire mid-multi-select).
            if pendingPreReadySelectionID != nil {
                guard !ConversationSidebarInteractionPolicy.projectedSelectionIsCurrent(
                    capturedNavigationGeneration: pendingPreReadyNavigationGeneration,
                    currentNavigationGeneration: bridge.preReadyNavigationGeneration
                ) else { return }
                pendingPreReadySelectionID = nil
                pendingPreReadyNavigationGeneration = nil
            }
            let targetSelection = visibleSelection(for: id)
            if listSelection != targetSelection { listSelection = targetSelection }
        }
        }
        }
        .environment(\.uiScale, uiScale(typeStep)) // scale conversation-list text with ⌘+/-
        .onChange(of: bridge.searchFocusToken) { _, _ in searchFocused = true } // ⌥⌘F
        // FTS augmentation runs per keystroke; the substring scan in the snapshot stays
        // synchronous so typing never waits on the projection queue.
        .onChange(of: searchText) { _, newValue in refreshContentMatches(for: newValue) }
        .onChange(of: conversationStore.searchIndexState) { _, _ in
            refreshContentMatches(for: searchText)
        }
        .onReceive(conversationStore.liveResidentContentDidChange) { _ in
            guard !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return
            }
            liveResidentContentRevision &+= 1
        }
        // Match the native workspace shell's fresh 340-point sidebar. Existing workspace/session
        // widths are restored by `WorkspaceToolbarController` and never flow through this ideal.
        .navigationSplitViewColumnWidth(min: 220, ideal: 340, max: 400)
        .confirmationDialog("Delete all conversations?", isPresented: $showClearConfirm, titleVisibility: .visible) {
            Button("Delete All", role: .destructive) { bridge.clearAllConversations() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes every conversation. You can undo it with Undo in the Edit menu.")
        }
        .confirmationDialog(bulkDeleteTitle, isPresented: bulkDeletePresented, titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                if let ids = pendingBulkDelete { bridge.deleteConversations(ids) }
                pendingBulkDelete = nil
            }
            Button("Cancel", role: .cancel) { pendingBulkDelete = nil }
        } message: {
            Text("This removes the selected conversations. You can undo it with Undo in the Edit menu.")
        }
    }

    /// The active conversation can be changed by a command, a restored session, or another window.
    /// If its row is outside the current filter, keep the detail view active but leave the table
    /// honestly unselected instead of retaining an invisible bulk-action target.
    private func visibleSelection(for id: UUID?) -> Set<UUID> {
        ConversationSidebarInteractionPolicy.selectionAfterFiltering(
            id.map { [$0] } ?? [],
            visibleConversationIDs: Set(sidebarSnapshot.visibleConversations.map(\.id)))
    }

    /// Mirror AppKit's visible rows back into the binding whenever filtering (including a live turn
    /// finishing) removes a selected identity. The repair is deliberately action-suppressed: a
    /// multi-selection reduced to one row is not a person choosing to open that row.
    private func reconcileSidebarSelection(visibleConversationIDs: Set<UUID>) {
        let repaired = ConversationSidebarInteractionPolicy.selectionAfterFiltering(
            listSelection,
            visibleConversationIDs: visibleConversationIDs)
        let removed = listSelection.subtracting(repaired)
        guard !removed.isEmpty else { return }

        let shouldCancelPending =
            ConversationSidebarInteractionPolicy.shouldCancelPendingSidebarSelection(
                removedSelection: removed,
                pendingSelectionID: bridge.pendingSelectionID)
        let shouldClearPreReady =
            ConversationSidebarInteractionPolicy.shouldClearPreReadySidebarSelection(
                removedSelection: removed,
                pendingSelectionID: pendingPreReadySelectionID)
        if shouldClearPreReady {
            pendingPreReadySelectionID = nil
            pendingPreReadyNavigationGeneration = nil
            bridge.retainPreReadyConversationSelection(nil)
        }

        pendingFilteredSelectionRepair = repaired
        listSelection = repaired
        if shouldCancelPending { bridge.cancelPendingConversationSelection() }
    }

    private func isLocalConversation(_ id: UUID) -> Bool {
        guard let conversation = conversationStore.summary(id) else { return false }
        return workspaceScope?.contains(conversation, projects: projects.projects) == true
    }

    /// One-conversation/one-controller selection shared by ordinary and retained launch clicks.
    /// `completion` says whether this bridge selected the row; focusing another owner intentionally
    /// returns false so this table restores its own active highlight.
    private func commitConversationSelection(
        _ id: UUID,
        completion: @escaping (Bool) -> Void
    ) {
        guard isLocalConversation(id) else { completion(false); return }
        if let owner = AgentBridge.owner(of: id, excluding: bridge),
           let win = owner.window {
            owner.select(id)
            win.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            completion(false)
            return
        }
        bridge.select(
            id,
            allowingWorkspaceChange: false,
            completion: completion)
    }

    @discardableResult
    private func moveConversationsToCurrentWorkspace(_ ids: Set<UUID>) -> Bool {
        let destination: WorkspaceDestination
        guard let workspaceScope else { return false }
        switch workspaceScope {
        case .home:
            destination = .home
        case .project(let projectID):
            guard let project = projects.project(projectID) else { return false }
            destination = .project(project)
        }

        // AppKit's drop delegate must answer synchronously. Here `true` means Mechanician accepted
        // responsibility for the move; hydration and the atomic adoption finish asynchronously.
        // Reject the failures knowable at drop time so AppKit can honestly refuse the operation,
        // then surface any later file/destination failure from the completion.
        if let failure = WorkspaceAdoption.preflight(conversations: ids) {
            presentWorkspaceMoveFailure(failure, count: ids.count)
            return false
        }
        return WorkspaceAdoption.adoptAfterAcquiring(
            conversations: ids,
            into: destination,
            receivingBridge: bridge,
            undoManager: workspaceUndoManager(for: bridge)
        ) { result in
            presentWorkspaceMoveFailure(result, count: ids.count)
        }
    }

    private func presentWorkspaceMoveFailure(_ result: WorkspaceAdoptionResult, count: Int = 1) {
        guard let message = result.failureMessage else { return }
        let alert = NSAlert()
        let noun = count == 1 ? "Conversation" : "Conversations"
        if result == .busy {
            alert.messageText = "\(noun) can’t be moved yet"
        } else if result == .moveInProgress {
            alert.messageText = "Move already in progress"
        } else {
            alert.messageText = "Move unavailable"
        }
        // A batch move is all-or-nothing, so say so rather than leaving the user to guess which of
        // the selected conversations was the blocker or whether some of them went anyway.
        alert.informativeText = (result == .busy && count > 1)
            ? "One of the \(count) selected conversations still has active work. Stop it before moving them to another workspace."
            : message
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    /// Search box that filters conversations by title or message text.
    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").scaledFont(11).foregroundStyle(.secondary)
            TextField("Search", text: $searchText)
                .textFieldStyle(.plain)
                .focused($searchFocused)
            if conversationStore.searchIndexState == .indexing {
                // The app's own mark, not the system's. This one is on screen at every launch while
                // the content index reconciles, so it is one of the most-seen indicators in the app
                // and it was a stock `ProgressView` — a system spinner sitting in the middle of a
                // window that has no other system controls in it.
                OrbitingDots(diameter: 13)
                    .help("Conversation content is being indexed")
                    .accessibilityLabel("Indexing conversation content")
            } else if conversationStore.searchIndexState == .failed {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(Color.nWarningText)
                    .help("Conversation content search needs attention; title search still works")
                    .accessibilityLabel("Conversation content search needs attention")
            }
            if !searchText.isEmpty {
                Button { searchText = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Clear search")
                .accessibilityLabel("Clear search")
            }
        }
        .scaledFont(12)
        .padding(.horizontal, 8).padding(.vertical, 5)
        // nSurface + hairline so it reads as a raised well in BOTH appearances (nElevated == nBg in
        // Light, which made this invisible). Matches the launcher search field.
        .background(RoundedRectangle(cornerRadius: 7).fill(Color.nSurface)
            .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Color.nMuted.opacity(0.5))))
        .padding(.horizontal, 12)   // align the field's edge with the header (was 10 vs the header's 12)
        .padding(.bottom, 8)
    }

    /// Mail keeps conversation filtering in the header instead of spending a full row on three
    /// segments. The menu remains a native `Menu`, while explicit checkmarks make the current
    /// mutually-exclusive scope clear to sighted people and assistive technology alike.
    private var conversationFilterMenu: some View {
        Menu {
            conversationFilterMenuOption(.all)
            Divider()
            Section("Show only") {
                conversationFilterMenuOption(.unread)
                conversationFilterMenuOption(.working)
            }
        } label: {
            ConversationSidebarHeaderActionLabel(
                systemImage: ConversationSidebarFilterPresentation.symbolName,
                tone: conversationFilter.isActive ? .activeFilter : .standard)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .disabled(!conversationStore.isReady)
        .help(ConversationSidebarFilterPresentation.help(for: conversationFilter))
        .accessibilityIdentifier(ConversationSidebarFilterPresentation.accessibilityIdentifier)
        .accessibilityLabel(ConversationSidebarFilterPresentation.accessibilityLabel)
        .accessibilityValue(conversationFilter.accessibilityValue)
        .accessibilityHint(ConversationSidebarFilterPresentation.accessibilityHint)
    }

    private func conversationFilterMenuOption(_ filter: ConversationSidebarFilter) -> some View {
        let selected = conversationFilter == filter
        return Button {
            conversationFilterBinding.wrappedValue = filter
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "checkmark")
                    .font(.system(size: 11, weight: .semibold))
                    .opacity(selected ? 1 : 0)
                    .frame(width: 12)
                    .accessibilityHidden(true)
                conversationFilterMenuOptionLabel(filter)
            }
        }
        .accessibilityIdentifier("conversationSidebar.filter.\(filter.rawValue)")
        .accessibilityLabel(
            ConversationSidebarFilterPresentation.menuOptionAccessibilityLabel(for: filter))
        .accessibilityValue(
            ConversationSidebarFilterPresentation.selectionAccessibilityValue(selected: selected))
    }

    /// Keep menu labels as SwiftUI literals so they retain their catalogue keys rather than being
    /// built as runtime `String` values beside their accessibility-only counterparts above.
    @ViewBuilder
    private func conversationFilterMenuOptionLabel(_ filter: ConversationSidebarFilter) -> some View {
        switch filter {
        case .all:
            Text("All Conversations")
        case .unread:
            Text("Unread")
        case .working:
            Text("Working")
        }
    }

    /// Shown over the conversation list when a project has no matching conversations. A fresh,
    /// unfiltered project reads as inviting; a deliberately filtered one explains the exact state.
    private var sidebarEmptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "bubble.left.and.bubble.right").font(.system(size: 26)).foregroundStyle(.tertiary)
            Text(ConversationSidebarEmptyPresentation.message(
                query: searchText,
                filter: conversationFilter))
                .scaledFont(12).foregroundStyle(.secondary)
            if ConversationSidebarEmptyPresentation.showsNewConversationAction(
                query: searchText,
                filter: conversationFilter) {
                Button { bridge.newConversation() } label: { Text("New Conversation") }
                    .buttonStyle(PillButtonStyle(kind: .accent))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity).padding()
    }

    /// A Mail-style column header: title + count on the left, actions on the right.
    private func sidebarHeader(count: Int, isReady: Bool) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .center, spacing: 8) {
                sidebarHeaderCopy(
                    count: count,
                    isReady: isReady,
                    reportsIntrinsicWidth: true)
                Spacer(minLength: 0)
                sidebarHeaderActions
            }
            // A three-control header cannot share one 220-point row with the full title. Keep the
            // title and count intact at the sidebar's documented minimum instead of letting the
            // word "Conversations" wrap into an awkward two-line label.
            VStack(alignment: .leading, spacing: 6) {
                sidebarHeaderCopy(count: count, isReady: isReady)
                HStack {
                    Spacer(minLength: 0)
                    sidebarHeaderActions
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 20) // breathing room below the window's top boundary / traffic lights
        .padding(.bottom, 8)
    }

    private func sidebarHeaderCopy(
        count: Int,
        isReady: Bool,
        reportsIntrinsicWidth: Bool = false
    ) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text("Conversations")
                .scaledFont(13, weight: .semibold)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
                .allowsTightening(true)
            Text(ConversationSidebarLoadPresentation.countLabel(
                isReady: isReady,
                rowCount: count))
                .scaledFont(11)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        // Make only the inline candidate report its complete intrinsic header width. The stacked
        // fallback can use the entire narrow column and keeps an enlarged title on one line.
        .fixedSize(horizontal: reportsIntrinsicWidth, vertical: false)
    }

    private var sidebarHeaderActions: some View {
        HStack(spacing: 4) {
            conversationFilterMenu
            conversationActionsMenu
            sidebarNewConversationButton
        }
        .fixedSize()
    }

    /// Keep destructive work behind a familiar overflow menu rather than presenting a red trash
    /// target beside the primary New control. The menu is also where Select All belongs: it is a
    /// list operation, and it selects only the rows the current search/filter exposes.
    private var conversationActionsMenu: some View {
        Menu {
            Button {
                selectAllVisibleRequest &+= 1
            } label: {
                Text("Select All")
            }
            .disabled(sidebarSnapshot.visibleConversations.isEmpty)
            .accessibilityIdentifier(
                ConversationSidebarHeaderActionPresentation.selectAllAccessibilityIdentifier)
            .accessibilityLabel(
                ConversationSidebarHeaderActionPresentation.selectAllAccessibilityLabel)
            .accessibilityHint(
                ConversationSidebarHeaderActionPresentation.selectAllAccessibilityHint)

            Divider()

            Button(role: .destructive) { showClearConfirm = true } label: {
                Text("Delete All Conversations…")
            }
            .disabled(conversationStore.summaries.isEmpty)
            .accessibilityIdentifier(
                ConversationSidebarHeaderActionPresentation.deleteAllAccessibilityIdentifier)
            .accessibilityLabel(ConversationSidebarHeaderActionPresentation.deleteAllAccessibilityLabel)
            .accessibilityHint(ConversationSidebarHeaderActionPresentation.deleteAllAccessibilityHint)
        } label: {
            ConversationSidebarHeaderActionLabel(
                systemImage: ConversationSidebarHeaderActionPresentation.moreActionsSymbolName)
        }
        .buttonStyle(ConversationSidebarHeaderActionButtonStyle())
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .disabled(conversationStore.summaries.isEmpty)
        .help(ConversationSidebarHeaderActionPresentation.moreActionsHelp)
        .accessibilityLabel(ConversationSidebarHeaderActionPresentation.moreActionsAccessibilityLabel)
        .accessibilityHint(ConversationSidebarHeaderActionPresentation.moreActionsAccessibilityHint)
        .accessibilityIdentifier(
            ConversationSidebarHeaderActionPresentation.moreActionsAccessibilityIdentifier)
    }

    private var sidebarNewConversationButton: some View {
        Button { bridge.newConversation() } label: {
            ConversationSidebarHeaderActionLabel(
                systemImage: ConversationSidebarHeaderActionPresentation.newConversationSymbolName)
        }
        .buttonStyle(ConversationSidebarHeaderActionButtonStyle())
        .help(ConversationSidebarHeaderActionPresentation.newConversationHelp)
        .accessibilityLabel(ConversationSidebarHeaderActionPresentation.newConversationAccessibilityLabel)
        .accessibilityHint(ConversationSidebarHeaderActionPresentation.newConversationAccessibilityHint)
        .accessibilityIdentifier(
            ConversationSidebarHeaderActionPresentation.newConversationAccessibilityIdentifier)
    }

    /// **Go to a conversation** (one native group per place): if it's already
    /// displayed anywhere, focus that; otherwise open/focus its PLACE window — its Project (folder or
    /// topic) or Home — and select it there. Never spawns a duplicate place window or a mis-scoped one.
    private func openInNewWindow(_ convo: ConversationSummary) {
        if AgentBridge.focusOwner(of: convo.id) { return }   // already displayed → go there
        let allProjects = projects.projects
        guard let scope = WorkspaceScope.resolve(
            summary: convo,
            projects: allProjects)
        else { return }
        // Find the one group for this conversation's canonical workspace, regardless of whether
        // that window is represented by an id (topic) or by its Project's working folder.
        let isPlaceWindow: (AgentBridge) -> Bool = { b in
            WorkspaceScope.resolve(
                projectID: b.projectID,
                cwd: b.cwd,
                projects: allProjects) == scope
        }
        if let owner = AgentBridge.live.allObjects.first(where: isPlaceWindow), let win = owner.window {
            owner.select(convo.id)
            if win.isMiniaturized { win.deminiaturize(nil) }
            win.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        } else {
            // No window open for this place → open it, bound to this conversation. The binding is
            // per-window rather than a process-global slot, so opening two conversations in quick
            // succession can no longer leave one of the windows on a blank conversation.
            let id = convo.id
            switch scope {
            case .home:
                makeWorkspaceWindow(initialConversationID: id).makeKeyAndOrderFront(nil)
            case .project(let projectID):
                guard let project = allProjects.first(where: { $0.id == projectID }) else { return }
                makeWorkspaceWindow(
                    initialFolder: project.isWorkspace ? project.cwd : nil,
                    initialProjectID: project.isWorkspace ? nil : project.id,
                    initialConversationID: id)
                    .makeKeyAndOrderFront(nil)
            }
        }
    }

    /// Open a conversation in a new native TAB of the current window. Reuses the same
    /// pending-conversation handoff as new-window; openWorkspaceTab folds the fresh main window
    /// into this window's tab group.
    private func openInNewTab(
        _ convo: ConversationSummary,
        intent: ConversationTabOpenIntent? = nil
    ) {
        // The first click starts selection immediately. If its hydration has not installed yet,
        // cancellation leaves this tab on its original conversation and the target can open in the
        // new tab directly. If it did install, restore the displaced (still back-navigation-pinned)
        // conversation first, then open the now-unowned target. This preserves double-click-to-tab
        // without taxing every ordinary single click with a fixed delay.
        bridge.cancelPendingConversationSelection()

        func openTarget() {
            if AgentBridge.owner(of: convo.id) != nil {
                _ = AgentBridge.focusOwner(of: convo.id)
            } else {
                openWorkspaceTab(initialConversationID: convo.id)
            }
        }

        if let intent,
           intent.replacedSelection,
           bridge.currentID == convo.id {
            if let replacedID = intent.replacedConversationID,
               conversationStore.contains(replacedID) {
                bridge.select(replacedID, allowingWorkspaceChange: false) { restored in
                    guard restored, bridge.currentID == replacedID else {
                        listSelection = bridge.currentID.map { [$0] } ?? []
                        return
                    }
                    openTarget()
                }
            } else {
                // The displaced tab was a disposable empty placeholder and navigation removed it.
                // Recreate that blank intent before placing the clicked conversation in its tab.
                bridge.newConversation()
                guard bridge.currentID != convo.id else {
                    listSelection = bridge.currentID.map { [$0] } ?? []
                    return
                }
                openTarget()
            }
            return
        }

        listSelection = bridge.currentID.map { [$0] } ?? []
        // Already open in ANY window or tab, INCLUDING this one → go there.
        //
        // This deliberately does not exclude `bridge`. It used to, on the reasoning that the
        // just-clicked row should not count as "already open" — but ownership is about which window
        // is SHOWING a conversation, not about which row was clicked. Excluding this window meant a
        // conversation already on screen here looked closed, so a tab was built for it, and
        // `consumeOpenConversation` (which does not exclude this window) then blanked that tab.
        switch ConversationOpenPlan.resolve(
            conversationID: convo.id,
            isShownInAnyWindow: AgentBridge.owner(of: convo.id) != nil) {
        case .focusExistingWindow:
            _ = AgentBridge.focusOwner(of: convo.id)
        case .openInNewTab(let id):
            openWorkspaceTab(initialConversationID: id)
        }
    }

    // MARK: Delete — one immediately; many behind a confirmation. Both are undoable.

    /// The conversations a Delete should target: the whole multi-selection if `convo` is part of
    /// it, otherwise just `convo`.
    private func deleteTargets(for convo: ConversationSummary) -> Set<UUID> {
        listSelection.contains(convo.id) && listSelection.count > 1 ? listSelection : [convo.id]
    }
    private func requestDelete(of convo: ConversationSummary) { requestDelete(ids: deleteTargets(for: convo)) }
    private func requestDelete(ids: Set<UUID>) {
        if ids.count > 1 { pendingBulkDelete = ids }
        else if let id = ids.first { bridge.deleteConversation(id) }
    }
    private var bulkDeletePresented: Binding<Bool> {
        Binding(get: { pendingBulkDelete != nil }, set: { if !$0 { pendingBulkDelete = nil } })
    }
    private var bulkDeleteTitle: String { "Delete \(pendingBulkDelete?.count ?? 0) conversations?" }

    private func convo(for id: UUID) -> ConversationSummary? { conversationStore.summary(id) }

    private func beginRename(_ convo: ConversationSummary) {
        // Start inline editing in the sidebar row (the row hosts a focused TextField).
        editText = convo.displayTitle
        editingID = convo.id
    }

    private func commitRename(_ id: UUID) {
        bridge.renameConversation(id, to: editText)
        editingID = nil
    }
}

/// Return on the focused conversation list begins an inline rename (macOS 14+; a no-op on 13).
private struct ReturnKeyRename: ViewModifier {
    let selection: UUID?
    let editing: Bool
    let action: (UUID) -> Void

    func body(content: Content) -> some View {
        if #available(macOS 14.0, *) {
            content.onKeyPress(.return) {
                guard !editing, let id = selection else { return .ignored }
                action(id)
                return .handled
            }
        } else {
            content
        }
    }
}

/// The inspector divider is a native event target mounted at the existing SwiftUI layout seam.
///
/// AppKit owns pointer capture, cursor rects, keyboard adjustment, and accessibility. SwiftUI only
/// supplies the already-established binding and places this integration seam over the HStack. That
/// division is intentional: a `DragGesture` can lose the press when hosted AppKit views or a later
/// SwiftUI sibling win hit testing, while AppKit keeps sending drag and mouse-up events to the view
/// that received mouse-down even as the divider moves under the pointer.
struct AppKitInspectorResizeHandle: NSViewRepresentable {
    static let hitSlabWidth: CGFloat = 10

    @Binding var size: Double
    let range: ClosedRange<Double>
    let displayedSize: Double
    /// Reports where this handle is actually drawn, in window coordinates, so the native toolbar
    /// can put the right-panel toggle inside the inspector rather than on the seam. Absence belongs
    /// to the explicit inspector state; dismantling an AppKit view must not publish into SwiftUI.
    let onSeamMove: (CGFloat) -> Void

    func makeNSView(context: Context) -> AppKitInspectorResizeHandleView {
        let view = AppKitInspectorResizeHandleView(frame: .zero)
        configure(view)
        return view
    }

    func updateNSView(_ nsView: AppKitInspectorResizeHandleView, context: Context) {
        configure(nsView)
    }

    static func dismantleNSView(
        _ nsView: AppKitInspectorResizeHandleView,
        coordinator: Void
    ) {
        nsView.stop()
    }

    private func configure(_ view: AppKitInspectorResizeHandleView) {
        let binding = $size
        view.onSeamMove = onSeamMove
        view.configure(
            preferredSize: size,
            displayedSize: displayedSize,
            range: range,
            onResize: { binding.wrappedValue = $0 })
    }
}

/// Native half of `AppKitInspectorResizeHandle`.
///
/// The drag session records positions in window coordinates. Its own frame moves on every width
/// publication, so local coordinates would feed that movement back into the drag and produce a
/// dead zone or jitter. AppKit continues routing the gesture here after mouse-down, independent of
/// that layout change.
final class AppKitInspectorResizeHandleView: NSView {
    private struct DragSession {
        let windowX: CGFloat
        let preferredSize: Double
        let displayedSize: Double
        let range: ClosedRange<Double>
    }

    private var preferredSize = 360.0
    private var displayedSize = 360.0
    private var range = 180.0...520.0
    private var onResize: ((Double) -> Void)?
    private var dragSession: DragSession?
    private var lastPublishedSeam: CGFloat?

    /// Published when the visible seam moves to another backing pixel, so the toolbar tracks what a
    /// person can see without turning no-op AppKit frame assignments into SwiftUI layout feedback.
    var onSeamMove: ((CGFloat) -> Void)?

    override var acceptsFirstResponder: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setAccessibilityElement(true)
        setAccessibilityRole(.splitter)
        setAccessibilityLabel(String(localized: "Resize inspector"))
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(
        preferredSize: Double,
        displayedSize: Double,
        range: ClosedRange<Double>,
        onResize: @escaping (Double) -> Void
    ) {
        self.preferredSize = preferredSize
        self.displayedSize = displayedSize
        self.range = range
        self.onResize = onResize
    }

    func stop() {
        dragSession = nil
        onResize = nil
        onSeamMove = nil
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        publishSeam()
    }

    override func setFrameOrigin(_ newOrigin: NSPoint) {
        super.setFrameOrigin(newOrigin)
        publishSeam()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        publishSeam()
    }

    private func publishSeam() {
        guard let window else { return }
        let scale = max(1, window.backingScaleFactor)
        let rawX = convert(NSPoint(x: bounds.midX, y: bounds.midY), to: nil).x
        let pixelAlignedX = (rawX * scale).rounded() / scale
        guard let onSeamMove, pixelAlignedX != lastPublishedSeam else { return }
        lastPublishedSeam = pixelAlignedX
        onSeamMove(pixelAlignedX)
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .resizeLeftRight)
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        dragSession = DragSession(
            windowX: event.locationInWindow.x,
            preferredSize: preferredSize,
            displayedSize: displayedSize,
            range: range)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let dragSession else {
            super.mouseDragged(with: event)
            return
        }
        let next = ResponsiveResizeDrag.preferredSize(
            preferredSize: dragSession.preferredSize,
            displayedSize: dragSession.displayedSize,
            translation: Double(event.locationInWindow.x - dragSession.windowX),
            range: dragSession.range)
        publish(next)
    }

    override func mouseUp(with event: NSEvent) {
        dragSession = nil
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 123: // Left: move the seam left and grow the trailing inspector.
            step(translation: -10)
        case 124: // Right: move the seam right and shrink the trailing inspector.
            step(translation: 10)
        default:
            super.keyDown(with: event)
        }
    }

    override func accessibilityPerformIncrement() -> Bool {
        step(translation: -10)
        return true
    }

    override func accessibilityPerformDecrement() -> Bool {
        step(translation: 10)
        return true
    }

    private func step(translation: Double) {
        let next = ResponsiveResizeDrag.preferredSize(
            preferredSize: preferredSize,
            displayedSize: displayedSize,
            translation: translation,
            range: range)
        publish(next)
    }

    private func publish(_ next: Double) {
        guard next != preferredSize else { return }
        // Keep repeated keyboard and accessibility actions continuous even before SwiftUI has
        // completed the binding-driven layout pass and called `configure` again.
        preferredSize = next
        displayedSize = next
        onResize?(next)
    }
}

/// A thin, draggable divider that resizes an adjacent panel and persists its size. The
/// panel sits on the trailing (right) or bottom side, so dragging toward it shrinks it.
struct ResizeHandle: View {
    enum Axis { case horizontal, vertical } // horizontal → adjusts a width; vertical → a height
    @Binding var size: Double
    let axis: Axis
    let range: ClosedRange<Double>
    var displayedSize: Double? = nil
    @State private var preferredBase: Double?
    @State private var displayedBase: Double?

    var body: some View {
        Rectangle()
            // The adjacent panel backgrounds already establish their boundary. A partial-height
            // hairline is worse than no line, so only the drag target remains visible on hover.
            .fill(.clear)
            .frame(width: axis == .horizontal ? 1 : nil, height: axis == .vertical ? 1 : nil)
            // Keep the actual split seam to one pixel. The wider clear overlay preserves a forgiving
            // drag target without inserting a dark 10-point gutter between adjacent panels.
            .overlay {
                Rectangle()
                    .fill(.clear)
                    .frame(width: axis == .horizontal ? 10 : nil,
                           height: axis == .vertical ? 10 : nil)
                    .contentShape(Rectangle())
            // AppKit cursor *rects* (not NSCursor.push/pop) so a sibling NSView below the
            // handle — e.g. the terminal's I-beam — can't clobber the resize cursor.
                    .overlay(CursorArea(cursor: axis == .horizontal ? .resizeLeftRight : .resizeUpDown))
                    .gesture(
                // Global coordinate space: the handle moves as the panel resizes, so a
                // local-space translation would feed back and jitter. Global stays stable.
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { g in
                        let preferred = preferredBase ?? size
                        let displayed = displayedBase ?? displayedSize ?? size
                        if preferredBase == nil {
                            preferredBase = preferred
                            displayedBase = displayed
                        }
                        let d = axis == .horizontal ? g.translation.width : g.translation.height
                        size = ResponsiveResizeDrag.preferredSize(
                            preferredSize: preferred,
                            displayedSize: displayed,
                            translation: d,
                            range: range)
                    }
                    .onEnded { _ in
                        preferredBase = nil
                        displayedBase = nil
                    }
            )
            }
    }
}

/// An AppKit cursor region backed by `resetCursorRects` — the same mechanism native
/// dividers use, so it composes with sibling NSViews instead of fighting them the way
/// `NSCursor.push()/pop()` does. `hitTest` returns nil so it never intercepts the drag.
struct CursorArea: NSViewRepresentable {
    let cursor: NSCursor
    func makeNSView(context: Context) -> NSView { CursorNSView(cursor) }
    func updateNSView(_ nsView: NSView, context: Context) {
        guard let v = nsView as? CursorNSView, v.cursor != cursor else { return }
        v.cursor = cursor
        v.window?.invalidateCursorRects(for: v)
    }
    final class CursorNSView: NSView {
        var cursor: NSCursor
        private var tracking: NSTrackingArea?
        init(_ cursor: NSCursor) { self.cursor = cursor; super.init(frame: .zero) }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        // A `.cursorUpdate` tracking area, NOT just cursor rects: rects are unreliable inside SwiftUI
        // hosting (resetCursorRects often isn't re-invalidated) and lose to a sibling NSView's own
        // cursor — e.g. SwiftTerm's I-beam under the terminal resize bar, the exact bug this fixes.
        // A front-most tracking area wins. The rect stays as a belt-and-suspenders fallback.
        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            if let t = tracking { removeTrackingArea(t) }
            let t = NSTrackingArea(rect: bounds,
                                   options: [.activeInKeyWindow, .inVisibleRect, .cursorUpdate, .mouseEnteredAndExited],
                                   owner: self, userInfo: nil)
            addTrackingArea(t); tracking = t
        }
        override func cursorUpdate(with event: NSEvent) { cursor.set() }
        override func mouseEntered(with event: NSEvent) { cursor.set() }
        override func resetCursorRects() { addCursorRect(bounds, cursor: cursor) }
        override func hitTest(_ point: NSPoint) -> NSView? { nil } // pass drags through to the SwiftUI gesture
    }
}

/// Maps the ⌘+/-/0 zoom step (0 == 100%) to a scale factor, clamped to 70%…160%.
func uiScale(_ step: Int) -> CGFloat {
    min(max(1.0 + 0.1 * CGFloat(step), 0.7), 1.6)
}

/// Applies the app's Appearance setting (Settings ▸ Theme) and accent to a window root.
/// Appearance itself is owned by `NSApp.appearance`; this modifier only carries the app accent.
/// Using the application appearance avoids a stale per-scene override when Light changes to System.
private struct AppChrome: ViewModifier {
    func body(content: Content) -> some View {
        content
            .tint(.nAccent)
    }
}

extension View {
    func appChrome() -> some View { modifier(AppChrome()) }
}

/// The current ⌘+/- zoom factor, propagated to the tool panels. macOS does NOT scale
/// semantic font styles via dynamicTypeSize (unlike iOS), so panels read this and size
/// their fonts explicitly — the same continuous mechanism the transcript uses.
private struct UIScaleKey: EnvironmentKey { static let defaultValue: CGFloat = 1 }
extension EnvironmentValues {
    var uiScale: CGFloat {
        get { self[UIScaleKey.self] }
        set { self[UIScaleKey.self] = newValue }
    }
}

private struct ScaledFontModifier: ViewModifier {
    @Environment(\.uiScale) private var uiScale
    let size: CGFloat
    let weight: Font.Weight
    let design: Font.Design
    func body(content: Content) -> some View {
        content.font(.system(size: size * uiScale, weight: weight, design: design))
    }
}

extension View {
    /// A system font that grows/shrinks with the ⌘+/- zoom (via `\.uiScale`). Base sizes
    /// match macOS's semantic styles (caption 10/11, callout 12, headline 13, …).
    func scaledFont(_ size: CGFloat, weight: Font.Weight = .regular, design: Font.Design = .default) -> some View {
        modifier(ScaledFontModifier(size: size, weight: weight, design: design))
    }
}

/// Passthrough for now. The previous scaleEffect+GeometryReader zoom crashed AppKit
/// during split-view resize, because the detail pane hosts native views (NSTextView
/// composer, SwiftTerm, WKWebView) that can't live under a resizing scale transform.
/// Zoom is being reimplemented via font scaling instead (see ChatFontScale).
struct Magnifier<Content: View>: View {
    let scale: CGFloat
    @ViewBuilder var content: () -> Content
    var body: some View { content() }
}
