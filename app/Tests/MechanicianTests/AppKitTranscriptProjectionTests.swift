import AppKit
import SwiftUI
import XCTest
@testable import Mechanician

@MainActor
final class AppKitTranscriptProjectionTests: XCTestCase {
    func testExactTailAppendKeepsCanonicalProjectionFixed() throws {
        let conversationID = UUID()
        let entryID = UUID()
        let cache = AppKitTranscriptProjectionCache<String>()
        let base = assistantEntry(id: entryID, text: "Hello")

        var canonicalCalls = 0
        let initial = cache.project(
            key: "stable-presentation",
            generation: 1,
            append: nil,
            conversationID: conversationID,
            tailEntry: base,
            canonical: {
                canonicalCalls += 1
                return [assistantChunk(for: base, generation: 1)]
            },
            tailChunk: assistantChunk(for:append:))

        XCTAssertEqual(initial.chunks.first?.assistant?.text, "Hello")
        XCTAssertNil(initial.tailUpdate)
        XCTAssertEqual(cache.canonicalProjectionCountForTesting, 1)

        let current = assistantEntry(id: entryID, text: "Hello, world")
        let append = tailAppend(
            conversationID: conversationID,
            entryID: entryID,
            baseGeneration: 1,
            generation: 2,
            baseText: "Hello",
            delta: ", world")
        let projected = cache.project(
            key: "stable-presentation",
            generation: 2,
            append: append,
            conversationID: conversationID,
            tailEntry: current,
            canonical: {
                canonicalCalls += 1
                return [assistantChunk(for: current, generation: 2)]
            },
            tailChunk: assistantChunk(for:append:))

        XCTAssertEqual(canonicalCalls, 1)
        XCTAssertEqual(cache.canonicalProjectionCountForTesting, 1)
        XCTAssertEqual(cache.exactTailUpdateCountForTesting, 1)
        XCTAssertEqual(
            projected.chunks.first?.assistant?.text,
            "Hello",
            "an exact append must retain the canonical baseline array")
        XCTAssertEqual(projected.tailUpdate?.chunk.assistant?.text, "Hello, world")
        XCTAssertEqual(projected.tailUpdate?.append, append)
        XCTAssertEqual(projected.chunksGeneration, 1)
    }

    func testMissedAppendGenerationRebuildsFromCanonicalTranscript() {
        let conversationID = UUID()
        let entryID = UUID()
        let cache = AppKitTranscriptProjectionCache<String>()
        let base = assistantEntry(id: entryID, text: "base")
        _ = cache.project(
            key: "stable-presentation",
            generation: 10,
            append: nil,
            conversationID: conversationID,
            tailEntry: base,
            canonical: { [assistantChunk(for: base, generation: 10)] },
            tailChunk: assistantChunk(for:append:))

        // The cache never consumed generation 11, so generation 12's suffix cannot be replayed
        // against its generation-10 baseline.
        let current = assistantEntry(id: entryID, text: "base-first-second")
        let missedAppend = tailAppend(
            conversationID: conversationID,
            entryID: entryID,
            baseGeneration: 11,
            generation: 12,
            baseText: "base-first",
            delta: "-second")
        var canonicalCalls = 0
        let projected = cache.project(
            key: "stable-presentation",
            generation: 12,
            append: missedAppend,
            conversationID: conversationID,
            tailEntry: current,
            canonical: {
                canonicalCalls += 1
                return [assistantChunk(for: current, generation: 12)]
            },
            tailChunk: assistantChunk(for:append:))

        XCTAssertEqual(canonicalCalls, 1)
        XCTAssertEqual(cache.canonicalProjectionCountForTesting, 2)
        XCTAssertEqual(cache.exactTailUpdateCountForTesting, 0)
        XCTAssertNil(projected.tailUpdate)
        XCTAssertEqual(projected.chunks.first?.assistant?.text, "base-first-second")
        XCTAssertEqual(projected.chunksGeneration, 12)
    }

    func testInvalidAppendSnapshotRebuildsCanonically() {
        let conversationID = UUID()
        let entryID = UUID()
        let cache = AppKitTranscriptProjectionCache<String>()
        let base = assistantEntry(id: entryID, text: "base")
        _ = cache.project(
            key: "stable-presentation",
            generation: 1,
            append: nil,
            conversationID: conversationID,
            tailEntry: base,
            canonical: { [assistantChunk(for: base, generation: 1)] },
            tailChunk: assistantChunk(for:append:))

        let current = assistantEntry(id: entryID, text: "base-tail")
        let inconsistent = TranscriptTailAppend(
            conversationID: conversationID,
            entryID: entryID,
            baseGeneration: 1,
            generation: 2,
            baseUTF8Count: "base".utf8.count,
            resultingUTF8Count: "base-tail".utf8.count + 1,
            delta: "-tail")
        let projected = cache.project(
            key: "stable-presentation",
            generation: 2,
            append: inconsistent,
            conversationID: conversationID,
            tailEntry: current,
            canonical: { [assistantChunk(for: current, generation: 2)] },
            tailChunk: assistantChunk(for:append:))

        XCTAssertEqual(cache.canonicalProjectionCountForTesting, 2)
        XCTAssertEqual(cache.exactTailUpdateCountForTesting, 0)
        XCTAssertNil(projected.tailUpdate)
        XCTAssertEqual(projected.chunks.first?.assistant?.text, "base-tail")
    }

    func testLateAppendMetadataAtAnAlreadySeenGenerationRebuildsCanonically() {
        let conversationID = UUID()
        let entryID = UUID()
        let cache = AppKitTranscriptProjectionCache<String>()
        let base = assistantEntry(id: entryID, text: "base")
        _ = cache.project(
            key: "stable-presentation",
            generation: 1,
            append: nil,
            conversationID: conversationID,
            tailEntry: base,
            canonical: { [assistantChunk(for: base, generation: 1)] },
            tailChunk: assistantChunk(for:append:))

        // @Published's willSet can invalidate SwiftUI before flushAssistant reinstalls its exact
        // descriptor. If that first body pass sees generation 2 without metadata, a second pass at
        // the same generation must still consume/reconcile the late descriptor rather than return
        // the prior cached projection unchanged.
        let current = assistantEntry(id: entryID, text: "base-tail")
        let early = cache.project(
            key: "stable-presentation",
            generation: 2,
            append: nil,
            conversationID: conversationID,
            tailEntry: current,
            canonical: { [assistantChunk(for: current, generation: 2)] },
            tailChunk: assistantChunk(for:append:))
        XCTAssertEqual(early.chunks.first?.assistant?.text, "base-tail")

        let late = tailAppend(
            conversationID: conversationID,
            entryID: entryID,
            baseGeneration: 1,
            generation: 2,
            baseText: "base",
            delta: "-tail")
        var canonicalCalls = 0
        let reconciled = cache.project(
            key: "stable-presentation",
            generation: 2,
            append: late,
            conversationID: conversationID,
            tailEntry: current,
            canonical: {
                canonicalCalls += 1
                return [assistantChunk(for: current, generation: 2)]
            },
            tailChunk: assistantChunk(for:append:))

        XCTAssertEqual(canonicalCalls, 1)
        XCTAssertNil(reconciled.tailUpdate)
        XCTAssertEqual(reconciled.chunks.first?.assistant?.text, "base-tail")
    }

    func testNonAppendPresentationKeyChangeRebuildsAtSameGeneration() {
        let conversationID = UUID()
        let entryID = UUID()
        let cache = AppKitTranscriptProjectionCache<String>()
        let tail = assistantEntry(id: entryID, text: "unchanged transcript")
        _ = cache.project(
            key: "scale-1",
            generation: 7,
            append: nil,
            conversationID: conversationID,
            tailEntry: tail,
            canonical: { [assistantChunk(for: tail, generation: 7, scale: 1)] },
            tailChunk: assistantChunk(for:append:))

        var canonicalCalls = 0
        let projected = cache.project(
            key: "scale-1.1",
            generation: 7,
            append: nil,
            conversationID: conversationID,
            tailEntry: tail,
            canonical: {
                canonicalCalls += 1
                return [assistantChunk(for: tail, generation: 7, scale: 1.1)]
            },
            tailChunk: assistantChunk(for:append:))

        XCTAssertEqual(canonicalCalls, 1)
        XCTAssertEqual(cache.canonicalProjectionCountForTesting, 2)
        XCTAssertEqual(projected.chunks.first?.assistant?.chatScale, 1.1)
        XCTAssertNil(projected.tailUpdate)
    }

    /// Workflow progress is not a transcript mutation. Rebuilding all 1,024 rows for one card's
    /// progress update puts linear projection and native diff work on the same main actor that
    /// accepts composer keystrokes. The workflow channel must retain the canonical projection and
    /// reload only the exact card whose complete presentation changed.
    func testWorkflowProgressUpdatesOnlyItsNativeRow() {
        _ = NSApplication.shared
        let cache = AppKitTranscriptProjectionCache<String>()
        let conversationID = UUID()
        let workflowIndex = 512
        var workflowRevision = 1
        var baseline = (0..<1_024).map { index in
            AppKitTranscriptChunk(
                id: AnyHashable("row-\(index)"),
                revision: 1,
                sourceIndex: index)
        }
        baseline[workflowIndex] = workflowChunk(
            id: "workflow-row",
            toolUseID: "workflow-tool",
            sourceIndex: workflowIndex,
            revision: workflowRevision)
        var canonicalCalls = 0

        let initial = cache.project(
            key: "stable-presentation",
            generation: 40,
            append: nil,
            conversationID: conversationID,
            tailEntry: nil,
            canonical: {
                canonicalCalls += 1
                return baseline
            },
            tailChunk: { _, _ in nil },
            workflowChunk: { sourceIndex, toolUseID in
                self.workflowChunk(
                    id: "workflow-row",
                    toolUseID: toolUseID,
                    sourceIndex: sourceIndex,
                    revision: workflowRevision)
            })
        workflowRevision = 2
        let updated = cache.project(
            key: "stable-presentation",
            generation: 40,
            append: nil,
            conversationID: conversationID,
            tailEntry: nil,
            canonical: {
                canonicalCalls += 1
                return baseline
            },
            tailChunk: { _, _ in nil },
            workflowChunk: { sourceIndex, toolUseID in
                self.workflowChunk(
                    id: "workflow-row",
                    toolUseID: toolUseID,
                    sourceIndex: sourceIndex,
                    revision: workflowRevision)
            })

        XCTAssertEqual(canonicalCalls, 1)
        XCTAssertEqual(cache.canonicalProjectionCountForTesting, 1)
        XCTAssertEqual(updated.projectionRevision, initial.projectionRevision)
        XCTAssertEqual(updated.workflowUpdate?.chunks.map(\.sourceIndex), [workflowIndex])
        XCTAssertEqual(updated.workflowUpdate?.chunks.map(\.revision), [2])

        let coordinator = AppKitTranscriptHost.Coordinator()
        let table = makeRecordingTable(coordinator: coordinator)
        coordinator.sync(
            chunks: initial.chunks,
            chunksGeneration: initial.chunksGeneration,
            projectionCacheID: initial.cacheID,
            projectionRevision: initial.projectionRevision,
            workflowUpdate: initial.workflowUpdate,
            content: { index in AnyView(Text("row \(index)")) })
        XCTAssertEqual(coordinator.canonicalSyncCountForTesting, 1)
        table.recordedReloads.removeAll()

        coordinator.sync(
            chunks: updated.chunks,
            chunksGeneration: updated.chunksGeneration,
            projectionCacheID: updated.cacheID,
            projectionRevision: updated.projectionRevision,
            workflowUpdate: updated.workflowUpdate,
            content: { index in AnyView(Text("row \(index)")) })

        XCTAssertEqual(
            coordinator.canonicalSyncCountForTesting,
            1,
            "workflow progress must not send the full native row graph through canonical sync")
        XCTAssertEqual(table.recordedReloads, [IndexSet(integer: workflowIndex)])
        coordinator.removeAll()
    }

    /// SwiftUI may coalesce two provider publications before updating its representable. The
    /// newest workflow update therefore has to be a complete snapshot of every keyed Workflow row,
    /// not merely the rows changed since the immediately preceding (possibly unseen) projection.
    func testLatestWorkflowUpdateRecoversAfterASkippedIntermediateUpdate() {
        _ = NSApplication.shared
        let cache = AppKitTranscriptProjectionCache<String>()
        let conversationID = UUID()
        var revisions = ["workflow-a": 1, "workflow-b": 1]
        let baseline = [
            AppKitTranscriptChunk(id: AnyHashable("before"), revision: 1, sourceIndex: 0),
            workflowChunk(
                id: "workflow-row-a",
                toolUseID: "workflow-a",
                sourceIndex: 1,
                revision: 1),
            AppKitTranscriptChunk(id: AnyHashable("between"), revision: 1, sourceIndex: 2),
            workflowChunk(
                id: "workflow-row-b",
                toolUseID: "workflow-b",
                sourceIndex: 3,
                revision: 1),
        ]
        let refresh: (Int, String) -> AppKitTranscriptChunk? = { sourceIndex, toolUseID in
            let rowID = toolUseID == "workflow-a" ? "workflow-row-a" : "workflow-row-b"
            return self.workflowChunk(
                id: rowID,
                toolUseID: toolUseID,
                sourceIndex: sourceIndex,
                revision: revisions[toolUseID] ?? 1)
        }
        let initial = cache.project(
            key: "stable-presentation",
            generation: 80,
            append: nil,
            conversationID: conversationID,
            tailEntry: nil,
            canonical: { baseline },
            tailChunk: { _, _ in nil },
            workflowChunk: refresh)

        // Deliberately do not synchronize this first update into the native coordinator.
        revisions["workflow-a"] = 2
        _ = cache.project(
            key: "stable-presentation",
            generation: 80,
            append: nil,
            conversationID: conversationID,
            tailEntry: nil,
            canonical: { XCTFail("workflow progress must not rebuild canonically"); return [] },
            tailChunk: { _, _ in nil },
            workflowChunk: refresh)

        revisions["workflow-b"] = 2
        let latest = cache.project(
            key: "stable-presentation",
            generation: 80,
            append: nil,
            conversationID: conversationID,
            tailEntry: nil,
            canonical: { XCTFail("workflow progress must not rebuild canonically"); return [] },
            tailChunk: { _, _ in nil },
            workflowChunk: refresh)

        XCTAssertEqual(latest.projectionRevision, initial.projectionRevision)
        XCTAssertEqual(
            latest.workflowUpdate?.chunks.map(\.workflowToolUseID),
            ["workflow-a", "workflow-b"])
        XCTAssertEqual(latest.workflowUpdate?.chunks.map(\.revision), [2, 2])

        let coordinator = AppKitTranscriptHost.Coordinator()
        let table = makeRecordingTable(coordinator: coordinator)
        coordinator.sync(
            chunks: initial.chunks,
            chunksGeneration: initial.chunksGeneration,
            projectionCacheID: initial.cacheID,
            projectionRevision: initial.projectionRevision,
            workflowUpdate: initial.workflowUpdate,
            content: { index in AnyView(Text("row \(index)")) })
        table.recordedReloads.removeAll()
        coordinator.sync(
            chunks: latest.chunks,
            chunksGeneration: latest.chunksGeneration,
            projectionCacheID: latest.cacheID,
            projectionRevision: latest.projectionRevision,
            workflowUpdate: latest.workflowUpdate,
            content: { index in AnyView(Text("row \(index)")) })

        XCTAssertEqual(coordinator.canonicalSyncCountForTesting, 1)
        XCTAssertEqual(table.recordedReloads, [IndexSet([1, 3])])
        coordinator.removeAll()
    }

    /// A terminal Workflow card is immutable. Its final revision must reach the native row before
    /// the cache drops its live key, then unrelated bridge publications must stop asking the row to
    /// refresh at all.
    func testTerminalWorkflowRevisionIsDeliveredOnceThenLeavesTheRefreshPath() {
        _ = NSApplication.shared
        let cache = AppKitTranscriptProjectionCache<String>()
        let conversationID = UUID()
        let baseline = workflowChunk(
            id: "workflow-row",
            toolUseID: "workflow-tool",
            sourceIndex: 0,
            revision: 1)
        var refreshCalls = 0
        let initial = cache.project(
            key: "stable-presentation",
            generation: 90,
            append: nil,
            conversationID: conversationID,
            tailEntry: nil,
            canonical: { [baseline] },
            tailChunk: { _, _ in nil },
            workflowChunk: { _, _ in
                XCTFail("the canonical projection already contains the initial Workflow row")
                return nil
            })

        let terminal = cache.project(
            key: "stable-presentation",
            generation: 90,
            append: nil,
            conversationID: conversationID,
            tailEntry: nil,
            canonical: { XCTFail("terminal progress is row-scoped"); return [] },
            tailChunk: { _, _ in nil },
            workflowChunk: { sourceIndex, toolUseID in
                refreshCalls += 1
                return self.workflowChunk(
                    id: "workflow-row",
                    toolUseID: toolUseID,
                    sourceIndex: sourceIndex,
                    revision: 2,
                    isTerminal: true)
            })
        XCTAssertEqual(refreshCalls, 1)
        XCTAssertEqual(terminal.workflowUpdate?.chunks.map(\.workflowToolUseID), [nil])

        let afterUnrelatedPublication = cache.project(
            key: "stable-presentation",
            generation: 90,
            append: nil,
            conversationID: conversationID,
            tailEntry: nil,
            canonical: { XCTFail("an unrelated publication is not canonical"); return [] },
            tailChunk: { _, _ in nil },
            workflowChunk: { _, _ in
                refreshCalls += 1
                XCTFail("a terminal Workflow row must leave the live refresh path")
                return nil
            })
        XCTAssertEqual(refreshCalls, 1)
        XCTAssertEqual(
            afterUnrelatedPublication.workflowUpdate?.generation,
            terminal.workflowUpdate?.generation)

        let coordinator = AppKitTranscriptHost.Coordinator()
        let table = makeRecordingTable(coordinator: coordinator)
        coordinator.sync(
            chunks: initial.chunks,
            chunksGeneration: initial.chunksGeneration,
            projectionCacheID: initial.cacheID,
            projectionRevision: initial.projectionRevision,
            workflowUpdate: initial.workflowUpdate,
            content: { index in AnyView(Text("row \(index)")) })
        table.recordedReloads.removeAll()
        coordinator.sync(
            chunks: terminal.chunks,
            chunksGeneration: terminal.chunksGeneration,
            projectionCacheID: terminal.cacheID,
            projectionRevision: terminal.projectionRevision,
            workflowUpdate: terminal.workflowUpdate,
            content: { index in AnyView(Text("row \(index)")) })
        XCTAssertEqual(table.recordedReloads, [IndexSet(integer: 0)])

        table.recordedReloads.removeAll()
        coordinator.sync(
            chunks: afterUnrelatedPublication.chunks,
            chunksGeneration: afterUnrelatedPublication.chunksGeneration,
            projectionCacheID: afterUnrelatedPublication.cacheID,
            projectionRevision: afterUnrelatedPublication.projectionRevision,
            workflowUpdate: afterUnrelatedPublication.workflowUpdate,
            content: { index in AnyView(Text("row \(index)")) })
        XCTAssertTrue(table.recordedReloads.isEmpty)
        XCTAssertEqual(coordinator.canonicalSyncCountForTesting, 1)
        coordinator.removeAll()
    }

    func testCoordinatorExactTailSyncReloadsOnlyTailRow() throws {
        _ = NSApplication.shared
        let coordinator = AppKitTranscriptHost.Coordinator()
        let table = makeRecordingTable(coordinator: coordinator)
        let conversationID = UUID()
        let entryID = UUID()
        let base = assistantEntry(id: entryID, text: "base")
        let baseline = [
            AppKitTranscriptChunk(id: AnyHashable("earlier-row"), revision: 1),
            assistantChunk(for: base, generation: 20),
        ]

        coordinator.sync(
            chunks: baseline,
            chunksGeneration: 20,
            projectionRevision: 1,
            content: { index in AnyView(Text("row \(index)")) })
        XCTAssertEqual(coordinator.canonicalSyncCountForTesting, 1)
        table.recordedReloads.removeAll()

        let current = assistantEntry(id: entryID, text: "base-tail")
        let append = tailAppend(
            conversationID: conversationID,
            entryID: entryID,
            baseGeneration: 20,
            generation: 21,
            baseText: "base",
            delta: "-tail")
        let update = AppKitTranscriptTailUpdate(
            generation: 21,
            chunk: assistantChunk(for: current, append: append),
            append: append)
        coordinator.sync(
            chunks: baseline,
            chunksGeneration: 20,
            projectionRevision: 1,
            tailUpdate: update,
            content: { index in AnyView(Text("row \(index)")) })

        XCTAssertEqual(coordinator.canonicalSyncCountForTesting, 1)
        XCTAssertEqual(coordinator.exactTailSyncCountForTesting, 1)
        XCTAssertEqual(coordinator.canonicalTailRecoveryCountForTesting, 0)
        XCTAssertEqual(table.recordedReloads, [IndexSet(integer: 1)])
        XCTAssertEqual(try nativeAssistantText(in: table, row: 1), "base-tail")
        coordinator.removeAll()
    }

    func testLaggingCoordinatorUsesCanonicalTailSnapshotRecovery() throws {
        _ = NSApplication.shared
        let coordinator = AppKitTranscriptHost.Coordinator()
        let table = makeRecordingTable(coordinator: coordinator)
        let conversationID = UUID()
        let entryID = UUID()
        let base = assistantEntry(id: entryID, text: "base")
        let baseline = [assistantChunk(for: base, generation: 30)]

        // This coordinator starts from generation 30 but receives only the latest generation-32
        // snapshot. The embedded append is based on generation 31 and must not be applied as a
        // suffix; the full chunk text is the canonical recovery payload.
        let current = assistantEntry(id: entryID, text: "base-first-second")
        let latestAppend = tailAppend(
            conversationID: conversationID,
            entryID: entryID,
            baseGeneration: 31,
            generation: 32,
            baseText: "base-first",
            delta: "-second")
        let update = AppKitTranscriptTailUpdate(
            generation: 32,
            chunk: assistantChunk(for: current, append: latestAppend),
            append: latestAppend)
        coordinator.sync(
            chunks: baseline,
            chunksGeneration: 30,
            projectionRevision: 4,
            tailUpdate: update,
            content: { _ in AnyView(EmptyView()) })

        XCTAssertEqual(coordinator.canonicalSyncCountForTesting, 1)
        XCTAssertEqual(coordinator.exactTailSyncCountForTesting, 0)
        XCTAssertEqual(coordinator.canonicalTailRecoveryCountForTesting, 1)
        XCTAssertEqual(table.recordedReloads, [IndexSet(integer: 0)])
        XCTAssertEqual(
            try nativeAssistantText(in: table, row: 0),
            "base-first-second")
        coordinator.removeAll()
    }

    private func assistantEntry(id: UUID, text: String) -> TranscriptEntry {
        var entry = TranscriptEntry(kind: .assistant, text: text)
        entry.id = id
        return entry
    }

    private func workflowChunk(
        id: String,
        toolUseID: String,
        sourceIndex: Int,
        revision: Int,
        isTerminal: Bool = false
    ) -> AppKitTranscriptChunk {
        AppKitTranscriptChunk(
            id: AnyHashable(id),
            revision: revision,
            sourceIndex: sourceIndex,
            hostedHeightEstimateClass: .workflow,
            workflowToolUseID: isTerminal ? nil : toolUseID)
    }

    private func tailAppend(
        conversationID: UUID,
        entryID: UUID,
        baseGeneration: UInt64,
        generation: UInt64,
        baseText: String,
        delta: String
    ) -> TranscriptTailAppend {
        TranscriptTailAppend(
            conversationID: conversationID,
            entryID: entryID,
            baseGeneration: baseGeneration,
            generation: generation,
            baseUTF8Count: baseText.utf8.count,
            resultingUTF8Count: baseText.utf8.count + delta.utf8.count,
            delta: delta)
    }

    private func assistantChunk(
        for entry: TranscriptEntry,
        generation: UInt64,
        scale: CGFloat = 1
    ) -> AppKitTranscriptChunk {
        AppKitTranscriptChunk(
            id: AnyHashable(entry.id),
            revision: Int(generation),
            sourceIndex: 1,
            assistant: AppKitAssistantContent(
                text: entry.text,
                chatScale: scale,
                isLive: true,
                canRetry: false,
                cwd: "/tmp",
                transcriptGeneration: generation))
    }

    private func assistantChunk(
        for entry: TranscriptEntry,
        append: TranscriptTailAppend
    ) -> AppKitTranscriptChunk {
        AppKitTranscriptChunk(
            id: AnyHashable(entry.id),
            revision: Int(append.generation),
            sourceIndex: 1,
            assistant: AppKitAssistantContent(
                text: entry.text,
                chatScale: 1,
                isLive: true,
                canRetry: false,
                cwd: "/tmp",
                tailAppend: append,
                transcriptGeneration: append.generation))
    }

    private func makeRecordingTable(
        coordinator: AppKitTranscriptHost.Coordinator
    ) -> RecordingTranscriptTable {
        let table = RecordingTranscriptTable(
            frame: NSRect(x: 0, y: 0, width: 600, height: 300))
        table.headerView = nil
        table.intercellSpacing = .zero
        table.rowHeight = 44
        table.usesAutomaticRowHeights = false
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("projection-test"))
        column.width = 600
        table.addTableColumn(column)
        table.dataSource = coordinator
        table.delegate = coordinator
        coordinator.table = table
        return table
    }

    private func nativeAssistantText(
        in table: NSTableView,
        row: Int
    ) throws -> String {
        let cell = try XCTUnwrap(
            table.view(atColumn: 0, row: row, makeIfNecessary: true)
                as? NativeAssistantCell)
        let textView = try XCTUnwrap(
            descendants(of: cell).compactMap { $0 as? NSTextView }.first)
        return textView.string
    }

    private func descendants(of view: NSView) -> [NSView] {
        view.subviews + view.subviews.flatMap(descendants(of:))
    }
}

private final class RecordingTranscriptTable: NSTableView {
    var recordedReloads: [IndexSet] = []

    override func reloadData(
        forRowIndexes rowIndexes: IndexSet,
        columnIndexes: IndexSet
    ) {
        recordedReloads.append(rowIndexes)
        super.reloadData(forRowIndexes: rowIndexes, columnIndexes: columnIndexes)
    }
}
