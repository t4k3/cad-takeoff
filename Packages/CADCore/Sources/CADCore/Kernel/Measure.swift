import Foundation

/// «Misura»: the shortest distance between picked faces and edges, and the size of round edges.
public enum Measure {
    /// Triangles and segments of a picked face or edge (world mm).
    public struct Shape: Sendable {
        public var triangles: [(Vec3, Vec3, Vec3)] = []
        public var segments: [(Vec3, Vec3)] = []
        public init(triangles: [(Vec3, Vec3, Vec3)] = [], segments: [(Vec3, Vec3)] = []) { self.triangles = triangles; self.segments = segments }
        var points: [Vec3] { triangles.flatMap { [$0.0, $0.1, $0.2] } + segments.flatMap { [$0.0, $0.1] } }
    }

    public static func shape(face id: FaceID, in s: BodySnapshot) -> Shape? {
        guard let f = s.faces.firstIndex(where: { $0.id == id }) else { return nil }
        var out = Shape()
        for t in 0..<s.triangleFace.count where Int(s.triangleFace[t]) == f {
            out.triangles.append((s.positions[Int(s.triangles[t * 3])], s.positions[Int(s.triangles[t * 3 + 1])], s.positions[Int(s.triangles[t * 3 + 2])]))
        }
        return out.triangles.isEmpty ? nil : out
    }

    public static func shape(edge e: EdgeInfo) -> Shape {
        Shape(segments: Array(zip(e.polyline, e.polyline.dropFirst())))
    }

    /// The round edge's diameter, centre and axis (nil when the edge is not a circle or an arc).
    public static func circle(of e: EdgeInfo) -> (diameter: Double, centre: Vec3, axis: Vec3)? {
        // Its true circle when the kernel knows it (tappa 2 of the exact surfaces).
        if case let .circle(c, axis, r)? = e.curve { return (2 * r, c, axis.normalized) }
        if case .line? = e.curve { return nil }
        guard e.polyline.count >= 4, let frame = JointFrame.from(edge: e) else { return nil }
        let (a, b) = (e.polyline.first!, e.polyline.last!)
        // A straight edge gives its middle: not a circle.
        if e.polyline.allSatisfy({ q in let d = (b - a).normalized, w = q - a; return (w - d * w.dot(d)).length < 1e-6 }) { return nil }
        let r = JointFrame.corners(e.polyline).map { ($0 - frame.origin).length }.max()!
        return (2 * r, frame.origin, frame.axis)
    }

    /// The edge's length on its true curve: a straight edge end to end, an arc its angle times
    /// its radius (a whole circle 2πr), else along the facets.
    public static func length(of e: EdgeInfo) -> Double {
        guard let first = e.polyline.first, let last = e.polyline.last else { return 0 }
        switch e.curve {
        case .line?:
            return (last - first).length
        case let .circle(c, axis, r)?:
            let n = axis.normalized
            func radial(_ p: Vec3) -> Vec3 { let v = p - c; return v - n * v.dot(n) }
            var angle = 0.0
            for (a, b) in zip(e.polyline, e.polyline.dropFirst()) {
                let u = radial(a), v = radial(b)
                angle += abs(atan2(u.cross(v).dot(n), u.dot(v)))
            }
            // A closed circle is a whole turn, whatever its facets add up to.
            if (last - first).length < 1e-9 && e.polyline.count > 2 { angle = 2 * .pi }
            return angle * r
        case nil:
            return e.length
        }
    }

    /// Shortest distance between two shapes and the two closest points.
    public static func distance(_ a: Shape, _ b: Shape) -> (distance: Double, from: Vec3, to: Vec3)? {
        guard !a.points.isEmpty, !b.points.isEmpty else { return nil }
        var best: (Double, Vec3, Vec3)?
        func consider(_ p: Vec3, _ q: Vec3) { let d = (p - q).length; if d < (best?.0 ?? .infinity) { best = (d, p, q) } }
        let segsA = a.segments + a.triangles.flatMap { [($0.0, $0.1), ($0.1, $0.2), ($0.2, $0.0)] }
        let segsB = b.segments + b.triangles.flatMap { [($0.0, $0.1), ($0.1, $0.2), ($0.2, $0.0)] }
        // Very large faces (imported meshes): not measured, rather than stalling the window.
        guard segsA.count * segsB.count + a.points.count * b.triangles.count + b.points.count * a.triangles.count <= 4_000_000 else { return nil }
        // Edges against edges, and every vertex against the other side's triangles.
        for s in segsA { for t in segsB { let (p, q) = closest(s, t); consider(p, q) } }
        for p in a.points { for t in b.triangles { consider(p, closest(p, t)) } }
        for q in b.points { for t in a.triangles { consider(closest(q, t), q) } }
        // Crossing faces touch.
        return best.map { ($0.0, $0.1, $0.2) }
    }

    static func closest(_ p: Vec3, _ t: (Vec3, Vec3, Vec3)) -> Vec3 {
        // Ericson, Real-Time Collision Detection 5.1.5.
        let (a, b, c) = t
        let ab = b - a, ac = c - a, ap = p - a
        let d1 = ab.dot(ap), d2 = ac.dot(ap)
        if d1 <= 0, d2 <= 0 { return a }
        let bp = p - b, d3 = ab.dot(bp), d4 = ac.dot(bp)
        if d3 >= 0, d4 <= d3 { return b }
        let vc = d1 * d4 - d3 * d2
        if vc <= 0, d1 >= 0, d3 <= 0 { return a + ab * (d1 / (d1 - d3)) }
        let cp = p - c, d5 = ab.dot(cp), d6 = ac.dot(cp)
        if d6 >= 0, d5 <= d6 { return c }
        let vb = d5 * d2 - d1 * d6
        if vb <= 0, d2 >= 0, d6 <= 0 { return a + ac * (d2 / (d2 - d6)) }
        let va = d3 * d6 - d5 * d4
        if va <= 0, d4 - d3 >= 0, d5 - d6 >= 0 { return b + (c - b) * ((d4 - d3) / ((d4 - d3) + (d5 - d6))) }
        let denom = 1 / (va + vb + vc)
        return a + ab * (vb * denom) + ac * (vc * denom)
    }

    static func closest(_ s: (Vec3, Vec3), _ t: (Vec3, Vec3)) -> (Vec3, Vec3) {
        let d1 = s.1 - s.0, d2 = t.1 - t.0, r = s.0 - t.0
        let a = d1.dot(d1), e = d2.dot(d2), f = d2.dot(r)
        var sP = 0.0, tP = 0.0
        if a < 1e-18, e < 1e-18 { return (s.0, t.0) }
        if a < 1e-18 { tP = max(0, min(1, f / e)) } else {
            let c = d1.dot(r)
            if e < 1e-18 { sP = max(0, min(1, -c / a)) } else {
                let b = d1.dot(d2), den = a * e - b * b
                sP = den > 1e-18 ? max(0, min(1, (b * f - c * e) / den)) : 0
                tP = (b * sP + f) / e
                if tP < 0 { tP = 0; sP = max(0, min(1, -c / a)) } else if tP > 1 { tP = 1; sP = max(0, min(1, (b - c) / a)) }
            }
        }
        return (s.0 + d1 * sP, t.0 + d2 * tP)
    }
}
