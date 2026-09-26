import Observation
import SwiftUI

/// One input of a command panel. UI-side type: the Model's future `ParameterSpec`
/// (T24) is mapped onto this by an adapter, so the panel never depends on Model internals.
struct CommandField: Identifiable, Equatable {
    enum Kind: Equatable {
        case length(ClosedRange<Double>)
        case angle(ClosedRange<Double>)
        case count(ClosedRange<Int>)
        case toggle
        case choice([String])
        /// Geometry to pick in the viewport (faces, edges, profiles…).
        case reference(prompt: String, maxCount: Int)
        /// Read-only text (the label): computed data or a workshop warning.
        case note(warning: Bool)
    }

    enum Value: Equatable {
        case number(Double)
        case flag(Bool)
        case index(Int)
        case references([String])
    }

    let id: String
    var label: String
    var kind: Kind
    var value: Value
    var help: String?
    /// Not relevant with the current choices (e.g. flange fields while no side has a flange).
    var isHidden = false

    var number: Double { if case let .number(v) = value { v } else { 0 } }

    /// nil when valid, otherwise a short message shown under the field.
    var validationMessage: String? {
        switch (kind, value) {
        case let (.length(r), .number(v)), let (.angle(r), .number(v)):
            guard v.isFinite, r.contains(v) else {
                return "Valore tra \(r.lowerBound.formatted()) e \(r.upperBound.formatted())"
            }
        case let (.count(r), .number(v)):
            guard r.contains(Int(v)) else { return "Valore tra \(r.lowerBound) e \(r.upperBound)" }
        case let (.reference(_, _), .references(refs)):
            if refs.isEmpty { return "Selezione richiesta" }
        default: break
        }
        return nil
    }
}

/// A running command (create or edit), Fusion-style: fields + live preview + OK/Cancel.
@MainActor
@Observable
final class CommandSession: Identifiable {
    let id = UUID()
    let title: String
    let symbol: String
    var fields: [CommandField] {
        didSet { if fields != oldValue { onPreview(fields) } }
    }
    /// Field currently waiting for a viewport pick, if any.
    var activeReference: String?
    var message: String?

    @ObservationIgnored var onPreview: ([CommandField]) -> Void
    @ObservationIgnored var onCommit: ([CommandField]) -> Void
    @ObservationIgnored var onCancel: () -> Void

    init(title: String, symbol: String, fields: [CommandField],
         onPreview: @escaping ([CommandField]) -> Void = { _ in },
         onCommit: @escaping ([CommandField]) -> Void,
         onCancel: @escaping () -> Void = {}) {
        self.title = title; self.symbol = symbol; self.fields = fields
        self.onPreview = onPreview; self.onCommit = onCommit; self.onCancel = onCancel
        activeReference = fields.first { if case .reference = $0.kind { true } else { false } }?.id
    }

    var isValid: Bool { fields.allSatisfy { $0.isHidden || $0.validationMessage == nil } }

    /// Updates a field in place (label, options, value, visibility) only when something changes.
    func update(_ id: String, _ change: (inout CommandField) -> Void) {
        guard let i = fields.firstIndex(where: { $0.id == id }) else { return }
        var f = fields[i]
        change(&f)
        if f != fields[i] { fields[i] = f }
    }

    subscript(_ id: String) -> CommandField? { fields.first { $0.id == id } }
}
