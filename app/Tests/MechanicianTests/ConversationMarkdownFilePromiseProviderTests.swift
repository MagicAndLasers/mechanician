import AppKit
import Foundation
import UniformTypeIdentifiers
import XCTest
@testable import Mechanician

/// The outbound Conversation drag is a performance boundary for bounded residency. AppKit asks
/// for a pasteboard writer synchronously, so that writer may advertise identity and a filename but
/// must not decode a Conversation until the receiving app actually fulfills its file promise.
@MainActor
final class ConversationMarkdownFilePromiseProviderTests: XCTestCase {
    private final class QueueProbe: @unchecked Sendable {
        private let lock = NSLock()
        private(set) var error: Error?
        private(set) var timedOut = false

        func record(error: Error?) {
            lock.lock()
            self.error = error
            lock.unlock()
        }

        func record(timedOut: Bool) {
            lock.lock()
            self.timedOut = timedOut
            lock.unlock()
        }

        func snapshot() -> (Error?, Bool) {
            lock.lock()
            defer { lock.unlock() }
            return (error, timedOut)
        }
    }

    /// The test deliberately models AppKit calling the non-Sendable provider/delegate from its
    /// operation queue. Keep that audited boundary in one unchecked box instead of teaching the
    /// test target to ignore Sendable diagnostics globally.
    private final class QueueInvocation: @unchecked Sendable {
        private let provider: ConversationMarkdownFilePromiseProvider
        private let delegate: any NSFilePromiseProviderDelegate

        init(
            provider: ConversationMarkdownFilePromiseProvider,
            delegate: any NSFilePromiseProviderDelegate
        ) {
            self.provider = provider
            self.delegate = delegate
        }

        func perform(
            output: URL,
            probe: QueueProbe,
            finished: XCTestExpectation
        ) {
            let completion = DispatchSemaphore(value: 0)
            delegate.filePromiseProvider(
                provider,
                writePromiseTo: output,
                completionHandler: { error in
                    probe.record(error: error)
                    completion.signal()
                })
            probe.record(timedOut: completion.wait(timeout: .now() + 2) == .timedOut)
            finished.fulfill()
        }
    }

    private final class BaselinePromiseDelegate: NSObject, NSFilePromiseProviderDelegate {
        @MainActor
        func filePromiseProvider(
            _ filePromiseProvider: NSFilePromiseProvider,
            fileNameForType fileType: String
        ) -> String {
            "Conversation.md"
        }

        nonisolated func filePromiseProvider(
            _ filePromiseProvider: NSFilePromiseProvider,
            writePromiseTo url: URL,
            completionHandler: @escaping (Error?) -> Void
        ) {
            completionHandler(nil)
        }
    }

    private func makeBase() throws -> URL {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(
            "Mechanician-outbound-promise-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    private func conversation(title: String) -> Conversation {
        Conversation(
            title: title,
            cwd: "/tmp/\(title)",
            sdkSessionId: nil,
            messages: [
                TranscriptEntry(kind: .user, text: "durable user text for \(title)"),
                TranscriptEntry(kind: .assistant, text: "durable assistant text for \(title)"),
            ],
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

    private func awaitReady(_ store: ConversationStore) async {
        await withCheckedContinuation { continuation in
            store.whenReady { continuation.resume() }
        }
        for _ in 0..<10_000 {
            if store.activeResidencyMode == .boundedAfterRecovery { return }
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTFail("bounded residency did not activate after projection reconciliation")
    }

    private func remove(
        _ id: UUID,
        from store: ConversationStore
    ) async -> ConversationDeleteReceipt? {
        await withCheckedContinuation { continuation in
            store.removeAfterAcquiring(id, permanently: true) {
                continuation.resume(returning: $0)
            }
        }
    }

    private func provider(
        for id: UUID,
        filename: String,
        store: ConversationStore
    ) -> ConversationMarkdownFilePromiseProvider {
        ConversationMarkdownFilePromiseProvider(
            conversationID: id,
            filename: filename,
            requestDocument: { requestedID, completion in
                ConversationMarkdownExport.document(
                    for: requestedID,
                    in: store,
                    completion: completion)
            })
    }

    private func fulfill(
        _ provider: ConversationMarkdownFilePromiseProvider,
        at url: URL
    ) async -> Error? {
        await withCheckedContinuation { continuation in
            guard let delegate = provider.delegate else {
                XCTFail("The provider must retain its promise delegate until fulfillment.")
                continuation.resume(returning: NSError(
                    domain: "ConversationMarkdownFilePromiseProviderTests",
                    code: 1))
                return
            }
            delegate.filePromiseProvider(
                provider,
                writePromiseTo: url,
                completionHandler: { continuation.resume(returning: $0) })
        }
    }

    private func waitUntil(
        _ description: String,
        _ condition: @escaping @MainActor () -> Bool
    ) async {
        for _ in 0..<2_000 {
            if condition() { return }
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTFail("Timed out waiting for \(description).")
    }

    func testProviderKeepsAppKitPromiseTypesAndAddsPrivateConversationIdentity() throws {
        let id = UUID()
        var documentRequests = 0
        let provider = ConversationMarkdownFilePromiseProvider(
            conversationID: id,
            filename: "Portable.md",
            requestDocument: { _, completion in
                documentRequests += 1
                completion(.failure(.deleted))
            })
        let baselineDelegate = BaselinePromiseDelegate()
        let baseline = NSFilePromiseProvider(
            fileType: UTType.plainText.identifier,
            delegate: baselineDelegate)

        let pasteboard = NSPasteboard(
            name: NSPasteboard.Name(
                "ai.mechanician.tests.outbound-promise.\(UUID().uuidString)"))
        let actualTypes = Set(provider.writableTypes(for: pasteboard))
        for type in baseline.writableTypes(for: pasteboard) {
            XCTAssertTrue(
                actualTypes.contains(type),
                "Adding Mechanician's row identity must not hide AppKit's public file promise type \(type.rawValue).")
        }
        XCTAssertTrue(
            actualTypes.contains(NSPasteboard.PasteboardType.mechConversationRow))
        XCTAssertEqual(
            provider.pasteboardPropertyList(
                forType: NSPasteboard.PasteboardType.mechConversationRow) as? String,
            id.uuidString)
        XCTAssertEqual(
            provider.delegate?.filePromiseProvider(
                provider,
                fileNameForType: provider.fileType),
            "Portable.md")
        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.writeObjects([provider]))
        XCTAssertEqual(
            pasteboard.pasteboardItems?.first?.string(
                forType: NSPasteboard.PasteboardType.mechConversationRow),
            id.uuidString)
        let receivers = pasteboard.readObjects(
            forClasses: [NSFilePromiseReceiver.self],
            options: nil) as? [NSFilePromiseReceiver]
        XCTAssertEqual(receivers?.count, 1)
        XCTAssertTrue(receivers?.first?.fileTypes.contains(provider.fileType) == true)
        XCTAssertEqual(
            documentRequests,
            0,
            "Creating or inspecting a drag writer must not hydrate its Conversation. Internal "
                + "and cancelled drags can consume the private identity without fulfilling the "
                + "public file promise.")
    }

    func testProviderRetainsDelegateAfterInitializerScopeEnds() async throws {
        let destination = try makeBase()
        defer { try? FileManager.default.removeItem(at: destination) }
        let id = UUID()
        let document = ConversationMarkdownDocument(
            conversation: conversation(title: "Retained delegate"))
        weak var delegate: AnyObject?

        let provider: ConversationMarkdownFilePromiseProvider = {
            let provider = ConversationMarkdownFilePromiseProvider(
                conversationID: id,
                filename: document.filename,
                requestDocument: { _, completion in completion(.success(document)) })
            delegate = provider.delegate as AnyObject?
            return provider
        }()

        XCTAssertNotNil(delegate)
        XCTAssertNotNil(provider.delegate)
        let output = destination.appendingPathComponent(document.filename)
        let error = await fulfill(provider, at: output)
        XCTAssertNil(error)
        XCTAssertEqual(try String(contentsOf: output, encoding: .utf8), document.contents)
    }

    func testEvictedPromiseWritesExactMarkdownWithoutSynchronousHydration() async throws {
        let base = try makeBase()
        defer { try? FileManager.default.removeItem(at: base) }
        let seeded = conversation(title: "Promised after eviction")
        try seed([seeded], at: base)
        let store = ConversationStore(
            appSupportBaseOverride: base,
            watchesDirectory: false,
            residencyMode: .boundedAfterRecovery)
        await awaitReady(store)
        store.trimResidencyIfNeeded(evictAllEligible: true)
        XCTAssertNil(store.residentConversation(seeded.id))

        let expected = ConversationMarkdownDocument(conversation: seeded)
        let promise = provider(for: seeded.id, filename: expected.filename, store: store)
        let output = base.appendingPathComponent(expected.filename)
        let error = await fulfill(promise, at: output)
        XCTAssertNil(error)

        XCTAssertEqual(try String(contentsOf: output, encoding: .utf8), expected.contents)
        XCTAssertEqual(store.synchronousHydrationCount, 0)
        XCTAssertEqual(store.hydrationDecodeCounts[seeded.id], 1)
    }

    func testMissingCorruptAndDeletedPromisesFailWithoutCreatingEmptyFiles() async throws {
        let base = try makeBase()
        defer { try? FileManager.default.removeItem(at: base) }
        let missing = conversation(title: "Missing promise")
        let corrupt = conversation(title: "Corrupt promise")
        let deleted = conversation(title: "Deleted promise")
        let identityMismatch = conversation(title: "Identity mismatch promise")
        try seed([missing, corrupt, deleted, identityMismatch], at: base)
        let store = ConversationStore(
            appSupportBaseOverride: base,
            watchesDirectory: false,
            residencyMode: .boundedAfterRecovery)
        await awaitReady(store)
        store.trimResidencyIfNeeded(evictAllEligible: true)

        let sidecars = base.appendingPathComponent("conversations", isDirectory: true)
        try FileManager.default.removeItem(
            at: sidecars.appendingPathComponent("\(missing.id.uuidString).json"))
        try Data("not conversation json".utf8).write(
            to: sidecars.appendingPathComponent("\(corrupt.id.uuidString).json"),
            options: .atomic)
        let wrongIdentity = conversation(title: "Wrong identity bytes")
        try ConversationStore.makeEncoder().encode(wrongIdentity).write(
            to: sidecars.appendingPathComponent("\(identityMismatch.id.uuidString).json"),
            options: .atomic)
        let deletedReceipt = await remove(deleted.id, from: store)
        XCTAssertNil(deletedReceipt, "A permanent delete intentionally creates no Undo receipt.")
        XCTAssertFalse(store.hasConversation(deleted.id))

        for (conversation, expectedFailure) in [
            (missing, ConversationHydrationError.missing),
            (corrupt, ConversationHydrationError.unreadable),
            (deleted, ConversationHydrationError.deleted),
            (identityMismatch, ConversationHydrationError.identityMismatch),
        ] {
            let filename = ConversationMarkdownDocument.filename(for: conversation.title)
            let output = base.appendingPathComponent("output-\(conversation.id.uuidString).md")
            let promise = provider(for: conversation.id, filename: filename, store: store)
            let error = await fulfill(promise, at: output)

            XCTAssertEqual(
                error as? ConversationHydrationError,
                expectedFailure,
                "The Finder promise must preserve the exact hydration failure.")
            XCTAssertFalse(
                FileManager.default.fileExists(atPath: output.path),
                "\(expectedFailure) must not become an authoritative-looking empty export.")
        }
        XCTAssertEqual(store.synchronousHydrationCount, 0)
    }

    func testTwoProvidersKeepTheirIdentityAndDocumentsIndependent() async throws {
        let base = try makeBase()
        defer { try? FileManager.default.removeItem(at: base) }
        let first = conversation(title: "First promised row")
        let second = conversation(title: "Second promised row")
        try seed([first, second], at: base)
        let store = ConversationStore(
            appSupportBaseOverride: base,
            watchesDirectory: false,
            residencyMode: .boundedAfterRecovery)
        await awaitReady(store)
        store.trimResidencyIfNeeded(evictAllEligible: true)

        let fixtures = [first, second]
        let providers = fixtures.map {
            provider(
                for: $0.id,
                filename: ConversationMarkdownDocument.filename(for: $0.title),
                store: store)
        }
        XCTAssertEqual(
            providers.compactMap {
                $0.pasteboardPropertyList(
                    forType: NSPasteboard.PasteboardType.mechConversationRow) as? String
            },
            fixtures.map { $0.id.uuidString })

        let pasteboard = NSPasteboard(
            name: NSPasteboard.Name(
                "ai.mechanician.tests.outbound-multi-promise.\(UUID().uuidString)"))
        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.writeObjects(providers))
        XCTAssertEqual(
            pasteboard.pasteboardItems?.compactMap {
                $0.string(forType: NSPasteboard.PasteboardType.mechConversationRow)
            },
            fixtures.map { $0.id.uuidString })
        let receivers = pasteboard.readObjects(
            forClasses: [NSFilePromiseReceiver.self],
            options: nil) as? [NSFilePromiseReceiver]
        XCTAssertEqual(receivers?.count, fixtures.count)

        for (fixture, promise) in zip(fixtures, providers) {
            let expected = ConversationMarkdownDocument(conversation: fixture)
            let output = base.appendingPathComponent("result-\(expected.filename)")
            let error = await fulfill(promise, at: output)
            XCTAssertNil(error)
            XCTAssertEqual(try String(contentsOf: output, encoding: .utf8), expected.contents)
        }
        XCTAssertEqual(store.synchronousHydrationCount, 0)
        XCTAssertEqual(Set(store.hydrationDecodeCounts.values), [1])
    }

    func testPromiseUsesFirstDocumentResolutionAndCompletesOnce() async throws {
        let base = try makeBase()
        defer { try? FileManager.default.removeItem(at: base) }
        let first = ConversationMarkdownDocument(
            conversation: conversation(title: "First resolution"))
        let second = ConversationMarkdownDocument(
            conversation: conversation(title: "Second resolution"))
        let provider = ConversationMarkdownFilePromiseProvider(
            conversationID: UUID(),
            filename: first.filename,
            requestDocument: { _, completion in
                completion(.success(first))
                completion(.success(second))
            })
        let output = base.appendingPathComponent(first.filename)

        let error = await fulfill(provider, at: output)

        XCTAssertNil(error)
        XCTAssertEqual(try String(contentsOf: output, encoding: .utf8), first.contents)
    }

    func testMultipleFulfillmentsRunOneCompletePipelineAtATime() async throws {
        typealias Resolution = @MainActor (
            Result<ConversationMarkdownDocument, ConversationHydrationError>
        ) -> Void

        let base = try makeBase()
        defer { try? FileManager.default.removeItem(at: base) }
        let ids = [UUID(), UUID(), UUID()]
        let documents = Dictionary(uniqueKeysWithValues: ids.enumerated().map { index, id in
            (id, ConversationMarkdownDocument(
                conversation: conversation(title: "Bounded promise \(index)")))
        })
        var pending: [UUID: Resolution] = [:]
        var activeRequests = 0
        var maximumActiveRequests = 0
        var requestedIDs: Set<UUID> = []
        let providers = ids.map { id in
            ConversationMarkdownFilePromiseProvider(
                conversationID: id,
                filename: documents[id]!.filename,
                requestDocument: { requestedID, completion in
                    activeRequests += 1
                    maximumActiveRequests = max(maximumActiveRequests, activeRequests)
                    requestedIDs.insert(requestedID)
                    pending[requestedID] = { result in
                        activeRequests -= 1
                        completion(result)
                    }
                })
        }
        let tasks = providers.enumerated().map { index, provider in
            Task { @MainActor in
                await fulfill(
                    provider,
                    at: base.appendingPathComponent("bounded-\(index).md"))
            }
        }

        for _ in ids {
            await waitUntil("one active file-promise request") { pending.count == 1 }
            XCTAssertEqual(activeRequests, 1)
            XCTAssertEqual(maximumActiveRequests, 1)
            let id = try XCTUnwrap(pending.keys.first)
            let resolution = try XCTUnwrap(pending.removeValue(forKey: id))
            resolution(.success(try XCTUnwrap(documents[id])))
            await waitUntil("the active promise to finish") { activeRequests == 0 }
        }

        for task in tasks {
            let error = await task.value
            XCTAssertNil(error)
        }
        XCTAssertEqual(requestedIDs, Set(ids))
        XCTAssertEqual(maximumActiveRequests, 1)
    }

    func testAppKitInvocationQueueMayStayOccupiedUntilPromiseCompletes() async throws {
        let base = try makeBase()
        defer { try? FileManager.default.removeItem(at: base) }
        let document = ConversationMarkdownDocument(
            conversation: conversation(title: "No nested queue deadlock"))
        let provider = ConversationMarkdownFilePromiseProvider(
            conversationID: UUID(),
            filename: document.filename,
            requestDocument: { _, completion in completion(.success(document)) })
        let delegate = try XCTUnwrap(provider.delegate)
        let queue = delegate.operationQueue?(for: provider) ?? .main
        let output = base.appendingPathComponent(document.filename)
        let operationFinished = expectation(description: "promise operation returned")
        let probe = QueueProbe()
        let invocation = QueueInvocation(provider: provider, delegate: delegate)

        queue.addOperation {
            invocation.perform(
                output: output,
                probe: probe,
                finished: operationFinished)
        }

        await fulfillment(of: [operationFinished], timeout: 3)
        let (error, timedOut) = probe.snapshot()
        XCTAssertFalse(timedOut, "The destination write must not queue behind AppKit's invocation.")
        XCTAssertNil(error)
        XCTAssertEqual(try String(contentsOf: output, encoding: .utf8), document.contents)
    }

    func testFailedDestinationDoesNotWedgeTheNextPromise() async throws {
        let base = try makeBase()
        defer { try? FileManager.default.removeItem(at: base) }
        let failedDocument = ConversationMarkdownDocument(
            conversation: conversation(title: "Unavailable destination"))
        let succeedingDocument = ConversationMarkdownDocument(
            conversation: conversation(title: "Promise after failure"))
        let failedProvider = ConversationMarkdownFilePromiseProvider(
            conversationID: UUID(),
            filename: failedDocument.filename,
            requestDocument: { _, completion in completion(.success(failedDocument)) })
        let succeedingProvider = ConversationMarkdownFilePromiseProvider(
            conversationID: UUID(),
            filename: succeedingDocument.filename,
            requestDocument: { _, completion in completion(.success(succeedingDocument)) })
        let missingDirectory = base.appendingPathComponent(
            "destination-removed-before-write", isDirectory: true)
        let failedOutput = missingDirectory.appendingPathComponent(failedDocument.filename)
        let succeedingOutput = base.appendingPathComponent(succeedingDocument.filename)

        async let failedError = fulfill(failedProvider, at: failedOutput)
        async let succeedingError = fulfill(succeedingProvider, at: succeedingOutput)

        let results = await (failedError, succeedingError)
        XCTAssertNotNil(results.0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: failedOutput.path))
        XCTAssertNil(results.1, "A failed Finder destination must release the global scheduler.")
        XCTAssertEqual(
            try String(contentsOf: succeedingOutput, encoding: .utf8),
            succeedingDocument.contents)
    }
}
