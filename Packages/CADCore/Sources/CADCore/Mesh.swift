import Foundation

/// Indexed triangle mesh. Triangles are counter-clockwise when seen from outside
/// (outward normals), which is what STL/3MF slicers expect.
public struct Mesh: Codable, Sendable, Equatable {
    public var vertices: [Vec3]
    /// Flat list, 3 indices per triangle.
    public var indices: [UInt32]

    public init(vertices: [Vec3] = [], indices: [UInt32] = []) {
        self.vertices = vertices
        self.indices = indices
    }

    public var triangleCount: Int { indices.count / 3 }
    public var isEmpty: Bool { indices.isEmpty }

    public func triangle(_ i: Int) -> (Vec3, Vec3, Vec3) {
        (vertices[Int(indices[i * 3])], vertices[Int(indices[i * 3 + 1])], vertices[Int(indices[i * 3 + 2])])
    }

    public func normal(ofTriangle i: Int) -> Vec3 {
        let (a, b, c) = triangle(i)
        return (b - a).cross(c - a).normalized
    }

    public var bounds: BoundingBox? {
        guard var lo = vertices.first else { return nil }
        var hi = lo
        for v in vertices {
            lo = Vec3(Swift.min(lo.x, v.x), Swift.min(lo.y, v.y), Swift.min(lo.z, v.z))
            hi = Vec3(Swift.max(hi.x, v.x), Swift.max(hi.y, v.y), Swift.max(hi.z, v.z))
        }
        return BoundingBox(min: lo, max: hi)
    }

    /// Signed volume in mm³ (positive for a closed, outward-oriented mesh).
    public var volume: Double {
        var v = 0.0
        for i in 0..<triangleCount {
            let (a, b, c) = triangle(i)
            v += a.dot(b.cross(c)) / 6
        }
        return v
    }

    public func translated(by t: Vec3) -> Mesh {
        Mesh(vertices: vertices.map { $0 + t }, indices: indices)
    }

    /// Concatenates meshes (no boolean union — see task graph for CSG).
    public mutating func append(_ other: Mesh) {
        let offset = UInt32(vertices.count)
        vertices += other.vertices
        indices += other.indices.map { $0 + offset }
    }

    public static func merged(_ meshes: [Mesh]) -> Mesh {
        var out = Mesh()
        for m in meshes { out.append(m) }
        return out
    }
}
