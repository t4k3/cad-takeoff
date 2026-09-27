import Foundation
import ElectronicsCore

@main
struct ElectronicsCheck {
    static func main() {
        do { try run() }
        catch {
            FileHandle.standardError.write(Data("\(error)\n".utf8))
            exit(1)
        }
    }

    static func run() throws {
        let args = CommandLine.arguments
        guard args.count == 3 || args.count == 4 else {
            throw ElectronicsFailure([.init("usage", "electronics-check", "electronics-check documento.json cartella-output [UUID-variante]")])
        }
        let data = try Data(contentsOf: URL(fileURLWithPath: args[1]))
        let document = try ElectronicsDocument.decode(data)
        var variantID: UUID?
        if args.count == 4 {
            guard let id = UUID(uuidString: args[3]) else { throw ElectronicsFailure([.init("invalid_variant", args[3], "UUID non valido.")]) }
            variantID = id
        }
        let result = try ElectronicsAssembly.export(document, variantID: variantID)
        let output = URL(fileURLWithPath: args[2], isDirectory: true)
        guard !FileManager.default.fileExists(atPath: output.path) else {
            throw ElectronicsFailure([.init("output_exists", output.path, "La cartella di uscita deve essere nuova.")])
        }
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        try result.bomCSV.write(to: output.appendingPathComponent("BOM.csv"), atomically: true, encoding: .utf8)
        try result.cplCSV.write(to: output.appendingPathComponent("CPL.csv"), atomically: true, encoding: .utf8)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(result).write(to: output.appendingPathComponent("assembly.json"), options: .atomic)
        print("Dati assemblaggio: \(result.instances3D.count) istanze 3D; revisione \(result.documentRevision).")
        print("Solo dati di assemblaggio E0: non è un rilascio per fabbricazione.")
        for issue in result.issues { print("\(issue.severity.rawValue): [\(issue.code)] \(issue.subject): \(issue.message)") }
    }
}
