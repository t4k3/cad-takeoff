import ElectronicsCore
import SwiftUI

/// The CAM artwork of an imported board as paths in board millimetres, built once per package:
/// each primitive's shapes in order (dark adds, clear removes, inside that primitive only), then
/// the primitive on its layer by its own polarity — the engine's contract, nothing re-interpreted.
struct CAMDrawing {
    struct Part { var path: Path; var width: CGFloat?; var filled = true; var isDark: Bool }
    struct Item { var parts: [Part]; var isDark: Bool; var simple: Bool }
    struct Layer { var kind: FabricationLayerKind; var name: String; var items: [Item] }
    var layers: [Layer]
    var drills: [(path: Path, width: CGFloat, plated: Bool)]

    init(_ package: ManufacturingPackage) {
        func cg(_ p: PCBPoint) -> CGPoint { CGPoint(x: p.x, y: p.y) }
        layers = package.layers.map { layer in
            Layer(kind: layer.kind, name: layer.name, items: layer.primitives.map { primitive in
                let parts = primitive.shapes.compactMap { shape -> Part? in
                    var path = Path()
                    if shape.radius > 0 {
                        // A point: a disk; two points: a capsule; a polygon: filled, its border
                        // widened by the radius (a stroke with round ends and joins).
                        var filled = false
                        for c in shape.contours where !c.isEmpty {
                            path.move(to: cg(c[0]))
                            if c.count == 1 { path.addLine(to: cg(c[0])) }
                            for p in c.dropFirst() { path.addLine(to: cg(p)) }
                            if c.count > 2 { path.closeSubpath(); filled = true }
                        }
                        return path.isEmpty ? nil : Part(path: path, width: 2 * shape.radius, filled: filled, isDark: shape.isDark)
                    }
                    for c in shape.contours where c.count > 2 { path.addLines(c.map(cg)); path.closeSubpath() }
                    return path.isEmpty ? nil : Part(path: path, width: nil, isDark: shape.isDark)
                }
                return Item(parts: parts, isDark: primitive.isDark, simple: parts.allSatisfy(\.isDark))
            })
        }
        drills = package.drills.map { d in
            var path = Path()
            path.move(to: cg(d.position)); path.addLine(to: cg(d.end ?? d.position))
            return (path, d.diameter, d.isPlated)
        }
    }

    /// Bottom side first, the inner copper upwards (the last inner layer is the lowest), the top
    /// over it, the outline last.
    static let order: [FabricationLayerKind] = [.bottomSilkscreen, .bottomPaste, .bottomMask, .bottomCopper]
        + (1...30).reversed().compactMap(FabricationLayerKind.inner)
        + [.topCopper, .topMask, .topPaste, .topSilkscreen, .profile]

    /// Inner layers start switched off: their planes would cover everything.
    static let innerLayers = Set(FabricationLayerKind.allCases.filter { $0.innerIndex != nil })

    static func colour(_ kind: FabricationLayerKind) -> (Color, Double) {
        switch kind {
        case .topCopper: (Color(red: 0.86, green: 0.52, blue: 0.24), 0.9)
        case .bottomCopper: (Color(red: 0.33, green: 0.55, blue: 0.95), 0.7)
        case .topMask, .bottomMask: (Color(red: 0.2, green: 0.8, blue: 0.4), 0.45)
        case .topPaste, .bottomPaste: (Color(white: 0.75), 0.6)
        case .topSilkscreen: (Color.white, 0.9)
        case .bottomSilkscreen: (Color(white: 0.75), 0.6)
        case .profile: (Color.yellow, 1)
        default:
            // Inner copper: alternating violet and teal, so neighbours differ.
            (kind.innerIndex.map { $0.isMultiple(of: 2) } == true ? Color(red: 0.3, green: 0.75, blue: 0.7) : Color(red: 0.72, green: 0.45, blue: 0.9), 0.65)
        }
    }

    static func mm(_ v: Double) -> String { v.formatted(.number.precision(.fractionLength(0...2))) + " mm" }

    static func name(_ kind: FabricationLayerKind) -> String {
        switch kind {
        case .topCopper: "Rame sopra"; case .bottomCopper: "Rame sotto"
        case .topMask: "Maschera sopra"; case .bottomMask: "Maschera sotto"
        case .topPaste: "Pasta sopra"; case .bottomPaste: "Pasta sotto"
        case .topSilkscreen: "Serigrafia sopra"; case .bottomSilkscreen: "Serigrafia sotto"
        case .profile: "Contorno"
        default: "Rame interno \(kind.innerIndex ?? 0)"
        }
    }

    /// How a finished board looks from one side: green solder mask, copper under it a lighter
    /// green, gold where the mask is open, white silkscreen (for the assembled views).
    static func finished(_ kind: FabricationLayerKind) -> (Color, Double) {
        switch kind {
        case .topCopper, .bottomCopper: (Color(red: 0.16, green: 0.46, blue: 0.24), 1)
        case .topMask, .bottomMask: (Color(red: 0.83, green: 0.69, blue: 0.36), 1)
        case .topSilkscreen, .bottomSilkscreen: (Color(white: 0.95), 1)
        case .topPaste, .bottomPaste, .profile: (.clear, 0)
        default: (.clear, 0)   // inner copper: inside the laminate, not seen
        }
    }
    static let maskGreen = Color(red: 0.07, green: 0.34, blue: 0.16)

    /// The layers of one side of the finished board, from the laminate outwards.
    static func finishedLayers(_ side: BoardSide) -> [FabricationLayerKind] {
        side == .top ? [.topCopper, .topMask, .topSilkscreen] : [.bottomCopper, .bottomMask, .bottomSilkscreen]
    }

    /// Draws the visible layers; `ctx` already maps board millimetres to the screen.
    func draw(_ ctx: inout GraphicsContext, hidden: Set<FabricationLayerKind>, drills showDrills: Bool,
              palette: (FabricationLayerKind) -> (Color, Double) = CAMDrawing.colour,
              order: [FabricationLayerKind] = CAMDrawing.order) {
        for kind in order where !hidden.contains(kind) {
            guard let layer = layers.first(where: { $0.kind == kind }) else { continue }
            let (colour, opacity) = palette(kind)
            guard opacity > 0 else { continue }
            var layerCtx = ctx
            layerCtx.opacity = opacity
            layerCtx.drawLayer { l in
                for item in layer.items {
                    var target = l
                    target.blendMode = item.isDark ? .normal : .destinationOut
                    if item.simple {
                        for part in item.parts { Self.paint(part, in: &target, colour) }
                    } else {
                        target.drawLayer { local in
                            for part in item.parts {
                                var p = local
                                p.blendMode = part.isDark ? .normal : .destinationOut
                                Self.paint(part, in: &p, colour)
                            }
                        }
                    }
                }
            }
        }
        if showDrills {
            for d in drills {
                ctx.stroke(d.path, with: .color(.black), style: StrokeStyle(lineWidth: d.width, lineCap: .round))
                if !d.plated {
                    ctx.stroke(d.path, with: .color(.white.opacity(0.5)),
                               style: StrokeStyle(lineWidth: d.width, lineCap: .round, dash: [0.2, 0.2]))
                }
            }
        }
    }

    private static func paint(_ part: Part, in ctx: inout GraphicsContext, _ colour: Color) {
        if let w = part.width {
            if part.filled { ctx.fill(part.path, with: .color(colour), style: FillStyle(eoFill: true)) }
            ctx.stroke(part.path, with: .color(colour), style: StrokeStyle(lineWidth: w, lineCap: .round, lineJoin: .round))
        } else {
            ctx.fill(part.path, with: .color(colour), style: FillStyle(eoFill: true))
        }
    }
}

/// Board millimetres (Y up) to the view, fitting the board's outline.
struct CAMMapping {
    var scale: CGFloat, origin: CGPoint
    init(bounds: ManufacturingBounds, size: CGSize, zoom: CGFloat = 1, pan: CGSize = .zero, margin: CGFloat = 40) {
        let w = max(bounds.width, 1), h = max(bounds.height, 1)
        let fit = min((size.width - 2 * margin) / w, (size.height - 2 * margin) / h)
        scale = max(fit, 0.5) * zoom
        let centre = CGPoint(x: size.width / 2 + pan.width, y: size.height / 2 + pan.height)
        origin = CGPoint(x: centre.x - (bounds.minimum.x + w / 2) * scale, y: centre.y + (bounds.minimum.y + h / 2) * scale)
    }
    var transform: CGAffineTransform { CGAffineTransform(a: scale, b: 0, c: 0, d: -scale, tx: origin.x, ty: origin.y) }
    func screen(_ p: PCBPoint) -> CGPoint { CGPoint(x: origin.x + p.x * scale, y: origin.y - p.y * scale) }
    func board(_ q: CGPoint) -> PCBPoint { PCBPoint(Double((q.x - origin.x) / scale), Double((origin.y - q.y) / scale)) }
}
