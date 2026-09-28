import ElectronicsCore
import SwiftUI

/// The imported board, from above: its CAM layers, the drills and a marker per component
/// (filled: mounted in the lot shown; hollow: excluded, still on the board). Click a marker to
/// choose the component; drag pans, pinch or the buttons zoom.
struct CAMBoardView: View {
    @Environment(CircuitModel.self) private var circuits
    @State private var drawing: (id: UUID, value: CAMDrawing)?
    @State private var zoom: CGFloat = 1
    @State private var pan: CGSize = .zero
    @State private var panStart: CGSize?
    @State private var hovered: UUID?
    /// The finished-board picture of the side shown in the assembled view.
    @State private var picture: (key: String, image: CGImage)?
    @GestureState private var pinch: CGFloat = 1

    var body: some View {
        if let package = circuits.manufacturing {
            GeometryReader { geo in
                let m = CAMMapping(bounds: package.bounds, size: geo.size, zoom: zoom * pinch, pan: pan)
                let fitted = Set(package.activeLot?.fittedComponentIDs ?? [])
                // Everything the drawing depends on is read HERE, in the body: a value read only
                // inside the Canvas closure is no dependency, and the board would appear only at
                // the next unrelated redraw (Ross's «after a minute», T110).
                let art = drawing?.id == package.id ? drawing?.value : nil
                let hidden = circuits.camHiddenLayers, showDrills = !circuits.camHideDrills
                let chosen = circuits.camSelection, hover = hovered
                let assembled = circuits.camView == .assembly
                let snapshot = circuits.assembly?.snapshot, side = circuits.assemblySide, showExcluded = circuits.showExcluded
                let draft = circuits.alignDraft?.preview
                let pictureKey = "\(package.id)/\(side.rawValue)/\(snapshot != nil)"
                let sidePicture = picture?.key == pictureKey ? picture?.image : nil
                Canvas { ctx, _ in
                    if assembled {
                        CAMBoardView.drawAssembly(&ctx, m, picture: sidePicture, bounds: package.bounds, snapshot: snapshot, side: side,
                                                  showExcluded: showExcluded, selection: chosen, hover: hover, draft: draft)
                        return
                    }
                    if let art {
                        var board = ctx
                        board.concatenate(m.transform)
                        art.draw(&board, hidden: hidden, drills: showDrills)
                    }
                    for c in package.components {
                        guard let p = c.placement?.position else { continue }
                        let q = m.screen(p), on = fitted.contains(c.id)
                        let selected = chosen == c.id, lit = selected || hover == c.id
                        let r: CGFloat = lit ? 5 : 3.5
                        let dot = Path(ellipseIn: CGRect(x: q.x - r, y: q.y - r, width: 2 * r, height: 2 * r))
                        if on { ctx.fill(dot, with: .color(Theme.Palette.accent)) }
                        ctx.stroke(dot, with: .color(on ? .white : .red), lineWidth: on ? 1 : 1.5)
                        if lit || m.scale > 14 {
                            ctx.draw(Text(c.reference).font(.system(size: 10, weight: selected ? .bold : .regular)).foregroundStyle(on ? .white : .red),
                                     at: CGPoint(x: q.x, y: q.y - r - 7))
                        }
                    }
                }
                .background(Color(red: 0.11, green: 0.12, blue: 0.14))
                .contentShape(Rectangle())
                .onContinuousHover { phase in
                    if case let .active(q) = phase { hovered = pick(m.board(q), Double(8 / m.scale), assembled) }
                    else { hovered = nil }
                }
                .gesture(DragGesture(minimumDistance: 2)
                    .onChanged { g in
                        let s = panStart ?? pan
                        if panStart == nil { panStart = pan }
                        pan = CGSize(width: s.width + g.translation.width, height: s.height + g.translation.height)
                    }
                    .onEnded { _ in panStart = nil })
                .simultaneousGesture(SpatialTapGesture().onEnded { tap in
                    circuits.camSelection = pick(m.board(tap.location), Double(8 / m.scale), assembled)
                })
                .gesture(MagnifyGesture().updating($pinch) { value, state, _ in state = value.magnification }
                    .onEnded { value in zoom = min(max(zoom * value.magnification, 0.2), 60) })
                .overlay(alignment: .bottomTrailing) { zoomButtons.padding(12) }
                .overlay(alignment: .topLeading) { chip(package).padding(12) }
                // Keyed also on the CAM drawing being ready: it arrives from another task.
                .task(id: assembled ? pictureKey + "/\(art != nil)" : "") {
                    guard assembled, let snapshot, let art, picture?.key != pictureKey else { return }
                    let mesh = AssemblyMesh(snapshot, outline: package.bounds)
                    let base = mesh.batches.first { $0.look == (side == .top ? .boardTop : .boardBottom) }?.positions ?? []
                    if let image = BoardPicture.render(art, bounds: package.bounds, base: base, side: side) { picture = (pictureKey, image) }
                }
                .overlay {
                    if art == nil || (assembled && (snapshot == nil || sidePicture == nil)) {
                        HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Preparo gli strati…").font(.callout) }
                            .padding(10).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
                    }
                }
            }
            .task(id: package.id) {
                if drawing?.id != package.id { drawing = (package.id, CAMDrawing(package)) }
            }
        }
    }

    private func pick(_ p: PCBPoint, _ tolerance: Double, _ assembled: Bool) -> UUID? {
        assembled ? circuits.assemblyComponent(at: p, tolerance: tolerance) : circuits.manufacturingComponent(at: p, tolerance: tolerance)
    }

    private var zoomButtons: some View {
        HStack(spacing: 4) {
            Button { zoom = max(zoom / 1.4, 0.2) } label: { Image(systemName: "minus.magnifyingglass") }
            Button { zoom = 1; pan = .zero } label: { Image(systemName: "arrow.up.left.and.down.right.magnifyingglass") }
                .help("Adatta la scheda alla vista")
            Button { zoom = min(zoom * 1.4, 60) } label: { Image(systemName: "plus.magnifyingglass") }
        }
        .buttonStyle(.bordered)
    }

    @ViewBuilder private func chip(_ package: ManufacturingPackage) -> some View {
        if let id = hovered ?? circuits.camSelection, let c = package.components.first(where: { $0.id == id }) {
            VStack(alignment: .leading, spacing: 2) {
                Text(c.reference).font(.caption.weight(.semibold))
                Text([c.value, c.footprint, c.lcscPartNumber].compactMap { $0 }.joined(separator: " · "))
                    .font(.caption2)
                Text(package.isFitted(c.id) ? "Montato nel lotto «\(package.activeLot?.name ?? "")»" : "Escluso dal lotto: resta sulla scheda")
                    .font(.caption2).foregroundStyle(package.isFitted(c.id) ? Color.secondary : Color.red)
            }
            .padding(8)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
        }
    }
}

/// The imported board's parts and lots: the lot shown (to switch or copy), each component with
/// its «Monta» box (one undo step each), and what to check before ordering.
struct ManufacturingPanel: View {
    @Environment(CircuitModel.self) private var circuits
    @State private var filter = ""
    @State private var newLot: String?

    var body: some View {
        if let package = circuits.manufacturing {
            let fitted = Set(package.activeLot?.fittedComponentIDs ?? [])
            VStack(alignment: .leading, spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(package.name).font(.headline).lineLimit(1)
                    Text("\(CAMDrawing.mm(package.bounds.width)) × \(CAMDrawing.mm(package.bounds.height)) · \(package.layers.count) strati · \(package.drills.count) fori")
                        .font(.caption).foregroundStyle(Theme.Palette.textSecondary)
                }
                HStack {
                    Picker("Lotto", selection: Binding(get: { package.activeLotID }, set: { circuits.selectLot($0) })) {
                        ForEach(package.lots, id: \.id) { Text($0.name).tag($0.id) }
                    }
                    Button { newLot = circuits.nextLotName() } label: { Image(systemName: "plus") }
                        .help("Nuovo lotto: una copia di quello mostrato, da cambiare")
                }
                Text("\(fitted.count) di \(package.components.count) componenti montati")
                    .font(.caption).foregroundStyle(Theme.Palette.textSecondary)
                BoardThicknessRow()
                if let id = circuits.camSelection, let c = package.components.first(where: { $0.id == id }) {
                    AssemblyComponentDetail(component: c)
                }
                TextField("Cerca sigla, valore, codice", text: $filter).textFieldStyle(.roundedBorder)
                List(selection: Binding(get: { circuits.camSelection }, set: { circuits.camSelection = $0 })) {
                    ForEach(package.components.filter(matches), id: \.id) { c in
                        HStack(spacing: 6) {
                            Toggle("", isOn: Binding(get: { fitted.contains(c.id) }, set: { circuits.setFitted(c.id, $0) }))
                                .labelsHidden().toggleStyle(.checkbox)
                                .help("Monta in questo lotto; escluso resta sulla scheda")
                            Text(c.reference).font(.caption.monospaced()).frame(width: 44, alignment: .leading)
                            Text(c.value ?? "—").font(.caption).lineLimit(1)
                            Spacer(minLength: 0)
                            if let i = circuits.assemblyInstance(c.id) {
                                let q = AssemblyLook.quality(i.quality, aligned: i.alignmentVerified)
                                Image(systemName: q.symbol).foregroundStyle(q.colour).help(q.text)
                            }
                            if c.placement == nil {
                                Image(systemName: "location.slash").foregroundStyle(.orange).help("Senza posizione nel CPL")
                            }
                            if fitted.contains(c.id), c.lcscPartNumber?.isEmpty != false {
                                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange).help("Codice LCSC assente")
                            } else if let code = c.lcscPartNumber {
                                Text(code).font(.caption2.monospaced()).foregroundStyle(Theme.Palette.textSecondary)
                            }
                        }
                        .tag(c.id)
                    }
                }
                .listStyle(.plain)
                .frame(maxHeight: .infinity)
                Text("Scheda importata dai file di produzione: niente schema, piste da modificare, verifiche DRC o export rigenerato. Qui si sceglie cosa montare in ogni lotto; i corpi dei componenti sono modelli approssimati da controllare.")
                    .font(.caption2).foregroundStyle(Theme.Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(10)
            .background(Theme.Palette.panel)
            .alert("Nuovo lotto", isPresented: Binding(get: { newLot != nil }, set: { if !$0 { newLot = nil } })) {
                TextField("Nome", text: Binding(get: { newLot ?? "" }, set: { newLot = $0 }))
                Button("Crea") { if let n = newLot { circuits.addLot(named: n) }; newLot = nil }
                Button("Annulla", role: .cancel) { newLot = nil }
            } message: {
                Text("Copia dei componenti montati nel lotto «\(package.activeLot?.name ?? "")».")
            }
        }
    }

    private func matches(_ c: ManufacturingComponent) -> Bool {
        let f = filter.trimmingCharacters(in: .whitespaces)
        guard !f.isEmpty else { return true }
        return [c.reference, c.value, c.footprint, c.lcscPartNumber].compactMap { $0 }.contains { $0.localizedCaseInsensitiveContains(f) }
    }
}

/// Which CAM layers to see (and the drills), in the canvas bar.
struct CAMLayerToggles: View {
    @Environment(CircuitModel.self) private var circuits

    var body: some View {
        @Bindable var c = circuits
        HStack(spacing: 10) {
            Picker("", selection: $c.camView) { ForEach(CircuitModel.CAMView.allCases) { Text($0.rawValue).tag($0) } }
                .pickerStyle(.segmented).labelsHidden().fixedSize()
                .help("Gerber: gli strati del produttore · Assemblata: la scheda finita con i componenti, un lato alla volta · 3D")
            if circuits.camView == .gerber { layerToggles }
            if circuits.camView == .assembly {
                Picker("", selection: $c.assemblySide) { Text("Sopra").tag(BoardSide.top); Text("Sotto").tag(BoardSide.bottom) }
                    .pickerStyle(.segmented).labelsHidden().fixedSize()
                    .help("Lato mostrato, sempre visto dall'alto come nei Gerber (il lato sotto non è specchiato)")
            }
            if circuits.camView != .gerber {
                Button { circuits.showExcluded.toggle() } label: {
                    HStack(spacing: 3) {
                        Image(systemName: circuits.showExcluded ? "checkmark.square" : "square")
                        Text("Esclusi")
                    }
                    .font(.caption)
                    .fixedSize()
                }
                .buttonStyle(.plain)
                .help("Mostra, sbiaditi, i componenti esclusi dal lotto")
            }
        }
    }

    private var layerToggles: some View {
        let kinds = CAMDrawing.order.filter { k in circuits.manufacturing?.layers.contains { $0.kind == k } == true }
        return HStack(spacing: 4) {
            ForEach(kinds.reversed(), id: \.self) { kind in
                let on = !circuits.camHiddenLayers.contains(kind)
                Button {
                    if on { circuits.camHiddenLayers.insert(kind) } else { circuits.camHiddenLayers.remove(kind) }
                } label: {
                    Label(CAMDrawing.name(kind), systemImage: on ? "square.fill" : "square")
                        .foregroundStyle(on ? CAMDrawing.colour(kind).0 : Theme.Palette.textSecondary)
                        .font(.caption)
                }
                .buttonStyle(.plain)
            }
            Button { circuits.camHideDrills.toggle() } label: {
                Label("Fori", systemImage: circuits.camHideDrills ? "circle" : "circle.fill").font(.caption)
            }
            .buttonStyle(.plain)
        }
    }
}

/// PRODUZIONE › Importa: what the engine read — where it goes, the board, its layers and drills,
/// the lot (who is excluded) and the warnings — before anything changes.
struct ManufacturingImportSheet: View {
    @Environment(CircuitModel.self) private var circuits
    @State private var lotName = ""
    @State private var drawing: (id: UUID, value: CAMDrawing)?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Importa scheda da file di produzione", systemImage: "square.and.arrow.down.on.square").font(.headline)
            if let p = circuits.manufacturingProposal {
                HStack(alignment: .top, spacing: 16) {
                    summary(p).frame(width: 330)
                    preview(p.package)
                        .frame(minWidth: 360, maxWidth: .infinity, maxHeight: .infinity)
                        .background(Color(red: 0.11, green: 0.12, blue: 0.14), in: RoundedRectangle(cornerRadius: 6))
                }
                HStack {
                    Spacer()
                    Button("Annulla") { circuits.cancelImport() }.keyboardShortcut(.cancelAction)
                    Button(p.inNewCircuit ? "Importa in un circuito nuovo" : "Importa") { circuits.confirmManufacturingImport() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(!p.canApply || lotName != p.package.activeLot?.name)
                }
            } else {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Lettura di \(circuits.importing ?? "")…").font(.callout)
                    Spacer()
                    Button("Annulla") { circuits.cancelImport() }.keyboardShortcut(.cancelAction)
                }
                Spacer()
            }
        }
        .padding(16)
        .frame(width: 820, height: 580)
    }

    private func summary(_ p: CircuitModel.ManufacturingProposal) -> some View {
        let package = p.package
        let fitted = Set(package.activeLot?.fittedComponentIDs ?? [])
        let excluded = package.components.filter { !fitted.contains($0.id) }.map(\.reference)
        let plated = package.drills.filter(\.isPlated).count
        let warnings = p.issues.filter { $0.code != "manufacturing_not_fitted" }
        return ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                Group {
                    if let lotOf = p.addsLotTo {
                        Label("Nuovo lotto della scheda «\(lotOf)» già aperta", systemImage: "plus.square.on.square")
                    } else if p.inNewCircuit {
                        Label("In un circuito nuovo: quello aperto ha un progetto o un'altra scheda", systemImage: "doc.badge.plus")
                    } else {
                        Label("Nel circuito aperto (vuoto)", systemImage: "doc")
                    }
                }
                .font(.caption.weight(.semibold))
                VStack(alignment: .leading, spacing: 2) {
                    ForEach([p.files.archive, p.files.bom, p.files.positions], id: \.self) { url in
                        Text(url.lastPathComponent).font(.caption.monospaced()).foregroundStyle(Theme.Palette.textSecondary)
                    }
                }
                Text("Scheda \(CAMDrawing.mm(package.bounds.width)) × \(CAMDrawing.mm(package.bounds.height))").font(.callout)
                Text("\(package.layers.count) strati: " + CAMDrawing.order.reversed().filter { k in package.layers.contains { $0.kind == k } }.map(CAMDrawing.name).joined(separator: ", "))
                    .font(.caption)
                Text("\(package.drills.count) fori: \(plated) metallizzati, \(package.drills.count - plated) non metallizzati").font(.caption)
                HStack {
                    Text("Lotto")
                    TextField("Nome del lotto", text: $lotName)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { circuits.renameImportedLot(lotName) }
                    if lotName != package.activeLot?.name {
                        Button("Rileggi") { circuits.renameImportedLot(lotName) }
                            .help("Rifà l'anteprima con questo nome di lotto (un lotto con BOM diversa vuole un nome nuovo)")
                    }
                }
                .onAppear { lotName = package.activeLot?.name ?? "" }
                .onChange(of: package.activeLotID) { _, _ in lotName = package.activeLot?.name ?? "" }
                Text("\(fitted.count) di \(package.components.count) componenti da montare").font(.callout)
                if !excluded.isEmpty {
                    Text("Esclusi dal lotto (DNP o assenti dalla BOM), restano sulla scheda: " + excluded.joined(separator: ", "))
                        .font(.caption).foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if !warnings.isEmpty {
                    Divider()
                    ForEach(Array(warnings.enumerated()), id: \.offset) { _, issue in
                        Label(issue.message, systemImage: issue.severity == .error ? "xmark.octagon.fill" : "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(issue.severity == .error ? Color.red : Color.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Divider()
                Text("Dai file di produzione arrivano strati, fori, BOM e posizioni: non lo schema, lo storico del progetto originale o i modelli 3D. La scheda non si modifica come un PCB nativo; si sceglie cosa montare per lotto.")
                    .font(.caption2).foregroundStyle(Theme.Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func preview(_ package: ManufacturingPackage) -> some View {
        GeometryReader { geo in
            let m = CAMMapping(bounds: package.bounds, size: geo.size, margin: 16)
            let fitted = Set(package.activeLot?.fittedComponentIDs ?? [])
            let art = drawing?.id == package.id ? drawing?.value : nil   // read in the body: a dependency
            Canvas { ctx, _ in
                guard let art else { return }
                var board = ctx
                board.concatenate(m.transform)
                art.draw(&board, hidden: [.topMask, .bottomMask, .topPaste, .bottomPaste], drills: true)
                for c in package.components {
                    guard let p = c.placement?.position, !fitted.contains(c.id) else { continue }
                    let q = m.screen(p)
                    ctx.stroke(Path(ellipseIn: CGRect(x: q.x - 5, y: q.y - 5, width: 10, height: 10)), with: .color(.red), lineWidth: 1.5)
                    ctx.draw(Text(c.reference).font(.caption2).foregroundStyle(.red), at: CGPoint(x: q.x, y: q.y - 12))
                }
            }
        }
        .task(id: package.id) { if drawing?.id != package.id { drawing = (package.id, CAMDrawing(package)) } }
    }
}
