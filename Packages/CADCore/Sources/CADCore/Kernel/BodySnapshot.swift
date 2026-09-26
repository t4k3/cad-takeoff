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
                    case .cone:
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
            // Each current semantic group is a single edge or one cylinder rim.
            while !remaining.isEmpty {
                let end = chain.last!
                guard let i = remaining.firstIndex(where: { $0.startVertex == end || $0.endVertex == end }) else {
                    preconditionFailure("PrimitiveKernel generated a disconnected semantic edge")
                }
                let edge = remaining.remove(at: i)
                chain.append(edge.startVertex == end ? edge.endVertex : edge.startVertex)
            }
            let adjacent = first.halfEdges.map { faces[halfEdges[$0].face].selectionID }
            return EdgeInfo(id: id, polyline: chain.map { vertices[$0].position }, isSharp: true,
                            faces: adjacent, topologyEdgeIDs: topologyIDs)
        }
        return BodySnapshot(bodyID: id, revision: revision, positions: positions, normals: normals,
                            triangles: triangles, triangleFace: triangleFace, triangleTopologyFace: triangleTopologyFace,
                            faces: faceInfo, edges: edgeInfo, maximumSurfaceDeviation: maximumSurfaceDeviation)
    }
}
