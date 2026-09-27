import Foundation

/// «Rivoluzione» (Fusion's Revolve): a sketch profile turned about a line of its sketch.
public struct RevolveSpec: Codable, Sendable, Equatable {
    /// Outline in sketch coordinates (the holes are the feature's `holes`).
    public var profile: Profile2D
    /// Sketch the profile lies on.
    public var plane: SketchPlane
    /// Two points of the axis, in sketch coordinates.
    public var axisStart: Vec2
    public var axisEnd: Vec2
    /// The sketch line used as axis, followed when the sketch changes (nil: fixed points).
    public var axisRef: SketchRef?
    /// Degrees, (0, 360]: 360 is a full turn.
    public var angle: Double
    /// Turns the other way (towards the back of the sketch plane).
    public var reversed: Bool

    public init(profile: Profile2D, plane: SketchPlane = .xy, axisStart: Vec2, axisEnd: Vec2, axisRef: SketchRef? = nil,
                angle: Double = 360, reversed: Bool = false) {
        self.profile = profile; self.plane = plane; self.axisStart = axisStart; self.axisEnd = axisEnd
        self.axisRef = axisRef; self.angle = angle; self.reversed = reversed
    }

    public func validate(holes: [Profile2D] = []) throws {
        guard angle.isFinite, angle > 0, angle <= 360 else { throw KernelError.invalidParameter("rivoluzione: angolo tra 0 e 360°") }
        guard (axisEnd - axisStart).length > 1e-9 else { throw KernelError.invalidParameter("rivoluzione: asse nullo") }
        guard (3...1024).contains(profile.points.count) else { throw KernelError.invalidProfile("richiesti 3–1024 vertici") }
        // The whole profile on one side of the axis (it may touch it).
        let d = (axisEnd - axisStart) * (1 / (axisEnd - axisStart).length)
        let s = (profile.points + holes.flatMap(\.points)).map { d.cross($0 - axisStart) }
        let tol = 1e-6 * max(1, s.map(abs).max() ?? 1)
        guard s.allSatisfy({ $0 >= -tol }) || s.allSatisfy({ $0 <= tol }) else {
            throw KernelError.invalidProfile("il profilo attraversa l'asse: deve stare da una parte sola")
        }
        guard s.contains(where: { abs($0) > tol }) else { throw KernelError.invalidProfile("il profilo sta tutto sull'asse") }
    }
}

enum Revolve {
    /// The closed solid swept by the profile (and its holes). Faces: one per profile side (plane,
    /// cylinder or cone; arcs of the profile make one torus or sphere face each), plus the two
    /// ends when the turn is not complete.
    static func build(_ given: RevolveSpec, holes givenHoles: [Profile2D], featureID: UUID, position: Vec3, segments standard: Int = 64) throws -> CSGSolid {
        try given.validate(holes: givenHoles)
        // At a finer tessellation: more steps round the axis, the profile's arcs cut finer.
        let segments = Tessellation.segments(standard)
        let spec = given, holes = givenHoles
        let plane = spec.plane
        let dir2 = (spec.axisEnd - spec.axisStart) * (1 / (spec.axisEnd - spec.axisStart).length)
        let left2 = Vec2(-dir2.y, dir2.x)
        // Which side of the axis the profile lies on.
        let side = (spec.profile.points + holes.flatMap(\.points)).map { dir2.cross($0 - spec.axisStart) }
            .max(by: { abs($0) < abs($1) }).map { $0 < 0 ? -1.0 : 1.0 } ?? 1
        func vec(_ v: Vec2) -> Vec3 { plane.xAxis * v.x + plane.yAxis * v.y }
        let origin = plane.world(spec.axisStart) + position
        let axis = vec(dir2).normalized
        let radial = vec(left2).normalized * side
        let normal = plane.xAxis.cross(plane.yAxis).normalized
        let turn = radial.cross(axis).dot(normal) >= 0 ? normal : -normal
        let w = spec.reversed ? -turn : turn
        let full = spec.angle >= 360 - 1e-9
        let span = spec.angle * .pi / 180
        let steps = full ? max(8, segments) : max(2, Int((span / (2 * .pi) * Double(segments)).rounded(.up)))

        /// (height along the axis, radius) of a sketch point.
        func hr(_ p: Vec2) -> (h: Double, r: Double) {
            let q = p - spec.axisStart
            return (q.dot(dir2), max(0, abs(dir2.cross(q))))
        }
        func point(_ p: (h: Double, r: Double), _ k: Int) -> Vec3 {
            let kk = full ? k % steps : k
            let t = Double(kk) / Double(steps) * span
            return origin + axis * p.h + (radial * cos(t) + w * sin(t)) * p.r
        }

        let prefix = featureID.uuidString.lowercased() + "/revolve/"
        var faces: [CSGFace] = []
        var polys: [CSGSolid.Polygon] = []
        func face(_ id: String, _ s: SurfaceDescriptor) -> Int {
            if let i = faces.firstIndex(where: { $0.id.rawValue == prefix + id }) { return i }
            faces.append(CSGFace(id: FaceID(rawValue: prefix + id), surface: s, flipped: false))
            return faces.count - 1
        }
        func surface(_ a: (h: Double, r: Double), _ b: (h: Double, r: Double)) -> SurfaceDescriptor {
            let dh = b.h - a.h, dr = b.r - a.r
            if abs(dr) < 1e-9 { return .cylinder(axisOrigin: origin, axisDirection: axis, radius: a.r) }
            if abs(dh) < 1e-9 { return .plane(origin: origin + axis * a.h, normal: axis) }
            let hApex = a.h - a.r * dh / dr
            let up = (a.h - hApex) > 0 || (b.h - hApex) > 0 ? axis : -axis
            return .cone(apex: origin + axis * hApex, axisDirection: up, halfAngle: atan(abs(dr / dh)))
        }
        // Loops: the outline counter-clockwise, holes clockwise (as the caps' boundary runs).
        let outer = Profile2D(points: spec.profile.points).points
        let loops: [(points: [Vec2], tag: String)] = [(outer, "o")] + holes.enumerated().map { (Array(Profile2D(points: $0.element.points).points.reversed()), "h\($0.offset)") }
        for loop in loops {
            let pts = loop.points, n = pts.count
            let arcs = PrimitiveKernel.profileArcs(pts)
            for i in 0..<n {
                let a = hr(pts[i]), b = hr(pts[(i + 1) % n])
                if a.r < 1e-9, b.r < 1e-9 { continue }   // along the axis: nothing to sweep
                // At a finer tessellation an arc side is swept in pieces on its circle; the face
                // keeps the side's name.
                let cut = [pts[i]] + Tessellation.between(pts[i], pts[(i + 1) % n], on: arcs[i]) + [pts[(i + 1) % n]]
                let f: Int
                if let arc = arcs[i] {
                    let c = hr(arc.center)
                    // An arc centred on the axis sweeps a sphere, not a torus of radius zero.
                    let onAxis = abs(c.r) <= 1e-7 * max(1, arc.radius)
                    f = face("\(loop.tag)/arc/\(arc.index)", onAxis
                             ? .sphere(center: origin + axis * c.h, radius: arc.radius)
                             : .torus(center: origin + axis * c.h, axisDirection: axis, majorRadius: c.r, minorRadius: arc.radius))
                } else {
                    f = face("\(loop.tag)/side/\(i)", surface(a, b))
                }
                for (qa, qb) in zip(cut, cut.dropFirst()) {
                let a = hr(qa), b = hr(qb)
                if a.r < 1e-9, b.r < 1e-9 { continue }
                for k in 0..<steps {
                    let pa0 = point(a, k), pb0 = point(b, k), pb1 = point(b, k + 1), pa1 = point(a, k + 1)
                    var v: [Vec3]
                    if a.r < 1e-9 { v = [pa0, pb0, pb1] } else if b.r < 1e-9 { v = [pa0, pb0, pa1] } else { v = [pa0, pb0, pb1, pa1] }
                    // Drop a collapsed corner (a sliver right on the axis).
                    v = v.enumerated().filter { j, p in (p - v[(j + 1) % v.count]).length > 1e-12 }.map(\.element)
                    guard v.count >= 3, (v[1] - v[0]).cross(v[2] - v[0]).length > 1e-14 else { continue }
                    polys.append(CSGSolid.Polygon(vertices: v, face: f))
                }
                }
            }
        }
        if !full {
            // The ends: the profile as its sides were swept (arcs cut finer too).
            let tris = Profile2D(points: Tessellation.refined(outer, keys: nil).points)
                .triangulate(holes: holes.map { Profile2D(points: Tessellation.refined(Profile2D(points: $0.points).points, keys: nil).points) })
            let flat = tris.map { (hr($0.0), hr($0.1), hr($0.2)) }
            let start = face("start", .plane(origin: origin, normal: -w))
            let endN = radial * -sin(span) + w * cos(span)
            let end = face("end", .plane(origin: origin, normal: endN))
            for (a, b, c) in flat {
                let s = [point(a, 0), point(c, 0), point(b, 0)], e = [point(a, steps), point(b, steps), point(c, steps)]
                if (s[1] - s[0]).cross(s[2] - s[0]).length > 1e-14 { polys.append(CSGSolid.Polygon(vertices: s, face: start)) }
                if (e[1] - e[0]).cross(e[2] - e[0]).length > 1e-14 { polys.append(CSGSolid.Polygon(vertices: e, face: end)) }
            }
        }
        guard !polys.isEmpty else { throw KernelError.invalidProfile("rivoluzione vuota") }
        // Everything was built with one winding; turn it outwards if it came out inside-out.
        var volume = 0.0
        let o = polys[0].vertices[0]
        for p in polys {
            for j in 1..<(p.vertices.count - 1) {
                volume += (p.vertices[0] - o).dot((p.vertices[j] - o).cross(p.vertices[j + 1] - o))
            }
        }
        if volume < 0 { polys = polys.map { $0.flipped(faceMap: { $0 }) } }
        return CSGSolid(polygons: polys, faces: faces)
    }
}
