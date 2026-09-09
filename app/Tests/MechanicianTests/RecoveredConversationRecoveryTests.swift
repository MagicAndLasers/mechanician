import Foundation
import XCTest
@testable import Mechanician

final class RecoveredConversationRecoveryTests: XCTestCase {
    @MainActor
    func testEnumeratesAndExportsExactRetainedBytes() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let service = RecoveredConversationRecoveryService(supportRoot: fixture.root)

        let bindings = try service.bindings()
        let binding = try XCTUnwrap(bindings.only)
        XCTAssertEqual(binding.id, fixture.conversation.id)
        XCTAssertEqual(binding.title, "Recovered exact bytes")
        XCTAssertEqual(binding.source.byteCount, fixture.bytes.count)
        XCTAssertEqual(
            try service.sourceURL(for: binding), fixture.source.resolvingSymlinksInPath())

        let export = fixture.root.appendingPathComponent("saved-copy.json")
        try service.exportRaw(binding, to: export)
        XCTAssertEqual(try Data(contentsOf: export), fixture.bytes)
        XCTAssertEqual(try service.bindings(), bindings, "export cannot mutate recovery state")
    }

    @MainActor
    func testRestoreCreatesCanonicalSidecarWithoutReplacingAnyLiveOwner() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let service = RecoveredConversationRecoveryService(supportRoot: fixture.root)
        let binding = try XCTUnwrap(try service.bindings().only)

        guard case .publishedLegacySidecar(let restored) = try service.restore(binding) else {
            return XCTFail("a legacy library restores by publishing its canonical sidecar")
        }
        XCTAssertEqual(restored.lastPathComponent, "\(fixture.conversation.id.uuidString).json")
        XCTAssertEqual(try Data(contentsOf: restored), fixture.bytes)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.source.path))

        XCTAssertThrowsError(try service.restore(binding)) { error in
            guard case RecoveredConversationRecoveryError.liveSourceExists(let path) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertEqual(path, restored.resolvingSymlinksInPath().path)
        }

        let liveStore = ConversationStore(
            appSupportBaseOverride: fixture.root, watchesDirectory: false)
        XCTAssertTrue(liveStore.contains(fixture.conversation.id))
    }

    @MainActor
    func testRestoreRefusesNoncanonicalLiveSourceWithSameDecodedIdentity() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let service = RecoveredConversationRecoveryService(supportRoot: fixture.root)
        let binding = try XCTUnwrap(try service.bindings().only)
        let live = fixture.source.deletingLastPathComponent()
            .appendingPathComponent("Finder copy.json")
        try fixture.bytes.write(to: live)

        XCTAssertThrowsError(try service.restore(binding)) { error in
            XCTAssertEqual(
                error as? RecoveredConversationRecoveryError,
                .liveSourceExists(live.resolvingSymlinksInPath().path))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath:
            fixture.source.deletingLastPathComponent()
                .appendingPathComponent("\(fixture.conversation.id.uuidString).json").path))
    }

    @MainActor
    func testChangedOrSymlinkEscapedRecoverySourceIsRejected() throws {
        do {
            let fixture = try makeFixture()
            defer { try? FileManager.default.removeItem(at: fixture.root) }
            let service = RecoveredConversationRecoveryService(supportRoot: fixture.root)
            let binding = try XCTUnwrap(try service.bindings().only)
            try Data("changed".utf8).write(to: fixture.source)
            XCTAssertThrowsError(try service.exportRaw(
                binding, to: fixture.root.appendingPathComponent("must-not-exist.json"))) { error in
                guard case RecoveredConversationRecoveryError.sourceChanged = error else {
                    return XCTFail("Unexpected error: \(error)")
                }
            }
        }

        do {
            let fixture = try makeFixture()
            defer { try? FileManager.default.removeItem(at: fixture.root) }
            let service = RecoveredConversationRecoveryService(supportRoot: fixture.root)
            let binding = try XCTUnwrap(try service.bindings().only)
            let real = fixture.root.appendingPathComponent("real-conversations", isDirectory: true)
            try FileManager.default.moveItem(
                at: fixture.source.deletingLastPathComponent(), to: real)
            try FileManager.default.createSymbolicLink(
                at: fixture.source.deletingLastPathComponent(),
                withDestinationURL: real)
            XCTAssertThrowsError(try service.sourceURL(for: binding)) { error in
                guard case RecoveredConversationRecoveryError.unsafeSource = error else {
                    return XCTFail("Unexpected error: \(error)")
                }
            }
        }
    }

    @MainActor
    func testRawExportCannotPublishIntoLiveConversationDirectory() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let service = RecoveredConversationRecoveryService(supportRoot: fixture.root)
        let binding = try XCTUnwrap(try service.bindings().only)
        let accidentalLive = fixture.source.deletingLastPathComponent()
            .appendingPathComponent("Accidental live copy.json")

        XCTAssertThrowsError(try service.exportRaw(binding, to: accidentalLive)) { error in
            XCTAssertEqual(
                error as? RecoveredConversationRecoveryError,
                .unsafeExportDestination(accidentalLive.path))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: accidentalLive.path))
    }

    /// The case that reaches real people: 15 quarantined sidecars sat on this developer's own
    /// machine, and once SQLite owned the library the recovery pane could not even list them —
    /// a plain shadow open refuses an active authority, correctly. Restoring one must put it in the
    /// library the app actually reads, and must survive the next launch.
    @MainActor
    func testRestoreUnderSQLiteAuthorityPromotesTheRecordItselfAndSurvivesRelaunch() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let activated = try activateAuthority(at: fixture.root)
        let service = RecoveredConversationRecoveryService(
            supportRoot: fixture.root,
            authority: { activated })

        let binding = try XCTUnwrap(try service.bindings().only)
        XCTAssertEqual(binding.id, fixture.conversation.id)

        guard case .promotedAuthorityRecord(let restored) = try service.restore(binding) else {
            return XCTFail("an active authority restores the record, not a file")
        }
        XCTAssertEqual(restored.id, fixture.conversation.id)
        XCTAssertEqual(restored.messages.map(\.text), fixture.conversation.messages.map(\.text))

        XCTAssertFalse(
            FileManager.default.fileExists(atPath: fixture.source.deletingLastPathComponent()
                .appendingPathComponent("\(fixture.conversation.id.uuidString).json").path),
            "no sidecar may be written into a directory the live library no longer reads")
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: fixture.source.path),
            "the retained bytes stay put, so a person can still export them")

        // The proof that it sticks: the launch inventory is what the app opens with, and it selects
        // on a canonical source identity. This is the assertion the old restore could not pass.
        XCTAssertTrue(
            try activated.launchInventory().conversations.contains {
                $0.summary.id == fixture.conversation.id
            },
            "a restored Conversation must be in the library the next launch reads")
        XCTAssertEqual(
            try activated.conversationSummaries().first?.title,
            "Recovered exact bytes")

        XCTAssertTrue(try service.bindings().isEmpty, "it is no longer awaiting recovery")
        XCTAssertThrowsError(try service.restore(binding)) { error in
            XCTAssertEqual(
                error as? RecoveredConversationRecoveryError,
                .bindingNoLongerCurrent,
                "a second attempt reports it is already done, not a destination collision")
        }
    }

    /// The mechanism the restore depends on, pinned from the other side: committing a recovered
    /// Conversation the ordinary way keeps the quarantine file's source identity, and the launch
    /// inventory selects on a canonical `.json` one — so the record stays hidden. That is exactly
    /// what made a restore look like it worked and then vanish on the next launch.
    @MainActor
    func testAnOrdinaryCommitLeavesARecoveredConversationHiddenFromTheNextLaunch() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let activated = try activateAuthority(at: fixture.root)

        _ = try activated.commit(conversation: fixture.conversation)
        XCTAssertFalse(
            try activated.launchInventory().conversations.contains {
                $0.summary.id == fixture.conversation.id
            },
            "an ordinary commit keeps the recovery identity, so the next launch cannot see it")
        XCTAssertFalse(
            try activated.recoveredConversationBindings().isEmpty,
            "and it is still awaiting recovery")

        try activated.restoreRecoveredConversation(fixture.conversation)
        XCTAssertTrue(
            try activated.launchInventory().conversations.contains {
                $0.summary.id == fixture.conversation.id
            })
    }

    /// Activate the fixture database as the live authority.
    @MainActor
    private func activateAuthority(at root: URL) throws -> LibraryAuthorityRepository {
        var store: SQLiteLibraryStore? = try SQLiteLibraryStore(supportRoot: root)
        let frontier = try XCTUnwrap(store).status()
        try XCTUnwrap(store).acknowledgeExactProjectionSnapshot(
            databaseInstanceID: frontier.databaseInstanceID,
            through: frontier.shadowChangeSequence,
            projectionSchemaVersion: Int(ConversationProjectionStore.schemaVersion))
        let activationID = UUID()
        try XCTUnwrap(store).prepareAuthority(
            activationID: activationID,
            minimumWriterBuild: StorageAuthorityProtocol.recognitionID)
        try XCTUnwrap(store).activatePreparedAuthority(activationID: activationID)
        let metadata = try XCTUnwrap(store).authorityMetadata()
        let marker = StorageAuthorityMarker(
            mode: .sqlite,
            activationID: activationID,
            databaseInstanceID: metadata.databaseInstanceID,
            schemaVersion: metadata.schemaVersion,
            createdAt: "2026-08-06T12:00:00Z")
        store = nil
        return try LibraryAuthorityRepository(
            store: SQLiteLibraryStore.openActiveAuthority(supportRoot: root, marker: marker),
            supportRoot: root,
            marker: marker)
    }

    private struct Fixture {
        let root: URL
        let conversation: Conversation
        let source: URL
        let bytes: Data
    }

    @MainActor
    private func makeFixture() throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "recovered-conversation-surface-\(UUID().uuidString)", isDirectory: true)
        let conversations = root.appendingPathComponent("conversations", isDirectory: true)
        try FileManager.default.createDirectory(
            at: conversations, withIntermediateDirectories: true)
        let conversation = Conversation(
            title: "Recovered exact bytes",
            cwd: "",
            sdkSessionId: nil,
            messages: [TranscriptEntry(kind: .user, text: "Preserve this exact history")],
            updatedAt: Date(timeIntervalSinceReferenceDate: 800))
        let source = conversations.appendingPathComponent(
            "\(conversation.id.uuidString).json.corrupt-1800100000-C0DE")
        let bytes = try ConversationStore.makeEncoder().encode(conversation)
        try bytes.write(to: source)
        let fingerprint = ShadowLibrarySourceFingerprint(
            identity: "conversations/\(source.lastPathComponent)",
            revision: "fixture-recovered-source-v1",
            sourceBytes: bytes)
        let home = try LibraryWorkspaceAdapter.capture(
            home: HomeWorkspaceSettings(), source: .implicitHomeWorkspace)
        let recovered = try LibraryConversationAdapter.capture(
            conversation, source: fingerprint)
        _ = try SQLiteLibraryStore(supportRoot: root).reconcile(
            ShadowLibraryImportSnapshot(
                home: home,
                workspaces: [],
                conversations: [recovered]))
        return Fixture(root: root, conversation: conversation, source: source, bytes: bytes)
    }
}

private extension Array {
    var only: Element? { count == 1 ? self[0] : nil }
}
