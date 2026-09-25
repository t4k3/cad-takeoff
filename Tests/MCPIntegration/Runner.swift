import Foundation
import CADCore

@main struct MCPIntegrationTests {
    @MainActor static func main() async throws {
        let model = DesignModel(); model.newDesign()
        let server = MCPServer(); server.provider = model
        let token = UUID().uuidString
        let transport = LocalHTTPTransport(token: token) { data, client in await server.handle(data, client: client) }
        let port: UInt16 = try await withCheckedThrowingContinuation { c in transport.start(preferredPort: 0) { c.resume(with: $0) } }
        defer { transport.stop() }
        var checks = 0
        func expect(_ b: Bool, _ s: String) { checks += 1; precondition(b, s) }
        func send(_ method: String, _ params: JSONValue = [:], token supplied: String? = nil, origin: String? = nil) async throws -> (Int, JSONValue?) {
            var req = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/mcp")!)
            req.httpMethod = "POST"; req.timeoutInterval = 5
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.setValue("Bearer \(supplied ?? token)", forHTTPHeaderField: "Authorization")
            if let origin { req.setValue(origin, forHTTPHeaderField: "Origin") }
            let message: JSONValue = ["jsonrpc": "2.0", "id": 1, "method": .string(method), "params": params]
            req.httpBody = Data(message.jsonString.utf8)
            let (data, resp) = try await URLSession.shared.data(for: req)
            return ((resp as! HTTPURLResponse).statusCode, try? JSONValue.parse(data))
        }
        let initReply = try await send("initialize", ["protocolVersion": "2024-11-05", "capabilities": [:], "clientInfo": ["name": "integration-test", "version": "1"]])
        expect(initReply.0 == 200, "real loopback listener initialized")
        let list = try await send("tools/list")
        expect(list.1?["result"]?["tools"]?.array?.count == 12, "12 tools via HTTP")
        let scene = try await send("tools/call", ["name": "scene_info", "arguments": [:]])
        let structured = scene.1!["result"]!["structuredContent"]!
        let text = scene.1!["result"]!["content"]!.array![0]["text"]!.string!
        let revision = structured["revision"]!
        expect(text.contains(revision.string!), "text-only clients receive revision")
        let added = try await send("tools/call", ["name": "add_box", "arguments": ["width": 40, "depth": 30, "height": 5, "expected_revision": revision]])
        expect(added.1?["result"]?["isError"]?.bool == false && model.document.features.count == 1, "geometry created over MCP")
        expect(abs(model.document.buildMesh().volume - 6000) < 1e-8, "known base volume")
        let stale = try await send("tools/call", ["name": "add_box", "arguments": ["width": 20, "depth": 20, "height": 5, "expected_revision": revision]])
        expect(stale.1?["result"]?["isError"]?.bool == true && model.document.features.count == 1, "second client stale write rejected")
        let undone = try await send("tools/call", ["name": "undo", "arguments": ["expected_revision": .string(model.designRevision)]])
        expect(undone.1?["result"]?["isError"]?.bool == false && model.document.features.isEmpty, "MCP undo restores document")
        let unauthorized = try await send("tools/list", token: "incorrect-test-token")
        expect(unauthorized.0 == 401, "token authentication")
        let badOrigin = try await send("tools/list", origin: "http://localhost.evil.example")
        expect(badOrigin.0 == 403, "origin hostname prefix refused")
        let goodOrigin = try await send("tools/list", origin: "http://127.0.0.1:1234")
        expect(goodOrigin.0 == 200, "exact local origin allowed")
        expect(HTTPRequest(Data("POST /mcp HTTP/1.1\r\nContent-Length: -1\r\n\r\n".utf8)) == nil, "negative length cannot crash parser")
        expect(HTTPRequest(Data("POST /mcp HTTP/1.1\r\nContent-Length: invalid\r\n\r\n".utf8)) == nil, "invalid length refused")
        let unknown = try await send("tools/call", ["name": "create_sheet_metal", "arguments": [:]])
        expect(unknown.1?["error"]?["code"]?.number == -32602, "unimplemented operation is explicit")
        print("PASS: \(checks) MCP HTTP integration checks (isolated scene; no user document changed)")
    }
}
