import CADCore
import Foundation
import Observation

/// Saved sketches of the open design and their links to extruded features (T77).
/// Stored in the same .ftk file under separate keys ("sketches", "sketchLinks"): old files
/// load unchanged and the core decoder ignores the extra keys. To be merged into the
/// document v2 when Codex introduces it (T27).
@MainActor
@Observable
final class SketchStore {
    private(set) var sketches: [Sketch] = []
    private(set) var links: [SketchLink] = []
    /// Bumped on every change (dirty tracking).
    private(set) var revision = 0

    func sketch(_ id: Sketch.ID) -> Sketch? { sketches.first { $0.id == id } }

    func upsert(_ s: Sketch) {
        if let i = sketches.firstIndex(where: { $0.id == s.id }) { sketches[i] = s } else { sketches.append(s) }
        revision += 1
    }

    func delete(_ id: Sketch.ID) {
        sketches.removeAll { $0.id == id }
        links.removeAll { $0.sketchID == id }
        revision += 1
    }

    func setVisible(_ id: Sketch.ID, _ visible: Bool) {
        guard let i = sketches.firstIndex(where: { $0.id == id }) else { return }
        sketches[i].isVisible = visible
        revision += 1
    }

    func rename(_ id: Sketch.ID, to name: String) {
        guard let i = sketches.firstIndex(where: { $0.id == id }), !name.isEmpty else { return }
        sketches[i].name = name
        revision += 1
    }

    func link(feature: UUID, sketch: Sketch.ID, shape: SketchShape.ID) {
        links.removeAll { $0.featureID == feature }
        links.append(SketchLink(featureID: feature, sketchID: sketch, shapeID: shape))
        revision += 1
    }

    func links(of sketch: Sketch.ID) -> [SketchLink] { links.filter { $0.sketchID == sketch } }
    func sketchID(forFeature f: UUID) -> Sketch.ID? { links.first { $0.featureID == f }?.sketchID }

    /// Drops links to features that no longer exist (deleted or undone).
    func prune(existing features: Set<UUID>) {
        let before = links.count
        links.removeAll { !features.contains($0.featureID) }
        if links.count != before { revision += 1 }
    }

    func reset() { sketches = []; links = []; revision += 1 }

    /// Next default name ("Schizzo N").
    var nextName: String {
        let n = (sketches.compactMap { Int($0.name.replacingOccurrences(of: "Schizzo ", with: "")) }.max() ?? 0) + 1
        return "Schizzo \(n)"
    }

    // MARK: File section

    private struct Section: Codable {
        var sketches: [Sketch]?
        var sketchLinks: [SketchLink]?
    }

    func load(fromFile data: Data) {
        let s = (try? JSONDecoder().decode(Section.self, from: data)) ?? Section()
        sketches = s.sketches ?? []
        links = s.sketchLinks ?? []
        revision += 1
    }

    /// Adds the sketch keys to an encoded document (keeps the document's own formatting keys).
    func merged(into documentJSON: Data) throws -> Data {
        guard !sketches.isEmpty || !links.isEmpty else { return documentJSON }
        guard var object = try JSONSerialization.jsonObject(with: documentJSON) as? [String: Any] else { return documentJSON }
        let extra = try JSONSerialization.jsonObject(with: JSONEncoder().encode(Section(sketches: sketches, sketchLinks: links))) as? [String: Any] ?? [:]
        for (k, v) in extra { object[k] = v }
        return try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    }
}
