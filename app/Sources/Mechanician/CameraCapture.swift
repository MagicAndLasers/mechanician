import AVFoundation
import AppKit

/// Take a photo with the Mac's camera, or with an iPhone acting as one.
///
/// Continuity Camera reaches us here as an ordinary `AVCaptureDevice`, so a nearby iPhone simply
/// appears in the source popup beside the built-in camera. That covers the iPhone app's Camera tile.
/// It does not cover Scan Documents, which has no public capture API on macOS and arrives instead
/// through the system's "Import from iPhone or iPad" menu (see `ComposerTextView`).
@MainActor
enum CameraCapture {
    static var discoveredDevices: [AVCaptureDevice] {
        AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .external, .continuityCamera],
            mediaType: .video,
            position: .unspecified
        ).devices
    }

    static var hasAnyCamera: Bool { !discoveredDevices.isEmpty }

    /// What to do about camera access, given the system's answer and whether this build can even ask.
    enum AccessOutcome: Equatable {
        case present
        case request
        case denied
        /// The running bundle has no `NSCameraUsageDescription`, so macOS will never prompt and the
        /// app can never appear in Privacy ▸ Camera. Sending someone to that pane would be a lie.
        case unsupportedBuild
    }

    static func outcome(
        status: AVAuthorizationStatus,
        hasUsageDescription: Bool
    ) -> AccessOutcome {
        guard hasUsageDescription else { return .unsupportedBuild }
        switch status {
        case .authorized: return .present
        case .notDetermined: return .request
        case .denied, .restricted: return .denied
        @unknown default: return .denied
        }
    }

    static var hasUsageDescription: Bool {
        let description = Bundle.main.object(forInfoDictionaryKey: "NSCameraUsageDescription")
        return (description as? String)?.isEmpty == false
    }

    /// Requesting even when a decline is likely is the point: that request is what registers the app
    /// in Privacy ▸ Camera, so someone who says no once can find us there later.
    static func present(from view: NSView, completion: @escaping (URL) -> Void) {
        switch outcome(
            status: AVCaptureDevice.authorizationStatus(for: .video),
            hasUsageDescription: hasUsageDescription
        ) {
        case .present:
            presentSheet(from: view, completion: completion)
        case .request:
            AVCaptureDevice.requestAccess(for: .video) { granted in
                Task { @MainActor in
                    if granted {
                        presentSheet(from: view, completion: completion)
                    } else {
                        presentAlert(from: view, outcome: .denied)
                    }
                }
            }
        case .denied:
            presentAlert(from: view, outcome: .denied)
        case .unsupportedBuild:
            presentAlert(from: view, outcome: .unsupportedBuild)
        }
    }

    private static func presentSheet(from view: NSView, completion: @escaping (URL) -> Void) {
        guard let host = view.window?.contentViewController else { return }
        host.presentAsSheet(CameraCaptureViewController(completion: completion))
    }

    static func alertText(for outcome: AccessOutcome) -> (message: String, detail: String) {
        switch outcome {
        case .unsupportedBuild:
            return (
                "This build of Mechanician cannot use the camera",
                "It was built without camera support, so macOS will not offer it in "
                + "Privacy & Security. Update to a build that includes it.")
        default:
            return (
                "Mechanician cannot use the camera",
                "Turn on the camera for Mechanician in System Settings ▸ Privacy & Security ▸ "
                + "Camera, then try again.")
        }
    }

    private static func presentAlert(from view: NSView, outcome: AccessOutcome) {
        let text = alertText(for: outcome)
        let alert = NSAlert()
        alert.messageText = text.message
        alert.informativeText = text.detail
        if outcome != .unsupportedBuild { alert.addButton(withTitle: "Open Settings") }
        alert.addButton(withTitle: "Cancel")
        guard let window = view.window else { return }
        alert.beginSheetModal(for: window) { response in
            guard outcome != .unsupportedBuild, response == .alertFirstButtonReturn,
                  let url = URL(
                    string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera")
            else { return }
            NSWorkspace.shared.open(url)
        }
    }
}

@MainActor
final class CameraCaptureViewController: NSViewController {
    private let completion: (URL) -> Void
    private let session = AVCaptureSession()
    private let output = AVCapturePhotoOutput()
    private var previewLayer: AVCaptureVideoPreviewLayer?
    private let sourcePopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private var devices: [AVCaptureDevice] = []
    private var captureDelegate: PhotoDelegate?

    init(completion: @escaping (URL) -> Void) {
        self.completion = completion
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 560, height: 460))
        let preview = NSView(frame: NSRect(x: 16, y: 64, width: 528, height: 380))
        preview.wantsLayer = true
        preview.layer?.backgroundColor = NSColor.black.cgColor
        preview.layer?.cornerRadius = 10
        preview.layer?.masksToBounds = true
        root.addSubview(preview)

        devices = CameraCapture.discoveredDevices
        sourcePopup.frame = NSRect(x: 16, y: 18, width: 240, height: 26)
        sourcePopup.addItems(withTitles: devices.map(\.localizedName))
        sourcePopup.target = self
        sourcePopup.action = #selector(changeSource)
        sourcePopup.setAccessibilityLabel("Camera source")
        sourcePopup.isHidden = devices.count < 2
        root.addSubview(sourcePopup)

        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancel))
        cancel.frame = NSRect(x: 356, y: 16, width: 84, height: 30)
        cancel.bezelStyle = .rounded
        cancel.keyEquivalent = "\u{1b}"
        root.addSubview(cancel)

        let shutter = NSButton(title: "Take Photo", target: self, action: #selector(takePhoto))
        shutter.frame = NSRect(x: 446, y: 16, width: 98, height: 30)
        shutter.bezelStyle = .rounded
        shutter.keyEquivalent = "\r"
        shutter.setAccessibilityLabel("Take photo")
        root.addSubview(shutter)

        view = root
        configureSession(preview: preview)
    }

    private func configureSession(preview: NSView) {
        session.beginConfiguration()
        session.sessionPreset = .photo
        if let device = devices.first, let input = try? AVCaptureDeviceInput(device: device),
           session.canAddInput(input) {
            session.addInput(input)
        }
        if session.canAddOutput(output) { session.addOutput(output) }
        session.commitConfiguration()

        let layer = AVCaptureVideoPreviewLayer(session: session)
        layer.videoGravity = .resizeAspectFill
        layer.frame = preview.bounds
        layer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        preview.layer?.addSublayer(layer)
        previewLayer = layer

        // Starting the session blocks; keep it off the main thread so the sheet appears immediately.
        Task.detached { [session] in session.startRunning() }
    }

    @objc private func changeSource() {
        let index = sourcePopup.indexOfSelectedItem
        guard devices.indices.contains(index) else { return }
        session.beginConfiguration()
        for input in session.inputs { session.removeInput(input) }
        if let input = try? AVCaptureDeviceInput(device: devices[index]),
           session.canAddInput(input) {
            session.addInput(input)
        }
        session.commitConfiguration()
    }

    @objc private func takePhoto() {
        let delegate = PhotoDelegate { [weak self] data in
            guard let self else { return }
            self.stop()
            guard let data,
                  let url = ComposerCaptureStorage.write(
                    data, fileExtension: "png", basename: "Photo")
            else {
                self.dismiss(nil)
                return
            }
            self.dismiss(nil)
            self.completion(url)
        }
        captureDelegate = delegate
        output.capturePhoto(with: AVCapturePhotoSettings(), delegate: delegate)
    }

    @objc private func cancel() {
        stop()
        dismiss(nil)
    }

    private func stop() {
        let session = session
        Task.detached { session.stopRunning() }
    }

    private final class PhotoDelegate: NSObject, AVCapturePhotoCaptureDelegate {
        private let completion: (Data?) -> Void

        init(completion: @escaping (Data?) -> Void) {
            self.completion = completion
        }

        func photoOutput(
            _ output: AVCapturePhotoOutput,
            didFinishProcessingPhoto photo: AVCapturePhoto,
            error: Error?
        ) {
            // Re-encode to PNG: the composer's inline thumbnails and every other attachment source
            // speak PNG, and a HEIC straight off the sensor would be the one that does not.
            let data = photo.fileDataRepresentation()
                .flatMap { NSImage(data: $0) }
                .flatMap { image -> Data? in
                    guard let tiff = image.tiffRepresentation,
                          let rep = NSBitmapImageRep(data: tiff) else { return nil }
                    return rep.representation(using: .png, properties: [:])
                }
            Task { @MainActor in self.completion(data) }
        }
    }
}
