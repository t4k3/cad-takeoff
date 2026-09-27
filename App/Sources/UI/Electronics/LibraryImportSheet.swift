import ElectronicsCore
import SwiftUI

/// LIBRERIA › Importa, step 2: what the engine proposes (docs/electronics/LIBRARY_REVISIONS.md).
/// A new definition, or a new revision compared with every revision it follows: fields changed,
/// pins, pads and graphics added, removed or changed, the footprint before and after, and the
/// components pinned to the old revision (they stay on it: nothing is replaced).
struct ImportPreviewSheet: View {
    @Environment(CircuitModel.self) private var circuits

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let p = circuits.importProposal {
                Label("Importa \(p.fileName)", systemImage: "square.and.arrow.down.on.square").font(.headline)
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(p.symbols, id: \.key) { s in
                            Label("Simbolo \(s.name) · \(s.pins.count) pin · revisione \(s.key.revision)", systemImage: "function")
                        }
                        ForEach(p.footprints, id: \.key) { f in
                            Label("Impronta \(f.name) · \(f.pads.count) piazzole · revisione \(f.key.revision)", systemImage: "square.grid.2x2")
                        }
                        if p.preview.revisionDiffs.isEmpty {
                            Text("Già nella libreria con lo stesso contenuto: importare non cambia nulla.")
                                .font(.caption).foregroundStyle(Theme.Palette.textSecondary)
                        }
                        ForEach(Array(p.preview.revisionDiffs.enumerated()), id: \.offset) { _, diff in
                            RevisionDiffView(diff: diff, shapes: p.footprintShapes)
                        }
                        if !p.preview.issues.isEmpty {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Da controllare").font(.caption.weight(.semibold))
                                ForEach(Array(p.preview.issues.enumerated()), id: \.offset) { _, issue in
                                    Label(issue.message, systemImage: issue.severity == .error ? "xmark.octagon" : "exclamationmark.triangle")
                                        .font(.caption).foregroundStyle(issue.severity == .error ? Color.red : Color.orange)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                        }
                        Text("Una revisione nuova si aggiunge: i componenti già posati restano sulla loro. Poi LIBRERIA › Nuovo tipo unisce simbolo e impronta in un componente da posare.")
                            .font(.caption).foregroundStyle(Theme.Palette.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Lettura di \(circuits.importing ?? "…") e confronto con la libreria…").font(.caption)
                }
                Spacer(minLength: 0)
            }
            HStack {
                Spacer()
                Button("Annulla") { circuits.cancelImport() }.keyboardShortcut(.cancelAction)
                Button("Importa") { circuits.confirmImport() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(circuits.importProposal == nil)
            }
        }
        .padding(16).frame(width: 560, height: 560)
    }
}

/// One comparison: a new definition, or revision N → M, with what changed and who uses N.
private struct RevisionDiffView: View {
    @Environment(CircuitModel.self) private var circuits
    let diff: LibraryRevisionDiff
    let shapes: [LibraryRevision: LibraryFootprintSnapshot]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: diff.before == nil ? "plus.circle" : "arrow.triangle.2.circlepath").foregroundStyle(.tint)
                Text(title).font(.subheadline.weight(.semibold))
            }
            if diff.isOlderRevision {
                Label("La revisione importata è PIÙ VECCHIA di quella presente: confronto esplicito, nessun componente viene retrocesso.",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
            if diff.before != nil {
                if diff.changedFields.isEmpty {
                    Text("Contenuto identico alla revisione precedente.").font(.caption).foregroundStyle(Theme.Palette.textSecondary)
                } else {
                    Text("Cambiano: " + diff.changedFields.map(Self.label).joined(separator: ", ")).font(.caption)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if case let .footprint(after) = diff.after, let shape = shapes[after.key] {
                FootprintBeforeAfter(before: { if case let .footprint(b)? = diff.before { shapes[b.key] } else { nil } }(), after: shape)
                    .frame(height: 170)
            }
            changes("Pin", diff.pins) { p in "\(p.number ?? p.name) «\(p.name)»" } detail: { b, a in
                b.name != a.name || b.number != a.number ? "\(b.number ?? b.name) «\(b.name)» → \(a.number ?? a.name) «\(a.name)»" : "tipo o disegno"
            }
            changes("Piazzole", diff.pads) { p in "\(p.number) (\(mm(p.center.x)); \(mm(p.center.y))) mm" } detail: { b, a in
                var parts: [String] = []
                if b.center != a.center { parts.append("centro (\(mm(b.center.x)); \(mm(b.center.y))) → (\(mm(a.center.x)); \(mm(a.center.y))) mm") }
                if b.size != a.size { parts.append("misura \(mm(b.size.x)) × \(mm(b.size.y)) → \(mm(a.size.x)) × \(mm(a.size.y)) mm") }
                if b.drillDiameter != a.drillDiameter { parts.append("foro \(b.drillDiameter.map { mm($0) + " mm" } ?? "—") → \(a.drillDiameter.map { mm($0) + " mm" } ?? "—")") }
                if b.number != a.number { parts.append("numero \(b.number) → \(a.number)") }
                return parts.isEmpty ? "forma o strati" : parts.joined(separator: " · ")
            }
            if !diff.graphics.isEmpty {
                let g = counts(diff.graphics)
                Text("Grafica: \(g)").font(.caption)
            }
            if diff.before != nil {
                let refs = diff.affectedComponentIDs.compactMap { id in circuits.design?.components.first { $0.id == id }?.reference }
                Text(refs.isEmpty ? "Nessun componente usa la revisione \(diff.before!.key.revision)."
                                  : "Da valutare (restano sulla revisione \(diff.before!.key.revision)): " + refs.joined(separator: ", "))
                    .font(.caption).foregroundStyle(refs.isEmpty ? Theme.Palette.textSecondary : Color.primary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(10)
        .background(Theme.Palette.panelRaised, in: RoundedRectangle(cornerRadius: 8))
    }

    private var title: String {
        let kind: String, name: String
        switch diff.after {
        case let .symbol(s): kind = "Simbolo"; name = s.name
        case let .footprint(f): kind = "Impronta"; name = f.name
        case let .device(d): kind = "Tipo"; name = d.manufacturerPartNumber.isEmpty ? "componente" : d.manufacturerPartNumber
        }
        guard let before = diff.before else { return "\(kind) \(name): nuova (revisione \(diff.after.key.revision))" }
        return "\(kind) \(name): revisione \(before.key.revision) → \(diff.after.key.revision)"
    }

    @ViewBuilder
    private func changes<T>(_ title: String, _ list: [LibraryEntityChange<T>], name: @escaping (T) -> String,
                            detail: @escaping (T, T) -> String) -> some View {
        if !list.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                Text("\(title): \(counts(list))").font(.caption.weight(.medium))
                ForEach(Array(list.prefix(12).enumerated()), id: \.offset) { _, c in
                    Group {
                        switch c.kind {
                        case .added: Text("+ \(name(c.after!))").foregroundStyle(.green)
                        case .removed: Text("− \(name(c.before!))").foregroundStyle(.red)
                        case .modified: Text("~ \(name(c.after!)): \(detail(c.before!, c.after!))")
                        }
                    }
                    .font(.caption.monospacedDigit())
                    .fixedSize(horizontal: false, vertical: true)
                }
                if list.count > 12 { Text("… e altre \(list.count - 12)").font(.caption).foregroundStyle(Theme.Palette.textSecondary) }
            }
        }
    }

    private func counts<T>(_ list: [LibraryEntityChange<T>]) -> String {
        let a = list.filter { $0.kind == .added }.count, r = list.filter { $0.kind == .removed }.count, m = list.filter { $0.kind == .modified }.count
        return [a > 0 ? "\(a) aggiunte" : nil, r > 0 ? "\(r) tolte" : nil, m > 0 ? "\(m) cambiate" : nil].compactMap { $0 }.joined(separator: ", ")
    }

    /// Millimetres to 3 decimals, decimal comma, and never «-0».
    private func mm(_ v: Double) -> String {
        (abs(v) < 0.0005 ? 0 : v).formatted(.number.precision(.fractionLength(0...3)).locale(Locale(identifier: "it_IT")))
    }

    static func label(_ f: LibraryChangedField) -> String {
        switch f {
        case .definition: "definizione"; case .name: "nome"; case .source: "provenienza"; case .properties: "proprietà"
        case .pins: "pin"; case .pads: "piazzole"; case .graphics: "grafica"; case .assemblyCentroid: "centro di presa"
        case .model3D: "modello 3D"; case .manufacturer: "produttore"; case .manufacturerPartNumber: "codice produttore"
        case .symbol: "simbolo"; case .footprint: "impronta"; case .pinMap: "abbinamento pin"; case .supplier: "fornitore"
        }
    }
}

/// The footprint's pads before (dashed, grey) and after (filled), as the engine's exact shapes:
/// each pad its core swept by a disk (rotation applied), one outline with its hole cut out.
private struct FootprintBeforeAfter: View {
    let before: LibraryFootprintSnapshot?
    let after: LibraryFootprintSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Canvas { ctx, size in
                let boxes = [after.bounds] + (before.map { [$0.bounds] } ?? [])
                let minX = boxes.map(\.minimum.x).min()!, maxX = boxes.map(\.maximum.x).max()!
                let minY = boxes.map(\.minimum.y).min()!, maxY = boxes.map(\.maximum.y).max()!
                let w = max(maxX - minX, 0.1), h = max(maxY - minY, 0.1)
                let scale = min((size.width - 16) / w, (size.height - 16) / h)
                let ox = (size.width - w * scale) / 2, oy = (size.height - h * scale) / 2
                func screen(_ p: PCBPoint) -> CGPoint { CGPoint(x: ox + (p.x - minX) * scale, y: size.height - oy - (p.y - minY) * scale) }
                /// The pad as one closed shape: core ⊕ disk, minus its hole.
                func shape(_ p: LibraryPadPrimitive) -> Path {
                    let width = CGFloat(2 * p.radius) * scale
                    var core = Path()
                    if p.core.count == 1 {
                        let c = screen(p.core[0]), r = width / 2
                        core.addEllipse(in: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r))
                    } else {
                        core.move(to: screen(p.core[0]))
                        for q in p.core.dropFirst() { core.addLine(to: screen(q)) }
                        if p.core.count > 2 { core.closeSubpath() }
                        if width > 0 {
                            let swept = core.strokedPath(StrokeStyle(lineWidth: width, lineCap: .round, lineJoin: .round))
                            core = p.core.count > 2 ? core.union(swept) : swept
                        }
                    }
                    guard let d = p.drillDiameter else { return core }
                    let c = screen(p.center), r = CGFloat(d / 2) * scale
                    return core.subtracting(Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r)))
                }
                for p in after.pads { ctx.fill(shape(p), with: .color(.orange.opacity(0.85))) }
                for p in before?.pads ?? [] { ctx.stroke(shape(p), with: .color(.gray), style: StrokeStyle(lineWidth: 1.2, dash: [3, 2])) }
            }
            .background(Color.black.opacity(0.8), in: RoundedRectangle(cornerRadius: 6))
            Text(before == nil ? "Impronta nuova" : "Tratteggio: prima · pieno: dopo")
                .font(.caption2).foregroundStyle(Theme.Palette.textSecondary)
        }
    }
}
