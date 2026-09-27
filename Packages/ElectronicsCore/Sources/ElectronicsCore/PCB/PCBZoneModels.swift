import Foundation

public enum PCBZoneConnection: String, Codable, CaseIterable, Sendable {
    case solid, thermal, thermalThroughHole, none
}

/// Fill is derived, never persisted or trusted from a file. Zero minimumWidth preserves
/// legacy geometry; a positive value filters narrow copper with a polygonal opening.
public struct PCBZone: Codable, Equatable, Sendable {
    public var id: UUID
    public var name: String
    public var netID: UUID
    public var layer: Int
    public var outline: [PCBPoint]
    public var removeIslands: Bool
    public var connection: PCBZoneConnection
    public var thermalGap: Double
    public var thermalSpokeWidth: Double
    /// Degrees relative to the placed pad axes, on either side of the board.
    public var thermalAngleDegrees: Double
    public var minimumSpokes: Int
    public var minimumWidth: Double
    public init(id: UUID = UUID(), name: String = "Piano di rame", netID: UUID, layer: Int,
                outline: [PCBPoint], removeIslands: Bool = true,
                connection: PCBZoneConnection = .solid, thermalGap: Double = 0.3,
                thermalSpokeWidth: Double = 0.3, thermalAngleDegrees: Double = 0,
                minimumSpokes: Int = 2, minimumWidth: Double = 0) {
        self.id = id; self.name = name; self.netID = netID; self.layer = layer
        self.outline = outline; self.removeIslands = removeIslands
        self.connection = connection; self.thermalGap = thermalGap; self.thermalSpokeWidth = thermalSpokeWidth
        self.thermalAngleDegrees = thermalAngleDegrees; self.minimumSpokes = minimumSpokes; self.minimumWidth = minimumWidth
    }
    private enum CodingKeys: String, CodingKey {
        case id, name, netID, layer, outline, removeIslands, connection, thermalGap, thermalSpokeWidth, thermalAngleDegrees, minimumSpokes, minimumWidth
    }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id); name = try c.decode(String.self, forKey: .name)
        netID = try c.decode(UUID.self, forKey: .netID); layer = try c.decode(Int.self, forKey: .layer)
        outline = try c.decode([PCBPoint].self, forKey: .outline); removeIslands = try c.decode(Bool.self, forKey: .removeIslands)
        connection = try c.decodeIfPresent(PCBZoneConnection.self, forKey: .connection) ?? .solid
        thermalGap = try c.decodeIfPresent(Double.self, forKey: .thermalGap) ?? 0.3
        thermalSpokeWidth = try c.decodeIfPresent(Double.self, forKey: .thermalSpokeWidth) ?? 0.3
        thermalAngleDegrees = try c.decodeIfPresent(Double.self, forKey: .thermalAngleDegrees) ?? 0
        minimumSpokes = try c.decodeIfPresent(Int.self, forKey: .minimumSpokes) ?? 2
        minimumWidth = try c.decodeIfPresent(Double.self, forKey: .minimumWidth) ?? 0
    }
}

/// Resolved from retained copper, not from the four intended spokes.
public struct PCBZoneThermal: Codable, Equatable, Sendable {
    public let componentID: UUID
    public let padID: UUID
    public let position: PCBPoint
    public let connectedSpokes: Int
}

/// Cells have disjoint interiors within one zone. They are convex, CCW, and use mm.
/// Removing islands means no path through copper to any physical pad, not just no pad in this cell.
public struct PCBZoneFill: Codable, Equatable, Sendable {
    public let zone: PCBZone
    public let cells: [[PCBPoint]]
    public let islandCount: Int
    public let removedIslandCount: Int
    public let area: Double
    public let thermals: [PCBZoneThermal]
    public let removedNarrowArea: Double
}

extension ElectronicsPCB {
    static func zoneIntegrity(_ copper: PCBCopper, nets: Set<UUID>) -> [ElectronicsIssue] {
        var result: [ElectronicsIssue] = []
        for z in copper.zones {
            if ![z.thermalGap,z.thermalSpokeWidth].allSatisfy({ ElectronicsGeometry.valid($0) && $0 > 0 }) ||
                !ElectronicsGeometry.valid(z.thermalAngleDegrees) || !ElectronicsGeometry.valid(z.minimumWidth) || z.minimumWidth < 0 ||
                !(0...4).contains(z.minimumSpokes) {
                result += failure("invalid_zone_thermal", "Piano: distanza e ponticelli positivi, larghezza minima non negativa, angolo finito e 0–4 raggi minimi richiesti.", [z.id]).issues
            }
            if z.name.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty || z.name.count > 128 ||
                z.outline.count > 1024 || !ElectronicsGeometry.simplePolygon(z.outline) {
                result += failure("invalid_zone", "Piano di rame: nome e contorno semplice di 3–1024 vertici richiesti.", [z.id]).issues
            }
            if !nets.contains(z.netID) { result += failure("dangling_copper_net", "Il piano riferisce una rete inesistente.", [z.id,z.netID]).issues }
            if z.layer < 0 || z.layer >= copper.layerCount { result += failure("invalid_zone_layer", "Strato del piano inesistente.", [z.id]).issues }
        }
        // Same-net outlines may overlap. Different nets must have separate outlines until
        // an explicit priority model exists; UUID ordering must never decide electrical intent.
        if result.isEmpty {
            for i in copper.zones.indices {
                let a = copper.zones[i]
                for b in copper.zones.dropFirst(i+1) where a.layer == b.layer && a.netID != b.netID {
                    if PCBGeometry.coreDistance(a.outline,b.outline) <= PCBGeometry.epsilon {
                        result += failure("overlapping_zone_nets", "Piani di reti diverse sullo stesso strato: separare i contorni prima di riempire.", [a.id,b.id]).issues
                    }
                }
            }
        }
        return result
    }
}
