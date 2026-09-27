import Foundation
import XCTest
@testable import ElectronicsCore

final class ElectronicsCoreTests: XCTestCase {
    private func fixture() throws -> ElectronicsDocument {
        let url = Bundle.module.url(forResource: "assembly", withExtension: "json", subdirectory: "Fixtures")!
        return try ElectronicsDocument.decode(Data(contentsOf: url))
    }
    private func id(_ n: Int) -> UUID { UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", n))! }
    private func failure(_ body: () throws -> Void, code: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try body(), file: file, line: line) { error in
            XCTAssertTrue((error as? ElectronicsFailure)?.issues.contains { $0.code == code } == true,
                          "Expected \(code), got \(error)", file: file, line: line)
        }
    }

    func testFixtureIntegrityAndDocumentRoundTrip() throws {
        let doc = try fixture()
        XCTAssertTrue(ElectronicsValidation.integrity(doc.design).isEmpty)
        XCTAssertTrue(ElectronicsValidation.electrical(doc.design).isEmpty)
        XCTAssertEqual(try ElectronicsDocument.decode(doc.encoded()), doc)
        XCTAssertEqual(try doc.encoded(), try doc.encoded())
    }

    func testAssemblyExportsPopulationAndGroupsByActualDevice() throws {
        let result = try ElectronicsAssembly.export(fixture())
        XCTAssertEqual(result.instances3D.map(\.reference), ["R1", "R2", "R4", "R5", "R6"])
        XCTAssertTrue(result.bomCSV.contains("\"R1,R2,R5\""))
        XCTAssertTrue(result.bomCSV.contains("\"R6\""))
        XCTAssertFalse(result.bomCSV.contains("R3")); XCTAssertFalse(result.bomCSV.contains("R4"))
        XCTAssertFalse(result.cplCSV.contains("R3")); XCTAssertFalse(result.cplCSV.contains("R4"))
        XCTAssertTrue(result.bomCSV.contains("\"10k, 1% \"\"thin\"\"\""))
        XCTAssertFalse(result.fabricationReady)
        XCTAssertTrue(result.issues.contains { $0.code == "assembly_data_only" })
    }

    func testCentroidOriginAndExplicitSideRotations() throws {
        let result = try ElectronicsAssembly.export(fixture())
        XCTAssertTrue(result.cplCSV.contains("\"R1\",\"10.100000\",\"20.200000\",\"Top\",\"180.000000\""))
        XCTAssertTrue(result.cplCSV.contains("\"R2\",\"30.100000\",\"19.800000\",\"Bottom\",\"90.000000\""))
        XCTAssertTrue(result.cplCSV.contains("\"R5\",\"33.900000\",\"7.800000\",\"Top\",\"0.000000\""))
    }

    func testVariantUsesSameSelectionForBOMCPLAndMechanicalInstances() throws {
        let result = try ElectronicsAssembly.export(fixture(), variantID: id(301))
        XCTAssertFalse(result.bomCSV.contains("R2")); XCTAssertFalse(result.cplCSV.contains("R2"))
        XCTAssertFalse(result.instances3D.contains { $0.reference == "R2" })
        // DNP/variants change assembly, not the copper pads in the manufactured board.
        XCTAssertTrue(result.connectivity.pads.contains { $0.componentID == id(102) })
        failure({ _ = try ElectronicsAssembly.export(self.fixture(), variantID: UUID()) }, code: "unknown_variant")
    }

    func testUnplacedPartAndMissingSupplierNeverDisappearSilently() throws {
        var d = try fixture().design
        d.board.placements.removeAll { $0.componentID == id(101) }
        failure({ _ = try ElectronicsAssembly.export(ElectronicsDocument(design: d)) }, code: "unplaced_component")
        d = try fixture().design; d.library.devices[0].jlc = nil
        failure({ _ = try ElectronicsAssembly.export(ElectronicsDocument(design: d)) }, code: "missing_supplier_part")
    }

    func testMissingBottomCalibrationBlocksOnlyThatPopulatedSide() throws {
        var d = try fixture().design
        d.library.devices[0].jlc?.bottomRotation = nil
        let doc = try ElectronicsDocument(design: d)
        failure({ _ = try ElectronicsAssembly.export(doc) }, code: "unverified_assembly_rotation")
        XCTAssertNoThrow(try ElectronicsAssembly.export(doc, variantID: id(301)))
    }

    func testMechanicalTransformIsRigidAndPlacesBottomOutsideBoard() throws {
        let result = try ElectronicsAssembly.export(fixture())
        let top = try XCTUnwrap(result.instances3D.first { $0.reference == "R1" }).transform
        let bottom = try XCTUnwrap(result.instances3D.first { $0.reference == "R2" }).transform
        XCTAssertEqual(top[3], 10.8, accuracy: 1e-9); XCTAssertEqual(top[7], 22.1, accuracy: 1e-9)
        XCTAssertEqual(top[11], 1.9, accuracy: 1e-9)
        XCTAssertEqual(bottom[3], 30.8, accuracy: 1e-9); XCTAssertEqual(bottom[7], 21.9, accuracy: 1e-9)
        XCTAssertEqual(bottom[11], -0.3, accuracy: 1e-9)
        for m in [top, bottom] {
            let determinant = m[0] * (m[5] * m[10] - m[6] * m[9]) - m[1] * (m[4] * m[10] - m[6] * m[8]) + m[2] * (m[4] * m[9] - m[5] * m[8])
            XCTAssertEqual(determinant, 1, accuracy: 1e-9)
            for row in 0..<3 { XCTAssertEqual((0..<3).reduce(0.0) { $0 + m[row * 4 + $1] * m[row * 4 + $1] }, 1, accuracy: 1e-9) }
        }
    }

    func testPadsFollowExplicitPinMappingNotPinNumbers() throws {
        var d = try fixture().design
        d.library.devices[0].pinMap.reverse()
        d.library.devices[0].pinMap[0].padID = id(21)
        d.library.devices[0].pinMap[1].padID = id(22)
        let snapshot = try ElectronicsConnectivity.snapshot(d)
        let pad = try XCTUnwrap(snapshot.pads.first { $0.componentID == id(101) && $0.padID == id(21) })
        XCTAssertEqual(pad.pinID, id(12)); XCTAssertEqual(pad.netID, id(202))
    }

    func testConnectivityTreeAndBottomPadsAreDeterministic() throws {
        var d = try fixture().design
        let a = try ElectronicsConnectivity.snapshot(d)
        XCTAssertEqual(a.pads.count, 10)
        XCTAssertEqual(a.airwires.count, 8) // two nets, five placed pads per net
        XCTAssertEqual(a.unplacedComponents, [id(103)])
        let bottom = try XCTUnwrap(a.pads.first { $0.componentID == id(102) && $0.padID == id(21) })
        XCTAssertEqual(bottom.center.x, 31, accuracy: 1e-9); XCTAssertEqual(bottom.center.y, 22.8, accuracy: 1e-9)
        XCTAssertEqual(bottom.copperSides, [.bottom])
        d.components.reverse(); d.nets.reverse(); d.connections.reverse(); d.board.placements.reverse()
        XCTAssertEqual(try ElectronicsConnectivity.snapshot(d), a)
        XCTAssertEqual(try ElectronicsAssembly.export(ElectronicsDocument(design: d)).bomCSV,
                       try ElectronicsAssembly.export(fixture()).bomCSV)
    }

    func testMultiplePadsCanMapToOnePinAndThroughPadsSpanBothSides() throws {
        var d = try fixture().design
        var pad = d.library.footprints[0].pads[0]
        pad.id = id(23); pad.drillDiameter = 0.3
        d.library.footprints[0].pads.append(pad)
        for i in d.library.devices.indices { d.library.devices[i].pinMap.append(.init(pinID: id(11), padID: id(23))) }
        XCTAssertTrue(ElectronicsValidation.integrity(d).isEmpty)
        let snapshot = try ElectronicsConnectivity.snapshot(d)
        XCTAssertEqual(snapshot.pads.first { $0.padID == id(23) }?.copperSides, [.top, .bottom])
    }

    func testRejectsIdentityMappingAndReferenceCorruptionWithoutCrashing() throws {
        let original = try fixture().design
        let corruptions: [(String, (inout ElectronicsDesign) -> Void)] = [
            ("duplicate_identity", { $0.components.append($0.components[0]) }),
            ("duplicate_identity", { $0.components[1].reference = "r1" }),
            ("duplicate_identity", { $0.connections.append($0.connections[0]) }),
            ("duplicate_identity", { $0.library.symbols.append($0.library.symbols[0]) }),
            ("invalid_pin_map", { $0.library.devices[0].pinMap.removeLast() }),
            ("duplicate_identity", { $0.library.devices[0].pinMap.append($0.library.devices[0].pinMap[0]) }),
            ("missing_library_revision", { $0.library.devices[0].footprint.revision = 2 }),
            ("missing_device_revision", { $0.components[0].device.revision = 2 }),
            ("dangling_net", { $0.connections[0].netID = UUID() }),
            ("dangling_pin", { $0.connections[0].pin.pinID = UUID() }),
            ("dangling_placement", { $0.board.placements[0].componentID = UUID() }),
            ("dangling_variant", { $0.variants[0].excludedComponents.append(UUID()) })
        ]
        for (code, mutate) in corruptions {
            var d = original; mutate(&d)
            failure({ _ = try ElectronicsDocument(design: d) }, code: code)
        }
    }

    func testRejectsNonFiniteAndMalformedGeometry() throws {
        let original = try fixture().design
        let corruptions: [(String, (inout ElectronicsDesign) -> Void)] = [
            ("invalid_thickness", { $0.board.thickness = .nan }),
            ("invalid_placement", { $0.board.placements[0].position.x = .infinity }),
            ("invalid_placement", { $0.board.placements[0].rotationDegrees = .nan }),
            ("invalid_pad", { $0.library.footprints[0].pads[0].size.x = -1 }),
            ("invalid_drill", { $0.library.footprints[0].pads[0].drillDiameter = 1 }),
            ("invalid_outline", { $0.board.outline = [.init(0,0), .init(10,10), .init(0,10), .init(10,0)] }),
            ("invalid_outline", { $0.board.outline = [.init(0,0), .init(10,0), .init(5,0), .init(5,10)] }),
            ("invalid_outline", { $0.board.outline.append($0.board.outline[0]) }),
            ("invalid_model_path", { $0.library.footprints[0].model3D?.relativePath = "../secret.step" }),
            ("invalid_model_hash", { $0.library.footprints[0].model3D?.sha256 = "unknown" })
        ]
        for (code, mutate) in corruptions {
            var d = original; mutate(&d)
            failure({ _ = try ElectronicsDocument(design: d) }, code: code)
        }
    }

    func testElectricalChecksFindDriversAndRespectExplicitNC() throws {
        var d = try fixture().design
        d.library.symbols[0].pins[0].electricalType = .output
        XCTAssertTrue(ElectronicsValidation.electrical(d).contains { $0.code == "multiple_drivers" })
        let onlyR1 = Set(d.components.dropFirst().map(\.id))
        XCTAssertFalse(ElectronicsValidation.electrical(d, excluding: onlyR1).contains { $0.code == "multiple_drivers" })
        d = try fixture().design
        d.connections[0].netID = nil
        XCTAssertFalse(ElectronicsValidation.electrical(d).contains { $0.code == "unconnected_pin" })
        d.connections.removeFirst()
        XCTAssertTrue(ElectronicsValidation.electrical(d).contains { $0.code == "unconnected_pin" })
        d = try fixture().design; d.library.symbols[0].pins[0].electricalType = .noConnect
        XCTAssertTrue(ElectronicsValidation.electrical(d).contains { $0.code == "nc_pin_connected" })
    }

    func testAtomicEditsUndoRedoAndReopenPreserveHistory() throws {
        var doc = try fixture()
        let original = doc.design
        try doc.edit(title: "Sposta R1", expectedRevision: 0) { $0.board.placements[0].position.x = 17 }
        XCTAssertEqual(doc.revision, 1)
        doc = try ElectronicsDocument.decode(doc.encoded())
        try doc.undo(expectedRevision: 1)
        XCTAssertEqual(doc.design, original); XCTAssertEqual(doc.revision, 2)
        doc = try ElectronicsDocument.decode(doc.encoded())
        try doc.redo(expectedRevision: 2)
        XCTAssertEqual(doc.design.board.placements[0].position.x, 17); XCTAssertEqual(doc.revision, 3)
        failure({ try doc.edit(title: "Obsoleto", expectedRevision: 1) { $0.name = "Bad" } }, code: "stale_revision")
        XCTAssertEqual(doc.revision, 3)
    }

    func testFailedEditDoesNotPartiallyMutateDocument() throws {
        var doc = try fixture(); let before = doc
        failure({ try doc.edit(title: "Elimina collegamenti", expectedRevision: 0) { $0.components.removeAll() } }, code: "dangling_pin")
        XCTAssertEqual(doc, before)
        enum Deliberate: Error { case failure }
        XCTAssertThrowsError(try doc.edit(title: "Interrotta", expectedRevision: 0) { $0.name = "changed"; throw Deliberate.failure })
        XCTAssertEqual(doc, before)
        try doc.edit(title: "Nessuna modifica", expectedRevision: 0) { _ in }
        XCTAssertEqual(doc, before)
    }

    func testLibraryChangesRequireNewPinnedRevision() throws {
        var doc = try fixture()
        failure({ try doc.edit(title: "Impronta", expectedRevision: 0) { $0.library.footprints[0].pads[0].center.x = -1 } }, code: "changed_library_revision")
        try doc.edit(title: "Nuova revisione", expectedRevision: 0) {
            var footprint = $0.library.footprints[0]
            footprint.key.revision = 2; footprint.pads[0].center.x = -1
            $0.library.footprints.append(footprint)
        }
        XCTAssertEqual(doc.design.library.devices[0].footprint.revision, 1)
        XCTAssertEqual(try ElectronicsDocument.decode(doc.encoded()), doc)
    }

    func testUndoBranchCannotReuseAnExistingLibraryRevisionWithDifferentContent() throws {
        var doc = try fixture()
        try doc.edit(title: "Revisione 2", expectedRevision: 0) {
            var footprint = $0.library.footprints[0]; footprint.key.revision = 2
            $0.library.footprints.append(footprint)
        }
        try doc.undo(expectedRevision: 1)
        failure({ try doc.edit(title: "Revisione 2 diversa", expectedRevision: 2) {
            var footprint = $0.library.footprints[0]; footprint.key.revision = 2; footprint.name = "Changed"
            $0.library.footprints.append(footprint)
        } }, code: "changed_library_revision")
    }

    func testNewEditAfterUndoDropsRedoAndKeepsRevisionMonotonic() throws {
        var doc = try fixture()
        try doc.edit(title: "A", expectedRevision: 0) { $0.name = "A" }
        try doc.edit(title: "B", expectedRevision: 1) { $0.name = "B" }
        try doc.undo(expectedRevision: 2)
        try doc.edit(title: "C", expectedRevision: 3) { $0.name = "C" }
        XCTAssertTrue(doc.future.isEmpty); XCTAssertEqual(doc.revision, 4)
        XCTAssertEqual(try ElectronicsDocument.decode(doc.encoded()), doc)
    }

    func testNewerFileVersionAndBrokenHistoryAreRejected() throws {
        var doc = try fixture()
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: doc.encoded()) as? [String: Any])
        json["formatVersion"] = 999
        failure({ _ = try ElectronicsDocument.decode(JSONSerialization.data(withJSONObject: json)) }, code: "unsupported_version")
        try doc.edit(title: "Changed", expectedRevision: 0) { $0.name = "Changed" }
        json = try XCTUnwrap(JSONSerialization.jsonObject(with: doc.encoded()) as? [String: Any])
        var state = json["design"] as! [String: Any]; state["name"] = "Tampered"; json["design"] = state
        failure({ _ = try ElectronicsDocument.decode(JSONSerialization.data(withJSONObject: json)) }, code: "invalid_history")
    }
}
