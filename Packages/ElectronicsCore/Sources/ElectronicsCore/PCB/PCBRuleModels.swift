import Foundation

/// Optional minima inherit the board floor. Explicit values can only tighten that floor.
public struct PCBNetClassConstraints: Codable, Equatable, Sendable {
    public var clearance: Double?
    public var minimumTrackWidth: Double?
    public var minimumDrill: Double?
    public var minimumAnnularRing: Double?
    public init(clearance: Double? = nil, minimumTrackWidth: Double? = nil,
                minimumDrill: Double? = nil, minimumAnnularRing: Double? = nil) {
        self.clearance = clearance; self.minimumTrackWidth = minimumTrackWidth
        self.minimumDrill = minimumDrill; self.minimumAnnularRing = minimumAnnularRing
    }
}

/// Preferred routing dimensions, distinct from mandatory manufacturing/project minima.
public struct PCBRoutingDimensions: Codable, Equatable, Sendable {
    public var trackWidth: Double
    public var viaDiameter: Double
    public var viaDrill: Double
    public init(trackWidth: Double = 0.25, viaDiameter: Double = 0.6, viaDrill: Double = 0.3) {
        self.trackWidth = trackWidth; self.viaDiameter = viaDiameter; self.viaDrill = viaDrill
    }
}

public struct PCBNetClass: Codable, Equatable, Sendable {
    public var id: UUID
    public var name: String
    public var netIDs: [UUID]
    public var constraints: PCBNetClassConstraints
    public var routing: PCBRoutingDimensions
    public init(id: UUID = UUID(), name: String, netIDs: [UUID] = [],
                constraints: PCBNetClassConstraints = .init(), routing: PCBRoutingDimensions = .init()) {
        self.id = id; self.name = name; self.netIDs = netIDs; self.constraints = constraints; self.routing = routing
    }
}

public struct PCBResolvedNetRules: Codable, Equatable, Sendable {
    public let classID: UUID?
    public let className: String?
    public let rules: PCBDesignRules
    public let routing: PCBRoutingDimensions
}

/// Closed simple polygon; the final point is implicit. Touching its boundary is forbidden.
/// This is a rule region, never conductive material or a mechanical cutout.
public struct PCBKeepout: Codable, Equatable, Sendable {
    public var id: UUID
    public var name: String
    public var outline: [PCBPoint]
    public var layers: [Int]
    public var tracks: Bool
    public var vias: Bool
    public var pads: Bool
    public var zones: Bool
    public init(id: UUID = UUID(), name: String = "Area vietata", outline: [PCBPoint], layers: [Int],
                tracks: Bool = true, vias: Bool = true, pads: Bool = true, zones: Bool = true) {
        self.id = id; self.name = name; self.outline = outline; self.layers = layers
        self.tracks = tracks; self.vias = vias; self.pads = pads; self.zones = zones
    }
    private enum CodingKeys: String, CodingKey { case id, name, outline, layers, tracks, vias, pads, zones }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy:CodingKeys.self)
        id = try c.decode(UUID.self,forKey:.id); name = try c.decode(String.self,forKey:.name)
        outline = try c.decode([PCBPoint].self,forKey:.outline); layers = try c.decode([Int].self,forKey:.layers)
        tracks = try c.decode(Bool.self,forKey:.tracks); vias = try c.decode(Bool.self,forKey:.vias)
        pads = try c.decode(Bool.self,forKey:.pads)
        zones = try c.decodeIfPresent(Bool.self,forKey:.zones) ?? true
    }
    func excludes(_ item: PCBItem) -> Bool {
        switch item { case .track: tracks; case .via: vias; case .pad: pads; case .zone: zones }
    }
}

public struct PCBKeepoutHit: Equatable, Sendable {
    public let id: UUID
    public let position: PCBPoint
    public let distance: Double
}
public struct PCBKeepoutSnapTarget: Equatable, Sendable {
    public enum Kind: Int, Sendable { case vertex, edge }
    public let id: UUID
    public let kind: Kind
    public let position: PCBPoint
    public let distance: Double
}

extension ElectronicsPCB {
    /// Resolve a whole net table after one integrity check. Intended for a background,
    /// revision-keyed UI cache; calling the single-net overload N times validates N times.
    public static func resolvedRules(design: ElectronicsDesign) throws -> [UUID: PCBResolvedNetRules] {
        try ElectronicsValidation.requireIntegrity(design)
        let copper = design.board.copper ?? .init()
        let classes = Dictionary(uniqueKeysWithValues:copper.netClasses.flatMap { c in c.netIDs.map { ($0,c) } })
        var result: [UUID: PCBResolvedNetRules] = [:]
        for net in design.nets {
            try Task.checkCancellation()
            result[net.id] = resolve(copper.rules,netClass:classes[net.id])
        }
        return result
    }
    public static func resolvedRules(design: ElectronicsDesign, netID: UUID?) throws -> PCBResolvedNetRules {
        try ElectronicsValidation.requireIntegrity(design)
        if let netID, !design.nets.contains(where: { $0.id == netID }) {
            throw failure("net_missing", "Rete inesistente: rileggere il circuito.", [netID])
        }
        let copper = design.board.copper ?? .init()
        return resolve(copper.rules, netClass: copper.netClasses.first { netID.map($0.netIDs.contains) ?? false })
    }

    static func resolve(_ boardRules: PCBDesignRules, netClass: PCBNetClass?) -> PCBResolvedNetRules {
        var rules = boardRules
        if let c = netClass?.constraints {
            rules.clearance = max(rules.clearance, c.clearance ?? 0)
            rules.minimumTrackWidth = max(rules.minimumTrackWidth, c.minimumTrackWidth ?? 0)
            rules.minimumDrill = max(rules.minimumDrill, c.minimumDrill ?? 0)
            rules.minimumAnnularRing = max(rules.minimumAnnularRing, c.minimumAnnularRing ?? 0)
        }
        var routing = netClass?.routing ?? .init()
        routing.trackWidth = max(routing.trackWidth, rules.minimumTrackWidth)
        routing.viaDrill = max(routing.viaDrill, rules.minimumDrill)
        routing.viaDiameter = max(routing.viaDiameter, routing.viaDrill + 2 * rules.minimumAnnularRing)
        return .init(classID: netClass?.id, className: netClass?.name, rules: rules, routing: routing)
    }

    public static func keepoutRectangle(from a: PCBPoint, to b: PCBPoint) -> [PCBPoint]? {
        guard ElectronicsGeometry.valid(a), ElectronicsGeometry.valid(b),
              abs(a.x-b.x) > 1e-6, abs(a.y-b.y) > 1e-6 else { return nil }
        let x0 = min(a.x,b.x), x1 = max(a.x,b.x), y0 = min(a.y,b.y), y1 = max(a.y,b.y)
        return [.init(x0,y0), .init(x1,y0), .init(x1,y1), .init(x0,y1)]
    }
}
