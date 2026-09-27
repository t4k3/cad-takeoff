import Foundation

/// Faces of an imported mesh (T74, parts from the Fusion add-in, STL, 3MF): connected coplanar
/// triangles become one planar face (selectable, measurable, sketchable, drillable); smooth
/// regions (creases above ~25° split them) that lie on a cylinder become a cylinder face (holes,
/// shafts, rounds: diameter, axis, centre); the rest stays freeform.
enum MeshFaces {
    static func solid(_ mesh: Mesh, featureID: UUID) -> CSGSolid { faces(mesh, featureID: featureID).solid }

    /// The solid plus the mesh and face of each triangle as they are: an imported mesh is already
    /// welded and indexed, so the viewport snapshot can be built from it directly (the CSG clean-up
    /// — welding, T-junctions — is only needed after a boolean, and takes ~40 s on a large assembly).
    static func faces(_ mesh: Mesh, featureID: UUID) -> (solid: CSGSolid, mesh: Mesh, triangleFace: [Int]) {
        let n = mesh.triangleCount
        var normals = [Vec3](repeating: .zero, count: n), w = [Double](repeating: 0, count: n)
        var areas = [Double](repeating: 0, count: n)
        for t in 0..<n {
            let (a, b, c) = mesh.triangle(t)
            let cr = (b - a).cross(c - a)
            normals[t] = cr.normalized
            w[t] = normals[t].dot(a)
            areas[t] = cr.length / 2
        }
        // Neighbours across each edge, computed once.
        struct E: Hashable { let a: UInt32, b: UInt32 }
        var byEdge: [E: [Int32]] = [:]
        byEdge.reserveCapacity(n * 2)
        for t in 0..<n {
            for k in 0..<3 {
                let a = mesh.indices[t * 3 + k], b = mesh.indices[t * 3 + (k + 1) % 3]
                byEdge[E(a: min(a, b), b: max(a, b)), default: []].append(Int32(t))
            }
        }
        var adjacency = [[Int32]](repeating: [], count: n)
        for list in byEdge.values where list.count > 1 {
            for t in list { for u in list where u != t { adjacency[Int(t)].append(u) } }
        }
        // Flood fill with a reusable visit stamp (no per-fill sets).
        var stamp = [Int](repeating: -1, count: n), fill = 0
        func flood(_ seed: Int, within allowed: (Int) -> Bool, joins: (Int, Int) -> Bool) -> [Int] {
            fill += 1
            var members = [seed], queue = [seed]
            stamp[seed] = fill
            while let t = queue.popLast() {
                for u32 in adjacency[t] {
                    let u = Int(u32)
                    guard stamp[u] != fill, allowed(u), joins(t, u) else { continue }
                    stamp[u] = fill; members.append(u); queue.append(u)
                }
            }
            return members
        }
        // Distances: exported coordinates are rounded (float), so "on the plane" allows for it.
        var lo = mesh.vertices.first ?? .zero, hi = lo
        for v in mesh.vertices { lo = Vec3(min(lo.x, v.x), min(lo.y, v.y), min(lo.z, v.z)); hi = Vec3(max(hi.x, v.x), max(hi.y, v.y), max(hi.z, v.z)) }
        let reach = max(abs(lo.x), abs(lo.y), abs(lo.z), abs(hi.x), abs(hi.y), abs(hi.z), (hi - lo).length)
        let tol = max(2e-4, 4e-6 * reach)
        // A sliver's normal is noise at that precision: only its corners say where it lies.
        func sliver(_ t: Int) -> Bool {
            let (a, b, c) = mesh.triangle(t)
            let longest = max((b - a).length, (c - b).length, (a - c).length)
            return 2 * areas[t] / max(longest, 1e-12) < 20 * tol
        }
        // 1. Smooth regions: creases sharper than ~25° separate them.
        let crease = cos(25 * Double.pi / 180)
        var smooth = [Int](repeating: -1, count: n)
        var regions: [[Int]] = []
        for seed in 0..<n where smooth[seed] < 0 {
            let members = flood(seed, within: { smooth[$0] < 0 }, joins: { normals[$0].dot(normals[$1]) > crease })
            for m in members { smooth[m] = regions.count }
            regions.append(members)
        }
        // 2. Whole regions lying on one cylinder (a hole, a shaft, a round) are one cylinder face.
        var region = [Int](repeating: -1, count: n)
        var assigned = [Bool](repeating: false, count: n)
        var faces: [CSGFace] = []
        let prefix = "mesh:\(featureID.uuidString)/"
        func cylinder(_ members: [Int]) -> SurfaceDescriptor? {
            guard members.count >= 6 else { return nil }
            let solid = members.filter { !sliver($0) }
            guard let first = solid.first else { return nil }
            // The axis is square to every normal: from the two most different ones.
            var axis = Vec3.zero
            for t in solid { let c = normals[first].cross(normals[t]); if c.length > axis.length { axis = c } }
            guard axis.length > 0.05 else { return nil }   // nearly flat: not a cylinder
            axis = axis.normalized
            guard solid.allSatisfy({ abs(normals[$0].dot(axis)) < 0.02 }) else { return nil }
            let helper = abs(axis.z) < 0.9 ? Vec3(0, 0, 1) : Vec3(1, 0, 0)
            let u = helper.cross(axis).normalized, v = axis.cross(u)
            var seen = Set<UInt32>(), pts: [Vec3] = []
            for t in members { for k in 0..<3 where seen.insert(mesh.indices[t * 3 + k]).inserted { pts.append(mesh.vertices[Int(mesh.indices[t * 3 + k])]) } }
            let flat = pts.map { Vec2($0.dot(u), $0.dot(v)) }
            guard let fit = PrimitiveKernel.fit(flat), fit.r > 10 * tol,
                  flat.allSatisfy({ abs(($0 - fit.c).length - fit.r) < max(3 * tol, 1e-3 * fit.r) }) else { return nil }
            // Points the booleans left on the chords lie a little inside: the true vertices are
            // the farthest out.
            let radius = flat.map { ($0 - fit.c).length }.max() ?? fit.r
            let along = pts.reduce(0.0) { $0 + $1.dot(axis) } / Double(pts.count)
            // Facing out of the part: the normals point away from the axis on a shaft, towards it
            // in a hole; the descriptor holds the geometry, the face's orientation comes from them.
            return .cylinder(axisOrigin: u * fit.c.x + v * fit.c.y + axis * along, axisDirection: axis, radius: radius)
        }
        for (r, members) in regions.enumerated() {
            if let surface = cylinder(members) {
                let f = faces.count
                faces.append(CSGFace(id: FaceID(rawValue: prefix + "c\(f)"), surface: surface, flipped: false))
                for m in members { region[m] = f; assigned[m] = true }
                continue
            }
            // 3. Inside the others: coplanar patches that matter (≥ 4% of the region) are planar
            //    faces; the rest (facets of curved surfaces) one face per connected piece, a
            //    cylinder if it lies on one, else freeform.
            let total = members.reduce(0) { $0 + areas[$1] }
            for seed in members where !assigned[seed] && normals[seed].length > 0 && !sliver(seed) {
                let (sa, sb, sc) = mesh.triangle(seed)
                let n0 = normals[seed], w0 = n0.dot(sa)
                _ = (sb, sc)
                let patch = flood(seed, within: { smooth[$0] == r && !assigned[$0] }, joins: { _, u in
                    let (a, b, c) = mesh.triangle(u)
                    guard [a, b, c].allSatisfy({ abs(n0.dot($0) - w0) < tol }) else { return false }
                    return sliver(u) || normals[u].dot(n0) > 1 - 2e-4
                })
                let area = patch.reduce(0) { $0 + areas[$1] }
                guard patch.count == members.count || area >= 0.04 * total else { continue }
                // The plane of the whole patch (area-weighted), not of its first triangle.
                var normal = Vec3.zero, centre = Vec3.zero
                for m in patch {
                    let (a, b, c) = mesh.triangle(m)
                    normal = normal + (b - a).cross(c - a)
                    centre = centre + (a + b + c) * (areas[m] / 3)
                }
                let f = faces.count
                faces.append(CSGFace(id: FaceID(rawValue: prefix + "p\(f)"),
                                     surface: .plane(origin: area > 0 ? centre * (1 / area) : sa, normal: normal.length > 0 ? normal.normalized : n0),
                                     flipped: false))
                for m in patch { region[m] = f; assigned[m] = true }
            }
            for seed in members where region[seed] < 0 {
                let f = faces.count
                let piece = flood(seed, within: { smooth[$0] == r && region[$0] < 0 }, joins: { _, _ in true })
                let surface = cylinder(piece) ?? .freeform
                faces.append(CSGFace(id: FaceID(rawValue: prefix + (surface == .freeform ? "s" : "c") + "\(f)"), surface: surface, flipped: false))
                for m in piece { region[m] = f }
            }
        }
        // 4. Pieces lying on a neighbouring flat face join it: a flat face split by a row of
        //    slivers (where a boolean mended the mesh), or by rounding, is one face again.
        var members = [[Int]](repeating: [], count: faces.count)
        for t in 0..<n where region[t] >= 0 { members[region[t]].append(t) }
        func planeOf(_ f: Int) -> (Vec3, Double)? {
            guard case .plane = faces[f].surface else { return nil }
            var normal = Vec3.zero, centre = Vec3.zero, area = 0.0
            for m in members[f] {
                let (a, b, c) = mesh.triangle(m)
                normal = normal + (b - a).cross(c - a); centre = centre + (a + b + c) * (areas[m] / 3); area += areas[m]
            }
            guard normal.length > 0, area > 0 else { return nil }
            let k = normal.normalized
            return (k, k.dot(centre * (1 / area)))
        }
        var planes = faces.indices.map { planeOf($0) }
        var merged = [Bool](repeating: false, count: faces.count)
        var changed = true
        while changed {
            changed = false
            for f in faces.indices where !merged[f] && !members[f].isEmpty {
                if case .cylinder = faces[f].surface { continue }
                let own = planes[f]
                var neighbours = Set<Int>()
                for t in members[f] { for u in adjacency[t] { let g = region[Int(u)]; if g >= 0, g != f, !merged[g] { neighbours.insert(g) } } }
                for g in neighbours.sorted() {
                    guard let (k, d) = planes[g] else { continue }
                    if let (k2, _) = own, k2.dot(k) < 1 - 2e-4 { continue }
                    let on = members[f].allSatisfy { t in let (a, b, c) = mesh.triangle(t); return [a, b, c].allSatisfy { abs(k.dot($0) - d) < tol } }
                    guard on else { continue }
                    for t in members[f] { region[t] = g }
                    members[g] += members[f]; members[f] = []; merged[f] = true
                    planes[g] = planeOf(g)
                    changed = true
                    break
                }
            }
        }
        // Planes described by all their triangles; faces renumbered without the merged ones.
        var renumber = [Int](repeating: -1, count: faces.count)
        var finalFaces: [CSGFace] = []
        for f in faces.indices where !merged[f] && !members[f].isEmpty {
            renumber[f] = finalFaces.count
            var face = faces[f]
            if let (k, d) = planes[f] { face.surface = .plane(origin: k * d, normal: k) }
            finalFaces.append(face)
        }
        for t in 0..<n where region[t] >= 0 { region[t] = renumber[region[t]] }
        faces = finalFaces
        var polygons: [CSGSolid.Polygon] = []
        var kept = Mesh(vertices: mesh.vertices, indices: [])
        var triangleFace: [Int] = []
        polygons.reserveCapacity(n); kept.indices.reserveCapacity(n * 3); triangleFace.reserveCapacity(n)
        for t in 0..<n {
            let (a, b, c) = mesh.triangle(t)
            guard areas[t] > 5e-13 else { continue }
            polygons.append(CSGSolid.Polygon(vertices: [a, b, c], face: region[t]))
            kept.indices += mesh.indices[(t * 3)..<(t * 3 + 3)]
            triangleFace.append(region[t])
        }
        return (CSGSolid(polygons: polygons, faces: faces), kept, triangleFace)
    }
}
