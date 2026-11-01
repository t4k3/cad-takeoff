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
    case colinear = "Colineare"
    case tangent = "Tangente"
    case equal = "Uguale"
    case concentric = "Concentrico"
    case midpoint = "Punto medio"
    case symmetric = "Simmetrico"
    case fix = "Fisso"
    case pointOnPlane = "Sul piano"
    case normalToPlane = "Normale al piano"
    case planeDistance = "Distanza dal piano"
    case lockRotation = "Blocco rotazione"
    case pointOnBezier = "Punto su Bezier"
    case bezierTangent = "Tangente alla Bezier"
    case bezierPerpendicular = "Perpendicolare alla Bezier"

    var id: String { rawValue }

    /// Name shown in the tool dock and in tooltips (localized at runtime).
    var title: String {
        switch self {
        case .horizontalVertical: String(localized: "Oriz./Vert.")
        case .coincident: String(localized: "Coincidente")
        case .parallel: String(localized: "Parallelo")
        case .perpendicular: String(localized: "Perpendicolare")
        case .colinear: String(localized: "Colineare")
        case .tangent: String(localized: "Tangente")
        case .equal: String(localized: "Uguale")
        case .concentric: String(localized: "Concentrico")
        case .midpoint: String(localized: "Punto medio")
        case .symmetric: String(localized: "Simmetrico")
        case .fix: String(localized: "Fisso")
        case .pointOnPlane: String(localized: "Sul piano")
        case .normalToPlane: String(localized: "Normale al piano")
        case .planeDistance: String(localized: "Distanza dal piano")
        case .lockRotation: String(localized: "Blocco rotazione")
        case .pointOnBezier: String(localized: "Punto su Bezier")
        case .bezierTangent: String(localized: "Tangente alla Bezier")
        case .bezierPerpendicular: String(localized: "Perpendicolare alla Bezier")
        }
    }

    var symbol: String {
        switch self {
        case .horizontalVertical: "arrow.up.and.down.and.arrow.left.and.right"
        case .coincident: "smallcircle.filled.circle"
        case .parallel: "equal"
        case .perpendicular: "angle"
        case .colinear: "align.horizontal.left"
        case .tangent: "circle.and.line.horizontal"
        case .equal: "equal.square"
        case .concentric: "circle.circle"
        case .midpoint: "circle.bottomhalf.filled"
        case .symmetric: "arrow.left.and.line.vertical.and.arrow.right"
        case .fix: "lock"
        case .pointOnPlane: "rectangle.dashed"
        case .normalToPlane: "arrow.up.to.line"
        case .planeDistance: "ruler"
        case .lockRotation: "lock.rotation"
        case .pointOnBezier: "smallcircle.filled.circle"
        case .bezierTangent: "circle.and.line.horizontal"
        case .bezierPerpendicular: "angle"
        }
    }

    /// Tooltip (localized at runtime).
    var hint: String {
        switch self {
        case .horizontalVertical: String(localized: "Clicca una linea: diventa orizzontale o verticale (la più vicina).")
        case .coincident: String(localized: "Clicca due punti (o un punto e una linea o un cerchio).")
        case .parallel: String(localized: "Clicca due linee.")
        case .perpendicular: String(localized: "Clicca due linee.")
        case .colinear: String(localized: "Clicca due linee: giacciono sulla stessa retta.")
        case .tangent: String(localized: "Clicca una linea e un cerchio, o due cerchi.")
        case .equal: String(localized: "Clicca due linee (stessa lunghezza) o due cerchi (stesso raggio).")
        case .concentric: String(localized: "Clicca due cerchi.")
        case .midpoint: String(localized: "Clicca un punto, poi la linea.")
        case .symmetric: String(localized: "Clicca due punti, poi la linea d'asse: i punti diventano simmetrici.")
        case .fix: String(localized: "Clicca un punto (anche 3D): resta dov'è.")
        case .pointOnPlane: String(localized: "Clicca un punto 3D: resta sul piano dello schizzo.")
        case .normalToPlane: String(localized: "Clicca una linea 3D: diventa perpendicolare al piano dello schizzo.")
        case .planeDistance: String(localized: "Clicca un punto 3D, poi scrivi la distanza dal piano (0 è sul piano).")
        case .lockRotation: String(localized: "Clicca il piano di lavoro: la sua orientazione resta bloccata, l'origine resta libera.")
        case .pointOnBezier: String(localized: "Clicca un punto, poi la curva di Bezier: il punto resta sulla curva.")
        case .bezierTangent: String(localized: "Clicca una linea e poi la curva: l'estremo più vicino resta sulla curva e la linea le è tangente.")
        case .bezierPerpendicular: String(localized: "Clicca una linea e poi la curva: l'estremo più vicino resta sulla curva e la linea le è perpendicolare.")
        }
    }
}

extension SketchSession {
    // MARK: Picking entities

    enum RefKind { case point, segment, circle, curve }

    /// What a click may select for the active constraint: the first pick and the following ones.
    func wantedKinds(for tool: ConstraintTool, picked count: Int) -> Set<RefKind> {
        switch (tool, count) {
        case (.horizontalVertical, _), (.parallel, _), (.perpendicular, _), (.colinear, _): [.segment]
        case (.fix, _), (.pointOnPlane, _), (.planeDistance, _), (.lockRotation, _): [.point]
        case (.normalToPlane, _): [.segment]
        // Coincidente takes a point and a point, or a point and a line/axis/arc, in either order.
        case (.coincident, _): [.point, .segment, .circle]
        case (.tangent, _), (.equal, _): [.segment, .circle]
        case (.concentric, _): [.circle, .point]
        case (.midpoint, 0): [.point]
        case (.midpoint, _): [.segment]
        case (.symmetric, 0), (.symmetric, 1): [.point]
        case (.symmetric, _): [.segment]
        // The Bezier constraints: a point/line first, then the curve itself.
        case (.pointOnBezier, 0): [.point]
        case (.bezierTangent, 0), (.bezierPerpendicular, 0): [.segment]
        case (.pointOnBezier, _), (.bezierTangent, _), (.bezierPerpendicular, _): [.curve]
        }
    }

    /// The entity under `p` with the priority of SolidWorks and Fusion: **a click near a vertex
    /// takes the vertex**, not the lines that meet there; then come lines (the axes included),
    /// then circles. dune3d does the same: every point is drawn as a screen-sized disk and the
    /// nearest disk wins, so corners stay point-pickable however close the edges are.
    /// Off-plane entities come first, picked where they appear on screen (they are what the user
    /// is aiming at when they are near the cursor).
    func pickRef(_ p: Vec2, kinds: Set<RefKind> = [.point, .segment, .circle], screen: CGPoint? = nil,
                 include3D: Bool = true) -> SketchRef? {
        if include3D, let ref = pickRef3D(screen: screen, kinds: kinds) { return ref }
        let tol = vertexSnap * 1.2
        // 1. Points, the origin included: they have their own radius and win outright.
        if kinds.contains(.point) {
            var best: (SketchRef, Double)?
            for s in shapes {
                for i in 0..<s.pointCount {
                    guard let q = s.point(i) else { continue }
                    let d = dist(q, p)
                    if d <= tol, d < (best?.1 ?? .infinity) { best = (.point(s.id, i), d) }
                }
            }
            // Sketch geometry wins ties with the origin: it is what the user drew.
            let dOrigin = dist(Vec2(0, 0), p)
            if dOrigin <= tol, dOrigin + tol * 0.1 < (best?.1 ?? .infinity) { best = (.origin, dOrigin) }
            if let best { return best.0 }
        }
        // 2. Lines: sketch sides first, then the axes (infinite lines through the origin).
        if kinds.contains(.segment) {
            var best: (SketchRef, Double)?
            func consider(_ r: SketchRef, _ d: Double) {
                if d <= tol, d < (best?.1 ?? .infinity) { best = (r, d) }
            }
            consider(.axisX, abs(p.y))
            consider(.axisY, abs(p.x))
            for s in shapes {
                for i in 0..<s.segmentCount {
                    guard let (a, b) = s.segment(i) else { continue }
                    consider(.segment(s.id, i), distanceToSegment(p, a, b))
                }
            }
            if let best { return best.0 }
        }
        // 3. Circles and arcs, by their rim.
        if kinds.contains(.circle) {
            var best: (SketchRef, Double)?
            for s in shapes {
                for i in 0..<2 {
                    guard let c = s.circle(i) else { continue }
                    let d = abs(dist(c.center, p) - c.radius)
                    if d <= tol, d < (best?.1 ?? .infinity) { best = (.circle(s.id, i), d) }
                }
            }
            if let best { return best.0 }
        }
        // 4. Bezier curves, by their drawn outline (the handles are not pickable; the curve is
        //    referenced as `.circle(id, 0)`, as the core's Bezier constraints expect).
        if kinds.contains(.curve) {
            var best: (SketchRef, Double)?
            for s in shapes {
                guard case .bezier = s.kind else { continue }
                let o = s.outline
                guard o.count >= 2 else { continue }
                for i in 0..<(o.count - 1) {
                    let d = distanceToSegment(p, o[i], o[i + 1])
                    if d <= tol, d < (best?.1 ?? .infinity) { best = (.circle(s.id, 0), d) }
                }
            }
            if let best { return best.0 }
        }
        return nil
    }

    // MARK: Applying constraints

    func pickForConstraint(_ p: Vec2, screen: CGPoint? = nil) {
        guard let tool = constraintTool else { return }
        let wanted = wantedKinds(for: tool, picked: picked.count)
        guard let ref = pickRef(p, kinds: wanted, screen: screen) else {
            notice = String(localized: "Niente da vincolare qui: \(tool.hint)")
            return
        }
        if picked.last == ref { return }
        picked.append(ref)
        let a = picked[0], b = picked.count > 1 ? picked[1] : nil
        var kind: SketchConstraintKind?
        switch tool {
        case .horizontalVertical:
            if a.isFixedGeometry {
                notice = a == .origin
                    ? String(localized: "L'origine non ha un'orientazione da vincolare.")
                    : String(localized: "L'asse è già orizzontale o verticale.")
                picked = []
                return
            }
            if let (u, v) = shape(a.shapeID)?.segment(index(a)) {
                kind = abs(v.x - u.x) >= abs(v.y - u.y) ? .horizontal(a) : .vertical(a)
            }
        case .fix:
            // A 3D point is pinned in all three coordinates of the plane's frame.
            if let q = point3(a) { kind = .fix3D(a, q) }
            else if let q = shape(a.shapeID)?.point(index(a)) { kind = .fix(a, q) }
        case .pointOnPlane:
            guard point3(a) != nil else {
                picked = []
                notice = String(localized: "«Sul piano»: clicca un punto 3D (quelli sul piano ci sono già).")
                return
            }
            kind = .pointOnPlane(a)
        case .normalToPlane:
            guard segment3(a) != nil else {
                picked = []
                notice = String(localized: "«Normale al piano»: clicca una linea 3D.")
                return
            }
            kind = .normalToPlane(a)
        case .planeDistance:
            guard let q = point3(a) else {
                picked = []
                notice = String(localized: "«Distanza dal piano»: clicca un punto 3D.")
                return
            }
            picked = []
            addDimension(.planeDistance(a, q.z))
            return
        case .lockRotation:
            guard let s = shape(a.shapeID), case let .workplane(o, x, p) = s.kind else {
                picked = []
                notice = String(localized: "«Blocco rotazione»: clicca un piano di lavoro.")
                return
            }
            kind = .lockRotation(a, xDirection: x - o, planeDirection: p - o)
        case .pointOnBezier:
            guard let b else { return }
            guard case let .circle(cid, 0) = b, let s = shape(cid), case .bezier = s.kind,
                  let q = point(a), let t = s.bezierParameter(nearest: q) else {
                picked = []
                notice = String(localized: "«Punto su Bezier»: clicca prima un punto, poi la curva.")
                return
            }
            kind = .pointOnBezier(a, b, t: t)
        case .bezierTangent, .bezierPerpendicular:
            guard let b else { return }
            guard !a.isFixedGeometry, case let .circle(cid, 0) = b, let s = shape(cid),
                  case let .bezier(p0, c1, c2, p3) = s.kind, let (u, v) = segment(a) else {
                picked = []
                notice = tool == .bezierTangent
                    ? String(localized: "«Tangente alla Bezier»: clicca una linea, poi la curva.")
                    : String(localized: "«Perpendicolare alla Bezier»: clicca una linea, poi la curva.")
                return
            }
            // Which end of the line lands on the curve: the nearest one.
            let tU = s.bezierParameter(nearest: u) ?? 0
            let tV = s.bezierParameter(nearest: v) ?? 1
            let atU = SketchShape.bezier(tU, start: p0, control1: c1, control2: c2, end: p3)
            let atV = SketchShape.bezier(tV, start: p0, control1: c1, control2: c2, end: p3)
            let (end, t) = dist(u, atU) <= dist(v, atV) ? (u, tU) : (v, tV)
            guard let pref = pointRef(a.shapeID, at: end) else { picked = []; return }
            kind = tool == .bezierTangent
                ? .bezierLineTangent(pref, a, b, t: t)
                : .bezierLinePerpendicular(pref, a, b, t: t)
        case .coincident:
            guard let b else { return }
            if let k = coincidentKind(a, b) {
                kind = k
            } else {
                picked = []
                notice = String(localized: "Coincidente unisce punti, oppure un punto a una linea, a un asse o a un arco. Per due linee usa «Colineare».")
                return
            }
        case .parallel: if let b { kind = .parallel(a, b) } else { return }
        case .perpendicular: if let b { kind = .perpendicular(a, b) } else { return }
        case .colinear: if let b { kind = .colinear(a, b) } else { return }
        case .tangent: if let b { kind = .tangent(a, b) } else { return }
        case .equal:
            guard let b else { return }
            guard sameKind(a, b) else { picked = [a]; notice = String(localized: "Uguale: due linee o due cerchi."); return }
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

    /// What "Coincidente" means for two picked entities, in either picking order.
    private func coincidentKind(_ a: SketchRef, _ b: SketchRef) -> SketchConstraintKind? {
        switch (a, b) {
        case (.point, .point), (.point, .origin), (.origin, .point), (.origin, .origin):
            return .coincident(a, b)
        case (.point, .segment), (.point, .axisX), (.point, .axisY),
             (.origin, .segment), (.origin, .axisX), (.origin, .axisY):
            return .pointOnLine(a, b)
        case (.segment, .point), (.axisX, .point), (.axisY, .point),
             (.segment, .origin), (.axisX, .origin), (.axisY, .origin):
            return .pointOnLine(b, a)
        case (.point, .circle), (.origin, .circle):
            return pointOnArcOrCircle(a, b)
        case (.circle, .point), (.circle, .origin):
            return pointOnArcOrCircle(b, a)
        default:
            return nil
        }
    }

    private func pointOnArcOrCircle(_ p: SketchRef, _ c: SketchRef) -> SketchConstraintKind {
        // On an arc the point is tied to the arc itself, not to its whole support circle.
        if let s = shape(c.shapeID), case .arc = s.kind { return .pointOnArc(p, c) }
        return .pointOnCircle(p, c)
    }

    /// Why a relation is refused as redundant because the shape already guarantees it: a rectangle
    /// is axis-aligned, a regular polygon has equal sides, a slot has two equal sides and arcs.
    /// dune3d turns these into explicit constraints; here they live in the entity, so the same
    /// relation cannot be added again — and the notice says so instead of just "already present".
    private func intrinsicReason(_ c: SketchConstraint) -> String? {
        let refs = c.kind.refs
        guard let first = refs.first, !first.isFixedGeometry,
              refs.allSatisfy({ $0.isFixedGeometry || $0.shapeID == first.shapeID }),
              let s = shape(first.shapeID) else { return nil }
        switch c.kind {
        case .parallel, .perpendicular, .equal, .horizontal, .vertical:
            if case .rectangle = s.kind {
                return String(localized: "«\(c.kind.label)» è già garantito dal rettangolo (lati orizzontali e verticali, opposti paralleli e uguali, adiacenti perpendicolari): non aggiunto.")
            }
            if case .slot = s.kind, case .parallel = c.kind {
                return String(localized: "«\(c.kind.label)» è già garantito dall'asola (2 lati paralleli e uguali, 2 archi dello stesso raggio): non aggiunto.")
            }
            if case .polygon = s.kind, case .equal = c.kind {
                return String(localized: "«\(c.kind.label)» è già garantito dal poligono regolare (lati tutti uguali): non aggiunto.")
            }
        default:
            break
        }
        return nil
    }

    /// Adds a constraint if the sketch can satisfy it (otherwise explains and leaves it out).
    /// A constraint that only repeats what the others already say is refused too: it would
    /// over-constrain the sketch without adding anything.
    @discardableResult
    func apply(_ c: SketchConstraint) -> Bool {
        if !c.isReference {
            switch SketchSolver.check(sketch.shapes, sketch.constraints, adding: c) {
            case .redundant:
                notice = intrinsicReason(c) ?? String(localized: "«\(c.kind.label)» ripete un vincolo già presente: non aggiunto.")
                return false
            case .infeasible:
                notice = String(localized: "«\(c.kind.label)» è in conflitto con i vincoli esistenti: non aggiunto.")
                return false
            case .ok:
                break
            }
        }
        var next = sketch
        next.constraints.append(c)
        guard next.solve(after: c.id) else {
            notice = String(localized: "«\(c.kind.label)» è in conflitto con i vincoli esistenti: non aggiunto.")
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
        case .bezier: [0, 1, 2, 3]
        case .rectangle: [0, 1, 2, 3]
        case .circle, .polygon: [0]
        case .slot: [0, 1]
        case .arc: [1, 2]
        case .point3D, .line3D, .workplane: []
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
                    out.append(.init(.midpoint(.point(new.id, i), .segment(other.id, k)))); linked = true; break
                }
            }
            if linked { continue }
            // Snapped onto a line or a circle: it stays on it.
            for other in shapes where other.id != new.id {
                if let k = (0..<other.segmentCount).first(where: { other.segment($0).map { distanceToSegment(p, $0.0, $0.1) < eps } ?? false }) {
                    out.append(.init(.pointOnLine(.point(new.id, i), .segment(other.id, k)))); break
                }
                if let c = other.circle(0), abs(dist(p, c.center) - c.radius) < eps {
                    if case .slot = other.kind { continue }
                    out.append(.init(.pointOnCircle(.point(new.id, i), .circle(other.id, 0)))); break
                }
            }
        }
        // Arcs and lines drawn on from each other's ends along the same direction: tangent.
        out += sketch.tangentAutoConstraints(for: new)
        // 3D endpoints landing on an existing 3D point stay joined (as 2D vertices do).
        if new.is3D {
            for i in 0..<new.pointCount {
                guard let q = new.point3D(i) else { continue }
                for other in shapes where other.id != new.id && other.is3D {
                    if let j = (0..<other.pointCount).first(where: { other.point3D($0).map { ($0 - q).length < eps } ?? false }) {
                        out.append(.init(.coincident(.point(new.id, i), .point(other.id, j))))
                        break
                    }
                }
            }
        }
        return out
    }

    // MARK: Dimensions

    func pickForDimension(_ p: Vec2, screen: CGPoint? = nil) {
        let ref = pickRef(p, screen: screen)
        switch (picked.first, ref) {
        case (nil, nil): return
        case (nil, .circle?):
            addDimension(.diameter(ref!, 2 * (circle(ref!)?.radius ?? 0)))
        case (nil, let r?):
            picked = [r]
            notice = r.isPoint ? String(localized: "Clicca un altro punto o una linea.") : String(localized: "Clicca un'altra linea (angolo), oppure in un punto vuoto per la lunghezza.")
        case (let a?, nil):
            // Line then empty space: its length.
            picked = []
            notice = nil
            if let (u, v) = segment3(a) { addDimension(.length(a, (v - u).length)) }
            else if case .segment = a, let (u, v) = segment(a) { addDimension(.length(a, dist(u, v))) }
        case (let a?, let b?):
            picked = []
            notice = nil
            // Off-plane pairs: the true 3D distance, point–point or point–line.
            if let q = point3(a), let w = point3(b) { addDimension(.distance(a, b, (w - q).length)); return }
            if let q = point3(a), let (u, v) = segment3(b) { addDimension(.distance(a, b, pointLineDistance3(q, u, v))); return }
            if let q = point3(b), let (u, v) = segment3(a) { addDimension(.distance(a, b, pointLineDistance3(q, u, v))); return }
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

    /// A new dimension at the current measure, its value field opened for typing. With "Rif."
    /// active the dimension only measures (it never drives the sketch), as in Fusion.
    private func addDimension(_ kind: SketchConstraintKind) {
        let reference = referenceNextDimension
        referenceNextDimension = false
        let c = SketchConstraint(kind.with(value: ((kind.value ?? 0) * 100).rounded() / 100), isReference: reference)
        if apply(c) { editingDimension = c.isReference ? nil : c.id }
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
            notice = String(localized: "Quota: \(error.localizedDescription)")
            return false
        }
    }

    /// Sets a dimension's value (typed or from a parameter); false when the sketch cannot take it.
    @discardableResult
    func setDimension(_ id: SketchConstraint.ID, value: Double, expression: String? = nil) -> Bool {
        guard let i = sketch.constraints.firstIndex(where: { $0.id == id }), value.isFinite else { return false }
        if case .angle = sketch.constraints[i].kind {} else { guard value > 0 else { notice = String(localized: "Il valore deve essere positivo."); return false } }
        var next = sketch
        next.constraints[i].kind = next.constraints[i].kind.with(value: value)
        next.constraints[i].expression = expression
        guard next.solve(after: next.constraints[i].id) else { notice = String(localized: "Con \(fmt(value)) i vincoli non si possono rispettare: valore non applicato."); return false }
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
        if next.solve() { sketch = next } else { notice = String(localized: "Lo schizzo non riesce a seguire i nuovi parametri.") }
    }

    // MARK: Dragging

    /// Starts dragging the point under `p` (Seleziona). A shape's centre grip moves the whole shape;
    /// rectangles keep their opposite corner when dragged by a corner.
    func beginDrag(_ world: SIMD3<Float>) -> Bool {
        guard tool == .select, constraintTool == nil else { return false }
        let p = local(world)
        // The centre grip of a rectangle, circle or polygon translates the whole shape.
        if let id = gripHit(p), let s = shape(id), let anchor = s.point(0) {
            dragRef = .point(id, 0)
            shapeDrag = (id, p, anchor)
            dragFixes = []
            setBlocking([])
            recordStep()
            dragging = true
            return true
        }
        guard let ref = pickRef(p, kinds: [.point], include3D: false) else { return false }
        dragRef = ref
        dragFixes = []
        setBlocking([])
        if case let .point(id, i) = ref, let s = shape(id), case .rectangle = s.kind, i < 4, let opposite = s.point((i + 2) % 4) {
            dragFixes = [SketchConstraint(.fix(.point(id, (i + 2) % 4), opposite))]
        }
        recordStep()
        dragging = true
        return true
    }

    func drag(_ world: SIMD3<Float>) {
        guard let ref = dragRef else { return }
        let cursor = local(world)
        let target = shapeDrag.map { $0.anchor + (cursor - $0.startCursor) } ?? snapForDrag(cursor)
        var next = sketch
        next.constraints += dragFixes
        // The drag loop only needs the solved shapes: no DOF/conflict analysis on every mouse move.
        let result = SketchSolver.solve(next.shapes, next.constraints, drag: (ref, target), diagnosis: false)
        guard result.converged else { return }
        next.shapes = result.shapes
        next.constraints.removeAll { c in dragFixes.contains { $0.id == c.id } }
        sketch = next
        setBlocking(result.blocking)
    }

    func endDrag() {
        dragRef = nil
        dragFixes = []
        shapeDrag = nil
        dragging = false
        setBlocking([])
        // One full analysis per drag, on release: the panels may have gone stale while moving.
        analyze()
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
        /// A reference dimension only measures: it never drives the sketch.
        let isReference: Bool
    }

    /// One label per constraint: a small symbol for geometric ones, the value for dimensions.
    /// Reference dimensions show the measure taken from the geometry right now.
    func annotations() -> [Annotation] {
        let off = vertexSnap * 2.2
        return sketch.constraints.compactMap { c -> Annotation? in
            let measuredKind = c.isReference ? c.kind.with(value: (measured(c.kind) ?? c.kind.value ?? 0)) : c.kind
            guard let (anchor, text) = labelAnchor(measuredKind, offset: off) else { return nil }
            let driven = c.kind.value != nil && !c.isReference ? c.expression : nil
            let label = c.isReference ? String(localized: "Rif. ") + text : text
            return Annotation(id: c.id, anchor: anchor, text: driven == nil ? label : "fx: " + label,
                              isDimension: c.kind.value != nil, value: measuredKind.value, expression: driven,
                              isReference: c.isReference)
        }
    }

    /// Where a constraint's label goes: a 3D entity's label sits on it in depth, a planar
    /// constraint's on the sketch plane.
    private func labelAnchor(_ k: SketchConstraintKind, offset off: Double) -> (SIMD3<Float>, String)? {
        if let (at, text) = placement3D(k, offset: off) { return (world(at), text) }
        if let (at, text) = placement(k, offset: off) { return (world(at, 0.05), text) }
        return nil
    }

    /// The value a dimension measures on the sketch as it is (for reference dimensions).
    private func measured(_ k: SketchConstraintKind) -> Double? {
        switch k {
        case let .length(r, _):
            if let (u, v) = segment3(r) { return (v - u).length }
            guard let (u, v) = segment(r) else { return nil }
            return dist(u, v)
        case let .radius(r, _): return circle(r)?.radius
        case let .diameter(r, _): return circle(r).map { 2 * $0.radius }
        case let .planeDistance(r, _): return point3(r)?.z
        case let .distance(a, b, _):
            if let q = point3(a), let w = point3(b) { return (w - q).length }
            if let q = point3(a), let (u, v) = segment3(b) { return pointLineDistance3(q, u, v) }
            if let q = point3(b), let (u, v) = segment3(a) { return pointLineDistance3(q, u, v) }
            if let u = point(a), let v = point(b) { return dist(u, v) }
            if let q = point(a) ?? point(b), let (u, v) = segment(a.isPoint ? b : a) { return distanceToLineInfinite(q, u, v) }
            if let (u1, v1) = segment(a), let (u2, _) = segment(b) { return distanceToLineInfinite(u2, u1, v1) }
            return nil
        case let .horizontalDistance(a, b, _):
            if let u = point3(a), let v = point3(b) { return abs(v.x - u.x) }
            guard let u = point(a), let v = point(b) else { return nil }
            return abs(v.x - u.x)
        case let .verticalDistance(a, b, _):
            if let u = point3(a), let v = point3(b) { return abs(v.y - u.y) }
            guard let u = point(a), let v = point(b) else { return nil }
            return abs(v.y - u.y)
        case let .angle(a, b, _):
            guard let (u1, v1) = segment(a), let (u2, v2) = segment(b) else { return nil }
            let d1 = v1 - u1, d2 = v2 - u2
            return atan2(d1.cross(d2), d1.x * d2.x + d1.y * d2.y) * 180 / .pi
        default: return nil
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
                if let (u, v) = segment3(ref) {
                    let n = normal(Vec2(u.x, u.y), Vec2(v.x, v.y)) * off
                    out += [(world(Vec2(u.x, u.y), u.z + 0.04), world(Vec2(u.x + n.x * 1.2, u.y + n.y * 1.2), u.z + 0.04), color),
                            (world(Vec2(v.x, v.y), v.z + 0.04), world(Vec2(v.x + n.x * 1.2, v.y + n.y * 1.2), v.z + 0.04), color),
                            (world(Vec2(u.x + n.x, u.y + n.y), u.z + 0.04), world(Vec2(v.x + n.x, v.y + n.y), v.z + 0.04), color)]
                    continue
                }
                guard let (u, v) = segment(ref) else { continue }
                let n = normal(u, v) * off
                out += [(w(u), w(u + n * 1.2), color), (w(v), w(v + n * 1.2), color), (w(u + n), w(v + n), color)]
            case let .distance(a, b, _) where a.isPoint && b.isPoint:
                if let u = point3(a), let v = point3(b) {
                    let n = normal(Vec2(u.x, u.y), Vec2(v.x, v.y)) * off
                    out += [(world(Vec2(u.x, u.y), u.z + 0.04), world(Vec2(u.x + n.x * 1.2, u.y + n.y * 1.2), u.z + 0.04), color),
                            (world(Vec2(v.x, v.y), v.z + 0.04), world(Vec2(v.x + n.x * 1.2, v.y + n.y * 1.2), v.z + 0.04), color),
                            (world(Vec2(u.x + n.x, u.y + n.y), u.z + 0.04), world(Vec2(v.x + n.x, v.y + n.y), v.z + 0.04), color)]
                    continue
                }
                guard let u = point(a), let v = point(b) else { continue }
                let n = normal(u, v) * off
                out += [(w(u), w(u + n * 1.2), color), (w(v), w(v + n * 1.2), color), (w(u + n), w(v + n), color)]
            case let .planeDistance(ref, _):
                guard let q = point3(ref) else { continue }
                out.append((world(Vec2(q.x, q.y), 0.02), world(q), color))
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
        case let .parallel(a, _), let .smooth(a, _): return mid(a).map { ($0, "∥") }
        case let .colinear(a, _): return mid(a).map { ($0, "≡") }
        case let .perpendicular(a, _): return mid(a).map { ($0, "⊥") }
        case let .equal(a, _): return (mid(a) ?? circle(a).map { $0.center + Vec2(0, $0.radius + off * 0.6) }).map { ($0, "=") }
        case let .tangent(a, b): return (mid(a) ?? mid(b)).map { ($0, "T") }
        case let .concentric(a, _): return circle(a).map { ($0.center + Vec2(off * 0.6, off * 0.6), "◎") }
        case let .coincident(a, _), let .pointOnLine(a, _), let .pointOnCircle(a, _),
             let .pointOnArc(a, _), let .pointOnBezier(a, _, _),
             let .bezierLineTangent(a, _, _, _), let .bezierLinePerpendicular(a, _, _, _):
            return point(a).map { ($0 + Vec2(off * 0.5, off * 0.5), "•") }
        case let .midpoint(a, _): return point(a).map { ($0 + Vec2(off * 0.5, off * 0.5), "½") }
        case let .symmetric(_, b, _): return point(b).map { ($0 + Vec2(off * 0.5, -off * 0.5), "⇋") }
        case let .fix(a, _): return point(a).map { ($0 + Vec2(-off * 0.6, -off * 0.6), "🔒") }
        // 3D relations live in the viewport's depth: their labels arrive with T137.
        case .pointOnPlane, .normalToPlane, .fix3D, .planeDistance, .lockRotation: return nil
        case let .length(r, v):
            guard let (u, w) = segment(r) else { return nil }
            return ((u + w) * 0.5 + normal(u, w) * off, fmt(v))
        case let .distance(a, b, v), let .offset(a, b, v):
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

    /// Where a 3D constraint's label goes, in the plane's frame (the viewport projects it).
    /// Nil for the planar constraints, which `placement` handles.
    private func placement3D(_ k: SketchConstraintKind, offset off: Double) -> (Vec3, String)? {
        switch k {
        case let .pointOnPlane(a): return point3(a).map { ($0, "▽") }
        case let .normalToPlane(a): return segment3(a).map { (($0.0 + $0.1) * 0.5, "⇡") }
        case let .fix3D(a, _): return point3(a).map { ($0, "🔒") }
        case let .planeDistance(a, v): return point3(a).map { ($0, fmt(v)) }
        case let .length(r, v): return segment3(r).map { (($0.0 + $0.1) * 0.5, fmt(v)) }
        case let .distance(a, b, v):
            if let u = point3(a), let q = point3(b) { return ((u + q) * 0.5, fmt(v)) }
            if let u = point3(a) ?? point3(b) { return (u, fmt(v)) }
            return nil
        case let .horizontalDistance(a, b, v), let .verticalDistance(a, b, v):
            guard let u = point3(a), let q = point3(b) else { return nil }
            return ((u + q) * 0.5, fmt(v))
        case let .coincident(a, _): return point3(a).map { ($0, "•") }
        default: return nil
        }
    }

    // MARK: Helpers

    private func index(_ r: SketchRef) -> Int {
        switch r {
        case let .point(_, i), let .segment(_, i), let .circle(_, i): i
        case .origin, .axisX, .axisY: 0
        }
    }

    /// The point reference of a shape at a given position (e.g. an end of a picked segment).
    private func pointRef(_ id: SketchShape.ID, at p: Vec2) -> SketchRef? {
        guard let s = shape(id) else { return nil }
        for i in 0..<s.pointCount where s.point(i).map({ dist($0, p) < 1e-9 }) == true {
            return .point(id, i)
        }
        return nil
    }
    private func point(_ r: SketchRef) -> Vec2? {
        switch r {
        case let .point(id, i): return shape(id)?.point(i)
        case .origin: return Vec2(0, 0)
        case .segment, .circle, .axisX, .axisY: return nil
        }
    }
    private func segment(_ r: SketchRef) -> (Vec2, Vec2)? {
        switch r {
        case let .segment(id, i): return shape(id)?.segment(i)
        case .axisX: return (Vec2(0, 0), Vec2(1, 0))
        case .axisY: return (Vec2(0, 0), Vec2(0, 1))
        case .point, .circle, .origin: return nil
        }
    }
    private func circle(_ r: SketchRef) -> (center: Vec2, radius: Double)? {
        if case let .circle(id, i) = r { return shape(id)?.circle(i) }
        return nil
    }
    private func sameKind(_ a: SketchRef, _ b: SketchRef) -> Bool { (a.isCircle && b.isCircle) || (!a.isCircle && !b.isCircle && !a.isPoint && !b.isPoint) }
    private func normal(_ u: Vec2, _ v: Vec2) -> Vec2 {
        let d = v - u, l = max(dist(u, v), 1e-9)
        return Vec2(-d.y / l, d.x / l)
    }
    private func distanceToLineInfinite(_ p: Vec2, _ a: Vec2, _ b: Vec2) -> Double {
        abs((b - a).cross(p - a)) / max(dist(a, b), 1e-9)
    }

    /// A 3D point reference; nil for the planar entities.
    private func point3(_ r: SketchRef) -> Vec3? {
        if case let .point(id, i) = r { return shape(id)?.point3D(i) }
        return nil
    }

    /// The segment of a 3D line reference; nil for the planar entities.
    private func segment3(_ r: SketchRef) -> (Vec3, Vec3)? {
        if case let .segment(id, i) = r { return shape(id)?.segment3D(i) }
        return nil
    }

    /// Distance from a point to the infinite line through u–v, in 3D.
    private func pointLineDistance3(_ p: Vec3, _ u: Vec3, _ v: Vec3) -> Double {
        let d = v - u
        guard d.length > 1e-12 else { return (p - u).length }
        return (p - u).cross(d).length / d.length
    }
}

extension SketchRef {
    var isPoint: Bool { if case .point = self { true } else { if case .origin = self { true } else { false } } }
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
        var next = sketch
        do {
            let arc: UUID
            if let (a, ia, b, ib) = jointUnder(p) {
                // Two separate lines meeting at a corner: one fillet.
                arc = chamfer ? try next.chamfer(a, vertex: ia, b, vertex: ib, distance: chamferDistance)
                              : try next.fillet(a, vertex: ia, b, vertex: ib, radius: filletRadius)
            } else if let id = pick(p), let s = shape(id), isWholeCornerShape(s) {
                // Clicking a rectangle or a polygon rounds/smussoes all its corners in one step.
                let made = chamfer ? try next.chamferAllCorners(id, distance: chamferDistance)
                                   : try next.filletAllCorners(id, radius: filletRadius)
                guard next.solve() else {
                    notice = (chamfer ? String(localized: "Smusso in conflitto con i vincoli dello schizzo.") : String(localized: "Raccordo in conflitto con i vincoli dello schizzo."))
                    return
                }
                notice = nil
                sketch = next
                selection = nearest(of: made, to: p, in: next) ?? made.first
                return
            } else if let (id, i, _) = cornerUnder(p) {
                arc = chamfer ? try next.chamfer(id, vertex: i, distance: chamferDistance)
                              : try next.fillet(id, vertex: i, radius: filletRadius)
            } else {
                notice = String(localized: "Clicca vicino all'angolo tra due lati (anche di un rettangolo).")
                return
            }
            guard next.solve() else { notice = (chamfer ? String(localized: "Smusso in conflitto con i vincoli dello schizzo.") : String(localized: "Raccordo in conflitto con i vincoli dello schizzo.")); return }
            notice = nil
            sketch = next
            selection = arc
        } catch {
            notice = (chamfer ? String(localized: "Smusso: \(error.localizedDescription)") : String(localized: "Raccordo: \(error.localizedDescription)"))
        }
    }

    /// A rectangle or a polygon whose click means "all the corners" (a closed polyline keeps the
    /// single-corner behaviour).
    private func isWholeCornerShape(_ s: SketchShape) -> Bool {
        switch s.kind {
        case .rectangle, .polygon: return true
        default: return false
        }
    }

    /// The arc/chamfer line among `ids` whose middle is nearest to the click: what gets selected.
    private func nearest(of ids: [UUID], to p: Vec2, in sketch: Sketch) -> UUID? {
        ids.min { a, b in
            func d(_ id: UUID) -> Double {
                guard let s = sketch.shapes.first(where: { $0.id == id }), let prim = s.prims.first else { return .infinity }
                return (prim.at(0.5) - p).length
            }
            return d(a) < d(b)
        }
    }

    /// The corner where two separate open lines meet near `p` (the sides of the new rectangles):
    /// the two line IDs and which end of each is the corner. When lines are joined, clicking near
    /// the corner finds it even though each line's free end is not a "corner" of its own.
    private func jointUnder(_ p: Vec2) -> (UUID, Int, UUID, Int)? {
        let tol = max(vertexSnap * 3.5, 1e-6)
        var ends: [(UUID, Int, Vec2)] = []
        for s in shapes {
            guard case let .polyline(pts, closed) = s.kind, !closed, pts.count >= 2 else { continue }
            ends.append((s.id, 0, pts[0]))
            ends.append((s.id, pts.count - 1, pts[pts.count - 1]))
        }
        var best: (UUID, Int, UUID, Int, Double)?
        for i in 0..<ends.count {
            for j in (i + 1)..<ends.count where ends[i].0 != ends[j].0 {
                guard dist(ends[i].2, ends[j].2) < 1e-5 else { continue }
                let d = dist(ends[i].2, p)
                if d <= tol, d < (best?.4 ?? .infinity) { best = (ends[i].0, ends[i].1, ends[j].0, ends[j].1, d) }
            }
        }
        return best.map { ($0.0, $0.1, $0.2, $0.3) }
    }

    /// The corner nearest to `p`: a polyline vertex or a rectangle corner. The radius is generous
    /// on purpose — people click near the corner of a rectangle, not exactly on the vertex, and a
    /// rectangle is one entity whose four sides are still four pickable lines (Lato 1…4).
    private func cornerUnder(_ p: Vec2) -> (UUID, Int, SketchShape)? {
        let tol = max(vertexSnap * 3.5, 1e-6)
        var best: (UUID, Int, SketchShape, Double)?
        for s in shapes {
            switch s.kind {
            case let .polyline(pts, closed):
                let n = pts.count
                for i in 0..<n {
                    // An open line's free ends are not corners between two sides.
                    if !closed && (i == 0 || i == n - 1) { continue }
                    let d = dist(pts[i], p)
                    if d <= tol, d < (best?.3 ?? .infinity) { best = (s.id, i, s, d) }
                }
            case .rectangle:
                for i in 0..<4 {
                    guard let q = s.point(i) else { continue }
                    let d = dist(q, p)
                    if d <= tol, d < (best?.3 ?? .infinity) { best = (s.id, i, s, d) }
                }
            default:
                break
            }
        }
        return best.map { ($0.0, $0.1, $0.2) }
    }
}
