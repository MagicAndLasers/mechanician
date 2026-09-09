import CryptoKit
import Darwin
import Foundation
import XCTest
@testable import Mechanician

final class ArtifactMediaSourceScannerTests: XCTestCase {
    private final class MutationControl: @unchecked Sendable {
        private let lock = NSLock()
        private var running = true

        var shouldContinue: Bool {
            lock.withLock { running }
        }

        func stop() {
            lock.withLock { running = false }
        }
    }

    private func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "artifact-media-scanner-\(UUID().uuidString)",
                isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func makeDirectory(_ relativePath: String, in root: URL) throws -> URL {
        let directory = root.appendingPathComponent(relativePath, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true)
        return directory
    }

    private func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    func testArtifactDecodePreservesExactUTF8BytesAndAmbientTaskProvenance() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let artifacts = try makeDirectory("artifacts", in: root)
        let artifactID = UUID()
        let conversationID = UUID()
        let taskID = "ambient-task-é-🛠"
        let sourceText = "# Café\r\n\r\nExact UTF-8 🧰\n"
        let json = """
        {"id":"\(artifactID.uuidString)","title":"Café 🛠","type":"markdown","source":"# Café\\r\\n\\r\\nExact UTF-8 🧰\\n","createdAt":"2026-08-04T12:34:56.789Z","updatedAt":"2026-08-04T12:35:01.234Z","revisions":2,"favorite":false,"origin":"ambient","conversationID":"\(conversationID.uuidString)","conversationTitle":"Scheduled brief","cwd":"","taskId":"\(taskID)"}
        """
        let bytes = try XCTUnwrap(json.data(using: .utf8))
        let url = artifacts.appendingPathComponent("\(artifactID.uuidString).json")
        try bytes.write(to: url)

        let scan = ArtifactMediaSourceScanner.scan(supportRoot: root)
        let candidate = try XCTUnwrap(scan.artifacts.only)

        XCTAssertEqual(candidate.artifact.uuid, artifactID)
        XCTAssertEqual(candidate.artifact.conversationID, conversationID)
        XCTAssertEqual(candidate.artifact.source, sourceText)
        XCTAssertEqual(candidate.producerTaskID, taskID)
        XCTAssertEqual(candidate.rawSourceBytes, bytes)
        XCTAssertEqual(candidate.source.identity, "artifacts/\(artifactID.uuidString).json")
        XCTAssertEqual(candidate.source.byteCount, bytes.count)
        XCTAssertEqual(candidate.source.digest, digest(bytes))
        XCTAssertTrue(scan.issues.isEmpty)
        XCTAssertTrue(scan.hasCompleteCensus)
    }

    func testHiddenSourcesAreInventoriedWhileKnownArtifactMigrationMarkerIsIgnored() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let artifacts = try makeDirectory("artifacts", in: root)
        let artifact = Artifact(
            title: "Hidden but authoritative",
            type: "markdown",
            source: "retained hidden source")
        try ArtifactStore.persistedEncoder().encode(artifact).write(
            to: artifacts.appendingPathComponent(".hidden.json"))
        try Data("administrative marker".utf8).write(
            to: artifacts.appendingPathComponent(".migrated-v1"))

        let conversationID = UUID()
        let owner = try makeDirectory(
            "conversation-media/\(conversationID.uuidString)",
            in: root)
        let media = Data("hidden retained media".utf8)
        try media.write(to: owner.appendingPathComponent(".hidden.png"))

        let scan = ArtifactMediaSourceScanner.scan(supportRoot: root)

        XCTAssertEqual(scan.artifacts.map(\.artifact.uuid), [artifact.uuid])
        XCTAssertEqual(scan.artifacts.map(\.source.identity), ["artifacts/.hidden.json"])
        XCTAssertEqual(scan.retainedBytes.map(\.storageName), [".hidden.png"])
        XCTAssertEqual(scan.retainedBytes.map(\.source.digest), [digest(media)])
        XCTAssertFalse(scan.sourceIdentities.contains("artifacts/.migrated-v1"))
        XCTAssertTrue(scan.issues.isEmpty)
        XCTAssertTrue(scan.hasCompleteCensus)
    }

    func testMissingOptionalRootsRemainACompleteEmptyCensus() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let scan = ArtifactMediaSourceScanner.scan(supportRoot: root)

        XCTAssertTrue(scan.artifacts.isEmpty)
        XCTAssertTrue(scan.retainedBytes.isEmpty)
        XCTAssertTrue(scan.issues.isEmpty)
        XCTAssertTrue(scan.hasCompleteCensus)
    }

    func testUnreadableDirectoryProducesVisibleIncompleteCensus() throws {
        let root = try makeRoot()
        let artifacts = try makeDirectory("artifacts", in: root)
        defer {
            _ = Darwin.chmod(artifacts.path, S_IRWXU)
            try? FileManager.default.removeItem(at: root)
        }
        XCTAssertEqual(Darwin.chmod(artifacts.path, 0), 0)

        let scan = ArtifactMediaSourceScanner.scan(supportRoot: root)
        let issue = try XCTUnwrap(scan.issues.only)

        XCTAssertTrue(scan.artifacts.isEmpty)
        XCTAssertTrue(scan.retainedBytes.isEmpty)
        XCTAssertFalse(scan.hasCompleteCensus)
        XCTAssertEqual(issue.source.identity, "artifacts")
        XCTAssertTrue(issue.diagnostics.contains("could not be enumerated"))
    }

    func testOversizedArtifactIsReportedWithoutAllocatingItsDeclaredSize() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let artifacts = try makeDirectory("artifacts", in: root)
        let url = artifacts.appendingPathComponent("oversized.json")
        let descriptor = Darwin.open(
            url.path,
            O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC,
            S_IRUSR | S_IWUSR)
        XCTAssertGreaterThanOrEqual(descriptor, 0)
        guard descriptor >= 0 else { return }
        XCTAssertEqual(
            ftruncate(
                descriptor,
                off_t(ArtifactMediaSourceScanner.maximumArtifactJSONBytes + 1)),
            0)
        Darwin.close(descriptor)

        let scan = ArtifactMediaSourceScanner.scan(supportRoot: root)
        let issue = try XCTUnwrap(scan.issues.only)

        XCTAssertTrue(scan.artifacts.isEmpty)
        XCTAssertTrue(scan.hasCompleteCensus)
        XCTAssertEqual(issue.source.identity, "artifacts/oversized.json")
        XCTAssertTrue(issue.diagnostics.contains("scanner limit"))
    }

    func testLargeMediaDigestStreamsAcrossMultipleChunks() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let conversationID = UUID()
        let fileID = UUID()
        let owner = try makeDirectory(
            "conversation-media/\(conversationID.uuidString)",
            in: root)
        let bytes = Data((0..<(2 * 1_024 * 1_024 + 137)).map {
            UInt8(truncatingIfNeeded: $0 &* 31)
        })
        try bytes.write(to: owner.appendingPathComponent("\(fileID.uuidString).png"))

        let scan = ArtifactMediaSourceScanner.scan(supportRoot: root)
        let candidate = try XCTUnwrap(scan.retainedBytes.only)

        XCTAssertEqual(candidate.kind, .conversationMedia)
        XCTAssertEqual(candidate.ownerConversationID, conversationID)
        XCTAssertEqual(candidate.storageName, "\(fileID.uuidString).png")
        XCTAssertEqual(candidate.source.byteCount, bytes.count)
        XCTAssertEqual(candidate.source.digest, digest(bytes))
        XCTAssertTrue(scan.issues.isEmpty)
        XCTAssertTrue(scan.hasCompleteCensus)
    }

    func testCachedFingerprintIsReusedOnlyForAnExactDescriptorRevision() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let conversationID = UUID()
        let fileID = UUID()
        let owner = try makeDirectory(
            "conversation-media/\(conversationID.uuidString)",
            in: root)
        let url = owner.appendingPathComponent("\(fileID.uuidString).png")
        let firstBytes = Data("first generation".utf8)
        try firstBytes.write(to: url)

        let initial = try XCTUnwrap(
            ArtifactMediaSourceScanner.scan(supportRoot: root).retainedBytes.only)
        let sentinelDigest = String(repeating: "ab", count: 32)
        let cached = ShadowLibrarySourceFingerprint(
            identity: initial.source.identity,
            revision: initial.source.revision,
            digest: sentinelDigest,
            byteCount: initial.source.byteCount)

        let reused = try XCTUnwrap(ArtifactMediaSourceScanner.scan(
            supportRoot: root,
            cachedFingerprints: [cached.identity: cached]).retainedBytes.only)
        XCTAssertEqual(reused.source, cached, "An exact descriptor revision should avoid rehashing.")

        let secondBytes = Data("other generation".utf8)
        XCTAssertEqual(secondBytes.count, firstBytes.count)
        try secondBytes.write(to: url, options: .atomic)
        let refreshed = try XCTUnwrap(ArtifactMediaSourceScanner.scan(
            supportRoot: root,
            cachedFingerprints: [cached.identity: cached]).retainedBytes.only)

        XCTAssertNotEqual(refreshed.source.revision, cached.revision)
        XCTAssertNotEqual(refreshed.source.digest, sentinelDigest)
        XCTAssertEqual(refreshed.source.digest, digest(secondBytes))
    }

    func testDuplicateBytesKeepDistinctSourceAndOwnerIdentities() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let firstConversationID = UUID()
        let secondConversationID = UUID()
        let firstFileID = UUID()
        let secondFileID = UUID()
        let bytes = Data("same retained bytes, different uses".utf8)
        let firstOwner = try makeDirectory(
            "conversation-media/\(firstConversationID.uuidString)",
            in: root)
        let secondOwner = try makeDirectory(
            "conversation-media/\(secondConversationID.uuidString)",
            in: root)
        try bytes.write(to: firstOwner.appendingPathComponent("\(firstFileID.uuidString).png"))
        try bytes.write(to: secondOwner.appendingPathComponent("\(secondFileID.uuidString).png"))

        let scan = ArtifactMediaSourceScanner.scan(supportRoot: root)
        XCTAssertEqual(scan.retainedBytes.count, 2)
        XCTAssertEqual(Set(scan.retainedBytes.map(\.source.digest)), [digest(bytes)])
        XCTAssertEqual(Set(scan.retainedBytes.map(\.source.identity)).count, 2)
        XCTAssertEqual(
            Set(scan.retainedBytes.compactMap(\.ownerConversationID)),
            [firstConversationID, secondConversationID])
        XCTAssertEqual(
            Set(scan.retainedBytes.map(\.storageName)),
            ["\(firstFileID.uuidString).png", "\(secondFileID.uuidString).png"])
    }

    func testConversationTrashMediaRetainsOwnerAndTrashClassification() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let conversationID = UUID()
        let slotID = UUID()
        let fileID = UUID()
        let directory = try makeDirectory(
            "trash/conversations/\(conversationID.uuidString)-\(slotID.uuidString)/\(conversationID.uuidString)",
            in: root)
        let bytes = Data("undo-owned media".utf8)
        try bytes.write(to: directory.appendingPathComponent("\(fileID.uuidString).html"))

        let scan = ArtifactMediaSourceScanner.scan(supportRoot: root)
        let candidate = try XCTUnwrap(scan.retainedBytes.only)

        XCTAssertEqual(candidate.kind, .conversationTrashMedia)
        XCTAssertEqual(candidate.ownerConversationID, conversationID)
        XCTAssertEqual(candidate.storageName, "\(fileID.uuidString).html")
        XCTAssertTrue(candidate.source.identity.hasPrefix("trash/conversations/"))
        XCTAssertEqual(candidate.source.digest, digest(bytes))
    }

    func testSymlinkedIntermediateTrashDirectoryIsReportedAndNeverTraversed() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let conversationID = UUID()
        let slotID = UUID()
        let fileID = UUID()
        let outside = try makeDirectory(
            "outside-trash/conversations/\(conversationID.uuidString)-\(slotID.uuidString)/\(conversationID.uuidString)",
            in: root)
        let bytes = Data("must not cross the intermediate trash symlink".utf8)
        try bytes.write(to: outside.appendingPathComponent("\(fileID.uuidString).png"))
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("trash", isDirectory: true),
            withDestinationURL: root.appendingPathComponent(
                "outside-trash",
                isDirectory: true))

        let scan = ArtifactMediaSourceScanner.scan(supportRoot: root)
        let issue = try XCTUnwrap(scan.issues.only)

        XCTAssertTrue(scan.artifacts.isEmpty)
        XCTAssertTrue(scan.retainedBytes.isEmpty)
        XCTAssertEqual(issue.kind, .malformed)
        XCTAssertEqual(issue.source.identity, "trash")
        XCTAssertTrue(issue.diagnostics.contains(
            "contains a non-directory path component and was not traversed"))
        XCTAssertFalse(
            scan.hasCompleteCensus,
            "an untraversed authority path cannot prove a closed source set")
        XCTAssertFalse(scan.sourceIdentities.contains(
            "trash/conversations/\(conversationID.uuidString)-\(slotID.uuidString)"
                + "/\(conversationID.uuidString)/\(fileID.uuidString).png"))
    }

    func testSymlinkedArtifactRootIsReportedAndNeverTraversed() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let outside = try makeDirectory("outside-artifact-authority", in: root)
        let artifact = Artifact(
            title: "Must stay outside",
            type: "markdown",
            source: "private artifact source")
        let artifactBytes = try ArtifactStore.persistedEncoder().encode(artifact)
        try artifactBytes.write(
            to: outside.appendingPathComponent("\(artifact.uuid.uuidString).json"))
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("artifacts", isDirectory: true),
            withDestinationURL: outside)

        let scan = ArtifactMediaSourceScanner.scan(supportRoot: root)
        let issue = try XCTUnwrap(scan.issues.only)

        XCTAssertTrue(scan.artifacts.isEmpty)
        XCTAssertTrue(scan.retainedBytes.isEmpty)
        XCTAssertEqual(issue.kind, .malformed)
        XCTAssertEqual(issue.source.identity, "artifacts")
        XCTAssertTrue(issue.diagnostics.contains("was not traversed"))
        XCTAssertFalse(
            scan.hasCompleteCensus,
            "an untraversed authority root must not authorize stale-row pruning")
        XCTAssertFalse(scan.sourceIdentities.contains(
            "artifacts/\(artifact.uuid.uuidString).json"))
    }

    func testSymlinkedConversationMediaRootIsReportedAndNeverTraversed() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let conversationID = UUID()
        let fileID = UUID()
        let outside = try makeDirectory(
            "outside-media-authority/\(conversationID.uuidString)",
            in: root)
        let bytes = Data("must not cross the media-root symlink".utf8)
        try bytes.write(to: outside.appendingPathComponent("\(fileID.uuidString).png"))
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("conversation-media", isDirectory: true),
            withDestinationURL: outside.deletingLastPathComponent())

        let scan = ArtifactMediaSourceScanner.scan(supportRoot: root)
        let issue = try XCTUnwrap(scan.issues.only)

        XCTAssertTrue(scan.artifacts.isEmpty)
        XCTAssertTrue(scan.retainedBytes.isEmpty)
        XCTAssertEqual(issue.kind, .malformed)
        XCTAssertEqual(issue.source.identity, "conversation-media")
        XCTAssertTrue(issue.diagnostics.contains("was not traversed"))
        XCTAssertFalse(
            scan.hasCompleteCensus,
            "an untraversed media root must preserve previously inventoried children")
        XCTAssertFalse(scan.sourceIdentities.contains(
            "conversation-media/\(conversationID.uuidString)/\(fileID.uuidString).png"))
    }

    func testSymlinkedMediaIsRefusedAndReportedWithoutReadingTarget() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let conversationID = UUID()
        let fileID = UUID()
        let owner = try makeDirectory(
            "conversation-media/\(conversationID.uuidString)",
            in: root)
        let outside = root.appendingPathComponent("outside-private.png")
        let privateBytes = Data("must not be inventoried through a symlink".utf8)
        try privateBytes.write(to: outside)
        let link = owner.appendingPathComponent("\(fileID.uuidString).png")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)

        let scan = ArtifactMediaSourceScanner.scan(supportRoot: root)
        let issue = try XCTUnwrap(scan.issues.only)

        XCTAssertTrue(scan.retainedBytes.isEmpty)
        XCTAssertEqual(issue.kind, .malformed)
        XCTAssertEqual(
            issue.source.identity,
            "conversation-media/\(conversationID.uuidString)/\(fileID.uuidString).png")
        XCTAssertTrue(issue.diagnostics.contains("could not be safely digested"))
        XCTAssertNotEqual(issue.source.digest, digest(privateBytes))
        XCTAssertTrue(scan.hasCompleteCensus)
    }

    func testConcurrentArtifactMutationIsReportedInsteadOfPublishingMixedBytes() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let artifacts = try makeDirectory("artifacts", in: root)
        let url = artifacts.appendingPathComponent("changing.json")
        let descriptor = Darwin.open(
            url.path,
            O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC,
            S_IRUSR | S_IWUSR)
        XCTAssertGreaterThanOrEqual(descriptor, 0)
        guard descriptor >= 0 else { return }
        XCTAssertEqual(ftruncate(descriptor, 32 * 1_024 * 1_024), 0)
        Darwin.close(descriptor)

        let control = MutationControl()
        let started = DispatchSemaphore(value: 0)
        let finished = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            let writer = Darwin.open(url.path, O_WRONLY | O_CLOEXEC)
            guard writer >= 0 else {
                started.signal()
                finished.signal()
                return
            }
            defer {
                Darwin.close(writer)
                finished.signal()
            }
            var value: UInt8 = 0
            _ = withUnsafeBytes(of: &value) { bytes in
                Darwin.pwrite(writer, bytes.baseAddress, 1, 0)
            }
            started.signal()
            while control.shouldContinue {
                value &+= 1
                _ = withUnsafeBytes(of: &value) { bytes in
                    Darwin.pwrite(writer, bytes.baseAddress, 1, 0)
                }
            }
        }
        XCTAssertEqual(started.wait(timeout: .now() + 2), .success)

        let scan = ArtifactMediaSourceScanner.scan(supportRoot: root)
        control.stop()
        XCTAssertEqual(finished.wait(timeout: .now() + 2), .success)

        XCTAssertTrue(scan.artifacts.isEmpty)
        XCTAssertTrue(scan.hasCompleteCensus)
        let issue = try XCTUnwrap(scan.issues.only)
        XCTAssertEqual(issue.kind, .malformed)
        XCTAssertTrue(issue.diagnostics.contains("could not be safely read"))
    }

    func testConcurrentMediaMutationIsReportedInsteadOfPublishingMixedDigest() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let conversationID = UUID()
        let fileID = UUID()
        let owner = try makeDirectory(
            "conversation-media/\(conversationID.uuidString)",
            in: root)
        let url = owner.appendingPathComponent("\(fileID.uuidString).png")
        let descriptor = Darwin.open(
            url.path,
            O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC,
            S_IRUSR | S_IWUSR)
        XCTAssertGreaterThanOrEqual(descriptor, 0)
        guard descriptor >= 0 else { return }
        XCTAssertEqual(ftruncate(descriptor, 128 * 1_024 * 1_024), 0)
        Darwin.close(descriptor)

        let control = MutationControl()
        let started = DispatchSemaphore(value: 0)
        let finished = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            let writer = Darwin.open(url.path, O_WRONLY | O_CLOEXEC)
            guard writer >= 0 else {
                started.signal()
                finished.signal()
                return
            }
            defer {
                Darwin.close(writer)
                finished.signal()
            }
            var value: UInt8 = 0
            _ = withUnsafeBytes(of: &value) { bytes in
                Darwin.pwrite(writer, bytes.baseAddress, 1, 0)
            }
            started.signal()
            while control.shouldContinue {
                value &+= 1
                _ = withUnsafeBytes(of: &value) { bytes in
                    Darwin.pwrite(writer, bytes.baseAddress, 1, 0)
                }
            }
        }
        XCTAssertEqual(started.wait(timeout: .now() + 2), .success)

        let scan = ArtifactMediaSourceScanner.scan(supportRoot: root)
        control.stop()
        XCTAssertEqual(finished.wait(timeout: .now() + 2), .success)

        XCTAssertTrue(scan.retainedBytes.isEmpty)
        let issue = try XCTUnwrap(scan.issues.only)
        XCTAssertEqual(issue.kind, .malformed)
        XCTAssertTrue(issue.diagnostics.contains("could not be safely digested"))
        XCTAssertTrue(scan.hasCompleteCensus)
    }
}

private extension Collection {
    var only: Element? {
        count == 1 ? first : nil
    }
}
