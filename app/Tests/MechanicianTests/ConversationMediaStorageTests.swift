import Foundation
import XCTest
@testable import Mechanician

final class ConversationMediaStorageTests: XCTestCase {
    func testScreenshotRoundTripUsesValidatedPerConversationPathAndDeletesWithConversation() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MechanicianMediaTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let storage = ConversationMediaStorage(root: root)
        let conversationID = UUID()
        let entryID = UUID()
        let bytes = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])

        let reference = try storage.persistScreenshot(
            bytes,
            conversationID: conversationID,
            entryID: entryID,
            width: 1728,
            height: 1117)

        XCTAssertEqual(reference.fileName, "\(entryID.uuidString).png")
        XCTAssertEqual(reference.width, 1728)
        XCTAssertEqual(reference.height, 1117)
        let url = try XCTUnwrap(storage.imageURL(
            conversationID: conversationID,
            reference: reference))
        XCTAssertEqual(try Data(contentsOf: url), bytes)
        XCTAssertTrue(url.path.hasPrefix(root.appendingPathComponent(
            conversationID.uuidString, isDirectory: true).path + "/"))

        try storage.removeConversation(conversationID)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testPersistedImageReferenceRejectsTraversalAndNonUUIDNames() {
        let storage = ConversationMediaStorage(
            root: FileManager.default.temporaryDirectory.appendingPathComponent("media"))
        let conversationID = UUID()

        XCTAssertNil(storage.imageURL(
            conversationID: conversationID,
            reference: ToolImageReference(
                fileName: "../outside.png", width: 10, height: 10)))
        XCTAssertNil(storage.imageURL(
            conversationID: conversationID,
            reference: ToolImageReference(
                fileName: "preview.png", width: 10, height: 10)))
        XCTAssertNil(storage.imageURL(
            conversationID: conversationID,
            reference: ToolImageReference(
                fileName: "\(UUID().uuidString).jpg", width: 10, height: 10)))
    }

    func testComposerImageCloneRehomesBytesBeforeSourceConversationDeletion() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MechanicianMediaCloneTests-\(UUID().uuidString)",
                                    isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = ConversationMediaStorage(root: root)
        let sourceID = UUID()
        let destinationID = UUID()
        let bytes = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        let sourceReference = try storage.persistScreenshot(
            bytes,
            conversationID: sourceID,
            entryID: UUID(),
            width: 100,
            height: 80)
        let sourceURL = try XCTUnwrap(storage.imageURL(
            conversationID: sourceID,
            reference: sourceReference))

        let clone = try XCTUnwrap(storage.cloneComposerImage(
            at: sourceURL.path,
            from: sourceID,
            to: destinationID))

        XCTAssertNotEqual(clone.url, sourceURL)
        XCTAssertEqual(clone.byteCount, bytes.count)
        XCTAssertEqual(try Data(contentsOf: clone.url), bytes)
        try storage.removeConversation(sourceID)
        XCTAssertFalse(FileManager.default.fileExists(atPath: sourceURL.path))
        XCTAssertEqual(try Data(contentsOf: clone.url), bytes)

        let external = root.appendingPathComponent("external.png")
        try bytes.write(to: external)
        XCTAssertNil(try storage.cloneComposerImage(
            at: external.path,
            from: sourceID,
            to: destinationID),
            "Recovery must not copy arbitrary user files into app-owned storage.")
    }

    func testNonPNGComposerImageCopyAndCloneRemainOwnedWhileScreenshotResolverStaysPNGOnly() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "MechanicianJPEGMediaTests-\(UUID().uuidString)",
                isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source.jpg")
        let bytes = Data([0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10, 0xFF, 0xD9])
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true)
        try bytes.write(to: source)
        let storage = ConversationMediaStorage(
            root: root.appendingPathComponent("media", isDirectory: true))
        let sourceID = UUID()
        let destinationID = UUID()

        let owned = try XCTUnwrap(storage.persistComposerImageFile(
            at: source,
            conversationID: sourceID))
        XCTAssertEqual(owned.pathExtension, "jpg")
        XCTAssertTrue(storage.ownsComposerImagePath(
            owned.path,
            conversationID: sourceID))
        XCTAssertNil(storage.imageURL(
            conversationID: sourceID,
            reference: ToolImageReference(
                fileName: owned.lastPathComponent,
                width: nil,
                height: nil)),
            "Transcript screenshot references remain UUID.png-only.")

        let clone = try XCTUnwrap(storage.cloneComposerImage(
            at: owned.path,
            from: sourceID,
            to: destinationID))
        XCTAssertEqual(clone.url.pathExtension, "jpg")
        XCTAssertTrue(storage.ownsComposerImagePath(
            clone.url.path,
            conversationID: destinationID))
        XCTAssertEqual(try Data(contentsOf: clone.url), bytes)
    }

    func testComposerImageCloneRejectsSymlinkWithoutLeavingPartialDestination() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MechanicianMediaSymlinkTests-\(UUID().uuidString)",
                                    isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = ConversationMediaStorage(root: root)
        let sourceID = UUID()
        let destinationID = UUID()
        let sourceDirectory = root.appendingPathComponent(
            sourceID.uuidString,
            isDirectory: true)
        try FileManager.default.createDirectory(
            at: sourceDirectory,
            withIntermediateDirectories: true)
        let external = root.appendingPathComponent("external.png")
        try Data([0x89, 0x50, 0x4E, 0x47]).write(to: external)
        let linked = sourceDirectory.appendingPathComponent("\(UUID().uuidString).png")
        try FileManager.default.createSymbolicLink(
            at: linked,
            withDestinationURL: external)

        XCTAssertNil(try storage.cloneComposerImage(
            at: linked.path,
            from: sourceID,
            to: destinationID))
        let destinationDirectory = root.appendingPathComponent(
            destinationID.uuidString,
            isDirectory: true)
        XCTAssertEqual(
            (try? FileManager.default.contentsOfDirectory(atPath: destinationDirectory.path))
                ?? [],
            [],
            "A rejected no-follow copy must not leave a partial destination file.")
    }

    @MainActor
    func testDraftPathRewriteDeduplicatesAndOwnsRecoveredComposerMedia() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("MechanicianMediaRewriteTests-\(UUID().uuidString)",
                                    isDirectory: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let store = ConversationStore(
            appSupportBaseOverride: base,
            watchesDirectory: false)
        let sourceID = UUID()
        let destinationID = UUID()
        let bytes = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        let sourceURL = try XCTUnwrap(store.persistComposerImage(
            bytes,
            conversationID: sourceID,
            width: 120,
            height: 90))
        let lexicalVariant = sourceURL.deletingLastPathComponent().path
            + "/./" + sourceURL.lastPathComponent
        let prompt = "First image: \(sourceURL.path)\n"
            + "Again: \(sourceURL.path)\n"
            + "Lexical variant: \(lexicalVariant)"

        let rewritten = store.cloneComposerMediaPaths(
            in: prompt,
            from: sourceID,
            to: destinationID)
        let rewrittenPaths = ImagePathDetector.matches(in: rewritten).map(\.path)

        XCTAssertEqual(rewrittenPaths.count, 3)
        XCTAssertEqual(Set(rewrittenPaths).count, 1,
                       "Repeated and lexically equivalent references must reuse one clone.")
        let clonePath = try XCTUnwrap(rewrittenPaths.first)
        XCTAssertTrue(clonePath.contains("/\(destinationID.uuidString)/"))
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: clonePath)), bytes)

        let repeatedDestinationID = UUID()
        let repeated = Array(repeating: sourceURL.path, count: 1_000)
            .joined(separator: " ")
        let repeatedRewrite = store.cloneComposerMediaPaths(
            in: repeated,
            from: sourceID,
            to: repeatedDestinationID)
        let repeatedPaths = ImagePathDetector.matches(in: repeatedRewrite).map(\.path)
        XCTAssertEqual(repeatedPaths.count, 1_000)
        XCTAssertEqual(Set(repeatedPaths).count, 1,
                       "Large repeated prompts should remain linear and consume one clone.")

        var boundedSources = [sourceURL]
        for _ in 0..<4 {
            boundedSources.append(try XCTUnwrap(store.persistComposerImage(
                bytes,
                conversationID: sourceID,
                width: 120,
                height: 90)))
        }
        let boundedDestinationID = UUID()
        let bounded = store.cloneComposerMediaPaths(
            in: boundedSources.map(\.path).joined(separator: "\n"),
            from: sourceID,
            to: boundedDestinationID)
        XCTAssertEqual(ImagePathDetector.matches(in: bounded).count, 4)
        XCTAssertTrue(bounded.contains("[Pasted image unavailable. Attach it again]"),
                      "Synchronous recovery copies must stay within their unique-file cap.")

        let largeBytes = Data(repeating: 0x7F, count: 9 * 1024 * 1024)
        let largeSources = try (0..<2).map { _ in
            try XCTUnwrap(store.persistComposerImage(
                largeBytes,
                conversationID: sourceID,
                width: 120,
                height: 90))
        }
        let byteBounded = store.cloneComposerMediaPaths(
            in: largeSources.map(\.path).joined(separator: "\n"),
            from: sourceID,
            to: UUID())
        XCTAssertEqual(ImagePathDetector.matches(in: byteBounded).count, 1)
        XCTAssertTrue(byteBounded.contains("[Pasted image unavailable. Attach it again]"),
                      "Actual copied bytes must stay within the aggregate 16 MiB budget.")

        let forkDestinationID = UUID()
        let forkInputs = [
            "old turn \(sourceURL.path)",
            "later turn \(sourceURL.path)",
        ] + boundedSources.dropFirst().map { "unique turn \($0.path)" }
        let forkOutputs = store.cloneComposerMediaPaths(
            in: forkInputs,
            from: sourceID,
            to: forkDestinationID)
        let repeatedForkPaths = forkOutputs.prefix(2)
            .flatMap { ImagePathDetector.matches(in: $0).map(\.path) }
        XCTAssertEqual(repeatedForkPaths.count, 2)
        XCTAssertEqual(
            Set(repeatedForkPaths).count,
            1,
            "A media reference repeated across retained fork turns must reuse one destination copy.")
        XCTAssertEqual(
            Set(forkOutputs
                .flatMap { ImagePathDetector.matches(in: $0).map(\.path) })
                .count,
            ConversationAttachmentImportBudget.maximumFiles,
            "A multi-entry fork must share one file cap instead of resetting it per transcript row.")
        XCTAssertTrue(
            forkOutputs.last?.contains("[Pasted image unavailable. Attach it again]") == true)

        let storage = ConversationMediaStorage(
            root: base.appendingPathComponent("conversation-media", isDirectory: true))
        try storage.removeConversation(sourceID)
        XCTAssertFalse(FileManager.default.fileExists(atPath: sourceURL.path))
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: clonePath)), bytes)
    }

    @MainActor
    func testForkClonesCurrentPromptBeforeHistoryAndSurvivesSourceDeletion() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "MechanicianForkMediaPriorityTests-\(UUID().uuidString)",
                isDirectory: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let store = ConversationStore(
            appSupportBaseOverride: base,
            watchesDirectory: false)
        let sourceID = UUID()
        let destinationID = UUID()
        let bytes = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        let currentSource = try XCTUnwrap(store.persistComposerImage(
            bytes,
            conversationID: sourceID,
            width: 120,
            height: 90))
        let historySources = try (0..<ConversationAttachmentImportBudget.maximumFiles).map { _ in
            try XCTUnwrap(store.persistComposerImage(
                bytes,
                conversationID: sourceID,
                width: 120,
                height: 90))
        }

        let cloned = store.cloneForkComposerMediaPaths(
            currentPrompt: "Current request \(currentSource.path)",
            replayedHistoryPrompts: historySources.map { "Earlier turn \($0.path)" },
            from: sourceID,
            to: destinationID)
        let currentClone = try XCTUnwrap(
            ImagePathDetector.matches(in: cloned.currentPrompt).first?.path)

        XCTAssertTrue(currentClone.contains("/\(destinationID.uuidString)/"))
        XCTAssertEqual(
            cloned.replayedHistoryPrompts
                .flatMap { ImagePathDetector.matches(in: $0) }
                .count,
            ConversationAttachmentImportBudget.maximumFiles - 1,
            "The current branch prompt gets the first slot; only the remaining budget goes to history.")
        XCTAssertTrue(
            cloned.replayedHistoryPrompts.last?
                .contains("[Pasted image unavailable. Attach it again]") == true)

        let storage = ConversationMediaStorage(
            root: base.appendingPathComponent("conversation-media", isDirectory: true))
        try storage.removeConversation(sourceID)

        XCTAssertFalse(FileManager.default.fileExists(atPath: currentSource.path))
        XCTAssertEqual(
            try Data(contentsOf: URL(fileURLWithPath: currentClone)),
            bytes,
            "A fork must own the current prompt's media after its source conversation is deleted.")
    }

    @MainActor
    func testCloneBudgetPreservesAuthoredMixedImageAndFileOrder() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "MechanicianMixedCloneOrderTests-\(UUID().uuidString)",
                isDirectory: true)
        let incoming = base.appendingPathComponent("incoming", isDirectory: true)
        try FileManager.default.createDirectory(
            at: incoming,
            withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let store = ConversationStore(
            appSupportBaseOverride: base.appendingPathComponent("support", isDirectory: true),
            watchesDirectory: false)
        let sourceID = UUID()
        let destinationID = UUID()
        let files = try (1...4).map { index -> ConversationFileReference in
            let url = incoming.appendingPathComponent("file-\(index).txt")
            try Data("file \(index)".utf8).write(to: url)
            return try XCTUnwrap(store.persistComposerFile(
                at: url,
                conversationID: sourceID))
        }
        let firstImageBytes = Data([0x89, 0x50, 0x4E, 0x47, 0x01])
        let secondImageBytes = Data([0x89, 0x50, 0x4E, 0x47, 0x02])
        let firstImage = try XCTUnwrap(store.persistComposerImage(
            firstImageBytes,
            conversationID: sourceID,
            width: 10,
            height: 10))
        let secondImage = try XCTUnwrap(store.persistComposerImage(
            secondImageBytes,
            conversationID: sourceID,
            width: 10,
            height: 10))
        let prompt = [
            files[0].promptToken,
            firstImage.path,
            files[1].promptToken,
            files[2].promptToken,
            files[3].promptToken,
            secondImage.path,
        ].joined(separator: "\n")

        let rewritten = store.cloneComposerMediaPaths(
            in: prompt,
            from: sourceID,
            to: destinationID)
        let survivingFiles = ConversationFileReference.matches(in: rewritten)
            .map(\.reference.displayName)
        let survivingImage = try XCTUnwrap(
            ImagePathDetector.matches(in: rewritten).first?.path)

        XCTAssertEqual(
            survivingFiles,
            ["file-1.txt", "file-2.txt", "file-3.txt"],
            "A later image must not jump ahead of earlier authored files when applying the cap.")
        XCTAssertEqual(ImagePathDetector.matches(in: rewritten).count, 1)
        XCTAssertEqual(
            try Data(contentsOf: URL(fileURLWithPath: survivingImage)),
            firstImageBytes)
        XCTAssertTrue(rewritten.contains("[Attached file unavailable. Attach it again]"))
        XCTAssertTrue(rewritten.contains("[Pasted image unavailable. Attach it again]"))
    }

    @MainActor
    func testForkMediaSelectionUsesTheProviderHistoryReplayPredicate() {
        let ordinary = TranscriptEntry(kind: .user, text: "ordinary")
        var delivered = TranscriptEntry(kind: .user, text: "delivered guidance")
        delivered.guidanceState = .delivered
        var queued = TranscriptEntry(kind: .user, text: "queued guidance")
        queued.guidanceState = .queued
        var sending = TranscriptEntry(kind: .user, text: "sending guidance")
        sending.guidanceState = .sending
        var cancelled = TranscriptEntry(kind: .user, text: "cancelled guidance")
        cancelled.guidanceState = .cancelled
        var superseded = TranscriptEntry(kind: .user, text: "superseded")
        superseded.supersessionEventID = UUID()

        XCTAssertTrue(AgentBridge.historyEntryIsReplayable(ordinary))
        XCTAssertTrue(AgentBridge.historyEntryIsReplayable(delivered))
        XCTAssertTrue(AgentBridge.historyEntryIsReplayable(
            TranscriptEntry(kind: .assistant, text: "answer")))
        XCTAssertFalse(AgentBridge.historyEntryIsReplayable(queued))
        XCTAssertFalse(AgentBridge.historyEntryIsReplayable(sending))
        XCTAssertFalse(AgentBridge.historyEntryIsReplayable(cancelled))
        XCTAssertFalse(AgentBridge.historyEntryIsReplayable(superseded))
        XCTAssertFalse(AgentBridge.historyEntryIsReplayable(
            TranscriptEntry(kind: .tool, text: "not replayed directly")))
    }

    func testHistoricalTranscriptWithoutImageReferenceStillDecodes() throws {
        let entry = TranscriptEntry(
            kind: .tool,
            text: "{}",
            toolName: "ComputerScreenshot",
            toolResult: "Screen: 1728×1117 points")
        let encoded = try JSONEncoder().encode(entry)
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object.removeValue(forKey: "toolImage")
        let legacy = try JSONSerialization.data(withJSONObject: object)

        XCTAssertNil(try JSONDecoder().decode(TranscriptEntry.self, from: legacy).toolImage)
    }
}

/// A tool-captured screenshot lives in `TranscriptEntry.toolImage`, a structured reference rather
/// than a path inside prompt text. Fork cloning only rewrote text, so a fork inherited a reference
/// that resolved inside its own empty directory and the card read "Preview unavailable" forever —
/// with the original conversation still holding the bytes and nothing having been deleted.
@MainActor
final class ForkToolImageCloneTests: XCTestCase {
    private func makeStore() throws -> (ConversationStore, URL) {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(
            "MechanicianForkToolImage-\(UUID().uuidString)", isDirectory: true)
        return (ConversationStore(appSupportBaseOverride: base, watchesDirectory: false), base)
    }

    private let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])

    func testAForkCanShowAScreenshotItInherited() async throws {
        let (store, base) = try makeStore()
        defer { try? FileManager.default.removeItem(at: base) }
        let source = UUID()
        let fork = UUID()
        let persisted = await store.persistToolImage(
            png, conversationID: source, entryID: UUID(), width: 120, height: 90)
        let reference = try XCTUnwrap(persisted)

        // What the fork inherits: the tool row verbatim, reference untouched.
        var entry = TranscriptEntry(kind: .tool, text: "screenshot")
        entry.toolImage = reference
        XCTAssertNil(
            try? Data(contentsOf: XCTUnwrap(
                store.toolImageURL(conversationID: fork, reference: reference))),
            "precondition: the fork's own directory does not hold the bytes yet")

        store.cloneForkToolImages(in: [entry], from: source, to: fork)

        let forked = try XCTUnwrap(store.toolImageURL(conversationID: fork, reference: reference))
        XCTAssertEqual(try Data(contentsOf: forked), png, "the fork resolves the same image")
        let original = try XCTUnwrap(store.toolImageURL(conversationID: source, reference: reference))
        XCTAssertEqual(try Data(contentsOf: original), png, "and the original still has it")
    }

    /// Cloning must be idempotent: a fork of a fork, or a repeated call, must not fail or duplicate.
    func testCloningAnImageTheForkAlreadyHasIsANoOp() async throws {
        let (store, base) = try makeStore()
        defer { try? FileManager.default.removeItem(at: base) }
        let source = UUID()
        let fork = UUID()
        let persisted = await store.persistToolImage(
            png, conversationID: source, entryID: UUID(), width: 120, height: 90)
        let reference = try XCTUnwrap(persisted)
        var entry = TranscriptEntry(kind: .tool, text: "screenshot")
        entry.toolImage = reference

        store.cloneForkToolImages(in: [entry], from: source, to: fork)
        store.cloneForkToolImages(in: [entry], from: source, to: fork)

        let forked = try XCTUnwrap(store.toolImageURL(conversationID: fork, reference: reference))
        XCTAssertEqual(try Data(contentsOf: forked), png)
    }

    /// An entry with no screenshot, and a reference whose bytes are already gone, must both be
    /// survivable: a fork that inherits a broken reference is no worse off than its source.
    func testEntriesWithoutAnImageAndMissingBytesAreSurvivable() async throws {
        let (store, base) = try makeStore()
        defer { try? FileManager.default.removeItem(at: base) }
        let source = UUID()
        let fork = UUID()
        let plain = TranscriptEntry(kind: .user, text: "no image here")
        let persisted = await store.persistToolImage(
            png, conversationID: source, entryID: UUID(), width: 120, height: 90)
        let reference = try XCTUnwrap(persisted)
        try FileManager.default.removeItem(
            at: XCTUnwrap(store.toolImageURL(conversationID: source, reference: reference)))
        var orphaned = TranscriptEntry(kind: .tool, text: "screenshot")
        orphaned.toolImage = reference

        store.cloneForkToolImages(in: [plain, orphaned], from: source, to: fork)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: try XCTUnwrap(
                store.toolImageURL(conversationID: fork, reference: reference)).path))
    }
}
