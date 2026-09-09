import Foundation
import XCTest
@testable import Mechanician

final class ConversationAttachmentIntakeTests: XCTestCase {
    @MainActor
    func testGenericFileUsesConversationOwnedStorageAcrossSharedIntake() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.base) }
        let source = fixture.base.appendingPathComponent("notes.txt")
        let bytes = Data("durable attachment".utf8)
        try bytes.write(to: source)
        let conversationID = UUID()

        let result = ConversationAttachmentIntake.ingest(
            source,
            conversationID: conversationID,
            store: fixture.store)

        guard case .file(let reference, let ownedURL) = result else {
            return XCTFail("Generic files must use the durable file-reference path.")
        }
        XCTAssertNotEqual(ownedURL.standardizedFileURL, source.standardizedFileURL)
        XCTAssertEqual(try Data(contentsOf: ownedURL), bytes)
        XCTAssertEqual(result.promptPayload, reference.promptToken)
        XCTAssertEqual(
            fixture.store.providerPrompt(
                from: result.promptPayload,
                conversationID: conversationID),
            reference.providerContext(fileURL: ownedURL))
    }

    @MainActor
    func testImageIsCopiedIntoConversationWhileConversationlessFileKeepsFallback() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.base) }
        let imageURL = fixture.base.appendingPathComponent("pixel.png")
        try XCTUnwrap(
            Data(base64Encoded:
                "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="))
            .write(to: imageURL)
        let textURL = fixture.base.appendingPathComponent("external.txt")
        try Data("external".utf8).write(to: textURL)

        let conversationID = UUID()
        let image = ConversationAttachmentIntake.ingest(
            imageURL,
            conversationID: conversationID,
            store: fixture.store)
        guard case .image(let ownedURL, _) = image else {
            return XCTFail("Images should retain their visual behavior from owned storage.")
        }
        XCTAssertNotEqual(ownedURL, imageURL)
        XCTAssertEqual(ownedURL.pathExtension, "png")
        XCTAssertEqual(try Data(contentsOf: ownedURL), try Data(contentsOf: imageURL))
        XCTAssertEqual(image.promptPayload, ownedURL.path)

        let external = ConversationAttachmentIntake.ingest(
            textURL,
            conversationID: nil,
            store: fixture.store)
        guard case .externalFile(let preservedURL) = external else {
            return XCTFail("An intake without a conversation cannot create owned storage.")
        }
        XCTAssertEqual(preservedURL, textURL)
        XCTAssertEqual(external.promptPayload, textURL.path)
    }

    @MainActor
    func testMissingFileProducesHonestUnavailablePayload() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.base) }
        let missing = fixture.base.appendingPathComponent("gone.pdf")

        let result = ConversationAttachmentIntake.ingest(
            missing,
            conversationID: UUID(),
            store: fixture.store)

        guard case .unavailable(let displayName) = result else {
            return XCTFail("Missing inputs must not become durable-looking attachment tokens.")
        }
        XCTAssertEqual(displayName, "gone.pdf")
        XCTAssertEqual(result.promptPayload, "[Attachment unavailable: gone.pdf]")
    }

    @MainActor
    func testBatchBudgetCapsAggregateCommittedBytesAndAttemptCount() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.base) }
        let first = fixture.base.appendingPathComponent("first.bin")
        let second = fixture.base.appendingPathComponent("second.bin")
        for url in [first, second] {
            XCTAssertTrue(FileManager.default.createFile(atPath: url.path, contents: nil))
            let handle = try FileHandle(forWritingTo: url)
            try handle.truncate(atOffset: 9 * 1024 * 1024)
            try handle.close()
        }
        let conversationID = UUID()
        var budget = ConversationAttachmentImportBudget()

        let firstLimit = try XCTUnwrap(budget.beginAttachment())
        let firstResult = ConversationAttachmentIntake.ingest(
            first,
            conversationID: conversationID,
            maximumBytes: firstLimit,
            store: fixture.store)
        budget.recordCommittedBytes(firstResult.committedByteCount)
        guard case .file = firstResult else {
            return XCTFail("The first file should fit inside the aggregate budget.")
        }

        let secondLimit = try XCTUnwrap(budget.beginAttachment())
        XCTAssertEqual(secondLimit, 7 * 1024 * 1024)
        let secondResult = ConversationAttachmentIntake.ingest(
            second,
            conversationID: conversationID,
            maximumBytes: secondLimit,
            store: fixture.store)
        guard case .unavailable = secondResult else {
            return XCTFail("A second file may not exceed the remaining aggregate budget.")
        }
        XCTAssertEqual(budget.remainingBytes, 7 * 1024 * 1024)

        XCTAssertNotNil(budget.beginAttachment())
        XCTAssertNotNil(budget.beginAttachment())
        XCTAssertNil(budget.beginAttachment())
        XCTAssertEqual(budget.takeLimitMessage(), ConversationAttachmentImportBudget.limitMessage)
        XCTAssertNil(budget.takeLimitMessage())
    }

    @MainActor
    private func makeFixture() throws -> (base: URL, store: ConversationStore) {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "MechanicianAttachmentIntake-\(UUID().uuidString)",
                isDirectory: true)
        try FileManager.default.createDirectory(
            at: base,
            withIntermediateDirectories: true)
        return (
            base,
            ConversationStore(
                appSupportBaseOverride: base.appendingPathComponent(
                    "support",
                    isDirectory: true),
                watchesDirectory: false))
    }
}
