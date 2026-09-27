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
        case circuits = "CIRCUITI"
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
    /// A jointed part being dragged (turns or slides on its joint).
    @ObservationIgnored var jointDrag: JointDrag?

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
        let resolver = model?.componentResolver, cache = model?.evaluationCache
        Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) {
                DesignEvaluator.evaluate(doc, revision: revision, components: resolver, cache: cache)
            }.value
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
    var showParameters = false
    var showInterference = false

    /// LAMIERA tab: show sheet-metal parts developed flat (with bend lines) instead of folded.
    var showFlat = false

    func startSheetMetal(model: DesignModel, editing feature: Feature? = nil) {
        command?.onCancel()
        if sketch != nil { exitSketch() }
        showFlat = false
        command = SheetMetalCommand.start(workspace: self, model: model, editing: feature)
    }

    /// LAMIERA from the sketch: the chosen closed shape (or the only one) becomes the sheet's
    /// base; the sides to bend are clicked on the part. Horizontal sketches only (the sheet lies
    /// on XY at the sketch's height).
    func sheetMetalFromSketch(model: DesignModel) {
        guard let sketch else { return }
        let plane = sketch.sketch.plane
        guard abs(abs(plane.normal.z) - 1) < 1e-9 else {
            model.statusMessage = "La lamiera nasce da uno schizzo orizzontale (piano XY o una faccia in piano)."
            return
        }
        guard let shape = sketch.extrudeCandidate?.profile?.points ?? (sketch.faces.count == 1 ? sketch.faces[0].outline : nil) else {
            model.statusMessage = "Seleziona il profilo chiuso da usare come base della lamiera."
            return
        }
        let world = shape.map { plane.world($0) }
        command?.onCancel()
        exitSketch()
        showFlat = false
        command = SheetMetalCommand.start(workspace: self, model: model, outline: world.map { Vec2($0.x, $0.y) }, at: world.first?.z ?? 0)
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

    func startExplode(model: DesignModel) {
        command?.onCancel()
        if sketch != nil { exitSketch() }
        let session = ExplodeCommand.start(workspace: self, model: model)
        command = session
        session.onPreview(session.fields)
    }
    func startJoint(model: DesignModel) {
        command?.onCancel()
        if sketch != nil { exitSketch() }
        command = JointCommand.start(workspace: self, model: model)
    }
    func startMove(model: DesignModel) {
        command?.onCancel()
        if sketch != nil { exitSketch() }
        command = MoveCommand.start(workspace: self, model: model)
    }
    func startCombine(model: DesignModel) {
        command?.onCancel()
        if sketch != nil { exitSketch() }
        command = CombineCommand.start(workspace: self, model: model)
    }
    func startShell(model: DesignModel) {
        command?.onCancel()
        if sketch != nil { exitSketch() }
        command = ShellCommand.start(workspace: self, model: model)
    }
    func startPressPull(model: DesignModel) {
        command?.onCancel()
        if sketch != nil { exitSketch() }
        command = PressPullCommand.start(workspace: self, model: model)
    }
    func startChamfer(model: DesignModel, editing feature: Feature? = nil, profile: ChamferSpec.Profile = .flat) {
        command?.onCancel()
        if sketch != nil { exitSketch() }
        command = ChamferCommand.start(workspace: self, model: model, editing: feature, profile: profile)
    }
    /// Active sketch (v0, UI-only). nil = not sketching.
    var sketch: SketchSession?
    /// Asks the viewport for a standard view (e.g. 3/4 when extruding, so the arrow can be dragged).
    var viewRequest: CameraController.StandardView?
    /// Asks the viewport to switch camera for sketch mode (true) or restore it (false).
    var sketchCameraRequest: Bool?
    /// Set by WorkspaceView: saved sketches and the model (for regenerating linked extrusions).
    @ObservationIgnored weak var sketchStore: SketchStore?
    @ObservationIgnored weak var model: DesignModel?

    /// Section view: the bodies cut by a plane square to X, Y or Z (0, 1, 2) at `sectionOffset`
    /// mm, the side beyond it taken away (the other side when flipped). Display only.
    var sectionAxis: Int?
    var sectionOffset = 0.0
    var sectionFlip = false
    var sectionPlane: SIMD4<Float> {
        guard let axis = sectionAxis else { return .zero }
        var n = SIMD3<Float>(repeating: 0)
        n[axis] = sectionFlip ? -1 : 1
        return SIMD4(n, Float(sectionFlip ? -sectionOffset : sectionOffset))
    }

    /// «Schizzo» waits for a click on a planar face (or a base plane).
    var pickingSketchPlane = false {
        didSet { if !pickingSketchPlane { planePickPoints = []; planePickFace = nil; geoHover = nil } }
    }
    /// How the construction plane is picked: a face (planar, or tangent to a round one), three
    /// points, or midway between two parallel faces.
    enum PlanePickMode: String, CaseIterable, Identifiable {
        case face = "Faccia", points = "3 punti", midway = "Medio"
        var id: String { rawValue }
    }
    var planePickMode = PlanePickMode.face
    /// Points clicked so far (3 punti), or the first face and its click point (Medio).
    var planePickPoints: [Vec3] = []
    var planePickFace: (origin: Vec3, normal: Vec3)?
    /// Construction plane: the chosen face or base plane moved along its normal (mm).
    var sketchPlaneOffset = 0.0
    /// Inclined construction plane: degrees about the chosen plane's X (or Y) axis.
    var sketchPlaneTilt = 0.0
    var sketchPlaneTiltAboutX = true
    /// Point the sketch camera centres on (the clicked face).
    var sketchFocus: Vec3?

    /// Starts a new sketch: on the selected planar face, else asks for one.
    func startSketch() {
        command?.onCancel(); command = nil
        if case let .face(id)? = geoSelection.first?.kind, let body = geoSelection.first.flatMap({ ref in
               model?.evaluation().bodies.first { $0.id == ref.feature } }),
           let (origin, normal) = body.snapshot.flatPlane(of: id) {
            enterSketch(plane: SketchPlane.onFace(point: origin, normal: normal), focus: origin)
            return
        }
        pickingSketchPlane = true
    }

    /// New sketch (on `plane`), or edit an existing saved one.
    func enterSketch(editing existing: Sketch? = nil, plane chosen: SketchPlane = .xy, focus: Vec3? = nil) {
        command?.onCancel(); command = nil
        var plane = chosen
        if existing == nil, pickingSketchPlane {
            if sketchPlaneTilt != 0 { plane = plane.tilted(by: sketchPlaneTilt, aboutX: sketchPlaneTiltAboutX) }
            if sketchPlaneOffset != 0 { plane = plane.offset(by: sketchPlaneOffset) }
        }
        pickingSketchPlane = false
        if sketch != nil { exitSketch() }
        let session = SketchSession(sketch: existing ?? Sketch(name: sketchStore?.nextName ?? "Schizzo 1", plane: plane))
        sketchFocus = existing.map { $0.plane.world(Vec2(0, 0)) } ?? focus
        if !session.sketch.plane.isXY, let model {
            session.projectReferences(from: model.evaluation().bodies.map(\.snapshot))
        }
        session.parameterValues = (try? model?.document.parameterValues()) ?? [:]
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
        sketch?.finish()   // a line still being drawn is kept
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

    func revolveSketch(model: DesignModel) {
        guard let sketch else { return }
        command?.onCancel()
        command = SketchCommands.revolve(sketch: sketch, model: model, workspace: self)
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
        if let f = model.document.features.first(where: { $0.id == id }), case let .pattern(p) = f.kind, p.placements == nil {
            command = PatternCommand.start(workspace: self, model: model, kind: p.kind, editing: f)
            return
        }
        if let f = model.document.features.first(where: { $0.id == id }), case .sheetMetal = f.kind {
            showFlat = false
            command = SheetMetalCommand.start(workspace: self, model: model, editing: f)
            return
        }
        if let f = model.document.features.first(where: { $0.id == id }), case .joint = f.kind {
            command = JointCommand.edit(f, model: model, workspace: self)
            return
        }
        if let f = model.document.features.first(where: { $0.id == id }), case .combine = f.kind {
            command = CombineCommand.start(workspace: self, model: model, editing: f)
            return
        }
        if let f = model.document.features.first(where: { $0.id == id }), case .move = f.kind {
            command = MoveCommand.start(workspace: self, model: model, editing: f)
            return
        }
        if let f = model.document.features.first(where: { $0.id == id }), case .shell = f.kind {
            command = ShellCommand.edit(f, workspace: self, model: model)
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
        case .revolve: "arrow.triangle.2.circlepath"
        case .shell: "cube.transparent"
        case .move: "arrow.up.and.down.and.arrow.left.and.right"
        case .joint: "link"
        case .combine: "square.on.square.intersection.dashed"
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
        case .revolve: "Rivoluzione"
        case .shell: "Guscio"
        case .move: "Sposta"
        case .joint: "Giunto"
        case .combine: "Combina"
        }
    }
}
