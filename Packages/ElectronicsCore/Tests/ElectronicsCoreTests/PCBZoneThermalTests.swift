import Foundation
import XCTest
@testable import ElectronicsCore

final class PCBZoneThermalTests: XCTestCase {
    func id(_ n: Int) -> UUID { UUID(uuidString:String(format:"DDDD0000-0000-4000-8000-%012d",n))! }
    func rect(_ x: Double,_ y: Double,_ w: Double,_ h: Double) -> [PCBPoint] {
        [.init(x,y),.init(x+w,y),.init(x+w,y+h),.init(x,y+h)]
    }
    func apply(_ c: PCBCommand,_ d: inout ElectronicsDocument) throws {
        try ElectronicsCommands.apply(.pcb(c),to:&d,expectedRevision:d.revision)
    }
    func document(template: Int = 0, angle: Double = 0, bottom: Bool = false) throws -> ElectronicsDocument {
        var d = try ElectronicsDocument.empty(name:"Termiche")
        for (n,x) in [(1,8.0),(2,40.0)] {
            let c = ElectronicsStarterLibrary.components[template].command(componentID:id(n),reference:"J\(n)",position:.init(x,15))
            try ElectronicsCommands.apply(c,to:&d,expectedRevision:d.revision)
        }
        let pads = try ElectronicsConnectivity.snapshot(d.design).pads
        let pins = [1,2].map { n in pads.filter { $0.componentID == id(n) }.max { $0.center.x < $1.center.x }! }
        try ElectronicsCommands.apply(.connect(pins:pins.map { .init(componentID:$0.componentID,pinID:$0.pinID) },net:.init(id:id(10),name:"GND")),to:&d,expectedRevision:d.revision)
        var design = d.design
        for n in design.board.placements.indices { design.board.placements[n].rotationDegrees = angle; design.board.placements[n].side = bottom ? .bottom : .top }
        return try .init(design:design)
    }
    func zone() -> PCBZone { .init(id:id(20),netID:id(10),layer:0,outline:rect(1,1,48,28),removeIslands:false,connection:.thermal) }
    func testFourRealSpokesGapAndConnectivity() throws {
        var d = try document(), z = zone(); z.minimumSpokes = 4
        try apply(.addZone(z),&d)
        let s = try ElectronicsPCB.snapshot(d)
        XCTAssertEqual(s.zones[0].thermals.map(\.connectedSpokes),[4,4])
        XCTAssertTrue(s.board.airwires.isEmpty)
        XCTAssertFalse(s.issues.contains { $0.severity == .error })
        let p = s.board.pads.first { $0.netID == id(10) }!
        let diagonal = PCBPoint(p.center.x+p.size.x/2+0.1,p.center.y+p.size.y/2+0.1)
        XCTAssertFalse(s.pick(point:diagonal,tolerance:0,layer:0).contains { $0.item == .zone(z.id) })
        let bridge = PCBPoint(p.center.x+p.size.x/2+0.15,p.center.y)
        XCTAssertTrue(s.pick(point:bridge,tolerance:0,layer:0).contains { $0.item == .zone(z.id) })
        z.connection = .solid; try apply(.updateZone(z),&d)
        XCTAssertGreaterThan(try ElectronicsPCB.snapshot(d).zones[0].area,s.zones[0].area)
    }
    func testObstaclesCutSpokesAndDiagnosticsUsePhysicalPadIDs() throws {
        var d = try document(); let z = zone(); try apply(.addZone(z),&d)
        let p = try ElectronicsPCB.snapshot(d).board.pads.first { $0.netID == id(10) }!
        // A thin interruption across only part of the spoke: centreline contact alone is insufficient.
        let k = PCBKeepout(outline:rect(p.center.x+p.size.x/2+0.08,p.center.y+0.04,0.06,0.07),layers:[0],tracks:false,vias:false,pads:false)
        try apply(.addKeepout(k),&d)
        var s = try ElectronicsPCB.snapshot(d)
        XCTAssertEqual(s.zones[0].thermals.first { $0.componentID == p.componentID }?.connectedSpokes,3)
        var design = d.design; design.board.copper!.zones[0].minimumSpokes = 4
        s = try ElectronicsPCB.snapshot(design:design,revision:0)
        let issue = try XCTUnwrap(s.issues.first { $0.code == "pcb_thermal_starved" })
        XCTAssertTrue(issue.subjectIDs?.contains(p.componentID) == true)
        XCTAssertTrue(issue.subjectIDs?.contains(p.padID) == true)
        XCTAssertTrue(issue.subjectIDs?.contains(z.id) == true)
        XCTAssertEqual(issue.position,p.center)
    }
    func testRotatedBottomPadsAndThroughHoleOnlyMode() throws {
        var d = try document(angle:37,bottom:true), z = zone(); z.layer = 1; z.minimumSpokes = 4; z.thermalAngleDegrees = 17
        try apply(.addZone(z),&d)
        let s = try ElectronicsPCB.snapshot(d)
        XCTAssertEqual(s.zones[0].thermals.map(\.connectedSpokes),[4,4])
        XCTAssertTrue(s.board.airwires.isEmpty)
        z.connection = .thermalThroughHole; try apply(.updateZone(z),&d)
        XCTAssertTrue(try ElectronicsPCB.snapshot(d).zones[0].thermals.isEmpty)
    }
    func testPlatedPadsGetThermalsButViaStaysSolidAndHolesStayEmpty() throws {
        var d = try document(template:2), z = zone(); z.connection = .thermalThroughHole
        try apply(.addVia(.init(id:id(30),netID:id(10),position:.init(25,15),diameter:1,drill:0.4)),&d)
        try apply(.addZone(z),&d)
        let s = try ElectronicsPCB.snapshot(d)
        XCTAssertEqual(s.zones[0].thermals.count,2)
        XCTAssertTrue(s.zones[0].thermals.allSatisfy { $0.connectedSpokes == 4 })
        for p in s.board.pads where p.drillDiameter != nil {
            XCTAssertFalse(s.pick(point:p.center,tolerance:0).contains { $0.item == .zone(z.id) })
        }
        XCTAssertFalse(s.pick(point:.init(25,15),tolerance:0).contains { $0.item == .zone(z.id) })
        XCTAssertTrue(s.pick(point:.init(25.4,15.4),tolerance:0).contains { $0.item == .zone(z.id) })
    }
    func testIsolatedPadsDoNotEraseAirwires() throws {
        var d = try document(), z = zone(); z.connection = .none
        try apply(.addZone(z),&d)
        let s = try ElectronicsPCB.snapshot(d)
        XCTAssertEqual(s.board.airwires.count,1)
        XCTAssertTrue(s.zones[0].thermals.isEmpty)
        XCTAssertTrue(s.issues.contains { $0.code == "pcb_floating_copper" })
    }
    func testIsolationGapAlsoProtectsPadJustOutsideZoneOutline() throws {
        var d = try document(), z = zone(); z.connection = .none
        let p = try ElectronicsPCB.snapshot(d).board.pads.first { $0.netID == id(10) }!
        let edge = p.center.x+p.size.x/2
        z.outline = rect(edge+0.05,1,1,28)
        try apply(.addZone(z),&d)
        let s = try ElectronicsPCB.snapshot(d)
        XCTAssertFalse(s.pick(point:.init(edge+0.15,p.center.y),tolerance:0).contains { $0.item == .zone(z.id) })
        XCTAssertTrue(s.pick(point:.init(edge+0.5,p.center.y),tolerance:0).contains { $0.item == .zone(z.id) })
    }
    func dumbbell(neck: Double, length: Double = 20) -> [PCBPoint] {
        let a = 25-length/2, b = 25+length/2, y0 = 15-neck/2, y1 = 15+neck/2
        return [.init(1,1),.init(a,1),.init(a,y0),.init(b,y0),.init(b,1),.init(49,1),.init(49,29),.init(b,29),.init(b,y1),.init(a,y1),.init(a,29),.init(1,29)]
    }
    func widthSnapshot(neck: Double, length: Double = 20, width: Double = 1) throws -> PCBSnapshot {
        var d = try ElectronicsDocument.empty(name:"Colli").design
        d.nets = [.init(id:id(10),name:"GND")]
        var z = zone(); z.connection = .solid; z.outline = dumbbell(neck:neck,length:length); z.minimumWidth = width
        d.board.copper = .init(zones:[z])
        return try ElectronicsPCB.snapshot(design:d,revision:0)
    }
    func testMinimumWidthRemovesLongThinBridgeButKeepsWideOne() throws {
        let raw = try widthSnapshot(neck:0.4,width:0), narrow = try widthSnapshot(neck:0.4), wide = try widthSnapshot(neck:2)
        XCTAssertEqual(raw.zones[0].islandCount,1)
        XCTAssertEqual(narrow.zones[0].islandCount,2)
        XCTAssertGreaterThan(narrow.zones[0].removedNarrowArea,7)
        XCTAssertFalse(narrow.pick(point:.init(25,15),tolerance:0).contains { $0.item == .zone(id(20)) })
        XCTAssertEqual(wide.zones[0].islandCount,1)
        XCTAssertFalse(wide.issues.contains { $0.code == "pcb_zone_neck" })
    }
    func testShortPinchIsReportedIfDilationReconnectsIt() throws {
        let s = try widthSnapshot(neck:0.8,length:0.02)
        if s.zones[0].islandCount == 1 {
            XCTAssertTrue(s.issues.contains { $0.code == "pcb_zone_neck" && $0.subjectIDs == [id(20)] })
        } else { XCTAssertEqual(s.zones[0].islandCount,2) }
    }
    func testMinimumWidthDoesNotErodeInternalCellSeamsOrBreakThermals() throws {
        var d = try document(), z = zone(); z.minimumWidth = 0.2
        try apply(.addZone(z),&d)
        let s = try ElectronicsPCB.snapshot(d)
        XCTAssertTrue(s.board.airwires.isEmpty)
        XCTAssertEqual(s.zones[0].thermals.map(\.connectedSpokes),[4,4])
        XCTAssertFalse(s.issues.contains { $0.severity == .error })
    }
    func testInvalidSettingsAreAtomicAndWidthViolationsAreReported() throws {
        var d = try document(); let original = d
        for mutate: (inout PCBZone) -> Void in [{ $0.thermalGap = 0 },{ $0.thermalSpokeWidth = .nan },{ $0.minimumWidth = -1 },{ $0.minimumSpokes = 5 },{ $0.thermalAngleDegrees = .infinity }] {
            var z = zone(); mutate(&z)
            XCTAssertThrowsError(try apply(.addZone(z),&d)); XCTAssertEqual(d,original)
        }
        var z = zone(); z.thermalSpokeWidth = 0.1
        XCTAssertThrowsError(try apply(.addZone(z),&d)) { e in
            XCTAssertTrue((e as? ElectronicsFailure)?.issues.contains { $0.code == "pcb_thermal_width" } == true)
        }
        XCTAssertEqual(d,original)
    }
    func testRotatedNarrowBridgeAndCancelledWidthFilter() async throws {
        var design = try ElectronicsDocument.empty(name:"Collo ruotato",outline:rect(-20,-20,100,100)).design
        design.nets = [.init(id:id(10),name:"GND")]
        let angle = 0.371
        func rotated(_ p: PCBPoint) -> PCBPoint { .init(p.x*cos(angle)-p.y*sin(angle),p.x*sin(angle)+p.y*cos(angle)) }
        var z = zone(); z.connection = .solid; z.minimumWidth = 1
        z.outline = dumbbell(neck:0.4).map(rotated)
        design.board.copper = .init(zones:[z])
        let s = try ElectronicsPCB.snapshot(design:design,revision:0)
        XCTAssertEqual(s.zones[0].islandCount,2)
        XCTAssertFalse(s.pick(point:rotated(.init(25,15)),tolerance:0).contains { $0.item == .zone(z.id) })
        let immutableZone = z, board = design.board.outline
        let task = Task.detached {
            withUnsafeCurrentTask { $0?.cancel() }
            return try PCBZoneWidth.filter(zone:immutableZone,board:board,obstacles:[],raw:[immutableZone.outline])
        }
        do { _ = try await task.value; XCTFail("Cancelled minimum-width fill succeeded") }
        catch { XCTAssertTrue(error is CancellationError) }
    }
    func testPreviewPersistenceAndFormatSixMigrationKeepWholeHistory() throws {
        var d = try document(), z = zone(); z.connection = .solid
        try apply(.addZone(z),&d)
        func legacy(_ value: Any) -> Any {
            if let a = value as? [Any] { return a.map(legacy) }
            if let o = value as? [String:Any] { return o.filter { !["connection","thermalGap","thermalSpokeWidth","thermalAngleDegrees","minimumSpokes","minimumWidth"].contains($0.key) }.mapValues(legacy) }
            return value
        }
        var json = legacy(try JSONSerialization.jsonObject(with:d.encoded())) as! [String:Any]; json["formatVersion"] = 6
        var migrated = try ElectronicsDocument.decode(JSONSerialization.data(withJSONObject:json))
        XCTAssertEqual(migrated,d); XCTAssertEqual(migrated.formatVersion,8)
        z.connection = .thermal; z.minimumWidth = 0.2
        let before = migrated
        let p = try ElectronicsCommands.preview(.pcb(.updateZone(z)),document:migrated,expectedRevision:migrated.revision)
        XCTAssertTrue(p.canApply); XCTAssertEqual(migrated,before)
        try apply(.updateZone(z),&migrated)
        XCTAssertEqual(try ElectronicsPCB.snapshot(migrated).zones,try p.pcbSnapshot().zones)
        migrated = try ElectronicsDocument.decode(migrated.encoded())
        try migrated.undo(expectedRevision:migrated.revision); XCTAssertEqual(migrated.design,before.design)
        try migrated.redo(expectedRevision:migrated.revision); XCTAssertEqual(migrated.design.board.copper?.zones[0],z)
        XCTAssertThrowsError(try ElectronicsCommands.apply(.pcb(.updateZone(z)),to:&migrated,expectedRevision:before.revision))
    }
}
