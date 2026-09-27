import Foundation

/// A library identity is independent of its display name. References pin an exact revision.
public struct LibraryRevision: Codable, Hashable, Sendable {
    public var id: UUID
    public var revision: Int
    public init(id: UUID = UUID(), revision: Int = 1) { self.id = id; self.revision = revision }
}

/// All coordinates are millimetres, in a right-handed, Z-up board frame, seen from the top.
/// Raw values are editable; validation is mandatory at transaction, load and export boundaries.
public struct PCBPoint: Codable, Hashable, Sendable {
    public var x: Double
    public var y: Double
    public init(_ x: Double = 0, _ y: Double = 0) { self.x = x; self.y = y }
}

public struct PCBPoint3: Codable, Equatable, Sendable {
    public var x: Double
    public var y: Double
    public var z: Double
    public init(_ x: Double = 0, _ y: Double = 0, _ z: Double = 0) { self.x = x; self.y = y; self.z = z }
}

public struct LibrarySource: Codable, Equatable, Sendable {
    public var reference: String
    public var license: String
    /// Revision of the source data, not the mutable catalog's current version.
    public var sourceRevision: String
    public init(reference: String, license: String, sourceRevision: String) {
        self.reference = reference; self.license = license; self.sourceRevision = sourceRevision
    }
}

public enum PinElectricalType: String, Codable, Sendable {
    case passive, input, output, bidirectional, openDrain, powerInput, powerOutput, noConnect
}

public struct SymbolPin: Codable, Equatable, Sendable {
    public var id: UUID
    public var name: String
    public var electricalType: PinElectricalType
    public init(id: UUID = UUID(), name: String, electricalType: PinElectricalType = .passive) {
        self.id = id; self.name = name; self.electricalType = electricalType
    }
}

public struct SymbolDefinition: Codable, Equatable, Sendable {
    public var key: LibraryRevision
    public var name: String
    public var pins: [SymbolPin]
    public var source: LibrarySource
    public init(key: LibraryRevision = .init(), name: String, pins: [SymbolPin], source: LibrarySource) {
        self.key = key; self.name = name; self.pins = pins; self.source = source
    }
}

public enum PadShape: String, Codable, Sendable { case circle, rectangle, oval }
public struct FootprintPad: Codable, Equatable, Sendable {
    public var id: UUID
    public var number: String
    public var center: PCBPoint
    public var size: PCBPoint
    public var shape: PadShape
    public var rotationDegrees: Double
    /// nil is a surface pad; a value is a plated through-hole diameter in mm.
    public var drillDiameter: Double?
    public init(id: UUID = UUID(), number: String, center: PCBPoint, size: PCBPoint,
                shape: PadShape = .rectangle, rotationDegrees: Double = 0, drillDiameter: Double? = nil) {
        self.id = id; self.number = number; self.center = center; self.size = size
        self.shape = shape; self.rotationDegrees = rotationDegrees; self.drillDiameter = drillDiameter
    }
}

/// Asset data are not loaded by this package. A CAD adapter must resolve this within the project.
/// Model coordinates must already use mm, Z-up, mounting plane Z=0, body extending toward +Z.
public struct ComponentModel3D: Codable, Equatable, Sendable {
    public var relativePath: String
    public var sha256: String
    public var offset: PCBPoint3
    public init(relativePath: String, sha256: String, offset: PCBPoint3 = .init()) {
        self.relativePath = relativePath; self.sha256 = sha256; self.offset = offset
    }
}

public struct FootprintDefinition: Codable, Equatable, Sendable {
    public var key: LibraryRevision
    public var name: String
    public var pads: [FootprintPad]
    /// Actual pickup/placement centroid, not necessarily the footprint origin or bounding-box centre.
    public var assemblyCentroid: PCBPoint
    public var model3D: ComponentModel3D?
    public var source: LibrarySource
    public init(key: LibraryRevision = .init(), name: String, pads: [FootprintPad],
                assemblyCentroid: PCBPoint = .init(), model3D: ComponentModel3D? = nil, source: LibrarySource) {
        self.key = key; self.name = name; self.pads = pads; self.assemblyCentroid = assemblyCentroid
        self.model3D = model3D; self.source = source
    }
}

public struct PinPadMapping: Codable, Equatable, Sendable {
    public var pinID: UUID
    public var padID: UUID
    public init(pinID: UUID, padID: UUID) { self.pinID = pinID; self.padID = padID }
}

/// An explicit, per-side supplier convention. No unverified bottom-side sign is assumed.
public struct AssemblyRotationRule: Codable, Equatable, Sendable {
    public enum Direction: String, Codable, Sendable { case same, negated }
    public var direction: Direction
    public var offsetDegrees: Double
    public var evidence: String
    public init(direction: Direction, offsetDegrees: Double, evidence: String) {
        self.direction = direction; self.offsetDegrees = offsetDegrees; self.evidence = evidence
    }
}

public struct JLCAssemblyPart: Codable, Equatable, Sendable {
    public var partNumber: String
    /// Catalog lookup provenance; this does not assert current stock or production availability.
    public var catalogReference: String
    public var topRotation: AssemblyRotationRule?
    public var bottomRotation: AssemblyRotationRule?
    public init(partNumber: String, catalogReference: String,
                topRotation: AssemblyRotationRule? = nil, bottomRotation: AssemblyRotationRule? = nil) {
        self.partNumber = partNumber; self.catalogReference = catalogReference
        self.topRotation = topRotation; self.bottomRotation = bottomRotation
    }
}

public struct DeviceDefinition: Codable, Equatable, Sendable {
    public var key: LibraryRevision
    public var manufacturer: String
    public var manufacturerPartNumber: String
    public var symbol: LibraryRevision
    public var footprint: LibraryRevision
    /// Every electrical pad is mapped explicitly. One pin may map to several physical pads.
    public var pinMap: [PinPadMapping]
    public var jlc: JLCAssemblyPart?
    public init(key: LibraryRevision = .init(), manufacturer: String, manufacturerPartNumber: String,
                symbol: LibraryRevision, footprint: LibraryRevision, pinMap: [PinPadMapping], jlc: JLCAssemblyPart? = nil) {
        self.key = key; self.manufacturer = manufacturer; self.manufacturerPartNumber = manufacturerPartNumber
        self.symbol = symbol; self.footprint = footprint; self.pinMap = pinMap; self.jlc = jlc
    }
}

/// Embedded snapshots make reopening independent of catalog updates or network access.
public struct ElectronicsLibrary: Codable, Equatable, Sendable {
    public var symbols: [SymbolDefinition]
    public var footprints: [FootprintDefinition]
    public var devices: [DeviceDefinition]
    public init(symbols: [SymbolDefinition] = [], footprints: [FootprintDefinition] = [], devices: [DeviceDefinition] = []) {
        self.symbols = symbols; self.footprints = footprints; self.devices = devices
    }
}

public enum AssemblyMethod: String, Codable, Sendable { case jlcpcb, manual, doNotPopulate }
public struct CircuitComponent: Codable, Equatable, Sendable {
    public var id: UUID
    public var reference: String
    public var value: String
    public var device: LibraryRevision
    public var assembly: AssemblyMethod
    public init(id: UUID = UUID(), reference: String, value: String, device: LibraryRevision, assembly: AssemblyMethod = .manual) {
        self.id = id; self.reference = reference; self.value = value; self.device = device; self.assembly = assembly
    }
}

public struct CircuitNet: Codable, Equatable, Sendable {
    public var id: UUID
    public var name: String
    public init(id: UUID = UUID(), name: String) { self.id = id; self.name = name }
}

public struct PinReference: Codable, Hashable, Sendable {
    public var componentID: UUID
    public var pinID: UUID
    public init(componentID: UUID, pinID: UUID) { self.componentID = componentID; self.pinID = pinID }
}

/// nil netID is an explicit no-connect marker, not an implicit missing wire.
public struct PinConnection: Codable, Equatable, Sendable {
    public var pin: PinReference
    public var netID: UUID?
    public init(pin: PinReference, netID: UUID?) { self.pin = pin; self.netID = netID }
}

public enum BoardSide: String, Codable, Sendable { case top, bottom }
public struct ComponentPlacement: Codable, Equatable, Sendable {
    public var componentID: UUID
    public var position: PCBPoint
    /// CCW as viewed from the top of the board, including components on the bottom.
    public var rotationDegrees: Double
    public var side: BoardSide
    public init(componentID: UUID, position: PCBPoint, rotationDegrees: Double = 0, side: BoardSide = .top) {
        self.componentID = componentID; self.position = position; self.rotationDegrees = rotationDegrees; self.side = side
    }
}

public struct PCBBoard: Codable, Equatable, Sendable {
    /// Simple closed polygon without a repeated final vertex. Cutouts and stackups follow in E2.
    public var outline: [PCBPoint]
    public var thickness: Double
    public var assemblyOrigin: PCBPoint
    public var placements: [ComponentPlacement]
    public init(outline: [PCBPoint], thickness: Double = 1.6, assemblyOrigin: PCBPoint = .init(), placements: [ComponentPlacement] = []) {
        self.outline = outline; self.thickness = thickness; self.assemblyOrigin = assemblyOrigin; self.placements = placements
    }
}

public struct AssemblyVariant: Codable, Equatable, Sendable {
    public var id: UUID
    public var name: String
    public var excludedComponents: [UUID]
    public init(id: UUID = UUID(), name: String, excludedComponents: [UUID] = []) {
        self.id = id; self.name = name; self.excludedComponents = excludedComponents
    }
}

public struct ElectronicsDesign: Codable, Equatable, Sendable {
    public var id: UUID
    public var name: String
    public var library: ElectronicsLibrary
    public var components: [CircuitComponent]
    public var nets: [CircuitNet]
    public var connections: [PinConnection]
    public var board: PCBBoard
    public var variants: [AssemblyVariant]
    public init(id: UUID = UUID(), name: String, library: ElectronicsLibrary, components: [CircuitComponent] = [],
                nets: [CircuitNet] = [], connections: [PinConnection] = [], board: PCBBoard, variants: [AssemblyVariant] = []) {
        self.id = id; self.name = name; self.library = library; self.components = components
        self.nets = nets; self.connections = connections; self.board = board; self.variants = variants
    }
}
