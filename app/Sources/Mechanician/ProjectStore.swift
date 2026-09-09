import Foundation
import Combine

/// A Project is the organizing container above conversations (idiom B: one project ⇒ one workspace
/// window, conversations as tabs). It's the promotion of today's *implicit* project — the cwd-bound
/// workspace window — into an explicit, named, reopenable entity.
///
/// `cwd` is the fork that lets one type serve both audiences:
///   • EMPTY cwd  → a "topic" project (a beautiful named space for chat + files; terminal/git/build
///     inspector tabs stay dormant). This is the non-developer's project.
///   • Non-empty  → a dev workspace: cwd drives the terminal, git, build, and file browser.
struct Project: Identifiable, Codable {
    var id = UUID()
    /// User-facing name. For a folder-backed project this defaults to the folder's last path component.
    var name: String
    /// A short, human-facing description shown on the project card. NOT the model's context — that's
    /// the app-owned `instructions` below plus any provider-native repository guidance.
    var goal: String = ""
    /// Provider-neutral standing instructions for this Project, whether it has a folder or not.
    /// Mechanician stores these in app data and delivers them through each provider's supported
    /// instruction channel. Repository-owned CLAUDE.md / AGENTS.md files remain separate additions.
    var instructions: String = ""
    /// The working directory this project is bound to. EMPTY = topic project; non-empty = dev workspace.
    var cwd: String = ""
    /// Pinned to the top of the projects launcher (favorites-first ordering).
    var favorite: Bool = false
    /// Explicit manual position from drag-to-reorder; nil until hand-ordered, then honored over recency.
    var sortIndex: Int? = nil
    /// SF Symbol for the project's glyph in the launcher. nil → a sensible default (workspace vs topic).
    var iconSymbol: String? = nil
    /// Accent color (hex `#RRGGBB`) for the project chip; nil → the app accent.
    var colorHex: String? = nil
    /// Model/access route inherited by new conversations in this workspace. Optional so existing
    /// project files decode without guessing; the first new conversation adopts the current global
    /// selection as the migration default.
    var defaultModelSelection: ModelSelection? = nil
    var createdAt: Date = Date()
    var updatedAt: Date = Date()

    /// A dev workspace (has a working dir) vs a topic project (chat + files only).
    var isWorkspace: Bool { !cwd.isEmpty }

    var displayName: String {
        if !name.isEmpty { return name }
        return cwd.isEmpty ? "Untitled Workspace" : URL(fileURLWithPath: cwd).lastPathComponent
    }

    /// The glyph shown for this project when it hasn't been given a custom one.
    var effectiveSymbol: String { iconSymbol ?? (isWorkspace ? "folder" : "bubble.left.and.bubble.right") }

    init(id: UUID = UUID(), name: String, goal: String = "", instructions: String = "", cwd: String = "",
         favorite: Bool = false, sortIndex: Int? = nil, iconSymbol: String? = nil,
         colorHex: String? = nil, defaultModelSelection: ModelSelection? = nil,
         createdAt: Date = Date(), updatedAt: Date = Date()) {
        self.id = id
        self.name = name
        self.goal = goal
        self.instructions = instructions
        self.cwd = cwd
        self.favorite = favorite
        self.sortIndex = sortIndex
        self.iconSymbol = iconSymbol
        self.colorHex = colorHex
        self.defaultModelSelection = defaultModelSelection
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    // Tolerant decode so a project file written by a future build (with more fields) still loads, and
    // vice-versa — matches the convention every other model in this app follows.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        goal = try c.decodeIfPresent(String.self, forKey: .goal) ?? ""
        instructions = try c.decodeIfPresent(String.self, forKey: .instructions) ?? ""
        cwd = try c.decodeIfPresent(String.self, forKey: .cwd) ?? ""
        favorite = try c.decodeIfPresent(Bool.self, forKey: .favorite) ?? false
        sortIndex = try c.decodeIfPresent(Int.self, forKey: .sortIndex)
        iconSymbol = try c.decodeIfPresent(String.self, forKey: .iconSymbol)
        colorHex = try c.decodeIfPresent(String.self, forKey: .colorHex)
        defaultModelSelection = try c.decodeIfPresent(ModelSelection.self, forKey: .defaultModelSelection)
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        updatedAt = try c.decodeIfPresent(Date.self, forKey: .updatedAt) ?? Date()
    }
}

/// A workspace assignment has one of two honest destinations. Home is not a hidden/synthetic
/// Project: it is the deliberate absence of a workspace id and working folder.
enum WorkspaceDestination {
    case home
    case project(Project)

    var projectID: UUID? {
        switch self {
        case .home: return nil
        case .project(let project): return project.id
        }
    }

    var cwd: String {
        switch self {
        case .home: return ""
        case .project(let project): return project.cwd
        }
    }

    /// Folder-backed workspace windows are keyed by cwd; Home/topic windows are keyed by project id.
    var windowProjectID: UUID? {
        switch self {
        case .home: return nil
        case .project(let project): return project.cwd.isEmpty ? project.id : nil
        }
    }

    var displayName: String {
        switch self {
        case .home: return "Home"
        case .project(let project): return project.displayName
        }
    }

    var scope: WorkspaceScope {
        switch self {
        case .home: return .home
        case .project(let project): return .project(project.id)
        }
    }
}

/// The small, value-only view of a live workspace window needed to choose a conversation handoff.
/// Keeping this policy independent of `AgentBridge` lets regression tests prove the cross-window
/// ownership decision without creating windows or touching the process-global conversation store.
struct WorkspaceAdoptionLiveBridgeSnapshot: Equatable {
    let bridgeID: UUID
    let hasWindow: Bool
    let currentConversationID: UUID?
    let projectID: UUID?
    let cwd: String

    fileprivate func displays(_ destination: WorkspaceDestination) -> Bool {
        displays(projectID: destination.projectID, cwd: destination.cwd)
    }

    fileprivate func displays(projectID destinationProjectID: UUID?, cwd destinationCwd: String) -> Bool {
        destinationCwd.isEmpty
            ? projectID == destinationProjectID && cwd.isEmpty
            : projectID == nil && cwd == destinationCwd
    }
}

struct WorkspaceAdoptionLiveHandoffPlan: Equatable {
    let receivingBridgeID: UUID
    let sourceBridgeIDs: [UUID]
    let revealConversationID: UUID
}

/// Choose one existing destination window, every source viewer that must relinquish ownership, and
/// the deterministic moved conversation the receiver reveals. The source action deliberately has
/// no destination metadata: relinquishing a conversation must leave that window in its old place.
func workspaceAdoptionLiveHandoffPlan(
    movedConversationIDs: Set<UUID>,
    destination: WorkspaceDestination,
    bridges: [WorkspaceAdoptionLiveBridgeSnapshot],
    explicitReceivingBridgeID: UUID? = nil
) -> WorkspaceAdoptionLiveHandoffPlan? {
    workspaceAdoptionLiveHandoffPlan(
        movedConversationIDs: movedConversationIDs,
        destinationProjectID: destination.projectID,
        destinationCwd: destination.cwd,
        bridges: bridges,
        explicitReceivingBridgeID: explicitReceivingBridgeID)
}

/// Value-only counterpart used by Undo, whose recorded destination may outlive its Project row.
func workspaceAdoptionLiveHandoffPlan(
    movedConversationIDs: Set<UUID>,
    destinationProjectID: UUID?,
    destinationCwd: String,
    bridges: [WorkspaceAdoptionLiveBridgeSnapshot],
    explicitReceivingBridgeID: UUID? = nil
) -> WorkspaceAdoptionLiveHandoffPlan? {
    guard let revealConversationID = movedConversationIDs.min(by: {
        $0.uuidString < $1.uuidString
    }) else { return nil }

    let receivingBridgeID: UUID?
    if let explicitReceivingBridgeID {
        receivingBridgeID = bridges.contains {
            $0.bridgeID == explicitReceivingBridgeID
        } ? explicitReceivingBridgeID : nil
    } else {
        receivingBridgeID = bridges
            .filter {
                $0.hasWindow
                    && ($0.currentConversationID.map {
                        !movedConversationIDs.contains($0)
                    } ?? true)
                    && $0.displays(projectID: destinationProjectID, cwd: destinationCwd)
            }
            .map(\.bridgeID)
            .min(by: { $0.uuidString < $1.uuidString })
    }
    guard let receivingBridgeID else { return nil }

    let sourceBridgeIDs = bridges.compactMap { bridge in
        bridge.bridgeID != receivingBridgeID
            && bridge.currentConversationID.map(movedConversationIDs.contains) == true
            ? bridge.bridgeID
            : nil
    }
    .sorted(by: { $0.uuidString < $1.uuidString })
    return WorkspaceAdoptionLiveHandoffPlan(
        receivingBridgeID: receivingBridgeID,
        sourceBridgeIDs: sourceBridgeIDs,
        revealConversationID: revealConversationID)
}

/// Identify only live windows still displaying the Workspace whose folder is changing. A foreign
/// Conversation may belong to the impact graph solely because it holds a moved Artifact; that makes
/// its nested snapshot eligible for convergence, never its window or working directory.
func workspaceFolderSourceBridgeIDs(
    projectID: UUID,
    previousCwd: String,
    memberConversationIDs: Set<UUID>,
    bridges: [WorkspaceAdoptionLiveBridgeSnapshot]
) -> Set<UUID> {
    Set(bridges.compactMap { bridge in
        guard bridge.hasWindow else { return nil }
        if bridge.currentConversationID.map(memberConversationIDs.contains) == true {
            return bridge.bridgeID
        }
        if bridge.projectID == projectID { return bridge.bridgeID }
        return !previousCwd.isEmpty
            && bridge.projectID == nil
            && bridge.cwd == previousCwd
            ? bridge.bridgeID
            : nil
    })
}

/// The object waiting for a New Workspace editor to create its destination. Sets are supported now
/// so a later multi-select command does not need another process-global pending variable.
enum WorkspaceAdoptionTarget: Equatable {
    case conversations(Set<UUID>)
    case artifacts(Set<UUID>)

    var isEmpty: Bool {
        switch self {
        case .conversations(let ids), .artifacts(let ids): return ids.isEmpty
        }
    }
}

struct PendingWorkspaceAdoption: Identifiable, Equatable {
    let id: UUID
    let target: WorkspaceAdoptionTarget
    /// The workspace window where the move began. The launcher is process-global and may not be
    /// frontmost when Create is clicked, so Undo/routing must not infer ownership from then-current
    /// focus. Nil is valid for utility-originated or test requests.
    let originBridgeID: UUID?

    init(
        id: UUID = UUID(),
        target: WorkspaceAdoptionTarget,
        originBridgeID: UUID? = nil
    ) {
        self.id = id
        self.target = target
        self.originBridgeID = originBridgeID
    }
}

enum WorkspaceAdoptionResult: Equatable {
    case moved(conversations: Int, artifacts: Int)
    case unchanged
    case unavailable
    case busy
    case moveInProgress
    case bindingUnavailable(ConversationHydrationError)
    case destinationWindowChanged
    case requestChanged
    case workspacePersistenceFailed(String)

    var succeeded: Bool {
        switch self {
        case .moved, .unchanged: return true
        case .unavailable, .busy, .moveInProgress, .bindingUnavailable,
             .destinationWindowChanged, .requestChanged, .workspacePersistenceFailed:
            return false
        }
    }

    var failureMessage: String? {
        switch self {
        case .busy:
            return "Stop the active work before moving this conversation to another workspace."
        case .moveInProgress:
            return "Another workspace move is still being prepared. Try again in a moment."
        case .bindingUnavailable(let error):
            return "No items moved. \(error.localizedDescription)"
        case .destinationWindowChanged:
            return "No items moved because the destination window changed or closed. Try the move again."
        case .requestChanged:
            return nil
        case .workspacePersistenceFailed(let detail):
            return "The Workspace could not be saved, so nothing moved. \(detail)"
        case .unavailable:
            return "The item or destination workspace is no longer available."
        case .moved, .unchanged:
            return nil
        }
    }
}

/// Identity-bearing ownership for the one process-wide placement transaction. A delayed callback
/// holding an old lease can never clear a newer operation that acquired the gate after it.
struct WorkspacePlacementLease: Equatable {
    fileprivate let id: UUID
}

/// A New Workspace sidecar written completely off-main but not yet visible to loaders or the UI.
/// Publishing is one same-directory rename at the prepared placement commit edge.
struct PreparedWorkspaceProject {
    fileprivate let project: Project
    fileprivate let stagedURL: URL
    fileprivate let publishedURL: URL
    fileprivate let sourceBytes: Data
    fileprivate let usesSQLiteAuthority: Bool
}

enum WorkspaceProjectPersistenceFailure: Error, Equatable {
    case write(String)
    case publish(String)

    var message: String {
        switch self {
        case .write(let message), .publish(let message): return message
        }
    }
}

private enum ProjectStorePersistenceError: LocalizedError {
    case repositoryUnavailable(String)

    var errorDescription: String? {
        switch self {
        case .repositoryUnavailable(let message): message
        }
    }
}

/// The single source of truth for the PROJECT list and its on-disk persistence, shared by every window
/// in the process — the exact sibling of `ConversationStore`. A create/rename/delete/update in any
/// window republishes to all of them via the `@Published` array (no broadcast, no races).
///
/// Removing a project deliberately does NOT delete its conversations. They retain the removed id as
/// unresolved records; a future external-file recovery design can surface them without pretending
/// they belong to Home or recreating the removed workspace from cwd.
/// The outcome of repointing a project's working folder via `ProjectStore.setCwd`.
enum SetProjectCwdResult: Equatable {
    case ok                 // cwd changed and the project's conversations were re-keyed
    case unchanged          // the new path equals the current cwd — no-op
    case collision(String)  // another project already owns that folder (carries its display name)
    case notFound           // no project with this id
    case reserved           // app-owned Workspaces are permanently folderless
    case busy               // another placement transaction is hydrating or committing
}

/// One exact, replay-safe request to change a Workspace's working folder. The expected source path
/// prevents a delayed hydration callback from applying an edit after another window has already
/// repointed the same Workspace.
struct WorkspaceFolderReassignmentRequest: Equatable {
    let id: UUID
    let projectID: UUID
    let expectedCwd: String
    let destinationCwd: String

    init(
        id: UUID = UUID(),
        projectID: UUID,
        expectedCwd: String,
        destinationCwd: String
    ) {
        self.id = id
        self.projectID = projectID
        self.expectedCwd = expectedCwd
        self.destinationCwd = destinationCwd
    }
}

/// Folder assignment has stricter outcomes than an ordinary item move: the Project can disappear,
/// its source binding can change while records hydrate, or another Workspace can claim the folder.
enum WorkspaceFolderReassignmentResult: Error, Equatable {
    case changed
    case unchanged
    case collision(String)
    case unavailable
    case sourceChanged
    case activeWork
    case moveInProgress
    case bindingUnavailable(ConversationHydrationError)

    var succeeded: Bool {
        switch self {
        case .changed, .unchanged: return true
        case .collision, .unavailable, .sourceChanged, .activeWork, .moveInProgress,
             .bindingUnavailable: return false
        }
    }

    var failureMessage: String? {
        switch self {
        case .collision(let name):
            return "“\(name)” already uses that folder. Open that Workspace instead, or pick a different folder."
        case .unavailable:
            return "This Workspace or one of its Conversation files is no longer available. Nothing changed."
        case .sourceChanged:
            return "The Workspace changed while its Conversations were loading. Nothing changed; try again."
        case .activeWork:
            return "Stop the active work before changing this Workspace’s folder."
        case .moveInProgress:
            return "Another Workspace move is still being prepared. Try again in a moment."
        case .bindingUnavailable(let error):
            return "No folder changed. \(error.localizedDescription)"
        case .changed, .unchanged:
            return nil
        }
    }
}

@MainActor
final class ProjectStore: ObservableObject {
    static let shared = ProjectStore()
#if DEBUG
    /// Focused persistence tests fail the real Workspace write before its authority COMMIT.
    nonisolated(unsafe) static var persistenceWriteTestHook: (() throws -> Void)?
#endif

    @Published private(set) var projects: [Project] = []
    @Published private(set) var homeSettings = HomeWorkspaceSettings()
    /// Non-nil while a project/home-settings write has exhausted its disk retries. Shown with a
    /// Retry button beside the conversation-save banner; a silently dropped workspace edit (name,
    /// instructions, folder) previously left no trace at all.
    @Published private(set) var persistenceError: String?
    private var failedProjectIDs: Set<UUID> = []
    private var failedProjectDeletes: Set<UUID> = []
    private var homeSettingsSaveFailed = false
    private var lastPersistenceFailureDetail: String?

    /// Set by the toolbar / File-menu "New Project…" actions; the launcher consumes it (on appear or on
    /// change) to open a fresh inline card. A published flag — not a Notification — so it survives the
    /// race where the launcher window is still being created when the request is made.
    @Published var pendingNewProjectRequest = false
    /// The toolbar workspace menu can reveal one exact card in the reusable All Workspaces window.
    /// Keep this durable until the scene consumes it for the same open-window race as new requests.
    @Published var pendingEditProjectRequest: UUID?
    /// Conversations or artifacts waiting to be re-filed into whatever workspace the open
    /// new-workspace draft creates. The request id makes cancellation request-scoped: an old window
    /// may not clear a newer move that replaced its editor.
    @Published private(set) var pendingWorkspaceAdoption: PendingWorkspaceAdoption?

    private let appSupportBaseOverride: URL?
    private let selectedSQLiteAuthority: Bool
    private let authorityRepository: LibraryAuthorityRepository?
    private let authorityRepositoryOpenFailure: String?

    /// Internal override keeps persistence tests isolated from the user's real workspace store.
    init(
        appSupportBaseOverride: URL? = nil,
        libraryAuthorityRepository: LibraryAuthorityRepository? = nil
    ) {
        self.appSupportBaseOverride = appSupportBaseOverride
        let processSelectedSQLite: Bool
        if case .sqlite = StorageAuthorityBootstrap.current.disposition {
            processSelectedSQLite = appSupportBaseOverride == nil
                && NSClassFromString("XCTestCase") == nil
        } else {
            processSelectedSQLite = false
        }
        selectedSQLiteAuthority = libraryAuthorityRepository != nil || processSelectedSQLite
        if let libraryAuthorityRepository {
            authorityRepository = libraryAuthorityRepository
            authorityRepositoryOpenFailure = nil
        } else if processSelectedSQLite {
            authorityRepository = LibraryAuthorityRepository.sharedIfActive
            authorityRepositoryOpenFailure = authorityRepository == nil
                ? "The SQLite authority repository was not available for the selected root."
                : nil
        } else {
            authorityRepository = nil
            authorityRepositoryOpenFailure = nil
        }
        load()
    }

    // MARK: - Lookup

    func project(_ id: UUID?) -> Project? {
        guard let id else { return nil }
        return projects.first { $0.id == id }
    }
    func contains(_ id: UUID) -> Bool { projects.contains { $0.id == id } }

    /// Begin one New Workspace adoption. The launcher owns one editor, so a second request replaces
    /// the old target deliberately and receives a new identity; stale cancellation must provide the
    /// old id and therefore cannot erase it.
    @discardableResult
    func beginWorkspaceAdoption(
        _ target: WorkspaceAdoptionTarget,
        originBridgeID: UUID? = nil
    ) -> UUID? {
        guard !target.isEmpty else { return nil }
        let request = PendingWorkspaceAdoption(
            target: target,
            originBridgeID: originBridgeID)
        pendingWorkspaceAdoption = request
        return request.id
    }

    func cancelWorkspaceAdoption(_ requestID: UUID? = nil) {
        guard let requestID, pendingWorkspaceAdoption?.id == requestID else { return }
        pendingWorkspaceAdoption = nil
    }

    func takeWorkspaceAdoption(_ requestID: UUID? = nil) -> PendingWorkspaceAdoption? {
        guard let requestID, pendingWorkspaceAdoption?.id == requestID else { return nil }
        defer { pendingWorkspaceAdoption = nil }
        return pendingWorkspaceAdoption
    }

    func instructions(for target: WorkspaceInstructionsTarget) -> String? {
        switch target {
        case .home:
            return homeSettings.instructions
        case .project(let id):
            return project(id)?.instructions
        }
    }

    func displayName(for target: WorkspaceInstructionsTarget) -> String? {
        switch target {
        case .home:
            return "Home"
        case .project(let id):
            return project(id)?.displayName
        }
    }

    func folder(for target: WorkspaceInstructionsTarget) -> String? {
        guard case .project(let id) = target,
              let cwd = project(id)?.cwd.trimmingCharacters(in: .whitespacesAndNewlines),
              !cwd.isEmpty else { return nil }
        return cwd
    }

    /// The canonical launcher order: favorites pinned on top, then the hand-ordered position (once
    /// dragged) or most-recent activity — same single-Int strict-weak-ordering as `ConversationStore`.
    static func order(_ a: Project, _ b: Project) -> Bool {
        if a.favorite != b.favorite { return a.favorite }
        let ai = a.sortIndex ?? Int.max, bi = b.sortIndex ?? Int.max
        if ai != bi { return ai < bi }
        return a.updatedAt > b.updatedAt
    }

    // MARK: - Mutations (persist + republish to every window)

    /// Replace-or-append `p` by id, keep the list sorted, and persist. The single write path.
    func upsert(_ p: Project) {
        let accepted: Project
        if let reserved = ReservedWorkspace.workspace(for: p.id) {
            // Reserved identities are created only in their canonical folderless shape. Once one
            // exists, a generic upsert is not an edit back door; runtime model preference changes
            // use `update`, whose narrow exception is explicit below.
            guard !contains(p.id) else { return }
            accepted = reserved.canonicalProject(preservingRuntimePreferenceFrom: p)
        } else {
            accepted = p
        }
        if let idx = projects.firstIndex(where: { $0.id == accepted.id }) {
            projects[idx] = accepted
        } else {
            projects.append(accepted)
        }
        projects.sort(by: Self.order)
        save(accepted)
    }

    /// Encode and write a New Workspace to an ignored staging name on the serial project queue.
    /// Conversation hydration starts only after this succeeds; the final project filename is not
    /// published until the full placement graph is resident and the exact request still owns it.
    func prepareWorkspaceProject(
        _ project: Project,
        completion: @escaping @MainActor (
            Result<PreparedWorkspaceProject, WorkspaceProjectPersistenceFailure>
        ) -> Void
    ) {
        let project = ReservedWorkspace.workspace(for: project.id)?
            .canonicalProject(preservingRuntimePreferenceFrom: project) ?? project
        if selectedSQLiteAuthority {
            guard authorityRepository != nil else {
                completion(.failure(.write(authorityRepositoryOpenFailure
                    ?? "The SQLite authority repository is unavailable.")))
                return
            }
            do {
                let data = try Self.makeSidecarEncoder().encode(project)
                let placeholder = URL(fileURLWithPath: "/dev/null")
                completion(.success(PreparedWorkspaceProject(
                    project: project,
                    stagedURL: placeholder,
                    publishedURL: placeholder,
                    sourceBytes: data,
                    usesSQLiteAuthority: true)))
            } catch {
                completion(.failure(.write(error.localizedDescription)))
            }
            return
        }
        let stagedURL = storeDir.appendingPathComponent(
            ".workspace-\(project.id.uuidString)-\(UUID().uuidString).preparing")
        let publishedURL = storeDir.appendingPathComponent("\(project.id.uuidString).json")
        saveQueue.async {
            let result: Result<PreparedWorkspaceProject, WorkspaceProjectPersistenceFailure>
            do {
                let data = try Self.makeSidecarEncoder().encode(project)
                try data.write(to: stagedURL, options: .atomic)
                result = .success(PreparedWorkspaceProject(
                    project: project,
                    stagedURL: stagedURL,
                    publishedURL: publishedURL,
                    sourceBytes: data,
                    usesSQLiteAuthority: false))
            } catch {
                try? FileManager.default.removeItem(at: stagedURL)
                result = .failure(.write(error.localizedDescription))
            }
            Task { @MainActor in completion(result) }
        }
    }

    /// Publish prepared bytes before any Conversation starts referencing this id. The disk work is
    /// only a same-directory rename; encoding and data write already happened on `saveQueue`.
    func publishPreparedWorkspaceProject(
        _ prepared: PreparedWorkspaceProject
    ) -> Result<Project, WorkspaceProjectPersistenceFailure> {
        guard project(prepared.project.id) == nil else {
            return .failure(.publish("A Workspace with this identity already exists."))
        }
        if prepared.usesSQLiteAuthority {
            guard selectedSQLiteAuthority, let authorityRepository else {
                return .failure(.publish(authorityRepositoryOpenFailure
                    ?? "The SQLite authority repository is unavailable."))
            }
            if let failure = Self.retryingDiskOperation({
                _ = try authorityRepository.commit(workspace: prepared.project)
            }) {
                return .failure(.publish(failure.localizedDescription))
            }
            projects.append(prepared.project)
            projects.sort(by: Self.order)
            failedProjectIDs.remove(prepared.project.id)
            failedProjectDeletes.remove(prepared.project.id)
            refreshPersistenceError()
            return .success(prepared.project)
        }
        guard !FileManager.default.fileExists(atPath: prepared.publishedURL.path) else {
            return .failure(.publish("A Workspace with this identity already exists."))
        }
        do {
            try FileManager.default.moveItem(
                at: prepared.stagedURL,
                to: prepared.publishedURL)
        } catch {
            return .failure(.publish(error.localizedDescription))
        }
        projects.append(prepared.project)
        projects.sort(by: Self.order)
        failedProjectIDs.remove(prepared.project.id)
        refreshPersistenceError()
        return .success(prepared.project)
    }

    func discardPreparedWorkspaceProject(_ prepared: PreparedWorkspaceProject) {
        guard !prepared.usesSQLiteAuthority else { return }
        let url = prepared.stagedURL
        saveQueue.async { try? FileManager.default.removeItem(at: url) }
    }

    /// Defensive rollback for a failure discovered in the same non-yielding placement commit that
    /// published the destination. A process crash after publication may leave an empty Workspace,
    /// but it can never leave moved content pointing at an absent one.
    func rollbackPublishedWorkspaceProject(_ prepared: PreparedWorkspaceProject) {
        guard !ReservedWorkspace.owns(prepared.project.id) else { return }
        projects.removeAll { $0.id == prepared.project.id }
        if prepared.usesSQLiteAuthority {
            guard let authorityRepository else { return }
            saveQueue.async {
                _ = try? authorityRepository.deleteWorkspace(id: prepared.project.id)
            }
            return
        }
        try? FileManager.default.removeItem(at: prepared.publishedURL)
    }

    /// Mutate one project in place (persisting the result), or no-op if it isn't present. `updatedAt`
    /// is stamped for the caller so recency ordering stays honest.
    @discardableResult
    func update(_ id: UUID, _ mutate: (inout Project) -> Void) -> Project? {
        guard let idx = projects.firstIndex(where: { $0.id == id }) else { return nil }
        let current = projects[idx]
        var proposed = current
        mutate(&proposed)
        if let reserved = ReservedWorkspace.workspace(for: id) {
            // The model preference is runtime configuration rather than editable Workspace
            // identity. If that one field did not change, reject the generic mutation completely:
            // even `updatedAt` must not make a forbidden edit look like activity.
            guard proposed.defaultModelSelection != current.defaultModelSelection else {
                return current
            }
            proposed.updatedAt = Date()
            proposed = reserved.preservingIdentity(of: current, after: proposed)
        } else {
            proposed.updatedAt = Date()
        }
        projects[idx] = proposed
        projects.sort(by: Self.order)
        let p = projects.first { $0.id == id }
        if let p { save(p) }
        return p
    }

    /// Save the app-owned instruction text for Home or a real Project. A missing Project is reported
    /// to the editor instead of silently closing after a no-op.
    @discardableResult
    func setInstructions(_ instructions: String, for target: WorkspaceInstructionsTarget) -> Bool {
        switch target {
        case .home:
            homeSettings.instructions = instructions
            homeSettings.updatedAt = Date()
            saveHomeSettings(homeSettings)
            return true
        case .project(let id):
            guard !ReservedWorkspace.owns(id) else { return false }
            return update(id) { $0.instructions = instructions } != nil
        }
    }

    /// Remove a project and its file. Its conversations are left untouched with an unresolved id.
    func remove(_ id: UUID) {
        guard !ReservedWorkspace.owns(id) else { return }
        projects.removeAll { $0.id == id }
        deleteFile(id)
    }

    /// Legacy synchronous compatibility seam retained for focused ownership tests. Production UI
    /// must use `WorkspaceAdoption.reassignWorkspaceFolderAfterAcquiring`; this method may hydrate
    /// records synchronously and cannot establish the complete foreign-holder graph.
    /// Repoint an existing project at a new working folder — the "edit a project's cwd" primitive
    /// (distinct from `projectID(forCwd:)`, which MINTS a project for an unknown folder). A folder
    /// project's execution location is its cwd; the Project id remains its canonical membership.
    /// Folder paths must still be unique because window routing and agentd working directories use
    /// them, so this:
    ///   (a) rejects a folder another project already owns, or those `first(where: cwd==)` lookups
    ///       would become ambiguous (the implicit "cwd is unique across projects" invariant); and
    ///   (b) re-keys THIS project's conversations to the new cwd using `WorkspaceScope`, so an
    ///       authoritative id wins and only an unambiguous legacy cwd can gain canonical membership.
    /// LOSSLESS: only mutates `cwd`/`projectID` fields; never deletes or reorders a conversation.
    @discardableResult
    func setCwd(_ id: UUID, to newPath: String) -> SetProjectCwdResult {
        guard !ReservedWorkspace.owns(id) else { return .reserved }
        guard let lease = WorkspaceAdoption.beginPlacementOperation() else { return .busy }
        defer { WorkspaceAdoption.endPlacementOperation(lease) }
        let trimmed = newPath.trimmingCharacters(in: .whitespaces)
        guard let current = project(id) else { return .notFound }
        if current.cwd == trimmed { return .unchanged }
        if !trimmed.isEmpty, let clash = projects.first(where: { $0.id != id && $0.cwd == trimmed }) {
            return .collision(clash.displayName)
        }
        let oldCwd = current.cwd
        let scope = WorkspaceScope.project(id)
        let affectedConversationIDs = Set(ConversationStore.shared.summaries.compactMap {
            scope.contains($0, projects: projects) ? $0.id : nil
        })
        update(id) { $0.cwd = trimmed }
        WorkspaceAdoption.reassignWorkspaceFolder(
            projectID: id,
            previousCwd: oldCwd,
            cwd: trimmed,
            conversationIDs: affectedConversationIDs)
        return .ok
    }

    // MARK: - Binding a conversation's cwd to a Project

    /// The project bound to `cwd`, minting one (named for the folder) if absent. Empty cwd → nil (a
    /// loose Home conversation). This is how opening a new folder mints its Project, and
    /// how a new conversation inherits the right `projectID`.
    @discardableResult
    func projectID(forCwd cwd: String, createIfMissing: Bool = true) -> UUID? {
        let trimmed = cwd.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        if let p = projects.first(where: { $0.cwd == trimmed }) { return p.id }
        guard createIfMissing else { return nil }
        let p = Project(name: URL(fileURLWithPath: trimmed).lastPathComponent, cwd: trimmed)
        upsert(p)
        return p.id
    }

    /// One-time migration: promote every distinct working directory among existing conversations into
    /// a named Project, and tag each conversation with its `projectID`. Empty-cwd conversations stay
    /// loose (Home). Idempotent — no-ops once any project exists (the projects dir is
    /// per-store, so the dev build migrates its own store independently). LOSSLESS: only sets
    /// `projectID`, never deletes or reorders a conversation.
    func migrateIfNeeded(
        conversations explicitConversations: ConversationStore? = nil,
        defaults: UserDefaults = .standard
    ) {
        guard projects.isEmpty else { return }
        let conversations = explicitConversations ?? .shared
        // Only records that predate workspace ids are migration evidence. A non-nil id with no
        // matching Project is a deliberately unresolved/removal case; its cwd must not resurrect a
        // workspace that the user removed.
        let legacy = conversations.summaries.filter { $0.workspaceID == nil }
        let cwds = Set(legacy.map {
            $0.workspaceCWD.trimmingCharacters(in: .whitespaces)
        }.filter { !$0.isEmpty })
        guard !cwds.isEmpty else { return }
        var idForCwd: [String: UUID] = [:]
        for cwd in cwds {
            let p = Project(name: URL(fileURLWithPath: cwd).lastPathComponent, cwd: cwd)
            idForCwd[cwd] = p.id
            upsert(p)
        }
        var migrated = 0
        for c in legacy {
            if let pid = idForCwd[c.workspaceCWD.trimmingCharacters(in: .whitespaces)] {
                conversations.update(c.id) { $0.projectID = pid }
                migrated += 1
            }
        }
        // Record a one-time notice so this partition reads as intentional organization, not lost
        // history — ContentView surfaces it once on the first post-migration launch.
        defaults.set(true, forKey: "pendingMigrationNotice")
        defaults.set(migrated, forKey: "migratedConversationCount")
        defaults.set(cwds.count, forKey: "migratedProjectCount")
    }

    /// Converge the two persisted pieces of healthy conversation workspace metadata without
    /// inventing ownership. A valid id wins and receives its Project's canonical cwd; an older
    /// cwd-only conversation can be backfilled only when exactly one existing Project owns that
    /// full normalized path. Dangling ids and unknown/ambiguous paths stay untouched for explicit
    /// recovery rather than being silently moved to Home or resurrecting a removed workspace.
    @discardableResult
    func repairConversationWorkspaceBindings(
        conversations explicitConversations: ConversationStore? = nil
    ) -> Int {
        let conversations = explicitConversations ?? .shared
        var repaired = 0
        for conversation in conversations.summaries {
            let project: Project?
            if let projectID = conversation.workspaceID {
                project = self.project(projectID)
            } else if !conversation.workspaceCWD.isEmpty {
                let normalizedCwd = conversation.workspaceCWD.trimmingCharacters(
                    in: .whitespacesAndNewlines)
                guard !normalizedCwd.isEmpty else { continue }
                let matches = projects.filter {
                    !$0.cwd.isEmpty
                        && $0.cwd.trimmingCharacters(in: .whitespacesAndNewlines) == normalizedCwd
                }
                project = matches.count == 1 ? matches[0] : nil
            } else {
                project = nil
            }

            guard let project,
                  conversation.workspaceID != project.id
                    || conversation.workspaceCWD != project.cwd
            else { continue }
            conversations.update(conversation.id) {
                $0.projectID = project.id
                $0.cwd = project.cwd
            }
            repaired += 1
        }
        return repaired
    }

    // MARK: - Persistence

    private var appSupportBase: URL {
        // Dev isolation: dev.sh sets MECHANICIAN_SUPPORT_DIR so the dev build never shares the stable
        // app's store (both carry bundle id ai.mechanician.app). Mirrors ConversationStore exactly.
        let base = appSupportBaseOverride ?? MechanicianEnvironment.currentSupportRoot()
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    /// The app-private Workspace record authority. `Project` remains the tolerant legacy Swift/JSON
    /// type until the `.mecha` cutover, but new storage paths use the product noun now.
    private var storeDir: URL {
        let dir = appSupportBase.appendingPathComponent("workspaces", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Older builds and an already-running ambient daemon still resolve `<support>/projects`.
    /// After the one-time directory move this path is a relative symlink to `workspaces`, so both
    /// generations reach the same bytes rather than creating a compatibility copy/second authority.
    private var legacyStoreDir: URL {
        appSupportBase.appendingPathComponent("projects", isDirectory: true)
    }

    private let saveQueue = DispatchQueue(label: "ai.mechanician.project-io", qos: .utility)
    private var homeSettingsURL: URL {
        appSupportBase.appendingPathComponent("home-workspace.json", isDirectory: false)
    }

    private func save(_ p: Project) {
        let snapshot = p
        if selectedSQLiteAuthority {
            guard let authorityRepository else {
                finishSave(
                    projectID: snapshot.id,
                    failure: ProjectStorePersistenceError.repositoryUnavailable(
                        authorityRepositoryOpenFailure
                            ?? "The SQLite authority repository is unavailable."))
                return
            }
            let projection = workspaceProjectionPayload()
            let projectionURL = workspaceProjectionURL
            saveQueue.async { [weak self] in
                let failure = Self.retryingDiskOperation {
#if DEBUG
                    try Self.persistenceWriteTestHook?()
#endif
                    try authorityRepository.commit(workspace: snapshot)
                }
                if failure == nil {
                    Self.writeWorkspaceProjection(projection, to: projectionURL)
                }
                Task { @MainActor [weak self] in
                    self?.finishSave(projectID: snapshot.id, failure: failure)
                }
            }
            return
        }
        let url = storeDir.appendingPathComponent("\(p.id.uuidString).json")
        saveQueue.async { [weak self] in
            let failure = Self.retryingDiskOperation {
                let data = try Self.makeSidecarEncoder().encode(snapshot)
                // .atomic so a crash mid-write can't truncate a project file — a corrupt project
                // makes a whole workspace vanish from the launcher and dangles its conversations'
                // projectID.
                try data.write(to: url, options: .atomic)
            }
            Task { @MainActor [weak self] in
                self?.finishSave(projectID: snapshot.id, failure: failure)
            }
        }
    }

    private func saveHomeSettings(_ settings: HomeWorkspaceSettings) {
        let snapshot = settings
        if selectedSQLiteAuthority {
            guard let authorityRepository else {
                finishSave(
                    projectID: nil,
                    failure: ProjectStorePersistenceError.repositoryUnavailable(
                        authorityRepositoryOpenFailure
                            ?? "The SQLite authority repository is unavailable."))
                return
            }
            let projection = workspaceProjectionPayload()
            let projectionURL = workspaceProjectionURL
            saveQueue.async { [weak self] in
                let failure = Self.retryingDiskOperation {
                    _ = try authorityRepository.commit(home: snapshot)
                }
                if failure == nil {
                    Self.writeWorkspaceProjection(projection, to: projectionURL)
                }
                Task { @MainActor [weak self] in
                    self?.finishSave(projectID: nil, failure: failure)
                }
            }
            return
        }
        let url = homeSettingsURL
        saveQueue.async { [weak self] in
            let failure = Self.retryingDiskOperation {
                let data = try Self.makeSidecarEncoder().encode(snapshot)
                try data.write(to: url, options: .atomic)
            }
            Task { @MainActor [weak self] in
                self?.finishSave(projectID: nil, failure: failure)
            }
        }
    }

    nonisolated private static func makeSidecarEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    /// Retry short-lived filesystem failures; sleeps run inline on the serial save queue so the
    /// termination flush waits for every retry. (Same pattern as `ArtifactStore`.)
    nonisolated private static func retryingDiskOperation(_ operation: () throws -> Void) -> Error? {
        var lastError: Error?
        for attempt in 0..<3 {
            do {
                try operation()
                return nil
            } catch {
                lastError = error
                if attempt < 2 { Thread.sleep(forTimeInterval: 0.08 * Double(attempt + 1)) }
            }
        }
        return lastError
    }

    /// `projectID == nil` means the Home settings file.
    private func finishSave(projectID: UUID?, failure: Error?) {
        if let failure {
            if let projectID { failedProjectIDs.insert(projectID) } else { homeSettingsSaveFailed = true }
            lastPersistenceFailureDetail = failure.localizedDescription
        } else {
            if let projectID { failedProjectIDs.remove(projectID) } else { homeSettingsSaveFailed = false }
        }
        refreshPersistenceError()
    }

    /// The scheduler daemon resolves a task's working directory and Workspace Instructions
    /// immediately before every run, and it cannot open `library.db`. It used to read
    /// `workspaces/` and `home-workspace.json`; those stop being written once SQLite owns the
    /// library, so a Workspace created after the cutover resolved to nothing and its task ran from
    /// the user's home directory.
    ///
    /// This is the contract `AmbientStore` already uses for `tasks.json`: a disposable read
    /// projection the app writes only after the authoritative commit, that nothing in the app reads
    /// back, and that may be deleted at any time. It carries no transcript and no secret — only the
    /// three facts a scheduled run needs.
    /// Captured on the main actor with the value the caller is about to commit, then written on the
    /// save queue immediately after that commit succeeds. Writing it in the same queued operation
    /// keeps the projection strictly behind the database and makes `flushSaves()` a real barrier.
    private func workspaceProjectionPayload() -> WorkspaceProjection? {
        guard selectedSQLiteAuthority else { return nil }
        return WorkspaceProjection(
            home: .init(instructions: homeSettings.instructions),
            workspaces: projects.map {
                .init(id: $0.id, cwd: $0.cwd, instructions: $0.instructions)
            })
    }

    nonisolated private static func writeWorkspaceProjection(
        _ payload: WorkspaceProjection?,
        to destination: URL
    ) {
        guard let payload else { return }
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try FileManager.default.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true)
            try encoder.encode(payload).write(to: destination, options: .atomic)
        } catch {
            // A stale projection only costs the scheduler its newest Workspace edits, and the next
            // launch republishes it. It must never fail a save the database already committed.
            NSLog(
                "[persistence] workspace projection could not be written: %@",
                error.localizedDescription)
        }
    }

    /// Beside `tasks.json`, and named by the same rule: the daemon is handed this directory as
    /// `MECHANICIAN_AMBIENT_DIR`, and it is physically separate from the frozen Legacy sources.
    private var workspaceProjectionURL: URL {
        appSupportBase
            .appendingPathComponent("ambient-projection", isDirectory: true)
            .appendingPathComponent("workspaces.json", isDirectory: false)
    }

    private struct WorkspaceProjection: Encodable, Sendable {
        struct Home: Encodable, Sendable {
            let instructions: String
        }

        struct Workspace: Encodable, Sendable {
            let id: UUID
            let cwd: String
            let instructions: String
        }

        let home: Home
        let workspaces: [Workspace]
    }

    private func finishDelete(projectID: UUID, failure: Error?) {
        if let failure {
            failedProjectDeletes.insert(projectID)
            lastPersistenceFailureDetail = failure.localizedDescription
        } else {
            failedProjectDeletes.remove(projectID)
            failedProjectIDs.remove(projectID)
        }
        refreshPersistenceError()
    }

    private func refreshPersistenceError() {
        let count = failedProjectIDs.count + failedProjectDeletes.count
            + (homeSettingsSaveFailed ? 1 : 0)
        guard count > 0 else {
            persistenceError = nil
            lastPersistenceFailureDetail = nil
            return
        }
        // No error detail in the sentence: see the note in `ConversationStore.refreshPersistenceError`.
        let subject = count == 1 ? "a workspace change" : "\(count) workspace changes"
        persistenceError =
            "Mechanician couldn’t save \(subject). The change is still here but not yet on disk, "
            + "so don’t quit until this clears."
    }

    /// Re-save the newest in-memory state for every failed write. A project removed since its
    /// failed save is dropped, not resurrected.
    func retryFailedSaves() {
        for id in Array(failedProjectIDs) {
            if let current = projects.first(where: { $0.id == id }) {
                save(current)
            } else {
                failedProjectIDs.remove(id)
            }
        }
        for id in Array(failedProjectDeletes) { deleteFile(id) }
        if homeSettingsSaveFailed { saveHomeSettings(homeSettings) }
        refreshPersistenceError()
    }

    private func deleteFile(_ id: UUID) {
        if selectedSQLiteAuthority {
            guard let authorityRepository else {
                finishDelete(
                    projectID: id,
                    failure: ProjectStorePersistenceError.repositoryUnavailable(
                        authorityRepositoryOpenFailure
                            ?? "The SQLite authority repository is unavailable."))
                return
            }
            // `remove(_:)` has already dropped it from `projects`, so this payload is the set the
            // scheduler must resolve against from here on.
            let projection = workspaceProjectionPayload()
            let projectionURL = workspaceProjectionURL
            saveQueue.async { [weak self] in
                let failure = Self.retryingDiskOperation {
                    _ = try authorityRepository.deleteWorkspace(id: id)
                }
                if failure == nil {
                    Self.writeWorkspaceProjection(projection, to: projectionURL)
                }
                Task { @MainActor [weak self] in
                    self?.finishDelete(projectID: id, failure: failure)
                }
            }
            return
        }
        let url = storeDir.appendingPathComponent("\(id.uuidString).json")
        saveQueue.async {
            try? FileManager.default.removeItem(at: url)
        }
    }

    /// Move an undecodable project file aside (non-`.json` suffix so it is never re-read) rather
    /// than silently skipping it, so a truncated/incompatible file is recoverable, not lost.
    private func quarantineCorruptFile(_ url: URL) {
        let stamp = Int(Date().timeIntervalSince1970)
        let dest = url.appendingPathExtension("corrupt-\(stamp)")
        saveQueue.async {
            let fm = FileManager.default
            let final = fm.fileExists(atPath: dest.path)
                ? url.appendingPathExtension("corrupt-\(stamp)-\(UUID().uuidString.prefix(4))")
                : dest
            try? fm.moveItem(at: url, to: final)
        }
    }

    /// Block until every queued write/delete completes — called on app termination.
    func flushSaves() { saveQueue.sync {} }

    /// Before reserved Workspaces became closed identities, their ordinary Workspace rows could be
    /// renamed, instructed, decorated, or attached to a folder. Both storage authorities load rows
    /// directly rather than through `upsert`, so repair them at that common boundary and re-save
    /// only records that actually drifted. Runtime provider preference and historical timestamps
    /// survive through `canonicalProject(preservingRuntimePreferenceFrom:)`.
    private static func canonicalizeLoadedReservedProjects(
        _ loaded: [Project]
    ) -> (projects: [Project], repairs: [Project]) {
        var repairs: [Project] = []
        let projects = loaded.map { project in
            guard let reserved = ReservedWorkspace.workspace(for: project.id),
                  !reserved.hasCanonicalIdentity(project) else { return project }
            let repaired = reserved.canonicalProject(preservingRuntimePreferenceFrom: project)
            repairs.append(repaired)
            return repaired
        }
        return (projects, repairs)
    }

    private func load() {
        if selectedSQLiteAuthority {
            guard let authorityRepository else {
                persistenceError = authorityRepositoryOpenFailure
                    ?? "The SQLite authority repository is unavailable."
                return
            }
            do {
                let inventory = try authorityRepository.workspaceInventory()
                homeSettings = inventory.home
                let loaded = Self.canonicalizeLoadedReservedProjects(inventory.workspaces)
                projects = loaded.projects.sorted(by: Self.order)
                for repaired in loaded.repairs { save(repaired) }
                // Republish at launch, so the daemon has a current projection on the first run
                // after the cutover, when nothing has been edited yet to trigger a save — and so a
                // projection lost to a crash between commit and write heals without an edit.
                let projection = workspaceProjectionPayload()
                let projectionURL = workspaceProjectionURL
                saveQueue.async { Self.writeWorkspaceProjection(projection, to: projectionURL) }
            } catch {
                NSLog("[persistence] workspace library could not be loaded: %@",
                      error.localizedDescription)
                persistenceError = "Mechanician couldn’t open your workspaces. Nothing on disk "
                    + "was changed. Quit and reopen Mechanician to try again."
            }
            return
        }
        prepareWorkspaceStorage()
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let homeURL = homeSettingsURL
        if let data = try? Data(contentsOf: homeURL) {
            if let settings = try? decoder.decode(HomeWorkspaceSettings.self, from: data) {
                homeSettings = settings
            } else {
                quarantineCorruptFile(homeURL)
            }
        }

        let files = (try? FileManager.default.contentsOfDirectory(
            at: storeDir, includingPropertiesForKeys: nil)) ?? []
        var loaded: [Project] = []
        for file in files
        where file.lastPathComponent.hasPrefix(".workspace-")
            && file.pathExtension == "preparing" {
            saveQueue.async { try? FileManager.default.removeItem(at: file) }
        }
        for f in files where f.pathExtension == "json" {
            guard let data = try? Data(contentsOf: f) else { continue }
            if let p = try? decoder.decode(Project.self, from: data) {
                loaded.append(p)
            } else {
                quarantineCorruptFile(f)   // preserve, don't silently drop a workspace
            }
        }
        let normalized = Self.canonicalizeLoadedReservedProjects(loaded)
        projects = normalized.projects.sorted(by: Self.order)
        for repaired in normalized.repairs { save(repaired) }
    }

    /// Move the legacy directory before the first load. A same-volume directory rename is atomic,
    /// leaves every Workspace byte untouched, and is idempotent across relaunch. The relative alias
    /// preserves downgrade and already-running-daemon behavior without maintaining duplicate files.
    ///
    /// If a crash/old build leaves both real directories, converge missing or byte-identical files.
    /// A divergent legacy file is preserved under a non-JSON conflict suffix in the canonical
    /// directory before the legacy directory becomes the alias; it is never newest-wins overwritten.
    private func prepareWorkspaceStorage() {
        let fm = FileManager.default
        let canonical = appSupportBase.appendingPathComponent("workspaces", isDirectory: true)
        let legacy = legacyStoreDir
        let legacyLinkDestination = try? fm.destinationOfSymbolicLink(atPath: legacy.path)
        var canonicalExists = fm.fileExists(atPath: canonical.path)

        if !canonicalExists,
           legacyLinkDestination == nil,
           fm.fileExists(atPath: legacy.path) {
            do {
                try fm.moveItem(at: legacy, to: canonical)
                canonicalExists = true
            } catch {
                NSLog("Mechanician could not atomically migrate projects/ to workspaces/: %@",
                      error.localizedDescription)
            }
        }

        if !canonicalExists {
            do {
                try fm.createDirectory(at: canonical, withIntermediateDirectories: true)
                canonicalExists = true
            } catch {
                NSLog("Mechanician could not create workspaces/: %@", error.localizedDescription)
                return
            }
        }

        // Interrupted migration or a downgrade launched during the rename/link window.
        if legacyLinkDestination == nil, fm.fileExists(atPath: legacy.path) {
            convergeLegacyWorkspaceDirectory(from: legacy, into: canonical)
        }

        if let destination = try? fm.destinationOfSymbolicLink(atPath: legacy.path) {
            let resolved = URL(
                fileURLWithPath: destination,
                relativeTo: legacy.deletingLastPathComponent()).standardizedFileURL
            if resolved.path != canonical.standardizedFileURL.path {
                NSLog("Mechanician preserved an unexpected projects symlink at %@", legacy.path)
            }
            return
        }

        guard !fm.fileExists(atPath: legacy.path) else {
            NSLog("Mechanician preserved a non-empty legacy projects directory at %@", legacy.path)
            return
        }
        do {
            try fm.createSymbolicLink(atPath: legacy.path, withDestinationPath: "workspaces")
        } catch {
            // The canonical directory is already valid; retry alias creation on the next launch.
            NSLog("Mechanician could not create the projects compatibility alias: %@",
                  error.localizedDescription)
        }
    }

    private func convergeLegacyWorkspaceDirectory(from legacy: URL, into canonical: URL) {
        let fm = FileManager.default
        let files = (try? fm.contentsOfDirectory(
            at: legacy,
            includingPropertiesForKeys: nil)) ?? []

        for source in files {
            let destination = canonical.appendingPathComponent(source.lastPathComponent)
            guard fm.fileExists(atPath: destination.path) else {
                do {
                    try fm.moveItem(at: source, to: destination)
                } catch {
                    NSLog("Mechanician preserved an unmigrated Workspace file %@: %@",
                          source.path, error.localizedDescription)
                }
                continue
            }

            let sourceData = try? Data(contentsOf: source, options: .mappedIfSafe)
            let destinationData = try? Data(contentsOf: destination, options: .mappedIfSafe)
            if sourceData != nil, sourceData == destinationData {
                try? fm.removeItem(at: source)
                continue
            }

            let conflict = canonical.appendingPathComponent(
                "\(source.lastPathComponent).legacy-conflict-\(UUID().uuidString)")
            do {
                try fm.moveItem(at: source, to: conflict)
                NSLog("Mechanician preserved a divergent legacy Workspace file at %@", conflict.path)
            } catch {
                NSLog("Mechanician preserved a divergent Workspace file in projects/: %@",
                      error.localizedDescription)
            }
        }

        let remaining = (try? fm.contentsOfDirectory(atPath: legacy.path)) ?? []
        if remaining.isEmpty { try? fm.removeItem(at: legacy) }
    }
}

/// Re-filing a conversation into a workspace.
///
/// A conversation adopts the workspace's id AND its working directory together: the id is what the
/// sidebar files it under, and the cwd is what its tools operate in. Moving one without the other
/// leaves a conversation listed in a workspace while still acting in the previous folder.
/// Takes the destination as a value rather than an id so the rule itself stays independent of the
/// shared `ProjectStore` and its persistence.
enum WorkspaceAdoption {
    /// Existing-destination moves are prepared one at a time. Their commit remains one synchronous
    /// MainActor transaction, but every potentially affected Conversation is decoded and pinned
    /// before that transaction begins. Legacy New Workspace/folder paths consult the same gate so
    /// they cannot interleave a second ownership graph while preparation is suspended.
    @MainActor private static var activePlacementLease: WorkspacePlacementLease?

    /// Reserved Workspaces select closed provider authority. Moving a Conversation is a filing
    /// operation, not consent to replace its tool profile, so every member of a batch must stay on
    /// the same side of the exact reserved identity boundary. Ordinary Home/Project moves all have
    /// a nil reserved identity and remain freely interchangeable.
    static func preservesReservedConversationIdentity(
        _ conversations: [Conversation],
        into destination: WorkspaceDestination
    ) -> Bool {
        let destinationID = ReservedWorkspace.workspace(for: destination.projectID)?.id
        return conversations.allSatisfy {
            ReservedWorkspace.workspace(for: $0.projectID)?.id == destinationID
        }
    }

    @MainActor
    static var isPlacementOperationInProgress: Bool { activePlacementLease != nil }

    /// One process-wide lease for every operation that rewrites Workspace placement. Hydration can
    /// yield to another window, so a per-window Undo busy bit is not sufficient.
    @MainActor
    static func beginPlacementOperation() -> WorkspacePlacementLease? {
        guard activePlacementLease == nil else { return nil }
        let lease = WorkspacePlacementLease(id: UUID())
        activePlacementLease = lease
        return lease
    }

    @discardableResult
    @MainActor
    static func endPlacementOperation(_ lease: WorkspacePlacementLease) -> Bool {
        guard activePlacementLease == lease else { return false }
        activePlacementLease = nil
        return true
    }

    private enum DestinationResolution {
        case destination(WorkspaceDestination)
        case failure(WorkspaceAdoptionResult)
    }

    private struct PreparedDestinationCommit {
        let resolve: @MainActor () -> DestinationResolution
        let finalize: @MainActor (WorkspaceAdoptionResult) -> Void
    }

    /// Owns the staged sidecar and request-specific destination mutation for one launcher commit.
    /// Hydration failures only discard staging. At the commit edge, a same-folder Workspace is
    /// re-resolved and reused; otherwise the staged sidecar publishes before placement changes.
    @MainActor
    private final class NewWorkspaceDestinationCommit {
        let draft: Project
        let pending: PendingWorkspaceAdoption
        let prepared: PreparedWorkspaceProject
        let projects: ProjectStore
        private(set) var projectForCompletion: Project?
        private var publishedNewProject = false

        init(
            draft: Project,
            pending: PendingWorkspaceAdoption,
            prepared: PreparedWorkspaceProject,
            projects: ProjectStore
        ) {
            self.draft = draft
            self.pending = pending
            self.prepared = prepared
            self.projects = projects
        }

        func resolve() -> DestinationResolution {
            guard projects.pendingWorkspaceAdoption == pending else {
                projects.discardPreparedWorkspaceProject(prepared)
                return .failure(.requestChanged)
            }
            if !draft.cwd.isEmpty,
               let existing = projects.projects.first(where: { $0.cwd == draft.cwd }) {
                projects.discardPreparedWorkspaceProject(prepared)
                projectForCompletion = existing
                return .destination(.project(existing))
            }
            switch projects.publishPreparedWorkspaceProject(prepared) {
            case .success(let project):
                publishedNewProject = true
                projectForCompletion = project
                return .destination(.project(project))
            case .failure(let failure):
                projects.discardPreparedWorkspaceProject(prepared)
                return .failure(.workspacePersistenceFailed(failure.message))
            }
        }

        func finalize(_ result: WorkspaceAdoptionResult) {
            guard result.succeeded else {
                if publishedNewProject {
                    projects.rollbackPublishedWorkspaceProject(prepared)
                } else {
                    projects.discardPreparedWorkspaceProject(prepared)
                }
                projectForCompletion = nil
                return
            }
            _ = projects.takeWorkspaceAdoption(pending.id)
        }

        var destinationCommit: PreparedDestinationCommit {
            PreparedDestinationCommit(
                resolve: { [self] in resolve() },
                finalize: { [self] result in finalize(result) })
        }
    }

    /// Exact provenance always wins. The only safe legacy inference is a nil-provenance interactive
    /// artifact embedded in the conversation itself: older agent-created snapshots predate
    /// `conversationID`. Standalone user/ambient artifacts and another conversation's artifact are
    /// references, not followers, even when their durable record is temporarily unavailable.
    private static func nestedArtifact(
        _ artifact: Artifact,
        follows conversationID: UUID
    ) -> Bool {
        artifact.conversationID == conversationID
            || (artifact.conversationID == nil && artifact.origin == "interactive")
    }

    /// Validate a conversation batch before a New Workspace editor persists its destination. A
    /// non-nil result is the blocking failure; nil means the caller may create the destination and
    /// immediately call `adopt`. This keeps a busy batch from consuming its request and leaving an
    /// empty workspace behind.
    @MainActor
    static func preflight(
        conversations ids: Set<UUID>,
        conversations explicitConversations: ConversationStore? = nil,
        synchronizeLiveState explicitLiveSync: Bool? = nil,
        ignoringPreparation: Bool = false
    ) -> WorkspaceAdoptionResult? {
        if isPlacementOperationInProgress, !ignoringPreparation { return .moveInProgress }
        let conversations = explicitConversations ?? .shared
        guard !ids.isEmpty,
              ids.allSatisfy({ conversations.contains($0) })
        else { return .unavailable }

        let liveSync = explicitLiveSync ?? (conversations === ConversationStore.shared)
        if liveSync,
           ids.contains(where: { AgentBridge.hasBlockingWorkspaceMoveWork(for: $0) }) {
            return .busy
        }
        return nil
    }

    /// Validate an artifact batch before the New Workspace editor persists its destination. Artifact
    /// menu requests can outlive the source row (for example another window deletes it while the
    /// editor is open); the destination must not be created or renamed for a move that can no longer
    /// succeed.
    @MainActor
    static func preflight(
        artifacts ids: Set<UUID>,
        artifactStore explicitArtifactStore: ArtifactStore? = nil,
        ignoringPreparation: Bool = false
    ) -> WorkspaceAdoptionResult? {
        if isPlacementOperationInProgress, !ignoringPreparation { return .moveInProgress }
        let artifacts = explicitArtifactStore ?? .shared
        guard !ids.isEmpty,
              ids.allSatisfy({ id in
                artifacts.artifacts.contains { $0.uuid == id }
              }) else { return .unavailable }
        return nil
    }

    /// Create-or-reuse a launcher draft and adopt its exact pending target without ever decoding a
    /// full Conversation on the main actor. The destination file is staged first, then published
    /// only after the complete impact set is pinned and the request still matches. Completion runs
    /// after claims and the identity-bearing placement lease have both been released.
    @discardableResult
    @MainActor
    static func adoptAfterAcquiring(
        _ pending: PendingWorkspaceAdoption,
        intoNewWorkspace draft: Project,
        projects: ProjectStore,
        conversations explicitConversations: ConversationStore? = nil,
        artifactStore explicitArtifactStore: ArtifactStore? = nil,
        synchronizeLiveState explicitLiveSync: Bool? = nil,
        undoManager: UndoManager? = nil,
        completion: @escaping @MainActor (WorkspaceAdoptionResult, Project?) -> Void
    ) -> Bool {
        guard projects.pendingWorkspaceAdoption == pending else {
            completion(.requestChanged, nil)
            return false
        }
        let conversations = explicitConversations ?? .shared
        let artifactStore = explicitArtifactStore ?? .shared
        let liveSync = explicitLiveSync ?? (conversations === ConversationStore.shared)
        let failure: WorkspaceAdoptionResult?
        switch pending.target {
        case .conversations(let ids):
            failure = preflight(
                conversations: ids,
                conversations: conversations,
                synchronizeLiveState: liveSync)
        case .artifacts(let ids):
            failure = preflight(artifacts: ids, artifactStore: artifactStore)
        }
        if let failure {
            completion(failure, nil)
            return false
        }
        guard let lease = beginPlacementOperation() else {
            completion(.moveInProgress, nil)
            return false
        }

        projects.prepareWorkspaceProject(draft) { preparation in
            switch preparation {
            case .failure(let failure):
                let inert = PreparedDestinationCommit(
                    resolve: { .failure(.workspacePersistenceFailed(failure.message)) },
                    finalize: { _ in })
                finishPreparedMove(
                    .workspacePersistenceFailed(failure.message),
                    lease: lease,
                    destinationCommit: inert
                ) { result in completion(result, nil) }
            case .success(let prepared):
                guard projects.pendingWorkspaceAdoption == pending else {
                    projects.discardPreparedWorkspaceProject(prepared)
                    let inert = PreparedDestinationCommit(
                        resolve: { .failure(.requestChanged) },
                        finalize: { _ in })
                    finishPreparedMove(
                        .requestChanged,
                        lease: lease,
                        destinationCommit: inert
                    ) { result in completion(result, nil) }
                    return
                }
                let context = NewWorkspaceDestinationCommit(
                    draft: draft,
                    pending: pending,
                    prepared: prepared,
                    projects: projects)
                let destinationCommit = context.destinationCommit
                let finish: @MainActor (WorkspaceAdoptionResult) -> Void = { result in
                    completion(result, context.projectForCompletion)
                }

                switch pending.target {
                case .conversations(let ids):
                    conversations.withAcquiredConversations(ids) { result in
                        guard case .success = result else {
                            guard case .failure(let error) = result else { return }
                            finishPreparedMove(
                                .bindingUnavailable(error),
                                lease: lease,
                                destinationCommit: destinationCommit,
                                completion: finish)
                            return
                        }
                        continueConversationPreparation(
                            ids: ids,
                            requiredIDs: ids,
                            lease: lease,
                            destinationCommit: destinationCommit,
                            conversations: conversations,
                            artifactStore: artifactStore,
                            synchronizeLiveState: liveSync,
                            receivingBridgeID: nil,
                            undoManager: undoManager,
                            completion: finish)
                    }
                case .artifacts(let ids):
                    let acquisitionIDs = conversations.conversationIDs(
                        referencingArtifactIDs: ids)
                    conversations.withAcquiredConversations(acquisitionIDs) { result in
                        guard case .success = result else {
                            guard case .failure(let error) = result else { return }
                            finishPreparedMove(
                                .bindingUnavailable(error),
                                lease: lease,
                                destinationCommit: destinationCommit,
                                completion: finish)
                            return
                        }
                        continueArtifactPreparation(
                            ids: ids,
                            requiredIDs: acquisitionIDs,
                            lease: lease,
                            destinationCommit: destinationCommit,
                            conversations: conversations,
                            artifactStore: artifactStore,
                            synchronizeLiveState: liveSync,
                            undoManager: undoManager,
                            completion: finish)
                    }
                }
            }
        }
        return true
    }

    /// Existing-destination UI moves use this entry point so an evicted Conversation sidecar is
    /// never decoded on the main actor. Preparation grows a reference-counted residency claim until
    /// the complete artifact/reference impact set is stable. Only then does the synchronous commit
    /// coordinator below run, preserving its ownership, live-window and undo semantics.
    @discardableResult
    @MainActor
    static func adoptAfterAcquiring(
        conversations ids: Set<UUID>,
        into destination: WorkspaceDestination,
        conversations explicitConversations: ConversationStore? = nil,
        artifactStore explicitArtifactStore: ArtifactStore? = nil,
        projectStore explicitProjectStore: ProjectStore? = nil,
        synchronizeLiveState explicitLiveSync: Bool? = nil,
        receivingBridge explicitReceivingBridge: AgentBridge? = nil,
        undoManager: UndoManager? = nil,
        completion: @escaping @MainActor (WorkspaceAdoptionResult) -> Void
    ) -> Bool {
        let conversations = explicitConversations ?? .shared
        let liveSync = explicitLiveSync ?? (conversations === ConversationStore.shared)
        if let failure = preflight(
            conversations: ids,
            conversations: conversations,
            synchronizeLiveState: liveSync
        ) {
            completion(failure)
            return false
        }
        guard let lease = beginPlacementOperation() else {
            completion(.moveInProgress)
            return false
        }

        let artifactStore = explicitArtifactStore
            ?? (conversations === ConversationStore.shared ? ArtifactStore.shared : nil)
        let projectStore = explicitProjectStore
            ?? (conversations === ConversationStore.shared ? ProjectStore.shared : nil)
        let receivingBridgeID = explicitReceivingBridge?.bridgeID
        let destinationCommit = PreparedDestinationCommit(
            resolve: {
                guard let destination = resolvedDestination(
                    destination,
                    projectStore: projectStore)
                else { return .failure(.unavailable) }
                return .destination(destination)
            },
            finalize: { _ in })

        conversations.withAcquiredConversations(ids) { result in
            guard case .success = result else {
                guard case .failure(let error) = result else { return }
                finishPreparedMove(
                    .bindingUnavailable(error),
                    lease: lease,
                    destinationCommit: destinationCommit,
                    completion: completion)
                return
            }
            continueConversationPreparation(
                ids: ids,
                requiredIDs: ids,
                lease: lease,
                destinationCommit: destinationCommit,
                conversations: conversations,
                artifactStore: artifactStore,
                synchronizeLiveState: liveSync,
                receivingBridgeID: receivingBridgeID,
                undoManager: undoManager,
                completion: completion)
        }
        return true
    }

    /// Direct artifact filing also rewrites every same-UUID nested Conversation snapshot. Acquire
    /// and temporarily pin those exact holders first; a missing member aborts before the standalone
    /// artifact changes, preserving the existing all-or-nothing contract.
    @discardableResult
    @MainActor
    static func adoptAfterAcquiring(
        artifacts ids: Set<UUID>,
        into destination: WorkspaceDestination,
        conversations explicitConversations: ConversationStore? = nil,
        artifactStore explicitArtifactStore: ArtifactStore? = nil,
        projectStore explicitProjectStore: ProjectStore? = nil,
        synchronizeLiveState: Bool = true,
        undoManager: UndoManager? = nil,
        completion: @escaping @MainActor (WorkspaceAdoptionResult) -> Void
    ) -> Bool {
        let conversations = explicitConversations ?? .shared
        let artifactStore = explicitArtifactStore ?? .shared
        if let failure = preflight(artifacts: ids, artifactStore: artifactStore) {
            completion(failure)
            return false
        }
        guard let lease = beginPlacementOperation() else {
            completion(.moveInProgress)
            return false
        }
        let projectStore = explicitProjectStore
            ?? (conversations === ConversationStore.shared ? ProjectStore.shared : nil)
        let destinationCommit = PreparedDestinationCommit(
            resolve: {
                guard let destination = resolvedDestination(
                    destination,
                    projectStore: projectStore)
                else { return .failure(.unavailable) }
                return .destination(destination)
            },
            finalize: { _ in })
        let acquisitionIDs = conversations.conversationIDs(referencingArtifactIDs: ids)
        conversations.withAcquiredConversations(acquisitionIDs) { result in
            guard case .success = result else {
                guard case .failure(let error) = result else { return }
                finishPreparedMove(
                    .bindingUnavailable(error),
                    lease: lease,
                    destinationCommit: destinationCommit,
                    completion: completion)
                return
            }
            continueArtifactPreparation(
                ids: ids,
                requiredIDs: acquisitionIDs,
                lease: lease,
                destinationCommit: destinationCommit,
                conversations: conversations,
                artifactStore: artifactStore,
                synchronizeLiveState: synchronizeLiveState,
                undoManager: undoManager,
                completion: completion)
        }
        return true
    }

    /// Change one existing Workspace folder without decoding any Conversation on the main actor.
    /// The operation waits for the authoritative inventory, acquires and pins the complete member +
    /// artifact-holder graph, then revalidates the original Project binding immediately before one
    /// synchronous in-memory commit. A required hydration failure aborts before any store mutates;
    /// already-resident records remain the live authority and retain the stores' normal retry path.
    @discardableResult
    @MainActor
    static func reassignWorkspaceFolderAfterAcquiring(
        _ request: WorkspaceFolderReassignmentRequest,
        projects: ProjectStore,
        conversations explicitConversations: ConversationStore? = nil,
        artifactStore explicitArtifactStore: ArtifactStore? = nil,
        synchronizeLiveState explicitLiveSync: Bool? = nil,
        completion: @escaping @MainActor (WorkspaceFolderReassignmentResult) -> Void
    ) -> Bool {
        let conversations = explicitConversations ?? .shared
        let artifactStore = explicitArtifactStore ?? .shared
        let liveSync = explicitLiveSync ?? (conversations === ConversationStore.shared)

        guard !ReservedWorkspace.owns(request.projectID) else {
            completion(.unavailable)
            return false
        }

        // Before readiness, summaries can be a disposable SQLite projection while the artifact-id
        // inventory is still incomplete. Wait for the authoritative scan rather than treating the
        // pre-ready list as a placement graph.
        guard conversations.isReady else {
            conversations.whenReady {
                _ = reassignWorkspaceFolderAfterAcquiring(
                    request,
                    projects: projects,
                    conversations: conversations,
                    artifactStore: artifactStore,
                    synchronizeLiveState: liveSync,
                    completion: completion)
            }
            return true
        }

        switch validateWorkspaceFolderRequest(request, projects: projects) {
        case .failure(let result):
            completion(result)
            return false
        case .success(let project):
            if project.cwd == request.destinationCwd {
                completion(.unchanged)
                return false
            }
        }
        let memberIDs = workspaceFolderMemberIDs(
            projectID: request.projectID,
            projects: projects,
            conversations: conversations)
        if liveSync,
           memberIDs.contains(where: { AgentBridge.hasBlockingWorkspaceMoveWork(for: $0) }) {
            completion(.activeWork)
            return false
        }
        guard let lease = beginPlacementOperation() else {
            completion(.moveInProgress)
            return false
        }

        conversations.withAcquiredConversations(memberIDs) { result in
            guard case .success = result else {
                guard case .failure(let error) = result else { return }
                finishWorkspaceFolderReassignment(
                    .bindingUnavailable(error),
                    lease: lease,
                    completion: completion)
                return
            }
            continueWorkspaceFolderReassignment(
                request,
                requiredIDs: memberIDs,
                lease: lease,
                projects: projects,
                conversations: conversations,
                artifactStore: artifactStore,
                synchronizeLiveState: liveSync,
                completion: completion)
        }
        return true
    }

    @MainActor
    private static func continueWorkspaceFolderReassignment(
        _ request: WorkspaceFolderReassignmentRequest,
        requiredIDs: Set<UUID>,
        lease: WorkspacePlacementLease,
        projects: ProjectStore,
        conversations: ConversationStore,
        artifactStore: ArtifactStore,
        synchronizeLiveState: Bool,
        completion: @escaping @MainActor (WorkspaceFolderReassignmentResult) -> Void
    ) {
        guard activePlacementLease == lease else {
            finishWorkspaceFolderReassignment(
                .sourceChanged, lease: lease, completion: completion)
            return
        }
        switch validateWorkspaceFolderRequest(request, projects: projects) {
        case .failure(let result):
            finishWorkspaceFolderReassignment(result, lease: lease, completion: completion)
            return
        case .success:
            break
        }

        // Membership itself can change while an earlier sidecar is loading. Grow the claim before
        // reading any member's nested artifacts; records that left the Workspace may remain pinned
        // harmlessly, but no newly joined member may be missed.
        let memberIDs = workspaceFolderMemberIDs(
            projectID: request.projectID,
            projects: projects,
            conversations: conversations)
        let memberExpandedIDs = requiredIDs.union(memberIDs)
        if memberExpandedIDs != requiredIDs {
            acquireExpandedWorkspaceFolderGraph(
                request,
                ids: memberExpandedIDs,
                lease: lease,
                projects: projects,
                conversations: conversations,
                artifactStore: artifactStore,
                synchronizeLiveState: synchronizeLiveState,
                completion: completion)
            return
        }
        guard memberIDs.allSatisfy({ conversations.residentConversation($0) != nil }) else {
            finishWorkspaceFolderReassignment(
                .unavailable, lease: lease, completion: completion)
            return
        }

        let preliminary = workspaceFolderImpact(
            projectID: request.projectID,
            previousCwd: request.expectedCwd,
            memberIDs: memberIDs,
            conversations: conversations,
            artifactStore: artifactStore)
        let preliminaryExpandedIDs = requiredIDs.union(preliminary.holderIDs)
        if preliminaryExpandedIDs != requiredIDs {
            acquireExpandedWorkspaceFolderGraph(
                request,
                ids: preliminaryExpandedIDs,
                lease: lease,
                projects: projects,
                conversations: conversations,
                artifactStore: artifactStore,
                synchronizeLiveState: synchronizeLiveState,
                completion: completion)
            return
        }
        let preliminarySourceBridges = synchronizeLiveState
            ? liveWorkspaceFolderSourceBridges(
                projectID: request.projectID,
                previousCwd: request.expectedCwd,
                memberIDs: memberIDs)
            : []
        let preliminaryActiveIDs = preliminary.impactIDs.union(
            preliminarySourceBridges.compactMap(\.currentID))
        if synchronizeLiveState,
           preliminaryActiveIDs.contains(where: {
               AgentBridge.hasBlockingWorkspaceMoveWork(for: $0)
           }) {
            finishWorkspaceFolderReassignment(
                .activeWork, lease: lease, completion: completion)
            return
        }

        // Land each affected idle controller while the old folder is still authoritative. This can
        // add a newly produced artifact to a member, so rediscover the graph once more afterwards.
        if synchronizeLiveState {
            for bridge in AgentBridge.live.allObjects {
                let holdsImpactedConversation = bridge.currentID.map(
                    preliminary.impactIDs.contains) == true
                guard holdsImpactedConversation
                        || preliminarySourceBridges.contains(where: { $0 === bridge })
                else { continue }
                bridge.prepareForWorkspaceFolderReassignment()
            }
        }
        let stabilizedMemberIDs = workspaceFolderMemberIDs(
            projectID: request.projectID,
            projects: projects,
            conversations: conversations)
        let stabilized = workspaceFolderImpact(
            projectID: request.projectID,
            previousCwd: request.expectedCwd,
            memberIDs: stabilizedMemberIDs,
            conversations: conversations,
            artifactStore: artifactStore)
        let stabilizedExpandedIDs = requiredIDs
            .union(stabilizedMemberIDs)
            .union(stabilized.holderIDs)
        if stabilizedExpandedIDs != requiredIDs {
            acquireExpandedWorkspaceFolderGraph(
                request,
                ids: stabilizedExpandedIDs,
                lease: lease,
                projects: projects,
                conversations: conversations,
                artifactStore: artifactStore,
                synchronizeLiveState: synchronizeLiveState,
                completion: completion)
            return
        }
        guard stabilized.impactIDs.allSatisfy({
            conversations.residentConversation($0) != nil
        }) else {
            finishWorkspaceFolderReassignment(
                .unavailable, lease: lease, completion: completion)
            return
        }
        let finalSourceBridges = synchronizeLiveState
            ? liveWorkspaceFolderSourceBridges(
                projectID: request.projectID,
                previousCwd: request.expectedCwd,
                memberIDs: stabilizedMemberIDs)
            : []
        let finalActiveIDs = stabilized.impactIDs.union(
            finalSourceBridges.compactMap(\.currentID))
        if synchronizeLiveState,
           finalActiveIDs.contains(where: {
               AgentBridge.hasBlockingWorkspaceMoveWork(for: $0)
           }) {
            finishWorkspaceFolderReassignment(
                .activeWork, lease: lease, completion: completion)
            return
        }
        switch validateWorkspaceFolderRequest(request, projects: projects) {
        case .failure(let result):
            finishWorkspaceFolderReassignment(result, lease: lease, completion: completion)
            return
        case .success:
            break
        }

        // This is the runtime all-or-nothing edge: nothing below can yield or discover another
        // binding. Project, Artifact, and Conversation sidecars still persist on their existing
        // independent retrying queues, whose visible error banners retain failed snapshots. A
        // process-crash-atomic multi-file commit remains operation-journal work in the portability
        // phase; this slice deliberately does not pretend those separate files are one transaction.
        let synchronousLoadsBefore = conversations.synchronousHydrationCount
        guard let updatedProject = projects.update(request.projectID, {
            $0.cwd = request.destinationCwd
        }) else {
            finishWorkspaceFolderReassignment(
                .unavailable, lease: lease, completion: completion)
            return
        }
        let commit = reassignWorkspaceFolderResident(
            projectID: request.projectID,
            previousCwd: request.expectedCwd,
            cwd: request.destinationCwd,
            memberConversationIDs: stabilizedMemberIDs,
            artifactHolderConversationIDs: stabilized.holderIDs,
            legacyArtifactIDs: stabilized.legacyArtifactIDs,
            conversations: conversations,
            artifactStore: artifactStore,
            synchronizeLiveState: synchronizeLiveState)
        assert(
            conversations.synchronousHydrationCount == synchronousLoadsBefore,
            "A prepared Workspace-folder change must not hydrate on the main actor.")

        if synchronizeLiveState {
            for bridge in AgentBridge.live.allObjects {
                bridge.applyArtifactWorkspaceAssignments(commit.movedArtifactsByID)
            }
            for bridge in finalSourceBridges {
                bridge.applyWorkspaceFolderReassignment(updatedProject)
            }
        }
        finishWorkspaceFolderReassignment(.changed, lease: lease, completion: completion)
    }

    @MainActor
    private static func acquireExpandedWorkspaceFolderGraph(
        _ request: WorkspaceFolderReassignmentRequest,
        ids: Set<UUID>,
        lease: WorkspacePlacementLease,
        projects: ProjectStore,
        conversations: ConversationStore,
        artifactStore: ArtifactStore,
        synchronizeLiveState: Bool,
        completion: @escaping @MainActor (WorkspaceFolderReassignmentResult) -> Void
    ) {
        // Nested claims install before the current acquisition callback returns, so no resident
        // member can be evicted between graph-growth passes.
        conversations.withAcquiredConversations(ids) { result in
            guard case .success = result else {
                guard case .failure(let error) = result else { return }
                finishWorkspaceFolderReassignment(
                    .bindingUnavailable(error),
                    lease: lease,
                    completion: completion)
                return
            }
            continueWorkspaceFolderReassignment(
                request,
                requiredIDs: ids,
                lease: lease,
                projects: projects,
                conversations: conversations,
                artifactStore: artifactStore,
                synchronizeLiveState: synchronizeLiveState,
                completion: completion)
        }
    }

    private struct WorkspaceFolderImpact {
        let legacyArtifactIDs: Set<UUID>
        let holderIDs: Set<UUID>
        let impactIDs: Set<UUID>
    }

    @MainActor
    private static func workspaceFolderImpact(
        projectID: UUID,
        previousCwd: String,
        memberIDs: Set<UUID>,
        conversations: ConversationStore,
        artifactStore: ArtifactStore
    ) -> WorkspaceFolderImpact {
        let legacyArtifactIDs = Set(memberIDs.flatMap { id in
            conversations.residentConversation(id)?.artifacts.map(\.uuid) ?? []
        })
        let movingArtifactIDs = artifactStore.artifactIDsFollowingWorkspaceFolder(
            inWorkspace: projectID,
            includingConversationIDs: memberIDs,
            includingLegacyArtifactIDs: legacyArtifactIDs,
            previousCwd: previousCwd)
        let holderIDs = conversations.conversationIDs(
            referencingArtifactIDs: movingArtifactIDs)
        return WorkspaceFolderImpact(
            legacyArtifactIDs: legacyArtifactIDs,
            holderIDs: holderIDs,
            impactIDs: memberIDs.union(holderIDs))
    }

    @MainActor
    private static func workspaceFolderMemberIDs(
        projectID: UUID,
        projects: ProjectStore,
        conversations: ConversationStore
    ) -> Set<UUID> {
        let scope = WorkspaceScope.project(projectID)
        return Set(conversations.summaries.compactMap {
            scope.contains($0, projects: projects.projects) ? $0.id : nil
        })
    }

    @MainActor
    private static func liveWorkspaceFolderSourceBridges(
        projectID: UUID,
        previousCwd: String,
        memberIDs: Set<UUID>
    ) -> [AgentBridge] {
        let live = AgentBridge.live.allObjects
        let sourceIDs = workspaceFolderSourceBridgeIDs(
            projectID: projectID,
            previousCwd: previousCwd,
            memberConversationIDs: memberIDs,
            bridges: live.map { bridge in
                WorkspaceAdoptionLiveBridgeSnapshot(
                    bridgeID: bridge.bridgeID,
                    hasWindow: bridge.window != nil,
                    currentConversationID: bridge.currentID,
                    projectID: bridge.projectID,
                    cwd: bridge.cwd)
            })
        return live.filter { bridge in
            sourceIDs.contains(bridge.bridgeID)
        }
    }

    @MainActor
    private static func validateWorkspaceFolderRequest(
        _ request: WorkspaceFolderReassignmentRequest,
        projects: ProjectStore
    ) -> Result<Project, WorkspaceFolderReassignmentResult> {
        guard !ReservedWorkspace.owns(request.projectID) else {
            return .failure(.unavailable)
        }
        guard let current = projects.project(request.projectID) else { return .failure(.unavailable) }
        guard current.cwd == request.expectedCwd else { return .failure(.sourceChanged) }
        if let clash = projects.projects.first(where: {
            $0.id != request.projectID && $0.cwd == request.destinationCwd
        }) {
            return .failure(.collision(clash.displayName))
        }
        return .success(current)
    }

    private struct WorkspaceFolderResidentCommit {
        let movedArtifactsByID: [UUID: Artifact]
    }

    /// The non-yielding mutation edge. Every full Conversation is already resident and pinned; only
    /// Workspace members change placement, while foreign same-UUID holders receive canonical nested
    /// artifact metadata without being moved themselves.
    @MainActor
    private static func reassignWorkspaceFolderResident(
        projectID: UUID,
        previousCwd: String,
        cwd: String,
        memberConversationIDs: Set<UUID>,
        artifactHolderConversationIDs: Set<UUID>,
        legacyArtifactIDs: Set<UUID>,
        conversations: ConversationStore,
        artifactStore: ArtifactStore,
        synchronizeLiveState: Bool
    ) -> WorkspaceFolderResidentCommit {
        let impactIDs = memberConversationIDs.union(artifactHolderConversationIDs)
        precondition(impactIDs.allSatisfy {
            conversations.residentConversation($0) != nil
        }, "Workspace-folder commit requires a fully resident impact graph.")

        let moved = artifactStore.reassignArtifacts(
            inWorkspace: projectID,
            includingConversationIDs: memberConversationIDs,
            includingLegacyArtifactIDs: legacyArtifactIDs,
            previousCwd: previousCwd,
            cwd: cwd)
        let movedByID = Dictionary(uniqueKeysWithValues: moved.map { ($0.uuid, $0) })
        let durableByID = Dictionary(uniqueKeysWithValues: artifactStore.artifacts.map {
            ($0.uuid, $0)
        })

        for id in impactIDs.sorted(by: { $0.uuidString < $1.uuidString }) {
            let isMember = memberConversationIDs.contains(id)
            guard let updated = conversations.updateResident(id, { conversation in
                if isMember {
                    conversation.projectID = projectID
                    conversation.cwd = cwd
                }
                for index in conversation.artifacts.indices {
                    let nested = conversation.artifacts[index]
                    if let moved = movedByID[nested.uuid] {
                        conversation.artifacts[index] = moved
                    } else if isMember, let durable = durableByID[nested.uuid] {
                        conversation.artifacts[index] = durable
                    } else if isMember, nestedArtifact(nested, follows: id) {
                        conversation.artifacts[index].workspaceID = projectID
                        conversation.artifacts[index].cwd = cwd
                    }
                }
            }) else {
                preconditionFailure("A pinned Workspace-folder Conversation disappeared at commit.")
            }
            if synchronizeLiveState {
                PreviewRegistry.shared.sync(updated.artifacts, conv: id)
            }
        }
        return WorkspaceFolderResidentCommit(movedArtifactsByID: movedByID)
    }

    @MainActor
    private static func finishWorkspaceFolderReassignment(
        _ result: WorkspaceFolderReassignmentResult,
        lease: WorkspacePlacementLease,
        completion: @escaping @MainActor (WorkspaceFolderReassignmentResult) -> Void
    ) {
        // Acquisition scopes release their claims as the callback unwinds. Complete on the next
        // actor turn so a modal UI or immediate retry can never overlap those claims or this lease.
        Task { @MainActor in
            _ = endPlacementOperation(lease)
            completion(result)
        }
    }

    @MainActor
    private static func continueConversationPreparation(
        ids: Set<UUID>,
        requiredIDs: Set<UUID>,
        lease: WorkspacePlacementLease,
        destinationCommit: PreparedDestinationCommit,
        conversations: ConversationStore,
        artifactStore: ArtifactStore?,
        synchronizeLiveState: Bool,
        receivingBridgeID: UUID?,
        undoManager: UndoManager?,
        completion: @escaping @MainActor (WorkspaceAdoptionResult) -> Void
    ) {
        // Hydration yields. Recheck active work before touching the visible controller, then land
        // its latest idle snapshot and rediscover the complete ownership graph. If that graph grew,
        // the nested acquisition extends the claims and this exact stabilization pass repeats.
        if let failure = preflight(
            conversations: ids,
            conversations: conversations,
            synchronizeLiveState: synchronizeLiveState,
            ignoringPreparation: true) {
            finishPreparedMove(
                failure,
                lease: lease,
                destinationCommit: destinationCommit,
                completion: completion)
            return
        }
        if synchronizeLiveState {
            for bridge in AgentBridge.live.allObjects {
                guard let currentID = bridge.currentID, ids.contains(currentID) else { continue }
                bridge.prepareForConversationWorkspaceAdoption(currentID)
            }
        }
        guard let impactIDs = conversationMoveImpactIDs(
            ids: ids,
            conversations: conversations,
            artifactStore: artifactStore)
        else {
            finishPreparedMove(
                .unavailable,
                lease: lease,
                destinationCommit: destinationCommit,
                completion: completion)
            return
        }
        let expandedIDs = requiredIDs.union(impactIDs)
        if expandedIDs != requiredIDs {
            // The nested acquisition installs its claims before this callback returns, so releasing
            // the outer claim cannot create an eviction gap for already-loaded records.
            conversations.withAcquiredConversations(expandedIDs) { result in
                guard case .success = result else {
                    guard case .failure(let error) = result else { return }
                    finishPreparedMove(
                        .bindingUnavailable(error),
                        lease: lease,
                        destinationCommit: destinationCommit,
                        completion: completion)
                    return
                }
                continueConversationPreparation(
                    ids: ids,
                    requiredIDs: expandedIDs,
                    lease: lease,
                    destinationCommit: destinationCommit,
                    conversations: conversations,
                    artifactStore: artifactStore,
                    synchronizeLiveState: synchronizeLiveState,
                    receivingBridgeID: receivingBridgeID,
                    undoManager: undoManager,
                    completion: completion)
            }
            return
        }

        let destination: WorkspaceDestination
        switch destinationCommit.resolve() {
        case .destination(let resolved):
            destination = resolved
        case .failure(let failure):
            finishPreparedMove(
                failure,
                lease: lease,
                destinationCommit: destinationCommit,
                completion: completion)
            return
        }
        let receivingBridge: AgentBridge?
        if synchronizeLiveState, receivingBridgeID != nil {
            guard let valid = validReceivingBridge(
                receivingBridgeID,
                destination: destination)
            else {
                finishPreparedMove(
                    .destinationWindowChanged,
                    lease: lease,
                    destinationCommit: destinationCommit,
                    completion: completion)
                return
            }
            receivingBridge = valid
        } else {
            receivingBridge = nil
        }
        let synchronousLoadsBefore = conversations.synchronousHydrationCount
        let result = adopt(
            conversations: ids,
            into: destination,
            conversations: conversations,
            artifactStore: artifactStore,
            synchronizeLiveState: synchronizeLiveState,
            receivingBridge: receivingBridge,
            undoManager: undoManager,
            ignoringPreparation: true)
        assert(
            conversations.synchronousHydrationCount == synchronousLoadsBefore,
            "A prepared Workspace move must not hydrate on the main actor.")
        finishPreparedMove(
            result,
            lease: lease,
            destinationCommit: destinationCommit,
            completion: completion)
    }

    @MainActor
    private static func continueArtifactPreparation(
        ids: Set<UUID>,
        requiredIDs: Set<UUID>,
        lease: WorkspacePlacementLease,
        destinationCommit: PreparedDestinationCommit,
        conversations: ConversationStore,
        artifactStore: ArtifactStore,
        synchronizeLiveState: Bool,
        undoManager: UndoManager?,
        completion: @escaping @MainActor (WorkspaceAdoptionResult) -> Void
    ) {
        let impactIDs = conversations.conversationIDs(referencingArtifactIDs: ids)
        let expandedIDs = requiredIDs.union(impactIDs)
        if expandedIDs != requiredIDs {
            conversations.withAcquiredConversations(expandedIDs) { result in
                guard case .success = result else {
                    guard case .failure(let error) = result else { return }
                    finishPreparedMove(
                        .bindingUnavailable(error),
                        lease: lease,
                        destinationCommit: destinationCommit,
                        completion: completion)
                    return
                }
                continueArtifactPreparation(
                    ids: ids,
                    requiredIDs: expandedIDs,
                    lease: lease,
                    destinationCommit: destinationCommit,
                    conversations: conversations,
                    artifactStore: artifactStore,
                    synchronizeLiveState: synchronizeLiveState,
                    undoManager: undoManager,
                    completion: completion)
            }
            return
        }

        if let failure = preflight(
            artifacts: ids,
            artifactStore: artifactStore,
            ignoringPreparation: true) {
            finishPreparedMove(
                failure,
                lease: lease,
                destinationCommit: destinationCommit,
                completion: completion)
            return
        }
        let destination: WorkspaceDestination
        switch destinationCommit.resolve() {
        case .destination(let resolved):
            destination = resolved
        case .failure(let failure):
            finishPreparedMove(
                failure,
                lease: lease,
                destinationCommit: destinationCommit,
                completion: completion)
            return
        }
        let synchronousLoadsBefore = conversations.synchronousHydrationCount
        let result = adopt(
            artifacts: ids,
            into: destination,
            conversations: conversations,
            artifactStore: artifactStore,
            synchronizeLiveState: synchronizeLiveState,
            undoManager: undoManager,
            ignoringPreparation: true)
        assert(
            conversations.synchronousHydrationCount == synchronousLoadsBefore,
            "A prepared artifact move must not hydrate on the main actor.")
        finishPreparedMove(
            result,
            lease: lease,
            destinationCommit: destinationCommit,
            completion: completion)
    }

    @MainActor
    private static func conversationMoveImpactIDs(
        ids: Set<UUID>,
        conversations: ConversationStore,
        artifactStore: ArtifactStore?
    ) -> Set<UUID>? {
        var nestedArtifactIDs = Set<UUID>()
        for id in ids {
            guard let conversation = conversations.residentConversation(id) else { return nil }
            nestedArtifactIDs.formUnion(conversation.artifacts.map(\.uuid))
        }
        guard let artifactStore else { return ids }
        let movingArtifactIDs = Set(artifactStore.artifacts.compactMap { artifact -> UUID? in
            if artifact.conversationID.map(ids.contains) == true { return artifact.uuid }
            return artifact.conversationID == nil
                && artifact.origin == "interactive"
                && nestedArtifactIDs.contains(artifact.uuid)
                ? artifact.uuid
                : nil
        })
        return ids.union(conversations.conversationIDs(
            referencingArtifactIDs: movingArtifactIDs))
    }

    @MainActor
    private static func resolvedDestination(
        _ requested: WorkspaceDestination,
        projectStore: ProjectStore?
    ) -> WorkspaceDestination? {
        switch requested {
        case .home:
            return .home
        case .project(let snapshot):
            guard let projectStore else { return .project(snapshot) }
            guard let current = projectStore.project(snapshot.id) else { return nil }
            return .project(current)
        }
    }

    @MainActor
    private static func validReceivingBridge(
        _ bridgeID: UUID?,
        destination: WorkspaceDestination
    ) -> AgentBridge? {
        guard let bridgeID else { return nil }
        return AgentBridge.live.allObjects.first { bridge in
            guard bridge.bridgeID == bridgeID, bridge.window != nil else { return false }
            return WorkspaceAdoptionLiveBridgeSnapshot(
                bridgeID: bridge.bridgeID,
                hasWindow: bridge.window != nil,
                currentConversationID: bridge.currentID,
                projectID: bridge.projectID,
                cwd: bridge.cwd).displays(destination)
        }
    }

    /// Leave the residency scope and the one-move preparation gate before running UI completion.
    /// Completion may present a modal alert, route a window, or submit another move; scheduling it
    /// for the next MainActor turn prevents those nested event loops from overlapping this scope.
    @MainActor
    private static func finishPreparedMove(
        _ result: WorkspaceAdoptionResult,
        lease: WorkspacePlacementLease,
        destinationCommit: PreparedDestinationCommit,
        completion: @escaping @MainActor (WorkspaceAdoptionResult) -> Void
    ) {
        destinationCommit.finalize(result)
        Task { @MainActor in
            endPlacementOperation(lease)
            completion(result)
        }
    }

    private static func workspaceMoveCaptures(
        memberKind: LibraryWorkspaceMoveOperationPayload.MemberKind,
        memberIDsBySourceWorkspace: [UUID: Set<UUID>],
        destinationWorkspaceID: UUID?,
        isUndo: Bool
    ) -> [LibraryTransientOperationCaptureFactory.Capture] {
        var captures: [LibraryTransientOperationCaptureFactory.Capture] = []
        for source in memberIDsBySourceWorkspace.keys.sorted(by: {
            $0.uuidString < $1.uuidString
        }) {
            guard let memberIDs = memberIDsBySourceWorkspace[source], !memberIDs.isEmpty else {
                continue
            }
            if let capture = try? LibraryTransientOperationCaptureFactory.workspaceMove(
                memberKind: memberKind,
                memberIDs: memberIDs,
                sourceWorkspaceID: source,
                destinationWorkspaceID: destinationWorkspaceID,
                isUndo: isUndo) {
                captures.append(capture)
            }
        }
        return captures
    }

    /// Preserve the historical single-conversation API while routing it through the complete
    /// ownership coordinator. Tests with an isolated ConversationStore do not implicitly touch the
    /// process-global artifact library; pass an isolated ArtifactStore when exercising convergence.
    @discardableResult
    @MainActor
    static func adopt(
        conversation id: UUID,
        into project: Project,
        conversations explicitConversations: ConversationStore? = nil,
        artifactStore: ArtifactStore? = nil,
        synchronizeLiveState: Bool? = nil
    ) -> WorkspaceAdoptionResult {
        let conversations = explicitConversations ?? .shared
        return adopt(
            conversations: [id],
            into: .project(project),
            conversations: conversations,
            artifactStore: artifactStore,
            synchronizeLiveState: synchronizeLiveState)
    }

    /// Convenience for callers holding only an id. A missing project is a no-op: better to leave a
    /// conversation where it is than to move it somewhere that no longer exists.
    @discardableResult
    @MainActor
    static func adopt(
        conversation id: UUID,
        intoProjectID projectID: UUID
    ) -> WorkspaceAdoptionResult {
        guard let project = ProjectStore.shared.project(projectID) else { return .unavailable }
        return adopt(conversation: id, into: project)
    }

    /// Move a validated conversation set and every artifact that belongs to it. The main-actor
    /// mutation is all-or-nothing from the UI's perspective; the stores retain their existing
    /// explicit retry banners if an asynchronous atomic sidecar write later fails.
    @discardableResult
    @MainActor
    static func adopt(
        conversations ids: Set<UUID>,
        into destination: WorkspaceDestination,
        conversations explicitConversations: ConversationStore? = nil,
        artifactStore explicitArtifactStore: ArtifactStore? = nil,
        synchronizeLiveState explicitLiveSync: Bool? = nil,
        receivingBridge explicitReceivingBridge: AgentBridge? = nil,
        undoManager: UndoManager? = nil,
        ignoringPreparation: Bool = false
    ) -> WorkspaceAdoptionResult {
        let conversations = explicitConversations ?? .shared
        let liveSync = explicitLiveSync ?? (conversations === ConversationStore.shared)
        if let failure = preflight(
            conversations: ids,
            conversations: conversations,
            synchronizeLiveState: liveSync,
            ignoringPreparation: ignoringPreparation) {
            return failure
        }

        // Establish the complete exact input set before the first workspace/artifact mutation.
        // A binding that vanished after the lightweight preflight must fail the whole move, never
        // leave an early member moved and a later member behind. This compatibility guard keeps the
        // synchronous workspace/undo API lossless; its counted loads identify the seam to move
        // behind an asynchronous operation journal in the portability phase.
        var acquiredConversations: [UUID: Conversation] = [:]
        for id in ids.sorted(by: { $0.uuidString < $1.uuidString }) {
            guard let conversation = conversations.residentConversation(id)
                    ?? conversations.hydrateImmediately(id)
            else { return .unavailable }
            acquiredConversations[id] = conversation
        }
        guard preservesReservedConversationIdentity(
            Array(acquiredConversations.values),
            into: destination
        ) else { return .unavailable }

        // If the destination already has a window, that window receives the moved conversation and
        // the source window remains in its old workspace. This is the cross-window drop contract and
        // also prevents a sidebar move from manufacturing a second window for one workspace.
        var liveBridges = liveSync ? AgentBridge.live.allObjects : []
        if let explicitReceivingBridge,
           !liveBridges.contains(where: { $0 === explicitReceivingBridge }) {
            liveBridges.append(explicitReceivingBridge)
        }
        let handoffPlan: WorkspaceAdoptionLiveHandoffPlan? = {
            guard liveSync else { return nil }
            return workspaceAdoptionLiveHandoffPlan(
                movedConversationIDs: ids,
                destination: destination,
                bridges: liveBridges.map {
                    WorkspaceAdoptionLiveBridgeSnapshot(
                        bridgeID: $0.bridgeID,
                        hasWindow: $0.window != nil,
                        currentConversationID: $0.currentID,
                        projectID: $0.projectID,
                        cwd: $0.cwd)
                },
                explicitReceivingBridgeID: explicitReceivingBridge?.bridgeID)
        }()
        let receivingBridge = handoffPlan.flatMap { plan in
            liveBridges.first { $0.bridgeID == plan.receivingBridgeID }
        }

        // Land any unsaved transcript/artifact bytes before taking the store snapshots used below.
        // No active turn exists (guarded above), so this cannot race provider output.
        if liveSync {
            for bridge in AgentBridge.live.allObjects {
                guard let currentID = bridge.currentID, ids.contains(currentID) else { continue }
                bridge.prepareForConversationWorkspaceAdoption(currentID)
            }
        }

        let artifactStore = explicitArtifactStore
            ?? (conversations === ConversationStore.shared ? ArtifactStore.shared : nil)
        var changedConversationCount = 0
        var changedArtifactIDs = Set<UUID>()
        var adoptedDurableByID: [UUID: Artifact] = [:]
        var updatedConversations: [UUID: Conversation] = [:]
        var movedConversationIDsBySourceWorkspace: [UUID: Set<UUID>] = [:]
        var movedArtifactIDsBySourceWorkspace: [UUID: Set<UUID>] = [:]
        // Captured from the values this function already reads on its way through, so the undo
        // record cannot drift from the ownership rules below. See `WorkspaceMoveUndo`.
        var undoRecord = WorkspaceMoveUndo.Record()

        for id in ids.sorted(by: { $0.uuidString < $1.uuidString }) {
            guard let before = acquiredConversations[id] else { return .unavailable }
            movedConversationIDsBySourceWorkspace[
                before.projectID ?? SQLiteLibraryStore.homeWorkspaceID,
                default: []
            ].insert(id)
            undoRecord.capture(before)
            let legacyIDs = Set(before.artifacts.map(\.uuid))
            let beforeDurable: [UUID: Artifact] = artifactStore.map { store in
                Dictionary(uniqueKeysWithValues: store.artifacts.compactMap { artifact in
                    let belongs = artifact.conversationID == id
                        || (artifact.conversationID == nil
                            && artifact.origin == "interactive"
                            && legacyIDs.contains(artifact.uuid))
                    return belongs ? (artifact.uuid, artifact) : nil
                })
            } ?? [:]
            for artifact in beforeDurable.values {
                movedArtifactIDsBySourceWorkspace[
                    artifact.workspaceID ?? SQLiteLibraryStore.homeWorkspaceID,
                    default: []
                ].insert(artifact.uuid)
            }
            undoRecord.capture(artifacts: beforeDurable)
            let movedDurable = artifactStore?.reassignArtifacts(
                forConversation: id,
                includingLegacyArtifactIDs: legacyIDs,
                conversationTitle: before.conversationTitleForArtifacts,
                workspaceID: destination.projectID,
                cwd: destination.cwd) ?? []
            let movedDurableByID = Dictionary(
                uniqueKeysWithValues: movedDurable.map { ($0.uuid, $0) })
            adoptedDurableByID.merge(movedDurableByID) { _, latest in latest }
            // A conversation may reference an artifact owned by another conversation. Its exact
            // durable UUID remains canonical and must not be retagged just because the referencing
            // conversation moved.
            let durableByID = artifactStore.map { store in
                Dictionary(uniqueKeysWithValues: store.artifacts.map { ($0.uuid, $0) })
            } ?? movedDurableByID
            for artifact in movedDurable {
                if beforeDurable[artifact.uuid] != artifact {
                    changedArtifactIDs.insert(artifact.uuid)
                }
            }

            var conversationChanged =
                before.projectID != destination.projectID || before.cwd != destination.cwd
            let updated = conversations.updateResident(id) { conversation in
                conversation.projectID = destination.projectID
                conversation.cwd = destination.cwd
                for index in conversation.artifacts.indices {
                    let nested = conversation.artifacts[index]
                    if let durable = durableByID[nested.uuid] {
                        conversation.artifacts[index] = durable
                    } else if nestedArtifact(nested, follows: id) {
                        conversation.artifacts[index].workspaceID = destination.projectID
                        conversation.artifacts[index].cwd = destination.cwd
                        if conversation.artifacts[index].conversationID == nil {
                            conversation.artifacts[index].conversationID = id
                        }
                        if conversation.artifacts[index].conversationTitle.isEmpty {
                            conversation.artifacts[index].conversationTitle =
                                conversation.conversationTitleForArtifacts
                        }
                    }
                    if conversation.artifacts[index] != nested {
                        changedArtifactIDs.insert(conversation.artifacts[index].uuid)
                        conversationChanged = true
                    }
                }
            }
            if let updated {
                if conversationChanged { changedConversationCount += 1 }
                updatedConversations[id] = updated
            }
        }

        // An artifact can be referenced by conversations other than the one that owns it (for
        // example after dragging it into another chat). Conversation adoption changes the durable
        // owner record above; converge every exact-UUID nested snapshot as well, just like a direct
        // artifact move does. Otherwise a closed or live referencing conversation can retain the
        // old workspace metadata and write that stale snapshot back on its next save.
        if !adoptedDurableByID.isEmpty {
            let referencingConversationIDs = conversations.conversationIDs(
                referencingArtifactIDs: Set(adoptedDurableByID.keys))
            for conversationID in referencingConversationIDs.sorted(by: {
                $0.uuidString < $1.uuidString
            }) {
                var didChange = false
                if let referencing = conversations.residentConversation(conversationID)
                    ?? conversations.hydrateImmediately(conversationID) {
                    undoRecord.capture(referencing)
                }
                let updated = conversations.updateResident(conversationID) { conversation in
                    for index in conversation.artifacts.indices {
                        let artifactID = conversation.artifacts[index].uuid
                        guard let durable = adoptedDurableByID[artifactID],
                              conversation.artifacts[index] != durable else { continue }
                        conversation.artifacts[index] = durable
                        changedArtifactIDs.insert(artifactID)
                        didChange = true
                    }
                }
                if didChange, let updated {
                    updatedConversations[conversationID] = updated
                }
            }
        }

        if liveSync {
            for bridge in liveBridges {
                bridge.applyArtifactWorkspaceAssignments(adoptedDurableByID)
            }
            if let receivingBridge, let handoffPlan {
                let sourceBridgeIDs = Set(handoffPlan.sourceBridgeIDs)
                for bridge in liveBridges
                where sourceBridgeIDs.contains(bridge.bridgeID) {
                    bridge.relinquishConversationsAfterWorkspaceAdoption(ids)
                }
                if receivingBridge.currentID != handoffPlan.revealConversationID {
                    receivingBridge.select(handoffPlan.revealConversationID)
                }
            }
            for conversation in updatedConversations.values.sorted(by: {
                $0.id.uuidString < $1.id.uuidString
            }) {
                if receivingBridge == nil {
                    for bridge in AgentBridge.live.allObjects
                    where bridge.currentID == conversation.id {
                        bridge.applyConversationWorkspaceAdoption(
                            conversation,
                            destination: destination)
                    }
                }
                PreviewRegistry.shared.sync(conversation.artifacts, conv: conversation.id)
            }
        }

        guard changedConversationCount > 0 || !changedArtifactIDs.isEmpty else { return .unchanged }
        let operationCaptures = workspaceMoveCaptures(
            memberKind: .conversation,
            memberIDsBySourceWorkspace: movedConversationIDsBySourceWorkspace,
            destinationWorkspaceID: destination.projectID,
            isUndo: false)
            + workspaceMoveCaptures(
                memberKind: .artifact,
                memberIDsBySourceWorkspace: movedArtifactIDsBySourceWorkspace.mapValues {
                    $0.intersection(changedArtifactIDs)
                },
                destinationWorkspaceID: destination.projectID,
                isUndo: false)
        LibraryTransientOperationCapturePublisher.publish(
            operationCaptures,
            afterConversations: undoRecord.conversationIDs,
            in: conversations,
            artifactIDs: changedArtifactIDs,
            in: artifactStore)
        WorkspaceMoveUndo.register(
            undoRecord,
            actionName: WorkspaceMoveUndo.actionName(conversations: ids.count),
            with: undoManager,
            conversations: conversations,
            artifactStore: artifactStore)
        return .moved(
            conversations: changedConversationCount,
            artifacts: changedArtifactIDs.count)
    }

    /// Re-file standalone/durable artifacts without changing their originating conversation. Any
    /// nested/live copy with the same UUID receives the canonical metadata so a later save cannot
    /// write the previous workspace back.
    @discardableResult
    @MainActor
    static func adopt(
        artifacts ids: Set<UUID>,
        into destination: WorkspaceDestination,
        conversations explicitConversations: ConversationStore? = nil,
        artifactStore explicitArtifactStore: ArtifactStore? = nil,
        synchronizeLiveState: Bool = true,
        undoManager: UndoManager? = nil,
        ignoringPreparation: Bool = false
    ) -> WorkspaceAdoptionResult {
        let conversations = explicitConversations ?? .shared
        let artifactStore = explicitArtifactStore ?? .shared
        if let failure = preflight(
            artifacts: ids,
            artifactStore: artifactStore,
            ignoringPreparation: ignoringPreparation) {
            return failure
        }

        let before = Dictionary(
            uniqueKeysWithValues: artifactStore.artifacts
                .filter { ids.contains($0.uuid) }
                .map { ($0.uuid, $0) })
        var movedArtifactIDsBySourceWorkspace: [UUID: Set<UUID>] = [:]
        for artifact in before.values {
            movedArtifactIDsBySourceWorkspace[
                artifact.workspaceID ?? SQLiteLibraryStore.homeWorkspaceID,
                default: []
            ].insert(artifact.uuid)
        }
        // `before` is already exactly the artifact half of the undo record, so it is reused rather
        // than recomputed. Restoring whole values matters here for the same reason it does for a
        // conversation move: reassignment fills fields that nothing ever clears.
        var undoRecord = WorkspaceMoveUndo.Record()
        undoRecord.capture(artifacts: before)
        var movedByID: [UUID: Artifact] = [:]
        for id in ids.sorted(by: { $0.uuidString < $1.uuidString }) {
            guard let moved = artifactStore.reassignArtifact(
                id,
                workspaceID: destination.projectID,
                cwd: destination.cwd)
            else { return .unavailable }
            movedByID[id] = moved
        }

        var updatedConversations: [Conversation] = []
        let conversationIDs = conversations.conversationIDs(
            referencingArtifactIDs: Set(movedByID.keys))
        for conversationID in conversationIDs {
            var didChange = false
            // A conversation holding a same-UUID nested snapshot is rewritten below, so its
            // pre-move placement belongs in the record too — otherwise undo would restore the
            // durable artifact while leaving stale copies inside conversations.
            if let referencing = conversations.residentConversation(conversationID)
                ?? conversations.hydrateImmediately(conversationID) {
                undoRecord.capture(referencing)
            }
            let updated = conversations.updateResident(conversationID) { conversation in
                for index in conversation.artifacts.indices {
                    let id = conversation.artifacts[index].uuid
                    guard let moved = movedByID[id] else { continue }
                    if conversation.artifacts[index] != moved {
                        conversation.artifacts[index] = moved
                        didChange = true
                    }
                }
            }
            if didChange, let updated { updatedConversations.append(updated) }
        }

        if synchronizeLiveState {
            for bridge in AgentBridge.live.allObjects {
                bridge.applyArtifactWorkspaceAssignments(movedByID)
            }
            for conversation in updatedConversations {
                PreviewRegistry.shared.sync(
                    conversation.artifacts,
                    conv: conversation.id)
            }
            for artifact in movedByID.values {
                if let conversationID = artifact.conversationID {
                    PreviewRegistry.shared.put(artifact, conv: conversationID)
                }
            }
        }

        let changed = movedByID.values.filter { before[$0.uuid] != $0 }.count
        guard changed > 0 || !updatedConversations.isEmpty else { return .unchanged }
        let changedArtifactIDs = Set(movedByID.values.compactMap {
            before[$0.uuid] != $0 ? $0.uuid : nil
        })
        let operationCaptures = workspaceMoveCaptures(
            memberKind: .artifact,
            memberIDsBySourceWorkspace: movedArtifactIDsBySourceWorkspace.mapValues {
                $0.intersection(changedArtifactIDs)
            },
            destinationWorkspaceID: destination.projectID,
            isUndo: false)
        LibraryTransientOperationCapturePublisher.publish(
            operationCaptures,
            afterConversations: undoRecord.conversationIDs,
            in: conversations,
            artifactIDs: changedArtifactIDs,
            in: artifactStore)
        WorkspaceMoveUndo.register(
            undoRecord,
            actionName: WorkspaceMoveUndo.actionName(artifacts: ids.count),
            with: undoManager,
            conversations: conversations,
            artifactStore: artifactStore)
        return .moved(conversations: 0, artifacts: changed)
    }

    /// Legacy synchronous compatibility seam for focused ownership tests. User-facing folder
    /// changes use `reassignWorkspaceFolderAfterAcquiring`, whose complete impact graph is resident
    /// before its strict commit. This helper remains useful for exercising the underlying ownership
    /// rules without UI or asynchronous acquisition.
    @MainActor
    static func reassignWorkspaceFolder(
        projectID: UUID,
        previousCwd: String,
        cwd: String,
        conversationIDs: Set<UUID>,
        conversations explicitConversations: ConversationStore? = nil,
        artifactStore explicitArtifactStore: ArtifactStore? = nil
    ) {
        let conversations = explicitConversations ?? .shared
        let artifactStore = explicitArtifactStore ?? .shared
        let legacyIDs = Set(conversationIDs.flatMap { id in
            (conversations.residentConversation(id)
                ?? conversations.hydrateImmediately(id))?.artifacts.map(\.uuid) ?? []
        })
        let moved = artifactStore.reassignArtifacts(
            inWorkspace: projectID,
            includingConversationIDs: conversationIDs,
            includingLegacyArtifactIDs: legacyIDs,
            previousCwd: previousCwd,
            cwd: cwd)
        let movedByID = Dictionary(uniqueKeysWithValues: moved.map { ($0.uuid, $0) })
        // A conversation snapshot may contain an artifact the user filed independently in another
        // workspace. `reassignArtifacts(inWorkspace:)` deliberately leaves that durable record
        // alone; use the complete post-reassignment durable set when converging nested snapshots so
        // the fallback below cannot silently pull the nested copy back into this workspace.
        let durableByID = Dictionary(uniqueKeysWithValues: artifactStore.artifacts.map {
            ($0.uuid, $0)
        })

        for id in conversationIDs {
            guard let updated = conversations.update(id, { conversation in
                conversation.projectID = projectID
                conversation.cwd = cwd
                for index in conversation.artifacts.indices {
                    let nested = conversation.artifacts[index]
                    if let durable = movedByID[nested.uuid] {
                        conversation.artifacts[index] = durable
                    } else if let durable = durableByID[nested.uuid] {
                        conversation.artifacts[index] = durable
                    } else if nestedArtifact(nested, follows: id) {
                        conversation.artifacts[index].workspaceID = projectID
                        conversation.artifacts[index].cwd = cwd
                    }
                }
            }) else { continue }
            PreviewRegistry.shared.sync(updated.artifacts, conv: id)
        }
    }
}

private extension Conversation {
    var conversationTitleForArtifacts: String {
        displayTitle.isEmpty ? title : displayTitle
    }
}
