import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// The reusable Workspaces gallery. In normal browsing it lets a user replace the current window's
/// workspace in place; File ▸ Open Workspace in New Window supplies `.newWindow`, which uses the
/// same focus-or-create rule after its separate chooser window is dismissed.
enum WorkspaceLauncherPurpose {
    case browse
    case newWindow
}

/// A File ▸ Open Workspace in New Window chooser is transient and must not capture the process-wide
/// request that belongs to the dedicated Workspaces scene. Ordinary New Workspace requests remain
/// consumable by either launcher, preserving the existing standalone creation flow.
enum WorkspaceLauncherPendingNewPolicy {
    static func canConsume(
        purpose: WorkspaceLauncherPurpose,
        hasPendingAdoption: Bool
    ) -> Bool {
        switch (purpose, hasPendingAdoption) {
        case (.newWindow, true):
            return false
        case (.browse, _), (.newWindow, false):
            return true
        }
    }
}

enum WorkspaceLauncherDraftPersistenceResult {
    case committed(Project)
    case blocked(WorkspaceAdoptionResult)
}

/// A pending move belongs to one exact New Workspace draft. Any UI transition that abandons that
/// draft must clear only its own request so a later ordinary workspace creation cannot unexpectedly
/// adopt the old item—and a stale launcher cannot cancel a newer request owned by another window.
@MainActor
@discardableResult
func abandonWorkspaceLauncherAdoption(
    _ adoptionRequestID: UUID?,
    projects: ProjectStore
) -> UUID? {
    projects.cancelWorkspaceAdoption(adoptionRequestID)
    return nil
}

/// Persist a New Workspace draft only after the exact adoption request owned by its editor is still
/// viable. Keeping the preflight and project mutation in one function makes it impossible for a
/// stale conversation/artifact request to create or rename an otherwise empty workspace.
@MainActor
func persistWorkspaceLauncherDraft(
    _ draft: Project,
    adoption: PendingWorkspaceAdoption?,
    adoptionRequestID: UUID?,
    projects: ProjectStore,
    conversations explicitConversations: ConversationStore? = nil,
    artifacts explicitArtifacts: ArtifactStore? = nil,
    synchronizeLiveState: Bool? = nil
) -> WorkspaceLauncherDraftPersistenceResult {
    let conversations = explicitConversations ?? .shared
    let artifacts = explicitArtifacts ?? .shared
    if let adoptionRequestID {
        guard let adoption, adoption.id == adoptionRequestID else {
            return .blocked(.unavailable)
        }
        let failure: WorkspaceAdoptionResult?
        switch adoption.target {
        case .conversations(let ids):
            failure = WorkspaceAdoption.preflight(
                conversations: ids,
                conversations: conversations,
                synchronizeLiveState: synchronizeLiveState)
        case .artifacts(let ids):
            failure = WorkspaceAdoption.preflight(
                artifacts: ids,
                artifactStore: artifacts)
        }
        if let failure { return .blocked(failure) }
    }

    // Reuse a project already bound to this folder rather than duplicating it.
    if let existing = projects.projects.first(where: {
        $0.cwd == draft.cwd && !draft.cwd.isEmpty
    }) {
        projects.update(existing.id) {
            $0.name = draft.name
            $0.goal = draft.goal
        }
        return .committed(projects.project(existing.id) ?? existing)
    }
    projects.upsert(draft)
    return .committed(projects.project(draft.id) ?? draft)
}

/// Normal Workspaces browsing focuses an existing owner or reuses the originating workspace window
/// in place. Returning the exact bridge is essential: a follow-up conversation reveal must select on
/// that destination instead of publishing a flag that only newly-ready windows consume.
@MainActor
@discardableResult
func routeToWorkspaceProject(
    _ project: Project,
    replacing origin: AgentBridge?
) -> AgentBridge? {
    switch WorkspaceLauncherRouting.route(
        projectID: project.id,
        cwd: project.cwd,
        originBridgeID: origin?.bridgeID,
        among: liveWorkspaceWindowIdentities()
    ) {
    case .focus(let bridgeID):
        guard let owner = liveWorkspaceBridge(bridgeID) else { return openProject(project) }
        focusWorkspaceWindow(of: owner)
        return owner
    case .replaceOrigin(let bridgeID):
        guard let origin = liveWorkspaceBridge(bridgeID) else { return openProject(project) }
        origin.enterWorkspace(project)
        focusWorkspaceWindow(of: origin)
        return origin
    case .openWorkspace:
        return openProject(project)
    }
}

/// Every open workspace window as a plain identity, for the pure routing rules.
@MainActor
func liveWorkspaceWindowIdentities() -> [WorkspaceWindowIdentity] {
    AgentBridge.live.allObjects.map {
        WorkspaceWindowIdentity(
            bridgeID: $0.bridgeID,
            projectID: $0.projectID,
            cwd: $0.cwd,
            hasWindow: $0.window != nil)
    }
}

/// Bring a chosen window forward. Deliberately `NSApp.activate()` rather than
/// `ignoringOtherApps: true`: the user asked for this workspace, so going to its window is the
/// point, but nothing here should wrench focus away from whatever else they were doing.
@MainActor
func focusWorkspaceWindow(of bridge: AgentBridge) {
    guard let window = bridge.window else { return }
    if window.isMiniaturized { window.deminiaturize(nil) }
    window.makeKeyAndOrderFront(nil)
    NSApp.activate()
}

/// Re-resolve a window by stable identity at the moment it will be used. Async Workspace creation
/// must never retain and later route through a bridge whose window closed while records hydrated.
@MainActor
func liveWorkspaceBridge(_ bridgeID: UUID?) -> AgentBridge? {
    guard let bridgeID else { return nil }
    return AgentBridge.live.allObjects.first {
        $0.bridgeID == bridgeID && $0.window != nil
    }
}

enum WorkspaceConversationRevealResult: Equatable {
    case selectedDestination
    case focusedExistingOwner
    case unavailable
}

/// Reveal a moved conversation on the bridge selected by the launcher. The durable assignment and
/// bridge scope are checked before navigation, and a live owner always wins over creating a duplicate
/// controller for the same conversation.
@MainActor
func revealWorkspaceConversation(
    _ conversationID: UUID,
    in destination: WorkspaceDestination,
    on destinationBridge: AgentBridge?,
    completion: @escaping @MainActor (WorkspaceConversationRevealResult) -> Void
) {
    guard let summary = ConversationStore.shared.summary(conversationID),
          conversationBelongsToWorkspace(summary, destination: destination)
    else {
        completion(.unavailable)
        return
    }

    if let owner = AgentBridge.owner(
        of: conversationID,
        excluding: destinationBridge) {
        if !bridgeDisplaysWorkspace(owner, destination: destination) {
            // Owner-visible records are pinned by the residency guard. Apply the move before the
            // same-id selection fast path, which deliberately does not reload its workspace.
            guard let conversation = ConversationStore.shared.residentConversation(conversationID)
            else {
                completion(.unavailable)
                return
            }
            owner.applyConversationWorkspaceAdoption(
                conversation,
                destination: destination)
        }
        owner.select(conversationID)
        owner.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        completion(.focusedExistingOwner)
        return
    }

    guard let destinationBridge,
          bridgeDisplaysWorkspace(destinationBridge, destination: destination)
    else {
        completion(.unavailable)
        return
    }
    destinationBridge.openConversation(conversationID) { selected in
        // Hydration may cross an arbitrary number of main-loop turns. Revalidate the durable
        // placement, destination window, and one-owner rule at the publication edge rather than
        // treating `openConversation` as a synchronous selection.
        if selected,
           destinationBridge.currentID == conversationID,
           destinationBridge.window != nil,
           bridgeDisplaysWorkspace(destinationBridge, destination: destination),
           let current = ConversationStore.shared.summary(conversationID),
           conversationBelongsToWorkspace(current, destination: destination) {
            destinationBridge.window?.makeKeyAndOrderFront(nil)
            completion(.selectedDestination)
            return
        }

        // A competing owner may have appeared during the reload/select boundary.
        if let owner = AgentBridge.owner(
            of: conversationID,
            excluding: destinationBridge) {
            owner.window?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            completion(.focusedExistingOwner)
            return
        }
        completion(.unavailable)
    }
}

func conversationBelongsToWorkspace(
    _ conversation: Conversation,
    destination: WorkspaceDestination
) -> Bool {
    let projects: [Project]
    switch destination {
    case .home: projects = []
    case .project(let project): projects = [project]
    }
    return destination.scope.contains(conversation, projects: projects)
}

func conversationBelongsToWorkspace(
    _ summary: ConversationSummary,
    destination: WorkspaceDestination
) -> Bool {
    let projects: [Project]
    switch destination {
    case .home: projects = []
    case .project(let project): projects = [project]
    }
    return destination.scope.contains(summary, projects: projects)
}

@MainActor
private func bridgeDisplaysWorkspace(
    _ bridge: AgentBridge,
    destination: WorkspaceDestination
) -> Bool {
    switch destination {
    case .home:
        return bridge.projectID == nil && bridge.cwd.isEmpty
    case .project(let project):
        return project.cwd.isEmpty
            ? bridge.projectID == project.id && bridge.cwd.isEmpty
            : bridge.projectID == nil && bridge.cwd == project.cwd
    }
}

struct ProjectsLauncherView: View {
    let purpose: WorkspaceLauncherPurpose
    let onFinish: (() -> Void)?
    @ObservedObject private var store: ProjectStore
    @ObservedObject private var convStore: ConversationStore
    @State private var search = ""
    @State private var editingID: UUID?     // an existing project being edited inline
    @State private var draft: Project?       // a new, unsaved project card (in edit mode)
    @State private var adoptionRequestID: UUID?
    @State private var isCommittingDraft = false
    @State private var editCommitRequestID: UUID?
    @State private var editingGeneration = UUID()
    @State private var isLauncherVisible = false
    @State private var launcherGeneration = UUID()
    @State private var pickedIdea: ProjectIdea?         // a starting-point tile awaiting the editor
    @State private var editingInstructions: WorkspaceInstructionsTarget?
    @State private var homeHovering = false
    @State private var helpHovering = false
    @Environment(\.dismissWindow) private var dismissWindow

    @MainActor init(
        purpose: WorkspaceLauncherPurpose = .browse,
        onFinish: (() -> Void)? = nil
    ) {
        self.init(
            purpose: purpose,
            onFinish: onFinish,
            store: .shared,
            conversationStore: .shared)
    }

    @MainActor init(
        purpose: WorkspaceLauncherPurpose = .browse,
        onFinish: (() -> Void)? = nil,
        store: ProjectStore,
        conversationStore: ConversationStore
    ) {
        self.purpose = purpose
        self.onFinish = onFinish
        _store = ObservedObject(wrappedValue: store)
        _convStore = ObservedObject(wrappedValue: conversationStore)
    }

    private var isNewWindowPicker: Bool { purpose == .newWindow }
    private var projects: [Project] {
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        // Product-owned destinations are not one of YOUR Workspaces. They get fixed rows beside
        // Home instead of editable cards in the user-Workspace grid.
        let all = store.projects.filter { !ReservedWorkspace.owns($0.id) }
        guard !q.isEmpty else { return all }
        return all.filter { $0.displayName.lowercased().contains(q) || $0.cwd.lowercased().contains(q) }
    }

    /// A workspace may own exactly one live window. Selecting one that is already open focuses it;
    /// selecting one without a window creates it.
    private func isOpen(_ p: Project) -> Bool {
        AgentBridge.live.allObjects.contains { b in
            p.cwd.isEmpty ? (b.projectID == p.id) : (b.cwd == p.cwd && b.projectID == nil)
        }
    }

    private func dismissLauncher() {
        // The captured origin belongs to one visit. Leaving it set would let a later gallery visit
        // opened from somewhere else act on a window the user is no longer working in.
        ActiveWorkspace.shared.launcherOriginBridgeID = nil
        if let onFinish { onFinish() }
        else { dismissWindow(id: "projects") }
    }
    private func conversationCount(_ p: Project) -> Int {
        convStore.summaries.filter {
            WorkspaceScope.project(p.id).contains($0, projects: store.projects)
        }.count
    }
    /// Whether any of this project's conversations produced artifacts — a folder-less project that
    /// MAKES things is a design space, and its type chip says so.
    private func hasArtifacts(_ p: Project) -> Bool {
        convStore.summaries.contains {
            WorkspaceScope.project(p.id).contains($0, projects: store.projects)
                && convStore.conversationHasArtifacts($0.id)
        }
    }
    /// One visual weight for both places.
    ///
    /// Home and Help were drawn a third larger than the workspace cards underneath them: a 29pt
    /// glyph in a 50pt frame and an 18pt title, against a card whose own name is 15pt. Two of them
    /// stacked outside the scroll view meant a short window showed a header, two oversized places,
    /// and a sliver of the workspaces the panel is for. They are destinations, not a second header,
    /// so they now match the cards they sit above.
    private enum PlaceRow {
        static let icon: CGFloat = 21
        static let iconFrame: CGFloat = 36
        static let title: CGFloat = 15
        static let subtitle: CGFloat = 12
        static let innerHorizontal: CGFloat = 14
        static let innerVertical: CGFloat = 11
    }

    private let columns = [GridItem(.adaptive(minimum: 300, maximum: 460), spacing: 16)]

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            // Everything below the header scrolls, places included. They used to be pinned above the
            // scroll view, so their height came out of the workspace grid's: the shorter the window,
            // the less of the panel's actual subject you could see, and no amount of scrolling got
            // them out of the way.
            GeometryReader { viewport in
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        VStack(spacing: 0) {
                            homeRow
                            helpRow
                        }
                        if projects.isEmpty && draft == nil {   // filtered — so a non-matching search shows "No matches"
                            emptyState
                        } else {
                            if let d = draft { draftSection(d) }
                            if !projects.isEmpty {
                                LazyVGrid(columns: columns, alignment: .leading, spacing: 16) {
                                    ForEach(projects) { p in
                                        if editingID == p.id {
                                            ProjectCardEditor(
                                                project: p,
                                                isNew: false,
                                                isCommitting: editCommitRequestID != nil,
                                                onCommit: saveEdit,
                                                onCancel: {
                                                    editingGeneration = UUID()
                                                    editingID = nil
                                                })
                                        } else {
                                            ProjectCard(project: p, conversationCount: conversationCount(p),
                                                        hasArtifacts: hasArtifacts(p),
                                                        onOpen: { select(p) },
                                                        onEdit: {
                                                            guard editCommitRequestID == nil else { return }
                                                            abandonAdoptionDraft()
                                                            draft = nil
                                                            editingGeneration = UUID()
                                                            editingID = p.id
                                                        },
                                                        onChooseFolder: { chooseFolder(for: p) },
                                                        onInstructions: { openInstructions(p) },
                                                        onDelete: { store.remove(p.id) },
                                                        onToggleFavorite: { store.update(p.id) { $0.favorite.toggle() } })
                                        }
                                    }
                                }
                            }
                        }
                    }
                    .padding(20)
                }
                // A SwiftUI Window scene asks its root for an intrinsic ideal size before it has a
                // finite native viewport. Without this explicit proposal the ScrollView votes for
                // its whole document height; the restored window clips that tall view instead of
                // giving it a scroll range. GeometryReader accepts the window's remaining height
                // and makes that height the one viewport authority as the window is resized.
                .frame(width: viewport.size.width, height: viewport.size.height)
                .accessibilityIdentifier("workspace.launcher.scroll")
            }
        }
        .frame(minWidth: 680, minHeight: 460)
        .background(Color.nBg)
        .sheet(item: $editingInstructions) { target in
            WorkspaceInstructionsEditor(target: target) { editingInstructions = nil }
        }
        .onAppear {
            isLauncherVisible = true
            launcherGeneration = UUID()
            consumePendingRequests()
        }
        .onChange(of: store.pendingNewProjectRequest) { _, _ in consumePendingNew() }
        .onChange(of: store.pendingEditProjectRequest) { _, _ in consumePendingEdit() }
        // The Projects window scene survives closing (it's reopened, not recreated), so an abandoned
        // inline editor would come back as a phantom "blank project" card. Drop stale edit state.
        // The Projects window scene survives closing, so a pending adoptee must die with the draft it
        // belonged to — otherwise a workspace created days later would silently swallow it.
        .onDisappear {
            isLauncherVisible = false
            launcherGeneration = UUID()
            draft = nil
            // The folder transaction itself is deliberately not cancellable. Detaching this
            // request identity prevents its eventual completion from editing or closing a reused
            // launcher scene; placement failures remain global and may still explain themselves.
            editCommitRequestID = nil
            editingGeneration = UUID()
            editingID = nil
            pickedIdea = nil
            editingInstructions = nil
            abandonAdoptionDraft()
        }
    }

    /// The new-project panel: the inline editor beside a gallery of STARTING POINTS — concrete kinds
    /// of projects (code workspace, writing, research, design, data, planning) that prefill the card.
    private func draftSection(_ d: Project) -> some View {
        HStack(alignment: .top, spacing: 16) {
            ProjectCardEditor(
                              project: d,
                              isNew: true,
                              isCommitting: isCommittingDraft,
                              pickedIdea: $pickedIdea,
                              onCommit: { commitDraft($0); pickedIdea = nil },
                              onCancel: {
                                  draft = nil
                                  pickedIdea = nil
                                  // Abandoning the draft abandons the move with it.
                                  abandonAdoptionDraft()
                              })
                .frame(width: 340)
                .fixedSize(horizontal: false, vertical: true)  // hug the form, don't stretch to the ideas column
            VStack(alignment: .leading, spacing: 8) {
                Text("What kind of workspace?")
                    .font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 235), spacing: 10)],
                          alignment: .leading, spacing: 10) {
                    ForEach(ProjectIdea.all) { idea in
                        IdeaCard(idea: idea) { pickedIdea = idea }
                    }
                }
            }
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Text(isNewWindowPicker ? "Choose a Workspace" : "Workspaces")
                .font(.system(size: 22, weight: .semibold))
            Spacer()
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary).font(.system(size: 12))
                TextField("Search workspaces…", text: $search).textFieldStyle(.plain).frame(width: 170)
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color.nSurface)
                .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(Color.nMuted.opacity(0.5))))
            Button { startNew() } label: { Label("New Workspace", systemImage: "plus") }
                .buttonStyle(PillButtonStyle(kind: .accent))
                .disabled(isCommittingDraft || editCommitRequestID != nil)
        }
        .padding(.horizontal, 20).padding(.vertical, 14)
    }


    /// The product-help expert is a fixed destination like Memory: it keeps ordinary Conversation
    /// history, but it is not an editable Workspace the person created.
    private var helpRow: some View {
        let conversations = convStore.summaries.filter {
            $0.workspaceID == HelpWorkspace.id
        }.count
        let conversationLabel = conversations == 1
            ? String(localized: "1 conversation")
            : String(localized: "\(conversations) conversations")
        return HStack(spacing: 10) {
            Button { pickHelp() } label: {
                HStack(spacing: 15) {
                    Image(systemName: HelpWorkspace.iconSymbol)
                        .font(.system(size: PlaceRow.icon)).foregroundStyle(Color.nAccent)
                        .frame(width: PlaceRow.iconFrame)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(verbatim: HelpWorkspace.name)
                            .font(.system(size: PlaceRow.title, weight: .semibold))
                        Text(verbatim: HelpWorkspace.goal)
                            .font(.system(size: PlaceRow.subtitle)).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(verbatim: conversationLabel)
                        .font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
                        .padding(.horizontal, 10).padding(.vertical, 4)
                        .background(Capsule().fill(Color.nElevated))
                    Image(systemName: "chevron.right")
                        .font(.system(size: 14, weight: .semibold)).foregroundStyle(.tertiary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Help — ask Mechanician how the app works")
            .accessibilityIdentifier("workspace.reserved.help")
        }
        .padding(.horizontal, PlaceRow.innerHorizontal).padding(.vertical, PlaceRow.innerVertical)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous)
            .fill(Color.nAccent.opacity(helpHovering ? 0.10 : 0.055)))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
            .strokeBorder(Color.nAccent.opacity(helpHovering ? 0.7 : 0.35), lineWidth: 1))
        .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .onHover { helpHovering = $0 }
        .animation(.easeOut(duration: 0.15), value: helpHovering)
        .padding(.bottom, 0)
        .help("Open the Help workspace")
    }

    /// The launcher's **Home** destination — the default workspace for loose chats. An accent-tinted
    /// hero card with accent chat bubbles, so it reads as a real alternative to picking a workspace,
    /// not a section header.
    private var homeRow: some View {
        let n = convStore.summaries.filter {
            WorkspaceScope.home.contains($0, projects: store.projects)
        }.count
        return HStack(spacing: 10) {
            Button { pickHome() } label: {
                HStack(spacing: 15) {
                    // The same house the toolbar segment draws. The card can afford a glyph that
                    // only makes sense beside its label; the segment cannot, and a place wears one
                    // glyph or it is two places.
                    Image(systemName: WorkspacePlace.home.iconSymbol)
                        .font(.system(size: PlaceRow.icon)).foregroundStyle(Color.nAccent)
                        .frame(width: PlaceRow.iconFrame)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Home").font(.system(size: PlaceRow.title, weight: .semibold))
                        Text("Your default workspace for loose conversations")
                            .font(.system(size: PlaceRow.subtitle)).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(n == 1 ? "1 conversation" : "\(n) conversations")
                        .font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
                        .padding(.horizontal, 10).padding(.vertical, 4)
                        .background(Capsule().fill(Color.nElevated))
                    Image(systemName: "chevron.right")
                        .font(.system(size: 14, weight: .semibold)).foregroundStyle(.tertiary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Home — your default workspace, loose conversations")
            .accessibilityIdentifier("workspace.reserved.home")

            Menu {
                Button(WorkspaceInstructionsPresentation.actionTitle) {
                    editingInstructions = .home
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.system(size: 15))
                    .foregroundStyle(.secondary)
                    .frame(width: 26, height: 24)
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityLabel("Actions for Home")
            .accessibilityIdentifier("workspaceManagement.actions.home")
            .help("Workspace actions for Home")
        }
        .padding(.horizontal, PlaceRow.innerHorizontal).padding(.vertical, PlaceRow.innerVertical)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous)
            .fill(Color.nAccent.opacity(homeHovering ? 0.10 : 0.055)))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
            .strokeBorder(Color.nAccent.opacity(homeHovering ? 0.7 : 0.35), lineWidth: 1))
        .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .onHover { homeHovering = $0 }
        .animation(.easeOut(duration: 0.15), value: homeHovering)
        .padding(.bottom, 8)
        .contextMenu {
            Button(WorkspaceInstructionsPresentation.actionTitle) {
                editingInstructions = .home
            }
            Button("Copy Link") { MechanicianURL.copyLink(to: .workspace(nil)) }
        }
        .help("Go to Home, your default workspace")
    }

    private var emptyState: some View {
        VStack(spacing: 0) {
            Spacer()
            if search.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "square.grid.2x2").font(.system(size: 30)).foregroundStyle(Color.nAccent)
                    Text("Start your first workspace").font(.system(size: 21, weight: .semibold))
                    Text("A workspace keeps related conversations, files, and instructions together. Pick a path. You can add more workspaces any time.")
                        .font(.system(size: 13)).foregroundStyle(.secondary)
                        .multilineTextAlignment(.center).frame(maxWidth: 440).fixedSize(horizontal: false, vertical: true)
                }
                HStack(alignment: .top, spacing: 14) {
                    onboardCard(icon: "folder", title: "Open a folder",
                                subtitle: "A dev workspace: code, commands, git, and the terminal all run in a working directory, with optional workspace and repository instructions.",
                                action: openFolderAsProject)
                    onboardCard(icon: "bubble.left.and.bubble.right", title: "Start without a folder",
                                subtitle: "A clean space for conversations and files, with no folder needed. Great for research, planning, or writing.",
                                action: { startNew() })
                }
                .padding(.top, 24)
            } else {
                Image(systemName: "magnifyingglass").font(.system(size: 30)).foregroundStyle(.tertiary)
                Text("No workspaces match “\(search)”").font(.system(size: 15)).foregroundStyle(.secondary).padding(.top, 10)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, minHeight: 320).padding(30)
    }

    private func onboardCard(icon: String, title: String, subtitle: String, action: @escaping () -> Void) -> some View {
        OnboardCard(icon: icon, title: title, subtitle: subtitle, action: action)
    }

    /// The "Open a folder" onboarding path: pick a folder, then create-or-reuse its Project and open it.
    private func openFolderAsProject() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.allowsMultipleSelection = false
        panel.prompt = "Open as Workspace"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        if let existing = store.projects.first(where: { $0.cwd == url.path }) { select(existing) }
        else {
            let p = Project(name: url.lastPathComponent, cwd: url.path)
            store.upsert(p); select(p)
        }
    }

    private func startNew(preservingAdoption: Bool = false) {
        guard editCommitRequestID == nil else { return }
        if !preservingAdoption { abandonAdoptionDraft() }
        editingGeneration = UUID()
        editingID = nil
        draft = Project(name: "", cwd: "")
    }

    private func abandonAdoptionDraft() {
        adoptionRequestID = abandonWorkspaceLauncherAdoption(
            adoptionRequestID,
            projects: store)
    }

    /// Select a workspace. The normal launcher replaces its origin window in place; the new-window
    /// chooser follows the same focus-or-create rule, then dismisses its temporary chooser window.
    @discardableResult
    private func select(_ p: Project) -> AgentBridge? {
        // The window the user opened the gallery from, not whichever workspace window was key
        // last. See `WorkspaceLauncherRouting`.
        select(p, replacing: liveWorkspaceBridge(ActiveWorkspace.shared.launcherOriginBridgeID))
    }

    @discardableResult
    private func select(_ p: Project, replacing origin: AgentBridge?) -> AgentBridge? {
        let bridge: AgentBridge?
        if isNewWindowPicker {
            bridge = openProject(p)
        } else {
            bridge = routeToWorkspaceProject(
                p,
                replacing: origin)
        }
        dismissLauncher()
        return bridge
    }
    private func pickHome() {
        // File ▸ Open Workspace in New Window must never replace the source window's workspace.
        // `openHome` preserves Home's one-window invariant itself: it creates Home when absent,
        // otherwise focuses it.
        if isNewWindowPicker {
            openHome()
            dismissLauncher()
            return
        }
        switch WorkspaceLauncherRouting.homeRoute(
            originBridgeID: ActiveWorkspace.shared.launcherOriginBridgeID,
            among: liveWorkspaceWindowIdentities()
        ) {
        case .focus(let bridgeID):
            if let owner = liveWorkspaceBridge(bridgeID) {
                focusWorkspaceWindow(of: owner)
            } else {
                openHome()
            }
        case .replaceOrigin(let bridgeID):
            if let origin = liveWorkspaceBridge(bridgeID) {
                origin.enterHome()
                focusWorkspaceWindow(of: origin)
            } else {
                openHome()
            }
        case .openWorkspace:
            openHome()
        }
        dismissLauncher()
    }


    private func pickHelp() {
        HelpWorkspace.ensure(in: store) { project in
            guard let project else { return }
            select(project)
        }
    }

    private func consumePendingNew() {
        guard !isCommittingDraft, editCommitRequestID == nil,
              store.pendingNewProjectRequest,
              WorkspaceLauncherPendingNewPolicy.canConsume(
                purpose: purpose,
                hasPendingAdoption: store.pendingWorkspaceAdoption != nil)
        else { return }

        store.pendingNewProjectRequest = false
        adoptionRequestID = store.pendingWorkspaceAdoption?.id
        startNew(preservingAdoption: true)
    }
    private func consumePendingEdit() {
        guard !isCommittingDraft, editCommitRequestID == nil,
              let id = store.pendingEditProjectRequest else { return }
        store.pendingEditProjectRequest = nil
        guard store.contains(id), !ReservedWorkspace.owns(id) else { return }
        abandonAdoptionDraft()
        search = ""
        draft = nil
        editingGeneration = UUID()
        editingID = id
    }
    private func consumePendingRequests() {
        consumePendingNew()
        consumePendingEdit()
    }

    private func commitDraft(_ p: Project) {
        guard !isCommittingDraft else { return }
        guard let requestID = adoptionRequestID else {
            switch persistWorkspaceLauncherDraft(
                p,
                adoption: nil,
                adoptionRequestID: nil,
                projects: store,
                conversations: convStore,
                artifacts: .shared) {
            case .blocked(let failure):
                presentAdoptionFailure(failure)
            case .committed(let destination):
                draft = nil
                _ = select(destination)
            }
            return
        }
        guard let pending = store.pendingWorkspaceAdoption,
              pending.id == requestID else {
            adoptionRequestID = nil
            draft = nil
            return
        }

        let commitGeneration = launcherGeneration
        let originBridgeID = pending.originBridgeID
        let origin = liveWorkspaceBridge(originBridgeID)
        let undoManager = workspaceUndoManager(for: origin)
        isCommittingDraft = true
        WorkspaceAdoption.adoptAfterAcquiring(
            pending,
            intoNewWorkspace: p,
            projects: store,
            conversations: convStore,
            artifactStore: .shared,
            undoManager: undoManager
        ) { result, committedProject in
            isCommittingDraft = false
            guard result.succeeded, let destination = committedProject else {
                if result == .requestChanged {
                    // A newer launcher request may already own this reusable scene. The stale
                    // completion can clear only its own editor identity, never the successor's.
                    if adoptionRequestID == requestID {
                        adoptionRequestID = nil
                        if draft?.id == p.id { draft = nil }
                    }
                }
                if isLauncherVisible, launcherGeneration == commitGeneration {
                    presentAdoptionFailure(result)
                }
                if isLauncherVisible { consumePendingRequests() }
                return
            }

            if adoptionRequestID == requestID {
                adoptionRequestID = nil
                if draft?.id == p.id { draft = nil }
            }
            // A newer move may have arrived while the old commit unwound. Keep the reusable scene
            // on the newest editor instead of dismissing it and stranding that request.
            if store.pendingNewProjectRequest || store.pendingEditProjectRequest != nil {
                if isLauncherVisible { consumePendingRequests() }
                return
            }
            // Closing the launcher is cancellation of its UI effects. The durable move may already
            // have committed, but a late callback must not refocus or replace another window.
            guard isLauncherVisible, launcherGeneration == commitGeneration else { return }
            let destinationBridge = select(
                destination,
                replacing: liveWorkspaceBridge(originBridgeID))
            switch pending.target {
            case .conversations(let ids):
                if let conversationID = ids.min(by: { $0.uuidString < $1.uuidString }) {
                    revealWorkspaceConversation(
                        conversationID,
                        in: .project(destination),
                        on: destinationBridge) { _ in }
                }
            case .artifacts(let ids):
                if let artifactID = ids.min(by: { $0.uuidString < $1.uuidString }) {
                    ActiveWorkspace.shared.revealArtifact(artifactID)
                }
            }
        }
    }

    private func presentAdoptionFailure(_ result: WorkspaceAdoptionResult) {
        guard let message = result.failureMessage else { return }
        let alert = NSAlert()
        if result == .busy {
            alert.messageText = "Move postponed"
        } else if result == .moveInProgress {
            alert.messageText = "Move already in progress"
        } else if case .workspacePersistenceFailed = result {
            alert.messageText = "Workspace wasn’t created"
        } else {
            alert.messageText = "Item unavailable"
        }
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
    private func saveEdit(_ p: Project) {
        guard !ReservedWorkspace.owns(p.id) else { editingID = nil; return }
        guard let base = store.project(p.id) else { editingID = nil; return }
        guard editCommitRequestID == nil else { return }
        guard base.cwd != p.cwd else {
            // Patch only the fields owned by this editor so a concurrent favorite, instructions,
            // ordering, or other metadata change remains intact.
            store.update(p.id) { $0.name = p.name; $0.goal = p.goal }
            editingGeneration = UUID()
            editingID = nil
            return
        }

        let requestID = UUID()
        let commitLauncherGeneration = launcherGeneration
        let commitEditingGeneration = editingGeneration
        editCommitRequestID = requestID
        let accepted = WorkspaceFolderAssignment.assign(p.cwd, to: base) { succeeded in
            guard editCommitRequestID == requestID else { return }
            editCommitRequestID = nil

            // A reusable launcher scene can close and reopen, or receive a newer edit request,
            // while the Conversation graph hydrates. The durable folder operation may finish, but
            // its stale callback must never close or overwrite that successor editor.
            guard isLauncherVisible,
                  launcherGeneration == commitLauncherGeneration,
                  editingGeneration == commitEditingGeneration,
                  editingID == p.id
            else { return }
            guard succeeded else {
                consumePendingRequests()
                return
            }

            // Folder publication succeeded. Apply only this editor's name and goal to the latest
            // Project value, preserving unrelated metadata that may have changed during hydration.
            guard store.update(p.id, {
                $0.name = p.name
                $0.goal = p.goal
            }) != nil else {
                editingGeneration = UUID()
                editingID = nil
                consumePendingRequests()
                return
            }
            editingGeneration = UUID()
            editingID = nil
            consumePendingRequests()
        }
        if !accepted, editCommitRequestID == requestID {
            editCommitRequestID = nil
        }
    }

    private func chooseFolder(for project: Project) {
        _ = WorkspaceFolderAssignment.chooseFolder(for: project)
    }

    private func openInstructions(_ p: Project) {
        editingInstructions = .project(p.id)
    }
}

/// A first-run guided-path card ("Open a folder" / "Start without a folder"). Hover-lit like a real
/// project card so the two most important first-run CTAs don't read as inert.
private struct OnboardCard: View {
    let icon: String
    let title: String
    let subtitle: String
    let action: () -> Void
    @State private var hovering = false
    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 8) {
                Image(systemName: icon).font(.system(size: 20)).foregroundStyle(Color.nAccent)
                Text(title).font(.system(size: 14, weight: .semibold)).foregroundStyle(.primary)
                Text(subtitle).font(.system(size: 12)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(width: 220, alignment: .leading).padding(16)
            .cardSurface(cornerRadius: 12)
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(hovering ? Color.nAccent.opacity(0.55) : Color.clear))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

/// The monochrome TYPE chip: says what KIND of project a card is — a folder-backed workspace, a
/// chat-only topic, or a design space (no folder, but it has produced artifacts). Replaces the old
/// colored-initial badge, which repeated the adjacent name and pulled random hues into the gallery.
private struct ProjectTypeChip: View {
    let symbol: String
    let caption: String
    var body: some View {
        RoundedRectangle(cornerRadius: 7, style: .continuous)
            .fill(Color.nElevated)
            .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous)
                .strokeBorder(Color.nMuted.opacity(0.5)))
            .frame(width: 30, height: 30)
            .overlay(Image(systemName: symbol)
                .font(.system(size: 12.5, weight: .medium)).foregroundStyle(.secondary))
            .help(caption)
    }
}

/// A starting-point suggestion in the new-project panel — a concrete kind of project, with enough
/// detail to know what you'd use it for. Picking one prefills the draft card (and, for folder-backed
/// kinds, opens the folder picker).
struct ProjectIdea: Identifiable, Equatable {
    let icon: String
    let title: String
    let detail: String
    let suggestedName: String   // empty → keep whatever's typed (folder kinds name themselves)
    let goal: String
    let needsFolder: Bool
    var id: String { title }

    static let all: [ProjectIdea] = [
        ProjectIdea(icon: "chevron.left.forwardslash.chevron.right", title: "Code workspace",
                    detail: "Open a repo and work in it: terminal, git, builds, and its instruction file all follow the folder.",
                    suggestedName: "", goal: "", needsFolder: true),
        ProjectIdea(icon: "doc.text", title: "Writing & docs",
                    detail: "Draft and revise essays, posts, or documentation. Pieces land as artifacts you can copy out.",
                    suggestedName: "Writing", goal: "Drafts and revisions, kept together.", needsFolder: false),
        ProjectIdea(icon: "magnifyingglass", title: "Research",
                    detail: "Dig into one subject across many conversations: collect sources, compare findings, build summaries.",
                    suggestedName: "Research", goal: "Notes, sources, and findings on one subject.", needsFolder: false),
        ProjectIdea(icon: "paintbrush", title: "Design & prototypes",
                    detail: "Sketch UI mockups, dashboards, diagrams, and one-off pages, rendered live in the preview pane.",
                    suggestedName: "Design studio", goal: "Mockups and prototypes.", needsFolder: false),
        ProjectIdea(icon: "chart.bar", title: "Data analysis",
                    detail: "Point at a folder of CSVs or exports and ask for charts, tables, and what stands out.",
                    suggestedName: "", goal: "Charts and findings from this folder's data.", needsFolder: true),
        ProjectIdea(icon: "checklist", title: "Planning",
                    detail: "Plan a trip, an event, or a move: itineraries, checklists, schedules, and reminders in one place.",
                    suggestedName: "Planning", goal: "Plans, checklists, and schedules.", needsFolder: false),
    ]
}

/// One starting-point tile in the new-project panel.
private struct IdeaCard: View {
    let idea: ProjectIdea
    let action: () -> Void
    @State private var hovering = false
    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 9) {
                Image(systemName: idea.icon)
                    .font(.system(size: 13, weight: .medium)).foregroundStyle(.secondary)
                    .frame(width: 20).padding(.top, 2)
                VStack(alignment: .leading, spacing: 2) {
                    Text(idea.title).font(.system(size: 12.5, weight: .semibold)).foregroundStyle(.primary)
                    Text(idea.detail).font(.system(size: 11)).foregroundStyle(.secondary)
                        .multilineTextAlignment(.leading).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.nSurface))
            .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(hovering ? Color.nAccent.opacity(0.55) : Color.nMuted.opacity(0.35)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

/// A project card in its display state. The ••• menu stays visible for pointer, keyboard, and
/// VoiceOver discovery; the same actions remain available from the right-click context menu.
private struct ProjectCard: View {
    let project: Project
    let conversationCount: Int
    let hasArtifacts: Bool
    let onOpen: () -> Void
    let onEdit: () -> Void
    let onChooseFolder: () -> Void
    let onInstructions: () -> Void
    let onDelete: () -> Void
    let onToggleFavorite: () -> Void
    @State private var hovering = false
    /// Removing a Workspace leaves its Conversations behind with an unresolved membership, and it
    /// is the one destructive action in the app that never asked. Every other one does, and says
    /// what is lost.
    @State private var confirmingRemoval = false

    /// Type-chip glyph: a custom symbol wins; else folder-backed → folder, artifact-producing
    /// topic → design (the artifacts glyph used app-wide), otherwise chat-only.
    private var chipSymbol: String {
        project.iconSymbol ?? (project.isWorkspace ? "folder"
            : hasArtifacts ? "square.stack.3d.up" : "bubble.left.and.bubble.right")
    }
    private var chipCaption: String {
        project.isWorkspace ? "Folder workspace — works in \(project.cwd)"
            : hasArtifacts ? "Design workspace — no folder, with artifacts"
            : "Workspace with no folder"
    }

    var body: some View {
        cardBody
            .confirmationDialog(
                "Remove \(project.name)?",
                isPresented: $confirmingRemoval,
                titleVisibility: .visible
            ) {
                Button("Remove Workspace", role: .destructive) { onDelete() }
                Button("Cancel", role: .cancel) { confirmingRemoval = false }
            } message: {
                Text(conversationCount == 1
                     ? "Its conversation is not deleted, but it will no longer be in a workspace."
                     : conversationCount == 0
                       ? "Its instructions and settings are removed."
                       : "Its \(conversationCount) conversations are not deleted, but they will no "
                         + "longer be in a workspace.")
            }
    }

    private var cardBody: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 10) {
                ProjectTypeChip(symbol: chipSymbol, caption: chipCaption)
                VStack(alignment: .leading, spacing: 2) {
                    Text(project.displayName).font(.system(size: 15, weight: .semibold)).lineLimit(1)
                    if project.isWorkspace {
                        Text(project.cwd).font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.tertiary).lineLimit(1).truncationMode(.head)
                    }
                }
                Spacer(minLength: 0)
                if project.favorite {
                    Image(systemName: "star.fill").font(.system(size: 11))
                        .foregroundStyle(Color.nGoldText)
                }
                Menu {
                    menuItems
                } label: {
                    Image(systemName: "ellipsis.circle").font(.system(size: 14))
                        .foregroundStyle(.secondary).frame(width: 22, height: 20).contentShape(Rectangle())
                }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .accessibilityLabel("Actions for \(project.displayName)")
                .accessibilityIdentifier("workspaceManagement.actions.\(project.id.uuidString)")
                .help("Workspace actions for \(project.displayName)")
            }
            if !project.goal.isEmpty {
                Text(project.goal).font(.system(size: 12)).foregroundStyle(.secondary)
                    .lineLimit(2).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 4)
            HStack(spacing: 6) {
                Image(systemName: "bubble.left.and.bubble.right").font(.system(size: 10))
                Text("\(conversationCount)")
                Spacer()
                Text("Updated \(project.updatedAt.formatted(date: .abbreviated, time: .omitted))")
            }.font(.system(size: 11)).foregroundStyle(.tertiary)
        }
        .padding(14).frame(height: 132, alignment: .topLeading).frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface(cornerRadius: 12)
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .strokeBorder(hovering ? Color.nAccent.opacity(0.55) : Color.clear))
        .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .onHover { hovering = $0 }
        .onTapGesture { onOpen() }   // single-click opens (matches the Home card); ⋯ / right-click for actions
        .contextMenu { menuItems }
        .help("Open \(project.displayName)")
    }

    @ViewBuilder private var menuItems: some View {
        Button("Open") { onOpen() }
        Button(WorkspaceInstructionsPresentation.actionTitle) { onInstructions() }
        Button(WorkspaceFolderAssignment.actionTitle(for: project)) { onChooseFolder() }
        Button(WorkspaceManagementPresentation.editWorkspaceActionTitle) { onEdit() }
        Button(project.favorite ? "Remove from Favorites" : "Add to Favorites") { onToggleFavorite() }
        Button("Copy Link") { MechanicianURL.copyLink(to: .workspace(project.id)) }
        Divider()
        Button("Remove Workspace…", role: .destructive) { confirmingRemoval = true }
    }
}

/// A project card in its edit state (new or existing), edited in place. Name + goal are inline fields;
/// a new project also picks a working folder. Enter or Create/Save commits; Esc or Cancel dismisses.
private struct ProjectCardEditor: View {
    let base: Project
    let isNew: Bool
    let isCommitting: Bool
    let onCommit: (Project) -> Void
    let onCancel: () -> Void
    @Binding var pickedIdea: ProjectIdea?   // a starting-point tile the user tapped (new drafts only)
    @State private var name: String
    @State private var goal: String
    @State private var folder: String
    @State private var picking = false
    @FocusState private var nameFocused: Bool

    init(
         project: Project,
         isNew: Bool,
         isCommitting: Bool = false,
         pickedIdea: Binding<ProjectIdea?> = .constant(nil),
         onCommit: @escaping (Project) -> Void, onCancel: @escaping () -> Void) {
        base = project
        self.isNew = isNew
        self.isCommitting = isCommitting
        self.onCommit = onCommit
        self.onCancel = onCancel
        _pickedIdea = pickedIdea
        _name = State(initialValue: project.name)
        _goal = State(initialValue: project.goal)
        _folder = State(initialValue: project.cwd)
    }
    // A folder is optional: no folder → a chat-only "topic" project (scoped by projectID, not cwd).
    private var canCommit: Bool { !name.trimmingCharacters(in: .whitespaces).isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 10) {
                ProjectTypeChip(symbol: folder.isEmpty ? "bubble.left.and.bubble.right" : "folder",
                                caption: folder.isEmpty ? "Workspace with no folder"
                                                        : "Folder workspace — works in \(folder)")
                TextField("Workspace name", text: $name)
                    .textFieldStyle(.plain).font(.system(size: 15, weight: .semibold))
                    .focused($nameFocused).onSubmit { commit() }
                    .disabled(isCommitting)
            }
            TextField("Description (optional)", text: $goal, axis: .vertical)
                .textFieldStyle(.plain).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1...2)
                .disabled(isCommitting)
            if isNew {
                HStack(spacing: 6) {
                    Image(systemName: folder.isEmpty ? "bubble.left.and.bubble.right" : "folder").font(.system(size: 10))
                    Text(folder.isEmpty ? "No folder — conversations and artifacts" : folder)
                        .font(.system(size: 11, design: .monospaced)).lineLimit(1).truncationMode(.head)
                    Spacer()
                    Button(folder.isEmpty ? "Choose…" : "Change…") { picking = true }
                        .buttonStyle(PillButtonStyle(kind: .neutral))
                        .disabled(isCommitting)
                }.foregroundStyle(.tertiary)
            } else {
                HStack(spacing: 6) {
                    Image(systemName: folder.isEmpty ? "folder.badge.plus" : "folder").font(.system(size: 10))
                    Text(folder.isEmpty ? "No folder — conversations and artifacts" : folder)
                        .font(.system(size: 11, design: .monospaced)).lineLimit(1).truncationMode(.head)
                    Spacer()
                    Button(folder.isEmpty ? "Add Folder…" : "Change…") { picking = true }
                        .buttonStyle(PillButtonStyle(kind: .neutral))
                        .disabled(isCommitting)
                }.foregroundStyle(.tertiary)
            }
            Spacer(minLength: 2)
            HStack(spacing: 8) {
                Spacer()
                Button("Cancel") { onCancel() }.buttonStyle(PillButtonStyle(kind: .plain))
                    .disabled(isCommitting)
                    .keyboardShortcut(.cancelAction)
                Button {
                    commit()
                } label: {
                    HStack(spacing: 5) {
                        if isCommitting { ProgressView().controlSize(.small) }
                        Text(isCommitting ? (isNew ? "Creating…" : "Saving…")
                                          : (isNew ? "Create" : "Save"))
                    }
                }
                    .buttonStyle(PillButtonStyle(kind: .accent))
                    .disabled(!canCommit || isCommitting).keyboardShortcut(.defaultAction)
            }
        }
        .padding(14).frame(minHeight: 132, alignment: .topLeading).frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface(cornerRadius: 12)
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .strokeBorder(Color.nAccent.opacity(0.8), lineWidth: 1.5))
        .fileImporter(isPresented: $picking, allowedContentTypes: [.folder], allowsMultipleSelection: false) { result in
            if case .success(let urls) = result, let url = urls.first {
                folder = url.path
                if name.trimmingCharacters(in: .whitespaces).isEmpty { name = url.lastPathComponent }
            }
        }
        // Defer focus one runloop — setting it synchronously in onAppear loses to the search field,
        // so typed text landed in Search instead of the name field.
        .onAppear { DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { nameFocused = true } }
        // A tapped starting point prefills the card without stomping anything already typed; the
        // folder-backed kinds jump straight to the picker (which also names the project).
        .onChange(of: pickedIdea) { _, idea in
            guard let idea else { return }
            if name.trimmingCharacters(in: .whitespaces).isEmpty, !idea.suggestedName.isEmpty {
                name = idea.suggestedName
            }
            if goal.trimmingCharacters(in: .whitespaces).isEmpty { goal = idea.goal }
            if idea.needsFolder, folder.isEmpty { picking = true }
            pickedIdea = nil
        }
    }

    private func commit() {
        guard canCommit, !isCommitting else { return }
        var p = base
        p.name = name.trimmingCharacters(in: .whitespaces)
        p.goal = goal.trimmingCharacters(in: .whitespaces)
        // Every workspace can gain or change a folder after creation. saveEdit routes existing
        // workspace changes through the guarded assignment coordinator.
        p.cwd = folder
        onCommit(p)
    }
}

/// UserDefaults key for the last place the user was (a Project's id, or absent = Home). Drives
/// launch restore so relaunch lands where you were, never on an empty surface (the v0.80 lesson).
let lastLocationKey = "lastLocationProjectID"

/// Go **Home** without creating a duplicate: focus an existing Home window; otherwise reuse the
/// originating workspace window in place; if there is no workspace origin (launch or a utility
/// window), create Home. The toolbar, launcher, and ⇧⌘H command all share this exact policy.
@MainActor func goHome(from origin: AgentBridge?) {
    UserDefaults.standard.removeObject(forKey: lastLocationKey)   // Home is now the last location
    if let bridge = AgentBridge.live.allObjects.first(where: { $0.projectID == nil && $0.cwd.isEmpty }),
       let win = bridge.window {
        if win.isMiniaturized { win.deminiaturize(nil) }
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        return
    }
    if let origin {
        origin.enterHome()
        origin.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        return
    }
    makeWorkspaceWindow().makeKeyAndOrderFront(nil)
}

/// Open Home from a context that must never replace another workspace (launch and File ▸ Open
/// Workspace in New Window).
@MainActor func openHome() {
    goHome(from: nil)
}

/// Reopen the windows that were open at quit, tab groups and all. Falls back to
/// `openLastLocationOrHome()` — today's exact single-window behavior — whenever the ledger is
/// absent, empty, unreadable, or names nothing that still exists. Called once at launch.
///
/// Replay goes through `makeWorkspaceWindow` rather than `openProject`/`openHome`: those helpers
/// focus the Workspace's existing native group, while replay must rebuild each durable Conversation
/// tab in that group and preserve its order. `openProject` also rewrites `lastLocationKey` on every
/// call, which would leave the fallback pointing at whichever Workspace happened to replay last.
@MainActor func restoreWorkspaceSession() {
    // Read once, up front. Nothing below writes the ledger — capture happens only at terminate — but
    // taking the snapshot before any window exists makes that independent of anything a window does
    // as it comes up.
    guard let ledger = WorkspaceSessionLedger.load(),
          let groups = WorkspaceSessionPlan.restore(
            ledger: ledger,
            projectExists: { ProjectStore.shared.project($0) != nil },
            // The launch caller is gated on `whenReady`, so this is the complete authoritative
            // inventory. A missing id names an old empty placeholder and must not become a window.
            conversationExists: { ConversationStore.shared.hasConversation($0) },
            projectIDForLegacyCwd: { cwd in
                guard let scope = WorkspaceScope.resolve(
                    projectID: nil,
                    cwd: cwd,
                    projects: ProjectStore.shared.projects),
                      case .project(let id) = scope else { return nil }
                return id
            },
            conversationBelongsToWorkspace: { conversationID, projectID in
                guard let summary = ConversationStore.shared.summary(conversationID),
                      let scope = WorkspaceScope.resolve(
                          summary: summary,
                          projects: ProjectStore.shared.projects)
                else { return false }
                if let projectID { return scope == .project(projectID) }
                return scope == .home
            })
    else {
        openLastLocationOrHome()
        return
    }

    var rebuilt: [(window: NSWindow, entry: WorkspaceSessionLedger.Entry)] = []
    for group in groups {
        var previous: NSWindow?
        var rebuiltGroup: [(window: NSWindow, entry: WorkspaceSessionLedger.Entry)] = []
        for entry in group.windows {
            let project = entry.projectID.flatMap(ProjectStore.shared.project)
            // The same split `openConversation` uses: a folder workspace is keyed by cwd with a nil
            // projectID, a topic workspace by projectID with an empty cwd.
            let window = makeWorkspaceWindow(
                initialFolder: project?.isWorkspace == true ? project?.cwd
                    : (project == nil && !entry.cwd.isEmpty ? entry.cwd : nil),
                initialProjectID: project?.isWorkspace == true ? nil : project?.id,
                initialConversationID: entry.conversationID,
                startsFreshConversation: entry.restoresBlankTab,
                initialWindowLayout: entry.layout)
            if let previous {
                // Join after the tab just added, so the group comes back in its recorded order
                // rather than reversed.
                previous.addTabbedWindow(window, ordered: .above)
            } else {
                // The group's first tab has to be on screen before anything can join it —
                // `openWorkspaceTab` likewise only ever adds to a window that is already showing.
                window.orderFront(nil)
            }
            previous = window
            rebuilt.append((window, entry))
            rebuiltGroup.append((window, entry))
        }
        // Selection is per native tab group, not only for the one group that happened to be key at
        // quit. Older ledgers lack `wasSelected`; retain their prior last-added behavior.
        if let selected = rebuiltGroup.first(where: { $0.entry.wasSelected })
            ?? rebuiltGroup.first(where: { $0.entry.wasKey })
            ?? rebuiltGroup.last {
            selected.window.tabGroup?.selectedWindow = selected.window
        }
    }
    // Key last, and only once: ordering a tab's window front also selects that tab, so restoring
    // focus and restoring which tab was on top are the same act.
    let focus = rebuilt.first(where: { $0.entry.wasKey }) ?? rebuilt.first
    focus?.window.makeKeyAndOrderFront(nil)
}

/// Restore the last place you were — a Project's window, or Home. Falls back to Home if the project
/// is gone. Called once at launch (launch restores; Open Workspace in New Window → Home).
@MainActor func openLastLocationOrHome() {
    if let s = UserDefaults.standard.string(forKey: lastLocationKey),
       let id = UUID(uuidString: s), let p = ProjectStore.shared.project(id) {
        openProject(p)
    } else {
        openHome()
    }
}

/// Open a project: focus an already-open window bound to its folder, else open a new workspace window
/// there. The window's project-scoped sidebar then shows only this project's conversations.
@MainActor
@discardableResult
func openProject(_ project: Project) -> AgentBridge? {
    UserDefaults.standard.set(project.id.uuidString, forKey: lastLocationKey)   // for launch restore
    // Focus an already-open window bound to this project — matched by folder for a workspace project,
    // by projectID for a folder-less topic project — else open a new one.
    // The same predicate every other path uses. This one used to match a folder Workspace by cwd
    // alone, so it could focus (or fail to dedupe against) a window already bound to a topic
    // Workspace in that folder.
    let match = WorkspaceLauncherRouting.owner(
        ofProjectID: project.id,
        cwd: project.cwd,
        among: liveWorkspaceWindowIdentities()
    ).flatMap { liveWorkspaceBridge($0.bridgeID) }
    if let bridge = match, let win = bridge.window {
        if win.isMiniaturized { win.deminiaturize(nil) }
        win.makeKeyAndOrderFront(nil)
        // A newly-created window consumes this when it becomes ready; an already-open one never
        // becomes ready again, so consume it here or a requested conversation would be dropped
        // exactly when the workspace was already open.
        ActiveWorkspace.shared.consumeOpenConversation(bridge)
        return bridge
    }
    let window: NSWindow
    if project.cwd.isEmpty {
        window = makeWorkspaceWindow(initialFolder: nil, initialProjectID: project.id)
    } else {
        window = makeWorkspaceWindow(initialFolder: project.cwd)
    }
    window.makeKeyAndOrderFront(nil)
    return AgentBridge.live.allObjects.first { $0.window === window }
}
