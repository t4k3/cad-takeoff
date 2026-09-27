import Foundation

// Sketch model v1 (T77, Claude with Ross). Pure value types: 2D entities on a plane,
// in millimetres. Kept in its own folder; integration with features/history goes
// through explicit requests to the Model (see docs/COLLAB.md).

/// Plane of a sketch: origin and orthonormal in-plane axes, in world millimetres.
public struct SketchPlane: Codable, Sendable, Equatable {
    public var origin: Vec3
    public var xAxis: Vec3
    public var yAxis: Vec3

    public init(origin: Vec3, xAxis: Vec3, yAxis: Vec3) {
        self.origin = origin; self.xAxis = xAxis; self.yAxis = yAxis
    }

    /// Print-bed plane (Z = 0).
    public static let xy = SketchPlane(origin: .zero, xAxis: Vec3(1, 0, 0), yAxis: Vec3(0, 1, 0))

    public var normal: Vec3 { xAxis.cross(yAxis).normalized }
    public func world(_ p: Vec2) -> Vec3 { origin + xAxis * p.x + yAxis * p.y }
    /// Plane coordinates of a world point (projected onto the plane).
    public func local(_ p: Vec3) -> Vec2 { Vec2((p - origin).dot(xAxis), (p - origin).dot(yAxis)) }
    /// World point at plane coordinates `p`, `height` along the normal.
    public func world(_ p: Vec2, height: Double) -> Vec3 { world(p) + normal * height }

    public var isXY: Bool { self == .xy }

    /// Front plane (world XZ, seen from −Y) and side plane (world YZ, seen from +X).
    public static let xz = SketchPlane(origin: .zero, xAxis: Vec3(1, 0, 0), yAxis: Vec3(0, 0, 1))
    public static let yz = SketchPlane(origin: .zero, xAxis: Vec3(0, 1, 0), yAxis: Vec3(0, 0, 1))

    /// The same plane moved along its normal (construction plane).
    public func offset(by distance: Double) -> SketchPlane {
        SketchPlane(origin: origin + normal * distance, xAxis: xAxis, yAxis: yAxis)
    }

    /// The plane turned by `degrees` about its own X axis (`aboutX`) or Y axis, through its origin
    /// (inclined construction plane). Positive turns the far side up, by the right-hand rule.
    public func tilted(by degrees: Double, aboutX: Bool = true) -> SketchPlane {
        let t = degrees * .pi / 180
        let k = (aboutX ? xAxis : yAxis).normalized
        func rotate(_ v: Vec3) -> Vec3 { v * cos(t) + k.cross(v) * sin(t) + k * (k.dot(v) * (1 - cos(t))) }
        return SketchPlane(origin: origin, xAxis: rotate(xAxis), yAxis: rotate(yAxis))
    }

    /// Plane of a planar face (sketch on face): origin = the world origin projected onto it, so
    /// on a horizontal face the coordinates are the world X/Y; on a vertical face X runs
    /// horizontally and Y up.
    public static func onFace(point: Vec3, normal: Vec3) -> SketchPlane {
        let n = normal.normalized
        let origin = n * point.dot(n)
        let x = abs(n.z) > 0.999 ? Vec3(1, 0, 0) : Vec3(0, 0, 1).cross(n).normalized
        return SketchPlane(origin: origin, xAxis: x, yAxis: n.cross(x).normalized)
    }
}

/// One entity drawn in a sketch.
public struct SketchShape: Identifiable, Codable, Sendable, Equatable {
    public enum Kind: Codable, Sendable, Equatable {
        /// Open (line chain) or closed (profile) polyline.
        case polyline([Vec2], closed: Bool)
        /// Axis-aligned rectangle from a corner, width and height (may be negative while drawing).
        case rectangle(corner: Vec2, width: Double, height: Double)
        case circle(center: Vec2, radius: Double)
        /// Regular polygon. `radius` goes to the vertices (inscribed) or to the side midpoints (circumscribed).
        case polygon(center: Vec2, radius: Double, sides: Int, rotation: Double, circumscribed: Bool)
        /// Centre-to-centre slot: the two arc centres and the overall width.
        case slot(start: Vec2, end: Vec2, width: Double)
        /// Circular arc, counter-clockwise from `start` to `end` (radians). Open: it bounds profiles
        /// together with the lines it meets (fillets, rounded outlines).
        case arc(center: Vec2, radius: Double, start: Double, end: Double)
    }

    public var id: UUID
    public var kind: Kind
    /// Construction geometry is drawn dashed and never becomes a profile.
    public var isConstruction: Bool

    public init(id: UUID = UUID(), kind: Kind, isConstruction: Bool = false) {
        self.id = id; self.kind = kind; self.isConstruction = isConstruction
    }

    /// Segments used to tessellate full circles (slots use half on each end).
    public static let arcSegments = 64

    public var isClosed: Bool {
        if case let .polyline(_, closed) = kind { return closed }
        if case .arc = kind { return false }
        return true
    }

    /// Counter-clockwise sweep of an arc, in (0, 2π].
    public static func sweep(_ start: Double, _ end: Double) -> Double {
        var s = (end - start).truncatingRemainder(dividingBy: 2 * .pi)
        if s <= 1e-12 { s += 2 * .pi }
        return s
    }

    /// Outline vertices (closed shapes without the repeated first point).
    public var outline: [Vec2] {
        switch kind {
        case let .polyline(p, _):
            return p
        case let .rectangle(c, w, h):
            let x0 = min(c.x, c.x + w), x1 = max(c.x, c.x + w), y0 = min(c.y, c.y + h), y1 = max(c.y, c.y + h)
            return [Vec2(x0, y0), Vec2(x1, y0), Vec2(x1, y1), Vec2(x0, y1)]
        case let .circle(c, r):
            return (0..<Self.arcSegments).map { i in
                let t = Double(i) / Double(Self.arcSegments) * 2 * .pi
                return Vec2(c.x + r * cos(t), c.y + r * sin(t))
            }
        case let .polygon(c, r, n, rot, circ):
            let n = max(3, n)
            let vr = circ ? r / cos(.pi / Double(n)) : r
            return (0..<n).map { i in
                let t = rot + Double(i) / Double(n) * 2 * .pi
                return Vec2(c.x + vr * cos(t), c.y + vr * sin(t))
            }
        case let .slot(a, b, w):
            let r = w / 2
            let dx = b.x - a.x, dy = b.y - a.y
            let len = (dx * dx + dy * dy).squareRoot()
            guard len > 1e-9 else { return SketchShape(kind: .circle(center: a, radius: r)).outline }
            let base = atan2(dy, dx)
            let half = Self.arcSegments / 2
            // Arc around `end` from -90° to +90° relative to the axis, then around `start` from +90° to +270°.
            let arcB = (0...half).map { i -> Vec2 in
                let t = base - .pi / 2 + Double(i) / Double(half) * .pi
                return Vec2(b.x + r * cos(t), b.y + r * sin(t))
            }
            let arcA = (0...half).map { i -> Vec2 in
                let t = base + .pi / 2 + Double(i) / Double(half) * .pi
                return Vec2(a.x + r * cos(t), a.y + r * sin(t))
            }
            return arcB + arcA
        case let .arc(c, r, a0, a1):
            let sweep = Self.sweep(a0, a1)
            let n = max(4, Int((sweep / (2 * .pi) * Double(Self.arcSegments)).rounded(.up)))
            return (0...n).map { i in
                let t = a0 + sweep * Double(i) / Double(n)
                return Vec2(c.x + r * cos(t), c.y + r * sin(t))
            }
        }
    }

    /// Profile for extrusion (nil for open or construction shapes).
    public var profile: Profile2D? {
        guard isClosed, !isConstruction, outline.count >= 3 else { return nil }
        return Profile2D(points: outline)
    }

    /// Perimeter in mm (open polylines: total length).
    public var length: Double {
        switch kind {
        case let .circle(_, r): return 2 * .pi * r
        case let .arc(_, r, a0, a1): return r * Self.sweep(a0, a1)
        case let .slot(a, b, w):
            return 2 * ((b.x - a.x) * (b.x - a.x) + (b.y - a.y) * (b.y - a.y)).squareRoot() + .pi * w
        default:
            let p = outline
            guard p.count >= 2 else { return 0 }
            var l = 0.0
            for i in 0..<(isClosed ? p.count : p.count - 1) {
                let a = p[i], b = p[(i + 1) % p.count]
                l += ((b.x - a.x) * (b.x - a.x) + (b.y - a.y) * (b.y - a.y)).squareRoot()
            }
            return l
        }
    }

    /// Exact enclosed area in mm² (0 for open shapes).
    public var area: Double {
        guard isClosed else { return 0 }
        switch kind {
        case let .circle(_, r): return .pi * r * r
        case let .rectangle(_, w, h): return abs(w * h)
        case let .slot(a, b, w):
            return ((b.x - a.x) * (b.x - a.x) + (b.y - a.y) * (b.y - a.y)).squareRoot() * w + .pi * w * w / 4
        default: return abs(Profile2D(points: outline).area)
        }
    }

    /// Short Italian name for the UI.
    public var typeName: String {
        switch kind {
        case let .polyline(p, closed): closed ? "Profilo" : (p.count == 2 ? "Linea" : "Polilinea")
        case .rectangle: "Rettangolo"
        case .circle: "Cerchio"
        case let .polygon(_, _, n, _, _): "Poligono (\(n) lati)"
        case .slot: "Asola"
        case .arc: "Arco"
        }
    }
}

/// A saved sketch: plane plus entities.
public struct Sketch: Identifiable, Codable, Sendable, Equatable {
    public var id: UUID
    public var name: String
    public var plane: SketchPlane
    public var shapes: [SketchShape]
    public var isVisible: Bool
    /// Geometric constraints and dimensions between the shapes (solved by `SketchSolver`).
    public var constraints: [SketchConstraint]

    public init(id: UUID = UUID(), name: String, plane: SketchPlane = .xy, shapes: [SketchShape] = [], isVisible: Bool = true,
                constraints: [SketchConstraint] = []) {
        self.id = id; self.name = name; self.plane = plane; self.shapes = shapes; self.isVisible = isVisible
        self.constraints = constraints
    }

    private enum CodingKeys: String, CodingKey { case id, name, plane, shapes, isVisible, constraints }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        plane = try c.decode(SketchPlane.self, forKey: .plane)
        shapes = try c.decode([SketchShape].self, forKey: .shapes)
        isVisible = try c.decodeIfPresent(Bool.self, forKey: .isVisible) ?? true
        constraints = try c.decodeIfPresent([SketchConstraint].self, forKey: .constraints) ?? []
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id); try c.encode(name, forKey: .name); try c.encode(plane, forKey: .plane)
        try c.encode(shapes, forKey: .shapes); try c.encode(isVisible, forKey: .isVisible)
        if !constraints.isEmpty { try c.encode(constraints, forKey: .constraints) }
    }

    /// Re-solves the constraints (after an edit or a new dimension). Constraints on deleted shapes are
    /// dropped. Returns false, leaving the sketch unchanged, when they cannot all hold.
    @discardableResult
    public mutating func solve(drag: (SketchRef, Vec2)? = nil) -> Bool {
        let ids = Set(shapes.map(\.id))
        constraints.removeAll { c in c.kind.refs.contains { !ids.contains($0.shapeID) } }
        guard !constraints.isEmpty || drag != nil else { return true }
        let result = SketchSolver.solve(shapes, constraints, drag: drag)
        guard result.converged else { return false }
        shapes = result.shapes
        return true
    }

    /// Re-solves after the dimension `id` changed, moving as little of the rest as it can (as Fusion
    /// does): first with every point pinned except those of the shapes the dimension touches and the
    /// points joined to them, then, if that cannot hold, freely.
    @discardableResult
    public mutating func solve(after id: SketchConstraint.ID) -> Bool {
        guard let changed = constraints.first(where: { $0.id == id }) else { return solve() }
        let freeShapes = Set(changed.kind.refs.map(\.shapeID))
        struct Key: Hashable { let shape: UUID, index: Int }
        var free = Set<Key>()
        for s in shapes where freeShapes.contains(s.id) { for j in 0..<s.pointCount { free.insert(Key(shape: s.id, index: j)) } }
        var grew = true
        while grew {
            grew = false
            for c in constraints {
                guard case let .coincident(.point(a, i), .point(b, j)) = c.kind else { continue }
                let ka = Key(shape: a, index: i), kb = Key(shape: b, index: j)
                if free.contains(ka) != free.contains(kb) { free.insert(ka); free.insert(kb); grew = true }
            }
        }
        var pinned = self
        for s in shapes {
            for j in 0..<s.pointCount where !free.contains(Key(shape: s.id, index: j)) {
                if let p = s.point(j) { pinned.constraints.append(SketchConstraint(.fix(.point(s.id, j), p))) }
            }
        }
        if pinned.solve() {
            shapes = pinned.shapes
            return true
        }
        return solve()
    }

    public var profiles: [SketchShape] { shapes.filter { $0.profile != nil } }
}

/// Feature created from a sketch shape: regenerated when the sketch changes.
public struct SketchLink: Codable, Sendable, Equatable, Hashable {
    public var featureID: UUID
    public var sketchID: UUID
    public var shapeID: UUID
    /// Closed shapes left as holes in the extruded region (the inner circle of a ring).
    public var holeShapeIDs: [UUID]
    /// Points inside the extruded face(s) of the sketch arrangement: the face is found again from
    /// them after edits (preferred over shapeID when present).
    public var seeds: [Vec2]

    public init(featureID: UUID, sketchID: UUID, shapeID: UUID, holeShapeIDs: [UUID] = [], seeds: [Vec2] = []) {
        self.featureID = featureID; self.sketchID = sketchID; self.shapeID = shapeID; self.holeShapeIDs = holeShapeIDs
        self.seeds = seeds
    }

    private enum CodingKeys: String, CodingKey { case featureID, sketchID, shapeID, holeShapeIDs, seeds }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        featureID = try c.decode(UUID.self, forKey: .featureID)
        sketchID = try c.decode(UUID.self, forKey: .sketchID)
        shapeID = try c.decode(UUID.self, forKey: .shapeID)
        holeShapeIDs = try c.decodeIfPresent([UUID].self, forKey: .holeShapeIDs) ?? []
        seeds = try c.decodeIfPresent([Vec2].self, forKey: .seeds) ?? []
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(featureID, forKey: .featureID); try c.encode(sketchID, forKey: .sketchID); try c.encode(shapeID, forKey: .shapeID)
        if !holeShapeIDs.isEmpty { try c.encode(holeShapeIDs, forKey: .holeShapeIDs) }
        if !seeds.isEmpty { try c.encode(seeds, forKey: .seeds) }
    }
}

extension CADDocument {
    /// Rewrites the profile of every extrusion linked to a (still closed) shape of `sketch`;
    /// links to deleted features or shapes are dropped, those features keep their last profile.
    public mutating func regenerate(from sketch: Sketch) {
        let featureIDs = Set(features.map(\.id))
        sketchLinks.removeAll { link in
            link.sketchID == sketch.id && (!featureIDs.contains(link.featureID)
                                          || (link.seeds.isEmpty && !sketch.shapes.contains { $0.id == link.shapeID && $0.profile != nil }))
        }
        for link in sketchLinks where link.sketchID == sketch.id {
            // Faces of the arrangement, found again from the points picked inside them.
            if !link.seeds.isEmpty {
                guard let area = sketch.areas(seeds: link.seeds).first,
                      let i = features.firstIndex(where: { $0.id == link.featureID }) else { continue }
                switch features[i].kind {
                case let .extrude(_, height):
                    features[i].kind = .extrude(profile: Profile2D(points: area.outline), height: height)
                case var .revolve(spec):
                    spec.profile = Profile2D(points: area.outline)
                    // The axis line follows the sketch too.
                    if case let .segment(id, j)? = spec.axisRef, let (a, b) = sketch.shapes.first(where: { $0.id == id })?.segment(j) {
                        spec.axisStart = a; spec.axisEnd = b
                    }
                    features[i].kind = .revolve(spec)
                default:
                    continue
                }
                features[i].holes = area.holes.map { Profile2D(points: $0) }
                continue
            }
            guard let shape = sketch.shapes.first(where: { $0.id == link.shapeID }), let profile = shape.profile,
                  let i = features.firstIndex(where: { $0.id == link.featureID }),
                  case let .extrude(_, height) = features[i].kind else { continue }
            features[i].kind = .extrude(profile: profile, height: height)
            // Holes follow their shapes; a deleted or opened one stops being a hole.
            features[i].holes = link.holeShapeIDs.compactMap { id in sketch.shapes.first { $0.id == id }?.profile }
        }
    }

    /// Inserts or replaces a sketch.
    public mutating func upsert(_ s: Sketch) {
        if let i = sketches.firstIndex(where: { $0.id == s.id }) { sketches[i] = s } else { sketches.append(s) }
    }
}
