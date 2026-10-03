import Foundation

/// Explicit process assumptions, not a supplier qualification. Stored in every export manifest.
public struct FabricationProfile: Codable, Equatable, Sendable {
    public var solderMaskExpansion: Double
    public var pasteInset: Double
    public var minimumMaskWeb: Double
    public var minimumSilkscreenWidth: Double
    public var silkscreenClearance: Double
    public var minimumHoleSeparation: Double
    public var tentVias: Bool
    public init(solderMaskExpansion: Double = 0.05, pasteInset: Double = 0,
                minimumMaskWeb: Double = 0.1, minimumSilkscreenWidth: Double = 0.15,
                silkscreenClearance: Double = 0.1, minimumHoleSeparation: Double = 0.25,
                tentVias: Bool = true) {
        self.solderMaskExpansion = solderMaskExpansion; self.pasteInset = pasteInset
        self.minimumMaskWeb = minimumMaskWeb; self.minimumSilkscreenWidth = minimumSilkscreenWidth
        self.silkscreenClearance = silkscreenClearance; self.minimumHoleSeparation = minimumHoleSeparation
        self.tentVias = tentVias
    }
}

public enum FabricationLayerKind: String, Codable, CaseIterable, Sendable {
    case topCopper, bottomCopper, topMask, bottomMask, topPaste, bottomPaste, topSilkscreen, bottomSilkscreen, profile
    /// Inner copper of an IMPORTED multilayer board (In1 = L2 under the top). The native export
    /// writes `twoLayer` only.
    case inner1, inner2, inner3, inner4, inner5, inner6, inner7, inner8, inner9, inner10, inner11, inner12, inner13, inner14, inner15, inner16, inner17, inner18, inner19, inner20, inner21, inner22, inner23, inner24, inner25, inner26, inner27, inner28, inner29, inner30

    /// The layers of a two-layer board: what the native fabrication export writes.
    public static let twoLayer: [FabricationLayerKind] = [.topCopper, .bottomCopper, .topMask, .bottomMask, .topPaste,
                                                          .bottomPaste, .topSilkscreen, .bottomSilkscreen, .profile]
    /// 1 for In1 … nil for the outer layers.
    public var innerIndex: Int? { rawValue.hasPrefix("inner") ? Int(rawValue.dropFirst(5)) : nil }
    public static func inner(_ index: Int) -> FabricationLayerKind? { FabricationLayerKind(rawValue: "inner\(index)") }
    public var isCopper: Bool { self == .topCopper || self == .bottomCopper || innerIndex != nil }

    public var fileName: String {
        if let n = innerIndex { return "board-In\(n)_Cu.gbr" }
        return switch self {
        case .topCopper: "board-F_Cu.gbr"; case .bottomCopper: "board-B_Cu.gbr"
        case .topMask: "board-F_Mask.gbr"; case .bottomMask: "board-B_Mask.gbr"
        case .topPaste: "board-F_Paste.gbr"; case .bottomPaste: "board-B_Paste.gbr"
        case .topSilkscreen: "board-F_Silkscreen.gbr"; case .bottomSilkscreen: "board-B_Silkscreen.gbr"
        case .profile: "board-Profile.gbr"
        default: "board-\(rawValue).gbr"
        }
    }
    public var fileFunction: String {
        if let n = innerIndex { return "Copper,L\(n + 1),Inr" }
        return switch self {
        case .topCopper: "Copper,L1,Top"; case .bottomCopper: "Copper,L2,Bot"
        case .topMask: "Soldermask,Top"; case .bottomMask: "Soldermask,Bot"
        case .topPaste: "Paste,Top"; case .bottomPaste: "Paste,Bot"
        case .topSilkscreen: "Legend,Top"; case .bottomSilkscreen: "Legend,Bot"
        case .profile: "Profile,NP"
        default: "Other"
        }
    }
    public var polarity: String { self == .topMask || self == .bottomMask ? "Negative" : "Positive" }
}

/// Geometry in the document frame, mm, top view on BOTH sides. Drills are separate voids.
/// A flash is a convex core swept by a disk. A stroke is a polyline swept by a disk.
/// A region is a filled polygon (radius zero). Mask objects denote OPENINGS.
public struct FabricationObject: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable { case flash, stroke, region }
    public let kind: Kind
    public let subjectIDs: [UUID]
    public let core: [PCBPoint]
    public let radius: Double
    var center: PCBPoint { .init(core.map(\.x).reduce(0,+)/Double(core.count), core.map(\.y).reduce(0,+)/Double(core.count)) }
    var copper: PCBCopperPrimitive { .init(item:.track(subjectIDs[0]),netID:nil,layers:[0],core:core,radius:radius) }
}

public struct FabricationLayer: Codable, Equatable, Sendable {
    public let kind: FabricationLayerKind
    public let objects: [FabricationObject]
}

/// Only round plated through holes are represented by the current document model.
public struct FabricationDrill: Codable, Equatable, Sendable {
    public let subjectIDs: [UUID]
    public let position: PCBPoint
    public let diameter: Double
}

public struct FabricationPreview: Codable, Equatable, Sendable {
    public let designID: UUID
    public let revision: UInt64
    public let variantID: UUID?
    public let origin: PCBPoint
    public let profile: FabricationProfile
    public let layers: [FabricationLayer]
    public let drills: [FabricationDrill]
    public let issues: [ElectronicsIssue]
    public var canExport: Bool { !issues.contains { $0.severity == .error } }
}

public struct FabricationFile: Codable, Equatable, Sendable {
    /// Fixed relative base name, never derived from untrusted project/component text.
    public let name: String
    public let content: String
}

public struct FabricationPackage: Codable, Equatable, Sendable {
    public let preview: FabricationPreview
    public let files: [FabricationFile]
}
