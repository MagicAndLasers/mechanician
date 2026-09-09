import XCTest
@testable import Mechanician

@MainActor
final class ConversationSummaryParityTests: XCTestCase {
    private func makeBase() throws -> URL {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("Mechanician-summary-parity-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    private func conversation(
        id: UUID = UUID(),
        title: String = "Conversation",
        cwd: String = "",
        workspaceID: UUID? = nil,
        messages: [TranscriptEntry] = [TranscriptEntry(kind: .user, text: "hello")],
        updatedAt: Date = Date(timeIntervalSinceReferenceDate: 1_000)
    ) -> Conversation {
        Conversation(
            id: id,
            title: title,
            cwd: cwd,
            sdkSessionId: nil,
            messages: messages,
            updatedAt: updatedAt,
            projectID: workspaceID)
    }

    private func assertSummaryParity(
        _ store: ConversationStore,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let expected = store.conversations
            .map(ConversationSummary.init)
            .sorted(by: ConversationSummary.canonicalOrder)
        XCTAssertEqual(store.summaries, expected, file: file, line: line)
        XCTAssertEqual(
            store.summaries.map(\.id),
            store.conversations.sorted(by: ConversationStore.order).map(\.id),
            "The lightweight inventory must use the exact authoritative list order.",
            file: file,
            line: line)
    }

    private func awaitReady(_ store: ConversationStore) async {
        await withCheckedContinuation { continuation in
            store.whenReady { continuation.resume() }
        }
    }

    func testDerivationCarriesCompleteInertSidebarState() throws {
        let workspaceID = try XCTUnwrap(
            UUID(uuidString: "CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC"))
        let messages = [
            TranscriptEntry(kind: .system, text: "system detail"),
            TranscriptEntry(kind: .assistant, text: "Earlier answer"),
            TranscriptEntry(kind: .tool, text: "tool input"),
            TranscriptEntry(kind: .user, text: "  Latest request\nwith context  "),
            TranscriptEntry(kind: .compaction, text: "history reduced"),
        ]
        var source = conversation(
            title: "",
            cwd: "/private/tmp/Legacy Workspace",
            workspaceID: workspaceID,
            messages: messages)
        source.favorite = true
        source.sortIndex = 4
        source.unread = true
        source.errored = true
        source.awaitingQuestion = true
        source.subagents["running-child"] = SubagentRun(
            key: "running-child",
            subagentType: "Explore",
            task: "Inspect the summary plane")
        source.providerAccessRequest = ProviderAccessRequest(
            maker: .openAI,
            reason: "Resume the task",
            resumePrompts: ["continue"])
        source.armedTrigger = ArmedTrigger(
            note: "waiting for the signed build",
            check: nil,
            deadline: nil,
            armedAt: Date(timeIntervalSinceReferenceDate: 900),
            expiresAt: Date(timeIntervalSinceReferenceDate: 1_800))

        let summary = ConversationSummary(source)

        XCTAssertEqual(summary.id, source.id)
        XCTAssertEqual(summary.title, "")
        XCTAssertEqual(summary.displayTitle, "New conversation")
        XCTAssertEqual(summary.workspaceCWD, "/private/tmp/Legacy Workspace")
        XCTAssertEqual(summary.workspaceID, workspaceID)
        XCTAssertEqual(summary.updatedAt, source.updatedAt)
        XCTAssertEqual(summary.messageCount, 2, "Only user and assistant rows count.")
        XCTAssertEqual(summary.snippet, "You: Latest request with context")
        XCTAssertTrue(summary.hasUserMessage)
        XCTAssertTrue(summary.favorite)
        XCTAssertEqual(summary.sortIndex, 4)
        XCTAssertTrue(summary.unread)
        XCTAssertTrue(summary.errored)
        XCTAssertTrue(summary.awaitingQuestion)
        XCTAssertTrue(summary.hasRunningDelegate)
        XCTAssertEqual(summary.providerAccessName, "OpenAI")
        XCTAssertEqual(summary.armedWaitSummary, "for the signed build")

        let long = conversation(
            messages: [TranscriptEntry(kind: .assistant, text: String(repeating: "x", count: 500))])
        let bounded = ConversationSummary(long).snippet
        XCTAssertEqual(bounded.count, ConversationSummary.snippetCharacterLimit)
        XCTAssertTrue(bounded.hasSuffix("…"))
    }

    func testCanonicalOrderingUsesDeterministicUUIDTiebreak() throws {
        let lowerID = try XCTUnwrap(
            UUID(uuidString: "00000000-0000-0000-0000-000000000001"))
        let higherID = try XCTUnwrap(
            UUID(uuidString: "00000000-0000-0000-0000-000000000002"))
        let timestamp = Date(timeIntervalSinceReferenceDate: 10_000)
        let lower = conversation(id: lowerID, title: "Lower", updatedAt: timestamp)
        let higher = conversation(id: higherID, title: "Higher", updatedAt: timestamp)

        let fullOrder = [lower, higher].sorted(by: ConversationStore.order).map(\.id)
        let summaryOrder = [ConversationSummary(lower), ConversationSummary(higher)]
            .sorted(by: ConversationSummary.canonicalOrder)
            .map(\.id)

        XCTAssertEqual(fullOrder, [higherID, lowerID])
        XCTAssertEqual(summaryOrder, fullOrder)
    }

    func testStoreMaintainsSummaryParityAcrossEveryMutationSeam() throws {
        let base = try makeBase()
        defer { try? FileManager.default.removeItem(at: base) }
        let store = ConversationStore(appSupportBaseOverride: base, watchesDirectory: false)

        var first = conversation(
            title: "First",
            messages: [TranscriptEntry(kind: .user, text: "initial request")],
            updatedAt: Date(timeIntervalSinceReferenceDate: 1_000))
        let second = conversation(
            title: "Second",
            messages: [TranscriptEntry(kind: .assistant, text: "standalone result")],
            updatedAt: Date(timeIntervalSinceReferenceDate: 2_000))

        store.upsert(first)
        assertSummaryParity(store)
        store.upsert(second)
        assertSummaryParity(store)

        first.title = "First replacement"
        first.favorite = true
        first.unread = true
        store.upsert(first)
        assertSummaryParity(store)
        XCTAssertEqual(store.summaries.first?.id, first.id)

        store.update(second.id) {
            $0.title = "Second updated"
            $0.errored = true
            $0.providerAccessRequest = ProviderAccessRequest(
                maker: .anthropic,
                reason: "Resume",
                resumePrompts: ["continue"])
        }
        assertSummaryParity(store)
        XCTAssertEqual(
            store.summaries.first(where: { $0.id == second.id })?.providerAccessName,
            "Anthropic")

        store.updateLive(second.id) {
            $0.messages.append(TranscriptEntry(kind: .user, text: "live follow-up"))
            $0.awaitingQuestion = true
            $0.subagents["live-child"] = SubagentRun(
                key: "live-child",
                subagentType: "Explore",
                task: "Still running")
        }
        XCTAssertEqual(
            store.summaries.first(where: { $0.id == second.id })?.snippet,
            "standalone result",
            "the hot streaming path must coalesce summary derivation, not rescan per delta")
        store.flushLiveSummaryRefreshes()
        assertSummaryParity(store)
        let live = try XCTUnwrap(store.summaries.first(where: { $0.id == second.id }))
        XCTAssertEqual(live.messageCount, 2)
        XCTAssertEqual(live.snippet, "You: live follow-up")
        XCTAssertTrue(live.awaitingQuestion)
        XCTAssertTrue(live.hasRunningDelegate)

        store.remove(first.id, permanently: true)
        assertSummaryParity(store)
        XCTAssertFalse(store.summaries.contains(where: { $0.id == first.id }))

        store.flushSaves()
        store.projections.drain()
    }

    func testAsyncLoadAndCreateDuringLoadPublishOneOrderedSummaryInventory() async throws {
        let base = try makeBase()
        defer { try? FileManager.default.removeItem(at: base) }
        let directory = base.appendingPathComponent("conversations", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        var favoriteOnDisk = conversation(
            title: "Favorite from disk",
            messages: [TranscriptEntry(kind: .user, text: "persisted favorite")],
            updatedAt: Date(timeIntervalSinceReferenceDate: 100))
        favoriteOnDisk.favorite = true
        let recentOnDisk = conversation(
            title: "Recent from disk",
            messages: [TranscriptEntry(kind: .assistant, text: "persisted result")],
            updatedAt: Date(timeIntervalSinceReferenceDate: 300))
        for seeded in [favoriteOnDisk, recentOnDisk] {
            try ConversationStore.makeEncoder().encode(seeded).write(
                to: directory.appendingPathComponent("\(seeded.id.uuidString).json"))
        }

        let store = ConversationStore(
            appSupportBaseOverride: base,
            watchesDirectory: false,
            loadsAsynchronously: true)
        XCTAssertFalse(store.isReady)

        // The background scan cannot publish on the main actor until this test yields, so this is
        // deterministically the real ⌘N-during-launch merge case.
        let createdDuringLoad = conversation(
            title: "Created during load",
            messages: [TranscriptEntry(kind: .user, text: "typed immediately")],
            updatedAt: Date(timeIntervalSinceReferenceDate: 200))
        store.upsert(createdDuringLoad)
        XCTAssertEqual(store.summaries.map(\.id), [createdDuringLoad.id])

        await awaitReady(store)

        XCTAssertTrue(store.isReady)
        XCTAssertEqual(Set(store.conversations.map(\.id)), [
            favoriteOnDisk.id, recentOnDisk.id, createdDuringLoad.id,
        ])
        assertSummaryParity(store)
        XCTAssertEqual(store.summaries.map(\.id), [
            favoriteOnDisk.id, recentOnDisk.id, createdDuringLoad.id,
        ])

        store.flushSaves()
        store.projections.drain()
    }
}
