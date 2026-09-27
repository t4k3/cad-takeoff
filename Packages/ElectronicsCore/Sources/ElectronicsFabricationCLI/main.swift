import Foundation
import ElectronicsCore

@main
struct FabricationCLI {
    static func main() {
        do { try run() }
        catch {
            FileHandle.standardError.write(Data(("Export rifiutato: \(error)\n").utf8))
            exit(1)
        }
    }
    static func run() throws {
        guard CommandLine.arguments.count == 3 else {
            throw ElectronicsFailure([.init("usage","CLI","Uso: electronics-fabrication documento.ftkc nuova-cartella-output")])
        }
        let input = URL(fileURLWithPath:CommandLine.arguments[1])
        let output = URL(fileURLWithPath:CommandLine.arguments[2]).standardizedFileURL
        let fm = FileManager.default
        guard !fm.fileExists(atPath:output.path) else {
            throw ElectronicsFailure([.init("output_exists","CLI","La cartella di destinazione esiste già: sceglierne una nuova.")])
        }
        let document = try ElectronicsDocument.decode(Data(contentsOf:input))
        let package = try ElectronicsFabrication.export(document:document,expectedRevision:document.revision)
        // Build the complete package first. Write a sibling staging directory, then one rename.
        let parent = output.deletingLastPathComponent()
        try fm.createDirectory(at:parent,withIntermediateDirectories:true)
        let staging = parent.appendingPathComponent(".fabrication-"+UUID().uuidString,isDirectory:true)
        try fm.createDirectory(at:staging,withIntermediateDirectories:false)
        defer { try? fm.removeItem(at:staging) }
        for file in package.files { try Data(file.content.utf8).write(to:staging.appendingPathComponent(file.name),options:.atomic) }
        try fm.moveItem(at:staging,to:output)
        print("PASS export: \(package.files.count) file, revisione \(document.revision), \(package.preview.drills.count) fori PTH; \(package.preview.issues.count) avvisi da verificare. Profilo generico non qualificato sul produttore.")
    }
}
