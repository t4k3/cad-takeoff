import ElectronicsCore
import SwiftUI

/// SCHEMA: the sheet as the engine draws it (its primitives; the colours are ours), the engine's
/// snap under the mouse (pin, junction, wire, grid), and the tools turning clicks into engine
/// commands. Y up in the sheet, down on screen; nothing here computes pins or connections.
struct CircuitSchematicView: View {
    @Environment(CircuitModel.self) private var circuits
    @State private var zoom: CGFloat = 1
    @State private var pan: CGSize = .zero
    /// What the view frames (sheet millimetres): fixed once, so placing or rotating never moves
    /// the camera; only Adatta (or another sheet) frames the drawing again.
    @State private var framed: (lo: PCBPoint, w: Double, h: Double)?
    @State private var panStart: CGSize?
    @State private var cursor: PCBPoint?
    @State private var snap: SchematicSnap?
    @State private var hovered: SchematicObject?
    @State private var dragging: (component: UUID, from: PCBPoint, delta: PCBPoint)?
    @GestureState private var pinch: CGFloat = 1
    @FocusState private var focused: Bool

    private struct Mapping {
        var scale: CGFloat, origin: CGPoint
        func screen(_ p: PCBPoint) -> CGPoint { CGPoint(x: origin.x + CGFloat(p.x) * scale, y: origin.y - CGFloat(p.y) * scale) }
        func board(_ q: CGPoint) -> PCBPoint { PCBPoint(Double((q.x - origin.x) / scale), Double((origin.y - q.y) / scale)) }
    }

    /// The framed area (fixed until Adatta) in the view; pinch and buttons zoom.
    private func mapping(_ size: CGSize) -> Mapping {
        let f = framed ?? contentFrame()
        let fit = min((size.width - 40) / CGFloat(f.w), (size.height - 40) / CGFloat(f.h))
        let scale = max(min(fit, 12), 0.5) * zoom * pinch
        let centre = CGPoint(x: size.width / 2 + pan.width, y: size.height / 2 + pan.height)
        return Mapping(scale: scale, origin: CGPoint(x: centre.x - CGFloat(f.lo.x + f.w / 2) * scale, y: centre.y + CGFloat(f.lo.y + f.h / 2) * scale))
    }

    /// What is drawn (or an empty A4-sized area), with a margin.
    private func contentFrame() -> (lo: PCBPoint, w: Double, h: Double) {
        var xs: [Double] = [], ys: [Double] = []
        for p in circuits.schematic?.primitives ?? [] {
            switch p.shape {
            case let .polyline(pts, _): xs += pts.map(\.x); ys += pts.map(\.y)
            case let .circle(c, r): xs += [c.x - r, c.x + r]; ys += [c.y - r, c.y + r]
            case let .text(_, at, _): xs.append(at.x); ys.append(at.y)
            }
        }
        // Always at least an A4-sized area from the origin: the first parts do not move the view.
        xs += [0, 150]; ys += [0, 100]
        let lo = PCBPoint(xs.min()! - 10, ys.min()! - 10), hi = PCBPoint(xs.max()! + 10, ys.max()! + 10)
        return (lo, max(hi.x - lo.x, 20), max(hi.y - lo.y, 20))
    }

    /// Adatta: frame the drawing as it is now.
    private func frameDrawing() { framed = contentFrame(); zoom = 1; pan = .zero }

    var body: some View {
        GeometryReader { geo in
            let m = mapping(geo.size)
            Canvas { ctx, _ in draw(&ctx, m) }
                .background(Color(red: 0.10, green: 0.11, blue: 0.13))
                .contentShape(Rectangle())
                .onContinuousHover { phase in
                    guard case let .active(q) = phase else { cursor = nil; snap = nil; hovered = nil; return }
                    hover(m.board(q), m)
                }
                .gesture(
                    DragGesture(minimumDistance: 3)
                        .onChanged { g in drag(g, m) }
                        .onEnded { _ in
                            if let d = dragging, d.delta.x != 0 || d.delta.y != 0 {
                                circuits.moveSymbol(d.component, to: PCBPoint(d.from.x + d.delta.x, d.from.y + d.delta.y))
                            }
                            dragging = nil; panStart = nil
                        }
                )
                .simultaneousGesture(SpatialTapGesture().onEnded { tap in click(m.board(tap.location), m); focused = true })
                .gesture(MagnifyGesture().updating($pinch) { value, state, _ in state = value.magnification }
                    .onEnded { value in zoom = min(max(zoom * value.magnification, 0.2), 40) })
                .focusable().focused($focused).focusEffectDisabled()
                .onKeyPress(.escape) { escape(); return .handled }
                .onKeyPress("r") { if let c = selectedSymbol { circuits.rotateSymbol(c) }; return .handled }
                .onKeyPress("m") { if let c = selectedSymbol { circuits.mirrorSymbol(c) }; return .handled }
                .onKeyPress(.delete) { deleteSelection(); return .handled }
                .onKeyPress(.deleteForward) { deleteSelection(); return .handled }
                .onChange(of: circuits.schematicTool) { _, _ in focused = true }
                // Framed once the drawing is there, and again for another sheet or circuit.
                .onChange(of: circuits.schematic?.sheetID) { _, _ in if framed == nil || circuits.schematic != nil { frameDrawing() } }
                .onChange(of: circuits.document?.design.id) { _, _ in framed = nil }
                .onAppear { if circuits.schematic != nil { frameDrawing() } }
                .overlay(alignment: .top) { hint.padding(.top, 12) }
                .overlay(alignment: .topTrailing) {
                    if circuits.schematic != nil, !circuits.schematicIsCurrent {
                        ProgressView().controlSize(.small).padding(12).help("Schema in aggiornamento")
                    }
                }
                .overlay(alignment: .bottomTrailing) { zoomButtons.padding(12) }
        }
    }

    private var selectedSymbol: UUID? {
        guard let s = circuits.schematicSelection, s.kind == .symbol || s.kind == .pin else { return nil }
        return s.componentID
    }

    /// ~11 points on screen, in sheet millimetres (the snap radius of UX_RULES).
    private func radius(_ m: Mapping) -> Double { 11 / Double(m.scale) }

    /// The drawing to pick and snap on: only one that matches the document (never a stale one).
    private var current: SchematicSnapshot? { circuits.schematicIsCurrent ? circuits.schematic : nil }

    private func hover(_ p: PCBPoint, _ m: Mapping) {
        let drawing = current
        snap = drawing?.snapTargets(near: p, radius: radius(m), grid: 1.27).first
        cursor = snap?.point ?? PCBPoint((p.x / 1.27).rounded() * 1.27, (p.y / 1.27).rounded() * 1.27)
        hovered = circuits.schematicTool == .select ? drawing?.pick(p, tolerance: radius(m) * 0.8).first?.object : nil
        placingCursor()
    }

    /// Crosshair where a click puts a point (placing, drawing a wire); arrow otherwise.
    private func placingCursor() {
        switch circuits.schematicTool {
        case .place, .wire: NSCursor.crosshair.set()
        default: NSCursor.arrow.set()
        }
    }

    private func drag(_ g: DragGesture.Value, _ m: Mapping) {
        if dragging == nil, panStart == nil {
            let start = m.board(g.startLocation)
            if circuits.schematicTool == .select,
               let hit = current?.pick(start, tolerance: radius(m) * 0.8, filter: [.symbol, .pin]).first?.object,
               let c = hit.componentID, let sym = circuits.sheets.flatMap(\.symbols).first(where: { $0.componentID == c }) {
                circuits.schematicSelection = hit; circuits.selection = c
                dragging = (c, sym.position, PCBPoint())
            } else {
                panStart = pan
            }
        }
        if var d = dragging {
            // On the 1,27 mm grid while moving.
            let g2 = 1.27, dx = Double(g.translation.width / m.scale), dy = Double(-g.translation.height / m.scale)
            d.delta = PCBPoint((dx / g2).rounded() * g2, (dy / g2).rounded() * g2)
            dragging = d
        } else if let s = panStart {
            pan = CGSize(width: s.width + g.translation.width, height: s.height + g.translation.height)
        }
    }

    private func click(_ p: PCBPoint, _ m: Mapping) {
        guard let drawing = current else { circuits.report("Schema in aggiornamento: un attimo e riprova."); return }
        let here = drawing.snapTargets(near: p, radius: radius(m), grid: 1.27).first
        let point = here?.point ?? p
        switch circuits.schematicTool {
        case .select:
            let hit = drawing.pick(p, tolerance: radius(m) * 0.8).first?.object
            circuits.schematicSelection = hit
            circuits.selection = hit?.componentID
        case let .place(placing):
            circuits.placeSchematic(placing, at: point)
        case .wire:
            let end = here.flatMap { circuits.wireEnd(for: $0) }
            if let start = circuits.wireStart {
                if let end, end != start {
                    circuits.addWire(from: start, to: end, bends: circuits.wireBends)
                    circuits.wireStart = nil; circuits.wireBends = []
                } else if end == nil {
                    circuits.wireBends.append(point)       // a bend on the grid
                }
            } else if let end {
                circuits.wireStart = end
            } else {
                circuits.report("Il filo parte da un pin, da una giunzione o da un filo: clicca lì.")
            }
        case .label:
            if let end = here.flatMap({ circuits.wireEnd(for: $0) }), case let .terminal(t, _) = end {
                circuits.labelTarget = t
            } else {
                circuits.report("L'etichetta va su un pin o su una giunzione.")
            }
        case .noConnect:
            if here?.kind == .pin, let c = here?.object?.componentID, let pin = here?.object?.pinID {
                circuits.markNoConnect(PinReference(componentID: c, pinID: pin))
            } else { circuits.report("NC va su un pin libero.") }
        case .junction:
            if let s = here, [.onWire, .midpoint, .vertex].contains(s.kind), let w = s.object, w.kind == .wire {
                circuits.addJunction(onWire: w.id, at: s.point)
            } else { circuits.report("La giunzione va su un filo.") }
        }
    }

    private func escape() {
        if circuits.wireStart != nil { circuits.wireStart = nil; circuits.wireBends = [] }
        else if circuits.schematicTool != .select { circuits.schematicTool = .select }
        else { circuits.schematicSelection = nil; circuits.selection = nil }
    }

    private func deleteSelection() {
        if let s = circuits.schematicSelection { circuits.removeSchematicObject(s) }
    }

    @ViewBuilder private var hint: some View {
        let text: String? = switch circuits.schematicTool {
        case let .place(p): "Clicca dove posare \(p.reference) · Esc per finire"
        case .wire: circuits.wireStart == nil ? "Filo: clicca un pin, una giunzione o un filo · Esc per finire"
            : "Filo: clicca il pin o il filo d'arrivo; clic nel vuoto = piega · Esc annulla"
        case .label: "Etichetta: clicca il pin o la giunzione da nominare"
        case .noConnect: "NC: clicca il pin da lasciare scollegato"
        case .junction: "Giunzione: clicca il punto del filo da cui ramificare"
        case .select: nil
        }
        if let text {
            Text(text).font(.system(size: 11, weight: .medium)).padding(.horizontal, 10).padding(.vertical, 5).overlayChip()
        }
    }

    private var zoomButtons: some View {
        HStack(spacing: 2) {
            Button { zoom = min(zoom * 1.4, 40) } label: { Label("Ingrandisci", systemImage: "plus.magnifyingglass") }
            Button { zoom = max(zoom / 1.4, 0.2) } label: { Label("Riduci", systemImage: "minus.magnifyingglass") }
            Button { frameDrawing() } label: { Label("Adatta", systemImage: "arrow.up.left.and.down.right.magnifyingglass") }
        }
        .buttonStyle(IconButtonStyle())
        .overlayChip()
    }

    // MARK: Drawing

    private static let accent = Color(red: 1, green: 0.55, blue: 0.22)

    /// Our colours for the engine's semantic styles.
    private func colour(_ style: SchematicPrimitive.Style) -> Color {
        switch style {
        case .symbol: Color(red: 0.86, green: 0.88, blue: 0.92)
        case .pin: Color(red: 0.70, green: 0.73, blue: 0.78)
        case .wire: Color(red: 0.36, green: 0.84, blue: 0.47)
        case .junction: Color(red: 0.36, green: 0.84, blue: 0.47)
        case .reference: Color(red: 0.95, green: 0.95, blue: 0.97)
        case .value: Color(red: 0.72, green: 0.76, blue: 0.82)
        case .pinName, .pinNumber: Color(red: 0.60, green: 0.64, blue: 0.70)
        case .label: Color(red: 0.98, green: 0.80, blue: 0.35)
        case .power: Color(red: 0.95, green: 0.42, blue: 0.40)
        case .noConnect: Color(red: 0.40, green: 0.62, blue: 1.0)
        }
    }

    private func draw(_ ctx: inout GraphicsContext, _ m: Mapping) {
        // The 1,27 mm grid as faint dots when there is room for them.
        if m.scale * 1.27 >= 8, let drawing = circuits.schematic {
            _ = drawing
            let size = ctx.clipBoundingRect
            let lo = m.board(CGPoint(x: size.minX, y: size.maxY)), hi = m.board(CGPoint(x: size.maxX, y: size.minY))
            var x = (lo.x / 1.27).rounded(.down) * 1.27
            var dots = Path()
            while x <= hi.x {
                var y = (lo.y / 1.27).rounded(.down) * 1.27
                while y <= hi.y { let q = m.screen(PCBPoint(x, y)); dots.addRect(CGRect(x: q.x, y: q.y, width: 1, height: 1)); y += 1.27 }
                x += 1.27
            }
            ctx.fill(dots, with: .color(.white.opacity(0.12)))
        }
        let selected = circuits.schematicSelection, lit = hovered
        func paint(_ p: SchematicPrimitive, colour c: Color, offset: PCBPoint = PCBPoint()) {
            func at(_ q: PCBPoint) -> CGPoint { m.screen(PCBPoint(q.x + offset.x, q.y + offset.y)) }
            let width = max(1, CGFloat(p.strokeWidth) * m.scale)
            switch p.shape {
            case let .polyline(pts, closed):
                guard let first = pts.first else { return }
                var path = Path(); path.move(to: at(first)); for q in pts.dropFirst() { path.addLine(to: at(q)) }
                if closed { path.closeSubpath() }
                if p.filled { ctx.fill(path, with: .color(c)) } else { ctx.stroke(path, with: .color(c), style: StrokeStyle(lineWidth: width, lineCap: .round, lineJoin: .round)) }
            case let .circle(center, r):
                let q = at(center), rr = CGFloat(r) * m.scale
                let path = Path(ellipseIn: CGRect(x: q.x - rr, y: q.y - rr, width: 2 * rr, height: 2 * rr))
                if p.filled { ctx.fill(path, with: .color(c)) } else { ctx.stroke(path, with: .color(c), lineWidth: width) }
            case let .text(text, pos, height):
                let size = max(6, CGFloat(height) * m.scale)
                ctx.draw(Text(text).font(.system(size: size, weight: p.style == .reference ? .semibold : .regular)).foregroundColor(c), at: at(pos), anchor: .bottomLeading)
            }
        }
        for p in circuits.schematic?.primitives ?? [] {
            let owner = p.owner
            let isSel = selected.map { s in s.id == owner.id || (s.componentID != nil && s.componentID == owner.componentID && s.kind != .wire && s.kind != .label) } ?? false
            let isLit = lit.map { $0.id == owner.id || ($0.componentID != nil && $0.componentID == owner.componentID) } ?? false
            let sameComponent = circuits.selection != nil && owner.componentID == circuits.selection
            var c = colour(p.style)
            if isSel || sameComponent { c = Self.accent } else if isLit { c = c.opacity(0.75).mix(with: Self.accent, by: 0.5) }
            if let d = dragging, owner.componentID == d.component {
                paint(p, colour: c.opacity(0.35))
                paint(p, colour: Self.accent, offset: d.delta)
            } else {
                paint(p, colour: c)
            }
        }
        // Posa: the session's symbol (previewed once at the origin) under the mouse.
        if case .place = circuits.schematicTool, let at = cursor {
            for p in circuits.schematicGhost { paint(p, colour: Self.accent.opacity(0.7), offset: at) }
        }
        // Filo: from the start through the bends to the mouse.
        if let start = circuits.wireStart, let c = cursor {
            var path = Path(); path.move(to: m.screen(start.point))
            for b in circuits.wireBends { path.addLine(to: m.screen(b)) }
            path.addLine(to: m.screen(c))
            ctx.stroke(path, with: .color(Self.accent), style: StrokeStyle(lineWidth: 1.5, dash: [5, 3]))
        }
        // The engine's snap: □ pin, ● junction, ◇ on a wire, · grid.
        if let s = snap, circuits.schematicTool != .select {
            let q = m.screen(s.point), r: CGFloat = 5
            let rect = CGRect(x: q.x - r, y: q.y - r, width: 2 * r, height: 2 * r)
            let mark: Path = switch s.kind {
            case .pin: Path(rect)
            case .junction: Path(ellipseIn: rect)
            case .onWire, .vertex, .midpoint:
                Path { p in p.move(to: CGPoint(x: q.x, y: q.y - r)); p.addLine(to: CGPoint(x: q.x + r, y: q.y)); p.addLine(to: CGPoint(x: q.x, y: q.y + r)); p.addLine(to: CGPoint(x: q.x - r, y: q.y)); p.closeSubpath() }
            case .grid: Path(ellipseIn: rect.insetBy(dx: 3, dy: 3))
            }
            ctx.stroke(mark, with: .color(Self.accent), lineWidth: 1.5)
        }
    }
}

/// Etichetta: the net's name for the terminal clicked (an existing name joins that net).
struct LabelSheet: View {
    @Environment(CircuitModel.self) private var circuits
    @State private var name = ""
    @State private var power = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Etichetta di rete", systemImage: "tag").font(.headline)
            Text("Lo stesso nome in un altro punto, anche su un altro foglio, è la stessa rete.")
                .font(.caption).foregroundStyle(Theme.Palette.textSecondary)
            TextField("VCC, GND, SDA…", text: $name).textFieldStyle(.roundedBorder)
            let existing = circuits.design?.nets.map(\.name).filter { !$0.isEmpty }.sorted() ?? []
            if !existing.isEmpty {
                Picker("Reti esistenti", selection: $name) {
                    Text("—").tag("")
                    ForEach(existing, id: \.self) { Text($0).tag($0) }
                }
            }
            Toggle("Simbolo di alimentazione", isOn: $power)
            Spacer(minLength: 0)
            HStack {
                Spacer()
                Button("Annulla") { circuits.labelTarget = nil }.keyboardShortcut(.cancelAction)
                Button("OK") {
                    if let t = circuits.labelTarget { circuits.addLabel(at: t, name: name, power: power) }
                    circuits.labelTarget = nil
                }
                .keyboardShortcut(.defaultAction).disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(16).frame(width: 360, height: 260)
        .onAppear {
            if case let .pin(p)? = circuits.labelTarget, let n = circuits.netName(of: p) { name = n }
        }
    }
}
