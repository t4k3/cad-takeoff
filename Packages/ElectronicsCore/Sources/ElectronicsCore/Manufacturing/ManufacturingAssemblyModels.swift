import Foundation

/// Saved visual assembly assumptions. Nil thickness means the viewer uses a clearly
/// labelled 1.6 mm estimate; Gerber/CPL do not establish the finished PCB thickness.
public struct ManufacturingAssemblySettings: Codable, Equatable, Sendable {
    public var boardThickness: Double?
    public init(boardThickness: Double? = nil) { self.boardThickness = boardThickness }
}

/// Model coordinates are mm, mounting plane z=0, body above it. Apply local Euler
/// Rz*Ry*Rx, then local offset, then the unmodified CPL placement. A bottom component
/// receives a proper 180 degree Y rotation, never a winding-reversing reflection.
/// Confirming alignment does not certify the manufacturer's dimensions or geometry.
public struct ManufacturingModelBinding: Codable, Equatable, Sendable {
    public var modelKey: String
    public var offset: PCBPoint3
    public var rotationDegrees: PCBPoint3
    public var alignmentVerified: Bool
    public init(modelKey: String, offset: PCBPoint3 = .init(), rotationDegrees: PCBPoint3 = .init(),
                alignmentVerified: Bool = false) {
        self.modelKey = modelKey; self.offset = offset; self.rotationDegrees = rotationDegrees
        self.alignmentVerified = alignmentVerified
    }
}

public enum ManufacturingModelQuality: String, Codable, Sendable {
    case verified, approximate, missing
}

/// Semantic materials, not UI colors. Each part is a closed outward-CCW mesh.
public enum ManufacturingAssemblyMaterial: String, Codable, Sendable {
    case substrate, body, ceramic, metal, polarity, insulator
}

public struct ManufacturingAssemblyPart: Codable, Equatable, Sendable {
    /// Stable within a model. Pair with the component UUID for cross-view selection.
    public let id: String
    public let material: ManufacturingAssemblyMaterial
    public let vertices: [PCBPoint3]
    /// Consecutive triples index vertices. Renderer supplies normals from these faces.
    public let indices: [Int]
    public init(id: String, material: ManufacturingAssemblyMaterial, vertices: [PCBPoint3], indices: [Int]) {
        self.id = id; self.material = material; self.vertices = vertices; self.indices = indices
    }
}

public struct ManufacturingAssemblyPolygon: Codable, Equatable, Sendable {
    public let partID: String
    public let material: ManufacturingAssemblyMaterial
    public let points: [PCBPoint]
    public init(partID: String, material: ManufacturingAssemblyMaterial, points: [PCBPoint]) {
        self.partID = partID; self.material = material; self.points = points
    }
}

/// Revisioned built-in model. All initial catalog entries are approximate envelopes,
/// including generic terminal geometry: none are a supplier-certified part model.
public struct ManufacturingPackageModel: Codable, Equatable, Sendable {
    public let key: String
    public let name: String
    public let source: String
    public let quality: ManufacturingModelQuality
    public let parts: [ManufacturingAssemblyPart]
    /// Optional local pin-1/polarity witness, not a guaranteed CPL orientation.
    public let pinOne: PCBPoint3?
    public init(key: String, name: String, source: String, quality: ManufacturingModelQuality = .approximate,
                parts: [ManufacturingAssemblyPart], pinOne: PCBPoint3? = nil) {
        self.key = key; self.name = name; self.source = source; self.quality = quality
        self.parts = parts; self.pinOne = pinOne
    }
}

public struct ManufacturingAssemblyInstance: Codable, Equatable, Sendable {
    public let id: UUID
    public let reference: String
    public let side: BoardSide?
    public let fitted: Bool
    public let modelKey: String?
    public let modelName: String?
    public let modelSource: String?
    public let quality: ManufacturingModelQuality
    public let alignmentVerified: Bool
    /// Unmodified CPL center. Nil means no placement: no invented board position.
    public let position: PCBPoint?
    /// Row-major 4x4, acting on column vectors. Nil when placement/model is missing.
    public let transform: [Double]?
    /// Already transformed into document coordinates. Excluded items are retained;
    /// the viewer chooses whether to show them ghosted or hide them.
    public let parts: [ManufacturingAssemblyPart]
    /// Back-to-front for this component's side: paint in array order. Each polygon
    /// is a convex part silhouette; overlapping tilted/intersecting parts still
    /// require the 3D mesh for exact visibility.
    public let polygons: [ManufacturingAssemblyPolygon]
    public let pinOne: PCBPoint3?
    public let bounds: ManufacturingBounds?
}
