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
        try c.open(fixture)
        let before = c.design!.components.count
        guard let device = c.deviceChoices.first else { print("FALLITO: nessun dispositivo nell'esempio"); exit(1) }

        // Componente: two of the same part, references in sequence.
        let r1 = c.nextReference(prefix: device.prefix)
        let a = c.addComponent(.init(device: device.key, name: device.name, prefix: device.prefix, reference: r1, value: "10k"), at: PCBPoint(10, 10))
        let r2 = c.nextReference(prefix: device.prefix)
        let b = c.addComponent(.init(device: device.key, name: device.name, prefix: device.prefix, reference: r2, value: "10k"), at: PCBPoint(20, 10))
        check(a != nil && b != nil && r1 != r2 && c.design!.components.count == before + 2, "due componenti aggiunti (\(last))")
        // The same reference twice is refused, the design untouched.
        let again = c.addComponent(.init(device: device.key, name: device.name, prefix: device.prefix, reference: r1, value: "1k"), at: PCBPoint(30, 10))
        check(again == nil && c.design!.components.count == before + 2 && last.contains("c'è già"), "sigla doppia rifiutata")

        // Collega: a pad of each, a new net.
        let pads = c.board!.pads
        guard let pa = pads.first(where: { $0.componentID == a }), let pb = pads.first(where: { $0.componentID == b }) else {
            print("FALLITO: piazzole dei nuovi componenti non trovate"); exit(1)
        }
        let nets = c.design!.nets.count
        c.connect(PinReference(componentID: a!, pinID: pa.pinID), PinReference(componentID: b!, pinID: pb.pinID))
        check(c.design!.nets.count == nets + 1, "rete nuova (\(last))")
        check(c.board!.airwires.contains { Set([$0.fromComponent, $0.toComponent]) == Set([a!, b!]) }, "collegamento da sbrogliare tra i due")

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
        print("OK: circuiti — componenti, collegamenti, scheda, annulla, salva e riapri")
    }
}
