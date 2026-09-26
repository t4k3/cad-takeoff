import Foundation
import Testing
@testable import CADCore

@Test func cachedEvaluationMatchesAFreshOne() {
    let plate = Feature(name: "Piastra", kind: .box(width: 60, depth: 40, height: 8))
    let holes = Feature(name: "Fori", kind: .hole(HoleSpec(centers: [Vec3(-20, -10, 8), Vec3(20, 10, 8)], style: .counterbore, fit: .clearance, size: "M4")), operation: .cut)
    var boss = Feature(name: "Perno", kind: .cylinder(radius: 5, height: 10), position: Vec3(0, 0, 8), operation: .join)
    let cache = EvaluationCache()
    func same(_ doc: CADDocument) -> Bool {
        let a = DesignEvaluator.evaluate(doc, revision: "r", cache: cache), b = DesignEvaluator.evaluate(doc, revision: "r")
        return a.bodies.count == b.bodies.count && a.issues == b.issues
            && zip(a.bodies, b.bodies).allSatisfy { abs($0.mesh.volume - $1.mesh.volume) < 1e-9 && $0.snapshot.faces.map(\.id) == $1.snapshot.faces.map(\.id) }
    }
    #expect(same(CADDocument(features: [plate, holes, boss])))
    // Editing the last step reuses the drilled plate.
    boss.kind = .cylinder(radius: 7, height: 10)
    let t = Date()
    #expect(same(CADDocument(features: [plate, holes, boss])))
    #expect(Date().timeIntervalSince(t) < 5)
    // Editing an earlier step invalidates what follows it.
    var wide = plate
    wide.kind = .box(width: 80, depth: 40, height: 8)
    #expect(same(CADDocument(features: [wide, holes, boss])))
    // A changed component file changes the result even with the same document.
    var part = CADDocument(features: [Feature(name: "B", kind: .box(width: 10, depth: 10, height: 10))])
    let assembly = CADDocument(features: [Feature(name: "C", kind: .component(ComponentRef(path: "p.ftk")))])
    let original = part
    let first = DesignEvaluator.evaluate(assembly, revision: "r", components: { _ in original }, cache: cache).bodies[0].mesh.volume
    part.features[0].kind = .box(width: 20, depth: 10, height: 10)
    let changed = part
    let second = DesignEvaluator.evaluate(assembly, revision: "r", components: { _ in changed }, cache: cache).bodies[0].mesh.volume
    #expect(abs(first - 1000) < 1e-9 && abs(second - 2000) < 1e-9)
}
