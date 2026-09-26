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
