import Foundation

@main struct OpenAIProviderTests {
    static func main() throws {
        var checks = 0
        func expect(_ value: Bool, _ message: String) { checks += 1; precondition(value, message) }
        let function: JSONValue = ["type": "function_call", "id": "fc_a", "call_id": "call_a", "name": "scene_info", "arguments": "{}", "status": "completed"]
        let reasoning: JSONValue = ["type": "reasoning", "id": "rs_a", "summary": [], "encrypted_content": "opaque-test"]
        let completed: JSONValue = ["type": "response.completed", "response": ["status": "completed", "output": .array([reasoning, function]), "usage": ["input_tokens": 30, "output_tokens": 10]]]
        var stream = OpenAIStreamAssembler()
        let begun = stream.consume(["type": "response.output_item.added", "item": function])
        expect(begun.count == 1, "tool card at stream start")
        _ = stream.consume(["type": "response.function_call_arguments.delta", "item_id": "fc_a", "delta": "{"])
        do { _ = try stream.finish(); preconditionFailure("partial stream executed") } catch { checks += 1 }
        _ = stream.consume(completed)
        guard case let .toolCalls(calls) = try stream.finish() else { fatalError("expected tool calls") }
        expect(calls.count == 1 && calls[0].id == "call_a" && calls[0].arguments == .object([:]), "complete call only")
        var history = OpenAIConversation()
        history.addUserMessage("Leggi la scena")
        _ = try history.accept(stream)
        expect(history.items.contains(reasoning), "preserve encrypted reasoning")
        history.addToolResults([(calls[0], ToolResult(text: "Scena", structured: ["revision": "r1"]))])
        expect(history.items.last?["type"]?.string == "function_call_output", "tool result response item")
        let resultJSON = try JSONValue.parse(Data(history.items.last!["output"]!.string!.utf8))
        expect(resultJSON["data"]?["revision"]?.string == "r1", "revision returned to model")
        expect(resultJSON["is_error"]?.bool == false, "success flag")
        let count = history.items.count
        history.addToolResults([(calls[0], .error("duplicate"))])
        expect(history.items.count == count, "duplicate tool results ignored")
        let tool = ToolSpec(name: "scene_info", title: "Scena", description: "mm Z-up", inputSchema: ["type": "object", "properties": [:]], isReadOnly: true)
        let request = history.request(model: "test-model", system: "system", tools: [tool])
        expect(request["model"]?.string == "test-model", "selected model")
        expect(request["parallel_tool_calls"]?.bool == false, "writes sequenced")
        expect(request["store"]?.bool == false, "explicit storage policy")
        expect(request["tools"]?.array?.first?["strict"]?.bool == false, "optional parameters not implicitly forced")
        expect(request["tools"]?.array?.first?["parameters"] == tool.inputSchema, "same CAD schema")
        var interruptedHistory = OpenAIConversation()
        _ = try interruptedHistory.accept(stream)
        interruptedHistory.addUserMessage("Continua")
        expect(interruptedHistory.items.suffix(2).first?["type"]?.string == "function_call_output", "cancelled batch closes before new user")
        var incomplete = OpenAIStreamAssembler()
        _ = incomplete.consume(["type": "response.incomplete", "response": ["status": "incomplete", "output": .array([function])]])
        expect(try incomplete.finish() == .truncated, "truncated tools never run")
        var failed = OpenAIStreamAssembler()
        _ = failed.consume(["type": "error", "message": "server test error"])
        do { _ = try failed.finish(); preconditionFailure("error accepted") } catch { checks += 1 }
        var duplicate = OpenAIStreamAssembler()
        _ = duplicate.consume(["type": "response.completed", "response": ["status": "completed", "output": .array([function, function])]])
        do { _ = try duplicate.finish(); preconditionFailure("duplicate accepted") } catch { checks += 1 }
        var malformed = OpenAIStreamAssembler()
        let bad: JSONValue = ["type": "function_call", "call_id": "bad", "name": "add_box", "arguments": "{", "status": "completed"]
        _ = malformed.consume(["type": "response.completed", "response": ["status": "completed", "output": .array([bad])]])
        guard case let .toolCalls(invalidCalls) = try malformed.finish() else { fatalError() }
        expect(invalidCalls[0].arguments == nil, "bad JSON is never executable")
        var refused = OpenAIStreamAssembler()
        _ = refused.consume(["type": "response.completed", "response": ["status": "completed", "output": [["type": "message", "content": [["type": "refusal", "refusal": "declined"]]]]]])
        expect(try refused.finish() == .refused("declined"), "explicit refusal")
        var sse = OpenAISSEDecoder()
        expect(try sse.consume(line: "event: response.created") == nil, "SSE event line")
        expect(try sse.consume(line: "data: {\"type\":") == nil, "multiline pending")
        expect(try sse.consume(line: "data: \"response.created\"}")?["type"]?.string == "response.created", "multiline event decoded")
        expect(try sse.consume(line: "data: [DONE]") == nil, "SSE sentinel")
        print("PASS: \(checks) OpenAI assertions (Responses request, streaming, tool results, interruptions, errors)")
    }
}
