import Foundation

// Shared contract between the CAD tool layer (Model, Codex — T48) and its consumers:
// the in-app MCP server (T49), the Claude/ChatGPT connectors (T50/T51) and the
// in-app assistant chat (T52/T53). Changing it requires a DECISIONE entry in COLLAB.md.

/// Minimal JSON value, enough for tool schemas, arguments and results.
enum JSONValue: Codable, Sendable, Equatable, Hashable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let b = try? c.decode(Bool.self) { self = .bool(b) }
        else if let n = try? c.decode(Double.self) { self = .number(n) }
        else if let s = try? c.decode(String.self) { self = .string(s) }
        else if let a = try? c.decode([JSONValue].self) { self = .array(a) }
        else { self = .object(try c.decode([String: JSONValue].self)) }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case let .bool(b): try c.encode(b)
        case let .number(n):
            if n.rounded() == n, abs(n) < 1e15 { try c.encode(Int64(n)) } else { try c.encode(n) }
        case let .string(s): try c.encode(s)
        case let .array(a): try c.encode(a)
        case let .object(o): try c.encode(o)
        }
    }

    subscript(key: String) -> JSONValue? { if case let .object(o) = self { o[key] } else { nil } }
    var string: String? { if case let .string(s) = self { s } else { nil } }
    var number: Double? { if case let .number(n) = self { n } else { nil } }
    var bool: Bool? { if case let .bool(b) = self { b } else { nil } }
    var array: [JSONValue]? { if case let .array(a) = self { a } else { nil } }

    /// Compact JSON text (sorted keys, stable for logs and tests).
    var jsonString: String {
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return (try? enc.encode(self)).flatMap { String(data: $0, encoding: .utf8) } ?? "null"
    }

    static func parse(_ data: Data) throws -> JSONValue { try JSONDecoder().decode(JSONValue.self, from: data) }
}

extension JSONValue: ExpressibleByStringLiteral, ExpressibleByFloatLiteral, ExpressibleByIntegerLiteral,
    ExpressibleByBooleanLiteral, ExpressibleByArrayLiteral, ExpressibleByDictionaryLiteral {
    init(stringLiteral v: String) { self = .string(v) }
    init(floatLiteral v: Double) { self = .number(v) }
    init(integerLiteral v: Int) { self = .number(Double(v)) }
    init(booleanLiteral v: Bool) { self = .bool(v) }
    init(arrayLiteral e: JSONValue...) { self = .array(e) }
    init(dictionaryLiteral e: (String, JSONValue)...) { self = .object(Dictionary(uniqueKeysWithValues: e)) }
}

/// Description of one CAD tool, as exposed to MCP clients and LLM providers.
struct ToolSpec: Sendable, Equatable {
    /// snake_case, stable: clients cache it.
    let name: String
    /// Short human title (Italian UI).
    let title: String
    /// What it does, units (mm, Z up), examples. Written for the model.
    let description: String
    /// JSON Schema (draft 2020-12 subset) of the arguments object.
    let inputSchema: JSONValue
    /// True if the tool never changes the design.
    let isReadOnly: Bool
}

/// Outcome of a tool call. Errors are values, never thrown, so every consumer
/// can report them back to the model.
struct ToolResult: Sendable, Equatable {
    var text: String
    var structured: JSONValue?
    var isError: Bool
    /// Features created or modified, so the UI can highlight / undo them.
    var changedFeatures: [UUID]

    init(text: String, structured: JSONValue? = nil, isError: Bool = false, changedFeatures: [UUID] = []) {
        self.text = text; self.structured = structured; self.isError = isError; self.changedFeatures = changedFeatures
    }

    static func error(_ message: String) -> ToolResult { ToolResult(text: message, isError: true) }
}

/// Implemented by the Model (T48). Calls run on the main actor, validated,
/// each modifying call is one undo step named "Assistente: <title>".
@MainActor
protocol CADToolProvider: AnyObject {
    var tools: [ToolSpec] { get }
    func call(_ name: String, arguments: JSONValue) async -> ToolResult
    /// The design's current revision (what `expected_revision` must match).
    var designRevision: String { get }
    /// What `expected_revision` must match for `tool` (a provider serving several documents —
    /// CAD and CIRCUITI — answers per tool; T100).
    func expectedRevision(for tool: String) -> String
}

extension CADToolProvider {
    func expectedRevision(for tool: String) -> String { designRevision }
}
