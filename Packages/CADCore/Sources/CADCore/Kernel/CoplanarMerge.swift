import Foundation

/// Re-triangulates the BSP fragments of one planar face as a single polygon (with holes).
///
/// Booleans chop every face into many convex fragments; kept as they are, a plate with one
/// hole and a bevel becomes ~16k triangles and every later operation gets slower. The shared
/// inner edges cancel out, leaving the face's boundary loops; every boundary vertex is kept
/// (neighbouring faces use them), so the mesh stays closed. Any doubt → nil (caller keeps the
/// fragments).
enum CoplanarMerge {
    /// Tests can compare with the raw fragments.
    nonisolated(unsafe) static var isEnabled = true
    static func triangulate(_ loops: [[UInt32]], _ positions: [Vec3], normal: Vec3) -> [(UInt32, UInt32, UInt32)]? {
        guard loops.count > 1 else { return nil }
        // 1. Boundary = directed edges without their reverse.
        struct E: Hashable { let a: UInt32, b: UInt32 }
        var count: [E: Int] = [:]
        for l in loops {
            for k in l.indices { count[E(a: l[k], b: l[(k + 1) % l.count]), default: 0] += 1 }
        }
        var next: [UInt32: [UInt32]] = [:]
        for (e, n) in count {
            let back = count[E(a: e.b, b: e.a)] ?? 0
            for _ in 0..<max(0, n - back) { next[e.a, default: []].append(e.b) }
        }
        guard !next.isEmpty, next.values.allSatisfy({ $0.count == 1 }) else { return nil }   // pinch points: leave as is
        // 2. Trace loops.
        var remaining = next.mapValues { $0[0] }
        var boundary: [[UInt32]] = []
        while let start = remaining.keys.min() {
            var loop = [start], cur = start
            while let n = remaining.removeValue(forKey: cur) {
                if n == start { break }
                loop.append(n); cur = n
                guard loop.count <= positions.count else { return nil }
            }
            guard loop.count >= 3, cur != start || loop.count == 1 else { return nil }
            boundary.append(loop)
        }
        // 3. 2D frame of the face.
        let n = normal.normalized
        let helper = abs(n.z) < 0.9 ? Vec3(0, 0, 1) : Vec3(1, 0, 0)
        let u = helper.cross(n).normalized, v = n.cross(u)
        func p2(_ i: UInt32) -> (Double, Double) { let p = positions[Int(i)]; return (p.dot(u), p.dot(v)) }
        func area(_ l: [UInt32]) -> Double {
            var s = 0.0
            for k in l.indices { let a = p2(l[k]), b = p2(l[(k + 1) % l.count]); s += a.0 * b.1 - b.0 * a.1 }
            return s / 2
        }
        var outers: [[UInt32]] = [], holes: [[UInt32]] = []
        for l in boundary { let a = area(l); if a > 1e-12 { outers.append(l) } else if a < -1e-12 { holes.append(l) } else { return nil } }
        guard !outers.isEmpty else { return nil }
        // 4. Holes into their outer loop.
        func inside(_ p: (Double, Double), _ l: [UInt32]) -> Bool {
            var c = false
            for k in l.indices {
                let a = p2(l[k]), b = p2(l[(k + 1) % l.count])
                if (a.1 > p.1) != (b.1 > p.1), p.0 < (b.0 - a.0) * (p.1 - a.1) / (b.1 - a.1) + a.0 { c.toggle() }
            }
            return c
        }
        var groups = outers.map { ($0, [[UInt32]]()) }
        for h in holes {
            // A point just inside the hole's first edge (off the boundary) decides the owner.
            let a = p2(h[0]), b = p2(h[1])
            let probe = ((a.0 + b.0) / 2, (a.1 + b.1) / 2)
            let owners = groups.indices.filter { inside(probe, groups[$0].0) }
            guard owners.count == 1 else { return nil }
            groups[owners[0]].1.append(h)
        }
        var out: [(UInt32, UInt32, UInt32)] = []
        for (outer, hs) in groups {
            guard let polygon = bridged(outer, hs, p2), let tris = earClip(polygon, p2) else { return nil }
            out += tris
        }
        // 5. Same area as the fragments, or it went wrong.
        let fragments = loops.reduce(0.0) { $0 + area($1) }
        let merged = out.reduce(0.0) { $0 + area([$1.0, $1.1, $1.2]) }
        guard abs(fragments - merged) <= 1e-7 * max(1, abs(fragments)) else { return nil }
        return out
    }

    /// Joins each hole to the outer loop with a two-way cut, rightmost hole first.
    private static func bridged(_ outer: [UInt32], _ holes: [[UInt32]], _ p2: (UInt32) -> (Double, Double)) -> [UInt32]? {
        var poly = outer
        let ordered = holes.sorted { ($0.map { p2($0).0 }.max() ?? 0) > ($1.map { p2($0).0 }.max() ?? 0) }
        for hole in ordered {
            guard let hi = hole.indices.max(by: { p2(hole[$0]).0 < p2(hole[$1]).0 }) else { return nil }
            let h = p2(hole[hi])
            // Segments that the bridge must not cross: current polygon and all holes.
            var segments: [((Double, Double), (Double, Double))] = []
            for l in [poly] + holes { for k in l.indices { segments.append((p2(l[k]), p2(l[(k + 1) % l.count]))) } }
            let candidates = poly.indices.sorted {
                let a = p2(poly[$0]), b = p2(poly[$1])
                return hypot(a.0 - h.0, a.1 - h.1) < hypot(b.0 - h.0, b.1 - h.1)
            }
            var chosen: Int?
            for c in candidates {
                let o = p2(poly[c])
                if segments.allSatisfy({ !properlyCrosses(h, o, $0.0, $0.1) }) { chosen = c; break }
            }
            guard let c = chosen else { return nil }
            let rotated = Array(hole[hi...] + hole[..<hi])
            poly = Array(poly[...c]) + rotated + [rotated[0], poly[c]] + Array(poly[(c + 1)...])
        }
        return poly
    }

    private static func properlyCrosses(_ a: (Double, Double), _ b: (Double, Double), _ c: (Double, Double), _ d: (Double, Double)) -> Bool {
        func cross(_ o: (Double, Double), _ p: (Double, Double), _ q: (Double, Double)) -> Double {
            (p.0 - o.0) * (q.1 - o.1) - (p.1 - o.1) * (q.0 - o.0)
        }
        // Shared endpoints are allowed (the bridge starts/ends on vertices).
        let same = { (p: (Double, Double), q: (Double, Double)) in abs(p.0 - q.0) < 1e-12 && abs(p.1 - q.1) < 1e-12 }
        if same(a, c) || same(a, d) || same(b, c) || same(b, d) { return false }
        let d1 = cross(c, d, a), d2 = cross(c, d, b), d3 = cross(a, b, c), d4 = cross(a, b, d)
        if ((d1 > 1e-12 && d2 < -1e-12) || (d1 < -1e-12 && d2 > 1e-12)) && ((d3 > 1e-12 && d4 < -1e-12) || (d3 < -1e-12 && d4 > 1e-12)) { return true }
        // Touching the bridge at an interior point also blocks it.
        func onSegment(_ p: (Double, Double), _ s: (Double, Double), _ e: (Double, Double)) -> Bool {
            abs(cross(s, e, p)) < 1e-12 && min(s.0, e.0) - 1e-12 <= p.0 && p.0 <= max(s.0, e.0) + 1e-12
                && min(s.1, e.1) - 1e-12 <= p.1 && p.1 <= max(s.1, e.1) + 1e-12
        }
        return onSegment(c, a, b) || onSegment(d, a, b)
    }

    /// Ear clipping of a counter-clockwise polygon (bridge vertices may repeat).
    private static func earClip(_ polygon: [UInt32], _ p2: (UInt32) -> (Double, Double)) -> [(UInt32, UInt32, UInt32)]? {
        var idx = Array(polygon.indices)
        var out: [(UInt32, UInt32, UInt32)] = []
        func cross(_ o: (Double, Double), _ a: (Double, Double), _ b: (Double, Double)) -> Double {
            (a.0 - o.0) * (b.1 - o.1) - (a.1 - o.1) * (b.0 - o.0)
        }
        /// Clearly left turn: the sine of the corner angle, not the raw area, so three nearly
        /// aligned points (rounding noise) never make a sliver that the mesh would later drop.
        func convex(_ a: (Double, Double), _ b: (Double, Double), _ c: (Double, Double)) -> Bool {
            let lab = hypot(b.0 - a.0, b.1 - a.1), lbc = hypot(c.0 - b.0, c.1 - b.1)
            return cross(a, b, c) > max(1e-9 * lab * lbc, 2e-12)
        }
        var guardCount = 0
        while idx.count > 3 {
            guardCount += 1
            guard guardCount < 4 * polygon.count * polygon.count + 100 else { return nil }
            var clipped = false
            for k in idx.indices {
                let i0 = idx[(k + idx.count - 1) % idx.count], i1 = idx[k], i2 = idx[(k + 1) % idx.count]
                let a = p2(polygon[i0]), b = p2(polygon[i1]), c = p2(polygon[i2])
                guard convex(a, b, c) else { continue }   // reflex or flat
                var blocked = false
                for j in idx where j != i0 && j != i1 && j != i2 {
                    let id = polygon[j]
                    if id == polygon[i0] || id == polygon[i1] || id == polygon[i2] { continue }
                    let p = p2(id)
                    if cross(a, b, p) >= -1e-14 && cross(b, c, p) >= -1e-14 && cross(c, a, p) >= -1e-14 { blocked = true; break }
                }
                if blocked { continue }
                out.append((polygon[i0], polygon[i1], polygon[i2]))
                idx.remove(at: k)
                clipped = true
                break
            }
            if !clipped { return nil }
        }
        let a = p2(polygon[idx[0]]), b = p2(polygon[idx[1]]), c = p2(polygon[idx[2]])
        // A flat leftover would leave boundary edges unused (an open mesh): give up instead.
        guard convex(a, b, c) else { return nil }
        out.append((polygon[idx[0]], polygon[idx[1]], polygon[idx[2]]))
        return out
    }
}
