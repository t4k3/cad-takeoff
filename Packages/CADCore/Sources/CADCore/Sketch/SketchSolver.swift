import Dispatch
import Foundation

// MARK: - Scalar arithmetic
//
// The residuals are written once, over a small scalar protocol, and evaluated twice: with plain
// `Double` to measure them and with `Dual` (value + gradient) to get the analytic Jacobian. No
// finite differences, so the derivatives are exact and the solver does not stumble on the noise
// near degenerate configurations.

protocol SketchScalar: Comparable, Sendable {
    static func from(_ value: Double) -> Self
    static func + (a: Self, b: Self) -> Self
    static func - (a: Self, b: Self) -> Self
    static func * (a: Self, b: Self) -> Self
    static func / (a: Self, b: Self) -> Self
    static prefix func - (a: Self) -> Self
    var asDouble: Double { get }
    func root() -> Self
    func sine() -> Self
    func cosine() -> Self
    static func angle(y: Self, x: Self) -> Self
    static func larger(_ a: Self, _ b: Self) -> Self
    static func magnitude(_ a: Self) -> Self
}

extension Double: SketchScalar {
    static func from(_ value: Double) -> Double { value }
    var asDouble: Double { self }
    func root() -> Double { sqrt(self) }
    func sine() -> Double { sin(self) }
    func cosine() -> Double { cos(self) }
    static func angle(y: Double, x: Double) -> Double { atan2(y, x) }
    static func larger(_ a: Double, _ b: Double) -> Double { max(a, b) }
    static func magnitude(_ a: Double) -> Double { abs(a) }
}

/// A value with its derivative: `d[j]` is the partial derivative with respect to variable `j`.
/// A constant has an empty gradient, so constants never need to know how many variables there are.
struct Dual: SketchScalar {
    var v: Double
    var d: [Double]

    init(_ v: Double) { self.v = v; d = [] }
    init(_ v: Double, d: [Double]) { self.v = v; self.d = d }
    init(_ v: Double, seed: Int, variables: Int) {
        self.v = v
        var g = [Double](repeating: 0, count: variables)
        g[seed] = 1
        d = g
    }

    var asDouble: Double { v }

    static func from(_ value: Double) -> Dual { Dual(value) }

    static func combine(_ a: Dual, _ b: Dual, _ ka: Double, _ kb: Double) -> Dual {
        let value = a.v * ka + b.v * kb
        if a.d.isEmpty && b.d.isEmpty { return Dual(value) }
        if b.d.isEmpty { return Dual(value, d: a.d.map { $0 * ka }) }
        if a.d.isEmpty { return Dual(value, d: b.d.map { $0 * kb }) }
        return Dual(value, d: zip(a.d, b.d).map { $0 * ka + $1 * kb })
    }

    static func + (a: Dual, b: Dual) -> Dual { combine(a, b, 1, 1) }
    static func - (a: Dual, b: Dual) -> Dual { combine(a, b, 1, -1) }
    static prefix func - (a: Dual) -> Dual { Dual(a.v, d: a.d.map { -$0 }) }

    static func * (a: Dual, b: Dual) -> Dual {
        let value = a.v * b.v
        if a.d.isEmpty && b.d.isEmpty { return Dual(value) }
        if b.d.isEmpty { return Dual(value, d: a.d.map { $0 * b.v }) }
        if a.d.isEmpty { return Dual(value, d: b.d.map { $0 * a.v }) }
        return Dual(value, d: zip(a.d, b.d).map { $0 * b.v + $1 * a.v })
    }

    static func / (a: Dual, b: Dual) -> Dual {
        let value = a.v / b.v
        if b.d.isEmpty { return Dual(value, d: a.d.map { $0 / b.v }) }
        let scale = -(a.v) / (b.v * b.v)
        if a.d.isEmpty { return Dual(value, d: b.d.map { $0 * scale }) }
        return Dual(value, d: zip(a.d, b.d).map { $0 / b.v + $1 * scale })
    }

    func root() -> Dual {
        let r = sqrt(v)
        return d.isEmpty ? Dual(r) : Dual(r, d: d.map { $0 / (2 * r) })
    }

    func sine() -> Dual { d.isEmpty ? Dual(sin(v)) : Dual(sin(v), d: d.map { $0 * cos(v) }) }
    func cosine() -> Dual { d.isEmpty ? Dual(cos(v)) : Dual(cos(v), d: d.map { -$0 * sin(v) }) }

    static func angle(y: Dual, x: Dual) -> Dual {
        let value = atan2(y.v, x.v)
        let r2 = x.v * x.v + y.v * y.v
        guard r2 > 0 else { return Dual(value) }
        var g: [Double] = []
        if !y.d.isEmpty { g = y.d.map { $0 * x.v / r2 } }
        if !x.d.isEmpty {
            let scaled = x.d.map { -$0 * y.v / r2 }
            g = g.isEmpty ? scaled : zip(g, scaled).map(+)
        }
        return Dual(value, d: g)
    }

    static func larger(_ a: Dual, _ b: Dual) -> Dual { a.v >= b.v ? a : b }
    static func magnitude(_ a: Dual) -> Dual { a.v >= 0 ? a : -a }

    static func < (a: Dual, b: Dual) -> Bool { a.v < b.v }
}

// MARK: - Generic 2D geometry

struct GVec2<S: SketchScalar> {
    var x: S
    var y: S

    init(_ x: S, _ y: S) { self.x = x; self.y = y }
    static func + (a: Self, b: Self) -> Self { Self(a.x + b.x, a.y + b.y) }
    static func - (a: Self, b: Self) -> Self { Self(a.x - b.x, a.y - b.y) }
    static func * (a: Self, k: S) -> Self { Self(a.x * k, a.y * k) }
    func dot(_ b: Self) -> S { x * b.x + y * b.y }
    func cross(_ b: Self) -> S { x * b.y - y * b.x }
    var length: S { (x * x + y * y).root() }
}

/// A point in the sketch plane's frame: x and y along the plane axes, z along the normal.
struct GVec3<S: SketchScalar> {
    var x: S
    var y: S
    var z: S

    init(_ x: S, _ y: S, _ z: S) { self.x = x; self.y = y; self.z = z }
    static func - (a: Self, b: Self) -> Self { Self(a.x - b.x, a.y - b.y, a.z - b.z) }
    func dot(_ b: Self) -> S { x * b.x + y * b.y + z * b.z }
    func cross(_ b: Self) -> Self { Self(y * b.z - z * b.y, z * b.x - x * b.z, x * b.y - y * b.x) }
    var length: S { (x * x + y * y + z * z).root() }
}

/// One sketch shape whose parameters may be plain numbers (value) or duals (value + derivatives).
/// `kind` only tells the structure (open/closed, polygon sides, circumscribed); the numbers are in `p`.
struct GShape<S: SketchScalar> {
    let kind: SketchShape.Kind
    let p: [S]

    private func f(_ k: Double) -> S { S.from(k) }

    func point(_ i: Int) -> GVec2<S>? {
        switch kind {
        case .polyline, .spline:
            guard i >= 0, 2 * i + 1 < p.count else { return nil }
            return GVec2(p[2 * i], p[2 * i + 1])
        case .rectangle:
            guard (0...4).contains(i) else { return nil }
            let c = GVec2(p[0], p[1]), w = p[2], h = p[3]
            let corners = [c, GVec2(c.x + w, c.y), GVec2(c.x + w, c.y + h), GVec2(c.x, c.y + h),
                           GVec2(c.x + w * f(0.5), c.y + h * f(0.5))]
            return corners[i]
        case .circle:
            return i == 0 ? GVec2(p[0], p[1]) : nil
        case let .polygon(_, _, n, _, circumscribed):
            let sides = max(3, n)
            if i == 0 { return GVec2(p[0], p[1]) }
            guard (1...sides).contains(i) else { return nil }
            let vr = circumscribed ? p[2] / f(cos(.pi / Double(sides))) : p[2]
            let t = p[3] + f(Double(i - 1) / Double(sides) * 2 * .pi)
            return GVec2(p[0] + vr * t.cosine(), p[1] + vr * t.sine())
        case .slot:
            return i == 0 ? GVec2(p[0], p[1]) : (i == 1 ? GVec2(p[2], p[3]) : nil)
        case .arc:
            switch i {
            case 0: return GVec2(p[0], p[1])
            case 1: return GVec2(p[0] + p[2] * p[3].cosine(), p[1] + p[2] * p[3].sine())
            case 2: return GVec2(p[0] + p[2] * p[4].cosine(), p[1] + p[2] * p[4].sine())
            default: return nil
            }
        case .bezier:
            guard (0...3).contains(i) else { return nil }
            return GVec2(p[2 * i], p[2 * i + 1])
        case .point3D, .line3D, .workplane:
            return nil
        }
    }

    /// A point of a cubic Bezier at curve parameter `t`.
    func bezierAt(_ t: S) -> GVec2<S>? {
        guard case .bezier = kind else { return nil }
        let u = S.from(1) - t
        let p0 = GVec2(p[0], p[1]), c1 = GVec2(p[2], p[3])
        let c2 = GVec2(p[4], p[5]), p3 = GVec2(p[6], p[7])
        return p0 * (u * u * u) + c1 * (S.from(3) * u * u * t)
            + c2 * (S.from(3) * u * t * t) + p3 * (t * t * t)
    }

    /// The (non-normalised) derivative of a cubic Bezier at curve parameter `t`.
    func bezierTangentAt(_ t: S) -> GVec2<S>? {
        guard case .bezier = kind else { return nil }
        let u = S.from(1) - t
        let p0 = GVec2(p[0], p[1]), c1 = GVec2(p[2], p[3])
        let c2 = GVec2(p[4], p[5]), p3 = GVec2(p[6], p[7])
        return (c1 - p0) * (S.from(3) * u * u) + (c2 - c1) * (S.from(6) * u * t)
            + (p3 - c2) * (S.from(3) * t * t)
    }

    /// The entity's points in the plane's frame: 3D entities keep their own z, 2D ones lie on it.
    func point3(_ i: Int) -> GVec3<S>? {
        switch kind {
        case .point3D:
            return i == 0 ? GVec3(p[0], p[1], p[2]) : nil
        case .line3D:
            if i == 0 { return GVec3(p[0], p[1], p[2]) }
            return i == 1 ? GVec3(p[3], p[4], p[5]) : nil
        case .workplane:
            guard (0...2).contains(i) else { return nil }
            let o = 3 * i
            return GVec3(p[o], p[o + 1], p[o + 2])
        default:
            guard let q = point(i) else { return nil }
            return GVec3(q.x, q.y, S.from(0))
        }
    }

    func segment3(_ i: Int) -> (GVec3<S>, GVec3<S>)? {
        guard case .line3D = kind, i == 0 else { return nil }
        return (GVec3(p[0], p[1], p[2]), GVec3(p[3], p[4], p[5]))
    }

    var is3D: Bool {
        switch kind {
        case .point3D, .line3D, .workplane: return true
        default: return false
        }
    }

    var pointCount: Int {
        switch kind {
        case let .polyline(p, _): p.count
        case .rectangle: 5
        case .circle: 1
        case let .polygon(_, _, n, _, _): max(3, n) + 1
        case .slot: 2
        case .arc: 3
        case let .spline(p, _): p.count
        case .bezier: 4
        case .point3D: 1
        case .line3D: 2
        case .workplane: 3
        }
    }

    var segmentCount: Int {
        switch kind {
        case let .polyline(p, closed): closed ? p.count : max(0, p.count - 1)
        case .rectangle: 4
        case let .polygon(_, _, n, _, _): max(3, n)
        case .slot: 2
        case .circle, .arc, .spline, .bezier, .point3D, .workplane: 0
        case .line3D: 1
        }
    }

    func segment(_ i: Int) -> (GVec2<S>, GVec2<S>)? {
        switch kind {
        case .polyline(_, let closed):
            let n = p.count / 2
            let count = closed ? n : max(0, n - 1)
            guard n > 0, i >= 0, i < count else { return nil }
            let j = (i + 1) % n
            let u = GVec2(p[2 * i], p[2 * i + 1])
            let v = GVec2(p[2 * j], p[2 * j + 1])
            return (u, v)
        case .rectangle:
            guard (0..<4).contains(i), let a = point(i), let b = point((i + 1) % 4) else { return nil }
            return (a, b)
        case let .polygon(_, _, n, _, _):
            let sides = max(3, n)
            guard (0..<sides).contains(i), let a = point(i + 1), let b = point((i + 1) % sides + 1) else { return nil }
            return (a, b)
        case .slot:
            guard i == 0 || i == 1 else { return nil }
            let a = GVec2(p[0], p[1]), b = GVec2(p[2], p[3]), w = p[4]
            let d = b - a
            let l = S.larger(d.length, f(1e-12))
            let n = GVec2(f(0) - d.y / l * w / f(2), d.x / l * w / f(2))
            return i == 0 ? (a - n, b - n) : (b + n, a + n)
        case .circle, .arc, .spline, .bezier, .point3D, .line3D, .workplane:
            return nil
        }
    }

    func circle(_ i: Int) -> (center: GVec2<S>, radius: S)? {
        switch kind {
        case .circle: return i == 0 ? (GVec2(p[0], p[1]), p[2]) : nil
        case .slot: return i == 0 ? (GVec2(p[0], p[1]), p[4] / f(2)) : (i == 1 ? (GVec2(p[2], p[3]), p[4] / f(2)) : nil)
        case .arc: return i == 0 ? (GVec2(p[0], p[1]), p[2]) : nil
        default: return nil
        }
    }
}

// MARK: - Solver

public enum SketchSolver {
    public struct Result: Sendable {
        /// Shapes with the solved parameters (unchanged when the solve failed).
        public let shapes: [SketchShape]
        /// The constraints with their auxiliary curve parameters (`t` of a point on a Bezier, for
        /// instance) updated by the solve; the others are returned as they came in.
        public let constraints: [SketchConstraint]
        public let converged: Bool
        /// Remaining degrees of freedom of the whole sketch.
        public let freedom: Int
        /// Shapes none of whose parameters can still move.
        public let fullyConstrained: Set<UUID>
        /// Largest remaining residual (mm or mm-equivalent).
        public let error: Double
        /// How many directions each shape can still move in (per-point when the shape has points).
        public let freedomPerShape: [UUID: Int]
        /// Constraints that add no equation of their own (over-constraining duplicates).
        public let redundant: [SketchConstraint.ID]
        /// Constraints that could not be satisfied (the ones left with a residual).
        public let conflicting: [SketchConstraint.ID]
        /// During a drag: the constraints on the dragged point that keep it from the mouse.
        public let blocking: [SketchConstraint.ID]
    }

    public struct Diagnosis: Sendable {
        public let converged: Bool
        public let freedom: Int
        public let freedomPerShape: [UUID: Int]
        public let redundant: [SketchConstraint.ID]
        public let conflicting: [SketchConstraint.ID]
    }

    public enum AddCheck: Sendable, Equatable {
        case ok
        /// The constraint repeats what the others already say (it would over-constrain).
        case redundant
        /// The constraint cannot hold together with the others.
        case infeasible
    }

    /// Solves `constraints` on `shapes`. `drag`: a point pulled towards a position (weak: it gives
    /// way to the constraints). Shapes not touched by any constraint are returned as they are.
    ///
    /// The sketch is split into independent clusters first (shapes joined by constraints), so an
    /// edit only re-solves the part it touches and each cluster gets its own DOF and diagnostics.
    /// `diagnosis: false` skips the DOF/conflict analysis (the null basis and the rank of every
    /// shape), which is the expensive part: the drag loop only needs the solved shapes.
    /// `isCancelled`: a background analysis can stop a long solve (returns a non-converged
    /// result with the shapes untouched, which the caller discards).
    public static func solve(_ shapes: [SketchShape], _ constraints: [SketchConstraint],
                             drag: (SketchRef, Vec2)? = nil, diagnosis: Bool = true,
                             isCancelled: @Sendable () -> Bool = { false }) -> Result {
        let byID = Dictionary(uniqueKeysWithValues: shapes.map { ($0.id, $0) })
        // A constraint only counts if every shape it names exists (the axes are always there).
        let live = constraints.filter { c in c.kind.refs.allSatisfy { $0.isFixedGeometry || byID[$0.shapeID] != nil } }
        let clusters = makeClusters(shapes: shapes, constraints: live, drag: drag)
        guard !clusters.isEmpty else {
            return Result(shapes: shapes, constraints: constraints, converged: true, freedom: 0,
                          fullyConstrained: [], error: 0, freedomPerShape: [:], redundant: [],
                          conflicting: [], blocking: [])
        }
        // Independent clusters have no variables or constraints in common, so they are solved
        // together (T146); results keep the cluster order, so the diagnostics are deterministic.
        guard let results = solveClusters(clusters, diagnosis: diagnosis, isCancelled: isCancelled) else {
            return cancelled(shapes, constraints)
        }
        var solved: [UUID: SketchShape] = [:]
        var updated = constraints
        var freedom = 0, error = 0.0, convergedAll = true
        var freedomPerShape: [UUID: Int] = [:]
        var redundant: [SketchConstraint.ID] = [], conflicting: [SketchConstraint.ID] = [], blocking: [SketchConstraint.ID] = []
        for r in results {
            freedom += r.freedom
            error = max(error, r.error)
            convergedAll = convergedAll && r.converged
            freedomPerShape.merge(r.freedomPerShape) { a, b in max(a, b) }
            redundant += r.redundant
            conflicting += r.conflicting
            blocking += r.blocking
            for c in r.constraints { if let i = updated.firstIndex(where: { $0.id == c.id }) { updated[i] = c } }
            if r.converged { for s in r.shapes { solved[s.id] = s } }
        }
        guard convergedAll else {
            return Result(shapes: shapes, constraints: constraints, converged: false, freedom: freedom,
                          fullyConstrained: [], error: error, freedomPerShape: freedomPerShape,
                          redundant: redundant, conflicting: conflicting, blocking: blocking)
        }
        let fully = diagnosis ? Set(freedomPerShape.filter { $0.value == 0 }.keys) : []
        return Result(shapes: shapes.map { solved[$0.id] ?? $0 }, constraints: updated, converged: true,
                      freedom: freedom, fullyConstrained: fully, error: error,
                      freedomPerShape: freedomPerShape, redundant: redundant, conflicting: conflicting,
                      blocking: blocking)
    }

    /// A solve stopped by its caller: shapes and constraints exactly as they came in.
    private static func cancelled(_ shapes: [SketchShape], _ constraints: [SketchConstraint]) -> Result {
        Result(shapes: shapes, constraints: constraints, converged: false, freedom: 0,
               fullyConstrained: [], error: 0, freedomPerShape: [:], redundant: [],
               conflicting: [], blocking: [])
    }

    /// Whether `candidate` can be added without over-constraining the sketch.
    public static func check(_ shapes: [SketchShape], _ constraints: [SketchConstraint],
                             adding candidate: SketchConstraint) -> AddCheck {
        let r = solve(shapes, constraints + [candidate])
        if r.redundant.contains(candidate.id) { return .redundant }
        if !r.converged { return .infeasible }
        return .ok
    }

    /// The state of the constraint problem without moving the shapes (diagnostics for the UI).
    public static func diagnose(_ shapes: [SketchShape], _ constraints: [SketchConstraint]) -> Diagnosis {
        let r = solve(shapes, constraints)
        return Diagnosis(converged: r.converged, freedom: r.freedom, freedomPerShape: r.freedomPerShape,
                         redundant: r.redundant, conflicting: r.conflicting)
    }

    /// Residuals of one constraint at the current shapes, in millimetres (signs taken from the
    /// current geometry, so a distance reads as a value, never as a flip).
    static func residual(_ k: SketchConstraintKind, _ shapes: [UUID: SketchShape]) -> [Double] {
        let g = doubleShapes(shapes)
        return rows(k, g, branch(k, g)).map(\.asDouble)
    }

    /// The auxiliary parameter a Bezier constraint carries (the curve parameter `t`), which the
    /// solver moves as one more variable; nil for every other constraint.
    static func auxiliaryValue(_ k: SketchConstraintKind) -> Double? {
        switch k {
        case let .pointOnBezier(_, _, t), let .bezierLineTangent(_, _, _, t),
             let .bezierLinePerpendicular(_, _, _, t):
            t
        default:
            nil
        }
    }

    /// The same constraint with its auxiliary parameter set (after a solve).
    static func withAuxiliary(_ k: SketchConstraintKind, _ t: Double) -> SketchConstraintKind {
        switch k {
        case let .pointOnBezier(a, b, _): .pointOnBezier(a, b, t: t)
        case let .bezierLineTangent(p, s, c, _): .bezierLineTangent(p, s, c, t: t)
        case let .bezierLinePerpendicular(p, s, c, _): .bezierLinePerpendicular(p, s, c, t: t)
        default: k
        }
    }

    // MARK: Clusters

    private struct Cluster: Sendable {
        var shapes: [SketchShape]
        var constraints: [SketchConstraint]
        var drag: (SketchRef, Vec2)?
    }

    private static func makeClusters(shapes: [SketchShape], constraints: [SketchConstraint],
                                     drag: (SketchRef, Vec2)?) -> [Cluster] {
        var parent: [UUID: UUID] = Dictionary(uniqueKeysWithValues: shapes.map { ($0.id, $0.id) })
        func find(_ id: UUID) -> UUID {
            var id = id
            while let p = parent[id], p != id { id = p; parent[id] = parent[p] ?? p }
            return id
        }
        func union(_ a: UUID, _ b: UUID) {
            let ra = find(a), rb = find(b)
            if ra != rb { parent[ra] = rb }
        }
        let live = constraints.filter { c in c.kind.refs.allSatisfy { $0.isFixedGeometry || parent[$0.shapeID] != nil } }
        for c in live {
            let ids = c.kind.refs.filter { !$0.isFixedGeometry }.map(\.shapeID)
            guard let first = ids.first else { continue }
            for id in ids.dropFirst() { union(first, id) }
        }
        if let drag, parent[drag.0.shapeID] != nil {
            _ = find(drag.0.shapeID)   // a dragged shape is a cluster even with no constraints
        }
        var roots: [UUID: Cluster] = [:]
        for s in shapes {
            let root = find(s.id)
            roots[root, default: Cluster(shapes: [], constraints: [], drag: nil)].shapes.append(s)
        }
        for c in live {
            guard let first = c.kind.refs.first(where: { !$0.isFixedGeometry }) else { continue }
            let root = find(first.shapeID)
            roots[root, default: Cluster(shapes: [], constraints: [], drag: nil)].constraints.append(c)
        }
        if let drag, parent[drag.0.shapeID] != nil {
            roots[find(drag.0.shapeID), default: Cluster(shapes: [], constraints: [], drag: nil)].drag = drag
        }
        return roots.sorted { $0.key.uuidString < $1.key.uuidString }.map(\.value)
            .filter { !$0.constraints.isEmpty || $0.drag != nil }
    }

    // MARK: Running the clusters

    /// The result of every cluster, in `makeClusters` order, or nil when the caller cancelled
    /// before they were all solved (the whole solve is then discarded).
    ///
    /// Small sketches stay on the calling thread: the cost of handing work to other threads is
    /// larger than the solve itself. With several clusters of some size the independent problems
    /// run at the same time — the sketch's edit path (`diagnosis: false`, one cluster of the
    /// dragged shape) keeps its sequential shape, while the full analysis of a sketch made of many
    /// loose shapes gets the cores.
    private static func solveClusters(_ clusters: [Cluster], diagnosis: Bool,
                                      isCancelled: @Sendable () -> Bool) -> [ClusterResult]? {
        let parameters = clusters.reduce(0) { n, c in n + c.shapes.reduce(0) { $0 + $1.parameters.count } }
        guard clusters.count > 1, parameters >= 32 else {
            var results: [ClusterResult] = []
            results.reserveCapacity(clusters.count)
            for cluster in clusters {
                if isCancelled() { return nil }
                results.append(solveCluster(cluster.shapes, cluster.constraints, drag: cluster.drag,
                                            diagnosis: diagnosis, isCancelled: isCancelled))
            }
            return results
        }
        let slots = ClusterSlots(count: clusters.count)
        DispatchQueue.concurrentPerform(iterations: clusters.count) { i in
            guard !isCancelled() else { return }
            let cluster = clusters[i]
            slots.store(solveCluster(cluster.shapes, cluster.constraints, drag: cluster.drag,
                                     diagnosis: diagnosis, isCancelled: isCancelled), at: i)
        }
        guard !isCancelled() else { return nil }
        return slots.results
    }

    /// One result slot per cluster, written once by its own iteration of `concurrentPerform`.
    /// The lock is held for a single assignment, so the threads never wait on each other's work.
    private final class ClusterSlots: @unchecked Sendable {
        private let lock = NSLock()
        private var slots: [ClusterResult?]

        init(count: Int) { slots = Array(repeating: nil, count: count) }

        func store(_ result: ClusterResult, at index: Int) {
            lock.lock()
            slots[index] = result
            lock.unlock()
        }

        /// All the results in cluster order; nil if an iteration was skipped by cancellation.
        var results: [ClusterResult]? {
            lock.lock()
            defer { lock.unlock() }
            let values = slots.compactMap { $0 }
            return values.count == slots.count ? values : nil
        }
    }

    // MARK: One cluster

    private struct ClusterResult: Sendable {
        var shapes: [SketchShape]
        /// The solved constraints whose auxiliary parameter changed (empty when they did not).
        var constraints: [SketchConstraint]
        var converged: Bool
        var freedom: Int
        var error: Double
        var freedomPerShape: [UUID: Int]
        var redundant: [SketchConstraint.ID]
        var conflicting: [SketchConstraint.ID]
        var blocking: [SketchConstraint.ID]
    }

    private struct Branch: Sendable {
        var sign: Double = 1
        var innerSign: Double = 1
        var inside = false
        var turn: Double = 0
    }

    /// A cluster whose solve was stopped by the caller: non-converged, so the shapes stay as they
    /// came in and `solve` discards the whole result.
    private static func cancelledCluster(_ shapes: [SketchShape]) -> ClusterResult {
        ClusterResult(shapes: shapes, constraints: [], converged: false, freedom: 0, error: 0,
                      freedomPerShape: [:], redundant: [], conflicting: [], blocking: [])
    }

    private static func solveCluster(_ shapes: [SketchShape], _ constraints: [SketchConstraint],
                                     drag: (SketchRef, Vec2)?, diagnosis: Bool,
                                     isCancelled: @Sendable () -> Bool) -> ClusterResult {
        var offsets: [UUID: Int] = [:]
        var x: [Double] = []
        for s in shapes { offsets[s.id] = x.count; x += s.parameters }
        // Reference (driven) dimensions are measured, not solved; invalid refs are already gone.
        let live = constraints.filter { !$0.isReference && !$0.kind.refs.isEmpty }
        // A Bezier constraint carries the curve parameter `t`, which the solver moves as one more
        // variable of its own (the point-on-curve rows are two, so the net is one constraint).
        var auxiliary: [SketchConstraint.ID: Int] = [:]
        for c in live {
            if let t = auxiliaryValue(c.kind) { auxiliary[c.id] = x.count; x.append(t) }
        }
        let variables = x.count
        guard variables > 0 else {
            return ClusterResult(shapes: shapes, constraints: [], converged: true, freedom: 0, error: 0,
                                 freedomPerShape: [:], redundant: [], conflicting: [], blocking: [])
        }
        let byID = Dictionary(uniqueKeysWithValues: shapes.map { ($0.id, $0) })
        let initial = doubleShapes(byID)
        var branches: [SketchConstraint.ID: Branch] = [:]
        for c in live { branches[c.id] = branch(c.kind, initial) }
        func branchOf(_ c: SketchConstraint) -> Branch { branches[c.id] ?? Branch() }
        // The shapes each constraint really touches: its rows are differentiated with as many
        // variables as those shapes have (2 to 8 in practice), not with all the sketch's variables.
        let touched: [[UUID]] = live.map { c in
            var seen = Set<UUID>(), ids: [UUID] = []
            for r in c.kind.refs where !r.isFixedGeometry && seen.insert(r.shapeID).inserted {
                ids.append(r.shapeID)
            }
            return ids
        }

        func shapesAt(_ x: [Double]) -> [UUID: GShape<Double>] {
            var out: [UUID: GShape<Double>] = [:]
            for s in shapes {
                guard let o = offsets[s.id] else { continue }
                out[s.id] = GShape(kind: s.kind, p: Array(x[o..<(o + s.parameters.count)]))
            }
            return out
        }

        /// Constraint rows only (used for convergence and diagnostics).
        func constraintRows(_ x: [Double]) -> (values: [Double], owners: [SketchConstraint.ID]) {
            let g = shapesAt(x)
            var values: [Double] = [], owners: [SketchConstraint.ID] = []
            for c in live {
                let r = rows(c.kind, g, branchOf(c), auxiliary: auxiliary[c.id].map { x[$0] }).map(\.asDouble)
                values += r
                owners += Array(repeating: c.id, count: r.count)
            }
            return (values, owners)
        }

        /// All rows, plus the drag target (weight `w`, 0 = no drag).
        func allRows(_ x: [Double], withDrag w: Double) -> (values: [Double], owners: [SketchConstraint.ID]) {
            var out = constraintRows(x)
            if let (ref, target) = drag, w > 0, let p = pointOf(ref, shapesAt(x)) {
                out.values += [(p.x.asDouble - target.x) * w, (p.y.asDouble - target.y) * w]
                out.owners += [UUID(), UUID()]   // the drag is not a constraint: no owner to report
            }
            return out
        }

        /// One residual's gradient (as long as the constraint's shapes' parameters) scattered into
        /// a Jacobian row of all the cluster's variables. The auxiliary curve parameter, when there
        /// is one, sits past that prefix and is written separately.
        func scatter(_ d: [Double], _ global: [Int], into row: inout [Double]) {
            for (i, g) in d.enumerated() where i < global.count { row[global[i]] = g }
        }

        func jacobian(_ x: [Double], withDrag w: Double) -> [[Double]] {
            var J: [[Double]] = []
            for (i, c) in live.enumerated() {
                var global: [Int] = []
                var duals: [UUID: GShape<Dual>] = [:]
                // Every dual of this constraint needs the same gradient length: its shapes' total,
                // plus the auxiliary curve parameter when the constraint has one.
                let span = touched[i].reduce(0) { $0 + (byID[$1]?.parameters.count ?? 0) }
                let auxIndex = auxiliary[c.id]
                let gradient = span + (auxIndex == nil ? 0 : 1)
                for id in touched[i] {
                    guard let s = byID[id], let o = offsets[id] else { continue }
                    let n = s.parameters.count
                    let first = global.count
                    global += Array(o..<(o + n))
                    duals[id] = GShape(kind: s.kind,
                                       p: (0..<n).map { j in Dual(x[o + j], seed: first + j, variables: gradient) })
                }
                let auxDual = auxIndex.map { Dual(x[$0], seed: span, variables: gradient) }
                for r in rows(c.kind, duals, branchOf(c), auxiliary: auxDual) {
                    var row = [Double](repeating: 0, count: variables)
                    scatter(r.d, global, into: &row)
                    if let ai = auxIndex, r.d.count > span { row[ai] = r.d[span] }
                    J.append(row)
                }
            }
            if let (ref, _) = drag, w > 0, !ref.isFixedGeometry,
               let s = byID[ref.shapeID], let o = offsets[ref.shapeID] {
                let n = s.parameters.count
                let global = Array(o..<(o + n))
                let duals = [ref.shapeID: GShape(kind: s.kind,
                                                p: (0..<n).map { j in Dual(x[o + j], seed: j, variables: n) })]
                if let p = pointOf(ref, duals) {
                    var rx = [Double](repeating: 0, count: variables)
                    var ry = [Double](repeating: 0, count: variables)
                    for (j, g) in p.x.d.enumerated() { rx[global[j]] = g * w }
                    for (j, g) in p.y.d.enumerated() { ry[global[j]] = g * w }
                    J.append(rx)
                    J.append(ry)
                }
            }
            return J
        }

        func norm(_ v: [Double]) -> Double { v.reduce(0) { $0 + $1 * $1 } }
        func maxAbs(_ v: [Double]) -> Double { v.map(abs).max() ?? 0 }

        /// Newton with rank-truncated minimum-norm steps and step-halving. nil = stopped: the
        /// caller (a background analysis) no longer needs this result.
        func newton(from start: [Double], dragWeight: Double) -> [Double]? {
            var x = start
            var r = allRows(x, withDrag: dragWeight).values
            for _ in 0..<80 {
                if isCancelled() { return nil }
                if r.isEmpty || maxAbs(r) < 1e-9 { break }
                let J = jacobian(x, withDrag: dragWeight)
                guard let step = minimumNormSolve(J, r.map { -$0 }) else { break }
                var t = 1.0, improved = false
                while t > 1e-4 {
                    let trial = zip(x, step).map { $0 + t * $1 }
                    let rt = allRows(trial, withDrag: dragWeight).values
                    if norm(rt) < norm(r) { x = trial; r = rt; improved = true; break }
                    t /= 2
                }
                if !improved { break }
                if maxAbs(r) < 1e-10 { break }
            }
            return x
        }

        var current = x
        var reachedDrag = true
        if let _ = drag {
            // The point goes under the mouse when the constraints allow it, otherwise as near as
            // they let it: then the constraints alone are satisfied exactly again.
            guard let exact = newton(from: current, dragWeight: 1) else { return cancelledCluster(shapes) }
            let constraintsOnly = constraintRows(exact).values
            if maxAbs(constraintsOnly) < 1e-7 {
                current = exact
            } else {
                reachedDrag = false
                guard let foldedInput = newton(from: current, dragWeight: 0.05),
                      let folded = newton(from: foldedInput, dragWeight: 0) else { return cancelledCluster(shapes) }
                current = folded
            }
        } else {
            guard let solved = newton(from: current, dragWeight: 0) else { return cancelledCluster(shapes) }
            current = solved
        }

        let final = constraintRows(current)
        let error = maxAbs(final.values)
        let converged = error < 1e-7
        // Diagnostics on the constraint Jacobian only (the drag is not part of the sketch). They
        // are what the panel shows, not what the drag needs, so they can be skipped.
        var freedom = 0
        var freedomPerShape: [UUID: Int] = [:]
        var redundant: [SketchConstraint.ID] = []
        var conflicting: [SketchConstraint.ID] = []
        if diagnosis {
            if isCancelled() { return cancelledCluster(shapes) }
            let jac = jacobian(current, withDrag: 0).prefix(final.values.count).map { $0 }
            let null = nullBasis(jac, variables)
            freedom = null.count
            for (id, o) in offsets {
                guard let s = byID[id] else { continue }
                let n = s.parameters.count
                let slices = null.map { Array($0[o..<(o + n)]) }
                freedomPerShape[id] = rank(of: slices, tolerance: 1e-6)
            }
            var worst: [SketchConstraint.ID: Double] = [:]
            for (value, owner) in zip(final.values, final.owners) {
                worst[owner] = max(worst[owner] ?? 0, abs(value))
            }
            // A dependent row that is still unsatisfied is a conflict, not a duplicate.
            redundant = redundantConstraints(jac, owners: final.owners).filter { (worst[$0] ?? 0) <= 1e-6 }
            conflicting = worst.filter { $0.value > 1e-6 }.keys.sorted { $0.uuidString < $1.uuidString }
        }
        var blocking: [SketchConstraint.ID] = []
        if let (ref, _) = drag, !reachedDrag {
            blocking = live.filter { c in c.kind.refs.contains { $0.shapeID == ref.shapeID } }.map(\.id)
        }
        guard converged else {
            return ClusterResult(shapes: shapes, constraints: [], converged: false, freedom: freedom,
                                 error: error, freedomPerShape: freedomPerShape, redundant: redundant,
                                 conflicting: conflicting, blocking: blocking)
        }
        let solved = shapes.map { s in
            guard let o = offsets[s.id] else { return s }
            let n = s.parameters.count
            return s.with(parameters: Array(current[o..<(o + n)]))
        }
        var solvedConstraints: [SketchConstraint] = []
        for c in live {
            guard let ai = auxiliary[c.id] else { continue }
            var moved = c
            moved.kind = withAuxiliary(c.kind, current[ai])
            solvedConstraints.append(moved)
        }
        return ClusterResult(shapes: solved, constraints: solvedConstraints, converged: true, freedom: freedom,
                             error: error, freedomPerShape: freedomPerShape, redundant: redundant,
                             conflicting: conflicting, blocking: blocking)
    }

    // MARK: Shape conversion

    private static func doubleShapes(_ shapes: [UUID: SketchShape]) -> [UUID: GShape<Double>] {
        var out: [UUID: GShape<Double>] = [:]
        for (id, s) in shapes { out[id] = GShape(kind: s.kind, p: s.parameters) }
        return out
    }

    // MARK: References

    private static func pointOf<S: SketchScalar>(_ r: SketchRef, _ s: [UUID: GShape<S>]) -> GVec2<S>? {
        switch r {
        case let .point(id, i): return s[id]?.point(i)
        case .origin: return GVec2(S.from(0), S.from(0))
        case .segment, .circle, .axisX, .axisY: return nil
        }
    }
    private static func segmentOf<S: SketchScalar>(_ r: SketchRef, _ s: [UUID: GShape<S>]) -> (GVec2<S>, GVec2<S>)? {
        switch r {
        case let .segment(id, i): return s[id]?.segment(i)
        case .axisX: return (GVec2(S.from(0), S.from(0)), GVec2(S.from(1), S.from(0)))
        case .axisY: return (GVec2(S.from(0), S.from(0)), GVec2(S.from(0), S.from(1)))
        case .point, .circle, .origin: return nil
        }
    }

    /// A point in the plane's frame. 2D points lie on the plane (z constant 0); the origin is fixed.
    private static func point3Of<S: SketchScalar>(_ r: SketchRef, _ s: [UUID: GShape<S>]) -> GVec3<S>? {
        switch r {
        case let .point(id, i): return s[id]?.point3(i)
        case .origin: return GVec3(S.from(0), S.from(0), S.from(0))
        case .segment, .circle, .axisX, .axisY: return nil
        }
    }
    /// The segment of a 3D line (2D segments keep their own two-dimensional rows).
    private static func segment3Of<S: SketchScalar>(_ r: SketchRef, _ s: [UUID: GShape<S>]) -> (GVec3<S>, GVec3<S>)? {
        guard case let .segment(id, i) = r else { return nil }
        return s[id]?.segment3(i)
    }
    /// Whether the reference belongs to an entity that carries a third coordinate.
    private static func is3DRef<S: SketchScalar>(_ r: SketchRef, _ s: [UUID: GShape<S>]) -> Bool {
        s[r.shapeID]?.is3D ?? false
    }
    private static func circleOf<S: SketchScalar>(_ r: SketchRef, _ s: [UUID: GShape<S>]) -> (center: GVec2<S>, radius: S)? {
        switch r {
        case let .circle(id, i): return s[id]?.circle(i)
        case .origin, .axisX, .axisY, .point, .segment: return nil
        }
    }
    /// An arc's start or end point (1 or 2) with the circle it lies on: the `SketchRef.point` form
    /// of a fillet's tangency.
    private static func arcPointOf<S: SketchScalar>(_ r: SketchRef, _ s: [UUID: GShape<S>])
        -> (center: GVec2<S>, radius: S, point: GVec2<S>)? {
        guard case let .point(id, i) = r, i == 1 || i == 2, let shape = s[id], case .arc = shape.kind,
              let circle = shape.circle(0), let p = shape.point(i) else { return nil }
        return (circle.center, circle.radius, p)
    }
    /// The Bezier curve a constraint refers to. A curve is referenced as `.circle(id, 0)` (the
    /// shape-kind enum stays the solver's own business), which every other rule ignores.
    private static func bezierOf<S: SketchScalar>(_ r: SketchRef, _ s: [UUID: GShape<S>]) -> GShape<S>? {
        guard case let .circle(id, 0) = r, let shape = s[id], case .bezier = shape.kind else { return nil }
        return shape
    }

    // MARK: Branch selection (signed distances and tangency do not flip mid-solve)

    private static func signedCross<S: SketchScalar>(_ p: GVec2<S>, _ u: GVec2<S>, _ v: GVec2<S>) -> S {
        (v - u).cross(p - u)
    }

    private static func branch(_ k: SketchConstraintKind, _ s: [UUID: GShape<Double>]) -> Branch {
        var b = Branch()
        func sign(_ value: Double) -> Double { value < 0 ? -1 : 1 }
        switch k {
        case let .horizontalDistance(a, c, _):
            if let p = pointOf(a, s), let q = pointOf(c, s) { b.sign = sign(q.x.asDouble - p.x.asDouble) }
            else if let p = point3Of(a, s), let q = point3Of(c, s) { b.sign = sign(q.x.asDouble - p.x.asDouble) }
        case let .verticalDistance(a, c, _):
            if let p = pointOf(a, s), let q = pointOf(c, s) { b.sign = sign(q.y.asDouble - p.y.asDouble) }
            else if let p = point3Of(a, s), let q = point3Of(c, s) { b.sign = sign(q.y.asDouble - p.y.asDouble) }
        case let .distance(a, c, _), let .offset(a, c, _):
            if let p = pointOf(a, s), let (u, v) = segmentOf(c, s) {
                b.sign = sign(signedCross(p, u, v).asDouble)
            } else if let (u1, v1) = segmentOf(a, s), let (u2, _) = segmentOf(c, s) {
                b.sign = sign(signedCross(u2, u1, v1).asDouble)
            }
        case let .tangent(a, c):
            if let (u, v) = segmentOf(a, s), let circle = circleOf(c, s) {
                b.sign = sign(signedCross(circle.center, u, v).asDouble)
            } else if let circle = circleOf(a, s), let (u, v) = segmentOf(c, s) {
                b.sign = sign(signedCross(circle.center, u, v).asDouble)
            } else if let c1 = circleOf(a, s), let c2 = circleOf(c, s) {
                let d = length(c2.center - c1.center)
                let outside = abs(d - (c1.radius.asDouble + c2.radius.asDouble))
                let inside = abs(d - abs(c1.radius.asDouble - c2.radius.asDouble))
                b.inside = inside < outside
                b.innerSign = c1.radius.asDouble >= c2.radius.asDouble ? 1 : -1
            }
        case let .angle(a, c, deg):
            if let (p1, q1) = segmentOf(a, s), let (p2, q2) = segmentOf(c, s) {
                let d1 = q1 - p1, d2 = q2 - p2
                let current = atan2(d1.cross(d2).asDouble, d1.dot(d2).asDouble)
                let target = deg * .pi / 180
                // The nearest full turn: 179° does not flip to −179° (or to 181°).
                b.turn = ((current - target) / (2 * .pi)).rounded() * 2 * .pi
            }
        default:
            break
        }
        return b
    }

    private static func length<S: SketchScalar>(_ v: GVec2<S>) -> Double { v.length.asDouble }

    // MARK: Residuals

    private static func rows<S: SketchScalar>(_ k: SketchConstraintKind, _ s: [UUID: GShape<S>],
                                              _ branch: Branch, auxiliary: S? = nil) -> [S] {
        let eps = S.from(1e-9)
        let sign = S.from(branch.sign)
        switch k {
        case let .coincident(a, b):
            // Off-plane entities carry a third coordinate: the join holds it too.
            if is3DRef(a, s) || is3DRef(b, s) {
                guard let p = point3Of(a, s), let q = point3Of(b, s) else { return [] }
                return [p.x - q.x, p.y - q.y, p.z - q.z]
            }
            guard let p = pointOf(a, s), let q = pointOf(b, s) else { return [] }
            return [p.x - q.x, p.y - q.y]
        case let .horizontal(a):
            guard let (p, q) = segmentOf(a, s) else { return [] }
            return [q.y - p.y]
        case let .vertical(a):
            guard let (p, q) = segmentOf(a, s) else { return [] }
            return [q.x - p.x]
        case let .parallel(a, b), let .smooth(a, b):
            guard let (p1, q1) = segmentOf(a, s), let (p2, q2) = segmentOf(b, s) else { return [] }
            let d1 = q1 - p1, d2 = q2 - p2
            let l1 = S.larger(d1.length, eps), l2 = S.larger(d2.length, eps)
            let scale = (l1 + l2) / S.from(2)
            return [d1.cross(d2) / (l1 * l2) * scale]
        case let .perpendicular(a, b):
            guard let (p1, q1) = segmentOf(a, s), let (p2, q2) = segmentOf(b, s) else { return [] }
            let d1 = q1 - p1, d2 = q2 - p2
            let l1 = S.larger(d1.length, eps), l2 = S.larger(d2.length, eps)
            let scale = (l1 + l2) / S.from(2)
            return [d1.dot(d2) / (l1 * l2) * scale]
        case let .colinear(a, b):
            guard let (u, v) = segmentOf(a, s), let (p, q) = segmentOf(b, s) else { return [] }
            let d = v - u, n = S.larger(d.length, eps)
            return [d.cross(p - u) / n, d.cross(q - u) / n]
        case let .equal(a, b):
            if let (p1, q1) = segmentOf(a, s), let (p2, q2) = segmentOf(b, s) {
                return [(q1 - p1).length - (q2 - p2).length]
            }
            if let c1 = circleOf(a, s), let c2 = circleOf(b, s) { return [c1.radius - c2.radius] }
            return []
        case let .tangent(a, b):
            if let (p, q) = segmentOf(a, s), let c = circleOf(b, s) {
                let d = q - p
                return [sign * d.cross(c.center - p) / S.larger(d.length, eps) - c.radius]
            }
            if let (p, q) = segmentOf(b, s), let c = circleOf(a, s) {
                let d = q - p
                return [sign * d.cross(c.center - p) / S.larger(d.length, eps) - c.radius]
            }
            // Tangency at an arc's end (a fillet): the side is perpendicular to the radius there.
            // Written this way the row does not vanish at the touch point, so the solver's rank —
            // and the degrees of freedom it reports — stay right instead of counting a freedom
            // that the tangency actually removes.
            if let (p, q) = segmentOf(a, s), let arc = arcPointOf(b, s) {
                let d = q - p, r = arc.point - arc.center
                return [d.dot(r) / S.larger(d.length * r.length, eps)]
            }
            if let (p, q) = segmentOf(b, s), let arc = arcPointOf(a, s) {
                let d = q - p, r = arc.point - arc.center
                return [d.dot(r) / S.larger(d.length * r.length, eps)]
            }
            if let c1 = circleOf(a, s), let c2 = circleOf(b, s) {
                let d = (c2.center - c1.center).length
                if branch.inside {
                    let s2 = S.from(branch.innerSign)
                    return [d - s2 * (c1.radius - c2.radius)]
                }
                return [d - (c1.radius + c2.radius)]
            }
            return []
        case let .concentric(a, b):
            guard let c1 = circleOf(a, s) ?? pointOf(a, s).map({ ($0, S.from(0)) }),
                  let c2 = circleOf(b, s) ?? pointOf(b, s).map({ ($0, S.from(0)) }) else { return [] }
            return [c1.center.x - c2.center.x, c1.center.y - c2.center.y]
        case let .pointOnLine(a, b):
            guard let p = pointOf(a, s), let (u, v) = segmentOf(b, s) else { return [] }
            let d = v - u
            return [d.cross(p - u) / S.larger(d.length, eps)]
        case let .pointOnCircle(a, b), let .pointOnArc(a, b):
            guard let p = pointOf(a, s), let c = circleOf(b, s) else { return [] }
            return [(p - c.center).length - c.radius]
        case let .pointOnBezier(a, b, t0):
            guard let p = pointOf(a, s), let curve = bezierOf(b, s) else { return [] }
            let t = auxiliary ?? S.from(t0)
            guard let q = curve.bezierAt(t) else { return [] }
            return [p.x - q.x, p.y - q.y]
        case let .bezierLineTangent(a, b, c, t0):
            guard let p = pointOf(a, s), let (u, v) = segmentOf(b, s),
                  let curve = bezierOf(c, s) else { return [] }
            let t = auxiliary ?? S.from(t0)
            guard let q = curve.bezierAt(t), let tangent = curve.bezierTangentAt(t) else { return [] }
            let d = v - u
            let scale = S.larger(d.length * tangent.length, eps)
            return [p.x - q.x, p.y - q.y, d.cross(tangent) / scale]
        case let .bezierLinePerpendicular(a, b, c, t0):
            guard let p = pointOf(a, s), let (u, v) = segmentOf(b, s),
                  let curve = bezierOf(c, s) else { return [] }
            let t = auxiliary ?? S.from(t0)
            guard let q = curve.bezierAt(t), let tangent = curve.bezierTangentAt(t) else { return [] }
            let d = v - u
            let scale = S.larger(d.length * tangent.length, eps)
            return [p.x - q.x, p.y - q.y, d.dot(tangent) / scale]
        case let .midpoint(a, b):
            guard let p = pointOf(a, s), let (u, v) = segmentOf(b, s) else { return [] }
            return [p.x - (u.x + v.x) / S.from(2), p.y - (u.y + v.y) / S.from(2)]
        case let .symmetric(a, b, l):
            guard let p = pointOf(a, s), let q = pointOf(b, s), let (u, v) = segmentOf(l, s) else { return [] }
            let d = v - u, n = S.larger(d.length, eps)
            let m = GVec2((p.x + q.x) / S.from(2), (p.y + q.y) / S.from(2))
            return [d.cross(m - u) / n, ((q.x - p.x) * d.x + (q.y - p.y) * d.y) / n]
        case let .fix(a, at):
            guard let p = pointOf(a, s) else { return [] }
            return [p.x - S.from(at.x), p.y - S.from(at.y)]
        case let .pointOnPlane(a):
            guard let p = point3Of(a, s) else { return [] }
            return [p.z]
        case let .normalToPlane(a):
            // The in-plane components of the direction, in mm: the row stays exact when the line
            // is already vertical (no division by its length), and the solver keeps it that way.
            guard let (p, q) = segment3Of(a, s) else { return [] }
            let d = q - p
            return [d.x, d.y]
        case let .fix3D(a, at):
            guard let p = point3Of(a, s) else { return [] }
            return [p.x - S.from(at.x), p.y - S.from(at.y), p.z - S.from(at.z)]
        case let .lockRotation(a, xd, wd):
            guard let shape = s[a.shapeID], case .workplane = shape.kind,
                  let p0 = shape.point3(0), let p1 = shape.point3(1), let p2 = shape.point3(2) else { return [] }
            let u = p1 - p0, w = p2 - p0
            return [u.x - S.from(xd.x), u.y - S.from(xd.y), u.z - S.from(xd.z),
                    w.x - S.from(wd.x), w.y - S.from(wd.y), w.z - S.from(wd.z)]
        case let .distance(a, b, d):
            if is3DRef(a, s) || is3DRef(b, s) {
                if let p = point3Of(a, s), let q = point3Of(b, s) {
                    return [(q - p).length - S.from(d)]
                }
                if let p = point3Of(a, s), let (u, v) = segment3Of(b, s) {
                    let dir = v - u
                    return [(p - u).cross(dir).length / S.larger(dir.length, eps) - S.from(d)]
                }
                if let p = point3Of(b, s), let (u, v) = segment3Of(a, s) {
                    let dir = v - u
                    return [(p - u).cross(dir).length / S.larger(dir.length, eps) - S.from(d)]
                }
                return []
            }
            if let p = pointOf(a, s), let q = pointOf(b, s) { return [(q - p).length - S.from(d)] }
            if let p = pointOf(a, s), let (u, v) = segmentOf(b, s) { return [sign * signedCross(p, u, v) / S.larger((v - u).length, eps) - S.from(d)] }
            if let (u1, v1) = segmentOf(a, s), let (u2, _) = segmentOf(b, s) {
                return [sign * signedCross(u2, u1, v1) / S.larger((v1 - u1).length, eps) - S.from(d)]
            }
            return []
        case let .offset(a, b, d):
            if let p = pointOf(a, s), let (u, v) = segmentOf(b, s) { return [sign * signedCross(p, u, v) / S.larger((v - u).length, eps) - S.from(d)] }
            if let (u1, v1) = segmentOf(a, s), let (u2, _) = segmentOf(b, s) {
                return [sign * signedCross(u2, u1, v1) / S.larger((v1 - u1).length, eps) - S.from(d)]
            }
            return []
        case let .horizontalDistance(a, b, d):
            if let p = pointOf(a, s), let q = pointOf(b, s) { return [sign * (q.x - p.x) - S.from(d)] }
            guard let p = point3Of(a, s), let q = point3Of(b, s) else { return [] }
            return [sign * (q.x - p.x) - S.from(d)]
        case let .verticalDistance(a, b, d):
            if let p = pointOf(a, s), let q = pointOf(b, s) { return [sign * (q.y - p.y) - S.from(d)] }
            guard let p = point3Of(a, s), let q = point3Of(b, s) else { return [] }
            return [sign * (q.y - p.y) - S.from(d)]
        case let .planeDistance(a, d):
            guard let p = point3Of(a, s) else { return [] }
            return [p.z - S.from(d)]
        case let .length(a, d):
            if let (p, q) = segment3Of(a, s) { return [(q - p).length - S.from(d)] }
            guard let (p, q) = segmentOf(a, s) else { return [] }
            return [(q - p).length - S.from(d)]
        case let .radius(a, d):
            guard let c = circleOf(a, s) else { return [] }
            return [c.radius - S.from(d)]
        case let .diameter(a, d):
            guard let c = circleOf(a, s) else { return [] }
            return [c.radius * S.from(2) - S.from(d)]
        case let .angle(a, b, deg):
            guard let (p1, q1) = segmentOf(a, s), let (p2, q2) = segmentOf(b, s) else { return [] }
            let d1 = q1 - p1, d2 = q2 - p2
            var e = S.angle(y: d1.cross(d2), x: d1.dot(d2)) - S.from(deg * .pi / 180 + branch.turn)
            while e.asDouble > .pi { e = e - S.from(2 * .pi) }
            while e.asDouble < -.pi { e = e + S.from(2 * .pi) }
            return [e * ((d1.length + d2.length) / S.from(2))]
        }
    }

    // MARK: Linear algebra

    /// Minimum-norm least squares: solves J Δ = b with J (m×n), returning Δ of smallest length
    /// among the least-squares solutions. Householder QR with column pivoting (no normal equations),
    /// truncated at the numerical rank so redundant constraints do not blow the step up.
    static func minimumNormSolve(_ J: [[Double]], _ b: [Double]) -> [Double]? {
        let m = J.count, n = J.first?.count ?? 0
        guard m > 0, n > 0, b.count == m else { return nil }
        let scale = J.flatMap { $0 }.map(abs).max() ?? 0
        guard scale > 1e-300 else { return [Double](repeating: 0, count: n) }
        let tol = 1e-10 * scale * Double(max(m, n))
        var A = J
        var rhs = b
        var pivots = Array(0..<n)
        var rank = 0
        for k in 0..<min(m, n) {
            var best = k, bestNorm = -1.0
            for c in k..<n {
                var s = 0.0
                for i in k..<m { s += A[i][c] * A[i][c] }
                if s > bestNorm { bestNorm = s; best = c }
            }
            guard bestNorm > 0 else { break }
            if best != k { for i in 0..<m { A[i].swapAt(k, best) }; pivots.swapAt(k, best) }
            let norm = bestNorm.squareRoot()
            guard norm > tol else { break }
            let x0 = A[k][k]
            let alpha = x0 >= 0 ? -norm : norm
            var v = [Double](repeating: 0, count: m - k)
            v[0] = x0 - alpha
            for i in (k + 1)..<m { v[i - k] = A[i][k] }
            let vNorm2 = v.reduce(0.0) { $0 + $1 * $1 }
            guard vNorm2 > 1e-30 else { rank = k; break }
            let beta = 2 / vNorm2
            for c in k..<n {
                var s = 0.0
                for i in k..<m { s += v[i - k] * A[i][c] }
                let f = beta * s
                for i in k..<m { A[i][c] -= f * v[i - k] }
            }
            var s = 0.0
            for i in k..<m { s += v[i - k] * rhs[i] }
            let f = beta * s
            for i in k..<m { rhs[i] -= f * v[i - k] }
            A[k][k] = alpha
            for i in (k + 1)..<m { A[i][k] = 0 }
            rank = k + 1
        }
        guard rank > 0 else { return [Double](repeating: 0, count: n) }
        var y = [Double](repeating: 0, count: n)
        // R11 y1 = rhs
        for i in stride(from: rank - 1, through: 0, by: -1) {
            var s = rhs[i]
            for j in (i + 1)..<rank { s -= A[i][j] * y[j] }
            guard abs(A[i][i]) > 1e-300 else { return nil }
            y[i] = s / A[i][i]
        }
        if rank < n {
            // y2 = R12ᵀ (R11ᵀ)⁻¹ y1  (the minimum-norm choice for the free variables)
            var w = [Double](repeating: 0, count: rank)
            for i in 0..<rank {
                var s = y[i]
                for k in 0..<i { s -= A[k][i] * w[k] }
                guard abs(A[i][i]) > 1e-300 else { return nil }
                w[i] = s / A[i][i]
            }
            for j in rank..<n {
                var s = 0.0
                for i in 0..<rank { s += A[i][j] * w[i] }
                y[j] = s
            }
        }
        var x = [Double](repeating: 0, count: n)
        for i in 0..<n { x[pivots[i]] = y[i] }
        return x
    }

    /// Basis of the null space of J (vectors of `n` entries): the directions the sketch can still
    /// move in. Reduced row echelon form, rank detected relative to the largest entry.
    static func nullBasis(_ J: [[Double]], _ n: Int) -> [[Double]] {
        var A = J
        let scale = max(1, A.flatMap { $0 }.map(abs).max() ?? 1)
        let tol = 1e-9 * scale
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

    /// Rank of a small set of rows (Gram–Schmidt with reorthogonalisation).
    static func rank(of rows: [[Double]], tolerance: Double = 1e-6) -> Int {
        var basis: [[Double]] = []
        for row in rows {
            var v = row
            let original = norm2(v).squareRoot()
            guard original > tolerance else { continue }
            for _ in 0..<2 {
                for b in basis {
                    let d = dot(v, b)
                    for j in v.indices { v[j] -= d * b[j] }
                }
            }
            let n = norm2(v).squareRoot()
            if n > tolerance * max(1, original) {
                basis.append(v.map { $0 / n })
            }
        }
        return basis.count
    }

    private static func norm2(_ v: [Double]) -> Double { v.reduce(0) { $0 + $1 * $1 } }
    private static func dot(_ a: [Double], _ b: [Double]) -> Double { zip(a, b).reduce(0) { $0 + $1.0 * $1.1 } }

    /// The constraints whose rows bring no new direction: adding them would over-constrain.
    static func redundantConstraints(_ J: [[Double]], owners: [SketchConstraint.ID]) -> [SketchConstraint.ID] {
        var basis: [[Double]] = []
        var independent: Set<SketchConstraint.ID> = []
        var seen: Set<SketchConstraint.ID> = []
        let scale = max(1, J.flatMap { $0 }.map(abs).max() ?? 1)
        for (row, owner) in zip(J, owners) {
            seen.insert(owner)
            var v = row
            let original = norm2(v).squareRoot()
            if original > 1e-12 * scale {
                for _ in 0..<2 {
                    for b in basis {
                        let d = dot(v, b)
                        for j in v.indices { v[j] -= d * b[j] }
                    }
                }
                let n = norm2(v).squareRoot()
                if n > 1e-9 * max(1, original) {
                    basis.append(v.map { $0 / n })
                    independent.insert(owner)
                }
            }
        }
        // A constraint that owns no independent row is redundant (only report real constraints).
        return seen.filter { !independent.contains($0) }.sorted { $0.uuidString < $1.uuidString }
    }
}
