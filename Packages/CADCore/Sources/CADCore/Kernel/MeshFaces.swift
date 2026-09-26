import Foundation

/// Faces of an imported mesh (T74): connected coplanar triangles become one planar face
/// (selectable, measurable, sketchable, drillable); the rest is grouped into smooth regions
/// (creases above ~25° split them) marked as freeform surfaces.
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
        // 1. Smooth regions: creases sharper than ~25° separate them.
        let crease = cos(25 * Double.pi / 180)
        var smooth = [Int](repeating: -1, count: n)
        var regions: [[Int]] = []
        for seed in 0..<n where smooth[seed] < 0 {
            let members = flood(seed, within: { smooth[$0] < 0 }, joins: { normals[$0].dot(normals[$1]) > crease })
            for m in members { smooth[m] = regions.count }
            regions.append(members)
        }
        // 2. Inside each: coplanar patches that matter (≥ 4% of the region) are planar faces; the
        //    rest (tessellation facets of curved surfaces) stays one freeform face per connected piece.
        var region = [Int](repeating: -1, count: n)
        var assigned = [Bool](repeating: false, count: n)
        var faces: [CSGFace] = []
        let prefix = "mesh:\(featureID.uuidString)/"
        for (r, members) in regions.enumerated() {
            let total = members.reduce(0) { $0 + areas[$1] }
            for seed in members where !assigned[seed] && normals[seed].length > 0 {
                let patch = flood(seed, within: { smooth[$0] == r && !assigned[$0] },
                                  joins: { _, u in normals[u].dot(normals[seed]) > 1 - 1e-6 && abs(w[u] - w[seed]) < 1e-4 })
                let area = patch.reduce(0) { $0 + areas[$1] }
                guard patch.count == members.count || area >= 0.04 * total else { continue }
                let f = faces.count
                faces.append(CSGFace(id: FaceID(rawValue: prefix + "p\(f)"),
                                     surface: .plane(origin: mesh.triangle(seed).0, normal: normals[seed]), flipped: false))
                for m in patch { region[m] = f; assigned[m] = true }
            }
            for seed in members where region[seed] < 0 {
                let f = faces.count
                faces.append(CSGFace(id: FaceID(rawValue: prefix + "s\(f)"), surface: .freeform, flipped: false))
                for m in flood(seed, within: { smooth[$0] == r && region[$0] < 0 }, joins: { _, _ in true }) { region[m] = f }
            }
        }
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
