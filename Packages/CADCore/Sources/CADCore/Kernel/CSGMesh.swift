import Foundation

// Booleans without a BSP tree (26/09). The BSP splits every polygon by the infinite planes of
// the other solid: a hole's 64 wall facets slice a round next to it into tens of thousands of
// slivers, and the next round has to work on all of them. Here a polygon is split only by the
// planes of the polygons that really cross it, and each piece is classified inside/outside the
// other solid by casting a ray. Polygons that touch nothing stay whole.
//
// Coplanar contact (a join on a face, a tool flush with a face) is found explicitly: pieces lying
// on a face of the other solid are kept or dropped by comparing the two faces' directions.
// When a ray cannot decide (it grazes edges in every direction tried) the caller falls back to the BSP.

extension CSGSolid {
    enum MeshOp { case union, subtract, intersect }

    /// nil = undecidable here (use the BSP).
    static func meshBoolean(_ a: [Polygon], _ b: [Polygon], _ op: MeshOp) -> [Polygon]? {
        guard !a.isEmpty, !b.isEmpty else {
            switch op {
            case .union: return a + b
            case .subtract: return a
            case .intersect: return []
            }
        }
        let ia = PolygonIndex(a), ib = PolygonIndex(b)
        // Disjoint boxes: nothing touches.
        if !ia.bounds.overlaps(ib.bounds, pad: 1e-6) {
            switch op {
            case .union: return a + b
            case .subtract: return a
            case .intersect: return []
            }
        }
        // On a shared plane only the first solid's face can survive: facing the same way as the
        // other's face for union/intersection, the opposite way for a subtraction.
        guard let pa = classify(a, against: b, index: ib, keepSame: op != .subtract, keepOpposite: op == .subtract, keep: { inside in
                  switch op { case .union, .subtract: !inside; case .intersect: inside } }),
              let pb = classify(b, against: a, index: ia, keepSame: false, keepOpposite: false, keep: { inside in
                  switch op { case .union: !inside; case .subtract, .intersect: inside } }) else { return nil }
        // A subtracted tool's surviving faces bound the result from the other side.
        return pa + (op == .subtract ? pb.map { $0.flipped(faceMap: { $0 }) } : pb)
    }

    /// The pieces of `polys` to keep: split by the crossing polygons of `other`, then classified.
    /// `keepSame`/`keepOpposite`: whether a piece lying on a face of `other` is kept, by how the
    /// two faces are oriented.
    private static func classify(_ polys: [Polygon], against other: [Polygon], index: PolygonIndex,
                                 keepSame: Bool, keepOpposite: Bool, keep: (Bool) -> Bool) -> [Polygon]? {
        var out: [Polygon] = []
        out.reserveCapacity(polys.count)
        for p in polys {
            let box = Box(p.vertices)
            var cutters: [Int] = [], coplanar: [Int] = []
            for q in index.candidates(box) {
                let other = other[q]
                switch relation(p, other) {
                case .crossing: cutters.append(q)
                case .coplanar: coplanar.append(q)
                case .apart: break
                }
            }
            if cutters.isEmpty, coplanar.isEmpty {
                guard let inside = index.contains(centroid(p.vertices), polys: other) else { return nil }
                if keep(inside) { out.append(p) }
                continue
            }
            // Split by the crossing planes, and by the edge planes of coplanar polygons (their outline
            // in the shared plane), keeping only splits that really cut a piece.
            var pieces = [p]
            for q in cutters { pieces = pieces.flatMap { cut($0, other[q].normal, other[q].w) } }
            for q in coplanar {
                let o = other[q]
                for k in o.vertices.indices {
                    let e0 = o.vertices[k], e1 = o.vertices[(k + 1) % o.vertices.count]
                    let n = o.normal.cross(e1 - e0).normalized
                    guard n.length > 0.5 else { continue }
                    pieces = pieces.flatMap { cut($0, n, n.dot(e0)) }
                }
            }
            for piece in pieces {
                let c = centroid(piece.vertices)
                // On a coplanar polygon of the other solid?
                if let q = coplanar.first(where: { covers(other[$0], c) }) {
                    let same = other[q].normal.dot(piece.normal) > 0
                    if same ? keepSame : keepOpposite { out.append(piece) }
                    continue
                }
                guard let inside = index.contains(c, polys: other) else { return nil }
                if keep(inside) { out.append(piece) }
            }
        }
        return out
    }

    private enum Relation { case crossing, coplanar, apart }

    /// How two convex polygons relate: crossing (p straddles q's plane, and q straddles p's plane
    /// or stands on it with an edge), coplanar (same plane, either orientation) or apart.
    private static func relation(_ p: Polygon, _ q: Polygon) -> Relation {
        let eps = 1e-6
        var qPos = false, qNeg = false, qOn = 0
        for v in q.vertices {
            let d = p.normal.dot(v) - p.w
            if d > eps { qPos = true } else if d < -eps { qNeg = true } else { qOn += 1 }
        }
        if qOn == q.vertices.count { return overlapsInPlane(p, q) ? .coplanar : .apart }
        // Straddling p's plane, or standing on it with an edge (a round's tool touches the face
        // along its tangent line: the face must be split there too).
        guard (qPos && qNeg) || qOn >= 2 else { return .apart }
        var pPos = false, pNeg = false
        for v in p.vertices {
            let d = q.normal.dot(v) - q.w
            if d > eps { pPos = true } else if d < -eps { pNeg = true }
        }
        return pPos && pNeg ? .crossing : .apart
    }

    /// Two coplanar convex polygons share some area (separating-axis test in their plane).
    private static func overlapsInPlane(_ p: Polygon, _ q: Polygon) -> Bool {
        for poly in [p, q] {
            for k in poly.vertices.indices {
                let e0 = poly.vertices[k], e1 = poly.vertices[(k + 1) % poly.vertices.count]
                let axis = poly.normal.cross(e1 - e0)
                guard axis.length > 1e-12 else { continue }
                let pr = p.vertices.map { axis.dot($0) }, qr = q.vertices.map { axis.dot($0) }
                let tol = 1e-9 * axis.length
                if pr.max()! <= qr.min()! + tol || qr.max()! <= pr.min()! + tol { return false }
            }
        }
        return true
    }

    /// Point (on the polygon's plane) inside the convex polygon.
    private static func covers(_ q: Polygon, _ c: Vec3) -> Bool {
        guard abs(q.normal.dot(c) - q.w) < 1e-6 else { return false }
        for k in q.vertices.indices {
            let e0 = q.vertices[k], e1 = q.vertices[(k + 1) % q.vertices.count]
            if q.normal.dot((e1 - e0).cross(c - e0)) < -1e-9 { return false }
        }
        return true
    }

    /// The polygon split by a plane (only when the plane really crosses it).
    private static func cut(_ p: Polygon, _ n: Vec3, _ w: Double) -> [Polygon] {
        let eps = 1e-6
        let d = p.vertices.map { n.dot($0) - w }
        guard d.contains(where: { $0 > eps }), d.contains(where: { $0 < -eps }) else { return [p] }
        var f: [Vec3] = [], b: [Vec3] = []
        for i in p.vertices.indices {
            let j = (i + 1) % p.vertices.count
            let vi = p.vertices[i], vj = p.vertices[j], di = d[i], dj = d[j]
            if di >= -eps { f.append(vi) }
            if di <= eps { b.append(vi) }
            if (di > eps && dj < -eps) || (di < -eps && dj > eps) {
                let v = vi + (vj - vi) * (di / (di - dj))
                f.append(v); b.append(v)
            }
        }
        var out: [Polygon] = []
        if f.count >= 3 { out.append(Polygon(vertices: f, normal: p.normal, w: p.w, face: p.face)) }
        if b.count >= 3 { out.append(Polygon(vertices: b, normal: p.normal, w: p.w, face: p.face)) }
        return out
    }

    private static func centroid(_ v: [Vec3]) -> Vec3 {
        // Area centroid of the fan (a vertex average can sit on an edge of a thin sliver).
        var sum = Vec3.zero, total = 0.0
        for k in 1..<(v.count - 1) {
            let a = (v[k] - v[0]).cross(v[k + 1] - v[0]).length
            sum = sum + (v[0] + v[k] + v[k + 1]) * (a / 3)
            total += a
        }
        return total > 1e-18 ? sum * (1 / total) : v.reduce(.zero, +) * (1 / Double(v.count))
    }
}

/// Axis-aligned box.
struct Box {
    var lo: Vec3, hi: Vec3
    init(_ pts: [Vec3]) {
        lo = pts[0]; hi = pts[0]
        for p in pts.dropFirst() {
            lo = Vec3(min(lo.x, p.x), min(lo.y, p.y), min(lo.z, p.z)); hi = Vec3(max(hi.x, p.x), max(hi.y, p.y), max(hi.z, p.z))
        }
    }
    func overlaps(_ o: Box, pad: Double) -> Bool {
        lo.x <= o.hi.x + pad && o.lo.x <= hi.x + pad && lo.y <= o.hi.y + pad && o.lo.y <= hi.y + pad
            && lo.z <= o.hi.z + pad && o.lo.z <= hi.z + pad
    }
}

/// Uniform grid over a solid's polygons: box queries and ray casting.
final class PolygonIndex {
    let bounds: Box
    private let boxes: [Box]
    private let cell: Double
    private var cells: [SIMD3<Int32>: [Int]] = [:]
    private var stamp: [Int]
    private var query = 0

    init(_ polys: [CSGSolid.Polygon]) {
        boxes = polys.map { Box($0.vertices) }
        var b = boxes[0]
        for x in boxes.dropFirst() { b = Box([b.lo, b.hi, x.lo, x.hi]) }
        bounds = b
        let size = b.hi - b.lo
        // About as many cells as polygons along the surface: side ~ extent / cbrt(n) × 2.
        let extent = max(size.x, size.y, size.z, 1e-3)
        cell = max(extent / max(8, pow(Double(polys.count), 1.0 / 3) * 2), 1e-3)
        stamp = [Int](repeating: -1, count: polys.count)
        for (i, box) in boxes.enumerated() {
            let c0 = key(box.lo), c1 = key(box.hi)
            for x in c0.x...c1.x { for y in c0.y...c1.y { for z in c0.z...c1.z { cells[SIMD3(x, y, z), default: []].append(i) } } }
        }
    }

    private func key(_ p: Vec3) -> SIMD3<Int32> {
        SIMD3(Int32(((p.x - bounds.lo.x) / cell).rounded(.down)), Int32(((p.y - bounds.lo.y) / cell).rounded(.down)),
              Int32(((p.z - bounds.lo.z) / cell).rounded(.down)))
    }

    /// Polygons whose boxes overlap `box` (each once).
    func candidates(_ box: Box) -> [Int] {
        guard box.overlaps(bounds, pad: 1e-6) else { return [] }
        query += 1
        let pad = Vec3(1e-6, 1e-6, 1e-6)
        let c0 = key(box.lo - pad), c1 = key(box.hi + pad)
        var out: [Int] = []
        for x in c0.x...c1.x { for y in c0.y...c1.y { for z in c0.z...c1.z {
            for i in cells[SIMD3(x, y, z)] ?? [] where stamp[i] != query {
                stamp[i] = query
                if boxes[i].overlaps(box, pad: 1e-6) { out.append(i) }
            }
        } } }
        return out
    }

    /// Point inside the closed solid (ray parity). nil when every direction tried grazes an edge
    /// or passes through the point's own surface.
    func contains(_ p: Vec3, polys: [CSGSolid.Polygon]) -> Bool? {
        guard p.x >= bounds.lo.x - 1e-9, p.x <= bounds.hi.x + 1e-9, p.y >= bounds.lo.y - 1e-9,
              p.y <= bounds.hi.y + 1e-9, p.z >= bounds.lo.z - 1e-9, p.z <= bounds.hi.z + 1e-9 else { return false }
        let directions = [Vec3(0.5773, 0.5774, 0.5775), Vec3(-0.6123, 0.3211, 0.7222), Vec3(0.2311, -0.8123, 0.5357),
                          Vec3(-0.4411, -0.5566, -0.7033), Vec3(0.9001, 0.1234, -0.4177)].map { $0.normalized }
        for d in directions {
            if let n = cast(p, d, polys) { return n % 2 == 1 }
        }
        return nil
    }

    /// Hits along the ray, nil if ambiguous (edge graze or origin on the surface).
    private func cast(_ o: Vec3, _ d: Vec3, _ polys: [CSGSolid.Polygon]) -> Int? {
        query += 1
        // Walk the grid cells the ray crosses (DDA).
        var c = key(o)
        let dv = [d.x, d.y, d.z], ov = [o.x - bounds.lo.x, o.y - bounds.lo.y, o.z - bounds.lo.z]
        var tMax = [Double](repeating: .infinity, count: 3), tDelta = tMax
        var step = SIMD3<Int32>(0, 0, 0)
        for k in 0..<3 where abs(dv[k]) > 1e-15 {
            step[k] = dv[k] > 0 ? 1 : -1
            let boundary = (Double(c[k]) + (dv[k] > 0 ? 1 : 0)) * cell
            tMax[k] = (boundary - ov[k]) / dv[k]
            tDelta[k] = cell / abs(dv[k])
        }
        let hiKey = key(bounds.hi)
        var hits = 0
        while true {
            for i in cells[c] ?? [] where stamp[i] != query {
                stamp[i] = query
                switch hit(o, d, polys[i]) {
                case .none: break
                case .hit: hits += 1
                case .ambiguous: return nil
                }
            }
            let k = tMax[0] < tMax[1] ? (tMax[0] < tMax[2] ? 0 : 2) : (tMax[1] < tMax[2] ? 1 : 2)
            c[k] += step[k]; tMax[k] += tDelta[k]
            if c[k] < -1 || c[k] > hiKey[k] + 1 { break }
        }
        return hits
    }

    private enum Hit { case none, hit, ambiguous }

    private func hit(_ o: Vec3, _ d: Vec3, _ p: CSGSolid.Polygon) -> Hit {
        let den = p.normal.dot(d)
        let dist = p.normal.dot(o) - p.w
        if abs(den) < 1e-12 { return abs(dist) < 1e-9 ? .ambiguous : .none }
        let t = -dist / den
        if t < -1e-9 { return .none }
        let x = o + d * t
        // Inside test with a margin: near an edge (or at the origin) the count is unreliable.
        var minEdge = Double.infinity
        for k in p.vertices.indices {
            let e0 = p.vertices[k], e1 = p.vertices[(k + 1) % p.vertices.count]
            let e = e1 - e0, len = e.length
            guard len > 1e-15 else { continue }
            let s = p.normal.dot(e.cross(x - e0)) / len
            minEdge = min(minEdge, s)
        }
        if minEdge < -1e-7 { return .none }
        if minEdge < 1e-7 || t < 1e-9 { return .ambiguous }
        return .hit
    }
}
