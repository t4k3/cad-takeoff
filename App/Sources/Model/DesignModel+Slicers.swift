import AppKit
import Foundation

/// STAMPA › Invia a: the visible bodies as a 3MF (parts and colours, fine) opened straight in a
/// slicer installed on this Mac — Bambu Studio, OrcaSlicer, Snapmaker Orca, PrusaSlicer, Cura.
extension DesignModel {
    struct Slicer: Identifiable, Hashable {
        let id: String      // bundle identifier
        let name: String
        let url: URL
    }

    static let knownSlicers: [(id: String, name: String)] = [
        ("com.bambulab.bambu-studio", "Bambu Studio"),
        ("com.softfever3d.orca-slicer", "OrcaSlicer"),
        ("com.snapmaker.snapmaker-orca", "Snapmaker Orca"),
        ("com.prusa3d.slic3r", "PrusaSlicer"),
        ("com.prusa3d.PrusaSlicer", "PrusaSlicer"),
        ("nl.ultimaker.cura", "Ultimaker Cura"),
    ]

    /// The slicers installed here, in the order above (one entry per app).
    static var installedSlicers: [Slicer] {
        var seen = Set<URL>()
        return knownSlicers.compactMap { s in
            guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: s.id), seen.insert(url).inserted else { return nil }
            return Slicer(id: s.id, name: s.name, url: url)
        }
    }

    /// Writes the 3MF next to the app's temporary files and opens it with `slicer`.
    func send(to slicer: Slicer, name: String) {
        do {
            let (data, open) = try export3MF(fine: true, forSlicer: true)
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent("Invio allo slicer", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let clean = name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
                .trimmingCharacters(in: .whitespaces)
            let url = folder.appendingPathComponent((clean.isEmpty ? "Design" : clean) + ".3mf")
            try data.write(to: url, options: .atomic)
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            NSWorkspace.shared.open([url], withApplicationAt: slicer.url, configuration: configuration) { [weak self] _, error in
                Task { @MainActor in
                    self?.statusMessage = error.map { "\(slicer.name) non ha aperto il file: \($0.localizedDescription)" }
                        ?? "Inviato a \(slicer.name): \(url.lastPathComponent) — parti e colori, verifica i filamenti" + Self.openNote(open)
                }
            }
        } catch {
            statusMessage = "Invio a \(slicer.name) non riuscito: \(error.localizedDescription)"
        }
    }
}
