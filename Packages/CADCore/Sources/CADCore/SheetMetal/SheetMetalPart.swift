import Foundation

public enum SheetMetalError: Error, LocalizedError, Equatable, Sendable {
    case invalidParameter(String)
    case unsupportedHistory(String)
    case staleFlatPattern

    public var errorDescription: String? {
        switch self {
        case .invalidParameter(let detail): "Lamiera: \(detail)"
        case .unsupportedHistory(let detail): "Storico lamiera non supportato: \(detail)"
        case .staleFlatPattern: "Sviluppo obsoleto: rigenerarlo dalla parte corrente prima di esportare."
        }
    }
}

/// Explicit manufacturing inputs. No material name implies a calibrated K-factor.
public struct SheetMetalRule: Codable, Equatable, Sendable {
    public let id: UUID
    public let revision: Int
    public let name: String
    public let thickness: Double
    public let insideRadius: Double
    public let kFactor: Double

    public init(id: UUID = UUID(), revision: Int = 1, name: String,
                thickness: Double, insideRadius: Double, kFactor: Double) throws {
        self.id = id; self.revision = revision; self.name = name
        self.thickness = thickness; self.insideRadius = insideRadius; self.kFactor = kFactor
        try validate()
    }

    public func validate() throws {
        try SheetMetalLimits.dimension(thickness, "spessore")
        try SheetMetalLimits.dimension(insideRadius, "raggio interno")
        guard kFactor.isFinite && (0...1).contains(kFactor), revision > 0,
              !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, name.count <= 160 else {
            throw SheetMetalError.invalidParameter("regola: nome richiesto, revisione positiva, K-factor tra 0 e 1")
        }
    }

    public func revised(thickness: Double? = nil, insideRadius: Double? = nil, kFactor: Double? = nil) throws -> Self {
        guard revision < Int.max else { throw SheetMetalError.invalidParameter("revisione regola esaurita") }
        return try Self(id: id, revision: revision + 1, name: name,
                        thickness: thickness ?? self.thickness, insideRadius: insideRadius ?? self.insideRadius,
                        kFactor: kFactor ?? self.kFactor)
    }
}

public enum SheetMetalBendDirection: String, Codable, Sendable { case up, down }

public struct SheetMetalBase: Codable, Equatable, Sendable {
    public let width: Double
    /// Straight tangent length. The bend starts at x = 0, the base extends to -length.
    public let length: Double
    public init(width: Double, length: Double) { self.width = width; self.length = length }
}

public struct SheetMetalFlange: Codable, Equatable, Sendable {
    /// Straight length measured FROM the end tangent of the bend, not an outside dimension.
    public let length: Double
    /// Rotation from flat, in degrees (not the included interior angle).
    public let angleDegrees: Double
    public let direction: SheetMetalBendDirection
    public let bendSegments: Int
    public init(length: Double, angleDegrees: Double, direction: SheetMetalBendDirection = .up, bendSegments: Int = 24) {
        self.length = length; self.angleDegrees = angleDegrees; self.direction = direction; self.bendSegments = bendSegments
    }
}

public struct SheetMetalOperation: Codable, Equatable, Identifiable, Sendable {
    public enum Kind: Codable, Equatable, Sendable {
        case base(SheetMetalBase)
        case edgeFlange(SheetMetalFlange)
    }
    public let id: UUID
    public let kind: Kind
    public let isSuppressed: Bool
    init(id: UUID = UUID(), kind: Kind, isSuppressed: Bool = false) {
        self.id = id; self.kind = kind; self.isSuppressed = isSuppressed
    }
}

/// Small, replayable sheet-metal document. Deliberately separate from CADDocument v1:
/// integration into the global feature history and the app UI is a subsequent step.
public struct SheetMetalPart: Codable, Equatable, Identifiable, Sendable {
    public static let formatVersion = 1
    public let version: Int
    public let id: UUID
    public let name: String
    public private(set) var revision: Int
    public private(set) var rule: SheetMetalRule
    public private(set) var operations: [SheetMetalOperation]

    public init(id: UUID = UUID(), name: String, rule: SheetMetalRule, width: Double, baseLength: Double) throws {
        self.version = Self.formatVersion; self.id = id; self.name = name
        self.revision = 1; self.rule = rule
        operations = [.init(kind: .base(.init(width: width, length: baseLength)))]
        _ = try validatedParameters()
    }

    public func addingFlange(_ flange: SheetMetalFlange) throws -> Self {
        _ = try validatedParameters()
        guard operations.count == 1 else { throw SheetMetalError.unsupportedHistory("una sola flangia intera nella base v1") }
        var next = self
        next.operations.append(.init(kind: .edgeFlange(flange)))
        return try next.changed()
    }

    public func editingBase(width: Double, length: Double) throws -> Self {
        _ = try validatedParameters()
        var next = self
        next.operations[0] = .init(id: operations[0].id, kind: .base(.init(width: width, length: length)))
        return try next.changed()
    }

    public func editingFlange(_ flange: SheetMetalFlange) throws -> Self {
        _ = try validatedParameters()
        guard operations.count == 2 else { throw SheetMetalError.unsupportedHistory("nessuna flangia da modificare") }
        var next = self
        next.operations[1] = .init(id: operations[1].id, kind: .edgeFlange(flange), isSuppressed: operations[1].isSuppressed)
        return try next.changed()
    }

    public func suppressingFlange(_ suppressed: Bool) throws -> Self {
        _ = try validatedParameters()
        guard operations.count == 2 else { throw SheetMetalError.unsupportedHistory("nessuna flangia da sopprimere") }
        if operations[1].isSuppressed == suppressed { return self }
        var next = self
        next.operations[1] = .init(id: operations[1].id, kind: operations[1].kind, isSuppressed: suppressed)
        return try next.changed()
    }

    public func replacingRule(_ rule: SheetMetalRule) throws -> Self {
        _ = try validatedParameters()
        if rule == self.rule { return self }
        if rule.id == self.rule.id && rule.revision <= self.rule.revision {
            throw SheetMetalError.invalidParameter("una modifica della stessa regola richiede una revisione maggiore")
        }
        var next = self; next.rule = rule
        return try next.changed()
    }

    /// Replay a saved prefix. Keeps operation IDs; does not mutate or truncate the original.
    public func rolledBack(through operationID: UUID) throws -> Self {
        _ = try validatedParameters()
        guard let index = operations.firstIndex(where: { $0.id == operationID }) else {
            throw SheetMetalError.unsupportedHistory("operazione non trovata")
        }
        if index == operations.count - 1 { return self }
        var next = self; next.operations = Array(operations.prefix(index + 1))
        return try next.changed()
    }

    public func encoded() throws -> Data {
        _ = try validatedParameters()
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(self)
    }

    public static func decode(_ data: Data) throws -> Self {
        guard data.count <= 1_048_576 else { throw SheetMetalError.invalidParameter("documento lamiera oltre 1 MiB") }
        let part = try JSONDecoder().decode(Self.self, from: data)
        _ = try part.validatedParameters()
        return part
    }

    private func changed() throws -> Self {
        guard revision < Int.max else { throw SheetMetalError.invalidParameter("revisione parte esaurita") }
        var next = self; next.revision += 1
        _ = try next.validatedParameters()
        return next
    }

    func validatedParameters() throws -> (base: SheetMetalBase, flange: SheetMetalFlange?) {
        try rule.validate()
        guard version == Self.formatVersion, revision > 0,
              !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, name.count <= 160,
              (1...2).contains(operations.count), Set(operations.map(\.id)).count == operations.count,
              case .base(let base) = operations[0].kind, !operations[0].isSuppressed else {
            throw SheetMetalError.unsupportedHistory("versione, nome, ID o flangia base non validi")
        }
        try SheetMetalLimits.dimension(base.width, "larghezza")
        try SheetMetalLimits.dimension(base.length, "lunghezza base")
        var flange: SheetMetalFlange?
        if operations.count == 2 {
            guard case .edgeFlange(let value) = operations[1].kind else {
                throw SheetMetalError.unsupportedHistory("attesa una flangia dopo la base")
            }
            try SheetMetalLimits.dimension(value.length, "lunghezza flangia")
            guard value.angleDegrees.isFinite, (5...135).contains(value.angleDegrees), (2...60).contains(value.bendSegments) else {
                throw SheetMetalError.invalidParameter("piega v1: 5–135 gradi, 2–60 segmenti")
            }
            if !operations[1].isSuppressed { flange = value }
        }
        return (base, flange)
    }
}

enum SheetMetalLimits {
    static func dimension(_ value: Double, _ name: String) throws {
        guard value.isFinite, (0.01...10_000).contains(value) else {
            throw SheetMetalError.invalidParameter("\(name): richiesti 0,01–10000 mm")
        }
    }
}
