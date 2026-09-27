import Foundation

/// A dimension the designer put in a sketch, in world coordinates: the drawing shows it in the
/// view that sees the sketch true (the functional dimensions, besides the overall ones).
public struct ModelDimension: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        /// Between two points; `along` = measured along that direction (nil = straight across).
        case linear(Vec3, Vec3, along: Vec3?)
        /// A round's radius or diameter; `at` = a point on it for the leader.
        case radius(center: Vec3, radius: Double, at: Vec3)
        case diameter(center: Vec3, radius: Double, at: Vec3)
    }
    public var kind: Kind
    /// Normal of the plane it lies in (the sketch's).
    public var normal: Vec3
    public var value: Double
    /// "Ø" on a turned part's diameter (a radius from the axis, drawn across it).
    public var prefix: String

    public init(kind: Kind, normal: Vec3, value: Double, prefix: String = "") {
        self.kind = kind; self.normal = normal; self.value = value; self.prefix = prefix
    }
}

extension Sketch {
    /// Its driving dimensions (lengths, distances, radii and diameters), in world coordinates.
    public var drawingDimensions: [ModelDimension] { drawingDimensions(revolvedAbout: []) }

    /// The same, for a profile revolved about these axes (sketch coordinates): a distance from
    /// the axis, square to it, is the part's diameter there (Ø, twice the value, across the axis).
    public func drawingDimensions(revolvedAbout axes: [(Vec2, Vec2)]) -> [ModelDimension] {
        func shape(_ r: SketchRef) -> SketchShape? {
            switch r { case let .point(id, _), let .segment(id, _), let .circle(id, _): shapes.first { $0.id == id } }
        }
        func point(_ r: SketchRef) -> Vec2? { if case let .point(_, i) = r { shape(r)?.point(i) } else { nil } }
        func segment(_ r: SketchRef) -> (Vec2, Vec2)? { if case let .segment(_, i) = r { shape(r)?.segment(i) } else { nil } }
        func round(_ r: SketchRef) -> (center: Vec2, radius: Double, at: Vec2)? {
            guard case let .circle(_, i) = r, let s = shape(r), let c = s.circle(i) else { return nil }
            // On an arc, the leader goes to its middle; on a full circle, at 45°.
            var angle = Double.pi / 4
            if case let .arc(_, _, a0, a1) = s.kind { angle = a0 + SketchShape.sweep(a0, a1) / 2 }
            return (c.center, c.radius, c.center + Vec2(cos(angle), sin(angle)) * c.radius)
        }
        func foot(_ p: Vec2, _ l: (Vec2, Vec2)) -> Vec2 {
            let d = l.1 - l.0, t = (p - l.0).dot(d) / max(d.dot(d), 1e-18)
            return l.0 + d * t
        }
        let n = plane.normal
        func linear(_ a: Vec2, _ b: Vec2, along: Vec3?, _ v: Double) -> ModelDimension {
            for axis in axes {
                let d = axis.1 - axis.0
                guard d.length > 1e-9 else { continue }
                let k = d.normalized
                func onAxis(_ p: Vec2) -> Bool { abs((p - axis.0).cross(k)) < 1e-6 }
                // Measured square to the axis (its direction, or the line between the points).
                let m = along.map { Vec2($0.dot(plane.xAxis), $0.dot(plane.yAxis)) } ?? (b - a)
                guard m.length > 1e-9, abs(m.normalized.dot(k)) < 1e-6 else { continue }
                let off: Vec2
                if onAxis(a) { off = b } else if onAxis(b) { off = a } else { continue }
                // Across the axis: from the point's mirror image to the point.
                let foot = axis.0 + k * (off - axis.0).dot(k)
                let mirror = foot * 2 - off
                return ModelDimension(kind: .linear(plane.world(mirror), plane.world(off), along: along), normal: n, value: 2 * v, prefix: "Ø")
            }
            return ModelDimension(kind: .linear(plane.world(a), plane.world(b), along: along), normal: n, value: v)
        }
        return constraints.compactMap { c -> ModelDimension? in
            switch c.kind {
            case let .length(r, v):
                return segment(r).map { linear($0.0, $0.1, along: nil, v) }
            case let .distance(a, b, v):
                if let p = point(a), let q = point(b) { return linear(p, q, along: nil, v) }
                if let p = point(a) ?? point(b), let l = segment(a) ?? segment(b) { return linear(p, foot(p, l), along: nil, v) }
                if let l = segment(a), let m = segment(b) {
                    let p = (l.0 + l.1) * 0.5
                    return linear(p, foot(p, m), along: nil, v)
                }
                return nil
            case let .horizontalDistance(a, b, v):
                guard let p = point(a) ?? round(a)?.center, let q = point(b) ?? round(b)?.center else { return nil }
                return linear(p, q, along: plane.xAxis, v)
            case let .verticalDistance(a, b, v):
                guard let p = point(a) ?? round(a)?.center, let q = point(b) ?? round(b)?.center else { return nil }
                return linear(p, q, along: plane.yAxis, v)
            case let .radius(r, v):
                return round(r).map { ModelDimension(kind: .radius(center: plane.world($0.center), radius: $0.radius, at: plane.world($0.at)), normal: n, value: v) }
            case let .diameter(r, v):
                return round(r).map { ModelDimension(kind: .diameter(center: plane.world($0.center), radius: $0.radius, at: plane.world($0.at)), normal: n, value: v) }
            default:
                return nil
            }
        }
    }
}

extension TechnicalDrawing {
    /// A sketch dimension placed in a view (sheet-independent view coordinates).
    struct PlacedDimension {
        enum Side { case above, below, left, right, aligned }
        var view: Int
        var a: Vec2, b: Vec2
        var side: Side
        var value: Double
        var prefix = ""
        /// Radius or diameter leaders: centre, point on the round, "R"/"Ø".
        var round: (centre: Vec2, at: Vec2, prefix: String)?
        var isRound: Bool { round != nil }
        var span: Double { (b - a).length }
    }

    /// Which of the views (front, top, left) sees each dimension true, and where it goes: along
    /// the sheet above/below or left/right of the view (outside the overall dimensions),
    /// otherwise aligned. Overall sizes (already dimensioned) and repeats are dropped.
    /// `levels`: heights already dimensioned from the bottom in the first view.
    static func placeDimensions(_ dims: [ModelDimension], views: [View], extents: [(min: Vec2, max: Vec2)], topView: Int,
                                levels: [Double] = []) -> [PlacedDimension] {
        var out: [PlacedDimension] = []
        for d in dims {
            guard let v = views.indices.first(where: { abs(views[$0].look.normalized.dot(d.normal.normalized)) > 0.999 }) else { continue }
            let view = views[v], e = extents[v]
            func flat(_ p: Vec3) -> Vec2 { Vec2(p.dot(view.right), p.dot(view.up)) }
            switch d.kind {
            case let .linear(p, q, along):
                let a = flat(p), b = flat(q)
                var dir = (b - a)
                if let along { let u = flat(along); dir = u * (dir.dot(u) / max(u.dot(u), 1e-18)) }
                guard dir.length > 1e-6 else { continue }
                let u = dir.normalized
                let side: PlacedDimension.Side
                let diametral = !d.prefix.isEmpty
                if abs(u.y) < 1e-6 {
                    // Overall width of the view: already dimensioned (a diameter says more: kept).
                    if !diametral, abs(abs(dir.x) - (e.max.x - e.min.x)) < 1e-6 { continue }
                    side = v == topView ? .below : .above
                } else if abs(u.x) < 1e-6 {
                    if !diametral, abs(abs(dir.y) - (e.max.y - e.min.y)) < 1e-6 { continue }
                    // A height from the bottom the level dimensions already give.
                    let y0 = min(a.y, b.y), y1 = max(a.y, b.y)
                    if v == 0, abs(y0 - e.min.y) < 1e-6, levels.contains(where: { abs($0 - y1) < 1e-6 }) { continue }
                    side = v == 2 ? .right : .left
                } else {
                    side = .aligned
                }
                // Measured along a direction: the second point slides onto the first's line.
                let b2 = along == nil ? b : a + dir
                let (lo, hi) = abs(u.y) < 1e-6 ? (a.x <= b2.x ? (a, b) : (b, a)) : (abs(u.x) < 1e-6 ? (a.y <= b2.y ? (a, b) : (b, a)) : (a, b))
                let placed = PlacedDimension(view: v, a: lo, b: hi, side: side, value: d.value, prefix: d.prefix)
                if out.contains(where: { $0.view == v && $0.round == nil && abs($0.value - d.value) < 1e-9
                    && ($0.a - placed.a).length + ($0.b - placed.b).length < 1e-6 }) { continue }
                // At most six rows a side (the shortest, nearest the view): past that the views
                // would shrink for dimensions the hole table and the others already give.
                if side != .aligned, out.filter({ $0.view == v && $0.side == side }).count >= 6 {
                    let row = out.indices.filter { out[$0].view == v && out[$0].side == side }
                    guard let longest = row.max(by: { out[$0].span < out[$1].span }), out[longest].span > placed.span else { continue }
                    out[longest] = placed
                    continue
                }
                out.append(placed)
            case let .radius(c, _, at), let .diameter(c, _, at):
                let isDiameter: Bool = { if case .diameter = d.kind { true } else { false } }()
                // Holes seen from above already carry their diameter (table or leader).
                if isDiameter, v == topView { continue }
                let placed = PlacedDimension(view: v, a: flat(c), b: flat(at), side: .aligned, value: d.value,
                                             round: (flat(c), flat(at), isDiameter ? "Ø" : "R"))
                if out.contains(where: { $0.view == v && $0.round != nil && ($0.a - placed.a).length < 1e-6 && abs($0.value - d.value) < 1e-9 }) { continue }
                out.append(placed)
            }
        }
        return out
    }

    /// A linear dimension between `a` and `b` along `d`, its line at `level` (coordinate along
    /// the unit side `n`), extension lines from the points.
    static func linear(_ s: inout DrawingSheet, _ a: Vec2, _ b: Vec2, along d: Vec2, side n: Vec2, level: Double, value: Double, prefix: String = "",
                       key: String? = nil, manual: UUID? = nil) {
        let a1 = a + n * (level - a.dot(n)), b1 = b + n * (level - b.dot(n))
        for (p, p1) in [(a, a1), (b, b1)] {
            let reach = level - p.dot(n)
            s.lines.append(.init(a: p + n * min(1.5, max(reach, 0) * 0.5), b: p1 + n * 2, style: .thin))
        }
        s.lines.append(.init(a: a1, b: b1, style: .thin))
        arrow(&s, tip: a1, from: b1)
        arrow(&s, tip: b1, from: a1)
        var angle = atan2(d.y, d.x) * 180 / .pi
        if angle > 90 || angle <= -90 { angle += 180 }
        let up = Vec2(-sin(angle * .pi / 180), cos(angle * .pi / 180))
        s.texts.append(.init(at: (a1 + b1) * 0.5 + up * 1.0, text: prefix + number(value), size: 3.5, align: .center, angle: angle))
        if let key { s.marks.append(.init(key: key, manual: manual, line: (a1, b1), text: (a1 + b1) * 0.5 + up * 2.5, side: n)) }
    }

    /// A stable key for a sketch dimension (its view and measured points), to move or hide it.
    static func sketchKey(_ d: PlacedDimension) -> String {
        "sketch/\(d.view)/" + [d.a.x, d.a.y, d.b.x, d.b.y].map(keyNumber).joined(separator: ",")
    }
    static func keyNumber(_ v: Double) -> String { String(format: "%.3f", locale: Locale(identifier: "en_US_POSIX"), v) }
}
