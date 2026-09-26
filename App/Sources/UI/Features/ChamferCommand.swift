import CADCore
import SwiftUI

/// Chamfer panel (T85): pick edges in the viewport (each click adds or removes one), then
/// equal distance, two distances or distance + angle.
@MainActor
enum ChamferCommand {
    static let modes = ChamferSpec.Mode.allCases

    static func start(workspace: WorkspaceState, model: DesignModel, editing feature: Feature? = nil) -> CommandSession {
        var spec = ChamferSpec(edges: [])
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

        let fields: [CommandField] = [
            .init(id: "edges", label: "Spigoli", kind: .reference(prompt: "Clicca gli spigoli", maxCount: 500), value: edgeValue(),
                  help: original == nil ? "Clicca uno spigolo per aggiungerlo, cliccalo di nuovo per toglierlo" : "Gli spigoli restano quelli scelti alla creazione"),
            .init(id: "mode", label: "Tipo", kind: .choice(modes.map(\.label)), value: .index(modes.firstIndex(of: spec.mode) ?? 0)),
            .init(id: "d", label: "Distanza", kind: .length(0.01...1000), value: .number(spec.distance)),
            .init(id: "d2", label: "Distanza 2", kind: .length(0.01...1000), value: .number(spec.distance2),
                  help: "Usata con «Due distanze»: arretramento sulla seconda faccia"),
            .init(id: "angle", label: "Angolo", kind: .angle(1...89), value: .number(spec.angle),
                  help: "Usato con «Distanza e angolo»: angolo tra lo smusso e la prima faccia"),
            .init(id: "flip", label: "Inverti lati", kind: .toggle, value: .flag(spec.flip),
                  help: "Scambia le due facce (conta con «Due distanze» e «Distanza e angolo»)"),
        ]

        func read(_ f: [CommandField]) -> ChamferSpec {
            var s = spec
            func num(_ id: String) -> Double { f.first { $0.id == id }?.number ?? 0 }
            if case let .index(i)? = f.first(where: { $0.id == "mode" })?.value { s.mode = modes[i] }
            s.distance = num("d"); s.distance2 = num("d2"); s.angle = num("angle")
            if case let .flag(v)? = f.first(where: { $0.id == "flip" })?.value { s.flip = v }
            if original == nil { s.edges = pickedEdges() }
            return s
        }

        /// Editing an existing chamfer: live preview on the design (like the other edit panels).
        func apply(_ f: [CommandField]) {
            guard let original, f.allSatisfy({ $0.validationMessage == nil }),
                  let i = model.document.features.firstIndex(where: { $0.id == original.id }) else { return }
            let s = read(f)
            guard (try? s.validate()) != nil else { return }
            model.document.features[i].kind = .chamfer(s)
            // An automatic name ("Smusso 1 mm ×2") follows the new size; a name typed by the user stays.
            if original.name == "Smusso " + spec.summary { model.document.features[i].name = "Smusso " + s.summary }
        }

        func finish() { workspace.edgePicking = false; workspace.onGeoSelectionChange = nil }

        let session = CommandSession(
            title: original == nil ? "Smusso" : "Modifica \(original!.name)", symbol: "skew",
            fields: fields,
            onPreview: apply,
            onCommit: { f in
                defer { finish() }
                let s = read(f)
                do { try s.validate() } catch {
                    model.statusMessage = s.edges.isEmpty ? "Smusso non creato: scegli almeno uno spigolo."
                        : "Smusso non valido: \(error.localizedDescription)"
                    return
                }
                if let original {
                    apply(f)
                    if let issue = model.evaluation().issues.last(where: { $0.featureID == original.id }) { model.statusMessage = issue.message }
                    return
                }
                let chamfer = Feature(name: "Smusso " + s.summary, kind: .chamfer(s), operation: .cut)
                model.edit("Smusso " + s.summary, selected: .some(nil), changed: [chamfer.id]) { $0.features.append(chamfer) }
                workspace.geoSelection = []
                let problems = Set(model.evaluation().issues.filter { $0.featureID == chamfer.id }.map(\.message))
                if !problems.isEmpty { model.statusMessage = problems.sorted().joined(separator: " · ") }
            },
            onCancel: {
                finish()
                if let original, let i = model.document.features.firstIndex(where: { $0.id == original.id }) {
                    model.document.features[i] = original
                }
            })
        // The edge count in the panel follows the viewport selection.
        workspace.onGeoSelectionChange = { [weak session] in
            guard let session, let i = session.fields.firstIndex(where: { $0.id == "edges" }) else { return }
            session.fields[i].value = edgeValue()
        }
        return session
    }
}
