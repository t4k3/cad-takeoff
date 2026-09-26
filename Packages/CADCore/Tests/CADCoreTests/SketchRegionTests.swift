import Foundation
import Testing
@testable import CADCore

private func sketch() -> (Sketch, outer: UUID, inner: UUID, plate: UUID, apart: UUID) {
    let plate = SketchShape(kind: .rectangle(corner: Vec2(-50, -50), width: 100, height: 100))
    let outer = SketchShape(kind: .circle(center: Vec2(0, 0), radius: 30))
    let inner = SketchShape(kind: .circle(center: Vec2(0, 0), radius: 10))
    let apart = SketchShape(kind: .circle(center: Vec2(80, 0), radius: 5))
    return (Sketch(name: "S", shapes: [inner, plate, outer, apart]), outer.id, inner.id, plate.id, apart.id)
}

@Test func nestedShapesMakeRegions() {
    let (s, outer, inner, plate, apart) = sketch()
    let regions = s.regions
    #expect(regions.count == 4)
    #expect(regions.first { $0.shapeID == plate }?.holeShapeIDs == [outer])
    #expect(regions.first { $0.shapeID == outer }?.holeShapeIDs == [inner])
    #expect(regions.first { $0.shapeID == apart }?.holeShapeIDs == [])
    // Picking: between the circles → the ring; in the middle → the disc; in the plate corner → the plate.
    #expect(s.region(at: Vec2(20, 0))?.shapeID == outer)
    #expect(s.region(at: Vec2(0, 0))?.shapeID == inner)
    #expect(s.region(at: Vec2(45, 45))?.shapeID == plate)
    #expect(s.region(at: Vec2(200, 0)) == nil)
}

@Test func selectedRegionsMergeIntoAreas() {
    let (s, outer, inner, plate, apart) = sketch()
    // The ring alone: outer circle with the inner one as a hole.
    let ring = s.areas(selected: [outer])
    #expect(ring.count == 1 && ring[0].holeShapeIDs == [inner])
    // Ring + disc: one full disc, no hole.
    let disc = s.areas(selected: [outer, inner])
    #expect(disc.count == 1 && disc[0].shapeID == outer && disc[0].holes.isEmpty)
    // Plate + disc (ring not picked): the plate with the big hole, and the disc on its own.
    let two = s.areas(selected: [plate, inner])
    #expect(two.count == 2)
    #expect(two.first { $0.shapeID == plate }?.holeShapeIDs == [outer])
    #expect(two.contains { $0.shapeID == inner && $0.holes.isEmpty })
    // Plate + ring + disc: the whole square.
    #expect(s.areas(selected: [plate, outer, inner]).map(\.holes.count) == [0])
    #expect(s.areas(selected: [apart]).count == 1)
    // Shaded area of the ring = π(30² − 10²), up to the 64-gons.
    let tris = ring[0].profile.triangulate(holes: ring[0].holes)
    let area = tris.reduce(0.0) { $0 + abs(($1.1 - $1.0).cross($1.2 - $1.0)) / 2 }
    #expect(abs(area - (ring[0].profile.area - ring[0].holes[0].area)) < 1e-6)
}

@Test func extrudedRingKeepsItsHole() throws {
    let (s, outer, _, _, _) = sketch()
    let area = s.areas(selected: [outer])[0]
    let f = Feature(name: "Anello", kind: .extrude(profile: area.profile, height: 8), holes: area.holes)
    let (bodies, issues) = DesignEvaluator.evaluate(CADDocument(features: [f]), revision: "r")
    #expect(issues.isEmpty)
    let mesh = bodies[0].mesh
    #expect(MeshValidator.validate(mesh).isWatertight)
    #expect(abs(mesh.volume - (area.profile.area - area.holes[0].area) * 8) < 1e-6)
    // Both walls are cylinders; the bore is a real hole (a ray down the axis hits nothing).
    #expect(bodies[0].snapshot.faces.filter { if case .cylinder = $0.surface { true } else { false } }.count == 2)
    #expect(mesh.vertices.allSatisfy { ($0.x * $0.x + $0.y * $0.y).squareRoot() > 9.9 })
    // Saved and reopened with its hole; old files have none.
    let doc = CADDocument(features: [f])
    #expect(try CADDocument.decode(doc.encoded()) == doc)
    #expect(try CADDocument.decode(CADDocument(features: [Feature(name: "B", kind: .box(width: 1, depth: 1, height: 1))]).encoded()).features[0].holes.isEmpty)
    // On a face (placed), reversed into the part: same volume, still closed.
    var placed = f
    placed.placement = FeaturePlacement(plane: SketchPlane.onFace(point: Vec3(0, 0, 20), normal: Vec3(0, 0, 1)), reversed: true)
    let (pb, pi) = DesignEvaluator.evaluate(CADDocument(features: [placed]), revision: "r")
    #expect(pi.isEmpty && MeshValidator.validate(pb[0].mesh).isWatertight)
    #expect(abs(pb[0].mesh.volume - mesh.volume) < 1e-6 && abs(pb[0].mesh.bounds!.max.z - 20) < 1e-9)
}
