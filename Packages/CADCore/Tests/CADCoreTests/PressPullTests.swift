import Foundation
import Testing
@testable import CADCore

private func body(_ doc: CADDocument) -> DesignEvaluator.Body { DesignEvaluator.evaluate(doc, revision: "r").bodies[0] }

private func face(_ b: DesignEvaluator.Body, normal n: Vec3) -> FaceID {
    b.snapshot.faces.first { f in PressPull.frame(of: f.id, in: b.snapshot).map { ($0.normal - n).length < 1e-6 && $0.isPlanar } ?? false }!.id
}

@Test func pullingTheTopOfARingRaisesIt() throws {
    let ring = Feature(name: "Anello", kind: .extrude(profile: .circle(radius: 19), height: 10), holes: [.circle(radius: 5)])
    let doc = CADDocument(features: [ring])
    let b = body(doc)
    let v0 = b.mesh.volume
    let top = face(b, normal: Vec3(0, 0, 1))
    let plan = try #require(PressPull.plan(face: top, in: b.snapshot, document: doc))
    #expect(plan == .height(featureID: ring.id, normal: Vec3(0, 0, 1), shift: false))
    let (raised, id) = try PressPull.apply(plan, distance: 5, to: doc)
    #expect(id == ring.id && raised.features.count == 1 && raised.features[0].holes.count == 1)
    #expect(abs(body(raised).mesh.volume - v0 * 1.5) < 1e-6)
    // The bottom face moves down: taller, and the feature shifts.
    let bottom = face(b, normal: Vec3(0, 0, -1))
    let down = try #require(PressPull.plan(face: bottom, in: b.snapshot, document: doc))
    let (lowered, _) = try PressPull.apply(down, distance: 3, to: doc)
    let lb = body(lowered).mesh.bounds!
    #expect(abs(lb.min.z + 3) < 1e-9 && abs(lb.max.z - 10) < 1e-9)
    // Pushing it in by more than its height is refused.
    #expect(throws: KernelError.self) { try PressPull.apply(plan, distance: -12, to: doc) }
}

@Test func pullingASideFaceExtrudesIt() throws {
    let box = Feature(name: "Base", kind: .box(width: 40, depth: 30, height: 10))
    let doc = CADDocument(features: [box])
    let b = body(doc)
    let side = face(b, normal: Vec3(1, 0, 0))
    let plan = try #require(PressPull.plan(face: side, in: b.snapshot, document: doc))
    guard case let .offset(profile, holes, _) = plan else { Issue.record("side face is an offset"); return }
    #expect(holes.isEmpty && abs(profile.area - 300) < 1e-9)
    let (longer, _) = try PressPull.apply(plan, distance: 5, to: doc)
    let lb = DesignEvaluator.evaluate(longer, revision: "r")
    #expect(lb.issues.isEmpty && lb.bodies.count == 1 && abs(lb.bodies[0].mesh.volume - 12000 - 1500) < 1e-6)
    #expect(abs(lb.bodies[0].mesh.bounds!.max.x - 25) < 1e-9)
    let (shorter, _) = try PressPull.apply(plan, distance: -4, to: doc)
    #expect(abs(body(shorter).mesh.volume - (12000 - 1200)) < 1e-6)
    // Top of a box and of a cylinder: height.
    let top = face(b, normal: Vec3(0, 0, 1))
    #expect(PressPull.plan(face: top, in: b.snapshot, document: doc) == .height(featureID: box.id, normal: Vec3(0, 0, 1), shift: false))
    let cyl = Feature(name: "C", kind: .cylinder(radius: 5, height: 8))
    let cdoc = CADDocument(features: [cyl])
    let cb = body(cdoc)
    #expect(PressPull.plan(face: face(cb, normal: Vec3(0, 0, 1)), in: cb.snapshot, document: cdoc) != nil)
    // The curved wall cannot be pressed/pulled.
    let wall = cb.snapshot.faces.first { if case .cylinder = $0.surface { true } else { false } }!.id
    #expect(PressPull.plan(face: wall, in: cb.snapshot, document: cdoc) == nil)
}

@Test func severalFacesMoveTogether() throws {
    // Top and bottom of one box: 2 mm each way → 4 mm taller; plus a side face extruded.
    let box = Feature(name: "Base", kind: .box(width: 40, depth: 30, height: 10))
    let doc = CADDocument(features: [box])
    let b = body(doc)
    let plans = [Vec3(0, 0, 1), Vec3(0, 0, -1), Vec3(1, 0, 0)].compactMap { PressPull.plan(face: face(b, normal: $0), in: b.snapshot, document: doc) }
    #expect(plans.count == 3)
    let (moved, ids) = try PressPull.apply(plans, distance: 2, to: doc)
    #expect(ids.count == 2 && ids[0] == box.id)
    let r = DesignEvaluator.evaluate(moved, revision: "r")
    #expect(r.issues.isEmpty && r.bodies.count == 1)
    let bb = r.bodies[0].mesh.bounds!
    #expect(abs(bb.min.z + 2) < 1e-9 && abs(bb.max.z - 12) < 1e-9 && abs(bb.max.x - 22) < 1e-9)
    #expect(abs(r.bodies[0].mesh.volume - (40 * 30 * 14 + 2 * 30 * 10)) < 1e-6)
}

@Test func sideFacePulledWithTheTopTakesTheNewHeight() throws {
    let box = Feature(name: "Base", kind: .box(width: 40, depth: 30, height: 5))
    let doc = CADDocument(features: [box])
    let b = body(doc)
    let (moved, _) = try PressPull.move(faces: [face(b, normal: Vec3(0, 0, 1)), face(b, normal: Vec3(1, 0, 0))], distance: 3, in: doc)
    let r = DesignEvaluator.evaluate(moved, revision: "r")
    #expect(r.issues.isEmpty && r.bodies.count == 1)
    // One block 43 × 30 × 8: the extension is as tall as the raised part.
    #expect(abs(r.bodies[0].mesh.volume - 43 * 30 * 8) < 1e-6)
}
