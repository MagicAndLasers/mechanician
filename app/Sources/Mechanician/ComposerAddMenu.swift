import AppKit
import SwiftUI

/// What a row in the composer's "+" menu does. Every one of these ends the same way: a file URL
/// handed to the intake path that drag-and-drop and paste already use. A source that needed a new
/// payload kind would mean the design was wrong.
enum ComposerAddAction: Equatable {
    /// Ask for photo-library access so the recent strip can be drawn from then on.
    case showRecentPhotos
    /// The out-of-process picker. Needs no authorization at all, which is why it is always offered.
    case allPhotos
    case takePhoto
    case captureScreenArea
    case addFiles
}

/// Whether the recent-photos strip can be drawn. Distinct from "can the user pick photos", which is
/// always true: `PHPickerViewController` runs out of process and needs no grant.
enum ComposerPhotoStripAccess: Equatable {
    case notDetermined
    case authorized
    case unavailable
}

struct ComposerAddMenuItem: Equatable {
    let title: String
    let action: ComposerAddAction
    let symbol: String
    var startsSection = false
}

/// What the panel shows above its action rows.
enum ComposerAddMediaHeader: Equatable {
    /// Undecided library: offer to turn the strip on, rather than firing a prompt on open.
    case optIn
    /// Granted: draw the thumbnails.
    case photos
    /// Declined or restricted: the camera tile stands alone, and we stop asking.
    case cameraOnly
}

/// The panel's contents, as data. Kept separate from the view so the rules about what appears when
/// are testable without a window, a camera, or a photo library.
enum ComposerAddMenuModel {
    static func mediaHeader(_ access: ComposerPhotoStripAccess) -> ComposerAddMediaHeader {
        switch access {
        case .authorized: return .photos
        case .notDetermined: return .optIn
        case .unavailable: return .cameraOnly
        }
    }

    /// Independent of photo permission on purpose: `PHPickerViewController` runs out of process, so
    /// "Photos…" works whatever the library says.
    static func items(hasCamera: Bool) -> [ComposerAddMenuItem] {
        var items: [ComposerAddMenuItem] = [
            ComposerAddMenuItem(title: "Photos…", action: .allPhotos, symbol: "photo"),
        ]
        if hasCamera {
            items.append(ComposerAddMenuItem(
                title: "Take Photo…", action: .takePhoto, symbol: "camera"))
        }
        items.append(ComposerAddMenuItem(
            title: "Capture Screen Area",
            action: .captureScreenArea,
            symbol: "macwindow.on.rectangle"))
        items.append(ComposerAddMenuItem(
            title: "Files…", action: .addFiles, symbol: "paperclip", startsSection: true))
        return items
    }
}

/// What the open panel is showing. Published so thumbnails arriving from PhotoKit update a panel
/// that is already on screen, instead of the panel waiting for them before it opens.
@MainActor
final class ComposerAddPanelState: ObservableObject {
    @Published var header: ComposerAddMediaHeader = .optIn
    @Published var photos: [PhotoLibraryAccess.RecentPhoto] = []
    @Published var hasCamera = false
}

/// The `+` beside the microphone. Opens `ComposerAddPanelView` in a popover.
///
/// Presented from AppKit on a mouse event, never from a SwiftUI view update: driving an
/// `NSPopover` from inside an update is what once ran `NSWindow.addChildWindow` during an AppKit
/// layout pass and crashed the app (see `ComposerDeliveryMenuView`).
@MainActor
final class ComposerAddMenuView: NSView {
    /// Attach these URLs to the composer. Every source funnels through here.
    var onAttach: (([URL]) -> Void)?
    /// Present the standard file importer, which SwiftUI still owns.
    var onAddFiles: (() -> Void)?

    private let state = ComposerAddPanelState()
    private var popover: NSPopover?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        toolTip = "Add photos, files, or a screen capture"
        setAccessibilityRole(.popUpButton)
        setAccessibilityLabel("Add to message")
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var intrinsicContentSize: NSSize { NSSize(width: 28, height: 28) }

    /// Synchronous, and never gated on PhotoKit. Thumbnails are fetched afterwards and land in the
    /// published state, so a slow or silent image request cannot keep the panel from opening — which
    /// it could when presentation waited for that callback.
    func refreshAvailability() {
        let access = PhotoLibraryAccess.stripAccess()
        state.header = ComposerAddMenuModel.mediaHeader(access)
        state.hasCamera = CameraCapture.hasAnyCamera
        guard state.header == .photos else {
            state.photos = []
            return
        }
        PhotoLibraryAccess.loadRecentPhotos { [weak self] photos in
            self?.state.photos = photos
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        let configuration = NSImage.SymbolConfiguration(pointSize: 15, weight: .regular)
            .applying(NSImage.SymbolConfiguration(paletteColors: [.secondaryLabelColor]))
        guard let plus = NSImage(systemSymbolName: "plus", accessibilityDescription: nil)?
            .withSymbolConfiguration(configuration) else { return }
        let size = plus.size
        plus.draw(
            at: NSPoint(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2),
            from: .zero, operation: .sourceOver, fraction: 1)
    }

    /// Option-click goes straight to the file picker. Before the `+`, one click opened it; the panel
    /// would otherwise silently make that two for anyone who had the habit.
    override func mouseDown(with event: NSEvent) {
        if event.modifierFlags.contains(.option) {
            onAddFiles?()
            return
        }
        refreshAvailability()
        presentPanel()
    }

    func makePanelController() -> NSViewController {
        let panel = ComposerAddPanelView(
            state: state,
            perform: { [weak self] action in self?.perform(action) },
            pickPhoto: { [weak self] photo in
                self?.dismissPanel()
                PhotoLibraryAccess.exportOriginal(photo) { url in
                    guard let url else { return }
                    self?.onAttach?([url])
                }
            })
        let controller = NSHostingController(rootView: panel)
        controller.sizingOptions = [.preferredContentSize]
        return controller
    }

    private func presentPanel() {
        dismissPanel()
        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentViewController = makePanelController()
        popover.show(relativeTo: bounds, of: self, preferredEdge: .maxY)
        self.popover = popover
    }

    private func dismissPanel() {
        popover?.performClose(nil)
        popover = nil
    }

    private func perform(_ action: ComposerAddAction) {
        if action != .showRecentPhotos { dismissPanel() }
        switch action {
        case .addFiles:
            onAddFiles?()
        case .showRecentPhotos:
            PhotoLibraryAccess.requestStripAccess { [weak self] in
                // The panel stays open; granting swaps the opt-in card for the thumbnails in place.
                self?.refreshAvailability()
            }
        case .allPhotos:
            PhotoLibraryAccess.presentBrowser(from: self) { [weak self] urls in
                self?.onAttach?(urls)
            }
        case .takePhoto:
            CameraCapture.present(from: self) { [weak self] url in
                self?.onAttach?([url])
            }
        case .captureScreenArea:
            ScreenAreaCapture.capture { [weak self] url in
                self?.onAttach?([url])
            }
        }
    }
}

@MainActor
struct ComposerAddMenuButton: NSViewRepresentable {
    let addFiles: () -> Void
    let attach: ([URL]) -> Void

    func makeNSView(context: Context) -> ComposerAddMenuView {
        let view = ComposerAddMenuView()
        view.onAddFiles = addFiles
        view.onAttach = attach
        view.refreshAvailability()
        return view
    }

    func updateNSView(_ nsView: ComposerAddMenuView, context: Context) {
        nsView.onAddFiles = addFiles
        nsView.onAttach = attach
    }
}
