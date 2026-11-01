import Foundation
import Observation

/// Which Anthropic Messages endpoint and request features a Claude provider uses.
/// `.claude` keeps the first-party request exactly as before; `.compatible` only sends
/// the protocol fields every Anthropic-compatible endpoint understands.
struct AnthropicProviderConfig: Sendable, Equatable {
    enum Kind: String, Sendable { case claude, compatible }

    let kind: Kind
    let displayName: String
    let keychainService: String
    /// UserDefaults prefix: the model is "<defaultsKey>.model", the base URL "<defaultsKey>.base".
    let defaultsKey: String
    let defaultBaseURL: String
    let defaultModel: String
    let models: [ModelChoice]
    let maxTokens: Int
    let adaptiveThinking: Bool
    let promptCaching: Bool
    let eagerToolStreaming: Bool
    let serverFallbacks: Bool
    /// When false, an unknown `stop_reason` is accepted instead of making the message invalid.
    let strictStopReasons: Bool

    static let claude = AnthropicProviderConfig(
        kind: .claude, displayName: "Claude",
        keychainService: "com.takeoff.fusiontakeoff.anthropic-api-key",
        defaultsKey: "assistant.claude",
        defaultBaseURL: "https://api.anthropic.com",
        defaultModel: "claude-opus-5",
        models: [ModelChoice(id: "claude-opus-5", name: "Claude Opus 5"),
                 ModelChoice(id: "claude-sonnet-5", name: "Claude Sonnet 5")],
        maxTokens: 64000, adaptiveThinking: true, promptCaching: true,
        eagerToolStreaming: true, serverFallbacks: true, strictStopReasons: true)

    static let compatible = AnthropicProviderConfig(
        kind: .compatible, displayName: String(localized: "Anthropic compatibile"),
        keychainService: "com.takeoff.fusiontakeoff.anthropic-compatible-api-key",
        defaultsKey: "assistant.anthropic-compatible",
        defaultBaseURL: "", defaultModel: "", models: [],
        maxTokens: 8192, adaptiveThinking: false, promptCaching: false,
        eagerToolStreaming: false, serverFallbacks: false, strictStopReasons: false)

    var allowsCustomEndpoint: Bool { kind == .compatible }
}

/// Claude via the Anthropic Messages API (raw HTTP: there is no official Swift SDK).
/// Streaming SSE, adaptive thinking with readable summaries, client tools with
/// eager input streaming, server-side refusal fallbacks, automatic prompt caching.
/// The same class also serves Anthropic-compatible endpoints with a reduced request.
@MainActor
@Observable
final class ClaudeProvider: AssistantProvider {
    static let keychainService = AnthropicProviderConfig.claude.keychainService
    static let models: [ModelChoice] = AnthropicProviderConfig.claude.models

    let config: AnthropicProviderConfig
    var displayName: String { config.displayName }
    var modelID: String {
        didSet { UserDefaults.standard.set(modelID, forKey: config.defaultsKey + ".model") }
    }
    var baseURL: String {
        didSet { UserDefaults.standard.set(baseURL, forKey: config.defaultsKey + ".base") }
    }
    private(set) var hasKey: Bool
    @ObservationIgnored private var history: [JSONValue] = []
    /// A new conversation while a turn streams: that turn's answer belongs to the old one.
    @ObservationIgnored private var conversation = 0

    init(config: AnthropicProviderConfig = .claude) {
        self.config = config
        modelID = UserDefaults.standard.string(forKey: config.defaultsKey + ".model") ?? config.defaultModel
        baseURL = UserDefaults.standard.string(forKey: config.defaultsKey + ".base") ?? config.defaultBaseURL
        hasKey = Keychain.read(config.keychainService) != nil
    }

    var models: [ModelChoice] { config.models }
    var modelName: String {
        config.models.first { $0.id == modelID }?.name ?? (modelID.isEmpty ? String(localized: "non configurato") : modelID)
    }
    var isConfigured: Bool { hasKey && !modelID.isEmpty && endpoint != nil }
    var setupHint: String {
        config.kind == .compatible
            ? String(localized: "Per un modello compatibile Anthropic inserisci base URL, modello e API key in Impostazioni → Assistente.")
            : String(localized: "Per usare Claude inserisci la tua API key Anthropic in Impostazioni → Assistente.")
    }

    func setAPIKey(_ key: String?) {
        Keychain.write(config.keychainService, value: key?.trimmingCharacters(in: .whitespacesAndNewlines))
        hasKey = Keychain.read(config.keychainService) != nil
    }

    func reset() { history = []; conversation += 1 }

    func addUserMessage(_ text: String) {
        history.append(["role": "user", "content": [["type": "text", "text": .string(text)]]])
    }

    func addToolResults(_ results: [(ToolCallRequest, ToolResult)]) {
        // All results of one turn go back in a single user message (keeps parallel tool use working).
        let blocks: [JSONValue] = results.map { call, r in
            var text = r.text
            if let s = r.structured { text += "\n" + s.jsonString }
            return ["type": "tool_result", "tool_use_id": .string(call.id),
                    "content": .string(text), "is_error": .bool(r.isError)]
        }
        history.append(["role": "user", "content": .array(blocks)])
    }

    func runTurn(system: String, tools: [ToolSpec], onEvent: @escaping (AssistantEvent) -> Void) async throws -> AssistantStop {
        guard let key = Keychain.read(config.keychainService) else { throw AssistantError(message: setupHint) }
        guard let url = endpoint else { throw AssistantError(message: setupHint) }
        let turnOf = conversation

        let systemValue: JSONValue = config.adaptiveThinking
            ? .array([["type": "text", "text": .string(system)]])
            : .string(system)
        var body: [String: JSONValue] = [
            "model": .string(modelID),
            "max_tokens": .number(Double(config.maxTokens)),
            "stream": true,
            "system": systemValue,
            "messages": .array(history),
        ]
        if config.adaptiveThinking { body["thinking"] = ["type": "adaptive", "display": "summarized"] }
        if config.promptCaching { body["cache_control"] = ["type": "ephemeral"] }
        if !tools.isEmpty {
            body["tools"] = .array(tools.map { tool -> JSONValue in
                var entry: [String: JSONValue] = ["name": .string(tool.name), "description": .string(tool.description),
                                                  "input_schema": tool.inputSchema]
                if config.eagerToolStreaming { entry["eager_input_streaming"] = true }
                return .object(entry)
            })
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 600
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.setValue(key, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        if config.serverFallbacks, modelID == "claude-opus-5" {
            // On a safety decline, re-run server-side on Anthropic's recommended fallback model.
            body["fallbacks"] = "default"
            request.setValue("server-side-fallback-2026-07-01", forHTTPHeaderField: "anthropic-beta")
        }
        request.httpBody = Data(JSONValue.object(body).jsonString.utf8)

        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            var raw = Data()
            for try await b in bytes { raw.append(b); if raw.count > 64_000 { break } }
            throw Self.httpError(status: status, body: raw, name: displayName)
        }

        var assembler = AnthropicStreamAssembler(strictStopReasons: config.strictStopReasons)
        for try await line in bytes.lines {
            try Task.checkCancellation()
            guard line.hasPrefix("data:") else { continue }
            let json = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
            guard let payload = try? JSONValue.parse(Data(json.utf8)) else { continue }
            for e in assembler.consume(payload) { onEvent(e) }
            if let err = assembler.streamError {
                throw AssistantError(message: "\(displayName): \(err)", retryable: true)
            }
        }

        guard conversation == turnOf else { throw AssistantError(message: "Conversazione ricominciata durante la risposta: nulla eseguito.") }
        // Fail closed: nothing of an incomplete or incoherent message is used (tools least of all).
        if let why = assembler.incompleteness {
            throw AssistantError(message: "\(displayName): risposta non valida (\(why)); nulla eseguito. Riprova.", retryable: true)
        }
        let content = assembler.contentBlocks
        switch assembler.stopReason {
        case "refusal":
            // Don't keep a declined turn in the history.
            return .refused(assembler.stopExplanation)
        case "max_tokens":
            // Its tool calls are never run: kept without them (a call needs its result next turn).
            let kept = assembler.contentBlocksWithoutTools
            if !kept.isEmpty { history.append(["role": "assistant", "content": .array(kept)]) }
            return .truncated
        default:
            history.append(["role": "assistant", "content": .array(content)])
            let calls = assembler.toolCalls
            return calls.isEmpty ? .done : .toolCalls(calls)
        }
    }

    /// `<base>/v1/messages`, tolerating a base that already ends with `/v1` or the whole path.
    static func endpoint(for base: String) -> URL? {
        let trimmed = base.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.hasSuffix("/v1/messages") { return URL(string: trimmed) }
        if trimmed.hasSuffix("/v1") { return URL(string: trimmed + "/messages") }
        return URL(string: trimmed.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/v1/messages")
    }

    private var endpoint: URL? { Self.endpoint(for: baseURL) }

    private static func httpError(status: Int, body: Data, name: String) -> AssistantError {
        let apiMessage = (try? JSONValue.parse(body))?["error"]?["message"]?.string
        switch status {
        case 401: return AssistantError(message: "API key \(name) non valida o revocata.")
        case 403: return AssistantError(message: "Accesso negato dall'API \(name)\(apiMessage.map { ": \($0)" } ?? ".")")
        case 429: return AssistantError(message: "Limite di richieste raggiunto: riprova tra poco.", retryable: true)
        case 529, 500...599: return AssistantError(message: "Servizio \(name) momentaneamente non disponibile (\(status)).", retryable: true)
        default: return AssistantError(message: "Errore API \(name) \(status)\(apiMessage.map { ": \($0)" } ?? "").")
        }
    }
}
