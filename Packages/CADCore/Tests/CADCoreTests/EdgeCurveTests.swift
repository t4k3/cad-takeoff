import Foundation
import Testing
@testable import CADCore

/// Every edge of a part made of planes, a hole and rounds knows its true curve: circles with
/// the exact centre and radius, lines — not the facets' polyline.
@Test func edgesKnowTheirTrueCurves() throws {
    let block = Feature(name: "Blocco", kind: .box(width: 60, depth: 40, height: 10), position: Vec3(0, 0, 0))
    let hole = Feature(name: "Foro", kind: .hole(HoleSpec(centers: [Vec3(10, 5, 10)], fit: .manual, diameter: 8)), operation: .cut)
    var doc = CADDocument(features: [block, hole])
    let first = try #require(DesignEvaluator.evaluate(doc, revision: "a").bodies.first)
    // Before rounding: the hole's rims are circles Ø8 centred on its axis, the block's edges lines.
    let rims = first.snapshot.edges.compactMap { e -> (Vec3, Vec3, Double)? in if case let .circle(c, a, r)? = e.curve { (c, a, r) } else { nil } }
    #expect(rims.count == 2 && rims.allSatisfy { abs($0.2 - 4) < 1e-9 && abs($0.0.x - 10) < 1e-9 && abs($0.0.y - 5) < 1e-9 && abs(abs($0.1.z) - 1) < 1e-12 },
            "\(rims)")
    #expect(Set(rims.map { ($0.0.z * 1e6).rounded() }) == [0, 10e6])
    #expect(first.snapshot.edges.filter { if case .line? = $0.curve { true } else { false } }.count == 12)
    #expect(first.snapshot.edges.allSatisfy { $0.curve != nil })

    // A round R2 on the hole's top rim: the round meets the top on a circle Ø12 and the bore on Ø8.
    let top = try #require(first.snapshot.edges.first { if case let .circle(c, _, _)? = $0.curve { abs(c.z - 10) < 1e-9 } else { false } })
    doc.features.append(Feature(name: "Raccordo", kind: .chamfer(ChamferSpec(edges: [try #require(EdgeRef(top))], profile: .round, distance: 2))))
    let rounded = try #require(DesignEvaluator.evaluate(doc, revision: "b").bodies.first)
    let circles = rounded.snapshot.edges.compactMap { e -> (Vec3, Double)? in if case let .circle(c, _, r)? = e.curve { (c, r) } else { nil } }
    #expect(circles.contains { abs($0.1 - 6) < 1e-9 && abs($0.0.z - 10) < 1e-9 }, "\(circles)")
    #expect(circles.contains { abs($0.1 - 4) < 1e-9 && abs($0.0.z - 8) < 1e-9 }, "\(circles)")
    // The facets' corners lie on the curve (points on a chord only near it).
    for e in rounded.snapshot.edges { if let c = e.curve { #expect(EdgeCurve.corners(e.polyline, tol: 1e-4).allSatisfy { c.distance($0) < 1e-4 }) } }

    // A cylinder and a copy of it 30 mm along X: the copy's rims are circles moved with it.
    let pin = Feature(name: "Perno", kind: .cylinder(radius: 5, height: 12), position: Vec3(100, 0, 0))
    let copy = Feature(name: "Serie", kind: .pattern(PatternSpec(body: pin.id, kind: .rectangular, countX: 2, spacingX: 30)))
    let pins = DesignEvaluator.evaluate(CADDocument(features: [pin, copy]), revision: "c").bodies
    let centres = pins.flatMap { $0.snapshot.edges }.compactMap { e -> Vec3? in if case let .circle(c, _, r)? = e.curve, abs(r - 5) < 1e-9 { c } else { nil } }
    #expect(Set(centres.map { Int(($0.x).rounded()) }) == [100, 130] && centres.count == 4, "\(centres)")
}

@Test func curvesBetweenSurfacesThatDoNotMeetInALineOrCircle() {
    // A plane across a cylinder at 45°: an ellipse — no exact curve claimed.
    let cyl = SurfaceDescriptor.cylinder(axisOrigin: .zero, axisDirection: Vec3(0, 0, 1), radius: 5)
    let tilted = SurfaceDescriptor.plane(origin: .zero, normal: Vec3(0, 1, 1).normalized)
    let ellipse = (0..<16).map { k -> Vec3 in let a = Double(k) / 16 * 2 * .pi; return Vec3(5 * cos(a), 5 * sin(a), -5 * sin(a)) }
    #expect(EdgeCurve.between(cyl, tilted, polyline: ellipse) == nil)
    // Two planes: their line, whichever order.
    let x = SurfaceDescriptor.plane(origin: Vec3(3, 0, 0), normal: Vec3(1, 0, 0)), z = SurfaceDescriptor.plane(origin: Vec3(0, 0, 2), normal: Vec3(0, 0, 1))
    let line = EdgeCurve.between(z, x, polyline: [Vec3(3, -1, 2), Vec3(3, 4, 2)])
    #expect(line?.distance(Vec3(3, 100, 2)) ?? 1 < 1e-9)
}
