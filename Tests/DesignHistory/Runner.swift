import Foundation
import CADCore

/// Phase 0 (T81): one undo history for every change; the assistant never undoes the user.
@main
struct DesignHistoryTests {
    @MainActor static func main() async throws {
        let m = DesignModel()
        m.newDesign()
        var checks = 0
        func expect(_ c: Bool, _ msg: String) { checks += 1; precondition(c, msg) }

        expect(!m.canUndo && !m.canRedo, "new design has empty history")
        m.addBox()
        let box = m.document.features[0]
        expect(m.canUndo && m.undoTitle == "Aggiungi \(box.name)", "add is one titled step")

        // Direct writes (inspector bindings) are recorded; typing in one field merges into one step.
        m.document.features[0].name = "B"
        m.document.features[0].name = "Ba"
        m.document.features[0].name = "Base"
        expect(m.history.undo.count == 2 && m.undoTitle == "Rinomina Base", "typing = one rename step")
        m.undo()
        expect(m.document.features[0].name == box.name, "⌘Z restores the name")
        m.redo()
        expect(m.document.features[0].name == "Base", "⇧⌘Z redoes it")

        m.document.features[0].isVisible = false
        expect(m.undoTitle == "Nascondi Base", "visibility step title")
        m.undo()
        expect(m.document.features[0].isVisible, "visibility undone")

        m.selection = m.document.features[0].id
        m.deleteSelected()
        expect(m.document.features.isEmpty && m.undoTitle == "Elimina Base", "delete is undoable")
        m.undo()
        expect(m.document.features.count == 1 && m.selection == box.id, "undo delete restores feature and selection")

        // A new edit clears redo.
        m.undo()
        expect(m.canRedo, "redo available")
        m.addCylinder()
        expect(!m.canRedo, "new edit clears redo")

        // Sketch → extrude as one step, then "Termina" regenerates the linked solid as one step.
        m.newDesign()
        var sk = Sketch(name: "Schizzo 1", shapes: [SketchShape(kind: .rectangle(corner: .init(0, 0), width: 40, height: 30))])
        let shapeID = sk.shapes[0].id
        let solid = Feature(name: "Estrusione 1", kind: .extrude(profile: sk.shapes[0].profile!, height: 10))
        m.edit("Estrudi rettangolo", selected: .some(solid.id), changed: [solid.id]) { doc in
            doc.upsert(sk); doc.features.append(solid)
            doc.sketchLinks.append(SketchLink(featureID: solid.id, sketchID: sk.id, shapeID: shapeID))
        }
        expect(m.history.undo.count == 1 && m.document.sketches.count == 1, "extrude from sketch = one step")
        expect(abs(m.document.buildMesh().volume - 12000) < 1e-6, "extruded volume")
        sk.shapes[0].kind = .rectangle(corner: .init(0, 0), width: 50, height: 30)
        m.edit(sk.name) { doc in doc.upsert(sk); doc.regenerate(from: sk) }
        expect(abs(m.document.buildMesh().volume - 15000) < 1e-6, "Termina regenerates the linked extrusion")
        m.undo()
        expect(abs(m.document.buildMesh().volume - 12000) < 1e-6 && m.document.sketches[0].shapes[0].area == 1200,
               "one ⌘Z restores both sketch and solid")
        // Deleting the shape drops the link but keeps the solid.
        sk.shapes.removeAll()
        m.edit(sk.name) { doc in doc.upsert(sk); doc.regenerate(from: sk) }
        expect(m.document.sketchLinks.isEmpty && m.document.features.count == 1, "orphan link dropped, solid kept")

        // The assistant cannot undo a user change, but can undo its own.
        m.document.features[0].name = "Utente"
        let refused = await m.call("undo", arguments: ["expected_revision": .string(m.designRevision)])
        expect(refused.isError && m.document.features[0].name == "Utente", "assistant never undoes the user")
        let added = await m.call("add_box", arguments: ["width": 5, "depth": 5, "height": 5, "expected_revision": .string(m.designRevision)])
        expect(!added.isError, "assistant adds a box")
        let undone = await m.call("undo", arguments: ["expected_revision": .string(m.designRevision)])
        expect(!undone.isError && m.document.features.count == 1, "assistant undoes its own step")

        // Timeline (phase 1): marker, suppression, delete — all undoable.
        m.newDesign()
        m.addBox(); m.addCylinder(); m.addHexPrism()
        let ids = m.document.timeline.map(\.id)
        m.moveRollback(to: 1)
        expect(m.document.activeFeatures.count == 1 && m.undoTitle == "Marker dopo il passo 1", "marker rolls back")
        expect(m.snapshot().bodies.count == 1, "renderer snapshot follows the marker")
        m.addBox()
        expect(m.document.timeline[1].name.hasPrefix("Box") && m.document.rollback == 2, "new step inserted at the marker")
        m.undo(); m.undo()
        expect(m.document.rollback == nil && m.document.activeFeatures.count == 3, "undo marker move")
        m.setSuppressed(ids[1], true)
        expect(m.document.activeFeatures.count == 2 && m.undoTitle?.hasPrefix("Sopprimi") == true, "suppress")
        m.undo()
        expect(m.document.activeFeatures.count == 3, "undo suppress")
        m.moveRollback(to: 2)
        m.deleteStep(ids[0])
        expect(m.document.rollback == 1 && m.document.activeFeatures.count == 1, "delete before marker moves it")
        m.undo()
        expect(m.document.timeline.map(\.id) == ids && m.document.rollback == 2, "undo delete restores order and marker")

        // Assembly: two instances of a sheet-metal part → one BOM row, quantity 2, mass from DC01.
        let bracket = CADDocument(features: [Feature(name: "Staffa", kind: .sheetMetal(SheetMetalSpec(material: "dc01", thickness: 2,
                                                   width: 40, depth: 60, flanges: [.front: SheetFlange(length: 30)])))])
        m.componentResolver = { $0 == "P/Staffa.ftk" ? bracket : nil }
        m.replaceDocument(CADDocument(features: [
            Feature(name: "Staffa", kind: .component(ComponentRef(path: "P/Staffa.ftk"))),
            Feature(name: "Staffa (2)", kind: .component(ComponentRef(path: "P/Staffa.ftk", rotation: Vec3(0, 0, 180))), position: Vec3(0, 80, 0)),
        ]), status: "Assieme")
        let bom = m.billOfMaterials()
        expect(bom.count == 1 && bom[0].quantity == 2 && bom[0].material.hasPrefix("Acciaio DC01"), "BOM groups the instances")
        expect(abs((bom[0].mass ?? 0) - bom[0].volume * 7.85e-6) < 1e-9 && m.evaluation().bodies.count == 2, "mass from the material, two bodies")

        // Opening a file starts a fresh history.
        m.replaceDocument(CADDocument(), status: "Aperto")
        expect(!m.canUndo && !m.canRedo, "open/new clears history")
        print("PASS: \(checks) undo/redo assertions (manual, merged typing, delete, sketch transactions, assistant rule)")
    }
}
