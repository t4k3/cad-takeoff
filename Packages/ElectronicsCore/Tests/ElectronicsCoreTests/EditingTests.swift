import Foundation
import XCTest
@testable import ElectronicsCore

final class EditingTests: XCTestCase {
    let a = UUID(uuidString: "EEEE0000-0000-0000-0000-000000000001")!
    let b = UUID(uuidString: "EEEE0000-0000-0000-0000-000000000002")!
    var resistor: ElectronicsStarterComponent { ElectronicsStarterLibrary.components[0] }
    func apply(_ command: ElectronicsCommand, to doc: inout ElectronicsDocument) throws {
        try ElectronicsCommands.apply(command, to: &doc, expectedRevision: doc.revision)
    }
    func pair() throws -> ElectronicsDocument {
        var doc = try ElectronicsDocument.empty()
        try apply(resistor.command(componentID: a, reference: "R1", position: .init(10,10)), to: &doc)
        try apply(resistor.command(componentID: b, reference: "R2", position: .init(30,10)), to: &doc)
        return doc
    }
    func pin(_ id: UUID, _ document: ElectronicsDocument, index: Int = 0) throws -> PinReference {
        try ElectronicsCommands.pins(of: id, in: document.design)[index].reference
    }
    func failure(_ code: String, _ body: () throws -> Void, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try body(), file: file, line: line) { error in
            XCTAssertTrue((error as? ElectronicsFailure)?.issues.contains { $0.code == code } == true,
                          "Expected \(code), got \(error)", file: file, line: line)
        }
    }

    func testEmptyDocumentHasNoDemoDataAndValidDefaultBoard() throws {
        let doc = try ElectronicsDocument.empty()
        XCTAssertTrue(doc.design.components.isEmpty); XCTAssertTrue(doc.design.library.devices.isEmpty)
        XCTAssertTrue(doc.design.nets.isEmpty); XCTAssertTrue(doc.past.isEmpty)
        XCTAssertEqual(doc.design.board.outline, [.init(0,0), .init(50,0), .init(50,30), .init(0,30)])
        failure("invalid_outline") { _ = try ElectronicsDocument.empty(outline: [.init(0,0)]) }
    }

    func testTemplatesAreRepeatableQualifiedAsGenericAndHaveCompleteMappings() throws {
        for template in ElectronicsStarterLibrary.components {
            try ElectronicsValidation.requireLibrary(template.library)
            let device = try XCTUnwrap(template.library.devices.first)
            XCTAssertNil(device.jlc)
            XCTAssertEqual(device.pinMap.count, 2)
            XCTAssertEqual(template.library.footprints[0].properties?["qualification"], "generic-unverified")
            XCTAssertEqual(template.library, ElectronicsStarterLibrary.components.first { $0.id == template.id }?.library)
            var doc = try ElectronicsDocument.empty()
            try apply(template.command(reference: template.referencePrefix + "1", position: .init(5,5)), to: &doc)
            XCTAssertEqual(doc.design.components[0].assembly, .manual)
            XCTAssertEqual(ElectronicsCommands.genericIssues(doc.design).first?.subjectIDs, [doc.design.components[0].id])
        }
    }

    func testInsertPreviewAndConfirmationShareIDsAndOneUndoIncludingLibrary() throws {
        var doc = try ElectronicsDocument.empty(); let original = doc
        let command = resistor.command(componentID: a, reference: "R1", position: .init(10,10))
        let preview = try ElectronicsCommands.preview(command, document: doc, expectedRevision: 0)
        XCTAssertEqual(doc, original); XCTAssertEqual(preview.board.pads.count, 2)
        XCTAssertTrue(preview.issues.contains { $0.code == "generic_component" })
        let disconnected = preview.issues.filter { $0.code == "unconnected_pin" }
        XCTAssertEqual(disconnected.count, 2)
        XCTAssertTrue(disconnected.allSatisfy { $0.subjectIDs?.first == a && $0.subjectIDs?.count == 2 })
        try ElectronicsCommands.apply(command, to: &doc, expectedRevision: preview.baseRevision)
        XCTAssertEqual(doc.design, preview.design); XCTAssertEqual(doc.past.count, 1)
        try doc.undo(expectedRevision: doc.revision)
        XCTAssertEqual(doc.design, original.design)
        try doc.redo(expectedRevision: doc.revision)
        XCTAssertEqual(doc.design.components[0].id, a)
        XCTAssertEqual(doc.design.library, preview.design.library)
    }

    func testFromEmptyThroughConnectionsBoardEditSaveReopenAndUndo() throws {
        var doc = try pair()
        let pins = try [pin(a, doc), pin(b, doc)]
        let net = CircuitNet(name: "SIGNAL")
        let command = ElectronicsCommand.connect(pins: pins, net: net)
        let preview = try ElectronicsCommands.preview(command, document: doc, expectedRevision: doc.revision)
        XCTAssertEqual(preview.board.airwires.count, 1)
        XCTAssertEqual(preview.board.airwires[0].netID, net.id)
        XCTAssertEqual(doc.design.connections.count, 0)
        try apply(command, to: &doc)
        XCTAssertEqual(doc.design, preview.design)
        XCTAssertEqual(doc.past.count, 3) // includes the creation of the net and both connections
        let connected = doc.design
        try apply(.setBoard(outline: [.init(0,0), .init(80,0), .init(80,40), .init(0,40)], thickness: 2, assemblyOrigin: .init(1,2)), to: &doc)
        let data = try doc.encoded()
        var reopened = try ElectronicsDocument.decode(data)
        XCTAssertEqual(reopened, doc)
        try reopened.undo(expectedRevision: reopened.revision)
        XCTAssertEqual(reopened.design, connected)
        try reopened.undo(expectedRevision: reopened.revision)
        XCTAssertTrue(reopened.design.connections.isEmpty); XCTAssertTrue(reopened.design.nets.isEmpty)
        try reopened.redo(expectedRevision: reopened.revision)
        XCTAssertEqual(try ElectronicsConnectivity.snapshot(reopened.design).airwires.count, 1)
    }

    func testRevisionCheckedAgainAtConfirmationAndFailureLeavesEverythingUntouched() throws {
        var doc = try pair()
        let command = ElectronicsCommand.moveComponent(id: a, to: .init(9,8))
        let preview = try ElectronicsCommands.preview(command, document: doc, expectedRevision: doc.revision)
        try apply(.rotateComponent(id: b, by: 90), to: &doc)
        let before = doc
        failure("stale_revision") { try ElectronicsCommands.apply(command, to: &doc, expectedRevision: preview.baseRevision) }
        XCTAssertEqual(doc, before)
        failure("invalid_placement") { try self.apply(.moveComponent(id: self.a, to: .init(.nan, 0)), to: &doc) }
        XCTAssertEqual(doc, before)
        failure("component_missing") { try self.apply(.removeComponent(UUID()), to: &doc) }
        XCTAssertEqual(doc, before)
    }

    func testMoveRotateAndFlipReturnConsistentBoardAndPersistentIdentity() throws {
        var doc = try pair()
        try apply(.moveComponent(id: a, to: .init(20,15)), to: &doc)
        try apply(.rotateComponent(id: a, by: -90), to: &doc)
        XCTAssertEqual(doc.design.board.placements[0].rotationDegrees, 270)
        try apply(.flipComponent(a), to: &doc)
        let pads = try ElectronicsConnectivity.snapshot(doc.design).pads.filter { $0.componentID == a }
        XCTAssertTrue(pads.allSatisfy { $0.copperSides == [.bottom] })
        XCTAssertTrue(pads.allSatisfy { abs($0.center.x - 20) < 1e-9 })
        XCTAssertEqual(pads.map(\.center.y).sorted(), [14.175, 15.825])
        try apply(.setComponentSide(id: a, side: .top), to: &doc)
        XCTAssertEqual(doc.design.board.placements[0].componentID, a)
        let before = doc
        failure("invalid_rotation") { try self.apply(.rotateComponent(id: self.a, by: .infinity), to: &doc) }
        XCTAssertEqual(doc, before)
    }

    func testRemovingComponentCleansReferencesAndUndoRestoresAllOfThem() throws {
        var doc = try pair()
        let pins = try [pin(a, doc), pin(b, doc)]
        try apply(.connect(pins: pins, net: .init(name: "VCC")), to: &doc)
        try doc.edit(title: "Variante", expectedRevision: doc.revision) { $0.variants = [.init(name: "Test", excludedComponents: [self.a])] }
        let original = doc.design
        try apply(.removeComponent(a), to: &doc)
        XCTAssertEqual(doc.design.components.count, 1); XCTAssertEqual(doc.design.board.placements.count, 1)
        XCTAssertEqual(doc.design.connections.count, 1); XCTAssertTrue(doc.design.variants[0].excludedComponents.isEmpty)
        XCTAssertEqual(doc.design.library, original.library)
        try doc.undo(expectedRevision: doc.revision)
        XCTAssertEqual(doc.design, original)
    }

    func testConnectionsCannotSilentlyMergeNetworksAndRetryIsNoOp() throws {
        var doc = try pair()
        let p1 = try pin(a, doc), p2 = try pin(b, doc)
        let first = CircuitNet(name: "A"), second = CircuitNet(name: "B")
        try apply(.connect(pins: [p1], net: first), to: &doc)
        try apply(.connect(pins: [p2], net: second), to: &doc)
        let original = doc
        failure("pin_already_connected") { try self.apply(.connect(pins: [p1,p2], net: first), to: &doc) }
        XCTAssertEqual(doc, original)
        try apply(.connect(pins: [p1], net: first), to: &doc)
        XCTAssertEqual(doc, original)
        try apply(.disconnect([p2]), to: &doc)
        try apply(.connect(pins: [p1,p2], net: first), to: &doc)
        XCTAssertEqual(try ElectronicsConnectivity.snapshot(doc.design).airwires.count, 1)
    }

    func testDisconnectAndNCStayDistinctAndDeletingNetworkDoesNotDeclareNC() throws {
        var doc = try pair()
        let p = try pin(a, doc), net = CircuitNet(name: "GND")
        try apply(.connect(pins: [p], net: net), to: &doc)
        failure("connected_pin_nc") { try self.apply(.markNoConnect([p]), to: &doc) }
        try apply(.removeNet(net.id), to: &doc)
        XCTAssertTrue(doc.design.connections.isEmpty)
        XCTAssertFalse(try ElectronicsCommands.pins(of: a, in: doc.design)[0].explicitlyUnconnected)
        try apply(.markNoConnect([p]), to: &doc)
        XCTAssertTrue(try ElectronicsCommands.pins(of: a, in: doc.design)[0].explicitlyUnconnected)
        try apply(.disconnect([p]), to: &doc)
        XCTAssertFalse(try ElectronicsCommands.pins(of: a, in: doc.design)[0].explicitlyUnconnected)
    }

    func testLibraryConflictAndInvalidReferenceCannotPartiallyInsertAnything() throws {
        var doc = try pair(); let original = doc
        let command = resistor.command(reference: "R1", position: .init(3,4))
        failure("duplicate_identity") { try self.apply(command, to: &doc) }
        XCTAssertEqual(doc, original)
        var library = resistor.library
        library.footprints[0].pads[0].center.x += 1
        let component = CircuitComponent(reference: "R3", value: "test", device: resistor.device)
        failure("library_revision_conflict") {
            try self.apply(.addComponent(component: component, placement: .init(componentID: component.id, position: .init()), library: library), to: &doc)
        }
        XCTAssertEqual(doc, original)
    }

    func testMissingDuplicateOrEmptyPinSelectionsAndInvalidBoardsAreAtomic() throws {
        var doc = try pair(); let original = doc
        let p = try pin(a, doc)
        failure("invalid_pin_selection") { try self.apply(.connect(pins: [], net: .init(name: "A")), to: &doc) }
        failure("invalid_pin_selection") { try self.apply(.connect(pins: [p,p], net: .init(name: "A")), to: &doc) }
        failure("pin_missing") { try self.apply(.connect(pins: [.init(componentID: self.a, pinID: UUID())], net: .init(name: "A")), to: &doc) }
        failure("invalid_outline") { try self.apply(.setBoard(outline: [.init(0,0),.init(10,10),.init(0,10),.init(10,0)], thickness: 1.6, assemblyOrigin: .init()), to: &doc) }
        XCTAssertEqual(doc, original)
    }

    func testComponentUpdateAndReferenceSuggestionAreValidated() throws {
        var doc = try pair()
        XCTAssertEqual(ElectronicsCommands.nextReference(prefix: "R", in: doc.design), "R3")
        var component = doc.design.components[0]; component.reference = "R3"; component.value = "4.7k"
        try apply(.updateComponent(component), to: &doc)
        XCTAssertEqual(ElectronicsCommands.nextReference(prefix: "r", in: doc.design), "r1")
        XCTAssertEqual(doc.design.components[0].value, "4.7k")
        XCTAssertEqual(doc.design.components[0].id, a)
    }

    func testCodableCommandReplaysExactlyWithStableIDs() throws {
        let command = resistor.command(componentID: a, reference: "R1", position: .init(10,10))
        let restored = try JSONDecoder().decode(ElectronicsCommand.self, from: JSONEncoder().encode(command))
        XCTAssertEqual(command, restored)
        var first = try ElectronicsDocument.empty(); var second = first
        try apply(command, to: &first); try apply(restored, to: &second)
        XCTAssertEqual(first, second)
    }
}
