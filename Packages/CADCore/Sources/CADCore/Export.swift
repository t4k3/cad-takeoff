import Foundation

public enum STLExporter {
    /// Binary STL (little endian): 80-byte header, UInt32 count, 50 bytes per triangle.
    public static func binary(_ mesh: Mesh, header: String = "FusionTakeoff") -> Data {
        var data = Data(capacity: 84 + mesh.triangleCount * 50)
        var head = Array(header.utf8.prefix(80))
        head += Array(repeating: 0, count: 80 - head.count)
        data.append(contentsOf: head)
        appendUInt32(UInt32(mesh.triangleCount), to: &data)
        for i in 0..<mesh.triangleCount {
            let (a, b, c) = mesh.triangle(i)
            for v in [mesh.normal(ofTriangle: i), a, b, c] {
                appendFloat(Float(v.x), to: &data)
                appendFloat(Float(v.y), to: &data)
                appendFloat(Float(v.z), to: &data)
            }
            data.append(contentsOf: [0, 0]) // attribute byte count
        }
        return data
    }

    public static func ascii(_ mesh: Mesh, name: String = "FusionTakeoff") -> String {
        var s = "solid \(name)\n"
        for i in 0..<mesh.triangleCount {
            let (a, b, c) = mesh.triangle(i)
            let n = mesh.normal(ofTriangle: i)
            s += "  facet normal \(fmt(n))\n    outer loop\n"
            s += "      vertex \(fmt(a))\n      vertex \(fmt(b))\n      vertex \(fmt(c))\n"
            s += "    endloop\n  endfacet\n"
        }
        s += "endsolid \(name)\n"
        return s
    }

    private static func fmt(_ v: Vec3) -> String {
        String(format: "%.6e %.6e %.6e", v.x, v.y, v.z)
    }

    private static func appendUInt32(_ v: UInt32, to data: inout Data) {
        withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) }
    }

    private static func appendFloat(_ f: Float, to data: inout Data) {
        withUnsafeBytes(of: f.bitPattern.littleEndian) { data.append(contentsOf: $0) }
    }
}

public enum MeshValidator {
    public struct Report: Sendable, Equatable {
        public var isWatertight: Bool
        public var boundaryEdges: Int
        public var nonManifoldEdges: Int
        public var volume: Double
    }

    /// Checks every undirected edge is shared by exactly two triangles (vertices welded by position).
    public static func validate(_ mesh: Mesh) -> Report {
        var weld: [Vec3: Int] = [:]
        let ids = mesh.vertices.map { v -> Int in
            if let id = weld[v] { return id }
            let id = weld.count
            weld[v] = id
            return id
        }
        var edges: [UInt64: Int] = [:]
        for t in 0..<mesh.triangleCount {
            for k in 0..<3 {
                let a = ids[Int(mesh.indices[t * 3 + k])], b = ids[Int(mesh.indices[t * 3 + (k + 1) % 3])]
                let key = UInt64(min(a, b)) << 32 | UInt64(max(a, b))
                edges[key, default: 0] += 1
            }
        }
        let boundary = edges.values.filter { $0 == 1 }.count
        let nonManifold = edges.values.filter { $0 > 2 }.count
        return Report(isWatertight: boundary == 0 && nonManifold == 0,
                      boundaryEdges: boundary, nonManifoldEdges: nonManifold, volume: mesh.volume)
    }
}
