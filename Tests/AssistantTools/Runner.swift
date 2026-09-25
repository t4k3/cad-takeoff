import Foundation
import CADCore

@main
struct AssistantToolsTests {
    @MainActor static func main() async throws {
        let m = DesignModel()
        m.newDesign()
        func expect(_ condition: Bool, _ message: String) { precondition(condition, message) }
        func edit(_ tool: String, _ args: [String: JSONValue]) async -> ToolResult {
            var a = args; a["expected_revision"] = .string(m.designRevision)
            return await m.call(tool, arguments: .object(a))
        }
        let start = await m.call("scene_info", arguments: [:])
        expect(!start.isError && start.structured?["edge_closed"] == .null, "empty scene")
        let revision = m.designRevision
        let box = await edit("add_box", ["width": 40, "depth": 30, "height": 20, "name": "Base"])
        expect(!box.isError && m.document.features.count == 1, "box creation")
        let id = box.structured!["feature_id"]!
        let scene = await m.call("scene_info", arguments: [:])
        expect(scene.structured?["mesh_volume_mm3"]?.number == 24000, "analytic box volume")
        expect(scene.structured?["edge_closed"]?.bool == true, "closed box")
        let beforeStale = m.document
        let stale = await m.call("add_cylinder", arguments: ["radius": 5, "height": 10, "expected_revision": .string(revision)])
        expect(stale.isError && m.document == beforeStale, "two clients cannot overwrite stale geometry")
        let invalid = await edit("update_feature", ["feature_id": id, "height": -1])
        expect(invalid.isError && m.document == beforeStale, "invalid update is atomic")
        let unrelated = await edit("update_feature", ["feature_id": id, "radius": 3])
        expect(unrelated.isError && m.document == beforeStale, "inapplicable field rejected")
        let nonfinite = await edit("add_box", ["width": .number(.nan), "depth": 10, "height": 10])
        expect(nonfinite.isError, "nonfinite argument")
        let changed = await edit("update_feature", ["feature_id": id, "height": 25, "position": ["x": 3, "y": 4, "z": 5]])
        expect(!changed.isError && m.document.features.first?.id.uuidString == id.string, "stable feature ID")
        let after = m.document
        let undone = await edit("undo", [:])
        expect(!undone.isError && m.document == beforeStale, "undo exact parameters")
        let redone = await edit("redo", [:])
        expect(!redone.isError && m.document == after, "redo exact parameters")
        let noOpRevision = m.designRevision
        _ = await edit("update_feature", ["feature_id": id, "height": 25])
        expect(noOpRevision == m.designRevision, "no-op does not advance revision")
        let bowtie = await edit("add_extrude", ["height": 5, "points": [["x": 0, "y": 0], ["x": 10, "y": 10], ["x": 0, "y": 10], ["x": 10, "y": 0]]])
        expect(bowtie.isError && m.document == after, "self intersection rejected atomically")
        let concave = await edit("add_extrude", ["height": 5, "points": [["x": 0, "y": 0], ["x": 20, "y": 0], ["x": 20, "y": 10], ["x": 10, "y": 10], ["x": 10, "y": 20], ["x": 0, "y": 20]]])
        expect(!concave.isError, "concave polygon accepted")
        let concaveFeature = m.document.features.last!
        expect(abs(concaveFeature.buildMesh().volume - 1500) < 1e-8, "concave extrusion volume")
        let cyl = await edit("add_cylinder", ["radius": 5, "height": 20, "position": ["x": 100, "y": 0, "z": 0]])
        expect(!cyl.isError, "cylinder")
        let export = await m.call("export_stl", arguments: ["feature_id": id])
        let data = Data(base64Encoded: export.structured?["data"]?.string ?? "")!
        expect(!export.isError && data.count == 684, "binary STL 12 triangles")
        expect(Array(data[80..<84]) == [12, 0, 0, 0], "STL triangle header")
        let badPath = await m.call("export_stl", arguments: ["path": "/tmp/should-not-write.stl"])
        expect(badPath.isError, "arbitrary path refused")
        _ = await edit("set_visibility", ["feature_id": id, "visible": false])
        let all = await m.call("list_features", arguments: [:])
        expect(all.structured?["features"]?.array?.count == 3, "hidden geometry remains addressable")
        _ = await edit("delete_feature", ["feature_id": id])
        expect(!m.document.features.contains { $0.id.uuidString == id.string }, "delete feature")
        _ = await edit("undo", [:])
        expect(m.document.features.contains { $0.id.uuidString == id.string }, "undo deletion restores ID")
        m.document.features[0].name = "Modifica manuale"
        let undoManual = await edit("undo", [:])
        expect(undoManual.isError && m.document.features[0].name == "Modifica manuale", "manual edits cannot be lost by assistant undo")
        let invalidShape = await m.call("scene_info", arguments: .array([]))
        expect(invalidShape.isError, "JSON shape validation")
        let missing = await m.call("get_feature", arguments: ["feature_id": .string(UUID().uuidString)])
        expect(missing.isError, "unknown ID")
        expect(Set(m.tools.map(\.name)).count == 12, "12 unique tools")
        print("PASS: 25 CAD assistant assertions (geometry, revisions, atomic edits, undo/redo, validation, STL)")
    }
}
