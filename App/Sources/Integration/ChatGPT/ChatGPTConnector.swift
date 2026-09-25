import Foundation

/// Setup commands for the external ChatGPT connection; no account mutation or key access.
/// Usable by Claude's connector UI without requiring the repository or Python on the user's Mac.
enum ChatGPTConnector {
    static let documentationURL = URL(string: "https://developers.openai.com/api/docs/guides/secure-mcp-tunnels")!
    static var bridgeURL: URL { Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/ftk-mcp") }
    static var isBridgeInstalled: Bool { FileManager.default.isExecutableFile(atPath: bridgeURL.path) }
    static let profile = "fusion-takeoff"
    static let doctorCommand = "tunnel-client doctor --profile fusion-takeoff --explain"
    static let runCommand = "tunnel-client run --profile fusion-takeoff"

    static func configureCommand(tunnelID: String, bridge: URL = bridgeURL) throws -> String {
        guard tunnelID.range(of: "^tunnel_[A-Za-z0-9_-]{8,128}$", options: .regularExpression) != nil else {
            throw SetupError.invalidTunnelID
        }
        // Two quoting layers: the terminal, then the command string parsed by tunnel-client.
        return ["tunnel-client", "init", "--sample", "sample_mcp_stdio_local", "--profile", profile,
                "--tunnel-id", tunnelID, "--mcp-command", quote(bridge.path)].map(quote).joined(separator: " ")
    }
    private static func quote(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }
    enum SetupError: LocalizedError {
        case invalidTunnelID
        var errorDescription: String? { "Inserisci il tunnel_id effettivo dalle impostazioni OpenAI." }
    }
}
