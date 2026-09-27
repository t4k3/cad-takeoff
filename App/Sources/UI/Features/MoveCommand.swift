import CADCore
import SwiftUI

/// «Sposta» (Fusion's Move/Copy): the selected body shifted along X, Y, Z and turned about an
/// axis through its centre, with a live preview; a step of the timeline (editable later).
@MainActor
enum MoveCommand {
    static let axes = ["Z", "X", "Y"]
    static let axisVectors = [Vec3(0, 0, 1), Vec3(1, 0, 0), Vec3(0, 1, 0)]

    static func start(workspace: WorkspaceState, model: DesignModel, editing original: Feature? = nil) -> CommandSession? {
        let spec: MoveSpec
        if let original, case let .move(s) = original.kind { spec = s } else {
            guard let body = model.selection else { model.statusMessage = "Seleziona prima il corpo da spostare."; return nil }
            // The body a later feature changed is still named by its first feature.
            let source = model.evaluation().bodies.first { $0.id == body || $0.modifiedBy.contains(body) }?.id ?? body
            spec = MoveSpec(bodies: [source])
        }
        let names = spec.bodies.compactMap { id in model.document.features.first { $0.id == id }?.name }.joined(separator: ", ")
        func build(_ f: [CommandField]) -> Feature {
            let v = { (k: String) in f.first { $0.id == k }?.number ?? 0 }
            var s = spec
            s.translation = Vec3(v("x"), v("y"), v("z"))
            if case let .index(i)? = f.first(where: { $0.id == "axis" })?.value { s.axis = axisVectors[i] }
            s.angle = v("angle")
            var feature = original ?? Feature(name: "Sposta \(model.document.features.count + 1)", kind: .move(s))
            feature.kind = .move(s)
            return feature
        }
        func document(_ f: [CommandField]) -> CADDocument {
            var doc = model.document
            let feature = build(f)
            if let i = doc.features.firstIndex(where: { $0.id == feature.id }) { doc.features[i] = feature } else { doc.features.append(feature) }
            return doc
        }
        let axisIndex = axisVectors.firstIndex { ($0 - spec.axis.normalized).length < 1e-9 } ?? 0
        return CommandSession(
            title: original == nil ? "Sposta" : "Modifica \(original!.name)", symbol: "arrow.up.and.down.and.arrow.left.and.right",
            fields: [
                .init(id: "what", label: "Corpo: " + names, kind: .note(warning: false), value: .flag(false)),
                .init(id: "x", label: "X", kind: .length(-100_000...100_000), value: .number(spec.translation.x)),
                .init(id: "y", label: "Y", kind: .length(-100_000...100_000), value: .number(spec.translation.y)),
                .init(id: "z", label: "Z", kind: .length(-100_000...100_000), value: .number(spec.translation.z)),
                .init(id: "axis", label: "Ruota attorno a", kind: .choice(axes), value: .index(axisIndex),
                      help: "Asse del mondo che passa per il centro del corpo"),
                .init(id: "angle", label: "Angolo", kind: .angle(-360...360), value: .number(spec.angle)),
            ],
            onPreview: { workspace.requestPreview(document($0)) },
            onCommit: { f in
                workspace.requestPreview(nil)
                let feature = build(f)
                guard case let .move(s) = feature.kind, s.translation.length > 1e-9 || abs(s.angle) > 1e-9 else {
                    model.statusMessage = "Nessuno spostamento: scrivi una distanza o un angolo."; return
                }
                model.edit(original == nil ? "Sposta \(names)" : "Modifica \(feature.name)", selected: .some(spec.bodies.first), changed: [feature.id]) { $0 = document(f) }
            },
            onCancel: { workspace.requestPreview(nil) })
    }
}
