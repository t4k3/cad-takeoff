import Foundation

/// Pure assembler for a Chat Completions SSE stream: text, reasoning, index-slotted
/// tool calls, finish reason and usage. The provider judges completeness before using it.
struct OpenAIChatStreamAssembler {
    private struct Slot {
        var id = ""
        var name = ""
        var json = ""
        var announced = false
    }

    private var slots: [Int: Slot] = [:]
    private(set) var finishReason: String?
    private(set) var content = ""
    private(set) var usage: (input: Int, output: Int)?
    private(set) var streamError: String?

    /// Feeds one `data:` JSON payload; returns the UI events it produces.
    mutating func consume(_ payload: JSONValue) -> [AssistantEvent] {
        if let error = payload["error"] {
            streamError = error["message"]?.string ?? "Errore di streaming"
            return []
        }

        var events: [AssistantEvent] = []
        for choice in payload["choices"]?.array ?? [] {
            if let delta = choice["delta"] {
                if let text = delta["content"]?.string, !text.isEmpty {
                    content += text
                    events.append(.textDelta(text))
                }
                if let reasoning = delta["reasoning_content"]?.string, !reasoning.isEmpty {
                    events.append(.thinkingDelta(reasoning))
                }
                for call in delta["tool_calls"]?.array ?? [] {
                    events += appendToolCall(call)
                }
            }
            // Later chunks with empty choices may still carry usage: they never replace the reason.
            if finishReason == nil, let reason = choice["finish_reason"]?.string { finishReason = reason }
        }

        if let u = payload["usage"], let input = u["prompt_tokens"]?.number, let output = u["completion_tokens"]?.number,
           input.isFinite, output.isFinite, input >= 0, output >= 0, input < 1e12, output < 1e12 {
            usage = (Int(input), Int(output))
            events.append(.usage(input: Int(input), output: Int(output)))
        }
        return events
    }

    private mutating func appendToolCall(_ call: JSONValue) -> [AssistantEvent] {
        guard let index = call["index"]?.number.map(Int.init) else { return [] }
        var slot = slots[index] ?? Slot()
        var events: [AssistantEvent] = []
        if let id = call["id"]?.string, !id.isEmpty, slot.id.isEmpty { slot.id = id }
        if let name = call["function"]?["name"]?.string, !name.isEmpty, slot.name.isEmpty { slot.name = name }
        if !slot.announced, !slot.id.isEmpty, !slot.name.isEmpty {
            slot.announced = true
            events.append(.toolCallStarted(id: slot.id, name: slot.name))
        }
        if let fragment = call["function"]?["arguments"]?.string, !fragment.isEmpty {
            slot.json += fragment
            if !slot.id.isEmpty { events.append(.toolArgumentsDelta(id: slot.id, partial: fragment)) }
        }
        slots[index] = slot
        return events
    }

    /// Tool calls in slot order. Arguments are nil unless the streamed text is a JSON object
    /// (such a call must not run).
    var toolCalls: [ToolCallRequest] {
        slots.keys.sorted().compactMap { i in
            guard let slot = slots[i], !slot.id.isEmpty, !slot.name.isEmpty else { return nil }
            let raw = slot.json.isEmpty ? "{}" : slot.json
            var args = try? JSONValue.parse(Data(raw.utf8))
            if case .object? = args {} else { args = nil }
            return ToolCallRequest(id: slot.id, name: slot.name, arguments: args, rawArguments: raw)
        }
    }

    /// Why the stream cannot be trusted (nil: complete and coherent). Checked by the provider
    /// before anything of the turn is used or stored.
    var incompleteness: String? {
        guard let finishReason else { return "stream interrotto" }
        let calls = toolCalls
        let ids = calls.map(\.id)
        guard Set(ids).count == ids.count else { return "ID di chiamata duplicati" }
        switch finishReason {
        case "tool_calls": return calls.isEmpty ? "tool_calls senza chiamate" : nil
        case "length", "content_filter": return nil
        default: return calls.isEmpty ? nil : "chiamate con fine «\(finishReason)»"
        }
    }
}
