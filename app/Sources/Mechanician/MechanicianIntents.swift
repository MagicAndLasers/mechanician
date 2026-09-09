import AppIntents
import SwiftUI
import AppKit
import CoreSpotlight
import UniformTypeIdentifiers

@MainActor
private func requireStorageProductAccess() throws {
    guard StorageProductAccessGate.request() else {
        throw StorageProductUnavailableError.libraryUnavailable
    }
}

// Mechanician as an intent provider — exposes actions to Siri, Spotlight, and the Shortcuts
// app so a Claude-powered agent becomes a citizen of the OS. These run in the main app
// process (no extension), accessing the shared workspace + ambient store directly.

/// The headline: "Ask Mechanician to …" — opens the app and hands the prompt to a fresh
/// conversation.
@available(macOS 13.0, *)
struct AskMechanicianIntent: AppIntent {
    static var title: LocalizedStringResource = "Ask Mechanician"
    static var description = IntentDescription(
        "Send a prompt to Mechanician's Claude-powered agent and open the conversation.")
    static var openAppWhenRun = true

    @Parameter(title: "Prompt", requestValueDialog: "What should Mechanician do?")
    var prompt: String

    @MainActor
    func perform() async throws -> some IntentResult {
        guard ActiveWorkspace.shared.open(.newConversation(sending: prompt)) else {
            throw StorageProductUnavailableError.libraryUnavailable
        }
        return .result()
    }
}

/// Open a fresh conversation.
@available(macOS 13.0, *)
struct NewConversationIntent: AppIntent {
    static var title: LocalizedStringResource = "New Conversation"
    static var description = IntentDescription("Open a new Mechanician conversation.")
    static var openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        guard ActiveWorkspace.shared.open(.newConversation(sending: nil)) else {
            throw StorageProductUnavailableError.libraryUnavailable
        }
        return .result()
    }
}

// MARK: - Conversations & Artifacts as entities

/// A Mechanician conversation exposed to Siri / Spotlight / Shortcuts as a pickable entity.
@available(macOS 13.0, *)
struct ConversationEntity: AppEntity {
    static var typeDisplayRepresentation = TypeDisplayRepresentation(name: "Conversation")
    static var defaultQuery = ConversationEntityQuery()

    var id: UUID
    var name: String
    var folder: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)", subtitle: folder.isEmpty ? nil : "\(folder)")
    }
    init(_ c: IndexedConversation) { id = c.id; name = c.displayTitle; folder = c.cwdName }
}

@available(macOS 13.0, *)
struct ConversationEntityQuery: EntityQuery {
    @MainActor
    func entities(for identifiers: [UUID]) async throws -> [ConversationEntity] {
        try requireStorageProductAccess()
        return ConversationIndex.all().filter { identifiers.contains($0.id) }
            .map(ConversationEntity.init)
    }
    @MainActor
    func suggestedEntities() async throws -> [ConversationEntity] {
        try requireStorageProductAccess()
        return ConversationIndex.all().prefix(25).map(ConversationEntity.init)
    }
}

/// Lets Siri match a spoken/typed conversation name ("open my <name> conversation").
@available(macOS 13.0, *)
extension ConversationEntityQuery: EntityStringQuery {
    @MainActor
    func entities(matching string: String) async throws -> [ConversationEntity] {
        try requireStorageProductAccess()
        return ConversationIndex.all().filter {
            $0.displayTitle.localizedCaseInsensitiveContains(string)
                || $0.cwdName.localizedCaseInsensitiveContains(string)
        }.map(ConversationEntity.init)
    }
}

/// Golden Gate: donating the entity to Spotlight's SEMANTIC index (via SpotlightIndex's
/// associateAppEntity) lets Siri/Spotlight match conversations by MEANING and act on them through
/// the App Intents — not just keyword. `attributeSet` is the entity's searchable representation.
@available(macOS 15.0, *)
extension ConversationEntity: IndexedEntity {
    var attributeSet: CSSearchableItemAttributeSet {
        let a = CSSearchableItemAttributeSet(contentType: .text)
        a.title = name
        a.contentDescription = folder.isEmpty ? "Mechanician conversation" : "Conversation · \(folder)"
        a.keywords = ["Mechanician", "conversation", folder].filter { !$0.isEmpty }
        return a
    }
}

/// A Mechanician artifact (HTML/SVG/Mermaid/CSV/Markdown) exposed as a pickable entity.
@available(macOS 13.0, *)
struct ArtifactEntity: AppEntity {
    static var typeDisplayRepresentation = TypeDisplayRepresentation(name: "Artifact")
    static var defaultQuery = ArtifactEntityQuery()

    var id: UUID
    var name: String
    var kind: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)", subtitle: "\(kind)")
    }
    init(_ a: IndexedArtifact) { id = a.id; name = a.displayTitle; kind = a.type }
}

@available(macOS 13.0, *)
struct ArtifactEntityQuery: EntityQuery {
    @MainActor
    func entities(for identifiers: [UUID]) async throws -> [ArtifactEntity] {
        try requireStorageProductAccess()
        return ArtifactIndex.all().filter { identifiers.contains($0.id) }.map(ArtifactEntity.init)
    }
    @MainActor
    func suggestedEntities() async throws -> [ArtifactEntity] {
        try requireStorageProductAccess()
        return ArtifactIndex.all().prefix(25).map(ArtifactEntity.init)
    }
}

@available(macOS 13.0, *)
extension ArtifactEntityQuery: EntityStringQuery {
    @MainActor
    func entities(matching string: String) async throws -> [ArtifactEntity] {
        try requireStorageProductAccess()
        return ArtifactIndex.all().filter {
            $0.displayTitle.localizedCaseInsensitiveContains(string)
        }
            .map(ArtifactEntity.init)
    }
}

@available(macOS 15.0, *)
extension ArtifactEntity: IndexedEntity {
    var attributeSet: CSSearchableItemAttributeSet {
        let a = CSSearchableItemAttributeSet(contentType: .text)
        a.title = name
        a.contentDescription = "\(kind) artifact"
        a.keywords = ["Mechanician", "artifact", kind].filter { !$0.isEmpty }
        return a
    }
}

/// Open a specific conversation.
@available(macOS 13.0, *)
struct OpenConversationIntent: AppIntent {
    static var title: LocalizedStringResource = "Open Conversation"
    static var description = IntentDescription("Open a specific Mechanician conversation.")
    static var openAppWhenRun = true

    @Parameter(title: "Conversation")
    var conversation: ConversationEntity

    @MainActor
    func perform() async throws -> some IntentResult {
        guard ActiveWorkspace.shared.open(.conversation(conversation.id)) else {
            throw StorageProductUnavailableError.libraryUnavailable
        }
        return .result()
    }
}

/// Open a specific artifact in the Artifacts window.
@available(macOS 13.0, *)
struct OpenArtifactIntent: AppIntent {
    static var title: LocalizedStringResource = "Open Artifact"
    static var description = IntentDescription("Open a specific Mechanician artifact.")
    static var openAppWhenRun = true

    @Parameter(title: "Artifact")
    var artifact: ArtifactEntity

    @MainActor
    func perform() async throws -> some IntentResult {
        guard ActiveWorkspace.shared.open(.artifact(artifact.id)) else {
            throw StorageProductUnavailableError.libraryUnavailable
        }
        return .result()
    }
}

/// Run one of the ambient/scheduled tasks now. Uses an AppEntity so Shortcuts/Siri offer a
/// task picker.
@available(macOS 13.0, *)
struct RunScheduledTaskIntent: AppIntent {
    static var title: LocalizedStringResource = "Run a Scheduled Task"
    static var description = IntentDescription("Run one of Mechanician's ambient tasks now.")

    @Parameter(title: "Task")
    var task: ScheduledTaskEntity

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        try requireStorageProductAccess()
        if ManagedEnterprisePolicy.current?.allowsUnattendedWork() == false {
            return .result(dialog: "Scheduled tasks are disabled by your organization.")
        }
        if let stored = AmbientStore.shared.tasks.first(where: { $0.id == task.id }),
           !stored.resolvedAccess.isAllowedByEnterprisePolicy {
            return .result(dialog: "This task's provider is blocked by your organization.")
        }
        guard AmbientStore.shared.runNow(task.id) else {
            return .result(dialog: "Choose a regular workspace for “\(task.name)” before running it.")
        }
        return .result(dialog: "Running “\(task.name)” now.")
    }
}

/// A scheduled task exposed to the intents system (so it can be picked in Shortcuts).
@available(macOS 13.0, *)
struct ScheduledTaskEntity: AppEntity {
    static var typeDisplayRepresentation = TypeDisplayRepresentation(name: "Scheduled Task")
    static var defaultQuery = ScheduledTaskQuery()

    var id: String
    var name: String

    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(name)") }
}

@available(macOS 13.0, *)
struct ScheduledTaskQuery: EntityQuery {
    @MainActor
    func entities(for identifiers: [String]) async throws -> [ScheduledTaskEntity] {
        try requireStorageProductAccess()
        return AmbientStore.shared.tasks
            .filter { identifiers.contains($0.id) }
            .map { ScheduledTaskEntity(id: $0.id, name: $0.name) }
    }

    @MainActor
    func suggestedEntities() async throws -> [ScheduledTaskEntity] {
        try requireStorageProductAccess()
        return AmbientStore.shared.tasks.map { ScheduledTaskEntity(id: $0.id, name: $0.name) }
    }
}

/// A workspace is required for unattended work so the scheduler has an explicit filesystem and
/// instruction boundary instead of falling back to the user's home directory.
@available(macOS 13.0, *)
struct WorkspaceEntity: AppEntity {
    static var typeDisplayRepresentation = TypeDisplayRepresentation(name: "Workspace")
    static var defaultQuery = WorkspaceEntityQuery()

    var id: UUID
    var name: String
    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(name)") }

    init(_ project: Project) { id = project.id; name = project.displayName }
}

@available(macOS 13.0, *)
struct WorkspaceEntityQuery: EntityQuery {
    @MainActor
    func entities(for identifiers: [UUID]) async throws -> [WorkspaceEntity] {
        try requireStorageProductAccess()
        return AmbientTaskWorkspacePolicy.selectableProjects(ProjectStore.shared.projects)
            .filter { identifiers.contains($0.id) }
            .map(WorkspaceEntity.init)
    }

    @MainActor
    func suggestedEntities() async throws -> [WorkspaceEntity] {
        try requireStorageProductAccess()
        return AmbientTaskWorkspacePolicy.selectableProjects(ProjectStore.shared.projects)
            .map(WorkspaceEntity.init)
    }
}

/// "Schedule <something> at <time>" from Siri/Shortcuts — creates a one-shot ambient task that
/// runs the full agent once at the given moment, without opening the app.
@available(macOS 13.0, *)
struct ScheduleEventIntent: AppIntent {
    static var title: LocalizedStringResource = "Schedule a One-Time Task"
    static var description = IntentDescription(
        "Have Mechanician's agent run a prompt once at a specific date and time. The result arrives as a notification and a conversation.")

    @Parameter(title: "What should the agent do?", requestValueDialog: "What should Mechanician do?")
    var prompt: String

    @Parameter(title: "When", requestValueDialog: "When should it run?")
    var date: Date

    @Parameter(title: "Workspace", requestValueDialog: "Which workspace should the task use?")
    var workspace: WorkspaceEntity

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        try requireStorageProductAccess()
        let task = ScheduledTask(
            name: Self.shortName(from: prompt),
            prompt: prompt,
            workspaceID: workspace.id,
            trigger: AmbientTrigger(type: "time",
                                    schedule: AmbientSchedule(kind: "once",
                                                              at: ISO8601DateFormatter().string(from: date))),
            permissionMode: "dontAsk",
            createdAt: ISO8601DateFormatter().string(from: Date()))
        if ManagedEnterprisePolicy.current?.allowsUnattendedWork() == false {
            return .result(dialog: "Scheduled tasks are disabled by your organization.")
        }
        if !task.resolvedAccess.isAllowedByEnterprisePolicy {
            return .result(dialog: "The default scheduled-task provider is blocked by your organization.")
        }
        guard AmbientStore.shared.upsert(task) else {
            return .result(dialog: "Choose a regular workspace before scheduling this task.")
        }
        let when = date.formatted(date: .abbreviated, time: .shortened)
        return .result(dialog: "Scheduled for \(when).")
    }

    static func shortName(from prompt: String) -> String {
        let words = prompt.split(separator: " ").prefix(6).joined(separator: " ")
        return words.isEmpty ? "Scheduled task" : String(words)
    }
}

/// "Watch this file/folder" from Siri/Shortcuts — creates a standing watch task: whenever the
/// path changes, the agent runs the prompt. Shortcuts can feed the path from a file action.
@available(macOS 13.0, *)
struct AddWatchIntent: AppIntent {
    static var title: LocalizedStringResource = "Watch a File or Folder"
    static var description = IntentDescription(
        "Have Mechanician's agent run a prompt whenever a file or folder changes. Results arrive as notifications and conversations.")

    @Parameter(title: "File or folder path", requestValueDialog: "Which file or folder should I watch?")
    var path: String

    @Parameter(title: "What should the agent do when it changes?",
               requestValueDialog: "What should Mechanician do when it changes?")
    var prompt: String

    @Parameter(title: "Workspace", requestValueDialog: "Which workspace should the task use?")
    var workspace: WorkspaceEntity

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        try requireStorageProductAccess()
        let expanded = (path as NSString).expandingTildeInPath
        guard FileManager.default.fileExists(atPath: expanded) else {
            return .result(dialog: "I can't find \(path). Nothing was created.")
        }
        var task = AmbientStore.watchTask(path: expanded, workspaceID: workspace.id, prompt: prompt)
        task.createdAt = ISO8601DateFormatter().string(from: Date())
        task.permissionMode = "dontAsk"
        if ManagedEnterprisePolicy.current?.allowsUnattendedWork() == false {
            return .result(dialog: "Scheduled tasks are disabled by your organization.")
        }
        if !task.resolvedAccess.isAllowedByEnterprisePolicy {
            return .result(dialog: "The default scheduled-task provider is blocked by your organization.")
        }
        guard AmbientStore.shared.upsert(task) else {
            return .result(dialog: "Choose a regular workspace before creating this watch.")
        }
        return .result(dialog: "Watching \((expanded as NSString).lastPathComponent) . I'll run your instruction whenever it changes.")
    }
}

/// Registers the App Shortcuts so they appear in Spotlight and the Shortcuts gallery with
/// spoken phrases — no user setup required.
@available(macOS 13.0, *)
struct MechanicianShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: AskMechanicianIntent(),
            phrases: [
                "Ask \(.applicationName)",
                "Ask \(.applicationName) to \(\.$prompt)",
            ],
            shortTitle: "Ask Mechanician",
            systemImageName: "sparkles")
        AppShortcut(
            intent: NewConversationIntent(),
            phrases: ["New \(.applicationName) conversation"],
            shortTitle: "New Conversation",
            systemImageName: "plus.bubble")
        AppShortcut(
            intent: RunScheduledTaskIntent(),
            phrases: ["Run a \(.applicationName) task"],
            shortTitle: "Run Scheduled Task",
            systemImageName: "clock.arrow.circlepath")
        AppShortcut(
            intent: ScheduleEventIntent(),
            phrases: [
                "Schedule a task in \(.applicationName)",
                "Schedule \(.applicationName) to \(\.$prompt)",
            ],
            shortTitle: "Schedule Task",
            systemImageName: "calendar.badge.clock")
        AppShortcut(
            intent: AddWatchIntent(),
            phrases: [
                "Watch a file in \(.applicationName)",
                "Have \(.applicationName) watch a folder",
            ],
            shortTitle: "Watch File or Folder",
            systemImageName: "eye")
        AppShortcut(
            intent: OpenConversationIntent(),
            phrases: [
                "Open a \(.applicationName) conversation",
                "Open the \(\.$conversation) conversation in \(.applicationName)",
            ],
            shortTitle: "Open Conversation",
            systemImageName: "bubble.left.and.bubble.right")
        AppShortcut(
            intent: OpenArtifactIntent(),
            phrases: [
                "Open a \(.applicationName) artifact",
                "Open the \(\.$artifact) artifact in \(.applicationName)",
            ],
            shortTitle: "Open Artifact",
            systemImageName: "doc.richtext")
    }
}
