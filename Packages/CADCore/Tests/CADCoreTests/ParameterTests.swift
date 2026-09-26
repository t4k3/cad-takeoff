import Foundation
import Testing
@testable import CADCore

private func near(_ a: Double, _ b: Double, _ tol: Double = 1e-9) -> Bool { abs(a - b) < tol }

@Test func expressionsFollowTheUsualRules() throws {
    #expect(try Formula.evaluate("2 + 3 * 4") == 14)
    #expect(try Formula.evaluate("(2 + 3) * 4") == 20)
    #expect(try Formula.evaluate("-2^2") == -4)
    #expect(try Formula.evaluate("2^3^2") == 512)
    #expect(try Formula.evaluate("12,5 mm / 2") == 6.25)
    #expect(try Formula.evaluate("max(3, 7; 1)") == 7)
    #expect(try Formula.evaluate("max(1,5; 2)") == 2)
    #expect(near(try Formula.evaluate("sin(30°) + cos(60 deg)"), 1))
    #expect(near(try Formula.evaluate("2 * pi * r", ["r": 10]), 20 * .pi))
    #expect(try Formula.evaluate("larghezza / 2 + 3", ["larghezza": 40]) == 23)
    #expect(Formula.names(in: "sqrt(a) + b * max(c, 2) + pi") == ["a", "b", "c"])
    #expect(Formula.isNumber("12,5") && Formula.isNumber("-3") && !Formula.isNumber("a + 1"))
    #expect(throws: ExpressionError.unknown("b")) { try Formula.evaluate("a + b", ["a": 1]) }
    #expect(throws: ExpressionError.self) { try Formula.evaluate("2 +") }
    #expect(throws: ExpressionError.self) { try Formula.evaluate("(2") }
    #expect(throws: ExpressionError.self) { try Formula.evaluate("1 / 0") }
    #expect(throws: ExpressionError.self) { try Formula.evaluate("") }
}

@Test func parametersResolveInDependencyOrderAndCatchCycles() throws {
    var doc = CADDocument()
    doc.parameters = [
        .init(name: "foro", expression: "spessore * 2 + 1"),
        .init(name: "spessore", expression: "3"),
        .init(name: "larghezza", expression: "40", comment: "lato lungo"),
    ]
    let v = try doc.parameterValues()
    #expect(v == ["foro": 7, "spessore": 3, "larghezza": 40])
    doc.parameters[1].expression = "foro - 1"
    #expect(throws: ExpressionError.cycle("foro")) { try doc.parameterValues() }
    doc.parameters[1].expression = "3"
    doc.parameters.append(.init(name: "foro", expression: "1"))
    #expect(throws: ExpressionError.duplicate("foro")) { try doc.parameterValues() }
    doc.parameters.removeLast()
    doc.parameters.append(.init(name: "sin", expression: "1"))
    #expect(throws: ExpressionError.invalidName("sin")) { try doc.parameterValues() }
    doc.parameters.removeLast()
    // Saved and read back; old files have none.
    let back = try CADDocument.decode(doc.encoded())
    #expect(back.parameters == doc.parameters)
    #expect(try CADDocument.decode(CADDocument().encoded()).parameters.isEmpty)
}

@Test func parametersDriveSketchDimensionsAndFeatureSizes() throws {
    let r = SketchShape(kind: .rectangle(corner: Vec2(0, 0), width: 30, height: 10))
    let sketch = Sketch(name: "S", shapes: [r], constraints: [
        .init(.length(.segment(r.id, 0), 30), expression: "larghezza"),
        .init(.length(.segment(r.id, 1), 10), expression: "larghezza / 4"),
    ])
    var box = Feature(name: "Piastra", kind: .box(width: 10, depth: 10, height: 2))
    box.expressions = ["height": "spessore", "width": "larghezza + 2 * spessore"]
    var doc = CADDocument(features: [box], sketches: [sketch])
    doc.parameters = [.init(name: "larghezza", expression: "40"), .init(name: "spessore", expression: "3")]
    let changed = try doc.applyParameters()
    #expect(changed == [sketch.id])
    let s = doc.sketches[0].shapes[0]
    #expect(near(s.segment(0).map { ($0.1 - $0.0).length }!, 40, 1e-6) && near(s.segment(1).map { ($0.1 - $0.0).length }!, 10, 1e-6))
    #expect(doc.features[0].kind == .box(width: 46, depth: 10, height: 3))
    // Nothing changes the second time.
    let again = try doc.applyParameters()
    #expect(again.isEmpty)
    let saved = try CADDocument.decode(doc.encoded())
    #expect(saved.features[0].expressions == box.expressions && saved.sketches[0].constraints[1].expression == "larghezza / 4")
    // A parameter the sketch cannot follow: an error, the document untouched.
    doc.parameters[0].expression = "manca + 1"
    let before = doc
    #expect(throws: ExpressionError.self) { var d = doc; try d.applyParameters() }
    #expect(doc == before)
}

@Test func aSizeChangedByHandDropsItsExpression() throws {
    var box = Feature(name: "B", kind: .box(width: 10, depth: 10, height: 3))
    box.expressions = ["height": "spessore", "width": "10"]
    var doc = CADDocument(features: [box])
    doc.parameters = [.init(name: "spessore", expression: "3")]
    let none = doc.dropStaleExpressions()
    #expect(!none)
    doc.features[0].setSize("height", 8)   // Premi/Tira
    let dropped = doc.dropStaleExpressions()
    #expect(dropped)
    #expect(doc.features[0].expressions == ["width": "10"])
    doc.parameters[0].expression = "5"
    _ = try doc.applyParameters()
    #expect(doc.features[0].size("height") == 8)
}
