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
    @Bindable var viewport: ViewportState

    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(white: 0.30), Color(white: 0.17)], startPoint: .top, endPoint: .bottom)
                .overlay(Theme.Palette.canvas.opacity(0.0))
            MetalViewport(features: model.document.features, selection: model.selection,
                          hovered: workspace.hovered, style: viewport.style, camera: viewport.camera,
                          overlayLines: sketchLines,
                          onClick: { _, ray, _ in
                              if let sketch = workspace.sketch {
                                  guard workspace.command == nil,
                                        let p = ray.intersect(planePoint: .zero, normal: SIMD3(0, 0, 1)) else { return }
                                  sketch.vertexSnap = 8 * viewport.mmPerPoint
                                  sketch.click(p)
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
                              let id = ray.flatMap { viewport.pick($0) }
                              if workspace.hovered != id { workspace.hovered = id }
                          },
                          onReady: { renderer in
                              viewport.renderer = renderer
                              viewport.redraw = { [weak renderer] in renderer?.requestRedraw() }
                              DispatchQueue.main.async { viewport.fitOnce() }
                          })
        }
        .background(GeometryReader { g in Color.clear.onAppear { viewport.viewSize = g.size }.onChange(of: g.size) { _, s in viewport.viewSize = s } })
        .overlay(alignment: .topLeading) { sketchHUD }
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

    // MARK: Sketch overlays

    private var sketchLines: [(SIMD3<Float>, SIMD3<Float>, SIMD4<Float>)] {
        workspace.sketch?.overlay(sketchColor: SIMD4(0.35, 0.69, 1, 1),
                                  selectedColor: SIMD4(1, 0.55, 0.22, 1),
                                  previewColor: SIMD4(1, 0.55, 0.22, 0.8)) ?? []
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

    /// "SCHIZZO" banner with the current tool hint.
    @ViewBuilder private var sketchBanner: some View {
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
        if let sketch = workspace.sketch, workspace.command == nil {
            ZStack {
                Button("") { if !sketch.cancel() { workspace.exitSketch() } }.keyboardShortcut(.cancelAction)
                Button("") { sketch.finish() }.keyboardShortcut(.defaultAction)
                Button("") { sketch.deleteSelection() }.keyboardShortcut(.delete, modifiers: [])
                Button("") { sketch.tool = .line }.keyboardShortcut("l", modifiers: [])
                Button("") { sketch.tool = .rectangle }.keyboardShortcut("r", modifiers: [])
                Button("") { sketch.tool = .circle }.keyboardShortcut("c", modifiers: [])
            }
            .opacity(0).frame(width: 0, height: 0).accessibilityHidden(true)
        }
    }

    private var navigationBar: some View {
        HStack(spacing: 2) {
            Button { viewport.home() } label: { Label("Home", systemImage: "house") }
                .help("Vista iniziale (Home)")
            Button { viewport.fit() } label: { Label("Adatta", systemImage: "arrow.up.left.and.down.right.magnifyingglass") }
                .help("Adatta alla finestra (F)")
                .keyboardShortcut("f", modifiers: [])
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
