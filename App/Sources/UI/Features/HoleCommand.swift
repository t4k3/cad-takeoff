import CADCore
import Observation
import SwiftUI

/// Where the holes go: centres clicked on one planar face (T83), snapped to the part's
/// vertices, edge midpoints, circle centres, face centres and the points of saved sketches.
@MainActor
@Observable
final class HolePlacement {
    /// Plane of the first clicked face; later clicks are projected onto it.
    var planeOrigin: Vec3?
    var normal: Vec3?
    var centers: [Vec3] = []
    var bore = 3.0
    var head = 3.0
    var depth: Double?
    var editing: Feature.ID?
    /// Snapped point under the cursor, its face normal and what it snapped to.
    var hover: (point: Vec3, normal: Vec3, snap: String?)?
    /// Saved sketches whose points are snap targets.
    @ObservationIgnored var sketches: () -> [Sketch] = { [] }
    /// Called after a centre is added, moved or removed (the panel shows its coordinates).
    @ObservationIgnored var onChange: () -> Void = {}
    @ObservationIgnored private var cache: (key: String, points: [(Vec3, String)])?

    struct Target { var point: Vec3; var origin: Vec3; var normal: Vec3; var snap: String? }

    /// Adds a centre from a viewport click (the face must be planar).
    func click(_ ray: Ray, bodies: [ViewportRenderer.Body], tolerance: (Double) -> Double) -> String? {
        switch locate(ray, bodies: bodies, tolerance: tolerance) {
        case let .failure(message): return message.text
        case let .success(t):
            if normal == nil { planeOrigin = t.origin; normal = t.normal }
            return add(t.point)
        }
    }

    func hover(_ ray: Ray?, bodies: [ViewportRenderer.Body], tolerance: (Double) -> Double) {
        guard let ray, case let .success(t) = locate(ray, bodies: bodies, tolerance: tolerance) else {
            if hover != nil { hover = nil }
            return
        }
        hover = (t.point, t.normal, t.snap)
    }

    func removeLast() {
        guard !centers.isEmpty else { return }
        centers.removeLast()
        if centers.isEmpty, editing == nil { normal = nil; planeOrigin = nil }
        onChange()
    }

    /// Moves the last centre (typed coordinates), kept on the face plane.
    func moveLast(to p: Vec3) {
        guard !centers.isEmpty, let n = normal, let o = planeOrigin else { return }
        let q = p - n * (p - o).dot(n)
        if (centers[centers.count - 1] - q).length > 1e-9 { centers[centers.count - 1] = q }
    }

    struct Message: Error { let text: String }

    /// `tolerance(d)`: snap radius in mm at distance `d` along the ray (a fixed size on screen).
    private func locate(_ ray: Ray, bodies: [ViewportRenderer.Body], tolerance: (Double) -> Double) -> Result<Target, Message> {
        let o: Vec3, n: Vec3, raw: Vec3
        if let pn = normal, let po = planeOrigin {
            guard let p = ray.intersect(planePoint: f(po), normal: f(pn)) else { return .failure(Message(text: "")) }
            (o, n, raw) = (po, pn, Vec3(Double(p.x), Double(p.y), Double(p.z)))
        } else {
            guard let hit = Picking.pick(ray, in: bodies),
                  let body = bodies.first(where: { $0.feature.id == hit.featureID }),
                  let face = body.face(ofTriangle: hit.triangle) else { return .failure(Message(text: "Clicca su una faccia del pezzo.")) }
            guard case let .plane(fo, fn) = face.surface else { return .failure(Message(text: "Il foro va posizionato su una faccia piana.")) }
            let p = Vec3(Double(hit.point.x), Double(hit.point.y), Double(hit.point.z))
            (o, n, raw) = (fo, fn, p - fn * (p - fo).dot(fn))
        }
        // Screen-space test: distance of each target from the ray, relative to the radius at its depth.
        let ro = Vec3(Double(ray.origin.x), Double(ray.origin.y), Double(ray.origin.z))
        let rd = Vec3(Double(ray.direction.x), Double(ray.direction.y), Double(ray.direction.z)).normalized
        let near = snapPoints(o, n, bodies).compactMap { target -> ((Vec3, String), Double)? in
            let v = target.0 - ro, t = v.dot(rd)
            guard t > 0 else { return nil }
            let score = (v - rd * t).length / tolerance(t)
            return score <= 1 ? (target, score) : nil
        }.min { $0.1 < $1.1 }
        if let (target, _) = near { return .success(Target(point: target.0, origin: o, normal: n, snap: target.1)) }
        // Free placement only on the face itself (or a coplanar one), never on its empty extension.
        guard let hit = Picking.pick(ray, in: bodies),
              let face = bodies.first(where: { $0.feature.id == hit.featureID })?.face(ofTriangle: hit.triangle),
              case let .plane(fo, fn) = face.surface, fn.dot(n) > 1 - 1e-9, abs((fo - o).dot(n)) < 1e-4 else {
            return .failure(Message(text: "Clicca sulla faccia, o vicino a un vertice, a uno spigolo o a un punto dello schizzo."))
        }
        return .success(Target(point: grid(raw, n), origin: o, normal: n, snap: nil))
    }

    /// Snap targets lying on the plane (sketch points are projected onto it).
    private func snapPoints(_ o: Vec3, _ n: Vec3, _ bodies: [ViewportRenderer.Body]) -> [(Vec3, String)] {
        let key = "\(o)|\(n)|\(bodies.map { $0.snapshot.revision + $0.feature.id.uuidString })|\(sketches().count)"
        if let cache, cache.key == key { return cache.points }
        var out: [(Vec3, String)] = []
        func onPlane(_ p: Vec3) -> Bool { abs((p - o).dot(n)) < 1e-4 }
        for body in bodies {
            let s = body.snapshot
            for e in s.edges {
                let pts = e.polyline
                guard let a = pts.first, let b = pts.last else { continue }
                if pts.count > 3, (a - b).length < 1e-6 {
                    let unique = pts.dropLast()
                    let c = unique.reduce(Vec3.zero, +) * (1 / Double(unique.count))
                    if onPlane(c) { out.append((c, "Centro")) }
                    continue
                }
                if onPlane(a) { out.append((a, "Vertice")) }
                if onPlane(b) { out.append((b, "Vertice")) }
                let mid = (a + b) * 0.5
                let straight = pts.allSatisfy { p in let d = p - a, u = (b - a).normalized; return (d - u * d.dot(u)).length < 1e-6 }
                if straight, onPlane(mid) { out.append((mid, "Punto medio")) }
            }
            // Centre of each planar face lying on the plane (area-weighted).
            for (fi, face) in s.faces.enumerated() {
                guard case let .plane(fo, fn) = face.surface, fn.dot(n) > 1 - 1e-9, onPlane(fo) else { continue }
                var sum = Vec3.zero, area = 0.0
                for t in 0..<s.triangleFace.count where Int(s.triangleFace[t]) == fi {
                    let v = (0..<3).map { s.positions[Int(s.triangles[t * 3 + $0])] }
                    let a = (v[1] - v[0]).cross(v[2] - v[0]).length / 2
                    sum = sum + (v[0] + v[1] + v[2]) * (a / 3); area += a
                }
                if area > 0 { out.append((sum * (1 / area), "Centro faccia")) }
            }
        }
        for sk in sketches() where sk.isVisible {
            for shape in sk.shapes {
                for (p, label) in Self.keyPoints(shape) {
                    let w = sk.plane.world(p)
                    out.append((w - n * (w - o).dot(n), label))
                }
            }
        }
        cache = (key, out)
        return out
    }

    private static func keyPoints(_ shape: SketchShape) -> [(Vec2, String)] {
        func mid(_ a: Vec2, _ b: Vec2) -> Vec2 { Vec2((a.x + b.x) / 2, (a.y + b.y) / 2) }
        switch shape.kind {
        case let .polyline(p, closed):
            let segs = closed ? Array(zip(p, p.dropFirst() + p.prefix(1))) : Array(zip(p, p.dropFirst()))
            return p.map { ($0, "Estremità schizzo") } + segs.map { (mid($0, $1), "Punto medio schizzo") }
        case .rectangle:
            let c = shape.outline
            let centre = mid(c[0], c[2])
            return c.map { ($0, "Vertice schizzo") } + [(centre, "Centro schizzo")]
                + (0..<4).map { (mid(c[$0], c[($0 + 1) % 4]), "Punto medio schizzo") }
        case let .circle(c, _):
            return [(c, "Centro schizzo")]
        case let .polygon(c, _, _, _, _):
            return [(c, "Centro schizzo")] + shape.outline.map { ($0, "Vertice schizzo") }
        case let .slot(a, b, _):
            return [(a, "Centro schizzo"), (b, "Centro schizzo"), (mid(a, b), "Punto medio schizzo")]
        case .arc:
            return [(shape.point(0)!, "Centro schizzo"), (shape.point(1)!, "Estremità schizzo"), (shape.point(2)!, "Estremità schizzo")]
        case let .spline(p, _):
            return p.map { ($0, "Punto spline") }
        }
    }

    /// Ignores a click on an existing hole (a double click would stack two identical centres).
    private func add(_ c: Vec3) -> String? {
        let minGap = max(bore, head) / 2
        if centers.contains(where: { ($0 - c).length < minGap }) { return "C'è già un foro in quel punto." }
        centers.append(c)
        onChange()
        return nil
    }

    /// 0.5 mm grid on the in-plane axes of axis-aligned faces (when nothing to snap to is near).
    private func grid(_ p: Vec3, _ n: Vec3) -> Vec3 {
        func s(_ v: Double, _ nc: Double) -> Double { abs(nc) < 1e-6 ? (v * 2).rounded() / 2 : v }
        return Vec3(s(p.x, n.x), s(p.y, n.y), s(p.z, n.z))
    }

    private func f(_ p: Vec3) -> SIMD3<Float> { SIMD3(Float(p.x), Float(p.y), Float(p.z)) }

    /// Red preview: bore and head circles on the face, and the axis.
    func overlay() -> [(SIMD3<Float>, SIMD3<Float>, SIMD4<Float>)] {
        let red = SIMD4<Float>(0.95, 0.25, 0.25, 1), faint = SIMD4<Float>(0.95, 0.25, 0.25, 0.55)
        var out: [(SIMD3<Float>, SIMD3<Float>, SIMD4<Float>)] = []
        func circle(_ c: Vec3, _ n: Vec3, _ r: Double, _ color: SIMD4<Float>, segments: Int = 48) {
            let helper = abs(n.z) < 0.9 ? Vec3(0, 0, 1) : Vec3(1, 0, 0)
            let u = helper.cross(n).normalized, v = n.cross(u)
            let pts = (0...segments).map { k -> Vec3 in
                let t = Double(k) / Double(segments) * 2 * .pi
                return c + n * 0.02 + (u * cos(t) + v * sin(t)) * r
            }
            for (a, b) in zip(pts, pts.dropFirst()) { out.append((f(a), f(b), color)) }
        }
        if let n = normal {
            for c in centers {
                for (r, color) in [(bore / 2, red), (head / 2, faint)] where r > 0 { circle(c, n, r, color) }
                out.append((f(c + n * 1.5), f(c - n * (depth ?? 20)), faint))
            }
        }
        // Cursor: the hole outline where a click would put it, and a square on a snapped point.
        if let h = hover {
            circle(h.point, h.normal, max(bore, head) / 2, SIMD4(0.95, 0.25, 0.25, 0.35))
            if h.snap != nil {
                let green = SIMD4<Float>(0.3, 0.95, 0.45, 1)
                let size = max(0.4, max(bore, head) * 0.12)
                circle(h.point, h.normal, size, green, segments: 4)
            }
        }
        return out
    }
}

@MainActor
enum HoleCommand {
    static let styles = HoleSpec.Style.allCases
    static let fits: [HoleSpec.Fit] = [.clearance, .tapped, .heatInsert, .manual]   // modelled thread: not yet
    static let sizes = MetricScrew.all.map(\.name)

    /// Opens the Hole panel: new hole, or edit of an existing one.
    static func start(workspace: WorkspaceState, model: DesignModel, editing feature: Feature? = nil) -> CommandSession {
        let placement = HolePlacement()
        var spec = HoleSpec(centers: [], fit: .clearance, size: "M3")
        if let feature, case let .hole(existing) = feature.kind {
            spec = existing
            placement.centers = existing.centers
            placement.normal = -existing.direction.normalized
            placement.planeOrigin = existing.centers.first
            placement.editing = feature.id
        }
        placement.sketches = { [weak workspace] in workspace?.sketchStore?.sketches ?? [] }
        workspace.holePlacement = placement

        func fields(_ s: HoleSpec) -> [CommandField] {
            [
                .init(id: "style", label: "Tipo", kind: .choice(styles.map(\.label)), value: .index(styles.firstIndex(of: s.style) ?? 0)),
                .init(id: "fit", label: "Uso", kind: .choice(fits.map(\.label)), value: .index(fits.firstIndex(of: s.fit) ?? 0),
                      help: "Passaggio vite: la vite scorre. Filettatura indicata: preforo per maschiare o autofilettante. Inserto a caldo: foro per inserti filettati (verifica il produttore)."),
                .init(id: "size", label: "Vite", kind: .choice(sizes), value: .index(sizes.firstIndex(of: s.size ?? "M3") ?? 2)),
                .init(id: "dia", label: "Diametro (libero)", kind: .length(0.1...500), value: .number(s.diameter),
                      help: "Usato solo con «Diametro libero»"),
                .init(id: "through", label: "Passante", kind: .toggle, value: .flag(s.depth == nil)),
                .init(id: "depth", label: "Profondità", kind: .length(0.1...10000), value: .number(s.depth ?? 10),
                      help: "Usata quando il foro non è passante"),
                .init(id: "allow", label: "Compensazione stampa", kind: .length(0...2), value: .number(s.printAllowance),
                      help: "Aggiunta ai diametri: le stampanti FDM tendono a stampare i fori più stretti (tipico 0,1–0,3 mm)"),
            ] + ["x", "y", "z"].enumerated().map { i, axis in
                let c = placement.centers.last
                return .init(id: axis, label: "Centro \(axis.uppercased())", kind: .length(-100_000...100_000),
                             value: .number(c.map { [$0.x, $0.y, $0.z][i] } ?? 0),
                             help: i == 0 ? "Coordinate dell'ultimo centro: scrivi un valore per spostarlo con precisione (resta sulla faccia)" : nil)
            }
        }

        func read(_ f: [CommandField]) -> HoleSpec {
            var s = spec
            func idx(_ id: String) -> Int { if case let .index(i)? = f.first(where: { $0.id == id })?.value { i } else { 0 } }
            func num(_ id: String) -> Double { f.first { $0.id == id }?.number ?? 0 }
            s.style = styles[idx("style")]
            s.fit = fits[idx("fit")]
            s.size = s.fit == .manual ? nil : sizes[idx("size")]
            s.diameter = num("dia")
            if case let .flag(through)? = f.first(where: { $0.id == "through" })?.value { s.depth = through ? nil : num("depth") }
            s.printAllowance = num("allow")
            s.centers = placement.centers
            if let n = placement.normal { s.direction = -n }
            return s
        }

        func preview(_ f: [CommandField]) {
            func num(_ id: String) -> Double { f.first { $0.id == id }?.number ?? 0 }
            if !placement.centers.isEmpty, f.allSatisfy({ $0.validationMessage == nil }) {
                placement.moveLast(to: Vec3(num("x"), num("y"), num("z")))
            }
            let s = read(f)
            placement.bore = s.boreDiameter
            placement.head = s.style == .simple ? 0 : s.resolvedHeadDiameter
            placement.depth = s.depth
        }

        let session = CommandSession(
            title: feature == nil ? "Foro" : "Modifica \(feature!.name)", symbol: "circle.circle",
            fields: fields(spec),
            onPreview: preview,
            onCommit: { f in
                let s = read(f)
                defer { workspace.holePlacement = nil }
                guard !s.centers.isEmpty else {
                    model.statusMessage = "Foro non creato: clicca su una faccia piana per posizionare almeno un centro."
                    return
                }
                do { try s.validate() } catch {
                    model.statusMessage = "Foro non valido: \(error.localizedDescription)"; return
                }
                if let id = placement.editing {
                    model.edit("Modifica foro", selected: .some(id), changed: [id]) { doc in
                        if let i = doc.features.firstIndex(where: { $0.id == id }) {
                            if doc.features[i].name == "Foro " + spec.summary { doc.features[i].name = "Foro " + s.summary }
                            doc.features[i].kind = .hole(s)
                        }
                    }
                } else {
                    let hole = Feature(name: "Foro " + s.summary, kind: .hole(s), operation: .cut)
                    model.edit("Foro " + s.summary, selected: .some(nil), changed: [hole.id]) { $0.features.append(hole) }
                }
                if let issue = model.evaluation().issues.last(where: { $0.featureID == placement.editing ?? model.document.features.last?.id }) {
                    model.statusMessage = issue.message
                }
            },
            onCancel: { workspace.holePlacement = nil })
        // The coordinate fields follow the last centre placed with the mouse.
        placement.onChange = { [weak session, weak placement] in
            guard let session, let c = placement?.centers.last else { return }
            for (axis, v) in zip(["x", "y", "z"], [c.x, c.y, c.z]) {
                if let i = session.fields.firstIndex(where: { $0.id == axis }), session.fields[i].number != v {
                    session.fields[i].value = .number(v)
                }
            }
        }
        preview(session.fields)
        return session
    }
}
