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

    func home() { camera.show(.home, bounds: renderer?.sceneBounds) }
    func fit() { camera.fit(renderer?.sceneBounds) }

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
                          onReady: { renderer in
                              viewport.renderer = renderer
                              DispatchQueue.main.async { viewport.fitOnce() }
                          })
        }
        .overlay(alignment: .bottom) { navigationBar.padding(.bottom, 12) }
        .overlay(alignment: .topLeading) {
            Text("Trascina: orbita · ⇧ trascina / due dita: sposta · rotella / pizzica: zoom")
                .font(.system(size: 10.5)).foregroundStyle(.white.opacity(0.55))
                .padding(12)
        }
        .clipped()
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
