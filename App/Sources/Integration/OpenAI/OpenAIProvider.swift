import Foundation
import Observation

/// OpenAI Responses API adapter. API credentials are distinct from a ChatGPT login.
@MainActor
@Observable
final class OpenAIProvider: AssistantProvider {
    static let keychainService = "com.takeoff.fusiontakeoff.openai-api-key"
    static let models: [(id: String, name: String)] = [("gpt-6-sol", "GPT-6 Sol")]
    let displayName = "OpenAI"
    var modelID: String {
        didSet {
            UserDefaults.standard.set(modelID, forKey: "assistant.openai.model")
            if modelID != oldValue { reset() }
        }
    }
    private(set) var hasKey: Bool
    private(set) var credentialError: String?
    @ObservationIgnored private var conversation = OpenAIConversation()
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
        modelID = UserDefaults.standard.string(forKey: "assistant.openai.model") ?? Self.models[0].id
        hasKey = !(Keychain.read(Self.keychainService) ?? "").isEmpty
    }
    var modelName: String { Self.models.first { $0.id == modelID }?.name ?? modelID }
    var isConfigured: Bool { hasKey }
    var setupHint: String { credentialError ?? "Inserisci la chiave API OpenAI in Impostazioni → Assistente. Il login ChatGPT non configura automaticamente questa chiave." }

    func setAPIKey(_ key: String?) {
        let value = key?.trimmingCharacters(in: .whitespacesAndNewlines)
        let saved = Keychain.write(Self.keychainService, value: value)
        credentialError = saved ? nil : "Impossibile salvare la chiave OpenAI nel Portachiavi."
        hasKey = !(Keychain.read(Self.keychainService) ?? "").isEmpty
        reset()
    }
    func reset() { conversation = OpenAIConversation(); generation = UUID() }
    func addUserMessage(_ text: String) { conversation.addUserMessage(text) }
    func addToolResults(_ results: [(ToolCallRequest, ToolResult)]) { conversation.addToolResults(results) }

    func runTurn(system: String, tools: [ToolSpec], onEvent: @escaping (AssistantEvent) -> Void) async throws -> AssistantStop {
        guard let key = Keychain.read(Self.keychainService), !key.isEmpty else { throw AssistantError(message: setupHint) }
        let epoch = generation
        let body = conversation.request(model: modelID, system: system, tools: tools)
        var req = URLRequest(url: URL(string: "https://api.openai.com/v1/responses")!)
        req.httpMethod = "POST"; req.timeoutInterval = 300
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        req.httpBody = try JSONEncoder().encode(body)
        let (bytes, response) = try await session.bytes(for: req)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            // Do not log raw error bodies or credentials. Stable, actionable UI messages.
            switch status {
            case 401: throw AssistantError(message: "Chiave API OpenAI non valida o revocata.")
            case 403: throw AssistantError(message: "Accesso OpenAI negato: verificare progetto e permessi del modello.")
            case 404: throw AssistantError(message: "Modello OpenAI non disponibile per questo account. Verificare il modello configurato.")
            case 429: throw AssistantError(message: "Quota o limite API OpenAI raggiunto. Verificare il progetto API prima di riprovare.", retryable: true)
            case 500...599: throw AssistantError(message: "Servizio OpenAI non disponibile (\(status)).", retryable: true)
            default: throw AssistantError(message: "Richiesta OpenAI rifiutata (HTTP \(status)).")
            }
        }
        var decoder = OpenAISSEDecoder()
        var assembler = OpenAIStreamAssembler()
        for try await line in bytes.lines {
            try Task.checkCancellation()
            guard epoch == generation else { throw CancellationError() }
            if let payload = try decoder.consume(line: line) {
                for event in assembler.consume(payload) { onEvent(event) }
                if assembler.failure != nil || assembler.terminal != nil { break }
            }
        }
        try Task.checkCancellation()
        guard epoch == generation else { throw CancellationError() }
        return try conversation.accept(assembler)
    }
}
