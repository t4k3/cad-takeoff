import Foundation
import Testing
@testable import CADCore

private func topFace(_ snap: BodySnapshot) -> FaceID {
    snap.faces.first { if case let .plane(_, n) = $0.surface { n.z > 0.99 } else { false } }!.id
}

@Test func shellHollowsABoxWithTheTopOpen() throws {
    let box = Feature(name: "Scatola", kind: .box(width: 40, depth: 30, height: 20))
    let snap = DesignEvaluator.evaluate(CADDocument(features: [box]), revision: "a").bodies[0].snapshot
    let shell = Feature(name: "Guscio", kind: .shell(ShellSpec(body: box.id, thickness: 2, openFaces: [topFace(snap)])))
    let result = DesignEvaluator.evaluate(CADDocument(features: [box, shell]), revision: "b")
    #expect(result.issues.isEmpty)
    let m = result.bodies[0].mesh
    #expect(MeshValidator.validate(m).isWatertight)
    #expect(abs(m.volume - (40 * 30 * 20 - 36 * 26 * 18)) < 1e-3)
    // Closed (no open face): a hollow box, two shells.
    let closed = Feature(name: "Guscio", kind: .shell(ShellSpec(body: box.id, thickness: 2)))
    let r2 = DesignEvaluator.evaluate(CADDocument(features: [box, closed]), revision: "c")
    #expect(r2.issues.isEmpty)
    #expect(abs(r2.bodies[0].mesh.volume - (40 * 30 * 20 - 36 * 26 * 16)) < 1e-3)
}

@Test func shellFollowsCurvedWallsAndRejectsTooThick() throws {
    let cyl = Feature(name: "Tazza", kind: .cylinder(radius: 10, height: 20))
    let snap = DesignEvaluator.evaluate(CADDocument(features: [cyl]), revision: "a").bodies[0].snapshot
    let shell = Feature(name: "Guscio", kind: .shell(ShellSpec(body: cyl.id, thickness: 1.5, openFaces: [topFace(snap)])))
    let result = DesignEvaluator.evaluate(CADDocument(features: [cyl, shell]), revision: "b")
    #expect(result.issues.isEmpty)
    let m = result.bodies[0].mesh
    #expect(MeshValidator.validate(m).isWatertight)
    // 64-gon walls: the inner polygon is the outer one moved in by 1.5 (apothem).
    let apothem = 10 * cos(Double.pi / 64)
    let area = { (a: Double) in 64 * a * a * tan(Double.pi / 64) }
    let expected = area(apothem) * 20 - area(apothem - 1.5) * 18.5
    #expect(abs(m.volume - expected) < 0.05)
    let thick = Feature(name: "Guscio", kind: .shell(ShellSpec(body: cyl.id, thickness: 12, openFaces: [topFace(snap)])))
    #expect(!DesignEvaluator.evaluate(CADDocument(features: [cyl, thick]), revision: "c").issues.isEmpty)
    // Saved and read back.
    let doc = CADDocument(features: [cyl, shell])
    #expect(try CADDocument.decode(doc.encoded()) == doc)
}
