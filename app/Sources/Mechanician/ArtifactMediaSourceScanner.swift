import CryptoKit
import Darwin
import Foundation
import UniformTypeIdentifiers

/// Read-only L1b1 inventory over the artifact/media authorities that exist before Gate L.
///
/// The read-only scanner refuses observed symlink roots and entries, never repairs a source, and
/// never materializes a managed blob. Large media is opened with `O_NOFOLLOW`, hashed through a
/// descriptor in bounded chunks, and must retain identical descriptor metadata through EOF; a
/// concurrent mutation becomes a visible issue, not a digest of mixed generations. L1b2's copying
/// traversal must additionally be descriptor-relative (`openat`) so a directory-swap race cannot
/// redirect publication between inspection and enumeration.
struct ArtifactMediaSourceScan: Sendable {
    struct ArtifactCandidate: Sendable {
        let artifact: Artifact
        let producerTaskID: String?
        let rawSourceBytes: Data
        let source: ShadowLibrarySourceFingerprint
    }

    struct RetainedByteCandidate: Sendable {
        enum Kind: String, Sendable {
            case conversationMedia = "conversation_media"
            case conversationTrashMedia = "conversation_trash_media"
        }

        let kind: Kind
        let ownerConversationID: UUID?
        let storageName: String
        let mediaType: String
        let source: ShadowLibrarySourceFingerprint
    }

    struct Issue: Sendable {
        let source: ShadowLibrarySourceFingerprint
        let kind: ShadowLibrarySourceIssueKind
        let diagnostics: String
    }

    var artifacts: [ArtifactCandidate] = []
    var retainedBytes: [RetainedByteCandidate] = []
    var issues: [Issue] = []
    /// False means at least one present directory could not be enumerated, so the observed source
    /// identities are not a closed set. Per-source malformed/symlink issues may still be a complete
    /// census when the scanner successfully observed and classified every directory entry.
    var hasCompleteCensus = true

    var sourceIdentities: Set<String> {
        Set(artifacts.map(\.source.identity)
            + retainedBytes.map(\.source.identity)
            + issues.map(\.source.identity))
    }
}

enum ArtifactMediaSourceScanner {
    /// Artifact JSON is decoded in memory after a descriptor-stable read. Bound that allocation even
    /// if a cross-process writer places a hostile file in the live directory.
    static let maximumArtifactJSONBytes = 64 * 1_024 * 1_024

    private enum OptionalDirectoryValidation {
        case present
        case missing
        case rejected
    }

    private enum ScannerError: LocalizedError {
        case sourceTooLarge(maximumBytes: Int)

        var errorDescription: String? {
            switch self {
            case .sourceTooLarge(let maximumBytes):
                return "Source exceeds the \(maximumBytes)-byte scanner limit."
            }
        }
    }

    private struct FingerprintedArtifactBytes {
        let data: Data
        let source: ShadowLibrarySourceFingerprint
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
            "dev:\(device);ino:\(inode);bytes:\(size);mtime:\(modifiedSeconds).\(modifiedNanoseconds);ctime:\(changedSeconds).\(changedNanoseconds)"
        }
    }

    static func scan(
        supportRoot: URL,
        cachedFingerprints: [String: ShadowLibrarySourceFingerprint] = [:]
    ) -> ArtifactMediaSourceScan {
        let root = supportRoot.standardizedFileURL
        var result = ArtifactMediaSourceScan()
        scanArtifacts(root: root, into: &result)
        scanActiveMedia(root: root, cachedFingerprints: cachedFingerprints, into: &result)
        scanTrashMedia(root: root, cachedFingerprints: cachedFingerprints, into: &result)
        result.artifacts.sort { $0.source.identity < $1.source.identity }
        result.retainedBytes.sort { $0.source.identity < $1.source.identity }
        result.issues.sort { $0.source.identity < $1.source.identity }
        return result
    }

    /// Descriptor-safe, owner-scoped census used after SQLite authority when a Conversation adds
    /// app-managed media. Unlike the migration census this never walks unrelated artifacts, trash,
    /// or other Conversations, so one pasted file cannot turn a semantic Conversation commit into
    /// a scan of the entire retained-byte library.
    static func scanConversationMedia(
        supportRoot: URL,
        conversationID: UUID,
        cachedFingerprints: [String: ShadowLibrarySourceFingerprint] = [:]
    ) -> ArtifactMediaSourceScan {
        let root = supportRoot.standardizedFileURL
        let mediaRoot = root.appendingPathComponent("conversation-media", isDirectory: true)
        let ownerDirectory = mediaRoot.appendingPathComponent(
            conversationID.uuidString,
            isDirectory: true)
        var result = ArtifactMediaSourceScan()
        guard validateOptionalDirectory(
            ownerDirectory,
            root: root,
            label: "Conversation media owner",
            into: &result) == .present,
              let files = directoryEntries(
                ownerDirectory,
                root: root,
                label: "Conversation media owner",
                into: &result) else {
            return result
        }
        for file in files {
            scanMediaFile(
                file,
                root: root,
                kind: .conversationMedia,
                ownerConversationID: conversationID,
                cachedFingerprints: cachedFingerprints,
                into: &result)
        }
        result.retainedBytes.sort { $0.source.identity < $1.source.identity }
        result.issues.sort { $0.source.identity < $1.source.identity }
        return result
    }

    private static func scanArtifacts(root: URL, into result: inout ArtifactMediaSourceScan) {
        let directory = root.appendingPathComponent("artifacts", isDirectory: true)
        guard validateOptionalDirectory(
            directory,
            root: root,
            label: "Artifact root",
            into: &result) == .present,
              let entries = directoryEntries(
                directory,
                root: root,
                label: "Artifact root",
                into: &result) else { return }
        for url in entries {
            // This one-time migration marker is administrative state, not an artifact. Do not use a
            // blanket hidden-file skip: every other hidden source must remain visible to the census.
            if url.lastPathComponent == ".migrated-v1" { continue }
            let identity = relativeIdentity(url, root: root)
            guard isRegularNonSymlink(url) else {
                result.issues.append(issue(
                    identity: identity,
                    revision: metadataRevision(url),
                    diagnostics: "Artifact source is not a regular non-symlink file."))
                continue
            }
            let fingerprinted: FingerprintedArtifactBytes
            do {
                fingerprinted = try readArtifactBytes(url, identity: identity)
            } catch {
                result.issues.append(issue(
                    identity: identity,
                    revision: metadataRevision(url),
                    diagnostics:
                        "Artifact source could not be safely read: \(error.localizedDescription)"))
                continue
            }
            let data = fingerprinted.data
            let source = fingerprinted.source
            guard url.pathExtension.lowercased() == "json" else {
                result.issues.append(ArtifactMediaSourceScan.Issue(
                    source: source,
                    kind: .malformed,
                    diagnostics: "Artifact source does not use the live .json binding."))
                continue
            }
            do {
                let artifact = try ArtifactStore.persistedDecoder().decode(Artifact.self, from: data)
                let raw = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
                let taskID = raw?["taskId"] as? String
                result.artifacts.append(ArtifactMediaSourceScan.ArtifactCandidate(
                    artifact: artifact,
                    producerTaskID: taskID,
                    rawSourceBytes: data,
                    source: source))
            } catch {
                result.issues.append(ArtifactMediaSourceScan.Issue(
                    source: source,
                    kind: .malformed,
                    diagnostics: "Artifact JSON could not be decoded: \(error.localizedDescription)"))
            }
        }
    }

    private static func scanActiveMedia(
        root: URL,
        cachedFingerprints: [String: ShadowLibrarySourceFingerprint],
        into result: inout ArtifactMediaSourceScan
    ) {
        let mediaRoot = root.appendingPathComponent("conversation-media", isDirectory: true)
        guard validateOptionalDirectory(
            mediaRoot,
            root: root,
            label: "Conversation media root",
            into: &result) == .present,
              let ownerDirectories = directoryEntries(
                mediaRoot,
                root: root,
                label: "Conversation media root",
                into: &result) else { return }
        for ownerDirectory in ownerDirectories {
            let ownerID = UUID(uuidString: ownerDirectory.lastPathComponent)
            guard isDirectoryNonSymlink(ownerDirectory) else {
                result.issues.append(issue(
                    identity: relativeIdentity(ownerDirectory, root: root),
                    revision: metadataRevision(ownerDirectory),
                    diagnostics: "Conversation media owner is not a directory."))
                continue
            }
            guard let files = directoryEntries(
                ownerDirectory,
                root: root,
                label: "Conversation media owner",
                into: &result) else { continue }
            for file in files {
                scanMediaFile(
                    file,
                    root: root,
                    kind: .conversationMedia,
                    ownerConversationID: ownerID,
                    cachedFingerprints: cachedFingerprints,
                    into: &result)
            }
        }
    }

    private static func scanTrashMedia(
        root: URL,
        cachedFingerprints: [String: ShadowLibrarySourceFingerprint],
        into result: inout ArtifactMediaSourceScan
    ) {
        let trashRoot = root
            .appendingPathComponent("trash", isDirectory: true)
            .appendingPathComponent("conversations", isDirectory: true)
        guard validateOptionalDirectory(
            trashRoot,
            root: root,
            label: "Conversation trash root",
            into: &result) == .present,
              let slots = directoryEntries(
                trashRoot,
                root: root,
                label: "Conversation trash root",
                into: &result) else { return }
        for slot in slots {
            guard isDirectoryNonSymlink(slot) else {
                result.issues.append(issue(
                    identity: relativeIdentity(slot, root: root),
                    revision: metadataRevision(slot),
                    diagnostics: "Conversation trash slot is not a directory."))
                continue
            }
            guard let candidates = directoryEntries(
                slot,
                root: root,
                label: "Conversation trash slot",
                into: &result) else { continue }
            for candidate in candidates {
                // A trash slot normally also contains the Conversation JSON sidecar. It remains
                // covered by the Conversation quarantine/trash census, not the retained-byte
                // inventory, so only directory-shaped candidates belong here.
                if isRegularNonSymlink(candidate), candidate.pathExtension.lowercased() == "json" {
                    continue
                }
                guard isDirectoryNonSymlink(candidate) else {
                    result.issues.append(issue(
                        identity: relativeIdentity(candidate, root: root),
                        revision: metadataRevision(candidate),
                        diagnostics: "Trashed Conversation media source is not a directory."))
                    continue
                }
                guard let ownerID = UUID(uuidString: candidate.lastPathComponent) else {
                    result.issues.append(issue(
                        identity: relativeIdentity(candidate, root: root),
                        revision: metadataRevision(candidate),
                        diagnostics: "Trashed Conversation media owner is not a UUID."))
                    continue
                }
                guard let files = directoryEntries(
                    candidate,
                    root: root,
                    label: "Trashed Conversation media owner",
                    into: &result) else { continue }
                for file in files {
                    scanMediaFile(
                        file,
                        root: root,
                        kind: .conversationTrashMedia,
                        ownerConversationID: ownerID,
                        cachedFingerprints: cachedFingerprints,
                        into: &result)
                }
            }
        }
    }

    private static func scanMediaFile(
        _ url: URL,
        root: URL,
        kind: ArtifactMediaSourceScan.RetainedByteCandidate.Kind,
        ownerConversationID: UUID?,
        cachedFingerprints: [String: ShadowLibrarySourceFingerprint],
        into result: inout ArtifactMediaSourceScan
    ) {
        let identity = relativeIdentity(url, root: root)
        do {
            let source = try fingerprintRegularFile(
                url,
                identity: identity,
                cached: cachedFingerprints[identity])
            let mediaType = UTType(filenameExtension: url.pathExtension)?.identifier
                ?? "application/octet-stream"
            result.retainedBytes.append(ArtifactMediaSourceScan.RetainedByteCandidate(
                kind: kind,
                ownerConversationID: ownerConversationID,
                storageName: url.lastPathComponent,
                mediaType: mediaType,
                source: source))
        } catch {
            result.issues.append(issue(
                identity: identity,
                revision: metadataRevision(url),
                diagnostics: "Retained media could not be safely digested: \(error.localizedDescription)"))
        }
    }

    private static func fingerprintRegularFile(
        _ url: URL,
        identity: String,
        cached: ShadowLibrarySourceFingerprint?
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
        if let cached,
           cached.identity == identity,
           cached.revision == before.revision,
           cached.byteCount == Int(before.size) {
            return cached
        }

        var hasher = SHA256()
        var bytesRead: Int64 = 0
        var buffer = Data(count: 1_024 * 1_024)
        while true {
            let count: Int = buffer.withUnsafeMutableBytes { rawBuffer in
                while true {
                    let value = Darwin.read(descriptor, rawBuffer.baseAddress, rawBuffer.count)
                    if value < 0 && errno == EINTR { continue }
                    return value
                }
            }
            guard count >= 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
            if count == 0 { break }
            bytesRead += Int64(count)
            hasher.update(data: buffer.prefix(count))
        }

        var afterRaw = stat()
        guard fstat(descriptor, &afterRaw) == 0 else {
            throw POSIXError(.init(rawValue: errno) ?? .EIO)
        }
        let after = DescriptorMetadata(afterRaw)
        guard before == after, bytesRead == before.size else {
            throw CocoaError(.fileReadUnknown)
        }
        let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        return ShadowLibrarySourceFingerprint(
            identity: identity,
            revision: before.revision,
            digest: digest,
            byteCount: Int(bytesRead))
    }

    private static func readArtifactBytes(
        _ url: URL,
        identity: String
    ) throws -> FingerprintedArtifactBytes {
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
        guard beforeRaw.st_size <= off_t(maximumArtifactJSONBytes) else {
            throw ScannerError.sourceTooLarge(maximumBytes: maximumArtifactJSONBytes)
        }
        let before = DescriptorMetadata(beforeRaw)
        var data = Data()
        data.reserveCapacity(Int(before.size))
        var hasher = SHA256()
        var buffer = Data(count: 1_024 * 1_024)
        while true {
            let count: Int = buffer.withUnsafeMutableBytes { rawBuffer in
                while true {
                    let value = Darwin.read(descriptor, rawBuffer.baseAddress, rawBuffer.count)
                    if value < 0 && errno == EINTR { continue }
                    return value
                }
            }
            guard count >= 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
            if count == 0 { break }
            guard count <= maximumArtifactJSONBytes - data.count else {
                throw ScannerError.sourceTooLarge(maximumBytes: maximumArtifactJSONBytes)
            }
            let bytes = buffer.prefix(count)
            data.append(contentsOf: bytes)
            hasher.update(data: bytes)
        }

        var afterRaw = stat()
        guard fstat(descriptor, &afterRaw) == 0 else {
            throw POSIXError(.init(rawValue: errno) ?? .EIO)
        }
        let after = DescriptorMetadata(afterRaw)
        guard before == after, data.count == Int(before.size) else {
            throw CocoaError(.fileReadUnknown)
        }
        let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        return FingerprintedArtifactBytes(
            data: data,
            source: ShadowLibrarySourceFingerprint(
                identity: identity,
                revision: before.revision,
                digest: digest,
                byteCount: data.count))
    }

    private static func directoryEntries(
        _ directory: URL,
        root: URL,
        label: String,
        into result: inout ArtifactMediaSourceScan
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
                identity: relativeIdentity(directory, root: root),
                revision: metadataRevision(directory),
                diagnostics: "\(label) could not be enumerated: \(error.localizedDescription)"))
            return nil
        }
    }

    /// Missing optional roots mean there are simply no sources yet. Every present path component,
    /// including the support root and `trash`, must be an actual directory rather than a symlink.
    /// Checking only the final component would still let pathname resolution traverse a symlinked
    /// parent before `lstat` ever saw the leaf.
    private static func validateOptionalDirectory(
        _ directory: URL,
        root: URL,
        label: String,
        into result: inout ArtifactMediaSourceScan
    ) -> OptionalDirectoryValidation {
        let normalizedRoot = root.standardizedFileURL
        let normalizedDirectory = directory.standardizedFileURL
        let rootPath = normalizedRoot.path
        let descendantPrefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        guard normalizedDirectory.path == rootPath
                || normalizedDirectory.path.hasPrefix(descendantPrefix) else {
            result.issues.append(issue(
                identity: normalizedDirectory.lastPathComponent,
                revision: "outside-support-root",
                diagnostics: "\(label) is outside the support root and was not traversed."))
            return .rejected
        }

        var components = [normalizedRoot]
        if normalizedDirectory.path != rootPath {
            var cursor = normalizedRoot
            let suffix = normalizedDirectory.path.dropFirst(descendantPrefix.count)
            for component in suffix.split(separator: "/") {
                cursor.appendPathComponent(String(component), isDirectory: true)
                components.append(cursor)
            }
        }
        for component in components {
            var value = stat()
            if lstat(component.path, &value) != 0 {
                let code = errno
                if code == ENOENT { return .missing }
                let reason = String(cString: strerror(code))
                result.hasCompleteCensus = false
                result.issues.append(issue(
                    identity: relativeIdentity(component, root: normalizedRoot),
                    revision: "unavailable",
                    diagnostics: "\(label) could not be inspected: \(reason)."))
                return .rejected
            }
            guard value.st_mode & S_IFMT == S_IFDIR else {
                // The path component itself is classified, but the directory entries behind a
                // symlink/non-directory authority root were deliberately not enumerated. That is
                // not a closed set: a partial reconcile may record this issue, but must preserve
                // previously inventoried child sources rather than pruning them as absent.
                result.hasCompleteCensus = false
                result.issues.append(issue(
                    identity: relativeIdentity(component, root: normalizedRoot),
                    revision: DescriptorMetadata(value).revision,
                    diagnostics: "\(label) contains a non-directory path component and was not traversed."))
                return .rejected
            }
        }
        return .present
    }

    private static func isRegularNonSymlink(_ url: URL) -> Bool {
        var value = stat()
        return lstat(url.path, &value) == 0 && value.st_mode & S_IFMT == S_IFREG
    }

    private static func isDirectoryNonSymlink(_ url: URL) -> Bool {
        var value = stat()
        return lstat(url.path, &value) == 0 && value.st_mode & S_IFMT == S_IFDIR
    }

    private static func metadataRevision(_ url: URL) -> String {
        var value = stat()
        guard lstat(url.path, &value) == 0 else { return "unavailable" }
        return DescriptorMetadata(value).revision
    }

    /// A source's identity, relative to the support root.
    ///
    /// The unresolved path is tried FIRST, and that ordering is the point. `standardizedFileURL`
    /// resolves a symlink to its destination, so a symlink inside `conversation-media` standardized
    /// to somewhere outside the root, failed the prefix test, and fell back to `lastPathComponent` —
    /// leaving the source identified as bare `broken.png`. That is not merely ugly: it is not a path,
    /// so nothing downstream can tell which conversation owned it or even that it was media at all,
    /// and two conversations each holding an `image.png` would claim the SAME identity.
    ///
    /// Both bases are still tried, because the root itself may legitimately arrive standardized
    /// (`/tmp` → `/private/tmp`) while the enumerated URL is not, or the reverse.
    private static func relativeIdentity(_ url: URL, root: URL) -> String {
        // Compare through one normalization applied to BOTH sides. Directory enumeration yields
        // `/private/tmp/…` while Foundation's own `standardizedFileURL` normalizes the root the
        // OTHER way, to `/tmp/…`, so a raw prefix test fails on every source under such a root.
        //
        // Only the root may be symlink-resolved; the candidate never is. Resolving the candidate is
        // what produced the bug this replaces: a symlinked media file resolved to its destination,
        // escaped the root, and fell back to `lastPathComponent`. That left the source identified as
        // bare `broken.png` — not a path, so nothing downstream could tell which conversation owned
        // it or that it was media at all, and two conversations each holding an `image.png` would
        // claim the SAME identity.
        let bases = [root.path, root.standardizedFileURL.path, root.resolvingSymlinksInPath().path]
        for base in bases {
            let rootPath = Self.comparablePath(base.hasSuffix("/") ? base : base + "/")
            for candidate in [url.path, url.standardizedFileURL.path]
            where Self.comparablePath(candidate).hasPrefix(rootPath) {
                return String(Self.comparablePath(candidate).dropFirst(rootPath.count))
            }
        }
        return url.lastPathComponent
    }

    /// `/private/tmp` and `/tmp` are the same directory, and Foundation hands the two sides of this
    /// comparison different spellings of it. Collapse to one so a real path difference is the only
    /// thing that can fail the prefix test.
    private static func comparablePath(_ path: String) -> String {
        guard path.hasPrefix("/private/") else { return path }
        return String(path.dropFirst("/private".count))
    }

    private static func issue(
        identity: String,
        revision: String,
        diagnostics: String
    ) -> ArtifactMediaSourceScan.Issue {
        ArtifactMediaSourceScan.Issue(
            source: ShadowLibrarySourceFingerprint(
                identity: identity,
                revision: revision,
                sourceBytes: Data()),
            kind: .malformed,
            diagnostics: diagnostics)
    }
}
