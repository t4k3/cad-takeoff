import Foundation
import CADCore

@main struct SheetMetalFixture {
    static func main() throws {
        let directory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let rule = try SheetMetalRule(id: UUID(uuidString: "33333333-3333-3333-3333-333333333333")!,
                                     name: "Prova: K da calibrare", thickness: 2, insideRadius: 3, kFactor: 0.4)
        let part = try SheetMetalPart(id: UUID(uuidString: "44444444-4444-4444-4444-444444444444")!,
                                     name: "Staffa L di prova", rule: rule, width: 40, baseLength: 60)
            .addingFlange(.init(length: 30, angleDegrees: 90))
        // All exports are rebuilt from the serialized history, not from an in-memory-only mesh.
        try part.encoded().write(to: directory.appendingPathComponent("LBracket.sheetmetal.json"))
        let reopened = try SheetMetalPart.decode(Data(contentsOf: directory.appendingPathComponent("LBracket.sheetmetal.json")))
        let result = try SheetMetalEngine.rebuild(reopened)
        try STLExporter.binary(result.foldedBody.mesh).write(to: directory.appendingPathComponent("LBracket.stl"))
        try ThreeMFExporter.archive(parts: [.init(id: part.id, name: part.name, mesh: result.foldedBody.mesh,
                                                color: PartColor(hex: "#6C93B5")!)])
            .write(to: directory.appendingPathComponent("LBracket.3mf"))
        try ThreeMFExporter.archive(parts: [.init(id: part.id, name: "Sviluppo staffa L", mesh: result.flatPattern.mesh,
                                                color: PartColor(hex: "#6EA690")!)])
            .write(to: directory.appendingPathComponent("LBracket-flat.3mf"))
        try SheetMetalDXF.export(result.flatPattern, for: reopened)
            .write(to: directory.appendingPathComponent("LBracket-flat.dxf"), atomically: true, encoding: .utf8)
        let down = try part.editingFlange(.init(length: 30, angleDegrees: 90, direction: .down))
        try SheetMetalDXF.export(SheetMetalEngine.rebuild(down).flatPattern, for: down)
            .write(to: directory.appendingPathComponent("LBracket-down-flat.dxf"), atomically: true, encoding: .utf8)
        let report: [String: Any] = [
            "partID": part.id.uuidString, "partRevision": part.revision,
            "ruleRevision": part.rule.revision, "operationIDs": part.operations.map { $0.id.uuidString },
            "thickness": rule.thickness, "insideRadius": rule.insideRadius, "kFactor": rule.kFactor,
            "baseLength": 60, "flangeLength": 30, "width": 40, "angleDegrees": 90, "bendSegments": 24,
            "bendAllowance": result.flatPattern.bendZones[0].allowance,
            "developedLength": result.flatPattern.developedLength,
            "maximumSurfaceDeviation": result.foldedBody.maximumSurfaceDeviation,
            "manufacturingCalibrated": false
        ]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            .write(to: directory.appendingPathComponent("report.json"))
        print("Sheet metal fixture: saved/reopened history → folded STL/3MF + flat DXF/3MF")
    }
}
