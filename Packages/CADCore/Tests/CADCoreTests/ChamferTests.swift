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

@Test func insideCornersAreFilled() {
    let step = Feature(name: "Gradino", kind: .box(width: 20, depth: 10, height: 5), position: Vec3(10, 5, 0))
    let block = Feature(name: "Blocco", kind: .box(width: 10, depth: 10, height: 10), position: Vec3(5, 5, 0), operation: .join)
    // Inside corner between the step's top (z = 5) and the block's wall (x = 10), 10 mm long.
    let inner = refs([step, block], { e in e.polyline.allSatisfy { abs($0.z - 5) < 1e-9 && abs($0.x - 10) < 1e-9 } })
    #expect(inner.count == 1)
    let (round, i1, snap) = chamfered([step, block], ChamferSpec(edges: inner, profile: .round, distance: 2))
    #expect(i1.isEmpty && MeshValidator.validate(round).isWatertight)
    #expect(abs(round.volume - (1500 + 10 * roundArea(2))) < 1e-6)
    // Nothing added past the part's ends (y 0…10).
    #expect(abs(round.bounds!.min.y) < 1e-9 && abs(round.bounds!.max.y - 10) < 1e-9)
    #expect(snap?.faces.contains { if case let .cylinder(_, _, r) = $0.surface { abs(r - 2) < 1e-12 } else { false } } == true)
    let (flat, i2, _) = chamfered([step, block], ChamferSpec(edges: inner, distance: 2))
    #expect(i2.isEmpty && MeshValidator.validate(flat).isWatertight && abs(flat.volume - (1500 + 10 * 2)) < 1e-6)
}

@Test func rootOfABossAndFloorOfABlindHole() {
    let centroid = (10 - 3 * Double.pi) / (12 - 3 * Double.pi)
    let plate = Feature(name: "Piastra", kind: .box(width: 40, depth: 40, height: 5))
    let boss = Feature(name: "Perno", kind: .cylinder(radius: 5, height: 10), position: Vec3(0, 0, 5), operation: .join)
    let root = refs([plate, boss], { e in e.faces.contains { $0.rawValue.contains("cylinder/wall") } && e.polyline.allSatisfy { abs($0.z - 5) < 1e-9 } })
    #expect(root.count == 1)
    let before = DesignEvaluator.evaluate(CADDocument(features: [plate, boss]), revision: "r").bodies[0].mesh.volume
    let (m1, i1, _) = chamfered([plate, boss], ChamferSpec(edges: root, profile: .round, distance: 1))
    #expect(i1.isEmpty && MeshValidator.validate(m1).isWatertight)
    let added = 2 * Double.pi * (5 + centroid) * (1 - .pi / 4)
    #expect(abs((m1.volume - before) - added) < added * 0.05)

    let block = Feature(name: "Blocco", kind: .box(width: 40, depth: 40, height: 10))
    let blind = Feature(name: "Foro", kind: .hole(HoleSpec(centers: [Vec3(0, 0, 10)], fit: .manual, diameter: 10, depth: 5)), operation: .cut)
    let floor = refs([block, blind], { e in e.faces.contains { $0.rawValue.contains("bore") } && e.polyline.allSatisfy { abs($0.z - 5) < 1e-9 } })
    #expect(floor.count == 1)
    let drilled = DesignEvaluator.evaluate(CADDocument(features: [block, blind]), revision: "r").bodies[0].mesh.volume
    let (m2, i2, _) = chamfered([block, blind], ChamferSpec(edges: floor, profile: .round, distance: 1))
    #expect(i2.isEmpty && MeshValidator.validate(m2).isWatertight)
    let filled = 2 * Double.pi * (5 - centroid) * (1 - .pi / 4)
    #expect(abs((m2.volume - drilled) - filled) < filled * 0.05)
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

// MARK: Round profile (fillet)

/// Area removed by a round of radius r on a right-angle edge (arc as n chords over 90°).
private func roundArea(_ r: Double, _ n: Int = 16) -> Double { r * r - Double(n) / 2 * r * r * sin(.pi / 2 / Double(n)) }

@Test func roundOnOneEdgeAndMitredCorner() {
    let front = refs([base], { e in e.polyline.allSatisfy { abs($0.z - 5) < 1e-9 && abs($0.y + 15) < 1e-9 } })
    let (m1, i1, snap) = chamfered([base], ChamferSpec(edges: front, profile: .round, distance: 2))
    #expect(i1.isEmpty && MeshValidator.validate(m1).isWatertight)
    #expect(abs(m1.volume - (6000 - 40 * roundArea(2))) < 1e-6)
    let round = snap?.faces.first { $0.id.rawValue.hasPrefix("chamfer:") }
    if case let .cylinder(_, axis, r)? = round?.surface { #expect(abs(r - 2) < 1e-12 && abs(abs(axis.x) - 1) < 1e-12) } else { Issue.record("round face is cylindrical") }
    let top = refs([base], allAt(z: 5))
    let (m4, i4, _) = chamfered([base], ChamferSpec(edges: top, profile: .round, distance: 1))
    #expect(i4.isEmpty && MeshValidator.validate(m4).isWatertight)
    #expect(m4.volume < 6000 - 138 * roundArea(1) && m4.volume > 6000 - 140 * roundArea(1))
    #expect(ChamferSpec(edges: top, profile: .round, distance: 1).title == "Raccordo R1 mm ×4")
}

@Test func roundOnCylinderAndHoleRims() {
    let centroid = (10 - 3 * Double.pi) / (12 - 3 * Double.pi)   // of the removed corner, in radii
    let boss = Feature(name: "Perno", kind: .cylinder(radius: 10, height: 20))
    let (m1, i1, snap) = chamfered([boss], ChamferSpec(edges: refs([boss], allAt(z: 20)), profile: .round, distance: 2))
    #expect(i1.isEmpty && MeshValidator.validate(m1).isWatertight)
    let removed1 = Profile2D.circle(radius: 10, segments: 64).area * 20 - m1.volume
    let expected1 = 2 * .pi * (10 - 2 * centroid) * 4 * (1 - .pi / 4)
    #expect(abs(removed1 - expected1) < expected1 * 0.03)
    #expect(snap?.faces.contains { if case .torus = $0.surface { true } else { false } } == true)

    let plate = Feature(name: "Piastra", kind: .box(width: 40, depth: 40, height: 10))
    let hole = Feature(name: "Foro", kind: .hole(HoleSpec(centers: [Vec3(0, 0, 10)], fit: .manual, diameter: 6)), operation: .cut)
    let mouth = refs([plate, hole], { e in e.faces.contains { $0.rawValue.contains("bore") } && e.polyline.allSatisfy { abs($0.z - 10) < 1e-9 } })
    let drilled = DesignEvaluator.evaluate(CADDocument(features: [plate, hole]), revision: "r").bodies[0].mesh.volume
    let (m2, i2, _) = chamfered([plate, hole], ChamferSpec(edges: mouth, profile: .round, distance: 1))
    #expect(i2.isEmpty && MeshValidator.validate(m2).isWatertight)
    let expected2 = 2 * .pi * (3 + centroid) * (1 - .pi / 4)
    #expect(abs((drilled - m2.volume) - expected2) < expected2 * 0.05)
}

@Test func roundDecodesOldChamfers() throws {
    let json = #"{"edges":[],"mode":"equalDistance","distance":1,"distance2":1,"angle":45,"flip":false}"#
    let spec = try JSONDecoder().decode(ChamferSpec.self, from: Data(json.utf8))
    #expect(spec.profile == .flat)
}

@Test func oversizedBevelIsReported() {
    let cube = Feature(name: "Cubo", kind: .box(width: 20, depth: 20, height: 20))
    let edge = refs([cube], { e in e.polyline.allSatisfy { abs($0.z - 20) < 1e-9 && abs($0.y + 10) < 1e-9 } })
    let (mesh, issues, _) = chamfered([cube], ChamferSpec(edges: edge, profile: .round, distance: 21))
    #expect(issues.contains { $0.message.contains("troppo grande") && $0.message.contains("20.0") })
    #expect(abs(mesh.volume - 8000) < 1e-6)
    let (_, ok, _) = chamfered([cube], ChamferSpec(edges: edge, profile: .round, distance: 20))
    #expect(ok.isEmpty)
    let boss = Feature(name: "Perno", kind: .cylinder(radius: 10, height: 3))
    let (_, tall, _) = chamfered([boss], ChamferSpec(edges: refs([boss], allAt(z: 3)), profile: .round, distance: 4))
    #expect(tall.contains { $0.message.contains("troppo grande") })
}

// MARK: Arcs in extruded sketches

@Test func profileArcsFindCirclesAndSlotEnds() {
    let circle = PrimitiveKernel.profileArcs(Profile2D.circle(radius: 10).points)
    #expect(circle.allSatisfy { $0?.index == 0 && abs($0!.radius - 10) < 1e-9 })
    let slot = SketchShape(kind: .slot(start: Vec2(0, 0), end: Vec2(30, 0), width: 10)).outline
    let arcs = PrimitiveKernel.profileArcs(Profile2D(points: slot).points)
    #expect(Set(arcs.compactMap { $0?.index }) == [0, 1] && arcs.filter { $0 == nil }.count == 2)
    #expect(PrimitiveKernel.profileArcs(Profile2D.regularPolygon(sides: 6, radius: 10).points).allSatisfy { $0 == nil })
    #expect(PrimitiveKernel.profileArcs(Profile2D.rectangle(width: 10, height: 5).points).allSatisfy { $0 == nil })
    #expect(Profile2D.circle(radius: 11).entitiesDescription == "Cerchio Ø22")
    #expect(Profile2D(points: slot).entitiesDescription == "2 linee, 2 archi")
    #expect(Profile2D.rectangle(width: 10, height: 5).entitiesDescription == "4 linee")
}

@Test func roundOnExtrudedSketchCircleTakesTheWholeRim() {
    // A sketch circle extruded is a cylinder: one wall face, one rim edge, filleted all round.
    let disc = Feature(name: "Disco", kind: .extrude(profile: .circle(radius: 10), height: 20))
    let snap = DesignEvaluator.evaluate(CADDocument(features: [disc]), revision: "r").bodies[0].snapshot
    #expect(snap.faces.count == 3 && snap.edges.count == 2)
    #expect(snap.faces.contains { if case let .cylinder(_, _, r) = $0.surface { abs(r - 10) < 1e-9 } else { false } })
    let rim = refs([disc], allAt(z: 20))
    #expect(rim.count == 1)
    let (mesh, issues, after) = chamfered([disc], ChamferSpec(edges: rim, profile: .round, distance: 2))
    #expect(issues.isEmpty && MeshValidator.validate(mesh).isWatertight)
    let centroid = (10 - 3 * Double.pi) / (12 - 3 * Double.pi)
    let expected = 2 * .pi * (10 - 2 * centroid) * 4 * (1 - .pi / 4)
    #expect(abs((Profile2D.circle(radius: 10).area * 20 - mesh.volume) - expected) < expected * 0.03)
    #expect(after?.faces.contains { if case .torus = $0.surface { true } else { false } } == true)
    // A slot: two arc walls, two flat sides, and no crease where they meet tangentially.
    let slot = Feature(name: "Asola", kind: .extrude(profile: SketchShape(kind: .slot(start: Vec2(0, 0), end: Vec2(30, 0), width: 10)).profile!, height: 5))
    let s = DesignEvaluator.evaluate(CADDocument(features: [slot]), revision: "r").bodies[0].snapshot
    #expect(s.faces.count == 6 && s.edges.count == 8)
}

@Test func tangentChainFollowsSmoothJoints() {
    // Slot top: line, arc, line, arc all tangent → one chain of 4; a box top edge has no tangent neighbours.
    let slot = Feature(name: "Asola", kind: .extrude(profile: SketchShape(kind: .slot(start: Vec2(0, 0), end: Vec2(30, 0), width: 10)).profile!, height: 5))
    let s = DesignEvaluator.evaluate(CADDocument(features: [slot]), revision: "r").bodies[0].snapshot
    let top = s.edges.filter { $0.polyline.allSatisfy { abs($0.z - 5) < 1e-9 } }
    #expect(top.count == 4)
    #expect(Set(s.tangentChain(of: top[0].id)) == Set(top.map(\.id)))
    let b = DesignEvaluator.evaluate(CADDocument(features: [base]), revision: "r").bodies[0].snapshot
    let edge = b.edges.first { $0.polyline.allSatisfy { abs($0.z - 5) < 1e-9 } }!
    #expect(b.tangentChain(of: edge.id) == [edge.id])
    // The rounded slot top in one feature: closed and lighter by the swept quarter-round.
    let refsTop = top.compactMap(EdgeRef.init)
    let (mesh, issues, _) = chamfered([slot], ChamferSpec(edges: refsTop, profile: .round, distance: 1))
    #expect(issues.isEmpty, "\(issues.map(\.message))")
    #expect(MeshValidator.validate(mesh).isWatertight)
    // Removed: a quarter round along both 30 mm sides plus one full turn (two half rings) at r = 5.
    let before = SketchShape(kind: .slot(start: Vec2(0, 0), end: Vec2(30, 0), width: 10)).profile!.area * 5
    let centroid = (10 - 3 * Double.pi) / (12 - 3 * Double.pi)
    let expected = 60 * roundArea(1) + 2 * .pi * (5 - centroid) * (1 - .pi / 4)
    #expect(abs((before - mesh.volume) - expected) < expected * 0.03, "\(before - mesh.volume) vs \(expected)")
}

@Test func roundsAndBevelsOnABevelsCone() {
    // A 45° bevel on a cylinder's rim leaves a cone: its edges with the top and with the wall can
    // be rounded or bevelled in turn (rounds on rounds).
    let boss = Feature(name: "Perno", kind: .cylinder(radius: 20, height: 20))
    let bevel = Feature(name: "S", kind: .chamfer(ChamferSpec(edges: refs([boss], allAt(z: 20)), distance: 6)), operation: .cut)
    let (bevelled, i0, snap) = chamfered([boss], ChamferSpec(edges: refs([boss], allAt(z: 20)), distance: 6))
    #expect(i0.isEmpty && MeshValidator.validate(bevelled).isWatertight)
    let edges = DesignEvaluator.evaluate(CADDocument(features: [boss, bevel]), revision: "r").bodies[0].snapshot.edges
    let topRim = edges.filter { $0.polyline.allSatisfy { abs($0.z - 20) < 1e-6 } }.compactMap(EdgeRef.init)
    let wallRim = edges.filter { $0.polyline.allSatisfy { abs($0.z - 14) < 1e-6 } }.compactMap(EdgeRef.init)
    #expect(topRim.count == 1 && wallRim.count == 1)
    for (edge, profile) in [(topRim, ChamferSpec.Profile.round), (wallRim, .round), (wallRim, .flat)] {
        let (mesh, issues, after) = chamfered([boss, bevel], ChamferSpec(edges: edge, profile: profile, distance: 2))
        #expect(issues.isEmpty, "\(issues.map(\.message))")
        #expect(MeshValidator.validate(mesh).isWatertight)
        // Something small comes off the 135° edge: less than the whole corner ring.
        let removed = bevelled.volume - mesh.volume
        #expect(removed > 0.5 && removed < 2 * .pi * 20 * 2 * 2)
        if profile == .round { #expect(after?.faces.contains { if case .torus = $0.surface { true } else { false } } == true) }
    }
    _ = snap
}

@Test func roundsAndChamfersOnACrossHoleMouth() throws {
    // A shaft Ø20 cross-drilled Ø6: the hole's mouths are curves between two cylinders (not
    // circles). Rounds and chamfers on them: the ball rolled on the true surfaces, closed solids.
    let shaft = Feature(name: "Albero", kind: .cylinder(radius: 10, height: 40))
    let cross = Feature(name: "Foro", kind: .hole(HoleSpec(centers: [Vec3(-15, 0, 20)], direction: Vec3(1, 0, 0), fit: .manual, diameter: 6)), operation: .cut)
    let base = DesignEvaluator.evaluate(CADDocument(features: [shaft, cross]), revision: "a").bodies[0]
    let mouths = base.snapshot.edges.filter { e in e.faces.contains { $0.rawValue.contains("bore") } }
    #expect(mouths.count == 2)
    var removed: [String: Double] = [:]
    for profile in [ChamferSpec.Profile.round, .flat] {
        for size in [0.5, 1.0] {
            let spec = ChamferSpec(edges: mouths.compactMap(EdgeRef.init), profile: profile, distance: size)
            let r = DesignEvaluator.evaluate(CADDocument(features: [shaft, cross, Feature(name: "R", kind: .chamfer(spec))]), revision: "\(profile)\(size)")
            #expect(r.issues.isEmpty, "\(profile) \(size): \(r.issues)")
            let body = try #require(r.bodies.first)
            #expect(MeshValidator.validate(body.mesh).isWatertight, "\(profile) \(size): closed")
            let gone = base.mesh.volume - body.mesh.volume
            // About the section (r²(1 − π/4) round, d²/2 chamfer at a right angle) times the two
            // mouths' length (~2 × 20 mm), the angle between the walls varying around them.
            let section = profile == .round ? size * size * (1 - .pi / 4) : size * size / 2
            #expect(gone > section * 40 * 0.5 && gone < section * 40 * 2.5, "\(profile) \(size): \(gone) mm³ removed")
            removed["\(profile)\(size)"] = gone
        }
    }
    // Twice the size, about four times the material.
    #expect(abs(removed["round1.0"]! / removed["round0.5"]! - 4) < 1)
}

@Test func edgeChainsAreTheSameEveryRun() throws {
    // Two mouths between the same two faces: their order and starting points must not depend on
    // how a dictionary happens to be ordered (they were renumbered from run to run).
    let shaft = Feature(name: "Albero", kind: .cylinder(radius: 10, height: 40))
    let cross = Feature(name: "Foro", kind: .hole(HoleSpec(centers: [Vec3(-15, 0, 20)], direction: Vec3(1, 0, 0), fit: .manual, diameter: 6)), operation: .cut)
    let edges = DesignEvaluator.evaluate(CADDocument(features: [shaft, cross]), revision: "e").bodies[0].snapshot.edges
    let mouths = edges.filter { e in e.faces.contains { $0.rawValue.contains("bore") } }
    #expect(mouths.count == 2 && mouths[0].polyline.first!.x < 0 && mouths[1].polyline.first!.x > 0
            || mouths.count == 2 && mouths[0].polyline.first!.x > 0 && mouths[1].polyline.first!.x < 0)
    // The same evaluation again gives exactly the same chains.
    let again = DesignEvaluator.evaluate(CADDocument(features: [shaft, cross]), revision: "e2").bodies[0].snapshot.edges
    #expect(again.map(\.id) == edges.map(\.id) && again.map(\.polyline) == edges.map(\.polyline))
}
