import Foundation
import Testing
@testable import CADCore

/// Area of an annular sector drawn with n chords (the folded body's bend section).
private func bendSection(_ r: Double, _ t: Double, _ theta: Double, _ n: Int) -> Double {
    Double(n) / 2 * sin(theta / Double(n)) * ((r + t) * (r + t) - r * r)
}

private func evaluate(_ spec: SheetMetalSpec, extra: [Feature] = []) -> (DesignEvaluator.Body?, [DesignEvaluator.Issue]) {
    let f = Feature(name: "Lamiera", kind: .sheetMetal(spec))
    let (bodies, issues) = DesignEvaluator.evaluate(CADDocument(features: [f] + extra), revision: "r")
    return (bodies.first, issues)
}

@Test func materialRulesFollowPressBrakePractice() throws {
    let dc01 = SheetMaterial.named("dc01")!
    #expect(dc01.vDie(thickness: 1) == 8 && dc01.insideRadius(thickness: 1) == 1.3 && dc01.minimumFlange(thickness: 1) == 6.5)
    #expect(dc01.vDie(thickness: 2) == 16 && dc01.insideRadius(thickness: 2) == 2.6)
    // DIN 6935: k = 0.65 + 0.5·log10(r/t), K = k/2 → r = t gives 0.325, r ≥ 5t gives 0.5.
    #expect(abs(SheetMaterial.kFactor(insideRadius: 2, thickness: 2) - 0.325) < 1e-12)
    #expect(SheetMaterial.kFactor(insideRadius: 20, thickness: 2) == 0.5)
    // Stainless springs back more (larger radius), hard 6082-T6 needs ≥ 3t.
    #expect(SheetMaterial.named("aisi304")!.insideRadius(thickness: 1.5) == 2.6)
    #expect(SheetMaterial.named("al6082")!.insideRadius(thickness: 2) == 6)
    #expect(SheetMaterial.named("s235")!.vDie(thickness: 5) == 50)
    let rule = try SheetMetalSpec(material: "dc01", thickness: 1).rule()
    #expect(rule.radiusIsDefault && abs(rule.kFactor - (0.65 + 0.5 * log10(1.3)) / 2) < 1e-12)
    let custom = try SheetMetalSpec(material: "dc01", thickness: 1, radiusOverride: 2, kOverride: 0.4).rule()
    #expect(custom.insideRadius == 2 && custom.kFactor == 0.4 && !custom.radiusIsDefault)
}

@Test func flatPlateIsAClosedBox() throws {
    let spec = SheetMetalSpec(material: "dc01", thickness: 2, width: 80, depth: 50)
    let build = try SheetMetalGeometry.build(spec, featureID: UUID())
    let mesh = build.folded.triangulated().mesh
    #expect(MeshValidator.validate(mesh).isWatertight && abs(mesh.volume - 8000) < 1e-6)
    #expect(build.flat.outline.count == 4 && abs(build.flat.area - 4000) < 1e-9 && build.flat.bends.isEmpty)
}

@Test func lBracketFromOutsideDimensions() throws {
    let spec = SheetMetalSpec(material: "dc01", thickness: 2, width: 40, depth: 60, flanges: [.front: SheetFlange(length: 30)])
    let build = try SheetMetalGeometry.build(spec, featureID: UUID())
    let r = 2.6, t = 2.0, k = build.rule.kFactor
    let mesh = build.folded.triangulated().mesh
    #expect(MeshValidator.validate(mesh).isWatertight)
    // Outside dimensions: 40 wide, 60 deep, 30 tall (outer mould lines).
    let b = mesh.bounds!
    #expect(abs(b.min.y + 30) < 1e-9 && abs(b.max.y - 30) < 1e-9 && abs(b.max.z - 30) < 1e-9 && abs(b.min.z) < 1e-9)
    let setback = r + t, straight = 30 - setback, plate = 60 - setback
    let volume = 40 * (plate * t + bendSection(r, t, .pi / 2, 16) + straight * t)
    #expect(abs(mesh.volume - volume) < 1e-6)
    // Blank: plate + bend allowance on the neutral line + straight flange.
    let allowance = .pi / 2 * (r + k * t)
    #expect(abs(build.flat.area - 40 * (plate + allowance + straight)) < 1e-9)
    #expect(build.flat.bends.count == 1 && build.flat.bends[0].tangents.count == 2)
    #expect(abs(build.flat.bends[0].line.0.y - (-30 + setback - allowance / 2)) < 1e-9)
    // Bends are real cylinders in the folded body.
    let body = evaluate(spec).0!
    #expect(body.snapshot.faces.contains { if case let .cylinder(_, _, radius) = $0.surface { abs(radius - (r + t)) < 1e-12 } else { false } })
}

@Test func trayWithFourFlangesAndDownBend() throws {
    var tray = SheetMetalSpec(material: "aisi304", thickness: 1.5, width: 120, depth: 80)
    for e in SheetEdge.allCases { tray[e] = SheetFlange(length: 20) }
    let build = try SheetMetalGeometry.build(tray, featureID: UUID())
    let mesh = build.folded.triangulated().mesh
    #expect(MeshValidator.validate(mesh).isWatertight)
    #expect(abs(mesh.bounds!.max.x - 60) < 1e-9 && abs(mesh.bounds!.max.z - 20) < 1e-9)
    #expect(build.flat.outline.count == 12 && build.flat.bends.count == 4)
    // Cross-shaped blank: plate + 4 strips, no overlap (open corners).
    let r = build.rule.insideRadius, t = 1.5, sb = r + t
    let reach = .pi / 2 * (r + build.rule.kFactor * t) + (20 - sb)
    let plateW = 120 - 2 * sb, plateD = 80 - 2 * sb
    #expect(abs(build.flat.area - (plateW * plateD + 2 * reach * plateW + 2 * reach * plateD)) < 1e-9)
    #expect(MeshValidator.validate(SheetMetalGeometry.flatMesh(build.flat)).isWatertight)

    let z = SheetMetalSpec(material: "dc01", thickness: 2, width: 40, depth: 60,
                           flanges: [.back: SheetFlange(length: 25, direction: .down)])
    let down = try SheetMetalGeometry.build(z, featureID: UUID()).folded.triangulated().mesh
    #expect(MeshValidator.validate(down).isWatertight)
    #expect(abs(down.bounds!.min.z - (2 - 25)) < 1e-9 && abs(down.bounds!.max.z - 2) < 1e-9)
}

@Test func workshopChecks() throws {
    // Shorter than the bend itself: impossible.
    let tiny = SheetMetalSpec(material: "dc01", thickness: 2, width: 40, depth: 60, flanges: [.front: SheetFlange(length: 4)])
    #expect(throws: SheetMetalError.self) { try SheetMetalGeometry.build(tiny, featureID: UUID()) }
    // Possible but below the press-brake minimum: warned.
    let short = SheetMetalSpec(material: "dc01", thickness: 2, width: 40, depth: 60, flanges: [.front: SheetFlange(length: 8)])
    let w = try SheetMetalGeometry.build(short, featureID: UUID()).warnings
    #expect(w.contains { $0.contains("minimo piegabile") && $0.contains("V16") })
    let hard = SheetMetalSpec(material: "al6082", thickness: 2, width: 40, depth: 60, flanges: [.front: SheetFlange(length: 20)], radiusOverride: 2)
    #expect(try SheetMetalGeometry.build(hard, featureID: UUID()).warnings.contains { $0.contains("cricche") })
    #expect(throws: SheetMetalError.self) { try SheetMetalSpec(material: "legno").rule() }
    let (_, issues) = evaluate(SheetMetalSpec(material: "dc01", thickness: 2, width: 5, depth: 5,
                                              flanges: [.front: SheetFlange(length: 20), .back: SheetFlange(length: 20)]))
    #expect(issues.contains { $0.message.contains("base troppo piccola") })
}

@Test func sheetMetalInTheDesign() throws {
    let spec = SheetMetalSpec(material: "dc01", thickness: 2, width: 40, depth: 60, flanges: [.front: SheetFlange(length: 30)])
    let sheet = Feature(name: "Staffa", kind: .sheetMetal(spec), position: Vec3(10, 0, 0))
    // A hole through the plate cuts the folded part like any body.
    let hole = Feature(name: "Foro", kind: .hole(HoleSpec(centers: [Vec3(10, 10, 2)], fit: .clearance, size: "M4")), operation: .cut)
    let (bodies, issues) = DesignEvaluator.evaluate(CADDocument(features: [sheet, hole]), revision: "r")
    #expect(issues.isEmpty && bodies.count == 1 && MeshValidator.validate(bodies[0].mesh).isWatertight)
    #expect(bodies[0].mesh.volume < sheet.buildMesh().volume - 30)
    let doc = CADDocument(features: [sheet])
    #expect(try CADDocument.decode(doc.encoded()) == doc)
    let dxf = SheetMetalDXF.export(try SheetMetalGeometry.build(spec, featureID: sheet.id).flat, rule: try spec.rule(), name: "Staffa")
    #expect(dxf.contains("BEND_UP") && dxf.contains("$INSUNITS") && dxf.hasSuffix("EOF\n"))
    #expect(dxf.components(separatedBy: "\nLINE\n").count - 1 == 3)
}

@Test func holesUnfoldIntoTheFlatPattern() throws {
    let spec = SheetMetalSpec(material: "dc01", thickness: 2, width: 40, depth: 60, flanges: [.front: SheetFlange(length: 30)])
    let build = try SheetMetalGeometry.build(spec, featureID: UUID())
    let r = 2.6, t = 2.0, y0 = -30 + r + t
    let allowance = Double.pi / 2 * (r + build.rule.kFactor * t)
    let onPlate = HoleSpec(centers: [Vec3(0, 10, 2)], fit: .clearance, size: "M4")
    // Drilled horizontally into the flange's outer face (y = −30), 15 mm up.
    let onFlange = HoleSpec(centers: [Vec3(5, -30, 15)], direction: Vec3(0, 1, 0), fit: .manual, diameter: 6)
    // Inside the bend zone: cannot be unfolded reliably.
    let onBend = HoleSpec(centers: [Vec3(0, -28.5, 1)], direction: Vec3(0, 1, 0), fit: .manual, diameter: 2)
    let (flat, skipped) = build.flat(adding: [onPlate, onFlange, onBend])
    #expect(skipped == 1 && flat.holes.count == 2)
    #expect(flat.holes[0].center == Vec2(0, 10) && flat.holes[0].diameter == 4.5)
    #expect(abs(flat.holes[1].center.x - 5) < 1e-9 && abs(flat.holes[1].center.y - (y0 - allowance - (15 - (r + t)))) < 1e-9)
    let mesh = SheetMetalGeometry.flatMesh(flat)
    #expect(MeshValidator.validate(mesh).isWatertight)
    #expect(abs(mesh.volume - flat.area * t) < 0.5)   // 64-gon holes vs true circles
    let dxf = SheetMetalDXF.export(flat, rule: build.rule, name: "Forata")
    #expect(dxf.components(separatedBy: "\nCIRCLE\n").count - 1 == 2)
}

@Test func closedCornersMakeABox() throws {
    var box = SheetMetalSpec(material: "dc01", thickness: 1.5, width: 120, depth: 80)
    for e in SheetEdge.allCases { box[e] = SheetFlange(length: 30) }
    box.corners = .closed
    let build = try SheetMetalGeometry.build(box, featureID: UUID())
    #expect(build.warnings.isEmpty)
    let r = build.rule.insideRadius, t = 1.5, sb = r + t, gap = 0.2
    let straight = 30 - sb, allowance = .pi / 2 * (r + build.rule.kFactor * t)
    let plateW = 120 - 2 * sb, plateD = 80 - 2 * sb
    // Front/back walls run on over the corners (to the side walls' outer face), the side walls
    // stop `gap` short of the front/back walls' inner face.
    let cover = sb, butt = sb - t - gap
    let mesh = build.folded.triangulated().mesh
    #expect(MeshValidator.validate(mesh).isWatertight)
    #expect(abs(mesh.bounds!.min.x + 60) < 1e-9 && abs(mesh.bounds!.max.y - 40) < 1e-9 && abs(mesh.bounds!.max.z - 30) < 1e-9)
    let bend = bendSection(r, t, .pi / 2, 16)
    let volume = plateW * plateD * t + 2 * plateW * (bend + straight * t) + 2 * plateD * (bend + straight * t)
        + 4 * cover * straight * t + 4 * butt * straight * t
    #expect(abs(mesh.volume - volume) < 1e-6)
    // Blank: the cross plus the run-on tabs, a square relief where the bends meet.
    let open = plateW * plateD + 2 * (allowance + straight) * (plateW + plateD)
    #expect(abs(build.flat.area - (open + 4 * cover * straight + 4 * butt * straight)) < 1e-9)
    #expect(build.flat.outline.count == 28)
    #expect(MeshValidator.validate(SheetMetalGeometry.flatMesh(build.flat)).isWatertight)
    #expect(abs(build.flat.size.width - (plateW + 2 * (allowance + straight))) < 1e-9)
    // A hole in a corner tab unfolds onto the tab.
    let x = -60 + sb / 2
    let (flat, skipped) = build.flat(adding: [HoleSpec(centers: [Vec3(x, -40, 20)], direction: Vec3(0, 1, 0), fit: .manual, diameter: 1)])
    #expect(skipped == 0 && abs(flat.holes[0].center.x - x) < 1e-9)
    #expect(abs(flat.holes[0].center.y - (-40 + sb - allowance - (20 - sb))) < 1e-9)

    // Only 90° flanges bent the same way close; others stay open with a note.
    box.left = SheetFlange(length: 30, angle: 60)
    box.back = SheetFlange(length: 30, direction: .down)
    let mixed = try SheetMetalGeometry.build(box, featureID: UUID())
    #expect(mixed.warnings.count == 3)
    #expect(MeshValidator.validate(mixed.folded.triangulated().mesh).isWatertight)
    // Old files (no corner style) stay open.
    let decoded = try JSONDecoder().decode(SheetMetalSpec.self, from: JSONEncoder().encode(SheetMetalSpec()))
    #expect(decoded.cornerStyle == .open && decoded.gap == 0.2)
}

@Test func cChannelLipsFromOutsideDimensions() throws {
    // C channel: 40 deep, 30 tall walls with 10 mm inward lips, all outside dimensions.
    let lip = SheetLip(length: 10)
    let spec = SheetMetalSpec(material: "dc01", thickness: 2, width: 60, depth: 40,
                              flanges: [.front: SheetFlange(length: 30, lip: lip), .back: SheetFlange(length: 30, lip: lip)])
    let build = try SheetMetalGeometry.build(spec, featureID: UUID())
    let r = 2.6, t = 2.0, k = build.rule.kFactor
    let mesh = build.folded.triangulated().mesh
    #expect(MeshValidator.validate(mesh).isWatertight)
    let b = mesh.bounds!
    #expect(abs(b.min.y + 20) < 1e-9 && abs(b.max.y - 20) < 1e-9 && abs(b.max.z - 30) < 1e-9 && abs(b.min.z) < 1e-9)
    // The lips' tips stand 10 in from the outside faces.
    #expect(mesh.vertices.contains { abs($0.y - (-20 + 10)) < 1e-9 && $0.z > 25 })
    // Each wall: plate-side setback, lip-side setback; each lip one setback.
    let setback = r + t, plate = 40 - 2 * setback, wall = 30 - 2 * setback, tip = 10 - setback
    let volume = 60 * (plate * t + 4 * bendSection(r, t, .pi / 2, 16) + 2 * (wall + tip) * t)
    #expect(abs(mesh.volume - volume) < 1e-6)
    let allowance = .pi / 2 * (r + k * t)
    #expect(abs(build.flat.area - 60 * (plate + 4 * allowance + 2 * (wall + tip))) < 1e-9)
    // Four bends, all up (the lips curl on the same way), the lips' beyond the walls'.
    #expect(build.flat.bends.count == 4 && build.flat.bends.allSatisfy { $0.direction == .up && $0.angle == 90 })
    let front = build.flat.bends.filter { $0.edge == .front }.map(\.line.0.y).sorted()
    #expect(front.count == 2 && abs(front[1] - front[0] - (allowance / 2 + wall + allowance / 2)) < 1e-9)
}

@Test func zLipAndHemFoldTheOtherWay() throws {
    let spec = SheetMetalSpec(material: "dc01", thickness: 1.5, width: 50, depth: 40,
                              flanges: [.front: SheetFlange(length: 25, lip: SheetLip(length: 12, inward: false)),
                                        .back: SheetFlange(length: 25, lip: SheetLip(length: 8, angle: 180))])
    let build = try SheetMetalGeometry.build(spec, featureID: UUID())
    let mesh = build.folded.triangulated().mesh
    #expect(MeshValidator.validate(mesh).isWatertight)
    // The Z lip turns outwards: 12 from the wall's far face (outside of its bend), so 12 − t past
    // the part's outside; the hem folds back inside the wall.
    let b = mesh.bounds!
    #expect(abs(b.min.y - (-20 - 12 + 1.5)) < 1e-9 && abs(b.max.y - 20) < 1e-9 && abs(b.max.z - 25) < 1e-9)
    let lips = build.flat.bends.filter { $0.angle != 90 || $0.direction == .down }
    #expect(build.flat.bends.contains { $0.edge == .front && $0.direction == .down } && lips.contains { $0.angle == 180 && $0.direction == .up })
    // A 180° hem: the lip's straight part is parallel to the wall, 2r from it (open hem).
    #expect(throws: SheetMetalError.self) { try SheetMetalGeometry.build(SheetMetalSpec(material: "dc01", thickness: 1.5, width: 50, depth: 40,
        flanges: [.front: SheetFlange(length: 25, lip: SheetLip(length: 3, angle: 180))]), featureID: UUID()) }
}

@Test func boxWithInwardLipsLeavesCornerReliefs() throws {
    let lip = SheetLip(length: 10)
    var flanges: [SheetEdge: SheetFlange] = [:]
    for e in SheetEdge.allCases { flanges[e] = SheetFlange(length: 20, lip: lip) }
    let spec = SheetMetalSpec(material: "dc01", thickness: 1, width: 80, depth: 60, flanges: flanges)
    let build = try SheetMetalGeometry.build(spec, featureID: UUID())
    let mesh = build.folded.triangulated().mesh
    #expect(MeshValidator.validate(mesh).isWatertight)
    // No overlap: the folded volume is the sum of the pieces (the side lips stop short of the front/back ones).
    let r = 1.3, t = 1.0, setback = r + t
    let x = 80 - 2 * setback, y = 60 - 2 * setback, wall = 20 - 2 * setback, tip = 10 - setback
    let sideLip = y - 2 * (tip + spec.gap)
    let bend = bendSection(r, t, .pi / 2, 16)
    let volume = x * y * t + 2 * x * (2 * bend + (wall + tip) * t) + 2 * y * (bend + wall * t) + 2 * sideLip * (bend + tip * t)
    #expect(abs(mesh.volume - volume) < 1e-6)
    #expect(build.flat.bends.count == 8)
    #expect(build.flat.bends.filter { $0.edge == .left }.map { abs($0.line.1.y - $0.line.0.y) }.sorted().first.map { abs($0 - sideLip) < 1e-9 } == true)
}

@Test func sketchCutsUnfoldOntoTheBlank() throws {
    // U channel: 100 wide, 40 deep, 30 tall walls; a 30 × 10 window in the plate, a slot and a
    // round cut in the front wall, one cut crossing the bend (skipped).
    let spec = SheetMetalSpec(material: "dc01", thickness: 2, width: 100, depth: 40,
                              flanges: [.front: SheetFlange(length: 30), .back: SheetFlange(length: 30)])
    let build = try SheetMetalGeometry.build(spec, featureID: UUID(), folded: false)
    let window = SheetCutout(outline: [Vec3(-15, -5, 2), Vec3(15, -5, 2), Vec3(15, 5, 2), Vec3(-15, 5, 2)], axis: Vec3(0, 0, -1))
    // Front wall: outer face y = −20, cut along +Y; a slot 20 × 6 at height 15–21.
    let slot = SheetCutout(outline: [Vec3(-10, -20, 15), Vec3(10, -20, 15), Vec3(10, -20, 21), Vec3(-10, -20, 21)], axis: Vec3(0, 1, 0))
    let round = SheetCutout(outline: (0..<32).map { k in let a = Double(k) / 32 * 2 * .pi; return Vec3(30 + 4 * cos(a), -20, 18 + 4 * sin(a)) },
                            axis: Vec3(0, 1, 0))
    let crossing = SheetCutout(outline: [Vec3(-5, -25, 5), Vec3(5, -25, 5), Vec3(5, -15, 5), Vec3(-5, -15, 5)], axis: Vec3(0, 0, -1))
    let (flat, skipped) = build.flat(adding: [], cutouts: [window, slot, round, crossing])
    #expect(skipped == 1 && flat.cutouts.count == 2 && flat.holes.count == 1)
    // The window stays where it is on the plate; the slot lands on the front strip, the height
    // from the plate's outer face becoming the distance out along the strip.
    #expect(flat.cutouts[0].contains(Vec2(-15, -5)) && abs(Profile2D(points: flat.cutouts[0]).area.magnitude - 300) < 1e-9)
    let r = build.rule.insideRadius, t = 2.0
    let yPlate = -20 + r + t   // the plate's front tangent line
    let slotY = flat.cutouts[1].map(\.y)
    let expected = yPlate - build.rule.allowance(angleDegrees: 90) - (15 - (r + t))
    #expect(abs(slotY.max()! - expected) < 1e-9 && abs(slotY.max()! - slotY.min()! - 6) < 1e-9)
    #expect(abs(flat.holes[0].diameter - 8) < 1e-6 && abs(flat.holes[0].center.x - 30) < 1e-6)
    #expect(abs(flat.area - (build.flat.area - 300 - 120 - .pi * 16)) < 0.05)
    // The laser file and the blank solid carry them.
    let dxf = SheetMetalDXF.export(flat, rule: build.rule, name: "U")
    #expect(dxf.components(separatedBy: "LWPOLYLINE").count - 1 == 3 && dxf.contains("CIRCLE"))
    #expect(MeshValidator.validate(SheetMetalGeometry.flatMesh(flat)).isWatertight)
}

@Test func notchesAtTheEdgeComeOutOfTheBlank() throws {
    let spec = SheetMetalSpec(material: "dc01", thickness: 2, width: 100, depth: 40,
                              flanges: [.front: SheetFlange(length: 30), .back: SheetFlange(length: 30)])
    let build = try SheetMetalGeometry.build(spec, featureID: UUID(), folded: false)
    // 10 × 5 bite out of the plate's right edge (no flange there), and out of the front wall's top.
    let plateNotch = SheetCutout(outline: [Vec3(45, -5, 2), Vec3(55, -5, 2), Vec3(55, 5, 2), Vec3(45, 5, 2)], axis: Vec3(0, 0, -1))
    let wallNotch = SheetCutout(outline: [Vec3(-5, -20, 25), Vec3(5, -20, 25), Vec3(5, -20, 35), Vec3(-5, -20, 35)], axis: Vec3(0, 1, 0))
    // Running off the plate's front edge would cut the bend: skipped.
    let intoBend = SheetCutout(outline: [Vec3(-5, -15, 2), Vec3(5, -15, 2), Vec3(5, -25, 2), Vec3(-5, -25, 2)], axis: Vec3(0, 0, -1))
    let (flat, skipped) = build.flat(adding: [], cutouts: [plateNotch, wallNotch, intoBend])
    #expect(skipped == 1 && flat.cutouts.isEmpty)
    #expect(flat.outline.count == build.flat.outline.count + 8)
    #expect(abs(flat.area - (build.flat.area - 50 - 50)) < 1e-9)
    #expect(Profile2D(points: flat.outline).area > 0)
    #expect(flat.outline.contains(Vec2(45, 5)) && flat.outline.contains(Vec2(45, -5)))
}
