import Foundation

public struct ElectronicsEdit: Codable, Equatable, Sendable {
    public let title: String
    public let before: ElectronicsDesign
    public let after: ElectronicsDesign
}

/// Separate versioned document until the application adapter is agreed with Claude.
/// The history is persisted. Revision is monotonic even across undo/redo, so assistant calls
/// cannot reuse a stale revision after an ABA (edit -> undo) transition.
public struct ElectronicsDocument: Codable, Equatable, Sendable {
    public private(set) var formatVersion: Int = 8
    public private(set) var revision: UInt64 = 0
    public private(set) var design: ElectronicsDesign
    public private(set) var past: [ElectronicsEdit] = []
    public private(set) var future: [ElectronicsEdit] = []

    public init(design: ElectronicsDesign) throws {
        try ElectronicsValidation.requireIntegrity(design)
        self.design = design
    }

    public mutating func edit(title: String, expectedRevision: UInt64,
                              _ mutation: (inout ElectronicsDesign) throws -> Void) throws {
        try checkRevision(expectedRevision)
        guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw failure("missing_title", "Titolo della modifica mancante.") }
        var candidate = design
        try mutation(&candidate)
        guard candidate.id == design.id else { throw failure("changed_design_id", "L’identità del progetto non può cambiare.") }
        try ElectronicsValidation.requireIntegrity(candidate)
        try Self.checkLibraryRevisions([candidate] + allStates)
        _ = try ManufacturingDocumentStorage.pool(for: [candidate] + allStates)
        guard candidate != design else { return }
        let step = ElectronicsEdit(title: title, before: design, after: candidate)
        design = candidate; past.append(step); future.removeAll(); revision += 1
    }

    public mutating func undo(expectedRevision: UInt64) throws {
        try checkRevision(expectedRevision)
        guard let step = past.popLast() else { return }
        design = step.before; future.append(step); revision += 1
    }

    public mutating func redo(expectedRevision: UInt64) throws {
        try checkRevision(expectedRevision)
        guard let step = future.popLast() else { return }
        design = step.after; past.append(step); revision += 1
    }

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        if !allStates.contains(where: { $0.manufacturing != nil }) {
            encoder.outputFormatting.insert(.prettyPrinted)
        }
        let data = try encoder.encode(self)
        guard data.count <= 64 * 1024 * 1024 else {
            throw Self.failure("document_too_large", "Documento oltre 64 MiB: suddividere il progetto prima di salvarlo.")
        }
        return data
    }

    public static func decode(_ data: Data) throws -> Self {
        guard data.count <= 64 * 1024 * 1024 else { throw failure("document_too_large", "Documento oltre 64 MiB: suddividere il progetto.") }
        return try JSONDecoder().decode(Self.self, from: data)
    }

    private enum CodingKeys: String, CodingKey { case formatVersion, revision, design, past, future, manufacturingGeometry }
    public func encode(to encoder: any Encoder) throws {
        let pool = try ManufacturingDocumentStorage.pool(for: allStates)
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(formatVersion, forKey: .formatVersion)
        try c.encode(revision, forKey: .revision)
        try c.encode(ManufacturingDocumentStorage.Design(value: design), forKey: .design)
        try c.encode(past.map { ManufacturingDocumentStorage.Edit(value: $0) }, forKey: .past)
        try c.encode(future.map { ManufacturingDocumentStorage.Edit(value: $0) }, forKey: .future)
        if !pool.isEmpty { try c.encode(pool, forKey: .manufacturingGeometry) }
    }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let inputVersion = try c.decode(Int.self, forKey: .formatVersion)
        guard (1...8).contains(inputVersion) else { throw Self.failure("unsupported_version", "Versione elettronica non supportata: \(inputVersion). Aggiornare l’app prima di aprire il file.") }
        // Missing optional fields decode as nil. Older readers must reject CAM data,
        // rather than silently drop artwork and manufacturing lots on save.
        formatVersion = 8
        revision = try c.decode(UInt64.self, forKey: .revision)
        let geometry = try c.decodeIfPresent(ManufacturingDocumentStorage.Pool.self, forKey: .manufacturingGeometry) ?? [:]
        guard inputVersion == 8 || geometry.isEmpty else {
            throw Self.failure("unsupported_version", "Archivio geometrie presente in un formato precedente.")
        }
        design = try ManufacturingDocumentStorage.design(from: c.superDecoder(forKey: .design), pool: geometry)
        past = try ManufacturingDocumentStorage.edits(from: c.superDecoder(forKey: .past), pool: geometry)
        future = try ManufacturingDocumentStorage.edits(from: c.superDecoder(forKey: .future), pool: geometry)
        if inputVersion < 8, allStates.contains(where: { $0.manufacturing != nil }) {
            throw Self.failure("unsupported_version", "Dati di produzione presenti in un formato precedente: correggere la versione del documento.")
        }
        try ManufacturingDocumentStorage.validate(geometry, states: allStates)
        for state in allStates {
            guard state.id == design.id else { throw Self.failure("invalid_history", "Lo storico contiene un altro progetto.") }
            try ElectronicsValidation.requireIntegrity(state)
        }
        try Self.checkLibraryRevisions(allStates)
        guard past.last.map({ $0.after == design }) ?? true,
              future.last.map({ $0.before == design }) ?? true,
              zip(past, past.dropFirst()).allSatisfy({ $0.after == $1.before }),
              zip(future, future.dropFirst()).allSatisfy({ $0.before == $1.after }),
              (past + future).allSatisfy({ !$0.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
            throw Self.failure("invalid_history", "La catena dello storico non corrisponde al documento.")
        }
    }

    private var allStates: [ElectronicsDesign] { [design] + (past + future).flatMap { [$0.before, $0.after] } }
    private func checkRevision(_ expected: UInt64) throws {
        guard revision == expected else { throw failure("stale_revision", "Il progetto è cambiato: rileggere prima di modificare.") }
        guard revision < UInt64.max else { throw failure("revision_overflow", "Contatore revisioni esaurito.") }
    }
    private static func checkLibraryRevisions(_ states: [ElectronicsDesign]) throws {
        var symbols: [LibraryRevision: SymbolDefinition] = [:]
        var footprints: [LibraryRevision: FootprintDefinition] = [:]
        var devices: [LibraryRevision: DeviceDefinition] = [:]
        for state in states {
            for item in state.library.symbols {
                if let old = symbols[item.key], old != item { throw failure("changed_library_revision", "Simbolo modificato senza nuova revisione.") }
                symbols[item.key] = item
            }
            for item in state.library.footprints {
                if let old = footprints[item.key], old != item { throw failure("changed_library_revision", "Impronta modificata senza nuova revisione.") }
                footprints[item.key] = item
            }
            for item in state.library.devices {
                if let old = devices[item.key], old != item { throw failure("changed_library_revision", "Dispositivo modificato senza nuova revisione.") }
                devices[item.key] = item
            }
        }
    }
    private func failure(_ code: String, _ message: String) -> ElectronicsFailure { Self.failure(code, message) }
    private static func failure(_ code: String, _ message: String) -> ElectronicsFailure {
        ElectronicsFailure([.init(code, "document", message)])
    }
}
