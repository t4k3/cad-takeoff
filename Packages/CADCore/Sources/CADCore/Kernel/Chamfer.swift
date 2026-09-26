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
        guard edge.faces.count == 2, Set(edge.faces).count == 2, let mid = edge.midpoint else { return nil }
        self.init(faces: edge.faces, point: mid)
    }
}

extension EdgeInfo {
    /// Point halfway along the polyline.
    public var midpoint: Vec3? {
        guard var mid = polyline.first else { return nil }
        var half = length / 2
        for (a, b) in zip(polyline, polyline.dropFirst()) {
            let l = (b - a).length
            if l >= half, l > 0 { return a + (b - a) * (half / l) }
            half -= l; mid = b
        }
        return mid
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

    /// Flat bevel (chamfer) or round (constant-radius fillet, like Fusion's Fillet).
    public enum Profile: String, Codable, Sendable, CaseIterable {
        case flat, round

        public var label: String {
            switch self {
            case .flat: "Piatto (smusso)"
            case .round: "Tondo (raccordo)"
            }
        }
    }

    public var edges: [EdgeRef]
    public var profile: Profile
    /// Flat only; a round profile always uses `distance` as its radius.
    public var mode: Mode
    /// On the first face of each edge (all modes).
    public var distance: Double
    /// On the second face (two distances).
    public var distance2: Double
    /// Degrees, between the chamfer and the first face (distance and angle).
    public var angle: Double
    /// Swaps first and second face.
    public var flip: Bool

    public init(edges: [EdgeRef], profile: Profile = .flat, mode: Mode = .equalDistance, distance: Double = 1,
                distance2: Double = 1, angle: Double = 45, flip: Bool = false) {
        self.edges = edges; self.profile = profile; self.mode = mode; self.distance = distance; self.distance2 = distance2
        self.angle = angle; self.flip = flip
    }

    private enum CodingKeys: String, CodingKey { case edges, profile, mode, distance, distance2, angle, flip }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        edges = try c.decode([EdgeRef].self, forKey: .edges)
        profile = try c.decodeIfPresent(Profile.self, forKey: .profile) ?? .flat
        mode = try c.decode(Mode.self, forKey: .mode)
        distance = try c.decode(Double.self, forKey: .distance)
        distance2 = try c.decode(Double.self, forKey: .distance2)
        angle = try c.decode(Double.self, forKey: .angle)
        flip = try c.decode(Bool.self, forKey: .flip)
    }

    /// "Smusso 1 mm" / "Raccordo R2 mm" (+ edge count): automatic feature name.
    public var title: String { (profile == .round ? "Raccordo " : "Smusso ") + summary }

    public var summary: String {
        let size: String
        switch profile == .round ? nil : mode {
        case nil: size = "R\(fmt(distance)) mm"
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
        if profile == .flat, mode == .twoDistances {
            guard distance2.isFinite, (0.01...1000).contains(distance2) else { throw KernelError.invalidParameter("smusso: seconda distanza 0,01–1000 mm") }
        }
        if profile == .flat, mode == .distanceAngle {
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

    /// Up to two decimals, no trailing zeros (4.5, 0.25, 3).
    private func fmt(_ v: Double) -> String {
        var t = String(format: "%.2f", v)
        while t.hasSuffix("0") { t.removeLast() }
        if t.hasSuffix(".") { t.removeLast() }
        return t
    }
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

    /// Tool of a chamfer/round on `edge`: removed from the body on a convex edge, added to it
    /// (`adds`) on a concave one (inside corner: the round fills it).
    public static func tool(for edge: EdgeInfo, ref: EdgeRef, spec: ChamferSpec, snapshot: BodySnapshot,
                            featureID: UUID, index: Int) throws -> (solid: CSGSolid, adds: Bool) {
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
            // Circular edges where a bevel's cone meets a plane, a wall or another cone (rounds on
            // rounds): the same corner profile turned around their common axis.
            if let tool = try revolved(edge, a: fa, b: fb, spec: spec, snapshot: snapshot, prefix: prefix) { return tool }
            throw KernelError.invalidParameter("smusso: supportati spigoli tra facce piane, cilindri e coni con lo stesso asse")
        }
    }

    /// Drag handle of a chamfer/round on `edge`: the edge midpoint, the direction into the
    /// material (bisector of the two faces) and how far along it the bevel's middle sits per mm
    /// of distance/radius (`flat`, `round`). Nil when the faces cannot be found.
    /// `limit`: the largest size the two faces can take (their width away from the edge).
    public static func handle(for edge: EdgeInfo, in snapshot: BodySnapshot)
        -> (origin: Vec3, inward: Vec3, flat: Double, round: Double, limit: Double)? {
        guard let mid = edge.midpoint, edge.faces.count == 2 else { return nil }
        var normals: [Vec3] = [], centroids: [Vec3] = []
        var limit = Double.infinity
        for id in edge.faces {
            guard let f = snapshot.faces.firstIndex(where: { $0.id == id }) else { return nil }
            limit = min(limit, extent(ofFace: f, from: edge.polyline, snapshot))
            var best: (Double, Vec3, Vec3)?
            for t in 0..<snapshot.triangleFace.count where Int(snapshot.triangleFace[t]) == f {
                let v = (0..<3).map { snapshot.positions[Int(snapshot.triangles[t * 3 + $0])] }
                let c = (v[0] + v[1] + v[2]) * (1.0 / 3)
                let d = (c - mid).length
                if d < (best?.0 ?? .infinity) { best = (d, (v[1] - v[0]).cross(v[2] - v[0]).normalized, c) }
            }
            guard let (_, n, c) = best else { return nil }
            normals.append(n); centroids.append(c)
        }
        let sum = normals[0] + normals[1]
        guard sum.length > 1e-6 else { return nil }
        let dihedral = .pi - acos(max(-1, min(1, normals[0].dot(normals[1]))))
        let half = max(dihedral / 2, 0.05)
        // Inside corner: the fill grows out into the air, so the handle moves that way.
        let concave = (centroids[0] - mid).dot(normals[1]) > 1e-9
        return (mid, sum.normalized * (concave ? 1 : -1), cos(half), 1 / sin(half) - 1, limit)
    }

    /// Whether a bevel or round on the edge would be too thin to see: the faces turn so little that
    /// it stays within 0.01 mm of them (a 2.7° crease with a 3 mm round: 0.001 mm). Such tools are
    /// slivers that only break the booleans where rounds meet, so they are skipped.
    public static func isNearlyFlat(_ edge: EdgeInfo, in snapshot: BodySnapshot, spec: ChamferSpec) -> Bool {
        guard let mid = edge.midpoint, edge.faces.count == 2 else { return false }
        var normals: [Vec3] = []
        for id in edge.faces {
            guard let f = snapshot.faces.firstIndex(where: { $0.id == id }) else { return false }
            var best: (Double, Vec3)?
            for t in 0..<snapshot.triangleFace.count where Int(snapshot.triangleFace[t]) == f {
                let v = (0..<3).map { snapshot.positions[Int(snapshot.triangles[t * 3 + $0])] }
                let c = (v[0] + v[1] + v[2]) * (1.0 / 3)
                let d = (c - mid).length
                if d < (best?.0 ?? .infinity) { best = (d, (v[1] - v[0]).cross(v[2] - v[0]).normalized) }
            }
            guard let (_, n) = best else { return false }
            normals.append(n)
        }
        let turn = acos(max(-1, min(1, normals[0].dot(normals[1]))))
        if turn < 0.5 * .pi / 180 { return true }
        let sag = spec.profile == .round ? spec.distance * (1 / cos(turn / 2) - 1) : spec.distance * sin(turn / 2)
        return sag < 0.01
    }

    /// How far a face reaches from an edge (farthest vertex): no bevel can be wider.
    static func extent(ofFace f: Int, from polyline: [Vec3], _ s: BodySnapshot) -> Double {
        // Vertices alone are not enough: a disc merged into a fan has all of them on its rim.
        // Edge midpoints and centres reach inside (the chord across a disc passes its centre).
        var best = 0.0
        for t in 0..<s.triangleFace.count where Int(s.triangleFace[t]) == f {
            let v = (0..<3).map { s.positions[Int(s.triangles[t * 3 + $0])] }
            for p in v + [(v[0] + v[1]) * 0.5, (v[1] + v[2]) * 0.5, (v[2] + v[0]) * 0.5, (v[0] + v[1] + v[2]) * (1.0 / 3)] {
                best = max(best, distance(p, polyline))
            }
        }
        return best
    }

    private static func tooBig(_ spec: ChamferSpec, max: Double) -> KernelError {
        let what = spec.profile == .round ? "raccordo" : "smusso"
        return KernelError.invalidParameter("\(what) troppo grande per questo spigolo (massimo \(String(format: "%.1f", max)) mm)")
    }

    // MARK: Straight edge between two planes

    private static func straight(_ edge: EdgeInfo, a: (Int, Vec3, Vec3), b: (Int, Vec3, Vec3),
                                 spec: ChamferSpec, snapshot: BodySnapshot, prefix: String) throws -> (solid: CSGSolid, adds: Bool) {
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
        // Convex: each face runs away from the other's outside. Concave (inside corner): towards it;
        // then the air wedge lies between the faces and the tool fills its corner.
        let convex = ta.dot(nb) < -1e-6 && tb.dot(na) < -1e-6
        let concave = ta.dot(nb) > 1e-6 && tb.dot(na) > 1e-6
        guard convex || concave else { throw KernelError.invalidParameter("smusso: spigolo tangente o degenere") }
        let dihedral = acos(max(-1, min(1, ta.dot(tb))))
        // Direction from the edge into the material (concave) or the air (convex) side of the tool.
        let out = (na + nb).normalized * (concave ? -1.0 : 1.0)
        let sign = concave ? -1.0 : 1.0
        let widthA = extent(ofFace: a.0, from: pts, snapshot), widthB = extent(ofFace: b.0, from: pts, snapshot)

        // Cross-section, relative to a point of the edge (the corner), star-shaped around the
        // corner. `special` = its sides that become the bevel/round surface.
        let section: [Vec3], special: Set<Int>, surface: SurfaceDescriptor
        let probe: Vec3, reach: Double
        if spec.profile == .round {
            // Arc of radius r tangent to both faces; the tool is the corner outside the arc.
            let r = spec.distance
            let half = dihedral / 2
            let x = r / tan(half), centreDistance = r / sin(half)
            guard x <= min(widthA, widthB) + 1e-6 else { throw tooBig(spec, max: min(widthA, widthB) * tan(half)) }
            let w = (ta + tb).normalized
            let c = w * centreDistance
            let from = ta * x - c, to = tb * x - c
            let theta = acos(max(-1, min(1, from.dot(to) / (r * r))))
            let n = max(3, Int((theta / (2 * .pi) * Double(segments) - 1e-9).rounded(.up)))
            let arc = (0...n).map { i -> Vec3 in
                let t = Double(i) / Double(n)
                return c + (from * sin((1 - t) * theta) + to * sin(t * theta)) * (1 / sin(theta))
            }
            if concave {
                // Fill: just past the faces into the material (thin walls stay untouched outside).
                let ov = min(0.2, 0.25 * r)
                section = arc + [tb * x - nb * ov, (na + nb) * (-ov), ta * x - na * ov]
            } else {
                let m = r + lead
                section = arc + [tb * x + nb * (sign * m), out * (2 * m + centreDistance), ta * x + na * (sign * m)]
            }
            special = Set(0..<n)
            surface = .cylinder(axisOrigin: e0 + c, axisDirection: dir, radius: r)
            probe = w * (centreDistance - r) * 0.5
            reach = x + lead
        } else {
            // Parallelogram whose base is the chamfer line, extended past both faces and pushed
            // outward so it contains the corner.
            let (d1, d2) = try spec.distances(dihedral: dihedral)
            guard d1 <= widthA + 1e-6, d2 <= widthB + 1e-6 else { throw tooBig(spec, max: min(widthA, widthB)) }
            let qa = ta * d1, qb = tb * d2
            let u = (qb - qa).normalized
            let perp = qa - u * qa.dot(u)
            let nline = -perp.normalized
            let e = max(d1, d2) + lead
            if concave {
                // Fill the triangle corner–QA–QB, reaching just past the faces into the material.
                let ov = min(0.2, 0.25 * min(d1, d2))
                section = [qa, qb, qb - nb * ov, (na + nb) * (-ov), qa - na * ov]
            } else {
                let h = 2 * perp.length / max(out.dot(nline), 0.1) + lead
                section = [qa - u * e, qb + u * e, qb + u * e + out * h, qa - u * e + out * h]
            }
            special = [0]
            // Outward normal of the bevel in the result (faces the air).
            surface = .plane(origin: e0 + qa, normal: concave ? -nline : nline)
            probe = (qa + qb) * 0.25
            reach = e
        }

        // Ends: past a free end the tool overshoots; where the material continues (the edge
        // runs into a wall) it stops on that wall's plane.
        func cap(_ p: Vec3, outward w: Vec3) -> (centre: Vec3, ring: [Vec3]) {
            let delta = min(0.05, 0.25 * probe.length)
            // Filling an inside corner must never add material past the part: always stop at the end.
            if convex, !contains(p + w * delta + probe, snapshot) {
                return (p + w * reach, section.map { p + $0 + w * reach })
            }
            let wall = snapshot.faces.enumerated().compactMap { i, f -> (Vec3, Vec3)? in
                guard i != a.0, i != b.0, case let .plane(o, n) = f.surface, abs((p - o).dot(n)) < 1e-5,
                      abs(n.dot(dir)) > 0.9 else { return nil }
                return (o, n)
            }.max { abs($0.1.dot(dir)) < abs($1.1.dot(dir)) }
            guard let (o, n) = wall else { return (p, section.map { p + $0 }) }
            func onWall(_ q: Vec3) -> Vec3 { q + dir * ((o - q).dot(n) / dir.dot(n)) }
            return (onWall(p), section.map { onWall(p + $0) })
        }
        let (c0, s0) = cap(e0, outward: -dir), (c1, s1) = cap(e1, outward: dir)

        // Subtracted tools have their faces flipped by the boolean; added ones keep them. The round
        // surface of a concave corner faces its axis (flipped either way).
        let flipped = spec.profile == .round ? true : convex
        var faces = [CSGFace(id: FaceID(rawValue: prefix), surface: surface, flipped: flipped)]
        var polys: [CSGSolid.Polygon] = []
        func auxFace(_ v: [Vec3]) -> Int {
            let n = (v[1] - v[0]).cross(v[2] - v[0]).normalized
            faces.append(CSGFace(id: FaceID(rawValue: prefix + "/aux\(faces.count)"), surface: .plane(origin: v[0], normal: n), flipped: false))
            return faces.count - 1
        }
        let count = section.count
        for i in 0..<count {
            let j = (i + 1) % count
            let quad = [s0[i], s0[j], s1[j], s1[i]]
            polys.append(CSGSolid.Polygon(vertices: quad, face: special.contains(i) ? 0 : auxFace(quad)))
        }
        // End caps: fans around the corner point (the section is star-shaped around it).
        let cap0 = auxFace([c0, s0[1], s0[0]]), cap1 = auxFace([c1, s1[0], s1[1]])
        for i in 0..<count {
            let j = (i + 1) % count
            for (tri, face) in [([c0, s0[j], s0[i]], cap0), ([c1, s1[i], s1[j]], cap1)]
            where (tri[1] - tri[0]).cross(tri[2] - tri[0]).length > 1e-12 {
                polys.append(CSGSolid.Polygon(vertices: tri, face: face))
            }
        }
        return (oriented(polys, faces), concave)
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
                                 spec: ChamferSpec, snapshot: BodySnapshot, prefix: String) throws -> (solid: CSGSolid, adds: Bool) {
        let (po, a) = plane
        let (fc, axisOrigin, axisDir, radius) = cylinder
        guard abs(axisDir.normalized.dot(a)) > 0.999 else {
            throw KernelError.invalidParameter("smusso: cilindro non perpendicolare alla faccia")
        }
        guard let first = edge.polyline.first, let last = edge.polyline.last, edge.polyline.count >= 2 else {
            throw KernelError.invalidParameter("smusso: bordo circolare vuoto")
        }
        let closed = (first - last).length < 1e-4
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
        // Concave when the wall rises from the face (root of a boss, floor of a blind hole).
        var rise = 0.0, count = 0.0
        for t in 0..<snapshot.triangleFace.count where Int(snapshot.triangleFace[t]) == fc {
            for k in 0..<3 { rise += (snapshot.positions[Int(snapshot.triangles[t * 3 + k])] - centre).dot(a); count += 1 }
        }
        let concave = count > 0 && rise / count > 1e-6
        // Along the wall a bevel cannot go past the cylinder's height.
        let wall = extent(ofFace: fc, from: edge.polyline, snapshot)
        let alongWall = spec.profile == .round ? spec.distance : (planeFirst ? try spec.distances(dihedral: .pi / 2).1 : spec.distance)
        guard alongWall <= wall + 1e-6 else { throw tooBig(spec, max: wall) }
        let helper = abs(a.z) < 0.9 ? Vec3(0, 0, 1) : Vec3(1, 0, 0)
        let u = helper.cross(a).normalized, v = a.cross(u)
        // Angular range swept: the whole turn for a rim, the arc's own span for part of one
        // (slot ends, rounded corners), going the way the edge runs through its middle.
        var t0 = 0.0, span = 2 * Double.pi
        if !closed {
            func angle(_ p: Vec3) -> Double { let d = p - centre; return atan2(d.dot(v), d.dot(u)) }
            func wrapped(_ x: Double) -> Double { let m = x.truncatingRemainder(dividingBy: 2 * .pi); return m < 0 ? m + 2 * .pi : m }
            let a0 = angle(first), a1 = angle(last), am = angle(edge.polyline[edge.polyline.count / 2])
            let ccw = wrapped(a1 - a0)
            if wrapped(am - a0) < ccw { t0 = a0; span = ccw } else { t0 = a1; span = 2 * .pi - ccw }
        }
        let steps = closed ? segments : max(1, Int((span / (2 * .pi / Double(segments))).rounded(.up)))

        // Profile in (radius, height above the face); `special` = its sides that become the
        // bevel (cone) or round (torus) surface.
        var profile: [(Double, Double)]
        let special: Set<Int>
        let surface: SurfaceDescriptor
        let toolFlipped: Bool
        // Overlap of an added fill into the material: small, so thin plates are not pierced.
        let ov = min(0.2, 0.25 * min(spec.distance, radius))
        if spec.profile == .round, concave {
            // Fill the inside corner with a quarter round (torus); the round faces its tube axis.
            let q = spec.distance
            let arcSteps = segments / 4
            func arc(_ c: (Double, Double), from a0: Double, to a1: Double) -> [(Double, Double)] {
                (0...arcSteps).map { i in
                    let t = a0 + (a1 - a0) * Double(i) / Double(arcSteps)
                    return (c.0 + q * cos(t), c.1 + q * sin(t))
                }
            }
            if boss {
                profile = [(radius - ov, q), (radius - ov, -ov), (radius + q, -ov)] + arc((radius + q, q), from: -.pi / 2, to: -.pi)
                surface = .torus(center: centre + a * q, axisDirection: a, majorRadius: radius + q, minorRadius: q)
            } else {
                guard q < radius * 0.98 else { throw KernelError.invalidParameter("raccordo più grande del raggio del foro") }
                profile = [(radius + ov, q), (radius + ov, -ov), (radius - q, -ov)] + arc((radius - q, q), from: -.pi / 2, to: 0)
                surface = .torus(center: centre + a * q, axisDirection: a, majorRadius: radius - q, minorRadius: q)
            }
            special = Set(3..<(3 + arcSteps))
            toolFlipped = true
        } else if concave {
            // Fill the inside corner with a cone band.
            let (first1, second) = try spec.distances(dihedral: .pi / 2)
            let dp = planeFirst ? first1 : second, dc = planeFirst ? second : first1
            let k = dp / dc
            if boss {
                profile = [(radius - ov, dc), (radius - ov, -ov), (radius + dp, -ov), (radius + dp, 0), (radius, dc)]
                surface = .cone(apex: centre + a * ((radius + dp) / k), axisDirection: -a, halfAngle: atan(k))
                toolFlipped = false
            } else {
                guard dp < radius * 0.98 else { throw KernelError.invalidParameter("smusso più grande del raggio del foro") }
                profile = [(radius + ov, dc), (radius + ov, -ov), (radius - dp, -ov), (radius - dp, 0), (radius, dc)]
                surface = .cone(apex: centre - a * ((radius - dp) / k), axisDirection: a, halfAngle: atan(k))
                toolFlipped = true
            }
            special = [3]
        } else if spec.profile == .round {
            let q = spec.distance
            let arcSteps = segments / 4
            func arc(_ c: (Double, Double), from a0: Double, to a1: Double) -> [(Double, Double)] {
                (0...arcSteps).map { i in
                    let t = a0 + (a1 - a0) * Double(i) / Double(arcSteps)
                    return (c.0 + q * cos(t), c.1 + q * sin(t))
                }
            }
            if boss {
                guard q < radius * 0.98 else { throw KernelError.invalidParameter("raccordo più grande del raggio del cilindro") }
                // From the tangent on the wall (R, -q) round to the tangent on the face (R - q, 0).
                profile = [(radius - q, lead), (radius + lead, lead), (radius + lead, -q)]
                    + arc((radius - q, -q), from: 0, to: .pi / 2)
                special = Set(3..<(3 + arcSteps))
                surface = .torus(center: centre - a * q, axisDirection: a, majorRadius: radius - q, minorRadius: q)
            } else {
                // Tangent on the face (R + q, 0) round to the tangent on the hole wall (R, -q).
                let l2 = min(lead, 0.5 * radius)
                profile = [(0, lead), (radius + q, lead)] + arc((radius + q, -q), from: .pi / 2, to: .pi)
                    + [(radius - l2, -q - l2), (0, -q - l2)]
                special = Set(2..<(2 + arcSteps))
                surface = .torus(center: centre - a * q, axisDirection: a, majorRadius: radius + q, minorRadius: q)
            }
            toolFlipped = true
        } else {
            let (first1, second) = try spec.distances(dihedral: .pi / 2)
            let dp = planeFirst ? first1 : second, dc = planeFirst ? second : first1
            let k = dp / dc
            if boss {
                guard dp < radius * 0.98 else { throw KernelError.invalidParameter("smusso più grande del raggio del cilindro") }
                let l1 = min(lead, 0.45 * (radius - dp) / k), l2 = min(lead, 0.25 / k)
                profile = [(radius - dp - l1 * k, l1), (radius + lead, l1), (radius + lead, -dc - l2), (radius + l2 * k, -dc - l2)]
                special = [3]
                surface = .cone(apex: centre + a * ((radius - dp) / k), axisDirection: -a, halfAngle: atan(k))
                toolFlipped = true
            } else {
                let l2 = min(lead, 0.5 * radius / k)
                profile = [(0, lead), (radius + dp + lead * k, lead), (radius - l2 * k, -dc - l2), (0, -dc - l2)]
                special = [1]
                surface = .cone(apex: centre - a * ((radius + dp) / k), axisDirection: a, halfAngle: atan(k))
                toolFlipped = false
            }
        }

        var faces: [CSGFace] = []
        var polys: [CSGSolid.Polygon] = []
        func point(_ p: (Double, Double), _ step: Int) -> Vec3 {
            let t = t0 + Double(step) / Double(steps) * span
            return centre + a * p.1 + (u * cos(t) + v * sin(t)) * p.0
        }
        faces.append(CSGFace(id: FaceID(rawValue: prefix), surface: surface, flipped: toolFlipped))
        for i in profile.indices {
            let p = profile[i], q = profile[(i + 1) % profile.count]
            if p.0 == 0, q.0 == 0 { continue }
            let face: Int
            if special.contains(i) {
                face = 0
            } else {
                faces.append(CSGFace(id: FaceID(rawValue: prefix + "/aux\(i)"), surface: .plane(origin: point(p, 0), normal: a), flipped: false))
                face = faces.count - 1
            }
            for s in 0..<steps {
                var quad = [point(p, s), point(p, s + 1), point(q, s + 1), point(q, s)]
                if p.0 == 0 { quad.remove(at: 1) } else if q.0 == 0 { quad.remove(at: 2) }
                guard (quad[1] - quad[0]).cross(quad[2] - quad[0]).length > 1e-12 else { continue }
                polys.append(CSGSolid.Polygon(vertices: quad, face: face))
            }
        }
        if !closed {
            // End caps: the profile itself at both ends of the sweep, triangulated (it can be concave).
            let flat = Profile2D(points: profile.map { Vec2($0.0, $0.1) })
            let loop = flat.points.map { ($0.x, $0.y) }
            // The sides face out when the profile runs counter-clockwise; otherwise everything is
            // inside out until `oriented` turns it round, and the caps must match the sides.
            let signed = profile.indices.reduce(0.0) { acc, i in
                let p = profile[i], q = profile[(i + 1) % profile.count]
                return acc + p.0 * q.1 - q.0 * p.1
            }
            for (step, name) in [(0, "start"), (steps, "end")] {
                faces.append(CSGFace(id: FaceID(rawValue: prefix + "/" + name), surface: .plane(origin: point(loop[0], step), normal: a), flipped: false))
                let face = faces.count - 1
                for (i, j, k) in flat.triangulate() {
                    var tri = [loop[i], loop[j], loop[k]]
                    let area = (tri[1].0 - tri[0].0) * (tri[2].1 - tri[0].1) - (tri[2].0 - tri[0].0) * (tri[1].1 - tri[0].1)
                    if area < 0 { tri.swapAt(1, 2) }
                    // A counter-clockwise (radius, height) triangle faces back along the sweep: right for the start.
                    if (step != 0) == (signed > 0) { tri.swapAt(1, 2) }
                    let verts = tri.map { point($0, step) }
                    guard (verts[1] - verts[0]).cross(verts[2] - verts[0]).length > 1e-12 else { continue }
                    polys.append(CSGSolid.Polygon(vertices: verts, face: face))
                }
            }
        }
        return (oriented(polys, faces), concave)
    }

    // MARK: Circular edge between surfaces of revolution (plane ⟂ axis, cylinder, cone)

    /// Nil when the two faces are not coaxial surfaces of this kind.
    private static func revolved(_ edge: EdgeInfo, a fa: Int, b fb: Int, spec: ChamferSpec, snapshot: BodySnapshot,
                                 prefix: String) throws -> (solid: CSGSolid, adds: Bool)? {
        let sa = snapshot.faces[fa].surface, sb = snapshot.faces[fb].surface
        // The axis: from the cylinder or cone.
        var axisInfo: (Vec3, Vec3)?
        for s in [sa, sb] {
            switch s {
            case let .cylinder(o, d, _): axisInfo = (o, d.normalized)
            case let .cone(apex, d, _): axisInfo = (apex, d.normalized)
            default: break
            }
        }
        guard let (o, axis) = axisInfo, let p0 = edge.polyline.first, let last = edge.polyline.last, edge.polyline.count >= 3 else { return nil }
        func coaxial(_ s: SurfaceDescriptor) -> Bool {
            switch s {
            case let .plane(_, n): return abs(n.normalized.dot(axis)) > 0.9999
            case let .cylinder(oo, d, _), let .cone(oo, d, _):
                let off = oo - o
                return abs(d.normalized.dot(axis)) > 0.9999 && (off - axis * off.dot(axis)).length < 1e-5
            default: return false
            }
        }
        guard coaxial(sa), coaxial(sb) else { return nil }
        // Frame at the first edge point: radius r0 and height h0 along the axis.
        let d0 = p0 - o, h0 = d0.dot(axis), radial = d0 - axis * h0, r0 = radial.length
        guard r0 > 1e-6 else { return nil }
        let er = radial * (1 / r0)
        func flat(_ v: Vec3) -> (Double, Double) { (v.dot(er), v.dot(axis)) }
        func unit(_ v: (Double, Double)) -> (Double, Double) { let l = (v.0 * v.0 + v.1 * v.1).squareRoot(); return (v.0 / l, v.1 / l) }
        // Each face in the (radius, height) half-plane: direction away from the corner, outward normal.
        func profile(_ f: Int, _ s: SurfaceDescriptor) -> (t: (Double, Double), n: (Double, Double))? {
            var line: (Double, Double)
            switch s {
            case .plane: line = (1, 0)
            case .cylinder: line = (0, 1)
            case let .cone(apex, _, _): line = unit(flat(p0 - apex))
            default: return nil
            }
            // The side the face lies on, and its outward normal, from a triangle at the point.
            for t in 0..<snapshot.triangleFace.count where Int(snapshot.triangleFace[t]) == f {
                let v = (0..<3).map { snapshot.positions[Int(snapshot.triangles[t * 3 + $0])] }
                guard v.contains(where: { ($0 - p0).length < 1e-5 }) else { continue }
                let c = flat((v[0] + v[1] + v[2]) * (1.0 / 3) - p0)
                if line.0 * c.0 + line.1 * c.1 < 0 { line = (-line.0, -line.1) }
                let n = unit(flat((v[1] - v[0]).cross(v[2] - v[0])))
                return (line, n)
            }
            return nil
        }
        guard let A = profile(fa, sa), let B = profile(fb, sb) else { return nil }
        func dot(_ p: (Double, Double), _ q: (Double, Double)) -> Double { p.0 * q.0 + p.1 * q.1 }
        func add(_ p: (Double, Double), _ q: (Double, Double)) -> (Double, Double) { (p.0 + q.0, p.1 + q.1) }
        func mul(_ p: (Double, Double), _ k: Double) -> (Double, Double) { (p.0 * k, p.1 * k) }
        let (ta, na) = A, (tb, nb) = B
        let convex = dot(ta, nb) < -1e-6 && dot(tb, na) < -1e-6
        let concave = dot(ta, nb) > 1e-6 && dot(tb, na) > 1e-6
        guard convex || concave else { throw KernelError.invalidParameter("smusso: spigolo tangente o degenere") }
        let dihedral = acos(max(-1, min(1, dot(ta, tb))))
        let widthA = extent(ofFace: fa, from: edge.polyline, snapshot), widthB = extent(ofFace: fb, from: edge.polyline, snapshot)
        let out = unit(add(na, nb)), sign = concave ? -1.0 : 1.0
        let ov = min(0.2, 0.25 * spec.distance)
        // Section relative to the corner; `special` = its sides that become the bevel/round.
        var section: [(Double, Double)], special: Set<Int>
        if spec.profile == .round {
            let r = spec.distance, half = dihedral / 2
            let x = r / tan(half), cd = r / sin(half)
            guard x <= min(widthA, widthB) + 1e-6 else { throw tooBig(spec, max: min(widthA, widthB) * tan(half)) }
            let c = mul(unit(add(ta, tb)), cd)
            let from = add(mul(ta, x), mul(c, -1)), to = add(mul(tb, x), mul(c, -1))
            let theta = acos(max(-1, min(1, dot(from, to) / (r * r))))
            let n = max(3, Int((theta / (2 * .pi) * Double(segments) - 1e-9).rounded(.up)))
            section = (0...n).map { i in
                let t = Double(i) / Double(n)
                return add(c, mul(add(mul(from, sin((1 - t) * theta)), mul(to, sin(t * theta))), 1 / sin(theta)))
            }
            if concave {
                section += [add(mul(tb, x), mul(nb, -ov)), mul(add(na, nb), -ov), add(mul(ta, x), mul(na, -ov))]
            } else {
                let m = r + lead
                section += [add(mul(tb, x), mul(nb, sign * m)), mul(out, 2 * m + cd), add(mul(ta, x), mul(na, sign * m))]
            }
            special = Set(0..<n)
        } else {
            let (d1, d2) = try spec.distances(dihedral: dihedral)
            guard d1 <= widthA + 1e-6, d2 <= widthB + 1e-6 else { throw tooBig(spec, max: min(widthA, widthB)) }
            let qa = mul(ta, d1), qb = mul(tb, d2)
            if concave {
                section = [qa, qb, add(qb, mul(nb, -ov)), mul(add(na, nb), -ov), add(qa, mul(na, -ov))]
            } else {
                let u = unit(add(qb, mul(qa, -1)))
                let e = max(d1, d2) + lead
                let h = 2 * max(d1, d2) + lead
                section = [add(qa, mul(u, -e)), add(qb, mul(u, e)), add(add(qb, mul(u, e)), mul(out, h)), add(add(qa, mul(u, -e)), mul(out, h))]
            }
            special = [0]
        }
        // Absolute (radius, height); nothing past the axis.
        let prof = section.map { (max(0, r0 + $0.0), h0 + $0.1) }

        // Sweep: the whole turn for a rim, the arc's own span otherwise.
        let helper = abs(axis.z) < 0.9 ? Vec3(0, 0, 1) : Vec3(1, 0, 0)
        let u = helper.cross(axis).normalized, v = axis.cross(u)
        let closed = (p0 - last).length < 1e-4
        var t0 = 0.0, span = 2 * Double.pi
        if !closed {
            func angle(_ p: Vec3) -> Double { let d = p - o; return atan2(d.dot(v), d.dot(u)) }
            func wrapped(_ x: Double) -> Double { let m = x.truncatingRemainder(dividingBy: 2 * .pi); return m < 0 ? m + 2 * .pi : m }
            let a0 = angle(p0), a1 = angle(last), am = angle(edge.polyline[edge.polyline.count / 2])
            let ccw = wrapped(a1 - a0)
            if wrapped(am - a0) < ccw { t0 = a0; span = ccw } else { t0 = a1; span = 2 * .pi - ccw }
        }
        let steps = closed ? segments : max(1, Int((span / (2 * .pi / Double(segments))).rounded(.up)))
        func point(_ p: (Double, Double), _ step: Int) -> Vec3 {
            let t = t0 + Double(step) / Double(steps) * span
            return o + axis * p.1 + (u * cos(t) + v * sin(t)) * p.0
        }
        // Exact surface of the bevel/round.
        let surface: SurfaceDescriptor
        if spec.profile == .round {
            let r = spec.distance, half = dihedral / 2
            let c = mul(unit(add(ta, tb)), r / sin(half))
            surface = .torus(center: o + axis * (h0 + c.1), axisDirection: axis, majorRadius: r0 + c.0, minorRadius: r)
        } else {
            let a = prof[0], b = prof[1]
            let dr = b.0 - a.0, dh = b.1 - a.1
            if abs(dh) < 1e-9 {
                surface = .plane(origin: o + axis * a.1, normal: axis)
            } else if abs(dr) < 1e-9 {
                surface = .cylinder(axisOrigin: o, axisDirection: axis, radius: a.0)
            } else {
                // Apex where the bevel line meets the axis; the cone opens away from it.
                let hApex = a.1 - a.0 * dh / dr
                let up = (a.1 - hApex) > 0 ? axis : -axis
                surface = .cone(apex: o + axis * hApex, axisDirection: up, halfAngle: atan(abs(dr / dh)))
            }
        }
        var faces = [CSGFace(id: FaceID(rawValue: prefix), surface: surface, flipped: false)]
        var polys: [CSGSolid.Polygon] = []
        for i in prof.indices {
            let p = prof[i], q = prof[(i + 1) % prof.count]
            if p.0 == 0, q.0 == 0 { continue }
            let face: Int
            if special.contains(i) { face = 0 } else {
                faces.append(CSGFace(id: FaceID(rawValue: prefix + "/aux\(i)"), surface: .plane(origin: point(p, 0), normal: axis), flipped: false))
                face = faces.count - 1
            }
            for st in 0..<steps {
                var quad = [point(p, st), point(p, st + 1), point(q, st + 1), point(q, st)]
                if p.0 == 0 { quad.remove(at: 1) } else if q.0 == 0 { quad.remove(at: 2) }
                guard (quad[1] - quad[0]).cross(quad[2] - quad[0]).length > 1e-12 else { continue }
                polys.append(CSGSolid.Polygon(vertices: quad, face: face))
            }
        }
        if !closed {
            let flatProfile = Profile2D(points: prof.map { Vec2($0.0, $0.1) })
            let loop = flatProfile.points.map { ($0.x, $0.y) }
            let signed = prof.indices.reduce(0.0) { acc, i in
                let p = prof[i], q = prof[(i + 1) % prof.count]
                return acc + p.0 * q.1 - q.0 * p.1
            }
            for (step, name) in [(0, "start"), (steps, "end")] {
                faces.append(CSGFace(id: FaceID(rawValue: prefix + "/" + name), surface: .plane(origin: point(loop[0], step), normal: axis), flipped: false))
                let face = faces.count - 1
                for (i, j, k) in flatProfile.triangulate() {
                    var tri = [loop[i], loop[j], loop[k]]
                    let area = (tri[1].0 - tri[0].0) * (tri[2].1 - tri[0].1) - (tri[2].0 - tri[0].0) * (tri[1].1 - tri[0].1)
                    if area < 0 { tri.swapAt(1, 2) }
                    if (step != 0) == (signed > 0) { tri.swapAt(1, 2) }
                    let verts = tri.map { point($0, step) }
                    guard (verts[1] - verts[0]).cross(verts[2] - verts[0]).length > 1e-12 else { continue }
                    polys.append(CSGSolid.Polygon(vertices: verts, face: face))
                }
            }
        }
        let tool = oriented(polys, faces)
        // The bevel's normal must match its polygons in the result (subtracted tools are inverted
        // together with their "flipped" flag, so one rule covers both): compare at one polygon.
        var fixed = tool.faces
        if let sample = tool.polygons.first(where: { $0.face == 0 }) {
            let c = sample.vertices.reduce(Vec3.zero, +) * (1 / Double(sample.vertices.count))
            let natural: Vec3
            switch surface {
            case let .plane(_, n): natural = n
            case let .cylinder(oo, ax, _): let dd = c - oo; natural = (dd - ax * dd.dot(ax)).normalized
            case let .cone(apex, ax, half):
                let dd = c - apex
                natural = ((dd - ax * dd.dot(ax)).normalized * cos(half) - ax * sin(half)).normalized
            case let .torus(centre, ax, major, _):
                let dd = c - centre
                natural = (c - (centre + (dd - ax * dd.dot(ax)).normalized * major)).normalized
            case .freeform: natural = sample.normal
            }
            fixed[0].flipped = natural.dot(sample.normal) < 0
        }
        return (CSGSolid(polygons: tool.polygons, faces: fixed), concave)
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
