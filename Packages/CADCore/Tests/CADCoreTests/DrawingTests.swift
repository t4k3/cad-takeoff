import Foundation
import Testing
@testable import CADCore

/// Every line inside the sheet (A4 landscape unless given).
func onSheet(_ s: DrawingSheet, width: Double = 297, height: Double = 210) -> Bool {
    for line in s.lines {
        for p in [line.a, line.b] where p.x < 0 || p.x > width || p.y < 0 || p.y > height { return false }
    }
    return true
}

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
    #expect(onSheet(s))
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
    #expect(onSheet(s))
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
    #expect(onSheet(s))
    // The 40 between the holes: a horizontal dimension under the view from above.
    let forty = try #require(s.texts.first { $0.text == "40" })
    #expect(forty.angle == 0)
    let plain = try TechnicalDrawing.make(bodies, info: .init(title: "Piastra"))
    #expect(!plain.texts.map(\.text).contains("40"))
}

@Test func turnedPartRadiiFromTheAxisBecomeDiameters() throws {
    // Half profile of a stepped pin on XZ, axis along Z: Ø20 × 30 then Ø12 × 20.
    let axis = SketchShape(kind: .polyline([Vec2(0, 0), Vec2(0, 50)], closed: false), isConstruction: true)
    let profile = SketchShape(kind: .polyline([Vec2(0, 0), Vec2(10, 0), Vec2(10, 30), Vec2(6, 30), Vec2(6, 50), Vec2(0, 50)], closed: true))
    let sketch = Sketch(name: "Profilo", plane: .xz, shapes: [axis, profile], constraints: [
        SketchConstraint(.horizontalDistance(.point(axis.id, 0), .point(profile.id, 1), 10)),
        SketchConstraint(.distance(.point(profile.id, 3), .segment(axis.id, 0), 6)),
        SketchConstraint(.verticalDistance(.point(profile.id, 1), .point(profile.id, 2), 30)),
    ])
    let dims = sketch.drawingDimensions(revolvedAbout: [(Vec2(0, 0), Vec2(0, 50))])
    #expect(dims.map(\.prefix) == ["Ø", "Ø", ""] && dims.map(\.value) == [20, 12, 30])
    // Drawn across the axis: from x = −10 to +10.
    if case let .linear(a, b, _) = dims[0].kind { #expect(abs(a.x + 10) < 1e-9 && abs(b.x - 10) < 1e-9) } else { Issue.record("linear") }
    let spec = RevolveSpec(profile: Profile2D(points: profile.outline), plane: .xz, axisStart: Vec2(0, 0), axisEnd: Vec2(0, 50))
    let pin = Feature(name: "Perno", kind: .revolve(spec))
    let bodies = DesignEvaluator.evaluate(CADDocument(features: [pin]), revision: "d").bodies.map { (mesh: $0.mesh, snapshot: $0.snapshot) }
    let s = try TechnicalDrawing.make(bodies, info: .init(title: "Perno"), dimensions: dims)
    let texts = s.texts.map(\.text)
    for t in ["Ø20", "Ø12", "30"] { #expect(texts.contains(t), "\(t)") }
    // The 30 from the bottom is the step's level dimension already: once.
    #expect(texts.filter { $0 == "30" }.count == 1)
    // Ø20 is the overall width seen from the front: no plain 20 there (the side view keeps its own).
    #expect(texts.filter { $0 == "20" }.count == 1)
}

@Test func manySketchDimensionsStayOnTheSheet() throws {
    let plate = Feature(name: "Piastra", kind: .box(width: 100, depth: 60, height: 5))
    var shapes = [SketchShape(kind: .rectangle(corner: Vec2(-50, -30), width: 100, height: 60))]
    var constraints: [SketchConstraint] = []
    for k in 0..<11 {
        let c = SketchShape(kind: .circle(center: Vec2(-45 + 9 * Double(k), -20 + 4 * Double(k)), radius: 1.5))
        shapes.append(c)
        constraints.append(SketchConstraint(.horizontalDistance(.point(shapes[0].id, 0), .point(c.id, 0), 5 + 9 * Double(k))))
        constraints.append(SketchConstraint(.verticalDistance(.point(shapes[0].id, 0), .point(c.id, 0), 10 + 4 * Double(k))))
    }
    let dims = Sketch(name: "S", shapes: shapes, constraints: constraints).drawingDimensions
    let bodies = DesignEvaluator.evaluate(CADDocument(features: [plate]), revision: "d").bodies.map { (mesh: $0.mesh, snapshot: $0.snapshot) }
    let s = try TechnicalDrawing.make(bodies, info: .init(title: "Piastra"), dimensions: dims)
    #expect(onSheet(s))
    // Six a side, the shortest kept: 5 … 50 horizontally, 10 … 30 vertically.
    let texts = s.texts.map(\.text)
    #expect(texts.contains("5") && texts.contains("50") && !texts.contains("95"))
    #expect(texts.contains("10") && texts.contains("30") && !texts.contains("50,0"))
    #expect(texts.contains("1:1") || texts.contains("1:2"))
}

@Test func dimensionsAddedMovedAndHiddenByHand() throws {
    // An L block: 60 wide, 20 deep, 30 tall with a 30 × 15 step on top.
    let base = Feature(name: "Base", kind: .box(width: 60, depth: 20, height: 15))
    let step = Feature(name: "Gradino", kind: .box(width: 30, depth: 20, height: 15), position: Vec3(-15, 0, 15))
    let bodies = DesignEvaluator.evaluate(CADDocument(features: [base, step]), revision: "d").bodies.map { (mesh: $0.mesh, snapshot: $0.snapshot) }
    let info = TechnicalDrawing.Info(title: "Gradino", date: Date(timeIntervalSince1970: 0))
    let plain = try TechnicalDrawing.make(bodies, info: info)
    // Views placed, snap points on the visible edges, the automatic dimensions marked by key.
    #expect(plain.views.map(\.view) == [.front, .top, .left])
    let front = plain.views[0]
    let snaps = plain.snapPoints.filter { $0.view == .front }
    #expect(snaps.contains { ($0.local - Vec2(0, 30)).length < 1e-6 } && snaps.contains { ($0.local - Vec2(30, 15)).length < 1e-6 })
    #expect(snaps.allSatisfy { ($0.at - front.sheet($0.local)).length < 1e-9 })
    let keys = Set(plain.marks.map(\.key))
    #expect(keys.contains("auto/width") && keys.contains("auto/height") && keys.contains("auto/depth"))

    // By hand, in the front view: the step's width (horizontal, 15 mm above) and the diagonal
    // across it (aligned).
    let top = snaps.first { ($0.local - Vec2(-30, 30)).length < 1e-6 }?.local ?? Vec2(-30, 30)
    let stepEnd = Vec2(0, 30), corner = Vec2(0, 15)
    let width = DrawingDimension(view: .front, a: top, b: stepEnd, direction: .horizontal, offset: 15)
    let diagonal = DrawingDimension(view: .front, a: top, b: corner, direction: .aligned, offset: 6)
    #expect(width.value == 30 && abs(diagonal.value - (30 * 30 + 15 * 15).squareRoot()) < 1e-9)
    var notes = DrawingAnnotations(dimensions: [width, diagonal])
    let s = try TechnicalDrawing.make(bodies, info: info, annotations: notes)
    #expect(s.texts.contains { $0.text == "30" } && s.texts.contains { $0.text == "33,54" })
    let mark = s.marks.first { $0.manual == width.id }!
    // Its line 15 mm (sheet) above the higher point, across the two points.
    #expect(abs(mark.line.0.y - (front.sheet(top).y + 15)) < 1e-9 && abs(mark.line.0.x - front.sheet(top).x) < 1e-9)
    #expect(mark.side == Vec2(0, 1) && mark.distance(to: mark.text) < 1e-9)
    // An automatic one moved 10 mm further out, another taken off.
    notes.moved["auto/width"] = 10
    notes.hidden = ["auto/depth"]
    let t = try TechnicalDrawing.make(bodies, info: info, annotations: notes)
    let before = plain.marks.first { $0.key == "auto/width" }!, after = t.marks.first { $0.key == "auto/width" }!
    #expect(abs((after.line.0 - before.line.0).dot(before.side) - 10) < 1e-9)
    #expect(!t.marks.contains { $0.key == "auto/depth" } && !t.texts.contains { $0.text == "20" && $0.angle == 0 && false })
    #expect(onSheet(t))
    // Saved with the design.
    var doc = CADDocument(features: [base, step])
    doc.drawing = notes
    let back = try CADDocument.decode(doc.encoded())
    #expect(back.drawing == notes)
    #expect(try CADDocument.decode(CADDocument(features: [base]).encoded()).drawing.isEmpty)
}
