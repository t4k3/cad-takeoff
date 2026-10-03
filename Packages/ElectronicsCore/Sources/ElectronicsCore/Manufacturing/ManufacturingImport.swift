import Foundation

public enum ElectronicsManufacturingImport {
    private static let namespace = UUID(uuidString: "8A46DC20-C6D3-4F57-9BFA-7D2F4E1A4984")!

    /// Parse all inputs before returning a proposal. No I/O, network or mutation.
    public static func prepare(archive: Data, bom: Data, positions: Data, name: String,
                               lotName: String = "Lotto importato") throws -> ManufacturingPackage {
        try Task.checkCancellation()
        try requireName(name); try requireName(lotName)
        let files = try ManufacturingArchive.read(archive).sorted { $0.name < $1.name }
        let entries = try ManufacturingTables.bom(bom)
        let placements = try ManufacturingTables.positions(positions)
        var layers: [ManufacturingLayer] = [], drills: [ManufacturingDrill] = []
        var sources: [ManufacturingSource] = [], importIssues: [ElectronicsIssue] = []
        var identity = ""
        for file in files {
            try Task.checkCancellation()
            let ext = (file.name as NSString).pathExtension.lowercased()
            let hash = LibraryImportSupport.digest(file.data)
            sources.append(.init(name: file.name, sha256: hash, byteCount: file.data.count))
            let header = String(decoding: file.data.prefix(4096), as: UTF8.self)
            if ["drl", "xln", "exc"].contains(ext) || header.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("M48") {
                drills += try ExcellonReader.read(file.data, name: file.name)
                identity += file.name + "\0" + hash + "\n"
            } else if ["gbr", "ger", "gerber", "gtl", "gbl", "gts", "gbs", "gtp", "gbp", "gto", "gbo", "gm1", "gko"].contains(ext) || header.contains("%FS") || header.contains("TF.FileFunction") {
                if let layer = try GerberReader.read(file.data, name: file.name) {
                    layers.append(layer); identity += file.name + "\0" + hash + "\n"
                }
            } else if ext.hasPrefix("g"), ext.count > 1, ext.dropFirst().allSatisfy(\.isNumber) {
                // Inner copper of a multilayer board (KiCad .g1, .g2…).
                if let layer = try GerberReader.read(file.data, name: file.name) {
                    layers.append(layer); identity += file.name + "\0" + hash + "\n"
                }
            } else if ["pdf", "gbrjob"].contains(ext) || (file.name as NSString).lastPathComponent == ".DS_Store" || file.name.hasPrefix("__MACOSX/") {
                importIssues.append(.init("manufacturing_ancillary_file", file.name, "\(file.name): allegato accessorio non disegnato; provenienza conservata.", severity: .warning))
            } else {
                throw failure("manufacturing_unknown_file", "File non riconosciuto nel pacchetto: \(file.name). Separare gli allegati dai file di produzione.")
            }
        }
        guard Set(layers.map(\.kind)).count == layers.count,
              layers.contains(where: { $0.kind == .profile }),
              layers.contains(where: { $0.kind == .topCopper }),
              layers.contains(where: { $0.kind == .bottomCopper }) else {
            throw failure("manufacturing_layers", "Occorrono contorno e rame superiore/inferiore, senza strati duplicati.")
        }
        let bounds = try profileBounds(layers)
        let id = LibraryImportSupport.id(namespace, identity)
        let byBOM = Dictionary(uniqueKeysWithValues: entries.map { ($0.reference.uppercased(), $0) })
        let byPosition = Dictionary(uniqueKeysWithValues: placements.map { ($0.reference.uppercased(), $0) })
        var refs = Set(byBOM.keys).union(byPosition.keys)
        for layer in layers where [.topCopper, .bottomCopper].contains(layer.kind) {
            for primitive in layer.primitives {
                if let reference = primitive.componentReference, !reference.isEmpty { refs.insert(reference.uppercased()) }
            }
        }
        guard refs.count <= 20_000 else { throw failure("manufacturing_limit", "Troppi componenti: suddividere il pacchetto.") }
        let components = refs.sorted().map { reference in
            let entry = byBOM[reference]
            return ManufacturingComponent(id: LibraryImportSupport.id(id, "component/" + reference), reference: reference,
                                          value: entry?.value, footprint: entry?.footprint,
                                          lcscPartNumber: entry?.lcscPartNumber, placement: byPosition[reference])
        }
        let bomHash = LibraryImportSupport.digest(bom), cplHash = LibraryImportSupport.digest(positions)
        let lotID = LibraryImportSupport.id(id, "lot/" + bomHash + "/" + cplHash + "/" + lotName)
        let lot = ManufacturingLot(id: lotID, name: lotName,
            fittedComponentIDs: components.filter { byBOM[$0.reference]?.fitted == true }.map(\.id).sorted { $0.uuidString < $1.uuidString }, bomSHA256: bomHash)
        sources += [.init(name: "bom.csv", sha256: bomHash, byteCount: bom.count),
                    .init(name: "positions.csv", sha256: cplHash, byteCount: positions.count)]
        let package = ManufacturingPackage(id: id, name: name, layers: layers, drills: drills,
            components: components, lots: [lot], activeLotID: lotID, sources: sources, bounds: bounds, issues: importIssues)
        try requireIntegrity(package)
        return package
    }

    /// Current lot diagnostics. Omissions are intentional; none remove physical artwork.
    public static func diagnostics(_ package: ManufacturingPackage) -> [ElectronicsIssue] {
        let fitted = Set(package.activeLot?.fittedComponentIDs ?? [])
        var result = package.issues
        for c in package.components {
            func warn(_ code: String, _ message: String) {
                var issue = ElectronicsIssue(code, c.reference, message, severity: .warning)
                issue.subjectIDs = [c.id]; issue.position = c.placement?.position; result.append(issue)
            }
            if !fitted.contains(c.id) {
                warn("manufacturing_not_fitted", "\(c.reference): escluso dal lotto; resta presente sulla scheda.")
            } else {
                if c.lcscPartNumber?.isEmpty != false {
                    warn("manufacturing_missing_supplier", "\(c.reference): codice LCSC assente; scegliere il componente prima dell’ordine.")
                }
                if c.placement == nil {
                    warn("manufacturing_missing_position", "\(c.reference): posizione assente dal CPL; verificarla prima del montaggio.")
                }
            }
            if let p = c.placement?.position,
               p.x < package.bounds.minimum.x || p.x > package.bounds.maximum.x ||
               p.y < package.bounds.minimum.y || p.y > package.bounds.maximum.y {
                warn("manufacturing_position_outside", "\(c.reference): centro fuori dall’ingombro della scheda; verificare l’origine del CPL.")
            }
        }
        return result
    }

    static func mutate(_ command: ManufacturingCommand, design: inout ElectronicsDesign) throws {
        switch command {
        case .importPackage(let incoming):
            try requireIntegrity(incoming)
            if var current = design.manufacturing {
                guard current.id == incoming.id, current.layers == incoming.layers,
                      current.drills == incoming.drills, current.bounds == incoming.bounds else {
                    throw failure("manufacturing_different_board", "Il pacchetto appartiene a un’altra scheda: aprire un circuito nuovo.")
                }
                if let settings = incoming.assemblySettings, settings != current.assemblySettings {
                    throw failure("manufacturing_assembly_conflict", "Spessore o impostazioni di assemblaggio diversi: modificare la scheda con il comando dedicato.", [current.id])
                }
                // A new lot may omit entries from BOTH tables. Retain their known metadata/positions.
                for c in incoming.components {
                    if let i = current.components.firstIndex(where: { $0.id == c.id }) {
                        let old = current.components[i]
                        if let binding = c.modelBinding, binding != old.modelBinding {
                            throw failure("manufacturing_assembly_conflict", "\(c.reference): allineamento diverso. Usare il comando del modello senza alterare i lotti precedenti.", [c.id])
                        }
                        for (previous, next) in [(old.value, c.value), (old.footprint, c.footprint), (old.lcscPartNumber, c.lcscPartNumber)] {
                            if let previous, let next, previous != next {
                                throw failure("manufacturing_part_conflict", "\(c.reference): valore, impronta o codice LCSC diverso. I lotti precedenti non vengono modificati: importare questa distinta in un circuito separato.", [c.id])
                            }
                        }
                        if old.value == nil { current.components[i].value = c.value }
                        if old.footprint == nil { current.components[i].footprint = c.footprint }
                        if old.lcscPartNumber == nil { current.components[i].lcscPartNumber = c.lcscPartNumber }
                        if let v = c.placement {
                            if let old = current.components[i].placement, old != v {
                                throw failure("manufacturing_placement_conflict", "\(c.reference): posizione diversa sulla stessa scheda; verificare il CPL prima di aggiungere il lotto.", [c.id])
                            }
                            current.components[i].placement = v
                        }
                    } else { current.components.append(c) }
                }
                for lot in incoming.lots {
                    if let old = current.lots.first(where: { $0.id == lot.id }) {
                        guard old.name == lot.name, old.bomSHA256 == lot.bomSHA256,
                              Set(old.fittedComponentIDs) == Set(lot.fittedComponentIDs) else {
                            throw failure("manufacturing_lot_conflict", "Il lotto importato è già stato modificato: scegliere un nome di lotto nuovo.", [lot.id])
                        }
                    } else {
                        guard !current.lots.contains(where: { $0.name == lot.name }) else {
                            throw failure("manufacturing_lot_name", "Esiste già un lotto con questo nome: assegnare un nome diverso al nuovo lotto.", [lot.id])
                        }
                        current.lots.append(lot)
                    }
                }
                current.components.sort { $0.reference < $1.reference }
                current.activeLotID = incoming.activeLotID
                for source in incoming.sources where !current.sources.contains(source) { current.sources.append(source) }
                design.manufacturing = current
            } else {
                guard isNativeEmpty(design) else {
                    throw failure("manufacturing_native_board", "Il circuito contiene un progetto nativo: importare il pacchetto in un circuito nuovo.")
                }
                design.manufacturing = incoming
                design.name = incoming.name
            }
        case .setFitted(let id, let fitted):
            guard var p = design.manufacturing, p.components.contains(where: { $0.id == id }),
                  let i = p.lots.firstIndex(where: { $0.id == p.activeLotID }) else {
                throw failure("manufacturing_component", "Componente o lotto inesistente: rileggere il pacchetto.", [id])
            }
            p.lots[i].fittedComponentIDs.removeAll { $0 == id }
            if fitted { p.lots[i].fittedComponentIDs.append(id) }
            p.lots[i].fittedComponentIDs.sort { $0.uuidString < $1.uuidString }
            // Preserve ordering for a true no-op (no artificial history).
            if design.manufacturing?.isFitted(id) != fitted { design.manufacturing = p }
        case .addLot(let id, let name):
            try requireName(name)
            guard var p = design.manufacturing, let active = p.activeLot,
                  !p.lots.contains(where: { $0.id == id || $0.name == name }) else {
                throw failure("manufacturing_lot", "Lotto inesistente o nome/identità già usati: scegliere un nome nuovo.", [id])
            }
            p.lots.append(.init(id: id, name: name, fittedComponentIDs: active.fittedComponentIDs))
            p.activeLotID = id; design.manufacturing = p
        case .selectLot(let id):
            guard var p = design.manufacturing, p.lots.contains(where: { $0.id == id }) else {
                throw failure("manufacturing_lot", "Lotto inesistente: rileggere il pacchetto.", [id])
            }
            p.activeLotID = id; design.manufacturing = p
        case .setBoardThickness(let thickness):
            guard var p = design.manufacturing else {
                throw failure("manufacturing_missing", "Aprire una scheda importata prima di impostare lo spessore.")
            }
            p.assemblySettings = thickness.map { .init(boardThickness: $0) }
            design.manufacturing = p
        case .setComponentModel(let id, let binding):
            guard var p = design.manufacturing,
                  let i = p.components.firstIndex(where: { $0.id == id }) else {
                throw failure("manufacturing_component", "Componente inesistente: rileggere la scheda.", [id])
            }
            p.components[i].modelBinding = binding
            design.manufacturing = p
        }
    }

    static func isNativeEmpty(_ design: ElectronicsDesign) -> Bool {
        design.components.isEmpty && design.nets.isEmpty && design.connections.isEmpty &&
        design.board.placements.isEmpty && design.schematic == nil &&
        (design.board.copper.map { $0.tracks.isEmpty && $0.vias.isEmpty && $0.zones.isEmpty && $0.keepouts.isEmpty } ?? true)
    }

    static func profileBounds(_ layers: [ManufacturingLayer]) throws -> ManufacturingBounds {
        let points = layers.filter { $0.kind == .profile }.flatMap(\.primitives)
            .filter(\.isDark).flatMap(\.shapes).filter(\.isDark).flatMap(\.contours).flatMap { $0 }
        guard let first = points.first, points.allSatisfy(ElectronicsGeometry.valid) else {
            throw failure("manufacturing_profile", "Contorno scheda mancante o non valido.")
        }
        var low = first, high = first
        for p in points { low.x = min(low.x, p.x); low.y = min(low.y, p.y); high.x = max(high.x, p.x); high.y = max(high.y, p.y) }
        guard high.x > low.x, high.y > low.y else { throw failure("manufacturing_profile", "Il contorno non delimita una scheda.") }
        return .init(minimum: low, maximum: high)
    }

    static func requireName(_ name: String) throws {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, name.utf8.count <= 512,
              !name.contains("\0") else { throw failure("manufacturing_name", "Nome mancante o troppo lungo: usare fino a 512 byte.") }
    }

    static func failure(_ code: String, _ message: String, _ ids: [UUID] = []) -> ElectronicsFailure {
        var issue = ElectronicsIssue(code, "Importazione scheda", message); issue.subjectIDs = ids
        return ElectronicsFailure([issue])
    }
}
