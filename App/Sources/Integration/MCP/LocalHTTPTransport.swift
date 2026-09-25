import Foundation
import Network

/// MCP "Streamable HTTP" transport bound to 127.0.0.1 only. JSON responses (no SSE
/// stream is needed: the server never initiates requests). Every POST must carry
/// `Authorization: Bearer <token>`; browsers are rejected through the Origin check.
final class LocalHTTPTransport: @unchecked Sendable {
    typealias Handler = @Sendable (Data, String) async -> Data?

    let token: String
    private(set) var port: UInt16 = 0
    private var listener: NWListener?
    private let queue = DispatchQueue(label: "ftk.mcp.http")
    private let handler: Handler

    init(token: String, handler: @escaping Handler) {
        self.token = token
        self.handler = handler
    }

    /// Starts listening on `preferredPort` (falls back to a random port). Calls back with the bound port.
    func start(preferredPort: UInt16, onReady: @escaping @Sendable (Result<UInt16, Error>) -> Void) {
        func make(_ port: NWEndpoint.Port) throws -> NWListener {
            let params = NWParameters.tcp
            params.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: port)
            params.allowLocalEndpointReuse = true
            return try NWListener(using: params)
        }
        do {
            let l = try make(NWEndpoint.Port(rawValue: preferredPort) ?? .any)
            configure(l, fallback: preferredPort != 0, onReady: onReady)
        } catch {
            onReady(.failure(error))
        }
    }

    private func configure(_ l: NWListener, fallback: Bool, onReady: @escaping @Sendable (Result<UInt16, Error>) -> Void) {
        listener = l
        l.newConnectionHandler = { [weak self] c in self?.accept(c) }
        l.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.port = l.port?.rawValue ?? 0
                onReady(.success(self.port))
            case let .failed(error):
                l.cancel()
                if fallback { self.start(preferredPort: 0, onReady: onReady) } else { onReady(.failure(error)) }
            default: break
            }
        }
        l.start(queue: queue)
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }

    // MARK: HTTP/1.1 (minimal, one request per connection is fine for MCP clients)

    private func accept(_ c: NWConnection) {
        c.start(queue: queue)
        receive(c, buffer: Data())
    }

    private func receive(_ c: NWConnection, buffer: Data) {
        c.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] data, _, done, error in
            guard let self else { return }
            var buf = buffer
            if let data { buf.append(data) }
            if let request = HTTPRequest(buf) {
                self.respond(to: request, on: c)
            } else if done || error != nil || buf.count > 8 << 20 {
                c.cancel()
            } else {
                self.receive(c, buffer: buf)
            }
        }
    }

    private func respond(to r: HTTPRequest, on c: NWConnection) {
        // DNS-rebinding protection: only accept requests without Origin or from localhost.
        if let origin = r.headers["origin"] {
            guard let url = URLComponents(string: origin), url.scheme == "http",
                  url.host == "localhost" || url.host == "127.0.0.1",
                  url.user == nil, url.password == nil,
                  url.path.isEmpty, url.query == nil, url.fragment == nil else {
                return send(c, status: "403 Forbidden", body: Data("origin not allowed".utf8))
            }
        }
        guard r.path.hasPrefix("/mcp") else { return send(c, status: "404 Not Found", body: Data()) }
        guard r.headers["authorization"] == "Bearer \(token)" else {
            return send(c, status: "401 Unauthorized", body: Data("missing or wrong token".utf8),
                        extra: ["WWW-Authenticate": "Bearer"])
        }
        switch r.method {
        case "POST":
            let client = r.headers["user-agent"] ?? "client"
            let handler = self.handler
            Task {
                if let out = await handler(r.body, client) {
                    self.send(c, status: "200 OK", body: out, contentType: "application/json")
                } else {
                    self.send(c, status: "202 Accepted", body: Data())
                }
            }
        case "GET":
            // No server-initiated stream.
            send(c, status: "405 Method Not Allowed", body: Data(), extra: ["Allow": "POST, DELETE"])
        case "DELETE":
            send(c, status: "200 OK", body: Data())
        default:
            send(c, status: "405 Method Not Allowed", body: Data())
        }
    }

    private func send(_ c: NWConnection, status: String, body: Data, contentType: String = "text/plain",
                      extra: [String: String] = [:]) {
        var head = "HTTP/1.1 \(status)\r\nContent-Type: \(contentType)\r\nContent-Length: \(body.count)\r\nConnection: close\r\n"
        for (k, v) in extra { head += "\(k): \(v)\r\n" }
        head += "\r\n"
        var out = Data(head.utf8)
        out.append(body)
        c.send(content: out, completion: .contentProcessed { _ in c.cancel() })
    }
}

/// Parses a complete HTTP/1.1 request; nil while more bytes are needed.
struct HTTPRequest {
    let method: String
    let path: String
    let headers: [String: String]
    let body: Data

    init?(_ data: Data) {
        guard let range = data.range(of: Data("\r\n\r\n".utf8)),
              let head = String(data: data[..<range.lowerBound], encoding: .utf8) else { return nil }
        let lines = head.components(separatedBy: "\r\n")
        let parts = lines.first?.split(separator: " ") ?? []
        guard parts.count >= 2 else { return nil }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        guard let length = Int(headers["content-length"] ?? "0"), (0...(8 << 20)).contains(length) else { return nil }
        let bodyStart = range.upperBound
        guard data.count - bodyStart >= length else { return nil }
        method = String(parts[0]); path = String(parts[1]); self.headers = headers
        body = data.subdata(in: bodyStart..<(bodyStart + length))
    }
}
