import AppKit
import CryptoKit
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
    /// Pads where they are on the board, with their nets, and the connections still to route
    /// (from the copper drawing `pcb`, built off the main thread: the last one until the new is ready).
    var board: BoardConnectivity? { pcb?.board }
    /// Integrity and electrical checks of the current revision, then the copper's (DRC) when
    /// its drawing is ready.
    var issues: [ElectronicsIssue] { baseIssues + (pcbIsCurrent ? pcb?.issues ?? [] : []) }
    private(set) var baseIssues: [ElectronicsIssue] = []
    private(set) var isDirty = false
    /// The selected component (by identity, never by index; the same on schematic and PCB).
    var selection: UUID?

    /// Schema or PCB on the canvas.
    enum Canvas: String, CaseIterable, Identifiable { case schematic = "Schema", board = "PCB"; var id: String { rawValue } }
    var canvas: Canvas = .schematic { didSet { if canvas != oldValue { tool = .select; schematicTool = .select } } }
    /// The sheet chosen (see `currentSheetID`), the drawing kept for it, the schematic tool and
    /// the object selected on it, and the wire being drawn.
    var chosenSheet: UUID? { didSet { refreshSchematic() } }
    /// The drawing of the sheet shown: built off the main thread for each revision and sheet
    /// (a big sheet takes long); `schematicIsCurrent` says whether it matches the document yet —
    /// picks and snaps only use it then.
    var schematic: SchematicSnapshot?
    @ObservationIgnored var schematicTask: Task<Void, Never>?
    var schematicTool: SchematicTool = .select {
        didSet {
            if schematicTool != .wire { wireStart = nil; wireBends = [] }
            prepareSchematicGhost()
        }
    }
    /// Posa: the symbol being placed as drawn at the origin (moved under the mouse by the view),
    /// from one engine preview per placing session, made off the main thread.
    var schematicGhost: [SchematicPrimitive] = []
    @ObservationIgnored var ghostTask: Task<Void, Never>?
    /// The placing session, revision and sheet the ghost was made for (any change: a new one).
    @ObservationIgnored var ghostSession: GhostKey?
    /// PCB posa: the pads of the part being placed (the engine's exact copper), at the origin, the same way.
    private(set) var boardGhost: [PCBCopperPrimitive] = []
    @ObservationIgnored var boardGhostSession: GhostKey?
    @ObservationIgnored var boardGhostTask: Task<Void, Never>?
    func boardGhostReady() async { await boardGhostTask?.value }
    /// PCB: the copper drawing (pads, tracks, vias, DRC, airwires) of a revision, built off the
    /// main thread; picks and snaps use it only while `pcbIsCurrent`.
    var pcb: PCBSnapshot?
    @ObservationIgnored var pcbTask: Task<Void, Never>?
    /// The copper layer being drawn on (0 = top, layerCount − 1 = bottom).
    var activeLayer = 0
    /// Pista: the route being drawn, the leg to the mouse, and whether the engine would take it.
    var route: Route?
    var routeCheck: RouteCheck?
    @ObservationIgnored var routeCheckTask: Task<Void, Never>?
    /// The next leg bends diagonally first (else straight first); / switches.
    var diagonalFirst = true
    /// A track or via selected on the board.
    var copperSelection: PCBItem?
    /// Which open document the drawings belong to (another file may have the same design and revision).
    @ObservationIgnored var documentEpoch = 0
    /// Where the copper check chosen in VERIFICHE is (a ring on the board).
    var issueMark: PCBPoint?
    /// Area vietata: the outline being drawn (its points so far), and the area selected.
    var keepoutDraft: KeepoutDraft?
    var keepoutSelection: UUID?
    /// What the engine says of a rule change before it is confirmed (an area being drawn or
    /// moved, a class being edited): checked in the background, the last request wins.
    var ruleCheck: RuleCheck?
    @ObservationIgnored var ruleCheckTask: Task<Void, Never>?
    /// The CLASSI panel, and the rules the engine resolves for every net (one pass per revision,
    /// off the main thread: each resolution validates the whole document).
    var showNetClasses = false
    var netRules: NetRulesCache?
    @ObservationIgnored var netRulesTask: Task<Void, Never>?
    var schematicSelection: SchematicObject?
    var wireStart: WireEnd?
    var wireBends: [PCBPoint] = []
    /// Etichetta: the terminal being named (the name panel is open).
    var labelTarget: SchematicTerminal?
    /// The circuit's own last message (the status bar shows it in CIRCUITI, never the CAD's).
    var message = ""
    /// Where messages go: set by the workspace to `message` (tests read them here).
    @ObservationIgnored var report: (String) -> Void = { _ in }

    var design: ElectronicsDesign? { document?.design }
    var canUndo: Bool { !(document?.past.isEmpty ?? true) }
    var canRedo: Bool { !(document?.future.isEmpty ?? true) }
    var title: String { url?.deletingPathExtension().lastPathComponent ?? design?.name ?? "Circuito" }

    // MARK: Files

    func open(_ given: URL) throws {
        // A file reference (from the open panel) as its path: a save replaces the file, and a
        // reference to the old one no longer resolves.
        let url = (given as NSURL).filePathURL ?? given
        let data: Data
        do { data = try Data(contentsOf: url) } catch { throw CircuitEditError(Self.readFailure(url, error)) }
        let doc: ElectronicsDocument
        do { doc = try ElectronicsDocument.decode(data) } catch is DecodingError {
            // Another JSON (the panel shows .json too): not a circuit, said so.
            throw CircuitEditError("«\(url.deletingPathExtension().lastPathComponent)» non è un circuito di CAD Takeoff (.ftkc): scegli un file di circuito.")
        }
        forgetDrawings()
        document = doc; self.url = url; isDirty = false
        refresh()
        report("Aperto \(url.deletingPathExtension().lastPathComponent) — \(summary)")
    }

    /// A new, empty circuit: a 50 × 30 mm board, no components yet (the engine's empty document).
    func newCircuit(name: String = "Nuovo circuito") throws {
        let doc = try ElectronicsDocument.empty(name: name)
        forgetDrawings()
        document = doc
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
        // From the current circuit's folder: its listing is read again (after a save the file is a new one).
        if let url { panel.directoryURL = url.deletingLastPathComponent() }
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
            // Done: its name replaces an older refusal in the status bar.
            report(title)
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
        issueMark = issue.code.hasPrefix("pcb_") ? issue.position : nil
        if issueMark != nil { canvas = .board }
        // A track or via (DRC): that copper.
        if let copper = design?.board.copper {
            if let t = ids.first(where: { id in copper.tracks.contains { $0.id == id } }) { copperSelection = .track(t); canvas = .board; return }
            if let v = ids.first(where: { id in copper.vias.contains { $0.id == id } }) { copperSelection = .via(v); canvas = .board; return }
        }
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
            // Done: its name replaces an older refusal in the status bar.
            report(command.title)
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
        /// A component of the circuit (drawn on the schematic) still to put on the board.
        case placeExisting(UUID)
        /// Pista: copper from a pad, via or track of a net, leg by leg (CircuitModel+PCB).
        case route
        /// Area vietata: an outline clicked point by point on the layer being drawn on (CircuitModel+Rules).
        case keepout
    }

    /// PCB: puts a component that has no board position yet (from the schematic) where clicked.
    func placeExistingOnBoard(_ id: UUID, at position: PCBPoint) {
        if run(.placeComponent(ComponentPlacement(componentID: id, position: position))) {
            selection = id
            // The next one still to place, if any.
            if let next = unplacedComponents.first { tool = .placeExisting(next) } else { tool = .select }
        }
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

    var tool: Tool = .select {
        didSet {
            if tool != .connect { connectFrom = nil }
            if tool != .route { route = nil }
            if tool != .keepout { keepoutDraft = nil; ruleCheck = nil }
            prepareBoardGhost()
        }
    }
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

    struct GhostKey: Equatable { var component: UUID; var revision: UInt64; var sheet: UUID? }

    /// Work off the main thread whose cancellation reaches the work itself (not only its result).
    nonisolated static func offMain<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
        let worker = Task.detached(priority: .userInitiated, operation: work)
        return await withTaskCancellationHandler { await worker.value } onCancel: { worker.cancel() }
    }

    /// PCB posa: one preview per placing session (and revision), at the origin, off the main
    /// thread; the view moves the pads under the mouse.
    func prepareBoardGhost() {
        guard case let .place(p) = tool else { boardGhostTask?.cancel(); boardGhost = []; boardGhostSession = nil; return }
        let key = GhostKey(component: p.componentID, revision: p.baseRevision, sheet: nil)
        guard boardGhostSession != key else { return }
        boardGhostSession = key
        boardGhost = []
        boardGhostTask?.cancel()
        guard let doc = document else { return }
        let command = placeCommand(p, at: PCBPoint()), id = p.componentID, base = p.baseRevision
        boardGhostTask = Task { [weak self] in
            let pads = await Self.offMain { () -> [PCBCopperPrimitive] in
                guard let preview = try? ElectronicsCommands.preview(command, document: doc, expectedRevision: base),
                      let drawing = try? preview.pcbSnapshot() else { return [] }
                return drawing.primitives.filter { if case let .pad(c, _) = $0.item { c == id } else { false } }
            }
            guard !Task.isCancelled, let self, self.boardGhostSession == key else { return }
            self.boardGhost = pads
        }
    }

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

    // MARK: Libraries (docs/electronics/LIBRARIES.md)

    /// An import waiting for OK: the engine's proposal and its preview (what the circuit's library
    /// would become, and the warnings). OK applies it at the revision it was previewed on.
    struct ImportProposal {
        var fileName: String
        var command: ElectronicsLibraryCommand
        var preview: LibraryCommandPreview
        var symbols: [SymbolDefinition]
        var footprints: [FootprintDefinition]
    }
    var importProposal: ImportProposal?
    var showCreateDevice = false
    /// A KiCad symbol library with several symbols: which one to import.
    var symbolChoice: (url: URL, names: [String])?

    /// LIBRERIA › Importa: a KiCad footprint (.kicad_mod) or symbol library (.kicad_sym), or an
    /// EasyEDA Standard footprint (.json); then the preview panel.
    func importWithPanel() {
        guard document != nil else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = ["kicad_mod", "kicad_sym", "json"].compactMap { UTType(filenameExtension: $0) }
        panel.message = "Importa un'impronta KiCad (.kicad_mod), un simbolo KiCad (.kicad_sym) o un'impronta EasyEDA Standard (.json)"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard Self.libraryFile(url) == .kicadSymbols else { prepareImport(url); return }
        let names = (try? Data(contentsOf: url)).map(Self.kicadSymbolNames) ?? []
        if names.count == 1 { prepareImport(url, symbol: names[0]) }
        else if names.isEmpty { report("Nessun simbolo trovato in \(url.lastPathComponent)") }
        else { symbolChoice = (url, names) }
    }

    enum LibraryFile { case kicadFootprint, kicadSymbols, easyedaFootprint }

    static func libraryFile(_ url: URL) -> LibraryFile? {
        switch url.pathExtension.lowercased() {
        case "kicad_mod": .kicadFootprint
        case "kicad_sym": .kicadSymbols
        case "json": .easyedaFootprint
        default: nil
        }
    }

    /// The symbols of a KiCad symbol library, to choose one (top-level names; the engine checks
    /// the chosen one). TODO: the engine's own listing when it offers one (RICHIESTA-API).
    static func kicadSymbolNames(_ data: Data) -> [String] {
        let text = String(decoding: data, as: UTF8.self)
        var names: [String] = []
        var depth = 0, i = text.startIndex
        while i < text.endIndex {
            let ch = text[i]
            if ch == "(" {
                depth += 1
                if depth == 2, text[i...].hasPrefix("(symbol \""),
                   let open = text[i...].firstIndex(of: "\""), let close = text[text.index(after: open)...].firstIndex(of: "\"") {
                    names.append(String(text[text.index(after: open)..<close]))
                }
            } else if ch == ")" {
                depth -= 1
            } else if ch == "\"" {
                // Skip quoted strings (they may hold parentheses).
                var j = text.index(after: i)
                while j < text.endIndex, text[j] != "\"" { if text[j] == "\\" { j = text.index(after: j) }; if j < text.endIndex { j = text.index(after: j) } }
                i = j
            }
            if i < text.endIndex { i = text.index(after: i) }
        }
        return names
    }

    /// Reads a library file and prepares its import (nothing changes until `confirmImport`).
    func prepareImport(_ url: URL, symbol: String? = nil) {
        guard let doc = document, let kind = Self.libraryFile(url) else { return }
        do {
            let data = try Data(contentsOf: url)
            let name = symbol ?? url.deletingPathExtension().lastPathComponent
            let key = libraryKey(for: url.lastPathComponent + "|" + name, data: data)
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
                .map { ISO8601DateFormatter().string(from: $0) } ?? ""
            let context = LibraryImportContext(key: key, source: LibrarySource(reference: url.path, license: "da verificare", sourceRevision: modified))
            let result: LibraryImportResult = switch kind {
            case .kicadFootprint: try KiCadLibraryImporter.footprint(data, context: context)
            case .kicadSymbols: try KiCadLibraryImporter.symbol(data, name: name, context: context)
            case .easyedaFootprint: try EasyEDAStandardImporter.footprint(data, name: name, context: context)
            }
            let command = ElectronicsLibraryCommand.importLibrary(result)
            let preview = try ElectronicsLibraryCommands.preview(command, document: doc, expectedRevision: doc.revision)
            importProposal = ImportProposal(fileName: url.lastPathComponent, command: command, preview: preview,
                                            symbols: result.library.symbols, footprints: result.library.footprints)
        } catch {
            report("Import di \(url.lastPathComponent) non riuscito: \(Self.describe(error))")
        }
    }

    func confirmImport() {
        guard let p = importProposal, var doc = document else { return }
        importProposal = nil
        do {
            try ElectronicsLibraryCommands.apply(p.command, to: &doc, expectedRevision: p.preview.baseRevision)
            document = doc; isDirty = true
            refresh()
            let what = (p.symbols.map { "simbolo \($0.name)" } + p.footprints.map { "impronta \($0.name)" }).joined(separator: ", ")
            report("Importato \(what)" + (p.preview.issues.isEmpty ? "" : " · \(p.preview.issues.count) avvisi da controllare"))
        } catch {
            report("Import non riuscito: \(Self.describe(error))")
        }
    }

    /// The library identity of a file's content: the same file keeps its UUID; changed content
    /// gets the next revision, identical content the one it already has (a no-op re-import).
    private func libraryKey(for name: String, data: Data) -> LibraryRevision {
        let id = Self.stableUUID(name)
        let digest = Self.sha256(data)
        let library = design?.library
        let existing: [(Int, String?)] = (library?.symbols.filter { $0.key.id == id }.map { ($0.key.revision, $0.source.contentSHA256) } ?? [])
            + (library?.footprints.filter { $0.key.id == id }.map { ($0.key.revision, $0.source.contentSHA256) } ?? [])
        if let same = existing.first(where: { $0.1 == digest }) { return LibraryRevision(id: id, revision: same.0) }
        return LibraryRevision(id: id, revision: (existing.map(\.0).max() ?? 0) + 1)
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func stableUUID(_ text: String) -> UUID {
        var bytes = Array(SHA256.hash(data: Data(text.utf8)).prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x50; bytes[8] = (bytes[8] & 0x3F) | 0x80   // version 5 style
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }

    /// Crea componente: the pin ↔ pad pairing the engine suggests for a symbol and a footprint
    /// (by pin and pad numbers; to check on the datasheet), or why it cannot.
    func suggestedPinMap(symbol: LibraryRevision, footprint: LibraryRevision) -> Result<[PinPadMapping], Error> {
        guard let lib = design?.library, let s = lib.symbols.first(where: { $0.key == symbol }),
              let f = lib.footprints.first(where: { $0.key == footprint }) else { return .failure(CircuitEditError("Scegli un simbolo e un'impronta.")) }
        return Result { try ElectronicsLibraryCommands.suggestedPinMap(symbol: s, footprint: f) }
    }

    @discardableResult
    func createDevice(symbol: LibraryRevision, footprint: LibraryRevision, manufacturer: String, partNumber: String,
                      pinMap: [PinPadMapping]) -> Bool {
        guard var doc = document else { return false }
        // Left empty: a generic type, named after what it joins (not a part to buy).
        let lib = doc.design.library
        let described = [lib.symbols.first { $0.key == symbol }?.name, lib.footprints.first { $0.key == footprint }?.name]
            .compactMap { $0 }.joined(separator: " · ")
        let maker = manufacturer.trimmingCharacters(in: .whitespaces), code = partNumber.trimmingCharacters(in: .whitespaces)
        let device = DeviceDefinition(manufacturer: maker.isEmpty ? "Generico" : maker, manufacturerPartNumber: code.isEmpty ? described : code,
                                      symbol: symbol, footprint: footprint, pinMap: pinMap)
        do {
            let preview = try ElectronicsLibraryCommands.preview(.createDevice(device), document: doc, expectedRevision: doc.revision)
            try ElectronicsLibraryCommands.apply(.createDevice(device), to: &doc, expectedRevision: preview.baseRevision)
            document = doc; isDirty = true
            refresh()
            report("Componente pronto da posare: CREA › Componente")
            return true
        } catch {
            report("Componente non creato: \(Self.describe(error))")
            return false
        }
    }

    // MARK: Manufacturing

    /// JLCPCB BOM and pick-and-place files (CSV) into a chosen folder. The engine refuses when
    /// something is missing (a position, a JLC code, a side calibration) and says what.
    func exportJLCWithPanel() {
        guard let document else { return }
        let assembly: AssemblyData
        do { assembly = try ElectronicsAssembly.export(document) } catch {
            report("Export JLCPCB non riuscito: \(Self.describe(error))")
            if let failure = error as? ElectronicsFailure { baseIssues = failure.issues }
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

    func refresh() {
        // Sessions made on another revision are over (an undo, a change elsewhere).
        if let r = route, r.baseRevision != document?.revision { route = nil; routeCheck = nil }
        if let k = keepoutDraft, k.baseRevision != document?.revision { keepoutDraft = nil }
        if let c = ruleCheck, c.revision != document?.revision { ruleCheckTask?.cancel(); ruleCheck = nil }
        refreshSchematic()
        refreshPCB()
        guard let d = design else { baseIssues = []; return }
        baseIssues = ElectronicsValidation.integrity(d) + ElectronicsValidation.electrical(d) + ElectronicsCommands.genericIssues(d)
    }

    /// Why a circuit file could not be read, in words to act on.
    nonisolated static func readFailure(_ url: URL, _ error: Error) -> String {
        let name = "«\(url.deletingPathExtension().lastPathComponent)»"
        switch (error as? CocoaError)?.code {
        case .fileReadNoSuchFile?, .fileNoSuchFile?:
            return "\(name) non si trova più lì: forse è stato salvato di nuovo o spostato. Riaprilo dalla sua cartella (in Apri, ⇧⌘G per scrivere il percorso)."
        case .fileReadNoPermission?:
            return "Non ho il permesso di leggere \(name): aprilo con Apri, dalla sua cartella."
        default:
            return "\(name) non si legge: \(error.localizedDescription)"
        }
    }

    nonisolated static func describe(_ error: Error) -> String {
        if let e = error as? CircuitEditError { return e.message }
        if let f = error as? ElectronicsFailure {
            return f.issues.map { $0.subject.isEmpty ? $0.message : "\($0.subject): \($0.message)" }.joined(separator: " · ")
        }
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
