import Foundation

/// Volumes on the true surfaces (docs/SUPERFICI_ESATTE.md, tappa 3). The facets' error in a
/// volume goes as 1/n² with the segments per turn (and so do boolean curves between curved
/// faces): two resolutions, n and 2n, cancel it — (4·V₂ₙ − Vₙ) / 3 — leaving 1/n⁴. A shaft Ø20
/// cross-drilled Ø6: 2·10⁻⁷ relative at the default resolution, where the facets alone are
/// 1,6·10⁻³ off. Flat-faced bodies are exact either way.
extension DesignEvaluator {
    /// Each body's volume from its evaluations at a resolution (`coarse`) and twice as fine
    /// (`fine`, same design); a body missing from either keeps its coarse volume.
    public static func extrapolatedVolumes(coarse: [Body], fine: [Body]) -> [UUID: Double] {
        var fineVolume: [UUID: Double] = [:]
        for b in fine where fineVolume[b.id] == nil { fineVolume[b.id] = b.mesh.volume }
        var out: [UUID: Double] = [:]
        for b in coarse where out[b.id] == nil {
            let v = b.mesh.volume
            if let f = fineVolume[b.id], f.isFinite { out[b.id] = (4 * f - v) / 3 } else { out[b.id] = v }
        }
        return out
    }

    /// Each face's area the same way (face names are the same at every resolution); a face
    /// missing at the finer one keeps its facets' area.
    public static func extrapolatedFaceAreas(coarse: [Body], fine: [Body]) -> [UUID: [FaceID: Double]] {
        var fineAreas: [UUID: [FaceID: Double]] = [:]
        for b in fine where fineAreas[b.id] == nil {
            fineAreas[b.id] = Dictionary(b.snapshot.faces.map { ($0.id, $0.area) }, uniquingKeysWith: { a, _ in a })
        }
        var out: [UUID: [FaceID: Double]] = [:]
        for b in coarse where out[b.id] == nil {
            var areas: [FaceID: Double] = [:]
            for f in b.snapshot.faces where areas[f.id] == nil {
                areas[f.id] = fineAreas[b.id]?[f.id].map { (4 * $0 - f.area) / 3 } ?? f.area
            }
            out[b.id] = areas
        }
        return out
    }

    public struct ExactMeasures: Sendable, Equatable {
        public var volumes: [UUID: Double]
        public var faceAreas: [UUID: [FaceID: Double]]
    }

    /// The design evaluated at the current resolution and twice as fine: volumes and face areas
    /// extrapolated.
    public static func exactMeasures(_ doc: CADDocument, revision: String, components: ComponentResolver? = nil,
                                     coarse: [Body]? = nil, cache: EvaluationCache? = nil) -> ExactMeasures {
        let base = Tessellation.factor
        let first = coarse ?? evaluate(doc, revision: revision, components: components).bodies
        let fine = Tessellation.$factor.withValue(base * 2) {
            evaluate(doc, revision: revision + "-x\(base * 2)", components: components, cache: cache).bodies
        }
        return ExactMeasures(volumes: extrapolatedVolumes(coarse: first, fine: fine), faceAreas: extrapolatedFaceAreas(coarse: first, fine: fine))
    }

    public static func exactVolumes(_ doc: CADDocument, revision: String, components: ComponentResolver? = nil,
                                    coarse: [Body]? = nil, cache: EvaluationCache? = nil) -> [UUID: Double] {
        exactMeasures(doc, revision: revision, components: components, coarse: coarse, cache: cache).volumes
    }
}
