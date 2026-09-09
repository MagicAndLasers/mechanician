import AppKit
import Foundation
import UniformTypeIdentifiers

/// A native Finder file promise that also carries Mechanician's private row identity. AppKit asks
/// for this object synchronously when a drag begins, so everything captured here is summary-sized;
/// the complete Conversation is requested only if a destination fulfills the promise.
@MainActor
final class ConversationMarkdownFilePromiseProvider: NSFilePromiseProvider {
    typealias DocumentRequest = @MainActor (
        UUID,
        @escaping @MainActor (
            Result<ConversationMarkdownDocument, ConversationHydrationError>
        ) -> Void
    ) -> Void

    let conversationID: UUID
    private let retainedPromiseDelegate: ConversationMarkdownFilePromiseDelegate

    init(
        conversationID: UUID,
        filename: String,
        requestDocument: @escaping DocumentRequest
    ) {
        self.conversationID = conversationID
        let promiseDelegate = ConversationMarkdownFilePromiseDelegate(
            conversationID: conversationID,
            filename: filename,
            requestDocument: requestDocument)
        retainedPromiseDelegate = promiseDelegate
        // `init(fileType:delegate:)` is an Objective-C convenience initializer. Calling it from a
        // subclass dynamically re-enters `init()` and crashes. Enter through the designated
        // initializer, then configure the provider explicitly.
        super.init()
        fileType = UTType(filenameExtension: "md")?.identifier ?? UTType.plainText.identifier
        delegate = promiseDelegate
    }

    @available(*, unavailable, message: "Use init(conversationID:filename:requestDocument:)")
    override init() {
        fatalError("Use init(conversationID:filename:requestDocument:)")
    }

    /// Internal reorder, cross-Workspace filing, and drag-to-Trash all resolve the UUID from this
    /// private type. A file promise must add to that contract, never replace it.
    override func writableTypes(for pasteboard: NSPasteboard) -> [NSPasteboard.PasteboardType] {
        let inherited = super.writableTypes(for: pasteboard)
        guard !inherited.contains(.mechConversationRow) else { return inherited }
        return [.mechConversationRow] + inherited
    }

    override func pasteboardPropertyList(
        forType type: NSPasteboard.PasteboardType
    ) -> Any? {
        if type == .mechConversationRow { return conversationID.uuidString }
        return super.pasteboardPropertyList(forType: type)
    }

    override func writingOptions(
        forType type: NSPasteboard.PasteboardType,
        pasteboard: NSPasteboard
    ) -> NSPasteboard.WritingOptions {
        if type == .mechConversationRow { return [] }
        return super.writingOptions(forType: type, pasteboard: pasteboard)
    }
}

/// AppKit invokes promise writes on this delegate's operation queue. Hydration enters the main-
/// actor ConversationStore only long enough to acquire an immutable snapshot; Markdown rendering
/// and the destination write both stay off the main thread.
private final class ConversationMarkdownFilePromiseDelegate:
    NSObject,
    NSFilePromiseProviderDelegate,
    @unchecked Sendable
{
    private let conversationID: UUID
    private let filename: String
    private let requestDocument: ConversationMarkdownFilePromiseProvider.DocumentRequest

    init(
        conversationID: UUID,
        filename: String,
        requestDocument: @escaping ConversationMarkdownFilePromiseProvider.DocumentRequest
    ) {
        self.conversationID = conversationID
        self.filename = filename
        self.requestDocument = requestDocument
    }

    @MainActor
    func filePromiseProvider(
        _ filePromiseProvider: NSFilePromiseProvider,
        fileNameForType fileType: String
    ) -> String {
        filename
    }

    @MainActor
    func operationQueue(
        for filePromiseProvider: NSFilePromiseProvider
    ) -> OperationQueue {
        ConversationMarkdownFilePromiseScheduler.shared.operationQueue
    }

    nonisolated func filePromiseProvider(
        _ filePromiseProvider: NSFilePromiseProvider,
        writePromiseTo url: URL,
        completionHandler: @escaping (Error?) -> Void
    ) {
        let completion = FilePromiseCompletion(completionHandler)
        Task { @MainActor [conversationID, requestDocument] in
            ConversationMarkdownFilePromiseScheduler.shared.enqueue(
                conversationID: conversationID,
                destinationURL: url,
                requestDocument: requestDocument,
                completion: completion)
        }
    }
}

/// Bound the complete promise pipeline, not only its individual queues. Finder may call in every
/// selected row at once; starting all hydrations before the serial renderer catches up would retain
/// a corpus-sized stack of full Conversation snapshots. One job owns hydrate → render → write at a
/// time, while queued jobs retain only ids, URLs, and small closures.
@MainActor
private final class ConversationMarkdownFilePromiseScheduler {
    static let shared = ConversationMarkdownFilePromiseScheduler()

    /// AppKit may keep the operation that invokes `writePromiseTo` alive until its completion
    /// handler fires. Never queue the destination write behind that operation on this same serial
    /// queue or a real Finder fulfillment can deadlock.
    fileprivate let operationQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "ai.mechanician.conversation-file-promise-invocation"
        queue.qualityOfService = .userInitiated
        queue.maxConcurrentOperationCount = 1
        return queue
    }()

    private let destinationWriteQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "ai.mechanician.conversation-file-promise-write"
        queue.qualityOfService = .userInitiated
        queue.maxConcurrentOperationCount = 1
        return queue
    }()

    private struct Job {
        let conversationID: UUID
        let destinationURL: URL
        let requestDocument: ConversationMarkdownFilePromiseProvider.DocumentRequest
        let completion: FilePromiseCompletion
    }

    private var pending: [Job] = []
    private var isRunning = false

    func enqueue(
        conversationID: UUID,
        destinationURL: URL,
        requestDocument: @escaping ConversationMarkdownFilePromiseProvider.DocumentRequest,
        completion: FilePromiseCompletion
    ) {
        pending.append(Job(
            conversationID: conversationID,
            destinationURL: destinationURL,
            requestDocument: requestDocument,
            completion: completion))
        startNextIfNeeded()
    }

    private func startNextIfNeeded() {
        guard !isRunning, !pending.isEmpty else { return }
        isRunning = true
        let job = pending.removeFirst()
        job.requestDocument(job.conversationID) { result in
            // A request contract is exactly-once, but claim the resolution before any write so a
            // buggy future implementation cannot schedule two writes or complete AppKit twice.
            guard job.completion.claimResolution() else { return }
            self.destinationWriteQueue.addOperation {
                let error: Error?
                do {
                    let document = try result.get()
                    try ConversationMarkdownExport.write(document, to: job.destinationURL)
                    error = nil
                } catch let caught {
                    error = caught
                }
                job.completion.finish(error)
                Task { @MainActor in
                    ConversationMarkdownFilePromiseScheduler.shared.finishCurrentJob()
                }
            }
        }
    }

    private func finishCurrentJob() {
        isRunning = false
        startNextIfNeeded()
    }
}

/// Defensive exactly-once resolution and delivery for a system callback whose destination may
/// disappear while the Conversation hydrates.
private final class FilePromiseCompletion: @unchecked Sendable {
    private let lock = NSLock()
    private var didClaimResolution = false
    private var didFinish = false
    private let handler: (Error?) -> Void

    init(_ handler: @escaping (Error?) -> Void) {
        self.handler = handler
    }

    func claimResolution() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !didClaimResolution else { return false }
        didClaimResolution = true
        return true
    }

    func finish(_ error: Error?) {
        lock.lock()
        guard didClaimResolution, !didFinish else {
            lock.unlock()
            return
        }
        didFinish = true
        lock.unlock()
        handler(error)
    }
}
