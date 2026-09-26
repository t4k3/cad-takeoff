import Foundation
import Testing
@testable import CADCore

/// A 32-gon with coordinates rounded to 4 decimals, as the assistant writes them.
private func roundedCircle(_ c: Vec2, _ r: Double, _ n: Int = 32) -> [Vec2] {
    (0..<n).map { i in
        let t = Double(i) / Double(n) * 2 * .pi
        return Vec2(((c.x + r * cos(t)) * 1e4).rounded() / 1e4, ((c.y + r * sin(t)) * 1e4).rounded() / 1e4)
    }
}

@Test func roundedCoordinateCirclesAreOneWallAndTakeRounds() throws {
    // Once a crash: the arc found across the profile's first vertex.
    for r in [22.0, 33.0] {
        let f = Feature(name: "C", kind: .extrude(profile: Profile2D(points: roundedCircle(Vec2(140, 33), r)), height: 30))
        let snap = try PrimitiveKernel.build(f).snapshot(revision: "a")
        #expect(snap.faces.count == 3 && snap.edges.count == 2)
        var doc = CADDocument(features: [f])
        doc.features.append(Feature(name: "R", kind: .chamfer(ChamferSpec(edges: snap.edges.compactMap(EdgeRef.init), profile: .round, distance: 1.5))))
        let result = DesignEvaluator.evaluate(doc, revision: "b")
        #expect(result.issues.isEmpty && MeshValidator.validate(result.bodies[0].mesh).isWatertight)
    }
}

/// The sports car's body (made by the assistant): side profile with a long, almost flat roof and a
/// short nose, four wheel arches cut through. Rounding or bevelling every edge used to leave it open.
@Test func everyEdgeOfACarBodyRoundsClosed() throws {
    let side = SketchPlane(origin: Vec3(0, -95, 0), xAxis: Vec3(-1, 0, 0), yAxis: Vec3(0, 0, 1))
    let body = Feature(name: "Carrozzeria", kind: .extrude(profile: Profile2D(points: [
        Vec2(225, 72), Vec2(210, 81), Vec2(150, 80), Vec2(-60, 77), Vec2(-175, 70), Vec2(-222, 50), Vec2(-225, 35), Vec2(-215, 22), Vec2(225, 25),
    ]), height: 190), placement: FeaturePlacement(plane: side))
    var features = [body]
    for (y, xAxis) in [(-95.0, Vec3(1, 0, 0)), (95.0, Vec3(-1, 0, 0))] {
        for cx in [140.0, -140.0] {
            features.append(Feature(name: "Passaruota", kind: .extrude(profile: Profile2D(points: roundedCircle(Vec2(cx, 33), 38)), height: 40),
                                    operation: .cut, placement: FeaturePlacement(plane: SketchPlane(origin: Vec3(0, y, 0), xAxis: xAxis, yAxis: Vec3(0, 0, 1)), reversed: true)))
        }
    }
    let doc = CADDocument(features: features)
    let base = DesignEvaluator.evaluate(doc, revision: "a")
    #expect(base.issues.isEmpty && base.bodies.count == 1)
    let edges = base.bodies[0].snapshot.edges.filter(\.isSharp).compactMap(EdgeRef.init)
    for (profile, size) in [(ChamferSpec.Profile.round, 1.5), (.round, 3), (.round, 5), (.flat, 3)] {
        var d = doc
        d.features.append(Feature(name: "R", kind: .chamfer(ChamferSpec(edges: edges, profile: profile, distance: size))))
        let result = DesignEvaluator.evaluate(d, revision: "\(profile)\(size)")
        let report = MeshValidator.validate(result.bodies[0].mesh)
        #expect(report.isWatertight, "\(profile) \(size): \(report)")
        #expect(result.bodies[0].mesh.volume < base.bodies[0].mesh.volume)
    }
}
