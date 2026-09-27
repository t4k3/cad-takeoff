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
        try await c.open(fixture)
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
        try await d.open(out)
        check(d.design == c.design && d.canUndo, "salvato e riaperto uguale, con lo storico")
        try? FileManager.default.removeItem(at: out)

        // LIBRERIA: a KiCad resistor symbol and its 0603 footprint (Codex's redistributable
        // samples) imported with preview, joined into a new type, placed.
        let lib = URL(fileURLWithPath: CommandLine.arguments[2])
        let symURL = lib.appendingPathComponent("Device_R.kicad_sym"), fpURL = lib.appendingPathComponent("R_0603_1608Metric.kicad_mod")
        c.chooseImport(symURL)
        await c.importReady()
        let names = c.symbolChoice?.names ?? []
        check(names.contains("R") || c.importProposal?.symbols.first?.name == "R", "simboli del file KiCad elencati dal motore (\(names) · \(last))")
        let rev0 = c.document!.revision
        if c.symbolChoice != nil { c.chooseSymbol("R") }
        await c.importReady()
        check(c.importProposal?.symbols.first?.name == "R" && c.document!.revision == rev0, "anteprima del simbolo, nessuna modifica (\(last))")
        check(c.importProposal?.preview.revisionDiffs.allSatisfy { $0.before == nil } == true, "simbolo nuovo: nessuna revisione precedente")
        c.confirmImport()
        c.prepareImport(fpURL)
        await c.importReady()
        check((c.importProposal?.footprints.count ?? 0) == 1, "anteprima dell'impronta (\(last))")
        c.confirmImport()
        let lib1 = c.design!.library
        check(lib1.symbols.contains { $0.name == "R" } && lib1.footprints.contains { $0.name.contains("0603") }, "importati simbolo e impronta")
        // The same file again: nothing new.
        c.prepareImport(fpURL); await c.importReady(); c.confirmImport()
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

        // A new revision of the footprint (pads moved, same file name, another folder): compared
        // with revision 1, the placed resistor listed to evaluate (it stays on revision 1).
        let placedRef = c.design!.components.last!.id
        let v2Dir = FileManager.default.temporaryDirectory.appendingPathComponent("rev2-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: v2Dir, withIntermediateDirectories: true)
        let v2 = v2Dir.appendingPathComponent(fpURL.lastPathComponent)
        let original = try String(contentsOf: fpURL, encoding: .utf8)
        try original.replacingOccurrences(of: "(at -0.825 0)", with: "(at -0.925 0)").replacingOccurrences(of: "(at 0.825 0)", with: "(at 0.925 0)")
            .write(to: v2, atomically: true, encoding: .utf8)
        let beforeRev2 = c.document
        c.prepareImport(v2)
        await c.importReady()
        let diff = c.importProposal?.preview.revisionDiffs.first { if case .footprint = $0.after { true } else { false } }
        check(diff?.before?.key.revision == 1 && diff?.after.key.revision == 2 && diff?.pads.filter { $0.kind == .modified }.count == 2
              && diff?.affectedComponentIDs.contains(placedRef) == true && c.document == beforeRev2,
              "revisione 2 confrontata con la 1: 2 piazzole spostate, resistenza posata da valutare (\(diff.map { "\($0.pads.count)" } ?? "nessun confronto"))")
        let shapes = c.importProposal?.footprintShapes ?? [:]
        check(shapes.count == 2 && shapes.values.allSatisfy { $0.pads.count == 2 }, "forme esatte delle piazzole prima e dopo, dal motore")
        c.cancelImport()
        check(c.importProposal == nil && c.document == beforeRev2, "annulla: niente cambia")
        // Previewed, then the circuit changes: the confirmation is refused.
        c.prepareImport(v2); await c.importReady()
        c.setBoard(width: 61, height: 41, thickness: 1.6)
        let changedMeanwhile = c.document
        c.confirmImport()
        check(c.document == changedMeanwhile && last.contains("cambiato"), "anteprima su un altro stato: conferma rifiutata (\(last))")
        c.prepareImport(v2); await c.importReady(); c.confirmImport()
        check(c.design!.library.footprints.filter { $0.key.id == diff?.after.key.id }.map(\.key.revision).sorted() == [1, 2]
              && c.design!.board.placements.contains { $0.componentID == placedRef }, "revisione 2 aggiunta, la resistenza resta sulla 1")
        // The identical content again from another folder, same name, another date: nothing changes.
        let v3Dir = v2Dir.appendingPathComponent("altra")
        try FileManager.default.createDirectory(at: v3Dir, withIntermediateDirectories: true)
        let v3 = v3Dir.appendingPathComponent(fpURL.lastPathComponent)
        try FileManager.default.copyItem(at: v2, to: v3)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_000_000_000)], ofItemAtPath: v3.path)
        let unchanged = c.document
        c.prepareImport(v3); await c.importReady()
        check(c.importProposal?.preview.revisionDiffs.isEmpty == true, "reimport identico: nessun confronto")
        c.confirmImport()
        check(c.document == unchanged, "reimport identico da un'altra cartella e data: documento intero invariato (\(last))")
        // Reading held; the same circuit reopened meanwhile: the preview never lands.
        let saved = v2Dir.appendingPathComponent("circuito.ftkc")
        try c.save(to: saved)
        let libGate = ReadGate()
        c.readLibraryFile = { url in await libGate.wait(url); return try Data(contentsOf: url) }
        c.prepareImport(fpURL)
        let pendingPreview = c.importTask
        await libGate.arrived(fpURL)
        try await c.open(saved)
        await libGate.release(fpURL)
        await pendingPreview?.value
        check(c.importProposal == nil && c.importing == nil, "file riaperto durante la lettura: nessuna anteprima vecchia")
        // Listing symbols held, then another file: no choice offered for the old circuit.
        c.chooseImport(symURL)
        let pendingList = c.importTask
        await libGate.arrived(symURL)
        try await c.open(saved)
        await libGate.release(symURL)
        await pendingList?.value
        check(c.symbolChoice == nil && c.importProposal == nil, "elenco simboli di un altro circuito: scartato")
        c.readLibraryFile = { url in try Data(contentsOf: url) }
        try? FileManager.default.removeItem(at: v2Dir)

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
        await sc.routeClick(at: air.from, tolerance: 0.5)
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
        await sc.routeClick(at: air.to, tolerance: 0.5)
        await sc.pcbReady()
        let tracks = sc.design!.board.copper?.tracks ?? []
        check(sc.route == nil && tracks.count == 1 && tracks[0].id == trackID && tracks[0].layer == 0, "pista confermata con l'identità dell'anteprima (\(last))")
        check(sc.board!.airwires.count == airwires - 1 && sc.document!.revision == revisionBefore + 1, "collegamento sbrogliato, un solo passo")
        // Width, selection, delete, undo.
        await sc.setWidth(0.5, ofTrack: trackID)
        check(sc.track(trackID)?.width == 0.5, "larghezza cambiata")
        await sc.pcbReady()
        let halfway = PCBPoint((air.from.x + air.to.x) / 2, (air.from.y + air.to.y) / 2)
        sc.tool = .select
        check(sc.copperHit(at: tracks[0].points.count > 2 ? tracks[0].points[1] : halfway, tolerance: 0.5)?.item == .track(trackID), "pista trovata sotto il mouse")
        await sc.removeCopper(.track(trackID))
        check(sc.design!.board.copper?.tracks.isEmpty ?? true, "pista eliminata")
        sc.undo()
        check(sc.track(trackID) != nil, "annulla la rimette")
        // Layers cannot change under copper; without it, 4 layers.
        await check(!sc.configureCopper(layerCount: 4, rules: sc.copperRules), "strati bloccati con rame presente (\(last))")
        // A route with a via: out on top, via, on to R2 underneath or back up, then Invio.
        sc.undo(); sc.undo()
        await sc.pcbReady()
        check(sc.design!.board.copper?.tracks.isEmpty ?? true, "rame tolto")
        await check(sc.configureCopper(layerCount: 4, rules: sc.copperRules) && sc.layerCount == 4, "4 strati (\(last))")
        await sc.pcbReady()
        sc.tool = .route
        sc.activeLayer = 0
        await sc.routeClick(at: air.from, tolerance: 0.5)
        await sc.routeClick(at: PCBPoint(air.from.x + 4, air.from.y + 6), tolerance: 0.5)
        sc.switchLayer(to: 3)
        let viaID = sc.route?.vias.first?.id
        check(sc.route?.vias.count == 1 && sc.route?.layer == 3, "via e strato Sotto")
        await sc.routeClick(at: PCBPoint(air.to.x - 4, air.from.y + 6), tolerance: 0.5)
        sc.switchLayer(to: 0)
        await sc.routeClick(at: air.to, tolerance: 0.5)
        await sc.pcbReady()
        let copper = sc.design!.board.copper!
        check(sc.route == nil && copper.tracks.count == 3 && copper.vias.count == 2 && copper.vias.contains { $0.id == viaID }, "pista con due via in un passo (\(last))")
        check(!sc.board!.airwires.contains { $0.netID == air.netID }, "rete sbrogliata attraverso le via")

        // CLASSI (T94 rules): the net in «Potenza» routes with the class's sizes; a tighter minimum
        // is checked before Applica (errors on the copper already there), then applied.
        guard let power = await sc.addNetClass(name: "Potenza"), var klass = sc.netClasses.first(where: { $0.id == power }) else {
            print("FALLITO: classe non creata (\(last))"); exit(1)
        }
        klass.routing = PCBRoutingDimensions(trackWidth: 0.5, viaDiameter: 0.8, viaDrill: 0.4)
        let classUpdated = await sc.updateNetClass(klass), classAssigned = await sc.assign(nets: [air.netID], to: power)
        check(classUpdated && classAssigned && sc.netClass(of: air.netID)?.id == power, "classe con misure e rete assegnata (\(last))")
        await sc.pcbReady()
        sc.tool = .route
        sc.activeLayer = 0
        await sc.routeClick(at: air.from, tolerance: 0.5)
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
        await check(sc.updateNetClass(strict, expectedRevision: sc.ruleCheck?.revision) && sc.document!.revision == beforeStrict + 1
              && sc.netClass(of: air.netID)?.constraints.minimumTrackWidth == 1.0, "classe applicata, rete ancora nella classe, errori da correggere (\(last))")
        // A class the engine refuses (a negative minimum): nothing changes, the edit can be corrected.
        var broken = strict
        broken.constraints.minimumTrackWidth = -1
        let beforeBroken = sc.document!.revision
        await check(!sc.updateNetClass(broken) && sc.document!.revision == beforeBroken && sc.netClass(of: air.netID)?.constraints.minimumTrackWidth == 1.0,
              "classe non valida rifiutata senza toccare il circuito (\(last))")
        check(last.contains("non riuscito"), "rifiuto nella barra di stato")
        var renamed = strict
        renamed.name = "Potenza 2"
        await check(sc.updateNetClass(renamed) && !last.contains("non riuscito"), "dopo un comando riuscito il vecchio rifiuto sparisce (\(last))")
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
        await sc.keepoutClick(at: PCBPoint(centre.x - 1, centre.y - 1), tolerance: 0.1)
        await sc.keepoutClick(at: PCBPoint(centre.x + 1, centre.y + 1), tolerance: 0.1)
        let draftID = sc.keepoutDraft?.id
        check(sc.keepoutDraft?.outline(with: sc.keepoutDraft?.points.last)?.count == 4
              && sc.keepoutDraft?.outline(with: sc.keepoutDraft?.points.first)?.count == 4, "il mouse sull'ultimo o sul primo punto non cambia il rettangolo")
        await sc.ruleCheckReady()
        check(!(sc.ruleCheck?.newErrors ?? []).isEmpty, "area sopra la pista: conflitto mostrato prima di confermare")
        await check(sc.finishKeepout() && sc.keepouts.count == 1 && sc.keepouts[0].id == draftID && sc.keepoutSelection == draftID,
              "area confermata con l'identità dell'anteprima (\(last))")
        await sc.pcbReady()
        check(sc.issues.contains { $0.code == "pcb_keepout" }, "conflitto dell'area nelle VERIFICHE")
        check(sc.keepoutHit(at: centre, tolerance: 0.1)?.id == draftID, "area trovata sotto il mouse")
        await sc.moveKeepout(draftID!, by: PCBPoint(0, 30))
        await sc.pcbReady()
        check(abs(sc.keepouts[0].outline[0].y - (centre.y - 1 + 30)) < 1e-9 && !sc.issues.contains { $0.code == "pcb_keepout" }, "area spostata fuori dal rame")
        await sc.moveKeepout(draftID!, by: PCBPoint(0, -30))
        let beforeInto = sc.document!.revision
        sc.tool = .route
        await sc.routeClick(at: air.from, tolerance: 0.5)
        await sc.routeClick(at: PCBPoint(centre.x, centre.y), tolerance: 0.01)
        await check(!sc.finishRoute() && sc.document!.revision == beforeInto, "pista dentro l'area vietata rifiutata (\(last))")
        sc.tool = .select
        await sc.removeKeepout(draftID!)
        check(sc.keepouts.isEmpty, "area eliminata")
        sc.undo(); sc.undo(); sc.undo(); sc.undo()
        check(sc.keepouts.isEmpty, "annulla fino a prima dell'area")
        // One copper change at a time: a second one while the first runs is refused, not queued.
        let k1 = PCBKeepout(outline: [PCBPoint(1, 1), PCBPoint(3, 1), PCBPoint(3, 3)], layers: [0])
        let k2 = PCBKeepout(outline: [PCBPoint(5, 1), PCBPoint(7, 1), PCBPoint(7, 3)], layers: [0])
        async let first = sc.runPCB(.addKeepout(k1))
        async let second = sc.runPCB(.addKeepout(k2))
        let (r1, r2) = await (first, second)
        check(r1 != r2 && sc.keepouts.count == 1 && !sc.pcbBusy, "un solo comando del rame alla volta (\(r1), \(r2))")
        sc.undo()
        await sc.pcbReady()

        // Esc while a copper change runs: cancelled, never installed afterwards, the draft kept.
        sc.tool = .keepout
        await sc.keepoutClick(at: PCBPoint(10, 20), tolerance: 0.01)
        await sc.keepoutClick(at: PCBPoint(14, 24), tolerance: 0.01)
        let revisionBeforeCancel = sc.document!.revision
        // The copper worker held at its start: cancelled while it certainly runs.
        let workGate = ReadGate(), workKey = URL(fileURLWithPath: "/pcb-work")
        sc.pcbWorkGate = { await workGate.wait(workKey) }
        async let cancelled = sc.finishKeepout()
        await workGate.arrived(workKey)
        sc.cancelPCB()
        await workGate.release(workKey)
        sc.pcbWorkGate = nil
        let installed = await cancelled
        check(!installed && sc.keepouts.isEmpty && sc.document!.revision == revisionBeforeCancel && sc.keepoutDraft != nil && !sc.pcbBusy,
              "annullato durante il lavoro: niente area, bozza conservata (\(last))")
        sc.keepoutDraft = nil
        sc.tool = .select

        // PIANI DI RAME: a VCC plane over the whole top layer, previewed (the engine's fill shown
        // before confirming), confirmed with its identity, filled around the other net's copper.
        guard let vcc = sc.design!.nets.first(where: { $0.name == "VCC" })?.id else { print("FALLITO: rete VCC assente"); exit(1) }
        sc.tool = .zone
        sc.activeLayer = 0
        await sc.zoneClick(at: PCBPoint(1, 1), tolerance: 0.01)
        sc.zoneNet = vcc
        await sc.zoneClick(at: PCBPoint(49, 29), tolerance: 0.01)
        let planeID = sc.zoneDraft?.id
        await sc.ruleCheckReady()
        check(sc.ruleCheck?.refusal == nil && !(sc.ruleCheck?.fills?.first?.cells.isEmpty ?? true), "anteprima del piano col riempimento del motore (\(sc.ruleCheck?.refusal ?? ""))")
        await check(sc.finishZone() && sc.zones.count == 1 && sc.zones[0].id == planeID && sc.zoneSelection == planeID, "piano confermato con l'identità dell'anteprima (\(last))")
        await sc.pcbReady()
        let fill = sc.zoneFill(planeID!)
        check(fill != nil && !fill!.cells.isEmpty && fill!.area > 0 && fill!.area < 48 * 28, "piano riempito attorno al rame dell'altra rete (\(fill?.area ?? -1) mm²)")
        check(sc.zoneHit(at: PCBPoint(25, 25), tolerance: 0.1)?.id == planeID, "piano trovato dal contorno")
        check(sc.copperHit(at: PCBPoint(25, 25), tolerance: 0.1) == nil, "il rame del piano non si seleziona come pista")
        // Thermal reliefs chosen in the bar: the plane's pad gets its four spokes (docs PCB_THERMALS.md).
        var thermal = CircuitModel.ZoneRules()
        thermal.connection = .thermal
        let solidPlane = sc.zone(planeID!)!
        check(await sc.updateZone(thermal.applied(to: solidPlane)) && sc.zone(planeID!)?.connection == .thermal, "piano con termiche (\(last))")
        await sc.pcbReady()
        let relieved = sc.zoneFill(planeID!)
        check(!(relieved?.thermals.isEmpty ?? true) && relieved!.thermals.allSatisfy { $0.connectedSpokes >= 2 } && relieved!.area < fill!.area,
              "termica sulla piazzola VCC, raggi collegati (\(relieved?.thermals.map(\.connectedSpokes) ?? []))")
        var narrow = CircuitModel.ZoneRules(sc.zone(planeID!)!)
        narrow.minimumWidth = 0.2
        check(await sc.updateZone(narrow.applied(to: sc.zone(planeID!)!)) && sc.zone(planeID!)?.minimumWidth == 0.2, "larghezza minima impostata (\(last))")
        // Narrower than the spokes: they go, the pad would have none — refused, the plane unchanged.
        narrow.minimumWidth = 0.35
        check(!(await sc.updateZone(narrow.applied(to: sc.zone(planeID!)!))) && sc.zone(planeID!)?.minimumWidth == 0.2 && last.contains("raggi"),
              "filtro più largo dei ponticelli rifiutato (\(last))")
        sc.undo(); sc.undo()
        await sc.pcbReady()
        check(sc.zone(planeID!)?.connection == .solid && sc.zone(planeID!)?.minimumWidth == 0, "annulla: di nuovo pieno, senza filtro")
        // Rules set before the first click go into the next plane.
        sc.setDraftRules(thermal)
        check(sc.zoneRules.connection == .thermal && sc.zoneDraft == nil, "regole ricordate prima del primo clic")
        sc.setDraftRules(CircuitModel.ZoneRules())

        // An area being drawn across the plane: the preview shows the plane's fill already cut.
        sc.tool = .keepout
        await sc.keepoutClick(at: PCBPoint(24, 0), tolerance: 0.01)
        await sc.keepoutClick(at: PCBPoint(26, 30), tolerance: 0.01)
        await sc.ruleCheckReady()
        let cut = sc.ruleCheck?.fills?.first { $0.zone.id == planeID }
        check(cut != nil && cut!.area < fill!.area - 1, "anteprima dell'area: il piano già tagliato (\(cut?.area ?? -1) < \(fill!.area))")
        check(await sc.finishKeepout() && sc.zoneSelection == nil && sc.keepoutSelection != nil, "area confermata: selezionata solo lei")
        sc.undo()
        await sc.pcbReady()
        sc.zoneSelection = planeID
        sc.tool = .zone

        // Another net's plane over it on the same layer: refused, said before confirming.
        await sc.zoneClick(at: PCBPoint(5, 5), tolerance: 0.01)
        sc.zoneNet = air.netID
        await sc.zoneClick(at: PCBPoint(20, 20), tolerance: 0.01)
        await sc.ruleCheckReady()
        let beforeOverlap = sc.document!.revision
        let refusedBefore = sc.ruleCheck?.refusal != nil
        let overlapped = await sc.finishZone()
        check(refusedBefore && !overlapped && sc.zoneDraft != nil && sc.document!.revision == beforeOverlap,
              "piani di reti diverse sovrapposti rifiutati, bozza conservata (\(last))")
        sc.zoneDraft = nil
        sc.tool = .select
        // Islands off, moved, deleted, undone.
        var plane = sc.zone(planeID!)!
        plane.removeIslands = false
        await check(sc.updateZone(plane) && sc.zone(planeID!)?.removeIslands == false, "isole mantenute")
        await sc.moveZone(planeID!, by: PCBPoint(0, 0.5))
        check(abs(sc.zone(planeID!)!.outline[0].y - 1.5) < 1e-9, "piano spostato")
        await sc.removeZone(planeID!)
        check(sc.zones.isEmpty && sc.zoneSelection == nil, "piano eliminato")
        sc.undo(); sc.undo(); sc.undo()
        check(sc.zone(planeID!)?.removeIslands == true, "annulla riporta il piano com'era")
        sc.undo()
        check(sc.zones.isEmpty, "annulla toglie il piano")
        await sc.pcbReady()

        // A draft made on an older revision is dropped (an undo while drawing).
        sc.tool = .keepout
        await sc.keepoutClick(at: PCBPoint(1, 1), tolerance: 0.1)
        sc.undo()
        check(sc.keepoutDraft == nil, "bozza dell'area scartata al cambio di revisione")
        sc.redo()
        sc.tool = .select
        await sc.pcbReady()
        // A leg over another net's pad is shown as not confirmable, and refused.
        if let other = sc.board!.pads.first(where: { $0.componentID == air.fromComponent && $0.netID != air.netID }) {
            sc.activeLayer = 0
            await sc.routeClick(at: air.from, tolerance: 0.5)
            sc.previewLeg(to: other.center, tolerance: 0.01)
            await sc.routeCheckReady()
            check(!(sc.routeCheck?.blocking ?? []).isEmpty, "anteprima su un'altra rete non confermabile")
            let before = sc.document!.revision
            await sc.routeClick(at: other.center, tolerance: 0.01)
            await check(!sc.finishRoute() && sc.document!.revision == before, "corto rifiutato dal motore (\(last))")
            sc.tool = .select
            check(sc.route == nil, "uscire dallo strumento chiude la pista")
        } else { check(false, "piazzola di un'altra rete non trovata") }
        let outS = FileManager.default.temporaryDirectory.appendingPathComponent("schema-\(UUID().uuidString).ftkc")
        try sc.save(to: outS)
        let reopened = CircuitModel()
        try await reopened.open(outS)
        await reopened.schematicReady()
        check(reopened.design == sc.design && reopened.schematic?.pins.count == 4, "schema e rame salvati e riaperti")
        try? FileManager.default.removeItem(at: outS)
        let outS2 = FileManager.default.temporaryDirectory.appendingPathComponent("rame-\(UUID().uuidString).ftkc")
        try sc.save(to: outS2)

        // A file gone (a stale reference, a moved file): an Italian reason, the open circuit untouched.
        let before = sc.design
        do { try await sc.open(FileManager.default.temporaryDirectory.appendingPathComponent("sparito-\(UUID().uuidString).ftkc")); check(false, "file mancante aperto?") }
        catch { check(CircuitModel.describe(error).contains("non si trova più") && sc.design == before, "file mancante: motivo in italiano, circuito aperto intatto") }

        let notCircuit = FileManager.default.temporaryDirectory.appendingPathComponent("altro-\(UUID().uuidString).json")
        try Data(#"{"outline":[]}"#.utf8).write(to: notCircuit)
        do { try await sc.open(notCircuit); check(false, "JSON qualsiasi aperto?") }
        catch { check(CircuitModel.describe(error).contains("non è un circuito") && sc.design == before, "JSON che non è un circuito: detto in italiano (\(CircuitModel.describe(error)))") }
        try? FileManager.default.removeItem(at: notCircuit)

        // OPEN while other things happen, with a reader that waits until told to go on.
        let gate = ReadGate()
        let slow = CircuitModel()
        slow.report = { last = $0 }
        slow.readFile = { url in await gate.wait(url); return try Data(contentsOf: url) }
        try slow.newCircuit()
        // An edit while the file is being read wins: nothing replaced, the edit kept.
        async let openDuringEdit: Void = slow.open(outS2)
        await gate.arrived(outS2)
        slow.setBoard(width: 70, height: 40, thickness: 1.6)
        let edited = slow.document
        await gate.release(outS2)
        do { try await openDuringEdit; check(false, "apertura sopra una modifica?") }
        catch { check(slow.document == edited && slow.isDirty && CircuitModel.describe(error).contains("è cambiato"), "modifica durante l'apertura conservata") }
        // Two opens: the latest request wins even if it finishes first; the older ends quietly.
        async let older: Void = slow.open(outS2)
        await gate.arrived(outS2)
        async let newer: Void = slow.open(fixture)
        await gate.arrived(fixture)
        await gate.release(fixture)
        try await newer
        let latest = slow.document
        await gate.release(outS2)
        do { try await older; check(false, "apertura superata installata?") }
        catch { check((error as? CircuitEditError)?.isSuperseded == true && slow.document == latest, "vince l'ultima richiesta, la vecchia tace") }
        // Starting a drawing while reading: the open gives way, the drawing stays.
        async let openUnderDraft: Void = slow.open(outS2)
        await slow.pcbReady()
        await gate.arrived(outS2)
        slow.canvas = .board
        slow.tool = .keepout
        await slow.keepoutClick(at: PCBPoint(2, 2), tolerance: 0.01)
        let drawn = slow.document
        await gate.release(outS2)
        do { try await openUnderDraft; check(false, "apertura sopra una bozza?") }
        catch { check(slow.keepoutDraft != nil && slow.document == drawn && (error as? CircuitEditError)?.isSuperseded == true, "bozza iniziata durante l'apertura conservata") }
        // A draft already there when the open starts, changed during the read: the open gives way too.
        async let openOverDraft: Void = slow.open(outS2)
        await gate.arrived(outS2)
        await slow.keepoutClick(at: PCBPoint(6, 6), tolerance: 0.01)
        let grown = slow.keepoutDraft
        await gate.release(outS2)
        do { try await openOverDraft; check(false, "apertura sopra una bozza cambiata?") }
        catch { check(slow.keepoutDraft == grown && grown?.points.count == 2 && slow.document == drawn, "vertice aggiunto durante l'apertura conservato") }
        slow.keepoutDraft = nil
        slow.tool = .select

        // Cancelled while reading: nothing installed.
        let before2 = slow.document
        let cancelledOpen = Task { try await slow.open(outS2) }
        await gate.arrived(outS2)
        cancelledOpen.cancel()
        await gate.release(outS2)
        _ = await cancelledOpen.result
        check(slow.document == before2, "apertura annullata: nulla installato")

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
        try await two.open(outS2)
        await two.pcbReady()
        check(two.pcbIsCurrent && two.design == sc.design && two.design!.board.copper?.tracks.count == 3, "riaperto col suo rame")
        try? FileManager.default.removeItem(at: outS2)

        // PRODUZIONE: the check follows the circuit, profile and variant; closing forgets it.
        let fab = CircuitModel()
        var fabMessage = ""
        fab.report = { fabMessage = $0 }
        // The engine's own fabrication fixture: a routed two-layer board that can be exported.
        let fabFixture = URL(fileURLWithPath: CommandLine.arguments[2]).deletingLastPathComponent().appendingPathComponent("fabrication.json")
        try await fab.open(fabFixture)
        fab.openFabrication()
        await fab.fabricationReady()
        let firstCheck = fab.currentFabrication
        check(firstCheck?.preview?.designID == fab.design?.id && firstCheck?.preview?.revision == fab.document?.revision,
              "verifica di produzione del circuito aperto (\(firstCheck?.failure ?? "-"))")
        fab.closeFabrication()
        check(fab.fabrication == nil && fab.fabricationTask == nil, "chiusa: verifica dimenticata")
        fab.openFabrication()
        check(fab.fabricationTask != nil, "riaperta sulla stessa chiave: verifica rifatta, non in attesa")
        await fab.fabricationReady()
        check(fab.currentFabrication?.preview != nil, "riaperta: verifica pronta")
        fab.fabricationProfile.solderMaskExpansion = 0.1
        check(fab.currentFabrication == nil || fab.currentFabrication?.preview == nil, "profilo cambiato: verifica vecchia non mostrata")
        await fab.fabricationReady()
        check(fab.currentFabrication?.preview?.profile.solderMaskExpansion == 0.1, "verifica col profilo nuovo")
        fab.fabricationProfile.minimumMaskWeb = 0
        await fab.fabricationReady()
        check(fab.currentFabrication?.failure != nil && !fab.canExportFabrication, "profilo non valido: motivo, niente export")
        fab.fabricationProfile = FabricationProfile()
        await fab.fabricationReady()

        let parent = FileManager.default.temporaryDirectory.appendingPathComponent("produzione-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        func published() -> [String] { ((try? FileManager.default.contentsOfDirectory(atPath: parent.path)) ?? []).sorted() }
        if fab.canExportFabrication {
            let docBefore = fab.document
            let folder = await fab.exportFabrication(into: parent, name: "Scheda")
            check(folder?.lastPathComponent == "Scheda" && fab.document == docBefore && !fab.canUndo && !fab.isDirty,
                  "export in una cartella nuova, circuito intatto, nessun passo di annulla (\(fabMessage))")
            let files = (try? FileManager.default.contentsOfDirectory(atPath: folder?.path ?? "")) ?? []
            check(files.contains("board-F_Cu.gbr") && files.contains("board-PTH.drl") && files.count == 17 && !files.contains { $0.hasPrefix(".") },
                  "Gerber, forature e montaggio scritti, niente temporanei (\(files.count))")
            let again = await fab.exportFabrication(into: parent, name: "Scheda")
            check(fab.fabricationOutcome?.folder == again && fab.fabricationOutcome?.message.contains("Scheda 2") == true, "esito dell'export nel pannello")
            check(again?.lastPathComponent == "Scheda 2" && published() == ["Scheda", "Scheda 2"], "la cartella esistente non si tocca: «Scheda 2» (\(published()))")

            // Suspended while staging: a change, an open of the same circuit, or a cancel → nothing published.
            let stageGate = ReadGate()
            let stagingKey = parent.appendingPathComponent("staging")
            fab.stageFabrication = { files, parent in
                let temp = try CircuitModel.stageFiles(files, in: parent)
                await stageGate.wait(stagingKey)
                return temp
            }
            let saved = FileManager.default.temporaryDirectory.appendingPathComponent("produzione-\(UUID().uuidString).ftkc")
            try fab.save(to: saved)
            for change in ["revisione", "stesso circuito riaperto", "annullato"] {
                await fab.fabricationReady()
                let exporting = Task { await fab.exportFabrication(into: parent, name: "Cambiata") }
                await stageGate.arrived(stagingKey)
                switch change {
                case "revisione": fab.setBoard(width: 41, height: 30, thickness: 1.6)
                case "annullato": exporting.cancel()
                default: try await fab.open(saved)
                }
                await stageGate.release(stagingKey)
                let result = await exporting.value
                check(result == nil && published() == ["Scheda", "Scheda 2"], "export sospeso, \(change): nessuna cartella pubblicata (\(published()))")
            }
            try? FileManager.default.removeItem(at: saved)
        } else {
            check(false, "scheda di prova non esportabile: \(fab.currentFabrication?.preview?.issues.map(\.message) ?? [])")
        }
        try? FileManager.default.removeItem(at: parent)

        try await circuitToolTests(fixture: fabFixture, check: check)

        if failures > 0 { fatalError("\(failures) verifiche fallite") }
        print("OK: circuiti — PCB e schema da nuovo: componenti, fili, etichette, NC, giunzioni, posa sul PCB, piste, via e strati, classi di rete, aree vietate, piani di rame, produzione, strumenti circuit_* dell'assistente, annulla, salva e riapri")
    }
}

/// A file reader that stops at each file until the test lets it go on (keyed by the standardized
/// path: a relative file URL and the same file resolved are different URLs).
actor ReadGate {
    private var waiting: [String: CheckedContinuation<Void, Never>] = [:]
    private var arrivals: [String: [CheckedContinuation<Void, Never>]] = [:]
    private func key(_ url: URL) -> String { url.standardizedFileURL.path }
    func wait(_ url: URL) async {
        let k = key(url)
        await withCheckedContinuation { c in
            waiting[k] = c
            arrivals.removeValue(forKey: k)?.forEach { $0.resume() }
        }
    }
    /// Until a read of `url` is waiting.
    func arrived(_ url: URL) async {
        let k = key(url)
        if waiting[k] != nil { return }
        await withCheckedContinuation { c in arrivals[k, default: []].append(c) }
    }
    func release(_ url: URL) { waiting.removeValue(forKey: key(url))?.resume() }
}
