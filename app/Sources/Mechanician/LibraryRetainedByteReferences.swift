import CryptoKit
import Darwin
import Foundation
import UniformTypeIdentifiers

enum LibraryRetainedBytePermissionError: Error, Equatable, LocalizedError {
    case invalidIdentity(String)
    case permissions(String)
    case verification(String)

    var errorDescription: String? {
        switch self {
        case .invalidIdentity(let detail): return "Invalid retained-byte identity: \(detail)"
        case .permissions(let detail): return "Retained-byte permission failure: \(detail)"
        case .verification(let detail): return "Retained-byte verification failure: \(detail)"
        }
    }
}

/// Tightens one verified legacy-layout media source without resolving it through an absolute path.
/// The support root is opened once and every child is traversed with `openat` + `O_NOFOLLOW`, so a
/// symlink swap cannot turn adoption into chmod of an external user file.
enum LibraryRetainedBytePermissionAdopter {
    private static let digestBufferBytes = 1_024 * 1_024

    /// Returns the descriptor-verified post-adoption fingerprint. The caller must persist this
    /// value—not the earlier scanner fingerprint—because the first permission tightening changes
    /// ctime. The test seam runs after mutation but before the final path-to-descriptor identity
    /// check, making replacement races deterministic without weakening the production call.
    static func adopt(
        source: ShadowLibrarySourceFingerprint,
        supportRoot: URL,
        beforeFinalIdentityValidation: (() throws -> Void)? = nil
    ) throws -> ShadowLibrarySourceFingerprint {
        try protect(
            source: source,
            supportRoot: supportRoot,
            fileMode: 0o600,
            beforeFinalIdentityValidation: beforeFinalIdentityValidation)
    }

    /// Makes an inventoried but unclaimed source immutable without manufacturing an ownership
    /// edge. The returned post-chmod fingerprint is the exact byte identity persisted by SQLite
    /// and bound into backup/reverse-root evidence.
    static func protectUnclaimedRecovery(
        source: ShadowLibrarySourceFingerprint,
        supportRoot: URL,
        beforeFinalIdentityValidation: (() throws -> Void)? = nil
    ) throws -> ShadowLibrarySourceFingerprint {
        try protect(
            source: source,
            supportRoot: supportRoot,
            fileMode: 0o400,
            beforeFinalIdentityValidation: beforeFinalIdentityValidation)
    }

    private static func protect(
        source: ShadowLibrarySourceFingerprint,
        supportRoot: URL,
        fileMode: mode_t,
        beforeFinalIdentityValidation: (() throws -> Void)?
    ) throws -> ShadowLibrarySourceFingerprint {
        let components = source.identity.split(separator: "/", omittingEmptySubsequences: false)
            .map(String.init)
        guard components.count == 3,
              components[0] == "conversation-media",
              UUID(uuidString: components[1]) != nil,
              !components[2].isEmpty,
              components[2] != ".",
              components[2] != ".." else {
            throw LibraryRetainedBytePermissionError.invalidIdentity(source.identity)
        }
        guard source.byteCount >= 0, isSHA256(source.digest) else {
            throw LibraryRetainedBytePermissionError.verification(
                "expected fingerprint is malformed")
        }
        let rootFD = Darwin.open(
            supportRoot.standardizedFileURL.path,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard rootFD >= 0 else { throw posix("could not open support root") }
        defer { Darwin.close(rootFD) }
        let root = try require(
            rootFD, type: S_IFDIR, ownerOnly: true, label: "support root")

        let mediaFD = openatDirectory(components[0], parent: rootFD)
        guard mediaFD >= 0 else { throw posix("could not open conversation-media") }
        defer { Darwin.close(mediaFD) }
        let mediaBefore = try require(
            mediaFD, type: S_IFDIR, ownerOnly: false, label: "conversation-media")

        let ownerFD = openatDirectory(components[1], parent: mediaFD)
        guard ownerFD >= 0 else { throw posix("could not open Conversation media directory") }
        defer { Darwin.close(ownerFD) }
        let ownerBefore = try require(
            ownerFD,
            type: S_IFDIR,
            ownerOnly: false,
            label: "Conversation media directory")

        let fileFD = components[2].withCString {
            openat(ownerFD, $0, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        }
        guard fileFD >= 0 else { throw posix("could not open retained byte") }
        defer { Darwin.close(fileFD) }
        let fileBefore = try require(
            fileFD, type: S_IFREG, ownerOnly: false, label: "retained byte")
        guard fileBefore.revision == source.revision,
              fileBefore.size == Int64(source.byteCount) else {
            throw LibraryRetainedBytePermissionError.verification(
                "opened retained byte does not match the inventoried revision and size")
        }
        let openedDigest = try digest(descriptor: fileFD, expected: fileBefore)
        guard openedDigest.byteCount == source.byteCount,
              openedDigest.sha256.caseInsensitiveCompare(source.digest) == .orderedSame else {
            throw LibraryRetainedBytePermissionError.verification(
                "opened retained byte does not match the inventoried digest and size")
        }

        _ = try protect(mediaFD, mode: 0o700, type: S_IFDIR, label: "conversation-media")
        _ = try protect(
            ownerFD,
            mode: 0o700,
            type: S_IFDIR,
            label: "Conversation media directory")
        let protectedFile = try protect(
            fileFD, mode: fileMode, type: S_IFREG, label: "retained byte")
        guard protectedFile.sameObjectAndContent(as: fileBefore) else {
            throw LibraryRetainedBytePermissionError.verification(
                "retained byte changed during permission adoption")
        }

        try beforeFinalIdentityValidation?()

        try requirePath(
            components[0],
            parent: rootFD,
            names: mediaFD,
            expected: mediaBefore,
            type: S_IFDIR,
            label: "conversation-media")
        try requirePath(
            components[1],
            parent: mediaFD,
            names: ownerFD,
            expected: ownerBefore,
            type: S_IFDIR,
            label: "Conversation media directory")
        let finalFile = try requirePath(
            components[2],
            parent: ownerFD,
            names: fileFD,
            expected: protectedFile,
            type: S_IFREG,
            label: "retained byte")
        guard root.sameObject(as: try require(
            rootFD, type: S_IFDIR, ownerOnly: true, label: "support root")),
              finalFile.sameObjectAndContent(as: fileBefore),
              finalFile.size == Int64(source.byteCount) else {
            throw LibraryRetainedBytePermissionError.verification(
                "retained-byte identity changed during permission adoption")
        }
        return ShadowLibrarySourceFingerprint(
            identity: source.identity,
            revision: finalFile.revision,
            digest: source.digest.lowercased(),
            byteCount: source.byteCount)
    }

    private struct DescriptorMetadata: Equatable {
        let device: UInt64
        let inode: UInt64
        let size: Int64
        let modifiedSeconds: Int64
        let modifiedNanoseconds: Int64
        let changedSeconds: Int64
        let changedNanoseconds: Int64
        let permissions: mode_t

        init(_ value: stat) {
            device = UInt64(value.st_dev)
            inode = UInt64(value.st_ino)
            size = Int64(value.st_size)
            modifiedSeconds = Int64(value.st_mtimespec.tv_sec)
            modifiedNanoseconds = Int64(value.st_mtimespec.tv_nsec)
            changedSeconds = Int64(value.st_ctimespec.tv_sec)
            changedNanoseconds = Int64(value.st_ctimespec.tv_nsec)
            permissions = value.st_mode & 0o777
        }

        var revision: String {
            "dev:\(device);ino:\(inode);bytes:\(size);mtime:\(modifiedSeconds)."
                + "\(modifiedNanoseconds);ctime:\(changedSeconds).\(changedNanoseconds)"
        }

        func sameObject(as other: DescriptorMetadata) -> Bool {
            device == other.device && inode == other.inode
        }

        func sameObjectAndContent(as other: DescriptorMetadata) -> Bool {
            sameObject(as: other)
                && size == other.size
                && modifiedSeconds == other.modifiedSeconds
                && modifiedNanoseconds == other.modifiedNanoseconds
        }
    }

    private struct OpenedDigest {
        let byteCount: Int
        let sha256: String
    }

    private static func openatDirectory(_ name: String, parent: Int32) -> Int32 {
        name.withCString {
            openat(parent, $0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        }
    }

    @discardableResult
    private static func protect(
        _ descriptor: Int32,
        mode: mode_t,
        type: mode_t,
        label: String
    ) throws -> DescriptorMetadata {
        let before = try require(
            descriptor, type: type, ownerOnly: false, label: label)
        if before.permissions != mode {
            guard fchmod(descriptor, mode) == 0 else {
                throw posix("could not protect \(label)")
            }
        }
        return try require(descriptor, type: type, ownerOnly: true, label: label)
    }

    private static func require(
        _ descriptor: Int32,
        type: mode_t,
        ownerOnly: Bool,
        label: String
    ) throws -> DescriptorMetadata {
        var value = stat()
        guard fstat(descriptor, &value) == 0,
              value.st_mode & S_IFMT == type,
              (!ownerOnly || value.st_mode & 0o077 == 0) else {
            throw LibraryRetainedBytePermissionError.permissions(
                "\(label) is not an owner-only expected file type")
        }
        return DescriptorMetadata(value)
    }

    @discardableResult
    private static func requirePath(
        _ name: String,
        parent: Int32,
        names descriptor: Int32,
        expected: DescriptorMetadata,
        type: mode_t,
        label: String
    ) throws -> DescriptorMetadata {
        var pathValue = stat()
        let result = name.withCString {
            fstatat(parent, $0, &pathValue, AT_SYMLINK_NOFOLLOW)
        }
        guard result == 0,
              pathValue.st_mode & S_IFMT == type else {
            throw LibraryRetainedBytePermissionError.verification(
                "\(label) path no longer names the expected file type")
        }
        let descriptorValue = try require(
            descriptor, type: type, ownerOnly: true, label: label)
        let pathMetadata = DescriptorMetadata(pathValue)
        guard pathMetadata.sameObject(as: descriptorValue),
              descriptorValue.sameObject(as: expected) else {
            throw LibraryRetainedBytePermissionError.verification(
                "\(label) path was replaced during permission adoption")
        }
        return descriptorValue
    }

    private static func digest(
        descriptor: Int32,
        expected: DescriptorMetadata
    ) throws -> OpenedDigest {
        var hasher = SHA256()
        var total = 0
        var buffer = Data(count: digestBufferBytes)
        while true {
            let count: Int = buffer.withUnsafeMutableBytes { rawBuffer in
                while true {
                    let value = Darwin.read(descriptor, rawBuffer.baseAddress, rawBuffer.count)
                    if value < 0 && errno == EINTR { continue }
                    return value
                }
            }
            guard count >= 0 else { throw posix("could not read retained byte") }
            if count == 0 { break }
            guard total <= Int.max - count else {
                throw LibraryRetainedBytePermissionError.verification(
                    "retained byte size overflowed")
            }
            total += count
            hasher.update(data: buffer.prefix(count))
        }
        let after = try require(
            descriptor, type: S_IFREG, ownerOnly: false, label: "retained byte")
        guard after == expected, total == Int(expected.size) else {
            throw LibraryRetainedBytePermissionError.verification(
                "retained byte changed while being checksummed")
        }
        return OpenedDigest(
            byteCount: total,
            sha256: hasher.finalize().map { String(format: "%02x", $0) }.joined())
    }

    private static func isSHA256(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy {
            ($0 >= 48 && $0 <= 57) || ($0 >= 65 && $0 <= 70) || ($0 >= 97 && $0 <= 102)
        }
    }

    private static func posix(_ action: String) -> LibraryRetainedBytePermissionError {
        .permissions("\(action): \(String(cString: strerror(errno)))")
    }
}

/// One durable edge from a Conversation fact to bytes expected in the app-owned media layout.
///
/// This is deliberately schema-neutral. A later repository adapter may persist these values, but
/// extraction itself neither opens `library.db` nor treats a pathname as byte authority. The source
/// identity matches `ArtifactMediaSourceScanner`'s support-root-relative identity so reconciliation
/// can join an edge to the descriptor-verified physical inventory without consulting live paths.
struct LibraryRetainedByteReferenceCandidate: Equatable, Hashable, Sendable {
    enum LocalStateOwner: Equatable, Hashable, Sendable {
        case draft
        case queuedPrompt(index: Int)
        case pendingTurnPrompt
        case providerAccessResumePrompt(requestID: UUID, index: Int)
    }

    enum Owner: Equatable, Hashable, Sendable {
        case event(entryID: UUID, messageIndex: Int)
        case localState(LocalStateOwner)

        fileprivate var sortKey: String {
            switch self {
            case .event(let entryID, let index):
                return "0:event:\(String(format: "%09d", index)):\(entryID.uuidString)"
            case .localState(.draft):
                return "1:local:draft"
            case .localState(.queuedPrompt(let index)):
                return "1:local:queue:\(String(format: "%09d", index))"
            case .localState(.pendingTurnPrompt):
                return "1:local:pending"
            case .localState(.providerAccessResumePrompt(let requestID, let index)):
                return "1:local:provider-access:\(requestID.uuidString):\(String(format: "%09d", index))"
            }
        }
    }

    enum Evidence: String, Equatable, Hashable, Sendable {
        case fileToken = "file_token"
        case imagePathInText = "image_path_in_text"
        case imagePathsField = "image_paths_field"
        case toolImage = "tool_image"
    }

    let conversationID: UUID
    let owner: Owner
    let storageName: String
    let sourceIdentity: String
    /// Empty means the reference format did not retain an expected size. More than one distinct
    /// value is a source conflict and must not be healed by choosing whichever happens to match.
    let expectedByteCounts: Set<Int>
    /// These are UTI identifiers, matching the existing physical scanner's `mediaType` value.
    let expectedMediaTypes: Set<String>
    /// Text and `imagePaths` commonly restate one image edge. Keeping the evidence set preserves
    /// provenance without manufacturing two byte references.
    let evidence: Set<Evidence>

    fileprivate var sortKey: String {
        "\(owner.sortKey):\(sourceIdentity):"
            + expectedByteCounts.sorted().map(String.init).joined(separator: ",") + ":"
            + expectedMediaTypes.sorted().joined(separator: ",")
    }
}

/// An absolute user/repository path mentioned by a Conversation. It is provenance, not an
/// app-managed retained-byte edge, and is therefore kept out of managed-byte reconciliation.
struct LibraryExternalAbsolutePathReferenceCandidate: Equatable, Hashable, Sendable {
    let conversationID: UUID
    let owner: LibraryRetainedByteReferenceCandidate.Owner
    let path: String
    let evidence: Set<LibraryRetainedByteReferenceCandidate.Evidence>

    fileprivate var sortKey: String { "\(owner.sortKey):\(path)" }
}

/// A path that points into Mechanician's media root but cannot be owned safely by this
/// Conversation. Cross-Conversation and malformed media paths are neither external documents nor
/// valid managed references; keeping them explicit lets readiness fail closed.
struct LibraryInvalidManagedByteReferenceCandidate: Equatable, Hashable, Sendable {
    enum Reason: String, Equatable, Hashable, Sendable {
        case invalidToolImageName = "invalid_tool_image_name"
        case invalidOrCrossOwnerMediaPath = "invalid_or_cross_owner_media_path"
    }

    let conversationID: UUID
    let owner: LibraryRetainedByteReferenceCandidate.Owner
    let value: String
    let evidence: LibraryRetainedByteReferenceCandidate.Evidence
    let reason: Reason

    fileprivate var sortKey: String {
        "\(owner.sortKey):\(reason.rawValue):\(value):\(evidence.rawValue)"
    }
}

struct LibraryRetainedByteReferenceExtraction: Equatable, Sendable {
    let managedReferences: [LibraryRetainedByteReferenceCandidate]
    let externalAbsolutePaths: [LibraryExternalAbsolutePathReferenceCandidate]
    let invalidManagedReferences: [LibraryInvalidManagedByteReferenceCandidate]
}

/// Descriptor-verified inventory input. Digest equality never establishes reference identity: two
/// names with identical bytes remain two independently referenced physical sources.
struct LibraryRetainedByteObservedSource: Equatable, Hashable, Sendable {
    let sourceIdentity: String
    let revision: String
    let digest: String
    let byteCount: Int
    let mediaType: String
    let isAdopted: Bool
    let isUnclaimedRecovery: Bool

    init(
        sourceIdentity: String,
        revision: String = "",
        digest: String,
        byteCount: Int,
        mediaType: String,
        isAdopted: Bool = false,
        isUnclaimedRecovery: Bool = false
    ) {
        self.sourceIdentity = sourceIdentity
        self.revision = revision
        self.digest = digest
        self.byteCount = byteCount
        self.mediaType = mediaType
        self.isAdopted = isAdopted
        self.isUnclaimedRecovery = isUnclaimedRecovery
    }

    var fingerprint: ShadowLibrarySourceFingerprint {
        ShadowLibrarySourceFingerprint(
            identity: sourceIdentity,
            revision: revision,
            digest: digest,
            byteCount: byteCount)
    }
}

struct LibraryRetainedByteReferenceMatch: Equatable, Sendable {
    let reference: LibraryRetainedByteReferenceCandidate
    let source: LibraryRetainedByteObservedSource
}

struct LibraryRetainedByteReferenceMismatch: Equatable, Sendable {
    enum Reason: Equatable, Hashable, Sendable {
        case ambiguousInventory(sourceCount: Int)
        case byteCount(expected: Set<Int>, actual: Int)
        case mediaType(expected: Set<String>, actual: String)
    }

    let reference: LibraryRetainedByteReferenceCandidate
    let sources: [LibraryRetainedByteObservedSource]
    let reasons: Set<Reason>
}

struct LibraryRetainedByteReferenceResolution: Equatable, Sendable {
    let matched: [LibraryRetainedByteReferenceMatch]
    let missing: [LibraryRetainedByteReferenceCandidate]
    let mismatched: [LibraryRetainedByteReferenceMismatch]
    let unreferenced: [LibraryRetainedByteObservedSource]
}

/// One schema adapter shared by migration reconciliation and the active SQLite writer. Stable IDs
/// make an unchanged logical edge idempotent across activation, relaunch, and later media commits.
enum LibraryRetainedByteReferenceAdapter {
    static func capture(
        _ candidate: LibraryRetainedByteReferenceCandidate
    ) -> ShadowLibraryRetainedByteReferenceSnapshot {
        let ownerKind: ShadowLibraryRetainedByteReferenceSnapshot.OwnerKind
        let ownerEventID: UUID?
        let ownerKey: String
        switch candidate.owner {
        case .event(let entryID, let messageIndex):
            ownerKind = .event
            ownerEventID = entryID
            ownerKey = "message:\(messageIndex):\(entryID.uuidString)"
        case .localState(.draft):
            ownerKind = .localState
            ownerEventID = nil
            ownerKey = "local:draft"
        case .localState(.queuedPrompt(let index)):
            ownerKind = .localState
            ownerEventID = nil
            ownerKey = "local:queue:\(index)"
        case .localState(.pendingTurnPrompt):
            ownerKind = .localState
            ownerEventID = nil
            ownerKey = "local:pending-turn"
        case .localState(.providerAccessResumePrompt(let requestID, let index)):
            ownerKind = .localState
            ownerEventID = nil
            ownerKey = "local:provider-access:\(requestID.uuidString):\(index)"
        }
        let evidence = candidate.evidence.map(\.rawValue).sorted().joined(separator: "+")
        let referenceKind = "\(ownerKey)|\(evidence)"
        return ShadowLibraryRetainedByteReferenceSnapshot(
            id: stableID(
                conversationID: candidate.conversationID,
                namespace: "retained-byte-reference",
                sourceID: "\(referenceKind)|\(candidate.sourceIdentity)"),
            retainedSourceIdentity: candidate.sourceIdentity,
            ownerKind: ownerKind,
            ownerConversationID: candidate.conversationID,
            ownerEventID: ownerEventID,
            referenceKind: referenceKind)
    }

    private static func stableID(
        conversationID: UUID,
        namespace: String,
        sourceID: String
    ) -> UUID {
        let digest = SHA256.hash(data: Data(
            "\(conversationID.uuidString)|\(namespace)|\(sourceID)".utf8))
        var hex = digest.prefix(16).map { String(format: "%02x", $0) }.joined()
        hex.replaceSubrange(
            hex.index(hex.startIndex, offsetBy: 12)...hex.index(hex.startIndex, offsetBy: 12),
            with: "5")
        hex.replaceSubrange(
            hex.index(hex.startIndex, offsetBy: 16)...hex.index(hex.startIndex, offsetBy: 16),
            with: "8")
        let pieces = [8, 4, 4, 4, 12]
        var cursor = hex.startIndex
        let value = pieces.map { length -> String in
            let end = hex.index(cursor, offsetBy: length)
            defer { cursor = end }
            return String(hex[cursor..<end])
        }.joined(separator: "-")
        return UUID(uuidString: value)!
    }
}

enum LibraryRetainedByteReferenceExtractor {
    static func extract(
        from conversation: Conversation,
        supportRoot: URL,
        externalPathExists: @escaping (String) -> Bool = FileManager.default.fileExists(atPath:)
    ) -> LibraryRetainedByteReferenceExtraction {
        let builder = Builder(
            conversationID: conversation.id,
            supportRoot: supportRoot,
            externalPathExists: externalPathExists)

        for (index, entry) in conversation.messages.enumerated() {
            let owner = LibraryRetainedByteReferenceCandidate.Owner.event(
                entryID: entry.id,
                messageIndex: index)
            builder.recordText(entry.text, owner: owner)
            for path in entry.imagePaths ?? [] {
                builder.recordImagePath(
                    path,
                    owner: owner,
                    evidence: LibraryRetainedByteReferenceCandidate.Evidence.imagePathsField)
            }
            if let toolImage = entry.toolImage {
                builder.recordToolImage(toolImage, owner: owner)
            }
        }

        builder.recordText(
            conversation.draft,
            owner: LibraryRetainedByteReferenceCandidate.Owner.localState(.draft))
        for (index, prompt) in conversation.queuedPrompts.enumerated() {
            builder.recordText(
                prompt,
                owner: LibraryRetainedByteReferenceCandidate.Owner.localState(
                    .queuedPrompt(index: index)))
        }
        if let prompt = conversation.pendingTurnPrompt {
            builder.recordText(
                prompt,
                owner: LibraryRetainedByteReferenceCandidate.Owner.localState(
                    .pendingTurnPrompt))
        }
        if let request = conversation.providerAccessRequest {
            for (index, prompt) in request.resumePrompts.enumerated() {
                builder.recordText(
                    prompt,
                    owner: LibraryRetainedByteReferenceCandidate.Owner.localState(
                        .providerAccessResumePrompt(
                            requestID: request.id,
                            index: index)))
            }
        }
        return builder.finish()
    }

    static func resolve(
        _ extraction: LibraryRetainedByteReferenceExtraction,
        against observedSources: [LibraryRetainedByteObservedSource]
    ) -> LibraryRetainedByteReferenceResolution {
        let grouped = Dictionary(grouping: observedSources, by: \.sourceIdentity)
        var matched: [LibraryRetainedByteReferenceMatch] = []
        var missing: [LibraryRetainedByteReferenceCandidate] = []
        var mismatched: [LibraryRetainedByteReferenceMismatch] = []

        for reference in extraction.managedReferences {
            let sources = (grouped[reference.sourceIdentity] ?? []).sorted(by: sourcePrecedes)
            guard !sources.isEmpty else {
                missing.append(reference)
                continue
            }
            guard sources.count == 1, let source = sources.first else {
                mismatched.append(LibraryRetainedByteReferenceMismatch(
                    reference: reference,
                    sources: sources,
                    reasons: [.ambiguousInventory(sourceCount: sources.count)]))
                continue
            }
            var reasons = Set<LibraryRetainedByteReferenceMismatch.Reason>()
            if reference.expectedByteCounts.count > 1
                || (reference.expectedByteCounts.first.map { $0 != source.byteCount } ?? false) {
                reasons.insert(.byteCount(
                    expected: reference.expectedByteCounts,
                    actual: source.byteCount))
            }
            if reference.expectedMediaTypes.count > 1
                || (reference.expectedMediaTypes.first.map { $0 != source.mediaType } ?? false) {
                reasons.insert(.mediaType(
                    expected: reference.expectedMediaTypes,
                    actual: source.mediaType))
            }
            if reasons.isEmpty {
                matched.append(LibraryRetainedByteReferenceMatch(
                    reference: reference,
                    source: source))
            } else {
                mismatched.append(LibraryRetainedByteReferenceMismatch(
                    reference: reference,
                    sources: [source],
                    reasons: reasons))
            }
        }

        let referencedIdentities = Set(extraction.managedReferences.map(\.sourceIdentity))
        let unreferenced = observedSources
            .filter { !referencedIdentities.contains($0.sourceIdentity) }
            .sorted(by: sourcePrecedes)
        return LibraryRetainedByteReferenceResolution(
            matched: matched.sorted { $0.reference.sortKey < $1.reference.sortKey },
            missing: missing.sorted { $0.sortKey < $1.sortKey },
            mismatched: mismatched.sorted { $0.reference.sortKey < $1.reference.sortKey },
            unreferenced: unreferenced)
    }

    private static func sourcePrecedes(
        _ lhs: LibraryRetainedByteObservedSource,
        _ rhs: LibraryRetainedByteObservedSource
    ) -> Bool {
        if lhs.sourceIdentity != rhs.sourceIdentity {
            return lhs.sourceIdentity < rhs.sourceIdentity
        }
        if lhs.digest != rhs.digest { return lhs.digest < rhs.digest }
        if lhs.byteCount != rhs.byteCount { return lhs.byteCount < rhs.byteCount }
        return lhs.mediaType < rhs.mediaType
    }

    private final class Builder {
        private struct ManagedKey: Hashable {
            let owner: LibraryRetainedByteReferenceCandidate.Owner
            let storageName: String
        }

        private struct ManagedValue {
            var byteCounts = Set<Int>()
            var mediaTypes = Set<String>()
            var evidence = Set<LibraryRetainedByteReferenceCandidate.Evidence>()
        }

        private struct ExternalKey: Hashable {
            let owner: LibraryRetainedByteReferenceCandidate.Owner
            let path: String
        }

        private let conversationID: UUID
        private let mediaRoot: URL
        private let ownedDirectory: URL
        private let mediaStorage: ConversationMediaStorage
        private let externalPathExists: (String) -> Bool
        private var managed: [ManagedKey: ManagedValue] = [:]
        private var external: [ExternalKey: Set<LibraryRetainedByteReferenceCandidate.Evidence>] = [:]
        private var invalid = Set<LibraryInvalidManagedByteReferenceCandidate>()

        init(
            conversationID: UUID,
            supportRoot: URL,
            externalPathExists: @escaping (String) -> Bool
        ) {
            self.conversationID = conversationID
            mediaRoot = supportRoot.standardizedFileURL
                .appendingPathComponent("conversation-media", isDirectory: true)
                .standardizedFileURL
            ownedDirectory = mediaRoot
                .appendingPathComponent(conversationID.uuidString, isDirectory: true)
                .standardizedFileURL
            mediaStorage = ConversationMediaStorage(root: mediaRoot)
            self.externalPathExists = externalPathExists
        }

        func recordText(
            _ text: String,
            owner: LibraryRetainedByteReferenceCandidate.Owner
        ) {
            guard !text.isEmpty else { return }
            for match in ConversationFileReference.matches(in: text) {
                guard let url = mediaStorage.composerFileURL(
                    conversationID: conversationID,
                    reference: match.reference) else { continue }
                recordManaged(
                    url: url,
                    owner: owner,
                    evidence: .fileToken,
                    expectedByteCount: match.reference.byteCount,
                    expectedMediaType: match.reference.typeIdentifier)
            }
            // Missing app-owned images still have to become missing edges. The existing detector's
            // injectable existence check lets exact, syntactically owned media paths participate
            // without blessing arbitrary missing absolute paths as real external documents.
            for match in ImagePathDetector.matches(in: text, fileExists: { [weak self] path in
                guard let self else { return false }
                return self.isInsideMediaRoot(path) || self.externalPathExists(path)
            }) {
                recordImagePath(match.path, owner: owner, evidence: .imagePathInText)
            }
        }

        func recordImagePath(
            _ path: String,
            owner: LibraryRetainedByteReferenceCandidate.Owner,
            evidence: LibraryRetainedByteReferenceCandidate.Evidence
        ) {
            guard (path as NSString).isAbsolutePath else { return }
            let url = URL(fileURLWithPath: path).standardizedFileURL
            if mediaStorage.ownsComposerImagePath(url.path, conversationID: conversationID) {
                recordManaged(
                    url: url,
                    owner: owner,
                    evidence: evidence,
                    expectedByteCount: nil,
                    expectedMediaType: UTType(filenameExtension: url.pathExtension)?.identifier)
            } else if isInsideMediaRoot(url.path) {
                invalid.insert(LibraryInvalidManagedByteReferenceCandidate(
                    conversationID: conversationID,
                    owner: owner,
                    value: url.path,
                    evidence: evidence,
                    reason: .invalidOrCrossOwnerMediaPath))
            } else {
                let key = ExternalKey(owner: owner, path: url.path)
                external[key, default: []].insert(evidence)
            }
        }

        func recordToolImage(
            _ reference: ToolImageReference,
            owner: LibraryRetainedByteReferenceCandidate.Owner
        ) {
            guard let url = mediaStorage.imageURL(
                conversationID: conversationID,
                reference: reference) else {
                invalid.insert(LibraryInvalidManagedByteReferenceCandidate(
                    conversationID: conversationID,
                    owner: owner,
                    value: reference.fileName,
                    evidence: .toolImage,
                    reason: .invalidToolImageName))
                return
            }
            recordManaged(
                url: url,
                owner: owner,
                evidence: .toolImage,
                expectedByteCount: nil,
                expectedMediaType: UTType.png.identifier)
        }

        func finish() -> LibraryRetainedByteReferenceExtraction {
            let managedReferences = managed.map { key, value in
                LibraryRetainedByteReferenceCandidate(
                    conversationID: conversationID,
                    owner: key.owner,
                    storageName: key.storageName,
                    sourceIdentity: sourceIdentity(storageName: key.storageName),
                    expectedByteCounts: value.byteCounts,
                    expectedMediaTypes: value.mediaTypes,
                    evidence: value.evidence)
            }.sorted { $0.sortKey < $1.sortKey }
            let externalReferences = external.map { key, evidence in
                LibraryExternalAbsolutePathReferenceCandidate(
                    conversationID: conversationID,
                    owner: key.owner,
                    path: key.path,
                    evidence: evidence)
            }.sorted { $0.sortKey < $1.sortKey }
            return LibraryRetainedByteReferenceExtraction(
                managedReferences: managedReferences,
                externalAbsolutePaths: externalReferences,
                invalidManagedReferences: invalid.sorted { $0.sortKey < $1.sortKey })
        }

        private func recordManaged(
            url: URL,
            owner: LibraryRetainedByteReferenceCandidate.Owner,
            evidence: LibraryRetainedByteReferenceCandidate.Evidence,
            expectedByteCount: Int?,
            expectedMediaType: String?
        ) {
            let normalized = url.standardizedFileURL
            guard normalized.deletingLastPathComponent() == ownedDirectory else {
                invalid.insert(LibraryInvalidManagedByteReferenceCandidate(
                    conversationID: conversationID,
                    owner: owner,
                    value: normalized.path,
                    evidence: evidence,
                    reason: .invalidOrCrossOwnerMediaPath))
                return
            }
            let key = ManagedKey(owner: owner, storageName: normalized.lastPathComponent)
            var value = managed[key] ?? ManagedValue()
            if let expectedByteCount { value.byteCounts.insert(expectedByteCount) }
            if let expectedMediaType, !expectedMediaType.isEmpty {
                value.mediaTypes.insert(expectedMediaType)
            }
            value.evidence.insert(evidence)
            managed[key] = value
        }

        private func sourceIdentity(storageName: String) -> String {
            "conversation-media/\(conversationID.uuidString)/\(storageName)"
        }

        private func isInsideMediaRoot(_ path: String) -> Bool {
            let normalized = URL(fileURLWithPath: path).standardizedFileURL.path
            let prefix = mediaRoot.path.hasSuffix("/") ? mediaRoot.path : mediaRoot.path + "/"
            return normalized == mediaRoot.path || normalized.hasPrefix(prefix)
        }
    }
}
