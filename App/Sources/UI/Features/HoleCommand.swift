import CADCore
import Observation
import SwiftUI

/// Where the holes go: centres clicked on one planar face (T83).
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

    /// Adds a centre from a viewport click (the face must be planar).
    func click(_ ray: Ray, bodies: [ViewportRenderer.Body]) -> String? {
        if let n = normal, let o = planeOrigin {
            guard let p = ray.intersect(planePoint: SIMD3(Float(o.x), Float(o.y), Float(o.z)),
                                        normal: SIMD3(Float(n.x), Float(n.y), Float(n.z))) else { return nil }
            return add(snap(Vec3(Double(p.x), Double(p.y), Double(p.z)), n))
        }
        guard let hit = Picking.pick(ray, in: bodies),
              let body = bodies.first(where: { $0.feature.id == hit.featureID }),
              let face = body.face(ofTriangle: hit.triangle) else { return "Clicca su una faccia del pezzo." }
        guard case let .plane(origin, n) = face.surface else { return "Il foro va posizionato su una faccia piana." }
        planeOrigin = origin; normal = n
        let p = hit.point
        // Project exactly onto the face plane, then snap.
        let raw = Vec3(Double(p.x), Double(p.y), Double(p.z))
        return add(snap(raw - n * (raw - origin).dot(n), n))
    }

    /// Ignores a click on an existing hole (a double click would stack two identical centres).
    private func add(_ c: Vec3) -> String? {
        let minGap = max(bore, head) / 2
        if centers.contains(where: { ($0 - c).length < minGap }) { return "C'è già un foro in quel punto." }
        centers.append(c)
        return nil
    }

    /// 0.5 mm grid on the in-plane axes of axis-aligned faces.
    private func snap(_ p: Vec3, _ n: Vec3) -> Vec3 {
        func s(_ v: Double, _ nc: Double) -> Double { abs(nc) < 1e-6 ? (v * 2).rounded() / 2 : v }
        return Vec3(s(p.x, n.x), s(p.y, n.y), s(p.z, n.z))
    }

    /// Red preview: bore and head circles on the face, and the axis.
    func overlay() -> [(SIMD3<Float>, SIMD3<Float>, SIMD4<Float>)] {
        guard let n = normal else { return [] }
        let red = SIMD4<Float>(0.95, 0.25, 0.25, 1), faint = SIMD4<Float>(0.95, 0.25, 0.25, 0.55)
        let helper = abs(n.z) < 0.9 ? Vec3(0, 0, 1) : Vec3(1, 0, 0)
        let u = helper.cross(n).normalized, v = n.cross(u)
        func f(_ p: Vec3) -> SIMD3<Float> { SIMD3(Float(p.x), Float(p.y), Float(p.z)) }
        var out: [(SIMD3<Float>, SIMD3<Float>, SIMD4<Float>)] = []
        for c in centers {
            for (r, color) in [(bore / 2, red), (head / 2, faint)] where r > 0 {
                let pts = (0...48).map { k -> Vec3 in
                    let t = Double(k) / 48 * 2 * .pi
                    return c + n * 0.02 + (u * cos(t) + v * sin(t)) * r
                }
                for (a, b) in zip(pts, pts.dropFirst()) { out.append((f(a), f(b), color)) }
            }
            out.append((f(c + n * 1.5), f(c - n * (depth ?? 20)), faint))
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
            ]
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
                        if let i = doc.features.firstIndex(where: { $0.id == id }) { doc.features[i].kind = .hole(s) }
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
        preview(session.fields)
        return session
    }
}
