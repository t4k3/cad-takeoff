import Foundation
import CADCore

@main struct MCPIntegrationTests {
    @MainActor static func main() async throws {
        let model = DesignModel(); model.newDesign()
        // The app's provider: CAD tools and CIRCUITI's circuit_* tools behind one router (T100).
        let circuits = CircuitModel()
        try circuits.newCircuit(name: "MCP")
        let router = ToolRouter(cad: model, circuits: circuits)
        let server = MCPServer(); server.provider = router
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
        let names = list.1?["result"]?["tools"]?.array?.compactMap { $0["name"]?.string } ?? []
        expect(names.count == 37 && names.filter { $0.hasPrefix("circuit_") }.count == 10, "27 CAD + 10 circuit tools via HTTP (\(names.count))")
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
        _ = try await send("tools/call", ["name": "redo", "arguments": ["expected_revision": .string(model.designRevision)]])
        let colour = try await send("tools/call", ["name": "set_color", "arguments": ["feature_id": .string(model.document.features[0].id.uuidString), "color": "#1E88E5", "expected_revision": .string(model.designRevision)]])
        expect(colour.1?["result"]?["isError"]?.bool == false && model.document.features[0].color.hex == "#1E88E5", "colour via HTTP MCP")
        let threeMF = try await send("tools/call", ["name": "export_3mf", "arguments": [:]])
        let archive = Data(base64Encoded: threeMF.1?["result"]?["structuredContent"]?["data"]?.string ?? "") ?? Data()
        expect(archive.prefix(4) == Data([0x50, 0x4B, 0x03, 0x04]) && String(decoding: archive, as: UTF8.self).contains("#1E88E5FF"), "coloured 3MF round trip over real HTTP")
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
        // CIRCUITI over the same transport: its own token, preview then apply of the same ID.
        func call(_ name: String, _ args: JSONValue) async throws -> JSONValue {
            try await send("tools/call", ["name": .string(name), "arguments": args]).1?["result"] ?? .null
        }
        let info = try await call("circuit_info", [:])
        let circuitToken = info["structuredContent"]?["revision"]?.string ?? ""
        expect(info["isError"]?.bool == false && !circuitToken.isEmpty && circuitToken != model.designRevision, "circuit_info: own revision token")
        expect(router.expectedRevision(for: "circuit_preview") == circuits.designRevision && router.expectedRevision(for: "add_box") == model.designRevision
               && router.designRevision == model.designRevision, "router: CAD and circuit tokens per tool")
        let cadWithCircuitToken = try await call("add_box", ["width": 5, "depth": 5, "height": 5, "expected_revision": .string(circuitToken)])
        expect(cadWithCircuitToken["isError"]?.bool == true, "circuit token refused by a CAD write")
        let library = try await call("circuit_library", [:])
        let device = library["structuredContent"]?["devices"]?.array?.first?["device"]?.string ?? ""
        let before = circuits.document
        let preview = try await call("circuit_preview", ["action": "add_component", "device": .string(device), "x": 10, "y": 10, "expected_revision": .string(circuitToken)])
        let previewID = preview["structuredContent"]?["preview_id"]?.string ?? ""
        expect(preview["isError"]?.bool == false && !previewID.isEmpty && circuits.document == before, "circuit_preview over HTTP: nothing changed")
        let applied = try await call("circuit_apply", ["preview_id": .string(previewID), "expected_revision": .string(circuitToken)])
        expect(applied["isError"]?.bool == false && circuits.design?.components.count == 1 && circuits.document!.revision == before!.revision + 1,
               "circuit_apply over HTTP: one component, one step")
        let replay = try await call("circuit_apply", ["preview_id": .string(previewID), "expected_revision": .string(circuitToken)])
        expect(replay["isError"]?.bool == true && circuits.design?.components.count == 1, "replayed confirmation refused")
        let undoCircuit = try await call("circuit_undo", ["expected_revision": .string(circuits.designRevision)])
        expect(undoCircuit["isError"]?.bool == false && circuits.design == before?.design, "circuit_undo over HTTP")
        expect(model.document.features.count == 1, "CAD design untouched by circuit tools")
        print("PASS: \(checks) MCP HTTP integration checks (isolated scene; no user document changed)")
    }
}
