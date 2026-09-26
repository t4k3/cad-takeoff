import CADCore
import SwiftUI

/// Round / chamfer panel ("Raccordo", T85–T86: one command for both shapes): pick edges in the viewport (each click adds or removes one),
/// choose flat (chamfer) or round (fillet), set the size in the panel or with the drag arrow.
/// The result is previewed live; the design changes only on OK (one undo step).
@MainActor
enum ChamferCommand {
    static let modes = ChamferSpec.Mode.allCases
    static let profiles = ChamferSpec.Profile.allCases

    static func start(workspace: WorkspaceState, model: DesignModel, editing feature: Feature? = nil,
                      profile: ChamferSpec.Profile = .flat) -> CommandSession {
        var spec = ChamferSpec(edges: [], profile: profile)
        if let feature, case let .chamfer(existing) = feature.kind { spec = existing }
        let original = feature
        if original == nil {
            // Edge picking; an edge selection made before opening the panel is kept.
            if workspace.selectionFilter != .edge { workspace.selectionFilter = .edge }
            workspace.geoSelection.removeAll { if case .edge = $0.kind { false } else { true } }
            workspace.edgePicking = true
        }

        /// Selected edges as references that survive re-evaluation.
        func pickedEdges() -> [EdgeRef] {
            let bodies = model.evaluation().bodies
            return workspace.geoSelection.compactMap { ref -> EdgeRef? in
                guard case let .edge(id) = ref.kind,
                      let e = bodies.first(where: { $0.id == ref.feature })?.snapshot.edges.first(where: { $0.id == id }) else { return nil }
                return EdgeRef(e)
            }
        }
        func edgeValue() -> CommandField.Value {
            original == nil ? .references(workspace.geoSelection.map { "\($0)" }) : .references(spec.edges.map { "\($0.point)" })
        }

        /// Where the drag arrow goes: the first edge, on the design as it is before this feature.
        func handleEdge() -> (EdgeInfo, BodySnapshot)? {
            if original == nil {
                let bodies = model.evaluation().bodies
                for ref in workspace.geoSelection {
                    guard case let .edge(id) = ref.kind, let b = bodies.first(where: { $0.id == ref.feature }),
                          let e = b.snapshot.edges.first(where: { $0.id == id }) else { continue }
                    return (e, b.snapshot)
                }
                return nil
            }
            guard let first = spec.edges.first, let original,
                  let at = model.document.timeline.firstIndex(where: { $0.id == original.id }) else { return nil }
            var before = model.document
            before.rollback = at
            for b in DesignEvaluator.evaluate(before, revision: "handle", components: model.componentResolver).bodies {
                if let e = ChamferGeometry.resolve(first, in: b.snapshot) { return (e, b.snapshot) }
            }
            return nil
        }
        let editHandle = original == nil ? nil : handleEdge()

        let fields: [CommandField] = [
            .init(id: "edges", label: "Spigoli", kind: .reference(prompt: "Clicca gli spigoli", maxCount: 500), value: edgeValue(),
                  help: original == nil ? "Clicca uno spigolo per aggiungerlo, cliccalo di nuovo per toglierlo" : "Gli spigoli restano quelli scelti alla creazione"),
            .init(id: "chain", label: "Catena tangente", kind: .toggle, value: .flag(true),
                  help: "Un clic prende anche gli spigoli che proseguono in tangenza (il contorno di un'asola, il bordo di un cerchio)",
                  isHidden: original != nil),
            .init(id: "profile", label: "Forma", kind: .choice(profiles.map(\.label)), value: .index(profiles.firstIndex(of: spec.profile) ?? 0),
                  help: "Piatto: smusso a 45° o con due distanze/angolo. Tondo: raccordo a raggio costante."),
            .init(id: "mode", label: "Misura", kind: .choice(modes.map(\.label)), value: .index(modes.firstIndex(of: spec.mode) ?? 0),
                  help: "Solo per la forma piatta"),
            .init(id: "d", label: spec.profile == .round ? "Raggio" : "Distanza", kind: .length(0.01...1000), value: .number(spec.distance),
                  help: "Puoi anche trascinare la freccia sullo spigolo"),
            .init(id: "d2", label: "Distanza 2", kind: .length(0.01...1000), value: .number(spec.distance2),
                  help: "Solo con «Due distanze»: arretramento sulla seconda faccia"),
            .init(id: "angle", label: "Angolo", kind: .angle(1...89), value: .number(spec.angle),
                  help: "Solo con «Distanza e angolo»: angolo tra lo smusso e la prima faccia"),
            .init(id: "flip", label: "Inverti lati", kind: .toggle, value: .flag(spec.flip),
                  help: "Scambia le due facce (conta con «Due distanze» e «Distanza e angolo»)"),
        ]

        func read(_ f: [CommandField]) -> ChamferSpec {
            var s = spec
            func num(_ id: String) -> Double { f.first { $0.id == id }?.number ?? 0 }
            if case let .index(i)? = f.first(where: { $0.id == "profile" })?.value { s.profile = profiles[i] }
            if case let .index(i)? = f.first(where: { $0.id == "mode" })?.value { s.mode = modes[i] }
            s.distance = num("d"); s.distance2 = num("d2"); s.angle = num("angle")
            if case let .flag(v)? = f.first(where: { $0.id == "flip" })?.value { s.flip = v }
            if original == nil { s.edges = pickedEdges() }
            return s
        }

        /// The design with this chamfer applied (added, or replacing the edited one).
        func document(with s: ChamferSpec) -> (CADDocument, Feature) {
            var doc = model.document
            if let original, let i = doc.features.firstIndex(where: { $0.id == original.id }) {
                var f = doc.features[i]
                f.kind = .chamfer(s)
                // An automatic name ("Smusso 1 mm ×2") follows the new size; a name typed by the user stays.
                if original.name == spec.title { f.name = s.title }
                doc.features[i] = f
                return (doc, f)
            }
            let f = Feature(name: s.title, kind: .chamfer(s), operation: .cut)
            doc.features.append(f)
            return (doc, f)
        }

        var session: CommandSession!

        func updateArrow(_ s: ChamferSpec) {
            guard let (edge, snapshot) = editHandle ?? handleEdge(),
                  let h = ChamferGeometry.handle(for: edge, in: snapshot) else { workspace.manipulator = nil; return }
            let factor = s.profile == .round ? h.round : h.flat
            let label = s.profile == .round ? "R" : "D"
            if let m = workspace.manipulator {
                m.origin = h.origin; m.inward = h.inward; m.factor = factor; m.label = label
                m.range = 0.1...max(0.1, (h.limit * 10).rounded(.down) / 10)
                if !m.isDragging { m.value = s.distance }
            } else {
                let m = DistanceManipulator(origin: h.origin, inward: h.inward, factor: factor, value: s.distance,
                                            range: 0.1...max(0.1, (h.limit * 10).rounded(.down) / 10), label: label)
                m.onChange = { [weak session] v in
                    guard let session, let i = session.fields.firstIndex(where: { $0.id == "d" }) else { return }
                    session.fields[i].value = .number(v)
                }
                workspace.manipulator = m
            }
        }

        func preview(_ f: [CommandField]) {
            let s = read(f)
            // Field label follows the shape.
            if let session, let i = session.fields.firstIndex(where: { $0.id == "d" }) {
                let label = s.profile == .round ? "Raggio" : "Distanza"
                if session.fields[i].label != label { session.fields[i].label = label }
            }
            updateArrow(s)
            guard f.allSatisfy({ $0.validationMessage == nil }), (try? s.validate()) != nil else {
                workspace.requestPreview(nil); return
            }
            workspace.requestPreview(document(with: s).0)
        }

        func finish() {
            workspace.edgePicking = false
            workspace.onGeoSelectionChange = nil
            workspace.manipulator = nil
            workspace.requestPreview(nil)
        }

        session = CommandSession(
            title: original == nil ? "Raccordo" : "Modifica \(original!.name)",
            symbol: "circle.bottomhalf.filled",
            fields: fields,
            onPreview: preview,
            onCommit: { f in
                defer { finish() }
                let s = read(f)
                do { try s.validate() } catch {
                    model.statusMessage = s.edges.isEmpty ? "Scegli almeno uno spigolo."
                        : "\(s.profile == .round ? "Raccordo" : "Smusso") non valido: \(error.localizedDescription)"
                    return
                }
                let (doc, feature) = document(with: s)
                model.edit(original == nil ? s.title : "Modifica \(feature.name)", selected: .some(original == nil ? nil : feature.id),
                           changed: [feature.id]) { $0 = doc }
                if original == nil { workspace.geoSelection = [] }
                let problems = Set(model.evaluation().issues.filter { $0.featureID == feature.id }.map(\.message))
                if !problems.isEmpty { model.statusMessage = problems.sorted().joined(separator: " · ") }
            },
            onCancel: { finish() })
        // Tangent chain: a clicked edge brings the edges it runs on into smoothly; unclicking one
        // takes its chain away.
        var lastSelection = Set(workspace.geoSelection)
        func chain(_ ref: GeoRef) -> [GeoRef] {
            guard case let .edge(id) = ref.kind,
                  let body = model.evaluation().bodies.first(where: { $0.id == ref.feature }) else { return [ref] }
            return body.snapshot.tangentChain(of: id).map { GeoRef(feature: ref.feature, kind: .edge($0)) }
        }
        func chainOn() -> Bool {
            if case let .flag(on)? = session?.fields.first(where: { $0.id == "chain" })?.value { on } else { false }
        }
        func expandChains() {
            let current = workspace.geoSelection
            guard original == nil, chainOn() else { lastSelection = Set(current); return }
            let added = current.filter { !lastSelection.contains($0) }
            let removed = lastSelection.filter { !current.contains($0) }
            var next = current
            for r in removed { let gone = Set(chain(r)); next.removeAll { gone.contains($0) } }
            for r in added { for c in chain(r) where !next.contains(c) { next.append(c) } }
            lastSelection = Set(next)
            if next != current { workspace.geoSelection = next }
        }
        // The edge count, the arrow and the preview follow the viewport selection.
        workspace.onGeoSelectionChange = { [weak session] in
            expandChains()
            guard let session, let i = session.fields.firstIndex(where: { $0.id == "edges" }) else { return }
            session.fields[i].value = edgeValue()
        }
        preview(session.fields)
        return session
    }
}
