import Foundation

// Test-only replacement: this executable never reads or writes the real Keychain.
enum Keychain {
    static func read(_ service: String) -> String? { "offline-test-not-a-credential" }
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

@main struct RemoteProviderAcceptance {
    @MainActor static func main() async {
        guard URLProtocol.registerClass(FixtureProtocol.self) else { fatalError("Cannot isolate URLSession") }
        defer { URLProtocol.unregisterClass(FixtureProtocol.self) }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [FixtureProtocol.self]
        let openAI = OpenAIProvider(session: URLSession(configuration: config))
        let claude = ClaudeProvider()
        var failed = 0, checked = 0
        func run(_ label: String, provider: any AssistantProvider, events: [JSONValue], expected: String, resetDuringStream: Bool = false) async {
            provider.reset()
            provider.addUserMessage("QA Circuiti: conferma soltanto l'anteprima sintetica.")
            FixtureProtocol.prepare(events)
            let before = FixtureProtocol.count
            var actual = "error"
            do {
                var reset = false
                let result = try await provider.runTurn(system: "Offline protocol acceptance", tools: [], onEvent: { _ in
                    if resetDuringStream && !reset { reset = true; provider.reset() }
                })
                switch result {
                case .done: actual = "done"
                case .truncated: actual = "truncated"
                case .refused: actual = "refused"
                case .toolCalls(let calls):
                    actual = calls.count == 1 && calls[0].name == "circuit_apply" && calls[0].arguments?["preview_id"]?.string == "offline-preview" ? "apply" : "other-calls"
                }
            } catch { actual = "error" }
            checked += 1
            let ok = actual == expected && FixtureProtocol.count == before + 1
            if !ok { failed += 1 }
            print("\(ok ? "PASS" : "FAIL") \(label): expected=\(expected) actual=\(actual)")
        }
        let start: JSONValue = ["type": "message_start", "message": ["id": "msg_qa", "type": "message", "role": "assistant", "model": "qa-model", "content": [], "usage": ["input_tokens": 1]]]
        func block(_ index: Int, id: String = "call_qa") -> [JSONValue] { [
            ["type": "content_block_start", "index": .number(Double(index)), "content_block": ["type": "tool_use", "id": .string(id), "name": "circuit_apply", "input": [:]]],
            ["type": "content_block_delta", "index": .number(Double(index)), "delta": ["type": "input_json_delta", "partial_json": "{\"preview_id\":\"offline-preview\",\"expected_revision\":\"qa-revision\"}"]]
        ] }
        let close: JSONValue = ["type": "content_block_stop", "index": 0]
        func stop(_ reason: String) -> JSONValue { ["type": "message_delta", "delta": ["stop_reason": .string(reason)], "usage": ["output_tokens": 1]] }
        let end: JSONValue = ["type": "message_stop"]
        let prefix = [start] + block(0)
        await run("Claude complete", provider: claude, events: prefix + [close, stop("tool_use"), end], expected: "apply")
        await run("Claude EOF after valid arguments", provider: claude, events: prefix, expected: "error")
        await run("Claude EOF before message_stop", provider: claude, events: prefix + [close, stop("tool_use")], expected: "error")
        await run("Claude missing block stop", provider: claude, events: prefix + [stop("tool_use"), end], expected: "error")
        await run("Claude block closed after message_stop", provider: claude, events: prefix + [stop("tool_use"), end, close], expected: "error")
        await run("Claude stop reason after message_stop", provider: claude, events: prefix + [close, end, stop("tool_use")], expected: "error")
        await run("Claude duplicate tool ID", provider: claude, events: prefix + [close] + block(1) + [["type": "content_block_stop", "index": 1], stop("tool_use"), end], expected: "error")
        await run("Claude inconsistent end_turn", provider: claude, events: prefix + [close, stop("end_turn"), end], expected: "error")
        await run("Claude max_tokens", provider: claude, events: prefix + [close, stop("max_tokens"), end], expected: "truncated")
        await run("Claude refusal", provider: claude, events: prefix + [close, stop("refusal"), end], expected: "refused")
        await run("Claude empty stream", provider: claude, events: [], expected: "error")
        await run("Claude server error", provider: claude, events: prefix + [["type": "error", "error": ["type": "overloaded_error", "message": "Offline test"]]], expected: "error")
        await run("Claude conversation reset during stream", provider: claude, events: prefix + [close, stop("tool_use"), end], expected: "error", resetDuringStream: true)
        await run("Claude missing message_start", provider: claude, events: block(0) + [close, stop("tool_use"), end], expected: "error")
        await run("Claude missing stop_reason", provider: claude, events: prefix + [close, end], expected: "error")
        await run("Claude ordinary text", provider: claude, events: [start,
            ["type": "content_block_start", "index": 0, "content_block": ["type": "text", "text": ""]],
            ["type": "content_block_delta", "index": 0, "delta": ["type": "text_delta", "text": "Verifica conclusa."]],
            close, stop("end_turn"), end], expected: "done")

        let item: JSONValue = ["type": "function_call", "id": "fc_qa", "call_id": "call_qa", "name": "circuit_apply", "arguments": "{\"preview_id\":\"offline-preview\",\"expected_revision\":\"qa-revision\"}", "status": "completed"]
        func completed(_ output: [JSONValue]) -> JSONValue { ["type": "response.completed", "response": ["status": "completed", "output": .array(output)]] }
        await run("OpenAI complete", provider: openAI, events: [completed([item])], expected: "apply")
        await run("OpenAI EOF after valid arguments", provider: openAI, events: [["type": "response.output_item.added", "item": item], ["type": "response.output_item.done", "item": item]], expected: "error")
        await run("OpenAI duplicate tool ID", provider: openAI, events: [completed([item, item])], expected: "error")
        await run("OpenAI incomplete", provider: openAI, events: [["type": "response.incomplete", "response": ["status": "incomplete", "output": .array([item])]]], expected: "truncated")
        await run("OpenAI empty stream", provider: openAI, events: [], expected: "error")
        await run("OpenAI server error", provider: openAI, events: [["type": "error", "message": "Offline test"]], expected: "error")
        await run("OpenAI conversation reset during stream", provider: openAI, events: [["type": "response.output_item.added", "item": item], completed([item])], expected: "error", resetDuringStream: true)
        print("\(checked - failed)/\(checked) checks passed. Fixture transport only; no live API, keychain or document changes.")
        exit(failed == 0 ? 0 : 1)
    }
}
