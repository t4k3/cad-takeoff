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
                CircuitBoardView()
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
        }
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
    /// Where the mouse is on the board (placing a component, the Collega rubber band).
    @State private var cursor: PCBPoint?
    /// Posa: the part's pads where it would go (the engine's preview).
    @State private var ghost: [PlacedPad] = []
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

    /// Pads as drawn now: the dragged component's moved by the preview offset.
    private var pads: [PlacedPad] {
        guard let all = circuits.board?.pads else { return [] }
        guard let d = dragging else { return all }
        return all.map { p in
            guard p.componentID == d.component else { return p }
            var q = p; q.center = PCBPoint(p.center.x + d.delta.x, p.center.y + d.delta.y); return q
        }
    }

    private func pad(at p: PCBPoint) -> PlacedPad? {
        pads.min { distance($0, p) < distance($1, p) }.flatMap { distance($0, p) <= 0 ? $0 : nil }
    }

    /// 0 inside the pad (its larger half-size as radius: enough to aim), else how far out.
    private func distance(_ pad: PlacedPad, _ p: PCBPoint) -> Double {
        let r = max(pad.size.x, pad.size.y) / 2
        return max(0, hypot(p.x - pad.center.x, p.y - pad.center.y) - r)
    }

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
                        let snapped = PCBPoint((p.x * 2).rounded() / 2, (p.y * 2).rounded() / 2)   // 0,5 mm grid
                        if snapped != cursor, case let .place(placing) = circuits.tool {
                            ghost = circuits.placementPreview(placing, at: snapped)
                        }
                        cursor = snapped
                        placingCursor(true)
                    } else { hoveredPad = nil; cursor = nil; ghost = []; placingCursor(false) }
                }
                .gesture(
                    DragGesture(minimumDistance: 2)
                        .onChanged { g in
                            if dragging == nil, panStart == nil {
                                let start = m.board(g.startLocation)
                                if let hit = pad(at: start), let place = circuits.placement(of: hit.componentID) {
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
                    click(m.board(tap.location))
                    focused = true
                })
                .gesture(MagnifyGesture().updating($pinch) { value, state, _ in state = value.magnification }
                    .onEnded { value in zoom = min(max(zoom * value.magnification, 0.2), 40) })
                .focusable().focused($focused).focusEffectDisabled()
                .onKeyPress("r") { if let c = circuits.selection { circuits.rotate(c) }; return .handled }
                .onKeyPress("f") { if let c = circuits.selection { circuits.flip(c) }; return .handled }
                .onKeyPress(.escape) {
                    if circuits.connectFrom != nil { circuits.connectFrom = nil }
                    else if circuits.tool != .select { circuits.tool = .select }
                    else { circuits.selection = nil }
                    return .handled
                }
                .onKeyPress(.delete) { if let c = circuits.selection { circuits.removeComponent(c) }; return .handled }
                .onKeyPress(.deleteForward) { if let c = circuits.selection { circuits.removeComponent(c) }; return .handled }
                .overlay(alignment: .bottomTrailing) { zoomButtons.padding(12) }
                .overlay(alignment: .topLeading) { hoverChip.padding(12) }
                .overlay(alignment: .top) { toolHint.padding(.top, 12) }
                .onChange(of: circuits.tool) { _, tool in
                    focused = true
                    if case let .place(p) = tool, let c = cursor { ghost = circuits.placementPreview(p, at: c) } else { ghost = [] }
                }
        }
    }

    /// A click on the board: place, connect or select, by the tool.
    private func click(_ p: PCBPoint) {
        switch circuits.tool {
        case let .place(placing):
            // Keeps placing (next identity and reference) until Esc: the model moves the session on.
            let at = PCBPoint((p.x * 2).rounded() / 2, (p.y * 2).rounded() / 2)
            circuits.addComponent(placing, at: at)
            if case let .place(next) = circuits.tool { ghost = circuits.placementPreview(next, at: at) }
        case .connect:
            if let hit = pad(at: p) { circuits.connectClick(hit) }
        case .select:
            circuits.selection = pad(at: p)?.componentID
        }
    }

    /// The crosshair while placing a component (a click puts a point); the arrow otherwise.
    private func placingCursor(_ inside: Bool) {
        if inside, case .place = circuits.tool { NSCursor.crosshair.set() } else if inside { NSCursor.arrow.set() }
    }

    @ViewBuilder private var toolHint: some View {
        let text: String? = switch circuits.tool {
        case let .place(p): "Clicca dove posare \(p.reference) (\(p.name)) · Esc per finire"
        case .connect: circuits.connectFrom == nil ? "Collega: clicca la prima piazzola · Esc per finire"
            : "Collega: clicca la seconda piazzola · Esc per ricominciare"
        case .select: nil
        }
        if let text {
            Text(text).font(.system(size: 11, weight: .medium))
                .padding(.horizontal, 10).padding(.vertical, 5)
                .overlayChip()
        }
    }

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
        if let pad = hoveredPad, let design = circuits.design {
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

        let litNet = hoveredPad?.netID
        let selected = circuits.selection
        // Pads: copper, top gold and bottom blue; the net under the mouse and the selected
        // component in the accent colour.
        for pad in pads {
            let c = m.screen(pad.center)
            let w = CGFloat(pad.size.x) * m.scale, h = CGFloat(pad.size.y) * m.scale
            let rect = CGRect(x: -w / 2, y: -h / 2, width: w, height: h)
            // Shapes the engine may add later (rounded rectangles…) are drawn as rectangles with
            // softened corners until it gives the exact outline (UX_RULES §6.3).
            let shape: Path = switch pad.shape {
            case .circle: Path(ellipseIn: rect)
            case .oval: Path(roundedRect: rect, cornerRadius: min(w, h) / 2)
            case .rectangle: Path(rect)
            default: Path(roundedRect: rect, cornerRadius: min(w, h) * 0.25)
            }
            let placed = shape.applying(CGAffineTransform(rotationAngle: -CGFloat(pad.rotationDegrees) * .pi / 180))
                .applying(CGAffineTransform(translationX: c.x, y: c.y))
            let top = pad.copperSides.contains(.top)
            var colour = top ? Color(red: 0.84, green: 0.66, blue: 0.28) : Color(red: 0.35, green: 0.55, blue: 0.95)
            if let n = litNet, pad.netID == n { colour = accent }
            if pad.componentID == selected { colour = accent }
            ctx.fill(placed, with: .color(colour))
            if pad.componentID == selected { ctx.stroke(placed, with: .color(.white), lineWidth: 1.2) }
            if let drill = pad.drillDiameter, drill > 0 {
                let r = CGFloat(drill) * m.scale / 2
                ctx.fill(Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r)), with: .color(.black))
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
        if case .place = circuits.tool {
            for pad in ghost {
                let c = m.screen(pad.center)
                let w = CGFloat(pad.size.x) * m.scale, h = CGFloat(pad.size.y) * m.scale
                let rect = Path(roundedRect: CGRect(x: -w / 2, y: -h / 2, width: w, height: h), cornerRadius: min(w, h) * 0.25)
                    .applying(CGAffineTransform(rotationAngle: -CGFloat(pad.rotationDegrees) * .pi / 180))
                    .applying(CGAffineTransform(translationX: c.x, y: c.y))
                ctx.fill(rect, with: .color(accent.opacity(0.55)))
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
            if let id = circuits.selection, let comp = circuits.design?.components.first(where: { $0.id == id }) {
                Divider()
                Text("\(comp.reference) · \(comp.value)").font(.callout.weight(.semibold))
                if let place = circuits.placement(of: id) {
                    Text(String(format: "X %.2f  Y %.2f mm · %.0f° · %@", place.position.x, place.position.y, place.rotationDegrees,
                                place.side == .top ? "sopra" : "sotto"))
                        .font(.caption.monospacedDigit()).foregroundStyle(Theme.Palette.textSecondary)
                }
                Text("R ruota di 90° · F cambia lato · trascina per spostare").font(.caption2).foregroundStyle(Theme.Palette.textSecondary)
            }
        }
        .padding(12)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Theme.Palette.panel)
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
            Spacer(minLength: 0)
            HStack {
                Spacer()
                Button("Annulla") { circuits.showAddComponent = false }.keyboardShortcut(.cancelAction)
                Button("Posiziona sulla scheda") { place() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(choice == nil || reference.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(16)
        .frame(width: 440, height: circuits.deviceChoices.isEmpty ? 200 : 400)
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
        circuits.startPlacing(c, reference: reference.trimmingCharacters(in: .whitespaces), value: value)
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

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Scheda", systemImage: "rectangle.dashed").font(.headline)
            Text("Rettangolo dall'origine (0,0). Il contorno nuovo si vede tratteggiato sulla scheda.")
                .font(.caption).foregroundStyle(Theme.Palette.textSecondary)
            Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 6) {
                row("Larghezza", $width, "mm")
                row("Altezza", $height, "mm")
                row("Spessore", $thickness, "mm")
            }
            .textFieldStyle(.roundedBorder)
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
                    circuits.showBoard = false
                }
                .keyboardShortcut(.defaultAction)
                .disabled(width <= 0 || height <= 0 || thickness <= 0)
            }
        }
        .padding(16)
        .frame(width: 340, height: 250)
        .onAppear {
            if let board = circuits.design?.board {
                let xs = board.outline.map(\.x), ys = board.outline.map(\.y)
                width = (xs.max() ?? 50) - (xs.min() ?? 0); height = (ys.max() ?? 30) - (ys.min() ?? 0)
                thickness = board.thickness
            }
            preview()
        }
        .onChange(of: width) { preview() }
        .onChange(of: height) { preview() }
        .onDisappear { circuits.boardPreview = nil }
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
