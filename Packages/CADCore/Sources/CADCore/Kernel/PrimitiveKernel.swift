import Foundation

/// First kernel slice: explicit topology for boxes, faceted cylinders and simple
/// XY profile extrusions. Does not infer topology by comparing triangle normals.
public enum PrimitiveKernel {
    public static func build(_ feature: Feature, cylinderSegments: Int = 64) throws -> BRepBody {
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
            selectionIDs.append(radius == nil ? sideID : faceID("cylinder/wall"))
            let normal = (positions[j] - positions[i]).cross(positions[i + n] - positions[i]).normalized
            if let radius {
                surfaces.append(.cylinder(axisOrigin: feature.position, axisDirection: Vec3(0, 0, 1), radius: radius))
            } else { surfaces.append(.plane(origin: positions[i], normal: normal)) }
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
                selectedEdges.append(radius == nil ? id : (level == 2 ? nil : edgeID("cylinder/rim/\(role)")))
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
                            maximumSurfaceDeviation: radius.map { $0 * (1 - cos(.pi / Double(n))) } ?? 0,
                            faceTriangles: triangles)
        try body.validate()
        return body
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
