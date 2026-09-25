import CADCore
import Foundation
import Observation
import simd

/// Sketch v0 (T61): UI-only 2D drawing on the XY plane (Z = 0). Shapes are not stored in
/// the design; "Estrudi" turns a closed shape into a solid through the Model's validated,
/// undoable `add_extrude` command. Replaced by the core sketch model once T15 lands (T05).
@MainActor
@Observable
final class SketchSession {
    enum Tool: String, CaseIterable, Identifiable {
        case select = "Seleziona", line = "Linea", rectangle = "Rettangolo", circle = "Cerchio", polygon = "Poligono"
        var id: String { rawValue }
        var symbol: String {
            switch self {
            case .select: "cursorarrow"
            case .line: "line.diagonal"
            case .rectangle: "rectangle"
            case .circle: "circle"
            case .polygon: "hexagon"
            }
        }
        var hint: String {
            switch self {
            case .select: "Clicca dentro un profilo chiuso per selezionarlo, poi Estrudi."
            case .line: "Clicca i vertici. Clicca sul primo punto per chiudere · Invio termina · Esc annulla."
            case .rectangle: "Clicca il primo angolo, poi l'angolo opposto."
            case .circle: "Clicca il centro, poi un punto sulla circonferenza."
            case .polygon: "Clicca il centro, poi un vertice."
            }
        }
    }

    struct Shape: Identifiable, Equatable {
        enum Kind: Equatable {
            case polyline([Vec2], closed: Bool)
            case rectangle(Vec2, Vec2)
            case circle(center: Vec2, radius: Double)
            case polygon(center: Vec2, radius: Double, sides: Int, start: Double)
        }
        let id = UUID()
        var kind: Kind

        static let circleSegments = 64

        /// Vertices of the outline (circles tessellated, closed shapes without repeated first point).
        var outline: [Vec2] {
            switch kind {
            case let .polyline(p, _): return p
            case let .rectangle(a, b):
                return [Vec2(min(a.x, b.x), min(a.y, b.y)), Vec2(max(a.x, b.x), min(a.y, b.y)),
                        Vec2(max(a.x, b.x), max(a.y, b.y)), Vec2(min(a.x, b.x), max(a.y, b.y))]
            case let .circle(c, r):
                return (0..<Self.circleSegments).map { i in
                    let t = Double(i) / Double(Self.circleSegments) * 2 * .pi
                    return Vec2(c.x + r * cos(t), c.y + r * sin(t))
                }
            case let .polygon(c, r, n, start):
                return (0..<n).map { i in
                    let t = start + Double(i) / Double(n) * 2 * .pi
                    return Vec2(c.x + r * cos(t), c.y + r * sin(t))
                }
            }
        }

        var isClosed: Bool { if case let .polyline(_, closed) = kind { closed } else { true } }

        var title: String {
            switch kind {
            case .polyline: "Profilo"
            case let .rectangle(a, b): "Rettangolo \(fmt(abs(b.x - a.x)))×\(fmt(abs(b.y - a.y)))"
            case let .circle(_, r): "Cerchio Ø\(fmt(2 * r))"
            case let .polygon(_, _, n, _): "Poligono a \(n) lati"
            }
        }

        func contains(_ p: Vec2) -> Bool {
            guard isClosed else { return false }
            let v = outline
            var inside = false
            var j = v.count - 1
            for i in v.indices {
                if (v[i].y > p.y) != (v[j].y > p.y),
                   p.x < (v[j].x - v[i].x) * (p.y - v[i].y) / (v[j].y - v[i].y) + v[i].x { inside.toggle() }
                j = i
            }
            return inside
        }
    }

    var tool: Tool = .line { didSet { if tool != oldValue { pending = [] } } }
    private(set) var shapes: [Shape] = []
    var selection: Shape.ID?
    /// Clicked points of the shape being drawn.
    private(set) var pending: [Vec2] = []
    /// Snapped cursor on the plane, and cursor in view points (for the HUD).
    private(set) var cursor: Vec2?
    private(set) var cursorScreen: CGPoint?
    var snapToGrid = true
    var gridStep = 1.0
    var polygonSides = 6
    /// Height shown as wireframe preview while the Extrude panel is open.
    var previewHeight: Double?

    var selectedShape: Shape? { shapes.first { $0.id == selection } }
    var closedShapes: [Shape] { shapes.filter(\.isClosed) }
    /// Shape the Extrude command would use: the selected one, or the only closed one.
    var extrudeCandidate: Shape? {
        if let s = selectedShape, s.isClosed { return s }
        return closedShapes.count == 1 ? closedShapes[0] : nil
    }

    // MARK: Input

    /// Vertex snap radius in mm, from the camera scale (about 8 screen points).
    var vertexSnap = 1.0

    func hover(_ world: SIMD3<Float>?, screen: CGPoint?) {
        cursor = world.map { snap(Vec2(Double($0.x), Double($0.y))) }
        cursorScreen = screen
    }

    func click(_ world: SIMD3<Float>) {
        let p = snap(Vec2(Double(world.x), Double(world.y)))
        switch tool {
        case .select:
            selection = shapes.last { $0.contains(p) }?.id
        case .line:
            if pending.count >= 3, distance(p, pending[0]) < max(vertexSnap, 1e-6) {
                commit(.polyline(pending, closed: true))
            } else if pending.last.map({ distance($0, p) > 1e-6 }) ?? true {
                pending.append(p)
            }
        case .rectangle:
            if let a = pending.first {
                if abs(p.x - a.x) > 1e-6, abs(p.y - a.y) > 1e-6 { commit(.rectangle(a, p)) }
            } else { pending = [p] }
        case .circle:
            if let c = pending.first {
                let r = distance(c, p)
                if r > 1e-6 { commit(.circle(center: c, radius: r)) }
            } else { pending = [p] }
        case .polygon:
            if let c = pending.first {
                let r = distance(c, p)
                if r > 1e-6 { commit(.polygon(center: c, radius: r, sides: polygonSides, start: atan2(p.y - c.y, p.x - c.x))) }
            } else { pending = [p] }
        }
    }

    /// Return key: finishes an open polyline.
    func finish() {
        guard tool == .line, pending.count >= 2 else { return }
        commit(.polyline(pending, closed: false))
    }

    /// Esc: cancels the shape in progress, then the tool.
    func cancel() -> Bool {
        if !pending.isEmpty { pending = []; return true }
        if tool != .select { tool = .select; return true }
        if selection != nil { selection = nil; return true }
        return false
    }

    func deleteSelection() {
        shapes.removeAll { $0.id == selection }
        selection = nil
    }

    func replace(_ id: Shape.ID, with kind: Shape.Kind) {
        guard let i = shapes.firstIndex(where: { $0.id == id }) else { return }
        shapes[i].kind = kind
    }

    private func commit(_ kind: Shape.Kind) {
        let s = Shape(kind: kind)
        shapes.append(s)
        pending = []
        if s.isClosed { selection = s.id }
    }

    private func snap(_ p: Vec2) -> Vec2 {
        // Existing vertices win over the grid.
        let vertices = shapes.flatMap { s -> [Vec2] in
            if case .circle = s.kind { return [] } else { return s.outline }
        } + pending
        if let v = vertices.min(by: { distance($0, p) < distance($1, p) }), distance(v, p) < vertexSnap { return v }
        guard snapToGrid else { return p }
        return Vec2((p.x / gridStep).rounded() * gridStep, (p.y / gridStep).rounded() * gridStep)
    }

    private func distance(_ a: Vec2, _ b: Vec2) -> Double { ((a.x - b.x) * (a.x - b.x) + (a.y - b.y) * (a.y - b.y)).squareRoot() }

    // MARK: Live measurements (HUD)

    var liveMeasure: String? {
        guard let c = cursor else { return nil }
        switch tool {
        case .line:
            guard let last = pending.last else { return "X \(fmt(c.x))  Y \(fmt(c.y))" }
            let d = distance(last, c)
            let a = atan2(c.y - last.y, c.x - last.x) * 180 / .pi
            return "\(fmt(d)) mm · \(fmt(a))°"
        case .rectangle:
            guard let a = pending.first else { return "X \(fmt(c.x))  Y \(fmt(c.y))" }
            return "\(fmt(abs(c.x - a.x))) × \(fmt(abs(c.y - a.y))) mm"
        case .circle:
            guard let ctr = pending.first else { return "Centro X \(fmt(c.x))  Y \(fmt(c.y))" }
            return "Ø \(fmt(2 * distance(ctr, c))) mm"
        case .polygon:
            guard let ctr = pending.first else { return "Centro X \(fmt(c.x))  Y \(fmt(c.y))" }
            return "R \(fmt(distance(ctr, c))) mm · \(polygonSides) lati"
        case .select:
            return nil
        }
    }

    // MARK: Drawing (world-space line segments for the Metal overlay)

    typealias Line = (SIMD3<Float>, SIMD3<Float>, SIMD4<Float>)

    func overlay(sketchColor: SIMD4<Float>, selectedColor: SIMD4<Float>, previewColor: SIMD4<Float>) -> [Line] {
        var out: [Line] = []
        func w(_ p: Vec2, _ z: Double = 0) -> SIMD3<Float> { SIMD3(Float(p.x), Float(p.y), Float(z) + 0.02) }
        func ring(_ pts: [Vec2], closed: Bool, _ color: SIMD4<Float>, z: Double = 0) {
            guard pts.count >= 2 else { return }
            for i in 0..<(closed ? pts.count : pts.count - 1) {
                out.append((w(pts[i], z), w(pts[(i + 1) % pts.count], z), color))
            }
        }
        for s in shapes {
            let selected = s.id == selection
            ring(s.outline, closed: s.isClosed, selected ? selectedColor : sketchColor)
            if selected, let h = previewHeight, h > 0, s.isClosed {
                ring(s.outline, closed: true, previewColor, z: h)
                let step = max(1, s.outline.count / 16)
                for (i, p) in s.outline.enumerated() where i % step == 0 { out.append((w(p), w(p, h), previewColor)) }
            }
            // Vertex ticks.
            if case .circle = s.kind {} else {
                for p in s.outline { out += cross(p, size: vertexSnap * 0.35, color: selected ? selectedColor : sketchColor) }
            }
        }
        // Shape in progress, rubber-banded to the cursor.
        if let c = cursor, !pending.isEmpty {
            let rubber = sketchColor * SIMD4(1, 1, 1, 0.75)
            switch tool {
            case .line: ring(pending + [c], closed: false, rubber)
            case .rectangle: ring(Shape(kind: .rectangle(pending[0], c)).outline, closed: true, rubber)
            case .circle: ring(Shape(kind: .circle(center: pending[0], radius: max(distance(pending[0], c), 1e-6))).outline, closed: true, rubber)
            case .polygon:
                let r = max(distance(pending[0], c), 1e-6)
                ring(Shape(kind: .polygon(center: pending[0], radius: r, sides: polygonSides, start: atan2(c.y - pending[0].y, c.x - pending[0].x))).outline, closed: true, rubber)
            case .select: break
            }
        }
        if let c = cursor, tool != .select { out += cross(c, size: vertexSnap * 0.8, color: sketchColor) }
        return out
    }

    private func cross(_ p: Vec2, size: Double, color: SIMD4<Float>) -> [Line] {
        let z: Float = 0.03
        return [(SIMD3(Float(p.x - size), Float(p.y), z), SIMD3(Float(p.x + size), Float(p.y), z), color),
                (SIMD3(Float(p.x), Float(p.y - size), z), SIMD3(Float(p.x), Float(p.y + size), z), color)]
    }
}

func fmt(_ v: Double) -> String { v.formatted(.number.precision(.fractionLength(0...2))) }
