import CADCore
import Foundation

/// File I/O for the project library (T73). Sketches travel inside the document (T81).
/// A loaded design starts a fresh undo history and no selection.
extension DesignModel {
    func load(from url: URL) throws {
        let doc = try CADDocument.decode(Data(contentsOf: url))
        let name = url.deletingPathExtension().lastPathComponent
        replaceDocument(doc, status: doc.importReport.map { "Aperto \(name) — \($0)" } ?? "Aperto \(name)")
    }

    func write(to url: URL) throws {
        try document.encoded().write(to: url, options: .atomic)
    }
}
