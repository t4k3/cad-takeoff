import Compression
import Foundation

// Mesh import (T74): STL (binary/ASCII), OBJ and 3MF, e.g. exported from Fusion 360.
// Units: STL/OBJ carry none and are read as millimetres; 3MF declares its unit and is scaled.

public struct MeshImportError: LocalizedError, Sendable {
    public let message: String
    public var errorDescription: String? { message }
    init(_ message: String) { self.message = message }
}

public enum MeshImport {
    public static let triangleLimit = 1_000_000

    /// Named meshes in a file, by extension (stl, obj, 3mf).
    public static func read(_ data: Data, fileExtension: String) throws -> [(name: String, mesh: Mesh)] {
        switch fileExtension.lowercased() {
        case "stl": return [("", try stl(data))]
        case "obj": return [("", try obj(data))]
        case "3mf": return try threeMF(data)
        default: throw MeshImportError("Formato non supportato: .\(fileExtension) (usa STL, OBJ o 3MF)")
        }
    }

    // MARK: STL

    public static func stl(_ data: Data) throws -> Mesh {
        let bytes = [UInt8](data)
        if bytes.count >= 84 {
            let n = Int(UInt32(bytes[80]) | UInt32(bytes[81]) << 8 | UInt32(bytes[82]) << 16 | UInt32(bytes[83]) << 24)
            if bytes.count == 84 + 50 * n {
                guard n <= triangleLimit else { throw MeshImportError("STL oltre \(triangleLimit) triangoli") }
                var points: [Vec3] = []
                points.reserveCapacity(n * 3)
                func float(_ o: Int) -> Double {
                    Double(Float(bitPattern: UInt32(bytes[o]) | UInt32(bytes[o + 1]) << 8 | UInt32(bytes[o + 2]) << 16 | UInt32(bytes[o + 3]) << 24))
                }
                for t in 0..<n {
                    let o = 84 + 50 * t + 12
                    for k in 0..<3 { points.append(Vec3(float(o + 12 * k), float(o + 12 * k + 4), float(o + 12 * k + 8))) }
                }
                return welded(points)
            }
        }
        guard let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .ascii),
              text.lowercased().contains("vertex") else { throw MeshImportError("STL non valido") }
        var points: [Vec3] = []
        for line in text.split(whereSeparator: \.isNewline) {
            let parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            guard parts.first?.lowercased() == "vertex", parts.count >= 4,
                  let x = Double(parts[1]), let y = Double(parts[2]), let z = Double(parts[3]) else { continue }
            points.append(Vec3(x, y, z))
        }
        guard points.count >= 3, points.count % 3 == 0, points.count / 3 <= triangleLimit else { throw MeshImportError("STL ASCII non valido") }
        return welded(points)
    }

    // MARK: OBJ

    public static func obj(_ data: Data) throws -> Mesh {
        guard let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .ascii) else { throw MeshImportError("OBJ non leggibile") }
        var v: [Vec3] = [], points: [Vec3] = []
        for line in text.split(whereSeparator: \.isNewline) {
            let parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            guard let head = parts.first else { continue }
            if head == "v", parts.count >= 4, let x = Double(parts[1]), let y = Double(parts[2]), let z = Double(parts[3]) {
                v.append(Vec3(x, y, z))
            } else if head == "f", parts.count >= 4 {
                let ids = parts.dropFirst().compactMap { token -> Int? in
                    guard let i = Int(token.split(separator: "/", omittingEmptySubsequences: false).first ?? "") else { return nil }
                    return i < 0 ? v.count + i : i - 1
                }
                guard ids.count >= 3, ids.allSatisfy({ v.indices.contains($0) }) else { throw MeshImportError("OBJ: indice di vertice non valido") }
                for k in 1..<(ids.count - 1) { points += [v[ids[0]], v[ids[k]], v[ids[k + 1]]] }
            }
        }
        guard points.count >= 3, points.count / 3 <= triangleLimit else { throw MeshImportError("OBJ senza facce") }
        return welded(points)
    }

    // MARK: 3MF

    public static func threeMF(_ data: Data) throws -> [(name: String, mesh: Mesh)] {
        let files = try unzip(data)
        guard let model = files.first(where: { $0.key.lowercased().hasSuffix(".model") && $0.key.lowercased().contains("3d/") })?.value
                ?? files.first(where: { $0.key.lowercased().hasSuffix(".model") })?.value else {
            throw MeshImportError("3MF senza modello 3D")
        }
        let parser = ThreeMFParser()
        let xml = XMLParser(data: model)
        xml.delegate = parser
        guard xml.parse() else { throw MeshImportError("3MF: XML non valido") }
        let scale: Double = switch parser.unit {
        case "micron": 0.001
        case "centimeter": 10
        case "inch": 25.4
        case "foot": 304.8
        case "meter": 1000
        default: 1
        }
        func place(_ id: String, _ transform: [Double], depth: Int, into points: inout [Vec3]) {
            guard depth < 16, let object = parser.objects[id] else { return }
            for t in object.triangles {
                for i in [t.0, t.1, t.2] where object.vertices.indices.contains(i) {
                    points.append(apply(transform, object.vertices[i]) * scale)
                }
            }
            for c in object.components { place(c.id, compose(transform, c.transform), depth: depth + 1, into: &points) }
        }
        var out: [(String, Mesh)] = []
        var items = parser.items.isEmpty ? parser.objects.keys.sorted().map { ($0, identity) } : parser.items
        // An assembly object (components only) gives one part per component, as exported by
        // Fusion 360 and by us.
        items = items.flatMap { id, transform -> [(String, [Double])] in
            guard let o = parser.objects[id], o.triangles.isEmpty, !o.components.isEmpty else { return [(id, transform)] }
            return o.components.map { ($0.id, compose(transform, $0.transform)) }
        }
        for (id, transform) in items {
            var points: [Vec3] = []
            place(id, transform, depth: 0, into: &points)
            guard points.count >= 3, points.count % 3 == 0 else { continue }
            out.append((parser.objects[id]?.name ?? "", welded(points)))
        }
        guard !out.isEmpty else { throw MeshImportError("3MF senza oggetti") }
        guard out.reduce(0, { $0 + $1.1.triangleCount }) <= triangleLimit else { throw MeshImportError("3MF oltre \(triangleLimit) triangoli") }
        return out
    }

    private static let identity: [Double] = [1, 0, 0, 0, 1, 0, 0, 0, 1, 0, 0, 0]

    /// 3MF transform "m00 m01 m02 m10 m11 m12 m20 m21 m22 m30 m31 m32" (row vector convention).
    private static func apply(_ m: [Double], _ p: Vec3) -> Vec3 {
        Vec3(p.x * m[0] + p.y * m[3] + p.z * m[6] + m[9],
             p.x * m[1] + p.y * m[4] + p.z * m[7] + m[10],
             p.x * m[2] + p.y * m[5] + p.z * m[8] + m[11])
    }

    /// Inner transform then outer.
    private static func compose(_ outer: [Double], _ inner: [Double]) -> [Double] {
        var r = [Double](repeating: 0, count: 12)
        for row in 0..<4 {
            for col in 0..<3 {
                var v = row == 3 ? outer[9 + col] : 0
                for k in 0..<3 { v += (row == 3 ? inner[9 + k] : inner[row * 3 + k]) * outer[k * 3 + col] }
                r[row * 3 + col] = v
            }
        }
        return r
    }

    private final class ThreeMFParser: NSObject, XMLParserDelegate {
        struct Object { var name = ""; var vertices: [Vec3] = []; var triangles: [(Int, Int, Int)] = []; var components: [(id: String, transform: [Double])] = [] }
        var unit = "millimeter"
        var objects: [String: Object] = [:]
        var items: [(String, [Double])] = []
        private var current: String?

        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?,
                    attributes a: [String: String] = [:]) {
            switch name.split(separator: ":").last.map(String.init) ?? name {
            case "model": unit = a["unit"] ?? unit
            case "object":
                current = a["id"]
                if let id = current { objects[id] = Object(name: a["name"] ?? "") }
            case "vertex":
                guard let id = current, let x = a["x"].flatMap(Double.init), let y = a["y"].flatMap(Double.init), let z = a["z"].flatMap(Double.init) else { return }
                objects[id]?.vertices.append(Vec3(x, y, z))
            case "triangle":
                guard let id = current, let v1 = a["v1"].flatMap(Int.init), let v2 = a["v2"].flatMap(Int.init), let v3 = a["v3"].flatMap(Int.init) else { return }
                objects[id]?.triangles.append((v1, v2, v3))
            case "component":
                guard let id = current, let ref = a["objectid"] else { return }
                objects[id]?.components.append((ref, matrix(a["transform"])))
            case "item":
                if let ref = a["objectid"] { items.append((ref, matrix(a["transform"]))) }
            default: break
            }
        }

        func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
            if (name.split(separator: ":").last.map(String.init) ?? name) == "object" { current = nil }
        }

        private func matrix(_ s: String?) -> [Double] {
            let v = s?.split(separator: " ").compactMap { Double($0) } ?? []
            return v.count == 12 ? v : MeshImport.identity
        }
    }

    // MARK: ZIP (stored or deflate)

    private static func unzip(_ data: Data) throws -> [String: Data] {
        let b = [UInt8](data)
        func u16(_ o: Int) -> Int { Int(b[o]) | Int(b[o + 1]) << 8 }
        func u32(_ o: Int) -> Int { Int(b[o]) | Int(b[o + 1]) << 8 | Int(b[o + 2]) << 16 | Int(b[o + 3]) << 24 }
        // End of central directory.
        guard b.count >= 22, let eocd = stride(from: b.count - 22, through: max(0, b.count - 65_557), by: -1)
                .first(where: { u32($0) == 0x0605_4b50 }) else { throw MeshImportError("3MF: archivio ZIP non valido") }
        var o = u32(eocd + 16)
        var files: [String: Data] = [:]
        for _ in 0..<u16(eocd + 10) {
            guard o + 46 <= b.count, u32(o) == 0x0201_4b50 else { throw MeshImportError("3MF: directory ZIP non valida") }
            let method = u16(o + 10), compressed = u32(o + 20), size = u32(o + 24)
            let nameLength = u16(o + 28), extra = u16(o + 30), comment = u16(o + 32), local = u32(o + 42)
            let name = String(decoding: b[(o + 46)..<(o + 46 + nameLength)], as: UTF8.self)
            o += 46 + nameLength + extra + comment
            guard local + 30 <= b.count, u32(local) == 0x0403_4b50 else { continue }
            let start = local + 30 + u16(local + 26) + u16(local + 28)
            guard start + compressed <= b.count, size <= 512_000_000 else { throw MeshImportError("3MF: file troppo grande") }
            let raw = Data(b[start..<(start + compressed)])
            switch method {
            case 0: files[name] = raw
            case 8: files[name] = try inflate(raw, size: size)
            default: continue
            }
        }
        return files
    }

    private static func inflate(_ data: Data, size: Int) throws -> Data {
        guard size > 0 else { return Data() }
        var out = Data(count: size)
        let written = out.withUnsafeMutableBytes { dst in
            data.withUnsafeBytes { src in
                compression_decode_buffer(dst.bindMemory(to: UInt8.self).baseAddress!, size,
                                          src.bindMemory(to: UInt8.self).baseAddress!, data.count, nil, COMPRESSION_ZLIB)
            }
        }
        guard written == size else { throw MeshImportError("3MF: decompressione non riuscita") }
        return out
    }

    // MARK: Helpers

    /// Triangle soup → indexed mesh with shared vertices (exact positions, as exported).
    static func welded(_ points: [Vec3]) -> Mesh {
        struct Key: Hashable { let x: Int64, y: Int64, z: Int64 }
        var index: [Key: UInt32] = [:]
        var mesh = Mesh()
        for p in points {
            let k = Key(x: Int64((p.x * 1e6).rounded()), y: Int64((p.y * 1e6).rounded()), z: Int64((p.z * 1e6).rounded()))
            if let i = index[k] { mesh.indices.append(i); continue }
            let i = UInt32(mesh.vertices.count)
            index[k] = i
            mesh.vertices.append(p)
            mesh.indices.append(i)
        }
        // Drop triangles that collapsed to a line or a point.
        var clean: [UInt32] = []
        for t in 0..<(mesh.indices.count / 3) {
            let a = mesh.indices[t * 3], b = mesh.indices[t * 3 + 1], c = mesh.indices[t * 3 + 2]
            if a != b, b != c, a != c { clean += [a, b, c] }
        }
        mesh.indices = clean
        return mesh
    }
}
