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
             polygon = "Poligono", slot = "Asola", arc = "Arco", fillet = "Raccordo", chamfer = "Smusso", trim = "Taglia", extend = "Estendi",
             offset = "Offset", mirror = "Specchio", dimension = "Quota"
        var id: String { rawValue }
        /// The drawing tools (Quota lives with the constraints, the editing tools under MODIFICA).
        static var drawing: [Tool] { [.select, .line, .rectangle, .circle, .polygon, .slot, .arc] }
        static var modify: [Tool] { [.fillet, .chamfer, .trim, .extend, .offset, .mirror] }
        var symbol: String {
            switch self {
            case .select: "cursorarrow"
            case .line: "line.diagonal"
            case .rectangle: "rectangle"
            case .circle: "circle"
            case .polygon: "hexagon"
            case .slot: "capsule"
            case .arc: "circle.bottomhalf.filled"
            case .fillet: "arrow.turn.up.right"
            case .chamfer: "triangle.bottomhalf.filled"
            case .trim: "scissors"
            case .extend: "arrow.right.to.line"
            case .offset: "square.on.square.dashed"
            case .mirror: "arrow.left.and.right.righttriangle.left.righttriangle.right"
            case .dimension: "ruler"
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
            case .arc: "Clicca l'inizio, la fine, poi un punto dell'arco."
            case .fillet: "Clicca l'angolo tra due linee (anche di un rettangolo): diventa un arco tangente del raggio impostato."
            case .chamfer: "Clicca l'angolo tra due linee: lo taglia una linea alla distanza impostata su entrambi i lati."
            case .trim: "Clicca il pezzo da togliere: si taglia fino alle linee che lo incrociano (in rosso sotto il cursore)."
            case .extend: "Clicca vicino all'estremo libero di una linea o di un arco: si allunga fino alla prima curva che incontra."
            case .offset: "Clicca una forma (con le linee e gli archi uniti a lei), poi il lato dove creare la copia alla distanza impostata."
            case .mirror: "Clicca la linea d'asse, poi le forme da specchiare: le copie restano simmetriche all'originale."
            case .dimension: "Clicca una linea (lunghezza), un cerchio (diametro), due punti (distanza) o due linee (angolo), poi scrivi il valore."
            }
        }
        var key: String? {
            switch self {
            case .line: "l"; case .rectangle: "r"; case .circle: "c"; case .polygon: "p"; case .slot: "s"; case .dimension: "d"; case .arc: "a"
            case .trim: "t"; case .offset: "o"
            case .select, .fillet, .chamfer, .extend, .mirror: nil
            }
        }
    }

    var sketch: Sketch {
        didSet {
            if !applyingUndo, !dragging, sketch != oldValue { record(oldValue) }
            if sketch.shapes != oldValue.shapes || sketch.constraints != oldValue.constraints { analyze() }
        }
    }

    // MARK: Constraints state (logic in SketchSession+Constraints)
    /// A constraint being applied: the entities picked so far.
    var constraintTool: ConstraintTool? {
        didSet {
            picked = []
            notice = nil
            if constraintTool != nil { tool = .select; selection = nil }
        }
    }
    var picked: [SketchRef] = []
    var selectedConstraint: SketchConstraint.ID?
    /// Dimension whose value is being typed (its label shows a field).
    var editingDimension: SketchConstraint.ID?
    /// Last constraint problem ("Vincolo in conflitto…"), shown in the hint banner.
    var notice: String?
    /// Shapes that cannot move any more (drawn white), and the sketch's free degrees of freedom.
    private(set) var constrainedShapes: Set<UUID> = []
    private(set) var freedom = 0
    /// A point being dragged in Seleziona mode.
    @ObservationIgnored var dragRef: SketchRef?
    @ObservationIgnored var dragFixes: [SketchConstraint] = []
    @ObservationIgnored var dragging = false

    func analyze() {
        guard !sketch.constraints.isEmpty else { constrainedShapes = []; freedom = 0; return }
        let r = SketchSolver.solve(sketch.shapes, sketch.constraints)
        constrainedShapes = r.fullyConstrained
        freedom = r.freedom
    }

    /// Records the current state as one undo step (a whole drag is one step).
    func recordStep() { record(sketch) }
    // Local undo while the sketch is open (the whole sketch becomes one design step on "Termina").
    private var undoStack: [(sketch: Sketch, title: String, date: Date)] = []
    private var redoStack: [(sketch: Sketch, title: String)] = []
    @ObservationIgnored private var applyingUndo = false
    var tool: Tool = .line {
        didSet {
            if tool != oldValue { pending = []; picked = []; offsetSource = nil; mirrorAxis = nil }
            if tool != .select, constraintTool != nil { constraintTool = nil }
        }
    }
    var selection: SketchShape.ID?
    private(set) var pending: [Vec2] = []
    private(set) var cursor: Vec2?
    private(set) var cursorScreen: CGPoint?
    var snapToGrid = true
    var gridStep = 1.0
    var polygonSides = 6
    /// Radius of the next 2D fillet (Raccordo tool).
    var filletRadius = 3.0
    var offsetDistance = 2.0
    var chamferDistance = 2.0
    /// Values of the design's user parameters, for dimension expressions.
    var parameterValues: [String: Double] = [:]
    /// Offset: the shape picked first (then the side is clicked).
    var offsetSource: SketchShape.ID?
    /// Specchio: the axis line picked first (then the shapes to mirror).
    var mirrorAxis: SketchRef?
    /// Rivoluzione: the axis pick while the command's «Asse» field is active, and the preview.
    @ObservationIgnored var onAxisPick: ((SketchRef) -> Void)?
    struct RevolvePreview: Equatable { var axisStart: Vec2, axisEnd: Vec2, angle: Double, reversed: Bool, isCut: Bool }
    var revolvePreview: RevolvePreview?
    var polygonCircumscribed = false
    /// Height shown as wireframe while the Extrude panel is open.
    var previewHeight: Double?
    /// Preview drawn red when the extrusion cuts.
    var previewIsCut = false
    /// Preview extruded into the part (against the plane's normal).
    var previewReversed = false
    /// Snap radius in mm (~8 screen points), set by the viewport from the camera scale.
    var vertexSnap = 1.0
    /// While the Extrude panel is open, clicks pick areas (regions) instead of drawing, as with
    /// Fusion's profiles: the ring between two circles, the disc inside…
    var pickingRegions = false
    /// Picked regions, by the shape that bounds them.
    /// Picked faces, each by a point inside it (Fusion profiles from the sketch arrangement).
    var selectedSeeds: [Vec2] = []
    /// Faces of the sketch, recomputed only when the shapes change.
    @ObservationIgnored private var faceCache: (shapes: [SketchShape], faces: [SketchFace])?
    var faces: [SketchFace] {
        if let c = faceCache, c.shapes == sketch.shapes { return c.faces }
        let f = sketch.faces
        faceCache = (sketch.shapes, f)
        return f
    }
    /// The picked faces merged into areas to extrude.
    var pickedAreas: [SketchFace] { selectedSeeds.isEmpty ? [] : sketch.areas(seeds: selectedSeeds) }
    @ObservationIgnored var onRegionsChange: () -> Void = {}

    /// Adds or removes the region under a point of the plane.
    func toggleRegion(at world: SIMD3<Float>) {
        let p = local(world)
        let all = faces
        guard let f = sketch.face(at: p, in: all) else { return }
        if let i = selectedSeeds.firstIndex(where: { sketch.face(at: $0, in: all) == f }) { selectedSeeds.remove(at: i) } else { selectedSeeds.append(p) }
        onRegionsChange()
    }

    /// Shading of the picked regions (and, fainter, the one under the cursor) for the viewport.
    func regionFill() -> [(SIMD3<Float>, SIMD3<Float>, SIMD3<Float>, SIMD4<Float>)] {
        guard pickingRegions else { return [] }
        var out: [(SIMD3<Float>, SIMD3<Float>, SIMD3<Float>, SIMD4<Float>)] = []
        func fill(_ profile: Profile2D, _ holes: [Profile2D], _ color: SIMD4<Float>) {
            for (a, b, c) in profile.triangulate(holes: holes) { out.append((world(a, 0.01), world(b, 0.01), world(c, 0.01), color)) }
        }
        for area in pickedAreas { fill(Profile2D(points: area.outline), area.holes.map { Profile2D(points: $0) }, SIMD4(0.2, 0.55, 1, 0.35)) }
        let all = faces
        if let raw = rawCursor, let f = sketch.face(at: raw, in: all), !selectedSeeds.contains(where: { sketch.face(at: $0, in: all) == f }) {
            fill(Profile2D(points: f.outline), f.holes.map { Profile2D(points: $0) }, SIMD4(0.2, 0.55, 1, 0.14))
        }
        return out
    }

    /// Edges of the part lying on the sketch plane, in sketch coordinates (projected references:
    /// drawn dashed, snap targets; not part of the sketch).
    var references: [[Vec2]] = []

    init(sketch: Sketch) { self.sketch = sketch; analyze() }

    /// Projects the bodies' edges that lie on the sketch plane (the face outline and holes).
    func projectReferences(from bodies: [BodySnapshot]) {
        let pl = sketch.plane
        references = bodies.flatMap { b in
            b.edges.filter { e in e.polyline.allSatisfy { abs(($0 - pl.origin).dot(pl.normal)) < 1e-4 } }
                .map { $0.polyline.map { pl.local($0) } }
        }
    }

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
        update(id) { $0.kind = kind }
    }

    /// Edits a shape (Parametri panel) and re-solves the constraints around the new value.
    func update(_ id: SketchShape.ID, _ change: (inout SketchShape) -> Void) {
        guard let i = sketch.shapes.firstIndex(where: { $0.id == id }) else { return }
        var next = sketch
        change(&next.shapes[i])
        if !next.constraints.isEmpty, !next.solve() {
            notice = "La modifica non rispetta i vincoli dello schizzo: togli un vincolo o cambia una quota."
        }
        sketch = next
    }

    func deleteSelection() {
        if let c = selectedConstraint {
            sketch.constraints.removeAll { $0.id == c }
            selectedConstraint = nil
            return
        }
        sketch.shapes.removeAll { $0.id == selection }
        sketch.constraints.removeAll { $0.kind.refs.contains { $0.shapeID == selection } }
        selection = nil
    }

    // MARK: Input

    /// Where a viewport ray meets the sketch plane.
    func intersect(_ ray: Ray) -> SIMD3<Float>? {
        let pl = sketch.plane
        return ray.intersect(planePoint: SIMD3(Float(pl.origin.x), Float(pl.origin.y), Float(pl.origin.z)),
                             normal: SIMD3(Float(pl.normal.x), Float(pl.normal.y), Float(pl.normal.z)))
    }

    /// Sketch coordinates of a world point on the plane.
    func local(_ world: SIMD3<Float>) -> Vec2 {
        sketch.plane.local(Vec3(Double(world.x), Double(world.y), Double(world.z)))
    }

    func hover(_ world: SIMD3<Float>?, screen: CGPoint?) {
        cursor = world.map { snap(local($0)) }
        cursorScreen = screen
    }

    func click(_ world: SIMD3<Float>) {
        let raw = local(world)
        if constraintTool != nil { pickForConstraint(raw); return }
        if tool == .dimension { pickForDimension(raw); return }
        let p = snap(raw)
        switch tool {
        case .dimension: break
        case .fillet: filletCorner(raw)
        case .chamfer: filletCorner(raw, chamfer: true)
        case .trim: trim(raw)
        case .extend: extend(raw)
        case .offset: offsetClick(raw)
        case .mirror: mirrorClick(raw)
        case .arc:
            switch pending.count {
            case 0: pending = [p]
            case 1: if dist(pending[0], p) > 1e-6 { pending.append(p) }
            default: if let kind = arcKind(pending[0], pending[1], through: p) { commit(kind) }
            }
        case .select:
            selectedConstraint = nil
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
        if editingDimension != nil { editingDimension = nil; return true }
        if !picked.isEmpty { picked = []; return true }
        if offsetSource != nil { offsetSource = nil; return true }
        if mirrorAxis != nil { mirrorAxis = nil; return true }
        if constraintTool != nil { constraintTool = nil; return true }
        if selectedConstraint != nil { selectedConstraint = nil; return true }
        if !pending.isEmpty { pending = []; return true }
        if tool != .select { tool = .select; return true }
        if selection != nil { selection = nil; return true }
        return false
    }

    private func commit(_ kind: SketchShape.Kind) {
        let s = SketchShape(kind: kind)
        // The shape and the constraints it implies (as drawn) in one undo step.
        var next = sketch
        next.shapes.append(s)
        let implied = autoConstraints(for: s)
        if !implied.isEmpty {
            var withAll = next
            withAll.constraints += implied
            if withAll.solve() { next = withAll } else {
                for c in implied {
                    var one = next
                    one.constraints.append(c)
                    if one.solve() { next = one }
                }
            }
        }
        sketch = next
        pending = []
        selection = s.id
    }

    private func polygonKind(center c: Vec2, through p: Vec2) -> SketchShape.Kind {
        .polygon(center: c, radius: dist(c, p), sides: polygonSides,
                 rotation: atan2(p.y - c.y, p.x - c.x) - (polygonCircumscribed ? .pi / Double(polygonSides) : 0),
                 circumscribed: polygonCircumscribed)
    }

    /// Topmost closed shape containing the point, else the nearest outline within the snap radius.
    func pick(_ p: Vec2) -> SketchShape.ID? {
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

    // MARK: Snapping (vertices, midpoints, centres — as in Fusion)

    enum SnapKind { case vertex, midpoint, center }
    struct SnapPoint { let point: Vec2; let kind: SnapKind }

    /// What the cursor is snapped to (drawn with Fusion's glyphs: □ vertex, △ midpoint, ○ centre).
    private(set) var snapped: SnapPoint?
    /// Unsnapped cursor, to light up the midpoints of the segments it is close to.
    private(set) var rawCursor: Vec2?

    /// Straight segments of the sketch and of the projected references (their midpoints snap).
    private var segments: [(Vec2, Vec2)] {
        var out: [(Vec2, Vec2)] = []
        for s in shapes {
            switch s.kind {
            case .circle, .slot, .arc: continue
            default:
                let o = s.outline
                guard o.count >= 2 else { continue }
                for i in 0..<(s.isClosed ? o.count : o.count - 1) { out.append((o[i], o[(i + 1) % o.count])) }
            }
        }
        for line in references {
            guard line.count >= 2 else { continue }
            let closed = dist(line.first!, line.last!) < 1e-6
            if closed, line.count > 8 { continue }   // circle rims: centre snap only
            for (a, b) in zip(line, line.dropFirst()) { out.append((a, b)) }
        }
        return out
    }

    private var snapPoints: [SnapPoint] {
        var out: [SnapPoint] = []
        func mid(_ a: Vec2, _ b: Vec2) -> Vec2 { Vec2((a.x + b.x) / 2, (a.y + b.y) / 2) }
        for s in shapes {
            switch s.kind {
            case let .circle(c, _): out.append(.init(point: c, kind: .center))
            case let .slot(a, b, _):
                out += [.init(point: a, kind: .center), .init(point: b, kind: .center), .init(point: mid(a, b), kind: .midpoint)]
            case let .polygon(c, _, _, _, _):
                out.append(.init(point: c, kind: .center))
                out += s.outline.map { .init(point: $0, kind: .vertex) }
            case .rectangle:
                let o = s.outline
                out += o.map { .init(point: $0, kind: .vertex) }
                out.append(.init(point: mid(o[0], o[2]), kind: .center))
            case .polyline:
                out += s.outline.map { .init(point: $0, kind: .vertex) }
            case .arc:
                out += [.init(point: s.point(0)!, kind: .center), .init(point: s.point(1)!, kind: .vertex), .init(point: s.point(2)!, kind: .vertex)]
                let o = s.outline
                if !o.isEmpty { out.append(.init(point: o[o.count / 2], kind: .midpoint)) }
            }
        }
        out += segments.map { .init(point: mid($0.0, $0.1), kind: .midpoint) }
        out += pending.map { .init(point: $0, kind: .vertex) }
        for line in references {
            guard let a = line.first, let b = line.last else { continue }
            let closed = dist(a, b) < 1e-6
            let pts = closed ? Array(line.dropLast()) : line
            if closed, pts.count > 8 {
                let c = Vec2(pts.map(\.x).reduce(0, +) / Double(pts.count), pts.map(\.y).reduce(0, +) / Double(pts.count))
                out.append(.init(point: c, kind: .center))
                out += stride(from: 0, to: pts.count, by: max(1, pts.count / 4)).map { .init(point: pts[$0], kind: .vertex) }
            } else {
                out += pts.map { .init(point: $0, kind: .vertex) }
            }
        }
        return out
    }

    private func snap(_ p: Vec2) -> Vec2 {
        rawCursor = p
        // Nearest target; at the same distance a vertex wins over a midpoint over a centre.
        func rank(_ k: SnapKind) -> Double { k == .vertex ? 0 : (k == .midpoint ? 1e-9 : 2e-9) }
        if let best = snapPoints.min(by: { dist($0.point, p) + rank($0.kind) < dist($1.point, p) + rank($1.kind) }),
           dist(best.point, p) < vertexSnap {
            snapped = best
            return best.point
        }
        snapped = nil
        guard snapToGrid else { return p }
        return Vec2((p.x / gridStep).rounded() * gridStep, (p.y / gridStep).rounded() * gridStep)
    }

    // MARK: Geometry helpers

    func dist(_ a: Vec2, _ b: Vec2) -> Double { ((a.x - b.x) * (a.x - b.x) + (a.y - b.y) * (a.y - b.y)).squareRoot() }

    func distanceToSegment(_ p: Vec2, _ a: Vec2, _ b: Vec2) -> Double {
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
        case .arc:
            switch pending.count {
            case 0: return "Inizio " + xy
            case 1: return "Corda \(fmt(dist(pending[0], c))) mm"
            default:
                if case let .arc(_, r, a0, a1)? = arcKind(pending[0], pending[1], through: c) { return "R \(fmt(r)) mm · \(fmt(SketchShape.sweep(a0, a1) * 180 / .pi))°" }
                return nil
            }
        case .fillet: return "R \(fmt(filletRadius)) mm"
        case .chamfer: return "Smusso \(fmt(chamferDistance)) mm"
        case .offset: return offsetSource == nil ? nil : "Offset \(fmt(offsetDistance)) mm"
        case .select, .dimension, .trim, .extend, .mirror: return nil
        }
    }

    // MARK: Drawing

    typealias Line = (SIMD3<Float>, SIMD3<Float>, SIMD4<Float>)

    func overlay(sketchColor: SIMD4<Float>, selectedColor: SIMD4<Float>, previewColor: SIMD4<Float>) -> [Line] {
        var out: [Line] = []
        func w(_ p: Vec2, _ z: Double = 0) -> SIMD3<Float> { world(p, z + 0.02) }
        func ring(_ pts: [Vec2], closed: Bool, _ color: SIMD4<Float>, z: Double = 0) {
            guard pts.count >= 2 else { return }
            for i in 0..<(closed ? pts.count : pts.count - 1) { out.append((w(pts[i], z), w(pts[(i + 1) % pts.count], z), color)) }
        }
        // Projected part edges: dashed, orange.
        let refColor = SIMD4<Float>(1, 0.62, 0.25, 0.8)
        for line in references {
            for (k, (a, b)) in zip(line, line.dropFirst()).enumerated() {
                let l = dist(a, b)
                guard l > 1e-9 else { continue }
                // Dashes of ~1.5 snap radii.
                let dash = max(vertexSnap * 1.2, 0.3), steps = max(1, Int(l / dash))
                for i in stride(from: 0, to: steps, by: 2) {
                    let t0 = Double(i) / Double(steps), t1 = min(1, Double(i + 1) / Double(steps))
                    out.append((w(Vec2(a.x + (b.x - a.x) * t0, a.y + (b.y - a.y) * t0)),
                                w(Vec2(a.x + (b.x - a.x) * t1, a.y + (b.y - a.y) * t1)), refColor))
                }
                _ = k
            }
        }
        for s in shapes {
            let selected = s.id == selection
            // Fully constrained shapes turn white (Fusion: blue = free, black = defined).
            let defined = constrainedShapes.contains(s.id) ? SIMD4<Float>(0.93, 0.95, 0.98, 1) : sketchColor
            var color = selected ? selectedColor : defined
            if s.isConstruction { color *= SIMD4(1, 1, 1, 0.45) }
            ring(s.outline, closed: s.isClosed, color)
            if selected, !pickingRegions, let h0 = previewHeight, h0 > 0, s.profile != nil {
                let h = previewReversed ? -h0 : h0
                let pc = previewIsCut ? SIMD4<Float>(0.95, 0.25, 0.25, 0.9) : previewColor
                ring(s.outline, closed: true, pc, z: h)
                // Side lines at the corners only: quadrants of a circle, the four tangent points of a slot.
                let n = s.outline.count
                let sides: [Int] = switch s.kind {
                case .circle: [0, n / 4, n / 2, 3 * n / 4]
                case .slot: [0, n / 2 - 1, n / 2, n - 1]
                default: Array(0..<n)
                }
                for i in sides where i < n { out.append((w(s.outline[i]), w(s.outline[i], h), pc)) }
            }
            switch s.kind {
            case let .circle(c, _): out += cross(c, size: vertexSnap * 0.35, color: color)
            case let .slot(a, b, _): out += cross(a, size: vertexSnap * 0.35, color: color) + cross(b, size: vertexSnap * 0.35, color: color)
            case .polyline, .rectangle, .polygon: for p in s.outline { out += cross(p, size: vertexSnap * 0.3, color: color) }
            case .arc: out += cross(s.point(0)!, size: vertexSnap * 0.35, color: color * SIMD4(1, 1, 1, 0.6))
                for i in [1, 2] { out += cross(s.point(i)!, size: vertexSnap * 0.3, color: color) }
            }
        }
        // Extrusion preview of the picked areas: outlines and holes at the top, side lines at corners.
        if pickingRegions, let h0 = previewHeight, h0 > 0 {
            let h = previewReversed ? -h0 : h0
            let pc = previewIsCut ? SIMD4<Float>(0.95, 0.25, 0.25, 0.9) : previewColor
            for area in pickedAreas {
                for loop in [area.outline] + area.holes {
                    ring(loop, closed: true, pc, z: h)
                    // Side lines at real corners only (not along the facets of a circle or an arc),
                    // plus a few on smooth loops so they read as walls.
                    let n = loop.count
                    var sides: [Int] = []
                    for i in 0..<n {
                        let a = loop[(i + n - 1) % n], b = loop[i], c = loop[(i + 1) % n]
                        let u = b - a, v = c - b
                        let turn = abs(atan2(u.cross(v), u.x * v.x + u.y * v.y))
                        if turn > 0.35 { sides.append(i) }
                    }
                    if sides.isEmpty { sides = [0, n / 4, n / 2, 3 * n / 4] }
                    for i in sides where i < n { out.append((w(loop[i]), w(loop[i], h), pc)) }
                }
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
            if tool == .line || (tool == .arc && pending.count == 1) { ring(pending + [c], closed: false, rubber) }
            if tool == .arc, pending.count == 2, let kind = arcKind(pending[0], pending[1], through: c) {
                ring(SketchShape(kind: kind).outline, closed: false, rubber)
            }
            if let preview { let s = SketchShape(kind: preview); ring(s.outline, closed: true, rubber) }
        }
        out += editOverlay(sketchColor: sketchColor, selectedColor: selectedColor)
        // Midpoints of the segments near the cursor light up (then snap when closer).
        if let raw = rawCursor, tool != .select {
            let faint = SIMD4<Float>(1, 0.62, 0.25, 0.55)
            for (a, b) in segments where distanceToSegment(raw, a, b) < vertexSnap * 3 {
                out += glyph(Vec2((a.x + b.x) / 2, (a.y + b.y) / 2), .midpoint, size: vertexSnap * 0.45, color: faint)
            }
        }
        if let c = cursor, tool != .select {
            let snapColor = SIMD4<Float>(1, 0.62, 0.2, 1)
            out += cross(c, size: vertexSnap * 1.6, color: snapped == nil ? sketchColor : snapColor)
            if let s = snapped { out += glyph(s.point, s.kind, size: vertexSnap * 0.6, color: snapColor) }
        }
        return out
    }

    private func cross(_ p: Vec2, size: Double, color: SIMD4<Float>) -> [Line] {
        [(world(Vec2(p.x - size, p.y), 0.03), world(Vec2(p.x + size, p.y), 0.03), color),
         (world(Vec2(p.x, p.y - size), 0.03), world(Vec2(p.x, p.y + size), 0.03), color)]
    }

    /// Fusion's snap glyphs: square (vertex), triangle (midpoint), circle (centre).
    private func glyph(_ p: Vec2, _ kind: SnapKind, size r: Double, color: SIMD4<Float>) -> [Line] {
        let corners: [Vec2]
        switch kind {
        case .vertex: corners = [Vec2(p.x - r, p.y - r), Vec2(p.x + r, p.y - r), Vec2(p.x + r, p.y + r), Vec2(p.x - r, p.y + r)]
        case .midpoint: corners = [Vec2(p.x - r, p.y - r * 0.7), Vec2(p.x + r, p.y - r * 0.7), Vec2(p.x, p.y + r * 1.1)]
        case .center: corners = (0..<12).map { k in let t = Double(k) / 12 * 2 * .pi; return Vec2(p.x + r * cos(t), p.y + r * sin(t)) }
        }
        return corners.indices.map { i in (world(corners[i], 0.04), world(corners[(i + 1) % corners.count], 0.04), color) }
    }

    /// World position of sketch coordinates, `height` off the plane (overlays sit just above it).
    func world(_ p: Vec2, _ height: Double) -> SIMD3<Float> {
        let v = sketch.plane.world(p, height: height)
        return SIMD3(Float(v.x), Float(v.y), Float(v.z))
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

