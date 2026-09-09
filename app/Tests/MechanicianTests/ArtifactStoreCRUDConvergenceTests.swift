import XCTest
@testable import Mechanician

@MainActor
final class ArtifactStoreCRUDConvergenceTests: XCTestCase {
    private struct Stores {
        let support: URL
        let conversations: ConversationStore
        let artifacts: ArtifactStore
    }

    private func makeStores() throws -> Stores {
        let support = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "mechanician-artifact-crud-\(UUID().uuidString)",
                isDirectory: true)
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        return Stores(
            support: support,
            conversations: ConversationStore(
                appSupportBaseOverride: support,
                watchesDirectory: false),
            artifacts: ArtifactStore(
                appSupportBaseOverride: support,
                watchesDirectory: false))
    }

    private func seed(_ stores: Stores) -> (conversation: Conversation, artifact: Artifact) {
        let artifactID = UUID()
        var conversation = Conversation(
            title: "Artifact source",
            cwd: "/old/workspace",
            sdkSessionId: nil,
            messages: [],
            updatedAt: Date())
        conversation.projectID = UUID()
        // ConversationStore intentionally prunes empty placeholders on relaunch. Keep this fixture
        // as a real durable conversation so the test measures artifact convergence rather than
        // placeholder cleanup.
        conversation.draft = "Durable fixture"
        conversation.artifacts = [
            Artifact(
                title: "Plan",
                type: "markdown",
                source: "# Plan",
                workspaceID: conversation.projectID,
                conversationID: conversation.id,
                conversationTitle: conversation.title,
                cwd: conversation.cwd,
                uuid: artifactID)
        ]
        stores.conversations.upsert(conversation)
        let artifact = stores.artifacts.upsertFromAgent(
            title: "Plan",
            type: "markdown",
            source: "# Plan",
            workspaceID: conversation.projectID,
            conversationID: conversation.id,
            conversationTitle: conversation.title,
            cwd: conversation.cwd,
            preferredID: artifactID)
        return (conversation, artifact)
    }

    private func cleanUp(_ stores: Stores) {
        stores.conversations.flushSaves()
        stores.artifacts.flushSaves()
        try? FileManager.default.removeItem(at: stores.support)
    }

    func testRenameFavoriteAndSourceEditConvergeAndSurviveRelaunch() throws {
        let stores = try makeStores()
        defer { cleanUp(stores) }
        let seeded = seed(stores)

        stores.artifacts.rename(
            seeded.artifact.uuid,
            to: "Revised Plan",
            conversations: stores.conversations,
            synchronizeLiveState: false)
        stores.artifacts.setFavorite(
            seeded.artifact.uuid,
            true,
            conversations: stores.conversations,
            synchronizeLiveState: false)
        stores.artifacts.updateSource(
            seeded.artifact.uuid,
            "# Revised",
            conversations: stores.conversations,
            synchronizeLiveState: false)
        stores.conversations.flushSaves()
        stores.artifacts.flushSaves()

        let relaunchedConversations = ConversationStore(
            appSupportBaseOverride: stores.support,
            watchesDirectory: false)
        let relaunchedArtifacts = ArtifactStore(
            appSupportBaseOverride: stores.support,
            watchesDirectory: false)
        let nested = try XCTUnwrap(
            relaunchedConversations.conversation(seeded.conversation.id)?.artifacts.first)
        let durable = try XCTUnwrap(
            relaunchedArtifacts.artifacts.first { $0.uuid == seeded.artifact.uuid })

        XCTAssertEqual(nested, durable)
        XCTAssertEqual(durable.title, "Revised Plan")
        XCTAssertEqual(durable.source, "# Revised")
        XCTAssertTrue(durable.favorite)
        XCTAssertEqual(durable.revisions, 2)
    }

    func testMutationsConvergeEveryConversationReferenceAndPreview() throws {
        let stores = try makeStores()
        let seeded = seed(stores)
        var reference = Conversation(
            title: "Artifact reference",
            cwd: "/reference/workspace",
            sdkSessionId: nil,
            messages: [],
            updatedAt: Date())
        reference.draft = "Durable reference fixture"
        reference.artifacts = [seeded.artifact]
        stores.conversations.upsert(reference)

        let originalPayloads = [
            PreviewPayload(conv: seeded.conversation.id, title: seeded.artifact.title),
            PreviewPayload(conv: reference.id, title: seeded.artifact.title),
        ]
        for conversationID in [seeded.conversation.id, reference.id] {
            PreviewRegistry.shared.put(seeded.artifact, conv: conversationID)
        }
        defer {
            for payload in originalPayloads {
                PreviewRegistry.shared.remove(conv: payload.conv, title: payload.title)
                PreviewRegistry.shared.remove(conv: payload.conv, title: "Shared Revised Plan")
            }
            cleanUp(stores)
        }

        stores.artifacts.rename(
            seeded.artifact.uuid,
            to: "Shared Revised Plan",
            conversations: stores.conversations)
        stores.artifacts.setFavorite(
            seeded.artifact.uuid,
            true,
            conversations: stores.conversations)
        stores.artifacts.updateSource(
            seeded.artifact.uuid,
            "# Shared revision",
            conversations: stores.conversations)
        stores.conversations.flushSaves()
        stores.artifacts.flushSaves()

        let durable = try XCTUnwrap(
            stores.artifacts.artifacts.first { $0.uuid == seeded.artifact.uuid })
        for conversationID in [seeded.conversation.id, reference.id] {
            XCTAssertEqual(
                stores.conversations.conversation(conversationID)?.artifacts,
                [durable])
            XCTAssertNil(PreviewRegistry.shared.artifact(for: PreviewPayload(
                conv: conversationID,
                title: seeded.artifact.title)))
            XCTAssertEqual(PreviewRegistry.shared.artifact(for: PreviewPayload(
                conv: conversationID,
                title: durable.title)), durable)
        }

        let relaunchedConversations = ConversationStore(
            appSupportBaseOverride: stores.support,
            watchesDirectory: false)
        let relaunchedArtifacts = ArtifactStore(
            appSupportBaseOverride: stores.support,
            watchesDirectory: false)
        let relaunchedDurable = try XCTUnwrap(
            relaunchedArtifacts.artifacts.first { $0.uuid == seeded.artifact.uuid })
        for conversationID in [seeded.conversation.id, reference.id] {
            XCTAssertEqual(
                relaunchedConversations.conversation(conversationID)?.artifacts,
                [relaunchedDurable])
        }
    }

    func testDeleteRemovesNestedSnapshotSoRelaunchCannotResurrectIt() throws {
        let stores = try makeStores()
        defer { cleanUp(stores) }
        let seeded = seed(stores)

        stores.artifacts.delete(
            seeded.artifact.uuid,
            conversations: stores.conversations,
            synchronizeLiveState: false)
        stores.conversations.flushSaves()
        stores.artifacts.flushSaves()

        let relaunchedConversations = ConversationStore(
            appSupportBaseOverride: stores.support,
            watchesDirectory: false)
        let relaunchedArtifacts = ArtifactStore(
            appSupportBaseOverride: stores.support,
            watchesDirectory: false)

        XCTAssertTrue(
            relaunchedConversations.conversation(seeded.conversation.id)?.artifacts.isEmpty == true)
        XCTAssertFalse(
            relaunchedArtifacts.artifacts.contains { $0.uuid == seeded.artifact.uuid })
    }

    func testDeleteRemovesEveryReferenceToNilProvenanceArtifact() throws {
        let stores = try makeStores()
        let artifact = stores.artifacts.create(
            title: "Standalone shared artifact",
            type: "markdown",
            source: "# Shared",
            workspaceID: UUID(),
            cwd: "/artifact/workspace")
        let conversations = ["First reference", "Second reference"].map { title -> Conversation in
            var conversation = Conversation(
                title: title,
                cwd: "/reference/workspace",
                sdkSessionId: nil,
                messages: [],
                updatedAt: Date())
            conversation.draft = "Durable reference fixture"
            conversation.artifacts = [artifact]
            stores.conversations.upsert(conversation)
            PreviewRegistry.shared.put(artifact, conv: conversation.id)
            return conversation
        }
        defer {
            for conversation in conversations {
                PreviewRegistry.shared.remove(
                    conv: conversation.id,
                    title: artifact.title)
            }
            cleanUp(stores)
        }

        stores.artifacts.delete(
            artifact.uuid,
            conversations: stores.conversations)

        for conversation in conversations {
            XCTAssertTrue(
                stores.conversations.conversation(conversation.id)?.artifacts.isEmpty == true)
            XCTAssertNil(PreviewRegistry.shared.artifact(for: PreviewPayload(
                conv: conversation.id,
                title: artifact.title)))
        }
        stores.conversations.flushSaves()
        stores.artifacts.flushSaves()

        let relaunchedConversations = ConversationStore(
            appSupportBaseOverride: stores.support,
            watchesDirectory: false)
        let relaunchedArtifacts = ArtifactStore(
            appSupportBaseOverride: stores.support,
            watchesDirectory: false)
        for conversation in conversations {
            XCTAssertTrue(
                relaunchedConversations.conversation(conversation.id)?.artifacts.isEmpty == true)
        }
        XCTAssertFalse(
            relaunchedArtifacts.artifacts.contains { $0.uuid == artifact.uuid })
    }

    func testUserCreatedArtifactStampsWorkspaceIDAndCwdTogether() throws {
        let stores = try makeStores()
        defer { cleanUp(stores) }
        let workspaceID = UUID()

        let created = stores.artifacts.create(
            title: "Loose document",
            type: "markdown",
            source: "# Notes",
            workspaceID: workspaceID,
            cwd: "/workspace")

        XCTAssertEqual(created.workspaceID, workspaceID)
        XCTAssertEqual(created.cwd, "/workspace")
    }
}
