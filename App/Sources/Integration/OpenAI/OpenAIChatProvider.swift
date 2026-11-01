import Foundation
import Observation

/// Which Chat Completions endpoint and vendor switches an OpenAI-style provider uses.
struct OpenAIChatProviderConfig: Sendable, Equatable {
    enum Kind: String, Sendable { case chatGPT, deepSeek, compatible }

    let kind: Kind
    let displayName: String
    let keychainService: String
    /// UserDefaults prefix: the model is "<defaultsKey>.model", the base URL "<defaultsKey>.base".
    let defaultsKey: String
    let defaultBaseURL: String
    let defaultModel: String
    let models: [ModelChoice]
    let includeUsage: Bool
    /// DeepSeek: `thinking: {"type": "enabled"}`.
    let thinking: Bool
    let reasoningEffort: String?
    let allowsCustomEndpoint: Bool

    static let chatGPT = OpenAIChatProviderConfig(
        kind: .chatGPT, displayName: "ChatGPT",
        keychainService: "com.takeoff.fusiontakeoff.openai-api-key",
        defaultsKey: "assistant.openai",
        defaultBaseURL: "https://api.openai.com/v1",
        defaultModel: "gpt-6-sol", models: [ModelChoice(id: "gpt-6-sol", name: "GPT-6 Sol")],
        includeUsage: true, thinking: false, reasoningEffort: nil, allowsCustomEndpoint: false)

    static let deepSeek = OpenAIChatProviderConfig(
        kind: .deepSeek, displayName: "DeepSeek",
        keychainService: "com.takeoff.fusiontakeoff.deepseek-api-key",
        defaultsKey: "assistant.deepseek",
        defaultBaseURL: "https://api.deepseek.com",
        defaultModel: "deepseek-flash",
        models: [ModelChoice(id: "deepseek-flash", name: "DeepSeek Flash"),
                 ModelChoice(id: "deepseek-v4-pro", name: "DeepSeek V4 Pro")],
        includeUsage: true, thinking: true, reasoningEffort: "medium", allowsCustomEndpoint: false)

    static let compatible = OpenAIChatProviderConfig(
        kind: .compatible, displayName: String(localized: "OpenAI compatibile"),
        keychainService: "com.takeoff.fusiontakeoff.openai-compatible-api-key",
        defaultsKey: "assistant.openai-compatible",
        defaultBaseURL: "", defaultModel: "", models: [],
        includeUsage: false, thinking: false, reasoningEffort: nil, allowsCustomEndpoint: true)
}

/// Chat Completions provider (OpenAI, DeepSeek and any compatible endpoint). Raw HTTP,
/// SSE streaming: text, reasoning, `tool_calls` fragments, `role: "tool"` results.
@MainActor
@Observable
final class OpenAIChatProvider: AssistantProvider {
    let config: OpenAIChatProviderConfig
    var displayName: String { config.displayName }
    var modelID: String {
        didSet { UserDefaults.standard.set(modelID, forKey: config.defaultsKey + ".model") }
    }
    var baseURL: String {
        didSet { UserDefaults.standard.set(baseURL, forKey: config.defaultsKey + ".base") }
    }
    private(set) var hasKey: Bool
    @ObservationIgnored private var conversation = OpenAIChatConversation()
    /// A new conversation while a turn streams: that turn's answer belongs to the old one.
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private let session: URLSession

    init(config: OpenAIChatProviderConfig, session: URLSession = .shared) {
        self.config = config
        self.session = session
        modelID = UserDefaults.standard.string(forKey: config.defaultsKey + ".model") ?? config.defaultModel
        baseURL = UserDefaults.standard.string(forKey: config.defaultsKey + ".base") ?? config.defaultBaseURL
        hasKey = !(Keychain.read(config.keychainService) ?? "").isEmpty
    }

    var models: [ModelChoice] { config.models }
    var modelName: String {
        config.models.first { $0.id == modelID }?.name ?? (modelID.isEmpty ? String(localized: "non configurato") : modelID)
    }
    var isConfigured: Bool {
        hasKey && !modelID.isEmpty && !baseURL.isEmpty && endpoint != nil
    }
    var setupHint: String {
        switch config.kind {
        case .chatGPT:
            return String(localized: "Per usare ChatGPT inserisci la tua API key OpenAI in Impostazioni → Assistente.")
        case .deepSeek:
            return String(localized: "Per usare DeepSeek inserisci la tua API key in Impostazioni → Assistente.")
        case .compatible:
            return String(localized: "Per un modello compatibile OpenAI inserisci base URL, modello e API key in Impostazioni → Assistente.")
        }
    }

    func setAPIKey(_ key: String?) {
        Keychain.write(config.keychainService, value: key?.trimmingCharacters(in: .whitespacesAndNewlines))
        hasKey = !(Keychain.read(config.keychainService) ?? "").isEmpty
    }

    func reset() { conversation = OpenAIChatConversation(); generation += 1 }

    func addUserMessage(_ text: String) { conversation.addUser(text) }

    func addToolResults(_ results: [(ToolCallRequest, ToolResult)]) { conversation.addToolResults(results) }

    func runTurn(system: String, tools: [ToolSpec], onEvent: @escaping (AssistantEvent) -> Void) async throws -> AssistantStop {
        guard let key = Keychain.read(config.keychainService), !key.isEmpty else { throw AssistantError(message: setupHint) }
        guard let url = endpoint else { throw AssistantError(message: setupHint) }
        let turnOf = generation

        let body = conversation.request(
            model: modelID, system: system, tools: tools,
            options: OpenAIChatRequestOptions(includeUsage: config.includeUsage, thinking: config.thinking,
                                              reasoningEffort: config.reasoningEffort))
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 600
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.httpBody = Data(body.jsonString.utf8)

        let (bytes, response) = try await session.bytes(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            var raw = Data()
            for try await b in bytes { raw.append(b); if raw.count > 64_000 { break } }
            throw Self.httpError(status: status, body: raw, name: displayName)
        }

        var decoder = OpenAISSEDecoder()
        var assembler = OpenAIChatStreamAssembler()
        for try await line in bytes.lines {
            try Task.checkCancellation()
            guard generation == turnOf else {
                throw AssistantError(message: "Conversazione ricominciata durante la risposta: nulla eseguito.")
            }
            guard let payload = try decoder.consume(line: line) else { continue }
            for e in assembler.consume(payload) { onEvent(e) }
            if let err = assembler.streamError {
                throw AssistantError(message: "\(displayName): \(err)", retryable: true)
            }
        }

        guard generation == turnOf else {
            throw AssistantError(message: "Conversazione ricominciata durante la risposta: nulla eseguito.")
        }
        // Fail closed: nothing of an incomplete or incoherent message is used (tools least of all).
        if let why = assembler.incompleteness {
            throw AssistantError(message: "\(displayName): risposta non valida (\(why)); nulla eseguito. Riprova.", retryable: true)
        }
        let content = assembler.content
        switch assembler.finishReason ?? "" {
        case "length":
            // Its tool calls are never run: kept without them (a call needs its result next turn).
            if !content.isEmpty { conversation.addAssistant(content: content, toolCalls: []) }
            return .truncated
        case "content_filter":
            // Don't keep a filtered turn in the history.
            return .refused(nil)
        case "tool_calls":
            let calls = assembler.toolCalls
            conversation.addAssistant(content: content, toolCalls: calls.map {
                OpenAIChatToolCall(id: $0.id, name: $0.name, arguments: $0.rawArguments)
            })
            return .toolCalls(calls)
        default:
            // "stop" and any unknown reason (already checked: no tool calls).
            if !content.isEmpty { conversation.addAssistant(content: content, toolCalls: []) }
            return .done
        }
    }

    /// `<base>/chat/completions`, tolerating a base that already ends with the whole path.
    static func endpoint(for base: String) -> URL? {
        let trimmed = base.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.hasSuffix("/chat/completions") { return URL(string: trimmed) }
        return URL(string: trimmed.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/chat/completions")
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
