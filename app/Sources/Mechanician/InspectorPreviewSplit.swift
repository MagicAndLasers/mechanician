import SwiftUI

/// Stable sizing for resizable lower panes in the Files, Changes, and Agents inspectors.
///
/// `VSplitView` derives its divider position from the intrinsic size of both children. A selected
/// image, text view, diff, or placeholder all report different ideal heights, so merely changing
/// the preview content can move the divider. This split owns the preview height instead: selection
/// changes only the content below the divider, while the user's persisted height remains stable.
enum InspectorPreviewSizing {
    static let handleHeight: CGFloat = 10

    static func resolvedHeight(
        storedHeight: Double,
        availableHeight: CGFloat,
        minimumTopHeight: CGFloat,
        minimumPreviewHeight: CGFloat,
        maximumPreviewHeight: CGFloat
    ) -> CGFloat {
        let roomBelowTop = max(0, availableHeight - handleHeight - minimumTopHeight)
        guard roomBelowTop > 0 else { return 0 }
        let effectiveMinimum = min(minimumPreviewHeight, roomBelowTop)
        let effectiveMaximum = min(maximumPreviewHeight, roomBelowTop)
        return min(max(CGFloat(storedHeight), effectiveMinimum), effectiveMaximum)
    }
}

/// A user-resizable vertical inspector split whose lower-pane height survives content replacement,
/// tab changes, conversation switches, and relaunch. The preview is clamped only when the window is
/// too short to preserve both a usable list and the saved preview height.
struct InspectorPreviewSplit<Top: View, Preview: View>: View {
    @Binding private var previewHeight: Double
    private let minimumTopHeight: CGFloat
    private let minimumPreviewHeight: CGFloat
    private let maximumPreviewHeight: CGFloat
    private let top: Top
    private let preview: Preview

    init(
        previewHeight: Binding<Double>,
        minimumTopHeight: CGFloat = 180,
        minimumPreviewHeight: CGFloat = 220,
        maximumPreviewHeight: CGFloat = 520,
        @ViewBuilder top: () -> Top,
        @ViewBuilder preview: () -> Preview
    ) {
        _previewHeight = previewHeight
        self.minimumTopHeight = minimumTopHeight
        self.minimumPreviewHeight = minimumPreviewHeight
        self.maximumPreviewHeight = maximumPreviewHeight
        self.top = top()
        self.preview = preview()
    }

    var body: some View {
        GeometryReader { proxy in
            let resolvedPreviewHeight = InspectorPreviewSizing.resolvedHeight(
                storedHeight: previewHeight,
                availableHeight: proxy.size.height,
                minimumTopHeight: minimumTopHeight,
                minimumPreviewHeight: minimumPreviewHeight,
                maximumPreviewHeight: maximumPreviewHeight
            )
            VStack(spacing: 0) {
                top
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                InspectorPreviewResizeHandle(
                    size: $previewHeight,
                    range: Double(minimumPreviewHeight)...Double(maximumPreviewHeight)
                )
                preview
                    .frame(maxWidth: .infinity)
                    .frame(height: resolvedPreviewHeight)
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
    }
}

/// A visible, full-height drag target for inspector preview splits. The global resize handle is
/// intentionally a one-pixel seam for window chrome; using it here made the timeline divider nearly
/// impossible to acquire and gave no visual indication that the lower panel was resizable.
private struct InspectorPreviewResizeHandle: View {
    @Binding var size: Double
    let range: ClosedRange<Double>
    @State private var base: Double?
    @State private var hovered = false
    @State private var dragging = false

    var body: some View {
        ZStack {
            Rectangle()
                .fill((hovered || dragging) ? Color.nElevated.opacity(0.75) : Color.nSurface)
            Capsule()
                .fill((hovered || dragging) ? Color.nAccent.opacity(0.8) : Color.secondary.opacity(0.42))
                .frame(width: 34, height: 2)
        }
        .frame(height: InspectorPreviewSizing.handleHeight)
        .contentShape(Rectangle())
        .overlay(CursorArea(cursor: .resizeUpDown))
        .onHover { hovered = $0 }
        .gesture(
            DragGesture(minimumDistance: 0, coordinateSpace: .global)
                .onChanged { gesture in
                    let initial = base ?? size
                    if base == nil {
                        base = initial
                        dragging = true
                    }
                    size = min(
                        max(initial - gesture.translation.height, range.lowerBound),
                        range.upperBound)
                }
                .onEnded { _ in
                    base = nil
                    dragging = false
                }
        )
        .animation(.easeOut(duration: 0.1), value: hovered)
        .accessibilityLabel("Resize lower inspector panel")
        .accessibilityValue("\(Int(size)) points high")
    }
}
