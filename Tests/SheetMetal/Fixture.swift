import Foundation
import CADCore

/// Sheet-metal fixture (T79): an L bracket in DC01 2 mm with the material's press-brake rule,
/// saved as a design, reopened, then exported (folded STL/3MF, flat 3MF/DXF) for verify.py.
@main struct SheetMetalFixture {
    static func main() throws {
        let directory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let id = UUID(uuidString: "44444444-4444-4444-4444-444444444444")!
        let spec = SheetMetalSpec(material: "dc01", thickness: 2, width: 40, depth: 60, flanges: [.front: SheetFlange(length: 30)])
        let doc = CADDocument(features: [Feature(id: id, name: "Staffa L", kind: .sheetMetal(spec), color: PartColor(hex: "#6C93B5")!)])
        // Everything below is rebuilt from the saved design, not from in-memory geometry.
        try doc.encoded().write(to: directory.appendingPathComponent("LBracket.ftk"))
        let reopened = try CADDocument.decode(Data(contentsOf: directory.appendingPathComponent("LBracket.ftk")))
        guard case let .sheetMetal(saved)? = reopened.features.first?.kind else { fatalError("sheet metal feature lost") }
        let body = DesignEvaluator.evaluate(reopened, revision: "fixture").bodies[0]
        let build = try SheetMetalGeometry.build(saved, featureID: id)
        try STLExporter.binary(body.mesh).write(to: directory.appendingPathComponent("LBracket.stl"))
        try ThreeMFExporter.archive(parts: [.init(id: id, name: "Staffa L", mesh: body.mesh, color: PartColor(hex: "#6C93B5")!)])
            .write(to: directory.appendingPathComponent("LBracket.3mf"))
        try ThreeMFExporter.archive(parts: [.init(id: id, name: "Sviluppo staffa L", mesh: SheetMetalGeometry.flatMesh(build.flat),
                                                color: PartColor(hex: "#6EA690")!)])
            .write(to: directory.appendingPathComponent("LBracket-flat.3mf"))
        try SheetMetalDXF.export(build.flat, rule: build.rule, name: "Staffa L")
            .write(to: directory.appendingPathComponent("LBracket-flat.dxf"), atomically: true, encoding: .utf8)
        var down = saved
        down.front = SheetFlange(length: 30, direction: .down)
        let downBuild = try SheetMetalGeometry.build(down, featureID: id)
        try SheetMetalDXF.export(downBuild.flat, rule: downBuild.rule, name: "Staffa L giù")
            .write(to: directory.appendingPathComponent("LBracket-down-flat.dxf"), atomically: true, encoding: .utf8)
        let report: [String: Any] = [
            "material": build.rule.material.id, "thickness": build.rule.thickness, "insideRadius": build.rule.insideRadius,
            "kFactor": build.rule.kFactor, "vDie": build.rule.vDie, "minimumFlange": build.rule.minimumFlange,
            "width": 40, "depth": 60, "flangeOutside": 30, "bendSegments": 16,
            "flatArea": build.flat.area, "warnings": build.warnings
        ]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            .write(to: directory.appendingPathComponent("report.json"))
        print("Sheet metal fixture: saved/reopened design → folded STL/3MF + flat DXF/3MF")
    }
}
