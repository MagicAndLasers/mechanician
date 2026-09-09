import Foundation
import XCTest
@testable import Mechanician

@MainActor
final class ArtifactStoreBackgroundAdoptionTests: XCTestCase {
    private func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "artifact-background-adoption-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        return root
    }

    private func artifact(
        id: UUID = UUID(),
        source: String = "# Exact source\r\n\r\nCaf\u{00e9} \u{1f6e0}\u{fe0f}\n"
    ) -> Artifact {
        Artifact(
            title: "Ambient plan",
            type: "markdown",
            source: source,
            favorite: true,
            origin: "ambient",
            workspaceID: UUID(uuidString: "B7A8C145-D60E-49C1-A908-E0BEB7B51348"),
            conversationID: UUID(uuidString: "DFCF7B0A-C06B-4D2D-8A9D-C9F3E4B13AC5"),
            conversationTitle: "\u{23f0} Scheduled report",
            cwd: "/tmp/workspace",
            uuid: id,
            createdAt: Date(timeIntervalSince1970: 1_754_356_896.125),
            updatedAt: Date(timeIntervalSince1970: 1_754_356_956.875),
            revisions: 3)
    }

    private func adopt(
        _ artifact: Artifact,
        taskID: String,
        store: ArtifactStore
    ) async -> BackgroundArtifactAdoptionResult {
        await withCheckedContinuation { continuation in
            store.adoptBackgroundArtifact(
                artifact,
                producerTaskID: taskID,
                retainedSourceBytes: Data(artifact.source.utf8)) {
                    continuation.resume(returning: $0)
                }
        }
    }

    func testBackgroundArtifactPublishesExactSourceThroughDurableWriter() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ArtifactStore(
            appSupportBaseOverride: root,
            watchesDirectory: false)
        let candidate = artifact()
        let taskID = "scheduled-task-42"

        let result = await adopt(candidate, taskID: taskID, store: store)

        XCTAssertEqual(result, .published)
        XCTAssertEqual(store.artifacts, [candidate])
        let url = root.appendingPathComponent(
            "artifacts/\(candidate.uuid.uuidString).json")
        let bytes = try Data(contentsOf: url)
        let decoded = try ArtifactStore.persistedDecoder().decode(Artifact.self, from: bytes)
        XCTAssertEqual(decoded, candidate)
        XCTAssertEqual(Data(decoded.source.utf8), Data(candidate.source.utf8))
        let raw = try XCTUnwrap(
            JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        XCTAssertEqual(raw["taskId"] as? String, taskID)
        XCTAssertEqual(raw["source"] as? String, candidate.source)

        let relaunched = ArtifactStore(
            appSupportBaseOverride: root,
            watchesDirectory: false)
        XCTAssertEqual(relaunched.artifacts, [candidate])
    }

    func testExactBackgroundArtifactReplayDoesNotReplaceCanonicalFile() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ArtifactStore(
            appSupportBaseOverride: root,
            watchesDirectory: false)
        let candidate = artifact()
        let taskID = "scheduled-task-replay"
        let first = await adopt(candidate, taskID: taskID, store: store)
        XCTAssertEqual(first, .published)
        let url = root.appendingPathComponent(
            "artifacts/\(candidate.uuid.uuidString).json")
        let originalBytes = try Data(contentsOf: url)
        var before = stat()
        XCTAssertEqual(lstat(url.path, &before), 0)

        let replay = await adopt(candidate, taskID: taskID, store: store)

        var after = stat()
        XCTAssertEqual(lstat(url.path, &after), 0)
        XCTAssertEqual(replay, .alreadyPublished)
        XCTAssertEqual(store.artifacts, [candidate])
        XCTAssertEqual(try Data(contentsOf: url), originalBytes)
        XCTAssertEqual(before.st_dev, after.st_dev)
        XCTAssertEqual(before.st_ino, after.st_ino)
    }

    func testExactReplayAcceptsSwiftRewrittenLegacyJSONWithoutTaskIdentity() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let candidate = artifact()
        let directory = root.appendingPathComponent("artifacts", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("\(candidate.uuid.uuidString).json")
        let swiftBytes = try ArtifactStore.persistedEncoder().encode(candidate)
        try swiftBytes.write(to: url, options: .atomic)
        let store = ArtifactStore(
            appSupportBaseOverride: root,
            watchesDirectory: false)

        let result = await adopt(
            candidate,
            taskID: "scheduled-task-recovered-after-swift-write",
            store: store)

        XCTAssertEqual(result, .alreadyPublished)
        XCTAssertEqual(store.artifacts, [candidate])
        XCTAssertEqual(try Data(contentsOf: url), swiftBytes)
    }

    func testNextAmbientRevisionAtomicallyAdvancesExistingArtifact() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ArtifactStore(
            appSupportBaseOverride: root,
            watchesDirectory: false)
        let original = artifact()
        let taskID = "scheduled-task-update"
        let first = await adopt(original, taskID: taskID, store: store)
        XCTAssertEqual(first, .published)
        var successor = original
        successor.type = "html"
        successor.source = "<h1>Fresh report</h1>\n"
        successor.updatedAt = original.updatedAt.addingTimeInterval(90)
        successor.revisions = original.revisions + 1
        successor.conversationTitle = "\u{23f0} Renamed scheduled report"

        let result = await adopt(successor, taskID: taskID, store: store)

        XCTAssertEqual(result, .published)
        XCTAssertEqual(store.artifacts, [successor])
        let url = root.appendingPathComponent(
            "artifacts/\(original.uuid.uuidString).json")
        let bytes = try Data(contentsOf: url)
        XCTAssertEqual(
            try ArtifactStore.persistedDecoder().decode(Artifact.self, from: bytes),
            successor)
        let raw = try XCTUnwrap(
            JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        XCTAssertEqual(raw["taskId"] as? String, taskID)
        XCTAssertEqual(raw["source"] as? String, successor.source)
    }

    /// FR-234. A successor published within the same millisecond as its predecessor is legitimate.
    ///
    /// The record keeps milliseconds and ROUNDS, so a predecessor stamped …956.857977 is written as
    /// …956.858 and read back LARGER than it was. Comparing that against a successor's exact
    /// in-memory …956.857990 made the newer artifact look older, and the adoption was refused as
    /// `identityCollision` with the user's ambient revision silently never arriving.
    ///
    /// Fully deterministic: the two instants are fixed, chosen so that the predecessor rounds UP
    /// across the successor. The pre-existing coverage hit this only when two `Date()` calls
    /// happened to straddle a rounding boundary, which is why it failed roughly one run in three
    /// and pointed at concurrency rather than at precision.
    func testSuccessorInTheSameMillisecondIsNotAnIdentityCollision() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ArtifactStore(appSupportBaseOverride: root, watchesDirectory: false)
        let taskID = "scheduled-task-same-millisecond"

        var original = artifact()
        original.updatedAt = Date(timeIntervalSince1970: 1_754_356_956.857977)
        let first = await adopt(original, taskID: taskID, store: store)
        XCTAssertEqual(first, .published)

        // Rounding really does move the stored instant forward past the successor below. If this
        // stops holding, the test no longer reproduces the defect and must be re-derived.
        XCTAssertGreaterThan(
            ArtifactStore.persistedInstant(original.updatedAt),
            original.updatedAt,
            "the predecessor must round UP for this to be the FR-234 shape")

        var successor = original
        successor.type = "html"
        successor.source = "<h1>Next revision</h1>\n"
        successor.revisions += 1
        successor.updatedAt = Date(timeIntervalSince1970: 1_754_356_956.857990)
        XCTAssertGreaterThan(
            successor.updatedAt, original.updatedAt, "the successor is genuinely later")
        XCTAssertLessThan(
            successor.updatedAt,
            ArtifactStore.persistedInstant(original.updatedAt),
            "but earlier than the predecessor's ROUNDED form, which is the whole bug")

        let result = await adopt(successor, taskID: taskID, store: store)
        XCTAssertEqual(result, .published, "a same-millisecond successor must still publish")
        XCTAssertEqual(store.artifacts.first?.source, successor.source)
        XCTAssertEqual(store.artifacts.first?.revisions, successor.revisions)
    }

    func testSuccessorAndReplayPreserveUserOwnedTitleFavoriteAndFiling() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ArtifactStore(
            appSupportBaseOverride: root,
            watchesDirectory: false)
        let conversations = ConversationStore(
            appSupportBaseOverride: root,
            watchesDirectory: false)
        let original = artifact()
        let taskID = "scheduled-task-user-organization"
        let first = await adopt(original, taskID: taskID, store: store)
        XCTAssertEqual(first, .published)

        let userWorkspaceID = UUID()
        store.rename(
            original.uuid,
            to: "My dashboard",
            conversations: conversations,
            synchronizeLiveState: false)
        store.setFavorite(
            original.uuid,
            false,
            conversations: conversations,
            synchronizeLiveState: false)
        _ = store.reassignArtifact(
            original.uuid,
            workspaceID: userWorkspaceID,
            cwd: "/user/filing")
        _ = try XCTUnwrap(store.artifacts.first { $0.uuid == original.uuid })

        var successor = original
        successor.type = "html"
        successor.source = "<h1>New ambient content</h1>\n"
        successor.updatedAt = Date()
        successor.revisions += 1
        let updated = await adopt(successor, taskID: taskID, store: store)
        XCTAssertEqual(updated, .published)

        var expected = successor
        expected.title = "My dashboard"
        expected.favorite = false
        expected.workspaceID = userWorkspaceID
        expected.cwd = "/user/filing"
        XCTAssertEqual(store.artifacts, [expected])

        // A rename after canonical publication is a newer user-owned mutation. Replaying the same
        // producer revision must acknowledge it without snapping the title or filing back.
        store.rename(
            original.uuid,
            to: "My renamed dashboard",
            conversations: conversations,
            synchronizeLiveState: false)
        let replay = await adopt(successor, taskID: taskID, store: store)
        XCTAssertEqual(replay, .alreadyPublished)
        let retained = try XCTUnwrap(
            store.artifacts.first { $0.uuid == original.uuid })
        XCTAssertEqual(retained.title, "My renamed dashboard")
        XCTAssertFalse(retained.favorite)
        XCTAssertEqual(retained.workspaceID, userWorkspaceID)
        XCTAssertEqual(retained.cwd, "/user/filing")
        XCTAssertEqual(retained.type, successor.type)
        XCTAssertEqual(retained.source, successor.source)
        XCTAssertEqual(retained.revisions, successor.revisions)
    }

    func testUserOrganizationQueuedDuringAdoptionRebasesBeforeReceipt() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ArtifactStore(
            appSupportBaseOverride: root,
            watchesDirectory: false)
        let conversations = ConversationStore(
            appSupportBaseOverride: root,
            watchesDirectory: false)
        let original = artifact()
        let taskID = "scheduled-task-adoption-race"
        let initialResult = await adopt(original, taskID: taskID, store: store)
        XCTAssertEqual(initialResult, .published)

        var successor = original
        successor.type = "html"
        successor.source = "<h1>Fresh producer content</h1>\n"
        successor.updatedAt = Date()
        successor.revisions += 1

        let started = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        store.blockPersistenceForTesting(started: started, release: release)
        XCTAssertEqual(started.wait(timeout: .now() + 2), .success)
        defer { release.signal() }

        let completed = expectation(description: "background adoption commits after rebase")
        var result: BackgroundArtifactAdoptionResult?
        store.adoptBackgroundArtifact(
            successor,
            producerTaskID: taskID,
            retainedSourceBytes: Data(successor.source.utf8)
        ) {
            result = $0
            completed.fulfill()
        }

        let workspaceID = UUID()
        store.rename(
            original.uuid,
            to: "User-organized dashboard",
            conversations: conversations,
            synchronizeLiveState: false)
        store.setFavorite(
            original.uuid,
            false,
            conversations: conversations,
            synchronizeLiveState: false)
        _ = store.reassignArtifact(
            original.uuid,
            workspaceID: workspaceID,
            cwd: "/user/organized")
        release.signal()

        await fulfillment(of: [completed], timeout: 3)
        XCTAssertEqual(result, .published)
        store.flushSaves()

        let relaunched = ArtifactStore(
            appSupportBaseOverride: root,
            watchesDirectory: false)
        let retained = try XCTUnwrap(
            relaunched.artifacts.first { $0.uuid == original.uuid })
        XCTAssertEqual(retained.type, successor.type)
        XCTAssertEqual(retained.source, successor.source)
        XCTAssertEqual(retained.revisions, successor.revisions)
        XCTAssertEqual(retained.title, "User-organized dashboard")
        XCTAssertFalse(retained.favorite)
        XCTAssertEqual(retained.workspaceID, workspaceID)
        XCTAssertEqual(retained.cwd, "/user/organized")
        let raw = try XCTUnwrap(JSONSerialization.jsonObject(
            with: Data(contentsOf: root.appendingPathComponent(
                "artifacts/\(original.uuid.uuidString).json"))) as? [String: Any])
        XCTAssertEqual(raw["taskId"] as? String, taskID)
    }

    func testUserContentEditQueuedDuringAdoptionWinsAndRejectsReceipt() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ArtifactStore(
            appSupportBaseOverride: root,
            watchesDirectory: false)
        let conversations = ConversationStore(
            appSupportBaseOverride: root,
            watchesDirectory: false)
        let original = artifact()
        let taskID = "scheduled-task-content-race"
        let initialResult = await adopt(original, taskID: taskID, store: store)
        XCTAssertEqual(initialResult, .published)

        var successor = original
        successor.type = "html"
        successor.source = "<h1>Competing producer content</h1>\n"
        successor.updatedAt = Date()
        successor.revisions += 1

        let started = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        store.blockPersistenceForTesting(started: started, release: release)
        XCTAssertEqual(started.wait(timeout: .now() + 2), .success)
        defer { release.signal() }

        let completed = expectation(description: "content conflict restores user value")
        var result: BackgroundArtifactAdoptionResult?
        store.adoptBackgroundArtifact(
            successor,
            producerTaskID: taskID,
            retainedSourceBytes: Data(successor.source.utf8)
        ) {
            result = $0
            completed.fulfill()
        }
        let userSource = "# My simultaneous edit\n"
        store.updateSource(
            original.uuid,
            userSource,
            conversations: conversations,
            synchronizeLiveState: false)
        release.signal()

        await fulfillment(of: [completed], timeout: 3)
        XCTAssertEqual(result, .identityCollision)
        store.flushSaves()

        let relaunched = ArtifactStore(
            appSupportBaseOverride: root,
            watchesDirectory: false)
        let retained = try XCTUnwrap(
            relaunched.artifacts.first { $0.uuid == original.uuid })
        XCTAssertEqual(retained.source, userSource)
        XCTAssertEqual(retained.type, original.type)
        XCTAssertEqual(retained.revisions, original.revisions + 1)
    }

    func testBackgroundArtifactIdentityCollisionPreservesExistingBytes() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ArtifactStore(
            appSupportBaseOverride: root,
            watchesDirectory: false)
        let original = artifact()
        let taskID = "scheduled-task-collision"
        let first = await adopt(original, taskID: taskID, store: store)
        XCTAssertEqual(first, .published)
        let url = root.appendingPathComponent(
            "artifacts/\(original.uuid.uuidString).json")
        let originalBytes = try Data(contentsOf: url)
        var conflicting = original
        conflicting.title = "A different artifact"
        conflicting.source = "Different retained source"

        let result = await adopt(conflicting, taskID: taskID, store: store)

        XCTAssertEqual(result, .identityCollision)
        XCTAssertEqual(store.artifacts, [original])
        XCTAssertEqual(try Data(contentsOf: url), originalBytes)
        let reloaded = ArtifactStore(
            appSupportBaseOverride: root,
            watchesDirectory: false)
        XCTAssertEqual(reloaded.artifacts, [original])
    }

    func testStaleSkippedAndWrongTaskRevisionsCannotReplaceExistingArtifact() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ArtifactStore(
            appSupportBaseOverride: root,
            watchesDirectory: false)
        let original = artifact()
        let taskID = "scheduled-task-lineage"
        let first = await adopt(original, taskID: taskID, store: store)
        XCTAssertEqual(first, .published)
        let url = root.appendingPathComponent(
            "artifacts/\(original.uuid.uuidString).json")
        let originalBytes = try Data(contentsOf: url)

        var stale = original
        stale.source = "stale same-revision write"
        stale.updatedAt = stale.updatedAt.addingTimeInterval(10)
        let staleResult = await adopt(stale, taskID: taskID, store: store)
        XCTAssertEqual(staleResult, .identityCollision)

        var skipped = original
        skipped.source = "skipped revision"
        skipped.updatedAt = skipped.updatedAt.addingTimeInterval(20)
        skipped.revisions += 2
        let skippedResult = await adopt(skipped, taskID: taskID, store: store)
        XCTAssertEqual(skippedResult, .identityCollision)

        var wrongTask = original
        wrongTask.source = "wrong producer lineage"
        wrongTask.updatedAt = wrongTask.updatedAt.addingTimeInterval(30)
        wrongTask.revisions += 1
        let wrongTaskResult = await adopt(
            wrongTask, taskID: "other-task", store: store)
        XCTAssertEqual(wrongTaskResult, .identityCollision)

        XCTAssertEqual(store.artifacts, [original])
        XCTAssertEqual(try Data(contentsOf: url), originalBytes)
    }

}

/// FR-197 — a background revision is intermittently refused as an identity collision when a user
/// edit is still in flight. `ArtifactStore.swift:640` decides that from a synchronous file-exists
/// check while the write runs on the `.utility` `io` queue.
///
/// Not reproduced here, and deliberately not papered over: an attempted fix that drained pending
/// persistence before the collision test made `testUserOrganizationQueuedDuringAdoptionRebasesBeforeReceipt`
/// fail instead, because that path is built around user edits queued *during* an adoption being
/// rebased into it. Draining first defeats that interleaving. The remedy needs the adoption and
/// rebase design considered together, not a guard moved earlier.
///
/// What is pinned below is the half that must not change while that is worked out.
final class ArtifactAdoptionCollisionTests: XCTestCase {
    private func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("artifact-race-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    static func fixture(source: String) -> Artifact {
        Artifact(
            title: "Dashboard", type: "markdown", source: source,
            favorite: false, origin: "ambient",
            workspaceID: nil, conversationID: nil, conversationTitle: "", cwd: "",
            uuid: UUID(),
            createdAt: Date(timeIntervalSince1970: 1),
            updatedAt: Date(timeIntervalSince1970: 1),
            revisions: 1)
    }

    @MainActor
    private func adopt(
        _ artifact: Artifact, taskID: String, store: ArtifactStore
    ) async -> BackgroundArtifactAdoptionResult {
        await withCheckedContinuation { continuation in
            store.adoptBackgroundArtifact(
                artifact, producerTaskID: taskID,
                retainedSourceBytes: Data(artifact.source.utf8)) { continuation.resume(returning: $0) }
        }
    }

    /// An Artifact known in memory whose canonical file is genuinely gone is a real collision:
    /// republishing would create two Legacy authorities for one identity.
    @MainActor
    func testAGenuinelyAbsentCanonicalFileIsACollision() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ArtifactStore(appSupportBaseOverride: root, watchesDirectory: false)
        let artifact = Self.fixture(source: "# one\n")
        let published = await adopt(artifact, taskID: "task", store: store)
        XCTAssertEqual(published, .published)

        let canonical = root.appendingPathComponent(
            "artifacts/\(artifact.uuid.uuidString).json")
        try? FileManager.default.removeItem(at: canonical)
        XCTAssertFalse(FileManager.default.fileExists(atPath: canonical.path))

        var successor = artifact
        successor.source = "# two\n"
        successor.updatedAt = Date(timeIntervalSince1970: 2)
        successor.revisions += 1

        let collided = await adopt(successor, taskID: "task", store: store)
        XCTAssertEqual(
            collided, .identityCollision,
            "a missing canonical file with the Artifact still known must not be republished")
    }
}
