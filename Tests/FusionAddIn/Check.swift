import CADCore
import Foundation

/// Opens the .ftk written by the Fusion add-in (through fake_fusion.py) with the real CADCore.
@main struct FusionAddInCheck {
    static func main() throws {
        let url = URL(fileURLWithPath: CommandLine.arguments[1])
        let doc = try CADDocument.decode(Data(contentsOf: url))
        let (bodies, issues) = DesignEvaluator.evaluate(doc, revision: "check")
        func expect(_ c: Bool, _ m: String) { if !c { print("FAIL:", m); exit(1) } }
        expect(issues.isEmpty && bodies.count == 2, "two bodies, no issues: \(issues)")
        expect(bodies.map(\.source.name) == ["Base", "Perno:1 · Corpo1"], "names from bodies and components")
        expect(bodies[0].source.color == PartColor(hex: "#C81E1E")!, "appearance colour kept")
        // 2 cm cube → 20 mm; 8000 mm³; Y-up design turned Z-up: Fusion Y (0…20) becomes Z.
        expect(abs(bodies[0].mesh.volume - 8000) < 1e-3 && MeshValidator.validate(bodies[0].mesh).isWatertight, "cube volume in mm, closed")
        let b = bodies[0].mesh.bounds!
        expect(abs(b.max.z - 20) < 1e-4 && abs(b.min.y + 20) < 1e-4 && abs(b.max.x - 20) < 1e-4, "Y-up rotated to Z-up")
        expect(bodies[0].snapshot.faces.count == 6, "flat faces recognised")
        // The Base cube came with its history: rebuilt as a dimensioned sketch and an extrusion
        // (editable, «lato» a parameter); the component's body, without history, as its mesh.
        expect(doc.importReport?.hasPrefix("Da Fusion: 1 corpo modificabile, 1 come mesh") == true, "report: \(doc.importReport ?? "none")")
        expect(doc.parameters.map(\.name) == ["lato"] && doc.parameters[0].expression == "20", "user parameter")
        expect(doc.sketches.count == 1 && doc.sketches[0].constraints.filter { $0.expression == "lato" }.count == 2, "dimensions driven by lato")
        expect(doc.features.contains { if case .extrude = $0.kind { $0.expressions["height"] == "lato" } else { false } }, "extrusion by lato")
        var bigger = doc
        bigger.parameters[0].expression = "30"
        for id in try bigger.applyParameters() { if let s = bigger.sketches.first(where: { $0.id == id }) { bigger.regenerate(from: s) } }
        let grown = DesignEvaluator.evaluate(bigger, revision: "b").bodies[0].mesh
        expect(abs(grown.volume - 27000) < 1e-3, "lato 30: a 30 mm cube (\(grown.volume))")
        print("PASS: Fusion add-in export opens in CADCore (units, Y-up, components, colours, faces, editable history)")
    }
}
