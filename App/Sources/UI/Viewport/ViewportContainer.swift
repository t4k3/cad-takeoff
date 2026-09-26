import CADCore
import Observation
import SwiftUI

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
    func applySketchCamera(_ entering: Bool) {
        if entering {
            projectionBeforeSketch = camera.projection
            camera.projection = .orthographic
            camera.show(.top, bounds: nil)
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

    func pickGeo(_ ray: Ray, filter: SelectionFilter) -> GeoRef? {
        guard let bodies = renderer?.visibleBodies else { return nil }
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

    func body(_ id: Feature.ID) -> ViewportRenderer.Body? { renderer?.bodies[id] }

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

    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(white: 0.30), Color(white: 0.17)], startPoint: .top, endPoint: .bottom)
                .overlay(Theme.Palette.canvas.opacity(0.0))
            MetalViewport(features: model.document.activeFeatures, snapshot: model.snapshot(),
                          // In face/edge mode only the picked face/edge is highlighted, not the whole body.
                          selection: workspace.selectionFilter == .body ? model.selection : nil,
                          hovered: workspace.hovered, style: viewport.style, camera: viewport.camera,
                          overlayLines: sketchLines,
                          highlightTriangles: geoHighlight.triangles,
                          highlightLines: geoHighlight.lines,
                          onClick: { _, ray, mods in
                              if let sketch = workspace.sketch {
                                  guard workspace.command == nil,
                                        let p = ray.intersect(planePoint: .zero, normal: SIMD3(0, 0, 1)) else { return }
                                  sketch.vertexSnap = 8 * viewport.mmPerPoint
                                  sketch.click(p)
                                  return
                              }
                              if let placement = workspace.holePlacement, let bodies = viewport.renderer?.visibleBodies {
                                  if let msg = placement.click(ray, bodies: bodies) { model.statusMessage = msg }
                                  return
                              }
                              if workspace.selectionFilter != .body {
                                  let multi = !mods.isDisjoint(with: [.shift, .command])
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
                          },
                          onHover: { point, ray in
                              if let sketch = workspace.sketch {
                                  sketch.vertexSnap = 8 * viewport.mmPerPoint
                                  sketch.hover(ray?.intersect(planePoint: .zero, normal: SIMD3(0, 0, 1)), screen: point)
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
                          },
                          onKey: { key in
                              if let sketch = workspace.sketch, workspace.command == nil {
                                  if let tool = SketchSession.Tool.allCases.first(where: { $0.key == key }) {
                                      sketch.tool = tool; return true
                                  }
                                  if key == "e" { workspace.extrudeSketch(model: model); return true }
                              }
                              if key == "f" { viewport.fit(); return true }
                              return false
                          },
                          onReady: { renderer in
                              viewport.renderer = renderer
                              viewport.redraw = { [weak renderer] in renderer?.requestRedraw() }
                              DispatchQueue.main.async { viewport.fitOnce() }
                          })
        }
        .background(GeometryReader { g in Color.clear.onAppear { viewport.viewSize = g.size }.onChange(of: g.size) { _, s in viewport.viewSize = s } })
        .overlay(alignment: .topLeading) { sketchHUD }
        .overlay(alignment: .bottomLeading) { measureChip.padding(12) }
        .overlay(alignment: .top) { sketchBanner }
        .background { sketchKeys }
        .onChange(of: workspace.sketchCameraRequest) { _, request in
            guard let request else { return }
            viewport.applySketchCamera(request)
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
        savedSketchLines + (workspace.holePlacement?.overlay() ?? []) + (workspace.sketch?.overlay(sketchColor: SIMD4(0.35, 0.69, 1, 1),
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
                if !placement.centers.isEmpty {
                    Button("Togli ultimo") { placement.centers.removeLast(); if placement.centers.isEmpty { placement.normal = nil; placement.planeOrigin = nil } }
                        .controlSize(.small)
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .overlayChip()
            .padding(.top, 10)
        }
        if let sketch = workspace.sketch, workspace.command == nil {
            HStack(spacing: 8) {
                Label("SCHIZZO · piano XY", systemImage: "pencil.and.outline")
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
