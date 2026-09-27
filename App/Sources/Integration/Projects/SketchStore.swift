import CADCore
import Foundation
import Observation

/// Sketches of the open design, read from and written to `model.document` (T77, T81):
/// every change is one step of the design's undo history.
@MainActor
@Observable
final class SketchStore {
    @ObservationIgnored weak var model: DesignModel?

    var sketches: [Sketch] { model?.document.sketches ?? [] }
    var links: [SketchLink] { model?.document.sketchLinks ?? [] }

    func sketch(_ id: Sketch.ID) -> Sketch? { sketches.first { $0.id == id } }
    func links(of sketch: Sketch.ID) -> [SketchLink] { links.filter { $0.sketchID == sketch } }
    func sketchID(forFeature f: UUID) -> Sketch.ID? { links.first { $0.featureID == f }?.sketchID }

    func delete(_ id: Sketch.ID) { model?.deleteStep(id) }

    func setVisible(_ id: Sketch.ID, _ visible: Bool) {
        guard let s = sketch(id) else { return }
        model?.edit(visible ? "Mostra \(s.name)" : "Nascondi \(s.name)") { doc in
            if let i = doc.sketches.firstIndex(where: { $0.id == id }) { doc.sketches[i].isVisible = visible }
        }
    }

    /// Next default name ("Schizzo N").
    var nextName: String {
        let n = (sketches.compactMap { Int($0.name.replacingOccurrences(of: "Schizzo ", with: "")) }.max() ?? 0) + 1
        return "Schizzo \(n)"
    }
}

