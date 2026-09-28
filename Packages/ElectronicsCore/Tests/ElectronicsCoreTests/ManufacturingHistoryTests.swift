import Foundation
import XCTest
@testable import ElectronicsCore

final class ManufacturingHistoryTests: XCTestCase {
    func testDocumentEncodersStoreArtworkOnlyOnce() throws {
        var document = try ElectronicsDocument.empty()
        let package = fixture(primitiveCount: 600)
        try ElectronicsCommands.apply(.manufacturing(.importPackage(package)), to: &document, expectedRevision: 0)
        let firstSize = try document.encoded().count
        for index in 0..<40 {
            try ElectronicsCommands.apply(.manufacturing(.setFitted(componentID: package.components[0].id, fitted: index % 2 != 0)),
                                          to: &document, expectedRevision: document.revision)
        }
        XCTAssertEqual(document.past.count, 41)
        for data in [try document.encoded(), try JSONEncoder().encode(document)] {
            let root = try object(data)
            let pool = try XCTUnwrap(root["manufacturingGeometry"] as? [String: Any])
            XCTAssertEqual(pool.count, 1)
            XCTAssertEqual(Set(pool.keys), [package.id.uuidString])
            let design = try XCTUnwrap(root["design"] as? [String: Any])
            let manufacturing = try XCTUnwrap(design["manufacturing"] as? [String: Any])
            XCTAssertEqual(manufacturing["geometryID"] as? String, package.id.uuidString)
            XCTAssertNil(manufacturing["layers"]); XCTAssertNil(manufacturing["drills"]); XCTAssertNil(manufacturing["bounds"])
            XCTAssertEqual(try ElectronicsDocument.decode(data), document)
            // Forty lot operations must not produce eighty copies of the artwork.
            XCTAssertLessThan(data.count, firstSize * 5)
        }
    }

    func testUndoPastImportReopenAndRedoRestorePooledHistory() throws {
        var document = try ElectronicsDocument.empty()
        let empty = document.design, package = fixture(primitiveCount: 3), component = package.components[0].id
        try ElectronicsCommands.apply(.manufacturing(.importPackage(package)), to: &document, expectedRevision: 0)
        try ElectronicsCommands.apply(.manufacturing(.setFitted(componentID: component, fitted: false)), to: &document, expectedRevision: 1)
        try document.undo(expectedRevision: 2)
        try document.undo(expectedRevision: 3)
        XCTAssertEqual(document.design, empty)
        XCTAssertEqual(document.future.count, 2)
        document = try ElectronicsDocument.decode(document.encoded())
        try document.redo(expectedRevision: 4)
        XCTAssertEqual(document.design.manufacturing, package)
        try document.redo(expectedRevision: 5)
        XCTAssertFalse(try XCTUnwrap(document.design.manufacturing).isFitted(component))
        XCTAssertEqual(document.design.manufacturing?.layers, package.layers)
        XCTAssertEqual(try ElectronicsDocument.decode(document.encoded()), document)
    }

    func testInlineFormatEightMigratesLosslessly() throws {
        var document = try ElectronicsDocument.empty()
        try ElectronicsCommands.apply(.manufacturing(.importPackage(fixture(primitiveCount: 3))), to: &document, expectedRevision: 0)
        try document.undo(expectedRevision: 1)
        var old = try object(document.encoded())
        old.removeValue(forKey: "manufacturingGeometry")
        // Domain types retain their original complete inline Codable representation.
        old["design"] = try object(JSONEncoder().encode(document.design))
        old["past"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(document.past))
        old["future"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(document.future))
        let restored = try ElectronicsDocument.decode(JSONSerialization.data(withJSONObject: old))
        XCTAssertEqual(restored, document)
        XCTAssertNotNil(try object(restored.encoded())["manufacturingGeometry"])
    }

    func testDanglingMismatchedMixedAndUnusedGeometryReferencesAreRejected() throws {
        var document = try ElectronicsDocument.empty()
        let package = fixture(primitiveCount: 3)
        try ElectronicsCommands.apply(.manufacturing(.importPackage(package)), to: &document, expectedRevision: 0)
        let original = try object(document.encoded())
        var missing = original; missing.removeValue(forKey: "manufacturingGeometry")
        XCTAssertThrowsError(try ElectronicsDocument.decode(JSONSerialization.data(withJSONObject: missing)))
        for mode in 0..<3 {
            var root = original
            var design = try XCTUnwrap(root["design"] as? [String: Any])
            var p = try XCTUnwrap(design["manufacturing"] as? [String: Any])
            if mode == 0 { p["geometryID"] = UUID().uuidString }
            if mode == 1 { p["layers"] = [] }
            if mode == 2 { p["geometryID"] = NSNull() }
            design["manufacturing"] = p; root["design"] = design
            XCTAssertThrowsError(try ElectronicsDocument.decode(JSONSerialization.data(withJSONObject: root)))
        }
        var unused = original
        var pool = try XCTUnwrap(unused["manufacturingGeometry"] as? [String: Any])
        pool[UUID().uuidString] = pool[package.id.uuidString]
        unused["manufacturingGeometry"] = pool
        XCTAssertThrowsError(try ElectronicsDocument.decode(JSONSerialization.data(withJSONObject: unused)))
    }

    func testHistoricalCAMCannotBypassIntegrityOrVersionChecks() throws {
        var document = try ElectronicsDocument.empty()
        try ElectronicsCommands.apply(.manufacturing(.importPackage(fixture(primitiveCount: 3))), to: &document, expectedRevision: 0)
        try document.undo(expectedRevision: 1)
        let original = try object(document.encoded())
        var older = original; older["formatVersion"] = 7
        XCTAssertThrowsError(try ElectronicsDocument.decode(JSONSerialization.data(withJSONObject: older)))
        var forged = original
        var future = try XCTUnwrap(forged["future"] as? [[String: Any]])
        var after = try XCTUnwrap(future[0]["after"] as? [String: Any])
        var p = try XCTUnwrap(after["manufacturing"] as? [String: Any])
        var lots = try XCTUnwrap(p["lots"] as? [[String: Any]])
        lots[0]["fittedComponentIDs"] = [UUID().uuidString]
        p["lots"] = lots; after["manufacturing"] = p; future[0]["after"] = after; forged["future"] = future
        XCTAssertThrowsError(try ElectronicsDocument.decode(JSONSerialization.data(withJSONObject: forged)))
    }

    func testSameIdentityCannotChangeGeometryAcrossHistory() throws {
        var document = try ElectronicsDocument.empty()
        let package = fixture(primitiveCount: 3)
        try ElectronicsCommands.apply(.manufacturing(.importPackage(package)), to: &document, expectedRevision: 0)
        let before = document
        var layers = package.layers
        layers[1] = .init(id: layers[1].id, name: layers[1].name, kind: layers[1].kind, primitives: [])
        let changed = ManufacturingPackage(id: package.id, name: package.name, layers: layers, drills: package.drills,
            components: package.components, lots: package.lots, activeLotID: package.activeLotID,
            sources: package.sources, bounds: package.bounds)
        XCTAssertThrowsError(try document.edit(title: "Forged geometry", expectedRevision: 1) { $0.manufacturing = changed })
        XCTAssertEqual(document, before)
    }

    func testNativeVersionsKeepNativeSchemaAndMigrate() throws {
        let document = try ElectronicsDocument.empty()
        let native = try object(document.encoded())
        XCTAssertNil(native["manufacturingGeometry"])
        for version in 1...7 {
            var old = native; old["formatVersion"] = version
            let restored = try ElectronicsDocument.decode(JSONSerialization.data(withJSONObject: old))
            XCTAssertEqual(restored, document)
        }
    }

    private func object(_ data: Data) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
    private func fixture(primitiveCount: Int) -> ManufacturingPackage {
        func id(_ n: Int) -> UUID { UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", n))! }
        let profile = ManufacturingLayer(id: id(2), name: "edge.gm1", kind: .profile,
            primitives: [.init(id: id(3), shapes: [.init(contours: [[.init(0,0), .init(10,0), .init(10,10), .init(0,10)]], radius: 0)])])
        let copper = (0..<primitiveCount).map { i in
            ManufacturingPrimitive(id: id(1000 + i),
                shapes: [.init(contours: [[.init(1 + Double(i % 80) * 0.1, 1 + Double(i / 80) * 0.1)]], radius: 0.03)])
        }
        let component = ManufacturingComponent(id: id(10), reference: "R1", value: "10k", footprint: "R0603", lcscPartNumber: "C123",
            placement: .init(reference: "R1", position: .init(3, 3), rotationDegrees: 0, side: .top))
        return .init(id: id(1), name: "Synthetic persistence", layers: [profile,
            .init(id: id(4), name: "top.gtl", kind: .topCopper, primitives: copper),
            .init(id: id(5), name: "bottom.gbl", kind: .bottomCopper, primitives: [])],
            drills: [.init(id: id(6), position: .init(1,1), diameter: 0.4, isPlated: true)], components: [component],
            lots: [.init(id: id(12), name: "Lot A", fittedComponentIDs: [component.id])], activeLotID: id(12), sources: [],
            bounds: .init(minimum: .init(0,0), maximum: .init(10,10)))
    }
}
