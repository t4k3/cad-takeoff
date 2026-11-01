import Foundation

// Offline acceptance for the assistant provider layer (T150: Claude / ChatGPT / DeepSeek and the
// two compatible endpoints). This executable never reads or writes the real Keychain and, unless
// `--live` is passed, never opens a network connection (every URLRequest is served by a fixture).

/// Test-only replacement: the DeepSeek service resolves to DEEPSEEK_API_KEY, nothing else exists.
enum Keychain {
    static let deepSeekService = "com.takeoff.fusiontakeoff.deepseek-api-key"
    static func read(_ service: String) -> String? {
        guard service == deepSeekService else { return nil }
        return ProcessInfo.processInfo.environment["DEEPSEEK_API_KEY"]
    }
    @discardableResult static func write(_ service: String, value: String?) -> Bool { true }
}

/// Intercepts every URLSession request, including ClaudeProvider's shared session.
/// No request is forwarded to a network transport.
final class FixtureProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var payload = Data()
    nonisolated(unsafe) private static var requests = 0
    static func prepare(_ events: [JSONValue]) {
        lock.withLock { payload = Data(events.map { "data: \($0.jsonString)\n\n" }.joined().utf8) }
    }
    static var count: Int { lock.withLock { requests } }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let body = Self.lock.withLock { Self.requests += 1; return Self.payload }
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "text/event-stream"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

// The QA keychain stub only knows the DeepSeek service, so the offline fixtures (.chatGPT /
// .compatible request shapes) and the live Anthropic-compatible call reuse that service. The
// request body is the real production one: only the credentials lookup differs.

extension OpenAIChatProviderConfig {
    static func qaChatGPT() -> OpenAIChatProviderConfig {
        let base = OpenAIChatProviderConfig.chatGPT
        return OpenAIChatProviderConfig(
            kind: .chatGPT, displayName: base.displayName,
            keychainService: Keychain.deepSeekService,
            defaultsKey: "assistant.qa-chatgpt",
            defaultBaseURL: base.defaultBaseURL, defaultModel: base.defaultModel, models: base.models,
            includeUsage: base.includeUsage, thinking: base.thinking, reasoningEffort: base.reasoningEffort,
            allowsCustomEndpoint: base.allowsCustomEndpoint)
    }
}

extension AnthropicProviderConfig {
    static func qaCompatible(base: String, model: String) -> AnthropicProviderConfig {
        let compatible = AnthropicProviderConfig.compatible
        return AnthropicProviderConfig(
            kind: .compatible, displayName: compatible.displayName,
            keychainService: Keychain.deepSeekService,
            defaultsKey: "assistant.qa-anthropic-compatible",
            defaultBaseURL: base, defaultModel: model, models: compatible.models,
            maxTokens: compatible.maxTokens, adaptiveThinking: compatible.adaptiveThinking,
            promptCaching: compatible.promptCaching, eagerToolStreaming: compatible.eagerToolStreaming,
            serverFallbacks: compatible.serverFallbacks, strictStopReasons: compatible.strictStopReasons)
    }
}

@MainActor
final class Checker {
    private(set) var checked = 0
    private(set) var failed = 0
    func expect(_ ok: Bool, _ label: String) {
        checked += 1
        if !ok { failed += 1; print("FAIL \(label)") }
    }
}

// —— Chat Completions stream payload builders ——

func chunk(_ delta: JSONValue = .object([:]), finish: String? = nil) -> JSONValue {
    var choice: [String: JSONValue] = ["index": 0, "delta": delta]
    if let finish { choice["finish_reason"] = .string(finish) }
    return .object(["choices": .array([.object(choice)])])
}

func toolCall(index: Int, id: String? = nil, name: String? = nil, arguments: String? = nil) -> [String: JSONValue] {
    var call: [String: JSONValue] = ["index": .number(Double(index))]
    if let id { call["id"] = .string(id) }
    var function: [String: JSONValue] = [:]
    if let name { function["name"] = .string(name) }
    if let arguments { function["arguments"] = .string(arguments) }
    if !function.isEmpty { call["function"] = .object(function) }
    return call
}

func toolChunk(_ call: [String: JSONValue]) -> JSONValue {
    chunk(.object(["tool_calls": .array([.object(call)])]))
}

func feed(_ payloads: [JSONValue]) -> (assembler: OpenAIChatStreamAssembler, events: [AssistantEvent]) {
    var assembler = OpenAIChatStreamAssembler()
    var events: [AssistantEvent] = []
    for payload in payloads { events += assembler.consume(payload) }
    return (assembler, events)
}

func kinds(_ events: [AssistantEvent]) -> [String] {
    events.map {
        switch $0 {
        case .textDelta: return "text"
        case .thinkingDelta: return "thinking"
        case .toolCallStarted: return "started"
        case .toolArgumentsDelta: return "arguments"
        case .usage: return "usage"
        case .servedBy: return "served"
        }
    }
}

func textDelivered(_ events: [AssistantEvent]) -> [String] {
    events.compactMap { if case .textDelta(let t) = $0 { return t } else { return nil } }
}

func thinkingDelivered(_ events: [AssistantEvent]) -> [String] {
    events.compactMap { if case .thinkingDelta(let t) = $0 { return t } else { return nil } }
}

func argumentPartials(_ events: [AssistantEvent]) -> [String] {
    events.compactMap { if case .toolArgumentsDelta(_, let partial) = $0 { return partial } else { return nil } }
}

/// Runs one turn against the fixture transport.
@MainActor
func runFixture(_ provider: any AssistantProvider, events: [JSONValue])
    async -> (outcome: String, calls: [ToolCallRequest], streamed: [AssistantEvent]) {
    provider.reset()
    provider.addUserMessage("QA offline: nessuna richiesta di rete.")
    FixtureProtocol.prepare(events)
    var streamed: [AssistantEvent] = []
    do {
        let stop = try await provider.runTurn(system: "Offline fixture", tools: [], onEvent: { streamed.append($0) })
        switch stop {
        case .done: return ("done", [], streamed)
        case .truncated: return ("truncated", [], streamed)
        case .refused: return ("refused", [], streamed)
        case .toolCalls(let calls): return ("toolCalls", calls, streamed)
        }
    } catch {
        print("  fixture error: \(error.localizedDescription)")
        return ("error", [], streamed)
    }
}

@main struct AssistantProviderAcceptance {
    @MainActor static func main() async {
        let isLive = CommandLine.arguments.contains("--live")
        let checker = Checker()
        // Offline runs must not depend on a real credential: the stub keychain gets a placeholder.
        if !isLive { _ = setenv("DEEPSEEK_API_KEY", "offline-test-not-a-credential", 1) }

        // —— 1. Endpoint normalisation ——
        checker.expect(ClaudeProvider.endpoint(for: "https://api.anthropic.com")?.absoluteString == "https://api.anthropic.com/v1/messages",
                       "claude base becomes /v1/messages")
        checker.expect(ClaudeProvider.endpoint(for: "https://api.deepseek.com/anthropic")?.absoluteString == "https://api.deepseek.com/anthropic/v1/messages",
                       "anthropic-compatible base becomes /v1/messages")
        checker.expect(ClaudeProvider.endpoint(for: "https://api.deepseek.com/anthropic/v1/messages")?.absoluteString == "https://api.deepseek.com/anthropic/v1/messages",
                       "claude full path stays untouched")
        checker.expect(ClaudeProvider.endpoint(for: "https://api.anthropic.com/")?.absoluteString == "https://api.anthropic.com/v1/messages",
                       "claude trailing slash tolerated")
        checker.expect(ClaudeProvider.endpoint(for: "   ") == nil, "claude blank base has no endpoint")
        checker.expect(OpenAIChatProvider.endpoint(for: "https://api.deepseek.com")?.absoluteString == "https://api.deepseek.com/chat/completions",
                       "openai base becomes /chat/completions")
        checker.expect(OpenAIChatProvider.endpoint(for: "https://api.openai.com/v1")?.absoluteString == "https://api.openai.com/v1/chat/completions",
                       "openai /v1 base becomes /v1/chat/completions")
        checker.expect(OpenAIChatProvider.endpoint(for: "https://api.openai.com/v1/chat/completions")?.absoluteString == "https://api.openai.com/v1/chat/completions",
                       "openai full path stays untouched")
        checker.expect(OpenAIChatProvider.endpoint(for: "https://api.deepseek.com/")?.absoluteString == "https://api.deepseek.com/chat/completions",
                       "openai trailing slash tolerated")
        checker.expect(OpenAIChatProvider.endpoint(for: "") == nil, "openai empty base has no endpoint")

        // —— 2. Chat Completions request shape ——
        let probe = ToolSpec(name: "probe_tool", title: "Sonda", description: "No parameters.",
                             inputSchema: ["type": "object", "properties": JSONValue.object([:])], isReadOnly: true)
        var conversation = OpenAIChatConversation()
        conversation.addUser("ciao")
        conversation.addAssistant(content: "ok", toolCalls: [OpenAIChatToolCall(id: "call_1", name: "probe_tool", arguments: "{\"x\":1}")])
        conversation.addToolResults([
            (ToolCallRequest(id: "call_1", name: "probe_tool", arguments: ["x": 1], rawArguments: "{\"x\":1}"),
             ToolResult(text: "fatto", structured: ["ok": true])),
            (ToolCallRequest(id: "call_2", name: "probe_tool", arguments: nil, rawArguments: ""),
             ToolResult.error("no")),
        ])
        let request = conversation.request(model: "gpt-6-sol", system: "SYS", tools: [probe],
                                           options: OpenAIChatRequestOptions(includeUsage: false, thinking: false, reasoningEffort: nil))
        let messages = request["messages"]?.array ?? []
        checker.expect(messages.count == 5, "request carries system + user + assistant + 2 tool results")
        checker.expect(messages.first?["role"]?.string == "system" && messages.first?["content"]?.string == "SYS",
                       "system message comes first")
        checker.expect(messages.count > 1 && messages[1]["role"]?.string == "user" && messages[1]["content"]?.string == "ciao",
                       "user message appended after the system one")
        checker.expect(messages.count > 2 && messages[2]["role"]?.string == "assistant" && messages[2]["content"]?.string == "ok",
                       "assistant message keeps its content")
        checker.expect(messages.count > 2 && messages[2]["tool_calls"]?.array?[0]["id"]?.string == "call_1"
                       && messages[2]["tool_calls"]?.array?[0]["function"]?["name"]?.string == "probe_tool",
                       "assistant tool_calls keep id and name")
        checker.expect(messages.count > 2 && messages[2]["tool_calls"]?.array?[0]["function"]?["arguments"]?.string == "{\"x\":1}",
                       "tool call arguments stay the streamed string")
        checker.expect(messages.count > 3 && messages[3]["role"]?.string == "tool" && messages[3]["tool_call_id"]?.string == "call_1",
                       "first result is one role:tool message with tool_call_id")
        checker.expect(messages.count > 4 && messages[4]["role"]?.string == "tool" && messages[4]["tool_call_id"]?.string == "call_2",
                       "second result is its own role:tool message")
        checker.expect(messages[3]["content"]?.string?.hasPrefix("fatto") == true, "tool result content keeps the text")
        checker.expect(request["model"]?.string == "gpt-6-sol" && request["stream"]?.bool == true, "model and stream are set")
        checker.expect(request["tools"]?.array?.count == 1 && request["tools"]?.array?[0]["type"]?.string == "function"
                       && request["tools"]?.array?[0]["function"]?["parameters"] != nil, "tools use the function shape")
        checker.expect(conversation.request(model: "m", system: "S", tools: [],
                                            options: OpenAIChatRequestOptions(includeUsage: false, thinking: false, reasoningEffort: nil))["tools"] == nil,
                       "tools are omitted when there are none")

        let deepSeekRequest = conversation.request(model: "deepseek-flash", system: "SYS", tools: [probe],
                                                   options: OpenAIChatRequestOptions(includeUsage: true, thinking: true, reasoningEffort: "medium"))
        checker.expect(deepSeekRequest["thinking"]?["type"]?.string == "enabled", "deepSeek sends thinking enabled")
        checker.expect(deepSeekRequest["reasoning_effort"]?.string == "medium", "deepSeek sends reasoning_effort")
        checker.expect(deepSeekRequest["stream_options"]?["include_usage"]?.bool == true, "deepSeek asks for usage")
        let compatibleRequest = conversation.request(model: "custom", system: "SYS", tools: [probe],
                                                     options: OpenAIChatRequestOptions(includeUsage: false, thinking: false, reasoningEffort: nil))
        checker.expect(compatibleRequest["thinking"] == nil, "compatible endpoint sends no thinking")
        checker.expect(compatibleRequest["reasoning_effort"] == nil, "compatible endpoint sends no reasoning_effort")
        checker.expect(compatibleRequest["stream_options"] == nil, "compatible endpoint sends no stream_options")

        // —— 3. Chat Completions stream assembler ——
        let fragmented = feed([
            toolChunk(toolCall(index: 0, id: "call_1", name: "probe_tool", arguments: "")),
            toolChunk(toolCall(index: 0, arguments: "{\"x\": ")),
            toolChunk(toolCall(index: 0, arguments: "12}")),
            chunk(finish: "tool_calls"),
        ])
        checker.expect(kinds(fragmented.events).filter { $0 == "started" }.count == 1, "one tool call announced once")
        checker.expect(argumentPartials(fragmented.events) == ["{\"x\": ", "12}"], "each argument fragment becomes a delta")
        checker.expect(fragmented.assembler.finishReason == "tool_calls", "finish_reason tool_calls recorded")
        checker.expect(fragmented.assembler.incompleteness == nil, "fragmented tool call is complete")
        checker.expect(fragmented.assembler.toolCalls.map(\.id) == ["call_1"], "one rebuilt tool call")
        checker.expect(fragmented.assembler.toolCalls.first?.arguments?["x"]?.number == 12, "rebuild arguments are parsed JSON")
        checker.expect(fragmented.assembler.toolCalls.first?.rawArguments == "{\"x\": 12}", "raw arguments are kept")

        let parallel = feed([
            toolChunk(toolCall(index: 1, id: "call_b", name: "second_tool", arguments: "{}")),
            toolChunk(toolCall(index: 0, id: "call_a", name: "first_tool", arguments: "{}")),
            chunk(finish: "tool_calls"),
        ])
        checker.expect(kinds(parallel.events).filter { $0 == "started" }.count == 2, "two parallel calls announced")
        checker.expect(parallel.assembler.toolCalls.map(\.id) == ["call_a", "call_b"], "parallel calls are ordered by index")
        checker.expect(parallel.assembler.toolCalls.map(\.name) == ["first_tool", "second_tool"], "parallel calls keep their names")

        let text = feed([chunk(["content": "Ciao"]), chunk(["content": " mondo"]), chunk(finish: "stop")])
        checker.expect(textDelivered(text.events) == ["Ciao", " mondo"], "plain text arrives as textDelta")
        checker.expect(text.assembler.content == "Ciao mondo", "text content is assembled")
        checker.expect(text.assembler.finishReason == "stop", "finish_reason stop recorded")
        checker.expect(text.assembler.incompleteness == nil, "plain stop is complete")

        let length = feed([chunk(["content": "x"]), chunk(finish: "length")])
        checker.expect(length.assembler.finishReason == "length", "length is kept for the provider to map to truncated")
        checker.expect(length.assembler.incompleteness == nil, "length is a complete stream")

        let filtered = feed([chunk(["content": "x"]), chunk(finish: "content_filter")])
        checker.expect(filtered.assembler.finishReason == "content_filter", "content_filter is kept for the provider")
        checker.expect(filtered.assembler.incompleteness == nil, "content_filter is a complete stream")

        let missingReason = feed([chunk(["content": "x"])])
        checker.expect(missingReason.assembler.incompleteness != nil, "missing finish_reason is incomplete")

        let emptyCalls = feed([chunk(finish: "tool_calls")])
        checker.expect(emptyCalls.assembler.incompleteness != nil, "tool_calls without calls is incomplete")

        let stopWithCall = feed([
            toolChunk(toolCall(index: 0, id: "call_9", name: "probe_tool", arguments: "{}")),
            chunk(finish: "stop"),
        ])
        checker.expect(stopWithCall.assembler.incompleteness != nil, "stop with a call is incomplete")

        let duplicate = feed([
            toolChunk(toolCall(index: 0, id: "dup", name: "first_tool", arguments: "{}")),
            toolChunk(toolCall(index: 1, id: "dup", name: "second_tool", arguments: "{}")),
            chunk(finish: "tool_calls"),
        ])
        checker.expect(duplicate.assembler.incompleteness != nil, "duplicate tool ids are incomplete")

        let invalid = feed([
            toolChunk(toolCall(index: 0, id: "call_j", name: "probe_tool", arguments: "{\"x\": ")),
            chunk(finish: "tool_calls"),
        ])
        checker.expect(invalid.assembler.toolCalls.count == 1, "the call is still listed")
        checker.expect(invalid.assembler.toolCalls.first?.arguments == nil, "invalid arguments parse to nil")
        checker.expect(invalid.assembler.toolCalls.first?.rawArguments == "{\"x\": ", "invalid arguments keep the raw text")

        let reasoning = feed([chunk(["reasoning_content": "Penso..."])])
        checker.expect(thinkingDelivered(reasoning.events) == ["Penso..."], "reasoning_content becomes thinkingDelta")

        let usage = feed([chunk(finish: "stop"), ["choices": [], "usage": ["prompt_tokens": 3, "completion_tokens": 5]]])
        checker.expect(kinds(usage.events).filter { $0 == "usage" }.count == 1, "usage block emits one usage event")
        checker.expect(usage.assembler.usage?.input == 3 && usage.assembler.usage?.output == 5, "usage tokens are recorded")
        checker.expect(usage.assembler.finishReason == "stop", "a usage block does not replace finish_reason")

        let streamError = feed([["error": ["type": "invalid_request_error", "message": "boom"]]])
        checker.expect(streamError.assembler.streamError == "boom", "error payload sets streamError")
        checker.expect(streamError.events.isEmpty, "error payload emits no events")

        if isLive {
            // —— 5. Live DeepSeek smoke: 3 requests, no retries, key never printed ——
            guard let key = ProcessInfo.processInfo.environment["DEEPSEEK_API_KEY"], !key.isEmpty else {
                print("live: DEEPSEEK_API_KEY not set, skipping the 3 live requests.")
                report(checker)
            }
            let textProvider = OpenAIChatProvider(config: .deepSeek)
            textProvider.reset()
            textProvider.addUserMessage("Rispondi solo: OK")
            var liveText = ""
            do {
                let stop = try await textProvider.runTurn(system: "Test automatico: risposte di una parola.", tools: [], onEvent: { event in
                    if case .textDelta(let t) = event { liveText += t }
                })
                checker.expect(stop == .done, "live 1: chat completions returns .done")
                checker.expect(!liveText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, "live 1: text is not empty")
                print("live 1: \(stop == .done ? ".done" : "unexpected stop") with \(liveText.count) characters")
            } catch {
                checker.expect(false, "live 1: request failed")
                print("live 1: error \(error.localizedDescription)")
            }

            let probeSpec = ToolSpec(name: "probe_tool", title: "Sonda", description: "No-argument probe: call it with an empty object.",
                                     inputSchema: ["type": "object", "properties": JSONValue.object([:])], isReadOnly: true)
            let toolProvider = OpenAIChatProvider(config: .deepSeek)
            toolProvider.reset()
            toolProvider.addUserMessage("Chiama lo strumento probe_tool senza argomenti.")
            do {
                let stop = try await toolProvider.runTurn(system: "Test automatico: usa lo strumento disponibile.", tools: [probeSpec], onEvent: { _ in })
                switch stop {
                case .toolCalls(let calls):
                    print("live 2: .toolCalls \(calls.map(\.name))")
                    checker.expect(true, "live 2: answered with tool calls")
                case .done:
                    print("live 2: .done without tool calls")
                    checker.expect(true, "live 2: answered without tool calls")
                case .truncated:
                    print("live 2: .truncated")
                    checker.expect(false, "live 2: truncated")
                case .refused:
                    print("live 2: .refused")
                    checker.expect(false, "live 2: refused")
                }
            } catch {
                checker.expect(false, "live 2: request failed")
                print("live 2: error \(error.localizedDescription)")
            }

            let anthropicProvider = ClaudeProvider(config: .qaCompatible(base: "https://api.deepseek.com/anthropic", model: "deepseek-flash"))
            anthropicProvider.reset()
            anthropicProvider.addUserMessage("Rispondi solo: OK")
            do {
                let stop = try await anthropicProvider.runTurn(system: "Test automatico: risposte di una parola.", tools: [], onEvent: { _ in })
                checker.expect(stop == .done, "live 3: anthropic-compatible returns .done")
                print("live 3: \(stop == .done ? ".done" : "unexpected stop")")
            } catch {
                checker.expect(false, "live 3: request failed")
                print("live 3: error \(error.localizedDescription)")
            }
        } else {
            // —— 4. Provider-level turns over the fixture transport ——
            guard URLProtocol.registerClass(FixtureProtocol.self) else { fatalError("Cannot isolate URLSession") }
            let sessionConfig = URLSessionConfiguration.ephemeral
            sessionConfig.protocolClasses = [FixtureProtocol.self]
            let session = URLSession(configuration: sessionConfig)

            let chatFixture: [JSONValue] = [
                chunk(["content": "Penso."]),
                toolChunk(toolCall(index: 0, id: "call_fx", name: "probe_tool", arguments: "{\"ok\": true}")),
                chunk(finish: "tool_calls"),
            ]
            let chatProvider = OpenAIChatProvider(config: .qaChatGPT(), session: session)
            let chatRun = await runFixture(chatProvider, events: chatFixture)
            checker.expect(chatRun.outcome == "toolCalls", "OpenAI fixture ends with .toolCalls")
            checker.expect(chatRun.calls.count == 1 && chatRun.calls.first?.name == "probe_tool", "OpenAI fixture returns probe_tool")
            checker.expect(chatRun.calls.first?.arguments?["ok"]?.bool == true, "OpenAI fixture arguments are parsed")
            checker.expect(kinds(chatRun.streamed).filter { $0 == "text" }.count == 1, "OpenAI fixture streams its text")

            let messageStart: JSONValue = ["type": "message_start", "message": ["id": "msg_qa", "type": "message", "role": "assistant",
                                                                                "model": "qa-model", "content": [], "usage": ["input_tokens": 1]]]
            let anthropicFixture: [JSONValue] = [
                messageStart,
                ["type": "content_block_start", "index": 0, "content_block": ["type": "text", "text": ""]],
                ["type": "content_block_delta", "index": 0, "delta": ["type": "text_delta", "text": "Verifica offline."]],
                ["type": "content_block_stop", "index": 0],
                ["type": "message_delta", "delta": ["stop_reason": "end_turn"], "usage": ["output_tokens": 1]],
                ["type": "message_stop"],
            ]
            let anthropicProvider = ClaudeProvider(config: .qaCompatible(base: "https://api.anthropic.com", model: "compatible-test"))
            let anthropicRun = await runFixture(anthropicProvider, events: anthropicFixture)
            checker.expect(anthropicRun.outcome == "done", "Anthropic-compatible fixture ends with .done")
            checker.expect(textDelivered(anthropicRun.streamed) == ["Verifica offline."], "Anthropic-compatible fixture streams its text")

            // A conversation restarted while the answer streams: that turn must be discarded.
            FixtureProtocol.prepare(chatFixture)
            let resetProvider = OpenAIChatProvider(config: .qaChatGPT(), session: session)
            resetProvider.reset()
            resetProvider.addUserMessage("QA reset durante lo stream.")
            var didReset = false
            var thrown = false
            do {
                _ = try await resetProvider.runTurn(system: "Offline fixture", tools: [], onEvent: { _ in
                    if !didReset { didReset = true; resetProvider.reset() }
                })
            } catch {
                thrown = true
            }
            checker.expect(thrown, "reset during the stream throws")
            checker.expect(FixtureProtocol.count == 3, "one fixture request per offline turn")
            URLProtocol.unregisterClass(FixtureProtocol.self)
        }

        report(checker)
    }

    @MainActor private static func report(_ checker: Checker) -> Never {
        print(checker.failed == 0 ? "PASS \(checker.checked)/\(checker.checked)" : "FAIL \(checker.failed)/\(checker.checked)")
        exit(checker.failed == 0 ? 0 : 1)
    }
}
