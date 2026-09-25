import AppKit
import CADCore
import Observation
import UniformTypeIdentifiers

/// A revision-consistent renderer result. Invalid bodies have explicit diagnostics.
struct DesignSnapshot: Equatable, Sendable {
    struct Issue: Equatable, Sendable {
        let featureID: UUID
        let message: String
    }
    let revision: String
    let bodies: [BodySnapshot]
    let issues: [Issue]
}

/// App-level state: the current CAD document plus UI selection. All mutations go through here.
@MainActor
@Observable
final class DesignModel {
    var document = CADDocument(features: [
        Feature(name: "Base", kind: .box(width: 40, depth: 30, height: 5)),
    ]) {
        didSet {
            guard document != oldValue else { return }
            designRevision = UUID().uuidString
            if !applyingAssistantChange { assistantHistory = AssistantHistory() }
        }
    }
    private(set) var designRevision = UUID().uuidString
    @ObservationIgnored var assistantHistory = AssistantHistory()
    @ObservationIgnored var applyingAssistantChange = false
    @ObservationIgnored private var cachedSnapshot: DesignSnapshot?
    var selection: Feature.ID?
    var statusMessage = "Pronto"

    var selectedIndex: Int? { document.features.firstIndex { $0.id == selection } }

    /// Topology comes from feature parameters in CADCore, never from viewport triangles.
    /// A document edit invalidates the cache through designRevision, including undo/reopen.
    func snapshot() -> DesignSnapshot {
        if let cachedSnapshot, cachedSnapshot.revision == designRevision { return cachedSnapshot }
        var bodies: [BodySnapshot] = [], issues: [DesignSnapshot.Issue] = []
        let groups = Dictionary(grouping: document.features, by: \.id)
        var duplicateIDs = Set<UUID>()
        for feature in document.features where feature.isVisible {
            guard groups[feature.id]?.count == 1 else {
                if duplicateIDs.insert(feature.id).inserted {
                    issues.append(.init(featureID: feature.id, message: "Identificatore di parte duplicato nel documento."))
                }
                continue
            }
            do {
                bodies.append(try PrimitiveKernel.build(feature).snapshot(revision: designRevision))
            } catch {
                issues.append(.init(featureID: feature.id, message: error.localizedDescription))
            }
        }
        let result = DesignSnapshot(revision: designRevision, bodies: bodies, issues: issues)
        cachedSnapshot = result
        return result
    }

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

    /// The inspector and the assistant use the same transaction history for colour edits.
    func setFeatureColor(_ id: UUID, color: PartColor) throws {
        guard let i = document.features.firstIndex(where: { $0.id == id }) else {
            throw CADToolFailure("Geometria non trovata.")
        }
        var next = document
        next.features[i].color = color
        commitEdit(next, selected: selection, title: "Colore: \(next.features[i].name)", changed: [id])
    }

    func commitEdit(_ next: CADDocument, selected: UUID?, title: String, changed: [UUID]) {
        guard next != document else { return }
        let entry = AssistantHistory.Entry(before: document, after: next, selectionBefore: selection,
                                           selectionAfter: selected, title: title, changed: changed)
        applyingAssistantChange = true
        document = next; selection = selected
        applyingAssistantChange = false
        assistantHistory.undo.append(entry)
        if assistantHistory.undo.count > 50 { assistantHistory.undo.removeFirst() }
        assistantHistory.redo.removeAll()
        statusMessage = title
    }

    func newDesign() {
        assistantHistory = AssistantHistory()
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
            assistantHistory = AssistantHistory()
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

    /// Export visible parts, or the explicit feature even when hidden. Does not change the scene.
    func export3MFData(featureID: UUID? = nil) throws -> Data {
        let features: [Feature]
        if let featureID {
            guard let feature = document.features.first(where: { $0.id == featureID }) else {
                throw CADToolFailure("Geometria non trovata.")
            }
            features = [feature]
        } else { features = document.features.filter(\.isVisible) }
        let parts = try features.map { feature -> ThreeMFPart in
            try CADToolValidation.feature(feature)
            return ThreeMFPart(id: feature.id, name: feature.name, mesh: feature.buildMesh(), color: feature.color)
        }
        return try ThreeMFExporter.archive(parts: parts)
    }

    func export3MFWithPanel() {
        do {
            let data = try export3MFData()
            let panel = NSSavePanel()
            panel.allowedContentTypes = [UTType(filenameExtension: "3mf") ?? UTType(importedAs: "org.3mfconsortium.3mf", conformingTo: .data)]
            panel.nameFieldStringValue = "Design.3mf"
            guard panel.runModal() == .OK, let url = panel.url else { return }
            try data.write(to: url, options: .atomic)
            statusMessage = "Esportato \(url.lastPathComponent) — parti e colori; verificare i filamenti nello slicer"
        } catch { statusMessage = "Errore export 3MF: \(error.localizedDescription)" }
    }
}
