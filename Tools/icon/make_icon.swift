import AppKit

// Draws the app icon (macOS grid: 824 pt artwork in a 1024 canvas) and writes every size of
// App/Resources/Assets.xcassets/AppIcon.appiconset. Run: xcrun swift Tools/icon/make_icon.swift
let out = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "App/Resources/Assets.xcassets/AppIcon.appiconset")
try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

func draw(_ size: Int) -> Data {
    let s = CGFloat(size) / 1024
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext
    ctx.scaleBy(x: s, y: s)
    // Squircle-ish tile with a soft shadow.
    let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
    let path = CGPath(roundedRect: tile, cornerWidth: 185, cornerHeight: 185, transform: nil)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: NSColor.black.withAlphaComponent(0.35).cgColor)
    ctx.addPath(path); ctx.setFillColor(NSColor(red: 0.13, green: 0.17, blue: 0.23, alpha: 1).cgColor); ctx.fillPath()
    ctx.restoreGState()
    ctx.saveGState()
    ctx.addPath(path); ctx.clip()
    let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                              colors: [NSColor(red: 0.20, green: 0.26, blue: 0.35, alpha: 1).cgColor,
                                       NSColor(red: 0.09, green: 0.12, blue: 0.17, alpha: 1).cgColor] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(gradient, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])
    // Faint blueprint grid.
    ctx.setStrokeColor(NSColor(red: 0.45, green: 0.62, blue: 0.85, alpha: 0.10).cgColor)
    ctx.setLineWidth(3)
    for i in stride(from: 100.0, through: 924.0, by: 68.7) {
        ctx.move(to: CGPoint(x: i, y: 100)); ctx.addLine(to: CGPoint(x: i, y: 924))
        ctx.move(to: CGPoint(x: 100, y: i)); ctx.addLine(to: CGPoint(x: 924, y: i))
    }
    ctx.strokePath()
    // Isometric L bracket (plate + upright flange) with a hole, centred on the tile.
    // Object mm-like units: plate 320 × 300 × 40, flange 40 thick and 260 tall on the far edge.
    func raw(_ x: CGFloat, _ y: CGFloat, _ z: CGFloat) -> CGPoint { CGPoint(x: (x - y) * 0.866, y: -(x + y) * 0.5 + z) }
    let corners = [raw(0, 0, 260), raw(320, 0, 0), raw(0, 340, 0), raw(320, 340, 0), raw(0, 0, 0), raw(40, 0, 260)]
    let minX = corners.map(\.x).min()!, maxX = corners.map(\.x).max()!, minY = corners.map(\.y).min()!, maxY = corners.map(\.y).max()!
    let k = min(560 / (maxX - minX), 560 / (maxY - minY))
    func iso(_ x: CGFloat, _ y: CGFloat, _ z: CGFloat) -> CGPoint {
        let p = raw(x, y, z)
        return CGPoint(x: 512 + (p.x - (minX + maxX) / 2) * k, y: 500 + (p.y - (minY + maxY) / 2) * k)
    }
    func poly(_ pts: [CGPoint], _ c: NSColor) {
        ctx.beginPath(); ctx.move(to: pts[0]); for p in pts.dropFirst() { ctx.addLine(to: p) }; ctx.closePath()
        ctx.setFillColor(c.cgColor); ctx.fillPath()
    }
    let orange = NSColor(red: 0.95, green: 0.55, blue: 0.16, alpha: 1)
    let light = NSColor(red: 1.0, green: 0.74, blue: 0.40, alpha: 1)
    let dark = NSColor(red: 0.72, green: 0.36, blue: 0.07, alpha: 1)
    // Plate.
    poly([iso(40, 0, 40), iso(320, 0, 40), iso(320, 300, 40), iso(40, 300, 40)], light)
    poly([iso(320, 0, 0), iso(320, 300, 0), iso(320, 300, 40), iso(320, 0, 40)], orange)
    poly([iso(0, 300, 0), iso(320, 300, 0), iso(320, 300, 40), iso(0, 300, 40)], dark)
    // Flange.
    poly([iso(40, 0, 40), iso(40, 300, 40), iso(40, 300, 260), iso(40, 0, 260)], orange)
    poly([iso(0, 0, 260), iso(40, 0, 260), iso(40, 300, 260), iso(0, 300, 260)], light)
    poly([iso(0, 300, 0), iso(40, 300, 0), iso(40, 300, 260), iso(0, 300, 260)], dark)
    // Hole through the plate (isometric ellipse) and a hole in the flange.
    func hole(_ c: CGPoint, _ rx: CGFloat, _ ry: CGFloat) {
        ctx.setFillColor(NSColor(red: 0.11, green: 0.14, blue: 0.19, alpha: 1).cgColor)
        ctx.fillEllipse(in: CGRect(x: c.x - rx, y: c.y - ry, width: 2 * rx, height: 2 * ry))
    }
    hole(iso(200, 150, 40), 60 * k * 0.95, 34 * k * 0.95)
    // Blue dimension line in front of the plate.
    ctx.setStrokeColor(NSColor(red: 0.35, green: 0.69, blue: 1, alpha: 1).cgColor)
    ctx.setLineWidth(12 * k); ctx.setLineCap(.round)
    ctx.move(to: iso(0, 345, 0)); ctx.addLine(to: iso(320, 345, 0))
    for x in [CGFloat(0), 320] { ctx.move(to: iso(x, 320, 0)); ctx.addLine(to: iso(x, 370, 0)) }
    ctx.strokePath()
    ctx.restoreGState()
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

var images: [[String: String]] = []
for (points, scales) in [(16, [1, 2]), (32, [1, 2]), (128, [1, 2]), (256, [1, 2]), (512, [1, 2])] {
    for scale in scales {
        let px = points * scale
        let file = "icon_\(points)x\(points)\(scale == 2 ? "@2x" : "").png"
        try draw(px).write(to: out.appendingPathComponent(file))
        images.append(["idiom": "mac", "size": "\(points)x\(points)", "scale": "\(scale)x", "filename": file])
    }
}
let contents: [String: Any] = ["images": images, "info": ["author": "xcode", "version": 1]]
try JSONSerialization.data(withJSONObject: contents, options: [.prettyPrinted, .sortedKeys])
    .write(to: out.appendingPathComponent("Contents.json"))
let catalog = out.deletingLastPathComponent()
try #"{"info":{"author":"xcode","version":1}}"#.write(to: catalog.appendingPathComponent("Contents.json"), atomically: true, encoding: .utf8)
print("App icon written to \(out.path)")
