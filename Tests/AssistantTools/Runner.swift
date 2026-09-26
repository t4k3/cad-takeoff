import Foundation
import CADCore

@main
struct AssistantToolsTests {
    @MainActor static func main() async throws {
        let m = DesignModel()
        m.newDesign()
        var checks = 0
        func expect(_ condition: Bool, _ message: String) { checks += 1; precondition(condition, message) }
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
        expect(Set(m.tools.map(\.name)).count == 20, "20 unique tools")
        let partID = m.document.features[0].id
        let beforeColour = m.document
        let coloured = await edit("set_color", ["feature_id": .string(partID.uuidString), "color": "#E53935"])
        expect(!coloured.isError && m.document.features[0].color.hex == "#E53935", "assistant sets colour")
        let get = await m.call("get_feature", arguments: ["feature_id": .string(partID.uuidString)])
        expect(get.structured?["feature"]?["color"]?.string == "#E53935", "MCP reads colour")
        let afterColour = m.document
        let badColour = await edit("set_color", ["feature_id": .string(partID.uuidString), "color": "red"])
        expect(badColour.isError && m.document == afterColour, "bad colour rejected atomically")
        _ = await edit("undo", [:])
        expect(m.document == beforeColour, "undo restores exact previous colour")
        _ = await edit("redo", [:])
        expect(m.document == afterColour, "redo colour")
        try m.setFeatureColor(partID, color: PartColor(hex: "#1E88E5")!)
        expect(m.document.features[0].color.hex == "#1E88E5", "inspector shares colour transaction")
        let assistantUndo = await edit("undo", [:])
        expect(assistantUndo.isError && m.document.features[0].color.hex == "#1E88E5", "assistant never undoes a user colour")
        m.undo()
        expect(m.document == afterColour, "inspector colour has ⌘Z undo")
        m.redo()
        expect(m.document.features[0].color.hex == "#1E88E5", "⌘⇧Z redoes the user colour")
        m.undo()
        let printRevision = m.designRevision
        let threeMF = await m.call("export_3mf", arguments: ["feature_id": .string(partID.uuidString)])
        let bytes = Data(base64Encoded: threeMF.structured?["data"]?.string ?? "") ?? Data()
        expect(!threeMF.isError && bytes.prefix(4) == Data([0x50, 0x4B, 0x03, 0x04]), "3MF package via chat")
        expect(String(decoding: bytes, as: UTF8.self).contains("#E53935FF"), "colour in exported package")
        expect(printRevision == m.designRevision, "export is read only")
        let visibleData = try m.export3MFData()
        expect(!String(decoding: visibleData, as: UTF8.self).contains(partID.uuidString), "whole export omits hidden parts")
        let noPaths = await m.call("export_3mf", arguments: ["path": "/tmp/should-not-write.3mf"])
        expect(noPaths.isError, "3MF rejects arbitrary file paths")
        let colouredBox = await edit("add_box", ["width": 10, "depth": 10, "height": 10, "color": "#ABCDEF"])
        expect(!colouredBox.isError && m.document.features.last?.color.hex == "#ABCDEF", "create with colour")
        let updatedColour = await edit("update_feature", ["feature_id": colouredBox.structured!["feature_id"]!, "color": "#123456"])
        expect(!updatedColour.isError && m.document.features.last?.color.hex == "#123456", "update with colour")
        expect(try CADDocument.decode(m.document.encoded()) == m.document, "colours survive document save/reopen")
        // Renderer snapshot is read-only, revision-consistent and comes from the kernel.
        let snapshotRevision = m.designRevision
        let snapshot = m.snapshot()
        expect(snapshot.issues.isEmpty && snapshot.bodies.count == m.document.features.filter(\.isVisible).count, "visible kernel bodies")
        expect(snapshot.bodies.allSatisfy { $0.revision == snapshotRevision }, "one revision per renderer result")
        expect(m.snapshot() == snapshot && m.designRevision == snapshotRevision, "cached snapshot is read only")
        let visibleID = m.document.features.last!.id
        let originalFaces = snapshot.bodies.first { $0.bodyID == visibleID }!.faces.map(\.id)
        _ = await edit("update_feature", ["feature_id": .string(visibleID.uuidString), "height": 17])
        let resized = m.snapshot()
        expect(resized.revision != snapshot.revision, "editing invalidates snapshot cache")
        expect(resized.bodies.first { $0.bodyID == visibleID }!.faces.map(\.id) == originalFaces, "box references survive resize")
        _ = await edit("undo", [:])
        let restored = m.snapshot().bodies.first { $0.bodyID == visibleID }!
        expect(restored.positions == snapshot.bodies.first { $0.bodyID == visibleID }!.positions, "undo restores snapshot geometry")
        let validDocument = m.document
        m.document.features.append(Feature(name: "Invalid", kind: .box(width: -1, depth: 2, height: 3)))
        let diagnosed = m.snapshot()
        expect(diagnosed.issues.count == 1 && diagnosed.bodies.count == snapshot.bodies.count, "bad body reported, valid bodies retained")
        m.document = validDocument
        m.document.timeline.append(m.document.timeline.last!)   // corrupted file: same ID twice
        expect(m.snapshot().issues.count == 1 && !m.snapshot().bodies.contains { $0.bodyID == visibleID }, "duplicate IDs cannot create ambiguous renderer references")
        m.newDesign()
        expect(m.snapshot().bodies.isEmpty && m.snapshot().issues.isEmpty, "new document clears cached bodies")
        // Phase 3: the assistant can drill a through hole with operation cut.
        _ = await edit("add_box", ["width": 40, "depth": 30, "height": 5, "name": "Piastra"])
        let drilled = await edit("add_cylinder", ["radius": 3, "height": 20, "position": ["x": 0, "y": 0, "z": -5], "operation": "cut"])
        let info = await m.call("scene_info", arguments: [:])
        let expectedVolume = 6000 - Profile2D.circle(radius: 3, segments: 64).area * 5
        expect(!drilled.isError && info.structured?["body_count"]?.number == 1, "cut modifies the plate, no new body")
        expect(abs((info.structured?["mesh_volume_mm3"]?.number ?? 0) - expectedVolume) < 1e-3, "hole volume removed")
        expect(info.structured?["edge_closed"]?.bool == true, "drilled plate is closed")
        let badOp = await edit("add_box", ["width": 1, "depth": 1, "height": 1, "operation": "weld"])
        expect(badOp.isError, "unknown operation rejected")
        // Hole tool: 4 counterbored M3 holes at the plate corners.
        m.newDesign()
        _ = await edit("add_box", ["width": 40, "depth": 30, "height": 5, "name": "Piastra"])
        let corners: JSONValue = .array([-15.0, 15.0].flatMap { x in [-10.0, 10.0].map { y in ["x": .number(x), "y": .number(y), "z": 5] } })
        let holes = await edit("add_hole", ["centers": corners, "style": "counterbore", "fit": "clearance", "size": "M3"])
        let holeInfo = await m.call("scene_info", arguments: [:])
        let cb = Profile2D.circle(radius: 3.25, segments: 64).area, bore = Profile2D.circle(radius: 1.7, segments: 64).area
        let expectedHoles = 6000 - 4 * (cb * 3.3 + bore * (5 - 3.3))
        expect(!holes.isError && holeInfo.structured?["body_count"]?.number == 1, "holes modify the plate")
        expect(abs((holeInfo.structured?["mesh_volume_mm3"]?.number ?? 0) - expectedHoles) < 1e-2, "counterbore volumes removed")
        expect(holeInfo.structured?["edge_closed"]?.bool == true, "drilled plate closed")
        let thread = await edit("add_hole", ["centers": .array([["x": 0, "y": 0, "z": 5]]), "fit": "modeledThread", "size": "M6"])
        expect(thread.isError, "modelled thread not offered yet")
        // Chamfer tool: 1 mm on the top edges of a plate.
        m.newDesign()
        let plateID = (await edit("add_box", ["width": 40, "depth": 30, "height": 5, "name": "Piastra"])).structured?["feature_id"]?.string ?? ""
        let ch = await edit("add_chamfer", ["feature_id": .string(plateID), "edges": "top", "distance": 1])
        let chInfo = await m.call("scene_info", arguments: [:])
        expect(!ch.isError && ch.structured?["edge_count"]?.number == 4, "chamfer on 4 top edges")
        expect(abs((chInfo.structured?["mesh_volume_mm3"]?.number ?? 0) - (6000 - 70 + 4.0 / 3)) < 1e-6, "chamfer volume")
        expect(chInfo.structured?["edge_closed"]?.bool == true, "chamfered plate closed")
        let tooBig = await edit("add_chamfer", ["feature_id": .string(plateID), "edges": "vertical", "distance": 1, "mode": "distanceAngle", "angle": 95])
        expect(tooBig.isError, "chamfer angle out of range rejected")
        let rounded = await edit("add_chamfer", ["feature_id": .string(plateID), "edges": "vertical", "distance": 3, "profile": "round"])
        let roundInfo = await m.call("scene_info", arguments: [:])
        expect(!rounded.isError && rounded.structured?["edge_count"]?.number == 4, "round on 4 vertical edges")
        let chamferedVolume: Double = 6000 - 70 + 4.0 / 3
        let roundedVolume: Double = roundInfo.structured?["mesh_volume_mm3"]?.number ?? 0
        expect(roundedVolume < chamferedVolume - 20, "round removes the corners")
        expect(roundInfo.structured?["edge_closed"]?.bool == true, "rounded plate closed")
        // Pocket from the top face of a plate (sketch on face, into the part).
        m.newDesign()
        _ = await edit("add_box", ["width": 40, "depth": 30, "height": 5, "name": "Piastra"])
        let square: JSONValue = .array([[-5, -5], [5, -5], [5, 5], [-5, 5]].map { ["x": .number($0[0]), "y": .number($0[1])] })
        let pocket = await edit("add_extrude", ["points": square, "height": 3, "operation": "cut",
                                                "face_point": ["x": 0, "y": 0, "z": 5], "face_normal": ["x": 0, "y": 0, "z": 1], "into_part": true])
        let pocketInfo = await m.call("scene_info", arguments: [:])
        expect(!pocket.isError && abs((pocketInfo.structured?["mesh_volume_mm3"]?.number ?? 0) - 5700) < 1e-6, "pocket from the top face")
        // Mirror a plate about its left face, joined: twice the volume, one body.
        m.newDesign()
        let half = (await edit("add_box", ["width": 20, "depth": 10, "height": 5, "position": ["x": 10, "y": 0, "z": 0]])).structured?["feature_id"]?.string ?? ""
        let mirror = await edit("add_pattern", ["body_feature_id": .string(half), "kind": "mirror", "plane": "yz", "offset": 0, "join": true])
        let mirrorInfo = await m.call("scene_info", arguments: [:])
        expect(!mirror.isError && mirrorInfo.structured?["body_count"]?.number == 1
               && abs((mirrorInfo.structured?["mesh_volume_mm3"]?.number ?? 0) - 2000) < 1e-6, "mirror joined into one body")
        let cut = await edit("add_split", ["body_feature_id": .string(half), "plane": "xy", "offset": 2])
        let cutInfo = await m.call("scene_info", arguments: [:])
        expect(!cut.isError && cutInfo.structured?["body_count"]?.number == 2, "split in two bodies")
        // Sheet metal: U channel in DC01 2 mm with the workshop rule.
        m.newDesign()
        let channel = await edit("add_sheet_metal", ["material": "dc01", "thickness": 2, "width": 100, "depth": 40,
                                                    "flange_sides": .array(["front", "back"]), "flange_length": 25])
        let sheetInfo = await m.call("scene_info", arguments: [:])
        expect(!channel.isError && channel.structured?["inside_radius"]?.number == 2.6, "sheet metal with table radius")
        expect(sheetInfo.structured?["edge_closed"]?.bool == true && sheetInfo.structured?["body_count"]?.number == 1, "sheet metal body closed")
        let oddThickness = await edit("add_sheet_metal", ["material": "dc01", "thickness": 1.7, "width": 50, "depth": 50])
        expect(oddThickness.isError, "non-commercial thickness rejected")
        let tooShort = await edit("add_sheet_metal", ["material": "dc01", "thickness": 2, "width": 50, "depth": 50,
                                                     "flange_sides": .array(["left"]), "flange_length": 3])
        expect(tooShort.isError, "flange shorter than the bend rejected")
        let dxf = await m.call("export_flat_dxf", arguments: [:])
        let dxfText = dxf.structured?["data"]?.string.flatMap { Data(base64Encoded: $0) }.flatMap { String(data: $0, encoding: .utf8) } ?? ""
        expect(!dxf.isError && dxfText.contains("BEND_UP") && dxfText.hasSuffix("EOF\n"), "flat pattern DXF via tool")
        print("PASS: \(checks) CAD assistant assertions (geometry, revisions, undo/redo, validation, STL and coloured 3MF)")
    }
}
