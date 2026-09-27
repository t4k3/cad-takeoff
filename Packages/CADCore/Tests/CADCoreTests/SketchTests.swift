import Foundation
import Testing
@testable import CADCore

@Test func slotAreaAndProfileAgree() {
    let s = SketchShape(kind: .slot(start: Vec2(0, 0), end: Vec2(30, 0), width: 10))
    #expect(abs(s.area - (300 + .pi * 25)) < 1e-9)
    let tess = s.profile!.area
    #expect(abs(tess - s.area) / s.area < 0.002)
    #expect(MeshValidator.validate(Operations.extrude(s.profile!, height: 5)).isWatertight)
}

@Test func circumscribedPolygonHasApothemEqualToRadius() {
    let p = SketchShape(kind: .polygon(center: Vec2(0, 0), radius: 10, sides: 6, rotation: 0, circumscribed: true))
    let o = p.outline
    let mid = Vec2((o[0].x + o[1].x) / 2, (o[0].y + o[1].y) / 2)
    #expect(abs((mid.x * mid.x + mid.y * mid.y).squareRoot() - 10) < 1e-9)
}

@Test func negativeRectangleIsNormalised() {
    let r = SketchShape(kind: .rectangle(corner: Vec2(10, 10), width: -4, height: -6))
    #expect(r.area == 24)
    #expect(r.outline.first == Vec2(6, 4))
}

@Test func openLinesAreNotProfiles() {
    let l = SketchShape(kind: .polyline([Vec2(0, 0), Vec2(3, 4)], closed: false))
    #expect(l.profile == nil && l.length == 5 && l.typeName == "Linea")
    let c = SketchShape(kind: .circle(center: .init(0, 0), radius: 1), isConstruction: true)
    #expect(c.profile == nil)
}

@Test func sketchRoundTrip() throws {
    let s = Sketch(name: "Schizzo 1", shapes: [SketchShape(kind: .slot(start: .init(0, 0), end: .init(5, 5), width: 2))])
    let back = try JSONDecoder().decode(Sketch.self, from: JSONEncoder().encode(s))
    #expect(back == s)
}

@Test func documentKeepsSketchesAndReadsOldFiles() throws {
    let sk = Sketch(name: "S", shapes: [SketchShape(kind: .circle(center: .init(0, 0), radius: 2))])
    let f = Feature(name: "E", kind: .extrude(profile: sk.shapes[0].profile!, height: 3))
    let doc = CADDocument(features: [f], sketches: [sk], sketchLinks: [SketchLink(featureID: f.id, sketchID: sk.id, shapeID: sk.shapes[0].id)])
    #expect(try CADDocument.decode(doc.encoded()) == doc)
    // A v1 file without the sketch keys still opens.
    let old = try CADDocument.decode(Data(#"{"version":1,"features":[]}"#.utf8))
    #expect(old.sketches.isEmpty && old.sketchLinks.isEmpty)
}

// MARK: Sketch on face (placement)

@Test func facePlanesUseWorldLikeAxes() {
    let top = SketchPlane.onFace(point: Vec3(3, 4, 5), normal: Vec3(0, 0, 1))
    #expect(top.origin == Vec3(0, 0, 5) && top.xAxis == Vec3(1, 0, 0) && top.yAxis == Vec3(0, 1, 0))
    #expect(top.local(Vec3(3, 4, 5)) == Vec2(3, 4))
    let front = SketchPlane.onFace(point: Vec3(7, -15, 2), normal: Vec3(0, -1, 0))
    #expect(front.origin == Vec3(0, -15, 0) && front.xAxis == Vec3(1, 0, 0) && front.yAxis == Vec3(0, 0, 1))
    #expect(front.normal == Vec3(0, -1, 0))
}

@Test func extrudeOnSideFaceAndCutFromTop() throws {
    let base = Feature(name: "Base", kind: .box(width: 40, depth: 30, height: 5))
    let square = Profile2D.rectangle(width: 10, height: 4, center: Vec2(0, 2.5))
    // Boss on the front face (y = −15), 5 mm outward, joined.
    let front = SketchPlane.onFace(point: Vec3(0, -15, 0), normal: Vec3(0, -1, 0))
    let boss = Feature(name: "Boss", kind: .extrude(profile: square, height: 5), operation: .join,
                       placement: FeaturePlacement(plane: front))
    let b = try PrimitiveKernel.build(boss).mesh.bounds!
    #expect(abs(b.min.y + 20) < 1e-9 && abs(b.max.y + 15) < 1e-9 && abs(b.min.z - 0.5) < 1e-9 && abs(b.max.z - 4.5) < 1e-9)
    // Pocket from the top face (z = 5), 3 mm into the part.
    let top = SketchPlane.onFace(point: Vec3(0, 0, 5), normal: Vec3(0, 0, 1))
    let pocket = Feature(name: "Tasca", kind: .extrude(profile: Profile2D.rectangle(width: 10, height: 10), height: 3), operation: .cut,
                         placement: FeaturePlacement(plane: top, reversed: true))
    let p = try PrimitiveKernel.build(pocket).mesh.bounds!
    #expect(abs(p.min.z - 2) < 1e-9 && abs(p.max.z - 5) < 1e-9)
    let doc = CADDocument(features: [base, boss, pocket])
    let (bodies, issues) = DesignEvaluator.evaluate(doc, revision: "r")
    #expect(issues.isEmpty && bodies.count == 1 && MeshValidator.validate(bodies[0].mesh).isWatertight)
    #expect(abs(bodies[0].mesh.volume - (6000 + 200 - 300)) < 1e-6)
    #expect(try CADDocument.decode(doc.encoded()) == doc)
    #expect(abs(pocket.buildMesh().volume - 300) < 1e-9)
}

@Test func basePlanesAndConstructionOffsets() {
    #expect(SketchPlane.xz.normal == Vec3(0, -1, 0) && SketchPlane.yz.normal == Vec3(1, 0, 0))
    let raised = SketchPlane.xy.offset(by: 15)
    #expect(raised.origin == Vec3(0, 0, 15) && !raised.isXY)
    #expect(SketchPlane.xz.offset(by: 10).origin == Vec3(0, -10, 0))
}

@Test func inclinedConstructionPlanes() {
    let p = SketchPlane.xy.tilted(by: 90)
    #expect((p.yAxis - Vec3(0, 0, 1)).length < 1e-12 && (p.xAxis - Vec3(1, 0, 0)).length < 1e-12)
    let q = SketchPlane.xy.tilted(by: 30, aboutX: false).offset(by: 10)
    #expect(abs(q.normal.dot(Vec3(0, 0, 1)) - cos(30 * Double.pi / 180)) < 1e-12)
    #expect(abs(q.origin.dot(q.normal) - 10) < 1e-12)
    // An extrusion on it stands square to the inclined plane.
    let f = Feature(name: "E", kind: .extrude(profile: .rectangle(width: 10, height: 10), height: 5), placement: FeaturePlacement(plane: q))
    let m = try! PrimitiveKernel.build(f).mesh
    #expect(abs(m.volume - 500) < 1e-9)
}

@Test func constructionPlanesByPointsTangentAndMidway() throws {
    // Three points on the plane z = x (tilted 45°): the normal is ±(−1, 0, 1)/√2.
    let p = try #require(SketchPlane.through(Vec3(0, 0, 0), Vec3(0, 10, 0), Vec3(10, 0, 10)))
    #expect(abs(abs(p.normal.dot(Vec3(-1, 0, 1).normalized)) - 1) < 1e-12)
    for q in [Vec3(0, 0, 0), Vec3(0, 10, 0), Vec3(10, 0, 10)] { #expect(abs((q - p.origin).dot(p.normal)) < 1e-9) }
    #expect(SketchPlane.through(Vec3(0, 0, 0), Vec3(1, 1, 1), Vec3(2, 2, 2)) == nil)
    // Tangent to a vertical Ø20 cylinder at (10, 0, 5): the plane x = 10, facing +X, Y up.
    let t = try #require(SketchPlane.tangent(to: .cylinder(axisOrigin: .zero, axisDirection: Vec3(0, 0, 1), radius: 10), at: Vec3(10, 0, 5)))
    #expect((t.normal - Vec3(1, 0, 0)).length < 1e-12 && abs(t.origin.x - 10) < 1e-12 && (t.yAxis - Vec3(0, 0, 1)).length < 1e-12)
    // A 45° cone opening upwards from the origin: at (5, 0, 5) the normal is (1, 0, −1)/√2.
    let c = try #require(SketchPlane.tangent(to: .cone(apex: .zero, axisDirection: Vec3(0, 0, 1), halfAngle: .pi / 4), at: Vec3(5, 0, 5)))
    #expect((c.normal - Vec3(1, 0, -1).normalized).length < 1e-12 && abs((Vec3(5, 0, 5) - c.origin).dot(c.normal)) < 1e-9)
    #expect(SketchPlane.tangent(to: .plane(origin: .zero, normal: Vec3(0, 0, 1)), at: .zero) == nil)
    // Between the faces x = −15 and x = 25 (facing away from each other): x = 5.
    let m = try #require(SketchPlane.midway(Vec3(-15, 3, 0), Vec3(-1, 0, 0), Vec3(25, 0, 7), Vec3(1, 0, 0)))
    #expect(abs(m.origin.x - 5) < 1e-12 && abs(abs(m.normal.x) - 1) < 1e-12)
    #expect(SketchPlane.midway(.zero, Vec3(0, 0, 1), .zero, Vec3(1, 0, 0)) == nil)
}

@Test func flatFacesWithoutAPlaneDescriptionStillGiveTheirPlane() throws {
    // A chamfered box: the bevel face is flat; the kernel's plane or the triangles give it.
    let box = Feature(name: "B", kind: .box(width: 40, depth: 30, height: 20))
    let body = try #require(DesignEvaluator.evaluate(CADDocument(features: [box]), revision: "r").bodies.first)
    let s = body.snapshot
    for face in s.faces {
        let plane = try #require(s.flatPlane(of: face.id))
        #expect(abs(plane.normal.length - 1) < 1e-12)
    }
    // The same faces seen only as triangles (freeform): the same planes, facing out.
    let bare = BodySnapshot(bodyID: s.bodyID, revision: "t", positions: s.positions, normals: s.normals, triangles: s.triangles,
                            triangleFace: s.triangleFace, triangleTopologyFace: s.triangleTopologyFace,
                            faces: s.faces.map { FaceInfo(id: $0.id, surface: .freeform, area: $0.area, topologyFaceIDs: $0.topologyFaceIDs) }, edges: s.edges,
                            maximumSurfaceDeviation: s.maximumSurfaceDeviation)
    for face in s.faces {
        let exact = try #require(s.flatPlane(of: face.id)), found = try #require(bare.flatPlane(of: face.id))
        #expect((exact.normal - found.normal).length < 1e-9 && abs((found.origin - exact.origin).dot(exact.normal)) < 1e-9)
    }
    // A round face is not flat.
    let cyl = try #require(DesignEvaluator.evaluate(CADDocument(features: [Feature(name: "C", kind: .cylinder(radius: 5, height: 10))]), revision: "r").bodies.first)
    let side = try #require(cyl.snapshot.faces.first { if case .cylinder = $0.surface { true } else { false } })
    let bareSide = BodySnapshot(bodyID: cyl.snapshot.bodyID, revision: "t", positions: cyl.snapshot.positions, normals: cyl.snapshot.normals,
                                triangles: cyl.snapshot.triangles, triangleFace: cyl.snapshot.triangleFace,
                                triangleTopologyFace: cyl.snapshot.triangleTopologyFace,
                                faces: cyl.snapshot.faces.map { FaceInfo(id: $0.id, surface: .freeform, area: $0.area, topologyFaceIDs: $0.topologyFaceIDs) }, edges: cyl.snapshot.edges,
                                maximumSurfaceDeviation: 0)
    #expect(bareSide.flatPlane(of: side.id) == nil)
}

@Test func sideKeysFollowTheSketchNotTheNumbers() throws {
    // A slot-ended plate: a rectangle's sides and an arc, the outline read from different starts.
    let rect = SketchShape(kind: .rectangle(corner: Vec2(0, 0), width: 40, height: 20))
    let sketch = Sketch(name: "S", shapes: [rect])
    let outline = [Vec2(0, 0), Vec2(40, 0), Vec2(40, 20), Vec2(0, 20)]
    let keys = sketch.sideKeys(for: outline)
    #expect(Set(keys).count == 4 && keys.allSatisfy { $0.hasPrefix(rect.id.uuidString) })
    let turned = sketch.sideKeys(for: Array(outline[2...] + outline[..<2]))
    #expect(turned == Array(keys[2...] + keys[..<2]))
    // Wider: the same names.
    let wide = Sketch(name: "S", shapes: [SketchShape(id: rect.id, kind: .rectangle(corner: Vec2(0, 0), width: 70, height: 20))])
    #expect(wide.sideKeys(for: [Vec2(0, 0), Vec2(70, 0), Vec2(70, 20), Vec2(0, 20)]) == keys)
    // A circle's facets: one name per facet, the same wherever the outline starts.
    let circle = SketchShape(kind: .circle(center: Vec2(0, 0), radius: 5))
    let round = Sketch(name: "C", shapes: [circle])
    let ring = circle.outline
    let a = round.sideKeys(for: ring), b = round.sideKeys(for: Array(ring[10...] + ring[..<10]))
    #expect(Set(a).count == ring.count && b == Array(a[10...] + a[..<10]))
    // Extruded with them: faces named after the curves, the same after a dimension change.
    var f = Feature(name: "E", kind: .extrude(profile: Profile2D(points: outline), height: 5))
    f.keyProfile(from: sketch)
    var g = f
    g.kind = .extrude(profile: Profile2D(points: [Vec2(0, 0), Vec2(70, 0), Vec2(70, 20), Vec2(0, 20)]), height: 5)
    g.keyProfile(from: wide)
    let ids = { (x: Feature) in try PrimitiveKernel.build(x).snapshot(revision: "k").faces.map(\.id) }
    #expect(try ids(f) == ids(g))
}
