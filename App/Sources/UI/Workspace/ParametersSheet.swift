import CADCore
import SwiftUI

/// «Parametri» (Fusion's Change Parameters): the design's named values. Dimensions and sizes
/// typed as expressions (`larghezza / 2`) follow them; OK applies everything in one undo step.
struct ParametersSheet: View {
    @Environment(DesignModel.self) private var model
    @Environment(WorkspaceState.self) private var workspace
    @State private var rows: [UserParameter] = []
    @State private var failure: String?

    private var evaluation: Result<[String: Double], Error> { Result { try CADDocument.values(of: rows) } }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Parametri", systemImage: "function").font(.headline)
            Text("Valori con un nome, da usare nelle quote dello schizzo e nelle misure: scrivi per esempio «larghezza / 2 + 3». Millimetri e gradi; sin, cos, tan in gradi; sqrt, min, max, round, pi.")
                .font(.caption).foregroundStyle(Theme.Palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 6) {
                GridRow {
                    Text("Nome").frame(width: 130, alignment: .leading)
                    Text("Espressione").frame(width: 180, alignment: .leading)
                    Text("Valore").frame(width: 80, alignment: .trailing)
                    Text("Commento")
                    Text("")
                }
                .font(.caption.weight(.semibold)).foregroundStyle(Theme.Palette.textSecondary)
                ForEach($rows) { $row in
                    GridRow {
                        TextField("nome", text: $row.name).frame(width: 130)
                        TextField("40", text: $row.expression).frame(width: 180).font(Theme.Typeface.mono)
                        Text(valueText(row)).font(Theme.Typeface.mono).frame(width: 80, alignment: .trailing)
                            .foregroundStyle(value(row) == nil ? Color.red : Theme.Palette.textPrimary)
                        TextField("", text: $row.comment).frame(minWidth: 120)
                        Button { rows.removeAll { $0.id == row.id } } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.borderless)
                            .help("Elimina il parametro (le quote che lo usano restano al valore attuale finché non le cambi)")
                    }
                }
            }
            .textFieldStyle(.roundedBorder)
            Button { rows.append(UserParameter(name: nextName(), expression: "10")) } label: { Label("Aggiungi parametro", systemImage: "plus") }
                .buttonStyle(.borderless)
            if case let .failure(e) = evaluation {
                Text(e.localizedDescription).font(.caption).foregroundStyle(.red)
            } else if let failure {
                Text(failure).font(.caption).foregroundStyle(.red)
            }
            Spacer(minLength: 0)
            HStack {
                Spacer()
                Button("Annulla") { workspace.showParameters = false }.keyboardShortcut(.cancelAction)
                Button("OK") { apply() }
                    .keyboardShortcut(.defaultAction)
                    .disabled({ if case .failure = evaluation { true } else { false } }())
            }
        }
        .padding(16)
        .frame(width: 680, height: 420)
        .onAppear { rows = model.document.parameters }
    }

    private func value(_ row: UserParameter) -> Double? {
        guard case let .success(v) = evaluation else {
            // Rows that still evaluate on their own (only numbers and good names) show a value.
            return (try? Formula.evaluate(row.expression, [:]))
        }
        return v[row.name]
    }

    private func valueText(_ row: UserParameter) -> String { value(row).map(fmt) ?? "—" }

    private func nextName() -> String {
        var i = rows.count + 1
        while rows.contains(where: { $0.name == "p\(i)" }) { i += 1 }
        return "p\(i)"
    }

    private func apply() {
        do {
            try model.setParameters(rows)
            if let session = workspace.sketch {
                session.parameterValues = (try? model.document.parameterValues()) ?? [:]
                session.refreshExpressions()
            }
            workspace.showParameters = false
        } catch {
            failure = error.localizedDescription
        }
    }
}
