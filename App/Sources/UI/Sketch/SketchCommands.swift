import CADCore
import SwiftUI

/// "Estrudi" from a sketch shape: command panel with live wireframe preview; OK goes
/// through the Model's validated, undoable `add_extrude` command (no direct writes).
@MainActor
enum SketchCommands {
    static func extrude(sketch: SketchSession, model: DesignModel, workspace: WorkspaceState) -> CommandSession? {
        guard let shape = sketch.extrudeCandidate else { return nil }
        sketch.selection = shape.id
        let original = shape.kind
        let size = 0.01...10000.0

        var fields: [CommandField] = [.init(id: "h", label: "Distanza", kind: .length(size), value: .number(10),
                                            help: "Altezza dell'estrusione verso +Z")]
        switch original {
        case let .rectangle(a, b):
            fields += [.init(id: "w", label: "Larghezza", kind: .length(size), value: .number(abs(b.x - a.x))),
                       .init(id: "d", label: "Profondità", kind: .length(size), value: .number(abs(b.y - a.y)))]
        case let .circle(_, r):
            fields += [.init(id: "dia", label: "Diametro", kind: .length(size), value: .number(2 * r))]
        case let .polygon(_, r, _, _):
            fields += [.init(id: "r", label: "Raggio esterno", kind: .length(size), value: .number(r))]
        case .polyline: break
        }

        func reshaped(_ f: [CommandField]) -> SketchSession.Shape.Kind {
            let v = { (k: String) in f.first { $0.id == k }?.number ?? 0 }
            switch original {
            case let .rectangle(a, b):
                let lo = Vec2(min(a.x, b.x), min(a.y, b.y))
                return .rectangle(lo, Vec2(lo.x + v("w"), lo.y + v("d")))
            case let .circle(c, _): return .circle(center: c, radius: v("dia") / 2)
            case let .polygon(c, _, n, s): return .polygon(center: c, radius: v("r"), sides: n, start: s)
            case .polyline: return original
            }
        }

        sketch.previewHeight = 10
        return CommandSession(
            title: "Estrudi", symbol: "square.stack.3d.up", fields: fields,
            onPreview: { f in
                guard f.allSatisfy({ $0.validationMessage == nil }) else { return }
                sketch.replace(shape.id, with: reshaped(f))
                sketch.previewHeight = f.first { $0.id == "h" }?.number
            },
            onCommit: { f in
                sketch.replace(shape.id, with: reshaped(f))
                let outline = sketch.shapes.first { $0.id == shape.id }?.outline ?? []
                let height = f.first { $0.id == "h" }?.number ?? 10
                sketch.previewHeight = nil
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
                        if let id = r.changedFeatures.first { model.selection = id }
                        workspace.exitSketch()
                    }
                }
            },
            onCancel: {
                sketch.replace(shape.id, with: original)
                sketch.previewHeight = nil
            })
    }
}
