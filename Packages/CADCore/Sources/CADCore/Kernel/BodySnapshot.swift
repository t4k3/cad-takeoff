import Foundation

public struct FaceInfo: Equatable, Sendable {
    public let id: FaceID
    public let surface: SurfaceDescriptor
    /// Actual tessellated area in mm², including for a cylindrical source surface.
    public let area: Double
    public let topologyFaceIDs: [FaceID]
}

public struct EdgeInfo: Equatable, Sendable {
    public let id: EdgeID
    /// Ordered world-space polyline; closed curves repeat the first point.
    public let polyline: [Vec3]
    public let isSharp: Bool
    /// Two distinct selection-face IDs on the currently supported closed bodies.
    public let faces: [FaceID]
    public let topologyEdgeIDs: [EdgeID]
    /// Its true curve where the two surfaces describe one (a line, a circle); nil: only the polyline.
    public var curve: EdgeCurve? = nil

    public var length: Double {
        zip(polyline, polyline.dropFirst()).reduce(0) { $0 + ($1.1 - $1.0).length }
    }
}

/// Renderer contract. All coordinates/normals remain in CAD world space (mm, Z up).
/// Positions are split per triangle for shading; use BRepBody.mesh for welded export.
public struct BodySnapshot: Equatable, Sendable {
    public let bodyID: UUID
    public let revision: String
    public let positions: [Vec3]
    public let normals: [Vec3]
    public let triangles: [UInt32]
    /// One index in `faces` per triangle, not per vertex or triangle index.
    public let triangleFace: [UInt32]
    /// Underlying planar B-rep face for each triangle, before semantic grouping.
    public let triangleTopologyFace: [FaceID]
    public let faces: [FaceInfo]
    public let edges: [EdgeInfo]
    public let maximumSurfaceDeviation: Double
}

extension BRepBody {
    public func snapshot(revision: String) -> BodySnapshot {
        var positions: [Vec3] = [], normals: [Vec3] = [], triangles: [UInt32] = []
        var triangleFace: [UInt32] = [], triangleTopologyFace: [FaceID] = []
        var faceOrder: [FaceID] = [], lookup: [FaceID: Int] = [:]
        var surfaces: [SurfaceDescriptor] = [], areas: [Double] = [], members: [[FaceID]] = []
        for (f, face) in faces.enumerated() {
            let group: Int
            if let existing = lookup[face.selectionID] { group = existing }
            else {
                group = faceOrder.count; lookup[face.selectionID] = group
                faceOrder.append(face.selectionID); surfaces.append(face.sourceSurface)
                areas.append(0); members.append([])
            }
            members[group].append(face.id)
            let indices = faceTriangles[f]
            for t in stride(from: 0, to: indices.count, by: 3) {
                let points = (0..<3).map { vertices[Int(indices[t + $0])].position }
                areas[group] += (points[1] - points[0]).cross(points[2] - points[0]).length / 2
                for point in points {
                    triangles.append(UInt32(positions.count)); positions.append(point)
                    switch face.sourceSurface {
                    case .plane:
                        normals.append(face.normal)
                    case let .cylinder(origin, axis, _):
                        let relative = point - origin
                        normals.append((relative - axis * relative.dot(axis)).normalized)
                    case let .sphere(c, _):
                        normals.append((point - c).normalized)
                    case .cone, .torus, .freeform:
                        normals.append(face.normal)
                    }
                }
                triangleFace.append(UInt32(group)); triangleTopologyFace.append(face.id)
            }
        }
        let faceInfo = faceOrder.enumerated().map { i, id in
            FaceInfo(id: id, surface: surfaces[i], area: areas[i], topologyFaceIDs: members[i])
        }
        var edgeOrder: [EdgeID] = [], edgeGroups: [EdgeID: [BRepEdge]] = [:]
        for edge in edges {
            guard let id = edge.selectionID else { continue }
            if edgeGroups[id] == nil { edgeOrder.append(id) }
            edgeGroups[id, default: []].append(edge)
        }
        let edgeInfo = edgeOrder.map { id -> EdgeInfo in
            var remaining = edgeGroups[id]!
            let topologyIDs = remaining.map(\.id)
            let first = remaining.removeFirst()
            var chain = [first.startVertex, first.endVertex]
            // Each current semantic group is a single edge or one cylinder rim; its pieces are
            // chained from either end (an arc may run across the profile's first vertex).
            while !remaining.isEmpty {
                let end = chain.last!, start = chain.first!
                if let i = remaining.firstIndex(where: { $0.startVertex == end || $0.endVertex == end }) {
                    let edge = remaining.remove(at: i)
                    chain.append(edge.startVertex == end ? edge.endVertex : edge.startVertex)
                } else if let i = remaining.firstIndex(where: { $0.startVertex == start || $0.endVertex == start }) {
                    let edge = remaining.remove(at: i)
                    chain.insert(edge.startVertex == start ? edge.endVertex : edge.startVertex, at: 0)
                } else {
                    assertionFailure("PrimitiveKernel generated a disconnected semantic edge")
                    break
                }
            }
            let adjacent = first.halfEdges.map { faces[halfEdges[$0].face].selectionID }
            let polyline = chain.map { vertices[$0].position }
            let sides = first.halfEdges.map { faces[halfEdges[$0].face].sourceSurface }
            return EdgeInfo(id: id, polyline: polyline, isSharp: true, faces: adjacent, topologyEdgeIDs: topologyIDs,
                            curve: sides.count == 2 ? EdgeCurve.between(sides[0], sides[1], polyline: polyline) : nil)
        }
        return BodySnapshot(bodyID: id, revision: revision, positions: positions, normals: normals,
                            triangles: triangles, triangleFace: triangleFace, triangleTopologyFace: triangleTopologyFace,
                            faces: faceInfo, edges: edgeInfo, maximumSurfaceDeviation: maximumSurfaceDeviation)
    }
}

extension BodySnapshot {
    /// Tangent chain (Fusion's "Tangent chain"): the edge plus every edge reached through ends where
    /// the curve carries on smoothly (≤ `maxAngle` degrees between the end directions), e.g. the
    /// lines and arcs around a slot's top. Closed edges (a full rim) are their own chain.
    public func tangentChain(of id: EdgeID, maxAngle: Double = 12) -> [EdgeID] {
        guard let start = edges.first(where: { $0.id == id }) else { return [] }
        let cosMax = cos(maxAngle * .pi / 180)
        let tol = 1e-6
        func ends(_ e: EdgeInfo) -> [(point: Vec3, outward: Vec3)] {
            let p = e.polyline
            guard p.count >= 2, let first = p.first, let last = p.last, (last - first).length > tol else { return [] }
            return [(first, (p[0] - p[1]).normalized), (last, (p[p.count - 1] - p[p.count - 2]).normalized)]
        }
        var chain = [start.id], seen: Set<EdgeID> = [start.id], queue = [start]
        while let e = queue.popLast() {
            for end in ends(e) {
                for other in edges where !seen.contains(other.id) {
                    // Joined here, and the other edge leaves the joint straight on (opposite outward directions).
                    guard ends(other).contains(where: { ($0.point - end.point).length <= tol && -$0.outward.dot(end.outward) >= cosMax }) else { continue }
                    seen.insert(other.id); chain.append(other.id); queue.append(other)
                }
            }
        }
        return chain
    }
}

extension BodySnapshot {
    /// The same faces and edges, one level finer, for the screen: every triangle is split at its
    /// midpoints and the new points are put back on the exact surface (and on the exact circle of
    /// each edge) its face describes, with the normals of the surface. Booleans and the history do
    /// not run again, and no name changes: only the facets. Faces without an exact description
    /// (imported meshes) keep their triangles; flat faces are refined only where a circular edge
    /// makes the cap and the wall meet on a curve.
    public func refined() -> BodySnapshot {
        guard !triangles.isEmpty, triangles.count % 3 == 0 else { return self }

        struct Segment: Hashable {
            let low: Int, high: Int
            init(_ a: Int, _ b: Int) { low = min(a, b); high = max(a, b) }
        }
        /// Positions that meet exactly on screen (a wall and its cap) are the same vertex.
        struct Key: Hashable {
            let x: Int64, y: Int64, z: Int64
            init(_ p: Vec3) {
                x = Int64((p.x * 1e6).rounded()); y = Int64((p.y * 1e6).rounded()); z = Int64((p.z * 1e6).rounded())
            }
        }

        var lookup: [Key: Int] = [:], welded: [Vec3] = [], indices: [Int] = []
        indices.reserveCapacity(positions.count)
        for p in positions {
            let key = Key(p)
            if let i = lookup[key] { indices.append(i) }
            else { let i = welded.count; welded.append(p); lookup[key] = i; indices.append(i) }
        }

        // The face groups on each segment, to tell a face's own diagonals from its borders.
        var segmentGroups: [Segment: [UInt32]] = [:]
        for t in 0..<(triangles.count / 3) {
            let g = triangleFace[t]
            let a = indices[t * 3], b = indices[t * 3 + 1], c = indices[t * 3 + 2]
            for (i, j) in [(a, b), (b, c), (c, a)] where i != j {
                let s = Segment(i, j)
                var groups = segmentGroups[s] ?? []
                if !groups.contains(g) { groups.append(g); segmentGroups[s] = groups }
            }
        }

        // Edges whose true curve is a circle, per segment: caps and walls then meet on the arc.
        var segmentCurves: [Segment: EdgeCurve] = [:]
        for e in edges {
            guard let curve = e.curve, case .circle = curve else { continue }
            for (p, q) in zip(e.polyline, e.polyline.dropFirst()) {
                guard let i = lookup[Key(p)], let j = lookup[Key(q)], i != j else { continue }
                segmentCurves[Segment(i, j)] = curve
            }
        }

        // Flat faces are refined only where a round edge meets them; imported meshes never.
        var roundBorders: Set<Int> = []
        for e in edges {
            guard let curve = e.curve, case .circle = curve else { continue }
            for id in e.faces {
                if let g = faces.firstIndex(where: { $0.id == id }) { roundBorders.insert(g) }
            }
        }
        func refines(_ group: Int) -> Bool {
            switch faces[group].surface {
            case .plane: roundBorders.contains(group)
            case .freeform: false
            case .cylinder, .cone, .torus, .sphere: true
            }
        }

        func onSurface(_ p: Vec3, _ s: SurfaceDescriptor) -> Vec3 {
            switch s {
            case .plane, .freeform:
                return p
            case let .cylinder(o, a, r):
                let axis = a.normalized, v = p - o, radial = v - axis * v.dot(axis)
                guard radial.length > 1e-12 else { return p }
                return o + radial.normalized * r + axis * v.dot(axis)
            case let .cone(apex, a, half):
                let axis = a.normalized, v = p - apex, h = v.dot(axis), radial = v - axis * h
                guard h > 1e-9, radial.length > 1e-12 else { return p }
                return apex + axis * h + radial.normalized * (h * tan(half))
            case let .sphere(c, r):
                let v = p - c
                guard v.length > 1e-12 else { return p }
                return c + v.normalized * r
            case let .torus(c, a, major, minor):
                let axis = a.normalized, v = p - c, axial = axis * v.dot(axis), radial = v - axial
                guard radial.length > 1e-12 else { return p }
                let tube = c + axial + radial.normalized * major
                let w = p - tube
                guard w.length > 1e-12 else { return p }
                return tube + w.normalized * minor
            }
        }

        // The surface normal, oriented like the facet it belongs to (the kernel's outward normal).
        func normalAt(_ p: Vec3, _ s: SurfaceDescriptor, flat: Vec3) -> Vec3 {
            let n: Vec3?
            switch s {
            case .plane, .freeform:
                n = nil
            case let .cylinder(o, a, _):
                let axis = a.normalized, v = p - o, radial = v - axis * v.dot(axis)
                n = radial.length > 1e-12 ? radial.normalized : nil
            case let .cone(apex, a, half):
                let axis = a.normalized, v = p - apex, h = v.dot(axis), radial = v - axis * h
                n = radial.length > 1e-12 ? (radial.normalized - axis * tan(half)).normalized : nil
            case let .sphere(c, _):
                n = (p - c).length > 1e-12 ? (p - c).normalized : nil
            case let .torus(c, a, major, _):
                let axis = a.normalized, v = p - c, axial = axis * v.dot(axis), radial = v - axial
                let tube = c + axial + radial.normalized * major
                n = radial.length > 1e-12 && (p - tube).length > 1e-12 ? (p - tube).normalized : nil
            }
            guard let n else { return flat }
            return n.dot(flat) < 0 ? -n : n
        }

        var midpoints: [Segment: Vec3] = [:]
        func midpoint(_ i: Int, _ j: Int, surface: SurfaceDescriptor) -> Vec3 {
            let s = Segment(i, j)
            if let m = midpoints[s] { return m }
            let middle = (welded[i] + welded[j]) * 0.5
            let p: Vec3
            if let curve = segmentCurves[s] {
                // A border on a known circle: the arc, not the chord (and the same for both faces).
                p = curve.closest(middle)
            } else if let groups = segmentGroups[s], groups.count == 1 {
                // A diagonal inside one face: put it back on that face's surface.
                p = onSurface(middle, surface)
            } else {
                // A border between two faces with no exact curve: both use the straight midpoint.
                p = middle
            }
            midpoints[s] = p
            return p
        }

        var outPositions: [Vec3] = [], outNormals: [Vec3] = [], outTriangles: [UInt32] = []
        var outFace: [UInt32] = [], outTopology: [FaceID] = []
        outPositions.reserveCapacity(positions.count * 4); outNormals.reserveCapacity(normals.count * 4)
        outTriangles.reserveCapacity(triangles.count * 4)
        outFace.reserveCapacity(triangleFace.count * 4); outTopology.reserveCapacity(triangleTopologyFace.count * 4)

        func emit(_ a: Vec3, _ b: Vec3, _ c: Vec3, flat: Vec3, surface: SurfaceDescriptor,
                  group: UInt32, topology: FaceID) {
            for p in [a, b, c] {
                outTriangles.append(UInt32(outPositions.count))
                outPositions.append(p)
                outNormals.append(normalAt(p, surface, flat: flat))
            }
            outFace.append(group); outTopology.append(topology)
        }

        for t in 0..<(triangles.count / 3) {
            let group = Int(triangleFace[t])
            let topology = triangleTopologyFace[t]
            let surface = faces[group].surface
            let flat = normals[t * 3]
            let (ia, ib, ic) = (indices[t * 3], indices[t * 3 + 1], indices[t * 3 + 2])
            let (a, b, c) = (positions[t * 3], positions[t * 3 + 1], positions[t * 3 + 2])
            guard refines(group) else {
                emit(a, b, c, flat: flat, surface: surface, group: triangleFace[t], topology: topology)
                continue
            }
            let (ab, bc, ca) = (midpoint(ia, ib, surface: surface), midpoint(ib, ic, surface: surface),
                                midpoint(ic, ia, surface: surface))
            let children = [(a, ab, ca), (ab, b, bc), (ca, bc, c), (ab, bc, ca)]
            for (p, q, r) in children where (q - p).cross(r - p).length > 1e-18 {
                emit(p, q, r, flat: flat, surface: surface, group: triangleFace[t], topology: topology)
            }
        }

        let refinedEdges = edges.map { e -> EdgeInfo in
            guard let curve = e.curve, case .circle = curve, e.polyline.count > 1 else { return e }
            var points: [Vec3] = []
            points.reserveCapacity(e.polyline.count * 2)
            for (k, p) in e.polyline.enumerated() {
                points.append(p)
                guard k + 1 < e.polyline.count else { continue }
                let q = e.polyline[k + 1]
                guard (q - p).length > 1e-12 else { continue }
                points.append(curve.closest((p + q) * 0.5))
            }
            return EdgeInfo(id: e.id, polyline: points, isSharp: e.isSharp, faces: e.faces,
                            topologyEdgeIDs: e.topologyEdgeIDs, curve: e.curve)
        }

        return BodySnapshot(bodyID: bodyID, revision: revision, positions: outPositions, normals: outNormals,
                            triangles: outTriangles, triangleFace: outFace, triangleTopologyFace: outTopology,
                            faces: faces, edges: refinedEdges, maximumSurfaceDeviation: maximumSurfaceDeviation)
    }
}

extension BodySnapshot {
    /// The plane of a flat face: its kernel description, or, when the kernel only has its
    /// triangles (a bevel, an imported mesh, a face rebuilt by a boolean), the plane they all lie
    /// in. Nil for a face that is not flat. The normal points out of the part.
    public func flatPlane(of id: FaceID) -> (origin: Vec3, normal: Vec3)? {
        guard let f = faces.firstIndex(where: { $0.id == id }) else { return nil }
        if case let .plane(o, n) = faces[f].surface { return (o, n.normalized) }
        guard case .freeform = faces[f].surface else { return nil }
        var normal = Vec3.zero, points: [Vec3] = []
        for t in 0..<triangleFace.count where Int(triangleFace[t]) == f {
            let v = (0..<3).map { positions[Int(triangles[t * 3 + $0])] }
            normal = normal + (v[1] - v[0]).cross(v[2] - v[0])
            points += v
        }
        guard normal.length > 1e-12, let o = points.first else { return nil }
        let n = normal.normalized
        let size = points.reduce(0.0) { max($0, ($1 - o).length) }
        guard points.allSatisfy({ abs(($0 - o).dot(n)) <= 1e-6 * max(size, 1) }) else { return nil }
        return (o, n)
    }
}
