import XCTest
@testable import CADCore

final class CADCoreTests: XCTestCase {
    func testBoxDimensionsVolumeAndClosure() throws {
        let mesh = try PrimitiveMesher.build(CADModel())
        try mesh.validateClosed()
        XCTAssertEqual(mesh.signedVolume, 40*30*20, accuracy: 1e-8)
        XCTAssertEqual(mesh.vertices.map(\.x).min(), -20)
        XCTAssertEqual(mesh.vertices.map(\.y).max(), 15)
        XCTAssertEqual(mesh.vertices.map(\.z).max(), 20)
    }

    func testCylinderMatchesRegularPolygonVolume() throws {
        var model = CADModel(); model.profile = .circle
        for segments in [16, 96, 256] {
            model.segments = segments
            let mesh = try PrimitiveMesher.build(model)
            let n = Double(segments), r = model.width/2
            let volume = n/2 * r*r * sin(2 * .pi/n) * model.height
            XCTAssertEqual(mesh.signedVolume, volume, accuracy: 1e-7)
            XCTAssertLessThan(mesh.signedVolume, .pi*r*r*model.height)
            try mesh.validateClosed()
        }
    }

    func testMinimumAndMaximumSizesRemainClosed() throws {
        for size in [0.1, 1000.0] {
            for profile in ProfileKind.allCases {
                var model = CADModel(); model.profile = profile
                model.width = size; model.depth = size; model.height = size
                try PrimitiveMesher.build(model).validateClosed()
            }
        }
    }

    func testInvalidDimensionsAndSegmentCountsRejected() {
        for value in [0, -1, .infinity, .nan, 1001] {
            var model = CADModel(); model.width = value
            XCTAssertThrowsError(try PrimitiveMesher.build(model))
        }
        for segments in [0, 15, 257, Int.max] {
            var model = CADModel(); model.segments = segments
            XCTAssertThrowsError(try PrimitiveMesher.build(model))
        }
    }

    func testDocumentRoundTripAndUnsupportedSchema() throws {
        var model = CADModel(); model.profile = .circle; model.width = 13.7
        XCTAssertEqual(try CADModel.decode(model.encoded()), model)
        model.schemaVersion = 2
        XCTAssertThrowsError(try CADModel.decode(JSONEncoder().encode(model)))
        model.schemaVersion = 1; model.unit = "inch"
        XCTAssertThrowsError(try CADModel.decode(JSONEncoder().encode(model)))
        XCTAssertThrowsError(try CADModel.decode(Data("{}".utf8)))
    }

    func testBinarySTLLayoutCoordinatesAndNormals() throws {
        let mesh = try PrimitiveMesher.build(CADModel())
        let data = try STLExporter.encode(mesh)
        func uint32(_ offset: Int) -> UInt32 {
            (0..<4).reduce(0) { $0 | UInt32(data[offset+$1]) << (8*$1) }
        }
        func float(_ offset: Int) -> Float { Float(bitPattern: uint32(offset)) }
        XCTAssertEqual(data.count, 84 + 50*mesh.triangles.count)
        XCTAssertEqual(uint32(80), UInt32(mesh.triangles.count))
        var coordinates: [Float] = []
        for i in mesh.triangles.indices {
            let base = 84 + 50*i
            let n = Vector3(Double(float(base)),Double(float(base+4)),Double(float(base+8)))
            XCTAssertEqual(n.length, 1, accuracy: 1e-6)
            let t = mesh.triangles[i]
            for (corner, index) in [t.a,t.b,t.c].enumerated() {
                let v = mesh.vertices[index], start = base+12+12*corner
                XCTAssertEqual(float(start), Float(v.x))
                XCTAssertEqual(float(start+4), Float(v.y))
                XCTAssertEqual(float(start+8), Float(v.z))
                coordinates.append(float(start))
            }
            XCTAssertEqual(data[base+48], 0); XCTAssertEqual(data[base+49], 0)
        }
        XCTAssertEqual(coordinates.max(), 20)
    }

    func testBrokenMeshesCannotBeExported() throws {
        var mesh = try PrimitiveMesher.build(CADModel())
        mesh.triangles.removeLast()
        XCTAssertThrowsError(try STLExporter.encode(mesh))
        mesh = try PrimitiveMesher.build(CADModel())
        mesh.triangles[0] = Triangle(0, 0, 1)
        XCTAssertThrowsError(try STLExporter.encode(mesh))
        mesh.triangles[0] = Triangle(0, 1, 99999)
        XCTAssertThrowsError(try STLExporter.encode(mesh))
    }
}
