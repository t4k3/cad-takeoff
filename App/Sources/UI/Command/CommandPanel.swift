import CADCore
import SwiftUI

/// Floating command dialog over the viewport. Return = OK, Esc = Cancel.
struct CommandPanel: View {
    @Bindable var session: CommandSession
    var onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: session.symbol).foregroundStyle(Theme.Palette.accent)
                Text(session.title.uppercased()).font(.system(size: 11, weight: .bold)).tracking(0.5)
                Spacer()
                Button { cancel() } label: { Label("Chiudi", systemImage: "xmark") }
                    .buttonStyle(IconButtonStyle()).help("Annulla (Esc)")
            }
            .padding(.horizontal, 10).frame(height: 32)
            .background(Theme.Palette.panel)
            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach($session.fields) { $field in
                        if !field.isHidden { row($field) }
                    }
                    if let message = session.message {
                        Label(message, systemImage: "exclamationmark.triangle.fill")
                            .font(.caption).foregroundStyle(Theme.Palette.danger)
                    }
                }
                .padding(12)
            }
            .scrollBounceBehavior(.basedOnSize)
            .frame(maxHeight: 560)
            .fixedSize(horizontal: false, vertical: true)

            Divider()
            HStack {
                Spacer()
                Button("Annulla", role: .cancel) { cancel() }
                    .keyboardShortcut(.cancelAction)
                Button("OK") { commit() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!session.isValid)
            }
            .controlSize(.small)
            .padding(10)
        }
        .frame(width: 300)
        // Liquid Glass over the viewport (macOS 26), tinted with the panel colour so the fields
        // stay easy to read over any part.
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .glassEffect(.regular.tint(Theme.Palette.panelRaised.opacity(0.55)), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    @ViewBuilder
    private func row(_ field: Binding<CommandField>) -> some View {
        let f = field.wrappedValue
        VStack(alignment: .leading, spacing: 3) {
            switch f.kind {
            case .length where f.acceptsExpression:
                ExpressionDimensionField(field: field, values: session.parameterValues, unit: "mm") { session.message = $0 }
            case .length:
                DimensionField(title: f.label, value: number(field), unit: "mm")
            case .angle:
                DimensionField(title: f.label, value: number(field), unit: "°")
            case let .count(r):
                Stepper(value: Binding(get: { Int(f.number) }, set: { field.wrappedValue.value = .number(Double($0)) }), in: r) {
                    HStack {
                        Text(f.label).font(Theme.Typeface.body).foregroundStyle(Theme.Palette.textSecondary)
                        Spacer()
                        Text("\(Int(f.number))").font(Theme.Typeface.mono)
                    }
                }
            case .toggle:
                Toggle(f.label, isOn: Binding(get: { if case let .flag(b) = f.value { b } else { false } },
                                              set: { field.wrappedValue.value = .flag($0) }))
                    .toggleStyle(.switch).controlSize(.mini).font(Theme.Typeface.body)
            case let .choice(options):
                Picker(f.label, selection: Binding(get: { if case let .index(i) = f.value { i } else { 0 } },
                                                   set: { field.wrappedValue.value = .index($0) })) {
                    ForEach(options.indices, id: \.self) { Text(options[$0]).tag($0) }
                }
                .font(Theme.Typeface.body)
            case let .reference(prompt, _):
                referenceRow(f, prompt: prompt)
            case let .note(warning):
                if warning {
                    Label(f.label, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption).foregroundStyle(Color.orange)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text(f.label).font(.caption).foregroundStyle(Theme.Palette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if let msg = f.validationMessage, !isReference(f) {
                Text(msg).font(.caption2).foregroundStyle(Theme.Palette.danger)
            }
        }
        .help(f.help ?? "")
    }

    private func referenceRow(_ f: CommandField, prompt: String) -> some View {
        let refs: [String] = if case let .references(r) = f.value { r } else { [] }
        let active = session.activeReference == f.id
        return HStack {
            Text(f.label).font(Theme.Typeface.body).foregroundStyle(Theme.Palette.textSecondary)
            Spacer()
            Button {
                session.activeReference = active ? nil : f.id
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: refs.isEmpty ? "cursorarrow.rays" : "checkmark.circle.fill")
                    Text(refs.isEmpty ? prompt : "\(refs.count) selezionat\(refs.count == 1 ? "o" : "i")")
                }
                .font(.system(size: 11, weight: .medium))
                .padding(.horizontal, 8).frame(height: 22)
                .foregroundStyle(active ? .white : Theme.Palette.sketch)
                .background(RoundedRectangle(cornerRadius: 5).fill(active ? Theme.Palette.sketch : Theme.Palette.sketch.opacity(0.12)))
            }
            .buttonStyle(.plain)
        }
    }

    private func isReference(_ f: CommandField) -> Bool { if case .reference = f.kind { true } else { false } }

    private func number(_ field: Binding<CommandField>) -> Binding<Double> {
        Binding(get: { field.wrappedValue.number }, set: { field.wrappedValue.value = .number($0) })
    }

    private func commit() {
        guard session.isValid else { return }
        endEditing()
        session.onCommit(session.fields)
        onClose()
    }

    private func cancel() {
        endEditing()
        session.onCancel()
        onClose()
    }

    /// Drop the text-field focus first, so no stale focus ring survives the panel.
    private func endEditing() { NSApp.keyWindow?.makeFirstResponder(nil) }
}

/// A length that takes a number or an expression of the design's parameters («spessore * 2»).
/// Shows "fx" while an expression drives it; dragging the arrow turns it back into a number.
struct ExpressionDimensionField: View {
    @Binding var field: CommandField
    let values: [String: Double]
    var unit = "mm"
    var report: (String?) -> Void
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 6) {
            Text(field.label).font(Theme.Typeface.body).foregroundStyle(Theme.Palette.textSecondary)
            Spacer(minLength: 8)
            if field.expression != nil {
                Text("fx").font(.system(size: 10, weight: .bold, design: .serif)).italic()
                    .foregroundStyle(Theme.Palette.accent)
                    .help(fmt(field.number) + " " + unit)
            }
            TextField(field.label, text: $text)
                .labelsHidden()
                .multilineTextAlignment(.trailing)
                .font(Theme.Typeface.mono)
                .textFieldStyle(.roundedBorder)
                .frame(width: 84)
                .focused($focused)
                .onSubmit(commit)
                .onChange(of: focused) { _, f in if !f { commit() } }
            Text(unit).font(Theme.Typeface.mono).foregroundStyle(Theme.Palette.textSecondary)
                .frame(width: 24, alignment: .leading)
        }
        .onAppear(perform: refresh)
        .onChange(of: field.number) { _, v in
            // Changed elsewhere (the arrow): an expression that no longer gives it is dropped.
            if let e = field.expression, (try? Formula.evaluate(e, values)) != v { field.expression = nil }
            if !focused { refresh() }
        }
    }

    private func refresh() { text = field.expression ?? fmt(field.number) }

    private func commit() {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { refresh(); return }
        do {
            let v = try Formula.evaluate(clean, values)
            field.expression = Formula.isNumber(clean) ? nil : clean
            field.value = .number(v)
            report(nil)
        } catch {
            report(field.label + ": " + error.localizedDescription)
        }
    }
}
