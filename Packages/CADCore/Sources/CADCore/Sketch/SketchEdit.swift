import Foundation

// Sketch editing as in Fusion: trim, extend, offset and mirror. They work on the exact pieces of the
// curves (segments and arcs), not on the tessellated outlines, and carry the constraints over.

/// An exact piece of a sketch curve, parametrised by t ∈ [0, 1].
public enum SketchPrim: Equatable, Sendable {
    case line(Vec2, Vec2)
    /// Counter-clockwise from `start` through `sweep` radians (2π: a full circle).
    case arc(center: Vec2, radius: Double, start: Double, sweep: Double)

    public func at(_ t: Double) -> Vec2 {
        switch self {
        case let .line(a, b): return a + (b - a) * t
        case let .arc(c, r, a0, sw):
            let a = a0 + sw * t
            return Vec2(c.x + r * cos(a), c.y + r * sin(a))
        }
    }

    var isFullCircle: Bool { if case let .arc(_, _, _, sw) = self { sw >= 2 * .pi - 1e-9 } else { false } }

    /// Parameter of a point on the (infinite) line or (full) circle: for an arc, the angle from
    /// `start` counter-clockwise over the sweep (beyond 1 past the end).
    func param(_ q: Vec2) -> Double {
        switch self {
        case let .line(a, b):
            let d = b - a
            return ((q.x - a.x) * d.x + (q.y - a.y) * d.y) / max(d.x * d.x + d.y * d.y, 1e-18)
        case let .arc(c, _, a0, sw):
            return SketchEdit.angle(atan2(q.y - c.y, q.x - c.x) - a0) / sw
        }
    }

    public func distance(to p: Vec2) -> Double {
        switch self {
        case .line:
            let t = max(0, min(1, param(p)))
            return (p - at(t)).length
        case let .arc(c, r, _, _):
            if isFullCircle || param(p) <= 1 { return abs((p - c).length - r) }
            return min((p - at(0)).length, (p - at(1)).length)
        }
    }

    /// Points along the piece between two parameters (for previews).
    public func points(from t0: Double, to t1: Double) -> [Vec2] {
        switch self {
        case .line: return [at(t0), at(t1)]
        case let .arc(_, _, _, sw):
            let n = max(2, Int((abs(t1 - t0) * sw / (2 * .pi) * Double(SketchShape.arcSegments)).rounded(.up)))
            return (0...n).map { at(t0 + (t1 - t0) * Double($0) / Double(n)) }
        }
    }
}

enum SketchEdit {
    /// Angle in [0, 2π).
    static func angle(_ a: Double) -> Double {
        var x = a.truncatingRemainder(dividingBy: 2 * .pi)
        if x < 0 { x += 2 * .pi }
        if x >= 2 * .pi - 1e-12 { x = 0 }
        return x
    }

    /// Where the infinite lines through a0–b0 and a1–b1 meet (nil when parallel).
    static func meet(_ a0: Vec2, _ b0: Vec2, _ a1: Vec2, _ b1: Vec2) -> Vec2? {
        let d1 = b0 - a0, d2 = b1 - a1
        let den = d1.cross(d2)
        guard abs(den) > 1e-9 * max(d1.length * d2.length, 1e-12) else { return nil }
        return a0 + d1 * ((a1 - a0).cross(d2) / den)
    }

    /// Where `a` meets `b`, as parameters on `a`. `b` is always bounded; `a` is bounded unless
    /// `extendA` (then its line is infinite, its arc a full circle).
    static func hits(_ a: SketchPrim, _ b: SketchPrim, extendA: Bool = false) -> [Double] {
        let eps = 1e-9
        func onB(_ q: Vec2) -> Bool {
            if b.isFullCircle { return true }
            let t = b.param(q)
            if case .arc = b { return t <= 1 + eps || (q - b.at(0)).length < 1e-7 }
            return t >= -eps && t <= 1 + eps
        }
        func onA(_ t: Double) -> Bool { extendA || a.isFullCircle || (t >= -eps && t <= 1 + eps) }
        var points: [Vec2] = []
        switch (a, b) {
        case let (.line(p, q), .line(u, v)):
            let d1 = q - p, d2 = v - u
            let den = d1.cross(d2)
            guard abs(den) > 1e-12 * max(d1.length * d2.length, 1e-12) else { return [] }
            let t = (u - p).cross(d2) / den
            points = [p + d1 * t]
        case let (.line(p, q), .arc(c, r, _, _)), let (.arc(c, r, _, _), .line(p, q)):
            let d = q - p, f = p - c
            let A = d.dot(d), B = 2 * f.dot(d), C = f.dot(f) - r * r
            let disc = B * B - 4 * A * C
            guard A > 1e-18, disc >= -1e-12 else { return [] }
            let s = max(disc, 0).squareRoot()
            points = Set([(-B - s) / (2 * A), (-B + s) / (2 * A)]).map { p + d * $0 }
        case let (.arc(c1, r1, _, _), .arc(c2, r2, _, _)):
            let d = (c2 - c1).length
            guard d > 1e-12, d <= r1 + r2 + 1e-9, d >= abs(r1 - r2) - 1e-9 else { return [] }
            let x = (d * d + r1 * r1 - r2 * r2) / (2 * d)
            let h = max(r1 * r1 - x * x, 0).squareRoot()
            let e = (c2 - c1) * (1 / d), m = c1 + e * x, n = Vec2(-e.y, e.x)
            points = h < 1e-12 ? [m] : [m + n * h, m - n * h]
        }
        return points.filter(onB).map { a.param($0) }.filter(onA)
    }
}

extension SketchShape {
    /// The exact pieces of the curve, in outline order.
    public var prims: [SketchPrim] {
        switch kind {
        case .polyline, .rectangle, .polygon:
            return (0..<segmentCount).compactMap { segment($0).map { SketchPrim.line($0.0, $0.1) } }
        case .spline:
            // Its sampled curve (others trim and extend against it; it is not trimmed itself).
            let o = outline
            let count = isClosed ? o.count : o.count - 1
            return (0..<max(0, count)).map { SketchPrim.line(o[$0], o[($0 + 1) % o.count]) }
        case let .circle(c, r):
            return [.arc(center: c, radius: r, start: 0, sweep: 2 * .pi)]
        case let .arc(c, r, a0, a1):
            return [.arc(center: c, radius: r, start: a0, sweep: Self.sweep(a0, a1))]
        case let .slot(a, b, w):
            guard let (p0, q0) = segment(0), let (p1, q1) = segment(1) else { return [] }
            let base = atan2(b.y - a.y, b.x - a.x)
            return [.line(p0, q0), .arc(center: b, radius: w / 2, start: base - .pi / 2, sweep: .pi),
                    .line(p1, q1), .arc(center: a, radius: w / 2, start: base + .pi / 2, sweep: .pi)]
        }
    }

    /// Rectangles, polygons and slots as lines and arcs (trim and extend work on those), with the
    /// constraints a rectangle implied. Nil when the shape already is made of them.
    func exploded() -> (shapes: [SketchShape], implied: [SketchConstraint])? {
        switch kind {
        case .rectangle:
            let s = SketchShape(id: id, kind: .polyline((0..<4).compactMap { point($0) }, closed: true), isConstruction: isConstruction)
            return ([s], [.init(.horizontal(.segment(id, 0))), .init(.vertical(.segment(id, 1))),
                          .init(.horizontal(.segment(id, 2))), .init(.vertical(.segment(id, 3)))])
        case let .polygon(_, _, n, _, _):
            let s = SketchShape(id: id, kind: .polyline((1...max(3, n)).compactMap { point($0) }, closed: true), isConstruction: isConstruction)
            return ([s], [])
        case .slot:
            let p = prims
            guard p.count == 4, case let .line(a0, b0) = p[0], case let .line(a1, b1) = p[2],
                  case let .arc(cb, r, sb, _) = p[1], case let .arc(ca, _, sa, _) = p[3] else { return nil }
            let l0 = SketchShape(id: id, kind: .polyline([a0, b0], closed: false), isConstruction: isConstruction)
            let arcB = SketchShape(kind: .arc(center: cb, radius: r, start: sb, end: sb + .pi), isConstruction: isConstruction)
            let l1 = SketchShape(kind: .polyline([a1, b1], closed: false), isConstruction: isConstruction)
            let arcA = SketchShape(kind: .arc(center: ca, radius: r, start: sa, end: sa + .pi), isConstruction: isConstruction)
            let implied: [SketchConstraint] = [
                .init(.coincident(.point(l0.id, 1), .point(arcB.id, 1))), .init(.coincident(.point(arcB.id, 2), .point(l1.id, 0))),
                .init(.coincident(.point(l1.id, 1), .point(arcA.id, 1))), .init(.coincident(.point(arcA.id, 2), .point(l0.id, 0))),
                .init(.tangent(.segment(l0.id, 0), .circle(arcB.id, 0))), .init(.tangent(.segment(l1.id, 0), .circle(arcB.id, 0))),
                .init(.tangent(.segment(l1.id, 0), .circle(arcA.id, 0))), .init(.tangent(.segment(l0.id, 0), .circle(arcA.id, 0))),
                .init(.equal(.circle(arcA.id, 0), .circle(arcB.id, 0))),
            ]
            return ([l0, arcB, l1, arcA], implied)
        default:
            return nil
        }
    }
}

extension Sketch {
    // MARK: Replacing shapes

    /// Puts `new` where the shape `id` was and moves its constraints onto the new shapes by position:
    /// a point to the new point in the same place, a line to the new line on it, a circle to the
    /// new one with the same centre and radius. Constraints that no longer find their entities
    /// go, and so do lengths of lines that got shorter or longer.
    mutating func replaceShape(_ id: UUID, with new: [SketchShape], implied: [SketchConstraint] = []) {
        guard let k = shapes.firstIndex(where: { $0.id == id }) else { return }
        let old = shapes[k]
        shapes.replaceSubrange(k...k, with: new)
        let tol = 1e-6
        constraints = constraints.compactMap { c in
            guard c.kind.refs.contains(where: { $0.shapeID == id }) else { return c }
            var resized = false
            let kind = c.kind.mapRefs { ref in
                guard ref.shapeID == id else { return ref }
                switch ref {
                case let .point(_, j):
                    guard let q = old.point(j) else { return nil }
                    for s in new { for m in 0..<s.pointCount where s.point(m).map({ ($0 - q).length < tol }) == true { return .point(s.id, m) } }
                    return nil
                case let .segment(_, j):
                    guard let (a, b) = old.segment(j) else { return nil }
                    let line = SketchPrim.line(a, b), l = (b - a).length
                    for s in new {
                        for m in 0..<s.segmentCount {
                            guard let (u, v) = s.segment(m) else { continue }
                            let d = b - a
                            let off = max(abs(d.cross(u - a)), abs(d.cross(v - a))) / max(l, 1e-12)
                            let mid = line.param((u + v) * 0.5)
                            guard off < tol, mid > -1e-9, mid < 1 + 1e-9 else { continue }
                            if abs((v - u).length - l) > tol { resized = true }
                            return .segment(s.id, m)
                        }
                    }
                    return nil
                case let .circle(_, j):
                    guard let c0 = old.circle(j) else { return nil }
                    for s in new {
                        for m in 0..<2 {
                            if let c1 = s.circle(m), (c1.center - c0.center).length < tol, abs(c1.radius - c0.radius) < tol { return .circle(s.id, m) }
                        }
                    }
                    return nil
                }
            }
            guard let kind else { return nil }
            if resized { switch kind { case .length, .equal, .midpoint: return nil; default: break } }
            var moved = c
            moved.kind = kind
            return moved
        }
        constraints += implied
    }

    /// Rectangles, polygons and slots become lines and arcs (same IDs where it can).
    mutating func explode(_ id: UUID) {
        guard let s = shapes.first(where: { $0.id == id }), let (parts, implied) = s.exploded() else { return }
        replaceShape(id, with: parts, implied: implied)
    }

    /// The piece of curve nearest to `p` (within `tolerance`).
    func nearestPrim(_ p: Vec2, tolerance: Double, where accept: (SketchShape, Int) -> Bool = { _, _ in true }) -> (shape: Int, prim: Int)? {
        var best: (Int, Int, Double)?
        for (k, s) in shapes.enumerated() {
            for (i, prim) in s.prims.enumerated() where accept(s, i) {
                let d = prim.distance(to: p)
                if d <= tolerance, d < (best?.2 ?? .infinity) { best = (k, i, d) }
            }
        }
        return best.map { ($0.0, $0.1) }
    }

    /// Parameters where the piece `prim` of shape `k` is cut by every other curve of the sketch.
    func cuts(shape k: Int, prim i: Int) -> [Double] {
        let prim = shapes[k].prims[i]
        var out: [Double] = []
        for (m, s) in shapes.enumerated() {
            for (j, other) in s.prims.enumerated() where !(m == k && j == i) {
                out += SketchEdit.hits(prim, other)
            }
        }
        return out
    }

    // MARK: Trim

    /// The piece of curve a click at `p` would trim away: up to the nearest crossings (or the
    /// ends) on either side. Nil when nothing is under the cursor.
    public func trimPiece(at p: Vec2, tolerance: Double) -> [Vec2]? {
        guard let t = trimTarget(p, tolerance: tolerance) else { return nil }
        let prim = shapes[t.shape].prims[t.prim]
        return prim.points(from: t.t0, to: t.t1)
    }

    private func trimTarget(_ p: Vec2, tolerance: Double) -> (shape: Int, prim: Int, t0: Double, t1: Double)? {
        guard let (k, i) = nearestPrim(p, tolerance: tolerance) else { return nil }
        let prim = shapes[k].prims[i]
        let eps = 1e-7
        let tc = prim.param(p)
        let raw = cuts(shape: k, prim: i)
        if prim.isFullCircle {
            let c = Array(Set(raw.map { $0 >= 1 - eps ? 0 : max(0, $0) }.map { ($0 * 1e9).rounded() / 1e9 })).sorted()
            guard c.count >= 2 else { return (k, i, 0, 1) }
            let tcc = min(max(tc, 0), 1)
            if let hi = c.first(where: { $0 > tcc }) {
                return (k, i, c.last(where: { $0 <= tcc }) ?? (c.last! - 1), hi)
            }
            return (k, i, c.last!, c.first! + 1)
        }
        let inner = raw.filter { $0 > eps && $0 < 1 - eps }
        let tcc = min(max(tc, 0), 1)
        let t0 = ([0] + inner.filter { $0 <= tcc }).max()!
        let t1 = ([1] + inner.filter { $0 > tcc }).min()!
        return (k, i, t0, t1)
    }

    /// Trims the piece under `p` (Fusion's Taglia): a line up to the lines and arcs crossing it, a
    /// circle to an arc, a lone curve away entirely. Rectangles, polygons and slots become lines and
    /// arcs first. Returns false when nothing is under `p`.
    @discardableResult
    public mutating func trim(at p: Vec2, tolerance: Double) -> Bool {
        guard let (k, _) = nearestPrim(p, tolerance: tolerance) else { return false }
        if shapes[k].exploded() != nil {
            explode(shapes[k].id)
        }
        guard let t = trimTarget(p, tolerance: tolerance) else { return false }
        let shape = shapes[t.shape], prim = shape.prims[t.prim]
        let eps = 1e-7
        var parts: [SketchShape] = []
        func keep(_ kind: SketchShape.Kind) {
            parts.append(SketchShape(id: parts.isEmpty ? shape.id : UUID(), kind: kind, isConstruction: shape.isConstruction))
        }
        switch shape.kind {
        case let .polyline(pts, closed):
            let j = t.prim, n = pts.count
            let head = t.t0 > eps ? [prim.at(t.t0)] : [], tail = t.t1 < 1 - eps ? [prim.at(t.t1)] : []
            if closed {
                let around = (1...n).map { pts[(j + $0) % n] }   // p[j+1] … p[j]
                let open = tail + around + head
                if open.count >= 2 { keep(.polyline(open, closed: false)) }
            } else {
                let first = Array(pts[0...j]) + head, second = tail + Array(pts[(j + 1)...])
                if first.count >= 2 { keep(.polyline(first, closed: false)) }
                if second.count >= 2 { keep(.polyline(second, closed: false)) }
            }
        case let .circle(c, r):
            if t.t1 - t.t0 < 1 - eps {
                keep(.arc(center: c, radius: r, start: 2 * .pi * t.t1, end: 2 * .pi * (t.t0 + 1)))
            }
        case let .arc(c, r, a0, a1):
            let sw = SketchShape.sweep(a0, a1)
            if t.t0 > eps { keep(.arc(center: c, radius: r, start: a0, end: a0 + sw * t.t0)) }
            if t.t1 < 1 - eps { keep(.arc(center: c, radius: r, start: a0 + sw * t.t1, end: a1)) }
        default:
            return false
        }
        replaceShape(shape.id, with: parts)
        return true
    }

    // MARK: Extend

    /// Extends the open end nearest to `p` (of a line or an arc) up to the next curve it meets
    /// (Fusion's Estendi). Returns false when there is no free end there or nothing to reach.
    @discardableResult
    public mutating func extend(at p: Vec2, tolerance: Double) -> Bool {
        // Only pieces with a free end: the first or last segment of an open polyline, or an arc.
        guard let (k, i) = nearestPrim(p, tolerance: tolerance, where: { s, i in
            switch s.kind {
            case let .polyline(pts, closed): return !closed && (i == 0 || i == pts.count - 2)
            case .arc: return true
            default: return false
            }
        }) else { return false }
        let shape = shapes[k], prim = shape.prims[i]
        // Which end moves: the one nearer the click (a polyline's inner end never does).
        var atEnd = (p - prim.at(1)).length < (p - prim.at(0)).length
        if case let .polyline(pts, _) = shape.kind, pts.count > 2 { atEnd = i != 0 }
        var reach: Double?
        for (m, s) in shapes.enumerated() {
            for (j, other) in s.prims.enumerated() where !(m == k && j == i) {
                for t in SketchEdit.hits(prim, other, extendA: true) {
                    switch prim {
                    case .line:
                        if atEnd, t > 1 + 1e-7 { reach = min(reach ?? .infinity, t) }
                        if !atEnd, t < -1e-7 { reach = max(reach ?? -.infinity, t) }
                    case let .arc(_, _, _, sw):
                        // Angles past the end (or before the start), within the rest of the circle.
                        let past = atEnd ? t * sw - sw : 2 * .pi - t * sw
                        if past > 1e-7, past < 2 * .pi - sw - 1e-7 { reach = min(reach ?? .infinity, past) }
                    }
                }
            }
        }
        guard let reach else { return false }
        var next = shape
        switch shape.kind {
        case .polyline(var pts, let closed):
            let q = prim.at(reach)
            if atEnd { pts[pts.count - 1] = q } else { pts[0] = q }
            next.kind = .polyline(pts, closed: closed)
        case let .arc(c, r, a0, a1):
            next.kind = atEnd ? .arc(center: c, radius: r, start: a0, end: a1 + reach) : .arc(center: c, radius: r, start: a0 - reach, end: a1)
        default:
            return false
        }
        shapes[k] = next
        // Constraints the moved end no longer meets (its length, a coincidence) go.
        let byID = Dictionary(uniqueKeysWithValues: shapes.map { ($0.id, $0) })
        constraints.removeAll { c in
            c.kind.refs.contains { $0.shapeID == shape.id } && SketchSolver.residual(c.kind, byID).contains { abs($0) > 1e-6 }
        }
        return true
    }

    // MARK: Offset

    /// The shapes joined end to end with `id` (open lines and arcs), in order, each with whether it
    /// runs backwards along the chain. A closed shape is a chain of its own.
    func chain(from id: UUID) -> [(shape: SketchShape, reversed: Bool)] {
        guard let first = shapes.first(where: { $0.id == id }) else { return [] }
        func ends(_ s: SketchShape) -> (Vec2, Vec2)? {
            switch s.kind {
            case let .polyline(p, false): return p.count >= 2 ? (p[0], p[p.count - 1]) : nil
            case let .spline(p, false): return p.count >= 2 ? (p[0], p[p.count - 1]) : nil
            case .arc: return (s.point(1)!, s.point(2)!)
            default: return nil
            }
        }
        guard ends(first) != nil else { return [(first, false)] }
        let tol = 1e-6
        var used: Set<UUID> = [first.id]
        var chain: [(shape: SketchShape, reversed: Bool)] = [(first, false)]
        // Forward from the end, then backward from the start.
        for forward in [true, false] {
            while true {
                let tip: Vec2
                if forward { let (s, r) = chain.last!; let (a, b) = ends(s)!; tip = r ? a : b }
                else { let (s, r) = chain.first!; let (a, b) = ends(s)!; tip = r ? b : a }
                guard let (s, rev) = shapes.lazy.compactMap({ s -> (SketchShape, Bool)? in
                    guard !used.contains(s.id), let (a, b) = ends(s) else { return nil }
                    if (a - tip).length < tol { return (s, !forward) }
                    if (b - tip).length < tol { return (s, forward) }
                    return nil
                }).first else { break }
                used.insert(s.id)
                if forward { chain.append((s, rev)) } else { chain.insert((s, rev), at: 0) }
            }
        }
        return chain
    }

    /// Offsets the curve `id` — with the lines and arcs joined to it — by `distance` towards the
    /// side of `side` (Fusion's Offset). Closed shapes grow or shrink; corners between lines meet.
    /// Returns the new shapes' IDs.
    @discardableResult
    public mutating func offset(_ id: UUID, distance d: Double, toward side: Vec2) throws -> [UUID] {
        guard d.isFinite, d > 0 else { throw SketchEditError.invalid("distanza non valida") }
        let chain = chain(from: id)
        guard !chain.isEmpty else { throw SketchEditError.invalid("forma non trovata") }
        var made: [SketchShape] = []

        if chain.count == 1, chain[0].shape.isClosed {
            let s = chain[0].shape
            let inside = s.profile.map { SketchArrangement.inside(side, $0.points) } ?? false
            let δ = inside ? -d : d   // grow outwards
            var n = s
            n.id = UUID()
            switch s.kind {
            case let .circle(c, r):
                guard r + δ > 1e-9 else { throw SketchEditError.invalid("distanza più grande del raggio") }
                n.kind = .circle(center: c, radius: r + δ)
            case let .rectangle(c, w, h):
                let x0 = min(c.x, c.x + w) - δ, x1 = max(c.x, c.x + w) + δ, y0 = min(c.y, c.y + h) - δ, y1 = max(c.y, c.y + h) + δ
                guard x1 - x0 > 1e-9, y1 - y0 > 1e-9 else { throw SketchEditError.invalid("distanza più grande del rettangolo") }
                n.kind = .rectangle(corner: Vec2(x0, y0), width: x1 - x0, height: y1 - y0)
            case let .polygon(c, r, sides, rot, circ):
                let nn = Double(max(3, sides))
                let r2 = circ ? r + δ : r + δ / cos(.pi / nn)   // circumscribed: r is the apothem
                guard r2 > 1e-9 else { throw SketchEditError.invalid("distanza più grande del poligono") }
                n.kind = .polygon(center: c, radius: r2, sides: sides, rotation: rot, circumscribed: circ)
            case let .slot(a, b, w):
                guard w + 2 * δ > 1e-9 else { throw SketchEditError.invalid("distanza più grande dell'asola") }
                n.kind = .slot(start: a, end: b, width: w + 2 * δ)
            case let .polyline(p, _):
                // Counter-clockwise outline: its inside is on the left.
                let ccw = Profile2D.signedArea(p) > 0
                n.kind = .polyline(Self.offsetPolyline(p, closed: true, left: ccw ? -δ : δ), closed: true)
            case .spline:
                // A spline's offset follows its curve as a polyline.
                let p = s.outline
                let ccw = Profile2D.signedArea(p) > 0
                n.kind = .polyline(Self.offsetPolyline(p, closed: true, left: ccw ? -δ : δ), closed: true)
            default:
                throw SketchEditError.invalid("forma non gestita")
            }
            made = [n]
        } else {
            // Which side of the chain, walking it in order: left or right of the nearest piece.
            var best: (Int, Double)?
            for (i, link) in chain.enumerated() {
                for prim in link.shape.prims {
                    let dd = prim.distance(to: side)
                    if dd < (best?.1 ?? .infinity) { best = (i, dd) }
                }
            }
            guard let (bi, _) = best else { throw SketchEditError.invalid("forma non trovata") }
            func leftOfOwn(_ s: SketchShape, _ q: Vec2) -> Bool {
                let prims = s.prims
                guard let prim = prims.min(by: { $0.distance(to: q) < $1.distance(to: q) }) else { return true }
                switch prim {
                case let .line(a, b): return (b - a).cross(q - a) > 0
                case let .arc(c, r, _, _): return (q - c).length < r   // counter-clockwise: left is inside
                }
            }
            let link = chain[bi]
            let leftOfChain = leftOfOwn(link.shape, side) != link.reversed
            for (s, reversed) in chain {
                let δ = (leftOfChain != reversed) ? d : -d   // along the shape's own direction
                var n = s
                n.id = UUID()
                switch s.kind {
                case let .polyline(p, closed):
                    n.kind = .polyline(Self.offsetPolyline(p, closed: closed, left: δ), closed: closed)
                case let .spline(_, closed):
                    n.kind = .polyline(Self.offsetPolyline(s.outline, closed: closed, left: δ), closed: closed)
                case let .arc(c, r, a0, a1):
                    guard r - δ > 1e-9 else { throw SketchEditError.invalid("distanza più grande del raggio") }
                    n.kind = .arc(center: c, radius: r - δ, start: a0, end: a1)
                default:
                    throw SketchEditError.invalid("forma non gestita")
                }
                made.append(n)
            }
            // Corners between separate lines of the chain: the offset lines meet again.
            let closedLoop = chain.count > 2 && {
                let (s0, r0) = chain[0], (s1, r1) = chain[chain.count - 1]
                guard let a = s0.point(r0 ? s0.pointCount - 1 : 0), let b = s1.point(r1 ? 0 : s1.pointCount - 1) else { return false }
                if case .arc = s0.kind { return false }
                if case .arc = s1.kind { return false }
                return (a - b).length < 1e-6
            }()
            let pairs = Array(zip(0..<(made.count - 1), 1..<made.count)) + (closedLoop ? [(made.count - 1, 0)] : [])
            for (i, j) in pairs {
                guard case var .polyline(p, false) = made[i].kind, case var .polyline(q, false) = made[j].kind,
                      p.count >= 2, q.count >= 2 else { continue }
                let ri = chain[i].reversed, rj = chain[j].reversed
                // The end of i that meets the start of j (in chain order).
                let (ia, ib) = ri ? (1, 0) : (p.count - 2, p.count - 1)
                let (ja, jb) = rj ? (q.count - 1, q.count - 2) : (0, 1)
                guard (p[ib] - q[ja]).length > 1e-9, let meet = SketchEdit.meet(p[ia], p[ib], q[ja], q[jb]) else { continue }
                p[ib] = meet
                q[ja] = meet
                made[i].kind = .polyline(p, closed: false)
                made[j].kind = .polyline(q, closed: false)
            }
        }

        // The offset keeps the shape's own relations (horizontal, tangent, joined ends…).
        let map = Dictionary(uniqueKeysWithValues: zip(chain.map(\.shape.id), made.map(\.id)))
        let copied: [SketchConstraint] = constraints.compactMap { c in
            switch c.kind {
            case .coincident, .horizontal, .vertical, .parallel, .perpendicular, .tangent, .concentric:
                guard c.kind.refs.allSatisfy({ map[$0.shapeID] != nil }) else { return nil }
                return c.kind.mapRefs { ref in
                    guard let nid = map[ref.shapeID] else { return nil }
                    switch ref {
                    case let .point(_, i): return .point(nid, i)
                    case let .segment(_, i): return .segment(nid, i)
                    case let .circle(_, i): return .circle(nid, i)
                    }
                }.map { SketchConstraint($0) }
            default: return nil
            }
        }
        let byID = Dictionary(uniqueKeysWithValues: made.map { ($0.id, $0) })
        shapes += made
        constraints += copied.filter { !SketchSolver.residual($0.kind, byID).contains { abs($0) > 1e-6 } }
        return made.map(\.id)
    }

    /// A polyline moved sideways by `left` (negative: to the right of its direction); the corners
    /// are where the moved sides meet.
    public static func offsetPolyline(_ p: [Vec2], closed: Bool, left δ: Double) -> [Vec2] {
        let n = p.count
        let segs = closed ? n : n - 1
        guard segs >= 1 else { return p }
        func normal(_ i: Int) -> Vec2 {
            let d = p[(i + 1) % n] - p[i], l = max(d.length, 1e-12)
            return Vec2(-d.y / l, d.x / l)
        }
        let lines: [(Vec2, Vec2)] = (0..<segs).map { i in
            let o = normal(i) * δ
            return (p[i] + o, p[(i + 1) % n] + o)
        }
        return (0..<n).map { i -> Vec2 in
            let before = closed ? (i - 1 + segs) % segs : i - 1, after = i
            let hasBefore = closed || i > 0, hasAfter = closed || i < segs
            if hasBefore, hasAfter {
                let (a0, b0) = lines[before], (a1, b1) = lines[after]
                return SketchEdit.meet(a0, b0, a1, b1) ?? b0
            }
            return hasAfter ? lines[after].0 : lines[before].1
        }
    }

    // MARK: Mirror

    /// Mirrors the shapes about the line `axis` (Fusion's Specchio): copies tied to the originals
    /// by symmetric constraints, so they follow every later change. Returns the copies' IDs.
    @discardableResult
    public mutating func mirror(_ ids: [UUID], about axis: SketchRef) throws -> [UUID] {
        guard case let .segment(axisID, axisIndex) = axis, let (u, v) = shapes.first(where: { $0.id == axisID })?.segment(axisIndex),
              (v - u).length > 1e-9 else { throw SketchEditError.invalid("scegli una linea come asse") }
        let d = (v - u) * (1 / (v - u).length)
        let phi = atan2(d.y, d.x)
        func reflect(_ q: Vec2) -> Vec2 {
            let w = q - u
            let along = d * w.dot(d)
            return u + along * 2 - w
        }
        var copies: [SketchShape] = []
        var added: [SketchConstraint] = []
        for id in ids {
            guard let s = shapes.first(where: { $0.id == id }) else { continue }
            if s.id == axisID, s.segmentCount == 1 { continue }   // the axis itself
            var m = SketchShape(kind: s.kind, isConstruction: s.isConstruction)
            var pairs: [(Int, Int)] = []   // original point → copy point
            switch s.kind {
            case let .polyline(p, closed):
                m.kind = .polyline(p.map(reflect), closed: closed)
                pairs = p.indices.map { ($0, $0) }
            case .rectangle:
                m.kind = .polyline((0..<4).compactMap { s.point($0) }.map(reflect), closed: true)
                pairs = (0..<4).map { ($0, $0) }
            case let .polygon(_, _, n, _, _):
                m.kind = .polyline((1...max(3, n)).compactMap { s.point($0) }.map(reflect), closed: true)
                pairs = (1...max(3, n)).map { ($0, $0 - 1) }
            case let .circle(c, r):
                m.kind = .circle(center: reflect(c), radius: r)
                pairs = [(0, 0)]
                added.append(.init(.equal(.circle(s.id, 0), .circle(m.id, 0))))
            case let .arc(c, r, a0, a1):
                m.kind = .arc(center: reflect(c), radius: r, start: 2 * phi - a1, end: 2 * phi - a0)
                pairs = [(0, 0), (1, 2), (2, 1)]
            case let .slot(a, b, w):
                m.kind = .slot(start: reflect(a), end: reflect(b), width: w)
                pairs = [(0, 0), (1, 1)]
                added.append(.init(.equal(.circle(s.id, 0), .circle(m.id, 0))))
            case let .spline(p, closed):
                m.kind = .spline(points: p.map(reflect), closed: closed)
                pairs = p.indices.map { ($0, $0) }
            }
            added += pairs.map { .init(.symmetric(.point(s.id, $0.0), .point(m.id, $0.1), axis)) }
            copies.append(m)
        }
        guard !copies.isEmpty else { throw SketchEditError.invalid("niente da specchiare") }
        shapes += copies
        constraints += added
        return copies.map(\.id)
    }
}

extension Sketch {
    /// Tangencies the new shape was drawn with (Fusion's auto constraints): an arc leaving the end
    /// of a line along it, or a line leaving an arc's end along its tangent (within 3°).
    public func tangentAutoConstraints(for new: SketchShape) -> [SketchConstraint] {
        let limit = sin(3 * Double.pi / 180), eps = 1e-6
        var out: [SketchConstraint] = []
        func tangentAt(_ p: Vec2, circle c: (center: Vec2, radius: Double), segment s: (Vec2, Vec2)) -> Bool {
            let d = s.1 - s.0, r = p - c.center
            guard d.length > eps, r.length > eps else { return false }
            return abs(d.normalized.dot(r.normalized)) < limit
        }
        // Segments of a shape ending at p (the first or last one), with their index.
        func segments(of s: SketchShape, endingAt p: Vec2) -> [Int] {
            (0..<s.segmentCount).filter { k in
                guard let (a, b) = s.segment(k) else { return false }
                return (a - p).length < eps || (b - p).length < eps
            }
        }
        for other in shapes where other.id != new.id {
            if case .arc = new.kind, let c = new.circle(0) {
                for i in [1, 2] {
                    guard let p = new.point(i) else { continue }
                    for k in segments(of: other, endingAt: p) where tangentAt(p, circle: c, segment: other.segment(k)!) {
                        out.append(.init(.tangent(.segment(other.id, k), .circle(new.id, 0))))
                    }
                }
            }
            if case .arc = other.kind, let c = other.circle(0) {
                for i in [1, 2] {
                    guard let p = other.point(i) else { continue }
                    for k in segments(of: new, endingAt: p) where tangentAt(p, circle: c, segment: new.segment(k)!) {
                        out.append(.init(.tangent(.segment(new.id, k), .circle(other.id, 0))))
                    }
                }
            }
        }
        return out
    }
}
