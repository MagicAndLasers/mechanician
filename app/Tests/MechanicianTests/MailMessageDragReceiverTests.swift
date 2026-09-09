import AppKit
import Foundation
import XCTest
@testable import Mechanician

final class MailMessageDragReceiverTests: XCTestCase {
    private final class FakeExporter: MailMessageSourceExporting, @unchecked Sendable {
        let value: String
        private(set) var descriptor: MailMessageDragReceiver.Descriptor?

        init(value: String) {
            self.value = value
        }

        func source(
            for descriptor: MailMessageDragReceiver.Descriptor
        ) throws -> String {
            self.descriptor = descriptor
            return value
        }
    }

    func testObservedMailPasteboardContractProducesBoundedMessageIdentity() throws {
        let pasteboard = NSPasteboard(
            name: NSPasteboard.Name("MailMessageDragReceiverTests-\(UUID())"))
        pasteboard.clearContents()
        pasteboard.setString(
            "/Users/example/Library/Mail/V10/account/Mailbox.mbox",
            forType: MailMessageDragReceiver.messageTransferType)
        let automator = try PropertyListSerialization.data(
            fromPropertyList: [[
                "id": 1024348,
                "subject": "Quarterly update",
                "mailbox": "All Mail",
                "account": "Example",
            ]],
            format: .binary,
            options: 0)
        pasteboard.setData(automator, forType: MailMessageDragReceiver.automatorType)
        pasteboard.setString(
            "message:%3Cmessage-id@example.test%3E",
            forType: NSPasteboard.PasteboardType("public.url"))

        let descriptor = try XCTUnwrap(
            MailMessageDragReceiver.descriptors(from: pasteboard).first)

        XCTAssertEqual(descriptor.id, 1024348)
        XCTAssertEqual(descriptor.subject, "Quarterly update")
        XCTAssertEqual(descriptor.account, "Example")
        XCTAssertEqual(descriptor.mailbox, "All Mail")
        XCTAssertEqual(descriptor.messageID, "message-id@example.test")
        XCTAssertTrue(MailMessageDragReceiver.canRead(from: pasteboard))
        XCTAssertEqual(
            MailMessageDragReceiver.receivers(from: pasteboard).first?.promisedFileNames,
            ["Quarterly update.eml"])
    }

    func testRejectsSubjectOnlyFallbackAndMalformedAutomatorPayload() {
        let pasteboard = NSPasteboard(
            name: NSPasteboard.Name("MailMessageDragReceiverTests-\(UUID())"))
        pasteboard.clearContents()
        pasteboard.setString(
            "A subject is not an email body",
            forType: .string)
        XCTAssertFalse(MailMessageDragReceiver.canRead(from: pasteboard))

        pasteboard.setString(
            "mailbox path",
            forType: MailMessageDragReceiver.messageTransferType)
        pasteboard.setData(
            Data("not a plist".utf8),
            forType: MailMessageDragReceiver.automatorType)
        XCTAssertFalse(MailMessageDragReceiver.canRead(from: pasteboard))
    }

    func testReceiverMaterializesRFC822SourceAsNamedEML() throws {
        let descriptor = MailMessageDragReceiver.Descriptor(
            id: 42,
            subject: "Status / details",
            account: "Example",
            mailbox: "Inbox",
            messageID: "id@example.test")
        let source = """
        From: sender@example.test\r
        Subject: Status / details\r
        Content-Type: text/plain; charset=utf-8\r
        \r
        This is the complete body.\r
        """
        let exporter = FakeExporter(value: source)
        let receiver = MailMessageDragReceiver(
            descriptor: descriptor,
            exporter: exporter)
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "MailMessageDragReceiverTests-\(UUID())",
                isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }

        let completed = expectation(description: "message exported")
        let queue = OperationQueue()
        var result: Result<URL, Error>?
        receiver.receivePromisedFiles(
            at: directory,
            operationQueue: queue
        ) { url, error in
            result = error.map(Result.failure) ?? .success(url)
            completed.fulfill()
        }
        // Mail clears its scripting `selection` when the drop returns, so source capture must
        // happen synchronously even though file validation and writing remain queued.
        XCTAssertEqual(exporter.descriptor, descriptor)
        wait(for: [completed], timeout: 2)

        let url = try XCTUnwrap(result).get()
        XCTAssertEqual(url.lastPathComponent, "Status _ details.eml")
        XCTAssertEqual(url.deletingLastPathComponent(), directory)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), source)
    }
}
