import Foundation

/// Only the final, completed Responses output is executable. Deltas are presentation only.
struct OpenAIStreamAssembler {
    private(set) var completedResponse: JSONValue?
    private(set) var terminal: AssistantStop?
    private(set) var failure: String?
    private var callIDs: [String: String] = [:]
    private var announcedCalls: Set<String> = []

    mutating func consume(_ event: JSONValue) -> [AssistantEvent] {
        guard terminal == nil, failure == nil else { return [] }
        switch event["type"]?.string {
        case "response.output_text.delta":
            return event["delta"]?.string.map { [.textDelta($0)] } ?? []
        case "response.reasoning_summary_text.delta":
            return event["delta"]?.string.map { [.thinkingDelta($0)] } ?? []
        case "response.output_item.added":
            guard let item = event["item"], item["type"]?.string == "function_call",
                  let id = item["id"]?.string, let callID = item["call_id"]?.string,
                  let name = item["name"]?.string else { return [] }
            callIDs[id] = callID
            announcedCalls.insert(callID)
            return [.toolCallStarted(id: callID, name: name)]
        case "response.function_call_arguments.delta":
            guard let id = event["item_id"]?.string, let call = callIDs[id], let delta = event["delta"]?.string else { return [] }
            return [.toolArgumentsDelta(id: call, partial: delta)]
        case "response.failed", "error":
            failure = event["response"]?["error"]?["message"]?.string ?? event["message"]?.string ?? "Errore nello stream OpenAI."
            return []
        case "response.incomplete":
            terminal = .truncated
            return []
        case "response.completed":
            guard let response = event["response"], response["status"]?.string == "completed",
                  let output = response["output"]?.array else { failure = "Risposta OpenAI finale non valida."; return [] }
            var calls: [ToolCallRequest] = []
            var events: [AssistantEvent] = []
            var ids: Set<String> = []
            for item in output {
                if item["type"]?.string == "function_call" {
                    guard let id = item["call_id"]?.string, !id.isEmpty, ids.insert(id).inserted,
                          let name = item["name"]?.string, !name.isEmpty,
                          let raw = item["arguments"]?.string,
                          item["status"]?.string == nil || item["status"]?.string == "completed" else {
                        failure = "Chiamata strumento incompleta o duplicata: nessuna operazione eseguita."
                        return []
                    }
                    let args = try? JSONValue.parse(Data(raw.utf8))
                    calls.append(ToolCallRequest(id: id, name: name, arguments: args, rawArguments: raw))
                    if !announcedCalls.contains(id) { events.append(.toolCallStarted(id: id, name: name)) }
                }
                for content in item["content"]?.array ?? [] where content["type"]?.string == "refusal" {
                    terminal = .refused(content["refusal"]?.string)
                }
            }
            completedResponse = response
            if terminal == nil { terminal = calls.isEmpty ? .done : .toolCalls(calls) }
            if let usage = response["usage"], let input = usage["input_tokens"]?.number, let output = usage["output_tokens"]?.number,
               input.isFinite, output.isFinite, input >= 0, output >= 0, input < 1e12, output < 1e12 {
                events.append(.usage(input: Int(input), output: Int(output)))
            }
            return events
        default: return []
        }
    }

    func finish() throws -> AssistantStop {
        if let failure { throw AssistantError(message: "OpenAI: \(failure)", retryable: true) }
        guard let terminal else { throw AssistantError(message: "Stream OpenAI interrotto prima della conferma finale. Nessuno strumento parziale è stato eseguito.", retryable: true) }
        return terminal
    }
}

/// SSE data JSON may span multiple data lines; tolerates URLSession line sequences
/// that omit empty separator lines. Payload limit bounds memory for malformed streams.
struct OpenAISSEDecoder {
    private var pending = ""
    mutating func consume(line: String) throws -> JSONValue? {
        guard line.hasPrefix("data:") else { return nil }
        var data = String(line.dropFirst(5))
        if data.hasPrefix(" ") { data.removeFirst() }
        if data == "[DONE]" { return nil }
        pending += data + "\n"
        guard pending.utf8.count <= 8 * 1024 * 1024 else { throw AssistantError(message: "Evento OpenAI troppo grande.") }
        if let value = try? JSONValue.parse(Data(pending.utf8)) { pending = ""; return value }
        return nil
    }
}
