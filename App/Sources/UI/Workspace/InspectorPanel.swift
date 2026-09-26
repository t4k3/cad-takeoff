import CADCore
import SwiftUI

/// Parameters of the selected feature. Edits rebuild the mesh live.
/// NOTE: still writes through Bindings (pre-existing behaviour); moves to
/// `model.updateFeature` once R1/T04 lands — see docs/COLLAB.md.
struct InspectorPanel: View {
    @Environment(DesignModel.self) private var model

    @Environment(WorkspaceState.self) private var workspace
    @Environment(ProjectLibrary.self) private var library

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
                        section("Operazione") {
                            Picker("Operazione", selection: $model.document.features[i].operation) {
                                ForEach(BooleanOperation.allCases, id: \.self) { Text($0.label).tag($0) }
                            }
                            .labelsHidden()
                            .help("Nuovo corpo, oppure unisci/taglia/interseca i corpi che questo passo tocca")
                        }
                        section("Colore") { PartColorPicker(feature: feature) }
                        section("Dimensioni") {
                            parameters(for: $model.document.features[i].kind)
                            if !feature.holes.isEmpty {
                                info(feature.holes.count == 1 ? "Foro" : "Fori", feature.holes.map(\.entitiesDescription).joined(separator: " · "))
                            }
                        }
                        section("Posizione") {
                            DimensionField(title: "X", value: $model.document.features[i].position.x)
                            DimensionField(title: "Y", value: $model.document.features[i].position.y)
                            DimensionField(title: "Z", value: $model.document.features[i].position.z)
                        }
                        section("Proprietà") {
                            // The evaluated body (booleans, copies, components), else the feature's own mesh.
                            let mesh = model.evaluation().bodies.first { $0.id == feature.id }?.mesh ?? feature.buildMesh()
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
        case let .hole(spec):
            info("Foro", spec.summary)
            info("Diametro", String(format: "%.2f mm", spec.boreDiameter))
            if spec.style != .simple { info("Testa", String(format: "%.2f mm", spec.resolvedHeadDiameter)) }
            info("Centri", "\(spec.centers.count)")
            Button("Modifica foro…") {
                if let f = model.document.features.first(where: { $0.kind == kind.wrappedValue }) {
                    workspace.startHole(model: model, editing: f)
                }
            }
            .controlSize(.small)
        case let .chamfer(spec):
            info("Forma", spec.profile == .round ? "Tondo (raccordo)" : "Piatto (smusso)")
            if spec.profile == .flat { info("Misura", spec.mode.label) }
            info("Spigoli", "\(spec.edges.count)")
            DimensionField(title: spec.profile == .round ? "Raggio" : "Distanza", value: Binding(get: { spec.distance }, set: { var s = spec; s.distance = $0; kind.wrappedValue = .chamfer(s) }))
            if spec.profile == .flat, spec.mode == .twoDistances {
                DimensionField(title: "Distanza 2", value: Binding(get: { spec.distance2 }, set: { var s = spec; s.distance2 = $0; kind.wrappedValue = .chamfer(s) }))
            }
            if spec.profile == .flat, spec.mode == .distanceAngle { info("Angolo", String(format: "%.0f°", spec.angle)) }
        case let .split(sp):
            info("Divide", model.document.features.first { $0.id == sp.body }?.name ?? "—")
            info("Piano", SplitCommand.planeLabels[SplitCommand.planes.firstIndex(of: sp.plane) ?? 0] + " a \(sp.offset) mm")
            info("Tieni", sp.keep.label)
            Button("Modifica…") {
                if let f = model.document.features.first(where: { $0.kind == kind.wrappedValue }) { workspace.editFeature(f.id, model: model) }
            }
            .controlSize(.small)
        case let .pattern(p):
            info("Tipo", p.kind.label)
            info("Copia di", model.document.features.first { $0.id == p.body }?.name ?? "—")
            switch p.kind {
            case .rectangular: info("Griglia", "\(p.countX) × \(p.countY) · passo \(p.spacingX) × \(p.spacingY) mm")
            case .circular: info("Copie", "\(p.count) su \(Int(p.angle))°")
            case .mirror: info("Piano", p.plane.label + " a \(p.offset) mm")
            }
            info("Unito", p.join ? "sì, al corpo originale" : "no, corpo separato")
            Button("Modifica…") {
                if let f = model.document.features.first(where: { $0.kind == kind.wrappedValue }) { workspace.editFeature(f.id, model: model) }
            }
            .controlSize(.small)
        case let .revolve(spec):
            DimensionField(title: "Angolo", value: Binding(get: { spec.angle }, set: { var r = spec; r.angle = min(360, max(0.1, $0)); kind.wrappedValue = .revolve(r) }), unit: "°")
            info("Profilo", "\(spec.profile.points.count) vertici" + (spec.axisRef != nil ? " · asse dallo schizzo" : ""))
        case let .importedMesh(m):
            info("Origine", m.source)
            info("Triangoli", "\(m.mesh.triangleCount)")
            info("Nota", "Facce piane riconosciute: si possono selezionare, forare e usare per schizzi")
        case let .component(ref):
            info("Pezzo", ref.partName)
            info("File", ref.path)
            info("Rotazione", String(format: "%.0f° · %.0f° · %.0f°", ref.rotation.x, ref.rotation.y, ref.rotation.z))
            HStack {
                Button("Posiziona…") {
                    if let f = model.document.features.first(where: { $0.kind == kind.wrappedValue }) { workspace.editFeature(f.id, model: model) }
                }
                Button("Apri pezzo") {
                    if let url = library.url(forComponent: ref.path) { library.open(url, model: model) }
                }
            }
            .controlSize(.small)
        case let .sheetMetal(spec):
            if let rule = try? spec.rule() {
                info("Materiale", rule.material.name)
                info("Spessore", SheetMetalCommand.mm(rule.thickness) + " mm")
                info("Raggio interno", SheetMetalCommand.mm(rule.insideRadius) + " mm" + (rule.radiusIsDefault ? " (tabella)" : ""))
                info("K-factor", String(format: "%.3f", rule.kFactor))
                info("Matrice", "V" + SheetMetalCommand.mm(rule.vDie))
            }
            info("Ingombro", SheetMetalCommand.mm(spec.width) + " × " + SheetMetalCommand.mm(spec.depth) + " mm")
            info("Flange", SheetEdge.allCases.filter { spec[$0] != nil }.map(\.label).joined(separator: ", ").ifEmpty("nessuna"))
            Button("Modifica lamiera…") {
                if let f = model.document.features.first(where: { $0.kind == kind.wrappedValue }) {
                    workspace.startSheetMetal(model: model, editing: f)
                }
            }
            .controlSize(.small)
        case let .extrude(p, h):
            info("Profilo", p.entitiesDescription)
            DimensionField(title: "Altezza", value: Binding(get: { h }, set: { kind.wrappedValue = .extrude(profile: p, height: $0) }))
        }
    }
}

private extension String {
    func ifEmpty(_ fallback: String) -> String { isEmpty ? fallback : self }
}
