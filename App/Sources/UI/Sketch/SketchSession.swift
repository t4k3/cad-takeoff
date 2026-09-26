import CADCore
import Foundation
import Observation
import simd

/// Interactive editing of one sketch (T77). Entities are core `SketchShape` values;
/// the Parametri panel edits them directly while the sketch is open.
@MainActor
@Observable
final class SketchSession {
    enum Tool: String, CaseIterable, Identifiable {
        case select = "Seleziona", line = "Linea", rectangle = "Rettangolo", circle = "Cerchio",
             polygon = "Poligono", slot = "Asola"
        var id: String { rawValue }
        var symbol: String {
            switch self {
            case .select: "cursorarrow"
            case .line: "line.diagonal"
            case .rectangle: "rectangle"
            case .circle: "circle"
            case .polygon: "hexagon"
            case .slot: "capsule"
            }
        }
        var hint: String {
            switch self {
            case .select: "Clicca un'entità (o dentro un profilo) per vederne e modificarne i parametri."
            case .line: "Clicca i vertici. Clicca sul primo punto per chiudere · Invio termina · Esc annulla."
            case .rectangle: "Clicca il primo angolo, poi l'angolo opposto."
            case .circle: "Clicca il centro, poi un punto sulla circonferenza."
            case .polygon: "Clicca il centro, poi un vertice (o il punto medio di un lato se circoscritto)."
            case .slot: "Clicca il primo centro, il secondo centro, poi la larghezza."
            }
        }
        var key: String? {
            switch self {
            case .line: "l"; case .rectangle: "r"; case .circle: "c"; case .polygon: "p"; case .slot: "s"; case .select: nil
            }
        }
    }

    var sketch: Sketch {
        didSet { if !applyingUndo, sketch != oldValue { record(oldValue) } }
    }
    // Local undo while the sketch is open (the whole sketch becomes one design step on "Termina").
    private var undoStack: [(sketch: Sketch, title: String, date: Date)] = []
    private var redoStack: [(sketch: Sketch, title: String)] = []
    @ObservationIgnored private var applyingUndo = false
    var tool: Tool = .line { didSet { if tool != oldValue { pending = [] } } }
    var selection: SketchShape.ID?
    private(set) var pending: [Vec2] = []
    private(set) var cursor: Vec2?
    private(set) var cursorScreen: CGPoint?
    var snapToGrid = true
    var gridStep = 1.0
    var polygonSides = 6
    var polygonCircumscribed = false
    /// Height shown as wireframe while the Extrude panel is open.
    var previewHeight: Double?
    /// Preview drawn red when the extrusion cuts.
    var previewIsCut = false
    /// Snap radius in mm (~8 screen points), set by the viewport from the camera scale.
    var vertexSnap = 1.0

    init(sketch: Sketch) { self.sketch = sketch }

    private func record(_ old: Sketch) {
        let title = Self.describe(old, sketch)
        if let last = undoStack.last, last.title == title, title.hasPrefix("Modifica"), Date().timeIntervalSince(last.date) < 1.5 {
            undoStack[undoStack.count - 1].date = Date()   // typing in a field: one step
        } else {
            undoStack.append((old, title, Date()))
            if undoStack.count > 200 { undoStack.removeFirst() }
        }
        redoStack.removeAll()
    }

    private static func describe(_ old: Sketch, _ new: Sketch) -> String {
        if new.shapes.count > old.shapes.count, let s = new.shapes.last { return "Aggiungi \(s.typeName.lowercased())" }
        if new.shapes.count < old.shapes.count { return "Elimina entità" }
        if old.name != new.name { return "Rinomina schizzo" }
        if let s = zip(old.shapes, new.shapes).first(where: { $0 != $1 })?.1 { return "Modifica \(s.typeName.lowercased())" }
        return "Modifica schizzo"
    }

    var shapes: [SketchShape] { sketch.shapes }
    var selectedShape: SketchShape? { shapes.first { $0.id == selection } }
    var extrudeCandidate: SketchShape? {
        if let s = selectedShape, s.profile != nil { return s }
        let profiles = sketch.profiles
        return profiles.count == 1 ? profiles[0] : nil
    }

    func shape(_ id: SketchShape.ID) -> SketchShape? { shapes.first { $0.id == id } }

    func replace(_ id: SketchShape.ID, with kind: SketchShape.Kind) {
        guard let i = sketch.shapes.firstIndex(where: { $0.id == id }) else { return }
        sketch.shapes[i].kind = kind
    }

    func update(_ id: SketchShape.ID, _ change: (inout SketchShape) -> Void) {
        guard let i = sketch.shapes.firstIndex(where: { $0.id == id }) else { return }
        change(&sketch.shapes[i])
    }

    func deleteSelection() {
        sketch.shapes.removeAll { $0.id == selection }
        selection = nil
    }

    // MARK: Input

    func hover(_ world: SIMD3<Float>?, screen: CGPoint?) {
        cursor = world.map { snap(Vec2(Double($0.x), Double($0.y))) }
        cursorScreen = screen
    }

    func click(_ world: SIMD3<Float>) {
        let raw = Vec2(Double(world.x), Double(world.y))
        let p = snap(raw)
        switch tool {
        case .select:
            selection = pick(raw)
        case .line:
            if pending.count >= 3, dist(p, pending[0]) < max(vertexSnap, 1e-6) {
                commit(.polyline(pending, closed: true))
            } else if pending.last.map({ dist($0, p) > 1e-6 }) ?? true {
                pending.append(p)
            }
        case .rectangle:
            if let a = pending.first {
                if abs(p.x - a.x) > 1e-6, abs(p.y - a.y) > 1e-6 { commit(.rectangle(corner: a, width: p.x - a.x, height: p.y - a.y)) }
            } else { pending = [p] }
        case .circle:
            if let c = pending.first {
                if dist(c, p) > 1e-6 { commit(.circle(center: c, radius: dist(c, p))) }
            } else { pending = [p] }
        case .polygon:
            if let c = pending.first {
                if dist(c, p) > 1e-6 { commit(polygonKind(center: c, through: p)) }
            } else { pending = [p] }
        case .slot:
            switch pending.count {
            case 0: pending = [p]
            case 1: if dist(pending[0], p) > 1e-6 { pending.append(p) }
            default:
                let w = 2 * distanceToLine(p, pending[0], pending[1])
                if w > 1e-6 { commit(.slot(start: pending[0], end: pending[1], width: w)) }
            }
        }
    }

    func finish() {
        guard tool == .line, pending.count >= 2 else { return }
        commit(.polyline(pending, closed: false))
    }

    func cancel() -> Bool {
        if !pending.isEmpty { pending = []; return true }
        if tool != .select { tool = .select; return true }
        if selection != nil { selection = nil; return true }
        return false
    }

    private func commit(_ kind: SketchShape.Kind) {
        let s = SketchShape(kind: kind)
        sketch.shapes.append(s)
        pending = []
        selection = s.id
    }

    private func polygonKind(center c: Vec2, through p: Vec2) -> SketchShape.Kind {
        .polygon(center: c, radius: dist(c, p), sides: polygonSides,
                 rotation: atan2(p.y - c.y, p.x - c.x) - (polygonCircumscribed ? .pi / Double(polygonSides) : 0),
                 circumscribed: polygonCircumscribed)
    }

    /// Topmost closed shape containing the point, else the nearest outline within the snap radius.
    private func pick(_ p: Vec2) -> SketchShape.ID? {
        var best: (SketchShape.ID, Double)?
        for s in shapes.reversed() {
            let o = s.outline
            guard o.count >= 2 else { continue }
            for i in 0..<(s.isClosed ? o.count : o.count - 1) {
                let d = distanceToSegment(p, o[i], o[(i + 1) % o.count])
                if d < (best?.1 ?? .infinity) { best = (s.id, d) }
            }
        }
        if let best, best.1 <= vertexSnap * 1.2 { return best.0 }
        return shapes.last { $0.isClosed && contains($0.outline, p) }?.id
    }

    private func snap(_ p: Vec2) -> Vec2 {
        let vertices = shapes.flatMap { s -> [Vec2] in
            switch s.kind {
            case let .circle(c, _): return [c]
            case let .slot(a, b, _): return [a, b]
            case let .polygon(c, _, _, _, _): return [c] + s.outline
            default: return s.outline
            }
        } + pending
        if let v = vertices.min(by: { dist($0, p) < dist($1, p) }), dist(v, p) < vertexSnap { return v }
        guard snapToGrid else { return p }
        return Vec2((p.x / gridStep).rounded() * gridStep, (p.y / gridStep).rounded() * gridStep)
    }

    // MARK: Geometry helpers

    private func dist(_ a: Vec2, _ b: Vec2) -> Double { ((a.x - b.x) * (a.x - b.x) + (a.y - b.y) * (a.y - b.y)).squareRoot() }

    private func distanceToSegment(_ p: Vec2, _ a: Vec2, _ b: Vec2) -> Double {
        let dx = b.x - a.x, dy = b.y - a.y, l2 = dx * dx + dy * dy
        guard l2 > 1e-18 else { return dist(p, a) }
        let t = max(0, min(1, ((p.x - a.x) * dx + (p.y - a.y) * dy) / l2))
        return dist(p, Vec2(a.x + t * dx, a.y + t * dy))
    }

    private func distanceToLine(_ p: Vec2, _ a: Vec2, _ b: Vec2) -> Double {
        let dx = b.x - a.x, dy = b.y - a.y, l = (dx * dx + dy * dy).squareRoot()
        return l > 1e-12 ? abs((p.x - a.x) * dy - (p.y - a.y) * dx) / l : dist(p, a)
    }

    private func contains(_ v: [Vec2], _ p: Vec2) -> Bool {
        var inside = false
        var j = v.count - 1
        for i in v.indices {
            if (v[i].y > p.y) != (v[j].y > p.y),
               p.x < (v[j].x - v[i].x) * (p.y - v[i].y) / (v[j].y - v[i].y) + v[i].x { inside.toggle() }
            j = i
        }
        return inside
    }

    // MARK: HUD

    var liveMeasure: String? {
        guard let c = cursor else { return nil }
        let xy = "X \(fmt(c.x))  Y \(fmt(c.y))"
        switch tool {
        case .line:
            guard let last = pending.last else { return xy }
            return "\(fmt(dist(last, c))) mm · \(fmt(atan2(c.y - last.y, c.x - last.x) * 180 / .pi))°"
        case .rectangle:
            guard let a = pending.first else { return xy }
            return "\(fmt(abs(c.x - a.x))) × \(fmt(abs(c.y - a.y))) mm"
        case .circle:
            guard let ctr = pending.first else { return "Centro " + xy }
            return "Ø \(fmt(2 * dist(ctr, c))) mm"
        case .polygon:
            guard let ctr = pending.first else { return "Centro " + xy }
            return "R \(fmt(dist(ctr, c))) mm · \(polygonSides) lati \(polygonCircumscribed ? "circoscritto" : "inscritto")"
        case .slot:
            switch pending.count {
            case 0: return "Centro 1 " + xy
            case 1: return "Interasse \(fmt(dist(pending[0], c))) mm"
            default: return "Larghezza \(fmt(2 * distanceToLine(c, pending[0], pending[1]))) mm"
            }
        case .select: return nil
        }
    }

    // MARK: Drawing

    typealias Line = (SIMD3<Float>, SIMD3<Float>, SIMD4<Float>)

    func overlay(sketchColor: SIMD4<Float>, selectedColor: SIMD4<Float>, previewColor: SIMD4<Float>) -> [Line] {
        var out: [Line] = []
        func w(_ p: Vec2, _ z: Double = 0) -> SIMD3<Float> { SIMD3(Float(p.x), Float(p.y), Float(z) + 0.02) }
        func ring(_ pts: [Vec2], closed: Bool, _ color: SIMD4<Float>, z: Double = 0) {
            guard pts.count >= 2 else { return }
            for i in 0..<(closed ? pts.count : pts.count - 1) { out.append((w(pts[i], z), w(pts[(i + 1) % pts.count], z), color)) }
        }
        for s in shapes {
            let selected = s.id == selection
            var color = selected ? selectedColor : sketchColor
            if s.isConstruction { color *= SIMD4(1, 1, 1, 0.45) }
            ring(s.outline, closed: s.isClosed, color)
            if selected, let h = previewHeight, h > 0, s.profile != nil {
                let pc = previewIsCut ? SIMD4<Float>(0.95, 0.25, 0.25, 0.9) : previewColor
                ring(s.outline, closed: true, pc, z: h)
                let step = max(1, s.outline.count / 16)
                for (i, p) in s.outline.enumerated() where i % step == 0 { out.append((w(p), w(p, h), pc)) }
            }
            switch s.kind {
            case let .circle(c, _): out += cross(c, size: vertexSnap * 0.35, color: color)
            case let .slot(a, b, _): out += cross(a, size: vertexSnap * 0.35, color: color) + cross(b, size: vertexSnap * 0.35, color: color)
            case .polyline, .rectangle, .polygon: for p in s.outline { out += cross(p, size: vertexSnap * 0.3, color: color) }
            }
        }
        if let c = cursor, !pending.isEmpty {
            let rubber = sketchColor * SIMD4(1, 1, 1, 0.75)
            let preview: SketchShape.Kind? = switch tool {
            case .rectangle: .rectangle(corner: pending[0], width: c.x - pending[0].x, height: c.y - pending[0].y)
            case .circle: .circle(center: pending[0], radius: max(dist(pending[0], c), 1e-6))
            case .polygon: dist(pending[0], c) > 1e-6 ? polygonKind(center: pending[0], through: c) : nil
            case .slot:
                pending.count == 1 ? .slot(start: pending[0], end: c, width: max(vertexSnap, 0.5))
                    : .slot(start: pending[0], end: pending[1], width: max(2 * distanceToLine(c, pending[0], pending[1]), 1e-3))
            default: nil
            }
            if tool == .line { ring(pending + [c], closed: false, rubber) }
            if let preview { let s = SketchShape(kind: preview); ring(s.outline, closed: true, rubber) }
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

extension SketchSession: LocalUndoTarget {
    var canUndoLocally: Bool { !undoStack.isEmpty }
    var canRedoLocally: Bool { !redoStack.isEmpty }
    var localUndoTitle: String? { undoStack.last?.title }
    var localRedoTitle: String? { redoStack.last?.title }

    func undoLocally() {
        guard let last = undoStack.popLast() else { return }
        redoStack.append((sketch, last.title))
        applyingUndo = true; sketch = last.sketch; applyingUndo = false
        if let sel = selection, !sketch.shapes.contains(where: { $0.id == sel }) { selection = nil }
        pending = []
    }

    func redoLocally() {
        guard let next = redoStack.popLast() else { return }
        undoStack.append((sketch, next.title, .distantPast))
        applyingUndo = true; sketch = next.sketch; applyingUndo = false
        pending = []
    }
}

