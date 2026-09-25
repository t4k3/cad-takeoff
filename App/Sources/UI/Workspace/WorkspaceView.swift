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
                    InspectorPanel().frame(width: Theme.Metrics.inspectorWidth)
                }
            }
            Divider()
            TimelineBar()
            Divider()
            StatusBar()
        }
        .background(Theme.Palette.canvas)
        .environment(workspace)
    }
}
