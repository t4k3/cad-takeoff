import Foundation
import ElectronicsCore

@main
struct ElectronicsImportCLI {
    static func main() {
        do { try run() }
        catch {
            FileHandle.standardError.write(Data("Importazione non riuscita: \(error)\n".utf8))
            exit(1)
        }
    }
    private static func run() throws {
        let args = CommandLine.arguments
        guard (5...7).contains(args.count) else {
            throw NSError(domain: "electronics-import", code: 1, userInfo: [NSLocalizedDescriptionKey:
                "Uso: electronics-import GERBER.zip BOM.csv POSITIONS.csv OUTPUT.ftkc [NOME] [LOTTO]"])
        }
        let output = URL(fileURLWithPath: args[4])
        guard !FileManager.default.fileExists(atPath: output.path) else {
            throw NSError(domain: "electronics-import", code: 2, userInfo: [NSLocalizedDescriptionKey: "Il file di destinazione esiste già."])
        }
        let p = try ElectronicsManufacturingImport.prepare(
            archive: Data(contentsOf: URL(fileURLWithPath: args[1])),
            bom: Data(contentsOf: URL(fileURLWithPath: args[2])),
            positions: Data(contentsOf: URL(fileURLWithPath: args[3])),
            name: args.count > 5 ? args[5] : "Scheda importata",
            lotName: args.count > 6 ? args[6] : "Lotto importato")
        var document = try ElectronicsDocument.empty()
        let command = ElectronicsCommand.manufacturing(.importPackage(p))
        let preview = try ElectronicsCommands.preview(command, document: document, expectedRevision: 0)
        guard preview.canApply else { throw ElectronicsFailure(preview.blockingIssues) }
        try ElectronicsCommands.apply(command, to: &document, expectedRevision: 0)
        let data = try document.encoded()
        guard try ElectronicsDocument.decode(data) == document else {
            throw NSError(domain: "electronics-import", code: 3, userInfo: [NSLocalizedDescriptionKey: "Verifica del documento fallita."])
        }
        try data.write(to: output, options: .withoutOverwriting)
        print("Importati \(p.layers.count) strati, \(p.drills.count) fori, \(p.components.count) componenti; \(p.activeLot?.fittedComponentIDs.count ?? 0) da montare. \(p.bounds.width) × \(p.bounds.height) mm.")
        for issue in preview.issues { print("[\(issue.severity.rawValue)] \(issue.message)") }
    }
}
