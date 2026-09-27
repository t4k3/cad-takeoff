import ElectronicsCore
import Foundation

/// T100: the assistant's CIRCUITI tools — same transactions as the workspace, preview then
/// confirmation of the same command, tokens bound to identity, open file and revision.
@MainActor
func circuitToolTests(fixture: URL, check: (Bool, String) -> Void) async throws {
    let m = CircuitModel()
    check(m.tools.allSatisfy { $0.name.hasPrefix("circuit_") } && m.tools.count == 9, "strumenti circuit_* (\(m.tools.count))")
    check(m.tools.filter { !$0.isReadOnly }.allSatisfy { ($0.inputSchema["required"]?.array ?? []).contains("expected_revision") },
          "ogni scrittura vuole expected_revision")
    let empty = await m.call("circuit_info", arguments: [:])
    check(empty.isError && empty.text.contains("Nessun circuito"), "senza circuito: detto")

    // From an empty circuit: library, add, pins, connect, no-connect — the same commands as CREA.
    try m.newCircuit(name: "Da chat")
    func tok() -> String { m.designRevision }
    func step(_ args: [String: JSONValue]) async -> ToolResult {
        var a = args; a["expected_revision"] = .string(tok())
        let p = await m.call("circuit_preview", arguments: .object(a))
        guard let id = p.structured?["preview_id"]?.string else { return p }
        return await m.call("circuit_apply", arguments: ["preview_id": .string(id), "expected_revision": .string(tok())])
    }
    let lib = await m.call("circuit_library", arguments: [:])
    let devices = lib.structured?["devices"]?.array ?? []
    let resistor = devices.first { $0["reference_prefix"]?.string == "R" }?["device"]?.string ?? ""
    check(!lib.isError && !resistor.isEmpty && (devices.first?["pins"]?.array?.count ?? 0) == 2, "circuit_library: modelli con i pin")
    let addR = await step(["action": "add_component", "device": .string(resistor), "x": 10, "y": 10])
    let addR2 = await step(["action": "add_component", "device": .string(resistor), "value": "4k7", "x": 20, "y": 10])
    check(!addR.isError && !addR2.isError && m.design?.components.map(\.reference) == ["R1", "R2"] && m.design?.components[1].value == "4k7",
          "add_component: R1 e R2 posati (\(addR2.text))")
    let pins = await m.call("circuit_pins", arguments: ["component": "R1"])
    check(pins.structured?["pins"]?.array?.compactMap { $0["pin"]?.string } == ["R1.1", "R1.2"], "circuit_pins: R1.1 e R1.2")
    let wire = await step(["action": "connect", "pins": ["R1.2", "R2.1"]])
    check(!wire.isError && m.design?.nets.map(\.name) == ["N1"] && m.design?.connections.count == 2, "connect: rete N1 nuova (\(wire.text))")
    // Fields of another action: refused with the right ones (the small model corrects itself).
    let wrongFields = await m.call("circuit_preview", arguments: ["action": "rename_net", "component": "N1", "reference": "N1", "side": "top", "expected_revision": .string(tok())])
    check(wrongFields.isError && wrongFields.text.contains("rename_net usa solo: net, name"), "campi di un'altra azione: rifiutati con quelli giusti (\(wrongFields.text))")
    let noName = await m.call("circuit_preview", arguments: ["action": "rename_net", "net": "N1", "expected_revision": .string(tok())])
    check(noName.isError && noName.text.contains("name (nome nuovo)"), "rename_net senza name: esempio nell'errore")
    let named = await step(["action": "connect", "pins": ["R1.1"], "net": "VCC"])
    check(!named.isError && m.design?.nets.contains { $0.name == "VCC" } == true, "connect a una rete col nome")
    let nc = await step(["action": "no_connect", "pins": ["R2.2"]])
    let r2pins = await m.call("circuit_pins", arguments: ["component": "R2"])
    check(!nc.isError && r2pins.structured?["pins"]?.array?.last?["no_connect"]?.bool == true, "no_connect: pin segnato")
    let badPin = await step(["action": "connect", "pins": ["R1.9", "R2.1"]])
    check(badPin.isError && badPin.text.contains("R1.9"), "pin sconosciuto: detto")
    let busy = await step(["action": "connect", "pins": ["R1.1", "R2.1"]])
    check(busy.isError, "pin su reti diverse: rifiutato senza net")

    // Wrong types are errors, never defaults.
    let design0 = m.document
    let wrongLayer = await m.call("circuit_preview", arguments: ["action": "add_track", "net": "N1", "points": [["x": 1, "y": 1], ["x": 2, "y": 2]], "layer": 123, "expected_revision": .string(tok())])
    let wrongBool = await m.call("circuit_fabrication_check", arguments: ["tent_vias": "false"])
    let wrongPoint = await m.call("circuit_preview", arguments: ["action": "add_track", "net": "N1", "points": [["x": 1], ["x": 2, "y": 2]], "expected_revision": .string(tok())])
    let wrongNumber = await m.call("circuit_preview", arguments: ["action": "move_component", "component": "R1", "x": "5", "y": 5, "expected_revision": .string(tok())])
    check(wrongLayer.isError && wrongLayer.text.contains("layer") && wrongBool.isError && wrongBool.text.contains("tent_vias")
          && wrongPoint.isError && wrongNumber.isError && m.document == design0, "tipi sbagliati: errori, nulla cambia")

    try await m.open(fixture)
    await m.pcbReady()
    func token() -> String { m.designRevision }
    let info = await m.call("circuit_info", arguments: [:])
    check(!info.isError && info.structured?["revision"]?.string == token() && info.structured?["components"]?.array?.count == m.design?.components.count,
          "circuit_info: componenti e token (\(info.text))")
    let issues = await m.call("circuit_issues", arguments: [:])
    check(!issues.isError && issues.structured?["issues"]?.array?.count == m.issues.count, "circuit_issues")
    let fab = await m.call("circuit_fabrication_check", arguments: [:])
    check(!fab.isError && fab.structured?["can_export"]?.bool == true && fab.structured?["layers"]?.array?.count == 9, "verifica di produzione (\(fab.text))")

    // Malformed calls change nothing.
    let original = m.document
    let reference = m.design!.components[0].reference
    for (args, what) in [
        (["action": "move_component", "component": .string(reference), "x": 10, "y": 10] as JSONValue, "senza expected_revision"),
        (["action": "teleport", "expected_revision": .string(token())], "azione sconosciuta"),
        (["action": "move_component", "component": "ZZ9", "x": 1, "y": 1, "expected_revision": .string(token())], "componente sconosciuto"),
        (["action": "move_component", "component": .string(reference), "expected_revision": .string(token())], "senza coordinate"),
        (["action": "move_component", "component": .string(reference), "x": 1, "y": 1, "colour": "red", "expected_revision": .string(token())], "parametro sconosciuto"),
        (["action": "move_component", "component": .string(reference), "x": 1, "y": 1, "expected_revision": "vecchio"], "token vecchio"),
    ] {
        let r = await m.call("circuit_preview", arguments: args)
        check(r.isError && m.document == original, "anteprima rifiutata: \(what) (\(r.text))")
    }

    // Preview: nothing changes; apply the same ID: exactly one step.
    let placement = m.design!.board.placements.first { $0.componentID == m.design!.components[0].id }!
    let target = PCBPoint(placement.position.x + 0.5, placement.position.y)
    let preview = await m.call("circuit_preview", arguments: ["action": "move_component", "component": .string(reference),
                                                               "x": .number(target.x), "y": .number(target.y), "expected_revision": .string(token())])
    let id = preview.structured?["preview_id"]?.string ?? ""
    check(!preview.isError && !id.isEmpty && m.document == original, "anteprima: nulla cambia (\(preview.text))")
    let applied = await m.call("circuit_apply", arguments: ["preview_id": .string(id), "expected_revision": .string(token())])
    let moved = m.design!.board.placements.first { $0.componentID == m.design!.components[0].id }!
    check(!applied.isError && m.document!.revision == original!.revision + 1 && m.document!.past.count == original!.past.count + 1
          && moved.position == target && applied.structured?["can_undo"]?.bool == true,
          "conferma: il comando dell'anteprima, un passo (\(applied.text))")
    check(m.selection == m.design!.components[0].id, "conferma: componente selezionato nell'app")
    let again = await m.call("circuit_apply", arguments: ["preview_id": .string(id), "expected_revision": .string(token())])
    check(again.isError && moved == m.design!.board.placements.first { $0.componentID == m.design!.components[0].id }, "stessa anteprima due volte: rifiutata")

    // Undo / redo of the assistant's step: data back, revision forward.
    let afterMove = m.design
    let undone = await m.call("circuit_undo", arguments: ["expected_revision": .string(token())])
    check(!undone.isError && m.design == original!.design && m.document!.revision == original!.revision + 2, "annulla: dati di prima, revisione avanti")
    let redone = await m.call("circuit_redo", arguments: ["expected_revision": .string(token())])
    check(!redone.isError && m.design == afterMove && m.document!.revision == original!.revision + 3, "ripeti")

    /// Preview + apply in one go (the tests' shorthand).
    func change(_ args: [String: JSONValue]) async -> ToolResult {
        var a = args; a["expected_revision"] = .string(token())
        let p = await m.call("circuit_preview", arguments: .object(a))
        guard let id = p.structured?["preview_id"]?.string else { return p }
        return await m.call("circuit_apply", arguments: ["preview_id": .string(id), "expected_revision": .string(token())])
    }
    func undo() async -> ToolResult { await m.call("circuit_undo", arguments: ["expected_revision": .string(token())]) }
    func redo() async -> ToolResult { await m.call("circuit_redo", arguments: ["expected_revision": .string(token())]) }

    // Two assistant steps: two undos and two redos, in order.
    let s0 = m.design
    _ = await change(["action": "rotate_component", "component": .string(reference), "degrees": 90])
    let s1 = m.design
    _ = await change(["action": "rotate_component", "component": .string(reference), "degrees": 90])
    let s2 = m.design
    let u1 = await undo(), u2 = await undo()
    check(!u1.isError && !u2.isError && m.design == s0, "due passi dell'assistente, due annulla (\(u2.text))")
    let u3 = await undo()
    check(!u3.isError && m.design == original!.design, "terzo annulla: lo spostamento di prima, anch'esso dell'assistente")
    let u4 = await undo()
    check(u4.isError && m.design == original!.design && u4.structured?["can_undo"]?.bool == false, "quarto annulla: niente dell'assistente prima")
    let r0 = await redo()
    check(!r0.isError && m.design == s0, "ripeti lo spostamento")
    let r1 = await redo()
    check(!r1.isError && m.design == s1, "ripeti il primo")
    let r2 = await redo()
    let r3 = await redo()
    check(!r2.isError && m.design == s2 && r3.isError, "ripeti il secondo, poi niente")

    // Assistant, user, assistant: undo stops at the user's step.
    _ = await change(["action": "rotate_component", "component": .string(reference), "degrees": 90])
    m.setBoard(width: 55, height: 35, thickness: 1.6)
    let userStep = m.design
    _ = await change(["action": "rotate_component", "component": .string(reference), "degrees": 90])
    let ub = await undo()
    check(!ub.isError && m.design == userStep, "annulla il passo B dell'assistente")
    let uu = await undo()
    check(uu.isError && m.design == userStep && uu.structured?["can_undo"]?.bool == false, "si ferma sul passo dell'utente (\(uu.text))")

    // The assistant's step undone, then the user does exactly the same change by hand: that step
    // is the user's (same title, before and after — but a new branch).
    _ = await change(["action": "rotate_component", "component": .string(reference), "degrees": 90])
    let beforeSame = m.design
    _ = await undo()
    check(m.design == userStep && m.assistantCanRedo, "passo dell'assistente annullato, ripetibile")
    m.rotate(m.design!.components[0].id, by: 90)
    check(m.design == beforeSame && !m.assistantCanUndo && !m.assistantCanRedo, "stesso comando rifatto a mano: non è dell'assistente")
    let sameByHand = await undo()
    check(sameByHand.isError && m.design == beforeSame, "annulla dell'assistente non tocca il passo identico dell'utente")
    m.undo()
    let userStep2 = m.design
    check(userStep2 == userStep, "l'utente annulla il suo passo")

    // A change that changes nothing: no step, not the assistant's to undo (the user's stays).
    let here = m.design!.board.placements.first { $0.componentID == m.design!.components[0].id }!.position
    let revisionBefore = m.document!.revision
    let noop = await change(["action": "move_component", "component": .string(reference), "x": .number(here.x), "y": .number(here.y)])
    check(!noop.isError && noop.structured?["changed"]?.bool == false && m.document!.revision == revisionBefore
          && noop.structured?["can_undo"]?.bool == false, "spostamento sul posto: nessun passo (\(noop.text))")
    let afterNoop = await undo()
    check(afterNoop.isError && m.design == userStep, "dopo un no-op, annulla non tocca il passo dell'utente")

    // A change of the user after the preview: the confirmation is refused; the user's step is not undone.
    let p2 = await m.call("circuit_preview", arguments: ["action": "rotate_component", "component": .string(reference), "degrees": 90, "expected_revision": .string(token())])
    let stale = token()
    m.setBoard(width: 60, height: 40, thickness: 1.6)
    let byUser = m.document
    let late = await m.call("circuit_apply", arguments: ["preview_id": p2.structured?["preview_id"] ?? "", "expected_revision": .string(stale)])
    check(late.isError && m.document == byUser, "modifica dell'utente dopo l'anteprima: conferma rifiutata")
    let late2 = await m.call("circuit_apply", arguments: ["preview_id": p2.structured?["preview_id"] ?? "", "expected_revision": .string(token())])
    check(late2.isError && m.document == byUser, "anche col token nuovo: anteprima di un altro stato")
    let notMine = await m.call("circuit_undo", arguments: ["expected_revision": .string(token())])
    check(notMine.isError && m.document == byUser, "annulla dell'assistente non tocca il passo dell'utente")

    // Another open of a file with the same identity and revision: tokens and previews are void.
    let saved = FileManager.default.temporaryDirectory.appendingPathComponent("strumenti-\(UUID().uuidString).ftkc")
    try m.save(to: saved)
    let p3 = await m.call("circuit_preview", arguments: ["action": "rotate_component", "component": .string(reference), "degrees": 90, "expected_revision": .string(token())])
    let beforeOpen = token()
    try await m.open(saved)
    check(m.design?.id == byUser?.design.id && m.document?.revision == byUser?.revision && token() != beforeOpen, "stesso file riaperto: token nuovo")
    let reopened = m.document
    let afterOpen = await m.call("circuit_apply", arguments: ["preview_id": p3.structured?["preview_id"] ?? "", "expected_revision": .string(beforeOpen)])
    let afterOpen2 = await m.call("circuit_apply", arguments: ["preview_id": p3.structured?["preview_id"] ?? "", "expected_revision": .string(token())])
    check(afterOpen.isError && afterOpen2.isError && m.document == reopened, "altra apertura: anteprima e token vecchi rifiutati")
    try? FileManager.default.removeItem(at: saved)

    // Copper blocked by the DRC: a track from a pad of one net to a pad of another (a short).
    await m.pcbReady()
    let pads = m.board!.pads.filter { $0.netID != nil }
    let from = pads[0], to = pads.first { $0.netID != from.netID }!
    let net = m.design!.nets.first { $0.id == from.netID }!.name
    let side = from.copperSides.contains(.top) && to.copperSides.contains(.top) ? "top" : "bottom"
    let short: JSONValue = .array([["x": .number(from.center.x), "y": .number(from.center.y)], ["x": .number(to.center.x), "y": .number(to.center.y)]])
    let bad = await m.call("circuit_preview", arguments: ["action": "add_track", "net": .string(net), "points": short, "layer": .string(side), "expected_revision": .string(token())])
    check(!bad.isError && bad.structured?["can_apply"]?.bool == false && !(bad.structured?["blocking_issues"]?.array ?? []).isEmpty,
          "pista in corto con un'altra rete: anteprima bloccata dal motore (\(bad.text))")
    let outline = m.design!.board.outline
    let xs = outline.map(\.x), ys = outline.map(\.y)
    let blocked = await m.call("circuit_apply", arguments: ["preview_id": bad.structured?["preview_id"] ?? "", "expected_revision": .string(token())])
    check(blocked.isError && m.document == reopened, "conferma di un'anteprima bloccata: nulla cambia")

    // A copper change that passes goes through the copper worker, one step.
    let via = await m.call("circuit_preview", arguments: ["action": "add_via", "net": .string(net), "x": .number(xs.max()! - 1), "y": .number(ys.max()! - 1), "expected_revision": .string(token())])
    if via.structured?["can_apply"]?.bool == true {
        let done = await m.call("circuit_apply", arguments: ["preview_id": via.structured?["preview_id"] ?? "", "expected_revision": .string(token())])
        check(!done.isError && m.document!.revision == reopened!.revision + 1 && m.design!.board.copper!.vias.count == reopened!.design.board.copper!.vias.count + 1,
              "via confermata: un passo (\(done.text))")
    } else {
        check(false, "via nell'angolo bloccata? \(via.structured?["blocking_issues"]?.jsonString ?? via.text)")
    }
}
