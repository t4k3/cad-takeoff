import Foundation
import Testing
@testable import CADCore

private func sheet(_ features: [Feature], format: SheetFormat = .a4) throws -> DrawingSheet {
    let bodies = DesignEvaluator.evaluate(CADDocument(features: features), revision: "d").bodies.map { (mesh: $0.mesh, snapshot: $0.snapshot) }
    return try TechnicalDrawing.make(bodies, info: .init(title: "Prova à", material: "PLA", date: Date(timeIntervalSince1970: 0)), format: format)
}

@Test func drawingShowsHiddenHolesDimensionsAndTitle() throws {
    let plate = Feature(name: "Piastra", kind: .box(width: 60, depth: 40, height: 8))
    let hole = Feature(name: "Foro", kind: .cylinder(radius: 5, height: 20), position: Vec3(-15, 0, -2), operation: .cut)
    let s = try sheet([plate, hole])
    // The hole's walls are hidden lines in the front and side views; the rest is visible.
    #expect(s.lines.filter { $0.style == .hidden }.count >= 4)
    #expect(s.lines.filter { $0.style == .visible }.count > 20)
    #expect(s.lines.contains { $0.style == .center })
    // Overall size and the hole's diameter (the same circle top and bottom: once).
    let texts = s.texts.map(\.text)
    for t in ["60", "40", "8", "Prova à", "PLA", "1:1", "A4"] { #expect(texts.contains(t), "\(t)") }
    // The hole (the same circle top and bottom: once) is in the hole table as F1: X 15, Y 20,
    // Ø 10, from the part's lower-left corner.
    for t in ["Foro", "F1", "15", "20", "10", "0,0"] { #expect(texts.contains(t), "\(t)") }
    #expect(texts.filter { $0 == "F1" }.count == 2)   // table row and the label on the view
    // Everything inside the A4 sheet.
    #expect(s.lines.allSatisfy { [$0.a, $0.b].allSatisfy { $0.x >= 0 && $0.x <= 297 && $0.y >= 0 && $0.y <= 210 } })
}

@Test func drawingPicksAStandardScaleAndWritesPDFAndDXF() throws {
    let big = Feature(name: "Trave", kind: .box(width: 900, depth: 60, height: 60))
    let s = try sheet([big], format: .a3)
    #expect(s.texts.contains { $0.text == "1:10" } || s.texts.contains { $0.text == "1:5" })
    let pdf = PDFWriter.pdf(s)
    let text = String(decoding: pdf, as: UTF8.self)
    #expect(text.hasPrefix("%PDF-1.4") && text.hasSuffix("%%EOF\n"))
    // The xref points at the objects.
    if let r = text.range(of: "startxref\n"), let n = Int(text[r.upperBound...].prefix { $0.isNumber }) {
        #expect(String(decoding: pdf[n..<(n + 4)], as: UTF8.self) == "xref")
    } else { Issue.record("no startxref") }
    let dxf = DrawingDXF.dxf(s)
    #expect(dxf.contains("NASCOSTE") && dxf.contains("DASHED") && dxf.hasSuffix("EOF\n"))
    #expect(dxf.components(separatedBy: "\nLINE\n").count - 1 == s.lines.count)
    #expect(DrawingDXF.encoded("Ø10 à 45°") == "%%c10 \\U+00E0 45%%d")
    #expect(throws: KernelError.self) { try TechnicalDrawing.make([], info: .init(title: "x")) }
}

@Test func sectionViewHatchesTheCutAndMarksItsLine() throws {
    let p = Profile2D(points: [Vec2(6, 0), Vec2(12, 0), Vec2(12, 60), Vec2(6, 60)])   // a bush: bore Ø12
    let bush = Feature(name: "Boccola", kind: .revolve(RevolveSpec(profile: p, plane: SketchPlane(origin: .zero, xAxis: Vec3(1, 0, 0), yAxis: Vec3(0, 0, 1)),
                                                                    axisStart: Vec2(0, 0), axisEnd: Vec2(0, 1))))
    let plain = try sheet([bush])
    let cut = try TechnicalDrawing.make(DesignEvaluator.evaluate(CADDocument(features: [bush]), revision: "s").bodies.map { (mesh: $0.mesh, snapshot: $0.snapshot) },
                                        info: .init(title: "Boccola"), section: true)
    #expect(cut.texts.contains { $0.text == "SEZIONE A-A" } && cut.texts.filter { $0.text == "A" }.count == 2)
    // Hatching: many thin 45° lines; and the bore is no longer hidden in the front view.
    let hatch = cut.lines.filter { $0.style == .thin && abs(abs(($0.b - $0.a).normalized.x) - sqrt(0.5)) < 1e-6 }
    #expect(hatch.count > 20)
    #expect(cut.lines.filter { $0.style == .hidden }.count < plain.lines.filter { $0.style == .hidden }.count)
}

@Test func flatPatternSheetHasBendsTablesAndPositions() throws {
    let spec = SheetMetalSpec(material: "dc01", thickness: 1.5, width: 120, depth: 60,
                              flanges: [.front: SheetFlange(length: 20), .back: SheetFlange(length: 20),
                                        .left: SheetFlange(length: 15, angle: 90, direction: .down)])
    let build = try SheetMetalGeometry.build(spec, featureID: UUID(), folded: false)
    let (flat, _) = build.flat(adding: [HoleSpec(centers: [Vec3(20, 0, 1.5), Vec3(-20, 0, 1.5)], size: "M5", diameter: 5.5)])
    let s = try TechnicalDrawing.flatPattern(flat, rule: build.rule, info: .init(title: "Staffa", date: Date(timeIntervalSince1970: 0)))
    let texts = s.texts.map(\.text)
    // Three bends labelled on the blank and listed in the table; two holes F1, F2 (label + row).
    for t in ["P1 SU 90°", "P2 SU 90°", "P3 GIÙ 90°", "Piega", "Foro", "SVILUPPO", "Staffa", "1:1"] { #expect(texts.contains(t), "\(t)") }
    #expect(texts.filter { $0 == "F1" }.count == 2 && texts.filter { $0 == "F2" }.count == 2)
    #expect(texts.filter { $0 == "giù" }.count == 1 && texts.filter { $0 == "su" }.count == 2)
    // One centre line and two tangents per bend; blank size and each bend's position dimensioned.
    #expect(s.lines.filter { $0.style == .center }.count == 3)
    #expect(s.lines.filter { $0.style == .hidden }.count == 6)
    let blank = flat.outline.map(\.x).max()! - flat.outline.map(\.x).min()!
    #expect(texts.contains(TechnicalDrawing.number(blank)))
    #expect(s.lines.allSatisfy { [$0.a, $0.b].allSatisfy { $0.x >= 0 && $0.x <= 297 && $0.y >= 0 && $0.y <= 210 } })
    #expect(DrawingDXF.dxf(s).contains("GI\\U+00D9"))
}

@Test func sketchDimensionsGoOnTheViewThatSeesThemTrue() throws {
    let plate = Feature(name: "Piastra", kind: .box(width: 80, depth: 50, height: 6))
    let h1 = Feature(name: "F1", kind: .cylinder(radius: 4, height: 20), position: Vec3(-20, 0, -2), operation: .cut)
    let h2 = Feature(name: "F2", kind: .cylinder(radius: 4, height: 20), position: Vec3(20, 0, -2), operation: .cut)
    let rect = SketchShape(kind: .rectangle(corner: Vec2(-40, -25), width: 80, height: 50))
    let c1 = SketchShape(kind: .circle(center: Vec2(-20, 0), radius: 4)), c2 = SketchShape(kind: .circle(center: Vec2(20, 0), radius: 4))
    let corner = SketchShape(kind: .arc(center: Vec2(30, 15), radius: 10, start: 0, end: .pi / 2))
    let sketch = Sketch(name: "S", shapes: [rect, c1, c2, corner], constraints: [
        SketchConstraint(.horizontalDistance(.point(c1.id, 0), .point(c2.id, 0), 40)),
        SketchConstraint(.verticalDistance(.point(rect.id, 0), .point(c1.id, 0), 25)),
        SketchConstraint(.length(.segment(rect.id, 0), 80)),          // the overall width: not repeated
        SketchConstraint(.diameter(.circle(c1.id, 0), 8)),             // in the hole table already
        SketchConstraint(.radius(.circle(corner.id, 0), 10)),
    ])
    let dims = sketch.drawingDimensions
    #expect(dims.count == 5)
    let bodies = DesignEvaluator.evaluate(CADDocument(features: [plate, h1, h2]), revision: "d").bodies.map { (mesh: $0.mesh, snapshot: $0.snapshot) }
    let s = try TechnicalDrawing.make(bodies, info: .init(title: "Piastra", date: Date(timeIntervalSince1970: 0)), dimensions: dims)
    let texts = s.texts.map(\.text)
    for t in ["40", "25", "R10"] { #expect(texts.contains(t), "\(t)") }
    #expect(texts.filter { $0 == "80" }.count == 1 && !texts.contains("Ø8"))
    #expect(s.lines.allSatisfy { [$0.a, $0.b].allSatisfy { $0.x >= 0 && $0.x <= 297 && $0.y >= 0 && $0.y <= 210 } })
    // The 40 between the holes: a horizontal dimension under the view from above.
    let forty = try #require(s.texts.first { $0.text == "40" })
    #expect(forty.angle == 0)
    let plain = try TechnicalDrawing.make(bodies, info: .init(title: "Piastra"))
    #expect(!plain.texts.map(\.text).contains("40"))
}
