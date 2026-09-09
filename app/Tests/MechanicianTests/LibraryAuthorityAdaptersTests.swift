import CryptoKit
import Foundation
import XCTest
@testable import Mechanician

private final class ReconstructionCancellationProbe: @unchecked Sendable {
    private let lock = NSLock()
    private let cancelOnCheck: Int
    private var checkCount = 0

    init(cancelOnCheck: Int) {
        self.cancelOnCheck = cancelOnCheck
    }

    func isCancelled() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        checkCount += 1
        return checkCount >= cancelOnCheck
    }

    func observedCheckCount() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return checkCount
    }
}

final class LibraryAuthorityAdaptersTests: XCTestCase {
    func testConversationEventDateParityUsesExactLegacyMillisecondEncoding() {
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        let beforeBoundary = base.addingTimeInterval(0.00049)
        let afterBoundary = base.addingTimeInterval(0.00101)
        XCTAssertLessThan(
            abs(beforeBoundary.timeIntervalSinceReferenceDate
                - afterBoundary.timeIntervalSinceReferenceDate),
            0.001)
        XCTAssertNotEqual(
            SendableISO8601Formatter.fractional.string(from: beforeBoundary),
            SendableISO8601Formatter.fractional.string(from: afterBoundary))
        XCTAssertFalse(LibraryConversationAdapter.datesMatchLegacyEncoding(
            beforeBoundary, afterBoundary))

        let samePublishedMillisecond = base.addingTimeInterval(0.00040)
        XCTAssertTrue(LibraryConversationAdapter.datesMatchLegacyEncoding(
            beforeBoundary, samePublishedMillisecond))
    }

    func testConversationRoundTripPreservesEveryCurrentDurableDomain() throws {
        let conversationID = UUID(uuidString: "10000000-0000-0000-0000-000000000001")!
        let workspaceID = UUID(uuidString: "20000000-0000-0000-0000-000000000002")!
        let sessionRevision = UUID(uuidString: "30000000-0000-0000-0000-000000000003")!
        let date = Date(timeIntervalSince1970: 1_800_000_000.125)
        var entry = TranscriptEntry(kind: .user, text: "Retain this prompt")
        entry.id = UUID(uuidString: "40000000-0000-0000-0000-000000000004")!
        entry.observedAt = date
        entry.captureOrdinal = 1
        var assistant = TranscriptEntry(kind: .assistant, text: "Retain this answer")
        assistant.id = UUID(uuidString: "41000000-0000-0000-0000-000000000004")!
        assistant.observedAt = date.addingTimeInterval(0.5)
        assistant.captureOrdinal = 2
        var activity = AgentActivityRecord(kind: .state)
        activity.id = UUID(uuidString: "50000000-0000-0000-0000-000000000005")!
        activity.at = date.addingTimeInterval(1)
        activity.captureOrdinal = 3
        activity.phase = .completed
        let artifact = Artifact(
            title: "Result",
            type: "markdown",
            source: "# Durable",
            workspaceID: workspaceID,
            conversationID: conversationID,
            conversationTitle: "Authority sprint",
            cwd: "/tmp/workspace",
            uuid: UUID(uuidString: "60000000-0000-0000-0000-000000000006")!,
            createdAt: date,
            updatedAt: date)
        let workflow = WorkflowRun(
            runKey: "workflow-1", description: "A durable workflow", startedAt: date)
        let subagent = SubagentRun(
            key: "subagent-1", subagentType: "Explore", task: "Inventory writers",
            startedAt: date)
        let accessRequest = ProviderAccessRequest(
            id: UUID(uuidString: "70000000-0000-0000-0000-000000000007")!,
            maker: .anthropic,
            reason: "Resume later",
            resumePrompts: ["queued after access"],
            requestedAt: date,
            selectedAccess: .anthropicAPI)
        let trigger = ArmedTrigger(
            note: "waiting for the build",
            check: "test -f ready",
            deadline: date.addingTimeInterval(60),
            everySeconds: 10,
            armedAt: date,
            expiresAt: date.addingTimeInterval(600))
        var original = Conversation(
            id: conversationID,
            title: "Authority sprint",
            titleSource: .manual,
            cwd: "/tmp/workspace",
            sdkSessionId: "provider-session-private",
            sdkSessionRouteIdentity: "route-fingerprint",
            sdkSessionExtensionRevision: sessionRevision,
            sdkSessionWorkspaceInstructionsRevision: "instructions-revision",
            modelSelection: ModelSelection(access: .anthropicAPI, modelID: "model-a"),
            messages: [entry, assistant],
            updatedAt: date,
            artifacts: [artifact],
            workflowRuns: ["workflow-1": workflow],
            subagents: ["subagent-1": subagent],
            agentActivity: [activity],
            captureOrdinalHighWatermark: 9,
            providerHistoryReplayCutoffOrdinal: 8,
            queuedPrompts: ["queued one", "queued two"],
            draft: "unsent draft",
            favorite: true,
            sortIndex: 4,
            armedTrigger: trigger,
            unread: true,
            errored: true,
            projectID: workspaceID,
            contextTokens: 123,
            contextWindow: 456,
            contextModel: "model-a",
            providerAccessRequest: accessRequest,
            claudePreferences: ClaudeSessionPreferences())
        original.pendingTurnPrompt = "accepted but not acknowledged"
        original.claudeEffectiveModel = "fallback-model"
        let suggestedPrompt = ConversationSuggestedPrompt(
            text: "Continue with the authority-backed implementation.",
            source: .provider,
            rootPromptEntryID: entry.id,
            assistantEntryID: assistant.id)
        original.suggestedPrompt = suggestedPrompt

        let local = try LibraryConversationAdapter.captureLocalState(from: original)
        let encoder = ConversationStore.makeEncoder()
        let artifactPayload = try ArtifactStore.persistedEncoder().encode(artifact)
        let artifactContent = Data(artifact.source.utf8)
        let metadata = LibraryConversationMetadataPayload(
            modelSelection: original.modelSelection,
            forkProvenance: original.forkProvenance,
            captureOrdinalHighWatermark: original.captureOrdinalHighWatermark,
            providerHistoryReplayCutoffOrdinal:
                original.providerHistoryReplayCutoffOrdinal,
            contextTokens: original.contextTokens,
            contextWindow: original.contextWindow,
            contextModel: original.contextModel)
        let events = [
            ShadowLibraryEventSnapshot(
                id: entry.id, captureSequence: 0, kind: "transcript.user",
                actorID: "user", observedAt: entry.observedAt,
                payload: try encoder.encode(entry)),
            ShadowLibraryEventSnapshot(
                id: assistant.id, captureSequence: 1, kind: "transcript.assistant",
                actorID: "root", observedAt: assistant.observedAt,
                payload: try encoder.encode(assistant)),
            ShadowLibraryEventSnapshot(
                id: UUID(), captureSequence: 2, kind: "agent_activity.state",
                actorID: activity.agentID, observedAt: activity.at,
                payload: try encoder.encode(activity)),
            ShadowLibraryEventSnapshot(
                id: UUID(), captureSequence: 3,
                kind: "legacy_projection.workflow_summary",
                actorID: "root", targetID: "workflow:workflow-1",
                observedAt: workflow.endedAt ?? workflow.startedAt,
                payload: try encoder.encode(LibraryWorkflowPayload(
                    storageKey: "workflow-1", value: workflow))),
            ShadowLibraryEventSnapshot(
                id: UUID(), captureSequence: 4,
                kind: "legacy_projection.subagent_summary",
                actorID: "subagent:subagent-1",
                observedAt: subagent.endedAt ?? subagent.startedAt,
                payload: try encoder.encode(LibrarySubagentPayload(
                    storageKey: "subagent-1", value: subagent))),
            ShadowLibraryEventSnapshot(
                id: UUID(), captureSequence: 5, kind: "conversation.metadata",
                actorID: "root",
                payload: try encoder.encode(metadata)),
        ]
        let snapshot = ShadowLibraryConversationSnapshot(
            id: original.id,
            title: original.title,
            titleSource: original.titleSource.rawValue,
            cwd: original.cwd,
            workspaceID: workspaceID,
            updatedAt: original.updatedAt,
            favorite: original.favorite,
            sortIndex: original.sortIndex,
            unread: original.unread,
            errored: original.errored,
            revision: 0,
            localStateVersion: local.version,
            localStatePayload: local.payload,
            source: source("conversation.json"),
            events: events,
            nestedArtifacts: [ShadowLibraryNestedArtifactSnapshot(
                artifactID: artifact.uuid,
                canonicalPayload: artifactPayload,
                canonicalPayloadDigest: digest(artifactPayload),
                contentDigest: digest(artifactContent),
                contentByteCount: artifactContent.count)])

        let reconstructed = try LibraryConversationAdapter.reconstruct(from: snapshot)
        let expected = try encoder.encode(original)
        XCTAssertEqual(try encoder.encode(reconstructed), expected)
        XCTAssertEqual(reconstructed.suggestedPrompt, suggestedPrompt)
        XCTAssertEqual(try LibraryConversationAdapter.freshLegacyData(from: snapshot), expected)
    }

    func testConversationLocalStateV1WithoutSuggestedPromptDecodesAsNil() throws {
        let conversation = Conversation(
            title: "Legacy local state",
            cwd: "/tmp/legacy-local-state",
            sdkSessionId: nil,
            messages: [TranscriptEntry(kind: .user, text: "hello")],
            updatedAt: Date())
        let captured = try LibraryConversationAdapter.captureLocalState(from: conversation)
        XCTAssertEqual(captured.version, 1)

        var json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: captured.payload) as? [String: Any])
        json.removeValue(forKey: "suggestedPrompt")
        let legacyPayload = try JSONSerialization.data(withJSONObject: json)
        let decoded = try ConversationStore.makeDecoder().decode(
            LibraryConversationLocalStatePayload.self,
            from: legacyPayload)

        XCTAssertNil(decoded.suggestedPrompt)
        XCTAssertEqual(LibraryConversationLocalStatePayload.currentVersion, 1)
    }

    func testConversationReconstructionSamplesCancellationBetweenTranscriptEntries() throws {
        let conversation = Conversation(
            title: "Cancelable reconstruction",
            cwd: "",
            sdkSessionId: nil,
            messages: (0..<128).map { index in
                TranscriptEntry(kind: index.isMultiple(of: 2) ? .user : .assistant,
                                text: "entry \(index)")
            },
            updatedAt: Date())
        let snapshot = try LibraryConversationAdapter.capture(
            conversation,
            source: source("cancelable-reconstruction.json"))
        // The initial/local-state/prefix checks consume 131 samples. Cancellation at 150 therefore
        // occurs in the ordered transcript reconstruction loop rather than before it begins.
        let probe = ReconstructionCancellationProbe(cancelOnCheck: 150)

        XCTAssertThrowsError(
            try LibraryConversationAdapter.reconstruct(
                from: snapshot,
                isCancelled: { probe.isCancelled() })
        ) { error in
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertGreaterThanOrEqual(probe.observedCheckCount(), 150)
    }

    func testConversationReconstructionFailsClosedForFutureTitleAndLocalStateVersions() throws {
        let base = try minimalConversationSnapshot(titleSource: "future-source")
        XCTAssertThrowsError(try LibraryConversationAdapter.reconstruct(from: base)) { error in
            guard case LibraryAuthorityAdapterError.invalidPayload(let domain, _) = error else {
                return XCTFail("unexpected error: \(error)")
            }
            XCTAssertEqual(domain, "Conversation")
        }

        let current = try minimalConversationSnapshot(
            titleSource: ConversationTitleSource.manual.rawValue,
            localStateVersion: 99)
        XCTAssertThrowsError(try LibraryConversationAdapter.reconstruct(from: current)) { error in
            XCTAssertEqual(
                error as? LibraryAuthorityAdapterError,
                .unsupportedPayloadVersion(domain: "Conversation local state", version: 99))
        }
    }

    func testLegacyNilMembershipSurvivesCWDResolvedRelationalWorkspace() throws {
        let normalizedWorkspaceID = UUID(
            uuidString: "C0000000-0000-0000-0000-00000000000C")!
        let snapshot = try minimalConversationSnapshot(
            titleSource: ConversationTitleSource.manual.rawValue,
            workspaceID: normalizedWorkspaceID)

        let restored = try LibraryConversationAdapter.reconstruct(from: snapshot)
        XCTAssertNil(restored.projectID)
        XCTAssertEqual(snapshot.workspaceID, normalizedWorkspaceID)
    }

    func testConversationCaptureSequenceMustStartAtZeroAndContainNoGaps() throws {
        let firstNonzero = try minimalConversationSnapshot(
            titleSource: ConversationTitleSource.manual.rawValue,
            metadataCaptureSequence: 1)
        XCTAssertThrowsError(try LibraryConversationAdapter.reconstruct(from: firstNonzero)) { error in
            XCTAssertEqual(
                error as? LibraryAuthorityAdapterError,
                .invalidEvent("expected capture sequence 0, found 1"))
        }

        var entry = TranscriptEntry(kind: .user, text: "before the gap")
        entry.id = UUID()
        entry.observedAt = Date(timeIntervalSince1970: 1_800_000_301)
        let metadata = try XCTUnwrap(firstNonzero.events.first)
        let gap = ShadowLibraryConversationSnapshot(
            id: firstNonzero.id,
            title: firstNonzero.title,
            titleSource: firstNonzero.titleSource,
            cwd: firstNonzero.cwd,
            workspaceID: firstNonzero.workspaceID,
            updatedAt: firstNonzero.updatedAt,
            favorite: firstNonzero.favorite,
            sortIndex: firstNonzero.sortIndex,
            unread: firstNonzero.unread,
            errored: firstNonzero.errored,
            revision: firstNonzero.revision,
            localStateVersion: firstNonzero.localStateVersion,
            localStatePayload: firstNonzero.localStatePayload,
            source: firstNonzero.source,
            events: [
                ShadowLibraryEventSnapshot(
                    id: entry.id,
                    captureSequence: 0,
                    kind: "transcript.user",
                    actorID: "user",
                    observedAt: entry.observedAt,
                    payload: try ConversationStore.makeEncoder().encode(entry)),
                ShadowLibraryEventSnapshot(
                    id: metadata.id,
                    captureSequence: 2,
                    kind: metadata.kind,
                    payload: metadata.payload),
            ])
        XCTAssertThrowsError(try LibraryConversationAdapter.reconstruct(from: gap)) { error in
            XCTAssertEqual(
                error as? LibraryAuthorityAdapterError,
                .invalidEvent("expected capture sequence 1, found 2"))
        }
    }

    func testCanonicalLossPreflightFindsTopLevelAndNestedUnknownPaths() throws {
        let canonical = Data(#"{"messages":[{"text":"hello"}],"title":"Known"}"#.utf8)
        let original = Data(
            #"{"futureTop":true,"messages":[{"future/nested":{"x":1},"text":"hello"}],"title":"Known"}"#.utf8)

        let report = try LibraryCanonicalLossPreflight.compare(
            original: original, canonical: canonical)

        XCTAssertFalse(report.isLossless)
        XCTAssertEqual(report.droppedPaths, ["/futureTop", "/messages/0/future~1nested"])
        XCTAssertTrue(report.diagnostics.contains("/messages/0/future~1nested"))
    }

    func testWorkspaceRoundTripPreservesDefaultModelAndHomeSchemaVersion() throws {
        // ProjectStore's current `.iso8601` sidecars persist whole seconds.
        let date = Date(timeIntervalSince1970: 1_800_000_100)
        let project = Project(
            id: UUID(uuidString: "80000000-0000-0000-0000-000000000008")!,
            name: "Mechanician",
            goal: "SQLite authority",
            instructions: "Preserve every fact",
            cwd: "/tmp/mechanician",
            favorite: true,
            sortIndex: 2,
            iconSymbol: "wrench",
            colorHex: "#123456",
            defaultModelSelection: ModelSelection(
                access: .codexSubscription, modelID: "gpt-test"),
            createdAt: date,
            updatedAt: date)
        let projectLocal = try LibraryWorkspaceAdapter.captureLocalState(from: project)
        let projectSnapshot = ShadowLibraryWorkspaceSnapshot.named(
            project,
            source: source("workspace.json"),
            localStateVersion: projectLocal.version,
            localStatePayload: projectLocal.payload)
        guard case .named(let restoredProject) = try LibraryWorkspaceAdapter.reconstruct(
            from: projectSnapshot) else {
            return XCTFail("expected named Workspace")
        }
        XCTAssertEqual(
            try ConversationStore.makeEncoder().encode(restoredProject),
            try ConversationStore.makeEncoder().encode(project))
        let legacyProjectData = try LibraryWorkspaceAdapter.freshLegacyData(from: projectSnapshot)
        let workspaceDecoder = JSONDecoder()
        workspaceDecoder.dateDecodingStrategy = .iso8601
        let legacyProject = try workspaceDecoder.decode(Project.self, from: legacyProjectData)
        XCTAssertEqual(legacyProject.defaultModelSelection, project.defaultModelSelection)
        XCTAssertEqual(legacyProject.id, project.id)
        XCTAssertEqual(legacyProject.updatedAt, project.updatedAt)

        let home = HomeWorkspaceSettings(
            schemaVersion: 7, instructions: "Home instructions", updatedAt: date)
        let homeLocal = try LibraryWorkspaceAdapter.captureLocalState(from: home)
        let homeSnapshot = ShadowLibraryWorkspaceSnapshot.home(
            settings: home,
            source: source("home-workspace.json"),
            localStateVersion: homeLocal.version,
            localStatePayload: homeLocal.payload)
        guard case .home(let restoredHome) = try LibraryWorkspaceAdapter.reconstruct(
            from: homeSnapshot) else {
            return XCTFail("expected Home")
        }
        XCTAssertEqual(restoredHome, home)
        XCTAssertEqual(
            try workspaceDecoder.decode(
                HomeWorkspaceSettings.self,
                from: LibraryWorkspaceAdapter.freshLegacyData(from: homeSnapshot)),
            home)
    }

    func testArtifactDecodeBackValidatesCanonicalColumnsAndRetainsOnlyRawExtensions() throws {
        let workspaceID = UUID(uuidString: "90000000-0000-0000-0000-000000000009")!
        let conversationID = UUID(uuidString: "A0000000-0000-0000-0000-00000000000A")!
        let date = Date(timeIntervalSince1970: 1_800_000_200.5)
        let artifact = Artifact(
            title: "Current title",
            type: "markdown",
            source: "current body",
            favorite: true,
            origin: "ambient",
            workspaceID: workspaceID,
            conversationID: conversationID,
            conversationTitle: "Source conversation",
            cwd: "/tmp/workspace",
            uuid: UUID(uuidString: "B0000000-0000-0000-0000-00000000000B")!,
            createdAt: date,
            updatedAt: date,
            revisions: 3)
        let canonical = try ArtifactStore.persistedEncoder().encode(artifact)
        var raw = try XCTUnwrap(
            JSONSerialization.jsonObject(with: canonical) as? [String: Any])
        raw["title"] = "stale raw title"
        raw["source"] = "stale raw body"
        raw["taskId"] = "ambient-task-1"
        raw["futureExtension"] = ["retained": true]
        let rawData = try JSONSerialization.data(withJSONObject: raw, options: [.sortedKeys])
        let content = Data(artifact.source.utf8)
        let snapshot = ShadowLibraryArtifactSnapshot(
            id: artifact.uuid,
            title: artifact.title,
            type: artifact.type,
            origin: artifact.origin,
            workspaceID: workspaceID,
            provenanceConversationID: conversationID,
            conversationTitleSnapshot: artifact.conversationTitle,
            cwd: artifact.cwd,
            favorite: artifact.favorite,
            createdAt: artifact.createdAt,
            updatedAt: artifact.updatedAt,
            revision: artifact.revisions,
            producerTaskID: "ambient-task-1",
            rawSourcePayload: rawData,
            canonicalPayload: canonical,
            canonicalPayloadDigest: digest(canonical),
            content: content,
            contentDigest: digest(content),
            contentByteCount: content.count,
            payloadMediaType: "text/markdown",
            source: source("artifact.json"))

        XCTAssertEqual(try LibraryArtifactAdapter.reconstruct(from: snapshot), artifact)
        XCTAssertEqual(
            LibraryArtifactAdapter.retainedRawExtensionKeys(in: snapshot),
            ["futureExtension"])
        let legacy = try LibraryArtifactAdapter.freshLegacyData(from: snapshot)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: legacy) as? [String: Any])
        XCTAssertEqual(object["title"] as? String, "Current title")
        XCTAssertEqual(object["source"] as? String, "current body")
        XCTAssertEqual(object["taskId"] as? String, "ambient-task-1")
        XCTAssertNotNil(object["futureExtension"])
    }

    func testTombstonesNeverReconstructAndArtifactContentMustMatchCanonicalPayload() throws {
        let conversation = try minimalConversationSnapshot(
            titleSource: ConversationTitleSource.manual.rawValue,
            tombstoned: true)
        XCTAssertThrowsError(try LibraryConversationAdapter.reconstruct(from: conversation))

        let date = Date(timeIntervalSince1970: 1_800_000_400)
        let project = Project(
            id: UUID(), name: "Deleted", defaultModelSelection: nil,
            createdAt: date, updatedAt: date)
        let workspaceLocal = try LibraryWorkspaceAdapter.captureLocalState(from: project)
        let workspace = ShadowLibraryWorkspaceSnapshot(
            id: project.id,
            kind: .named,
            name: project.name,
            goal: project.goal,
            instructions: project.instructions,
            cwd: project.cwd,
            favorite: project.favorite,
            sortIndex: project.sortIndex,
            iconSymbol: project.iconSymbol,
            colorHex: project.colorHex,
            createdAt: project.createdAt,
            updatedAt: project.updatedAt,
            revision: 1,
            tombstoned: true,
            localStateVersion: workspaceLocal.version,
            localStatePayload: workspaceLocal.payload,
            source: source("deleted-workspace.json"))
        XCTAssertThrowsError(try LibraryWorkspaceAdapter.reconstruct(from: workspace))

        let artifact = Artifact(
            title: "Deleted", type: "markdown", source: "canonical",
            uuid: UUID(), createdAt: date, updatedAt: date)
        let tombstonedArtifact = try artifactSnapshot(for: artifact, tombstoned: true)
        XCTAssertThrowsError(try LibraryArtifactAdapter.reconstruct(from: tombstonedArtifact))

        let mismatchedContent = try artifactSnapshot(
            for: artifact, contentOverride: Data("different".utf8))
        XCTAssertThrowsError(try LibraryArtifactAdapter.reconstruct(from: mismatchedContent)) { error in
            guard case LibraryAuthorityAdapterError.invalidPayload(let domain, _) = error else {
                return XCTFail("unexpected error: \(error)")
            }
            XCTAssertEqual(domain, "Artifact")
        }
    }

    func testDatabaseSnapshotsDecodeBackAcrossEveryCurrentAuthorityDomain() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "library-adapter-db-roundtrip-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let store = try SQLiteLibraryStore(supportRoot: root)
        let date = Date(timeIntervalSince1970: 1_800_000_600)

        let project = Project(
            id: UUID(), name: "Round-trip Workspace", goal: "Prove decode-back",
            instructions: "Retain local defaults", cwd: "/tmp/round-trip",
            favorite: true, sortIndex: 3, iconSymbol: "arrow.triangle.2.circlepath",
            colorHex: "#654321",
            defaultModelSelection: ModelSelection(
                access: .codexSubscription, modelID: "gpt-round-trip"),
            createdAt: date, updatedAt: date)
        let workspaceLocal = try LibraryWorkspaceAdapter.captureLocalState(from: project)
        let workspace = ShadowLibraryWorkspaceSnapshot.named(
            project,
            source: source("workspaces/\(project.id).json"),
            revision: 4,
            localStateVersion: workspaceLocal.version,
            localStatePayload: workspaceLocal.payload)
        try store.upsert(workspace: workspace)

        let conversation = try minimalConversationSnapshot(
            titleSource: ConversationTitleSource.manual.rawValue,
            workspaceID: project.id)
        try store.upsert(conversation: conversation)

        let authoredArtifact = Artifact(
            title: "Round-trip Artifact", type: "markdown", source: "# Stored bytes",
            favorite: true, origin: "assistant", workspaceID: project.id,
            conversationID: conversation.id, conversationTitle: conversation.title,
            cwd: project.cwd, uuid: UUID(), createdAt: date, updatedAt: date,
            revisions: 2)
        let artifact = try artifactSnapshot(for: authoredArtifact)
        try store.upsert(artifact: artifact)

        let storedWorkspace = try XCTUnwrap(store.workspaceSnapshot(id: project.id))
        let storedConversation = try XCTUnwrap(store.conversationSnapshot(id: conversation.id))
        let storedArtifact = try XCTUnwrap(store.artifactSnapshot(id: authoredArtifact.uuid))
        XCTAssertEqual(storedWorkspace, workspace)
        XCTAssertEqual(storedConversation, conversation)
        XCTAssertEqual(storedArtifact, artifact)

        guard case .named(let restoredProject) = try LibraryWorkspaceAdapter.reconstruct(
            from: storedWorkspace) else {
            return XCTFail("expected named Workspace")
        }
        XCTAssertEqual(restoredProject.defaultModelSelection, project.defaultModelSelection)
        XCTAssertEqual(
            try LibraryConversationAdapter.reconstruct(from: storedConversation).id,
            conversation.id)
        XCTAssertEqual(
            try LibraryArtifactAdapter.reconstruct(from: storedArtifact),
            authoredArtifact)
        XCTAssertNoThrow(try LibraryWorkspaceAdapter.freshLegacyData(from: storedWorkspace))
        XCTAssertNoThrow(try LibraryConversationAdapter.freshLegacyData(from: storedConversation))
        XCTAssertNoThrow(try LibraryArtifactAdapter.freshLegacyData(from: storedArtifact))
    }

    private func minimalConversationSnapshot(
        titleSource: String,
        localStateVersion: Int = LibraryConversationLocalStatePayload.currentVersion,
        tombstoned: Bool = false,
        workspaceID: UUID? = nil,
        metadataCaptureSequence: Int64 = 0
    ) throws -> ShadowLibraryConversationSnapshot {
        let conversation = Conversation(
            title: "Minimal", titleSource: .manual, cwd: "", sdkSessionId: nil,
            messages: [], updatedAt: Date(timeIntervalSince1970: 1_800_000_300))
        let local = try LibraryConversationAdapter.captureLocalState(from: conversation)
        let metadata = LibraryConversationMetadataPayload(
            modelSelection: nil,
            forkProvenance: nil,
            captureOrdinalHighWatermark: nil,
            contextTokens: nil,
            contextWindow: nil,
            contextModel: nil)
        return ShadowLibraryConversationSnapshot(
            id: conversation.id,
            title: conversation.title,
            titleSource: titleSource,
            cwd: conversation.cwd,
            workspaceID: workspaceID,
            updatedAt: conversation.updatedAt,
            favorite: false,
            sortIndex: nil,
            unread: false,
            errored: false,
            revision: 0,
            tombstoned: tombstoned,
            localStateVersion: localStateVersion,
            localStatePayload: local.payload,
            source: source("minimal.json"),
            events: [ShadowLibraryEventSnapshot(
                id: UUID(), captureSequence: metadataCaptureSequence,
                kind: "conversation.metadata",
                actorID: "root",
                payload: try ConversationStore.makeEncoder().encode(metadata))])
    }

    private func artifactSnapshot(
        for artifact: Artifact,
        tombstoned: Bool = false,
        contentOverride: Data? = nil
    ) throws -> ShadowLibraryArtifactSnapshot {
        let canonical = try ArtifactStore.persistedEncoder().encode(artifact)
        let canonicalContent = Data(artifact.source.utf8)
        return ShadowLibraryArtifactSnapshot(
            id: artifact.uuid,
            title: artifact.title,
            type: artifact.type,
            origin: artifact.origin,
            workspaceID: artifact.workspaceID,
            provenanceConversationID: artifact.conversationID,
            conversationTitleSnapshot: artifact.conversationTitle,
            cwd: artifact.cwd,
            favorite: artifact.favorite,
            createdAt: artifact.createdAt,
            updatedAt: artifact.updatedAt,
            revision: artifact.revisions,
            tombstoned: tombstoned,
            producerTaskID: nil,
            rawSourcePayload: canonical,
            canonicalPayload: canonical,
            canonicalPayloadDigest: digest(canonical),
            content: contentOverride ?? canonicalContent,
            contentDigest: digest(canonicalContent),
            contentByteCount: canonicalContent.count,
            payloadMediaType: artifact.type == "markdown" ? "text/markdown" : "text/plain",
            source: ShadowLibrarySourceFingerprint(
                identity: "artifact-helper.json", revision: "1", sourceBytes: canonical))
    }

    private func source(_ identity: String) -> ShadowLibrarySourceFingerprint {
        ShadowLibrarySourceFingerprint(
            identity: identity,
            revision: "1",
            digest: String(repeating: "a", count: 64),
            byteCount: 1)
    }

    private func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
