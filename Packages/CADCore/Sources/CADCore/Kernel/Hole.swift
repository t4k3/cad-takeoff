import Foundation

// Hole feature (3b, T83): simple, counterbored or countersunk holes, sized manually or from
// metric screw tables for 3D printing (clearance, tap drill, heat-set insert, modelled thread).
// Always subtracts from the bodies it touches.

/// Metric coarse screw data used by the hole presets. Heat-set insert holes are typical
/// values: the insert maker's datasheet wins.
public struct MetricScrew: Sendable, Equatable {
    public let name: String
    public let diameter: Double
    public let pitch: Double
    public let tapDrill: Double
    public let clearance: Double
    public let heatInsert: Double
    /// Socket head cap screw (ISO 4762) counterbore.
    public let counterboreDiameter: Double
    public let counterboreDepth: Double
    /// Flat head (ISO 10642, 90°) countersink.
    public let countersinkDiameter: Double

    public static let all: [MetricScrew] = [
        .init(name: "M2", diameter: 2, pitch: 0.4, tapDrill: 1.6, clearance: 2.4, heatInsert: 3.2, counterboreDiameter: 4.4, counterboreDepth: 2.2, countersinkDiameter: 4.4),
        .init(name: "M2.5", diameter: 2.5, pitch: 0.45, tapDrill: 2.05, clearance: 2.9, heatInsert: 3.6, counterboreDiameter: 5.5, counterboreDepth: 2.7, countersinkDiameter: 5.5),
        .init(name: "M3", diameter: 3, pitch: 0.5, tapDrill: 2.5, clearance: 3.4, heatInsert: 4.0, counterboreDiameter: 6.5, counterboreDepth: 3.3, countersinkDiameter: 6.72),
        .init(name: "M4", diameter: 4, pitch: 0.7, tapDrill: 3.3, clearance: 4.5, heatInsert: 5.6, counterboreDiameter: 8.0, counterboreDepth: 4.4, countersinkDiameter: 8.96),
        .init(name: "M5", diameter: 5, pitch: 0.8, tapDrill: 4.2, clearance: 5.5, heatInsert: 6.4, counterboreDiameter: 10.0, counterboreDepth: 5.4, countersinkDiameter: 11.2),
        .init(name: "M6", diameter: 6, pitch: 1.0, tapDrill: 5.0, clearance: 6.6, heatInsert: 8.0, counterboreDiameter: 11.0, counterboreDepth: 6.5, countersinkDiameter: 13.44),
        .init(name: "M8", diameter: 8, pitch: 1.25, tapDrill: 6.8, clearance: 9.0, heatInsert: 9.7, counterboreDiameter: 15.0, counterboreDepth: 8.6, countersinkDiameter: 17.92),
        .init(name: "M10", diameter: 10, pitch: 1.5, tapDrill: 8.5, clearance: 11.0, heatInsert: 12.0, counterboreDiameter: 18.0, counterboreDepth: 10.8, countersinkDiameter: 22.4),
        .init(name: "M12", diameter: 12, pitch: 1.75, tapDrill: 10.2, clearance: 13.5, heatInsert: 14.4, counterboreDiameter: 20.0, counterboreDepth: 13.0, countersinkDiameter: 26.88),
    ]

    public static func named(_ n: String?) -> MetricScrew? { all.first { $0.name == n } }
}

public struct HoleSpec: Codable, Sendable, Equatable {
    public enum Style: String, Codable, Sendable, CaseIterable {
        case simple, counterbore, countersink
        public var label: String {
            switch self { case .simple: "Semplice"; case .counterbore: "Lamato"; case .countersink: "Svasato" }
        }
    }

    /// What the hole is for; decides the diameter from the screw table.
    public enum Fit: String, Codable, Sendable, CaseIterable {
        case manual, clearance, tapped, heatInsert, modeledThread
        public var label: String {
            switch self {
            case .manual: "Diametro libero"
            case .clearance: "Passaggio vite"
            case .tapped: "Filettatura indicata (preforo)"
            case .heatInsert: "Inserto a caldo"
            case .modeledThread: "Filetto modellato"
            }
        }
    }

    /// Hole centres on the start face, world mm.
    public var centers: [Vec3]
    /// Unit direction into the material.
    public var direction: Vec3
    public var style: Style
    public var fit: Fit
    /// Screw size ("M4") for every fit except manual.
    public var size: String?
    /// Diameter for `manual` (mm).
    public var diameter: Double
    /// Depth from the start face; nil = through all.
    public var depth: Double?
    /// 0 = from the screw table (counterbore/countersink diameter).
    public var headDiameter: Double
    /// 0 = from the screw table.
    public var counterboreDepth: Double
    public var countersinkAngle: Double
    /// Added to every diameter to compensate printer shrinkage/over-extrusion (mm).
    public var printAllowance: Double

    public init(centers: [Vec3], direction: Vec3 = Vec3(0, 0, -1), style: Style = .simple, fit: Fit = .clearance,
                size: String? = "M3", diameter: Double = 3, depth: Double? = nil, headDiameter: Double = 0,
                counterboreDepth: Double = 0, countersinkAngle: Double = 90, printAllowance: Double = 0) {
        self.centers = centers; self.direction = direction; self.style = style; self.fit = fit; self.size = size
        self.diameter = diameter; self.depth = depth; self.headDiameter = headDiameter
        self.counterboreDepth = counterboreDepth; self.countersinkAngle = countersinkAngle; self.printAllowance = printAllowance
    }

    public var screw: MetricScrew? { fit == .manual ? nil : MetricScrew.named(size) }

    /// Bore diameter actually cut (mm).
    public var boreDiameter: Double {
        let base: Double = switch (fit, screw) {
        case let (.clearance, s?): s.clearance
        case let (.tapped, s?): s.tapDrill
        case let (.heatInsert, s?): s.heatInsert
        case let (.modeledThread, s?): s.diameter - 1.0825 * s.pitch   // internal thread minor diameter
        default: diameter
        }
        return base + printAllowance
    }

    public var resolvedHeadDiameter: Double {
        if headDiameter > 0 { return headDiameter + printAllowance }
        switch style {
        case .simple: return boreDiameter
        case .counterbore: return (screw?.counterboreDiameter ?? boreDiameter * 1.8) + printAllowance
        case .countersink: return (screw?.countersinkDiameter ?? boreDiameter * 2) + printAllowance
        }
    }

    public var resolvedCounterboreDepth: Double {
        counterboreDepth > 0 ? counterboreDepth : (screw?.counterboreDepth ?? boreDiameter)
    }

    /// Short description for the UI ("M4 lamato passante").
    public var summary: String {
        let name = screw.map { $0.name + " " } ?? "Ø\(fmt(boreDiameter)) "
        let kind: String = switch fit {
        case .tapped: "filettato"
        case .heatInsert: "per inserto"
        case .modeledThread: "filetto modellato"
        default: ""
        }
        let st = style == .simple ? "" : style.label.lowercased() + " "
        let dp = depth.map { "prof. \(fmt($0))" } ?? "passante"
        return (name + st + kind + " " + dp).replacingOccurrences(of: "  ", with: " ") + (centers.count > 1 ? " ×\(centers.count)" : "")
    }

    public func validate() throws {
        guard (1...200).contains(centers.count) else { throw KernelError.invalidParameter("foro: da 1 a 200 centri") }
        guard direction.length > 0.5 else { throw KernelError.invalidParameter("foro: direzione non valida") }
        guard boreDiameter > 0.05, boreDiameter < 1000 else { throw KernelError.invalidParameter("foro: diametro non valido") }
        if let depth { guard depth > 0.01, depth < 100_000 else { throw KernelError.invalidParameter("foro: profondità non valida") } }
        guard fit == .manual || screw != nil else { throw KernelError.invalidParameter("foro: misura vite sconosciuta") }
        guard resolvedHeadDiameter >= boreDiameter else { throw KernelError.invalidParameter("foro: la testa deve essere più larga del foro") }
        guard (30...150).contains(countersinkAngle) else { throw KernelError.invalidParameter("foro: angolo svasatura 30–150°") }
        for (i, a) in centers.enumerated() where centers[..<i].contains(where: { ($0 - a).length < 1e-3 }) {
            throw KernelError.invalidParameter("foro: centro \(i + 1) ripetuto")
        }
        guard fit != .modeledThread else {
            throw KernelError.invalidParameter("filetto modellato non ancora disponibile: usa «Filettatura indicata» (preforo per maschio) o «Inserto a caldo»")
        }
    }

    private func fmt(_ v: Double) -> String { String(format: v == v.rounded() ? "%.0f" : "%.2f", v) }
}

/// Builds the solid removed by a hole (one per centre), with named faces.
public enum HoleGeometry {
    static let segments = 64
    static let threadSegments = 36
    static let ringsPerPitch = 6
    /// The tool starts slightly outside the face so the cut is clean (no coplanar sliver).
    static let lead = 0.5

    /// - Parameter throughDepth: depth used when `spec.depth` is nil (through all).
    public static func solid(_ spec: HoleSpec, featureID: UUID, throughDepth: Double) -> CSGSolid {
        var polygons: [CSGSolid.Polygon] = []
        var faces: [CSGFace] = []
        for (i, c) in spec.centers.enumerated() {
            append(spec, center: c, index: i, featureID: featureID, throughDepth: throughDepth, into: &polygons, faces: &faces)
        }
        return CSGSolid(polygons: polygons, faces: faces)
    }

    /// Preview/export mesh of the removed volume (depth 10 mm when through).
    public static func mesh(_ spec: HoleSpec, featureID: UUID) -> Mesh {
        solid(spec, featureID: featureID, throughDepth: spec.depth ?? 10).triangulated().mesh
    }

    private struct Ring {
        var z: Double
        var radius: (Double) -> Double       // angle → radius
        var constant: Double?                // set when the ring is circular
    }

    private static func append(_ spec: HoleSpec, center: Vec3, index: Int, featureID: UUID, throughDepth: Double,
                               into polygons: inout [CSGSolid.Polygon], faces: inout [CSGFace]) {
        let axis = spec.direction.normalized
        let helper = abs(axis.z) < 0.9 ? Vec3(0, 0, 1) : Vec3(1, 0, 0)
        let u = helper.cross(axis).normalized, v = axis.cross(u)
        let depth = spec.depth ?? throughDepth
        let rb = spec.boreDiameter / 2, rh = spec.resolvedHeadDiameter / 2
        let prefix = "hole:\(featureID.uuidString)/\(index)"

        // Profile rings along the axis (z = distance into the material).
        var rings: [Ring] = []
        func circle(_ z: Double, _ r: Double) -> Ring { Ring(z: z, radius: { _ in r }, constant: r) }
        var boreStart = 0.0
        switch spec.style {
        case .simple:
            rings = [circle(-lead, rb)]
        case .counterbore:
            let cb = min(spec.resolvedCounterboreDepth, depth * 0.95)
            rings = [circle(-lead, rh), circle(cb, rh), circle(cb, rb)]
            boreStart = cb
        case .countersink:
            let slope = tan(spec.countersinkAngle * .pi / 360)
            let cs = min((rh - rb) / slope, depth * 0.95)
            // The cone continues above the face so no ring lies exactly on the face plane
            // (exactly coplanar vertices are the worst case for the BSP split).
            rings = [circle(-lead, rh + lead * slope), circle(cs, rb)]
            boreStart = cs
        }
        if spec.fit == .modeledThread, let s = spec.screw {
            // ISO 60° internal thread: the removed "screw" has crests at the major radius
            // and roots at the minor radius (the bore).
            let rMaj = s.diameter / 2 + spec.printAllowance / 2
            let pitch = s.pitch
            let steps = max(2, Int(((depth - boreStart) / pitch * Double(ringsPerPitch)).rounded(.up)))
            for k in 0...steps {
                let z = boreStart + (depth - boreStart) * Double(k) / Double(steps)
                rings.append(Ring(z: z, radius: { theta in
                    var t = (z / pitch - theta / (2 * .pi)).truncatingRemainder(dividingBy: 1)
                    if t < 0 { t += 1 }
                    let tooth = min(1, max(0, (1 - abs(2 * t - 1)) * 1.25 - 0.125))   // flattened triangle
                    return rb + (rMaj - rb) * tooth
                }, constant: nil))
            }
        } else {
            rings.append(circle(depth, rb))
        }

        let n = rings.contains { $0.constant == nil } ? threadSegments : segments
        func point(_ ring: Ring, _ k: Int) -> Vec3 {
            let theta = Double(k) / Double(n) * 2 * .pi
            let r = ring.radius(theta)
            return center + axis * ring.z + (u * cos(theta) + v * sin(theta)) * r
        }
        func face(_ id: String, _ surface: SurfaceDescriptor) -> Int {
            faces.append(CSGFace(id: FaceID(rawValue: prefix + "/" + id), surface: surface, flipped: false))
            return faces.count - 1
        }

        // Caps (outward normals: -axis at the top, +axis at the bottom).
        let top = rings[0], bottom = rings[rings.count - 1]
        let topFace = face("top", .plane(origin: center + axis * top.z, normal: -axis))
        let bottomFace = face("bottom", .plane(origin: center + axis * bottom.z, normal: axis))
        let topCentre = center + axis * top.z, bottomCentre = center + axis * bottom.z
        for k in 0..<n {
            add([topCentre, point(top, (k + 1) % n), point(top, k)], topFace, &polygons)
            add([bottomCentre, point(bottom, k), point(bottom, (k + 1) % n)], bottomFace, &polygons)
        }

        // Bands between consecutive rings.
        var threadFace: Int?
        for b in 0..<(rings.count - 1) {
            let r0 = rings[b], r1 = rings[b + 1]
            let f: Int
            if let c0 = r0.constant, let c1 = r1.constant {
                if abs(r0.z - r1.z) < 1e-12 {
                    f = face("step\(b)", .plane(origin: center + axis * r0.z, normal: c1 < c0 ? axis : -axis))
                } else if abs(c0 - c1) < 1e-12 {
                    f = face(b == rings.count - 2 && spec.style != .simple || spec.style == .simple ? "bore" : "head",
                             .cylinder(axisOrigin: center, axisDirection: axis, radius: c0))
                } else {
                    // Cone: apex where the radius reaches zero.
                    let slope = (c1 - c0) / (r1.z - r0.z)
                    let apexZ = r0.z - c0 / slope
                    f = face("countersink", .cone(apex: center + axis * apexZ, axisDirection: slope < 0 ? -axis : axis,
                                                  halfAngle: atan(abs(slope))))
                }
            } else {
                if threadFace == nil {
                    threadFace = face("thread", .cylinder(axisOrigin: center, axisDirection: axis,
                                                          radius: (spec.screw?.diameter ?? spec.boreDiameter) / 2))
                }
                f = threadFace!
            }
            for k in 0..<n {
                let k1 = (k + 1) % n
                let a = point(r0, k), b1 = point(r0, k1), c = point(r1, k1), d = point(r1, k)
                add([a, b1, c], f, &polygons)
                add([a, c, d], f, &polygons)
            }
        }
    }

    private static func add(_ v: [Vec3], _ face: Int, _ polygons: inout [CSGSolid.Polygon]) {
        guard (v[1] - v[0]).cross(v[2] - v[0]).length > 1e-12 else { return }
        polygons.append(CSGSolid.Polygon(vertices: v, face: face))
    }
}
