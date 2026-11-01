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

/// A point, segment or circle of a sketch shape, or one of the sketch's fixed reference entities
/// (origin and axes), which exist in every sketch and cannot be moved by the solver.
public enum SketchRef: Codable, Sendable, Hashable {
    /// Polyline vertex i; rectangle corner 0…3 (4 = centre); circle centre (0); polygon centre (0)
    /// and vertices (1…n); slot arc centres 0 (start) and 1 (end); 3D point 0; 3D line end 0 or 1.
    case point(UUID, Int)
    /// Polyline side i (vertex i → i+1); rectangle side 0…3; polygon side i; slot straight side 0 or 1;
    /// 3D line 0.
    case segment(UUID, Int)
    /// Circle (0); slot arcs 0 (start) and 1 (end).
    case circle(UUID, Int)
    /// The sketch origin (0, 0): a point, fixed geometry.
    case origin
    /// The sketch X axis: a segment from the origin along +X, fixed geometry.
    case axisX
    /// The sketch Y axis: a segment from the origin along +Y, fixed geometry.
    case axisY

    /// The shape this reference points at. Fixed geometry uses sentinel IDs that no shape has, so
    /// filters over the sketch's shapes skip them.
    public var shapeID: UUID {
        switch self {
        case let .point(id, _), let .segment(id, _), let .circle(id, _): id
        case .origin: Self.originID
        case .axisX: Self.axisXID
        case .axisY: Self.axisYID
        }
    }

    /// Origin and axes are always there and have no parameters: the solver never moves them.
    public var isFixedGeometry: Bool {
        switch self {
        case .origin, .axisX, .axisY: true
        case .point, .segment, .circle: false
        }
    }

    static let originID = UUID(uuidString: "00000000-0000-0000-0000-000000000000")!
    static let axisXID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    static let axisYID = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
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
    /// A point on an arc (on its supporting circle).
    case pointOnArc(SketchRef, SketchRef)
    /// A point on a Bezier curve (referenced as `.circle(id, 0)`), at curve parameter `t`, which
    /// the solver moves together with the curve.
    case pointOnBezier(SketchRef, SketchRef, t: Double)
    /// A segment end (the first reference is its point, the second the segment) on a Bezier curve,
    /// with the segment tangent to the curve there (third reference: the curve).
    case bezierLineTangent(SketchRef, SketchRef, SketchRef, t: Double)
    /// A segment end on a Bezier curve, with the segment perpendicular to the curve there.
    case bezierLinePerpendicular(SketchRef, SketchRef, SketchRef, t: Double)
    /// Two lines lying on the same straight line.
    case colinear(SketchRef, SketchRef)
    /// G1 at a join: the two directions are equal (for two lines, the same as parallel).
    case smooth(SketchRef, SketchRef)
    case midpoint(SketchRef, SketchRef)
    /// Two points mirrored about a line (the third reference).
    case symmetric(SketchRef, SketchRef, SketchRef)
    /// Point pinned where it is.
    case fix(SketchRef, Vec2)
    // 3D constraints, for entities off the sketch plane (coordinates in the plane's frame).
    /// A 3D point lying on the sketch plane (z = 0).
    case pointOnPlane(SketchRef)
    /// A 3D line parallel to the sketch plane's normal (its two in-plane components are 0).
    case normalToPlane(SketchRef)
    /// A 3D point pinned at a position of the plane's frame.
    case fix3D(SketchRef, Vec3)
    /// A workplane's orientation frozen where it was (the two vectors from its origin to the
    /// X-axis point and to the in-plane point); its origin stays free, like dune3d's lock rotation.
    case lockRotation(SketchRef, xDirection: Vec3, planeDirection: Vec3)
    // Dimensions (driving values, mm or degrees).
    case distance(SketchRef, SketchRef, Double)
    case horizontalDistance(SketchRef, SketchRef, Double)
    case verticalDistance(SketchRef, SketchRef, Double)
    /// Signed distance from a 3D point to the sketch plane, along its normal (mm).
    case planeDistance(SketchRef, Double)
    case length(SketchRef, Double)
    case radius(SketchRef, Double)
    case diameter(SketchRef, Double)
    /// Angle from the first line to the second, degrees.
    case angle(SketchRef, SketchRef, Double)
    /// Signed distance from a point (or the first line) to a line: the other side keeps its sign.
    case offset(SketchRef, SketchRef, Double)

    public var refs: [SketchRef] {
        switch self {
        case let .coincident(a, b), let .parallel(a, b), let .perpendicular(a, b), let .equal(a, b), let .tangent(a, b),
             let .concentric(a, b), let .pointOnLine(a, b), let .pointOnCircle(a, b), let .pointOnArc(a, b),
             let .pointOnBezier(a, b, _),
             let .colinear(a, b), let .smooth(a, b), let .midpoint(a, b),
             let .distance(a, b, _), let .horizontalDistance(a, b, _), let .verticalDistance(a, b, _),
             let .angle(a, b, _), let .offset(a, b, _):
            [a, b]
        case let .horizontal(a), let .vertical(a), let .fix(a, _), let .length(a, _), let .radius(a, _), let .diameter(a, _),
             let .pointOnPlane(a), let .normalToPlane(a), let .fix3D(a, _), let .planeDistance(a, _),
             let .lockRotation(a, _, _):
            [a]
        case let .bezierLineTangent(p, s, c, _), let .bezierLinePerpendicular(p, s, c, _):
            [p, s, c]
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
        case let .pointOnArc(a, b): guard let a = f(a), let b = f(b) else { return nil }; return .pointOnArc(a, b)
        case let .pointOnBezier(a, b, t): guard let a = f(a), let b = f(b) else { return nil }; return .pointOnBezier(a, b, t: t)
        case let .bezierLineTangent(p, s, c, t):
            guard let p = f(p), let s = f(s), let c = f(c) else { return nil }
            return .bezierLineTangent(p, s, c, t: t)
        case let .bezierLinePerpendicular(p, s, c, t):
            guard let p = f(p), let s = f(s), let c = f(c) else { return nil }
            return .bezierLinePerpendicular(p, s, c, t: t)
        case let .colinear(a, b): guard let a = f(a), let b = f(b) else { return nil }; return .colinear(a, b)
        case let .smooth(a, b): guard let a = f(a), let b = f(b) else { return nil }; return .smooth(a, b)
        case let .midpoint(a, b): guard let a = f(a), let b = f(b) else { return nil }; return .midpoint(a, b)
        case let .symmetric(a, b, l): guard let a = f(a), let b = f(b), let l = f(l) else { return nil }; return .symmetric(a, b, l)
        case let .distance(a, b, v): guard let a = f(a), let b = f(b) else { return nil }; return .distance(a, b, v)
        case let .horizontalDistance(a, b, v): guard let a = f(a), let b = f(b) else { return nil }; return .horizontalDistance(a, b, v)
        case let .verticalDistance(a, b, v): guard let a = f(a), let b = f(b) else { return nil }; return .verticalDistance(a, b, v)
        case let .angle(a, b, v): guard let a = f(a), let b = f(b) else { return nil }; return .angle(a, b, v)
        case let .offset(a, b, v): guard let a = f(a), let b = f(b) else { return nil }; return .offset(a, b, v)
        case let .horizontal(a): return f(a).map { .horizontal($0) }
        case let .vertical(a): return f(a).map { .vertical($0) }
        case let .fix(a, v): return f(a).map { .fix($0, v) }
        case let .pointOnPlane(a): return f(a).map { .pointOnPlane($0) }
        case let .normalToPlane(a): return f(a).map { .normalToPlane($0) }
        case let .fix3D(a, v): return f(a).map { .fix3D($0, v) }
        case let .planeDistance(a, v): return f(a).map { .planeDistance($0, v) }
        case let .lockRotation(a, x, w): return f(a).map { .lockRotation($0, xDirection: x, planeDirection: w) }
        case let .length(a, v): return f(a).map { .length($0, v) }
        case let .radius(a, v): return f(a).map { .radius($0, v) }
        case let .diameter(a, v): return f(a).map { .diameter($0, v) }
        }
    }

    /// The driving value of a dimension (nil for a geometric constraint).
    public var value: Double? {
        switch self {
        case let .distance(_, _, v), let .horizontalDistance(_, _, v), let .verticalDistance(_, _, v), let .planeDistance(_, v),
             let .length(_, v), let .radius(_, v), let .diameter(_, v), let .angle(_, _, v), let .offset(_, _, v): v
        default: nil
        }
    }

    /// The same dimension with another value.
    public func with(value v: Double) -> SketchConstraintKind {
        switch self {
        case let .distance(a, b, _): .distance(a, b, v)
        case let .horizontalDistance(a, b, _): .horizontalDistance(a, b, v)
        case let .verticalDistance(a, b, _): .verticalDistance(a, b, v)
        case let .planeDistance(a, _): .planeDistance(a, v)
        case let .length(a, _): .length(a, v)
        case let .radius(a, _): .radius(a, v)
        case let .diameter(a, _): .diameter(a, v)
        case let .angle(a, b, _): .angle(a, b, v)
        case let .offset(a, b, _): .offset(a, b, v)
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
        case .pointOnArc: "Punto su arco"
        case .pointOnBezier: "Punto su Bezier"
        case .bezierLineTangent: "Tangente alla Bezier"
        case .bezierLinePerpendicular: "Perpendicolare alla Bezier"
        case .colinear: "Allineato"
        case .smooth: "Continuo"
        case .midpoint: "Punto medio"
        case .symmetric: "Simmetrico"
        case .fix: "Fisso"
        case .pointOnPlane: "Punto sul piano"
        case .normalToPlane: "Normale al piano"
        case .fix3D: "Fisso 3D"
        case .lockRotation: "Blocco rotazione"
        case .distance: "Distanza"
        case .horizontalDistance: "Distanza orizzontale"
        case .verticalDistance: "Distanza verticale"
        case .planeDistance: "Distanza dal piano"
        case .length: "Lunghezza"
        case .radius: "Raggio"
        case .diameter: "Diametro"
        case .angle: "Angolo"
        case .offset: "Scostamento"
        }
    }
}

public struct SketchConstraint: Identifiable, Codable, Sendable, Equatable {
    public var id: UUID
    public var kind: SketchConstraintKind
    /// A user parameter name or an expression driving a dimension (e.g. "larghezza / 2").
    public var expression: String?
    /// A reference (driven) dimension: it measures the sketch and never moves it.
    public var isReference: Bool

    public init(id: UUID = UUID(), _ kind: SketchConstraintKind, expression: String? = nil,
                isReference: Bool = false) {
        self.id = id; self.kind = kind; self.expression = expression; self.isReference = isReference
    }

    private enum CodingKeys: String, CodingKey { case id, kind, expression, isReference }

    /// Hand-written so old files without `isReference` still open.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        kind = try c.decode(SketchConstraintKind.self, forKey: .kind)
        expression = try c.decodeIfPresent(String.self, forKey: .expression)
        isReference = try c.decodeIfPresent(Bool.self, forKey: .isReference) ?? false
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
        case let .spline(p, _): p.flatMap { [$0.x, $0.y] }
        case let .bezier(p0, c1, c2, p3): [p0.x, p0.y, c1.x, c1.y, c2.x, c2.y, p3.x, p3.y]
        case let .point3D(p): [p.x, p.y, p.z]
        case let .line3D(a, b): [a.x, a.y, a.z, b.x, b.y, b.z]
        case let .workplane(o, x, p): [o.x, o.y, o.z, x.x, x.y, x.z, p.x, p.y, p.z]
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
        case let .spline(_, closed):
            s.kind = .spline(points: stride(from: 0, to: v.count - 1, by: 2).map { Vec2(v[$0], v[$0 + 1]) }, closed: closed)
        case .bezier:
            s.kind = .bezier(start: Vec2(v[0], v[1]), control1: Vec2(v[2], v[3]),
                             control2: Vec2(v[4], v[5]), end: Vec2(v[6], v[7]))
        case .point3D: s.kind = .point3D(position: Vec3(v[0], v[1], v[2]))
        case .line3D: s.kind = .line3D(start: Vec3(v[0], v[1], v[2]), end: Vec3(v[3], v[4], v[5]))
        case .workplane:
            s.kind = .workplane(origin: Vec3(v[0], v[1], v[2]), xAxisPoint: Vec3(v[3], v[4], v[5]),
                                planePoint: Vec3(v[6], v[7], v[8]))
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
        case let .spline(p, _): return p.indices.contains(i) ? p[i] : nil
        case let .bezier(p0, c1, c2, p3): return [p0, c1, c2, p3][safe: i]
        case let .arc(c, r, a0, a1):
            switch i {
            case 0: return c
            case 1: return Vec2(c.x + r * cos(a0), c.y + r * sin(a0))
            case 2: return Vec2(c.x + r * cos(a1), c.y + r * sin(a1))
            default: return nil
            }
        case .point3D, .line3D, .workplane:
            return nil
        }
    }

    /// A point of a 3D entity, in the sketch's plane frame.
    public func point3D(_ i: Int) -> Vec3? {
        switch kind {
        case let .point3D(p): return i == 0 ? p : nil
        case let .line3D(a, b): return i == 0 ? a : (i == 1 ? b : nil)
        case let .workplane(o, x, p): return [o, x, p][safe: i]
        default: return nil
        }
    }

    /// The segment of a 3D line, in the sketch's plane frame.
    public func segment3D(_ i: Int) -> (Vec3, Vec3)? {
        guard case let .line3D(a, b) = kind, i == 0 else { return nil }
        return (a, b)
    }

    /// Free geometry off the sketch plane: its points carry a third coordinate the solver moves.
    public var is3D: Bool {
        switch kind {
        case .point3D, .line3D, .workplane: return true
        default: return false
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
        case let .spline(p, _): p.count
        case .bezier: 4
        case .point3D: 1
        case .line3D: 2
        case .workplane: 3
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
        case .circle, .arc, .spline, .bezier, .point3D, .line3D, .workplane: return nil
        }
    }

    public var segmentCount: Int {
        switch kind {
        case let .polyline(p, closed): closed ? p.count : max(0, p.count - 1)
        case .rectangle: 4
        case let .polygon(_, _, n, _, _): max(3, n)
        case .slot: 2
        case .circle, .arc, .spline, .bezier, .point3D, .workplane: 0
        case .line3D: 1
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
        try cutCorner(shapeID, vertex: i, size: r, chamfer: false)
    }

    /// Sketch chamfer: the corner is cut by a line `distance` from it along both sides, joined
    /// to them by coincident constraints. Returns the new line's ID.
    @discardableResult
    public mutating func chamfer(_ shapeID: UUID, vertex i: Int, distance d: Double) throws -> UUID {
        try cutCorner(shapeID, vertex: i, size: d, chamfer: true)
    }

    private mutating func cutCorner(_ shapeID: UUID, vertex i: Int, size r: Double, chamfer: Bool) throws -> UUID {
        guard let k = shapes.firstIndex(where: { $0.id == shapeID }) else { throw SketchEditError.invalid("forma non trovata") }
        guard r.isFinite, r > 0 else { throw SketchEditError.invalid(chamfer ? "distanza non valida" : "raggio non valido") }
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
        let d = chamfer ? r : r / tan(theta / 2)
        guard d < la - 1e-6, d < lb - 1e-6 else {
            if chamfer { throw SketchEditError.invalid(String(format: "smusso troppo grande per questi lati (massimo %.2f mm)", min(la, lb))) }
            throw SketchEditError.invalid(String(format: "raggio troppo grande per questo angolo (massimo %.2f mm)", min(la, lb) * tan(theta / 2)))
        }
        let t1 = p[i] + u1 * d, t2 = p[i] + u2 * d
        let bis = u1 + u2, lbis = len(bis)
        let c = p[i] + bis * (1 / lbis) * (r / sin(theta / 2))
        let a1 = atan2(t1.y - c.y, t1.x - c.x), a2 = atan2(t2.y - c.y, t2.x - c.x)
        // The short way round: start/end so that the counter-clockwise sweep is under half a turn.
        let (start, end, t1IsStart) = SketchShape.sweep(a1, a2) <= .pi ? (a1, a2, true) : (a2, a1, false)
        let arc = chamfer ? SketchShape(kind: .polyline([t1, t2], closed: false), isConstruction: shape.isConstruction)
                          : SketchShape(kind: .arc(center: c, radius: r, start: start, end: end))
        let t1Point = chamfer ? 0 : (t1IsStart ? 1 : 2), t2Point = chamfer ? 1 : (t1IsStart ? 2 : 1)

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
            case .origin, .axisX, .axisY: return ref   // fixed geometry, not this shape's
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
            added += [.init(.coincident(.point(shapeID, m - 1), .point(arc.id, t1Point))), .init(.coincident(.point(shapeID, 0), .point(arc.id, t2Point)))]
            if !chamfer { added += [.init(.tangent(.segment(shapeID, m - 2), .point(arc.id, t1Point))), .init(.tangent(.segment(shapeID, 0), .point(arc.id, t2Point)))] }
        } else {
            shape.kind = .polyline(Array(p[0..<i]) + [t1], closed: false)
            shapes[k] = shape
            let second = SketchShape(id: secondID, kind: .polyline([t2] + Array(p[(i + 1)...]), closed: false), isConstruction: shape.isConstruction)
            shapes.insert(second, at: k + 1)
            added += [.init(.coincident(.point(shapeID, i), .point(arc.id, t1Point))), .init(.coincident(.point(second.id, 0), .point(arc.id, t2Point)))]
            if !chamfer { added += [.init(.tangent(.segment(shapeID, i - 1), .point(arc.id, t1Point))), .init(.tangent(.segment(second.id, 0), .point(arc.id, t2Point)))] }
        }
        shapes.insert(arc, at: k + 1)
        constraints += added + (chamfer ? [] : [.init(.radius(.circle(arc.id, 0), r))])
        return arc.id
    }

    // MARK: Rectangles as four constrained lines (dune3d's rectangle tool)

    /// Adds a rectangle as four independent lines joined at the corners by coincident constraints,
    /// each side with its horizontal or vertical relation — the way dune3d builds it. The four
    /// lines still leave four freedoms (position plus the two sizes), exactly like a `.rectangle`
    /// shape, but every relation is now visible in the constraint list. Returns the line IDs.
    @discardableResult
    public mutating func addRectangle(corner: Vec2, width w: Double, height h: Double) -> [UUID] {
        // Dragging the opposite corner backwards is fine: the sides are turned the other way round.
        let start = Vec2(w < 0 ? corner.x + w : corner.x, h < 0 ? corner.y + h : corner.y)
        let width = abs(w), height = abs(h)
        let corners = [start, Vec2(start.x + width, start.y),
                       Vec2(start.x + width, start.y + height), Vec2(start.x, start.y + height)]
        var ids: [UUID] = []
        for i in 0..<4 {
            let line = SketchShape(kind: .polyline([corners[i], corners[(i + 1) % 4]], closed: false))
            shapes.append(line)
            ids.append(line.id)
        }
        constraints += [
            .init(.horizontal(.segment(ids[0], 0))), .init(.vertical(.segment(ids[1], 0))),
            .init(.horizontal(.segment(ids[2], 0))), .init(.vertical(.segment(ids[3], 0))),
        ]
        for i in 0..<4 {
            constraints.append(.init(.coincident(.point(ids[i], 1), .point(ids[(i + 1) % 4], 0))))
        }
        return ids
    }

    /// Sketch fillet between two lines that meet at a shared corner (the rectangle above is four
    /// such lines): both are trimmed to their tangent points, the corner becomes an arc, and
    /// coincident/tangent relations plus the radius dimension keep the three pieces joined.
    @discardableResult
    public mutating func fillet(_ a: UUID, vertex ia: Int, _ b: UUID, vertex ib: Int, radius r: Double) throws -> UUID {
        try cutCornerBetween(a, ia, b, ib, size: r, chamfer: false)
    }

    /// Sketch chamfer between two lines meeting at a shared corner: the corner is cut by a line
    /// `distance` from it along both, joined to the trimmed ends by coincident relations.
    @discardableResult
    public mutating func chamfer(_ a: UUID, vertex ia: Int, _ b: UUID, vertex ib: Int, distance d: Double) throws -> UUID {
        try cutCornerBetween(a, ia, b, ib, size: d, chamfer: true)
    }

    private mutating func cutCornerBetween(_ aID: UUID, _ ia: Int, _ bID: UUID, _ ib: Int,
                                           size r: Double, chamfer: Bool) throws -> UUID {
        guard let ka = shapes.firstIndex(where: { $0.id == aID }),
              let kb = shapes.firstIndex(where: { $0.id == bID }) else {
            throw SketchEditError.invalid("raccordo: forma non trovata")
        }
        guard r.isFinite, r > 0 else { throw SketchEditError.invalid(chamfer ? "distanza non valida" : "raggio non valido") }
        guard case let .polyline(pa, closedA) = shapes[ka].kind, !closedA,
              case let .polyline(pb, closedB) = shapes[kb].kind, !closedB else {
            throw SketchEditError.invalid("raccordo: servono due linee aperte")
        }
        guard pa.count >= 2, pb.count >= 2, (ia == 0 || ia == pa.count - 1), (ib == 0 || ib == pb.count - 1),
              pa.indices.contains(ia), pb.indices.contains(ib) else {
            throw SketchEditError.invalid("raccordo: l'angolo deve essere un estremo delle due linee")
        }
        func len(_ v: Vec2) -> Double { (v.x * v.x + v.y * v.y).squareRoot() }
        let p = pa[ia], q = pb[ib]
        guard len(p - q) < 1e-5 else { throw SketchEditError.invalid("raccordo: le due linee non si incontrano in questo punto") }
        func away(_ pts: [Vec2], _ i: Int) -> Vec2 {
            let d = pts[i == 0 ? 1 : i - 1] - pts[i]
            let l = len(d)
            guard l > 1e-12 else { return Vec2(1, 0) }
            return d * (1 / l)
        }
        let u1 = away(pa, ia), u2 = away(pb, ib)
        let cosT = max(-1, min(1, u1.x * u2.x + u1.y * u2.y))
        let theta = acos(cosT)
        guard theta > 1e-3, theta < .pi - 1e-3 else { throw SketchEditError.invalid("raccordo: le due linee sono allineate") }
        let d = chamfer ? r : r / tan(theta / 2)
        let la = len(pa[ia == 0 ? 1 : ia - 1] - p), lb = len(pb[ib == 0 ? 1 : ib - 1] - q)
        guard d < la - 1e-6, d < lb - 1e-6 else {
            if chamfer { throw SketchEditError.invalid(String(format: "smusso troppo grande per queste linee (massimo %.2f mm)", min(la, lb))) }
            throw SketchEditError.invalid(String(format: "raggio troppo grande per questo angolo (massimo %.2f mm)", min(la, lb) * tan(theta / 2)))
        }
        let t1 = p + u1 * d, t2 = q + u2 * d
        let bis = u1 + u2
        let c = p + bis * (1 / len(bis)) * (r / sin(theta / 2))
        let a1 = atan2(t1.y - c.y, t1.x - c.x), a2 = atan2(t2.y - c.y, t2.x - c.x)
        let (start, end, t1IsStart) = SketchShape.sweep(a1, a2) <= .pi ? (a1, a2, true) : (a2, a1, false)
        let arc = chamfer ? SketchShape(kind: .polyline([t1, t2], closed: false))
                          : SketchShape(kind: .arc(center: c, radius: r, start: start, end: end))
        // The two lines now end at the tangent points; the relation that joined the corner goes.
        var ptsA = pa; ptsA[ia] = t1
        var ptsB = pb; ptsB[ib] = t2
        var shapeA = shapes[ka]; shapeA.kind = .polyline(ptsA, closed: false)
        var shapeB = shapes[kb]; shapeB.kind = .polyline(ptsB, closed: false)
        shapes[ka] = shapeA
        shapes[kb] = shapeB
        let ra = SketchRef.point(aID, ia), rb = SketchRef.point(bID, ib)
        constraints.removeAll { c in
            let refs = c.kind.refs
            return refs.contains(ra) && refs.contains(rb)
        }
        shapes.insert(arc, at: max(ka, kb) + 1)
        let t1Point = chamfer ? 0 : (t1IsStart ? 1 : 2), t2Point = chamfer ? 1 : (t1IsStart ? 2 : 1)
        var added: [SketchConstraint] = [
            .init(.coincident(.point(aID, ia), .point(arc.id, t1Point))),
            .init(.coincident(.point(bID, ib), .point(arc.id, t2Point))),
        ]
        if !chamfer {
            added += [.init(.tangent(.segment(aID, ia == 0 ? 0 : pa.count - 2), .point(arc.id, t1Point))),
                      .init(.tangent(.segment(bID, ib == 0 ? 0 : pb.count - 2), .point(arc.id, t2Point))),
                      .init(.radius(.circle(arc.id, 0), r))]
        }
        constraints += added
        return arc.id
    }

    // MARK: All the corners of a rectangle or a polygon

    /// Rounds every corner of a rectangle or a regular polygon with arcs of radius `r`, the way the
    /// UI's Raccordo tool works when a whole shape is clicked: the shape becomes lines and arcs in
    /// one step. Returns the arcs' IDs, in corner order (rectangle: corners 0…3, polygon: vertices
    /// 1…n). Throws, leaving the sketch untouched, when the radius does not fit a side.
    @discardableResult
    public mutating func filletAllCorners(_ shapeID: UUID, radius r: Double) throws -> [UUID] {
        try cutAllCorners(shapeID, size: r, chamfer: false)
    }

    /// Cuts every corner of a rectangle or a polygon with a line `distance` from the corner along
    /// both sides. Returns the chamfer lines' IDs, in corner order.
    @discardableResult
    public mutating func chamferAllCorners(_ shapeID: UUID, distance d: Double) throws -> [UUID] {
        try cutAllCorners(shapeID, size: d, chamfer: true)
    }

    private mutating func cutAllCorners(_ shapeID: UUID, size r: Double, chamfer: Bool) throws -> [UUID] {
        guard let k = shapes.firstIndex(where: { $0.id == shapeID }) else { throw SketchEditError.invalid("forma non trovata") }
        guard r.isFinite, r > 0 else { throw SketchEditError.invalid(chamfer ? "distanza non valida" : "raggio non valido") }
        let shape = shapes[k]
        let corners: [Vec2]
        switch shape.kind {
        case .rectangle:
            corners = (0..<4).compactMap { shape.point($0) }
        case let .polygon(_, _, n, _, _):
            corners = (1...max(3, n)).compactMap { shape.point($0) }
        default:
            throw SketchEditError.invalid("raccordo: scegli un rettangolo o un poligono")
        }
        let n = corners.count
        guard n >= 3 else { throw SketchEditError.invalid("raccordo: servono almeno tre angoli") }

        // One open line per side, the first keeping the shape's ID so its dimensions and constraints
        // (remapped by position) stay on it. The corners are joined by coincident relations and, for
        // a rectangle, the sides keep their H/V, exactly as a corner fillet does.
        let ids = (0..<n).map { $0 == 0 ? shapeID : UUID() }
        var lines: [SketchShape] = []
        for i in 0..<n {
            lines.append(SketchShape(id: ids[i], kind: .polyline([corners[i], corners[(i + 1) % n]], closed: false),
                                     isConstruction: shape.isConstruction))
        }
        var implied: [SketchConstraint] = []
        if case .rectangle = shape.kind {
            implied += [.init(.horizontal(.segment(ids[0], 0))), .init(.vertical(.segment(ids[1], 0))),
                        .init(.horizontal(.segment(ids[2], 0))), .init(.vertical(.segment(ids[3], 0)))]
        }
        for i in 0..<n {
            implied.append(.init(.coincident(.point(ids[i], 1), .point(ids[(i + 1) % n], 0))))
        }

        // Work on a copy: a corner whose sides are too short for the radius leaves the sketch as it was.
        var next = self
        next.replaceShape(shapeID, with: lines, implied: implied)
        var made: [UUID] = []
        for i in 0..<n {
            made.append(try next.cutCornerBetween(ids[i], 1, ids[(i + 1) % n], 0, size: r, chamfer: chamfer))
        }
        self = next
        return made
    }
}
