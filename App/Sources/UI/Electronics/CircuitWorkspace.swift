import ElectronicsCore
import SwiftUI

/// CIRCUITI: the board of the open circuit, seen from above (2D), and its checks. The engine
/// (ElectronicsCore) says where every pad is and which connections are still to route; this view
/// only draws them, lights up what is under the mouse and turns drags into engine transactions.
struct CircuitWorkspace: View {
    @Environment(CircuitModel.self) private var circuits

    var body: some View {
        if circuits.document == nil {
            emptyState
        } else {
            @Bindable var c = circuits
            HStack(spacing: 0) {
                VStack(spacing: 0) {
                    canvasBar
                    Divider()
                    if circuits.canvas == .schematic { CircuitSchematicView() } else { CircuitBoardView() }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                Divider()
                CircuitChecksPanel()
                    .frame(width: 280)
            }
            .sheet(isPresented: $c.showAddComponent) { AddComponentSheet() }
            .sheet(isPresented: $c.showBoard) { BoardSheet() }
            .sheet(isPresented: $c.showCreateDevice) { CreateDeviceSheet() }
            .sheet(isPresented: Binding(get: { circuits.importProposal != nil }, set: { if !$0 { circuits.importProposal = nil } })) { ImportPreviewSheet() }
            .sheet(isPresented: Binding(get: { circuits.symbolChoice != nil }, set: { if !$0 { circuits.symbolChoice = nil } })) { SymbolChoiceSheet() }
            .sheet(isPresented: Binding(get: { circuits.labelTarget != nil }, set: { if !$0 { circuits.labelTarget = nil } })) { LabelSheet() }
        }
    }

    /// Schema | PCB, the sheet shown (schematic), and what is still to place on the board.
    private var canvasBar: some View {
        @Bindable var c = circuits
        return HStack(spacing: 10) {
            Picker("", selection: $c.canvas) {
                ForEach(CircuitModel.Canvas.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented).labelsHidden().frame(width: 160)
            if circuits.canvas == .schematic {
                Menu {
                    ForEach(circuits.sheets, id: \.id) { sheet in
                        Button(sheet.name) { circuits.chosenSheet = sheet.id }
                    }
                    Divider()
                    Button("Nuovo foglio") { circuits.addSheet() }
                    if let id = circuits.currentSheetID, circuits.sheets.count > 1 {
                        Button("Elimina questo foglio") { circuits.removeSheet(id) }
                    }
                } label: {
                    Label(circuits.sheets.first { $0.id == circuits.currentSheetID }?.name ?? "Nessun foglio", systemImage: "doc")
                }
                .menuStyle(.borderlessButton).fixedSize()
                .help("Fogli dello schema")
            } else if let unplaced = circuits.board?.unplacedComponents, !unplaced.isEmpty {
                Button {
                    circuits.tool = .placeExisting(unplaced[0])
                } label: {
                    Label("\(unplaced.count) da posare dallo schema", systemImage: "arrow.down.to.line")
                }
                .help("Componenti disegnati nello schema e non ancora sulla scheda: clic, poi clic sulla scheda per ciascuno")
            }
            Spacer()
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(Theme.Palette.panel)
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "cpu").font(.system(size: 42)).foregroundStyle(Theme.Palette.textSecondary)
            Text("Circuiti").font(.title2.weight(.semibold))
            Text("Scheda, componenti e collegamenti da sbrogliare; verifiche e file per JLCPCB.")
                .font(.callout).foregroundStyle(Theme.Palette.textSecondary)
            HStack(spacing: 10) {
                Button { try? circuits.newCircuit() } label: { Label("Nuovo circuito", systemImage: "plus") }
                Button { circuits.openWithPanel() } label: { Label("Apri…", systemImage: "folder") }
                Button { circuits.openExample() } label: { Label("Esempio", systemImage: "sparkles") }
                    .help("Il circuito di prova del motore (componenti fittizi, da non ordinare)")
            }
            .controlSize(.large)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.Palette.canvas)
    }
}

/// The board from above. PCB millimetres, Y up; the view fits the board, pinch or the buttons
/// zoom, a drag in empty space pans, a drag on a component moves it (one undo step on release).
struct CircuitBoardView: View {
    @Environment(CircuitModel.self) private var circuits
    @State private var zoom: CGFloat = 1
    @State private var pan: CGSize = .zero
    @State private var panStart: CGSize?
    @State private var hoveredPad: PlacedPad?
    /// The track or via under the mouse (not on a pad).
    @State private var hoveredCopper: PCBHit?
    /// Where the mouse is on the board (placing a component, the Collega rubber band), on the
    /// 0,5 mm grid, and exactly.
    @State private var cursor: PCBPoint?
    @State private var pointer: PCBPoint?

    @State private var dragging: (component: UUID, from: PCBPoint, delta: PCBPoint)?
    @GestureState private var pinch: CGFloat = 1
    @FocusState private var focused: Bool

    private struct Mapping {
        var scale: CGFloat, origin: CGPoint
        func screen(_ p: PCBPoint) -> CGPoint { CGPoint(x: origin.x + CGFloat(p.x) * scale, y: origin.y - CGFloat(p.y) * scale) }
        func board(_ q: CGPoint) -> PCBPoint { PCBPoint(Double((q.x - origin.x) / scale), Double((origin.y - q.y) / scale)) }
    }

    private func mapping(_ size: CGSize) -> Mapping {
        let outline = circuits.design?.board.outline ?? []
        let xs = outline.map(\.x), ys = outline.map(\.y)
        let lo = PCBPoint(xs.min() ?? 0, ys.min() ?? 0), hi = PCBPoint(xs.max() ?? 50, ys.max() ?? 30)
        let w = max(hi.x - lo.x, 1), h = max(hi.y - lo.y, 1)
        let fit = min((size.width - 80) / CGFloat(w), (size.height - 80) / CGFloat(h))
        let scale = max(fit, 0.5) * zoom * pinch
        let centre = CGPoint(x: size.width / 2 + pan.width, y: size.height / 2 + pan.height)
        return Mapping(scale: scale, origin: CGPoint(x: centre.x - CGFloat(lo.x + w / 2) * scale, y: centre.y + CGFloat(lo.y + h / 2) * scale))
    }

    /// The pad under a point: the engine's exact copper (the same the DRC checks), the layer
    /// being drawn on first.
    private func pad(at p: PCBPoint) -> PlacedPad? {
        guard circuits.pcbIsCurrent, let s = circuits.pcb else { return nil }
        func pad(_ hits: [PCBHit]) -> PCBHit? { hits.first { if case .pad = $0.item { true } else { false } } }
        guard let hit = pad(s.pick(point: p, tolerance: 0, layer: circuits.activeLayer)) ?? pad(s.pick(point: p, tolerance: 0)),
              case let .pad(component, padID) = hit.item else { return nil }
        return s.board.pads.first { $0.componentID == component && $0.padID == padID }
    }

    /// About 11 px in millimetres: how near the mouse must be to pick or snap copper.
    private func tolerance(_ m: Mapping) -> Double { Double(11 / m.scale) }

    var body: some View {
        GeometryReader { geo in
            let m = mapping(geo.size)
            Canvas { ctx, _ in draw(&ctx, m) }
                .background(Color(red: 0.11, green: 0.12, blue: 0.14))
                .contentShape(Rectangle())
                .onContinuousHover { phase in
                    if case let .active(q) = phase {
                        let p = m.board(q)
                        hoveredPad = pad(at: p)
                        hoveredCopper = hoveredPad == nil ? circuits.copperHit(at: p, tolerance: tolerance(m)) : nil
                        cursor = PCBPoint((p.x * 2).rounded() / 2, (p.y * 2).rounded() / 2)   // 0,5 mm grid
                        pointer = p
                        if circuits.route != nil { circuits.previewLeg(to: p, tolerance: tolerance(m)) }
                        placingCursor(true)
                    } else { hoveredPad = nil; hoveredCopper = nil; cursor = nil; pointer = nil; placingCursor(false) }
                }
                .gesture(
                    DragGesture(minimumDistance: 2)
                        .onChanged { g in
                            if dragging == nil, panStart == nil {
                                let start = m.board(g.startLocation)
                                if circuits.tool != .route, let hit = pad(at: start), let place = circuits.placement(of: hit.componentID) {
                                    circuits.selection = hit.componentID
                                    dragging = (hit.componentID, place.position, PCBPoint())
                                } else {
                                    panStart = pan
                                }
                            }
                            if var d = dragging {
                                // A 0,1 mm grid while moving.
                                let dx = Double(g.translation.width / m.scale), dy = Double(-g.translation.height / m.scale)
                                d.delta = PCBPoint((dx * 10).rounded() / 10, (dy * 10).rounded() / 10)
                                dragging = d
                            } else if let s = panStart {
                                pan = CGSize(width: s.width + g.translation.width, height: s.height + g.translation.height)
                            }
                        }
                        .onEnded { _ in
                            if let d = dragging, d.delta.x != 0 || d.delta.y != 0 {
                                circuits.move(d.component, to: PCBPoint(d.from.x + d.delta.x, d.from.y + d.delta.y))
                            }
                            dragging = nil; panStart = nil
                        }
                )
                .simultaneousGesture(SpatialTapGesture().onEnded { tap in
                    click(m.board(tap.location), m)
                    focused = true
                })
                .gesture(MagnifyGesture().updating($pinch) { value, state, _ in state = value.magnification }
                    .onEnded { value in zoom = min(max(zoom * value.magnification, 0.2), 40) })
                .focusable().focused($focused).focusEffectDisabled()
                .onKeyPress("r") { if let c = circuits.selection { circuits.rotate(c) }; return .handled }
                .onKeyPress("f") { if let c = circuits.selection { circuits.flip(c) }; return .handled }
                .onKeyPress("x") { circuits.tool = circuits.tool == .route ? .select : .route; return .handled }
                .onKeyPress("v") { circuits.switchLayer(); return .handled }
                .onKeyPress("/") {
                    circuits.diagonalFirst.toggle()
                    circuits.routeCheck = nil
                    if let p = pointer { circuits.previewLeg(to: p, tolerance: tolerance(m)) }
                    return .handled
                }
                .onKeyPress(.return) { circuits.finishRoute(); return .handled }
                .onKeyPress(.escape) {
                    if circuits.route != nil { circuits.route = nil; circuits.routeCheck = nil }
                    else if circuits.connectFrom != nil { circuits.connectFrom = nil }
                    else if circuits.tool != .select { circuits.tool = .select }
                    else { circuits.selection = nil; circuits.copperSelection = nil; circuits.issueMark = nil }
                    return .handled
                }
                .onKeyPress(.delete) { deleteSelection(); return .handled }
                .onKeyPress(.deleteForward) { deleteSelection(); return .handled }
                .overlay(alignment: .bottomTrailing) { zoomButtons.padding(12) }
                .overlay(alignment: .bottomLeading) { routingBar.padding(12) }
                .overlay(alignment: .topLeading) { hoverChip.padding(12) }
                .overlay(alignment: .top) { toolHint.padding(.top, 12) }
                .onChange(of: circuits.tool) { _, _ in focused = true }
        }
    }

    /// Canc: the last leg of the route being drawn, else the copper or component selected.
    private func deleteSelection() {
        if circuits.route != nil { circuits.undoLeg() }
        else if let item = circuits.copperSelection { circuits.removeCopper(item) }
        else if let c = circuits.selection { circuits.removeComponent(c) }
    }

    /// A click on the board: place, connect, route or select, by the tool.
    private func click(_ p: PCBPoint, _ m: Mapping) {
        circuits.issueMark = nil
        switch circuits.tool {
        case .route:
            circuits.routeClick(at: p, tolerance: tolerance(m))
        case let .place(placing):
            // Keeps placing (next identity and reference) until Esc: the model moves the session on.
            let at = PCBPoint((p.x * 2).rounded() / 2, (p.y * 2).rounded() / 2)
            circuits.addComponent(placing, at: at)
        case .connect:
            if let hit = pad(at: p) { circuits.connectClick(hit) }
        case let .placeExisting(id):
            circuits.placeExistingOnBoard(id, at: PCBPoint((p.x * 2).rounded() / 2, (p.y * 2).rounded() / 2))
        case .select:
            if pad(at: p) == nil, let hit = circuits.copperHit(at: p, tolerance: tolerance(m)) {
                circuits.copperSelection = hit.item; circuits.selection = nil
            } else {
                circuits.selection = pad(at: p)?.componentID; circuits.copperSelection = nil
            }
        }
    }

    /// The crosshair while placing a component (a click puts a point); the arrow otherwise.
    private func placingCursor(_ inside: Bool) {
        guard inside else { return }
        switch circuits.tool {
        case .place, .placeExisting, .route: NSCursor.crosshair.set()
        default: NSCursor.arrow.set()
        }
    }

    @ViewBuilder private var toolHint: some View {
        let text: String? = switch circuits.tool {
        case let .place(p): "Clicca dove posare \(p.reference) (\(p.name)) · Esc per finire"
        case .connect: circuits.connectFrom == nil ? "Collega: clicca la prima piazzola · Esc per finire"
            : "Collega: clicca la seconda piazzola · Esc per ricominciare"
        case let .placeExisting(id):
            "Clicca dove posare \(circuits.design?.components.first { $0.id == id }?.reference ?? "il componente") · Esc per finire"
        case .route: routeHint
        case .select: nil
        }
        if let text {
            VStack(spacing: 4) {
                Text(text).font(.system(size: 11, weight: .medium))
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .overlayChip()
                if let blocking = circuits.routeCheck?.blocking, let first = blocking.first {
                    Label("Non confermabile: \(first.message)", systemImage: "xmark.octagon.fill")
                        .font(.system(size: 11, weight: .semibold)).foregroundStyle(.red)
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .overlayChip()
                }
            }
        }
    }

    private var routeHint: String {
        let layer = circuits.layerName(circuits.activeLayer)
        guard let r = circuits.route else {
            return "Pista su \(layer): clicca una piazzola, una via o una pista · X per uscire"
        }
        let net = circuits.design?.nets.first { $0.id == r.netID }?.name ?? "?"
        return "Rete \(net) su \(layer): clic per piegare · V via · / piega · Invio o clic sul rame della rete per finire · ⌫ toglie l'ultimo punto · Esc annulla"
    }

    /// Pista: the width of the next tracks and how the leg bends.
    @ViewBuilder private var routingBar: some View {
        if circuits.tool == .route {
            @Bindable var c = circuits
            HStack(spacing: 8) {
                Circle().fill(CopperColors.layer(circuits.activeLayer, of: circuits.layerCount)).frame(width: 9, height: 9)
                Text(circuits.layerName(circuits.activeLayer)).font(.system(size: 11, weight: .semibold))
                Divider().frame(height: 14)
                Menu {
                    ForEach(circuits.trackWidths, id: \.self) { w in
                        Button(Self.mm(w)) { circuits.trackWidth = w; circuits.route?.width = w; circuits.routeCheck = nil }
                    }
                } label: { Text("Larghezza \(Self.mm(circuits.route?.width ?? circuits.trackWidth))").font(.system(size: 11)) }
                .menuStyle(.borderlessButton).fixedSize()
                .help("Larghezza delle piste (la minima è quella delle regole: Scheda)")
                Divider().frame(height: 14)
                Toggle("45° prima", isOn: $c.diagonalFirst).toggleStyle(.checkbox).font(.system(size: 11))
                    .help("Il tratto piega prima in diagonale, altrimenti prima dritto (/)")
            }
            .padding(.horizontal, 10).padding(.vertical, 5)
            .overlayChip()
        }
    }

    static func mm(_ v: Double) -> String { v.formatted(.number.precision(.fractionLength(0...2))) + " mm" }

    private var zoomButtons: some View {
        HStack(spacing: 2) {
            Button { zoom = min(zoom * 1.4, 40) } label: { Label("Ingrandisci", systemImage: "plus.magnifyingglass") }
            Button { zoom = max(zoom / 1.4, 0.2) } label: { Label("Riduci", systemImage: "minus.magnifyingglass") }
            Button { zoom = 1; pan = .zero } label: { Label("Adatta", systemImage: "arrow.up.left.and.down.right.magnifyingglass") }
        }
        .buttonStyle(IconButtonStyle())
        .overlayChip()
    }

    @ViewBuilder private var hoverChip: some View {
        if hoveredPad == nil, let hit = hoveredCopper, let design = circuits.design {
            let net = hit.netID.flatMap { id in design.nets.first { $0.id == id } }?.name ?? "?"
            let text: String = switch hit.item {
            case .track(let id): circuits.track(id).map { "Pista · rete \(net) · \(circuits.layerName($0.layer)) · \(Self.mm($0.width))" } ?? "Pista"
            case .via(let id): circuits.via(id).map { "Via · rete \(net) · Ø \(Self.mm($0.diameter)), foro \(Self.mm($0.drill))" } ?? "Via"
            case .pad: "rete \(net)"
            }
            Text(text).font(.system(size: 11, weight: .medium))
                .padding(.horizontal, 8).padding(.vertical, 4)
                .overlayChip()
        } else if let pad = hoveredPad, let design = circuits.design {
            let component = design.components.first { $0.id == pad.componentID }
            let net = pad.netID.flatMap { id in design.nets.first { $0.id == id } }
            Text("\(component?.reference ?? "?") · \(net.map { "rete \($0.name)" } ?? "non collegata")")
                .font(.system(size: 11, weight: .medium))
                .padding(.horizontal, 8).padding(.vertical, 4)
                .overlayChip()
        }
    }

    // MARK: Drawing

    private func draw(_ ctx: inout GraphicsContext, _ m: Mapping) {
        guard let design = circuits.design else { return }
        let accent = Color(red: 1, green: 0.55, blue: 0.22)
        // Board: solder-mask green, outline light.
        var outline = Path()
        for (i, p) in design.board.outline.enumerated() { i == 0 ? outline.move(to: m.screen(p)) : outline.addLine(to: m.screen(p)) }
        outline.closeSubpath()
        ctx.fill(outline, with: .color(Color(red: 0.10, green: 0.33, blue: 0.20)))
        ctx.stroke(outline, with: .color(Color(red: 0.85, green: 0.9, blue: 0.8)), lineWidth: 1.5)

        let litNet = hoveredPad?.netID ?? hoveredCopper?.netID ?? circuits.route?.netID
        drawCopper(&ctx, m, litNet: litNet, accent: accent)
        let selected = circuits.selection
        // Pads: the engine's exact copper, top gold and bottom blue; the net under the mouse and
        // the selected component in the accent colour; the dragged component's moved by the offset.
        for primitive in circuits.pcb?.primitives ?? [] {
            guard case let .pad(component, _) = primitive.item else { continue }
            var core = primitive.core
            if let d = dragging, d.component == component { core = core.map { PCBPoint($0.x + d.delta.x, $0.y + d.delta.y) } }
            var colour = primitive.layers.contains(0) ? Color(red: 0.84, green: 0.66, blue: 0.28) : Color(red: 0.35, green: 0.55, blue: 0.95)
            if let n = litNet, primitive.netID == n { colour = accent }
            if component == selected {
                colour = accent
                fill(&ctx, m, core: core, radius: primitive.radius + Double(1.2 / m.scale), with: .color(.white))
            }
            fill(&ctx, m, core: core, radius: primitive.radius, with: .color(colour))
            if let drill = primitive.drillDiameter, drill > 0 {
                let c = core.reduce(PCBPoint()) { PCBPoint($0.x + $1.x / Double(core.count), $0.y + $1.y / Double(core.count)) }
                fill(&ctx, m, core: [c], radius: drill / 2, with: .color(.black))
            }
        }
        // Connections still to route (airwires): thin, the lit net's brighter.
        for wire in circuits.board?.airwires ?? [] {
            var a = wire.from, b = wire.to
            if let d = dragging {
                if wire.fromComponent == d.component { a = PCBPoint(a.x + d.delta.x, a.y + d.delta.y) }
                if wire.toComponent == d.component { b = PCBPoint(b.x + d.delta.x, b.y + d.delta.y) }
            }
            var path = Path(); path.move(to: m.screen(a)); path.addLine(to: m.screen(b))
            let lit = wire.netID == litNet
            ctx.stroke(path, with: .color(lit ? accent : Color.white.opacity(0.55)), lineWidth: lit ? 1.6 : 0.8)
        }
        drawRoute(&ctx, m, accent: accent)
        // Scheda: the new outline, dashed, until OK or Annulla.
        if let preview = circuits.boardPreview, preview.count >= 3 {
            var path = Path()
            for (i, p) in preview.enumerated() { i == 0 ? path.move(to: m.screen(p)) : path.addLine(to: m.screen(p)) }
            path.closeSubpath()
            ctx.stroke(path, with: .color(accent), style: StrokeStyle(lineWidth: 1.5, dash: [6, 4]))
        }
        // Collega: from the first pad to the mouse.
        if let first = circuits.connectFrom, let c = cursor {
            var path = Path(); path.move(to: m.screen(first.center)); path.addLine(to: m.screen(hoveredPad?.center ?? c))
            ctx.stroke(path, with: .color(accent), style: StrokeStyle(lineWidth: 1.4, dash: [5, 3]))
            let r: CGFloat = 5, q = m.screen(first.center)
            ctx.stroke(Path(ellipseIn: CGRect(x: q.x - r, y: q.y - r, width: 2 * r, height: 2 * r)), with: .color(accent), lineWidth: 2)
        }
        // Posa: the part's pads where it will go, then its reference.
        if case .place = circuits.tool, let at = cursor {
            // The session's pads (previewed once at the origin) moved under the mouse.
            for pad in circuits.boardGhost {
                fill(&ctx, m, core: pad.core.map { PCBPoint($0.x + at.x, $0.y + at.y) }, radius: pad.radius, with: .color(accent.opacity(0.55)))
            }
        }
        if case let .place(p) = circuits.tool, let c = cursor {
            let q = m.screen(c), r: CGFloat = 8
            var cross = Path()
            cross.move(to: CGPoint(x: q.x - r, y: q.y)); cross.addLine(to: CGPoint(x: q.x + r, y: q.y))
            cross.move(to: CGPoint(x: q.x, y: q.y - r)); cross.addLine(to: CGPoint(x: q.x, y: q.y + r))
            ctx.stroke(cross, with: .color(accent), lineWidth: 1.5)
            ctx.draw(Text(p.reference).font(.system(size: 12, weight: .semibold)).foregroundColor(accent), at: CGPoint(x: q.x, y: q.y - 16))
        }
        // References at the components' placements.
        for place in design.board.placements {
            guard let comp = design.components.first(where: { $0.id == place.componentID }) else { continue }
            var at = place.position
            if let d = dragging, d.component == place.componentID { at = PCBPoint(at.x + d.delta.x, at.y + d.delta.y) }
            let label = Text(comp.reference + (place.side == .bottom ? " (sotto)" : ""))
                .font(.system(size: max(9, min(14, m.scale * 1.2)), weight: .semibold))
                .foregroundColor(place.componentID == selected ? accent : .white)
            ctx.draw(label, at: CGPoint(x: m.screen(at).x, y: m.screen(at).y - max(10, 2.5 * m.scale)))
        }
        drawChecks(&ctx, m)
    }

    /// The engine's exact copper shape: its core (point, segment, convex polygon) swept by a disk.
    private func fill(_ ctx: inout GraphicsContext, _ m: Mapping, core: [PCBPoint], radius: Double, with shading: GraphicsContext.Shading) {
        let w = CGFloat(2 * radius) * m.scale
        switch core.count {
        case 0: return
        case 1:
            let c = m.screen(core[0]), r = w / 2
            ctx.fill(Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r)), with: shading)
        default:
            var path = Path()
            path.move(to: m.screen(core[0]))
            for p in core.dropFirst() { path.addLine(to: m.screen(p)) }
            if core.count > 2 { path.closeSubpath(); ctx.fill(path, with: shading) }
            ctx.stroke(path, with: shading, style: StrokeStyle(lineWidth: max(w, 1), lineCap: .round, lineJoin: .round))
        }
    }

    /// Tracks and vias of the drawing: other layers dimmed under the one being drawn on, vias on
    /// top with their hole; the lit net and the selection in the accent colour.
    private func drawCopper(_ ctx: inout GraphicsContext, _ m: Mapping, litNet: UUID?, accent: Color) {
        guard let pcb = circuits.pcb else { return }
        let active = circuits.activeLayer, count = pcb.layerCount
        let copper = pcb.primitives.filter { if case .pad = $0.item { false } else { true } }
        let tracks = copper.filter { if case .track = $0.item { true } else { false } }
        let order = tracks.filter { !$0.layers.contains(active) }.sorted { ($0.layers.first ?? 0) > ($1.layers.first ?? 0) }
            + tracks.filter { $0.layers.contains(active) }
        for p in order {
            let layer = p.layers.first ?? 0
            var colour = CopperColors.layer(layer, of: count).opacity(layer == active ? 0.95 : 0.4)
            if let n = litNet, p.netID == n { colour = accent.opacity(layer == active ? 1 : 0.6) }
            if p.item == circuits.copperSelection { fill(&ctx, m, core: p.core, radius: p.radius + Double(1.5 / m.scale), with: .color(.white)) }
            fill(&ctx, m, core: p.core, radius: p.radius, with: .color(colour))
        }
        for p in copper { if case .via = p.item {
            if p.item == circuits.copperSelection { fill(&ctx, m, core: p.core, radius: p.radius + Double(1.5 / m.scale), with: .color(.white)) }
            let lit = litNet != nil && p.netID == litNet
            fill(&ctx, m, core: p.core, radius: p.radius, with: .color(lit ? accent : Color(white: 0.78)))
            if let d = p.drillDiameter { fill(&ctx, m, core: p.core, radius: d / 2, with: .color(.black)) }
        } }
    }

    /// Pista: the runs drawn so far, their vias, and the leg to the mouse — red when the engine
    /// would refuse the route, dashed while it checks.
    private func drawRoute(_ ctx: inout GraphicsContext, _ m: Mapping, accent: Color) {
        guard let r = circuits.route else { return }
        let count = circuits.layerCount
        for run in r.runs where run.points.count > 1 {
            var path = Path()
            path.move(to: m.screen(run.points[0]))
            for p in run.points.dropFirst() { path.addLine(to: m.screen(p)) }
            ctx.stroke(path, with: .color(CopperColors.layer(run.layer, of: count)),
                       style: StrokeStyle(lineWidth: max(CGFloat(r.width) * m.scale, 1), lineCap: .round, lineJoin: .round))
        }
        let rules = circuits.copperRules
        let viaRadius = max(0.6, max(0.3, rules.minimumDrill) + 2 * rules.minimumAnnularRing) / 2
        for v in r.vias { fill(&ctx, m, core: [v.position], radius: viaRadius, with: .color(Color(white: 0.85))) }
        if let check = circuits.routeCheck, check.leg.count > 1 {
            var path = Path()
            path.move(to: m.screen(check.leg[0]))
            for p in check.leg.dropFirst() { path.addLine(to: m.screen(p)) }
            let refused = !(check.blocking?.isEmpty ?? true)
            let colour = refused ? Color.red : CopperColors.layer(r.layer, of: count)
            let w = max(CGFloat(r.width) * m.scale, 1)
            ctx.stroke(path, with: .color(colour.opacity(0.85)),
                       style: StrokeStyle(lineWidth: w, lineCap: .round, lineJoin: .round, dash: check.blocking == nil ? [w * 1.5, w] : []))
            for issue in check.blocking ?? [] { if let at = issue.position { ring(&ctx, m.screen(at), 7, .red) } }
            if check.target.kind != .grid { ring(&ctx, m.screen(check.target.position), 6, accent) }
        }
        ring(&ctx, m.screen(r.tip), 4, .white)
    }

    /// The copper errors where they are, and the check chosen in VERIFICHE.
    private func drawChecks(_ ctx: inout GraphicsContext, _ m: Mapping) {
        if circuits.pcbIsCurrent {
            for issue in circuits.pcb?.issues ?? [] where issue.severity == .error {
                guard let at = issue.position else { continue }
                let q = m.screen(at), r: CGFloat = 5
                var x = Path()
                x.move(to: CGPoint(x: q.x - r, y: q.y - r)); x.addLine(to: CGPoint(x: q.x + r, y: q.y + r))
                x.move(to: CGPoint(x: q.x + r, y: q.y - r)); x.addLine(to: CGPoint(x: q.x - r, y: q.y + r))
                ctx.stroke(x, with: .color(.red), lineWidth: 2)
            }
        }
        if let at = circuits.issueMark { ring(&ctx, m.screen(at), 14, .yellow) }
    }

    private func ring(_ ctx: inout GraphicsContext, _ q: CGPoint, _ r: CGFloat, _ colour: Color) {
        ctx.stroke(Path(ellipseIn: CGRect(x: q.x - r, y: q.y - r, width: 2 * r, height: 2 * r)), with: .color(colour), lineWidth: 2)
    }
}

/// Copper layer colours: top red, bottom blue, inner layers each their own.
enum CopperColors {
    static func layer(_ layer: Int, of count: Int) -> Color {
        if layer == 0 { return Color(red: 0.88, green: 0.30, blue: 0.24) }
        if layer == count - 1 { return Color(red: 0.30, green: 0.52, blue: 0.96) }
        let inner: [Color] = [Color(red: 0.92, green: 0.80, blue: 0.25), Color(red: 0.80, green: 0.38, blue: 0.85),
                              Color(red: 0.30, green: 0.82, blue: 0.80), Color(red: 0.55, green: 0.85, blue: 0.30),
                              Color(red: 0.96, green: 0.58, blue: 0.20), Color(red: 0.95, green: 0.45, blue: 0.65)]
        return inner[(layer - 1) % inner.count]
    }
}

/// VERIFICHE: what the engine found, errors first; a click selects the component concerned.
struct CircuitChecksPanel: View {
    @Environment(CircuitModel.self) private var circuits

    private var ordered: [ElectronicsIssue] {
        circuits.issues.filter { $0.severity == .error } + circuits.issues.filter { $0.severity != .error }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("VERIFICHE").font(.system(size: 11, weight: .bold)).foregroundStyle(Theme.Palette.textSecondary)
            Text(circuits.summary).font(.caption).foregroundStyle(Theme.Palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            if circuits.issues.isEmpty {
                Label("Nessun problema trovato", systemImage: "checkmark.seal").font(.callout).foregroundStyle(.green)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(ordered.enumerated()), id: \.offset) { _, issue in
                        IssueRow(issue: issue) { circuits.select(issue) }
                    }
                }
            }
            if let item = circuits.copperSelection { CopperDetail(item: item) }
            if let id = circuits.selection, let comp = circuits.design?.components.first(where: { $0.id == id }) {
                Divider()
                Text("\(comp.reference) · \(comp.value)").font(.callout.weight(.semibold))
                if let place = circuits.placement(of: id) {
                    Text(String(format: "X %.2f  Y %.2f mm · %.0f° · %@", place.position.x, place.position.y, place.rotationDegrees,
                                place.side == .top ? "sopra" : "sotto"))
                        .font(.caption.monospacedDigit()).foregroundStyle(Theme.Palette.textSecondary)
                }
                Text(circuits.canvas == .schematic ? "R ruota di 90° · M specchia · trascina per spostare · Canc elimina il simbolo"
                     : "R ruota di 90° · F cambia lato · trascina per spostare · Canc elimina")
                    .font(.caption2).foregroundStyle(Theme.Palette.textSecondary)
            }
        }
        .padding(12)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Theme.Palette.panel)
    }
}

/// The track or via selected: net, layer, size; the track's width can change (one undo step).
private struct CopperDetail: View {
    @Environment(CircuitModel.self) private var circuits
    let item: PCBItem

    var body: some View {
        let design = circuits.design
        let netName = { (id: UUID) in design?.nets.first { $0.id == id }?.name ?? "?" }
        Divider()
        switch item {
        case .track(let id):
            if let t = circuits.track(id) {
                let length = zip(t.points, t.points.dropFirst()).reduce(0.0) { $0 + CircuitModel.distance($1.0, $1.1) }
                Text("Pista · rete \(netName(t.netID))").font(.callout.weight(.semibold))
                Text("\(circuits.layerName(t.layer)) · \(String(format: "%.2f", length)) mm di lunghezza")
                    .font(.caption.monospacedDigit()).foregroundStyle(Theme.Palette.textSecondary)
                Menu {
                    ForEach(circuits.trackWidths, id: \.self) { w in
                        Button(CircuitBoardView.mm(w)) { circuits.setWidth(w, ofTrack: id) }
                    }
                } label: { Text("Larghezza \(CircuitBoardView.mm(t.width))") }
                .fixedSize()
            }
        case .via(let id):
            if let v = circuits.via(id) {
                Text("Via · rete \(netName(v.netID))").font(.callout.weight(.semibold))
                Text("Ø \(CircuitBoardView.mm(v.diameter)) · foro \(CircuitBoardView.mm(v.drill)) · passante")
                    .font(.caption.monospacedDigit()).foregroundStyle(Theme.Palette.textSecondary)
            }
        case .pad: EmptyView()
        }
        Text("Canc elimina").font(.caption2).foregroundStyle(Theme.Palette.textSecondary)
    }
}

private struct IssueRow: View {
    let issue: ElectronicsIssue
    let action: () -> Void

    var body: some View {
        let isError = issue.severity == .error
        Button(action: action) {
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
    }
}


/// CREA › Componente: what to place (from the circuit's library; the engine's generic models
/// join the list with T93), its reference and value; then a click on the board places it.
struct AddComponentSheet: View {
    @Environment(CircuitModel.self) private var circuits
    @State private var choice: CircuitModel.DeviceChoice?
    @State private var reference = ""
    @State private var value = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Aggiungi componente", systemImage: "cpu").font(.headline)
            let choices = circuits.deviceChoices
            if choices.isEmpty {
                Text("Nessun componente disponibile.")
                    .font(.callout).foregroundStyle(Theme.Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                List(choices, selection: $choice) { c in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(c.name).font(.body.weight(.medium))
                        if !c.detail.isEmpty { Text(c.detail).font(.caption).foregroundStyle(Theme.Palette.textSecondary) }
                    }
                    .tag(c)
                }
                .frame(height: 180)
                Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 6) {
                    GridRow {
                        Text("Sigla")
                        TextField("R1", text: $reference).frame(width: 120)
                    }
                    GridRow {
                        Text("Valore")
                        TextField("10k", text: $value).frame(width: 200)
                    }
                }
                .textFieldStyle(.roundedBorder)
            }
            // Already in the circuit: without a symbol (schematic) or not on the board (PCB).
            let existing: [CircuitComponent] = circuits.canvas == .schematic ? circuits.componentsWithoutSymbol
                : (circuits.board?.unplacedComponents ?? []).compactMap { id in circuits.design?.components.first { $0.id == id } }
            if !existing.isEmpty {
                Text(circuits.canvas == .schematic ? "Nel circuito, senza simbolo" : "Dallo schema, da posare sulla scheda")
                    .font(.caption.weight(.semibold))
                ScrollView(.horizontal) {
                    HStack {
                        ForEach(existing, id: \.id) { comp in
                            Button(comp.reference) {
                                if circuits.canvas == .schematic { circuits.startSchematicPlacing(existing: comp) }
                                else { circuits.tool = .placeExisting(comp.id) }
                                circuits.showAddComponent = false
                            }
                        }
                    }
                }
            }
            Spacer(minLength: 0)
            HStack {
                Spacer()
                Button("Annulla") { circuits.showAddComponent = false }.keyboardShortcut(.cancelAction)
                Button(circuits.canvas == .schematic ? "Posiziona sullo schema" : "Posiziona sulla scheda") { place() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(choice == nil || reference.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(16)
        .frame(width: 440, height: circuits.deviceChoices.isEmpty ? 200 : 460)
        .onAppear { if let first = circuits.deviceChoices.first { select(first) } }
        .onChange(of: choice) { _, c in if let c { select(c) } }
    }

    private func select(_ c: CircuitModel.DeviceChoice) {
        if choice != c { choice = c }
        reference = circuits.nextReference(prefix: c.prefix)
        value = c.defaultValue
    }

    private func place() {
        guard let c = choice else { return }
        let ref = reference.trimmingCharacters(in: .whitespaces)
        if circuits.canvas == .schematic {
            circuits.startSchematicPlacing(c, reference: ref, value: value)
        } else {
            circuits.startPlacing(c, reference: ref, value: value)
        }
        circuits.showAddComponent = false
    }
}

/// CREA › Scheda: the board's size and thickness, previewed dashed on the board; OK is one undo
/// step, Annulla leaves it as it was.
struct BoardSheet: View {
    @Environment(CircuitModel.self) private var circuits
    @State private var width = 50.0
    @State private var height = 30.0
    @State private var thickness = 1.6
    @State private var layers = 2
    @State private var rules = PCBDesignRules()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Scheda", systemImage: "rectangle.dashed").font(.headline)
            Text("Rettangolo dall'origine (0,0). Il contorno nuovo si vede tratteggiato sulla scheda.")
                .font(.caption).foregroundStyle(Theme.Palette.textSecondary)
            Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 6) {
                row("Larghezza", $width, "mm")
                row("Altezza", $height, "mm")
                row("Spessore", $thickness, "mm")
                GridRow {
                    Text("Strati rame")
                    Picker("", selection: $layers) {
                        ForEach(Array(stride(from: 2, through: 32, by: 2)), id: \.self) { Text("\($0)").tag($0) }
                    }
                    .labelsHidden().frame(width: 90)
                    .disabled(hasCopper)
                    Text(hasCopper ? "togli piste e via per cambiarli" : "").font(.caption2).foregroundStyle(Theme.Palette.textSecondary)
                }
                Divider().gridCellColumns(3)
                row("Distanza fra reti", $rules.clearance, "mm")
                row("Distanza dal bordo", $rules.edgeClearance, "mm")
                row("Pista minima", $rules.minimumTrackWidth, "mm")
                row("Foro minimo", $rules.minimumDrill, "mm")
                row("Anello minimo", $rules.minimumAnnularRing, "mm")
            }
            .textFieldStyle(.roundedBorder)
            Text("Regole di partenza del progetto, non quelle di un fornitore: controllale col produttore.")
                .font(.caption2).foregroundStyle(Theme.Palette.textSecondary)
            if width <= 0 || height <= 0 || thickness <= 0 {
                Text("Le misure devono essere maggiori di zero.").font(.caption).foregroundStyle(.red)
            }
            Spacer(minLength: 0)
            HStack {
                Spacer()
                Button("Annulla") { circuits.boardPreview = nil; circuits.showBoard = false }.keyboardShortcut(.cancelAction)
                Button("OK") {
                    circuits.boardPreview = nil
                    circuits.setBoard(width: width, height: height, thickness: thickness)
                    circuits.configureCopper(layerCount: layers, rules: rules)
                    circuits.showBoard = false
                }
                .keyboardShortcut(.defaultAction)
                .disabled(width <= 0 || height <= 0 || thickness <= 0)
            }
        }
        .padding(16)
        .frame(width: 380, height: 450)
        .onAppear {
            if let board = circuits.design?.board {
                let xs = board.outline.map(\.x), ys = board.outline.map(\.y)
                width = (xs.max() ?? 50) - (xs.min() ?? 0); height = (ys.max() ?? 30) - (ys.min() ?? 0)
                thickness = board.thickness
            }
            layers = circuits.layerCount
            rules = circuits.copperRules
            preview()
        }
        .onChange(of: width) { preview() }
        .onChange(of: height) { preview() }
        .onDisappear { circuits.boardPreview = nil }
    }

    private var hasCopper: Bool {
        guard let c = circuits.design?.board.copper else { return false }
        return !c.tracks.isEmpty || !c.vias.isEmpty
    }

    private func preview() {
        guard width > 0, height > 0 else { circuits.boardPreview = nil; return }
        circuits.boardPreview = [PCBPoint(0, 0), PCBPoint(width, 0), PCBPoint(width, height), PCBPoint(0, height)]
    }

    private func row(_ label: String, _ value: Binding<Double>, _ unit: String) -> some View {
        GridRow {
            Text(label)
            TextField("", value: value, format: .number.precision(.fractionLength(0...2))).frame(width: 90)
            Text(unit).foregroundStyle(Theme.Palette.textSecondary)
        }
    }
}


/// LIBRERIA › Importa, step 1 for a KiCad symbol library: which symbol.
struct SymbolChoiceSheet: View {
    @Environment(CircuitModel.self) private var circuits
    @State private var name: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Quale simbolo?", systemImage: "list.bullet").font(.headline)
            if let choice = circuits.symbolChoice {
                Text(choice.url.lastPathComponent).font(.caption).foregroundStyle(Theme.Palette.textSecondary)
                List(choice.names, id: \.self, selection: $name) { Text($0).tag($0) }.frame(height: 220)
            }
            HStack {
                Spacer()
                Button("Annulla") { circuits.symbolChoice = nil }.keyboardShortcut(.cancelAction)
                Button("Anteprima") {
                    guard let choice = circuits.symbolChoice, let name else { return }
                    circuits.symbolChoice = nil
                    circuits.prepareImport(choice.url, symbol: name)
                }
                .keyboardShortcut(.defaultAction).disabled(name == nil)
            }
        }
        .padding(16).frame(width: 380, height: 340)
    }
}

/// LIBRERIA › Importa, step 2: what comes into the circuit's library and the warnings; nothing
/// changes until «Importa» (one undo step).
struct ImportPreviewSheet: View {
    @Environment(CircuitModel.self) private var circuits

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let p = circuits.importProposal {
                Label("Importa \(p.fileName)", systemImage: "square.and.arrow.down.on.square").font(.headline)
                ForEach(p.symbols, id: \.key) { s in
                    Label("Simbolo \(s.name) · \(s.pins.count) pin", systemImage: "function")
                }
                ForEach(p.footprints, id: \.key) { f in
                    Label("Impronta \(f.name) · \(f.pads.count) piazzole", systemImage: "square.grid.2x2")
                }
                if !p.preview.issues.isEmpty {
                    Text("Da controllare").font(.caption.weight(.semibold)).padding(.top, 4)
                    ScrollView {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(Array(p.preview.issues.enumerated()), id: \.offset) { _, issue in
                                Label(issue.message, systemImage: issue.severity == .error ? "xmark.octagon" : "exclamationmark.triangle")
                                    .font(.caption).foregroundStyle(issue.severity == .error ? Color.red : Color.orange)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                    .frame(maxHeight: 140)
                }
                Text("Poi LIBRERIA › Nuovo tipo unisce simbolo e impronta in un componente da posare.")
                    .font(.caption).foregroundStyle(Theme.Palette.textSecondary)
            }
            Spacer(minLength: 0)
            HStack {
                Spacer()
                Button("Annulla") { circuits.importProposal = nil }.keyboardShortcut(.cancelAction)
                Button("Importa") { circuits.confirmImport() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(16).frame(width: 460, height: 360)
    }
}

/// LIBRERIA › Nuovo tipo: a symbol and a footprint of the circuit's library joined into a
/// component to place, with the pin ↔ pad pairing the engine suggests (to check on the datasheet).
struct CreateDeviceSheet: View {
    @Environment(CircuitModel.self) private var circuits
    @State private var symbol: LibraryRevision?
    @State private var footprint: LibraryRevision?
    @State private var manufacturer = ""
    @State private var partNumber = ""

    var body: some View {
        let library = circuits.design?.library
        VStack(alignment: .leading, spacing: 10) {
            Label("Nuovo tipo di componente", systemImage: "puzzlepiece.extension").font(.headline)
            if (library?.symbols.isEmpty ?? true) || (library?.footprints.isEmpty ?? true) {
                Text("Servono almeno un simbolo e un'impronta nella libreria del circuito: importali con LIBRERIA › Importa.")
                    .font(.callout).foregroundStyle(Theme.Palette.textSecondary).fixedSize(horizontal: false, vertical: true)
            } else if let library {
                Picker("Simbolo", selection: $symbol) {
                    Text("—").tag(LibraryRevision?.none)
                    ForEach(library.symbols, id: \.key) { s in Text("\(s.name) (\(s.pins.count) pin)").tag(Optional(s.key)) }
                }
                Picker("Impronta", selection: $footprint) {
                    Text("—").tag(LibraryRevision?.none)
                    ForEach(library.footprints, id: \.key) { f in Text("\(f.name) (\(f.pads.count) piazzole)").tag(Optional(f.key)) }
                }
                TextField("Produttore (vuoto = Generico)", text: $manufacturer).textFieldStyle(.roundedBorder)
                TextField("Codice produttore / MPN (vuoto = simbolo · impronta)", text: $partNumber).textFieldStyle(.roundedBorder)
                pairing(library)
            }
            Spacer(minLength: 0)
            HStack {
                Spacer()
                Button("Annulla") { circuits.showCreateDevice = false }.keyboardShortcut(.cancelAction)
                Button("Crea") {
                    guard let symbol, let footprint, case let .success(map) = circuits.suggestedPinMap(symbol: symbol, footprint: footprint) else { return }
                    if circuits.createDevice(symbol: symbol, footprint: footprint, manufacturer: manufacturer, partNumber: partNumber, pinMap: map) {
                        circuits.showCreateDevice = false
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled({ if let symbol, let footprint, case .success = circuits.suggestedPinMap(symbol: symbol, footprint: footprint) { false } else { true } }())
            }
        }
        .padding(16).frame(width: 460, height: 420)
    }

    @ViewBuilder private func pairing(_ library: ElectronicsLibrary) -> some View {
        if let symbol, let footprint {
            switch circuits.suggestedPinMap(symbol: symbol, footprint: footprint) {
            case let .success(map):
                let s = library.symbols.first { $0.key == symbol }, f = library.footprints.first { $0.key == footprint }
                Text("Pin ↔ piazzole (per numero: verificare sul datasheet)").font(.caption.weight(.semibold))
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(map.enumerated()), id: \.offset) { _, m in
                            let pin = s?.pins.first { $0.id == m.pinID }, pad = f?.pads.first { $0.id == m.padID }
                            Text("\(pin?.name ?? "?") (\(pin?.number ?? "?")) → piazzola \(pad?.number ?? "?")")
                                .font(.caption.monospacedDigit())
                        }
                    }
                }
                .frame(maxHeight: 110)
            case let .failure(error):
                Text(CircuitModel.describe(error)).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
