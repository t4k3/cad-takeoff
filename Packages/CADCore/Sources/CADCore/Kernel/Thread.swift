import Foundation

/// «Filetto» (Fusion's Thread, modelled): an ISO metric 60° thread cut on a cylindrical face —
/// outside on a shaft or boss (a screw), inside on a hole's wall (a nut) — over the face's
/// length, printable. The size follows the cylinder's diameter unless chosen.
public struct ThreadSpec: Codable, Sendable, Equatable {
    /// The cylindrical face (its ID survives re-evaluation).
    public var face: FaceID
    /// ISO size (M3…); nil: the one whose diameter matches the face.
    public var size: String?
    /// Added clearance for printing (mm on the diameter): an outside thread gets thinner, an
    /// inside one wider.
    public var printAllowance: Double

    public init(face: FaceID, size: String? = nil, printAllowance: Double = 0.2) {
        self.face = face; self.size = size; self.printAllowance = printAllowance
    }

    public func validate() throws {
        guard printAllowance.isFinite, (0...2).contains(printAllowance) else { throw KernelError.invalidParameter("filetto: compensazione tra 0 e 2 mm") }
        if let size { guard MetricScrew.named(size) != nil else { throw KernelError.invalidParameter("filetto: misura \(size) sconosciuta") } }
    }

    /// The ISO size for a cylinder of `diameter` (nominal for a shaft, minor for a hole).
    public static func size(forDiameter diameter: Double, inside: Bool) -> MetricScrew? {
        MetricScrew.all.min { a, b in
            abs((inside ? a.diameter - 1.0825 * a.pitch : a.diameter) - diameter) < abs((inside ? b.diameter - 1.0825 * b.pitch : b.diameter) - diameter)
        }
    }
}

enum ThreadGeometry {
    /// The solid removed from the body: between the thread profile and the air around it.
    static func tool(_ spec: ThreadSpec, snapshot: BodySnapshot, featureID: UUID) throws -> CSGSolid {
        try spec.validate()
        guard let f = snapshot.faces.firstIndex(where: { $0.id == spec.face }),
              case let .cylinder(origin, axis0, radius) = snapshot.faces[f].surface else {
            throw KernelError.invalidParameter("filetto: la faccia scelta non è cilindrica (o non esiste più)")
        }
        let axis = axis0.normalized
        // The face's extent along the axis, and whether the part is outside it (a hole).
        var lo = Double.infinity, hi = -Double.infinity
        var outward = 0.0
        for t in 0..<snapshot.triangleFace.count where Int(snapshot.triangleFace[t]) == f {
            let v = (0..<3).map { snapshot.positions[Int(snapshot.triangles[t * 3 + $0])] }
            for p in v { let z = (p - origin).dot(axis); lo = min(lo, z); hi = max(hi, z) }
            let c = (v[0] + v[1] + v[2]) * (1.0 / 3), n = (v[1] - v[0]).cross(v[2] - v[0])
            let radial = (c - origin) - axis * (c - origin).dot(axis)
            outward += n.dot(radial)
        }
        guard hi - lo > 1e-6 else { throw KernelError.invalidParameter("filetto: faccia troppo corta") }
        let inside = outward < 0    // normals toward the axis: the wall of a hole
        guard let screw = spec.size.flatMap(MetricScrew.named) ?? ThreadSpec.size(forDiameter: 2 * radius, inside: inside) else {
            throw KernelError.invalidParameter("filetto: nessuna misura ISO per questo diametro")
        }
        let pitch = screw.pitch, depthH = 0.541266 * pitch     // ISO: (D − D1) / 2
        // Crest and root radii: outside, crests at the nominal radius (less the allowance);
        // inside, roots at the nominal radius (more the allowance), crests at the bore.
        let rMajor = screw.diameter / 2 + (inside ? spec.printAllowance / 2 : -spec.printAllowance / 2)
        let rMinor = rMajor - depthH
        guard inside ? rMinor < rMajor : rMinor > 0.1 else { throw KernelError.invalidParameter("filetto: misura troppo piccola") }
        // Ends: past a free end the tool runs on (a clean thread end); against more material
        // (a shoulder, the bottom of a blind hole) it stops short of it.
        let helper = abs(axis.z) < 0.9 ? Vec3(0, 0, 1) : Vec3(1, 0, 0)
        let u = helper.cross(axis).normalized, v = axis.cross(u)
        let probeR = inside ? rMinor * 0.5 : (radius + rMinor) / 2
        func free(_ z: Double) -> Bool { !ChamferGeometry.contains(origin + axis * z + u * probeR, snapshot) }
        let run = 0.6 * pitch
        let z0 = free(lo - 0.05) ? lo - run : lo + 0.02, z1 = free(hi + 0.05) ? hi + run : hi - 0.02
        guard z1 > z0 + pitch else { throw KernelError.invalidParameter("filetto: faccia più corta di un passo") }

        // Radial height field: the thread's radius at angle θ and height z (60° flanks, flats
        // at crest P/8 and root P/4, sharpened a little for printing).
        func profile(_ theta: Double, _ z: Double) -> Double {
            var t = (z / pitch - theta / (2 * .pi)).truncatingRemainder(dividingBy: 1)
            if t < 0 { t += 1 }
            let tooth = min(1, max(0, (1 - abs(2 * t - 1)) * 1.25 - 0.125))
            // Outside: the tooth is material (crest out); inside: the tooth is the groove.
            return rMinor + (rMajor - rMinor) * tooth
        }
        let n = Tessellation.segments(48)
        let rows = max(4, Int(((z1 - z0) / pitch * 8).rounded(.up)))
        let other = inside ? 0.0 : rMajor + max(1, depthH * 2)    // the tool's other wall: axis or air
        func point(_ k: Int, _ j: Int) -> Vec3 {
            let theta = Double(k % n) / Double(n) * 2 * .pi, z = z0 + (z1 - z0) * Double(j) / Double(rows)
            return origin + axis * z + (u * cos(theta) + v * sin(theta)) * profile(theta, z)
        }
        func ring(_ k: Int, _ j: Int, _ r: Double) -> Vec3 {
            let theta = Double(k % n) / Double(n) * 2 * .pi, z = z0 + (z1 - z0) * Double(j) / Double(rows)
            return origin + axis * z + (u * cos(theta) + v * sin(theta)) * r
        }
        let prefix = "thread:\(featureID.uuidString)"
        var faces = [CSGFace(id: FaceID(rawValue: prefix), surface: .freeform, flipped: true),
                     CSGFace(id: FaceID(rawValue: prefix + "/end0"), surface: .plane(origin: origin + axis * z0, normal: -axis), flipped: false),
                     CSGFace(id: FaceID(rawValue: prefix + "/end1"), surface: .plane(origin: origin + axis * z1, normal: axis), flipped: false)]
        if !inside { faces.append(CSGFace(id: FaceID(rawValue: prefix + "/out"), surface: .cylinder(axisOrigin: origin, axisDirection: axis, radius: other), flipped: false)) }
        var polys: [CSGSolid.Polygon] = []
        /// A triangle facing out of the tool (`flip` when drawn the other way round).
        func add(_ p: [Vec3], _ face: Int, flip: Bool = false) {
            guard (p[1] - p[0]).cross(p[2] - p[0]).length > 1e-14 else { return }
            polys.append(CSGSolid.Polygon(vertices: flip ? [p[0], p[2], p[1]] : p, face: face))
        }
        // (u, v, axis) is right-handed: a quad drawn with θ then z faces away from the axis, a
        // cap triangle drawn outward then round faces +axis.
        // The thread surface: the outer wall of the core inside a hole, the inner wall of the
        // tube around a shaft (facing the axis).
        for j in 0..<rows {
            for k in 0..<n {
                let a = point(k, j), b = point(k + 1, j), c = point(k + 1, j + 1), d = point(k, j + 1)
                add([a, b, c], 0, flip: !inside); add([a, c, d], 0, flip: !inside)
            }
        }
        // The other wall (a cylinder in the air outside) and the two ends (−axis at z0).
        for k in 0..<n {
            if !inside {
                let a = ring(k, 0, other), b = ring(k + 1, 0, other), c = ring(k + 1, rows, other), d = ring(k, rows, other)
                add([a, b, c], 3); add([a, c, d], 3)
            }
            for (j, face) in [(0, 1), (rows, 2)] {
                let down = j == 0
                if inside {
                    let centre = origin + axis * (z0 + (z1 - z0) * Double(j) / Double(rows))
                    add([centre, point(k, j), point(k + 1, j)], face, flip: down)
                } else {
                    add([point(k, j), ring(k, j, other), ring(k + 1, j, other)], face, flip: down)
                    add([point(k, j), ring(k + 1, j, other), point(k + 1, j)], face, flip: down)
                }
            }
        }
        return ChamferGeometry.orientedSolid(polys, faces)
    }
}
