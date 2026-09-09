import CryptoKit
import Darwin
import Foundation

/// Durable operation evidence left after the app has adopted an immutable external-producer
/// envelope. The envelope remains a Legacy-era recovery/source fact until the authority marker
/// changes; this scanner only inventories it for the existing operations reconciliation.
struct LibraryAuthorityInboxOperationScan: Sendable {
    struct Candidate: Sendable {
        let operation: LibraryOperationSnapshot
        let receipt: LibraryOperationReceiptSnapshot
        let source: ShadowLibrarySourceFingerprint
    }

    struct Issue: Sendable {
        let operationID: UUID?
        let source: ShadowLibrarySourceFingerprint
        let kind: ShadowLibrarySourceIssueKind
        let diagnostics: String
    }

    var operations: [Candidate] = []
    var issues: [Issue] = []
    var hasCompleteCensus = true
}

/// One fully validated v1 Conversation-create envelope ready for the app-owned adopter. The raw
/// bytes stay untouched so moving the file to `adopted/` becomes the durable Legacy receipt.
struct ValidatedAuthorityInboxConversationEnvelope {
    struct FileIdentity: Equatable {
        let device: UInt64
        let inode: UInt64
        let size: Int64
        let modifiedSeconds: Int64
        let modifiedNanoseconds: Int64
        let changedSeconds: Int64
        let changedNanoseconds: Int64
    }

    let operationID: UUID
    let conversationID: UUID
    let createdAt: Date
    let conversation: Conversation
    let rawBytes: Data
    let fileIdentity: FileIdentity
}

/// One finite Artifact upsert plus the exact retained UTF-8 source it references. The producer
/// never writes the Legacy Artifact store; this value is the only input the app-owned writer sees.
struct ValidatedAuthorityInboxArtifactEnvelope {
    let operationID: UUID
    let artifactID: UUID
    let createdAt: Date
    let artifact: Artifact
    let producerTaskID: String
    let rawBytes: Data
    let retainedSourceURL: URL
    let retainedSourceBytes: Data
    let fileIdentity: ValidatedAuthorityInboxConversationEnvelope.FileIdentity
}

enum ValidatedAuthorityInboxOperation {
    case conversation(ValidatedAuthorityInboxConversationEnvelope)
    case artifact(ValidatedAuthorityInboxArtifactEnvelope)

    var operationID: UUID {
        switch self {
        case .conversation(let envelope): envelope.operationID
        case .artifact(let envelope): envelope.operationID
        }
    }

    var createdAt: Date {
        switch self {
        case .conversation(let envelope): envelope.createdAt
        case .artifact(let envelope): envelope.createdAt
        }
    }

    var rawBytes: Data {
        switch self {
        case .conversation(let envelope): envelope.rawBytes
        case .artifact(let envelope): envelope.rawBytes
        }
    }

    var fileIdentity: ValidatedAuthorityInboxConversationEnvelope.FileIdentity {
        switch self {
        case .conversation(let envelope): envelope.fileIdentity
        case .artifact(let envelope): envelope.fileIdentity
        }
    }
}

/// Read-only v1 census for the app/producer handoff beneath `authority-inbox/v1`.
///
/// Producer bytes are untrusted in every state. Pending and staging sources are unresolved evidence
/// that makes the census incomplete; only adopted bytes may synthesize applied operations. Every
/// path component is inspected without following links, envelope files are descriptor-stable and
/// owner-private, and the finite v1 schema is revalidated before SQLite sees their identities.
enum LibraryAuthorityInboxOperationScanner {
    static let maximumPayloadBytes = 128 * 1_024 * 1_024
    static let maximumEnvelopeBytes = 192 * 1_024 * 1_024

    private static let protocolName = "storage-authority-v1"
    private static let producerID = "ambientd"
    private static let pendingComponents = ["authority-inbox", "v1", "pending", producerID]
    private static let stagingComponents = ["authority-inbox", "v1", "staging", producerID]
    private static let adoptedComponents = ["authority-inbox", "v1", "adopted", producerID]
    private static let quarantineComponents = ["authority-inbox", "v1", "quarantine", producerID]
    private static let sha256Pattern = try! NSRegularExpression(pattern: "^[a-f0-9]{64}$")
    private static let safeIdentifierPattern = try! NSRegularExpression(
        pattern: "^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$")
    private static let safeDomainPattern = try! NSRegularExpression(
        pattern: "^[a-z][a-z0-9._-]{0,63}$")

    private struct DescriptorMetadata: Equatable {
        let device: UInt64
        let inode: UInt64
        let size: Int64
        let mode: mode_t
        let owner: uid_t
        let links: UInt64
        let modifiedSeconds: Int64
        let modifiedNanoseconds: Int64
        let changedSeconds: Int64
        let changedNanoseconds: Int64

        init(_ value: stat) {
            device = UInt64(value.st_dev)
            inode = UInt64(value.st_ino)
            size = Int64(value.st_size)
            mode = value.st_mode
            owner = value.st_uid
            links = UInt64(value.st_nlink)
            modifiedSeconds = Int64(value.st_mtimespec.tv_sec)
            modifiedNanoseconds = Int64(value.st_mtimespec.tv_nsec)
            changedSeconds = Int64(value.st_ctimespec.tv_sec)
            changedNanoseconds = Int64(value.st_ctimespec.tv_nsec)
        }

        var revision: String {
            "dev:\(device);ino:\(inode);bytes:\(size);mtime:\(modifiedSeconds)."
                + "\(modifiedNanoseconds);ctime:\(changedSeconds).\(changedNanoseconds)"
        }
    }

    private struct ReadEnvelope {
        let bytes: Data
        let metadata: DescriptorMetadata
    }

    private struct ParsedEnvelope {
        let operationID: UUID
        let subjectID: UUID
        let createdAt: Date
        let domain: String
        let kind: String
        let payloadBytes: Data
        let retainedBytes: [ParsedRetainedByte]
    }

    private struct ParsedRetainedByte {
        let id: String
        let relativePath: String
        let byteCount: Int
        let sha256: String
        let mediaType: String?
    }

    /// Strict reader shared by live adoption and the durable post-adoption census. A producer's
    /// hard-link publication briefly has two names; that is a retryable state, not malformed input.
    static func readConversationCreate(
        at url: URL
    ) throws -> ValidatedAuthorityInboxConversationEnvelope {
        guard let filenameID = operationID(fromEnvelopeFilename: url.lastPathComponent) else {
            throw ScannerError.invalidEnvelopeFilename
        }
        let read = try readStablePrivateEnvelope(url)
        return try validatedConversationCreate(
            read: read, filenameOperationID: filenameID)
    }

    /// Strict domain dispatch for the live adopter. Adding a producer operation requires an
    /// explicit finite decoder here; an unknown domain/kind is quarantined instead of entering a
    /// permissive Codable model or being silently skipped.
    static func readOperation(
        at url: URL,
        supportRoot: URL
    ) throws -> ValidatedAuthorityInboxOperation {
        guard let filenameID = operationID(fromEnvelopeFilename: url.lastPathComponent) else {
            throw ScannerError.invalidEnvelopeFilename
        }
        let read = try readStablePrivateEnvelope(url)
        let parsed = try parseEnvelope(read.bytes)
        guard parsed.operationID == filenameID else {
            throw ScannerError.operationFilenameMismatch
        }
        return try validatedOperation(
            read: read,
            parsed: parsed,
            filenameOperationID: filenameID,
            supportRoot: supportRoot.standardizedFileURL)
    }

    private static func validatedOperation(
        read: ReadEnvelope,
        parsed: ParsedEnvelope,
        filenameOperationID: UUID,
        supportRoot: URL
    ) throws -> ValidatedAuthorityInboxOperation {
        switch (parsed.domain, parsed.kind) {
        case ("conversation", "create"):
            return .conversation(try validatedConversationCreate(
                read: read,
                parsed: parsed,
                filenameOperationID: filenameOperationID))
        case ("artifact", "upsert"):
            return .artifact(try validatedArtifactUpsert(
                read: read,
                parsed: parsed,
                filenameOperationID: filenameOperationID,
                supportRoot: supportRoot))
        default:
            throw ScannerError.unsupportedOperation
        }
    }

    private static func validatedConversationCreate(
        read: ReadEnvelope,
        filenameOperationID: UUID
    ) throws -> ValidatedAuthorityInboxConversationEnvelope {
        let parsed = try parseEnvelope(read.bytes)
        return try validatedConversationCreate(
            read: read,
            parsed: parsed,
            filenameOperationID: filenameOperationID)
    }

    private static func validatedConversationCreate(
        read: ReadEnvelope,
        parsed: ParsedEnvelope,
        filenameOperationID: UUID
    ) throws -> ValidatedAuthorityInboxConversationEnvelope {
        guard parsed.operationID == filenameOperationID else {
            throw ScannerError.operationFilenameMismatch
        }
        guard parsed.domain == "conversation", parsed.kind == "create" else {
            throw ScannerError.unsupportedOperation
        }
        guard parsed.retainedBytes.isEmpty else {
            throw ScannerError.unsupportedRetainedBytes
        }
        let conversation: Conversation
        do {
            conversation = try ConversationStore.makeDecoder().decode(
                Conversation.self, from: parsed.payloadBytes)
        } catch {
            throw ScannerError.invalidConversation
        }
        guard conversation.id == parsed.subjectID, conversation.hasDurableContent else {
            throw ScannerError.invalidConversation
        }
        return ValidatedAuthorityInboxConversationEnvelope(
            operationID: parsed.operationID,
            conversationID: parsed.subjectID,
            createdAt: parsed.createdAt,
            conversation: conversation,
            rawBytes: read.bytes,
            fileIdentity: ValidatedAuthorityInboxConversationEnvelope.FileIdentity(
                device: read.metadata.device,
                inode: read.metadata.inode,
                size: read.metadata.size,
                modifiedSeconds: read.metadata.modifiedSeconds,
                modifiedNanoseconds: read.metadata.modifiedNanoseconds,
                changedSeconds: read.metadata.changedSeconds,
                changedNanoseconds: read.metadata.changedNanoseconds))
    }

    private static func validatedArtifactUpsert(
        read: ReadEnvelope,
        parsed: ParsedEnvelope,
        filenameOperationID: UUID,
        supportRoot: URL
    ) throws -> ValidatedAuthorityInboxArtifactEnvelope {
        guard parsed.operationID == filenameOperationID else {
            throw ScannerError.operationFilenameMismatch
        }
        guard parsed.domain == "artifact", parsed.kind == "upsert" else {
            throw ScannerError.unsupportedOperation
        }
        guard parsed.retainedBytes.count == 1,
              let retained = parsed.retainedBytes.first,
              retained.id == "source",
              retained.relativePath == "retained/\(parsed.operationID.uuidString)/source" else {
            throw ScannerError.invalidRetainedBytes
        }
        guard let payload = try JSONSerialization.jsonObject(with: parsed.payloadBytes)
                as? [String: Any] else {
            throw ScannerError.invalidArtifact
        }
        try requireExactKeys(payload, ["artifact", "source"], label: "Artifact payload")
        guard let source = payload["source"] as? [String: Any] else {
            throw ScannerError.invalidArtifact
        }
        try requireExactKeys(
            source, ["retainedByteID", "encoding"], label: "Artifact source")
        guard source["retainedByteID"] as? String == "source",
              source["encoding"] as? String == "utf-8" else {
            throw ScannerError.invalidArtifact
        }
        guard let metadata = payload["artifact"] as? [String: Any] else {
            throw ScannerError.invalidArtifact
        }
        try requireExactKeys(
            metadata,
            [
                "id", "title", "type", "createdAt", "updatedAt", "revisions", "favorite",
                "origin", "taskId", "conversationID", "conversationTitle", "workspaceID", "cwd",
            ],
            label: "Artifact metadata")
        guard let artifactID = UUID(uuidString: try boundedString(
                metadata["id"], label: "Artifact id", maximum: 36)),
              artifactID == parsed.subjectID else {
            throw ScannerError.invalidArtifact
        }
        let title = try boundedString(
            metadata["title"], label: "Artifact title", maximum: 4_096)
        let type = try boundedString(
            metadata["type"], label: "Artifact type", maximum: 64, pattern: safeDomainPattern)
        guard ["html", "svg", "mermaid", "csv", "markdown"].contains(type) else {
            throw ScannerError.invalidArtifact
        }
        let expectedMediaType = [
            "html": "text/html; charset=utf-8",
            "svg": "image/svg+xml; charset=utf-8",
            "mermaid": "text/vnd.mermaid; charset=utf-8",
            "csv": "text/csv; charset=utf-8",
            "markdown": "text/markdown; charset=utf-8",
        ][type]
        guard retained.mediaType == expectedMediaType else {
            throw ScannerError.invalidRetainedBytes
        }
        let createdAtText = try boundedString(
            metadata["createdAt"], label: "Artifact createdAt", maximum: 32)
        let updatedAtText = try boundedString(
            metadata["updatedAt"], label: "Artifact updatedAt", maximum: 32)
        guard let artifactCreatedAt = artifactDate(createdAtText),
              let artifactUpdatedAt = artifactDate(updatedAtText),
              artifactUpdatedAt >= artifactCreatedAt,
              let revisions = integer(metadata["revisions"]), revisions > 0,
              revisions <= Int.max,
              let favorite = metadata["favorite"] as? Bool,
              metadata["origin"] as? String == "ambient" else {
            throw ScannerError.invalidArtifact
        }
        let producerTaskID = try boundedString(
            metadata["taskId"], label: "Artifact taskId", maximum: 128,
            pattern: safeIdentifierPattern)
        let conversationID = try optionalUUID(
            metadata["conversationID"], label: "Artifact conversationID")
        let workspaceID = try optionalUUID(
            metadata["workspaceID"], label: "Artifact workspaceID")
        let conversationTitle = try boundedStringAllowingEmpty(
            metadata["conversationTitle"], label: "Artifact conversationTitle", maximum: 4_096)
        let cwd = try boundedStringAllowingEmpty(
            metadata["cwd"], label: "Artifact cwd", maximum: 16 * 1_024)
        let retainedURL = try retainedByteURL(
            retained.relativePath,
            operationID: parsed.operationID,
            supportRoot: supportRoot)
        let sourceBytes = try readStableRetainedByte(
            retainedURL,
            expectedByteCount: retained.byteCount,
            expectedSHA256: retained.sha256)
        guard let sourceText = String(data: sourceBytes, encoding: .utf8),
              Data(sourceText.utf8) == sourceBytes else {
            throw ScannerError.invalidArtifact
        }
        let artifact = Artifact(
            title: title,
            type: type,
            source: sourceText,
            favorite: favorite,
            origin: "ambient",
            workspaceID: workspaceID,
            conversationID: conversationID,
            conversationTitle: conversationTitle,
            cwd: cwd,
            uuid: artifactID,
            createdAt: artifactCreatedAt,
            updatedAt: artifactUpdatedAt,
            revisions: revisions)
        return ValidatedAuthorityInboxArtifactEnvelope(
            operationID: parsed.operationID,
            artifactID: artifactID,
            createdAt: parsed.createdAt,
            artifact: artifact,
            producerTaskID: producerTaskID,
            rawBytes: read.bytes,
            retainedSourceURL: retainedURL,
            retainedSourceBytes: sourceBytes,
            fileIdentity: ValidatedAuthorityInboxConversationEnvelope.FileIdentity(
                device: read.metadata.device,
                inode: read.metadata.inode,
                size: read.metadata.size,
                modifiedSeconds: read.metadata.modifiedSeconds,
                modifiedNanoseconds: read.metadata.modifiedNanoseconds,
                changedSeconds: read.metadata.changedSeconds,
                changedNanoseconds: read.metadata.changedNanoseconds))
    }

    static func publicationIsIncomplete(_ error: Error) -> Bool {
        (error as? ScannerError) == .publicationIncomplete
    }

    static func fileStillMatches(
        _ expected: ValidatedAuthorityInboxConversationEnvelope.FileIdentity,
        at url: URL
    ) -> Bool {
        var value = stat()
        guard lstat(url.path, &value) == 0 else { return false }
        let actual = DescriptorMetadata(value)
        return actual.device == expected.device
            && actual.inode == expected.inode
            && actual.size == expected.size
            && actual.modifiedSeconds == expected.modifiedSeconds
            && actual.modifiedNanoseconds == expected.modifiedNanoseconds
            && actual.changedSeconds == expected.changedSeconds
            && actual.changedNanoseconds == expected.changedNanoseconds
            && actual.mode & S_IFMT == S_IFREG
            && actual.owner == geteuid()
            && actual.mode & 0o777 == 0o400
            && actual.links == 1
    }

    static func scan(supportRoot: URL) -> LibraryAuthorityInboxOperationScan {
        let root = supportRoot.standardizedFileURL
        var result = LibraryAuthorityInboxOperationScan()
        scanPending(root: root, into: &result)
        scanStaging(root: root, into: &result)
        scanAdopted(root: root, into: &result)
        scanQuarantine(root: root, into: &result)
        result.operations.sort { $0.source.identity < $1.source.identity }
        result.issues.sort {
            ($0.source.identity, $0.diagnostics) < ($1.source.identity, $1.diagnostics)
        }
        return result
    }

    /// A complete pending envelope has not crossed the app-owned receipt boundary yet. A two-link
    /// envelope is the producer's deliberate link-before-unlink crash window. Both are valid
    /// unresolved states, but neither can be pruned or mistaken for activation completeness.
    private static func scanPending(
        root: URL,
        into result: inout LibraryAuthorityInboxOperationScan
    ) {
        guard let directory = validatedOptionalDirectory(
            components: pendingComponents,
            root: root,
            label: "Pending authority inbox",
            into: &result)
        else { return }
        guard let entries = directoryEntries(
            directory, root: root, label: "Pending authority inbox", into: &result)
        else { return }

        for url in entries {
            result.hasCompleteCensus = false
            let filenameOperationID = operationID(fromEnvelopeFilename: url.lastPathComponent)
            do {
                guard let filenameOperationID else {
                    throw ScannerError.invalidEnvelopeFilename
                }
                let read = try readStablePrivateEnvelope(
                    url, allowingIncompletePublicationLink: true)
                let parsed = try parseEnvelope(read.bytes)
                _ = try validatedOperation(
                    read: read,
                    parsed: parsed,
                    filenameOperationID: filenameOperationID,
                    supportRoot: root)
                let source = ShadowLibrarySourceFingerprint(
                    identity: relativeIdentity(url, root: root),
                    revision: read.metadata.revision,
                    sourceBytes: read.bytes)
                let noun = parsed.domain == "artifact" ? "Artifact" : "Conversation"
                let state = read.metadata.links == 2
                    ? "is still in the producer hard-link publication window"
                    : "awaits app-owned \(noun) adoption"
                result.issues.append(LibraryAuthorityInboxOperationScan.Issue(
                    operationID: filenameOperationID,
                    source: source,
                    kind: .importFailure,
                    diagnostics: "Pending authority-inbox envelope \(state) and blocks activation."))
            } catch {
                result.issues.append(issue(
                    operationID: filenameOperationID,
                    url: url,
                    root: root,
                    kind: .malformed,
                    diagnostics:
                        "Pending authority-inbox source is unsafe or malformed: \(error.localizedDescription)"))
            }
        }
    }

    /// Staging is producer-owned pre-publication state. A 0600 single-link file may still be under
    /// construction; a 0400 file may be fsynced but not linked, or linked twice while pending wins
    /// publication. Those finite states remain unresolved. Other types, modes, owners, and link
    /// counts are hostile/abandoned evidence rather than a reason for the adopter to retry forever.
    private static func scanStaging(
        root: URL,
        into result: inout LibraryAuthorityInboxOperationScan
    ) {
        guard let directory = validatedOptionalDirectory(
            components: stagingComponents,
            root: root,
            label: "Staging authority inbox",
            into: &result)
        else { return }
        guard let entries = directoryEntries(
            directory, root: root, label: "Staging authority inbox", into: &result)
        else { return }

        for url in entries {
            result.hasCompleteCensus = false
            let filenameOperationID = operationID(fromStagingFilename: url.lastPathComponent)
            do {
                guard let filenameOperationID else {
                    throw ScannerError.invalidStagingFilename
                }
                let metadata = try privateStagingMetadata(at: url)
                let identity = relativeIdentity(url, root: root)
                let source: ShadowLibrarySourceFingerprint
                let detail: String
                if metadata.mode & 0o777 == 0o400 {
                    let read = try readStablePrivateEnvelope(
                        url, allowingIncompletePublicationLink: true)
                    let parsed = try parseEnvelope(read.bytes)
                    _ = try validatedOperation(
                        read: read,
                        parsed: parsed,
                        filenameOperationID: filenameOperationID,
                        supportRoot: root)
                    source = ShadowLibrarySourceFingerprint(
                        identity: identity,
                        revision: read.metadata.revision,
                        sourceBytes: read.bytes)
                    detail = read.metadata.links == 2
                        ? "is linked into pending but its staging alias remains"
                        : "is immutable but has not published into pending"
                } else {
                    source = ShadowLibrarySourceFingerprint(
                        identity: identity,
                        revision: metadata.revision,
                        sourceBytes: Data())
                    detail = "is still a mutable producer write"
                }
                result.issues.append(LibraryAuthorityInboxOperationScan.Issue(
                    operationID: filenameOperationID,
                    source: source,
                    kind: .importFailure,
                    diagnostics: "Staging authority-inbox envelope \(detail) and blocks activation."))
            } catch {
                result.issues.append(issue(
                    operationID: filenameOperationID,
                    url: url,
                    root: root,
                    kind: .malformed,
                    diagnostics:
                        "Staging authority-inbox source is unsafe or malformed: \(error.localizedDescription)"))
            }
        }
    }

    private static func scanAdopted(
        root: URL,
        into result: inout LibraryAuthorityInboxOperationScan
    ) {
        guard let directory = validatedOptionalDirectory(
            components: adoptedComponents,
            root: root,
            label: "Adopted authority inbox",
            into: &result)
        else { return }
        guard let entries = directoryEntries(
            directory, root: root, label: "Adopted authority inbox", into: &result)
        else { return }

        var candidates: [LibraryAuthorityInboxOperationScan.Candidate] = []
        for url in entries {
            let identity = relativeIdentity(url, root: root)
            let filenameOperationID = operationID(fromEnvelopeFilename: url.lastPathComponent)
            do {
                guard let filenameOperationID else {
                    throw ScannerError.invalidEnvelopeFilename
                }
                let read = try readStablePrivateEnvelope(url)
                let source = ShadowLibrarySourceFingerprint(
                    identity: identity,
                    revision: read.metadata.revision,
                    sourceBytes: read.bytes)
                let parsed = try parseEnvelope(read.bytes)
                let validated = try validatedOperation(
                    read: read,
                    parsed: parsed,
                    filenameOperationID: filenameOperationID,
                    supportRoot: root)
                let conversationID: UUID?
                let artifactID: UUID?
                let diagnostics: String
                let retainedSourceCount: Int
                switch validated {
                case .conversation(let envelope):
                    conversationID = envelope.conversationID
                    artifactID = nil
                    diagnostics = "Authority-inbox Conversation create adopted"
                    retainedSourceCount = 0
                case .artifact(let envelope):
                    conversationID = nil
                    artifactID = envelope.artifactID
                    diagnostics = "Authority-inbox Artifact upsert adopted"
                    retainedSourceCount = 1
                }
                let sourceRevision = "sha256:\(source.digest)"
                let operation = try LibraryOperationSnapshot.backgroundAdoption(
                    id: parsed.operationID,
                    state: .committed,
                    idempotencyKey: "authority-inbox-v1:\(parsed.operationID.uuidString)",
                    recordedAt: parsed.createdAt,
                    payload: LibraryBackgroundAdoptionOperationPayload(
                        sourceIdentity: identity,
                        sourceRevision: sourceRevision,
                        sourceDigest: source.digest,
                        conversationID: conversationID,
                        artifactID: artifactID))
                let receipt = try LibraryOperationReceiptSnapshot(
                    id: parsed.operationID,
                    operationID: parsed.operationID,
                    operationKind: .backgroundAdoption,
                    state: .applied,
                    attempt: 0,
                    recordedAt: parsed.createdAt,
                    details: LibraryOperationReceiptDetails(
                        diagnostics: diagnostics,
                        retainedSourceCount: retainedSourceCount))
                candidates.append(LibraryAuthorityInboxOperationScan.Candidate(
                    operation: operation,
                    receipt: receipt,
                    source: source))
            } catch {
                result.issues.append(issue(
                    operationID: filenameOperationID,
                    url: url,
                    root: root,
                    kind: .malformed,
                    diagnostics: "Adopted authority-inbox envelope is invalid: \(error.localizedDescription)"))
            }
        }

        // Case variants can name two files whose envelope operation UUID is logically identical.
        // Refuse all sides of a collision rather than letting directory order pick an authority.
        for group in Dictionary(grouping: candidates, by: { $0.operation.id }).values {
            guard group.count == 1, let candidate = group.first else {
                for candidate in group {
                    result.issues.append(LibraryAuthorityInboxOperationScan.Issue(
                        operationID: candidate.operation.id,
                        source: candidate.source,
                        kind: .duplicate,
                        diagnostics: "Multiple adopted envelopes claim the same operation identity."))
                }
                continue
            }
            result.operations.append(candidate)
        }
    }

    /// Quarantine is deliberately not decoded as an operation. Its retained source must remain in
    /// the closed-set census so activation reports the unresolved producer/adopter failure.
    private static func scanQuarantine(
        root: URL,
        into result: inout LibraryAuthorityInboxOperationScan
    ) {
        guard let directory = validatedOptionalDirectory(
            components: quarantineComponents,
            root: root,
            label: "Quarantined authority inbox",
            into: &result)
        else { return }
        guard let entries = directoryEntries(
            directory, root: root, label: "Quarantined authority inbox", into: &result)
        else { return }
        for url in entries {
            if url.lastPathComponent.hasSuffix(".diagnostic.json") {
                do {
                    _ = try readStablePrivateEnvelope(url)
                    continue
                } catch {
                    result.hasCompleteCensus = false
                    result.issues.append(issue(
                        operationID: operationID(
                            fromQuarantineFilename: url.lastPathComponent),
                        url: url,
                        root: root,
                        kind: .malformed,
                        diagnostics:
                            "Authority-inbox quarantine diagnostic is unsafe: \(error.localizedDescription)"))
                    continue
                }
            }
            let parsedOperationID: UUID?
            if let read = try? readStablePrivateEnvelope(url),
               let parsed = try? parseEnvelope(read.bytes) {
                parsedOperationID = parsed.operationID
            } else {
                parsedOperationID = operationID(fromQuarantineFilename: url.lastPathComponent)
            }
            result.hasCompleteCensus = false
            result.issues.append(issue(
                operationID: parsedOperationID,
                url: url,
                root: root,
                kind: .malformed,
                diagnostics: "Authority-inbox source remains quarantined and blocks activation."))
        }
    }

    private static func parseEnvelope(_ data: Data) throws -> ParsedEnvelope {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ScannerError.invalidTopLevel
        }
        try requireExactKeys(
            object,
            [
                "schemaVersion", "operationID", "subjectID", "producer", "authority",
                "domain", "kind", "definitionRevision", "createdAt", "payload",
                "retainedBytes",
            ],
            label: "top level")
        guard integer(object["schemaVersion"]) == 1 else {
            throw ScannerError.unsupportedSchema
        }
        let operationIDText = try boundedString(
            object["operationID"], label: "operationID", maximum: 128,
            pattern: safeIdentifierPattern)
        let subjectIDText = try boundedString(
            object["subjectID"], label: "subjectID", maximum: 128,
            pattern: safeIdentifierPattern)
        guard let operationID = UUID(uuidString: operationIDText),
              let subjectID = UUID(uuidString: subjectIDText) else {
            throw ScannerError.invalidUUID
        }

        guard let producer = object["producer"] as? [String: Any] else {
            throw ScannerError.invalidProducer
        }
        try requireExactKeys(producer, ["id", "build"], label: "producer")
        guard try boundedString(
            producer["id"], label: "producer id", maximum: 128,
            pattern: safeIdentifierPattern) == producerID else {
            throw ScannerError.invalidProducer
        }
        _ = try boundedString(
            producer["build"], label: "producer build", maximum: 128,
            pattern: safeIdentifierPattern)

        guard let authority = object["authority"] as? [String: Any] else {
            throw ScannerError.invalidAuthority
        }
        try requireExactKeys(
            authority, ["protocol", "observedGeneration"], label: "authority")
        guard authority["protocol"] as? String == protocolName else {
            throw ScannerError.invalidAuthority
        }
        _ = try boundedString(
            authority["observedGeneration"], label: "observed authority generation",
            maximum: 128, pattern: safeIdentifierPattern)

        let domain = try boundedString(
            object["domain"], label: "domain", maximum: 64,
            pattern: safeDomainPattern)
        let kind = try boundedString(
            object["kind"], label: "kind", maximum: 64,
            pattern: safeDomainPattern)
        if !(object["definitionRevision"] is NSNull) {
            _ = try boundedString(
                object["definitionRevision"], label: "definitionRevision", maximum: 16 * 1_024)
        }
        let createdAtText = try boundedString(
            object["createdAt"], label: "createdAt", maximum: 20)
        guard let createdAt = canonicalDate(createdAtText) else {
            throw ScannerError.invalidTimestamp
        }

        guard let payload = object["payload"] as? [String: Any] else {
            throw ScannerError.invalidPayload
        }
        try requireExactKeys(payload, ["encoding", "byteCount", "sha256", "data"], label: "payload")
        guard payload["encoding"] as? String == "base64url-json",
              let byteCount = integer(payload["byteCount"]),
              byteCount >= 0,
              byteCount <= maximumPayloadBytes else {
            throw ScannerError.invalidPayload
        }
        let payloadDigest = try boundedString(
            payload["sha256"], label: "payload sha256", maximum: 64, pattern: sha256Pattern)
        guard let encodedPayload = payload["data"] as? String,
              let payloadBytes = canonicalBase64URLData(encodedPayload),
              payloadBytes.count == byteCount,
              sha256(payloadBytes) == payloadDigest,
              (try? JSONSerialization.jsonObject(with: payloadBytes)) != nil else {
            throw ScannerError.invalidPayload
        }
        guard let retainedValues = object["retainedBytes"] as? [Any],
              retainedValues.count <= 64 else {
            throw ScannerError.invalidRetainedBytes
        }
        var retainedBytes: [ParsedRetainedByte] = []
        var retainedIDs = Set<String>()
        for value in retainedValues {
            guard let reference = value as? [String: Any] else {
                throw ScannerError.invalidRetainedBytes
            }
            try requireExactKeys(
                reference,
                ["id", "relativePath", "byteCount", "sha256", "mediaType"],
                label: "retained byte")
            let id = try boundedString(
                reference["id"], label: "retained byte id", maximum: 128,
                pattern: safeIdentifierPattern)
            guard retainedIDs.insert(id).inserted,
                  let retainedByteCount = integer(reference["byteCount"]),
                  retainedByteCount >= 0,
                  retainedByteCount <= maximumPayloadBytes else {
                throw ScannerError.invalidRetainedBytes
            }
            let relativePath = try boundedString(
                reference["relativePath"], label: "retained byte path", maximum: 512)
            let expectedPrefix = "retained/\(operationID.uuidString)/"
            guard !relativePath.hasPrefix("/"),
                  !relativePath.contains("\\"),
                  !relativePath.contains("\0"),
                  relativePath.hasPrefix(expectedPrefix),
                  !relativePath.dropFirst(expectedPrefix.count).contains("/"),
                  !relativePath.split(separator: "/").contains(where: {
                    $0 == "." || $0 == ".." || $0.isEmpty
                  }) else {
                throw ScannerError.invalidRetainedBytes
            }
            let retainedDigest = try boundedString(
                reference["sha256"], label: "retained byte sha256", maximum: 64,
                pattern: sha256Pattern)
            let mediaType: String?
            if reference["mediaType"] is NSNull {
                mediaType = nil
            } else {
                mediaType = try boundedString(
                    reference["mediaType"], label: "retained byte media type", maximum: 255)
            }
            retainedBytes.append(ParsedRetainedByte(
                id: id,
                relativePath: relativePath,
                byteCount: retainedByteCount,
                sha256: retainedDigest,
                mediaType: mediaType))
        }
        return ParsedEnvelope(
            operationID: operationID,
            subjectID: subjectID,
            createdAt: createdAt,
            domain: domain,
            kind: kind,
            payloadBytes: payloadBytes,
            retainedBytes: retainedBytes)
    }

    private static func readStablePrivateEnvelope(
        _ url: URL,
        allowingIncompletePublicationLink: Bool = false
    ) throws -> ReadEnvelope {
        let descriptor = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        defer { Darwin.close(descriptor) }
        var beforeRaw = stat()
        guard fstat(descriptor, &beforeRaw) == 0 else {
            throw POSIXError(.init(rawValue: errno) ?? .EIO)
        }
        let before = DescriptorMetadata(beforeRaw)
        guard before.mode & S_IFMT == S_IFREG,
              before.size >= 0,
              before.size <= Int64(maximumEnvelopeBytes),
              before.owner == geteuid(),
              before.mode & 0o777 == 0o400 else {
            throw ScannerError.unsafeEnvelope
        }
        if before.links == 2, !allowingIncompletePublicationLink {
            throw ScannerError.publicationIncomplete
        }
        guard before.links == 1 || (allowingIncompletePublicationLink && before.links == 2) else {
            throw ScannerError.unsafeEnvelope
        }
        var bytes = Data()
        bytes.reserveCapacity(Int(before.size))
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
            bytes.append(buffer.prefix(count))
        }
        var afterRaw = stat()
        guard fstat(descriptor, &afterRaw) == 0 else {
            throw POSIXError(.init(rawValue: errno) ?? .EIO)
        }
        guard DescriptorMetadata(afterRaw) == before, bytes.count == before.size else {
            throw ScannerError.changedDuringRead
        }
        return ReadEnvelope(bytes: bytes, metadata: before)
    }

    private static func privateStagingMetadata(at url: URL) throws -> DescriptorMetadata {
        var value = stat()
        guard lstat(url.path, &value) == 0 else {
            throw POSIXError(.init(rawValue: errno) ?? .EIO)
        }
        let metadata = DescriptorMetadata(value)
        guard metadata.mode & S_IFMT == S_IFREG,
              metadata.size >= 0,
              metadata.size <= Int64(maximumEnvelopeBytes),
              metadata.owner == geteuid(),
              metadata.mode & 0o777 == 0o600 || metadata.mode & 0o777 == 0o400,
              metadata.links == 1 || metadata.links == 2 else {
            throw ScannerError.unsafeEnvelope
        }
        return metadata
    }

    private static func validatedOptionalDirectory(
        components: [String],
        root: URL,
        label: String,
        into result: inout LibraryAuthorityInboxOperationScan
    ) -> URL? {
        var cursor = root
        for (index, component) in components.enumerated() {
            cursor.appendPathComponent(component, isDirectory: true)
            var metadata = stat()
            if lstat(cursor.path, &metadata) != 0 {
                if errno == ENOENT { return nil }
                result.hasCompleteCensus = false
                result.issues.append(issue(
                    operationID: nil,
                    url: cursor,
                    root: root,
                    kind: .importFailure,
                    diagnostics: "\(label) could not be inspected."))
                return nil
            }
            guard metadata.st_mode & S_IFMT == S_IFDIR,
                  metadata.st_uid == getuid(),
                  metadata.st_mode & 0o077 == 0 else {
                result.hasCompleteCensus = false
                result.issues.append(issue(
                    operationID: nil,
                    url: cursor,
                    root: root,
                    kind: .malformed,
                    diagnostics: "\(label) contains an unsafe path component at index \(index)."))
                return nil
            }
        }
        return cursor
    }

    private static func directoryEntries(
        _ directory: URL,
        root: URL,
        label: String,
        into result: inout LibraryAuthorityInboxOperationScan
    ) -> [URL]? {
        do {
            return try FileManager.default.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: nil, options: [])
                .sorted { $0.lastPathComponent < $1.lastPathComponent }
        } catch {
            result.hasCompleteCensus = false
            result.issues.append(issue(
                operationID: nil,
                url: directory,
                root: root,
                kind: .importFailure,
                diagnostics: "\(label) could not be enumerated: \(error.localizedDescription)"))
            return nil
        }
    }

    private static func issue(
        operationID: UUID?,
        url: URL,
        root: URL,
        kind: ShadowLibrarySourceIssueKind,
        diagnostics: String
    ) -> LibraryAuthorityInboxOperationScan.Issue {
        let identity = relativeIdentity(url, root: root)
        let source: ShadowLibrarySourceFingerprint
        if let read = try? readStablePrivateEnvelope(url) {
            source = ShadowLibrarySourceFingerprint(
                identity: identity,
                revision: read.metadata.revision,
                sourceBytes: read.bytes)
        } else {
            source = ShadowLibrarySourceFingerprint(
                identity: identity,
                revision: metadataRevision(url),
                sourceBytes: Data())
        }
        return LibraryAuthorityInboxOperationScan.Issue(
            operationID: operationID,
            source: source,
            kind: kind,
            diagnostics: diagnostics)
    }

    private static func requireExactKeys(
        _ object: [String: Any],
        _ expected: Set<String>,
        label: String
    ) throws {
        guard Set(object.keys) == expected else {
            throw ScannerError.unexpectedFields(label)
        }
    }

    private static func boundedString(
        _ value: Any?,
        label: String,
        maximum: Int,
        pattern: NSRegularExpression? = nil
    ) throws -> String {
        guard let value = value as? String,
              !value.isEmpty,
              value.utf8.count <= maximum else {
            throw ScannerError.invalidString(label)
        }
        if let pattern {
            let range = NSRange(value.startIndex..<value.endIndex, in: value)
            guard pattern.firstMatch(in: value, range: range)?.range == range else {
                throw ScannerError.invalidString(label)
            }
        }
        return value
    }

    private static func boundedStringAllowingEmpty(
        _ value: Any?,
        label: String,
        maximum: Int
    ) throws -> String {
        guard let value = value as? String, value.utf8.count <= maximum else {
            throw ScannerError.invalidString(label)
        }
        return value
    }

    private static func optionalUUID(_ value: Any?, label: String) throws -> UUID? {
        if value is NSNull { return nil }
        guard let text = value as? String, let id = UUID(uuidString: text) else {
            throw ScannerError.invalidString(label)
        }
        return id
    }

    private static func retainedByteURL(
        _ relativePath: String,
        operationID: UUID,
        supportRoot: URL
    ) throws -> URL {
        let components = relativePath.split(separator: "/", omittingEmptySubsequences: false)
        guard components.count == 3,
              components[0] == "retained",
              UUID(uuidString: String(components[1])) == operationID,
              components[2] == "source" else {
            throw ScannerError.invalidRetainedBytes
        }
        var cursor = supportRoot
        for component in ["authority-inbox", "v1", "retained", String(components[1])] {
            cursor.appendPathComponent(component, isDirectory: true)
            var metadata = stat()
            guard lstat(cursor.path, &metadata) == 0,
                  metadata.st_mode & S_IFMT == S_IFDIR,
                  metadata.st_uid == geteuid(),
                  metadata.st_mode & 0o077 == 0 else {
                throw ScannerError.unsafeRetainedByte
            }
        }
        return cursor.appendingPathComponent(String(components[2]), isDirectory: false)
    }

    private static func readStableRetainedByte(
        _ url: URL,
        expectedByteCount: Int,
        expectedSHA256: String
    ) throws -> Data {
        let descriptor = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw ScannerError.unsafeRetainedByte }
        defer { _ = Darwin.close(descriptor) }
        var beforeRaw = stat()
        guard fstat(descriptor, &beforeRaw) == 0 else {
            throw ScannerError.unsafeRetainedByte
        }
        let before = DescriptorMetadata(beforeRaw)
        guard before.mode & S_IFMT == S_IFREG,
              before.owner == geteuid(),
              before.mode & 0o777 == 0o400,
              before.links == 1,
              before.size == expectedByteCount,
              before.size >= 0,
              before.size <= maximumPayloadBytes else {
            throw ScannerError.unsafeRetainedByte
        }
        var bytes = Data()
        bytes.reserveCapacity(expectedByteCount)
        var buffer = Data(count: min(1 * 1_024 * 1_024, max(1, expectedByteCount)))
        while true {
            let count = buffer.withUnsafeMutableBytes { raw -> Int in
                while true {
                    let value = Darwin.read(descriptor, raw.baseAddress, raw.count)
                    if value < 0, errno == EINTR { continue }
                    return value
                }
            }
            guard count >= 0 else { throw ScannerError.unsafeRetainedByte }
            if count == 0 { break }
            bytes.append(buffer.prefix(count))
        }
        var afterRaw = stat()
        guard fstat(descriptor, &afterRaw) == 0,
              DescriptorMetadata(afterRaw) == before,
              bytes.count == expectedByteCount,
              sha256(bytes) == expectedSHA256 else {
            throw ScannerError.changedDuringRead
        }
        return bytes
    }

    private static func integer(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let double = number.doubleValue
        guard double.isFinite, double.rounded(.towardZero) == double,
              double >= Double(Int.min), double <= Double(Int.max) else { return nil }
        return Int(double)
    }

    private static func canonicalDate(_ text: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss'Z'"
        formatter.isLenient = false
        guard let date = formatter.date(from: text), formatter.string(from: date) == text else {
            return nil
        }
        return date
    }

    private static func artifactDate(_ text: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: text), fractional.string(from: date) == text {
            return date
        }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        guard let date = plain.date(from: text), plain.string(from: date) == text else {
            return nil
        }
        return date
    }

    private static func canonicalBase64URLData(_ text: String) -> Data? {
        guard !text.contains("="), text.utf8.allSatisfy({ byte in
            (65...90).contains(byte) || (97...122).contains(byte)
                || (48...57).contains(byte) || byte == 45 || byte == 95
        }), text.utf8.count % 4 != 1 else { return nil }
        var standard = text.replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        standard += String(repeating: "=", count: (4 - standard.utf8.count % 4) % 4)
        guard let data = Data(base64Encoded: standard) else { return nil }
        let canonical = data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return canonical == text ? data : nil
    }

    private static func operationID(fromEnvelopeFilename name: String) -> UUID? {
        guard name.hasSuffix(".json") else { return nil }
        return UUID(uuidString: String(name.dropLast(5)))
    }

    private static func operationID(fromStagingFilename name: String) -> UUID? {
        guard name.first == ".", name.hasSuffix(".tmp") else { return nil }
        let body = name.dropFirst().dropLast(4)
        guard let separator = body.firstIndex(of: ".") else { return nil }
        return UUID(uuidString: String(body[..<separator]))
    }

    private static func operationID(fromQuarantineFilename name: String) -> UUID? {
        guard name.hasSuffix(".json") else { return nil }
        let stem = name.dropLast(5)
        let first = stem.split(separator: ".", maxSplits: 1).first.map(String.init)
        return first.flatMap(UUID.init(uuidString:))
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func relativeIdentity(_ url: URL, root: URL) -> String {
        let rootPath = root.path.hasSuffix("/") ? root.path : root.path + "/"
        let path = url.standardizedFileURL.path
        guard path.hasPrefix(rootPath) else { return url.lastPathComponent }
        return String(path.dropFirst(rootPath.count))
    }

    private static func metadataRevision(_ url: URL) -> String {
        var value = stat()
        guard lstat(url.path, &value) == 0 else { return "unavailable" }
        return DescriptorMetadata(value).revision
    }

    private enum ScannerError: Error, LocalizedError, Equatable {
        case invalidTopLevel
        case unsupportedSchema
        case invalidEnvelopeFilename
        case invalidStagingFilename
        case operationFilenameMismatch
        case invalidUUID
        case invalidProducer
        case invalidAuthority
        case unsupportedOperation
        case invalidTimestamp
        case invalidPayload
        case invalidConversation
        case invalidArtifact
        case invalidRetainedBytes
        case unsupportedRetainedBytes
        case unsafeEnvelope
        case unsafeRetainedByte
        case publicationIncomplete
        case changedDuringRead
        case unexpectedFields(String)
        case invalidString(String)

        var errorDescription: String? {
            switch self {
            case .invalidTopLevel: "Envelope top level is not an object."
            case .unsupportedSchema: "Envelope schemaVersion is unsupported."
            case .invalidEnvelopeFilename: "Envelope filename is not <operation UUID>.json."
            case .invalidStagingFilename: "Staging filename does not carry an operation UUID."
            case .operationFilenameMismatch: "Envelope filename does not match operationID."
            case .invalidUUID: "Envelope operation or subject identity is not a UUID."
            case .invalidProducer: "Envelope producer is unsupported."
            case .invalidAuthority: "Envelope authority observation is invalid."
            case .unsupportedOperation: "Envelope operation domain or kind is unsupported."
            case .invalidTimestamp: "Envelope createdAt is not canonical UTC seconds."
            case .invalidPayload: "Envelope payload bytes, digest, or JSON are invalid."
            case .invalidConversation: "Envelope payload is not a durable completed Conversation."
            case .invalidArtifact: "Envelope payload is not a valid finite Artifact upsert."
            case .invalidRetainedBytes: "Envelope retained-byte references are invalid."
            case .unsupportedRetainedBytes: "Conversation create v1 cannot retain separate bytes."
            case .unsafeEnvelope: "Envelope is not a private, single-link regular file."
            case .unsafeRetainedByte: "Envelope retained bytes are missing, unsafe, or incomplete."
            case .publicationIncomplete: "Envelope publication is not complete yet."
            case .changedDuringRead: "Envelope changed while it was read."
            case .unexpectedFields(let label): "Envelope \(label) contains unexpected fields."
            case .invalidString(let label): "Envelope \(label) is invalid or exceeds its bound."
            }
        }
    }
}
