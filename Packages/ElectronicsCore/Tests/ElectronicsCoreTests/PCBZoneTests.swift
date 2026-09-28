import Foundation
import XCTest
@testable import ElectronicsCore

final class PCBZoneTests: XCTestCase {
    func id(_ n: Int) -> UUID { UUID(uuidString:String(format:"BBBB0000-0000-0000-0000-%012d",n))! }
    func rectangle(_ x: Double, _ y: Double, _ w: Double, _ h: Double) -> [PCBPoint] {
        [.init(x,y),.init(x+w,y),.init(x+w,y+h),.init(x,y+h)]
    }
    func document() throws -> ElectronicsDocument {
        var d = try ElectronicsDocument.empty(name:"Piani").design
        d.nets = [.init(id:id(1),name:"GND"),.init(id:id(2),name:"POWER")]
        return try .init(design:d)
    }
    func zone(_ n: Int = 10, net: Int = 1, layer: Int = 0, remove: Bool = false) -> PCBZone {
        .init(id:id(n),netID:id(net),layer:layer,outline:rectangle(1,1,48,28),removeIslands:remove)
    }
    func apply(_ command: PCBCommand, _ d: inout ElectronicsDocument) throws {
        try ElectronicsCommands.apply(.pcb(command),to:&d,expectedRevision:d.revision)
    }
    func testDecompositionSubtractsOverlapsWithoutDoubleRemoval() throws {
        let cells = try PCBPolygonFill.cells(subject:rectangle(0,0,10,10),board:rectangle(-1,-1,12,12),
                    obstacles:[rectangle(2,2,4,4),rectangle(4,4,4,4)])
        XCTAssertEqual(cells.map(PCBPolygonFill.area).reduce(0,+),72,accuracy:1e-9)
        for cell in cells {
            XCTAssertTrue(ElectronicsGeometry.simplePolygon(cell))
            XCTAssertGreaterThan(PCBPolygonFill.area(cell),0)
        }
    }
    func testDecompositionConcaveSubjectAndBoardWithCrossingEdges() throws {
        let concave: [PCBPoint] = [.init(0,0),.init(10,0),.init(10,3),.init(3,3),.init(3,10),.init(0,10)]
        let diamond: [PCBPoint] = [.init(0,5),.init(5,0),.init(10,5),.init(5,10)]
        let cells = try PCBPolygonFill.cells(subject:concave,board:diamond,obstacles:[])
        // Each arm intersects a triangle of area 9; their overlap is a triangle
        // with legs 1: 9 + 9 - 0.5 = 17.5.
        XCTAssertEqual(cells.map(PCBPolygonFill.area).reduce(0,+),17.5,accuracy:1e-9)
        for c in cells { for p in c { XCTAssertTrue(PCBGeometry.inside(p,concave)); XCTAssertTrue(PCBGeometry.inside(p,diamond)) } }
    }
    func testFillCropsAtBoardAndUsesActualForeignClearanceAndLayer() throws {
        var d = try document(), z = zone(); z.outline = rectangle(-5,-5,60,40)
        try apply(.addNetClass(.init(name:"Potenza",netIDs:[id(2)],constraints:.init(clearance:0.8))),&d)
        try apply(.addTrack(.init(id:id(20),netID:id(2),layer:0,width:0.5,points:[.init(20,5),.init(20,25)])),&d)
        try apply(.addZone(z),&d)
        let s = try ElectronicsPCB.snapshot(d), track = try XCTUnwrap(s.primitives.first { $0.item == .track(id(20)) })
        let cells = s.primitives.filter { $0.item == .zone(z.id) }
        XCTAssertFalse(cells.isEmpty)
        for c in cells { XCTAssertGreaterThanOrEqual(PCBGeometry.gap(c,track),0.8-1e-8) }
        XCTAssertFalse(s.issues.contains { $0.severity == .error })
        XCTAssertFalse(s.pick(point:.init(0.1,15),tolerance:0,layer:0).contains { $0.item == .zone(z.id) })
        XCTAssertFalse(s.pick(point:.init(20,15),tolerance:0,layer:0).contains { $0.item == .zone(z.id) })
        var lower = z; lower.id = id(11); lower.layer = 1
        try apply(.addZone(lower),&d)
        XCTAssertTrue(try ElectronicsPCB.snapshot(d).pick(point:.init(20,15),tolerance:0,layer:1).contains { $0.item == .zone(lower.id) })
    }
    func testKeepoutCutsPlaneButTracksCanRemainAllowed() throws {
        var d = try document()
        let k = PCBKeepout(id:id(30),outline:rectangle(20,0,2,30),layers:[0],tracks:false,vias:false,pads:false,zones:true)
        try apply(.addKeepout(k),&d); try apply(.addZone(zone()),&d)
        let s = try ElectronicsPCB.snapshot(d)
        XCTAssertEqual(s.zones[0].islandCount,2)
        XCTAssertFalse(s.pick(point:.init(21,10),tolerance:0,layer:0).contains { $0.item == .zone(id(10)) })
        XCTAssertFalse(s.issues.contains { $0.code == "pcb_keepout" })
    }
    func testEmptyZoneIsEditableButCannotBePickedAsConductiveCopper() throws {
        var d = try document(); try apply(.addZone(zone(remove:true)),&d)
        let s = try ElectronicsPCB.snapshot(d)
        XCTAssertTrue(s.zones[0].cells.isEmpty); XCTAssertEqual(s.zones[0].removedIslandCount,1)
        XCTAssertTrue(s.pick(point:.init(10,10),tolerance:0).isEmpty)
        XCTAssertEqual(s.pickZones(point:.init(10,10),tolerance:0).first?.id,id(10))
        XCTAssertTrue(s.issues.contains { $0.code == "pcb_zone_empty" })
    }
    func testZoneCommandsAreAtomicPersistentAndUseStableIdentity() throws {
        var d = try document(); let z = zone(); let c = ElectronicsCommand.pcb(.addZone(z))
        let original = d, preview = try ElectronicsCommands.preview(c,document:d,expectedRevision:d.revision)
        XCTAssertEqual(d,original); XCTAssertTrue(preview.canApply)
        try ElectronicsCommands.apply(c,to:&d,expectedRevision:d.revision)
        XCTAssertEqual(try preview.pcbSnapshot().zones,try ElectronicsPCB.snapshot(d).zones)
        try apply(.moveZone(id:z.id,offset:.init(1,0)),&d)
        let moved = d.design
        d = try ElectronicsDocument.decode(d.encoded()); XCTAssertEqual(d.formatVersion,9)
        try d.undo(expectedRevision:d.revision); XCTAssertEqual(d.design.board.copper?.zones,[z])
        try d.redo(expectedRevision:d.revision); XCTAssertEqual(d.design,moved)
        let before = d
        XCTAssertThrowsError(try apply(.batch([.removeZone(z.id),.removeZone(id(99))]),&d)); XCTAssertEqual(d,before)
        XCTAssertThrowsError(try ElectronicsCommands.apply(.removeNet(id(1)),to:&d,expectedRevision:d.revision))
        XCTAssertThrowsError(try apply(.configure(layerCount:4,rules:.init()),&d))
    }
    func testDifferentNetOverlapRejectedWithoutUUIDPriority() throws {
        var d = try document(); try apply(.addZone(zone()),&d); let before = d
        XCTAssertThrowsError(try apply(.addZone(zone(11,net:2)),&d)) { error in
            XCTAssertTrue((error as? ElectronicsFailure)?.issues.contains { $0.code == "overlapping_zone_nets" } == true)
        }
        XCTAssertEqual(d,before)
        try apply(.addZone(zone(11,net:2,layer:1)),&d)
    }
    func testForeignTrackRefillsPlaneInsteadOfShortingToOldFill() throws {
        var d = try document(); try apply(.addZone(zone()),&d)
        let before = try ElectronicsPCB.snapshot(d).zones[0].area
        try apply(.addTrack(.init(id:id(20),netID:id(2),layer:0,width:0.4,points:[.init(5,10),.init(45,10)])),&d)
        let s = try ElectronicsPCB.snapshot(d)
        XCTAssertLessThan(s.zones[0].area,before)
        XCTAssertFalse(s.issues.contains { $0.severity == .error })
        try d.undo(expectedRevision:d.revision)
        XCTAssertEqual(try ElectronicsPCB.snapshot(d).zones[0].area,before)
    }
    func testInvalidPolygonsAndZoneReferencesAreRejected() throws {
        var d = try document(); let before = d
        var z = zone(); z.outline = [.init(1,1),.init(5,5),.init(1,5),.init(5,1)]
        XCTAssertThrowsError(try apply(.addZone(z),&d)); XCTAssertEqual(d,before)
        z = zone(net:99); XCTAssertThrowsError(try apply(.addZone(z),&d))
        z = zone(layer:32); XCTAssertThrowsError(try apply(.addZone(z),&d))
        z = zone(); z.id = id(1); XCTAssertThrowsError(try apply(.addZone(z),&d))
    }
    func padDocument(bottom: Bool = false) throws -> ElectronicsDocument {
        var d = try document()
        let template = ElectronicsStarterLibrary.components[0]
        for (n,x) in [(100,8.0),(101,40.0)] {
            try ElectronicsCommands.apply(template.command(componentID:id(n),reference:"R\(n)",position:.init(x,10)),to:&d,expectedRevision:d.revision)
        }
        let pads = try ElectronicsConnectivity.snapshot(d.design).pads.filter { $0.componentID == id(100) || $0.componentID == id(101) }
        let pins = [100,101].map { n in pads.filter { $0.componentID == id(n) }.max { $0.center.x < $1.center.x }! }
        try ElectronicsCommands.apply(.connect(pins:pins.map { .init(componentID:$0.componentID,pinID:$0.pinID) },net:d.design.nets[0]),to:&d,expectedRevision:d.revision)
        if bottom { try ElectronicsCommands.apply(.setComponentSide(id:id(101),side:.bottom),to:&d,expectedRevision:d.revision) }
        return d
    }
    func testSolidPlaneConnectsPadsButDisconnectedIslandsNeverShortCircuitAirwires() throws {
        var d = try padDocument(); try apply(.addZone(zone(remove:true)),&d)
        XCTAssertTrue(try ElectronicsPCB.snapshot(d).board.airwires.isEmpty)
        let k = PCBKeepout(id:id(30),outline:rectangle(20,0,2,30),layers:[0],tracks:false,vias:false,pads:false)
        try apply(.addKeepout(k),&d)
        let s = try ElectronicsPCB.snapshot(d)
        XCTAssertEqual(s.board.airwires.count,1) // both islands have a pad, but no path between them
        XCTAssertEqual(s.zones[0].islandCount,2); XCTAssertEqual(s.zones[0].removedIslandCount,0)
        XCTAssertFalse(s.issues.contains { $0.severity == .error })
        try apply(.addTrack(.init(id:id(20),netID:id(1),layer:0,width:0.4,points:[.init(15,10),.init(28,10)])),&d)
        XCTAssertTrue(try ElectronicsPCB.snapshot(d).board.airwires.isEmpty)
    }
    func testRemovalUsesPhysicalPadReachabilityAndThroughViaConnectsLayers() throws {
        var d = try padDocument(bottom:true)
        try apply(.batch([.addZone(zone(remove:true)),.addZone(zone(11,layer:1,remove:true))]),&d)
        XCTAssertEqual(try ElectronicsPCB.snapshot(d).board.airwires.count,1)
        let via = PCBVia(id:id(20),netID:id(1),position:.init(25,15),diameter:1,drill:0.5)
        try apply(.addVia(via),&d)
        let s = try ElectronicsPCB.snapshot(d)
        XCTAssertTrue(s.board.airwires.isEmpty)
        XCTAssertFalse(s.pick(point:via.position,tolerance:0).contains { if case .zone = $0.item { true } else { false } })
        let k = PCBKeepout(id:id(30),outline:rectangle(45,0,1,30),layers:[0,1],tracks:false,vias:false,pads:false)
        try apply(.addKeepout(k),&d)
        let cut = try ElectronicsPCB.snapshot(d)
        XCTAssertTrue(cut.board.airwires.isEmpty)
        XCTAssertEqual(cut.zones.map(\.removedIslandCount),[1,1])
        XCTAssertFalse(cut.pick(point:.init(48,15),tolerance:0).contains { if case .zone = $0.item { true } else { false } })
    }
    func testFormatFiveMigrationAddsNoZonesAndKeepsKeepoutProtection() throws {
        var d = try document(); try apply(.addKeepout(.init(outline:rectangle(20,0,2,30),layers:[0])),&d)
        func strip(_ v: Any) -> Any {
            if let a = v as? [Any] { return a.map(strip) }
            if let o = v as? [String:Any] { return o.filter { $0.key != "zones" }.mapValues(strip) }
            return v
        }
        var json = strip(try JSONSerialization.jsonObject(with:d.encoded())) as! [String:Any]
        json["formatVersion"] = 5
        var migrated = try ElectronicsDocument.decode(JSONSerialization.data(withJSONObject:json))
        XCTAssertEqual(migrated,d)
        XCTAssertTrue(migrated.design.board.copper!.keepouts[0].zones)
        try migrated.undo(expectedRevision:migrated.revision); try migrated.redo(expectedRevision:migrated.revision)
        XCTAssertEqual(migrated.design,d.design)
    }
    func testFillIsDeterministicAcrossObstacleAndOutlineOrder() throws {
        var d = try document()
        let tracks: [PCBTrack] = (0..<8).map { n in .init(id:id(40+n),netID:id(2),layer:0,width:0.4,points:[.init(Double(n)*4+5,5),.init(Double(n)*4+6,25)]) }
        try apply(.batch(tracks.map(PCBCommand.addTrack)+[.addZone(zone())]),&d)
        let a = try ElectronicsPCB.snapshot(d)
        var other = d.design; other.board.copper!.tracks.reverse()
        let b = try ElectronicsPCB.snapshot(design:other,revision:d.revision)
        XCTAssertEqual(a.zones,b.zones)
    }
    func testSnapshotCanBeCancelledBeforeFill() async throws {
        let d = try document()
        let task = Task { () throws -> PCBSnapshot in
            withUnsafeCurrentTask { $0?.cancel() }
            return try ElectronicsPCB.snapshot(d)
        }
        do { _ = try await task.value; XCTFail("Cancelled fill succeeded") } catch { XCTAssertTrue(error is CancellationError) }
    }
    func testClippingAtLargeCoordinatesAndAlmostCoincidentEdgesIsConservative() throws {
        let shift = 50_000.0
        let subject = rectangle(shift,shift,10,10)
        let obstacles = [rectangle(shift+2,shift+2,4,4),rectangle(shift+2.00000001,shift+2,4,4)]
        let cells = try PCBPolygonFill.cells(subject:subject,board:subject,obstacles:obstacles)
        XCTAssertEqual(cells.map(PCBPolygonFill.area).reduce(0,+),84-4e-8,accuracy:1e-7)
        XCTAssertFalse(cells.contains { PCBGeometry.inside(.init(shift+4,shift+4),$0) })
    }
    func testCircularObstacleIsCircumscribedWithinStatedTolerance() throws {
        for radius in [0.01,0.2,1.0,10,100] {
            let polygon = try PCBPolygonFill.expandedConvex([.init()],radius:radius)
            XCTAssertTrue(polygon.allSatisfy { PCBGeometry.distance(.init(),$0) <= radius+0.005+1e-9 })
            for n in 0..<1000 {
                let a = Double(n) * 2 * .pi/1000
                XCTAssertTrue(PCBGeometry.inside(.init(radius*cos(a),radius*sin(a)),polygon))
            }
        }
    }
    func testComplexityFailureIsExplicitAndAtomic() throws {
        var d = try document()
        try apply(.addTrack(.init(id:id(20),netID:id(2),layer:0,width:0.4,points:[.init(5,10),.init(40,10)])),&d)
        try apply(.addNetClass(.init(name:"Fuori scala",netIDs:[id(2)],constraints:.init(clearance:100_000))),&d)
        let before = d
        XCTAssertThrowsError(try apply(.addZone(zone()),&d)) { e in
            XCTAssertTrue((e as? ElectronicsFailure)?.issues.contains { $0.code == "zone_fill_complexity" } == true)
        }
        XCTAssertEqual(d,before)
    }
}
