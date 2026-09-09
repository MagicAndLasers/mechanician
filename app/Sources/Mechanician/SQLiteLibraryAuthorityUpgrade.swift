import Foundation

/// Carries an existing active `library.db` across a schema-version bump.
///
/// ## Why this exists
///
/// Until 2026-08-14 nothing did. The migration ladder in `SQLiteLibraryStore` only runs on the
/// shadow-open path, whose first guard requires `authority_state == "shadow"`, and a real user's
/// library is an *active* authority. The active opener instead asserts
/// `marker.schemaVersion == Self.schemaVersion` exactly. So bumping `schemaVersion` moved a gate
/// that every launch must pass and left no path through it: schema v7 shipped and every machine
/// with an existing library opened to the Storage Recovery screen. It was reverted the same day.
///
/// `schemaVersion` was born at 6 and every library in existence was provisioned fresh at 6, so the
/// ladder had never once run in production. The code meant to carry a library forward had no
/// callers, no coverage, and — for the active case — did not exist.
///
/// ## The shape of the fix
///
/// Never mutate the live database. Copy it, migrate the copy, prove the copy, then swap. Any
/// failure before the swap costs a temporary file and leaves the original openable by the older
/// build. The identity of the authority is preserved through the migration, so the existing marker
/// is republished with only its version integer changed rather than a new authority being minted.
///
/// ## The one interruption window
///
/// Two files have to change together — `library.db` and `storage-authority.json` — and no
/// filesystem makes that atomic. The database is swapped first and the marker republished second,
/// so the only reachable intermediate state is "new database, stale marker". That state is
/// recognized by `StorageAuthorityRecognizer.assessUpgrade` as `.republishMarker` and finished on
/// the next launch. The reverse order was rejected because a marker naming a schema the database
/// does not have is indistinguishable from corruption.
enum SQLiteLibraryAuthorityUpgrade {
    enum UpgradeError: Error, LocalizedError, Equatable {
        case unsupported(String)
        case failed(String)

        var errorDescription: String? {
            switch self {
            case .unsupported(let message): return message
            case .failed(let message): return message
            }
        }
    }

    /// The outcome, for logging and for tests. Deliberately not thrown: a refusal to upgrade is a
    /// normal answer, and the caller decides whether it blocks launch.
    enum Outcome: Equatable {
        case notNeeded
        case upgraded(from: Int, to: Int)
        case markerRepublished(from: Int, to: Int)
        case unsupported(String)
        case failed(String)
    }

    /// Carry the root's authority forward if it needs it, and return the recognition to launch with.
    ///
    /// Read-only and cheap when there is nothing to do, which is every launch after the first one
    /// following an update.
    /// - Parameter ownsProcessLease: the caller must already hold the root's writer lease. This is
    ///   not a courtesy: the upgrade replaces `library.db`, and a second instance opening the same
    ///   root mid-swap is the one thing that could turn a recoverable failure into a lost library.
    ///   The lease is a process singleton taken by `recognizeCurrentProcess`, so this asks the
    ///   caller to prove it rather than taking a second one.
    @discardableResult
    static func upgradeIfNeeded(
        supportRoot: URL,
        ownsProcessLease: Bool,
        now: () -> Date = Date.init
    ) -> (recognition: StorageAuthorityRecognition, outcome: Outcome) {
        let root = supportRoot.standardizedFileURL
        guard ownsProcessLease else {
            return (StorageAuthorityRecognizer.inspect(supportRoot: root), .notNeeded)
        }
        let assessment = StorageAuthorityRecognizer.assessUpgrade(supportRoot: root)
        switch assessment {
        case .notNeeded:
            return (StorageAuthorityRecognizer.inspect(supportRoot: root), .notNeeded)

        case .unsupported(let message):
            return (StorageAuthorityRecognizer.inspect(supportRoot: root), .unsupported(message))

        case .republishMarker(let marker, let probe):
            do {
                try republish(marker: marker, probe: probe, in: root, now: now)
                return (
                    StorageAuthorityRecognizer.inspect(supportRoot: root),
                    .markerRepublished(from: marker.schemaVersion, to: probe.schemaVersion))
            } catch {
                return (
                    StorageAuthorityRecognizer.inspect(supportRoot: root),
                    .failed(error.localizedDescription))
            }

        case .migrate(let marker, let probe):
            do {
                try migrate(marker: marker, probe: probe, in: root, now: now)
                return (
                    StorageAuthorityRecognizer.inspect(supportRoot: root),
                    .upgraded(from: probe.schemaVersion, to: SQLiteLibraryStore.schemaVersion))
            } catch {
                // The original is still in place: everything destructive happens after the copy is
                // proven. Report the failure and let launch block, which is the same outcome as
                // before this existed — never a half-migrated library.
                return (
                    StorageAuthorityRecognizer.inspect(supportRoot: root),
                    .failed(error.localizedDescription))
            }
        }
    }

    // MARK: - Steps

    private static func migrate(
        marker: StorageAuthorityMarker,
        probe: StorageAuthorityDatabaseProbe,
        in root: URL,
        now: () -> Date
    ) throws {
        let database = root.appendingPathComponent(StorageAuthorityProtocol.databaseName)
        let working = root.appendingPathComponent(
            "\(StorageAuthorityProtocol.databaseName).upgrade-\(UUID().uuidString)")
        removeDatabaseFiles(at: working)

        do {
            // `onlineBackup` reads through the WAL, so this is a consistent snapshot without
            // taking the live database offline or trusting a byte copy of a file with a journal.
            try LibraryBackupService.copyDatabase(source: database, destination: working)
            try SQLiteLibraryStore.upgradeCopiedActiveAuthority(at: working, expecting: probe)
        } catch {
            removeDatabaseFiles(at: working)
            throw UpgradeError.failed(
                "the library could not be upgraded to schema v\(SQLiteLibraryStore.schemaVersion): \(error.localizedDescription)")
        }

        // Everything below is destructive, and everything above proved the replacement first.
        let superseded = root.appendingPathComponent(
            "\(StorageAuthorityProtocol.databaseName).superseded-v\(probe.schemaVersion)-\(timestamp(now()))")
        do {
            try swap(original: database, replacement: working, superseded: superseded)
        } catch {
            removeDatabaseFiles(at: working)
            throw UpgradeError.failed(
                "the upgraded library could not replace the original: \(error.localizedDescription)")
        }
        // The file behind any cached repository handle for this root has just been renamed away.
        // The registry key survives the swap because the activation id does, so it must be dropped
        // explicitly or the next caller is served a store pointing at the superseded file.
        LibraryAuthorityRepository.forget(supportRoot: root)

        // From here the database is the new one and the marker is stale. A crash lands in
        // `.republishMarker` and is finished on the next launch.
        try republish(marker: marker, probe: probe, in: root, now: now)
    }

    /// Publish the existing marker with only its schema version moved forward.
    ///
    /// A new marker is NOT minted. `activationID` and `databaseInstanceID` carry over because the
    /// upgraded database is the same authority — a new identity here would look to every other
    /// check like the library had been replaced.
    private static func republish(
        marker: StorageAuthorityMarker,
        probe: StorageAuthorityDatabaseProbe,
        in root: URL,
        now: () -> Date
    ) throws {
        let upgraded = StorageAuthorityMarker(
            mode: .sqlite,
            activationID: marker.activationID,
            databaseInstanceID: marker.databaseInstanceID,
            schemaVersion: SQLiteLibraryStore.schemaVersion,
            minimumWriterBuild: marker.minimumWriterBuild,
            createdAt: SendableISO8601Formatter.fractional.string(from: now()))
        try StorageAuthorityMarkerStore.publish(upgraded, in: root)

        // Prove the pair the way launch will, before returning success.
        let fresh = StorageAuthorityRecognizer.inspect(supportRoot: root)
        guard case .sqlite(let observed, let observedProbe) = fresh.disposition,
              observed == upgraded,
              observedProbe.authorityState == .active,
              observedProbe.schemaVersion == SQLiteLibraryStore.schemaVersion,
              observedProbe.databaseInstanceID == probe.databaseInstanceID,
              observedProbe.activationID == probe.activationID else {
            throw UpgradeError.failed(
                "the upgraded library did not re-recognize as the active SQLite authority")
        }
    }

    /// Move the original aside and the replacement in.
    ///
    /// The sidecar journals move with their database. A `-wal` left behind would be adopted by the
    /// replacement that arrives under the same name, which is a corrupt pairing rather than a
    /// missing file.
    private static func swap(original: URL, replacement: URL, superseded: URL) throws {
        let manager = FileManager.default
        try manager.moveItem(at: original, to: superseded)
        for suffix in ["-wal", "-shm"] {
            let from = URL(fileURLWithPath: original.path + suffix)
            guard manager.fileExists(atPath: from.path) else { continue }
            try? manager.moveItem(at: from, to: URL(fileURLWithPath: superseded.path + suffix))
        }
        do {
            try manager.moveItem(at: replacement, to: original)
        } catch {
            // Put the original back rather than leaving the root with no database at all.
            try? manager.moveItem(at: superseded, to: original)
            for suffix in ["-wal", "-shm"] {
                let parked = URL(fileURLWithPath: superseded.path + suffix)
                guard manager.fileExists(atPath: parked.path) else { continue }
                try? manager.moveItem(at: parked, to: URL(fileURLWithPath: original.path + suffix))
            }
            throw error
        }
        for suffix in ["-wal", "-shm"] {
            let from = URL(fileURLWithPath: replacement.path + suffix)
            guard manager.fileExists(atPath: from.path) else { continue }
            try? manager.moveItem(at: from, to: URL(fileURLWithPath: original.path + suffix))
        }
    }

    private static func removeDatabaseFiles(at url: URL) {
        let manager = FileManager.default
        for path in [url.path, url.path + "-wal", url.path + "-shm"] {
            try? manager.removeItem(atPath: path)
        }
    }

    /// Filename-safe, deliberately NOT the marker's ISO form. The marker must carry a timestamp
    /// `markerValidationProblem` accepts; a retained database beside it must carry one that is
    /// pleasant in a path a human may have to move around.
    private static func timestamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        return formatter.string(from: date)
    }
}
