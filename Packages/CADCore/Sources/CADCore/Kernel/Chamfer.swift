import Foundation

// Chamfer (phase 3c, T85): bevels selected convex edges by subtracting a small tool solid.
// Straight edges between two planar faces use a prism; circular edges between a plane and a
// cylinder (top of a boss, mouth of a hole) use a ring of revolution.

/// A reference to an edge that survives re-evaluation: the two faces it separates (their IDs
/// are stable through the history) and a point near it, used when those faces meet more than once.
public struct EdgeRef: Codable, Sendable, Equatable, Hashable {
    /// Sorted by raw value, always two.
    public var faces: [FaceID]
    public var point: Vec3

    public init(faces: [FaceID], point: Vec3) {
        self.faces = faces.sorted { $0.rawValue < $1.rawValue }
        self.point = point
    }

    /// Reference to an edge of the current geometry (its midpoint as the hint).
    public init?(_ edge: EdgeInfo) {
        guard edge.faces.count == 2, Set(edge.faces).count == 2, let first = edge.polyline.first else { return nil }
        var half = edge.length / 2, mid = first
        for (a, b) in zip(edge.polyline, edge.polyline.dropFirst()) {
            let l = (b - a).length
            if l >= half, l > 0 { mid = a + (b - a) * (half / l); break }
            half -= l; mid = b
        }
        self.init(faces: edge.faces, point: mid)
    }
}

public struct ChamferSpec: Codable, Sendable, Equatable {
    public enum Mode: String, Codable, Sendable, CaseIterable {
        case equalDistance, twoDistances, distanceAngle

        public var label: String {
            switch self {
            case .equalDistance: "Distanza uguale"
            case .twoDistances: "Due distanze"
            case .distanceAngle: "Distanza e angolo"
            }
        }
    }

    public var edges: [EdgeRef]
    public var mode: Mode
    /// On the first face of each edge (all modes).
    public var distance: Double
    /// On the second face (two distances).
    public var distance2: Double
    /// Degrees, between the chamfer and the first face (distance and angle).
    public var angle: Double
    /// Swaps first and second face.
    public var flip: Bool

    public init(edges: [EdgeRef], mode: Mode = .equalDistance, distance: Double = 1, distance2: Double = 1,
                angle: Double = 45, flip: Bool = false) {
        self.edges = edges; self.mode = mode; self.distance = distance; self.distance2 = distance2
        self.angle = angle; self.flip = flip
    }

    public var summary: String {
        let size: String
        switch mode {
        case .equalDistance: size = "\(fmt(distance)) mm"
        case .twoDistances: size = "\(fmt(distance))×\(fmt(distance2)) mm"
        case .distanceAngle: size = "\(fmt(distance)) mm \(fmt(angle))°"
        }
        return edges.count == 1 ? size : "\(size) ×\(edges.count)"
    }

    public func validate() throws {
        guard (1...500).contains(edges.count) else { throw KernelError.invalidParameter("smusso: da 1 a 500 spigoli") }
        guard edges.allSatisfy({ $0.faces.count == 2 && $0.faces[0] != $0.faces[1] }) else {
            throw KernelError.invalidParameter("smusso: riferimento spigolo non valido")
        }
        guard Set(edges).count == edges.count else { throw KernelError.invalidParameter("smusso: spigolo ripetuto") }
        guard distance.isFinite, (0.01...1000).contains(distance) else { throw KernelError.invalidParameter("smusso: distanza 0,01–1000 mm") }
        if mode == .twoDistances {
            guard distance2.isFinite, (0.01...1000).contains(distance2) else { throw KernelError.invalidParameter("smusso: seconda distanza 0,01–1000 mm") }
        }
        if mode == .distanceAngle {
            guard angle.isFinite, (1...89).contains(angle) else { throw KernelError.invalidParameter("smusso: angolo 1–89°") }
        }
    }

    /// Setbacks on the first and second face for an edge whose faces meet at `dihedral` radians
    /// (interior angle of the material, π/2 for a box edge).
    func distances(dihedral: Double) throws -> (Double, Double) {
        switch mode {
        case .equalDistance: return (distance, distance)
        case .twoDistances: return (distance, distance2)
        case .distanceAngle:
            // Triangle edge–A–B: angle `dihedral` at the edge, `angle` at the point on face A.
            let theta = angle * .pi / 180, rest = .pi - dihedral - theta
            guard rest > 0.02 else { throw KernelError.invalidParameter("smusso: angolo troppo grande per questo spigolo") }
            return (distance, distance * sin(theta) / sin(rest))
        }
    }

    private func fmt(_ v: Double) -> String { String(format: v == v.rounded() ? "%.0f" : "%.2f", v) }
}

public enum ChamferGeometry {
    /// Margin the tool extends beyond the part (no coplanar faces with the body).
    static let lead = 0.5
    static let segments = 64

    /// The edge of `snapshot` a reference points to: same two faces, nearest to the hint.
    public static func resolve(_ ref: EdgeRef, in snapshot: BodySnapshot) -> EdgeInfo? {
        let want = Set(ref.faces)
        return snapshot.edges.filter { Set($0.faces) == want }
            .min { distance(ref.point, $0.polyline) < distance(ref.point, $1.polyline) }
    }

    /// Solid removed by chamfering `edge` of the body described by `snapshot`.
    public static func tool(for edge: EdgeInfo, ref: EdgeRef, spec: ChamferSpec, snapshot: BodySnapshot,
                            featureID: UUID, index: Int) throws -> CSGSolid {
        let order = spec.flip ? [ref.faces[1], ref.faces[0]] : ref.faces
        guard let fa = snapshot.faces.firstIndex(where: { $0.id == order[0] }),
              let fb = snapshot.faces.firstIndex(where: { $0.id == order[1] }) else {
            throw KernelError.invalidTopology("smusso: facce dello spigolo non trovate")
        }
        let prefix = "chamfer:\(featureID.uuidString)/\(index)"
        switch (snapshot.faces[fa].surface, snapshot.faces[fb].surface) {
        case let (.plane(oa, na), .plane(ob, nb)):
            return try straight(edge, a: (fa, oa, na), b: (fb, ob, nb), spec: spec, snapshot: snapshot, prefix: prefix)
        case let (.plane(o, n), .cylinder(ax, dir, r)):
            return try circular(edge, plane: (o, n), cylinder: (fb, ax, dir, r), planeFirst: true, spec: spec, snapshot: snapshot, prefix: prefix)
        case let (.cylinder(ax, dir, r), .plane(o, n)):
            return try circular(edge, plane: (o, n), cylinder: (fa, ax, dir, r), planeFirst: false, spec: spec, snapshot: snapshot, prefix: prefix)
        default:
            throw KernelError.invalidParameter("smusso: supportati spigoli tra facce piane e bordi circolari di cilindri e fori")
        }
    }

    // MARK: Straight edge between two planes

    private static func straight(_ edge: EdgeInfo, a: (Int, Vec3, Vec3), b: (Int, Vec3, Vec3),
                                 spec: ChamferSpec, snapshot: BodySnapshot, prefix: String) throws -> CSGSolid {
        let pts = edge.polyline
        guard let e0 = pts.first, let e1 = pts.last, (e1 - e0).length > 1e-6 else {
            throw KernelError.invalidParameter("smusso: spigolo troppo corto")
        }
        let dir = (e1 - e0).normalized
        for p in pts {
            let d = p - e0
            guard (d - dir * d.dot(dir)).length < 1e-4 else { throw KernelError.invalidParameter("smusso: spigolo non rettilineo") }
        }
        let (na, nb) = (a.2, b.2)
        // In-face directions away from the edge, from the face's own triangles.
        guard let ta = inFaceDirection(face: a.0, edgeStart: e0, dir: dir, normal: na, snapshot: snapshot),
              let tb = inFaceDirection(face: b.0, edgeStart: e0, dir: dir, normal: nb, snapshot: snapshot) else {
            throw KernelError.invalidTopology("smusso: facce dello spigolo non trovate")
        }
        guard ta.dot(nb) < -1e-6, tb.dot(na) < -1e-6 else {
            throw KernelError.invalidParameter("smusso su spigolo concavo non ancora disponibile")
        }
        let dihedral = acos(max(-1, min(1, ta.dot(tb))))
        let (d1, d2) = try spec.distances(dihedral: dihedral)

        // Cross-section (relative to a point of the edge): parallelogram whose base is the chamfer
        // line, extended past both faces, pushed outward so it contains the corner.
        let qa = ta * d1, qb = tb * d2
        let u = (qb - qa).normalized
        let perp = qa - u * qa.dot(u)
        let depth = perp.length
        let nline = -perp.normalized
        let out = (na + nb).normalized
        let e = max(d1, d2) + lead
        let h = 2 * depth / max(out.dot(nline), 0.1) + lead
        let section = [qa - u * e, qb + u * e, qb + u * e + out * h, qa - u * e + out * h]

        // Ends: past a free end the tool overshoots; where the material continues (the edge
        // runs into a wall) it stops on that wall's plane.
        let probe = (qa + qb) * 0.25
        func cap(_ p: Vec3, outward w: Vec3) -> [Vec3] {
            let delta = min(0.05, 0.1 * min(d1, d2))
            if !contains(p + w * delta + probe, snapshot) {
                return section.map { p + $0 + w * e }
            }
            let wall = snapshot.faces.enumerated().compactMap { i, f -> (Vec3, Vec3)? in
                guard i != a.0, i != b.0, case let .plane(o, n) = f.surface, abs((p - o).dot(n)) < 1e-5,
                      abs(n.dot(dir)) > 0.2 else { return nil }
                return (o, n)
            }.max { abs($0.1.dot(dir)) < abs($1.1.dot(dir)) }
            guard let (o, n) = wall else { return section.map { p + $0 } }
            return section.map { v in
                let q = p + v
                return q + dir * ((o - q).dot(n) / dir.dot(n))
            }
        }
        let s0 = cap(e0, outward: -dir), s1 = cap(e1, outward: dir)

        var faces = [CSGFace(id: FaceID(rawValue: prefix), surface: .plane(origin: e0 + qa, normal: nline), flipped: true)]
        var polys: [CSGSolid.Polygon] = []
        func auxFace(_ v: [Vec3]) -> Int {
            let n = (v[1] - v[0]).cross(v[2] - v[0]).normalized
            faces.append(CSGFace(id: FaceID(rawValue: prefix + "/aux\(faces.count)"), surface: .plane(origin: v[0], normal: n), flipped: false))
            return faces.count - 1
        }
        for i in 0..<4 {
            let j = (i + 1) % 4
            let quad = [s0[i], s0[j], s1[j], s1[i]]
            polys.append(CSGSolid.Polygon(vertices: quad, face: i == 0 ? 0 : auxFace(quad)))
        }
        let c0 = Array(s0.reversed()), c1 = s1
        polys.append(CSGSolid.Polygon(vertices: c0, face: auxFace(c0)))
        polys.append(CSGSolid.Polygon(vertices: c1, face: auxFace(c1)))
        return oriented(polys, faces)
    }

    /// Unit vector in the face plane, perpendicular to the edge, pointing into the face.
    private static func inFaceDirection(face: Int, edgeStart e0: Vec3, dir: Vec3, normal: Vec3, snapshot: BodySnapshot) -> Vec3? {
        let candidate = normal.cross(dir).normalized
        var side = 0.0
        for t in 0..<snapshot.triangleFace.count where Int(snapshot.triangleFace[t]) == face {
            let v = (0..<3).map { snapshot.positions[Int(snapshot.triangles[t * 3 + $0])] }
            let touches = v.contains { p in let d = p - e0; return (d - dir * d.dot(dir)).length < 1e-5 }
            guard touches else { continue }
            let c = (v[0] + v[1] + v[2]) * (1.0 / 3)
            side += (c - e0).dot(candidate)
        }
        guard abs(side) > 1e-12 else { return nil }
        return side > 0 ? candidate : -candidate
    }

    // MARK: Circular edge between a plane and a cylinder

    private static func circular(_ edge: EdgeInfo, plane: (Vec3, Vec3), cylinder: (Int, Vec3, Vec3, Double), planeFirst: Bool,
                                 spec: ChamferSpec, snapshot: BodySnapshot, prefix: String) throws -> CSGSolid {
        let (po, a) = plane
        let (fc, axisOrigin, axisDir, radius) = cylinder
        guard abs(axisDir.normalized.dot(a)) > 0.999 else {
            throw KernelError.invalidParameter("smusso: cilindro non perpendicolare alla faccia")
        }
        guard let first = edge.polyline.first, let last = edge.polyline.last, (first - last).length < 1e-4 else {
            throw KernelError.invalidParameter("smusso: bordo circolare non chiuso (arco) non ancora disponibile")
        }
        let axis = axisDir.normalized
        let centre = axisOrigin + axis * (po - axisOrigin).dot(axis)
        // Boss (material inside the cylinder) or hole (material outside)?
        var boss: Bool?
        for t in 0..<snapshot.triangleFace.count where Int(snapshot.triangleFace[t]) == fc {
            let i = Int(snapshot.triangles[t * 3]), p = snapshot.positions[i]
            let d = p - axisOrigin
            let radial = d - axis * d.dot(axis)
            boss = snapshot.normals[i].dot(radial) > 0
            break
        }
        guard let boss else { throw KernelError.invalidTopology("smusso: faccia cilindrica non trovata") }
        let (first1, second) = try spec.distances(dihedral: .pi / 2)
        let dp = planeFirst ? first1 : second, dc = planeFirst ? second : first1
        let k = dp / dc
        let helper = abs(a.z) < 0.9 ? Vec3(0, 0, 1) : Vec3(1, 0, 0)
        let u = helper.cross(a).normalized, v = a.cross(u)

        // Profile in (radius, height above the face); the chamfer line is one of its edges.
        let profile: [(Double, Double)]
        let chamferEdge: Int
        let surface: SurfaceDescriptor
        let toolFlipped: Bool
        if boss {
            guard dp < radius * 0.98 else { throw KernelError.invalidParameter("smusso più grande del raggio del cilindro") }
            let l1 = min(lead, 0.45 * (radius - dp) / k), l2 = min(lead, 0.25 / k)
            profile = [(radius - dp - l1 * k, l1), (radius + lead, l1), (radius + lead, -dc - l2), (radius + l2 * k, -dc - l2)]
            chamferEdge = 3
            surface = .cone(apex: centre + a * ((radius - dp) / k), axisDirection: -a, halfAngle: atan(k))
            toolFlipped = true
        } else {
            let l2 = min(lead, 0.5 * radius / k)
            profile = [(0, lead), (radius + dp + lead * k, lead), (radius - l2 * k, -dc - l2), (0, -dc - l2)]
            chamferEdge = 1
            surface = .cone(apex: centre - a * ((radius + dp) / k), axisDirection: a, halfAngle: atan(k))
            toolFlipped = false
        }

        var faces: [CSGFace] = []
        var polys: [CSGSolid.Polygon] = []
        func point(_ p: (Double, Double), _ step: Int) -> Vec3 {
            let t = Double(step) / Double(segments) * 2 * .pi
            return centre + a * p.1 + (u * cos(t) + v * sin(t)) * p.0
        }
        for i in profile.indices {
            let p = profile[i], q = profile[(i + 1) % profile.count]
            if p.0 == 0, q.0 == 0 { continue }
            let face: Int
            if i == chamferEdge {
                faces.append(CSGFace(id: FaceID(rawValue: prefix), surface: surface, flipped: toolFlipped))
            } else {
                faces.append(CSGFace(id: FaceID(rawValue: prefix + "/aux\(i)"), surface: .plane(origin: point(p, 0), normal: a), flipped: false))
            }
            face = faces.count - 1
            for s in 0..<segments {
                var quad = [point(p, s), point(p, s + 1), point(q, s + 1), point(q, s)]
                if p.0 == 0 { quad.remove(at: 1) } else if q.0 == 0 { quad.remove(at: 2) }
                guard (quad[1] - quad[0]).cross(quad[2] - quad[0]).length > 1e-12 else { continue }
                polys.append(CSGSolid.Polygon(vertices: quad, face: face))
            }
        }
        return oriented(polys, faces)
    }

    // MARK: Helpers

    /// Makes the polygons face outward (positive volume).
    private static func oriented(_ polys: [CSGSolid.Polygon], _ faces: [CSGFace]) -> CSGSolid {
        var volume = 0.0
        let o = polys.first?.vertices.first ?? .zero
        for p in polys {
            for k in 1..<(p.vertices.count - 1) {
                volume += (p.vertices[0] - o).dot((p.vertices[k] - o).cross(p.vertices[k + 1] - o))
            }
        }
        let out = volume >= 0 ? polys : polys.map { $0.flipped(faceMap: { $0 }) }
        return CSGSolid(polygons: out, faces: faces)
    }

    /// Point inside the closed triangle mesh of a snapshot (ray parity).
    static func contains(_ p: Vec3, _ s: BodySnapshot) -> Bool {
        let d = Vec3(0.5773, 0.5774, 0.5775).normalized
        var hits = 0
        for t in 0..<(s.triangles.count / 3) {
            let a = s.positions[Int(s.triangles[t * 3])], b = s.positions[Int(s.triangles[t * 3 + 1])], c = s.positions[Int(s.triangles[t * 3 + 2])]
            let e1 = b - a, e2 = c - a, q = d.cross(e2), det = e1.dot(q)
            guard abs(det) > 1e-14 else { continue }
            let f = 1 / det, w = p - a, uu = w.dot(q) * f
            guard uu >= 0, uu <= 1 else { continue }
            let r = w.cross(e1), vv = d.dot(r) * f
            guard vv >= 0, uu + vv <= 1 else { continue }
            if e2.dot(r) * f > 1e-9 { hits += 1 }
        }
        return hits % 2 == 1
    }

    private static func distance(_ p: Vec3, _ polyline: [Vec3]) -> Double {
        guard polyline.count > 1 else { return polyline.first.map { ($0 - p).length } ?? .infinity }
        return zip(polyline, polyline.dropFirst()).map { a, b in
            let d = b - a, l2 = d.dot(d)
            let t = l2 > 0 ? max(0, min(1, (p - a).dot(d) / l2)) : 0
            return (a + d * t - p).length
        }.min()!
    }
}
