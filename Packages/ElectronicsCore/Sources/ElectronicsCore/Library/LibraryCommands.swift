import Foundation

public enum ElectronicsLibraryCommand: Codable, Equatable, Sendable {
    case importLibrary(LibraryImportResult)
    case createDevice(DeviceDefinition)

    public var title: String {
        switch self {
        case .importLibrary: "Importa libreria"
        case .createDevice: "Crea componente"
        }
    }
}

public struct LibraryCommandPreview: Codable, Equatable, Sendable {
    public var baseRevision: UInt64
    public var library: ElectronicsLibrary
    public var issues: [ElectronicsIssue]
    public var revisionDiffs: [LibraryRevisionDiff]
}

/// One typed command path for the UI, chat and MCP. Preview changes a value copy only;
/// confirming runs the same validation on the current revision and creates one undo step.
public enum ElectronicsLibraryCommands {
    public static func preview(_ command: ElectronicsLibraryCommand, document: ElectronicsDocument,
                               expectedRevision: UInt64) throws -> LibraryCommandPreview {
        var copy = document
        let issues = try apply(command, to: &copy, expectedRevision: expectedRevision)
        let diffs = try ElectronicsLibraryComparison.compare(current: document.design, proposedLibrary: copy.design.library)
        return .init(baseRevision: document.revision, library: copy.design.library, issues: issues, revisionDiffs: diffs)
    }

    @discardableResult
    public static func apply(_ command: ElectronicsLibraryCommand, to document: inout ElectronicsDocument,
                             expectedRevision: UInt64) throws -> [ElectronicsIssue] {
        var issues: [ElectronicsIssue] = []
        try document.edit(title: command.title, expectedRevision: expectedRevision) { design in
            switch command {
            case let .importLibrary(bundle):
                let original = try LibraryImportSupport.text(Data(bundle.originalSource.utf8))
                guard LibraryImportSupport.digest(Data(original.utf8)) == bundle.sourceSHA256,
                      (bundle.library.symbols.map(\.source) + bundle.library.footprints.map(\.source)).allSatisfy({ $0.contentSHA256 == bundle.sourceSHA256 }),
                      !bundle.issues.contains(where: { $0.severity == .error }) else {
                    throw LibraryImportSupport.error("invalid_import_bundle", "libreria", "Sorgente modificato o import con errori: ripetere l’importazione.")
                }
                try ElectronicsValidation.requireLibrary(bundle.library)
                try merge(bundle.library.symbols, into: &design.library.symbols, key: \.key)
                try merge(bundle.library.footprints, into: &design.library.footprints, key: \.key)
                try merge(bundle.library.devices, into: &design.library.devices, key: \.key)
                issues = bundle.issues
            case let .createDevice(device):
                // Pin assignments are explicit; the number-matching helper below never commits them.
                try merge([device], into: &design.library.devices, key: \.key)
            }
        }
        return issues
    }

    /// Proposal only, useful in the mapping preview. Matching labels is not a datasheet check.
    /// Ambiguous or missing physical pin numbers cause an error rather than an invented pinout.
    public static func suggestedPinMap(symbol: SymbolDefinition, footprint: FootprintDefinition) throws -> [PinPadMapping] {
        let pins = symbol.pins.compactMap { pin in pin.number.map { ($0, pin.id) } }
        guard pins.count == symbol.pins.count, Set(pins.map(\.0)).count == pins.count else {
            throw LibraryImportSupport.error("ambiguous_pin_numbers", symbol.name, "Numerazione pin assente o ambigua: assegnare le piazzole esplicitamente.")
        }
        let byNumber = Dictionary(uniqueKeysWithValues: pins)
        var mapping: [PinPadMapping] = []
        for pad in footprint.pads {
            guard let pin = byNumber[pad.number] else {
                throw LibraryImportSupport.error("unmatched_pad", pad.number, "Nessun pin corrispondente: verificare la piedinatura nel datasheet.", id: pad.id)
            }
            mapping.append(.init(pinID: pin, padID: pad.id))
        }
        guard Set(mapping.map(\.pinID)) == Set(symbol.pins.map(\.id)) else {
            throw LibraryImportSupport.error("unmatched_pin", symbol.name, "Alcuni pin non hanno una piazzola: verificare simbolo e package.")
        }
        return mapping
    }

    private static func merge<T: Equatable>(_ incoming: [T], into current: inout [T], key: KeyPath<T, LibraryRevision>) throws {
        for item in incoming {
            if let old = current.first(where: { $0[keyPath: key] == item[keyPath: key] }) {
                guard old == item else { throw LibraryImportSupport.error("library_revision_conflict", item[keyPath: key].id.uuidString,
                    "Revisione già presente con contenuto diverso: creare una nuova revisione.", id: item[keyPath: key].id) }
            } else { current.append(item) }
        }
    }
}
