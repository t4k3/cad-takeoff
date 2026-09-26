import Foundation
import Testing
@testable import CADCore

private func solid(_ f: Feature) throws -> CSGSolid {
    CSGSolid(try PrimitiveKernel.build(f).snapshot(revision: "t"))
}
private func box(_ w: Double, _ d: Double, _ h: Double, at p: Vec3 = .zero) -> Feature {
    Feature(name: "B", kind: .box(width: w, depth: d, height: h), position: p)
}

@Test func unionOfOverlappingBoxesIsClosedWithExactVolume() throws {
    let a = try solid(box(20, 20, 20))
    let b = try solid(box(20, 20, 20, at: Vec3(10, 10, 10)))
    let (mesh, _) = a.union(b).triangulated()
    let r = MeshValidator.validate(mesh)
    #expect(r.isWatertight, "boundary \(r.boundaryEdges) nonmanifold \(r.nonManifoldEdges)")
    #expect(abs(mesh.volume - (8000 + 8000 - 1000)) < 1e-6)
}

@Test func cylinderHoleThroughPlate() throws {
    let plate = try solid(box(40, 30, 5))
    let tool = Feature(name: "H", kind: .cylinder(radius: 4, height: 20), position: Vec3(0, 0, -5))
    let toolSolid = try solid(tool)
    let result = plate.subtracting(toolSolid)
    let (mesh, faces) = result.triangulated()
    #expect(MeshValidator.validate(mesh).isWatertight)
    // Faceted cylinder area (64 segments) removed from the plate.
    let holeArea = Profile2D.circle(radius: 4, segments: 64).area
    let expectedVolume = 6000 - holeArea * 5
    #expect(abs(mesh.volume - expectedVolume) / expectedVolume < 1e-6, "volume \(mesh.volume) vs \(expectedVolume)")
    // The hole wall keeps the cylinder's identity and surface, marked as flipped.
    let wall = result.faces.enumerated().filter { e in
        if case .cylinder = e.element.surface { return faces.contains(e.offset) } else { return false }
    }
    #expect(wall.count == 1 && wall[0].element.flipped)
}

@Test func intersectionKeepsOnlyTheOverlap() throws {
    let a = try solid(box(20, 20, 20))
    let b = try solid(box(20, 20, 20, at: Vec3(10, 0, 0)))
    let (mesh, _) = a.intersecting(b).triangulated()
    #expect(MeshValidator.validate(mesh).isWatertight)
    #expect(abs(mesh.volume - 10 * 20 * 20) < 1e-6)
}

@Test func disjointCutLeavesBodyUnchanged() throws {
    let a = try solid(box(10, 10, 10))
    let far = try solid(box(5, 5, 5, at: Vec3(100, 0, 0)))
    let (mesh, _) = a.subtracting(far).triangulated()
    #expect(MeshValidator.validate(mesh).isWatertight && abs(mesh.volume - 1000) < 1e-6)
}

@Test func coplanarFacesUnionStaysClosed() throws {
    // Two boxes sharing the bottom plane and one side: classic degenerate case.
    let a = try solid(box(20, 20, 10))
    let b = try solid(box(20, 20, 10, at: Vec3(10, 0, 0)))
    let (mesh, _) = a.union(b).triangulated()
    let r = MeshValidator.validate(mesh)
    #expect(r.isWatertight, "boundary \(r.boundaryEdges) nonmanifold \(r.nonManifoldEdges)")
    #expect(abs(mesh.volume - 30 * 20 * 10) < 1e-6)
}

@Test func slotCutThenCylinderUnion() throws {
    let plate = try solid(box(60, 40, 6))
    let slot = SketchShape(kind: .slot(start: .init(-10, 0), end: .init(10, 0), width: 8))
    let slotTool = try solid(Feature(name: "S", kind: .extrude(profile: slot.profile!, height: 20), position: Vec3(0, 0, -5)))
    let boss = try solid(Feature(name: "C", kind: .cylinder(radius: 6, height: 15), position: Vec3(22, 12, 0)))
    let (mesh, _) = plate.subtracting(slotTool).union(boss).triangulated()
    let r = MeshValidator.validate(mesh)
    #expect(r.isWatertight, "boundary \(r.boundaryEdges) nonmanifold \(r.nonManifoldEdges)")
    let expected = 60.0 * 40 * 6 - slot.profile!.area * 6 + Profile2D.circle(radius: 6, segments: 64).area * 9
    #expect(abs(mesh.volume - expected) / expected < 1e-6)
}

@Test func timelineEvaluatesJoinCutIntersect() {
    let plate = Feature(name: "Piastra", kind: .box(width: 40, depth: 30, height: 5))
    let hole = Feature(name: "Foro", kind: .cylinder(radius: 4, height: 10), position: Vec3(0, 0, -2), operation: .cut)
    let boss = Feature(name: "Perno", kind: .cylinder(radius: 5, height: 10), position: Vec3(12, 0, 5), operation: .join)
    let far = Feature(name: "Lontano", kind: .box(width: 5, depth: 5, height: 5), position: Vec3(200, 0, 0))
    let doc = CADDocument(features: [plate, hole, boss, far])
    let (bodies, issues) = DesignEvaluator.evaluate(doc, revision: "r")
    #expect(issues.isEmpty)
    #expect(bodies.map(\.id) == [plate.id, far.id], "cut and join modify the plate, no new bodies")
    #expect(bodies[0].modifiedBy == [hole.id, boss.id])
    let expected = 6000 - Profile2D.circle(radius: 4, segments: 64).area * 5 + Profile2D.circle(radius: 5, segments: 64).area * 10
    #expect(abs(bodies[0].mesh.volume - expected) / expected < 1e-6)
    #expect(MeshValidator.validate(bodies[0].mesh).isWatertight)
    // The hole wall is selectable as a cylindrical face with the tool's radius.
    let holeFace = bodies[0].snapshot.faces.first { if case let .cylinder(_, _, r) = $0.surface { r == 4 } else { false } }
    #expect(holeFace != nil)
    // Untouched body keeps the kernel's original IDs.
    let direct = try! PrimitiveKernel.build(far).snapshot(revision: "r")
    #expect(bodies[1].snapshot.faces.map(\.id) == direct.faces.map(\.id))
    // Export of the whole design is the united result.
    #expect(abs(doc.buildMesh().volume - expected - 125) / expected < 1e-6)
}

@Test func cutThatMissesIsReported() {
    let a = Feature(name: "A", kind: .box(width: 10, depth: 10, height: 10))
    let miss = Feature(name: "M", kind: .box(width: 1, depth: 1, height: 1), position: Vec3(50, 0, 0), operation: .cut)
    let (bodies, issues) = DesignEvaluator.evaluate(CADDocument(features: [a, miss]), revision: "r")
    #expect(bodies.count == 1 && issues.count == 1 && issues[0].featureID == miss.id)
}

@Test func cutRemovingEverythingDeletesTheBody() {
    let a = Feature(name: "A", kind: .box(width: 10, depth: 10, height: 10))
    let big = Feature(name: "Big", kind: .box(width: 50, depth: 50, height: 50), position: Vec3(0, 0, -20), operation: .cut)
    #expect(DesignEvaluator.evaluate(CADDocument(features: [a, big]), revision: "r").bodies.isEmpty)
}

/// Fragments of each face (and of each facet of curved faces) are merged before triangulating:
/// the same closed solid with far fewer triangles.
@Test func mergedFacesAreLighterAndStayClosed() {
    let plate = Feature(name: "Piastra", kind: .box(width: 40, depth: 40, height: 10))
    let hole = Feature(name: "Foro", kind: .hole(HoleSpec(centers: [Vec3(0, 0, 10)], fit: .manual, diameter: 6)), operation: .cut)
    let b = DesignEvaluator.evaluate(CADDocument(features: [plate, hole]), revision: "r").bodies[0]
    let rim = b.snapshot.edges.first { $0.faces.contains { $0.rawValue.contains("bore") } && $0.polyline.allSatisfy { abs($0.z - 10) < 1e-9 } }!
    let bevel = Feature(name: "S", kind: .chamfer(ChamferSpec(edges: [EdgeRef(rim)!], distance: 1)), operation: .cut)
    let doc = CADDocument(features: [plate, hole, bevel])
    // (No global switch here: tests run in parallel.) Unmerged this was 8118 triangles.
    let merged = DesignEvaluator.evaluate(doc, revision: "r").bodies[0].mesh
    #expect(MeshValidator.validate(merged).isWatertight)
    #expect(merged.triangleCount < 4500)
}
