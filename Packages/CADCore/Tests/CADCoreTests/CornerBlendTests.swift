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
        // Every edge takes it, except those too short for the size.
        #expect(result.issues.allSatisfy { $0.message.contains("troppo grande") }, "\(Set(result.issues.map(\.message)))")
        #expect(result.bodies[0].mesh.volume < base.bodies[0].mesh.volume)
    }
}

/// Rounds and bevels where a plane meets a cylinder along its length: an arch cut through the
/// underside of a block (convex edges) and a half-round boss lying on a plate (inside corners).
@Test func roundsAlongACylinderThatMeetsAPlane() throws {
    let block = Feature(name: "Blocco", kind: .box(width: 40, depth: 30, height: 20))
    let across = SketchPlane(origin: Vec3(0, 25, 3), xAxis: Vec3(1, 0, 0), yAxis: Vec3(0, 0, 1))
    let arch = Feature(name: "Arco", kind: .cylinder(radius: 8, height: 50), operation: .cut, placement: FeaturePlacement(plane: across))
    let doc = CADDocument(features: [block, arch])
    let base = DesignEvaluator.evaluate(doc, revision: "a")
    #expect(base.issues.isEmpty)
    let snap = base.bodies[0].snapshot
    let lines = snap.edges.filter { e in
        let kinds = e.faces.compactMap { id in snap.faces.first { $0.id == id }?.surface }
        return kinds.contains { if case .cylinder = $0 { true } else { false } } && kinds.contains { if case .plane = $0 { true } else { false } }
            && abs(e.polyline.first!.x - e.polyline.last!.x) < 1e-6 && abs(e.polyline.first!.y - e.polyline.last!.y) > 20
    }
    #expect(lines.count == 2)
    for (profile, size) in [(ChamferSpec.Profile.round, 1.0), (.round, 3), (.flat, 1.5)] {
        var d = doc
        d.features.append(Feature(name: "R", kind: .chamfer(ChamferSpec(edges: lines.compactMap(EdgeRef.init), profile: profile, distance: size))))
        let r = DesignEvaluator.evaluate(d, revision: "\(profile)\(size)")
        #expect(r.issues.isEmpty, "\(r.issues.map(\.message))")
        #expect(MeshValidator.validate(r.bodies[0].mesh).isWatertight)
        #expect(r.bodies[0].mesh.volume < base.bodies[0].mesh.volume)
    }

    // A half-round boss joined along a plate: filled inside corners add material.
    let plate = Feature(name: "Piastra", kind: .box(width: 40, depth: 30, height: 5))
    let along = SketchPlane(origin: Vec3(-20, 0, 5), xAxis: Vec3(0, 1, 0), yAxis: Vec3(0, 0, 1))
    let boss = Feature(name: "Tondo", kind: .cylinder(radius: 6, height: 40), operation: .join, placement: FeaturePlacement(plane: along))
    let doc2 = CADDocument(features: [plate, boss])
    let base2 = DesignEvaluator.evaluate(doc2, revision: "p")
    #expect(base2.issues.isEmpty && base2.bodies.count == 1)
    let snap2 = base2.bodies[0].snapshot
    let inside = snap2.edges.filter { e in
        let kinds = e.faces.compactMap { id in snap2.faces.first { $0.id == id }?.surface }
        return kinds.contains { if case .cylinder = $0 { true } else { false } }
            && e.polyline.allSatisfy { abs($0.z - 5) < 1e-6 } && abs(e.polyline.first!.x - e.polyline.last!.x) > 30
    }
    #expect(inside.count == 2)
    var d2 = doc2
    d2.features.append(Feature(name: "R", kind: .chamfer(ChamferSpec(edges: inside.compactMap(EdgeRef.init), profile: .round, distance: 1.5))))
    let r2 = DesignEvaluator.evaluate(d2, revision: "q")
    #expect(r2.issues.isEmpty, "\(r2.issues.map(\.message))")
    #expect(MeshValidator.validate(r2.bodies[0].mesh).isWatertight)
    #expect(r2.bodies[0].mesh.volume > base2.bodies[0].mesh.volume)
}
