import Foundation
import XCTest
@testable import ElectronicsCore

final class LibraryGeometryTests: XCTestCase {
    private func snapshot(_ pad: FootprintPad) throws -> LibraryFootprintSnapshot {
        try ElectronicsLibraryGeometry.footprint(.init(name: "Synthetic QA", pads: [pad],
            source: .init(reference: "test", license: "synthetic", sourceRevision: "1")))
    }

    func testRectangleCornersAndRotatedBoundsAreExact() throws {
        var pad = FootprintPad(number: "1", center: .init(10, 20), size: .init(4, 2), shape: .rectangle)
        let first = try snapshot(pad)
        XCTAssertEqual(first.pads[0].core, [.init(8,19), .init(12,19), .init(12,21), .init(8,21)])
        XCTAssertEqual(first.pads[0].radius, 0)
        pad.rotationDegrees = 90
        let rotated = try snapshot(pad)
        XCTAssertEqual(rotated.bounds.minimum.x, 9, accuracy: 1e-12)
        XCTAssertEqual(rotated.bounds.maximum.x, 11, accuracy: 1e-12)
        XCTAssertEqual(rotated.bounds.minimum.y, 18, accuracy: 1e-12)
        XCTAssertEqual(rotated.bounds.maximum.y, 22, accuracy: 1e-12)
        pad.rotationDegrees = 45
        let oblique = try snapshot(pad), extent = 3 / sqrt(2.0)
        XCTAssertEqual(oblique.bounds.minimum.x, 10 - extent, accuracy: 1e-12)
        XCTAssertEqual(oblique.bounds.maximum.y, 20 + extent, accuracy: 1e-12)
    }

    func testOvalAndRoundedRectangleKeepActualRadii() throws {
        var pad = FootprintPad(number: "2", center: .init(), size: .init(4, 2), shape: .oval)
        let oval = try snapshot(pad)
        XCTAssertEqual(oval.pads[0].core, [.init(-1,0), .init(1,0)])
        XCTAssertEqual(oval.pads[0].radius, 1)
        pad.shape = .roundedRectangle; pad.cornerRadius = 0.2
        let rounded = try snapshot(pad)
        XCTAssertEqual(rounded.pads[0].radius, 0.2)
        XCTAssertEqual(rounded.pads[0].core, [.init(-1.8,-0.8), .init(1.8,-0.8), .init(1.8,0.8), .init(-1.8,0.8)])
        XCTAssertEqual(rounded.bounds.minimum, .init(-2,-1))
        XCTAssertEqual(rounded.bounds.maximum, .init(2,1))
    }

    func testThroughHoleCircleKeepsBoreAndStableIdentity() throws {
        var pad = FootprintPad(number: "3", center: .init(2,-3), size: .init(2,2), shape: .circle)
        pad.drillDiameter = 0.8
        let result = try snapshot(pad)
        XCTAssertEqual(result.pads[0].id, pad.id)
        XCTAssertEqual(result.pads[0].core, [.init(2,-3)])
        XCTAssertEqual(result.pads[0].center, pad.center)
        XCTAssertEqual(result.pads[0].radius, 1)
        XCTAssertEqual(result.pads[0].drillDiameter, 0.8)
        XCTAssertEqual(result.bounds.minimum, .init(1,-4))
        XCTAssertEqual(result.bounds.maximum, .init(3,-2))
        XCTAssertEqual(try JSONDecoder().decode(LibraryFootprintSnapshot.self, from: JSONEncoder().encode(result)), result)
    }

    func testInvalidGeometryIsRejectedBeforeDrawing() throws {
        var pad = FootprintPad(number: "1", center: .init(), size: .init(2,1), shape: .rectangle)
        pad.center.x = .nan
        XCTAssertThrowsError(try snapshot(pad))
        pad.center.x = 0; pad.drillDiameter = 2
        XCTAssertThrowsError(try snapshot(pad))
        let empty = FootprintDefinition(name: "empty", pads: [], source: .init(reference: "test", license: "test", sourceRevision: "1"))
        XCTAssertThrowsError(try ElectronicsLibraryGeometry.footprint(empty))
    }
}
