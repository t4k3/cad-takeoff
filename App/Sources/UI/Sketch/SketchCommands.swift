import CADCore
import SwiftUI

/// "Estrudi" from a sketch profile: distance with wireframe preview; OK creates the solid
/// through the Model's validated, undoable `add_extrude` command. Profile dimensions are
/// edited in the Parametri panel before extruding.
@MainActor
enum SketchCommands {
    static func extrude(sketch: SketchSession, model: DesignModel, workspace: WorkspaceState) -> CommandSession? {
        guard let shape = sketch.extrudeCandidate, shape.profile != nil else { return nil }
        sketch.selection = shape.id
        sketch.previewHeight = 10
        return CommandSession(
            title: "Estrudi \(shape.typeName.lowercased())", symbol: "square.stack.3d.up",
            fields: [.init(id: "h", label: "Distanza", kind: .length(0.01...10000), value: .number(10),
                           help: "Altezza dell'estrusione verso +Z")],
            onPreview: { f in sketch.previewHeight = f.first?.number },
            onCommit: { f in
                let height = f.first?.number ?? 10
                sketch.previewHeight = nil
                let outline = sketch.shape(shape.id)?.outline ?? shape.outline
                let args: JSONValue = [
                    "points": .array(outline.map { ["x": .number($0.x), "y": .number($0.y)] }),
                    "height": .number(height),
                    "name": .string("Estrusione \(model.document.features.count + 1)"),
                    "expected_revision": .string(model.designRevision),
                ]
                Task {
                    // TODO(R2): model.addExtrude(profile:height:name:) when Codex adds the direct command.
                    let r = await model.call("add_extrude", arguments: args)
                    if r.isError {
                        model.statusMessage = "Estrusione non riuscita: \(r.text)"
                    } else {
                        model.statusMessage = "Estrusione creata (\(fmt(height)) mm) — ⌘Z per annullare"
                        if let id = r.changedFeatures.first {
                            model.selection = id
                            workspace.sketchStore?.link(feature: id, sketch: sketch.sketch.id, shape: shape.id)
                        }
                        workspace.exitSketch()
                    }
                }
            },
            onCancel: { sketch.previewHeight = nil })
    }
}
