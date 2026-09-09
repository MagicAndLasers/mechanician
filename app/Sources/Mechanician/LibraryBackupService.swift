import CryptoKit
import Darwin
import Foundation
import SQLite3

/// A checksummed backup of one coherent `library.db` snapshot and every retained byte referenced
/// by that snapshot.
///
/// It never changes authority state, never opens a restored database through the writable
/// repository, and requires an explicit destination outside the live support root.
struct LibraryBackupManifest: Codable, Equatable, Sendable {
    static let currentFormatVersion = 3

    struct DatabaseBinding: Codable, Equatable, Sendable {
        let databaseInstanceID: UUID
        let schemaVersion: Int
        let applicationID: Int32
        let authorityState: String
        let activationID: UUID?
        let rollbackID: UUID?
        let minimumWriterBuild: String?
        let committedSequence: Int64
        let shadowChangeSequence: Int64
        let relativePath: String
        let byteCount: Int64
        let sha256: String
    }

    struct RetainedReference: Codable, Equatable, Sendable {
        let referenceID: UUID
        let ownerKind: String
        let ownerConversationID: UUID?
        let ownerOperationID: UUID?
        let ownerEventID: UUID?
        let referenceKind: String
    }

    struct RetainedByte: Codable, Equatable, Sendable {
        let sourceIdentity: String
        let storageIdentity: String
        let kind: String
        let ownerConversationID: UUID?
        let ownerOperationID: UUID?
        let storageName: String
        let mediaType: String
        let retentionState: String
        let disposition: String
        let byteCount: Int64
        let sha256: String
        let backupRelativePath: String
        let references: [RetainedReference]
    }

    let formatVersion: Int
    let backupID: UUID
    let createdAt: String
    let database: DatabaseBinding
    let retainedBytes: [RetainedByte]
}

struct LibraryBackupReceipt: Equatable, Sendable {
    let backupURL: URL
    let manifest: LibraryBackupManifest
    let manifestSHA256: String
}

struct LibraryBackupRestoreReport: Equatable, Sendable {
    let restoredSupportRoot: URL
    let databaseInstanceID: UUID
    let schemaVersion: Int
    let authorityState: LibraryAuthorityState
    let activationID: UUID?
    let committedSequence: Int64
    let shadowChangeSequence: Int64
    let retainedByteCount: Int
    let retainedBytes: Int64
    let manifestSHA256: String
}

enum LibraryBackupServiceError: Error, Equatable, LocalizedError {
    case invalidInput(String)
    case permissions(String)
    case sqlite(String)
    case verification(String)

    var errorDescription: String? {
        switch self {
        case .invalidInput(let detail): return "Invalid library backup input: \(detail)"
        case .permissions(let detail): return "Library backup permission failure: \(detail)"
        case .sqlite(let detail): return "Library backup SQLite failure: \(detail)"
        case .verification(let detail): return "Library backup verification failure: \(detail)"
        }
    }
}

enum LibraryBackupService {
    private static let manifestName = "manifest.json"
    private static let manifestDigestName = "manifest.sha256"
    private static let databaseName = "library.db"
    private static let maximumBusyAttempts = 500
    private static let transferBufferBytes = 1_024 * 1_024
    private static let immutablePooledObjectMode = mode_t(0o400)

    /// A consistent copy of one live SQLite database, taken through SQLite's own backup API so a
    /// WAL in flight is included rather than missed by a byte copy.
    ///
    /// Exposed for the schema-upgrade path, which migrates a copy and swaps it in rather than
    /// touching the live authority. Deliberately narrower than `createBackup`: no manifest, no
    /// retained bytes, no generation — this is one database file, and the caller owns its lifetime.
    static func copyDatabase(source: URL, destination: URL) throws {
        try onlineBackup(source: source, destination: destination)
    }

    /// Takes a SQLite online backup and publishes the complete backup directory by one final rename.
    /// The explicit destination must not exist and must not be inside the source support root. With
    /// no pool, retained bytes are copied into the generation exactly as before. An optional shared
    /// pool stores each verified digest once and hard-links it into every self-contained generation.
    static func createBackup(
        sourceSupportRoot: URL,
        destinationURL: URL,
        backupID: UUID = UUID(),
        createdAt: Date = Date(),
        sharedObjectPoolURL: URL? = nil
    ) throws -> LibraryBackupReceipt {
        let sourceRoot = sourceSupportRoot.standardizedFileURL
        let destination = destinationURL.standardizedFileURL
        guard !isDescendant(destination, of: sourceRoot) else {
            throw LibraryBackupServiceError.invalidInput(
                "backup destination must be outside the live support root")
        }
        guard !FileManager.default.fileExists(atPath: destination.path) else {
            throw LibraryBackupServiceError.invalidInput("backup destination already exists")
        }
        // Repaired, not refused — the second copy of the check that stranded a machine at launch.
        try makePrivateOwnedDirectory(sourceRoot, label: "support root")
        let sourceDatabase = sourceRoot.appendingPathComponent(databaseName, isDirectory: false)
        try requireOwnerOnlyRegularFile(sourceDatabase, label: databaseName)

        let sharedObjectPool = sharedObjectPoolURL?.standardizedFileURL
        if let sharedObjectPool {
            guard !isDescendant(sharedObjectPool, of: sourceRoot) else {
                throw LibraryBackupServiceError.invalidInput(
                    "shared backup object pool must be outside the live support root")
            }
            guard sharedObjectPool != destination,
                  !isDescendant(sharedObjectPool, of: destination),
                  !isDescendant(destination, of: sharedObjectPool) else {
                throw LibraryBackupServiceError.invalidInput(
                    "shared backup object pool must be outside the backup generation")
            }
            try prepareSharedObjectPool(sharedObjectPool)
        }

        let parent = destination.deletingLastPathComponent()
        try prepareDestinationParent(parent)
        let staging = parent.appendingPathComponent(
            ".\(destination.lastPathComponent).staging-\(UUID().uuidString)",
            isDirectory: true)
        try createOwnerOnlyDirectory(staging)
        var published = false
        defer {
            if !published { try? FileManager.default.removeItem(at: staging) }
        }

        let stagedDatabase = staging.appendingPathComponent(databaseName, isDirectory: false)
        try onlineBackup(source: sourceDatabase, destination: stagedDatabase)
        try setOwnerOnlyFile(stagedDatabase)

        let snapshot = try inspectDatabase(at: stagedDatabase, requireIntegrity: true)
        let databaseDigest = try digestRegularFile(stagedDatabase, requireOwnerOnly: true)
        let retainedRoot = staging.appendingPathComponent("retained", isDirectory: true)
        let objectsRoot = retainedRoot.appendingPathComponent("objects", isDirectory: true)
        try createOwnerOnlyDirectory(retainedRoot)
        try createOwnerOnlyDirectory(objectsRoot)

        let sourceRootFD = Darwin.open(sourceRoot.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard sourceRootFD >= 0 else { throw posixPermissions("could not open support root") }
        defer { Darwin.close(sourceRootFD) }

        var retainedManifest: [LibraryBackupManifest.RetainedByte] = []
        for retained in snapshot.retainedBytes {
            let identityDigest = sha256(Data(retained.storageIdentity.utf8))
            let shard = String(identityDigest.prefix(2))
            let shardURL = objectsRoot.appendingPathComponent(shard, isDirectory: true)
            if !FileManager.default.fileExists(atPath: shardURL.path) {
                try createOwnerOnlyDirectory(shardURL)
            }
            let objectRelativePath = "retained/objects/\(shard)/\(identityDigest).blob"
            let objectURL = staging.appendingPathComponent(objectRelativePath, isDirectory: false)
            let copied: FileDigest
            if let sharedObjectPool {
                let contentShard = String(retained.sha256.prefix(2)).lowercased()
                let poolShardURL = sharedObjectPool.appendingPathComponent(
                    contentShard, isDirectory: true)
                try prepareOwnerOnlyDirectory(poolShardURL, label: "backup object-pool shard")
                let poolObjectURL = poolShardURL.appendingPathComponent(
                    "\(retained.sha256.lowercased()).blob", isDirectory: false)
                copied = try verifiedPooledObject(
                    rootFD: sourceRootFD,
                    relativePath: retained.storageIdentity,
                    destination: poolObjectURL,
                    expectedByteCount: retained.byteCount,
                    expectedSHA256: retained.sha256,
                    requiredSourcePermissions:
                        retained.disposition == "unclaimed_recovery" ? 0o400 : nil)
                try hardLinkVerifiedObject(
                    source: poolObjectURL,
                    destination: objectURL,
                    expectedByteCount: retained.byteCount,
                    expectedSHA256: retained.sha256)
            } else {
                copied = try copyRelativeOwnerOnlyFile(
                    rootFD: sourceRootFD,
                    relativePath: retained.storageIdentity,
                    destination: objectURL,
                    requiredSourcePermissions:
                        retained.disposition == "unclaimed_recovery" ? 0o400 : nil)
            }
            guard copied.byteCount == retained.byteCount,
                  copied.sha256.caseInsensitiveCompare(retained.sha256) == .orderedSame else {
                throw LibraryBackupServiceError.verification(
                    "retained byte changed or disagrees with library.db: \(retained.sourceIdentity)")
            }
            retainedManifest.append(LibraryBackupManifest.RetainedByte(
                sourceIdentity: retained.sourceIdentity,
                storageIdentity: retained.storageIdentity,
                kind: retained.kind,
                ownerConversationID: retained.ownerConversationID,
                ownerOperationID: retained.ownerOperationID,
                storageName: retained.storageName,
                mediaType: retained.mediaType,
                retentionState: retained.retentionState,
                disposition: retained.disposition,
                byteCount: retained.byteCount,
                sha256: retained.sha256,
                backupRelativePath: objectRelativePath,
                references: retained.references))
        }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let manifest = LibraryBackupManifest(
            formatVersion: LibraryBackupManifest.currentFormatVersion,
            backupID: backupID,
            createdAt: formatter.string(from: createdAt),
            database: LibraryBackupManifest.DatabaseBinding(
                databaseInstanceID: snapshot.metadata.databaseInstanceID,
                schemaVersion: snapshot.metadata.schemaVersion,
                applicationID: snapshot.applicationID,
                authorityState: snapshot.metadata.authorityState.rawValue,
                activationID: snapshot.metadata.activationID,
                rollbackID: snapshot.metadata.rollbackID,
                minimumWriterBuild: snapshot.metadata.minimumWriterBuild,
                committedSequence: snapshot.metadata.committedSequence,
                shadowChangeSequence: snapshot.shadowChangeSequence,
                relativePath: databaseName,
                byteCount: databaseDigest.byteCount,
                sha256: databaseDigest.sha256),
            retainedBytes: retainedManifest.sorted { $0.sourceIdentity < $1.sourceIdentity })
        let manifestData = try encodeManifest(manifest)
        let manifestSHA256 = sha256(manifestData)
        try writeOwnerOnly(manifestData, to: staging.appendingPathComponent(manifestName))
        try writeOwnerOnly(
            Data("\(manifestSHA256)  \(manifestName)\n".utf8),
            to: staging.appendingPathComponent(manifestDigestName))

        _ = try verifyBackup(at: staging)
        do {
            try FileManager.default.moveItem(at: staging, to: destination)
            try setOwnerOnlyDirectory(destination)
            published = true
        } catch {
            throw LibraryBackupServiceError.permissions(
                "could not publish backup: \(error.localizedDescription)")
        }
        return LibraryBackupReceipt(
            backupURL: destination,
            manifest: manifest,
            manifestSHA256: manifestSHA256)
    }

    /// Restores into a new, isolated support root and verifies the restored database read-only.
    /// It never constructs `SQLiteLibraryStore`, so verification cannot create a WAL, reset marker,
    /// or integrity receipt in the restored copy.
    static func verifyAndRestore(
        backupURL: URL,
        isolatedSupportRoot: URL
    ) throws -> LibraryBackupRestoreReport {
        let backup = backupURL.standardizedFileURL
        let destination = isolatedSupportRoot.standardizedFileURL
        guard !FileManager.default.fileExists(atPath: destination.path) else {
            throw LibraryBackupServiceError.invalidInput(
                "isolated restore root already exists")
        }
        guard !isDescendant(destination, of: backup) else {
            throw LibraryBackupServiceError.invalidInput(
                "restore root must not be inside the backup")
        }
        let verified = try verifyBackup(at: backup)
        let parent = destination.deletingLastPathComponent()
        try prepareDestinationParent(parent)
        let staging = parent.appendingPathComponent(
            ".\(destination.lastPathComponent).restore-\(UUID().uuidString)",
            isDirectory: true)
        try createOwnerOnlyDirectory(staging)
        var published = false
        defer {
            if !published { try? FileManager.default.removeItem(at: staging) }
        }

        let backupDatabase = backup.appendingPathComponent(
            verified.manifest.database.relativePath, isDirectory: false)
        let restoredDatabase = staging.appendingPathComponent(databaseName, isDirectory: false)
        try copyVerifiedFile(
            source: backupDatabase,
            destination: restoredDatabase,
            expectedByteCount: verified.manifest.database.byteCount,
            expectedSHA256: verified.manifest.database.sha256)

        for retained in verified.manifest.retainedBytes {
            let source = backup.appendingPathComponent(retained.backupRelativePath, isDirectory: false)
            let target = try safeDestination(
                root: staging,
                relativePath: retained.storageIdentity)
            try prepareOwnerOnlyParents(of: target, beneath: staging)
            try copyVerifiedFile(
                source: source,
                destination: target,
                expectedByteCount: retained.byteCount,
                expectedSHA256: retained.sha256)
        }

        let restored = try inspectDatabase(at: restoredDatabase, requireIntegrity: true)
        try requireMatchingDatabase(verified.manifest.database, inspected: restored)
        for retained in verified.manifest.retainedBytes {
            let target = try safeDestination(root: staging, relativePath: retained.storageIdentity)
            let digest = try digestRegularFile(target, requireOwnerOnly: true)
            guard digest.byteCount == retained.byteCount,
                  digest.sha256.caseInsensitiveCompare(retained.sha256) == .orderedSame else {
                throw LibraryBackupServiceError.verification(
                    "restored retained byte does not match manifest: \(retained.sourceIdentity)")
            }
        }
        do {
            try FileManager.default.moveItem(at: staging, to: destination)
            try setOwnerOnlyDirectory(destination)
            published = true
        } catch {
            throw LibraryBackupServiceError.permissions(
                "could not publish isolated restore: \(error.localizedDescription)")
        }
        return LibraryBackupRestoreReport(
            restoredSupportRoot: destination,
            databaseInstanceID: restored.metadata.databaseInstanceID,
            schemaVersion: restored.metadata.schemaVersion,
            authorityState: restored.metadata.authorityState,
            activationID: restored.metadata.activationID,
            committedSequence: restored.metadata.committedSequence,
            shadowChangeSequence: restored.shadowChangeSequence,
            retainedByteCount: verified.manifest.retainedBytes.count,
            retainedBytes: verified.manifest.retainedBytes.reduce(0) { $0 + $1.byteCount },
            manifestSHA256: verified.manifestSHA256)
    }
}

// MARK: - Private verification model

private extension LibraryBackupService {
    struct FileDigest {
        let byteCount: Int64
        let sha256: String
    }

    struct DatabaseSnapshot {
        struct RetainedByte {
            let sourceIdentity: String
            let storageIdentity: String
            let kind: String
            let ownerConversationID: UUID?
            let ownerOperationID: UUID?
            let storageName: String
            let mediaType: String
            let retentionState: String
            let disposition: String
            let byteCount: Int64
            let sha256: String
            var references: [LibraryBackupManifest.RetainedReference]
        }

        let metadata: LibraryAuthorityMetadata
        let applicationID: Int32
        let shadowChangeSequence: Int64
        let retainedBytes: [RetainedByte]
    }

    struct VerifiedBackup {
        let manifest: LibraryBackupManifest
        let manifestSHA256: String
    }

    static func verifyBackup(at backup: URL) throws -> VerifiedBackup {
        try requireOwnerOnlyDirectory(backup, label: "backup root")
        let manifestURL = backup.appendingPathComponent(manifestName, isDirectory: false)
        let detachedURL = backup.appendingPathComponent(manifestDigestName, isDirectory: false)
        try requireOwnerOnlyRegularFile(manifestURL, label: manifestName)
        try requireOwnerOnlyRegularFile(detachedURL, label: manifestDigestName)
        let manifestData = try Data(contentsOf: manifestURL, options: [.mappedIfSafe])
        let actualManifestDigest = sha256(manifestData)
        let detached = try String(contentsOf: detachedURL, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard detached == "\(actualManifestDigest)  \(manifestName)" else {
            throw LibraryBackupServiceError.verification("manifest checksum does not match")
        }
        let manifest: LibraryBackupManifest
        do {
            manifest = try JSONDecoder().decode(LibraryBackupManifest.self, from: manifestData)
        } catch {
            throw LibraryBackupServiceError.verification(
                "manifest could not be decoded: \(error.localizedDescription)")
        }
        guard manifest.formatVersion == LibraryBackupManifest.currentFormatVersion else {
            throw LibraryBackupServiceError.verification(
                "unsupported manifest format \(manifest.formatVersion)")
        }
        guard manifest.database.relativePath == databaseName else {
            throw LibraryBackupServiceError.verification("database path is not canonical")
        }
        let databaseURL = backup.appendingPathComponent(databaseName, isDirectory: false)
        let databaseDigest = try digestRegularFile(databaseURL, requireOwnerOnly: true)
        guard databaseDigest.byteCount == manifest.database.byteCount,
              databaseDigest.sha256.caseInsensitiveCompare(manifest.database.sha256) == .orderedSame else {
            throw LibraryBackupServiceError.verification("database checksum does not match")
        }
        let inspected = try inspectDatabase(at: databaseURL, requireIntegrity: true)
        try requireMatchingDatabase(manifest.database, inspected: inspected)
        let manifestInventory = manifest.retainedBytes.sorted { $0.sourceIdentity < $1.sourceIdentity }
        let databaseInventory = inspected.retainedBytes.sorted { $0.sourceIdentity < $1.sourceIdentity }
        guard manifestInventory.count == databaseInventory.count else {
            throw LibraryBackupServiceError.verification(
                "retained-byte manifest does not cover the database reference set")
        }
        for (entry, row) in zip(manifestInventory, databaseInventory) {
            guard entry.sourceIdentity == row.sourceIdentity,
                  entry.storageIdentity == row.storageIdentity,
                  entry.kind == row.kind,
                  entry.ownerConversationID == row.ownerConversationID,
                  entry.ownerOperationID == row.ownerOperationID,
                  entry.storageName == row.storageName,
                  entry.mediaType == row.mediaType,
                  entry.retentionState == row.retentionState,
                  entry.disposition == row.disposition,
                  entry.byteCount == row.byteCount,
                  entry.sha256.caseInsensitiveCompare(row.sha256) == .orderedSame,
                  entry.references == row.references else {
                throw LibraryBackupServiceError.verification(
                    "retained-byte manifest disagrees with library.db: \(entry.sourceIdentity)")
            }
            let objectURL = try safeDestination(root: backup, relativePath: entry.backupRelativePath)
            let objectDigest = try digestRegularFile(objectURL, requireOwnerOnly: true)
            guard objectDigest.byteCount == entry.byteCount,
                  objectDigest.sha256.caseInsensitiveCompare(entry.sha256) == .orderedSame else {
                throw LibraryBackupServiceError.verification(
                    "backup object checksum does not match: \(entry.sourceIdentity)")
            }
        }
        return VerifiedBackup(manifest: manifest, manifestSHA256: actualManifestDigest)
    }

    static func requireMatchingDatabase(
        _ binding: LibraryBackupManifest.DatabaseBinding,
        inspected: DatabaseSnapshot
    ) throws {
        let metadata = inspected.metadata
        guard binding.databaseInstanceID == metadata.databaseInstanceID,
              binding.schemaVersion == metadata.schemaVersion,
              binding.applicationID == inspected.applicationID,
              binding.authorityState == metadata.authorityState.rawValue,
              binding.activationID == metadata.activationID,
              binding.rollbackID == metadata.rollbackID,
              binding.minimumWriterBuild == metadata.minimumWriterBuild,
              binding.committedSequence == metadata.committedSequence,
              binding.shadowChangeSequence == inspected.shadowChangeSequence else {
            throw LibraryBackupServiceError.verification(
                "database authority binding does not match the backed-up snapshot")
        }
    }

    static func inspectDatabase(
        at url: URL,
        requireIntegrity: Bool
    ) throws -> DatabaseSnapshot {
        try requireOwnerOnlyRegularFile(url, label: url.lastPathComponent)
        var db: OpaquePointer?
        // Online backup produces a complete main database, but the copied header retains the
        // source's WAL mode. `immutable=1` is the SQLite-supported way to inspect that sealed copy
        // without creating a WAL/SHM beside it or pretending the backup may still change.
        let readOnlyURI = url.absoluteString + "?mode=ro&immutable=1"
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX | SQLITE_OPEN_URI
        guard sqlite3_open_v2(readOnlyURI, &db, flags, nil) == SQLITE_OK, let db else {
            let detail = db.map { String(cString: sqlite3_errmsg($0)) } ?? "open failed"
            if let db { sqlite3_close(db) }
            throw LibraryBackupServiceError.sqlite(detail)
        }
        defer { sqlite3_close(db) }
        guard sqlite3_exec(db, "PRAGMA query_only = ON", nil, nil, nil) == SQLITE_OK else {
            throw sqliteError(db, "could not enable read-only verification")
        }
        let applicationID = Int32(try scalarInt64(db, sql: "PRAGMA application_id"))
        guard applicationID == SQLiteLibraryStore.applicationID else {
            throw LibraryBackupServiceError.verification("unexpected SQLite application id")
        }
        if requireIntegrity {
            let result = try scalarText(db, sql: "PRAGMA integrity_check")
            guard result == "ok" else {
                throw LibraryBackupServiceError.verification("SQLite integrity_check: \(result)")
            }
            guard try rowCount(db, sql: "PRAGMA foreign_key_check") == 0 else {
                throw LibraryBackupServiceError.verification("SQLite foreign_key_check failed")
            }
        }

        let metadataSQL = """
        SELECT database_instance_id, schema_version, authority_state, activation_id,
               rollback_id, minimum_writer_build, committed_sequence, shadow_change_sequence
        FROM library_metadata WHERE singleton = 1
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, metadataSQL, -1, &statement, nil) == SQLITE_OK,
              let statement else { throw sqliteError(db, "could not read library metadata") }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW,
              let rawInstance = text(statement, 0),
              let instanceID = UUID(uuidString: rawInstance),
              let rawState = text(statement, 2),
              let authorityState = LibraryAuthorityState(rawValue: rawState) else {
            throw LibraryBackupServiceError.verification("library metadata is invalid")
        }
        let schemaVersion = Int(sqlite3_column_int64(statement, 1))
        let metadata = LibraryAuthorityMetadata(
            databaseInstanceID: instanceID,
            schemaVersion: schemaVersion,
            authorityState: authorityState,
            activationID: text(statement, 3).flatMap(UUID.init(uuidString:)),
            rollbackID: text(statement, 4).flatMap(UUID.init(uuidString:)),
            minimumWriterBuild: text(statement, 5),
            committedSequence: sqlite3_column_int64(statement, 6))
        let shadowChangeSequence = sqlite3_column_int64(statement, 7)
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw LibraryBackupServiceError.verification("library metadata is not a singleton")
        }
        guard schemaVersion == SQLiteLibraryStore.schemaVersion else {
            throw LibraryBackupServiceError.verification(
                "unsupported library schema \(schemaVersion)")
        }
        let pragmaVersion = Int(try scalarInt64(db, sql: "PRAGMA user_version"))
        guard pragmaVersion == schemaVersion else {
            throw LibraryBackupServiceError.verification("schema version metadata disagrees with SQLite")
        }
        let retained = try readRetainedBytes(db)
        return DatabaseSnapshot(
            metadata: metadata,
            applicationID: applicationID,
            shadowChangeSequence: shadowChangeSequence,
            retainedBytes: retained)
    }

    static func readRetainedBytes(_ db: OpaquePointer) throws -> [DatabaseSnapshot.RetainedByte] {
        let unsupported = try scalarInt64(db, sql: """
        SELECT COUNT(*)
        FROM retained_byte_references ref
        JOIN retained_byte_sources r ON r.source_identity = ref.retained_source_identity
        WHERE r.storage_class != 'legacy_layout' OR r.storage_state != 'adopted'
           OR r.link_state != 'current' OR r.disposition != 'referenced'
        """)
        guard unsupported == 0 else {
            throw LibraryBackupServiceError.verification(
                "database has referenced retained bytes outside the adopted legacy-layout class")
        }
        let unreferencedAdopted = try scalarInt64(db, sql: """
        SELECT COUNT(*) FROM retained_byte_sources r
        WHERE r.storage_class = 'legacy_layout' AND r.storage_state = 'adopted'
          AND NOT EXISTS (
            SELECT 1 FROM retained_byte_references ref
            WHERE ref.retained_source_identity = r.source_identity)
        """)
        guard unreferencedAdopted == 0 else {
            throw LibraryBackupServiceError.verification(
                "database marks unreferenced retained bytes as adopted")
        }
        let pendingDisposition = try scalarInt64(db, sql: """
        SELECT COUNT(*) FROM retained_byte_sources WHERE disposition = 'reference_pending'
        """)
        guard pendingDisposition == 0 else {
            throw LibraryBackupServiceError.verification(
                "retained-byte ownership disposition is incomplete")
        }
        let malformedUnclaimed = try scalarInt64(db, sql: """
        SELECT COUNT(*) FROM retained_byte_sources r
        WHERE r.disposition = 'unclaimed_recovery' AND NOT (
          r.kind = 'conversation_media' AND r.owner_conversation_id IS NULL
          AND r.storage_class = 'legacy_layout' AND r.storage_state = 'observed'
          AND r.link_state = 'current' AND r.retention_state = 'live'
          AND NOT EXISTS (
            SELECT 1 FROM retained_byte_references ref
            WHERE ref.retained_source_identity = r.source_identity))
        """)
        guard malformedUnclaimed == 0 else {
            throw LibraryBackupServiceError.verification(
                "unclaimed recovery bytes assert ownership or an unsupported storage state")
        }
        let sql = """
        SELECT r.source_identity, r.storage_identity, r.kind, r.owner_conversation_id,
               r.storage_name, r.media_type, r.retention_state, r.byte_count, r.digest,
               ref.reference_id, ref.owner_kind, ref.owner_conversation_id,
               ref.owner_event_id, ref.reference_kind, r.disposition
        FROM retained_byte_sources r
        JOIN retained_byte_references ref ON ref.retained_source_identity = r.source_identity
        WHERE r.storage_class = 'legacy_layout' AND r.storage_state = 'adopted'
          AND r.link_state = 'current' AND r.disposition = 'referenced'
        ORDER BY r.source_identity, ref.reference_id
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else { throw sqliteError(db, "could not read retained-byte inventory") }
        defer { sqlite3_finalize(statement) }
        var rows: [String: DatabaseSnapshot.RetainedByte] = [:]
        var order: [String] = []
        while true {
            let result = sqlite3_step(statement)
            if result == SQLITE_DONE { break }
            guard result == SQLITE_ROW,
                  let sourceIdentity = text(statement, 0),
                  let storageIdentity = text(statement, 1),
                  let kind = text(statement, 2),
                  let storageName = text(statement, 4),
                  let mediaType = text(statement, 5),
                  let retentionState = text(statement, 6),
                  let digest = text(statement, 8), isSHA256(digest),
                  let rawReferenceID = text(statement, 9),
                  let referenceID = UUID(uuidString: rawReferenceID),
                  let ownerKind = text(statement, 10),
                  let rawReferenceOwner = text(statement, 11),
                  let referenceOwner = UUID(uuidString: rawReferenceOwner),
                  let referenceKind = text(statement, 13),
                  let disposition = text(statement, 14) else {
                throw LibraryBackupServiceError.verification("retained-byte row is invalid")
            }
            let owner = text(statement, 3).flatMap(UUID.init(uuidString:))
            guard owner == referenceOwner else {
                throw LibraryBackupServiceError.verification(
                    "retained-byte owner disagrees with its reference")
            }
            let byteCount = sqlite3_column_int64(statement, 7)
            let reference = LibraryBackupManifest.RetainedReference(
                referenceID: referenceID,
                ownerKind: ownerKind,
                ownerConversationID: referenceOwner,
                ownerOperationID: nil,
                ownerEventID: text(statement, 12).flatMap(UUID.init(uuidString:)),
                referenceKind: referenceKind)
            if var existing = rows[sourceIdentity] {
                guard existing.storageIdentity == storageIdentity,
                      existing.sha256 == digest,
                      existing.byteCount == byteCount else {
                    throw LibraryBackupServiceError.verification(
                        "retained-byte source has inconsistent rows")
                }
                existing.references.append(reference)
                rows[sourceIdentity] = existing
            } else {
                order.append(sourceIdentity)
                rows[sourceIdentity] = DatabaseSnapshot.RetainedByte(
                    sourceIdentity: sourceIdentity,
                    storageIdentity: storageIdentity,
                    kind: kind,
                    ownerConversationID: owner,
                    ownerOperationID: nil,
                    storageName: storageName,
                    mediaType: mediaType,
                    retentionState: retentionState,
                    disposition: disposition,
                    byteCount: byteCount,
                    sha256: digest.lowercased(),
                    references: [reference])
            }
        }
        let unclaimedSQL = """
        SELECT source_identity, storage_identity, kind, storage_name, media_type,
               retention_state, byte_count, digest, disposition
        FROM retained_byte_sources
        WHERE disposition = 'unclaimed_recovery'
        ORDER BY source_identity
        """
        var unclaimedStatement: OpaquePointer?
        guard sqlite3_prepare_v2(db, unclaimedSQL, -1, &unclaimedStatement, nil) == SQLITE_OK,
              let unclaimedStatement else {
            throw sqliteError(db, "could not read unclaimed recovery inventory")
        }
        defer { sqlite3_finalize(unclaimedStatement) }
        while true {
            let result = sqlite3_step(unclaimedStatement)
            if result == SQLITE_DONE { break }
            guard result == SQLITE_ROW,
                  let sourceIdentity = text(unclaimedStatement, 0),
                  let storageIdentity = text(unclaimedStatement, 1),
                  let kind = text(unclaimedStatement, 2),
                  let storageName = text(unclaimedStatement, 3),
                  let mediaType = text(unclaimedStatement, 4),
                  let retentionState = text(unclaimedStatement, 5),
                  let digest = text(unclaimedStatement, 7), isSHA256(digest),
                  let disposition = text(unclaimedStatement, 8),
                  rows[sourceIdentity] == nil else {
                throw LibraryBackupServiceError.verification(
                    "unclaimed recovery row is invalid or duplicated")
            }
            order.append(sourceIdentity)
            rows[sourceIdentity] = DatabaseSnapshot.RetainedByte(
                sourceIdentity: sourceIdentity,
                storageIdentity: storageIdentity,
                kind: kind,
                ownerConversationID: nil,
                ownerOperationID: nil,
                storageName: storageName,
                mediaType: mediaType,
                retentionState: retentionState,
                disposition: disposition,
                byteCount: sqlite3_column_int64(unclaimedStatement, 6),
                sha256: digest.lowercased(),
                references: [])
        }
        let operationSQL = """
        SELECT retained.source_identity, retained.storage_identity, retained.kind,
               retained.media_type, retained.retention_state, retained.byte_count,
               retained.digest, retained.operation_id, retained.reference_kind
        FROM operation_retained_sources retained
        JOIN operations operation ON operation.id = retained.operation_id
        JOIN migration_sources receipt
          ON receipt.domain = 'operations'
         AND receipt.source_identity = retained.source_identity
        WHERE receipt.dirty = 0 AND receipt.import_state = 'current'
          AND receipt.observed_revision = receipt.imported_revision
          AND receipt.observed_digest = receipt.imported_digest
        ORDER BY retained.source_identity
        """
        var operationStatement: OpaquePointer?
        guard sqlite3_prepare_v2(db, operationSQL, -1, &operationStatement, nil) == SQLITE_OK,
              let operationStatement else {
            throw sqliteError(db, "could not read operation-retained inventory")
        }
        defer { sqlite3_finalize(operationStatement) }
        while true {
            let result = sqlite3_step(operationStatement)
            if result == SQLITE_DONE { break }
            guard result == SQLITE_ROW,
                  let sourceIdentity = text(operationStatement, 0),
                  let storageIdentity = text(operationStatement, 1),
                  let kind = text(operationStatement, 2),
                  let mediaType = text(operationStatement, 3),
                  let retentionState = text(operationStatement, 4),
                  let digest = text(operationStatement, 6), isSHA256(digest),
                  let rawOperationID = text(operationStatement, 7),
                  let operationID = UUID(uuidString: rawOperationID),
                  let referenceKind = text(operationStatement, 8) else {
                throw LibraryBackupServiceError.verification(
                    "operation-retained row is invalid")
            }
            guard rows[sourceIdentity] == nil else {
                throw LibraryBackupServiceError.verification(
                    "retained byte has duplicate live and operation owners: \(sourceIdentity)")
            }
            order.append(sourceIdentity)
            rows[sourceIdentity] = DatabaseSnapshot.RetainedByte(
                sourceIdentity: sourceIdentity,
                storageIdentity: storageIdentity,
                kind: kind,
                ownerConversationID: nil,
                ownerOperationID: operationID,
                storageName: URL(fileURLWithPath: storageIdentity).lastPathComponent,
                mediaType: mediaType,
                retentionState: retentionState,
                disposition: "undo_recovery",
                byteCount: sqlite3_column_int64(operationStatement, 5),
                sha256: digest.lowercased(),
                references: [LibraryBackupManifest.RetainedReference(
                    referenceID: operationID,
                    ownerKind: "operation",
                    ownerConversationID: nil,
                    ownerOperationID: operationID,
                    ownerEventID: nil,
                    referenceKind: referenceKind)])
        }
        return try order.map {
            guard var row = rows[$0] else {
                throw LibraryBackupServiceError.verification("retained-byte grouping failed")
            }
            row.references.sort { $0.referenceID.uuidString < $1.referenceID.uuidString }
            return row
        }
    }

    static func onlineBackup(source: URL, destination: URL) throws {
        guard FileManager.default.createFile(
            atPath: destination.path,
            contents: nil,
            attributes: [.posixPermissions: 0o600]) else {
            throw LibraryBackupServiceError.permissions("could not create backup database")
        }
        var sourceDB: OpaquePointer?
        var destinationDB: OpaquePointer?
        guard sqlite3_open_v2(
            source.path, &sourceDB, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK,
              let sourceDB else {
            if let sourceDB { sqlite3_close(sourceDB) }
            throw LibraryBackupServiceError.sqlite("could not open source database read-only")
        }
        defer { sqlite3_close(sourceDB) }
        guard sqlite3_open_v2(
            destination.path, &destinationDB, SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK,
              let destinationDB else {
            if let destinationDB { sqlite3_close(destinationDB) }
            throw LibraryBackupServiceError.sqlite("could not open backup database")
        }
        defer { sqlite3_close(destinationDB) }
        guard let handle = sqlite3_backup_init(destinationDB, "main", sourceDB, "main") else {
            throw sqliteError(destinationDB, "could not initialize online backup")
        }
        var attempts = 0
        var finalResult: Int32 = SQLITE_OK
        while true {
            let result = sqlite3_backup_step(handle, 256)
            if result == SQLITE_DONE {
                finalResult = result
                break
            }
            if result == SQLITE_OK { continue }
            if result == SQLITE_BUSY || result == SQLITE_LOCKED {
                attempts += 1
                guard attempts <= maximumBusyAttempts else {
                    finalResult = result
                    break
                }
                usleep(10_000)
                continue
            }
            finalResult = result
            break
        }
        let finishResult = sqlite3_backup_finish(handle)
        guard finalResult == SQLITE_DONE, finishResult == SQLITE_OK else {
            throw sqliteError(destinationDB, "online backup did not complete")
        }
    }

    static func copyRelativeOwnerOnlyFile(
        rootFD: Int32,
        relativePath: String,
        destination: URL,
        requiredSourcePermissions: mode_t? = nil
    ) throws -> FileDigest {
        let components = try safeRelativeComponents(relativePath)
        var directoryFD = dup(rootFD)
        guard directoryFD >= 0 else { throw posixPermissions("could not duplicate root descriptor") }
        defer { Darwin.close(directoryFD) }
        try requireOwnerOnlyDescriptor(directoryFD, directory: true, label: "support root")
        for component in components.dropLast() {
            let next = component.withCString {
                openat(directoryFD, $0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            }
            guard next >= 0 else {
                throw posixPermissions("could not open retained-byte directory \(component)")
            }
            Darwin.close(directoryFD)
            directoryFD = next
            try requireOwnerOnlyDescriptor(directoryFD, directory: true, label: component)
        }
        guard let filename = components.last else {
            throw LibraryBackupServiceError.invalidInput("retained-byte path is empty")
        }
        let sourceFD = filename.withCString {
            openat(directoryFD, $0, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        }
        guard sourceFD >= 0 else {
            throw posixPermissions("could not open retained byte \(relativePath)")
        }
        defer { Darwin.close(sourceFD) }
        try requireOwnerOnlyDescriptor(sourceFD, directory: false, label: relativePath)
        if let requiredSourcePermissions {
            var sourceMetadata = stat()
            guard fstat(sourceFD, &sourceMetadata) == 0,
                  sourceMetadata.st_mode & 0o777 == requiredSourcePermissions else {
                throw LibraryBackupServiceError.verification(
                    "unclaimed recovery byte is not owner-read-only: \(relativePath)")
            }
        }
        return try transfer(sourceFD: sourceFD, destination: destination)
    }

    /// Returns one verified immutable object in the shared pool. Publication uses an exclusive
    /// hard link rather than a replacing rename: concurrent creators may race, but an existing
    /// object is never overwritten and the winner is always re-verified before it is reused. The
    /// inode is owner-read-only before publication because every generation link shares its mode.
    static func verifiedPooledObject(
        rootFD: Int32,
        relativePath: String,
        destination: URL,
        expectedByteCount: Int64,
        expectedSHA256: String,
        requiredSourcePermissions: mode_t? = nil
    ) throws -> FileDigest {
        if FileManager.default.fileExists(atPath: destination.path) {
            return try verifyAndProtectPooledObject(
                destination,
                expectedByteCount: expectedByteCount,
                expectedSHA256: expectedSHA256)
        }

        let temporary = destination.deletingLastPathComponent().appendingPathComponent(
            ".\(destination.lastPathComponent).staging-\(UUID().uuidString)",
            isDirectory: false)
        defer {
            if FileManager.default.fileExists(atPath: temporary.path) {
                try? FileManager.default.removeItem(at: temporary)
            }
        }
        let copied = try copyRelativeOwnerOnlyFile(
            rootFD: rootFD,
            relativePath: relativePath,
            destination: temporary,
            requiredSourcePermissions: requiredSourcePermissions)
        guard copied.byteCount == expectedByteCount,
              copied.sha256.caseInsensitiveCompare(expectedSHA256) == .orderedSame else {
            throw LibraryBackupServiceError.verification(
                "retained byte changed or disagrees with library.db: \(relativePath)")
        }
        _ = try verifyAndProtectPooledObject(
            temporary,
            expectedByteCount: expectedByteCount,
            expectedSHA256: expectedSHA256)

        let publishResult = Darwin.link(temporary.path, destination.path)
        if publishResult != 0, errno != EEXIST {
            throw posixPermissions("could not publish shared backup object")
        }
        return try verifyAndProtectPooledObject(
            destination,
            expectedByteCount: expectedByteCount,
            expectedSHA256: expectedSHA256)
    }

    static func hardLinkVerifiedObject(
        source: URL,
        destination: URL,
        expectedByteCount: Int64,
        expectedSHA256: String
    ) throws {
        try requireImmutablePooledObject(source, label: "shared backup object")
        let sourceDigest = try digestRegularFile(source, requireOwnerOnly: true)
        guard sourceDigest.byteCount == expectedByteCount,
              sourceDigest.sha256.caseInsensitiveCompare(expectedSHA256) == .orderedSame else {
            throw LibraryBackupServiceError.verification(
                "shared backup object changed before generation publication")
        }
        guard Darwin.link(source.path, destination.path) == 0 else {
            throw posixPermissions("could not link shared object into backup generation")
        }
        let linkedDigest = try digestRegularFile(destination, requireOwnerOnly: true)
        guard linkedDigest.byteCount == expectedByteCount,
              linkedDigest.sha256.caseInsensitiveCompare(expectedSHA256) == .orderedSame else {
            throw LibraryBackupServiceError.verification(
                "linked backup object does not match its manifest")
        }
        try requireImmutablePooledObject(destination, label: "linked backup object")
    }

    /// Verifies bytes before changing a legacy 0600 pool inode, then upgrades that inode (and all
    /// generation hard links to it) to 0400 and verifies it again. A corrupt pre-existing object is
    /// rejected without changing its contents or permissions.
    static func verifyAndProtectPooledObject(
        _ url: URL,
        expectedByteCount: Int64,
        expectedSHA256: String
    ) throws -> FileDigest {
        let before = try digestRegularFile(url, requireOwnerOnly: true)
        guard before.byteCount == expectedByteCount,
              before.sha256.caseInsensitiveCompare(expectedSHA256) == .orderedSame else {
            throw LibraryBackupServiceError.verification(
                "shared backup object disagrees with library.db: \(url.lastPathComponent)")
        }
        try setImmutablePooledObject(url)
        let protected = try digestRegularFile(url, requireOwnerOnly: true)
        guard protected.byteCount == expectedByteCount,
              protected.sha256.caseInsensitiveCompare(expectedSHA256) == .orderedSame else {
            throw LibraryBackupServiceError.verification(
                "protected shared backup object disagrees with library.db")
        }
        try requireImmutablePooledObject(url, label: "shared backup object")
        return protected
    }

    static func transfer(sourceFD: Int32, destination: URL) throws -> FileDigest {
        let destinationFD = Darwin.open(
            destination.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, mode_t(0o600))
        guard destinationFD >= 0 else {
            throw posixPermissions("could not create \(destination.lastPathComponent)")
        }
        defer { Darwin.close(destinationFD) }
        var before = stat()
        guard fstat(sourceFD, &before) == 0,
              before.st_mode & S_IFMT == S_IFREG,
              before.st_size >= 0 else {
            throw LibraryBackupServiceError.verification("source is not a regular file")
        }
        var hasher = SHA256()
        var total: Int64 = 0
        var buffer = [UInt8](repeating: 0, count: transferBufferBytes)
        while true {
            let count = buffer.withUnsafeMutableBytes { pointer in
                while true {
                    let result = Darwin.read(sourceFD, pointer.baseAddress, pointer.count)
                    if result < 0 && errno == EINTR { continue }
                    return result
                }
            }
            guard count >= 0 else { throw posixPermissions("could not read retained byte") }
            if count == 0 { break }
            hasher.update(data: Data(buffer.prefix(count)))
            total += Int64(count)
            var written = 0
            while written < count {
                let result = buffer.withUnsafeBytes { pointer in
                    Darwin.write(
                        destinationFD,
                        pointer.baseAddress?.advanced(by: written),
                        count - written)
                }
                if result < 0 && errno == EINTR { continue }
                guard result > 0 else { throw posixPermissions("could not write retained byte") }
                written += result
            }
        }
        var after = stat()
        guard fstat(sourceFD, &after) == 0,
              before.st_dev == after.st_dev,
              before.st_ino == after.st_ino,
              before.st_size == after.st_size,
              before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
              before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
              before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec,
              before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec,
              total == Int64(before.st_size) else {
            throw LibraryBackupServiceError.verification(
                "retained byte changed during backup")
        }
        guard fsync(destinationFD) == 0 else {
            throw posixPermissions("could not sync retained backup object")
        }
        return FileDigest(
            byteCount: total,
            sha256: hasher.finalize().map { String(format: "%02x", $0) }.joined())
    }

    static func copyVerifiedFile(
        source: URL,
        destination: URL,
        expectedByteCount: Int64,
        expectedSHA256: String
    ) throws {
        try requireOwnerOnlyRegularFile(source, label: source.lastPathComponent)
        let sourceFD = Darwin.open(source.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard sourceFD >= 0 else { throw posixPermissions("could not open backup object") }
        defer { Darwin.close(sourceFD) }
        let copied = try transfer(sourceFD: sourceFD, destination: destination)
        guard copied.byteCount == expectedByteCount,
              copied.sha256.caseInsensitiveCompare(expectedSHA256) == .orderedSame else {
            throw LibraryBackupServiceError.verification(
                "copied backup object does not match its manifest")
        }
    }

    static func digestRegularFile(_ url: URL, requireOwnerOnly: Bool) throws -> FileDigest {
        if requireOwnerOnly { try requireOwnerOnlyRegularFile(url, label: url.lastPathComponent) }
        let descriptor = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw posixPermissions("could not open \(url.lastPathComponent)") }
        defer { Darwin.close(descriptor) }
        var before = stat()
        guard fstat(descriptor, &before) == 0,
              before.st_mode & S_IFMT == S_IFREG,
              before.st_size >= 0 else {
            throw LibraryBackupServiceError.verification("file is not regular")
        }
        var hasher = SHA256()
        var total: Int64 = 0
        var buffer = [UInt8](repeating: 0, count: transferBufferBytes)
        while true {
            let count = buffer.withUnsafeMutableBytes { pointer in
                while true {
                    let result = Darwin.read(descriptor, pointer.baseAddress, pointer.count)
                    if result < 0 && errno == EINTR { continue }
                    return result
                }
            }
            guard count >= 0 else { throw posixPermissions("could not read \(url.lastPathComponent)") }
            if count == 0 { break }
            hasher.update(data: Data(buffer.prefix(count)))
            total += Int64(count)
        }
        var after = stat()
        guard fstat(descriptor, &after) == 0,
              before.st_dev == after.st_dev,
              before.st_ino == after.st_ino,
              before.st_size == after.st_size,
              before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
              before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
              total == Int64(before.st_size) else {
            throw LibraryBackupServiceError.verification("file changed while being checksummed")
        }
        return FileDigest(
            byteCount: total,
            sha256: hasher.finalize().map { String(format: "%02x", $0) }.joined())
    }

    static func encodeManifest(_ manifest: LibraryBackupManifest) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        do { return try encoder.encode(manifest) }
        catch {
            throw LibraryBackupServiceError.verification(
                "manifest could not be encoded: \(error.localizedDescription)")
        }
    }

    static func writeOwnerOnly(_ data: Data, to url: URL) throws {
        guard FileManager.default.createFile(
            atPath: url.path, contents: data, attributes: [.posixPermissions: 0o600]) else {
            throw LibraryBackupServiceError.permissions("could not write \(url.lastPathComponent)")
        }
        try setOwnerOnlyFile(url)
    }

    static func safeDestination(root: URL, relativePath: String) throws -> URL {
        let components = try safeRelativeComponents(relativePath)
        return components.reduce(root) { partial, component in
            partial.appendingPathComponent(component, isDirectory: false)
        }
    }

    static func safeRelativeComponents(_ path: String) throws -> [String] {
        guard !path.isEmpty, !path.hasPrefix("/"), !path.contains("\0") else {
            throw LibraryBackupServiceError.verification("retained-byte path is not relative")
        }
        let components = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            throw LibraryBackupServiceError.verification("retained-byte path escapes its support root")
        }
        return components
    }

    static func prepareOwnerOnlyParents(of file: URL, beneath root: URL) throws {
        let rootPath = root.standardizedFileURL.path
        var current = file.deletingLastPathComponent()
        var missing: [URL] = []
        while current.standardizedFileURL.path != rootPath {
            guard isDescendant(current, of: root) else {
                throw LibraryBackupServiceError.verification("restore path escapes isolated root")
            }
            if FileManager.default.fileExists(atPath: current.path) { break }
            missing.append(current)
            current.deleteLastPathComponent()
        }
        for directory in missing.reversed() { try createOwnerOnlyDirectory(directory) }
    }

    static func prepareDestinationParent(_ parent: URL) throws {
        if FileManager.default.fileExists(atPath: parent.path) {
            try requireOwnerOnlyDirectory(parent, label: "destination parent")
        } else {
            do {
                try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
                try setOwnerOnlyDirectory(parent)
            } catch {
                throw LibraryBackupServiceError.permissions(
                    "could not create destination parent: \(error.localizedDescription)")
            }
        }
    }

    static func prepareSharedObjectPool(_ pool: URL) throws {
        let parent = pool.deletingLastPathComponent()
        try prepareDestinationParent(parent)
        try prepareOwnerOnlyDirectory(pool, label: "shared backup object pool")
    }

    /// Creates the directory private, and refuses an existing one that is not — see the same method
    /// on `LibraryBackupLifecycle` for why backup directories are refused rather than repaired.
    static func prepareOwnerOnlyDirectory(_ url: URL, label: String) throws {
        if FileManager.default.fileExists(atPath: url.path) {
            try requireOwnerOnlyDirectory(url, label: label)
        } else {
            try createOwnerOnlyDirectory(url)
        }
    }

    static func makePrivateOwnedDirectory(_ url: URL, label: String) throws {
        if let reason = OwnerOnlyDirectory.makePrivateReason(url, label: label) {
            throw LibraryBackupServiceError.permissions(reason)
        }
    }

    static func createOwnerOnlyDirectory(_ url: URL) throws {
        do {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
            try setOwnerOnlyDirectory(url)
        } catch {
            throw LibraryBackupServiceError.permissions(
                "could not create \(url.lastPathComponent): \(error.localizedDescription)")
        }
    }

    static func setOwnerOnlyDirectory(_ url: URL) throws {
        do {
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        } catch {
            throw LibraryBackupServiceError.permissions(
                "could not protect \(url.lastPathComponent): \(error.localizedDescription)")
        }
    }

    static func setOwnerOnlyFile(_ url: URL) throws {
        do {
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch {
            throw LibraryBackupServiceError.permissions(
                "could not protect \(url.lastPathComponent): \(error.localizedDescription)")
        }
    }

    static func setImmutablePooledObject(_ url: URL) throws {
        let descriptor = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else {
            throw posixPermissions("could not open shared backup object for protection")
        }
        defer { Darwin.close(descriptor) }
        try requireOwnerOnlyDescriptor(
            descriptor,
            directory: false,
            label: "shared backup object")
        guard fchmod(descriptor, immutablePooledObjectMode) == 0 else {
            throw posixPermissions("could not make shared backup object owner-read-only")
        }
        guard fsync(descriptor) == 0 else {
            throw posixPermissions("could not sync protected shared backup object")
        }
        var value = stat()
        guard fstat(descriptor, &value) == 0,
              value.st_mode & S_IFMT == S_IFREG,
              value.st_mode & mode_t(0o777) == immutablePooledObjectMode else {
            throw LibraryBackupServiceError.permissions(
                "shared backup object must be a 0400 regular file")
        }
    }

    /// For a directory this app does not own, or is verifying rather than preparing.
    static func requireOwnerOnlyDirectory(_ url: URL, label: String) throws {
        if let reason = OwnerOnlyDirectory.requireReason(url, label: label) {
            throw LibraryBackupServiceError.permissions(reason)
        }
    }

    static func requireOwnerOnlyRegularFile(_ url: URL, label: String) throws {
        var value = stat()
        guard lstat(url.path, &value) == 0,
              value.st_mode & S_IFMT == S_IFREG,
              value.st_mode & 0o077 == 0 else {
            throw LibraryBackupServiceError.permissions("\(label) must be a 0600 non-symlink file")
        }
    }

    static func requireImmutablePooledObject(_ url: URL, label: String) throws {
        var value = stat()
        guard lstat(url.path, &value) == 0,
              value.st_mode & S_IFMT == S_IFREG,
              value.st_mode & mode_t(0o777) == immutablePooledObjectMode else {
            throw LibraryBackupServiceError.permissions(
                "\(label) must be a 0400 non-symlink regular file")
        }
    }

    static func requireOwnerOnlyDescriptor(
        _ descriptor: Int32,
        directory: Bool,
        label: String
    ) throws {
        var value = stat()
        let expected = directory ? S_IFDIR : S_IFREG
        guard fstat(descriptor, &value) == 0,
              value.st_mode & S_IFMT == expected,
              value.st_mode & 0o077 == 0 else {
            let mode = directory ? "0700 directory" : "0600 file"
            throw LibraryBackupServiceError.permissions("\(label) must be an owner-only \(mode)")
        }
    }

    static func isDescendant(_ candidate: URL, of root: URL) -> Bool {
        let rootPath = root.standardizedFileURL.path
        let candidatePath = candidate.standardizedFileURL.path
        return candidatePath == rootPath || candidatePath.hasPrefix(rootPath + "/")
    }

    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func isSHA256(_ value: String) -> Bool {
        value.count == 64 && value.allSatisfy { $0.isHexDigit }
    }

    static func text(_ statement: OpaquePointer, _ index: Int32) -> String? {
        guard sqlite3_column_type(statement, index) != SQLITE_NULL,
              let pointer = sqlite3_column_text(statement, index) else { return nil }
        return String(cString: pointer)
    }

    static func scalarInt64(_ db: OpaquePointer, sql: String) throws -> Int64 {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else { throw sqliteError(db, "could not prepare scalar query") }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else {
            throw sqliteError(db, "scalar query returned no row")
        }
        return sqlite3_column_int64(statement, 0)
    }

    static func scalarText(_ db: OpaquePointer, sql: String) throws -> String {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else { throw sqliteError(db, "could not prepare text query") }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW, let result = text(statement, 0) else {
            throw sqliteError(db, "text query returned no row")
        }
        return result
    }

    static func rowCount(_ db: OpaquePointer, sql: String) throws -> Int {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else { throw sqliteError(db, "could not prepare row query") }
        defer { sqlite3_finalize(statement) }
        var count = 0
        while true {
            let result = sqlite3_step(statement)
            if result == SQLITE_DONE { return count }
            guard result == SQLITE_ROW else { throw sqliteError(db, "row query failed") }
            count += 1
        }
    }

    static func sqliteError(_ db: OpaquePointer, _ context: String) -> LibraryBackupServiceError {
        .sqlite("\(context): \(String(cString: sqlite3_errmsg(db)))")
    }

    static func posixPermissions(_ context: String) -> LibraryBackupServiceError {
        let code = POSIXErrorCode(rawValue: errno)
        let detail = code.map { POSIXError($0).localizedDescription } ?? "errno \(errno)"
        return .permissions("\(context): \(detail)")
    }
}
