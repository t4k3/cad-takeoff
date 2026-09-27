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
    public private(set) var formatVersion: Int = 2
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
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }

    public static func decode(_ data: Data) throws -> Self {
        guard data.count <= 64 * 1024 * 1024 else { throw failure("document_too_large", "Documento oltre 64 MiB: suddividere il progetto.") }
        return try JSONDecoder().decode(Self.self, from: data)
    }

    private enum CodingKeys: String, CodingKey { case formatVersion, revision, design, past, future }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let inputVersion = try c.decode(Int.self, forKey: .formatVersion)
        guard (1...2).contains(inputVersion) else { throw Self.failure("unsupported_version", "Versione elettronica non supportata: \(inputVersion). Aggiornare l’app prima di aprire il file.") }
        // v1 has no E1 library geometry fields; missing optional fields decode as nil. Always
        // write v2 so old E0 readers reject the document instead of silently losing those fields.
        formatVersion = 2
        revision = try c.decode(UInt64.self, forKey: .revision)
        design = try c.decode(ElectronicsDesign.self, forKey: .design)
        past = try c.decode([ElectronicsEdit].self, forKey: .past)
        future = try c.decode([ElectronicsEdit].self, forKey: .future)
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
