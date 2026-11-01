import Foundation

/// One tool call in the Chat Completions shape: `arguments` is the JSON text the model streamed.
struct OpenAIChatToolCall: Sendable, Equatable {
    let id: String
    let name: String
    let arguments: String
}

/// Vendor-specific switches for a Chat Completions request; only the enabled ones are sent.
struct OpenAIChatRequestOptions: Sendable {
    let includeUsage: Bool
    let thinking: Bool
    let reasoningEffort: String?
}

/// Chat Completions history: plain messages plus one `role: "tool"` message per result.
struct OpenAIChatConversation {
    var messages: [JSONValue] = []

    mutating func addUser(_ text: String) {
        messages.append(["role": "user", "content": .string(text)])
    }

    mutating func addAssistant(content: String, toolCalls: [OpenAIChatToolCall]) {
        // `content` is always present (possibly empty): some compatible servers require the key.
        var message: [String: JSONValue] = ["role": "assistant", "content": .string(content)]
        if !toolCalls.isEmpty {
            message["tool_calls"] = .array(toolCalls.map { call in
                ["id": .string(call.id), "type": "function",
                 "function": ["name": .string(call.name), "arguments": .string(call.arguments)]]
            })
        }
        messages.append(.object(message))
    }

    mutating func addToolResults(_ results: [(ToolCallRequest, ToolResult)]) {
        for (call, r) in results {
            var text = r.text
            if let s = r.structured { text += "\n" + s.jsonString }
            messages.append(["role": "tool", "tool_call_id": .string(call.id), "content": .string(text)])
        }
    }

    func request(model: String, system: String, tools: [ToolSpec], options: OpenAIChatRequestOptions) -> JSONValue {
        var body: [String: JSONValue] = [
            "model": .string(model),
            "stream": true,
            "messages": .array([["role": "system", "content": .string(system)]] + messages),
        ]
        if !tools.isEmpty {
            body["tools"] = .array(tools.map { tool in
                ["type": "function", "function": [
                    "name": .string(tool.name),
                    "description": .string(tool.description),
                    "parameters": tool.inputSchema,
                ]]
            })
        }
        if options.includeUsage { body["stream_options"] = ["include_usage": true] }
        if options.thinking { body["thinking"] = ["type": "enabled"] }
        if let effort = options.reasoningEffort { body["reasoning_effort"] = .string(effort) }
        return .object(body)
    }
}
