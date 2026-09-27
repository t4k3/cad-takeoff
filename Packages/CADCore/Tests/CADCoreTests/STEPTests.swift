import Foundation
import Testing
@testable import CADCore

/// A minimal ISO 10303-21 reader: entity text by id.
private func entities(_ step: String) -> [Int: String] {
    var out: [Int: String] = [:]
    for line in step.split(separator: "\n") where line.hasPrefix("#") {
        guard let eq = line.firstIndex(of: "="), let id = Int(line[line.index(after: line.startIndex)..<eq]) else { continue }
        out[id] = String(line[line.index(after: eq)...].dropLast())
    }
    return out
}

private func refs(_ text: String) -> [Int] {
    var out: [Int] = [], digits = "", inRef = false
    for ch in text {
        if ch == "#" { inRef = true; digits = ""; continue }
        if inRef, ch.isNumber { digits.append(ch); continue }
        if inRef, let n = Int(digits) { out.append(n) }
        inRef = false
    }
    if inRef, let n = Int(digits) { out.append(n) }
    return out
}

/// Checks a solid's topology: references resolve, every edge is used once each way, and the
/// Euler–Poincaré count V − E + F − (L − F) = 2 − 2·genus.
private func check(_ step: String, genus: Int, faces expectedFaces: Int? = nil) {
    let e = entities(step)
    for (_, text) in e { for r in refs(text) { #expect(e[r] != nil, "missing #\(r)") } }
    func named(_ prefix: String) -> [Int: String] { e.filter { $0.value.hasPrefix(prefix + "(") } }
    let curves = named("EDGE_CURVE"), vertices = named("VERTEX_POINT"), faces = named("ADVANCED_FACE"), loops = named("EDGE_LOOP")
    var uses: [Int: [String]] = [:]
    for (_, text) in named("ORIENTED_EDGE") {
        let curve = refs(text).last!
        uses[curve, default: []].append(text.hasSuffix(".T.)") ? "T" : "F")
    }
    #expect(uses.count == curves.count)
    #expect(uses.values.allSatisfy { $0.sorted() == ["F", "T"] })
    let chi = vertices.count - curves.count + faces.count - (loops.count - faces.count)
    #expect(chi == 2 - 2 * genus, "V \(vertices.count) E \(curves.count) F \(faces.count) L \(loops.count)")
    if let expectedFaces { #expect(faces.count == expectedFaces) }
}

@Test func stepOfABoxHasSixFacesTwelveEdgesAndItsColour() throws {
    let box = Feature(name: "Piastra «prova»", kind: .box(width: 40, depth: 30, height: 5), color: PartColor(red: 255, green: 0, blue: 0))
    let step = try STEPExporter.export(STEPExporter.parts(of: CADDocument(features: [box])), name: "Prova", date: Date(timeIntervalSince1970: 0))
    #expect(step.hasPrefix("ISO-10303-21;") && step.contains("FILE_SCHEMA(('AUTOMOTIVE_DESIGN"))
    #expect(step.contains("SI_UNIT(.MILLI.,.METRE.)") && step.contains("COLOUR_RGB('',1.,0.,0.)"))
    #expect(step.contains("MANIFOLD_SOLID_BREP('Piastra \\X2\\00AB\\X0\\prova\\X2\\00BB\\X0\\'"))
    check(step, genus: 0, faces: 6)
    #expect(entities(step).values.filter { $0.hasPrefix("EDGE_CURVE(") }.count == 12)
}

@Test func stepKeepsHolesInFacesAndFacetsCurvedWalls() throws {
    let plate = Feature(name: "Piastra", kind: .box(width: 40, depth: 30, height: 5))
    let hole = Feature(name: "Foro", kind: .cylinder(radius: 4, height: 10), position: Vec3(0, 0, -2), operation: .cut)
    let step = try STEPExporter.export(STEPExporter.parts(of: CADDocument(features: [plate, hole])))
    // Top and bottom are one face each with the hole as an inner bound; the bore is one exact
    // cylinder bounded by two circles.
    let e = entities(step)
    #expect(e.values.filter { $0.hasPrefix("CYLINDRICAL_SURFACE(") }.count == 1)
    #expect(e.values.filter { $0.hasPrefix("CIRCLE(") }.count == 2)
    #expect(e.values.contains { $0.hasPrefix("CYLINDRICAL_SURFACE(") && $0.hasSuffix(",4.)") })
    check(step, genus: 1, faces: 7)
    // Several bodies: one solid each.
    let other = Feature(name: "Perno", kind: .cylinder(radius: 3, height: 12), position: Vec3(50, 0, 0))
    let two = try STEPExporter.export(STEPExporter.parts(of: CADDocument(features: [plate, other])))
    #expect(entities(two).values.filter { $0.hasPrefix("MANIFOLD_SOLID_BREP(") }.count == 2)
    #expect(throws: KernelError.self) { try STEPExporter.export([]) }
}

@Test func stepOfARoundedPartIsClosed() throws {
    let box = Feature(name: "B", kind: .box(width: 30, depth: 20, height: 10))
    let snap = DesignEvaluator.evaluate(CADDocument(features: [box]), revision: "a").bodies[0].snapshot
    let round = Feature(name: "R", kind: .chamfer(ChamferSpec(edges: snap.edges.compactMap(EdgeRef.init), profile: .round, distance: 2)))
    let step = try STEPExporter.export(STEPExporter.parts(of: CADDocument(features: [box, round])))
    check(step, genus: 0)
}

@Test func stepWritesRoundsAndBevelsOnCirclesExactly() throws {
    let cup = Feature(name: "Tazza", kind: .cylinder(radius: 10, height: 20))
    let rims = DesignEvaluator.evaluate(CADDocument(features: [cup]), revision: "a").bodies[0].snapshot.edges.compactMap(EdgeRef.init)
    for (profile, surface) in [(ChamferSpec.Profile.round, "TOROIDAL_SURFACE("), (.flat, "CONICAL_SURFACE(")] {
        let doc = CADDocument(features: [cup, Feature(name: "R", kind: .chamfer(ChamferSpec(edges: rims, profile: profile, distance: 2)))])
        let step = try STEPExporter.export(STEPExporter.parts(of: doc))
        let e = entities(step)
        // Two caps, the wall and the two rounds or bevels: five exact faces.
        #expect(e.values.filter { $0.hasPrefix(surface) }.count == 2)
        #expect(e.values.filter { $0.hasPrefix("CYLINDRICAL_SURFACE(") }.count == 1)
        check(step, genus: 0, faces: 5)
    }
}

/// Where two exact surfaces meet on a curve that is neither a line nor a circle (a cross hole
/// through a shaft, a plane across a cylinder), both stay exact and the curve is a cubic
/// B-spline through points on both surfaces (docs/SUPERFICI_ESATTE.md, tappa 3).
@Test func stepWritesCrossHolesAndObliqueCutsExactly() throws {
    let shaft = Feature(name: "Albero", kind: .cylinder(radius: 10, height: 40))
    let cross = Feature(name: "Foro", kind: .hole(HoleSpec(centers: [Vec3(-15, 0, 20)], direction: Vec3(1, 0, 0), fit: .manual, diameter: 6)), operation: .cut)
    let step = try STEPExporter.export(STEPExporter.parts(of: CADDocument(features: [shaft, cross])), name: "Albero", date: Date(timeIntervalSince1970: 0))
    let values = entities(step).values
    // Two ends, the shaft's wall, the hole's wall: four faces, two exact cylinders, two crossing curves.
    check(step, genus: 1, faces: 4)
    #expect(values.filter { $0.hasPrefix("CYLINDRICAL_SURFACE(") }.count == 2)
    #expect(values.filter { $0.hasPrefix("B_SPLINE_CURVE_WITH_KNOTS(") }.count == 2)

    // A plane across the shaft at 45°: an ellipse, the wall still one exact cylinder.
    var wedge = Feature(name: "Taglio", kind: .box(width: 40, depth: 40, height: 20), operation: .cut)
    wedge.placement = FeaturePlacement(plane: SketchPlane(origin: Vec3(0, 0, 30), xAxis: Vec3(1, 0, 0), yAxis: Vec3(0, 1, 1).normalized))
    let cut = try STEPExporter.export(STEPExporter.parts(of: CADDocument(features: [shaft, wedge])), name: "Smusso", date: Date(timeIntervalSince1970: 0))
    check(cut, genus: 0, faces: 3)
    #expect(entities(cut).values.filter { $0.hasPrefix("B_SPLINE_CURVE_WITH_KNOTS(") }.count == 1)
}

@Test func pointsGoOntoTheTrueSurfacesAndSplinesThroughThem() throws {
    // Where a cylinder Ø20 (Z) and a cylinder Ø6 (X) meet, near a facets' point.
    let a = SurfaceDescriptor.cylinder(axisOrigin: .zero, axisDirection: Vec3(0, 0, 1), radius: 10)
    let b = SurfaceDescriptor.cylinder(axisOrigin: Vec3(0, 0, 20), axisDirection: Vec3(1, 0, 0), radius: 3)
    let q = try #require(SurfaceDescriptor.project(Vec3(9.9, 1.4, 22.5), onto: [a, b]))
    #expect(abs(a.signedDistance(q)!.d) < 1e-9 && abs(b.signedDistance(q)!.d) < 1e-9 && (q - Vec3(9.9, 1.4, 22.5)).length < 0.3, "\(q)")
    // A torus and a plane and a sphere: each on its own.
    for s in [SurfaceDescriptor.torus(center: .zero, axisDirection: Vec3(0, 0, 1), majorRadius: 10, minorRadius: 2),
              .sphere(center: Vec3(1, 2, 3), radius: 4), .cone(apex: .zero, axisDirection: Vec3(0, 0, 1), halfAngle: 0.5)] {
        let p = try #require(SurfaceDescriptor.project(Vec3(7, 3, 2), onto: [s]))
        #expect(abs(s.signedDistance(p)!.d) < 1e-9)
    }
    // Two parallel planes never meet.
    #expect(SurfaceDescriptor.project(.zero, onto: [.plane(origin: .zero, normal: Vec3(0, 0, 1)), .plane(origin: Vec3(0, 0, 1), normal: Vec3(0, 0, 1))]) == nil)
    // The spline passes through the points it interpolates.
    let pts = (0...20).map { k -> Vec3 in let t = Double(k) / 20 * .pi; return Vec3(cos(t) * 5, sin(t) * 5, t) }
    let spline = try #require(CubicInterpolation(pts))
    #expect(spline.controls.first == pts.first && spline.controls.last == pts.last)
    #expect(spline.multiplicities.first == 4 && spline.multiplicities.last == 4 && spline.multiplicities.reduce(0, +) == pts.count + 4)
}
