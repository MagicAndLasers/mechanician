import Foundation

/// Classifies the files currently used by the scheduled/ambient subsystem by whether their facts
/// must survive an authority cutover. Heartbeat and lease-owner files describe one live process
/// generation; replaying either after a restore would manufacture liveness/ownership. The other
/// three sources contain user work, scheduler idempotency state, or durable run receipts.
enum LibraryAmbientAuthoritySourceKind: String, Codable, CaseIterable, Equatable {
    case taskDefinitions = "ambient_task_definitions"
    case schedulerRuntime = "ambient_scheduler_runtime"
    case runReceipts = "ambient_run_receipts"
    case heartbeat = "ambient_heartbeat"
    case schedulerLease = "ambient_scheduler_lease"

    var requiresAuthorityRepresentation: Bool {
        switch self {
        case .taskDefinitions, .schedulerRuntime, .runReceipts: true
        case .heartbeat, .schedulerLease: false
        }
    }
}

/// Exact app-owned shape of one entry in `ambient/tasks.json`. This deliberately does not use
/// `ScheduledTask` directly: that runtime/UI type also contains daemon-owned fields which the app's
/// current writer intentionally excludes from the definition source.
struct LibraryAmbientTaskDefinition: Codable, Equatable {
    let id: String
    let name: String
    let prompt: String
    let workspaceID: UUID?
    let cwd: String
    let enabled: Bool
    let trigger: AmbientTrigger
    let access: String?
    let model: String?
    let effort: String?
    let permissionMode: String?
    let createdAt: String?
    let definitionRevision: String?
    let runRequestID: String?
    /// Pre-split `tasks.json` files may still carry daemon fields inline. Both current readers
    /// deliberately accept these as migration input, so A1 must retain them rather than classifying
    /// a valid not-yet-rewritten source as an unknown-field quarantine.
    let lastRun: String?
    let lastResult: String?
    let nextRun: Double?
    let lastMtime: Double?
    let lastMailId: String?
    let runNow: Bool?
    let lastRunRequestID: String?
    let onceCompleted: Bool?
    let activeRun: AmbientActiveRun?

    init(
        id: String,
        name: String,
        prompt: String,
        workspaceID: UUID?,
        cwd: String,
        enabled: Bool,
        trigger: AmbientTrigger,
        access: String?,
        model: String?,
        effort: String?,
        permissionMode: String?,
        createdAt: String?,
        definitionRevision: String?,
        runRequestID: String?,
        lastRun: String? = nil,
        lastResult: String? = nil,
        nextRun: Double? = nil,
        lastMtime: Double? = nil,
        lastMailId: String? = nil,
        runNow: Bool? = nil,
        lastRunRequestID: String? = nil,
        onceCompleted: Bool? = nil,
        activeRun: AmbientActiveRun? = nil
    ) {
        self.id = id
        self.name = name
        self.prompt = prompt
        self.workspaceID = workspaceID
        self.cwd = cwd
        self.enabled = enabled
        self.trigger = trigger
        self.access = access
        self.model = model
        self.effort = effort
        self.permissionMode = permissionMode
        self.createdAt = createdAt
        self.definitionRevision = definitionRevision
        self.runRequestID = runRequestID
        self.lastRun = lastRun
        self.lastResult = lastResult
        self.nextRun = nextRun
        self.lastMtime = lastMtime
        self.lastMailId = lastMailId
        self.runNow = runNow
        self.lastRunRequestID = lastRunRequestID
        self.onceCompleted = onceCompleted
        self.activeRun = activeRun
    }
}

/// Exact daemon-owned value in `ambient/runtime.json`, keyed by task id. `activeRun` is the durable
/// claim-before-execute receipt; the remaining trigger watermarks and consumed request id prevent a
/// restart from replaying unattended work.
struct LibraryAmbientTaskRuntime: Codable, Equatable {
    let definitionRevision: String?
    let lastRun: String?
    let lastResult: String?
    let nextRun: Double?
    let lastMtime: Double?
    let lastMailId: String?
    let lastRunRequestID: String?
    let onceCompleted: Bool?
    let activeRun: AmbientActiveRun?
}

/// One versioned SQLite payload owns one current legacy source. It is intentionally source-shaped
/// for A1: normalizing every schedule field before authority would add migration risk without a hot
/// query benefit. Exactly one member must match `kind`; no original JSON blob is retained here.
private struct LibraryAmbientAuthorityPayload: Codable, Equatable {
    let kind: LibraryAmbientAuthoritySourceKind
    let taskDefinitions: [LibraryAmbientTaskDefinition]?
    let schedulerRuntime: [String: LibraryAmbientTaskRuntime]?
    let runReceipts: [AmbientRun]?
}

enum LibraryAmbientAuthorityAdapter {
    static let currentVersion = 1
    static let maximumSourceBytes = 16 * 1_024 * 1_024

    /// Decode a current legacy source, prove the current schema will not drop an unknown member, and
    /// emit its bounded versioned SQLite payload. Process-liveness files are rejected rather than
    /// accidentally promoted into restorable authority.
    static func capture(
        sourceData: Data,
        kind: LibraryAmbientAuthoritySourceKind
    ) throws -> (version: Int, payload: Data) {
        guard kind.requiresAuthorityRepresentation else {
            throw LibraryAuthorityAdapterError.invalidPayload(
                domain: "Ambient authority",
                detail: "\(kind.rawValue) is ephemeral process state")
        }
        try validateSize(sourceData, domain: "Ambient \(kind.rawValue) source")

        let payload: LibraryAmbientAuthorityPayload
        do {
            switch kind {
            case .taskDefinitions:
                let value = try decoder().decode(
                    [LibraryAmbientTaskDefinition].self, from: sourceData)
                try validateUniqueTaskIDs(value.map(\.id), domain: kind.rawValue)
                payload = LibraryAmbientAuthorityPayload(
                    kind: kind,
                    taskDefinitions: value,
                    schedulerRuntime: nil,
                    runReceipts: nil)
            case .schedulerRuntime:
                let value = try decoder().decode(
                    [String: LibraryAmbientTaskRuntime].self, from: sourceData)
                payload = LibraryAmbientAuthorityPayload(
                    kind: kind,
                    taskDefinitions: nil,
                    schedulerRuntime: value,
                    runReceipts: nil)
            case .runReceipts:
                let value = try decoder().decode([AmbientRun].self, from: sourceData)
                payload = LibraryAmbientAuthorityPayload(
                    kind: kind,
                    taskDefinitions: nil,
                    schedulerRuntime: nil,
                    runReceipts: value)
            case .heartbeat, .schedulerLease:
                throw LibraryAuthorityAdapterError.invalidPayload(
                    domain: "Ambient authority",
                    detail: "\(kind.rawValue) is ephemeral process state")
            }
        } catch let error as LibraryAuthorityAdapterError {
            throw error
        } catch {
            throw LibraryAuthorityAdapterError.invalidPayload(
                domain: "Ambient \(kind.rawValue)",
                detail: error.localizedDescription)
        }

        let canonicalSource = try encodeLegacy(payload)
        let loss = try LibraryCanonicalLossPreflight.compare(
            original: sourceData,
            canonical: canonicalSource)
        guard loss.isLossless else {
            throw LibraryAuthorityAdapterError.invalidPayload(
                domain: "Ambient \(kind.rawValue)", detail: loss.diagnostics)
        }
        let encoded = try encoder().encode(payload)
        try validateSize(encoded, domain: "Ambient \(kind.rawValue) payload")
        return (currentVersion, encoded)
    }

    /// Reconstruct a fresh current-generation source for rollback or read rehearsal. A future
    /// version, kind mismatch, or malformed one-of payload fails closed instead of becoming an empty
    /// task list/runtime map—the unsafe interpretation for unattended work.
    static func freshLegacyData(
        version: Int,
        payload data: Data,
        expectedKind: LibraryAmbientAuthoritySourceKind
    ) throws -> Data {
        guard expectedKind.requiresAuthorityRepresentation else {
            throw LibraryAuthorityAdapterError.invalidPayload(
                domain: "Ambient authority",
                detail: "\(expectedKind.rawValue) is ephemeral process state")
        }
        guard version == currentVersion else {
            throw LibraryAuthorityAdapterError.unsupportedPayloadVersion(
                domain: "Ambient \(expectedKind.rawValue)", version: version)
        }
        try validateSize(data, domain: "Ambient \(expectedKind.rawValue) payload")
        let payload: LibraryAmbientAuthorityPayload
        do {
            payload = try decoder().decode(LibraryAmbientAuthorityPayload.self, from: data)
        } catch {
            throw LibraryAuthorityAdapterError.invalidPayload(
                domain: "Ambient \(expectedKind.rawValue)",
                detail: error.localizedDescription)
        }
        guard payload.kind == expectedKind else {
            throw LibraryAuthorityAdapterError.invalidPayload(
                domain: "Ambient \(expectedKind.rawValue)",
                detail: "payload kind is \(payload.kind.rawValue)")
        }
        return try encodeLegacy(payload)
    }

    private static func encodeLegacy(_ payload: LibraryAmbientAuthorityPayload) throws -> Data {
        switch payload.kind {
        case .taskDefinitions:
            guard let value = payload.taskDefinitions,
                  payload.schedulerRuntime == nil,
                  payload.runReceipts == nil else {
                throw invalidOneOf(payload.kind)
            }
            try validateUniqueTaskIDs(value.map(\.id), domain: payload.kind.rawValue)
            return try legacyEncoder(prettyPrinted: true).encode(value)
        case .schedulerRuntime:
            guard payload.taskDefinitions == nil,
                  let value = payload.schedulerRuntime,
                  payload.runReceipts == nil else {
                throw invalidOneOf(payload.kind)
            }
            return try legacyEncoder(prettyPrinted: false).encode(value)
        case .runReceipts:
            guard payload.taskDefinitions == nil,
                  payload.schedulerRuntime == nil,
                  let value = payload.runReceipts else {
                throw invalidOneOf(payload.kind)
            }
            return try legacyEncoder(prettyPrinted: false).encode(value)
        case .heartbeat, .schedulerLease:
            throw LibraryAuthorityAdapterError.invalidPayload(
                domain: "Ambient authority",
                detail: "\(payload.kind.rawValue) is ephemeral process state")
        }
    }

    private static func validateUniqueTaskIDs(_ ids: [String], domain: String) throws {
        guard ids.allSatisfy({ !$0.isEmpty }), Set(ids).count == ids.count else {
            throw LibraryAuthorityAdapterError.invalidPayload(
                domain: "Ambient \(domain)", detail: "task identities are empty or duplicated")
        }
    }

    private static func validateSize(_ data: Data, domain: String) throws {
        guard data.count <= maximumSourceBytes else {
            throw LibraryAuthorityAdapterError.payloadTooLarge(
                domain: domain, bytes: data.count, limit: maximumSourceBytes)
        }
    }

    private static func invalidOneOf(
        _ kind: LibraryAmbientAuthoritySourceKind
    ) -> LibraryAuthorityAdapterError {
        .invalidPayload(
            domain: "Ambient \(kind.rawValue)",
            detail: "payload members do not match the declared source kind")
    }

    private static func encoder() -> JSONEncoder {
        let value = JSONEncoder()
        value.outputFormatting = [.sortedKeys]
        return value
    }

    private static func decoder() -> JSONDecoder { JSONDecoder() }

    private static func legacyEncoder(prettyPrinted: Bool) -> JSONEncoder {
        let value = JSONEncoder()
        value.outputFormatting = prettyPrinted ? [.prettyPrinted, .sortedKeys] : [.sortedKeys]
        return value
    }
}
