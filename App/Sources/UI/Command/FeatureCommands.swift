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
            fields = [.init(id: "h", label: "Distanza", kind: .length(length), value: .number(h))]
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
            case let .extrude(p, _): f.kind = .extrude(profile: p, height: v("h"))
            }
            f.position.z = v("z")
            if case let .index(i)? = fields.first(where: { $0.id == "op" })?.value { f.operation = BooleanOperation.allCases[i] }
            // TODO(R1): model.updateFeature(id, actionName:) — direct write until the command exists.
            model.document.features[i] = f
        }

        return CommandSession(
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
    }
}
