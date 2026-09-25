import CADCore
import SwiftUI

struct ContentView: View {
    @Environment(DesignModel.self) private var model

    var body: some View {
        @Bindable var model = model
        NavigationSplitView {
            List(selection: $model.selection) {
                Section("Timeline") {
                    ForEach(model.document.features) { f in
                        Label(f.name, systemImage: icon(for: f.kind))
                            .opacity(f.isVisible ? 1 : 0.4)
                            .tag(f.id)
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 200, ideal: 230)
        } detail: {
            VStack(spacing: 0) {
                ViewportView(document: model.document, selection: model.selection)
                Divider()
                HStack {
                    Text(model.statusMessage).font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    let mesh = model.document.buildMesh()
                    Text("\(mesh.triangleCount) triangoli · \(String(format: "%.1f", mesh.volume / 1000)) cm³")
                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
                .padding(.horizontal, 10).padding(.vertical, 4)
            }
        }
        .inspector(isPresented: .constant(true)) {
            InspectorView().inspectorColumnWidth(min: 220, ideal: 260)
        }
        .toolbar {
            ToolbarItemGroup {
                Button { model.addBox() } label: { Label("Box", systemImage: "cube") }
                Button { model.addCylinder() } label: { Label("Cilindro", systemImage: "cylinder") }
                Button { model.addHexPrism() } label: { Label("Estrusione", systemImage: "hexagon") }
                Button(role: .destructive) { model.deleteSelected() } label: { Label("Elimina", systemImage: "trash") }
                    .disabled(model.selection == nil)
                Button { model.exportSTLWithPanel() } label: { Label("Esporta STL", systemImage: "printer") }
            }
        }
    }

    private func icon(for kind: Feature.Kind) -> String {
        switch kind {
        case .box: "cube"
        case .cylinder: "cylinder"
        case .extrude: "hexagon"
        }
    }
}

/// Parameter editor for the selected feature. Edits rebuild the mesh live.
struct InspectorView: View {
    @Environment(DesignModel.self) private var model

    var body: some View {
        @Bindable var model = model
        if let i = model.selectedIndex {
            Form {
                TextField("Nome", text: $model.document.features[i].name)
                Toggle("Visibile", isOn: $model.document.features[i].isVisible)
                Section("Posizione (mm)") {
                    number("X", $model.document.features[i].position.x)
                    number("Y", $model.document.features[i].position.y)
                    number("Z", $model.document.features[i].position.z)
                }
                Section("Parametri (mm)") { parameters(for: $model.document.features[i].kind) }
            }
            .formStyle(.grouped)
        } else {
            ContentUnavailableView("Nessuna selezione", systemImage: "cursorarrow.click",
                                   description: Text("Seleziona una feature nella timeline"))
        }
    }

    @ViewBuilder
    private func parameters(for kind: Binding<Feature.Kind>) -> some View {
        switch kind.wrappedValue {
        case let .box(w, d, h):
            number("Larghezza", Binding(get: { w }, set: { kind.wrappedValue = .box(width: $0, depth: d, height: h) }))
            number("Profondità", Binding(get: { d }, set: { kind.wrappedValue = .box(width: w, depth: $0, height: h) }))
            number("Altezza", Binding(get: { h }, set: { kind.wrappedValue = .box(width: w, depth: d, height: $0) }))
        case let .cylinder(r, h):
            number("Raggio", Binding(get: { r }, set: { kind.wrappedValue = .cylinder(radius: $0, height: h) }))
            number("Altezza", Binding(get: { h }, set: { kind.wrappedValue = .cylinder(radius: r, height: $0) }))
        case let .extrude(p, h):
            LabeledContent("Profilo", value: "\(p.points.count) punti")
            number("Altezza", Binding(get: { h }, set: { kind.wrappedValue = .extrude(profile: p, height: $0) }))
        }
    }

    private func number(_ title: String, _ value: Binding<Double>) -> some View {
        TextField(title, value: value, format: .number.precision(.fractionLength(0...3)))
    }
}
