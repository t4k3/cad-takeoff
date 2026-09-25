import Foundation

/// Responses history preserves complete output items, including encrypted reasoning.
/// Unfinished tool batches are closed with error outputs before a new user message.
struct OpenAIConversation {
    private(set) var items: [JSONValue] = []
    private var pending: [ToolCallRequest] = []

    mutating func addUserMessage(_ text: String) {
        if !pending.isEmpty {
            addToolResults(pending.map { ($0, .error("Esecuzione interrotta prima del risultato; rileggere la scena prima di nuove modifiche.")) })
        }
        items.append(["role": "user", "content": .string(text)])
    }
    mutating func accept(_ assembler: OpenAIStreamAssembler) throws -> AssistantStop {
        let stop = try assembler.finish()
        if case .truncated = stop { return stop }
        if let output = assembler.completedResponse?["output"]?.array { items += output }
        if case let .toolCalls(calls) = stop { pending = calls }
        return stop
    }
    mutating func addToolResults(_ results: [(ToolCallRequest, ToolResult)]) {
        for (call, result) in results where pending.contains(where: { $0.id == call.id }) {
            let payload: JSONValue = ["text": .string(result.text), "is_error": .bool(result.isError),
                                      "data": result.structured ?? .null,
                                      "changed_features": .array(result.changedFeatures.map { .string($0.uuidString) })]
            items.append(["type": "function_call_output", "call_id": .string(call.id), "output": .string(payload.jsonString)])
            pending.removeAll { $0.id == call.id }
        }
    }
    func request(model: String, system: String, tools: [ToolSpec]) -> JSONValue {
        ["model": .string(model), "instructions": .string(system), "input": .array(items),
         "stream": true, "store": false, "include": ["reasoning.encrypted_content"],
         "parallel_tool_calls": false,
         "tools": .array(tools.map { tool in
             ["type": "function", "name": .string(tool.name), "description": .string(tool.description),
              "parameters": tool.inputSchema, "strict": false]
         })]
    }
}
