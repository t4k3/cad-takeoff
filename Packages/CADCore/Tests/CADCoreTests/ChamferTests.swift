import Foundation
import Testing
@testable import CADCore

private let base = Feature(name: "Base", kind: .box(width: 40, depth: 30, height: 5))

/// Edges of the design's first body matching `filter`, as stable references.
private func refs(_ features: [Feature], _ filter: (EdgeInfo) -> Bool) -> [EdgeRef] {
    let snap = DesignEvaluator.evaluate(CADDocument(features: features), revision: "r").bodies[0].snapshot
    return snap.edges.filter(filter).compactMap(EdgeRef.init)
}

private func chamfered(_ features: [Feature], _ spec: ChamferSpec) -> (Mesh, [DesignEvaluator.Issue], BodySnapshot?) {
    let c = Feature(name: "Smusso", kind: .chamfer(spec), operation: .cut)
    let (bodies, issues) = DesignEvaluator.evaluate(CADDocument(features: features + [c]), revision: "r")
    return (bodies.first?.mesh ?? Mesh(), issues, bodies.first?.snapshot)
}

private func allAt(z: Double) -> (EdgeInfo) -> Bool { { e in e.polyline.allSatisfy { abs($0.z - z) < 1e-9 } } }

@Test func equalChamferOnTopEdgesOfBox() {
    let top = refs([base], allAt(z: 5))
    #expect(top.count == 4)
    let (mesh, issues, snap) = chamfered([base], ChamferSpec(edges: top, distance: 1))
    #expect(issues.isEmpty)
    #expect(MeshValidator.validate(mesh).isWatertight)
    // Four wedges (legs 1 mm) minus the four mitred corners (d³/3 each).
    #expect(abs(mesh.volume - (6000 - 140 * 0.5 + 4.0 / 3)) < 1e-6)
    // The bevels are selectable planar faces tilted 45°.
    let bevels = snap?.faces.filter { $0.id.rawValue.hasPrefix("chamfer:") } ?? []
    #expect(bevels.count == 4)
    if case let .plane(_, n)? = bevels.first?.surface { #expect(abs(n.z - 0.5.squareRoot()) < 1e-9) }
}

@Test func twoDistancesAndDistanceAngle() {
    let front = refs([base], { e in e.polyline.allSatisfy { abs($0.z - 5) < 1e-9 && abs($0.y + 15) < 1e-9 } })
    #expect(front.count == 1)
    let (m1, i1, _) = chamfered([base], ChamferSpec(edges: front, mode: .twoDistances, distance: 1, distance2: 2))
    #expect(i1.isEmpty && MeshValidator.validate(m1).isWatertight)
    #expect(abs(m1.volume - (6000 - 40 * 1)) < 1e-6)
    let (m2, i2, _) = chamfered([base], ChamferSpec(edges: front, mode: .distanceAngle, distance: 2, angle: 30))
    #expect(i2.isEmpty && MeshValidator.validate(m2).isWatertight)
    #expect(abs(m2.volume - (6000 - 40 * 0.5 * 2 * 2 * tan(.pi / 6))) < 1e-6)
    // Flip swaps the sides: same removed area for two distances.
    let (m3, _, _) = chamfered([base], ChamferSpec(edges: front, mode: .twoDistances, distance: 1, distance2: 2, flip: true))
    #expect(abs(m3.volume - m1.volume) < 1e-6)
}

@Test func chamferFollowsParameterEdits() {
    let front = refs([base], { e in e.polyline.allSatisfy { abs($0.z - 5) < 1e-9 && abs($0.y + 15) < 1e-9 } })
    var wider = base
    wider.kind = .box(width: 60, depth: 30, height: 5)
    let (mesh, issues, _) = chamfered([wider], ChamferSpec(edges: front, distance: 1))
    #expect(issues.isEmpty)
    #expect(abs(mesh.volume - (9000 - 60 * 0.5)) < 1e-6)
}

@Test func chamferStopsAtWall() {
    // L-shape: step 20×10×5 with a 10×10×10 block on its left half.
    let step = Feature(name: "Gradino", kind: .box(width: 20, depth: 10, height: 5), position: Vec3(10, 5, 0))
    let block = Feature(name: "Blocco", kind: .box(width: 10, depth: 10, height: 10), position: Vec3(5, 5, 0), operation: .join)
    let edge = refs([step, block], { e in e.polyline.allSatisfy { abs($0.z - 5) < 1e-9 && abs($0.y) < 1e-9 } })
    #expect(edge.count == 1)
    let (mesh, issues, _) = chamfered([step, block], ChamferSpec(edges: edge, distance: 1))
    #expect(issues.isEmpty && MeshValidator.validate(mesh).isWatertight)
    // Only the free 10 mm run is bevelled; the block's front face is untouched.
    #expect(abs(mesh.volume - (1000 + 500 - 10 * 0.5)) < 1e-6)
}

@Test func concaveEdgeIsReported() {
    let step = Feature(name: "Gradino", kind: .box(width: 20, depth: 10, height: 5), position: Vec3(10, 5, 0))
    let block = Feature(name: "Blocco", kind: .box(width: 10, depth: 10, height: 10), position: Vec3(5, 5, 0), operation: .join)
    // Inside corner between the step's top and the block's wall.
    let inner = refs([step, block], { e in e.polyline.allSatisfy { abs($0.z - 5) < 1e-9 && abs($0.x - 10) < 1e-9 } })
    #expect(inner.count == 1)
    let (mesh, issues, _) = chamfered([step, block], ChamferSpec(edges: inner, distance: 1))
    #expect(issues.contains { $0.message.contains("concavo") })
    #expect(abs(mesh.volume - 1500) < 1e-6)
}

@Test func cylinderTopRim() {
    let boss = Feature(name: "Perno", kind: .cylinder(radius: 10, height: 20))
    let rim = refs([boss], allAt(z: 20))
    #expect(rim.count == 1)
    let (mesh, issues, snap) = chamfered([boss], ChamferSpec(edges: rim, distance: 1))
    #expect(issues.isEmpty && MeshValidator.validate(mesh).isWatertight)
    let before = Profile2D.circle(radius: 10, segments: 64).area * 20
    let ring = 0.5 * 2 * .pi * (10 - 1.0 / 3)   // Pappus, true circle
    #expect(abs((before - mesh.volume) - ring) < ring * 0.02)
    #expect(snap?.faces.contains { if case .cone = $0.surface { $0.id.rawValue.hasPrefix("chamfer:") } else { false } } == true)
}

@Test func holeMouthChamfer() {
    let plate = Feature(name: "Piastra", kind: .box(width: 40, depth: 40, height: 10))
    let hole = Feature(name: "Foro", kind: .hole(HoleSpec(centers: [Vec3(0, 0, 10)], fit: .manual, diameter: 6)), operation: .cut)
    let mouth = refs([plate, hole], { e in e.faces.contains { $0.rawValue.contains("bore") } && e.polyline.allSatisfy { abs($0.z - 10) < 1e-9 } })
    #expect(mouth.count == 1)
    let drilled = DesignEvaluator.evaluate(CADDocument(features: [plate, hole]), revision: "r").bodies[0].mesh.volume
    let (mesh, issues, _) = chamfered([plate, hole], ChamferSpec(edges: mouth, distance: 1))
    #expect(issues.isEmpty && MeshValidator.validate(mesh).isWatertight)
    let ring = 0.5 * 2 * .pi * (3 + 1.0 / 3)
    #expect(abs((drilled - mesh.volume) - ring) < ring * 0.03)
}

@Test func missingEdgesAndPersistence() throws {
    let ghost = EdgeRef(faces: [FaceID(rawValue: "x/a"), FaceID(rawValue: "x/b")], point: .zero)
    let (_, issues, _) = chamfered([base], ChamferSpec(edges: [ghost], distance: 1))
    #expect(issues.contains { $0.message.contains("non esistono più") })
    var spec = ChamferSpec(edges: [ghost, ghost], distance: 1)
    #expect(throws: KernelError.self) { try spec.validate() }
    spec.edges = [ghost]; spec.distance = 0
    #expect(throws: KernelError.self) { try spec.validate() }
    let f = Feature(name: "S", kind: .chamfer(ChamferSpec(edges: [ghost], mode: .distanceAngle, distance: 2, angle: 30)), operation: .cut)
    let doc = CADDocument(features: [base, f])
    #expect(try CADDocument.decode(doc.encoded()) == doc)
}
