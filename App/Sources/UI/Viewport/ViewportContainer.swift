import CADCore
import Observation
import SwiftUI
import simd

/// UI state of the 3D view that must survive SwiftUI updates.
@MainActor
@Observable
final class ViewportState {
    let camera = CameraController()
    var style: ViewportRenderer.DisplayStyle = .shadedEdges
    @ObservationIgnored weak var renderer: ViewportRenderer?
    @ObservationIgnored private var didInitialFit = false
    @ObservationIgnored private var projectionBeforeSketch: CameraController.Projection?
    var viewSize: CGSize = .zero

    /// Sketch mode camera: animate to the top view, orthographic; restore on exit.
    func applySketchCamera(_ entering: Bool, plane: SketchPlane = .xy, focus: Vec3? = nil) {
        if entering {
            projectionBeforeSketch = camera.projection
            camera.projection = .orthographic
            if plane.isXY { camera.show(.top, bounds: nil) } else { camera.look(at: plane, target: focus) }
        } else {
            camera.projection = projectionBeforeSketch ?? .perspective
            camera.show(.home, bounds: renderer?.sceneBounds)
        }
        redraw()
    }

    /// Millimetres per screen point at the orbit target (for snap radii).
    var mmPerPoint: Double {
        let h = max(Double(viewSize.height), 1)
        return 2 * Double(camera.pose.distance) * tan(Double(camera.fovY) / 2) / h
    }

    /// Set by the Metal view: restarts the render loop so camera animations play.
    @ObservationIgnored var redraw: () -> Void = {}

    func home() { camera.show(.home, bounds: renderer?.sceneBounds); redraw() }
    func fit() { camera.fit(renderer?.sceneBounds); redraw() }

    // MARK: Faces and edges (stable kernel IDs, T76)

    /// While a command preview replaces the geometry on screen, picking and highlights keep
    /// using the real design (the edges being chamfered stay clickable).
    @ObservationIgnored private var reference: (revision: String, bodies: [Feature.ID: ViewportRenderer.Body])?

    func setReference(_ snapshot: DesignSnapshot?, features: [Feature]) {
        guard let snapshot else { reference = nil; return }
        guard reference?.revision != snapshot.revision else { return }
        var map: [Feature.ID: ViewportRenderer.Body] = [:]
        for b in snapshot.bodies {
            guard let f = features.first(where: { $0.id == b.bodyID }), var lo = b.positions.first else { continue }
            var hi = lo
            for p in b.positions {
                lo = Vec3(min(lo.x, p.x), min(lo.y, p.y), min(lo.z, p.z)); hi = Vec3(max(hi.x, p.x), max(hi.y, p.y), max(hi.z, p.z))
            }
            map[f.id] = ViewportRenderer.Body(feature: f, snapshot: b, triangles: nil, triangleVertexCount: 0,
                                             edges: nil, edgeVertexCount: 0, bounds: BoundingBox(min: lo, max: hi))
        }
        reference = (snapshot.revision, map)
    }

    var pickableBodies: [ViewportRenderer.Body] {
        reference.map { Array($0.bodies.values) } ?? renderer?.visibleBodies ?? []
    }

    /// Screen point (points, top-left origin) of a world position; nil when behind the camera.
    func screenPoint(_ p: Vec3) -> CGPoint? {
        let size = viewSize
        guard size.width > 0, size.height > 0 else { return nil }
        let proj: simd_float4x4 = camera.projectionMatrix(aspect: Float(size.width / size.height))
        let m: simd_float4x4 = simd_mul(proj, camera.viewMatrix)
        let c: SIMD4<Float> = simd_mul(m, SIMD4<Float>(Float(p.x), Float(p.y), Float(p.z), 1))
        guard c.w > 1e-6 else { return nil }
        let x = Double((c.x / c.w + 1) / 2), y = Double((1 - c.y / c.w) / 2)
        return CGPoint(x: x * size.width, y: y * size.height)
    }

    func pickGeo(_ ray: Ray, filter: SelectionFilter) -> GeoRef? {
        let bodies = pickableBodies
        guard !bodies.isEmpty else { return nil }
        switch filter {
        case .body: return nil
        case .face: return GeoPicking.face(ray, bodies: bodies)
        case .edge:
            // ~7 screen points at the hit distance.
            let h = Float(max(viewSize.height, 1)), tanHalf = tan(camera.fovY / 2)
            return GeoPicking.edge(ray, bodies: bodies) { [camera] d in
                let depth = camera.projection == .perspective ? max(d, 1) : camera.pose.distance
                return 7 * 2 * depth * tanHalf / h
            }
        }
    }

    /// Millimetres covered by `points` on screen at distance `d` along a pick ray.
    func screenTolerance(_ points: Double) -> (Double) -> Double {
        let h = Double(max(viewSize.height, 1)), tanHalf = Double(tan(camera.fovY / 2))
        let perspective = camera.projection == .perspective, orbit = Double(camera.pose.distance)
        return { d in points * 2 * (perspective ? max(d, 1) : orbit) * tanHalf / h }
    }

    func body(_ id: Feature.ID) -> ViewportRenderer.Body? { reference?.bodies[id] ?? renderer?.bodies[id] }

    func pick(_ ray: Ray) -> Feature.ID? {
        guard let renderer else { return nil }
        return Picking.pick(ray, in: renderer.visibleBodies)?.featureID
    }

    func fitOnce() {
        guard !didInitialFit, renderer?.sceneBounds != nil else { return }
        didInitialFit = true
        home()
    }
}

/// Viewport with its overlays: navigation bar (bottom) and hint.
struct ViewportContainer: View {
    @Environment(DesignModel.self) private var model
    @Environment(WorkspaceState.self) private var workspace
    @Environment(SketchStore.self) private var sketchStore
    @Bindable var viewport: ViewportState

    /// Viewport and its first overlays (split from `body` to keep type-checking fast).
    private var canvas: some View {
        ZStack {
            LinearGradient(colors: [Color(white: 0.30), Color(white: 0.17)], startPoint: .top, endPoint: .bottom)
                .overlay(Theme.Palette.canvas.opacity(0.0))
            metal
        }
        .background(GeometryReader { g in Color.clear.onAppear { viewport.viewSize = g.size }.onChange(of: g.size) { _, s in viewport.viewSize = s } })
        .overlay(alignment: .topLeading) { sketchHUD }
        .overlay(alignment: .bottomLeading) { measureChip.padding(12) }
        .overlay(alignment: .topLeading) { manipulatorLabel }
        .onChange(of: workspace.previewSnapshot?.revision) { _, revision in
            viewport.setReference(revision == nil ? nil : model.snapshot(), features: model.document.activeFeatures)
        }
    }

    var body: some View {
        canvas
        .overlay(alignment: .top) { sketchBanner }
        .background { sketchKeys }
        .onChange(of: workspace.sketchCameraRequest) { _, request in
            guard let request else { return }
            viewport.applySketchCamera(request, plane: workspace.sketch?.sketch.plane ?? .xy, focus: workspace.sketchFocus)
            workspace.sketchCameraRequest = nil
        }
        .overlay(alignment: .bottom) { navigationBar.padding(.bottom, 12) }
        .overlay(alignment: .topTrailing) {
            ViewCube(camera: viewport.camera) { view in
                viewport.camera.show(view, bounds: viewport.renderer?.sceneBounds)
                viewport.renderer.map { _ in viewport.redraw() }
            }
            .padding(8)
        }
        .overlay(alignment: .topLeading) {
            if let session = workspace.command {
                CommandPanel(session: session) { workspace.command = nil }
                    .padding(12)
                    .transition(.move(edge: .leading).combined(with: .opacity))
                    .id(session.id)
            } else if workspace.sketch == nil {
            Text("Trascina: orbita · ⇧ trascina / due dita: sposta · rotella / pizzica: zoom")
                .font(.system(size: 10.5)).foregroundStyle(.white.opacity(0.55))
                .padding(12)
            }
        }
        .animation(.easeOut(duration: 0.18), value: workspace.command?.id)
        .clipped()
    }

    private var metal: some View {
    MetalViewport(features: workspace.previewSnapshot == nil ? model.document.activeFeatures : workspace.previewFeatures,
                  snapshot: displayedSnapshot,
                  // In face/edge mode only the picked face/edge is highlighted, not the whole body.
                  selection: workspace.selectionFilter == .body ? model.selection : nil,
                  hovered: workspace.hovered, style: viewport.style, camera: viewport.camera,
                  overlayLines: sketchLines,
                  highlightTriangles: geoHighlight.triangles,
                  highlightLines: geoHighlight.lines,
                  gizmos: workspace.manipulator.map { [$0.mesh(length: arrowLength)] } ?? [],
                  onClick: handleClick,
                  onHover: handleHover,
                  onDragBegin: dragBegin,
                  onDragMove: { ray in workspace.manipulator?.drag(ray) },
                  onDragEnd: { workspace.manipulator?.endDrag() },
                  onKey: handleKey,
                  onReady: { renderer in
                      viewport.renderer = renderer
                      viewport.redraw = { [weak renderer] in renderer?.requestRedraw() }
                      DispatchQueue.main.async { viewport.fitOnce() }
                  })
    }

    /// Command preview, flat patterns (LAMIERA › Sviluppo) or the design.
    private var displayedSnapshot: DesignSnapshot {
        if let preview = workspace.previewSnapshot { return preview }
        if workspace.showFlat, model.hasSheetMetal { return model.flatView().snapshot }
        return model.snapshot()
    }

    /// Bend lines on the flat patterns: red = up, blue = down; tangents faint.
    private var flatLines: [(SIMD3<Float>, SIMD3<Float>, SIMD4<Float>)] {
        guard workspace.showFlat, workspace.previewSnapshot == nil, model.hasSheetMetal else { return [] }
        func f(_ v: Vec3) -> SIMD3<Float> { SIMD3(Float(v.x), Float(v.y), Float(v.z)) }
        return model.flatView().bends.map { a, b, direction, centre in
            let c: SIMD4<Float> = direction == .up ? SIMD4(0.95, 0.3, 0.25, 1) : SIMD4(0.25, 0.55, 1, 1)
            return (f(a), f(b), centre ? c : c * SIMD4(1, 1, 1, 0.45))
        }
    }

    // MARK: Viewport input

    private func handleClick(_ point: CGPoint, _ ray: Ray, _ mods: NSEvent.ModifierFlags) {
        if workspace.pickingSketchPlane {
            pickSketchPlane(ray)
            return
        }
        if let sketch = workspace.sketch {
            guard workspace.command == nil, let p = sketch.intersect(ray) else { return }
            sketch.vertexSnap = 8 * viewport.mmPerPoint
            sketch.click(p)
            return
        }
        if let placement = workspace.holePlacement, let bodies = viewport.renderer?.visibleBodies {
            if let msg = placement.click(ray, bodies: bodies, tolerance: viewport.screenTolerance(12)), !msg.isEmpty { model.statusMessage = msg }
            return
        }
        if workspace.selectionFilter != .body {
            let multi = workspace.edgePicking || !mods.isDisjoint(with: [.shift, .command])
            if let ref = viewport.pickGeo(ray, filter: workspace.selectionFilter) {
                model.selection = ref.feature
                if multi {
                    if let i = workspace.geoSelection.firstIndex(of: ref) { workspace.geoSelection.remove(at: i) }
                    else { workspace.geoSelection.append(ref) }
                } else { workspace.geoSelection = [ref] }
            } else if !multi {
                workspace.geoSelection = []
                model.selection = nil
            }
            return
        }
        // Click selects the body under the cursor; empty space clears the selection.
        // TODO(R1): model.select(_:) when Codex ships it.
        model.selection = viewport.pick(ray)
    }

    /// «Schizzo»: a click on a planar face sketches on it; in empty space, on the XY plane.
    private func pickSketchPlane(_ ray: Ray) {
        let bodies = viewport.renderer?.visibleBodies ?? []
        guard let hit = Picking.pick(ray, in: bodies),
              let face = bodies.first(where: { $0.feature.id == hit.featureID })?.face(ofTriangle: hit.triangle) else {
            workspace.enterSketch(); return
        }
        guard case let .plane(origin, normal) = face.surface else {
            model.statusMessage = "Lo schizzo va su una faccia piana: scegli un'altra faccia."
            workspace.pickingSketchPlane = true
            return
        }
        let p = Vec3(Double(hit.point.x), Double(hit.point.y), Double(hit.point.z))
        workspace.enterSketch(plane: SketchPlane.onFace(point: origin, normal: normal), focus: p)
    }

    private func dragBegin(_ ray: Ray) -> Bool {
        guard let m = workspace.manipulator,
              m.hits(ray, length: arrowLength, tolerance: viewport.screenTolerance(10)) else { return false }
        m.beginDrag(ray, viewDirection: viewport.camera.forward)
        return true
    }

    private func handleHover(_ point: CGPoint?, _ ray: Ray?) {
        if let m = workspace.manipulator {
            let hot = ray.map { m.hits($0, length: arrowLength, tolerance: viewport.screenTolerance(10)) } ?? false
            if m.isHot != hot { m.isHot = hot }
        }
        if let sketch = workspace.sketch {
            sketch.vertexSnap = 8 * viewport.mmPerPoint
            sketch.hover(ray.flatMap { sketch.intersect($0) }, screen: point)
            return
        }
        if let placement = workspace.holePlacement {
            placement.hover(ray, bodies: viewport.renderer?.visibleBodies ?? [], tolerance: viewport.screenTolerance(12))
            return
        }
        if workspace.selectionFilter != .body {
            let ref = ray.flatMap { viewport.pickGeo($0, filter: workspace.selectionFilter) }
            if workspace.geoHover != ref { workspace.geoHover = ref }
            if workspace.hovered != nil { workspace.hovered = nil }
            return
        }
        let id = ray.flatMap { viewport.pick($0) }
        if workspace.hovered != id { workspace.hovered = id }
    }

    private func handleKey(_ key: String) -> Bool {
        if let sketch = workspace.sketch, workspace.command == nil {
            if let tool = SketchSession.Tool.allCases.first(where: { $0.key == key }) {
                sketch.tool = tool; return true
            }
            if key == "e" { workspace.extrudeSketch(model: model); return true }
        }
        if key == "f" { viewport.fit(); return true }
        return false
    }

    // MARK: Drag arrow

    /// Arrow length: about 70 points on screen.
    private var arrowLength: Double { 70 * viewport.mmPerPoint }

    /// Value next to the arrow tip, like Fusion's on-canvas input.
    @ViewBuilder private var manipulatorLabel: some View {
        if let m = workspace.manipulator, let p = viewport.screenPoint(m.handle - m.inward * arrowLength) {
            let active = m.isDragging || m.isHot
            HStack(spacing: 4) {
                Text(m.label).font(.system(size: 10, weight: .bold)).opacity(0.8)
                Text(String(format: "%.1f", m.value)).font(.system(size: 12, weight: .semibold).monospacedDigit())
                Text("mm").font(.system(size: 10, weight: .medium)).opacity(0.8)
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 9).padding(.vertical, 4)
            .background(Capsule().fill(active ? Color(red: 1, green: 0.6, blue: 0.12) : Color(red: 0.16, green: 0.52, blue: 1)))
            .overlay(Capsule().strokeBorder(.white.opacity(0.35), lineWidth: 1))
            .shadow(color: .black.opacity(0.35), radius: 4, y: 2)
            .fixedSize()
            .offset(x: p.x + 12, y: p.y - 14)
            .allowsHitTesting(false)
            .animation(.easeOut(duration: 0.12), value: active)
        }
    }

    // MARK: Face / edge highlight and measurements

    private var geoHighlight: (triangles: [(SIMD3<Float>, SIMD3<Float>, SIMD3<Float>, SIMD4<Float>)],
                               lines: [(SIMD3<Float>, SIMD3<Float>, SIMD4<Float>)]) {
        var tris: [(SIMD3<Float>, SIMD3<Float>, SIMD3<Float>, SIMD4<Float>)] = []
        var lines: [(SIMD3<Float>, SIMD3<Float>, SIMD4<Float>)] = []
        func f(_ v: Vec3) -> SIMD3<Float> { SIMD3(Float(v.x), Float(v.y), Float(v.z)) }
        func add(_ ref: GeoRef, selected: Bool) {
            guard let body = viewport.body(ref.feature) else { return }
            let accent = Theme.Palette.bodySelected
            switch ref.kind {
            case let .face(id):
                let c = SIMD4(accent, selected ? 0.45 : 0.22)
                for t in body.triangles(of: id) {
                    let (a, b, cc) = body.triangle(t)
                    tris.append((f(a), f(b), f(cc), c))
                }
            case let .edge(id):
                guard let e = body.edge(id) else { return }
                let c = selected ? SIMD4(accent, 1) : SIMD4(accent * 0.7 + 0.3, 0.9)
                for (a, b) in zip(e.polyline, e.polyline.dropFirst()) { lines.append((f(a), f(b), c)) }
            }
        }
        for ref in workspace.geoSelection { add(ref, selected: true) }
        if let h = workspace.geoHover, !workspace.geoSelection.contains(h) { add(h, selected: false) }
        return (tris, lines)
    }

    /// Measurements of the face/edge selection, from the kernel's exact descriptions.
    @ViewBuilder private var measureChip: some View {
        if workspace.sketch == nil, !workspace.geoSelection.isEmpty {
            let faces = workspace.geoSelection.compactMap { ref -> FaceInfo? in
                if case let .face(id) = ref.kind { viewport.body(ref.feature)?.face(id) } else { nil }
            }
            let edges = workspace.geoSelection.compactMap { ref -> EdgeInfo? in
                if case let .edge(id) = ref.kind { viewport.body(ref.feature)?.edge(id) } else { nil }
            }
            VStack(alignment: .leading, spacing: 3) {
                if faces.count == 1, let face = faces.first {
                    switch face.surface {
                    case let .plane(_, n):
                        Text("Faccia piana").font(.system(size: 11, weight: .semibold))
                        Text("Area \(fmt(face.area)) mm²")
                        Text("Normale \(fmt(n.x)) · \(fmt(n.y)) · \(fmt(n.z))")
                    case let .cone(_, _, half):
                        Text("Faccia conica (svasatura)").font(.system(size: 11, weight: .semibold))
                        Text("Angolo \(fmt(2 * half * 180 / .pi))°")
                        Text("Area \(fmt(face.area)) mm²")
                    case .freeform:
                        Text("Superficie importata").font(.system(size: 11, weight: .semibold))
                        Text("Area \(fmt(face.area)) mm²")
                    case let .torus(_, _, _, minor):
                        Text("Faccia tonda (raccordo)").font(.system(size: 11, weight: .semibold))
                        Text("Raggio \(fmt(minor)) mm")
                        Text("Area \(fmt(face.area)) mm²")
                    case let .cylinder(_, axis, r):
                        Text("Faccia cilindrica").font(.system(size: 11, weight: .semibold))
                        Text("Ø \(fmt(2 * r)) mm · R \(fmt(r)) mm")
                        Text("Asse \(fmt(axis.x)) · \(fmt(axis.y)) · \(fmt(axis.z))")
                        Text("Area \(fmt(face.area)) mm²")
                    }
                } else if faces.count > 1 {
                    Text("\(faces.count) facce").font(.system(size: 11, weight: .semibold))
                    Text("Area totale \(fmt(faces.reduce(0) { $0 + $1.area })) mm²")
                    if faces.count == 2, case let .plane(o1, n1) = faces[0].surface, case let .plane(o2, n2) = faces[1].surface {
                        let ang = acos(max(-1, min(1, n1.dot(n2)))) * 180 / .pi
                        Text("Angolo tra le facce \(fmt(ang))°")
                        if abs(abs(n1.dot(n2)) - 1) < 1e-6 {
                            Text("Distanza tra i piani \(fmt(abs((o2 - o1).dot(n1)))) mm")
                        }
                    }
                }
                if edges.count == 1, let e = edges.first {
                    Text("Spigolo").font(.system(size: 11, weight: .semibold))
                    Text("Lunghezza \(fmt(e.length)) mm")
                } else if edges.count > 1 {
                    Text("\(edges.count) spigoli").font(.system(size: 11, weight: .semibold))
                    Text("Lunghezza totale \(fmt(edges.reduce(0) { $0 + $1.length })) mm")
                }
                Text("⇧/⌘ clic: aggiungi · Esc: deseleziona").foregroundStyle(Theme.Palette.textSecondary)
            }
            .font(.system(size: 11).monospacedDigit())
            .padding(.horizontal, 8).padding(.vertical, 6)
            .overlayChip()
        }
    }

    // MARK: Sketch overlays

    private var sketchLines: [(SIMD3<Float>, SIMD3<Float>, SIMD4<Float>)] {
        savedSketchLines + flatLines + (workspace.holePlacement?.overlay() ?? []) + (workspace.manipulator?.overlay() ?? []) + (workspace.sketch?.overlay(sketchColor: SIMD4(0.35, 0.69, 1, 1),
                                  selectedColor: SIMD4(1, 0.55, 0.22, 1),
                                  previewColor: SIMD4(1, 0.55, 0.22, 0.8)) ?? [])
    }

    /// Visible saved sketches, faint, on their plane.
    private var savedSketchLines: [(SIMD3<Float>, SIMD3<Float>, SIMD4<Float>)] {
        let editing = workspace.sketch?.sketch.id
        let color = SIMD4<Float>(0.35, 0.69, 1, 0.45)
        var out: [(SIMD3<Float>, SIMD3<Float>, SIMD4<Float>)] = []
        for sk in sketchStore.sketches where sk.isVisible && sk.id != editing {
            for shape in sk.shapes {
                let pts = shape.outline.map { sk.plane.world($0) }.map { SIMD3(Float($0.x), Float($0.y), Float($0.z) + 0.02) }
                guard pts.count >= 2 else { continue }
                for i in 0..<(shape.isClosed ? pts.count : pts.count - 1) {
                    out.append((pts[i], pts[(i + 1) % pts.count], shape.isConstruction ? color * SIMD4(1, 1, 1, 0.5) : color))
                }
            }
        }
        return out
    }

    /// Live measurement next to the cursor.
    @ViewBuilder private var sketchHUD: some View {
        if let sketch = workspace.sketch, workspace.command == nil,
           let text = sketch.liveMeasure, let p = sketch.cursorScreen {
            Text(text)
                .font(.system(size: 11, weight: .medium).monospacedDigit())
                .foregroundStyle(.white)
                .padding(.horizontal, 6).padding(.vertical, 3)
                .background(Theme.Palette.sketch.opacity(0.9), in: RoundedRectangle(cornerRadius: 4))
                .offset(x: p.x + 14, y: p.y + 14)
                .allowsHitTesting(false)
        }
    }

    /// "SCHIZZO" / "FORO" banner with the current hint.
    @ViewBuilder private var sketchBanner: some View {
        if let placement = workspace.holePlacement {
            HStack(spacing: 8) {
                Label("FORO", systemImage: "circle.circle").font(.system(size: 11, weight: .bold))
                    .foregroundStyle(Theme.Palette.danger)
                Text(placement.centers.isEmpty ? "Clicca su una faccia piana per posizionare il centro"
                     : "\(placement.centers.count) centr\(placement.centers.count == 1 ? "o" : "i") · clicca per aggiungerne altri")
                    .font(.system(size: 11)).foregroundStyle(Theme.Palette.textSecondary)
                if let snap = placement.hover?.snap {
                    Label(snap, systemImage: "scope").font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Color(red: 0.3, green: 0.9, blue: 0.45))
                }
                if !placement.centers.isEmpty {
                    Button("Togli ultimo") { placement.removeLast() }
                        .controlSize(.small)
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .overlayChip()
            .padding(.top, 10)
        }
        if workspace.pickingSketchPlane {
            HStack(spacing: 8) {
                Label("SCHIZZO", systemImage: "pencil.and.outline").font(.system(size: 11, weight: .bold))
                    .foregroundStyle(Theme.Palette.sketch)
                Text("Clicca una faccia piana, oppure").font(.system(size: 11)).foregroundStyle(Theme.Palette.textSecondary)
                Button("XY") { workspace.enterSketch(plane: .xy) }.controlSize(.small).help("Piano di base (vista dall'alto)")
                Button("XZ") { workspace.enterSketch(plane: .xz) }.controlSize(.small).help("Piano frontale (vista di fronte)")
                Button("YZ") { workspace.enterSketch(plane: .yz) }.controlSize(.small).help("Piano laterale (vista da destra)")
                Text("Sfalsa").font(.system(size: 11)).foregroundStyle(Theme.Palette.textSecondary)
                TextField("0", value: Binding(get: { workspace.sketchPlaneOffset }, set: { workspace.sketchPlaneOffset = $0 }),
                          format: .number.precision(.fractionLength(0...2)))
                    .frame(width: 54).multilineTextAlignment(.trailing).font(.system(size: 11).monospacedDigit())
                    .help("Piano di costruzione: sposta il piano scelto lungo la sua normale (mm)")
                Text("mm").font(.system(size: 11)).foregroundStyle(Theme.Palette.textSecondary)
                Button("Annulla") { workspace.pickingSketchPlane = false }.controlSize(.small)
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .overlayChip()
            .padding(.top, 10)
        }
        if let sketch = workspace.sketch, workspace.command == nil {
            HStack(spacing: 8) {
                Label("SCHIZZO · " + (sketch.sketch.plane.isXY ? "piano XY" : "su faccia"), systemImage: "pencil.and.outline")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(Theme.Palette.sketch)
                Text(sketch.tool.hint).font(.system(size: 11)).foregroundStyle(Theme.Palette.textSecondary)
                Button("Termina") { workspace.exitSketch() }.controlSize(.small)
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .overlayChip()
            .padding(.top, 10)
        }
    }

    /// Keyboard shortcuts active only while sketching and no command panel is open.
    @ViewBuilder private var sketchKeys: some View {
        if workspace.sketch == nil, workspace.command == nil, !workspace.geoSelection.isEmpty {
            Button("") { workspace.geoSelection = [] }.keyboardShortcut(.cancelAction)
                .opacity(0).frame(width: 0, height: 0).accessibilityHidden(true)
        }
        if let sketch = workspace.sketch, workspace.command == nil {
            ZStack {
                Button("") { if !sketch.cancel() { workspace.exitSketch() } }.keyboardShortcut(.cancelAction)
                Button("") { sketch.finish() }.keyboardShortcut(.defaultAction)
                Button("") { sketch.deleteSelection() }.keyboardShortcut(.delete, modifiers: [])
            }
            .opacity(0).frame(width: 0, height: 0).accessibilityHidden(true)
        }
    }

    private var navigationBar: some View {
        HStack(spacing: 2) {
            ForEach(SelectionFilter.allCases) { filter in
                Button { workspace.selectionFilter = filter } label: { Label(filter.rawValue, systemImage: filter.symbol) }
                    .buttonStyle(IconButtonStyle(isActive: workspace.selectionFilter == filter))
                    .help("Seleziona: \(filter.rawValue.lowercased())")
                    .disabled(workspace.sketch != nil)
            }
            Divider().frame(height: 16).padding(.horizontal, 3)
            Button { viewport.home() } label: { Label("Home", systemImage: "house") }
                .help("Vista iniziale (Home)")
            Button { viewport.fit() } label: { Label("Adatta", systemImage: "arrow.up.left.and.down.right.magnifyingglass") }
                .help("Adatta alla finestra (F con il viewport attivo)")
            Divider().frame(height: 16).padding(.horizontal, 3)
            Button {
                viewport.camera.projection = viewport.camera.projection == .perspective ? .orthographic : .perspective
            } label: {
                Label("Proiezione", systemImage: viewport.camera.projection == .perspective ? "perspective" : "square.on.square.dashed")
            }
            .help(viewport.camera.projection == .perspective ? "Prospettiva — passa a ortogonale" : "Ortogonale — passa a prospettiva")
            Menu {
                Picker("Stile", selection: $viewport.style) {
                    ForEach(ViewportRenderer.DisplayStyle.allCases) { s in
                        Label(s.rawValue, systemImage: s.symbol).tag(s)
                    }
                }
                .pickerStyle(.inline)
            } label: {
                Image(systemName: viewport.style.symbol)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .frame(width: 26)
            .help("Stile di visualizzazione")
        }
        .buttonStyle(IconButtonStyle())
        .overlayChip()
    }
}


extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}
