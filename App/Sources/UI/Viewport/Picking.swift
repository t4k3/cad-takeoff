import CADCore
import simd

/// Viewport hit-testing (interaction, not modelling): nearest body under a ray.
/// Faces/edges: see GeoPicking (stable kernel IDs).
enum Picking {
    struct Hit {
        var featureID: Feature.ID
        var triangle: Int
        var distance: Float
        var point: SIMD3<Float>
    }

    @MainActor
    static func pick(_ ray: Ray, in bodies: [ViewportRenderer.Body]) -> Hit? {
        var best: Hit?
        for body in bodies {
            guard let b = body.bounds, intersects(ray, b) else { continue }
            for t in 0..<body.triangleCount {
                let (a, bb, c) = body.triangle(t)
                if let d = intersect(ray, f(a), f(bb), f(c)), d < (best?.distance ?? .infinity) {
                    best = Hit(featureID: body.feature.id, triangle: t, distance: d,
                               point: ray.origin + ray.direction * d)
                }
            }
        }
        return best
    }

    private static func f(_ v: Vec3) -> SIMD3<Float> { SIMD3(Float(v.x), Float(v.y), Float(v.z)) }

    /// Möller–Trumbore, double-sided. Returns the distance along the ray.
    private static func intersect(_ r: Ray, _ a: SIMD3<Float>, _ b: SIMD3<Float>, _ c: SIMD3<Float>) -> Float? {
        let e1 = b - a, e2 = c - a
        let p = simd_cross(r.direction, e2)
        let det = simd_dot(e1, p)
        guard abs(det) > 1e-9 else { return nil }
        let inv = 1 / det
        let s = r.origin - a
        let u = simd_dot(s, p) * inv
        guard u >= 0, u <= 1 else { return nil }
        let q = simd_cross(s, e1)
        let v = simd_dot(r.direction, q) * inv
        guard v >= 0, u + v <= 1 else { return nil }
        let t = simd_dot(e2, q) * inv
        return t > 1e-4 ? t : nil
    }

    /// Slab test against an axis-aligned box, with a small margin.
    private static func intersects(_ r: Ray, _ b: BoundingBox) -> Bool {
        let lo = f(b.min) - 0.01, hi = f(b.max) + 0.01
        let inv = 1 / r.direction
        let t1 = (lo - r.origin) * inv, t2 = (hi - r.origin) * inv
        let tmin = simd_reduce_max(simd_min(t1, t2)), tmax = simd_reduce_min(simd_max(t1, t2))
        return tmax >= max(tmin, 0)
    }
}
