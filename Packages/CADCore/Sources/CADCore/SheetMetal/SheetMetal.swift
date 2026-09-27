import Foundation

// Sheet-metal part (T79): a base plate with flanges on any of its four sides, bent with the
// material's press-brake rule. A feature of the timeline like the solids: folded body for the
// design, flat pattern (developed blank with bend lines) for cutting and the DXF.
//
// Dimensions are workshop style: width/depth are the OUTSIDE footprint (mould lines), flange
// lengths are outside/inside/tangent lengths. Corners between flanges are open (each flange spans
// the flat part of its side) or closed: front/back walls run on over the corner, the side walls
// stop a small gap short of them, and the blank gets a square relief where the bends meet.

public enum SheetEdge: String, Codable, CaseIterable, Sendable {
    case front, right, back, left

    public var label: String {
        switch self {
        case .front: "Davanti"
        case .right: "Destra"
        case .back: "Dietro"
        case .left: "Sinistra"
        }
    }
}

public enum SheetBendDirection: String, Codable, CaseIterable, Sendable {
    case up, down
    public var label: String { self == .up ? "In su" : "In giù" }
}

/// Where a flange length is measured from (as in Fusion's flange dialog).
public enum SheetFlangeReference: String, Codable, CaseIterable, Sendable {
    /// From the outer mould line: the outside dimension on a workshop drawing (default).
    case outside
    /// From the inner mould line.
    case inside
    /// Straight part only, from the end of the bend.
    case tangent

    public var label: String {
        switch self {
        case .outside: "Quota esterna"
        case .inside: "Quota interna"
        case .tangent: "Dalla tangente"
        }
    }
}

/// How two neighbouring flanges meet.
public enum SheetCornerStyle: String, Codable, CaseIterable, Sendable {
    /// Each flange spans its side only: a notch at every corner (simple, any angle).
    case open
    /// A closed box corner: the front/back walls cover the corner, the left/right walls butt
    /// against them with `cornerGap` of clearance; square relief where the bends meet.
    /// Only between flanges bent 90° the same way (others stay open, with a warning).
    case closed

    public var label: String { self == .open ? "Aperti" : "Chiusi" }
}

public struct SheetFlange: Codable, Equatable, Sendable {
    public var length: Double
    /// Degrees from flat (90 = right angle), 5–135.
    public var angle: Double
    public var direction: SheetBendDirection
    public var reference: SheetFlangeReference
    /// A second bend at the flange's tip (nil = none).
    public var lip: SheetLip?

    public init(length: Double, angle: Double = 90, direction: SheetBendDirection = .up, reference: SheetFlangeReference = .outside,
                lip: SheetLip? = nil) {
        self.length = length; self.angle = angle; self.direction = direction; self.reference = reference; self.lip = lip
    }
}

/// «Risvolto» / «orlo»: a second bend at a flange's tip. Inward it curls on towards the part (a C
/// channel's lip); outward it turns away (a Z); at 180° it folds back against the flange (open hem,
/// with the material's inside radius). The flange's length then runs to the lip's outside, the
/// lip's from the flange face on the outside of the lip's bend (for a Z, the far face); both as
/// the flange's reference says.
public struct SheetLip: Codable, Equatable, Sendable {
    public var length: Double
    /// Degrees from straight on, 5–180 (180 = hem).
    public var angle: Double
    public var inward: Bool

    public init(length: Double, angle: Double = 90, inward: Bool = true) {
        self.length = length; self.angle = angle; self.inward = inward
    }

    public var label: String { angle >= 180 - 1e-9 ? "orlo" : "risvolto" }
}

/// A flange on a side of a free-form base: the side from outline point `side` to the next.
public struct SheetSideFlange: Codable, Equatable, Sendable {
    public var side: Int
    public var flange: SheetFlange
    public init(side: Int, flange: SheetFlange) { self.side = side; self.flange = flange }
}

public struct SheetMetalSpec: Codable, Equatable, Sendable {
    /// `SheetMaterial.id`.
    public var material: String
    public var thickness: Double
    /// Nil = from the material's press-brake rule.
    public var radiusOverride: Double?
    /// Nil = DIN 6935 from r/t.
    public var kOverride: Double?
    /// Outside footprint along X and Y.
    public var width: Double
    public var depth: Double
    public var front: SheetFlange?
    public var right: SheetFlange?
    public var back: SheetFlange?
    public var left: SheetFlange?
    /// Nil = open (files written before closed corners existed).
    public var corners: SheetCornerStyle?
    /// Clearance between a side wall and the wall it butts against, closed corners (nil = 0.2 mm).
    public var cornerGap: Double?
    /// Free-form base: the outside footprint (mould lines) as a polygon in the part's XY, either
    /// winding; nil = the `width` × `depth` rectangle centred on the origin with its four flanges.
    public var outline: [Vec2]?
    /// Flanges on the free-form base's straight sides (open corners).
    public var sideFlanges: [SheetSideFlange]?

    public var cornerStyle: SheetCornerStyle { corners ?? .open }
    public var gap: Double { cornerGap ?? 0.2 }

    public init(material: String = "dc01", thickness: Double = 1.5, width: Double = 80, depth: Double = 50,
                flanges: [SheetEdge: SheetFlange] = [:], radiusOverride: Double? = nil, kOverride: Double? = nil) {
        self.material = material; self.thickness = thickness; self.width = width; self.depth = depth
        self.radiusOverride = radiusOverride; self.kOverride = kOverride
        for (e, f) in flanges { self[e] = f }
    }

    /// A free-form base (its bounding box as width × depth) with flanges on some of its sides.
    public init(material: String = "dc01", thickness: Double = 1.5, outline: [Vec2], sideFlanges: [SheetSideFlange] = [],
                radiusOverride: Double? = nil, kOverride: Double? = nil) {
        let xs = outline.map(\.x), ys = outline.map(\.y)
        self.init(material: material, thickness: thickness, width: (xs.max() ?? 0) - (xs.min() ?? 0), depth: (ys.max() ?? 0) - (ys.min() ?? 0),
                  radiusOverride: radiusOverride, kOverride: kOverride)
        self.outline = outline
        self.sideFlanges = sideFlanges
    }

    public subscript(edge: SheetEdge) -> SheetFlange? {
        get {
            switch edge { case .front: front; case .right: right; case .back: back; case .left: left }
        }
        set {
            switch edge { case .front: front = newValue; case .right: right = newValue; case .back: back = newValue; case .left: left = newValue }
        }
    }

    /// The bending rule actually used: material defaults unless overridden.
    public func rule() throws -> SheetBendRule {
        guard let m = SheetMaterial.named(material) else { throw SheetMetalError.invalidParameter("materiale sconosciuto «\(material)»") }
        guard thickness.isFinite, (0.1...30).contains(thickness) else { throw SheetMetalError.invalidParameter("spessore 0,1–30 mm") }
        let r = radiusOverride ?? m.insideRadius(thickness: thickness)
        guard r.isFinite, (0.05...500).contains(r) else { throw SheetMetalError.invalidParameter("raggio interno 0,05–500 mm") }
        let k = kOverride ?? SheetMaterial.kFactor(insideRadius: r, thickness: thickness)
        guard k.isFinite, (0...0.5).contains(k) else { throw SheetMetalError.invalidParameter("K-factor 0–0,5") }
        return SheetBendRule(material: m, thickness: thickness, insideRadius: r, kFactor: k,
                             vDie: m.vDie(thickness: thickness), minimumFlange: m.minimumFlange(thickness: thickness),
                             radiusIsDefault: radiusOverride == nil, kIsDefault: kOverride == nil)
    }

    /// "DC01 1,5 mm · 2 flange".
    public var summary: String {
        let count = outline != nil ? (sideFlanges ?? []).count : SheetEdge.allCases.filter { self[$0] != nil }.count
        let t = thickness == thickness.rounded() ? String(format: "%.0f", thickness) : String(format: "%g", thickness)
        let short = SheetMaterial.named(material)?.name.components(separatedBy: " (").first ?? material
        return "\(short) \(t) mm" + (count == 0 ? "" : " · \(count) flang\(count == 1 ? "ia" : "e")")
    }
}

public struct SheetBendRule: Equatable, Sendable {
    public let material: SheetMaterial
    public let thickness: Double
    public let insideRadius: Double
    public let kFactor: Double
    /// V-die opening the defaults assume.
    public let vDie: Double
    /// Shortest bendable flange (outside, 90°) with that die.
    public let minimumFlange: Double
    public let radiusIsDefault: Bool
    public let kIsDefault: Bool

    /// Neutral-line length of a bend.
    public func allowance(angleDegrees: Double) -> Double { angleDegrees * .pi / 180 * (insideRadius + kFactor * thickness) }
}

public enum SheetMetalError: Error, LocalizedError, Equatable, Sendable {
    case invalidParameter(String)

    public var errorDescription: String? {
        switch self { case .invalidParameter(let detail): "Lamiera: \(detail)" }
    }
}

/// Developed blank: outline to cut and bend lines, in the part's XY frame (plate at its place).
public struct SheetFlatPattern: Equatable, Sendable {
    public struct Bend: Equatable, Sendable {
        /// The side of the rectangular base, or (free-form base) the side's index in its outline.
        public let edge: SheetEdge?
        public var side: Int? = nil
        /// Bend (centre) line and the two tangent lines where the bend zone starts and ends.
        public let line: (Vec2, Vec2)
        public let tangents: [(Vec2, Vec2)]
        public let angle: Double
        public let direction: SheetBendDirection
        public let insideRadius: Double

        public static func == (a: Bend, b: Bend) -> Bool {
            a.edge == b.edge && a.side == b.side && a.line.0 == b.line.0 && a.line.1 == b.line.1 && a.angle == b.angle
                && a.direction == b.direction && a.insideRadius == b.insideRadius
        }
    }

    public struct Hole: Equatable, Sendable {
        public let center: Vec2
        public let diameter: Double
    }

    /// Counter-clockwise outline (closed, first point not repeated); notches cut at the edge
    /// are taken out of it.
    public internal(set) var outline: [Vec2]
    public let bends: [Bend]
    /// Round holes to cut, unfolded from the holes drilled in the folded part.
    public internal(set) var holes: [Hole] = []
    /// Other cut-outs (windows, slots from sketch cuts), closed outlines in the same frame.
    public internal(set) var cutouts: [[Vec2]] = []
    public let thickness: Double
    /// Offset of the part (the feature position): the flat pattern lies at the plate.
    public let origin: Vec3

    public var area: Double {
        Profile2D(points: outline).area - holes.reduce(0) { $0 + .pi * $1.diameter * $1.diameter / 4 }
            - cutouts.reduce(0) { $0 + abs(Profile2D(points: $1).area) }
    }
    public var size: (width: Double, height: Double) {
        let xs = outline.map(\.x), ys = outline.map(\.y)
        return ((xs.max() ?? 0) - (xs.min() ?? 0), (ys.max() ?? 0) - (ys.min() ?? 0))
    }
}

public struct SheetMetalBuild: Sendable {
    public let rule: SheetBendRule
    public let folded: CSGSolid
    public let flat: SheetFlatPattern
    /// Workshop advice (short flanges, radii below the material minimum…): not errors.
    public let warnings: [String]
    let layout: SheetLayout

    /// The flat pattern with the holes drilled in the folded part (hole features that cut it).
    /// Holes on the plate or on a flange's straight part unfold exactly; holes crossing a bend,
    /// blind or not square to the sheet are skipped and counted.
    /// Cut-outs (`SheetCutout`) unfold when the whole outline lies on one flat region, cut
    /// square to it; round ones become holes.
    public func flat(adding holes: [HoleSpec], cutouts: [SheetCutout] = []) -> (flat: SheetFlatPattern, skipped: Int) {
        var out = flat, skipped = 0
        for spec in holes {
            let through = spec.depth.map { $0 >= layout.t - 1e-6 } ?? true
            for c in spec.centers {
                if through, let p = layout.unfold(c, axis: spec.direction.normalized) {
                    out.holes.append(.init(center: p, diameter: spec.boreDiameter))
                } else { skipped += 1 }
            }
        }
        for cut in cutouts {
            let axis = cut.axis.normalized
            let mapped = cut.outline.map { layout.region(of: $0, axis: axis) }
            let regions = Set(mapped.compactMap { $0?.region })
            guard cut.outline.count >= 3, regions.count == 1, let region = regions.first else { skipped += 1; continue }
            guard mapped.contains(where: { $0 == nil }) else {
                let pts = mapped.map { $0!.point }
                // A sketch circle (a polygon on one circle): a hole, as the laser wants it.
                if pts.count >= 16, let fit = PrimitiveKernel.fit(pts), pts.allSatisfy({ abs(($0 - fit.c).length - fit.r) < 1e-3 * max(1, fit.r) }) {
                    out.holes.append(.init(center: fit.c, diameter: 2 * fit.r))
                } else {
                    out.cutouts.append(pts)
                }
                continue
            }
            // Part of it off the region: a notch, if those points fall off the blank (not on a
            // bend or another wall). The blank's outline loses it.
            let pts = cut.outline.compactMap { layout.region(of: $0, axis: axis, only: region)?.point }
            guard pts.count == cut.outline.count,
                  zip(mapped, pts).allSatisfy({ m, p in m != nil || !SketchArrangement.inside(p, out.outline) }),
                  let notched = SheetMetalGeometry.subtract(pts, from: out.outline) else { skipped += 1; continue }
            out.outline = notched
        }
        return (out, skipped)
    }
}


/// A cut through the folded sheet (a sketch cut): its outline where it meets the sheet, in world
/// coordinates, and the cutting direction.
public struct SheetCutout: Sendable, Equatable {
    public var outline: [Vec3]
    public var axis: Vec3
    public init(outline: [Vec3], axis: Vec3) { self.outline = outline; self.axis = axis }

    /// What a cutting feature leaves through a sheet: a sketch cut's outline (and its islands),
    /// a cylinder's circle; nil for other kinds and drafted cuts.
    public static func of(_ f: Feature) -> [SheetCutout]? {
        guard f.operation == .cut, f.taper == 0 else { return nil }
        let outlines: [[Vec2]]
        switch f.kind {
        case let .extrude(profile, _): outlines = [profile.points] + f.holes.map(\.points)
        case let .cylinder(r, _): outlines = [(0..<48).map { k in let a = Double(k) / 48 * 2 * .pi; return Vec2(r * cos(a), r * sin(a)) }]
        default: return nil
        }
        let plane = f.placement?.plane ?? .xy
        return outlines.map { SheetCutout(outline: $0.map { plane.world($0) + f.position }, axis: plane.normal) }
    }
}

/// Where everything is, to map folded points back onto the flat pattern.
struct SheetLayout: Sendable {
    struct Bent: Sendable {
        /// The side's tangent line on the plate: start, outward and along directions, length.
        let origin: Vec2; let out: Vec2; let along: Vec2; let span: Double
        let theta: Double; let straight: Double; let allowance: Double; let up: Bool
        /// Straight part run on past the side's start/end (closed corners).
        var extStart = 0.0, extEnd = 0.0
        /// The lip at the tip, if any: its bend, straight part, side, and how much shorter than
        /// the side it is at each end.
        struct Lip: Sendable { let theta: Double; let straight: Double; let allowance: Double; let inward: Bool; let trimStart: Double; let trimEnd: Double }
        var lip: Lip?
    }
    /// The flat plate between the tangent lines (counter-clockwise).
    let plate: [Vec2]
    let r: Double, t: Double
    let position: Vec3
    let flanges: [Bent]

    /// Flat-pattern point of a hole centre drilled along `axis`, if it lies on a flat region.
    func unfold(_ world: Vec3, axis: Vec3) -> Vec2? { region(of: world, axis: axis, inSheet: true)?.point }

    /// Flat-pattern point of a point cut along `axis` and the flat region it falls on (0 = plate,
    /// k = the k-th flange's straight part). `inSheet`: the point itself must lie within the
    /// sheet's thickness (a hole centre); otherwise the cut's line along the axis is followed.
    /// `only`: that region's mapping carried on past its bounds (a notch running off the edge).
    func region(of world: Vec3, axis: Vec3, inSheet: Bool = false, only: Int? = nil) -> (point: Vec2, region: Int)? {
        let q = world - position
        let e = 1e-4
        if only == 0 { return abs(axis.z) > 0.999 ? (Vec2(q.x, q.y), 0) : nil }
        if only == nil, abs(axis.z) > 0.999, onPlate(Vec2(q.x, q.y), within: e), !inSheet || (q.z >= -e && q.z <= t + e) {
            return (Vec2(q.x, q.y), 0)
        }
        for (k, b) in flanges.enumerated() where only == nil || only == k + 1 || only == 101 + k {
            let (origin, out, along, span) = (b.origin, b.out, b.along, b.span)
            let rel = Vec2(q.x - origin.x, q.y - origin.y)
            let u = rel.x * out.x + rel.y * out.y, s = rel.x * along.x + rel.y * along.y
            // Section of the straight part: mid-thickness line from the bend end along d.
            let rm = r + t / 2
            let c = Vec2(0, r + t)
            var mid = Vec2(rm * sin(b.theta), c.y - rm * cos(b.theta))
            var d = Vec2(cos(b.theta), sin(b.theta))
            if !b.up { mid = Vec2(mid.x, t - mid.y); d = Vec2(d.x, -d.y) }
            let w = q.z
            let along2 = (u - mid.x) * d.x + (w - mid.y) * d.y
            let across = abs((u - mid.x) * -d.y + (w - mid.y) * d.x)
            // The flange's normal in world: perpendicular to d in the (out, z) plane.
            let normal = Vec3(out.x * -d.y, out.y * -d.y, d.x)
            let inBend = along2 < e
            // The lip's straight part (region 101 + k): its mid line in this section.
            if let lip = b.lip, only == nil || only == 101 + k {
                let nIn = b.up ? Vec2(-sin(b.theta), cos(b.theta)) : Vec2(-sin(b.theta), -cos(b.theta))
                func mirror(_ p: Vec2) -> Vec2 { b.up ? p : Vec2(p.x, t - p.y) }
                let outerTip = mirror(Vec2((r + t) * sin(b.theta), (r + t) * (1 - cos(b.theta)))) + d * b.straight
                let innerTip = mirror(Vec2(r * sin(b.theta), r + t - r * cos(b.theta))) + d * b.straight
                let o = lip.inward ? outerTip : innerTip, y = lip.inward ? nIn : nIn * -1
                let m = o + d * (rm * sin(lip.theta)) + y * (r + t - rm * cos(lip.theta))
                let d2 = d * cos(lip.theta) + y * sin(lip.theta)
                let along3 = (u - m.x) * d2.x + (w - m.y) * d2.y
                let across3 = abs((u - m.x) * -d2.y + (w - m.y) * d2.x)
                let normal2 = Vec3(out.x * -d2.y, out.y * -d2.y, d2.x)
                let fits = only != nil || (s >= lip.trimStart - e && s <= span - lip.trimEnd + e && along3 >= -e && along3 <= lip.straight + e
                                           && (!inSheet || across3 <= t / 2 + e))
                if fits, abs(normal2.dot(axis)) > 0.999 {
                    let reach = b.allowance + b.straight + lip.allowance + along3
                    return (Vec2(origin.x + along.x * s + out.x * reach, origin.y + along.y * s + out.y * reach), 101 + k)
                }
                if only != nil { return nil }
            }
            if only != nil {
                guard abs(normal.dot(axis)) > 0.999 else { return nil }
                let reach = b.allowance + along2
                return (Vec2(origin.x + along.x * s + out.x * reach, origin.y + along.y * s + out.y * reach), k + 1)
            }
            guard s >= -e - (inBend ? 0 : b.extStart), s <= span + e + (inBend ? 0 : b.extEnd), along2 >= -e, along2 <= b.straight + e,
                  !inSheet || across <= t / 2 + e, abs(normal.dot(axis)) > 0.999 else { continue }
            let reach = b.allowance + along2
            return (Vec2(origin.x + along.x * s + out.x * reach, origin.y + along.y * s + out.y * reach), k + 1)
        }
        return nil
    }

    /// Inside the plate or on its border (within `e`).
    func onPlate(_ p: Vec2, within e: Double) -> Bool {
        if SketchArrangement.inside(p, plate) { return true }
        for i in plate.indices {
            let a = plate[i], b = plate[(i + 1) % plate.count], d = b - a
            let u = max(0, min(1, (p - a).dot(d) / max(d.dot(d), 1e-18)))
            if (a + d * u - p).length <= e { return true }
        }
        return false
    }
}

public enum SheetMetalGeometry {
    static let bendSegments = 16

    /// A flange's straight length, bend allowance and outside setback from the mould line, and
    /// its lip's; workshop advice goes to `warnings`.
    struct Bent {
        let flange: SheetFlange; let theta: Double; let straight: Double; let allowance: Double; let setback: Double
        /// The lip's bend angle, straight part and allowance (0 without a lip).
        var lipTheta = 0.0, lipStraight = 0.0, lipAllowance = 0.0
        /// Flat reach: up to the lip's bend, and in all.
        var reach: Double { allowance + straight }
        var total: Double { reach + lipAllowance + lipStraight }

        init(_ f: SheetFlange, name: String, rule: SheetBendRule, warnings: inout [String]) throws {
            let t = rule.thickness, r = rule.insideRadius
            // Setback of a bend at a length's far end: to the virtual sharp up to 90°, to the bend's
            // farthest point beyond (a hem has no sharp).
            func farSetback(_ theta: Double, _ radius: Double, _ ref: SheetFlangeReference) -> Double {
                let rr = ref == .inside ? radius : radius + t
                guard ref != .tangent else { return 0 }
                return theta <= .pi / 2 + 1e-9 ? tan(theta / 2) * rr : rr
            }
            guard f.angle.isFinite, (5...135).contains(f.angle) else {
                throw SheetMetalError.invalidParameter("\(name): angolo 5–135° dalla posizione piana")
            }
            guard f.length.isFinite, (0.1...10_000).contains(f.length) else {
                throw SheetMetalError.invalidParameter("\(name): lunghezza flangia 0,1–10000 mm")
            }
            let theta = f.angle * .pi / 180
            let outer = tan(theta / 2) * (r + t), inner = tan(theta / 2) * r
            var straight: Double
            switch f.reference {
            case .outside: straight = f.length - outer
            case .inside: straight = f.length - inner
            case .tangent: straight = f.length
            }
            var lipTheta = 0.0, lipStraight = 0.0
            if let lip = f.lip {
                guard lip.angle.isFinite, (5...180).contains(lip.angle) else {
                    throw SheetMetalError.invalidParameter("\(name): angolo del \(lip.label) 5–180°")
                }
                guard lip.length.isFinite, (0.1...10_000).contains(lip.length) else {
                    throw SheetMetalError.invalidParameter("\(name): lunghezza del \(lip.label) 0,1–10000 mm")
                }
                lipTheta = lip.angle * .pi / 180
                straight -= farSetback(lipTheta, r, f.reference)
                lipStraight = lip.length - farSetback(lipTheta, r, f.reference)
                guard lipStraight >= 0.05 else {
                    throw SheetMetalError.invalidParameter("\(lip.label) \(name) troppo corto: serve più di \(fmt(farSetback(lipTheta, r, f.reference))) mm")
                }
                if lip.length < rule.minimumFlange - 1e-9 {
                    warnings.append("\(lip.label.capitalized) \(name) \(fmt(lip.length)) mm: sotto il minimo piegabile ≈ \(fmt(rule.minimumFlange)) mm con matrice V\(fmt(rule.vDie))")
                }
            }
            guard straight >= 0.05 else {
                let min = f.reference == .outside ? outer : inner
                throw SheetMetalError.invalidParameter("flangia \(name) troppo corta: con raggio \(fmt(r)) e spessore \(fmt(t)) serve più di \(fmt(min)) mm")
            }
            // Workshop minimum, compared as an outside length.
            let outsideLength = straight + outer
            if outsideLength < rule.minimumFlange - 1e-9 {
                warnings.append("Flangia \(name) \(fmt(outsideLength)) mm (esterna): sotto il minimo piegabile ≈ \(fmt(rule.minimumFlange)) mm con matrice V\(fmt(rule.vDie))")
            }
            flange = f; self.theta = theta; self.straight = straight
            allowance = rule.allowance(angleDegrees: f.angle); setback = outer
            if let lip = f.lip { self.lipTheta = lipTheta; self.lipStraight = lipStraight; lipAllowance = rule.allowance(angleDegrees: lip.angle) }
        }
    }

    /// `folded: false` skips the folded solid (rule, flat pattern and warnings only: cheap).
    public static func build(_ spec: SheetMetalSpec, featureID: UUID, position: Vec3 = .zero, folded: Bool = true) throws -> SheetMetalBuild {
        let rule = try spec.rule()
        let t = rule.thickness, r = rule.insideRadius
        for (v, name) in [(spec.width, "larghezza"), (spec.depth, "profondità")] {
            guard v.isFinite, (1...10_000).contains(v) else { throw SheetMetalError.invalidParameter("\(name) 1–10000 mm") }
        }
        var warnings: [String] = []
        if let over = spec.radiusOverride, over < rule.material.minimumRadiusRatio * t - 1e-9 {
            warnings.append("Raggio \(fmt(over)) mm sotto il minimo consigliato per \(rule.material.name) (\(fmt(rule.material.minimumRadiusRatio * t)) mm): rischio di cricche")
        }
        if !rule.material.thicknesses.contains(where: { abs($0 - t) < 1e-9 }) {
            warnings.append("Spessore \(fmt(t)) mm non standard per \(rule.material.name)")
        }

        if spec.outline != nil {
            return try buildFree(spec, rule: rule, featureID: featureID, position: position, folded: folded, warnings: warnings)
        }
        var bent: [SheetEdge: Bent] = [:]
        for edge in SheetEdge.allCases {
            guard let f = spec[edge] else { continue }
            bent[edge] = try Bent(f, name: edge.label.lowercased(), rule: rule, warnings: &warnings)
        }

        // Inward lips meet over the part's corners: the front/back ones run the whole side, the
        // left/right ones stop short of them by the gap (a square relief in the blank).
        var lipTrim: [SheetEdge: (start: Double, end: Double)] = [:]
        for (cover, butt, atStart) in [(SheetEdge.front, SheetEdge.left, true), (.front, .right, false), (.back, .left, true), (.back, .right, false)] {
            guard let a = bent[cover], let b = bent[butt], let la = a.flange.lip, let lb = b.flange.lip, la.inward, lb.inward else { continue }
            guard a.flange.direction == b.flange.direction, abs(a.flange.angle - 90) < 1e-6, abs(b.flange.angle - 90) < 1e-6,
                  abs(la.angle - 90) < 1e-6, abs(lb.angle - 90) < 1e-6 else {
                warnings.append("Risvolti \(cover.label.lowercased())-\(butt.label.lowercased()): possibile sovrapposizione nell'angolo (si accorciano solo a 90°)")
                continue
            }
            // The cover's lip reaches this far over the plate from its side's tangent line.
            let reach = a.lipStraight + spec.gap
            if cover == .front { lipTrim[butt, default: (0, 0)].start = reach } else { lipTrim[butt, default: (0, 0)].end = reach }
            _ = atStart
        }

        // Closed corners: which side runs on over each corner, and by how much.
        var ext: [SheetEdge: (start: Double, end: Double)] = [:]
        if spec.cornerStyle == .closed {
            let gap = spec.gap
            guard gap.isFinite, (0...5).contains(gap) else { throw SheetMetalError.invalidParameter("gioco negli angoli 0–5 mm") }
            // (front/back side, left/right side, is it at the front/back side's start?)
            let corners: [(SheetEdge, SheetEdge, Bool)] = [(.front, .left, true), (.front, .right, false), (.back, .left, true), (.back, .right, false)]
            for (cover, butt, atStart) in corners {
                guard let a = bent[cover], let b = bent[butt] else { continue }
                guard a.flange.direction == b.flange.direction, abs(a.flange.angle - 90) < 1e-6, abs(b.flange.angle - 90) < 1e-6 else {
                    warnings.append("Angolo \(cover.label.lowercased())-\(butt.label.lowercased()) lasciato aperto: si chiude solo tra flange a 90° piegate nello stesso verso")
                    continue
                }
                // Cover wall reaches the outer face of the side wall; the side wall stops `gap`
                // short of the cover wall's inner face (a 90° wall stands `setback − t` past the plate).
                let over = b.setback, short = a.setback - t - gap
                if atStart { ext[cover, default: (0, 0)].start = over } else { ext[cover, default: (0, 0)].end = over }
                // The side walls run along +Y: the front corner is at their start.
                if short > 1e-6 {
                    if cover == .front { ext[butt, default: (0, 0)].start = short } else { ext[butt, default: (0, 0)].end = short }
                }
            }
        }

        // Flat plate between the tangent lines.
        let x0 = -spec.width / 2 + (bent[.left]?.setback ?? 0), x1 = spec.width / 2 - (bent[.right]?.setback ?? 0)
        let y0 = -spec.depth / 2 + (bent[.front]?.setback ?? 0), y1 = spec.depth / 2 - (bent[.back]?.setback ?? 0)
        guard x1 - x0 > 0.1, y1 - y0 > 0.1 else {
            throw SheetMetalError.invalidParameter("base troppo piccola per raggio e flange: allarga la lamiera o riduci il raggio")
        }

        // Folded: plate ∪ flanges (each flange spans the flat part of its side: open corners).
        let prefix = "sheet:\(featureID.uuidString)"
        var solid = box(Vec3(x0, y0, 0) + position, Vec3(x1, y1, t) + position, prefix: prefix + "/plate")
        for edge in SheetEdge.allCases where folded {
            guard let b = bent[edge] else { continue }
            let frame = edgeFrame(edge, x0: x0, x1: x1, y0: y0, y1: y1)
            let piece = flange(b.flange, theta: b.theta, straight: b.straight, r: r, t: t,
                               origin: frame.origin + position, out: frame.out, along: frame.along, span: frame.span,
                               prefix: prefix + "/" + edge.rawValue)
            solid = solid.union(piece)
            if let lip = b.flange.lip {
                let trim = lipTrim[edge] ?? (0, 0)
                let span = frame.span - trim.start - trim.end
                guard span > 0.1 else { throw SheetMetalError.invalidParameter("\(lip.label) \(edge.label.lowercased()) senza spazio tra i risvolti vicini") }
                let tip = flangeTip(b.flange, theta: b.theta, straight: b.straight, r: r, t: t)
                func world(_ p: Vec2) -> Vec3 { frame.origin + position + frame.out * p.x + Vec3(0, 0, p.y) + frame.along * trim.start }
                let dir = frame.out * tip.d.x + Vec3(0, 0, tip.d.y), inside = frame.out * tip.inner.x + Vec3(0, 0, tip.inner.y)
                solid = solid.union(flange(SheetFlange(length: lip.length), theta: b.lipTheta, straight: b.lipStraight, r: r, t: t,
                                           origin: world(lip.inward ? tip.outer : tip.innerFace), out: dir, along: frame.along, span: span,
                                           prefix: prefix + "/" + edge.rawValue + "/lip", up: lip.inward ? inside : -inside))
            }
            // Closed corners: the straight wall runs on past the bend.
            let e = ext[edge] ?? (0, 0)
            for (from, to, name) in [(-e.start, 0.0, "corner-a"), (frame.span, frame.span + e.end, "corner-b")] where to - from > 1e-9 {
                solid = solid.union(flange(b.flange, theta: b.theta, straight: b.straight, r: r, t: t,
                                           origin: frame.origin + position + frame.along * from, out: frame.out, along: frame.along,
                                           span: to - from, prefix: prefix + "/" + edge.rawValue + "/" + name, straightOnly: true))
            }
        }

        // Flat pattern: plate plus one strip per flange (allowance + straight), cross-shaped; at a
        // closed corner the strips' straight parts run on and the bend zones leave a square relief.
        func outward(_ e: SheetEdge) -> Vec2 {
            switch e { case .front: Vec2(0, -1); case .right: Vec2(1, 0); case .back: Vec2(0, 1); case .left: Vec2(-1, 0) }
        }
        // Counter-clockwise: each corner goes from the incoming side's strip to the outgoing one's.
        let walk: [(corner: Vec2, incoming: SheetEdge, outgoing: SheetEdge)] = [
            (Vec2(x1, y0), .front, .right), (Vec2(x1, y1), .right, .back), (Vec2(x0, y1), .back, .left), (Vec2(x0, y0), .left, .front),
        ]
        func runOn(_ side: SheetEdge, at corner: Vec2) -> Double {
            let e = ext[side] ?? (0, 0)
            let atStart = side == .front || side == .back ? corner.x == x0 : corner.y == y0
            return atStart ? e.start : e.end
        }
        func lipCut(_ side: SheetEdge, at corner: Vec2) -> Double {
            let e = lipTrim[side] ?? (0, 0)
            let atStart = side == .front || side == .back ? corner.x == x0 : corner.y == y0
            return atStart ? e.start : e.end
        }
        var raw: [Vec2] = []
        for (p, i, o) in walk {
            let ni = outward(i), no = outward(o)
            let reachI = bent[i]?.reach ?? 0, reachO = bent[o]?.reach ?? 0
            let totalI = bent[i]?.total ?? 0, totalO = bent[o]?.total ?? 0
            let eI = runOn(i, at: p), eO = runOn(o, at: p)
            let cI = lipCut(i, at: p), cO = lipCut(o, at: p)
            // The incoming strip's lip (narrowed by its cut), then down to its flange.
            raw += [p + ni * totalI - no * cI, p + ni * reachI - no * cI]
            if eI > 0 || eO > 0, let bi = bent[i], let bo = bent[o] {
                raw += [p + ni * reachI + no * eI, p + ni * bi.allowance + no * eI, p + ni * bi.allowance, p,
                        p + no * bo.allowance, p + no * bo.allowance + ni * eO, p + no * reachO + ni * eO]
            } else {
                raw += [p + ni * reachI, p, p + no * reachO]
            }
            raw += [p + no * reachO - ni * cO, p + no * totalO - ni * cO]
        }
        // Start at the front strip's left end, as before closed corners (stable DXF output).
        raw = Array(raw.suffix(3)) + raw.dropLast(3)
        var bends: [SheetFlatPattern.Bend] = []
        for edge in SheetEdge.allCases {
            guard let b = bent[edge] else { continue }
            // Tangent at the plate (distance 0) and at the end of the bend zone (distance BA).
            func line(_ d: Double) -> (Vec2, Vec2) {
                switch edge {
                case .front: (Vec2(x0, y0 - d), Vec2(x1, y0 - d))
                case .back: (Vec2(x0, y1 + d), Vec2(x1, y1 + d))
                case .left: (Vec2(x0 - d, y0), Vec2(x0 - d, y1))
                case .right: (Vec2(x1 + d, y0), Vec2(x1 + d, y1))
                }
            }
            bends.append(.init(edge: edge, line: line(b.allowance / 2), tangents: [line(0), line(b.allowance)],
                               angle: b.flange.angle, direction: b.flange.direction, insideRadius: r))
            if let lip = b.flange.lip {
                // The lip's bend: across its (cut) width, curling on the same way when inward.
                let cut = lipTrim[edge] ?? (0, 0)
                let along: Vec2 = edge == .front || edge == .back ? Vec2(1, 0) : Vec2(0, 1)
                func lipLine(_ d: Double) -> (Vec2, Vec2) { let l = line(d); return (l.0 + along * cut.start, l.1 - along * cut.end) }
                let dir: SheetBendDirection = lip.inward == (b.flange.direction == .up) ? .up : .down
                bends.append(.init(edge: edge, line: lipLine(b.reach + b.lipAllowance / 2), tangents: [lipLine(b.reach), lipLine(b.reach + b.lipAllowance)],
                                   angle: lip.angle, direction: dir, insideRadius: r))
            }
        }
        let flat = SheetFlatPattern(outline: simplified(raw), bends: bends, thickness: t, origin: position)
        let plate = [Vec2(x0, y0), Vec2(x1, y0), Vec2(x1, y1), Vec2(x0, y1)]
        let layout = SheetLayout(plate: plate, r: r, t: t, position: position,
                                 flanges: SheetEdge.allCases.compactMap { e in bent[e].map { b in
                                     let f = edgeFrame(e, x0: x0, x1: x1, y0: y0, y1: y1)
                                     return .init(origin: Vec2(f.origin.x, f.origin.y), out: Vec2(f.out.x, f.out.y), along: Vec2(f.along.x, f.along.y),
                                           span: f.span, theta: b.theta, straight: b.straight, allowance: b.allowance, up: b.flange.direction == .up,
                                           extStart: ext[e]?.start ?? 0, extEnd: ext[e]?.end ?? 0,
                                           lip: b.flange.lip.map { l in .init(theta: b.lipTheta, straight: b.lipStraight, allowance: b.lipAllowance, inward: l.inward,
                                                                             trimStart: lipTrim[e]?.start ?? 0, trimEnd: lipTrim[e]?.end ?? 0) })
                                 } })
        return SheetMetalBuild(rule: rule, folded: solid, flat: flat, warnings: warnings, layout: layout)
    }

    /// A free-form base (`spec.outline`) with flanges on some of its straight sides: each side
    /// with a flange is set back by its bend, the flange spans the plate's side (open corners:
    /// at a convex corner the strips part and leave the corner relief). Two flanged sides meeting
    /// at an inward (reflex) corner would overlap, and are refused.
    static func buildFree(_ spec: SheetMetalSpec, rule: SheetBendRule, featureID: UUID, position: Vec3, folded: Bool,
                          warnings initial: [String]) throws -> SheetMetalBuild {
        var warnings = initial
        let t = rule.thickness, r = rule.insideRadius
        var outline = spec.outline ?? []
        var sides = spec.sideFlanges ?? []
        let n = outline.count
        guard (3...2000).contains(n), outline.allSatisfy({ $0.x.isFinite && $0.y.isFinite && abs($0.x) < 1e5 && abs($0.y) < 1e5 }) else {
            throw SheetMetalError.invalidParameter("contorno della base: da 3 a 2000 punti finiti")
        }
        // Counter-clockwise; a side's index follows its points when the winding is turned.
        if Profile2D.signedArea(outline) < 0 {
            outline.reverse()
            sides = sides.map { SheetSideFlange(side: ((n - 2 - $0.side) % n + n) % n, flange: $0.flange) }
        }
        guard Profile2D.signedArea(outline) > 1 else { throw SheetMetalError.invalidParameter("base troppo piccola") }
        for i in 0..<n where (outline[(i + 1) % n] - outline[i]).length < 1e-6 {
            throw SheetMetalError.invalidParameter("contorno della base con punti ripetuti")
        }
        guard !selfIntersecting(outline) else { throw SheetMetalError.invalidParameter("il contorno della base si interseca") }
        if spec.cornerStyle == .closed { warnings.append("Angoli chiusi solo sulla base rettangolare: qui restano aperti") }

        var bent: [Int: Bent] = [:]
        for sf in sides {
            guard (0..<n).contains(sf.side) else { throw SheetMetalError.invalidParameter("flangia su un lato inesistente (\(sf.side + 1))") }
            guard bent[sf.side] == nil else { throw SheetMetalError.invalidParameter("due flange sul lato \(sf.side + 1)") }
            bent[sf.side] = try Bent(sf.flange, name: "lato \(sf.side + 1)", rule: rule, warnings: &warnings)
        }
        let along = (0..<n).map { (outline[($0 + 1) % n] - outline[$0]).normalized }
        let out = along.map { Vec2($0.y, -$0.x) }
        // Corners: a flange on both sides of an inward corner overlaps. One flange there ends
        // against the plate, which goes on along the next side: the flange stops a relief width
        // short of the corner and a slot with a round end (into the plate) frees it to bend.
        let relief = t
        var reliefAtStart = Set<Int>(), reliefAtEnd = Set<Int>()
        for k in 0..<n {
            let prev = (k + n - 1) % n
            let turn = along[prev].cross(along[k])
            guard turn < -1e-9, bent[prev] != nil || bent[k] != nil else { continue }
            if bent[prev] != nil, bent[k] != nil {
                throw SheetMetalError.invalidParameter("flange sui lati \(prev + 1) e \(k + 1): si sovrappongono nell'angolo rientrante")
            }
            if bent[k] != nil { reliefAtStart.insert(k) } else { reliefAtEnd.insert(prev) }
        }
        if !reliefAtStart.isEmpty || !reliefAtEnd.isEmpty {
            warnings.append("Scarico tondo largo \(fmt(relief)) mm negli angoli rientranti: la flangia si ferma prima dell'angolo")
        }

        // The plate: each side moved in by its setback, corners where the moved sides meet.
        var plate: [Vec2] = []
        for k in 0..<n {
            let prev = (k + n - 1) % n
            let sp = bent[prev]?.setback ?? 0, sk = bent[k]?.setback ?? 0
            let a = outline[k] - out[prev] * sp, b = outline[k] - out[k] * sk
            let denom = along[prev].cross(along[k])
            if abs(denom) < 1e-9 {
                guard abs(sp - sk) < 1e-9 else {
                    throw SheetMetalError.invalidParameter("lati \(prev + 1) e \(k + 1) allineati con flange diverse: uniscili in un lato solo")
                }
                plate.append(b)
            } else {
                plate.append(a + along[prev] * ((b - a).cross(along[k]) / denom))
            }
        }
        for k in 0..<n where (plate[(k + 1) % n] - plate[k]).dot(along[k]) < 0.1 {
            throw SheetMetalError.invalidParameter("base troppo piccola per raggio e flange al lato \(k + 1): allarga la lamiera o riduci il raggio")
        }
        guard !selfIntersecting(plate) else { throw SheetMetalError.invalidParameter("base troppo piccola per raggio e flange") }

        // Folded: plate ∪ flanges.
        let prefix = "sheet:\(featureID.uuidString)"
        var solid = prism(plate, height: t, at: position, prefix: prefix + "/plate")
        struct Side { let origin: Vec2; let out: Vec2; let along: Vec2; let span: Double }
        /// A flanged side's bend line: the plate's side less the reliefs at inward corners.
        func side(_ k: Int) -> Side {
            let a = plate[k], b = plate[(k + 1) % n]
            let start = reliefAtStart.contains(k) ? relief : 0, end = reliefAtEnd.contains(k) ? relief : 0
            return Side(origin: a + along[k] * start, out: out[k], along: along[k], span: (b - a).length - start - end)
        }
        for k in bent.keys where side(k).span < 0.1 {
            throw SheetMetalError.invalidParameter("lato \(k + 1) troppo corto per la flangia con lo scarico")
        }
        // The reliefs' round ends: half-discs into the plate, centred on the bend's tangent line.
        let notches: [Vec2] = reliefAtStart.map { plate[$0] + along[$0] * (relief / 2) }
            + reliefAtEnd.map { plate[($0 + 1) % n] - along[$0] * (relief / 2) }
        /// From `a` to `b` (a relief's width apart on a side) round into the plate.
        func notch(_ a: Vec2, _ b: Vec2, inward: Vec2) -> [Vec2] {
            let c = (a + b) * 0.5, r = (b - a).length / 2, u = (a - c) * (1 / r)
            return (0...16).map { i in let th = Double(i) / 16 * .pi; return c + u * (r * cos(th)) + inward * (r * sin(th)) }
        }
        for (i, c) in notches.enumerated() where folded {
            let spec = HoleSpec(centers: [Vec3(c.x, c.y, t) + position], fit: .manual, diameter: relief)
            solid = solid.subtracting(HoleGeometry.solid(spec, featureID: UUID(uuidString: featureID.uuidString.prefix(24) + String(format: "%012d", 900 + i)) ?? featureID,
                                                         throughDepth: t + 1))
        }
        for (k, b) in bent.sorted(by: { $0.key < $1.key }) where folded {
            let f = side(k)
            let origin = Vec3(f.origin.x, f.origin.y, 0) + position, o = Vec3(f.out.x, f.out.y, 0), al = Vec3(f.along.x, f.along.y, 0)
            solid = solid.union(flange(b.flange, theta: b.theta, straight: b.straight, r: r, t: t, origin: origin, out: o, along: al,
                                       span: f.span, prefix: prefix + "/side-\(k)"))
            if let lip = b.flange.lip {
                let tip = flangeTip(b.flange, theta: b.theta, straight: b.straight, r: r, t: t)
                func world(_ p: Vec2) -> Vec3 { origin + o * p.x + Vec3(0, 0, p.y) }
                let dir = o * tip.d.x + Vec3(0, 0, tip.d.y), inside = o * tip.inner.x + Vec3(0, 0, tip.inner.y)
                solid = solid.union(flange(SheetFlange(length: lip.length), theta: b.lipTheta, straight: b.lipStraight, r: r, t: t,
                                           origin: world(lip.inward ? tip.outer : tip.innerFace), out: dir, along: al, span: f.span,
                                           prefix: prefix + "/side-\(k)/lip", up: lip.inward ? inside : -inside))
            }
        }

        // Flat pattern: the plate with a strip out of each flanged side.
        var raw: [Vec2] = []
        for k in 0..<n {
            let f = side(k)
            if reliefAtStart.contains(k) { raw += notch(plate[k], f.origin, inward: out[k] * -1) } else { raw.append(plate[k]) }
            if let b = bent[k] {
                let end = f.origin + f.along * f.span
                raw += [f.origin + f.out * b.total, end + f.out * b.total, end]
                if reliefAtEnd.contains(k) { raw += notch(end, plate[(k + 1) % n], inward: out[k] * -1) }
            }
        }
        var bends: [SheetFlatPattern.Bend] = []
        for (k, b) in bent.sorted(by: { $0.key < $1.key }) {
            let f = side(k)
            func line(_ d: Double) -> (Vec2, Vec2) { (f.origin + f.out * d, f.origin + f.along * f.span + f.out * d) }
            bends.append(.init(edge: nil, side: k, line: line(b.allowance / 2), tangents: [line(0), line(b.allowance)],
                               angle: b.flange.angle, direction: b.flange.direction, insideRadius: r))
            if let lip = b.flange.lip {
                let dir: SheetBendDirection = lip.inward == (b.flange.direction == .up) ? .up : .down
                bends.append(.init(edge: nil, side: k, line: line(b.reach + b.lipAllowance / 2), tangents: [line(b.reach), line(b.reach + b.lipAllowance)],
                                   angle: lip.angle, direction: dir, insideRadius: r))
            }
        }
        let flat = SheetFlatPattern(outline: simplified(raw), bends: bends, thickness: t, origin: position)
        let layout = SheetLayout(plate: plate, r: r, t: t, position: position, flanges: bent.sorted(by: { $0.key < $1.key }).map { k, b in
            let f = side(k)
            return .init(origin: f.origin, out: f.out, along: f.along, span: f.span, theta: b.theta, straight: b.straight,
                         allowance: b.allowance, up: b.flange.direction == .up,
                         lip: b.flange.lip.map { l in .init(theta: b.lipTheta, straight: b.lipStraight, allowance: b.lipAllowance,
                                                           inward: l.inward, trimStart: 0, trimEnd: 0) })
        })
        return SheetMetalBuild(rule: rule, folded: solid, flat: flat, warnings: warnings, layout: layout)
    }

    /// Two sides of a closed polygon that cross or touch (other than neighbours at their shared point).
    static func selfIntersecting(_ p: [Vec2]) -> Bool {
        let n = p.count
        func crosses(_ a: Vec2, _ b: Vec2, _ c: Vec2, _ d: Vec2) -> Bool {
            let d1 = (b - a).cross(c - a), d2 = (b - a).cross(d - a), d3 = (d - c).cross(a - c), d4 = (d - c).cross(b - c)
            return ((d1 > 1e-12 && d2 < -1e-12) || (d1 < -1e-12 && d2 > 1e-12)) && ((d3 > 1e-12 && d4 < -1e-12) || (d3 < -1e-12 && d4 > 1e-12))
        }
        for i in 0..<n {
            for j in (i + 2)..<max(i + 2, n) where !(i == 0 && j == n - 1) {
                if crosses(p[i], p[(i + 1) % n], p[j], p[(j + 1) % n]) { return true }
            }
        }
        return false
    }

    /// A counter-clockwise polygon extruded by `height`: faces bottom, top and side-k (side k
    /// from point k to the next).
    private static func prism(_ poly: [Vec2], height: Double, at position: Vec3, prefix: String) -> CSGSolid {
        var faces: [CSGFace] = []
        var polys: [CSGSolid.Polygon] = []
        func v(_ p: Vec2, _ z: Double) -> Vec3 { Vec3(p.x, p.y, z) + position }
        faces.append(CSGFace(id: FaceID(rawValue: prefix + "/bottom"), surface: .plane(origin: v(poly[0], 0), normal: Vec3(0, 0, -1)), flipped: false))
        faces.append(CSGFace(id: FaceID(rawValue: prefix + "/top"), surface: .plane(origin: v(poly[0], height), normal: Vec3(0, 0, 1)), flipped: false))
        for (a, b, c) in Profile2D(points: poly).triangulate() {
            polys.append(CSGSolid.Polygon(vertices: [v(poly[a], height), v(poly[b], height), v(poly[c], height)], face: 1))
            polys.append(CSGSolid.Polygon(vertices: [v(poly[c], 0), v(poly[b], 0), v(poly[a], 0)], face: 0))
        }
        for k in poly.indices {
            let a = poly[k], b = poly[(k + 1) % poly.count], d = (b - a).normalized
            faces.append(CSGFace(id: FaceID(rawValue: prefix + "/side-\(k)"), surface: .plane(origin: v(a, 0), normal: Vec3(d.y, -d.x, 0)), flipped: false))
            polys.append(CSGSolid.Polygon(vertices: [v(a, 0), v(b, 0), v(b, height), v(a, height)], face: faces.count - 1))
        }
        return CSGSolid(polygons: polys, faces: faces)
    }

    /// Flat pattern as a thin solid (for display and 3MF), at the plate's height, holes cut.
    public static func flatMesh(_ flat: SheetFlatPattern) -> Mesh {
        guard !flat.holes.isEmpty || !flat.cutouts.isEmpty else {
            return Operations.extrude(Profile2D(points: flat.outline), height: flat.thickness).translated(by: flat.origin)
        }
        return flatSolid(flat, id: UUID()).triangulated().mesh
    }

    /// Flat blank as a solid with named faces (its holes are cylinders), for the viewport.
    public static func flatSolid(_ flat: SheetFlatPattern, id: UUID) -> CSGSolid {
        let plate = Feature(id: id, name: "Sviluppo", kind: .extrude(profile: Profile2D(points: flat.outline), height: flat.thickness),
                            position: flat.origin)
        guard let brep = try? PrimitiveKernel.build(plate) else { return CSGSolid(polygons: [], faces: []) }
        var solid = CSGSolid(brep.snapshot(revision: "flat"))
        for (i, c) in flat.cutouts.enumerated() {
            let tool = Feature(id: UUID(uuidString: String(format: "00000000-0000-0000-0001-%012d", i)) ?? id, name: "Taglio",
                               kind: .extrude(profile: Profile2D(points: c), height: flat.thickness + 2), position: flat.origin - Vec3(0, 0, 1))
            if let brep = try? PrimitiveKernel.build(tool) { solid = solid.subtracting(CSGSolid(brep.snapshot(revision: "flat"))) }
        }
        for (i, h) in flat.holes.enumerated() {
            let spec = HoleSpec(centers: [Vec3(h.center.x, h.center.y, flat.thickness) + flat.origin], fit: .manual, diameter: h.diameter)
            let hole = HoleGeometry.solid(spec, featureID: UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", i)) ?? id,
                                          throughDepth: flat.thickness + 1)
            solid = solid.subtracting(hole)
        }
        return solid
    }

    // MARK: Pieces

    private struct Frame { let origin: Vec3; let out: Vec3; let along: Vec3; let span: Double }

    /// Tangent line of a side: start point, outward direction, direction along the side, length.
    private static func edgeFrame(_ edge: SheetEdge, x0: Double, x1: Double, y0: Double, y1: Double) -> Frame {
        switch edge {
        case .front: Frame(origin: Vec3(x0, y0, 0), out: Vec3(0, -1, 0), along: Vec3(1, 0, 0), span: x1 - x0)
        case .back: Frame(origin: Vec3(x0, y1, 0), out: Vec3(0, 1, 0), along: Vec3(1, 0, 0), span: x1 - x0)
        case .left: Frame(origin: Vec3(x0, y0, 0), out: Vec3(-1, 0, 0), along: Vec3(0, 1, 0), span: y1 - y0)
        case .right: Frame(origin: Vec3(x1, y0, 0), out: Vec3(1, 0, 0), along: Vec3(0, 1, 0), span: y1 - y0)
        }
    }

    private static func box(_ lo: Vec3, _ hi: Vec3, prefix: String) -> CSGSolid {
        var faces: [CSGFace] = []
        var polys: [CSGSolid.Polygon] = []
        func quad(_ name: String, _ v: [Vec3], _ n: Vec3) {
            faces.append(CSGFace(id: FaceID(rawValue: prefix + "/" + name), surface: .plane(origin: v[0], normal: n), flipped: false))
            polys.append(CSGSolid.Polygon(vertices: v, face: faces.count - 1))
        }
        let (a, b) = (lo, hi)
        quad("bottom", [Vec3(a.x, a.y, a.z), Vec3(a.x, b.y, a.z), Vec3(b.x, b.y, a.z), Vec3(b.x, a.y, a.z)], Vec3(0, 0, -1))
        quad("top", [Vec3(a.x, a.y, b.z), Vec3(b.x, a.y, b.z), Vec3(b.x, b.y, b.z), Vec3(a.x, b.y, b.z)], Vec3(0, 0, 1))
        quad("side-front", [Vec3(a.x, a.y, a.z), Vec3(b.x, a.y, a.z), Vec3(b.x, a.y, b.z), Vec3(a.x, a.y, b.z)], Vec3(0, -1, 0))
        quad("side-back", [Vec3(a.x, b.y, a.z), Vec3(a.x, b.y, b.z), Vec3(b.x, b.y, b.z), Vec3(b.x, b.y, a.z)], Vec3(0, 1, 0))
        quad("side-left", [Vec3(a.x, a.y, a.z), Vec3(a.x, a.y, b.z), Vec3(a.x, b.y, b.z), Vec3(a.x, b.y, a.z)], Vec3(-1, 0, 0))
        quad("side-right", [Vec3(b.x, a.y, a.z), Vec3(b.x, b.y, a.z), Vec3(b.x, b.y, b.z), Vec3(b.x, a.y, b.z)], Vec3(1, 0, 0))
        return CSGSolid(polygons: polys, faces: faces)
    }

    /// Bend + straight flange swept along a side. Section in (u outward from the tangent line,
    /// w up); a downward bend is the upward one mirrored about the plate's mid-plane.
    private static func flange(_ f: SheetFlange, theta: Double, straight: Double, r: Double, t: Double,
                               origin: Vec3, out: Vec3, along: Vec3, span: Double, prefix: String,
                               straightOnly: Bool = false, up upVector: Vec3 = Vec3(0, 0, 1)) -> CSGSolid {
        let up = f.direction == .up
        let n = max(2, Int((Double(bendSegments) * theta / (.pi / 2)).rounded(.up)))
        func mirror(_ p: Vec2) -> Vec2 { up ? p : Vec2(p.x, t - p.y) }
        let centre = Vec2(0, r + t)
        func arc(_ radius: Double, _ phi: Double) -> Vec2 { mirror(Vec2(radius * sin(phi), centre.y - radius * cos(phi))) }
        let outer = (0...n).map { arc(r + t, theta * Double($0) / Double(n)) }
        let inner = (0...n).map { arc(r, theta * Double($0) / Double(n)) }
        let d = up ? Vec2(cos(theta), sin(theta)) : Vec2(cos(theta), -sin(theta))
        let outerTip = Vec2(outer[n].x + d.x * straight, outer[n].y + d.y * straight)
        let innerTip = Vec2(inner[n].x + d.x * straight, inner[n].y + d.y * straight)
        let z = upVector
        func world(_ p: Vec2, _ s: Double) -> Vec3 { origin + out * p.x + z * p.y + along * s }
        let axis = world(mirror(centre), 0)

        var faces: [CSGFace] = []
        func face(_ name: String, _ surface: SurfaceDescriptor, flipped: Bool = false) -> Int {
            faces.append(CSGFace(id: FaceID(rawValue: prefix + "/" + name), surface: surface, flipped: flipped)); return faces.count - 1
        }
        let bendOut = straightOnly ? -1 : face("bend-out", .cylinder(axisOrigin: axis, axisDirection: along, radius: r + t))
        let bendIn = straightOnly ? -1 : face("bend-in", .cylinder(axisOrigin: axis, axisDirection: along, radius: r), flipped: true)
        func plane(_ name: String, _ a: Vec2, _ b: Vec2) -> Int {
            let pa = world(a, 0), pb = world(b, 0)
            return face(name, .plane(origin: pa, normal: (pb - pa).cross(along).normalized))
        }
        // Section outline, counter-clockwise in (u, w) for an up bend: outer arc, tip, inner arc back, joint.
        // `straightOnly`: just the straight wall (a closed corner's run-on), closed at the bend end.
        var loop: [(Vec2, Int)] = []
        if !straightOnly { for i in 0..<n { loop.append((outer[i], bendOut)) } }
        loop.append((outer[n], plane("flange-out", outer[n], outerTip)))
        loop.append((outerTip, plane("tip", outerTip, innerTip)))
        loop.append((innerTip, plane("flange-in", innerTip, inner[n])))
        if straightOnly {
            loop.append((inner[n], plane("foot", inner[n], outer[n])))
        } else {
            for i in stride(from: n, to: 0, by: -1) { loop.append((inner[i], bendIn)) }
            loop.append((inner[0], plane("joint", inner[0], outer[0])))
        }

        var polys: [CSGSolid.Polygon] = []
        for k in loop.indices {
            let (a, f) = loop[k], b = loop[(k + 1) % loop.count].0
            polys.append(CSGSolid.Polygon(vertices: [world(a, 0), world(b, 0), world(b, span), world(a, span)], face: f))
        }
        // End caps: convex quads between the arcs, plus the straight part.
        let capA = face("end-a", .plane(origin: origin, normal: -along))
        let capB = face("end-b", .plane(origin: origin + along * span, normal: along))
        var quads: [[Vec2]] = straightOnly ? [] : (0..<n).map { [outer[$0], outer[$0 + 1], inner[$0 + 1], inner[$0]] }
        quads.append([outer[n], outerTip, innerTip, inner[n]])
        for q in quads {
            // Same winding rule as the sides: the start cap runs against the section loop.
            polys.append(CSGSolid.Polygon(vertices: q.reversed().map { world($0, 0) }, face: capA))
            polys.append(CSGSolid.Polygon(vertices: q.map { world($0, span) }, face: capB))
        }
        return oriented(polys, faces)
    }

    /// A flange's tip in its section (u outward, w up): the outer and inner faces' ends, the
    /// straight part's direction and the unit normal of its inner face.
    static func flangeTip(_ f: SheetFlange, theta: Double, straight: Double, r: Double, t: Double) -> (outer: Vec2, innerFace: Vec2, d: Vec2, inner: Vec2) {
        let up = f.direction == .up
        func mirror(_ p: Vec2) -> Vec2 { up ? p : Vec2(p.x, t - p.y) }
        let d = up ? Vec2(cos(theta), sin(theta)) : Vec2(cos(theta), -sin(theta))
        let o = mirror(Vec2((r + t) * sin(theta), r + t - (r + t) * cos(theta))) + d * straight
        let i = mirror(Vec2(r * sin(theta), r + t - r * cos(theta))) + d * straight
        let n = up ? Vec2(-sin(theta), cos(theta)) : Vec2(-sin(theta), -cos(theta))
        return (o, i, d, n)
    }

    /// Consistent outward winding (the side-quad loop direction depends on up/down and side).
    private static func oriented(_ polys: [CSGSolid.Polygon], _ faces: [CSGFace]) -> CSGSolid {
        var volume = 0.0
        let o = polys.first?.vertices.first ?? .zero
        for p in polys {
            for k in 1..<(p.vertices.count - 1) {
                volume += (p.vertices[0] - o).dot((p.vertices[k] - o).cross(p.vertices[k + 1] - o))
            }
        }
        let out = volume >= 0 ? polys : polys.map { $0.flipped(faceMap: { $0 }) }
        // Plane descriptors take the real outward normal of their polygons.
        var fixed = faces
        for (i, f) in faces.enumerated() {
            guard case .plane = f.surface, let p = out.first(where: { $0.face == i }) else { continue }
            fixed[i].surface = .plane(origin: p.vertices[0], normal: p.normal)
        }
        return CSGSolid(polygons: out, faces: fixed)
    }

    /// `outline` minus `cut` as one outline, when the cut takes a bite out of its edge (nil when
    /// it splits the blank or leaves it unchanged).
    static func subtract(_ cut: [Vec2], from outline: [Vec2]) -> [Vec2]? {
        let curves: [(points: [Vec2], closed: Bool)] = [(outline, true), (cut, true)]
        let kept = SketchArrangement.faces(curves).filter { SketchArrangement.inside($0.seed, outline) && !SketchArrangement.inside($0.seed, cut) }
        let merged = SketchArrangement.merged([], seeds: kept.map(\.seed), curves: curves)
        guard merged.count == 1, merged[0].holes.isEmpty,
              abs(Profile2D(points: merged[0].outline).area.magnitude - Profile2D(points: outline).area.magnitude) > 1e-9 else { return nil }
        let result = simplified(merged[0].outline)
        return Profile2D(points: result).area < 0 ? result.reversed() : result
    }

    /// Drops repeated and collinear points (sides without a flange).
    private static func simplified(_ pts: [Vec2]) -> [Vec2] {
        var p: [Vec2] = []
        for v in pts where p.last.map({ ($0 - v).x != 0 || ($0 - v).y != 0 }) ?? true { p.append(v) }
        if let f = p.first, let l = p.last, f == l { p.removeLast() }
        var changed = true
        while changed, p.count > 3 {
            changed = false
            for i in p.indices {
                let a = p[(i + p.count - 1) % p.count], b = p[i], c = p[(i + 1) % p.count]
                if abs((b - a).cross(c - b)) < 1e-12 { p.remove(at: i); changed = true; break }
            }
        }
        return p
    }

    static func fmt(_ v: Double) -> String {
        var s = String(format: "%.2f", v)
        while s.hasSuffix("0") { s.removeLast() }
        if s.hasSuffix(".") { s.removeLast() }
        return s.replacingOccurrences(of: ".", with: ",")
    }
}

/// ASCII DXF (AC1015, mm) of a flat pattern: closed CUT outline, bend lines on BEND_UP /
/// BEND_DOWN, tangent lines on BEND_TANGENT, rule and bend data as comments.
public enum SheetMetalDXF {
    public static func export(_ flat: SheetFlatPattern, rule: SheetBendRule, name: String) -> String {
        var records: [String] = []
        func put(_ code: Int, _ value: String) { records += [String(code), value] }
        func number(_ value: Double) -> String {
            value == 0 ? "0" : String(format: "%.12g", locale: Locale(identifier: "en_US_POSIX"), value)
        }
        put(999, "CAD Takeoff flat pattern: \(name)")
        put(999, "Material \(rule.material.name), t=\(number(rule.thickness)) mm, Ri=\(number(rule.insideRadius)) mm, K=\(number(rule.kFactor)), V\(number(rule.vDie))")
        put(0, "SECTION"); put(2, "HEADER")
        put(9, "$ACADVER"); put(1, "AC1015")
        put(9, "$INSUNITS"); put(70, "4")
        put(9, "$MEASUREMENT"); put(70, "1")
        put(0, "ENDSEC")
        put(0, "SECTION"); put(2, "TABLES")
        put(0, "TABLE"); put(2, "LTYPE"); put(70, "1")
        put(0, "LTYPE"); put(100, "AcDbSymbolTableRecord"); put(100, "AcDbLinetypeTableRecord")
        put(2, "CONTINUOUS"); put(70, "0"); put(3, "Solid line"); put(72, "65"); put(73, "0"); put(40, "0")
        put(0, "ENDTAB")
        let layers = [("0", 7), ("CUT", 7), ("BEND_UP", 1), ("BEND_DOWN", 5), ("BEND_TANGENT", 8)]
        put(0, "TABLE"); put(2, "LAYER"); put(70, String(layers.count))
        for (layer, color) in layers {
            put(0, "LAYER"); put(100, "AcDbSymbolTableRecord"); put(100, "AcDbLayerTableRecord")
            put(2, layer); put(70, "0"); put(62, String(color)); put(6, "CONTINUOUS")
        }
        put(0, "ENDTAB"); put(0, "ENDSEC")
        put(0, "SECTION"); put(2, "ENTITIES")
        put(0, "LWPOLYLINE"); put(100, "AcDbEntity"); put(8, "CUT"); put(100, "AcDbPolyline")
        put(90, String(flat.outline.count)); put(70, "1")
        for p in flat.outline { put(10, number(p.x)); put(20, number(p.y)) }
        func line(_ l: (Vec2, Vec2), _ layer: String) {
            put(0, "LINE"); put(100, "AcDbEntity"); put(8, layer); put(100, "AcDbLine")
            put(10, number(l.0.x)); put(20, number(l.0.y)); put(30, "0")
            put(11, number(l.1.x)); put(21, number(l.1.y)); put(31, "0")
        }
        for c in flat.cutouts {
            put(0, "LWPOLYLINE"); put(100, "AcDbEntity"); put(8, "CUT"); put(100, "AcDbPolyline")
            put(90, String(c.count)); put(70, "1")
            for p in c { put(10, number(p.x)); put(20, number(p.y)) }
        }
        for h in flat.holes {
            put(0, "CIRCLE"); put(100, "AcDbEntity"); put(8, "CUT"); put(100, "AcDbCircle")
            put(10, number(h.center.x)); put(20, number(h.center.y)); put(30, "0"); put(40, number(h.diameter / 2))
        }
        for b in flat.bends {
            put(999, "Bend \(b.edge?.rawValue ?? "side\(b.side ?? 0)") \(b.direction.rawValue) angle_deg=\(number(b.angle)) inside_radius_mm=\(number(b.insideRadius))")
            line(b.line, b.direction == .up ? "BEND_UP" : "BEND_DOWN")
            for tl in b.tangents { line(tl, "BEND_TANGENT") }
        }
        put(0, "ENDSEC"); put(0, "EOF")
        return records.joined(separator: "\n") + "\n"
    }
}
