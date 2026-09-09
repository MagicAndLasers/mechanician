import CryptoKit
import Dispatch
import Foundation

/// Errors at the SQLite/runtime boundary must fail closed. A corrupt or newer payload is recovery
/// input, never permission to manufacture a partially empty Conversation or Workspace.
enum LibraryAuthorityAdapterError: Error, Equatable, LocalizedError {
    case unsupportedPayloadVersion(domain: String, version: Int)
    case payloadTooLarge(domain: String, bytes: Int, limit: Int)
    case invalidPayload(domain: String, detail: String)
    case unsupportedEventKind(String)
    case invalidEvent(String)
    case unresolvedWorkspace(UUID)

    var errorDescription: String? {
        switch self {
        case .unsupportedPayloadVersion(let domain, let version):
            return "Unsupported \(domain) payload version \(version)."
        case .payloadTooLarge(let domain, let bytes, let limit):
            return "\(domain) payload is \(bytes) bytes; the limit is \(limit)."
        case .invalidPayload(let domain, let detail):
            return "Invalid \(domain) payload: \(detail)"
        case .unsupportedEventKind(let kind):
            return "Unsupported Conversation event kind \(kind)."
        case .invalidEvent(let detail):
            return "Invalid Conversation event: \(detail)"
        case .unresolvedWorkspace(let id):
            return "Unresolved Workspace \(id.uuidString) cannot be emitted as a live legacy record."
        }
    }
}

/// The Conversation fields that are durable today but are neither row metadata nor canonical
/// retained-history events. This is deliberately a small, versioned operative payload rather than
/// a second encoded `Conversation`: dialog, agents, workflow/activity history, artifacts, identity,
/// presentation flags, membership and timestamps each have one relational/event owner elsewhere.
///
/// The inventory mirrors every remaining `Conversation.CodingKeys` member:
/// - provider recovery: sdk session and its route/configuration/instruction revisions;
/// - user work: draft, suggested follow-up, accepted-but-unacknowledged prompt, FIFO queue and armed wait;
/// - provider-access recovery and Conversation-scoped Claude preferences/effective model; and
/// - the exact legacy optional `projectID`, retained only for pre-activation parity/down-conversion.
///
/// `awaitingQuestion`, `needsStaleStatePersistence`, and `ArmedTrigger.lastCheckedAt` are excluded
/// because the current runtime explicitly does not persist them across relaunch.
struct LibraryConversationLocalStatePayload: Codable, Equatable {
    static let currentVersion = 1
    static let maximumEncodedBytes = 32 * 1_024 * 1_024

    let sdkSessionID: String?
    let sdkSessionRouteIdentity: String?
    let sdkSessionExtensionRevision: UUID?
    let sdkSessionToolProfile: ProviderToolProfile?
    let sdkSessionWorkspaceInstructionsRevision: String?
    let queuedPrompts: [String]
    let pendingTurnPrompt: String?
    let draft: String
    let suggestedPrompt: ConversationSuggestedPrompt?
    let armedTrigger: ArmedTrigger?
    let providerAccessRequest: ProviderAccessRequest?
    let claudePreferences: ClaudeSessionPreferences?
    let claudeEffectiveModel: String?
    let legacyProjectID: UUID?

    init(
        sdkSessionID: String?,
        sdkSessionRouteIdentity: String?,
        sdkSessionExtensionRevision: UUID?,
        sdkSessionToolProfile: ProviderToolProfile?,
        sdkSessionWorkspaceInstructionsRevision: String?,
        queuedPrompts: [String],
        pendingTurnPrompt: String?,
        draft: String,
        suggestedPrompt: ConversationSuggestedPrompt? = nil,
        armedTrigger: ArmedTrigger?,
        providerAccessRequest: ProviderAccessRequest?,
        claudePreferences: ClaudeSessionPreferences?,
        claudeEffectiveModel: String?,
        legacyProjectID: UUID?
    ) {
        self.sdkSessionID = sdkSessionID
        self.sdkSessionRouteIdentity = sdkSessionRouteIdentity
        self.sdkSessionExtensionRevision = sdkSessionExtensionRevision
        self.sdkSessionToolProfile = sdkSessionToolProfile
        self.sdkSessionWorkspaceInstructionsRevision =
            sdkSessionWorkspaceInstructionsRevision
        self.queuedPrompts = queuedPrompts
        self.pendingTurnPrompt = pendingTurnPrompt
        self.draft = draft
        self.suggestedPrompt = suggestedPrompt
        self.armedTrigger = armedTrigger
        self.providerAccessRequest = providerAccessRequest
        self.claudePreferences = claudePreferences
        self.claudeEffectiveModel = claudeEffectiveModel
        self.legacyProjectID = legacyProjectID
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        sdkSessionID = try c.decodeIfPresent(String.self, forKey: .sdkSessionID)
        sdkSessionRouteIdentity = try c.decodeIfPresent(
            String.self, forKey: .sdkSessionRouteIdentity)
        sdkSessionExtensionRevision = try c.decodeIfPresent(
            UUID.self, forKey: .sdkSessionExtensionRevision)
        sdkSessionToolProfile = try? c.decodeIfPresent(
            ProviderToolProfile.self, forKey: .sdkSessionToolProfile)
        sdkSessionWorkspaceInstructionsRevision = try c.decodeIfPresent(
            String.self, forKey: .sdkSessionWorkspaceInstructionsRevision)
        queuedPrompts = try c.decode([String].self, forKey: .queuedPrompts)
        pendingTurnPrompt = try c.decodeIfPresent(String.self, forKey: .pendingTurnPrompt)
        draft = try c.decode(String.self, forKey: .draft)
        // Suggested text is presentation help, not authority admission. A future/invalid optional
        // record must never make the entire Conversation local-state payload unreadable.
        suggestedPrompt = (try? c.decodeIfPresent(
            ConversationSuggestedPrompt.self, forKey: .suggestedPrompt)) ?? nil
        armedTrigger = try c.decodeIfPresent(ArmedTrigger.self, forKey: .armedTrigger)
        providerAccessRequest = try c.decodeIfPresent(
            ProviderAccessRequest.self, forKey: .providerAccessRequest)
        claudePreferences = try c.decodeIfPresent(
            ClaudeSessionPreferences.self, forKey: .claudePreferences)
        claudeEffectiveModel = try c.decodeIfPresent(
            String.self, forKey: .claudeEffectiveModel)
        legacyProjectID = try c.decodeIfPresent(UUID.self, forKey: .legacyProjectID)
    }
}

/// Workspace values not owned by the normalized Workspace row. Named Workspaces currently have one
/// such field (`defaultModelSelection`); Home also needs its source schema version for an exact fresh
/// `home-workspace.json` rollback record.
struct LibraryWorkspaceLocalStatePayload: Codable, Equatable {
    static let currentVersion = 1
    static let maximumEncodedBytes = 1 * 1_024 * 1_024

    let defaultModelSelection: ModelSelection?
    let homeSchemaVersion: Int?
}

struct LibraryConversationMetadataPayload: Codable, Equatable {
    let modelSelection: ModelSelection?
    let forkProvenance: ConversationForkProvenance?
    let captureOrdinalHighWatermark: UInt64?
    let providerHistoryReplayCutoffOrdinal: UInt64?
    let contextTokens: Int?
    let contextWindow: Int?
    let contextModel: String?

    init(
        modelSelection: ModelSelection?,
        forkProvenance: ConversationForkProvenance?,
        captureOrdinalHighWatermark: UInt64?,
        providerHistoryReplayCutoffOrdinal: UInt64? = nil,
        contextTokens: Int?,
        contextWindow: Int?,
        contextModel: String?
    ) {
        self.modelSelection = modelSelection
        self.forkProvenance = forkProvenance
        self.captureOrdinalHighWatermark = captureOrdinalHighWatermark
        self.providerHistoryReplayCutoffOrdinal = providerHistoryReplayCutoffOrdinal
        self.contextTokens = contextTokens
        self.contextWindow = contextWindow
        self.contextModel = contextModel
    }
}

struct LibraryWorkflowPayload: Codable, Equatable {
    let storageKey: String
    let value: WorkflowRun
}

struct LibrarySubagentPayload: Codable, Equatable {
    let storageKey: String
    let value: SubagentRun
}

private enum LibraryTranscriptDecodeOutcome {
    case value(TranscriptEntry)
    case failure(String)
}

/// `DispatchQueue.concurrentPerform` joins every worker before reconstruction reads this buffer.
/// The lock protects Array's shared storage while each worker publishes its one disjoint chunk;
/// the unchecked conformance is limited to that explicit synchronization boundary because current
/// persisted runtime models predate `Sendable` annotations.
private final class LibraryTranscriptDecodeBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var chunks: [[LibraryTranscriptDecodeOutcome]?]

    init(workerCount: Int) {
        chunks = Array(repeating: nil, count: workerCount)
    }

    func publish(_ outcomes: [LibraryTranscriptDecodeOutcome], worker: Int) {
        lock.lock()
        chunks[worker] = outcomes
        lock.unlock()
    }

    func joined() -> [LibraryTranscriptDecodeOutcome] {
        lock.lock()
        defer { lock.unlock() }
        return chunks.flatMap { chunk in
            // `concurrentPerform` is synchronous, so a missing publication is an internal defect,
            // not malformed persisted data that may be tolerated.
            precondition(chunk != nil, "Transcript decode worker did not publish its result")
            return chunk!
        }
    }
}

struct LibraryCanonicalLossReport: Equatable {
    let droppedPaths: [String]
    let isTruncated: Bool

    var isLossless: Bool { droppedPaths.isEmpty && !isTruncated }

    var diagnostics: String {
        let paths = droppedPaths.joined(separator: ", ")
        let suffix = isTruncated ? ", … additional paths omitted" : ""
        return "Canonical decode would drop source JSON path(s): \(paths)\(suffix)"
    }
}

/// Structural loss preflight for tolerant Codable migration.
///
/// Current decoders intentionally ignore unknown keys so newer/ambient JSON does not crash older
/// builds. That behavior is unsafe at an authority cutover unless migration first proves that the
/// canonical current encoding still contains every source object path. This comparison retains no
/// second giant JSON value: it walks the two already-loaded JSON trees, reports bounded RFC 6901
/// pointers, and lets the coordinator preserve the original source as visible quarantine evidence.
enum LibraryCanonicalLossPreflight {
    static let maximumReportedPaths = 128

    /// - Parameter accounting: members the decoder reports discarding on purpose. They are removed
    ///   from the source tree before comparison, so a product-defined repair is not reported as
    ///   loss. Anything the decoder does not declare stays strict.
    static func compare(
        original: Data,
        canonical: Data,
        accounting normalizations: [ConversationDecodeNormalization] = [],
        maximumReportedPaths: Int = maximumReportedPaths
    ) throws -> LibraryCanonicalLossReport {
        guard maximumReportedPaths > 0 else {
            throw LibraryAuthorityAdapterError.invalidPayload(
                domain: "canonical loss preflight", detail: "path limit must be positive")
        }
        let source: Any
        let encoded: Any
        do {
            source = try JSONSerialization.jsonObject(with: original, options: [.fragmentsAllowed])
            encoded = try JSONSerialization.jsonObject(
                with: canonical, options: [.fragmentsAllowed])
        } catch {
            throw LibraryAuthorityAdapterError.invalidPayload(
                domain: "canonical loss preflight", detail: error.localizedDescription)
        }
        let accounted = ConversationDecodeNormalization.prune(
            source: source, applying: normalizations)
        var collector = PathCollector(limit: maximumReportedPaths)
        compare(source: accounted, canonical: encoded, path: "", collector: &collector)
        return LibraryCanonicalLossReport(
            droppedPaths: collector.paths,
            isTruncated: collector.isTruncated)
    }

    private struct PathCollector {
        let limit: Int
        var paths: [String] = []
        var isTruncated = false

        mutating func append(_ path: String) {
            guard paths.count < limit else {
                isTruncated = true
                return
            }
            paths.append(path.isEmpty ? "/" : path)
        }
    }

    private static func compare(
        source: Any,
        canonical: Any,
        path: String,
        collector: inout PathCollector
    ) {
        guard !collector.isTruncated else { return }
        if let sourceObject = source as? [String: Any] {
            guard let canonicalObject = canonical as? [String: Any] else {
                for key in sourceObject.keys.sorted() {
                    collector.append(appending(key: key, to: path))
                }
                return
            }
            for key in sourceObject.keys.sorted() {
                let childPath = appending(key: key, to: path)
                guard let canonicalValue = canonicalObject[key] else {
                    // A source may spell an absent Optional as JSON null while Swift's synthesized
                    // encoder omits it. Null carries no field value to preserve and is therefore
                    // structurally equivalent to absence; non-null unknown members are not.
                    if !(sourceObject[key] is NSNull) { collector.append(childPath) }
                    continue
                }
                compare(
                    source: sourceObject[key]!,
                    canonical: canonicalValue,
                    path: childPath,
                    collector: &collector)
            }
            return
        }
        if let sourceArray = source as? [Any] {
            guard let canonicalArray = canonical as? [Any] else {
                collector.append(path)
                return
            }
            for index in sourceArray.indices {
                let childPath = appending(index: index, to: path)
                guard index < canonicalArray.count else {
                    collector.append(childPath)
                    continue
                }
                compare(
                    source: sourceArray[index],
                    canonical: canonicalArray[index],
                    path: childPath,
                    collector: &collector)
            }
        }
        // Scalar values may legitimately normalize (notably date formatting). This gate detects
        // structural omission, while semantic parity remains a separate decode-back check.
    }

    private static func appending(key: String, to path: String) -> String {
        let escaped = key.replacingOccurrences(of: "~", with: "~0")
            .replacingOccurrences(of: "/", with: "~1")
        return "\(path)/\(escaped)"
    }

    private static func appending(index: Int, to path: String) -> String {
        "\(path)/\(index)"
    }
}

enum LibraryConversationAdapter {
    static let maximumEventCount = 250_000
    static let maximumEventPayloadBytes = 64 * 1_024 * 1_024
    private static let parallelTranscriptEntryThreshold = 512
    private static let parallelTranscriptByteThreshold = 4 * 1_024 * 1_024
    private static let maximumTranscriptDecodeWorkers = 4

    static func captureLocalState(
        from conversation: Conversation
    ) throws -> (version: Int, payload: Data) {
        let value = LibraryConversationLocalStatePayload(
            sdkSessionID: conversation.sdkSessionId,
            sdkSessionRouteIdentity: conversation.sdkSessionRouteIdentity,
            sdkSessionExtensionRevision: conversation.sdkSessionExtensionRevision,
            sdkSessionToolProfile: conversation.sdkSessionToolProfile,
            sdkSessionWorkspaceInstructionsRevision:
                conversation.sdkSessionWorkspaceInstructionsRevision,
            queuedPrompts: conversation.queuedPrompts,
            pendingTurnPrompt: conversation.pendingTurnPrompt,
            draft: conversation.draft,
            suggestedPrompt: conversation.suggestedPrompt,
            armedTrigger: conversation.armedTrigger,
            providerAccessRequest: conversation.providerAccessRequest,
            claudePreferences: conversation.claudePreferences,
            claudeEffectiveModel: conversation.claudeEffectiveModel,
            legacyProjectID: conversation.projectID)
        return (
            LibraryConversationLocalStatePayload.currentVersion,
            try encodeBounded(
                value,
                domain: "Conversation local state",
                limit: LibraryConversationLocalStatePayload.maximumEncodedBytes,
                encoder: ConversationStore.makeEncoder()))
    }

    /// Reconstruct the exact current runtime value from relational row metadata, ordered event
    /// payloads, nested artifact snapshots and the bounded local-state payload. Unknown event kinds
    /// fail closed so a newer database can never look like an older, partially empty Conversation.
    static func reconstruct(from snapshot: ShadowLibraryConversationSnapshot) throws -> Conversation {
        try reconstruct(from: snapshot, isCancelled: { false })
    }

    /// Selected Conversation hydration passes a cancellation sampler so a newer sidebar choice can
    /// reclaim the interactive lane between event decodes. One individual JSON decode remains an
    /// atomic Foundation operation, but large transcripts are checked before every next entry and
    /// their parallel workers stop before taking another payload.
    static func reconstruct(
        from snapshot: ShadowLibraryConversationSnapshot,
        isCancelled: @escaping @Sendable () -> Bool
    ) throws -> Conversation {
        guard !isCancelled() else { throw CancellationError() }
        guard !snapshot.tombstoned else {
            throw LibraryAuthorityAdapterError.invalidPayload(
                domain: "Conversation", detail: "tombstoned row is not live runtime state")
        }
        guard snapshot.events.count <= maximumEventCount else {
            throw LibraryAuthorityAdapterError.invalidEvent(
                "\(snapshot.events.count) rows exceed the \(maximumEventCount) row limit")
        }
        let local: LibraryConversationLocalStatePayload = try decodeBounded(
            LibraryConversationLocalStatePayload.self,
            version: snapshot.localStateVersion,
            expectedVersion: LibraryConversationLocalStatePayload.currentVersion,
            data: snapshot.localStatePayload,
            domain: "Conversation local state",
            limit: LibraryConversationLocalStatePayload.maximumEncodedBytes,
            decoder: ConversationStore.makeDecoder())
        guard !isCancelled() else { throw CancellationError() }

        var messages: [TranscriptEntry] = []
        // A transcript dominates real Conversation event sets. Reserving the upper bound avoids
        // repeated copy-on-growth of thousands of reference-rich entries; unused capacity is
        // released with this short-lived reconstruction scope.
        messages.reserveCapacity(snapshot.events.count)
        var activity: [AgentActivityRecord] = []
        var workflows: [String: WorkflowRun] = [:]
        var subagents: [String: SubagentRun] = [:]
        var metadata: LibraryConversationMetadataPayload?
        var expectedSequence: Int64 = 0
        let decoder = ConversationStore.makeDecoder()

        // Store reads and capture adapters already emit capture order. Preserve the historical
        // tolerance for a caller-supplied unsorted snapshot, but do not allocate and comparison-sort
        // the common 10k-row path merely to rediscover that SQL's ORDER BY was correct.
        let events: [ShadowLibraryEventSnapshot]
        if zip(snapshot.events, snapshot.events.dropFirst()).allSatisfy({ pair in
            pair.0.captureSequence < pair.1.captureSequence
        }) {
            events = snapshot.events
        } else {
            events = snapshot.events.sorted(by: { $0.captureSequence < $1.captureSequence })
        }

        // A large imported transcript is a contiguous prefix by construction. Its independently
        // framed payloads let SQLite use a few cores where the legacy monolith is necessarily one
        // JSON parse, while every identity/kind/column check below remains ordered and fail-closed.
        // Small records stay sequential so thread scheduling never becomes their dominant cost.
        let parallelTranscript = try decodeLargeTranscriptPrefix(
            in: events,
            isCancelled: isCancelled)

        for (eventIndex, event) in events.enumerated() {
            guard !isCancelled() else { throw CancellationError() }
            guard event.captureSequence == expectedSequence else {
                throw LibraryAuthorityAdapterError.invalidEvent(
                    "expected capture sequence \(expectedSequence), found \(event.captureSequence)")
            }
            expectedSequence += 1
            guard event.payloadVersion == 1 else {
                throw LibraryAuthorityAdapterError.unsupportedPayloadVersion(
                    domain: "Conversation event \(event.kind)", version: event.payloadVersion)
            }
            guard event.payload.count <= maximumEventPayloadBytes else {
                throw LibraryAuthorityAdapterError.payloadTooLarge(
                    domain: "Conversation event \(event.kind)",
                    bytes: event.payload.count,
                    limit: maximumEventPayloadBytes)
            }
            do {
                if event.kind.hasPrefix("transcript.") {
                    let entry: TranscriptEntry
                    if eventIndex < parallelTranscript.count {
                        switch parallelTranscript[eventIndex] {
                        case .value(let value):
                            entry = value
                        case .failure(let description):
                            throw LibraryAuthorityAdapterError.invalidEvent(
                                "\(event.kind) could not decode: \(description)")
                        }
                    } else {
                        entry = try decoder.decode(TranscriptEntry.self, from: event.payload)
                    }
                    // Strict by default, with one declared exception. A kind this build retired
                    // decodes as `.system` (see `TranscriptEntry.Kind.retiredRawValues`), so the
                    // stored event kind legitimately disagrees with the decoded one. Accepting
                    // that only for values named in the retired set keeps every other mismatch a
                    // hard error, which is what catches a genuinely corrupt row.
                    let storedKind = event.kind.hasPrefix("transcript.")
                        ? String(event.kind.dropFirst("transcript.".count))
                        : event.kind
                    let kindAgrees = storedKind == entry.kind.rawValue
                        || (entry.kind == .system
                            && TranscriptEntry.Kind.retiredRawValues.contains(storedKind))
                    guard kindAgrees, entry.id == event.id else {
                        throw LibraryAuthorityAdapterError.invalidEvent(
                            "transcript row identity/kind does not match its payload")
                    }
                    try validateColumns(
                        event,
                        actorID: actorID(for: entry),
                        targetID: nil,
                        observedAt: entry.observedAt)
                    messages.append(entry)
                } else if event.kind.hasPrefix("agent_activity.") {
                    let record = try decoder.decode(AgentActivityRecord.self, from: event.payload)
                    guard event.kind == "agent_activity.\(record.kind.rawValue)" else {
                        throw LibraryAuthorityAdapterError.invalidEvent(
                            "agent activity kind does not match its payload")
                    }
                    try validateColumns(
                        event,
                        actorID: record.agentID,
                        targetID: nil,
                        observedAt: record.at)
                    activity.append(record)
                } else if event.kind == "legacy_projection.workflow_summary" {
                    let value = try decoder.decode(LibraryWorkflowPayload.self, from: event.payload)
                    try validateColumns(
                        event,
                        actorID: "root",
                        targetID: "workflow:\(value.storageKey)",
                        observedAt: value.value.endedAt ?? value.value.startedAt)
                    guard workflows.updateValue(value.value, forKey: value.storageKey) == nil else {
                        throw LibraryAuthorityAdapterError.invalidEvent(
                            "duplicate workflow key \(value.storageKey)")
                    }
                } else if event.kind == "legacy_projection.subagent_summary" {
                    let value = try decoder.decode(LibrarySubagentPayload.self, from: event.payload)
                    try validateColumns(
                        event,
                        actorID: "subagent:\(value.storageKey)",
                        targetID: nil,
                        observedAt: value.value.endedAt ?? value.value.startedAt)
                    guard subagents.updateValue(value.value, forKey: value.storageKey) == nil else {
                        throw LibraryAuthorityAdapterError.invalidEvent(
                            "duplicate subagent key \(value.storageKey)")
                    }
                } else if event.kind == "conversation.metadata" {
                    guard metadata == nil else {
                        throw LibraryAuthorityAdapterError.invalidEvent(
                            "duplicate Conversation metadata row")
                    }
                    try validateColumns(
                        event, actorID: "root", targetID: nil, observedAt: nil)
                    metadata = try decoder.decode(
                        LibraryConversationMetadataPayload.self, from: event.payload)
                } else {
                    throw LibraryAuthorityAdapterError.unsupportedEventKind(event.kind)
                }
            } catch let error as LibraryAuthorityAdapterError {
                throw error
            } catch {
                throw LibraryAuthorityAdapterError.invalidEvent(
                    "\(event.kind) could not decode: \(error.localizedDescription)")
            }
        }
        guard let metadata else {
            throw LibraryAuthorityAdapterError.invalidEvent("Conversation metadata row is missing")
        }

        guard let titleSource = ConversationTitleSource(rawValue: snapshot.titleSource) else {
            throw LibraryAuthorityAdapterError.invalidPayload(
                domain: "Conversation",
                detail: "unsupported title source \(snapshot.titleSource)")
        }
        if let legacyProjectID = local.legacyProjectID,
           legacyProjectID != snapshot.workspaceID {
            throw LibraryAuthorityAdapterError.invalidPayload(
                domain: "Conversation local state",
                detail: "legacy membership disagrees with the relational Workspace")
        }
        var artifacts: [Artifact] = []
        artifacts.reserveCapacity(snapshot.nestedArtifacts.count)
        for nestedArtifact in snapshot.nestedArtifacts {
            guard !isCancelled() else { throw CancellationError() }
            artifacts.append(try LibraryArtifactAdapter.reconstructNested(from: nestedArtifact))
        }
        guard !isCancelled() else { throw CancellationError() }
        var conversation = Conversation(
            id: snapshot.id,
            title: snapshot.title,
            titleSource: titleSource,
            cwd: snapshot.cwd,
            sdkSessionId: local.sdkSessionID,
            sdkSessionRouteIdentity: local.sdkSessionRouteIdentity,
            sdkSessionExtensionRevision: local.sdkSessionExtensionRevision,
            sdkSessionToolProfile: local.sdkSessionToolProfile,
            sdkSessionWorkspaceInstructionsRevision:
                local.sdkSessionWorkspaceInstructionsRevision,
            modelSelection: metadata.modelSelection,
            messages: messages,
            updatedAt: snapshot.updatedAt,
            forkProvenance: metadata.forkProvenance,
            artifacts: artifacts,
            workflowRuns: workflows,
            subagents: subagents,
            agentActivity: activity,
            captureOrdinalHighWatermark: metadata.captureOrdinalHighWatermark,
            providerHistoryReplayCutoffOrdinal:
                metadata.providerHistoryReplayCutoffOrdinal,
            queuedPrompts: local.queuedPrompts,
            draft: local.draft,
            suggestedPrompt: local.suggestedPrompt?.validated(in: messages),
            favorite: snapshot.favorite,
            sortIndex: snapshot.sortIndex,
            armedTrigger: local.armedTrigger,
            unread: snapshot.unread,
            errored: snapshot.errored,
            // This is the exact old-generation value, not normalized membership truth. A nil
            // `projectID` may map to Home or may have been uniquely cwd-resolved during import.
            // SQLite consumers use the relational Workspace id; rollback must not fabricate a
            // legacy key that the source never contained.
            projectID: local.legacyProjectID,
            contextTokens: metadata.contextTokens,
            contextWindow: metadata.contextWindow,
            contextModel: metadata.contextModel,
            providerAccessRequest: local.providerAccessRequest,
            claudePreferences: local.claudePreferences)
        conversation.pendingTurnPrompt = local.pendingTurnPrompt
        conversation.claudeEffectiveModel = local.claudeEffectiveModel
        conversation.needsStaleStatePersistence = false
        return conversation
    }

    /// Decode only the leading transcript run emitted by the capture adapter. Returning an empty
    /// array keeps the original sequential path for a small or interleaved caller-supplied snapshot.
    private static func decodeLargeTranscriptPrefix(
        in events: [ShadowLibraryEventSnapshot],
        isCancelled: @escaping @Sendable () -> Bool
    ) throws -> [LibraryTranscriptDecodeOutcome] {
        guard !isCancelled() else { throw CancellationError() }
        var entryCount = 0
        var byteCount = 0
        while entryCount < events.count,
              events[entryCount].kind.hasPrefix("transcript.") {
            guard !isCancelled() else { throw CancellationError() }
            byteCount += events[entryCount].payload.count
            entryCount += 1
        }
        guard entryCount >= parallelTranscriptEntryThreshold,
              byteCount >= parallelTranscriptByteThreshold else { return [] }

        // Do not decode ahead of the ordered structural guards in `reconstruct`. If any row would
        // fail one of those guards, leave the whole prefix on the original sequential path so the
        // same first error wins without parsing a payload that should already have been rejected.
        for index in 0..<entryCount {
            guard !isCancelled() else { throw CancellationError() }
            if events[index].captureSequence != Int64(index)
                || events[index].payloadVersion != 1
                || events[index].payload.count > maximumEventPayloadBytes {
                return []
            }
        }

        let workerCount = min(
            maximumTranscriptDecodeWorkers,
            max(1, ProcessInfo.processInfo.activeProcessorCount),
            entryCount)
        guard workerCount > 1 else { return [] }

        let buffer = LibraryTranscriptDecodeBuffer(workerCount: workerCount)
        let chunkSize = (entryCount + workerCount - 1) / workerCount
        DispatchQueue.concurrentPerform(iterations: workerCount) { worker in
            let start = worker * chunkSize
            let end = min(start + chunkSize, entryCount)
            guard start < end else {
                buffer.publish([], worker: worker)
                return
            }
            let decoder = ConversationStore.makeDecoder()
            var outcomes: [LibraryTranscriptDecodeOutcome] = []
            outcomes.reserveCapacity(end - start)
            for index in start..<end {
                guard !isCancelled() else { break }
                do {
                    outcomes.append(.value(try decoder.decode(
                        TranscriptEntry.self, from: events[index].payload)))
                } catch {
                    outcomes.append(.failure(error.localizedDescription))
                }
            }
            buffer.publish(outcomes, worker: worker)
        }
        guard !isCancelled() else { throw CancellationError() }
        return buffer.joined()
    }

    /// Rollback writes a newly encoded, current legacy generation. It never copies the old giant
    /// source JSON into SQLite merely to make down-conversion easy.
    static func freshLegacyData(from snapshot: ShadowLibraryConversationSnapshot) throws -> Data {
        try ConversationStore.makeEncoder().encode(reconstruct(from: snapshot))
    }

    /// Columns are the queryable projection of the same current-generation fact. Accepting a row
    /// whose columns disagree with its payload would silently choose one copy during rollback.
    /// Fields that current legacy/runtime values cannot represent must stay nil until a versioned
    /// payload and decoder own them.
    private static func validateColumns(
        _ event: ShadowLibraryEventSnapshot,
        actorID: String?,
        targetID: String?,
        observedAt: Date?
    ) throws {
        guard event.actorID == actorID,
              event.targetID == targetID,
              datesMatchLegacyEncoding(event.observedAt, observedAt),
              event.providerAt == nil,
              event.producingEventID == nil,
              event.causalEventID == nil else {
            throw LibraryAuthorityAdapterError.invalidEvent(
                "\(event.kind) relational columns disagree with, or exceed, payload v1")
        }
    }

    /// Legacy ISO-8601 JSON persists milliseconds. A post-write shadow capture can see the original
    /// in-memory sub-millisecond `Date` while its fingerprint and event payload describe the exact
    /// rounded source bytes. Treat only that encoding quantum as equal; reconstruction still takes
    /// the payload value, which is exactly what decoding the authoritative sidecar returns.
    static func datesMatchLegacyEncoding(_ lhs: Date?, _ rhs: Date?) -> Bool {
        switch (lhs, rhs) {
        case (nil, nil): true
        case (.some(let lhs), .some(let rhs)):
            // Compare the exact bytes the legacy encoder would publish. A numeric tolerance can
            // accept values on opposite millisecond rounding boundaries even though their JSON
            // strings differ, which would bless two contradictory copies of the same fact.
            SendableISO8601Formatter.fractional.string(from: lhs)
                == SendableISO8601Formatter.fractional.string(from: rhs)
        default: false
        }
    }

    private static func actorID(for entry: TranscriptEntry) -> String {
        switch entry.kind {
        case .user: return "user"
        case .tool: return entry.toolOwnerAgentID ?? "root"
        default: return "root"
        }
    }
}

enum LibraryWorkspaceReconstruction {
    case home(HomeWorkspaceSettings)
    case named(Project)
    case unresolved(UUID)
}

enum LibraryWorkspaceAdapter {
    static func captureLocalState(
        from workspace: Project
    ) throws -> (version: Int, payload: Data) {
        try capture(LibraryWorkspaceLocalStatePayload(
            defaultModelSelection: workspace.defaultModelSelection,
            homeSchemaVersion: nil))
    }

    static func captureLocalState(
        from settings: HomeWorkspaceSettings
    ) throws -> (version: Int, payload: Data) {
        try capture(LibraryWorkspaceLocalStatePayload(
            defaultModelSelection: nil,
            homeSchemaVersion: settings.schemaVersion))
    }

    static func reconstruct(
        from snapshot: ShadowLibraryWorkspaceSnapshot
    ) throws -> LibraryWorkspaceReconstruction {
        guard !snapshot.tombstoned else {
            throw LibraryAuthorityAdapterError.invalidPayload(
                domain: "Workspace", detail: "tombstoned row is not live runtime state")
        }
        let local: LibraryWorkspaceLocalStatePayload = try decodeBounded(
            LibraryWorkspaceLocalStatePayload.self,
            version: snapshot.localStateVersion,
            expectedVersion: LibraryWorkspaceLocalStatePayload.currentVersion,
            data: snapshot.localStatePayload,
            domain: "Workspace local state",
            limit: LibraryWorkspaceLocalStatePayload.maximumEncodedBytes,
            decoder: ConversationStore.makeDecoder())
        switch snapshot.kind {
        case .home:
            guard local.defaultModelSelection == nil else {
                throw LibraryAuthorityAdapterError.invalidPayload(
                    domain: "Workspace local state",
                    detail: "Home unexpectedly contains a default model selection")
            }
            return .home(HomeWorkspaceSettings(
                schemaVersion: local.homeSchemaVersion ?? 1,
                instructions: snapshot.instructions,
                updatedAt: snapshot.updatedAt))
        case .named:
            guard local.homeSchemaVersion == nil else {
                throw LibraryAuthorityAdapterError.invalidPayload(
                    domain: "Workspace local state",
                    detail: "named Workspace unexpectedly contains a Home schema version")
            }
            return .named(Project(
                id: snapshot.id,
                name: snapshot.name,
                goal: snapshot.goal,
                instructions: snapshot.instructions,
                cwd: snapshot.cwd,
                favorite: snapshot.favorite,
                sortIndex: snapshot.sortIndex,
                iconSymbol: snapshot.iconSymbol,
                colorHex: snapshot.colorHex,
                defaultModelSelection: local.defaultModelSelection,
                createdAt: snapshot.createdAt,
                updatedAt: snapshot.updatedAt))
        case .unresolved:
            return .unresolved(snapshot.id)
        }
    }

    static func freshLegacyData(from snapshot: ShadowLibraryWorkspaceSnapshot) throws -> Data {
        switch try reconstruct(from: snapshot) {
        case .home(let settings):
            return try legacyEncoder().encode(settings)
        case .named(let workspace):
            return try legacyEncoder().encode(workspace)
        case .unresolved(let id):
            throw LibraryAuthorityAdapterError.unresolvedWorkspace(id)
        }
    }

    private static func capture(
        _ value: LibraryWorkspaceLocalStatePayload
    ) throws -> (version: Int, payload: Data) {
        (
            LibraryWorkspaceLocalStatePayload.currentVersion,
            try encodeBounded(
                value,
                domain: "Workspace local state",
                limit: LibraryWorkspaceLocalStatePayload.maximumEncodedBytes,
                encoder: ConversationStore.makeEncoder()))
    }

    /// Match `ProjectStore`'s current sidecar contract. Its loader uses `.iso8601`, so rollback must
    /// not casually reuse the Conversation encoder's fractional-date strategy.
    private static func legacyEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }
}

enum LibraryArtifactAdapter {
    private static let maximumRawPayloadBytes = 64 * 1_024 * 1_024
    private static let knownTopLevelKeys: Set<String> = [
        "id", "title", "type", "source", "createdAt", "updatedAt", "revisions",
        "favorite", "origin", "workspaceID", "conversationID", "conversationTitle", "cwd",
        // Ambient's producer id is not part of `Artifact.CodingKeys`, but it has a typed relational
        // owner and therefore is not an opaque raw extension after import.
        "taskId",
    ]

    static func reconstruct(from snapshot: ShadowLibraryArtifactSnapshot) throws -> Artifact {
        guard !snapshot.tombstoned else {
            throw LibraryAuthorityAdapterError.invalidPayload(
                domain: "Artifact", detail: "tombstoned row is not live runtime state")
        }
        guard digest(snapshot.canonicalPayload) == snapshot.canonicalPayloadDigest else {
            throw LibraryAuthorityAdapterError.invalidPayload(
                domain: "Artifact", detail: "canonical payload digest mismatch")
        }
        let artifact: Artifact
        do {
            artifact = try ArtifactStore.persistedDecoder().decode(
                Artifact.self, from: snapshot.canonicalPayload)
        } catch {
            throw LibraryAuthorityAdapterError.invalidPayload(
                domain: "Artifact", detail: error.localizedDescription)
        }
        let content = Data(artifact.source.utf8)
        let normalizedWorkspaceID = artifact.workspaceID ?? SQLiteLibraryStore.homeWorkspaceID
        guard artifact.uuid == snapshot.id,
              artifact.title == snapshot.title,
              artifact.type == snapshot.type,
              artifact.origin == snapshot.origin,
              normalizedWorkspaceID == snapshot.workspaceID,
              artifact.conversationID == snapshot.provenanceConversationID,
              artifact.conversationTitle == snapshot.conversationTitleSnapshot,
              artifact.cwd == snapshot.cwd,
              artifact.favorite == snapshot.favorite,
              artifact.createdAt == snapshot.createdAt,
              artifact.updatedAt == snapshot.updatedAt,
              artifact.revisions == snapshot.revision,
              content.count == snapshot.contentByteCount,
              content == snapshot.content,
              digest(content) == snapshot.contentDigest,
              mediaType(for: artifact.type) == snapshot.payloadMediaType else {
            throw LibraryAuthorityAdapterError.invalidPayload(
                domain: "Artifact", detail: "canonical payload disagrees with relational columns")
        }
        return artifact
    }

    static func reconstructNested(
        from snapshot: ShadowLibraryNestedArtifactSnapshot
    ) throws -> Artifact {
        guard digest(snapshot.canonicalPayload) == snapshot.canonicalPayloadDigest else {
            throw LibraryAuthorityAdapterError.invalidPayload(
                domain: "nested Artifact", detail: "canonical payload digest mismatch")
        }
        let artifact: Artifact
        do {
            artifact = try ArtifactStore.persistedDecoder().decode(
                Artifact.self, from: snapshot.canonicalPayload)
        } catch {
            throw LibraryAuthorityAdapterError.invalidPayload(
                domain: "nested Artifact", detail: error.localizedDescription)
        }
        let content = Data(artifact.source.utf8)
        guard artifact.uuid == snapshot.artifactID,
              content.count == snapshot.contentByteCount,
              digest(content) == snapshot.contentDigest else {
            throw LibraryAuthorityAdapterError.invalidPayload(
                domain: "nested Artifact", detail: "payload metadata mismatch")
        }
        return artifact
    }

    /// A safe downgrade carries only unknown top-level ambient/future extension members out of the
    /// retained raw payload. Current canonical keys always come from the verified relational value,
    /// so stale raw title/content/ownership fields cannot roll an authoritative mutation backward.
    static func freshLegacyData(from snapshot: ShadowLibraryArtifactSnapshot) throws -> Data {
        let artifact = try reconstruct(from: snapshot)
        let canonical = try ArtifactStore.persistedEncoder().encode(artifact)
        guard let canonicalObject = try? jsonObject(canonical) else {
            return canonical
        }
        var merged = canonicalObject
        if snapshot.rawSourcePayload.count <= maximumRawPayloadBytes,
           let rawObject = try? jsonObject(snapshot.rawSourcePayload) {
            for (key, value) in rawObject where !knownTopLevelKeys.contains(key) {
                merged[key] = value
            }
        }
        if let producerTaskID = snapshot.producerTaskID {
            merged["taskId"] = producerTaskID
        }
        return try JSONSerialization.data(withJSONObject: merged, options: [.sortedKeys])
    }

    static func retainedRawExtensionKeys(
        in snapshot: ShadowLibraryArtifactSnapshot
    ) -> Set<String> {
        guard let object = try? jsonObject(snapshot.rawSourcePayload) else { return [] }
        return Set(object.keys).subtracting(knownTopLevelKeys)
    }

    private static func jsonObject(_ data: Data) throws -> [String: Any] {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw LibraryAuthorityAdapterError.invalidPayload(
                domain: "Artifact", detail: "source is not a JSON object")
        }
        return object
    }

    private static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func mediaType(for type: String) -> String {
        switch type.lowercased() {
        case "html": return "text/html"
        case "svg": return "image/svg+xml"
        case "mermaid": return "text/vnd.mermaid"
        case "csv": return "text/csv"
        case "markdown", "md": return "text/markdown"
        default: return "text/plain"
        }
    }
}

// MARK: - Runtime-to-authority capture

extension LibraryConversationAdapter {
    /// Captures one complete runtime Conversation for an authoritative SQLite transaction. Unlike
    /// the migration coordinator this adapter has no filesystem-generation dependency.
    static func capture(
        _ conversation: Conversation,
        source: ShadowLibrarySourceFingerprint,
        changedTranscriptEntryIDs: Set<UUID>? = nil
    ) throws -> ShadowLibraryConversationSnapshot {
        let encoder = ConversationStore.makeEncoder()
        var events: [ShadowLibraryEventSnapshot] = []
        events.reserveCapacity(
            conversation.messages.count + conversation.agentActivity.count
                + conversation.workflowRuns.count + conversation.subagents.count + 1)
        for (index, entry) in conversation.messages.enumerated()
        where changedTranscriptEntryIDs?.contains(entry.id) ?? true {
            events.append(ShadowLibraryEventSnapshot(
                id: entry.id,
                captureSequence: Int64(index),
                kind: "transcript.\(entry.kind.rawValue)",
                actorID: entry.kind == .user
                    ? "user"
                    : (entry.kind == .tool ? entry.toolOwnerAgentID ?? "root" : "root"),
                observedAt: entry.observedAt,
                payloadVersion: 1,
                payload: try encoder.encode(entry)))
        }
        var nextSequence = Int64(conversation.messages.count)
        for activity in conversation.agentActivity {
            events.append(ShadowLibraryEventSnapshot(
                id: authorityStableID(
                    conversation.id, namespace: "agent-activity",
                    sourceID: activity.id.uuidString),
                captureSequence: nextSequence,
                kind: "agent_activity.\(activity.kind.rawValue)",
                actorID: activity.agentID,
                observedAt: activity.at,
                payloadVersion: 1,
                payload: try encoder.encode(activity)))
            nextSequence += 1
        }
        for key in conversation.workflowRuns.keys.sorted() {
            guard let value = conversation.workflowRuns[key] else { continue }
            events.append(ShadowLibraryEventSnapshot(
                id: authorityStableID(
                    conversation.id, namespace: "workflow-summary", sourceID: key),
                captureSequence: nextSequence,
                kind: "legacy_projection.workflow_summary",
                actorID: "root",
                targetID: "workflow:\(key)",
                observedAt: value.endedAt ?? value.startedAt,
                payloadVersion: 1,
                payload: try encoder.encode(LibraryWorkflowPayload(
                    storageKey: key, value: value))))
            nextSequence += 1
        }
        for key in conversation.subagents.keys.sorted() {
            guard let value = conversation.subagents[key] else { continue }
            events.append(ShadowLibraryEventSnapshot(
                id: authorityStableID(
                    conversation.id, namespace: "subagent-summary", sourceID: key),
                captureSequence: nextSequence,
                kind: "legacy_projection.subagent_summary",
                actorID: "subagent:\(key)",
                observedAt: value.endedAt ?? value.startedAt,
                payloadVersion: 1,
                payload: try encoder.encode(LibrarySubagentPayload(
                    storageKey: key, value: value))))
            nextSequence += 1
        }
        events.append(ShadowLibraryEventSnapshot(
            id: authorityStableID(
                conversation.id, namespace: "conversation-metadata", sourceID: "v1"),
            captureSequence: nextSequence,
            kind: "conversation.metadata",
            actorID: "root",
            payloadVersion: 1,
            payload: try encoder.encode(LibraryConversationMetadataPayload(
                modelSelection: conversation.modelSelection,
                forkProvenance: conversation.forkProvenance,
                captureOrdinalHighWatermark: conversation.captureOrdinalHighWatermark,
                providerHistoryReplayCutoffOrdinal:
                    conversation.providerHistoryReplayCutoffOrdinal,
                contextTokens: conversation.contextTokens,
                contextWindow: conversation.contextWindow,
                contextModel: conversation.contextModel))))
        let local = try captureLocalState(from: conversation)
        let nested = try conversation.artifacts.map { artifact -> ShadowLibraryNestedArtifactSnapshot in
            let payload = try ArtifactStore.persistedEncoder().encode(artifact)
            let content = Data(artifact.source.utf8)
            return ShadowLibraryNestedArtifactSnapshot(
                artifactID: artifact.uuid,
                canonicalPayload: payload,
                canonicalPayloadDigest: authorityDigest(payload),
                contentDigest: authorityDigest(content),
                contentByteCount: content.count)
        }
        return ShadowLibraryConversationSnapshot(
            id: conversation.id,
            title: conversation.title,
            titleSource: conversation.titleSource.rawValue,
            cwd: conversation.cwd,
            workspaceID: conversation.projectID,
            updatedAt: conversation.updatedAt,
            favorite: conversation.favorite,
            sortIndex: conversation.sortIndex,
            unread: conversation.unread,
            errored: conversation.errored,
            revision: 0,
            localStateVersion: local.version,
            localStatePayload: local.payload,
            source: source,
            events: events,
            nestedArtifacts: nested)
    }
}

extension LibraryWorkspaceAdapter {
    static func capture(
        _ workspace: Project,
        source: ShadowLibrarySourceFingerprint
    ) throws -> ShadowLibraryWorkspaceSnapshot {
        let local = try captureLocalState(from: workspace)
        return .named(
            workspace,
            source: source,
            localStateVersion: local.version,
            localStatePayload: local.payload)
    }

    static func capture(
        home settings: HomeWorkspaceSettings,
        source: ShadowLibrarySourceFingerprint
    ) throws -> ShadowLibraryWorkspaceSnapshot {
        let local = try captureLocalState(from: settings)
        return .home(
            settings: settings,
            source: source,
            localStateVersion: local.version,
            localStatePayload: local.payload)
    }
}

extension LibraryArtifactAdapter {
    static func capture(
        _ artifact: Artifact,
        source: ShadowLibrarySourceFingerprint,
        preserving prior: ShadowLibraryArtifactSnapshot? = nil,
        producerTaskID: String? = nil
    ) throws -> ShadowLibraryArtifactSnapshot {
        let canonical = try ArtifactStore.persistedEncoder().encode(artifact)
        // The persisted codec is the public precision contract (notably ISO-8601 milliseconds).
        // Populate relational columns from that exact round trip so a sub-millisecond runtime Date
        // cannot disagree with its own canonical payload on the next authoritative read.
        let normalized = try ArtifactStore.persistedDecoder().decode(
            Artifact.self, from: canonical)
        let content = Data(normalized.source.utf8)
        return ShadowLibraryArtifactSnapshot(
            id: normalized.uuid,
            title: normalized.title,
            type: normalized.type,
            origin: normalized.origin,
            workspaceID: normalized.workspaceID,
            provenanceConversationID: normalized.conversationID,
            conversationTitleSnapshot: normalized.conversationTitle,
            cwd: normalized.cwd,
            favorite: normalized.favorite,
            createdAt: normalized.createdAt,
            updatedAt: normalized.updatedAt,
            revision: normalized.revisions,
            producerTaskID: producerTaskID ?? prior?.producerTaskID,
            rawSourcePayload: prior?.rawSourcePayload ?? canonical,
            canonicalPayload: canonical,
            canonicalPayloadDigest: authorityDigest(canonical),
            content: content,
            contentDigest: authorityDigest(content),
            contentByteCount: content.count,
            payloadMediaType: authorityArtifactMediaType(normalized.type),
            source: source)
    }
}

private func authorityDigest(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

private func authorityStableID(
    _ conversationID: UUID,
    namespace: String,
    sourceID: String
) -> UUID {
    let digest = SHA256.hash(data: Data(
        "\(conversationID.uuidString)|\(namespace)|\(sourceID)".utf8))
    var bytes = Array(digest.prefix(16))
    bytes[6] = (bytes[6] & 0x0f) | 0x50
    bytes[8] = (bytes[8] & 0x3f) | 0x80
    return UUID(uuid: (
        bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
        bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
}

private func authorityArtifactMediaType(_ type: String) -> String {
    switch type.lowercased() {
    case "html": return "text/html"
    case "svg": return "image/svg+xml"
    case "mermaid": return "text/vnd.mermaid"
    case "csv": return "text/csv"
    case "markdown", "md": return "text/markdown"
    default: return "text/plain"
    }
}

private func encodeBounded<T: Encodable>(
    _ value: T,
    domain: String,
    limit: Int,
    encoder: JSONEncoder
) throws -> Data {
    let data = try encoder.encode(value)
    guard data.count <= limit else {
        throw LibraryAuthorityAdapterError.payloadTooLarge(
            domain: domain, bytes: data.count, limit: limit)
    }
    return data
}

private func decodeBounded<T: Decodable>(
    _ type: T.Type,
    version: Int,
    expectedVersion: Int,
    data: Data,
    domain: String,
    limit: Int,
    decoder: JSONDecoder
) throws -> T {
    guard version == expectedVersion else {
        throw LibraryAuthorityAdapterError.unsupportedPayloadVersion(
            domain: domain, version: version)
    }
    guard data.count <= limit else {
        throw LibraryAuthorityAdapterError.payloadTooLarge(
            domain: domain, bytes: data.count, limit: limit)
    }
    do { return try decoder.decode(type, from: data) }
    catch {
        throw LibraryAuthorityAdapterError.invalidPayload(
            domain: domain, detail: error.localizedDescription)
    }
}
