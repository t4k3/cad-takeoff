import Foundation
import Testing
@testable import CADCore

struct ThreeMFTests {
    private var box: Mesh { Primitives.box(width: 40, depth: 30, height: 5) }

    @Test func colourParsingAndCoding() throws {
        let colour = try #require(PartColor(hex: "#e53935"))
        #expect(colour.hex == "#E53935")
        #expect(colour.red == 229 && colour.green == 57 && colour.blue == 53)
        #expect(try JSONDecoder().decode(PartColor.self, from: JSONEncoder().encode(colour)) == colour)
        for invalid in ["red", "FFFFFF", "#FFF", "#112233FF", " #112233", "#11GG33", "#-12345"] {
            #expect(PartColor(hex: invalid) == nil)
        }
    }

    @Test func oldDocumentAndColourRoundTrip() throws {
        let original = CADDocument(features: [Feature(name: "Parte", kind: .box(width: 10, depth: 20, height: 5), color: PartColor(hex: "#123456")!)])
        let encoded = try original.encoded()
        #expect(try CADDocument.decode(encoded) == original)
        var json = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        var features = try #require(json["features"] as? [[String: Any]])
        features[0].removeValue(forKey: "color")
        json["features"] = features
        let old = try CADDocument.decode(JSONSerialization.data(withJSONObject: json))
        #expect(old.features[0].color == .defaultColor)
        #expect(old.features[0].id == original.features[0].id)
        features[0]["color"] = ["red": 256, "green": 0, "blue": 0]
        json["features"] = features
        let invalid = try JSONSerialization.data(withJSONObject: json)
        #expect(throws: (any Error).self) { try CADDocument.decode(invalid) }
    }

    @Test func deterministicPackageWithNamedComponents() throws {
        let id = UUID()
        let part = ThreeMFPart(id: id, name: "Rosso & <\"α\">", mesh: box, color: PartColor(hex: "#E53935")!)
        let data = try ThreeMFExporter.archive(parts: [part])
        #expect(data.prefix(4) == Data([0x50, 0x4B, 0x03, 0x04]))
        #expect(try ThreeMFExporter.archive(parts: [part]) == data)
        // ZIP structure/CRC/XML are additionally checked by an independent Python reader.
        let bytes = String(decoding: data, as: UTF8.self)
        #expect(bytes.contains("#E53935FF"))
        #expect(bytes.contains("name=\"Rosso &amp; &lt;&quot;α&quot;&gt;\""))
        #expect(bytes.contains("partnumber=\"\(id.uuidString)\""))
        #expect(bytes.contains("<component objectid=\"2\"/>"))
    }

    @Test func rejectsInvalidMeshWithoutIndexTraps() {
        var invalidIndex = box; invalidIndex.indices[0] = UInt32.max
        var partialTriangle = box; partialTriangle.indices.removeLast()
        var nonfinite = box; nonfinite.vertices[0].x = .nan
        var infinity = box; infinity.vertices[0].y = .infinity
        var open = box; open.indices.removeLast(3)
        var inconsistent = box; inconsistent.indices.swapAt(0, 1)
        var inverted = box
        for i in stride(from: 0, to: inverted.indices.count, by: 3) { inverted.indices.swapAt(i, i + 1) }
        var degenerate = box; degenerate.indices[1] = degenerate.indices[0]
        for mesh in [Mesh(), invalidIndex, partialTriangle, nonfinite, infinity, open, inconsistent, inverted, degenerate] {
            #expect(throws: ThreeMFExportError.self) { try ThreeMFExporter.archive(parts: [ThreeMFPart(name: "Invalid", mesh: mesh)]) }
        }
    }

    @Test func rejectsEmptyDuplicateIDsAndInvalidXML() {
        #expect(throws: ThreeMFExportError.self) { try ThreeMFExporter.archive(parts: []) }
        let p = ThreeMFPart(name: "Part", mesh: box)
        #expect(throws: ThreeMFExportError.self) { try ThreeMFExporter.archive(parts: [p, p]) }
        #expect(throws: ThreeMFExportError.self) { try ThreeMFExporter.archive(parts: [ThreeMFPart(name: "bad\u{01}name", mesh: box)]) }
    }
}
