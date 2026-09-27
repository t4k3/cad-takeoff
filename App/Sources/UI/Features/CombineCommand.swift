import CADCore
import SwiftUI

/// Combina (Fusion's Combine): the selected body is the target; the tools are ticked among the
/// other bodies; join, cut or intersect, tools kept or not. Live preview; a timeline step.
@MainActor
enum CombineCommand {
    static let operations = CombineSpec.Operation.allCases

    static func start(workspace: WorkspaceState, model: DesignModel, editing feature: Feature? = nil) -> CommandSession? {
        let bodies = model.evaluation().bodies.map(\.id)
        let names = Dictionary(model.document.features.map { ($0.id, $0.name) }, uniquingKeysWith: { a, _ in a })
        var spec: CombineSpec
        if let feature, case let .combine(existing) = feature.kind {
            spec = existing
        } else {
            guard let id = model.selection, bodies.contains(id) else {
                model.statusMessage = "Seleziona prima il corpo da modificare (l'obiettivo)."
                return nil
            }
            spec = CombineSpec(target: id, tools: [], operation: .join)
        }
        // Bodies that exist before this step (editing: also the ones it removed, i.e. its tools).
        let candidates = (bodies + spec.tools + [spec.target]).reduce(into: [UUID]()) { if !$0.contains($1) { $0.append($1) } }
        guard candidates.count > 1 else {
            model.statusMessage = "Combina vuole almeno due corpi."
            return nil
        }
        let original = feature
        func name(_ id: UUID) -> String { names[id] ?? "corpo" }
        var fields: [CommandField] = [
            .init(id: "target", label: "Obiettivo", kind: .choice(candidates.map(name)), value: .index(candidates.firstIndex(of: spec.target) ?? 0),
                  help: "Il corpo che cambia"),
            .init(id: "operation", label: "Operazione", kind: .choice(operations.map(\.label)), value: .index(operations.firstIndex(of: spec.operation) ?? 0)),
            .init(id: "keep", label: "Mantieni strumenti", kind: .toggle, value: .flag(spec.keepTools),
                  help: "Gli strumenti restano corpi a sé"),
            .init(id: "note", label: "Strumenti:", kind: .note(warning: false), value: .flag(false)),
        ]
        for id in candidates {
            fields.append(.init(id: "tool:" + id.uuidString, label: name(id), kind: .toggle, value: .flag(spec.tools.contains(id))))
        }
        func read(_ f: [CommandField]) -> CombineSpec {
            var s = spec
            if case let .index(i)? = f.first(where: { $0.id == "target" })?.value { s.target = candidates[min(i, candidates.count - 1)] }
            if case let .index(i)? = f.first(where: { $0.id == "operation" })?.value { s.operation = operations[min(i, operations.count - 1)] }
            if case let .flag(k)? = f.first(where: { $0.id == "keep" })?.value { s.keepTools = k }
            s.tools = candidates.filter { id in
                if case .flag(true)? = f.first(where: { $0.id == "tool:" + id.uuidString })?.value { id != s.target } else { false }
            }
            return s
        }
        func document(with s: CombineSpec) -> (CADDocument, Feature) {
            var doc = model.document
            if let original, let i = doc.features.firstIndex(where: { $0.id == original.id }) {
                doc.features[i].kind = .combine(s)
                return (doc, doc.features[i])
            }
            let f = Feature(name: "Combina " + name(s.target), kind: .combine(s), color: doc.features.first { $0.id == s.target }?.color ?? .defaultColor)
            doc.features.append(f)
            return (doc, f)
        }
        let created = CommandSession(
            title: original == nil ? "Combina" : "Modifica \(original!.name)", symbol: "square.on.square.intersection.dashed",
            fields: fields,
            onPreview: { f in
                let s = read(f)
                guard !s.tools.isEmpty else { workspace.requestPreview(nil); return }
                workspace.requestPreview(document(with: s).0)
            },
            onCommit: { f in
                defer { workspace.requestPreview(nil) }
                let s = read(f)
                guard !s.tools.isEmpty else { model.statusMessage = "Combina: spunta almeno un corpo strumento."; return }
                let (doc, feature) = document(with: s)
                model.edit(original == nil ? feature.name : "Modifica \(feature.name)", selected: .some(s.target), changed: [feature.id]) { $0 = doc }
                if let issue = model.evaluation().issues.first(where: { $0.featureID == feature.id }) { model.statusMessage = issue.message }
            },
            onCancel: { workspace.requestPreview(nil) })
        if !spec.tools.isEmpty { workspace.requestPreview(document(with: spec).0) }
        return created
    }
}
