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
    /// What a click in the viewport selects (bodies, faces, edges).
    var selectionFilter: SelectionFilter = .body {
        didSet { if selectionFilter != oldValue { geoHover = nil; geoSelection = [] } }
    }
    var geoHover: GeoRef?
    var geoSelection: [GeoRef] = []

    /// Command panel currently open (create/edit feature).
    var command: CommandSession?
    /// Active sketch (v0, UI-only). nil = not sketching.
    var sketch: SketchSession?
    /// Asks the viewport to switch camera for sketch mode (true) or restore it (false).
    var sketchCameraRequest: Bool?
    /// Set by WorkspaceView: saved sketches and the model (for regenerating linked extrusions).
    @ObservationIgnored weak var sketchStore: SketchStore?
    @ObservationIgnored weak var model: DesignModel?

    /// New sketch, or edit an existing saved one.
    func enterSketch(editing existing: Sketch? = nil) {
        command?.onCancel(); command = nil
        if sketch != nil { exitSketch() }
        let session = SketchSession(sketch: existing ?? Sketch(name: sketchStore?.nextName ?? "Schizzo 1"))
        sketch = session
        model?.localUndoTarget = session
        tab = .sketch
        // Show the entity parameters while sketching.
        showInspector = true
        sideTab = .parameters
        sketchCameraRequest = true
    }

    /// "Termina schizzo": saves the sketch and regenerates the extrusions made from it,
    /// as one undoable step ("Schizzo 1").
    func exitSketch() {
        command?.onCancel(); command = nil
        if let edited = sketch?.sketch, let model {
            let before = model.document.sketches.first { $0.id == edited.id }
            if (!edited.shapes.isEmpty || before != nil), before != edited {
                model.edit(edited.name) { doc in
                    doc.upsert(edited)
                    doc.regenerate(from: edited)
                }
            }
        }
        model?.localUndoTarget = nil
        sketch = nil
        tab = .solid
        sketchCameraRequest = false
    }

    func extrudeSketch(model: DesignModel) {
        guard let sketch else { return }
        command?.onCancel()
        command = SketchCommands.extrude(sketch: sketch, model: model, workspace: self)
    }

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
