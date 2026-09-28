import CADCore
import SwiftUI

/// Fusion-style workspace: ribbon on top, browser left, viewport centre,
/// inspector right, timeline and status bar at the bottom.
struct WorkspaceView: View {
    @Environment(DesignModel.self) private var model
    @Environment(ProjectLibrary.self) private var library
    @Environment(SketchStore.self) private var sketches
    @Environment(CircuitModel.self) private var circuits
    @Environment(AssistantSession.self) private var assistant
    @State private var workspace = WorkspaceState()
    @State private var viewport = ViewportState()

    var body: some View {
        VStack(spacing: 0) {
            DesignTabs()
            Ribbon()
            Divider()
            HStack(spacing: 0) {
                if workspace.tab == .circuits {
                    // CIRCUITI: the board and its checks instead of the 3D workspace.
                    CircuitWorkspace()
                } else {
                if workspace.showBrowser {
                    BrowserPanel().frame(width: Theme.Metrics.browserWidth)
                    Divider()
                }
                ViewportContainer(viewport: viewport)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                if workspace.showInspector, workspace.tab != .circuits {
                    Divider()
                    SidePanel().frame(width: Theme.Metrics.inspectorWidth + 60)
                } else if workspace.tab == .circuits, workspace.showInspector, workspace.sideTab == .assistant {
                    // CIRCUITI has no parameters panel; the assistant (⌘L) works on the circuit too.
                    Divider()
                    AssistantPanel().frame(width: Theme.Metrics.inspectorWidth + 60)
                }
            }
            if workspace.tab != .circuits {
                Divider()
                TimelineBar()
            }
            Divider()
            StatusBar()
        }
        .background(Theme.Palette.canvas)
        .accessibilityHidden(library.showHome)
        .overlay {
            // Home covers the workspace but keeps its state (camera, panels) alive underneath.
            if library.showHome { HomeView().transition(.opacity) }
        }
        .overlay {
            // Opening a design in the background: progress over everything, input blocked.
            if let loading = model.loading { LoadingCard(loading: loading).transition(.opacity) }
        }
        .animation(.easeOut(duration: 0.15), value: model.loading == nil)
        // A design just opened: frame all of it from the home view.
        .onChange(of: model.loading == nil) { _, done in if done { workspace.viewRequest = .home } }
        .animation(.easeOut(duration: 0.15), value: library.showHome)
        .sheet(isPresented: $workspace.showComponentPicker) { ComponentPickerSheet().environment(workspace) }
        .sheet(isPresented: $workspace.showBOM) { BOMSheet().environment(workspace) }
        .sheet(isPresented: $workspace.showParameters) { ParametersSheet().environment(workspace) }
        .sheet(isPresented: $workspace.showInterference) { InterferenceSheet().environment(workspace) }
        .sheet(isPresented: Binding(get: { model.showDrawing }, set: { model.showDrawing = $0 })) { DrawingWindow() }
        .environment(workspace)
        // ⌘Z in CIRCUITI undoes the circuit's steps; elsewhere the design's (or the sketch's).
        .onChange(of: workspace.tab) { old, new in
            assistant.focus = new == .circuits ? .circuits : .cad
            circuits.isFrontmost = new == .circuits
            if new == .circuits { model.localUndoTarget = circuits }
            else if old == .circuits, model.localUndoTarget === circuits { model.localUndoTarget = nil }
        }
        .onAppear {
            circuits.report = { [weak circuits] in circuits?.message = $0 }
            circuits.defaultFolder = { [weak library] in library?.currentURL?.deletingLastPathComponent() ?? library?.projects.first?.url }
            circuits.saved = { [weak library] in library?.noteRecent($0) }
            workspace.sketchStore = sketches; workspace.model = model
            model.finishPendingEdits = { [weak workspace] in
                if workspace?.sketch != nil { workspace?.exitSketch() }
            }
            model.willSwitchDesign = { [weak workspace] in
                guard let workspace else { return }
                if workspace.sketch != nil { workspace.exitSketch() }
                workspace.command?.onCancel()
                workspace.command = nil
                workspace.geoSelection = []
                workspace.manipulator = nil
            }
            model.captureView = { [viewport] in viewport.camera.pose }
            model.restoreView = { [viewport] saved in
                if let pose = saved as? CameraController.Pose { viewport.camera.restore(pose); viewport.redraw() }
            }
        }
        .onChange(of: model.designRevision) { _, _ in
            // Drop face/edge references that no longer exist after an edit (stable IDs survive resizes).
            let bodies = model.snapshot().bodies
            func exists(_ r: GeoRef) -> Bool {
                guard let b = bodies.first(where: { $0.bodyID == r.feature }) else { return false }
                switch r.kind {
                case let .face(id): return b.faces.contains { $0.id == id }
                case let .edge(id): return b.edges.contains { $0.id == id }
                }
            }
            workspace.geoSelection.removeAll { !exists($0) }
            if let h = workspace.geoHover, !exists(h) { workspace.geoHover = nil }
        }
        .onChange(of: model.selection) { _, id in
            // Selecting a body from the viewport/browser shows its parameters, unless the user is chatting.
            if id != nil, workspace.sideTab == .parameters { workspace.showInspector = true }
        }
    }
}

/// Right column: parameters of the selection or the design assistant.
private struct SidePanel: View {
    @Environment(WorkspaceState.self) private var workspace

    var body: some View {
        @Bindable var workspace = workspace
        VStack(spacing: 0) {
            Picker("Pannello", selection: $workspace.sideTab) {
                ForEach(WorkspaceState.SideTab.allCases) { tab in
                    Label(tab.rawValue, systemImage: tab == .assistant ? "sparkles" : "slider.horizontal.3").tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 8).padding(.vertical, 5)
            .background(Theme.Palette.panel)
            Divider()
            switch workspace.sideTab {
            case .parameters: InspectorPanel()
            case .assistant: AssistantPanel()
            }
        }
    }
}

/// «Apertura Robotvolley — parte 57 di 138» with a progress bar, while a design is read and
/// evaluated in the background.
private struct LoadingCard: View {
    let loading: DesignModel.Loading

    var body: some View {
        ZStack {
            Color.black.opacity(0.35).ignoresSafeArea()
            VStack(alignment: .leading, spacing: 10) {
                Label("Apertura «\(loading.name)»", systemImage: "cube.transparent")
                    .font(.system(size: 13, weight: .semibold))
                if loading.total > 0 {
                    ProgressView(value: Double(loading.done), total: Double(loading.total))
                    Text("Parte \(min(loading.done + 1, loading.total)) di \(loading.total)")
                        .font(.system(size: 11).monospacedDigit()).foregroundStyle(Theme.Palette.textSecondary)
                } else {
                    ProgressView().progressViewStyle(.linear)
                    Text("Lettura del file…").font(.system(size: 11)).foregroundStyle(Theme.Palette.textSecondary)
                }
            }
            .padding(18)
            .frame(width: 320)
            .background(RoundedRectangle(cornerRadius: 12).fill(Theme.Palette.panel))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.white.opacity(0.08)))
            .shadow(color: .black.opacity(0.4), radius: 18, y: 6)
        }
        .contentShape(Rectangle())
        .onTapGesture {}   // swallow clicks while loading
    }
}
