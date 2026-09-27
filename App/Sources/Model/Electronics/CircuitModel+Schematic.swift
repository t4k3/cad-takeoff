import ElectronicsCore
import Foundation

/// The schematic of «Circuiti» (Codex's engine, docs/electronics/SCHEMATIC.md): the sheet shown,
/// its drawing (the engine's snapshot, kept per revision and sheet), and the drawing tools. Every
/// change is an engine command through preview/apply; connections come only from the terminals the
/// engine's snap names (a wire over a pin connects nothing by itself).
extension CircuitModel {
    /// What a click on the schematic does.
    enum SchematicTool: Equatable {
        case select
        /// Posa un componente sul foglio (a new one from the library, or one of the circuit's
        /// without a symbol).
        case place(SchematicPlacing)
        /// Filo: from a terminal (pin, junction, or a point on a wire that becomes a junction)
        /// through bends to another.
        case wire
        case label
        case noConnect
        case junction
    }

    struct SchematicPlacing: Equatable {
        var choice: DeviceChoice?
        /// An existing component of the circuit that has no symbol yet.
        var existing: UUID?
        var reference: String
        var value: String
        var componentID = UUID()
        var baseRevision: UInt64 = 0
        var name: String
    }

    /// Where a wire starts or ends: an existing terminal, or a point of a wire to split there.
    enum WireEnd: Equatable {
        case terminal(SchematicTerminal, at: PCBPoint)
        case split(wireID: UUID, at: PCBPoint, junction: UUID)

        var point: PCBPoint {
            switch self { case let .terminal(_, p), let .split(_, p, _): p }
        }
        var terminal: SchematicTerminal {
            switch self { case let .terminal(t, _): t; case let .split(_, _, j): .junction(j) }
        }
    }

    var sheets: [SchematicSheet] { design?.schematic?.sheets ?? [] }

    /// The sheet shown: the chosen one while it exists, else the first.
    var currentSheetID: UUID? {
        if let id = chosenSheet, sheets.contains(where: { $0.id == id }) { return id }
        return sheets.first?.id
    }

    /// The drawing matches the document and the sheet shown.
    var schematicIsCurrent: Bool {
        guard let s = schematic, let doc = document else { return false }
        return s.revision == doc.revision && s.sheetID == currentSheetID
    }

    /// Rebuilds the sheet's drawing off the main thread when the document or the sheet changed
    /// (the previous build is cancelled; a late result for an older revision is dropped).
    func refreshSchematic() {
        guard let doc = document, let sheet = currentSheetID else {
            schematicTask?.cancel(); schematic = nil; return
        }
        if schematicIsCurrent { return }
        schematicTask?.cancel()
        let design = doc.design, revision = doc.revision, epoch = documentEpoch
        schematicTask = Task { [weak self] in
            let built = await Self.offMain { try? ElectronicsSchematic.snapshot(design: design, revision: revision, sheetID: sheet) }
            guard !Task.isCancelled, let self, self.documentEpoch == epoch, self.document?.revision == revision,
                  self.currentSheetID == sheet else { return }
            self.schematic = built
        }
    }

    /// Waits for the drawing in progress (tests, and anything that needs it current).
    func schematicReady() async { await schematicTask?.value }

    /// One preview per placing session, at the origin, off the main thread.
    func prepareSchematicGhost() {
        guard case let .place(p) = schematicTool else { ghostTask?.cancel(); schematicGhost = []; ghostSession = nil; return }
        let key = GhostKey(component: p.componentID, revision: p.baseRevision, sheet: currentSheetID)
        guard ghostSession != key else { return }
        ghostSession = key
        schematicGhost = []
        ghostTask?.cancel()
        guard let doc = document, let sheet = currentSheetID, let command = schematicPlaceCommand(p, at: PCBPoint()) else { return }
        let id = p.componentID, base = p.baseRevision
        ghostTask = Task { [weak self] in
            let prims = await Self.offMain { () -> [SchematicPrimitive] in
                guard let preview = try? ElectronicsCommands.preview(command, document: doc, expectedRevision: base),
                      let drawing = try? preview.schematicSnapshot(sheetID: sheet) else { return [] }
                return drawing.primitives.filter { $0.owner.componentID == id }
            }
            guard !Task.isCancelled, let self, self.ghostSession == key else { return }
            self.schematicGhost = prims
        }
    }

    func ghostReady() async { await ghostTask?.value }

    /// The sheet to draw on: the one shown, or a first «Foglio 1» made now (its own undo step).
    @discardableResult
    func ensureSheet() -> UUID? {
        if let id = currentSheetID { return id }
        let sheet = SchematicSheet(name: "Foglio 1")
        guard run(.schematic(.addSheet(sheet))) else { return nil }
        chosenSheet = sheet.id
        return sheet.id
    }

    func addSheet() {
        var n = sheets.count + 1
        while sheets.contains(where: { $0.name == "Foglio \(n)" }) { n += 1 }
        let sheet = SchematicSheet(name: "Foglio \(n)")
        if run(.schematic(.addSheet(sheet))) { chosenSheet = sheet.id }
    }

    func renameSheet(_ id: UUID, to name: String) {
        let clean = name.trimmingCharacters(in: .whitespaces)
        guard !clean.isEmpty else { return }
        run(.schematic(.renameSheet(id: id, name: clean)))
    }

    func removeSheet(_ id: UUID) { run(.schematic(.removeSheet(id))) }

    // MARK: Placing symbols

    /// Components of the circuit (e.g. placed on the PCB first) without a symbol yet.
    var componentsWithoutSymbol: [CircuitComponent] {
        let drawn = Set(sheets.flatMap(\.symbols).map(\.componentID))
        return (design?.components ?? []).filter { !drawn.contains($0.id) }
    }

    func startSchematicPlacing(_ choice: DeviceChoice, reference: String, value: String) {
        guard ensureSheet() != nil else { return }
        schematicTool = .place(.init(choice: choice, reference: reference, value: value,
                                     baseRevision: document?.revision ?? 0, name: choice.name))
    }

    func startSchematicPlacing(existing component: CircuitComponent) {
        guard ensureSheet() != nil else { return }
        schematicTool = .place(.init(existing: component.id, reference: component.reference, value: component.value,
                                     componentID: component.id, baseRevision: document?.revision ?? 0, name: component.reference))
    }

    func schematicPlaceCommand(_ p: SchematicPlacing, at position: PCBPoint) -> ElectronicsCommand? {
        guard let sheet = currentSheetID else { return nil }
        if let existing = p.existing {
            return .schematic(.placeSymbol(sheetID: sheet, symbol: SchematicSymbol(componentID: existing, position: position)))
        }
        guard let choice = p.choice else { return nil }
        if let sid = choice.starterID, let template = ElectronicsStarterLibrary.components.first(where: { $0.id == sid }) {
            return template.schematicCommand(componentID: p.componentID, reference: p.reference, value: p.value.isEmpty ? nil : p.value,
                                             sheetID: sheet, position: position)
        }
        return .addSchematicComponent(component: CircuitComponent(id: p.componentID, reference: p.reference, value: p.value, device: choice.key),
                                      sheetID: sheet, symbol: SchematicSymbol(componentID: p.componentID, position: position),
                                      library: ElectronicsLibrary())
    }

    /// Places the session's symbol; a new component goes on with a new identity and the next
    /// reference, an existing one ends the session.
    @discardableResult
    func placeSchematic(_ p: SchematicPlacing, at position: PCBPoint) -> Bool {
        if p.existing == nil, design?.components.contains(where: { $0.reference.uppercased() == p.reference.uppercased() }) == true {
            report("La sigla \(p.reference) c'è già: scegline un'altra.")
            return false
        }
        guard let command = schematicPlaceCommand(p, at: position) else { return false }
        guard run(command, expectedRevision: p.baseRevision) else {
            if case var .place(session) = schematicTool { session.baseRevision = document?.revision ?? 0; schematicTool = .place(session) }
            return false
        }
        selection = p.componentID
        if p.existing != nil {
            schematicTool = .select
        } else if let choice = p.choice {
            schematicTool = .place(.init(choice: choice, reference: nextReference(prefix: choice.prefix), value: p.value,
                                         baseRevision: document?.revision ?? 0, name: p.name))
        }
        return true
    }

    // MARK: Wires, labels, NC, junctions

    /// The terminal (or wire point) under a snap, for the wire tool.
    func wireEnd(for snap: SchematicSnap) -> WireEnd? {
        switch snap.kind {
        case .pin:
            guard let c = snap.object?.componentID, let pin = snap.object?.pinID else { return nil }
            return .terminal(.pin(PinReference(componentID: c, pinID: pin)), at: snap.point)
        case .junction:
            guard let id = snap.object?.id else { return nil }
            return .terminal(.junction(id), at: snap.point)
        case .onWire, .vertex, .midpoint:
            guard let obj = snap.object, obj.kind == .wire else { return nil }
            return .split(wireID: obj.id, at: snap.point, junction: UUID())
        case .grid:
            return nil
        }
    }

    /// A wire from `start` to `end` through `bends`, splitting the wires it starts or ends on
    /// (one undo step).
    func addWire(from start: WireEnd, to end: WireEnd, bends: [PCBPoint]) {
        guard let sheet = currentSheetID, start != end else { return }
        var commands: [SchematicCommand] = []
        for e in [start, end] {
            if case let .split(wireID, at, junction) = e {
                commands.append(.splitWire(id: wireID, junction: SchematicJunction(id: junction, position: at), newWireID: UUID()))
            }
        }
        commands.append(.addWire(sheetID: sheet, wire: SchematicWire(start: start.terminal, end: end.terminal, bends: bends)))
        run(.schematic(commands.count == 1 ? commands[0] : .batch(commands)))
    }

    /// Giunzione: a junction on a wire (split there), to branch from.
    func addJunction(onWire wireID: UUID, at point: PCBPoint) {
        run(.schematic(.splitWire(id: wireID, junction: SchematicJunction(position: point), newWireID: UUID())))
    }

    /// The net a pin is on, if any (to label it with its name).
    func netName(of pin: PinReference) -> String? {
        guard let d = design, let id = d.connections.first(where: { $0.pin == pin })?.netID else { return nil }
        return d.nets.first { $0.id == id }?.name
    }

    /// Etichetta: names the net at a terminal; the same name elsewhere is the same net.
    func addLabel(at terminal: SchematicTerminal, name: String, power: Bool = false) {
        guard let sheet = currentSheetID, let d = design else { return }
        let clean = name.trimmingCharacters(in: .whitespaces)
        guard !clean.isEmpty else { report("Scrivi il nome della rete."); return }
        let net = d.nets.first { $0.name == clean } ?? CircuitNet(name: clean)
        run(.schematic(.addLabel(sheetID: sheet, label: SchematicLabel(terminal: terminal, netID: net.id, kind: power ? .power : .net), net: net)))
    }

    func markNoConnect(_ pin: PinReference) { run(.markNoConnect([pin])) }

    // MARK: Selected object

    func moveSymbol(_ component: UUID, to position: PCBPoint) { run(.schematic(.moveSymbol(componentID: component, to: position))) }
    func rotateSymbol(_ component: UUID) { run(.schematic(.rotateSymbol(componentID: component, by: 90))) }
    func mirrorSymbol(_ component: UUID) { run(.schematic(.mirrorSymbol(component))) }

    /// Elimina what is selected on the schematic: a symbol (the component stays on the PCB), a
    /// wire, a label or a junction.
    func removeSchematicObject(_ object: SchematicObject) {
        let ok: Bool = switch object.kind {
        case .symbol, .pin: object.componentID.map { run(.schematic(.removeSymbol($0))) } ?? false
        case .wire: run(.schematic(.removeWire(object.id)))
        case .label: run(.schematic(.removeLabel(object.id)))
        case .junction: run(.schematic(.removeJunction(object.id)))
        case .noConnect: object.componentID.flatMap { c in object.pinID.map { run(.disconnect([PinReference(componentID: c, pinID: $0)])) } } ?? false
        }
        if ok { schematicSelection = nil }
    }
}
