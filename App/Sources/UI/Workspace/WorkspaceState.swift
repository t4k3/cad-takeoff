import CADCore
import Observation
import SwiftUI

/// UI-only state of the workspace (never persisted in the design, never read by the Model).
@MainActor
@Observable
final class WorkspaceState {
    enum Tab: String, CaseIterable, Identifiable {
        case solid = "SOLIDO"
        case sketch = "SCHIZZO"
        case print = "STAMPA"
        var id: String { rawValue }
    }

    var tab: Tab = .solid
    var showBrowser = true
    var showInspector = true
    enum SideTab: String, CaseIterable, Identifiable { case parameters = "Parametri", assistant = "Assistente"; var id: String { rawValue } }
    var sideTab: SideTab = .assistant

    /// Shows the assistant tab (opening the side panel if hidden).
    func showAssistant() {
        showInspector = true
        sideTab = .assistant
    }
    /// Feature under the mouse in browser, timeline or viewport: highlighted everywhere.
    var hovered: Feature.ID?
    /// Command panel currently open (create/edit feature).
    var command: CommandSession?

    /// Opens the edit panel for a feature, cancelling any command already running.
    func editFeature(_ id: Feature.ID, model: DesignModel) {
        command?.onCancel()
        model.selection = id
        command = FeatureCommands.edit(id, model: model)
    }
}

extension Feature.Kind {
    var symbol: String {
        switch self {
        case .box: "cube"
        case .cylinder: "cylinder"
        case .extrude: "square.stack.3d.up"
        }
    }

    var typeName: String {
        switch self {
        case .box: "Parallelepipedo"
        case .cylinder: "Cilindro"
        case .extrude: "Estrusione"
        }
    }
}
