import ElectronicsCore
import SwiftUI

/// The CAM artwork of an imported board as paths in board millimetres, built once per package:
/// each primitive's shapes in order (dark adds, clear removes, inside that primitive only), then
/// the primitive on its layer by its own polarity — the engine's contract, nothing re-interpreted.
struct CAMDrawing {
    struct Part { var path: Path; var width: CGFloat?; var filled = true; var isDark: Bool }
    struct Item { var parts: [Part]; var isDark: Bool; var simple: Bool }
    struct Layer { var kind: FabricationLayerKind; var name: String; var items: [Item] }
    var layers: [Layer]
    var drills: [(path: Path, width: CGFloat, plated: Bool)]

    init(_ package: ManufacturingPackage) {
        func cg(_ p: PCBPoint) -> CGPoint { CGPoint(x: p.x, y: p.y) }
        layers = package.layers.map { layer in
            Layer(kind: layer.kind, name: layer.name, items: layer.primitives.map { primitive in
                let parts = primitive.shapes.compactMap { shape -> Part? in
                    var path = Path()
                    if shape.radius > 0 {
                        // A point: a disk; two points: a capsule; a polygon: filled, its border
                        // widened by the radius (a stroke with round ends and joins).
                        var filled = false
                        for c in shape.contours where !c.isEmpty {
                            path.move(to: cg(c[0]))
                            if c.count == 1 { path.addLine(to: cg(c[0])) }
                            for p in c.dropFirst() { path.addLine(to: cg(p)) }
                            if c.count > 2 { path.closeSubpath(); filled = true }
                        }
                        return path.isEmpty ? nil : Part(path: path, width: 2 * shape.radius, filled: filled, isDark: shape.isDark)
                    }
                    for c in shape.contours where c.count > 2 { path.addLines(c.map(cg)); path.closeSubpath() }
                    return path.isEmpty ? nil : Part(path: path, width: nil, isDark: shape.isDark)
                }
                return Item(parts: parts, isDark: primitive.isDark, simple: parts.allSatisfy(\.isDark))
            })
        }
        drills = package.drills.map { d in
            var path = Path()
            path.move(to: cg(d.position)); path.addLine(to: cg(d.end ?? d.position))
            return (path, d.diameter, d.isPlated)
        }
    }

    /// Bottom side first, the top over it, the outline last.
    static let order: [FabricationLayerKind] = [.bottomSilkscreen, .bottomPaste, .bottomMask, .bottomCopper,
                                                .topCopper, .topMask, .topPaste, .topSilkscreen, .profile]

    static func colour(_ kind: FabricationLayerKind) -> (Color, Double) {
        switch kind {
        case .topCopper: (Color(red: 0.86, green: 0.52, blue: 0.24), 0.9)
        case .bottomCopper: (Color(red: 0.33, green: 0.55, blue: 0.95), 0.7)
        case .topMask, .bottomMask: (Color(red: 0.2, green: 0.8, blue: 0.4), 0.45)
        case .topPaste, .bottomPaste: (Color(white: 0.75), 0.6)
        case .topSilkscreen: (Color.white, 0.9)
        case .bottomSilkscreen: (Color(white: 0.75), 0.6)
        case .profile: (Color.yellow, 1)
        }
    }

    static func name(_ kind: FabricationLayerKind) -> String { FabricationSheet.name(kind) }

    /// Draws the visible layers; `ctx` already maps board millimetres to the screen.
    func draw(_ ctx: inout GraphicsContext, hidden: Set<FabricationLayerKind>, drills showDrills: Bool) {
        for kind in Self.order where !hidden.contains(kind) {
            guard let layer = layers.first(where: { $0.kind == kind }) else { continue }
            let (colour, opacity) = Self.colour(kind)
            var layerCtx = ctx
            layerCtx.opacity = opacity
            layerCtx.drawLayer { l in
                for item in layer.items {
                    var target = l
                    target.blendMode = item.isDark ? .normal : .destinationOut
                    if item.simple {
                        for part in item.parts { Self.paint(part, in: &target, colour) }
                    } else {
                        target.drawLayer { local in
                            for part in item.parts {
                                var p = local
                                p.blendMode = part.isDark ? .normal : .destinationOut
                                Self.paint(part, in: &p, colour)
                            }
                        }
                    }
                }
            }
        }
        if showDrills {
            for d in drills {
                ctx.stroke(d.path, with: .color(.black), style: StrokeStyle(lineWidth: d.width, lineCap: .round))
                if !d.plated {
                    ctx.stroke(d.path, with: .color(.white.opacity(0.5)),
                               style: StrokeStyle(lineWidth: d.width, lineCap: .round, dash: [0.2, 0.2]))
                }
            }
        }
    }

    private static func paint(_ part: Part, in ctx: inout GraphicsContext, _ colour: Color) {
        if let w = part.width {
            if part.filled { ctx.fill(part.path, with: .color(colour), style: FillStyle(eoFill: true)) }
            ctx.stroke(part.path, with: .color(colour), style: StrokeStyle(lineWidth: w, lineCap: .round, lineJoin: .round))
        } else {
            ctx.fill(part.path, with: .color(colour), style: FillStyle(eoFill: true))
        }
    }
}

/// Board millimetres (Y up) to the view, fitting the board's outline.
struct CAMMapping {
    var scale: CGFloat, origin: CGPoint
    init(bounds: ManufacturingBounds, size: CGSize, zoom: CGFloat = 1, pan: CGSize = .zero, margin: CGFloat = 40) {
        let w = max(bounds.width, 1), h = max(bounds.height, 1)
        let fit = min((size.width - 2 * margin) / w, (size.height - 2 * margin) / h)
        scale = max(fit, 0.5) * zoom
        let centre = CGPoint(x: size.width / 2 + pan.width, y: size.height / 2 + pan.height)
        origin = CGPoint(x: centre.x - (bounds.minimum.x + w / 2) * scale, y: centre.y + (bounds.minimum.y + h / 2) * scale)
    }
    var transform: CGAffineTransform { CGAffineTransform(a: scale, b: 0, c: 0, d: -scale, tx: origin.x, ty: origin.y) }
    func screen(_ p: PCBPoint) -> CGPoint { CGPoint(x: origin.x + p.x * scale, y: origin.y - p.y * scale) }
    func board(_ q: CGPoint) -> PCBPoint { PCBPoint(Double((q.x - origin.x) / scale), Double((origin.y - q.y) / scale)) }
}

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
    @GestureState private var pinch: CGFloat = 1

    var body: some View {
        if let package = circuits.manufacturing {
            GeometryReader { geo in
                let m = CAMMapping(bounds: package.bounds, size: geo.size, zoom: zoom * pinch, pan: pan)
                let fitted = Set(package.activeLot?.fittedComponentIDs ?? [])
                Canvas { ctx, _ in
                    if let d = drawing?.value {
                        var board = ctx
                        board.concatenate(m.transform)
                        d.draw(&board, hidden: circuits.camHiddenLayers, drills: !circuits.camHideDrills)
                    }
                    for c in package.components {
                        guard let p = c.placement?.position else { continue }
                        let q = m.screen(p), on = fitted.contains(c.id)
                        let selected = circuits.camSelection == c.id, lit = selected || hovered == c.id
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
                    if case let .active(q) = phase { hovered = circuits.manufacturingComponent(at: m.board(q), tolerance: Double(8 / m.scale)) }
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
                    circuits.camSelection = circuits.manufacturingComponent(at: m.board(tap.location), tolerance: Double(8 / m.scale))
                })
                .gesture(MagnifyGesture().updating($pinch) { value, state, _ in state = value.magnification }
                    .onEnded { value in zoom = min(max(zoom * value.magnification, 0.2), 60) })
                .overlay(alignment: .bottomTrailing) { zoomButtons.padding(12) }
                .overlay(alignment: .topLeading) { chip(package).padding(12) }
            }
            .task(id: package.id) {
                if drawing?.id != package.id { drawing = (package.id, CAMDrawing(package)) }
            }
        }
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
                    Text("\(CircuitBoardView.mm(package.bounds.width)) × \(CircuitBoardView.mm(package.bounds.height)) · \(package.layers.count) strati · \(package.drills.count) fori")
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
                Text("Scheda importata dai file di produzione: niente schema, piste da modificare, verifiche DRC, export rigenerato o modelli 3D. Qui si sceglie cosa montare in ogni lotto.")
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
        let kinds = CAMDrawing.order.filter { k in circuits.manufacturing?.layers.contains { $0.kind == k } == true }
        HStack(spacing: 4) {
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
                Text("Scheda \(CircuitBoardView.mm(package.bounds.width)) × \(CircuitBoardView.mm(package.bounds.height))").font(.callout)
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
            Canvas { ctx, _ in
                guard let d = drawing?.value else { return }
                var board = ctx
                board.concatenate(m.transform)
                d.draw(&board, hidden: [.topMask, .bottomMask, .topPaste, .bottomPaste], drills: true)
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
