// ftk-mcp — stdio ⇄ HTTP bridge between MCP clients that launch local servers
// (Claude Desktop, Claude Code stdio) and the MCP server inside CAD Takeoff.
//
// Reads newline-delimited JSON-RPC from stdin, POSTs each message to the app's local
// endpoint with its bearer token (from the app's discovery file) and writes the
// response on stdout. Logs go to stderr only. While the app is not running, the handshake
// (initialize, tools/list, ping) is answered from the app's saved handshake file; the app is
// launched only for a tool call (Ross 04/10: it started with every Claude session).
import AppKit
import Foundation

let bundleID = "com.takeoff.fusiontakeoff"
let appGroup = "9F8D583GBV.com.takeoff.fusiontakeoff"

/// Real home directory (inside the sandbox NSHomeDirectory() points at our own container).
let realHome = URL(fileURLWithPath: String(cString: getpwuid(getuid()).pointee.pw_dir))

/// Where the app publishes url+token: App Group container (TestFlight / signed builds),
/// then the app's own container (local builds without the App Group).
/// FTK_MCP_DISCOVERY_DIR (tests only): read mcp.json and mcp-handshake.json from there, never
/// launch the app.
let testDirectory = ProcessInfo.processInfo.environment["FTK_MCP_DISCOVERY_DIR"].map { URL(fileURLWithPath: $0) }
let discoveryCandidates: [URL] = testDirectory.map { [$0.appendingPathComponent("mcp.json")] } ?? [
    FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup)?.appendingPathComponent("mcp.json"),
    realHome.appendingPathComponent("Library/Group Containers/\(appGroup)/mcp.json"),
    realHome.appendingPathComponent("Library/Containers/\(bundleID)/Data/Library/Application Support/FusionTakeoff/mcp.json"),
].compactMap { $0 }

struct Endpoint { let url: URL; let token: String }

/// Server info and tool list the app saved when it last ran (mcp-handshake.json beside mcp.json).
func savedHandshake() -> [String: Any]? {
    for url in discoveryCandidates {
        let file = url.deletingLastPathComponent().appendingPathComponent("mcp-handshake.json")
        if let data = try? Data(contentsOf: file), let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           obj["tools"] is [Any] { return obj }
    }
    return nil
}

/// The handshake answered here when the app is not running (nil: forward, launching it if needed).
func localReply(_ message: Data) -> (handled: Bool, reply: Data?) {
    guard readEndpoint() == nil, let saved = savedHandshake(),
          let obj = try? JSONSerialization.jsonObject(with: message) as? [String: Any],
          let method = obj["method"] as? String else { return (false, nil) }
    let id = obj["id"]
    func reply(_ result: [String: Any]) -> (Bool, Data?) {
        guard let id else { return (true, nil) }
        return (true, try? JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": id, "result": result]))
    }
    switch method {
    case "initialize":
        let supported = saved["supportedVersions"] as? [String] ?? []
        let requested = (obj["params"] as? [String: Any])?["protocolVersion"] as? String
        let version = requested.flatMap { supported.contains($0) ? $0 : nil } ?? supported.first ?? "2025-06-18"
        return reply(["protocolVersion": version, "capabilities": ["tools": ["listChanged": false]],
                      "serverInfo": saved["serverInfo"] ?? [:], "instructions": saved["instructions"] ?? ""])
    case "tools/list": return reply(["tools": saved["tools"] ?? []])
    case "ping": return reply([:])
    default:
        if method.hasPrefix("notifications/") { return (true, nil) }
        return (false, nil)
    }
}

/// The app to launch: the one this bridge is inside (…/X.app/Contents/MacOS/ftk-mcp), not
/// whichever copy Launch Services knows about (an old build).
func appToLaunch() -> URL? {
    let own = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    if own.pathExtension == "app", Bundle(url: own)?.bundleIdentifier == bundleID { return own }
    return NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
}

func log(_ s: String) { FileHandle.standardError.write(Data("ftk-mcp: \(s)\n".utf8)) }

func readEndpoint() -> Endpoint? {
    var found: Data?
    for url in discoveryCandidates {
        do { found = try Data(contentsOf: url); break }
        catch { if ProcessInfo.processInfo.environment["FTK_MCP_DEBUG"] != nil { log("\(url.path): \(error.localizedDescription)") } }
    }
    guard let data = found,
          let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let u = obj["url"] as? String, let url = URL(string: u), let token = obj["token"] as? String else { return nil }
    // Stale file from a dead app? Inside the sandbox kill(pid, 0) may fail with EPERM for a
    // live process, so only ESRCH ("no such process") means the app is gone.
    if let pid = obj["pid"] as? Int, kill(pid_t(pid), 0) != 0, errno == ESRCH { return nil }
    return Endpoint(url: url, token: token)
}

/// Finds the running app's endpoint, launching the app and waiting up to ~20 s if needed.
func endpoint() async -> Endpoint? {
    if let e = readEndpoint() { return e }
    if testDirectory == nil, NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty,
       let appURL = appToLaunch() {
        log("avvio CAD Takeoff…")
        let config = NSWorkspace.OpenConfiguration()
        config.activates = false
        _ = try? await NSWorkspace.shared.openApplication(at: appURL, configuration: config)
    }
    for _ in 0..<(testDirectory == nil ? 40 : 1) {
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
            return errorReply(for: message, "CAD Takeoff non è in esecuzione o il server MCP è disattivato (barra di stato → MCP).")
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
            default: return errorReply(for: message, "CAD Takeoff ha risposto HTTP \(status).")
            }
        } catch {
            if attempt == 0 { try? await Task.sleep(for: .milliseconds(300)); continue }
            return errorReply(for: message, "Connessione a CAD Takeoff non riuscita: \(error.localizedDescription)")
        }
    }
    return errorReply(for: message, "Autorizzazione rifiutata da CAD Takeoff.")
}

let stdout = FileHandle.standardOutput
for try await line in FileHandle.standardInput.bytes.lines {
    let trimmed = line.trimmingCharacters(in: .whitespaces)
    guard !trimmed.isEmpty else { continue }
    let local = localReply(Data(trimmed.utf8))
    if let reply = local.handled ? local.reply : await forward(Data(trimmed.utf8)) {
        var out = reply.filter { $0 != 0x0A && $0 != 0x0D } // one message per line
        out.append(0x0A)
        stdout.write(out)
    }
}
