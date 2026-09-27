import Foundation

// Rounds and chamfers on closed edges between any two exact surfaces (docs/SUPERFICI_ESATTE.md,
// tappa 4): where a cross hole meets a shaft, where two cylinders cross. At every point of the
// edge — carried onto both surfaces — the ball of the round is found on the true surfaces
// (Newton: at distance r inside both, in the plane across the edge), its contact points are the
// round's borders; the section between them is swept along the edge into a ring removed from
// the body. A chamfer takes the points at its distance on each surface instead of the arc.

extension ChamferGeometry {
    static func swept(_ edge: EdgeInfo, a fa: Int, b fb: Int, spec: ChamferSpec, snapshot: BodySnapshot,
                      prefix: String) throws -> (solid: CSGSolid, adds: Bool)? {
        let sa = snapshot.faces[fa].surface, sb = snapshot.faces[fb].surface
        guard sa.signedDistance(edge.polyline.first ?? .zero) != nil, sb.signedDistance(edge.polyline.first ?? .zero) != nil else { return nil }
        var line = edge.polyline
        guard line.count >= 4, let first = line.first, let last = line.last, (last - first).length < 1e-6 else { return nil }   // closed loops
        line.removeLast()
        // Outward sides from the facets next to the edge, and whether the edge is convex.
        func facet(_ f: Int, near p: Vec3) -> (n: Vec3, c: Vec3)? {
            var best: (Double, Vec3, Vec3)?
            for t in 0..<snapshot.triangleFace.count where Int(snapshot.triangleFace[t]) == f {
                let v = (0..<3).map { snapshot.positions[Int(snapshot.triangles[t * 3 + $0])] }
                let c = (v[0] + v[1] + v[2]) * (1.0 / 3), d = (c - p).length
                if d < (best?.0 ?? .infinity) { best = (d, (v[1] - v[0]).cross(v[2] - v[0]).normalized, c) }
            }
            return best.map { ($0.1, $0.2) }
        }
        let probe = line[0]
        guard let na = facet(fa, near: probe), let nb = facet(fb, near: probe),
              let ga = sa.signedDistance(probe)?.g, let gb = sb.signedDistance(probe)?.g else { return nil }
        // Signed distances positive outside the part.
        let ka: Double = ga.dot(na.n) >= 0 ? 1 : -1, kb: Double = gb.dot(nb.n) >= 0 ? 1 : -1
        func outside(_ s: SurfaceDescriptor, _ k: Double, _ x: Vec3) -> (d: Double, n: Vec3)? {
            s.signedDistance(x).map { (k * $0.d, $0.g * k) }
        }
        // Convex: stepping off the edge up over face a and away from face b stays in the air
        // (inside corner: it enters the material of the wall).
        let eps = max(0.02, 0.05 * spec.distance)
        let concave = contains(probe + (ga * ka - gb * kb) * eps, snapshot)
        guard !concave else {
            throw KernelError.invalidParameter("smusso: su questo spigolo curvo per ora solo spigoli sporgenti (non angoli interni)")
        }
        let r = spec.distance, d2 = spec.mode == .equalDistance ? spec.distance : spec.distance2
        guard r > 0, d2 > 0 else { throw KernelError.invalidParameter("smusso: misura non valida") }
        let arcSteps = spec.profile == .round ? Tessellation.segments(8) : 1
        let lift = max(0.5 * max(r, d2), 0.2)

        // Stations: exact edge points, tangent from the neighbours.
        let n = line.count
        let exact = line.map { ChamferGeometry.onBoth($0, sa, sb) ?? $0 }
        var sections: [[Vec3]] = []
        for i in 0..<n {
            let e = exact[i], t = (exact[(i + 1) % n] - exact[(i + n - 1) % n]).normalized
            guard let oa = outside(sa, ka, e)?.n, let ob = outside(sb, kb, e)?.n else { throw KernelError.invalidParameter("smusso: superficie non definita sullo spigolo") }
            var pa: Vec3, pb: Vec3, arc: [Vec3]
            // The ball of radius ρ inside both surfaces, across the edge (Newton on the true
            // surfaces); its feet are the borders of the round, or of the chamfer.
            func ball(_ rho: Double) throws -> (c: Vec3, pa: Vec3, pb: Vec3) {
                var c = e - (oa + ob).normalized * (rho * 1.4)
                for _ in 0..<40 {
                    guard let da = outside(sa, ka, c), let db = outside(sb, kb, c) else { break }
                    let f = [da.d + rho, db.d + rho, (c - e).dot(t)]
                    if f.allSatisfy({ abs($0) < 1e-10 * max(1, rho) }) {
                        return (c, c - da.n * da.d, c - db.n * db.d)
                    }
                    guard let step = solve3([[da.n.x, da.n.y, da.n.z], [db.n.x, db.n.y, db.n.z], [t.x, t.y, t.z]], f) else { break }
                    c = c - Vec3(step[0], step[1], step[2])
                }
                throw KernelError.invalidParameter(String(format: "raccordo/smusso: misura %.2f mm troppo grande per questo spigolo", spec.distance))
            }
            switch spec.profile {
            case .round:
                let (c, a, b) = try ball(r)
                pa = a; pb = b
                let u = (pa - c).normalized, w = (pb - c).normalized
                let angle = acos(max(-1, min(1, u.dot(w))))
                let axis = u.cross(w).normalized
                arc = (0...arcSteps).map { k in
                    let a = angle * Double(k) / Double(arcSteps)
                    return c + (u * cos(a) + axis.cross(u) * sin(a)) * r
                }
            case .flat:
                // Equal distances: the ball tangent to both faces touches them at d from the edge
                // when its radius is d·tan(α/2), α the angle between the faces inside the part.
                let interior = Double.pi - acos(max(-1, min(1, oa.dot(ob))))
                if spec.mode == .equalDistance {
                    let (_, a, b) = try ball(r * tan(interior / 2))
                    pa = a; pb = b
                } else {
                    func along(_ s: SurfaceDescriptor, own: Vec3, other: Vec3, _ dist: Double) -> Vec3 {
                        var u = t.cross(own).normalized
                        if u.dot(other) > 0 { u = -u }
                        let guess = e + u * dist
                        return ChamferGeometry.onSurface(guess, s, across: t, from: e) ?? guess
                    }
                    pa = along(sa, own: oa, other: ob, r)
                    pb = along(sb, own: ob, other: oa, d2)
                }
                arc = [pa, pb]
            }
            guard let na2 = outside(sa, ka, pa)?.n, let nb2 = outside(sb, kb, pb)?.n else {
                throw KernelError.invalidParameter("smusso: superficie non definita sullo spigolo")
            }
            // The section: the round (or bevel) line, then out over the surfaces and past the edge.
            sections.append(arc + [pb + nb2 * lift, e + (oa + ob).normalized * lift, pa + na2 * lift])
        }
        // The ring: quads between consecutive sections as triangles (they are not flat).
        let m = sections[0].count
        let roundFace = 0, auxFace = 1
        var polys: [CSGSolid.Polygon] = []
        for i in 0..<n {
            let s0 = sections[i], s1 = sections[(i + 1) % n]
            for k in 0..<m {
                let k1 = (k + 1) % m
                let face = k < arcSteps ? roundFace : auxFace
                for tri in [[s0[k], s0[k1], s1[k1]], [s0[k], s1[k1], s1[k]]] where (tri[1] - tri[0]).cross(tri[2] - tri[0]).length > 1e-14 {
                    polys.append(CSGSolid.Polygon(vertices: tri, face: face))
                }
            }
        }
        let faces = [CSGFace(id: FaceID(rawValue: prefix), surface: .freeform, flipped: true),
                     CSGFace(id: FaceID(rawValue: prefix + "/aux"), surface: .freeform, flipped: false)]
        return (orientedSolid(polys, faces), false)
    }

    /// A point carried onto where the two surfaces meet (nil: Newton does not settle).
    static func onBoth(_ p: Vec3, _ a: SurfaceDescriptor, _ b: SurfaceDescriptor) -> Vec3? {
        SurfaceDescriptor.project(p, onto: [a, b], tolerance: 1e-10)
    }

    /// A point carried onto a surface staying in the plane across the edge at `e`.
    static func onSurface(_ p: Vec3, _ s: SurfaceDescriptor, across t: Vec3, from e: Vec3) -> Vec3? {
        var x = p
        for _ in 0..<40 {
            guard let (d, g) = s.signedDistance(x) else { return nil }
            if abs(d) < 1e-11 * max(1, x.length) { return x }
            // Move along the surface normal projected into the plane across the edge.
            var dir = g - t * g.dot(t)
            let l = dir.length
            guard l > 1e-9 else { return nil }
            dir = dir * (1 / l)
            x = x - dir * (d / max(1e-9, dir.dot(g)))
            x = x - t * (x - e).dot(t)
        }
        return nil
    }

    /// 3×3 linear solve (Gaussian elimination with pivoting).
    static func solve3(_ A0: [[Double]], _ b0: [Double]) -> [Double]? {
        var A = A0, b = b0
        for c in 0..<3 {
            guard let p = (c..<3).max(by: { abs(A[$0][c]) < abs(A[$1][c]) }), abs(A[p][c]) > 1e-15 else { return nil }
            A.swapAt(c, p); b.swapAt(c, p)
            for r in 0..<3 where r != c {
                let f = A[r][c] / A[c][c]
                for k in c..<3 { A[r][k] -= f * A[c][k] }
                b[r] -= f * b[c]
            }
        }
        return (0..<3).map { b[$0] / A[$0][$0] }
    }
}
