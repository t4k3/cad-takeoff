import Foundation

/// Pure assembler for the Messages API SSE stream: turns `data:` payloads into
/// UI events and rebuilds the assistant content blocks exactly as received, so they
/// can be replayed in the next request (thinking signatures included).
struct AnthropicStreamAssembler {
    private enum Block {
        case text(String)
        case thinking(text: String, signature: String)
        case toolUse(id: String, name: String, json: String)
        /// Any block delivered whole in content_block_start (redacted_thinking, fallback…).
        case opaque(JSONValue)
    }

    private var blocks: [Int: Block] = [:]
    private(set) var stopReason: String?
    private(set) var stopExplanation: String?
    private(set) var servedModel: String?
    private(set) var inputTokens = 0
    private(set) var outputTokens = 0
    private(set) var streamError: String?

    /// Feeds one `data:` JSON payload; returns the UI events it produces.
    mutating func consume(_ payload: JSONValue) -> [AssistantEvent] {
        guard let type = payload["type"]?.string else { return [] }
        switch type {
        case "message_start":
            servedModel = payload["message"]?["model"]?.string
            inputTokens = Int(payload["message"]?["usage"]?["input_tokens"]?.number ?? 0)
            return servedModel.map { [.servedBy(model: $0)] } ?? []
        case "content_block_start":
            guard let i = payload["index"]?.number.map(Int.init), let block = payload["content_block"] else { return [] }
            switch block["type"]?.string {
            case "text":
                let t = block["text"]?.string ?? ""
                blocks[i] = .text(t)
                return t.isEmpty ? [] : [.textDelta(t)]
            case "thinking":
                blocks[i] = .thinking(text: block["thinking"]?.string ?? "", signature: block["signature"]?.string ?? "")
                return []
            case "tool_use":
                let id = block["id"]?.string ?? "tool_\(i)", name = block["name"]?.string ?? "?"
                blocks[i] = .toolUse(id: id, name: name, json: "")
                return [.toolCallStarted(id: id, name: name)]
            default:
                blocks[i] = .opaque(block)
                return []
            }
        case "content_block_delta":
            guard let i = payload["index"]?.number.map(Int.init), let d = payload["delta"] else { return [] }
            switch (d["type"]?.string, blocks[i]) {
            case let ("text_delta", .text(t)?):
                let s = d["text"]?.string ?? ""
                blocks[i] = .text(t + s)
                return [.textDelta(s)]
            case let ("thinking_delta", .thinking(t, sig)?):
                let s = d["thinking"]?.string ?? ""
                blocks[i] = .thinking(text: t + s, signature: sig)
                return s.isEmpty ? [] : [.thinkingDelta(s)]
            case let ("signature_delta", .thinking(t, sig)?):
                blocks[i] = .thinking(text: t, signature: sig + (d["signature"]?.string ?? ""))
                return []
            case let ("input_json_delta", .toolUse(id, name, json)?):
                let s = d["partial_json"]?.string ?? ""
                blocks[i] = .toolUse(id: id, name: name, json: json + s)
                return [.toolArgumentsDelta(id: id, partial: s)]
            default:
                return []
            }
        case "message_delta":
            if let r = payload["delta"]?["stop_reason"]?.string { stopReason = r }
            stopExplanation = payload["delta"]?["stop_details"]?["explanation"]?.string ?? stopExplanation
            let out = Int(payload["usage"]?["output_tokens"]?.number ?? 0)
            outputTokens = out
            return [.usage(input: inputTokens, output: out)]
        case "error":
            streamError = payload["error"]?["message"]?.string ?? "Errore di streaming"
            return []
        default: // ping, message_stop, content_block_stop
            return []
        }
    }

    /// Assistant content blocks for the history, in index order.
    var contentBlocks: [JSONValue] {
        blocks.keys.sorted().compactMap { i -> JSONValue? in
            switch blocks[i]! {
            case let .text(t):
                return t.isEmpty ? nil : ["type": "text", "text": .string(t)]
            case let .thinking(t, sig):
                return ["type": "thinking", "thinking": .string(t), "signature": .string(sig)]
            case let .toolUse(id, name, json):
                let input = (try? JSONValue.parse(Data((json.isEmpty ? "{}" : json).utf8))) ?? .object([:])
                return ["type": "tool_use", "id": .string(id), "name": .string(name), "input": input]
            case let .opaque(v):
                return v
            }
        }
    }

    /// Tool calls requested in this turn. Arguments are nil when the streamed JSON is invalid
    /// (eager input streaming does not validate on the server side).
    var toolCalls: [ToolCallRequest] {
        blocks.keys.sorted().compactMap { i in
            guard case let .toolUse(id, name, json)? = blocks[i] else { return nil }
            let raw = json.isEmpty ? "{}" : json
            var args = try? JSONValue.parse(Data(raw.utf8))
            if case .object? = args {} else { args = nil }
            return ToolCallRequest(id: id, name: name, arguments: args, rawArguments: raw)
        }
    }
}
