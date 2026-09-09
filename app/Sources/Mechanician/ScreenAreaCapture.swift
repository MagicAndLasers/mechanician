import AppKit

/// Drag out a region of the screen and attach it.
///
/// The item with no iPhone equivalent, and the one most likely to be used: on a Mac the thing you
/// want to ask about is usually already on screen, not in front of a camera.
///
/// Uses `/usr/sbin/screencapture -i`, the same interactive selection every Mac user already knows,
/// rather than reimplementing a selection overlay on top of ScreenCaptureKit. Cancelling writes no
/// file, which is how a cancel is detected: the tool exits 0 either way.
enum ScreenAreaCapture {
    static func capture(completion: @escaping (URL) -> Void) {
        // screencapture refuses to overwrite, so it needs a reserved path that does not exist yet.
        guard let destination = ComposerCaptureStorage.reserveURL(
            fileExtension: "png", basename: "Screen")
        else { return }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        process.arguments = ["-i", "-o", destination.path]
        process.terminationHandler = { _ in
            Task { @MainActor in
                guard isUsableCapture(destination) else {
                    try? FileManager.default.removeItem(at: destination)
                    return
                }
                completion(destination)
            }
        }
        do {
            try process.run()
        } catch {
            // Screen Recording permission or a missing tool. Nothing to attach, and the system
            // already presents its own permission prompt for this.
            try? FileManager.default.removeItem(at: destination)
        }
    }

    /// A cancelled selection leaves no file; a zero-byte file means the capture failed. Both are
    /// "nothing to attach" rather than an error worth interrupting the user for.
    static func isUsableCapture(_ url: URL) -> Bool {
        guard let values = try? url.resourceValues(forKeys: [.fileSizeKey]),
              let size = values.fileSize else { return false }
        return size > 0
    }
}
