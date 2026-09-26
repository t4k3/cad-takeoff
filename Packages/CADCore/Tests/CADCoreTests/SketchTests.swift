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
    // No sketch keys are written for documents without sketches (unchanged v1 files).
    let plain = String(decoding: try CADDocument(features: [f]).encoded(), as: UTF8.self)
    #expect(!plain.contains("sketches"))
}
