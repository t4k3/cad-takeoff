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

extension CADDocument {
    /// Rewrites the profile of every extrusion linked to a (still closed) shape of `sketch`;
    /// links to deleted features or shapes are dropped, those features keep their last profile.
    mutating func regenerate(from sketch: Sketch) {
        let featureIDs = Set(features.map(\.id))
        sketchLinks.removeAll { link in
            link.sketchID == sketch.id && (!featureIDs.contains(link.featureID)
                                          || (link.seeds.isEmpty && !sketch.shapes.contains { $0.id == link.shapeID && $0.profile != nil }))
        }
        for link in sketchLinks where link.sketchID == sketch.id {
            // Faces of the arrangement, found again from the points picked inside them.
            if !link.seeds.isEmpty {
                guard let area = sketch.areas(seeds: link.seeds).first,
                      let i = features.firstIndex(where: { $0.id == link.featureID }) else { continue }
                switch features[i].kind {
                case let .extrude(_, height):
                    features[i].kind = .extrude(profile: Profile2D(points: area.outline), height: height)
                case var .revolve(spec):
                    spec.profile = Profile2D(points: area.outline)
                    // The axis line follows the sketch too.
                    if case let .segment(id, j)? = spec.axisRef, let (a, b) = sketch.shapes.first(where: { $0.id == id })?.segment(j) {
                        spec.axisStart = a; spec.axisEnd = b
                    }
                    features[i].kind = .revolve(spec)
                default:
                    continue
                }
                features[i].holes = area.holes.map { Profile2D(points: $0) }
                continue
            }
            guard let shape = sketch.shapes.first(where: { $0.id == link.shapeID }), let profile = shape.profile,
                  let i = features.firstIndex(where: { $0.id == link.featureID }),
                  case let .extrude(_, height) = features[i].kind else { continue }
            features[i].kind = .extrude(profile: profile, height: height)
            // Holes follow their shapes; a deleted or opened one stops being a hole.
            features[i].holes = link.holeShapeIDs.compactMap { id in sketch.shapes.first { $0.id == id }?.profile }
        }
    }

    /// Inserts or replaces a sketch.
    mutating func upsert(_ s: Sketch) {
        if let i = sketches.firstIndex(where: { $0.id == s.id }) { sketches[i] = s } else { sketches.append(s) }
    }
}
