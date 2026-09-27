import Foundation
import XCTest
@testable import ElectronicsCore

final class PCBRuleTests: XCTestCase {
    func id(_ n: Int) -> UUID { UUID(uuidString:String(format:"EEEE0000-0000-0000-0000-%012d",n))! }
    func document() throws -> ElectronicsDocument {
        var d = try ElectronicsDocument.empty(name:"Regole PCB").design
        d.nets = [.init(id:id(1),name:"POWER"),.init(id:id(2),name:"SIGNAL")]
        return try .init(design:d)
    }
    func apply(_ c: PCBCommand, _ d: inout ElectronicsDocument) throws {
        try ElectronicsCommands.apply(.pcb(c),to:&d,expectedRevision:d.revision)
    }
    func track(_ n: Int = 10, net: Int = 1, y: Double = 10, width: Double = 0.25, layer: Int = 0) -> PCBTrack {
        .init(id:id(n),netID:id(net),layer:layer,width:width,points:[.init(5,y),.init(35,y)])
    }
    func area(_ n: Int = 30, layers: [Int] = [0]) -> PCBKeepout {
        .init(id:id(n),name:"Antenna",outline:[.init(18,8),.init(22,8),.init(22,12),.init(18,12)],layers:layers)
    }
    func failure(_ code: String, _ body: () throws -> Void, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try body(),file:file,line:line) { error in
            XCTAssertTrue((error as? ElectronicsFailure)?.issues.contains { $0.code == code } == true,"\(error)",file:file,line:line)
        }
    }
    func testEffectiveClassRulesRespectBoardFloorAndSeparatePreferredDimensions() throws {
        var d = try document()
        try apply(.configure(layerCount:4,rules:.init(clearance:0.3,minimumTrackWidth:0.4,minimumDrill:0.4,minimumAnnularRing:0.2)),&d)
        let c = PCBNetClass(id:id(20),name:"Potenza",netIDs:[id(1)],constraints:.init(clearance:0.2,minimumTrackWidth:0.7,minimumDrill:0.2,minimumAnnularRing:0.1))
        try apply(.addNetClass(c),&d)
        let r = try ElectronicsPCB.resolvedRules(design:d.design,netID:id(1))
        XCTAssertEqual(r.classID,c.id); XCTAssertEqual(r.className,"Potenza")
        XCTAssertEqual(r.rules.clearance,0.3); XCTAssertEqual(r.rules.minimumTrackWidth,0.7)
        XCTAssertEqual(r.routing.trackWidth,0.7); XCTAssertEqual(r.routing.viaDrill,0.4)
        XCTAssertEqual(r.routing.viaDiameter,0.8,accuracy:1e-9)
        XCTAssertEqual(d.design.board.copper?.netClasses[0],c) // no silent rewrite
        let fallback = try ElectronicsPCB.resolvedRules(design:d.design,netID:id(2))
        XCTAssertNil(fallback.classID); XCTAssertEqual(fallback.routing.trackWidth,0.4)
        failure("net_missing") { _ = try ElectronicsPCB.resolvedRules(design:d.design,netID:self.id(99)) }
    }
    func testNarrowTrackAndSmallViaRejectedButChangingRulesAllowsRepair() throws {
        var d = try document(); try apply(.addTrack(track()),&d)
        let c = PCBNetClass(id:id(20),name:"Potenza",netIDs:[id(1)],constraints:.init(minimumTrackWidth:0.6,minimumDrill:0.5,minimumAnnularRing:0.25))
        try apply(.addNetClass(c),&d)
        XCTAssertTrue(try ElectronicsPCB.snapshot(d).issues.contains { $0.code == "pcb_track_width" })
        let before = d
        failure("pcb_track_width") { try self.apply(.addTrack(self.track(11,y:15)),&d) }; XCTAssertEqual(d,before)
        failure("pcb_drill") { try self.apply(.addVia(.init(id:self.id(12),netID:self.id(1),position:.init(20,15))),&d) }
        try apply(.updateTrack(track(width:0.6)),&d)
        let r = try ElectronicsPCB.resolvedRules(design:d.design,netID:id(1)).routing
        try apply(.addVia(.init(id:id(12),netID:id(1),position:.init(20,10),diameter:r.viaDiameter,drill:r.viaDrill)),&d)
        XCTAssertFalse(try ElectronicsPCB.snapshot(d).issues.contains { $0.severity == .error })
    }
    func testPairClearanceUsesStricterNetIncludingBroadPhaseInEitherOrder() throws {
        for first in [true,false] {
            var d = try document()
            try apply(.addNetClass(.init(id:id(20),name:"Isolata",netIDs:[id(2)],constraints:.init(clearance:1))),&d)
            let a = track(10,net:first ? 1 : 2,y:10,width:0.2)
            let b = track(11,net:first ? 2 : 1,y:11,width:0.2)
            try apply(.addTrack(a),&d)
            let p = try ElectronicsCommands.preview(.pcb(.addTrack(b)),document:d,expectedRevision:d.revision)
            XCTAssertTrue(p.blockingIssues.contains { $0.code == "pcb_clearance" && $0.message.contains("1.0") })
            XCTAssertFalse(p.canApply)
            var safe = b; safe.points = [.init(5,11.2),.init(35,11.2)]
            try apply(.addTrack(safe),&d) // exactly the required clearance is allowed
        }
    }
    func testAssignmentsAreExclusiveExplicitAndUndoable() throws {
        var d = try document()
        try apply(.batch([.addNetClass(.init(id:id(20),name:"A",netIDs:[id(1)])),.addNetClass(.init(id:id(21),name:"B"))]),&d)
        let before = d
        failure("ambiguous_net_class") { try self.apply(.updateNetClass(.init(id:self.id(21),name:"B",netIDs:[self.id(1)])),&d) }
        XCTAssertEqual(d,before)
        try apply(.assignNetClass(netIDs:[id(1),id(2)],classID:id(21)),&d)
        XCTAssertTrue(d.design.board.copper!.netClasses[0].netIDs.isEmpty)
        XCTAssertEqual(Set(d.design.board.copper!.netClasses[1].netIDs),[id(1),id(2)])
        try d.undo(expectedRevision:d.revision); XCTAssertEqual(d.design,before.design)
        try d.redo(expectedRevision:d.revision)
        try apply(.removeNetClass(id(21)),&d)
        XCTAssertNil(try ElectronicsPCB.resolvedRules(design:d.design,netID:id(1)).classID)
        try d.undo(expectedRevision:d.revision)
        try apply(.assignNetClass(netIDs:[id(1)],classID:nil),&d)
        XCTAssertEqual(d.design.board.copper!.netClasses[1].netIDs,[id(2)])
        try ElectronicsCommands.apply(.removeNet(id(2)),to:&d,expectedRevision:d.revision)
        XCTAssertTrue(d.design.board.copper!.netClasses.allSatisfy { $0.netIDs.isEmpty })
    }
    func testInvalidClassDefinitionAndAssignmentAreAtomic() throws {
        var d = try document(); let original = d
        for c in [PCBNetClass(name:" "),.init(name:"A",netIDs:[id(99)]),.init(name:"A",netIDs:[id(1),id(1)]),
                  .init(name:"A",constraints:.init(clearance:0)),.init(name:"A",routing:.init(viaDiameter:0.3,viaDrill:0.4))] {
            XCTAssertThrowsError(try apply(.addNetClass(c),&d)); XCTAssertEqual(d,original)
        }
        try apply(.addNetClass(.init(id:id(20),name:"Power")),&d)
        failure("invalid_net_class_name") { try self.apply(.addNetClass(.init(name:" power ")),&d) }
        failure("net_class_missing") { try self.apply(.assignNetClass(netIDs:[self.id(1)],classID:self.id(99)),&d) }
        failure("invalid_class_assignment") { try self.apply(.assignNetClass(netIDs:[self.id(99)],classID:self.id(20)),&d) }
    }
    func testKeepoutRejectsCrossingTrackEvenWithBothEndpointsOutside() throws {
        var d = try document(); let k = area(); try apply(.addKeepout(k),&d)
        let before = d, c = ElectronicsCommand.pcb(.addTrack(track()))
        let preview = try ElectronicsCommands.preview(c,document:d,expectedRevision:d.revision)
        XCTAssertFalse(preview.canApply); XCTAssertEqual(d,before)
        let issue = try XCTUnwrap(preview.blockingIssues.first { $0.code == "pcb_keepout" })
        XCTAssertEqual(Set(issue.subjectIDs ?? []),[k.id,id(10)])
        XCTAssertTrue(issue.message.contains("Antenna")); XCTAssertNotNil(issue.position)
        failure("pcb_keepout") { try ElectronicsCommands.apply(c,to:&d,expectedRevision:d.revision) }
        XCTAssertEqual(d,before)
        try apply(.addTrack(track(layer:1)),&d) // top-only restriction
        XCTAssertEqual(try ElectronicsPCB.snapshot(d).keepouts,[k])
    }
    func testKeepoutUsesActualWidthAndIncludesItsBoundary() throws {
        var d = try document(); try apply(.addKeepout(area()),&d)
        failure("pcb_keepout") { try self.apply(.addTrack(self.track(y:7.9,width:0.2)),&d) }
        try apply(.addTrack(track(y:7.89,width:0.2)),&d)
    }
    func testKeepoutSelectiveTypesAndInnerLayerThroughVia() throws {
        var d = try document(); try apply(.configure(layerCount:4,rules:.init()),&d)
        var k = area(layers:[2]); k.tracks = false; k.pads = false
        try apply(.addKeepout(k),&d)
        try apply(.addTrack(track(layer:2)),&d)
        failure("pcb_keepout") { try self.apply(.addVia(.init(id:self.id(11),netID:self.id(1),position:.init(20,10))),&d) }
        k.vias = false; k.tracks = true; try apply(.updateKeepout(k),&d)
        try apply(.addVia(.init(id:id(11),netID:id(1),position:.init(20,10))),&d)
        XCTAssertTrue(try ElectronicsPCB.snapshot(d).issues.contains { $0.code == "pcb_keepout" && $0.subjectIDs?.contains(id(10)) == true })
        failure("occupied_stackup") { try self.apply(.configure(layerCount:6,rules:.init()),&d) }
    }
    func testConcaveAreaDoesNotFillItsNotchAndDetectsEnclosure() throws {
        var k = area(); k.outline = [.init(10,10),.init(20,10),.init(20,12),.init(12,12),.init(12,20),.init(10,20)]
        let notch = PCBCopperPrimitive(item:.track(id(10)),netID:id(1),layers:[0],core:[.init(15,15),.init(18,18)],radius:0.2)
        XCTAssertFalse(PCBGeometry.keepoutIntersects(k,notch))
        var inside = notch; inside.core = [.init(11,12),.init(11,18)]
        XCTAssertTrue(PCBGeometry.keepoutIntersects(k,inside))
        let largePad = PCBCopperPrimitive(item:.pad(componentID:id(40),padID:id(41)),netID:nil,layers:[0],core:[.init(5,5),.init(25,5),.init(25,25),.init(5,25)],radius:0)
        XCTAssertTrue(PCBGeometry.keepoutIntersects(k,largePad))
    }
    func testAreaInEmptyBoreDoesNotTouchCopperButRingDoes() {
        let via = PCBCopperPrimitive(item:.via(id(10)),netID:id(1),layers:[0,1],core:[.init(20,10)],radius:1,drillDiameter:1)
        var k = area(); k.outline = ElectronicsPCB.keepoutRectangle(from:.init(19.8,9.8),to:.init(20.2,10.2))!
        XCTAssertFalse(PCBGeometry.keepoutIntersects(k,via))
        k.outline = ElectronicsPCB.keepoutRectangle(from:.init(20.4,9.8),to:.init(20.6,10.2))!
        XCTAssertTrue(PCBGeometry.keepoutIntersects(k,via))
    }
    func testRuleCanBePlacedOnExistingCopperThenRepairedWithSingleUndo() throws {
        var d = try document(); try apply(.addTrack(track()),&d)
        let c = PCBCommand.addKeepout(area())
        let p = try ElectronicsCommands.preview(.pcb(c),document:d,expectedRevision:d.revision)
        XCTAssertTrue(p.canApply); XCTAssertTrue(p.issues.contains { $0.code == "pcb_keepout" })
        try apply(c,&d); let withError = d
        try apply(.batch([.moveKeepout(id:id(30),offset:.init(0,10)),.addNetClass(.init(id:id(20),name:"Power",netIDs:[id(1)]))]),&d)
        XCTAssertFalse(try ElectronicsPCB.snapshot(d).issues.contains { $0.code == "pcb_keepout" })
        XCTAssertEqual(d.past.count,3)
        d = try ElectronicsDocument.decode(d.encoded())
        try d.undo(expectedRevision:d.revision); XCTAssertEqual(d.design,withError.design)
        try d.redo(expectedRevision:d.revision)
        XCTAssertEqual(d.design.board.copper?.keepouts[0].outline[0],.init(18,18))
        let before = d
        failure("keepout_missing") { try self.apply(.batch([.removeKeepout(self.id(30)),.removeKeepout(self.id(99))]),&d) }
        XCTAssertEqual(d,before)
    }
    func testInvalidKeepoutsRejectedBeforeGeometryAndBatchRollsBack() throws {
        var d = try document()
        var crossed = area(); crossed.outline = [.init(1,1),.init(5,5),.init(1,5),.init(5,1)]
        var empty = area(); empty.tracks = false; empty.vias = false; empty.pads = false
        var duplicate = area(); duplicate.layers = [0,0]
        var outside = area(); outside.layers = [2]
        var degenerate = area(); degenerate.outline = [.init(),.init(1,1),.init(2,2)]
        let original = d
        for k in [crossed,empty,duplicate,outside,degenerate] {
            XCTAssertThrowsError(try apply(.batch([.addTrack(track()),.addKeepout(k)]),&d)); XCTAssertEqual(d,original)
        }
        var collidingID = area(); collidingID.id = id(1)
        failure("duplicate_copper_identity") { try self.apply(.addKeepout(collidingID),&d) }
    }
    func testIndexedPickingSnappingAndTranslationKeepStableIdentity() throws {
        var d = try document(); try apply(.addKeepout(area()),&d)
        let s = try ElectronicsPCB.snapshot(d)
        XCTAssertTrue(s.primitives.isEmpty)
        XCTAssertEqual(s.pickKeepouts(point:.init(20,10),tolerance:0,layer:0).map(\.id),[id(30)])
        XCTAssertTrue(s.pickKeepouts(point:.init(20,10),tolerance:2,layer:1).isEmpty)
        XCTAssertEqual(s.pickKeepouts(point:.init(17.9,10),tolerance:0.11).first?.position,.init(18,10))
        XCTAssertEqual(s.keepoutSnapTargets(near:.init(18.1,8.1),radius:0.2,layer:0).first?.kind,.vertex)
        XCTAssertEqual(s.keepoutSnapTargets(near:.init(20,8.1),radius:0.2,layer:0).first?.position,.init(20,8))
        XCTAssertTrue(s.pickKeepouts(point:.init(.nan,0),tolerance:1).isEmpty)
        try apply(.moveKeepout(id:id(30),offset:.init(10,0)),&d)
        XCTAssertEqual(try ElectronicsPCB.snapshot(d).pickKeepouts(point:.init(30,10),tolerance:0).first?.id,id(30))
        XCTAssertEqual(s.pickKeepouts(point:.init(20,10),tolerance:0).first?.id,id(30)) // immutable snapshot
    }
    func testFormatFourWithoutNewKeysMigratesEntireHistoryAndReencodesAsFive() throws {
        var d = try document(); try apply(.addTrack(track()),&d)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with:d.encoded()) as? [String:Any])
        func strip(_ value: Any) -> Any {
            if let list = value as? [Any] { return list.map(strip) }
            if let object = value as? [String:Any] { return object.filter { !["netClasses","keepouts"].contains($0.key) }.mapValues(strip) }
            return value
        }
        json = strip(json) as! [String:Any]; json["formatVersion"] = 4
        var migrated = try ElectronicsDocument.decode(JSONSerialization.data(withJSONObject:json))
        XCTAssertEqual(migrated.formatVersion,5); XCTAssertEqual(migrated,d)
        try migrated.undo(expectedRevision:migrated.revision)
        try migrated.redo(expectedRevision:migrated.revision); XCTAssertEqual(migrated.design,d.design)
    }
    func testRectangleHelperNormalizesDirectionsAndRejectsDegeneracy() {
        XCTAssertEqual(ElectronicsPCB.keepoutRectangle(from:.init(4,5),to:.init(2,3)),[.init(2,3),.init(4,3),.init(4,5),.init(2,5)])
        XCTAssertNil(ElectronicsPCB.keepoutRectangle(from:.init(2,2),to:.init(2,3)))
        XCTAssertNil(ElectronicsPCB.keepoutRectangle(from:.init(.infinity,2),to:.init()))
    }
    func testSchematicSplitInheritsClassAndDifferentClassesCannotMergeSilently() throws {
        var d = try ElectronicsDocument.empty()
        let j = (0..<4).map { SchematicJunction(id:id(100+$0),position:.init(Double($0)*5,10)) }
        let left = SchematicWire(id:id(110),start:.junction(j[0].id),end:.junction(j[1].id))
        let right = SchematicWire(id:id(111),start:.junction(j[2].id),end:.junction(j[3].id))
        let bridge = SchematicWire(id:id(112),start:.junction(j[1].id),end:.junction(j[2].id))
        let sheet = SchematicSheet(id:id(120),name:"Test",junctions:j,wires:[left,right,bridge])
        try ElectronicsCommands.apply(.schematic(.addSheet(sheet)),to:&d,expectedRevision:d.revision)
        let originalNet = try XCTUnwrap(d.design.nets.first?.id)
        try apply(.addNetClass(.init(id:id(20),name:"Potenza",netIDs:[originalNet],constraints:.init(minimumTrackWidth:0.8))),&d)
        try ElectronicsCommands.apply(.schematic(.removeWire(bridge.id)),to:&d,expectedRevision:d.revision)
        let splitNets = Set(d.design.schematic!.wireNets.map(\.netID))
        XCTAssertEqual(splitNets.count,2)
        XCTAssertTrue(splitNets.isSubset(of:d.design.board.copper!.classifiedNetIDs))
        for net in splitNets { XCTAssertEqual(try ElectronicsPCB.resolvedRules(design:d.design,netID:net).rules.minimumTrackWidth,0.8) }
        try apply(.addNetClass(.init(id:id(21),name:"Segnale")),&d)
        let other = try XCTUnwrap(splitNets.first { $0 != originalNet })
        try apply(.assignNetClass(netIDs:[other],classID:id(21)),&d)
        let before = d
        failure("schematic_net_class_conflict") {
            try ElectronicsCommands.apply(.schematic(.addWire(sheetID:sheet.id,wire:bridge)),to:&d,expectedRevision:d.revision)
        }
        XCTAssertEqual(d,before)
        try apply(.assignNetClass(netIDs:[other],classID:id(20)),&d)
        try ElectronicsCommands.apply(.schematic(.addWire(sheetID:sheet.id,wire:bridge)),to:&d,expectedRevision:d.revision)
        XCTAssertEqual(Set(d.design.schematic!.wireNets.map(\.netID)).count,1)
        try ElectronicsCommands.apply(.schematic(.batch([.removeWire(left.id),.removeWire(right.id),.removeWire(bridge.id)])),to:&d,expectedRevision:d.revision)
        XCTAssertTrue(splitNets.isSubset(of:Set(d.design.nets.map(\.id)))) // retained class references
        XCTAssertEqual(try ElectronicsDocument.decode(d.encoded()),d)
    }
    func testRotatedAndBottomPadsUseExactCopperForKeepoutsAndLayerFilter() throws {
        var d = try ElectronicsDocument.empty()
        let starter = ElectronicsStarterLibrary.components[0]
        try ElectronicsCommands.apply(starter.command(componentID:id(50),reference:"R1",position:.init(20,10)),to:&d,expectedRevision:0)
        try ElectronicsCommands.apply(.rotateComponent(id:id(50),by:45),to:&d,expectedRevision:d.revision)
        try ElectronicsCommands.apply(.flipComponent(id(50)),to:&d,expectedRevision:d.revision)
        let pad = try XCTUnwrap(ElectronicsPCB.snapshot(d).primitives.first)
        var k = area(); k.outline = ElectronicsPCB.keepoutRectangle(from:.init(pad.center.x-0.1,pad.center.y-0.1),to:.init(pad.center.x+0.1,pad.center.y+0.1))!
        k.tracks = false; k.vias = false
        try apply(.addKeepout(k),&d)
        XCTAssertFalse(try ElectronicsPCB.snapshot(d).issues.contains { $0.code == "pcb_keepout" })
        k.layers = [1]; try apply(.updateKeepout(k),&d)
        let issue = try XCTUnwrap(ElectronicsPCB.snapshot(d).issues.first { $0.code == "pcb_keepout" })
        XCTAssertTrue(Set(pad.item.subjectIDs+[k.id]).isSubset(of:Set(issue.subjectIDs ?? [])))
        XCTAssertEqual(try ElectronicsPCB.snapshot(d).board.airwires.count,0)
    }
    func testCommandReplayStaleRevisionAndKeepoutOnlyStackupChange() throws {
        var d = try document()
        let c = ElectronicsCommand.pcb(.batch([.addKeepout(area()),.addNetClass(.init(id:id(20),name:"A",netIDs:[id(1)]))]))
        let p = try ElectronicsCommands.preview(c,document:d,expectedRevision:0)
        let decoded = try JSONDecoder().decode(ElectronicsCommand.self,from:JSONEncoder().encode(c))
        try ElectronicsCommands.apply(decoded,to:&d,expectedRevision:0)
        XCTAssertEqual(d.design,p.design); XCTAssertEqual(d.past.count,1)
        let before = d
        failure("stale_revision") { try ElectronicsCommands.apply(decoded,to:&d,expectedRevision:0) }
        failure("occupied_stackup") { try self.apply(.configure(layerCount:4,rules:.init()),&d) }
        XCTAssertEqual(d,before)
        try apply(.batch([.removeKeepout(id(30)),.configure(layerCount:4,rules:.init())]),&d)
        XCTAssertEqual(d.design.board.copper?.layerCount,4)
    }
    func testBulkRulesMatchIndividualResolutionWithoutDroppingUnclassifiedNets() throws {
        var d = try document()
        try apply(.addNetClass(.init(id:id(20),name:"Potenza",netIDs:[id(1)],constraints:.init(minimumTrackWidth:0.8))),&d)
        let all = try ElectronicsPCB.resolvedRules(design:d.design)
        XCTAssertEqual(Set(all.keys),[id(1),id(2)])
        for net in d.design.nets { XCTAssertEqual(all[net.id],try ElectronicsPCB.resolvedRules(design:d.design,netID:net.id)) }
        var invalid = d.design; invalid.board.copper!.netClasses.append(.init(name:"Doppia",netIDs:[id(1)]))
        failure("ambiguous_net_class") { _ = try ElectronicsPCB.resolvedRules(design:invalid) }
    }
}
