import Foundation
import ElectronicsCore

@main
struct ElectronicsLibraryCLI {
    static func main() {
        do { try run(Array(CommandLine.arguments.dropFirst())) }
        catch {
            let message = (error as? ElectronicsFailure)?.description ?? "File non leggibile o formato non valido: controllare i percorsi e il JSON."
            FileHandle.standardError.write(Data((message + "\n").utf8)); exit(1)
        }
    }
    static func run(_ args: [String]) throws {
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        func read(_ i: Int) throws -> Data { try Data(contentsOf: URL(fileURLWithPath: args[i])) }
        func write<T: Encodable>(_ value: T, _ path: String) throws {
            guard !FileManager.default.fileExists(atPath: path) else {
                throw ElectronicsFailure([.init("output_exists", path, "Il file esiste già: scegliere un nuovo percorso.")])
            }
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(value).write(to: URL(fileURLWithPath: path), options: .withoutOverwriting)
            print("Libreria salvata: \(path)")
        }
        switch args.first {
        case "kicad-footprint" where args.count == 4:
            let context = try decoder.decode(LibraryImportContext.self, from: read(2))
            try write(KiCadLibraryImporter.footprint(read(1), context: context), args[3])
        case "kicad-symbol" where args.count == 5:
            let context = try decoder.decode(LibraryImportContext.self, from: read(2))
            try write(KiCadLibraryImporter.symbol(read(1), name: args[3], context: context), args[4])
        case "easyeda-footprint" where args.count == 5:
            let context = try decoder.decode(LibraryImportContext.self, from: read(2))
            try write(EasyEDAStandardImporter.footprint(read(1), name: args[3], context: context), args[4])
        case "catalog" where args.count == 4:
            struct Metadata: Decodable { var columns: CatalogColumns; var sourceReference: String; var observedAt: Date }
            let meta = try decoder.decode(Metadata.self, from: read(2))
            try write(ComponentCatalogImporter.csv(read(1), columns: meta.columns, sourceReference: meta.sourceReference, observedAt: meta.observedAt), args[3])
        case let action? where ["apply-import", "preview-import"].contains(action) && args.count == 5:
            var document = try ElectronicsDocument.decode(read(1))
            let imported = try decoder.decode(LibraryImportResult.self, from: read(2))
            guard let revision = UInt64(args[3]) else { throw ElectronicsFailure([.init("invalid_revision", "documento", "Revisione non valida.")]) }
            if args[0] == "preview-import" {
                try write(ElectronicsLibraryCommands.preview(.importLibrary(imported), document: document, expectedRevision: revision), args[4])
            } else {
                try ElectronicsLibraryCommands.apply(.importLibrary(imported), to: &document, expectedRevision: revision)
                try write(document, args[4])
            }
        default:
            throw ElectronicsFailure([.init("usage", "librerie", "Usare: kicad-footprint input contesto.json output | kicad-symbol input contesto.json nome output | easyeda-footprint input contesto.json nome output | catalog input meta.json output | preview-import documento bundle revisione output | apply-import documento bundle revisione output.")])
        }
    }
}
