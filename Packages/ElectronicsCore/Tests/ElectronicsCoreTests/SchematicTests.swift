import XCTest
@testable import ElectronicsCore

final class SchematicTests: XCTestCase {
    let starter = ElectronicsStarterLibrary.components[0]
    func apply(_ c: ElectronicsCommand, _ d: inout ElectronicsDocument) throws {
        try ElectronicsCommands.apply(c,to: &d,expectedRevision: d.revision)
    }
    func edit(_ c: SchematicCommand, _ d: inout ElectronicsDocument) throws { try apply(.schematic(c),&d) }
    func fixture(_ count: Int = 2) throws -> (ElectronicsDocument, UUID, [PinReference]) {
        var d = try ElectronicsDocument.empty()
        var pins: [PinReference] = [], symbols: [SchematicSymbol] = []
        for n in 0..<count {
            let id = UUID()
            try apply(starter.command(componentID: id,reference: "R\(n+1)",position: .init(Double(n)*5,10)),&d)
            pins.append(.init(componentID: id,pinID: starter.library.symbols[0].pins[0].id))
            symbols.append(.init(componentID: id,position: .init(Double(n)*20+10,10)))
        }
        let sheet = SchematicSheet(name: "Principale",symbols: symbols)
        try edit(.addSheet(sheet),&d)
        return (d,sheet.id,pins)
    }
    func net(_ pin: PinReference, _ d: ElectronicsDocument) -> UUID? { d.design.connections.first { $0.pin == pin }?.netID }

    func testWirePreviewUsesSameIDsAndUpdatesPCBInOnePersistentStep() throws {
        var (d,s,p) = try fixture(); let before = d
        let wire = SchematicWire(start: .pin(p[0]),end: .pin(p[1]),bends: [.init(20,10)])
        let command = ElectronicsCommand.schematic(.addWire(sheetID: s,wire: wire))
        let preview = try ElectronicsCommands.preview(command,document: d,expectedRevision: d.revision)
        let again = try ElectronicsCommands.preview(command,document: d,expectedRevision: d.revision)
        XCTAssertEqual(d,before); XCTAssertEqual(preview.design,again.design)
        XCTAssertEqual(preview.board.airwires.count,1)
        let drawing = try preview.schematicSnapshot(sheetID: s)
        XCTAssertTrue(drawing.primitives.contains { $0.owner.id == wire.id && $0.owner.netID != nil })
        try apply(command,&d)
        XCTAssertEqual(d.design,preview.design); XCTAssertEqual(d.past.count,before.past.count+1)
        XCTAssertEqual(net(p[0],d),net(p[1],d)); XCTAssertNotNil(net(p[0],d))
        let reopened = try ElectronicsDocument.decode(d.encoded()); XCTAssertEqual(d,reopened)
        try d.undo(expectedRevision: d.revision); XCTAssertEqual(d.design,before.design)
        try d.redo(expectedRevision: d.revision); XCTAssertEqual(d.design,reopened.design)
    }

    func testBridgeDeletionSplitsAutomaticNetsAndUndoRestores() throws {
        var (d,s,p) = try fixture(4)
        let left = SchematicWire(start: .pin(p[0]),end: .pin(p[1]))
        let right = SchematicWire(start: .pin(p[2]),end: .pin(p[3]))
        let bridge = SchematicWire(start: .pin(p[1]),end: .pin(p[2]))
        try edit(.batch([.addWire(sheetID:s,wire:left),.addWire(sheetID:s,wire:right)]),&d)
        XCTAssertNotEqual(net(p[0],d),net(p[2],d)); XCTAssertEqual(d.design.nets.count,2)
        try edit(.addWire(sheetID:s,wire:bridge),&d)
        XCTAssertEqual(net(p[0],d),net(p[3],d)); XCTAssertEqual(d.design.nets.count,1)
        let joined = d.design
        try edit(.removeWire(bridge.id),&d)
        XCTAssertEqual(net(p[0],d),net(p[1],d)); XCTAssertEqual(net(p[2],d),net(p[3],d))
        XCTAssertNotEqual(net(p[0],d),net(p[2],d)); XCTAssertEqual(d.design.nets.count,2)
        XCTAssertTrue(ElectronicsValidation.integrity(d.design).isEmpty)
        let split = d.design
        try d.undo(expectedRevision:d.revision); XCTAssertEqual(d.design,joined)
        try d.redo(expectedRevision:d.revision); XCTAssertEqual(d.design,split)
    }

    func testGeometricCrossingOnlyConnectsAfterExplicitSharedJunction() throws {
        var d = try ElectronicsDocument.empty()
        let j = [PCBPoint(-10,0),.init(10,0),.init(0,-10),.init(0,10)].map { SchematicJunction(position:$0) }
        let a = SchematicWire(start:.junction(j[0].id),end:.junction(j[1].id))
        let b = SchematicWire(start:.junction(j[2].id),end:.junction(j[3].id))
        let sheet = SchematicSheet(name:"Croce",junctions:j,wires:[a,b])
        try edit(.addSheet(sheet),&d); XCTAssertEqual(d.design.nets.count,2)
        let center = SchematicJunction(position:.init())
        let before = d.design
        try edit(.batch([.splitWire(id:a.id,junction:center,newWireID:UUID()),.splitWire(id:b.id,junction:center,newWireID:UUID())]),&d)
        XCTAssertEqual(d.design.nets.count,1); XCTAssertEqual(d.design.schematic!.sheets[0].wires.count,4)
        XCTAssertEqual(d.design.schematic!.sheets[0].junctions.count,5)
        try d.undo(expectedRevision:d.revision); XCTAssertEqual(d.design,before)
        try d.redo(expectedRevision:d.revision)
        try edit(.removeJunction(center.id),&d)
        XCTAssertEqual(d.design.nets.count,0); XCTAssertTrue(d.design.schematic!.sheets[0].wires.isEmpty)
    }

    func testSplitFirstSegmentAtBendAndInvalidSplitAreAtomic() throws {
        var (d,s,p) = try fixture()
        let w = SchematicWire(start:.pin(p[0]),end:.pin(p[1]),bends:[.init(20,10),.init(20,15)])
        try edit(.addWire(sheetID:s,wire:w),&d)
        let before=d
        XCTAssertThrowsError(try edit(.splitWire(id:w.id,junction:.init(position:.init(90,90)),newWireID:UUID()),&d))
        XCTAssertEqual(d,before)
        try edit(.splitWire(id:w.id,junction:.init(position:.init(15,10)),newWireID:UUID()),&d)
        XCTAssertEqual(d.design.schematic!.sheets[0].wires.count,2)
        XCTAssertEqual(net(p[0],d),net(p[1],d))
        XCTAssertTrue(ElectronicsValidation.integrity(d.design).isEmpty)
    }

    func testMovingAndRotatingSymbolMovesWireEndsButNotPCB() throws {
        var (d,s,p) = try fixture()
        let w = SchematicWire(start:.pin(p[0]),end:.pin(p[1]))
        try edit(.addWire(sheetID:s,wire:w),&d)
        let placements=d.design.board.placements, netID=net(p[0],d)
        try edit(.batch([.moveSymbol(componentID:p[0].componentID,to:.init(5,6)),.rotateSymbol(componentID:p[0].componentID,by:90),.mirrorSymbol(p[0].componentID)]),&d)
        let snap=try ElectronicsSchematic.snapshot(d,sheetID:s)
        let pin=try XCTUnwrap(snap.pins.first { $0.reference == p[0] })
        XCTAssertEqual(pin.position.x,5,accuracy:1e-9); XCTAssertEqual(pin.position.y,9.81,accuracy:1e-9)
        XCTAssertEqual(d.design.board.placements,placements); XCTAssertEqual(net(p[0],d),netID)
        let wireShape=try XCTUnwrap(snap.primitives.first { $0.owner.id == w.id })
        if case .polyline(let points,_) = wireShape.shape { XCTAssertEqual(points.first,pin.position) } else { XCTFail() }
    }

    func testLabelsConnectAcrossSheetsAndConflictingNamesAreRefused() throws {
        var (d,s,p) = try fixture()
        try edit(.removeSymbol(p[1].componentID),&d)
        let child=SchematicSheet(name:"Alimentazione",parentID:s,symbols:[.init(componentID:p[1].componentID,position:.init(50,10))])
        try edit(.addSheet(child),&d)
        let ground=CircuitNet(name:"GND")
        let a=SchematicLabel(terminal:.pin(p[0]),netID:ground.id,kind:.power)
        let b=SchematicLabel(terminal:.pin(p[1]),netID:ground.id,kind:.power)
        try edit(.batch([.addLabel(sheetID:s,label:a,net:ground),.addLabel(sheetID:child.id,label:b,net:ground)]),&d)
        XCTAssertEqual(net(p[0],d),ground.id); XCTAssertEqual(net(p[1],d),ground.id)
        XCTAssertEqual(try ElectronicsConnectivity.snapshot(d.design).airwires.count,1)
        let before=d, other=CircuitNet(name:"VCC")
        XCTAssertThrowsError(try edit(.addLabel(sheetID:s,label:.init(terminal:.pin(p[0]),netID:other.id),net:other),&d))
        XCTAssertEqual(d,before)
        try edit(.removeLabel(a.id),&d); XCTAssertNil(net(p[0],d)); XCTAssertEqual(net(p[1],d),ground.id)
    }

    func testDirectConnectionsSurviveWireDeletionAndNCRequiresExplicitRemoval() throws {
        var (d,s,p) = try fixture()
        let n=CircuitNet(name:"SIGNAL")
        try apply(.connect(pins:p,net:n),&d)
        let w=SchematicWire(start:.pin(p[0]),end:.pin(p[1]))
        try edit(.addWire(sheetID:s,wire:w),&d)
        let before=d
        XCTAssertThrowsError(try apply(.disconnect([p[0]]),&d)); XCTAssertEqual(d,before)
        XCTAssertThrowsError(try apply(.removeNet(n.id),&d)); XCTAssertEqual(d,before)
        try edit(.removeWire(w.id),&d); XCTAssertEqual(net(p[0],d),n.id)
        try apply(.disconnect(p),&d); XCTAssertTrue(d.design.connections.isEmpty)
        try apply(.markNoConnect([p[0]]),&d)
        let nc=d
        XCTAssertThrowsError(try edit(.addWire(sheetID:s,wire:w),&d)); XCTAssertEqual(d,nc)
        let snap=try ElectronicsSchematic.snapshot(d,sheetID:s)
        XCTAssertTrue(snap.primitives.contains { $0.style == .noConnect })
        try apply(.disconnect([p[0]]),&d); try edit(.addWire(sheetID:s,wire:w),&d)
        XCTAssertEqual(net(p[0],d),net(p[1],d))
    }

    func testOldLogicalNetlistIsPreservedWhenEnablingSchematic() throws {
        var d=try ElectronicsDocument.empty()
        let id=UUID(); try apply(starter.command(componentID:id,reference:"R1",position:.init()),&d)
        let pin=PinReference(componentID:id,pinID:starter.library.symbols[0].pins[0].id),n=CircuitNet(name:"OLD")
        try apply(.connect(pins:[pin],net:n),&d)
        let before=d.design.connections
        try edit(.addSheet(.init(name:"Schema")),&d)
        XCTAssertEqual(d.design.schematic?.directConnections,before)
        XCTAssertEqual(d.design.connections,before)
        XCTAssertTrue(ElectronicsValidation.electrical(d.design).contains { $0.code == "symbol_not_placed" })
    }

    func testRemovalCleansDrawingWhileKeepingOtherComponentsAndUndo() throws {
        var (d,s,p) = try fixture(); let w=SchematicWire(start:.pin(p[0]),end:.pin(p[1]))
        try edit(.addWire(sheetID:s,wire:w),&d); let before=d.design
        try apply(.removeComponent(p[0].componentID),&d)
        XCTAssertEqual(d.design.components.count,1); XCTAssertEqual(d.design.schematic?.sheets[0].symbols.count,1)
        XCTAssertTrue(d.design.connections.isEmpty); XCTAssertTrue(d.design.schematic!.sheets[0].wires.isEmpty)
        try d.undo(expectedRevision:d.revision); XCTAssertEqual(d.design,before)
        try edit(.removeSymbol(p[0].componentID),&d)
        XCTAssertEqual(d.design.components.count,2); XCTAssertEqual(d.design.board.placements.count,2)
        XCTAssertTrue(d.design.connections.isEmpty)
    }

    func testSheetHierarchyAndMissingEntitiesAreTransactional() throws {
        var (d,s,p)=try fixture(); let before=d
        let child=SchematicSheet(name:"Figlio",parentID:s)
        try edit(.addSheet(child),&d); let withChild=d
        XCTAssertThrowsError(try edit(.removeSheet(s),&d)); XCTAssertEqual(d,withChild)
        try edit(.removeSheet(child.id),&d); XCTAssertEqual(d.design,before.design)
        let bad=SchematicSheet(name:"Ciclo",parentID:UUID())
        let stable=d
        XCTAssertThrowsError(try edit(.addSheet(bad),&d)); XCTAssertEqual(d,stable)
        XCTAssertThrowsError(try edit(.placeSymbol(sheetID:s,symbol:.init(componentID:p[0].componentID,position:.init())),&d)); XCTAssertEqual(d,stable)
        XCTAssertThrowsError(try edit(.moveSymbol(componentID:UUID(),to:.init()),&d)); XCTAssertEqual(d,stable)
        XCTAssertThrowsError(try edit(.addWire(sheetID:s,wire:.init(start:.pin(p[0]),end:.junction(UUID()))),&d)); XCTAssertEqual(d,stable)
        XCTAssertThrowsError(try edit(.batch([.renameSheet(id:s,name:"Changed"),.moveSymbol(componentID:UUID(),to:.init())]),&d)); XCTAssertEqual(d,stable)
    }

    func testSnapshotPickSnapAndFilterAreDeterministic() throws {
        var (d,s,p)=try fixture()
        let w=SchematicWire(start:.pin(p[0]),end:.pin(p[1]))
        try edit(.addWire(sheetID:s,wire:w),&d)
        let snapshot=try ElectronicsSchematic.snapshot(d,sheetID:s)
        let point=try XCTUnwrap(snapshot.pins.first { $0.reference == p[0] }).position
        let hits=snapshot.pick(point,tolerance:0.3)
        XCTAssertEqual(hits.first?.object.kind,.pin); XCTAssertEqual(hits.first?.object.componentID,p[0].componentID)
        XCTAssertEqual(snapshot.pick(point,tolerance:0.3),hits)
        XCTAssertTrue(snapshot.pick(point,tolerance:0.3,filter:[.wire]).allSatisfy { $0.object.kind == .wire })
        let snap=snapshot.snapTargets(near:point,radius:1,grid:1.27)
        XCTAssertEqual(snap.first?.kind,.pin); XCTAssertEqual(snap.first?.point,point)
        XCTAssertEqual(snapshot.snapTargets(near:.init(99.9,100.1),radius:1,grid:1).first?.kind,.grid)
        XCTAssertTrue(snapshot.pick(.init(.nan,0),tolerance:1).isEmpty)
        XCTAssertTrue(snapshot.snapTargets(near:point,radius:-1).isEmpty)
    }

    func testStalePreviewAndCorruptProjectionAreRejected() throws {
        var (d,s,p)=try fixture()
        let wire=SchematicWire(start:.pin(p[0]),end:.pin(p[1]))
        let c=ElectronicsCommand.schematic(.addWire(sheetID:s,wire:wire))
        let preview=try ElectronicsCommands.preview(c,document:d,expectedRevision:d.revision)
        try edit(.renameSheet(id:s,name:"Nuovo nome"),&d); let before=d
        XCTAssertThrowsError(try ElectronicsCommands.apply(c,to:&d,expectedRevision:preview.baseRevision)); XCTAssertEqual(d,before)
        try apply(c,&d)
        var json=try XCTUnwrap(JSONSerialization.jsonObject(with:d.encoded()) as? [String:Any])
        var design=json["design"] as! [String:Any]; design["connections"]=[]; json["design"]=design
        XCTAssertThrowsError(try ElectronicsDocument.decode(JSONSerialization.data(withJSONObject:json)))
        var bad=d.design; bad.schematic!.sheets[0].wires[0].end = .junction(UUID())
        XCTAssertThrowsError(try ElectronicsDocument(design:bad))
    }

    func testCommandsEncodeAndReplayWithStableTopology() throws {
        var (d,s,p)=try fixture(); var copy=d
        let command=ElectronicsCommand.schematic(.addWire(sheetID:s,wire:.init(start:.pin(p[0]),end:.pin(p[1]))))
        let decoded=try JSONDecoder().decode(ElectronicsCommand.self,from:JSONEncoder().encode(command))
        try apply(command,&d); try apply(decoded,&copy)
        XCTAssertEqual(d,copy)
        XCTAssertEqual(d.formatVersion,4)
        let roundtrip=try ElectronicsDocument.decode(d.encoded()); XCTAssertEqual(roundtrip,d)
    }

    func testERCPositionsAndPowerLabelDoesNotInventADriver() throws {
        var (d,s,p)=try fixture()
        // New revision, because existing library snapshots are immutable across history.
        var symbol=starter.library.symbols[0]; symbol.key.revision=2; symbol.pins[0].electricalType = .powerInput
        var device=starter.library.devices[0]; device.key.revision=2; device.symbol=symbol.key
        try d.edit(title:"Libreria per prova ERC",expectedRevision:d.revision) { design in
            design.library.symbols.append(symbol); design.library.devices.append(device)
            design.components[0].device=device.key
        }
        let n=CircuitNet(name:"VCC")
        try edit(.addLabel(sheetID:s,label:.init(terminal:.pin(p[0]),netID:n.id,kind:.power),net:n),&d)
        let issues=ElectronicsValidation.electrical(d.design)
        let issue=try XCTUnwrap(issues.first { $0.code == "undriven_power" })
        XCTAssertEqual(issue.subjectIDs?.first,p[0].componentID); XCTAssertNotNil(issue.position)
        XCTAssertTrue(issues.contains { $0.code == "single_pin_net" })
    }

    func testSymbolNamesUsesTopLevelParserAndRejectsAmbiguity() throws {
        let data=Data(#"(kicad_symbol_lib (symbol "Z" (symbol "Z_0_1")) (symbol "中文" (property "x" "(symbol fake)")) (symbol "A"))"#.utf8)
        XCTAssertEqual(try KiCadLibraryImporter.symbolNames(data),["A","Z","中文"])
        XCTAssertThrowsError(try KiCadLibraryImporter.symbolNames(Data(#"(kicad_symbol_lib (symbol "A") (symbol "A"))"#.utf8)))
        XCTAssertThrowsError(try KiCadLibraryImporter.symbolNames(Data(#"(kicad_symbol_lib (symbol "unterminated))"#.utf8)))
        XCTAssertThrowsError(try KiCadLibraryImporter.symbolNames(Data("(footprint R)".utf8)))
    }
    func testCreateOnSchemaIsOneUndoAndPCBPlacementIsExplicit() throws {
        var d = try ElectronicsDocument.empty()
        let sheet = SchematicSheet(name: "Principale")
        try edit(.addSheet(sheet), &d)
        let before = d, id = UUID()
        let command = starter.schematicCommand(componentID: id, reference: "R1", sheetID: sheet.id, position: .init(10,20))
        let preview = try ElectronicsCommands.preview(command, document: d, expectedRevision: d.revision)
        XCTAssertEqual(preview.board.unplacedComponents, [id]); XCTAssertTrue(preview.board.pads.isEmpty)
        try apply(command, &d)
        XCTAssertEqual(d.past.count, before.past.count + 1); XCTAssertEqual(d.design, preview.design)
        try d.undo(expectedRevision: d.revision); XCTAssertEqual(d.design, before.design)
        try d.redo(expectedRevision: d.revision)
        let symbols = d.design.schematic!.sheets[0].symbols
        try apply(.placeComponent(.init(componentID: id, position: .init(50,60), rotationDegrees: 90)), &d)
        XCTAssertEqual(d.design.schematic!.sheets[0].symbols, symbols)
        XCTAssertTrue(try ElectronicsConnectivity.snapshot(d.design).unplacedComponents.isEmpty)
    }

    func testNamedAutomaticNetsCannotBeSilentlyMerged() throws {
        var (d,s,p) = try fixture(4)
        try edit(.batch([
            .addWire(sheetID:s,wire:.init(start:.pin(p[0]),end:.pin(p[1]))),
            .addWire(sheetID:s,wire:.init(start:.pin(p[2]),end:.pin(p[3])))
        ]), &d)
        let a = try XCTUnwrap(net(p[0],d)), b = try XCTUnwrap(net(p[2],d))
        try apply(.renameNet(id:a,name:"GND"), &d)
        try apply(.renameNet(id:b,name:"VCC"), &d)
        let before = d
        XCTAssertThrowsError(try edit(.addWire(sheetID:s,wire:.init(start:.pin(p[1]),end:.pin(p[2]))), &d))
        XCTAssertEqual(d,before)
        XCTAssertTrue(ElectronicsValidation.integrity(d.design).isEmpty)
        XCTAssertEqual(try ElectronicsDocument.decode(d.encoded()), d)
    }

    func testNumericalAndDuplicateDrawingErrorsDoNotCorruptHistory() throws {
        var (d,s,p) = try fixture()
        let before = d
        for point in [PCBPoint(.infinity,0), .init(0,.nan), .init(100001,0)] {
            XCTAssertThrowsError(try edit(.moveSymbol(componentID:p[0].componentID,to:point), &d))
            XCTAssertEqual(d,before)
        }
        XCTAssertThrowsError(try edit(.rotateSymbol(componentID:p[0].componentID,by:.nan), &d))
        XCTAssertEqual(d,before)
        let j = SchematicJunction(position:.init(20,20))
        XCTAssertThrowsError(try edit(.batch([.addJunction(sheetID:s,junction:j),.addJunction(sheetID:s,junction:j)]), &d))
        XCTAssertEqual(d,before)
        var cyclic = d.design
        cyclic.schematic!.sheets[0].parentID = s
        XCTAssertThrowsError(try ElectronicsDocument(design:cyclic))
    }

}
