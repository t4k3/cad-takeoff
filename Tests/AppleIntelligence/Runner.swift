import CADCore
import Foundation
import FoundationModels

/// The on-device assistant's side of the tools: every CAD tool's schema becomes a valid
/// Foundation Models schema (without expected_revision), the small context gets the everyday
/// tools. With FTK_LIVE_FM=1 and Apple Intelligence on, a real request must build a box.
@main
struct AppleIntelligenceTests {
    @MainActor static func main() async throws {
        setvbuf(stdout, nil, _IOLBF, 0)
        var failures = 0
        func check(_ ok: Bool, _ what: String) { if !ok { failures += 1; print("FALLITO: \(what)") } }
        let specs = CADToolCatalog.tools
        var converted = 0
        for spec in specs {
            do {
                let tool = try CADTool(spec: spec) { _, _ in .error("prova") }
                converted += 1
                check(tool.description.count <= 200, "\(spec.name): descrizione breve")
                check(!CADToolSchema.withoutRevision(spec.inputSchema).jsonString.contains("expected_revision"), "\(spec.name): senza expected_revision")
            } catch {
                check(false, "\(spec.name): schema non convertibile (\(error))")
            }
        }
        check(converted == specs.count, "tutti gli strumenti convertiti (\(converted)/\(specs.count))")
        let small = AppleIntelligenceProvider.select(specs, contextSize: 4096)
        check(small.count == 6 && small.contains { $0.name == "add_box" }, "contesto piccolo: gli strumenti di tutti i giorni")
        check(AppleIntelligenceProvider.select(specs, contextSize: 32_000).count == specs.count, "contesto grande: tutti")

        // CIRCUITI (T100): the circuit tools convert, keep every operational field in the small
        // context, and the small context in CIRCUITI gets the whole preview → apply cycle.
        let router = ToolRouter(cad: DesignModel(), circuits: CircuitModel())
        let all = router.tools
        for spec in all where spec.name.hasPrefix("circuit_") {
            do {
                let tool = try CADTool(spec: spec, compact: true) { _, _ in .error("prova") }
                check(tool.description.count <= 900, "\(spec.name): descrizione contenuta")
            } catch { check(false, "\(spec.name): schema non convertibile (\(error))") }
        }
        let preview = all.first { $0.name == "circuit_preview" }!
        let kept = CADToolSchema.essentials(CADToolSchema.withoutRevision(preview.inputSchema),
                                            keeping: Set(preview.inputSchema["properties"].flatMap { if case let .object(o) = $0 { Array(o.keys) } else { nil } } ?? []))
        for field in ["action", "component", "x", "y", "device", "pins", "net", "points", "layer", "degrees"] {
            check(kept["properties"]?[field] != nil, "circuit_preview compatto conserva \(field)")
        }
        check(kept["properties"]?["expected_revision"] == nil, "circuit_preview senza expected_revision (lo mette la sessione)")
        var previewFields: [String: JSONValue] = [:]
        if case let .object(o)? = preview.inputSchema["properties"] { previewFields = o }
        for (field, schema) in previewFields where field != "expected_revision" {
            if let d = schema["description"]?.string { check(d.count <= 60, "circuit_preview.\(field): descrizione intera nel contesto piccolo (\(d.count))") }
        }
        check(kept["properties"]?["name"]?["description"]?.string?.contains("rename_net") == true
              && kept["properties"]?["net"]?["description"]?.string?.contains("rename_net") == true, "net e name dicono che servono a rename_net")
        let previewTool = try CADTool(spec: preview, compact: true) { _, _ in .error("prova") }
        check(["add_component", "connect", "no_connect", "move_component", "add_track"].allSatisfy { previewTool.description.contains($0) },
              "circuit_preview: la descrizione compatta elenca le azioni")
        let circuitSmall = AppleIntelligenceProvider.select(all, contextSize: 4096, focus: .circuits)
        check(circuitSmall.map(\.name) == ["circuit_info", "circuit_library", "circuit_pins",
                                            "circuit_rename_net", "circuit_add_component", "circuit_connect", "circuit_disconnect", "circuit_no_connect",
                                            "circuit_move_component", "circuit_rotate_component", "circuit_remove_component",
                                            "circuit_apply", "circuit_undo", "circuit_redo", "circuit_fabrication_check"],
              "contesto piccolo in CIRCUITI: letture, uno strumento per azione, conferma, storico e produzione (\(circuitSmall.map(\.name)))")
        for spec in circuitSmall {
            do { _ = try CADTool(spec: spec, compact: true) { _, _ in .error("prova") } }
            catch { check(false, "\(spec.name): schema non convertibile (\(error))") }
        }
        let rename = circuitSmall.first { $0.name == "circuit_rename_net" }!
        check(rename.inputSchema["properties"]?["new_name"] != nil && rename.inputSchema["properties"]?["reference"] == nil
              && rename.inputSchema["required"]?.array?.compactMap(\.string).sorted() == ["expected_revision", "net", "new_name"], "circuit_rename_net: solo net e new_name")
        let mapped = AppleIntelligenceProvider.catalogueCall("circuit_rename_net", ["net": "SUPPLY", "new_name": "QA_CHAT", "expected_revision": "t"])
        check(mapped?.0 == "circuit_preview" && mapped?.1 == ["action": "rename_net", "net": "SUPPLY", "name": "QA_CHAT", "expected_revision": "t"],
              "circuit_rename_net diventa circuit_preview rename_net del catalogo")
        check(AppleIntelligenceProvider.catalogueCall("circuit_apply", [:]) == nil, "gli altri strumenti restano quelli del catalogo")
        // What the small window pays for the circuit tools (schemas + descriptions), roughly 4 chars a token.
        let circuitChars = circuitSmall.reduce(0) { total, spec in
            let schema = CADToolSchema.essentials(CADToolSchema.withoutRevision(spec.inputSchema),
                                                  keeping: Set(spec.inputSchema["properties"].flatMap { if case let .object(o) = $0 { Array(o.keys) } else { nil } } ?? []))
            return total + schema.jsonString.count + min(900, spec.title.count + 2 + spec.description.count)
        }
        print("Strumenti circuito nel contesto piccolo: \(circuitChars) caratteri (~\(circuitChars / 4) token)")
        check(circuitChars / 4 < 3000, "strumenti circuito entro ~3000 token del contesto piccolo")
        check(AppleIntelligenceProvider.select(all, contextSize: 4096).allSatisfy { !$0.name.hasPrefix("circuit_") }, "contesto piccolo nel CAD: strumenti CAD")
        let noisy = ToolResult(text: "Anteprima «Traccia pista»", structured: .object([
            "new_issues": .array((0..<40).map { .object(["message": .string("Distanza insufficiente numero \($0) tra rame e rame di un'altra rete")]) }),
            "preview_id": "abc-123", "revision": "tok@7#x-1", "can_apply": false, "changed": false,
        ]))
        let compactText = CADTool.compactCircuitResult(noisy)
        check(compactText.contains("abc-123") && compactText.contains("tok@7#x-1") && compactText.contains("\"can_apply\":false")
              && compactText.count <= 1500 && compactText.contains("altri 35"), "risultato compatto: preview_id, revisione e can_apply sempre, liste accorciate")

        // A reply that claims a change no tool made is flagged (Ross, 28/09: «ho creato il coperchio»).
        check(AssistantSession.claimsAChange("ho creato il coperchio, ma non appare") && !AssistantSession.claimsAChange("il volume è 12 cm³"),
              "frasi che dicono di aver cambiato il disegno riconosciute")

        if ProcessInfo.processInfo.environment["FTK_LIVE_FM"] == "1" {
            // An imported tray (no dimensions of its own): «a lid for this box» must build a body over it.
            let tray = DesignModel()
            tray.newDesign()
            let shell = try PrimitiveKernel.build(Feature(name: "t", kind: .box(width: 60, depth: 40, height: 20), position: Vec3(0, 0, 0))).mesh
            tray.document.features = [Feature(name: "Scatola", kind: .importedMesh(ImportedMesh(mesh: shell, source: "scatola.stl")))]
            let lidChat = AssistantSession(providers: [AppleIntelligenceProvider()])
            lidChat.tools = tray
            if lidChat.provider.isConfigured {
                lidChat.send("crea un coperchio per questa scatola")
                while lidChat.isRunning { try await Task.sleep(for: .milliseconds(200)) }
                for e in lidChat.entries { print("· coperchio", e.kind) }
                let lid = tray.document.features.dropFirst().first
                let flagged = lidChat.entries.contains { if case let .notice(t, _) = $0.kind { t.contains("nessuno strumento") } else { false } }
                check(lid != nil || flagged, "dal vivo: coperchio creato, o risposta falsa segnalata")
                if let lid, let b = DesignEvaluator.evaluate(tray.document, revision: "l").bodies.first(where: { $0.id == lid.id })?.mesh.bounds {
                    print("· coperchio ingombro", b.min, b.max)
                }
            }
            let model = DesignModel()
            model.newDesign()
            let session = AssistantSession(providers: [AppleIntelligenceProvider()])
            session.tools = model
            print("Disponibilità:", SystemLanguageModel.default.availability, "contesto:", SystemLanguageModel.default.contextSize)
            if session.provider.isConfigured {
                session.send("Crea un cubo di 20 mm di lato.")
                while session.isRunning { try await Task.sleep(for: .milliseconds(200)) }
                for e in session.entries { print("·", e.kind) }
                check(model.document.features.contains { if case let .box(w, d, h) = $0.kind { w == 20 && d == 20 && h == 20 } else { false } },
                      "dal vivo: il modello sul Mac ha creato il cubo")
            } else {
                print("Apple Intelligence non disponibile qui:", session.provider.setupHint)
            }
            // CIRCUITI: Codex's natural request (QA 27/09) on a circuit with a SUPPLY net.
            let circuits = CircuitModel()
            try circuits.newCircuit(name: "Chat")
            let liveRouter = ToolRouter(cad: model, circuits: circuits)
            func step(_ args: [String: JSONValue]) async {
                var a = args; a["expected_revision"] = .string(circuits.designRevision)
                let p = await circuits.call("circuit_preview", arguments: .object(a))
                if let id = p.structured?["preview_id"] { _ = await circuits.call("circuit_apply", arguments: ["preview_id": id, "expected_revision": .string(circuits.designRevision)]) }
            }
            await step(["action": "add_component", "device": "resistor-0603", "x": 10, "y": 10])
            await step(["action": "add_component", "device": "resistor-0603", "x": 20, "y": 10])
            await step(["action": "connect", "pins": ["R1.2", "R2.1"], "net": "SUPPLY"])
            let chat = AssistantSession(providers: [AppleIntelligenceProvider()])
            chat.tools = liveRouter
            chat.focus = .circuits
            if chat.provider.isConfigured, circuits.design?.nets.map(\.name) == ["SUPPLY"] {
                let before = circuits.design
                chat.send("Rinomina la rete SUPPLY in QA_CHAT. Esegui anteprima e applicazione, senza altre modifiche.")
                while chat.isRunning { try await Task.sleep(for: .milliseconds(200)) }
                for e in chat.entries { print("·", e.kind) }
                var expected = before!
                expected.nets[0].name = "QA_CHAT"
                check(circuits.design == expected, "dal vivo: rete rinominata in QA_CHAT e nient'altro")
                let undone = await liveRouter.call("circuit_undo", arguments: ["expected_revision": .string(circuits.designRevision)])
                check(!undone.isError && circuits.design == before, "dal vivo: annulla dell'assistente riporta SUPPLY")
                chat.send("Collega R1.1 e R2.2 alla rete GND.")
                while chat.isRunning { try await Task.sleep(for: .milliseconds(200)) }
                for e in chat.entries.suffix(4) { print("·", e.kind) }
                let gnd = circuits.design?.nets.first { $0.name == "GND" }
                let onGND = circuits.design?.connections.filter { $0.netID == gnd?.id }.count ?? 0
                check(gnd != nil && onGND == 2 && circuits.design?.nets.count == 2, "dal vivo: R1.1 e R2.2 collegati a GND")
            }
        }
        if failures > 0 { fatalError("\(failures) verifiche fallite") }
        print("OK: assistente sul Mac — \(converted) strumenti per Foundation Models")
    }
}
