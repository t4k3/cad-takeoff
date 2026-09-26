import Foundation
import Testing
@testable import CADCore

private func box(_ n: String) -> Feature { Feature(name: n, kind: .box(width: 10, depth: 10, height: 10)) }

@Test func v1FileMigratesWithSketchBeforeItsSolid() throws {
    let a = box("A"), sk = Sketch(name: "S", shapes: [SketchShape(kind: .circle(center: .init(0, 0), radius: 3))])
    let e = Feature(name: "E", kind: .extrude(profile: sk.shapes[0].profile!, height: 2))
    let link = SketchLink(featureID: e.id, sketchID: sk.id, shapeID: sk.shapes[0].id)
    // Hand-written v1 JSON: features + sketches as separate arrays.
    struct V1: Encodable { let version = 1; let features: [Feature]; let sketches: [Sketch]; let sketchLinks: [SketchLink] }
    let data = try JSONEncoder().encode(V1(features: [a, e], sketches: [sk], sketchLinks: [link]))
    let doc = try CADDocument.decode(data)
    #expect(doc.version == 2)
    #expect(doc.timeline.map(\.name) == ["A", "S", "E"])
    #expect(doc.features.map(\.id) == [a.id, e.id] && doc.sketches == [sk] && doc.sketchLinks == [link])
    #expect(try CADDocument.decode(doc.encoded()) == doc)
}

@Test func newerFormatIsRejected() {
    #expect(throws: DecodingError.self) { try CADDocument.decode(Data(#"{"version":99,"timeline":[]}"#.utf8)) }
}

@Test func rollbackAndSuppressionControlEvaluation() {
    var doc = CADDocument(features: [box("A"), box("B"), box("C")])
    #expect(doc.activeFeatures.count == 3)
    doc.rollback = 1
    #expect(doc.activeFeatures.map(\.name) == ["A"] && doc.features.count == 3)
    #expect(abs(doc.buildMesh().volume - 1000) < 1e-9)
    doc.rollback = nil
    doc.timeline[1].isSuppressed = true
    #expect(doc.activeFeatures.map(\.name) == ["A", "C"])
}

@Test func newStepsAreInsertedAtTheMarker() {
    var doc = CADDocument(features: [box("A"), box("B")])
    doc.rollback = 1
    doc.features.append(box("N"))
    #expect(doc.timeline.map(\.name) == ["A", "N", "B"] && doc.rollback == 2)
    #expect(doc.activeFeatures.map(\.name) == ["A", "N"])
    doc.sketches.append(Sketch(name: "S"))
    #expect(doc.timeline.map(\.name) == ["A", "N", "S", "B"] && doc.rollback == 3)
}

@Test func featureSetterKeepsSlotsAndOrder() {
    let sk = Sketch(name: "S")
    var doc = CADDocument(timeline: [TimelineItem(.feature(box("A"))), TimelineItem(.sketch(sk)), TimelineItem(.feature(box("B")))])
    doc.features[1].name = "B2"                       // in-place edit through the view
    #expect(doc.timeline.map(\.name) == ["A", "S", "B2"])
    doc.features.remove(at: 0)                         // removal keeps the rest in place
    #expect(doc.timeline.map(\.name) == ["S", "B2"])
    doc.timeline[1].isSuppressed = true
    doc.features[0].name = "B3"                        // suppression survives edits
    #expect(doc.timeline[1].isSuppressed && doc.timeline[1].name == "B3")
}

@Test func removingBeforeTheMarkerMovesIt() {
    var doc = CADDocument(features: [box("A"), box("B"), box("C")])
    doc.rollback = 2
    doc.features.removeFirst()
    #expect(doc.rollback == 1 && doc.activeFeatures.map(\.name) == ["B"])
}

