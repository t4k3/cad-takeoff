import ElectronicsCore
import Foundation

/// The imported board with its components (T111, Codex's `ManufacturingAssemblySnapshot`):
/// seen as Gerber, assembled from above (2D, one side at a time) or in 3D. The engine places
/// every model; the app only shows it, picks with the same component UUIDs as the list, and
/// edits a component's model and alignment as one previewed step.
extension CircuitModel {
    enum CAMView: String, CaseIterable, Identifiable {
        case gerber = "Gerber", assembly = "Assemblata", threeD = "3D"
        var id: String { rawValue }
    }

    struct AssemblyKey: Equatable, Sendable { var packageID: UUID; var epoch: Int; var revision: UInt64 }

    struct AssemblyState: Sendable {
        var key: AssemblyKey
        var snapshot: ManufacturingAssemblySnapshot
    }

    /// A model/alignment change being tried on one component: the engine's preview of exactly
    /// the command OK will apply, and the component as it would be.
    struct AlignDraft {
        var componentID: UUID
        var binding: ManufacturingModelBinding?
        var baseRevision: UInt64
        var epoch: Int
        var preview: ManufacturingAssemblyInstance?
        var refused: String?
        var command: ElectronicsCommand { .manufacturing(.setComponentModel(componentID: componentID, binding: binding)) }
    }

    /// The assembly of the open board, rebuilt off the main thread when it changes (lots, models,
    /// thickness); the previous one stays shown until the new one is ready.
    func refreshAssembly() {
        guard let package = manufacturing, let doc = document else {
            assemblyTask?.cancel(); assembly = nil; assemblyKey = nil; alignDraft = nil; return
        }
        let key = AssemblyKey(packageID: package.id, epoch: documentEpoch, revision: doc.revision)
        if assemblyKey == key { return }
        assemblyKey = key
        if let d = alignDraft, d.baseRevision != doc.revision || d.epoch != documentEpoch { alignDraft = nil }
        // Another board or another opening: the old assembly is not this one's, even for a moment.
        // A new revision of the same board (a lot, a model) keeps it shown while the new one builds,
        // and hands it to the engine to reuse the unchanged substrate.
        let previous = assembly.flatMap { $0.key.packageID == key.packageID && $0.key.epoch == key.epoch ? $0.snapshot : nil }
        if previous == nil { assembly = nil; assemblyFailure = nil }
        assemblyTask?.cancel()
        assemblyTask = Task { [weak self] in
            let built = await Self.offMain { () -> Result<ManufacturingAssemblySnapshot, CircuitEditError> in
                do { return .success(try ManufacturingAssemblySnapshot(package: package, previous: previous)) }
                catch { return .failure(CircuitEditError(Self.describe(error))) }
            }
            guard let self, !Task.isCancelled, self.assemblyKey == key else { return }
            switch built {
            case .success(let s): self.assembly = AssemblyState(key: key, snapshot: s); self.assemblyFailure = nil
            case .failure(let e): self.assemblyFailure = e.message
            }
        }
    }

    func assemblyReady() async { await assemblyTask?.value }

    /// The component under a board point in the assembled view (its body's outline, or its CPL
    /// centre when it has no model), on the side shown.
    func assemblyComponent(at point: PCBPoint, tolerance: Double) -> UUID? {
        guard let s = assembly?.snapshot else { return nil }
        return s.pick(point: point, tolerance: tolerance, side: assemblySide, includeExcluded: showExcluded)
            .first { $0.kind == .component }?.id
    }

    func assemblyInstance(_ id: UUID?) -> ManufacturingAssemblyInstance? {
        guard let id else { return nil }
        return assembly?.snapshot.instances.first { $0.id == id }
    }

    // MARK: Board thickness

    /// nil: back to the declared 1.6 mm estimate.
    func setBoardThickness(_ mm: Double?) { run(.manufacturing(.setBoardThickness(mm))) }

    // MARK: Model and alignment (preview, then OK or Annulla)

    /// Starts (or changes) the draft of a component's model and alignment; the engine previews it
    /// off the main thread. Nothing changes until `confirmAlignment`.
    func draftAlignment(_ componentID: UUID, _ binding: ManufacturingModelBinding?) {
        guard let doc = document else { return }
        var draft = AlignDraft(componentID: componentID, binding: binding, baseRevision: doc.revision, epoch: documentEpoch)
        alignDraft = draft
        let command = draft.command, revision = doc.revision, epoch = documentEpoch
        // The saved assembly lets the engine reuse the substrate (no new triangulation per key).
        let previous = assembly.flatMap { $0.key.packageID == doc.design.manufacturing?.id && $0.key.epoch == epoch ? $0.snapshot : nil }
        alignTask?.cancel()
        alignTask = Task { [weak self] in
            let result = await Self.offMain { () -> Result<ManufacturingAssemblyInstance?, CircuitEditError> in
                do {
                    let p = try ElectronicsCommands.preview(command, document: doc, expectedRevision: revision)
                    guard let package = p.design.manufacturing else { return .success(nil) }
                    let s = try ManufacturingAssemblySnapshot(package: package, previous: previous)
                    return .success(s.instances.first { $0.id == componentID })
                } catch { return .failure(CircuitEditError(Self.describe(error))) }
            }
            guard let self, !Task.isCancelled, self.alignDraft?.componentID == componentID,
                  self.alignDraft?.binding == binding, self.document?.revision == revision,
                  self.documentEpoch == epoch else { return }
            switch result {
            case .success(let instance): draft.preview = instance; draft.refused = nil
            case .failure(let e): draft.preview = nil; draft.refused = e.message
            }
            self.alignDraft = draft
        }
    }

    func alignmentPreviewReady() async { await alignTask?.value }

    /// OK: the previewed command, one undo step — only on the revision it was previewed on.
    func confirmAlignment() {
        guard let d = alignDraft else { return }
        guard d.refused == nil else { report("Allineamento non applicabile: \(d.refused!)"); return }
        // OK only on a finished preview: the engine has seen exactly this command.
        guard d.preview != nil else { report("Attendi l'anteprima dell'allineamento."); return }
        guard d.epoch == documentEpoch, d.baseRevision == document?.revision else {
            alignDraft = nil
            report("Allineamento non applicato: la scheda è cambiata dopo l'anteprima. Rifallo.")
            return
        }
        alignDraft = nil
        run(d.command, expectedRevision: d.baseRevision)
    }

    func cancelAlignment() { alignTask?.cancel(); alignDraft = nil }
}
