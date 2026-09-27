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
