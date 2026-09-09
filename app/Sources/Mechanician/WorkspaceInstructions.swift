import CryptoKit
import Foundation

/// The canonical identity of one workspace. A folder is a property of a Project, never a second
/// ownership key. Home deliberately remains distinct rather than becoming a synthetic `Project`.
///
/// Persisted conversation ids win over cwd. The cwd fallback exists only for legacy records that
/// predate projectID, and only when one existing Project owns that exact normalized path.
enum WorkspaceScope: Hashable, Identifiable {
    case home
    case project(UUID)

    var id: String {
        switch self {
        case .home:
            return "home"
        case .project(let id):
            return "project:\(id.uuidString)"
        }
    }

    static func resolve(
        projectID: UUID?,
        cwd: String,
        projects: [Project]
    ) -> WorkspaceScope? {
        if let projectID {
            return projects.contains(where: { $0.id == projectID })
                ? .project(projectID)
                : nil
        }

        // Exact nil + empty is Home. Whitespace is not a location and must not silently widen Home.
        if cwd.isEmpty { return .home }
        let normalizedCwd = cwd.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedCwd.isEmpty else { return nil }
        let matches = projects.filter {
            $0.cwd.trimmingCharacters(in: .whitespacesAndNewlines) == normalizedCwd
        }
        guard matches.count == 1, let project = matches.first else { return nil }
        return .project(project.id)
    }

    static func resolve(
        conversation: Conversation,
        projects: [Project]
    ) -> WorkspaceScope? {
        resolve(projectID: conversation.projectID, cwd: conversation.cwd, projects: projects)
    }

    static func resolve(
        summary: ConversationSummary,
        projects: [Project]
    ) -> WorkspaceScope? {
        resolve(
            projectID: summary.workspaceID,
            cwd: summary.workspaceCWD,
            projects: projects)
    }

    func contains(_ conversation: Conversation, projects: [Project]) -> Bool {
        Self.resolve(conversation: conversation, projects: projects) == self
    }

    func contains(_ summary: ConversationSummary, projects: [Project]) -> Bool {
        Self.resolve(summary: summary, projects: projects) == self
    }

    /// The two persisted fields a conversation must carry for this scope. Resolution decides
    /// membership; this binding keeps the execution cwd synchronized with that canonical identity.
    func canonicalBinding(
        projects: [Project]
    ) -> (projectID: UUID?, cwd: String)? {
        switch self {
        case .home:
            return (nil, "")
        case .project(let id):
            guard let project = projects.first(where: { $0.id == id }) else { return nil }
            return (id, project.cwd)
        }
    }

    /// Choose an exact requested conversation when it belongs here; otherwise use this workspace's
    /// most recently updated candidate. Callers remove conversations owned by other windows first.
    func preferredConversation(
        requestedID: UUID? = nil,
        among candidates: [Conversation],
        projects: [Project]
    ) -> Conversation? {
        let eligible = candidates.filter { contains($0, projects: projects) }
        if let requestedID,
           let requested = eligible.first(where: { $0.id == requestedID }) {
            return requested
        }
        return eligible.max(by: { $0.updatedAt < $1.updatedAt })
    }

    func preferredConversation(
        requestedID: UUID? = nil,
        among candidates: [ConversationSummary],
        projects: [Project]
    ) -> ConversationSummary? {
        let eligible = candidates.filter { contains($0, projects: projects) }
        if let requestedID,
           let requested = eligible.first(where: { $0.id == requestedID }) {
            return requested
        }
        return eligible.max(by: { $0.updatedAt < $1.updatedAt })
    }
}

/// Workspace instructions use the same identity as every other workspace-scoped surface.
typealias WorkspaceInstructionsTarget = WorkspaceScope

/// Home has no `Project` record, but its app-owned settings deserve the same tolerant, future-proof
/// persistence contract as Workspaces. Keeping this file outside `workspaces/` also means record
/// scanners ignore it instead of trying to decode it as a Project.
struct HomeWorkspaceSettings: Codable, Equatable {
    var schemaVersion: Int = 1
    var instructions: String = ""
    var updatedAt: Date = Date()

    init(
        schemaVersion: Int = 1,
        instructions: String = "",
        updatedAt: Date = Date()
    ) {
        self.schemaVersion = schemaVersion
        self.instructions = instructions
        self.updatedAt = updatedAt
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try c.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        instructions = try c.decodeIfPresent(String.self, forKey: .instructions) ?? ""
        updatedAt = try c.decodeIfPresent(Date.self, forKey: .updatedAt) ?? Date()
    }
}

/// An immutable, provider-neutral view of the instructions owned by the workspace for one turn.
///
/// Resolving this before constructing a provider request prevents three subtle leaks:
/// - a deleted/dangling Project never falls through to Home;
/// - a topic workspace never reads `~/CLAUDE.md` merely because its process cwd is the home folder;
/// - repository files are read from the resolved Project, never from mutable window state.
struct WorkspaceInstructionSnapshot: Equatable {

    let target: WorkspaceInstructionsTarget
    let appText: String?
    let appRevision: String?
    let projectCwd: String?
    let claudeRepositoryText: String?

    var allowsCodexRepositoryInstructions: Bool { projectCwd != nil }

    /// Mechanician-owned text uses the provider's explicit instruction channel. Claude additionally
    /// receives the one repository surface advertised by the editor; putting app text last gives
    /// the user's workspace-level policy deterministic precedence over that repository addition.
    func effectiveText(for access: ModelAccess) -> String? {
        switch access {
        case .claudeSubscription, .anthropicAPI, .claudeVertex, .claudeBedrock:
            let sections = [
                claudeRepositoryText.map {
                    "Repository instructions (CLAUDE.md):\n\($0)"
                },
                appText.map {
                    "Workspace Instructions (Mechanician):\n\($0)"
                },
            ].compactMap { $0 }
            let text = sections.joined(separator: "\n\n")
            return text.isEmpty ? nil : text
        case .codexSubscription, .openAIAPI:
            return appText
        }
    }

    /// Include workspace identity and actual delivery bytes in a stable receipt. Adapters can use it
    /// for exact prewarm compatibility; Codex additionally requires thread replacement on mismatch,
    /// while Claude can update its append while resuming.
    func sessionRevision(for access: ModelAccess) -> String {
        let material = [
            "workspace-instructions-v1",
            target.id,
            projectCwd ?? "",
            allowsCodexRepositoryInstructions ? "repository-docs:on" : "repository-docs:off",
            effectiveText(for: access) ?? "",
        ].joined(separator: "\u{1f}")
        return Self.hash(material)
    }

    static func revision(for text: String?) -> String? {
        guard let text else { return nil }
        return hash(text)
    }


    private static func hash(_ text: String) -> String {
        let bytes = Data(text.utf8)
        return SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }
}

/// Pure conversation-to-workspace identity resolution. This is intentionally independent of the
/// singleton store so the complete legacy/Home/topic/folder matrix can be tested without disk I/O.
enum WorkspaceInstructionResolver {
    static func target(
        for conversation: Conversation,
        projects: [Project]
    ) -> WorkspaceInstructionsTarget? {
        target(
            projectID: conversation.projectID,
            cwd: conversation.cwd,
            projects: projects)
    }

    static func target(
        projectID: UUID?,
        cwd: String,
        projects: [Project]
    ) -> WorkspaceInstructionsTarget? {
        WorkspaceScope.resolve(projectID: projectID, cwd: cwd, projects: projects)
    }

    static func snapshot(
        for conversation: Conversation,
        access: ModelAccess,
        projects: [Project],
        homeInstructions: String,
        claudeFileReader: (String) -> String?
    ) -> WorkspaceInstructionSnapshot? {
        guard let target = target(for: conversation, projects: projects) else { return nil }

        let rawText: String
        let projectCwd: String?
        switch target {
        case .home:
            rawText = homeInstructions
            projectCwd = nil
        case .project(let id):
            guard let project = projects.first(where: { $0.id == id }) else { return nil }
            rawText = project.instructions
            let cwd = project.cwd.trimmingCharacters(in: .whitespacesAndNewlines)
            projectCwd = cwd.isEmpty ? nil : cwd
        }

        let trimmed = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        let appText = trimmed.isEmpty ? nil : trimmed
        let readsClaudeFile: Bool
        switch access {
        case .claudeSubscription, .anthropicAPI, .claudeVertex, .claudeBedrock:
            readsClaudeFile = true
        case .codexSubscription, .openAIAPI:
            readsClaudeFile = false
        }
        let repositoryText = readsClaudeFile
            ? projectCwd.flatMap(claudeFileReader)
            : nil
        return WorkspaceInstructionSnapshot(
            target: target,
            appText: appText,
            appRevision: WorkspaceInstructionSnapshot.revision(for: appText),
            projectCwd: projectCwd,
            claudeRepositoryText: repositoryText)
    }
}
