import Foundation

/// The true curve of an edge (docs/SUPERFICI_ESATTE.md, tappa 2): where its two surfaces meet,
/// found from their exact descriptions, not from the facets. The edge's polyline is only its
/// tessellation; points, centres and radii come from here.
public enum EdgeCurve: Equatable, Sendable {
    /// A straight edge: a point on it and its unit direction.
    case line(point: Vec3, direction: Vec3)
    /// A circle (or an arc of it): centre, unit axis, radius.
    case circle(center: Vec3, axis: Vec3, radius: Double)

    /// How far a point is from the curve.
    public func distance(_ p: Vec3) -> Double { (closest(p) - p).length }

    /// The point of the curve nearest to `p`.
    public func closest(_ p: Vec3) -> Vec3 {
        switch self {
        case let .line(q, d):
            return q + d * (p - q).dot(d)
        case let .circle(c, a, r):
            let v = p - c, inPlane = v - a * v.dot(a)
            guard inPlane.length > 1e-12 else {
                let helper = abs(a.z) < 0.9 ? Vec3(0, 0, 1) : Vec3(1, 0, 0)
                return c + helper.cross(a).normalized * r
            }
            return c + inPlane.normalized * r
        }
    }

    /// The same curve moved by a rigid motion (or mirror image).
    public func mapped(point: (Vec3) -> Vec3, direction: (Vec3) -> Vec3) -> EdgeCurve {
        switch self {
        case let .line(q, d): .line(point: point(q), direction: direction(d).normalized)
        case let .circle(c, a, r): .circle(center: point(c), axis: direction(a).normalized, radius: r)
        }
    }

    /// Where two surfaces meet along `polyline`, when that is a line or a circle both surfaces
    /// describe exactly (planes, and the coaxial pairs rounds and holes make); nil otherwise (an
    /// ellipse, a curve of two cylinders crossing: still only its facets).
    public static func between(_ s: SurfaceDescriptor, _ t: SurfaceDescriptor, polyline: [Vec3]) -> EdgeCurve? {
        guard polyline.count >= 2 else { return nil }
        let size = polyline.map { max(abs($0.x), abs($0.y), abs($0.z)) }.max() ?? 1
        let tol = 1e-4 + 1e-6 * size
        // The facets' corners are on the curve; points the booleans add on a facet's chord are
        // not, by at most the chord's sagitta (32 facets per turn at the coarsest).
        let key = corners(polyline, tol: tol)
        return (candidates(s, t) + candidates(t, s)).first { c in
            let slack: Double = if case let .circle(_, _, r) = c { r * (1 - cos(Double.pi / 32)) } else { 0 }
            return key.allSatisfy { c.distance($0) <= tol } && polyline.allSatisfy { c.distance($0) <= tol + slack }
        }
    }

    /// The polyline without the points lying on the straight piece between their neighbours.
    static func corners(_ p: [Vec3], tol: Double) -> [Vec3] {
        let closed = p.count > 3 && (p.first! - p.last!).length < 1e-9
        var kept = closed ? Array(p.dropLast()) : p
        var removed = true
        while removed, kept.count > 3 {
            removed = false
            var i = closed ? 0 : 1
            while i < (closed ? kept.count : kept.count - 1), kept.count > 3 {
                let a = kept[(i + kept.count - 1) % kept.count], b = kept[(i + 1) % kept.count], q = kept[i]
                let d = b - a, l = d.length
                if l > 1e-12, ((q - a) - d * ((q - a).dot(d) / (l * l))).length < tol { kept.remove(at: i); removed = true } else { i += 1 }
            }
        }
        return kept
    }

    private static func candidates(_ s: SurfaceDescriptor, _ t: SurfaceDescriptor) -> [EdgeCurve] {
        func unit(_ v: Vec3) -> Vec3 { v.normalized }
        switch (s, t) {
        case let (.plane(o1, n1), .plane(o2, n2)):
            let a = unit(n1), b = unit(n2), c = a.dot(b), d = a.cross(b)
            guard d.length > 1e-9 else { return [] }
            let h1 = o1.dot(a), h2 = o2.dot(b)
            let p = (a * (h1 - h2 * c) + b * (h2 - h1 * c)) * (1 / (1 - c * c))
            return [.line(point: p, direction: d.normalized)]
        case let (.plane(o, n0), .cylinder(c, a0, r)):
            let n = unit(n0), a = unit(a0), na = n.dot(a)
            if abs(abs(na) - 1) < 1e-9 { return [.circle(center: c + a * ((o - c).dot(n) / na), axis: a, radius: r)] }
            guard abs(na) < 1e-9 else { return [] }
            // The plane along the axis: two lines along it (or one, touching).
            let d = (c - o).dot(n)
            guard abs(d) <= r + 1e-9 else { return [] }
            let w = a.cross(n).normalized, s = max(0, r * r - d * d).squareRoot()
            let foot = c - n * d
            return [.line(point: foot + w * s, direction: a), .line(point: foot - w * s, direction: a)]
        case let (.plane(o, n0), .cone(apex, a0, half)):
            let n = unit(n0), a = unit(a0), na = n.dot(a)
            guard abs(abs(na) - 1) < 1e-9 else { return [] }
            let h = (o - apex).dot(n) / na
            return [.circle(center: apex + a * h, axis: a, radius: abs(h) * tan(half))]
        case let (.plane(o, n0), .sphere(c, r)):
            let n = unit(n0), d = (c - o).dot(n)
            guard abs(d) < r else { return [] }
            return [.circle(center: c - n * d, axis: n, radius: (r * r - d * d).squareRoot())]
        case let (.plane(o, n0), .torus(c, a0, big, small)):
            let n = unit(n0), a = unit(a0), na = n.dot(a)
            guard abs(abs(na) - 1) < 1e-9 else { return [] }
            let h = (o - c).dot(n) / na, q = small * small - h * h
            guard q >= 0 else { return [] }
            let centre = c + a * h
            return [.circle(center: centre, axis: a, radius: big + q.squareRoot()), .circle(center: centre, axis: a, radius: big - q.squareRoot())]
        case let (.cylinder(c1, a1, r1), .torus(c, a0, big, small)):
            // A round on a hole's or a shaft's rim: coaxial, they meet on circles of the cylinder.
            let a = unit(a0)
            guard abs(abs(unit(a1).dot(a)) - 1) < 1e-9, ((c1 - c) - a * (c1 - c).dot(a)).length < 1e-6 else { return [] }
            let q = small * small - (r1 - big) * (r1 - big)
            guard q >= 0 else { return [] }
            return [.circle(center: c + a * q.squareRoot(), axis: a, radius: r1), .circle(center: c - a * q.squareRoot(), axis: a, radius: r1)]
        case let (.cylinder(c1, a1, r1), .sphere(c, r)):
            let a = unit(a1)
            guard ((c - c1) - a * (c - c1).dot(a)).length < 1e-6, r > r1 else { return [] }
            let h = (r * r - r1 * r1).squareRoot(), foot = c1 + a * (c - c1).dot(a)
            return [.circle(center: foot + a * h, axis: a, radius: r1), .circle(center: foot - a * h, axis: a, radius: r1)]
        default:
            return []
        }
    }
}
