import Foundation
import XCTest
@testable import ElectronicsCore

final class LibraryImportTests: XCTestCase {
    func data(_ name: String, _ ext: String) throws -> Data {
        try Data(contentsOf: XCTUnwrap(Bundle.module.url(forResource: name, withExtension: ext, subdirectory: "Fixtures/Library")))
    }
    func context(_ revision: Int = 1, id: UUID = UUID(uuidString: "AAAAAAAA-0000-0000-0000-000000000001")!) -> LibraryImportContext {
        .init(key: .init(id: id, revision: revision), source: .init(reference: "Test corpus", license: "See fixture attribution", sourceRevision: "9.0.0"))
    }
    func doc() throws -> ElectronicsDocument {
        try ElectronicsDocument(design: .init(name: "Library test", library: .init(), board: .init(outline: [.init(0,0), .init(20,0), .init(20,20), .init(0,20)])))
    }
    func assertFailure(_ code: String, _ run: () throws -> Void, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try run(), file: file, line: line) { error in
            XCTAssertTrue((error as? ElectronicsFailure)?.issues.contains { $0.code == code } == true,
                          "Expected \(code): \(error)", file: file, line: line)
        }
    }
    func simpleFootprint(_ pad: String) -> Data { Data("(footprint \"Test\" (layer \"F.Cu\") \(pad))".utf8) }
    var simplePad: String { "(pad \"1\" smd rect (at 2 3 30) (size 1 2) (layers \"F.Cu\" \"F.Mask\" \"F.Paste\"))" }

    func testOfficialKiCadResistorKeepsRoundrectGeometryAndProvenance() throws {
        let source = try data("R_0603_1608Metric", "kicad_mod")
        let imported = try KiCadLibraryImporter.footprint(source, context: context())
        let fp = try XCTUnwrap(imported.library.footprints.first)
        XCTAssertEqual(fp.name, "R_0603_1608Metric"); XCTAssertEqual(fp.pads.count, 2)
        XCTAssertEqual(fp.pads.map(\.number), ["1", "2"])
        XCTAssertEqual(fp.pads[0].shape, .roundedRectangle)
        XCTAssertEqual(try XCTUnwrap(fp.pads[0].cornerRadius), 0.2, accuracy: 1e-9)
        XCTAssertEqual(fp.pads[0].center.x, -0.825, accuracy: 1e-9)
        XCTAssertEqual(fp.pads[1].center.x - fp.pads[0].center.x, 1.65, accuracy: 1e-9)
        XCTAssertEqual(fp.graphics?.count, 10)
        XCTAssertEqual(fp.source.contentSHA256, imported.sourceSHA256)
        XCTAssertEqual(imported.originalSource, String(data: source, encoding: .utf8))
        XCTAssertNil(fp.model3D)
        XCTAssertTrue(imported.issues.contains { $0.code == "unresolved_3d_model" })
    }

    func testOfficialKiCadSymbolPreservesPinNumbersGeometryAndDrawing() throws {
        let imported = try KiCadLibraryImporter.symbol(data("Device_R", "kicad_sym"), name: "R", context: context())
        let s = try XCTUnwrap(imported.library.symbols.first)
        XCTAssertEqual(s.pins.map(\.number), ["1", "2"])
        XCTAssertEqual(s.pins.map(\.electricalType), [.passive, .passive])
        XCTAssertEqual(s.pins[0].position, .init(0, 3.81))
        XCTAssertEqual(s.pins[0].rotationDegrees, 270); XCTAssertEqual(s.pins[0].length, 1.27)
        XCTAssertEqual(s.graphics?.first?.kind, .rectangle)
        XCTAssertEqual(s.graphics?.first?.strokeWidth, 0.254)
        XCTAssertEqual(s.properties?["Reference"], "R")
    }

    func testOfficialThroughHoleHeaderPreservesDrillDiameterAndMirrorsYOnly() throws {
        let fp = try KiCadLibraryImporter.footprint(data("PinHeader_1x02", "kicad_mod"), context: context()).library.footprints[0]
        XCTAssertEqual(fp.pads.count, 2)
        XCTAssertEqual(fp.pads[0].drillDiameter, 1)
        XCTAssertEqual(fp.pads[1].center, .init(0, -2.54))
        let small = try KiCadLibraryImporter.footprint(simpleFootprint(simplePad), context: context()).library.footprints[0].pads[0]
        XCTAssertEqual(small.center, .init(2, -3)); XCTAssertEqual(small.rotationDegrees, 30)
    }

    func testImportIdentitySurvivesRevisionChangeAndSourceWhitespace() throws {
        let source = try data("R_0603_1608Metric", "kicad_mod")
        let a = try KiCadLibraryImporter.footprint(source, context: context()).library.footprints[0]
        let b = try KiCadLibraryImporter.footprint(Data("\n; comment\n".utf8) + source, context: context(2)).library.footprints[0]
        XCTAssertEqual(a.key.id, b.key.id); XCTAssertEqual(b.key.revision, 2)
        XCTAssertEqual(a.pads.map(\.id), b.pads.map(\.id)); XCTAssertEqual(a.graphics?.map(\.id), b.graphics?.map(\.id))
        XCTAssertNotEqual(a.source.contentSHA256, b.source.contentSHA256)
    }

    func testUnsupportedGeometryAndManufacturingRulesFailInsteadOfBeingDropped() throws {
        for addition in ["(clearance 0.4)", "(solder_mask_margin 0.02)", "(chamfer_ratio 0.2)", "(primitives)"] {
            let bad = simplePad.dropLast() + " " + addition + ")"
            assertFailure("unsupported_construct") { _ = try KiCadLibraryImporter.footprint(self.simpleFootprint(bad), context: self.context()) }
        }
        assertFailure("unsupported_pad") { _ = try KiCadLibraryImporter.footprint(self.simpleFootprint(self.simplePad.replacingOccurrences(of: "smd rect", with: "smd custom")), context: self.context()) }
        assertFailure("unsupported_pad_layers") { _ = try KiCadLibraryImporter.footprint(self.simpleFootprint(self.simplePad.replacingOccurrences(of: "F.Cu", with: "B.Cu")), context: self.context()) }
        let slotted = "(pad 1 thru_hole oval (at 0 0) (size 3 4) (drill oval 1 2) (layers *.Cu *.Mask))"
        assertFailure("unsupported_drill") { _ = try KiCadLibraryImporter.footprint(self.simpleFootprint(slotted), context: self.context()) }
        let copper = simplePad + " (fp_line (start 0 0) (end 1 1) (layer F.Cu) (width 0.2))"
        assertFailure("unsupported_copper_graphic") { _ = try KiCadLibraryImporter.footprint(self.simpleFootprint(copper), context: self.context()) }
    }

    func testMalformedSExpressionsHaveBoundedDepthAndNoPartialResult() throws {
        for s in ["(footprint", "(footprint \"unterminated)", "(footprint \"x\") (extra)", "(footprint \"x\" (layer F.Cu) (layer B.Cu))",
                  String(repeating: "(x ", count: 70) + "a" + String(repeating: ")", count: 70)] {
            assertFailure("invalid_sexpression") { _ = try KiCadLibraryImporter.footprint(Data(s.utf8), context: self.context()) }
        }
    }

    func testEscapedUTF8StringsAndLegacyModuleAreRead() throws {
        let s = "(module \"Résistance \\\"test\\\"\" (layer F.Cu) \(simplePad))"
        let f = try KiCadLibraryImporter.footprint(Data(s.utf8), context: context()).library.footprints[0]
        XCTAssertEqual(f.name, "Résistance \"test\"")
    }

    func testSymbolInheritanceAndUnsupportedUnitsAreExplicit() throws {
        let base = "(symbol Base (property \"Value\" \"A\") (symbol Base_1_1 (pin input line (at 0 0 0) (length 2) (name IN) (number 1))))"
        let s = "(kicad_symbol_lib \(base) (symbol Derived (extends Base) (property \"Value\" \"B\")))"
        let symbol = try KiCadLibraryImporter.symbol(Data(s.utf8), name: "Derived", context: context()).library.symbols[0]
        XCTAssertEqual(symbol.properties?["Value"], "B"); XCTAssertEqual(symbol.pins.count, 1)
        let multi = s.replacingOccurrences(of: "Base_1_1", with: "Base_2_1")
        assertFailure("unsupported_symbol_unit") { _ = try KiCadLibraryImporter.symbol(Data(multi.utf8), name: "Derived", context: self.context()) }
        let cycle = "(kicad_symbol_lib (symbol A (extends B)) (symbol B (extends A)))"
        assertFailure("invalid_sexpression") { _ = try KiCadLibraryImporter.symbol(Data(cycle.utf8), name: "A", context: self.context()) }
    }

    func easy(_ shapes: [String], docType: String = "4") throws -> Data {
        try JSONSerialization.data(withJSONObject: ["head": ["docType": docType, "x": "4000", "y": "3000", "c_para": ["package": "Synthetic"]],
                                                  "shape": shapes, "canvas": "ignored display unit mm"])
    }
    var easyPad: String { "PAD~RECT~4010~3020~4~6~1~~1~0~~90~gge1~0~~Y~0~~~" }

    func testEasyEDAStandardUnitsOriginAndOrthogonalPads() throws {
        let result = try EasyEDAStandardImporter.footprint(easy([easyPad, "TRACK~0.5~3~~4000 3000 4020 3000~g1~0"]), name: "Easy test", context: context())
        let f = result.library.footprints[0]
        XCTAssertEqual(f.pads[0].center.x, 2.54, accuracy: 1e-9); XCTAssertEqual(f.pads[0].center.y, -5.08, accuracy: 1e-9)
        XCTAssertEqual(f.pads[0].size.x, 1.016, accuracy: 1e-9); XCTAssertEqual(f.pads[0].size.y, 1.524, accuracy: 1e-9)
        XCTAssertEqual(f.graphics?.first?.points.last, PCBPoint(5.08, 0))
        XCTAssertEqual(f.properties?["package"], "Synthetic")
    }

    func testEasyEDARefusesProBoardThruHolesAndAmbiguousRotation() throws {
        assertFailure("unsupported_easyeda_document") { _ = try EasyEDAStandardImporter.footprint(self.easy([self.easyPad], docType: "3"), name: "test", context: self.context()) }
        assertFailure("unsupported_easyeda_pad") { _ = try EasyEDAStandardImporter.footprint(self.easy([self.easyPad.replacingOccurrences(of: "~1~0~~90", with: "~1~1~~90")]), name: "test", context: self.context()) }
        assertFailure("unsupported_easyeda_rotation") { _ = try EasyEDAStandardImporter.footprint(self.easy([self.easyPad.replacingOccurrences(of: "~~90~", with: "~~45~")]), name: "test", context: self.context()) }
        assertFailure("unsupported_easyeda_shape") { _ = try EasyEDAStandardImporter.footprint(self.easy([self.easyPad, "COPPERAREA~1~1~GND"]), name: "test", context: self.context()) }
    }

    func testPreviewDoesNotMutateAndConfirmIsOnePersistentUndoStep() throws {
        var document = try doc(); let original = document
        let imported = try KiCadLibraryImporter.footprint(data("R_0603_1608Metric", "kicad_mod"), context: context())
        let command = ElectronicsLibraryCommand.importLibrary(imported)
        let preview = try ElectronicsLibraryCommands.preview(command, document: document, expectedRevision: 0)
        XCTAssertEqual(document, original); XCTAssertEqual(preview.library.footprints.count, 1)
        try ElectronicsLibraryCommands.apply(command, to: &document, expectedRevision: 0)
        XCTAssertEqual(document.past.count, 1); XCTAssertEqual(document.design.library, preview.library)
        document = try ElectronicsDocument.decode(document.encoded())
        try document.undo(expectedRevision: 1); XCTAssertEqual(document.design, original.design)
        try document.redo(expectedRevision: 2); XCTAssertEqual(document.design.library, preview.library)
        assertFailure("stale_revision") { try ElectronicsLibraryCommands.apply(command, to: &document, expectedRevision: 0) }
    }

    func testReimportIsIdempotentButConflictingRevisionsAreRejectedAtomically() throws {
        var document = try doc()
        let input = try data("R_0603_1608Metric", "kicad_mod")
        let imported = try KiCadLibraryImporter.footprint(input, context: context())
        try ElectronicsLibraryCommands.apply(.importLibrary(imported), to: &document, expectedRevision: 0)
        try ElectronicsLibraryCommands.apply(.importLibrary(imported), to: &document, expectedRevision: 1)
        XCTAssertEqual(document.revision, 1); let before = document
        let changed = Data(String(decoding: input, as: UTF8.self).replacingOccurrences(of: "0.825", with: "0.925").utf8)
        let incompatible = try KiCadLibraryImporter.footprint(changed, context: context())
        assertFailure("library_revision_conflict") { try ElectronicsLibraryCommands.apply(.importLibrary(incompatible), to: &document, expectedRevision: 1) }
        XCTAssertEqual(document, before)
        try ElectronicsLibraryCommands.apply(.importLibrary(KiCadLibraryImporter.footprint(changed, context: context(2))), to: &document, expectedRevision: 1)
        XCTAssertEqual(document.design.library.footprints.count, 2)
    }

    func testPinMappingIsAProposalThenValidatedOnDeviceCreation() throws {
        var document = try doc()
        let fp = try KiCadLibraryImporter.footprint(data("R_0603_1608Metric", "kicad_mod"), context: context())
        let sy = try KiCadLibraryImporter.symbol(data("Device_R", "kicad_sym"), name: "R", context: context(id: UUID()))
        try ElectronicsLibraryCommands.apply(.importLibrary(fp), to: &document, expectedRevision: 0)
        try ElectronicsLibraryCommands.apply(.importLibrary(sy), to: &document, expectedRevision: 1)
        let mapping = try ElectronicsLibraryCommands.suggestedPinMap(symbol: sy.library.symbols[0], footprint: fp.library.footprints[0])
        XCTAssertTrue(document.design.library.devices.isEmpty)
        var device = DeviceDefinition(manufacturer: "Fixture", manufacturerPartNumber: "Test", symbol: sy.library.symbols[0].key,
                                      footprint: fp.library.footprints[0].key, pinMap: mapping)
        try ElectronicsLibraryCommands.apply(.createDevice(device), to: &document, expectedRevision: 2)
        let before = document
        device.key = .init(); device.pinMap.removeLast()
        assertFailure("invalid_pin_map") { try ElectronicsLibraryCommands.apply(.createDevice(device), to: &document, expectedRevision: 3) }
        XCTAssertEqual(document, before)
    }

    func testChangedImportArchiveHashIsRejected() throws {
        var document = try doc()
        var imported = try KiCadLibraryImporter.footprint(simpleFootprint(simplePad), context: context())
        imported.originalSource += "changed"
        assertFailure("invalid_import_bundle") { try ElectronicsLibraryCommands.apply(.importLibrary(imported), to: &document, expectedRevision: 0) }
        XCTAssertEqual(document.revision, 0)
    }

    func testV1MigrationPreservesHistoryAndWritesCurrentVersionForOlderReaderSafety() throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "assembly", withExtension: "json", subdirectory: "Fixtures"))
        let oldData = try Data(contentsOf: url)
        let old = try XCTUnwrap(JSONSerialization.jsonObject(with: oldData) as? [String: Any])
        XCTAssertEqual(old["formatVersion"] as? Int, 1)
        var document = try ElectronicsDocument.decode(oldData)
        XCTAssertEqual(document.formatVersion, 5)
        let before = document.design
        try document.edit(title: "Verifica migrazione", expectedRevision: document.revision) { $0.name = "Migrated" }
        document = try ElectronicsDocument.decode(document.encoded())
        try document.undo(expectedRevision: document.revision)
        XCTAssertEqual(document.design, before)
        let saved = try XCTUnwrap(JSONSerialization.jsonObject(with: document.encoded()) as? [String: Any])
        XCTAssertEqual(saved["formatVersion"] as? Int, 5)
        XCTAssertEqual(try ElectronicsDocument.decode(document.encoded()), document)
    }

    func testSourcePoliciesAndMalformedEasyEDAGetExplicitErrors() throws {
        let attr = simplePad + " (attr smd exclude_from_bom)"
        assertFailure("unsupported_component_policy") { _ = try KiCadLibraryImporter.footprint(self.simpleFootprint(attr), context: self.context()) }
        let symbol = "(kicad_symbol_lib (symbol X (on_board no)))"
        assertFailure("unsupported_component_policy") { _ = try KiCadLibraryImporter.symbol(Data(symbol.utf8), name: "X", context: self.context()) }
        assertFailure("invalid_easyeda_json") { _ = try EasyEDAStandardImporter.footprint(Data("{broken".utf8), name: "X", context: self.context()) }
        let imported = try KiCadLibraryImporter.footprint(data("R_0603_1608Metric", "kicad_mod"), context: context())
        XCTAssertTrue(imported.issues.allSatisfy { $0.subjectIDs == [context().key.id] })
    }

    func testAlteredLibrarySourceOrLayersDoNotEnterHistory() throws {
        var document = try doc()
        var bundle = try KiCadLibraryImporter.footprint(simpleFootprint(simplePad), context: context())
        bundle.library.footprints[0].source.contentSHA256 = String(repeating: "0", count: 64)
        assertFailure("invalid_import_bundle") { try ElectronicsLibraryCommands.apply(.importLibrary(bundle), to: &document, expectedRevision: 0) }
        bundle.library.footprints[0].source.contentSHA256 = bundle.sourceSHA256
        bundle.library.footprints[0].pads[0].sourceLayers = ["B.Cu"]
        assertFailure("invalid_pad_layers") { try ElectronicsLibraryCommands.apply(.importLibrary(bundle), to: &document, expectedRevision: 0) }
        XCTAssertEqual(document.revision, 0)
    }

    var catalog: Data {
        Data("LCSC Part #,Manufacturer,MPN,Package,Description,Stock,Datasheet\r\nC123,Test maker,PART-A,0603,\"10k, 1% \"\"thin\"\"\",20,https://example.invalid/a.pdf\r\nC456,Test maker,PART-B,0805,\"line 1\nline 2\",,\r\n".utf8)
    }

    func testCatalogCSVPreservesQuotesUnknownStockAndProvenance() throws {
        let timestamp = Date(timeIntervalSince1970: 1000)
        let snapshot = try ComponentCatalogImporter.csv(catalog, sourceReference: "synthetic", observedAt: timestamp)
        XCTAssertEqual(snapshot.parts.count, 2)
        XCTAssertEqual(snapshot.parts[0].description, "10k, 1% \"thin\"")
        XCTAssertNil(snapshot.parts[1].stock)
        XCTAssertEqual(snapshot.search("PART-A").map(\.partNumber), ["C123"])
        XCTAssertEqual(snapshot.search("", availableOnly: true).map(\.partNumber), ["C123"])
        XCTAssertTrue(snapshot.observationIsOlder(than: 60, at: timestamp.addingTimeInterval(61)))
        XCTAssertFalse(snapshot.observationIsOlder(than: 60, at: timestamp.addingTimeInterval(59)))
        XCTAssertEqual(try JSONDecoder().decode(SupplierCatalogSnapshot.self, from: JSONEncoder().encode(snapshot)), snapshot)
    }

    func testCatalogNeverSelectsAnAlternativeMPNOrGuessesAssemblyRotation() throws {
        let snapshot = try ComponentCatalogImporter.csv(catalog, sourceReference: "synthetic", observedAt: Date(timeIntervalSince1970: 1000))
        var device = DeviceDefinition(manufacturer: "Test maker", manufacturerPartNumber: "PART-A", symbol: .init(), footprint: .init(), pinMap: [])
        let binding = try snapshot.jlcPart(number: "C123", for: device)
        XCTAssertNil(binding.topRotation); XCTAssertNil(binding.bottomRotation)
        device.manufacturerPartNumber = "part-a"
        assertFailure("catalog_identity_mismatch") { _ = try snapshot.jlcPart(number: "C123", for: device) }
        device.manufacturerPartNumber = "PART-B"
        assertFailure("catalog_identity_mismatch") { _ = try snapshot.jlcPart(number: "C123", for: device) }
    }

    func testCatalogCacheRefusesInvalidStockAndUnknownVersions() throws {
        let snapshot = try ComponentCatalogImporter.csv(catalog, sourceReference: "synthetic", observedAt: Date(timeIntervalSince1970: 1000))
        let original = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(snapshot)) as? [String: Any])
        var changed = original; changed["formatVersion"] = 999
        assertFailure("invalid_catalog_snapshot") { _ = try JSONDecoder().decode(SupplierCatalogSnapshot.self, from: JSONSerialization.data(withJSONObject: changed)) }
        changed = original
        var parts = try XCTUnwrap(changed["parts"] as? [[String: Any]])
        parts[0]["stock"] = -1; changed["parts"] = parts
        assertFailure("invalid_catalog_snapshot") { _ = try JSONDecoder().decode(SupplierCatalogSnapshot.self, from: JSONSerialization.data(withJSONObject: changed)) }
    }

    func testCatalogRejectsMalformedCSVAndDuplicateSupplierCodes() throws {
        for malformed in ["a,a\n1,2", "a,b\n\"unterminated", "a,b\n\"closed\"extra,b"] {
            XCTAssertThrowsError(try ComponentCatalogImporter.csv(Data(malformed.utf8), sourceReference: "test", observedAt: Date()))
        }
        let text = String(decoding: catalog, as: UTF8.self)
        assertFailure("invalid_catalog_part") { _ = try ComponentCatalogImporter.csv(Data(text.replacingOccurrences(of: "C456", with: "C123").utf8), sourceReference: "test", observedAt: Date()) }
        assertFailure("invalid_catalog_stock") { _ = try ComponentCatalogImporter.csv(Data(text.replacingOccurrences(of: ",20,", with: ",-1,").utf8), sourceReference: "test", observedAt: Date()) }
    }
}
