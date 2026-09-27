import Foundation
import Testing
@testable import CADCore

private let facet = sin(2 * Double.pi / 64) * 64 / (2 * .pi)   // area of a 64-gon over the circle's

private func rect(_ x0: Double, _ y0: Double, _ x1: Double, _ y1: Double) -> Profile2D {
    Profile2D(points: [Vec2(x0, y0), Vec2(x1, y0), Vec2(x1, y1), Vec2(x0, y1)])
}

private func solidMesh(_ spec: RevolveSpec, holes: [Profile2D] = []) throws -> Mesh {
    try Revolve.build(spec, holes: holes, featureID: UUID(), position: .zero).triangulated().mesh
}

@Test func revolvingARectangleMakesATubeOrAPartOfIt() throws {
    // Profile 5…10 from the Y axis, 20 high: a tube around Y.
    let spec = RevolveSpec(profile: rect(5, 0, 10, 20), axisStart: Vec2(0, 0), axisEnd: Vec2(0, 1))
    let tube = try solidMesh(spec)
    #expect(MeshValidator.validate(tube).isWatertight)
    let exact = Double.pi * (100 - 25) * 20
    #expect(abs(tube.volume - exact * facet) / exact < 1e-3)
    // A quarter turn, both ways: a quarter of the volume, closed by the two ends.
    for reversed in [false, true] {
        var q = spec
        q.angle = 90; q.reversed = reversed
        let m = try solidMesh(q)
        #expect(MeshValidator.validate(m).isWatertight)
        #expect(abs(m.volume - exact / 4) / exact < 2e-3)
        // Reversed turns towards −Z (the back of the XY sketch).
        let zs = m.vertices.map(\.z)
        #expect(reversed ? zs.max()! < 1e-9 : zs.min()! > -1e-9)
    }
}

@Test func revolvingAProfileOnTheAxisMakesASolidAndACircleATorus() throws {
    let cyl = try solidMesh(RevolveSpec(profile: rect(0, 0, 10, 20), axisStart: Vec2(0, 0), axisEnd: Vec2(0, 5)))
    #expect(MeshValidator.validate(cyl).isWatertight)
    #expect(abs(cyl.volume - .pi * 100 * 20 * facet) < 1)
    // A circle of radius 3 at 12 from the axis: a torus, 2π²·R·r².
    let circle = SketchShape(kind: .circle(center: Vec2(12, 0), radius: 3)).profile!
    let solid = try Revolve.build(RevolveSpec(profile: circle, axisStart: Vec2(0, -1), axisEnd: Vec2(0, 1)), holes: [], featureID: UUID(), position: .zero)
    let m = solid.triangulated().mesh
    #expect(MeshValidator.validate(m).isWatertight)
    let exact = 2 * Double.pi * .pi * 12 * 9
    #expect(abs(m.volume - exact) / exact < 5e-3)
    // One torus face for the whole circle.
    #expect(solid.faces.filter { if case .torus = $0.surface { true } else { false } }.count == 1)
}

@Test func revolveRejectsAProfileAcrossTheAxisAndKeepsHoles() throws {
    #expect(throws: KernelError.self) { try solidMesh(RevolveSpec(profile: rect(-5, 0, 5, 10), axisStart: Vec2(0, 0), axisEnd: Vec2(0, 1))) }
    #expect(throws: KernelError.self) { try solidMesh(RevolveSpec(profile: rect(1, 0, 5, 10), axisStart: Vec2(0, 0), axisEnd: Vec2(0, 1), angle: 0)) }
    // A washer section with a hole: the hole sweeps a void inside.
    let hole = rect(6, 4, 8, 6)
    let m = try solidMesh(RevolveSpec(profile: rect(5, 0, 10, 10), axisStart: Vec2(0, 0), axisEnd: Vec2(0, 1), angle: 180), holes: [hole])
    #expect(MeshValidator.validate(m).isWatertight)
    let exact = (Double.pi * (100 - 25) * 10 - .pi * (64 - 36) * 2) / 2
    #expect(abs(m.volume - exact) / exact < 3e-3)
}

@Test func revolveInTheDesignJoinsAndCuts() throws {
    // A shaft (revolved about X on the XY sketch) and a box it cuts a groove into.
    var shaft = Feature(name: "Albero", kind: .revolve(RevolveSpec(profile: rect(0, 0, 40, 6), axisStart: Vec2(0, 0), axisEnd: Vec2(1, 0))))
    shaft.operation = .newBody
    let block = Feature(name: "Blocco", kind: .box(width: 10, depth: 30, height: 30), position: Vec3(20, 0, -15))
    var groove = Feature(name: "Gola", kind: .revolve(RevolveSpec(profile: rect(18, 5, 22, 8), axisStart: Vec2(0, 0), axisEnd: Vec2(1, 0))))
    groove.operation = .cut
    let doc = CADDocument(features: [block, groove, shaft])
    let result = DesignEvaluator.evaluate(doc, revision: "r")
    #expect(result.issues.isEmpty)
    #expect(result.bodies.count == 2)
    let cutBlock = result.bodies.first { $0.id == block.id }!
    #expect(MeshValidator.validate(cutBlock.mesh).isWatertight)
    let ring = Double.pi * (64 - 25) * 4 * facet
    #expect(abs(cutBlock.mesh.volume - (10 * 30 * 30 - ring)) < 2)
    // Saved and read back.
    #expect(try CADDocument.decode(doc.encoded()) == doc)
}

@Test func revolveFollowsItsSketch() throws {
    let axis = SketchShape(kind: .polyline([Vec2(0, 0), Vec2(0, 50)], closed: false), isConstruction: true)
    let rect = SketchShape(kind: .rectangle(corner: Vec2(5, 0), width: 5, height: 20))
    var sketch = Sketch(name: "S", shapes: [axis, rect])
    let area = sketch.faces[0]
    let spec = RevolveSpec(profile: Profile2D(points: area.outline), axisStart: Vec2(0, 0), axisEnd: Vec2(0, 50), axisRef: .segment(axis.id, 0))
    let f = Feature(name: "R", kind: .revolve(spec))
    var doc = CADDocument(features: [f], sketches: [sketch])
    doc.sketchLinks = [SketchLink(featureID: f.id, sketchID: sketch.id, shapeID: UUID(), seeds: [area.seed])]
    // The rectangle gets wider and the axis moves: the revolve follows both.
    sketch.shapes[1].kind = .rectangle(corner: Vec2(5, 0), width: 10, height: 20)
    sketch.shapes[0].kind = .polyline([Vec2(-2, 0), Vec2(-2, 50)], closed: false)
    doc.upsert(sketch)
    doc.regenerate(from: sketch)
    guard case let .revolve(s) = doc.features[0].kind else { Issue.record("no revolve"); return }
    #expect(abs(s.profile.area - 200) < 1e-9 && s.axisStart.x == -2)
}

@Test func anArcCentredOnTheAxisSweepsASphere() throws {
    // Half a disc of radius 10 against the axis: a ball, one exact sphere face (not a torus of
    // radius zero, which STEP readers refuse).
    let half = Profile2D(points: (0...32).map { k -> Vec2 in
        let a = -Double.pi / 2 + Double.pi * Double(k) / 32
        return Vec2(10 * cos(a), 10 * sin(a))
    })
    let spec = RevolveSpec(profile: half, axisStart: Vec2(0, -1), axisEnd: Vec2(0, 1))
    let solid = try Revolve.build(spec, holes: [], featureID: UUID(), position: .zero)
    let spheres = solid.faces.compactMap { if case let .sphere(_, r) = $0.surface { r } else { nil } }
    #expect(spheres.count == 1 && abs(spheres[0] - 10) < 1e-9)
    #expect(!solid.faces.contains { if case .torus = $0.surface { true } else { false } })
    let m = solid.triangulated().mesh
    #expect(MeshValidator.validate(m).isWatertight)
    let ball = Feature(name: "Sfera", kind: .revolve(spec))
    let step = try STEPExporter.export(STEPExporter.parts(of: CADDocument(features: [ball])))
    #expect(step.contains("SPHERICAL_SURFACE") && !step.contains("TOROIDAL_SURFACE"))
}

@Test func aDomedPinIsExactInSTEP() throws {
    // Cylinder Ø20 × 20 with a half-sphere cap: the sphere meets the cylinder on an exact circle.
    let cap = (1...16).map { k -> Vec2 in
        let a = Double.pi / 2 * Double(k) / 16
        return Vec2(10 * cos(a), 20 + 10 * sin(a))
    }
    let profile = Profile2D(points: [Vec2(0, 0), Vec2(10, 0), Vec2(10, 20)] + cap.dropLast() + [Vec2(0, 30)])
    let spec = RevolveSpec(profile: profile, axisStart: Vec2(0, 0), axisEnd: Vec2(0, 1))
    let solid = try Revolve.build(spec, holes: [], featureID: UUID(), position: .zero)
    #expect(solid.faces.contains { if case .sphere = $0.surface { true } else { false } })
    let step = try STEPExporter.export(STEPExporter.parts(of: CADDocument(features: [Feature(name: "Perno", kind: .revolve(spec))])))
    #expect(step.contains("SPHERICAL_SURFACE") && step.contains("CYLINDRICAL_SURFACE") && !step.contains("TOROIDAL_SURFACE"))
}
