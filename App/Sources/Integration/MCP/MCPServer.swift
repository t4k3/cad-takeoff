import Foundation

/// Transport-agnostic MCP server (JSON-RPC 2.0): lifecycle, ping, tools/list, tools/call.
/// Every transport (local HTTP, stdio bridge, ChatGPT remote) feeds raw messages here.
@MainActor
final class MCPServer {
    static let supportedVersions = ["2025-11-25", "2025-06-18", "2025-03-26", "2024-11-05"]

    weak var provider: CADToolProvider?
    /// Observer for the UI activity log.
    var onEvent: (MCPEvent) -> Void = { _ in }

    let serverName = "fusion-takeoff"
    let serverVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1.0"

    static let instructions = """
    CAD Takeoff è un CAD parametrico per macOS orientato alla stampa 3D.
    Unità: millimetri. Asse Z verso l'alto; il piano XY è il piatto di stampa.
    Prima di modificare, leggi lo stato con gli strumenti di sola lettura (es. list_features, scene_info).
    Ogni strumento che modifica il design crea un passo annullabile nell'app.
    Gli strumenti circuit_* lavorano sul circuito aperto in CIRCUITI (mm, scheda vista dall'alto) con un
    proprio token di revisione: leggi con circuit_info, modifica con circuit_preview e poi circuit_apply
    dello stesso preview_id.
    """

    /// Handles one JSON-RPC message (or batch). Returns the response bytes, or nil for notifications.
    func handle(_ data: Data, client: String) async -> Data? {
        guard let message = try? JSONValue.parse(data) else {
            return encode(errorResponse(id: .null, code: -32700, message: "Parse error"))
        }
        if case let .array(batch) = message {
            var out: [JSONValue] = []
            for m in batch { if let r = await handleOne(m, client: client) { out.append(r) } }
            return out.isEmpty ? nil : encode(.array(out))
        }
        return await handleOne(message, client: client).map(encode)
    }

    private func handleOne(_ m: JSONValue, client: String) async -> JSONValue? {
        guard let method = m["method"]?.string else {
            // A response from the client (we never send requests): ignore.
            return nil
        }
        let id = m["id"]
        let params = m["params"] ?? .object([:])
        let isNotification = id == nil

        switch method {
        case "initialize":
            let requested = params["protocolVersion"]?.string ?? Self.supportedVersions[0]
            let version = Self.supportedVersions.contains(requested) ? requested : Self.supportedVersions[0]
            let info = params["clientInfo"]?["name"]?.string ?? client
            onEvent(.connected(client: info, protocolVersion: version))
            return result(id, [
                "protocolVersion": .string(version),
                "capabilities": ["tools": ["listChanged": false]],
                "serverInfo": ["name": .string(serverName), "title": "CAD Takeoff", "version": .string(serverVersion)],
                "instructions": .string(Self.instructions),
            ])
        case "notifications/initialized", "notifications/cancelled":
            return nil
        case "ping":
            return result(id, [:])
        case "tools/list":
            return result(id, ["tools": toolList])
        case "tools/call":
            guard let name = params["name"]?.string else {
                return errorResponse(id: id ?? .null, code: -32602, message: "Missing tool name")
            }
            guard let provider, provider.tools.contains(where: { $0.name == name }) else {
                return errorResponse(id: id ?? .null, code: -32602, message: "Unknown tool: \(name)")
            }
            let args = params["arguments"] ?? .object([:])
            let started = Date()
            let r = await provider.call(name, arguments: args)
            onEvent(.toolCall(client: client, tool: name, isError: r.isError, summary: r.text,
                              duration: Date().timeIntervalSince(started)))
            var payload: [String: JSONValue] = [
                "content": [["type": "text", "text": .string(r.text)]],
                "isError": .bool(r.isError),
            ]
            if let s = r.structured {
                payload["structuredContent"] = s
                // Older MCP clients consume text only: retain IDs and revision tokens there too.
                payload["content"] = [["type": "text", "text": .string(r.text + "\n" + s.jsonString)]]
            }
            return result(id, .object(payload))
        default:
            return isNotification ? nil : errorResponse(id: id ?? .null, code: -32601, message: "Method not found: \(method)")
        }
    }

    /// The tools as tools/list gives them.
    var toolList: JSONValue {
        .array((provider?.tools ?? []).map { t -> JSONValue in
            [
                "name": .string(t.name),
                "title": .string(t.title),
                "description": .string(t.description),
                "inputSchema": t.inputSchema,
                "annotations": ["title": .string(t.title), "readOnlyHint": .bool(t.isReadOnly),
                                "destructiveHint": .bool(false), "openWorldHint": false],
            ]
        })
    }

    /// What the stdio bridge needs to answer a client's handshake (initialize, tools/list) while
    /// the app is not running, without launching it: the app starts only for a tool call.
    var handshake: JSONValue {
        ["supportedVersions": .array(Self.supportedVersions.map(JSONValue.string)),
         "serverInfo": ["name": .string(serverName), "title": "CAD Takeoff", "version": .string(serverVersion)],
         "instructions": .string(Self.instructions),
         "tools": toolList]
    }

    private func result(_ id: JSONValue?, _ result: JSONValue) -> JSONValue? {
        guard let id else { return nil }
        return ["jsonrpc": "2.0", "id": id, "result": result]
    }

    private func errorResponse(id: JSONValue, code: Int, message: String) -> JSONValue {
        ["jsonrpc": "2.0", "id": id, "error": ["code": .number(Double(code)), "message": .string(message)]]
    }

    private func encode(_ v: JSONValue) -> Data { Data(v.jsonString.utf8) }
}

enum MCPEvent: Sendable {
    case connected(client: String, protocolVersion: String)
    case toolCall(client: String, tool: String, isError: Bool, summary: String, duration: TimeInterval)
    case listening(url: String)
    case stopped(reason: String?)
}
