import CADCore
import simd

/// Face/edge picked in the viewport (T72, provisional indices from DerivedTopology).
struct GeoRef: Hashable {
    enum Kind: Hashable { case face(Int), edge(Int) }
    let feature: Feature.ID
    let kind: Kind
}

enum SelectionFilter: String, CaseIterable, Identifiable {
    case body = "Corpi", face = "Facce", edge = "Spigoli"
    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .body: "shippingbox"
        case .face: "square.fill"
        case .edge: "line.diagonal"
        }
    }
}

/// Picking of faces and edges on top of the body picking (interaction only).
@MainActor
enum GeoPicking {
    /// Nearest face under the ray.
    static func face(_ ray: Ray, bodies: [ViewportRenderer.Body], topology: (ViewportRenderer.Body) -> DerivedTopology) -> GeoRef? {
        guard let hit = Picking.pick(ray, in: bodies), let body = bodies.first(where: { $0.feature.id == hit.featureID }) else { return nil }
        let topo = topology(body)
        guard hit.triangle < topo.triangleFace.count else { return nil }
        return GeoRef(feature: hit.featureID, kind: .face(topo.triangleFace[hit.triangle]))
    }

    /// Nearest visible edge within `tolerance(distance)` millimetres of the ray.
    static func edge(_ ray: Ray, bodies: [ViewportRenderer.Body], topology: (ViewportRenderer.Body) -> DerivedTopology,
                     tolerance: (Float) -> Float) -> GeoRef? {
        let front = Picking.pick(ray, in: bodies)?.distance ?? .infinity
        var best: (ref: GeoRef, score: Float)?
        for body in bodies {
            let topo = topology(body)
            for (i, e) in topo.edges.enumerated() {
                for (a, b) in e.segments {
                    let (d, t) = distance(ray, SIMD3(Float(a.x), Float(a.y), Float(a.z)), SIMD3(Float(b.x), Float(b.y), Float(b.z)))
                    // Hidden behind the first surface hit? (small allowance: edges lie on that surface)
                    guard t <= front + max(0.5, front * 0.01), d <= tolerance(t) else { continue }
                    let score = d / tolerance(t)
                    if score < (best?.score ?? .infinity) { best = (GeoRef(feature: body.feature.id, kind: .edge(i)), score) }
                }
            }
        }
        return best?.ref
    }

    /// Distance between a ray and a segment, and the ray parameter of the closest point.
    private static func distance(_ r: Ray, _ a: SIMD3<Float>, _ b: SIMD3<Float>) -> (Float, Float) {
        let u = r.direction, v = b - a, w = r.origin - a
        let aa = simd_dot(u, u), bb = simd_dot(u, v), cc = simd_dot(v, v), dd = simd_dot(u, w), ee = simd_dot(v, w)
        let den = aa * cc - bb * bb
        var s: Float, t: Float
        if den < 1e-9 { s = 0; t = cc > 0 ? ee / cc : 0 } else {
            s = (bb * ee - cc * dd) / den
            t = (aa * ee - bb * dd) / den
        }
        t = min(max(t, 0), 1)
        s = max((bb * t - dd) / aa, 0)
        let p = r.origin + u * s, q = a + v * t
        return (simd_length(p - q), s)
    }
}
