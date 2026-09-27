import CADCore
import Foundation
import simd

/// Constraints and dimensions in the sketch editor (Fusion's flow): pick a constraint, then the
/// entities; Quota (D) measures what is clicked and asks for the value; points can be dragged
/// along whatever the constraints leave free.
enum ConstraintTool: String, CaseIterable, Identifiable {
    case horizontalVertical = "Oriz./Vert."
    case coincident = "Coincidente"
    case parallel = "Parallelo"
    case perpendicular = "Perpendicolare"
    case tangent = "Tangente"
    case equal = "Uguale"
    case concentric = "Concentrico"
    case midpoint = "Punto medio"
    case symmetric = "Simmetrico"
    case fix = "Fisso"

    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .horizontalVertical: "arrow.up.and.down.and.arrow.left.and.right"
        case .coincident: "smallcircle.filled.circle"
        case .parallel: "equal"
        case .perpendicular: "angle"
        case .tangent: "circle.and.line.horizontal"
        case .equal: "equal.square"
        case .concentric: "circle.circle"
        case .midpoint: "circle.bottomhalf.filled"
        case .symmetric: "arrow.left.and.line.vertical.and.arrow.right"
        case .fix: "lock"
        }
    }

    var hint: String {
        switch self {
        case .horizontalVertical: "Clicca una linea: diventa orizzontale o verticale (la più vicina)."
        case .coincident: "Clicca due punti (o un punto e una linea o un cerchio)."
        case .parallel: "Clicca due linee."
        case .perpendicular: "Clicca due linee."
        case .tangent: "Clicca una linea e un cerchio, o due cerchi."
        case .equal: "Clicca due linee (stessa lunghezza) o due cerchi (stesso raggio)."
        case .concentric: "Clicca due cerchi."
        case .midpoint: "Clicca un punto, poi la linea."
        case .symmetric: "Clicca due punti, poi la linea d'asse: i punti diventano simmetrici."
        case .fix: "Clicca un punto: resta dov'è."
        }
    }
}

extension SketchSession {
    // MARK: Picking entities

    enum RefKind { case point, segment, circle }

    /// The point, circle rim or segment under `p` (points first, as in Fusion), within the snap radius.
    func pickRef(_ p: Vec2, kinds: Set<RefKind> = [.point, .segment, .circle]) -> SketchRef? {
        let tol = vertexSnap * 1.2
        var best: (SketchRef, Double)?
        func consider(_ r: SketchRef, _ d: Double, bias: Double) {
            if d <= tol, d + bias < (best?.1 ?? .infinity) { best = (r, d + bias) }
        }
        for s in shapes where !s.isConstruction || true {
            if kinds.contains(.point) {
                for i in 0..<s.pointCount { if let q = s.point(i) { consider(.point(s.id, i), dist(q, p), bias: 0) } }
            }
            if kinds.contains(.circle) {
                for i in 0..<2 { if let c = s.circle(i) { consider(.circle(s.id, i), abs(dist(c.center, p) - c.radius), bias: tol * 0.3) } }
            }
            if kinds.contains(.segment) {
                for i in 0..<s.segmentCount { if let (a, b) = s.segment(i) { consider(.segment(s.id, i), distanceToSegment(p, a, b), bias: tol * 0.4) } }
            }
        }
        return best?.0
    }

    // MARK: Applying constraints

    func pickForConstraint(_ p: Vec2) {
        guard let tool = constraintTool else { return }
        let wanted: Set<RefKind> = switch (tool, picked.count) {
        case (.horizontalVertical, _), (.parallel, _), (.perpendicular, _): [.segment]
        case (.coincident, 0), (.fix, _): [.point]
        case (.coincident, _): [.point, .segment, .circle]
        case (.tangent, _), (.equal, _): [.segment, .circle]
        case (.concentric, _): [.circle, .point]
        case (.midpoint, 0): [.point]
        case (.midpoint, _): [.segment]
        case (.symmetric, 0), (.symmetric, 1): [.point]
        case (.symmetric, _): [.segment]
        }
        guard let ref = pickRef(p, kinds: wanted) else { notice = "Niente da vincolare qui: " + tool.hint; return }
        if picked.last == ref { return }
        picked.append(ref)
        let a = picked[0], b = picked.count > 1 ? picked[1] : nil
        var kind: SketchConstraintKind?
        switch tool {
        case .horizontalVertical:
            if let (u, v) = shape(a.shapeID)?.segment(index(a)) {
                kind = abs(v.x - u.x) >= abs(v.y - u.y) ? .horizontal(a) : .vertical(a)
            }
        case .fix:
            if let q = shape(a.shapeID)?.point(index(a)) { kind = .fix(a, q) }
        case .coincident:
            guard let b else { return }
            switch b {
            case .point: kind = .coincident(a, b)
            case .segment: kind = .pointOnLine(a, b)
            case .circle: kind = .pointOnCircle(a, b)
            }
        case .parallel: if let b { kind = .parallel(a, b) } else { return }
        case .perpendicular: if let b { kind = .perpendicular(a, b) } else { return }
        case .tangent: if let b { kind = .tangent(a, b) } else { return }
        case .equal:
            guard let b else { return }
            guard sameKind(a, b) else { picked = [a]; notice = "Uguale: due linee o due cerchi."; return }
            kind = .equal(a, b)
        case .concentric: if let b { kind = .concentric(a, b) } else { return }
        case .midpoint: if let b { kind = .midpoint(a, b) } else { return }
        case .symmetric:
            guard picked.count == 3, let b else { return }
            kind = .symmetric(a, b, picked[2])
        }
        picked = []
        if let kind { apply(SketchConstraint(kind)) }
    }

    /// Adds a constraint if the sketch can satisfy it (otherwise explains and leaves it out).
    @discardableResult
    func apply(_ c: SketchConstraint) -> Bool {
        var next = sketch
        next.constraints.append(c)
        guard next.solve(after: c.id) else {
            notice = "«\(c.kind.label)» è in conflitto con i vincoli esistenti: non aggiunto."
            return false
        }
        notice = nil
        sketch = next
        return true
    }

    // MARK: Automatic constraints (as Fusion infers them while drawing)

    /// What a new shape implies as drawn: sides exactly horizontal/vertical, points on other shapes'
    /// points (coincident), on their midpoints (midpoint), centres on other centres (concentric).
    func autoConstraints(for new: SketchShape) -> [SketchConstraint] {
        var out: [SketchConstraint] = []
        let eps = 1e-6
        if case .polyline = new.kind {
            for i in 0..<new.segmentCount {
                guard let (a, b) = new.segment(i), dist(a, b) > eps else { continue }
                if abs(a.y - b.y) < eps { out.append(.init(.horizontal(.segment(new.id, i)))) }
                else if abs(a.x - b.x) < eps { out.append(.init(.vertical(.segment(new.id, i)))) }
            }
        }
        // Defining points only (a rectangle's corners, a circle's centre…), never derived ones.
        let ownPoints: [Int] = switch new.kind {
        case let .polyline(p, _): Array(p.indices)
        case let .spline(p, _): Array(p.indices)
        case .rectangle: [0, 1, 2, 3]
        case .circle, .polygon: [0]
        case .slot: [0, 1]
        case .arc: [1, 2]
        }
        for i in ownPoints {
            guard let p = new.point(i) else { continue }
            var linked = false
            for other in shapes where other.id != new.id {
                // Centre on a centre: concentric circles.
                if case .circle = new.kind, let c = other.circle(0), dist(c.center, p) < eps {
                    out.append(.init(.concentric(.circle(new.id, 0), .circle(other.id, 0)))); linked = true; break
                }
                if let j = (0..<other.pointCount).first(where: { other.point($0).map { dist($0, p) < eps } ?? false }) {
                    out.append(.init(.coincident(.point(new.id, i), .point(other.id, j)))); linked = true; break
                }
            }
            if linked { continue }
            for other in shapes where other.id != new.id {
                if let k = (0..<other.segmentCount).first(where: { other.segment($0).map { dist(($0.0 + $0.1) * 0.5, p) < eps } ?? false }) {
                    out.append(.init(.midpoint(.point(new.id, i), .segment(other.id, k)))); break
                }
            }
        }
        // Arcs and lines drawn on from each other's ends along the same direction: tangent.
        out += sketch.tangentAutoConstraints(for: new)
        return out
    }

    // MARK: Dimensions

    func pickForDimension(_ p: Vec2) {
        let ref = pickRef(p)
        switch (picked.first, ref) {
        case (nil, nil): return
        case (nil, .circle?):
            addDimension(.diameter(ref!, 2 * (circle(ref!)?.radius ?? 0)))
        case (nil, let r?):
            picked = [r]
            notice = r.isPoint ? "Clicca un altro punto o una linea." : "Clicca un'altra linea (angolo), oppure in un punto vuoto per la lunghezza."
        case (let a?, nil):
            // Line then empty space: its length.
            picked = []
            notice = nil
            if case .segment = a, let (u, v) = segment(a) { addDimension(.length(a, dist(u, v))) }
        case (let a?, let b?):
            picked = []
            notice = nil
            switch (a, b) {
            case (.point, .point):
                if let u = point(a), let v = point(b) { addDimension(.distance(a, b, dist(u, v))) }
            case (.point, .segment), (.segment, .point):
                let (pt, seg) = a.isPoint ? (a, b) : (b, a)
                if let q = point(pt), let (u, v) = segment(seg) { addDimension(.distance(pt, seg, distanceToLineInfinite(q, u, v))) }
            case (.segment, .segment):
                guard let (u1, v1) = segment(a), let (u2, v2) = segment(b) else { return }
                let d1 = v1 - u1, d2 = v2 - u2
                let angle = atan2(d1.cross(d2), d1.x * d2.x + d1.y * d2.y) * 180 / .pi
                if abs(sin(angle * .pi / 180)) < 1e-3 {
                    addDimension(.distance(a, b, distanceToLineInfinite(u2, u1, v1)))   // parallel lines
                } else {
                    addDimension(.angle(a, b, angle))
                }
            case (_, .circle), (.circle, _):
                let c = a.isCircle ? a : b
                if let r = circle(c) { addDimension(.diameter(c, 2 * r.radius)) }
            default: return
            }
        }
    }

    /// A new dimension at the current measure, its value field opened for typing.
    private func addDimension(_ kind: SketchConstraintKind) {
        let c = SketchConstraint(kind.with(value: ((kind.value ?? 0) * 100).rounded() / 100))
        if apply(c) { editingDimension = c.id }
    }

    /// Sets a dimension from what was typed: a number, or an expression of the design's
    /// parameters (it then follows them). False when it is invalid or the sketch cannot take it.
    @discardableResult
    func setDimension(_ id: SketchConstraint.ID, text: String) -> Bool {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "⌀", with: "")
        guard !clean.isEmpty else { return false }
        do {
            let value = try Formula.evaluate(clean, parameterValues)
            return setDimension(id, value: value, expression: Formula.isNumber(clean) ? nil : clean)
        } catch {
            notice = "Quota: " + error.localizedDescription
            return false
        }
    }

    /// Sets a dimension's value (typed or from a parameter); false when the sketch cannot take it.
    @discardableResult
    func setDimension(_ id: SketchConstraint.ID, value: Double, expression: String? = nil) -> Bool {
        guard let i = sketch.constraints.firstIndex(where: { $0.id == id }), value.isFinite else { return false }
        if case .angle = sketch.constraints[i].kind {} else { guard value > 0 else { notice = "Il valore deve essere positivo."; return false } }
        var next = sketch
        next.constraints[i].kind = next.constraints[i].kind.with(value: value)
        next.constraints[i].expression = expression
        guard next.solve(after: next.constraints[i].id) else { notice = "Con \(fmt(value)) i vincoli non si possono rispettare: valore non applicato."; return false }
        notice = nil
        sketch = next
        return true
    }

    /// Re-evaluates the dimensions driven by expressions (after the parameters changed).
    func refreshExpressions() {
        var next = sketch
        var touched = false
        for i in next.constraints.indices {
            guard let e = next.constraints[i].expression, next.constraints[i].kind.value != nil,
                  let v = try? Formula.evaluate(e, parameterValues), v != next.constraints[i].kind.value else { continue }
            next.constraints[i].kind = next.constraints[i].kind.with(value: v)
            touched = true
        }
        guard touched else { return }
        if next.solve() { sketch = next } else { notice = "Lo schizzo non riesce a seguire i nuovi parametri." }
    }

    // MARK: Dragging

    /// Starts dragging the point under `p` (Seleziona). Rectangles keep their opposite corner.
    func beginDrag(_ world: SIMD3<Float>) -> Bool {
        guard tool == .select, constraintTool == nil, let ref = pickRef(local(world), kinds: [.point]) else { return false }
        dragRef = ref
        dragFixes = []
        if case let .point(id, i) = ref, let s = shape(id), case .rectangle = s.kind, i < 4, let opposite = s.point((i + 2) % 4) {
            dragFixes = [SketchConstraint(.fix(.point(id, (i + 2) % 4), opposite))]
        }
        recordStep()
        dragging = true
        return true
    }

    func drag(_ world: SIMD3<Float>) {
        guard let ref = dragRef else { return }
        let target = snapForDrag(local(world))
        var next = sketch
        next.constraints += dragFixes
        let result = SketchSolver.solve(next.shapes, next.constraints, drag: (ref, target))
        guard result.converged else { return }
        next.shapes = result.shapes
        next.constraints.removeAll { c in dragFixes.contains { $0.id == c.id } }
        sketch = next
    }

    func endDrag() {
        dragRef = nil
        dragFixes = []
        dragging = false
    }

    private func snapForDrag(_ p: Vec2) -> Vec2 {
        guard snapToGrid else { return p }
        return Vec2((p.x / gridStep).rounded() * gridStep, (p.y / gridStep).rounded() * gridStep)
    }

    // MARK: Annotations (drawn by the viewport as labels)

    struct Annotation: Identifiable {
        let id: SketchConstraint.ID
        let anchor: SIMD3<Float>
        let text: String
        let isDimension: Bool
        let value: Double?
        /// The parameter expression driving the dimension, if any (label "fx: …").
        let expression: String?
    }

    /// One label per constraint: a small symbol for geometric ones, the value for dimensions.
    func annotations() -> [Annotation] {
        let off = vertexSnap * 2.2
        return sketch.constraints.compactMap { c -> Annotation? in
            guard let (at, text) = placement(c.kind, offset: off) else { return nil }
            let driven = c.kind.value != nil ? c.expression : nil
            return Annotation(id: c.id, anchor: world(at, 0.05), text: driven == nil ? text : "fx: " + text,
                              isDimension: c.kind.value != nil, value: c.kind.value, expression: driven)
        }
    }

    /// Dimension lines (thin) for the viewport overlay.
    func dimensionLines(color: SIMD4<Float>) -> [Line] {
        var out: [Line] = []
        let off = vertexSnap * 2.2
        func w(_ p: Vec2) -> SIMD3<Float> { world(p, 0.04) }
        for c in sketch.constraints {
            switch c.kind {
            case let .length(ref, _):
                guard let (u, v) = segment(ref) else { continue }
                let n = normal(u, v) * off
                out += [(w(u), w(u + n * 1.2), color), (w(v), w(v + n * 1.2), color), (w(u + n), w(v + n), color)]
            case let .distance(a, b, _) where a.isPoint && b.isPoint:
                guard let u = point(a), let v = point(b) else { continue }
                let n = normal(u, v) * off
                out += [(w(u), w(u + n * 1.2), color), (w(v), w(v + n * 1.2), color), (w(u + n), w(v + n), color)]
            case let .diameter(ref, _), let .radius(ref, _):
                guard let c = circle(ref) else { continue }
                let d = Vec2(cos(.pi / 4), sin(.pi / 4))
                out.append((w(c.center - d * c.radius), w(c.center + d * (c.radius + off)), color))
            default: continue
            }
        }
        return out
    }

    private func placement(_ k: SketchConstraintKind, offset off: Double) -> (Vec2, String)? {
        // Symbols on the other side of the line from its dimension, so they never overlap.
        func mid(_ r: SketchRef) -> Vec2? { segment(r).map { ($0.0 + $0.1) * 0.5 + normal($0.0, $0.1) * (-off * 0.7) } }
        switch k {
        case let .horizontal(r): return mid(r).map { ($0, "—") }
        case let .vertical(r): return mid(r).map { ($0, "|") }
        case let .parallel(a, _): return mid(a).map { ($0, "∥") }
        case let .perpendicular(a, _): return mid(a).map { ($0, "⊥") }
        case let .equal(a, _): return (mid(a) ?? circle(a).map { $0.center + Vec2(0, $0.radius + off * 0.6) }).map { ($0, "=") }
        case let .tangent(a, b): return (mid(a) ?? mid(b)).map { ($0, "T") }
        case let .concentric(a, _): return circle(a).map { ($0.center + Vec2(off * 0.6, off * 0.6), "◎") }
        case let .coincident(a, _), let .pointOnLine(a, _), let .pointOnCircle(a, _): return point(a).map { ($0 + Vec2(off * 0.5, off * 0.5), "•") }
        case let .midpoint(a, _): return point(a).map { ($0 + Vec2(off * 0.5, off * 0.5), "½") }
        case let .symmetric(_, b, _): return point(b).map { ($0 + Vec2(off * 0.5, -off * 0.5), "⇋") }
        case let .fix(a, _): return point(a).map { ($0 + Vec2(-off * 0.6, -off * 0.6), "🔒") }
        case let .length(r, v):
            guard let (u, w) = segment(r) else { return nil }
            return ((u + w) * 0.5 + normal(u, w) * off, fmt(v))
        case let .distance(a, b, v):
            if let u = point(a), let q = point(b) { return ((u + q) * 0.5 + normal(u, q) * off, fmt(v)) }
            if let u = point(a) ?? point(b) { return (u + Vec2(off, off), fmt(v)) }
            if let (u, q) = segment(a) { return ((u + q) * 0.5 + normal(u, q) * off, fmt(v)) }
            return nil
        case let .horizontalDistance(a, b, v), let .verticalDistance(a, b, v):
            guard let u = point(a), let q = point(b) else { return nil }
            return ((u + q) * 0.5 + Vec2(0, off), fmt(v))
        case let .diameter(r, v):
            guard let c = circle(r) else { return nil }
            return (c.center + Vec2(cos(.pi / 4), sin(.pi / 4)) * (c.radius + off), "⌀" + fmt(v))
        case let .radius(r, v):
            guard let c = circle(r) else { return nil }
            return (c.center + Vec2(cos(.pi / 4), sin(.pi / 4)) * (c.radius + off), "R" + fmt(v))
        case let .angle(a, _, v):
            guard let (u, w) = segment(a) else { return nil }
            return (u + (w - u) * 0.25 + normal(u, w) * off, fmt(v) + "°")
        }
    }

    // MARK: Helpers

    private func index(_ r: SketchRef) -> Int {
        switch r { case let .point(_, i), let .segment(_, i), let .circle(_, i): i }
    }
    private func point(_ r: SketchRef) -> Vec2? { if case let .point(id, i) = r { shape(id)?.point(i) } else { nil } }
    private func segment(_ r: SketchRef) -> (Vec2, Vec2)? { if case let .segment(id, i) = r { shape(id)?.segment(i) } else { nil } }
    private func circle(_ r: SketchRef) -> (center: Vec2, radius: Double)? { if case let .circle(id, i) = r { shape(id)?.circle(i) } else { nil } }
    private func sameKind(_ a: SketchRef, _ b: SketchRef) -> Bool { (a.isCircle && b.isCircle) || (!a.isCircle && !b.isCircle && !a.isPoint && !b.isPoint) }
    private func normal(_ u: Vec2, _ v: Vec2) -> Vec2 {
        let d = v - u, l = max(dist(u, v), 1e-9)
        return Vec2(-d.y / l, d.x / l)
    }
    private func distanceToLineInfinite(_ p: Vec2, _ a: Vec2, _ b: Vec2) -> Double {
        abs((b - a).cross(p - a)) / max(dist(a, b), 1e-9)
    }
}

extension SketchRef {
    var isPoint: Bool { if case .point = self { true } else { false } }
    var isCircle: Bool { if case .circle = self { true } else { false } }
}

// MARK: - Arcs and 2D fillets

extension SketchSession {
    /// Arc from `a` to `b` through `p` (three-point arc), nil when the points are aligned.
    func arcKind(_ a: Vec2, _ b: Vec2, through p: Vec2) -> SketchShape.Kind? {
        let d = 2 * (a.x * (b.y - p.y) + b.x * (p.y - a.y) + p.x * (a.y - b.y))
        guard abs(d) > 1e-9 else { return nil }
        let a2 = a.x * a.x + a.y * a.y, b2 = b.x * b.x + b.y * b.y, p2 = p.x * p.x + p.y * p.y
        let c = Vec2((a2 * (b.y - p.y) + b2 * (p.y - a.y) + p2 * (a.y - b.y)) / d,
                     (a2 * (p.x - b.x) + b2 * (a.x - p.x) + p2 * (b.x - a.x)) / d)
        let r = dist(c, a)
        guard r.isFinite, r < 1e6 else { return nil }
        let ta = atan2(a.y - c.y, a.x - c.x), tb = atan2(b.y - c.y, b.x - c.x), tp = atan2(p.y - c.y, p.x - c.x)
        // Counter-clockwise from a to b if that way passes through p, otherwise from b to a.
        let passes = SketchShape.sweep(ta, tp) < SketchShape.sweep(ta, tb)
        return passes ? .arc(center: c, radius: r, start: ta, end: tb) : .arc(center: c, radius: r, start: tb, end: ta)
    }

    /// Raccordo: the corner under `p` becomes a tangent arc of `filletRadius` (Smusso: a line
    /// `chamferDistance` from the corner).
    func filletCorner(_ p: Vec2, chamfer: Bool = false) {
        guard case let .point(id, i)? = pickRef(p, kinds: [.point]), let shape = shape(id) else {
            notice = "Clicca l'angolo tra due linee."; return
        }
        switch shape.kind {
        case .polyline: break
        case .rectangle where i < 4: break
        default: notice = "Si fa sull'angolo tra due linee (polilinea o rettangolo)."; return
        }
        var next = sketch
        do {
            let arc = chamfer ? try next.chamfer(id, vertex: i, distance: chamferDistance) : try next.fillet(id, vertex: i, radius: filletRadius)
            guard next.solve() else { notice = (chamfer ? "Smusso" : "Raccordo") + " in conflitto con i vincoli dello schizzo."; return }
            notice = nil
            sketch = next
            selection = arc
        } catch {
            notice = (chamfer ? "Smusso: " : "Raccordo: ") + error.localizedDescription
        }
    }
}
