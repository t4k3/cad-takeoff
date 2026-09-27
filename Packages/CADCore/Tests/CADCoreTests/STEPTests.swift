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
    // Top and bottom are one face each with the hole as an inner bound; the bore is 64 facets.
    #expect(entities(step).values.filter { $0.hasPrefix("FACE_BOUND(") }.count == 2)
    check(step, genus: 1, faces: 6 + 64)
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
