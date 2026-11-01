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
                    section(String(localized: "Entità (\(sketch.shapes.count))")) {
                        if sketch.shapes.isEmpty {
                            Text("Disegna con gli strumenti della barra SCHIZZO.").font(.caption)
                                .foregroundStyle(Theme.Palette.textSecondary)
                        }
                        ForEach(Array(sketch.shapes.enumerated()), id: \.element.id) { i, s in
                            entityRow(s, index: i + 1)
                        }
                    }
                    if let id = sketch.selection, let shape = sketch.shape(id) {
                        section(shape.localizedTypeName) { ShapeParameters(sketch: sketch, id: id, shape: shape) }
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
            .accessibilityLabel(Text(verbatim: "\(s.localizedTypeName) \(index), \(summary(s))"))
            .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func entityLabel(_ s: SketchShape, index: Int, selected: Bool) -> some View {
        HStack(spacing: 6) {
            Image(systemName: symbol(s)).frame(width: 16)
                .foregroundStyle(selected ? Theme.Palette.accent : Theme.Palette.sketch)
            Text(verbatim: "\(s.localizedTypeName) \(index)").font(Theme.Typeface.body)
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
        case .spline: "scribble.variable"
        case .bezier: "waveform.path"
        case .point3D: "point.3.connected.trianglepath.dotted"
        case .line3D: "line.diagonal"
        case .workplane: "square.stack.3d.up"
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
        case let .spline(p, _): String(localized: "\(p.count) punti")
        case .bezier: "\(fmt(s.length)) mm"
        case let .point3D(p): "\(fmt(p.x)), \(fmt(p.y)), \(fmt(p.z)) mm"
        case .line3D: "\(fmt(s.length)) mm"
        case .workplane: s.workplanePlane == nil ? "degenere" : ""
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
                field(String(localized: "Angolo X"), x0) { set(.rectangle(corner: Vec2($0, y0), width: abs(w), height: abs(h))) }
                field(String(localized: "Angolo Y"), y0) { set(.rectangle(corner: Vec2(x0, $0), width: abs(w), height: abs(h))) }
                field(String(localized: "Larghezza"), abs(w), positive: true) { set(.rectangle(corner: Vec2(x0, y0), width: $0, height: abs(h))) }
                field(String(localized: "Altezza"), abs(h), positive: true) { set(.rectangle(corner: Vec2(x0, y0), width: abs(w), height: $0)) }
            case let .circle(c, r):
                field(String(localized: "Centro X"), c.x) { set(.circle(center: Vec2($0, c.y), radius: r)) }
                field(String(localized: "Centro Y"), c.y) { set(.circle(center: Vec2(c.x, $0), radius: r)) }
                field(String(localized: "Diametro"), 2 * r, positive: true) { set(.circle(center: c, radius: $0 / 2)) }
            case let .polygon(c, r, n, rot, circ):
                field(String(localized: "Centro X"), c.x) { set(.polygon(center: Vec2($0, c.y), radius: r, sides: n, rotation: rot, circumscribed: circ)) }
                field(String(localized: "Centro Y"), c.y) { set(.polygon(center: Vec2(c.x, $0), radius: r, sides: n, rotation: rot, circumscribed: circ)) }
                field(circ ? String(localized: "Raggio (apotema)") : String(localized: "Raggio (vertici)"), r, positive: true) {
                    set(.polygon(center: c, radius: $0, sides: n, rotation: rot, circumscribed: circ))
                }
                Stepper(value: Binding(get: { n }, set: { set(.polygon(center: c, radius: r, sides: $0, rotation: rot, circumscribed: circ)) }), in: 3...64) {
                    HStack { label(String(localized: "Lati")); Spacer(); Text("\(n)").font(Theme.Typeface.mono) }
                }
                field(String(localized: "Rotazione"), rot * 180 / .pi, unit: "°") { set(.polygon(center: c, radius: r, sides: n, rotation: $0 * .pi / 180, circumscribed: circ)) }
                Picker("Tipo", selection: Binding(get: { circ }, set: { set(.polygon(center: c, radius: r, sides: n, rotation: rot, circumscribed: $0)) })) {
                    Text("Inscritto").tag(false)
                    Text("Circoscritto").tag(true)
                }
                .pickerStyle(.segmented)
            case let .slot(a, b, wdt):
                let len = hypot(b.x - a.x, b.y - a.y), ang = atan2(b.y - a.y, b.x - a.x)
                let endFrom = { (s: Vec2, l: Double, t: Double) in Vec2(s.x + l * cos(t), s.y + l * sin(t)) }
                field(String(localized: "Centro 1 X"), a.x) { let s = Vec2($0, a.y); set(.slot(start: s, end: endFrom(s, len, ang), width: wdt)) }
                field(String(localized: "Centro 1 Y"), a.y) { let s = Vec2(a.x, $0); set(.slot(start: s, end: endFrom(s, len, ang), width: wdt)) }
                field(String(localized: "Interasse"), len, positive: true) { set(.slot(start: a, end: endFrom(a, $0, ang), width: wdt)) }
                field(String(localized: "Angolo"), ang * 180 / .pi, unit: "°") { set(.slot(start: a, end: endFrom(a, len, $0 * .pi / 180), width: wdt)) }
                field(String(localized: "Larghezza"), wdt, positive: true) { set(.slot(start: a, end: b, width: $0)) }
                info(String(localized: "Lunghezza totale"), "\(fmt(len + wdt)) mm")
            case let .spline(p, closed):
                ForEach(p.indices, id: \.self) { i in
                    field(String(localized: "Punto \(i + 1) X"), p[i].x) { var q = p; q[i].x = $0; set(.spline(points: q, closed: closed)) }
                    field(String(localized: "Punto \(i + 1) Y"), p[i].y) { var q = p; q[i].y = $0; set(.spline(points: q, closed: closed)) }
                }
                info(String(localized: "Lunghezza"), "\(fmt(shape.length)) mm")
            case let .bezier(p0, c1, c2, p3):
                field(String(localized: "Inizio X"), p0.x) { set(.bezier(start: Vec2($0, p0.y), control1: c1, control2: c2, end: p3)) }
                field(String(localized: "Inizio Y"), p0.y) { set(.bezier(start: Vec2(p0.x, $0), control1: c1, control2: c2, end: p3)) }
                field(String(localized: "Controllo 1 X"), c1.x) { set(.bezier(start: p0, control1: Vec2($0, c1.y), control2: c2, end: p3)) }
                field(String(localized: "Controllo 1 Y"), c1.y) { set(.bezier(start: p0, control1: Vec2(c1.x, $0), control2: c2, end: p3)) }
                field(String(localized: "Controllo 2 X"), c2.x) { set(.bezier(start: p0, control1: c1, control2: Vec2($0, c2.y), end: p3)) }
                field(String(localized: "Controllo 2 Y"), c2.y) { set(.bezier(start: p0, control1: c1, control2: Vec2(c2.x, $0), end: p3)) }
                field(String(localized: "Fine X"), p3.x) { set(.bezier(start: p0, control1: c1, control2: c2, end: Vec2($0, p3.y))) }
                field(String(localized: "Fine Y"), p3.y) { set(.bezier(start: p0, control1: c1, control2: c2, end: Vec2(p3.x, $0))) }
                info(String(localized: "Lunghezza"), "\(fmt(shape.length)) mm")
            case let .arc(c, r, a0, a1):
                field(String(localized: "Centro X"), c.x) { set(.arc(center: Vec2($0, c.y), radius: r, start: a0, end: a1)) }
                field(String(localized: "Centro Y"), c.y) { set(.arc(center: Vec2(c.x, $0), radius: r, start: a0, end: a1)) }
                field(String(localized: "Raggio"), r, positive: true) { set(.arc(center: c, radius: $0, start: a0, end: a1)) }
                field(String(localized: "Angolo iniziale"), a0 * 180 / .pi, unit: "°") { set(.arc(center: c, radius: r, start: $0 * .pi / 180, end: a1)) }
                field(String(localized: "Angolo finale"), a1 * 180 / .pi, unit: "°") { set(.arc(center: c, radius: r, start: a0, end: $0 * .pi / 180)) }
            case let .point3D(p):
                field("X", p.x) { set(.point3D(position: Vec3($0, p.y, p.z))) }
                field("Y", p.y) { set(.point3D(position: Vec3(p.x, $0, p.z))) }
                field("Z", p.z) { set(.point3D(position: Vec3(p.x, p.y, $0))) }
            case let .line3D(a, b):
                field(String(localized: "Inizio X"), a.x) { set(.line3D(start: Vec3($0, a.y, a.z), end: b)) }
                field(String(localized: "Inizio Y"), a.y) { set(.line3D(start: Vec3(a.x, $0, a.z), end: b)) }
                field(String(localized: "Inizio Z"), a.z) { set(.line3D(start: Vec3(a.x, a.y, $0), end: b)) }
                field(String(localized: "Fine X"), b.x) { set(.line3D(start: a, end: Vec3($0, b.y, b.z))) }
                field(String(localized: "Fine Y"), b.y) { set(.line3D(start: a, end: Vec3(b.x, $0, b.z))) }
                field(String(localized: "Fine Z"), b.z) { set(.line3D(start: a, end: Vec3(b.x, b.y, $0))) }
            case let .workplane(o, x, p):
                // The three points in the sketch's frame: origin, a point along X, one in the plane.
                field(String(localized: "Origine X"), o.x) { set(.workplane(origin: Vec3($0, o.y, o.z), xAxisPoint: x, planePoint: p)) }
                field(String(localized: "Origine Y"), o.y) { set(.workplane(origin: Vec3(o.x, $0, o.z), xAxisPoint: x, planePoint: p)) }
                field(String(localized: "Origine Z"), o.z) { set(.workplane(origin: Vec3(o.x, o.y, $0), xAxisPoint: x, planePoint: p)) }
                field(String(localized: "Asse X (x)"), x.x) { set(.workplane(origin: o, xAxisPoint: Vec3($0, x.y, x.z), planePoint: p)) }
                field(String(localized: "Asse X (y)"), x.y) { set(.workplane(origin: o, xAxisPoint: Vec3(x.x, $0, x.z), planePoint: p)) }
                field(String(localized: "Asse X (z)"), x.z) { set(.workplane(origin: o, xAxisPoint: Vec3(x.x, x.y, $0), planePoint: p)) }
                field(String(localized: "Nel piano (x)"), p.x) { set(.workplane(origin: o, xAxisPoint: x, planePoint: Vec3($0, p.y, p.z))) }
                field(String(localized: "Nel piano (y)"), p.y) { set(.workplane(origin: o, xAxisPoint: x, planePoint: Vec3(p.x, $0, p.z))) }
                field(String(localized: "Nel piano (z)"), p.z) { set(.workplane(origin: o, xAxisPoint: x, planePoint: Vec3(p.x, p.y, $0))) }
                if let plane = shape.workplanePlane {
                    info(String(localized: "Normale"),
                         "\(fmt(plane.normal.x)), \(fmt(plane.normal.y)), \(fmt(plane.normal.z))")
                } else {
                    Text("I tre punti sono in linea: sposta il punto dell'asse X o quello nel piano.")
                        .font(.caption).foregroundStyle(.orange)
                }
                Button { sketch.setWorkplane(id) } label: {
                    Label("Imposta piano di lavoro", systemImage: "square.stack.3d.up")
                }
                .controlSize(.small)
                .disabled(shape.workplanePlane == nil)
                .help("Lo schizzo passa su questo piano: il 3D resta dov'è, il 2D si appoggia al nuovo piano")
            }
            if case .workplane = shape.kind {
                // A frame has no length: its normal is shown above.
            } else if shape.is3D {
                info(String(localized: "Lunghezza 3D"), "\(fmt(shape.length)) mm")
            } else {
                if shape.isClosed { info(String(localized: "Area"), "\(fmt(shape.area)) mm²") }
                info(shape.isClosed ? String(localized: "Perimetro") : String(localized: "Lunghezza"), "\(fmt(shape.length)) mm")
            }
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
        field(String(localized: "Inizio X"), p0.x) { set(.polyline(end(Vec2($0, p0.y), len, ang), closed: false)) }
        field(String(localized: "Inizio Y"), p0.y) { set(.polyline(end(Vec2(p0.x, $0), len, ang), closed: false)) }
        field(String(localized: "Lunghezza"), len, positive: true) { set(.polyline(end(p0, $0, ang), closed: false)) }
        field(String(localized: "Angolo"), ang * 180 / .pi, unit: "°") { set(.polyline(end(p0, len, $0 * .pi / 180), closed: false)) }
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

    private func label(_ s: String) -> some View { Text(LocalizedStringKey(s)).font(Theme.Typeface.body).foregroundStyle(Theme.Palette.textSecondary) }

    private func info(_ t: String, _ v: String) -> some View {
        HStack { label(t); Spacer(); Text(LocalizedStringKey(v)).font(Theme.Typeface.mono) }
    }
}

/// The entity type as shown to the user. CADCore's `typeName` is Italian source text; the app
/// localizes it here, where the catalog lives.
extension SketchShape {
    var localizedTypeName: String {
        switch kind {
        case let .polyline(p, closed):
            closed ? String(localized: "Profilo") : (p.count == 2 ? String(localized: "Linea") : String(localized: "Polilinea"))
        case .rectangle: String(localized: "Rettangolo")
        case .circle: String(localized: "Cerchio")
        case let .polygon(_, _, n, _, _): String(localized: "Poligono (\(n) lati)")
        case .slot: String(localized: "Asola")
        case .arc: String(localized: "Arco")
        case .spline: String(localized: "Spline")
        case .bezier: String(localized: "Curva di Bezier")
        case .point3D: String(localized: "Punto 3D")
        case .line3D: String(localized: "Linea 3D")
        case .workplane: String(localized: "Piano di lavoro")
        }
    }
}
