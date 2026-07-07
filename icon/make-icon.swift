// Renders the SnapBar app icon into an .iconset directory (one PNG per macOS size).
// Style kinship with SnapTrade: rounded hexagon silhouette + the teal/gold palette.
// Distinct: the interior is SnapBar's own mark — ascending bars (net worth) in gold on a
// teal hexagon, rather than SnapTrade's interlocking "S".
// Usage: swift make-icon.swift <output.iconset dir>
import AppKit

// Rounded-corner regular hexagon (pointy top/bottom), centered.
func roundedHex(center c: CGPoint, radius r: CGFloat, corner: CGFloat) -> CGPath {
    var pts: [CGPoint] = []
    for i in 0..<6 {
        let a = Double(90 + 60 * i) * .pi / 180
        pts.append(CGPoint(x: c.x + r * CGFloat(cos(a)), y: c.y + r * CGFloat(sin(a))))
    }
    func mid(_ p: CGPoint, _ q: CGPoint) -> CGPoint { CGPoint(x: (p.x + q.x) / 2, y: (p.y + q.y) / 2) }
    let path = CGMutablePath()
    path.move(to: mid(pts[5], pts[0]))
    for i in 0..<6 { path.addArc(tangent1End: pts[i], tangent2End: pts[(i + 1) % 6], radius: corner) }
    path.closeSubpath()
    return path
}

func drawIcon(pixel: Int) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: pixel, pixelsHigh: pixel,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    )!
    rep.size = NSSize(width: pixel, height: pixel)
    NSGraphicsContext.saveGraphicsState()
    let gctx = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.current = gctx
    let cg = gctx.cgContext
    let s = CGFloat(pixel)
    let space = CGColorSpaceCreateDeviceRGB()
    cg.clear(CGRect(x: 0, y: 0, width: s, height: s))

    let center = CGPoint(x: s / 2, y: s / 2)
    let radius = s * 0.435
    let hex = roundedHex(center: center, radius: radius, corner: s * 0.085)

    // Soft ambient shadow so the mark reads on light Finder/Spotlight backgrounds.
    cg.saveGState()
    cg.setShadow(offset: CGSize(width: 0, height: -s * 0.012), blur: s * 0.03,
                 color: NSColor.black.withAlphaComponent(0.22).cgColor)
    cg.addPath(hex)
    cg.setFillColor(NSColor.black.cgColor)   // placeholder fill just to cast the shadow
    cg.fillPath()
    cg.restoreGState()

    // Teal hexagon (SnapTrade's teal), lighter top-left → deeper bottom-right.
    cg.saveGState()
    cg.addPath(hex)
    cg.clip()
    let teal = CGGradient(colorsSpace: space, colors: [
        NSColor(srgbRed: 0.204, green: 0.655, blue: 0.600, alpha: 1).cgColor,
        NSColor(srgbRed: 0.098, green: 0.451, blue: 0.416, alpha: 1).cgColor,
    ] as CFArray, locations: [0, 1])!
    cg.drawLinearGradient(teal, start: CGPoint(x: center.x - radius, y: center.y + radius),
                          end: CGPoint(x: center.x + radius, y: center.y - radius), options: [])
    // Faint top highlight for depth.
    let hi = CGGradient(colorsSpace: space, colors: [
        NSColor.white.withAlphaComponent(0.14).cgColor,
        NSColor.white.withAlphaComponent(0.0).cgColor,
    ] as CFArray, locations: [0, 1])!
    cg.drawLinearGradient(hi, start: CGPoint(x: center.x, y: center.y + radius),
                          end: CGPoint(x: center.x, y: center.y), options: [])
    cg.restoreGState()

    // Ascending gold bars (SnapTrade's gold), centered in the hexagon.
    let contentW = radius * 1.16
    let contentH = radius * 1.04
    let content = CGRect(x: center.x - contentW / 2, y: center.y - contentH / 2, width: contentW, height: contentH)
    let n = 3
    let gap = content.width * 0.11
    let barW = (content.width - gap * CGFloat(n - 1)) / CGFloat(n)
    let heights: [CGFloat] = [0.5, 0.73, 1.0]
    let gold = CGGradient(colorsSpace: space, colors: [
        NSColor(srgbRed: 0.965, green: 0.706, blue: 0.318, alpha: 1).cgColor,  // top (brighter)
        NSColor(srgbRed: 0.894, green: 0.529, blue: 0.106, alpha: 1).cgColor,  // bottom
    ] as CFArray, locations: [0, 1])!
    for i in 0..<n {
        let h = content.height * heights[i]
        let x = content.minX + CGFloat(i) * (barW + gap)
        let bar = CGRect(x: x, y: content.minY, width: barW, height: h)
        let cr = min(barW * 0.34, h * 0.5)
        cg.saveGState()
        cg.addPath(CGPath(roundedRect: bar, cornerWidth: cr, cornerHeight: cr, transform: nil))
        cg.clip()
        cg.drawLinearGradient(gold, start: CGPoint(x: 0, y: bar.maxY), end: CGPoint(x: 0, y: bar.minY), options: [])
        cg.restoreGState()
    }

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

let outDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.iconset"
try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)
let sizes: [(String, Int)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32),
    ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256),
    ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]
for (name, px) in sizes {
    let rep = drawIcon(pixel: px)
    guard let data = rep.representation(using: .png, properties: [:]) else {
        FileHandle.standardError.write(Data("failed to encode \(name)\n".utf8)); exit(1)
    }
    try! data.write(to: URL(fileURLWithPath: outDir).appendingPathComponent("\(name).png"))
    print("wrote \(name).png (\(px)px)")
}
