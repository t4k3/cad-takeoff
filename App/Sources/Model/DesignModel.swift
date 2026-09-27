import AppKit
import CADCore
import Observation
import UniformTypeIdentifiers

/// A revision-consistent renderer result. Invalid bodies have explicit diagnostics.
struct DesignSnapshot: Equatable, Sendable {
    struct Issue: Equatable, Sendable {
        let featureID: UUID
        let message: String
    }
    let revision: String
    let bodies: [BodySnapshot]
    let issues: [Issue]
}

/// One undo history for every change to the design: manual edits, sketches, assistant tools.
struct EditHistory {
    enum Author { case user, assistant }
    struct Entry {
        var before: CADDocument
        var after: CADDocument
        let selectionBefore: UUID?
        var selectionAfter: UUID?
        var title: String
        var changed: [UUID]
        let author: Author
        var date = Date()
        /// Consecutive direct edits with the same key (same field of the same part) merge.
        var mergeKey: String? = nil
    }
    var undo: [Entry] = []
    var redo: [Entry] = []
    static let limit = 100
}

/// Something with its own short-lived undo (e.g. the sketch being edited) that ⌘Z should
/// address before the design history.
@MainActor
protocol LocalUndoTarget: AnyObject {
    var canUndoLocally: Bool { get }
    var canRedoLocally: Bool { get }
    var localUndoTitle: String? { get }
    var localRedoTitle: String? { get }
    func undoLocally()
    func redoLocally()
}

/// App-level state: the current CAD document plus UI selection. All mutations go through here.
@MainActor
@Observable
final class DesignModel {
    var document = CADDocument(features: [
        Feature(name: "Base", kind: .box(width: 40, depth: 30, height: 5)),
    ]) {
        didSet {
            guard document != oldValue else { return }
            designRevision = UUID().uuidString
            // Direct writes (inspector bindings, visibility…) are recorded too, so ⌘Z always works.
            if !applyingHistoryChange {
                // A size typed or dragged by hand replaces the expression that drove it.
                var fresh = document
                if fresh.dropStaleExpressions() { applyingHistoryChange = true; document = fresh; applyingHistoryChange = false }
                recordDirectEdit(from: oldValue)
            }
        }
    }
    private(set) var designRevision = UUID().uuidString
    private(set) var history = EditHistory()
    @ObservationIgnored var applyingHistoryChange = false
    /// Registered while the sketch editor is open: ⌘Z goes there first.
    weak var localUndoTarget: LocalUndoTarget?
    /// Commits work still open in an editor (e.g. the sketch) into the document, so saving,
    /// opening another file or quitting never silently drops it.
    @ObservationIgnored var finishPendingEdits: () -> Void = {}
    /// States after each unchanged history prefix, shared with the background previews.
    let evaluationCache = EvaluationCache()
    /// Reads assembly components from the project library (set by the app).
    @ObservationIgnored var componentResolver: DesignEvaluator.ComponentResolver?
    /// Designs of the project library as component paths (set by the app; for the assistant).
    @ObservationIgnored var projectDesigns: (() -> [String])?
    @ObservationIgnored private var cachedSnapshot: DesignSnapshot?
    @ObservationIgnored private var cachedFlat: (snapshot: DesignSnapshot, bends: [(Vec3, Vec3, SheetBendDirection, Bool)])?
    @ObservationIgnored private var cachedEvaluation: (revision: String, bodies: [DesignEvaluator.Body], issues: [DesignEvaluator.Issue])?
    var selection: Feature.ID?
    var statusMessage = "Pronto"

    var selectedIndex: Int? { document.features.firstIndex { $0.id == selection } }

    /// Topology comes from feature parameters in CADCore, never from viewport triangles.
    /// A document edit invalidates the cache through designRevision, including undo/reopen.
    func snapshot() -> DesignSnapshot {
        if let cachedSnapshot, cachedSnapshot.revision == designRevision { return cachedSnapshot }
        let e = evaluation()
        let result = DesignSnapshot(revision: designRevision,
                                    bodies: e.bodies.filter(\.isVisible).map(\.snapshot),
                                    issues: e.issues.map { .init(featureID: $0.featureID, message: $0.message) })
        cachedSnapshot = result
        return result
    }

    /// Bodies of the design after running the active history with its booleans (cached per revision).
    func evaluation() -> (bodies: [DesignEvaluator.Body], issues: [DesignEvaluator.Issue]) {
        if let c = cachedEvaluation, c.revision == designRevision { return (c.bodies, c.issues) }
        let (bodies, issues) = DesignEvaluator.evaluate(document, revision: designRevision, components: componentResolver, cache: evaluationCache)
        cachedEvaluation = (designRevision, bodies, issues)
        return (bodies, issues)
    }

    /// Bodies, triangles and volume of the visible bodies (status bar), once per revision:
    /// merging a million-triangle assembly on every redraw froze the window.
    func stats() -> (bodies: Int, triangles: Int, volume: Double) {
        if let c = cachedStats, c.revision == designRevision { return c.value }
        let visible = evaluation().bodies.filter(\.isVisible)
        let value = (visible.count, visible.reduce(0) { $0 + $1.mesh.triangleCount }, visible.reduce(0.0) { $0 + $1.mesh.volume })
        cachedStats = (designRevision, value)
        return value
    }
    @ObservationIgnored private var cachedStats: (revision: String, value: (bodies: Int, triangles: Int, volume: Double))?

    // MARK: Features

    func addBox() { add(Feature(name: "Box \(document.features.count + 1)", kind: .box(width: 20, depth: 20, height: 20))) }
    func addCylinder() { add(Feature(name: "Cilindro \(document.features.count + 1)", kind: .cylinder(radius: 10, height: 20))) }
    func addHexPrism() {
        add(Feature(name: "Esagono \(document.features.count + 1)",
                    kind: .extrude(profile: .regularPolygon(sides: 6, radius: 10), height: 10)))
    }

    private func add(_ f: Feature) {
        var next = document
        next.features.append(f)
        commitEdit(next, selected: f.id, title: "Aggiungi \(f.name)", changed: [f.id])
    }

    func deleteSelected() {
        guard let id = selection else { return }
        deleteStep(id)
        selection = nil
    }

    // MARK: Timeline (history)

    /// Moves the rollback marker: steps after `index` stay in the history but are not evaluated.
    func moveRollback(to index: Int) {
        let i = max(0, min(index, document.timeline.count))
        let target: Int? = i >= document.timeline.count ? nil : i
        guard target != document.rollback else { return }
        edit(target == nil ? "Marker alla fine" : "Marker dopo il passo \(i)") { $0.rollback = target }
    }

    func setSuppressed(_ id: UUID, _ suppressed: Bool) {
        guard let i = document.timeline.firstIndex(where: { $0.id == id }) else { return }
        let name = document.timeline[i].name
        edit(suppressed ? "Sopprimi \(name)" : "Ripristina \(name)") { $0.timeline[i].isSuppressed = suppressed }
    }

    /// Deletes one history step (solid, sketch or sheet-metal part). Links to it are dropped;
    /// solids made from a deleted sketch keep their last shape.
    func deleteStep(_ id: UUID) {
        guard let i = document.timeline.firstIndex(where: { $0.id == id }) else { return }
        let name = document.timeline[i].name
        edit("Elimina \(name)", selected: .some(selection == id ? nil : selection)) { doc in
            doc.timeline.remove(at: i)
            if let r = doc.rollback, i < r { doc.rollback = r - 1 }
            doc.sketchLinks.removeAll { $0.featureID == id || $0.sketchID == id }
        }
    }

    /// Applies `change` to a copy of the document as one undoable step.
    func edit(_ title: String, selected: UUID?? = nil, changed: [UUID] = [], _ change: (inout CADDocument) throws -> Void) rethrows {
        var next = document
        try change(&next)
        commitEdit(next, selected: selected ?? selection, title: title, changed: changed)
    }

    /// The inspector and the assistant use the same transaction history for colour edits.
    func setFeatureColor(_ id: UUID, color: PartColor) throws {
        guard let i = document.features.firstIndex(where: { $0.id == id }) else {
            throw CADToolFailure("Geometria non trovata.")
        }
        var next = document
        next.features[i].color = color
        commitEdit(next, selected: selection, title: "Colore: \(next.features[i].name)", changed: [id])
    }

    func commitEdit(_ next: CADDocument, selected: UUID?, title: String, changed: [UUID]) {
        var next = next
        next.dropStaleExpressions()
        guard next != document else { return }
        let author: EditHistory.Author = title.hasPrefix("Assistente") ? .assistant : .user
        push(EditHistory.Entry(before: document, after: next, selectionBefore: selection,
                               selectionAfter: selected, title: title, changed: changed, author: author))
        applyingHistoryChange = true
        document = next; selection = selected
        applyingHistoryChange = false
        statusMessage = title
    }

    /// Replaces the whole document (open, new): starts a fresh history.
    func replaceDocument(_ doc: CADDocument, status: String) {
        applyingHistoryChange = true
        document = doc
        applyingHistoryChange = false
        history = EditHistory()
        selection = nil
        statusMessage = status
    }

    func newDesign() { replaceDocument(CADDocument(), status: "Nuovo design") }

    // MARK: Tabs (several designs open, one shown)

    /// Everything that belongs to one open design, kept while another tab is shown: switching
    /// back is instant (the evaluation comes back with it, nothing is recomputed).
    struct Session {
        var document: CADDocument
        var history: EditHistory
        var selection: Feature.ID?
        var revision: String
        var evaluation: (revision: String, bodies: [DesignEvaluator.Body], issues: [DesignEvaluator.Issue])?
        var status: String
        /// The viewport's camera (opaque to the model).
        var view: Any?
    }

    /// Set by the workspace: closes an open command/sketch before another design is shown, and
    /// saves/restores the camera per tab.
    @ObservationIgnored var willSwitchDesign: () -> Void = {}
    @ObservationIgnored var captureView: () -> Any? = { nil }
    @ObservationIgnored var restoreView: (Any?) -> Void = { _ in }

    func captureSession() -> Session {
        Session(document: document, history: history, selection: selection, revision: designRevision,
                evaluation: cachedEvaluation, status: statusMessage, view: captureView())
    }

    func restoreSession(_ s: Session) {
        applyingHistoryChange = true
        document = s.document
        applyingHistoryChange = false
        history = s.history
        selection = s.selection
        designRevision = s.revision
        cachedEvaluation = s.evaluation
        statusMessage = s.status
        restoreView(s.view)
    }

    // MARK: Opening in the background

    /// A design being opened: its name and how many history steps are done (progress bar).
    struct Loading: Equatable { var name: String; var done: Int; var total: Int }
    private(set) var loading: Loading?

    /// Reads and evaluates a design off the main thread (a large Fusion assembly takes seconds),
    /// with progress in `loading`, then shows it without evaluating it again.
    func loadInBackground(from url: URL, completion: @escaping @MainActor (Result<Void, Error>) -> Void) {
        let name = url.deletingPathExtension().lastPathComponent
        loading = Loading(name: name, done: 0, total: 0)
        let revision = UUID().uuidString
        let components = componentResolver, cache = evaluationCache
        Task.detached(priority: .userInitiated) { [weak self] in
            do {
                let doc = try CADDocument.decode(Data(contentsOf: url))
                let total = doc.activeFeatures.count
                await MainActor.run { self?.loading = Loading(name: name, done: 0, total: total) }
                let (bodies, issues) = DesignEvaluator.evaluate(doc, revision: revision, components: components, cache: cache) { done, total in
                    Task { @MainActor in
                        guard let self, var l = self.loading, done > l.done else { return }
                        l.done = done; l.total = total
                        self.loading = l
                    }
                }
                await MainActor.run {
                    guard let self else { return }
                    self.replaceDocument(doc, status: "Aperto \(name)")
                    // The evaluation just made is the one for this document: no second pass.
                    self.designRevision = revision
                    self.cachedEvaluation = (revision, bodies, issues)
                    self.loading = nil
                    completion(.success(()))
                }
            } catch {
                await MainActor.run {
                    self?.loading = nil
                    completion(.failure(error))
                }
            }
        }
    }

    // MARK: Undo / Redo

    var canUndo: Bool { !history.undo.isEmpty }
    var canRedo: Bool { !history.redo.isEmpty }
    var undoTitle: String? { history.undo.last?.title }
    var redoTitle: String? { history.redo.last?.title }
    var lastEditAuthor: EditHistory.Author? { history.undo.last?.author }
    var nextRedoAuthor: EditHistory.Author? { history.redo.last?.author }

    @discardableResult
    func undo() -> EditHistory.Entry? {
        guard let entry = history.undo.popLast() else { return nil }
        apply(entry.before, selection: entry.selectionBefore)
        history.redo.append(entry)
        statusMessage = "Annullato: \(entry.title)"
        return entry
    }

    @discardableResult
    func redo() -> EditHistory.Entry? {
        guard let entry = history.redo.popLast() else { return nil }
        apply(entry.after, selection: entry.selectionAfter)
        history.undo.append(entry)
        statusMessage = "Ripetuto: \(entry.title)"
        return entry
    }

    private func apply(_ doc: CADDocument, selection sel: UUID?) {
        applyingHistoryChange = true
        document = doc
        applyingHistoryChange = false
        selection = sel.flatMap { id in doc.features.contains { $0.id == id } ? id : nil }
    }

    private func push(_ entry: EditHistory.Entry) {
        history.undo.append(entry)
        if history.undo.count > EditHistory.limit { history.undo.removeFirst() }
        history.redo.removeAll()
    }

    /// Records a write that bypassed `commitEdit`. Consecutive writes to the same thing
    /// within 1.5 s (typing in a field, dragging a slider) merge into one undo step.
    private func recordDirectEdit(from old: CADDocument) {
        let (title, key) = Self.describe(old, document)
        if var last = history.undo.last, last.author == .user, last.mergeKey == key, last.after == old,
           Date().timeIntervalSince(last.date) < 1.5 {
            last.after = document
            last.title = title
            last.date = Date()
            history.undo[history.undo.count - 1] = last
            history.redo.removeAll()
            return
        }
        push(EditHistory.Entry(before: old, after: document, selectionBefore: selection,
                               selectionAfter: selection, title: title, changed: [], author: .user, mergeKey: key))
    }

    /// Human title for a change ("Annulla <titolo>") and a merge key for consecutive edits.
    static func describe(_ old: CADDocument, _ new: CADDocument) -> (title: String, key: String?) {
        if old.rollback != new.rollback { return ("Sposta marker", nil) }
        for (o, n) in zip(old.timeline, new.timeline) where o.id == n.id && o.isSuppressed != n.isSuppressed {
            return (n.isSuppressed ? "Sopprimi \(n.name)" : "Ripristina \(n.name)", nil)
        }
        if new.features.count > old.features.count, let f = new.features.last { return ("Aggiungi \(f.name)", nil) }
        if new.features.count < old.features.count,
           let f = old.features.first(where: { o in !new.features.contains { $0.id == o.id } }) { return ("Elimina \(f.name)", nil) }
        for (o, n) in zip(old.features, new.features) where o != n {
            let id = n.id.uuidString
            if o.isVisible != n.isVisible, o.kind == n.kind, o.position == n.position {
                return (n.isVisible ? "Mostra \(n.name)" : "Nascondi \(n.name)", nil)
            }
            if o.color != n.color, o.kind == n.kind { return ("Colore: \(n.name)", "color:\(id)") }
            if o.name != n.name, o.kind == n.kind { return ("Rinomina \(n.name)", "name:\(id)") }
            if o.position != n.position, o.kind == n.kind { return ("Sposta \(n.name)", "position:\(id)") }
            return ("Modifica \(n.name)", "kind:\(id)")
        }
        if old.sketches != new.sketches || old.sketchLinks != new.sketchLinks { return ("Modifica schizzo", "sketch") }
        return ("Modifica", nil)
    }

    // MARK: Files

    static let ftkType = UTType(exportedAs: "com.takeoff.fusiontakeoff.design", conformingTo: .json)

    func saveWithPanel() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [Self.ftkType]
        panel.nameFieldStringValue = "Design.ftk"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try document.encoded().write(to: url)
            statusMessage = "Salvato \(url.lastPathComponent)"
        } catch { statusMessage = "Errore salvataggio: \(error.localizedDescription)" }
    }

    func openWithPanel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [Self.ftkType, .json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            replaceDocument(try CADDocument.decode(Data(contentsOf: url)), status: "Aperto \(url.lastPathComponent)")
        } catch { statusMessage = "Errore apertura: \(error.localizedDescription)" }
    }

    func exportSTLWithPanel() {
        let mesh = Mesh.merged(evaluation().bodies.filter(\.isVisible).map(\.mesh))
        guard !mesh.isEmpty else { statusMessage = "Niente da esportare"; return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "stl") ?? .data]
        panel.nameFieldStringValue = "Design.stl"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try STLExporter.binary(mesh).write(to: url)
            let r = MeshValidator.validate(mesh)
            statusMessage = "Esportato \(url.lastPathComponent) — \(mesh.triangleCount) triangoli, "
                + (r.isWatertight ? "chiuso ✓" : "NON chiuso (\(r.boundaryEdges) bordi aperti)")
        } catch { statusMessage = "Errore export: \(error.localizedDescription)" }
    }

    /// Technical drawing of the visible bodies (ISO first angle, hidden lines, overall dimensions,
    /// title block): PDF or DXF by the chosen extension; A4, or A3 when the part is large. The file
    /// name is the drawing's title.
    func exportDrawingWithPanel() {
        let bodies = evaluation().bodies.filter(\.isVisible).map { (mesh: $0.mesh, snapshot: $0.snapshot) }
        guard !bodies.isEmpty else { statusMessage = "Niente da disegnare"; return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf, UTType(filenameExtension: "dxf") ?? .data]
        panel.nameFieldStringValue = "Tavola.pdf"
        panel.message = "Tavola tecnica: .pdf per stampare, .dxf per altri CAD"
        let sectionBox = NSButton(checkboxWithTitle: "Vista di fronte in sezione A-A (pezzi torniti, fori interni)", target: nil, action: nil)
        panel.accessoryView = sectionBox
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let section = sectionBox.state == .on
        do {
            let info = TechnicalDrawing.Info(title: url.deletingPathExtension().lastPathComponent,
                                             material: sheetParts().first.map { $0.build.rule.material.name } ?? "")
            // A4 unless the part only fits it at 1:5 or smaller.
            var sheet = try TechnicalDrawing.make(bodies, info: info, format: .a4, section: section)
            if let scale = sheet.texts.first(where: { t in TechnicalDrawing.scales.contains { $0.1 == t.text } }),
               let value = TechnicalDrawing.scales.first(where: { $0.1 == scale.text })?.0, value <= 0.2 {
                sheet = try TechnicalDrawing.make(bodies, info: info, format: .a3, section: section)
            }
            if url.pathExtension.lowercased() == "dxf" {
                try DrawingDXF.dxf(sheet).write(to: url, atomically: true, encoding: .utf8)
            } else {
                try PDFWriter.pdf(sheet).write(to: url)
            }
            statusMessage = "Tavola salvata: \(url.lastPathComponent)"
        } catch { statusMessage = "Tavola non riuscita: \(error.localizedDescription)" }
    }

    /// STEP AP214 of the visible bodies (one solid each, with colours), for suppliers and other CAD.
    func exportSTEPWithPanel() {
        let parts = evaluation().bodies.filter(\.isVisible).map {
            STEPExporter.Part(name: $0.source.name, mesh: $0.mesh, snapshot: $0.snapshot, color: $0.source.color)
        }
        guard !parts.isEmpty else { statusMessage = "Niente da esportare"; return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "step") ?? .data]
        panel.nameFieldStringValue = "Design.step"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let name = url.deletingPathExtension().lastPathComponent
            try STEPExporter.export(parts, name: name).write(to: url, atomically: true, encoding: .utf8)
            statusMessage = "Esportato \(url.lastPathComponent) — \(parts.count) \(parts.count == 1 ? "solido" : "solidi") STEP AP214 in mm"
        } catch { statusMessage = "Errore export STEP: \(error.localizedDescription)" }
    }

    /// Export visible parts, or the explicit feature even when hidden. Does not change the scene.
    func export3MFData(featureID: UUID? = nil) throws -> Data {
        let all = evaluation().bodies
        let bodies: [DesignEvaluator.Body]
        if let featureID {
            guard let body = all.first(where: { $0.id == featureID }) else {
                throw CADToolFailure(document.features.contains { $0.id == featureID }
                    ? "Questa operazione non crea un corpo (taglio/unione): esporta il corpo che modifica."
                    : "Geometria non trovata.")
            }
            bodies = [body]
        } else { bodies = all.filter(\.isVisible) }
        let parts = try bodies.map { body -> ThreeMFPart in
            try CADToolValidation.mesh(body.mesh)
            return ThreeMFPart(id: body.id, name: body.source.name, mesh: body.mesh, color: body.source.color)
        }
        return try ThreeMFExporter.archive(parts: parts)
    }

    // MARK: Import (T74)

    /// STL, OBJ or 3MF (e.g. from Fusion 360): one imported body per part, one undo step.
    func importMesh(from url: URL) throws -> Int {
        let parts = try MeshImport.read(try Data(contentsOf: url), fileExtension: url.pathExtension)
        let base = url.deletingPathExtension().lastPathComponent
        let features = parts.enumerated().map { i, p in
            Feature(name: p.name.isEmpty ? (parts.count == 1 ? base : "\(base) \(i + 1)") : p.name,
                    kind: .importedMesh(ImportedMesh(mesh: p.mesh, source: url.lastPathComponent)))
        }
        edit("Importa \(url.lastPathComponent)", selected: .some(features.first?.id), changed: features.map(\.id)) {
            $0.features.append(contentsOf: features)
        }
        return features.count
    }

    func importMeshWithPanel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = ["stl", "obj", "3mf"].compactMap { UTType(filenameExtension: $0) }
        panel.message = "Importa una mesh (STL, OBJ o 3MF), ad esempio esportata da Fusion 360. Unità: millimetri (il 3MF dichiara le sue)."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let n = try importMesh(from: url)
            let issues = evaluation().issues.filter { i in document.features.suffix(n).contains { $0.id == i.featureID } }
            statusMessage = "Importat\(n == 1 ? "o" : "i") \(n) corp\(n == 1 ? "o" : "i") da \(url.lastPathComponent)"
                + (issues.isEmpty ? "" : " — " + (issues.first?.message ?? ""))
        } catch { statusMessage = "Import non riuscito: \(error.localizedDescription)" }
    }

    // MARK: Assemblies

    struct BOMRow: Identifiable {
        let path: String
        let name: String
        let quantity: Int
        /// Sheet metal: material and thickness; otherwise empty.
        let material: String
        /// One piece.
        let volume: Double
        /// One piece, when the material is known (sheet metal), in kg.
        let mass: Double?
        var id: String { path }
    }

    /// Bill of materials of the assembly: one row per referenced part, with quantities.
    func billOfMaterials() -> [BOMRow] {
        var order: [String] = [], count: [String: Int] = [:]
        for f in document.activeFeatures {
            guard case let .component(ref) = f.kind else { continue }
            if count[ref.path] == nil { order.append(ref.path) }
            count[ref.path, default: 0] += 1
        }
        return order.map { path in
            let part = componentResolver?(path)
            let bodies = part.map { DesignEvaluator.evaluate($0, revision: "bom", components: componentResolver).bodies.filter(\.isVisible) } ?? []
            let volume = bodies.reduce(0) { $0 + $1.mesh.volume }
            var materials: [String] = [], mass = 0.0, massKnown = false
            for f in part?.activeFeatures ?? [] {
                guard case let .sheetMetal(spec) = f.kind, let rule = try? spec.rule() else { continue }
                materials.append(spec.summary.components(separatedBy: " · ").first ?? spec.summary)
                if let body = bodies.first(where: { $0.id == f.id }) {
                    mass += body.mesh.volume * rule.material.density / 1_000_000; massKnown = true
                }
            }
            return BOMRow(path: path, name: ComponentRef(path: path).partName, quantity: count[path] ?? 0,
                          material: Array(Set(materials)).sorted().joined(separator: ", "), volume: volume, mass: massKnown ? mass : nil)
        }
    }

    func exportBOMWithPanel() {
        let rows = billOfMaterials()
        guard !rows.isEmpty else { statusMessage = "Nessun componente nell'assieme."; return }
        func field(_ s: String) -> String { "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }
        var csv = "Pos;Pezzo;Quantità;Materiale;Volume cad. (cm³);Massa cad. (kg);File\n"
        for (i, r) in rows.enumerated() {
            csv += "\(i + 1);\(field(r.name));\(r.quantity);\(field(r.material));"
                + String(format: "%.2f", r.volume / 1000).replacingOccurrences(of: ".", with: ",") + ";"
                + (r.mass.map { String(format: "%.3f", $0).replacingOccurrences(of: ".", with: ",") } ?? "") + ";\(field(r.path))\n"
        }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "csv") ?? .commaSeparatedText]
        panel.nameFieldStringValue = "Distinta base.csv"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try csv.write(to: url, atomically: true, encoding: .utf8)
            statusMessage = "Esportata \(url.lastPathComponent) (separatore ; per Excel italiano)"
        } catch { statusMessage = "Errore export distinta: \(error.localizedDescription)" }
    }

    // MARK: Sheet metal (T79)

    var hasSheetMetal: Bool { document.activeFeatures.contains { if case .sheetMetal = $0.kind { true } else { false } } }

    /// The design with every sheet-metal part developed flat (LAMIERA › Sviluppo), and the
    /// bend lines to draw on it. Cached per revision.
    func flatView() -> (snapshot: DesignSnapshot, bends: [(Vec3, Vec3, SheetBendDirection, Bool)]) {
        if let cachedFlat, cachedFlat.snapshot.revision == "flat-" + designRevision { return cachedFlat }
        let base = snapshot()
        var bodies = base.bodies
        var lines: [(Vec3, Vec3, SheetBendDirection, Bool)] = []
        for (f, _, flat, _) in sheetParts() {
            let snap: BodySnapshot
            if flat.holes.isEmpty {
                let plate = Feature(id: f.id, name: f.name, kind: .extrude(profile: Profile2D(points: flat.outline), height: flat.thickness),
                                    position: flat.origin)
                guard let brep = try? PrimitiveKernel.build(plate) else { continue }
                snap = brep.snapshot(revision: "flat-" + designRevision)
            } else {
                snap = SheetMetalGeometry.flatSolid(flat, id: f.id).bodySnapshot(bodyID: f.id, revision: "flat-" + designRevision).snapshot
            }
            if let i = bodies.firstIndex(where: { $0.bodyID == f.id }) { bodies[i] = snap } else { bodies.append(snap) }
            let z = flat.origin.z + flat.thickness + 0.02
            func p(_ v: Vec2) -> Vec3 { Vec3(v.x + flat.origin.x, v.y + flat.origin.y, z) }
            for b in flat.bends {
                lines.append((p(b.line.0), p(b.line.1), b.direction, true))
                for tl in b.tangents { lines.append((p(tl.0), p(tl.1), b.direction, false)) }
            }
        }
        let result = (DesignSnapshot(revision: "flat-" + designRevision, bodies: bodies, issues: base.issues), lines)
        cachedFlat = result
        return result
    }


    /// Active sheet-metal parts with their bending rule and flat pattern.
    /// Rule and flat pattern (with the holes drilled into the folded part) of each sheet part.
    /// The folded solid itself comes from `evaluation()`.
    func sheetParts() -> [(feature: Feature, build: SheetMetalBuild, flat: SheetFlatPattern, skippedHoles: Int)] {
        let bodies = evaluation().bodies
        return document.activeFeatures.compactMap { f in
            guard case let .sheetMetal(spec) = f.kind,
                  let build = try? SheetMetalGeometry.build(spec, featureID: f.id, position: f.position, folded: false) else { return nil }
            let cutters = bodies.first { $0.id == f.id }?.modifiedBy ?? []
            let holes = document.features.filter { cutters.contains($0.id) }.compactMap { h -> HoleSpec? in
                if case let .hole(spec) = h.kind { spec } else { nil }
            }
            let (flat, skipped) = build.flat(adding: holes)
            return (f, build, flat, skipped)
        }
    }

    /// DXF of a part's flat pattern (the selected part, or the only one).
    func flatPatternDXF(_ id: UUID? = nil) throws -> (name: String, dxf: String) {
        let parts = sheetParts()
        guard let part = id.flatMap({ id in parts.first { $0.feature.id == id } }) ?? (parts.count == 1 ? parts.first : nil) else {
            throw CADToolFailure(parts.isEmpty ? "Nessuna lamiera nel disegno." : "Seleziona la lamiera da sviluppare.")
        }
        return (part.feature.name, SheetMetalDXF.export(part.flat, rule: part.build.rule, name: part.feature.name))
    }

    func exportFlatDXFWithPanel(_ id: UUID? = nil) {
        do {
            let (name, dxf) = try flatPatternDXF(id)
            let panel = NSSavePanel()
            panel.allowedContentTypes = [UTType(filenameExtension: "dxf") ?? .data]
            panel.nameFieldStringValue = "\(name) - sviluppo.dxf"
            guard panel.runModal() == .OK, let url = panel.url else { return }
            try dxf.write(to: url, atomically: true, encoding: .utf8)
            let skipped = sheetParts().first { $0.feature.name == name }?.skippedHoles ?? 0
            statusMessage = "Esportato \(url.lastPathComponent) — taglio (CUT), fori e linee di piega, in mm"
                + (skipped > 0 ? " · \(skipped) for\(skipped == 1 ? "o" : "i") su pieghe o non passant\(skipped == 1 ? "e" : "i") non riportat\(skipped == 1 ? "o" : "i")" : "")
        } catch { statusMessage = "Errore export DXF: \(error.localizedDescription)" }
    }

    func export3MFWithPanel() {
        do {
            let data = try export3MFData()
            let panel = NSSavePanel()
            panel.allowedContentTypes = [UTType(filenameExtension: "3mf") ?? UTType(importedAs: "org.3mfconsortium.3mf", conformingTo: .data)]
            panel.nameFieldStringValue = "Design.3mf"
            guard panel.runModal() == .OK, let url = panel.url else { return }
            try data.write(to: url, options: .atomic)
            statusMessage = "Esportato \(url.lastPathComponent) — parti e colori; verificare i filamenti nello slicer"
        } catch { statusMessage = "Errore export 3MF: \(error.localizedDescription)" }
    }
}

extension DesignModel {
    /// New user parameters, with every dimension and size that uses them re-evaluated and the
    /// extrusions of the changed sketches regenerated, as one undoable step.
    func setParameters(_ parameters: [UserParameter], title: String = "Parametri") throws {
        try edit(title) { doc in
            doc.parameters = parameters
            for id in try doc.applyParameters() {
                if let s = doc.sketches.first(where: { $0.id == id }) { doc.regenerate(from: s) }
            }
        }
    }
}
