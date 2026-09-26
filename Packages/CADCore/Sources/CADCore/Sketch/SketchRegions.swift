import Foundation

// Sketch profiles as regions, like Fusion's "profiles": closed shapes nested inside one another
// split the plane into areas. The ring between two concentric circles is one region (the outer
// circle with a hole), the inner disc another. Picking regions and extruding them together keeps
// the holes. Shapes that cross each other are not split yet: each stays a whole region.

/// One pickable area of a sketch: a closed shape minus the closed shapes directly inside it.
public struct SketchRegion: Equatable, Sendable {
    /// The shape whose outline bounds the region (also the region's identity).
    public let shapeID: UUID
    /// Closed shapes directly inside it (its holes).
    public let holeShapeIDs: [UUID]
    public let outline: [Vec2]
    public let holes: [[Vec2]]
}

/// An area to extrude: an outline and the holes left in it (selected regions merged).
public struct ProfileArea: Equatable, Sendable {
    public let shapeID: UUID
    public let holeShapeIDs: [UUID]
    public let profile: Profile2D
    public let holes: [Profile2D]
}

extension Sketch {
    /// Regions of the sketch's closed, non-construction shapes, from outer to inner.
    public var regions: [SketchRegion] {
        let closed = shapes.filter { $0.profile != nil }
        let outlines = Dictionary(uniqueKeysWithValues: closed.map { ($0.id, $0.outline) })
        // Parent = the smallest shape that strictly contains it.
        var parent: [UUID: UUID] = [:]
        for s in closed {
            let inner = outlines[s.id]!
            let containers = closed.filter { $0.id != s.id && Self.contains(outlines[$0.id]!, inner) }
            if let p = containers.min(by: { $0.area < $1.area }) { parent[s.id] = p.id }
        }
        return closed.sorted { $0.area > $1.area }.map { s in
            let children = closed.filter { parent[$0.id] == s.id }
            return SketchRegion(shapeID: s.id, holeShapeIDs: children.map(\.id), outline: outlines[s.id]!,
                                holes: children.map { outlines[$0.id]! })
        }
    }

    /// The region under a point: the innermost closed shape containing it.
    public func region(at p: Vec2) -> SketchRegion? {
        regions.last { Self.inside(p, $0.outline) && !$0.holes.contains { Self.inside(p, $0) } }
    }

    /// Selected regions as areas to extrude. Neighbouring selected regions merge (the ring and
    /// the disc inside it make a full disc); unselected inner regions stay holes.
    public func areas(selected: Set<UUID>) -> [ProfileArea] {
        let all = regions
        let byID = Dictionary(uniqueKeysWithValues: all.map { ($0.shapeID, $0) })
        let parentOf = Dictionary(all.flatMap { r in r.holeShapeIDs.map { ($0, r.shapeID) } }, uniquingKeysWith: { a, _ in a })
        var out: [ProfileArea] = []
        for r in all where selected.contains(r.shapeID) && !(parentOf[r.shapeID].map(selected.contains) ?? false) {
            // Holes: walk down through selected inner regions, keep the first unselected ones.
            var holes: [UUID] = [], stack = r.holeShapeIDs
            while let h = stack.popLast() {
                if selected.contains(h) { stack += byID[h]?.holeShapeIDs ?? [] } else { holes.append(h) }
            }
            // A selected region inside a hole starts its own area (handled by the loop: its parent is unselected).
            out.append(ProfileArea(shapeID: r.shapeID, holeShapeIDs: holes, profile: Profile2D(points: r.outline),
                                   holes: holes.compactMap { byID[$0].map { Profile2D(points: $0.outline) } }))
        }
        return out
    }

    // MARK: Geometry

    static func inside(_ p: Vec2, _ poly: [Vec2]) -> Bool {
        var inside = false
        var j = poly.count - 1
        for i in poly.indices {
            let a = poly[i], b = poly[j]
            if (a.y > p.y) != (b.y > p.y), p.x < (b.x - a.x) * (p.y - a.y) / (b.y - a.y) + a.x { inside.toggle() }
            j = i
        }
        return inside
    }

    /// `outer` strictly contains `inner`: every vertex inside, and no edges crossing.
    static func contains(_ outer: [Vec2], _ inner: [Vec2]) -> Bool {
        guard inner.allSatisfy({ inside($0, outer) }) else { return false }
        for i in outer.indices {
            let a = outer[i], b = outer[(i + 1) % outer.count]
            for k in inner.indices where crosses(a, b, inner[k], inner[(k + 1) % inner.count]) { return false }
        }
        return true
    }

    private static func crosses(_ a: Vec2, _ b: Vec2, _ c: Vec2, _ d: Vec2) -> Bool {
        let d1 = (b - a).cross(c - a), d2 = (b - a).cross(d - a), d3 = (d - c).cross(a - c), d4 = (d - c).cross(b - c)
        return d1 * d2 < 0 && d3 * d4 < 0
    }
}

extension Profile2D {
    /// Triangles of the area inside the profile and outside `holes` (for shading a region).
    public func triangulate(holes: [Profile2D]) -> [(Vec2, Vec2, Vec2)] {
        guard !holes.isEmpty else { return triangulate().map { (points[$0.0], points[$0.1], points[$0.2]) } }
        // Outer loop counter-clockwise, holes clockwise, all in one index space.
        var positions = points.map { Vec3($0.x, $0.y, 0) }
        var loops: [[UInt32]] = [Array(0..<UInt32(points.count))]
        for h in holes {
            let base = UInt32(positions.count)
            positions += h.points.map { Vec3($0.x, $0.y, 0) }
            loops.append((0..<UInt32(h.points.count)).reversed().map { base + $0 })
        }
        guard let tris = CoplanarMerge.triangulate(loops, positions, normal: Vec3(0, 0, 1)) else { return [] }
        func p(_ i: UInt32) -> Vec2 { Vec2(positions[Int(i)].x, positions[Int(i)].y) }
        return tris.map { (p($0.0), p($0.1), p($0.2)) }
    }
}
