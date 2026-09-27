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
