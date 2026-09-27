import Foundation
import Testing
@testable import CADCore

/// A part with every kind of curved piece: a cylinder rounded on its rim, a slot (arcs in an
/// extruded profile), a revolve with an arc in its profile, a drilled hole, a bent sheet.
private func part() throws -> CADDocument {
    let cylinder = Feature(name: "Cilindro", kind: .cylinder(radius: 20, height: 20))
    let slot: [Vec2] = (0...32).map { k in let a = -Double.pi / 2 + Double(k) / 32 * .pi; return Vec2(30 + 6 * cos(a), 6 * sin(a)) }
        + (0...32).map { k in let a = Double.pi / 2 + Double(k) / 32 * .pi; return Vec2(-30 + 6 * cos(a), 6 * sin(a)) }
    let slotFeature = Feature(name: "Asola", kind: .extrude(profile: Profile2D(points: slot), height: 4), position: Vec3(0, 60, 0))
    // A pin with a rounded shoulder: rectangle with an arc corner, turned about the Y axis of its sketch.
    var profile: [Vec2] = [Vec2(0, 0), Vec2(8, 0), Vec2(8, 10)]
    profile += (1...15).map { k in let a = Double(k) / 16 * .pi / 2; return Vec2(4 + 4 * cos(a), 10 + 4 * sin(a)) }
    profile += [Vec2(4, 14), Vec2(0, 14)]
    let pin = Feature(name: "Perno", kind: .revolve(RevolveSpec(profile: Profile2D(points: profile), axisStart: Vec2(0, 0), axisEnd: Vec2(0, 1))),
                      position: Vec3(80, 0, 0))
    let hole = Feature(name: "Foro", kind: .hole(HoleSpec(centers: [Vec3(10, 0, 20)], fit: .manual, diameter: 5)), operation: .cut)
    let sheet = Feature(name: "Staffa", kind: .sheetMetal(SheetMetalSpec(material: "dc01", thickness: 2, width: 40, depth: 60,
                                                                           flanges: [.front: SheetFlange(length: 20)])), position: Vec3(0, -80, 0))
    var doc = CADDocument(features: [cylinder, hole, slotFeature, pin, sheet])
    // The cylinder's top rim rounded R2.
    let rim = try #require(DesignEvaluator.evaluate(doc, revision: "r").bodies.first { $0.id == cylinder.id }?.snapshot.edges.first { e in
        e.faces.contains { $0.rawValue.hasSuffix("cylinder/wall") } && e.faces.contains { $0.rawValue.hasSuffix("cylinder/top") }
    })
    doc.features.append(Feature(name: "Raccordo", kind: .chamfer(ChamferSpec(edges: [try #require(EdgeRef(rim))], profile: .round, distance: 2))))
    return doc
}

@Test func finerTessellationKeepsEveryNameAndCloses() throws {
    let doc = try part()
    let standard = DesignEvaluator.evaluate(doc, revision: "s")
    let fine = Tessellation.$factor.withValue(4) { DesignEvaluator.evaluate(doc, revision: "f") }
    #expect(standard.issues.isEmpty && fine.issues.isEmpty, "\(standard.issues) \(fine.issues)")
    #expect(standard.bodies.count == 4 && fine.bodies.count == 4)
    for (s, f) in zip(standard.bodies, fine.bodies) {
        #expect(s.id == f.id)
        #expect(MeshValidator.validate(f.mesh).isWatertight, "\(f.source.name) chiuso anche fine")
        // Faces and edges keep their names: nothing saved depends on the tessellation.
        let sf = Set(s.snapshot.faces.map(\.id.rawValue)), ff = Set(f.snapshot.faces.map(\.id.rawValue))
        #expect(sf == ff, "\(f.source.name): facce \(sf.subtracting(ff).sorted().prefix(4)) → \(ff.subtracting(sf).sorted().prefix(4))")
        #expect(Set(s.snapshot.edges.map(\.id)) == Set(f.snapshot.edges.map(\.id)), "\(f.source.name): spigoli")
        #expect(f.mesh.triangleCount > 2 * s.mesh.triangleCount, "\(f.source.name): più fine")
        // Closer to the true shape (the facets cut the curved parts inside them).
        #expect(f.mesh.volume >= s.mesh.volume - 1e-6, "\(f.source.name): volume")
    }
    // A plain cylinder: the error on its volume falls with the square of the facet angle.
    let plain = CADDocument(features: [Feature(name: "C", kind: .cylinder(radius: 50, height: 10))])
    let exact = Double.pi * 2500 * 10
    let v1 = DesignEvaluator.evaluate(plain, revision: "a").bodies[0].mesh.volume
    let v4 = Tessellation.$factor.withValue(4) { DesignEvaluator.evaluate(plain, revision: "b").bodies[0].mesh.volume }
    #expect(abs(exact - v4) < abs(exact - v1) / 10)
    // Back at the interactive factor, the cache gives the model as before.
    #expect(DesignEvaluator.evaluate(plain, revision: "c").bodies[0].mesh.volume == v1)
}
