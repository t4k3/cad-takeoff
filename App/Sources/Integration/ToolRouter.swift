import Foundation

/// The one tool provider MCP clients and the in-app chat see (T48 + T100): the CAD design's tools
/// and CIRCUITI's `circuit_*` tools, each answered by its own model with its own revision token.
@MainActor
final class ToolRouter: CADToolProvider {
    private let cad: CADToolProvider
    private let circuits: CADToolProvider

    init(cad: CADToolProvider, circuits: CADToolProvider) {
        self.cad = cad; self.circuits = circuits
    }

    var tools: [ToolSpec] { cad.tools + circuits.tools }

    func call(_ name: String, arguments: JSONValue) async -> ToolResult {
        await provider(for: name).call(name, arguments: arguments)
    }

    /// The CAD design's revision (the contract's historic meaning).
    var designRevision: String { cad.designRevision }

    func expectedRevision(for tool: String) -> String { provider(for: tool).designRevision }

    private func provider(for tool: String) -> CADToolProvider {
        tool.hasPrefix("circuit_") ? circuits : cad
    }
}
