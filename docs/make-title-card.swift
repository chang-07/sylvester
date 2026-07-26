// Composes docs/title-card.png — the README hero. Dark banner: icon + "Sylvester" lockup and
// tagline on the left, the app screenshot (rounded, shadowed, bottom noise cropped) on the right.
// Usage: swift docs/make-title-card.swift   (run from repo root)
import AppKit

let W = 1200, H = 630
let rep = NSBitmapImageRep(
    bitmapDataPlanes: nil, pixelsWide: W, pixelsHigh: H,
    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
)!
NSGraphicsContext.saveGraphicsState()
let gctx = NSGraphicsContext(bitmapImageRep: rep)!
NSGraphicsContext.current = gctx
let cg = gctx.cgContext
let space = CGColorSpaceCreateDeviceRGB()
let w = CGFloat(W), h = CGFloat(H)

// Dark diagonal background.
let bg = CGGradient(colorsSpace: space, colors: [
    NSColor(srgbRed: 0.070, green: 0.090, blue: 0.110, alpha: 1).cgColor,
    NSColor(srgbRed: 0.039, green: 0.051, blue: 0.067, alpha: 1).cgColor,
] as CFArray, locations: [0, 1])!
cg.drawLinearGradient(bg, start: CGPoint(x: 0, y: h), end: CGPoint(x: w, y: 0), options: [])

// Subtle teal brand glow behind the lockup.
let glowC = CGPoint(x: 150, y: h - 250)
let glow = CGGradient(colorsSpace: space, colors: [
    NSColor(srgbRed: 0.85, green: 0.83, blue: 0.78, alpha: 0.16).cgColor,
    NSColor(srgbRed: 0.85, green: 0.83, blue: 0.78, alpha: 0.0).cgColor,
] as CFArray, locations: [0, 1])!
cg.drawRadialGradient(glow, startCenter: glowC, startRadius: 0, endCenter: glowC, endRadius: 300, options: [])

func draw(_ s: String, x: CGFloat, y: CGFloat, size: CGFloat, weight: NSFont.Weight, color: NSColor) {
    let base = NSFont.systemFont(ofSize: size, weight: weight)
    let font = NSFont(descriptor: base.fontDescriptor.withDesign(.rounded) ?? base.fontDescriptor, size: size) ?? base
    NSAttributedString(string: s, attributes: [.font: font, .foregroundColor: color]).draw(at: CGPoint(x: x, y: y))
}

// Icon + wordmark lockup (side by side), vertically centered around y = 372.
let iconSize: CGFloat = 132
let iconRect = CGRect(x: 82, y: 372 - iconSize / 2, width: iconSize, height: iconSize)
if let icon = NSImage(contentsOfFile: "icon/AppIcon.svg") {
    icon.draw(in: iconRect)
}
draw("Sylvester", x: iconRect.maxX + 26, y: 372 - 26, size: 62, weight: .bold, color: .white)

// Cream accent underline, picking up the icon tile rather than a retired brand colour.
let accent = CGRect(x: iconRect.maxX + 30, y: 372 - 44, width: 196, height: 7)
cg.saveGState()
let accentGrad = CGGradient(colorsSpace: space, colors: [
    NSColor(srgbRed: 0.98, green: 0.97, blue: 0.94, alpha: 1).cgColor,
    NSColor(srgbRed: 0.98, green: 0.97, blue: 0.94, alpha: 0.15).cgColor,
] as CFArray, locations: [0, 1])!
cg.addPath(CGPath(roundedRect: accent, cornerWidth: 3.5, cornerHeight: 3.5, transform: nil))
cg.clip()
cg.drawLinearGradient(accentGrad, start: CGPoint(x: accent.minX, y: 0), end: CGPoint(x: accent.maxX, y: 0), options: [])
cg.restoreGState()

// Tagline + meta.
draw("Your net worth, every brokerage — right in the menubar.",
     x: 84, y: 264, size: 25, weight: .medium, color: NSColor(srgbRed: 0.64, green: 0.68, blue: 0.72, alpha: 1))
draw("macOS menubar app · via SnapTrade · read-only, keys stay on your Mac",
     x: 84, y: 224, size: 15.5, weight: .regular, color: NSColor(srgbRed: 0.42, green: 0.46, blue: 0.50, alpha: 1))

// Screenshot on the right: crop the terminal noise off the bottom, round + shadow.
if let shot = NSImage(contentsOfFile: "docs/screenshot-raw.png") {
    let cropBottom: CGFloat = 0    // rendered mock — nothing to trim
    let from = CGRect(x: 0, y: cropBottom, width: shot.size.width, height: shot.size.height - cropBottom)
    let destH: CGFloat = 566
    let destW = destH * (from.width / from.height)
    let dest = CGRect(x: w - destW - 76, y: (h - destH) / 2, width: destW, height: destH)
    let rr = CGPath(roundedRect: dest, cornerWidth: 18, cornerHeight: 18, transform: nil)

    cg.saveGState()
    cg.setShadow(offset: CGSize(width: 0, height: -12), blur: 36, color: NSColor.black.withAlphaComponent(0.55).cgColor)
    cg.addPath(rr); cg.setFillColor(NSColor.black.cgColor); cg.fillPath()
    cg.restoreGState()

    cg.saveGState()
    cg.addPath(rr); cg.clip()
    shot.draw(in: dest, from: from, operation: .sourceOver, fraction: 1.0)
    cg.restoreGState()

    cg.saveGState()
    cg.addPath(rr)
    cg.setStrokeColor(NSColor.white.withAlphaComponent(0.09).cgColor); cg.setLineWidth(1.5); cg.strokePath()
    cg.restoreGState()
}

NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "docs/title-card.png"))
print("wrote docs/title-card.png (\(W)x\(H))")
