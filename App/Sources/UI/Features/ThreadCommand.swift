import CADCore
import SwiftUI

/// «Filetto» (Fusion's Thread, modelled): click a cylindrical face — a shaft for a screw thread,
/// a hole's wall for a nut thread — the ISO size follows its diameter (or is chosen), with the
/// print clearance. Live preview; OK = one undo step.
@MainActor
enum ThreadCommand {
    static let sizes = ["Dal diametro"] + MetricScrew.all.map(\.name)

    static func start(workspace: WorkspaceState, model: DesignModel, editing original: Feature? = nil) -> CommandSession {
        workspace.selectionFilter = .face
        workspace.geoSelection.removeAll { if case .face = $0.kind { false } else { true } }
        var fixed: ThreadSpec?
        if let original, case let .thread(spec) = original.kind { fixed = spec }
        weak var session: CommandSession?

        /// The cylindrical face picked (the last one clicked), with its body's snapshot.
        func picked() -> (FaceID, SurfaceDescriptor)? {
            if let fixed {
                let body = model.evaluation().bodies.first { $0.snapshot.faces.contains { $0.id == fixed.face } }
                return body?.snapshot.faces.first { $0.id == fixed.face }.map { ($0.id, $0.surface) }
            }
            for ref in workspace.geoSelection.reversed() {
                guard case let .face(id) = ref.kind,
                      let face = model.evaluation().bodies.first(where: { $0.id == ref.feature })?.snapshot.faces.first(where: { $0.id == id }),
                      case .cylinder = face.surface else { continue }
                return (id, face.surface)
            }
            return nil
        }
        func spec(_ f: [CommandField]) -> ThreadSpec? {
            guard let (face, _) = picked() else { return nil }
            var s = ThreadSpec(face: face)
            if case let .index(i)? = f.first(where: { $0.id == "size" })?.value, i > 0 { s.size = sizes[i] }
            s.printAllowance = f.first { $0.id == "allow" }?.number ?? 0.2
            return s
        }
        func document(_ s: ThreadSpec) -> (CADDocument, Feature) {
            var doc = model.document
            if let original, let i = doc.features.firstIndex(where: { $0.id == original.id }) {
                doc.features[i].kind = .thread(s)
                return (doc, doc.features[i])
            }
            let f = Feature(name: "Filetto \(s.size ?? "")".trimmingCharacters(in: .whitespaces), kind: .thread(s))
            doc.features.append(f)
            return (doc, f)
        }
        func preview(_ f: [CommandField]) {
            let face = picked()
            session?.update("face") { $0.value = .references(face.map { [$0.0.rawValue] } ?? []) }
            session?.update("what") {
                guard let (_, surface) = face, case let .cylinder(_, _, r) = surface else {
                    $0.label = "Clicca una faccia cilindrica: un perno (filetto esterno) o la parete di un foro (interno)."
                    return
                }
                let auto = ThreadSpec.size(forDiameter: 2 * r, inside: false)?.name ?? "—"
                $0.label = String(format: "Ø %.2f mm · misura dal diametro: %@ (su un foro vale il diametro di nocciolo)", 2 * r, auto)
            }
            guard let s = spec(f) else { workspace.requestPreview(nil); return }
            workspace.requestPreview(document(s).0)
        }
        func finish() {
            workspace.onGeoSelectionChange = nil
            workspace.requestPreview(nil)
        }
        let initialSize = fixed?.size.flatMap { sizes.firstIndex(of: $0) } ?? 0
        let created = CommandSession(
            title: original == nil ? "Filetto" : "Modifica \(original!.name)", symbol: "screwdriver",
            fields: [
                .init(id: "face", label: "Faccia", kind: .reference(prompt: "Clicca un cilindro", maxCount: 1), value: .references([]),
                      help: "Un perno o una sporgenza tonda (filetto esterno, vite) o la parete di un foro (filetto interno, madrevite)"),
                .init(id: "size", label: "Misura", kind: .choice(sizes), value: .index(initialSize),
                      help: "Filetto metrico ISO a passo grosso; «Dal diametro» sceglie quella del cilindro"),
                .init(id: "allow", label: "Compensazione stampa", kind: .length(0...2), value: .number(fixed?.printAllowance ?? 0.2),
                      help: "Gioco per la stampa: un filetto esterno si assottiglia, uno interno si allarga (tipico 0,2–0,4 mm in FDM)"),
                .init(id: "what", label: "", kind: .note(warning: false), value: .flag(false)),
            ],
            onPreview: preview,
            onCommit: { f in
                defer { finish() }
                guard let s = spec(f) else { model.statusMessage = "Clicca una faccia cilindrica da filettare."; return }
                let (doc, feature) = document(s)
                if let issue = DesignEvaluator.evaluate(doc, revision: "check").issues.first(where: { $0.featureID == feature.id }) {
                    model.statusMessage = "Filetto non riuscito: \(issue.message)"
                    return
                }
                model.edit(original == nil ? feature.name : "Modifica \(feature.name)", selected: .some(feature.id), changed: [feature.id]) { $0 = doc }
                workspace.geoSelection = []
            },
            onCancel: { finish() })
        session = created
        workspace.onGeoSelectionChange = { preview(created.fields) }
        preview(created.fields)
        return created
    }
}
