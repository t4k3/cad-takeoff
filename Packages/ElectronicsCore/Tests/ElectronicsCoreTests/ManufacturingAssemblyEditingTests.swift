import Foundation
import XCTest
@testable import ElectronicsCore

final class ManufacturingAssemblyEditingTests: XCTestCase {
    func testPreviewAlignmentIsAtomicAndDoesNotChangeCPLOrArtwork() throws {
        var d = try document(), before = d
        let p = try XCTUnwrap(d.design.manufacturing), c = p.components[0]
        let binding = try sampleBinding()
        let command = ElectronicsCommand.manufacturing(.setComponentModel(componentID: c.id, binding: binding))
        let preview = try ElectronicsCommands.preview(command, document: d, expectedRevision: d.revision)
        XCTAssertEqual(d, before); XCTAssertTrue(preview.canApply)
        XCTAssertEqual(preview.design.manufacturing?.components[0].modelBinding, binding)
        try ElectronicsCommands.apply(command, to: &d, expectedRevision: d.revision)
        XCTAssertEqual(d.past.count, before.past.count + 1)
        XCTAssertEqual(d.design.manufacturing?.components[0].placement, c.placement)
        XCTAssertEqual(d.design.manufacturing?.layers, p.layers)
        XCTAssertEqual(d.design.manufacturing?.drills, p.drills)
        XCTAssertEqual(d.design.manufacturing?.lots, p.lots)
        before = d
        try ElectronicsCommands.apply(command, to: &d, expectedRevision: d.revision)
        XCTAssertEqual(d, before, "Identical alignment must not create phantom undo steps")
        XCTAssertThrowsError(try ElectronicsCommands.apply(.manufacturing(.setBoardThickness(2)), to: &d, expectedRevision: 0))
        XCTAssertEqual(d, before)
    }

    func testThicknessAndAlignmentSurviveHistoryPoolingLotChangeReopenUndoRedo() throws {
        var d = try document()
        let original = try XCTUnwrap(d.design.manufacturing), c = original.components[0].id
        let binding = try sampleBinding()
        try apply(.setBoardThickness(2.4), to: &d)
        try apply(.setComponentModel(componentID: c, binding: binding), to: &d)
        let saved = d
        try d.undo(expectedRevision: d.revision)
        let bytes = try d.encoded(), json = try object(bytes)
        XCTAssertEqual(json["formatVersion"] as? Int, 9)
        XCTAssertEqual((json["manufacturingGeometry"] as? [String: Any])?.count, 1)
        XCTAssertFalse(String(decoding: bytes, as: UTF8.self).contains("\"vertices\""), "Meshes are derived, not duplicated throughout history")
        d = try ElectronicsDocument.decode(bytes)
        XCTAssertNil(d.design.manufacturing?.components[0].modelBinding)
        try d.redo(expectedRevision: d.revision)
        XCTAssertEqual(d.design, saved.design)
        try apply(.addLot(id: UUID(), name: "Senza R1"), to: &d)
        try apply(.setFitted(componentID: c, fitted: false), to: &d)
        XCTAssertEqual(d.design.manufacturing?.components[0].modelBinding, binding)
        XCTAssertEqual(d.design.manufacturing?.assemblySettings?.boardThickness, 2.4)
        try apply(.selectLot(original.activeLotID), to: &d)
        XCTAssertTrue(try XCTUnwrap(d.design.manufacturing).isFitted(c))
        XCTAssertEqual(try ElectronicsDocument.decode(d.encoded()), d)
        try apply(.setComponentModel(componentID: c, binding: nil), to: &d)
        try apply(.setBoardThickness(nil), to: &d)
        XCTAssertNil(d.design.manufacturing?.components[0].modelBinding)
        XCTAssertNil(d.design.manufacturing?.assemblySettings)
        try d.undo(expectedRevision: d.revision)
        try d.undo(expectedRevision: d.revision)
        XCTAssertEqual(d.design.manufacturing?.components[0].modelBinding, binding)
        XCTAssertEqual(d.design.manufacturing?.assemblySettings?.boardThickness, 2.4)
    }

    func testInvalidSettingsAreRejectedWithoutHistoryOrDataChanges() throws {
        var d = try document()
        let before = d, c = try XCTUnwrap(d.design.manufacturing?.components.first?.id)
        for thickness in [Double.nan, .infinity, -.infinity, 0, -1, 20.01] {
            XCTAssertThrowsError(try apply(.setBoardThickness(thickness), to: &d))
            XCTAssertEqual(d, before)
        }
        for field in 0..<4 {
            var binding = try sampleBinding()
            if field == 0 { binding.offset.x = .nan }
            if field == 1 { binding.offset.z = 1001 }
            if field == 2 { binding.rotationDegrees.y = .infinity }
            if field == 3 { binding.modelKey = "absent-v99" }
            XCTAssertThrowsError(try apply(.setComponentModel(componentID: c, binding: binding), to: &d))
            XCTAssertEqual(d, before)
        }
        XCTAssertThrowsError(try apply(.setComponentModel(componentID: UUID(), binding: try sampleBinding()), to: &d))
        XCTAssertEqual(d, before)
        var native = try ElectronicsDocument.empty()
        XCTAssertThrowsError(try apply(.setBoardThickness(1.6), to: &native))
        XCTAssertEqual(native.revision, 0)
    }

    func testFormatEightPooledMigrationAndVersionGuardAlsoCoverFuture() throws {
        var d = try document()
        var legacy = try object(d.encoded()); legacy["formatVersion"] = 8
        let migrated = try ElectronicsDocument.decode(JSONSerialization.data(withJSONObject: legacy))
        XCTAssertEqual(migrated, d); XCTAssertEqual(migrated.formatVersion, 9)
        try apply(.setBoardThickness(2), to: &d)
        try apply(.setComponentModel(componentID: try XCTUnwrap(d.design.manufacturing?.components[0].id), binding: try sampleBinding()), to: &d)
        try d.undo(expectedRevision: d.revision)
        try d.undo(expectedRevision: d.revision)
        XCTAssertNil(d.design.manufacturing?.assemblySettings)
        var wrongVersion = try object(d.encoded()); wrongVersion["formatVersion"] = 8
        XCTAssertThrowsError(try ElectronicsDocument.decode(JSONSerialization.data(withJSONObject: wrongVersion)))
        // Invalid alignment in a redo branch is rejected even with a valid version.
        var corrupt = try object(d.encoded())
        var future = try XCTUnwrap(corrupt["future"] as? [[String: Any]])
        var after = try XCTUnwrap(future[0]["after"] as? [String: Any])
        var package = try XCTUnwrap(after["manufacturing"] as? [String: Any])
        var components = try XCTUnwrap(package["components"] as? [[String: Any]])
        var binding = try XCTUnwrap(components[0]["modelBinding"] as? [String: Any])
        binding["modelKey"] = "unknown"; components[0]["modelBinding"] = binding
        package["components"] = components; after["manufacturing"] = package
        future[0]["after"] = after; corrupt["future"] = future
        XCTAssertThrowsError(try ElectronicsDocument.decode(JSONSerialization.data(withJSONObject: corrupt)))
    }

    func testCannotConfirmAlignmentWithoutPlacement() throws {
        var d = try document()
        try d.edit(title: "Fixture senza CPL", expectedRevision: d.revision) { $0.manufacturing?.components[0].placement = nil }
        let before = d, id = try XCTUnwrap(d.design.manufacturing?.components[0].id)
        var binding = try sampleBinding()
        XCTAssertThrowsError(try apply(.setComponentModel(componentID: id, binding: binding), to: &d))
        XCTAssertEqual(d, before)
        binding.alignmentVerified = false
        try apply(.setComponentModel(componentID: id, binding: binding), to: &d)
        XCTAssertEqual(d.design.manufacturing?.components[0].modelBinding, binding)
    }

    func testNewProductionLotRetainsBindingsAndCannotOverwriteCorrections() throws {
        var d = try document()
        let raw = try XCTUnwrap(d.design.manufacturing), binding = try sampleBinding()
        try apply(.setComponentModel(componentID: raw.components[0].id, binding: binding), to: &d)
        try apply(.setBoardThickness(2), to: &d)
        var incoming = raw
        incoming.lots = [.init(id: UUID(), name: "Lotto successivo", fittedComponentIDs: [])]
        incoming.activeLotID = incoming.lots[0].id
        try apply(.importPackage(incoming), to: &d)
        let retained = try XCTUnwrap(d.design.manufacturing?.components.first { $0.id == raw.components[0].id })
        XCTAssertEqual(retained.modelBinding, binding)
        XCTAssertEqual(d.design.manufacturing?.assemblySettings?.boardThickness, 2)
        XCTAssertEqual(retained.placement, raw.components[0].placement)
        let before = d
        incoming.components[0].modelBinding = binding
        incoming.components[0].modelBinding?.offset.x += 1
        XCTAssertThrowsError(try apply(.importPackage(incoming), to: &d))
        XCTAssertEqual(d, before)
    }

    private func document() throws -> ElectronicsDocument {
        var d = try ElectronicsDocument.empty()
        let a = UUID(), b = UUID(), lot = UUID()
        let p = ManufacturingPackage(id: UUID(), name: "Assembly transaction fixture", layers: [
            .init(id: UUID(), name: "edge.gm1", kind: .profile, primitives: [
                .init(id: UUID(), shapes: [.init(contours: [[.init(0,0),.init(30,0),.init(30,20),.init(0,20)]], radius: 0)])]),
            .init(id: UUID(), name: "top.gtl", kind: .topCopper, primitives: []),
            .init(id: UUID(), name: "bottom.gbl", kind: .bottomCopper, primitives: [])], drills: [],
            components: [.init(id: a, reference: "R1", footprint: "R_0805", placement: .init(reference: "R1", position: .init(4,5), rotationDegrees: 37, side: .top)),
                         .init(id: b, reference: "Q1", footprint: "unknown", placement: .init(reference: "Q1", position: .init(10,8), rotationDegrees: 90, side: .bottom))],
            lots: [.init(id: lot, name: "Lotto A", fittedComponentIDs: [a,b])], activeLotID: lot, sources: [],
            bounds: .init(minimum: .init(0,0), maximum: .init(30,20)))
        try apply(.importPackage(p), to: &d)
        return d
    }
    private func sampleBinding() throws -> ManufacturingModelBinding {
        let model = try XCTUnwrap(ManufacturingPackageCatalog.suggestedModel(for: .init(id: UUID(), reference: "R1", footprint: "R_0805")))
        return .init(modelKey: model.key, offset: .init(1,2,0.1), rotationDegrees: .init(0,0,90), alignmentVerified: true)
    }
    private func apply(_ command: ManufacturingCommand, to document: inout ElectronicsDocument) throws {
        try ElectronicsCommands.apply(.manufacturing(command), to: &document, expectedRevision: document.revision)
    }
    private func object(_ data: Data) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}
