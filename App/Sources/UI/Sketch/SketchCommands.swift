import CADCore
import SwiftUI

/// "Estrudi" from a sketch profile: distance with wireframe preview; OK adds the validated solid,
/// saves the sketch and links them in one undoable step. Profile dimensions are edited in
/// the Parametri panel before extruding.
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
                guard let current = sketch.shape(shape.id), let profile = current.profile else { return }
                let feature = Feature(name: "Estrusione \(model.document.features.count + 1)",
                                      kind: .extrude(profile: profile, height: height))
                do {
                    try CADToolValidation.feature(feature)
                } catch {
                    model.statusMessage = "Estrusione non riuscita: \(error.localizedDescription)"
                    return
                }
                // One undo step: saves the sketch, adds the solid and links it to the shape.
                let saved = sketch.sketch
                model.edit("Estrudi \(current.typeName.lowercased())", selected: .some(feature.id), changed: [feature.id]) { doc in
                    doc.upsert(saved)
                    doc.features.append(feature)
                    doc.sketchLinks.append(SketchLink(featureID: feature.id, sketchID: saved.id, shapeID: current.id))
                }
                model.statusMessage = "Estrusione creata (\(fmt(height)) mm) — ⌘Z per annullare"
                workspace.exitSketch()
            },
            onCancel: { sketch.previewHeight = nil })
    }
}
