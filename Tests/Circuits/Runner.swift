import ElectronicsCore
import Foundation

/// What CIRCUITI's tools do, without the screen: from a circuit, add two components, connect
/// them, change the board, undo, save and reopen (the joint check with Codex's engine, T93/T97).
@main
struct CircuitTests {
    @MainActor static func main() async throws {
        var failures = 0
        func check(_ ok: Bool, _ what: String) { if !ok { failures += 1; print("FALLITO: \(what)"); fflush(stdout) } }
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
        check(!c.boardGhost.isEmpty && c.boardGhost.allSatisfy { $0.item.subjectIDs.first == session.componentID },
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
        await c.pcbReady()
        let pads = c.board!.pads
        guard let pa = pads.first(where: { $0.componentID == a }),
              let pb = pads.first(where: { $0.componentID == b && $0.padID == pa.padID }) else {
            print("FALLITO: piazzole dei nuovi componenti non trovate"); exit(1)
        }
        let nets = c.design!.nets.count
        c.tool = .connect
        c.connectClick(pa); c.connectClick(pb)
        await c.pcbReady()
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
        await sc.pcbReady()
        check(Set(sc.board!.unplacedComponents) == Set([sp1.componentID, sp2.componentID]), "da posare sul PCB")
        sc.placeExistingOnBoard(sp1.componentID, at: PCBPoint(10, 10))
        sc.placeExistingOnBoard(sp2.componentID, at: PCBPoint(30, 10))
        await sc.pcbReady()
        check(sc.board!.unplacedComponents.isEmpty && !sc.board!.airwires.isEmpty, "posati sul PCB, collegamento da sbrogliare (\(last))")
        // Undo the last, redo; save and reopen with the schematic.
        sc.undo()
        await sc.pcbReady()
        check(sc.board!.unplacedComponents == [sp2.componentID], "annulla la posa di R2")
        sc.redo()
        await sc.pcbReady()

        // PISTA (T97 on T94): from R1's pad to R2's along the airwire, previewed then confirmed.
        sc.canvas = .board
        sc.tool = .route
        guard let air = sc.board!.airwires.first else { print("FALLITO: nessun collegamento da sbrogliare"); exit(1) }
        let airwires = sc.board!.airwires.count
        sc.routeClick(at: air.from, tolerance: 0.5)
        guard let started = sc.route else { print("FALLITO: pista non iniziata (\(last))"); exit(1) }
        check(started.netID == air.netID && started.runs[0].points.count == 1 && CircuitModel.distance(started.runs[0].points[0], air.from) < 1e-6, "pista iniziata sulla piazzola, nella sua rete")
        // Changing side at once: a via unless the pad goes through the board.
        sc.switchLayer()
        check(sc.route!.startLayers.contains(sc.layerCount - 1) ? sc.route!.vias.isEmpty : sc.route!.vias.count == 1, "cambio lato sul pad: via se il pad è solo su un lato")
        sc.switchLayer(to: 0)
        check(sc.route!.vias.isEmpty && sc.route!.layer == 0, "tornato sopra senza via")
        sc.previewLeg(to: air.to, tolerance: 0.5)
        await sc.routeCheckReady()
        check(sc.routeCheck?.blocking == [] && sc.routeCheck?.target.kind == .pad, "anteprima confermabile, agganciata alla piazzola (\(sc.routeCheck?.blocking?.first?.message ?? "in corso"))")
        let revisionBefore = sc.document!.revision
        let trackID = sc.route!.runs[0].id
        sc.routeClick(at: air.to, tolerance: 0.5)
        await sc.pcbReady()
        let tracks = sc.design!.board.copper?.tracks ?? []
        check(sc.route == nil && tracks.count == 1 && tracks[0].id == trackID && tracks[0].layer == 0, "pista confermata con l'identità dell'anteprima (\(last))")
        check(sc.board!.airwires.count == airwires - 1 && sc.document!.revision == revisionBefore + 1, "collegamento sbrogliato, un solo passo")
        // Width, selection, delete, undo.
        sc.setWidth(0.5, ofTrack: trackID)
        check(sc.track(trackID)?.width == 0.5, "larghezza cambiata")
        await sc.pcbReady()
        let halfway = PCBPoint((air.from.x + air.to.x) / 2, (air.from.y + air.to.y) / 2)
        sc.tool = .select
        check(sc.copperHit(at: tracks[0].points.count > 2 ? tracks[0].points[1] : halfway, tolerance: 0.5)?.item == .track(trackID), "pista trovata sotto il mouse")
        sc.removeCopper(.track(trackID))
        check(sc.design!.board.copper?.tracks.isEmpty ?? true, "pista eliminata")
        sc.undo()
        check(sc.track(trackID) != nil, "annulla la rimette")
        // Layers cannot change under copper; without it, 4 layers.
        check(!sc.configureCopper(layerCount: 4, rules: sc.copperRules), "strati bloccati con rame presente (\(last))")
        // A route with a via: out on top, via, on to R2 underneath or back up, then Invio.
        sc.undo(); sc.undo()
        await sc.pcbReady()
        check(sc.design!.board.copper?.tracks.isEmpty ?? true, "rame tolto")
        check(sc.configureCopper(layerCount: 4, rules: sc.copperRules) && sc.layerCount == 4, "4 strati (\(last))")
        await sc.pcbReady()
        sc.tool = .route
        sc.activeLayer = 0
        sc.routeClick(at: air.from, tolerance: 0.5)
        sc.routeClick(at: PCBPoint(air.from.x + 4, air.from.y + 6), tolerance: 0.5)
        sc.switchLayer(to: 3)
        let viaID = sc.route?.vias.first?.id
        check(sc.route?.vias.count == 1 && sc.route?.layer == 3, "via e strato Sotto")
        sc.routeClick(at: PCBPoint(air.to.x - 4, air.from.y + 6), tolerance: 0.5)
        sc.switchLayer(to: 0)
        sc.routeClick(at: air.to, tolerance: 0.5)
        await sc.pcbReady()
        let copper = sc.design!.board.copper!
        check(sc.route == nil && copper.tracks.count == 3 && copper.vias.count == 2 && copper.vias.contains { $0.id == viaID }, "pista con due via in un passo (\(last))")
        check(!sc.board!.airwires.contains { $0.netID == air.netID }, "rete sbrogliata attraverso le via")

        // CLASSI (T94 rules): the net in «Potenza» routes with the class's sizes; a tighter minimum
        // is checked before Applica (errors on the copper already there), then applied.
        guard let power = sc.addNetClass(name: "Potenza"), var klass = sc.netClasses.first(where: { $0.id == power }) else {
            print("FALLITO: classe non creata (\(last))"); exit(1)
        }
        klass.routing = PCBRoutingDimensions(trackWidth: 0.5, viaDiameter: 0.8, viaDrill: 0.4)
        check(sc.updateNetClass(klass) && sc.assign(nets: [air.netID], to: power) && sc.netClass(of: air.netID)?.id == power, "classe con misure e rete assegnata (\(last))")
        await sc.pcbReady()
        sc.tool = .route
        sc.activeLayer = 0
        sc.routeClick(at: air.from, tolerance: 0.5)
        check(sc.route?.width == 0.5 && sc.route?.rules.routing.viaDiameter == 0.8 && sc.route?.rules.className == "Potenza", "pista con le misure della classe")
        sc.switchLayer(to: 3)
        if case let .batch(cmds)? = sc.routeCommand(sc.route!), case let .addVia(v)? = cmds.last { check(v.diameter == 0.8 && v.drill == 0.4, "via della classe") }
        else if case let .addVia(v)? = sc.routeCommand(sc.route!) { check(v.diameter == 0.8 && v.drill == 0.4, "via della classe") }
        else { check(false, "via della classe nel comando") }
        sc.tool = .select
        // The class as edited before its net was assigned: applying it keeps the net in the class.
        var strict = klass
        strict.constraints.minimumTrackWidth = 1.0
        check(sc.edited(strict)?.netIDs == [air.netID], "la modifica della classe conserva le reti assegnate")
        sc.checkRule(.updateNetClass(sc.edited(strict)!))
        await sc.ruleCheckReady()
        check(!(sc.ruleCheck?.newErrors ?? []).isEmpty && sc.ruleCheck?.refusal == nil, "classe più stretta: errori sul rame mostrati prima di applicare")
        let beforeStrict = sc.document!.revision
        check(sc.updateNetClass(strict, expectedRevision: sc.ruleCheck?.revision) && sc.document!.revision == beforeStrict + 1
              && sc.netClass(of: air.netID)?.constraints.minimumTrackWidth == 1.0, "classe applicata, rete ancora nella classe, errori da correggere (\(last))")
        // A class the engine refuses (a negative minimum): nothing changes, the edit can be corrected.
        var broken = strict
        broken.constraints.minimumTrackWidth = -1
        let beforeBroken = sc.document!.revision
        check(!sc.updateNetClass(broken) && sc.document!.revision == beforeBroken && sc.netClass(of: air.netID)?.constraints.minimumTrackWidth == 1.0,
              "classe non valida rifiutata senza toccare il circuito (\(last))")
        check(last.contains("non riuscito"), "rifiuto nella barra di stato")
        var renamed = strict
        renamed.name = "Potenza 2"
        check(sc.updateNetClass(renamed) && !last.contains("non riuscito"), "dopo un comando riuscito il vecchio rifiuto sparisce (\(last))")
        sc.undo()
        sc.refreshNetRules()
        await sc.netRulesReady()
        check(sc.currentNetRules?[air.netID]?.rules.minimumTrackWidth == 1.0, "regole risolte per rete, per revisione")
        sc.undo(); sc.undo(); sc.undo(); sc.undo()
        await sc.pcbReady()
        check(sc.netClasses.isEmpty, "annulla toglie la classe")

        // AREE VIETATE: two corners across a track → rectangle, previewed (conflict shown), confirmed
        // with the previewed identity; moved; a track into it refused; deleted and undone.
        let crossing = copper.tracks[0].points
        let c0 = crossing[0], c1 = crossing[crossing.count - 1]
        let centre = PCBPoint((c0.x + c1.x) / 2, (c0.y + c1.y) / 2)
        sc.tool = .keepout
        sc.activeLayer = copper.tracks[0].layer
        sc.keepoutClick(at: PCBPoint(centre.x - 1, centre.y - 1), tolerance: 0.1)
        sc.keepoutClick(at: PCBPoint(centre.x + 1, centre.y + 1), tolerance: 0.1)
        let draftID = sc.keepoutDraft?.id
        check(sc.keepoutDraft?.outline(with: sc.keepoutDraft?.points.last)?.count == 4
              && sc.keepoutDraft?.outline(with: sc.keepoutDraft?.points.first)?.count == 4, "il mouse sull'ultimo o sul primo punto non cambia il rettangolo")
        await sc.ruleCheckReady()
        check(!(sc.ruleCheck?.newErrors ?? []).isEmpty, "area sopra la pista: conflitto mostrato prima di confermare")
        check(sc.finishKeepout() && sc.keepouts.count == 1 && sc.keepouts[0].id == draftID && sc.keepoutSelection == draftID,
              "area confermata con l'identità dell'anteprima (\(last))")
        await sc.pcbReady()
        check(sc.issues.contains { $0.code == "pcb_keepout" }, "conflitto dell'area nelle VERIFICHE")
        check(sc.keepoutHit(at: centre, tolerance: 0.1)?.id == draftID, "area trovata sotto il mouse")
        sc.moveKeepout(draftID!, by: PCBPoint(0, 30))
        await sc.pcbReady()
        check(abs(sc.keepouts[0].outline[0].y - (centre.y - 1 + 30)) < 1e-9 && !sc.issues.contains { $0.code == "pcb_keepout" }, "area spostata fuori dal rame")
        sc.moveKeepout(draftID!, by: PCBPoint(0, -30))
        let beforeInto = sc.document!.revision
        sc.tool = .route
        sc.routeClick(at: air.from, tolerance: 0.5)
        sc.routeClick(at: PCBPoint(centre.x, centre.y), tolerance: 0.01)
        check(!sc.finishRoute() && sc.document!.revision == beforeInto, "pista dentro l'area vietata rifiutata (\(last))")
        sc.tool = .select
        sc.removeKeepout(draftID!)
        check(sc.keepouts.isEmpty, "area eliminata")
        sc.undo(); sc.undo(); sc.undo(); sc.undo()
        check(sc.keepouts.isEmpty, "annulla fino a prima dell'area")
        // A draft made on an older revision is dropped (an undo while drawing).
        sc.tool = .keepout
        sc.keepoutClick(at: PCBPoint(1, 1), tolerance: 0.1)
        sc.undo()
        check(sc.keepoutDraft == nil, "bozza dell'area scartata al cambio di revisione")
        sc.redo()
        sc.tool = .select
        await sc.pcbReady()
        // A leg over another net's pad is shown as not confirmable, and refused.
        if let other = sc.board!.pads.first(where: { $0.componentID == air.fromComponent && $0.netID != air.netID }) {
            sc.activeLayer = 0
            sc.routeClick(at: air.from, tolerance: 0.5)
            sc.previewLeg(to: other.center, tolerance: 0.01)
            await sc.routeCheckReady()
            check(!(sc.routeCheck?.blocking ?? []).isEmpty, "anteprima su un'altra rete non confermabile")
            let before = sc.document!.revision
            sc.routeClick(at: other.center, tolerance: 0.01)
            check(!sc.finishRoute() && sc.document!.revision == before, "corto rifiutato dal motore (\(last))")
            sc.tool = .select
            check(sc.route == nil, "uscire dallo strumento chiude la pista")
        } else { check(false, "piazzola di un'altra rete non trovata") }
        let outS = FileManager.default.temporaryDirectory.appendingPathComponent("schema-\(UUID().uuidString).ftkc")
        try sc.save(to: outS)
        let reopened = CircuitModel()
        try reopened.open(outS)
        await reopened.schematicReady()
        check(reopened.design == sc.design && reopened.schematic?.pins.count == 4, "schema e rame salvati e riaperti")
        try? FileManager.default.removeItem(at: outS)
        let outS2 = FileManager.default.temporaryDirectory.appendingPathComponent("rame-\(UUID().uuidString).ftkc")
        try sc.save(to: outS2)

        // A file gone (a stale reference, a moved file): an Italian reason, the open circuit untouched.
        let before = sc.design
        do { try sc.open(FileManager.default.temporaryDirectory.appendingPathComponent("sparito-\(UUID().uuidString).ftkc")); check(false, "file mancante aperto?") }
        catch { check(CircuitModel.describe(error).contains("non si trova più") && sc.design == before, "file mancante: motivo in italiano, circuito aperto intatto") }

        let notCircuit = FileManager.default.temporaryDirectory.appendingPathComponent("altro-\(UUID().uuidString).json")
        try Data(#"{"outline":[]}"#.utf8).write(to: notCircuit)
        do { try sc.open(notCircuit); check(false, "JSON qualsiasi aperto?") }
        catch { check(CircuitModel.describe(error).contains("non è un circuito") && sc.design == before, "JSON che non è un circuito: detto in italiano (\(CircuitModel.describe(error)))") }
        try? FileManager.default.removeItem(at: notCircuit)

        // Another document with the same revision: nothing of the previous drawings, route or selection.
        let two = CircuitModel()
        try two.newCircuit(name: "Primo")
        await two.pcbReady()
        let firstID = two.pcb?.designID
        two.tool = .route
        two.copperSelection = .via(UUID())
        try two.newCircuit(name: "Secondo")
        check(two.document!.revision == 0 && !two.pcbIsCurrent && two.route == nil && two.copperSelection == nil && two.tool == .select,
              "altro circuito alla stessa revisione: niente disegno, pista o selezione del precedente")
        await two.pcbReady()
        check(two.pcbIsCurrent && two.pcb?.designID == two.design?.id && two.pcb?.designID != firstID, "disegno del nuovo circuito")
        try two.open(outS2)
        await two.pcbReady()
        check(two.pcbIsCurrent && two.design == sc.design && two.design!.board.copper?.tracks.count == 3, "riaperto col suo rame")
        try? FileManager.default.removeItem(at: outS2)

        if failures > 0 { fatalError("\(failures) verifiche fallite") }
        print("OK: circuiti — PCB e schema da nuovo: componenti, fili, etichette, NC, giunzioni, posa sul PCB, piste, via e strati, classi di rete, aree vietate, annulla, salva e riapri")
    }
}
