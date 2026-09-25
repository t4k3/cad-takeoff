import CADCore
import Foundation

/// File I/O for the project library (T73, Claude). Kept outside `App/Sources/Model`
/// (Codex's area) and built only on the Model's existing API, with the same logic as
/// `openWithPanel`: a loaded design starts a fresh undo history and no selection.
extension DesignModel {
    func load(from url: URL) throws {
        let doc = try CADDocument.decode(Data(contentsOf: url))
        document = doc
        assistantHistory = AssistantHistory()
        selection = nil
        statusMessage = "Aperto \(url.deletingPathExtension().lastPathComponent)"
    }

    func write(to url: URL) throws {
        try document.encoded().write(to: url, options: .atomic)
    }
}
