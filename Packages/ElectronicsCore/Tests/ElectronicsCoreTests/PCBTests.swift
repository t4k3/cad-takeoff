import Foundation
import XCTest
@testable import ElectronicsCore

final class PCBTests: XCTestCase {
    func id(_ n: Int) -> UUID { UUID(uuidString:String(format:"DDDD0000-0000-0000-0000-%012d",n))! }
    func fixture() throws -> ElectronicsDocument {
        let source = LibrarySource(reference:"Native test",license:"CC0-1.0",sourceRevision:"1")
        var symbol = SymbolDefinition(key:.init(id:id(1),revision:1),name:"Test",pins:[.init(id:id(2),name:"1",electricalType:.passive)],source:source)
        symbol.pins[0].position = .init()
        let foot = FootprintDefinition(key:.init(id:id(3),revision:1),name:"Test",pads:[.init(id:id(4),number:"1",center:.init(),size:.init(1,1),shape:.circle)],source:source)
        let device = DeviceDefinition(key:.init(id:id(5),revision:1),manufacturer:"Native",manufacturerPartNumber:"Test",symbol:symbol.key,footprint:foot.key,pinMap:[.init(pinID:id(2),padID:id(4))])
        let points: [PCBPoint] = [.init(5,10),.init(35,10),.init(20,5),.init(20,25)]
        let components = points.indices.map { CircuitComponent(id:id(10+$0),reference:"J\($0+1)",value:"Test",device:device.key,assembly:.manual) }
        let connections = components.indices.map { PinConnection(pin:.init(componentID:components[$0].id,pinID:id(2)),netID:id($0 < 2 ? 20 : 21)) }
        return try .init(design:.init(name:"PCB test",library:.init(symbols:[symbol],footprints:[foot],devices:[device]),components:components,
                     nets:[.init(id:id(20),name:"A"),.init(id:id(21),name:"B")],connections:connections,
                     board:.init(outline:[.init(0,0),.init(40,0),.init(40,30),.init(0,30)],placements:components.indices.map { .init(componentID:components[$0].id,position:points[$0]) })))
    }
    func apply(_ command: ElectronicsCommand, _ d: inout ElectronicsDocument) throws { try ElectronicsCommands.apply(command,to:&d,expectedRevision:d.revision) }
    func track(_ n: Int = 30, net: Int = 20, layer: Int = 0, width: Double = 0.25, points: [PCBPoint] = [.init(5,10),.init(35,10)]) -> PCBTrack {
        .init(id:id(n),netID:id(net),layer:layer,width:width,points:points)
    }
    func assertFailure(_ code: String, _ body: () throws -> Void, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try body(),file:file,line:line) { error in
            XCTAssertTrue((error as? ElectronicsFailure)?.issues.contains { $0.code == code } == true,"\(error)",file:file,line:line)
        }
    }
    func testRouteActuallyJoinsPadsAndDeletingRestoresAirwireWithPersistentUndo() throws {
        var d = try fixture()
        XCTAssertEqual(try ElectronicsPCB.snapshot(d).board.airwires.count,2)
        let command = ElectronicsCommand.pcb(.addTrack(track()))
        let before = d, preview = try ElectronicsCommands.preview(command,document:d,expectedRevision:d.revision)
        XCTAssertEqual(d,before); XCTAssertTrue(preview.canApply)
        XCTAssertEqual(try preview.pcbSnapshot().designID,d.design.id)
        XCTAssertEqual(try preview.pcbSnapshot().revision,d.revision)
        XCTAssertEqual(try preview.pcbSnapshot().board.airwires.map(\.netID),[id(21)])
        try apply(command,&d)
        XCTAssertEqual(d.design,preview.design); XCTAssertEqual(d.past.count,1)
        d = try ElectronicsDocument.decode(d.encoded())
        XCTAssertEqual(d.formatVersion,7)
        try apply(.pcb(.removeTrack(id(30))),&d)
        XCTAssertEqual(try ElectronicsConnectivity.snapshot(d.design).airwires.count,2)
        try d.undo(expectedRevision:d.revision)
        XCTAssertEqual(try ElectronicsConnectivity.snapshot(d.design).airwires.count,1)
        try d.undo(expectedRevision:d.revision); XCTAssertEqual(d.design,before.design)
        try d.redo(expectedRevision:d.revision); XCTAssertEqual(d.design,preview.design)
    }
    func testPreviewShowsShortButCommitIsAtomicAndSameNetCrossingConnects() throws {
        var d = try fixture(); try apply(.pcb(.addTrack(track())),&d)
        let other = track(31,net:21,points:[.init(20,5),.init(20,25)])
        let c = ElectronicsCommand.pcb(.addTrack(other)), before = d
        let p = try ElectronicsCommands.preview(c,document:d,expectedRevision:d.revision)
        XCTAssertFalse(p.canApply); XCTAssertTrue(p.blockingIssues.contains { $0.code == "pcb_short" && $0.subjectIDs?.contains(id(31)) == true })
        XCTAssertEqual(d,before)
        assertFailure("pcb_short") { try self.apply(c,&d) }; XCTAssertEqual(d,before)
        var same = other; same.netID = id(20); same.points = [.init(20,8),.init(20,12)]
        try apply(.pcb(.addTrack(same)),&d)
        XCTAssertFalse(try ElectronicsPCB.snapshot(d).issues.contains { $0.code == "pcb_floating_copper" })
    }
    func testLayerCrossingsRemainIsolatedAndThroughViaBridgesTopBottomAndInner() throws {
        var d = try fixture()
        try apply(.pcb(.configure(layerCount:4,rules:.init())),&d)
        try apply(.setComponentSide(id:id(11),side:.bottom),&d)
        try apply(.pcb(.batch([
            .addTrack(track(30,layer:0,points:[.init(5,10),.init(20,10)])),
            .addTrack(track(31,layer:3,points:[.init(20,10),.init(35,10)]))
        ])),&d)
        XCTAssertEqual(try ElectronicsPCB.snapshot(d).board.airwires.count,2)
        try apply(.pcb(.addVia(.init(id:id(40),netID:id(20),position:.init(20,10)))),&d)
        XCTAssertEqual(try ElectronicsPCB.snapshot(d).board.airwires.map(\.netID),[id(21)])
        try apply(.pcb(.addTrack(track(32,layer:1,points:[.init(20,10),.init(25,15)]))),&d)
        XCTAssertFalse(try ElectronicsPCB.snapshot(d).issues.contains { $0.code == "pcb_floating_copper" })
        assertFailure("occupied_stackup") { try self.apply(.pcb(.configure(layerCount:2,rules:.init())),&d) }
        let saved = try ElectronicsDocument.decode(d.encoded())
        XCTAssertEqual(saved.design.board.copper?.layerCount,4)
        try apply(.pcb(.removeVia(id(40))),&d)
        XCTAssertEqual(try ElectronicsPCB.snapshot(d).board.airwires.count,2)
    }
    func testDifferentNetsOnDifferentLayersDoNotShortButViaAtCrossingDoes() throws {
        var d = try fixture()
        try apply(.pcb(.addTrack(track())),&d)
        try apply(.pcb(.addTrack(track(31,net:21,layer:1,points:[.init(20,5),.init(20,25)]))),&d)
        XCTAssertFalse(try ElectronicsPCB.snapshot(d).issues.contains { $0.code == "pcb_short" })
        let before = d
        assertFailure("pcb_short") { try self.apply(.pcb(.addVia(.init(id:self.id(40),netID:self.id(20),position:.init(20,10)))),&d) }
        XCTAssertEqual(d,before)
    }
    func testFiniteWidthsClearanceTangencyAndNearMissAreDistinguished() throws {
        var d = try fixture(); try apply(.pcb(.addTrack(track(width:0.4))),&d)
        let safe = track(31,net:21,width:0.4,points:[.init(10,10.6),.init(30,10.6)])
        try apply(.pcb(.addTrack(safe)),&d) // .2 edge gap exactly
        var close = safe; close.points = [.init(10,10.599),.init(30,10.599)]
        assertFailure("pcb_clearance") { try self.apply(.pcb(.updateTrack(close)),&d) }
        close.points = [.init(10,10.4),.init(30,10.4)]
        assertFailure("pcb_short") { try self.apply(.pcb(.updateTrack(close)),&d) }
        XCTAssertEqual(d.design.board.copper?.tracks.last,safe)
    }
    func testWidthDrillRingAndConcaveBoardAreEnforcedForActualCopperExtent() throws {
        var d = try fixture()
        assertFailure("pcb_track_width") { try self.apply(.pcb(.addTrack(self.track(width:0.1))),&d) }
        assertFailure("pcb_drill") { try self.apply(.pcb(.addVia(.init(netID:self.id(20),position:.init(10,15),diameter:0.6,drill:0.2))),&d) }
        assertFailure("pcb_annular_ring") { try self.apply(.pcb(.addVia(.init(netID:self.id(20),position:.init(10,15),diameter:0.4,drill:0.3))),&d) }
        assertFailure("pcb_edge_clearance") { try self.apply(.pcb(.addTrack(self.track(points:[.init(0.2,5),.init(0.2,20)]))),&d) }
        try apply(.setBoard(outline:[.init(0,0),.init(40,0),.init(40,30),.init(25,30),.init(25,15),.init(15,15),.init(15,30),.init(0,30)],thickness:1.6,assemblyOrigin:.init()),&d)
        assertFailure("pcb_edge_clearance") { try self.apply(.pcb(.addTrack(self.track(points:[.init(10,20),.init(30,20)]))),&d) }
    }
    func testMovingPadBreaksPhysicalConnectivityAndNetChangesNeverRewriteCopper() throws {
        var d = try fixture(); try apply(.pcb(.addTrack(track())),&d)
        try apply(.moveComponent(id:id(11),to:.init(35,15)),&d)
        XCTAssertEqual(try ElectronicsPCB.snapshot(d).board.airwires.count,2)
        XCTAssertEqual(d.design.board.copper?.tracks[0],track())
        assertFailure("net_has_copper") { try self.apply(.removeNet(self.id(20)),&d) }
        try apply(.disconnect([.init(componentID:id(10),pinID:id(2))]),&d)
        XCTAssertTrue(try ElectronicsPCB.snapshot(d).issues.contains { $0.code == "pcb_short" })
        XCTAssertEqual(d.design.board.copper?.tracks[0].netID,id(20))
    }
    func testInvalidCopperAndStaleRevisionLeaveHistoryUntouched() throws {
        var d = try fixture(); let before = d
        assertFailure("invalid_track") { try self.apply(.pcb(.addTrack(self.track(points:[.init(5,10),.init(5,10)]))),&d) }
        assertFailure("invalid_track_layer") { try self.apply(.pcb(.addTrack(self.track(layer:2))),&d) }
        assertFailure("dangling_copper_net") { try self.apply(.pcb(.addTrack(self.track(net:99))),&d) }
        assertFailure("invalid_via") { try self.apply(.pcb(.addVia(.init(netID:self.id(20),position:.init(.nan,1)))),&d) }
        assertFailure("invalid_copper_layers") { try self.apply(.pcb(.configure(layerCount:3,rules:.init())),&d) }
        assertFailure("invalid_pcb_rules") { try self.apply(.pcb(.configure(layerCount:2,rules:.init(clearance:0))),&d) }
        XCTAssertEqual(d,before)
        let preview = try ElectronicsCommands.preview(.pcb(.addTrack(track())),document:d,expectedRevision:0)
        try apply(.renameNet(id:id(20),name:"POWER"),&d)
        assertFailure("stale_revision") { try ElectronicsCommands.apply(.pcb(.addTrack(self.track())),to:&d,expectedRevision:preview.baseRevision) }
        XCTAssertNil(d.design.board.copper)
    }
    func testPickSnapLayerFilteringAndRoutingLegs() throws {
        var d = try fixture(); try apply(.pcb(.addTrack(track())),&d)
        let s = try ElectronicsPCB.snapshot(d)
        XCTAssertEqual(s.pick(point:.init(20,10),tolerance:0.1,layer:0).first?.item,.track(id(30)))
        XCTAssertTrue(s.pick(point:.init(20,10),tolerance:0.1,layer:1).isEmpty)
        XCTAssertEqual(s.snapTargets(near:.init(5.1,10),radius:0.4,layer:0,netID:id(20),grid:0.1).first?.kind,.pad)
        XCTAssertEqual(s.snapTargets(near:.init(20,10.1),radius:0.4,layer:0,netID:id(20),grid:0.1).first?.kind,.track)
        XCTAssertEqual(s.snapTargets(near:.init(20,10),radius:0.4,layer:0,netID:id(21),grid:1).first?.kind,.grid)
        XCTAssertEqual(ElectronicsPCB.routePoints(from:.init(),to:.init(10,4)),[.init(),.init(4,4),.init(10,4)])
        XCTAssertEqual(ElectronicsPCB.routePoints(from:.init(),to:.init(10,4),diagonalFirst:false),[.init(),.init(6,0),.init(10,4)])
        XCTAssertEqual(ElectronicsPCB.routePoints(from:.init(),to:.init()),[.init()])
    }
    func testExactPadGeometryRotationAndDrillVoid() throws {
        func pad(_ shape: PadShape, _ size: PCBPoint, angle: Double = 0, drill: Double? = nil, radius: Double? = nil) -> PCBCopperPrimitive {
            PCBGeometry.pad(.init(componentID:id(10),padID:id(4),pinID:id(2),center:.init(),size:size,shape:shape,rotationDegrees:angle,copperSides:[.bottom],drillDiameter:drill,cornerRadius:radius),layerCount:4)
        }
        let rect = pad(.rectangle,.init(4,2),angle:90)
        XCTAssertEqual(PCBGeometry.pointDistance(.init(1.5,0),rect),0.5,accuracy:1e-9)
        XCTAssertEqual(rect.layers,[3])
        let oval = pad(.oval,.init(4,2))
        XCTAssertEqual(PCBGeometry.pointDistance(.init(3,0),oval),1,accuracy:1e-9)
        let round = pad(.roundedRectangle,.init(4,2),radius:0.5)
        XCTAssertEqual(PCBGeometry.pointDistance(.init(2,1),round),sqrt(0.5)-0.5,accuracy:1e-9)
        let annulus = pad(.circle,.init(2,2),drill:1)
        let tiny = PCBCopperPrimitive(item:.track(id(30)),netID:nil,layers:[0],core:[.init(0,0),.init(0.1,0)],radius:0.1)
        XCTAssertGreaterThan(PCBGeometry.gap(annulus,tiny),0)
        XCTAssertEqual(annulus.layers,[0,1,2,3])
        XCTAssertEqual(PCBGeometry.pointDistance(.init(),annulus),0.5,accuracy:1e-9)
    }
    func testMalformedBatchRollsBackAndCommandReplayIsIdentical() throws {
        var d = try fixture(); let before = d
        let c = ElectronicsCommand.pcb(.batch([.addTrack(track()),.removeVia(id(99))]))
        assertFailure("via_missing") { try self.apply(c,&d) }; XCTAssertEqual(d,before)
        let command = ElectronicsCommand.pcb(.batch([.addTrack(track()),.addVia(.init(id:id(40),netID:id(20),position:.init(20,10)))]))
        let decoded = try JSONDecoder().decode(ElectronicsCommand.self,from:JSONEncoder().encode(command))
        var other = d
        try apply(command,&d); try apply(decoded,&other)
        XCTAssertEqual(d,other); XCTAssertEqual(d.past.count,1)
    }
    func testMigrationFromOldFormatsAndUnsupportedFuturePreservesHistory() throws {
        let d = try fixture()
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with:d.encoded()) as? [String:Any])
        for version in 1...5 {
            json["formatVersion"] = version
            let old = try ElectronicsDocument.decode(JSONSerialization.data(withJSONObject:json))
            XCTAssertEqual(old.formatVersion,7); XCTAssertEqual(old.design,d.design)
        }
        json["formatVersion"] = 8
        assertFailure("unsupported_version") { _ = try ElectronicsDocument.decode(JSONSerialization.data(withJSONObject:json)) }
    }
    func testSchematicWireDeletionRetainsCopperNetAndReportsDisconnectedPads() throws {
        var d = try fixture()
        try apply(.disconnect(d.design.connections.map(\.pin)),&d)
        let pins = [PinReference(componentID:id(10),pinID:id(2)),.init(componentID:id(11),pinID:id(2))]
        let wire = SchematicWire(id:id(81),start:.pin(pins[0]),end:.pin(pins[1]))
        let sheet = SchematicSheet(id:id(80),name:"Test",symbols:[.init(componentID:id(10),position:.init(5,5)),.init(componentID:id(11),position:.init(25,5))],wires:[wire])
        try apply(.schematic(.addSheet(sheet)),&d)
        let netID = try XCTUnwrap(d.design.connections.first { $0.pin == pins[0] }?.netID)
        var t = track(); t.netID = netID
        try apply(.pcb(.addTrack(t)),&d)
        try apply(.schematic(.removeWire(wire.id)),&d)
        XCTAssertTrue(d.design.nets.contains { $0.id == netID })
        XCTAssertEqual(d.design.board.copper?.tracks[0].netID,netID)
        XCTAssertTrue(try ElectronicsPCB.snapshot(d).issues.contains { $0.code == "pcb_short" })
        XCTAssertTrue(ElectronicsValidation.integrity(d.design).isEmpty)
        XCTAssertEqual(try ElectronicsDocument.decode(d.encoded()),d)
        try d.undo(expectedRevision:d.revision)
        XCTAssertFalse(try ElectronicsPCB.snapshot(d).issues.contains { $0.code == "pcb_short" })
    }

    func testPlatedPadBridgesLayersAndUnassignedPadCannotBeUsedAsBridge() throws {
        var design = try fixture().design
        design.library.footprints[0].pads[0].drillDiameter = 0.4
        var d = try ElectronicsDocument(design:design)
        try apply(.pcb(.addTrack(track(layer:1))),&d)
        XCTAssertEqual(try ElectronicsPCB.snapshot(d).board.airwires.count,1)
        try apply(.disconnect([.init(componentID:id(12),pinID:id(2))]),&d)
        try apply(.markNoConnect([.init(componentID:id(12),pinID:id(2))]),&d)
        assertFailure("pcb_short") { try self.apply(.pcb(.addTrack(self.track(31,layer:1,points:[.init(20,10),.init(20,5)]))),&d) }
    }

    func testDeletingOrRepairingExistingViolationsRemainsPossible() throws {
        var d = try fixture(); try apply(.pcb(.addTrack(track())),&d)
        try apply(.moveComponent(id:id(12),to:.init(20,10)),&d)
        XCTAssertTrue(try ElectronicsPCB.snapshot(d).issues.contains { $0.code == "pcb_short" })
        try apply(.pcb(.removeTrack(id(30))),&d)
        XCTAssertFalse(try ElectronicsPCB.snapshot(d).issues.contains { $0.code == "pcb_short" })
    }

    func testRoutingHelpersPreserveReversalAndRejectNonFiniteInput() {
        XCTAssertEqual(ElectronicsPCB.simplifiedPoints([.init(),.init(),.init(1,1),.init(2,2),.init(1,1)]),[.init(),.init(2,2),.init(1,1)])
        XCTAssertTrue(ElectronicsPCB.simplifiedPoints([.init(.nan,0)]).isEmpty)
        XCTAssertEqual(ElectronicsPCB.gridPoint(.init(1.12,-1.13),spacing:0.25),.init(1,-1.25))
        XCTAssertNil(ElectronicsPCB.gridPoint(.init(),spacing:0))
        XCTAssertNil(ElectronicsPCB.gridPoint(.init(100,100),spacing:Double.leastNonzeroMagnitude))
    }

    func testCancelledSnapshotDoesNotReturnObsoleteGeometry() async throws {
        let doc = try fixture()
        let task = Task.detached { () throws -> PCBSnapshot in
            withUnsafeCurrentTask { $0?.cancel() }
            return try ElectronicsPCB.snapshot(doc)
        }
        do { _ = try await task.value; XCTFail("Cancelled work returned a drawing") }
        catch is CancellationError { }
    }

}
