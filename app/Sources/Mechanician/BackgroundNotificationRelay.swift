import Foundation
import Darwin

/// A bounded, file-backed notification request written by the background scheduler. The title/body
/// stay out of the process table; only the request path is passed to a short-lived Mechanician
/// process, which gives the resulting banner the correct application identity.
struct BackgroundNotificationPayload: Codable, Equatable {
    let title: String
    let body: String
    let openWindowID: String?
    let conversationID: UUID?
}

enum BackgroundNotificationRelayLaunch: Equatable {
    case notRequested
    case invalid
    case deliver(BackgroundNotificationPayload)
}

enum BackgroundNotificationRelay {
    static let argument = "--deliver-background-notification"
    static let maximumRequestBytes = 64 * 1024

    static func isRequested(arguments: [String]) -> Bool {
        arguments.contains(argument)
    }

    static func requestDirectory(
        environment: [String: String],
        homeDirectory: URL
    ) -> URL {
        AgentdRuntime.supportDirectory(environment: environment, homeDirectory: homeDirectory)
            .appendingPathComponent("ambient/notification-requests", isDirectory: true)
    }

    /// Consume exactly one scheduler-created request. A path outside the dedicated request
    /// directory is never opened or removed; symlinks are rejected with `O_NOFOLLOW`.
    static func consume(
        arguments: [String],
        requestDirectory: URL,
        fileManager: FileManager = .default
    ) -> BackgroundNotificationRelayLaunch {
        guard let argumentIndex = arguments.firstIndex(of: argument) else {
            return .notRequested
        }
        guard arguments.count == argumentIndex + 2 else { return .invalid }

        let directory = requestDirectory.standardizedFileURL.resolvingSymlinksInPath()
        let request = URL(fileURLWithPath: arguments[argumentIndex + 1]).standardizedFileURL
        guard request.pathExtension == "json",
              request.deletingLastPathComponent().resolvingSymlinksInPath() == directory
        else { return .invalid }

        // Once a request has been proven to be inside the relay directory it is single-use,
        // including malformed/oversized files. Never leave a poison request behind.
        defer { try? fileManager.removeItem(at: request) }

        let descriptor = Darwin.open(request.path, O_RDONLY | O_NOFOLLOW)
        guard descriptor >= 0 else { return .invalid }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }

        var attributes = stat()
        guard fstat(descriptor, &attributes) == 0,
              (attributes.st_mode & S_IFMT) == S_IFREG,
              attributes.st_size > 0,
              attributes.st_size <= maximumRequestBytes,
              let data = try? handle.read(upToCount: maximumRequestBytes + 1),
              data.count <= maximumRequestBytes,
              let payload = try? JSONDecoder().decode(BackgroundNotificationPayload.self, from: data),
              isValid(payload)
        else { return .invalid }
        return .deliver(payload)
    }

    private static func isValid(_ payload: BackgroundNotificationPayload) -> Bool {
        let title = payload.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty,
              payload.title.utf8.count <= 512,
              payload.body.utf8.count <= 16 * 1024,
              payload.openWindowID == nil || payload.openWindowID == "ambient"
        else { return false }
        return true
    }
}
