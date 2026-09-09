import Darwin
import Foundation

/// Creates the current SQLite authority for a genuinely empty installation.
///
/// This is not a migration. Any legacy library fact, malformed path, unknown database content, or
/// authority ambiguity is refused and left byte-for-byte untouched for the recovery screen. The
/// marker remains the final durable write, exactly as it is for every existing SQLite library.
enum SQLiteLibraryBootstrapService {
    enum Error: Swift.Error, Equatable, LocalizedError {
        case legacyLibrary(String)
        case verification(String)

        var errorDescription: String? {
            switch self {
            case .legacyLibrary(let path):
                return "This library has not completed the required SQLite update (found \(path)). "
                    + "Install and open Mechanician 0.26.21 before using this build."
            case .verification(let detail):
                return "The new SQLite library could not be verified: \(detail)"
            }
        }
    }

    /// Returns a fresh SQLite recognition for an unmarked pristine root. Existing recognized
    /// SQLite roots pass through unchanged; every other unmarked root throws and is fenced.
    static func provisionIfNeeded(
        recognition: StorageAuthorityRecognition,
        ownsProcessLease: Bool,
        now: () -> Date = Date.init
    ) throws -> StorageAuthorityRecognition {
        guard ownsProcessLease else { return recognition }
        guard case .absent = recognition.marker,
              case .legacyUnmarked(let database) = recognition.disposition else {
            return recognition
        }

        let root = recognition.anchorRoot.standardizedFileURL
        if let legacyPath = LegacyLibraryFootprint.firstFact(in: root) {
            throw Error.legacyLibrary(legacyPath)
        }

        let store: SQLiteLibraryStore
        let activationID: UUID
        switch database?.authorityState {
        case nil, .shadow:
            store = try SQLiteLibraryStore(supportRoot: root)
            try store.requirePristineBootstrapShape()
            let settings = HomeWorkspaceSettings(updatedAt: now())
            let home = try LibraryWorkspaceAdapter.capture(
                home: settings,
                source: .implicitHomeWorkspace)
            _ = try store.reconcile(ShadowLibraryImportSnapshot(
                home: home, workspaces: [], conversations: []))
            try store.requirePristineBootstrapShape()
            activationID = UUID()
            try store.prepareAuthority(
                activationID: activationID,
                minimumWriterBuild: StorageAuthorityProtocol.recognitionID)

        case .prepared, .active:
            guard let database,
                  let persistedActivationID = database.activationID,
                  database.minimumWriterBuild == StorageAuthorityProtocol.recognitionID else {
                throw Error.verification("interrupted bootstrap metadata is incomplete")
            }
            store = try SQLiteLibraryStore.openInterruptedAuthority(
                supportRoot: root, probe: database)
            try store.requirePristineBootstrapShape()
            activationID = persistedActivationID

        case .rollbackPrepared, .rolledBack:
            throw Error.verification("rollback state cannot bootstrap a new library")
        }

        let beforeActivation = try store.authorityMetadata()
        if beforeActivation.authorityState == .prepared {
            try store.activatePreparedAuthority(activationID: activationID)
        }
        let active = try store.authorityMetadata()
        let activeStatus = try store.status()
        guard active.authorityState == .active,
              active.activationID == activationID,
              active.rollbackID == nil,
              active.committedSequence == activeStatus.shadowChangeSequence else {
            throw Error.verification("database did not reach the exact active frontier")
        }

        try store.requirePristineBootstrapShape()
        guard let home = try store.workspaceSnapshot(id: SQLiteLibraryStore.homeWorkspaceID),
              case .home = try LibraryWorkspaceAdapter.reconstruct(from: home) else {
            throw Error.verification("empty authority does not reconstruct as Home")
        }

        let marker = StorageAuthorityMarker(
            mode: .sqlite,
            activationID: activationID,
            databaseInstanceID: active.databaseInstanceID,
            schemaVersion: active.schemaVersion,
            minimumWriterBuild: StorageAuthorityProtocol.recognitionID,
            createdAt: timestamp(now()))
        try StorageAuthorityMarkerStore.publish(marker, in: root)

        let fresh = StorageAuthorityRecognizer.inspect(supportRoot: root)
        guard case .sqlite(let observedMarker, let probe) = fresh.disposition,
              observedMarker == marker,
              probe.authorityState == .active,
              probe.databaseInstanceID == active.databaseInstanceID,
              probe.committedSequence == active.committedSequence,
              let repository = try LibraryAuthorityRepository.open(recognition: fresh) else {
            throw Error.verification("marker-last publication did not reopen as SQLite authority")
        }
        let inventory = try repository.launchInventory()
        guard inventory.databaseInstanceID == active.databaseInstanceID,
              inventory.committedSequence == active.committedSequence,
              inventory.workspaces.isEmpty,
              inventory.conversations.isEmpty,
              inventory.intrinsicConversations.isEmpty,
              inventory.artifacts.isEmpty else {
            throw Error.verification("opened inventory is not the empty authority just published")
        }
        return fresh
    }

    private static func timestamp(_ date: Date) -> String {
        SendableISO8601Formatter.fractional.string(from: date)
    }
}

/// A conservative census of every path that has ever owned a legacy library fact. Existence is
/// enough: empty, unreadable, symlinked, or wrong-type paths are evidence, not permission to erase.
enum LegacyLibraryFootprint {
    private static let exactNames = [
        "conversations", "workspaces", "projects", "workspaces.json",
        "home-workspace.json", "artifacts", "ambient", "ambient-projection",
        "conversation-media", "trash", "authority-inbox",
    ]

    static func firstFact(in supportRoot: URL) -> String? {
        let root = supportRoot.standardizedFileURL
        for name in exactNames {
            var status = stat()
            let path = root.appendingPathComponent(name).path
            if lstat(path, &status) == 0 || errno != ENOENT { return name }
        }

        // Corrupt/quarantined Home records carry suffixes, so checking only the canonical name
        // would misclassify the one case whose bytes most need preservation.
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: root.path) else {
            return "an unreadable support root"
        }
        return names.sorted().first(where: {
            $0.hasPrefix("home-workspace.json.") || $0.hasPrefix("home-workspace.json-")
        })
    }
}
