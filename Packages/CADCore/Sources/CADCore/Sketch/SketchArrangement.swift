import Foundation

// Faces of a sketch as Fusion finds its profiles: every curve (lines, rectangles, circles, arcs,
// open or closed) is split where it crosses another, and each bounded zone of the plane becomes a
// pickable face — two overlapping rectangles give three faces, a line across a circle two halves,
// lines and arcs that close on each other one face. Faces are identified by a point inside them
// (a "seed"), which survives edits well enough to re-find the face after the sketch changes.

public struct SketchFace: Sendable, Equatable {
    /// Counter-clockwise outer boundary.
    public let outline: [Vec2]
    /// Clockwise holes (other shapes lying inside).
    public let holes: [[Vec2]]
    /// A point strictly inside the face (outside its holes).
    public let seed: Vec2

    public var area: Double {
        Profile2D(points: outline).area - holes.reduce(0) { $0 + abs(Profile2D(points: $1).area) }
    }

    /// The point lies in the face (inside the outline, outside the holes).
    public func contains(_ p: Vec2) -> Bool {
        SketchArrangement.inside(p, outline) && !holes.contains { SketchArrangement.inside(p, $0) }
    }
}

public enum SketchArrangement {
    /// Point in polygon (even–odd).
    public static func inside(_ p: Vec2, _ polygon: [Vec2]) -> Bool { Graph.inside(p, polygon) }

    /// Faces of a set of curves (each a polyline; `closed` joins last to first).
    public static func faces(_ curves: [(points: [Vec2], closed: Bool)]) -> [SketchFace] {
        let graph = Graph(curves)
        return graph.faces()
    }

    /// Faces whose seeds are given, merged where they touch (a ring and the disc inside it make
    /// one full disc), as outline + holes ready to extrude.
    public static func merged(_ faces: [SketchFace], seeds: [Vec2], curves: [(points: [Vec2], closed: Bool)]) -> [SketchFace] {
        let graph = Graph(curves)
        let loops = graph.faceLoops()
        let chosen = Set(seeds.compactMap { s in graph.faceIndex(containing: s, loops: loops) })
        return chosen.isEmpty ? [] : graph.union(of: chosen, loops: loops)
    }

    // MARK: Planar graph

    struct Graph {
        var nodes: [Vec2] = []
        /// Undirected edges as node pairs (a < b).
        var edges: [(Int, Int)] = []
        let eps = 1e-6

        init(_ curves: [(points: [Vec2], closed: Bool)]) {
            // 1. Segments.
            var segs: [(Vec2, Vec2)] = []
            for c in curves where c.points.count >= 2 {
                let n = c.closed ? c.points.count : c.points.count - 1
                for i in 0..<n {
                    let a = c.points[i], b = c.points[(i + 1) % c.points.count]
                    if (a - b).length2 > eps * eps { segs.append((a, b)) }
                }
            }
            // 2. Split every segment at the points where others cross or touch it.
            var cuts = segs.map { _ in [Double]() }
            let boxes = segs.map { Box2($0.0, $0.1) }
            let index = GridIndex(boxes)
            for i in segs.indices {
                for j in index.candidates(boxes[i]) where j > i {
                    for (ti, tj) in intersections(segs[i], segs[j]) {
                        cuts[i].append(ti); cuts[j].append(tj)
                    }
                }
            }
            // 3. Nodes (welded) and edges.
            var lookup: [Key: Int] = [:]
            func node(_ p: Vec2) -> Int {
                let k = Key(p, eps)
                for dx in -1...1 { for dy in -1...1 {
                    if let i = lookup[Key(k.x + Int64(dx), k.y + Int64(dy))], (nodes[i] - p).length2 < 4 * eps * eps { return i }
                } }
                nodes.append(p); lookup[k] = nodes.count - 1
                return nodes.count - 1
            }
            var seen = Set<Pair>()
            for (i, (a, b)) in segs.enumerated() {
                let ts = ([0.0, 1.0] + cuts[i]).sorted()
                var prev = node(a)
                for t in ts.dropFirst() {
                    let n = node(a + (b - a) * t)
                    if n != prev, seen.insert(Pair(prev, n)).inserted { edges.append((min(prev, n), max(prev, n))) }
                    prev = n
                }
            }
            // 4. Dangling edges bound nothing: peel them off.
            var degree = [Int](repeating: 0, count: nodes.count)
            for (a, b) in edges { degree[a] += 1; degree[b] += 1 }
            var alive = [Bool](repeating: true, count: edges.count)
            var changed = true
            while changed {
                changed = false
                for (k, (a, b)) in edges.enumerated() where alive[k] && (degree[a] < 2 || degree[b] < 2) {
                    alive[k] = false; degree[a] -= 1; degree[b] -= 1; changed = true
                }
            }
            edges = edges.enumerated().filter { alive[$0.offset] }.map(\.element)
        }

        struct Key: Hashable {
            let x: Int64, y: Int64
            init(_ x: Int64, _ y: Int64) { self.x = x; self.y = y }
            init(_ p: Vec2, _ eps: Double) { x = Int64((p.x / (2 * eps)).rounded(.down)); y = Int64((p.y / (2 * eps)).rounded(.down)) }
        }
        struct Pair: Hashable {
            let a: Int, b: Int
            init(_ a: Int, _ b: Int) { self.a = min(a, b); self.b = max(a, b) }
        }

        /// Parameters (tA, tB) where two segments cross or touch (end points included).
        func intersections(_ s: (Vec2, Vec2), _ t: (Vec2, Vec2)) -> [(Double, Double)] {
            let p = s.0, r = s.1 - s.0, q = t.0, u = t.1 - t.0
            let den = r.cross(u)
            let lr = max(r.length2, 1e-30), lu = max(u.length2, 1e-30)
            if abs(den) < 1e-12 * (lr.squareRoot() * lu.squareRoot()) {
                // Parallel: overlapping collinear parts cut at each other's ends.
                guard abs((q - p).cross(r)) < eps * lr.squareRoot() else { return [] }
                var out: [(Double, Double)] = []
                for (pt, onS) in [(q, true), (t.1, true)] where onS {
                    let ts = (pt - p).dot(r) / lr
                    if ts > 1e-9, ts < 1 - 1e-9 { out.append((ts, pt == q ? 0 : 1)) }
                }
                for pt in [p, s.1] {
                    let tt = (pt - q).dot(u) / lu
                    if tt > 1e-9, tt < 1 - 1e-9 { out.append((pt == p ? 0 : 1, tt)) }
                }
                return out
            }
            let ts = (q - p).cross(u) / den, tt = (q - p).cross(r) / den
            let slackS = eps / lr.squareRoot(), slackT = eps / lu.squareRoot()
            guard ts > -slackS, ts < 1 + slackS, tt > -slackT, tt < 1 + slackT else { return [] }
            return [(min(max(ts, 0), 1), min(max(tt, 0), 1))]
        }

        // MARK: Faces

        /// Directed boundary cycles: bounded faces are counter-clockwise, the outer rims of connected
        /// pieces clockwise. Each directed edge is used once.
        func faceLoops() -> [[Int]] {
            var out: [[Int]] = []
            var adjacency = [[Int]](repeating: [], count: nodes.count)
            for (a, b) in edges { adjacency[a].append(b); adjacency[b].append(a) }
            // Neighbours sorted by angle around each node.
            for v in adjacency.indices {
                let c = nodes[v]
                adjacency[v].sort { atan2(nodes[$0].y - c.y, nodes[$0].x - c.x) < atan2(nodes[$1].y - c.y, nodes[$1].x - c.x) }
            }
            struct D: Hashable { let a: Int, b: Int }
            var used = Set<D>()
            for (a, b) in edges {
                for start in [D(a: a, b: b), D(a: b, b: a)] where !used.contains(start) {
                    var loop: [Int] = [], e = start
                    while !used.contains(e) {
                        used.insert(e); loop.append(e.a)
                        // Next: at e.b, the neighbour just clockwise from e.a (keeps the face on the left).
                        let around = adjacency[e.b]
                        guard let k = around.firstIndex(of: e.a) else { break }
                        let next = around[(k - 1 + around.count) % around.count]
                        e = D(a: e.b, b: next)
                        if loop.count > edges.count * 2 + 2 { break }
                    }
                    if loop.count >= 3 { out.append(loop) }
                }
            }
            return out
        }

        func points(_ loop: [Int]) -> [Vec2] { loop.map { nodes[$0] } }

        static func signedArea(_ p: [Vec2]) -> Double {
            var a = 0.0
            for i in p.indices { a += p[i].cross(p[(i + 1) % p.count]) }
            return a / 2
        }

        func faces() -> [SketchFace] {
            let loops = faceLoops()
            let bounded = loops.indices.filter { Self.signedArea(points(loops[$0])) > 1e-12 }
            let holes = holeMap(loops)
            return bounded.map { i in
                let outline = points(loops[i])
                let hs = (holes[i] ?? []).map { points(loops[$0]) }
                return SketchFace(outline: outline, holes: hs, seed: seed(outline, hs))
            }
        }

        /// Index of the bounded face (counter-clockwise loop) containing a point: the smallest one.
        func faceIndex(containing p: Vec2, loops: [[Int]]) -> Int? {
            var best: (Int, Double)?
            for (i, l) in loops.enumerated() {
                let pts = points(l)
                let a = Self.signedArea(pts)
                guard a > 1e-12, Self.inside(p, pts) else { continue }
                if a < (best?.1 ?? .infinity) { best = (i, a) }
            }
            return best?.0
        }

        /// For each bounded face, the outer rims (clockwise loops) of the pieces lying inside it:
        /// a probe just outside each rim (to its left) finds the face that holds it.
        func holeMap(_ loops: [[Int]]) -> [Int: [Int]] {
            var out: [Int: [Int]] = [:]
            for (r, l) in loops.enumerated() where Self.signedArea(points(l)) < -1e-12 {
                let a = nodes[l[0]], b = nodes[l[1]]
                let d = b - a, len = max(d.length, 1e-12)
                let probe = (a + b) * 0.5 + Vec2(-d.y / len, d.x / len) * (10 * eps)
                if let f = faceIndex(containing: probe, loops: loops) { out[f, default: []].append(r) }
            }
            return out
        }

        /// Outline + holes of the chosen faces, merged where they share edges (a ring and the disc
        /// inside it become one disc; a plate keeps its hole).
        func union(of chosen: Set<Int>, loops: [[Int]]) -> [SketchFace] {
            let holes = holeMap(loops)
            struct D: Hashable { let a: Int, b: Int }
            var directed = Set<D>()
            for i in chosen {
                for l in [loops[i]] + (holes[i] ?? []).map({ loops[$0] }) {
                    for k in l.indices { directed.insert(D(a: l[k], b: l[(k + 1) % l.count])) }
                }
            }
            let boundary = directed.filter { !directed.contains(D(a: $0.b, b: $0.a)) }
            var next: [Int: [Int]] = [:]
            for d in boundary { next[d.a, default: []].append(d.b) }
            var remaining = boundary
            var outer: [[Vec2]] = [], inner: [[Vec2]] = []
            while let start = remaining.first {
                var loop: [Int] = [], e = start
                while remaining.contains(e) {
                    remaining.remove(e); loop.append(e.a)
                    guard let options = next[e.b], let n = options.first(where: { remaining.contains(D(a: e.b, b: $0)) }) ?? options.first else { break }
                    e = D(a: e.b, b: n)
                }
                let pts = points(loop)
                guard pts.count >= 3 else { continue }
                if Self.signedArea(pts) > 0 { outer.append(pts) } else { inner.append(pts) }
            }
            return outer.map { o in
                // A hole goes to the smallest outline containing it.
                let own = inner.filter { h in
                    let probe = h[0]
                    let containing = outer.filter { Self.inside(probe, $0) || $0.contains(probe) }
                    return containing.min(by: { Self.signedArea($0) < Self.signedArea($1) }) == o
                }
                return SketchFace(outline: o, holes: own, seed: seed(o, own))
            }
        }

        /// A point inside the outline and outside the holes: a triangle centre of its triangulation.
        private func seed(_ outline: [Vec2], _ holes: [[Vec2]]) -> Vec2 {
            let tris = Profile2D(points: outline).triangulate(holes: holes.map { Profile2D(points: $0) })
            if let big = tris.max(by: { abs(($0.1 - $0.0).cross($0.2 - $0.0)) < abs(($1.1 - $1.0).cross($1.2 - $1.0)) }) {
                return (big.0 + big.1 + big.2) * (1.0 / 3)
            }
            return Self.centroid(outline)
        }

        static func centroid(_ p: [Vec2]) -> Vec2 { p.reduce(Vec2(0, 0), +) * (1 / Double(max(p.count, 1))) }
        static func nudge(_ p: [Vec2]) -> Vec2 { centroid(p) }

        static func inside(_ p: Vec2, _ poly: [Vec2]) -> Bool {
            var inside = false
            var j = poly.count - 1
            for i in poly.indices {
                let a = poly[i], b = poly[j]
                if (a.y > p.y) != (b.y > p.y), p.x < (b.x - a.x) * (p.y - a.y) / (b.y - a.y) + a.x { inside.toggle() }
                j = i
            }
            return inside
        }
    }

    struct Box2 {
        var lo: Vec2, hi: Vec2
        init(_ a: Vec2, _ b: Vec2) { lo = Vec2(min(a.x, b.x), min(a.y, b.y)); hi = Vec2(max(a.x, b.x), max(a.y, b.y)) }
        func overlaps(_ o: Box2, _ pad: Double) -> Bool {
            lo.x <= o.hi.x + pad && o.lo.x <= hi.x + pad && lo.y <= o.hi.y + pad && o.lo.y <= hi.y + pad
        }
    }

    /// Uniform grid over segment boxes.
    struct GridIndex {
        let boxes: [Box2]
        var cells: [Graph.Key: [Int]] = [:]
        let cell: Double
        init(_ boxes: [Box2]) {
            self.boxes = boxes
            var lo = Vec2(.infinity, .infinity), hi = Vec2(-.infinity, -.infinity)
            for b in boxes { lo = Vec2(min(lo.x, b.lo.x), min(lo.y, b.lo.y)); hi = Vec2(max(hi.x, b.hi.x), max(hi.y, b.hi.y)) }
            let extent = boxes.isEmpty ? 1 : max(hi.x - lo.x, hi.y - lo.y, 1e-3)
            cell = max(extent / max(4, Double(boxes.count).squareRoot()), 1e-3)
            // Boxes padded by the weld distance: an end a hair's breadth off a line (1e-15 below
            // it, as arc ends at 180° are) still meets it even across a cell border.
            let pad = 1e-6
            for (i, b) in boxes.enumerated() {
                for x in Int64(((b.lo.x - pad) / cell).rounded(.down))...Int64(((b.hi.x + pad) / cell).rounded(.down)) {
                    for y in Int64(((b.lo.y - pad) / cell).rounded(.down))...Int64(((b.hi.y + pad) / cell).rounded(.down)) { cells[Graph.Key(x, y), default: []].append(i) }
                }
            }
        }
        func candidates(_ b: Box2) -> [Int] {
            var out = Set<Int>()
            for x in Int64((b.lo.x / cell).rounded(.down))...Int64((b.hi.x / cell).rounded(.down)) {
                for y in Int64((b.lo.y / cell).rounded(.down))...Int64((b.hi.y / cell).rounded(.down)) {
                    for i in cells[Graph.Key(x, y)] ?? [] where boxes[i].overlaps(b, 1e-6) { out.insert(i) }
                }
            }
            return Array(out)
        }
    }
}

extension Vec2 {
    public var length2: Double { x * x + y * y }
    public var length: Double { length2.squareRoot() }
    public func dot(_ o: Vec2) -> Double { x * o.x + y * o.y }
}

extension Sketch {
    /// Every non-construction curve of the sketch, as the arrangement sees it.
    public var curves: [(points: [Vec2], closed: Bool)] {
        shapes.filter { !$0.isConstruction && $0.outline.count >= 2 }.map { ($0.outline, $0.isClosed) }
    }

    /// Pickable faces (profiles) of the sketch.
    public var faces: [SketchFace] { SketchArrangement.faces(curves) }

    /// The face under a point (the smallest containing it, outside its holes).
    public func face(at p: Vec2, in faces: [SketchFace]? = nil) -> SketchFace? {
        (faces ?? self.faces).filter { SketchArrangement.Graph.inside(p, $0.outline) && !$0.holes.contains { SketchArrangement.Graph.inside(p, $0) } }
            .min { $0.area < $1.area }
    }

    /// Faces picked by points inside them, merged where they touch, ready to extrude.
    public func areas(seeds: [Vec2]) -> [SketchFace] {
        SketchArrangement.merged([], seeds: seeds, curves: curves)
    }
}
