import Foundation

public enum STLExporter {
    /// Binary STL has no standard unit field. Coordinate values remain in millimetres.
    public static func encode(_ mesh: Mesh) throws -> Data {
        try mesh.validateClosed()
        guard mesh.triangles.count <= Int(UInt32.max) else { throw CADError.invalid("Mesh troppo grande.") }
        var data = Data("TAKEOFF CAD | coordinates in mm".utf8)
        data.append(contentsOf: repeatElement(UInt8(0), count: 80 - data.count))
        func appendUInt32(_ value: UInt32) {
            var little = value.littleEndian
            withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
        }
        func appendVector(_ v: Vector3) throws {
            for value in [v.x, v.y, v.z] {
                let float = Float(value)
                guard float.isFinite else { throw CADError.invalid("Coordinate fuori scala STL.") }
                appendUInt32(float.bitPattern)
            }
        }
        appendUInt32(UInt32(mesh.triangles.count))
        for t in mesh.triangles {
            let a = mesh.vertices[t.a], b = mesh.vertices[t.b], c = mesh.vertices[t.c]
            try appendVector((b-a).cross(c-a).normalized)
            try appendVector(a); try appendVector(b); try appendVector(c)
            data.append(contentsOf: [0, 0])
        }
        return data
    }
}

