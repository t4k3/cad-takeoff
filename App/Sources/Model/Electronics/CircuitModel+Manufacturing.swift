import AppKit
import ElectronicsCore
import Foundation
import UniformTypeIdentifiers

/// CIRCUITI › PRODUZIONE › Importa: a board as the manufacturer receives it — Gerber ZIP, BOM and
/// positions (CPL) — read by the engine (T108) into CAM artwork and assembly lots. Nothing here
/// parses a file: the app picks the three files, runs the engine's `prepare` and preview off the
/// main thread for the circuit it was started on, and confirms the same command as one undo step.
/// A component missing from the BOM stays on the board, excluded from the lot, never deleted.
extension CircuitModel {
    /// The three files of one import, the two tables told apart by the engine's readers.
    struct ManufacturingFiles: Equatable, Sendable {
        var archive: URL
        var bom: URL
        var positions: URL
    }

    struct ManufacturingProposal {
        var urls: [URL]
        var files: ManufacturingFiles
        var package: ManufacturingPackage
        var command: ElectronicsCommand
        var issues: [ElectronicsIssue]
        var canApply: Bool
        var key: ImportKey
        /// The document the command applies to: the open circuit (same board: a new lot) or a new,
        /// empty circuit (the open one has a native design or another board).
        var target: ElectronicsDocument
        var inNewCircuit: Bool
        /// A lot of the same board: what it changes (nil for a new board).
        var addsLotTo: String?
    }

    /// The open circuit is a board imported from manufacturing files: CAM artwork and lots, no
    /// native schematic or copper to edit.
    var isManufacturing: Bool { design?.manufacturing != nil }
    var manufacturing: ManufacturingPackage? { design?.manufacturing }

    /// PRODUZIONE › Importa: the Gerber ZIP, the BOM and the positions, chosen together in one
    /// panel (the files stay where they are; nothing is copied).
    func importManufacturingWithPanel() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.zip, .commaSeparatedText, .plainText]
        panel.message = "Scegli insieme i tre file del produttore: lo ZIP dei Gerber, la BOM (.csv) e le posizioni CPL (.csv)"
        panel.prompt = "Importa"
        guard panel.runModal() == .OK else { return }
        do {
            if document == nil {
                let zip = panel.urls.first { $0.pathExtension.lowercased() == "zip" }
                try newCircuit(name: zip?.deletingPathExtension().lastPathComponent ?? "Scheda importata")
            }
            prepareManufacturingImport(panel.urls)
        } catch {
            report("Importazione non avviata: \(Self.describe(error))")
        }
    }

    /// The lot name proposed for an import: the first one on a new board, a new name for another
    /// lot of the board already open (a different BOM under an old name would be refused).
    var defaultLotName: String { isManufacturing ? nextLotName() : "Lotto importato" }

    /// Reads the chosen files and prepares the import off the main thread — which CSV is which
    /// decided there by the engine's own table readers; nothing changes until
    /// `confirmManufacturingImport`, and the proposal counts only for the circuit it was made on.
    func prepareManufacturingImport(_ urls: [URL], lotName: String? = nil) {
        guard let doc = document, let key = importKey else { return }
        let lotName = lotName ?? defaultLotName
        cancelImport()
        let zips = urls.filter { $0.pathExtension.lowercased() == "zip" }
        guard zips.count == 1, urls.count == 3 else {
            report("Servono tre file: uno ZIP con i Gerber e le forature, la BOM e le posizioni (CSV). Scelti: \(urls.map(\.lastPathComponent).joined(separator: ", ")).")
            return
        }
        importing = zips[0].lastPathComponent
        importingCAM = true
        let token = UUID()
        importRequest = token
        let read = readLibraryFile
        let name = zips[0].deletingPathExtension().lastPathComponent
        importTask = Task { [weak self] in
            let built: Result<ManufacturingProposal, CircuitEditError>
            do {
                var data: [URL: Data] = [:]
                for url in urls { data[url] = try await read(url) }
                let loaded = data
                built = await Self.offMain {
                    Self.manufacturingProposal(urls: urls, data: loaded, name: name, lotName: lotName, document: doc, key: key)
                }
            } catch {
                built = .failure(CircuitEditError(Self.describe(error)))
            }
            guard let self, self.importRequest == token else { return }
            self.importing = nil
            guard !Task.isCancelled, self.importKey == key else { return }
            switch built {
            case .success(let proposal): self.manufacturingProposal = proposal
            case .failure(let e): self.report("Importazione di \(name) non riuscita: \(e.message)")
            }
        }
    }

    /// The same files again under another lot name (the sheet's field).
    func renameImportedLot(_ name: String) {
        guard let p = manufacturingProposal, name != p.package.activeLot?.name else { return }
        prepareManufacturingImport(p.urls, lotName: name)
    }

    /// Which table is which: the one the engine reads as positions (X, Y, rotation, side) is the
    /// CPL, the other the BOM.
    nonisolated static func manufacturingFiles(_ urls: [URL], data: [URL: Data]) throws -> ManufacturingFiles {
        let zips = urls.filter { $0.pathExtension.lowercased() == "zip" }
        let tables = urls.filter { $0.pathExtension.lowercased() != "zip" }
        guard zips.count == 1, tables.count == 2 else {
            throw CircuitEditError("Servono tre file: uno ZIP con i Gerber e le forature, la BOM e le posizioni (CSV).")
        }
        let asPositions = tables.map { (try? ManufacturingTables.positions(data[$0] ?? Data())) != nil }
        guard asPositions[0] != asPositions[1] else {
            throw CircuitEditError("Non riesco a distinguere la BOM dalle posizioni (\(tables.map(\.lastPathComponent).joined(separator: ", "))): le posizioni hanno sigla, X, Y, rotazione e lato.")
        }
        return ManufacturingFiles(archive: zips[0], bom: asPositions[0] ? tables[1] : tables[0], positions: asPositions[0] ? tables[0] : tables[1])
    }

    /// The engine's package and preview: on the open circuit when it takes it (empty, or the same
    /// board: a new lot), else on a new empty circuit.
    nonisolated static func manufacturingProposal(urls: [URL], data: [URL: Data], name: String, lotName: String,
                                                  document: ElectronicsDocument, key: ImportKey) -> Result<ManufacturingProposal, CircuitEditError> {
        do {
            let files = try manufacturingFiles(urls, data: data)
            let package = try ElectronicsManufacturingImport.prepare(archive: data[files.archive] ?? Data(), bom: data[files.bom] ?? Data(),
                                                                     positions: data[files.positions] ?? Data(),
                                                                     name: name, lotName: lotName)
            try Task.checkCancellation()
            let command = ElectronicsCommand.manufacturing(.importPackage(package))
            var target = document, inNew = false
            let preview: ElectronicsCommandPreview
            do {
                preview = try ElectronicsCommands.preview(command, document: target, expectedRevision: target.revision)
            } catch let f as ElectronicsFailure where f.issues.contains(where: { ["manufacturing_native_board", "manufacturing_different_board", "manufacturing_native_edit"].contains($0.code) }) {
                target = try ElectronicsDocument.empty(name: name)
                inNew = true
                preview = try ElectronicsCommands.preview(command, document: target, expectedRevision: target.revision)
            }
            let lot = document.design.manufacturing?.id == package.id && !inNew ? document.design.manufacturing?.name : nil
            return .success(ManufacturingProposal(urls: urls, files: files, package: package, command: command,
                                                  issues: preview.issues, canApply: preview.canApply, key: key,
                                                  target: target, inNewCircuit: inNew, addsLotTo: lot))
        } catch {
            return .failure(CircuitEditError(describe(error)))
        }
    }

    /// Conferma: the same command, one step — on the open circuit, or as a new circuit (after
    /// asking about unsaved changes of the open one).
    func confirmManufacturingImport() {
        guard let p = manufacturingProposal else { return }
        manufacturingProposal = nil
        guard importKey == p.key else {
            report("Importazione non applicata: il circuito è cambiato dopo l'anteprima. Rifai l'importazione.")
            return
        }
        // The unsaved-changes alert runs a modal loop: the circuit may change meanwhile.
        if p.inNewCircuit {
            guard confirmDiscard() else { return }
            guard importKey == p.key else {
                report("Importazione non applicata: il circuito è cambiato durante la conferma. Rifai l'importazione.")
                return
            }
        }
        var doc = p.target
        do {
            try ElectronicsCommands.apply(p.command, to: &doc, expectedRevision: doc.revision)
        } catch {
            report("Importazione non riuscita: \(Self.describe(error))")
            return
        }
        installManufacturing(doc, asNewCircuit: p.inNewCircuit)
        let fitted = p.package.activeLot?.fittedComponentIDs.count ?? 0
        report("Importata \(p.package.name): \(p.package.layers.count) strati, \(p.package.drills.count) fori, \(fitted) di \(p.package.components.count) componenti nel lotto")
    }

    // MARK: Lots

    func setFitted(_ component: UUID, _ fitted: Bool) { run(.manufacturing(.setFitted(componentID: component, fitted: fitted))) }
    func selectLot(_ id: UUID) { run(.manufacturing(.selectLot(id))) }

    /// A new lot, a copy of the one shown, under a name not used yet.
    func addLot(named name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        run(.manufacturing(.addLot(id: UUID(), name: trimmed)))
    }

    func nextLotName() -> String {
        let names = Set(manufacturing?.lots.map(\.name) ?? [])
        return (2...).lazy.map { "Lotto \($0)" }.first { !names.contains($0) }!
    }

    // MARK: Picking

    /// The CAM index of the open package (built off the main thread once per board: lots do not
    /// change the artwork).
    func refreshManufacturingSnapshot() {
        guard let package = manufacturing else { camSnapshotTask?.cancel(); camSnapshot = nil; camSnapshotKey = nil; return }
        // Lots only choose who is mounted; a new lot can add components or positions.
        let key = CAMSnapshot.Key(packageID: package.id, epoch: documentEpoch, components: package.components)
        if camSnapshotKey == key { return }
        camSnapshotKey = key
        camSnapshot = nil
        camSnapshotTask?.cancel()
        camSnapshotTask = Task { [weak self] in
            let built = await Self.offMain { try? ManufacturingSnapshot(package: package) }
            guard let self, !Task.isCancelled, self.camSnapshotKey == key, let built else { return }
            self.camSnapshot = .init(key: key, snapshot: built)
        }
    }

    /// The component under a board point (its placement marker), else nil.
    func manufacturingComponent(at point: PCBPoint, tolerance: Double) -> UUID? {
        guard let snap = camSnapshot?.snapshot else { return nil }
        return snap.pick(point: point, tolerance: tolerance).first { $0.kind == .component }?.id
    }
}

struct CAMSnapshot: Sendable {
    struct Key: Equatable, Sendable { var packageID: UUID; var epoch: Int; var components: [ManufacturingComponent] }
    var key: Key
    var snapshot: ManufacturingSnapshot
}
