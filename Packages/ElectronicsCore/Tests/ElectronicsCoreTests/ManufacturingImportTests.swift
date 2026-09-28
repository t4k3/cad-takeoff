import XCTest
@testable import ElectronicsCore

final class ManufacturingImportTests: XCTestCase {
    func fixture() -> ManufacturingPackage {
        let profile = ManufacturingLayer(id: UUID(), name: "edge.gm1", kind: .profile,
            primitives: [.init(id: UUID(), shapes: [.init(contours: [[.init(100,-70), .init(165,-70), .init(165,-151), .init(100,-151)]], radius: 0.075)])])
        let id = UUID(), r = UUID(), t = UUID(), lot = UUID()
        return .init(id: id, name: "Test reale nelle coordinate originali", layers: [profile,
            .init(id: UUID(), name: "top.gtl", kind: .topCopper, primitives: []),
            .init(id: UUID(), name: "bottom.gbl", kind: .bottomCopper, primitives: [])],
            drills: [.init(id: UUID(), position: .init(104,-74), diameter: 3.2, isPlated: false)],
            components: [.init(id: r, reference: "R1", value: "10k", footprint: "R0805", lcscPartNumber: "C123",
                              placement: .init(reference: "R1", position: .init(120,-80), rotationDegrees: 90, side: .top)),
                         .init(id: t, reference: "T1", placement: .init(reference: "T1", position: .init(148,-82), rotationDegrees: 0, side: .bottom))],
            lots: [.init(id: lot, name: "Lotto A", fittedComponentIDs: [r])], activeLotID: lot, sources: [],
            bounds: .init(minimum: .init(100,-151), maximum: .init(165,-70)))
    }

    func testPreviewImportUndoReopenRedoPreserveEverything() throws {
        var document = try ElectronicsDocument.empty()
        let original = document, package = fixture()
        let command = ElectronicsCommand.manufacturing(.importPackage(package))
        let preview = try ElectronicsCommands.preview(command, document: document, expectedRevision: 0)
        XCTAssertEqual(document, original); XCTAssertTrue(preview.canApply)
        XCTAssertEqual(preview.design.manufacturing, package)
        XCTAssertTrue(preview.issues.contains { $0.code == "manufacturing_not_fitted" && $0.subject == "T1" })
        try ElectronicsCommands.apply(command, to: &document, expectedRevision: 0)
        XCTAssertEqual(document.past.count, 1); XCTAssertEqual(document.revision, 1)
        XCTAssertEqual(document.design.manufacturing, package)
        try document.undo(expectedRevision: 1)
        XCTAssertEqual(document.design, original.design)
        document = try ElectronicsDocument.decode(document.encoded())
        try document.redo(expectedRevision: 2)
        XCTAssertEqual(document.design.manufacturing, package)
        XCTAssertEqual(document.formatVersion, 8)
        XCTAssertEqual(try ElectronicsDocument.decode(document.encoded()), document)
    }

    func testLotOmissionNeverRemovesGeometryOrOtherLot() throws {
        var document = try ElectronicsDocument.empty()
        let package = fixture(), newLot = UUID(), r = package.components[0].id, t = package.components[1].id
        try ElectronicsCommands.apply(.manufacturing(.importPackage(package)), to: &document, expectedRevision: 0)
        try ElectronicsCommands.apply(.manufacturing(.addLot(id: newLot, name: "Lotto B")), to: &document, expectedRevision: 1)
        try ElectronicsCommands.apply(.manufacturing(.setFitted(componentID: r, fitted: false)), to: &document, expectedRevision: 2)
        try ElectronicsCommands.apply(.manufacturing(.setFitted(componentID: t, fitted: true)), to: &document, expectedRevision: 3)
        let current = try XCTUnwrap(document.design.manufacturing)
        XCTAssertEqual(current.components, package.components); XCTAssertEqual(current.layers, package.layers)
        XCTAssertEqual(current.drills, package.drills)
        XCTAssertEqual(current.lots[0], package.lots[0])
        XCTAssertEqual(current.activeLot?.fittedComponentIDs, [t])
        let noOp = document
        try ElectronicsCommands.apply(.manufacturing(.setFitted(componentID: t, fitted: true)), to: &document, expectedRevision: 4)
        XCTAssertEqual(document, noOp)
        try ElectronicsCommands.apply(.manufacturing(.selectLot(package.activeLotID)), to: &document, expectedRevision: 4)
        XCTAssertTrue(document.design.manufacturing!.isFitted(r)); XCTAssertFalse(document.design.manufacturing!.isFitted(t))
        XCTAssertEqual(try ElectronicsDocument.decode(document.encoded()), document)
    }

    func testReimportAddsLotAndRetainsMissingComponentsWithSameIDs() throws {
        var document = try ElectronicsDocument.empty()
        let original = fixture()
        try ElectronicsCommands.apply(.manufacturing(.importPackage(original)), to: &document, expectedRevision: 0)
        let before = document
        try ElectronicsCommands.apply(.manufacturing(.importPackage(original)), to: &document, expectedRevision: 1)
        XCTAssertEqual(before, document)
        var next = original
        next.components.removeLast()
        let lot = ManufacturingLot(id: UUID(), name: "Lotto ridotto", fittedComponentIDs: [])
        next.lots = [lot]; next.activeLotID = lot.id
        try ElectronicsCommands.apply(.manufacturing(.importPackage(next)), to: &document, expectedRevision: 1)
        XCTAssertEqual(document.design.manufacturing?.components, original.components)
        XCTAssertEqual(document.design.manufacturing?.lots.count, 2)
        XCTAssertEqual(document.design.manufacturing?.activeLot?.fittedComponentIDs, [])
        XCTAssertEqual(document.design.manufacturing?.layers, original.layers)
    }

    func testStaleInvalidAndForeignPackagesAreAtomic() throws {
        var document = try ElectronicsDocument.empty()
        let p = fixture()
        try ElectronicsCommands.apply(.manufacturing(.importPackage(p)), to: &document, expectedRevision: 0)
        let before = document
        XCTAssertThrowsError(try ElectronicsCommands.apply(.manufacturing(.setFitted(componentID: p.components[0].id, fitted: false)), to: &document, expectedRevision: 0))
        XCTAssertEqual(document, before)
        XCTAssertThrowsError(try ElectronicsCommands.apply(.manufacturing(.importPackage(fixture())), to: &document, expectedRevision: 1))
        XCTAssertEqual(document, before)
        var broken = p; broken.lots[0].fittedComponentIDs.append(UUID())
        XCTAssertThrowsError(try ElectronicsCommands.apply(.manufacturing(.importPackage(broken)), to: &document, expectedRevision: 1))
        XCTAssertEqual(document, before)
        XCTAssertThrowsError(try ElectronicsCommands.apply(.manufacturing(.setFitted(componentID: UUID(), fitted: true)), to: &document, expectedRevision: 1))
        XCTAssertEqual(document, before)
        XCTAssertThrowsError(try ElectronicsCommands.apply(.addNet(.init(name: "FORBIDDEN")), to: &document, expectedRevision: 1))
        XCTAssertEqual(document, before)
    }

    func testCAMIsNeverExportedAsEmptyNativeBoardOrAssembly() throws {
        var document = try ElectronicsDocument.empty()
        try ElectronicsCommands.apply(.manufacturing(.importPackage(fixture())), to: &document, expectedRevision: 0)
        XCTAssertThrowsError(try ElectronicsFabrication.export(document: document, expectedRevision: 1))
        XCTAssertThrowsError(try ElectronicsAssembly.export(document))
        XCTAssertEqual(ElectronicsValidation.electrical(document.design).first?.code, "manufacturing_erc_unavailable")
    }

    func testChangingBOMCannotAlterPreviousLotParts() throws {
        var document = try ElectronicsDocument.empty()
        let p = fixture()
        try ElectronicsCommands.apply(.manufacturing(.importPackage(p)), to: &document, expectedRevision: 0)
        let before = document
        for field in ["value", "footprint", "part"] {
            var incoming = p
            incoming.lots = [.init(id: UUID(), name: "B", fittedComponentIDs: [])]
            incoming.activeLotID = incoming.lots[0].id
            if field == "value" { incoming.components[0].value = "22k" }
            if field == "footprint" { incoming.components[0].footprint = "R0402" }
            if field == "part" { incoming.components[0].lcscPartNumber = "C456" }
            XCTAssertThrowsError(try ElectronicsCommands.apply(.manufacturing(.importPackage(incoming)), to: &document, expectedRevision: 1))
            XCTAssertEqual(document, before)
        }
    }

    func testLotMembershipOrderIsNotASemanticChange() throws {
        var p = fixture()
        p.lots[0].fittedComponentIDs = p.components.map(\.id)
        var document = try ElectronicsDocument.empty()
        try ElectronicsCommands.apply(.manufacturing(.importPackage(p)), to: &document, expectedRevision: 0)
        let id = p.components[0].id
        try ElectronicsCommands.apply(.manufacturing(.setFitted(componentID: id, fitted: false)), to: &document, expectedRevision: 1)
        try ElectronicsCommands.apply(.manufacturing(.setFitted(componentID: id, fitted: true)), to: &document, expectedRevision: 2)
        let before = document
        try ElectronicsCommands.apply(.manufacturing(.importPackage(p)), to: &document, expectedRevision: 3)
        XCTAssertEqual(document, before)
    }

    func testOlderVersionsMigrateButCannotSmuggleCAM() throws {
        var document = try ElectronicsDocument.empty()
        let encoder = JSONEncoder()
        var old = try XCTUnwrap(JSONSerialization.jsonObject(with: document.encoded()) as? [String: Any])
        old["formatVersion"] = 7
        XCTAssertEqual(try ElectronicsDocument.decode(JSONSerialization.data(withJSONObject: old)).formatVersion, 8)
        try ElectronicsCommands.apply(.manufacturing(.importPackage(fixture())), to: &document, expectedRevision: 0)
        old = try XCTUnwrap(JSONSerialization.jsonObject(with: encoder.encode(document)) as? [String: Any])
        old["formatVersion"] = 7
        XCTAssertThrowsError(try ElectronicsDocument.decode(JSONSerialization.data(withJSONObject: old)))
        old["formatVersion"] = 9
        XCTAssertThrowsError(try ElectronicsDocument.decode(JSONSerialization.data(withJSONObject: old)))
    }

    func testRealProductionManyLotEditsAndReopenWhenExplicitlySupplied() throws {
        guard let path = ProcessInfo.processInfo.environment["FTK_MANUFACTURING_FIXTURE_DIR"] else {
            throw XCTSkip("Pacchetto privato opzionale: impostare FTK_MANUFACTURING_FIXTURE_DIR per il collaudo reale.")
        }
        let folder = URL(fileURLWithPath: path)
        let p = try ElectronicsManufacturingImport.prepare(
            archive: Data(contentsOf: folder.appendingPathComponent("Ballgunmain_hw.zip")),
            bom: Data(contentsOf: folder.appendingPathComponent("bom.csv")),
            positions: Data(contentsOf: folder.appendingPathComponent("positions.csv")), name: "Collaudo Ballgun")
        XCTAssertEqual(p.layers.count, 9); XCTAssertEqual(p.components.count, 86)
        XCTAssertEqual(p.drills.count, 158); XCTAssertEqual(p.drills.filter { $0.end != nil }.count, 4)
        XCTAssertEqual(p.bounds.width, 65); XCTAssertEqual(p.bounds.height, 81)
        let component = try XCTUnwrap(p.components.first { $0.reference == "R1" })
        let started = Date()
        let snapshot = try ManufacturingSnapshot(package: p)
        let snapshotMS = Date().timeIntervalSince(started) * 1000
        XCTAssertTrue(snapshot.pick(point: try XCTUnwrap(component.placement).position, tolerance: 0.1).contains { $0.id == component.id })
        var queryMS: [Double] = []
        for i in 0..<200 {
            let point = PCBPoint(100 + Double(i % 20) * 3.25, -151 + Double(i / 20) * 8.1)
            let begin = Date()
            _ = snapshot.pick(point: point, tolerance: 0.2)
            _ = snapshot.snapTargets(near: point, radius: 0.2)
            queryMS.append(Date().timeIntervalSince(begin) * 1000)
        }
        print("Ballgun snapshot \(snapshotMS) ms, pick+snap p95 \(queryMS.sorted()[189]) ms (metrica, non soglia CI).")
        var d = try ElectronicsDocument.empty()
        try ElectronicsCommands.apply(.manufacturing(.importPackage(p)), to: &d, expectedRevision: 0)
        for i in 0..<100 {
            try ElectronicsCommands.apply(.manufacturing(.setFitted(componentID: component.id, fitted: i % 2 != 0)), to: &d, expectedRevision: d.revision)
        }
        XCTAssertEqual(d.past.count, 101)
        try d.undo(expectedRevision: d.revision)
        let data = try d.encoded()
        XCTAssertLessThan(data.count, 32 * 1024 * 1024)
        let reopened = try ElectronicsDocument.decode(data)
        XCTAssertEqual(reopened, d)
        d = reopened
        try d.redo(expectedRevision: d.revision)
        XCTAssertTrue(d.design.manufacturing!.isFitted(component.id))
        XCTAssertEqual(d.design.manufacturing?.layers, p.layers)
        print("Ballgun: 100 modifiche lotto, undo/riapertura/redo; \(data.count) byte salvati.")
    }
}
