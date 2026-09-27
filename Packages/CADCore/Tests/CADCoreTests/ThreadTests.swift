import Foundation
import Testing
@testable import CADCore

private func wall(_ snap: BodySnapshot, radius r: Double) -> FaceID? {
    snap.faces.first { if case let .cylinder(_, _, rr) = $0.surface { abs(rr - r) < 1e-6 } else { false } }?.id
}

@Test func outsideThreadOnAShaftIsAnM8Screw() throws {
    // A Ø8 × 20 shaft standing on a 30 × 30 × 5 plate: an M8 × 1.25 thread on its wall, stopping
    // at the plate (a shoulder), running out at the free top.
    let plate = Feature(name: "Base", kind: .box(width: 30, depth: 30, height: 5))
    var shaft = Feature(name: "Perno", kind: .cylinder(radius: 4, height: 20), operation: .join)
    shaft.position = Vec3(0, 0, 5)
    let base = DesignEvaluator.evaluate(CADDocument(features: [plate, shaft]), revision: "a").bodies[0]
    let face = try #require(wall(base.snapshot, radius: 4))
    let thread = Feature(name: "Filetto", kind: .thread(ThreadSpec(face: face)))
    let r = DesignEvaluator.evaluate(CADDocument(features: [plate, shaft, thread]), revision: "b")
    #expect(r.issues.isEmpty, "\(r.issues)")
    let body = try #require(r.bodies.first)
    #expect(MeshValidator.validate(body.mesh).isWatertight)
    // Material removed: less than the whole ring between the minor and the nominal radius.
    let removed = base.mesh.volume - body.mesh.volume
    let ring = Double.pi * (16 - pow(4 - 0.541266 * 1.25 - 0.1, 2)) * 20
    #expect(removed > ring * 0.25 && removed < ring, "\(removed) of \(ring)")
    // The plate is untouched: nothing removed below z = 5.
    #expect(abs((body.mesh.bounds?.min.z ?? -1)) < 1e-9 && abs((body.mesh.bounds?.max.x ?? 0) - 15) < 1e-9)
    let low = body.mesh.vertices.filter { $0.z < 4.99 && hypot($0.x, $0.y) < 5 }
    #expect(low.isEmpty)
    // Teeth: radii at one height vary by about the thread depth.
    let radii = body.mesh.vertices.filter { abs($0.z - 15) < 0.1 && hypot($0.x, $0.y) < 4.5 }.map { hypot($0.x, $0.y) }
    #expect((radii.max() ?? 0) - (radii.min() ?? 0) > 0.5)
}

@Test func insideThreadInAHoleWallAndItsSize() throws {
    // A plate with a Ø6.8 hole (M8 tap drill) through it: the wall threaded M8 from the inside.
    let plate = Feature(name: "Piastra", kind: .box(width: 30, depth: 30, height: 10))
    let hole = Feature(name: "Foro", kind: .hole(HoleSpec(centers: [Vec3(0, 0, 10)], fit: .manual, size: nil, diameter: 6.8)), operation: .cut)
    let base = DesignEvaluator.evaluate(CADDocument(features: [plate, hole]), revision: "a").bodies[0]
    let face = try #require(wall(base.snapshot, radius: 3.4))
    let thread = Feature(name: "Filetto", kind: .thread(ThreadSpec(face: face)))
    let r = DesignEvaluator.evaluate(CADDocument(features: [plate, hole, thread]), revision: "b")
    #expect(r.issues.isEmpty, "\(r.issues)")
    let body = try #require(r.bodies.first)
    #expect(MeshValidator.validate(body.mesh).isWatertight)
    #expect(body.mesh.volume < base.mesh.volume - 5, "grooves cut into the wall")
    #expect(ThreadSpec.size(forDiameter: 6.8, inside: true)?.name == "M8" && ThreadSpec.size(forDiameter: 8, inside: false)?.name == "M8")
    // A face that is not a cylinder: said.
    let top = try #require(base.snapshot.faces.first { if case let .plane(_, n) = $0.surface { n.z > 0.9 } else { false } }?.id)
    let bad = DesignEvaluator.evaluate(CADDocument(features: [plate, hole, Feature(name: "F", kind: .thread(ThreadSpec(face: top)))]), revision: "c")
    #expect(bad.issues.contains { $0.message.contains("non è cilindrica") })
}
