import Foundation

// Sketch constraints and dimensions (piano ottobre, settimana 1).
//
// The solver works on the parameters of the shapes the sketch already has (polyline vertices,
// rectangle corner and size, circle centre and radius, polygon centre/radius/rotation, slot ends
// and width): constraints refer to points, segments and circles of those shapes. Drawing,
// profiles and the extrusions linked to shapes keep working unchanged.
//
// Solving: Newton steps of minimum norm (Δ = −Jᵀ(JJᵀ + λI)⁻¹ r), so whatever is not constrained
// moves as little as possible — dragging or editing a dimension leaves the rest of the sketch
// where it was. Degrees of freedom come from the null space of the Jacobian: a shape is fully
// constrained when none of its parameters can move.

/// A point, segment or circle of a sketch shape.
public enum SketchRef: Codable, Sendable, Hashable {
    /// Polyline vertex i; rectangle corner 0…3 (4 = centre); circle centre (0); polygon centre (0)
    /// and vertices (1…n); slot arc centres 0 (start) and 1 (end).
    case point(UUID, Int)
    /// Polyline side i (vertex i → i+1); rectangle side 0…3; polygon side i; slot straight side 0 or 1.
    case segment(UUID, Int)
    /// Circle (0); slot arcs 0 (start) and 1 (end).
    case circle(UUID, Int)

    public var shapeID: UUID {
        switch self { case let .point(id, _), let .segment(id, _), let .circle(id, _): id }
    }
}

public enum SketchConstraintKind: Codable, Sendable, Equatable {
    // Geometric constraints.
    case coincident(SketchRef, SketchRef)
    case horizontal(SketchRef)
    case vertical(SketchRef)
    case parallel(SketchRef, SketchRef)
    case perpendicular(SketchRef, SketchRef)
    /// Equal lengths (two segments) or radii (two circles).
    case equal(SketchRef, SketchRef)
    /// Segment–circle or circle–circle.
    case tangent(SketchRef, SketchRef)
    case concentric(SketchRef, SketchRef)
    case pointOnLine(SketchRef, SketchRef)
    case pointOnCircle(SketchRef, SketchRef)
    case midpoint(SketchRef, SketchRef)
    /// Two points mirrored about a line (the third reference).
    case symmetric(SketchRef, SketchRef, SketchRef)
    /// Point pinned where it is.
    case fix(SketchRef, Vec2)
    // Dimensions (driving values, mm or degrees).
    case distance(SketchRef, SketchRef, Double)
    case horizontalDistance(SketchRef, SketchRef, Double)
    case verticalDistance(SketchRef, SketchRef, Double)
    case length(SketchRef, Double)
    case radius(SketchRef, Double)
    case diameter(SketchRef, Double)
    /// Angle from the first line to the second, degrees.
    case angle(SketchRef, SketchRef, Double)

    public var refs: [SketchRef] {
        switch self {
        case let .coincident(a, b), let .parallel(a, b), let .perpendicular(a, b), let .equal(a, b), let .tangent(a, b),
             let .concentric(a, b), let .pointOnLine(a, b), let .pointOnCircle(a, b), let .midpoint(a, b),
             let .distance(a, b, _), let .horizontalDistance(a, b, _), let .verticalDistance(a, b, _), let .angle(a, b, _):
            [a, b]
        case let .horizontal(a), let .vertical(a), let .fix(a, _), let .length(a, _), let .radius(a, _), let .diameter(a, _):
            [a]
        case let .symmetric(a, b, l):
            [a, b, l]
        }
    }

    /// The same constraint on other references; nil when `f` drops one of them.
    public func mapRefs(_ f: (SketchRef) -> SketchRef?) -> SketchConstraintKind? {
        switch self {
        case let .coincident(a, b): guard let a = f(a), let b = f(b) else { return nil }; return .coincident(a, b)
        case let .parallel(a, b): guard let a = f(a), let b = f(b) else { return nil }; return .parallel(a, b)
        case let .perpendicular(a, b): guard let a = f(a), let b = f(b) else { return nil }; return .perpendicular(a, b)
        case let .equal(a, b): guard let a = f(a), let b = f(b) else { return nil }; return .equal(a, b)
        case let .tangent(a, b): guard let a = f(a), let b = f(b) else { return nil }; return .tangent(a, b)
        case let .concentric(a, b): guard let a = f(a), let b = f(b) else { return nil }; return .concentric(a, b)
        case let .pointOnLine(a, b): guard let a = f(a), let b = f(b) else { return nil }; return .pointOnLine(a, b)
        case let .pointOnCircle(a, b): guard let a = f(a), let b = f(b) else { return nil }; return .pointOnCircle(a, b)
        case let .midpoint(a, b): guard let a = f(a), let b = f(b) else { return nil }; return .midpoint(a, b)
        case let .symmetric(a, b, l): guard let a = f(a), let b = f(b), let l = f(l) else { return nil }; return .symmetric(a, b, l)
        case let .distance(a, b, v): guard let a = f(a), let b = f(b) else { return nil }; return .distance(a, b, v)
        case let .horizontalDistance(a, b, v): guard let a = f(a), let b = f(b) else { return nil }; return .horizontalDistance(a, b, v)
        case let .verticalDistance(a, b, v): guard let a = f(a), let b = f(b) else { return nil }; return .verticalDistance(a, b, v)
        case let .angle(a, b, v): guard let a = f(a), let b = f(b) else { return nil }; return .angle(a, b, v)
        case let .horizontal(a): return f(a).map { .horizontal($0) }
        case let .vertical(a): return f(a).map { .vertical($0) }
        case let .fix(a, v): return f(a).map { .fix($0, v) }
        case let .length(a, v): return f(a).map { .length($0, v) }
        case let .radius(a, v): return f(a).map { .radius($0, v) }
        case let .diameter(a, v): return f(a).map { .diameter($0, v) }
        }
    }

    /// The driving value of a dimension (nil for a geometric constraint).
    public var value: Double? {
        switch self {
        case let .distance(_, _, v), let .horizontalDistance(_, _, v), let .verticalDistance(_, _, v), let .length(_, v),
             let .radius(_, v), let .diameter(_, v), let .angle(_, _, v): v
        default: nil
        }
    }

    /// The same dimension with another value.
    public func with(value v: Double) -> SketchConstraintKind {
        switch self {
        case let .distance(a, b, _): .distance(a, b, v)
        case let .horizontalDistance(a, b, _): .horizontalDistance(a, b, v)
        case let .verticalDistance(a, b, _): .verticalDistance(a, b, v)
        case let .length(a, _): .length(a, v)
        case let .radius(a, _): .radius(a, v)
        case let .diameter(a, _): .diameter(a, v)
        case let .angle(a, b, _): .angle(a, b, v)
        default: self
        }
    }

    public var label: String {
        switch self {
        case .coincident: "Coincidente"
        case .horizontal: "Orizzontale"
        case .vertical: "Verticale"
        case .parallel: "Parallelo"
        case .perpendicular: "Perpendicolare"
        case .equal: "Uguale"
        case .tangent: "Tangente"
        case .concentric: "Concentrico"
        case .pointOnLine: "Punto su linea"
        case .pointOnCircle: "Punto su cerchio"
        case .midpoint: "Punto medio"
        case .symmetric: "Simmetrico"
        case .fix: "Fisso"
        case .distance: "Distanza"
        case .horizontalDistance: "Distanza orizzontale"
        case .verticalDistance: "Distanza verticale"
        case .length: "Lunghezza"
        case .radius: "Raggio"
        case .diameter: "Diametro"
        case .angle: "Angolo"
        }
    }
}

public struct SketchConstraint: Identifiable, Codable, Sendable, Equatable {
    public var id: UUID
    public var kind: SketchConstraintKind
    /// A user parameter name or an expression driving a dimension (e.g. "larghezza / 2").
    public var expression: String?

    public init(id: UUID = UUID(), _ kind: SketchConstraintKind, expression: String? = nil) {
        self.id = id; self.kind = kind; self.expression = expression
    }
}

// MARK: - Shape parameters

extension SketchShape {
    /// The numbers the solver may change.
    public var parameters: [Double] {
        switch kind {
        case let .polyline(p, _): p.flatMap { [$0.x, $0.y] }
        case let .rectangle(c, w, h): [c.x, c.y, w, h]
        case let .circle(c, r): [c.x, c.y, r]
        case let .polygon(c, r, _, rot, _): [c.x, c.y, r, rot]
        case let .slot(a, b, w): [a.x, a.y, b.x, b.y, w]
        case let .arc(c, r, a0, a1): [c.x, c.y, r, a0, a1]
        }
    }

    /// The same shape with new parameters (as many as `parameters`).
    public func with(parameters v: [Double]) -> SketchShape {
        var s = self
        switch kind {
        case let .polyline(_, closed):
            s.kind = .polyline(stride(from: 0, to: v.count - 1, by: 2).map { Vec2(v[$0], v[$0 + 1]) }, closed: closed)
        case .rectangle: s.kind = .rectangle(corner: Vec2(v[0], v[1]), width: v[2], height: v[3])
        case .circle: s.kind = .circle(center: Vec2(v[0], v[1]), radius: v[2])
        case let .polygon(_, _, n, _, circ): s.kind = .polygon(center: Vec2(v[0], v[1]), radius: v[2], sides: n, rotation: v[3], circumscribed: circ)
        case .slot: s.kind = .slot(start: Vec2(v[0], v[1]), end: Vec2(v[2], v[3]), width: v[4])
        case .arc: s.kind = .arc(center: Vec2(v[0], v[1]), radius: v[2], start: v[3], end: v[4])
        }
        return s
    }

    /// Named points (role index → position): what a constraint or dimension can grab.
    public func point(_ i: Int) -> Vec2? {
        switch kind {
        case let .polyline(p, _): return p.indices.contains(i) ? p[i] : nil
        case let .rectangle(c, w, h):
            return [Vec2(c.x, c.y), Vec2(c.x + w, c.y), Vec2(c.x + w, c.y + h), Vec2(c.x, c.y + h), Vec2(c.x + w / 2, c.y + h / 2)][safe: i]
        case let .circle(c, _): return i == 0 ? c : nil
        case let .polygon(c, r, n, rot, circ):
            if i == 0 { return c }
            guard (1...max(3, n)).contains(i) else { return nil }
            let vr = circ ? r / cos(.pi / Double(max(3, n))) : r
            let t = rot + Double(i - 1) / Double(max(3, n)) * 2 * .pi
            return Vec2(c.x + vr * cos(t), c.y + vr * sin(t))
        case let .slot(a, b, _): return i == 0 ? a : (i == 1 ? b : nil)
        case let .arc(c, r, a0, a1):
            switch i {
            case 0: return c
            case 1: return Vec2(c.x + r * cos(a0), c.y + r * sin(a0))
            case 2: return Vec2(c.x + r * cos(a1), c.y + r * sin(a1))
            default: return nil
            }
        }
    }

    public var pointCount: Int {
        switch kind {
        case let .polyline(p, _): p.count
        case .rectangle: 5
        case .circle: 1
        case let .polygon(_, _, n, _, _): max(3, n) + 1
        case .slot: 2
        case .arc: 3
        }
    }

    public func segment(_ i: Int) -> (Vec2, Vec2)? {
        switch kind {
        case let .polyline(p, closed):
            let count = closed ? p.count : p.count - 1
            guard i >= 0, i < count else { return nil }
            return (p[i], p[(i + 1) % p.count])
        case .rectangle:
            guard (0..<4).contains(i), let a = point(i), let b = point((i + 1) % 4) else { return nil }
            return (a, b)
        case let .polygon(_, _, n, _, _):
            let n = max(3, n)
            guard (0..<n).contains(i), let a = point(i + 1), let b = point((i + 1) % n + 1) else { return nil }
            return (a, b)
        case let .slot(a, b, w):
            guard i == 0 || i == 1 else { return nil }
            let d = Vec2(b.x - a.x, b.y - a.y), l = max((d.x * d.x + d.y * d.y).squareRoot(), 1e-12)
            let n = Vec2(-d.y / l * w / 2, d.x / l * w / 2)
            return i == 0 ? (Vec2(a.x - n.x, a.y - n.y), Vec2(b.x - n.x, b.y - n.y)) : (Vec2(b.x + n.x, b.y + n.y), Vec2(a.x + n.x, a.y + n.y))
        case .circle, .arc: return nil
        }
    }

    public var segmentCount: Int {
        switch kind {
        case let .polyline(p, closed): closed ? p.count : max(0, p.count - 1)
        case .rectangle: 4
        case let .polygon(_, _, n, _, _): max(3, n)
        case .slot: 2
        case .circle, .arc: 0
        }
    }

    public func circle(_ i: Int) -> (center: Vec2, radius: Double)? {
        switch kind {
        case let .circle(c, r): i == 0 ? (c, r) : nil
        case let .slot(a, b, w): i == 0 ? (a, w / 2) : (i == 1 ? (b, w / 2) : nil)
        case let .arc(c, r, _, _): i == 0 ? (c, r) : nil
        default: nil
        }
    }
}


// MARK: - Solver

public enum SketchSolver {
    public struct Result: Sendable {
        /// Shapes with the solved parameters (unchanged when the solve failed).
        public let shapes: [SketchShape]
        public let converged: Bool
        /// Remaining degrees of freedom of the whole sketch.
        public let freedom: Int
        /// Shapes none of whose parameters can still move.
        public let fullyConstrained: Set<UUID>
        /// Largest remaining residual (mm or mm-equivalent).
        public let error: Double
    }

    /// Solves `constraints` on `shapes`. `drag`: a point pulled towards a position (weak: it gives
    /// way to the constraints). Shapes not touched by any constraint are returned as they are.
    public static func solve(_ shapes: [SketchShape], _ constraints: [SketchConstraint],
                             drag: (SketchRef, Vec2)? = nil) -> Result {
        // Variables: the parameters of constrained (or dragged) shapes.
        var involved = Set(constraints.flatMap(\.kind.refs).map(\.shapeID))
        if let drag { involved.insert(drag.0.shapeID) }
        var offsets: [UUID: Int] = [:], x: [Double] = []
        for s in shapes where involved.contains(s.id) { offsets[s.id] = x.count; x += s.parameters }
        let index = Dictionary(uniqueKeysWithValues: shapes.enumerated().map { ($1.id, $0) })
        func shapesAt(_ x: [Double]) -> [UUID: SketchShape] {
            var out: [UUID: SketchShape] = [:]
            for (id, o) in offsets {
                let s = shapes[index[id]!]
                out[id] = s.with(parameters: Array(x[o..<(o + s.parameters.count)]))
            }
            return out
        }
        let live = constraints.filter { c in c.kind.refs.allSatisfy { index[$0.shapeID] != nil } }
        func residuals(_ x: [Double], dragWeight: Double) -> [Double] {
            let s = shapesAt(x)
            var r: [Double] = []
            for c in live { r += residual(c.kind, s) }
            if let (ref, target) = drag, dragWeight > 0, let p = pointOf(ref, s) {
                r += [(p.x - target.x) * dragWeight, (p.y - target.y) * dragWeight]
            }
            return r
        }
        guard !x.isEmpty else {
            return Result(shapes: shapes, converged: true, freedom: 0, fullyConstrained: [], error: 0)
        }
        // With a drag: the point goes exactly under the mouse when the constraints allow it,
        // otherwise as near as they let it; then the constraints are satisfied exactly.
        var current = x
        if drag != nil {
            let exact = newton(current, { residuals($0, dragWeight: 1) }, leastSquares: false)
            current = (residuals(exact, dragWeight: 1).map(abs).max() ?? 0) < 1e-7
                ? exact : newton(current, { residuals($0, dragWeight: 0.05) }, leastSquares: true)
        }
        current = newton(current, { residuals($0, dragWeight: 0) }, leastSquares: false)
        let r = residuals(current, dragWeight: 0)
        let error = r.map(abs).max() ?? 0
        let converged = error < 1e-7
        // Degrees of freedom from the null space of the constraint Jacobian.
        let J = jacobian(current) { residuals($0, dragWeight: 0) }
        let null = nullSpace(J, columns: current.count)
        var full = Set<UUID>()
        for (id, o) in offsets {
            let n = shapes[index[id]!].parameters.count
            if null.allSatisfy({ v in (o..<(o + n)).allSatisfy { abs(v[$0]) < 1e-6 } }) { full.insert(id) }
        }
        guard converged else {
            return Result(shapes: shapes, converged: false, freedom: null.count, fullyConstrained: full, error: error)
        }
        let solved = shapesAt(current)
        return Result(shapes: shapes.map { solved[$0.id] ?? $0 }, converged: true, freedom: null.count,
                      fullyConstrained: full, error: error)
    }

    // MARK: Residuals

    static func pointOf(_ ref: SketchRef, _ s: [UUID: SketchShape]) -> Vec2? {
        guard case let .point(id, i) = ref else { return nil }
        return s[id]?.point(i)
    }
    static func segmentOf(_ ref: SketchRef, _ s: [UUID: SketchShape]) -> (Vec2, Vec2)? {
        guard case let .segment(id, i) = ref else { return nil }
        return s[id]?.segment(i)
    }
    static func circleOf(_ ref: SketchRef, _ s: [UUID: SketchShape]) -> (center: Vec2, radius: Double)? {
        guard case let .circle(id, i) = ref else { return nil }
        return s[id]?.circle(i)
    }

    private static func len(_ v: Vec2) -> Double { (v.x * v.x + v.y * v.y).squareRoot() }

    /// Residuals of one constraint (zero when satisfied), in millimetres.
    static func residual(_ k: SketchConstraintKind, _ s: [UUID: SketchShape]) -> [Double] {
        switch k {
        case let .coincident(a, b):
            guard let p = pointOf(a, s), let q = pointOf(b, s) else { return [] }
            return [p.x - q.x, p.y - q.y]
        case let .horizontal(a):
            if let (p, q) = segmentOf(a, s) { return [q.y - p.y] }
            return []
        case let .vertical(a):
            if let (p, q) = segmentOf(a, s) { return [q.x - p.x] }
            return []
        case let .parallel(a, b), let .perpendicular(a, b):
            guard let (p1, q1) = segmentOf(a, s), let (p2, q2) = segmentOf(b, s) else { return [] }
            let d1 = q1 - p1, d2 = q2 - p2
            let l1 = max(len(d1), 1e-9), l2 = max(len(d2), 1e-9), scale = (l1 + l2) / 2
            if case .parallel = k { return [d1.cross(d2) / (l1 * l2) * scale] }
            return [(d1.x * d2.x + d1.y * d2.y) / (l1 * l2) * scale]
        case let .equal(a, b):
            if let (p1, q1) = segmentOf(a, s), let (p2, q2) = segmentOf(b, s) { return [len(q1 - p1) - len(q2 - p2)] }
            if let c1 = circleOf(a, s), let c2 = circleOf(b, s) { return [c1.radius - c2.radius] }
            return []
        case let .tangent(a, b):
            if let (p, q) = segmentOf(a, s), let c = circleOf(b, s) { return [lineDistance(c.center, p, q) - c.radius] }
            if let (p, q) = segmentOf(b, s), let c = circleOf(a, s) { return [lineDistance(c.center, p, q) - c.radius] }
            if let c1 = circleOf(a, s), let c2 = circleOf(b, s) {
                let d = len(c1.center - c2.center)
                // Outside each other or one inside the other, whichever is nearer.
                let outside = d - (c1.radius + c2.radius), inside = d - abs(c1.radius - c2.radius)
                return [abs(outside) < abs(inside) ? outside : inside]
            }
            return []
        case let .concentric(a, b):
            guard let c1 = circleOf(a, s) ?? pointOf(a, s).map({ ($0, 0) }), let c2 = circleOf(b, s) ?? pointOf(b, s).map({ ($0, 0) }) else { return [] }
            return [c1.center.x - c2.center.x, c1.center.y - c2.center.y]
        case let .pointOnLine(a, b):
            guard let p = pointOf(a, s), let (u, v) = segmentOf(b, s) else { return [] }
            let d = v - u
            return [d.cross(p - u) / max(len(d), 1e-9)]
        case let .pointOnCircle(a, b):
            guard let p = pointOf(a, s), let c = circleOf(b, s) else { return [] }
            return [len(p - c.center) - c.radius]
        case let .midpoint(a, b):
            guard let p = pointOf(a, s), let (u, v) = segmentOf(b, s) else { return [] }
            return [p.x - (u.x + v.x) / 2, p.y - (u.y + v.y) / 2]
        case let .symmetric(a, b, l):
            guard let p = pointOf(a, s), let q = pointOf(b, s), let (u, v) = segmentOf(l, s) else { return [] }
            let d = v - u, n = max(len(d), 1e-9), m = Vec2((p.x + q.x) / 2, (p.y + q.y) / 2)
            return [d.cross(m - u) / n, ((q.x - p.x) * d.x + (q.y - p.y) * d.y) / n]
        case let .fix(a, at):
            guard let p = pointOf(a, s) else { return [] }
            return [p.x - at.x, p.y - at.y]
        case let .distance(a, b, d):
            if let p = pointOf(a, s), let q = pointOf(b, s) { return [len(q - p) - d] }
            if let p = pointOf(a, s), let (u, v) = segmentOf(b, s) { return [abs((v - u).cross(p - u)) / max(len(v - u), 1e-9) - d] }
            if let (u1, v1) = segmentOf(a, s), let (u2, _) = segmentOf(b, s) {   // parallel lines
                return [abs((v1 - u1).cross(u2 - u1)) / max(len(v1 - u1), 1e-9) - d]
            }
            return []
        case let .horizontalDistance(a, b, d):
            guard let p = pointOf(a, s), let q = pointOf(b, s) else { return [] }
            return [abs(q.x - p.x) - d]
        case let .verticalDistance(a, b, d):
            guard let p = pointOf(a, s), let q = pointOf(b, s) else { return [] }
            return [abs(q.y - p.y) - d]
        case let .length(a, d):
            guard let (p, q) = segmentOf(a, s) else { return [] }
            return [len(q - p) - d]
        case let .radius(a, d):
            guard let c = circleOf(a, s) else { return [] }
            return [c.radius - d]
        case let .diameter(a, d):
            guard let c = circleOf(a, s) else { return [] }
            return [2 * c.radius - d]
        case let .angle(a, b, deg):
            guard let (p1, q1) = segmentOf(a, s), let (p2, q2) = segmentOf(b, s) else { return [] }
            let d1 = q1 - p1, d2 = q2 - p2
            var e = atan2(d1.cross(d2), d1.x * d2.x + d1.y * d2.y) - deg * .pi / 180
            while e > .pi { e -= 2 * .pi }
            while e < -.pi { e += 2 * .pi }
            return [e * max((len(d1) + len(d2)) / 2, 1)]
        }
    }

    private static func lineDistance(_ c: Vec2, _ p: Vec2, _ q: Vec2) -> Double {
        abs((q - p).cross(c - p)) / max(len(q - p), 1e-9)
    }

    // MARK: Numerics

    static func jacobian(_ x: [Double], _ f: ([Double]) -> [Double]) -> [[Double]] {
        let f0 = f(x)
        var J = [[Double]](repeating: [Double](repeating: 0, count: x.count), count: f0.count)
        var xp = x
        for j in x.indices {
            let h = 1e-6 * max(1, abs(x[j]))
            xp[j] = x[j] + h
            let fp = f(xp)
            xp[j] = x[j] - h
            let fm = f(xp)
            xp[j] = x[j]
            for i in f0.indices { J[i][j] = (fp[i] - fm[i]) / (2 * h) }
        }
        return J
    }

    /// Newton iterations with minimum-norm steps (least squares when the equations cannot all hold,
    /// e.g. the weak drag target), with step halving when the residual grows.
    static func newton(_ x0: [Double], _ f: ([Double]) -> [Double], leastSquares: Bool) -> [Double] {
        var x = x0
        var r = f(x)
        func norm(_ v: [Double]) -> Double { v.reduce(0) { $0 + $1 * $1 } }
        for _ in 0..<60 {
            if r.isEmpty || norm(r) < 1e-20 { break }
            let J = jacobian(x, f)
            guard let step = minimumNormStep(J, r) else { break }
            var t = 1.0, improved = false
            while t > 1e-4 {
                let trial = zip(x, step).map { $0 + t * $1 }
                let rt = f(trial)
                if norm(rt) < norm(r) { x = trial; r = rt; improved = true; break }
                t /= 2
            }
            if !improved { break }
            if !leastSquares, r.map(abs).max() ?? 0 < 1e-10 { break }
        }
        return x
    }

    /// Δ = −Jᵀ (J Jᵀ + λI)⁻¹ r.
    static func minimumNormStep(_ J: [[Double]], _ r: [Double]) -> [Double]? {
        let m = J.count, n = J.first?.count ?? 0
        guard m > 0, n > 0 else { return nil }
        var A = [[Double]](repeating: [Double](repeating: 0, count: m), count: m)
        for i in 0..<m {
            for k in i..<m {
                var s = 0.0
                for j in 0..<n { s += J[i][j] * J[k][j] }
                A[i][k] = s; A[k][i] = s
            }
        }
        let trace = (0..<m).reduce(0.0) { $0 + A[$1][$1] }
        let lambda = max(1e-12, 1e-10 * trace / Double(m))
        for i in 0..<m { A[i][i] += lambda }
        guard let y = solveLinear(A, r.map { -$0 }) else { return nil }
        return (0..<n).map { j in (0..<m).reduce(0.0) { $0 + J[$1][j] * y[$1] } }
    }

    static func solveLinear(_ A0: [[Double]], _ b0: [Double]) -> [Double]? {
        var A = A0, b = b0
        let n = b.count
        for c in 0..<n {
            guard let p = (c..<n).max(by: { abs(A[$0][c]) < abs(A[$1][c]) }), abs(A[p][c]) > 1e-300 else { return nil }
            A.swapAt(c, p); b.swapAt(c, p)
            for r in (c + 1)..<n where A[r][c] != 0 {
                let f = A[r][c] / A[c][c]
                for k in c..<n { A[r][k] -= f * A[c][k] }
                b[r] -= f * b[c]
            }
        }
        var x = [Double](repeating: 0, count: n)
        for r in stride(from: n - 1, through: 0, by: -1) {
            var s = b[r]
            for k in (r + 1)..<n { s -= A[r][k] * x[k] }
            x[r] = s / A[r][r]
        }
        return x
    }

    /// Basis of the null space of J (vectors of `columns` entries): the directions the sketch can
    /// still move in. Reduced row echelon form with a relative tolerance.
    static func nullSpace(_ J: [[Double]], columns n: Int) -> [[Double]] {
        var A = J
        let scale = max(1, A.flatMap { $0 }.map(abs).max() ?? 1)
        let tol = 1e-8 * scale
        var pivots: [Int] = []
        var row = 0
        for c in 0..<n where row < A.count {
            guard let p = (row..<A.count).max(by: { abs(A[$0][c]) < abs(A[$1][c]) }), abs(A[p][c]) > tol else { continue }
            A.swapAt(row, p)
            let v = A[row][c]
            for k in 0..<n { A[row][k] /= v }
            for r in A.indices where r != row && A[r][c] != 0 {
                let f = A[r][c]
                for k in 0..<n { A[r][k] -= f * A[row][k] }
            }
            pivots.append(c); row += 1
        }
        let free = (0..<n).filter { !pivots.contains($0) }
        return free.map { f in
            var v = [Double](repeating: 0, count: n)
            v[f] = 1
            for (r, c) in pivots.enumerated() { v[c] = -A[r][f] }
            return v
        }
    }
}

// MARK: - 2D fillet

public enum SketchEditError: Error, LocalizedError, Equatable {
    case invalid(String)
    public var errorDescription: String? { if case let .invalid(m) = self { m } else { nil } }
}

extension Sketch {
    /// Rounds the corner at vertex `i` of a polyline or rectangle with an arc of radius `r`
    /// (Fusion's sketch fillet): the corner becomes two tangent points joined by an arc, with
    /// coincident and tangent constraints and a radius dimension. Returns the arc's ID.
    @discardableResult
    public mutating func fillet(_ shapeID: UUID, vertex i: Int, radius r: Double) throws -> UUID {
        guard let k = shapes.firstIndex(where: { $0.id == shapeID }) else { throw SketchEditError.invalid("forma non trovata") }
        guard r.isFinite, r > 0 else { throw SketchEditError.invalid("raggio non valido") }
        var shape = shapes[k]
        if case .rectangle = shape.kind, (0..<4).contains(i) {
            // Same vertex and side numbering as the rectangle: its constraints stay valid, and its
            // sides keep being horizontal and vertical as the rectangle implied.
            shape.kind = .polyline((0..<4).compactMap { shape.point($0) }, closed: true)
            constraints += [.init(.horizontal(.segment(shapeID, 0))), .init(.vertical(.segment(shapeID, 1))),
                            .init(.horizontal(.segment(shapeID, 2))), .init(.vertical(.segment(shapeID, 3)))]
        }
        guard case let .polyline(p, closed) = shape.kind, p.indices.contains(i) else { throw SketchEditError.invalid("raccordo: scegli l'angolo di una linea o di un rettangolo") }
        let n = p.count
        guard closed || (i > 0 && i < n - 1) else { throw SketchEditError.invalid("raccordo: un estremo libero non è un angolo") }
        let prev = (i - 1 + n) % n, next = (i + 1) % n
        func len(_ v: Vec2) -> Double { (v.x * v.x + v.y * v.y).squareRoot() }
        let a = p[prev] - p[i], b = p[next] - p[i]
        let la = len(a), lb = len(b)
        guard la > 1e-9, lb > 1e-9 else { throw SketchEditError.invalid("raccordo: lati nulli") }
        let u1 = a * (1 / la), u2 = b * (1 / lb)
        let cosT = max(-1, min(1, u1.x * u2.x + u1.y * u2.y))
        let theta = acos(cosT)
        guard theta > 1e-3, theta < .pi - 1e-3 else { throw SketchEditError.invalid("raccordo: i due lati sono allineati") }
        let d = r / tan(theta / 2)
        guard d < la - 1e-6, d < lb - 1e-6 else {
            throw SketchEditError.invalid(String(format: "raggio troppo grande per questo angolo (massimo %.2f mm)", min(la, lb) * tan(theta / 2)))
        }
        let t1 = p[i] + u1 * d, t2 = p[i] + u2 * d
        let bis = u1 + u2, lbis = len(bis)
        let c = p[i] + bis * (1 / lbis) * (r / sin(theta / 2))
        let a1 = atan2(t1.y - c.y, t1.x - c.x), a2 = atan2(t2.y - c.y, t2.x - c.x)
        // The short way round: start/end so that the counter-clockwise sweep is under half a turn.
        let (start, end, t1IsStart) = SketchShape.sweep(a1, a2) <= .pi ? (a1, a2, true) : (a2, a1, false)
        let arc = SketchShape(kind: .arc(center: c, radius: r, start: start, end: end))
        let t1Point = t1IsStart ? 1 : 2, t2Point = t1IsStart ? 2 : 1

        // The polyline (or its two halves) now ends at the tangent points. Constraints move to the
        // new numbering; those on the corner itself go, and so do lengths of the two trimmed sides.
        let secondID = UUID()
        func remap(_ ref: SketchRef) -> SketchRef? {
            guard ref.shapeID == shapeID else { return ref }
            switch ref {
            case let .point(_, j):
                if j == i { return nil }
                if closed { return .point(shapeID, 1 + (j - next + n) % n) }
                return j < i ? ref : .point(secondID, j - i)
            case let .segment(_, j):
                if closed { return .segment(shapeID, j == i ? 0 : 1 + (j - next + n) % n) }
                return j < i ? ref : .segment(secondID, j - i)
            case .circle: return nil
            }
        }
        let trimmed: Set<Int> = [prev, i]
        constraints = constraints.compactMap { c in
            guard c.kind.refs.contains(where: { $0.shapeID == shapeID }) else { return c }
            switch c.kind {
            case let .length(.segment(_, j), _) where trimmed.contains(j): return nil
            case let .equal(a, b) where [a, b].contains(where: { if case let .segment(id, j) = $0 { id == shapeID && trimmed.contains(j) } else { false } }): return nil
            default: break
            }
            guard let kind = c.kind.mapRefs(remap) else { return nil }
            var moved = c
            moved.kind = kind
            return moved
        }
        var added: [SketchConstraint] = []
        if closed {
            let order = (0..<(n - 1)).map { p[(next + $0) % n] }   // p[i+1] … p[i-1]
            shape.kind = .polyline([t2] + order + [t1], closed: false)
            shapes[k] = shape
            let m = n + 1
            added += [.init(.coincident(.point(shapeID, m - 1), .point(arc.id, t1Point))), .init(.coincident(.point(shapeID, 0), .point(arc.id, t2Point))),
                      .init(.tangent(.segment(shapeID, m - 2), .circle(arc.id, 0))), .init(.tangent(.segment(shapeID, 0), .circle(arc.id, 0)))]
        } else {
            shape.kind = .polyline(Array(p[0..<i]) + [t1], closed: false)
            shapes[k] = shape
            let second = SketchShape(id: secondID, kind: .polyline([t2] + Array(p[(i + 1)...]), closed: false), isConstruction: shape.isConstruction)
            shapes.insert(second, at: k + 1)
            added += [.init(.coincident(.point(shapeID, i), .point(arc.id, t1Point))), .init(.coincident(.point(second.id, 0), .point(arc.id, t2Point))),
                      .init(.tangent(.segment(shapeID, i - 1), .circle(arc.id, 0))), .init(.tangent(.segment(second.id, 0), .circle(arc.id, 0)))]
        }
        shapes.insert(arc, at: k + 1)
        constraints += added + [.init(.radius(.circle(arc.id, 0), r))]
        return arc.id
    }
}
