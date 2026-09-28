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
        #expect(try CADDocument.decode(original.encoded()) == original)
        // Hand-built v1 file (flat `features` array) to check old documents without colours.
        let featuresJSON = try JSONEncoder().encode(original.features)
        let featuresObject = try JSONSerialization.jsonObject(with: featuresJSON)
        var json: [String: Any] = ["version": 1, "features": featuresObject]
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

    /// Ross 28/09: pieces placed apart are separate objects on the slicer's plate — also two
    /// pieces of one body; touching parts (a two-colour insert) stay one object with its parts;
    /// a void stays inside its piece.
    @Test func separatePiecesAreSeparateObjects() throws {
        func items(_ data: Data) -> Int { String(decoding: data, as: UTF8.self).components(separatedBy: "<item ").count - 1 }
        func names(_ data: Data) -> [String] {
            String(decoding: data, as: UTF8.self).components(separatedBy: "type=\"model\" name=\"").dropFirst().map { String($0.prefix { $0 != "\"" }) }
        }
        let a = ThreeMFPart(name: "Vaso", mesh: box)
        let b = ThreeMFPart(name: "Base", mesh: box.translated(by: Vec3(100, 0, 0)))
        #expect(items(try ThreeMFExporter.archive(parts: [a, b])) == 2)
        // One body, two pieces apart: two objects «Corpo 1», «Corpo 2».
        var two = box
        let far = box.translated(by: Vec3(0, 80, 0)), base = UInt32(two.vertices.count)
        two.vertices += far.vertices; two.indices += far.indices.map { $0 + base }
        let split = try ThreeMFExporter.archive(parts: [ThreeMFPart(name: "Corpo", mesh: two)])
        #expect(items(split) == 2 && names(split).contains("Corpo 1") && names(split).contains("Corpo 2"))
        // An insert on its base: one object, two parts.
        let insert = ThreeMFPart(name: "Inserto", mesh: Primitives.box(width: 10, depth: 10, height: 8).translated(by: Vec3(0, 0, 5)))
        #expect(items(try ThreeMFExporter.archive(parts: [a, insert])) == 1)
        // A hollow box (inner shell turned inwards): one piece.
        var hollow = Primitives.box(width: 20, depth: 20, height: 20)
        var inner = Primitives.box(width: 10, depth: 10, height: 10).translated(by: Vec3(0, 0, 5))
        for i in stride(from: 0, to: inner.indices.count, by: 3) { inner.indices.swapAt(i, i + 1) }
        let hb = UInt32(hollow.vertices.count)
        hollow.vertices += inner.vertices; hollow.indices += inner.indices.map { $0 + hb }
        #expect(ThreeMFExporter.shells(hollow).count == 1)
        #expect(items(try ThreeMFExporter.archive(parts: [ThreeMFPart(name: "Cavo", mesh: hollow)])) == 1)
    }

    /// For a slicer an open surface goes anyway (it repairs small gaps); broken indices never.
    @Test func openSurfaceForTheSlicer() throws {
        var open = box; open.indices.removeLast(3)
        let part = ThreeMFPart(name: "Aperta", mesh: open)
        #expect(throws: ThreeMFExportError.self) { try ThreeMFExporter.archive(parts: [part]) }
        #expect(try ThreeMFExporter.archive(parts: [part], allowOpen: true).count > 100)
        var broken = box; broken.indices[0] = UInt32.max
        #expect(throws: ThreeMFExportError.self) { try ThreeMFExporter.archive(parts: [ThreeMFPart(name: "Rotta", mesh: broken)], allowOpen: true) }
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
