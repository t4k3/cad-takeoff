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

    func delete(_ id: Sketch.ID) {
        guard let name = sketch(id)?.name else { return }
        model?.edit("Elimina \(name)") { doc in
            doc.sketches.removeAll { $0.id == id }
            doc.sketchLinks.removeAll { $0.sketchID == id }
        }
    }

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

extension CADDocument {
    /// Rewrites the profile of every extrusion linked to a (still closed) shape of `sketch`;
    /// links to deleted features or shapes are dropped, those features keep their last profile.
    mutating func regenerate(from sketch: Sketch) {
        sketchLinks.removeAll { link in
            link.sketchID == sketch.id && (!features.contains { $0.id == link.featureID }
                                          || !sketch.shapes.contains { $0.id == link.shapeID && $0.profile != nil })
        }
        for link in sketchLinks where link.sketchID == sketch.id {
            guard let shape = sketch.shapes.first(where: { $0.id == link.shapeID }), let profile = shape.profile,
                  let i = features.firstIndex(where: { $0.id == link.featureID }),
                  case let .extrude(_, height) = features[i].kind else { continue }
            features[i].kind = .extrude(profile: profile, height: height)
        }
    }

    /// Inserts or replaces a sketch.
    mutating func upsert(_ s: Sketch) {
        if let i = sketches.firstIndex(where: { $0.id == s.id }) { sketches[i] = s } else { sketches.append(s) }
    }
}
