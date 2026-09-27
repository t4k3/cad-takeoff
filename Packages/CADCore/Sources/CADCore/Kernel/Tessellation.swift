import Foundation

/// How finely curved surfaces are cut into facets (docs/SUPERFICI_ESATTE.md, tappa 1). The model is
/// built at `factor` 1 (as always: 64 facets per turn); an export «Fine» evaluates it again at a
/// higher factor. Every count in the kernel is multiplied by the same factor, so the pieces that
/// meet point for point (fillet seams, ball corners, arc walls) still meet; faces and edges keep
/// their names, so nothing saved depends on it.
public enum Tessellation {
    /// Times finer than the interactive model (1 = as always).
    @TaskLocal public static var factor = 1

    /// A count of the interactive model at the current factor.
    public static func segments(_ standard: Int) -> Int { standard * max(1, factor) }

    /// A profile (and its side keys) with every arc side cut into `factor` sides on its circle:
    /// the arcs are the ones the kernel recognises (sketch circles, slot ends, fillets). Lines stay.
    static func refined(_ points: [Vec2], keys: [String]?) -> (points: [Vec2], keys: [String]?) {
        let f = max(1, factor)
        guard f > 1, points.count >= 4 else { return (points, keys) }
        let arcs = PrimitiveKernel.profileArcs(points)
        let n = points.count
        var out: [Vec2] = [], outKeys: [String] = []
        for i in 0..<n {
            out.append(points[i])
            if let keys { outKeys.append(keys[i]) }
            let inner = between(points[i], points[(i + 1) % n], on: arcs[i])
            out += inner
            // The facet's key, one level down: the arc's name (before «#») stays the same.
            if let keys { outKeys += inner.indices.map { keys[i] + ".\($0 + 1)" } }
        }
        return (out, keys == nil ? nil : outKeys)
    }

    /// The points a side from `a` to `b` on `arc` gets inside it at the current factor (none for
    /// a straight side or at factor 1): the same everywhere a side is cut, so caps and walls meet.
    static func between(_ a: Vec2, _ b: Vec2, on arc: PrimitiveKernel.ProfileArc?) -> [Vec2] {
        let f = max(1, factor)
        guard f > 1, let arc else { return [] }
        let u = a - arc.center, v = b - arc.center
        let a0 = atan2(u.y, u.x)
        var d = atan2(v.y, v.x) - a0
        if d > .pi { d -= 2 * .pi } else if d <= -.pi { d += 2 * .pi }
        return (1..<f).map { k in
            let t = a0 + d * Double(k) / Double(f)
            return arc.center + Vec2(cos(t), sin(t)) * arc.radius
        }
    }
}
