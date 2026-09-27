import Foundation
import XCTest
@testable import ElectronicsCore

final class LibraryComparisonTests: XCTestCase {
    private func fixture() throws -> ElectronicsDocument {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "assembly", withExtension: "json", subdirectory: "Fixtures"))
        return try ElectronicsDocument.decode(Data(contentsOf: url))
    }
    private func compare(_ document: ElectronicsDocument, _ library: ElectronicsLibrary) throws -> [LibraryRevisionDiff] {
        try ElectronicsLibraryComparison.compare(current: document.design, proposedLibrary: library)
    }
    private func failure(_ body: () throws -> Void) {
        XCTAssertThrowsError(try body()) { XCTAssertTrue($0 is ElectronicsFailure) }
    }

    func testPadGeometryNumberAndDrillKeepBeforeAfterAndExactComponentUsage() throws {
        let document = try fixture(), original = document
        var library = document.design.library
        var next = library.footprints[0]; next.key.revision += 1
        let oldPad = next.pads[0]
        next.pads[0].center.x += 0.4
        next.pads[0].number = "QA9"
        next.pads[0].drillDiameter = 0.2
        next.assemblyCentroid.y += 0.3
        library.footprints.append(next)
        let diff = try XCTUnwrap(compare(document, library).first)
        XCTAssertEqual(document, original)
        XCTAssertEqual(diff.pads.count, 1)
        XCTAssertEqual(diff.pads[0].id, oldPad.id)
        XCTAssertEqual(diff.pads[0].before, oldPad)
        XCTAssertEqual(diff.pads[0].after, next.pads[0])
        XCTAssertEqual(diff.pads[0].kind, .modified)
        XCTAssertEqual(diff.changedFields, [.assemblyCentroid, .pads])
        let devices = Set(library.devices.filter { $0.footprint == library.footprints[0].key }.map(\.key))
        let expected = document.design.components.filter { devices.contains($0.device) }.map(\.id).sorted { $0.uuidString < $1.uuidString }
        XCTAssertFalse(expected.isEmpty)
        XCTAssertEqual(diff.affectedComponentIDs, expected)
        XCTAssertFalse(diff.isOlderRevision)
    }

    func testRemovedAndAddedPinNeverMatchedByDisplayNumber() throws {
        let document = try fixture(); var library = document.design.library
        var next = library.symbols[0]; next.key.revision += 1
        let removed = next.pins[0]
        next.pins[0].id = UUID(); next.pins[0].electricalType = .input
        let added = next.pins[0]
        library.symbols.append(next)
        let diff = try XCTUnwrap(compare(document, library).first)
        XCTAssertEqual(diff.pins.count, 2)
        let deletion = try XCTUnwrap(diff.pins.first { $0.id == removed.id })
        let addition = try XCTUnwrap(diff.pins.first { $0.id == added.id })
        XCTAssertEqual(deletion.kind, .removed); XCTAssertEqual(deletion.before, removed); XCTAssertNil(deletion.after)
        XCTAssertEqual(addition.kind, .added); XCTAssertNil(addition.before); XCTAssertEqual(addition.after, added)
        XCTAssertEqual(diff.changedFields, [.pins])
    }

    func testElectricalPinChangeAndMetadataAreSeparated() throws {
        let document = try fixture(); var library = document.design.library
        var next = library.symbols[0]; next.key.revision += 1
        next.pins[0].electricalType = .output; next.source.sourceRevision = "datasheet-revision-2"
        library.symbols.append(next)
        let diff = try XCTUnwrap(compare(document, library).first)
        XCTAssertEqual(diff.changedFields, [.source, .pins])
        XCTAssertEqual(diff.pins.first?.after?.electricalType, .output)
    }

    func testReorderingEntitiesAndMappingsIsNotAContentChange() throws {
        let document = try fixture(); var library = document.design.library
        var fp = library.footprints[0]; fp.key.revision += 1; fp.pads.reverse(); fp.graphics?.reverse()
        var sy = library.symbols[0]; sy.key.revision += 1; sy.pins.reverse(); sy.graphics?.reverse()
        var dev = library.devices[0]; dev.key.revision += 1; dev.pinMap.reverse()
        library.footprints.append(fp); library.symbols.append(sy); library.devices.append(dev)
        let diffs = try compare(document, library)
        XCTAssertEqual(diffs.count, 3)
        XCTAssertTrue(diffs.allSatisfy { $0.changedFields.isEmpty && $0.pads.isEmpty && $0.pins.isEmpty })
        library.symbols.reverse(); library.footprints.reverse(); library.devices.reverse()
        XCTAssertEqual(try compare(document, library), diffs)
    }

    func testDeviceMappingSupplierAndIdentityChangesAreVisible() throws {
        let document = try fixture(); var library = document.design.library
        var dev = library.devices[0]; dev.key.revision += 1
        dev.manufacturerPartNumber += "-ALT"
        let oldMap = dev.pinMap
        XCTAssertGreaterThanOrEqual(dev.pinMap.count, 2)
        dev.pinMap[0].pinID = oldMap[1].pinID; dev.pinMap[1].pinID = oldMap[0].pinID
        dev.jlc = .init(partNumber: "C999999", catalogReference: "Synthetic QA only")
        library.devices.append(dev)
        let diff = try XCTUnwrap(compare(document, library).first)
        XCTAssertEqual(diff.changedFields, [.manufacturerPartNumber, .pinMap, .supplier])
        guard case .device(let before) = diff.before, case .device(let after) = diff.after else { return XCTFail("device snapshots") }
        XCTAssertEqual(before.pinMap, oldMap); XCTAssertEqual(after.pinMap, dev.pinMap)
    }

    func testEachPinnedRevisionGetsItsOwnDiffAndComponents() throws {
        var document = try fixture()
        let old = document.design.library.footprints[0]
        var second = old; second.key.revision = 2; second.pads[0].center.x += 0.2
        let device = try XCTUnwrap(document.design.library.devices.first { $0.footprint == old.key })
        var device2 = device; device2.key.revision = 2; device2.footprint = second.key
        let component = CircuitComponent(reference: "QA100", value: "QA", device: device2.key)
        try document.edit(title: "Fixture second revision", expectedRevision: 0) {
            $0.library.footprints.append(second); $0.library.devices.append(device2); $0.components.append(component)
        }
        var next = second; next.key.revision = 3; next.pads[0].center.x += 0.1
        var library = document.design.library; library.footprints.append(next)
        let diffs = try compare(document, library)
        XCTAssertEqual(diffs.map { $0.before?.key.revision }, [1, 2])
        XCTAssertFalse(diffs[0].affectedComponentIDs.contains(component.id))
        XCTAssertEqual(diffs[1].affectedComponentIDs, [component.id])
        XCTAssertEqual(diffs[0].pads[0].before?.center, old.pads[0].center)
        XCTAssertEqual(diffs[1].pads[0].before?.center, second.pads[0].center)
    }

    func testOlderRevisionIsExplicitAndSameRevisionChangesAreRejected() throws {
        var document = try fixture()
        try document.edit(title: "Fixture high revision", expectedRevision: 0) {
            var fp = $0.library.footprints[0]; fp.key.revision = 4; $0.library.footprints.append(fp)
        }
        var next = document.design.library.footprints[0]; next.key.revision = 2
        var library = document.design.library; library.footprints.append(next)
        let diffs = try compare(document, library)
        XCTAssertEqual(diffs.map(\.isOlderRevision), [false, true])
        library = document.design.library; library.footprints[0].name += "changed"
        failure { _ = try compare(document, library) }
        library = document.design.library; library.footprints.removeLast()
        failure { _ = try compare(document, library) }
    }

    func testPreviewImportIsNonMutatingAndApplyKeepsPinnedPartsAndUndo() throws {
        var document = try fixture()
        let url = try XCTUnwrap(Bundle.module.url(forResource: "R_0603_1608Metric", withExtension: "kicad_mod", subdirectory: "Fixtures/Library"))
        let source = try Data(contentsOf: url)
        let key = LibraryRevision()
        let context = LibraryImportContext(key: key, source: .init(reference: "Pinned KiCad fixture", license: "See corpus license", sourceRevision: "9.0.0"))
        let first = try KiCadLibraryImporter.footprint(source, context: context)
        try ElectronicsLibraryCommands.apply(.importLibrary(first), to: &document, expectedRevision: 0)
        let baseline = document
        var nextContext = context; nextContext.key.revision = 2
        let changed = Data(String(decoding: source, as: UTF8.self).replacingOccurrences(of: "0.825", with: "0.925").utf8)
        let command = ElectronicsLibraryCommand.importLibrary(try KiCadLibraryImporter.footprint(changed, context: nextContext))
        let preview = try ElectronicsLibraryCommands.preview(command, document: document, expectedRevision: 1)
        XCTAssertEqual(document, baseline); XCTAssertEqual(preview.revisionDiffs.count, 1)
        XCTAssertEqual(preview.revisionDiffs[0].pads.count, 2)
        XCTAssertEqual(preview.revisionDiffs[0].before?.key, key)
        let decoded = try JSONDecoder().decode(LibraryCommandPreview.self, from: JSONEncoder().encode(preview))
        XCTAssertEqual(decoded, preview)
        try ElectronicsLibraryCommands.apply(command, to: &document, expectedRevision: preview.baseRevision)
        XCTAssertEqual(document.design.library, preview.library)
        XCTAssertEqual(document.design.components, baseline.design.components)
        XCTAssertEqual(document.design.connections, baseline.design.connections)
        XCTAssertEqual(document.design.board, baseline.design.board)
        XCTAssertEqual(document.past.count, baseline.past.count + 1)
        document = try ElectronicsDocument.decode(document.encoded())
        try document.undo(expectedRevision: 2); XCTAssertEqual(document.design, baseline.design)
        try document.redo(expectedRevision: 3); XCTAssertEqual(document.design.library, preview.library)
        XCTAssertTrue(try ElectronicsLibraryCommands.preview(command, document: document, expectedRevision: 4).revisionDiffs.isEmpty)
        failure { _ = try ElectronicsLibraryCommands.preview(command, document: document, expectedRevision: 1) }
    }

    func testNewFamilyAndInvalidDuplicateIdentity() throws {
        let document = try fixture(); var library = document.design.library
        var new = library.symbols[0]; new.key = .init(); library.symbols.append(new)
        let diff = try XCTUnwrap(compare(document, library).first)
        XCTAssertNil(diff.before); XCTAssertTrue(diff.affectedComponentIDs.isEmpty)
        XCTAssertTrue(diff.changedFields.contains(.definition)); XCTAssertTrue(diff.pins.allSatisfy { $0.kind == .added })
        library.symbols[library.symbols.count - 1].pins.append(new.pins[0])
        failure { _ = try compare(document, library) }
    }

    func testGraphicsModelAndCentroidRemainNativeSnapshots() throws {
        let document = try fixture(); var library = document.design.library
        var next = library.footprints[0]; next.key.revision += 1
        let graphic = LibraryGraphic(id: UUID(), kind: .line, points: [.init(0,0), .init(1,1)], layer: "F.SilkS", strokeWidth: 0.1)
        next.graphics = (next.graphics ?? []) + [graphic]
        next.model3D = .init(relativePath: "Models/qa.step", sha256: String(repeating: "a", count: 64))
        library.footprints.append(next)
        let diff = try XCTUnwrap(compare(document, library).first)
        XCTAssertEqual(diff.graphics.first?.after, graphic)
        XCTAssertTrue(diff.changedFields.contains(.model3D)); XCTAssertTrue(diff.changedFields.contains(.graphics))
        guard case .footprint(let snapshot) = diff.after else { return XCTFail("native footprint") }
        XCTAssertEqual(snapshot.model3D, next.model3D)
    }
}
