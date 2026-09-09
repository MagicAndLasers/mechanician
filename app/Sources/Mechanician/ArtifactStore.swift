import SwiftUI
import AppKit

enum BackgroundArtifactAdoptionResult: Equatable {
    /// This call introduced or advanced the Artifact and its canonical Legacy JSON crossed the
    /// durable publication boundary.
    case published
    /// The byte-exact canonical Artifact already exists. This is the expected replay after a crash
    /// between Legacy publication and moving the immutable inbox envelope to `adopted/`.
    case alreadyPublished
    /// The UUID already names different Legacy bytes. An external producer may never replace them.
    case identityCollision
    /// The retained bytes are not the exact UTF-8 representation carried by the candidate.
    case invalidSource
    /// The canonical Artifact JSON could not cross its durable publication boundary.
    case persistenceFailed
}

private enum BackgroundArtifactFilePublication: Equatable {
    case created
    case updated
    case existingIdentical
    case collision
}

private struct BackgroundArtifactExistingRecord {
    let artifact: Artifact
    let producerTaskID: String?
    let identity: String
}

private enum BackgroundArtifactAdoptionError: Error {
    case sourceChanged
}

private enum ArtifactStorePersistenceError: LocalizedError {
    case repositoryUnavailable(String)

    var errorDescription: String? {
        switch self {
        case .repositoryUnavailable(let message): message
        }
    }
}

/// `Artifact` intentionally ignores ambientd's producer task identity, but Legacy JSON and the
/// SQLite adapter retain it as provenance. Encode the finite producer contract without teaching the
/// UI model that an ambient scheduler task is an intrinsic part of Artifact identity.
private struct BackgroundArtifactLegacyRecord: Encodable {
    let id: UUID
    let title: String
    let type: String
    let source: String
    let createdAt: Date
    let updatedAt: Date
    let revisions: Int
    let favorite: Bool
    let origin: String
    let taskId: String
    let conversationID: UUID?
    let conversationTitle: String
    let workspaceID: UUID?
    let cwd: String

    init(artifact: Artifact, producerTaskID: String) {
        id = artifact.uuid
        title = artifact.title
        type = artifact.type
        source = artifact.source
        createdAt = artifact.createdAt
        updatedAt = artifact.updatedAt
        revisions = artifact.revisions
        favorite = artifact.favorite
        origin = artifact.origin
        taskId = producerTaskID
        conversationID = artifact.conversationID
        conversationTitle = artifact.conversationTitle
        workspaceID = artifact.workspaceID
        cwd = artifact.cwd
    }
}

/// The durable, standalone artifact store — one `<uuid>.json` per artifact under
/// `<support>/artifacts/`, independent of any conversation. This is the single source of
/// truth for the Artifacts manager window and the only app writer for ambient artifacts that have
/// no interactive conversation.
///
/// Interactive turns write through from `AgentBridge` (`upsertFromAgent`); validated background
/// envelopes enter through `adoptBackgroundArtifact`. After A3b1 the app is the sole supported
/// Legacy writer: ambientd may read existing JSON only to preserve identity/revision lineage and
/// publishes immutable inbox operations instead of editing this directory. Full CRUD
/// (create/delete/rename/favorite/edit) runs through the mutation methods below.
@MainActor
final class ArtifactStore: ObservableObject {
    static let shared = ArtifactStore()

    @Published private(set) var artifacts: [Artifact] = []
    /// Cold-start loading is synchronous, so every mutation can rely on a complete disk snapshot.
    /// Keeping the readiness bit explicit prevents a future asynchronous refactor from silently
    /// reintroducing the move-before-load data loss that workspace assignment must avoid.
    @Published private(set) var isInitialLoadComplete = false
    /// A durable write/delete failed after bounded retries. Kept visible until every failed
    /// operation succeeds so disk-full and permissions failures cannot masquerade as saved state.
    @Published private(set) var persistenceError: String?

    private let io = DispatchQueue(label: "ai.mechanician.artifact-io", qos: .utility)
    private var watch: DispatchSourceFileSystemObject?
    private var reloadPending = false
    /// Bumped by every main-actor mutation. A reload captures it before reading disk and refuses to
    /// apply its (now stale) snapshot if a user mutation intervened — otherwise a dir-watcher reload
    /// racing a rename/edit visibly reverts the change for ~0.5 s before self-healing.
    private var mutationGeneration: UInt = 0
    private var nextOperationToken: UInt = 0
    private var latestOperationToken: [UUID: UInt] = [:]
    /// Optimistic UI snapshots stay authoritative while their corresponding disk operation is in
    /// flight or failed. A manual/directory reload must not replace them with older disk contents.
    private var pendingWriteSnapshots: [UUID: Artifact] = [:]
    private var pendingDeleteIDs = Set<UUID>()
    private var failedWrites: [UUID: Artifact] = [:]
    private var failedDeletes = Set<UUID>()
    private struct PendingOperationCapture {
        let capture: LibraryTransientOperationCaptureFactory.Capture
    }
    private var pendingWriteOperationCaptures: [UUID: PendingOperationCapture] = [:]
    private var pendingDeleteOperationCaptures: [UUID: PendingOperationCapture] = [:]
    private var lastPersistenceFailureDetail: String?
    private let appSupportBaseOverride: URL?
    private let selectedSQLiteAuthority: Bool
    private let authorityRepository: LibraryAuthorityRepository?
    private let authorityRepositoryOpenFailure: String?

    /// The support-directory override and watcher switch keep ownership/persistence tests isolated
    /// from the user's real artifact library. Production uses the defaults through `shared`.
    init(
        appSupportBaseOverride: URL? = nil,
        watchesDirectory: Bool = true,
        libraryAuthorityRepository: LibraryAuthorityRepository? = nil
    ) {
        self.appSupportBaseOverride = appSupportBaseOverride
        let processSelectedSQLite: Bool
        if case .sqlite = StorageAuthorityBootstrap.current.disposition {
            processSelectedSQLite = appSupportBaseOverride == nil
                && NSClassFromString("XCTestCase") == nil
        } else {
            processSelectedSQLite = false
        }
        selectedSQLiteAuthority = libraryAuthorityRepository != nil || processSelectedSQLite
        if let libraryAuthorityRepository {
            authorityRepository = libraryAuthorityRepository
            authorityRepositoryOpenFailure = nil
        } else if processSelectedSQLite {
            authorityRepository = LibraryAuthorityRepository.sharedIfActive
            authorityRepositoryOpenFailure = authorityRepository == nil
                ? "The SQLite authority repository was not available for the selected root."
                : nil
        } else {
            authorityRepository = nil
            authorityRepositoryOpenFailure = nil
        }
        if !selectedSQLiteAuthority { migrateIfNeeded() }
        loadInitialSnapshot()
        isInitialLoadComplete = true
        if watchesDirectory, !selectedSQLiteAuthority {
            startWatching()
        }
    }

    // MARK: paths

    /// Honors MECHANICIAN_SUPPORT_DIR so the dev build stays isolated from the stable app
    /// (both carry bundle id ai.mechanician.app). Mirrors AgentBridge.appSupportBase.
    private var supportBase: URL {
        let base = appSupportBaseOverride ?? MechanicianEnvironment.currentSupportRoot()
        return base
    }

    private var dir: URL {
        let d = supportBase.appendingPathComponent("artifacts", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    private func fileURL(_ id: UUID) -> URL { dir.appendingPathComponent("\(id.uuidString).json") }

    /// The one legacy Artifact encoding contract used by the live store and the SQLite shadow
    /// adapter. Keeping it shared prevents the shadow from silently normalizing dates or source
    /// text differently from the bytes that remain authoritative through Gate L.
    nonisolated static func persistedEncoder() -> JSONEncoder {
        let e = JSONEncoder()
        // Match ConversationStore's fractional ISO-8601 encoding. The same canonical Artifact is
        // written both standalone and nested in a conversation; dropping sub-second precision from
        // only one copy makes the two snapshots unequal after relaunch.
        e.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(isoFractional.string(from: date))
        }
        e.outputFormatting = [.sortedKeys, .prettyPrinted]
        return e
    }

    // ambientd (Node) stamps dates with `new Date().toISOString()` — ALWAYS fractional seconds
    // (…56.789Z). Foundation's `.iso8601` strategy uses .withInternetDateTime only on the macOS
    // 13/14 floor and REJECTS fractional seconds, which would silently drop every ambient
    // artifact. Decode both forms.
    nonisolated(unsafe) private static let isoFractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f
    }()
    nonisolated(unsafe) private static let isoPlain: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime]; return f
    }()
    /// The instant as the durable record can actually represent it.
    ///
    /// `isoFractional` keeps MILLISECONDS and ROUNDS, so a `Date()` of …341.857977 is written as
    /// …341.858 and reads back LARGER than the value it came from. Comparing a timestamp that has
    /// been through the file against one that has not is therefore not an ordering test at all
    /// within any single millisecond: the predecessor can appear up to half a millisecond newer
    /// than a successor that genuinely came after it.
    ///
    /// That is not hypothetical. It is FR-234: a background revision published in the same
    /// millisecond as a user rename was refused as `identityCollision`, because the rename's
    /// rounded-up `updatedAt` on disk sorted after the successor's exact one in memory. Round-trip
    /// through the same formatter rather than rounding by hand, so this cannot drift from whatever
    /// the encoder actually does.
    nonisolated static func persistedInstant(_ date: Date) -> Date {
        isoFractional.date(from: isoFractional.string(from: date)) ?? date
    }

    nonisolated static func persistedDecoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .custom { dec in
            let s = try dec.singleValueContainer().decode(String.self)
            if let date = isoFractional.date(from: s) ?? isoPlain.date(from: s) { return date }
            throw DecodingError.dataCorrupted(.init(codingPath: dec.codingPath,
                                                    debugDescription: "unrecognized ISO8601 date: \(s)"))
        }
        return d
    }

    // MARK: load

    /// Load the complete cold-start snapshot before construction returns. Workspace reassignment can
    /// be triggered immediately after launch (before an artifacts window appears); an asynchronous
    /// initial read would see an empty array and leave every on-disk artifact behind.
    private func loadInitialSnapshot() {
        if selectedSQLiteAuthority {
            guard let authorityRepository else {
                persistenceError = authorityRepositoryOpenFailure
                    ?? "The SQLite authority repository is unavailable."
                return
            }
            do {
                artifacts = Self.sorted(try authorityRepository.artifacts())
                for artifact in artifacts {
                    SpotlightIndex.indexArtifact(
                        id: artifact.uuid,
                        title: artifact.title,
                        type: artifact.type,
                        cwd: artifact.cwd,
                        conversationTitle: artifact.conversationTitle)
                }
            } catch {
                persistenceError = Self.artifactLibraryOpenFailure(error)
            }
            return
        }
        artifacts = Self.sorted(Self.artifactsOnDisk(in: dir))
        for artifact in artifacts {
            SpotlightIndex.indexArtifact(
                id: artifact.uuid,
                title: artifact.title,
                type: artifact.type,
                cwd: artifact.cwd,
                conversationTitle: artifact.conversationTitle)
        }
    }

    nonisolated private static func artifactsOnDisk(in dir: URL) -> [Artifact] {
        let decoder = persistedDecoder()
        let files = (try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil)) ?? []
        var artifacts: [Artifact] = []
        for file in files where file.lastPathComponent != ".migrated-v1" {
            if file.pathExtension == "json",
               let data = Self.safelyReadRegularFile(file),
               let artifact = try? decoder.decode(Artifact.self, from: data) {
                artifacts.append(artifact)
            }
        }
        return artifacts
    }

    /// Read a compatibility sidecar without following symlinks or accepting an inode swap. The
    /// active SQLite product does not use this path; isolated legacy-store tests still exercise it.
    nonisolated private static func safelyReadRegularFile(_ url: URL) -> Data? {
        var pathMetadata = stat()
        guard lstat(url.path, &pathMetadata) == 0 else { return nil }
        guard pathMetadata.st_mode & S_IFMT == S_IFREG,
              pathMetadata.st_size >= 0,
              pathMetadata.st_size <= off_t(ArtifactMediaSourceScanner.maximumArtifactJSONBytes)
        else { return nil }
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { return nil }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        var openedMetadata = stat()
        guard fstat(descriptor, &openedMetadata) == 0,
              openedMetadata.st_mode & S_IFMT == S_IFREG,
              openedMetadata.st_dev == pathMetadata.st_dev,
              openedMetadata.st_ino == pathMetadata.st_ino,
              openedMetadata.st_size >= 0,
              openedMetadata.st_size <= off_t(ArtifactMediaSourceScanner.maximumArtifactJSONBytes)
        else {
            return nil
        }
        var data = Data()
        data.reserveCapacity(Int(openedMetadata.st_size))
        while data.count <= ArtifactMediaSourceScanner.maximumArtifactJSONBytes {
            let remaining = ArtifactMediaSourceScanner.maximumArtifactJSONBytes + 1 - data.count
            let chunk: Data
            do {
                guard let next = try handle.read(
                    upToCount: min(1_024 * 1_024, remaining)) else { break }
                chunk = next
            } catch {
                return nil
            }
            guard !chunk.isEmpty else { break }
            data.append(chunk)
        }
        var finalMetadata = stat()
        guard data.count <= ArtifactMediaSourceScanner.maximumArtifactJSONBytes,
              data.count == Int(openedMetadata.st_size),
              fstat(descriptor, &finalMetadata) == 0,
              metadataFingerprint(finalMetadata) == metadataFingerprint(openedMetadata) else {
            return nil
        }
        return data
    }

    nonisolated private static func metadataFingerprint(_ value: stat) -> String {
        "dev:\(value.st_dev);ino:\(value.st_ino);mode:\(value.st_mode);bytes:\(value.st_size);"
            + "mtime:\(value.st_mtimespec.tv_sec).\(value.st_mtimespec.tv_nsec);"
            + "ctime:\(value.st_ctimespec.tv_sec).\(value.st_ctimespec.tv_nsec)"
    }

    func load() {
        if selectedSQLiteAuthority {
            guard let authorityRepository else {
                persistenceError = authorityRepositoryOpenFailure
                    ?? "The SQLite authority repository is unavailable."
                return
            }
            let capturedGeneration = mutationGeneration
            io.async { [weak self] in
                let result = Result { try authorityRepository.artifacts() }
                Task { @MainActor [weak self] in
                    guard let self, self.mutationGeneration == capturedGeneration else { return }
                    switch result {
                    case .success(let values):
                        self.artifacts = Self.sorted(values)
                    case .failure(let error):
                        self.persistenceError =
                            Self.artifactLibraryOpenFailure(error)
                    }
                }
            }
            return
        }
        // Read on the SAME serial io queue as writes/deletes, so a reload can never observe
        // disk state older than an already-enqueued persist (which would clobber an in-memory
        // mutation). Assign the result back on the main actor.
        let dir = self.dir
        let capturedGeneration = mutationGeneration
        let pendingWrites = pendingWriteSnapshots
        let pendingDeletes = pendingDeleteIDs
        io.async { [weak self] in
            var list = Self.artifactsOnDisk(in: dir)
            list.removeAll { pendingDeletes.contains($0.uuid) }
            for artifact in pendingWrites.values {
                if let index = list.firstIndex(where: { $0.uuid == artifact.uuid }) {
                    list[index] = artifact
                } else {
                    list.append(artifact)
                }
            }
            let sorted = Self.sorted(list)
            Task { @MainActor in
                guard let self else { return }
                // A user mutation landed after this read was enqueued: its snapshot is stale and
                // would clobber the in-memory change. Skip — the mutation's own persist re-fires the
                // watcher, so a fresh reload reconciles both changes.
                guard self.mutationGeneration == capturedGeneration else { return }
                // Index only artifacts that are new or changed since the last snapshot — an in-app
                // edit already indexed via persist() (and updated updatedAt before this reload
                // fires), so this only picks up artifacts written OUTSIDE the app (restore/repair)
                // rather than re-indexing the whole library on every dir-watcher fire.
                let prev = Dictionary(self.artifacts.map { ($0.uuid, $0) },
                                      uniquingKeysWith: { a, _ in a })
                self.artifacts = sorted
                for a in sorted where prev[a.uuid] != a {
                    SpotlightIndex.indexArtifact(id: a.uuid, title: a.title, type: a.type,
                                                 cwd: a.cwd, conversationTitle: a.conversationTitle)
                }
            }
        }
    }

    /// Favorites first, then most-recently-updated.
    nonisolated private static func sorted(_ list: [Artifact]) -> [Artifact] {
        list.sorted { a, b in
            if a.favorite != b.favorite { return a.favorite && !b.favorite }
            return a.updatedAt > b.updatedAt
        }
    }

    // MARK: writes (persist off the main thread on a serial queue, ordered vs deletes)

    private func persist(
        _ a: Artifact,
        operationCapture: PendingOperationCapture? = nil,
        backgroundProducerTaskID: String? = nil,
        completion: ((Bool) -> Void)? = nil
    ) {
        mutationGeneration &+= 1   // invalidate any in-flight reload that would clobber this write
        let token = beginDiskOperation(for: a.uuid)
        pendingWriteSnapshots[a.uuid] = a
        pendingDeleteIDs.remove(a.uuid)
        pendingDeleteOperationCaptures[a.uuid] = nil
        pendingWriteOperationCaptures[a.uuid] = operationCapture
        if selectedSQLiteAuthority {
            guard let authorityRepository else {
                finishWrite(
                    a,
                    token: token,
                    failure: ArtifactStorePersistenceError.repositoryUnavailable(
                        authorityRepositoryOpenFailure
                            ?? "The SQLite authority repository is unavailable."),
                    completion: completion)
                return
            }
            io.async { [weak self] in
                let failure = Self.retryingDiskOperation {
                    if let capture = operationCapture?.capture {
                        _ = try authorityRepository.commit(
                            artifact: a, adopting: capture)
                    } else {
                        _ = try authorityRepository.commit(artifact: a)
                    }
                }
                DispatchQueue.main.async { [weak self] in
                    MainActor.assumeIsolated {
                        self?.finishWrite(
                            a,
                            token: token,
                            failure: failure,
                            completion: completion)
                    }
                }
            }
            return
        }
        let url = fileURL(a.uuid)
        let enc = Self.persistedEncoder()
        io.async { [weak self] in
            let failure = Self.retryingDiskOperation {
                let data: Data
                if let backgroundProducerTaskID {
                    data = try enc.encode(BackgroundArtifactLegacyRecord(
                        artifact: a,
                        producerTaskID: backgroundProducerTaskID))
                    // This corrective write is part of the inbox acknowledgement boundary, not an
                    // ordinary UI save. Publish through the same file+directory fsync discipline
                    // as the initial adoption before allowing the receipt to move to adopted/.
                    guard let existing = try Self.readBackgroundArtifact(at: url) else {
                        throw BackgroundArtifactAdoptionError.sourceChanged
                    }
                    try Self.replaceBackgroundArtifact(
                        data,
                        at: url,
                        replacingIdentity: existing.identity)
                } else {
                    data = try enc.encode(a)
                    try data.write(to: url, options: .atomic)
                }
            }
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated {
                    self?.finishWrite(
                        a,
                        token: token,
                        failure: failure,
                        completion: completion)
                }
            }
        }
    }

    /// Create-or-next-revision Legacy adoption for one fully validated immutable background
    /// Artifact envelope.
    ///
    /// General `upsertFromAgent` replaces without proving a predecessor and is therefore unsafe at
    /// this boundary. This seam publishes on the same serial writer as ordinary Artifact mutations.
    /// A new UUID is create-only; an existing ambient UUID advances only by one revision after its
    /// immutable lineage is proved from the current raw Legacy file. Completion follows canonical
    /// JSON and parent-directory durability. `retainedSourceBytes` is compared byte-for-byte before
    /// encoding so a validation/mapping bug cannot silently normalize producer-authored text.
    func adoptBackgroundArtifact(
        _ candidate: Artifact,
        producerTaskID: String,
        retainedSourceBytes: Data,
        authorityCapture: LibraryTransientOperationCaptureFactory.Capture? = nil,
        completion: @escaping (BackgroundArtifactAdoptionResult) -> Void
    ) {
        guard !producerTaskID.isEmpty,
              Data(candidate.source.utf8) == retainedSourceBytes else {
            completion(.invalidSource)
            return
        }
        if selectedSQLiteAuthority {
            guard authorityRepository != nil, authorityCapture != nil else {
                completion(.persistenceFailed)
                return
            }
            // Filled by the SQLite-authority adoption branch below; never fall through to Legacy
            // JSON when a marker selected the database.
            adoptBackgroundArtifactUsingSQLite(
                candidate,
                producerTaskID: producerTaskID,
                authorityCapture: authorityCapture!,
                completion: completion)
            return
        }
        let known = artifacts.filter { $0.uuid == candidate.uuid }
        let destination = fileURL(candidate.uuid)
        // A known Artifact can have arrived from a restored/non-canonical filename. Without a
        // durable source map, publishing another canonical file would create two Legacy authorities.
        // Refuse that shape conservatively instead of turning replay into duplication.
        if !known.isEmpty, !FileManager.default.fileExists(atPath: destination.path) {
            completion(.identityCollision)
            return
        }

        let writer = io
        writer.async { [weak self] in
            var publication: BackgroundArtifactFilePublication?
            var acceptedPredecessor: Artifact?
            var publishedArtifact: Artifact?
            let failure = Self.retryingDiskOperation {
                publication = try Self.publishBackgroundArtifact(
                    candidate: candidate,
                    producerTaskID: producerTaskID,
                    to: destination,
                    allowCreate: known.isEmpty,
                    acceptedPredecessor: &acceptedPredecessor,
                    publishedArtifact: &publishedArtifact)
            }
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated {
                    guard let self else {
                        completion(.persistenceFailed)
                        return
                    }
                    if failure != nil {
                        completion(.persistenceFailed)
                        return
                    }
                    guard publication != .collision else {
                        completion(.identityCollision)
                        return
                    }
                    guard let publishedArtifact else {
                        completion(.persistenceFailed)
                        return
                    }
                    let current = self.artifacts.filter { $0.uuid == candidate.uuid }
                    let adoptionResult: BackgroundArtifactAdoptionResult =
                        publication == .existingIdentical ? .alreadyPublished : .published
                    let finish: (BackgroundArtifactAdoptionResult) -> Void = completion
                    let install: (Artifact) -> Void = { artifact in
                        self.mutationGeneration &+= 1
                        self.artifacts.removeAll { $0.uuid == candidate.uuid }
                        self.artifacts = Self.sorted(self.artifacts + [artifact])
                        SpotlightIndex.indexArtifact(
                            id: artifact.uuid,
                            title: artifact.title,
                            type: artifact.type,
                            cwd: artifact.cwd,
                            conversationTitle: artifact.conversationTitle)
                    }

                    guard let predecessor = acceptedPredecessor else {
                        // A newly created identity did not exist in the UI before this commit.
                        install(publishedArtifact)
                        finish(adoptionResult)
                        return
                    }

                    if current.isEmpty {
                        // A user delete queued behind the adoption commit is a legitimate later
                        // operation. Never resurrect it in memory; acknowledge only after its
                        // Legacy unlink has itself reached the durable writer.
                        self.afterPendingPersistence(of: [candidate.uuid]) { succeeded in
                            finish(succeeded ? adoptionResult : .persistenceFailed)
                        }
                        return
                    }
                    guard current.count == 1 else {
                        finish(.identityCollision)
                        return
                    }
                    let live = current[0]
                    if Self.sameCanonicalArtifact(live, predecessor) {
                        install(publishedArtifact)
                        finish(adoptionResult)
                        return
                    }

                    if Self.sameBackgroundProducerState(live, predecessor) {
                        // An organization-only mutation was queued after adoption. Its stale full
                        // snapshot may overwrite the just-published producer revision on `io`.
                        // Queue one final rebased record behind it and do not release the inbox
                        // receipt until that final record is durable.
                        var rebased = publishedArtifact
                        rebased.title = live.title
                        rebased.favorite = live.favorite
                        rebased.workspaceID = live.workspaceID
                        rebased.cwd = live.cwd
                        rebased.updatedAt = max(live.updatedAt, publishedArtifact.updatedAt)
                        install(rebased)
                        self.persist(
                            rebased,
                            backgroundProducerTaskID: producerTaskID
                        ) { succeeded in
                            finish(succeeded ? adoptionResult : .persistenceFailed)
                        }
                        return
                    }

                    // A simultaneous source/type/provenance edit is a real content conflict. Put
                    // the user's current value back behind every queued stale write, preserving
                    // task provenance, before quarantining the producer envelope. This prevents an
                    // unreceipted background revision from surviving a crash window.
                    self.persist(
                        live,
                        backgroundProducerTaskID: producerTaskID
                    ) { succeeded in
                        finish(succeeded ? .identityCollision : .persistenceFailed)
                    }
                }
            }
        }
    }

    private func adoptBackgroundArtifactUsingSQLite(
        _ candidate: Artifact,
        producerTaskID: String,
        authorityCapture: LibraryTransientOperationCaptureFactory.Capture,
        completion: @escaping (BackgroundArtifactAdoptionResult) -> Void
    ) {
        guard let authorityRepository else {
            completion(.persistenceFailed)
            return
        }
        let initial = artifacts.filter { $0.uuid == candidate.uuid }
        guard initial.count <= 1 else {
            completion(.identityCollision)
            return
        }
        io.async { [weak self] in
            var adoption: LibraryAuthorityArtifactAdoptionResult?
            let failure = Self.retryingDiskOperation {
                adoption = try authorityRepository.adoptBackgroundArtifact(
                    candidate: candidate,
                    producerTaskID: producerTaskID,
                    capture: authorityCapture)
            }
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, failure == nil, let adoption else {
                        completion(.persistenceFailed)
                        return
                    }
                    switch adoption.disposition {
                    case .identityCollision:
                        completion(.identityCollision)
                    case .alreadyApplied:
                        completion(.alreadyPublished)
                    case .created:
                        let current = self.artifacts.filter { $0.uuid == candidate.uuid }
                        let initialArtifact = initial.first
                        if initialArtifact == nil
                            || (current.count == 1
                                && initialArtifact.map {
                                    Self.sameCanonicalArtifact(current[0], $0)
                                } == true) {
                            self.mutationGeneration &+= 1
                            self.artifacts.removeAll { $0.uuid == candidate.uuid }
                            self.artifacts = Self.sorted(self.artifacts + [adoption.artifact])
                            SpotlightIndex.indexArtifact(
                                id: adoption.artifact.uuid,
                                title: adoption.artifact.title,
                                type: adoption.artifact.type,
                                cwd: adoption.artifact.cwd,
                                conversationTitle: adoption.artifact.conversationTitle)
                            completion(.published)
                        } else {
                            // A later main-actor edit/delete already queued behind the adoption on
                            // this same writer. Preserve its optimistic state and acknowledge only
                            // after that later SQLite transaction reaches durability.
                            self.afterPendingPersistence(of: [candidate.uuid]) { succeeded in
                                completion(succeeded ? .published : .persistenceFailed)
                            }
                        }
                    }
                }
            }
        }
    }

    /// Decide create/replay/next-revision from the exact file currently occupying the canonical
    /// Legacy name. This entire decision and its publication run on `io`, serialized with every app
    /// Artifact write.
    nonisolated private static func publishBackgroundArtifact(
        candidate: Artifact,
        producerTaskID: String,
        to destination: URL,
        allowCreate: Bool,
        acceptedPredecessor: inout Artifact?,
        publishedArtifact: inout Artifact?
    ) throws -> BackgroundArtifactFilePublication {
        guard let existing = try readBackgroundArtifact(at: destination) else {
            guard allowCreate else { return .collision }
            let bytes = try persistedEncoder().encode(BackgroundArtifactLegacyRecord(
                artifact: candidate,
                producerTaskID: producerTaskID))
            publishedArtifact = candidate
            return try publishBackgroundArtifactCreateOnly(bytes, to: destination)
        }
        if acceptedPredecessor == nil {
            acceptedPredecessor = existing.artifact
        }
        let taskIdentityMatches = existing.producerTaskID == nil
            || existing.producerTaskID == producerTaskID
        if taskIdentityMatches,
           sameBackgroundProducerRevision(existing.artifact, candidate) {
            publishedArtifact = existing.artifact
            try syncBackgroundArtifactDirectory(destination.deletingLastPathComponent())
            return .existingIdentical
        }

        let current = existing.artifact
        // Both timestamp comparisons are made at the precision the file preserves. `current` has
        // been through the encoder and `candidate` has not, so a raw comparison is not an ordering
        // test within a millisecond, and refusing on it rejected a legitimate successor. See
        // `persistedInstant`.
        guard current.origin == "ambient",
              candidate.origin == "ambient",
              current.uuid == candidate.uuid,
              persistedInstant(current.createdAt) == persistedInstant(candidate.createdAt),
              current.revisions < Int.max,
              candidate.revisions == current.revisions + 1,
              persistedInstant(candidate.updatedAt) >= persistedInstant(current.updatedAt),
              taskIdentityMatches else {
            return .collision
        }
        // Title and filing/favorite fields are user-owned organization. An ambient content
        // successor can advance type/source/provenance, but it must not snap the Artifact back to
        // the producer's stale view after a rename, favorite change, or Workspace move.
        var normalized = candidate
        normalized.title = current.title
        normalized.favorite = current.favorite
        normalized.workspaceID = current.workspaceID
        normalized.cwd = current.cwd
        let bytes = try persistedEncoder().encode(BackgroundArtifactLegacyRecord(
            artifact: normalized,
            producerTaskID: producerTaskID))
        publishedArtifact = normalized
        try replaceBackgroundArtifact(
            bytes,
            at: destination,
            replacingIdentity: existing.identity)
        return .updated
    }

    /// Compare the producer-owned portion of one Artifact revision. Title, favorite, Workspace and
    /// cwd are intentionally excluded: a crash replay after user organization must acknowledge the
    /// already-published content revision without reversing that newer user choice. A later
    /// user rename may advance `updatedAt`, so nondecreasing current time is sufficient when every
    /// content/provenance field and the revision number agree.
    nonisolated private static func sameBackgroundProducerRevision(
        _ current: Artifact,
        _ candidate: Artifact
    ) -> Bool {
        // `current` came off disk and `candidate` did not, so both timestamps are compared at the
        // precision the file preserves. See `persistedInstant`.
        current.uuid == candidate.uuid
            && current.type == candidate.type
            && current.source == candidate.source
            && persistedInstant(current.createdAt) == persistedInstant(candidate.createdAt)
            && persistedInstant(current.updatedAt) >= persistedInstant(candidate.updatedAt)
            && current.revisions == candidate.revisions
            && current.origin == candidate.origin
            && current.conversationID == candidate.conversationID
            && current.conversationTitle == candidate.conversationTitle
    }

    /// Compare only the producer-owned portion of a pre-adoption value. Differences in title,
    /// favorite, Workspace, cwd, or updatedAt are user organization and can be safely rebased over
    /// a newly published producer revision. Any content/provenance difference is a true conflict.
    nonisolated private static func sameBackgroundProducerState(
        _ current: Artifact,
        _ predecessor: Artifact
    ) -> Bool {
        current.uuid == predecessor.uuid
            && current.type == predecessor.type
            && current.source == predecessor.source
            && current.createdAt == predecessor.createdAt
            && current.revisions == predecessor.revisions
            && current.origin == predecessor.origin
            && current.conversationID == predecessor.conversationID
            && current.conversationTitle == predecessor.conversationTitle
    }

    /// Persisted ISO-8601 dates have millisecond precision while a just-mutated resident Artifact
    /// can retain finer `Date` precision. Compare their canonical Legacy encodings when deciding
    /// whether main-actor state is still the predecessor that the serialized writer proved.
    nonisolated private static func sameCanonicalArtifact(
        _ lhs: Artifact,
        _ rhs: Artifact
    ) -> Bool {
        if lhs == rhs { return true }
        guard let left = try? persistedEncoder().encode(lhs),
              let right = try? persistedEncoder().encode(rhs) else { return false }
        return left == right
    }

    /// Atomically publish already-validated Artifact bytes without replacing an existing Legacy
    /// source. `RENAME_EXCL` is the create point; parent-directory fsync is the acknowledgement
    /// point. An exact destination is an idempotent replay, while all other existing bytes collide.
    nonisolated private static func publishBackgroundArtifactCreateOnly(
        _ bytes: Data,
        to destination: URL
    ) throws -> BackgroundArtifactFilePublication {
        let directory = destination.deletingLastPathComponent()
        let temporary = directory.appendingPathComponent(
            ".\(destination.lastPathComponent).adoption-\(UUID().uuidString).tmp")
        let descriptor = open(
            temporary.path,
            O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
            mode_t(0o600))
        guard descriptor >= 0 else {
            throw POSIXError(.init(rawValue: errno) ?? .EIO)
        }
        var temporaryExists = true
        defer {
            _ = close(descriptor)
            if temporaryExists { _ = unlink(temporary.path) }
        }
        try bytes.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let count = write(
                    descriptor,
                    raw.baseAddress?.advanced(by: offset),
                    raw.count - offset)
                if count < 0, errno == EINTR { continue }
                guard count > 0 else {
                    throw POSIXError(.init(rawValue: errno) ?? .EIO)
                }
                offset += count
            }
        }
        guard fsync(descriptor) == 0 else {
            throw POSIXError(.init(rawValue: errno) ?? .EIO)
        }

        let renameResult = temporary.path.withCString { temporaryPath in
            destination.path.withCString { destinationPath in
                renameatx_np(
                    AT_FDCWD,
                    temporaryPath,
                    AT_FDCWD,
                    destinationPath,
                    UInt32(RENAME_EXCL))
            }
        }
        if renameResult == 0 {
            temporaryExists = false
            try syncBackgroundArtifactDirectory(directory)
            return .created
        }
        let renameErrno = errno
        guard renameErrno == EEXIST else {
            throw POSIXError(.init(rawValue: renameErrno) ?? .EIO)
        }
        let identical = try backgroundArtifactBytes(at: destination, equal: bytes)
        if identical { try syncBackgroundArtifactDirectory(directory) }
        return identical ? .existingIdentical : .collision
    }

    /// Descriptor-based decode refuses links/non-regular sources and binds Artifact metadata plus
    /// the raw producer task identity to one stable inode across the read.
    nonisolated private static func readBackgroundArtifact(
        at url: URL
    ) throws -> BackgroundArtifactExistingRecord? {
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else {
            if errno == ENOENT { return nil }
            throw POSIXError(.init(rawValue: errno) ?? .EIO)
        }
        defer { _ = close(descriptor) }
        var before = stat()
        guard fstat(descriptor, &before) == 0,
              before.st_mode & S_IFMT == S_IFREG,
              before.st_uid == geteuid(),
              before.st_nlink == 1,
              before.st_size >= 0,
              before.st_size <= ArtifactMediaSourceScanner.maximumArtifactJSONBytes else {
            throw BackgroundArtifactAdoptionError.sourceChanged
        }
        var bytes = Data(count: Int(before.st_size))
        let completed = bytes.withUnsafeMutableBytes { raw -> Bool in
            var offset = 0
            while offset < raw.count {
                let count = read(
                    descriptor,
                    raw.baseAddress?.advanced(by: offset),
                    raw.count - offset)
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { return false }
                offset += count
            }
            return true
        }
        var after = stat()
        guard completed,
              fstat(descriptor, &after) == 0,
              metadataFingerprint(before) == metadataFingerprint(after),
              let artifact = try? persistedDecoder().decode(Artifact.self, from: bytes),
              let raw = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any] else {
            throw BackgroundArtifactAdoptionError.sourceChanged
        }
        return BackgroundArtifactExistingRecord(
            artifact: artifact,
            producerTaskID: raw["taskId"] as? String,
            identity: metadataFingerprint(before))
    }

    /// Byte-exact replay proof used when a create-only rename discovers a destination published by
    /// an earlier retry attempt.
    nonisolated private static func backgroundArtifactBytes(
        at url: URL,
        equal expected: Data
    ) throws -> Bool {
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else {
            throw POSIXError(.init(rawValue: errno) ?? .EIO)
        }
        defer { _ = close(descriptor) }
        var before = stat()
        guard fstat(descriptor, &before) == 0,
              before.st_mode & S_IFMT == S_IFREG,
              before.st_uid == geteuid(),
              before.st_nlink == 1,
              before.st_size == expected.count else {
            return false
        }
        var actual = Data(count: expected.count)
        let completed = actual.withUnsafeMutableBytes { raw -> Bool in
            var offset = 0
            while offset < raw.count {
                let count = read(
                    descriptor,
                    raw.baseAddress?.advanced(by: offset),
                    raw.count - offset)
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { return false }
                offset += count
            }
            return true
        }
        var after = stat()
        return completed
            && fstat(descriptor, &after) == 0
            && metadataFingerprint(before) == metadataFingerprint(after)
            && actual == expected
    }

    /// Publish a proved successor by atomic replacement. The final identity check closes races with
    /// other app work; `io` is the only supported Legacy writer after A3b activation.
    nonisolated private static func replaceBackgroundArtifact(
        _ bytes: Data,
        at destination: URL,
        replacingIdentity: String
    ) throws {
        let directory = destination.deletingLastPathComponent()
        let temporary = directory.appendingPathComponent(
            ".\(destination.lastPathComponent).update-\(UUID().uuidString).tmp")
        let descriptor = open(
            temporary.path,
            O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
            mode_t(0o600))
        guard descriptor >= 0 else {
            throw POSIXError(.init(rawValue: errno) ?? .EIO)
        }
        var temporaryExists = true
        defer {
            _ = close(descriptor)
            if temporaryExists { _ = unlink(temporary.path) }
        }
        try bytes.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let count = write(
                    descriptor,
                    raw.baseAddress?.advanced(by: offset),
                    raw.count - offset)
                if count < 0, errno == EINTR { continue }
                guard count > 0 else {
                    throw POSIXError(.init(rawValue: errno) ?? .EIO)
                }
                offset += count
            }
        }
        guard fsync(descriptor) == 0 else {
            throw POSIXError(.init(rawValue: errno) ?? .EIO)
        }
        var current = stat()
        guard lstat(destination.path, &current) == 0,
              current.st_mode & S_IFMT == S_IFREG,
              current.st_nlink == 1,
              metadataFingerprint(current) == replacingIdentity else {
            throw BackgroundArtifactAdoptionError.sourceChanged
        }
        guard Darwin.rename(temporary.path, destination.path) == 0 else {
            throw POSIXError(.init(rawValue: errno) ?? .EIO)
        }
        temporaryExists = false
        try syncBackgroundArtifactDirectory(directory)
    }

    nonisolated private static func syncBackgroundArtifactDirectory(_ directory: URL) throws {
        let descriptor = open(
            directory.path,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else {
            throw POSIXError(.init(rawValue: errno) ?? .EIO)
        }
        defer { _ = close(descriptor) }
        guard fsync(descriptor) == 0 else {
            throw POSIXError(.init(rawValue: errno) ?? .EIO)
        }
    }

    private func removeFile(
        _ id: UUID,
        operationCapture: PendingOperationCapture? = nil
    ) {
        mutationGeneration &+= 1   // invalidate any in-flight reload that would resurrect this file
        let token = beginDiskOperation(for: id)
        pendingWriteSnapshots[id] = nil
        pendingDeleteIDs.insert(id)
        pendingWriteOperationCaptures[id] = nil
        if let operationCapture {
            pendingDeleteOperationCaptures[id] = operationCapture
        }
        if selectedSQLiteAuthority {
            guard let authorityRepository else {
                finishDelete(
                    id,
                    token: token,
                    failure: ArtifactStorePersistenceError.repositoryUnavailable(
                        authorityRepositoryOpenFailure
                            ?? "The SQLite authority repository is unavailable."))
                return
            }
            io.async { [weak self] in
                let failure = Self.retryingDiskOperation {
                    if let capture = operationCapture?.capture {
                        _ = try authorityRepository.deleteArtifact(id: id, capture: capture)
                    } else {
                        _ = try authorityRepository.deleteArtifact(id: id)
                    }
                }
                DispatchQueue.main.async { [weak self] in
                    MainActor.assumeIsolated {
                        self?.finishDelete(id, token: token, failure: failure)
                    }
                }
            }
            return
        }
        let url = fileURL(id)
        io.async { [weak self] in
            let failure = Self.retryingDiskOperation {
                if FileManager.default.fileExists(atPath: url.path) {
                    try FileManager.default.removeItem(at: url)
                }
            }
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated {
                    self?.finishDelete(id, token: token, failure: failure)
                }
            }
        }
    }

    private func beginDiskOperation(for id: UUID) -> UInt {
        nextOperationToken &+= 1
        latestOperationToken[id] = nextOperationToken
        return nextOperationToken
    }

    /// Retry short-lived filesystem failures without blocking the main actor. Persistent failures
    /// remain retryable from the UI and keep an explicit error visible.
    nonisolated private static func retryingDiskOperation(_ operation: () throws -> Void) -> Error? {
        var lastError: Error?
        for attempt in 0..<3 {
            do {
                try operation()
                return nil
            } catch {
                lastError = error
                if attempt < 2 { Thread.sleep(forTimeInterval: 0.08 * Double(attempt + 1)) }
            }
        }
        return lastError
    }

    private func finishWrite(
        _ artifact: Artifact,
        token: UInt,
        failure: Error?,
        completion: ((Bool) -> Void)? = nil
    ) {
        if latestOperationToken[artifact.uuid] == token {
            if let failure {
                failedWrites[artifact.uuid] = artifact
                failedDeletes.remove(artifact.uuid)
                lastPersistenceFailureDetail = failure.localizedDescription
                // Keep the engine's words in the log, not in the banner. See the note in
                // `ConversationStore.refreshPersistenceError`.
                NSLog(
                    "[persistence] artifact %@ could not be saved: %@",
                    artifact.uuid.uuidString, failure.localizedDescription)
            } else {
                pendingWriteSnapshots[artifact.uuid] = nil
                failedWrites.removeValue(forKey: artifact.uuid)
                failedDeletes.remove(artifact.uuid)
                // Search follows the durable authority commit. A failed or superseded optimistic
                // mutation must never become more visible than the database/file that owns it.
                SpotlightIndex.indexArtifact(
                    id: artifact.uuid,
                    title: artifact.title,
                    type: artifact.type,
                    cwd: artifact.cwd,
                    conversationTitle: artifact.conversationTitle)
                pendingWriteOperationCaptures.removeValue(forKey: artifact.uuid)
            }
            refreshPersistenceError()
        }
        // A later user mutation can supersede this bookkeeping token after the bytes have already
        // committed. Adoption still needs the result of this exact final rebase write so it can
        // decide whether releasing the producer receipt is safe.
        completion?(failure == nil)
    }

    private func finishDelete(_ id: UUID, token: UInt, failure: Error?) {
        guard latestOperationToken[id] == token else { return }
        if let failure {
            failedDeletes.insert(id)
            failedWrites.removeValue(forKey: id)
            lastPersistenceFailureDetail = failure.localizedDescription
        } else {
            pendingDeleteIDs.remove(id)
            failedDeletes.remove(id)
            failedWrites.removeValue(forKey: id)
            SpotlightIndex.deindexArtifact(id)
            pendingDeleteOperationCaptures.removeValue(forKey: id)
        }
        refreshPersistenceError()
    }

    /// The engine's words go to the log; the person is told what happened to their work. See the
    /// note in `ConversationStore.refreshPersistenceError`.
    static func artifactLibraryOpenFailure(_ error: Error) -> String {
        NSLog("[persistence] artifact library could not be loaded: %@", error.localizedDescription)
        return "Mechanician couldn’t open your artifacts. Nothing on disk was changed. Quit and "
            + "reopen Mechanician to try again."
    }

    private func refreshPersistenceError() {
        let count = failedWrites.count + failedDeletes.count
        guard count > 0 else {
            persistenceError = nil
            lastPersistenceFailureDetail = nil
            return
        }
        // No error detail in the sentence: see the note in `ConversationStore.refreshPersistenceError`.
        let subject = count == 1 ? "an artifact" : "\(count) artifact changes"
        persistenceError =
            "Mechanician couldn’t save \(subject). The work is still here but not yet on disk, "
            + "so don’t quit until this clears."
    }

    /// Re-enqueue the exact snapshots/deletions that failed. Newer mutations supersede an older
    /// retry through the per-artifact operation token.
    func retryFailedSaves() {
        let writes = Array(failedWrites.values)
        let deletes = Array(failedDeletes)
        for artifact in writes {
            persist(
                artifact,
                operationCapture: pendingWriteOperationCaptures[artifact.uuid])
        }
        for id in deletes {
            removeFile(id, operationCapture: pendingDeleteOperationCaptures[id])
        }
    }

    /// Drain all queued artifact writes/deletes before process termination. This is intentionally
    /// synchronous and called only from the main-thread application termination path.
    func flushSaves() {
        io.sync {}
    }

#if DEBUG
    /// Deterministically hold the serial Legacy writer so focused tests can place adoption and a
    /// user mutation on opposite sides of the same publication boundary.
    func blockPersistenceForTesting(
        started: DispatchSemaphore,
        release: DispatchSemaphore
    ) {
        io.async {
            started.signal()
            release.wait()
        }
    }
#endif

    /// Run after every Artifact write/delete queued before this call has delivered its MainActor
    /// completion. Workspace operation capture uses this as an observation barrier only; it never
    /// delays the user-visible move or changes legacy retry behavior.
    func afterPendingPersistence(
        of ids: Set<UUID>,
        completion: @escaping @MainActor (Bool) -> Void
    ) {
        io.async { [weak self] in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else {
                        completion(false)
                        return
                    }
                    let succeeded = ids.allSatisfy {
                        self.failedWrites[$0] == nil
                            && !self.failedDeletes.contains($0)
                            && self.pendingWriteSnapshots[$0] == nil
                            && !self.pendingDeleteIDs.contains($0)
                    }
                    completion(succeeded)
                }
            }
        }
    }

    // MARK: CRUD

    @discardableResult
    func create(
        title: String,
        type: String,
        source: String,
        workspaceID: UUID? = nil,
        cwd: String = ""
    ) -> Artifact {
        let a = Artifact(title: title.isEmpty ? "Untitled" : title, type: type, source: source,
                         origin: "user", workspaceID: workspaceID, cwd: cwd)
        artifacts = Self.sorted(artifacts + [a])
        persist(a)
        return a
    }

    /// Returns what undo needs to put the artifact back, or nil if there was nothing to delete.
    @discardableResult
    func delete(
        _ id: UUID,
        conversations explicitConversations: ConversationStore? = nil,
        synchronizeLiveState: Bool = true
    ) -> ArtifactDeleteReceipt? {
        guard let lease = WorkspaceAdoption.beginPlacementOperation() else {
            NSSound.beep()
            return nil
        }
        defer { WorkspaceAdoption.endPlacementOperation(lease) }
        guard let a = artifacts.first(where: { $0.uuid == id }) else { return nil }
        let conversations = explicitConversations ?? .shared
        artifacts.removeAll { $0.uuid == id }
        var record: WorkspaceMoveUndo.Record? = WorkspaceMoveUndo.Record()
        synchronizeCopies(
            before: a,
            after: nil,
            conversations: conversations,
            synchronizeLiveState: synchronizeLiveState,
            capturing: &record)
        let capture = try? LibraryTransientOperationCaptureFactory.artifactDelete(
            artifactID: a.uuid,
            ownerConversationID: a.conversationID)
        removeFile(
            id,
            operationCapture: capture.map {
                PendingOperationCapture(capture: $0)
            })
        return ArtifactDeleteReceipt(
            artifact: a,
            conversations: record ?? WorkspaceMoveUndo.Record())
    }

    /// Put a deleted artifact back, in the library and in every conversation that referenced it.
    ///
    /// Restoring the durable record alone is not enough: the delete removed the nested copy from
    /// each affected conversation, and `synchronizeCopies` locates its target by finding that copy,
    /// so it cannot run in reverse. The receipt carries those conversations as they stood.
    ///
    /// `persist` is what makes this safe against the resurrection guard rather than fighting it: it
    /// bumps `mutationGeneration` — invalidating any in-flight reload that still believes this
    /// artifact is deleted — and clears the id from `pendingDeleteIDs`, which is precisely the state
    /// a reload consults to filter it out.
    @discardableResult
    func restore(
        _ receipt: ArtifactDeleteReceipt,
        conversations explicitConversations: ConversationStore? = nil
    ) -> Bool {
        let conversations = explicitConversations ?? .shared
        let artifact = receipt.artifact
        guard !artifacts.contains(where: { $0.uuid == artifact.uuid }) else { return false }
        artifacts = Self.sorted(artifacts + [artifact])
        let capture = try? LibraryTransientOperationCaptureFactory.artifactDelete(
            artifactID: artifact.uuid,
            ownerConversationID: artifact.conversationID,
            reversed: true)
        persist(
            artifact,
            operationCapture: capture.map {
                PendingOperationCapture(capture: $0)
            })
        WorkspaceMoveUndo.apply(
            receipt.conversations,
            conversations: conversations,
            artifactStore: nil)
        return true
    }

    func rename(
        _ id: UUID,
        to newTitle: String,
        conversations explicitConversations: ConversationStore? = nil,
        synchronizeLiveState: Bool = true
    ) {
        let name = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, let i = artifacts.firstIndex(where: { $0.uuid == id }), artifacts[i].title != name else { return }
        let conversations = explicitConversations ?? .shared
        let before = artifacts[i]
        artifacts[i].title = name
        artifacts[i].updatedAt = Date()
        let after = artifacts[i]
        persist(after)
        artifacts = Self.sorted(artifacts)
        synchronizeCopies(
            before: before,
            after: after,
            conversations: conversations,
            synchronizeLiveState: synchronizeLiveState)
    }

    func setFavorite(
        _ id: UUID,
        _ on: Bool,
        conversations explicitConversations: ConversationStore? = nil,
        synchronizeLiveState: Bool = true
    ) {
        guard let i = artifacts.firstIndex(where: { $0.uuid == id }),
              artifacts[i].favorite != on else { return }
        let conversations = explicitConversations ?? .shared
        let before = artifacts[i]
        artifacts[i].favorite = on
        let after = artifacts[i]
        persist(after)
        artifacts = Self.sorted(artifacts)
        synchronizeCopies(
            before: before,
            after: after,
            conversations: conversations,
            synchronizeLiveState: synchronizeLiveState)
    }

    func updateSource(
        _ id: UUID,
        _ source: String,
        conversations explicitConversations: ConversationStore? = nil,
        synchronizeLiveState: Bool = true
    ) {
        guard let i = artifacts.firstIndex(where: { $0.uuid == id }), artifacts[i].source != source else { return }
        let conversations = explicitConversations ?? .shared
        let before = artifacts[i]
        artifacts[i].source = source
        artifacts[i].updatedAt = Date()
        artifacts[i].revisions += 1
        let after = artifacts[i]
        persist(after)
        artifacts = Self.sorted(artifacts)
        synchronizeCopies(
            before: before,
            after: after,
            conversations: conversations,
            synchronizeLiveState: synchronizeLiveState)
    }

    /// Keep the standalone record, conversation snapshot, open inspectors, and preview registry on
    /// one canonical value. Without the persisted conversation mutation, a later bridge save (or a
    /// relaunch of a legacy sidecar) can resurrect a deleted title/source after an apparently
    /// successful manager/inspector action.
    /// The common case: no undo record wanted.
    private func synchronizeCopies(
        before: Artifact,
        after: Artifact?,
        conversations: ConversationStore,
        synchronizeLiveState: Bool
    ) {
        var ignored: WorkspaceMoveUndo.Record?
        synchronizeCopies(
            before: before,
            after: after,
            conversations: conversations,
            synchronizeLiveState: synchronizeLiveState,
            capturing: &ignored)
    }

    /// `capturing` records each affected conversation *before* it is rewritten, so a delete can be
    /// undone. Deleting removes the nested entry outright, and this function finds its target by
    /// locating that entry — so it cannot run in reverse. The pre-state has to be kept.
    ///
    /// Captured here rather than recomputed by the caller: the affected set includes a
    /// content-match fallback for the provenanced conversation, and a second copy of that rule
    /// would drift.
    private func synchronizeCopies(
        before: Artifact,
        after: Artifact?,
        conversations: ConversationStore,
        synchronizeLiveState: Bool,
        capturing record: inout WorkspaceMoveUndo.Record?
    ) {
        let provenanceConversationID = before.conversationID ?? after?.conversationID
        var affectedConversationIDs = conversations.conversationIDs(
            referencingArtifactIDs: [before.uuid])
        // UUID identity converges every explicit reference, including references to standalone
        // user/ambient artifacts that have no conversation provenance. Preserve the old bounded
        // content-equivalent repair only for the artifact's provenanced conversation: applying that
        // fallback to every sidecar could mutate an unrelated, intentionally duplicated artifact.
        if let provenanceConversationID,
           let conversation = conversations.residentConversation(provenanceConversationID)
                ?? conversations.hydrateImmediately(provenanceConversationID),
           Self.matchingIndex(for: before, in: conversation.artifacts) != nil {
            affectedConversationIDs.insert(provenanceConversationID)
        }

        var updatedConversations: [UUID: Conversation] = [:]
        for conversationID in affectedConversationIDs.sorted(by: {
            $0.uuidString < $1.uuidString
        }) {
            if record != nil,
               let existing = conversations.residentConversation(conversationID)
                    ?? conversations.hydrateImmediately(conversationID) {
                record?.captureArtifactMembership(existing)
            }
            let updated = conversations.update(conversationID) { conversation in
                let exactIndex = conversation.artifacts.firstIndex {
                    $0.uuid == before.uuid
                }
                let index = exactIndex
                    ?? (conversationID == provenanceConversationID
                        ? Self.matchingIndex(for: before, in: conversation.artifacts)
                        : nil)
                guard let index else { return }
                if let after {
                    conversation.artifacts[index] = after
                } else {
                    conversation.artifacts.remove(at: index)
                }
            }
            if let updated {
                updatedConversations[conversationID] = updated
            }
        }

        guard synchronizeLiveState else { return }
        for bridge in AgentBridge.live.allObjects {
            guard let conversationID = bridge.currentID,
                  affectedConversationIDs.contains(conversationID) else { continue }
            let exactIndex = bridge.artifacts.firstIndex { $0.uuid == before.uuid }
            let index = exactIndex
                ?? (conversationID == provenanceConversationID
                    ? Self.matchingIndex(for: before, in: bridge.artifacts)
                    : nil)
            guard let index else { continue }
            if let after {
                bridge.artifacts[index] = after
                if bridge.selectedArtifact == before.title {
                    bridge.selectedArtifact = after.title
                }
            } else {
                bridge.artifacts.remove(at: index)
                if bridge.selectedArtifact == before.title {
                    bridge.selectedArtifact = bridge.artifacts.last?.title
                }
            }
        }

        var previewConversationIDs = affectedConversationIDs
        if let provenanceConversationID {
            // A pop-out can be seeded before an old nested cache has converged. Keep the historical
            // provenanced preview coherent even when no matching sidecar entry was found above.
            previewConversationIDs.insert(provenanceConversationID)
        }
        for conversationID in previewConversationIDs {
            PreviewRegistry.shared.remove(conv: conversationID, title: before.title)
            if let updated = updatedConversations[conversationID] {
                // Re-seed the complete conversation after removing the old title. This restores a
                // distinct same-title artifact instead of leaving its preview accidentally blank.
                PreviewRegistry.shared.sync(updated.artifacts, conv: conversationID)
            } else if let after {
                PreviewRegistry.shared.put(after, conv: conversationID)
            }
        }
    }

    /// UUID identity is authoritative. The unique content-equivalent fallback repairs a bounded
    /// pre-convergence cache without using title alone, which could target the wrong same-name item.
    private static func matchingIndex(for artifact: Artifact, in candidates: [Artifact]) -> Int? {
        if let exact = candidates.firstIndex(where: { $0.uuid == artifact.uuid }) {
            return exact
        }
        let equivalent = candidates.indices.filter {
            candidates[$0].title == artifact.title
                && candidates[$0].type == artifact.type
                && candidates[$0].source == artifact.source
        }
        return equivalent.count == 1 ? equivalent[0] : nil
    }

    // MARK: workspace assignment

    /// Re-file one artifact without changing its content identity or conversation provenance.
    /// Returning the canonical snapshot lets callers converge nested/live copies without a second
    /// lookup that could race a directory-watcher refresh.
    @discardableResult
    func reassignArtifact(
        _ id: UUID,
        workspaceID: UUID?,
        cwd: String
    ) -> Artifact? {
        guard let index = artifacts.firstIndex(where: { $0.uuid == id }) else { return nil }
        let existing = artifacts[index]
        guard existing.workspaceID != workspaceID || existing.cwd != cwd else { return existing }

        var updated = existing
        updated.workspaceID = workspaceID
        updated.cwd = cwd
        var next = artifacts
        next[index] = updated
        artifacts = Self.sorted(next)
        persist(updated)
        return updated
    }

    /// Put a durable artifact back exactly as it was, for undo.
    ///
    /// `reassignArtifact` carries only `workspaceID` and `cwd`, which cannot reverse an adoption:
    /// adoption also fills `conversationID` when it was nil and `conversationTitle` when it was
    /// empty, and nothing in the app ever clears either. Restoring the whole recorded value is what
    /// makes a move followed by an undo identical to never having moved.
    @discardableResult
    func restore(_ artifact: Artifact) -> Artifact? {
        guard let index = artifacts.firstIndex(where: { $0.uuid == artifact.uuid }) else {
            return nil
        }
        guard artifacts[index] != artifact else { return artifact }
        var next = artifacts
        next[index] = artifact
        artifacts = Self.sorted(next)
        persist(artifact)
        return artifact
    }

    /// Restore only the ownership/location fields changed by Workspace adoption. Undo must not
    /// replace a whole Artifact and erase title/source/favorite edits made after the move.
    @discardableResult
    func restoreWorkspacePlacement(
        _ placement: WorkspaceMoveUndo.ArtifactPlacement,
        for id: UUID
    ) -> Artifact? {
        guard let index = artifacts.firstIndex(where: { $0.uuid == id }) else { return nil }
        var updated = artifacts[index]
        placement.apply(to: &updated)
        guard updated != artifacts[index] else { return updated }
        var next = artifacts
        next[index] = updated
        artifacts = Self.sorted(next)
        persist(updated)
        return updated
    }

    /// Re-file every durable artifact provenanced to one conversation. Older interactive artifacts
    /// may lack `conversationID`; callers can supply UUIDs from that conversation's nested snapshots
    /// as a bounded fallback. We never infer ownership by title/cwd, never adopt ambient/user
    /// artifacts, and never override a conflicting non-nil conversation provenance.
    @discardableResult
    func reassignArtifacts(
        forConversation conversationID: UUID,
        includingLegacyArtifactIDs legacyArtifactIDs: Set<UUID> = [],
        conversationTitle: String? = nil,
        workspaceID: UUID?,
        cwd: String
    ) -> [Artifact] {
        reassignArtifacts(
            matching: { artifact in
                artifact.conversationID == conversationID
                    || (artifact.conversationID == nil
                        && artifact.origin == "interactive"
                        && legacyArtifactIDs.contains(artifact.uuid))
            },
            workspaceID: workspaceID,
            cwd: cwd,
            transform: { artifact in
                // An exact nested UUID is durable evidence that this pre-provenance artifact belongs
                // to the conversation. Heal it once so every later move uses canonical provenance
                // instead of depending on another nested-snapshot fallback.
                guard artifact.conversationID == nil,
                      artifact.origin == "interactive",
                      legacyArtifactIDs.contains(artifact.uuid) else { return }
                artifact.conversationID = conversationID
                if let conversationTitle {
                    artifact.conversationTitle = conversationTitle
                }
            })
    }

    /// Rebase all artifacts owned by a workspace when its folder changes. Exact workspace identity
    /// is authoritative. The legacy fallback is deliberately narrower: the artifact must have an
    /// affected conversation and the project's non-empty previous cwd.
    /// A nil identity with an empty cwd is also the user's explicit Home filing and must stay Home.
    /// Nil-provenance interactive artifacts require an explicit nested UUID; cwd alone is never
    /// ownership evidence.
    @discardableResult
    func reassignArtifacts(
        inWorkspace workspaceID: UUID,
        includingConversationIDs conversationIDs: Set<UUID>,
        includingLegacyArtifactIDs legacyArtifactIDs: Set<UUID> = [],
        previousCwd: String,
        cwd: String
    ) -> [Artifact] {
        reassignArtifacts(
            matching: { artifact in
                Self.followsWorkspaceFolder(
                    artifact,
                    workspaceID: workspaceID,
                    conversationIDs: conversationIDs,
                    legacyArtifactIDs: legacyArtifactIDs,
                    previousCwd: previousCwd)
            },
            workspaceID: workspaceID,
            cwd: cwd)
    }

    /// Establish the exact durable-artifact half of a Workspace-folder impact graph without
    /// mutating it. Async coordinators use these UUIDs to acquire every Conversation holding a
    /// nested copy before the main-actor commit; the predicate is shared with the mutation above so
    /// discovery and commit can never drift into subtly different ownership rules.
    func artifactIDsFollowingWorkspaceFolder(
        inWorkspace workspaceID: UUID,
        includingConversationIDs conversationIDs: Set<UUID>,
        includingLegacyArtifactIDs legacyArtifactIDs: Set<UUID> = [],
        previousCwd: String
    ) -> Set<UUID> {
        Set(artifacts.lazy.compactMap { artifact in
            Self.followsWorkspaceFolder(
                artifact,
                workspaceID: workspaceID,
                conversationIDs: conversationIDs,
                legacyArtifactIDs: legacyArtifactIDs,
                previousCwd: previousCwd)
                ? artifact.uuid
                : nil
        })
    }

    private static func followsWorkspaceFolder(
        _ artifact: Artifact,
        workspaceID: UUID,
        conversationIDs: Set<UUID>,
        legacyArtifactIDs: Set<UUID>,
        previousCwd: String
    ) -> Bool {
        if artifact.workspaceID == workspaceID { return true }
        if let conversationID = artifact.conversationID,
           conversationIDs.contains(conversationID),
           !previousCwd.isEmpty,
           artifact.cwd == previousCwd {
            return true
        }
        return artifact.conversationID == nil
            && artifact.origin == "interactive"
            && legacyArtifactIDs.contains(artifact.uuid)
    }

    /// Apply a batch as one published array mutation, then persist its changed snapshots. Matched
    /// snapshots are returned even when already assigned so higher layers can converge stale nested
    /// copies idempotently.
    private func reassignArtifacts(
        matching belongsToMove: (Artifact) -> Bool,
        workspaceID: UUID?,
        cwd: String,
        transform: (inout Artifact) -> Void = { _ in }
    ) -> [Artifact] {
        let matchedIDs = Set(artifacts.lazy.filter(belongsToMove).map(\.uuid))
        guard !matchedIDs.isEmpty else { return [] }

        var next = artifacts
        var changed: [Artifact] = []
        for index in next.indices where matchedIDs.contains(next[index].uuid) {
            var updated = next[index]
            updated.workspaceID = workspaceID
            updated.cwd = cwd
            transform(&updated)
            guard updated != next[index] else { continue }
            next[index] = updated
            changed.append(updated)
        }
        if !changed.isEmpty {
            artifacts = Self.sorted(next)
            for artifact in changed {
                persist(artifact)
            }
        }
        return artifacts.filter { matchedIDs.contains($0.uuid) }
    }

    // MARK: agent write-through (interactive turns via AgentBridge)

    /// Upsert an artifact from an agent turn. An explicit preferred id is used when a user dragged
    /// an existing artifact into this conversation; otherwise (conversationID, title) preserves the
    /// original same-title live-update contract. Returning the durable snapshot lets the nested
    /// conversation cache converge on the store's identity instead of minting a second UUID.
    @discardableResult
    func upsertFromAgent(title: String, type: String, source: String,
                         workspaceID: UUID?, conversationID: UUID?, conversationTitle: String, cwd: String,
                         origin: String = "interactive",
                         preferredID: UUID? = nil) -> Artifact {
        let explicitIndex = preferredID.flatMap { id in
            artifacts.firstIndex(where: { $0.uuid == id })
        }
        let scopedIndex = artifacts.firstIndex {
            $0.conversationID == conversationID && $0.title == title
        }
        if let i = explicitIndex ?? scopedIndex {
            let preservesPriorProvenance =
                explicitIndex == i && artifacts[i].conversationID != conversationID
            artifacts[i].type = type
            artifacts[i].source = source
            artifacts[i].updatedAt = Date()
            artifacts[i].revisions += 1
            // A revision updates content, not the user's filing choice. New artifacts are born in
            // the conversation's workspace below; once an existing artifact is moved explicitly,
            // only the workspace-adoption coordinator may move it again. Otherwise the next
            // same-title agent event silently snaps it back to the conversation's old location.
            if !preservesPriorProvenance {
                artifacts[i].conversationID = conversationID
                artifacts[i].conversationTitle = conversationTitle
            }
            let updated = artifacts[i]
            persist(updated)
            artifacts = Self.sorted(artifacts)
            return updated
        } else {
            var a = Artifact(title: title, type: type, source: source, origin: origin,
                             workspaceID: workspaceID, conversationID: conversationID,
                             conversationTitle: conversationTitle, cwd: cwd,
                             uuid: preferredID ?? UUID())
            a.revisions = 1
            artifacts = Self.sorted(artifacts + [a])
            persist(a)
            return a
        }
    }

    // MARK: one-time migration from conversation-nested artifacts

    private func migrateIfNeeded() {
        let marker = dir.appendingPathComponent(".migrated-v1")
        guard !FileManager.default.fileExists(atPath: marker.path) else { return }
        let convDir = supportBase.appendingPathComponent("conversations", isDirectory: true)
        let dec = Self.persistedDecoder()
        let files = (try? FileManager.default.contentsOfDirectory(at: convDir, includingPropertiesForKeys: nil)) ?? []
        for f in files where f.pathExtension == "json" {
            guard let data = try? Data(contentsOf: f), let c = try? dec.decode(Conversation.self, from: data) else { continue }
            for nested in c.artifacts {
                var a = nested
                a.conversationID = c.id
                a.conversationTitle = c.title
                a.cwd = c.cwd
                if a.origin.isEmpty { a.origin = "interactive" }
                let enc = Self.persistedEncoder()
                if let d = try? enc.encode(a) { try? d.write(to: fileURL(a.uuid)) }
            }
        }
        FileManager.default.createFile(atPath: marker.path, contents: Data())
    }

    // MARK: external restore/repair directory watch

    private func startWatching() {
        let fd = open(dir.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: [.write, .rename], queue: .main)
        src.setEventHandler { [weak self] in self?.debouncedReload() }
        src.setCancelHandler { close(fd) }
        src.resume()
        watch = src
    }

    /// Coalesce a burst of file events (an ambient run can write several) into one reload.
    private func debouncedReload() {
        guard !reloadPending else { return }
        reloadPending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            self?.reloadPending = false
            self?.load()
        }
    }
}

/// Shared, actionable presentation for persistence failures in both artifact surfaces.
/// A one-line disk-failure banner with a Retry affordance — shared by the artifacts panel and the
/// main window's conversation/workspace save surfaces.
struct PersistenceErrorBanner: View {
    let message: String
    let retry: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "externaldrive.badge.exclamationmark")
                .foregroundStyle(Color.nWarningText)
            Text(message)
                .scaledFont(11)
                .lineLimit(2)
            Spacer(minLength: 8)
            Button("Try Again", action: retry)
                .buttonStyle(PillButtonStyle(kind: .accent))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(Color.orange.opacity(0.12))
        .accessibilityElement(children: .contain)
    }
}
