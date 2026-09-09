import AppKit
import SwiftUI

/// The panel the `+` opens: recent photos you can click straight into the message, a camera tile,
/// and the rest of the sources as rows underneath.
///
/// A plain `NSMenu` was the wrong shape for this. The point of the phone's sheet is that you *see*
/// the photos and pick one, and a menu can only carry a cramped strip of them as an accessory view.
struct ComposerAddPanelView: View {
    @ObservedObject var state: ComposerAddPanelState
    let perform: (ComposerAddAction) -> Void
    let pickPhoto: (PhotoLibraryAccess.RecentPhoto) -> Void

    private var header: ComposerAddMediaHeader { state.header }
    private var photos: [PhotoLibraryAccess.RecentPhoto] { state.photos }
    private var hasCamera: Bool { state.hasCamera }

    static let width: CGFloat = 460
    private static let tile: CGFloat = 76

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if header == .photos, !photos.isEmpty {
                HStack(spacing: 0) {
                    Spacer(minLength: 8)
                    Button { perform(.allPhotos) } label: {
                        Text("All Photos")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(Color.nInfoText)
                    }
                    .buttonStyle(.plain)
                    .help("Browse the full photo library")
                }
                .padding(.horizontal, 2)
            }
            mediaRow
            VStack(spacing: 0) {
                ForEach(Array(ComposerAddMenuModel.items(hasCamera: hasCamera).enumerated()),
                        id: \.offset) { index, item in
                    if index > 0 { Divider().padding(.leading, 38) }
                    ComposerAddRow(item: item) { perform(item.action) }
                }
            }
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.nSurface))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.nMuted.opacity(0.45)))
        }
        .padding(12)
        .frame(width: Self.width)
    }

    @ViewBuilder private var mediaRow: some View {
        switch header {
        case .photos where !photos.isEmpty:
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    if hasCamera { cameraTile }
                    ForEach(photos, id: \.localIdentifier) { photo in
                        ComposerPhotoTile(photo: photo, side: Self.tile) { pickPhoto(photo) }
                    }
                }
                .padding(.horizontal, 1)
            }
            .frame(height: Self.tile + 2)
        case .optIn:
            HStack(spacing: 8) {
                if hasCamera { cameraTile }
                Button { perform(.showRecentPhotos) } label: {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Show recent photos")
                            .font(.system(size: 12.5, weight: .semibold))
                        Text("Pick one without opening the full picker.")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 11)
                    .frame(height: Self.tile)
                    .background(RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(Color.nSurface))
                    .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .strokeBorder(Color.nMuted.opacity(0.45), style: StrokeStyle(dash: [4, 3])))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        default:
            if hasCamera {
                HStack(spacing: 8) { cameraTile; Spacer(minLength: 0) }
            }
        }
    }

    private var cameraTile: some View {
        Button { perform(.takePhoto) } label: {
            VStack(spacing: 5) {
                Image(systemName: "camera.fill").font(.system(size: 17))
                Text("Camera").font(.system(size: 10.5, weight: .medium))
            }
            .foregroundStyle(Color.nInfoText)
            .frame(width: Self.tile, height: Self.tile)
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.nSurface))
            .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(Color.nMuted.opacity(0.45)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Take a photo with the camera or a nearby iPhone")
        .accessibilityLabel("Take photo")
    }

}

private struct ComposerPhotoTile: View {
    let photo: PhotoLibraryAccess.RecentPhoto
    let side: CGFloat
    let pick: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: pick) {
            Image(nsImage: photo.thumbnail)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fill)
                .frame(width: side, height: side)
                .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .strokeBorder(hovering ? Color.nAccent : Color.nMuted.opacity(0.4),
                                  lineWidth: hovering ? 2 : 1))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityLabel("Recent photo")
    }
}

private struct ComposerAddRow: View {
    let item: ComposerAddMenuItem
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: item.symbol)
                    .font(.system(size: 13))
                    .foregroundStyle(Color.nInfoText)
                    .frame(width: 18)
                Text(item.title).font(.system(size: 13))
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .frame(height: 34)
            .background(hovering ? Color.nElevated : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}
