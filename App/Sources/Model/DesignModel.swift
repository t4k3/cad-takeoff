import AppKit
import CADCore
import Observation
import UniformTypeIdentifiers

/// App-level state: the current CAD document plus UI selection. All mutations go through here.
@MainActor
@Observable
final class DesignModel {
    var document = CADDocument(features: [
        Feature(name: "Base", kind: .box(width: 40, depth: 30, height: 5)),
    ])
    var selection: Feature.ID?
    var statusMessage = "Pronto"

    var selectedIndex: Int? { document.features.firstIndex { $0.id == selection } }

    // MARK: Features

    func addBox() { add(Feature(name: "Box \(document.features.count + 1)", kind: .box(width: 20, depth: 20, height: 20))) }
    func addCylinder() { add(Feature(name: "Cilindro \(document.features.count + 1)", kind: .cylinder(radius: 10, height: 20))) }
    func addHexPrism() {
        add(Feature(name: "Esagono \(document.features.count + 1)",
                    kind: .extrude(profile: .regularPolygon(sides: 6, radius: 10), height: 10)))
    }

    private func add(_ f: Feature) {
        document.features.append(f)
        selection = f.id
    }

    func deleteSelected() {
        guard let i = selectedIndex else { return }
        document.features.remove(at: i)
        selection = nil
    }

    func newDesign() {
        document = CADDocument()
        selection = nil
        statusMessage = "Nuovo design"
    }

    // MARK: Files

    static let ftkType = UTType(exportedAs: "com.takeoff.fusiontakeoff.design", conformingTo: .json)

    func saveWithPanel() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [Self.ftkType]
        panel.nameFieldStringValue = "Design.ftk"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try document.encoded().write(to: url)
            statusMessage = "Salvato \(url.lastPathComponent)"
        } catch { statusMessage = "Errore salvataggio: \(error.localizedDescription)" }
    }

    func openWithPanel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [Self.ftkType, .json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            document = try CADDocument.decode(Data(contentsOf: url))
            selection = nil
            statusMessage = "Aperto \(url.lastPathComponent)"
        } catch { statusMessage = "Errore apertura: \(error.localizedDescription)" }
    }

    func exportSTLWithPanel() {
        let mesh = document.buildMesh()
        guard !mesh.isEmpty else { statusMessage = "Niente da esportare"; return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "stl") ?? .data]
        panel.nameFieldStringValue = "Design.stl"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try STLExporter.binary(mesh).write(to: url)
            let r = MeshValidator.validate(mesh)
            statusMessage = "Esportato \(url.lastPathComponent) — \(mesh.triangleCount) triangoli, "
                + (r.isWatertight ? "chiuso ✓" : "NON chiuso (\(r.boundaryEdges) bordi aperti)")
        } catch { statusMessage = "Errore export: \(error.localizedDescription)" }
    }
}
