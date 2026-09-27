import Foundation
import XCTest
@testable import ElectronicsCore

final class FabricationTests: XCTestCase {
    func fixture() throws -> ElectronicsDocument {
        let url = Bundle.module.url(forResource:"fabrication",withExtension:"json",subdirectory:"Fixtures")!
        return try ElectronicsDocument.decode(Data(contentsOf:url))
    }
    func preview(_ d: ElectronicsDocument, _ p: FabricationProfile = .init(), variant: UUID? = nil) throws -> FabricationPreview {
        try ElectronicsFabrication.preview(document:d,expectedRevision:d.revision,profile:p,variantID:variant)
    }
    func changed(_ mutation: (inout ElectronicsDesign) -> Void) throws -> ElectronicsDocument {
        var design = try fixture().design; mutation(&design); return try ElectronicsDocument(design:design)
    }
    func layer(_ p: FabricationPreview, _ kind: FabricationLayerKind) -> [FabricationObject] { p.layers.first { $0.kind == kind }!.objects }
    func assertBlocked(_ d: ElectronicsDocument, code: String, profile: FabricationProfile = .init(), file: StaticString = #filePath, line: UInt = #line) throws {
        let p = try preview(d,profile)
        XCTAssertFalse(p.canExport,file:file,line:line)
        XCTAssertTrue(p.issues.contains { $0.code == code && $0.severity == .error },"\(p.issues)",file:file,line:line)
        XCTAssertThrowsError(try ElectronicsFabrication.export(document:d,expectedRevision:d.revision,profile:profile),file:file,line:line)
    }
    func testCompletePackageIsDeterministicAndUsesOneRevisionOriginAndAllLayers() throws {
        let d = try fixture(), before = d, p = try preview(d)
        XCTAssertTrue(p.canExport,"\(p.issues)")
        XCTAssertEqual(p.layers.count,9); XCTAssertEqual(p.drills.count,3)
        XCTAssertEqual(p.origin,PCBPoint(10,5))
        XCTAssertEqual(layer(p,.topPaste).count,2); XCTAssertEqual(layer(p,.bottomPaste).count,2)
        XCTAssertEqual(layer(p,.topMask).count,4); XCTAssertEqual(layer(p,.bottomMask).count,4)
        let a = try ElectronicsFabrication.export(document:d,expectedRevision:d.revision)
        let b = try ElectronicsFabrication.export(document:ElectronicsDocument.decode(d.encoded()),expectedRevision:d.revision)
        XCTAssertEqual(a,b); XCTAssertEqual(d,before)
        XCTAssertEqual(a.files.count,17); XCTAssertEqual(Set(a.files.map(\.name)).count,17)
        XCTAssertTrue(a.files.first { $0.name == "board-F_Cu.gbr" }!.content.contains("%FSLAX66Y66*%"))
        XCTAssertTrue(a.files.first { $0.name == "board-F_Mask.gbr" }!.content.contains("%TF.FilePolarity,Negative*%"))
        XCTAssertTrue(a.files.first { $0.name == "board-PTH.drl" }!.content.contains("X-5.000000Y10.000000"))
    }
    func testUnroutedFloatingShortAndUnplacedBoardsCannotExport() throws {
        try assertBlocked(changed { $0.board.copper!.tracks.removeFirst() },code:"pcb_unrouted")
        try assertBlocked(changed { d in d.board.copper!.tracks.append(.init(netID:d.nets[0].id,layer:0,width:0.3,points:[.init(32,22),.init(34,22)])) },code:"pcb_floating_copper")
        try assertBlocked(changed { d in d.board.copper!.tracks[0].points = [.init(5,15),.init(16.5,15)] },code:"pcb_short")
        try assertBlocked(changed { $0.board.placements.removeLast() },code:"fabrication_unplaced")
    }
    func testMissingNetNeedsExplicitNoConnectAndERCDriversBlock() throws {
        try assertBlocked(changed { $0.connections.removeLast() },code:"unconnected_pin")
        let d = try changed { d in
            d.library.symbols[0].pins[0].electricalType = .output
            d.library.symbols[1].pins[0].electricalType = .output
        }
        try assertBlocked(d,code:"multiple_drivers")
    }
    func testMaskSliversAndSilkscreenPadOverlapAreDetectedWithSubjects() throws {
        let d = try fixture()
        try assertBlocked(d,code:"fabrication_mask_web",profile:.init(solderMaskExpansion:0.8))
        try assertBlocked(changed { d in d.library.footprints[1].graphics![0].points = [.init(-2,-0.3),.init(2,0.3)] },code:"fabrication_silk_mask")
        let p = try preview(changed { $0.library.footprints[1].graphics![0].strokeWidth = 0.05 })
        XCTAssertTrue(p.issues.contains { $0.code == "fabrication_silk_width" && $0.subjectIDs?.count == 2 })
    }
    func testPasteReductionFailureAndExplicitNoPasteLayers() throws {
        try assertBlocked(fixture(),code:"fabrication_paste_size",profile:.init(pasteInset:0.6))
        let d = try changed { d in for i in d.library.footprints[1].pads.indices { d.library.footprints[1].pads[i].sourceLayers = ["F.Cu","F.Mask"] } }
        let p = try preview(d)
        XCTAssertTrue(p.canExport); XCTAssertTrue(layer(p,.topPaste).isEmpty); XCTAssertEqual(layer(p,.topMask).count,4)
    }
    func testBottomMaskAndPasteAreMirroredOnlyOnceAndRemainTopView() throws {
        let d = try fixture(), p = try preview(d)
        let pad = layer(p,.bottomPaste)[0]
        XCTAssertEqual(pad.center.x,28+cos(.pi/6)*1.5,accuracy:1e-8)
        XCTAssertEqual(pad.center.y,15.75,accuracy:1e-8)
        XCTAssertEqual(layer(p,.bottomSilkscreen).count,2)
        XCTAssertTrue(layer(p,.topSilkscreen).flatMap(\.subjectIDs).allSatisfy { $0 != d.design.components[2].id })
    }
    func testTentedAndExposedViasRespectExplicitProfile() throws {
        let d = try fixture(), tented = try preview(d), open = try preview(d,.init(tentVias:false))
        XCTAssertTrue(open.canExport,"\(open.issues)")
        XCTAssertEqual(layer(open,.topMask).count,layer(tented,.topMask).count+1)
        XCTAssertEqual(layer(open,.bottomMask).count,layer(tented,.bottomMask).count+1)
        XCTAssertEqual(layer(open,.topPaste),layer(tented,.topPaste)); XCTAssertEqual(open.drills,tented.drills)
    }
    func testAssemblyVariantRemovesPasteButNotCopperDrillOrMask() throws {
        let id = UUID(), d = try changed { d in d.variants = [.init(id:id,name:"No diode",excludedComponents:[d.components[2].id])] }
        let full = try preview(d), v = try preview(d,variant:id)
        XCTAssertTrue(v.canExport); XCTAssertTrue(layer(v,.bottomPaste).isEmpty)
        XCTAssertEqual(layer(v,.bottomCopper),layer(full,.bottomCopper)); XCTAssertEqual(v.drills,full.drills)
        XCTAssertEqual(layer(v,.bottomMask),layer(full,.bottomMask))
        let notFitted = try changed { $0.components[2].assembly = .doNotPopulate }
        XCTAssertTrue(layer(try preview(notFitted),.bottomPaste).isEmpty)
    }
    func testRejectUnsupportedLayersAndNoSilentOmissionOfCopperGraphics() throws {
        try assertBlocked(changed { $0.board.copper!.layerCount = 4 },code:"fabrication_layer_count")
        try assertBlocked(changed { $0.library.footprints[1].graphics![0].layer = "F.Cu" },code:"fabrication_graphic_layer")
        try assertBlocked(changed { $0.library.footprints[1].graphics![0].layer = "Edge.Cuts" },code:"fabrication_graphic_layer")
    }
    func testStaleRevisionAfterUndoAndInvalidProfileFailWithoutHistoryMutation() throws {
        var d = try fixture()
        let p = try preview(d)
        try d.edit(title:"Rename",expectedRevision:d.revision) { $0.name = "Changed" }
        try d.undo(expectedRevision:d.revision)
        let before = d
        XCTAssertThrowsError(try ElectronicsFabrication.export(document:d,expectedRevision:p.revision))
        XCTAssertThrowsError(try preview(d,.init(pasteInset:.nan)))
        XCTAssertThrowsError(try preview(d,.init(minimumMaskWeb:0)))
        XCTAssertEqual(d,before)
        XCTAssertEqual(try preview(d).revision,2)
    }
    func testSupplierMissingAndUnverifiedRotationCannotProducePartialAssemblyPackage() throws {
        try assertBlocked(changed { $0.components[1].assembly = .jlcpcb },code:"missing_supplier_part")
        try assertBlocked(changed { d in
            d.components[2].assembly = .jlcpcb
            d.library.devices[2].jlc = .init(partNumber:"C123",catalogReference:"Synthetic",topRotation:.init(direction:.same,offsetDegrees:0,evidence:"Test only"))
        },code:"unverified_assembly_rotation")
    }
    func testIndependentHoleSeparationCanBeStricterThanCopperRule() throws {
        let d = try fixture()
        try assertBlocked(d,code:"fabrication_hole_separation",profile:.init(minimumHoleSeparation:2))
    }
    func testSerigraphyCircleArcAndDegenerateGeometry() throws {
        let d = try changed { d in
            d.library.footprints[1].graphics = [
                .init(id:UUID(),kind:.circle,points:[.init(0,4),.init(1,4)],layer:"F.SilkS",strokeWidth:0.2),
                .init(id:UUID(),kind:.arc,points:[.init(-1,6),.init(0,7),.init(1,6)],layer:"F.SilkS",strokeWidth:0.2)]
        }
        let p = try preview(d)
        XCTAssertTrue(p.canExport,"\(p.issues)")
        let objects = layer(p,.topSilkscreen).filter { $0.subjectIDs.contains(d.design.components[1].id) }
        XCTAssertEqual(objects.count,2)
        XCTAssertTrue(objects.allSatisfy { $0.core.count > 8 })
        try assertBlocked(changed { $0.library.footprints[1].graphics![0].points = [.init(),.init()] },code:"fabrication_graphic")
    }
    func testCancellationDoesNotReturnFilesOrChangeDocument() async throws {
        let d = try fixture()
        let task = Task.detached {
            withUnsafeCurrentTask { $0?.cancel() }
            return try ElectronicsFabrication.export(document:d,expectedRevision:d.revision)
        }
        do { _ = try await task.value; XCTFail("Cancelled export returned files") } catch is CancellationError { }
    }
    func testThermalRegionsComeFromFinalCopperAndKeepTheirGaps() throws {
        let d = try changed { d in
            d.board.copper!.zones = [.init(name:"Return",netID:d.nets[2].id,layer:1,outline:d.board.outline,connection:.thermal,thermalSpokeWidth:0.4)]
        }
        let p = try preview(d), pcb = try ElectronicsPCB.snapshot(d)
        XCTAssertTrue(p.canExport,"\(p.issues)")
        let regions = layer(p,.bottomCopper).filter { $0.kind == .region }
        XCTAssertEqual(regions.map(\.core),pcb.zones[0].cells)
        XCTAssertGreaterThan(regions.count,10)
        let export = try ElectronicsFabrication.export(document:d,expectedRevision:d.revision)
        let gerber = export.files.first { $0.name == "board-B_Cu.gbr" }!.content
        XCTAssertEqual(gerber.components(separatedBy:"G36*").count-1,regions.count)
    }

    func testPlatedMaskOnOneSourceSideFlipsWithBottomPlacement() throws {
        let d = try changed { d in
            d.board.placements[0].side = .bottom // Pads lie on local X=0: physical routing stays fixed.
            for i in d.library.footprints[0].pads.indices { d.library.footprints[0].pads[i].sourceLayers = ["*.Cu","F.Mask"] }
        }
        let p = try preview(d), component = d.design.components[0].id
        XCTAssertTrue(p.canExport,"\(p.issues)")
        XCTAssertFalse(layer(p,.topMask).contains { $0.subjectIDs.contains(component) })
        XCTAssertEqual(layer(p,.bottomMask).filter { $0.subjectIDs.contains(component) }.count,2)
        XCTAssertFalse(layer(p,.topPaste).contains { $0.subjectIDs.contains(component) })
        XCTAssertFalse(layer(p,.bottomPaste).contains { $0.subjectIDs.contains(component) })
    }

    func testFilledLegendPreservesBoundaryStrokeAndRefusesOutOfBoard() throws {
        let id = UUID(), d = try changed { d in
            d.library.footprints[1].graphics = [.init(id:id,kind:.rectangle,points:[.init(-0.5,3),.init(0.5,4)],layer:"F.SilkS",strokeWidth:0.2,filled:true)]
        }
        let p = try preview(d)
        XCTAssertTrue(p.canExport)
        let objects = layer(p,.topSilkscreen).filter { $0.subjectIDs.contains(id) }
        XCTAssertEqual(objects.map(\.kind),[.region,.stroke])
        XCTAssertEqual(objects.last!.radius,0.1)
        try assertBlocked(changed { d in
            d.library.footprints[1].graphics = [.init(id:id,kind:.line,points:[.init(0,14.95),.init(3,14.95)],layer:"F.SilkS",strokeWidth:0.2)]
        },code:"fabrication_silk_edge")
    }

    func testThinRegionCannotSilentlyCollapseDuringGerberQuantization() throws {
        let d = try changed { d in
            d.library.footprints[1].graphics = [.init(id:UUID(),kind:.polyline,points:[.init(-1,3),.init(0,3.0000001),.init(1,3)],layer:"F.SilkS",strokeWidth:0,filled:true)]
        }
        try assertBlocked(d,code:"fabrication_region_resolution")
    }

    func testUnknownVariantAndEmptyBoardCannotExport() throws {
        let d = try fixture(), p = try preview(d,variant:UUID())
        XCTAssertFalse(p.canExport); XCTAssertTrue(p.issues.contains { $0.code == "unknown_variant" })
        try assertBlocked(ElectronicsDocument.empty(name:"Empty",outline:[.init(),.init(20,0),.init(20,20),.init(0,20)]),code:"fabrication_empty_board")
    }
}
