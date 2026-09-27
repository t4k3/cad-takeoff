import Foundation

public struct AssemblyInstance3D: Codable, Equatable, Sendable {
    public var componentID: UUID
    public var reference: String
    public var side: BoardSide
    public var device: LibraryRevision
    public var footprint: LibraryRevision
    public var model: ComponentModel3D?
    /// Row-major, column-vector, right-handed rigid matrix. Board is in XY, z in [0, thickness].
    public var transform: [Double]
}

public struct AssemblyData: Codable, Equatable, Sendable {
    public var designID: UUID
    public var documentRevision: UInt64
    public var variantID: UUID?
    public var bomCSV: String
    public var cplCSV: String
    public var instances3D: [AssemblyInstance3D]
    public var connectivity: BoardConnectivity
    public var issues: [ElectronicsIssue]
    /// E0 verifies assembly data only; it has no copper/DRC/fabrication release engine yet.
    public let fabricationReady: Bool = false
}

public enum ElectronicsAssembly {
    /// Export is all-or-nothing. No component disappears silently because it is unplaced,
    /// unmapped, missing a supplier number, or missing the required side's rotation rule.
    public static func export(_ document: ElectronicsDocument, variantID: UUID? = nil) throws -> AssemblyData {
        let design = document.design
        try ElectronicsValidation.requireIntegrity(design)
        let excluded: Set<UUID>
        if let variantID {
            guard let variant = design.variants.first(where: { $0.id == variantID }) else {
                throw ElectronicsFailure([.init("unknown_variant", variantID.uuidString, "Variante inesistente.")])
            }
            excluded = Set(variant.excludedComponents)
        } else { excluded = [] }
        let notFitted = excluded.union(design.components.filter { $0.assembly == .doNotPopulate }.map(\.id))
        var issues = ElectronicsValidation.electrical(design, excluding: notFitted)
        var rows: [[String]] = []
        var instances: [AssemblyInstance3D] = []
        struct Group: Hashable {
            var device: LibraryRevision
            var value: String
            var footprint: String
            var part: String
        }
        var groups: [Group: [String]] = [:]
        let components = design.components.filter { $0.assembly != .doNotPopulate && !excluded.contains($0.id) }
            .sorted { $0.reference < $1.reference }
        for component in components {
            guard let device = design.library.devices.first(where: { $0.key == component.device }),
                  let footprint = design.library.footprints.first(where: { $0.key == device.footprint }) else { continue } // integrity checked
            guard let placement = design.board.placements.first(where: { $0.componentID == component.id }) else {
                issues.append(.init("unplaced_component", component.reference, "Componente montato senza posizione PCB.")); continue
            }
            instances.append(.init(componentID: component.id, reference: component.reference, side: placement.side,
                                   device: device.key, footprint: footprint.key, model: footprint.model3D,
                                   transform: ElectronicsGeometry.modelTransform(placement: placement, thickness: design.board.thickness,
                                                                                 offset: footprint.model3D?.offset ?? .init())))
            if footprint.model3D == nil {
                issues.append(.init("missing_3d_model", component.reference, "Trasformazione disponibile; manca la geometria 3D verificata.", severity: .warning))
            }
            guard component.assembly == .jlcpcb else { continue }
            guard let part = device.jlc else {
                issues.append(.init("missing_supplier_part", component.reference, "Manca il componente JLCPCB/LCSC selezionato.")); continue
            }
            guard let rule = placement.side == .top ? part.topRotation : part.bottomRotation else {
                issues.append(.init("unverified_assembly_rotation", component.reference, "Manca la convenzione di rotazione verificata per questo lato.")); continue
            }
            let center = ElectronicsGeometry.boardPoint(footprint.assemblyCentroid, placement: placement)
            let rotation = ElectronicsGeometry.normalizedDegrees((rule.direction == .same ? 1 : -1) * placement.rotationDegrees + rule.offsetDegrees)
            rows.append([component.reference, decimal(center.x - design.board.assemblyOrigin.x),
                         decimal(center.y - design.board.assemblyOrigin.y), placement.side == .top ? "Top" : "Bottom", decimal(rotation)])
            let group = Group(device: device.key, value: component.value, footprint: footprint.name, part: part.partNumber)
            groups[group, default: []].append(component.reference)
        }
        let errors = issues.filter { $0.severity == .error }
        guard errors.isEmpty else { throw ElectronicsFailure(errors) }
        let bomRows = groups.map { group, refs in [group.value, refs.sorted().joined(separator: ","), group.footprint, group.part] }
            .sorted { $0[1] < $1[1] }
        issues.append(.init("assembly_data_only", "export", "Dati di assemblaggio: routing, DRC completo e file di fabbricazione non verificati da E0.", severity: .warning))
        issues.append(.init("supplier_availability_unchecked", "export", "Disponibilità e orientamento nel viewer JLCPCB richiedono verifica sul fornitore.", severity: .warning))
        issues.append(.init("model_assets_unchecked", "export", "Riferimenti e trasformazioni 3D disponibili; file, hash e ingombri dei modelli non verificati da E0.", severity: .warning))
        return AssemblyData(designID: design.id, documentRevision: document.revision, variantID: variantID,
                            bomCSV: csv([["Comment", "Designator", "Footprint", "LCSC Part #"]] + bomRows),
                            cplCSV: csv([["Designator", "Mid X", "Mid Y", "Layer", "Rotation"]] + rows),
                            instances3D: instances, connectivity: try ElectronicsConnectivity.snapshot(design), issues: issues)
    }

    private static func decimal(_ value: Double) -> String {
        // Avoid '-0.000000'; POSIX is independent of the Italian UI/OS locale.
        String(format: "%.6f", locale: Locale(identifier: "en_US_POSIX"), abs(value) < 0.0000005 ? 0 : value)
    }
    private static func csv(_ rows: [[String]]) -> String {
        rows.map { row in row.map { "\"" + $0.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }.joined(separator: ",") }
            .joined(separator: "\r\n") + "\r\n"
    }
}
