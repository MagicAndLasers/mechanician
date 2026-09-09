import CryptoKit
import Darwin
import Foundation

/// Exact, bounded evidence staged when a provider file tool starts and completed only after the
/// matching successful `tool_result`. This is deliberately independent of Git: Git describes the
/// repository at a later observation boundary, while this value describes the path the tool named.
struct ConversationFileToolCaptureDraft: Equatable, Sendable {
    struct File: Equatable, Sendable {
        let absolutePath: String
        let beforeExists: Bool?
        let beforeDigest: String?
        let boundedPatch: String?
        let patchWasTruncated: Bool
        /// False keeps the exact named path in the manifest while avoiding unbounded synchronous
        /// hashing/patch capture for a very large multi-file tool call.
        let capturesContent: Bool
    }

    let conversationID: UUID
    let turnID: String
    let toolUseID: String
    let workingDirectory: String
    let workspaceID: UUID?
    let rootPromptEntryID: UUID?
    let operation: ConversationFileOperation
    let files: [File]
}

struct ConversationFileToolCaptureResult: Equatable, Sendable {
    let absolutePath: String
    let beforeExists: Bool?
    let beforeDigest: String?
    let afterExists: Bool?
    let afterDigest: String?
    let boundedPatch: String?
    let patchWasTruncated: Bool
}

enum ConversationFileToolCapture {
    /// Provider lifecycle arrives on the UI actor. Keep synchronous pre/post snapshots small enough
    /// that a generated multi-file edit cannot hash gigabytes before the interface handles its next
    /// event. Larger files still retain existence, tool identity, and bounded patch evidence; only
    /// their content digest becomes unknown.
    static let maximumCapturedFilesPerTool = 16
    static let maximumDigestBytes = 512_000

    struct FileSnapshot: Equatable, Sendable {
        let exists: Bool?
        let digest: String?
    }

    static func begin(
        conversationID: UUID,
        turnID: String,
        toolUseID: String,
        workingDirectory: String,
        workspaceID: UUID?,
        rootPromptEntryID: UUID?,
        name: String?,
        input: Any?,
        snapshot: (String) -> FileSnapshot = { snapshotFile($0) }
    ) -> ConversationFileToolCaptureDraft? {
        guard !turnID.isEmpty, !toolUseID.isEmpty,
              let name,
              let operation = operation(for: name),
              let input = input as? [String: Any] else { return nil }
        let candidates = fileCandidates(
            name: name,
            input: input,
            workingDirectory: workingDirectory)
        guard !candidates.isEmpty else { return nil }
        let files = candidates.enumerated().map { index, candidate in
            let capturesContent = index < maximumCapturedFilesPerTool
            let before = capturesContent
                ? snapshot(candidate.path) : existenceOnlySnapshot(candidate.path)
            let bounded = capturesContent ? candidate.patch.map(boundPatch) : nil
            return ConversationFileToolCaptureDraft.File(
                absolutePath: candidate.path,
                beforeExists: before.exists,
                beforeDigest: before.digest,
                boundedPatch: bounded?.text,
                patchWasTruncated: bounded?.truncated ?? false,
                capturesContent: capturesContent)
        }
        return ConversationFileToolCaptureDraft(
            conversationID: conversationID,
            turnID: turnID,
            toolUseID: toolUseID,
            workingDirectory: (workingDirectory as NSString).standardizingPath,
            workspaceID: workspaceID,
            rootPromptEntryID: rootPromptEntryID,
            operation: operation,
            files: files)
    }

    static func finish(
        _ draft: ConversationFileToolCaptureDraft,
        snapshot: (String) -> FileSnapshot = { snapshotFile($0) }
    ) -> [ConversationFileToolCaptureResult] {
        draft.files.map { file in
            let after = file.capturesContent
                ? snapshot(file.absolutePath) : existenceOnlySnapshot(file.absolutePath)
            return ConversationFileToolCaptureResult(
                absolutePath: file.absolutePath,
                beforeExists: file.beforeExists,
                beforeDigest: file.beforeDigest,
                afterExists: after.exists,
                afterDigest: after.digest,
                boundedPatch: file.boundedPatch,
                patchWasTruncated: file.patchWasTruncated)
        }
    }

    private static func operation(for name: String) -> ConversationFileOperation? {
        switch name {
        case "Read": return .read
        case "Edit": return .edit
        case "Write": return .write
        case "MultiEdit": return .multiEdit
        case "NotebookEdit": return .notebookEdit
        default: return nil
        }
    }

    private struct Candidate {
        let path: String
        let patch: String?
    }

    private static func fileCandidates(
        name: String,
        input: [String: Any],
        workingDirectory: String
    ) -> [Candidate] {
        var candidates: [Candidate] = []
        if name == "Edit",
           let changes = input["changes"] as? [[String: Any]] {
            candidates.append(contentsOf: changes.compactMap { change in
                guard let rawPath = change["path"] as? String, !rawPath.isEmpty else {
                    return nil
                }
                return Candidate(
                    path: absolutePath(rawPath, workingDirectory: workingDirectory),
                    patch: (change["diff"] as? String).flatMap { $0.isEmpty ? nil : $0 })
            })
        }
        if candidates.isEmpty,
           let rawPath = (input["file_path"] ?? input["notebook_path"]) as? String,
           !rawPath.isEmpty {
            candidates.append(Candidate(
                path: absolutePath(rawPath, workingDirectory: workingDirectory),
                patch: patch(name: name, input: input)))
        }
        var seen = Set<String>()
        return candidates.filter { candidate in
            candidate.path.hasPrefix("/") && seen.insert(candidate.path).inserted
        }
    }

    private static func absolutePath(_ path: String, workingDirectory: String) -> String {
        let raw = (path as NSString).isAbsolutePath
            ? path
            : (workingDirectory as NSString).appendingPathComponent(path)
        return (raw as NSString).standardizingPath
    }

    private static func patch(name: String, input: [String: Any]) -> String? {
        func hunk(old: String, new: String) -> String {
            var lines: [String] = []
            if !old.isEmpty {
                lines.append(contentsOf: old.components(separatedBy: "\n").map { "- " + $0 })
            }
            if !new.isEmpty {
                lines.append(contentsOf: new.components(separatedBy: "\n").map { "+ " + $0 })
            }
            return lines.joined(separator: "\n")
        }
        switch name {
        case "Edit":
            guard let old = input["old_string"] as? String,
                  let new = input["new_string"] as? String else { return nil }
            return hunk(old: old, new: new)
        case "MultiEdit":
            guard let edits = input["edits"] as? [[String: Any]] else { return nil }
            let hunks = edits.map {
                hunk(
                    old: $0["old_string"] as? String ?? "",
                    new: $0["new_string"] as? String ?? "")
            }.filter { !$0.isEmpty }
            return hunks.isEmpty ? nil : hunks.joined(separator: "\n@@\n")
        case "Write":
            guard let content = input["content"] as? String else { return nil }
            return "@@ full write @@\n"
                + content.components(separatedBy: "\n").map { "+ " + $0 }.joined(separator: "\n")
        case "NotebookEdit":
            guard let content = input["new_source"] as? String else { return nil }
            return "@@ cell @@\n"
                + content.components(separatedBy: "\n").map { "+ " + $0 }.joined(separator: "\n")
        default:
            return nil
        }
    }

    private static func boundPatch(_ value: String) -> (text: String, truncated: Bool) {
        let limit = ConversationFileObservation.maximumBoundedPatchBytes
        let data = Data(value.utf8)
        guard data.count > limit else { return (value, false) }
        var end = limit
        while end > 0 {
            if let text = String(data: data.prefix(end), encoding: .utf8) {
                return (text, true)
            }
            end -= 1
        }
        return ("", true)
    }

    static func snapshotFile(
        _ path: String,
        afterInitialStat: (() -> Void)? = nil
    ) -> FileSnapshot {
        var isDirectory = ObjCBool(false)
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) else {
            return FileSnapshot(exists: false, digest: nil)
        }
        guard !isDirectory.boolValue else {
            return FileSnapshot(exists: true, digest: nil)
        }
        let url = URL(fileURLWithPath: path)
        guard let data = boundedRegularFileData(at: url, afterInitialStat: afterInitialStat) else {
            return FileSnapshot(exists: true, digest: nil)
        }
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        return FileSnapshot(exists: true, digest: digest)
    }

    /// A tool target can be replaced or truncated while its lifecycle event is being handled.
    /// Reading through a descriptor copies bounded bytes into owned memory, so hashing cannot fault
    /// later on invalidated memory-mapped pages. The before/after metadata check treats a changing
    /// file as unknown rather than retaining a mixed snapshot.
    private static func boundedRegularFileData(
        at url: URL,
        afterInitialStat: (() -> Void)?
    ) -> Data? {
        let descriptor = url.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { return -1 }
            return Darwin.open(path, O_RDONLY | O_NONBLOCK | O_CLOEXEC)
        }
        guard descriptor >= 0 else { return nil }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }

        var initial = stat()
        guard Darwin.fstat(descriptor, &initial) == 0,
              (initial.st_mode & S_IFMT) == S_IFREG,
              initial.st_size >= 0,
              initial.st_size <= off_t(maximumDigestBytes) else {
            return nil
        }
        afterInitialStat?()

        var data = Data()
        data.reserveCapacity(Int(initial.st_size))
        while data.count <= maximumDigestBytes {
            let remaining = maximumDigestBytes + 1 - data.count
            guard remaining > 0 else { break }
            let chunk: Data
            do {
                guard let next = try handle.read(upToCount: min(64 * 1_024, remaining)) else {
                    break
                }
                chunk = next
            } catch {
                return nil
            }
            guard !chunk.isEmpty else { break }
            data.append(chunk)
        }

        var final = stat()
        guard data.count <= maximumDigestBytes,
              data.count == Int(initial.st_size),
              Darwin.fstat(descriptor, &final) == 0,
              unchangedFileMetadata(initial, final) else {
            return nil
        }
        return data
    }

    private static func unchangedFileMetadata(_ initial: stat, _ final: stat) -> Bool {
        initial.st_mode == final.st_mode
            && initial.st_dev == final.st_dev
            && initial.st_ino == final.st_ino
            && initial.st_size == final.st_size
            && initial.st_mtimespec.tv_sec == final.st_mtimespec.tv_sec
            && initial.st_mtimespec.tv_nsec == final.st_mtimespec.tv_nsec
            && initial.st_ctimespec.tv_sec == final.st_ctimespec.tv_sec
            && initial.st_ctimespec.tv_nsec == final.st_ctimespec.tv_nsec
    }

    private static func existenceOnlySnapshot(_ path: String) -> FileSnapshot {
        var isDirectory = ObjCBool(false)
        let exists = FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
        return FileSnapshot(exists: exists, digest: nil)
    }
}
