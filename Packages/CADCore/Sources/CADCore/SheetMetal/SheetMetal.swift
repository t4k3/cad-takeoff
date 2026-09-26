import Foundation

// Sheet-metal part (T79): a base plate with flanges on any of its four sides, bent with the
// material's press-brake rule. A feature of the timeline like the solids: folded body for the
// design, flat pattern (developed blank with bend lines) for cutting and the DXF.
//
// Dimensions are workshop style: width/depth are the OUTSIDE footprint (mould lines), flange
// lengths are outside/inside/tangent lengths. Corners between flanges are open (each flange spans
// the flat part of its side), so the blank never overlaps itself; closed corners come later.

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

public struct SheetFlange: Codable, Equatable, Sendable {
    public var length: Double
    /// Degrees from flat (90 = right angle), 5–135.
    public var angle: Double
    public var direction: SheetBendDirection
    public var reference: SheetFlangeReference

    public init(length: Double, angle: Double = 90, direction: SheetBendDirection = .up, reference: SheetFlangeReference = .outside) {
        self.length = length; self.angle = angle; self.direction = direction; self.reference = reference
    }
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

    public init(material: String = "dc01", thickness: Double = 1.5, width: Double = 80, depth: Double = 50,
                flanges: [SheetEdge: SheetFlange] = [:], radiusOverride: Double? = nil, kOverride: Double? = nil) {
        self.material = material; self.thickness = thickness; self.width = width; self.depth = depth
        self.radiusOverride = radiusOverride; self.kOverride = kOverride
        for (e, f) in flanges { self[e] = f }
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
        let count = SheetEdge.allCases.filter { self[$0] != nil }.count
        let t = thickness == thickness.rounded() ? String(format: "%.0f", thickness) : String(format: "%g", thickness)
        let short = SheetMaterial.named(material)?.name.components(separatedBy: " (").first ?? material
        return "\(short) \(t) mm" + (count == 0 ? "" : " · \(count) fless\(count == 1 ? "a" : "e")")
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
        public let edge: SheetEdge
        /// Bend (centre) line and the two tangent lines where the bend zone starts and ends.
        public let line: (Vec2, Vec2)
        public let tangents: [(Vec2, Vec2)]
        public let angle: Double
        public let direction: SheetBendDirection
        public let insideRadius: Double

        public static func == (a: Bend, b: Bend) -> Bool {
            a.edge == b.edge && a.line.0 == b.line.0 && a.line.1 == b.line.1 && a.angle == b.angle
                && a.direction == b.direction && a.insideRadius == b.insideRadius
        }
    }

    /// Counter-clockwise outline (closed, first point not repeated).
    public let outline: [Vec2]
    public let bends: [Bend]
    public let thickness: Double
    /// Offset of the part (the feature position): the flat pattern lies at the plate.
    public let origin: Vec3

    public var area: Double { Profile2D(points: outline).area }
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
}

public enum SheetMetalGeometry {
    static let bendSegments = 16

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

        // Per flange: straight length, bend allowance and outside setback from the mould line.
        struct Bent { let edge: SheetEdge; let flange: SheetFlange; let theta: Double; let straight: Double; let allowance: Double; let setback: Double }
        var bent: [SheetEdge: Bent] = [:]
        for edge in SheetEdge.allCases {
            guard let f = spec[edge] else { continue }
            guard f.angle.isFinite, (5...135).contains(f.angle) else {
                throw SheetMetalError.invalidParameter("\(edge.label.lowercased()): angolo 5–135° dalla posizione piana")
            }
            guard f.length.isFinite, (0.1...10_000).contains(f.length) else {
                throw SheetMetalError.invalidParameter("\(edge.label.lowercased()): lunghezza flangia 0,1–10000 mm")
            }
            let theta = f.angle * .pi / 180
            let outer = tan(theta / 2) * (r + t), inner = tan(theta / 2) * r
            let straight: Double
            switch f.reference {
            case .outside: straight = f.length - outer
            case .inside: straight = f.length - inner
            case .tangent: straight = f.length
            }
            guard straight >= 0.05 else {
                let min = f.reference == .outside ? outer : inner
                throw SheetMetalError.invalidParameter("flangia \(edge.label.lowercased()) troppo corta: con raggio \(fmt(r)) e spessore \(fmt(t)) serve più di \(fmt(min)) mm")
            }
            // Workshop minimum, compared as an outside length.
            let outsideLength = straight + outer
            if outsideLength < rule.minimumFlange - 1e-9 {
                warnings.append("Flangia \(edge.label.lowercased()) \(fmt(outsideLength)) mm (esterna): sotto il minimo piegabile ≈ \(fmt(rule.minimumFlange)) mm con matrice V\(fmt(rule.vDie))")
            }
            bent[edge] = Bent(edge: edge, flange: f, theta: theta, straight: straight,
                              allowance: rule.allowance(angleDegrees: f.angle), setback: outer)
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
        }

        // Flat pattern: plate plus one strip per flange (allowance + straight), cross-shaped.
        let reach: [SheetEdge: Double] = bent.mapValues { $0.allowance + $0.straight }
        let lf = reach[.front] ?? 0, lr = reach[.right] ?? 0, lb = reach[.back] ?? 0, ll = reach[.left] ?? 0
        let raw = [Vec2(x0, y0 - lf), Vec2(x1, y0 - lf), Vec2(x1, y0), Vec2(x1 + lr, y0), Vec2(x1 + lr, y1), Vec2(x1, y1),
                   Vec2(x1, y1 + lb), Vec2(x0, y1 + lb), Vec2(x0, y1), Vec2(x0 - ll, y1), Vec2(x0 - ll, y0), Vec2(x0, y0)]
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
        }
        let flat = SheetFlatPattern(outline: simplified(raw), bends: bends, thickness: t, origin: position)
        return SheetMetalBuild(rule: rule, folded: solid, flat: flat, warnings: warnings)
    }

    /// Flat pattern as a thin solid (for display and 3MF), at the plate's height.
    public static func flatMesh(_ flat: SheetFlatPattern) -> Mesh {
        Operations.extrude(Profile2D(points: flat.outline), height: flat.thickness).translated(by: flat.origin)
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
                               origin: Vec3, out: Vec3, along: Vec3, span: Double, prefix: String) -> CSGSolid {
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
        let z = Vec3(0, 0, 1)
        func world(_ p: Vec2, _ s: Double) -> Vec3 { origin + out * p.x + z * p.y + along * s }
        let axis = world(mirror(centre), 0)

        var faces: [CSGFace] = []
        func face(_ name: String, _ surface: SurfaceDescriptor, flipped: Bool = false) -> Int {
            faces.append(CSGFace(id: FaceID(rawValue: prefix + "/" + name), surface: surface, flipped: flipped)); return faces.count - 1
        }
        let bendOut = face("bend-out", .cylinder(axisOrigin: axis, axisDirection: along, radius: r + t))
        let bendIn = face("bend-in", .cylinder(axisOrigin: axis, axisDirection: along, radius: r), flipped: true)
        func plane(_ name: String, _ a: Vec2, _ b: Vec2) -> Int {
            let pa = world(a, 0), pb = world(b, 0)
            return face(name, .plane(origin: pa, normal: (pb - pa).cross(along).normalized))
        }
        // Section outline, counter-clockwise in (u, w) for an up bend: outer arc, tip, inner arc back, joint.
        var loop: [(Vec2, Int)] = []
        for i in 0..<n { loop.append((outer[i], bendOut)) }
        loop.append((outer[n], plane("flange-out", outer[n], outerTip)))
        loop.append((outerTip, plane("tip", outerTip, innerTip)))
        loop.append((innerTip, plane("flange-in", innerTip, inner[n])))
        for i in stride(from: n, to: 0, by: -1) { loop.append((inner[i], bendIn)) }
        loop.append((inner[0], plane("joint", inner[0], outer[0])))

        var polys: [CSGSolid.Polygon] = []
        for k in loop.indices {
            let (a, f) = loop[k], b = loop[(k + 1) % loop.count].0
            polys.append(CSGSolid.Polygon(vertices: [world(a, 0), world(b, 0), world(b, span), world(a, span)], face: f))
        }
        // End caps: convex quads between the arcs, plus the straight part.
        let capA = face("end-a", .plane(origin: origin, normal: -along))
        let capB = face("end-b", .plane(origin: origin + along * span, normal: along))
        var quads: [[Vec2]] = (0..<n).map { [outer[$0], outer[$0 + 1], inner[$0 + 1], inner[$0]] }
        quads.append([outer[n], outerTip, innerTip, inner[n]])
        for q in quads {
            // Same winding rule as the sides: the start cap runs against the section loop.
            polys.append(CSGSolid.Polygon(vertices: q.reversed().map { world($0, 0) }, face: capA))
            polys.append(CSGSolid.Polygon(vertices: q.map { world($0, span) }, face: capB))
        }
        return oriented(polys, faces)
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
        put(999, "Fusion Takeoff flat pattern: \(name)")
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
        for b in flat.bends {
            put(999, "Bend \(b.edge.rawValue) \(b.direction.rawValue) angle_deg=\(number(b.angle)) inside_radius_mm=\(number(b.insideRadius))")
            line(b.line, b.direction == .up ? "BEND_UP" : "BEND_DOWN")
            for tl in b.tangents { line(tl, "BEND_TANGENT") }
        }
        put(0, "ENDSEC"); put(0, "EOF")
        return records.joined(separator: "\n") + "\n"
    }
}
