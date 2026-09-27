import AppKit
import ElectronicsCore
import Foundation
import Observation
import UniformTypeIdentifiers

/// «Circuiti»: the open circuit (an `ElectronicsDocument` of Codex's ElectronicsCore) and what the
/// workspace shows of it. Every change is one of the engine's transactions (checked, one undo
/// step, `expectedRevision`); nothing here recomputes pin maps, transforms or checks — the engine
/// does. A circuit is its own file (`.ftkc`) in the project, next to the CAD designs (`.ftk`).
@MainActor
@Observable
final class CircuitModel {
    static let fileType = UTType(exportedAs: "com.takeoff.fusiontakeoff.circuit", conformingTo: .json)

    private(set) var document: ElectronicsDocument?
    private(set) var url: URL?
    /// Pads where they are on the board, with their nets, and the connections still to route.
    private(set) var board: BoardConnectivity?
    /// Integrity and electrical checks of the current revision.
    private(set) var issues: [ElectronicsIssue] = []
    private(set) var isDirty = false
    /// The selected component (by identity, never by index).
    var selection: UUID?
    /// Status bar messages go through the design model's (one status line in the app).
    @ObservationIgnored var report: (String) -> Void = { _ in }

    var design: ElectronicsDesign? { document?.design }
    var canUndo: Bool { !(document?.past.isEmpty ?? true) }
    var canRedo: Bool { !(document?.future.isEmpty ?? true) }
    var title: String { url?.deletingPathExtension().lastPathComponent ?? design?.name ?? "Circuito" }

    // MARK: Files

    func open(_ url: URL) throws {
        let doc = try ElectronicsDocument.decode(Data(contentsOf: url))
        document = doc; self.url = url; isDirty = false
        refresh()
        report("Aperto \(url.deletingPathExtension().lastPathComponent) — \(summary)")
    }

    /// A new, empty circuit: a 50 × 30 mm board, no components yet.
    func newCircuit(name: String = "Nuovo circuito") throws {
        let outline = [PCBPoint(0, 0), PCBPoint(50, 0), PCBPoint(50, 30), PCBPoint(0, 30)]
        document = try ElectronicsDocument(design: ElectronicsDesign(name: name, library: ElectronicsLibrary(), board: PCBBoard(outline: outline)))
        url = nil; isDirty = true
        refresh()
        report("Nuovo circuito: scheda 50 × 30 mm")
    }

    func save(to target: URL? = nil) throws {
        guard let document, let destination = target ?? url else { return }
        try document.encoded().write(to: destination, options: .atomic)
        url = destination; isDirty = false
        report("Salvato \(destination.lastPathComponent)")
    }

    func openWithPanel() {
        guard confirmDiscard() else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [Self.fileType, .json]
        panel.message = "Apri un circuito (.ftkc)"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try open(url) } catch { report("Circuito non aperto: \(Self.describe(error))") }
    }

    func saveWithPanel(asNew: Bool = false) {
        guard document != nil else { return }
        if !asNew, url != nil { do { try save() } catch { report("Salvataggio non riuscito: \(Self.describe(error))") }; return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [Self.fileType]
        panel.nameFieldStringValue = title + ".ftkc"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try save(to: url) } catch { report("Salvataggio non riuscito: \(Self.describe(error))") }
    }

    /// The example circuit of the engine's tests (synthetic parts: not for manufacture).
    func openExample() {
        guard confirmDiscard(), let url = Bundle.main.url(forResource: "Esempio circuito", withExtension: "ftkc") else { return }
        do {
            try open(url)
            self.url = nil   // a copy: «Salva» asks where
        } catch { report("Esempio non aperto: \(Self.describe(error))") }
    }

    /// Unsaved changes: ask before throwing them away.
    func confirmDiscard() -> Bool {
        guard isDirty, document != nil else { return true }
        let alert = NSAlert()
        alert.messageText = "Il circuito «\(title)» ha modifiche non salvate."
        alert.informativeText = "Se continui, le modifiche vanno perse."
        alert.addButton(withTitle: "Salva")
        alert.addButton(withTitle: "Non salvare")
        alert.addButton(withTitle: "Annulla")
        switch alert.runModal() {
        case .alertFirstButtonReturn: saveWithPanel(); return !isDirty
        case .alertSecondButtonReturn: return true
        default: return false
        }
    }

    // MARK: Edits (engine transactions)

    /// Applies one change as one undo step; the engine refuses it whole if it breaks the design.
    @discardableResult
    func edit(_ title: String, _ change: (inout ElectronicsDesign) throws -> Void) -> Bool {
        guard var doc = document else { return false }
        do {
            try doc.edit(title: title, expectedRevision: doc.revision, change)
            document = doc; isDirty = true
            refresh()
            return true
        } catch {
            report("\(title) non riuscito: \(Self.describe(error))")
            return false
        }
    }

    /// Selects the component a check is about (if it names one).
    func select(_ issue: ElectronicsIssue) {
        guard let components = design?.components else { return }
        // The engine is adding the subjects' identities to its issues (`subjectIDs`): read them
        // when present, else find the component named in the subject (its reference or UUID).
        let ids = Mirror(reflecting: issue).children.first { $0.label == "subjectIDs" }.flatMap { $0.value as? [UUID] } ?? []
        selection = ids.first { id in components.contains { $0.id == id } }
            ?? components.first { issue.subject.contains($0.id.uuidString) }?.id
            ?? components.first { c in issue.subject.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).contains { $0 == c.reference } }?.id
    }

    func placement(of component: UUID) -> ComponentPlacement? {
        design?.board.placements.first { $0.componentID == component }
    }

    func move(_ component: UUID, to position: PCBPoint) {
        let name = design?.components.first { $0.id == component }?.reference ?? "componente"
        edit("Sposta \(name)") { d in
            guard let i = d.board.placements.firstIndex(where: { $0.componentID == component }) else { return }
            d.board.placements[i].position = position
        }
    }

    func rotate(_ component: UUID, by degrees: Double = 90) {
        let name = design?.components.first { $0.id == component }?.reference ?? "componente"
        edit("Ruota \(name)") { d in
            guard let i = d.board.placements.firstIndex(where: { $0.componentID == component }) else { return }
            var a = (d.board.placements[i].rotationDegrees + degrees).truncatingRemainder(dividingBy: 360)
            if a < 0 { a += 360 }
            d.board.placements[i].rotationDegrees = a
        }
    }

    func flip(_ component: UUID) {
        let name = design?.components.first { $0.id == component }?.reference ?? "componente"
        edit("Sposta \(name) sull'altro lato") { d in
            guard let i = d.board.placements.firstIndex(where: { $0.componentID == component }) else { return }
            d.board.placements[i].side = d.board.placements[i].side == .top ? .bottom : .top
        }
    }

    func undo() {
        guard var doc = document else { return }
        do { try doc.undo(expectedRevision: doc.revision); document = doc; isDirty = true; refresh() } catch { report(Self.describe(error)) }
    }

    func redo() {
        guard var doc = document else { return }
        do { try doc.redo(expectedRevision: doc.revision); document = doc; isDirty = true; refresh() } catch { report(Self.describe(error)) }
    }

    // MARK: Manufacturing

    /// JLCPCB BOM and pick-and-place files (CSV) into a chosen folder. The engine refuses when
    /// something is missing (a position, a JLC code, a side calibration) and says what.
    func exportJLCWithPanel() {
        guard let document else { return }
        let assembly: AssemblyData
        do { assembly = try ElectronicsAssembly.export(document) } catch {
            report("Export JLCPCB non riuscito: \(Self.describe(error))")
            if let failure = error as? ElectronicsFailure { issues = failure.issues }
            return
        }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.canCreateDirectories = true
        panel.prompt = "Esporta qui"
        panel.message = "Cartella per BOM e CPL JLCPCB di «\(title)»"
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        do {
            try assembly.bomCSV.write(to: folder.appendingPathComponent("\(title) - BOM.csv"), atomically: true, encoding: .utf8)
            try assembly.cplCSV.write(to: folder.appendingPathComponent("\(title) - CPL.csv"), atomically: true, encoding: .utf8)
            report("BOM e CPL JLCPCB salvati in \(folder.lastPathComponent) — da verificare nel visore JLC prima di ordinare")
        } catch { report("Scrittura non riuscita: \(error.localizedDescription)") }
    }

    // MARK: State

    var summary: String {
        guard let d = design else { return "" }
        let errors = issues.filter { $0.severity == .error }.count, warnings = issues.count - errors
        var s = "\(d.components.count) componenti, \(d.nets.count) reti"
        if let b = board { s += ", \(b.airwires.count) collegamenti da sbrogliare" }
        if errors > 0 { s += " · \(errors) error\(errors == 1 ? "e" : "i")" }
        if warnings > 0 { s += " · \(warnings) avvis\(warnings == 1 ? "o" : "i")" }
        return s
    }

    private func refresh() {
        guard let d = design else { board = nil; issues = []; return }
        board = try? ElectronicsConnectivity.snapshot(d)
        issues = ElectronicsValidation.integrity(d) + ElectronicsValidation.electrical(d)
    }

    static func describe(_ error: Error) -> String {
        if let f = error as? ElectronicsFailure { return f.issues.map { "\($0.subject): \($0.message)" }.joined(separator: " · ") }
        return error.localizedDescription
    }
}

/// ⌘Z / ⇧⌘Z in the CIRCUITI tab: the circuit's own history (the engine's undo/redo).
extension CircuitModel: LocalUndoTarget {
    var canUndoLocally: Bool { canUndo }
    var canRedoLocally: Bool { canRedo }
    var localUndoTitle: String? { document?.past.last?.title }
    var localRedoTitle: String? { document?.future.last?.title }
    func undoLocally() { undo() }
    func redoLocally() { redo() }
}
