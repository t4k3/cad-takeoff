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
        sketch = SketchSession(sketch: existing ?? Sketch(name: sketchStore?.nextName ?? "Schizzo 1"))
        tab = .sketch
        // Show the entity parameters while sketching.
        showInspector = true
        sideTab = .parameters
        sketchCameraRequest = true
    }

    /// "Termina schizzo": saves the sketch (if it has entities) and regenerates the extrusions made from it.
    func exitSketch() {
        command?.onCancel(); command = nil
        if let edited = sketch?.sketch, let store = sketchStore {
            let before = store.sketch(edited.id)
            if !edited.shapes.isEmpty || before != nil {
                if before != edited { store.upsert(edited) }
                if let model { Task { await regenerate(edited, store: store, model: model) } }
            }
        }
        sketch = nil
        tab = .solid
        sketchCameraRequest = false
    }

    /// Updates every extrusion linked to a shape of `sketch` through the Model's undoable `update_feature`.
    private func regenerate(_ sketch: Sketch, store: SketchStore, model: DesignModel) async {
        store.prune(existing: Set(model.document.features.map(\.id)))
        var updated = 0
        for link in store.links(of: sketch.id) {
            guard let shape = sketch.shapes.first(where: { $0.id == link.shapeID }), let profile = shape.profile,
                  let feature = model.document.features.first(where: { $0.id == link.featureID }),
                  case let .extrude(current, _) = feature.kind, current != profile else { continue }
            let r = await model.call("update_feature", arguments: [
                "feature_id": .string(feature.id.uuidString),
                "points": .array(shape.outline.map { ["x": .number($0.x), "y": .number($0.y)] }),
                "expected_revision": .string(model.designRevision),
            ])
            if r.isError { model.statusMessage = "\(feature.name) non aggiornata: \(r.text)" } else { updated += 1 }
        }
        if updated > 0 {
            model.statusMessage = "\(sketch.name): " + (updated == 1 ? "aggiornata 1 estrusione" : "aggiornate \(updated) estrusioni") + " — ⌘Z per annullare"
        }
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
