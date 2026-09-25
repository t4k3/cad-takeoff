// ftk-mcp — stdio ⇄ HTTP bridge between MCP clients that launch local servers
// (Claude Desktop, Claude Code stdio) and the MCP server inside Fusion Takeoff.
//
// Reads newline-delimited JSON-RPC from stdin, POSTs each message to the app's local
// endpoint with its bearer token (from the app's discovery file) and writes the
// response on stdout. Logs go to stderr only. Launches the app if it is not running.
import AppKit
import Foundation

let bundleID = "com.takeoff.fusiontakeoff"
let discovery = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/Containers/\(bundleID)/Data/Library/Application Support/FusionTakeoff/mcp.json")

struct Endpoint { let url: URL; let token: String }

func log(_ s: String) { FileHandle.standardError.write(Data("ftk-mcp: \(s)\n".utf8)) }

func readEndpoint() -> Endpoint? {
    guard let data = try? Data(contentsOf: discovery),
          let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let u = obj["url"] as? String, let url = URL(string: u), let token = obj["token"] as? String else { return nil }
    if let pid = obj["pid"] as? Int, kill(pid_t(pid), 0) != 0 { return nil } // stale file from a dead app
    return Endpoint(url: url, token: token)
}

/// Finds the running app's endpoint, launching the app and waiting up to ~20 s if needed.
func endpoint() async -> Endpoint? {
    if let e = readEndpoint() { return e }
    if NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty,
       let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
        log("avvio Fusion Takeoff…")
        let config = NSWorkspace.OpenConfiguration()
        config.activates = false
        _ = try? await NSWorkspace.shared.openApplication(at: appURL, configuration: config)
    }
    for _ in 0..<40 {
        try? await Task.sleep(for: .milliseconds(500))
        if let e = readEndpoint() { return e }
    }
    return nil
}

func errorReply(for message: Data, _ text: String) -> Data? {
    guard let obj = try? JSONSerialization.jsonObject(with: message) as? [String: Any], let id = obj["id"] else { return nil }
    let reply: [String: Any] = ["jsonrpc": "2.0", "id": id, "error": ["code": -32000, "message": text]]
    return try? JSONSerialization.data(withJSONObject: reply)
}

func forward(_ message: Data) async -> Data? {
    for attempt in 0..<2 {
        guard let e = await endpoint() else {
            return errorReply(for: message, "Fusion Takeoff non è in esecuzione o il server MCP è disattivato (barra di stato → MCP).")
        }
        var req = URLRequest(url: e.url)
        req.httpMethod = "POST"
        req.timeoutInterval = 300
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        req.setValue("Bearer \(e.token)", forHTTPHeaderField: "Authorization")
        req.setValue("ftk-mcp", forHTTPHeaderField: "User-Agent")
        req.httpBody = message
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
            switch status {
            case 200: return data
            case 202: return nil
            case 401 where attempt == 0: continue // token rotated: re-read discovery and retry once
            default: return errorReply(for: message, "Fusion Takeoff ha risposto HTTP \(status).")
            }
        } catch {
            if attempt == 0 { try? await Task.sleep(for: .milliseconds(300)); continue }
            return errorReply(for: message, "Connessione a Fusion Takeoff non riuscita: \(error.localizedDescription)")
        }
    }
    return errorReply(for: message, "Autorizzazione rifiutata da Fusion Takeoff.")
}

let stdout = FileHandle.standardOutput
for try await line in FileHandle.standardInput.bytes.lines {
    let trimmed = line.trimmingCharacters(in: .whitespaces)
    guard !trimmed.isEmpty else { continue }
    if let reply = await forward(Data(trimmed.utf8)) {
        var out = reply.filter { $0 != 0x0A && $0 != 0x0D } // one message per line
        out.append(0x0A)
        stdout.write(out)
    }
}
