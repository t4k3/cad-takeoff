import Foundation

// STEP with exact geometry where the part has it: planes, and cylinders (holes, bosses, round
// walls) bounded by true circles and straight lines. A curved face whose edges do not all lie on
// it (a round meeting a freeform corner) is written as its facets, and its neighbours then share
// straight edges with it. OpenCascade reads the result as valid solids.

/// A curved surface the STEP writes exactly.
enum ExactSurface {
    case cylinder(origin: Vec3, axis: Vec3, radius: Double)
    case cone(apex: Vec3, axis: Vec3, half: Double)
    case torus(center: Vec3, axis: Vec3, major: Double, minor: Double)
    case sphere(center: Vec3, radius: Double)

    init?(_ s: SurfaceDescriptor) {
        switch s {
        case let .cylinder(o, a, r): self = .cylinder(origin: o, axis: a.normalized, radius: r)
        case let .cone(apex, a, h) where h > 1e-6 && h < .pi / 2 - 1e-6: self = .cone(apex: apex, axis: a.normalized, half: h)
        case let .torus(c, a, R, r) where R > r + 1e-9 && r > 1e-9: self = .torus(center: c, axis: a.normalized, major: R, minor: r)
        case let .sphere(c, r) where r > 1e-9: self = .sphere(center: c, radius: r)
        default: return nil
        }
    }

    var axis: Vec3 {
        switch self { case let .cylinder(_, a, _), let .cone(_, a, _), let .torus(_, a, _, _): a; case .sphere: Vec3(0, 0, 1) }
    }
    var origin: Vec3 {
        switch self { case let .cylinder(o, _, _): o; case let .cone(apex, _, _): apex; case let .torus(c, _, _, _), let .sphere(c, _): c }
    }
    /// Distance off the surface (approximate, mm).
    func distance(_ p: Vec3) -> Double {
        let q = p - origin, h = q.dot(axis), rho = (q - axis * h).length
        switch self {
        case let .cylinder(_, _, r): return abs(rho - r)
        case let .cone(_, _, half): return abs(rho * cos(half) - h * sin(half))
        case let .torus(_, _, R, r): return abs(((rho - R) * (rho - R) + h * h).squareRoot() - r)
        case let .sphere(_, r): return abs(q.length - r)
        }
    }
    /// The surface's own normal direction (STEP: away from the axis, away from the tube).
    func normal(at p: Vec3) -> Vec3 {
        let q = p - origin, h = q.dot(axis), radial = q - axis * h
        switch self {
        case .cylinder, .cone: return radial
        case let .torus(_, _, R, _): return q - radial.normalized * R
        case .sphere: return q
        }
    }
    /// Whether a straight edge from p to q lies on the surface (a cylinder's or cone's generator).
    func holdsLine(_ p: Vec3, _ q: Vec3) -> Bool {
        let d = (q - p).normalized
        switch self {
        case .cylinder: return abs(d.dot(axis)) > 1 - 1e-9
        case let .cone(apex, _, _):
            let w = apex - p
            return (w - d * w.dot(d)).length < 1e-5
        case .torus, .sphere: return false
        }
    }
    /// Whether a circle lies on the surface (a parallel: square to the axis, centred on it).
    func holdsCircle(center c: Vec3, normal n: Vec3, radius r: Double, sample: Vec3) -> Bool {
        let off = c - origin
        if case .sphere = self {
            // Any circle of the sphere: its centre on the line from the sphere's centre along n.
            guard off.length < 1e-5 || abs(n.dot(off.normalized)) > 1 - 1e-9 else { return false }
            return distance(sample) < 1e-5 * max(1, r)
        }
        guard abs(n.dot(axis)) > 1 - 1e-9, (off - axis * off.dot(axis)).length < 1e-5 else { return false }
        return distance(sample) < 1e-5 * max(1, r)
    }
    func entity(_ w: inout STEPExporter.Writer) -> String {
        let helper = abs(axis.z) < 0.9 ? Vec3(0, 0, 1) : Vec3(1, 0, 0)
        let ref = helper.cross(axis).normalized
        switch self {
        case let .cylinder(o, a, r):
            return w.add("CYLINDRICAL_SURFACE('',\(w.placement(o, normal: a, reference: ref)),\(w.real(r)))")
        case let .cone(apex, a, half):
            // Placed one millimetre from the apex, where the radius is tan(half).
            return w.add("CONICAL_SURFACE('',\(w.placement(apex + a, normal: a, reference: ref)),\(w.real(tan(half))),\(w.real(half)))")
        case let .torus(c, a, R, r):
            return w.add("TOROIDAL_SURFACE('',\(w.placement(c, normal: a, reference: ref)),\(w.real(R)),\(w.real(r)))")
        case let .sphere(c, r):
            return w.add("SPHERICAL_SURFACE('',\(w.placement(c, normal: Vec3(0, 0, 1), reference: Vec3(1, 0, 0))),\(w.real(r)))")
        }
    }
}

extension STEPExporter {
    struct ExactFailure: Error { var at = 0 }

    static func exactSolid(_ part: Part, into w: inout Writer) throws -> String {
        let s = part.snapshot
        // 1. Shared vertices and valid triangles.
        var index: [SIMD3<Int64>: Int] = [:]
        var points: [Vec3] = []
        func key(_ p: Vec3) -> SIMD3<Int64> { SIMD3(Int64((p.x * 1e7).rounded()), Int64((p.y * 1e7).rounded()), Int64((p.z * 1e7).rounded())) }
        let corner = s.triangles.map { i -> Int in
            let p = s.positions[Int(i)], k = key(p)
            if let v = index[k] { return v }
            points.append(p); index[k] = points.count - 1
            return points.count - 1
        }
        var tris: [(v: [Int], face: Int, normal: Vec3)] = []
        for t in 0..<(corner.count / 3) {
            let v = [corner[t * 3], corner[t * 3 + 1], corner[t * 3 + 2]]
            guard Set(v).count == 3 else { continue }
            let n = (points[v[1]] - points[v[0]]).cross(points[v[2]] - points[v[0]])
            guard n.length > 1e-14 else { continue }
            tris.append((v, Int(s.triangleFace[t]), n.normalized))
        }
        struct E: Hashable { let a: Int, b: Int; init(_ x: Int, _ y: Int) { a = min(x, y); b = max(x, y) } }
        var edgeTris: [E: [Int]] = [:]
        for (t, tri) in tris.enumerated() { for k in 0..<3 { edgeTris[E(tri.v[k], tri.v[(k + 1) % 3]), default: []].append(t) } }
        guard edgeTris.values.allSatisfy({ $0.count == 2 }) else { throw ExactFailure(at: 1) }

        func curved(_ f: Int) -> ExactSurface? { ExactSurface(s.faces[f].surface) }
        func isPlane(_ f: Int) -> Bool { if case .plane = s.faces[f].surface { true } else { false } }
        let tol = 1e-6
        // 2. Which faces are written exactly (planes always; cylinders while their edges allow).
        var exact = Set(s.faces.indices.filter { isPlane($0) || curved($0) != nil })
        struct PK: Hashable { let face: Int; let plane: SIMD4<Int64> }
        func piece(_ t: Int) -> PK {
            let tri = tris[t]
            if exact.contains(tri.face) { return PK(face: tri.face, plane: .zero) }
            let n = tri.normal, d = n.dot(points[tri.v[0]])
            return PK(face: tri.face, plane: SIMD4(Int64((n.x * 1e5).rounded()), Int64((n.y * 1e5).rounded()), Int64((n.z * 1e5).rounded()), Int64((d * 1e4).rounded())))
        }

        struct Chain { var points: [Int]; var closed: Bool; var pieces: (PK, PK) }
        func chains(_ pieceOf: [PK]) -> [Chain] {
            var groups: [[PK]: [E]] = [:]
            var piecesAt = [Set<PK>](repeating: [], count: points.count)
            for (t, tri) in tris.enumerated() { for v in tri.v { piecesAt[v].insert(pieceOf[t]) } }
            for (e, ts) in edgeTris where pieceOf[ts[0]] != pieceOf[ts[1]] {
                let pair = [pieceOf[ts[0]], pieceOf[ts[1]]].sorted { "\($0)" < "\($1)" }
                groups[pair, default: []].append(e)
            }
            var out: [Chain] = []
            for (pair, edges) in groups {
                var adj: [Int: [Int]] = [:]
                for e in edges { adj[e.a, default: []].append(e.b); adj[e.b, default: []].append(e.a) }
                let corner = Set(adj.keys.filter { adj[$0]!.count != 2 || piecesAt[$0].count >= 3 })
                var used = Set<E>()
                func walk(from start: Int, via first: Int) -> [Int] {
                    var path = [start, first]
                    used.insert(E(start, first))
                    var at = first
                    while !corner.contains(at), let next = adj[at]!.first(where: { !used.contains(E(at, $0)) }) {
                        used.insert(E(at, next)); path.append(next); at = next
                        if at == start { break }
                    }
                    return path
                }
                for c in corner.sorted() { for n in adj[c]! where !used.contains(E(c, n)) {
                    out.append(Chain(points: walk(from: c, via: n), closed: false, pieces: (pair[0], pair[1])))
                } }
                // Loops with no corner (a full rim): start anywhere.
                for v in adj.keys.sorted() { for n in adj[v]! where !used.contains(E(v, n)) {
                    var path = walk(from: v, via: n)
                    let closed = path.last == path.first
                    if closed { path.removeLast() }
                    out.append(Chain(points: path, closed: closed, pieces: (pair[0], pair[1])))
                } }
            }
            return out
        }

        // The chain without points lying on the straight piece between their neighbours (the
        // booleans add such points on the facets' chords; they are not on the circle).
        func corners(_ ids: [Int], closed: Bool) -> [Int] {
            var kept = ids
            var removed = true
            while removed, kept.count > 3 {
                removed = false
                var i = closed ? 0 : 1
                while i < (closed ? kept.count : kept.count - 1), kept.count > 3 {
                    let a = points[kept[(i + kept.count - 1) % kept.count]], b = points[kept[(i + 1) % kept.count]], q = points[kept[i]]
                    let d = b - a, l = d.length
                    if l > 1e-12, ((q - a) - d * ((q - a).dot(d) / (l * l))).length < tol * max(1, l) { kept.remove(at: i); removed = true } else { i += 1 }
                }
            }
            return kept
        }
        // Circle through a chain (3D), nil when it is not one.
        func circle(_ all: [Int], closed: Bool) -> (c: Vec3, n: Vec3, r: Double)? {
            let ids = corners(all, closed: closed)
            guard ids.count >= 3 else { return nil }
            let p = ids.map { points[$0] }
            var n = Vec3.zero
            for i in p.indices { let a = p[i], b = p[(i + 1) % p.count]; n = n + Vec3((a.y - b.y) * (a.z + b.z), (a.z - b.z) * (a.x + b.x), (a.x - b.x) * (a.y + b.y)) }
            guard n.length > 1e-12 else { return nil }
            n = n.normalized
            let c0 = p.reduce(Vec3.zero, +) * (1 / Double(p.count))
            guard p.allSatisfy({ abs(($0 - c0).dot(n)) < tol * max(1, ($0 - c0).length) + tol }) else { return nil }
            let helper = abs(n.z) < 0.9 ? Vec3(0, 0, 1) : Vec3(1, 0, 0)
            let u = helper.cross(n).normalized, v = n.cross(u)
            guard let fit = PrimitiveKernel.fit(p.map { Vec2(($0 - c0).dot(u), ($0 - c0).dot(v)) }) else { return nil }
            let c = c0 + u * fit.c.x + v * fit.c.y
            guard p.allSatisfy({ abs(($0 - c).length - fit.r) < tol * max(1, fit.r) + tol }) else { return nil }
            // Not a circle when the points only span a sliver of it with a large radius (a line).
            guard fit.r < 1e5 else { return nil }
            return (c, n, fit.r)
        }
        func straight(_ ids: [Int]) -> Bool {
            guard ids.count >= 2 else { return false }
            let a = points[ids.first!], b = points[ids.last!], d = b - a
            guard d.length > 1e-12 else { return false }
            return ids.allSatisfy { let q = points[$0] - a; return (q - d.normalized * q.dot(d.normalized)).length < tol * max(1, d.length) }
        }

        // 3. Settle the exact cylinders: every edge on the surface, as a circle or an axis line.
        var pieceOf = tris.indices.map(piece)
        var found = chains(pieceOf)
        var changed = true
        while changed {
            changed = false
            for f in exact {
                guard let surface = curved(f) else { continue }
                let fine = found.allSatisfy { ch in
                    guard ch.pieces.0.face == f || ch.pieces.1.face == f else { return true }
                    let other = ch.pieces.0.face == f ? ch.pieces.1.face : ch.pieces.0.face
                    let keyPoints = corners(ch.points, closed: ch.closed)
                    guard keyPoints.allSatisfy({ surface.distance(points[$0]) < 1e-5 * max(1, points[$0].length * 1e-3) + 1e-5 }) else { return false }
                    if !ch.closed, straight(ch.points), surface.holdsLine(points[ch.points.first!], points[ch.points.last!]) { return true }
                    guard exact.contains(other), let c = circle(ch.points, closed: ch.closed) else { return false }
                    return surface.holdsCircle(center: c.c, normal: c.n, radius: c.r, sample: points[keyPoints[0]])
                }
                if !fine { exact.remove(f); changed = true }
            }
            if changed { pieceOf = tris.indices.map(piece); found = chains(pieceOf) }
        }

        // 4. Curves: circles between exact faces, one line for a straight run, else segments.
        struct CurveEdge { let start: Int, end: Int; let entity: String }
        var vertexIDs: [Int: String] = [:]
        func vertex(_ v: Int) -> String {
            if let id = vertexIDs[v] { return id }
            let id = w.add("VERTEX_POINT('',\(w.point(points[v])))")
            vertexIDs[v] = id
            return id
        }
        struct DE: Hashable { let a: Int, b: Int }
        var byMeshEdge: [DE: (edge: Int, forward: Bool)] = [:]
        var curves: [CurveEdge] = []
        func line(_ a: Int, _ b: Int) -> String {
            let p = points[a], q = points[b]
            return w.add("LINE('',\(w.point(p)),\(w.add("VECTOR('',\(w.direction((q - p).normalized)),\(w.real((q - p).length)))")))")
        }
        for ch in found {
            let ids = ch.points
            let bothExact = exact.contains(ch.pieces.0.face) && exact.contains(ch.pieces.1.face)
                && ch.pieces.0.plane == .zero && ch.pieces.1.plane == .zero
            func register(_ path: [Int], closed: Bool, entity: String) {
                let k = curves.count
                curves.append(CurveEdge(start: path[0], end: closed ? path[0] : path.last!, entity: entity))
                let seq = closed ? path + [path[0]] : path
                for i in 0..<(seq.count - 1) {
                    byMeshEdge[DE(a: seq[i], b: seq[i + 1])] = (k, true)
                    byMeshEdge[DE(a: seq[i + 1], b: seq[i])] = (k, false)
                }
            }
            if bothExact, let c = circle(ids, closed: ch.closed) {
                let ref = (points[ids[0]] - c.c).normalized
                let geometry = w.add("CIRCLE('',\(w.placement(c.c, normal: c.n, reference: ref)),\(w.real(c.r)))")
                let end = ch.closed ? ids[0] : ids.last!
                register(ids, closed: ch.closed, entity: w.add("EDGE_CURVE('',\(vertex(ids[0])),\(vertex(end)),\(geometry),.T.)"))
            } else if !ch.closed, straight(ids) {
                register(ids, closed: false, entity: w.add("EDGE_CURVE('',\(vertex(ids[0])),\(vertex(ids.last!)),\(line(ids[0], ids.last!)),.T.)"))
            } else {
                let seq = ch.closed ? ids + [ids[0]] : ids
                for i in 0..<(seq.count - 1) {
                    register([seq[i], seq[i + 1]], closed: false,
                             entity: w.add("EDGE_CURVE('',\(vertex(seq[i])),\(vertex(seq[i + 1])),\(line(seq[i], seq[i + 1])),.T.)"))
                }
            }
        }

        // 5. Faces: each connected piece with its loops of oriented curve edges.
        var groups: [PK: [Int]] = [:], order: [PK] = []
        for t in tris.indices { let k = pieceOf[t]; if groups[k] == nil { order.append(k) }; groups[k, default: []].append(t) }
        var faces: [String] = []
        for pk in order {
            // Connected parts of the piece.
            var component = [Int: Int](), parts: [[Int]] = []
            for seed in groups[pk]! where component[seed] == nil {
                var stack = [seed], part: [Int] = []
                component[seed] = parts.count
                while let t = stack.popLast() {
                    part.append(t)
                    for k in 0..<3 {
                        let e = E(tris[t].v[k], tris[t].v[(k + 1) % 3])
                        for u in edgeTris[e]! where u != t && pieceOf[u] == pk && component[u] == nil { component[u] = parts.count; stack.append(u) }
                    }
                }
                parts.append(part)
            }
            for part in parts {
                let inPart = Set(part)
                var next: [Int: [Int]] = [:]
                for t in part {
                    for k in 0..<3 {
                        let a = tris[t].v[k], b = tris[t].v[(k + 1) % 3]
                        let across = edgeTris[E(a, b)]!.first { $0 != t }!
                        if !inPart.contains(across) { next[a, default: []].append(b) }
                    }
                }
                var loops: [[DE]] = []
                while let start = next.keys.sorted().first {
                    var loop: [DE] = [], at = start
                    repeat {
                        guard var outs = next[at], let to = outs.popLast() else { throw ExactFailure(at: 2) }
                        next[at] = outs.isEmpty ? nil : outs
                        loop.append(DE(a: at, b: to)); at = to
                        if loop.count > points.count + 2 { throw ExactFailure(at: 3) }
                    } while at != start
                    loops.append(loop)
                }
                // Loops as oriented curve edges, starting where a curve edge starts.
                var bounds: [(entity: String, points: [Int])] = []
                for loop in loops {
                    guard let first = loop.firstIndex(where: { de in
                        guard let m = byMeshEdge[de] else { return false }
                        let c = curves[m.edge]
                        return de.a == (m.forward ? c.start : c.end)
                    }) else { throw ExactFailure(at: 4) }
                    let rotated = Array(loop[first...] + loop[..<first])
                    var oriented: [String] = []
                    var last: (Int, Bool)?
                    for de in rotated {
                        guard let m = byMeshEdge[de] else { throw ExactFailure(at: 5) }
                        let c = curves[m.edge]
                        if let l = last, l.0 == m.edge, l.1 == m.forward, de.a != (m.forward ? c.start : c.end) { continue }
                        oriented.append(w.add("ORIENTED_EDGE('',*,*,\(c.entity),\(m.forward ? ".T." : ".F."))"))
                        last = (m.edge, m.forward)
                    }
                    bounds.append((w.add("EDGE_LOOP('',(\(oriented.joined(separator: ","))))"), rotated.map(\.a)))
                }
                guard !bounds.isEmpty else { continue }
                // Surface and its sense (outward normal from the triangles).
                var n = Vec3.zero
                for t in part { let v = tris[t].v; n = n + (points[v[1]] - points[v[0]]).cross(points[v[2]] - points[v[0]]) }
                let surface: String, sense: Bool
                var outer: Int? = nil
                if pk.plane == .zero, let exactSurface = curved(pk.face) {
                    surface = exactSurface.entity(&w)
                    // Outward (from the triangles) against the surface's own normal, summed over the face.
                    var agree = 0.0
                    for t in part {
                        let c = (points[tris[t].v[0]] + points[tris[t].v[1]] + points[tris[t].v[2]]) * (1.0 / 3)
                        agree += tris[t].normal.dot(exactSurface.normal(at: c).normalized)
                    }
                    sense = agree > 0
                } else {
                    let normal = n.normalized
                    let helper = abs(normal.z) < 0.9 ? Vec3(0, 0, 1) : Vec3(1, 0, 0)
                    let u = helper.cross(normal).normalized, v = normal.cross(u)
                    surface = w.add("PLANE('',\(w.placement(points[bounds[0].points[0]], normal: normal, reference: u)))")
                    sense = true
                    // The outline: the loop of largest area (a connected region has one).
                    func area(_ ids: [Int]) -> Double {
                        let p = ids.map { Vec2(points[$0].dot(u), points[$0].dot(v)) }
                        var a = 0.0
                        for i in p.indices { let q = p[i], r = p[(i + 1) % p.count]; a += q.x * r.y - r.x * q.y }
                        return a / 2
                    }
                    outer = bounds.indices.max { area(bounds[$0].points) < area(bounds[$1].points) }
                }
                let entries = bounds.indices.map { i in
                    w.add("\(i == outer ? "FACE_OUTER_BOUND" : "FACE_BOUND")('',\(bounds[i].entity),.T.)")
                }
                faces.append(w.add("ADVANCED_FACE('',(\(entries.joined(separator: ","))),\(surface),\(sense ? ".T." : ".F."))"))
            }
        }
        guard !faces.isEmpty else { throw ExactFailure(at: 6) }
        let shell = w.add("CLOSED_SHELL('',(\(faces.joined(separator: ","))))")
        return w.add("MANIFOLD_SOLID_BREP(\(w.text(part.name)),\(shell))")
    }
}
