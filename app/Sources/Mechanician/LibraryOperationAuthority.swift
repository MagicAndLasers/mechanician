import CryptoKit
import Darwin
import Foundation

/// Durable operation classes needed before `library.db` can become authoritative.
///
/// The raw values are persistence vocabulary. Adding a case is a schema decision; an older build
/// decoding an unknown value fails rather than treating a newer operation as an understood one.
enum LibraryOperationKind: String, Codable, CaseIterable, Equatable, Hashable, Sendable {
    case conversationDelete = "conversation_delete"
    case artifactDelete = "artifact_delete"
    case workspaceMove = "workspace_move"
    case backgroundAdoption = "background_adoption"
}

enum LibraryOperationState: String, Codable, CaseIterable, Equatable, Hashable, Sendable {
    case prepared
    case committed
    case reversed
    case failed
    /// The source was observed, but cannot safely participate in activation until repaired.
    case quarantined
}

enum LibraryOperationReceiptState: String, Codable, CaseIterable, Equatable, Hashable, Sendable {
    case pending
    case applied
    case reversed
    case failed
    case quarantined
}

/// A recovered legacy delete has no durable copy of `ConversationDeleteReceipt.wasQueuePaused`.
/// Restoring it as running could spend provider money, so unknown always means safe-paused.
enum LibraryConversationQueuePauseState: String, Codable, Equatable, Hashable, Sendable {
    case knownPaused = "known_paused"
    case knownUnpaused = "known_unpaused"
    case unknownSafePaused = "unknown_safe_paused"

    var shouldRestorePaused: Bool { self != .knownUnpaused }
}

struct LibraryConversationDeleteOperationPayload: Codable, Equatable, Sendable {
    let conversationID: UUID
    /// Support-root-relative identity of the unique trash slot, not an absolute machine path.
    let trashSlotIdentity: String
    let queuePauseState: LibraryConversationQueuePauseState
}

struct LibraryArtifactDeleteOperationPayload: Codable, Equatable, Sendable {
    let artifactID: UUID
    let ownerConversationID: UUID?
}

struct LibraryWorkspaceMoveOperationPayload: Codable, Equatable, Sendable {
    enum MemberKind: String, Codable, Equatable, Hashable, Sendable {
        case conversation
        case artifact
    }

    static let maximumMemberCount = 10_000

    let memberKind: MemberKind
    let memberIDs: [UUID]
    let sourceWorkspaceID: UUID
    let destinationWorkspaceID: UUID

    init(
        memberKind: MemberKind,
        memberIDs: [UUID],
        sourceWorkspaceID: UUID,
        destinationWorkspaceID: UUID
    ) throws {
        guard !memberIDs.isEmpty, memberIDs.count <= Self.maximumMemberCount else {
            throw LibraryOperationAuthorityError.invalidPayload(
                "Workspace move member count must be 1...\(Self.maximumMemberCount).")
        }
        guard Set(memberIDs).count == memberIDs.count else {
            throw LibraryOperationAuthorityError.invalidPayload(
                "Workspace move contains duplicate member identities.")
        }
        guard sourceWorkspaceID != destinationWorkspaceID else {
            throw LibraryOperationAuthorityError.invalidPayload(
                "Workspace move source and destination are identical.")
        }
        self.memberKind = memberKind
        self.memberIDs = memberIDs
        self.sourceWorkspaceID = sourceWorkspaceID
        self.destinationWorkspaceID = destinationWorkspaceID
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            memberKind: values.decode(MemberKind.self, forKey: .memberKind),
            memberIDs: values.decode([UUID].self, forKey: .memberIDs),
            sourceWorkspaceID: values.decode(UUID.self, forKey: .sourceWorkspaceID),
            destinationWorkspaceID: values.decode(UUID.self, forKey: .destinationWorkspaceID))
    }
}

struct LibraryBackgroundAdoptionOperationPayload: Codable, Equatable, Sendable {
    let sourceIdentity: String
    let sourceRevision: String
    let sourceDigest: String
    let conversationID: UUID?
    let artifactID: UUID?

    init(
        sourceIdentity: String,
        sourceRevision: String,
        sourceDigest: String,
        conversationID: UUID? = nil,
        artifactID: UUID? = nil
    ) {
        self.sourceIdentity = sourceIdentity
        self.sourceRevision = sourceRevision
        self.sourceDigest = sourceDigest
        self.conversationID = conversationID
        self.artifactID = artifactID
    }
}

enum LibraryOperationAuthorityError: Error, Equatable, LocalizedError {
    case unsupportedSnapshotVersion(Int)
    case unsupportedPayloadVersion(kind: LibraryOperationKind, version: Int)
    case payloadTooLarge(bytes: Int, limit: Int)
    case invalidPayload(String)

    var errorDescription: String? {
        switch self {
        case .unsupportedSnapshotVersion(let version):
            return "Unsupported operation snapshot version \(version)."
        case .unsupportedPayloadVersion(let kind, let version):
            return "Unsupported \(kind.rawValue) payload version \(version)."
        case .payloadTooLarge(let bytes, let limit):
            return "Operation payload is \(bytes) bytes; the limit is \(limit)."
        case .invalidPayload(let detail):
            return "Invalid operation payload: \(detail)"
        }
    }
}

/// A small one-of envelope makes the kind/payload relationship self-validating. It never contains
/// a Conversation, Artifact body, media bytes, or another legacy source blob.
private struct LibraryOperationPayloadEnvelope: Codable {
    let kind: LibraryOperationKind
    let conversationDelete: LibraryConversationDeleteOperationPayload?
    let artifactDelete: LibraryArtifactDeleteOperationPayload?
    let workspaceMove: LibraryWorkspaceMoveOperationPayload?
    let backgroundAdoption: LibraryBackgroundAdoptionOperationPayload?

    init(_ payload: LibraryConversationDeleteOperationPayload) {
        kind = .conversationDelete
        conversationDelete = payload
        artifactDelete = nil
        workspaceMove = nil
        backgroundAdoption = nil
    }

    init(_ payload: LibraryArtifactDeleteOperationPayload) {
        kind = .artifactDelete
        conversationDelete = nil
        artifactDelete = payload
        workspaceMove = nil
        backgroundAdoption = nil
    }

    init(_ payload: LibraryWorkspaceMoveOperationPayload) {
        kind = .workspaceMove
        conversationDelete = nil
        artifactDelete = nil
        workspaceMove = payload
        backgroundAdoption = nil
    }

    init(_ payload: LibraryBackgroundAdoptionOperationPayload) {
        kind = .backgroundAdoption
        conversationDelete = nil
        artifactDelete = nil
        workspaceMove = nil
        backgroundAdoption = payload
    }

    func validate(expectedKind: LibraryOperationKind) throws {
        guard kind == expectedKind else {
            throw LibraryOperationAuthorityError.invalidPayload(
                "Envelope kind \(kind.rawValue) does not match \(expectedKind.rawValue).")
        }
        let populated = [
            conversationDelete != nil,
            artifactDelete != nil,
            workspaceMove != nil,
            backgroundAdoption != nil,
        ].filter { $0 }.count
        guard populated == 1 else {
            throw LibraryOperationAuthorityError.invalidPayload(
                "Operation payload must populate exactly one kind.")
        }
        switch kind {
        case .conversationDelete where conversationDelete != nil: return
        case .artifactDelete where artifactDelete != nil: return
        case .workspaceMove where workspaceMove != nil: return
        case .backgroundAdoption where backgroundAdoption != nil:
            guard let backgroundAdoption,
                  !(backgroundAdoption.conversationID != nil
                    && backgroundAdoption.artifactID != nil) else {
                throw LibraryOperationAuthorityError.invalidPayload(
                    "Background adoption cannot identify both a Conversation and Artifact.")
            }
            return
        default:
            throw LibraryOperationAuthorityError.invalidPayload(
                "Operation payload member does not match its kind.")
        }
    }
}

/// Versioned bounded representation suitable for one `operations` row.
struct LibraryOperationSnapshot: Codable, Equatable, Sendable {
    static let currentFormatVersion = 1
    static let currentPayloadVersion = 1
    static let maximumPayloadBytes = 1 * 1_024 * 1_024
    static let maximumIdempotencyKeyBytes = 1_024

    let formatVersion: Int
    let id: UUID
    let kind: LibraryOperationKind
    let state: LibraryOperationState
    let idempotencyKey: String
    let createdAt: Date
    let updatedAt: Date
    let payloadVersion: Int
    let payload: Data

    private init(
        id: UUID,
        kind: LibraryOperationKind,
        state: LibraryOperationState,
        idempotencyKey: String,
        createdAt: Date,
        updatedAt: Date,
        envelope: LibraryOperationPayloadEnvelope
    ) throws {
        let payload = try Self.encoder().encode(envelope)
        try Self.validate(
            formatVersion: Self.currentFormatVersion,
            kind: kind,
            idempotencyKey: idempotencyKey,
            createdAt: createdAt,
            updatedAt: updatedAt,
            payloadVersion: Self.currentPayloadVersion,
            payload: payload)
        try envelope.validate(expectedKind: kind)
        formatVersion = Self.currentFormatVersion
        self.id = id
        self.kind = kind
        self.state = state
        self.idempotencyKey = idempotencyKey
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        payloadVersion = Self.currentPayloadVersion
        self.payload = payload
    }

    static func conversationDelete(
        id: UUID,
        state: LibraryOperationState,
        idempotencyKey: String,
        recordedAt: Date,
        payload: LibraryConversationDeleteOperationPayload
    ) throws -> Self {
        try Self(
            id: id, kind: .conversationDelete, state: state,
            idempotencyKey: idempotencyKey, createdAt: recordedAt, updatedAt: recordedAt,
            envelope: LibraryOperationPayloadEnvelope(payload))
    }

    static func artifactDelete(
        id: UUID,
        state: LibraryOperationState,
        idempotencyKey: String,
        recordedAt: Date,
        payload: LibraryArtifactDeleteOperationPayload
    ) throws -> Self {
        try Self(
            id: id, kind: .artifactDelete, state: state,
            idempotencyKey: idempotencyKey, createdAt: recordedAt, updatedAt: recordedAt,
            envelope: LibraryOperationPayloadEnvelope(payload))
    }

    static func workspaceMove(
        id: UUID,
        state: LibraryOperationState,
        idempotencyKey: String,
        recordedAt: Date,
        payload: LibraryWorkspaceMoveOperationPayload
    ) throws -> Self {
        try Self(
            id: id, kind: .workspaceMove, state: state,
            idempotencyKey: idempotencyKey, createdAt: recordedAt, updatedAt: recordedAt,
            envelope: LibraryOperationPayloadEnvelope(payload))
    }

    static func backgroundAdoption(
        id: UUID,
        state: LibraryOperationState,
        idempotencyKey: String,
        recordedAt: Date,
        payload: LibraryBackgroundAdoptionOperationPayload
    ) throws -> Self {
        try Self(
            id: id, kind: .backgroundAdoption, state: state,
            idempotencyKey: idempotencyKey, createdAt: recordedAt, updatedAt: recordedAt,
            envelope: LibraryOperationPayloadEnvelope(payload))
    }

    func conversationDeletePayload() throws -> LibraryConversationDeleteOperationPayload {
        let envelope = try decodedEnvelope(expectedKind: .conversationDelete)
        guard let value = envelope.conversationDelete else {
            throw LibraryOperationAuthorityError.invalidPayload(
                "Conversation delete payload is absent.")
        }
        return value
    }

    func artifactDeletePayload() throws -> LibraryArtifactDeleteOperationPayload {
        let envelope = try decodedEnvelope(expectedKind: .artifactDelete)
        guard let value = envelope.artifactDelete else {
            throw LibraryOperationAuthorityError.invalidPayload(
                "Artifact delete payload is absent.")
        }
        return value
    }

    func workspaceMovePayload() throws -> LibraryWorkspaceMoveOperationPayload {
        let envelope = try decodedEnvelope(expectedKind: .workspaceMove)
        guard let value = envelope.workspaceMove else {
            throw LibraryOperationAuthorityError.invalidPayload(
                "Workspace move payload is absent.")
        }
        return value
    }

    func backgroundAdoptionPayload() throws -> LibraryBackgroundAdoptionOperationPayload {
        let envelope = try decodedEnvelope(expectedKind: .backgroundAdoption)
        guard let value = envelope.backgroundAdoption else {
            throw LibraryOperationAuthorityError.invalidPayload(
                "Background adoption payload is absent.")
        }
        return value
    }

    /// Strict repository read path. This is intentionally not a general mutation initializer: it
    /// accepts every persisted column, then reruns the same version, bound, and one-of validation
    /// as Codable decoding before exposing a snapshot to A2/runtime rehearsal.
    init(
        persistedFormatVersion: Int,
        id: UUID,
        kind: LibraryOperationKind,
        state: LibraryOperationState,
        idempotencyKey: String,
        createdAt: Date,
        updatedAt: Date,
        payloadVersion: Int,
        payload: Data
    ) throws {
        try Self.validate(
            formatVersion: persistedFormatVersion,
            kind: kind,
            idempotencyKey: idempotencyKey,
            createdAt: createdAt,
            updatedAt: updatedAt,
            payloadVersion: payloadVersion,
            payload: payload)
        let envelope: LibraryOperationPayloadEnvelope
        do {
            envelope = try Self.decoder().decode(
                LibraryOperationPayloadEnvelope.self, from: payload)
        } catch {
            throw LibraryOperationAuthorityError.invalidPayload(error.localizedDescription)
        }
        try envelope.validate(expectedKind: kind)
        formatVersion = persistedFormatVersion
        self.id = id
        self.kind = kind
        self.state = state
        self.idempotencyKey = idempotencyKey
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.payloadVersion = payloadVersion
        self.payload = payload
    }

    private func decodedEnvelope(
        expectedKind: LibraryOperationKind
    ) throws -> LibraryOperationPayloadEnvelope {
        guard kind == expectedKind else {
            throw LibraryOperationAuthorityError.invalidPayload(
                "Requested \(expectedKind.rawValue) from \(kind.rawValue).")
        }
        let envelope: LibraryOperationPayloadEnvelope
        do {
            envelope = try Self.decoder().decode(
                LibraryOperationPayloadEnvelope.self, from: payload)
        } catch let error as LibraryOperationAuthorityError {
            throw error
        } catch {
            throw LibraryOperationAuthorityError.invalidPayload(error.localizedDescription)
        }
        try envelope.validate(expectedKind: kind)
        return envelope
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let formatVersion = try values.decode(Int.self, forKey: .formatVersion)
        let id = try values.decode(UUID.self, forKey: .id)
        let kind = try values.decode(LibraryOperationKind.self, forKey: .kind)
        let state = try values.decode(LibraryOperationState.self, forKey: .state)
        let idempotencyKey = try values.decode(String.self, forKey: .idempotencyKey)
        let createdAt = try values.decode(Date.self, forKey: .createdAt)
        let updatedAt = try values.decode(Date.self, forKey: .updatedAt)
        let payloadVersion = try values.decode(Int.self, forKey: .payloadVersion)
        let payload = try values.decode(Data.self, forKey: .payload)
        try Self.validate(
            formatVersion: formatVersion,
            kind: kind,
            idempotencyKey: idempotencyKey,
            createdAt: createdAt,
            updatedAt: updatedAt,
            payloadVersion: payloadVersion,
            payload: payload)
        let envelope: LibraryOperationPayloadEnvelope
        do {
            envelope = try Self.decoder().decode(
                LibraryOperationPayloadEnvelope.self, from: payload)
        } catch {
            throw LibraryOperationAuthorityError.invalidPayload(error.localizedDescription)
        }
        try envelope.validate(expectedKind: kind)
        self.formatVersion = formatVersion
        self.id = id
        self.kind = kind
        self.state = state
        self.idempotencyKey = idempotencyKey
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.payloadVersion = payloadVersion
        self.payload = payload
    }

    private static func validate(
        formatVersion: Int,
        kind: LibraryOperationKind,
        idempotencyKey: String,
        createdAt: Date,
        updatedAt: Date,
        payloadVersion: Int,
        payload: Data
    ) throws {
        guard formatVersion == currentFormatVersion else {
            throw LibraryOperationAuthorityError.unsupportedSnapshotVersion(formatVersion)
        }
        guard payloadVersion == currentPayloadVersion else {
            throw LibraryOperationAuthorityError.unsupportedPayloadVersion(
                kind: kind, version: payloadVersion)
        }
        guard !idempotencyKey.isEmpty,
              idempotencyKey.utf8.count <= maximumIdempotencyKeyBytes else {
            throw LibraryOperationAuthorityError.invalidPayload(
                "Idempotency key must be 1...\(maximumIdempotencyKeyBytes) UTF-8 bytes.")
        }
        guard payload.count <= maximumPayloadBytes else {
            throw LibraryOperationAuthorityError.payloadTooLarge(
                bytes: payload.count, limit: maximumPayloadBytes)
        }
        guard updatedAt >= createdAt else {
            throw LibraryOperationAuthorityError.invalidPayload(
                "Operation update precedes creation.")
        }
    }

    private static func encoder() -> JSONEncoder { LibraryOperationCoding.encoder() }

    private static func decoder() -> JSONDecoder { LibraryOperationCoding.decoder() }
}

/// One deterministic encoder for everything persisted or compared in this file.
///
/// It used to be `private static` on `LibraryOperationSnapshot`, which is why the RECEIPT — a
/// different type in the same file — encoded its payload with a bare `JSONEncoder()` and got
/// unsorted keys. Receipt payloads are compared for idempotency, so those bytes have to be a
/// function of their contents and nothing else; unsorted, they were only accidentally stable, and
/// the test that caught it passed alone and failed in the full suite.
///
/// Shared rather than duplicated, so the next type in this file cannot make the same choice.
enum LibraryOperationCoding {
    static func encoder() -> JSONEncoder {
        let value = JSONEncoder()
        value.outputFormatting = [.sortedKeys]
        return value
    }

    static func decoder() -> JSONDecoder { JSONDecoder() }
}

struct LibraryOperationReceiptDetails: Codable, Equatable, Sendable {
    static let maximumDiagnosticsBytes = 16 * 1_024

    let diagnostics: String?
    let retainedSourceCount: Int

    init(diagnostics: String?, retainedSourceCount: Int) throws {
        guard retainedSourceCount >= 0 else {
            throw LibraryOperationAuthorityError.invalidPayload(
                "Receipt retained-source count cannot be negative.")
        }
        guard (diagnostics?.utf8.count ?? 0) <= Self.maximumDiagnosticsBytes else {
            throw LibraryOperationAuthorityError.invalidPayload(
                "Receipt diagnostics exceed \(Self.maximumDiagnosticsBytes) UTF-8 bytes.")
        }
        self.diagnostics = diagnostics
        self.retainedSourceCount = retainedSourceCount
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            diagnostics: values.decodeIfPresent(String.self, forKey: .diagnostics),
            retainedSourceCount: values.decode(Int.self, forKey: .retainedSourceCount))
    }
}

/// Receipts are separately versioned so an operation journal can retain multiple attempts without
/// mutating the operation's bounded intent payload.
struct LibraryOperationReceiptSnapshot: Codable, Equatable, Sendable {
    static let currentFormatVersion = 1
    static let currentPayloadVersion = 1
    static let maximumPayloadBytes = 64 * 1_024

    let formatVersion: Int
    let id: UUID
    let operationID: UUID
    let operationKind: LibraryOperationKind
    let state: LibraryOperationReceiptState
    let attempt: Int
    let recordedAt: Date
    let payloadVersion: Int
    let payload: Data

    init(
        id: UUID,
        operationID: UUID,
        operationKind: LibraryOperationKind,
        state: LibraryOperationReceiptState,
        attempt: Int,
        recordedAt: Date,
        details: LibraryOperationReceiptDetails
    ) throws {
        // THE DETERMINISTIC ENCODER, which exists two hundred lines below and this one call site
        // did not use. A receipt's payload is compared for idempotency — scanning the same envelope
        // twice must produce the same receipt — and an unsorted encoding makes those bytes depend on
        // dictionary ordering. It surfaced as a test that passed alone and failed in the full suite,
        // which is the signature of a value that is only accidentally stable.
        let payload = try LibraryOperationCoding.encoder().encode(details)
        try Self.validate(
            formatVersion: Self.currentFormatVersion,
            operationKind: operationKind,
            attempt: attempt,
            payloadVersion: Self.currentPayloadVersion,
            payload: payload)
        formatVersion = Self.currentFormatVersion
        self.id = id
        self.operationID = operationID
        self.operationKind = operationKind
        self.state = state
        self.attempt = attempt
        self.recordedAt = recordedAt
        payloadVersion = Self.currentPayloadVersion
        self.payload = payload
    }

    func details() throws -> LibraryOperationReceiptDetails {
        do {
            return try JSONDecoder().decode(LibraryOperationReceiptDetails.self, from: payload)
        } catch let error as LibraryOperationAuthorityError {
            throw error
        } catch {
            throw LibraryOperationAuthorityError.invalidPayload(error.localizedDescription)
        }
    }

    init(
        persistedFormatVersion: Int,
        id: UUID,
        operationID: UUID,
        operationKind: LibraryOperationKind,
        state: LibraryOperationReceiptState,
        attempt: Int,
        recordedAt: Date,
        payloadVersion: Int,
        payload: Data
    ) throws {
        try Self.validate(
            formatVersion: persistedFormatVersion,
            operationKind: operationKind,
            attempt: attempt,
            payloadVersion: payloadVersion,
            payload: payload)
        do {
            _ = try JSONDecoder().decode(LibraryOperationReceiptDetails.self, from: payload)
        } catch let error as LibraryOperationAuthorityError {
            throw error
        } catch {
            throw LibraryOperationAuthorityError.invalidPayload(error.localizedDescription)
        }
        formatVersion = persistedFormatVersion
        self.id = id
        self.operationID = operationID
        self.operationKind = operationKind
        self.state = state
        self.attempt = attempt
        self.recordedAt = recordedAt
        self.payloadVersion = payloadVersion
        self.payload = payload
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let formatVersion = try values.decode(Int.self, forKey: .formatVersion)
        let id = try values.decode(UUID.self, forKey: .id)
        let operationID = try values.decode(UUID.self, forKey: .operationID)
        let operationKind = try values.decode(LibraryOperationKind.self, forKey: .operationKind)
        let state = try values.decode(LibraryOperationReceiptState.self, forKey: .state)
        let attempt = try values.decode(Int.self, forKey: .attempt)
        let recordedAt = try values.decode(Date.self, forKey: .recordedAt)
        let payloadVersion = try values.decode(Int.self, forKey: .payloadVersion)
        let payload = try values.decode(Data.self, forKey: .payload)
        try Self.validate(
            formatVersion: formatVersion,
            operationKind: operationKind,
            attempt: attempt,
            payloadVersion: payloadVersion,
            payload: payload)
        do {
            _ = try JSONDecoder().decode(LibraryOperationReceiptDetails.self, from: payload)
        } catch let error as LibraryOperationAuthorityError {
            throw error
        } catch {
            throw LibraryOperationAuthorityError.invalidPayload(error.localizedDescription)
        }
        self.formatVersion = formatVersion
        self.id = id
        self.operationID = operationID
        self.operationKind = operationKind
        self.state = state
        self.attempt = attempt
        self.recordedAt = recordedAt
        self.payloadVersion = payloadVersion
        self.payload = payload
    }

    private static func validate(
        formatVersion: Int,
        operationKind: LibraryOperationKind,
        attempt: Int,
        payloadVersion: Int,
        payload: Data
    ) throws {
        guard formatVersion == currentFormatVersion else {
            throw LibraryOperationAuthorityError.unsupportedSnapshotVersion(formatVersion)
        }
        guard payloadVersion == currentPayloadVersion else {
            throw LibraryOperationAuthorityError.unsupportedPayloadVersion(
                kind: operationKind, version: payloadVersion)
        }
        guard attempt >= 0 else {
            throw LibraryOperationAuthorityError.invalidPayload(
                "Receipt attempt cannot be negative.")
        }
        guard payload.count <= maximumPayloadBytes else {
            throw LibraryOperationAuthorityError.payloadTooLarge(
                bytes: payload.count, limit: maximumPayloadBytes)
        }
    }
}

/// Builds the bounded identity-only facts reported by current legacy writers after their durable
/// publication succeeds. These are rehearsal observations, not a new product authority: callers
/// hand them to the active SQLite authority, and a failure to encode them never changes
/// the result of the already-completed legacy operation.
enum LibraryTransientOperationCaptureFactory {
    struct Capture: Sendable {
        let operation: LibraryOperationSnapshot
        let receipt: LibraryOperationReceiptSnapshot
    }

    static func backgroundAdoption(
        sourceIdentity: String,
        sourceRevision: String,
        sourceDigest: String,
        conversationID: UUID,
        recordedAt: Date = Date(),
        operationID: UUID = UUID()
    ) throws -> Capture {
        try capture(
            operation: .backgroundAdoption(
                id: operationID,
                state: .committed,
                idempotencyKey: "background-adoption:\(sourceIdentity):\(sourceDigest)",
                recordedAt: recordedAt,
                payload: LibraryBackgroundAdoptionOperationPayload(
                    sourceIdentity: sourceIdentity,
                    sourceRevision: sourceRevision,
                    sourceDigest: sourceDigest,
                    conversationID: conversationID)),
            receiptState: .applied,
            diagnostics: "Legacy background Conversation adoption published")
    }

    static func artifactDelete(
        artifactID: UUID,
        ownerConversationID: UUID?,
        reversed: Bool = false,
        recordedAt: Date = Date(),
        operationID: UUID = UUID()
    ) throws -> Capture {
        try capture(
            operation: .artifactDelete(
                id: operationID,
                state: reversed ? .reversed : .committed,
                idempotencyKey:
                    "artifact-\(reversed ? "restore" : "delete"):\(operationID.uuidString)",
                recordedAt: recordedAt,
                payload: LibraryArtifactDeleteOperationPayload(
                    artifactID: artifactID,
                    ownerConversationID: ownerConversationID)),
            receiptState: reversed ? .reversed : .applied,
            diagnostics: reversed
                ? "Legacy Artifact delete was undone"
                : "Legacy Artifact delete published")
    }

    static func workspaceMove(
        memberKind: LibraryWorkspaceMoveOperationPayload.MemberKind,
        memberIDs: Set<UUID>,
        sourceWorkspaceID: UUID?,
        destinationWorkspaceID: UUID?,
        isUndo: Bool = false,
        recordedAt: Date = Date(),
        operationID: UUID = UUID()
    ) throws -> Capture? {
        let source = sourceWorkspaceID ?? SQLiteLibraryStore.homeWorkspaceID
        let destination = destinationWorkspaceID ?? SQLiteLibraryStore.homeWorkspaceID
        guard source != destination, !memberIDs.isEmpty else { return nil }
        let sortedIDs = memberIDs.sorted { $0.uuidString < $1.uuidString }
        return try capture(
            operation: .workspaceMove(
                id: operationID,
                state: .committed,
                idempotencyKey:
                    "workspace-\(isUndo ? "undo" : "move"):\(operationID.uuidString)",
                recordedAt: recordedAt,
                payload: LibraryWorkspaceMoveOperationPayload(
                    memberKind: memberKind,
                    memberIDs: sortedIDs,
                    sourceWorkspaceID: source,
                    destinationWorkspaceID: destination)),
            receiptState: .applied,
            diagnostics: isUndo
                ? "Legacy Workspace move undo published"
                : "Legacy Workspace move published")
    }

    private static func capture(
        operation: LibraryOperationSnapshot,
        receiptState: LibraryOperationReceiptState,
        diagnostics: String
    ) throws -> Capture {
        Capture(
            operation: operation,
            receipt: try LibraryOperationReceiptSnapshot(
                id: operation.id,
                operationID: operation.id,
                operationKind: operation.kind,
                state: receiptState,
                attempt: 0,
                recordedAt: operation.updatedAt,
                details: LibraryOperationReceiptDetails(
                    diagnostics: diagnostics,
                    retainedSourceCount: 0)))
    }
}

/// Joins existing legacy persistence acknowledgements before publishing a transient operation into
/// the disposable shadow. The product action has already committed optimistically in the current
/// stores; any failed member leaves their normal retry banner as the explicit stop and suppresses
/// only this rehearsal receipt.
@MainActor
enum LibraryTransientOperationCapturePublisher {
    static func publish(
        _ captures: [LibraryTransientOperationCaptureFactory.Capture],
        afterConversations conversationIDs: Set<UUID>,
        in conversations: ConversationStore,
        artifactIDs: Set<UUID> = [],
        in artifactStore: ArtifactStore? = nil
    ) {
        guard !captures.isEmpty, conversations.recordsTransientOperations else { return }
        let sortedConversationIDs = conversationIDs.sorted { $0.uuidString < $1.uuidString }
        var remaining = sortedConversationIDs.count + (artifactIDs.isEmpty ? 0 : 1)
        var allSucceeded = true
        guard remaining > 0 else {
            conversations.recordTransientOperations(captures)
            return
        }
        let completed: (Bool) -> Void = { succeeded in
            allSucceeded = allSucceeded && succeeded
            remaining -= 1
            guard remaining == 0, allSucceeded else { return }
            conversations.recordTransientOperations(captures)
        }
        for id in sortedConversationIDs {
            conversations.awaitPublishedSnapshot(id) { completed($0 != nil) }
        }
        if !artifactIDs.isEmpty {
            guard let artifactStore else {
                completed(false)
                return
            }
            artifactStore.afterPendingPersistence(of: artifactIDs, completion: completed)
        }
    }
}

/// Joins an operation to immutable recovery bytes without copying those bytes into its payload.
struct LibraryOperationRetainedSourceEdge: Codable, Equatable, Sendable {
    enum Role: String, Codable, Equatable, Hashable, Sendable {
        case conversationSidecar = "conversation_sidecar"
        case conversationMedia = "conversation_media"
        case artifactSource = "artifact_source"
        case recoveryEnvelope = "recovery_envelope"
    }

    let operationID: UUID
    let retainedSourceIdentity: String
    let role: Role
}

struct LibraryConversationTrashScan: Sendable {
    struct OperationCandidate: Sendable {
        let operation: LibraryOperationSnapshot
        let conversationID: UUID
        let slotIdentity: String

        /// Logical identity of the synthesized operation intent. This must not reuse the physical
        /// trash-slot identity: a malformed slot can legitimately produce both a quarantined
        /// operation and an independently-accounted source issue for that directory.
        var authoritySourceIdentity: String {
            "operation-intents/\(operation.kind.rawValue)/\(operation.id.uuidString)"
        }
    }

    struct RetainedSourceCandidate: Sendable {
        enum Kind: String, Hashable, Sendable {
            case conversationSidecar = "conversation_sidecar"
            case conversationMedia = "conversation_media"
        }

        let kind: Kind
        let ownerConversationID: UUID
        let storageName: String
        let source: ShadowLibrarySourceFingerprint
    }

    struct Issue: Sendable {
        let operationID: UUID?
        let source: ShadowLibrarySourceFingerprint
        let kind: ShadowLibrarySourceIssueKind
        let diagnostics: String
    }

    var operations: [OperationCandidate] = []
    var retainedSources: [RetainedSourceCandidate] = []
    var retainedSourceEdges: [LibraryOperationRetainedSourceEdge] = []
    var issues: [Issue] = []
    var hasCompleteCensus = true

    /// Unlike `hasCompleteCensus`, this also requires every observed slot to be representable.
    var hasCompleteInventory: Bool { hasCompleteCensus && issues.isEmpty }
}

/// Read-only legacy trash inventory. It never follows a symlink or retains a giant Conversation
/// payload. Each sidecar/media file is independently descriptor-stable and SHA-256 fingerprinted.
enum LibraryConversationTrashScanner {
    private struct SlotName {
        let conversationID: UUID
        let token: UUID
    }

    private struct DescriptorMetadata: Equatable {
        let device: UInt64
        let inode: UInt64
        let size: Int64
        let modifiedSeconds: Int64
        let modifiedNanoseconds: Int64
        let changedSeconds: Int64
        let changedNanoseconds: Int64

        init(_ value: stat) {
            device = UInt64(value.st_dev)
            inode = UInt64(value.st_ino)
            size = Int64(value.st_size)
            modifiedSeconds = Int64(value.st_mtimespec.tv_sec)
            modifiedNanoseconds = Int64(value.st_mtimespec.tv_nsec)
            changedSeconds = Int64(value.st_ctimespec.tv_sec)
            changedNanoseconds = Int64(value.st_ctimespec.tv_nsec)
        }

        var revision: String {
            "dev:\(device);ino:\(inode);bytes:\(size);mtime:\(modifiedSeconds)."
                + "\(modifiedNanoseconds);ctime:\(changedSeconds).\(changedNanoseconds)"
        }

        var modifiedAt: Date {
            Date(timeIntervalSince1970:
                TimeInterval(modifiedSeconds) + TimeInterval(modifiedNanoseconds) / 1_000_000_000)
        }
    }

    private struct PendingSlot {
        let operationID: UUID
        let conversationID: UUID
        let slotIdentity: String
        let recordedAt: Date
        let retainedSources: [LibraryConversationTrashScan.RetainedSourceCandidate]
        let edges: [LibraryOperationRetainedSourceEdge]
        let issueCount: Int
    }

    /// The injection seam exists only to prove collision refusal. Production callers use the
    /// namespaced SHA-256 derivation.
    static func scan(
        supportRoot: URL,
        operationIDDeriver: (String) -> UUID = stableOperationID(slotName:)
    ) -> LibraryConversationTrashScan {
        let root = supportRoot.standardizedFileURL
        var result = LibraryConversationTrashScan()
        let trashRoot = root
            .appendingPathComponent("trash", isDirectory: true)
            .appendingPathComponent("conversations", isDirectory: true)
        guard validateOptionalDirectory(
            trashRoot, root: root, label: "Conversation trash root", into: &result) else {
            return result
        }
        guard let slots = directoryEntries(
            trashRoot, root: root, label: "Conversation trash root", into: &result) else {
            return result
        }

        var pending: [PendingSlot] = []
        for slot in slots {
            let slotIdentity = relativeIdentity(slot, root: root)
            guard isDirectoryNonSymlink(slot) else {
                result.issues.append(issue(
                    operationID: nil,
                    identity: slotIdentity,
                    revision: metadataRevision(slot),
                    kind: .malformed,
                    diagnostics: "Conversation trash slot is not a non-symlink directory."))
                continue
            }
            guard let parsed = parseSlotName(slot.lastPathComponent) else {
                // A real directory with an unrecognized identity may contain retained bytes that
                // cannot yet be assigned to an operation. Do not authorize closed-set pruning.
                result.hasCompleteCensus = false
                result.issues.append(issue(
                    operationID: nil,
                    identity: slotIdentity,
                    revision: metadataRevision(slot),
                    kind: .malformed,
                    diagnostics: "Conversation trash slot name is not <conversation UUID>-<unique UUID>."))
                continue
            }
            // Reading `token` proves the entire generated name parsed, even though the stable id is
            // intentionally derived from the complete name rather than one component.
            _ = parsed.token
            let operationID = operationIDDeriver(slot.lastPathComponent)
            let issueStart = result.issues.count
            guard let entries = directoryEntries(
                slot, root: root, label: "Conversation trash slot", into: &result) else {
                pending.append(PendingSlot(
                    operationID: operationID,
                    conversationID: parsed.conversationID,
                    slotIdentity: slotIdentity,
                    recordedAt: modifiedDate(slot),
                    retainedSources: [],
                    edges: [],
                    issueCount: result.issues.count - issueStart))
                continue
            }

            var sources: [LibraryConversationTrashScan.RetainedSourceCandidate] = []
            var edges: [LibraryOperationRetainedSourceEdge] = []
            let expectedSidecarName = "\(parsed.conversationID.uuidString).json"
            let expectedMediaName = parsed.conversationID.uuidString
            var sawSidecar = false
            var sawMediaDirectory = false

            for entry in entries {
                let identity = relativeIdentity(entry, root: root)
                if entry.lastPathComponent == expectedSidecarName {
                    guard !sawSidecar else {
                        result.issues.append(issue(
                            operationID: operationID,
                            identity: identity,
                            revision: metadataRevision(entry),
                            kind: .duplicate,
                            diagnostics: "Conversation trash slot contains a duplicate sidecar binding."))
                        continue
                    }
                    sawSidecar = true
                    appendFingerprintedSource(
                        entry,
                        kind: .conversationSidecar,
                        role: .conversationSidecar,
                        conversationID: parsed.conversationID,
                        operationID: operationID,
                        root: root,
                        sources: &sources,
                        edges: &edges,
                        result: &result)
                } else if entry.lastPathComponent == expectedMediaName {
                    guard !sawMediaDirectory else {
                        result.issues.append(issue(
                            operationID: operationID,
                            identity: identity,
                            revision: metadataRevision(entry),
                            kind: .duplicate,
                            diagnostics: "Conversation trash slot contains a duplicate media binding."))
                        continue
                    }
                    sawMediaDirectory = true
                    scanMediaDirectory(
                        entry,
                        conversationID: parsed.conversationID,
                        operationID: operationID,
                        root: root,
                        sources: &sources,
                        edges: &edges,
                        result: &result)
                } else {
                    result.issues.append(issue(
                        operationID: operationID,
                        identity: identity,
                        revision: metadataRevision(entry),
                        kind: .malformed,
                        diagnostics: "Conversation trash slot contains an unknown entry."))
                }
            }
            if !sawSidecar {
                result.issues.append(issue(
                    operationID: operationID,
                    identity: slotIdentity,
                    revision: metadataRevision(slot),
                    kind: .malformed,
                    diagnostics: "Conversation trash slot has no retained Conversation sidecar."))
            }
            pending.append(PendingSlot(
                operationID: operationID,
                conversationID: parsed.conversationID,
                slotIdentity: slotIdentity,
                recordedAt: modifiedDate(slot),
                retainedSources: sources,
                edges: edges,
                issueCount: result.issues.count - issueStart))
        }

        let grouped = Dictionary(grouping: pending, by: \.operationID)
        for operationID in grouped.keys.sorted(by: { $0.uuidString < $1.uuidString }) {
            guard let slots = grouped[operationID] else { continue }
            guard slots.count == 1, let slot = slots.first else {
                for collision in slots {
                    result.issues.append(issue(
                        operationID: operationID,
                        identity: collision.slotIdentity,
                        revision: "operation-id-collision",
                        kind: .duplicate,
                        diagnostics: "Distinct trash slots derived the same operation id; none were published."))
                }
                result.retainedSources.append(contentsOf: slots.flatMap(\.retainedSources))
                continue
            }
            do {
                let operation = try LibraryOperationSnapshot.conversationDelete(
                    id: operationID,
                    state: slot.issueCount == 0 ? .committed : .quarantined,
                    idempotencyKey: "legacy-trash:\(slot.slotIdentity)",
                    recordedAt: slot.recordedAt,
                    payload: LibraryConversationDeleteOperationPayload(
                        conversationID: slot.conversationID,
                        trashSlotIdentity: slot.slotIdentity,
                        queuePauseState: .unknownSafePaused))
                result.operations.append(LibraryConversationTrashScan.OperationCandidate(
                    operation: operation,
                    conversationID: slot.conversationID,
                    slotIdentity: slot.slotIdentity))
                result.retainedSources.append(contentsOf: slot.retainedSources)
                result.retainedSourceEdges.append(contentsOf: slot.edges)
            } catch {
                result.issues.append(issue(
                    operationID: operationID,
                    identity: slot.slotIdentity,
                    revision: "operation-encoding-failed",
                    kind: .importFailure,
                    diagnostics: "Conversation delete operation could not be encoded: \(error.localizedDescription)"))
                result.retainedSources.append(contentsOf: slot.retainedSources)
            }
        }

        result.operations.sort { $0.slotIdentity < $1.slotIdentity }
        result.retainedSources.sort { $0.source.identity < $1.source.identity }
        result.retainedSourceEdges.sort {
            ($0.operationID.uuidString, $0.retainedSourceIdentity, $0.role.rawValue)
                < ($1.operationID.uuidString, $1.retainedSourceIdentity, $1.role.rawValue)
        }
        result.issues.sort {
            ($0.source.identity, $0.diagnostics) < ($1.source.identity, $1.diagnostics)
        }
        return result
    }

    static func stableOperationID(slotName: String) -> UUID {
        let namespace = Data("mechanician:conversation-delete:v1\u{0}".utf8)
        let digest = SHA256.hash(data: namespace + Data(slotName.utf8))
        var bytes = Array(digest.prefix(16))
        // RFC 4122 variant plus a v5 marker communicates that this UUID is name-derived.
        bytes[6] = (bytes[6] & 0x0f) | 0x50
        bytes[8] = (bytes[8] & 0x3f) | 0x80
        let tuple: uuid_t = (
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15])
        return UUID(uuid: tuple)
    }

    private static func scanMediaDirectory(
        _ directory: URL,
        conversationID: UUID,
        operationID: UUID,
        root: URL,
        sources: inout [LibraryConversationTrashScan.RetainedSourceCandidate],
        edges: inout [LibraryOperationRetainedSourceEdge],
        result: inout LibraryConversationTrashScan
    ) {
        let identity = relativeIdentity(directory, root: root)
        guard isDirectoryNonSymlink(directory) else {
            result.issues.append(issue(
                operationID: operationID,
                identity: identity,
                revision: metadataRevision(directory),
                kind: .malformed,
                diagnostics: "Trashed Conversation media owner is not a non-symlink directory."))
            return
        }
        guard let files = directoryEntries(
            directory, root: root, label: "Trashed Conversation media owner", into: &result,
            operationID: operationID) else { return }
        for file in files {
            appendFingerprintedSource(
                file,
                kind: .conversationMedia,
                role: .conversationMedia,
                conversationID: conversationID,
                operationID: operationID,
                root: root,
                sources: &sources,
                edges: &edges,
                result: &result)
        }
    }

    private static func appendFingerprintedSource(
        _ url: URL,
        kind: LibraryConversationTrashScan.RetainedSourceCandidate.Kind,
        role: LibraryOperationRetainedSourceEdge.Role,
        conversationID: UUID,
        operationID: UUID,
        root: URL,
        sources: inout [LibraryConversationTrashScan.RetainedSourceCandidate],
        edges: inout [LibraryOperationRetainedSourceEdge],
        result: inout LibraryConversationTrashScan
    ) {
        let identity = relativeIdentity(url, root: root)
        do {
            let source = try fingerprintRegularFile(url, identity: identity)
            sources.append(LibraryConversationTrashScan.RetainedSourceCandidate(
                kind: kind,
                ownerConversationID: conversationID,
                storageName: url.lastPathComponent,
                source: source))
            edges.append(LibraryOperationRetainedSourceEdge(
                operationID: operationID,
                retainedSourceIdentity: identity,
                role: role))
        } catch {
            result.issues.append(issue(
                operationID: operationID,
                identity: identity,
                revision: metadataRevision(url),
                kind: .malformed,
                diagnostics: "Retained trash source could not be safely digested: \(error.localizedDescription)"))
        }
    }

    private static func fingerprintRegularFile(
        _ url: URL,
        identity: String
    ) throws -> ShadowLibrarySourceFingerprint {
        let descriptor = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        defer { Darwin.close(descriptor) }
        var beforeRaw = stat()
        guard fstat(descriptor, &beforeRaw) == 0 else {
            throw POSIXError(.init(rawValue: errno) ?? .EIO)
        }
        guard beforeRaw.st_mode & S_IFMT == S_IFREG, beforeRaw.st_size >= 0 else {
            throw CocoaError(.fileReadUnsupportedScheme)
        }
        let before = DescriptorMetadata(beforeRaw)
        var hasher = SHA256()
        var byteCount: Int64 = 0
        var buffer = Data(count: 1 * 1_024 * 1_024)
        while true {
            let count: Int = buffer.withUnsafeMutableBytes { raw in
                while true {
                    let value = Darwin.read(descriptor, raw.baseAddress, raw.count)
                    if value < 0 && errno == EINTR { continue }
                    return value
                }
            }
            guard count >= 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
            if count == 0 { break }
            byteCount += Int64(count)
            hasher.update(data: buffer.prefix(count))
        }
        var afterRaw = stat()
        guard fstat(descriptor, &afterRaw) == 0 else {
            throw POSIXError(.init(rawValue: errno) ?? .EIO)
        }
        let after = DescriptorMetadata(afterRaw)
        guard before == after, byteCount == before.size, byteCount <= Int64(Int.max) else {
            throw CocoaError(.fileReadUnknown)
        }
        return ShadowLibrarySourceFingerprint(
            identity: identity,
            revision: before.revision,
            digest: hasher.finalize().map { String(format: "%02x", $0) }.joined(),
            byteCount: Int(byteCount))
    }

    private static func parseSlotName(_ name: String) -> SlotName? {
        guard name.utf8.count == 73 else { return nil }
        let start = name.startIndex
        guard let separator = name.index(start, offsetBy: 36, limitedBy: name.endIndex),
              separator < name.endIndex,
              name[separator] == "-" else { return nil }
        let suffixStart = name.index(after: separator)
        guard let conversationID = UUID(uuidString: String(name[..<separator])),
              let token = UUID(uuidString: String(name[suffixStart...])) else { return nil }
        return SlotName(conversationID: conversationID, token: token)
    }

    private static func directoryEntries(
        _ directory: URL,
        root: URL,
        label: String,
        into result: inout LibraryConversationTrashScan,
        operationID: UUID? = nil
    ) -> [URL]? {
        do {
            return try FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil,
                options: [])
                .sorted { $0.lastPathComponent < $1.lastPathComponent }
        } catch {
            result.hasCompleteCensus = false
            result.issues.append(issue(
                operationID: operationID,
                identity: relativeIdentity(directory, root: root),
                revision: metadataRevision(directory),
                kind: .importFailure,
                diagnostics: "\(label) could not be enumerated: \(error.localizedDescription)"))
            return nil
        }
    }

    /// A missing optional root is a complete empty inventory. Every present component from the
    /// support root down must be a real directory so pathname traversal never crosses a symlink.
    private static func validateOptionalDirectory(
        _ directory: URL,
        root: URL,
        label: String,
        into result: inout LibraryConversationTrashScan
    ) -> Bool {
        let rootPath = root.path
        let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        guard directory.standardizedFileURL.path.hasPrefix(prefix) else {
            result.hasCompleteCensus = false
            result.issues.append(issue(
                operationID: nil,
                identity: directory.lastPathComponent,
                revision: "outside-support-root",
                kind: .malformed,
                diagnostics: "\(label) is outside the support root."))
            return false
        }
        var components = [root]
        var cursor = root
        let suffix = directory.standardizedFileURL.path.dropFirst(prefix.count)
        for component in suffix.split(separator: "/") {
            cursor.appendPathComponent(String(component), isDirectory: true)
            components.append(cursor)
        }
        for component in components {
            var value = stat()
            if lstat(component.path, &value) != 0 {
                if errno == ENOENT { return false }
                result.hasCompleteCensus = false
                result.issues.append(issue(
                    operationID: nil,
                    identity: relativeIdentity(component, root: root),
                    revision: "unavailable",
                    kind: .importFailure,
                    diagnostics: "\(label) could not be inspected."))
                return false
            }
            guard value.st_mode & S_IFMT == S_IFDIR else {
                result.hasCompleteCensus = false
                result.issues.append(issue(
                    operationID: nil,
                    identity: relativeIdentity(component, root: root),
                    revision: DescriptorMetadata(value).revision,
                    kind: .malformed,
                    diagnostics: "\(label) contains a non-directory path component and was not traversed."))
                return false
            }
        }
        return true
    }

    private static func isDirectoryNonSymlink(_ url: URL) -> Bool {
        var value = stat()
        return lstat(url.path, &value) == 0 && value.st_mode & S_IFMT == S_IFDIR
    }

    private static func modifiedDate(_ url: URL) -> Date {
        var value = stat()
        guard lstat(url.path, &value) == 0 else { return Date(timeIntervalSince1970: 0) }
        return DescriptorMetadata(value).modifiedAt
    }

    private static func metadataRevision(_ url: URL) -> String {
        var value = stat()
        guard lstat(url.path, &value) == 0 else { return "unavailable" }
        return DescriptorMetadata(value).revision
    }

    private static func relativeIdentity(_ url: URL, root: URL) -> String {
        let rootPath = root.path.hasSuffix("/") ? root.path : root.path + "/"
        let path = url.standardizedFileURL.path
        guard path.hasPrefix(rootPath) else { return url.lastPathComponent }
        return String(path.dropFirst(rootPath.count))
    }

    private static func issue(
        operationID: UUID?,
        identity: String,
        revision: String,
        kind: ShadowLibrarySourceIssueKind,
        diagnostics: String
    ) -> LibraryConversationTrashScan.Issue {
        LibraryConversationTrashScan.Issue(
            operationID: operationID,
            source: ShadowLibrarySourceFingerprint(
                identity: identity, revision: revision, sourceBytes: Data()),
            kind: kind,
            diagnostics: diagnostics)
    }
}
