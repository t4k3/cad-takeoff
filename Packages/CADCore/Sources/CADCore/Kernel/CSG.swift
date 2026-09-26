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

    // MARK: Operations

    public func union(_ other: CSGSolid) -> CSGSolid {
        let (b, faces) = merged(other, flipOther: false)
        let na = BSPNode(polygons), nb = BSPNode(b)
        na.clip(to: nb); nb.clip(to: na); nb.invert(); nb.clip(to: na); nb.invert()
        na.build(nb.allPolygons())
        return CSGSolid(polygons: na.allPolygons(), faces: faces)
    }

    public func subtracting(_ other: CSGSolid) -> CSGSolid {
        let (b, faces) = merged(other, flipOther: true)
        let na = BSPNode(polygons), nb = BSPNode(b)
        na.invert(); na.clip(to: nb); nb.clip(to: na); nb.invert(); nb.clip(to: na); nb.invert()
        na.build(nb.allPolygons()); na.invert()
        return CSGSolid(polygons: na.allPolygons(), faces: faces)
    }

    public func intersecting(_ other: CSGSolid) -> CSGSolid {
        let (b, faces) = merged(other, flipOther: false)
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
    var normal: Vec3?
    var w = 0.0
    var front: BSPNode?
    var back: BSPNode?
    var polygons: [CSGSolid.Polygon] = []

    init(_ polygons: [CSGSolid.Polygon] = []) { build(polygons) }

    func invert() {
        polygons = polygons.map { $0.flipped(faceMap: { $0 }) }
        if let n = normal { normal = -n; w = -w }
        front?.invert(); back?.invert()
        swap(&front, &back)
    }

    func clipPolygons(_ list: [CSGSolid.Polygon]) -> [CSGSolid.Polygon] {
        guard let n = normal else { return list }
        var f: [CSGSolid.Polygon] = [], b: [CSGSolid.Polygon] = []
        for p in list {
            let r = split(p, n, w)
            f += r.coFront + r.front
            b += r.coBack + r.back
        }
        f = front?.clipPolygons(f) ?? f
        b = back?.clipPolygons(b) ?? []
        return f + b
    }

    func clip(to other: BSPNode) {
        polygons = other.clipPolygons(polygons)
        front?.clip(to: other); back?.clip(to: other)
    }

    func allPolygons() -> [CSGSolid.Polygon] {
        polygons + (front?.allPolygons() ?? []) + (back?.allPolygons() ?? [])
    }

    func build(_ list: [CSGSolid.Polygon]) {
        guard !list.isEmpty else { return }
        if normal == nil { normal = list[0].normal; w = list[0].w }
        let n = normal!
        var f: [CSGSolid.Polygon] = [], b: [CSGSolid.Polygon] = []
        for p in list {
            let r = split(p, n, w)
            polygons += r.coFront + r.coBack
            f += r.front
            b += r.back
        }
        if !f.isEmpty { if front == nil { front = BSPNode() }; front!.build(f) }
        if !b.isEmpty { if back == nil { back = BSPNode() }; back!.build(b) }
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
        // 1. Weld on a 1e-5 mm grid so vertices computed by different splits coincide.
        var index: [SIMD3<Int64>: UInt32] = [:]
        var positions: [Vec3] = []
        func key(_ v: Vec3) -> SIMD3<Int64> { SIMD3(Int64((v.x * 1e5).rounded()), Int64((v.y * 1e5).rounded()), Int64((v.z * 1e5).rounded())) }
        func id(_ v: Vec3) -> UInt32 {
            let k = key(v)
            if let i = index[k] { return i }
            let i = UInt32(positions.count)
            index[k] = i
            positions.append(Vec3(Double(k.x) / 1e5, Double(k.y) / 1e5, Double(k.z) / 1e5))
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

        // 2. T-junctions: insert any vertex lying inside a polygon edge.
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
                for (ci, pc) in positions.enumerated() {
                    let c = UInt32(ci)
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
        for (ids, face) in loops {
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
        return (mesh, triangleFace)
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
