import Foundation

/// A parametric feature in the timeline. The mesh is always regenerated from parameters.
public struct Feature: Identifiable, Codable, Sendable, Equatable {
    public enum Kind: Codable, Sendable, Equatable {
        case box(width: Double, depth: Double, height: Double)
        case cylinder(radius: Double, height: Double)
        case extrude(profile: Profile2D, height: Double)
    }

    public var id: UUID
    public var name: String
    public var kind: Kind
    public var position: Vec3
    public var isVisible: Bool

    public init(id: UUID = UUID(), name: String, kind: Kind, position: Vec3 = .zero, isVisible: Bool = true) {
        self.id = id; self.name = name; self.kind = kind; self.position = position; self.isVisible = isVisible
    }

    public func buildMesh() -> Mesh {
        let local: Mesh
        switch kind {
        case let .box(w, d, h): local = Primitives.box(width: w, depth: d, height: h)
        case let .cylinder(r, h): local = Primitives.cylinder(radius: r, height: h)
        case let .extrude(profile, h): local = Operations.extrude(profile, height: h)
        }
        return local.translated(by: position)
    }
}

/// The design: an ordered feature timeline. Serialized as JSON (`.ftk`).
public struct CADDocument: Codable, Sendable, Equatable {
    public static let formatVersion = 1

    public var version: Int = CADDocument.formatVersion
    public var features: [Feature] = []

    public init(features: [Feature] = []) { self.features = features }

    /// Combined printable mesh of visible features (concatenation; boolean union is task T11).
    public func buildMesh() -> Mesh {
        Mesh.merged(features.filter(\.isVisible).map { $0.buildMesh() })
    }

    public func encoded() throws -> Data {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try enc.encode(self)
    }

    public static func decode(_ data: Data) throws -> CADDocument {
        try JSONDecoder().decode(CADDocument.self, from: data)
    }
}
