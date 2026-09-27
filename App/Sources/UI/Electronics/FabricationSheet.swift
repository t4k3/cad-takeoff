import AppKit
import ElectronicsCore
import SwiftUI

/// PRODUZIONE › Gerber: the engine's fabrication check of the circuit as it is (profile and
/// assembly variant included), each layer as the manufacturer will get it, and the export into a
/// new folder. Nothing here changes the circuit.
struct FabricationSheet: View {
    @Environment(CircuitModel.self) private var circuits
    @State private var layer: FabricationLayerKind = .topCopper

    var body: some View {
        @Bindable var c = circuits
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 12) {
                Label("Produzione", systemImage: "square.stack.3d.up").font(.headline)
                Text("Gerber X2, forature Excellon, BOM e CPL per una scheda a due strati. Il circuito non cambia.")
                    .font(.caption).foregroundStyle(Theme.Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let variants = circuits.design?.variants, !variants.isEmpty {
                    Picker("Variante", selection: $c.fabricationVariant) {
                        Text("Tutti i componenti").tag(UUID?.none)
                        ForEach(variants, id: \.id) { Text($0.name).tag(UUID?.some($0.id)) }
                    }
                    .disabled(circuits.fabricationExporting)
                }
                profileForm
                Divider()
                status
                outcome
                Spacer(minLength: 0)
                buttons
            }
            .frame(width: 320)
            VStack(alignment: .leading, spacing: 8) {
                Picker("", selection: $layer) {
                    ForEach(FabricationLayerKind.allCases, id: \.self) { Text(Self.name($0)).tag($0) }
                }
                .labelsHidden()
                FabricationLayerView(preview: circuits.currentFabrication?.preview, layer: layer,
                                     failed: circuits.currentFabrication?.failure != nil)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.black.opacity(0.85), in: RoundedRectangle(cornerRadius: 6))
                Text(layer.fileName).font(.caption.monospaced()).foregroundStyle(Theme.Palette.textSecondary)
            }
            .frame(minWidth: 380)
        }
        .padding(16)
        .frame(width: 760, height: 560)
        .onExitCommand {
            if circuits.fabricationExporting { circuits.cancelFabricationExport() } else { circuits.closeFabrication() }
        }
    }

    private var profileForm: some View {
        @Bindable var c = circuits
        return Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 6) {
            row("Espansione maschera", $c.fabricationProfile.solderMaskExpansion)
            row("Riduzione pasta", $c.fabricationProfile.pasteInset)
            row("Ponte maschera minimo", $c.fabricationProfile.minimumMaskWeb)
            row("Serigrafia minima", $c.fabricationProfile.minimumSilkscreenWidth)
            row("Serigrafia–piazzole", $c.fabricationProfile.silkscreenClearance)
            row("Distanza fra fori", $c.fabricationProfile.minimumHoleSeparation)
            GridRow {
                Text("Via coperte")
                Toggle("", isOn: $c.fabricationProfile.tentVias).labelsHidden()
                Text("")
            }
        }
        .textFieldStyle(.roundedBorder)
        .disabled(circuits.fabricationExporting)
    }

    @ViewBuilder private var status: some View {
        if let f = circuits.currentFabrication {
            if let failure = f.failure {
                Label(failure, systemImage: "xmark.octagon.fill").foregroundStyle(.red).font(.caption)
            } else if let p = f.preview {
                let errors = p.issues.filter { $0.severity == .error }
                if errors.isEmpty {
                    Label("Pronta: \(p.layers.count) strati, \(p.drills.count) fori" + (p.issues.isEmpty ? "" : " · \(p.issues.count) avvisi"),
                          systemImage: "checkmark.seal.fill").foregroundStyle(.green).font(.caption)
                } else {
                    Label("\(errors.count) error\(errors.count == 1 ? "e" : "i") da correggere prima di esportare",
                          systemImage: "xmark.octagon.fill").foregroundStyle(.red).font(.caption)
                }
                if !p.issues.isEmpty {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(Array(p.issues.enumerated()), id: \.offset) { _, issue in issueRow(issue) }
                        }
                    }
                    .frame(maxHeight: 180)
                }
            } else {
                HStack(spacing: 6) { ProgressView().controlSize(.small); Text("Verifica in corso…").font(.caption) }
            }
        } else {
            HStack(spacing: 6) { ProgressView().controlSize(.small); Text("Verifica in corso…").font(.caption) }
        }
    }

    /// The last export, here and not only in the status bar (covered by the sheet).
    @ViewBuilder private var outcome: some View {
        if let o = circuits.fabricationOutcome {
            VStack(alignment: .leading, spacing: 4) {
                Label(o.message, systemImage: o.folder == nil ? "exclamationmark.triangle.fill" : "folder.fill.badge.checkmark")
                    .font(.caption).foregroundStyle(o.folder == nil ? Color.orange : Color.green)
                    .fixedSize(horizontal: false, vertical: true)
                if let folder = o.folder {
                    Button("Mostra nel Finder") { NSWorkspace.shared.activateFileViewerSelecting([folder]) }
                        .controlSize(.small)
                }
            }
        }
    }

    private func issueRow(_ issue: ElectronicsIssue) -> some View {
        let isError = issue.severity == .error
        return Button { circuits.closeFabrication(); circuits.select(issue) } label: {
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: isError ? "xmark.octagon.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(isError ? Color.red : Color.orange)
                VStack(alignment: .leading, spacing: 2) {
                    Text(issue.subject).font(.caption.weight(.semibold))
                    Text(issue.message).font(.caption).foregroundStyle(Theme.Palette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Chiudi e mostra sulla scheda")
    }

    private var buttons: some View {
        HStack {
            if circuits.fabricationExporting {
                ProgressView().controlSize(.small)
                Text("Esportazione…").font(.caption)
                Spacer()
                Button("Annulla") { circuits.cancelFabricationExport() }
            } else {
                Spacer()
                Button("Chiudi") { circuits.closeFabrication() }.keyboardShortcut(.cancelAction)
                Button("Esporta…") { circuits.exportFabricationWithPanel() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!circuits.canExportFabrication)
                    .help("Crea una cartella nuova con Gerber, forature, BOM e CPL: non sovrascrive niente")
            }
        }
    }

    private func row(_ label: String, _ value: Binding<Double>) -> some View {
        GridRow {
            Text(label)
            TextField("", value: value, format: .number.precision(.fractionLength(0...3))).frame(width: 80)
            Text("mm").foregroundStyle(Theme.Palette.textSecondary)
        }
    }

    static func name(_ kind: FabricationLayerKind) -> String {
        switch kind {
        case .topCopper: "Rame sopra"; case .bottomCopper: "Rame sotto"
        case .topMask: "Maschera sopra"; case .bottomMask: "Maschera sotto"
        case .topPaste: "Pasta sopra"; case .bottomPaste: "Pasta sotto"
        case .topSilkscreen: "Serigrafia sopra"; case .bottomSilkscreen: "Serigrafia sotto"
        case .profile: "Contorno"
        }
    }
}

/// One fabrication layer as the engine will write it: flashes and strokes (a core swept by a
/// disk), filled regions, the board outline and — on copper — the holes. Masks are shown as the
/// openings (the Gerber is negative).
struct FabricationLayerView: View {
    let preview: FabricationPreview?
    let layer: FabricationLayerKind
    /// The check failed (e.g. an invalid profile): nothing is coming, no spinner.
    var failed = false

    var body: some View {
        Canvas { ctx, size in
            guard let preview else { return }
            let outline = preview.layers.first { $0.kind == .profile }?.objects.flatMap(\.core) ?? []
            let all = outline.isEmpty ? preview.layers.flatMap { $0.objects.flatMap(\.core) } : outline
            guard let minX = all.map(\.x).min(), let maxX = all.map(\.x).max(),
                  let minY = all.map(\.y).min(), let maxY = all.map(\.y).max(), maxX > minX, maxY > minY else { return }
            let scale = min((size.width - 24) / (maxX - minX), (size.height - 24) / (maxY - minY))
            let ox = (size.width - (maxX - minX) * scale) / 2, oy = (size.height - (maxY - minY) * scale) / 2
            func screen(_ p: PCBPoint) -> CGPoint { CGPoint(x: ox + (p.x - minX) * scale, y: size.height - oy - (p.y - minY) * scale) }
            let color: Color = switch layer {
            case .topCopper, .bottomCopper: .orange
            case .topMask, .bottomMask: .green
            case .topPaste, .bottomPaste: .gray
            case .topSilkscreen, .bottomSilkscreen: .white
            case .profile: .yellow
            }
            for object in preview.layers.first(where: { $0.kind == layer })?.objects ?? [] {
                let core = object.core
                guard !core.isEmpty else { continue }
                let w = max(CGFloat(2 * object.radius) * scale, 1)
                if core.count == 1 {
                    let c = screen(core[0]), r = w / 2
                    ctx.fill(Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r)), with: .color(color))
                    continue
                }
                var path = Path()
                path.move(to: screen(core[0]))
                for p in core.dropFirst() { path.addLine(to: screen(p)) }
                switch object.kind {
                case .region:
                    path.closeSubpath(); ctx.fill(path, with: .color(color))
                case .flash:
                    if core.count > 2 { path.closeSubpath(); ctx.fill(path, with: .color(color)) }
                    ctx.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: w, lineCap: .round, lineJoin: .round))
                case .stroke:
                    ctx.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: w, lineCap: .round, lineJoin: .round))
                }
            }
            if layer == .topCopper || layer == .bottomCopper {
                for d in preview.drills {
                    let c = screen(d.position), r = max(CGFloat(d.diameter / 2) * scale, 1)
                    ctx.fill(Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r)), with: .color(.black))
                }
            }
            if layer != .profile, !outline.isEmpty {
                var path = Path()
                path.move(to: screen(outline[0]))
                for p in outline.dropFirst() { path.addLine(to: screen(p)) }
                ctx.stroke(path, with: .color(.yellow.opacity(0.6)), lineWidth: 1)
            }
        }
        .overlay {
            if preview == nil {
                if failed { Text("Nessuna anteprima: correggi il profilo").font(.caption).foregroundStyle(.secondary) }
                else { ProgressView() }
            }
        }
    }
}
