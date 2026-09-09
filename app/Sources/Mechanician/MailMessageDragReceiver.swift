import AppKit
import Foundation

/// Apple Mail does not expose dragged messages as `NSFilePromiseReceiver` objects on macOS 26.
/// Its public fallback is only a `message:` URL plus the subject, while these two Mail-owned
/// representations identify the selected message. Resolve that identity through Mail's public
/// scripting dictionary and feed the resulting RFC 822 source through the ordinary promised-file
/// intake, so the composer remains responsive and every existing size/ownership check still applies.
final class MailMessageDragReceiver: ConversationFilePromiseReceiving {
    static let messageTransferType = NSPasteboard.PasteboardType(
        "com.apple.mail.PasteboardTypeMessageTransfer")
    static let automatorType = NSPasteboard.PasteboardType(
        "com.apple.mail.PasteboardTypeAutomator")
    static let readablePasteboardTypes = [messageTransferType, automatorType]

    struct Descriptor: Equatable {
        let id: Int
        let subject: String
        let account: String?
        let mailbox: String?
        let messageID: String?
    }

    private let descriptor: Descriptor
    private let exporter: any MailMessageSourceExporting

    var promisedFileTypes: [String] { ["public.email-message"] }
    var promisedFileNames: [String] { [Self.fileName(for: descriptor)] }

    init(
        descriptor: Descriptor,
        exporter: any MailMessageSourceExporting = AppleScriptMailMessageSourceExporter()
    ) {
        self.descriptor = descriptor
        self.exporter = exporter
    }

    static func canRead(from pasteboard: NSPasteboard) -> Bool {
        !descriptors(from: pasteboard).isEmpty
    }

    static func receivers(from pasteboard: NSPasteboard) -> [MailMessageDragReceiver] {
        descriptors(from: pasteboard)
            .prefix(ConversationAttachmentImportBudget.maximumFiles)
            .map { MailMessageDragReceiver(descriptor: $0) }
    }

    static func descriptors(from pasteboard: NSPasteboard) -> [Descriptor] {
        guard pasteboard.availableType(from: readablePasteboardTypes) != nil,
              pasteboard.data(forType: messageTransferType) != nil,
              let data = pasteboard.data(forType: automatorType),
              data.count <= 256 * 1024,
              let value = try? PropertyListSerialization.propertyList(
                  from: data,
                  options: [],
                  format: nil),
              let records = value as? [[String: Any]],
              !records.isEmpty,
              records.count <= 32 else { return [] }

        let publicMessageID = messageID(from: pasteboard)
        return records.compactMap { record in
            let id: Int?
            if let number = record["id"] as? NSNumber {
                id = number.intValue
            } else {
                id = record["id"] as? Int
            }
            guard let id, id > 0,
                  let rawSubject = record["subject"] as? String else { return nil }
            let subject = boundedSingleLine(rawSubject)
            guard !subject.isEmpty else { return nil }
            return Descriptor(
                id: id,
                subject: subject,
                account: boundedOptional(record["account"] as? String),
                mailbox: boundedOptional(record["mailbox"] as? String),
                messageID: records.count == 1 ? publicMessageID : nil)
        }
    }

    func receivePromisedFiles(
        at destinationDirectory: URL,
        operationQueue: OperationQueue,
        reader: @escaping (URL, Error?) -> Void
    ) {
        let descriptor = descriptor
        // Mail clears `selection` as soon as AppKit finishes the drop. Capture the RFC 822 source
        // while `performDragOperation` is still on the stack, then leave validation, staging, and
        // delivery on the ordinary file-promise queue.
        let sourceResult = Result { try exporter.source(for: descriptor) }
        guard let output = Self.reserveOutput(
            in: destinationDirectory,
            fileName: Self.fileName(for: descriptor)
        ) else {
            reader(destinationDirectory, MailMessageDragError.exportFailed)
            return
        }
        operationQueue.addOperation {
            do {
                let source = try sourceResult.get()
                let data = Data(source.utf8)
                guard !data.isEmpty,
                      data.count <= ConversationAttachmentImportBudget.maximumBytes else {
                    throw MailMessageDragError.messageTooLarge
                }
                try data.write(to: output, options: [.atomic])
                reader(output, nil)
            } catch {
                reader(destinationDirectory, error)
            }
        }
    }

    /// The promise materializer accepts direct children of its private staging directory. Reserve
    /// a unique name synchronously so two dragged messages with the same subject cannot race and
    /// overwrite one another when their export operations run concurrently.
    private static func reserveOutput(in directory: URL, fileName: String) -> URL? {
        let source = URL(fileURLWithPath: fileName)
        let stem = source.deletingPathExtension().lastPathComponent
        let suffix = source.pathExtension
        for index in 1...ConversationAttachmentImportBudget.maximumFiles {
            let candidateName = index == 1
                ? fileName
                : "\(stem) \(index).\(suffix)"
            let candidate = directory.appendingPathComponent(
                candidateName,
                isDirectory: false)
            if FileManager.default.createFile(
                atPath: candidate.path,
                contents: nil,
                attributes: [.posixPermissions: 0o600]
            ) {
                return candidate
            }
        }
        return nil
    }

    private static func messageID(from pasteboard: NSPasteboard) -> String? {
        let urlType = NSPasteboard.PasteboardType("public.url")
        guard let raw = pasteboard.string(forType: urlType),
              raw.lowercased().hasPrefix("message:"),
              let decoded = String(raw.dropFirst("message:".count))
                .removingPercentEncoding else { return nil }
        return normalizedMessageID(decoded)
    }

    fileprivate static func normalizedMessageID(_ value: String) -> String {
        value.trimmingCharacters(in: CharacterSet(
            charactersIn: "<> \t\r\n"))
    }

    private static func boundedSingleLine(_ value: String) -> String {
        String(value
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .prefix(300))
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func boundedOptional(_ value: String?) -> String? {
        guard let value else { return nil }
        let bounded = boundedSingleLine(value)
        return bounded.isEmpty ? nil : bounded
    }

    private static func fileName(for descriptor: Descriptor) -> String {
        let illegal = CharacterSet(charactersIn: "/:\\")
            .union(.controlCharacters)
        let cleaned = descriptor.subject.unicodeScalars.map {
            illegal.contains($0) ? "_" : Character(String($0))
        }
        let stem = String(String(cleaned).prefix(120))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (stem.isEmpty ? "Mail message" : stem) + ".eml"
    }
}

protocol MailMessageSourceExporting: Sendable {
    func source(for descriptor: MailMessageDragReceiver.Descriptor) throws -> String
}

struct AppleScriptMailMessageSourceExporter: MailMessageSourceExporting {
    func source(for descriptor: MailMessageDragReceiver.Descriptor) throws -> String {
        // Only the integer library ID is interpolated. Subject and Message-ID are verified after
        // Mail returns them, so drag metadata can never become executable AppleScript.
        let script = """
        using terms from application "Mail"
            tell application id "com.apple.mail"
                repeat with candidate in selection
                    try
                        if (id of candidate as integer) is \(descriptor.id) then
                            return {message id of candidate, subject of candidate, source of candidate}
                        end if
                    end try
                end repeat
                -- Mail can clear `selection` when the drag destination activates. The message
                -- remains in the originating viewer; its numeric library ID is stable there.
                repeat with viewer in message viewers
                    try
                        set matches to (every message of viewer whose id is \(descriptor.id))
                        repeat with candidate in matches
                            return {message id of candidate, subject of candidate, source of candidate}
                        end repeat
                    end try
                end repeat
            end tell
        end using terms from
        return missing value
        """
        guard let appleScript = NSAppleScript(source: script) else {
            throw MailMessageDragError.exportFailed
        }
        var details: NSDictionary?
        let result = appleScript.executeAndReturnError(&details)
        guard result.numberOfItems == 3,
              let returnedMessageID = result.atIndex(1)?.stringValue,
              let returnedSubject = result.atIndex(2)?.stringValue,
              let source = result.atIndex(3)?.stringValue,
              !source.isEmpty else {
            throw MailMessageDragError.messageNoLongerSelected
        }
        guard returnedSubject == descriptor.subject else {
            throw MailMessageDragError.identityMismatch
        }
        if let expected = descriptor.messageID {
            guard MailMessageDragReceiver.normalizedMessageID(returnedMessageID) == expected else {
                throw MailMessageDragError.identityMismatch
            }
        }
        return source
    }
}

enum MailMessageDragError: LocalizedError {
    case exportFailed
    case messageNoLongerSelected
    case identityMismatch
    case messageTooLarge

    var errorDescription: String? {
        switch self {
        case .exportFailed:
            return "Mail could not export the selected message."
        case .messageNoLongerSelected:
            return "The dragged Mail message is no longer selected."
        case .identityMismatch:
            return "Mail returned a different message than the one that was dragged."
        case .messageTooLarge:
            return "The Mail message exceeds the 16 MB attachment limit."
        }
    }
}
