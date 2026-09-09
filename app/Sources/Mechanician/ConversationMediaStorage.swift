import Foundation
import Darwin

/// A lightweight, durable pointer from a transcript tool entry to media stored outside the
/// conversation JSON. Tool-produced image bytes can be several megabytes, so keeping them out of the
/// sidecar preserves fast conversation decoding and switching.
struct ToolImageReference: Codable, Equatable, Hashable, Sendable {
    let fileName: String
    let width: Int?
    let height: Int?
}

/// Filesystem mechanics for per-conversation transcript media. ConversationStore serializes calls
/// to this value on its existing I/O queue; keeping the path policy here makes traversal rejection,
/// deletion, and round-trip behavior testable without booting the process-wide store singleton.
struct ConversationMediaStorage: Sendable {
    struct ComposerImageClone: Equatable, Sendable {
        let url: URL
        let byteCount: Int
    }

    /// Individual composer attachments are copied synchronously at the drop boundary, so keep the
    /// ceiling aligned with the existing pasted-image safety limit and reject oversized inputs
    /// before they can stall the editor or inflate Application Support without bound.
    static let maximumComposerFileBytes = 64 * 1024 * 1024

    let root: URL

    func persistScreenshot(
        _ data: Data,
        conversationID: UUID,
        entryID: UUID,
        width: Int?,
        height: Int?
    ) throws -> ToolImageReference {
        let directory = conversationDirectory(conversationID)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true)
        let reference = ToolImageReference(
            fileName: "\(entryID.uuidString).png",
            width: positiveDimension(width),
            height: positiveDimension(height))
        guard let url = imageURL(conversationID: conversationID, reference: reference) else {
            throw CocoaError(.fileWriteInvalidFileName)
        }
        try data.write(to: url, options: .atomic)
        return reference
    }

    /// Resolve only a plain UUID-named PNG inside the owning conversation directory. Conversation
    /// JSON can be written by external/ambient integrations, so never trust a persisted path.
    func imageURL(conversationID: UUID, reference: ToolImageReference) -> URL? {
        let fileName = reference.fileName
        guard fileName == URL(fileURLWithPath: fileName).lastPathComponent,
              fileName.count <= 80,
              fileName.lowercased().hasSuffix(".png"),
              UUID(uuidString: String(fileName.dropLast(4))) != nil else { return nil }
        return conversationDirectory(conversationID).appendingPathComponent(fileName)
    }

    func removeConversation(_ conversationID: UUID) throws {
        let directory = conversationDirectory(conversationID)
        guard FileManager.default.fileExists(atPath: directory.path) else { return }
        try FileManager.default.removeItem(at: directory)
    }

    /// Copy a generic attachment into the owning conversation before its token enters the draft.
    /// No source path is retained. A no-follow descriptor copy prevents symlinks and pathname races
    /// from turning an innocuous Finder drop into a copy of unrelated bytes.
    func persistComposerFile(
        at sourceURL: URL,
        conversationID: UUID,
        displayName: String? = nil,
        typeIdentifier: String? = nil,
        maximumBytes: Int = maximumComposerFileBytes
    ) throws -> ConversationFileReference? {
        guard maximumBytes >= 0 else { return nil }
        let source = sourceURL.standardizedFileURL
        let storageName = composerFileStorageName(for: source)
        let directory = conversationDirectory(conversationID)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true)
        let destination = directory.appendingPathComponent(storageName)
        guard let byteCount = try copyRegularFile(
            from: source,
            to: destination,
            maximumBytes: maximumBytes) else { return nil }
        let inferred = ConversationFileReference(
            storageName: storageName,
            sourceURL: source,
            byteCount: byteCount)
        return ConversationFileReference(
            storageName: storageName,
            displayName: displayName ?? inferred.displayName,
            typeIdentifier: typeIdentifier ?? inferred.typeIdentifier,
            byteCount: byteCount)
    }

    /// Preserve an image selected from Finder/the importer in conversation-owned storage while
    /// retaining its native encoding. This uses the same descriptor-based no-follow copy as generic
    /// files; pasted screenshots continue to use `persistScreenshot`.
    func persistComposerImageFile(
        at sourceURL: URL,
        conversationID: UUID,
        maximumBytes: Int = maximumComposerFileBytes
    ) throws -> URL? {
        guard maximumBytes >= 0 else { return nil }
        let source = sourceURL.standardizedFileURL
        let ext = source.pathExtension.lowercased()
        guard ConversationFileReference.composerImageExtensions.contains(ext) else {
            return nil
        }
        let directory = conversationDirectory(conversationID)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true)
        let destination = directory.appendingPathComponent(
            UUID().uuidString + ".\(ext)")
        guard try copyRegularFile(
            from: source,
            to: destination,
            maximumBytes: maximumBytes) != nil else { return nil }
        return destination
    }

    /// Resolve a syntactically valid reference inside exactly one conversation. This intentionally
    /// returns the expected URL even when the bytes are missing so transcript UI can render an
    /// honest unavailable attachment without losing its original name.
    func composerFileURL(
        conversationID: UUID,
        reference: ConversationFileReference
    ) -> URL? {
        guard reference.isValid else { return nil }
        return conversationDirectory(conversationID)
            .appendingPathComponent(reference.storageName)
            .standardizedFileURL
    }

    /// Provider expansion is stricter than presentation: only an existing regular, non-symlink
    /// file owned by this conversation may become an absolute path on the wire.
    func availableComposerFileURL(
        conversationID: UUID,
        reference: ConversationFileReference
    ) -> URL? {
        guard let url = composerFileURL(
            conversationID: conversationID,
            reference: reference),
              let values = try? url.resourceValues(
                forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]),
              values.isRegularFile == true,
              values.isSymbolicLink != true,
              values.fileSize == reference.byteCount else { return nil }
        return url
    }

    func cloneComposerFile(
        _ reference: ConversationFileReference,
        from sourceConversationID: UUID,
        to destinationConversationID: UUID,
        maximumBytes: Int = maximumComposerFileBytes
    ) throws -> ConversationFileReference? {
        guard maximumBytes >= 0,
              let source = availableComposerFileURL(
                conversationID: sourceConversationID,
                reference: reference) else { return nil }
        let storageName = composerFileStorageName(for: source)
        let destinationDirectory = conversationDirectory(destinationConversationID)
        try FileManager.default.createDirectory(
            at: destinationDirectory,
            withIntermediateDirectories: true)
        let destination = destinationDirectory.appendingPathComponent(storageName)
        guard let byteCount = try copyRegularFile(
            from: source,
            to: destination,
            maximumBytes: maximumBytes) else { return nil }
        return ConversationFileReference(
            storageName: storageName,
            displayName: reference.displayName,
            typeIdentifier: reference.typeIdentifier,
            byteCount: byteCount)
    }

    /// Re-home an app-owned composer image when its draft moves to another conversation. Accept
    /// only a UUID-named supported image directly inside the source conversation's directory;
    /// arbitrary user file paths remain references to their original locations and are never copied.
    /// Re-home a tool-captured screenshot into another Conversation's media directory.
    ///
    /// A `ToolImageReference` is only a file name; the directory it resolves in comes from whichever
    /// Conversation is asking (`imageURL(conversationID:reference:)`). So a fork that copies a tool
    /// row verbatim keeps a reference that now resolves inside the fork's own directory, where the
    /// bytes were never put — the card renders "Preview unavailable" forever. Copying the file under
    /// the same name makes the inherited reference resolve, with no rewriting of the entry at all.
    ///
    /// Returns true when the fork can show the image: either it was copied, or it is already there.
    @discardableResult
    func cloneToolImage(
        _ reference: ToolImageReference,
        from sourceConversationID: UUID,
        to destinationConversationID: UUID,
        maximumBytes: Int = 64 * 1024 * 1024
    ) -> Bool {
        guard sourceConversationID != destinationConversationID,
              let sourceURL = imageURL(
                conversationID: sourceConversationID, reference: reference),
              let destinationURL = imageURL(
                conversationID: destinationConversationID, reference: reference)
        else { return false }
        if FileManager.default.fileExists(atPath: destinationURL.path) { return true }
        guard FileManager.default.fileExists(atPath: sourceURL.path) else { return false }
        try? FileManager.default.createDirectory(
            at: destinationURL.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        // `copyRegularFile` returns nil for a source it refuses (not a regular file, over the
        // cap); `try?` collapses a thrown failure to the same nil. Either way there is no image.
        return ((try? copyRegularFile(
            from: sourceURL,
            to: destinationURL,
            maximumBytes: maximumBytes)) ?? nil) != nil
    }

    func cloneComposerImage(
        at path: String,
        from sourceConversationID: UUID,
        to destinationConversationID: UUID,
        maximumBytes: Int = 64 * 1024 * 1024
    ) throws -> ComposerImageClone? {
        guard maximumBytes >= 0 else { return nil }
        let sourceURL = URL(fileURLWithPath: path).standardizedFileURL
        guard ownsComposerImagePath(
            sourceURL.path,
            conversationID: sourceConversationID) else { return nil }

        let destinationDirectory = conversationDirectory(destinationConversationID)
        try FileManager.default.createDirectory(
            at: destinationDirectory,
            withIntermediateDirectories: true)
        let destinationURL = destinationDirectory.appendingPathComponent(
            UUID().uuidString + ".\(sourceURL.pathExtension.lowercased())")

        guard let copiedBytes = try copyRegularFile(
            from: sourceURL,
            to: destinationURL,
            maximumBytes: maximumBytes) else { return nil }
        return ComposerImageClone(url: destinationURL, byteCount: copiedBytes)
    }

    func composerImageFileSize(at path: String, conversationID: UUID) throws -> Int? {
        guard ownsComposerImagePath(path, conversationID: conversationID) else { return nil }
        let values = try URL(fileURLWithPath: path).standardizedFileURL.resourceValues(
            forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true,
              values.isSymbolicLink != true,
              let size = values.fileSize,
              size >= 0 else { return nil }
        return size
    }

    func ownsComposerImagePath(_ path: String, conversationID: UUID) -> Bool {
        let url = URL(fileURLWithPath: path).standardizedFileURL
        let directory = conversationDirectory(conversationID).standardizedFileURL
        let ext = url.pathExtension.lowercased()
        let stem = url.deletingPathExtension().lastPathComponent
        return url.deletingLastPathComponent() == directory
            && ConversationFileReference.composerImageExtensions.contains(ext)
            && UUID(uuidString: stem) != nil
    }

    private func conversationDirectory(_ conversationID: UUID) -> URL {
        root.appendingPathComponent(conversationID.uuidString, isDirectory: true)
    }

    private func composerFileStorageName(for sourceURL: URL) -> String {
        let ext = sourceURL.pathExtension
        let safeExtension = ext.count <= 20
            && ext.unicodeScalars.allSatisfy {
                CharacterSet.alphanumerics.contains($0) || $0 == "-" || $0 == "_"
            }
            ? ext
            : ""
        return UUID().uuidString + (safeExtension.isEmpty ? "" : ".\(safeExtension)")
    }

    /// Copy from one already-resolved path without following the final source or destination
    /// component. The size check is performed on the open descriptor and repeated while reading, so
    /// concurrent growth cannot bypass the limit.
    private func copyRegularFile(
        from sourceURL: URL,
        to destinationURL: URL,
        maximumBytes: Int
    ) throws -> Int? {
        guard maximumBytes >= 0 else { return nil }
        let sourceDescriptor = Darwin.open(
            sourceURL.path,
            O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard sourceDescriptor >= 0 else { return nil }
        defer { Darwin.close(sourceDescriptor) }
        var sourceMetadata = stat()
        guard fstat(sourceDescriptor, &sourceMetadata) == 0,
              sourceMetadata.st_mode & S_IFMT == S_IFREG,
              sourceMetadata.st_size >= 0,
              sourceMetadata.st_size <= off_t(maximumBytes)
        else { return nil }

        let destinationDescriptor = Darwin.open(
            destinationURL.path,
            O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
            S_IRUSR | S_IWUSR)
        guard destinationDescriptor >= 0 else { return nil }
        var completed = false
        defer {
            Darwin.close(destinationDescriptor)
            if !completed {
                try? FileManager.default.removeItem(at: destinationURL)
            }
        }

        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        var copiedBytes = 0
        while true {
            let count: Int = buffer.withUnsafeMutableBytes { bytes in
                while true {
                    let result = Darwin.read(
                        sourceDescriptor,
                        bytes.baseAddress,
                        bytes.count)
                    if result < 0 && errno == EINTR { continue }
                    return result
                }
            }
            guard count >= 0 else { throw posixError() }
            if count == 0 { break }
            guard count <= maximumBytes - copiedBytes else { return nil }
            var written = 0
            while written < count {
                let amount: Int = buffer.withUnsafeBytes { bytes in
                    while true {
                        let result = Darwin.write(
                            destinationDescriptor,
                            bytes.baseAddress?.advanced(by: written),
                            count - written)
                        if result < 0 && errno == EINTR { continue }
                        return result
                    }
                }
                guard amount > 0 else { throw posixError() }
                written += amount
            }
            copiedBytes += count
        }
        var destinationMetadata = stat()
        guard fstat(destinationDescriptor, &destinationMetadata) == 0,
              destinationMetadata.st_mode & S_IFMT == S_IFREG,
              destinationMetadata.st_size == off_t(copiedBytes),
              copiedBytes <= maximumBytes
        else { return nil }
        completed = true
        return copiedBytes
    }

    private func positiveDimension(_ value: Int?) -> Int? {
        guard let value, value > 0 else { return nil }
        return value
    }

    private func posixError(_ code: Int32 = errno) -> NSError {
        NSError(domain: NSPOSIXErrorDomain, code: Int(code))
    }
}
