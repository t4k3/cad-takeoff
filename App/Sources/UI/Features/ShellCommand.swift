import CADCore
import SwiftUI

/// «Guscio» (Fusion's Shell): click the faces to leave open (the top of a box), set the wall
/// thickness; with no face the selected body is hollowed closed. Live preview; OK = one undo step.
@MainActor
enum ShellCommand {
    static func start(workspace: WorkspaceState, model: DesignModel) -> CommandSession {
        workspace.selectionFilter = .face
        workspace.geoSelection.removeAll { if case .face = $0.kind { false } else { true } }
        workspace.edgePicking = true
        let selectedBody = model.selection
        weak var session: CommandSession?

        func picked() -> (body: UUID?, faces: [FaceID]) {
            var body: UUID?
            var faces: [FaceID] = []
            for ref in workspace.geoSelection {
                guard case let .face(id) = ref.kind else { continue }
                if body == nil { body = ref.feature }
                if ref.feature == body { faces.append(id) }   // one body at a time
            }
            return (body ?? selectedBody, faces)
        }
        func thickness(_ f: [CommandField]) -> Double { f.first { $0.id == "t" }?.number ?? 2 }
        func feature(_ f: [CommandField]) -> Feature? {
            let (body, faces) = picked()
            guard let body else { return nil }
            return Feature(name: "Guscio \(model.document.features.count + 1)",
                           kind: .shell(ShellSpec(body: body, thickness: thickness(f), openFaces: faces)))
        }
        func preview(_ f: [CommandField]) {
            let (body, faces) = picked()
            session?.update("faces") { $0.value = .references(faces.map(\.rawValue)) }
            session?.update("what") {
                $0.label = body == nil ? "Clicca le facce da lasciare aperte, o seleziona prima un corpo per un guscio chiuso."
                    : faces.isEmpty ? "Nessuna faccia aperta: il corpo diventa cavo e chiuso." : "\(faces.count) facc\(faces.count == 1 ? "ia aperta" : "e aperte")."
            }
            guard let shell = feature(f) else { workspace.requestPreview(nil); return }
            var doc = model.document
            doc.features.append(shell)
            workspace.requestPreview(doc)
        }
        func finish() {
            workspace.onGeoSelectionChange = nil
            workspace.edgePicking = false
            workspace.requestPreview(nil)
        }
        let created = CommandSession(
            title: "Guscio", symbol: "cube.transparent",
            fields: [
                .init(id: "faces", label: "Facce aperte", kind: .reference(prompt: "Clicca le facce", maxCount: 100), value: .references([]),
                      help: "Le facce da togliere (per esempio il sopra di una scatola). Nessuna: guscio chiuso del corpo selezionato"),
                .init(id: "t", label: "Spessore", kind: .length(0.05...1000), value: .number(2), help: "Spessore delle pareti, verso l'interno"),
                .init(id: "what", label: "", kind: .note(warning: false), value: .flag(false)),
            ],
            onPreview: preview,
            onCommit: { f in
                defer { finish() }
                guard let shell = feature(f) else { model.statusMessage = "Clicca le facce da aprire o seleziona un corpo."; return }
                var doc = model.document
                doc.features.append(shell)
                if let issue = DesignEvaluator.evaluate(doc, revision: "check").issues.first(where: { $0.featureID == shell.id }) {
                    model.statusMessage = "Guscio non riuscito: \(issue.message)"
                    return
                }
                model.edit("Guscio \(fmt(thickness(f))) mm", selected: .some(shell.id), changed: [shell.id]) { $0.features.append(shell) }
                workspace.geoSelection = []
            },
            onCancel: { finish() })
        session = created
        workspace.onGeoSelectionChange = { preview(created.fields) }
        preview(created.fields)
        return created
    }

    /// An existing shell: its thickness (the open faces stay as chosen).
    static func edit(_ original: Feature, workspace: WorkspaceState, model: DesignModel) -> CommandSession? {
        guard case let .shell(spec) = original.kind else { return nil }
        func apply(_ f: [CommandField]) {
            guard let i = model.document.features.firstIndex(where: { $0.id == original.id }) else { return }
            var s = spec
            s.thickness = f.first { $0.id == "t" }?.number ?? spec.thickness
            model.document.features[i].kind = .shell(s)
        }
        return CommandSession(
            title: "Modifica \(original.name)", symbol: "cube.transparent",
            fields: [.init(id: "t", label: "Spessore", kind: .length(0.05...1000), value: .number(spec.thickness)),
                     .init(id: "note", label: "\(spec.openFaces.count) facce aperte", kind: .note(warning: false), value: .flag(false))],
            onPreview: apply, onCommit: apply,
            onCancel: {
                if let i = model.document.features.firstIndex(where: { $0.id == original.id }) { model.document.features[i] = original }
            })
    }
}
