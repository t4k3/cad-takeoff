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
    try "Designator,Mid X,Mid Y,Layer,Rotation\nR1,11,10,Top,0\nT1,25,20,Bottom,90\n".write(to: cpl, atomically: true, encoding: .utf8)

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

    // T111: the assembled board — models, picking, alignment previewed then one step, thickness.
    try await assemblyTests(c, r1: r1!.id, t1: t1!.id, check: check)

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
    check(reopened.manufacturing == c.manufacturing && reopened.document?.formatVersion == 9, "salva e riapri con lotti (formato 9)")

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

    // Apri: circuits enabled by extension, also as file references; other files not.
    let filter = CircuitFileFilter()
    let savedRef = (saved as NSURL).fileReferenceURL() ?? saved
    check(filter.panel(NSObject(), shouldEnable: saved) && filter.panel(NSObject(), shouldEnable: savedRef)
          && !filter.panel(NSObject(), shouldEnable: bom) && filter.panel(NSObject(), shouldEnable: dir),
          "Apri: .ftkc abilitato (anche come riferimento), .csv no, cartelle sì")

    // One ZIP chosen: the package inside it (as KiCad exports it for JLCPCB), extras named.
    let pack = dir.appendingPathComponent("pacchetto")
    try FileManager.default.createDirectory(at: pack, withIntermediateDirectories: true)
    for f in [zip, bom, cpl] { try FileManager.default.copyItem(at: f, to: pack.appendingPathComponent(f.lastPathComponent)) }
    try "R1:1\nT1:1\n".write(to: pack.appendingPathComponent("designators.csv"), atomically: true, encoding: .utf8)
    let bundle = dir.appendingPathComponent("scheda_2026-09-30.zip")
    let zipper = Process()
    zipper.executableURL = URL(fileURLWithPath: "/usr/bin/zip"); zipper.currentDirectoryURL = pack
    zipper.arguments = ["-q", bundle.path, zip.lastPathComponent, bom.lastPathComponent, cpl.lastPathComponent, "designators.csv"]
    try zipper.run(); zipper.waitUntilExit()
    let fromBundle = CircuitModel()
    var bundleLast = ""
    fromBundle.report = { bundleLast = $0 }
    try fromBundle.newCircuit()
    fromBundle.prepareManufacturingImport([bundle])
    await fromBundle.importReady()
    let bp = fromBundle.manufacturingProposal
    check(bp?.files.bom.lastPathComponent == bom.lastPathComponent && bp?.files.positions.lastPathComponent == cpl.lastPathComponent
          && bp?.ignored == ["designators.csv"] && bp?.package.components.count == 2, "pacchetto in un solo ZIP: BOM e posizioni trovate, extra dichiarati (\(bundleLast))")
    let alone = CircuitModel()
    var aloneLast = ""
    alone.report = { aloneLast = $0 }
    try alone.newCircuit()
    alone.prepareManufacturingImport([zip])
    await alone.importReady()
    check(alone.manufacturingProposal == nil && aloneLast.contains("non contiene un pacchetto"), "solo lo ZIP dei Gerber: chiesto di aggiungere BOM e posizioni")

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

    // A real four-layer KiCad package in one ZIP, when given (Ross's forcedeck, never in the repo).
    if let path = ProcessInfo.processInfo.environment["FTK_FORCEDECK_BUNDLE"] {
        let fd = CircuitModel()
        var fdLast = ""
        fd.report = { fdLast = $0 }
        try fd.newCircuit()
        fd.prepareManufacturingImport([URL(fileURLWithPath: path)])
        await fd.importReady()
        fd.confirmManufacturingImport()
        let m = fd.manufacturing
        print("· forcedeck: \(m?.layers.map(\.kind.rawValue) ?? []) \(m?.drills.count ?? 0) fori, \(m?.activeLot?.fittedComponentIDs.count ?? 0)/\(m?.components.count ?? 0) — \(fdLast)")
        check(m?.layers.contains { $0.kind == .inner1 } == true && m?.layers.contains { $0.kind == .inner2 } == true
              && m?.components.count == 111, "forcedeck a 4 strati importato dal pacchetto")
        await fd.assemblyReady()
        check(fd.assembly != nil, "forcedeck: scheda assemblata (\(fd.assemblyFailure ?? ""))")
    }

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
    /// Samples (every 8 px) of the finished board's solder-mask green.
    func samples(maskGreen: Bool) -> Int {
        count { c in c.greenComponent > 0.25 && c.greenComponent < 0.45 && c.redComponent < 0.15 && c.blueComponent < 0.25 }
    }

    /// Samples (every 8 px) of the bottom copper's blue.
    func samples(bottomCopper: Bool) -> Int {
        count { c in c.blueComponent > 0.6 && c.redComponent < 0.45 && c.greenComponent > 0.3 && c.greenComponent < 0.75 }
    }

    private func count(_ match: (NSColor) -> Bool) -> Int {
        host.layoutSubtreeIfNeeded(); host.display()
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return -1 }
        host.cacheDisplay(in: host.bounds, to: rep)
        var n = 0
        for y in stride(from: 0, to: rep.pixelsHigh, by: 8) { for x in stride(from: 0, to: rep.pixelsWide, by: 8) {
            if let c = rep.colorAt(x: x, y: y), match(c) { n += 1 } } }
        return n
    }
}

/// The assembled board in the app: the engine's assembly built off the main thread, the same
/// selection as the list, the model/alignment draft (preview without changes, OK = one step,
/// refused when stale), the thickness, and the 2D assembled view's first frame without input.
@MainActor
func assemblyTests(_ c: CircuitModel, r1: UUID, t1: UUID, check: (Bool, String) -> Void) async throws {
    await c.assemblyReady()
    guard let s = c.assembly?.snapshot else { check(false, "assemblata: nessuno snapshot (\(c.assemblyFailure ?? ""))"); return }
    let i1 = s.instances.first { $0.id == r1 }, it = s.instances.first { $0.id == t1 }
    check(i1?.quality == .approximate && !(i1?.parts.isEmpty ?? true), "R1 (R0805) con modello approssimato")
    check(it?.quality == .missing && it?.parts.isEmpty == true, "T1 senza impronta: nessun corpo inventato")
    let mesh = AssemblyMesh(s, outline: c.manufacturing!.bounds)
    let top = mesh.batches.first { $0.look == .boardTop }, bottom = mesh.batches.first { $0.look == .boardBottom }
    check((top?.triangleCount ?? 0) > 0 && top?.uvs.count == top?.positions.count && (bottom?.triangleCount ?? 0) > 0,
          "substrato: facce sopra/sotto con coordinate del disegno")
    check(mesh.batches.contains { $0.component == r1 } && mesh.batches.contains { $0.component == t1 && $0.look == .missing },
          "mesh: corpi di R1, indicatore per T1")
    let hitR1 = mesh.pick(origin: SIMD3(11, 10, 50), direction: SIMD3(0, 0, -1), visible: { _ in true })
    check(hitR1 == r1, "3D: un raggio dall'alto su R1 lo sceglie")
    // T1 is on the bottom: from above, the substrate hides it; from below it is picked.
    let t1p = it!.position!
    let fromAbove = mesh.pick(origin: SIMD3(Float(t1p.x), Float(t1p.y), 50), direction: SIMD3(0, 0, -1), visible: { _ in true })
    let fromBelow = mesh.pick(origin: SIMD3(Float(t1p.x), Float(t1p.y), -50), direction: SIMD3(0, 0, 1), visible: { _ in true })
    check(fromAbove != t1 && fromBelow == t1, "3D: il substrato copre il lato opposto (\(String(describing: fromAbove)))")
    c.assemblySide = .top
    check(c.assemblyComponent(at: PCBPoint(11, 10), tolerance: 0.2) == r1, "2D assemblata: clic su R1")

    // 3D: the board picture can arrive after the assembly — the board is then rebuilt with it.
    let scene = AssemblyScene()
    scene.update(c.assembly!, package: c.manufacturing!, art: nil, selection: nil, showExcluded: true, draft: nil)
    check(!scene.boardIsPictured && scene.root.children.count > 2, "3D senza disegno: scheda senza foto, corpi presenti")
    scene.update(c.assembly!, package: c.manufacturing!, art: CAMDrawing(c.manufacturing!), selection: nil, showExcluded: true, draft: nil)
    check(scene.boardIsPictured, "3D: la foto della scheda arriva dopo e viene applicata")
    // Rendered from above: the copper track lies where the board has it, not mirrored in y
    // (the picture was upside down on the substrate, T111 QA).
    if let pixels = await renderFromAbove(scene, centre: SIMD3(20, 15, 0), size: 256) {
        func green(_ x: Double, _ y: Double) -> Double {
            let half = tan(17.5 * Double.pi / 180) * (100 - 1.6)
            let px = Int(128 + (x - 20) / half * 128), py = Int(128 - (y - 15) / half * 128)
            return pixels(px, py)
        }
        // The track (12,10)→(20,15), lighter green than the mask; its mirror in y is bare mask.
        let track = green(16, 12.5), mirrored = green(16, 17.5)
        check(track > mirrored + 0.03 && track > mirrored * 1.15, "3D dall'alto: la pista è dove la scheda la ha, non specchiata (\(track) vs \(mirrored))")
    } else { check(false, "3D: rendering fuori schermo non riuscito") }

    // Alignment: a draft previews without changing anything; OK is one step; undo takes it back.
    let revision = c.document!.revision
    var binding = ManufacturingModelBinding(modelKey: i1!.modelKey!)
    binding.offset = PCBPoint3(0.5, 0, 0)
    c.draftAlignment(r1, binding)
    check(c.alignDraft?.preview == nil, "prima dell'anteprima niente OK")
    c.confirmAlignment()
    check(c.document!.revision == revision, "OK rifiutato finché manca l'anteprima")
    await c.alignmentPreviewReady()
    let moved = c.alignDraft?.preview?.polygons.flatMap(\.points).map(\.x).max() ?? 0
    let before = i1!.polygons.flatMap(\.points).map(\.x).max() ?? 0
    check(abs(moved - before - 0.5) < 1e-6 && c.document!.revision == revision, "anteprima spostata di 0,5 mm, documento invariato")
    c.confirmAlignment()
    check(c.document!.revision == revision + 1 && c.manufacturing?.components.first { $0.id == r1 }?.modelBinding == binding, "OK: un passo, allineamento salvato")
    c.undo()
    check(c.manufacturing?.components.first { $0.id == r1 }?.modelBinding == nil, "annulla l'allineamento")
    // A draft made before another change is refused on OK.
    c.draftAlignment(r1, binding)
    await c.alignmentPreviewReady()
    c.setFitted(t1, !(c.manufacturing?.isFitted(t1) ?? false))
    c.confirmAlignment()
    check(c.manufacturing?.components.first { $0.id == r1 }?.modelBinding == nil, "allineamento su revisione cambiata rifiutato")
    c.undo()

    // Thickness: set, then back to the estimate.
    c.setBoardThickness(1.0)
    await c.assemblyReady()
    check(c.assembly?.snapshot.boardThickness == 1.0 && c.assembly?.snapshot.isBoardThicknessAssumed == false, "spessore 1,0 mm")
    c.setBoardThickness(nil)
    await c.assemblyReady()
    check(c.assembly?.snapshot.isBoardThicknessAssumed == true, "spessore di nuovo stimato")

    // The same through the assistant's tools (chat and MCP).
    func tok() -> String { c.designRevision }
    func model(_ info: ToolResult, _ ref: String) -> JSONValue? {
        info.structured?["components"]?.array?.first { $0["reference"]?.string == ref }?["model"]
    }
    let catalog = await c.call("circuit_models", arguments: [:])
    check(catalog.structured?["models"]?.array?.contains { $0["key"]?.string == "ftk.r0805.v1" } == true, "circuit_models: chiavi del catalogo")
    let info0 = await c.call("circuit_info", arguments: [:])
    check(model(info0, "R1")?["quality"]?.string == "approximate" && model(info0, "T1")?["quality"]?.string == "missing"
          && info0.structured?["board_thickness_assumed"]?.bool == true, "circuit_info: modello, qualità e spessore stimato")
    let offset = await c.call("circuit_preview", arguments: ["action": "set_component_model", "component": "R1",
                                                             "offset": ["x": 0.25, "y": 0, "z": 0], "expected_revision": .string(tok())])
    check(!offset.isError && c.manufacturing?.components.first { $0.id == r1 }?.modelBinding == nil, "anteprima set_component_model senza modifiche (\(offset.text))")
    if let id = offset.structured?["preview_id"]?.string {
        let done = await c.call("circuit_apply", arguments: ["preview_id": .string(id), "expected_revision": .string(tok())])
        let b = c.manufacturing?.components.first { $0.id == r1 }?.modelBinding
        check(!done.isError && b?.modelKey == "ftk.r0805.v1" && b?.offset.x == 0.25, "set_component_model applicato: modello automatico con spostamento")
    }
    let unknown = await c.call("circuit_preview", arguments: ["action": "set_component_model", "component": "T1", "offset": ["x": 1], "expected_revision": .string(tok())])
    check(unknown.isError && unknown.text.contains("model_key"), "T1 senza modello automatico: serve model_key")
    let thick = await c.call("circuit_preview", arguments: ["action": "set_board_thickness", "thickness": 1.2, "expected_revision": .string(tok())])
    c.setFitted(t1, !(c.manufacturing?.isFitted(t1) ?? false))
    if let id = thick.structured?["preview_id"]?.string {
        let stale = await c.call("circuit_apply", arguments: ["preview_id": .string(id), "expected_revision": .string(tok())])
        check(stale.isError && c.manufacturing?.assemblySettings?.boardThickness == nil, "anteprima superata da un'altra modifica: rifiutata")
    }
    c.undo()
    let thick2 = await c.call("circuit_preview", arguments: ["action": "set_board_thickness", "thickness": 1.2, "expected_revision": .string(tok())])
    if let id = thick2.structured?["preview_id"]?.string { _ = await c.call("circuit_apply", arguments: ["preview_id": .string(id), "expected_revision": .string(tok())]) }
    // Reopened: the same through circuit_info.
    let file = FileManager.default.temporaryDirectory.appendingPathComponent("assemblata-\(UUID().uuidString).ftkc")
    try c.save(to: file)
    let again = CircuitModel()
    try await again.open(file)
    let info1 = await again.call("circuit_info", arguments: [:])
    check(info1.structured?["board_thickness"]?.number == 1.2 && model(info1, "R1")?["offset"]?["x"]?.number == 0.25
          && model(info1, "R1")?["automatic"]?.bool == false, "riaperto: spessore e allineamento via circuit_info")
    try? FileManager.default.removeItem(at: file)
    let auto = await c.call("circuit_preview", arguments: ["action": "set_component_model", "component": "R1", "expected_revision": .string(tok())])
    if let id = auto.structured?["preview_id"]?.string { _ = await c.call("circuit_apply", arguments: ["preview_id": .string(id), "expected_revision": .string(tok())]) }
    check(c.manufacturing?.components.first { $0.id == r1 }?.modelBinding == nil, "solo component: di nuovo automatico")
    c.setBoardThickness(nil)
    await c.assemblyReady()

    // The 2D assembled view: the finished board (mask green) in the first frames, no input.
    c.camView = .assembly
    let view = CAMFrame(c)
    var green = 0
    for _ in 0..<60 where green == 0 { try await Task.sleep(for: .milliseconds(50)); green = view.samples(maskGreen: true) }
    check(green > 5, "vista assemblata: scheda finita nel primo fotogramma senza interazione (\(green))")
    c.camView = .gerber
}

import Metal
import RealityKit

/// The assembled scene rendered offscreen from straight above its centre (100 mm up, board +y
/// up on screen): the green channel at a pixel (0…1).
@MainActor
func renderFromAbove(_ scene: AssemblyScene, centre: SIMD3<Float>, size: Int) async -> ((Int, Int) -> Double)? {
    guard let device = MTLCreateSystemDefaultDevice(), let renderer = try? RealityRenderer() else { return nil }
    scene.place(eye: centre + SIMD3(0, 0, 100), target: centre, up: SIMD3(0, 1, 0))
    renderer.entities.append(scene.root)
    renderer.entities.append(scene.cameraEntity)
    renderer.activeCamera = scene.cameraEntity
    renderer.cameraSettings.colorBackground = .color(CGColor(gray: 0, alpha: 1))
    let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: size, height: size, mipmapped: false)
    d.usage = [.renderTarget, .shaderRead]; d.storageMode = .shared
    guard let texture = device.makeTexture(descriptor: d), let output = try? RealityRenderer.CameraOutput(.singleProjection(colorTexture: texture)) else { return nil }
    let done: Bool = await withCheckedContinuation { c in
        do { try renderer.updateAndRender(deltaTime: 1 / 60, cameraOutput: output, onComplete: { _ in c.resume(returning: true) }) }
        catch { c.resume(returning: false) }
    }
    guard done else { return nil }
    var bytes = [UInt8](repeating: 0, count: size * size * 4)
    texture.getBytes(&bytes, bytesPerRow: size * 4, from: MTLRegionMake2D(0, 0, size, size), mipmapLevel: 0)
    renderer.entities.removeAll()
    if let path = ProcessInfo.processInfo.environment["FTK_RENDER_DUMP"],
       let provider = CGDataProvider(data: Data(bytes) as CFData),
       let image = CGImage(width: size, height: size, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: size * 4,
                           space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
                           provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent) {
        try? NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }
    return { x, y in
        guard (0..<size).contains(x), (0..<size).contains(y) else { return 0 }
        // A few pixels around, BGRA.
        var sum = 0.0, n = 0.0
        for yy in max(0, y - 1)...min(size - 1, y + 1) { for xx in max(0, x - 1)...min(size - 1, x + 1) { sum += Double(bytes[(yy * size + xx) * 4 + 1]) / 255; n += 1 } }
        return sum / n
    }
}
