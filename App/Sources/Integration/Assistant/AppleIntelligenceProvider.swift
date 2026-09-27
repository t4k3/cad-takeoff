import Foundation
import FoundationModels
import Observation

/// The assistant on the Mac: Apple's on-device model (Foundation Models, macOS 26) with the same
/// CAD tools as Claude and ChatGPT. No API key, no network, nothing leaves the Mac.
///
/// The model calls the tools itself while it answers (Foundation Models' `Tool`); each call runs
/// through the session's executor, so it shows in the conversation and is undoable like any
/// other. Its context is small (8192 tokens on macOS 27): it gets short instructions and, when
/// the window is that small, the everyday tools with one-line descriptions.
@MainActor
@Observable
final class AppleIntelligenceProvider: AssistantProvider {
    let displayName = "Apple Intelligence"
    let modelName = "sul Mac, senza rete"

    /// Runs a CAD tool for the model (set by the session: shows the call and returns its result).
    @ObservationIgnored var executor: (@MainActor (String, JSONValue) async -> ToolResult)?
    @ObservationIgnored private var session: LanguageModelSession?
    /// The tools (and workspace) the session was made with: another catalogue needs a new session.
    @ObservationIgnored private var sessionKey: [String] = []
    /// Where the user is (set by the session before each turn): CAD or CIRCUITI.
    @ObservationIgnored var focus: AssistantFocus = .cad
    @ObservationIgnored private var pending = ""

    var isConfigured: Bool { SystemLanguageModel.default.isAvailable }

    var setupHint: String {
        switch SystemLanguageModel.default.availability {
        case .available: ""
        case .unavailable(.deviceNotEligible): "Questo Mac non supporta Apple Intelligence: usa Claude o ChatGPT con la tua chiave."
        case .unavailable(.appleIntelligenceNotEnabled): "Attiva Apple Intelligence in Impostazioni di Sistema › Apple Intelligence e Siri."
        case .unavailable(.modelNotReady): "Il modello Apple si sta ancora scaricando: riprova tra qualche minuto."
        case .unavailable: "Apple Intelligence non è disponibile su questo Mac ora."
        }
    }

    func reset() { session = nil; sessionKey = []; pending = "" }

    func addUserMessage(_ text: String) { pending = text }

    /// Tool results reach the model inside its own turn: nothing to add afterwards.
    func addToolResults(_ results: [(ToolCallRequest, ToolResult)]) {}

    static let instructions = """
    Sei l'assistente di CAD Takeoff, un CAD per stampa 3D su Mac. Rispondi in italiano, breve.
    Millimetri, Z in alto, Z = 0 è il piatto. Per creare o modificare chiama lo strumento (non scrivere \
    i suoi argomenti nel testo e non ripetere la richiesta).
    Non chiedere dati che non servono: senza posizione indicata metti il pezzo all'origine (ometti la \
    posizione); se manca una misura secondaria scegli un valore ragionevole, dichiaralo e procedi.
    Per modificare un pezzo esistente leggi prima lo stato (list_features). Dopo una modifica di' in una \
    frase cosa hai fatto e le misure. Se nessuno strumento fa ciò che serve, dillo.
    """

    static let circuitInstructions = """
    Sei l'assistente dei circuiti di CAD Takeoff su Mac. Rispondi in italiano, breve. Millimetri, scheda \
    vista dall'alto. Leggi prima con circuit_info (e circuit_library o circuit_pins se servono). Ogni \
    modifica: circuit_preview, poi circuit_apply con il preview_id ricevuto; se can_apply è false spiega \
    il motivo e non insistere. Pin come «R1.2». Dopo una modifica di' in una frase cosa hai fatto.
    """

    func runTurn(system: String, tools: [ToolSpec], onEvent: @escaping (AssistantEvent) -> Void) async throws -> AssistantStop {
        guard isConfigured else { throw AssistantError(message: setupHint) }
        let model = SystemLanguageModel.default
        let chosen = Self.select(tools, contextSize: model.contextSize, focus: focus)
        let key = [focus == .circuits ? "circuiti" : "cad"] + chosen.map(\.name)
        // Another workspace or catalogue: a new session with its own tools and instructions.
        if session == nil || key != sessionKey {
            sessionKey = key
            let runner: @Sendable (String, JSONValue) async -> ToolResult = { [weak self] name, args in
                await self?.run(name, args) ?? .error("Assistente chiuso.")
            }
            let compact = model.contextSize < 16_000
            let fmTools: [any Tool] = chosen.compactMap { try? CADTool(spec: $0, compact: compact, run: runner) }
            session = LanguageModelSession(model: model, tools: fmTools, instructions: focus == .circuits ? Self.circuitInstructions : Self.instructions)
        }
        guard let session else { return .done }
        let prompt = pending
        pending = ""
        var shown = ""
        do {
            // Greedy: the same request does the same thing (a CAD action is not a place for variety).
            for try await snapshot in session.streamResponse(to: prompt, options: GenerationOptions(samplingMode: .greedy)) {
                try Task.checkCancellation()
                let text = snapshot.content
                if text.hasPrefix(shown) {
                    let delta = String(text.dropFirst(shown.count))
                    if !delta.isEmpty { onEvent(.textDelta(delta)) }
                } else {
                    onEvent(.textDelta("\n" + text))
                }
                shown = text
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            switch Self.kind(of: error) {
            case .contextFull:
                self.session = nil; sessionKey = []
                throw AssistantError(message: "La conversazione è troppo lunga per il modello sul Mac: comincia una nuova conversazione.")
            case .refused:
                return .refused(nil)
            case .other:
                throw AssistantError(message: "Apple Intelligence: \(error.localizedDescription)", retryable: true)
            }
        }
        return .done
    }

    enum FailureKind { case contextFull, refused, other }

    /// The model's errors (macOS 27: `LanguageModelError`).
    static func kind(of error: Error) -> FailureKind {
        guard let e = error as? LanguageModelError else { return .other }
        switch e {
        case .contextSizeExceeded: return .contextFull
        case .guardrailViolation, .refusal: return .refused
        default: return .other
        }
    }

    private func run(_ name: String, _ arguments: JSONValue) async -> ToolResult {
        guard let executor else { return .error("Strumenti CAD non collegati.") }
        return await executor(name, arguments)
    }

    /// The tools that fit: all of them in a large window, else the everyday ones of the workspace
    /// the user is in (the circuit's whole preview → apply cycle in CIRCUITI).
    static func select(_ tools: [ToolSpec], contextSize: Int, focus: AssistantFocus = .cad) -> [ToolSpec] {
        guard contextSize < 16_000 else { return tools }
        let everyday = focus == .circuits
            ? ["circuit_info", "circuit_library", "circuit_pins", "circuit_preview", "circuit_apply", "circuit_undo", "circuit_redo", "circuit_fabrication_check"]
            : ["list_features", "add_box", "add_cylinder", "update_feature", "delete_feature", "undo"]
        return everyday.compactMap { name in tools.first { $0.name == name } }
    }
}

/// A CAD tool as Foundation Models sees it: its JSON schema turned into a generation schema, a
/// one-line description, arguments handed back as JSON to the same CAD tool code.
struct CADTool: Tool {
    typealias Arguments = GeneratedContent
    typealias Output = String

    let name: String
    let description: String
    let parameters: GenerationSchema
    let run: @Sendable (String, JSONValue) async -> ToolResult

    /// `compact`: for a small context — the title and first sentence as description, and only the
    /// required arguments plus name and position (defaults do the rest).
    init(spec: ToolSpec, compact: Bool = false, run: @escaping @Sendable (String, JSONValue) async -> ToolResult) throws {
        name = spec.name
        var schema = CADToolSchema.withoutRevision(spec.inputSchema)
        if spec.name.hasPrefix("circuit_") {
            // A circuit change is chosen by its action and fields: keep every field (short
            // descriptions) and the list of actions, which is the description's first part.
            description = String((spec.title + ": " + spec.description).prefix(900))
            if compact, case let .object(p)? = schema["properties"] { schema = CADToolSchema.essentials(schema, keeping: Set(p.keys)) }
        } else {
            let first = spec.description.split(separator: ".", maxSplits: 1).first.map(String.init) ?? spec.description
            description = String((spec.title + ": " + first).prefix(200))
            if compact { schema = CADToolSchema.essentials(schema, keeping: ["name", "position"]) }
        }
        parameters = try GenerationSchema(root: CADToolSchema.dynamic(schema, name: spec.name), dependencies: [])
        self.run = run
    }

    func call(arguments: GeneratedContent) async throws -> String {
        let json = (try? JSONValue.parse(Data(arguments.jsonString.utf8))) ?? .object([:])
        let result = await run(name, json)
        if name.hasPrefix("circuit_") { return Self.compactCircuitResult(result) }
        var text = result.text
        if let s = result.structured { text += "\n" + s.jsonString }
        // Short: every word of a result takes room in the small context.
        return String((result.isError ? "Errore: " + text : text).prefix(1200))
    }

    /// A circuit result in little room: what the next call needs (revision, preview_id,
    /// can_apply…) always whole and first; the diagnostic lists shortened, the rest cut to fit.
    static func compactCircuitResult(_ result: ToolResult, limit: Int = 1500) -> String {
        let operational = ["error", "revision", "preview_id", "can_apply", "changed", "title", "can_undo", "can_redo", "copper_check", "can_export"]
        var head = (result.isError ? "Errore: " : "") + result.text
        guard case let .object(fields)? = result.structured else { return String(head.prefix(limit)) }
        var essential: [String: JSONValue] = [:]
        for key in operational { if let v = fields[key] { essential[key] = v } }
        head += "\n" + JSONValue.object(essential).jsonString
        var rest: [String: JSONValue] = [:]
        for (key, value) in fields where essential[key] == nil {
            if case let .array(items) = value, items.count > 5 {
                rest[key] = .array(Array(items.prefix(5)) + [.string("… altri \(items.count - 5)")])
            } else { rest[key] = value }
        }
        guard !rest.isEmpty else { return head }
        let room = max(0, limit - head.count - 1)
        return head + "\n" + String(JSONValue.object(rest).jsonString.prefix(room))
    }
}

/// JSON Schema (the subset the CAD tools use) → Foundation Models dynamic schema.
enum CADToolSchema {
    /// Only the required properties and `keeping` (without their long descriptions).
    static func essentials(_ schema: JSONValue, keeping: Set<String>) -> JSONValue {
        guard case var .object(o) = schema, case let .object(p)? = o["properties"] else { return schema }
        let required = Set(o["required"]?.array?.compactMap(\.string) ?? [])
        var kept: [String: JSONValue] = [:]
        for (k, v) in p where required.contains(k) || keeping.contains(k) {
            if case var .object(vo) = v, let d = vo["description"]?.string, d.count > 60 { vo["description"] = .string(String(d.prefix(60))); kept[k] = .object(vo) }
            else { kept[k] = v }
        }
        o["properties"] = .object(kept)
        return .object(o)
    }

    /// The schema without `expected_revision` (the session supplies it at call time).
    static func withoutRevision(_ schema: JSONValue) -> JSONValue {
        guard case var .object(o) = schema else { return schema }
        if case var .object(p)? = o["properties"] { p["expected_revision"] = nil; o["properties"] = .object(p) }
        if let r = o["required"]?.array { o["required"] = .array(r.filter { $0.string != "expected_revision" }) }
        return .object(o)
    }

    static func dynamic(_ schema: JSONValue, name: String) -> DynamicGenerationSchema {
        let description = schema["description"]?.string
        if let values = schema["enum"]?.array?.compactMap(\.string), !values.isEmpty {
            return DynamicGenerationSchema(name: name, description: description, anyOf: values)
        }
        switch schema["type"]?.string ?? (schema["properties"] != nil ? "object" : "string") {
        case "object":
            let required = Set(schema["required"]?.array?.compactMap(\.string) ?? [])
            let props: [DynamicGenerationSchema.Property] = (schema["properties"].flatMap { if case let .object(o) = $0 { o } else { nil } } ?? [:])
                .sorted { $0.key < $1.key }
                .map { key, value in
                    DynamicGenerationSchema.Property(name: key, description: value["description"]?.string.map { String($0.prefix(120)) },
                                                     schema: dynamic(value, name: name + "_" + key), isOptional: !required.contains(key))
                }
            return DynamicGenerationSchema(name: name, description: description, properties: props)
        case "array":
            let item = schema["items"].map { dynamic($0, name: name + "_item") } ?? DynamicGenerationSchema(type: String.self)
            return DynamicGenerationSchema(arrayOf: item, minimumElements: schema["minItems"]?.number.map { Int($0) },
                                           maximumElements: schema["maxItems"]?.number.map { Int($0) })
        case "number": return DynamicGenerationSchema(type: Double.self)
        case "integer": return DynamicGenerationSchema(type: Int.self)
        case "boolean": return DynamicGenerationSchema(type: Bool.self)
        default: return DynamicGenerationSchema(type: String.self)
        }
    }
}
