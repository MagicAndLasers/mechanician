import AppKit
import Foundation
import XCTest
@testable import Mechanician

final class ConversationFilePromiseMaterializerTests: XCTestCase {
    private final class FakeReceiver: ConversationFilePromiseReceiving {
        struct Emission {
            let name: String
            let data: Data
            let delay: TimeInterval
            let error: Error?
            let escapesDestination: Bool
        }

        let promisedFileTypes: [String]
        private(set) var promisedFileNames: [String] = []
        let emissions: [Emission]
        let escapedRoot: URL?

        init(
            fileTypes: [String],
            emissions: [Emission],
            escapedRoot: URL? = nil
        ) {
            promisedFileTypes = fileTypes
            self.emissions = emissions
            self.escapedRoot = escapedRoot
        }

        func receivePromisedFiles(
            at destinationDirectory: URL,
            operationQueue: OperationQueue,
            reader: @escaping (URL, Error?) -> Void
        ) {
            promisedFileNames = emissions.map(\.name)
            for emission in emissions {
                operationQueue.addOperation {
                    if emission.delay > 0 { Thread.sleep(forTimeInterval: emission.delay) }
                    let parent = emission.escapesDestination
                        ? (self.escapedRoot ?? destinationDirectory.deletingLastPathComponent())
                        : destinationDirectory
                    let url = parent.appendingPathComponent(emission.name)
                    if emission.error == nil {
                        try? emission.data.write(to: url, options: .atomic)
                    }
                    reader(url, emission.error)
                }
            }
        }
    }

    private struct FixtureError: LocalizedError {
        let errorDescription: String?
    }

    private final class DeferredQueueReceiver: ConversationFilePromiseReceiving {
        let promisedFileTypes = ["public.email-message"]
        let promisedFileNames = ["Deferred.eml"]

        func receivePromisedFiles(
            at destinationDirectory: URL,
            operationQueue: OperationQueue,
            reader: @escaping (URL, Error?) -> Void
        ) {
            let url = destinationDirectory.appendingPathComponent(promisedFileNames[0])
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.02) {
                [weak operationQueue] in
                guard let operationQueue else {
                    reader(
                        url,
                        FixtureError(
                            errorDescription: "operation queue was released too early"))
                    return
                }
                operationQueue.addOperation {
                    try? Data("deferred".utf8).write(to: url)
                    reader(url, nil)
                }
            }
        }
    }

    private final class LateLegacyNamesReceiver:
        ConversationFilePromiseReceiving, @unchecked Sendable
    {
        let promisedFileTypes = ["public.email-message"]
        private let lock = NSLock()
        private var names: [String] = []
        var promisedFileNames: [String] {
            lock.withLock { names }
        }

        func receivePromisedFiles(
            at destinationDirectory: URL,
            operationQueue: OperationQueue,
            reader: @escaping (URL, Error?) -> Void
        ) {
            operationQueue.addOperation {
                self.lock.withLock {
                    self.names = ["Legacy First.eml", "Legacy Second.eml"]
                }
                for name in self.promisedFileNames {
                    let url = destinationDirectory.appendingPathComponent(name)
                    try? Data(name.utf8).write(to: url)
                    reader(url, nil)
                    Thread.sleep(forTimeInterval: 0.01)
                }
            }
        }
    }

    private final class LateIgnoringCancellationReceiver:
        ConversationFilePromiseReceiving, @unchecked Sendable
    {
        let promisedFileTypes = ["public.email-message"]
        let promisedFileNames = ["Late.eml"]
        private let lock = NSLock()
        private var _destination: URL?
        private var _operation: Operation?
        private var _didCallback = false
        private let started = DispatchSemaphore(value: 0)
        private let release = DispatchSemaphore(value: 0)

        var destination: URL? { lock.withLock { _destination } }
        var operation: Operation? { lock.withLock { _operation } }
        var didCallback: Bool { lock.withLock { _didCallback } }

        /// The operation must still be executing when the materializer's timeout cancels the
        /// queue, or `isCancelled` is meaningless. Blocking beats sleeping: a fixed 0.12 s sleep
        /// raced a 0.05 s timeout, and on a loaded CI runner the block finished first, so
        /// `cancelAllOperations` had nothing left to cancel and the assertion failed.
        @discardableResult
        func waitUntilWriting() -> Bool { started.wait(timeout: .now() + 5) == .success }

        func releaseWrite() { release.signal() }

        func receivePromisedFiles(
            at destinationDirectory: URL,
            operationQueue: OperationQueue,
            reader: @escaping (URL, Error?) -> Void
        ) {
            let url = destinationDirectory.appendingPathComponent(promisedFileNames[0])
            let operation = BlockOperation { [started, release] in
                // Intentionally ignore cancellation to model a provider already inside its write.
                started.signal()
                _ = release.wait(timeout: .now() + 10)
                try? FileManager.default.createDirectory(
                    at: destinationDirectory,
                    withIntermediateDirectories: true)
                try? Data("late".utf8).write(to: url)
                reader(url, nil)
                self.lock.withLock { self._didCallback = true }
            }
            lock.withLock {
                _destination = destinationDirectory
                _operation = operation
            }
            operationQueue.addOperation(operation)
        }
    }

    @MainActor
    func testConcurrentPromisesReturnInReceiverAndPromisedFilenameOrder() async throws {
        let first = FakeReceiver(
            fileTypes: ["public.email-message", "public.email-message"],
            emissions: [
                .init(
                    name: "First.eml",
                    data: Data("first".utf8),
                    delay: 0.04,
                    error: nil,
                    escapesDestination: false),
                .init(
                    name: "Second.eml",
                    data: Data("second".utf8),
                    delay: 0,
                    error: nil,
                    escapesDestination: false),
            ])
        let second = FakeReceiver(
            fileTypes: ["public.email-message"],
            emissions: [
                .init(
                    name: "Third.eml",
                    data: Data("third".utf8),
                    delay: 0.01,
                    error: nil,
                    escapesDestination: false),
            ])

        let outcomes = await materialize([first, second])
        let names = try outcomes.map {
            try $0.result.get().lastPathComponent
        }

        XCTAssertEqual(names, ["First.eml", "Second.eml", "Third.eml"])
        XCTAssertEqual(outcomes.map(\.receiverIndex), [0, 0, 1])
        XCTAssertEqual(outcomes.map(\.fileIndex), [0, 1, 0])
    }

    @MainActor
    func testEscapedPromiseURLAndProducerFailureAreHonestFailures() async throws {
        let escapedRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("MechanicianPromiseEscape-\(UUID().uuidString)",
                                    isDirectory: true)
        try FileManager.default.createDirectory(at: escapedRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: escapedRoot) }
        let receiver = FakeReceiver(
            fileTypes: ["public.email-message", "public.email-message"],
            emissions: [
                .init(
                    name: "Escaped.eml",
                    data: Data("outside".utf8),
                    delay: 0,
                    error: nil,
                    escapesDestination: true),
                .init(
                    name: "Failed.eml",
                    data: Data(),
                    delay: 0,
                    error: FixtureError(errorDescription: "fixture refusal"),
                    escapesDestination: false),
            ],
            escapedRoot: escapedRoot)

        let outcomes = await materialize([receiver])

        XCTAssertEqual(outcomes.count, 2)
        XCTAssertThrowsError(try outcomes[0].result.get()) {
            XCTAssertTrue($0.localizedDescription.contains("outside"))
        }
        XCTAssertThrowsError(try outcomes[1].result.get()) {
            XCTAssertTrue($0.localizedDescription.contains("could not provide"))
            XCTAssertFalse(
                $0.localizedDescription.contains("fixture refusal"),
                "Provider-controlled failure text must not cross into the user prompt boundary.")
        }
    }

    @MainActor
    func testUnfulfilledPromiseTimesOutOnce() async {
        let receiver = FakeReceiver(
            fileTypes: ["public.email-message"],
            emissions: [])

        let outcomes = await materialize([receiver], timeout: 0.05)

        XCTAssertEqual(outcomes.count, 1)
        XCTAssertThrowsError(try outcomes[0].result.get()) {
            XCTAssertTrue($0.localizedDescription.contains("in time"))
        }
    }

    @MainActor
    func testTimeoutCancelsQueueAndLateCallbackCannotLeaveStagingBytes() async {
        let receiver = LateIgnoringCancellationReceiver()

        let outcomes = await materialize([receiver], timeout: 0.05)

        XCTAssertEqual(outcomes.count, 1)
        XCTAssertTrue(
            receiver.waitUntilWriting(),
            "the provider operation must be executing before the timeout cancels its queue")
        XCTAssertTrue(receiver.operation?.isCancelled == true)
        receiver.releaseWrite()
        let deadline = Date().addingTimeInterval(5)
        while !receiver.didCallback, Date() < deadline {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertTrue(receiver.didCallback)
        if let destination = receiver.destination {
            XCTAssertFalse(
                FileManager.default.fileExists(atPath: destination.path),
                "A provider that reports after timeout must not recreate its staging directory.")
        }
    }

    @MainActor
    func testOperationQueueLivesUntilADeferredProducerSchedulesItsWork() async throws {
        let outcomes = await materialize([DeferredQueueReceiver()])

        XCTAssertEqual(outcomes.count, 1)
        let url = try outcomes[0].result.get()
        XCTAssertEqual(url.lastPathComponent, "Deferred.eml")
    }

    @MainActor
    func testLegacyReceiverCanPublishMultipleNamesWithItsFirstCallback() async throws {
        let outcomes = await materialize([LateLegacyNamesReceiver()])

        XCTAssertEqual(
            try outcomes.map { try $0.result.get().lastPathComponent },
            ["Legacy First.eml", "Legacy Second.eml"])
        XCTAssertEqual(outcomes.map(\.fileIndex), [0, 1])
    }

    @MainActor
    func testRegistersOnlyAppKitProvenPromiseTypes() {
        XCTAssertEqual(
            ConversationFilePromiseMaterializer.readablePasteboardTypes.map(\.rawValue),
            NSFilePromiseReceiver.readableDraggedTypes)
        XCTAssertFalse(
            ConversationFilePromiseMaterializer.readablePasteboardTypes.contains {
                $0.rawValue.lowercased().contains("mail")
            },
            "The generic promise adapter must stay AppKit-only; Mail's observed non-promise "
                + "contract is handled by MailMessageDragReceiver.")
    }

    @MainActor
    private func materialize(
        _ receivers: [ConversationFilePromiseReceiving],
        timeout: TimeInterval = 1
    ) async -> [ConversationFilePromiseOutcome] {
        await withCheckedContinuation { continuation in
            ConversationFilePromiseMaterializer.materialize(
                receivers,
                timeout: timeout
            ) {
                continuation.resume(returning: $0)
            }
        }
    }
}
