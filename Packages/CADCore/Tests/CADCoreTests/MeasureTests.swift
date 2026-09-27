import Foundation
import Testing
@testable import CADCore

@Test func measureDistancesAndRoundEdges() throws {
    let a = Feature(name: "A", kind: .box(width: 20, depth: 20, height: 10))
    let b = Feature(name: "B", kind: .box(width: 20, depth: 20, height: 10), position: Vec3(35, 5, 3))   // 15 mm gap in X
    let hole = Feature(name: "Foro", kind: .cylinder(radius: 3, height: 20), position: Vec3(0, 0, -5), operation: .cut)
    let bodies = DesignEvaluator.evaluate(CADDocument(features: [a, hole, b]), revision: "m").bodies
    let sa = bodies.first { $0.id == a.id }!.snapshot, sb = bodies.first { $0.id == b.id }!.snapshot
    func face(_ s: BodySnapshot, normal n: Vec3) -> Measure.Shape {
        let f = s.faces.first { if case let .plane(_, m) = $0.surface { m.dot(n) > 0.999 } else { false } }!
        return Measure.shape(face: f.id, in: s)!
    }
    // Facing sides: 15 mm apart.
    let d = Measure.distance(face(sa, normal: Vec3(1, 0, 0)), face(sb, normal: Vec3(-1, 0, 0)))!
    #expect(abs(d.distance - 15) < 1e-9 && abs(d.to.x - d.from.x - 15) < 1e-9)
    // Top of A to the bottom of B: skew in space, the closest corners.
    let e = Measure.distance(face(sa, normal: Vec3(0, 0, 1)), face(sb, normal: Vec3(0, 0, -1)))!
    #expect(abs(e.distance - (15.0 * 15 + 7 * 7).squareRoot()) < 1e-9)
    // The hole's rim: Ø6, centred on the hole's axis.
    let rim = sa.edges.compactMap(Measure.circle(of:)).first!
    #expect(abs(rim.diameter - 6) < 1e-6 && abs(rim.centre.x) < 1e-6 && abs(abs(rim.axis.z) - 1) < 1e-9)
    // A straight edge is not a circle.
    #expect(sa.edges.filter { $0.polyline.count == 2 }.compactMap(Measure.circle(of:)).isEmpty)
}
