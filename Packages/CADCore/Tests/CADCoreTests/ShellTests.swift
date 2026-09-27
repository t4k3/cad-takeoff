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

/// The usual enclosure: a box rounded on every edge, then hollowed with the top open; and it
/// keeps working when the box changes size afterwards.
@Test func roundedBoxShellsAndFollowsItsSize() throws {
    for width in [40.0, 60.0, 25.0] {
        let box = Feature(name: "B", kind: .box(width: width, depth: 30, height: 20))
        let snap = DesignEvaluator.evaluate(CADDocument(features: [Feature(name: "B", kind: .box(width: 40, depth: 30, height: 20))]), revision: "a").bodies[0].snapshot
        _ = snap
        let base = DesignEvaluator.evaluate(CADDocument(features: [box]), revision: "b\(width)").bodies[0].snapshot
        let round = Feature(name: "R", kind: .chamfer(ChamferSpec(edges: base.edges.filter(\.isSharp).compactMap(EdgeRef.init), profile: .round, distance: 3)))
        let rounded = DesignEvaluator.evaluate(CADDocument(features: [box, round]), revision: "r\(width)").bodies[0]
        let top = rounded.snapshot.faces.first { if case let .plane(_, n) = $0.surface { n.z > 0.99 } else { false } }!.id
        let shell = Feature(name: "G", kind: .shell(ShellSpec(body: box.id, thickness: 2, openFaces: [top])))
        let r = DesignEvaluator.evaluate(CADDocument(features: [box, round, shell]), revision: "s\(width)")
        #expect(r.issues.isEmpty, "\(r.issues.map(\.message))")
        let m = r.bodies[0].mesh
        #expect(MeshValidator.validate(m).isWatertight)
        // Walls about 2 mm: far less than the solid, more than a paper-thin skin.
        #expect(m.volume < rounded.mesh.volume * 0.6 && m.volume > rounded.mesh.volume * 0.1)
    }
}

/// Hollowing moves each curved wall into the material: the cup's wall towards its axis (the
/// cavity wall is the cylinder r − t, described exactly).
@Test func shellMovesCurvedWallsIntoTheMaterialExactly() throws {
    let cyl = Feature(name: "Tazza", kind: .cylinder(radius: 10, height: 20))
    let snap = DesignEvaluator.evaluate(CADDocument(features: [cyl]), revision: "a").bodies[0].snapshot
    let shell = Feature(name: "Guscio", kind: .shell(ShellSpec(body: cyl.id, thickness: 1.5, openFaces: [topFace(snap)])))
    let body = try #require(DesignEvaluator.evaluate(CADDocument(features: [cyl, shell]), revision: "b").bodies.first)
    let radii = body.snapshot.faces.compactMap { f -> Double? in if case let .cylinder(_, _, r) = f.surface { r } else { nil } }
    #expect(Set(radii) == [10, 8.5], "\(radii)")
}
