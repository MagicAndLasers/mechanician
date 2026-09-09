import AppKit
import SwiftUI
import XCTest
@testable import Mechanician

@MainActor
final class ConversationSwitchingRegressionTests: XCTestCase {
    func testDoubleClickReceiptRestoresOnlyTheSelectionItsFirstClickDisplaced() {
        let original = UUID()
        let target = UUID()

        XCTAssertEqual(
            ConversationTabOpenIntent.resolve(
                conversationID: target,
                pendingTargetID: target,
                replacedConversationID: original),
            ConversationTabOpenIntent(
                conversationID: target,
                replacedSelection: true,
                replacedConversationID: original))
        XCTAssertEqual(
            ConversationTabOpenIntent.resolve(
                conversationID: target,
                pendingTargetID: UUID(),
                replacedConversationID: original),
            ConversationTabOpenIntent(
                conversationID: target,
                replacedSelection: false,
                replacedConversationID: nil))
    }

    func testReplacementProjectionCacheCannotLeavePriorConversationRowsOnScreen() {
        _ = NSApplication.shared
        let coordinator = AppKitTranscriptHost.Coordinator()
        let table = makeTable(coordinator: coordinator)
        defer { coordinator.removeAll() }

        let firstCache = AppKitTranscriptProjectionCache<String>()
        let first = firstCache.project(
            key: "conversation-a",
            generation: 0,
            append: nil,
            conversationID: UUID(),
            tailEntry: nil,
            canonical: {
                [AppKitTranscriptChunk(id: AnyHashable("conversation-a-row"), revision: 1)]
            },
            tailChunk: { _, _ in nil })
        coordinator.sync(
            chunks: first.chunks,
            chunksGeneration: first.chunksGeneration,
            projectionCacheID: first.cacheID,
            projectionRevision: first.projectionRevision,
            content: { _ in AnyView(EmptyView()) })

        XCTAssertEqual(first.projectionRevision, 1)
        XCTAssertEqual(coordinator.numberOfRows(in: table), 1)
        XCTAssertEqual(coordinator.canonicalSyncCountForTesting, 1)

        // A ContentView replacement owns a fresh cache, so its first canonical projection can
        // legitimately reuse the numeric revision that the coordinator last saw. The revision is
        // cache-local, not a process-wide transcript identity; the new canonical rows must still
        // replace the old conversation instead of leaving its transcript visible.
        let replacementCache = AppKitTranscriptProjectionCache<String>()
        let replacement = replacementCache.project(
            key: "conversation-b",
            generation: 0,
            append: nil,
            conversationID: UUID(),
            tailEntry: nil,
            canonical: {
                [
                    AppKitTranscriptChunk(
                        id: AnyHashable("conversation-b-row-1"), revision: 1),
                    AppKitTranscriptChunk(
                        id: AnyHashable("conversation-b-row-2"), revision: 1),
                ]
            },
            tailChunk: { _, _ in nil })

        XCTAssertEqual(replacement.projectionRevision, first.projectionRevision)
        coordinator.sync(
            chunks: replacement.chunks,
            chunksGeneration: replacement.chunksGeneration,
            projectionCacheID: replacement.cacheID,
            projectionRevision: replacement.projectionRevision,
            content: { _ in AnyView(EmptyView()) })

        XCTAssertEqual(
            coordinator.canonicalSyncCountForTesting,
            2,
            "A repeated cache-local revision must not suppress a replacement canonical transcript.")
        XCTAssertEqual(
            coordinator.numberOfRows(in: table),
            2,
            "The table must show the replacement conversation, not stale rows from its predecessor.")
    }

    func testLatestSelectionCancelsSupersededTranscriptHydration() async throws {
        let base = try makeBase()
        let priorLastConversationID = UserDefaults.standard.string(forKey: "lastConversationID")
        defer {
            if let priorLastConversationID {
                UserDefaults.standard.set(priorLastConversationID, forKey: "lastConversationID")
            } else {
                UserDefaults.standard.removeObject(forKey: "lastConversationID")
            }
            try? FileManager.default.removeItem(at: base)
        }

        let first = conversation(title: "First", transcript: "first transcript")
        let superseded = conversation(
            title: "Superseded",
            transcript: String(repeating: "superseded transcript ", count: 20_000))
        let latest = conversation(title: "Latest", transcript: "latest transcript")
        try seed([first, superseded, latest], at: base)

        let store = ConversationStore(
            appSupportBaseOverride: base,
            watchesDirectory: false,
            residencyMode: .boundedAfterRecovery)
        await awaitBoundedReady(store)

        let bridge = AgentBridge(
            settingsBaseOverride: base.appendingPathComponent("settings", isDirectory: true),
            environmentOverride: [:],
            conversationStoreOverride: store)
        AgentBridge.live.add(bridge)
        defer {
            bridge.currentID = nil
            bridge.shutdown()
        }

        let selectedFirst = await select(first.id, in: bridge)
        XCTAssertTrue(selectedFirst)
        XCTAssertEqual(bridge.entries.map(\.text), ["first transcript"])

        store.trimResidencyIfNeeded(evictAllEligible: true)
        XCTAssertNil(store.residentConversation(superseded.id))
        XCTAssertNil(store.residentConversation(latest.id))

        let supersededFinished = expectation(description: "superseded hydration finished")
        let latestFinished = expectation(description: "latest hydration finished")
        var completions: [(id: UUID, selected: Bool)] = []

        bridge.select(superseded.id) { selected in
            completions.append((superseded.id, selected))
            supersededFinished.fulfill()
        }
        XCTAssertEqual(bridge.pendingSelectionID, superseded.id)
        XCTAssertEqual(bridge.conversationTranscriptPreview?.conversationID, superseded.id)
        XCTAssertEqual(bridge.conversationTranscriptPreview?.entries, [])
        XCTAssertEqual(bridge.currentID, first.id)
        XCTAssertEqual(
            bridge.entries.map(\.text),
            ["first transcript"],
            "A quick display page must never replace the authoritative foreground transcript.")

        // A newer click withdraws the first waiter before starting its own request. The completion
        // still resolves false, but the obsolete record may neither install nor consume the serial
        // hydration lane ahead of the latest intent.
        bridge.select(latest.id) { selected in
            completions.append((latest.id, selected))
            latestFinished.fulfill()
        }
        XCTAssertEqual(bridge.pendingSelectionID, latest.id)
        XCTAssertEqual(bridge.conversationTranscriptPreview?.conversationID, latest.id)
        XCTAssertEqual(bridge.currentID, first.id)

        await fulfillment(of: [supersededFinished, latestFinished], timeout: 5)

        XCTAssertEqual(completions.map(\.id), [superseded.id, latest.id])
        XCTAssertEqual(completions.map(\.selected), [false, true])
        XCTAssertEqual(bridge.currentID, latest.id)
        XCTAssertNil(bridge.conversationTranscriptPreview)
        XCTAssertEqual(bridge.entries.map(\.text), ["latest transcript"])
        XCTAssertNil(
            store.hydrationDecodeCounts[superseded.id],
            "A superseded navigation must not publish its expensive decoded transcript.")
        XCTAssertEqual(
            store.synchronousHydrationCount,
            0,
            "Conversation switching must never decode a transcript on the main actor.")
    }

    private func makeTable(coordinator: AppKitTranscriptHost.Coordinator) -> NSTableView {
        let table = NSTableView(frame: NSRect(x: 0, y: 0, width: 600, height: 300))
        table.headerView = nil
        table.intercellSpacing = .zero
        table.rowHeight = 44
        table.usesAutomaticRowHeights = false
        let column = NSTableColumn(
            identifier: NSUserInterfaceItemIdentifier("conversation-switch-regression"))
        column.width = 600
        table.addTableColumn(column)
        table.dataSource = coordinator
        table.delegate = coordinator
        coordinator.table = table
        return table
    }

    private func makeBase() throws -> URL {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(
            "Mechanician-conversation-switch-\(UUID().uuidString)",
            isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    private func conversation(title: String, transcript: String) -> Conversation {
        Conversation(
            title: title,
            cwd: "",
            sdkSessionId: nil,
            messages: [TranscriptEntry(kind: .user, text: transcript)],
            updatedAt: Date())
    }

    private func seed(_ conversations: [Conversation], at base: URL) throws {
        let directory = base.appendingPathComponent("conversations", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for conversation in conversations {
            try ConversationStore.makeEncoder().encode(conversation).write(
                to: directory.appendingPathComponent("\(conversation.id.uuidString).json"))
        }
    }

    private func awaitBoundedReady(_ store: ConversationStore) async {
        await withCheckedContinuation { continuation in
            store.whenReady { continuation.resume() }
        }
        for _ in 0..<10_000 {
            if store.activeResidencyMode == .boundedAfterRecovery { return }
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTFail("bounded conversation residency did not activate")
    }

    private func select(_ id: UUID, in bridge: AgentBridge) async -> Bool {
        await withCheckedContinuation { continuation in
            bridge.select(id) { continuation.resume(returning: $0) }
        }
    }
}
