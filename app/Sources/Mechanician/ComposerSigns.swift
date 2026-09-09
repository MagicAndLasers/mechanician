import AppKit
import SwiftUI

/// Compact action glyphs inspired by road signs, drawn in Mechanician's restrained symbol style.
/// They borrow the silhouettes and route metaphors without trying to reproduce physical signage.
enum ComposerRoadSignKind: Hashable {
    case send
    case stop
    case yield
    case detour
    case curveAhead
}

/// A flat, single-weight glyph family for the composer's in-flight actions. Translucent surfaces,
/// clean strokes, and a very small hover lift keep these aligned with the rest of the app chrome.
///
/// Every internal metric is a FRACTION of `size`, never a fixed point value: the same sign is drawn
/// at 23pt on the send button and at 14pt in the delivery menu, and hardcoded insets tuned for the
/// button left the menu's arrows bursting out of their silhouettes. Strokes get a floor so the small
/// renderings stay visible rather than fading to a hairline.
struct ComposerRoadSign: View {
    let kind: ComposerRoadSignKind
    var size: CGFloat = 20
    var highlighted = false
    var raised = true

    private var tint: Color {
        switch kind {
        case .send:
            return Color(red: 0.30, green: 0.56, blue: 0.92)
        case .stop:
            return Color(red: 0.93, green: 0.32, blue: 0.35)
        case .yield:
            return Color(red: 0.92, green: 0.42, blue: 0.36)
        case .detour:
            return Color(red: 0.91, green: 0.59, blue: 0.27)
        case .curveAhead:
            return Color(red: 0.92, green: 0.66, blue: 0.29)
        }
    }

    var body: some View {
        Group {
            switch kind {
            case .send:
                SendGlyph(tint: tint, size: size)
            case .stop:
                StopGlyph(tint: tint, size: size)
            case .yield:
                YieldGlyph(tint: tint, size: size)
            case .detour:
                RouteGlyph(kind: .detour, tint: tint, size: size)
            case .curveAhead:
                RouteGlyph(kind: .curveAhead, tint: tint, size: size)
            }
        }
        .frame(width: size, height: size)
        .compositingGroup()
        .brightness(highlighted ? 0.06 : 0)
        .scaleEffect(highlighted ? 1.06 : 1)
        .shadow(
            color: raised ? tint.opacity(highlighted ? 0.24 : 0.10) : .clear,
            radius: highlighted ? 3 : 1.5,
            y: 0.5)
        .animation(.easeOut(duration: 0.13), value: highlighted)
        .accessibilityHidden(true)
    }
}

/// A shared AppKit rendering of the SwiftUI sign artwork.
///
/// Agent rows and native menus need an `NSImage`, but they should not recreate or approximate the
/// composer's glyphs. Render the quiet, unhighlighted form once per logical size and share it. The
/// cached images are intentionally non-template images: their translucent fills and colored
/// keylines are part of the artwork and must not be replaced by an AppKit control tint.
@MainActor
enum ComposerRoadSignImage {
    private struct CacheKey: Hashable {
        let kind: ComposerRoadSignKind
        let size: CGFloat
    }

    /// Cached `NSImage` instances are immutable after insertion. Controls may display them but must
    /// not change their size or template state.
    private static var cache: [CacheKey: NSImage] = [:]

    static func image(kind: ComposerRoadSignKind, size: CGFloat) -> NSImage? {
        guard size.isFinite, size > 0 else { return nil }
        let key = CacheKey(kind: kind, size: size)
        if let cached = cache[key] { return cached }

        let renderer = ImageRenderer(
            content: ComposerRoadSign(
                kind: kind,
                size: size,
                highlighted: false,
                raised: false))
        renderer.scale = 2
        guard let cgImage = renderer.cgImage else { return nil }
        let logicalSize = NSSize(width: size, height: size)
        let representation = NSBitmapImageRep(cgImage: cgImage)
        representation.size = logicalSize
        let image = NSImage(size: logicalSize)
        image.addRepresentation(representation)
        image.isTemplate = false
        cache[key] = image
        return image
    }
}

struct ComposerRoundButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.93 : 1)
            .brightness(configuration.isPressed ? -0.04 : 0)
            .animation(.spring(response: 0.22, dampingFraction: 0.72), value: configuration.isPressed)
    }
}

// MARK: - Flat glyphs

/// The size the family's proportions were drawn against: the composer's send button. Every glyph
/// expresses its insets, strokes and symbol sizes as a fraction of this, so a 14pt menu icon is a
/// true miniature of the 23pt button rather than a shrunken frame around full-size contents.
private let signReferenceSize: CGFloat = 23

/// Hairlines vanish once a sign is rendered at menu size, so strokes thin proportionally only to
/// a legible floor.
private func signStroke(_ fraction: CGFloat, _ size: CGFloat) -> CGFloat {
    max(size * fraction, 0.9)
}

/// Send is part of the same flat sign family as the in-flight actions. The circular silhouette
/// distinguishes the ordinary forward action without bringing back the old glossy orb or its
/// button-local activity halo.
private struct SendGlyph: View {
    let tint: Color
    let size: CGFloat

    var body: some View {
        ZStack {
            Circle()
                .fill(tint.opacity(0.13))
                .overlay {
                    Circle()
                        .stroke(tint.opacity(0.74), lineWidth: signStroke(1.25 / signReferenceSize, size))
                }

            Image(systemName: "arrow.up")
                .font(.system(size: size * (11.5 / signReferenceSize), weight: .semibold))
                .symbolRenderingMode(.monochrome)
                .foregroundStyle(tint)
        }
        .padding(size * (1.25 / signReferenceSize))
    }
}

/// Stop uses the same translucent material and colored keyline as the rest of the family. Its
/// silhouette carries the destructive meaning without reproducing a literal roadside sign.
private struct StopGlyph: View {
    let tint: Color
    let size: CGFloat

    var body: some View {
        OctagonShape()
            .fill(tint.opacity(0.15))
            .overlay {
                OctagonShape()
                    .strokeBorder(tint.opacity(0.86), lineWidth: signStroke(1.45 / signReferenceSize, size))
            }
            .padding(size * (1.25 / signReferenceSize))
    }
}

/// An open, softly filled inverted triangle: enough to read as Yield without reproducing a
/// red-and-white roadside sign.
private struct YieldGlyph: View {
    let tint: Color
    let size: CGFloat

    var body: some View {
        RoundedYieldTriangle()
            .fill(tint.opacity(0.11))
            .overlay {
                RoundedYieldTriangle()
                    .stroke(tint.opacity(0.88),
                            style: StrokeStyle(lineWidth: signStroke(1.65 / signReferenceSize, size),
                                               lineJoin: .round))
            }
            .padding(.horizontal, size * (1.5 / signReferenceSize))
            .padding(.vertical, size * (2.5 / signReferenceSize))
    }
}

private struct RouteGlyph: View {
    enum Kind { case detour, curveAhead }

    let kind: Kind
    let tint: Color
    let size: CGFloat

    private var symbolName: String {
        switch kind {
        case .curveAhead:
            return "arrowshape.turn.up.right.fill"
        case .detour:
            return "arrow.triangle.branch"
        }
    }

    /// A diamond only leaves an inscribed square of `side / √2` for its contents, so these run
    /// smaller than the other glyphs' symbols at every size.
    private var symbolFraction: CGFloat {
        switch kind {
        case .curveAhead: return 11.5 / signReferenceSize
        case .detour: return 11 / signReferenceSize
        }
    }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * (4.6 / signReferenceSize), style: .continuous)
                .fill(tint.opacity(0.13))
                .overlay {
                    RoundedRectangle(cornerRadius: size * (4.6 / signReferenceSize), style: .continuous)
                        .stroke(tint.opacity(0.66), lineWidth: signStroke(1.2 / signReferenceSize, size))
                }
                .rotationEffect(.degrees(45))
                .padding(size * (3.0 / signReferenceSize))

            Image(systemName: symbolName)
                .font(.system(size: size * symbolFraction, weight: .bold))
                .symbolRenderingMode(.monochrome)
                .foregroundStyle(tint)
        }
    }
}

// MARK: - Shapes

private struct OctagonShape: InsettableShape {
    var insetAmount: CGFloat = 0

    func path(in rect: CGRect) -> Path {
        let r = rect.insetBy(dx: insetAmount, dy: insetAmount)
        guard r.width > 0, r.height > 0 else { return Path() }
        let a: CGFloat = 0.292893
        var path = Path()
        path.addLines([
            CGPoint(x: r.minX + a * r.width, y: r.minY),
            CGPoint(x: r.maxX - a * r.width, y: r.minY),
            CGPoint(x: r.maxX, y: r.minY + a * r.height),
            CGPoint(x: r.maxX, y: r.maxY - a * r.height),
            CGPoint(x: r.maxX - a * r.width, y: r.maxY),
            CGPoint(x: r.minX + a * r.width, y: r.maxY),
            CGPoint(x: r.minX, y: r.maxY - a * r.height),
            CGPoint(x: r.minX, y: r.minY + a * r.height),
        ])
        path.closeSubpath()
        return path
    }

    func inset(by amount: CGFloat) -> OctagonShape {
        var copy = self
        copy.insetAmount += amount
        return copy
    }
}

private struct RoundedYieldTriangle: Shape {
    func path(in rect: CGRect) -> Path {
        let radius = min(rect.width, rect.height) * 0.10
        var path = Path()
        path.move(to: CGPoint(x: rect.minX + radius, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX - radius, y: rect.minY))
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX - radius * 0.45, y: rect.minY + radius),
            control: CGPoint(x: rect.maxX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.midX + radius * 0.5, y: rect.maxY - radius))
        path.addQuadCurve(
            to: CGPoint(x: rect.midX - radius * 0.5, y: rect.maxY - radius),
            control: CGPoint(x: rect.midX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX + radius * 0.45, y: rect.minY + radius))
        path.addQuadCurve(
            to: CGPoint(x: rect.minX + radius, y: rect.minY),
            control: CGPoint(x: rect.minX, y: rect.minY))
        path.closeSubpath()
        return path
    }
}
