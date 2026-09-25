import CADCore
import SwiftUI

/// Parameters of the selected feature. Edits rebuild the mesh live.
/// NOTE: still writes through Bindings (pre-existing behaviour); moves to
/// `model.updateFeature` once R1/T04 lands — see docs/COLLAB.md.
struct InspectorPanel: View {
    @Environment(DesignModel.self) private var model

    @Environment(WorkspaceState.self) private var workspace

    var body: some View {
        if let sketch = workspace.sketch { SketchInspector(sketch: sketch) } else { solidBody }
    }

    @ViewBuilder private var solidBody: some View {
        @Bindable var model = model
        VStack(spacing: 0) {
            PanelHeader("Parametri")
            if let i = model.selectedIndex {
                let feature = model.document.features[i]
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        HStack(spacing: 8) {
                            Image(systemName: feature.kind.symbol).font(.title3).foregroundStyle(Theme.Palette.accent)
                            VStack(alignment: .leading, spacing: 2) {
                                TextField("Nome", text: $model.document.features[i].name)
                                    .textFieldStyle(.plain).font(.system(size: 13, weight: .semibold))
                                Text(feature.kind.typeName).font(.caption).foregroundStyle(Theme.Palette.textSecondary)
                            }
                        }
                        section("Colore") { PartColorPicker(feature: feature) }
                        section("Dimensioni") { parameters(for: $model.document.features[i].kind) }
                        section("Posizione") {
                            DimensionField(title: "X", value: $model.document.features[i].position.x)
                            DimensionField(title: "Y", value: $model.document.features[i].position.y)
                            DimensionField(title: "Z", value: $model.document.features[i].position.z)
                        }
                        section("Proprietà") {
                            let mesh = feature.buildMesh()
                            info("Volume", String(format: "%.2f cm³", mesh.volume / 1000))
                            if let b = mesh.bounds {
                                info("Ingombro", String(format: "%.1f × %.1f × %.1f mm", b.size.x, b.size.y, b.size.z))
                            }
                            info("Triangoli", "\(mesh.triangleCount)")
                            Toggle("Visibile", isOn: $model.document.features[i].isVisible)
                                .toggleStyle(.switch).controlSize(.small)
                        }
                    }
                    .padding(Theme.Metrics.pad + 2)
                }
            } else {
                ContentUnavailableView {
                    Label("Nessuna selezione", systemImage: "cursorarrow.click.2")
                } description: {
                    Text("Clicca un corpo nel viewport, nel Browser o nella timeline per modificarne i parametri.")
                }
                .frame(maxHeight: .infinity)
            }
        }
        .background(Theme.Palette.panel)
    }

    private func section<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title.uppercased()).font(.system(size: 9.5, weight: .semibold)).tracking(0.5)
                .foregroundStyle(Theme.Palette.textSecondary)
            content()
        }
    }

    private func info(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title).font(Theme.Typeface.body).foregroundStyle(Theme.Palette.textSecondary)
            Spacer()
            Text(value).font(Theme.Typeface.mono)
        }
    }

    @ViewBuilder
    private func parameters(for kind: Binding<Feature.Kind>) -> some View {
        switch kind.wrappedValue {
        case let .box(w, d, h):
            DimensionField(title: "Larghezza", value: Binding(get: { w }, set: { kind.wrappedValue = .box(width: $0, depth: d, height: h) }))
            DimensionField(title: "Profondità", value: Binding(get: { d }, set: { kind.wrappedValue = .box(width: w, depth: $0, height: h) }))
            DimensionField(title: "Altezza", value: Binding(get: { h }, set: { kind.wrappedValue = .box(width: w, depth: d, height: $0) }))
        case let .cylinder(r, h):
            DimensionField(title: "Raggio", value: Binding(get: { r }, set: { kind.wrappedValue = .cylinder(radius: $0, height: h) }))
            DimensionField(title: "Altezza", value: Binding(get: { h }, set: { kind.wrappedValue = .cylinder(radius: r, height: $0) }))
        case let .extrude(p, h):
            info("Profilo", "\(p.points.count) vertici")
            DimensionField(title: "Altezza", value: Binding(get: { h }, set: { kind.wrappedValue = .extrude(profile: p, height: $0) }))
        }
    }
}
