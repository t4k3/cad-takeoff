import AppKit
import ElectronicsCore
import Foundation

/// PRODUZIONE (Codex's engine, docs/electronics/FABRICATION.md): the fabrication check and the
/// Gerber/drill/assembly package. Both are pure engine calls run off the main thread; a result
/// counts only for the circuit (identity and open document), revision, profile and variant it was
/// made for. The export is not a change of the circuit (no undo step): the files go to a new
/// folder, complete or not at all, and nothing written before is touched.
extension CircuitModel {
    struct FabricationKey: Equatable, Sendable {
        var designID: UUID
        var epoch: Int
        var revision: UInt64
        var profile: FabricationProfile
        var variant: UUID?
    }

    struct FabricationOutcome: Equatable {
        var folder: URL?
        var message: String
    }

    struct FabricationState: Equatable {
        var key: FabricationKey
        /// Both nil while the check runs.
        var preview: FabricationPreview?
        var failure: String?
    }

    var fabricationKey: FabricationKey? {
        guard let doc = document else { return nil }
        return FabricationKey(designID: doc.design.id, epoch: documentEpoch, revision: doc.revision,
                              profile: fabricationProfile, variant: fabricationVariant)
    }

    /// The check shown, when it is the one of the circuit as it is now.
    var currentFabrication: FabricationState? {
        guard let f = fabrication, f.key == fabricationKey else { return nil }
        return f
    }

    /// The export may start: the current check is done and has no error.
    var canExportFabrication: Bool {
        !fabricationExporting && currentFabrication?.preview?.canExport == true
    }

    func openFabrication() {
        guard document != nil else { return }
        // A variant of another circuit (or removed) is not this one's.
        if let v = fabricationVariant, design?.variants.contains(where: { $0.id == v }) != true { fabricationVariant = nil }
        showFabrication = true
        refreshFabrication()
    }

    /// Closing forgets the check (it is redone on opening) and stops an export in progress.
    func closeFabrication() {
        showFabrication = false
        fabricationTask?.cancel(); fabricationTask = nil
        fabricationToken += 1
        fabrication = nil
        fabricationOutcome = nil
        fabricationExport?.cancel()
    }

    /// Checks the circuit for fabrication in the background (only while the panel is open).
    func refreshFabrication() {
        guard showFabrication, let doc = document, let key = fabricationKey else { return }
        // Already done, or running, for this very circuit/profile/variant.
        if let f = fabrication, f.key == key, f.preview != nil || f.failure != nil || fabricationTask != nil { return }
        fabricationTask?.cancel()
        fabricationToken += 1
        let token = fabricationToken
        fabrication = FabricationState(key: key)
        fabricationTask = Task { [weak self] in
            let result = await Self.offMain { () -> Result<FabricationPreview, CircuitEditError> in
                do { return .success(try ElectronicsFabrication.preview(document: doc, expectedRevision: key.revision, profile: key.profile, variantID: key.variant)) }
                catch { return .failure(CircuitEditError(Self.describe(error))) }
            }
            guard let self, self.fabricationToken == token else { return }
            self.fabricationTask = nil
            guard !Task.isCancelled, self.fabrication?.key == key, self.fabricationKey == key else { return }
            switch result {
            case .success(let p): self.fabrication?.preview = p
            case .failure(let e): self.fabrication?.failure = e.message
            }
        }
    }

    func fabricationReady() async { await fabricationTask?.value }

    /// Esporta…: a folder chosen by the user, then the export in the background (Esc stops it).
    func exportFabricationWithPanel() {
        guard canExportFabrication else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.canCreateDirectories = true
        panel.prompt = "Esporta qui"
        panel.message = "Dove creare la cartella di produzione di «\(title)» (Gerber, forature, BOM e CPL)"
        guard panel.runModal() == .OK, let parent = panel.url else { return }
        startFabricationExport(into: parent, name: "\(title) - produzione")
    }

    func startFabricationExport(into parent: URL, name: String) {
        guard !fabricationExporting else { report("Un export di produzione è già in corso."); return }
        fabricationExport = Task { [weak self] in await self?.exportFabrication(into: parent, name: name) }
    }

    /// Esc / Annulla on an export in progress: nothing is published.
    func cancelFabricationExport() { fabricationExport?.cancel() }

    /// The package, published as the folder `name` inside `parent` (« 2», « 3»… if taken).
    /// Engine and writing happen off the main thread into a hidden folder; the rename that
    /// publishes it runs here on the main actor, right after checking — with no suspension in
    /// between — that the circuit, revision, profile and variant are still the ones exported and
    /// that nobody cancelled.
    @discardableResult
    func exportFabrication(into parent: URL, name: String) async -> URL? {
        guard let doc = document, let key = fabricationKey else { return nil }
        guard !fabricationExporting else { report("Un export di produzione è già in corso."); return nil }
        fabricationExporting = true
        fabricationOutcome = nil
        func tell(_ message: String, _ folder: URL? = nil) { report(message); fabricationOutcome = FabricationOutcome(folder: folder, message: message) }
        defer { fabricationExporting = false; fabricationExport = nil }
        let stale = "Produzione non esportata: il circuito, il profilo o la variante sono cambiati mentre si preparava. Riprova."

        let built = await Self.offMain { () -> Result<FabricationPackage, CircuitEditError> in
            do { return .success(try ElectronicsFabrication.export(document: doc, expectedRevision: key.revision, profile: key.profile, variantID: key.variant)) }
            catch { return .failure(CircuitEditError(Self.describe(error))) }
        }
        guard !Task.isCancelled else { tell("Export di produzione annullato."); return nil }
        guard fabricationKey == key else { tell(stale); return nil }
        let package: FabricationPackage
        switch built {
        case .success(let p): package = p
        case .failure(let e): tell("Produzione non esportata: \(e.message)"); return nil
        }

        let temp: URL
        do { temp = try await stageFabrication(package.files, parent) }
        catch { tell("Produzione non esportata: scrittura non riuscita: \(error.localizedDescription)"); return nil }
        // From here to the rename nothing awaits: the circuit checked is the one published.
        guard !Task.isCancelled, fabricationKey == key else {
            let cancelled = Task.isCancelled
            try? FileManager.default.removeItem(at: temp)
            tell(cancelled ? "Export di produzione annullato." : stale)
            return nil
        }
        do {
            let folder = try Self.publishFabrication(temp, in: parent, name: name)
            tell("Produzione esportata in «\(folder.lastPathComponent)»: \(package.files.count) file (Gerber, forature, BOM e CPL) — da verificare nel visore del produttore", folder)
            return folder
        } catch {
            try? FileManager.default.removeItem(at: temp)
            tell("Produzione non esportata: scrittura non riuscita: \(error.localizedDescription)")
            return nil
        }
    }

    /// Every file into a new hidden folder next to the destination.
    nonisolated static func stageFiles(_ files: [FabricationFile], in parent: URL) throws -> URL {
        let fm = FileManager.default
        let temp = parent.appendingPathComponent(".produzione-\(UUID().uuidString).tmp")
        try fm.createDirectory(at: temp, withIntermediateDirectories: false)
        do {
            for f in files {
                guard !f.name.isEmpty, !f.name.contains("/"), !f.name.hasPrefix(".") else {
                    throw CircuitEditError("nome di file non valido: \(f.name)")
                }
                try Data(f.content.utf8).write(to: temp.appendingPathComponent(f.name), options: .withoutOverwriting)
            }
            return temp
        } catch {
            try? fm.removeItem(at: temp)
            throw error
        }
    }

    /// The staged folder renamed to a free name: it appears complete, never over something else.
    nonisolated static func publishFabrication(_ temp: URL, in parent: URL, name: String) throws -> URL {
        let fm = FileManager.default
        var clean = name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespaces)
        while clean.hasPrefix(".") { clean.removeFirst() }
        if clean.isEmpty { clean = "Produzione" }
        var n = 1
        while true {
            let target = parent.appendingPathComponent(n == 1 ? clean : "\(clean) \(n)")
            do {
                // moveItem refuses an existing destination: no race with another writer.
                try fm.moveItem(at: temp, to: target)
                return target
            } catch CocoaError.fileWriteFileExists {
                n += 1
                if n > 999 { throw CircuitEditError("troppe cartelle «\(clean)» in questa posizione") }
            }
        }
    }
}

extension CircuitEditError: LocalizedError {
    var errorDescription: String? { message }
}
