import CADCore
import SwiftUI

/// Fusion-style workspace: ribbon on top, browser left, viewport centre,
/// inspector right, timeline and status bar at the bottom.
struct WorkspaceView: View {
    @Environment(DesignModel.self) private var model
    @State private var workspace = WorkspaceState()
    @State private var viewport = ViewportState()

    var body: some View {
        VStack(spacing: 0) {
            Ribbon()
            Divider()
            HStack(spacing: 0) {
                if workspace.showBrowser {
                    BrowserPanel().frame(width: Theme.Metrics.browserWidth)
                    Divider()
                }
                ViewportContainer(viewport: viewport)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                if workspace.showInspector {
                    Divider()
                    SidePanel().frame(width: Theme.Metrics.inspectorWidth + 60)
                }
            }
            Divider()
            TimelineBar()
            Divider()
            StatusBar()
        }
        .background(Theme.Palette.canvas)
        .environment(workspace)
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
