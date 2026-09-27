import Foundation

/// A solid-connected copper region. Fill is derived, never persisted or trusted from a file.
public struct PCBZone: Codable, Equatable, Sendable {
    public var id: UUID
    public var name: String
    public var netID: UUID
    public var layer: Int
    public var outline: [PCBPoint]
    public var removeIslands: Bool
    public init(id: UUID = UUID(), name: String = "Piano di rame", netID: UUID, layer: Int,
                outline: [PCBPoint], removeIslands: Bool = true) {
        self.id = id; self.name = name; self.netID = netID; self.layer = layer
        self.outline = outline; self.removeIslands = removeIslands
    }
}

/// Cells have disjoint interiors within one zone. They are convex, CCW, and use mm.
/// Removing islands means no path through copper to any physical pad, not just no pad in this cell.
public struct PCBZoneFill: Codable, Equatable, Sendable {
    public let zone: PCBZone
    public let cells: [[PCBPoint]]
    public let islandCount: Int
    public let removedIslandCount: Int
    public let area: Double
}

extension ElectronicsPCB {
    static func zoneIntegrity(_ copper: PCBCopper, nets: Set<UUID>) -> [ElectronicsIssue] {
        var result: [ElectronicsIssue] = []
        for z in copper.zones {
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
