import AppKit
import ElectronicsCore
import Foundation
import SwiftUI

/// PRODUZIONE › Importa in the app (T108 with Codex's engine): three files chosen in any order,
/// the tables told apart by the engine, preview then one step, lots, picking, native edits
/// refused, save and reopen, another lot of the same board, a native circuit left alone. With
/// FTK_MANUFACTURING_FIXTURE_DIR also the real package (never in the repository).
@MainActor
func manufacturingTests(check: (Bool, String) -> Void) async throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("cam-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let header = "%FSLAX46Y46*%\n%MOMM*%\n%LPD*%\n"
    let gerbers = [
        "scheda.gm1": header + "%ADD10C,0.100000*%\nD10*\nX0Y0D02*\nX40000000Y0D01*\nX40000000Y30000000D01*\nX0Y30000000D01*\nX0Y0D01*\nM02*\n",
        "scheda.gtl": header + "%ADD11R,1.000000X1.200000*%\nD11*\nX10000000Y10000000D03*\nX12000000Y10000000D03*\n%ADD12C,0.250000*%\nD12*\nX12000000Y10000000D02*\nX20000000Y15000000D01*\nM02*\n",
        "scheda.gbl": header + "%ADD13C,1.500000*%\nD13*\nX30000000Y20000000D03*\nM02*\n",
        "scheda-PTH.drl": "M48\nMETRIC\nT1C0.800\n%\nT1\nX30.0Y20.0\nM30\n",
    ]
    let src = dir.appendingPathComponent("src")
    try FileManager.default.createDirectory(at: src, withIntermediateDirectories: true)
    for (name, text) in gerbers { try text.write(to: src.appendingPathComponent(name), atomically: true, encoding: .utf8) }
    let zip = dir.appendingPathComponent("Scheda prova.zip")
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
    process.currentDirectoryURL = src
    process.arguments = ["-q", zip.path] + gerbers.keys.sorted()
    try process.run(); process.waitUntilExit()
    // T1 is only in the positions: excluded from the lot, never removed.
    let bom = dir.appendingPathComponent("distinta.csv"), cpl = dir.appendingPathComponent("tabella.csv")
    try "Comment,Designator,Footprint,LCSC\n10k,R1,R0805,C17414\n".write(to: bom, atomically: true, encoding: .utf8)
    try "Designator,Mid X,Mid Y,Layer,Rotation\nR1,11,10,Top,0\nT1,30,20,Bottom,90\n".write(to: cpl, atomically: true, encoding: .utf8)

    let c = CircuitModel()
    var last = ""
    c.report = { last = $0 }
    try c.newCircuit()
    c.prepareManufacturingImport([cpl, zip, bom])   // any order: the engine tells the tables apart
    await c.importReady()
    guard let p = c.manufacturingProposal else { check(false, "anteprima import produzione (\(last))"); return }
    check(p.files.bom == bom && p.files.positions == cpl && p.files.archive == zip, "BOM e posizioni riconosciute dal contenuto")
    check(!p.inNewCircuit && p.addsLotTo == nil && p.canApply, "nel circuito nuovo aperto")
    check(!c.canUndo && c.design?.manufacturing == nil, "anteprima senza modifiche")
    let r1 = p.package.components.first { $0.reference == "R1" }, t1 = p.package.components.first { $0.reference == "T1" }
    check(r1 != nil && t1 != nil && p.package.isFitted(r1!.id) && !p.package.isFitted(t1!.id), "R1 montato, T1 escluso ma presente")
    check(p.package.drills.count == 1 && p.package.layers.count == 3, "3 strati e 1 foro (\(p.package.layers.count), \(p.package.drills.count))")

    c.confirmManufacturingImport()
    check(c.isManufacturing && c.document?.past.count == 1, "importata in un passo (\(last))")
    check(c.issues.contains { $0.code == "manufacturing_not_fitted" && $0.subjectIDs == [t1!.id] }, "T1 segnalato escluso")
    // The board view as the app shows it: the layers in the first frames, without mouse, hover or
    // zoom (T110: they appeared only at the next unrelated redraw), and a layer switched off.
    let view = CAMFrame(c)
    var blue = 0
    for _ in 0..<60 where blue == 0 { try await Task.sleep(for: .milliseconds(50)); blue = view.samples(bottomCopper: true) }
    check(blue > 5, "vista CAM: rame sotto visibile nel primo fotogramma senza interazione (\(blue) campioni)")
    c.camHiddenLayers.insert(.bottomCopper)
    var hiddenBlue = blue
    for _ in 0..<20 where hiddenBlue > 0 { try await Task.sleep(for: .milliseconds(50)); hiddenBlue = view.samples(bottomCopper: true) }
    check(hiddenBlue == 0, "strato spento: sparisce senza interazione (\(hiddenBlue))")
    c.camHiddenLayers.remove(.bottomCopper)
    await c.camSnapshotTask?.value
    check(c.manufacturingComponent(at: PCBPoint(11, 10.1), tolerance: 0.5) == r1!.id, "clic sul marcatore di R1")

    // Lots: mount T1 in a copy; the first lot keeps its choice; undo is per step.
    c.addLot(named: "Prototipi")
    c.setFitted(t1!.id, true)
    check(c.manufacturing?.lots.count == 2 && c.manufacturing?.isFitted(t1!.id) == true, "lotto Prototipi con T1 montato")
    c.selectLot(p.package.activeLotID)
    check(c.manufacturing?.isFitted(t1!.id) == false, "il primo lotto resta senza T1")
    c.undo()
    check(c.manufacturing?.activeLot?.name == "Prototipi", "annulla la scelta del lotto")

    // Native edits are refused on CAM artwork, nothing changes.
    let before = c.document
    c.setBoard(width: 80, height: 60, thickness: 1.6)
    check(c.document == before, "modifica nativa rifiutata sulla scheda importata (\(last))")

    // A reading overtaken by a reopen: the worker's result is never installed.
    let gate = ReadGate()
    let saved0 = dir.appendingPathComponent("prima.ftkc")
    try c.save(to: saved0)
    c.readLibraryFile = { url in
        if url == zip { await gate.wait(url) }   // only the first read stops (the gate is not sticky)
        return try Data(contentsOf: url)
    }
    c.prepareManufacturingImport([zip, bom, cpl])
    let pending = c.importTask
    await gate.arrived(zip)
    try await c.open(saved0)
    await gate.release(zip)
    await pending?.value
    check(c.manufacturingProposal == nil && c.importing == nil && c.importTask == nil, "lettura superata da una riapertura: nessuna anteprima")
    c.readLibraryFile = { url in try Data(contentsOf: url) }

    // A proposal made before another change: Conferma refuses it, nothing imported twice.
    c.prepareManufacturingImport([zip, bom, cpl])
    await c.importReady()
    check(c.manufacturingProposal != nil, "anteprima di nuovo lotto")
    c.setFitted(t1!.id, !(c.manufacturing?.isFitted(t1!.id) ?? false))
    let lotsBefore = c.manufacturing?.lots.count
    c.confirmManufacturingImport()
    check(c.manufacturing?.lots.count == lotsBefore && last.contains("cambiato"), "conferma su revisione cambiata rifiutata (\(last))")
    c.undo()

    // Save and reopen.
    let saved = dir.appendingPathComponent("importata.ftkc")
    try c.save(to: saved)
    let reopened = CircuitModel()
    try await reopened.open(saved)
    check(reopened.manufacturing == c.manufacturing && reopened.document?.formatVersion == 8, "salva e riapri con lotti (formato 8)")

    // The assistant's tools: CAM said as such, lots editable, native actions and checks refused.
    func tok() -> String { c.designRevision }
    let info = await c.call("circuit_info", arguments: [:])
    check(info.structured?["kind"]?.string == "manufacturing" && info.structured?["copper_check"] == nil
          && info.structured?["components"]?.array?.count == 2 && info.structured?["lots"]?.array?.count == 2, "circuit_info: scheda importata con lotti (\(info.text))")
    let drc = await c.call("circuit_fabrication_check", arguments: [:])
    check(drc.isError && drc.text.contains("Non applicabile"), "verifica produzione non applicabile, non «superata»")
    let issuesCAM = await c.call("circuit_issues", arguments: [:])
    check(issuesCAM.structured?["copper_check"]?.string == "not_applicable", "circuit_issues: DRC non applicabile")
    let move = await c.call("circuit_preview", arguments: ["action": "move_component", "component": "R1", "x": 1, "y": 1, "expected_revision": .string(tok())])
    check(move.isError && move.text.contains("set_fitted"), "azione nativa rifiutata con le azioni possibili")
    let exclude = await c.call("circuit_preview", arguments: ["action": "set_fitted", "component": "r1", "fitted": false, "expected_revision": .string(tok())])
    if let id = exclude.structured?["preview_id"]?.string {
        check(c.manufacturing?.isFitted(r1!.id) == true, "anteprima set_fitted senza modifiche")
        let done = await c.call("circuit_apply", arguments: ["preview_id": .string(id), "expected_revision": .string(tok())])
        check(!done.isError && c.manufacturing?.isFitted(r1!.id) == false, "set_fitted dalla chat: R1 escluso (\(done.text))")
        _ = await c.call("circuit_undo", arguments: ["expected_revision": .string(tok())])
        check(c.manufacturing?.isFitted(r1!.id) == true, "circuit_undo lo rimonta")
    } else { check(false, "anteprima set_fitted (\(exclude.text))") }
    let pick = await c.call("circuit_preview", arguments: ["action": "select_lot", "lot": "Prototipi", "expected_revision": .string(tok())])
    check(!pick.isError, "select_lot per nome (\(pick.text))")
    let nativeRefused = await CircuitModel.nativeLotRefusal()
    check(nativeRefused, "azioni di lotto rifiutate su un circuito nativo")

    // The same board again with another BOM: a new lot under a new name, same artwork.
    try "Comment,Designator,Footprint,LCSC\n10k,R1,R0805,C17414\nNTC,T1,0603,C77131\n".write(to: bom, atomically: true, encoding: .utf8)
    c.prepareManufacturingImport([zip, bom, cpl])
    await c.importReady()
    if let again = c.manufacturingProposal {
        check(again.addsLotTo != nil && !again.inNewCircuit && again.package.activeLot?.name == "Lotto 2", "reimport: nuovo lotto «Lotto 2» della stessa scheda")
        c.confirmManufacturingImport()
        check(c.manufacturing?.lots.count == 3 && c.manufacturing?.isFitted(t1!.id) == true, "terzo lotto con T1 dalla BOM (\(last))")
    } else { check(false, "reimport stessa scheda (\(last))") }

    // A native circuit: the import goes to a new circuit, the native one untouched until Conferma.
    let native = CircuitModel()
    try await native.open(URL(fileURLWithPath: CommandLine.arguments[1]))   // the example: components, nets
    native.prepareManufacturingImport([zip, bom, cpl])
    await native.importReady()
    check(native.manufacturingProposal?.inNewCircuit == true && !native.isManufacturing, "circuito nativo: import proposto in un circuito nuovo (\(last))")
    native.cancelImport()

    // Close (the tab's X, ⌘W): a saved circuit closes; the native one kept its board.
    native.closeCircuit()
    check(native.document == nil && native.url == nil && native.title == "Circuito", "chiudi circuito salvato")

    // Two tables that are both BOMs: said so, nothing prepared.
    let other = dir.appendingPathComponent("altra.csv")
    try FileManager.default.copyItem(at: bom, to: other)
    let wrong = CircuitModel()
    var wrongLast = ""
    wrong.report = { wrongLast = $0 }
    try wrong.newCircuit()
    wrong.prepareManufacturingImport([zip, bom, other])
    await wrong.importReady()
    check(wrong.manufacturingProposal == nil && wrongLast.contains("distinguere"), "due BOM: rifiutato con il motivo (\(wrongLast))")

    // The real package, when given (Ross's files stay in Downloads).
    if let path = ProcessInfo.processInfo.environment["FTK_MANUFACTURING_FIXTURE_DIR"] {
        let folder = URL(fileURLWithPath: path)
        let real = CircuitModel()
        var realLast = ""
        real.report = { realLast = $0 }
        try real.newCircuit()
        real.prepareManufacturingImport(["Ballgunmain_hw.zip", "bom.csv", "positions.csv"].map { folder.appendingPathComponent($0) })
        await real.importReady()
        real.confirmManufacturingImport()
        let m = real.manufacturing
        print("· reale: \(m?.layers.count ?? 0) strati, \(m?.drills.count ?? 0) fori, \(m?.activeLot?.fittedComponentIDs.count ?? 0)/\(m?.components.count ?? 0) montati — \(realLast)")
        check(m?.components.count == 86 && m?.activeLot?.fittedComponentIDs.count == 84 && m?.drills.count == 158, "pacchetto reale: 86 componenti, 84 montati, 158 forature")
    }
}

extension CircuitModel {
    /// Lot actions on a native circuit: refused with the reason.
    static func nativeLotRefusal() async -> Bool {
        let m = CircuitModel()
        guard (try? m.newCircuit()) != nil else { return false }
        let r = await m.call("circuit_preview", arguments: ["action": "add_lot", "name": "X", "expected_revision": .string(m.designRevision)])
        return r.isError && r.text.contains("solo per una scheda importata")
    }
}

/// CAMBoardView hosted in an offscreen window, read back as pixels.
@MainActor
final class CAMFrame {
    let host: NSHostingView<AnyView>
    let window: NSWindow
    init(_ c: CircuitModel) {
        _ = NSApplication.shared
        host = NSHostingView(rootView: AnyView(CAMBoardView().environment(c).frame(width: 1000, height: 800)))
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 800), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
    }
    /// Samples (every 8 px) of the bottom copper's blue.
    func samples(bottomCopper: Bool) -> Int {
        host.layoutSubtreeIfNeeded(); host.display()
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return -1 }
        host.cacheDisplay(in: host.bounds, to: rep)
        var n = 0
        for y in stride(from: 0, to: rep.pixelsHigh, by: 8) { for x in stride(from: 0, to: rep.pixelsWide, by: 8) {
            if let c = rep.colorAt(x: x, y: y), c.blueComponent > 0.6, c.redComponent < 0.45, c.greenComponent > 0.3, c.greenComponent < 0.75 { n += 1 } } }
        return n
    }
}
