import Foundation
import Testing
@testable import CADCore

@Test func moveTurnsAndShiftsBodiesKeepingTheirFaces() throws {
    let box = Feature(name: "Box", kind: .box(width: 40, depth: 20, height: 10))
    let other = Feature(name: "Altro", kind: .cylinder(radius: 5, height: 10), position: Vec3(100, 0, 0))
    // A quarter turn about Z through the box's centre, then 50 up.
    let move = Feature(name: "Sposta", kind: .move(MoveSpec(bodies: [box.id], translation: Vec3(0, 0, 50), axis: Vec3(0, 0, 1), angle: 90)))
    let before = DesignEvaluator.evaluate(CADDocument(features: [box, other]), revision: "a")
    let result = DesignEvaluator.evaluate(CADDocument(features: [box, other, move]), revision: "b")
    #expect(result.issues.isEmpty)
    let moved = result.bodies.first { $0.id == box.id }!
    let v = moved.mesh.vertices
    #expect(abs(v.map(\.x).max()! - 10) < 1e-9 && abs(v.map(\.y).max()! - 20) < 1e-9)   // 40 × 20 turned: 20 × 40
    #expect(abs(v.map(\.z).min()! - 50) < 1e-9 && abs(v.map(\.z).max()! - 60) < 1e-9)
    #expect(abs(moved.mesh.volume - 8000) < 1e-6)
    #expect(Set(moved.snapshot.faces.map(\.id)) == Set(before.bodies.first { $0.id == box.id }!.snapshot.faces.map(\.id)))
    // The other body stays; a later cut sees the moved box where it now is.
    #expect(result.bodies.first { $0.id == other.id }!.mesh.vertices == before.bodies.first { $0.id == other.id }!.mesh.vertices)
    let hole = Feature(name: "Foro", kind: .cylinder(radius: 2, height: 20), position: Vec3(0, 0, 45), operation: .cut)
    let cut = DesignEvaluator.evaluate(CADDocument(features: [box, other, move, hole]), revision: "c")
    let cutBox = cut.bodies.first { $0.id == box.id }!
    #expect(cutBox.mesh.volume < 8000 - 100 && MeshValidator.validate(cutBox.mesh).isWatertight)
    // Nothing to move: an issue, not a crash; saved and read back.
    let lost = Feature(name: "Sposta", kind: .move(MoveSpec(bodies: [UUID()], translation: Vec3(1, 0, 0))))
    #expect(!DesignEvaluator.evaluate(CADDocument(features: [box, lost]), revision: "d").issues.isEmpty)
    let doc = CADDocument(features: [box, move])
    #expect(try CADDocument.decode(doc.encoded()) == doc)
}
