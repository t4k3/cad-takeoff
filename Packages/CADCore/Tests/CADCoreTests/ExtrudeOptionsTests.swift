import Foundation
import Testing
@testable import CADCore

private func square(_ s: Double) -> Profile2D { Profile2D.rectangle(width: s, height: s) }

@Test func symmetricExtrusionsSitAcrossTheSketchPlane() throws {
    var f = Feature(name: "S", kind: .extrude(profile: square(20), height: 10))
    f.symmetric = true
    let m = try PrimitiveKernel.build(f).mesh
    #expect(abs(m.vertices.map(\.z).min()! + 5) < 1e-9 && abs(m.vertices.map(\.z).max()! - 5) < 1e-9)
    #expect(abs(m.volume - 4000) < 1e-6)
    // On a side plane (XZ): across y = 0.
    f.placement = FeaturePlacement(plane: SketchPlane(origin: .zero, xAxis: Vec3(1, 0, 0), yAxis: Vec3(0, 0, 1)))
    let p = try PrimitiveKernel.build(f).mesh
    #expect(abs(p.vertices.map(\.y).min()! + 5) < 1e-9 && abs(p.vertices.map(\.y).max()! - 5) < 1e-9)
    #expect(try CADDocument.decode(CADDocument(features: [f]).encoded()).features[0].symmetric)
}

@Test func draftedExtrusionsNarrowOrWiden() throws {
    var f = Feature(name: "T", kind: .extrude(profile: square(20), height: 10))
    f.taper = 10
    let body = try PrimitiveKernel.build(f)
    try body.validate()
    let top = 20 - 2 * 10 * tan(10 * Double.pi / 180)
    let expected = 10.0 / 3 * (400 + top * top + 20 * top)
    #expect(abs(body.mesh.volume - expected) < 1e-6)
    f.taper = -10   // widens
    let wide = 20 + 2 * 10 * tan(10 * Double.pi / 180)
    #expect(abs(try PrimitiveKernel.build(f).mesh.volume - 10.0 / 3 * (400 + wide * wide + 20 * wide)) < 1e-6)
    // Too steep: the top would vanish.
    f.taper = 50
    f.kind = .extrude(profile: square(20), height: 30)
    #expect(throws: KernelError.self) { try PrimitiveKernel.build(f) }
    #expect(try CADDocument.decode(CADDocument(features: [f]).encoded()).features[0].taper == 50)
}

@Test func draftedRoundWallIsAConeAndHolesOpenUp() throws {
    let circle = SketchShape(kind: .circle(center: .init(0, 0), radius: 10)).profile!
    var f = Feature(name: "C", kind: .extrude(profile: circle, height: 10))
    f.taper = 5
    let snap = try PrimitiveKernel.build(f).snapshot(revision: "a")
    #expect(snap.faces.count == 3)
    #expect(snap.faces.contains { if case let .cone(apex, axis, half) = $0.surface { apex.z > 10 && axis.z < 0 && abs(half - 5 * .pi / 180) < 1e-12 } else { false } })
    // A plate with a hole, drafted: still one closed body, the hole wider at the top.
    var plate = Feature(name: "P", kind: .extrude(profile: square(40), height: 10), holes: [SketchShape(kind: .circle(center: .init(0, 0), radius: 5)).profile!])
    plate.taper = 5
    let result = DesignEvaluator.evaluate(CADDocument(features: [plate]), revision: "b")
    #expect(result.issues.isEmpty)
    let m = result.bodies[0].mesh
    #expect(MeshValidator.validate(m).isWatertight)
    let t = 10 * tan(5 * Double.pi / 180), top = 40 - 2 * t
    let outer = 10.0 / 3 * (1600 + top * top + 40 * top)
    let facet = sin(2 * Double.pi / 64) * 64 / (2 * .pi)
    let hole = Double.pi * 10 / 3 * (25 + 5 * (5 + t) + (5 + t) * (5 + t)) * facet
    #expect(abs(m.volume - (outer - hole)) < 0.5)
    #expect(m.vertices.map(\.z).min()! > -1e-9 && m.vertices.map(\.z).max()! < 10 + 1e-9)
}
