import AppKit
import Photos
import SwiftUI

/// Our own photo browser.
///
/// `PHPickerViewController` is an out-of-process view controller, and on macOS it sizes its own
/// sheet: asking for a bigger `preferredContentSize` does not survive the remote view, which opened
/// a roughly 310x195 sheet with its grid crushed behind its own controls. Since the recent strip
/// already needs library access, browsing the library ourselves costs no additional permission and
/// puts the size, the grid, and the appearance under our control.
///
/// The system picker stays as the fallback for a declined library, because it needs no grant at all.
@MainActor
final class PhotoBrowserModel: ObservableObject {
    @Published private(set) var assets: [PHAsset] = []
    @Published var selection: [String] = []
    /// Non-nil while originals are being fetched. A photo that lives only in iCloud has to be
    /// downloaded before it can be attached, which is slow enough that saying nothing reads as
    /// nothing happening.
    @Published var exportProgress: ExportProgress?

    struct ExportProgress: Equatable {
        var completed: Int
        var total: Int
        var fraction: Double { total > 0 ? Double(completed) / Double(total) : 0 }
    }

    var hasSelection: Bool { !selection.isEmpty }
    var isExporting: Bool { exportProgress != nil }

    func load(limit: Int = 300) {
        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        options.fetchLimit = limit
        let result = PHAsset.fetchAssets(with: .image, options: options)
        var collected: [PHAsset] = []
        result.enumerateObjects { asset, _, _ in collected.append(asset) }
        assets = collected
    }

    /// Ordered by when the user picked, not by date, so a deliberate order survives into the message.
    func toggle(_ asset: PHAsset) {
        if let index = selection.firstIndex(of: asset.localIdentifier) {
            selection.remove(at: index)
        } else {
            selection.append(asset.localIdentifier)
        }
    }

    func isSelected(_ asset: PHAsset) -> Bool { selection.contains(asset.localIdentifier) }

    func selectionIndex(_ asset: PHAsset) -> Int? {
        selection.firstIndex(of: asset.localIdentifier).map { $0 + 1 }
    }

    func selectedAssets() -> [PHAsset] {
        selection.compactMap { identifier in
            assets.first { $0.localIdentifier == identifier }
        }
    }
}

struct PhotoBrowserView: View {
    @ObservedObject var model: PhotoBrowserModel
    let cancel: () -> Void
    let add: ([PHAsset]) -> Void

    private let columns = [GridItem(.adaptive(minimum: 132), spacing: 10)]

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                LazyVGrid(columns: columns, spacing: 10) {
                    ForEach(model.assets, id: \.localIdentifier) { asset in
                        PhotoBrowserCell(
                            asset: asset,
                            order: model.selectionIndex(asset),
                            isSelected: model.isSelected(asset)
                        ) {
                            model.toggle(asset)
                        }
                    }
                }
                .padding(14)
            }
            Divider()
            HStack(spacing: 10) {
                if let progress = model.exportProgress {
                    ProgressView(value: progress.fraction)
                        .progressViewStyle(.linear)
                        .frame(width: 120)
                }
                Text(footerText)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Cancel", action: cancel)
                    .buttonStyle(PillButtonStyle(kind: .neutral))
                    .keyboardShortcut(.cancelAction)
                    .disabled(model.isExporting)
                Button(model.isExporting ? "Adding…" : "Add") { add(model.selectedAssets()) }
                    .buttonStyle(PillButtonStyle(kind: .accent))
                    .keyboardShortcut(.defaultAction)
                    .disabled(!model.hasSelection || model.isExporting)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
        }
        .frame(minWidth: 720, minHeight: 520)
    }

    var footerText: String {
        if let progress = model.exportProgress {
            return "Adding \(progress.completed + 1) of \(progress.total)…"
        }
        if model.assets.isEmpty { return "No photos in this library." }
        let count = model.selection.count
        if count == 0 { return "Click photos to add them." }
        return "\(count) photo\(count == 1 ? "" : "s") selected"
    }
}

private struct PhotoBrowserCell: View {
    let asset: PHAsset
    let order: Int?
    let isSelected: Bool
    let toggle: () -> Void

    @State private var thumbnail: NSImage?
    @State private var hovering = false

    var body: some View {
        Button(action: toggle) {
            ZStack(alignment: .topTrailing) {
                Group {
                    if let thumbnail {
                        Image(nsImage: thumbnail)
                            .resizable()
                            .interpolation(.high)
                            .aspectRatio(contentMode: .fill)
                    } else {
                        Color.nElevated
                    }
                }
                .frame(height: 132)
                .frame(maxWidth: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(
                        isSelected ? Color.nAccent : (hovering ? Color.nMuted : Color.clear),
                        lineWidth: isSelected ? 3 : 1))

                if let order {
                    Text("\(order)")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 20, height: 20)
                        .background(Circle().fill(Color.nAccent))
                        .padding(7)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityLabel(isSelected ? "Photo, selected" : "Photo")
        .task { await loadThumbnail() }
    }

    /// One synchronous request off the main thread: `opportunistic` delivery calls back more than
    /// once, and guarding a continuation against that with a captured flag is a data race, because
    /// PhotoKit does not promise which thread those callbacks arrive on.
    private func loadThumbnail() async {
        let asset = self.asset
        let image = await Task.detached { () -> NSImage? in
            let options = PHImageRequestOptions()
            options.isNetworkAccessAllowed = true
            options.deliveryMode = .highQualityFormat
            options.resizeMode = .fast
            options.isSynchronous = true
            var result: NSImage?
            PHImageManager.default().requestImage(
                for: asset,
                targetSize: CGSize(width: 320, height: 320),
                contentMode: .aspectFill,
                options: options
            ) { image, _ in result = image }
            return result
        }.value
        thumbnail = image
    }
}
