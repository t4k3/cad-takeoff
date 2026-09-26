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
    public var color: PartColor

    public init(id: UUID = UUID(), name: String, kind: Kind, position: Vec3 = .zero, isVisible: Bool = true, color: PartColor = .defaultColor) {
        self.id = id; self.name = name; self.kind = kind; self.position = position; self.isVisible = isVisible
        self.color = color
    }

    private enum CodingKeys: String, CodingKey { case id, name, kind, position, isVisible, color }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        kind = try c.decode(Kind.self, forKey: .kind)
        position = try c.decode(Vec3.self, forKey: .position)
        isVisible = try c.decode(Bool.self, forKey: .isVisible)
        // Existing v1 documents have no colour field. Invalid supplied colours still fail decoding.
        color = try c.decodeIfPresent(PartColor.self, forKey: .color) ?? .defaultColor
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
    /// Sketches and which feature each sketch shape produced (T77). Optional keys:
    /// documents written before sketches existed decode with empty arrays.
    public var sketches: [Sketch] = []
    public var sketchLinks: [SketchLink] = []

    public init(features: [Feature] = [], sketches: [Sketch] = [], sketchLinks: [SketchLink] = []) {
        self.features = features; self.sketches = sketches; self.sketchLinks = sketchLinks
    }

    private enum CodingKeys: String, CodingKey { case version, features, sketches, sketchLinks }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? CADDocument.formatVersion
        features = try c.decode([Feature].self, forKey: .features)
        sketches = try c.decodeIfPresent([Sketch].self, forKey: .sketches) ?? []
        sketchLinks = try c.decodeIfPresent([SketchLink].self, forKey: .sketchLinks) ?? []
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(version, forKey: .version)
        try c.encode(features, forKey: .features)
        if !sketches.isEmpty { try c.encode(sketches, forKey: .sketches) }
        if !sketchLinks.isEmpty { try c.encode(sketchLinks, forKey: .sketchLinks) }
    }

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
