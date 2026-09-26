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
        case sheetMetal = "LAMIERA"
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
    var geoSelection: [GeoRef] = [] {
        didSet { if geoSelection != oldValue { onGeoSelectionChange?() } }
    }
    /// A command is collecting edges: a plain click adds or removes one (no ⇧ needed).
    var edgePicking = false
    @ObservationIgnored var onGeoSelectionChange: (() -> Void)?

    /// Drag arrow of the open command (chamfer distance/radius), if any.
    var manipulator: DistanceManipulator?

    // MARK: Command preview (computed off the main thread; the newest request wins)

    /// Geometry shown instead of the design while a command previews its result.
    private(set) var previewSnapshot: DesignSnapshot?
    private(set) var previewIssues: [DesignEvaluator.Issue] = []
    /// Features of the previewed document (a new part is not in the design yet).
    private(set) var previewFeatures: [Feature] = []
    @ObservationIgnored private var pendingPreview: CADDocument?
    @ObservationIgnored private var previewBusy = false
    @ObservationIgnored private var previewGeneration = 0

    /// Shows `doc` evaluated in the viewport; nil goes back to the design.
    func requestPreview(_ doc: CADDocument?) {
        guard let doc else {
            previewGeneration += 1; pendingPreview = nil
            previewSnapshot = nil; previewIssues = []
            return
        }
        pendingPreview = doc
        if !previewBusy { runPreview() }
    }

    private func runPreview() {
        guard let doc = pendingPreview else { previewBusy = false; return }
        pendingPreview = nil; previewBusy = true
        let generation = previewGeneration
        let revision = "preview-\(UUID().uuidString)"
        let resolver = model?.componentResolver
        Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) { DesignEvaluator.evaluate(doc, revision: revision, components: resolver) }.value
            guard let self else { return }
            if generation == self.previewGeneration {
                self.previewSnapshot = DesignSnapshot(revision: revision, bodies: result.bodies.filter(\.isVisible).map(\.snapshot),
                                                      issues: result.issues.map { .init(featureID: $0.featureID, message: $0.message) })
                self.previewIssues = result.issues
                self.previewFeatures = doc.activeFeatures
            }
            self.runPreview()
        }
    }

    /// Command panel currently open (create/edit feature).
    var command: CommandSession?
    /// Hole centres being placed while the Hole panel is open.
    var holePlacement: HolePlacement?

    func startHole(model: DesignModel, editing feature: Feature? = nil) {
        command?.onCancel()
        if sketch != nil { exitSketch() }
        command = HoleCommand.start(workspace: self, model: model, editing: feature)
    }
    /// ASSIEME: sheets for inserting a component and for the bill of materials.
    var showComponentPicker = false
    var showBOM = false

    /// LAMIERA tab: show sheet-metal parts developed flat (with bend lines) instead of folded.
    var showFlat = false

    func startSheetMetal(model: DesignModel, editing feature: Feature? = nil) {
        command?.onCancel()
        if sketch != nil { exitSketch() }
        showFlat = false
        command = SheetMetalCommand.start(workspace: self, model: model, editing: feature)
    }

    func startPattern(model: DesignModel, kind: PatternSpec.Kind) {
        command?.onCancel()
        if sketch != nil { exitSketch() }
        command = PatternCommand.start(workspace: self, model: model, kind: kind)
    }

    func startSplit(model: DesignModel) {
        command?.onCancel()
        if sketch != nil { exitSketch() }
        command = SplitCommand.start(workspace: self, model: model)
    }

    func startChamfer(model: DesignModel, editing feature: Feature? = nil, profile: ChamferSpec.Profile = .flat) {
        command?.onCancel()
        if sketch != nil { exitSketch() }
        command = ChamferCommand.start(workspace: self, model: model, editing: feature, profile: profile)
    }
    /// Active sketch (v0, UI-only). nil = not sketching.
    var sketch: SketchSession?
    /// Asks the viewport to switch camera for sketch mode (true) or restore it (false).
    var sketchCameraRequest: Bool?
    /// Set by WorkspaceView: saved sketches and the model (for regenerating linked extrusions).
    @ObservationIgnored weak var sketchStore: SketchStore?
    @ObservationIgnored weak var model: DesignModel?

    /// «Schizzo» waits for a click on a planar face (or «Piano XY»).
    var pickingSketchPlane = false
    /// Point the sketch camera centres on (the clicked face).
    var sketchFocus: Vec3?

    /// Starts a new sketch: on the selected planar face, else asks for one.
    func startSketch() {
        command?.onCancel(); command = nil
        if case let .face(id)? = geoSelection.first?.kind, let body = geoSelection.first.flatMap({ ref in
               model?.evaluation().bodies.first { $0.id == ref.feature } }),
           let face = body.snapshot.faces.first(where: { $0.id == id }), case let .plane(origin, normal) = face.surface {
            enterSketch(plane: SketchPlane.onFace(point: origin, normal: normal), focus: origin)
            return
        }
        pickingSketchPlane = true
    }

    /// New sketch (on `plane`), or edit an existing saved one.
    func enterSketch(editing existing: Sketch? = nil, plane: SketchPlane = .xy, focus: Vec3? = nil) {
        command?.onCancel(); command = nil
        pickingSketchPlane = false
        if sketch != nil { exitSketch() }
        let session = SketchSession(sketch: existing ?? Sketch(name: sketchStore?.nextName ?? "Schizzo 1", plane: plane))
        sketchFocus = existing.map { $0.plane.world(Vec2(0, 0)) } ?? focus
        if !session.sketch.plane.isXY, let model {
            session.projectReferences(from: model.evaluation().bodies.map(\.snapshot))
        }
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
        if let f = model.document.features.first(where: { $0.id == id }), case .hole = f.kind {
            command = HoleCommand.start(workspace: self, model: model, editing: f)
            return
        }
        if let f = model.document.features.first(where: { $0.id == id }), case .split = f.kind {
            command = SplitCommand.start(workspace: self, model: model, editing: f)
            return
        }
        if let f = model.document.features.first(where: { $0.id == id }), case let .pattern(p) = f.kind {
            command = PatternCommand.start(workspace: self, model: model, kind: p.kind, editing: f)
            return
        }
        if let f = model.document.features.first(where: { $0.id == id }), case .sheetMetal = f.kind {
            showFlat = false
            command = SheetMetalCommand.start(workspace: self, model: model, editing: f)
            return
        }
        if let f = model.document.features.first(where: { $0.id == id }), case .chamfer = f.kind {
            command = ChamferCommand.start(workspace: self, model: model, editing: f)
            return
        }
        command = FeatureCommands.edit(id, model: model)
    }
}

extension Feature.Kind {
    var symbol: String {
        switch self {
        case .box: "cube"
        case .cylinder: "cylinder"
        case .extrude: "square.stack.3d.up"
        case .hole: "circle.circle"
        case let .chamfer(s): s.profile == .round ? "circle.bottomhalf.filled" : "skew"
        case .sheetMetal: "square.stack.3d.down.forward"
        case .component: "puzzlepiece.extension"
        case .importedMesh: "square.and.arrow.down.on.square"
        case let .pattern(p): p.kind == .mirror ? "arrow.left.and.right.righttriangle.left.righttriangle.right" : "square.grid.3x3"
        case .split: "rectangle.split.2x1"
        }
    }

    var typeName: String {
        switch self {
        case .box: "Parallelepipedo"
        case .cylinder: "Cilindro"
        case .extrude: "Estrusione"
        case .hole: "Foro"
        case let .chamfer(s): s.profile == .round ? "Raccordo" : "Smusso"
        case .sheetMetal: "Lamiera"
        case .component: "Componente"
        case .importedMesh: "Mesh importata"
        case let .pattern(p): p.kind.label
        case .split: "Dividi"
        }
    }
}
