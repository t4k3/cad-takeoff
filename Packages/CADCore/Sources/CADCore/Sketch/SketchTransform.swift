import Foundation

// MARK: - Moving, rotating and copying sketch entities

extension SketchShape {
    /// The same shape after a rotation of `angle` radians around `center` and a translation `delta`,
    /// both in the sketch plane. Rectangles that stop being axis aligned become closed polylines;
    /// arcs turn with their angles; off-plane entities stay where they are (a planar transform
    /// would not carry their depth).
    public func transformed(rotating angle: Double, around center: Vec2, moving delta: Vec2) -> SketchShape {
        let c = cos(angle), s = sin(angle)
        func move(_ p: Vec2) -> Vec2 {
            let q = p - center
            return Vec2(q.x * c - q.y * s, q.x * s + q.y * c) + center + delta
        }
        var out = self
        switch kind {
        case let .polyline(points, closed):
            out.kind = .polyline(points.map(move), closed: closed)
        case let .rectangle(corner, width, height):
            let corners = [corner, Vec2(corner.x + width, corner.y),
                           Vec2(corner.x + width, corner.y + height), Vec2(corner.x, corner.y + height)].map(move)
            let quarter = angle / (.pi / 2)
            if abs(quarter - quarter.rounded()) < 1e-9 {
                let xs = corners.map(\.x), ys = corners.map(\.y)
                out.kind = .rectangle(corner: Vec2(xs.min()!, ys.min()!),
                                      width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!)
            } else {
                // The rectangle entity is axis aligned: any other angle needs a plain profile.
                out.kind = .polyline(corners, closed: true)
            }
        case let .circle(center: c0, radius):
            out.kind = .circle(center: move(c0), radius: radius)
        case let .polygon(center: c0, radius, sides, rotation, circumscribed):
            out.kind = .polygon(center: move(c0), radius: radius, sides: sides,
                                rotation: rotation + angle, circumscribed: circumscribed)
        case let .slot(start, end, width):
            out.kind = .slot(start: move(start), end: move(end), width: width)
        case let .arc(center: c0, radius, start, end):
            // The sweep keeps its direction: both angles turn with the geometry.
            out.kind = .arc(center: move(c0), radius: radius, start: start + angle, end: end + angle)
        case let .spline(points, closed):
            out.kind = .spline(points: points.map(move), closed: closed)
        case let .bezier(p0, c1, c2, p3):
            out.kind = .bezier(start: move(p0), control1: move(c1), control2: move(c2), end: move(p3))
        case .point3D, .line3D, .workplane:
            break
        }
        return out
    }
}

extension Sketch {
    /// Moves and rotates the shapes `ids` in the plane. The constraints keep pointing at the same
    /// points, so the solve that follows may move the rest of the geometry; when they cannot hold,
    /// or they pull the moved shape straight back (a fully constrained sketch), returns false and
    /// leaves the sketch as it was.
    @discardableResult
    public mutating func transform(_ ids: [SketchShape.ID], rotating angle: Double, around center: Vec2,
                                   moving delta: Vec2) -> Bool {
        guard !ids.isEmpty else { return false }
        var next = self
        // Where the moved points must end up, to tell a move from a sketch that refuses it.
        var expected: [SketchShape.ID: (from: Vec2, to: Vec2)] = [:]
        for i in next.shapes.indices where ids.contains(next.shapes[i].id) {
            let before = next.shapes[i]
            let after = before.transformed(rotating: angle, around: center, moving: delta)
            if let a = before.point(0), let b = after.point(0) { expected[before.id] = (a, b) }
            next.shapes[i] = after
        }
        guard next.solve() else { return false }
        for (id, e) in expected {
            guard let q = next.shapes.first(where: { $0.id == id })?.point(0) else { continue }
            let asked = (e.to - e.from).length
            if (q - e.to).length > max(1e-6, asked * 0.5) { return false }
        }
        self = next
        return true
    }

    /// Duplicates the given shapes moved by `delta`, with fresh IDs and without their constraints,
    /// and returns the IDs of the copies.
    @discardableResult
    public mutating func insert(copies: [SketchShape], moving delta: Vec2) -> [SketchShape.ID] {
        var made: [SketchShape.ID] = []
        for s in copies {
            var copy = s.transformed(rotating: 0, around: Vec2(0, 0), moving: delta)
            copy.id = UUID()
            shapes.append(copy)
            made.append(copy.id)
        }
        return made
    }
}
