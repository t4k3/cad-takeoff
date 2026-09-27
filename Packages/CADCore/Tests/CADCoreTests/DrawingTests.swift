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
    for t in ["60", "40", "8", "Ø10", "Prova à", "PLA", "1:1", "A4"] { #expect(texts.contains(t), "\(t)") }
    #expect(texts.filter { $0.hasPrefix("Ø") }.count == 1)
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
