import Foundation
import Testing
@testable import CADCore

private func near(_ a: Double, _ b: Double, _ tol: Double = 1e-7) -> Bool { abs(a - b) < tol }

/// Parameters, accessors and dimensions of the 3D entities in the sketch-plane frame.
@Test func point3DAndLine3DParametersRoundTrip() {
    let point = SketchShape(kind: .point3D(position: Vec3(3, -2, 5)))
    #expect(point.parameters == [3, -2, 5])
    #expect(point.point3D(0) == Vec3(3, -2, 5))
    #expect(point.point3D(1) == nil)
    #expect(point.point(0) == nil)
    #expect(point.pointCount == 1)
    #expect(point.segmentCount == 0)
    #expect(point.is3D)
    #expect(point.length == 0)
    #expect(point.outline.isEmpty)
    #expect(point.with(parameters: point.parameters).kind == point.kind)

    let line = SketchShape(kind: .line3D(start: Vec3(1, 2, 3), end: Vec3(4, 6, 3)))
    #expect(line.parameters == [1, 2, 3, 4, 6, 3])
    #expect(line.point3D(0) == Vec3(1, 2, 3))
    #expect(line.point3D(1) == Vec3(4, 6, 3))
    #expect(line.point3D(2) == nil)
    #expect(line.point(0) == nil)
    #expect(line.segment(0) == nil)
    #expect(line.segmentCount == 1)
    #expect(line.pointCount == 2)
    #expect(line.segment3D(0)?.0 == Vec3(1, 2, 3))
    #expect(line.segment3D(0)?.1 == Vec3(4, 6, 3))
    #expect(line.segment3D(1) == nil)
    #expect(line.is3D)
    #expect(near(line.length, 5))
    #expect(line.with(parameters: line.parameters).kind == line.kind)
}

/// Off-plane geometry never becomes a profile, a region or an extrusion input.
@Test func threeDEntitiesNeverBecomeProfiles() {
    let line = SketchShape(kind: .line3D(start: Vec3(0, 0, 0), end: Vec3(10, 0, 5)))
    let point = SketchShape(kind: .point3D(position: Vec3(2, 3, 7)))
    let only = Sketch(name: "Solo 3D", shapes: [line, point])
    #expect(line.profile == nil)
    #expect(point.profile == nil)
    #expect(line.outline.isEmpty && point.outline.isEmpty)
    #expect(line.prims.isEmpty && point.prims.isEmpty)
    #expect(line.area == 0)
    #expect(only.profiles.isEmpty)
    #expect(only.regions.isEmpty)

    let circle = SketchShape(kind: .circle(center: Vec2(0, 0), radius: 5))
    let mixed = Sketch(name: "Misto", shapes: [circle, line])
    #expect(mixed.profiles.count == 1)
    #expect(mixed.regions.count == 1)
    #expect(mixed.regions[0].holeShapeIDs.isEmpty)
    #expect(mixed.regions[0].shapeID == circle.id)
}

/// A length dimension on a 3D line is solved in space: both z coordinates move.
@Test func threeDLineLengthIsSolvedOffThePlane() {
    let line = SketchShape(kind: .line3D(start: Vec3(0, 0, 0), end: Vec3(3, 0, 4)))
    var sketch = Sketch(name: "Linea 3D", shapes: [line],
                        constraints: [.init(.length(.segment(line.id, 0), 10))])
    let solvedOK = sketch.solve()
    #expect(solvedOK)
    let solved = sketch.shapes[0]
    #expect(near(solved.length, 10))
    #expect(solved.point3D(1)!.z > 0)
    #expect(solved.point3D(0)!.z < 0)
}

/// A 3D point joined to the sketch origin is pulled onto it, including the out-of-plane coordinate.
@Test func threeDPointCoincidentToOriginLandsAtTheOrigin() {
    let point = SketchShape(kind: .point3D(position: Vec3(4, 2, 4)))
    var sketch = Sketch(name: "Punto 3D", shapes: [point],
                        constraints: [.init(.coincident(.point(point.id, 0), .origin))])
    let solvedOK = sketch.solve()
    #expect(solvedOK)
    let q = sketch.shapes[0].point3D(0)!
    #expect(near(q.x, 0) && near(q.y, 0) && near(q.z, 0))
}

/// New entities and their constraints survive a save/open round-trip.
@Test func threeDGeometrySurvivesCodable() throws {
    let point = SketchShape(kind: .point3D(position: Vec3(1, 2, 3)))
    let line = SketchShape(kind: .line3D(start: Vec3(0, 0, 0), end: Vec3(5, 0, 5)))
    let sketch = Sketch(name: "3D", shapes: [point, line], constraints: [
        .init(.coincident(.point(point.id, 0), .origin)),
        .init(.length(.segment(line.id, 0), 7)),
    ])
    let data = try JSONEncoder().encode(sketch)
    let back = try JSONDecoder().decode(Sketch.self, from: data)
    #expect(back == sketch)
}

/// A 3D point constrained to the sketch plane loses only its out-of-plane coordinate.
@Test func threeDPointOnPlaneIsSolved() {
    let point = SketchShape(kind: .point3D(position: Vec3(2, 3, 5)))
    var sketch = Sketch(name: "Sul piano", shapes: [point],
                        constraints: [.init(.pointOnPlane(.point(point.id, 0)))])
    let solvedOK = sketch.solve()
    #expect(solvedOK)
    let p = sketch.shapes[0].point3D(0)!
    #expect(near(p.x, 2) && near(p.y, 3) && near(p.z, 0))
}

/// The plane-distance dimension drives the out-of-plane coordinate, sign included.
@Test func threeDPlaneDistanceIsSolved() {
    let point = SketchShape(kind: .point3D(position: Vec3(1, 1, 4)))
    var sketch = Sketch(name: "Distanza piano", shapes: [point],
                        constraints: [.init(.planeDistance(.point(point.id, 0), 5))])
    let solvedOK = sketch.solve()
    #expect(solvedOK)
    let p = sketch.shapes[0].point3D(0)!
    #expect(near(p.z, 5))
    #expect(near(p.x, 1) && near(p.y, 1))
}

/// A line constrained normal to the plane ends up parallel to its normal.
@Test func threeDLineNormalToPlaneIsSolved() {
    let line = SketchShape(kind: .line3D(start: Vec3(1, 1, 0), end: Vec3(4, 2, 6)))
    var sketch = Sketch(name: "Normale", shapes: [line],
                        constraints: [.init(.normalToPlane(.segment(line.id, 0)))])
    let solvedOK = sketch.solve()
    #expect(solvedOK)
    let a = sketch.shapes[0].point3D(0)!, b = sketch.shapes[0].point3D(1)!
    #expect(near(a.x, b.x) && near(a.y, b.y))
    #expect(near(a.z, 0) && near(b.z, 6))
}

/// A fixed 3D point goes exactly where the constraint says, on all three axes.
@Test func threeDFixPinsThePoint() {
    let point = SketchShape(kind: .point3D(position: Vec3(1, 2, 3)))
    var sketch = Sketch(name: "Fisso 3D", shapes: [point],
                        constraints: [.init(.fix3D(.point(point.id, 0), Vec3(4, 5, 6)))])
    let solvedOK = sketch.solve()
    #expect(solvedOK)
    let p = sketch.shapes[0].point3D(0)!
    #expect(near(p.x, 4) && near(p.y, 5) && near(p.z, 6))
}

/// Horizontal/vertical dimensions of 3D points use the plane's x/y axes, not their depth.
@Test func threeDHorizontalDistanceIsSolvedInThePlaneFrame() {
    let a = SketchShape(kind: .point3D(position: Vec3(1, 2, 3)))
    let b = SketchShape(kind: .point3D(position: Vec3(5, 7, 9)))
    var sketch = Sketch(name: "Distanza orizzontale", shapes: [a, b], constraints: [
        .init(.horizontalDistance(.point(a.id, 0), .point(b.id, 0), 10)),
    ])
    let solvedOK = sketch.solve()
    #expect(solvedOK)
    let p = sketch.shapes[0].point3D(0)!, q = sketch.shapes[1].point3D(0)!
    #expect(near(q.x - p.x, 10))
    #expect(near(p.y, 2) && near(q.y, 7) && near(p.z, 3) && near(q.z, 9))
}

/// A 3D point–line distance dimension is solved in space.
@Test func threeDPointLineDistanceIsSolved() {
    let point = SketchShape(kind: .point3D(position: Vec3(3, 0, 0)))
    let line = SketchShape(kind: .line3D(start: Vec3(0, 0, 0), end: Vec3(0, 0, 5)))
    var sketch = Sketch(name: "Distanza punto-linea", shapes: [point, line], constraints: [
        .init(.distance(.point(point.id, 0), .segment(line.id, 0), 5)),
    ])
    let solvedOK = sketch.solve()
    #expect(solvedOK)
    let p = sketch.shapes[0].point3D(0)!
    let (u, v) = sketch.shapes[1].segment3D(0)!
    let dir = v - u
    let distance = (p - u).cross(dir).length / dir.length
    #expect(near(distance, 5))
}

/// The new 3D constraints survive a save/open round-trip.
@Test func threeDConstraintsSurviveCodable() throws {
    let point = SketchShape(kind: .point3D(position: Vec3(1, 2, 3)))
    let line = SketchShape(kind: .line3D(start: Vec3(0, 0, 0), end: Vec3(0, 0, 5)))
    let sketch = Sketch(name: "Vincoli 3D", shapes: [point, line], constraints: [
        .init(.pointOnPlane(.point(point.id, 0))),
        .init(.planeDistance(.point(point.id, 0), 4)),
        .init(.normalToPlane(.segment(line.id, 0))),
        .init(.fix3D(.point(point.id, 0), Vec3(1, 2, 4))),
    ])
    let data = try JSONEncoder().encode(sketch)
    let back = try JSONDecoder().decode(Sketch.self, from: data)
    #expect(back == sketch)
}

/// A workplane entity is three 3D points and derives a plane from them; it is never a profile.
@Test func workplaneParametersAndDerivedPlane() {
    let plane = SketchShape(kind: .workplane(origin: Vec3(1, 2, 3), xAxisPoint: Vec3(1, 7, 3),
                                             planePoint: Vec3(1, 2, 8)))
    #expect(plane.parameters == [1, 2, 3, 1, 7, 3, 1, 2, 8])
    #expect(plane.point3D(0) == Vec3(1, 2, 3))
    #expect(plane.point3D(1) == Vec3(1, 7, 3))
    #expect(plane.point3D(2) == Vec3(1, 2, 8))
    #expect(plane.point3D(3) == nil)
    #expect(plane.point(0) == nil)
    #expect(plane.pointCount == 3)
    #expect(plane.segmentCount == 0)
    #expect(plane.segment(0) == nil)
    #expect(plane.is3D)
    #expect(plane.outline.isEmpty)
    #expect(plane.area == 0)
    #expect(plane.prims.isEmpty)
    #expect(plane.profile == nil)
    #expect(plane.typeName == "Piano di lavoro")
    #expect(plane.with(parameters: plane.parameters).kind == plane.kind)

    let derived = plane.workplanePlane
    #expect(derived?.origin == Vec3(1, 2, 3))
    #expect(derived?.xAxis == Vec3(0, 1, 0))
    #expect(derived?.normal == Vec3(1, 0, 0))
    #expect(derived?.yAxis == Vec3(0, 0, 1))
    #expect(SketchPlane.workplane(Vec3(0, 0, 0), Vec3(0, 0, 0), Vec3(0, 1, 0)) == nil)
    #expect(SketchPlane.workplane(Vec3(0, 0, 0), Vec3(1, 0, 0), Vec3(2, 0, 0)) == nil)
    #expect(Sketch(name: "Piano", shapes: [plane]).profiles.isEmpty)
}

/// Lock rotation freezes a workplane's two directions and leaves its origin free.
@Test func workplaneLockRotationKeepsDirectionsNotPosition() {
    let wp = SketchShape(kind: .workplane(origin: Vec3(1, 1, 1), xAxisPoint: Vec3(6, 1, 1),
                                         planePoint: Vec3(1, 4, 1)))
    var sketch = Sketch(name: "Blocco", shapes: [wp], constraints: [
        .init(.lockRotation(.point(wp.id, 0), xDirection: Vec3(4, 0, 0), planeDirection: Vec3(0, 3, 0))),
    ])
    let solvedOK = sketch.solve()
    #expect(solvedOK)
    let solved = sketch.shapes[0]
    let o = solved.point3D(0)!, x = solved.point3D(1)!, p = solved.point3D(2)!
    #expect(near((x - o).x, 4) && near((x - o).y, 0) && near((x - o).z, 0))
    #expect(near((p - o).x, 0) && near((p - o).y, 3) && near((p - o).z, 0))
}

/// Setting a new plane keeps 3D geometry where it is in the world and 2D coordinates attached to it.
@Test func setPlaneKeepsThreeDPositionAndCarriesTwoDGeometry() {
    let point = SketchShape(kind: .point3D(position: Vec3(2, 3, 4)))
    let line = SketchShape(kind: .line3D(start: Vec3(0, 0, 0), end: Vec3(5, 0, 5)))
    let wp = SketchShape(kind: .workplane(origin: Vec3(1, 1, 1), xAxisPoint: Vec3(4, 1, 1),
                                         planePoint: Vec3(1, 3, 1)))
    let square = SketchShape(kind: .rectangle(corner: Vec2(0, 0), width: 10, height: 10))
    var sketch = Sketch(name: "Piano", shapes: [point, line, wp, square])
    let old = sketch.plane
    let new = SketchPlane.xy.offset(by: 10).tilted(by: 30)
    let worlds = sketch.shapes.prefix(3).flatMap { s in
        (0..<s.pointCount).compactMap { s.point3D($0) }.map { old.world(Vec2($0.x, $0.y), height: $0.z) }
    }
    sketch.setPlane(new)
    #expect(sketch.plane == new)
    let after = sketch.shapes.prefix(3).flatMap { s in
        (0..<s.pointCount).compactMap { s.point3D($0) }.map { new.world(Vec2($0.x, $0.y), height: $0.z) }
    }
    #expect(after.count == worlds.count)
    for (a, b) in zip(worlds, after) { #expect(near((a - b).length, 0, 1e-9)) }
    #expect(sketch.shapes[3].kind == square.kind)
    #expect(sketch.shapes[3].point(0) == Vec2(0, 0))
}

/// Setting a new plane re-expresses the absolute 3D constraints so the sketch stays solved.
@Test func setPlaneUpdatesAbsoluteConstraints() {
    let point = SketchShape(kind: .point3D(position: Vec3(1, 2, 3)))
    let wp = SketchShape(kind: .workplane(origin: Vec3(0, 0, 0), xAxisPoint: Vec3(4, 0, 0),
                                         planePoint: Vec3(0, 3, 0)))
    var sketch = Sketch(name: "Vincoli", shapes: [point, wp], constraints: [
        .init(.fix3D(.point(point.id, 0), Vec3(1, 2, 3))),
        .init(.planeDistance(.point(point.id, 0), 3)),
        .init(.lockRotation(.point(wp.id, 0), xDirection: Vec3(4, 0, 0), planeDirection: Vec3(0, 3, 0))),
    ])
    sketch.setPlane(SketchPlane.xy.offset(by: 5))
    guard case let .fix3D(_, fixed) = sketch.constraints[0].kind,
          case let .planeDistance(_, distance) = sketch.constraints[1].kind,
          case let .lockRotation(_, xDirection, planeDirection) = sketch.constraints[2].kind else {
        Issue.record("constraints changed kind")
        return
    }
    #expect(near(fixed.x, 1) && near(fixed.y, 2) && near(fixed.z, -2))
    #expect(near(distance, -2))
    #expect(near(xDirection.x, 4) && near(xDirection.y, 0) && near(xDirection.z, 0))
    #expect(near(planeDirection.y, 3))
    let solvedOK = sketch.solve()
    #expect(solvedOK)
}

/// Workplanes and lock rotation survive a save/open round-trip.
@Test func workplaneConstraintsSurviveCodable() throws {
    let wp = SketchShape(kind: .workplane(origin: Vec3(1, 2, 3), xAxisPoint: Vec3(4, 2, 3),
                                         planePoint: Vec3(1, 5, 3)))
    let sketch = Sketch(name: "Piani", shapes: [wp], constraints: [
        .init(.lockRotation(.point(wp.id, 0), xDirection: Vec3(3, 0, 0), planeDirection: Vec3(0, 3, 0))),
        .init(.fix3D(.point(wp.id, 0), Vec3(1, 2, 3))),
    ])
    let data = try JSONEncoder().encode(sketch)
    let back = try JSONDecoder().decode(Sketch.self, from: data)
    #expect(back == sketch)
}

/// Documents written before the 3D entities still open: no new key is required.
@Test func legacyTwoDSketchStillDecodes() throws {
    let json = """
    {
      "id": "11111111-1111-1111-1111-111111111111",
      "name": "vecchio",
      "plane": {
        "origin": {"x": 0, "y": 0, "z": 0},
        "xAxis": {"x": 1, "y": 0, "z": 0},
        "yAxis": {"x": 0, "y": 1, "z": 0}
      },
      "shapes": [
        {
          "id": "22222222-2222-2222-2222-222222222222",
          "kind": {"polyline": {"_0": [{"x": 0, "y": 0}, {"x": 10, "y": 0}], "closed": false}},
          "isConstruction": false
        }
      ]
    }
    """
    let data = try #require(json.data(using: .utf8))
    let sketch = try JSONDecoder().decode(Sketch.self, from: data)
    #expect(sketch.name == "vecchio")
    #expect(sketch.plane == .xy)
    #expect(sketch.shapes.count == 1)
    #expect(sketch.shapes[0].point(0) == Vec2(0, 0))
    #expect(sketch.shapes[0].point(1) == Vec2(10, 0))
    #expect(sketch.constraints.isEmpty)
}
