import CADCore
import SwiftUI

/// Serie (rectangular/circular) and Specchio of the selected body (T88), live preview.
@MainActor
enum PatternCommand {
    static let planes = PatternSpec.MirrorPlane.allCases

    static func start(workspace: WorkspaceState, model: DesignModel, kind: PatternSpec.Kind, editing feature: Feature? = nil) -> CommandSession? {
        var spec: PatternSpec
        if let feature, case let .pattern(existing) = feature.kind {
            spec = existing
        } else {
            // The body of the selection, or a feature that cuts or adds (a hole, a pocket, a boss):
            // then its operation is what gets repeated.
            let isTool: (UUID) -> Bool = { id in
                guard let f = model.document.features.first(where: { $0.id == id }) else { return false }
                if case .hole = f.kind { return true }
                return f.operation != .newBody
            }
            guard let id = model.selection, model.evaluation().bodies.contains(where: { $0.id == id }) || isTool(id) else {
                model.statusMessage = "Seleziona prima il corpo, il foro o il taglio da \(kind == .mirror ? "specchiare" : "ripetere")."
                return nil
            }
            spec = PatternSpec(body: id, kind: kind)
            if kind == .mirror, let b = model.evaluation().bodies.first(where: { $0.id == id })?.mesh.bounds {
                spec.offset = b.min.x   // mirror about its left face: a symmetric part in one click
            }
        }
        let original = feature
        // Specchio on a clicked face that is not parallel to YZ/XZ/XY: its normal.
        var faceNormal = spec.mirrorNormal
        let planeChoices = planes.map(\.label) + ["Faccia cliccata"]
        let sourceName = model.document.features.first { $0.id == spec.body }?.name ?? "corpo"
        let fields: [CommandField]
        switch spec.kind {
        case .rectangular, .circular:
            fields = [
                .init(id: "note", label: "Copia di «\(sourceName)»", kind: .note(warning: false), value: .flag(false)),
                .init(id: "kind", label: "Tipo", kind: .choice(["Rettangolare", "Circolare"]), value: .index(spec.kind == .circular ? 1 : 0)),
                .init(id: "nx", label: "Numero in X", kind: .count(1...100), value: .number(Double(spec.countX))),
                .init(id: "dx", label: "Passo X", kind: .length(-10_000...10_000), value: .number(spec.spacingX)),
                .init(id: "ny", label: "Numero in Y", kind: .count(1...100), value: .number(Double(spec.countY))),
                .init(id: "dy", label: "Passo Y", kind: .length(-10_000...10_000), value: .number(spec.spacingY)),
                .init(id: "n", label: "Numero", kind: .count(2...360), value: .number(Double(spec.count))),
                .init(id: "angle", label: "Angolo totale", kind: .angle(-360...360), value: .number(spec.angle),
                      help: "360° = copie distribuite su tutto il giro"),
                .init(id: "cx", label: "Asse in X", kind: .length(-100_000...100_000), value: .number(spec.center.x),
                      help: "Asse verticale (Z) della serie circolare"),
                .init(id: "cy", label: "Asse in Y", kind: .length(-100_000...100_000), value: .number(spec.center.y)),
                .init(id: "join", label: "Unisci al corpo originale", kind: .toggle, value: .flag(spec.join)),
            ]
        case .mirror:
            fields = [
                .init(id: "note", label: "Specchio di «\(sourceName)»", kind: .note(warning: false), value: .flag(false)),
                .init(id: "face", label: "Clicca una faccia piana del pezzo per specchiare su di lei", kind: .note(warning: false), value: .flag(false)),
                .init(id: "plane", label: "Piano", kind: .choice(planeChoices),
                      value: .index(spec.mirrorNormal != nil ? planes.count : planes.firstIndex(of: spec.plane) ?? 0)),
                .init(id: "offset", label: "Posizione del piano", kind: .length(-100_000...100_000), value: .number(spec.offset),
                      help: "Coordinata del piano lungo l'asse che specchia (es. X = … per il piano YZ); per una faccia inclinata, la distanza del piano dall'origine lungo la sua normale"),
                .init(id: "join", label: "Unisci al corpo originale", kind: .toggle, value: .flag(spec.join),
                      help: "Utile per pezzi simmetrici: disegni metà e specchi sulla faccia di mezzeria"),
            ]
        }

        func idx(_ f: [CommandField], _ id: String) -> Int { if case let .index(i)? = f.first(where: { $0.id == id })?.value { i } else { 0 } }
        func read(_ f: [CommandField]) -> PatternSpec {
            func num(_ id: String) -> Double { f.first { $0.id == id }?.number ?? 0 }
            func idx(_ id: String) -> Int { if case let .index(i)? = f.first(where: { $0.id == id })?.value { i } else { 0 } }
            var s = spec
            if s.kind != .mirror { s.kind = idx("kind") == 1 ? .circular : .rectangular }
            s.countX = Int(num("nx")); s.spacingX = num("dx"); s.countY = Int(num("ny")); s.spacingY = num("dy")
            s.count = Int(num("n")); s.angle = num("angle"); s.center = Vec3(num("cx"), num("cy"), 0)
            if s.kind == .mirror {
                let i = idx("plane")
                if i >= planes.count { s.mirrorNormal = faceNormal } else { s.plane = planes[i]; s.mirrorNormal = nil }
                s.offset = num("offset")
            }
            if case let .flag(b)? = f.first(where: { $0.id == "join" })?.value { s.join = b }
            return s
        }

        func document(with s: PatternSpec) -> (CADDocument, Feature) {
            var doc = model.document
            if let original, let i = doc.features.firstIndex(where: { $0.id == original.id }) {
                doc.features[i].kind = .pattern(s)
                return (doc, doc.features[i])
            }
            let colour = doc.features.first { $0.id == s.body }?.color ?? .defaultColor
            let f = Feature(name: (s.kind == .mirror ? "Specchio " : "Serie ") + sourceName, kind: .pattern(s), color: colour)
            doc.features.append(f)
            return (doc, f)
        }

        weak var session: CommandSession?
        func preview(_ f: [CommandField]) {
            let s = read(f)
            if let session, s.kind != .mirror {
                for id in ["nx", "dx", "ny", "dy"] { session.update(id) { $0.isHidden = s.kind == .circular } }
                for id in ["n", "angle", "cx", "cy"] { session.update(id) { $0.isHidden = s.kind == .rectangular } }
            }
            guard f.allSatisfy({ $0.isHidden || $0.validationMessage == nil }), (try? s.validate()) != nil,
                  s.kind != .mirror || idx(f, "plane") < planes.count || s.mirrorNormal != nil else {
                workspace.requestPreview(nil); return
            }
            workspace.requestPreview(document(with: s).0)
        }
        let created = CommandSession(
            title: original == nil ? spec.kind.label : "Modifica \(original!.name)",
            symbol: spec.kind == .mirror ? "arrow.left.and.right.righttriangle.left.righttriangle.right" : "square.grid.3x3",
            fields: fields,
            onPreview: preview,
            onCommit: { f in
                defer { workspace.requestPreview(nil); workspace.mirrorFacePick = nil }
                let s = read(f)
                do { try s.validate() } catch { model.statusMessage = error.localizedDescription; return }
                let (doc, feature) = document(with: s)
                model.edit(original == nil ? feature.name : "Modifica \(feature.name)", selected: .some(feature.id), changed: [feature.id]) { $0 = doc }
            },
            onCancel: { workspace.requestPreview(nil); workspace.mirrorFacePick = nil })
        session = created
        if spec.kind == .mirror {
            // A face parallel to YZ, XZ or XY sets that plane and its coordinate; any other planar
            // face becomes «Faccia cliccata» (its normal, its distance from the origin).
            workspace.mirrorFacePick = { [weak created] point, normal in
                guard let created else { return }
                let n = normal * (1 / normal.length)
                if let i = planes.firstIndex(where: { abs(abs($0.axisVector.dot(n)) - 1) < 1e-9 }) {
                    faceNormal = nil
                    created.update("plane") { $0.value = .index(i) }
                    created.update("offset") { $0.value = .number(point.dot(planes[i].axisVector)) }
                } else {
                    faceNormal = n
                    created.update("plane") { $0.value = .index(planes.count) }
                    created.update("offset") { $0.value = .number(point.dot(n)) }
                }
                model.statusMessage = "Piano dello specchio sulla faccia cliccata"
            }
        }
        preview(created.fields)
        return created
    }
}
