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
        sketch.previewReversed = false
        let onFace = !sketch.sketch.plane.isXY
        func operation(_ f: [CommandField]) -> BooleanOperation {
            if case let .index(i)? = f.first(where: { $0.id == "op" })?.value { return BooleanOperation.allCases[i] }
            return .newBody
        }
        func reversed(_ f: [CommandField]) -> Bool {
            if case let .index(i)? = f.first(where: { $0.id == "dir" })?.value { return onFace && i == 1 }
            return false
        }
        var lastOp = BooleanOperation.newBody
        weak var session: CommandSession?
        let created = CommandSession(
            title: "Estrudi \(shape.typeName.lowercased())", symbol: "square.stack.3d.up",
            fields: [.init(id: "h", label: "Distanza", kind: .length(0.01...10000), value: .number(10),
                           help: onFace ? "Profondità dalla faccia" : "Altezza dell'estrusione verso +Z"),
                     .init(id: "op", label: "Operazione", kind: .choice(BooleanOperation.allCases.map(\.label)), value: .index(0),
                           help: "Nuovo corpo, oppure unisci/taglia/interseca i corpi che tocca"),
                     .init(id: "dir", label: "Direzione", kind: .choice(["Fuori dalla faccia", "Dentro il pezzo"]), value: .index(0),
                           help: "Su una faccia: un taglio va dentro il pezzo, un'unione verso l'esterno", isHidden: !onFace)],
            onPreview: { f in
                let op = operation(f)
                // Switching to «Taglia» on a face flips the direction into the part (once).
                if onFace, op == .cut, lastOp != .cut, case .index(0)? = f.first(where: { $0.id == "dir" })?.value {
                    lastOp = op
                    session?.update("dir") { $0.value = .index(1) }
                    return
                }
                lastOp = op
                sketch.previewHeight = f.first?.number
                sketch.previewIsCut = op == .cut
                sketch.previewReversed = reversed(f)
            },
            onCommit: { f in
                let height = f.first?.number ?? 10
                let op = operation(f)
                sketch.previewHeight = nil
                guard let current = sketch.shape(shape.id), let profile = current.profile else { return }
                let placement = onFace ? FeaturePlacement(plane: sketch.sketch.plane, reversed: reversed(f)) : nil
                let feature = Feature(name: (op == .cut ? "Taglio " : "Estrusione ") + "\(model.document.features.count + 1)",
                                      kind: .extrude(profile: profile, height: height), operation: op, placement: placement)
                do {
                    try CADToolValidation.feature(feature)
                } catch {
                    model.statusMessage = "Estrusione non riuscita: \(error.localizedDescription)"
                    return
                }
                // One undo step: saves the sketch, adds the solid and links it to the shape.
                let saved = sketch.sketch
                model.edit((op == .newBody ? "Estrudi " : op.label + ": ") + current.typeName.lowercased(), selected: .some(feature.id), changed: [feature.id]) { doc in
                    doc.upsert(saved)
                    doc.features.append(feature)
                    doc.sketchLinks.append(SketchLink(featureID: feature.id, sketchID: saved.id, shapeID: current.id))
                }
                model.statusMessage = "Estrusione creata (\(fmt(height)) mm) — ⌘Z per annullare"
                workspace.exitSketch()
            },
            onCancel: { sketch.previewHeight = nil })
        session = created
        return created
    }
}
