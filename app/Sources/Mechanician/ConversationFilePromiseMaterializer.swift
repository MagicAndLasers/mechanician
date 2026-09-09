import AppKit
import Foundation

/// Testable adapter around AppKit's public promised-file receiver. We deliberately do not register
/// Mail-private pasteboard type strings: `NSFilePromiseReceiver.readableDraggedTypes` is Apple's
/// source of truth for item-based and legacy/non-item-based file promises.
protocol ConversationFilePromiseReceiving: AnyObject {
    var promisedFileTypes: [String] { get }
    var promisedFileNames: [String] { get }

    func receivePromisedFiles(
        at destinationDirectory: URL,
        operationQueue: OperationQueue,
        reader: @escaping (URL, Error?) -> Void)
}

extension NSFilePromiseReceiver: ConversationFilePromiseReceiving {
    var promisedFileTypes: [String] { fileTypes }
    var promisedFileNames: [String] { fileNames }

    func receivePromisedFiles(
        at destinationDirectory: URL,
        operationQueue: OperationQueue,
        reader: @escaping (URL, Error?) -> Void
    ) {
        receivePromisedFiles(
            atDestination: destinationDirectory,
            options: [:],
            operationQueue: operationQueue,
            reader: reader)
    }
}

enum ConversationFilePromiseMaterializationError: LocalizedError {
    case couldNotCreateStagingDirectory
    case producerFailed
    case escapedStagingDirectory
    case invalidPromisedFile
    case timedOut

    var errorDescription: String? {
        switch self {
        case .couldNotCreateStagingDirectory:
            return "Mechanician could not create a safe staging folder for the promised file."
        case .producerFailed:
            // A promise provider controls its NSError text. Keep that untrusted, potentially huge
            // string out of the user's editable/submittable prompt.
            return "The source app could not provide the promised file."
        case .escapedStagingDirectory:
            return "The source app returned a file outside Mechanician’s staging folder."
        case .invalidPromisedFile:
            return "The source app did not provide a regular promised file."
        case .timedOut:
            return "The source app did not finish providing the promised file in time."
        }
    }
}

struct ConversationFilePromiseOutcome {
    let receiverIndex: Int
    let fileIndex: Int
    let suggestedFileName: String?
    let result: Result<URL, Error>
}

enum ConversationFilePromiseMaterializer {
    static var readablePasteboardTypes: [NSPasteboard.PasteboardType] {
        NSFilePromiseReceiver.readableDraggedTypes.map {
            NSPasteboard.PasteboardType($0)
        }
    }

    static func receivers(from pasteboard: NSPasteboard) -> [NSFilePromiseReceiver] {
        (pasteboard.readObjects(
            forClasses: [NSFilePromiseReceiver.self],
            options: nil) as? [NSFilePromiseReceiver]) ?? []
    }

    /// Materialize every receiver into one private staging directory, as required by AppKit. Results
    /// are returned in receiver order and then promised-filename order even when producers complete
    /// concurrently. The completion executes on the main actor; staging bytes remain available for
    /// that synchronous callback and are removed immediately afterward.
    @MainActor
    static func materialize(
        _ receivers: [ConversationFilePromiseReceiving],
        timeout: TimeInterval = 30,
        fileManager: FileManager = .default,
        completion: @escaping @MainActor ([ConversationFilePromiseOutcome]) -> Void
    ) {
        guard !receivers.isEmpty else {
            completion([])
            return
        }
        let staging = fileManager.temporaryDirectory
            .appendingPathComponent(
                "mechanician-promised-files-\(UUID().uuidString)",
                isDirectory: true)
        do {
            try fileManager.createDirectory(
                at: staging,
                withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700])
        } catch {
            completion(receivers.enumerated().map {
                ConversationFilePromiseOutcome(
                    receiverIndex: $0.offset,
                    fileIndex: 0,
                    suggestedFileName: nil,
                    result: .failure(
                        ConversationFilePromiseMaterializationError
                            .couldNotCreateStagingDirectory))
            })
            return
        }

        let operationQueue = OperationQueue()
        operationQueue.name = "ai.mechanician.file-promise"
        operationQueue.qualityOfService = .userInitiated
        operationQueue.maxConcurrentOperationCount = 2
        let state = State(
            receivers: receivers,
            staging: staging,
            fileManager: fileManager,
            operationQueue: operationQueue,
            completion: completion)

        for (receiverIndex, receiver) in receivers.enumerated() {
            receiver.receivePromisedFiles(
                at: staging,
                operationQueue: operationQueue
            ) { url, error in
                state.receive(
                    receiverIndex: receiverIndex,
                    receiver: receiver,
                    url: url,
                    error: error)
            }
            state.markReceiveCalled(
                receiverIndex: receiverIndex,
                receiver: receiver)
        }
        state.markAllReceiversCalled()

        let boundedTimeout = min(max(timeout, 0.05), 120)
        DispatchQueue.main.asyncAfter(deadline: .now() + boundedTimeout) {
            state.timeout()
        }
    }

    private final class State: @unchecked Sendable {
        private struct IndexedOutcome {
            let promisedIndex: Int
            let sequence: Int
            let outcome: ConversationFilePromiseOutcome
        }

        private let lock = NSLock()
        private var receivers: [ConversationFilePromiseReceiving]
        private let staging: URL
        private let fileManager: FileManager
        /// `NSFilePromiseReceiver` may enqueue work after `receivePromisedFiles` returns. Keep its
        /// queue alive for the entire materialization instead of relying on undocumented retention.
        private let operationQueue: OperationQueue
        private let completion: @MainActor ([ConversationFilePromiseOutcome]) -> Void
        private var buckets: [[IndexedOutcome]]
        private var expectedCounts: [Int]
        private var receiveCalled: [Bool]
        private var allReceiversCalled = false
        private var didFinish = false
        private var deliveryFinished = false

        init(
            receivers: [ConversationFilePromiseReceiving],
            staging: URL,
            fileManager: FileManager,
            operationQueue: OperationQueue,
            completion: @escaping @MainActor ([ConversationFilePromiseOutcome]) -> Void
        ) {
            self.receivers = receivers
            self.staging = staging
            self.fileManager = fileManager
            self.operationQueue = operationQueue
            self.completion = completion
            buckets = Array(repeating: [], count: receivers.count)
            expectedCounts = receivers.map { max($0.promisedFileTypes.count, 1) }
            receiveCalled = Array(repeating: false, count: receivers.count)
        }

        func markReceiveCalled(
            receiverIndex: Int,
            receiver: ConversationFilePromiseReceiving
        ) {
            lock.lock()
            guard !didFinish, expectedCounts.indices.contains(receiverIndex) else {
                lock.unlock()
                return
            }
            receiveCalled[receiverIndex] = true
            // Legacy receivers learn their exact filenames only after the promise is called in.
            expectedCounts[receiverIndex] = max(
                receiver.promisedFileNames.count,
                receiver.promisedFileTypes.count,
                buckets[receiverIndex].count,
                1)
            let finished = finishIfReadyLocked()
            lock.unlock()
            deliver(finished)
        }

        func markAllReceiversCalled() {
            lock.lock()
            guard !didFinish else {
                lock.unlock()
                return
            }
            allReceiversCalled = true
            let finished = finishIfReadyLocked()
            lock.unlock()
            deliver(finished)
        }

        func receive(
            receiverIndex: Int,
            receiver: ConversationFilePromiseReceiving,
            url: URL,
            error: Error?
        ) {
            lock.lock()
            guard !didFinish, buckets.indices.contains(receiverIndex) else {
                let shouldCleanLateBytes = didFinish && deliveryFinished
                lock.unlock()
                if shouldCleanLateBytes { removeStagingDirectory() }
                return
            }
            let sequence = buckets[receiverIndex].count
            let names = receiver.promisedFileNames
            // Some legacy/non-item receivers publish the complete fileNames list only when their
            // first callback arrives. Grow (never shrink) the expected count before deciding this
            // receiver is complete, or a multi-message Mail drag can finish after its first file.
            expectedCounts[receiverIndex] = max(
                expectedCounts[receiverIndex],
                names.count,
                buckets[receiverIndex].count + 1)
            let promisedIndex = names.firstIndex(of: url.lastPathComponent) ?? sequence
            let suggestedName = names.indices.contains(promisedIndex)
                ? names[promisedIndex]
                : (url.lastPathComponent.isEmpty ? nil : url.lastPathComponent)
            let result: Result<URL, Error>
            if error != nil {
                result = .failure(
                    ConversationFilePromiseMaterializationError
                        .producerFailed)
            } else if url.standardizedFileURL.deletingLastPathComponent()
                != staging.standardizedFileURL {
                result = .failure(
                    ConversationFilePromiseMaterializationError
                        .escapedStagingDirectory)
            } else if let values = try? url.resourceValues(
                forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
                      values.isRegularFile == true,
                      values.isSymbolicLink != true {
                result = .success(url.standardizedFileURL)
            } else {
                result = .failure(
                    ConversationFilePromiseMaterializationError
                        .invalidPromisedFile)
            }
            buckets[receiverIndex].append(IndexedOutcome(
                promisedIndex: promisedIndex,
                sequence: sequence,
                outcome: ConversationFilePromiseOutcome(
                    receiverIndex: receiverIndex,
                    fileIndex: promisedIndex,
                    suggestedFileName: suggestedName,
                    result: result)))
            let finished = finishIfReadyLocked()
            lock.unlock()
            deliver(finished)
        }

        func timeout() {
            lock.lock()
            guard !didFinish else {
                lock.unlock()
                return
            }
            for receiverIndex in buckets.indices {
                let existingIndexes = Set(
                    buckets[receiverIndex].map(\.promisedIndex))
                let missingIndexes = (0..<expectedCounts[receiverIndex]).filter {
                    !existingIndexes.contains($0)
                }
                for fileIndex in missingIndexes {
                    let names = receivers[receiverIndex].promisedFileNames
                    let suggestedName = names.indices.contains(fileIndex)
                        ? names[fileIndex]
                        : nil
                    buckets[receiverIndex].append(IndexedOutcome(
                        promisedIndex: fileIndex,
                        sequence: buckets[receiverIndex].count,
                        outcome: ConversationFilePromiseOutcome(
                            receiverIndex: receiverIndex,
                            fileIndex: fileIndex,
                            suggestedFileName: suggestedName,
                            result: .failure(
                                ConversationFilePromiseMaterializationError.timedOut))))
                }
            }
            let finished = finishLocked()
            lock.unlock()
            if finished != nil {
                // Cancellation is advisory for already-running provider work, but it prevents queued
                // work from continuing after the user-visible timeout. A late callback is ignored
                // and re-runs staging cleanup once delivery no longer needs those bytes.
                operationQueue.cancelAllOperations()
            }
            deliver(finished)
        }

        private func finishIfReadyLocked() -> [ConversationFilePromiseOutcome]? {
            guard allReceiversCalled,
                  receiveCalled.allSatisfy({ $0 }),
                  buckets.indices.allSatisfy({
                      buckets[$0].count >= expectedCounts[$0]
                  }) else { return nil }
            return finishLocked()
        }

        private func finishLocked() -> [ConversationFilePromiseOutcome]? {
            guard !didFinish else { return nil }
            didFinish = true
            let outcomes = buckets.enumerated().flatMap { receiverIndex, bucket in
                bucket.sorted {
                    if $0.promisedIndex != $1.promisedIndex {
                        return $0.promisedIndex < $1.promisedIndex
                    }
                    return $0.sequence < $1.sequence
                }
                .enumerated()
                .map { fileIndex, indexed in
                    ConversationFilePromiseOutcome(
                        receiverIndex: receiverIndex,
                        fileIndex: fileIndex,
                        suggestedFileName: indexed.outcome.suggestedFileName,
                        result: indexed.outcome.result)
                }
            }
            // A hung receiver may retain its reader block. Do not make that a State ↔ receiver cycle
            // after success or timeout; callbacks already carry the receiver they need for names.
            receivers.removeAll()
            return outcomes
        }

        private func deliver(_ outcomes: [ConversationFilePromiseOutcome]?) {
            guard let outcomes else { return }
            Task { @MainActor in
                completion(outcomes)
                finishDelivery()
            }
        }

        private func finishDelivery() {
            lock.lock()
            deliveryFinished = true
            lock.unlock()
            removeStagingDirectory()
        }

        private func removeStagingDirectory() {
            try? fileManager.removeItem(at: staging)
        }
    }
}
