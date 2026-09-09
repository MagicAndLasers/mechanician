import Darwin
import Foundation

/// The bounded, non-authoritative record of the latest installed backup attempt that published a
/// complete generation. The generation manifest remains the recovery authority; this small receipt
/// exists so launch/status code never has to decode an unbounded retained-byte manifest.
struct LibraryBackupLifecycleReceipt: Codable, Equatable, Sendable {
    static let currentFormatVersion = 2

    let formatVersion: Int
    let backupID: UUID
    let createdAt: String
    let generationName: String
    let manifestSHA256: String
    let databaseInstanceID: UUID
    let schemaVersion: Int
    let shadowChangeSequence: Int64
    let restoreVerifiedAt: String
    let retainedByteCount: Int
    let retainedBytes: Int64
}

struct LibraryBackupLifecycleResult: Equatable, Sendable {
    enum Disposition: String, Equatable, Sendable {
        case created
        case skippedRecentGeneration
    }

    let disposition: Disposition
    let backupRoot: URL
    let generationURL: URL
    let receipt: LibraryBackupLifecycleReceipt?
    /// Present only when this call created and fully restored the generation. A skipped recent
    /// generation must be re-verified by a cutover caller because its prior receipt is not proof
    /// that the retained files remain intact now.
    let verifiedRestoreReport: LibraryBackupRestoreReport?
}

/// The exact database generation that a readiness backup must cover. A recent backup from an older
/// schema or shadow sequence is not evidence for the current candidate and cannot suppress a new
/// generation merely because it is less than 24 hours old.
struct LibraryBackupFreshnessRequirement: Equatable, Sendable {
    let databaseInstanceID: UUID
    let schemaVersion: Int
    let shadowChangeSequence: Int64

    func matches(_ receipt: LibraryBackupLifecycleReceipt?) -> Bool {
        receipt?.databaseInstanceID == databaseInstanceID
            && receipt?.schemaVersion == schemaVersion
            && receipt?.shadowChangeSequence == shadowChangeSequence
    }
}

/// Scheduling and retention around `LibraryBackupService`.
///
/// Generations and the immutable pool are siblings outside the live support root. Only recognized
/// generation directories participate in scheduling or retention. Pool objects are intentionally
/// never collected here: a later gate must prove manifest-reference auditing before it may remove
/// even an apparently unreferenced digest.
enum LibraryBackupLifecycle {
    static let minimumInterval: TimeInterval = 24 * 60 * 60

    /// How many daily copies to keep. A SETTING now, not a constant.
    ///
    /// It was 7. Measured on a real library one generation is about 2.4 GB, of which only 651 MB is
    /// the database — the rest is retained media copied whole into every generation, because the
    /// shared object pool beside them is empty. Seven copies is roughly 17 GB, almost all of it the
    /// same files written out seven times, on a policy nobody was ever shown.
    ///
    /// `LibraryBackupSettings` owns the default and the offered choices. Injectable so the retention
    /// tests stay deterministic rather than reading whatever this machine happens to prefer.
    static var maximumGenerations: Int { LibraryBackupSettings.generations() }

    private static let receiptFormatLimit = 16 * 1_024
    private static let generationPrefix = "generation-"
    private static let generationsName = "generations"
    private static let objectPoolName = "objects"
    private static let receiptName = "latest-receipt.json"
    private static let lockName = ".lifecycle.lock"

    /// Whether a backup whose restore was actually verified still exists to go back to.
    ///
    /// This is the reclaim's "there is still a way back" precondition, so it deliberately requires
    /// evidence rather than the presence of a directory: a receipt naming a generation that is
    /// still on disk, and a restore this app proved. Anything it cannot read is a no.
    static func hasVerifiedBackup(for supportRoot: URL) -> Bool {
        let root = backupRoot(for: supportRoot)
        guard let receipt = (try? readReceiptIfPresent(in: root)) ?? nil else { return false }
        guard !receipt.restoreVerifiedAt.trimmingCharacters(in: .whitespaces).isEmpty else {
            return false
        }
        // Generations live one level down, in `generations/` — the same place `createBackupIfDue`
        // writes them and every other reader looks. Enumerating the backup root instead finds only
        // `generations`, `objects` and the receipt, none of which carry the `generation-` prefix, so
        // this answered "no verified backup" on every machine and the post-soak reclaim it guards
        // could never run at all.
        let generationsRoot = root.appendingPathComponent(generationsName, isDirectory: true)
        guard let generations = try? recognizedGenerations(in: generationsRoot) else { return false }
        return generations.contains { $0.url.lastPathComponent == receipt.generationName }
    }

    static func backupRoot(for supportRoot: URL) -> URL {
        let source = supportRoot.standardizedFileURL
        return source.deletingLastPathComponent().appendingPathComponent(
            "\(source.lastPathComponent) Library Backups",
            isDirectory: true)
    }

    /// Creates one backup when the newest recognized generation is at least 24 hours old. Calls
    /// are serialized across app instances by an owner-only advisory lock. `now` and `backupID`
    /// are injectable solely so the cadence and retention policy are deterministic under test.
    static func createBackupIfDue(
        sourceSupportRoot: URL,
        now: Date = Date(),
        backupID: UUID = UUID(),
        requiring requirement: LibraryBackupFreshnessRequirement? = nil,
        /// Ignore the 24-hour cadence. The one caller is a person pressing "Back up now", which
        /// tells the app something a clock cannot: usually that they are about to do something they
        /// might regret.
        force: Bool = false,
        /// How many copies to keep. Defaults to the person's setting; injectable so the retention
        /// tests prove the MECHANISM deterministically rather than whichever default ships today —
        /// one of them pinned 7 and broke the moment the default became a choice, which is a test
        /// measuring the wrong thing.
        keeping keptGenerations: Int? = nil
    ) throws -> LibraryBackupLifecycleResult {
        let keep = keptGenerations ?? maximumGenerations
        guard now.timeIntervalSince1970.isFinite, now.timeIntervalSince1970 >= 0 else {
            throw LibraryBackupServiceError.invalidInput("backup lifecycle date is invalid")
        }
        let sourceRoot = sourceSupportRoot.standardizedFileURL
        // Repaired, not refused. This is the same check that stranded a machine at launch, in a
        // path the 0.25.3 fix did not reach; it survived only because recognition happens to repair
        // the root earlier in launch, which is exactly the "unreachable in practice" reasoning that
        // has already failed twice.
        try makePrivateOwnedDirectory(sourceRoot, label: "support root")
        guard !sourceRoot.lastPathComponent.isEmpty else {
            throw LibraryBackupServiceError.invalidInput("support root has no sibling backup name")
        }
        let root = backupRoot(for: sourceRoot)
        try prepareRoot(root)
        return try withLifecycleLock(at: root.appendingPathComponent(lockName)) {
            let generations = root.appendingPathComponent(generationsName, isDirectory: true)
            let pool = root.appendingPathComponent(objectPoolName, isDirectory: true)
            try prepareOwnerOnlyDirectory(generations, label: "backup generations root")
            try prepareOwnerOnlyDirectory(pool, label: "backup object pool")

            var existing = try recognizedGenerations(in: generations)
            try pruneExpiredGenerations(existing, keeping: keep)
            existing = Array(existing.prefix(keep))
            if !force, let newest = existing.first,
               now.timeIntervalSince1970 - TimeInterval(newest.timestamp) < minimumInterval {
                let receipt = try readReceiptIfPresent(in: root)
                let currentReceipt = receipt?.generationName == newest.url.lastPathComponent
                    ? receipt : nil
                if requirement == nil || requirement?.matches(currentReceipt) == true {
                    return LibraryBackupLifecycleResult(
                        disposition: .skippedRecentGeneration,
                        backupRoot: root,
                        generationURL: newest.url,
                        receipt: currentReceipt,
                        verifiedRestoreReport: nil)
                }
            }

            let timestamp = Int64(now.timeIntervalSince1970.rounded(.down))
            let generationName = "\(generationPrefix)\(timestamp)-\(backupID.uuidString.lowercased())"
            let destination = generations.appendingPathComponent(generationName, isDirectory: true)
            let backup = try LibraryBackupService.createBackup(
                sourceSupportRoot: sourceRoot,
                destinationURL: destination,
                backupID: backupID,
                createdAt: now,
                sharedObjectPoolURL: pool)

            let restoreRoot = root.appendingPathComponent(
                ".restore-verification-\(backupID.uuidString.lowercased())",
                isDirectory: true)
            let restoreReport: LibraryBackupRestoreReport
            do {
                restoreReport = try LibraryBackupService.verifyAndRestore(
                    backupURL: destination,
                    isolatedSupportRoot: restoreRoot)
                try FileManager.default.removeItem(at: restoreRoot)
            } catch {
                try? FileManager.default.removeItem(at: restoreRoot)
                try? FileManager.default.removeItem(at: destination)
                throw error
            }

            let allGenerations = try recognizedGenerations(in: generations)
            try pruneExpiredGenerations(allGenerations, keeping: keep)
            let retainedBytes = try backup.manifest.retainedBytes.reduce(into: Int64(0)) {
                let (sum, overflow) = $0.addingReportingOverflow($1.byteCount)
                guard !overflow else {
                    throw LibraryBackupServiceError.verification(
                        "backup receipt retained-byte total overflowed")
                }
                $0 = sum
            }
            let receipt = LibraryBackupLifecycleReceipt(
                formatVersion: LibraryBackupLifecycleReceipt.currentFormatVersion,
                backupID: backup.manifest.backupID,
                createdAt: backup.manifest.createdAt,
                generationName: generationName,
                manifestSHA256: backup.manifestSHA256,
                databaseInstanceID: backup.manifest.database.databaseInstanceID,
                schemaVersion: backup.manifest.database.schemaVersion,
                shadowChangeSequence: backup.manifest.database.shadowChangeSequence,
                restoreVerifiedAt: backup.manifest.createdAt,
                retainedByteCount: backup.manifest.retainedBytes.count,
                retainedBytes: retainedBytes)
            guard requirement == nil || requirement?.matches(receipt) == true else {
                try? FileManager.default.removeItem(at: destination)
                throw LibraryBackupServiceError.verification(
                    "new backup does not match the required database generation")
            }
            try writeReceipt(receipt, in: root)
            return LibraryBackupLifecycleResult(
                disposition: .created,
                backupRoot: root,
                generationURL: destination,
                receipt: receipt,
                verifiedRestoreReport: restoreReport)
        }
    }
}

private extension LibraryBackupLifecycle {
    struct Generation {
        let timestamp: Int64
        let url: URL
    }

    static func prepareRoot(_ root: URL) throws {
        // The backup root is a SIBLING of the support root, so this parent is whatever contains
        // the library — normally `~/Library/Application Support`. It is shared with every other
        // app, so it is checked and never repaired.
        try requireOwnerOnlyDirectory(root.deletingLastPathComponent(), label: "backup parent")
        try prepareOwnerOnlyDirectory(root, label: "backup root")
    }

    /// Creates the directory private, and **refuses** an existing one that is not.
    ///
    /// Deliberately not repaired, unlike the support root. Everything under the backup root is
    /// restore evidence, and a directory already readable by other users is evidence whose history
    /// this app cannot vouch for. Tightening it would not undo the exposure; it would only hide it
    /// and then write more of the library into the same place. Refusing a backup costs backups.
    /// Refusing a launch cost users their app, which is why that one repairs.
    static func prepareOwnerOnlyDirectory(_ url: URL, label: String) throws {
        if FileManager.default.fileExists(atPath: url.path) {
            try requireOwnerOnlyDirectory(url, label: label)
            return
        }
        do {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o700], ofItemAtPath: url.path)
            try requireOwnerOnlyDirectory(url, label: label)
        } catch let error as LibraryBackupServiceError {
            throw error
        } catch {
            throw LibraryBackupServiceError.permissions(
                "could not create \(label): \(error.localizedDescription)")
        }
    }

    static func makePrivateOwnedDirectory(_ url: URL, label: String) throws {
        if let reason = OwnerOnlyDirectory.makePrivateReason(url, label: label) {
            throw LibraryBackupServiceError.permissions(reason)
        }
    }

    /// For a directory this app does not own, or is verifying rather than preparing.
    static func requireOwnerOnlyDirectory(_ url: URL, label: String) throws {
        if let reason = OwnerOnlyDirectory.requireReason(url, label: label) {
            throw LibraryBackupServiceError.permissions(reason)
        }
    }

    static func withLifecycleLock<T>(at url: URL, _ body: () throws -> T) throws -> T {
        let descriptor = Darwin.open(
            url.path, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, mode_t(0o600))
        guard descriptor >= 0 else {
            throw posixPermissions("could not open backup lifecycle lock")
        }
        defer { Darwin.close(descriptor) }
        guard fchmod(descriptor, mode_t(0o600)) == 0 else {
            throw posixPermissions("could not protect backup lifecycle lock")
        }
        var value = stat()
        guard fstat(descriptor, &value) == 0,
              value.st_mode & S_IFMT == S_IFREG,
              value.st_mode & 0o077 == 0 else {
            throw LibraryBackupServiceError.permissions(
                "backup lifecycle lock must be a 0600 regular file")
        }
        guard flock(descriptor, LOCK_EX) == 0 else {
            throw posixPermissions("could not acquire backup lifecycle lock")
        }
        defer { _ = flock(descriptor, LOCK_UN) }
        return try body()
    }

    static func recognizedGenerations(in root: URL) throws -> [Generation] {
        let entries: [URL]
        do {
            entries = try FileManager.default.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles])
        } catch {
            throw LibraryBackupServiceError.permissions(
                "could not enumerate backup generations: \(error.localizedDescription)")
        }
        var generations: [Generation] = []
        for entry in entries {
            guard let timestamp = generationTimestamp(entry.lastPathComponent) else { continue }
            try requireOwnerOnlyDirectory(entry, label: "backup generation")
            generations.append(Generation(timestamp: timestamp, url: entry))
        }
        return generations.sorted {
            if $0.timestamp != $1.timestamp { return $0.timestamp > $1.timestamp }
            return $0.url.lastPathComponent > $1.url.lastPathComponent
        }
    }

    static func generationTimestamp(_ name: String) -> Int64? {
        guard name.hasPrefix(generationPrefix) else { return nil }
        let suffix = name.dropFirst(generationPrefix.count)
        guard let separator = suffix.firstIndex(of: "-") else { return nil }
        let timestampText = suffix[..<separator]
        let uuidText = suffix[suffix.index(after: separator)...]
        guard let timestamp = Int64(timestampText), timestamp >= 0,
              UUID(uuidString: String(uuidText)) != nil else { return nil }
        return timestamp
    }

    static func pruneExpiredGenerations(
        _ generations: [Generation], keeping keep: Int? = nil
    ) throws {
        for obsolete in generations.dropFirst(keep ?? maximumGenerations) {
            do {
                try FileManager.default.removeItem(at: obsolete.url)
            } catch {
                throw LibraryBackupServiceError.permissions(
                    "could not prune expired backup generation: \(error.localizedDescription)")
            }
        }
    }

    static func readReceiptIfPresent(in root: URL) throws -> LibraryBackupLifecycleReceipt? {
        let url = root.appendingPathComponent(receiptName, isDirectory: false)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        var value = stat()
        guard lstat(url.path, &value) == 0,
              value.st_mode & S_IFMT == S_IFREG,
              value.st_mode & 0o077 == 0,
              value.st_size >= 0,
              value.st_size <= Int64(receiptFormatLimit) else {
            throw LibraryBackupServiceError.verification(
                "backup lifecycle receipt is not a bounded 0600 regular file")
        }
        let data = try Data(contentsOf: url, options: [.mappedIfSafe])
        let receipt: LibraryBackupLifecycleReceipt
        do {
            receipt = try JSONDecoder().decode(LibraryBackupLifecycleReceipt.self, from: data)
        } catch {
            throw LibraryBackupServiceError.verification(
                "backup lifecycle receipt could not be decoded")
        }
        guard receipt.formatVersion == LibraryBackupLifecycleReceipt.currentFormatVersion,
              receipt.generationName.count <= 128,
              generationTimestamp(receipt.generationName) != nil,
              receipt.manifestSHA256.count == 64,
              receipt.manifestSHA256.allSatisfy(\.isHexDigit),
              receipt.retainedByteCount >= 0,
              receipt.retainedBytes >= 0 else {
            throw LibraryBackupServiceError.verification(
                "backup lifecycle receipt is invalid")
        }
        return receipt
    }

    static func writeReceipt(_ receipt: LibraryBackupLifecycleReceipt, in root: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data: Data
        do { data = try encoder.encode(receipt) }
        catch {
            throw LibraryBackupServiceError.verification(
                "backup lifecycle receipt could not be encoded")
        }
        guard data.count <= receiptFormatLimit else {
            throw LibraryBackupServiceError.verification(
                "backup lifecycle receipt exceeds its size limit")
        }
        let destination = root.appendingPathComponent(receiptName, isDirectory: false)
        let temporary = root.appendingPathComponent(
            ".\(receiptName).staging-\(UUID().uuidString)", isDirectory: false)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let descriptor = Darwin.open(
            temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, mode_t(0o600))
        guard descriptor >= 0 else { throw posixPermissions("could not create backup receipt") }
        var writeError: LibraryBackupServiceError?
        data.withUnsafeBytes { bytes in
            var written = 0
            while written < bytes.count {
                let result = Darwin.write(
                    descriptor,
                    bytes.baseAddress?.advanced(by: written),
                    bytes.count - written)
                if result < 0 && errno == EINTR { continue }
                if result <= 0 {
                    writeError = posixPermissions("could not write backup receipt")
                    break
                }
                written += result
            }
        }
        if writeError == nil, fsync(descriptor) != 0 {
            writeError = posixPermissions("could not sync backup receipt")
        }
        Darwin.close(descriptor)
        if let writeError { throw writeError }
        guard Darwin.rename(temporary.path, destination.path) == 0 else {
            throw posixPermissions("could not publish backup receipt")
        }
    }

    static func posixPermissions(_ context: String) -> LibraryBackupServiceError {
        let code = POSIXErrorCode(rawValue: errno)
        let detail = code.map { POSIXError($0).localizedDescription } ?? "errno \(errno)"
        return .permissions("\(context): \(detail)")
    }
}
