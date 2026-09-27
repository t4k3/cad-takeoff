import Foundation

// Press/Pull (Fusion's Q): drag a planar face of a solid along its normal.
// - The top or bottom face of an extrusion, box or cylinder changes that feature's height (the
//   history stays parametric: a ring extruded 10 mm becomes 15 mm, nothing is added).
// - Any other planar face is extruded by the distance: joined when pulled out, cut when pushed in.

public enum PressPull {
    public enum Plan: Equatable, Sendable {
        /// Change the height of `featureID`; `shift`: the feature also moves by the distance
        /// along the face normal (the face is the one that does not move when the height grows).
        case height(featureID: UUID, normal: Vec3, shift: Bool)
        /// Extrude the face outline (with its holes) from the face plane.
        case offset(profile: Profile2D, holes: [Profile2D], plane: SketchPlane)
    }

    /// Centre and outward normal of a face of a body (from its triangles).
    public static func frame(of face: FaceID, in snapshot: BodySnapshot) -> (centre: Vec3, normal: Vec3, isPlanar: Bool)? {
        guard let f = snapshot.faces.firstIndex(where: { $0.id == face }) else { return nil }
        var weighted = Vec3.zero, area = 0.0, sum = Vec3.zero
        for t in snapshot.triangleFace.indices where Int(snapshot.triangleFace[t]) == f {
            let v = (0..<3).map { snapshot.positions[Int(snapshot.triangles[t * 3 + $0])] }
            let c = (v[1] - v[0]).cross(v[2] - v[0])
            sum = sum + c
            weighted = weighted + (v[0] + v[1] + v[2]) * (c.length / 6)
            area += c.length / 2
        }
        guard area > 1e-12 else { return nil }
        let n = sum.normalized
        var planar = true
        if case .plane = snapshot.faces[f].surface {} else { planar = false }
        return (weighted * (1 / area), n, planar && sum.length / 2 > area * 0.999)
    }

    /// What pressing/pulling `face` would do, or nil (curved face, unknown owner, outline too complex).
    public static func plan(face: FaceID, in snapshot: BodySnapshot, document: CADDocument) -> Plan? {
        guard let frame = frame(of: face, in: snapshot), frame.isPlanar else { return nil }
        // Cap of a feature? Face IDs start with the feature's UUID, then family/role.
        let parts = face.rawValue.split(separator: "/").map(String.init)
        if parts.count >= 3, let id = UUID(uuidString: parts[0]), ["extrude", "box", "cylinder"].contains(parts[1]),
           ["top", "bottom"].contains(parts.last!),
           let feature = document.features.first(where: { $0.id == id }), height(of: feature) != nil,
           // Symmetric or drafted: changing the height would move the other cap or the walls too.
           !feature.symmetric, feature.taper == 0,
           let shift = capShift(feature, face: face, normal: frame.normal) {
            return .height(featureID: id, normal: frame.normal, shift: shift)
        }
        guard let loops = boundary(of: face, in: snapshot), !loops.isEmpty else { return nil }
        let plane = SketchPlane.onFace(point: frame.centre, normal: frame.normal)
        let flat = loops.map { Profile2D(points: $0.map { plane.local($0) }) }
        guard let outer = flat.max(by: { $0.area < $1.area }), flat.allSatisfy({ (3...1024).contains($0.points.count) }) else { return nil }
        return .offset(profile: outer, holes: flat.filter { $0 != outer }, plane: plane)
    }

    /// The design with the face moved by `distance` (mm, positive = out of the material), and the
    /// feature that changed or was added.
    public static func apply(_ plan: Plan, distance: Double, to document: CADDocument, name: String = "Premi/Tira") throws -> (CADDocument, UUID) {
        guard distance.isFinite, abs(distance) > 1e-9 else { throw KernelError.invalidParameter("distanza nulla") }
        var doc = document
        switch plan {
        case let .height(id, normal, shift):
            guard let i = doc.features.firstIndex(where: { $0.id == id }), let h = height(of: doc.features[i]) else {
                throw KernelError.invalidParameter("la feature della faccia non esiste più")
            }
            let next = h + distance
            guard next >= 0.01 else { throw KernelError.invalidParameter("altezza risultante \(String(format: "%.2f", next)) mm: spingi meno di \(String(format: "%.2f", h)) mm") }
            doc.features[i].kind = withHeight(doc.features[i].kind, next)
            if shift { doc.features[i].position = doc.features[i].position + normal * distance }
            return (doc, id)
        case let .offset(profile, holes, plane):
            let f = Feature(name: name, kind: .extrude(profile: profile, height: abs(distance)),
                            operation: distance > 0 ? .join : .cut,
                            placement: FeaturePlacement(plane: plane, reversed: distance < 0), holes: holes)
            doc.features.append(f)
            return (doc, f.id)
        }
    }

    /// Several faces moved by the same distance, each along its own normal (applied in order: two
    /// caps of one feature both change its height).
    public static func apply(_ plans: [Plan], distance: Double, to document: CADDocument, name: String = "Premi/Tira") throws -> (CADDocument, [UUID]) {
        var doc = document, ids: [UUID] = []
        for plan in plans {
            let (next, id) = try apply(plan, distance: distance, to: doc, name: name)
            doc = next
            if !ids.contains(id) { ids.append(id) }
        }
        return (doc, ids)
    }

    /// Faces of the evaluated design moved together by `distance`: heights first, then the other
    /// faces are re-read on the updated part and extruded, so a side face pulled with the top
    /// takes the new height (no step), as when Fusion offsets several faces at once.
    public static func move(faces: [FaceID], distance: Double, in document: CADDocument,
                            components: DesignEvaluator.ComponentResolver? = nil, name: String = "Premi/Tira") throws -> (CADDocument, [UUID]) {
        func planned(_ doc: CADDocument) -> [FaceID: Plan] {
            let bodies = DesignEvaluator.evaluate(doc, revision: "presspull", components: components).bodies
            var out: [FaceID: Plan] = [:]
            for id in faces {
                for b in bodies where b.snapshot.faces.contains(where: { $0.id == id }) {
                    if let p = plan(face: id, in: b.snapshot, document: doc) { out[id] = p }
                    break
                }
            }
            return out
        }
        let first = planned(document)
        let heights = faces.compactMap { first[$0] }.filter { if case .height = $0 { true } else { false } }
        guard !first.isEmpty else { throw KernelError.invalidParameter("nessuna faccia piana da spostare") }
        var (doc, ids) = try apply(heights, distance: distance, to: document, name: name)
        let offsetFaces = faces.filter { if case .offset? = first[$0] { true } else { false } }
        if !offsetFaces.isEmpty {
            let again = heights.isEmpty ? first : planned(doc)
            let offsets = offsetFaces.compactMap { again[$0] }.filter { if case .offset = $0 { true } else { false } }
            let (next, more) = try apply(offsets, distance: distance, to: doc, name: name)
            doc = next
            ids += more.filter { !ids.contains($0) }
        }
        return (doc, ids)
    }

    // MARK: Helpers

    static func height(of f: Feature) -> Double? {
        switch f.kind {
        case let .box(_, _, h), let .cylinder(_, h), let .extrude(_, h): h
        default: nil
        }
    }

    static func withHeight(_ kind: Feature.Kind, _ h: Double) -> Feature.Kind {
        switch kind {
        case let .box(w, d, _): .box(width: w, depth: d, height: h)
        case let .cylinder(r, _): .cylinder(radius: r, height: h)
        case let .extrude(p, _): .extrude(profile: p, height: h)
        default: kind
        }
    }

    /// Does this cap stay put when the height grows (so pulling it must also move the feature)?
    private static func capShift(_ feature: Feature, face: FaceID, normal: Vec3) -> Bool? {
        guard let h = height(of: feature) else { return nil }
        var a = feature, b = feature
        a.holes = []; b.holes = []
        b.kind = withHeight(b.kind, h + 1)
        guard let sa = try? PrimitiveKernel.build(a).snapshot(revision: ""), let sb = try? PrimitiveKernel.build(b).snapshot(revision: ""),
              let fa = frame(of: face, in: sa), let fb = frame(of: face, in: sb) else { return nil }
        let moved = (fb.centre - fa.centre).dot(normal)
        if abs(moved - 1) < 1e-6 { return false }
        if abs(moved) < 1e-6 { return true }
        return nil
    }

    /// Boundary loops of a face, welded, without collinear points (outer and holes, any order).
    static func boundary(of face: FaceID, in snapshot: BodySnapshot) -> [[Vec3]]? {
        guard let f = snapshot.faces.firstIndex(where: { $0.id == face }) else { return nil }
        struct Key: Hashable { let x: Int64, y: Int64, z: Int64 }
        func key(_ p: Vec3) -> Key { Key(x: Int64((p.x * 1e5).rounded()), y: Int64((p.y * 1e5).rounded()), z: Int64((p.z * 1e5).rounded())) }
        var point: [Key: Vec3] = [:]
        struct E: Hashable { let a: Key, b: Key }
        var count: [E: Int] = [:]
        for t in snapshot.triangleFace.indices where Int(snapshot.triangleFace[t]) == f {
            let v = (0..<3).map { snapshot.positions[Int(snapshot.triangles[t * 3 + $0])] }
            let k = v.map(key)
            for (p, kk) in zip(v, k) { point[kk] = p }
            for j in 0..<3 where k[j] != k[(j + 1) % 3] { count[E(a: k[j], b: k[(j + 1) % 3]), default: 0] += 1 }
        }
        var next: [Key: Key] = [:]
        for (e, n) in count where n > (count[E(a: e.b, b: e.a)] ?? 0) {
            guard next[e.a] == nil else { return nil }   // pinch point
            next[e.a] = e.b
        }
        var loops: [[Vec3]] = []
        while let start = next.keys.first {
            var loop: [Vec3] = [], cur = start
            while let n = next.removeValue(forKey: cur) {
                loop.append(point[cur]!); cur = n
                if cur == start { break }
                guard loop.count <= count.count else { return nil }
            }
            guard cur == start else { return nil }
            // Drop points on straight runs (split triangles leave them).
            var changed = true
            while changed, loop.count > 3 {
                changed = false
                for i in loop.indices {
                    let a = loop[(i + loop.count - 1) % loop.count], b = loop[i], c = loop[(i + 1) % loop.count]
                    if (b - a).cross(c - b).length <= 1e-9 * max(1, (c - a).length) { loop.remove(at: i); changed = true; break }
                }
            }
            if loop.count >= 3 { loops.append(loop) }
        }
        return loops
    }
}
