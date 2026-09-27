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

    /// A new, empty circuit: a 50 × 30 mm board, no components yet (the engine's empty document).
    func newCircuit(name: String = "Nuovo circuito") throws {
        document = try ElectronicsDocument.empty(name: name)
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
        // The subjects' identities first, else the component named in the subject.
        let ids = issue.subjectIDs ?? []
        selection = ids.first { id in components.contains { $0.id == id } }
            ?? components.first { issue.subject.contains($0.id.uuidString) }?.id
            ?? components.first { c in issue.subject.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).contains { $0 == c.reference } }?.id
    }

    /// One of the engine's commands (docs/electronics/EDITING.md): checked, one undo step, or
    /// refused whole with the engine's reason.
    @discardableResult
    func run(_ command: ElectronicsCommand, expectedRevision: UInt64? = nil) -> Bool {
        guard var doc = document else { return false }
        do {
            try ElectronicsCommands.apply(command, to: &doc, expectedRevision: expectedRevision ?? doc.revision)
            document = doc; isDirty = true
            refresh()
            return true
        } catch {
            report("\(command.title) non riuscito: \(Self.describe(error))")
            return false
        }
    }

    func placement(of component: UUID) -> ComponentPlacement? {
        design?.board.placements.first { $0.componentID == component }
    }

    func move(_ component: UUID, to position: PCBPoint) { run(.moveComponent(id: component, to: position)) }
    func rotate(_ component: UUID, by degrees: Double = 90) { run(.rotateComponent(id: component, by: degrees)) }
    func flip(_ component: UUID) { run(.flipComponent(component)) }

    func undo() {
        guard var doc = document else { return }
        do { try doc.undo(expectedRevision: doc.revision); document = doc; isDirty = true; refresh() } catch { report(Self.describe(error)) }
    }

    func redo() {
        guard var doc = document else { return }
        do { try doc.redo(expectedRevision: doc.revision); document = doc; isDirty = true; refresh() } catch { report(Self.describe(error)) }
    }

    // MARK: Building a circuit (T97, on the engine's commands of docs/electronics/EDITING.md)

    /// What a click on the board does.
    enum Tool: Equatable {
        case select
        /// Posa un componente: the next one to place (reference and value already chosen).
        case place(Placing)
        /// Collega: pads clicked two by two.
        case connect
    }

    /// A placing session: the same component identity and the same base revision from the
    /// previews to the click that confirms (EDITING.md: the confirmed command is the previewed
    /// one, at the revision it was previewed on); a new identity only after an insertion.
    struct Placing: Equatable {
        var device: LibraryRevision
        /// One of the engine's generic models (its library comes into the circuit with it).
        var starterID: String?
        var name: String
        var prefix: String
        var reference: String
        var value: String
        var side: BoardSide = .top
        var componentID = UUID()
        var baseRevision: UInt64 = 0
    }

    /// Starts placing `choice` (identity and base revision fixed for the session).
    func startPlacing(_ choice: DeviceChoice, reference: String, value: String) {
        tool = .place(.init(device: choice.key, starterID: choice.starterID, name: choice.name, prefix: choice.prefix,
                            reference: reference, value: value, baseRevision: document?.revision ?? 0))
    }

    var tool: Tool = .select { didSet { if tool != .connect { connectFrom = nil } } }
    /// Collega: the first pad chosen.
    var connectFrom: PlacedPad?
    /// Scheda: the outline being edited, drawn over the board until OK or Annulla.
    var boardPreview: [PCBPoint]?
    /// The CREA panels (Componente, Scheda).
    var showAddComponent = false
    var showBoard = false

    struct DeviceChoice: Identifiable, Hashable {
        var id: LibraryRevision { key }
        var key: LibraryRevision
        var starterID: String?
        var name: String
        var detail: String
        var prefix: String
        var defaultValue: String
    }

    /// What can be placed: the engine's generic models first (always there, even in a new
    /// circuit), then the devices of the circuit's own library.
    var deviceChoices: [DeviceChoice] {
        var out = ElectronicsStarterLibrary.components.map { t in
            DeviceChoice(key: t.device, starterID: t.id, name: t.name, detail: "Modello generico · verificare impronta e piedinatura",
                         prefix: t.referencePrefix, defaultValue: t.defaultValue)
        }
        guard let library = design?.library else { return out }
        for d in library.devices where !out.contains(where: { $0.key == d.key }) {
            let symbol = library.symbols.first { $0.key == d.symbol }?.name ?? "Componente"
            let footprint = library.footprints.first { $0.key == d.footprint }?.name ?? ""
            let prefix = String(symbol.first(where: \.isLetter) ?? "U").uppercased()
            out.append(DeviceChoice(key: d.key, starterID: nil, name: symbol,
                                    detail: [footprint, d.manufacturerPartNumber].filter { !$0.isEmpty }.joined(separator: " · "),
                                    prefix: prefix, defaultValue: ""))
        }
        return out
    }

    /// The first free reference with this prefix (R1, R2…), as the engine counts them.
    func nextReference(prefix: String) -> String {
        guard let design else { return prefix + "1" }
        return ElectronicsCommands.nextReference(prefix: prefix, in: design)
    }

    /// The command that places `p` at `position` (with its library when it is a generic model).
    func placeCommand(_ p: Placing, at position: PCBPoint) -> ElectronicsCommand {
        let id = p.componentID
        if let sid = p.starterID, let template = ElectronicsStarterLibrary.components.first(where: { $0.id == sid }) {
            return template.command(componentID: id, reference: p.reference, value: p.value.isEmpty ? nil : p.value, position: position, side: p.side)
        }
        let component = CircuitComponent(id: id, reference: p.reference, value: p.value, device: p.device)
        return .addComponent(component: component, placement: ComponentPlacement(componentID: id, position: position, side: p.side),
                             library: ElectronicsLibrary())
    }

    /// Posa: the pads the part would have there, from the engine's preview (nothing changes).
    func placementPreview(_ p: Placing, at position: PCBPoint) -> [PlacedPad] {
        guard let doc = document,
              let preview = try? ElectronicsCommands.preview(placeCommand(p, at: position), document: doc, expectedRevision: p.baseRevision)
        else { return [] }
        return preview.board.pads.filter { $0.componentID == p.componentID }
    }

    /// addComponent: the component and its placement in one step.
    /// Places the session's component (at the revision it was previewed on). After it goes in,
    /// the session goes on with a new identity, the next reference and the new revision; if the
    /// circuit changed meanwhile (an undo…), the engine refuses and the session restarts on it.
    @discardableResult
    func addComponent(_ p: Placing, at position: PCBPoint) -> UUID? {
        if design?.components.contains(where: { $0.reference.uppercased() == p.reference.uppercased() }) == true {
            report("La sigla \(p.reference) c'è già: scegline un'altra.")
            return nil
        }
        guard run(placeCommand(p, at: position), expectedRevision: p.baseRevision) else {
            if case var .place(session) = tool, session.componentID == p.componentID {
                session.baseRevision = document?.revision ?? 0
                tool = .place(session)
            }
            return nil
        }
        selection = p.componentID
        if case .place = tool {
            var next = p
            next.componentID = UUID()
            next.reference = nextReference(prefix: p.prefix)
            next.baseRevision = document?.revision ?? 0
            tool = .place(next)
        }
        return p.componentID
    }

    /// Collega: a click on a pad. Pins are told apart by component and pin (pads of one
    /// footprint share their IDs across the components using it).
    func connectClick(_ pad: PlacedPad) {
        guard let first = connectFrom else { connectFrom = pad; return }
        let a = PinReference(componentID: first.componentID, pinID: first.pinID)
        let b = PinReference(componentID: pad.componentID, pinID: pad.pinID)
        connectFrom = nil
        if a != b { connect(a, b) }
    }

    /// removeComponent: its placement and connections go with it (one step); the library stays.
    func removeComponent(_ id: UUID) {
        if run(.removeComponent(id)) { selection = nil }
    }

    /// connect: both pins on one net — the one either already has, or a new one. A pin already
    /// on another net is refused (no silent merging: disconnect it first).
    func connect(_ a: PinReference, _ b: PinReference) {
        guard a != b, let d = design else { return }
        func net(_ p: PinReference) -> UUID? { d.connections.first { $0.pin == p }?.netID ?? nil }
        let na = net(a), nb = net(b)
        if let na, let nb, na != nb {
            let names = [na, nb].map { id in d.nets.first { $0.id == id }?.name ?? "?" }
            let refs = [a, b].map { p in d.components.first { $0.id == p.componentID }?.reference ?? "?" }
            report("\(refs[0]) è sulla rete \(names[0]) e \(refs[1]) sulla rete \(names[1]): scollega uno dei due prima.")
            return
        }
        // The net either pin is already on, or a new one (N1, N2…); the engine makes it in the same step.
        let net: CircuitNet
        if let existing = (na ?? nb).flatMap({ id in d.nets.first { $0.id == id } }) {
            net = existing
        } else {
            var k = 1
            while d.nets.contains(where: { $0.name == "N\(k)" }) { k += 1 }
            net = CircuitNet(name: "N\(k)")
        }
        run(.connect(pins: [a, b], net: net))
    }

    /// setBoard: a rectangle from the origin, and the thickness.
    func setBoard(width: Double, height: Double, thickness: Double) {
        guard width > 0, height > 0, thickness > 0 else { report("Larghezza, altezza e spessore devono essere maggiori di zero."); return }
        let outline = [PCBPoint(0, 0), PCBPoint(width, 0), PCBPoint(width, height), PCBPoint(0, height)]
        run(.setBoard(outline: outline, thickness: thickness, assemblyOrigin: design?.board.assemblyOrigin ?? PCBPoint()))
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
        issues = ElectronicsValidation.integrity(d) + ElectronicsValidation.electrical(d) + ElectronicsCommands.genericIssues(d)
    }

    static func describe(_ error: Error) -> String {
        if let e = error as? CircuitEditError { return e.message }
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

/// A change the circuit refuses before reaching the engine (the engine's own checks come as
/// ElectronicsFailure).
struct CircuitEditError: Error {
    let message: String
    init(_ message: String) { self.message = message }
}
