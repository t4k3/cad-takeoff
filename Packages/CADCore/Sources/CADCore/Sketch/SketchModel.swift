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
        return true
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

    public init(id: UUID = UUID(), name: String, plane: SketchPlane = .xy, shapes: [SketchShape] = [], isVisible: Bool = true) {
        self.id = id; self.name = name; self.plane = plane; self.shapes = shapes; self.isVisible = isVisible
    }

    public var profiles: [SketchShape] { shapes.filter { $0.profile != nil } }
}

/// Feature created from a sketch shape: regenerated when the sketch changes.
public struct SketchLink: Codable, Sendable, Equatable, Hashable {
    public var featureID: UUID
    public var sketchID: UUID
    public var shapeID: UUID

    public init(featureID: UUID, sketchID: UUID, shapeID: UUID) {
        self.featureID = featureID; self.sketchID = sketchID; self.shapeID = shapeID
    }
}
