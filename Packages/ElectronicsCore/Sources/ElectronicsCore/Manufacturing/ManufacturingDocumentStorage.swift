import Foundation

/// Format 8 stores immutable CAM artwork once at document scope. In-memory domain values
/// remain complete, so transaction/undo APIs and standalone ManufacturingPackage Codable
/// are unchanged. Restored states share the pool arrays through Swift copy-on-write.
enum ManufacturingDocumentStorage {
    struct Geometry: Codable, Equatable {
        let layers: [ManufacturingLayer]
        let drills: [ManufacturingDrill]
        let bounds: ManufacturingBounds
        init(_ package: ManufacturingPackage) {
            layers = package.layers; drills = package.drills; bounds = package.bounds
        }
    }
    typealias Pool = [String: Geometry]

    static func pool(for states: [ElectronicsDesign]) throws -> Pool {
        var result: Pool = [:]
        for state in states {
            try Task.checkCancellation()
            guard let package = state.manufacturing else { continue }
            let key = package.id.uuidString, geometry = Geometry(package)
            if let old = result[key], old != geometry {
                throw failure("La stessa scheda contiene geometrie diverse nello storico.")
            }
            result[key] = geometry
        }
        return result
    }

    static func validate(_ stored: Pool, states: [ElectronicsDesign]) throws {
        let used = try pool(for: states)
        for (key, geometry) in stored {
            guard let id = UUID(uuidString: key), key == id.uuidString,
                  used[key] == geometry else {
                throw failure("Archivio geometrie non valido, non usato o diverso dallo storico.")
            }
        }
    }

    struct Design: Encodable {
        let value: ElectronicsDesign
        func encode(to encoder: any Encoder) throws {
            var native = value
            native.manufacturing = nil
            try native.encode(to: encoder)
            if let package = value.manufacturing {
                var c = encoder.container(keyedBy: DesignKeys.self)
                try c.encode(Package(value: package), forKey: .manufacturing)
            }
        }
    }
    struct Edit: Encodable {
        let value: ElectronicsEdit
        func encode(to encoder: any Encoder) throws {
            var c = encoder.container(keyedBy: EditKeys.self)
            try c.encode(value.title, forKey: .title)
            try c.encode(Design(value: value.before), forKey: .before)
            try c.encode(Design(value: value.after), forKey: .after)
        }
    }

    static func design(from decoder: any Decoder, pool: Pool) throws -> ElectronicsDesign {
        let c = try decoder.container(keyedBy: DesignKeys.self)
        // These are the native ElectronicsDesign fields. They retain their original keys,
        // required/optional decoding and domain validation; only CAM geometry is indirect.
        var value = ElectronicsDesign(id: try c.decode(UUID.self, forKey: .id),
            name: try c.decode(String.self, forKey: .name),
            library: try c.decode(ElectronicsLibrary.self, forKey: .library),
            components: try c.decode([CircuitComponent].self, forKey: .components),
            nets: try c.decode([CircuitNet].self, forKey: .nets),
            connections: try c.decode([PinConnection].self, forKey: .connections),
            board: try c.decode(PCBBoard.self, forKey: .board),
            variants: try c.decode([AssemblyVariant].self, forKey: .variants))
        value.schematic = try c.decodeIfPresent(SchematicCircuit.self, forKey: .schematic)
        if c.contains(.manufacturing), try !c.decodeNil(forKey: .manufacturing) {
            value.manufacturing = try package(from: c.superDecoder(forKey: .manufacturing), pool: pool)
        }
        return value
    }

    static func edits(from decoder: any Decoder, pool: Pool) throws -> [ElectronicsEdit] {
        var container = try decoder.unkeyedContainer(), result: [ElectronicsEdit] = []
        while !container.isAtEnd {
            try Task.checkCancellation()
            let c = try container.superDecoder().container(keyedBy: EditKeys.self)
            result.append(.init(title: try c.decode(String.self, forKey: .title),
                                before: try design(from: c.superDecoder(forKey: .before), pool: pool),
                                after: try design(from: c.superDecoder(forKey: .after), pool: pool)))
        }
        return result
    }

    private struct Package: Encodable {
        let value: ManufacturingPackage
        func encode(to encoder: any Encoder) throws {
            var c = encoder.container(keyedBy: PackageKeys.self)
            try c.encode(value.id, forKey: .id)
            try c.encode(value.name, forKey: .name)
            try c.encode(value.id, forKey: .geometryID)
            try c.encode(value.components, forKey: .components)
            try c.encode(value.lots, forKey: .lots)
            try c.encode(value.activeLotID, forKey: .activeLotID)
            try c.encode(value.sources, forKey: .sources)
            try c.encode(value.issues, forKey: .issues)
        }
    }

    private static func package(from decoder: any Decoder, pool: Pool) throws -> ManufacturingPackage {
        let c = try decoder.container(keyedBy: PackageKeys.self)
        let id = try c.decode(UUID.self, forKey: .id)
        let geometry: Geometry
        if c.contains(.geometryID) {
            let reference = try c.decode(UUID.self, forKey: .geometryID)
            guard reference == id, !c.contains(.layers), !c.contains(.drills), !c.contains(.bounds),
                  let stored = pool[reference.uuidString] else {
                throw failure("Riferimento geometrico mancante, ambiguo o appartenente a un’altra scheda.")
            }
            geometry = stored
        } else {
            // Early format-8 documents used complete inline ManufacturingPackage values.
            geometry = try Geometry(from: decoder)
        }
        return .init(id: id, name: try c.decode(String.self, forKey: .name),
            layers: geometry.layers, drills: geometry.drills,
            components: try c.decode([ManufacturingComponent].self, forKey: .components),
            lots: try c.decode([ManufacturingLot].self, forKey: .lots),
            activeLotID: try c.decode(UUID.self, forKey: .activeLotID),
            sources: try c.decode([ManufacturingSource].self, forKey: .sources), bounds: geometry.bounds,
            issues: try c.decode([ElectronicsIssue].self, forKey: .issues))
    }

    private enum DesignKeys: String, CodingKey {
        case manufacturing, schematic, id, name, library, components, nets, connections, board, variants
    }
    private enum PackageKeys: String, CodingKey {
        case id, name, geometryID, layers, drills, components, lots, activeLotID, sources, bounds, issues
    }
    private enum EditKeys: String, CodingKey { case title, before, after }
    private static func failure(_ message: String) -> ElectronicsFailure {
        .init([.init("manufacturing_history_geometry", "Storico scheda", message)])
    }
}
