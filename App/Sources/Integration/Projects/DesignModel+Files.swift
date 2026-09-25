import CADCore
import Foundation

/// File I/O for the project library (T73, Claude). Kept outside `App/Sources/Model`
/// (Codex's area) and built only on the Model's existing API, with the same logic as
/// `openWithPanel`: a loaded design starts a fresh undo history and no selection.
extension DesignModel {
    func load(from url: URL, sketches: SketchStore? = nil) throws {
        let data = try Data(contentsOf: url)
        let doc = try CADDocument.decode(data)
        sketches?.load(fromFile: data)
        document = doc
        assistantHistory = AssistantHistory()
        selection = nil
        statusMessage = "Aperto \(url.deletingPathExtension().lastPathComponent)"
    }

    func write(to url: URL, sketches: SketchStore? = nil) throws {
        let data = try document.encoded()
        try (sketches.map { try $0.merged(into: data) } ?? data).write(to: url, options: .atomic)
    }
}
