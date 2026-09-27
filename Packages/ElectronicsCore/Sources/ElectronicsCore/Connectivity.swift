import Foundation

public struct PlacedPad: Codable, Equatable, Sendable {
    public var componentID: UUID
    public var padID: UUID
    public var pinID: UUID
    public var netID: UUID?
    public var center: PCBPoint
    public var size: PCBPoint
    public var shape: PadShape
    public var rotationDegrees: Double
    public var copperSides: [BoardSide]
    public var drillDiameter: Double?
    public var cornerRadius: Double?
    public var sourceLayers: [String]?
}

public struct Airwire: Codable, Equatable, Sendable {
    public var netID: UUID
    public var fromComponent: UUID
    public var fromPad: UUID
    public var toComponent: UUID
    public var toPad: UUID
    public var from: PCBPoint
    public var to: PCBPoint
}

public struct BoardConnectivity: Codable, Equatable, Sendable {
    public var pads: [PlacedPad]
    /// Minimum-length spanning tree between pad centres. E0 has no routed copper; these
    /// are connections to be routed, never evidence of electrical connection on a real PCB.
    public var airwires: [Airwire]
    public var unplacedComponents: [UUID]
}

public enum ElectronicsConnectivity {
    public static func snapshot(_ design: ElectronicsDesign) throws -> BoardConnectivity {
        try ElectronicsValidation.requireIntegrity(design)
        var pads: [PlacedPad] = []
        var unplaced: [UUID] = []
        for component in design.components.sorted(by: { $0.id.uuidString < $1.id.uuidString }) {
            guard let placement = design.board.placements.first(where: { $0.componentID == component.id }) else {
                unplaced.append(component.id); continue
            }
            let device = design.library.devices.first { $0.key == component.device }!
            let footprint = design.library.footprints.first { $0.key == device.footprint }!
            for pad in footprint.pads.sorted(by: { $0.id.uuidString < $1.id.uuidString }) {
                let pinID = device.pinMap.first { $0.padID == pad.id }!.pinID
                let netID = design.connections.first { $0.pin == PinReference(componentID: component.id, pinID: pinID) }?.netID
                pads.append(.init(componentID: component.id, padID: pad.id, pinID: pinID, netID: netID,
                                  center: ElectronicsGeometry.boardPoint(pad.center, placement: placement), size: pad.size,
                                  shape: pad.shape, rotationDegrees: ElectronicsGeometry.normalizedDegrees(
                                    placement.rotationDegrees + (placement.side == .top ? 1 : -1) * pad.rotationDegrees),
                                  copperSides: pad.drillDiameter == nil ? [placement.side] : [.top, .bottom], drillDiameter: pad.drillDiameter,
                                  cornerRadius: pad.cornerRadius, sourceLayers: pad.sourceLayers))
            }
        }
        var airwires: [Airwire] = []
        for net in design.nets.sorted(by: { $0.id.uuidString < $1.id.uuidString }) {
            let members = pads.filter { $0.netID == net.id }
            guard members.count > 1 else { continue }
            // Deterministic Prim, O(n²), no external geometry library. Tie breaks follow UUID order.
            var reached = Set([0])
            var best = [Double](repeating: .infinity, count: members.count)
            var parent = [Int](repeating: 0, count: members.count)
            var newest = 0
            while reached.count < members.count {
                for j in members.indices where !reached.contains(j) {
                    let a = members[newest].center, b = members[j].center
                    let distance = (a.x - b.x) * (a.x - b.x) + (a.y - b.y) * (a.y - b.y)
                    if distance < best[j] { best[j] = distance; parent[j] = newest }
                }
                let next = members.indices.filter { !reached.contains($0) }.min { a, b in
                    best[a] == best[b] ? a < b : best[a] < best[b]
                }!
                let a = members[parent[next]], b = members[next]
                airwires.append(.init(netID: net.id, fromComponent: a.componentID, fromPad: a.padID,
                                      toComponent: b.componentID, toPad: b.padID, from: a.center, to: b.center))
                reached.insert(next); newest = next
            }
        }
        return .init(pads: pads, airwires: airwires, unplacedComponents: unplaced)
    }
}
