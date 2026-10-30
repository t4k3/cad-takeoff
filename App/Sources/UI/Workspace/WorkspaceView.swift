import CADCore
import SwiftUI

/// Workspace in the macOS HIG style: the 3D viewport fills the window, and the panels are
/// floating Liquid Glass islands over it — document tabs (top-left), modes (top centre),
/// tools (top centre row), browser (left), parameters/assistant (right), timeline and
/// status capsules at the bottom.
struct WorkspaceView: View {
    @Environment(DesignModel.self) private var model
    @Environment(ProjectLibrary.self) private var library
    @Environment(SketchStore.self) private var sketches
    @Environment(CircuitModel.self) private var circuits
    @Environment(AssistantSession.self) private var assistant
    @Environment(WorkspaceState.self) private var workspace
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow
    @State private var viewport = ViewportState()

    /// Geometry of the floating chrome, so the viewport overlays can keep clear of it.
    private enum Glass {
        static let inset: CGFloat = 12
        /// Tool dock, first row under the window title bar: document tabs and modes now live in
        /// the title bar itself (Xcode style), so nothing else sits above the dock.
        static let dockY: CGFloat = 8
        static let dockHeight: CGFloat = 58
        /// One full-width bottom bar: navigation buttons, timeline, design stats and status.
        static let barHeight: CGFloat = 44
        /// Equal to `dockY`, so the side panels have the same margin to the title bar above
        /// and to the bottom bar below.
        static let bottomGap: CGFloat = 8
        static let browserWidth: CGFloat = 248
        static let inspectorWidth: CGFloat = 300

        static var topRoom: CGFloat { dockY + dockHeight + 8 }
        static var bottomRoom: CGFloat { barHeight + inset }
    }

    var body: some View {
        @Bindable var workspace = workspace
        return GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                base(geo.size)
                islands(geo.size)
            }
        }
        .background(Theme.Palette.canvas)
        // Home lives in its own window (Window id «welcome», FusionTakeoffApp), shown or
        // dismissed by `library.showHome`; the workspace keeps its state underneath.
        .onAppear {
            // If the welcome window is the one launched, this workspace stays closed until a
            // design is opened; otherwise make sure `showHome` matches it (no double toggle).
            let wantsWelcome = UserDefaults.standard.object(forKey: "welcome.showAtLaunch") as? Bool ?? true
            if wantsWelcome {
                if library.showHome { openWindow(id: "welcome") }
            } else if library.showHome {
                library.showHome = false
            }
        }
        .onChange(of: library.showHome) { _, show in
            if show { openWindow(id: "welcome") } else { dismissWindow(id: "welcome") }
        }
        .overlay {
            // Opening a design in the background: progress over everything, input blocked.
            if let loading = model.loading { LoadingCard(loading: loading).transition(.opacity) }
        }
        .animation(.easeOut(duration: 0.15), value: model.loading == nil)
        // A design just opened: frame all of it.
        .onChange(of: model.loading == nil) { _, done in if done { workspace.viewRequest = .home } }
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: workspace.showBrowser)
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: workspace.showInspector)
        .sheet(isPresented: $workspace.showComponentPicker) { ComponentPickerSheet().environment(workspace) }
        .sheet(isPresented: $workspace.showBOM) { BOMSheet().environment(workspace) }
        .sheet(isPresented: $workspace.showParameters) { ParametersSheet().environment(workspace) }
        .sheet(isPresented: $workspace.showInterference) { InterferenceSheet().environment(workspace) }
        .sheet(isPresented: Binding(get: { model.showDrawing }, set: { model.showDrawing = $0 })) { DrawingWindow() }
        .environment(workspace)
        .toolbar { toolbar }
        // ⌘Z in CIRCUITI undoes the circuit's steps; elsewhere the design's (or the sketch's).
        .onChange(of: workspace.tab) { old, new in
            assistant.focus = new == .circuits ? .circuits : .cad
            circuits.isFrontmost = new == .circuits
            if new == .circuits { model.localUndoTarget = circuits }
            else if old == .circuits, model.localUndoTarget === circuits { model.localUndoTarget = nil }
        }
        .onAppear {
            // Local names, so the callbacks below hold them weakly (not the view's strongly).
            let circuits = circuits, library = library, workspace = workspace
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

    // MARK: - Base layer

    /// The whole window: the live viewport (edge to edge) or the circuit board.
    @ViewBuilder private func base(_ size: CGSize) -> some View {
        if workspace.tab == .circuits {
            CircuitWorkspace()
                .padding(.top, Glass.topRoom)
                .padding(.bottom, Glass.bottomRoom)
                .frame(width: size.width, height: size.height)
        } else {
            ViewportContainer(viewport: viewport, overlayInsets: viewportInsets)
                .frame(width: size.width, height: size.height)
        }
    }

    /// What the viewport's own overlays (ViewCube, hints, nav bar) must leave free.
    private var viewportInsets: EdgeInsets {
        EdgeInsets(top: Glass.topRoom + 8,
                   leading: workspace.showBrowser ? Glass.browserWidth + Glass.inset : 0,
                   bottom: Glass.bottomRoom,
                   trailing: workspace.showInspector ? Glass.inspectorWidth + Glass.inset : 0)
    }

    // MARK: - Floating islands

    @ViewBuilder private func islands(_ size: CGSize) -> some View {
        // Tool dock, centred between the side islands.
        let availableWidth = size.width
            - (workspace.showBrowser ? Glass.browserWidth + Glass.inset : 0)
            - (workspace.showInspector ? Glass.inspectorWidth + Glass.inset : 0)
            - Glass.inset * 2
        let dockWidth = min(max(availableWidth, 320), 820)
        Ribbon()
            .frame(width: dockWidth)
            .offset(x: (size.width - dockWidth) / 2, y: Glass.dockY)

        if workspace.tab != .circuits, workspace.showBrowser {
            BrowserPanel()
                .frame(width: Glass.browserWidth, height: islandHeight(size))
                .glassPanel()
                .offset(x: Glass.inset, y: Glass.dockY)
                .transition(.move(edge: .leading).combined(with: .opacity))
        }

        if workspace.tab == .circuits {
            if workspace.showInspector, workspace.sideTab == .assistant {
                AssistantPanel()
                    .frame(width: Glass.inspectorWidth, height: islandHeight(size))
                    .glassPanel()
                    .offset(x: size.width - Glass.inspectorWidth - Glass.inset, y: Glass.dockY)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        } else if workspace.showInspector {
            SidePanel()
                .frame(width: Glass.inspectorWidth, height: islandHeight(size))
                .glassPanel()
                .offset(x: size.width - Glass.inspectorWidth - Glass.inset, y: Glass.dockY)
                .transition(.move(edge: .trailing).combined(with: .opacity))
        }

        // Bottom: one full-width bar with everything — navigation buttons, timeline, design
        // stats and the status text.
        let barWidth = size.width - Glass.inset * 2
        let barY = size.height - Glass.inset - Glass.barHeight
        HStack(spacing: 0) {
            if workspace.tab != .circuits {
                ViewportNavigationBar(viewport: viewport)
                barSeparator
                TimelineBar()
                barSeparator
                DesignStatsBar()
                barSeparator
            }
            StatusBar()
                .layoutPriority(1)
        }
        .padding(.horizontal, 12)
        .frame(width: barWidth, height: Glass.barHeight)
        .glassCapsule()
        .offset(x: (size.width - barWidth) / 2, y: barY)
    }

    private var barSeparator: some View {
        Divider().frame(height: 18).padding(.horizontal, 8)
    }

    /// Tall enough to be useful, short enough to leave the part visible; the margins above
    /// (`dockY`) and below (`bottomGap`) are equal.
    private func islandHeight(_ size: CGSize) -> CGFloat {
        max(220, size.height - Glass.dockY - Glass.bottomGap - Glass.barHeight - Glass.inset)
    }

    // MARK: - Window toolbar

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        // Document tabs, middle-left (Xcode puts its breadcrumb there).
        ToolbarItem(placement: .navigation) {
            DesignTabs(inToolbar: true)
                .frame(width: 280)
        }
        // Workspace modes, centred like Xcode's run/scheme controls.
        ToolbarItem(placement: .principal) {
            ModeSwitcher(inToolbar: true)
        }
        ToolbarItemGroup(placement: .primaryAction) {
            Button { library.showHome.toggle() } label: { Label("Home", systemImage: "house") }
                .help("Home: progetti e disegni (⇧⌘H)")
            Button { UndoRouter.undo(model) } label: { Label("Annulla", systemImage: "arrow.uturn.backward") }
                .disabled(!UndoRouter.canUndo(model))
                .help(UndoRouter.undoTitle(model) + " (⌘Z)")
            Button { UndoRouter.redo(model) } label: { Label("Ripeti", systemImage: "arrow.uturn.forward") }
                .disabled(!UndoRouter.canRedo(model))
                .help(UndoRouter.redoTitle(model) + " (⇧⌘Z)")
            Button { workspace.showAssistant() } label: { Label("Assistente", systemImage: "sparkles") }
                .help("Assistente di progettazione (⌘L)")
                .keyboardShortcut("l", modifiers: .command)
            Button { workspace.showBrowser.toggle() } label: { Label("Browser", systemImage: "sidebar.left") }
                .help("Mostra/nascondi Browser")
            Button { workspace.showInspector.toggle() } label: { Label("Parametri", systemImage: "sidebar.right") }
                .help("Mostra/nascondi Parametri")
            // MCP server status and settings: top-right corner, like a network indicator.
            MCPStatusButton()
        }
    }
}

/// Right island: parameters of the selection or the design assistant.
private struct SidePanel: View {
    @Environment(WorkspaceState.self) private var workspace

    var body: some View {
        @Bindable var workspace = workspace
        VStack(spacing: 0) {
            Picker("Pannello", selection: $workspace.sideTab) {
                ForEach(WorkspaceState.SideTab.allCases) { tab in
                    Label(LocalizedStringKey(tab.rawValue), systemImage: tab == .assistant ? "sparkles" : "slider.horizontal.3").tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 10).padding(.vertical, 7)
            Divider().opacity(0.5)
            switch workspace.sideTab {
            case .parameters: InspectorPanel()
            case .assistant: AssistantPanel()
            }
        }
    }
}

/// What the design contains — bodies, triangles, volume — in the middle of the bottom bar.
private struct DesignStatsBar: View {
    @Environment(DesignModel.self) private var model

    var body: some View {
        let stats = model.stats()
        HStack(spacing: 10) {
            Label(stats.bodies == 1 ? String(localized: "1 corpo") : String(localized: "\(stats.bodies) corpi"),
                  systemImage: "shippingbox")
            Label(stats.triangles == 1 ? String(localized: "1 triangolo") : String(localized: "\(stats.triangles) triangoli"),
                  systemImage: "triangle")
            Label(String(format: "%.2f cm³", stats.volume / 1000), systemImage: "cube.transparent")
            Text("mm · Z↑")
        }
        .labelStyle(.titleAndIcon)
        .font(.system(size: 10.5).monospacedDigit())
        .foregroundStyle(Theme.Palette.textSecondary)
        .fixedSize()
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
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(.white.opacity(0.18)))
            .shadow(color: .black.opacity(0.4), radius: 18, y: 6)
        }
        .contentShape(Rectangle())
        .onTapGesture {}   // swallow clicks while loading
    }
}
