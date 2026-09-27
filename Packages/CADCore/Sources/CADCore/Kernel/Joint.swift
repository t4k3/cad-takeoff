import Foundation

/// «Giunto» (Fusion's Joint): places a part against another by one point and axis on each
/// (the centre and axis of a hole, a shaft, a face), then lets it turn or slide by a value.
/// Points and axes are stored in each part's own coordinates, so they follow the parts.
public struct JointSpec: Codable, Sendable, Equatable {
    public enum Kind: String, Codable, Sendable, CaseIterable {
        /// Fixed: aligned, optionally turned by `angle`.
        case rigid
        /// Turns about the axis by `angle`.
        case revolute
        /// Slides along the axis by `offset`.
        case slider
        /// Turns and slides.
        case cylindrical

        public var label: String {
            switch self {
            case .rigid: "Rigido"
            case .revolute: "Rotazione"
            case .slider: "Scorrimento"
            case .cylindrical: "Cilindrico"
            }
        }
    }

    public var kind: Kind
    /// The body placed by the joint (its source feature).
    public var moving: UUID
    public var movingOrigin: Vec3
    public var movingAxis: Vec3
    /// The body it is joined to; nil = the world (origin and axis in world coordinates).
    public var fixed: UUID?
    public var fixedOrigin: Vec3
    public var fixedAxis: Vec3
    /// Degrees about the axis; mm along it.
    public var angle: Double
    public var offset: Double
    /// The moving axis against the fixed one (face to face instead of stacked).
    public var flip: Bool

    public init(kind: Kind, moving: UUID, movingOrigin: Vec3, movingAxis: Vec3, fixed: UUID?, fixedOrigin: Vec3, fixedAxis: Vec3,
                angle: Double = 0, offset: Double = 0, flip: Bool = false) {
        self.kind = kind; self.moving = moving; self.movingOrigin = movingOrigin; self.movingAxis = movingAxis
        self.fixed = fixed; self.fixedOrigin = fixedOrigin; self.fixedAxis = fixedAxis
        self.angle = angle; self.offset = offset; self.flip = flip
    }

    public func validate() throws {
        guard movingAxis.length > 1e-9, fixedAxis.length > 1e-9 else { throw KernelError.invalidParameter("giunto: asse nullo") }
        guard [movingOrigin, fixedOrigin].allSatisfy({ $0.isFinite }), angle.isFinite, offset.isFinite, abs(offset) <= 100_000 else {
            throw KernelError.invalidParameter("giunto: valori non validi")
        }
        guard fixed != moving else { throw KernelError.invalidParameter("giunto: un pezzo non si unisce a sé stesso") }
    }

    /// Only the values the kind allows.
    var effectiveAngle: Double { kind == .slider ? 0 : angle }
    var effectiveOffset: Double { kind == .revolute || kind == .rigid ? 0 : offset }
}

/// A rigid motion p ↦ R·p + t (R given by its columns).
public struct RigidMotion: Sendable, Equatable {
    public var c0: Vec3, c1: Vec3, c2: Vec3
    public var t: Vec3

    public static let identity = RigidMotion(c0: Vec3(1, 0, 0), c1: Vec3(0, 1, 0), c2: Vec3(0, 0, 1), t: .zero)

    public func direction(_ v: Vec3) -> Vec3 { c0 * v.x + c1 * v.y + c2 * v.z }
    public func point(_ p: Vec3) -> Vec3 { direction(p) + t }
    /// self after `other`.
    public func after(_ other: RigidMotion) -> RigidMotion {
        RigidMotion(c0: direction(other.c0), c1: direction(other.c1), c2: direction(other.c2), t: point(other.t))
    }
    public var inverse: RigidMotion {
        // Transpose of R; t' = −Rᵀ t.
        let r0 = Vec3(c0.x, c1.x, c2.x), r1 = Vec3(c0.y, c1.y, c2.y), r2 = Vec3(c0.z, c1.z, c2.z)
        let inv = RigidMotion(c0: r0, c1: r1, c2: r2, t: .zero)
        return RigidMotion(c0: r0, c1: r1, c2: r2, t: -inv.direction(t))
    }

    /// Rotation by `degrees` about the unit axis `k` through the origin.
    public static func rotation(about k: Vec3, degrees: Double) -> RigidMotion {
        let a = degrees * .pi / 180, c = cos(a), s = sin(a), n = k.normalized
        func rot(_ v: Vec3) -> Vec3 { v * c + n.cross(v) * s + n * (n.dot(v) * (1 - c)) }
        return RigidMotion(c0: rot(Vec3(1, 0, 0)), c1: rot(Vec3(0, 1, 0)), c2: rot(Vec3(0, 0, 1)), t: .zero)
    }

    /// The shortest turn taking the unit direction `a` onto `b`.
    public static func aligning(_ a: Vec3, to b: Vec3) -> RigidMotion {
        let u = a.normalized, v = b.normalized
        let axis = u.cross(v), s = axis.length, c = u.dot(v)
        if s < 1e-12 {
            if c > 0 { return .identity }
            // Opposite: half a turn about any perpendicular.
            let helper = abs(u.x) < 0.9 ? Vec3(1, 0, 0) : Vec3(0, 1, 0)
            return rotation(about: u.cross(helper).normalized, degrees: 180)
        }
        return rotation(about: axis / s, degrees: atan2(s, c) * 180 / .pi)
    }
}

extension Vec3 {
    static func / (v: Vec3, k: Double) -> Vec3 { v * (1 / k) }
}

extension ComponentRef {
    /// The part's own coordinates → where the assembly places it (rotation, then position).
    public func placement(position: Vec3) -> RigidMotion {
        RigidMotion(c0: rotate(Vec3(1, 0, 0)), c1: rotate(Vec3(0, 1, 0)), c2: rotate(Vec3(0, 0, 1)), t: position)
    }
}

extension Feature {
    /// Where the feature's own coordinates land in the design (components are placed; everything
    /// else is modelled in place).
    public var placementMotion: RigidMotion {
        if case let .component(ref) = kind { return ref.placement(position: position) }
        return .identity
    }
}

extension JointSpec {
    /// The motion that brings the moving part from where it is (`movingNow`: its placement and any
    /// earlier motion) to its joined place against the fixed part (`fixedNow`, nil = world).
    func motion(movingNow: RigidMotion, fixedNow: RigidMotion?) -> RigidMotion {
        let oB = movingNow.point(movingOrigin), aB = movingNow.direction(movingAxis).normalized
        let oF = fixedNow.map { $0.point(fixedOrigin) } ?? fixedOrigin
        let aF = (fixedNow.map { $0.direction(fixedAxis) } ?? fixedAxis).normalized
        let target = flip ? -aF : aF
        // Axis onto axis, then the turn about it, then origin onto origin (+ the slide).
        let turn = RigidMotion.rotation(about: target, degrees: effectiveAngle).after(.aligning(aB, to: target))
        let shift = oF + target * effectiveOffset - turn.direction(oB)
        return RigidMotion(c0: turn.c0, c1: turn.c1, c2: turn.c2, t: shift)
    }
}

/// Where a joint grips a part: from a picked edge or face, in world coordinates.
public enum JointFrame {
    /// A round edge: its centre and axis; a straight one: its middle and direction.
    public static func from(edge e: EdgeInfo) -> (origin: Vec3, axis: Vec3)? {
        let p = e.polyline
        guard p.count >= 2 else { return nil }
        if p.count >= 4 {
            var n = Vec3.zero
            for i in p.indices { let a = p[i], b = p[(i + 1) % p.count]; n = n + Vec3((a.y - b.y) * (a.z + b.z), (a.z - b.z) * (a.x + b.x), (a.x - b.x) * (a.y + b.y)) }
            if n.length > 1e-9 {
                n = n.normalized
                let c0 = p.reduce(Vec3.zero, +) * (1 / Double(p.count))
                let helper = abs(n.z) < 0.9 ? Vec3(0, 0, 1) : Vec3(1, 0, 0)
                let u = helper.cross(n).normalized, v = n.cross(u)
                if p.allSatisfy({ abs(($0 - c0).dot(n)) < 1e-4 }), let fit = PrimitiveKernel.fit(p.map { Vec2(($0 - c0).dot(u), ($0 - c0).dot(v)) }),
                   p.allSatisfy({ abs((Vec2(($0 - c0).dot(u), ($0 - c0).dot(v)) - fit.c).length - fit.r) < 0.02 * fit.r + 1e-4 }) {
                    return (c0 + u * fit.c.x + v * fit.c.y, n)
                }
            }
        }
        let a = p.first!, b = p.last!
        guard (b - a).length > 1e-9 else { return nil }
        return ((a + b) * 0.5, (b - a).normalized)
    }

    /// A plane: its middle and normal; a cylinder or cone: the point of its axis level with the
    /// face's middle, and the axis.
    public static func from(face id: FaceID, in s: BodySnapshot) -> (origin: Vec3, axis: Vec3)? {
        guard let f = s.faces.firstIndex(where: { $0.id == id }) else { return nil }
        var sum = Vec3.zero, area = 0.0
        for t in 0..<s.triangleFace.count where Int(s.triangleFace[t]) == f {
            let v = (0..<3).map { s.positions[Int(s.triangles[t * 3 + $0])] }
            let a = (v[1] - v[0]).cross(v[2] - v[0]).length / 2
            sum = sum + (v[0] + v[1] + v[2]) * (a / 3); area += a
        }
        guard area > 0 else { return nil }
        let centre = sum * (1 / area)
        switch s.faces[f].surface {
        case let .plane(_, n): return (centre, n.normalized)
        case let .cylinder(o, a, _), let .cone(o, a, _):
            let k = a.normalized
            return (o + k * (centre - o).dot(k), k)
        case let .torus(c, a, _, _): return (c, a.normalized)
        case let .sphere(c, _): return (c, Vec3(0, 0, 1))
        case .freeform: return nil
        }
    }
}
