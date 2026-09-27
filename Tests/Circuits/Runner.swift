import ElectronicsCore
import Foundation

/// What CIRCUITI's tools do, without the screen: from a circuit, add two components, connect
/// them, change the board, undo, save and reopen (the joint check with Codex's engine, T93/T97).
@main
struct CircuitTests {
    @MainActor static func main() throws {
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
        let ghost1 = c.placementPreview(session, at: PCBPoint(10, 10)), ghost2 = c.placementPreview(session, at: PCBPoint(12, 10))
        check(!ghost1.isEmpty && ghost1.allSatisfy { $0.componentID == session.componentID } && ghost2.allSatisfy { $0.componentID == session.componentID },
              "anteprime con la stessa identità")
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

        if failures > 0 { fatalError("\(failures) verifiche fallite") }
        print("OK: circuiti — da nuovo: componenti generici, collegamento, scheda, annulla, salva e riapri")
    }
}
