import AppKit
import Foundation

/// One-click registration of the bundled ftk-mcp bridge in Claude Desktop.
/// The app is sandboxed, so the user grants access to Claude's settings folder once
/// through an open panel; the existing configuration is backed up and merged, never replaced.
@MainActor
enum ClaudeDesktopSetup {
    static let serverName = "fusion-takeoff"
    private static let configuredKey = "connectors.claudeDesktop.bridgePath"

    /// Real home folder (inside the sandbox NSHomeDirectory() is the app container).
    static var realHome: URL { URL(fileURLWithPath: String(cString: getpwuid(getuid()).pointee.pw_dir)) }
    static var claudeFolder: URL { realHome.appendingPathComponent("Library/Application Support/Claude") }

    /// Bridge path recorded at the last successful setup (nil = never configured).
    static var configuredBridgePath: String? { UserDefaults.standard.string(forKey: configuredKey) }
    static var needsUpdate: Bool {
        guard let saved = configuredBridgePath else { return false }
        return saved != MCPHost.bridgeURL?.path
    }

    enum Outcome { case configured(backup: URL?), cancelled, failed(String) }

    static func connect() -> Outcome {
        guard let bridge = MCPHost.bridgeURL else { return .failed("Il bridge ftk-mcp non è presente nell'app.") }
        guard FileManager.default.fileExists(atPath: claudeFolder.path) else {
            return .failed("Claude Desktop non sembra installato (manca la cartella «Claude» in Application Support). Installalo da claude.ai/download e riprova.")
        }
        let panel = NSOpenPanel()
        panel.directoryURL = claudeFolder
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Consenti"
        panel.message = "Per collegare Claude Desktop, Fusion Takeoff deve aggiungere una voce alla configurazione di Claude. Seleziona la cartella «Claude» (già evidenziata) e premi Consenti."
        guard panel.runModal() == .OK, let folder = panel.url else { return .cancelled }
        guard folder.lastPathComponent == "Claude" else {
            return .failed("Seleziona proprio la cartella «Claude» in Libreria › Application Support.")
        }

        let file = folder.appendingPathComponent("claude_desktop_config.json")
        var config: [String: Any] = [:]
        var backup: URL?
        if let data = try? Data(contentsOf: file), !data.isEmpty {
            guard let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return .failed("claude_desktop_config.json non è JSON valido: correggilo o rinominalo e riprova.")
            }
            config = parsed
            let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "")
            let b = folder.appendingPathComponent("claude_desktop_config.backup-\(stamp).json")
            do { try data.write(to: b) ; backup = b } catch { return .failed("Backup non riuscito: \(error.localizedDescription)") }
        }
        var servers = config["mcpServers"] as? [String: Any] ?? [:]
        servers[serverName] = ["command": bridge.path]
        config["mcpServers"] = servers
        do {
            let data = try JSONSerialization.data(withJSONObject: config, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
            try data.write(to: file, options: .atomic)
        } catch {
            return .failed("Scrittura della configurazione non riuscita: \(error.localizedDescription)")
        }
        UserDefaults.standard.set(bridge.path, forKey: configuredKey)
        return .configured(backup: backup)
    }
}
