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
