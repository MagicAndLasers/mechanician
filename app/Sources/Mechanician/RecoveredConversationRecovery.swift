import AppKit
import CryptoKit
import Darwin
import Foundation
import SwiftUI
import UniformTypeIdentifiers

enum RecoveredConversationRecoveryError: Error, Equatable, LocalizedError {
    case bindingNoLongerCurrent
    case unsafeSource(String)
    case sourceMissing(String)
    case sourceChanged(String)
    case identityMismatch
    case liveSourceExists(String)
    case destinationExists(String)
    case unsafeExportDestination(String)
    case io(String)

    var errorDescription: String? {
        switch self {
        case .bindingNoLongerCurrent:
            return "This recovered Conversation is no longer a current recovery candidate. Refresh and try again."
        case .unsafeSource(let path):
            return "The retained recovery source is not a safe regular file: \(path)"
        case .sourceMissing(let path):
            return "The retained recovery source is missing: \(path)"
        case .sourceChanged(let path):
            return "The retained recovery source changed after library.db recorded it: \(path)"
        case .identityMismatch:
            return "The retained bytes do not decode to the expected Conversation identity."
        case .liveSourceExists(let path):
            return "A live Conversation source already owns this identity: \(path)"
        case .destinationExists(let path):
            return "Restore stopped because the live destination already exists: \(path)"
        case .unsafeExportDestination(let path):
            return "A raw recovery copy cannot be exported into Mechanician’s live Conversations directory: \(path)"
        case .io(let detail):
            return detail
        }
    }
}

/// What a restore actually did, which differs by which library owns the record.
enum RecoveredConversationRestoration: Sendable {
    /// The exact bytes were published as today's canonical legacy sidecar.
    case publishedLegacySidecar(URL)
    /// The stored row was promoted to a live record. No file was written: under SQLite authority the
    /// legacy directory is a frozen snapshot, so publishing a sidecar there restores nothing.
    case promotedAuthorityRecord(Conversation)
}

/// Read/export/restore operations for the exact retained bytes of a Conversation the app could not
/// decode. Reveal and export always operate on the fingerprinted retained file, because those bytes
/// are what a person asked to see. Restore publishes into whichever library is live.
struct RecoveredConversationRecoveryService: Sendable {
    let supportRoot: URL
    /// Resolved per call rather than held, so the service stays a value and a test can stand up its
    /// own authority. Nil means the legacy directory is still the library.
    private let authority: @Sendable () -> LibraryAuthorityRepository?

    init(
        supportRoot: URL = Self.defaultSupportRoot(),
        authority: @escaping @Sendable () -> LibraryAuthorityRepository? = {
            LibraryAuthorityRepository.sharedIfActive
        }
    ) {
        self.supportRoot = supportRoot.standardizedFileURL.resolvingSymlinksInPath()
        self.authority = authority
    }

    /// A plain shadow open refuses an active authority — correctly, since a second writer is what
    /// the marker protocol exists to prevent. Reading through the repository instead is why this
    /// surface can list anything at all once SQLite owns the library.
    func bindings() throws -> [ShadowLibraryRecoveredConversationBinding] {
        if let repository = authority() {
            return try repository.recoveredConversationBindings()
        }
        return try SQLiteLibraryStore(supportRoot: supportRoot).recoveredConversationBindings()
    }

    /// Revalidate both the SQLite receipt and the exact retained bytes before revealing them.
    func sourceURL(for binding: ShadowLibraryRecoveredConversationBinding) throws -> URL {
        let current = try requireCurrent(binding)
        _ = try verifiedSourceData(current)
        return try supportRelativeURL(current.source.identity)
    }

    /// Write an exact user-chosen copy. Export never targets the live Conversations directory and
    /// therefore cannot accidentally adopt a recovery source as current authority.
    func exportRaw(
        _ binding: ShadowLibraryRecoveredConversationBinding,
        to destination: URL
    ) throws {
        let output = destination.standardizedFileURL
        let liveDirectory = conversationsDirectory.resolvingSymlinksInPath()
        let resolvedOutput = output.resolvingSymlinksInPath()
        if resolvedOutput.deletingLastPathComponent() == liveDirectory {
            throw RecoveredConversationRecoveryError.unsafeExportDestination(output.path)
        }
        let current = try requireCurrent(binding)
        let data = try verifiedSourceData(current)
        try decodedConversation(data, id: current.id)
        do {
            try data.write(to: output, options: [.atomic])
            let written = try Data(contentsOf: output, options: [.mappedIfSafe])
            guard written == data else {
                throw RecoveredConversationRecoveryError.io(
                    "The raw recovery copy did not verify after writing.")
            }
        } catch let error as RecoveredConversationRecoveryError {
            throw error
        } catch {
            NSLog("[recovery] raw copy could not be saved: %@", error.localizedDescription)
            throw RecoveredConversationRecoveryError.io(
                "The copy could not be saved. Check that the destination still exists and that "
                + "you can write to it.")
        }
    }

    /// Publish the retained bytes into the live library.
    ///
    /// Under SQLite authority that is the database: the row is already there, carrying the
    /// quarantine file's identity, and promoting it is the whole operation. Writing a sidecar
    /// instead would put the restored Conversation in a directory nothing reads.
    ///
    /// On a legacy library it is a create-only publication of the exact bytes: the operation scans
    /// current live `.json` sources for an existing decoded owner and then uses link-as-publication
    /// so the canonical destination is created atomically and can never replace an existing file.
    @discardableResult
    func restore(
        _ binding: ShadowLibraryRecoveredConversationBinding
    ) throws -> RecoveredConversationRestoration {
        let current = try requireCurrent(binding)
        let data = try verifiedSourceData(current)
        let conversation = try decodedConversation(data, id: current.id)

        if let repository = authority() {
            // No directory scan: the binding query already proves this row still carries a
            // quarantine identity, and a row holds exactly one source, so no live record can own
            // this id. The frozen directory has no say either way.
            do {
                try repository.restoreRecoveredConversation(conversation)
            } catch {
                throw RecoveredConversationRecoveryError.io(
                    "The recovered Conversation could not be added to your library: "
                        + error.localizedDescription)
            }
            return .promotedAuthorityRecord(conversation)
        }

        try requireNoLiveSource(for: current.id)

        let directory = conversationsDirectory
        let directoryFD = try openConversationsDirectory()
        defer { _ = Darwin.close(directoryFD) }
        let destinationName = "\(current.id.uuidString).json"
        let destination = directory.appendingPathComponent(destinationName, isDirectory: false)
        let stagingName = ".restore-\(current.id.uuidString)-\(UUID().uuidString)"
        try writeExclusive(data, directoryFD: directoryFD, name: stagingName)
        defer { _ = Darwin.unlinkat(directoryFD, stagingName, 0) }
        guard Darwin.linkat(directoryFD, stagingName, directoryFD, destinationName, 0) == 0 else {
            if errno == EEXIST {
                throw RecoveredConversationRecoveryError.destinationExists(destination.path)
            }
            throw RecoveredConversationRecoveryError.io(
                "The restored Conversation could not be published: \(Self.posixMessage(errno))")
        }
        guard Darwin.fsync(directoryFD) == 0 else {
            let failure = errno
            // Publication is reported successful only after its directory entry is durable. A
            // failed sync is rolled back best-effort so callers never receive a failure while a
            // newly authoritative sidecar silently remains behind.
            _ = Darwin.unlinkat(directoryFD, destinationName, 0)
            _ = Darwin.fsync(directoryFD)
            throw RecoveredConversationRecoveryError.io(
                "The restored Conversation publication could not be synchronized: \(Self.posixMessage(failure))")
        }
        return .publishedLegacySidecar(destination)
    }

    private var conversationsDirectory: URL {
        supportRoot.appendingPathComponent("conversations", isDirectory: true)
    }

    private func requireCurrent(
        _ binding: ShadowLibraryRecoveredConversationBinding
    ) throws -> ShadowLibraryRecoveredConversationBinding {
        let current = try bindings().first {
            $0.id == binding.id && $0.source.identity == binding.source.identity
                && $0.source.digest == binding.source.digest
                && $0.source.byteCount == binding.source.byteCount
        }
        guard let current else {
            throw RecoveredConversationRecoveryError.bindingNoLongerCurrent
        }
        return current
    }

    private func verifiedSourceData(
        _ binding: ShadowLibraryRecoveredConversationBinding
    ) throws -> Data {
        let url = try supportRelativeURL(binding.source.identity)
        let fd = try openSupportRelativeFile(binding.source.identity, displayURL: url)
        defer { _ = Darwin.close(fd) }
        let data = try readRegularFile(fd, displayPath: url.path)
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard data.count == binding.source.byteCount, digest == binding.source.digest else {
            throw RecoveredConversationRecoveryError.sourceChanged(url.path)
        }
        return data
    }

    /// The retained bytes must decode to the Conversation they claim to be before anything is
    /// published anywhere. The decoded value is the record a promotion commits, so proving the
    /// identity and producing the value are the same step.
    @discardableResult
    private func decodedConversation(_ data: Data, id: UUID) throws -> Conversation {
        guard let conversation = try? ConversationStore.makeDecoder().decode(
            Conversation.self, from: data), conversation.id == id else {
            throw RecoveredConversationRecoveryError.identityMismatch
        }
        return conversation
    }

    private func requireNoLiveSource(for id: UUID) throws {
        let directoryFD = try openConversationsDirectory()
        defer { _ = Darwin.close(directoryFD) }
        guard let directory = fdopendir(Darwin.dup(directoryFD)) else {
            throw RecoveredConversationRecoveryError.io(
                "Mechanician’s live Conversations directory could not be inspected.")
        }
        defer { closedir(directory) }
        let decoder = ConversationStore.makeDecoder()
        while let entry = readdir(directory) {
            let name = withUnsafePointer(to: &entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) {
                    String(cString: $0)
                }
            }
            guard !name.hasPrefix("."), (name as NSString).pathExtension == "json" else {
                continue
            }
            let fd = Darwin.openat(directoryFD, name, O_RDONLY | O_NOFOLLOW)
            guard fd >= 0 else {
                throw RecoveredConversationRecoveryError.io(
                    "Restore stopped because a live JSON source could not be inspected: \(name)")
            }
            let bytes: Data
            do {
                bytes = try readRegularFile(
                    fd, displayPath: conversationsDirectory.appendingPathComponent(name).path)
            } catch {
                _ = Darwin.close(fd)
                throw error
            }
            _ = Darwin.close(fd)
            guard let candidate = try? decoder.decode(Conversation.self, from: bytes) else {
                throw RecoveredConversationRecoveryError.io(
                    "Restore stopped because the identity of a live JSON source could not be proven: \(name)")
            }
            if candidate.id == id {
                throw RecoveredConversationRecoveryError.liveSourceExists(
                    conversationsDirectory.appendingPathComponent(name).path)
            }
        }
    }

    private func supportRelativeURL(_ identity: String) throws -> URL {
        let components = try sourceComponents(identity)
        guard !identity.isEmpty, !identity.hasPrefix("/"),
              components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            throw RecoveredConversationRecoveryError.unsafeSource(identity)
        }
        return components.reduce(supportRoot) {
            $0.appendingPathComponent($1, isDirectory: false)
        }
    }

    private func writeExclusive(_ data: Data, directoryFD: Int32, name: String) throws {
        let fd = Darwin.openat(
            directoryFD, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard fd >= 0 else {
            throw RecoveredConversationRecoveryError.io(
                "A private restore staging file could not be created: \(Self.posixMessage(errno))")
        }
        var keep = false
        defer {
            _ = Darwin.close(fd)
            if !keep { _ = Darwin.unlinkat(directoryFD, name, 0) }
        }
        let failedErrno: Int32? = data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return nil }
            var offset = 0
            while offset < raw.count {
                let count = Darwin.write(fd, base.advanced(by: offset), raw.count - offset)
                if count < 0 {
                    if errno == EINTR { continue }
                    return errno
                }
                offset += count
            }
            return nil
        }
        if let failedErrno {
            throw RecoveredConversationRecoveryError.io(
                "The restored Conversation could not be staged: \(Self.posixMessage(failedErrno))")
        }
        guard Darwin.fsync(fd) == 0 else {
            throw RecoveredConversationRecoveryError.io(
                "The restored Conversation could not be synchronized: \(Self.posixMessage(errno))")
        }
        keep = true
    }

    /// Open a support-root-relative source one descriptor component at a time. `O_NOFOLLOW` on
    /// every hop prevents a symlinked `conversations/` (not just a symlinked final file) from
    /// escaping the app-owned recovery namespace.
    private func openSupportRelativeFile(_ identity: String, displayURL: URL) throws -> Int32 {
        let components = try sourceComponents(identity)
        guard !components.isEmpty else {
            throw RecoveredConversationRecoveryError.unsafeSource(displayURL.path)
        }
        var directoryFD = Darwin.open(supportRoot.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard directoryFD >= 0 else {
            throw RecoveredConversationRecoveryError.unsafeSource(supportRoot.path)
        }
        for component in components.dropLast() {
            let next = Darwin.openat(
                directoryFD, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
            _ = Darwin.close(directoryFD)
            guard next >= 0 else {
                throw RecoveredConversationRecoveryError.unsafeSource(displayURL.path)
            }
            directoryFD = next
        }
        let fd = Darwin.openat(directoryFD, components.last!, O_RDONLY | O_NOFOLLOW)
        let failure = errno
        _ = Darwin.close(directoryFD)
        guard fd >= 0 else {
            if failure == ENOENT {
                throw RecoveredConversationRecoveryError.sourceMissing(displayURL.path)
            }
            throw RecoveredConversationRecoveryError.unsafeSource(displayURL.path)
        }
        return fd
    }

    /// A support-root URL reached through macOS's `/var` → `/private/var` alias can make the
    /// coordinator's historical path-prefix fallback retain only the basename. The recovery
    /// marker unambiguously identifies that legacy basename as a Conversation-directory source.
    private func sourceComponents(_ identity: String) throws -> [String] {
        let raw = identity.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard !identity.isEmpty, !identity.hasPrefix("/"),
              raw.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            throw RecoveredConversationRecoveryError.unsafeSource(identity)
        }
        if raw.count == 1, identity.contains(".json.corrupt-") {
            return ["conversations", identity]
        }
        return raw
    }

    private func openConversationsDirectory() throws -> Int32 {
        let rootFD = Darwin.open(supportRoot.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard rootFD >= 0 else {
            throw RecoveredConversationRecoveryError.unsafeSource(supportRoot.path)
        }
        defer { _ = Darwin.close(rootFD) }
        let fd = Darwin.openat(rootFD, "conversations", O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard fd >= 0 else {
            throw RecoveredConversationRecoveryError.io(
                "Mechanician’s live Conversations directory is unavailable or unsafe.")
        }
        return fd
    }

    private func readRegularFile(_ fd: Int32, displayPath: String) throws -> Data {
        var metadata = stat()
        guard fstat(fd, &metadata) == 0, metadata.st_mode & S_IFMT == S_IFREG else {
            throw RecoveredConversationRecoveryError.unsafeSource(displayPath)
        }
        var data = Data()
        if metadata.st_size > 0 && metadata.st_size <= Int64(Int.max) {
            data.reserveCapacity(Int(metadata.st_size))
        }
        var buffer = [UInt8](repeating: 0, count: 1024 * 1024)
        while true {
            let count = buffer.withUnsafeMutableBytes {
                Darwin.read(fd, $0.baseAddress, $0.count)
            }
            if count == 0 { break }
            guard count > 0 else {
                if errno == EINTR { continue }
                throw RecoveredConversationRecoveryError.io(
                    "The retained recovery source could not be read: \(Self.posixMessage(errno))")
            }
            data.append(contentsOf: buffer[0..<count])
        }
        return data
    }

    private static func defaultSupportRoot() -> URL {
        return MechanicianEnvironment.currentSupportRoot()
    }

    private static func posixMessage(_ code: Int32) -> String {
        String(cString: strerror(code))
    }
}

@MainActor
final class RecoveredConversationRecoveryModel: ObservableObject {
    @Published private(set) var bindings: [ShadowLibraryRecoveredConversationBinding] = []
    @Published private(set) var isLoading = false
    @Published private(set) var busyIDs: Set<UUID> = []
    @Published var message: String?

    private let service: RecoveredConversationRecoveryService

    init(service: RecoveredConversationRecoveryService = .init()) {
        self.service = service
    }

    func load() {
        guard !isLoading else { return }
        isLoading = true
        message = nil
        Task {
            do {
                bindings = try await Task.detached { [service] in
                    try service.bindings()
                }.value
            } catch {
                message = Self.personMessage(for: error)
            }
            isLoading = false
        }
    }

    func reveal(_ binding: ShadowLibraryRecoveredConversationBinding) {
        perform(binding) { [service] in
            let url = try service.sourceURL(for: binding)
            await MainActor.run {
                NSWorkspace.shared.activateFileViewerSelecting([url])
            }
            return "Revealed the retained recovery source in Finder."
        }
    }

    func exportRaw(
        _ binding: ShadowLibraryRecoveredConversationBinding,
        to destination: URL
    ) {
        perform(binding) { [service] in
            try service.exportRaw(binding, to: destination)
            return "Saved an exact raw copy as \(destination.lastPathComponent)."
        }
    }

    func restore(_ binding: ShadowLibraryRecoveredConversationBinding) {
        perform(binding) { [service] in
            switch try service.restore(binding) {
            case .promotedAuthorityRecord(let conversation):
                await MainActor.run {
                    ConversationStore.shared.adoptRestoredConversation(conversation)
                }
            case .publishedLegacySidecar(let destination):
                let adopted = await MainActor.run {
                    ConversationStore.shared.reloadFromDisk(binding.id)
                }
                guard adopted else {
                    throw RecoveredConversationRecoveryError.io(
                        "The exact sidecar was restored, but the running app could not open it. "
                            + "Relaunch Mechanician; the restored file remains intact at "
                            + destination.path + ".")
                }
            }
            return "Restored \(binding.title) as a live Conversation."
        } completion: { [weak self] succeeded in
            guard succeeded else { return }
            self?.bindings.removeAll { $0.id == binding.id }
        }
    }

    private func perform(
        _ binding: ShadowLibraryRecoveredConversationBinding,
        operation: @escaping @Sendable () async throws -> String,
        completion: @escaping (Bool) -> Void = { _ in }
    ) {
        guard !busyIDs.contains(binding.id) else { return }
        busyIDs.insert(binding.id)
        message = nil
        Task {
            do {
                message = try await Task.detached {
                    try await operation()
                }.value
                completion(true)
            } catch {
                message = Self.personMessage(for: error)
                completion(false)
            }
            busyIDs.remove(binding.id)
        }
    }

    /// This service's own errors are written for the person who hit them. Anything else comes from
    /// the storage engine and says so in its own vocabulary, which belongs in the log.
    nonisolated static func personMessage(for error: Error) -> String {
        if let recovery = error as? RecoveredConversationRecoveryError {
            return recovery.localizedDescription
        }
        NSLog("[recovery] recovered-conversation operation failed: %@", "\(error)")
        return "Mechanician couldn't read the conversations it saved for recovery. "
            + "Nothing was changed. Quit and reopen Mechanician to try again."
    }
}

struct RecoveredConversationRecoveryView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var model: RecoveredConversationRecoveryModel
    @State private var restoreCandidate: ShadowLibraryRecoveredConversationBinding?

    init(service: RecoveredConversationRecoveryService = .init()) {
        _model = StateObject(wrappedValue: RecoveredConversationRecoveryModel(service: service))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Recovered Conversations")
                        .font(.title2.weight(.semibold))
                    Text("These exact retained sidecars are represented in library.db but are not live Conversations.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }

            Group {
                if model.isLoading && model.bindings.isEmpty {
                    ProgressView("Reading recovery bindings…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if model.bindings.isEmpty {
                    ContentUnavailableView(
                        "No Recovered Conversations",
                        systemImage: "checkmark.circle",
                        description: Text("No current lossless recovery bindings remain."))
                } else {
                    List(model.bindings) { binding in
                        recoveryRow(binding)
                    }
                    .listStyle(.inset)
                }
            }
            .frame(minHeight: 330)

            if let message = model.message, !message.isEmpty {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Text("Restore is create-only. It revalidates the retained bytes and stops if any "
                + "live JSON source already owns the Conversation identity; it never replaces "
                + "an existing sidecar.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(20)
        .frame(minWidth: 760, idealWidth: 820, minHeight: 470, idealHeight: 540)
        .task { model.load() }
        .alert(item: $restoreCandidate) { binding in
            Alert(
                title: Text("Restore “\(binding.title)” as a live Conversation?"),
                message: Text("Mechanician will create \(binding.id.uuidString).json from the "
                    + "exact retained bytes. This changes today’s legacy-file library and cannot "
                    + "overwrite an existing live source."),
                primaryButton: .destructive(Text("Restore Conversation")) {
                    model.restore(binding)
                },
                secondaryButton: .cancel())
        }
    }

    private func recoveryRow(
        _ binding: ShadowLibraryRecoveredConversationBinding
    ) -> some View {
        let busy = model.busyIDs.contains(binding.id)
        return VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(binding.title.isEmpty ? "Untitled Conversation" : binding.title)
                        .fontWeight(.medium)
                        .lineLimit(1)
                    Text(binding.id.uuidString)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                Spacer()
                if busy { ProgressView().controlSize(.small) }
                Button("Reveal") { model.reveal(binding) }
                    .disabled(busy)
                Button("Save Raw Copy…") { chooseExport(binding) }
                    .disabled(busy)
                Button("Restore…") { restoreCandidate = binding }
                    .disabled(busy)
            }
            HStack(spacing: 10) {
                Text(binding.updatedAt.formatted(.dateTime.year().month().day().hour().minute()))
                Text(ByteCountFormatter.string(
                    fromByteCount: Int64(binding.source.byteCount), countStyle: .file))
                Text(binding.source.identity)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 5)
    }

    private func chooseExport(_ binding: ShadowLibraryRecoveredConversationBinding) {
        let panel = NSSavePanel()
        panel.title = "Save Raw Recovered Conversation"
        panel.prompt = "Save Copy"
        panel.allowedContentTypes = [.json]
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.nameFieldStringValue = "\(binding.id.uuidString).recovered.json"
        let completion: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK, let destination = panel.url else { return }
            model.exportRaw(binding, to: destination)
        }
        if let window = NSApp.keyWindow {
            panel.beginSheetModal(for: window, completionHandler: completion)
        } else {
            panel.begin(completionHandler: completion)
        }
    }
}
