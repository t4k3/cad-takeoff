import Foundation
import Observation

/// Claude via the Anthropic Messages API (raw HTTP: there is no official Swift SDK).
/// Streaming SSE, adaptive thinking with readable summaries, client tools with
/// eager input streaming, server-side refusal fallbacks, automatic prompt caching.
@MainActor
@Observable
final class ClaudeProvider: AssistantProvider {
    static let keychainService = "com.takeoff.fusiontakeoff.anthropic-api-key"
    static let models: [(id: String, name: String)] = [
        ("claude-opus-5", "Claude Opus 5"),
        ("claude-sonnet-5", "Claude Sonnet 5"),
    ]

    let displayName = "Claude"
    var modelID: String {
        didSet { UserDefaults.standard.set(modelID, forKey: "assistant.claude.model") }
    }
    private(set) var hasKey: Bool
    @ObservationIgnored private var history: [JSONValue] = []

    init() {
        modelID = UserDefaults.standard.string(forKey: "assistant.claude.model") ?? Self.models[0].id
        hasKey = Keychain.read(Self.keychainService) != nil
    }

    var modelName: String { Self.models.first { $0.id == modelID }?.name ?? modelID }
    var isConfigured: Bool { hasKey }
    var setupHint: String { "Per usare Claude inserisci la tua API key Anthropic in Impostazioni → Assistente." }

    func setAPIKey(_ key: String?) {
        Keychain.write(Self.keychainService, value: key?.trimmingCharacters(in: .whitespacesAndNewlines))
        hasKey = Keychain.read(Self.keychainService) != nil
    }

    func reset() { history = [] }

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
        guard let key = Keychain.read(Self.keychainService) else { throw AssistantError(message: setupHint) }

        var body: [String: JSONValue] = [
            "model": .string(modelID),
            "max_tokens": 64000,
            "stream": true,
            "system": [["type": "text", "text": .string(system)]],
            "thinking": ["type": "adaptive", "display": "summarized"],
            "cache_control": ["type": "ephemeral"],
            "messages": .array(history),
        ]
        if !tools.isEmpty {
            body["tools"] = .array(tools.map {
                ["name": .string($0.name), "description": .string($0.description),
                 "input_schema": $0.inputSchema, "eager_input_streaming": true]
            })
        }
        var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 600
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.setValue(key, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        if modelID == "claude-opus-5" {
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
            throw Self.httpError(status: status, body: raw)
        }

        var assembler = AnthropicStreamAssembler()
        for try await line in bytes.lines {
            try Task.checkCancellation()
            guard line.hasPrefix("data:") else { continue }
            let json = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
            guard let payload = try? JSONValue.parse(Data(json.utf8)) else { continue }
            for e in assembler.consume(payload) { onEvent(e) }
            if let err = assembler.streamError { throw AssistantError(message: "Claude: \(err)", retryable: true) }
        }

        let content = assembler.contentBlocks
        switch assembler.stopReason {
        case "refusal":
            // Don't keep a declined turn in the history.
            return .refused(assembler.stopExplanation)
        case "max_tokens":
            if !content.isEmpty { history.append(["role": "assistant", "content": .array(content)]) }
            return .truncated
        default:
            history.append(["role": "assistant", "content": .array(content)])
            let calls = assembler.toolCalls
            return calls.isEmpty ? .done : .toolCalls(calls)
        }
    }

    private static func httpError(status: Int, body: Data) -> AssistantError {
        let apiMessage = (try? JSONValue.parse(body))?["error"]?["message"]?.string
        switch status {
        case 401: return AssistantError(message: "API key Anthropic non valida o revocata.")
        case 403: return AssistantError(message: "Accesso negato dall'API Anthropic\(apiMessage.map { ": \($0)" } ?? ".")")
        case 429: return AssistantError(message: "Limite di richieste raggiunto: riprova tra poco.", retryable: true)
        case 529, 500...599: return AssistantError(message: "Servizio Anthropic momentaneamente non disponibile (\(status)).", retryable: true)
        default: return AssistantError(message: "Errore API Anthropic \(status)\(apiMessage.map { ": \($0)" } ?? "").")
        }
    }
}
