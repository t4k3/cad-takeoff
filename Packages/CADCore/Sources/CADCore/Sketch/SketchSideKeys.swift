import Foundation

extension Sketch {
    /// A stable name for each side of an area's outline (from point i to i + 1): the sketch curve
    /// it lies on ("<shape>/s<k>" for the k-th straight segment, "/c<k>" for a circle or arc,
    /// "/sp" for a spline), numbered along the curve where it takes several sides (an arc's
    /// facets, a line split by another). Independent of the dimensions and of where the outline
    /// starts: the same side keeps its name when the sketch changes.
    public func sideKeys(for outline: [Vec2]) -> [String] {
        let n = outline.count
        guard n >= 3 else { return [] }
        func onSegment(_ p: Vec2, _ a: Vec2, _ b: Vec2) -> Bool {
            let d = b - a, l2 = d.dot(d)
            guard l2 > 1e-18 else { return (p - a).length < 1e-6 }
            let t = (p - a).dot(d) / l2
            return t > -1e-9 && t < 1 + 1e-9 && ((a + d * t) - p).length < 1e-6
        }
        func owner(_ p: Vec2, _ q: Vec2) -> String {
            for s in shapes where !s.isConstruction {
                for k in 0..<s.segmentCount {
                    if let (a, b) = s.segment(k), onSegment(p, a, b), onSegment(q, a, b) { return "\(s.id.uuidString)/s\(k)" }
                }
                for k in 0..<2 {
                    if let c = s.circle(k), abs((p - c.center).length - c.radius) < 1e-6, abs((q - c.center).length - c.radius) < 1e-6 {
                        return "\(s.id.uuidString)/c\(k)"
                    }
                }
                if case .spline = s.kind {
                    let o = s.outline
                    if o.contains(where: { ($0 - p).length < 1e-6 }), o.contains(where: { ($0 - q).length < 1e-6 }) { return "\(s.id.uuidString)/sp" }
                }
            }
            return "free"
        }
        let base = (0..<n).map { owner(outline[$0], outline[($0 + 1) % n]) }
        // Runs of sides on the same curve, taken round the outline; each run starts where the
        // curve changes (or, all one curve, at the rightmost-then-lowest point).
        var starts = (0..<n).filter { base[$0] != base[($0 + n - 1) % n] }
        if starts.isEmpty {
            starts = [outline.indices.min { a, b in (-outline[a].x, outline[a].y) < (-outline[b].x, outline[b].y) }!]
        }
        var keys = [String](repeating: "", count: n)
        var runsOf: [String: [(start: Int, first: Vec2)]] = [:]
        for s in starts { runsOf[base[s], default: []].append((s, outline[s])) }
        for (key, runs) in runsOf {
            // Several runs on one curve (a line split in two): ordered by where they begin.
            let ordered = runs.sorted { ($0.first.x, $0.first.y) < ($1.first.x, $1.first.y) }
            for (r, run) in ordered.enumerated() {
                var i = run.start, j = 0
                repeat {
                    keys[i] = key + (runs.count > 1 ? "#r\(r)" : "") + (j == 0 && base[(i + 1) % n] != key ? "" : "#\(j)")
                    i = (i + 1) % n; j += 1
                } while base[i] == key && !starts.contains(i) && i != run.start
            }
        }
        // Still repeated (should not happen): made unique by position so IDs never collide.
        var seen: [String: Int] = [:]
        for i in 0..<n {
            let k = keys[i]
            if let c = seen[k] { keys[i] = k + "~\(c)"; seen[k] = c + 1 } else { seen[k] = 1 }
        }
        return keys
    }
}

extension Feature {
    /// Names the sides of an extrusion's profile after the sketch curves they lie on.
    public mutating func keyProfile(from sketch: Sketch) {
        guard case let .extrude(profile, _) = kind else { return }
        let keys = sketch.sideKeys(for: profile.points)
        profileKeys = keys.count == profile.points.count && !keys.contains("free") ? keys : nil
    }
}
