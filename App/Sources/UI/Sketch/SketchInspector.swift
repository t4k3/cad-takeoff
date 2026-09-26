import CADCore
import SwiftUI

/// Parametri panel while sketching: entity list + editable parameters of the selected entity.
struct SketchInspector: View {
    @Bindable var sketch: SketchSession

    var body: some View {
        VStack(spacing: 0) {
            PanelHeader("Parametri schizzo")
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    HStack {
                        Image(systemName: "pencil.and.outline").foregroundStyle(Theme.Palette.sketch)
                        TextField("Nome", text: $sketch.sketch.name).textFieldStyle(.plain)
                            .font(.system(size: 13, weight: .semibold))
                    }
                    section("Entità (\(sketch.shapes.count))") {
                        if sketch.shapes.isEmpty {
                            Text("Disegna con gli strumenti della barra SCHIZZO.").font(.caption)
                                .foregroundStyle(Theme.Palette.textSecondary)
                        }
                        ForEach(Array(sketch.shapes.enumerated()), id: \.element.id) { i, s in
                            entityRow(s, index: i + 1)
                        }
                    }
                    if let id = sketch.selection, let shape = sketch.shape(id) {
                        section(shape.typeName) { ShapeParameters(sketch: sketch, id: id, shape: shape) }
                    }
                }
                .padding(Theme.Metrics.pad + 2)
            }
        }
        .background(Theme.Palette.panel)
    }

    private func entityRow(_ s: SketchShape, index: Int) -> some View {
        let selected = sketch.selection == s.id
        return Button { sketch.selection = s.id } label: { entityLabel(s, index: index, selected: selected) }
            .buttonStyle(.plain)
            .accessibilityLabel("\(s.typeName) \(index), \(summary(s))")
            .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func entityLabel(_ s: SketchShape, index: Int, selected: Bool) -> some View {
        HStack(spacing: 6) {
            Image(systemName: symbol(s)).frame(width: 16)
                .foregroundStyle(selected ? Theme.Palette.accent : Theme.Palette.sketch)
            Text("\(s.typeName) \(index)").font(Theme.Typeface.body)
            if s.isConstruction { Text("costr.").font(.caption2).foregroundStyle(Theme.Palette.textSecondary) }
            Spacer()
            Text(summary(s)).font(Theme.Typeface.mono).foregroundStyle(Theme.Palette.textSecondary).lineLimit(1)
        }
        .padding(.horizontal, 6).frame(height: 24)
        .background(RoundedRectangle(cornerRadius: 4).fill(selected ? Theme.Palette.accent.opacity(0.16) : .clear))
        .contentShape(Rectangle())
    }

    private func symbol(_ s: SketchShape) -> String {
        switch s.kind {
        case let .polyline(_, closed): closed ? "pentagon" : "line.diagonal"
        case .rectangle: "rectangle"
        case .circle: "circle"
        case .polygon: "hexagon"
        case .slot: "capsule"
        case .arc: "circle.bottomhalf.filled"
        }
    }

    private func summary(_ s: SketchShape) -> String {
        switch s.kind {
        case .polyline: "\(fmt(s.length)) mm"
        case let .rectangle(_, w, h): "\(fmt(abs(w)))×\(fmt(abs(h)))"
        case let .circle(_, r): "Ø\(fmt(2 * r))"
        case let .polygon(_, r, _, _, _): "R\(fmt(r))"
        case let .slot(a, b, w): "\(fmt(hypot(b.x - a.x, b.y - a.y)))×\(fmt(w))"
        case let .arc(_, r, _, _): "R\(fmt(r))"
        }
    }

    private func section<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title.uppercased()).font(.system(size: 9.5, weight: .semibold)).tracking(0.5)
                .foregroundStyle(Theme.Palette.textSecondary)
            content()
        }
    }
}

/// Editable parameters of one entity. Each field rewrites the entity kind.
private struct ShapeParameters: View {
    let sketch: SketchSession
    let id: SketchShape.ID
    let shape: SketchShape

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            switch shape.kind {
            case let .polyline(p, closed):
                if p.count == 2 { line(p[0], p[1]) } else { polyline(p, closed: closed) }
            case let .rectangle(c, w, h):
                let x0 = min(c.x, c.x + w), y0 = min(c.y, c.y + h)
                field("Angolo X", x0) { set(.rectangle(corner: Vec2($0, y0), width: abs(w), height: abs(h))) }
                field("Angolo Y", y0) { set(.rectangle(corner: Vec2(x0, $0), width: abs(w), height: abs(h))) }
                field("Larghezza", abs(w), positive: true) { set(.rectangle(corner: Vec2(x0, y0), width: $0, height: abs(h))) }
                field("Altezza", abs(h), positive: true) { set(.rectangle(corner: Vec2(x0, y0), width: abs(w), height: $0)) }
            case let .circle(c, r):
                field("Centro X", c.x) { set(.circle(center: Vec2($0, c.y), radius: r)) }
                field("Centro Y", c.y) { set(.circle(center: Vec2(c.x, $0), radius: r)) }
                field("Diametro", 2 * r, positive: true) { set(.circle(center: c, radius: $0 / 2)) }
            case let .polygon(c, r, n, rot, circ):
                field("Centro X", c.x) { set(.polygon(center: Vec2($0, c.y), radius: r, sides: n, rotation: rot, circumscribed: circ)) }
                field("Centro Y", c.y) { set(.polygon(center: Vec2(c.x, $0), radius: r, sides: n, rotation: rot, circumscribed: circ)) }
                field(circ ? "Raggio (apotema)" : "Raggio (vertici)", r, positive: true) {
                    set(.polygon(center: c, radius: $0, sides: n, rotation: rot, circumscribed: circ))
                }
                Stepper(value: Binding(get: { n }, set: { set(.polygon(center: c, radius: r, sides: $0, rotation: rot, circumscribed: circ)) }), in: 3...64) {
                    HStack { label("Lati"); Spacer(); Text("\(n)").font(Theme.Typeface.mono) }
                }
                field("Rotazione", rot * 180 / .pi, unit: "°") { set(.polygon(center: c, radius: r, sides: n, rotation: $0 * .pi / 180, circumscribed: circ)) }
                Picker("Tipo", selection: Binding(get: { circ }, set: { set(.polygon(center: c, radius: r, sides: n, rotation: rot, circumscribed: $0)) })) {
                    Text("Inscritto").tag(false)
                    Text("Circoscritto").tag(true)
                }
                .pickerStyle(.segmented)
            case let .slot(a, b, wdt):
                let len = hypot(b.x - a.x, b.y - a.y), ang = atan2(b.y - a.y, b.x - a.x)
                let endFrom = { (s: Vec2, l: Double, t: Double) in Vec2(s.x + l * cos(t), s.y + l * sin(t)) }
                field("Centro 1 X", a.x) { let s = Vec2($0, a.y); set(.slot(start: s, end: endFrom(s, len, ang), width: wdt)) }
                field("Centro 1 Y", a.y) { let s = Vec2(a.x, $0); set(.slot(start: s, end: endFrom(s, len, ang), width: wdt)) }
                field("Interasse", len, positive: true) { set(.slot(start: a, end: endFrom(a, $0, ang), width: wdt)) }
                field("Angolo", ang * 180 / .pi, unit: "°") { set(.slot(start: a, end: endFrom(a, len, $0 * .pi / 180), width: wdt)) }
                field("Larghezza", wdt, positive: true) { set(.slot(start: a, end: b, width: $0)) }
                info("Lunghezza totale", "\(fmt(len + wdt)) mm")
            case let .arc(c, r, a0, a1):
                field("Centro X", c.x) { set(.arc(center: Vec2($0, c.y), radius: r, start: a0, end: a1)) }
                field("Centro Y", c.y) { set(.arc(center: Vec2(c.x, $0), radius: r, start: a0, end: a1)) }
                field("Raggio", r, positive: true) { set(.arc(center: c, radius: $0, start: a0, end: a1)) }
                field("Angolo iniziale", a0 * 180 / .pi, unit: "°") { set(.arc(center: c, radius: r, start: $0 * .pi / 180, end: a1)) }
                field("Angolo finale", a1 * 180 / .pi, unit: "°") { set(.arc(center: c, radius: r, start: a0, end: $0 * .pi / 180)) }
            }
            if shape.isClosed { info("Area", "\(fmt(shape.area)) mm²") }
            info(shape.isClosed ? "Perimetro" : "Lunghezza", "\(fmt(shape.length)) mm")
            Toggle("Geometria di costruzione", isOn: Binding(get: { shape.isConstruction },
                                                             set: { v in sketch.update(id) { $0.isConstruction = v } }))
                .toggleStyle(.switch).controlSize(.small).font(Theme.Typeface.body)
                .help("Linee di riferimento: non diventano profili da estrudere")
            Button(role: .destructive) { sketch.deleteSelection() } label: { Label("Elimina entità", systemImage: "trash") }
                .controlSize(.small)
        }
    }

    // Line: start point, length and angle (end derived).
    @ViewBuilder private func line(_ p0: Vec2, _ p1: Vec2) -> some View {
        let len = hypot(p1.x - p0.x, p1.y - p0.y), ang = atan2(p1.y - p0.y, p1.x - p0.x)
        let end = { (s: Vec2, l: Double, t: Double) in [s, Vec2(s.x + l * cos(t), s.y + l * sin(t))] }
        field("Inizio X", p0.x) { set(.polyline(end(Vec2($0, p0.y), len, ang), closed: false)) }
        field("Inizio Y", p0.y) { set(.polyline(end(Vec2(p0.x, $0), len, ang), closed: false)) }
        field("Lunghezza", len, positive: true) { set(.polyline(end(p0, $0, ang), closed: false)) }
        field("Angolo", ang * 180 / .pi, unit: "°") { set(.polyline(end(p0, len, $0 * .pi / 180), closed: false)) }
    }

    // Polyline/profile: each vertex editable.
    @ViewBuilder private func polyline(_ p: [Vec2], closed: Bool) -> some View {
        ForEach(p.indices, id: \.self) { i in
            HStack(spacing: 4) {
                label("P\(i + 1)").frame(width: 26, alignment: .leading)
                coord(p[i].x) { var q = p; q[i].x = $0; set(.polyline(q, closed: closed)) }
                coord(p[i].y) { var q = p; q[i].y = $0; set(.polyline(q, closed: closed)) }
            }
        }
        Toggle("Chiusa (profilo)", isOn: Binding(get: { closed }, set: { set(.polyline(p, closed: $0 && p.count >= 3)) }))
            .toggleStyle(.switch).controlSize(.small).font(Theme.Typeface.body)
    }

    private func set(_ kind: SketchShape.Kind) { sketch.replace(id, with: kind) }

    private func field(_ title: String, _ value: Double, unit: String = "mm", positive: Bool = false,
                       _ apply: @escaping (Double) -> Void) -> some View {
        DimensionField(title: title, value: Binding(get: { value }, set: { v in
            guard v.isFinite, !positive || v > 0 else { return }
            apply(v)
        }), unit: unit)
    }

    private func coord(_ value: Double, _ apply: @escaping (Double) -> Void) -> some View {
        TextField("", value: Binding(get: { value }, set: { if $0.isFinite { apply($0) } }),
                  format: .number.precision(.fractionLength(0...3)))
            .textFieldStyle(.roundedBorder).font(Theme.Typeface.mono).multilineTextAlignment(.trailing)
    }

    private func label(_ s: String) -> some View { Text(s).font(Theme.Typeface.body).foregroundStyle(Theme.Palette.textSecondary) }

    private func info(_ t: String, _ v: String) -> some View {
        HStack { label(t); Spacer(); Text(v).font(Theme.Typeface.mono) }
    }
}
