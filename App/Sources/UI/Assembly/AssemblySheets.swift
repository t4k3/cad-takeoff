import CADCore
import SwiftUI

/// «Inserisci componente»: the designs of the project library; one click inserts it at the origin.
struct ComponentPickerSheet: View {
    @Environment(DesignModel.self) private var model
    @Environment(ProjectLibrary.self) private var library
    @Environment(WorkspaceState.self) private var workspace
    @State private var filter = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Inserisci componente", systemImage: "puzzlepiece.extension").font(.headline)
                Spacer()
                TextField("Cerca", text: $filter).textFieldStyle(.roundedBorder).frame(width: 180)
            }
            Text("Il componente resta collegato al suo file: quando modifichi il pezzo, l'assieme si aggiorna. Il disegno aperto deve essere salvato prima di inserirsi in un altro.")
                .font(.caption).foregroundStyle(Theme.Palette.textSecondary)
            if library.rootURL == nil {
                Text("Scegli prima la cartella dei progetti dalla Home.").foregroundStyle(Theme.Palette.textSecondary)
            }
            List(designs) { item in
                Button { insert(item) } label: {
                    HStack {
                        Image(systemName: "cube").foregroundStyle(Theme.Palette.accent)
                        VStack(alignment: .leading) {
                            Text(item.name)
                            Text(library.componentPath(for: item.url)).font(.caption2).foregroundStyle(Theme.Palette.textSecondary)
                        }
                        Spacer()
                        Text(item.modified, style: .relative).font(.caption2).foregroundStyle(Theme.Palette.textSecondary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .frame(minHeight: 260)
            HStack { Spacer(); Button("Chiudi") { workspace.showComponentPicker = false }.keyboardShortcut(.cancelAction) }
        }
        .padding(16)
        .frame(width: 520, height: 420)
    }

    private var designs: [ProjectLibrary.Item] {
        library.allDesigns.filter { $0.url != library.currentURL && (filter.isEmpty || $0.name.localizedCaseInsensitiveContains(filter)) }
    }

    private func insert(_ item: ProjectLibrary.Item) {
        let path = library.componentPath(for: item.url)
        let part = library.componentResolver(path)
        let colour = part?.activeFeatures.first(where: \.isVisible)?.color ?? .defaultColor
        let copies = model.document.features.filter { if case let .component(r) = $0.kind { r.path == path } else { false } }.count
        let feature = Feature(name: item.name + (copies > 0 ? " (\(copies + 1))" : ""), kind: .component(ComponentRef(path: path)), color: colour)
        model.edit("Inserisci \(item.name)", selected: .some(feature.id), changed: [feature.id]) { $0.features.append(feature) }
        workspace.showComponentPicker = false
        workspace.editFeature(feature.id, model: model)
    }
}

/// Distinta base: parts, quantities, sheet materials, volume and mass per piece; CSV export.
struct BOMSheet: View {
    @Environment(DesignModel.self) private var model
    @Environment(WorkspaceState.self) private var workspace

    var body: some View {
        let rows = model.billOfMaterials()
        VStack(alignment: .leading, spacing: 10) {
            Label("Distinta base", systemImage: "list.number").font(.headline)
            if rows.isEmpty {
                Text("Nessun componente: usa ASSIEME › Inserisci per aggiungere i pezzi del progetto.")
                    .foregroundStyle(Theme.Palette.textSecondary)
            } else {
                Table(rows) {
                    TableColumn("Pos") { r in Text("\((rows.firstIndex { $0.id == r.id } ?? 0) + 1)") }.width(34)
                    TableColumn("Pezzo", value: \.name)
                    TableColumn("Q.tà") { r in Text("\(r.quantity)") }.width(40)
                    TableColumn("Materiale") { r in Text(r.material.isEmpty ? "—" : r.material) }
                    TableColumn("Volume cad.") { r in Text(String(format: "%.2f cm³", r.volume / 1000)) }.width(90)
                    TableColumn("Massa cad.") { r in Text(r.mass.map { String(format: "%.3f kg", $0) } ?? "—") }.width(80)
                }
                .frame(minHeight: 220)
                Text("Massa calcolata per la lamiera (materiale noto); per i pezzi stampati conta il volume.")
                    .font(.caption).foregroundStyle(Theme.Palette.textSecondary)
            }
            HStack {
                Button("Esporta CSV…") { model.exportBOMWithPanel() }.disabled(rows.isEmpty)
                Spacer()
                Button("Chiudi") { workspace.showBOM = false }.keyboardShortcut(.cancelAction)
            }
        }
        .padding(16)
        .frame(width: 640, height: 400)
    }
}

/// «Interferenze»: the bodies and components that overlap (not the ones that only touch), with
/// the volume in common; a row selects the first part.
struct InterferenceSheet: View {
    @Environment(DesignModel.self) private var model
    @Environment(WorkspaceState.self) private var workspace
    @State private var clashes: [Interference.Clash]?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Interferenze", systemImage: "exclamationmark.triangle").font(.headline)
            if let clashes {
                if clashes.isEmpty {
                    Label("Nessuna interferenza: i corpi si toccano al massimo, senza compenetrarsi.", systemImage: "checkmark.seal")
                        .foregroundStyle(.green)
                } else {
                    Text("\(clashes.count) \(clashes.count == 1 ? "coppia si compenetra" : "coppie si compenetrano"):")
                        .foregroundStyle(Theme.Palette.textSecondary)
                    List(clashes) { c in
                        HStack {
                            Text(name(c.a)).bold()
                            Image(systemName: "arrow.left.and.right")
                            Text(name(c.b)).bold()
                            Spacer()
                            Text(String(format: "%.1f mm³", c.volume)).font(Theme.Typeface.mono)
                            Button("Seleziona") { model.selection = c.a; workspace.showInterference = false }
                                .controlSize(.small)
                        }
                    }
                    .frame(minHeight: 180)
                }
            } else {
                ProgressView("Controllo dei corpi…")
            }
            HStack {
                Spacer()
                Button("Chiudi") { workspace.showInterference = false }.keyboardShortcut(.cancelAction)
            }
        }
        .padding(16)
        .frame(width: 560, height: 360)
        .task {
            let bodies = model.evaluation().bodies.filter(\.isVisible)
            clashes = await Task.detached { Interference.check(bodies) }.value
        }
    }

    private func name(_ id: UUID) -> String { model.document.features.first { $0.id == id }?.name ?? "?" }
}
