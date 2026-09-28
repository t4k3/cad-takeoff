import AppKit
import ElectronicsCore
import SwiftUI

// MARK: Colours

enum AssemblyLook {
    /// Semantic material → colour (the engine gives materials, the app chooses colours).
    static func colour(_ m: ManufacturingAssemblyMaterial) -> Color {
        switch m {
        case .substrate: Color(red: 0.55, green: 0.5, blue: 0.3)
        case .body: Color(red: 0.14, green: 0.14, blue: 0.15)
        case .ceramic: Color(red: 0.72, green: 0.6, blue: 0.42)
        case .metal: Color(red: 0.8, green: 0.8, blue: 0.82)
        case .polarity: Color(red: 0.88, green: 0.88, blue: 0.86)
        case .insulator: Color(red: 0.9, green: 0.84, blue: 0.68)
        }
    }

    static func quality(_ q: ManufacturingModelQuality, aligned: Bool) -> (symbol: String, colour: Color, text: String) {
        switch q {
        case .verified: ("checkmark.seal.fill", .green, "Modello verificato")
        case .approximate: (aligned ? "cube.fill" : "cube.transparent", .orange,
                            aligned ? "Modello approssimato, orientamento controllato" : "Modello approssimato, orientamento da controllare")
        case .missing: ("questionmark.square.dashed", .red, "Senza modello: solo il centro dalla CPL")
        }
    }
}

// MARK: Finished-board picture

/// One side of the board as it comes from the factory (green mask, gold openings, white
/// silkscreen, black holes) over the board's own top-face shape: the 2D assembled view draws
/// it, the 3D view puts it on the drilled substrate's faces.
@MainActor
enum BoardPicture {
    static func render(_ art: CAMDrawing, bounds: ManufacturingBounds, base: [SIMD3<Float>], side: BoardSide) -> CGImage? {
        let ppm = min(16, 4096 / max(bounds.width, bounds.height))
        let size = CGSize(width: (bounds.width * ppm).rounded(.up), height: (bounds.height * ppm).rounded(.up))
        let canvas = Canvas { ctx, _ in
            var board = ctx
            board.concatenate(CGAffineTransform(a: ppm, b: 0, c: 0, d: -ppm, tx: -bounds.minimum.x * ppm, ty: bounds.maximum.y * ppm))
            var shape = Path()
            var i = 0
            while i + 2 < base.count {
                shape.move(to: CGPoint(x: CGFloat(base[i].x), y: CGFloat(base[i].y)))
                shape.addLine(to: CGPoint(x: CGFloat(base[i + 1].x), y: CGFloat(base[i + 1].y)))
                shape.addLine(to: CGPoint(x: CGFloat(base[i + 2].x), y: CGFloat(base[i + 2].y)))
                shape.closeSubpath()
                i += 3
            }
            // No substrate from the engine (outline refused): the artwork alone, no invented board.
            board.fill(shape, with: .color(CAMDrawing.maskGreen))
            art.draw(&board, hidden: [], drills: true, palette: CAMDrawing.finished, order: CAMDrawing.finishedLayers(side))
        }
        .frame(width: size.width, height: size.height)
        let renderer = ImageRenderer(content: canvas)
        renderer.scale = 1
        return renderer.cgImage
    }
}

// MARK: 2D assembled view (drawn by CAMBoardView)

extension CAMBoardView {
    /// The finished board of one side and its components, from above; excluded ones faded (or
    /// hidden), models without a body as a dashed ring with «?», the component being aligned
    /// as the engine previews it.
    static func drawAssembly(_ ctx: inout GraphicsContext, _ m: CAMMapping, picture: CGImage?, bounds: ManufacturingBounds,
                             snapshot: ManufacturingAssemblySnapshot?, side: BoardSide, showExcluded: Bool,
                             selection: UUID?, hover: UUID?, draft: ManufacturingAssemblyInstance?) {
        if let picture {
            let a = m.screen(PCBPoint(bounds.minimum.x, bounds.maximum.y)), b = m.screen(PCBPoint(bounds.maximum.x, bounds.minimum.y))
            ctx.draw(Image(decorative: picture, scale: 1), in: CGRect(x: a.x, y: a.y, width: b.x - a.x, height: b.y - a.y))
        }
        guard let snapshot else { return }
        for original in snapshot.instances where original.side == side {
            let instance = draft?.id == original.id ? draft! : original
            guard instance.fitted || showExcluded, let centre = instance.position else { continue }
            let selected = selection == instance.id, lit = selected || hover == instance.id
            var layer = ctx
            layer.opacity = instance.fitted ? 1 : 0.3
            if instance.polygons.isEmpty {
                let q = m.screen(centre)
                let ring = Path(ellipseIn: CGRect(x: q.x - 5, y: q.y - 5, width: 10, height: 10))
                layer.stroke(ring, with: .color(.red), style: StrokeStyle(lineWidth: lit ? 2 : 1.2, dash: [2, 2]))
                layer.draw(Text("?").font(.system(size: 8, weight: .bold)).foregroundStyle(.red), at: q)
            } else {
                for polygon in instance.polygons {
                    var path = Path()
                    path.addLines(polygon.points.map(m.screen)); path.closeSubpath()
                    layer.fill(path, with: .color(AssemblyLook.colour(polygon.material)))
                    layer.stroke(path, with: .color(.black.opacity(0.6)), lineWidth: 0.5)
                }
            }
            if lit || draft?.id == instance.id {
                for polygon in instance.polygons {
                    var path = Path()
                    path.addLines(polygon.points.map(m.screen)); path.closeSubpath()
                    layer.stroke(path, with: .color(Theme.Palette.accent),
                                 style: StrokeStyle(lineWidth: 2, dash: draft?.id == instance.id ? [4, 3] : []))
                }
            }
            if let p1 = instance.pinOne {
                let q = m.screen(PCBPoint(p1.x, p1.y))
                layer.fill(Path(ellipseIn: CGRect(x: q.x - 1.8, y: q.y - 1.8, width: 3.6, height: 3.6)), with: .color(.red))
            }
            if lit || m.scale > 12 {
                let q = m.screen(centre)
                layer.draw(Text(instance.reference).font(.system(size: 9, weight: selected ? .bold : .regular)).foregroundStyle(.white),
                           at: CGPoint(x: q.x, y: q.y - 9))
            }
        }
    }
}

// MARK: Component detail (model and alignment)

/// The chosen component of the imported board: what it is, its model (automatic or chosen from
/// the catalog) and its alignment — offset and rotation tried with the engine's preview, then
/// OK (one undo step) or Annulla. Confirming the orientation does not certify the geometry.
struct AssemblyComponentDetail: View {
    @Environment(CircuitModel.self) private var circuits
    let component: ManufacturingComponent

    var body: some View {
        let saved = circuits.assemblyInstance(component.id)
        let draft = circuits.alignDraft?.componentID == component.id ? circuits.alignDraft : nil
        let binding = draft.map(\.binding) ?? component.modelBinding
        let shown = draft?.preview ?? saved
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(component.reference).font(.headline)
                Text([component.value, component.footprint].compactMap { $0 }.joined(separator: " · "))
                    .font(.caption).foregroundStyle(Theme.Palette.textSecondary).lineLimit(1)
            }
            if let shown {
                let q = AssemblyLook.quality(shown.quality, aligned: shown.alignmentVerified)
                Label(q.text, systemImage: q.symbol).font(.caption).foregroundStyle(q.colour)
                if let source = shown.modelSource { Text(source).font(.caption2).foregroundStyle(Theme.Palette.textSecondary).lineLimit(2) }
            }
            Menu(binding.flatMap { ManufacturingPackageCatalog.model(key: $0.modelKey)?.name } ?? "Automatico" + (ManufacturingPackageCatalog.suggestedModel(for: component).map { " (\($0.name))" } ?? " (nessuno)")) {
                Button("Automatico") { circuits.draftAlignment(component.id, nil) }
                Divider()
                ForEach(ManufacturingPackageCatalog.models, id: \.key) { model in
                    Button(model.name) {
                        var b = binding ?? ManufacturingModelBinding(modelKey: model.key)
                        b.modelKey = model.key; b.alignmentVerified = false
                        circuits.draftAlignment(component.id, b)
                    }
                }
            }
            .help("Modello del corpo: tutti quelli del catalogo sono approssimati")
            if let b = binding {
                axes("Spostamento (mm)", b.offset, step: 0.05) { var n = b; n.offset = $0; circuits.draftAlignment(component.id, n) }
                axes("Rotazione (°)", b.rotationDegrees, step: 90) { var n = b; n.rotationDegrees = $0; circuits.draftAlignment(component.id, n) }
                Toggle("Orientamento e pin 1 controllati", isOn: Binding(get: { b.alignmentVerified }, set: { var n = b; n.alignmentVerified = $0; circuits.draftAlignment(component.id, n) }))
                    .font(.caption)
                    .help("Dice che hai controllato orientamento e pin 1 sulla scheda; non rende esatto un modello approssimato")
            } else if saved?.modelKey != nil {
                Button("Regola allineamento…") {
                    if let key = saved?.modelKey { circuits.draftAlignment(component.id, ManufacturingModelBinding(modelKey: key)) }
                }
                .controlSize(.small)
            }
            if let draft {
                if let refused = draft.refused { Text(refused).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true) }
                else if draft.preview == nil { HStack { ProgressView().controlSize(.small); Text("Anteprima…").font(.caption) } }
                HStack {
                    Spacer()
                    Button("Annulla") { circuits.cancelAlignment() }
                    Button("OK") { circuits.confirmAlignment() }.keyboardShortcut(.defaultAction)
                        .disabled(draft.refused != nil || draft.preview == nil)
                }
                .controlSize(.small)
            }
        }
        .padding(8)
        .background(Theme.Palette.canvas.opacity(0.6), in: RoundedRectangle(cornerRadius: 6))
    }

    private func axes(_ title: String, _ v: PCBPoint3, step: Double, _ set: @escaping @MainActor (PCBPoint3) -> Void) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption2).foregroundStyle(Theme.Palette.textSecondary)
            HStack(spacing: 4) {
                field("X", v.x, step) { set(PCBPoint3($0, v.y, v.z)) }
                field("Y", v.y, step) { set(PCBPoint3(v.x, $0, v.z)) }
                field("Z", v.z, step) { set(PCBPoint3(v.x, v.y, $0)) }
            }
        }
    }

    private func field(_ axis: String, _ value: Double, _ step: Double, _ set: @escaping @MainActor (Double) -> Void) -> some View {
        HStack(spacing: 2) {
            Text(axis).font(.caption2)
            TextField(axis, value: Binding(get: { value }, set: set), format: .number.precision(.fractionLength(0...3)))
                .textFieldStyle(.roundedBorder).frame(width: 52).font(.caption)
            Stepper("", value: Binding(get: { value }, set: set), step: step).labelsHidden().controlSize(.mini)
        }
    }
}

/// Board thickness: the engine's estimate until the real one is given.
struct BoardThicknessRow: View {
    @Environment(CircuitModel.self) private var circuits
    @State private var text = ""

    var body: some View {
        let set = circuits.manufacturing?.assemblySettings?.boardThickness
        HStack(spacing: 6) {
            Text("Spessore").font(.caption)
            TextField("1,6", text: $text).textFieldStyle(.roundedBorder).frame(width: 56).font(.caption)
                .onSubmit(apply)
            Text("mm").font(.caption)
            if set == nil { Text("stimato").font(.caption2).foregroundStyle(.orange) }
            else { Button("Stima") { circuits.setBoardThickness(nil) }.controlSize(.mini).help("Torna alla stima dichiarata di 1,6 mm") }
        }
        .onAppear { text = set.map { $0.formatted(.number.precision(.fractionLength(0...3))) } ?? "" }
        .onChange(of: set) { _, v in text = v.map { $0.formatted(.number.precision(.fractionLength(0...3))) } ?? "" }
        .help("Spessore della scheda finita (i Gerber non lo dicono): Invio per applicarlo, un passo di Annulla")
    }

    private func apply() {
        let t = text.replacingOccurrences(of: ",", with: ".").trimmingCharacters(in: .whitespaces)
        if t.isEmpty { circuits.setBoardThickness(nil); return }
        guard let v = Double(t), v > 0 else { return }
        circuits.setBoardThickness(v)
    }
}
