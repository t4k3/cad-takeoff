import Foundation

public enum ProfileKind: String, Codable, CaseIterable, Sendable {
    case rectangle, circle
}

/// Persistent dimensions are millimetres. Z is the extrusion axis.
public struct CADModel: Codable, Equatable, Sendable {
    public var schemaVersion = 1
    public var unit = "mm"
    public var profile: ProfileKind = .rectangle
    public var width = 40.0
    public var depth = 30.0
    public var height = 20.0
    public var segments = 96

    public init() {}

    public func validate() throws {
        guard schemaVersion == 1 else { throw CADError.invalid("Versione documento non supportata: \(schemaVersion).") }
        guard unit == "mm" else { throw CADError.invalid("Il documento deve usare millimetri.") }
        for value in [width, depth, height] {
            guard value.isFinite && (0.1...1000).contains(value) else {
                throw CADError.invalid("Le dimensioni devono essere comprese tra 0,1 e 1000 mm.")
            }
        }
        guard (16...256).contains(segments) else {
            throw CADError.invalid("La risoluzione deve essere tra 16 e 256 segmenti.")
        }
    }

    public static func decode(_ data: Data) throws -> CADModel {
        let model = try JSONDecoder().decode(CADModel.self, from: data)
        try model.validate()
        return model
    }

    public func encoded() throws -> Data {
        try validate()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(self)
    }
}

public enum CADError: LocalizedError {
    case invalid(String)
    public var errorDescription: String? {
        switch self { case .invalid(let message): return message }
    }
}

