import CADCore
import SwiftUI

/// Dividi (T89): cut the selected body with a plane parallel to YZ, XZ or XY; live preview.
@MainActor
enum SplitCommand {
    static let planes = PatternSpec.MirrorPlane.allCases
    static let keeps = SplitSpec.Keep.allCases
    static let planeLabels = ["Piano YZ (taglio lungo X)", "Piano XZ (taglio lungo Y)", "Piano XY (taglio in altezza)"]

    static func start(workspace: WorkspaceState, model: DesignModel, editing feature: Feature? = nil) -> CommandSession? {
        var spec: SplitSpec
        if let feature, case let .split(existing) = feature.kind {
            spec = existing
        } else {
            guard let id = model.selection, let body = model.evaluation().bodies.first(where: { $0.id == id }),
                  let b = body.mesh.bounds else {
                model.statusMessage = "Seleziona prima il corpo da dividere."
                return nil
            }
            spec = SplitSpec(body: id, plane: .xy, offset: (b.min.z + b.max.z) / 2)   // halfway up
        }
        let original = feature
        let sourceName = model.document.features.first { $0.id == spec.body }?.name ?? "corpo"
        let fields: [CommandField] = [
            .init(id: "note", label: "Divide «\(sourceName)»", kind: .note(warning: false), value: .flag(false)),
            .init(id: "plane", label: "Piano", kind: .choice(planeLabels), value: .index(planes.firstIndex(of: spec.plane) ?? 2)),
            .init(id: "offset", label: "Posizione", kind: .length(-100_000...100_000), value: .number(spec.offset),
                  help: "Coordinata del piano (X, Y o Z secondo il piano)"),
            .init(id: "keep", label: "Tieni", kind: .choice(keeps.map(\.label)), value: .index(keeps.firstIndex(of: spec.keep) ?? 0),
                  help: "Entrambe: la parte dal lato + diventa un corpo nuovo (es. per stampare un pezzo più grande del piatto)"),
        ]
        func read(_ f: [CommandField]) -> SplitSpec {
            var s = spec
            if case let .index(i)? = f.first(where: { $0.id == "plane" })?.value { s.plane = planes[min(i, planes.count - 1)] }
            if case let .index(i)? = f.first(where: { $0.id == "keep" })?.value { s.keep = keeps[min(i, keeps.count - 1)] }
            s.offset = f.first { $0.id == "offset" }?.number ?? 0
            return s
        }
        func document(with s: SplitSpec) -> (CADDocument, Feature) {
            var doc = model.document
            if let original, let i = doc.features.firstIndex(where: { $0.id == original.id }) {
                doc.features[i].kind = .split(s)
                return (doc, doc.features[i])
            }
            let colour = doc.features.first { $0.id == s.body }?.color ?? .defaultColor
            let f = Feature(name: "Dividi " + sourceName, kind: .split(s), color: colour)
            doc.features.append(f)
            return (doc, f)
        }
        let created = CommandSession(
            title: original == nil ? "Dividi" : "Modifica \(original!.name)", symbol: "rectangle.split.2x1",
            fields: fields,
            onPreview: { f in
                guard f.allSatisfy({ $0.validationMessage == nil }) else { workspace.requestPreview(nil); return }
                workspace.requestPreview(document(with: read(f)).0)
            },
            onCommit: { f in
                defer { workspace.requestPreview(nil) }
                let (doc, feature) = document(with: read(f))
                model.edit(original == nil ? feature.name : "Modifica \(feature.name)", selected: .some(feature.id), changed: [feature.id]) { $0 = doc }
                if let issue = model.evaluation().issues.first(where: { $0.featureID == feature.id }) { model.statusMessage = issue.message }
            },
            onCancel: { workspace.requestPreview(nil) })
        workspace.requestPreview(document(with: spec).0)
        return created
    }
}
