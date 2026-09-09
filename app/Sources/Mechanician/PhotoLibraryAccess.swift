import AppKit
import Photos
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

/// Photo sources for the composer.
///
/// Two different doors, deliberately: `presentPicker` runs `PHPickerViewController`, which lives in
/// another process and therefore needs no authorization and no `NSPhotoLibraryUsageDescription`. Only
/// the recent-photos strip reads the library directly, so only the strip has to ask. That split is
/// what lets the "+" menu open without ever firing a permission prompt.
@MainActor
enum PhotoLibraryAccess {
    struct RecentPhoto: Equatable {
        let localIdentifier: String
        let thumbnail: NSImage
    }

    static func stripAccess() -> ComposerPhotoStripAccess {
        switch PHPhotoLibrary.authorizationStatus(for: .readWrite) {
        case .authorized, .limited: return .authorized
        case .notDetermined: return .notDetermined
        case .denied, .restricted: return .unavailable
        @unknown default: return .unavailable
        }
    }

    /// Requesting even when a decline is likely is the point: it registers the app in
    /// Privacy ▸ Photos so the user can turn it on later without hunting for us. Same reasoning as
    /// `SpeechDictation` requesting the microphone before speech authorization.
    static func requestStripAccess(completion: @escaping () -> Void) {
        PHPhotoLibrary.requestAuthorization(for: .readWrite) { _ in
            Task { @MainActor in completion() }
        }
    }

    /// Recent thumbnails, in library order.
    ///
    /// Completion is unconditional. The previous version only counted non-degraded deliveries, so an
    /// asset that never produced a final image left the caller waiting forever — and presentation
    /// used to be gated on that callback, which meant the whole panel could fail to open.
    static func loadRecentPhotos(
        limit: Int = 4,
        completion: @escaping ([RecentPhoto]) -> Void
    ) {
        guard stripAccess() == .authorized else {
            completion([])
            return
        }
        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        options.fetchLimit = limit
        let assets = PHAsset.fetchAssets(with: .image, options: options)
        var ordered: [PHAsset] = []
        assets.enumerateObjects { asset, _, _ in ordered.append(asset) }
        guard !ordered.isEmpty else {
            completion([])
            return
        }

        let request = PHImageRequestOptions()
        request.isNetworkAccessAllowed = true
        request.deliveryMode = .highQualityFormat   // one delivery, so no degraded-first bookkeeping
        request.resizeMode = .fast

        var collected: [String: NSImage] = [:]
        var outstanding = ordered.count
        let finish = {
            completion(ordered.compactMap { asset in
                collected[asset.localIdentifier].map {
                    RecentPhoto(localIdentifier: asset.localIdentifier, thumbnail: $0)
                }
            })
        }
        for asset in ordered {
            PHImageManager.default().requestImage(
                for: asset,
                targetSize: CGSize(width: 208, height: 208),
                contentMode: .aspectFill,
                options: request
            ) { image, _ in
                Task { @MainActor in
                    if let image { collected[asset.localIdentifier] = image }
                    outstanding -= 1
                    if outstanding <= 0 { finish() }
                }
            }
        }
    }

    /// The full-size original behind a strip thumbnail, written where every other attachment source
    /// writes, so it reaches the composer as an ordinary file.
    static func exportOriginal(
        _ photo: RecentPhoto,
        completion: @escaping (URL?) -> Void
    ) {
        let assets = PHAsset.fetchAssets(
            withLocalIdentifiers: [photo.localIdentifier], options: nil)
        guard let asset = assets.firstObject else {
            completion(nil)
            return
        }
        let options = PHImageRequestOptions()
        options.isNetworkAccessAllowed = true   // iCloud-only originals must still work
        options.deliveryMode = .highQualityFormat
        PHImageManager.default().requestImageDataAndOrientation(
            for: asset, options: options
        ) { data, uti, _, _ in
            Task { @MainActor in
                guard let data else {
                    completion(nil)
                    return
                }
                completion(ComposerCaptureStorage.writeImage(
                    data, sourceType: uti.flatMap(UTType.init), basename: "Photo"))
            }
        }
    }

    /// Browse the library. Ours when we are allowed to read it, the system picker when we are not.
    ///
    /// Asking here is not the thing the opt-in card exists to avoid: that card exists so that merely
    /// *opening* the add panel never prompts. Clicking "Photos…" is an explicit request for the
    /// library, and a prompt in direct answer to it is what anyone would expect.
    static func presentBrowser(from view: NSView, completion: @escaping ([URL]) -> Void) {
        switch stripAccess() {
        case .authorized:
            presentOwnBrowser(from: view, completion: completion)
        case .notDetermined:
            requestStripAccess {
                if stripAccess() == .authorized {
                    presentOwnBrowser(from: view, completion: completion)
                } else {
                    presentPicker(from: view, completion: completion)
                }
            }
        case .unavailable:
            presentPicker(from: view, completion: completion)
        }
    }

    private static func presentOwnBrowser(
        from view: NSView,
        completion: @escaping ([URL]) -> Void
    ) {
        guard let host = view.window?.contentViewController else {
            completion([])
            return
        }
        let model = PhotoBrowserModel()
        model.load()
        var controller: NSViewController?
        let browser = PhotoBrowserView(
            model: model,
            cancel: {
                controller?.dismiss(nil)
                completion([])
            },
            add: { assets in
                // The sheet stays up while originals are fetched. An iCloud-only photo has to be
                // downloaded first, and dismissing immediately made that read as nothing happening.
                model.exportProgress = .init(completed: 0, total: assets.count)
                exportOriginals(
                    assets,
                    progress: { done in
                        model.exportProgress = .init(completed: done, total: assets.count)
                    },
                    completion: { urls in
                        model.exportProgress = nil
                        controller?.dismiss(nil)
                        completion(urls)
                    })
            })
        let hosting = NSHostingController(rootView: browser)
        // Our own controller, so this is honoured — unlike the remote picker, which shrank to about
        // 310x195 no matter what it was asked for.
        let available = view.window?.screen?.visibleFrame.size
            ?? NSSize(width: 1_400, height: 900)
        hosting.preferredContentSize = NSSize(
            width: min(980, max(720, available.width - 220)),
            height: min(680, max(520, available.height - 220)))
        controller = hosting
        host.presentAsSheet(hosting)
    }

    /// Full-size originals for a browser selection, in the order they were picked.
    ///
    /// `progress` fires as each one lands so the sheet can say where it is.
    private static func exportOriginals(
        _ assets: [PHAsset],
        progress: @escaping (Int) -> Void = { _ in },
        completion: @escaping ([URL]) -> Void
    ) {
        guard !assets.isEmpty else {
            completion([])
            return
        }
        var urls = [URL?](repeating: nil, count: assets.count)
        var outstanding = assets.count
        var completed = 0
        let options = PHImageRequestOptions()
        options.isNetworkAccessAllowed = true
        options.deliveryMode = .highQualityFormat
        for (index, asset) in assets.enumerated() {
            PHImageManager.default().requestImageDataAndOrientation(
                for: asset, options: options
            ) { data, uti, _, _ in
                let written = data.flatMap {
                    ComposerCaptureStorage.writeImage(
                        $0, sourceType: uti.flatMap(UTType.init), basename: "Photo")
                }
                Task { @MainActor in
                    urls[index] = written
                    completed += 1
                    progress(completed)
                    outstanding -= 1
                    guard outstanding <= 0 else { return }
                    completion(urls.compactMap { $0 })
                }
            }
        }
    }

    /// The out-of-process picker: no authorization, no usage description, multi-select. Kept only as
    /// the fallback for a library we are not allowed to read.
    static func presentPicker(from view: NSView, completion: @escaping ([URL]) -> Void) {
        var configuration = PHPickerConfiguration()
        configuration.filter = .images
        configuration.selectionLimit = 0
        let picker = PHPickerViewController(configuration: configuration)
        let delegate = PickerDelegate(completion: completion)
        picker.delegate = delegate
        pickerDelegate = delegate
        guard let host = view.window?.contentViewController else {
            completion([])
            return
        }
        // Deliberately no preferredContentSize: this is an out-of-process controller that sizes its
        // own sheet, and asking made it smaller rather than larger. Reachable only when we are not
        // allowed to read the library, so its appearance is the system's business, not ours.
        host.presentAsSheet(picker)
    }

    /// `PHPickerViewController` holds its delegate weakly.
    private static var pickerDelegate: PickerDelegate?

    private final class PickerDelegate: NSObject, PHPickerViewControllerDelegate {
        private let completion: ([URL]) -> Void

        init(completion: @escaping ([URL]) -> Void) {
            self.completion = completion
        }

        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            picker.dismiss(nil)
            guard !results.isEmpty else {
                Task { @MainActor in
                    PhotoLibraryAccess.pickerDelegate = nil
                    self.completion([])
                }
                return
            }
            // Preserve the order the user selected in; a concurrent group would not.
            var urls = [URL?](repeating: nil, count: results.count)
            var outstanding = results.count
            for (index, result) in results.enumerated() {
                let provider = result.itemProvider
                // Whatever the library hands back, named honestly and readable by the agent. This
                // used to write every result as ".png" regardless of its actual bytes.
                let identifier = provider.registeredTypeIdentifiers.first {
                    UTType($0).map { type in type.conforms(to: .image) } ?? false
                } ?? UTType.image.identifier
                provider.loadDataRepresentation(forTypeIdentifier: identifier) { data, _ in
                    let written = data.flatMap {
                        ComposerCaptureStorage.writeImage(
                            $0, sourceType: UTType(identifier), basename: "Photo")
                    }
                    Task { @MainActor in
                        urls[index] = written
                        outstanding -= 1
                        guard outstanding <= 0 else { return }
                        PhotoLibraryAccess.pickerDelegate = nil
                        self.completion(urls.compactMap { $0 })
                    }
                }
            }
        }
    }
}

/// One place for bytes captured or exported by the composer's own sources to land before intake
/// copies them into conversation storage. Not the conversation store itself: these are scratch files
/// whose only job is to look exactly like a file the user dragged in.
enum ComposerCaptureStorage {
    static func directory() -> URL {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("Mechanician-composer-capture", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    /// A path nothing else will take.
    ///
    /// The timestamp is for humans; the suffix is what makes it unique. Exporting several photos at
    /// once happens well inside one second, and a second-precision name meant every export landed on
    /// the same path and overwrote the last — so picking four photos attached four copies of the
    /// fourth.
    static func reserveURL(fileExtension: String, basename: String) -> URL? {
        let stamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        let unique = UUID().uuidString.prefix(8)
        return directory()
            .appendingPathComponent("\(basename) \(stamp) \(unique)")
            .appendingPathExtension(fileExtension)
    }

    /// Formats the model can actually read. Anthropic's vision API accepts JPEG, PNG, GIF, and
    /// WebP. A photo library hands back HEIC, which is none of them — so exporting an original
    /// untouched attaches a thumbnail the person can see and the agent cannot.
    static let modelReadableTypes: Set<UTType> = [.png, .jpeg, .gif, .webP]

    /// Write image bytes in a format the agent can read, transcoding only when it has to.
    static func writeImage(_ data: Data, sourceType: UTType?, basename: String) -> URL? {
        if let sourceType, modelReadableTypes.contains(sourceType) {
            return write(
                data,
                fileExtension: sourceType.preferredFilenameExtension ?? "png",
                basename: basename)
        }
        // JPEG, not PNG. A 12-megapixel HEIC is a couple of megabytes; the same pixels as PNG are
        // twenty-five or more, and the composer's import budget is 16 MB for the whole batch — so
        // transcoding photos losslessly silently dropped every photo after the first.
        guard let image = NSImage(data: data),
              let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let jpeg = bitmap.representation(
                using: .jpeg, properties: [.compressionFactor: 0.9])
        else { return nil }
        return write(jpeg, fileExtension: "jpg", basename: basename)
    }

    static func write(_ data: Data, fileExtension: String, basename: String) -> URL? {
        guard let url = reserveURL(fileExtension: fileExtension, basename: basename) else {
            return nil
        }
        do {
            try data.write(to: url, options: .atomic)
            return url
        } catch {
            return nil
        }
    }
}
