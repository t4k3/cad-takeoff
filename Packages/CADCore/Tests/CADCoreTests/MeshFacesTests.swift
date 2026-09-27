import Foundation
import Testing
@testable import CADCore

/// A part as the Fusion add-in brings it: one welded triangle mesh, far from the origin, with the
/// coordinates rounded to float precision.
private func imported(_ features: [Feature], offset: Vec3 = Vec3(250.123, -180.77, 33.3)) -> (solid: CSGSolid, snapshot: BodySnapshot) {
    let body = DesignEvaluator.evaluate(CADDocument(features: features), revision: "k").bodies[0]
    var soup: [Vec3] = []
    for t in 0..<body.mesh.triangleCount { let (a, b, c) = body.mesh.triangle(t); soup += [a, b, c].map { $0 + offset } }
    let mesh = ImportedMesh(mesh: MeshImport.welded(soup), source: "Fusion").mesh
    let f = Feature(name: "Importato", kind: .importedMesh(ImportedMesh(mesh: mesh, source: "Fusion")))
    let b = DesignEvaluator.evaluate(CADDocument(features: [f]), revision: "m").bodies[0]
    return (MeshFaces.solid(mesh, featureID: f.id), b.snapshot)
}

@Test func importedPlateKeepsWholeFlatFacesAndRoundHoles() throws {
    let plate = Feature(name: "Piastra", kind: .box(width: 80, depth: 60, height: 8))
    let hole = Feature(name: "Foro", kind: .cylinder(radius: 5, height: 20), position: Vec3(-15, 10, -2), operation: .cut)
    let boss = Feature(name: "Perno", kind: .cylinder(radius: 6, height: 12), position: Vec3(20, -10, 8), operation: .join)
    let (_, s) = imported([plate, hole, boss])
    func planes(_ n: Vec3) -> [FaceInfo] {
        s.faces.filter { if case let .plane(_, m) = $0.surface { m.normalized.dot(n) > 0.999 } else { false } }
    }
    // Top of the plate (with the hole in it and the boss on it) is one face; so is the bottom.
    #expect(planes(Vec3(0, 0, 1)).count == 2)   // plate top and boss top
    #expect(planes(Vec3(0, 0, -1)).count == 1)
    #expect(s.faces.filter { if case .freeform = $0.surface { true } else { false } }.isEmpty)
    // The hole and the boss are cylinders with their radius and axis.
    let cylinders = s.faces.compactMap { f -> (Vec3, Vec3, Double)? in if case let .cylinder(o, a, r) = f.surface { (o, a, r) } else { nil } }
    #expect(cylinders.count == 2)
    for (o, a, r) in cylinders {
        #expect(abs(abs(a.normalized.z) - 1) < 1e-6)
        let centre = r < 5.5 ? Vec3(-15 + 250.123, 10 - 180.77, 0) : Vec3(20 + 250.123, -10 - 180.77, 0)
        #expect(abs(r - (r < 5.5 ? 5 : 6)) < 1e-3, "r \(r) o \(o)")
        #expect(abs(o.x - centre.x) < 1e-3 && abs(o.y - centre.y) < 1e-3)
    }
    // Every flat face gives a sketch plane.
    for f in s.faces { if case .plane = f.surface { #expect(s.flatPlane(of: f.id) != nil) } }
}

@Test func noisyExportStillGivesWholeFaces() throws {
    // The same plate with every vertex moved by up to 2 µm (an exporter's rounding): the faces
    // must not break up into patches or freeform bits.
    let plate = Feature(name: "Piastra", kind: .box(width: 120, depth: 70, height: 6))
    let holes = (0..<4).map { k in Feature(name: "F", kind: .cylinder(radius: 3, height: 20), position: Vec3(-45 + 30 * Double(k), 20, -2), operation: .cut) }
    let body = DesignEvaluator.evaluate(CADDocument(features: [plate] + holes), revision: "k").bodies[0]
    var soup: [Vec3] = []
    for t in 0..<body.mesh.triangleCount { let (a, b, c) = body.mesh.triangle(t); soup += [a, b, c] }
    var mesh = MeshImport.welded(soup)
    var seed: UInt64 = 42
    func noise() -> Double { seed = seed &* 6364136223846793005 &+ 1442695040888963407; return (Double(seed >> 11) / Double(1 << 53) - 0.5) * 4e-3 }
    mesh.vertices = mesh.vertices.map { $0 + Vec3(noise(), noise(), noise()) * 1e-3 + Vec3(310, 95, 12) }
    let f = Feature(name: "Importato", kind: .importedMesh(ImportedMesh(mesh: mesh, source: "Fusion")))
    let s = DesignEvaluator.evaluate(CADDocument(features: [f]), revision: "m").bodies[0].snapshot
    let up = s.faces.filter { if case let .plane(_, n) = $0.surface { n.normalized.z > 0.999 } else { false } }
    #expect(up.count == 1, "\(up.count) facce in su; \(s.faces.map { "\($0.surface)".prefix(8) })")
    #expect(s.faces.filter { $0.surface == .freeform }.isEmpty, "\(s.faces.map { "\($0.surface)".prefix(8) + " \(Int($0.area))" })")
    #expect(s.faces.filter { if case .cylinder = $0.surface { true } else { false } }.count == 4)
    #expect(s.faces.count == 6 + 4)
}
