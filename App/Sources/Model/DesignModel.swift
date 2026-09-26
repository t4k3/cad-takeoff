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
            if !applyingHistoryChange { recordDirectEdit(from: oldValue) }
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
    @ObservationIgnored private var cachedSnapshot: DesignSnapshot?
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
        let (bodies, issues) = DesignEvaluator.evaluate(document, revision: designRevision)
        cachedEvaluation = (designRevision, bodies, issues)
        return (bodies, issues)
    }

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
