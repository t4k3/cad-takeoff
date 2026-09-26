import AppKit
import Foundation

/// Installs the «Esporta per Fusion Takeoff» add-in into Fusion 360 (T74), only when the user
/// asks and confirms Fusion's AddIns folder (the app is sandboxed: the folder must be granted).
@MainActor
enum FusionAddInInstaller {
    static let name = "FusionTakeoffExport"

    /// ~/Library/Application Support/Autodesk/Autodesk Fusion 360/API/AddIns (real home, not the sandbox container).
    static var defaultFolder: URL {
        let home = getpwuid(getuid()).flatMap { String(validatingCString: $0.pointee.pw_dir) } ?? NSHomeDirectory()
        return URL(fileURLWithPath: home).appendingPathComponent("Library/Application Support/Autodesk/Autodesk Fusion 360/API/AddIns")
    }

    /// Returns a status message for the status bar.
    static func installWithPanel() -> String {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = defaultFolder
        panel.prompt = "Installa qui"
        panel.message = "Conferma la cartella AddIns di Fusion 360 (Libreria › Application Support › Autodesk › Autodesk Fusion 360 › API › AddIns). L'add-in «Esporta per Fusion Takeoff» verrà copiato qui."
        guard panel.runModal() == .OK, let folder = panel.url else { return "Installazione add-in annullata" }
        do {
            let target = folder.lastPathComponent == name ? folder : folder.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
            for ext in ["py", "manifest"] {
                guard let source = Bundle.main.url(forResource: name, withExtension: ext) else {
                    return "Add-in non trovato nell'app (\(name).\(ext))"
                }
                let destination = target.appendingPathComponent("\(name).\(ext)")
                if FileManager.default.fileExists(atPath: destination.path) { try FileManager.default.removeItem(at: destination) }
                try FileManager.default.copyItem(at: source, to: destination)
            }
            return "Add-in installato. In Fusion: Utilità › Aggiunte › «\(name)» › Esegui (poi parte da solo); comando «Esporta per Fusion Takeoff» nel pannello Script e aggiunte."
        } catch {
            return "Installazione add-in non riuscita: \(error.localizedDescription)"
        }
    }
}
