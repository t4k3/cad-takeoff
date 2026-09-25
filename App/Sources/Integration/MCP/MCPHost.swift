import Foundation
import Observation

/// Owns the in-app MCP server and its local transport; observable for the UI.
/// Writes a discovery file (URL + token) that the Claude stdio bridge reads.
@MainActor
@Observable
final class MCPHost {
    enum State: Equatable { case stopped, starting, running(url: String), failed(String) }

    struct Activity: Identifiable {
        let id = UUID()
        let date = Date()
        let text: String
        let isError: Bool
    }

    static let defaultPort: UInt16 = 51770

    private(set) var state: State = .stopped
    private(set) var token = MCPHost.makeToken()
    private(set) var clients: [String] = []
    private(set) var activity: [Activity] = []
    var enabled: Bool {
        didSet { UserDefaults.standard.set(enabled, forKey: "mcp.enabled"); enabled ? start() : stop() }
    }

    let server = MCPServer()
    @ObservationIgnored private var transport: LocalHTTPTransport?

    init() {
        enabled = UserDefaults.standard.object(forKey: "mcp.enabled") as? Bool ?? true
        server.onEvent = { [weak self] in self?.record($0) }
    }

    var url: String? { if case let .running(url) = state { url } else { nil } }

    /// Discovery file, inside the app container (sandbox):
    /// ~/Library/Containers/com.takeoff.fusiontakeoff/Data/Library/Application Support/FusionTakeoff/mcp.json
    static var discoveryURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("FusionTakeoff/mcp.json")
    }

    func attach(_ provider: CADToolProvider?) { server.provider = provider }

    func start() {
        guard enabled, transport == nil else { return }
        state = .starting
        let server = self.server
        let t = LocalHTTPTransport(token: token) { data, client in
            await server.handle(data, client: client)
        }
        transport = t
        t.start(preferredPort: Self.defaultPort) { [weak self] result in
            Task { @MainActor in self?.didStart(result) }
        }
    }

    func stop() {
        transport?.stop()
        transport = nil
        try? FileManager.default.removeItem(at: Self.discoveryURL)
        state = .stopped
    }

    /// New token: existing clients must be reconfigured.
    func regenerateToken() {
        token = Self.makeToken()
        stop(); start()
    }

    private func didStart(_ result: Result<UInt16, Error>) {
        switch result {
        case let .success(port):
            let url = "http://127.0.0.1:\(port)/mcp"
            state = .running(url: url)
            writeDiscovery(url: url)
            record(.listening(url: url))
        case let .failure(error):
            transport = nil
            state = .failed(error.localizedDescription)
            record(.stopped(reason: error.localizedDescription))
        }
    }

    private func writeDiscovery(url: String) {
        let file = Self.discoveryURL
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let json: JSONValue = ["url": .string(url), "token": .string(token), "pid": .number(Double(ProcessInfo.processInfo.processIdentifier))]
        try? Data(json.jsonString.utf8).write(to: file, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }

    private func record(_ e: MCPEvent) {
        let (text, isError): (String, Bool) = switch e {
        case let .connected(client, v):
            ("\(client) connesso (MCP \(v))", false)
        case let .toolCall(client, tool, err, summary, d):
            ("\(client) → \(tool) (\(Int(d * 1000)) ms): \(summary.prefix(120))", err)
        case let .listening(url): ("In ascolto su \(url)", false)
        case let .stopped(reason): ("Server fermo\(reason.map { ": \($0)" } ?? "")", reason != nil)
        }
        if case let .connected(client, _) = e, !clients.contains(client) { clients.append(client) }
        activity.insert(Activity(text: text, isError: isError), at: 0)
        if activity.count > 200 { activity.removeLast(activity.count - 200) }
    }

    private static func makeToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 24)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return bytes.map { String(format: "%02x", $0) }.joined()
    }
}
