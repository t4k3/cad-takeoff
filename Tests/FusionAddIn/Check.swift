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
        print("PASS: Fusion add-in export opens in CADCore (units, Y-up, components, colours, faces)")
    }
}
