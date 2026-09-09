import Combine
import Foundation

/// Immutable app-owned identity for the exact provider turn whose callable surface was observed.
/// None of these fields comes from a model-supplied conversation or cwd parameter: AgentBridge
/// stamps them from the already-authorized TurnRoute and runtime that accepted the callback.
struct AgentToolSurfaceRoute: Equatable, Hashable {
    let bridgeID: UUID
    let runtimeGeneration: UUID
    let conversationID: UUID
    let turnID: String
    let selection: ModelSelection
    let accountInstanceID: ProviderAccountInstanceID
    let credentialEpoch: Int
    let providerRouteIdentity: String
    let workspaceIdentity: String
    let canonicalCWD: String
    let toolProfile: ProviderToolProfile
    let permissionMode: String
    let providerSessionRevision: UUID
    let workspaceInstructionsRevision: String
}

enum AgentToolSurfaceCoverage: String, Equatable, Hashable, Sendable {
    /// The report enumerates the complete callable provider surface for this turn.
    case complete
    /// The report completely enumerates Mechanician-injected tools, while provider-native tools
    /// (notably Codex file/shell abilities) are not exposed by the provider as a complete list.
    case mechanicianSupplied = "mechanician-supplied"
}

enum AgentToolSurfaceProvenance: String, Equatable, Hashable, Sendable {
    case providerInit = "provider-init"
    case mechanicianAPIRequest = "mechanician-api-request"
    case mechanicianCodexThread = "mechanician-codex-thread"
}

struct AgentToolSurfaceSnapshot: Equatable {
    enum Phase: Equatable {
        case discovering
        case ready
        case failed(String)
    }

    let route: AgentToolSurfaceRoute
    var phase: Phase
    var rawToolNames: [String]
    var coverage: AgentToolSurfaceCoverage?
    var provenance: AgentToolSurfaceProvenance?
    var adapterRevision: String?
    var updatedAt: Date
    var isActiveEvidence: Bool = true
}

/// Workflow evaluation deliberately has a fourth state. Partial evidence is not the same as
/// absence, and forcing it into unavailable would make Codex advice confidently wrong.
enum AgentWorkflowReadiness: Equatable, Sendable {
    case ready(mayRequestApproval: Bool)
    case needsModeChange
    case unavailableHere
    case notVerified
}

/// Per-bridge, ephemeral capability authority. A bridge owns one daemon pool per window, so
/// process-global state would let whichever window reported last overwrite every other one.
/// Records are intentionally not persisted: a provider/account/configuration boundary makes live
/// capability evidence stale even when the conversation transcript itself remains durable.
@MainActor
final class AgentToolCatalog: ObservableObject {
    struct WireReport: Equatable {
        let tools: [String]
        let coverage: AgentToolSurfaceCoverage
        let provenance: AgentToolSurfaceProvenance
    }

    static let adapterRevision = "mechanician-tool-surface-v1"
    static let maximumTools = 512
    static let maximumToolNameBytes = 512
    /// Mirrors agentd's complete serialized-event ceiling. The bridge checks the full decoded
    /// object before interpreting it, while `publish` independently bounds the retained names so
    /// a direct/test caller cannot bypass the same budget.
    static let maximumWirePayloadBytes = 64 * 1024
    static let maximumRecords = 128
    static let wireFieldNames: Set<String> = [
        "type", "id", "lane", "toolProfile", "permissionMode", "coverage", "provenance",
        "adapterRevision", "tools",
    ]

    @Published private(set) var snapshots: [UUID: AgentToolSurfaceSnapshot] = [:]

    init() {}

    func begin(route: AgentToolSurfaceRoute, at date: Date = Date()) {
        snapshots[route.conversationID] = AgentToolSurfaceSnapshot(
            route: route,
            phase: .discovering,
            rawToolNames: [],
            coverage: nil,
            provenance: nil,
            adapterRevision: nil,
            updatedAt: date,
            isActiveEvidence: true)
        pruneIfNeeded()
    }

    @discardableResult
    func publish(
        tools: [String],
        coverage: AgentToolSurfaceCoverage,
        provenance: AgentToolSurfaceProvenance,
        adapterRevision: String,
        for route: AgentToolSurfaceRoute,
        at date: Date = Date()
    ) -> Bool {
        guard adapterRevision == Self.adapterRevision,
              tools.count <= Self.maximumTools,
              Set(tools).count == tools.count,
              Self.retainedToolPayloadBytes(tools) <= Self.maximumWirePayloadBytes,
              tools.allSatisfy(Self.toolNameIsAdmissible),
              let current = snapshots[route.conversationID],
              current.route == route,
              current.phase == .discovering else { return false }
        let normalized = tools.sorted()
        snapshots[route.conversationID] = AgentToolSurfaceSnapshot(
            route: route,
            phase: .ready,
            rawToolNames: normalized,
            coverage: coverage,
            provenance: provenance,
            adapterRevision: adapterRevision,
            updatedAt: date,
            isActiveEvidence: true)
        return true
    }

    @discardableResult
    func failIfDiscovering(
        route: AgentToolSurfaceRoute,
        message: String,
        at date: Date = Date()
    ) -> Bool {
        guard let current = snapshots[route.conversationID],
              current.route == route,
              current.phase == .discovering else { return false }
        var failed = current
        failed.phase = .failed(message)
        failed.rawToolNames = []
        failed.updatedAt = date
        failed.isActiveEvidence = false
        snapshots[route.conversationID] = failed
        return true
    }

    func finish(route: AgentToolSurfaceRoute) {
        guard var current = snapshots[route.conversationID], current.route == route else { return }
        if current.phase == .discovering {
            current.phase = .failed(String(
                localized: "The provider finished without reporting its callable tools."))
            current.rawToolNames = []
        }
        current.isActiveEvidence = false
        current.updatedAt = Date()
        snapshots[route.conversationID] = current
    }

    func snapshot(for conversationID: UUID) -> AgentToolSurfaceSnapshot? {
        snapshots[conversationID]
    }

    func invalidate(conversationID: UUID) {
        snapshots[conversationID] = nil
    }

    func invalidate(access: ModelAccess, generation: UUID? = nil) {
        snapshots = snapshots.filter { _, snapshot in
            guard snapshot.route.selection.access == access else { return true }
            if let generation { return snapshot.route.runtimeGeneration != generation }
            return false
        }
    }

    private func pruneIfNeeded() {
        guard snapshots.count > Self.maximumRecords else { return }
        let excess = snapshots.count - Self.maximumRecords
        for id in snapshots.values.sorted(by: { $0.updatedAt < $1.updatedAt })
            .prefix(excess).map(\.route.conversationID) {
            snapshots[id] = nil
        }
    }

    /// Validate the complete wire object, including fields this app version does not interpret.
    /// Extra attacker-controlled data must not get a free pass merely because the retained `tools`
    /// array is small. Failure is non-destructive: the exact route remains discovering until its
    /// terminal boundary reports that no admissible surface arrived.
    static func wirePayloadIsWithinBounds(_ event: [String: Any]) -> Bool {
        guard JSONSerialization.isValidJSONObject(event),
              let data = try? JSONSerialization.data(withJSONObject: event) else { return false }
        return data.count <= maximumWirePayloadBytes
    }

    static func wireShapeIsAdmissible(_ event: [String: Any]) -> Bool {
        Set(event.keys) == wireFieldNames && wirePayloadIsWithinBounds(event)
    }

    static func decodeWireReport(
        _ event: [String: Any],
        expectedTurnID: String,
        expectedLane: String,
        expectedToolProfile: ProviderToolProfile,
        expectedPermissionMode: String,
        expectedCoverage: AgentToolSurfaceCoverage,
        expectedProvenance: AgentToolSurfaceProvenance
    ) -> WireReport? {
        guard wireShapeIsAdmissible(event),
              event["type"] as? String == "tool_surface",
              event["id"] as? String == expectedTurnID,
              event["lane"] as? String == expectedLane,
              event["toolProfile"] as? String == expectedToolProfile.rawValue,
              event["permissionMode"] as? String == expectedPermissionMode,
              event["adapterRevision"] as? String == adapterRevision,
              event["coverage"] as? String == expectedCoverage.rawValue,
              event["provenance"] as? String == expectedProvenance.rawValue,
              let tools = event["tools"] as? [String],
              tools.count <= maximumTools,
              Set(tools).count == tools.count,
              retainedToolPayloadBytes(tools) <= maximumWirePayloadBytes,
              tools.allSatisfy(toolNameIsAdmissible) else { return nil }
        return WireReport(
            tools: tools,
            coverage: expectedCoverage,
            provenance: expectedProvenance)
    }

    private static func retainedToolPayloadBytes(_ tools: [String]) -> Int {
        tools.reduce(into: 0) { total, name in
            // Include JSON array/string punctuation conservatively as retained payload overhead.
            total += name.lengthOfBytes(using: .utf8) + 3
        }
    }

    private static func toolNameIsAdmissible(_ name: String) -> Bool {
        guard !name.isEmpty,
              name.lengthOfBytes(using: .utf8) <= maximumToolNameBytes,
              name == name.trimmingCharacters(in: .whitespacesAndNewlines) else { return false }
        return name.unicodeScalars.allSatisfy { scalar in
            scalar.value > 0x1F && scalar.value != 0x7F
        }
    }

    // MARK: Workflow-facing evaluation

    func readiness(
        requiring canonicalToolIDs: Set<String>,
        requiresExecutionMode: Bool,
        snapshot: AgentToolSurfaceSnapshot?
    ) -> AgentWorkflowReadiness {
        // An empty requirement set is not a workflow proof: every surface would satisfy it
        // vacuously. Closed product workspaces are deliberately advisory/editor authorities and
        // cannot be promoted into an executable workflow route even when a named tool is present.
        guard !canonicalToolIDs.isEmpty else { return .notVerified }
        guard let snapshot, snapshot.phase == .ready else { return .notVerified }
        guard snapshot.route.toolProfile == .standard else { return .unavailableHere }
        let present = Set(snapshot.rawToolNames.compactMap(Self.canonicalCapabilityID))
        guard canonicalToolIDs.isSubset(of: present) else {
            return snapshot.coverage == .complete ? .unavailableHere : .notVerified
        }
        if requiresExecutionMode, snapshot.route.permissionMode == "plan" {
            return .needsModeChange
        }
        return .ready(mayRequestApproval: snapshot.route.permissionMode != "bypassPermissions")
    }

    func workflowAssessment(
        for demonstration: MechanicianHelpDemonstration,
        snapshot: AgentToolSurfaceSnapshot?
    ) -> MechanicianWorkflowCapabilityAssessment {
        let required = Set(demonstration.requirements.tools)
        let present = Set(snapshot?.rawToolNames.compactMap(Self.canonicalCapabilityID) ?? [])
        var workflowReadiness = readiness(
            requiring: required,
            requiresExecutionMode:
                demonstration.requirements.mode == .executionEnabled,
            snapshot: snapshot)
        // The signed recipe mode is the app-owned effect class. Inventory probes and additive
        // artifact previews are auto-allowed by runtime policy even in Plan; only an
        // execution-enabled external action may still ask for Mechanician approval.
        if case .ready = workflowReadiness {
            workflowReadiness = .ready(
                mayRequestApproval:
                    demonstration.requirements.mode == .executionEnabled)
        }
        return MechanicianWorkflowCapabilityAssessment(
            readiness: workflowReadiness,
            unobservedRequiredToolIDs: required.subtracting(present).sorted())
    }

    // MARK: Pure presentation

    struct Group: Identifiable, Equatable {
        let id: String
        let title: String
        let detail: String
        let symbol: String
        let tools: [String]
    }

    nonisolated private static let groupings: [(
        id: String, title: String, detail: String, symbol: String, match: [String]
    )] = [
        ("files", "Read and change files",
         "Open, search, edit and create files in the current workspace.",
         "doc.text", ["Read", "Write", "Edit", "ListFiles", "SearchFiles", "Glob", "Grep", "NotebookEdit"]),
        ("shell", "Run commands", "Run shell commands, build, and test.",
         "terminal", ["Bash", "BashOutput", "KillShell", "Build"]),
        ("web", "Search and read the web", "Look things up and read pages.",
         "globe", ["WebSearch", "WebFetch"]),
        ("help", "Understand Mechanician",
         "Search the signed product guide, present reviewed Mechanician interface guidance, and operate the app's own panels and windows on request.",
         "questionmark.circle", ["SearchMechanicianHelp", "ShowMechanician",
                                  "OperateMechanician", "RecommendMechanicianWorkflow"]),
        ("mac", "Work the apps on this Mac",
         "Drive Mac apps with AppleScript, run your Shortcuts, and see the screen.",
         "macwindow", ["RunAppleScript", "ListShortcuts", "RunShortcut", "DiscoverAppActions",
                       "RunCapability", "ListCapabilities", "SaveCapability",
                       "ComputerScreenshot", "ComputerAction", "ComputerClick", "ComputerType",
                       "ComputerKey", "ComputerScroll", "ComputerWait", "ComputerReadUI",
                       "ComputerLaunchApp", "ComputerFrontmostApp", "ComputerMove", "ComputerDrag",
                       "ComputerRightClick", "ComputerDoubleClick", "ComputerClipboardGet",
                       "ComputerClipboardSet"]),
        ("make", "Make documents and artifacts",
         "Produce pages, diagrams, tables and documents you can open.",
         "square.on.square", ["CreateOrUpdateArtifact", "Artifact"]),
        ("ask", "Ask you a question", "Stop and ask when a decision is genuinely yours.",
         "questionmark.bubble", ["Question", "AskUserQuestion"]),
        ("wait", "Wait for something to happen",
         "Pause for a build, a deploy, or a file to appear, then carry on.",
         "clock", ["WaitFor", "Monitor"]),
        ("schedule", "Schedule work for later",
         "Run something on a schedule, or once at a chosen time.",
         "calendar.badge.clock", ["ScheduleTask", "CronCreate", "CronList", "CronDelete",
                                  "ListScheduledTasks", "SetScheduledTaskEnabled",
                                  "DeleteScheduledTask"]),
        ("agents", "Delegate to other agents", "Split work across subagents and run multi-step workflows.",
         "person.2", ["Agent", "Task", "Workflow", "SendMessage", "TaskCreate", "TaskUpdate",
                      "TaskList", "TaskGet", "TaskOutput", "TaskStop"]),
    ]

    nonisolated private static let appOwnedAliases: [String: String] = {
        let servers: [String: [String]] = [
            "help": ["SearchMechanicianHelp", "ShowMechanician", "OperateMechanician",
                     "RecommendMechanicianWorkflow"],
            "artifacts": ["CreateOrUpdateArtifact"],
            "automation": ["RunAppleScript"],
            "shortcuts": ["ListShortcuts", "RunShortcut", "DiscoverAppActions"],
            "capabilities": ["ListCapabilities", "RunCapability", "SaveCapability"],
            "dev": ["Build"],
            "computer": ["ComputerScreenshot", "ComputerAction", "ComputerClick", "ComputerType",
                         "ComputerKey", "ComputerScroll", "ComputerWait", "ComputerReadUI",
                         "ComputerLaunchApp", "ComputerFrontmostApp", "ComputerMove", "ComputerDrag",
                         "ComputerRightClick", "ComputerDoubleClick", "ComputerClipboardGet",
                         "ComputerClipboardSet"],
            "ask": ["Question"],
            "provider_access": ["RequestProviderAccess"],
            "waitmode": ["WaitFor"],
            "scheduler": ["ScheduleTask", "ListScheduledTasks", "SetScheduledTaskEnabled",
                          "DeleteScheduledTask"],
        ]
        return Dictionary(uniqueKeysWithValues: servers.flatMap { server, tools in
            tools.map { ("mcp__\(server)__\($0)", $0) }
        })
    }()

    nonisolated private static let groupedCanonicalIDs = Set(groupings.flatMap(\.match))
    /// Closed mapping only. An arbitrary MCP suffix can never impersonate an app-owned ability.
    nonisolated static func canonicalCapabilityID(for raw: String) -> String? {
        if let known = appOwnedAliases[raw] { return known }
        guard !raw.hasPrefix("mcp__") else { return nil }
        return groupedCanonicalIDs.contains(raw) ? raw : nil
    }

    static func groups(for snapshot: AgentToolSurfaceSnapshot) -> [Group] {
        let present = Set(snapshot.rawToolNames.compactMap(canonicalCapabilityID))
        return groupings.compactMap { spec in
            let matched = spec.match.filter(present.contains)
            guard !matched.isEmpty else { return nil }
            return Group(
                id: spec.id, title: spec.title, detail: spec.detail,
                symbol: spec.symbol, tools: matched.sorted())
        }
    }

    static func ungroupedTools(in snapshot: AgentToolSurfaceSnapshot) -> [String] {
        snapshot.rawToolNames.filter { canonicalCapabilityID(for: $0) == nil }.sorted()
    }

    static func contains(_ canonicalID: String, in snapshot: AgentToolSurfaceSnapshot) -> Bool {
        snapshot.rawToolNames.contains { canonicalCapabilityID(for: $0) == canonicalID }
    }
}
