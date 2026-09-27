import CADCore
import SwiftUI

/// TAVOLA: the technical drawing on screen, as it will be printed. Quota (D) adds a dimension by
/// hand: a point of a view, another point of the same view, then where the dimension line goes
/// (above or below: horizontal; beside: vertical; ⌥ or between the points: aligned). Any
/// dimension can be dragged further out or in, and Canc takes it off (an automatic one comes
/// back with «Ripristina»). Every change is a step of the design's history; the drawing is
/// regenerated from the model each time, with the user's changes on top.
struct DrawingWindow: View {
    @Environment(DesignModel.self) private var model
    @Environment(ProjectLibrary.self) private var library

    enum Tool { case select, dimension }

    @State private var section = false
    @State private var sheet: DrawingSheet?
    @State private var failure: String?
    @State private var tool: Tool = .select
    /// The dimension selected (its mark's key).
    @State private var selected: String?
    @State private var hoveredMark: String?
    /// Quota: the points chosen so far, the snap point under the mouse, the mouse (sheet mm).
    @State private var picked: [DrawingSheet.SnapPoint] = []
    @State private var hoverSnap: DrawingSheet.SnapPoint?
    @State private var mouse: Vec2?
    /// A dimension being dragged: its mark, where the drag started, how far along its side (mm).
    @State private var moving: (mark: DrawingSheet.DimensionMark, start: Vec2, delta: Double)?
    @State private var hint = ""
    @FocusState private var focused: Bool

    private struct Fit {
        var scale: CGFloat, ox: CGFloat, oy: CGFloat, height: Double
        func pt(_ p: Vec2) -> CGPoint { CGPoint(x: ox + CGFloat(p.x) * scale, y: oy + CGFloat(height - p.y) * scale) }
        func mm(_ q: CGPoint) -> Vec2 { Vec2(Double((q.x - ox) / scale), height - Double((q.y - oy) / scale)) }
        /// Screen points in sheet mm.
        func mm(points: CGFloat) -> Double { Double(points / scale) }
    }

    private func fit(_ size: CGSize, _ s: DrawingSheet) -> Fit {
        let scale = min((size.width - 24) / CGFloat(s.width), (size.height - 24) / CGFloat(s.height))
        return Fit(scale: scale, ox: (size.width - CGFloat(s.width) * scale) / 2, oy: (size.height - CGFloat(s.height) * scale) / 2, height: s.height)
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            GeometryReader { geo in
                if let sheet {
                    let f = fit(geo.size, sheet)
                    Canvas { ctx, _ in draw(&ctx, sheet, f) }
                        .contentShape(Rectangle())
                        .onContinuousHover { phase in hover(phase, sheet, f) }
                        .gesture(DragGesture(minimumDistance: 0)
                            .onChanged { g in dragChanged(g, sheet, f) }
                            .onEnded { g in dragEnded(g, sheet, f) })
                        .focusable().focused($focused).focusEffectDisabled()
                        .onKeyPress(.delete) { deleteSelected(); return .handled }
                        .onKeyPress(.deleteForward) { deleteSelected(); return .handled }
                        .onKeyPress(.escape) { escape(); return .handled }
                        .onKeyPress("d") { setTool(tool == .dimension ? .select : .dimension); return .handled }
                } else {
                    Text(failure ?? "Preparo la tavola…").foregroundStyle(Theme.Palette.textSecondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .background(Color(white: 0.55))
            Divider()
            footer
        }
        .frame(minWidth: 960, idealWidth: 1180, minHeight: 680, idealHeight: 840)
        .onAppear { rebuild(); focused = true }
        .onChange(of: model.designRevision) { rebuild() }
        .onChange(of: section) { rebuild() }
    }

    // MARK: Bars

    private var toolbar: some View {
        HStack(spacing: 10) {
            Label("Tavola", systemImage: "doc.richtext").font(.headline)
            Divider().frame(height: 18)
            Button { setTool(.select) } label: { Label("Seleziona", systemImage: "cursorarrow") }
                .buttonStyle(RibbonButtonStyle(isActive: tool == .select, tint: Theme.Palette.accent))
                .help("Clic su una quota per sceglierla, trascinala per allontanarla o avvicinarla, Canc la toglie")
            Button { setTool(.dimension) } label: { Label("Quota", systemImage: "ruler") }
                .buttonStyle(RibbonButtonStyle(isActive: tool == .dimension, tint: Theme.Palette.accent))
                .help("Aggiungi una quota (D): due punti della stessa vista, poi dove mettere la linea")
            Toggle("Sezione A-A", isOn: $section).toggleStyle(.checkbox)
                .help("Vista di fronte in sezione (pezzi torniti, fori interni)")
            Button("Ripristina quote automatiche") {
                model.edit("Ripristina quote della tavola") { $0.drawing.hidden = []; $0.drawing.moved = [:] }
            }
            .disabled(model.document.drawing.hidden.isEmpty && model.document.drawing.moved.isEmpty)
            .help("Rimette le quote automatiche tolte o spostate")
            Spacer()
            if let scale = sheet?.texts.first(where: { t in TechnicalDrawing.scales.contains { $0.1 == t.text } })?.text {
                Text("\(sheet!.width > 300 ? "A3" : "A4") · scala \(scale)").font(.callout).foregroundStyle(Theme.Palette.textSecondary)
            }
            Button { model.exportDrawingWithPanel(section: section) } label: { Label("Esporta…", systemImage: "square.and.arrow.up") }
                .help("PDF per stampare, DXF per altri CAD: scegli l'estensione nel pannello")
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
    }

    private var footer: some View {
        HStack {
            Text(hintText).font(.callout).foregroundStyle(Theme.Palette.textSecondary).lineLimit(2)
            Spacer()
            Button("Chiudi") { model.showDrawing = false }.keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
    }

    private var hintText: String {
        if !hint.isEmpty { return hint }
        switch tool {
        case .select:
            return selected == nil ? "Clic su una quota per sceglierla · D per aggiungerne una" : "Trascina la quota per spostarla · Canc la toglie · Esc deseleziona"
        case .dimension:
            switch picked.count {
            case 0: return "Quota: clicca il primo punto (estremo o metà di uno spigolo, centro di un foro)"
            case 1: return "Quota: clicca il secondo punto nella stessa vista · Esc ricomincia"
            default: return "Quota: clicca dove va la linea — sopra/sotto orizzontale, a lato verticale, ⌥ o in mezzo allineata · Esc annulla"
            }
        }
    }

    // MARK: Model

    private func rebuild() {
        do {
            sheet = try model.drawingSheet(title: library.currentName.isEmpty ? "Tavola" : library.currentName, section: section)
            failure = nil
        } catch {
            sheet = nil
            failure = "Tavola non disponibile: \(error.localizedDescription)"
        }
        if let s = sheet, let key = selected, !s.marks.contains(where: { $0.key == key }) { selected = nil }
        // Points picked on the old sheet: their places may have moved.
        picked = picked.compactMap { p in sheet?.snapPoints.first { $0.view == p.view && ($0.local - p.local).length < 1e-6 } }
    }

    private func setTool(_ t: Tool) {
        tool = t; picked = []; hint = ""
        if t == .dimension { selected = nil }
    }

    private func escape() {
        if !picked.isEmpty { picked = [] } else if tool != .select { setTool(.select) } else { selected = nil }
        hint = ""
    }

    private func deleteSelected() {
        guard let key = selected else { return }
        if key.hasPrefix("manual/"), let id = UUID(uuidString: String(key.dropFirst("manual/".count))) {
            model.edit("Togli quota dalla tavola") { $0.drawing.dimensions.removeAll { $0.id == id } }
        } else {
            model.edit("Togli quota dalla tavola") { doc in
                if !doc.drawing.hidden.contains(key) { doc.drawing.hidden.append(key) }
                doc.drawing.moved[key] = nil
            }
        }
        selected = nil
    }

    /// The dimension a third click would add: direction from where the mouse is.
    private func candidate(_ a: DrawingSheet.SnapPoint, _ b: DrawingSheet.SnapPoint, mouse m: Vec2, aligned: Bool) -> DrawingDimension {
        let A = a.at, B = b.at
        let minX = min(A.x, B.x), maxX = max(A.x, B.x), minY = min(A.y, B.y), maxY = max(A.y, B.y)
        let outX = m.x > maxX ? m.x - maxX : (m.x < minX ? minX - m.x : 0)
        let outY = m.y > maxY ? m.y - maxY : (m.y < minY ? minY - m.y : 0)
        var direction: DrawingDimension.Direction
        if aligned || (outX == 0 && outY == 0) { direction = .aligned }
        else { direction = outY >= outX ? .horizontal : .vertical }
        // Points on one vertical (horizontal) line: only their vertical (horizontal) distance means anything.
        if abs(maxX - minX) < 1e-6, direction == .horizontal { direction = .vertical }
        if abs(maxY - minY) < 1e-6, direction == .vertical { direction = .horizontal }
        let offset: Double
        switch direction {
        case .horizontal: offset = m.y >= (minY + maxY) / 2 ? max(m.y - maxY, 2) : -max(minY - m.y, 2)
        case .vertical: offset = m.x >= (minX + maxX) / 2 ? max(m.x - maxX, 2) : -max(minX - m.x, 2)
        case .aligned:
            let u = (B - A).length > 1e-9 ? (B - A).normalized : Vec2(1, 0), n = Vec2(-u.y, u.x)
            let d = (m - A).dot(n)
            offset = d >= 0 ? max(d, 2) : min(d, -2)
        }
        return DrawingDimension(view: a.view, a: a.local, b: b.local, direction: direction, offset: offset)
    }

    // MARK: Mouse

    private func nearestSnap(_ p: Vec2, _ s: DrawingSheet, _ f: Fit, view: DrawingDimension.View? = nil) -> DrawingSheet.SnapPoint? {
        let tol = f.mm(points: 10)
        return s.snapPoints.filter { view == nil || $0.view == view }.min { ($0.at - p).length < ($1.at - p).length }
            .flatMap { ($0.at - p).length <= tol ? $0 : nil }
    }

    private func nearestMark(_ p: Vec2, _ s: DrawingSheet, _ f: Fit) -> DrawingSheet.DimensionMark? {
        let tol = f.mm(points: 8)
        return s.marks.min { $0.distance(to: p) < $1.distance(to: p) }.flatMap { $0.distance(to: p) <= tol ? $0 : nil }
    }

    private func hover(_ phase: HoverPhase, _ s: DrawingSheet, _ f: Fit) {
        guard case let .active(q) = phase else { mouse = nil; hoverSnap = nil; hoveredMark = nil; return }
        let p = f.mm(q)
        mouse = p
        switch tool {
        case .dimension:
            hoverSnap = picked.count < 2 ? nearestSnap(p, s, f, view: picked.first?.view) : nil
            hoveredMark = nil
        case .select:
            hoverSnap = nil
            hoveredMark = nearestMark(p, s, f)?.key
        }
    }

    private func dragChanged(_ g: DragGesture.Value, _ s: DrawingSheet, _ f: Fit) {
        focused = true
        guard tool == .select else { return }
        let p = f.mm(g.location)
        if moving == nil {
            guard hypot(g.translation.width, g.translation.height) > 3, let mark = nearestMark(f.mm(g.startLocation), s, f) else { return }
            selected = mark.key
            moving = (mark, f.mm(g.startLocation), 0)
        }
        if var m = moving {
            m.delta = ((p - m.start).dot(m.mark.side) * 2).rounded() / 2   // 0,5 mm steps
            moving = m
        }
    }

    private func dragEnded(_ g: DragGesture.Value, _ s: DrawingSheet, _ f: Fit) {
        defer { moving = nil }
        if let m = moving {
            if m.delta != 0 { move(m.mark, by: m.delta) }
            return
        }
        click(f.mm(g.location), s, f)
    }

    private func move(_ mark: DrawingSheet.DimensionMark, by delta: Double) {
        if let id = mark.manual {
            model.edit("Sposta quota sulla tavola") { doc in
                guard let i = doc.drawing.dimensions.firstIndex(where: { $0.id == id }) else { return }
                let o = doc.drawing.dimensions[i].offset
                doc.drawing.dimensions[i].offset = (o < 0 ? -1 : 1) * max(abs(o) + delta, 2)
            }
        } else {
            model.edit("Sposta quota sulla tavola") { $0.drawing.moved[mark.key, default: 0] += delta }
        }
    }

    private func click(_ p: Vec2, _ s: DrawingSheet, _ f: Fit) {
        focused = true
        hint = ""
        switch tool {
        case .select:
            selected = nearestMark(p, s, f)?.key
        case .dimension:
            if picked.count == 2 {
                let d = candidate(picked[0], picked[1], mouse: p, aligned: NSEvent.modifierFlags.contains(.option))
                guard d.value > 1e-6 else { hint = "Quota nulla: scegli due punti distanti."; picked = []; return }
                model.edit("Quota sulla tavola") { $0.drawing.dimensions.append(d) }
                selected = "manual/" + d.id.uuidString
                picked = []
                return
            }
            guard let snap = nearestSnap(p, s, f, view: picked.first?.view) else {
                hint = picked.isEmpty ? "Clicca vicino a un estremo o alla metà di uno spigolo, o al centro di un foro."
                    : "Il secondo punto va nella stessa vista del primo."
                return
            }
            if let first = picked.first, (first.local - snap.local).length < 1e-9 { return }
            picked.append(snap)
        }
    }

    // MARK: Drawing

    private func draw(_ ctx: inout GraphicsContext, _ s: DrawingSheet, _ f: Fit) {
        let paper = CGRect(x: f.ox, y: f.oy, width: CGFloat(s.width) * f.scale, height: CGFloat(s.height) * f.scale)
        ctx.fill(Path(paper), with: .color(.white))
        let ink = Color(white: 0.08), accent = Theme.Palette.accent
        for line in s.lines {
            var path = Path(); path.move(to: f.pt(line.a)); path.addLine(to: f.pt(line.b))
            let mm = f.scale
            let style: StrokeStyle = switch line.style {
            case .visible: StrokeStyle(lineWidth: max(0.35 * mm, 0.9), lineCap: .round)
            case .hidden: StrokeStyle(lineWidth: max(0.25 * mm, 0.6), dash: [3 * mm, 1.5 * mm])
            case .thin: StrokeStyle(lineWidth: max(0.18 * mm, 0.5))
            case .border: StrokeStyle(lineWidth: max(0.5 * mm, 1.2))
            case .center: StrokeStyle(lineWidth: max(0.18 * mm, 0.5), dash: [8 * mm, 1.5 * mm, 1 * mm, 1.5 * mm])
            }
            ctx.stroke(path, with: .color(ink), style: style)
        }
        for tri in s.arrows where tri.count == 3 {
            var path = Path(); path.move(to: f.pt(tri[0])); path.addLine(to: f.pt(tri[1])); path.addLine(to: f.pt(tri[2])); path.closeSubpath()
            ctx.fill(path, with: .color(ink))
        }
        for t in s.texts {
            let anchor: UnitPoint = switch t.align { case .left: .bottomLeading; case .center: .bottom; case .right: .bottomTrailing }
            var layer = ctx
            layer.translateBy(x: f.pt(t.at).x, y: f.pt(t.at).y)
            layer.rotate(by: .degrees(-t.angle))
            layer.draw(Text(t.text).font(.system(size: max(CGFloat(t.size) * f.scale, 4))).foregroundColor(ink), at: .zero, anchor: anchor)
        }
        // Selection and hover: the dimension line in the accent colour; while dragging, where it goes.
        for mark in s.marks where mark.key == selected || mark.key == hoveredMark {
            let shift = moving.map { $0.mark.key == mark.key ? mark.side * $0.delta : Vec2(0, 0) } ?? Vec2(0, 0)
            var path = Path(); path.move(to: f.pt(mark.line.0 + shift)); path.addLine(to: f.pt(mark.line.1 + shift))
            ctx.stroke(path, with: .color(accent.opacity(mark.key == selected ? 1 : 0.6)), lineWidth: mark.key == selected ? 2.5 : 2)
            let c = f.pt(mark.text + shift)
            ctx.stroke(Path(ellipseIn: CGRect(x: c.x - 9, y: c.y - 9, width: 18, height: 18)), with: .color(accent.opacity(0.7)), lineWidth: 1.2)
        }
        guard tool == .dimension else { return }
        // Quota: the snap points of the view in use, the one under the mouse, those picked, the preview.
        for p in s.snapPoints where picked.isEmpty || p.view == picked[0].view {
            let c = f.pt(p.at)
            ctx.fill(Path(ellipseIn: CGRect(x: c.x - 1.5, y: c.y - 1.5, width: 3, height: 3)), with: .color(accent.opacity(0.45)))
        }
        for p in picked + (hoverSnap.map { [$0] } ?? []) {
            let c = f.pt(p.at)
            ctx.stroke(Path(ellipseIn: CGRect(x: c.x - 6, y: c.y - 6, width: 12, height: 12)), with: .color(accent), lineWidth: 2)
        }
        if picked.count == 1, let m = mouse {
            var path = Path(); path.move(to: f.pt(picked[0].at)); path.addLine(to: f.pt(hoverSnap?.at ?? m))
            ctx.stroke(path, with: .color(accent), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
        }
        if picked.count == 2, let m = mouse, let place = s.views.first(where: { $0.view == picked[0].view }) {
            let d = candidate(picked[0], picked[1], mouse: m, aligned: NSEvent.modifierFlags.contains(.option))
            let a = place.sheet(d.a), b = place.sheet(d.b)
            let sign = d.offset < 0 ? -1.0 : 1.0
            let n: Vec2 = switch d.direction {
            case .horizontal: Vec2(0, sign)
            case .vertical: Vec2(sign, 0)
            case .aligned: { let u = (b - a).normalized; return Vec2(-u.y, u.x) * sign }()
            }
            let level = max(a.dot(n), b.dot(n)) + abs(d.offset)
            let a1 = a + n * (level - a.dot(n)), b1 = b + n * (level - b.dot(n))
            var path = Path()
            path.move(to: f.pt(a)); path.addLine(to: f.pt(a1)); path.addLine(to: f.pt(b1)); path.addLine(to: f.pt(b))
            ctx.stroke(path, with: .color(accent), lineWidth: 1.4)
            let mid = f.pt((a1 + b1) * 0.5 + n * 2)
            ctx.draw(Text(SheetMetalCommand.mm(d.value)).font(.system(size: max(3.5 * f.scale, 9), weight: .semibold)).foregroundColor(accent), at: mid)
        }
    }
}
