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

    /// The design evaluated at the current resolution and twice as fine, volumes extrapolated.
    public static func exactVolumes(_ doc: CADDocument, revision: String, components: ComponentResolver? = nil,
                                    coarse: [Body]? = nil, cache: EvaluationCache? = nil) -> [UUID: Double] {
        let base = Tessellation.factor
        let first = coarse ?? evaluate(doc, revision: revision, components: components).bodies
        let fine = Tessellation.$factor.withValue(base * 2) {
            evaluate(doc, revision: revision + "-x\(base * 2)", components: components, cache: cache).bodies
        }
        return extrapolatedVolumes(coarse: first, fine: fine)
    }
}
