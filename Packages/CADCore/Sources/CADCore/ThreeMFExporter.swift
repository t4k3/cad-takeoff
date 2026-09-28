import Foundation

/// One independently coloured solid, already positioned in world millimetres, Z up.
public struct ThreeMFPart: Sendable {
    public var id: UUID
    public var name: String
    public var mesh: Mesh
    public var color: PartColor

    public init(id: UUID = UUID(), name: String, mesh: Mesh, color: PartColor = .defaultColor) {
        self.id = id; self.name = name; self.mesh = mesh; self.color = color
    }
}

public struct ThreeMFExportError: LocalizedError, Sendable {
    public let message: String
    /// About the surface (open, not manifold, degenerate): a slicer can still take the part.
    public var isSurface = false
    public var errorDescription: String? { message }
    init(_ message: String) { self.message = message }
}

private func surface(_ e: ThreeMFExportError) -> ThreeMFExportError { var e = e; e.isSurface = true; return e }

public enum ThreeMFExportProfile: String, Codable, Sendable {
    case standard
    /// Additional colour-slot and part-name metadata shared by Bambu, Orca and Snapmaker Orca.
    /// No machine, material/process preset, toolhead mapping or G-code is embedded.
    case bambuOrca
}

/// 3MF Core + Materials Extension. No printer presets, G-code, or filament settings.
///
/// Objects on the plate: every separate piece is its own build item, so the slicer can arrange
/// it (Ross 28/09: two parts placed apart went to Bambu Studio as one object). A body made of
/// disconnected pieces is split into them; pieces that touch or overlap (a two-colour part, an
/// insert in its base) stay one object with its named parts, in place.
public enum ThreeMFExporter {
    /// `allowOpen`: a part whose surface is not closed goes anyway (for a slicer, which repairs
    /// small gaps), its degenerate triangles dropped; indices and coordinates are still checked.
    public static func archive(parts given: [ThreeMFPart], profile: ThreeMFExportProfile = .bambuOrca,
                               allowOpen: Bool = false) throws -> Data {
        guard !given.isEmpty else { throw ThreeMFExportError("Nessuna parte da esportare.") }
        guard Set(given.map(\.id)).count == given.count else {
            throw ThreeMFExportError("Parti con identificatori ripetuti.")
        }
        // Checked whole (closed, oriented, finite) before being split into pieces.
        guard given.reduce(0, { $0 + $1.mesh.indices.count }) <= 3_000_000,
              given.reduce(0, { $0 + $1.mesh.vertices.count }) <= 1_000_000 else {
            throw ThreeMFExportError("Geometria troppo grande per l'esportatore 3MF del prototipo.")
        }
        var checked: [ThreeMFPart] = []
        for part in given {
            do { try validate(part); checked.append(part) }
            catch let e as ThreeMFExportError where allowOpen && e.isSurface { checked.append(try usable(part)) }
        }
        let parts = checked.flatMap(pieces)
        guard parts.count <= 256 else {
            throw ThreeMFExportError("Massimo 256 parti (contando i pezzi separati di ogni corpo).")
        }
        var palette: [PartColor] = []
        for part in parts where !palette.contains(part.color) { palette.append(part.color) }
        // One colour per group is standard-compliant and also supports older Orca importers
        // that only retain the last entry of a colour group. Resource IDs are globally unique.
        let firstObjectID = palette.count + 1
        let groups = objects(parts)
        let firstAssemblyID = firstObjectID + parts.count
        func groupName(_ g: [Int]) -> String {
            let names = g.map { parts[$0].name }
            return names.count == 1 ? names[0] : names.prefix(3).joined(separator: " + ") + (names.count > 3 ? " …" : "")
        }
        var xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <model unit="millimeter" xml:lang="it-IT" xmlns="http://schemas.microsoft.com/3dmanufacturing/core/2015/02" xmlns:m="http://schemas.microsoft.com/3dmanufacturing/material/2015/02" requiredextensions="m">
        <metadata name="Application">CAD Takeoff</metadata>
        <metadata name="Title">Design</metadata>
        <resources>
        """
        for (i, color) in palette.enumerated() {
            xml += "\n<m:colorgroup id=\"\(i + 1)\"><m:color color=\"\(color.hex)FF\"/></m:colorgroup>"
        }
        for (i, part) in parts.enumerated() {
            let colorID = palette.firstIndex(of: part.color)! + 1
            xml += "\n<object id=\"\(firstObjectID + i)\" type=\"model\" name=\"\(escape(part.name))\" partnumber=\"\(part.id.uuidString)\" pid=\"\(colorID)\" pindex=\"0\"><mesh><vertices>"
            for v in part.mesh.vertices {
                xml += "\n<vertex x=\"\(v.x)\" y=\"\(v.y)\" z=\"\(v.z)\"/>"
            }
            xml += "\n</vertices><triangles>"
            for t in stride(from: 0, to: part.mesh.indices.count, by: 3) {
                xml += "\n<triangle v1=\"\(part.mesh.indices[t])\" v2=\"\(part.mesh.indices[t + 1])\" v3=\"\(part.mesh.indices[t + 2])\"/>"
            }
            xml += "\n</triangles></mesh></object>"
        }
        // One build item per object, its named component parts in place (absolute coordinates:
        // the relative placement is kept). Properties belong on mesh objects, never on a container.
        for (g, group) in groups.enumerated() {
            xml += "\n<object id=\"\(firstAssemblyID + g)\" type=\"model\" name=\"\(escape(groupName(group)))\"><components>"
            for i in group { xml += "\n<component objectid=\"\(firstObjectID + i)\"/>" }
            xml += "\n</components></object>"
        }
        xml += "\n</resources><build>"
        for g in groups.indices { xml += "<item objectid=\"\(firstAssemblyID + g)\"/>" }
        xml += "</build></model>"
        guard xml.utf8.count <= 64 * 1024 * 1024 else { throw ThreeMFExportError("Archivio 3MF oltre il limite di 64 MiB.") }
        let extraTypes = profile == .bambuOrca ? "<Override PartName=\"/Metadata/model_settings.config\" ContentType=\"application/xml\"/><Override PartName=\"/Metadata/project_settings.config\" ContentType=\"application/json\"/>" : ""
        let contentTypes = """
        <?xml version="1.0" encoding="UTF-8"?>
        <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="model" ContentType="application/vnd.ms-package.3dmanufacturing-3dmodel+xml"/>\(extraTypes)</Types>
        """
        let extraRelationships = profile == .bambuOrca ? "<Relationship Target=\"/Metadata/model_settings.config\" Id=\"rel1\" Type=\"urn:takeoff:3mf:relationships:part-settings\"/><Relationship Target=\"/Metadata/project_settings.config\" Id=\"rel2\" Type=\"urn:takeoff:3mf:relationships:colour-slots\"/>" : ""
        let relationships = """
        <?xml version="1.0" encoding="UTF-8"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Target="/3D/3dmodel.model" Id="rel0" Type="http://schemas.microsoft.com/3dmanufacturing/2013/01/3dmodel"/>\(extraRelationships)</Relationships>
        """
        var files: [(String, Data)] = [
            ("[Content_Types].xml", Data(contentTypes.utf8)),
            ("_rels/.rels", Data(relationships.utf8)),
            ("3D/3dmodel.model", Data(xml.utf8))
        ]
        if profile == .bambuOrca {
            // A colour slot is one-based in these slicers. Equal sRGB colours share one slot.
            var settings = "<?xml version=\"1.0\" encoding=\"UTF-8\"?><config>"
            for (g, group) in groups.enumerated() {
                settings += "<object id=\"\(firstAssemblyID + g)\"><metadata key=\"name\" value=\"\(escape(groupName(group)))\"/>"
                for i in group {
                    let slot = palette.firstIndex(of: parts[i].color)! + 1
                    settings += "<part id=\"\(firstObjectID + i)\" subtype=\"normal_part\"><metadata key=\"name\" value=\"\(escape(parts[i].name))\"/><metadata key=\"extruder\" value=\"\(slot)\"/></part>"
                }
                settings += "</object>"
            }
            settings += "</config>"
            files.append(("Metadata/model_settings.config", Data(settings.utf8)))
            let colours = try JSONSerialization.data(withJSONObject: ["filament_colour": palette.map(\.hex)], options: [.sortedKeys])
            files.append(("Metadata/project_settings.config", colours))
        }
        return StoredZIP.archive(files)
    }

    // MARK: Pieces and objects

    /// A part's separate pieces (connected shells), each with the voids inside it; the part
    /// itself when it is one piece. Pieces are named «Name 1», «Name 2»… in order along X, Y, Z.
    static func pieces(_ part: ThreeMFPart) -> [ThreeMFPart] {
        let shells = shells(part.mesh)
        guard shells.count > 1 else { return [part] }
        return shells.enumerated().map { k, mesh in
            var bytes = part.id.uuid
            bytes.15 ^= UInt8(truncatingIfNeeded: k + 1); bytes.14 ^= UInt8(truncatingIfNeeded: (k + 1) >> 8)
            return ThreeMFPart(id: UUID(uuid: bytes), name: "\(part.name) \(k + 1)", mesh: mesh, color: part.color)
        }
    }

    /// Connected pieces of a mesh (vertices joined by position). A shell turned inwards (a void)
    /// goes with the smallest outward shell whose box contains it.
    public static func shells(_ mesh: Mesh) -> [Mesh] {
        var weld: [Vec3: Int] = [:]
        let node = mesh.vertices.map { v -> Int in
            if let i = weld[v] { return i }
            weld[v] = weld.count; return weld.count - 1
        }
        var parent = Array(0..<weld.count)
        func find(_ i: Int) -> Int { var i = i; while parent[i] != i { parent[i] = parent[parent[i]]; i = parent[i] }; return i }
        for t in stride(from: 0, to: mesh.indices.count - 2, by: 3) {
            let a = find(node[Int(mesh.indices[t])])
            for k in 1...2 { let b = find(node[Int(mesh.indices[t + k])]); if a != b { parent[b] = a } }
        }
        var byRoot: [Int: [Int]] = [:]
        for t in stride(from: 0, to: mesh.indices.count - 2, by: 3) { byRoot[find(node[Int(mesh.indices[t])]), default: []].append(t) }
        guard byRoot.count > 1 else { return [mesh] }
        var pieces: [Mesh] = byRoot.values.map { triangles in
            var remap: [UInt32: UInt32] = [:], sub = Mesh()
            for t in triangles {
                for k in 0..<3 {
                    let i = mesh.indices[t + k]
                    if let j = remap[i] { sub.indices.append(j) }
                    else { remap[i] = UInt32(sub.vertices.count); sub.indices.append(UInt32(sub.vertices.count)); sub.vertices.append(mesh.vertices[Int(i)]) }
                }
            }
            return sub
        }
        // Voids inside their piece.
        var outer = pieces.filter { $0.volume > 0 }
        for void in pieces where void.volume <= 0 {
            guard let vb = void.bounds else { continue }
            let hosts = outer.indices.filter { i in
                guard let b = outer[i].bounds else { return false }
                return b.min.x <= vb.min.x && b.min.y <= vb.min.y && b.min.z <= vb.min.z && b.max.x >= vb.max.x && b.max.y >= vb.max.y && b.max.z >= vb.max.z
            }
            guard let host = hosts.min(by: { outer[$0].volume < outer[$1].volume }) else { outer.append(void); continue }
            let base = UInt32(outer[host].vertices.count)
            outer[host].vertices += void.vertices
            outer[host].indices += void.indices.map { $0 + base }
        }
        pieces = outer
        func key(_ m: Mesh) -> (Double, Double, Double) { let b = m.bounds; return (b?.min.x ?? 0, b?.min.y ?? 0, b?.min.z ?? 0) }
        return pieces.sorted { key($0) < key($1) }
    }

    /// Parts grouped into objects: those whose boxes touch or overlap go together (in the given
    /// order); the others are objects of their own.
    static func objects(_ parts: [ThreeMFPart]) -> [[Int]] {
        let boxes = parts.map(\.mesh.bounds)
        var parent = Array(parts.indices)
        func find(_ i: Int) -> Int { var i = i; while parent[i] != i { parent[i] = parent[parent[i]]; i = parent[i] }; return i }
        let eps = 1e-6
        for i in parts.indices { for j in parts.indices where j > i {
            guard let a = boxes[i], let b = boxes[j] else { continue }
            if a.min.x <= b.max.x + eps, b.min.x <= a.max.x + eps, a.min.y <= b.max.y + eps, b.min.y <= a.max.y + eps,
               a.min.z <= b.max.z + eps, b.min.z <= a.max.z + eps { parent[find(j)] = find(i) }
        } }
        var order: [Int] = [], members: [Int: [Int]] = [:]
        for i in parts.indices {
            let r = find(i)
            if members[r] == nil { order.append(r) }
            members[r, default: []].append(i)
        }
        return order.map { members[$0]! }
    }

    private struct Edge: Hashable {
        let low: UInt32
        let high: UInt32
        init(_ a: UInt32, _ b: UInt32) { low = min(a, b); high = max(a, b) }
    }

    /// An open part as far as a slicer can take it: valid indices and finite coordinates,
    /// degenerate triangles left out.
    private static func usable(_ part: ThreeMFPart) throws -> ThreeMFPart {
        let mesh = part.mesh
        guard mesh.indices.count.isMultiple(of: 3), mesh.indices.allSatisfy({ Int($0) < mesh.vertices.count }),
              mesh.vertices.allSatisfy({ $0.x.isFinite && $0.y.isFinite && $0.z.isFinite }) else {
            throw ThreeMFExportError("Parte «\(part.name)»: indici o coordinate non validi.")
        }
        var kept = part
        kept.mesh.indices = []
        for t in stride(from: 0, to: mesh.indices.count, by: 3) {
            let a = mesh.vertices[Int(mesh.indices[t])], b = mesh.vertices[Int(mesh.indices[t + 1])], c = mesh.vertices[Int(mesh.indices[t + 2])]
            if (b - a).cross(c - a).length > 1e-12 { kept.mesh.indices += mesh.indices[t..<t + 3] }
        }
        guard kept.mesh.indices.count >= 3 else { throw ThreeMFExportError("Parte «\(part.name)»: nessun triangolo valido.") }
        return kept
    }

    private static func validate(_ part: ThreeMFPart) throws {
        let mesh = part.mesh
        func fail(_ reason: String) -> ThreeMFExportError { ThreeMFExportError("Parte «\(part.name)»: \(reason)") }
        guard !part.name.isEmpty, part.name.unicodeScalars.allSatisfy({
            $0.value == 9 || $0.value == 10 || $0.value == 13 || (0x20...0xD7FF).contains($0.value)
                || (0xE000...0xFFFD).contains($0.value) || (0x10000...0x10FFFF).contains($0.value)
        }) else { throw fail("nome non valido per XML.") }
        guard mesh.indices.count >= 12, mesh.indices.count.isMultiple(of: 3),
              mesh.indices.allSatisfy({ Int($0) < mesh.vertices.count }) else { throw fail("indici mesh non validi.") }
        guard mesh.vertices.allSatisfy({ $0.x.isFinite && $0.y.isFinite && $0.z.isFinite }) else { throw fail("coordinate non finite.") }
        var edges: [Edge: (count: Int, direction: Int)] = [:]
        for t in stride(from: 0, to: mesh.indices.count, by: 3) {
            let ids = Array(mesh.indices[t..<t + 3])
            let a = mesh.vertices[Int(ids[0])], b = mesh.vertices[Int(ids[1])], c = mesh.vertices[Int(ids[2])]
            let area = (b - a).cross(c - a).length
            guard area.isFinite, area > 1e-12 else { throw surface(fail("triangolo degenere.")) }
            for i in 0..<3 {
                let u = ids[i], v = ids[(i + 1) % 3], key = Edge(u, v)
                var value = edges[key, default: (0, 0)]
                value.count += 1; value.direction += u < v ? 1 : -1
                edges[key] = value
            }
        }
        guard edges.values.allSatisfy({ $0.count == 2 && $0.direction == 0 }) else {
            throw surface(fail("mesh aperta, non manifold o orientamento incoerente."))
        }
        guard mesh.volume.isFinite, mesh.volume > 1e-12 else { throw surface(fail("volume nullo o orientamento interno.")) }
    }

    private static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;").replacingOccurrences(of: "\n", with: "&#10;")
            .replacingOccurrences(of: "\r", with: "&#13;").replacingOccurrences(of: "\t", with: "&#9;")
    }
}

/// ZIP method 0 (stored) with CRC32 and central directory, as permitted by OPC.
/// Only fixed internal paths and bounded payloads from ThreeMFExporter enter this writer.
private enum StoredZIP {
    static func archive(_ files: [(String, Data)]) -> Data {
        var output = Data(), directory = Data()
        for (path, data) in files {
            let name = Data(path.utf8), size = UInt32(data.count), offset = UInt32(output.count), crc = crc32(data)
            output.le(UInt32(0x04034B50)); output.le(UInt16(20)); output.le(UInt16(0x0800))
            output.le(UInt16(0)); output.le(UInt16(0)); output.le(UInt16(0x0021)) // 1980-01-01, deterministic
            output.le(crc); output.le(size); output.le(size); output.le(UInt16(name.count)); output.le(UInt16(0))
            output.append(name); output.append(data)
            directory.le(UInt32(0x02014B50)); directory.le(UInt16(20)); directory.le(UInt16(20)); directory.le(UInt16(0x0800))
            directory.le(UInt16(0)); directory.le(UInt16(0)); directory.le(UInt16(0x0021))
            directory.le(crc); directory.le(size); directory.le(size); directory.le(UInt16(name.count))
            directory.le(UInt16(0)); directory.le(UInt16(0)); directory.le(UInt16(0)); directory.le(UInt16(0))
            directory.le(UInt32(0)); directory.le(offset); directory.append(name)
        }
        let offset = UInt32(output.count)
        output.append(directory)
        output.le(UInt32(0x06054B50)); output.le(UInt16(0)); output.le(UInt16(0))
        output.le(UInt16(files.count)); output.le(UInt16(files.count)); output.le(UInt32(directory.count)); output.le(offset); output.le(UInt16(0))
        return output
    }

    private static let crcTable: [UInt32] = (0..<256).map { byte in
        var crc = UInt32(byte)
        for _ in 0..<8 { crc = (crc >> 1) ^ ((crc & 1) == 0 ? 0 : 0xEDB88320) }
        return crc
    }
    private static func crc32(_ data: Data) -> UInt32 {
        var crc = UInt32.max
        for byte in data { crc = (crc >> 8) ^ crcTable[Int((crc ^ UInt32(byte)) & 255)] }
        return ~crc
    }
}

private extension Data {
    mutating func le<T: FixedWidthInteger>(_ value: T) {
        var little = value.littleEndian
        Swift.withUnsafeBytes(of: &little) { append(contentsOf: $0) }
    }
}
