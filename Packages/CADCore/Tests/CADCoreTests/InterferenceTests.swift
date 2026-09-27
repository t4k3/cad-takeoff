import Foundation
import Testing
@testable import CADCore

@Test func interferenceFindsOverlapsButNotTouchingParts() throws {
    let a = Feature(name: "A", kind: .box(width: 20, depth: 20, height: 20))
    let b = Feature(name: "B", kind: .box(width: 20, depth: 20, height: 20), position: Vec3(10, 10, 10))       // overlaps 10³
    let c = Feature(name: "C", kind: .box(width: 20, depth: 20, height: 20), position: Vec3(0, 0, 20))        // rests on A
    let d = Feature(name: "D", kind: .cylinder(radius: 3, height: 40), position: Vec3(100, 0, 0))            // far away
    let pin = Feature(name: "Perno", kind: .cylinder(radius: 2, height: 30), position: Vec3(-5, -5, -5))   // through A
    let bodies = DesignEvaluator.evaluate(CADDocument(features: [a, b, c, d, pin]), revision: "i").bodies
    let clashes = Interference.check(bodies)
    let pairs = clashes.map { Set([$0.a, $0.b]) }
    #expect(pairs.contains([a.id, b.id]) && pairs.contains([a.id, pin.id]))
    #expect(!pairs.contains([a.id, c.id]) && !pairs.contains { $0.contains(d.id) })
    let ab = clashes.first { Set([$0.a, $0.b]) == [a.id, b.id] }!
    #expect(abs(ab.volume - 1000) < 1e-6)
    #expect((ab.centre - Vec3(5, 5, 15)).length < 1e-9)
    // B also reaches into C (it rises to z = 30).
    #expect(pairs.contains([b.id, c.id]))
}
