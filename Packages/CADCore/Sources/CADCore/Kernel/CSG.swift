import Foundation

// Boolean operations (phase 3, T84): our own BSP-tree CSG on polyhedral solids, followed by
// a clean-up that welds vertices and repairs T-junctions so every result is a closed,
// printable triangle mesh. Every polygon carries the face it came from, so results keep
// face identity (a hole cut by a cylinder is still a "cylindrical face Ø…").

/// Identity and exact surface of a face, carried through booleans.
public struct CSGFace: Equatable, Sendable {
    public var id: FaceID
    public var surface: SurfaceDescriptor
    /// True when the face belongs to a subtracted tool: its outward normal is reversed.
    public var flipped: Bool
}

/// A closed polyhedral solid as convex polygons tagged with their source face.
public struct CSGSolid: Sendable {
    struct Polygon: Sendable {
        var vertices: [Vec3]
        var normal: Vec3
        var w: Double
        var face: Int

        init(vertices: [Vec3], face: Int) {
            self.vertices = vertices
            self.face = face
            let n = (vertices[1] - vertices[0]).cross(vertices[2] - vertices[0]).normalized
            normal = n
            w = n.dot(vertices[0])
        }

        init(vertices: [Vec3], normal: Vec3, w: Double, face: Int) {
            self.vertices = vertices; self.normal = normal; self.w = w; self.face = face
        }

        func flipped(faceMap: (Int) -> Int) -> Polygon {
            Polygon(vertices: vertices.reversed(), normal: -normal, w: -w, face: faceMap(face))
        }
    }

    var polygons: [Polygon]
    public private(set) var faces: [CSGFace]

    public var isEmpty: Bool { polygons.isEmpty }

    /// From a kernel snapshot: one polygon per triangle, tagged with its selection face.
    public init(_ snapshot: BodySnapshot) {
        faces = snapshot.faces.map { CSGFace(id: $0.id, surface: $0.surface, flipped: false) }
        polygons = []
        let p = snapshot.positions, t = snapshot.triangles
        for i in 0..<(t.count / 3) {
            let v = [p[Int(t[i * 3])], p[Int(t[i * 3 + 1])], p[Int(t[i * 3 + 2])]]
            guard (v[1] - v[0]).cross(v[2] - v[0]).length > 1e-12 else { continue }
            polygons.append(Polygon(vertices: v, face: Int(snapshot.triangleFace[i])))
        }
    }

    init(polygons: [Polygon], faces: [CSGFace]) { self.polygons = polygons; self.faces = faces }

    /// The solid moved (or mirrored: `reflect`), its face IDs prefixed to stay unique among copies.
    func transformed(point: (Vec3) -> Vec3, direction: (Vec3) -> Vec3, reflect: Bool, prefix: String) -> CSGSolid {
        let polys = polygons.map { p -> Polygon in
            var v = p.vertices.map(point)
            if reflect { v.reverse() }
            let n = direction(p.normal).normalized
            return Polygon(vertices: v, normal: n, w: n.dot(v[0]), face: p.face)
        }
        let fs = faces.map { CSGFace(id: FaceID(rawValue: prefix + $0.id.rawValue), surface: $0.surface.mapped(point: point, direction: direction), flipped: $0.flipped) }
        return CSGSolid(polygons: polys, faces: fs)
    }

    // MARK: Operations

    /// The polygon-pair booleans (CSGMesh) first; the BSP only when they cannot decide.
    nonisolated(unsafe) static var useMeshBooleans = true

    public func union(_ other: CSGSolid) -> CSGSolid {
        let (b, faces) = merged(other, flipOther: false)
        if Self.useMeshBooleans, let r = Self.meshBoolean(polygons, b, .union) { return CSGSolid(polygons: r, faces: faces) }
        let na = BSPNode(polygons), nb = BSPNode(b)
        na.clip(to: nb); nb.clip(to: na); nb.invert(); nb.clip(to: na); nb.invert()
        na.build(nb.allPolygons())
        return CSGSolid(polygons: na.allPolygons(), faces: faces)
    }

    public func subtracting(_ other: CSGSolid) -> CSGSolid {
        let (b, faces) = merged(other, flipOther: true)
        if Self.useMeshBooleans, let r = Self.meshBoolean(polygons, b, .subtract) { return CSGSolid(polygons: r, faces: faces) }
        let na = BSPNode(polygons), nb = BSPNode(b)
        na.invert(); na.clip(to: nb); nb.clip(to: na); nb.invert(); nb.clip(to: na); nb.invert()
        na.build(nb.allPolygons()); na.invert()
        return CSGSolid(polygons: na.allPolygons(), faces: faces)
    }

    public func intersecting(_ other: CSGSolid) -> CSGSolid {
        let (b, faces) = merged(other, flipOther: false)
        if Self.useMeshBooleans, let r = Self.meshBoolean(polygons, b, .intersect) { return CSGSolid(polygons: r, faces: faces) }
        let na = BSPNode(polygons), nb = BSPNode(b)
        na.invert(); nb.clip(to: na); nb.invert(); na.clip(to: nb); nb.clip(to: na)
        na.build(nb.allPolygons()); na.invert()
        return CSGSolid(polygons: na.allPolygons(), faces: faces)
    }

    /// Other solid's polygons re-tagged into a shared face table. For subtraction the tool's
    /// faces become "flipped" twins (their polygons are inverted by the BSP algorithm).
    private func merged(_ other: CSGSolid, flipOther: Bool) -> ([Polygon], [CSGFace]) {
        var table = faces
        let offset = table.count
        table += other.faces.map { var f = $0; if flipOther { f.flipped.toggle() }; return f }
        let polys = other.polygons.map { var p = $0; p.face += offset; return p }
        return (polys, table)
    }
}

// MARK: - BSP tree (after csg.js, Evan Wallace, MIT)

private let epsilon = 1e-6

private final class BSPNode {
    // Every traversal is iterative: tangent or nearly coplanar faces (rounds) make deep trees
    // that would overflow the small stacks of background threads.
    var normal: Vec3?
    var w = 0.0
    var front: BSPNode?
    var back: BSPNode?
    var polygons: [CSGSolid.Polygon] = []

    init(_ polygons: [CSGSolid.Polygon] = []) { build(polygons) }

    deinit {
        // Releasing a deep tree recursively would overflow the stack too.
        var stack = [front, back].compactMap { $0 }
        front = nil; back = nil
        while let node = stack.popLast() {
            if let f = node.front { stack.append(f); node.front = nil }
            if let b = node.back { stack.append(b); node.back = nil }
        }
    }

    private var allNodes: [BSPNode] {
        var out: [BSPNode] = [], stack = [self]
        while let n = stack.popLast() {
            out.append(n)
            if let f = n.front { stack.append(f) }
            if let b = n.back { stack.append(b) }
        }
        return out
    }

    func invert() {
        for node in allNodes {
            node.polygons = node.polygons.map { $0.flipped(faceMap: { $0 }) }
            if let n = node.normal { node.normal = -n; node.w = -node.w }
            swap(&node.front, &node.back)
        }
    }

    /// Removes the parts of `list` inside this tree's solid.
    func clipPolygons(_ list: [CSGSolid.Polygon]) -> [CSGSolid.Polygon] {
        var out: [CSGSolid.Polygon] = []
        var work: [(BSPNode, [CSGSolid.Polygon])] = [(self, list)]
        while let (node, polys) = work.popLast() {
            guard let n = node.normal else { out += polys; continue }
            var f: [CSGSolid.Polygon] = [], b: [CSGSolid.Polygon] = []
            for p in polys {
                let r = split(p, n, node.w)
                f += r.coFront + r.front
                b += r.coBack + r.back
            }
            if let front = node.front { work.append((front, f)) } else { out += f }
            if let back = node.back { work.append((back, b)) }   // no back child: inside, dropped
        }
        return out
    }

    func clip(to other: BSPNode) {
        for node in allNodes { node.polygons = other.clipPolygons(node.polygons) }
    }

    func allPolygons() -> [CSGSolid.Polygon] { allNodes.flatMap(\.polygons) }

    func build(_ list: [CSGSolid.Polygon]) {
        var work: [(BSPNode, [CSGSolid.Polygon])] = [(self, list)]
        while let (node, polys) = work.popLast() {
            guard !polys.isEmpty else { continue }
            if node.normal == nil { node.normal = polys[0].normal; node.w = polys[0].w }
            let n = node.normal!
            var f: [CSGSolid.Polygon] = [], b: [CSGSolid.Polygon] = []
            for p in polys {
                let r = split(p, n, node.w)
                node.polygons += r.coFront + r.coBack
                f += r.front
                b += r.back
            }
            if !f.isEmpty { if node.front == nil { node.front = BSPNode() }; work.append((node.front!, f)) }
            if !b.isEmpty { if node.back == nil { node.back = BSPNode() }; work.append((node.back!, b)) }
        }
    }
}

private struct SplitResult {
    var coFront: [CSGSolid.Polygon] = []
    var coBack: [CSGSolid.Polygon] = []
    var front: [CSGSolid.Polygon] = []
    var back: [CSGSolid.Polygon] = []
}

/// Splits `p` by the plane (n, w): coplanar (same/opposite facing), front and back parts.
private func split(_ p: CSGSolid.Polygon, _ n: Vec3, _ w: Double) -> SplitResult {
    let coplanar = 0, fr = 1, bk = 2, spanning = 3
    var r = SplitResult()
    var type = 0
    var types: [Int] = []
    types.reserveCapacity(p.vertices.count)
    for v in p.vertices {
        let t = n.dot(v) - w
        let c = t < -epsilon ? bk : (t > epsilon ? fr : coplanar)
        type |= c
        types.append(c)
    }
    switch type {
    case coplanar:
        if n.dot(p.normal) > 0 { r.coFront.append(p) } else { r.coBack.append(p) }
    case fr: r.front.append(p)
    case bk: r.back.append(p)
    default:
        var f: [Vec3] = [], b: [Vec3] = []
        let count = p.vertices.count
        for i in 0..<count {
            let j = (i + 1) % count
            let ti = types[i], tj = types[j]
            let vi = p.vertices[i], vj = p.vertices[j]
            if ti != bk { f.append(vi) }
            if ti != fr { b.append(vi) }
            if (ti | tj) == spanning {
                let t = (w - n.dot(vi)) / n.dot(vj - vi)
                let v = vi + (vj - vi) * t
                f.append(v); b.append(v)
            }
        }
        if f.count >= 3 { r.front.append(CSGSolid.Polygon(vertices: f, normal: p.normal, w: p.w, face: p.face)) }
        if b.count >= 3 { r.back.append(CSGSolid.Polygon(vertices: b, normal: p.normal, w: p.w, face: p.face)) }
    }
    return r
}

// MARK: - Clean-up to a closed triangle mesh

public extension CSGSolid {
    /// Welded, T-junction-free triangle mesh plus the face of each triangle.
    func triangulated() -> (mesh: Mesh, triangleFace: [Int]) {
        // 1. Weld within 2e-5 mm. Points are bucketed on a grid as fine as the tolerance but
        //    matched against the 27 neighbouring cells, so two nearly equal points on opposite
        //    sides of a rounding boundary still merge (plain rounding would split them and leave cracks).
        let tol = 2e-5, cell = 2e-5
        var buckets: [SIMD3<Int64>: [UInt32]] = [:]
        var positions: [Vec3] = []
        func key(_ v: Vec3) -> SIMD3<Int64> { SIMD3(Int64((v.x / cell).rounded(.down)), Int64((v.y / cell).rounded(.down)), Int64((v.z / cell).rounded(.down))) }
        func id(_ v: Vec3) -> UInt32 {
            let k = key(v)
            for dx in -1...1 { for dy in -1...1 { for dz in -1...1 {
                for i in buckets[k &+ SIMD3(Int64(dx), Int64(dy), Int64(dz))] ?? [] where (positions[Int(i)] - v).length <= tol { return i }
            } } }
            let i = UInt32(positions.count)
            buckets[k, default: []].append(i)
            positions.append(v)
            return i
        }
        var loops: [(ids: [UInt32], face: Int)] = []
        for p in polygons {
            var ids: [UInt32] = []
            for v in p.vertices { let i = id(v); if ids.last != i { ids.append(i) } }
            if ids.count > 1, ids.first == ids.last { ids.removeLast() }
            guard ids.count >= 3 else { continue }
            loops.append((ids, p.face))
        }

        // 2. T-junctions: insert any vertex lying inside a polygon edge. Candidates come from a
        //    coarse grid walked along each edge (checking every vertex is quadratic).
        var lo = positions.first ?? .zero, hi = lo
        for p in positions {
            lo = Vec3(min(lo.x, p.x), min(lo.y, p.y), min(lo.z, p.z)); hi = Vec3(max(hi.x, p.x), max(hi.y, p.y), max(hi.z, p.z))
        }
        let g = max((hi - lo).length / 256, 1e-3)
        func cellOf(_ p: Vec3) -> SIMD3<Int32> {
            SIMD3(Int32(((p.x - lo.x) / g).rounded(.down)), Int32(((p.y - lo.y) / g).rounded(.down)), Int32(((p.z - lo.z) / g).rounded(.down)))
        }
        // Each vertex goes in every cell its tolerance box touches, so the cells an edge passes
        // through (exact traversal) hold every vertex within tolerance of it.
        var grid: [SIMD3<Int32>: [UInt32]] = [:]
        let pad = Vec3(3e-5, 3e-5, 3e-5)
        for (i, p) in positions.enumerated() {
            let c0 = cellOf(p - pad), c1 = cellOf(p + pad)
            for x in c0.x...c1.x { for y in c0.y...c1.y { for z in c0.z...c1.z { grid[SIMD3(x, y, z), default: []].append(UInt32(i)) } } }
        }
        func candidates(_ pa: Vec3, _ pb: Vec3) -> [UInt32] {
            var c = cellOf(pa)
            let end = cellOf(pb), d = pb - pa
            let dv = [d.x, d.y, d.z], av = [pa.x - lo.x, pa.y - lo.y, pa.z - lo.z]
            var tMax = [Double](repeating: .infinity, count: 3), tDelta = tMax
            var stepv = SIMD3<Int32>(0, 0, 0)
            for k in 0..<3 where abs(dv[k]) > 1e-15 {
                stepv[k] = dv[k] > 0 ? 1 : -1
                let boundary = (Double(c[k]) + (dv[k] > 0 ? 1 : 0)) * g
                tMax[k] = (boundary - av[k]) / dv[k]
                tDelta[k] = g / abs(dv[k])
            }
            var out = grid[c] ?? []
            var budget = abs(Int(end.x - c.x)) + abs(Int(end.y - c.y)) + abs(Int(end.z - c.z))
            while c != end, budget > 0 {
                let k = tMax[0] < tMax[1] ? (tMax[0] < tMax[2] ? 0 : 2) : (tMax[1] < tMax[2] ? 1 : 2)
                c[k] += stepv[k]; tMax[k] += tDelta[k]; budget -= 1
                out += grid[c] ?? []
            }
            if c != end { out += grid[end] ?? [] }
            return out
        }
        for li in loops.indices {
            var out: [UInt32] = []
            let ids = loops[li].ids
            for k in 0..<ids.count {
                let a = ids[k], b = ids[(k + 1) % ids.count]
                out.append(a)
                let pa = positions[Int(a)], pb = positions[Int(b)]
                let d = pb - pa, len2 = d.dot(d)
                guard len2 > 1e-14 else { continue }
                var inner: [(Double, UInt32)] = []
                let lo = Vec3(min(pa.x, pb.x), min(pa.y, pb.y), min(pa.z, pb.z)) - Vec3(1e-4, 1e-4, 1e-4)
                let hi = Vec3(max(pa.x, pb.x), max(pa.y, pb.y), max(pa.z, pb.z)) + Vec3(1e-4, 1e-4, 1e-4)
                for c in candidates(pa, pb) {
                    let pc = positions[Int(c)]
                    guard c != a, c != b, pc.x >= lo.x, pc.x <= hi.x, pc.y >= lo.y, pc.y <= hi.y,
                          pc.z >= lo.z, pc.z <= hi.z else { continue }
                    let t = (pc - pa).dot(d) / len2
                    guard t > 1e-9, t < 1 - 1e-9 else { continue }
                    if (pa + d * t - pc).length < 2e-5 { inner.append((t, c)) }
                }
                out += inner.sorted { $0.0 < $1.0 }.map(\.1)
            }
            loops[li].ids = out
        }

        // 3. Triangulate each convex loop. Loops with points on their edges use a centre fan
        //    (never degenerate), plain loops a vertex fan.
        var mesh = Mesh(vertices: positions, indices: [])
        var triangleFace: [Int] = []
        // Planar faces split into many fragments are re-triangulated as one polygon.
        var merged = Set<Int>()
        let byFace = Dictionary(grouping: loops.indices, by: { loops[$0].face })
        // Curved faces are facets: fragments are merged per facet plane.
        // Sorted: dictionary order differs between runs, the mesh must not.
        for face in byFace.keys.sorted() where CoplanarMerge.isEnabled {
            let members = byFace[face]!
            guard members.count > 1 else { continue }
            var clusters: [(n: Vec3, w: Double, members: [Int])] = []
            for m in members {
                let nn = newell(loops[m].ids, positions)
                guard nn.length > 1e-14 else { continue }
                let n = nn.normalized, w = n.dot(positions[Int(loops[m].ids[0])])
                if let i = clusters.firstIndex(where: { $0.n.dot(n) > 1 - 1e-9 && abs($0.w - w) < 1e-7 }) {
                    clusters[i].members.append(m)
                } else { clusters.append((n, w, [m])) }
            }
            for cluster in clusters where cluster.members.count > 1 {
                guard let tris = CoplanarMerge.triangulate(cluster.members.map { loops[$0].ids }, positions, normal: cluster.n) else { continue }
                for (a, b, c) in tris { addTriangle(&mesh, &triangleFace, a, b, c, face) }
                merged.formUnion(cluster.members)
            }
        }
        for (li, (ids, face)) in loops.enumerated() where !merged.contains(li) {
            if ids.count == 3 || !hasCollinear(ids, positions) {
                for k in 1..<(ids.count - 1) {
                    addTriangle(&mesh, &triangleFace, ids[0], ids[k], ids[k + 1], face)
                }
            } else {
                let c = ids.reduce(Vec3.zero) { $0 + positions[Int($1)] } * (1 / Double(ids.count))
                let ci = UInt32(mesh.vertices.count)
                mesh.vertices.append(c)
                for k in 0..<ids.count { addTriangle(&mesh, &triangleFace, ci, ids[k], ids[(k + 1) % ids.count], face) }
            }
        }
        return Self.removingZeroVolumeFins(mesh, triangleFace)
    }

    /// Welding can turn two tiny BSP fragments into the same triangle with opposite winding:
    /// a zero-thickness fin that makes edges non-manifold. Such pairs cancel out.
    private static func removingZeroVolumeFins(_ mesh: Mesh, _ faces: [Int]) -> (mesh: Mesh, triangleFace: [Int]) {
        struct Key: Hashable { let a: UInt32, b: UInt32, c: UInt32 }
        func canonical(_ a: UInt32, _ b: UInt32, _ c: UInt32) -> (Key, Bool) {
            // Rotate so the smallest index is first; the parity of the rest tells the winding.
            var t = [a, b, c]
            while t[0] != t.min()! { t = [t[1], t[2], t[0]] }
            return t[1] < t[2] ? (Key(a: t[0], b: t[1], c: t[2]), true) : (Key(a: t[0], b: t[2], c: t[1]), false)
        }
        var seen: [Key: (ccw: [Int], cw: [Int])] = [:]
        for t in 0..<mesh.triangleCount {
            let (k, ccw) = canonical(mesh.indices[t * 3], mesh.indices[t * 3 + 1], mesh.indices[t * 3 + 2])
            if ccw { seen[k, default: ([], [])].ccw.append(t) } else { seen[k, default: ([], [])].cw.append(t) }
        }
        var drop = Set<Int>()
        for (_, v) in seen {
            let pairs = min(v.ccw.count, v.cw.count)
            drop.formUnion(v.ccw.prefix(pairs)); drop.formUnion(v.cw.prefix(pairs))
            drop.formUnion(v.ccw.dropFirst(max(pairs, 1)))   // exact duplicates, same winding
            drop.formUnion(v.cw.dropFirst(max(pairs, 1)))
        }
        guard !drop.isEmpty else { return (mesh, faces) }
        var out = Mesh(vertices: mesh.vertices, indices: [])
        var outFaces: [Int] = []
        for t in 0..<mesh.triangleCount where !drop.contains(t) {
            out.indices += mesh.indices[(t * 3)..<(t * 3 + 3)]
            outFaces.append(faces[t])
        }
        return (out, outFaces)
    }

    /// Area-weighted normal of a loop (Newell), zero for a degenerate one.
    private func newell(_ ids: [UInt32], _ p: [Vec3]) -> Vec3 {
        var n = Vec3.zero
        for k in ids.indices {
            let a = p[Int(ids[k])], b = p[Int(ids[(k + 1) % ids.count])]
            n = n + Vec3((a.y - b.y) * (a.z + b.z), (a.z - b.z) * (a.x + b.x), (a.x - b.x) * (a.y + b.y))
        }
        return n
    }

    private func hasCollinear(_ ids: [UInt32], _ p: [Vec3]) -> Bool {
        for k in 0..<ids.count {
            let a = p[Int(ids[(k + ids.count - 1) % ids.count])], b = p[Int(ids[k])], c = p[Int(ids[(k + 1) % ids.count])]
            if (b - a).cross(c - b).length < 1e-9 { return true }
        }
        return false
    }

    private func addTriangle(_ mesh: inout Mesh, _ faces: inout [Int], _ a: UInt32, _ b: UInt32, _ c: UInt32, _ face: Int) {
        let p = mesh.vertices
        guard (p[Int(b)] - p[Int(a)]).cross(p[Int(c)] - p[Int(a)]).length > 1e-12 else { return }
        mesh.indices += [a, b, c]
        faces.append(face)
    }
}
