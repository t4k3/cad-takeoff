import Foundation

/// A terminal is an identity, never a screen coordinate. Crossing strokes do not short nets.
public enum SchematicTerminal: Codable, Hashable, Sendable {
    case pin(PinReference)
    case junction(UUID)
    var sortKey: String {
        switch self {
        case .pin(let p): "p/\(p.componentID)/\(p.pinID)"
        case .junction(let id): "j/\(id)"
        }
    }
    var subjectIDs: [UUID] {
        switch self { case .pin(let p): [p.componentID, p.pinID]; case .junction(let id): [id] }
    }
}

public struct SchematicSymbol: Codable, Equatable, Sendable {
    public var componentID: UUID
    public var position: PCBPoint
    public var rotationDegrees: Double
    /// Mirror local X before the CCW rotation. PCB placement is independent.
    public var mirrored: Bool
    public init(componentID: UUID, position: PCBPoint, rotationDegrees: Double = 0, mirrored: Bool = false) {
        self.componentID = componentID; self.position = position
        self.rotationDegrees = rotationDegrees; self.mirrored = mirrored
    }
}

public struct SchematicJunction: Codable, Equatable, Sendable {
    public var id: UUID
    public var position: PCBPoint
    public init(id: UUID = UUID(), position: PCBPoint) { self.id = id; self.position = position }
}

public struct SchematicWire: Codable, Equatable, Sendable {
    public var id: UUID
    public var start: SchematicTerminal
    public var end: SchematicTerminal
    /// Interior vertices only; endpoints follow their pin/junction when moved.
    public var bends: [PCBPoint]
    public init(id: UUID = UUID(), start: SchematicTerminal, end: SchematicTerminal, bends: [PCBPoint] = []) {
        self.id = id; self.start = start; self.end = end; self.bends = bends
    }
}

public struct SchematicLabel: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable { case net, power }
    public var id: UUID
    public var terminal: SchematicTerminal
    /// Explicit identity shared between sheets. A matching display name is never sufficient.
    public var netID: UUID
    public var kind: Kind
    public var offset: PCBPoint
    public init(id: UUID = UUID(), terminal: SchematicTerminal, netID: UUID, kind: Kind = .net, offset: PCBPoint = .init(1, 1)) {
        self.id = id; self.terminal = terminal; self.netID = netID; self.kind = kind; self.offset = offset
    }
}

public struct SchematicSheet: Codable, Equatable, Sendable {
    public var id: UUID
    public var name: String
    /// Document organization; reusable hierarchical instances and ports are not implied.
    public var parentID: UUID?
    public var symbols: [SchematicSymbol]
    public var junctions: [SchematicJunction]
    public var wires: [SchematicWire]
    public var labels: [SchematicLabel]
    public init(id: UUID = UUID(), name: String, parentID: UUID? = nil,
                symbols: [SchematicSymbol] = [], junctions: [SchematicJunction] = [],
                wires: [SchematicWire] = [], labels: [SchematicLabel] = []) {
        self.id = id; self.name = name; self.parentID = parentID; self.symbols = symbols
        self.junctions = junctions; self.wires = wires; self.labels = labels
    }
}

public struct SchematicWireNet: Codable, Equatable, Sendable {
    public var wireID: UUID
    public var netID: UUID
    public init(wireID: UUID, netID: UUID) { self.wireID = wireID; self.netID = netID }
}

public struct SchematicCircuit: Codable, Equatable, Sendable {
    public var sheets: [SchematicSheet]
    /// Independent logical connections, including pre-schema projects and explicit NC markers.
    /// Wires may add connectivity, but removing a drawing must not erase these connections.
    public var directConnections: [PinConnection]
    /// Maintained by the engine to retain net identity while extending/moving wires.
    public var wireNets: [SchematicWireNet]
    public var generatedNetIDs: [UUID]
    /// Explicitly renamed networks remain intentional bindings even without a drawn label.
    public var namedNetIDs: [UUID]
    public init(sheets: [SchematicSheet] = [], directConnections: [PinConnection] = [],
                wireNets: [SchematicWireNet] = [], generatedNetIDs: [UUID] = [], namedNetIDs: [UUID] = []) {
        self.sheets = sheets; self.directConnections = directConnections
        self.wireNets = wireNets; self.generatedNetIDs = generatedNetIDs; self.namedNetIDs = namedNetIDs
    }
}

public indirect enum SchematicCommand: Codable, Equatable, Sendable {
    case addSheet(SchematicSheet)
    case renameSheet(id: UUID, name: String)
    case removeSheet(UUID)
    case placeSymbol(sheetID: UUID, symbol: SchematicSymbol)
    case moveSymbol(componentID: UUID, to: PCBPoint)
    case rotateSymbol(componentID: UUID, by: Double)
    case mirrorSymbol(UUID)
    case removeSymbol(UUID)
    case addJunction(sheetID: UUID, junction: SchematicJunction)
    case moveJunction(id: UUID, to: PCBPoint)
    case removeJunction(UUID)
    case addWire(sheetID: UUID, wire: SchematicWire)
    case setWireBends(id: UUID, bends: [PCBPoint])
    case removeWire(UUID)
    /// Split a specific stroke at an explicit junction (for a branch). The first wire keeps its ID.
    case splitWire(id: UUID, junction: SchematicJunction, newWireID: UUID)
    case addLabel(sheetID: UUID, label: SchematicLabel, net: CircuitNet)
    case removeLabel(UUID)
    /// All children are one preview / one undo; useful for a branch and its new wire.
    case batch([SchematicCommand])

    public var title: String {
        switch self {
        case .addSheet: "Aggiungi foglio"
        case .renameSheet: "Rinomina foglio"
        case .removeSheet: "Elimina foglio"
        case .placeSymbol: "Posiziona simbolo"
        case .moveSymbol: "Sposta simbolo"
        case .rotateSymbol: "Ruota simbolo"
        case .mirrorSymbol: "Specchia simbolo"
        case .removeSymbol: "Rimuovi simbolo"
        case .addJunction, .splitWire: "Inserisci giunzione"
        case .moveJunction: "Sposta giunzione"
        case .removeJunction: "Elimina giunzione"
        case .addWire: "Disegna filo"
        case .setWireBends: "Modifica filo"
        case .removeWire: "Elimina filo"
        case .addLabel: "Aggiungi etichetta"
        case .removeLabel: "Elimina etichetta"
        case .batch: "Modifica schema"
        }
    }
}
