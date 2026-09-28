import Foundation

public struct ManufacturingSource: Codable, Equatable, Sendable {
    public let name: String
    public let sha256: String
    public let byteCount: Int
    public init(name: String, sha256: String, byteCount: Int) {
        self.name = name; self.sha256 = sha256; self.byteCount = byteCount
    }
}

public struct ManufacturingBounds: Codable, Equatable, Sendable {
    public let minimum: PCBPoint
    public let maximum: PCBPoint
    public var width: Double { maximum.x - minimum.x }
    public var height: Double { maximum.y - minimum.y }
    public init(minimum: PCBPoint, maximum: PCBPoint) { self.minimum = minimum; self.maximum = maximum }
}

public struct ManufacturingComponent: Codable, Equatable, Sendable {
    public let id: UUID
    public let reference: String
    public var value: String?
    public var footprint: String?
    public var lcscPartNumber: String?
    public var placement: ManufacturingPlacement?
    public init(id: UUID, reference: String, value: String? = nil, footprint: String? = nil,
                lcscPartNumber: String? = nil, placement: ManufacturingPlacement? = nil) {
        self.id = id; self.reference = reference; self.value = value; self.footprint = footprint
        self.lcscPartNumber = lcscPartNumber; self.placement = placement
    }
}

public struct ManufacturingLot: Codable, Equatable, Sendable {
    public let id: UUID
    public var name: String
    public var fittedComponentIDs: [UUID]
    public let bomSHA256: String?
    public init(id: UUID, name: String, fittedComponentIDs: [UUID], bomSHA256: String? = nil) {
        self.id = id; self.name = name; self.fittedComponentIDs = fittedComponentIDs; self.bomSHA256 = bomSHA256
    }
}

/// Manufacturing artwork and assembly lots, not an inferred editable CAD/schematic model.
public struct ManufacturingPackage: Codable, Equatable, Sendable {
    public let id: UUID
    public var name: String
    public let layers: [ManufacturingLayer]
    public let drills: [ManufacturingDrill]
    public var components: [ManufacturingComponent]
    public var lots: [ManufacturingLot]
    public var activeLotID: UUID
    public var sources: [ManufacturingSource]
    public let bounds: ManufacturingBounds
    /// Import diagnostics. Use `diagnostics` for the current lot after editing.
    public let issues: [ElectronicsIssue]
    public var activeLot: ManufacturingLot? { lots.first { $0.id == activeLotID } }
    public func isFitted(_ id: UUID) -> Bool { activeLot?.fittedComponentIDs.contains(id) == true }
    public init(id: UUID, name: String, layers: [ManufacturingLayer], drills: [ManufacturingDrill],
                components: [ManufacturingComponent], lots: [ManufacturingLot], activeLotID: UUID,
                sources: [ManufacturingSource], bounds: ManufacturingBounds, issues: [ElectronicsIssue] = []) {
        self.id = id; self.name = name; self.layers = layers; self.drills = drills
        self.components = components; self.lots = lots; self.activeLotID = activeLotID
        self.sources = sources; self.bounds = bounds; self.issues = issues
    }
}

public enum ManufacturingCommand: Codable, Equatable, Sendable {
    case importPackage(ManufacturingPackage)
    case setFitted(componentID: UUID, fitted: Bool)
    case addLot(id: UUID, name: String)
    case selectLot(UUID)
    public var title: String {
        switch self {
        case .importPackage: "Importa scheda e lotto"
        case .setFitted: "Modifica montaggio del lotto"
        case .addLot: "Crea lotto"
        case .selectLot: "Seleziona lotto"
        }
    }
}
