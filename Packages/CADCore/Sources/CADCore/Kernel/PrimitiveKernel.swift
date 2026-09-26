import Foundation

/// First kernel slice: explicit topology for boxes, faceted cylinders and simple
/// XY profile extrusions. Does not infer topology by comparing triangle normals.
public enum PrimitiveKernel {
    public static func build(_ feature: Feature, cylinderSegments: Int = 64) throws -> BRepBody {
        guard let placement = feature.placement else { return try buildLocal(feature, cylinderSegments: cylinderSegments) }
        // Built at the origin in the plane's frame, then carried onto the plane (and position).
        var local = feature
        local.placement = nil
        local.position = .zero
        let body = try buildLocal(local, cylinderSegments: cylinderSegments)
        let height: Double = switch feature.kind {
        case let .box(_, _, h), let .cylinder(_, h), let .extrude(_, h): h
        default: 0
        }
        return try body.placed(on: placement.plane, depthOffset: placement.reversed ? -height : 0, translation: feature.position)
    }

    private static func buildLocal(_ feature: Feature, cylinderSegments: Int) throws -> BRepBody {
        guard feature.position.isFinite,
              [feature.position.x, feature.position.y, feature.position.z].allSatisfy({ abs($0) <= 100_000 }) else {
            throw KernelError.invalidParameter("posizione oltre ±100000 mm o non finita")
        }
        let points: [Vec2], height: Double, family: String, profileKey: String
        let radius: Double?
        switch feature.kind {
        case let .box(width, depth, h):
            try dimension(width); try dimension(depth); try dimension(h)
            points = Profile2D.rectangle(width: width, height: depth).points
            height = h; family = "box"; profileKey = "box"; radius = nil
        case let .cylinder(r, h):
            try dimension(r); try dimension(h)
            guard (3...512).contains(cylinderSegments) else {
                throw KernelError.invalidParameter("cilindro: 3–512 segmenti")
            }
            points = Profile2D.circle(radius: r, segments: cylinderSegments).points
            height = h; family = "cylinder"; profileKey = "cylinder/\(cylinderSegments)"; radius = r
        case let .hole(spec):
            try spec.validate()
            throw KernelError.invalidParameter("il foro è un taglio: viene calcolato dal valutatore")
        case let .sheetMetal(spec):
            _ = try spec.rule()
            throw KernelError.invalidParameter("la lamiera viene calcolata dal valutatore")
        case .component:
            throw KernelError.invalidParameter("il componente viene letto dal suo file dal valutatore")
        case .importedMesh:
            throw KernelError.invalidParameter("la mesh importata viene preparata dal valutatore")
        case .split:
            throw KernelError.invalidParameter("la divisione agisce su un corpo: viene calcolata dal valutatore")
        case let .pattern(spec):
            try spec.validate()
            throw KernelError.invalidParameter("la serie copia un corpo: viene calcolata dal valutatore")
        case let .chamfer(spec):
            try spec.validate()
            throw KernelError.invalidParameter("lo smusso modifica un corpo esistente: viene calcolato dal valutatore")
        case let .extrude(profile, h):
            try dimension(h)
            guard (3...128).contains(profile.points.count) else {
                throw KernelError.invalidProfile("richiesti 3–128 vertici, senza fori")
            }
            points = Profile2D(points: profile.points).points
            height = h; family = "extrude"; radius = nil
            // v1 profiles have no entity IDs. Conservatively invalidate side/edge IDs
            // on ANY profile edit instead of silently binding a different segment.
            // Exact bit patterns avoid hash collisions and remain stable across processes.
            profileKey = "extrude/" + points.map {
                String($0.x.bitPattern, radix: 16) + ":" + String($0.y.bitPattern, radix: 16)
            }.joined(separator: ",")
        }
        try validateProfile(points)
        let profile = Profile2D(points: points)
        let capTriangles = profile.triangulate()
        guard capTriangles.count == points.count - 2 else {
            throw KernelError.invalidProfile("triangolazione incompleta")
        }
        let n = points.count, prefix = feature.id.uuidString.lowercased() + "/"
        // Sides of an extruded profile that approximate an arc (sketch circles, slot ends) make one
        // cylindrical wall with one rim edge top and bottom, like the cylinder primitive: fillets,
        // chamfers and selection take the whole arc, and the wall renders smooth.
        let arcs: [ProfileArc?] = family == "extrude" ? profileArcs(points) : Array(repeating: nil, count: n)
        func faceID(_ role: String) -> FaceID { FaceID(rawValue: prefix + role) }
        func edgeID(_ role: String) -> EdgeID { EdgeID(rawValue: prefix + role) }
        let positions = points.map { Vec3($0.x, $0.y, 0) + feature.position }
            + points.map { Vec3($0.x, $0.y, height) + feature.position }
        let vertices = positions.enumerated().map { i, p in
            BRepVertex(id: VertexID(rawValue: prefix + profileKey + "/\(i < n ? "bottom" : "top")/vertex/\(i % n)"), position: p)
        }
        let bottomID = faceID(family + "/bottom"), topID = faceID(family + "/top")
        var loops = [Array((0..<n).reversed()), Array(n..<(2 * n))]
        var ids = [bottomID, topID], selectionIDs = ids
        var surfaces: [SurfaceDescriptor] = [
            .plane(origin: positions[0], normal: Vec3(0, 0, -1)),
            .plane(origin: positions[n], normal: Vec3(0, 0, 1))
        ]
        var triangles: [[UInt32]] = [
            capTriangles.flatMap { [UInt32($0.0), UInt32($0.2), UInt32($0.1)] },
            capTriangles.flatMap { [UInt32($0.0 + n), UInt32($0.1 + n), UInt32($0.2 + n)] }
        ]
        for i in 0..<n {
            let j = (i + 1) % n
            loops.append([i, j, j + n, i + n])
            let sideID = faceID(profileKey + "/side/\(i)")
            ids.append(sideID)
            let normal = (positions[j] - positions[i]).cross(positions[i + n] - positions[i]).normalized
            if let radius {
                selectionIDs.append(faceID("cylinder/wall"))
                surfaces.append(.cylinder(axisOrigin: feature.position, axisDirection: Vec3(0, 0, 1), radius: radius))
            } else if let arc = arcs[i] {
                selectionIDs.append(faceID(profileKey + "/arc/\(arc.index)/wall"))
                surfaces.append(.cylinder(axisOrigin: Vec3(arc.center.x, arc.center.y, 0) + feature.position,
                                          axisDirection: Vec3(0, 0, 1), radius: arc.radius))
            } else {
                selectionIDs.append(sideID)
                surfaces.append(.plane(origin: positions[i], normal: normal))
            }
            triangles.append([UInt32(i), UInt32(j), UInt32(j + n), UInt32(i), UInt32(j + n), UInt32(i + n)])
        }

        // Edges originate from profile roles, independent from tessellation order.
        struct EdgeKey: Hashable {
            let a: Int, b: Int
            init(_ a: Int, _ b: Int) { self.a = min(a, b); self.b = max(a, b) }
        }
        var edgeLookup: [EdgeKey: Int] = [:]
        var endpoints: [(Int, Int)] = []
        var edgeIDs: [EdgeID] = [], selectedEdges: [EdgeID?] = []
        for level in 0..<3 {
            for i in 0..<n {
                let j = (i + 1) % n
                let pair = level == 0 ? (i, j) : level == 1 ? (i + n, j + n) : (i, i + n)
                let role = ["bottom", "top", "vertical"][level]
                let id = edgeID(profileKey + "/edge/\(role)/\(i)")
                edgeLookup[EdgeKey(pair.0, pair.1)] = endpoints.count
                endpoints.append(pair); edgeIDs.append(id)
                if radius != nil {
                    selectedEdges.append(level == 2 ? nil : edgeID("cylinder/rim/\(role)"))
                } else if level < 2, let arc = arcs[i] {
                    selectedEdges.append(edgeID(profileKey + "/arc/\(arc.index)/rim/\(role)"))
                } else if level == 2, smoothJoint((i + n - 1) % n, points, arcs) {
                    selectedEdges.append(nil)   // inside an arc or where it runs tangent into a line
                } else {
                    selectedEdges.append(id)
                }
            }
        }
        struct Use { let origin: Int, destination: Int, edge: Int, face: Int, next: Int }
        var uses: [Use] = [], edgeUses = [[Int]](repeating: [], count: endpoints.count)
        var faces: [BRepFace] = []
        for (f, loop) in loops.enumerated() {
            let first = uses.count
            for k in loop.indices {
                let a = loop[k], b = loop[(k + 1) % loop.count]
                guard let edge = edgeLookup[EdgeKey(a, b)] else { throw KernelError.invalidTopology("spigolo mancante") }
                edgeUses[edge].append(uses.count)
                uses.append(Use(origin: a, destination: b, edge: edge, face: f, next: first + (k + 1) % loop.count))
            }
            let origin = positions[loop[0]]
            let normal = f == 0 ? Vec3(0, 0, -1) : f == 1 ? Vec3(0, 0, 1)
                : (positions[loop[1]] - origin).cross(positions[loop[2]] - origin).normalized
            faces.append(BRepFace(id: ids[f], halfEdges: Array(first..<uses.count), origin: origin,
                                  normal: normal, selectionID: selectionIDs[f], sourceSurface: surfaces[f]))
        }
        guard edgeUses.allSatisfy({ $0.count == 2 }) else { throw KernelError.invalidTopology("spigolo aperto o non manifold") }
        let halfEdges = uses.enumerated().map { h, use in
            BRepHalfEdge(origin: use.origin, destination: use.destination, edge: use.edge,
                         face: use.face, next: use.next, twin: edgeUses[use.edge].first { $0 != h }!)
        }
        let edges = endpoints.enumerated().map { e, pair in
            BRepEdge(id: edgeIDs[e], startVertex: pair.0, endVertex: pair.1,
                     halfEdges: edgeUses[e], selectionID: selectedEdges[e])
        }
        let body = BRepBody(id: feature.id, vertices: vertices, edges: edges, halfEdges: halfEdges, faces: faces,
                            maximumSurfaceDeviation: radius.map { $0 * (1 - cos(.pi / Double(n))) }
                                ?? arcs.compactMap { $0.map { $0.radius * (1 - cos($0.step / 2)) } }.max() ?? 0,
                            faceTriangles: triangles)
        try body.validate()
        return body
    }

    struct ProfileArc: Equatable {
        /// Which arc of the profile (0, 1… in profile order).
        let index: Int
        let center: Vec2
        let radius: Double
        /// Angle subtended by one side.
        let step: Double
    }

    /// Per side of the profile (side i runs from point i to i + 1): the arc it approximates, if any.
    /// An arc is 5+ consecutive co-circular vertices with sides of at most 20°, so regular polygons
    /// (hexagons…) stay flat-sided while sketch circles and slot ends (64 per turn) are arcs.
    static func profileArcs(_ p: [Vec2]) -> [ProfileArc?] {
        let n = p.count
        guard n >= 4 else { return Array(repeating: nil, count: n) }
        func at(_ i: Int) -> Vec2 { p[((i % n) + n) % n] }
        // Circle through a vertex and its two neighbours.
        func circle(_ i: Int) -> (c: Vec2, r: Double)? {
            let a = at(i - 1), b = at(i), c = at(i + 1)
            let d = 2 * (a.x * (b.y - c.y) + b.x * (c.y - a.y) + c.x * (a.y - b.y))
            guard abs(d) > 1e-12 else { return nil }
            let a2 = a.x * a.x + a.y * a.y, b2 = b.x * b.x + b.y * b.y, c2 = c.x * c.x + c.y * c.y
            let o = Vec2((a2 * (b.y - c.y) + b2 * (c.y - a.y) + c2 * (a.y - b.y)) / d,
                         (a2 * (c.x - b.x) + b2 * (a.x - c.x) + c2 * (b.x - a.x)) / d)
            let r = ((b - o).x * (b - o).x + (b - o).y * (b - o).y).squareRoot()
            guard r.isFinite, r < 1e6 else { return nil }
            return (o, r)
        }
        func same(_ u: (c: Vec2, r: Double), _ v: (c: Vec2, r: Double)) -> Bool {
            let tol = 1e-6 * max(1, u.r)
            return abs(u.r - v.r) <= tol && abs(u.c.x - v.c.x) <= tol && abs(u.c.y - v.c.y) <= tol
        }
        func onCircle(_ q: Vec2, _ c: (c: Vec2, r: Double)) -> Bool {
            abs(((q - c.c).x * (q - c.c).x + (q - c.c).y * (q - c.c).y).squareRoot() - c.r) <= 1e-6 * max(1, c.r)
        }
        func angle(_ i: Int, _ c: (c: Vec2, r: Double)) -> Double {
            let l = ((at(i + 1) - at(i)).x * (at(i + 1) - at(i)).x + (at(i + 1) - at(i)).y * (at(i + 1) - at(i)).y).squareRoot()
            return 2 * asin(min(1, l / (2 * c.r)))
        }
        let maxStep = 20 * Double.pi / 180
        let circles = (0..<n).map { circle($0) }
        // A vertex is inside an arc when its circle agrees with both neighbours' (5 co-circular points:
        // 4 are not enough, a line between two mirrored arc ends is co-circular with them).
        let arcVertex: [Bool] = (0..<n).map { i in
            guard let c = circles[i] else { return false }
            return [circles[(i + n - 1) % n], circles[(i + 1) % n]].allSatisfy { $0.map { same($0, c) } ?? false }
        }
        let sideCircle: [(c: Vec2, r: Double)?] = (0..<n).map { i in
            let j = (i + 1) % n
            for v in [i, j, (i + n - 1) % n, (i + 2) % n] where arcVertex[v] {
                let c = circles[v]!
                if onCircle(p[i], c), onCircle(p[j], c), angle(i, c) <= maxStep + 1e-9 { return c }
            }
            return nil
        }
        // Group consecutive sides on the same circle; a lone side is not an arc.
        var out = [ProfileArc?](repeating: nil, count: n)
        let start = (0..<n).first { i in sideCircle[i] == nil || sideCircle[(i + n - 1) % n].map { !same($0, sideCircle[i]!) } ?? true }
        guard let first = start else {
            // Every side on one circle: a full circle.
            let c = sideCircle[0]!
            return (0..<n).map { i in ProfileArc(index: 0, center: c.c, radius: c.r, step: angle(i, c)) }
        }
        var index = 0
        var k = 0
        while k < n {
            let i = (first + k) % n
            guard let c = sideCircle[i] else { k += 1; continue }
            var run = [i]
            while run.count < n, let next = sideCircle[(run.last! + 1) % n], same(next, c) { run.append((run.last! + 1) % n) }
            if run.count >= 2 {
                for s in run { out[s] = ProfileArc(index: index, center: c.c, radius: c.r, step: angle(s, c)) }
                index += 1
            }
            k += run.count
        }
        return out
    }

    /// Vertical edge at profile vertex i + 1 (between sides i and i + 1) is not a crease: both sides on
    /// the same arc, or an arc meeting a side along its tangent.
    private static func smoothJoint(_ i: Int, _ p: [Vec2], _ arcs: [ProfileArc?]) -> Bool {
        let n = p.count, j = (i + 1) % n
        let a = arcs[i], b = arcs[j]
        if let a, let b, a.index == b.index { return true }
        guard let arc = a ?? b else { return false }
        let u = p[j] - p[i], v = p[(j + 1) % n] - p[j]
        let turn = abs(atan2(u.cross(v), u.x * v.x + u.y * v.y))
        return turn <= arc.step * 0.6 + 1e-9
    }

    private static func dimension(_ value: Double) throws {
        guard value.isFinite && (0.01...100_000).contains(value) else {
            throw KernelError.invalidParameter("dimensione: 0,01–100000 mm")
        }
    }

    private static func validateProfile(_ p: [Vec2]) throws {
        guard p.allSatisfy({ $0.x.isFinite && $0.y.isFinite && abs($0.x) <= 100_000 && abs($0.y) <= 100_000 }) else {
            throw KernelError.invalidProfile("coordinate oltre ±100000 mm o non finite")
        }
        let n = p.count
        for i in 0..<n {
            let a = p[i], b = p[(i + 1) % n], c = p[(i + 2) % n]
            guard abs((b - a).cross(c - b)) > 1e-10 else {
                throw KernelError.invalidProfile("vertici coincidenti o consecutivi allineati")
            }
            for j in (i + 1)..<n where j != (i + 1) % n && (j + 1) % n != i {
                if intersects(a, b, p[j], p[(j + 1) % n]) {
                    throw KernelError.invalidProfile("contorno autointersecante o a contatto")
                }
            }
        }
        guard Profile2D(points: p).area > 1e-10 else { throw KernelError.invalidProfile("area nulla") }
    }

    private static func intersects(_ a: Vec2, _ b: Vec2, _ c: Vec2, _ d: Vec2) -> Bool {
        let x = (b - a).cross(c - a), y = (b - a).cross(d - a)
        let z = (d - c).cross(a - c), w = (d - c).cross(b - c)
        func on(_ a: Vec2, _ b: Vec2, _ p: Vec2, _ cross: Double) -> Bool {
            abs(cross) <= 1e-10 && p.x >= min(a.x, b.x) - 1e-9 && p.x <= max(a.x, b.x) + 1e-9
                && p.y >= min(a.y, b.y) - 1e-9 && p.y <= max(a.y, b.y) + 1e-9
        }
        return (x * y < 0 && z * w < 0) || on(a, b, c, x) || on(a, b, d, y) || on(c, d, a, z) || on(c, d, b, w)
    }
}

extension BRepBody {
    /// The body carried from its local frame (XY, +Z) onto a sketch plane: a proper rigid motion,
    /// so orientation, IDs and validity are kept. `depthOffset` shifts along the normal first.
    func placed(on plane: SketchPlane, depthOffset: Double, translation: Vec3) throws -> BRepBody {
        let n = plane.normal
        func point(_ v: Vec3) -> Vec3 { plane.origin + plane.xAxis * v.x + plane.yAxis * v.y + n * (v.z + depthOffset) + translation }
        func direction(_ v: Vec3) -> Vec3 { plane.xAxis * v.x + plane.yAxis * v.y + n * v.z }
        func surface(_ s: SurfaceDescriptor) -> SurfaceDescriptor {
            switch s {
            case let .plane(o, nn): .plane(origin: point(o), normal: direction(nn))
            case let .cylinder(o, a, r): .cylinder(axisOrigin: point(o), axisDirection: direction(a), radius: r)
            case let .cone(apex, a, h): .cone(apex: point(apex), axisDirection: direction(a), halfAngle: h)
            case .freeform: .freeform
            case let .torus(c, a, R, r): .torus(center: point(c), axisDirection: direction(a), majorRadius: R, minorRadius: r)
            }
        }
        let body = BRepBody(id: id, vertices: vertices.map { BRepVertex(id: $0.id, position: point($0.position)) },
                            edges: edges, halfEdges: halfEdges,
                            faces: faces.map { f in
                                BRepFace(id: f.id, halfEdges: f.halfEdges, origin: point(f.origin), normal: direction(f.normal),
                                         selectionID: f.selectionID, sourceSurface: surface(f.sourceSurface))
                            },
                            maximumSurfaceDeviation: maximumSurfaceDeviation, faceTriangles: faceTriangles)
        try body.validate()
        return body
    }
}

extension Profile2D {
    /// What the profile is made of, as a designer sees it: "Cerchio Ø22", "2 linee, 2 archi",
    /// "4 linee" (a sketch circle is one entity, not its 64 vertices).
    public var entitiesDescription: String {
        let arcs = PrimitiveKernel.profileArcs(points)
        func mm(_ v: Double) -> String {
            var s = String(format: "%.2f", v)
            while s.hasSuffix("0") { s.removeLast() }
            if s.hasSuffix(".") { s.removeLast() }
            return s.replacingOccurrences(of: ".", with: ",")
        }
        if let first = arcs.first ?? nil, arcs.allSatisfy({ $0?.index == first.index }) { return "Cerchio Ø\(mm(2 * first.radius))" }
        let arcCount = Set(arcs.compactMap { $0?.index }).count, lines = arcs.filter { $0 == nil }.count
        var parts: [String] = []
        if lines > 0 { parts.append("\(lines) line\(lines == 1 ? "a" : "e")") }
        if arcCount > 0 { parts.append("\(arcCount) arc\(arcCount == 1 ? "o" : "hi")") }
        return parts.joined(separator: ", ")
    }
}
