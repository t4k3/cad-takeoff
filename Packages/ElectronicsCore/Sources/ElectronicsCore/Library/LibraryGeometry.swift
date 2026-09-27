import Foundation

public struct LibraryGeometryBounds: Codable, Equatable, Sendable {
    public let minimum: PCBPoint
    public let maximum: PCBPoint
}

/// Exact outer pad shape = convex core swept by a disk of `radius`, minus the circular bore.
/// Coordinates are local footprint millimetres, Y up; rotation is already applied by the engine.
public struct LibraryPadPrimitive: Codable, Equatable, Sendable {
    public let id: UUID
    public let number: String
    public let core: [PCBPoint]
    public let radius: Double
    public let center: PCBPoint
    public let drillDiameter: Double?
}

/// Local pad copper and holes only. Cosmetic graphics, model assets and assembly courtyard
/// are not part of these bounds and must not be inferred from them.
public struct LibraryFootprintSnapshot: Codable, Equatable, Sendable {
    public let key: LibraryRevision
    public let pads: [LibraryPadPrimitive]
    public let bounds: LibraryGeometryBounds
}

public enum ElectronicsLibraryGeometry {
    public static func footprint(_ definition: FootprintDefinition) throws -> LibraryFootprintSnapshot {
        try Task.checkCancellation()
        try ElectronicsValidation.requireLibrary(.init(footprints: [definition]))
        var pads: [LibraryPadPrimitive] = []
        var bounds: PCBBox?
        for pad in definition.pads.sorted(by: { $0.id.uuidString < $1.id.uuidString }) {
            try Task.checkCancellation()
            // Reuse the DRC's exact shape. These temporary IDs never represent a placed part
            // and are not exposed: a library preview returns only its real pad identity.
            let placed = PlacedPad(componentID: definition.key.id, padID: pad.id, pinID: pad.id,
                netID: nil, center: pad.center, size: pad.size, shape: pad.shape,
                rotationDegrees: pad.rotationDegrees, copperSides: [.top],
                drillDiameter: pad.drillDiameter, cornerRadius: pad.cornerRadius, sourceLayers: pad.sourceLayers)
            let primitive = PCBGeometry.pad(placed, layerCount: 2)
            pads.append(.init(id: pad.id, number: pad.number, core: primitive.core, radius: primitive.radius,
                              center: pad.center, drillDiameter: primitive.drillDiameter))
            let box = PCBBox(primitive.core, margin: primitive.radius)
            bounds = bounds.map { PCBBox($0, box) } ?? box
        }
        // Empty footprints are rejected by library integrity above.
        let box = bounds!
        return .init(key: definition.key, pads: pads,
                     bounds: .init(minimum: .init(box.minX, box.minY), maximum: .init(box.maxX, box.maxY)))
    }
}
