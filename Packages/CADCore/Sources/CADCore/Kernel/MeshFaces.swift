import Foundation

/// Faces of an imported mesh (T74): connected coplanar triangles become one planar face
/// (selectable, measurable, sketchable, drillable); the rest is grouped into smooth regions
/// (creases above ~25° split them) marked as freeform surfaces.
enum MeshFaces {
    static func solid(_ mesh: Mesh, featureID: UUID) -> CSGSolid {
        let n = mesh.triangleCount
        var normals = [Vec3](repeating: .zero, count: n), w = [Double](repeating: 0, count: n)
        for t in 0..<n {
            let (a, b, c) = mesh.triangle(t)
            normals[t] = (b - a).cross(c - a).normalized
            w[t] = normals[t].dot(a)
        }
        // Triangles sharing an edge (in either direction).
        struct E: Hashable { let a: UInt32, b: UInt32 }
        var byEdge: [E: [Int]] = [:]
        for t in 0..<n {
            for k in 0..<3 {
                let a = mesh.indices[t * 3 + k], b = mesh.indices[t * 3 + (k + 1) % 3]
                byEdge[E(a: min(a, b), b: max(a, b)), default: []].append(t)
            }
        }
        func neighbours(_ t: Int) -> [Int] {
            (0..<3).flatMap { k -> [Int] in
                let a = mesh.indices[t * 3 + k], b = mesh.indices[t * 3 + (k + 1) % 3]
                return byEdge[E(a: min(a, b), b: max(a, b))] ?? []
            }.filter { $0 != t }
        }
        var areas = [Double](repeating: 0, count: n)
        for t in 0..<n { let (a, b, c) = mesh.triangle(t); areas[t] = (b - a).cross(c - a).length / 2 }
        func flood(_ seed: Int, within allowed: (Int) -> Bool, joins: (Int, Int) -> Bool) -> [Int] {
            var members = [seed], queue = [seed]
            var seen: Set<Int> = [seed]
            while let t = queue.popLast() {
                for u in neighbours(t) where !seen.contains(u) && allowed(u) && joins(t, u) {
                    seen.insert(u); members.append(u); queue.append(u)
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
        var faces: [CSGFace] = []
        let prefix = "mesh:\(featureID.uuidString)/"
        for (r, members) in regions.enumerated() {
            let total = members.reduce(0) { $0 + areas[$1] }
            var assigned = Set<Int>()
            for seed in members where !assigned.contains(seed) && normals[seed].length > 0 {
                let patch = flood(seed, within: { smooth[$0] == r && !assigned.contains($0) },
                                  joins: { _, u in normals[u].dot(normals[seed]) > 1 - 1e-6 && abs(w[u] - w[seed]) < 1e-4 })
                let area = patch.reduce(0) { $0 + areas[$1] }
                guard patch.count == members.count || area >= 0.04 * total else { continue }
                let f = faces.count
                faces.append(CSGFace(id: FaceID(rawValue: prefix + "p\(f)"),
                                     surface: .plane(origin: mesh.triangle(seed).0, normal: normals[seed]), flipped: false))
                for m in patch { region[m] = f; assigned.insert(m) }
            }
            for seed in members where region[seed] < 0 {
                let f = faces.count
                faces.append(CSGFace(id: FaceID(rawValue: prefix + "s\(f)"), surface: .freeform, flipped: false))
                for m in flood(seed, within: { smooth[$0] == r && region[$0] < 0 }, joins: { _, _ in true }) { region[m] = f }
            }
        }
        var polygons: [CSGSolid.Polygon] = []
        for t in 0..<n {
            let (a, b, c) = mesh.triangle(t)
            guard (b - a).cross(c - a).length > 1e-12 else { continue }
            polygons.append(CSGSolid.Polygon(vertices: [a, b, c], face: region[t]))
        }
        return CSGSolid(polygons: polygons, faces: faces)
    }
}
