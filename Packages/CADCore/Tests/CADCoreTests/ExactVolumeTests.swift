import Foundation
import Testing
@testable import CADCore

@Test func exactVolumesOfCurvedPartsAt1e6() throws {
    // A shaft Ø20 × 40 cross-drilled Ø6: π·100·40 − ∫ 4·√(9 − y²)·√(100 − y²) dy.
    let shaft = Feature(name: "Albero", kind: .cylinder(radius: 10, height: 40))
    let cross = Feature(name: "Foro", kind: .hole(HoleSpec(centers: [Vec3(-15, 0, 20)], direction: Vec3(1, 0, 0), fit: .manual, diameter: 6)), operation: .cut)
    let exact = 12007.319325476717
    let doc = CADDocument(features: [shaft, cross])
    let facets = DesignEvaluator.evaluate(doc, revision: "a").bodies[0].mesh.volume
    #expect(abs(facets - exact) / exact > 1e-3)
    // At any resolution (the default and twice as fine): within 1e-6.
    for factor in [1, 2] {
        let v = Tessellation.$factor.withValue(factor) { DesignEvaluator.exactVolumes(doc, revision: "e\(factor)")[shaft.id] }
        #expect(abs(try #require(v) - exact) / exact < 1e-6, "factor \(factor): \(v ?? 0)")
    }
    // A plain cylinder and a flat-faced box: π r² h and w·d·h.
    let cyl = Feature(name: "C", kind: .cylinder(radius: 7, height: 12))
    let box = Feature(name: "B", kind: .box(width: 10, depth: 20, height: 30), position: Vec3(50, 0, 0))
    let v = DesignEvaluator.exactVolumes(CADDocument(features: [cyl, box]), revision: "c")
    #expect(abs(v[cyl.id]! - .pi * 49 * 12) / (.pi * 49 * 12) < 1e-6)
    #expect(abs(v[box.id]! - 6000) < 1e-9)
    // Face areas: the cylinder's wall 2π·7·12, its top π·49; the box's sides exact.
    let m = DesignEvaluator.exactMeasures(CADDocument(features: [cyl, box]), revision: "a")
    let faces = DesignEvaluator.evaluate(CADDocument(features: [cyl]), revision: "f").bodies[0].snapshot.faces
    let wall = try #require(faces.first { if case .cylinder = $0.surface { true } else { false } })
    let top = try #require(faces.first { if case let .plane(_, n) = $0.surface { n.z > 0.5 } else { false } })
    #expect(abs(m.faceAreas[cyl.id]![wall.id]! - 2 * .pi * 7 * 12) / (2 * .pi * 84) < 1e-6)
    #expect(abs(m.faceAreas[cyl.id]![top.id]! - .pi * 49) / (.pi * 49) < 1e-6)
    #expect(abs(wall.area - 2 * .pi * 7 * 12) / (2 * .pi * 84) > 1e-4)
}
