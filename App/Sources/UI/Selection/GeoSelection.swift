import CADCore
import simd

/// Face/edge picked in the viewport, by stable kernel ID (T76): the reference survives
/// parameter edits that keep the topology (e.g. resizing a box).
struct GeoRef: Hashable {
    enum Kind: Hashable { case face(FaceID), edge(EdgeID) }
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

@MainActor
enum GeoPicking {
    /// Face under the ray (nearest body).
    static func face(_ ray: Ray, bodies: [ViewportRenderer.Body]) -> GeoRef? {
        guard let hit = Picking.pick(ray, in: bodies),
              let body = bodies.first(where: { $0.feature.id == hit.featureID }),
              let face = body.face(ofTriangle: hit.triangle) else { return nil }
        return GeoRef(feature: hit.featureID, kind: .face(face.id))
    }

    /// Nearest visible B-rep edge within `tolerance(distance)` mm of the ray.
    static func edge(_ ray: Ray, bodies: [ViewportRenderer.Body], tolerance: (Float) -> Float) -> GeoRef? {
        let front = Picking.pick(ray, in: bodies)?.distance ?? .infinity
        var best: (ref: GeoRef, score: Float)?
        for body in bodies {
            for e in body.snapshot.edges {
                for (a, b) in zip(e.polyline, e.polyline.dropFirst()) {
                    let (d, t) = distance(ray, SIMD3(Float(a.x), Float(a.y), Float(a.z)), SIMD3(Float(b.x), Float(b.y), Float(b.z)))
                    // Hidden behind the first surface hit? (edges lie on that surface: small allowance)
                    guard t <= front + max(0.5, front * 0.01), d <= tolerance(t) else { continue }
                    let score = d / tolerance(t)
                    if score < (best?.score ?? .infinity) { best = (GeoRef(feature: body.feature.id, kind: .edge(e.id)), score) }
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
        var t: Float = den < 1e-9 ? (cc > 0 ? ee / cc : 0) : (aa * ee - bb * dd) / den
        t = min(max(t, 0), 1)
        let s = max((bb * t - dd) / aa, 0)
        return (simd_length(r.origin + u * s - (a + v * t)), s)
    }
}
