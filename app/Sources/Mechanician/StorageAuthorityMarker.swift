import Darwin
import Foundation
import SQLite3

/// The process-wide generation fence introduced by the A3 recognition release.
///
/// This protocol is intentionally independent of the marketing/build number. Public 0.24.0 and
/// several dogfood candidates share build 208, but only A3-and-later binaries understand the root
/// marker. A future incompatible writer increments this identifier instead of pretending an older
/// binary can compare unordered Git revisions.
enum StorageAuthorityProtocol {
    static let recognitionID = "storage-authority-v1"
    static let markerFormatVersion = 1
    static let markerName = "storage-authority.json"
    static let databaseName = "library.db"
    static let processLeaseName = ".storage-authority.lock"
    static let resetMarkerName = "library.db.shadow-resettable"
    static let maximumMarkerBytes = 32 * 1_024
}

enum StorageAuthorityMarkerMode: String, Codable, Equatable, Sendable {
    case sqlite
    case legacy
}

/// A bounded root decision. SQLite markers name the database; rollback markers name one immutable
/// sibling Legacy generation. `databaseInstanceID` prevents a copied or replaced database from
/// inheriting authority merely because its filename is familiar.
struct StorageAuthorityMarker: Codable, Equatable, Sendable {
    let formatVersion: Int
    let mode: StorageAuthorityMarkerMode
    let activationID: UUID
    let databaseInstanceID: UUID
    let databaseName: String
    let generationName: String?
    let rollbackID: UUID?
    let schemaVersion: Int
    let minimumWriterBuild: String
    let createdAt: String

    init(
        mode: StorageAuthorityMarkerMode,
        activationID: UUID,
        databaseInstanceID: UUID,
        generationName: String? = nil,
        rollbackID: UUID? = nil,
        schemaVersion: Int = SQLiteLibraryStore.schemaVersion,
        minimumWriterBuild: String = StorageAuthorityProtocol.recognitionID,
        createdAt: String
    ) {
        formatVersion = StorageAuthorityProtocol.markerFormatVersion
        self.mode = mode
        self.activationID = activationID
        self.databaseInstanceID = databaseInstanceID
        databaseName = StorageAuthorityProtocol.databaseName
        self.generationName = generationName
        self.rollbackID = rollbackID
        self.schemaVersion = schemaVersion
        self.minimumWriterBuild = minimumWriterBuild
        self.createdAt = createdAt
    }
}

struct StorageAuthorityDatabaseProbe: Equatable, Sendable {
    let databaseInstanceID: UUID
    let schemaVersion: Int
    let authorityState: LibraryAuthorityState
    let activationID: UUID?
    let rollbackID: UUID?
    let minimumWriterBuild: String?
    let committedSequence: Int64
}

enum StorageAuthorityMarkerObservation: Equatable, Sendable {
    case absent
    case valid(StorageAuthorityMarker)
    case invalid(String)

    var title: String {
        switch self {
        case .absent: return "Absent · Legacy authority"
        case .valid(let marker): return "Recognized · \(marker.mode.rawValue.capitalized)"
        case .invalid: return "Invalid · launch fenced"
        }
    }
}

enum StorageAuthorityLaunchDisposition: Equatable, Sendable {
    /// No committed root marker exists. A shadow database leaves Legacy authoritative; a
    /// prepared/active database instead records an interrupted marker-last activation and fences
    /// Legacy until the eligible dogfood process resumes it.
    case legacyUnmarked(database: StorageAuthorityDatabaseProbe?)
    /// A verified rollback marker and matching DB pair selects one fresh immutable Legacy root.
    case legacyGeneration(marker: StorageAuthorityMarker, root: URL)
    /// SQLite is authoritative. The matching repository runs the normal product while every
    /// Legacy writer remains fenced.
    case sqlite(marker: StorageAuthorityMarker, database: StorageAuthorityDatabaseProbe)
    /// Uncertainty is never interpreted as permission to resurrect Legacy writers.
    case blocked(String)

    var isBlocked: Bool {
        if case .blocked = self { return true }
        return false
    }

    var allowsLegacyWriters: Bool {
        switch self {
        case .legacyUnmarked(let database):
            return database == nil || database?.authorityState == .shadow
        case .legacyGeneration: return true
        case .sqlite, .blocked: return false
        }
    }

    /// SQLite authority is a normal product mode once the matching repository is present. Keep
    /// this independent from `allowsLegacyWriters`: the root marker must fence every old JSON
    /// writer while the same process continues through the SQLite-backed product.
    var allowsNormalProduct: Bool {
        switch self {
        case .legacyUnmarked(let database):
            return database == nil || database?.authorityState == .shadow
        case .legacyGeneration: return true
        case .sqlite(_, let database): return database.authorityState == .active
        case .blocked: return false
        }
    }

    var title: String {
        switch self {
        case .legacyUnmarked(let database):
            return database?.authorityState == .prepared || database?.authorityState == .active
                ? "SQLite · resuming activation"
                : "Legacy · no authority marker"
        case .legacyGeneration: return "Legacy · verified rollback generation"
        case .sqlite: return "SQLite · recognized"
        case .blocked: return "Blocked · recovery required"
        }
    }

    var blockingMessage: String? {
        switch self {
        case .legacyUnmarked(let database):
            guard database?.authorityState == .prepared || database?.authorityState == .active else {
                return nil
            }
            return "SQLite activation was interrupted before its root marker published. Recovery must complete before the product opens."
        case .legacyGeneration: return nil
        case .sqlite(_, let database):
            return database.authorityState == .active
                ? nil
                : "SQLite activation is not active (\(database.authorityState.rawValue)). Recovery must complete before the product opens."
        case .blocked(let message):
            return message
        }
    }
}

/// What a newer binary must do to an existing active authority before it can open it.
enum StorageAuthorityUpgradeAssessment: Equatable, Sendable {
    /// Nothing to carry forward: already current, not a SQLite authority, or not classifiable.
    /// Every uncertain shape lands here so the upgrade never acts on a root it does not understand.
    case notNeeded
    /// An active authority at an older schema. Migrate a copy and swap it in.
    case migrate(marker: StorageAuthorityMarker, probe: StorageAuthorityDatabaseProbe)
    /// An upgrade that swapped the database in and died before republishing the marker.
    case republishMarker(marker: StorageAuthorityMarker, probe: StorageAuthorityDatabaseProbe)
    /// Recognized, but this build cannot carry it forward. The message is shown to the user.
    case unsupported(String)
}

struct StorageAuthorityRecognition: Equatable, Sendable {
    let anchorRoot: URL
    let effectiveSupportRoot: URL
    let marker: StorageAuthorityMarkerObservation
    let disposition: StorageAuthorityLaunchDisposition

    static func legacyDefault(root: URL) -> StorageAuthorityRecognition {
        StorageAuthorityRecognition(
            anchorRoot: root,
            effectiveSupportRoot: root,
            marker: .absent,
            disposition: .legacyUnmarked(database: nil))
    }
}

enum StorageAuthorityRecognitionError: Error, Equatable, LocalizedError {
    case unsafeRoot(String)
    case invalidMarker(String)
    case database(String)
    case lease(String)
    case publication(String)

    var errorDescription: String? {
        switch self {
        case .unsafeRoot(let value): return "Unsafe storage-authority root: \(value)"
        case .invalidMarker(let value): return "Invalid storage-authority marker: \(value)"
        case .database(let value): return "Storage-authority database probe failed: \(value)"
        case .lease(let value): return "Storage-authority lease failed: \(value)"
        case .publication(let value): return "Storage-authority publication failed: \(value)"
        }
    }
}

/// One place that makes the support root private to this user, or says why it cannot be.
///
/// Both recognition and the writer lease require an owner-only root, and both used to simply refuse
/// one that was not. Only the migration ever tightened that directory, and only on the machine that
/// ran it — every other installation has whatever `createDirectory` left under the default umask,
/// which is 0755. Refusing that is refusing to launch, with the data already sitting there at those
/// permissions, so it protects nothing.
///
/// Having a single repair matters as much as having one at all. When only the lease repaired, the
/// app survived by accident of ordering — it inspected, then leased, then inspected again — and any
/// path that recognized the root without taking the lease first still saw a blocked launch. A
/// notification-relay launch does exactly that.
/// The rule itself now lives in `OwnerOnlyDirectory`, shared with the backup paths that used to
/// carry their own copies. The label reproduces this type's original messages exactly.
enum StorageAuthorityRootPrivacy {
    /// Returns nil when the root is (or has been made) private to this user.
    static func makePrivateReason(_ root: URL) -> String? {
        OwnerOnlyDirectory.makePrivateReason(root, label: "support root")
    }
}

enum StorageAuthorityRecognizer {
    private enum DatabaseObservation {
        case absent
        case valid(StorageAuthorityDatabaseProbe)
        case invalid(String)
    }

    static func inspect(supportRoot: URL) -> StorageAuthorityRecognition {
        let root = supportRoot.standardizedFileURL
        if let problem = unsafeExistingRootReason(root) {
            return blocked(root: root, marker: .invalid(problem), problem)
        }
        let marker = readMarker(in: root)
        let database = probeDatabase(in: root)

        switch marker {
        case .absent:
            switch database {
            case .absent:
                return StorageAuthorityRecognition(
                    anchorRoot: root,
                    effectiveSupportRoot: root,
                    marker: marker,
                    disposition: .legacyUnmarked(database: nil))
            case .valid(let probe):
                switch probe.authorityState {
                case .shadow, .prepared, .active:
                    return StorageAuthorityRecognition(
                        anchorRoot: root,
                        effectiveSupportRoot: root,
                        marker: marker,
                        disposition: .legacyUnmarked(database: probe))
                case .rollbackPrepared, .rolledBack:
                    return blocked(
                        root: root,
                        marker: marker,
                        "library.db records \(probe.authorityState.rawValue) authority, but the root marker is missing or invalid. Legacy writers were not opened.")
                }
            case .invalid(let detail):
                return blocked(
                    root: root,
                    marker: marker,
                    "library.db could not be classified read-only (\(detail)). Legacy writers were not opened because active authority cannot be excluded.")
            }

        case .invalid:
            switch database {
            case .absent:
                return blocked(
                    root: root,
                    marker: marker,
                    "The root marker is invalid and library.db is absent. A committed SQLite generation cannot be excluded, so Legacy writers were not opened.")
            case .valid(let probe):
                switch probe.authorityState {
                case .shadow:
                    return StorageAuthorityRecognition(
                        anchorRoot: root,
                        effectiveSupportRoot: root,
                        marker: marker,
                        disposition: .legacyUnmarked(database: probe))
                case .prepared, .active, .rollbackPrepared, .rolledBack:
                    return blocked(
                        root: root,
                        marker: marker,
                        "library.db records \(probe.authorityState.rawValue) authority, but the root marker is missing or invalid. Legacy writers were not opened.")
                }
            case .invalid(let detail):
                return blocked(
                    root: root,
                    marker: marker,
                    "library.db could not be classified read-only (\(detail)). Legacy writers were not opened because active authority cannot be excluded.")
            }

        case .valid(let value):
            guard case .valid(let probe) = database else {
                let detail: String
                switch database {
                case .absent: detail = "library.db is missing"
                case .invalid(let reason): detail = reason
                case .valid: detail = "unknown database failure"
                }
                return blocked(
                    root: root,
                    marker: marker,
                    "The \(value.mode.rawValue) marker has no matching readable database (\(detail)). Legacy writers were not opened.")
            }
            if let problem = validate(value, against: probe) {
                return blocked(root: root, marker: marker, problem)
            }
            switch value.mode {
            case .sqlite:
                guard probe.authorityState == .prepared
                        || probe.authorityState == .active
                        || probe.authorityState == .rollbackPrepared else {
                    return blocked(
                        root: root,
                        marker: marker,
                        "A SQLite marker cannot pair with database state \(probe.authorityState.rawValue).")
                }
                return StorageAuthorityRecognition(
                    anchorRoot: root,
                    effectiveSupportRoot: root,
                    marker: marker,
                    disposition: .sqlite(marker: value, database: probe))

            case .legacy:
                guard (probe.authorityState == .rollbackPrepared
                        || probe.authorityState == .rolledBack),
                      probe.rollbackID == value.rollbackID,
                      let generationName = value.generationName,
                      let generation = safeSiblingGeneration(
                        named: generationName, for: root) else {
                    return blocked(
                        root: root,
                        marker: marker,
                        "The Legacy marker does not match a verified rollback-prepared database and generation.")
                }
                return StorageAuthorityRecognition(
                    anchorRoot: root,
                    effectiveSupportRoot: generation,
                    marker: marker,
                    disposition: .legacyGeneration(marker: value, root: generation))
            }
        }
    }

    /// Whether this root holds an active authority that a newer binary must carry forward, and how.
    ///
    /// Recognition deliberately does not answer this. `inspect` classifies a marker/database PAIR
    /// and has no opinion about the running binary's schema version — the version gap only becomes
    /// an error later, inside the repository opener, where it can do nothing but block. Asking the
    /// question here, read-only and before anything opens for writes, is what makes an upgrade
    /// possible at all.
    static func assessUpgrade(supportRoot: URL) -> StorageAuthorityUpgradeAssessment {
        let root = supportRoot.standardizedFileURL
        if unsafeExistingRootReason(root) != nil { return .notNeeded }
        guard case .valid(let marker) = readMarker(in: root),
              case .valid(let probe) = probeDatabase(in: root),
              marker.mode == .sqlite,
              marker.databaseInstanceID == probe.databaseInstanceID,
              marker.activationID == probe.activationID,
              marker.minimumWriterBuild == probe.minimumWriterBuild,
              probe.authorityState == .active,
              probe.rollbackID == nil else { return .notNeeded }

        let current = SQLiteLibraryStore.schemaVersion
        if marker.schemaVersion == probe.schemaVersion {
            if probe.schemaVersion == current { return .notNeeded }
            if probe.schemaVersion > current {
                // A library written by a newer build. Migrating it backwards is not a thing that
                // exists, so say so rather than attempting anything.
                return .unsupported(
                    "This library was written by a newer version of Mechanician (schema v\(probe.schemaVersion)). Update the app to open it.")
            }
            guard probe.schemaVersion >= SQLiteLibraryStore.lowestUpgradableSchemaVersion else {
                return .unsupported(
                    "This library uses schema v\(probe.schemaVersion), which this version can no longer upgrade.")
            }
            return .migrate(marker: marker, probe: probe)
        }

        // The one interrupted state an upgrade can leave behind: the database was swapped in at the
        // new version but the process died before the marker was republished. The database is
        // internally whole and still names the same authority, so only two integers in the marker
        // are stale. Finishing that is a republish, not a migration.
        if probe.schemaVersion == current,
           marker.schemaVersion < probe.schemaVersion,
           marker.schemaVersion >= SQLiteLibraryStore.lowestUpgradableSchemaVersion {
            return .republishMarker(marker: marker, probe: probe)
        }
        return .notNeeded
    }

    private static func blocked(
        root: URL,
        marker: StorageAuthorityMarkerObservation,
        _ message: String
    ) -> StorageAuthorityRecognition {
        StorageAuthorityRecognition(
            anchorRoot: root,
            effectiveSupportRoot: root,
            marker: marker,
            disposition: .blocked(message))
    }

    private static func readMarker(in root: URL) -> StorageAuthorityMarkerObservation {
        let url = root.appendingPathComponent(StorageAuthorityProtocol.markerName)
        var status = stat()
        guard lstat(url.path, &status) == 0 else {
            return errno == ENOENT
                ? .absent
                : .invalid("marker path could not be inspected")
        }
        do {
            let data = try boundedOwnerOnlyRegularFile(
                at: url, maximumBytes: StorageAuthorityProtocol.maximumMarkerBytes)
            let marker = try JSONDecoder().decode(StorageAuthorityMarker.self, from: data)
            if let problem = markerValidationProblem(marker) {
                throw StorageAuthorityRecognitionError.invalidMarker(problem)
            }
            return .valid(marker)
        } catch {
            return .invalid(error.localizedDescription)
        }
    }

    static func markerValidationProblem(_ marker: StorageAuthorityMarker) -> String? {
        guard marker.formatVersion == StorageAuthorityProtocol.markerFormatVersion,
              marker.databaseName == StorageAuthorityProtocol.databaseName,
              marker.schemaVersion > 0,
              marker.minimumWriterBuild == StorageAuthorityProtocol.recognitionID,
              validTimestamp(marker.createdAt),
              marker.generationName == nil || safeLeaf(marker.generationName!),
              (marker.mode == .sqlite
                ? marker.generationName == nil && marker.rollbackID == nil
                : marker.generationName != nil && marker.rollbackID != nil) else {
            return "fields do not satisfy format v\(StorageAuthorityProtocol.markerFormatVersion)"
        }
        return nil
    }

    private static func validate(
        _ marker: StorageAuthorityMarker,
        against database: StorageAuthorityDatabaseProbe
    ) -> String? {
        guard marker.databaseInstanceID == database.databaseInstanceID else {
            return "The marker names a different library.db instance."
        }
        guard marker.schemaVersion == database.schemaVersion else {
            return "The marker and library.db schema versions differ."
        }
        guard marker.activationID == database.activationID else {
            return "The marker and library.db activation IDs differ."
        }
        guard marker.minimumWriterBuild == database.minimumWriterBuild else {
            return "The marker and library.db minimum-writer identities differ."
        }
        return nil
    }

    private static func probeDatabase(in root: URL) -> DatabaseObservation {
        let url = root.appendingPathComponent(StorageAuthorityProtocol.databaseName)
        var status = stat()
        guard lstat(url.path, &status) == 0 else {
            return errno == ENOENT
                ? .absent
                : .invalid("library.db path could not be inspected")
        }
        guard status.st_mode & S_IFMT == S_IFREG,
              status.st_uid == geteuid(),
              status.st_mode & 0o077 == 0,
              status.st_nlink == 1 else {
            return .invalid("library.db is not an owner-only regular file")
        }

        var db: OpaquePointer?
        // The macOS system SQLite VFS can reject SQLITE_OPEN_NOFOLLOW even though the SDK exposes
        // the flag. Reject a symlink with lstat above, open read-only, then attest that the pathname
        // still names the same protected inode before executing any SQL.
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX
        let openResult = sqlite3_open_v2(url.path, &db, flags, nil)
        guard openResult == SQLITE_OK, let db else {
            let detail = db.map { String(cString: sqlite3_errmsg($0)) }
                ?? "SQLite result \(openResult)"
            if let db { sqlite3_close_v2(db) }
            return .invalid("library.db could not be opened read-only: \(detail)")
        }
        defer { sqlite3_close_v2(db) }
        var openedStatus = stat()
        guard lstat(url.path, &openedStatus) == 0,
              openedStatus.st_dev == status.st_dev,
              openedStatus.st_ino == status.st_ino,
              openedStatus.st_mode & S_IFMT == S_IFREG,
              openedStatus.st_uid == geteuid(),
              openedStatus.st_mode & 0o077 == 0,
              openedStatus.st_nlink == 1 else {
            return .invalid("library.db changed while opening read-only")
        }
        sqlite3_busy_timeout(db, 2_000)

        do {
            try execute(db, sql: "PRAGMA trusted_schema = OFF")
            try execute(db, sql: "PRAGMA query_only = ON")
            guard try scalarInt(db, sql: "PRAGMA application_id")
                    == Int64(SQLiteLibraryStore.applicationID) else {
                throw StorageAuthorityRecognitionError.database("application id mismatch")
            }
            let userVersion = Int(try scalarInt(db, sql: "PRAGMA user_version"))
            var rows: [StorageAuthorityDatabaseProbe] = []
            let sql = """
                SELECT database_instance_id, schema_version, application_id, authority_state,
                       activation_id, rollback_id, minimum_writer_build, committed_sequence
                FROM library_metadata WHERE singleton = 1
                """
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK,
                  let statement else {
                throw StorageAuthorityRecognitionError.database("metadata query could not prepare")
            }
            defer { sqlite3_finalize(statement) }
            while true {
                let result = sqlite3_step(statement)
                if result == SQLITE_DONE { break }
                guard result == SQLITE_ROW else {
                    throw StorageAuthorityRecognitionError.database(
                        "metadata query failed while reading rows")
                }
                guard let instance = text(statement, 0).flatMap(UUID.init(uuidString:)),
                      let stateText = text(statement, 3),
                      let state = LibraryAuthorityState(rawValue: stateText) else {
                    throw StorageAuthorityRecognitionError.database("authority metadata is malformed")
                }
                let schemaVersion = Int(sqlite3_column_int64(statement, 1))
                guard schemaVersion == userVersion,
                      sqlite3_column_int64(statement, 2)
                        == Int64(SQLiteLibraryStore.applicationID) else {
                    throw StorageAuthorityRecognitionError.database(
                        "header and authority metadata disagree")
                }
                rows.append(StorageAuthorityDatabaseProbe(
                    databaseInstanceID: instance,
                    schemaVersion: schemaVersion,
                    authorityState: state,
                    activationID: text(statement, 4).flatMap(UUID.init(uuidString:)),
                    rollbackID: text(statement, 5).flatMap(UUID.init(uuidString:)),
                    minimumWriterBuild: text(statement, 6),
                    committedSequence: sqlite3_column_int64(statement, 7)))
            }
            guard rows.count == 1 else {
                throw StorageAuthorityRecognitionError.database(
                    "authority metadata singleton is missing or duplicated")
            }
            return .valid(rows[0])
        } catch {
            return .invalid(error.localizedDescription)
        }
    }

    private static func safeSiblingGeneration(named name: String, for root: URL) -> URL? {
        guard safeLeaf(name) else { return nil }
        let candidate = root.deletingLastPathComponent().appendingPathComponent(
            name, isDirectory: true).standardizedFileURL
        guard candidate != root,
              candidate.deletingLastPathComponent() == root.deletingLastPathComponent() else {
            return nil
        }
        var status = stat()
        guard lstat(candidate.path, &status) == 0,
              status.st_mode & S_IFMT == S_IFDIR,
              status.st_uid == geteuid(),
              status.st_mode & 0o077 == 0 else { return nil }
        return candidate
    }

    private static func unsafeExistingRootReason(_ root: URL) -> String? {
        StorageAuthorityRootPrivacy.makePrivateReason(root)
    }

    private static func safeLeaf(_ value: String) -> Bool {
        !value.isEmpty
            && value != "."
            && value != ".."
            && !value.contains("/")
            && !value.contains("\\")
            && !value.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7f })
    }

    private static func validTimestamp(_ value: String) -> Bool {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if fractional.date(from: value) != nil { return true }
        return ISO8601DateFormatter().date(from: value) != nil
    }

    private static func boundedOwnerOnlyRegularFile(
        at url: URL,
        maximumBytes: Int
    ) throws -> Data {
        var status = stat()
        guard lstat(url.path, &status) == 0,
              status.st_mode & S_IFMT == S_IFREG,
              status.st_uid == geteuid(),
              status.st_mode & 0o077 == 0,
              status.st_nlink == 1,
              status.st_size >= 0,
              status.st_size <= Int64(maximumBytes) else {
            throw StorageAuthorityRecognitionError.invalidMarker(
                "file is not a bounded owner-only regular file")
        }
        let descriptor = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else {
            throw StorageAuthorityRecognitionError.invalidMarker("file could not be opened")
        }
        defer { Darwin.close(descriptor) }
        var bytes = Data(count: Int(status.st_size))
        let count = bytes.count
        let didRead = bytes.withUnsafeMutableBytes { buffer -> Int in
            guard let base = buffer.baseAddress else { return count == 0 ? 0 : -1 }
            var offset = 0
            while offset < count {
                let result = Darwin.read(descriptor, base.advanced(by: offset), count - offset)
                if result < 0, errno == EINTR { continue }
                if result <= 0 { return -1 }
                offset += result
            }
            return offset
        }
        guard didRead == count else {
            throw StorageAuthorityRecognitionError.invalidMarker("file changed while reading")
        }
        var after = stat()
        guard fstat(descriptor, &after) == 0,
              after.st_dev == status.st_dev,
              after.st_ino == status.st_ino,
              after.st_mode & S_IFMT == S_IFREG,
              after.st_uid == geteuid(),
              after.st_mode & 0o077 == 0,
              after.st_nlink == 1,
              after.st_size == status.st_size,
              after.st_mtimespec.tv_sec == status.st_mtimespec.tv_sec,
              after.st_mtimespec.tv_nsec == status.st_mtimespec.tv_nsec,
              after.st_ctimespec.tv_sec == status.st_ctimespec.tv_sec,
              after.st_ctimespec.tv_nsec == status.st_ctimespec.tv_nsec else {
            throw StorageAuthorityRecognitionError.invalidMarker("file changed while reading")
        }
        return bytes
    }

    private static func scalarInt(_ db: OpaquePointer, sql: String) throws -> Int64 {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else {
            throw StorageAuthorityRecognitionError.database("query could not prepare")
        }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else {
            throw StorageAuthorityRecognitionError.database("query returned no row")
        }
        return sqlite3_column_int64(statement, 0)
    }

    private static func execute(_ db: OpaquePointer, sql: String) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
            throw StorageAuthorityRecognitionError.database("query safety pragma failed")
        }
    }

    private static func text(_ statement: OpaquePointer, _ column: Int32) -> String? {
        guard sqlite3_column_type(statement, column) != SQLITE_NULL,
              let pointer = sqlite3_column_text(statement, column) else { return nil }
        return String(cString: pointer)
    }
}

/// Durable marker publication. The pristine-library bootstrap calls this as its final write; every
/// migrated installation already has the marker. The rename is the point after which SQLite owns
/// the root, so this remains product-critical authority code rather than migration machinery.
enum StorageAuthorityMarkerStore {
    static func publish(_ marker: StorageAuthorityMarker, in supportRoot: URL) throws {
        let root = supportRoot.standardizedFileURL
        // Repair rather than refuse, the same way recognition and the lease do. This guard used to
        // be a third hand-written copy of the same rule, and it was the one that never learned: an
        // identical refusal on the lease path blocked two installations from launching at all
        // (0.24.1), and one of them could not even reach Check for Updates to escape it. Relying on
        // an earlier step having already repaired the root is exactly the reasoning that failed.
        if let problem = StorageAuthorityRootPrivacy.makePrivateReason(root) {
            throw StorageAuthorityRecognitionError.unsafeRoot(problem)
        }
        // Identity captured *after* the repair, so the change-during-publication check below
        // compares against the directory this call actually validated rather than a pre-repair one.
        var rootStatus = stat()
        guard lstat(root.path, &rootStatus) == 0 else {
            throw StorageAuthorityRecognitionError.unsafeRoot("support root could not be inspected")
        }
        if let problem = StorageAuthorityRecognizer.markerValidationProblem(marker) {
            throw StorageAuthorityRecognitionError.publication(problem)
        }
        // The shadow-reset receipt grants older pre-activation builds permission to destroy and
        // rebuild `library.db`. No authority marker may coexist with that permission: preparation
        // must retire it first, and marker-last publication fails rather than making two
        // contradictory root decisions durable.
        let resetReceipt = root.appendingPathComponent(StorageAuthorityProtocol.resetMarkerName)
        var resetStatus = stat()
        if lstat(resetReceipt.path, &resetStatus) == 0 || errno != ENOENT {
            throw StorageAuthorityRecognitionError.publication(
                "the disposable shadow reset receipt still exists or cannot be classified")
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(marker)
        guard data.count <= StorageAuthorityProtocol.maximumMarkerBytes else {
            throw StorageAuthorityRecognitionError.publication("marker is oversized")
        }
        let destination = root.appendingPathComponent(StorageAuthorityProtocol.markerName)
        let temporary = root.appendingPathComponent(
            ".\(StorageAuthorityProtocol.markerName).\(UUID().uuidString).tmp")
        let descriptor = Darwin.open(
            temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, mode_t(0o600))
        guard descriptor >= 0 else {
            throw StorageAuthorityRecognitionError.publication("temporary marker could not open")
        }
        var published = false
        defer {
            Darwin.close(descriptor)
            if !published { _ = Darwin.unlink(temporary.path) }
        }
        guard fchmod(descriptor, mode_t(0o600)) == 0 else {
            throw StorageAuthorityRecognitionError.publication(
                "temporary marker permissions could not be protected")
        }
        var temporaryStatus = stat()
        guard fstat(descriptor, &temporaryStatus) == 0,
              temporaryStatus.st_mode & S_IFMT == S_IFREG,
              temporaryStatus.st_uid == geteuid(),
              temporaryStatus.st_mode & 0o077 == 0,
              temporaryStatus.st_nlink == 1 else {
            throw StorageAuthorityRecognitionError.publication(
                "temporary marker is not an owner-only single-link regular file")
        }
        try data.withUnsafeBytes { buffer in
            guard let base = buffer.baseAddress else { return }
            var offset = 0
            while offset < buffer.count {
                let result = Darwin.write(descriptor, base.advanced(by: offset), buffer.count - offset)
                if result < 0, errno == EINTR { continue }
                guard result > 0 else {
                    throw StorageAuthorityRecognitionError.publication("marker write failed")
                }
                offset += result
            }
        }
        guard fsync(descriptor) == 0,
              rename(temporary.path, destination.path) == 0 else {
            throw StorageAuthorityRecognitionError.publication("marker publication failed")
        }
        published = true
        let directory = Darwin.open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard directory >= 0 else {
            throw StorageAuthorityRecognitionError.publication("marker directory could not open")
        }
        defer { Darwin.close(directory) }
        var openedRootStatus = stat()
        guard fstat(directory, &openedRootStatus) == 0,
              openedRootStatus.st_dev == rootStatus.st_dev,
              openedRootStatus.st_ino == rootStatus.st_ino,
              openedRootStatus.st_mode & S_IFMT == S_IFDIR,
              openedRootStatus.st_uid == geteuid(),
              openedRootStatus.st_mode & 0o077 == 0 else {
            throw StorageAuthorityRecognitionError.publication(
                "marker directory changed during publication")
        }
        guard fsync(directory) == 0 else {
            throw StorageAuthorityRecognitionError.publication("marker directory sync failed")
        }
    }
}

final class StorageAuthorityProcessLease: @unchecked Sendable {
    private let descriptor: Int32

    private init(descriptor: Int32) { self.descriptor = descriptor }

    static func acquire(in root: URL) throws -> StorageAuthorityProcessLease {
        if !FileManager.default.fileExists(atPath: root.path) {
            do {
                try FileManager.default.createDirectory(
                    at: root,
                    withIntermediateDirectories: true,
                    attributes: [.posixPermissions: NSNumber(value: 0o700)])
            } catch {
                throw StorageAuthorityRecognitionError.lease(
                    "support root could not be created: \(error.localizedDescription)")
            }
        }
        // Shared with recognition, so a root the app can repair is repaired the same way wherever
        // it is first met rather than only on the path that happens to take the lease.
        if let problem = StorageAuthorityRootPrivacy.makePrivateReason(root) {
            throw StorageAuthorityRecognitionError.lease(problem)
        }
        let url = root.appendingPathComponent(StorageAuthorityProtocol.processLeaseName)
        let createdDescriptor = Darwin.open(
            url.path,
            O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
            mode_t(0o600))
        let descriptor: Int32
        let created: Bool
        if createdDescriptor >= 0 {
            descriptor = createdDescriptor
            created = true
        } else if errno == EEXIST {
            descriptor = Darwin.open(url.path, O_RDWR | O_NOFOLLOW | O_CLOEXEC)
            created = false
        } else {
            descriptor = -1
            created = false
        }
        guard descriptor >= 0 else {
            throw StorageAuthorityRecognitionError.lease("lease file could not open")
        }
        if created, fchmod(descriptor, mode_t(0o600)) != 0 {
            Darwin.close(descriptor)
            throw StorageAuthorityRecognitionError.lease(
                "new lease file permissions could not be protected")
        }
        var leaseStatus = stat()
        guard fstat(descriptor, &leaseStatus) == 0,
              leaseStatus.st_mode & S_IFMT == S_IFREG,
              leaseStatus.st_uid == geteuid(),
              leaseStatus.st_mode & 0o077 == 0,
              leaseStatus.st_nlink == 1 else {
            Darwin.close(descriptor)
            throw StorageAuthorityRecognitionError.lease(
                "lease must be an owner-only single-link regular file")
        }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            Darwin.close(descriptor)
            throw StorageAuthorityRecognitionError.lease(
                "another recognition-capable Mechanician process owns this library")
        }
        var lockedStatus = stat()
        guard fstat(descriptor, &lockedStatus) == 0,
              lockedStatus.st_dev == leaseStatus.st_dev,
              lockedStatus.st_ino == leaseStatus.st_ino,
              lockedStatus.st_mode & S_IFMT == S_IFREG,
              lockedStatus.st_uid == geteuid(),
              lockedStatus.st_mode & 0o077 == 0,
              lockedStatus.st_nlink == 1 else {
            _ = flock(descriptor, LOCK_UN)
            Darwin.close(descriptor)
            throw StorageAuthorityRecognitionError.lease(
                "lease file changed while ownership was acquired")
        }
        return StorageAuthorityProcessLease(descriptor: descriptor)
    }

    deinit {
        _ = flock(descriptor, LOCK_UN)
        Darwin.close(descriptor)
    }
}

/// One immutable decision per process. `MechanicianApp.init` calls this after bundle-derived path
/// bootstrap and before a scene can construct any store or provider runtime.
enum StorageAuthorityBootstrap {
    private static let lock = NSLock()
    private static var stored: StorageAuthorityRecognition?
    private static var processLease: StorageAuthorityProcessLease?

    static var current: StorageAuthorityRecognition {
        lock.lock()
        defer { lock.unlock() }
        return stored ?? .legacyDefault(root: MechanicianEnvironment.currentSupportRoot())
    }

    static var ownsProcessLease: Bool {
        lock.lock()
        defer { lock.unlock() }
        return processLease != nil
    }

    static func recognizeCurrentProcess(
        acquireLease: Bool,
        provisionsPristineLibrary: Bool = true
    ) {
        lock.lock()
        defer { lock.unlock() }
        guard stored == nil else { return }
        let anchor = MechanicianEnvironment.currentSupportRoot()
        var recognition = StorageAuthorityRecognizer.inspect(supportRoot: anchor)
        if acquireLease {
            do {
                processLease = try StorageAuthorityProcessLease.acquire(in: anchor)
                // Marker publication and rollback are atomic, but they can still win between the
                // first probe and lease acquisition. The decision used by every store is always
                // the second read made while this process owns the writer lease.
                recognition = StorageAuthorityRecognizer.inspect(supportRoot: anchor)
                // Carry an existing library across a schema bump before anything tries to open it.
                // This runs under the lease and before provisioning, because an active authority at
                // an older schema is neither pristine nor openable: without this the active opener
                // asserts an exact version match, fails, and launch lands on Storage Recovery. That
                // is exactly what schema v7 did to every existing installation on 2026-08-14.
                let upgrade = SQLiteLibraryAuthorityUpgrade.upgradeIfNeeded(
                    supportRoot: anchor,
                    ownsProcessLease: true)
                recognition = upgrade.recognition
                switch upgrade.outcome {
                case .notNeeded, .upgraded, .markerRepublished:
                    break
                case .unsupported(let message), .failed(let message):
                    recognition = StorageAuthorityRecognition(
                        anchorRoot: anchor,
                        effectiveSupportRoot: anchor,
                        marker: recognition.marker,
                        disposition: .blocked(message))
                }
                if provisionsPristineLibrary, !recognition.disposition.isBlocked {
                    do {
                        recognition = try SQLiteLibraryBootstrapService.provisionIfNeeded(
                            recognition: recognition,
                            ownsProcessLease: true)
                    } catch {
                        recognition = StorageAuthorityRecognition(
                            anchorRoot: anchor,
                            effectiveSupportRoot: anchor,
                            marker: recognition.marker,
                            disposition: .blocked(error.localizedDescription))
                    }
                } else {
                    // Background verification may inspect/open an existing library, but never
                    // creates a new authority as a side effect of a diagnostic launch.
                }
            } catch {
                recognition = StorageAuthorityRecognition(
                    anchorRoot: anchor,
                    effectiveSupportRoot: anchor,
                    marker: recognition.marker,
                    disposition: .blocked(error.localizedDescription))
            }
        }
        stored = recognition
        if case .legacyGeneration = recognition.disposition {
            setenv("MECHANICIAN_SUPPORT_DIR", recognition.effectiveSupportRoot.path, 1)
        }
    }

    /// Turns marker-level SQLite recognition into a product-ready decision by proving that the
    /// process can open the active writable repository before SwiftUI constructs any store-bearing
    /// scene. The default opener also registers the repository singleton, so normal stores reuse
    /// this exact verified handle instead of opening a second writer.
    @discardableResult
    static func preflightSQLiteRepository(
        openRepository: (StorageAuthorityRecognition) throws -> Bool = {
            try LibraryAuthorityRepository.open(recognition: $0) != nil
        }
    ) -> StorageAuthorityRecognition {
        lock.lock()
        defer { lock.unlock() }
        let recognition = stored
            ?? .legacyDefault(root: MechanicianEnvironment.currentSupportRoot())
        let checked = SQLiteAuthorityRepositoryPreflight.evaluate(
            recognition,
            openRepository: openRepository)
        stored = checked
        return checked
    }
}

/// Marker probing deliberately uses a small read-only SQLite check. Normal product startup needs
/// one additional proof: the matching active repository must actually open for writes. A failure
/// here is authority uncertainty, never permission to construct Legacy or half-backed stores.
enum SQLiteAuthorityRepositoryPreflight {
    static func evaluate(
        _ recognition: StorageAuthorityRecognition,
        openRepository: (StorageAuthorityRecognition) throws -> Bool
    ) -> StorageAuthorityRecognition {
        // Prepared/incomplete activation remains owned by the activation-resume policy. Only an
        // already-active SQLite selection is eligible to enter normal product construction.
        guard case .sqlite(_, let database) = recognition.disposition,
              database.authorityState == .active else { return recognition }
        do {
            guard try openRepository(recognition) else {
                throw StorageAuthorityRecognitionError.database(
                    "active repository opener returned no repository")
            }
            return recognition
        } catch {
            return StorageAuthorityRecognition(
                anchorRoot: recognition.anchorRoot,
                effectiveSupportRoot: recognition.effectiveSupportRoot,
                marker: recognition.marker,
                disposition: .blocked(
                    "SQLite authority repository could not open: \(error.localizedDescription)"))
        }
    }
}
