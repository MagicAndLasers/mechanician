import Foundation
import Combine
import XCTest
@testable import Mechanician

@MainActor
final class ConversationTitlePolicyTests: XCTestCase {
    private func temporarySupportRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "conversation-title-fast-path-\(UUID().uuidString)",
            isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func drainMainQueue() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
    }

    func testGeneratedTitleStripsLabelsMarkdownAndPunctuation() {
        XCTAssertEqual(
            ConversationTitlePolicy.sanitizeGenerated(
                #"**Title: Async Conversation Titles.**"#),
            "Async Conversation Titles")
        XCTAssertEqual(
            ConversationTitlePolicy.sanitizeGenerated("1. **Fix Workspace Tabs!**"),
            "Fix Workspace Tabs")
        XCTAssertEqual(
            ConversationTitlePolicy.sanitizeGenerated("TITLE - Repair Existing Titles"),
            "Repair Existing Titles")
    }

    func testGeneratedTitleUsesFirstMeaningfulLine() {
        XCTAssertEqual(
            ConversationTitlePolicy.sanitizeGenerated(
                """
                Here is the title:
                ```
                Background Title Generation
                ```
                """),
            "Background Title Generation")
    }

    func testGeneratedTitleRejectsRefusalInsteadOfPersistingIt() {
        XCTAssertNil(ConversationTitlePolicy.sanitizeGenerated(
            "I'm unable to provide a title for that request."))
        XCTAssertNil(ConversationTitlePolicy.sanitizeGenerated(
            "As an AI, I cannot provide that title."))
        XCTAssertNil(ConversationTitlePolicy.sanitizeGenerated(
            "I'm sorry, but I can't name this conversation."))
        XCTAssertNil(ConversationTitlePolicy.sanitizeGenerated(
            """
            ```bash
            echo COPYTEST123
            ```
            """))
    }

    func testGeneratedTitleNormalizesAllCapsAndBoundsLength() {
        XCTAssertEqual(
            ConversationTitlePolicy.sanitizeGenerated("ASYNC TITLE GENERATION"),
            "Async Title Generation")
        let title = ConversationTitlePolicy.sanitizeGenerated(
            "A deliberately verbose generated conversation title that should stop cleanly before overflowing the native tab")
        XCTAssertNotNil(title)
        XCTAssertLessThanOrEqual(title?.count ?? .max, ConversationTitlePolicy.maximumCharacters)
        XCTAssertFalse(title?.hasSuffix(" ") ?? true)
    }

    func testFallbackUsesOneReadableLineWithoutMarkdown() {
        XCTAssertEqual(
            ConversationTitlePolicy.fallback(from:
                """
                # Fix generated titles
                This second line should not appear.
                """),
            "Fix generated titles")
        XCTAssertEqual(
            ConversationTitlePolicy.fallback(from: " \n\t"),
            ConversationTitlePolicy.placeholder)
    }

    func testOnlyPlaceholderAndFallbackTitlesAreAutomaticallyReplaceable() {
        XCTAssertTrue(ConversationTitlePolicy.canReplaceAutomatically(.placeholder))
        XCTAssertTrue(ConversationTitlePolicy.canReplaceAutomatically(.fallback))
        XCTAssertFalse(ConversationTitlePolicy.canReplaceAutomatically(.generated))
        XCTAssertFalse(ConversationTitlePolicy.canReplaceAutomatically(.manual))
        XCTAssertFalse(ConversationTitlePolicy.canReplaceAutomatically(.legacy))
    }

    func testTitleSourceRoundTripsAndLegacySidecarStaysProtected() throws {
        let conversation = Conversation(
            title: "Chosen by a person",
            titleSource: .manual,
            cwd: "",
            sdkSessionId: nil,
            messages: [],
            updatedAt: Date())
        let encoded = try ConversationStore.makeEncoder().encode(conversation)
        let decoded = try ConversationStore.makeDecoder().decode(
            Conversation.self,
            from: encoded)
        XCTAssertEqual(decoded.titleSource, .manual)

        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object.removeValue(forKey: "titleSource")
        let legacyData = try JSONSerialization.data(withJSONObject: object)
        let legacy = try ConversationStore.makeDecoder().decode(
            Conversation.self,
            from: legacyData)
        XCTAssertEqual(legacy.titleSource, .legacy)
        XCTAssertFalse(ConversationTitlePolicy.canReplaceAutomatically(legacy.titleSource))
    }

    func testManualRenameChangesProvenanceWithoutChangingRecency() async {
        let conversation = Conversation(
            title: "Opening prompt fallback",
            titleSource: .fallback,
            cwd: "",
            sdkSessionId: nil,
            messages: [],
            updatedAt: Date(timeIntervalSince1970: 42))
        ConversationStore.shared.upsert(conversation)
        let bridge = AgentBridge(
            settingsBaseOverride: FileManager.default.temporaryDirectory
                .appendingPathComponent("title-policy-\(UUID().uuidString)"),
            environmentOverride: [:])
        defer {
            bridge.shutdown()
            ConversationStore.shared.remove(conversation.id, permanently: true)
            ConversationStore.shared.flushSaves()
        }

        let renamedExpectation = expectation(description: "rename lands after hydration")
        bridge.renameConversation(conversation.id, to: "My chosen title") { renamed in
            XCTAssertEqual(renamed?.title, "My chosen title")
            XCTAssertEqual(renamed?.titleSource, .manual)
            XCTAssertEqual(renamed?.updatedAt, conversation.updatedAt)
            renamedExpectation.fulfill()
        }
        await fulfillment(of: [renamedExpectation], timeout: 2)

        let renamed = ConversationStore.shared.conversation(conversation.id)
        if let renamed {
            XCTAssertEqual(renamed.title, "My chosen title")
            XCTAssertEqual(renamed.titleSource, .manual)
            XCTAssertEqual(renamed.updatedAt, conversation.updatedAt)
        }
    }

    func testResidentTitleFastPathDoesNotRescanLargeTranscriptOrReorderInventory() throws {
        let root = try temporarySupportRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ConversationStore(appSupportBaseOverride: root, watchesDirectory: false)

        var messages = (0..<12_000).map { index in
            TranscriptEntry(
                kind: index.isMultiple(of: 2) ? .user : .assistant,
                text: "retained row \(index)")
        }
        messages[messages.count - 1].toolTerminalCaptureOrdinal = 65_000
        let timestamp = Date(timeIntervalSinceReferenceDate: 60_000)
        let large = Conversation(
            title: "Opening prompt fallback",
            titleSource: .fallback,
            cwd: "",
            sdkSessionId: nil,
            messages: messages,
            updatedAt: timestamp)
        let older = Conversation(
            title: "Older peer",
            cwd: "",
            sdkSessionId: nil,
            messages: [TranscriptEntry(kind: .user, text: "peer")],
            updatedAt: timestamp.addingTimeInterval(-1))
        store.upsert(large)
        store.upsert(older)
        store.flushSaves()

        let orderBefore = store.summaries.map(\.id)
        let summaryBefore = try XCTUnwrap(store.summary(large.id))
        let derivationsBefore = store.fullSummaryDerivationCount
        let seedScansBefore = store.captureOrdinalSeedScanCount
        let saveScansBefore = store.saveCaptureOrdinalScanCount
        var renamed: Conversation?

        store.updateTitleAfterAcquiring(
            large.id,
            to: "A title chosen by the person",
            source: .manual,
            completion: { renamed = $0 })

        XCTAssertEqual(renamed?.title, "A title chosen by the person")
        XCTAssertEqual(renamed?.titleSource, .manual)
        XCTAssertEqual(renamed?.updatedAt, timestamp)
        XCTAssertEqual(renamed?.messages.count, messages.count)
        XCTAssertEqual(store.summaries.map(\.id), orderBefore)
        var expectedSummary = summaryBefore
        expectedSummary.title = "A title chosen by the person"
        XCTAssertEqual(store.summary(large.id), expectedSummary)
        XCTAssertEqual(store.fullSummaryDerivationCount, derivationsBefore)
        XCTAssertEqual(store.captureOrdinalSeedScanCount, seedScansBefore)
        XCTAssertEqual(store.saveCaptureOrdinalScanCount, saveScansBefore)

        // The arbitrary mutation seam remains conservative: it still derives the whole summary
        // and proves retained chronology rather than borrowing the title-only assertion.
        store.update(large.id) { $0.unread = true }
        XCTAssertEqual(store.fullSummaryDerivationCount, derivationsBefore + 1)
        XCTAssertEqual(store.saveCaptureOrdinalScanCount, saveScansBefore + 1)
        store.flushSaves()

        let relaunched = ConversationStore(
            appSupportBaseOverride: root,
            watchesDirectory: false)
        let restored = try XCTUnwrap(relaunched.conversation(large.id))
        XCTAssertEqual(restored.title, "A title chosen by the person")
        XCTAssertEqual(restored.titleSource, .manual)
        XCTAssertEqual(restored.updatedAt, timestamp)
        XCTAssertTrue(restored.unread)
        XCTAssertEqual(restored.messages.count, messages.count)
        XCTAssertEqual(relaunched.nextCaptureOrdinal(for: large.id), 65_001)
    }

    func testDelayedGeneratedTitleCannotReplaceManualFastPathRename() throws {
        let root = try temporarySupportRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ConversationStore(appSupportBaseOverride: root, watchesDirectory: false)
        let opening = "Explain the generated-title race"
        let conversation = Conversation(
            title: ConversationTitlePolicy.fallback(from: opening),
            titleSource: .fallback,
            cwd: "",
            sdkSessionId: nil,
            messages: [TranscriptEntry(kind: .user, text: opening)],
            updatedAt: Date(timeIntervalSinceReferenceDate: 61_000))
        store.upsert(conversation)
        store.flushSaves()

        XCTAssertNotNil(store.updateTitleResident(
            conversation.id,
            to: "My manual title",
            source: .manual))
        let delayed = store.updateTitleResident(
            conversation.id,
            to: "Delayed generated title",
            source: .generated,
            ifCurrent: { current in
                ConversationTitlePolicy.canReplaceAutomatically(current.titleSource)
                    && current.messages.first(where: { $0.kind == .user })?.text == opening
            })

        XCTAssertNil(delayed)
        XCTAssertEqual(store.conversation(conversation.id)?.title, "My manual title")
        XCTAssertEqual(store.conversation(conversation.id)?.titleSource, .manual)
        store.flushSaves()
    }

    func testTitleFastPathKeepsPendingLiveSummaryRefresh() throws {
        let root = try temporarySupportRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ConversationStore(appSupportBaseOverride: root, watchesDirectory: false)
        let conversation = Conversation(
            title: "Fallback title",
            titleSource: .fallback,
            cwd: "",
            sdkSessionId: nil,
            messages: [TranscriptEntry(kind: .assistant, text: "Earlier result")],
            updatedAt: Date(timeIntervalSinceReferenceDate: 61_500))
        store.upsert(conversation)
        store.flushSaves()

        store.updateLive(conversation.id) {
            $0.messages.append(TranscriptEntry(kind: .user, text: "Live follow-up"))
        }
        XCTAssertNotNil(store.updateTitleResident(
            conversation.id,
            to: "Manual during streaming",
            source: .manual))
        XCTAssertEqual(store.summary(conversation.id)?.title, "Manual during streaming")
        XCTAssertEqual(store.summary(conversation.id)?.snippet, "Earlier result")

        store.flushLiveSummaryRefreshes()
        XCTAssertEqual(store.summary(conversation.id)?.title, "Manual during streaming")
        XCTAssertEqual(store.summary(conversation.id)?.snippet, "You: Live follow-up")
        XCTAssertEqual(store.summary(conversation.id)?.messageCount, 2)
        store.flushSaves()
    }

    func testSameTextManualRenamePublishesTitleSourceChange() throws {
        let root = try temporarySupportRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ConversationStore(appSupportBaseOverride: root, watchesDirectory: false)
        let conversation = Conversation(
            title: "Keep this exact title",
            titleSource: .fallback,
            cwd: "",
            sdkSessionId: nil,
            messages: [TranscriptEntry(kind: .user, text: "Opening")],
            updatedAt: Date(timeIntervalSinceReferenceDate: 61_750))
        store.upsert(conversation)
        store.flushSaves()
        var publicationCount = 0
        let observation = store.objectWillChange.sink { publicationCount += 1 }
        defer { observation.cancel() }

        let renamed = store.updateTitleResident(
            conversation.id,
            to: conversation.title,
            source: .manual)

        XCTAssertEqual(renamed?.title, conversation.title)
        XCTAssertEqual(renamed?.titleSource, .manual)
        XCTAssertGreaterThan(publicationCount, 0)
        store.flushSaves()
    }

    func testTitleFastPathRetainsNewestSnapshotAcrossPersistenceRetry() async throws {
        let root = try temporarySupportRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        defer { ConversationStore.persistenceWriteTestHook = nil }
        let store = ConversationStore(appSupportBaseOverride: root, watchesDirectory: false)
        let conversation = Conversation(
            title: "Fallback before retry",
            titleSource: .fallback,
            cwd: "",
            sdkSessionId: nil,
            messages: [TranscriptEntry(kind: .user, text: "Keep the manual title")],
            updatedAt: Date(timeIntervalSinceReferenceDate: 62_000))
        store.upsert(conversation)
        store.flushSaves()

        ConversationStore.persistenceWriteTestHook = {
            throw CocoaError(.fileWriteNoPermission)
        }
        XCTAssertNotNil(store.updateTitleResident(
            conversation.id,
            to: "Manual title awaiting retry",
            source: .manual))
        store.flushSaves()
        await drainMainQueue()
        XCTAssertNotNil(store.persistenceError)

        ConversationStore.persistenceWriteTestHook = nil
        let saveScansBeforeRetry = store.saveCaptureOrdinalScanCount
        store.retryFailedSaves()
        store.flushSaves()
        await drainMainQueue()
        XCTAssertNil(store.persistenceError)
        XCTAssertEqual(store.saveCaptureOrdinalScanCount, saveScansBeforeRetry)

        let relaunched = ConversationStore(
            appSupportBaseOverride: root,
            watchesDirectory: false)
        let restored = try XCTUnwrap(relaunched.conversation(conversation.id))
        XCTAssertEqual(restored.title, "Manual title awaiting retry")
        XCTAssertEqual(restored.titleSource, .manual)
        XCTAssertEqual(restored.messages.map(\.id), conversation.messages.map(\.id))
        XCTAssertEqual(restored.messages.map(\.text), conversation.messages.map(\.text))
    }
}
