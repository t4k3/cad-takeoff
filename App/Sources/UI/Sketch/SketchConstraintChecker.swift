import CADCore
import SwiftUI

/// SolidWorks-style relations inspector for the sketch being edited: every entity with the
/// constraints acting on it, each relation's diagnostic state, and the freedom left per entity.
/// Clicking a row selects the constraint (and its first entity) in the viewport; the bin deletes it.
struct SketchConstraintChecker: View {
    let sketch: SketchSession
    @Environment(\.dismiss) private var dismiss
    /// Only the entities that are under-defined or carry a problem relation.
    @State private var onlyProblems = false

    var body: some View {
        let annotations = sketch.annotations()
        VStack(spacing: 0) {
            header.padding(14)
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(groups) { group in
                        groupView(group, annotations: annotations)
                    }
                }
                .padding(12)
            }
            Divider()
            footer.padding(12)
        }
        .frame(width: 540, height: 600)
    }

    // MARK: Header

    private var conflicting: Int { sketch.conflictingConstraints.count }
    private var redundant: Int { sketch.redundantConstraints.count }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: statusIcon).font(.system(size: 22, weight: .semibold)).foregroundStyle(statusColor)
            VStack(alignment: .leading, spacing: 2) {
                Text(statusTitle).font(.system(size: 14, weight: .semibold))
                Text(statusDetail).font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Spacer()
            Toggle("Solo problemi", isOn: $onlyProblems).toggleStyle(.switch).controlSize(.small)
        }
    }

    private var statusIcon: String {
        if conflicting > 0 { return "exclamationmark.triangle.fill" }
        if redundant > 0 { return "exclamationmark.circle.fill" }
        if sketch.freedom == 0 && !sketch.sketch.constraints.isEmpty { return "checkmark.seal.fill" }
        return "ruler.fill"
    }

    private var statusColor: Color {
        if conflicting > 0 { return .red }
        if redundant > 0 { return .orange }
        if sketch.freedom == 0 && !sketch.sketch.constraints.isEmpty { return .green }
        return Theme.Palette.sketch
    }

    private var statusTitle: String {
        if conflicting > 0 {
            return conflicting == 1 ? String(localized: "1 vincolo in conflitto") : String(localized: "\(conflicting) vincoli in conflitto")
        }
        if redundant > 0 {
            return redundant == 1 ? String(localized: "1 vincolo ridondante") : String(localized: "\(redundant) vincoli ridondanti")
        }
        if sketch.sketch.constraints.isEmpty { return String(localized: "Nessun vincolo") }
        if sketch.freedom == 0 { return String(localized: "Schizzo completamente definito") }
        return sketch.freedom == 1 ? String(localized: "1 grado libero") : String(localized: "\(sketch.freedom) gradi liberi")
    }

    private var statusDetail: String {
        let count = sketch.shapes.filter { (sketch.freedomPerShape[$0.id] ?? 0) > 0 }.count
        let free = count == 1 ? String(localized: "1 entità non definita") : String(localized: "\(count) entità non definite")
        return String(localized: "\(free) su \(sketch.shapes.count) · \(sketch.sketch.constraints.count) vincoli")
    }

    // MARK: Groups (one per entity, as SolidWorks lists relations per entity)

    private struct Group: Identifiable {
        let id: String
        let title: String
        /// Directions the entity can still move in; nil for the origin and the axes.
        let dof: Int?
        /// How many lines/arcs the entity is made of (a rectangle is four pickable sides).
        let note: String?
        /// Relations the shape's own definition already guarantees (a rectangle is square).
        let implicit: String?
        let constraints: [SketchConstraint]
    }

    private var groups: [Group] {
        var byShape: [UUID: [SketchConstraint]] = [:]
        var fixed: [SketchConstraint] = []
        for c in sketch.sketch.constraints {
            if let id = primaryShape(c) { byShape[id, default: []].append(c) } else { fixed.append(c) }
        }
        var out: [Group] = []
        for s in sketch.shapes {
            let cs = byShape[s.id] ?? []
            let dof = sketch.freedomPerShape[s.id] ?? 0
            if onlyProblems, dof == 0, cs.allSatisfy({ !isProblem($0) }) { continue }
            out.append(Group(id: s.id.uuidString, title: entityName(s), dof: dof, note: sideNote(s),
                             implicit: implicitNote(s), constraints: ordered(cs)))
        }
        if !fixed.isEmpty {
            out.append(Group(id: "fixed", title: String(localized: "Origine e assi"), dof: nil, note: nil,
                             implicit: nil, constraints: ordered(fixed)))
        }
        return out
    }

    /// Rectangles and polygons are one entity but several pickable lines, as in SolidWorks.
    private func sideNote(_ s: SketchShape) -> String? {
        switch s.kind {
        case .rectangle: String(localized: "4 lati selezionabili")
        case let .polygon(_, _, n, _, _): String(localized: "\(n) lati selezionabili")
        case .slot: String(localized: "2 lati + 2 archi")
        default: nil
        }
    }

    /// What the shape already guarantees on its own (dune3d builds these as explicit constraints;
    /// here they come from the entity, which is why adding them again is refused as redundant).
    private func implicitNote(_ s: SketchShape) -> String? {
        switch s.kind {
        case .rectangle:
            String(localized: "Impliciti: lati orizzontali e verticali · opposti paralleli e uguali · adiacenti perpendicolari")
        case .polygon:
            String(localized: "Impliciti: lati e angoli uguali (regolare) · vertici sulla stessa circonferenza")
        case .slot:
            String(localized: "Impliciti: 2 lati paralleli e uguali · 2 archi dello stesso raggio, tangenti ai lati")
        case .circle:
            String(localized: "Implicito: raggio costante, curva chiusa")
        case .arc:
            String(localized: "Implicito: raggio costante")
        case let .polyline(_, closed):
            closed ? String(localized: "Implicito: contorno chiuso") : nil
        case .spline:
            nil
        case .bezier:
            String(localized: "Implicito: curva cubica con 4 punti di controllo")
        case .point3D, .line3D, .workplane:
            nil
        }
    }

    private func primaryShape(_ c: SketchConstraint) -> UUID? {
        for r in c.kind.refs where !r.isFixedGeometry {
            if sketch.shape(r.shapeID) != nil { return r.shapeID }
        }
        return nil
    }

    private func isProblem(_ c: SketchConstraint) -> Bool {
        sketch.conflictingConstraints.contains(c.id) || sketch.redundantConstraints.contains(c.id)
    }

    private func ordered(_ cs: [SketchConstraint]) -> [SketchConstraint] {
        func severity(_ c: SketchConstraint) -> Int {
            if sketch.conflictingConstraints.contains(c.id) { return 0 }
            if sketch.redundantConstraints.contains(c.id) { return 1 }
            return c.isReference ? 3 : 2
        }
        return cs.sorted { a, b in
            severity(a) == severity(b) ? a.kind.label < b.kind.label : severity(a) < severity(b)
        }
    }

    // MARK: Rows

    private func groupView(_ g: Group, annotations: [SketchSession.Annotation]) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(g.title).font(.system(size: 12, weight: .semibold))
                if let dof = g.dof { dofBadge(dof) }
                if let note = g.note {
                    Text(note).font(.system(size: 10)).foregroundStyle(.secondary)
                }
                Spacer()
            }
            if let implicit = g.implicit {
                HStack(spacing: 4) {
                    Image(systemName: "lock.fill").font(.system(size: 8.5)).foregroundStyle(.tertiary)
                    Text(implicit).font(.system(size: 10)).foregroundStyle(.secondary)
                }
                .padding(.leading, 22).padding(.top, 1)
            }
            if g.constraints.isEmpty {
                Text(g.implicit == nil ? String(localized: "Nessun vincolo") : String(localized: "Nessun vincolo esplicito"))
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .padding(.leading, 22)
            } else {
                ForEach(g.constraints) { c in
                    row(c, annotations: annotations)
                }
            }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.05)))
    }

    private func dofBadge(_ dof: Int) -> some View {
        Text(dof == 0 ? String(localized: "vincolata") : (dof == 1 ? String(localized: "1 grado libero") : String(localized: "\(dof) gradi liberi")))
            .font(.system(size: 10, weight: .semibold).monospacedDigit())
            .padding(.horizontal, 5).padding(.vertical, 1)
            .background(Capsule().fill(dof == 0 ? Color.green.opacity(0.16) : Color.accentColor.opacity(0.14)))
            .foregroundStyle(dof == 0 ? Color.green : Color.accentColor)
    }

    private func row(_ c: SketchConstraint, annotations: [SketchSession.Annotation]) -> some View {
        let selected = sketch.selectedConstraint == c.id
        return HStack(spacing: 8) {
            Image(systemName: symbol(for: c.kind)).font(.system(size: 11)).frame(width: 17)
                .foregroundStyle(statusColor(c))
            VStack(alignment: .leading, spacing: 1) {
                Text(text(c, annotations: annotations)).font(.system(size: 11.5, weight: .medium))
                Text(subjects(c)).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 4)
            if let badge = badge(c) {
                Text(badge.0).font(.system(size: 9.5, weight: .semibold))
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background(Capsule().fill(badge.1.opacity(0.18)))
                    .foregroundStyle(badge.1)
            }
            Button { delete(c) } label: { Image(systemName: "trash").font(.system(size: 10.5)) }
                .buttonStyle(.borderless)
                .help("Elimina il vincolo")
        }
        .padding(.horizontal, 6).padding(.vertical, 3)
        .background(RoundedRectangle(cornerRadius: 5).fill(selected ? Theme.Palette.sketch.opacity(0.22) : statusBackground(c)))
        .contentShape(Rectangle())
        .onTapGesture { sketch.selectedConstraint = c.id }
        .help(subjects(c))
    }

    private func statusBackground(_ c: SketchConstraint) -> Color {
        if sketch.conflictingConstraints.contains(c.id) { return Color.red.opacity(0.10) }
        if sketch.redundantConstraints.contains(c.id) { return Color.orange.opacity(0.10) }
        return .clear
    }

    private func statusColor(_ c: SketchConstraint) -> Color {
        if sketch.conflictingConstraints.contains(c.id) { return .red }
        if sketch.redundantConstraints.contains(c.id) { return .orange }
        if sketch.blockingConstraints.contains(c.id) { return .yellow }
        return c.isReference ? .gray : Theme.Palette.sketch
    }

    private func badge(_ c: SketchConstraint) -> (String, Color)? {
        if sketch.conflictingConstraints.contains(c.id) { return (String(localized: "In conflitto"), .red) }
        if sketch.redundantConstraints.contains(c.id) { return (String(localized: "Ridondante"), .orange) }
        if sketch.blockingConstraints.contains(c.id) { return (String(localized: "Bloccante"), .yellow) }
        if c.isReference { return (String(localized: "Riferimento"), .gray) }
        return nil
    }

    private func text(_ c: SketchConstraint, annotations: [SketchSession.Annotation]) -> String {
        annotations.first { $0.id == c.id }?.text ?? c.kind.label
    }

    private func subjects(_ c: SketchConstraint) -> String {
        c.kind.refs.map(refName).joined(separator: " ↔ ")
    }

    // MARK: Entity and reference names

    private func kindKey(_ s: SketchShape) -> String {
        switch s.kind {
        case let .polyline(_, closed): closed ? "profile" : "line"
        case .rectangle: "rectangle"
        case .circle: "circle"
        case .polygon: "polygon"
        case .slot: "slot"
        case .arc: "arc"
        case .spline: "spline"
        case .bezier: "bezier"
        case .point3D: "point3d"
        case .line3D: "line3d"
        case .workplane: "workplane"
        }
    }

    private func entityName(_ s: SketchShape) -> String {
        let base: String = switch s.kind {
        case let .polyline(p, closed): closed ? String(localized: "Profilo") : (p.count == 2 ? String(localized: "Linea") : String(localized: "Polilinea"))
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
        let same = sketch.shapes.filter { kindKey($0) == kindKey(s) }
        let n = (same.firstIndex { $0.id == s.id } ?? 0) + 1
        return "\(base) \(n)"
    }

    private func refName(_ r: SketchRef) -> String {
        switch r {
        case .origin: return String(localized: "Origine")
        case .axisX: return String(localized: "Asse X")
        case .axisY: return String(localized: "Asse Y")
        case let .point(id, i):
            guard let s = sketch.shape(id) else { return String(localized: "Punto") }
            if case let .polyline(p, _) = s.kind, p.count == 1 { return entityName(s) }
            if case .circle = s.kind { return String(localized: "Centro · \(entityName(s))") }
            if case .arc = s.kind, i == 0 { return String(localized: "Centro · \(entityName(s))") }
            return String(localized: "Punto \(i + 1) · \(entityName(s))")
        case let .segment(id, i):
            guard let s = sketch.shape(id) else { return String(localized: "Linea") }
            return String(localized: "Lato \(i + 1) · \(entityName(s))")
        case let .circle(id, _):
            guard let s = sketch.shape(id) else { return String(localized: "Cerchio") }
            return entityName(s)
        }
    }

    // MARK: Actions

    private func delete(_ c: SketchConstraint) {
        sketch.sketch.constraints.removeAll { $0.id == c.id }
        if sketch.selectedConstraint == c.id { sketch.selectedConstraint = nil }
    }

    // MARK: Footer

    private var footer: some View {
        HStack {
            Text("\(sketch.sketch.constraints.count) vincoli · \(sketch.shapes.count) entità")
                .font(.system(size: 11)).foregroundStyle(.secondary)
            Spacer()
            Button { sketch.deleteSelection() } label: { Label("Elimina", systemImage: "trash") }
                .disabled(sketch.selectedConstraint == nil)
            Button("Chiudi") { dismiss() }.keyboardShortcut(.cancelAction)
        }
    }

    private func symbol(for k: SketchConstraintKind) -> String {
        switch k {
        case .coincident: "smallcircle.filled.circle"
        case .horizontal, .vertical: "arrow.up.and.down.and.arrow.left.and.right"
        case .parallel, .smooth: "equal"
        case .perpendicular: "angle"
        case .colinear: "align.horizontal.left"
        case .tangent: "circle.and.line.horizontal"
        case .equal: "equal.square"
        case .concentric: "circle.circle"
        case .midpoint: "circle.bottomhalf.filled"
        case .symmetric: "arrow.left.and.line.vertical.and.arrow.right"
        case .fix, .fix3D: "lock"
        case .pointOnLine, .pointOnCircle, .pointOnArc, .pointOnBezier, .pointOnPlane: "smallcircle.filled.circle"
        case .bezierLineTangent: "circle.and.line.horizontal"
        case .bezierLinePerpendicular: "angle"
        case .normalToPlane: "arrow.up.and.down.and.arrow.left.and.right"
        case .lockRotation: "lock.rotation"
        case .distance, .horizontalDistance, .verticalDistance, .planeDistance, .offset, .length: "ruler"
        case .radius, .diameter: "circle.dashed"
        case .angle: "angle"
        }
    }
}
