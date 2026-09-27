import Foundation

/// «Guscio» (Fusion's Shell): a body hollowed to a wall thickness, with the chosen faces removed
/// (the open top of a box or a cover).
public struct ShellSpec: Codable, Sendable, Equatable {
    /// The body (its source feature) to hollow; used when no face is open.
    public var body: UUID
    /// Wall thickness in mm.
    public var thickness: Double
    /// Faces left open (selection-face IDs of the body).
    public var openFaces: [FaceID]

    public init(body: UUID, thickness: Double, openFaces: [FaceID] = []) {
        self.body = body; self.thickness = thickness; self.openFaces = openFaces
    }

    public func validate() throws {
        guard thickness.isFinite, thickness > 0, thickness <= 1000 else { throw KernelError.invalidParameter("guscio: spessore tra 0 e 1000 mm") }
    }
}

enum ShellGeometry {
    /// The cavity to subtract: every face moved inwards by the thickness (open faces outwards, so
    /// the subtraction opens them); each corner solved from the planes of the faces around it.
    static func cavity(of snapshot: BodySnapshot, spec: ShellSpec, featureID: UUID) throws -> CSGSolid {
        try spec.validate()
        let t = spec.thickness
        let open = Set(spec.openFaces)
        let margin = max(t, 1)
        // Weld the shading-split positions.
        var index: [SIMD3<Int64>: Int] = [:]
        var points: [Vec3] = []
        func key(_ p: Vec3) -> SIMD3<Int64> { SIMD3(Int64((p.x * 1e6).rounded()), Int64((p.y * 1e6).rounded()), Int64((p.z * 1e6).rounded())) }
        let tri = snapshot.triangles.map { i -> Int in
            let p = snapshot.positions[Int(i)], k = key(p)
            if let v = index[k] { return v }
            points.append(p); index[k] = points.count - 1
            return points.count - 1
        }
        let count = tri.count / 3
        // Planes around each corner: (unit normal, offset target).
        var planes = [[(Vec3, Double)]](repeating: [], count: points.count)
        var normals: [Vec3] = []
        for f in 0..<count {
            let a = points[tri[f * 3]], b = points[tri[f * 3 + 1]], c = points[tri[f * 3 + 2]]
            let n = (b - a).cross(c - a)
            let l = n.length
            guard l > 1e-12 else { normals.append(.zero); continue }
            let u = n * (1 / l)
            normals.append(u)
            let face = snapshot.faces[Int(snapshot.triangleFace[f])].id
            // Every face in by the thickness (a closed cavity: robust where faces meet tangentially,
            // as rounds do); the open faces are cut through afterwards.
            _ = face
            let d = u.dot(a) - t
            for v in [tri[f * 3], tri[f * 3 + 1], tri[f * 3 + 2]] where !planes[v].contains(where: { $0.0.dot(u) > 1 - 1e-9 }) {
                planes[v].append((u, d))
            }
        }
        // Each corner: least squares on its planes, nearest to where it was (null directions).
        var moved = points
        for v in points.indices where !planes[v].isEmpty {
            let p = points[v], mu = 1e-9
            var A = [[Double]](repeating: [0, 0, 0], count: 3), rhs = [mu * p.x, mu * p.y, mu * p.z]
            for i in 0..<3 { A[i][i] = mu }
            for (n, d) in planes[v] {
                let nv = [n.x, n.y, n.z]
                for i in 0..<3 { for j in 0..<3 { A[i][j] += nv[i] * nv[j] }; rhs[i] += nv[i] * d }
            }
            guard let x = solve3(A, rhs) else { throw KernelError.invalidParameter("guscio: geometria non gestita") }
            moved[v] = Vec3(x[0], x[1], x[2])
        }
        // Faces of the cavity: the body's, moved in (the subtraction flips them).
        let prefix = featureID.uuidString.lowercased() + "/shell/"
        let faces = snapshot.faces.map { f -> CSGFace in
            let s: SurfaceDescriptor
            switch f.surface {
            case let .plane(o, n): s = .plane(origin: o - n.normalized * t, normal: n)
            case let .cylinder(o, d, r): s = r > t ? .cylinder(axisOrigin: o, axisDirection: d, radius: r - t) : .freeform
            default: s = .freeform
            }
            return CSGFace(id: FaceID(rawValue: prefix + f.id.rawValue), surface: s, flipped: false)
        }
        var polys: [CSGSolid.Polygon] = []
        for f in 0..<count where normals[f] != .zero {
            let v = [moved[tri[f * 3]], moved[tri[f * 3 + 1]], moved[tri[f * 3 + 2]]]
            let n = (v[1] - v[0]).cross(v[2] - v[0])
            // A face turned over: the walls meet inside (thickness larger than the part allows).
            guard n.dot(normals[f]) > -1e-9 else {
                throw KernelError.invalidParameter(String(format: "guscio: spessore %.2f mm troppo grande per questo corpo", t))
            }
            guard n.length > 1e-12 else { continue }
            polys.append(CSGSolid.Polygon(vertices: v, face: Int(snapshot.triangleFace[f])))
        }
        let cavity = CSGSolid(polygons: polys, faces: faces)
        // Walls thicker than the part allows turn the cavity inside out (its volume goes negative)
        // or leave it bigger than the part.
        func volume(_ ps: [CSGSolid.Polygon]) -> Double {
            guard let o = ps.first?.vertices.first else { return 0 }
            var v = 0.0
            for p in ps { for k in 1..<(p.vertices.count - 1) { v += (p.vertices[0] - o).dot((p.vertices[k] - o).cross(p.vertices[k + 1] - o)) } }
            return v / 6
        }
        var bodyVolume = 0.0
        for f in 0..<count where normals[f] != .zero {
            bodyVolume += points[tri[f * 3]].dot(points[tri[f * 3 + 1]].cross(points[tri[f * 3 + 2]])) / 6
        }
        let cavityVolume = volume(polys)
        guard cavityVolume > 1e-9, cavityVolume < abs(bodyVolume) else {
            throw KernelError.invalidParameter(String(format: "guscio: spessore %.2f mm troppo grande per questo corpo", t))
        }
        guard !open.isEmpty else { return cavity }
        // The opening: the cavity's open faces pushed out through the wall (t + margin) and a
        // little into the cavity, as a prism; so the lid is gone and the walls stay whole.
        var prisms: CSGSolid?
        for faceIndex in snapshot.faces.indices where open.contains(snapshot.faces[faceIndex].id) {
            let tris = (0..<count).filter { normals[$0] != .zero && Int(snapshot.triangleFace[$0]) == faceIndex }
            guard !tris.isEmpty else { continue }
            var n = Vec3.zero
            for f in tris { n = n + normals[f] }
            n = n.normalized
            let down = -min(0.2, 0.5 * t), up = t + margin
            var sides: [SIMD2<Int>: Int] = [:]
            var pp: [CSGSolid.Polygon] = []
            let capFace = snapshot.faces.count, sideFace = snapshot.faces.count + 1
            for f in tris {
                let v = [tri[f * 3], tri[f * 3 + 1], tri[f * 3 + 2]]
                let bottom = v.map { moved[$0] + n * down }, top = v.map { moved[$0] + n * up }
                pp.append(CSGSolid.Polygon(vertices: [bottom[0], bottom[2], bottom[1]], face: capFace))
                pp.append(CSGSolid.Polygon(vertices: top, face: capFace))
                for k in 0..<3 { sides[SIMD2(v[k], v[(k + 1) % 3]), default: 0] += 1 }
            }
            // Walls along the region's outline (edges used once, in the triangles' direction).
            for (e, _) in sides where sides[SIMD2(e.y, e.x)] == nil {
                let a = moved[e.x], b = moved[e.y]
                let quad = [a + n * down, b + n * down, b + n * up, a + n * up]
                guard (quad[1] - quad[0]).cross(quad[3] - quad[0]).length > 1e-14 else { continue }
                pp.append(CSGSolid.Polygon(vertices: quad, face: sideFace))
            }
            let piece = CSGSolid(polygons: pp, faces: faces + [CSGFace(id: FaceID(rawValue: prefix + "opening/\(faceIndex)"), surface: .plane(origin: moved[tri[tris[0] * 3]] + n * up, normal: n), flipped: false),
                                                        CSGFace(id: FaceID(rawValue: prefix + "opening/\(faceIndex)/side"), surface: .freeform, flipped: false)])
            prisms = prisms.map { $0.union(piece) } ?? piece
        }
        guard let prisms else { return cavity }
        return cavity.union(prisms)
    }

    /// 3×3 linear solve (Gaussian elimination with pivoting).
    private static func solve3(_ A0: [[Double]], _ b0: [Double]) -> [Double]? {
        var A = A0, b = b0
        for c in 0..<3 {
            guard let p = (c..<3).max(by: { abs(A[$0][c]) < abs(A[$1][c]) }), abs(A[p][c]) > 1e-18 else { return nil }
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
