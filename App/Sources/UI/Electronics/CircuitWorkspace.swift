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
            HStack(spacing: 0) {
                CircuitBoardView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                Divider()
                CircuitChecksPanel()
                    .frame(width: 280)
            }
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
                    if case let .active(q) = phase { hoveredPad = pad(at: m.board(q)) } else { hoveredPad = nil }
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
                    circuits.selection = pad(at: m.board(tap.location))?.componentID
                    focused = true
                })
                .gesture(MagnifyGesture().updating($pinch) { value, state, _ in state = value.magnification }
                    .onEnded { value in zoom = min(max(zoom * value.magnification, 0.2), 40) })
                .focusable().focused($focused).focusEffectDisabled()
                .onKeyPress("r") { if let c = circuits.selection { circuits.rotate(c) }; return .handled }
                .onKeyPress("f") { if let c = circuits.selection { circuits.flip(c) }; return .handled }
                .onKeyPress(.escape) { circuits.selection = nil; return .handled }
                .onHover { inside in if inside { NSCursor.arrow.set() } }
                .overlay(alignment: .bottomTrailing) { zoomButtons.padding(12) }
                .overlay(alignment: .topLeading) { hoverChip.padding(12) }
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
