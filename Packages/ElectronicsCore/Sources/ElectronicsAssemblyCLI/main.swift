import ElectronicsCore
import Foundation

/// Read-only derived geometry for independent QA and adapters. Does not replace the
/// production export or modify the input document. Output must not already exist.
private struct Report: Encodable {
    let schemaVersion = 1
    let sourceRevision: UInt64
    let packageID: UUID
    let boardThickness: Double
    let isBoardThicknessAssumed: Bool
    let boardParts: [ManufacturingAssemblyPart]
    let instances: [ManufacturingAssemblyInstance]
    let issues: [ElectronicsIssue]
}

do {
    guard CommandLine.arguments.count == 3 else {
        throw NSError(domain: "electronics-assembly", code: 1, userInfo: [NSLocalizedDescriptionKey:
            "Uso: electronics-assembly documento.ftkc nuovo-report.json"])
    }
    let input = URL(fileURLWithPath: CommandLine.arguments[1])
    let output = URL(fileURLWithPath: CommandLine.arguments[2])
    let size = try input.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max
    guard size <= 64 * 1024 * 1024 else {
        throw NSError(domain: "electronics-assembly", code: 2, userInfo: [NSLocalizedDescriptionKey: "Documento oltre 64 MiB."])
    }
    let document = try ElectronicsDocument.decode(Data(contentsOf: input))
    guard let package = document.design.manufacturing else {
        throw NSError(domain: "electronics-assembly", code: 3, userInfo: [NSLocalizedDescriptionKey: "Occorre una scheda importata da Gerber/BOM/CPL."])
    }
    let snapshot = try ManufacturingAssemblySnapshot(package: package)
    let report = Report(sourceRevision: document.revision, packageID: snapshot.packageID,
        boardThickness: snapshot.boardThickness, isBoardThicknessAssumed: snapshot.isBoardThicknessAssumed,
        boardParts: snapshot.boardParts, instances: snapshot.instances, issues: snapshot.issues)
    let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    try encoder.encode(report).write(to: output, options: [.withoutOverwriting])
    let ready = snapshot.instances.filter { $0.fitted && !$0.parts.isEmpty }.count
    print("Geometria assemblata: \(ready) componenti montati con modello; \(snapshot.instances.count) riferimenti; \(snapshot.boardParts.count) parti substrato. \(output.path)")
} catch {
    if let failure = error as? ElectronicsFailure {
        for issue in failure.issues { FileHandle.standardError.write(Data((issue.message + "\n").utf8)) }
    } else { FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8)) }
    exit(1)
}
