import CryptoKit
import Foundation
import XCTest
@testable import Mechanician

@MainActor
final class BackgroundConversationInboxAdopterTests: XCTestCase {
    private struct Fixture {
        let root: URL
        let pending: URL
        let adopted: URL
        let quarantine: URL
        let conversations: URL
    }

    private func makeFixture() throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "background-conversation-inbox-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700], ofItemAtPath: root.path)
        let pending = try makePrivateDirectory(
            "authority-inbox/v1/pending/ambientd", root: root)
        let adopted = try makePrivateDirectory(
            "authority-inbox/v1/adopted/ambientd", root: root)
        let quarantine = try makePrivateDirectory(
            "authority-inbox/v1/quarantine/ambientd", root: root)
        _ = try makePrivateDirectory(
            "authority-inbox/v1/staging/ambientd", root: root)
        let conversations = try makePrivateDirectory("conversations", root: root)
        return Fixture(
            root: root,
            pending: pending,
            adopted: adopted,
            quarantine: quarantine,
            conversations: conversations)
    }

    private func makePrivateDirectory(_ relativePath: String, root: URL) throws -> URL {
        var cursor = root
        for component in relativePath.split(separator: "/") {
            cursor.appendPathComponent(String(component), isDirectory: true)
            if !FileManager.default.fileExists(atPath: cursor.path) {
                try FileManager.default.createDirectory(
                    at: cursor,
                    withIntermediateDirectories: false,
                    attributes: [.posixPermissions: 0o700])
            }
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o700], ofItemAtPath: cursor.path)
        }
        return cursor
    }

    private func conversation(
        id: UUID = UUID(),
        title: String = "Ambient result"
    ) -> Conversation {
        let completedAt = Date(timeIntervalSince1970: 1_807_091_696)
        return Conversation(
            id: id,
            title: title,
            cwd: "",
            sdkSessionId: nil,
            messages: [
                TranscriptEntry(
                    id: UUID(), kind: .user, text: "Run scheduled work",
                    observedAt: completedAt),
                TranscriptEntry(
                    id: UUID(), kind: .assistant, text: "Completed scheduled work",
                    observedAt: completedAt),
            ],
            updatedAt: completedAt)
    }

    private func envelopeBytes(
        operationID: UUID,
        conversation: Conversation,
        mutatePayload: ((inout [String: Any]) -> Void)? = nil
    ) throws -> Data {
        let messages: [[String: Any]] = try conversation.messages.map { entry in
            guard let observedAt = entry.observedAt else {
                throw NSError(
                    domain: "BackgroundConversationInboxAdopterTests",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "fixture message needs observedAt"])
            }
            return [
                "id": entry.id.uuidString,
                "kind": entry.kind.rawValue,
                "text": entry.text,
                "observedAt": SendableISO8601Formatter.fractional.string(from: observedAt),
                "toolIsError": false,
                "permDecided": false,
                "permAllowed": false,
            ]
        }
        var payload: [String: Any] = [
            "id": conversation.id.uuidString,
            "title": conversation.title,
            "projectID": conversation.projectID?.uuidString ?? NSNull(),
            "cwd": conversation.cwd,
            "sdkSessionId": NSNull(),
            "messages": messages,
            "updatedAt": SendableISO8601Formatter.fractional.string(
                from: conversation.updatedAt),
            "errored": conversation.errored,
            "artifacts": [Any](),
            "workflowRuns": [String: Any](),
        ]
        mutatePayload?(&payload)
        let payloadBytes = try JSONSerialization.data(
            withJSONObject: payload, options: [.sortedKeys])
        let payloadBase64 = payloadBytes.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        let envelope: [String: Any] = [
            "schemaVersion": 1,
            "operationID": operationID.uuidString,
            "subjectID": conversation.id.uuidString,
            "producer": ["id": "ambientd", "build": "mechanician-test-authority-inbox-v1"],
            "authority": [
                "protocol": "storage-authority-v1",
                "observedGeneration": "legacy-unmarked",
            ],
            "domain": "conversation",
            "kind": "create",
            "definitionRevision": "fixture-definition-revision",
            "createdAt": "2026-08-05T12:34:56Z",
            "payload": [
                "encoding": "base64url-json",
                "byteCount": payloadBytes.count,
                "sha256": digest(payloadBytes),
                "data": payloadBase64,
            ],
            "retainedBytes": [],
        ]
        return try JSONSerialization.data(withJSONObject: envelope, options: [.sortedKeys])
    }

    private func artifactEnvelopeBytes(
        operationID: UUID,
        artifactID: UUID,
        taskID: String,
        source: String,
        cwd: String
    ) throws -> Data {
        let sourceBytes = Data(source.utf8)
        let payload: [String: Any] = [
            "artifact": [
                "id": artifactID.uuidString,
                "title": "Ambient report",
                "type": "markdown",
                "createdAt": "2026-08-05T12:34:56Z",
                "updatedAt": "2026-08-05T12:34:56Z",
                "revisions": 1,
                "favorite": false,
                "origin": "ambient",
                "taskId": taskID,
                "conversationID": NSNull(),
                "conversationTitle": "⏰ Report task",
                "workspaceID": NSNull(),
                "cwd": cwd,
            ],
            "source": ["retainedByteID": "source", "encoding": "utf-8"],
        ]
        let payloadBytes = try JSONSerialization.data(
            withJSONObject: payload, options: [.sortedKeys])
        let payloadBase64 = payloadBytes.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        let envelope: [String: Any] = [
            "schemaVersion": 1,
            "operationID": operationID.uuidString,
            "subjectID": artifactID.uuidString,
            "producer": ["id": "ambientd", "build": "mechanician-test-authority-inbox-v1"],
            "authority": [
                "protocol": "storage-authority-v1",
                "observedGeneration": "legacy-unmarked",
            ],
            "domain": "artifact",
            "kind": "upsert",
            "definitionRevision": "fixture-definition-revision",
            "createdAt": "2026-08-05T12:34:56Z",
            "payload": [
                "encoding": "base64url-json",
                "byteCount": payloadBytes.count,
                "sha256": digest(payloadBytes),
                "data": payloadBase64,
            ],
            "retainedBytes": [[
                "id": "source",
                "relativePath": "retained/\(operationID.uuidString)/source",
                "byteCount": sourceBytes.count,
                "sha256": digest(sourceBytes),
                "mediaType": "text/markdown; charset=utf-8",
            ]],
        ]
        return try JSONSerialization.data(withJSONObject: envelope, options: [.sortedKeys])
    }

    private func publishRetainedArtifactSource(
        _ source: Data,
        operationID: UUID,
        root: URL
    ) throws -> URL {
        let directory = try makePrivateDirectory(
            "authority-inbox/v1/retained/\(operationID.uuidString)", root: root)
        let destination = directory.appendingPathComponent("source")
        try source.write(to: destination, options: .withoutOverwriting)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o400], ofItemAtPath: destination.path)
        return destination
    }

    @discardableResult
    private func publish(
        _ bytes: Data,
        operationID: UUID,
        into pending: URL
    ) throws -> URL {
        let url = pending.appendingPathComponent("\(operationID.uuidString).json")
        let descriptor = Darwin.open(
            url.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
            mode_t(0o600))
        guard descriptor >= 0 else {
            throw POSIXError(.init(rawValue: errno) ?? .EIO)
        }
        defer { Darwin.close(descriptor) }
        try bytes.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let count = Darwin.write(
                    descriptor, raw.baseAddress?.advanced(by: offset), raw.count - offset)
                if count < 0, errno == EINTR { continue }
                guard count > 0 else {
                    throw POSIXError(.init(rawValue: errno) ?? .EIO)
                }
                offset += count
            }
        }
        guard fsync(descriptor) == 0, fchmod(descriptor, mode_t(0o400)) == 0 else {
            throw POSIXError(.init(rawValue: errno) ?? .EIO)
        }
        return url
    }

    private func runOneScan(_ adopter: BackgroundConversationInboxAdopter) async {
        let completed = expectation(description: "authority-inbox adoption scan")
        adopter.scanForTesting { completed.fulfill() }
        await fulfillment(of: [completed], timeout: 5)
    }

    private func rawQuarantineFiles(_ fixture: Fixture) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(
            at: fixture.quarantine, includingPropertiesForKeys: nil)
            .filter { !$0.lastPathComponent.hasSuffix(".diagnostic.json") }
    }

    private func digest(_ bytes: Data) -> String {
        SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }

    /// The timeout is patience, not a performance assertion. These conditions wait on a real
    /// filesystem watcher round trip, and 5 seconds started failing intermittently as the suite
    /// grew — the watcher was working, it just had not been scheduled yet. A genuinely broken
    /// watcher still fails, one wait later.
    private func waitUntil(
        timeout: TimeInterval = 15,
        _ condition: @escaping @MainActor () -> Bool
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 25_000_000)
        }
        return condition()
    }

    func testValidEnvelopePublishesConversationThenDurableAdoptedReceipt() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let operationID = UUID()
        let candidate = conversation()
        let bytes = try envelopeBytes(operationID: operationID, conversation: candidate)
        let pending = try publish(bytes, operationID: operationID, into: fixture.pending)
        let store = ConversationStore(
            appSupportBaseOverride: fixture.root,
            watchesDirectory: false)
        let adopter = BackgroundConversationInboxAdopter(anchorRoot: fixture.root)

        adopter.start(conversationStore: store, watchesDirectory: false)
        await runOneScan(adopter)
        store.flushSaves()

        let adopted = fixture.adopted.appendingPathComponent("\(operationID.uuidString).json")
        XCTAssertFalse(FileManager.default.fileExists(atPath: pending.path))
        XCTAssertEqual(try Data(contentsOf: adopted), bytes)
        XCTAssertEqual(store.conversation(candidate.id)?.title, candidate.title)
        let sidecar = fixture.conversations.appendingPathComponent("\(candidate.id.uuidString).json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: sidecar.path))
    }

    func testExactLivePayloadConstructsOnlyInertConversationState() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let workspaceID = UUID()
        let operationID = UUID()
        var candidate = conversation()
        candidate.projectID = workspaceID
        candidate.errored = true
        let bytes = try envelopeBytes(operationID: operationID, conversation: candidate)
        _ = try publish(bytes, operationID: operationID, into: fixture.pending)
        let store = ConversationStore(appSupportBaseOverride: fixture.root, watchesDirectory: false)
        let adopter = BackgroundConversationInboxAdopter(anchorRoot: fixture.root)

        adopter.start(conversationStore: store, watchesDirectory: false)
        await runOneScan(adopter)
        store.flushSaves()

        let adopted = try XCTUnwrap(store.conversation(candidate.id))
        XCTAssertEqual(adopted.projectID, workspaceID)
        XCTAssertEqual(adopted.messages.map(\.kind), [.user, .assistant])
        XCTAssertEqual(adopted.messages.map(\.text), candidate.messages.map(\.text))
        XCTAssertTrue(adopted.errored)
        XCTAssertNil(adopted.sdkSessionId)
        XCTAssertNil(adopted.sdkSessionRouteIdentity)
        XCTAssertNil(adopted.sdkSessionExtensionRevision)
        XCTAssertNil(adopted.sdkSessionWorkspaceInstructionsRevision)
        XCTAssertNil(adopted.modelSelection)
        XCTAssertNil(adopted.forkProvenance)
        XCTAssertTrue(adopted.artifacts.isEmpty)
        XCTAssertTrue(adopted.workflowRuns.isEmpty)
        XCTAssertTrue(adopted.subagents.isEmpty)
        XCTAssertTrue(adopted.agentActivity.isEmpty)
        XCTAssertTrue(adopted.queuedPrompts.isEmpty)
        XCTAssertNil(adopted.pendingTurnPrompt)
        XCTAssertTrue(adopted.draft.isEmpty)
        XCTAssertFalse(adopted.favorite)
        XCTAssertNil(adopted.sortIndex)
        XCTAssertNil(adopted.armedTrigger)
        XCTAssertFalse(adopted.unread)
        XCTAssertNil(adopted.contextTokens)
        XCTAssertNil(adopted.contextWindow)
        XCTAssertNil(adopted.contextModel)
        XCTAssertNil(adopted.providerAccessRequest)
        XCTAssertNil(adopted.claudePreferences)
        XCTAssertNil(adopted.claudeEffectiveModel)
        XCTAssertFalse(adopted.awaitingQuestion)
    }

    func testRejectsOperativeAndPrivateFieldsAtAmbientTrustBoundary() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let draftCandidate = conversation()
        let sessionCandidate = conversation()
        let nestedToolCandidate = conversation()
        let candidates: [(UUID, Conversation, (inout [String: Any]) -> Void)] = [
            (UUID(), draftCandidate, { $0["draft"] = "external draft must not cross" }),
            (UUID(), sessionCandidate, { $0["sdkSessionId"] = "provider-resume-handle" }),
            (UUID(), nestedToolCandidate, { payload in
                var messages = payload["messages"] as! [[String: Any]]
                messages[1]["toolName"] = "Bash"
                payload["messages"] = messages
            }),
        ]
        for (operationID, candidate, mutation) in candidates {
            let bytes = try envelopeBytes(
                operationID: operationID,
                conversation: candidate,
                mutatePayload: mutation)
            _ = try publish(bytes, operationID: operationID, into: fixture.pending)
        }
        let store = ConversationStore(appSupportBaseOverride: fixture.root, watchesDirectory: false)
        let adopter = BackgroundConversationInboxAdopter(anchorRoot: fixture.root)

        adopter.start(conversationStore: store, watchesDirectory: false)
        await runOneScan(adopter)

        XCTAssertNil(store.conversation(draftCandidate.id))
        XCTAssertNil(store.conversation(sessionCandidate.id))
        XCTAssertNil(store.conversation(nestedToolCandidate.id))
        XCTAssertEqual(try rawQuarantineFiles(fixture).count, 3)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(
            at: fixture.adopted, includingPropertiesForKeys: nil).isEmpty)
    }

    func testExactReplayIsIdempotentAndDoesNotDuplicateConversationOrReceipt() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let operationID = UUID()
        let candidate = conversation()
        let bytes = try envelopeBytes(operationID: operationID, conversation: candidate)
        _ = try publish(bytes, operationID: operationID, into: fixture.pending)
        let store = ConversationStore(appSupportBaseOverride: fixture.root, watchesDirectory: false)
        let adopter = BackgroundConversationInboxAdopter(anchorRoot: fixture.root)
        adopter.start(conversationStore: store, watchesDirectory: false)
        await runOneScan(adopter)

        _ = try publish(bytes, operationID: operationID, into: fixture.pending)
        await runOneScan(adopter)
        store.flushSaves()

        XCTAssertEqual(store.summaries.filter { $0.id == candidate.id }.count, 1)
        XCTAssertTrue(try rawQuarantineFiles(fixture).isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: fixture.pending.appendingPathComponent(
                "\(operationID.uuidString).json").path))
    }

    func testDuplicateOfExistingReceiptDoesNotOverwriteEvolvedConversation() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let operationID = UUID()
        let candidate = conversation()
        let bytes = try envelopeBytes(operationID: operationID, conversation: candidate)
        _ = try publish(bytes, operationID: operationID, into: fixture.pending)
        let store = ConversationStore(appSupportBaseOverride: fixture.root, watchesDirectory: false)
        let adopter = BackgroundConversationInboxAdopter(anchorRoot: fixture.root)
        adopter.start(conversationStore: store, watchesDirectory: false)
        await runOneScan(adopter)
        store.update(candidate.id) { $0.title = "Later user-visible title" }
        store.flushSaves()

        _ = try publish(bytes, operationID: operationID, into: fixture.pending)
        await runOneScan(adopter)

        XCTAssertEqual(store.conversation(candidate.id)?.title, "Later user-visible title")
        XCTAssertTrue(try rawQuarantineFiles(fixture).isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: fixture.pending.appendingPathComponent(
                "\(operationID.uuidString).json").path))
    }

    func testMismatchedExistingReceiptIsNotAcceptedAsReplayProof() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let operationID = UUID()
        let receiptConversation = conversation(title: "Different prior operation bytes")
        let receiptBytes = try envelopeBytes(
            operationID: operationID, conversation: receiptConversation)
        _ = try publish(receiptBytes, operationID: operationID, into: fixture.adopted)

        let candidate = conversation(title: "Pending candidate")
        let pendingBytes = try envelopeBytes(operationID: operationID, conversation: candidate)
        _ = try publish(pendingBytes, operationID: operationID, into: fixture.pending)
        let store = ConversationStore(appSupportBaseOverride: fixture.root, watchesDirectory: false)
        let adopter = BackgroundConversationInboxAdopter(anchorRoot: fixture.root)

        adopter.start(conversationStore: store, watchesDirectory: false)
        await runOneScan(adopter)

        XCTAssertNil(store.conversation(candidate.id))
        XCTAssertEqual(
            try Data(contentsOf: fixture.adopted.appendingPathComponent(
                "\(operationID.uuidString).json")),
            receiptBytes)
        XCTAssertEqual(try rawQuarantineFiles(fixture).count, 1)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: fixture.pending.appendingPathComponent(
                "\(operationID.uuidString).json").path))
    }

    func testUnseenCanonicalSidecarRaceCannotBeOverwrittenByAdoption() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let conversationID = UUID()
        let store = ConversationStore(appSupportBaseOverride: fixture.root, watchesDirectory: false)

        // The store's inventory is intentionally already closed when another valid Legacy source
        // appears. The create-only publication must discover it atomically, never overwrite it in
        // the gap between a MainActor inventory check and the save-queue write.
        let unseen = conversation(id: conversationID, title: "Unseen disk truth")
        let unseenBytes = try ConversationStore.makeEncoder().encode(unseen)
        let sidecar = fixture.conversations.appendingPathComponent(
            "\(conversationID.uuidString).json")
        try unseenBytes.write(to: sidecar, options: .withoutOverwriting)

        let candidate = conversation(id: conversationID, title: "External candidate")
        let operationID = UUID()
        let envelope = try envelopeBytes(operationID: operationID, conversation: candidate)
        _ = try publish(envelope, operationID: operationID, into: fixture.pending)
        let adopter = BackgroundConversationInboxAdopter(anchorRoot: fixture.root)

        adopter.start(conversationStore: store, watchesDirectory: false)
        await runOneScan(adopter)

        XCTAssertEqual(try Data(contentsOf: sidecar), unseenBytes)
        XCTAssertNil(store.conversation(conversationID))
        XCTAssertEqual(try rawQuarantineFiles(fixture).count, 1)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: fixture.adopted.appendingPathComponent(
                "\(operationID.uuidString).json").path))
    }

    func testConversationIdentityCollisionQuarantinesWithoutReplacingExistingRecord() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let conversationID = UUID()
        let existing = conversation(id: conversationID, title: "Existing user record")
        let candidate = conversation(id: conversationID, title: "Conflicting producer record")
        let operationID = UUID()
        let bytes = try envelopeBytes(operationID: operationID, conversation: candidate)
        _ = try publish(bytes, operationID: operationID, into: fixture.pending)
        let store = ConversationStore(appSupportBaseOverride: fixture.root, watchesDirectory: false)
        store.upsert(existing)
        store.flushSaves()
        let adopter = BackgroundConversationInboxAdopter(anchorRoot: fixture.root)

        adopter.start(conversationStore: store, watchesDirectory: false)
        await runOneScan(adopter)

        XCTAssertEqual(store.conversation(conversationID)?.title, "Existing user record")
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: fixture.adopted.appendingPathComponent(
                "\(operationID.uuidString).json").path))
        let quarantined = try rawQuarantineFiles(fixture)
        XCTAssertEqual(quarantined.count, 1)
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(quarantined.first)), bytes)
        let census = LibraryAuthorityInboxOperationScanner.scan(supportRoot: fixture.root)
        XCTAssertFalse(census.hasCompleteCensus)
        XCTAssertEqual(census.issues.first?.operationID, operationID)
    }

    func testMalformedSourceQuarantinesWhileIncompletePublicationRemainsPending() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let malformedID = UUID()
        let malformed = Data("{\"not\":\"an envelope\"}".utf8)
        _ = try publish(malformed, operationID: malformedID, into: fixture.pending)

        let incompleteID = UUID()
        let incompleteConversation = conversation()
        let incompleteBytes = try envelopeBytes(
            operationID: incompleteID, conversation: incompleteConversation)
        let incomplete = try publish(
            incompleteBytes, operationID: incompleteID, into: fixture.pending)
        let extraLink = fixture.root.appendingPathComponent("incomplete-publication-link")
        try FileManager.default.linkItem(at: incomplete, to: extraLink)

        let store = ConversationStore(appSupportBaseOverride: fixture.root, watchesDirectory: false)
        let adopter = BackgroundConversationInboxAdopter(anchorRoot: fixture.root)
        adopter.start(conversationStore: store, watchesDirectory: false)
        await runOneScan(adopter)

        XCTAssertFalse(FileManager.default.fileExists(
            atPath: fixture.pending.appendingPathComponent(
                "\(malformedID.uuidString).json").path))
        XCTAssertEqual(try rawQuarantineFiles(fixture).count, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: incomplete.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: extraLink.path))
        XCTAssertNil(store.conversation(incompleteConversation.id))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: fixture.adopted.appendingPathComponent(
                "\(incompleteID.uuidString).json").path))
    }

    func testSaveFailureLeavesEnvelopePendingThenRetryPublishesBeforeReceipt() async throws {
        let fixture = try makeFixture()
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o700], ofItemAtPath: fixture.conversations.path)
            try? FileManager.default.removeItem(at: fixture.root)
        }
        let operationID = UUID()
        let candidate = conversation()
        let bytes = try envelopeBytes(operationID: operationID, conversation: candidate)
        let pending = try publish(bytes, operationID: operationID, into: fixture.pending)
        let store = ConversationStore(appSupportBaseOverride: fixture.root, watchesDirectory: false)
        let adopter = BackgroundConversationInboxAdopter(anchorRoot: fixture.root)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o500], ofItemAtPath: fixture.conversations.path)

        adopter.start(conversationStore: store, watchesDirectory: false)
        await runOneScan(adopter)
        store.flushSaves()

        XCTAssertTrue(FileManager.default.fileExists(atPath: pending.path))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: fixture.adopted.appendingPathComponent(
                "\(operationID.uuidString).json").path))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: fixture.conversations.appendingPathComponent(
                "\(candidate.id.uuidString).json").path))

        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700], ofItemAtPath: fixture.conversations.path)
        await runOneScan(adopter)
        store.flushSaves()

        XCTAssertFalse(FileManager.default.fileExists(atPath: pending.path))
        XCTAssertEqual(
            try Data(contentsOf: fixture.adopted.appendingPathComponent(
                "\(operationID.uuidString).json")),
            bytes)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: fixture.conversations.appendingPathComponent(
                "\(candidate.id.uuidString).json").path))
    }

    func testArtifactAdoptionPublishesTaskProvenanceAndReplayPreservesUserEvolution() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let operationID = UUID()
        let artifactID = UUID()
        let taskID = "ambient-report-task"
        let source = "# Daily report\n\nEverything is nominal.\n"
        _ = try publishRetainedArtifactSource(
            Data(source.utf8), operationID: operationID, root: fixture.root)
        let bytes = try artifactEnvelopeBytes(
            operationID: operationID,
            artifactID: artifactID,
            taskID: taskID,
            source: source,
            cwd: fixture.root.path)
        _ = try publish(bytes, operationID: operationID, into: fixture.pending)
        let conversations = ConversationStore(
            appSupportBaseOverride: fixture.root, watchesDirectory: false)
        let artifacts = ArtifactStore(
            appSupportBaseOverride: fixture.root, watchesDirectory: false)
        let adopter = BackgroundConversationInboxAdopter(
            anchorRoot: fixture.root,
            artifactStore: artifacts)

        adopter.start(conversationStore: conversations, watchesDirectory: false)
        await runOneScan(adopter)
        artifacts.flushSaves()

        let adopted = fixture.adopted.appendingPathComponent(
            "\(operationID.uuidString).json")
        XCTAssertEqual(try Data(contentsOf: adopted), bytes)
        XCTAssertEqual(artifacts.artifacts.first(where: { $0.uuid == artifactID })?.source, source)
        let legacyURL = fixture.root.appendingPathComponent(
            "artifacts/\(artifactID.uuidString).json")
        let legacy = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(contentsOf: legacyURL))
                as? [String: Any])
        XCTAssertEqual(legacy["taskId"] as? String, taskID)

        artifacts.rename(
            artifactID,
            to: "User-renamed report",
            conversations: conversations,
            synchronizeLiveState: false)
        artifacts.flushSaves()
        _ = try publish(bytes, operationID: operationID, into: fixture.pending)
        await runOneScan(adopter)

        XCTAssertEqual(
            artifacts.artifacts.first(where: { $0.uuid == artifactID })?.title,
            "User-renamed report")
        XCTAssertTrue(try rawQuarantineFiles(fixture).isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: fixture.pending.appendingPathComponent(
                "\(operationID.uuidString).json").path))
    }

    func testArtifactRetainedDigestPathAndSourceMismatchQuarantineWithoutWrite() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let expectedSource = Data("# Expected\n".utf8)
        let cases: [(kind: String, source: Data, mutate: (inout [String: Any]) -> Void)] = [
            ("digest", expectedSource, { envelope in
                var retained = envelope["retainedBytes"] as! [[String: Any]]
                retained[0]["sha256"] = String(repeating: "0", count: 64)
                envelope["retainedBytes"] = retained
            }),
            ("path", expectedSource, { envelope in
                var retained = envelope["retainedBytes"] as! [[String: Any]]
                retained[0]["relativePath"] = "retained/not-this-operation/source"
                envelope["retainedBytes"] = retained
            }),
            ("source", Data("# Different bytes\n".utf8), { _ in }),
        ]
        var artifactIDs: [UUID] = []
        for entry in cases {
            let operationID = UUID()
            let artifactID = UUID()
            artifactIDs.append(artifactID)
            _ = try publishRetainedArtifactSource(
                entry.source, operationID: operationID, root: fixture.root)
            let original = try artifactEnvelopeBytes(
                operationID: operationID,
                artifactID: artifactID,
                taskID: "retained-mismatch-\(entry.kind)",
                source: String(decoding: expectedSource, as: UTF8.self),
                cwd: fixture.root.path)
            var envelope = try XCTUnwrap(
                try JSONSerialization.jsonObject(with: original) as? [String: Any])
            entry.mutate(&envelope)
            let bytes = try JSONSerialization.data(
                withJSONObject: envelope, options: [.sortedKeys])
            _ = try publish(bytes, operationID: operationID, into: fixture.pending)
        }
        let conversations = ConversationStore(
            appSupportBaseOverride: fixture.root, watchesDirectory: false)
        let artifacts = ArtifactStore(
            appSupportBaseOverride: fixture.root, watchesDirectory: false)
        let adopter = BackgroundConversationInboxAdopter(
            anchorRoot: fixture.root, artifactStore: artifacts)

        adopter.start(conversationStore: conversations, watchesDirectory: false)
        await runOneScan(adopter)

        XCTAssertTrue(artifacts.artifacts.filter { artifactIDs.contains($0.uuid) }.isEmpty)
        XCTAssertEqual(try rawQuarantineFiles(fixture).count, cases.count)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(
            at: fixture.adopted, includingPropertiesForKeys: nil).isEmpty)
    }

    func testWatcherRecreatesAndRearmsAfterPendingDirectoryRename() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let store = ConversationStore(appSupportBaseOverride: fixture.root, watchesDirectory: false)
        let adopter = BackgroundConversationInboxAdopter(anchorRoot: fixture.root)
        adopter.start(conversationStore: store, watchesDirectory: true)

        let displaced = fixture.root.appendingPathComponent(
            "displaced-pending-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.moveItem(at: fixture.pending, to: displaced)
        // LONGER THAN THE MECHANISM'S OWN CEILING. `scheduleWatcherRepair` backs off from 0.25s by
        // doubling, capped at 30 — so once a few attempts fail, the next one can be 16 or 30 seconds
        // away and a 15-second wait loses to the schedule rather than to a defect. Observed failing
        // at 15.7s on a machine that was also running a build and copying a 2.4 GB backup, and
        // passing in 0.7s on the same machine a moment later.
        //
        // Waiting past the ceiling is the fix; raising it a little and re-running is how a flake
        // stays.
        let recreated = await waitUntil(timeout: 45) {
            var metadata = stat()
            return lstat(fixture.pending.path, &metadata) == 0
                && metadata.st_mode & S_IFMT == S_IFDIR
        }
        XCTAssertTrue(recreated)

        let operationID = UUID()
        let candidate = conversation()
        let bytes = try envelopeBytes(operationID: operationID, conversation: candidate)
        _ = try publish(bytes, operationID: operationID, into: fixture.pending)

        let receipt = fixture.adopted.appendingPathComponent(
            "\(operationID.uuidString).json")
        // Same ceiling applies: this one cannot succeed until the watcher above is live again.
        let adopted = await waitUntil(timeout: 45) {
            store.conversation(candidate.id) != nil
                && FileManager.default.fileExists(atPath: receipt.path)
        }
        XCTAssertTrue(adopted)
        store.flushSaves()
        XCTAssertEqual(try Data(contentsOf: receipt), bytes)
    }
}
