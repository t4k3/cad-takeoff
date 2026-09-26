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
    public var errorDescription: String? { message }
    init(_ message: String) { self.message = message }
}

public enum ThreeMFExportProfile: String, Codable, Sendable {
    case standard
    /// Additional colour-slot and part-name metadata shared by Bambu, Orca and Snapmaker Orca.
    /// No machine, material/process preset, toolhead mapping or G-code is embedded.
    case bambuOrca
}

/// 3MF Core + Materials Extension. No printer presets, G-code, or filament settings.
public enum ThreeMFExporter {
    public static func archive(parts: [ThreeMFPart], profile: ThreeMFExportProfile = .bambuOrca) throws -> Data {
        guard !parts.isEmpty else { throw ThreeMFExportError("Nessuna parte da esportare.") }
        guard parts.count <= 256, Set(parts.map(\.id)).count == parts.count else {
            throw ThreeMFExportError("Massimo 256 parti con identificatori univoci.")
        }
        guard parts.reduce(0, { $0 + $1.mesh.indices.count }) <= 3_000_000,
              parts.reduce(0, { $0 + $1.mesh.vertices.count }) <= 1_000_000 else {
            throw ThreeMFExportError("Geometria troppo grande per l'esportatore 3MF del prototipo.")
        }
        for part in parts { try validate(part) }
        var palette: [PartColor] = []
        for part in parts where !palette.contains(part.color) { palette.append(part.color) }
        // One colour per group is standard-compliant and also supports older Orca importers
        // that only retain the last entry of a colour group. Resource IDs are globally unique.
        let firstObjectID = palette.count + 1
        let assemblyID = firstObjectID + parts.count
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
        // One build item with named component parts preserves their relative placement.
        // Properties belong on mesh objects, never on a component container.
        xml += "\n<object id=\"\(assemblyID)\" type=\"model\" name=\"Design\"><components>"
        for i in parts.indices { xml += "\n<component objectid=\"\(firstObjectID + i)\"/>" }
        xml += "\n</components></object></resources><build><item objectid=\"\(assemblyID)\"/></build></model>"
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
            var settings = "<?xml version=\"1.0\" encoding=\"UTF-8\"?><config><object id=\"\(assemblyID)\"><metadata key=\"name\" value=\"Design\"/>"
            for (i, part) in parts.enumerated() {
                let slot = palette.firstIndex(of: part.color)! + 1
                settings += "<part id=\"\(firstObjectID + i)\" subtype=\"normal_part\"><metadata key=\"name\" value=\"\(escape(part.name))\"/><metadata key=\"extruder\" value=\"\(slot)\"/></part>"
            }
            settings += "</object></config>"
            files.append(("Metadata/model_settings.config", Data(settings.utf8)))
            let colours = try JSONSerialization.data(withJSONObject: ["filament_colour": palette.map(\.hex)], options: [.sortedKeys])
            files.append(("Metadata/project_settings.config", colours))
        }
        return StoredZIP.archive(files)
    }

    private struct Edge: Hashable {
        let low: UInt32
        let high: UInt32
        init(_ a: UInt32, _ b: UInt32) { low = min(a, b); high = max(a, b) }
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
            guard area.isFinite, area > 1e-12 else { throw fail("triangolo degenere.") }
            for i in 0..<3 {
                let u = ids[i], v = ids[(i + 1) % 3], key = Edge(u, v)
                var value = edges[key, default: (0, 0)]
                value.count += 1; value.direction += u < v ? 1 : -1
                edges[key] = value
            }
        }
        guard edges.values.allSatisfy({ $0.count == 2 && $0.direction == 0 }) else {
            throw fail("mesh aperta, non manifold o orientamento incoerente.")
        }
        guard mesh.volume.isFinite, mesh.volume > 1e-12 else { throw fail("volume nullo o orientamento interno.") }
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
