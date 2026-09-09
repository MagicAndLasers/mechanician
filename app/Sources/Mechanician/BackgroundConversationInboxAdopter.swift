import Darwin
import CryptoKit
import Foundation

private struct AuthorityInboxJSONKey: CodingKey {
    let stringValue: String
    let intValue: Int? = nil

    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { return nil }
}

private func requireExactAuthorityInboxKeys(
    _ decoder: Decoder,
    expected: Set<String>,
    label: String
) throws {
    let container = try decoder.container(keyedBy: AuthorityInboxJSONKey.self)
    let actual = Set(container.allKeys.map(\.stringValue))
    guard actual == expected else {
        throw DecodingError.dataCorrupted(.init(
            codingPath: decoder.codingPath,
            debugDescription: "\(label) fields must be exactly \(expected.sorted().joined(separator: ", "))."))
    }
}

/// A value type used only to prove that producer-owned collections remain empty. Any element is a
/// schema violation; decoding an empty array or dictionary never asks this type to decode.
private struct RejectedAuthorityInboxValue: Decodable {
    init(from decoder: Decoder) throws {
        throw DecodingError.dataCorrupted(.init(
            codingPath: decoder.codingPath,
            debugDescription: "This authority-inbox collection must remain empty."))
    }
}

/// The complete and deliberately finite v1 ambient result row. It is not a TranscriptEntry decode:
/// accepting the app's tolerant persistence schema here would let an external producer populate
/// provider handles, tool lifecycle, permissions, questions, media paths, or future operative state.
private struct AmbientCreateMessage: Decodable {
    private enum CodingKeys: String, CodingKey, CaseIterable {
        case id, kind, text, observedAt, toolIsError, permDecided, permAllowed
    }

    let id: UUID
    let kind: TranscriptEntry.Kind
    let text: String
    let observedAt: Date

    init(from decoder: Decoder) throws {
        try requireExactAuthorityInboxKeys(
            decoder,
            expected: Set(CodingKeys.allCases.map(\.rawValue)),
            label: "ambient message")
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        kind = try container.decode(TranscriptEntry.Kind.self, forKey: .kind)
        text = try container.decode(String.self, forKey: .text)
        observedAt = try container.decode(Date.self, forKey: .observedAt)
        guard kind == .user || kind == .assistant,
              try !container.decode(Bool.self, forKey: .toolIsError),
              try !container.decode(Bool.self, forKey: .permDecided),
              try !container.decode(Bool.self, forKey: .permAllowed) else {
            throw DecodingError.dataCorrupted(.init(
                codingPath: decoder.codingPath,
                debugDescription: "Ambient result messages must be inert user/assistant text."))
        }
    }

    var transcriptEntry: TranscriptEntry {
        TranscriptEntry(id: id, kind: kind, text: text, observedAt: observedAt)
    }
}

/// Exact payload emitted by `ambientd.publishResultConversation`. Unknown keys are rejected instead
/// of being ignored by Codable, and fields present solely for wire compatibility are constrained to
/// their inert producer values before an app-owned Conversation is explicitly constructed.
private struct AmbientConversationCreatePayload: Decodable {
    private enum CodingKeys: String, CodingKey, CaseIterable {
        case id, title, projectID, cwd, sdkSessionId, messages, updatedAt, errored
        case artifacts, workflowRuns
    }

    let id: UUID
    let title: String
    let projectID: UUID?
    let cwd: String
    let messages: [AmbientCreateMessage]
    let updatedAt: Date
    let errored: Bool

    init(from decoder: Decoder) throws {
        try requireExactAuthorityInboxKeys(
            decoder,
            expected: Set(CodingKeys.allCases.map(\.rawValue)),
            label: "ambient Conversation create")
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        title = try container.decode(String.self, forKey: .title)
        projectID = try container.decodeIfPresent(UUID.self, forKey: .projectID)
        cwd = try container.decode(String.self, forKey: .cwd)
        guard try container.decodeNil(forKey: .sdkSessionId) else {
            throw DecodingError.dataCorruptedError(
                forKey: .sdkSessionId,
                in: container,
                debugDescription: "An ambient create cannot carry a provider session handle.")
        }
        messages = try container.decode([AmbientCreateMessage].self, forKey: .messages)
        updatedAt = try container.decode(Date.self, forKey: .updatedAt)
        errored = try container.decode(Bool.self, forKey: .errored)
        let artifacts = try container.decode(
            [RejectedAuthorityInboxValue].self, forKey: .artifacts)
        let workflowRuns = try container.decode(
            [String: RejectedAuthorityInboxValue].self, forKey: .workflowRuns)
        guard artifacts.isEmpty, workflowRuns.isEmpty,
              messages.count == 2,
              messages[0].kind == .user,
              messages[1].kind == .assistant,
              Set(messages.map(\.id)).count == messages.count else {
            throw DecodingError.dataCorrupted(.init(
                codingPath: decoder.codingPath,
                debugDescription: "Ambient create must contain one user row and one assistant row only."))
        }
    }

    var inertConversation: Conversation {
        Conversation(
            id: id,
            title: title,
            titleSource: .legacy,
            cwd: cwd,
            sdkSessionId: nil,
            sdkSessionRouteIdentity: nil,
            sdkSessionExtensionRevision: nil,
            sdkSessionWorkspaceInstructionsRevision: nil,
            modelSelection: nil,
            messages: messages.map(\.transcriptEntry),
            updatedAt: updatedAt,
            forkProvenance: nil,
            artifacts: [],
            workflowRuns: [:],
            subagents: [:],
            agentActivity: [],
            captureOrdinalHighWatermark: nil,
            queuedPrompts: [],
            draft: "",
            favorite: false,
            sortIndex: nil,
            armedTrigger: nil,
            unread: false,
            errored: errored,
            projectID: projectID,
            contextTokens: nil,
            contextWindow: nil,
            contextModel: nil,
            providerAccessRequest: nil,
            claudePreferences: nil)
    }
}

/// The app-owned half of the v1 authority inbox. External producers can create immutable envelopes
/// while Mechanician is closed, but only the process holding the storage-authority lease may turn
/// one into live product state. A successful move to `adopted/` is the durable file receipt.
@MainActor
final class AuthorityInboxAdopter {
    static let shared = AuthorityInboxAdopter(
        anchorRoot: StorageAuthorityBootstrap.current.anchorRoot)

    private enum ScannedItem {
        case ready(URL, ValidatedAuthorityInboxOperation)
        case incomplete
        case moreAvailable
        case sourceUnavailable
        case invalid(URL, String)
    }

    private struct Directories {
        let pending: URL
        let adopted: URL
        let quarantine: URL
    }

    private struct StableEnvelopeRead {
        let bytes: Data
        let identity: ValidatedAuthorityInboxConversationEnvelope.FileIdentity
    }

    private enum AmbientCreateEnvelopeError: Error, LocalizedError, Equatable {
        case invalidFilename
        case publicationIncomplete
        case unsafeEnvelope
        case invalidEnvelope
        case invalidPayload

        var errorDescription: String? {
            switch self {
            case .invalidFilename: "Authority inbox envelope has an invalid filename."
            case .publicationIncomplete: "Authority inbox publication is not complete."
            case .unsafeEnvelope: "Authority inbox envelope is not a stable private file."
            case .invalidEnvelope: "Authority inbox envelope does not match the finite v1 schema."
            case .invalidPayload: "Authority inbox payload is not an inert ambient Conversation create."
            }
        }
    }

    private let anchorRoot: URL
    private let artifactStoreOverride: ArtifactStore?
    private let worker = DispatchQueue(
        label: "ai.mechanician.authority-inbox-adopter", qos: .utility)
    private weak var conversationStore: ConversationStore?
    private var directories: Directories?
    private var watcher: DispatchSourceFileSystemObject?
    private var watchesDirectory = false
    private var scheduledWatcherRepair: DispatchWorkItem?
    private var watcherRetryDelay: TimeInterval = 0.25
    private var scanInFlight = false
    private var rescanRequested = false
    private var scheduledScan: DispatchWorkItem?
    private var retryDelay: TimeInterval = 0.25
    private var idleCallbacks: [() -> Void] = []

    init(
        anchorRoot: URL,
        artifactStore: ArtifactStore? = nil
    ) {
        self.anchorRoot = anchorRoot.standardizedFileURL
        artifactStoreOverride = artifactStore
    }

    /// Tests inject an isolated store; production resolves the process singleton only when an
    /// Artifact operation actually arrives, so Conversation-only startup does not eagerly load it.
    private var artifactStore: ArtifactStore { artifactStoreOverride ?? .shared }

    deinit {
        scheduledWatcherRepair?.cancel()
        watcher?.cancel()
    }

    /// Start only after the complete Conversation inventory is ready. The watcher is armed before
    /// the first scan so a producer publication cannot fall into a launch-time observation gap.
    func start(
        conversationStore: ConversationStore,
        watchesDirectory: Bool = true
    ) {
        guard self.conversationStore == nil else { return }
        let usesProcessAuthority = anchorRoot == StorageAuthorityBootstrap.current.anchorRoot
        guard !usesProcessAuthority
                || (StorageAuthorityBootstrap.current.disposition.allowsNormalProduct
                    && StorageAuthorityBootstrap.ownsProcessLease) else { return }
        do {
            let prepared = try Self.prepareDirectories(anchorRoot: anchorRoot)
            self.conversationStore = conversationStore
            directories = prepared
            self.watchesDirectory = watchesDirectory
            if watchesDirectory {
                do {
                    try startWatcher(pending: prepared.pending)
                } catch {
                    scheduleWatcherRepair()
                }
            }
            // Catch up a receipt whose rename+fsync completed just before the previous process
            // exited.
            requestScan()
        } catch {
            // An unsafe inbox is not interpreted as permission to traverse or repair it. The A3b
            // readiness census reports the path problem; a later launch may retry after repair.
        }
    }

#if DEBUG
    /// Deterministic focused-test seam. Completion runs once all work discovered by this scan has
    /// either committed, quarantined, or been left pending for a bounded retry.
    func scanForTesting(completion: @escaping () -> Void) {
        idleCallbacks.append(completion)
        requestScan()
    }
#endif

    private func startWatcher(pending: URL) throws {
        guard watcher == nil else { return }
        let descriptor = Darwin.open(
            pending.path, O_EVTONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0,
              metadata.st_mode & S_IFMT == S_IFDIR,
              metadata.st_uid == geteuid(),
              metadata.st_mode & 0o077 == 0 else {
            Darwin.close(descriptor)
            throw POSIXError(.EPERM)
        }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .rename, .delete],
            queue: .main)
        // `resume` activates a source asynchronously. Scanning from its registration handler
        // closes the gap between the eager startup scan and the point at which vnode edges can no
        // longer be missed.
        source.setRegistrationHandler { [weak self] in self?.requestScan() }
        source.setEventHandler { [weak self] in self?.handleWatcherEvent() }
        source.setCancelHandler { Darwin.close(descriptor) }
        watcher = source
        source.resume()
    }

    private func handleWatcherEvent() {
        guard let watcher else { return }
        let events = watcher.data
        if events.contains(.rename) || events.contains(.delete) {
            watcher.cancel()
            self.watcher = nil
            scheduleWatcherRepair()
        }
        requestScan()
    }

    private func scheduleWatcherRepair() {
        guard watchesDirectory, watcher == nil, scheduledWatcherRepair == nil else { return }
        let delay = watcherRetryDelay
        watcherRetryDelay = min(30, watcherRetryDelay * 2)
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.scheduledWatcherRepair = nil
            do {
                let prepared = try Self.prepareDirectories(anchorRoot: self.anchorRoot)
                self.directories = prepared
                try self.startWatcher(pending: prepared.pending)
                self.watcherRetryDelay = 0.25
                self.requestScan()
            } catch {
                self.scheduleWatcherRepair()
            }
        }
        scheduledWatcherRepair = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func requestScan(after delay: TimeInterval = 0) {
        if scanInFlight {
            rescanRequested = true
            return
        }
        if scheduledScan != nil { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.scheduledScan = nil
            self.beginScan()
        }
        scheduledScan = work
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0, delay), execute: work)
    }

    private func beginScan() {
        guard !scanInFlight, let directories, conversationStore != nil else {
            finishIdleCallbacksIfPossible()
            return
        }
        scanInFlight = true
        let supportRoot = anchorRoot
        worker.async { [weak self] in
            let items = Self.scan(
                directory: directories.pending,
                supportRoot: supportRoot)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self?.process(items, at: 0, needsRetry: false)
                }
            }
        }
    }

    nonisolated private static func scan(
        directory: URL,
        supportRoot: URL
    ) -> [ScannedItem] {
        let urls: [URL]
        do {
            urls = try FileManager.default.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: nil, options: [])
                .sorted { $0.lastPathComponent < $1.lastPathComponent }
        } catch {
            // The directory itself is never an envelope and must never be sent through the file
            // quarantine path. Leave it intact and retry after the transient/permission issue is
            // repaired; the authority readiness census remains conservative in the meantime.
            return [.sourceUnavailable]
        }
        var sawIncomplete = false
        for (index, url) in urls.enumerated() {
            let item: ScannedItem
            do {
                let initialRead = try readStablePrivateEnvelope(at: url)
                let discriminator = try envelopeDiscriminator(initialRead.bytes)
                if discriminator == ("conversation", "create") {
                    item = .ready(url, .conversation(
                        try readAmbientConversationCreate(at: url, read: initialRead)))
                } else {
                    // Artifact/upsert is the other finite v1 operation. The shared scanner owns
                    // its exact metadata schema plus retained-source path/digest validation.
                    let operation = try LibraryAuthorityInboxOperationScanner.readOperation(
                        at: url, supportRoot: supportRoot)
                    item = .ready(url, operation)
                }
            } catch {
                if (error as? AmbientCreateEnvelopeError) == .publicationIncomplete
                    || LibraryAuthorityInboxOperationScanner.publicationIsIncomplete(error) {
                    sawIncomplete = true
                    continue
                }
                item = .invalid(url, error.localizedDescription)
            }
            var result = [item]
            if sawIncomplete { result.append(.incomplete) }
            if index < urls.index(before: urls.endIndex) { result.append(.moreAvailable) }
            return result
        }
        return sawIncomplete ? [.incomplete] : []
    }

    private func process(
        _ items: [ScannedItem],
        at index: Int,
        needsRetry: Bool
    ) {
        guard index < items.count else {
            finishScan(needsRetry: needsRetry)
            return
        }
        switch items[index] {
        case .incomplete:
            process(items, at: index + 1, needsRetry: true)
        case .moreAvailable:
            rescanRequested = true
            process(items, at: index + 1, needsRetry: needsRetry)
        case .sourceUnavailable:
            process(items, at: index + 1, needsRetry: true)
        case .invalid(let source, let reason):
            moveToQuarantine(source, validated: nil, reason: reason) { [weak self] in
                self?.process(items, at: index + 1, needsRetry: needsRetry)
            }
        case .ready(let source, let operation):
            guard let conversationStore else {
                finishScan(needsRetry: true)
                return
            }
            consumeExistingReceipt(source, operation: operation) { [weak self] replay in
                guard let self else { return }
                switch replay {
                case .consumed, .rejected:
                    self.process(items, at: index + 1, needsRetry: needsRetry)
                case .absent:
                    self.adopt(
                        operation,
                        source: source,
                        conversationStore: conversationStore,
                        items: items,
                        nextIndex: index + 1,
                        needsRetry: needsRetry)
                }
            }
        }
    }

    private func adopt(
        _ operation: ValidatedAuthorityInboxOperation,
        source: URL,
        conversationStore: ConversationStore,
        items: [ScannedItem],
        nextIndex: Int,
        needsRetry: Bool
    ) {
        let authorityCapture: LibraryTransientOperationCaptureFactory.Capture
        do {
            authorityCapture = try makeAuthorityCapture(for: operation)
        } catch {
            moveToQuarantine(
                source,
                validated: operation,
                reason: "The adoption receipt could not be represented: \(error.localizedDescription)") {
                    self.process(items, at: nextIndex, needsRetry: needsRetry)
                }
            return
        }
        switch operation {
        case .conversation(let envelope):
            conversationStore.adoptBackgroundConversation(
                envelope.conversation,
                authorityCapture: authorityCapture
            ) {
                [weak self] result in
                guard let self else { return }
                switch result {
                case .published, .alreadyPublished:
                    self.moveToAdopted(source, operation: operation) { succeeded in
                        self.process(
                            items,
                            at: nextIndex,
                            needsRetry: needsRetry || !succeeded)
                    }
                case .identityCollision:
                    self.moveToQuarantine(
                        source,
                        validated: operation,
                        reason: "Conversation UUID already exists with different content.") {
                            self.process(items, at: nextIndex, needsRetry: needsRetry)
                        }
                case .persistenceFailed:
                    self.process(items, at: nextIndex, needsRetry: true)
                }
            }
        case .artifact(let envelope):
            artifactStore.adoptBackgroundArtifact(
                envelope.artifact,
                producerTaskID: envelope.producerTaskID,
                retainedSourceBytes: envelope.retainedSourceBytes,
                authorityCapture: authorityCapture
            ) { [weak self] result in
                guard let self else { return }
                switch result {
                case .published, .alreadyPublished:
                    self.moveToAdopted(source, operation: operation) { succeeded in
                        self.process(
                            items,
                            at: nextIndex,
                            needsRetry: needsRetry || !succeeded)
                    }
                case .identityCollision, .invalidSource:
                    self.moveToQuarantine(
                        source,
                        validated: operation,
                        reason: "Artifact UUID or retained source collides with existing content.") {
                            self.process(items, at: nextIndex, needsRetry: needsRetry)
                        }
                case .persistenceFailed:
                    self.process(items, at: nextIndex, needsRetry: true)
                }
            }
        }
    }

    /// Build the exact operation/receipt pair before the entity commit. Under SQLite authority the
    /// repository publishes all three in one transaction; only after that succeeds may the pending
    /// envelope move to `adopted/` as its durable file receipt.
    private func makeAuthorityCapture(
        for validated: ValidatedAuthorityInboxOperation
    ) throws -> LibraryTransientOperationCaptureFactory.Capture {
        let digest = SHA256.hash(data: validated.rawBytes)
            .map { String(format: "%02x", $0) }.joined()
        let sourceIdentity = "authority-inbox/v1/adopted/ambientd/"
            + "\(validated.operationID.uuidString).json"
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
        let operation = try LibraryOperationSnapshot.backgroundAdoption(
            id: validated.operationID,
            state: .committed,
            idempotencyKey: "authority-inbox-v1:\(validated.operationID.uuidString)",
            recordedAt: validated.createdAt,
            payload: LibraryBackgroundAdoptionOperationPayload(
                sourceIdentity: sourceIdentity,
                sourceRevision: "sha256:\(digest)",
                sourceDigest: digest,
                conversationID: conversationID,
                artifactID: artifactID))
        let receipt = try LibraryOperationReceiptSnapshot(
            id: validated.operationID,
            operationID: validated.operationID,
            operationKind: .backgroundAdoption,
            state: .applied,
            attempt: 0,
            recordedAt: validated.createdAt,
            details: LibraryOperationReceiptDetails(
                diagnostics: diagnostics,
                retainedSourceCount: retainedSourceCount))
        return LibraryTransientOperationCaptureFactory.Capture(
            operation: operation, receipt: receipt)
    }

    private enum ExistingReceiptResult {
        case absent
        case consumed
        case rejected
    }

    /// The adopted envelope is the durable operation receipt. Prove it before consulting mutable
    /// Conversation state: an exact producer retry must remain idempotent after the user renames,
    /// annotates, or otherwise evolves the Conversation created by the original operation.
    private func consumeExistingReceipt(
        _ source: URL,
        operation: ValidatedAuthorityInboxOperation,
        attempt: Int = 0,
        completion: @escaping (ExistingReceiptResult) -> Void
    ) {
        guard let directories else { completion(.absent); return }
        let destination = directories.adopted.appendingPathComponent(
            "\(operation.operationID.uuidString).json")
        worker.async { [weak self] in
            do {
                guard let matches = try Self.existingReceiptMatches(
                    operation.rawBytes, at: destination) else {
                    DispatchQueue.main.async { completion(.absent) }
                    return
                }
                guard matches else { throw InboxAdoptionError.adoptedCollision }
                try Self.unlinkAttested(source, identity: operation.fileIdentity)
                try Self.syncDirectories([directories.pending, directories.adopted])
                DispatchQueue.main.async { completion(.consumed) }
            } catch {
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    if let adoptionError = error as? InboxAdoptionError,
                       adoptionError == .sourceChanged
                        || adoptionError == .adoptedCollision
                        || adoptionError == .unsafeReceipt {
                        self.moveToQuarantine(
                            source,
                            validated: operation,
                            reason: "Existing adoption receipt is invalid: \(error.localizedDescription)") {
                                completion(.rejected)
                            }
                        return
                    }
                    let exponent = min(attempt, 7)
                    let delay = min(30, 0.25 * pow(2, Double(exponent)))
                    DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                        self?.consumeExistingReceipt(
                            source,
                            operation: operation,
                            attempt: attempt + 1,
                            completion: completion)
                    }
                }
            }
        }
    }

    private func moveToAdopted(
        _ source: URL,
        operation: ValidatedAuthorityInboxOperation,
        attempt: Int = 0,
        completion: @escaping (Bool) -> Void
    ) {
        guard let directories else { completion(false); return }
        worker.async { [weak self] in
            do {
                let destination = directories.adopted.appendingPathComponent(
                    "\(operation.operationID.uuidString).json")
                if let matches = try Self.existingReceiptMatches(
                    operation.rawBytes, at: destination) {
                    guard matches else { throw InboxAdoptionError.adoptedCollision }
                    // A retry after rename but before/while directory fsync legitimately has no
                    // pending source. A duplicate delivery has both names and removes only the
                    // attested pending file after proving the adopted bytes are identical.
                    if FileManager.default.fileExists(atPath: source.path) {
                        try Self.unlinkAttested(source, identity: operation.fileIdentity)
                    }
                    try Self.syncDirectories([directories.pending, directories.adopted])
                } else {
                    guard LibraryAuthorityInboxOperationScanner.fileStillMatches(
                        operation.fileIdentity, at: source) else {
                        throw InboxAdoptionError.sourceChanged
                    }
                    try Self.renameExclusive(source, destination)
                    try Self.syncDirectories([directories.pending, directories.adopted])
                }
                DispatchQueue.main.async { completion(true) }
            } catch {
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    if let adoptionError = error as? InboxAdoptionError,
                       adoptionError == .sourceChanged
                        || adoptionError == .adoptedCollision
                        || adoptionError == .unsafeReceipt {
                        self.moveToQuarantine(
                            source,
                            validated: operation,
                            reason: "Adoption receipt could not publish: \(error.localizedDescription)") {
                                completion(false)
                            }
                        return
                    }
                    // A rename may already have committed even when its following directory fsync
                    // reports a transient failure. Retry the exact destination-first proof until
                    // it is durable; never misclassify infrastructure failure as hostile input and
                    // never acknowledge the operation from an uncertain receipt.
                    let exponent = min(attempt, 7)
                    let delay = min(30, 0.25 * pow(2, Double(exponent)))
                    DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                        self?.moveToAdopted(
                            source,
                            operation: operation,
                            attempt: attempt + 1,
                            completion: completion)
                    }
                }
            }
        }
    }

    private func moveToQuarantine(
        _ source: URL,
        validated: ValidatedAuthorityInboxOperation?,
        reason: String,
        completion: @escaping () -> Void
    ) {
        guard let directories else { completion(); return }
        worker.async {
            let operationStem = validated?.operationID.uuidString
                ?? UUID(uuidString: source.deletingPathExtension().lastPathComponent)?.uuidString
                ?? "UNKNOWN"
            let unique = UUID().uuidString
            let destination = directories.quarantine.appendingPathComponent(
                "\(operationStem).\(unique).json")
            do {
                if let validated,
                   !LibraryAuthorityInboxOperationScanner.fileStillMatches(
                    validated.fileIdentity, at: source) {
                    throw InboxAdoptionError.sourceChanged
                }
                try Self.renameExclusive(source, destination)
                try Self.writeDiagnostic(
                    reason: reason,
                    sourceName: source.lastPathComponent,
                    destination: directories.quarantine.appendingPathComponent(
                        "\(operationStem).\(unique).diagnostic.json"))
                try Self.syncDirectories([directories.pending, directories.quarantine])
            } catch {
                // If a hostile race removed/replaced the source, leave a primary issue record (not
                // merely a diagnostic sidecar) so recovery diagnostics retain the failed source.
                let issue = directories.quarantine.appendingPathComponent(
                    "\(operationStem).\(UUID().uuidString).json")
                try? Self.writeDiagnostic(
                    reason: "Quarantine failed: \(reason) (\(error.localizedDescription))",
                    sourceName: source.lastPathComponent,
                    destination: issue)
                try? Self.syncDirectories([directories.quarantine])
            }
            DispatchQueue.main.async(execute: completion)
        }
    }

    private func finishScan(needsRetry: Bool) {
        scanInFlight = false
        if rescanRequested {
            rescanRequested = false
            requestScan()
            return
        } else if needsRetry {
            let delay = retryDelay
            retryDelay = min(30, retryDelay * 2)
            requestScan(after: delay)
        } else {
            retryDelay = 0.25
        }
        finishIdleCallbacksIfPossible()
    }

    private func finishIdleCallbacksIfPossible() {
        // Tests asking for one pass should not wait through a disk-failure backoff. A later retry
        // remains scheduled and production correctness is unchanged.
        guard !scanInFlight else { return }
        let callbacks = idleCallbacks
        idleCallbacks = []
        callbacks.forEach { $0() }
    }

    /// Live adoption deliberately does not decode the app's full, tolerant Conversation schema.
    /// That schema is a private persistence surface which grows operative fields over time. This
    /// reader validates the immutable envelope and its exact ambient-create DTO, then constructs the
    /// only inert Conversation state external producer v1 is allowed to introduce.
    nonisolated private static func readAmbientConversationCreate(
        at url: URL,
        read: StableEnvelopeRead
    ) throws -> ValidatedAuthorityInboxConversationEnvelope {
        guard url.pathExtension == "json",
              let filenameID = UUID(
                uuidString: url.deletingPathExtension().lastPathComponent) else {
            throw AmbientCreateEnvelopeError.invalidFilename
        }
        guard let object = try JSONSerialization.jsonObject(with: read.bytes)
                as? [String: Any] else {
            throw AmbientCreateEnvelopeError.invalidEnvelope
        }
        guard Set(object.keys) == Set([
            "schemaVersion", "operationID", "subjectID", "producer", "authority",
            "domain", "kind", "definitionRevision", "createdAt", "payload",
            "retainedBytes",
        ]), object["schemaVersion"] as? Int == 1,
              let operationText = boundedEnvelopeString(
                object["operationID"], maximum: 128, identifier: true),
              let operationID = UUID(uuidString: operationText),
              operationID == filenameID,
              let subjectText = boundedEnvelopeString(
                object["subjectID"], maximum: 128, identifier: true),
              let conversationID = UUID(uuidString: subjectText),
              object["domain"] as? String == "conversation",
              object["kind"] as? String == "create" else {
            throw AmbientCreateEnvelopeError.invalidEnvelope
        }

        guard let producer = object["producer"] as? [String: Any],
              Set(producer.keys) == Set(["id", "build"]),
              producer["id"] as? String == "ambientd",
              boundedEnvelopeString(
                producer["build"], maximum: 128, identifier: true) != nil else {
            throw AmbientCreateEnvelopeError.invalidEnvelope
        }
        guard let authority = object["authority"] as? [String: Any],
              Set(authority.keys) == Set(["protocol", "observedGeneration"]),
              authority["protocol"] as? String == "storage-authority-v1",
              boundedEnvelopeString(
                authority["observedGeneration"], maximum: 128, identifier: true) != nil else {
            throw AmbientCreateEnvelopeError.invalidEnvelope
        }
        if !(object["definitionRevision"] is NSNull),
           boundedEnvelopeString(
            object["definitionRevision"], maximum: 16 * 1_024, identifier: false) == nil {
            throw AmbientCreateEnvelopeError.invalidEnvelope
        }
        guard let createdAtText = object["createdAt"] as? String,
              createdAtText.count == 20,
              let createdAt = SendableISO8601Formatter.plain.date(from: createdAtText),
              SendableISO8601Formatter.plain.string(from: createdAt) == createdAtText,
              let retainedBytes = object["retainedBytes"] as? [Any],
              retainedBytes.isEmpty else {
            throw AmbientCreateEnvelopeError.invalidEnvelope
        }

        guard let payload = object["payload"] as? [String: Any],
              Set(payload.keys) == Set(["encoding", "byteCount", "sha256", "data"]),
              payload["encoding"] as? String == "base64url-json",
              let byteCount = payload["byteCount"] as? Int,
              byteCount >= 0,
              byteCount <= LibraryAuthorityInboxOperationScanner.maximumPayloadBytes,
              let digest = payload["sha256"] as? String,
              digest.range(
                of: "^[a-f0-9]{64}$", options: .regularExpression) != nil,
              let encodedPayload = payload["data"] as? String,
              let payloadBytes = canonicalBase64URLData(encodedPayload),
              payloadBytes.count == byteCount,
              sha256(payloadBytes) == digest else {
            throw AmbientCreateEnvelopeError.invalidPayload
        }
        guard let payloadJSON = try JSONSerialization.jsonObject(with: payloadBytes)
                as? [String: Any],
              let canonicalPayload = try? JSONSerialization.data(
                withJSONObject: payloadJSON,
                options: [.sortedKeys, .withoutEscapingSlashes]),
              canonicalPayload == payloadBytes else {
            throw AmbientCreateEnvelopeError.invalidPayload
        }

        let decoded: AmbientConversationCreatePayload
        do {
            decoded = try ConversationStore.makeDecoder().decode(
                AmbientConversationCreatePayload.self, from: payloadBytes)
        } catch {
            throw AmbientCreateEnvelopeError.invalidPayload
        }
        guard decoded.id == conversationID else {
            throw AmbientCreateEnvelopeError.invalidPayload
        }
        let conversation = decoded.inertConversation
        guard conversation.hasDurableContent else {
            throw AmbientCreateEnvelopeError.invalidPayload
        }
        return ValidatedAuthorityInboxConversationEnvelope(
            operationID: operationID,
            conversationID: conversationID,
            createdAt: createdAt,
            conversation: conversation,
            rawBytes: read.bytes,
            fileIdentity: read.identity)
    }

    nonisolated private static func envelopeDiscriminator(
        _ bytes: Data
    ) throws -> (String, String) {
        guard let object = try JSONSerialization.jsonObject(with: bytes) as? [String: Any],
              let domain = object["domain"] as? String,
              let kind = object["kind"] as? String else {
            throw AmbientCreateEnvelopeError.invalidEnvelope
        }
        return (domain, kind)
    }

    nonisolated private static func boundedEnvelopeString(
        _ value: Any?,
        maximum: Int,
        identifier: Bool
    ) -> String? {
        guard let value = value as? String,
              !value.isEmpty,
              value.count <= maximum else { return nil }
        if identifier,
           value.range(
            of: "^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$",
            options: .regularExpression) == nil { return nil }
        return value
    }

    nonisolated private static func canonicalBase64URLData(_ value: String) -> Data? {
        guard value.range(of: "^[A-Za-z0-9_-]*$", options: .regularExpression) != nil else {
            return nil
        }
        let padding = String(repeating: "=", count: (4 - value.count % 4) % 4)
        let base64 = value
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/") + padding
        guard let bytes = Data(base64Encoded: base64) else { return nil }
        let canonical = bytes.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return canonical == value ? bytes : nil
    }

    nonisolated private static func sha256(_ bytes: Data) -> String {
        SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }

    nonisolated private static func readStablePrivateEnvelope(
        at url: URL
    ) throws -> StableEnvelopeRead {
        let descriptor = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        defer { Darwin.close(descriptor) }
        var before = stat()
        guard fstat(descriptor, &before) == 0 else {
            throw POSIXError(.init(rawValue: errno) ?? .EIO)
        }
        if before.st_nlink == 2 { throw AmbientCreateEnvelopeError.publicationIncomplete }
        guard before.st_mode & S_IFMT == S_IFREG,
              before.st_uid == geteuid(),
              before.st_mode & 0o777 == 0o400,
              before.st_nlink == 1,
              before.st_size >= 0,
              before.st_size <= Int64(
                LibraryAuthorityInboxOperationScanner.maximumEnvelopeBytes) else {
            throw AmbientCreateEnvelopeError.unsafeEnvelope
        }

        var bytes = Data()
        bytes.reserveCapacity(Int(before.st_size))
        var buffer = Data(count: 1 * 1_024 * 1_024)
        while bytes.count < Int(before.st_size) {
            let requested = min(buffer.count, Int(before.st_size) - bytes.count)
            let count: Int = buffer.withUnsafeMutableBytes { raw in
                while true {
                    let value = Darwin.read(descriptor, raw.baseAddress, requested)
                    if value < 0, errno == EINTR { continue }
                    return value
                }
            }
            guard count > 0 else {
                if count < 0 { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
                throw AmbientCreateEnvelopeError.publicationIncomplete
            }
            bytes.append(buffer.prefix(count))
        }
        var after = stat()
        guard fstat(descriptor, &after) == 0 else {
            throw POSIXError(.init(rawValue: errno) ?? .EIO)
        }
        guard before.st_dev == after.st_dev,
              before.st_ino == after.st_ino,
              before.st_size == after.st_size,
              before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
              before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
              before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec,
              before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec,
              before.st_mode == after.st_mode,
              before.st_uid == after.st_uid,
              before.st_nlink == after.st_nlink else {
            throw AmbientCreateEnvelopeError.publicationIncomplete
        }
        return StableEnvelopeRead(
            bytes: bytes,
            identity: .init(
                device: UInt64(before.st_dev),
                inode: UInt64(before.st_ino),
                size: Int64(before.st_size),
                modifiedSeconds: Int64(before.st_mtimespec.tv_sec),
                modifiedNanoseconds: Int64(before.st_mtimespec.tv_nsec),
                changedSeconds: Int64(before.st_ctimespec.tv_sec),
                changedNanoseconds: Int64(before.st_ctimespec.tv_nsec)))
    }

    /// `nil` means no receipt exists, `true` is an exact stable receipt, and `false` is a stable
    /// receipt with different bytes. Crucially this never decodes the receipt through Conversation:
    /// replay remains provable after the app's private Conversation model evolves.
    nonisolated private static func existingReceiptMatches(
        _ expected: Data,
        at url: URL
    ) throws -> Bool? {
        do {
            return try readStablePrivateEnvelope(at: url).bytes == expected
        } catch let error as POSIXError where error.code == .ENOENT {
            return nil
        } catch is AmbientCreateEnvelopeError {
            throw InboxAdoptionError.unsafeReceipt
        }
    }

    nonisolated private static func prepareDirectories(anchorRoot: URL) throws -> Directories {
        var cursor = anchorRoot
        try validatePrivateDirectory(cursor)
        func descend(_ component: String) throws -> URL {
            cursor.appendPathComponent(component, isDirectory: true)
            if mkdir(cursor.path, mode_t(0o700)) != 0, errno != EEXIST {
                throw POSIXError(.init(rawValue: errno) ?? .EIO)
            }
            try validatePrivateDirectory(cursor)
            return cursor
        }
        _ = try descend("authority-inbox")
        _ = try descend("v1")
        let version = cursor

        func producerDirectory(_ state: String) throws -> URL {
            cursor = version
            _ = try descend(state)
            return try descend("ambientd")
        }
        let pending = try producerDirectory("pending")
        let adopted = try producerDirectory("adopted")
        let quarantine = try producerDirectory("quarantine")
        return Directories(pending: pending, adopted: adopted, quarantine: quarantine)
    }

    nonisolated private static func validatePrivateDirectory(_ url: URL) throws {
        var value = stat()
        guard lstat(url.path, &value) == 0,
              value.st_mode & S_IFMT == S_IFDIR,
              value.st_uid == geteuid(),
              value.st_mode & 0o077 == 0 else {
            throw InboxAdoptionError.unsafeDirectory
        }
    }

    nonisolated private static func renameExclusive(_ source: URL, _ destination: URL) throws {
        let result = source.path.withCString { sourcePath in
            destination.path.withCString { destinationPath in
                renameatx_np(
                    AT_FDCWD, sourcePath, AT_FDCWD, destinationPath,
                    UInt32(RENAME_EXCL))
            }
        }
        guard result == 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
    }

    nonisolated private static func unlinkAttested(
        _ source: URL,
        identity: ValidatedAuthorityInboxConversationEnvelope.FileIdentity
    ) throws {
        guard LibraryAuthorityInboxOperationScanner.fileStillMatches(identity, at: source),
              unlink(source.path) == 0 else {
            throw InboxAdoptionError.sourceChanged
        }
    }

    nonisolated private static func syncDirectories(_ directories: [URL]) throws {
        for directory in directories {
            let descriptor = Darwin.open(
                directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard descriptor >= 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
            defer { Darwin.close(descriptor) }
            guard fsync(descriptor) == 0 else {
                throw POSIXError(.init(rawValue: errno) ?? .EIO)
            }
        }
    }

    nonisolated private static func writeDiagnostic(
        reason: String,
        sourceName: String,
        destination: URL
    ) throws {
        let boundedReason = String(reason.prefix(4_096))
        let value: [String: Any] = [
            "formatVersion": 1,
            "reason": boundedReason,
            "sourceName": String(sourceName.prefix(512)),
            "recordedAt": ISO8601DateFormatter().string(from: Date()),
        ]
        let bytes = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
        let descriptor = Darwin.open(
            destination.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
            mode_t(0o600))
        guard descriptor >= 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        var succeeded = false
        defer {
            Darwin.close(descriptor)
            if !succeeded { _ = unlink(destination.path) }
        }
        try bytes.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let count = Darwin.write(
                    descriptor, raw.baseAddress?.advanced(by: offset), raw.count - offset)
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
                offset += count
            }
        }
        guard fsync(descriptor) == 0, fchmod(descriptor, mode_t(0o400)) == 0 else {
            throw POSIXError(.init(rawValue: errno) ?? .EIO)
        }
        succeeded = true
    }

    private enum InboxAdoptionError: Error, LocalizedError, Equatable {
        case unsafeDirectory
        case unsafeReceipt
        case sourceChanged
        case adoptedCollision

        var errorDescription: String? {
            switch self {
            case .unsafeDirectory: "Authority inbox directory is unsafe."
            case .unsafeReceipt: "Existing authority inbox receipt is unsafe."
            case .sourceChanged: "Authority inbox source changed during adoption."
            case .adoptedCollision: "A different adopted envelope already owns this operation ID."
            }
        }
    }
}

/// Transitional source compatibility while the authority-sprint integration renames the new file
/// and its launch wiring together. There remains exactly one watcher and one adopter instance.
typealias BackgroundConversationInboxAdopter = AuthorityInboxAdopter
