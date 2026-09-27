import Foundation

// Exact points on the true surfaces (docs/SUPERFICI_ESATTE.md, tappa 3): a point of the facets
// carried onto one surface, onto where two meet (an intersection curve) or onto where three meet
// (a corner), by Newton's method on their signed distances.

extension SurfaceDescriptor {
    /// Signed distance from the surface (mm) and its unit gradient; nil for freeform surfaces or
    /// on an axis (where the direction is undefined).
    func signedDistance(_ x: Vec3) -> (d: Double, g: Vec3)? {
        switch self {
        case let .plane(o, n):
            let u = n.normalized
            return ((x - o).dot(u), u)
        case let .cylinder(o, a0, r):
            let a = a0.normalized, v = x - o, radial = v - a * v.dot(a), rho = radial.length
            guard rho > 1e-12 else { return nil }
            return (rho - r, radial * (1 / rho))
        case let .cone(apex, a0, half):
            let a = a0.normalized, v = x - apex, h = v.dot(a), radial = v - a * h, rho = radial.length
            guard rho > 1e-12 else { return nil }
            return (rho * cos(half) - h * sin(half), radial * (cos(half) / rho) - a * sin(half))
        case let .sphere(c, r):
            let v = x - c, l = v.length
            guard l > 1e-12 else { return nil }
            return (l - r, v * (1 / l))
        case let .torus(c, a0, big, small):
            let a = a0.normalized, v = x - c, h = v.dot(a), radial = v - a * h, rho = radial.length
            let q = ((rho - big) * (rho - big) + h * h).squareRoot()
            guard rho > 1e-12, q > 1e-12 else { return nil }
            return (q - small, radial * ((rho - big) / (rho * q)) + a * (h / q))
        case .freeform:
            return nil
        }
    }

    /// The point nearest `p` lying on every surface given (one, two or three), or nil when Newton
    /// does not settle (tangent surfaces, a freeform one, too far).
    static func project(_ p: Vec3, onto surfaces: [SurfaceDescriptor], tolerance: Double = 1e-11) -> Vec3? {
        guard (1...3).contains(surfaces.count) else { return nil }
        var x = p
        for _ in 0..<40 {
            var rows: [(d: Double, g: Vec3)] = []
            for s in surfaces { guard let r = s.signedDistance(x) else { return nil }; rows.append(r) }
            if rows.allSatisfy({ abs($0.d) <= tolerance * max(1, x.length) }) { return x }
            // x ← x − Jᵀ (J Jᵀ)⁻¹ F: the smallest step that zeroes the linearised distances.
            let k = rows.count
            var m = [[Double]](repeating: [Double](repeating: 0, count: k), count: k)
            for i in 0..<k { for j in 0..<k { m[i][j] = rows[i].g.dot(rows[j].g) } }
            guard let lambda = solve(m, rows.map(\.d)) else { return nil }
            var step = Vec3.zero
            for i in 0..<k { step = step + rows[i].g * lambda[i] }
            x = x - step
        }
        return nil
    }

    /// Small dense system by Gaussian elimination with pivoting; nil when singular.
    private static func solve(_ a0: [[Double]], _ b0: [Double]) -> [Double]? {
        var a = a0, b = b0
        let n = b.count
        for c in 0..<n {
            guard let p = (c..<n).max(by: { abs(a[$0][c]) < abs(a[$1][c]) }), abs(a[p][c]) > 1e-12 else { return nil }
            a.swapAt(c, p); b.swapAt(c, p)
            for r in (c + 1)..<max(c + 1, n) {
                let f = a[r][c] / a[c][c]
                for j in c..<n { a[r][j] -= f * a[c][j] }
                b[r] -= f * b[c]
            }
        }
        var x = [Double](repeating: 0, count: n)
        for r in stride(from: n - 1, through: 0, by: -1) {
            var s = b[r]
            for j in (r + 1)..<max(r + 1, n) { s -= a[r][j] * x[j] }
            x[r] = s / a[r][r]
        }
        return x
    }
}

/// A cubic B-spline through given points (global interpolation, chord-length parameters and
/// averaged knots — Piegl & Tiller, The NURBS Book, A9.1): how STEP carries an intersection curve
/// that is neither a line nor a circle.
struct CubicInterpolation {
    let controls: [Vec3]
    /// Distinct knots and their multiplicities (clamped: 4 at each end).
    let knots: [Double]
    let multiplicities: [Int]

    init?(_ q: [Vec3]) {
        let n = q.count - 1, p = 3
        guard n >= p else { return nil }
        let lengths = zip(q, q.dropFirst()).map { ($1 - $0).length }
        let total = lengths.reduce(0, +)
        guard total > 1e-12, lengths.allSatisfy({ $0 > 1e-12 }) else { return nil }
        var u = [0.0]
        for l in lengths { u.append(u.last! + l / total) }
        u[n] = 1
        var knot = [Double](repeating: 0, count: n + p + 2)
        if n > p { for j in 1...(n - p) { knot[j + p] = (j..<(j + p)).map { u[$0] }.reduce(0, +) / Double(p) } }
        for j in (n + 1)...(n + p + 1) { knot[j] = 1 }
        // Banded system: row k holds the basis functions at u[k].
        func span(_ t: Double) -> Int {
            if t >= knot[n + 1] { return n }
            var lo = p, hi = n + 1
            while hi - lo > 1 { let mid = (lo + hi) / 2; if t < knot[mid] { hi = mid } else { lo = mid } }
            return lo
        }
        func basis(_ i: Int, _ t: Double) -> [Double] {
            var N = [Double](repeating: 0, count: p + 1), left = N, right = N
            N[0] = 1
            for j in 1...p {
                left[j] = t - knot[i + 1 - j]; right[j] = knot[i + j] - t
                var saved = 0.0
                for r in 0..<j {
                    let temp = N[r] / (right[r + 1] + left[j - r])
                    N[r] = saved + right[r + 1] * temp
                    saved = left[j - r] * temp
                }
                N[j] = saved
            }
            return N
        }
        var a = [[Double]](repeating: [Double](repeating: 0, count: n + 1), count: n + 1)
        for k in 0...n {
            let s = span(u[k]), N = basis(s, u[k])
            for r in 0...p { a[k][s - p + r] = N[r] }
        }
        // Totally positive and banded: elimination without pivoting keeps the band.
        var bx = q.map(\.x), by = q.map(\.y), bz = q.map(\.z)
        for c in 0...n {
            guard abs(a[c][c]) > 1e-14 else { return nil }
            guard c < n else { break }
            for r in (c + 1)...min(n, c + p) {
                let f = a[r][c] / a[c][c]
                if f == 0 { continue }
                for j in c...min(n, c + 2 * p) { a[r][j] -= f * a[c][j] }
                bx[r] -= f * bx[c]; by[r] -= f * by[c]; bz[r] -= f * bz[c]
            }
        }
        var cp = [Vec3](repeating: .zero, count: n + 1)
        for r in stride(from: n, through: 0, by: -1) {
            var sx = bx[r], sy = by[r], sz = bz[r]
            if r < n { for j in (r + 1)...min(n, r + 2 * p) { sx -= a[r][j] * cp[j].x; sy -= a[r][j] * cp[j].y; sz -= a[r][j] * cp[j].z } }
            cp[r] = Vec3(sx / a[r][r], sy / a[r][r], sz / a[r][r])
        }
        controls = cp
        var ks: [Double] = [], ms: [Int] = []
        for k in knot { if let last = ks.last, abs(last - k) < 1e-15 { ms[ms.count - 1] += 1 } else { ks.append(k); ms.append(1) } }
        knots = ks; multiplicities = ms
    }
}
