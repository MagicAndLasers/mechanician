import XCTest
@testable import Mechanician

@MainActor
final class ArtifactStoreWorkspaceAssignmentTests: XCTestCase {
    private func makeSupportDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "mechanician-artifact-assignment-\(UUID().uuidString)",
                isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func makeStore(_ support: URL) -> ArtifactStore {
        ArtifactStore(appSupportBaseOverride: support, watchesDirectory: false)
    }

    @discardableResult
    private func seed(
        _ store: ArtifactStore,
        title: String,
        workspaceID: UUID?,
        conversationID: UUID?,
        cwd: String,
        origin: String = "interactive",
        id: UUID = UUID()
    ) -> Artifact {
        store.upsertFromAgent(
            title: title,
            type: "markdown",
            source: "# \(title)",
            workspaceID: workspaceID,
            conversationID: conversationID,
            conversationTitle: conversationID == nil ? "" : "Source conversation",
            cwd: cwd,
            origin: origin,
            preferredID: id)
    }

    private func assertContentAndProvenancePreserved(
        _ before: Artifact,
        _ after: Artifact?,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard let after else {
            XCTFail("Expected reassigned artifact \(before.uuid)", file: file, line: line)
            return
        }
        XCTAssertEqual(after.uuid, before.uuid, file: file, line: line)
        XCTAssertEqual(after.title, before.title, file: file, line: line)
        XCTAssertEqual(after.type, before.type, file: file, line: line)
        XCTAssertEqual(after.source, before.source, file: file, line: line)
        XCTAssertEqual(after.createdAt, before.createdAt, file: file, line: line)
        XCTAssertEqual(after.updatedAt, before.updatedAt, file: file, line: line)
        XCTAssertEqual(after.revisions, before.revisions, file: file, line: line)
        XCTAssertEqual(after.favorite, before.favorite, file: file, line: line)
        XCTAssertEqual(after.origin, before.origin, file: file, line: line)
        XCTAssertEqual(after.conversationID, before.conversationID, file: file, line: line)
        XCTAssertEqual(after.conversationTitle, before.conversationTitle, file: file, line: line)
    }

    func testLiveSnapshotConvergenceUsesTheCompleteDurableArtifact() {
        let conversationID = UUID()
        let workspaceID = UUID()
        let durable = Artifact(
            title: "Canonical",
            type: "html",
            source: "<main>latest</main>",
            origin: "interactive",
            workspaceID: workspaceID,
            conversationID: conversationID,
            conversationTitle: "Source",
            cwd: "/canonical",
            uuid: UUID(),
            revisions: 4)
        var live = [
            Artifact(
                title: "Canonical",
                type: "markdown",
                source: "stale",
                workspaceID: nil,
                conversationID: nil,
                conversationTitle: "",
                cwd: "",
                uuid: UUID())
        ]

        AgentBridge.upsertLiveArtifact(&live, durable: durable)

        XCTAssertEqual(live, [durable])
    }

    func testInitialLoadIsCompleteBeforeAnImmediateConversationMoveAndPersistsAcrossRelaunch() throws {
        let support = try makeSupportDirectory()
        defer { try? FileManager.default.removeItem(at: support) }
        let conversationID = UUID()
        let oldWorkspaceID = UUID()
        let destinationID = UUID()

        var writer: ArtifactStore? = makeStore(support)
        let first = seed(
            writer!,
            title: "First",
            workspaceID: oldWorkspaceID,
            conversationID: conversationID,
            cwd: "/old")
        let second = seed(
            writer!,
            title: "Second",
            workspaceID: oldWorkspaceID,
            conversationID: conversationID,
            cwd: "/old")
        writer?.flushSaves()
        writer = nil

        let store = makeStore(support)
        XCTAssertTrue(store.isInitialLoadComplete)
        XCTAssertEqual(Set(store.artifacts.map(\.uuid)), Set([first.uuid, second.uuid]))

        let moved = store.reassignArtifacts(
            forConversation: conversationID,
            workspaceID: destinationID,
            cwd: "/new")

        XCTAssertEqual(Set(moved.map(\.uuid)), Set([first.uuid, second.uuid]))
        XCTAssertTrue(moved.allSatisfy {
            $0.workspaceID == destinationID && $0.cwd == "/new"
        })
        store.flushSaves()

        let relaunched = makeStore(support)
        XCTAssertTrue(relaunched.isInitialLoadComplete)
        XCTAssertEqual(relaunched.artifacts.count, 2)
        XCTAssertTrue(relaunched.artifacts.allSatisfy {
            $0.workspaceID == destinationID && $0.cwd == "/new"
        })
    }

    func testSingleArtifactAssignmentChangesOnlyWorkspaceMetadata() throws {
        let support = try makeSupportDirectory()
        let store = makeStore(support)
        defer {
            store.flushSaves()
            try? FileManager.default.removeItem(at: support)
        }
        let conversationID = UUID()
        let artifact = seed(
            store,
            title: "Portable",
            workspaceID: UUID(),
            conversationID: conversationID,
            cwd: "/before",
            origin: "ambient")
        store.setFavorite(artifact.uuid, true)
        store.updateSource(artifact.uuid, "# Portable\n\nRevised")
        let before = try XCTUnwrap(store.artifacts.first { $0.uuid == artifact.uuid })

        let moved = store.reassignArtifact(artifact.uuid, workspaceID: nil, cwd: "")

        assertContentAndProvenancePreserved(before, moved)
        XCTAssertNil(moved?.workspaceID)
        XCTAssertEqual(moved?.cwd, "")

        let idempotent = store.reassignArtifact(artifact.uuid, workspaceID: nil, cwd: "")
        XCTAssertEqual(idempotent, moved)
        XCTAssertNil(store.reassignArtifact(UUID(), workspaceID: nil, cwd: ""))
    }

    func testConversationBatchUsesProvenanceAndBoundedInteractiveUUIDFallback() throws {
        let support = try makeSupportDirectory()
        let store = makeStore(support)
        defer {
            store.flushSaves()
            try? FileManager.default.removeItem(at: support)
        }
        let conversationID = UUID()
        let otherConversationID = UUID()
        let oldWorkspaceID = UUID()
        let destinationID = UUID()

        let first = seed(
            store,
            title: "Same title",
            workspaceID: oldWorkspaceID,
            conversationID: conversationID,
            cwd: "/old")
        let durableUUIDMismatch = seed(
            store,
            title: "Durable identity differs from nested snapshot",
            workspaceID: oldWorkspaceID,
            conversationID: conversationID,
            cwd: "/old")
        let sameTitleOtherConversation = seed(
            store,
            title: "Same title",
            workspaceID: oldWorkspaceID,
            conversationID: otherConversationID,
            cwd: "/old")
        let legacyInteractive = seed(
            store,
            title: "Legacy nested artifact",
            workspaceID: oldWorkspaceID,
            conversationID: nil,
            cwd: "/old")
        let unlistedLegacyInteractive = seed(
            store,
            title: "Unlisted legacy artifact",
            workspaceID: oldWorkspaceID,
            conversationID: nil,
            cwd: "/old")
        let ambient = seed(
            store,
            title: "Ambient",
            workspaceID: oldWorkspaceID,
            conversationID: nil,
            cwd: "/old",
            origin: "ambient")
        let user = seed(
            store,
            title: "User-created",
            workspaceID: oldWorkspaceID,
            conversationID: nil,
            cwd: "/old",
            origin: "user")

        let before = Dictionary(
            uniqueKeysWithValues: store.artifacts.map { ($0.uuid, $0) })
        let moved = store.reassignArtifacts(
            forConversation: conversationID,
            includingLegacyArtifactIDs: [
                legacyInteractive.uuid,
                sameTitleOtherConversation.uuid,
                ambient.uuid,
                user.uuid
            ],
            conversationTitle: "Canonical source",
            workspaceID: destinationID,
            cwd: "/destination")

        XCTAssertEqual(
            Set(moved.map(\.uuid)),
            Set([first.uuid, durableUUIDMismatch.uuid, legacyInteractive.uuid]))
        for artifact in moved {
            if artifact.uuid == legacyInteractive.uuid {
                var expected = before[artifact.uuid]!
                expected.workspaceID = destinationID
                expected.cwd = "/destination"
                expected.conversationID = conversationID
                expected.conversationTitle = "Canonical source"
                XCTAssertEqual(artifact, expected)
            } else {
                assertContentAndProvenancePreserved(before[artifact.uuid]!, artifact)
            }
            XCTAssertEqual(artifact.workspaceID, destinationID)
            XCTAssertEqual(artifact.cwd, "/destination")
        }
        XCTAssertEqual(
            moved.first { $0.uuid == legacyInteractive.uuid }?.conversationID,
            conversationID,
            "exact nested UUID evidence should durably heal missing provenance")
        XCTAssertEqual(
            moved.first { $0.uuid == legacyInteractive.uuid }?.conversationTitle,
            "Canonical source")

        for untouched in [
            sameTitleOtherConversation,
            unlistedLegacyInteractive,
            ambient,
            user
        ] {
            XCTAssertEqual(
                store.artifacts.first { $0.uuid == untouched.uuid },
                before[untouched.uuid],
                "unrelated or unprovenanced artifacts must not be inferred as followers")
        }

        store.flushSaves()
        let relaunched = makeStore(support)
        let healed = relaunched.artifacts.first { $0.uuid == legacyInteractive.uuid }
        XCTAssertEqual(healed?.conversationID, conversationID)
        XCTAssertEqual(healed?.conversationTitle, "Canonical source")
    }

    func testWorkspaceFolderBatchUsesIdentityThenBoundedLegacyEvidence() throws {
        let support = try makeSupportDirectory()
        let store = makeStore(support)
        defer {
            store.flushSaves()
            try? FileManager.default.removeItem(at: support)
        }
        let workspaceID = UUID()
        let otherWorkspaceID = UUID()
        let affectedConversationID = UUID()
        let unrelatedConversationID = UUID()

        let workspaceOwned = seed(
            store,
            title: "Workspace-owned ambient artifact",
            workspaceID: workspaceID,
            conversationID: nil,
            cwd: "/old",
            origin: "ambient")
        let missingWorkspaceIdentity = seed(
            store,
            title: "Legacy conversation artifact",
            workspaceID: nil,
            conversationID: affectedConversationID,
            cwd: "/old")
        let staleConflictingIdentity = seed(
            store,
            title: "Stale ownership",
            workspaceID: otherWorkspaceID,
            conversationID: affectedConversationID,
            cwd: "/old")
        let independentlyPlaced = seed(
            store,
            title: "Independently placed",
            workspaceID: otherWorkspaceID,
            conversationID: affectedConversationID,
            cwd: "/somewhere-else")
        let explicitLegacyUUID = seed(
            store,
            title: "Nested legacy identity",
            workspaceID: nil,
            conversationID: nil,
            cwd: "/old")
        let unprovenancedOldCwd = seed(
            store,
            title: "Same old cwd is not ownership",
            workspaceID: nil,
            conversationID: nil,
            cwd: "/old",
            origin: "ambient")
        let otherConversation = seed(
            store,
            title: "Other conversation",
            workspaceID: otherWorkspaceID,
            conversationID: unrelatedConversationID,
            cwd: "/old")

        let before = Dictionary(
            uniqueKeysWithValues: store.artifacts.map { ($0.uuid, $0) })
        let moved = store.reassignArtifacts(
            inWorkspace: workspaceID,
            includingConversationIDs: [affectedConversationID],
            includingLegacyArtifactIDs: [explicitLegacyUUID.uuid, unprovenancedOldCwd.uuid],
            previousCwd: "/old",
            cwd: "/new")

        XCTAssertEqual(
            Set(moved.map(\.uuid)),
            Set([
                workspaceOwned.uuid,
                missingWorkspaceIdentity.uuid,
                staleConflictingIdentity.uuid,
                explicitLegacyUUID.uuid
            ]))
        for artifact in moved {
            assertContentAndProvenancePreserved(before[artifact.uuid]!, artifact)
            XCTAssertEqual(artifact.workspaceID, workspaceID)
            XCTAssertEqual(artifact.cwd, "/new")
        }
        XCTAssertNil(
            moved.first { $0.uuid == explicitLegacyUUID.uuid }?.conversationID,
            "workspace-wide rebasing must not invent conversation provenance")
        for untouched in [independentlyPlaced, unprovenancedOldCwd, otherConversation] {
            XCTAssertEqual(store.artifacts.first { $0.uuid == untouched.uuid }, before[untouched.uuid])
        }
    }
}
