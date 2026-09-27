import CADCore
import SwiftUI

/// «Vista esplosa»: every visible body pushed away from the assembly's centre in proportion to
/// its distance (so the parts separate along the way they are assembled). A view only: the design
/// does not change; Chiudi or Esc brings the parts back.
@MainActor
enum ExplodeCommand {
    static func start(workspace: WorkspaceState, model: DesignModel) -> CommandSession {
        let bodies = model.evaluation().bodies.filter(\.isVisible)
        func centre(_ m: Mesh) -> Vec3 {
            guard let b = m.bounds else { return .zero }
            return (b.min + b.max) * 0.5
        }
        let centres = bodies.map { centre($0.mesh) }
        let middle = centres.isEmpty ? Vec3.zero : centres.reduce(Vec3.zero, +) * (1 / Double(centres.count))
        func preview(_ f: [CommandField]) {
            let factor = (f.first { $0.id == "k" }?.number ?? 0) / 100
            guard factor > 0 else { workspace.requestPreview(nil); return }
            var doc = model.document
            for (b, c) in zip(bodies, centres) {
                var away = (c - middle) * factor
                // A part right at the centre rises a little, so it does not hide the others.
                if (c - middle).length < 1e-6 { away = Vec3(0, 0, 1) * factor * 20 }
                doc.features.append(Feature(name: "esploso", kind: .move(MoveSpec(bodies: [b.id], translation: away))))
            }
            workspace.requestPreview(doc)
        }
        return CommandSession(
            title: "Vista esplosa", symbol: "arrow.up.left.and.arrow.down.right",
            fields: [.init(id: "k", label: "Distanza", kind: .count(0...300), value: .number(80),
                           help: "Quanto si allontanano i pezzi dal centro dell'assieme, in % della loro distanza"),
                     .init(id: "note", label: "Solo una vista: il disegno non cambia. Chiudi per rimettere i pezzi a posto.", kind: .note(warning: false), value: .flag(false))],
            onPreview: preview,
            onCommit: { _ in workspace.requestPreview(nil) },
            onCancel: { workspace.requestPreview(nil) })
    }
}
