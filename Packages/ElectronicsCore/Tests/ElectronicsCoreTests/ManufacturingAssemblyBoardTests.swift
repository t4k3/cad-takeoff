import Foundation
import XCTest
@testable import ElectronicsCore

final class ManufacturingAssemblyBoardTests: XCTestCase {
    func testRectangleUsesActualProfileAndThicknessWithOutwardClosedMesh() throws {
        let p = package([rectangle(x: 100, y: -151, width: 65, height: 81)])
        let parts = try ManufacturingAssemblyBoard.parts(package: p, thickness: 1.6)
        let part = try XCTUnwrap(parts.first)
        XCTAssertEqual(parts.count, 1); XCTAssertEqual(part.material, .substrate)
        try assertClosed(part)
        XCTAssertEqual(volume(part), 65 * 81 * 1.6, accuracy: 1e-6)
        XCTAssertEqual(part.vertices.map(\.x).min(), 100)
        XCTAssertEqual(part.vertices.map(\.x).max(), 165)
        XCTAssertEqual(part.vertices.map(\.y).min(), -151)
        XCTAssertEqual(part.vertices.map(\.y).max(), -70)
        XCTAssertEqual(part.vertices.map(\.z).min(), 0)
        XCTAssertEqual(part.vertices.map(\.z).max(), 1.6)
    }

    func testRoundAndSlotVoidsRemoveRealMaterialIncludingTheirRoof() throws {
        let drills: [ManufacturingDrill] = [
            .init(id: UUID(), position: .init(3,3), diameter: 2, isPlated: false),
            .init(id: UUID(), position: .init(6,5), end: .init(8,5), diameter: 1, isPlated: true)
        ]
        let part = try XCTUnwrap(ManufacturingAssemblyBoard.parts(package: package([rectangle()], drills: drills), thickness: 2).first)
        try assertClosed(part)
        let circleArea = 32.0 / 2 * sin(2 * Double.pi / 32)
        let expectedArea = 100 - circleArea - (circleArea * 0.25 + 2)
        XCTAssertEqual(volume(part), expectedArea * 2, accuracy: 1e-6)
        XCTAssertFalse(roofCovers(.init(3,3), part: part, top: 2))
        XCTAssertFalse(roofCovers(.init(6.5,5), part: part, top: 2))
        XCTAssertTrue(roofCovers(.init(1,1), part: part, top: 2))
    }

    func testOffsetHoleSlabsHaveNoTJunctionsOrArtificialInternalWalls() throws {
        let drills: [ManufacturingDrill] = [
            .init(id: UUID(), position: .init(2.123,2.678), diameter: 1.2, isPlated: true),
            .init(id: UUID(), position: .init(5.551,4.211), diameter: 1.5, isPlated: false),
            .init(id: UUID(), position: .init(7.251,6.3), end: .init(7.8,7.7), diameter: 0.8, isPlated: true)
        ]
        let part = try XCTUnwrap(ManufacturingAssemblyBoard.parts(package: package([rectangle()], drills: drills), thickness: 1.6).first)
        try assertClosed(part)
        for p in [.init(2.123,2.678), PCBPoint(5.551,4.211), .init(7.5,7)] {
            XCTAssertFalse(roofCovers(p, part: part, top: 1.6))
        }
        XCTAssertGreaterThan(volume(part), 150)
        XCTAssertLessThan(volume(part), 160)
    }

    func testConcaveOutlineAndProfileCutoutRemainConcaveAndOpen() throws {
        let l: [PCBPoint] = [.init(0,0), .init(4,0), .init(4,2), .init(2,2), .init(2,4), .init(0,4)]
        let concave = try XCTUnwrap(ManufacturingAssemblyBoard.parts(package: package([l]), thickness: 1.7).first)
        try assertClosed(concave)
        XCTAssertEqual(volume(concave), 12 * 1.7, accuracy: 1e-9)
        XCTAssertFalse(roofCovers(.init(3,3), part: concave, top: 1.7))
        let cutout = rectangle(x: 3, y: 3, width: 4, height: 4)
        let withHole = try XCTUnwrap(ManufacturingAssemblyBoard.parts(package: package([rectangle(), cutout]), thickness: 2).first)
        try assertClosed(withHole)
        XCTAssertEqual(volume(withHole), 84 * 2, accuracy: 1e-9)
        XCTAssertFalse(roofCovers(.init(5,5), part: withHole, top: 2))
    }

    func testStrokedUnorderedSegmentsAndArcPolylineCloseAtCenterline() throws {
        var p = package([rectangle()])
        let points = (0...32).map { i in PCBPoint(5 + 4 * cos(Double(i) * 2 * .pi / 32), 5 + 4 * sin(Double(i) * 2 * .pi / 32)) }
        let arc = ManufacturingPrimitive(id: UUID(), shapes: [.init(contours: [points], radius: 0.075)])
        p = replaceProfile(p, primitives: [arc])
        let round = try XCTUnwrap(ManufacturingAssemblyBoard.parts(package: p, thickness: 1).first)
        try assertClosed(round)
        XCTAssertEqual(volume(round), 32.0 / 2 * 16 * sin(2 * Double.pi / 32), accuracy: 1e-6)

        let corners = rectangle()
        let strokes = [2,0,3,1].map { i in
            ManufacturingPrimitive(id: UUID(), shapes: [.init(contours: [[corners[(i+1)%4], corners[i]]], radius: 0.075)])
        }
        let rectanglePart = try XCTUnwrap(ManufacturingAssemblyBoard.parts(package: replaceProfile(package([corners]), primitives: strokes), thickness: 1).first)
        try assertClosed(rectanglePart)
        XCTAssertEqual(volume(rectanglePart), 100, accuracy: 1e-9)
    }

    func testOpenSelfCrossingOverlappingAndNegativeProfilesFailExplicitly() {
        let p = package([rectangle()])
        let open = ManufacturingPrimitive(id: UUID(), shapes: [.init(contours: [[.init(0,0), .init(10,0), .init(10,10)]], radius: 0.075)])
        XCTAssertThrowsError(try ManufacturingAssemblyBoard.parts(package: replaceProfile(p, primitives: [open]), thickness: 1.6))
        XCTAssertThrowsError(try ManufacturingAssemblyBoard.parts(package: package([[.init(0,0),.init(5,5),.init(0,5),.init(5,0)]]), thickness: 1.6))
        let clear = ManufacturingPrimitive(id: UUID(), shapes: [.init(contours: [rectangle()], radius: 0)], isDark: false)
        XCTAssertThrowsError(try ManufacturingAssemblyBoard.parts(package: replaceProfile(p, primitives: [clear]), thickness: 1.6))
        let overlap = [ManufacturingDrill(id: UUID(), position: .init(4,4), diameter: 2, isPlated: false),
                       ManufacturingDrill(id: UUID(), position: .init(4.5,4), diameter: 2, isPlated: false)]
        XCTAssertThrowsError(try ManufacturingAssemblyBoard.parts(package: package([rectangle()], drills: overlap), thickness: 1.6))
        let outside = [ManufacturingDrill(id: UUID(), position: .init(10,5), diameter: 2, isPlated: false)]
        XCTAssertThrowsError(try ManufacturingAssemblyBoard.parts(package: package([rectangle()], drills: outside), thickness: 1.6))
        XCTAssertThrowsError(try ManufacturingAssemblyBoard.parts(package: p, thickness: .nan))
    }

    func testRealBallgunBoardWhenExplicitFixtureDirectoryIsProvided() throws {
        guard let folder = ProcessInfo.processInfo.environment["FTK_MANUFACTURING_FIXTURE_DIR"] else { throw XCTSkip("Private real-file check is opt-in.") }
        let root = URL(fileURLWithPath: folder)
        let p = try ElectronicsManufacturingImport.prepare(
            archive: Data(contentsOf: root.appendingPathComponent("Ballgunmain_hw.zip")),
            bom: Data(contentsOf: root.appendingPathComponent("bom.csv")),
            positions: Data(contentsOf: root.appendingPathComponent("positions.csv")), name: "Ballgun QA")
        let part = try XCTUnwrap(ManufacturingAssemblyBoard.parts(package: p, thickness: 1.6).first)
        try assertClosed(part)
        XCTAssertEqual(part.vertices.map(\.x).min(), 100)
        XCTAssertEqual(part.vertices.map(\.x).max(), 165)
        XCTAssertEqual(part.vertices.map(\.y).min(), -151)
        XCTAssertEqual(part.vertices.map(\.y).max(), -70)
        let analyticArea = 65.0 * 81 - p.drills.reduce(0) { area, drill in
            let radius = drill.diameter / 2
            let length = drill.end.map { hypot($0.x - drill.position.x, $0.y - drill.position.y) } ?? 0
            return area + .pi * radius * radius + length * drill.diameter
        }
        // The circle polygons are inscribed with a documented 0.01 mm maximum sag.
        XCTAssertGreaterThanOrEqual(volume(part), analyticArea * 1.6)
        XCTAssertEqual(volume(part), analyticArea * 1.6, accuracy: 2)
        for drill in p.drills { XCTAssertFalse(roofCovers(drill.position, part: part, top: 1.6)) }
    }

    private struct Edge: Hashable { let a: Int; let b: Int }
    private func assertClosed(_ part: ManufacturingAssemblyPart, file: StaticString = #filePath, line: UInt = #line) throws {
        XCTAssertEqual(part.indices.count % 3, 0, file: file, line: line)
        var edges: [Edge: Int] = [:]
        for index in stride(from: 0, to: part.indices.count, by: 3) {
            let a = part.indices[index], b = part.indices[index+1], c = part.indices[index+2]
            XCTAssertTrue([a,b,c].allSatisfy { part.vertices.indices.contains($0) }, file: file, line: line)
            XCTAssertEqual(Set([a,b,c]).count, 3, file: file, line: line)
            edges[.init(a:a,b:b), default:0] += 1
            edges[.init(a:b,b:c), default:0] += 1
            edges[.init(a:c,b:a), default:0] += 1
        }
        for (edge,count) in edges {
            XCTAssertEqual(count, 1, file: file, line: line)
            XCTAssertEqual(edges[.init(a:edge.b,b:edge.a)], 1, file: file, line: line)
        }
        XCTAssertGreaterThan(volume(part), 0, file: file, line: line)
    }
    private func volume(_ part: ManufacturingAssemblyPart) -> Double {
        stride(from: 0, to: part.indices.count, by: 3).reduce(0) { total, i in
            let a = part.vertices[part.indices[i]], b = part.vertices[part.indices[i+1]], c = part.vertices[part.indices[i+2]]
            return total + (a.x * (b.y*c.z-b.z*c.y) + a.y * (b.z*c.x-b.x*c.z) + a.z * (b.x*c.y-b.y*c.x)) / 6
        }
    }
    private func roofCovers(_ p: PCBPoint, part: ManufacturingAssemblyPart, top: Double) -> Bool {
        for i in stride(from: 0, to: part.indices.count, by: 3) {
            let a = part.vertices[part.indices[i]], b = part.vertices[part.indices[i+1]], c = part.vertices[part.indices[i+2]]
            guard a.z == top, b.z == top, c.z == top,
                  p.x >= min(a.x,min(b.x,c.x)), p.x <= max(a.x,max(b.x,c.x)),
                  p.y >= min(a.y,min(b.y,c.y)), p.y <= max(a.y,max(b.y,c.y)) else { continue }
            let x = (b.x-a.x)*(p.y-a.y)-(b.y-a.y)*(p.x-a.x)
            let y = (c.x-b.x)*(p.y-b.y)-(c.y-b.y)*(p.x-b.x)
            let z = (a.x-c.x)*(p.y-c.y)-(a.y-c.y)*(p.x-c.x)
            if x >= -1e-9, y >= -1e-9, z >= -1e-9 { return true }
        }
        return false
    }
    private func rectangle(x: Double = 0, y: Double = 0, width: Double = 10, height: Double = 10) -> [PCBPoint] {
        [.init(x,y), .init(x+width,y), .init(x+width,y+height), .init(x,y+height)]
    }
    private func package(_ loops: [[PCBPoint]], drills: [ManufacturingDrill] = []) -> ManufacturingPackage {
        let id = UUID(), lot = UUID()
        return .init(id: id, name: "Board mesh QA", layers: [.init(id: UUID(), name: "profile.gm1", kind: .profile,
            primitives: loops.map { .init(id: UUID(), shapes: [.init(contours: [$0], radius: 0)]) })],
            drills: drills, components: [], lots: [.init(id: lot, name: "QA", fittedComponentIDs: [])],
            activeLotID: lot, sources: [], bounds: .init(minimum: .init(), maximum: .init(10,10)))
    }
    private func replaceProfile(_ p: ManufacturingPackage, primitives: [ManufacturingPrimitive]) -> ManufacturingPackage {
        .init(id: p.id, name: p.name, layers: [.init(id: UUID(), name: "profile.gm1", kind: .profile, primitives: primitives)],
              drills: p.drills, components: p.components, lots: p.lots, activeLotID: p.activeLotID, sources: p.sources, bounds: p.bounds)
    }
}
