import ElectronicsCore
import Foundation

/// What CIRCUITI's tools do, without the screen: from a circuit, add two components, connect
/// them, change the board, undo, save and reopen (the joint check with Codex's engine, T93/T97).
@main
struct CircuitTests {
    @MainActor static func main() async throws {
        var failures = 0
        func check(_ ok: Bool, _ what: String) { if !ok { failures += 1; print("FALLITO: \(what)") } }
        let fixture = URL(fileURLWithPath: CommandLine.arguments[1])
        let c = CircuitModel()
        var last = ""
        c.report = { last = $0 }
        // The example opens (a file written by the engine's own tests).
        try c.open(fixture)
        check(!(c.design?.components.isEmpty ?? true), "esempio aperto")

        // From a NEW circuit: the generic models are there to choose (Ross's blocker).
        try c.newCircuit()
        check(c.design!.components.isEmpty && c.deviceChoices.count >= 3, "nuovo circuito: si può scegliere un componente")
        guard let device = c.deviceChoices.first(where: { $0.starterID != nil }) else { print("FALLITO: nessun modello generico"); exit(1) }

        // Posa: one session keeps the component's identity and base revision from the previews to
        // the click; nothing changes while previewing.
        c.startPlacing(device, reference: c.nextReference(prefix: device.prefix), value: device.defaultValue)
        guard case let .place(session) = c.tool else { print("FALLITO: posa non avviata"); exit(1) }
        await c.boardGhostReady()
        check(!c.boardGhost.isEmpty && c.boardGhost.allSatisfy { $0.componentID == session.componentID },
              "anteprima della posa (una per sessione) con l'identità della sessione")
        check(c.design!.components.isEmpty && !c.canUndo, "anteprima senza modifiche")
        let a = c.addComponent(session, at: PCBPoint(10, 10))
        check(a == session.componentID && c.design!.components.first?.reference == "R1", "R1 posato con l'identità dell'anteprima (\(last))")
        guard case let .place(next) = c.tool else { print("FALLITO: la posa non continua"); exit(1) }
        check(next.componentID != session.componentID && next.reference == "R2" && next.baseRevision == c.document!.revision, "sessione avanti: nuova identità, R2, revisione nuova")
        let b = c.addComponent(next, at: PCBPoint(20, 10))
        check(b == next.componentID && c.design!.components.count == 2, "R2 posato")
        // A stale session (the circuit changed after its preview) is refused and restarts on the new revision.
        guard case let .place(third) = c.tool else { print("FALLITO"); exit(1) }
        c.undo(); c.redo()
        check(c.addComponent(third, at: PCBPoint(30, 10)) == nil && c.design!.components.count == 2, "posa su revisione superata rifiutata")
        if case let .place(restarted) = c.tool { check(restarted.baseRevision == c.document!.revision, "sessione ripartita sulla revisione attuale") }
        c.tool = .select
        // The same reference twice is refused, the design untouched.
        var dup = next; dup.componentID = UUID(); dup.baseRevision = c.document!.revision; dup.reference = "R1"
        check(c.addComponent(dup, at: PCBPoint(30, 10)) == nil && c.design!.components.count == 2 && last.contains("c'è già"), "sigla doppia rifiutata")

        // Collega: pin 1 of R1 to pin 1 of R2 — the same pad ID (one footprint), different pins.
        let pads = c.board!.pads
        guard let pa = pads.first(where: { $0.componentID == a }),
              let pb = pads.first(where: { $0.componentID == b && $0.padID == pa.padID }) else {
            print("FALLITO: piazzole dei nuovi componenti non trovate"); exit(1)
        }
        let nets = c.design!.nets.count
        c.tool = .connect
        c.connectClick(pa); c.connectClick(pb)
        check(c.design!.nets.count == nets + 1, "R1.1–R2.1 collegati anche con la stessa piazzola d'impronta (\(last))")
        check(c.board!.airwires.contains { Set([$0.fromComponent, $0.toComponent]) == Set([a!, b!]) }, "collegamento da sbrogliare tra i due")
        c.tool = .select

        // Scheda: bigger, then undo gives the old one back.
        let old = c.design!.board.outline
        c.setBoard(width: 80, height: 60, thickness: 1.6)
        check(c.design!.board.outline.contains(PCBPoint(80, 60)), "scheda 80 × 60")
        c.setBoard(width: 0, height: 60, thickness: 1.6)
        check(c.design!.board.outline.contains(PCBPoint(80, 60)), "misura nulla rifiutata, scheda invariata")
        c.undo()
        check(c.design!.board.outline == old, "annulla riporta la scheda di prima")
        c.redo()

        // Elimina the second: its connection goes too; undo brings both back.
        c.removeComponent(b!)
        check(!c.design!.components.contains { $0.id == b } && !c.design!.connections.contains { $0.pin.componentID == b }, "eliminato con i collegamenti")
        c.undo()
        check(c.design!.components.contains { $0.id == b } && c.design!.connections.contains { $0.pin.componentID == b }, "annulla lo rimette collegato")

        // Save and reopen: everything there, with the history.
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("circuito-\(UUID().uuidString).ftkc")
        try c.save(to: out)
        let d = CircuitModel()
        try d.open(out)
        check(d.design == c.design && d.canUndo, "salvato e riaperto uguale, con lo storico")
        try? FileManager.default.removeItem(at: out)

        // LIBRERIA: a KiCad resistor symbol and its 0603 footprint (Codex's redistributable
        // samples) imported with preview, joined into a new type, placed.
        let lib = URL(fileURLWithPath: CommandLine.arguments[2])
        let symURL = lib.appendingPathComponent("Device_R.kicad_sym"), fpURL = lib.appendingPathComponent("R_0603_1608Metric.kicad_mod")
        let names = CircuitModel.kicadSymbolNames(try Data(contentsOf: symURL))
        check(names.contains("R"), "simboli del file KiCad elencati (\(names))")
        let rev0 = c.document!.revision
        c.prepareImport(symURL, symbol: "R")
        check(c.importProposal?.symbols.first?.name == "R" && c.document!.revision == rev0, "anteprima del simbolo, nessuna modifica (\(last))")
        c.confirmImport()
        c.prepareImport(fpURL)
        check((c.importProposal?.footprints.count ?? 0) == 1, "anteprima dell'impronta (\(last))")
        c.confirmImport()
        let lib1 = c.design!.library
        check(lib1.symbols.contains { $0.name == "R" } && lib1.footprints.contains { $0.name.contains("0603") }, "importati simbolo e impronta")
        // The same file again: nothing new.
        c.prepareImport(fpURL); c.confirmImport()
        check(c.design!.library.footprints.count == lib1.footprints.count, "reimport identico senza doppioni")
        let sym = lib1.symbols.first { $0.name == "R" }!.key, fp = lib1.footprints.first { $0.name.contains("0603") && $0.source.reference.hasSuffix(".kicad_mod") }!.key
        guard case let .success(map) = c.suggestedPinMap(symbol: sym, footprint: fp) else { print("FALLITO: nessuna piedinatura proposta (\(last))"); exit(1) }
        check(map.count == 2 && c.createDevice(symbol: sym, footprint: fp, manufacturer: "", partNumber: "", pinMap: map), "nuovo tipo creato (\(last))")
        guard let kind = c.deviceChoices.first(where: { $0.starterID == nil && $0.key.id != device.key.id && $0.name == "R" }) else {
            print("FALLITO: il nuovo tipo non è fra i componenti da posare"); exit(1)
        }
        c.startPlacing(kind, reference: c.nextReference(prefix: kind.prefix), value: "4k7")
        if case let .place(s) = c.tool { check(c.addComponent(s, at: PCBPoint(40, 20)) != nil, "tipo importato posato (\(last))") }
        c.tool = .select

        // SCHEMA, from a new circuit: first sheet made on first use, two resistors placed on it.
        let sc = CircuitModel()
        sc.report = { last = $0 }
        try sc.newCircuit()
        let res = sc.deviceChoices.first { $0.starterID != nil }!
        sc.startSchematicPlacing(res, reference: "R1", value: "10k")
        check(sc.sheets.count == 1 && sc.currentSheetID != nil, "primo foglio creato al primo uso")
        guard case let .place(sp1) = sc.schematicTool else { print("FALLITO: posa schema non avviata"); exit(1) }
        await sc.ghostReady()
        check(!sc.schematicGhost.isEmpty && sc.schematicGhost.allSatisfy { $0.owner.componentID == sp1.componentID } && sc.design!.components.isEmpty,
              "anteprima del simbolo (in background) senza modifiche")
        check(sc.placeSchematic(sp1, at: PCBPoint(10, 10)), "R1 sullo schema (\(last))")
        guard case let .place(sp2) = sc.schematicTool else { print("FALLITO: la posa schema non continua"); exit(1) }
        check(sp2.reference == "R2" && sp2.componentID != sp1.componentID, "sessione avanti: R2")
        check(sc.placeSchematic(sp2, at: PCBPoint(40, 10)), "R2 sullo schema (\(last))")
        sc.schematicTool = .select
        await sc.schematicReady()
        check(sc.schematicIsCurrent, "disegno dello schema aggiornato (in background)")
        guard let draw = sc.schematic else { print("FALLITO: disegno dello schema assente"); exit(1) }
        let pins1 = draw.pins.filter { $0.reference.componentID == sp1.componentID }
        let pins2 = draw.pins.filter { $0.reference.componentID == sp2.componentID }
        check(pins1.count == 2 && pins2.count == 2 && !draw.primitives.isEmpty, "simboli disegnati con i loro pin")
        // Filo from a pin of R1 to a pin of R2 through the engine's snap.
        func end(_ p: PCBPoint) -> CircuitModel.WireEnd? {
            sc.schematic?.snapTargets(near: p, radius: 1, grid: 1.27).lazy.compactMap { sc.wireEnd(for: $0) }.first
        }
        guard let a1 = end(pins1[1].position), let b1 = end(pins2[0].position) else { print("FALLITO: aggancio ai pin"); exit(1) }
        sc.addWire(from: a1, to: b1, bends: [])
        check(!sc.schematicIsCurrent, "dopo una modifica il disegno vecchio non conta come attuale")
        await sc.schematicReady()
        let netA = sc.design!.connections.first { $0.pin == pins1[1].reference }?.netID
        check(netA != nil && netA == sc.design!.connections.first { $0.pin == pins2[0].reference }?.netID, "il filo collega i due pin (\(last))")
        // Etichetta VCC on R1's other pin; NC on R2's other pin.
        sc.addLabel(at: .pin(pins1[0].reference), name: "VCC")
        check(sc.design!.nets.contains { $0.name == "VCC" } && sc.netName(of: pins1[0].reference) == "VCC", "etichetta VCC (\(last))")
        sc.markNoConnect(pins2[1].reference)
        await sc.schematicReady()
        check(sc.design!.connections.contains { $0.pin == pins2[1].reference && $0.netID == nil }, "NC sul pin libero (\(last))")
        // Giunzione in the middle of the wire.
        let wire = sc.sheets[0].wires[0]
        let mid = PCBPoint((pins1[1].position.x + pins2[0].position.x) / 2, (pins1[1].position.y + pins2[0].position.y) / 2)
        if let onWire = sc.schematic?.snapTargets(near: mid, radius: 1).first(where: { $0.kind == .onWire || $0.kind == .midpoint }) {
            sc.addJunction(onWire: wire.id, at: onWire.point)
            check(sc.sheets[0].junctions.count == 1 && sc.sheets[0].wires.count == 2, "giunzione: il filo diviso in due (\(last))")
        } else { check(false, "punto sul filo non agganciato") }
        // PCB: both components still to place; placed, the connection shows as an airwire.
        check(Set(sc.board!.unplacedComponents) == Set([sp1.componentID, sp2.componentID]), "da posare sul PCB")
        sc.placeExistingOnBoard(sp1.componentID, at: PCBPoint(10, 10))
        sc.placeExistingOnBoard(sp2.componentID, at: PCBPoint(30, 10))
        check(sc.board!.unplacedComponents.isEmpty && !sc.board!.airwires.isEmpty, "posati sul PCB, collegamento da sbrogliare (\(last))")
        // Undo the last, redo; save and reopen with the schematic.
        sc.undo()
        check(sc.board!.unplacedComponents == [sp2.componentID], "annulla la posa di R2")
        sc.redo()
        let outS = FileManager.default.temporaryDirectory.appendingPathComponent("schema-\(UUID().uuidString).ftkc")
        try sc.save(to: outS)
        let reopened = CircuitModel()
        try reopened.open(outS)
        await reopened.schematicReady()
        check(reopened.design == sc.design && reopened.schematic?.pins.count == 4, "schema salvato e riaperto")
        try? FileManager.default.removeItem(at: outS)

        if failures > 0 { fatalError("\(failures) verifiche fallite") }
        print("OK: circuiti — PCB e schema da nuovo: componenti, fili, etichette, NC, giunzioni, posa sul PCB, annulla, salva e riapri")
    }
}
