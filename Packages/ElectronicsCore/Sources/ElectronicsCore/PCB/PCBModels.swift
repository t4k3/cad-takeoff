import Foundation

/// Millimetres. Project defaults, not a supplier-qualified process specification.
public struct PCBDesignRules: Codable, Equatable, Sendable {
    public var clearance: Double
    public var edgeClearance: Double
    public var minimumTrackWidth: Double
    public var minimumDrill: Double
    public var minimumAnnularRing: Double
    public init(clearance: Double = 0.2, edgeClearance: Double = 0.25,
                minimumTrackWidth: Double = 0.2, minimumDrill: Double = 0.3,
                minimumAnnularRing: Double = 0.15) {
        self.clearance = clearance; self.edgeClearance = edgeClearance
        self.minimumTrackWidth = minimumTrackWidth; self.minimumDrill = minimumDrill
        self.minimumAnnularRing = minimumAnnularRing
    }
}

public struct PCBTrack: Codable, Equatable, Sendable {
    public var id: UUID
    public var netID: UUID
    /// Zero is top, layerCount - 1 is bottom. Inner layers retain their integer identity.
    public var layer: Int
    public var width: Double
    public var points: [PCBPoint]
    public init(id: UUID = UUID(), netID: UUID, layer: Int, width: Double, points: [PCBPoint]) {
        self.id = id; self.netID = netID; self.layer = layer; self.width = width; self.points = points
    }
}

/// Plated through via. Blind/buried vias are deliberately not represented as through vias.
public struct PCBVia: Codable, Equatable, Sendable {
    public var id: UUID
    public var netID: UUID
    public var position: PCBPoint
    public var diameter: Double
    public var drill: Double
    public init(id: UUID = UUID(), netID: UUID, position: PCBPoint, diameter: Double = 0.6, drill: Double = 0.3) {
        self.id = id; self.netID = netID; self.position = position; self.diameter = diameter; self.drill = drill
    }
}

public struct PCBCopper: Codable, Equatable, Sendable {
    public var layerCount: Int
    public var rules: PCBDesignRules
    public var tracks: [PCBTrack]
    public var vias: [PCBVia]
    public init(layerCount: Int = 2, rules: PCBDesignRules = .init(), tracks: [PCBTrack] = [], vias: [PCBVia] = []) {
        self.layerCount = layerCount; self.rules = rules; self.tracks = tracks; self.vias = vias
    }
    public var netIDs: Set<UUID> { Set(tracks.map(\.netID) + vias.map(\.netID)) }
}

public enum PCBItem: Codable, Hashable, Sendable {
    case pad(componentID: UUID, padID: UUID)
    case track(UUID)
    case via(UUID)
    public var subjectIDs: [UUID] {
        switch self { case let .pad(c, p): [c, p]; case .track(let id), .via(let id): [id] }
    }
    var key: String {
        let prefix = switch self { case .pad: "0/"; case .via: "1/"; case .track: "2/" }
        return prefix + subjectIDs.map(\.uuidString).joined(separator: "/")
    }
}

/// Exact outer copper shape: a convex core swept by a disk. One track may have several primitives.
public struct PCBCopperPrimitive: Codable, Equatable, Sendable {
    public var item: PCBItem
    public var netID: UUID?
    public var layers: [Int]
    public var core: [PCBPoint]
    public var radius: Double
    public var drillDiameter: Double?
    public var center: PCBPoint {
        .init(core.map(\.x).reduce(0,+) / Double(core.count), core.map(\.y).reduce(0,+) / Double(core.count))
    }
}

public indirect enum PCBCommand: Codable, Equatable, Sendable {
    case addTrack(PCBTrack), updateTrack(PCBTrack), removeTrack(UUID)
    case addVia(PCBVia), updateVia(PCBVia), removeVia(UUID)
    case configure(layerCount: Int, rules: PCBDesignRules)
    case batch([PCBCommand])
    public var title: String {
        switch self {
        case .addTrack: "Traccia pista"; case .updateTrack: "Modifica pista"; case .removeTrack: "Elimina pista"
        case .addVia: "Inserisci via"; case .updateVia: "Modifica via"; case .removeVia: "Elimina via"
        case .configure: "Regole del PCB"; case .batch: "Modifica rame"
        }
    }
}
