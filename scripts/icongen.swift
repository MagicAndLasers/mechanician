import AppKit
import CoreGraphics

// Args: <banner.png> <outdir> <cropX> <cropY> <cropW> <cropH>
//
// Regenerate the shipped icon from the design master (a 1407x768 white-background
// figure banner). The crop is generous around the figure — the auto-trim below
// tightens it — and excludes the faint corner sparkle:
//   swift scripts/icongen.swift app/Resources/figure-source.png /tmp/out 380 0 680 768
//   iconutil -c icns /tmp/out/Mechanician.iconset -o app/Resources/Mechanician.icns
let a = CommandLine.arguments
let bannerPath = a[1], outDir = a[2]
let cropX = Double(a[3])!, cropY = Double(a[4])!, cropW = Double(a[5])!, cropH = Double(a[6])!

guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: bannerPath) as CFURL, nil),
      let banner = CGImageSourceCreateImageAtIndex(src, 0, nil) else { fatalError("load") }

let generous = banner.cropping(to: CGRect(x: cropX, y: cropY, width: cropW, height: cropH))!

// Auto-trim near-white margins so the figure is tight and centers cleanly.
func trim(_ img: CGImage) -> CGImage {
    let w = img.width, h = img.height, bpr = w * 4
    var data = [UInt8](repeating: 255, count: h * bpr)
    let cs = CGColorSpaceCreateDeviceRGB()
    let ctx = CGContext(data: &data, width: w, height: h, bitsPerComponent: 8,
                        bytesPerRow: bpr, space: cs,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
    var minX = w, minY = h, maxX = -1, maxY = -1
    // Horizontal extent uses a light threshold so the pale blouse/sleeve still counts.
    // Vertical extent uses a dark threshold: only substantive ink (the near-black hat,
    // skirt, and tools) bounds top/bottom, so any faint halo above the hat is ignored —
    // otherwise it renders as wasted "sky" once the white multiplies into the background.
    let tLight: UInt8 = 232
    let tDark: UInt8 = 110
    let minInkPerRow = 6 // a real ink row (the hat) has hundreds; speckle has a handful
    for y in 0..<h {
        let row = y * bpr
        var darkInRow = 0
        for x in 0..<w {
            let i = row + x * 4
            let r = data[i], g = data[i + 1], b = data[i + 2]
            if r < tLight || g < tLight || b < tLight {
                if x < minX { minX = x }; if x > maxX { maxX = x }
            }
            if r < tDark && g < tDark && b < tDark { darkInRow += 1 }
        }
        if darkInRow >= minInkPerRow {
            if y < minY { minY = y }; if y > maxY { maxY = y }
        }
    }
    guard maxX >= minX, maxY >= minY else { return img }
    let pad = 3
    let x0 = max(0, minX - pad), y0 = max(0, minY - pad)
    let x1 = min(w - 1, maxX + pad), y1 = min(h - 1, maxY + pad)
    // Context buffer is bottom-up; CGImage crop is top-left — flip Y.
    let cropTopY = h - 1 - y1
    return img.cropping(to: CGRect(x: x0, y: cropTopY, width: x1 - x0 + 1, height: y1 - y0 + 1)) ?? img
}

let figure = trim(generous)
let fw = CGFloat(figure.width), fh = CGFloat(figure.height)

// Tunable layout — adjust and re-render the preview to taste.
let kInset: CGFloat = 0.085       // transparent margin (macOS icons sit at ~80% of canvas)
let kFigureTop: CGFloat = 0.06    // margin above the hat, as a fraction of the rect height
let kFigureShiftX: CGFloat = 0.0  // horizontal nudge, as a fraction of the rect width
let kGradientMid: CGFloat = 0.42  // where the light field starts ramping toward Nord blue

// Glass gloss — the icon reads as if it sits under a polished pane. Every value is a fraction
// of the rounded rect, so the effect scales cleanly from 16px to 1024px. Three cues do the
// work: a soft convex top sheen, a bright bevel line hugging the top edge, and a catch-light
// pooling at the bottom edge. Dial to taste and re-render the preview.
let kGlossDomePeak: CGFloat = 0.34    // strength of the top specular sheen (0 disables gloss look)
let kGlossDomeReach: CGFloat = 0.46   // how far down the sheen fades, as a fraction of height
let kGlossTopEdge: CGFloat = 0.55     // bright bevel line hugging the top edge
let kGlossBottomEdge: CGFloat = 0.22  // catch-light pooling at the bottom edge
let kGlossBottomGlow: CGFloat = 0.06  // faint reflection glow off the bottom

func white(_ a: CGFloat) -> CGColor { CGColor(red: 1, green: 1, blue: 1, alpha: a) }

// Polished-glass gloss, drawn over the figure so the whole icon reads as if under glass. All
// gloss is clipped to the rounded rect so it stays within the squircle.
func drawGloss(_ ctx: CGContext, _ rect: CGRect, _ r: CGFloat, _ cs: CGColorSpace) {
    ctx.saveGState()
    ctx.addPath(CGPath(roundedRect: rect, cornerWidth: r, cornerHeight: r, transform: nil))
    ctx.clip()

    // Convex top sheen: clip to a wide ellipse centered above the icon whose lower arc dips
    // into the upper region (lowest at center), then paint a fading white vertical gradient —
    // the specular highlight of light hitting a curved glass surface.
    do {
        ctx.saveGState()
        let a = rect.width * 0.95                                  // semi-width, wider than the icon
        let cy = rect.maxY + rect.height * 0.18                    // ellipse center sits above the top edge
        let b = cy - (rect.maxY - rect.height * kGlossDomeReach)   // semi-height so the arc reaches `reach` down
        ctx.addEllipse(in: CGRect(x: rect.midX - a, y: cy - b, width: a * 2, height: b * 2))
        ctx.clip()
        let g = CGGradient(colorsSpace: cs,
                           colors: [white(kGlossDomePeak), white(kGlossDomePeak * 0.28), white(0)] as CFArray,
                           locations: [0.0, 0.5, 1.0])!
        ctx.drawLinearGradient(g, start: CGPoint(x: rect.midX, y: rect.maxY),
                               end: CGPoint(x: rect.midX, y: rect.maxY - rect.height * kGlossDomeReach), options: [])
        ctx.restoreGState()
    }

    // Bright bevel line hugging the inside of the top edge (a thin ring, painted only over its
    // top half so the light gathers along the top rim and fades toward the sides).
    do {
        ctx.saveGState()
        ctx.addPath(CGPath(roundedRect: rect.insetBy(dx: rect.width * 0.006, dy: rect.width * 0.006),
                           cornerWidth: r, cornerHeight: r, transform: nil))
        ctx.addPath(CGPath(roundedRect: rect.insetBy(dx: rect.width * 0.05, dy: rect.width * 0.05),
                           cornerWidth: r * 0.7, cornerHeight: r * 0.7, transform: nil))
        ctx.clip(using: .evenOdd)
        let g = CGGradient(colorsSpace: cs, colors: [white(0), white(kGlossTopEdge)] as CFArray,
                           locations: [0.0, 1.0])!
        ctx.drawLinearGradient(g, start: CGPoint(x: rect.midX, y: rect.midY),
                               end: CGPoint(x: rect.midX, y: rect.maxY), options: [])
        ctx.restoreGState()
    }

    // Slab catch-light pooling at the bottom edge, so the icon reads as a thick pane of glass
    // with light gathering at its base rather than a flat sticker.
    do {
        ctx.saveGState()
        ctx.addPath(CGPath(roundedRect: rect.insetBy(dx: rect.width * 0.006, dy: rect.width * 0.006),
                           cornerWidth: r, cornerHeight: r, transform: nil))
        ctx.addPath(CGPath(roundedRect: rect.insetBy(dx: rect.width * 0.045, dy: rect.width * 0.045),
                           cornerWidth: r * 0.7, cornerHeight: r * 0.7, transform: nil))
        ctx.clip(using: .evenOdd)
        let g = CGGradient(colorsSpace: cs, colors: [white(kGlossBottomEdge), white(0)] as CFArray,
                           locations: [0.0, 1.0])!
        ctx.drawLinearGradient(g, start: CGPoint(x: rect.midX, y: rect.minY),
                               end: CGPoint(x: rect.midX, y: rect.midY), options: [])
        ctx.restoreGState()
    }

    // Faint reflection glow lifting off the bottom edge — rounds out the slab read.
    do {
        ctx.saveGState()
        let g = CGGradient(colorsSpace: cs, colors: [white(0), white(kGlossBottomGlow)] as CFArray,
                           locations: [0.0, 1.0])!
        ctx.drawLinearGradient(g, start: CGPoint(x: rect.midX, y: rect.minY + rect.height * 0.30),
                               end: CGPoint(x: rect.midX, y: rect.minY), options: [])
        ctx.restoreGState()
    }

    ctx.restoreGState()
}

func renderIcon(size: Int) -> CGImage {
    let s = CGFloat(size)
    let cs = CGColorSpaceCreateDeviceRGB()
    let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8,
                        bytesPerRow: 0, space: cs,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.interpolationQuality = .high
    // macOS icons are inset within the canvas (transparent margin), so the rounded
    // rect occupies ~80% of the full size — matches other Dock icons' visual size.
    let inset = s * kInset
    let rect = CGRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset)
    let r = rect.width * 0.2237

    ctx.saveGState()
    ctx.addPath(CGPath(roundedRect: rect, cornerWidth: r, cornerHeight: r, transform: nil))
    ctx.clip()

    // Cool vertical gradient: Nord Snow Storm at the top (the figure reads at full
    // contrast) ramping to Polar Night at the bottom — so the dark lower body dissolves
    // into deep Nord blue instead of hitting a hard crop line.
    // Kept light enough throughout that the dark figure — especially the toolbelt and
    // wrench near the bottom — reads clearly. The figure overflows the frame, so the
    // skirt's cropped edge is already off-screen; no dark merge is needed to hide it.
    let snow  = CGColor(red: 0.937, green: 0.949, blue: 0.965, alpha: 1) // #EFF2F6 (top)
    let snow2 = CGColor(red: 0.847, green: 0.871, blue: 0.914, alpha: 1) // #D8DEE9
    let cool  = CGColor(red: 0.667, green: 0.706, blue: 0.784, alpha: 1) // #AAB4C8 (bottom)
    if let g = CGGradient(colorsSpace: cs, colors: [snow, snow2, cool] as CFArray,
                          locations: [0.0, kGradientMid, 1.0]) {
        ctx.drawLinearGradient(g, start: CGPoint(x: rect.midX, y: rect.maxY),
                               end: CGPoint(x: rect.midX, y: rect.minY), options: [])
    }

    // The figure, multiply-blended: its white background multiplies to the gradient
    // (vanishes) while its ink darkens whatever is behind it, so the dark skirt reads
    // seamlessly over the dark-blue bottom.
    //
    // Height-fit: the figure spans from a small margin below the top edge (so the full
    // hat is visible) down to the bottom edge, so the source's cropped bottom edge lands
    // exactly on the icon's bottom — the figure reads as grounded, not floating. Scale is
    // driven by height; width follows the figure's aspect. (draw(_:in:) puts the image's
    // top at the draw rect's maxY in this bottom-up context.)
    let topMargin = rect.height * kFigureTop
    let dh = rect.height - topMargin
    let scale = dh / fh
    let dw = fw * scale
    let fx = rect.midX - dw / 2 + rect.width * kFigureShiftX
    ctx.setBlendMode(.multiply)
    ctx.draw(figure, in: CGRect(x: fx, y: rect.minY, width: dw, height: dh))
    ctx.setBlendMode(.normal)
    ctx.restoreGState()

    // Glass gloss sits over the figure — the whole icon reads as if behind a polished pane.
    drawGloss(ctx, rect, r, cs)

    // Thin inner border for crisp definition against light Dock backgrounds.
    ctx.addPath(CGPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5),
                       cornerWidth: r, cornerHeight: r, transform: nil))
    ctx.setStrokeColor(CGColor(red: 0.10, green: 0.11, blue: 0.13, alpha: 0.30))
    ctx.setLineWidth(max(1, s * 0.006))
    ctx.strokePath()

    return ctx.makeImage()!
}

func writePNG(_ img: CGImage, to path: String) {
    let rep = NSBitmapImageRep(cgImage: img)
    try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: path))
}

writePNG(renderIcon(size: 1024), to: "\(outDir)/preview-1024.png")

let iconset = "\(outDir)/Mechanician.iconset"
try? FileManager.default.createDirectory(atPath: iconset, withIntermediateDirectories: true)
for (px, name) in [(16, "icon_16x16"), (32, "icon_16x16@2x"), (32, "icon_32x32"),
                   (64, "icon_32x32@2x"), (128, "icon_128x128"), (256, "icon_128x128@2x"),
                   (256, "icon_256x256"), (512, "icon_256x256@2x"), (512, "icon_512x512"),
                   (1024, "icon_512x512@2x")] {
    writePNG(renderIcon(size: px), to: "\(iconset)/\(name).png")
}
print("done")
