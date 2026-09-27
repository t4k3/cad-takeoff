import Foundation
import Testing
@testable import CADCore

private typealias F = FusionTimeline

/// A bracket as the add-in describes it: parameters, a dimensioned sketch (60 × 40 with a Ø8
/// hole in the middle), extruded by «spessore», one vertical edge rounded R3.
private func bracket() -> FusionTimeline {
    let pts = [F.Point(id: "p1", x: 0, y: 0, fixed: true), F.Point(id: "p2", x: 60, y: 0), F.Point(id: "p3", x: 60, y: 40), F.Point(id: "p4", x: 0, y: 40),
               F.Point(id: "p5", x: 30, y: 20)]
    let curves = [F.Curve(type: "line", id: "l1", start: "p1", end: "p2"), F.Curve(type: "line", id: "l2", start: "p2", end: "p3"),
                  F.Curve(type: "line", id: "l3", start: "p3", end: "p4"), F.Curve(type: "line", id: "l4", start: "p4", end: "p1"),
                  F.Curve(type: "circle", id: "c1", center: "p5", radius: 4)]
    let sketch = F.Sketch(id: "S1", name: "Schizzo1", points: pts, curves: curves,
                          constraints: [F.Constraint(type: "horizontal", a: "l1"), F.Constraint(type: "horizontal", a: "l3"),
                                        F.Constraint(type: "vertical", a: "l2"), F.Constraint(type: "vertical", a: "l4")],
                          dimensions: [F.Dimension(type: "distance", a: "l1", value: 60, expression: "larghezza"),
                                       F.Dimension(type: "vertical", a: "l2", value: 40, expression: "40 mm"),
                                       F.Dimension(type: "diameter", a: "c1", value: 8, expression: "foro"),
                                       F.Dimension(type: "horizontal", a: "p1", b: "p5", value: 30, expression: "larghezza / 2"),
                                       F.Dimension(type: "vertical", a: "p1", b: "p5", value: 20, expression: "d7 / 2")],
                          profiles: [F.Profile(id: "P0", area: 2400 - .pi * 16, min: [0, 0], max: [60, 40])])
    return FusionTimeline(
        parameters: [F.Parameter(name: "larghezza", expression: "60 mm", value: 60, isUser: true),
                     F.Parameter(name: "spessore", expression: "5 mm", value: 5, comment: "lamiera", isUser: true),
                     F.Parameter(name: "foro", expression: "8 mm", value: 8, isUser: true),
                     F.Parameter(name: "d7", expression: "40 mm", value: 40, isUser: false)],
        sketches: [sketch],
        features: [F.Feature(type: "extrude", name: "Estrusione1", operation: "newBody", profiles: ["S1/P0"],
                             extent: F.Extent(type: "distance", distance: 5, expression: "spessore")),
                   F.Feature(type: "fillet", name: "Raccordo1", edges: [[[60, 40, 0], [60, 40, 2.5], [60, 40, 5]]], size: 3)],
        bodies: [F.Body(name: "Staffa", volume: (2400 - .pi * 16) * 5 - (9 - .pi * 9 / 4) * 5, min: [0, 0, 0], max: [60, 40, 5])])
}

@Test func fusionBracketComesInEditable() throws {
    let (doc, report) = FusionImport.convert(bracket(), meshes: [])
    #expect(report.editable == ["Staffa"] && report.meshes.isEmpty && report.skipped.isEmpty, "\(report.summary)")
    #expect(doc.parameters.map(\.name) == ["larghezza", "spessore", "foro"])
    #expect(doc.parameters.map(\.expression) == ["60", "5", "8"] && doc.parameters[1].comment == "lamiera")
    let sketch = try #require(doc.sketches.first)
    // Every constraint and dimension kept; the expressions that name a parameter too (d7, a
    // model parameter, inlined).
    let dims = sketch.constraints.filter { $0.kind.value != nil }
    #expect(dims.count == 5)
    #expect(Set(dims.compactMap(\.expression)) == ["larghezza", "foro", "larghezza / 2"])
    let extrude = try #require(doc.features.first { if case .extrude = $0.kind { true } else { false } })
    #expect(extrude.expressions["height"] == "spessore" && extrude.name == "Staffa")
    #expect(doc.features.contains { if case let .chamfer(c) = $0.kind { c.profile == .round && c.distance == 3 } else { false } })
    #expect(doc.sketchLinks.count == 1)

    // Editable for real: a wider bracket, the hole stays in the middle, the round follows.
    var wider = doc
    wider.parameters[0].expression = "80"
    for id in try wider.applyParameters() { if let s = wider.sketches.first(where: { $0.id == id }) { wider.regenerate(from: s) } }
    let (bodies, issues) = DesignEvaluator.evaluate(wider, revision: "w")
    #expect(issues.isEmpty, "\(issues)")
    let box = try #require(bodies.first?.mesh.bounds)
    #expect(abs(box.max.x - 80) < 1e-6 && abs(box.max.z - 5) < 1e-6)
    let hole = try #require(bodies.first?.snapshot.faces.compactMap { f -> Vec3? in if case let .cylinder(o, _, r) = f.surface, abs(r - 4) < 1e-6 { o } else { nil } }.first)
    #expect(abs(hole.x - 40) < 1e-6)
    #expect(abs(bodies[0].mesh.volume - ((3200 - .pi * 16) * 5 - (9 - .pi * 9 / 4) * 5)) < 0.005 * 16000)
}

@Test func fusionFeaturesNotConvertedFallBackToTheirMesh() throws {
    // A loft (not converted): the body comes in as the mesh Fusion made.
    let cube = try PrimitiveKernel.build(Feature(name: "c", kind: .box(width: 10, depth: 10, height: 10), position: Vec3(0, 0, 0))).mesh
    let mesh = Feature(name: "Tappo", kind: .importedMesh(ImportedMesh(mesh: cube, source: "Tappo.f3d")), color: PartColor(hex: "#C81E1E")!)
    let t = FusionTimeline(features: [F.Feature(type: "loft", name: "Loft1")],
                           bodies: [F.Body(name: "Tappo", volume: 1000, min: [-5, -5, 0], max: [5, 5, 10], mesh: 0)])
    let (doc, report) = FusionImport.convert(t, meshes: [mesh])
    #expect(report.editable.isEmpty && report.meshes == ["Tappo"] && report.skipped == ["Loft1: tipo loft non ancora convertito"])
    #expect(doc.features.count == 1 && doc.features[0].color == mesh.color)
    // A mix: the bracket rebuilt, a second body only as mesh.
    var mixed = bracket()
    mixed.features.append(F.Feature(type: "loft", name: "Loft1"))
    mixed.bodies.append(F.Body(name: "Tappo", volume: 1000, min: [-5, -5, 0], max: [5, 5, 10], mesh: 0))
    let (both, r2) = FusionImport.convert(mixed, meshes: [mesh])
    #expect(r2.editable == ["Staffa"] && r2.meshes == ["Tappo"])
    #expect(DesignEvaluator.evaluate(both, revision: "m").bodies.count == 2)
}

@Test func fusionRebuiltBodyThatDiffersIsHiddenAndReplaced() throws {
    // Fusion says the bracket is 8 thick (a feature we do not see changed it): the rebuilt one does
    // not match, so it is hidden and flagged, and the mesh stands in.
    var t = bracket()
    t.bodies[0] = F.Body(name: "Staffa", volume: 18000, min: [0, 0, 0], max: [60, 40, 8], mesh: 0)
    let cube = try PrimitiveKernel.build(Feature(name: "c", kind: .box(width: 60, depth: 40, height: 8), position: Vec3(30, 20, 0))).mesh
    let mesh = Feature(name: "Staffa", kind: .importedMesh(ImportedMesh(mesh: cube, source: "x.f3d")))
    let (doc, report) = FusionImport.convert(t, meshes: [mesh])
    #expect(report.editable.isEmpty && report.meshes == ["Staffa"])
    #expect(doc.features.contains { $0.name.hasPrefix("⚠︎") && !$0.isVisible })
}

@Test func fusionRevolveAndDecodeFromTheFtk() throws {
    // A Ø20 × 30 pin revolved on the XZ plane about its axis line, stored as the add-in writes it.
    let pts = [F.Point(id: "a", x: 0, y: 0), F.Point(id: "b", x: 10, y: 0), F.Point(id: "c", x: 10, y: 30), F.Point(id: "d", x: 0, y: 30)]
    let sketch = F.Sketch(id: "S", name: "Profilo", origin: [0, 0, 0], xAxis: [1, 0, 0], yAxis: [0, 0, 1], points: pts,
                          curves: [F.Curve(type: "line", id: "l1", start: "a", end: "b"), F.Curve(type: "line", id: "l2", start: "b", end: "c"),
                                   F.Curve(type: "line", id: "l3", start: "c", end: "d"), F.Curve(type: "line", id: "axis", start: "d", end: "a")],
                          dimensions: [F.Dimension(type: "distance", a: "l2", value: 30, expression: "altezza")],
                          profiles: [F.Profile(id: "P0", area: 300, min: [0, 0], max: [10, 30])])
    let t = FusionTimeline(parameters: [F.Parameter(name: "altezza", expression: "30 mm", value: 30, isUser: true)], sketches: [sketch],
                           features: [F.Feature(type: "revolve", name: "Rivoluzione1", operation: "newBody", profiles: ["S/P0"],
                                                axis: F.Axis(curve: "axis"), angle: 360)],
                           bodies: [F.Body(name: "Perno", volume: .pi * 100 * 30, min: [-10, -10, 0], max: [10, 10, 30])])
    var json = try JSONSerialization.jsonObject(with: CADDocument().encoded()) as! [String: Any]
    json["fusion"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(t))
    let doc = try CADDocument.decode(JSONSerialization.data(withJSONObject: json))
    #expect(doc.importReport?.hasPrefix("Da Fusion: 1 corpo modificabile") == true, "\(doc.importReport ?? "")")
    #expect(doc.features.contains { if case .revolve = $0.kind { $0.name == "Perno" } else { false } })
    // Saved, it is a plain design.
    #expect(!String(decoding: try doc.encoded(), as: UTF8.self).contains("\"fusion\""))
}

@Test func fusionExpressionsBecomeOurs() {
    let p: [String: F.Parameter] = ["a": F.Parameter(name: "a", expression: "10 mm", value: 10, isUser: true),
                                    "d3": F.Parameter(name: "d3", expression: "a * 2", value: 20, isUser: false),
                                    "d4": F.Parameter(name: "d4", expression: "3 cm", value: 30, isUser: false)]
    let users = ["a": 10.0]
    #expect(FusionImport.translate("a / 2 + 1 mm", value: 6, parameters: p, users: users) == "a / 2 + 1")
    #expect(FusionImport.translate("d3 + 5 mm", value: 25, parameters: p, users: users) == "(a * 2) + 5")
    #expect(FusionImport.translate("2 cm", value: 20, parameters: p, users: users) == nil)            // plain number: no expression
    #expect(FusionImport.translate("2 cm", value: 20, parameters: p, users: users, keepPlain: true) == "2 * 10")
    #expect(FusionImport.translate("a + d4", value: 40, parameters: p, users: users) == "a + (3 * 10)")
    #expect(FusionImport.translate("a * 3", value: 31, parameters: p, users: users) == nil)           // does not give the value
    #expect(FusionImport.translate("unknown + 1", value: 1, parameters: p, users: users) == nil)
}
