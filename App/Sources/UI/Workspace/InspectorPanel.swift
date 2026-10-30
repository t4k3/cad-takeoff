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
                                ForEach(BooleanOperation.allCases, id: \.self) { Text(LocalizedStringKey($0.label)).tag($0) }
                            }
                            .labelsHidden()
                            .help("Nuovo corpo, oppure unisci/taglia/interseca i corpi che questo passo tocca")
                        }
                        section("Colore") { PartColorPicker(feature: feature) }
                        section("Dimensioni") {
                            parameters(for: $model.document.features[i].kind)
                            if !feature.holes.isEmpty {
                                info(feature.holes.count == 1 ? LocalizedStringKey("Foro") : LocalizedStringKey("Fori"), feature.holes.map(\.entitiesDescription).joined(separator: " · "))
                            }
                        }
                        section("Posizione") {
                            DimensionField(title: String(localized: "X"), value: $model.document.features[i].position.x)
                            DimensionField(title: String(localized: "Y"), value: $model.document.features[i].position.y)
                            DimensionField(title: String(localized: "Z"), value: $model.document.features[i].position.z)
                        }
                        section("Proprietà") {
                            // The evaluated body (booleans, copies, components), else the feature's own mesh.
                            let mesh = model.evaluation().bodies.first { $0.id == feature.id }?.mesh ?? feature.buildMesh()
                            // On the true surfaces when ready (the facets' volume meanwhile, marked ≈).
                            if let exact = model.exactVolume(of: feature.id) {
                                info("Volume", String(format: "%.3f cm³", exact / 1000))
                            } else {
                                info("Volume", String(format: "≈ %.2f cm³", mesh.volume / 1000))
                            }
                            if let b = mesh.bounds {
                                info("Ingombro", String(format: "%.1f × %.1f × %.1f mm", b.size.x, b.size.y, b.size.z))
                            }
                            info("Triangoli", "\(mesh.triangleCount)")
                            Toggle("Visibile", isOn: $model.document.features[i].isVisible)
                                .toggleStyle(.switch).controlSize(.small)
                        }
                        .task(id: model.designRevision) { model.requestExactVolumes() }
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

    private func section<C: View>(_ title: LocalizedStringKey, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title).textCase(.uppercase).font(.system(size: 9.5, weight: .semibold)).tracking(0.5)
                .foregroundStyle(Theme.Palette.textSecondary)
            content()
        }
    }

    private func info(_ title: LocalizedStringKey, _ value: String) -> some View {
        HStack {
            Text(title).font(Theme.Typeface.body).foregroundStyle(Theme.Palette.textSecondary)
            Spacer()
            // Values built by CADCore (option labels, summaries) are Italian source text:
            // looking them up shows the catalog translation when one exists, the text itself otherwise.
            Text(LocalizedStringKey(value)).font(Theme.Typeface.mono)
        }
    }

    @ViewBuilder
    private func parameters(for kind: Binding<Feature.Kind>) -> some View {
        switch kind.wrappedValue {
        case let .box(w, d, h):
            DimensionField(title: String(localized: "Larghezza"), value: Binding(get: { w }, set: { kind.wrappedValue = .box(width: $0, depth: d, height: h) }))
            DimensionField(title: String(localized: "Profondità"), value: Binding(get: { d }, set: { kind.wrappedValue = .box(width: w, depth: $0, height: h) }))
            DimensionField(title: String(localized: "Altezza"), value: Binding(get: { h }, set: { kind.wrappedValue = .box(width: w, depth: d, height: $0) }))
        case let .cylinder(r, h):
            DimensionField(title: String(localized: "Raggio"), value: Binding(get: { r }, set: { kind.wrappedValue = .cylinder(radius: $0, height: h) }))
            DimensionField(title: String(localized: "Altezza"), value: Binding(get: { h }, set: { kind.wrappedValue = .cylinder(radius: r, height: $0) }))
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
            info("Forma", spec.profile == .round ? String(localized: "Tondo (raccordo)") : String(localized: "Piatto (smusso)"))
            if spec.profile == .flat { info("Misura", spec.mode.label) }
            info("Spigoli", "\(spec.edges.count)")
            DimensionField(title: spec.profile == .round ? String(localized: "Raggio") : String(localized: "Distanza"), value: Binding(get: { spec.distance }, set: { var s = spec; s.distance = $0; kind.wrappedValue = .chamfer(s) }))
            if spec.profile == .flat, spec.mode == .twoDistances {
                DimensionField(title: String(localized: "Distanza 2"), value: Binding(get: { spec.distance2 }, set: { var s = spec; s.distance2 = $0; kind.wrappedValue = .chamfer(s) }))
            }
            if spec.profile == .flat, spec.mode == .distanceAngle { info("Angolo", String(format: "%.0f°", spec.angle)) }
        case let .split(sp):
            info("Divide", model.document.features.first { $0.id == sp.body }?.name ?? "—")
            info("Piano", String(localized: "\(SplitCommand.planeLabels[SplitCommand.planes.firstIndex(of: sp.plane) ?? 0]) a \(sp.offset) mm"))
            info("Tieni", sp.keep.label)
            Button("Modifica…") {
                if let f = model.document.features.first(where: { $0.kind == kind.wrappedValue }) { workspace.editFeature(f.id, model: model) }
            }
            .controlSize(.small)
        case let .pattern(p) where p.placements != nil:
            // Copies placed where Fusion put them (no grid or circle to edit).
            info("Tipo", String(localized: "Copie al loro posto (da Fusion)"))
            info("Copia di", model.document.features.first { $0.id == p.body }?.name ?? "—")
            info("Copie", "\(p.placements?.count ?? 0)")
        case let .pattern(p):
            info("Tipo", p.kind.label)
            info("Copia di", model.document.features.first { $0.id == p.body }?.name ?? "—")
            switch p.kind {
            case .rectangular: info("Griglia", String(localized: "\(p.countX) × \(p.countY) · passo \(p.spacingX) × \(p.spacingY) mm"))
            case .circular: info("Copie", String(localized: "\(p.count) su \(Int(p.angle))°"))
            case .mirror: info("Piano", String(localized: "\(p.plane.label) a \(p.offset) mm"))
            }
            info("Unito", p.join ? String(localized: "sì, al corpo originale") : String(localized: "no, corpo separato"))
            Button("Modifica…") {
                if let f = model.document.features.first(where: { $0.kind == kind.wrappedValue }) { workspace.editFeature(f.id, model: model) }
            }
            .controlSize(.small)
        case let .joint(spec):
            info("Tipo", spec.kind.label)
            info("Pezzi", [spec.moving, spec.fixed].compactMap { id in id.flatMap { i in model.document.features.first { $0.id == i }?.name } }.joined(separator: " → "))
            if spec.kind != .slider {
                DimensionField(title: String(localized: "Angolo"), value: Binding(get: { spec.angle }, set: { var j = spec; j.angle = $0; kind.wrappedValue = .joint(j) }), unit: "°")
            }
            if spec.kind == .slider || spec.kind == .cylindrical {
                DimensionField(title: String(localized: "Corsa"), value: Binding(get: { spec.offset }, set: { var j = spec; j.offset = $0; kind.wrappedValue = .joint(j) }))
            }
        case let .thread(spec):
            info("Misura", spec.size ?? String(localized: "dal diametro"))
            info("Compensazione", String(format: "%.2f mm", spec.printAllowance))
        case let .combine(spec):
            info("Operazione", spec.operation.label)
            info("Obiettivo", model.document.features.first { $0.id == spec.target }?.name ?? "—")
            info("Strumenti", spec.tools.compactMap { id in model.document.features.first { $0.id == id }?.name }.joined(separator: ", ").ifEmpty("—"))
            info("Strumenti mantenuti", spec.keepTools ? String(localized: "sì") : String(localized: "no"))
        case let .move(spec):
            info("Corpi", spec.bodies.compactMap { id in model.document.features.first { $0.id == id }?.name }.joined(separator: ", ").ifEmpty("—"))
            info("Spostamento", String(format: "%.2f · %.2f · %.2f mm", spec.translation.x, spec.translation.y, spec.translation.z))
            info("Rotazione", String(format: "%.1f°", spec.angle))
            Button("Modifica…") {
                if let f = model.document.features.first(where: { $0.kind == kind.wrappedValue }) { workspace.editFeature(f.id, model: model) }
            }
            .controlSize(.small)
        case let .shell(spec):
            DimensionField(title: String(localized: "Spessore"), value: Binding(get: { spec.thickness }, set: { var s = spec; s.thickness = max(0.01, $0); kind.wrappedValue = .shell(s) }))
            info("Facce aperte", "\(spec.openFaces.count)")
            info("Corpo", model.document.features.first { $0.id == spec.body }?.name ?? "—")
        case let .revolve(spec):
            DimensionField(title: String(localized: "Angolo"), value: Binding(get: { spec.angle }, set: { var r = spec; r.angle = min(360, max(0.1, $0)); kind.wrappedValue = .revolve(r) }), unit: "°")
            info("Profilo", spec.axisRef != nil
                ? String(localized: "\(spec.profile.points.count) vertici · asse dallo schizzo")
                : String(localized: "\(spec.profile.points.count) vertici"))
        case let .importedMesh(m):
            info("Origine", m.source)
            info("Triangoli", "\(m.mesh.triangleCount)")
            info("Nota", String(localized: "Facce piane riconosciute: si possono selezionare, forare e usare per schizzi"))
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
                info("Raggio interno", SheetMetalCommand.mm(rule.insideRadius) + " mm" + (rule.radiusIsDefault ? String(localized: " (tabella)") : ""))
                info("K-factor", String(format: "%.3f", rule.kFactor))
                info("Matrice", "V" + SheetMetalCommand.mm(rule.vDie))
            }
            info("Ingombro", SheetMetalCommand.mm(spec.width) + " × " + SheetMetalCommand.mm(spec.depth) + " mm")
            if spec.outline != nil {
                info("Flange", (spec.sideFlanges ?? []).map { String(localized: "lato \($0.side + 1)") }.joined(separator: ", ").ifEmpty(String(localized: "nessuna")))
            } else {
                info("Flange", SheetEdge.allCases.filter { spec[$0] != nil }.map(\.label).joined(separator: ", ").ifEmpty(String(localized: "nessuna")))
            }
            Button("Modifica lamiera…") {
                if let f = model.document.features.first(where: { $0.kind == kind.wrappedValue }) {
                    workspace.startSheetMetal(model: model, editing: f)
                }
            }
            .controlSize(.small)
        case let .extrude(p, h):
            info("Profilo", p.entitiesDescription)
            DimensionField(title: String(localized: "Altezza"), value: Binding(get: { h }, set: { kind.wrappedValue = .extrude(profile: p, height: $0) }))
        }
    }
}

private extension String {
    func ifEmpty(_ fallback: String) -> String { isEmpty ? fallback : self }
}
