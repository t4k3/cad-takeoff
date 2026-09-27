import CADCore
import SwiftUI

/// Temporary adapter: edit today's primitive features through the command panel.
/// Replaced by `ParameterSpec` + beginEdit/commitEdit/cancelEdit once T24/R1 land.
@MainActor
enum FeatureCommands {
    static func edit(_ id: Feature.ID, model: DesignModel) -> CommandSession? {
        guard let index = model.document.features.firstIndex(where: { $0.id == id }) else { return nil }
        let original = model.document.features[index]
        let length = 0.1...1000.0

        var fields: [CommandField]
        switch original.kind {
        case let .box(w, d, h):
            fields = [.init(id: "w", label: "Larghezza", kind: .length(length), value: .number(w)),
                      .init(id: "d", label: "Profondità", kind: .length(length), value: .number(d)),
                      .init(id: "h", label: "Altezza", kind: .length(length), value: .number(h))]
        case let .cylinder(r, h):
            fields = [.init(id: "r", label: "Raggio", kind: .length(0.05...500), value: .number(r)),
                      .init(id: "h", label: "Altezza", kind: .length(length), value: .number(h))]
        case let .extrude(_, h):
            fields = [.init(id: "h", label: "Distanza", kind: .length(length), value: .number(h)),
                      .init(id: "extent", label: "Estensione", kind: .choice(["Una direzione", "Simmetrica", "Passante"]),
                            value: .index(original.throughAll ? 2 : (original.symmetric ? 1 : 0))),
                      .init(id: "taper", label: "Sformo", kind: .angle(-60...60), value: .number(original.taper),
                            help: "Positivo stringe le pareti allontanandosi dallo schizzo, negativo le allarga")]
        case let .revolve(spec):
            fields = [.init(id: "angle", label: "Angolo", kind: .angle(0.1...360), value: .number(spec.angle)),
                      .init(id: "rev", label: "Verso opposto", kind: .toggle, value: .flag(spec.reversed))]
        case .hole, .chamfer, .sheetMetal, .pattern, .split, .shell, .move, .joint:
            return nil   // own panels (HoleCommand, ChamferCommand, SheetMetalCommand, PatternCommand)
        case let .component(ref):
            return component(id, ref: ref, original: original, model: model)
        case let .importedMesh(m):
            fields = [.init(id: "note", label: "Da \(m.source) · \(m.mesh.triangleCount) triangoli", kind: .note(warning: false), value: .flag(false)),
                      .init(id: "x", label: "Posizione X", kind: .length(-100_000...100_000), value: .number(original.position.x)),
                      .init(id: "y", label: "Posizione Y", kind: .length(-100_000...100_000), value: .number(original.position.y))]
        }
        // Sizes can be parameter expressions (Fusion: «spessore * 2»).
        let sizeKey = ["w": "width", "d": "depth", "h": "height", "r": "radius"]
        for i in fields.indices {
            guard let key = sizeKey[fields[i].id], original.size(key) != nil else { continue }
            fields[i].acceptsExpression = true
            fields[i].expression = original.expressions[key]
        }
        fields += [.init(id: "z", label: "Offset Z", kind: .length(-1000...1000), value: .number(original.position.z)),
                   .init(id: "op", label: "Operazione", kind: .choice(BooleanOperation.allCases.map(\.label)),
                         value: .index(BooleanOperation.allCases.firstIndex(of: original.operation) ?? 0))]

        func apply(_ fields: [CommandField]) {
            guard let i = model.document.features.firstIndex(where: { $0.id == id }) else { return }
            let v = { (key: String) in fields.first { $0.id == key }?.number ?? 0 }
            var f = original
            switch original.kind {
            case .box: f.kind = .box(width: v("w"), depth: v("d"), height: v("h"))
            case .cylinder: f.kind = .cylinder(radius: v("r"), height: v("h"))
            case let .extrude(p, _):
                f.kind = .extrude(profile: p, height: v("h"))
                if case let .index(e)? = fields.first(where: { $0.id == "extent" })?.value { f.symmetric = e == 1; f.throughAll = e == 2 }
                f.taper = v("taper")
            case .hole, .chamfer, .sheetMetal, .component, .pattern, .split, .shell, .move, .joint: break
            case var .revolve(spec):
                spec.angle = v("angle")
                if case let .flag(b)? = fields.first(where: { $0.id == "rev" })?.value { spec.reversed = b }
                f.kind = .revolve(spec)
            case .importedMesh: f.position.x = v("x"); f.position.y = v("y")
            }
            f.position.z = v("z")
            for field in fields where field.acceptsExpression {
                if let key = sizeKey[field.id] { f.expressions[key] = field.expression }
            }
            if case let .index(i)? = fields.first(where: { $0.id == "op" })?.value { f.operation = BooleanOperation.allCases[i] }
            // TODO(R1): model.updateFeature(id, actionName:) — direct write until the command exists.
            model.document.features[i] = f
        }

        let session = CommandSession(
            title: "Modifica \(original.name)", symbol: original.kind.symbol, fields: fields,
            onPreview: { fields in
                if fields.allSatisfy({ $0.validationMessage == nil }) { apply(fields) }
            },
            onCommit: { apply($0) },
            onCancel: {
                if let i = model.document.features.firstIndex(where: { $0.id == id }) {
                    model.document.features[i] = original
                }
            })
        session.parameterValues = (try? model.document.parameterValues()) ?? [:]
        return session
    }

    /// Component placement: position and rotation, previewed live on the design.
    private static func component(_ id: Feature.ID, ref: ComponentRef, original: Feature, model: DesignModel) -> CommandSession {
        let fields: [CommandField] = [
            .init(id: "note", label: "Pezzo: " + ref.path, kind: .note(warning: false), value: .flag(false)),
            .init(id: "x", label: "Posizione X", kind: .length(-100_000...100_000), value: .number(original.position.x)),
            .init(id: "y", label: "Posizione Y", kind: .length(-100_000...100_000), value: .number(original.position.y)),
            .init(id: "z", label: "Posizione Z", kind: .length(-100_000...100_000), value: .number(original.position.z)),
            .init(id: "rx", label: "Rotazione X", kind: .angle(-360...360), value: .number(ref.rotation.x)),
            .init(id: "ry", label: "Rotazione Y", kind: .angle(-360...360), value: .number(ref.rotation.y)),
            .init(id: "rz", label: "Rotazione Z", kind: .angle(-360...360), value: .number(ref.rotation.z),
                  help: "Rotazioni in gradi attorno agli assi del mondo, nell'ordine X, Y, Z"),
        ]
        func apply(_ f: [CommandField]) {
            guard f.allSatisfy({ $0.isHidden || $0.validationMessage == nil }),
                  let i = model.document.features.firstIndex(where: { $0.id == id }) else { return }
            let v = { (key: String) in f.first { $0.id == key }?.number ?? 0 }
            var next = original
            next.position = Vec3(v("x"), v("y"), v("z"))
            next.kind = .component(ComponentRef(path: ref.path, rotation: Vec3(v("rx"), v("ry"), v("rz"))))
            model.document.features[i] = next
        }
        return CommandSession(title: "Posiziona \(original.name)", symbol: "puzzlepiece.extension", fields: fields,
                              onPreview: apply, onCommit: apply,
                              onCancel: {
                                  if let i = model.document.features.firstIndex(where: { $0.id == id }) { model.document.features[i] = original }
                              })
    }
}
