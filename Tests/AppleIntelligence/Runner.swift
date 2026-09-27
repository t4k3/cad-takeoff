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
        let previewTool = try CADTool(spec: preview, compact: true) { _, _ in .error("prova") }
        check(["add_component", "connect", "no_connect", "move_component", "add_track"].allSatisfy { previewTool.description.contains($0) },
              "circuit_preview: la descrizione compatta elenca le azioni")
        let circuitSmall = AppleIntelligenceProvider.select(all, contextSize: 4096, focus: .circuits)
        check(circuitSmall.map(\.name) == ["circuit_info", "circuit_library", "circuit_pins", "circuit_preview", "circuit_apply", "circuit_undo", "circuit_redo", "circuit_fabrication_check"],
              "contesto piccolo in CIRCUITI: il ciclo anteprima → conferma")
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

        if ProcessInfo.processInfo.environment["FTK_LIVE_FM"] == "1" {
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
        }
        if failures > 0 { fatalError("\(failures) verifiche fallite") }
        print("OK: assistente sul Mac — \(converted) strumenti per Foundation Models")
    }
}
