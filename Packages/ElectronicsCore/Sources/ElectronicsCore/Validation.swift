import Foundation

public struct ElectronicsIssue: Codable, Equatable, Sendable {
    public enum Severity: String, Codable, Sendable { case error, warning }
    public var severity: Severity
    public var code: String
    public var subject: String
    public var message: String
    public var subjectIDs: [UUID]?
    public var position: PCBPoint?
    public init(_ code: String, _ subject: String, _ message: String, severity: Severity = .error) {
        self.code = code; self.subject = subject; self.message = message; self.severity = severity
    }
}

public struct ElectronicsFailure: Error, CustomStringConvertible, Sendable {
    public var issues: [ElectronicsIssue]
    public init(_ issues: [ElectronicsIssue]) { self.issues = issues }
    public var description: String { issues.map { "[\($0.code)] \($0.subject): \($0.message)" }.joined(separator: "\n") }
}

public enum ElectronicsValidation {
    /// Integrity only. An incomplete circuit is editable; dangling references and malformed
    /// geometry are not. This is deliberately distinct from electrical and manufacturing checks.
    public static func integrity(_ design: ElectronicsDesign) -> [ElectronicsIssue] {
        var issues: [ElectronicsIssue] = []
        if let package = design.manufacturing {
            do { try ElectronicsManufacturingImport.requireIntegrity(package) }
            catch let failure as ElectronicsFailure { issues += failure.issues }
            catch { issues.append(.init("manufacturing_cancelled", "Importazione scheda", "Verifica del pacchetto interrotta.")) }
            if !ElectronicsManufacturingImport.isNativeEmpty(design) {
                issues.append(.init("manufacturing_native_board", "Importazione scheda", "Geometria di produzione e progetto nativo non possono sovrapporsi nello stesso documento."))
            }
        }
        func add(_ code: String, _ subject: String, _ message: String) {
            issues.append(.init(code, subject, message))
        }
        func unique<T: Hashable>(_ values: [T], _ subject: String) {
            if Set(values).count != values.count { add("duplicate_identity", subject, "Identità duplicate.") }
        }
        func text(_ value: String, _ subject: String) {
            if value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                add("missing_text", subject, "Valore obbligatorio vuoto.")
            }
        }
        func source(_ value: LibrarySource, _ subject: String) {
            text(value.reference, subject); text(value.license, subject); text(value.sourceRevision, subject)
            if let hash = value.contentSHA256, !hash.matches("^[0-9a-f]{64}$") {
                add("invalid_source_hash", subject, "SHA-256 del sorgente non valido: ripetere l’importazione.")
            }
        }
        let library = design.library
        unique(library.symbols.map(\.key), "symbols"); unique(library.footprints.map(\.key), "footprints")
        unique(library.devices.map(\.key), "devices"); unique(design.components.map(\.id), "components")
        unique(design.nets.map(\.id), "nets"); unique(design.nets.map(\.name), "net names")
        unique(design.connections.map(\.pin), "connections"); unique(design.variants.map(\.id), "variants")
        unique(design.board.placements.map(\.componentID), "placements")
        unique(design.components.map { $0.reference.uppercased() }, "designators")
        text(design.name, "design")
        for key in library.symbols.map(\.key) + library.footprints.map(\.key) + library.devices.map(\.key) {
            if key.revision < 1 { add("invalid_revision", key.id.uuidString, "La revisione deve essere positiva.") }
        }
        for symbol in library.symbols {
            text(symbol.name, "symbol"); source(symbol.source, symbol.name); unique(symbol.pins.map(\.id), symbol.name)
            if symbol.pins.isEmpty { add("empty_symbol", symbol.name, "Nessun pin elettrico.") }
            unique(symbol.pins.compactMap(\.number), symbol.name + " pin numbers")
            for pin in symbol.pins {
                text(pin.name, symbol.name)
                if let n = pin.number { text(n, symbol.name) }
                if let p = pin.position, !ElectronicsGeometry.valid(p) { add("invalid_pin_geometry", symbol.name, "Posizione pin non valida.") }
                if let a = pin.rotationDegrees, !ElectronicsGeometry.validAngle(a) { add("invalid_pin_geometry", symbol.name, "Angolo pin non valido.") }
                if let l = pin.length, !ElectronicsGeometry.valid(l) || l < 0 { add("invalid_pin_geometry", symbol.name, "Lunghezza pin non valida.") }
            }
            issues += LibraryGraphics.validate(symbol.graphics ?? [], subject: symbol.name)
        }
        for footprint in library.footprints {
            text(footprint.name, "footprint"); source(footprint.source, footprint.name)
            unique(footprint.pads.map(\.id), footprint.name)
            issues += LibraryGraphics.validate(footprint.graphics ?? [], subject: footprint.name)
            if footprint.pads.isEmpty { add("empty_footprint", footprint.name, "Nessuna piazzola elettrica.") }
            if !ElectronicsGeometry.valid(footprint.assemblyCentroid) { add("invalid_centroid", footprint.name, "Centro non valido.") }
            for pad in footprint.pads {
                text(pad.number, footprint.name)
                if let layers = pad.sourceLayers {
                    let allowed = pad.drillDiameter == nil ? ["F.Cu", "F.Mask", "F.Paste"] : ["*.Cu", "*.Mask", "F.Mask", "B.Mask"]
                    let copper = pad.drillDiameter == nil ? "F.Cu" : "*.Cu"
                    if !layers.contains(copper) || Set(layers).count != layers.count || !layers.allSatisfy(allowed.contains) {
                        add("invalid_pad_layers", footprint.name, "Strati della piazzola non supportati: controllare la libreria.")
                    }
                }
                if !ElectronicsGeometry.valid(pad.center) || !ElectronicsGeometry.valid(pad.size) ||
                    pad.size.x <= 0 || pad.size.y <= 0 || !ElectronicsGeometry.validAngle(pad.rotationDegrees) {
                    add("invalid_pad", footprint.name, "Piazzola \(pad.number): dimensioni, posizione o angolo non validi.")
                }
                if pad.shape == .circle && pad.size.x != pad.size.y {
                    add("invalid_pad", footprint.name, "Piazzola circolare con diametri diversi.")
                }
                if pad.shape == .roundedRectangle {
                    if let r = pad.cornerRadius, r.isFinite && r >= 0 && r <= min(pad.size.x, pad.size.y) / 2 {} else {
                        add("invalid_corner_radius", footprint.name, "Raggio della piazzola arrotondata mancante o non valido.")
                    }
                } else if pad.cornerRadius != nil { add("invalid_corner_radius", footprint.name, "Raggio presente su una piazzola non arrotondata.") }
                if let drill = pad.drillDiameter, !ElectronicsGeometry.valid(drill) || drill <= 0 || drill >= min(pad.size.x, pad.size.y) {
                    add("invalid_drill", footprint.name, "Foro privo di anello anulare positivo.")
                }
            }
            if let model = footprint.model3D {
                let path = model.relativePath
                if path.isEmpty || path.hasPrefix("/") || path.contains(":") || path.contains("\\") ||
                    path.split(separator: "/").contains("..") || path.contains("\0") {
                    add("invalid_model_path", footprint.name, "Il modello deve riferirsi a un file relativo al progetto.")
                }
                if !model.sha256.matches("^[0-9a-fA-F]{64}$") {
                    add("invalid_model_hash", footprint.name, "SHA-256 del modello mancante o non valido.")
                }
                if ![model.offset.x, model.offset.y, model.offset.z].allSatisfy(ElectronicsGeometry.valid) {
                    add("invalid_model_offset", footprint.name, "Offset del modello non valido.")
                }
            }
        }
        for device in library.devices {
            let subject = device.manufacturerPartNumber
            text(device.manufacturer, subject); text(subject, "device")
            guard let symbol = library.symbols.first(where: { $0.key == device.symbol }),
                  let footprint = library.footprints.first(where: { $0.key == device.footprint }) else {
                add("missing_library_revision", subject, "Simbolo o impronta nella revisione richiesta non presenti."); continue
            }
            let pinIDs = Set(symbol.pins.map(\.id)), padIDs = Set(footprint.pads.map(\.id))
            unique(device.pinMap.map(\.padID), subject)
            if Set(device.pinMap.map(\.padID)) != padIDs || Set(device.pinMap.map(\.pinID)) != pinIDs {
                add("invalid_pin_map", subject, "Mappatura pin/piazzole incompleta o con riferimenti estranei.")
            }
            if let jlc = device.jlc {
                if !jlc.partNumber.matches("^C[0-9]+$") { add("invalid_supplier_number", subject, "Codice JLC/LCSC atteso: C seguito da cifre.") }
                text(jlc.catalogReference, subject)
                for rule in [jlc.topRotation, jlc.bottomRotation].compactMap({ $0 }) {
                    if !ElectronicsGeometry.validAngle(rule.offsetDegrees) { add("invalid_rotation_rule", subject, "Correzione angolare non valida.") }
                    text(rule.evidence, subject)
                }
            }
        }
        for component in design.components {
            if !component.reference.matches("^[A-Za-z][A-Za-z0-9_]*[0-9]+$") {
                add("invalid_designator", component.reference, "Designatore atteso, per esempio R1 o U12.")
            }
            if !library.devices.contains(where: { $0.key == component.device }) {
                add("missing_device_revision", component.reference, "Revisione del componente non presente nel progetto.")
            }
        }
        let componentIDs = Set(design.components.map(\.id)), netIDs = Set(design.nets.map(\.id))
        for net in design.nets { text(net.name, "net") }
        for connection in design.connections {
            let subject = connection.pin.componentID.uuidString
            guard let component = design.components.first(where: { $0.id == connection.pin.componentID }),
                  let device = library.devices.first(where: { $0.key == component.device }),
                  let symbol = library.symbols.first(where: { $0.key == device.symbol }),
                  symbol.pins.contains(where: { $0.id == connection.pin.pinID }) else {
                add("dangling_pin", subject, "Collegamento a un pin inesistente."); continue
            }
            if let net = connection.netID, !netIDs.contains(net) { add("dangling_net", subject, "Rete inesistente.") }
        }
        if !ElectronicsGeometry.valid(design.board.thickness) || design.board.thickness <= 0 {
            add("invalid_thickness", "board", "Spessore non positivo o non finito.")
        }
        if !ElectronicsGeometry.simplePolygon(design.board.outline) { add("invalid_outline", "board", "Contorno degenere o autointersecante.") }
        if !ElectronicsGeometry.valid(design.board.assemblyOrigin) { add("invalid_origin", "board", "Origine non valida.") }
        for placement in design.board.placements {
            if !componentIDs.contains(placement.componentID) { add("dangling_placement", "board", "Posizionamento senza componente.") }
            if !ElectronicsGeometry.valid(placement.position) || !ElectronicsGeometry.validAngle(placement.rotationDegrees) {
                add("invalid_placement", placement.componentID.uuidString, "Posizione o rotazione non valida.")
            }
        }
        for variant in design.variants {
            text(variant.name, "variant"); unique(variant.excludedComponents, variant.name)
            if !Set(variant.excludedComponents).isSubset(of: componentIDs) { add("dangling_variant", variant.name, "Variante con componenti inesistenti.") }
        }
        issues += ElectronicsPCB.integrity(design)
        issues += ElectronicsSchematic.integrity(design)
        return issues
    }

    /// Initial logical checks only: no analog analysis, power-domain solver or full ERC matrix.
    public static func electrical(_ design: ElectronicsDesign, excluding: Set<UUID> = []) -> [ElectronicsIssue] {
        if design.manufacturing != nil {
            return [.init("manufacturing_erc_unavailable", "Scheda importata", "Verifica elettrica non disponibile: il pacchetto non contiene lo schema originale.", severity: .warning)]
        }
        guard integrity(design).isEmpty else { return [.init("invalid_design", "ERC", "Correggere prima gli errori di integrità.")] }
        var issues: [ElectronicsIssue] = []
        var drivers: [UUID: [(name: String, component: UUID, pin: UUID)]] = [:]
        for component in design.components where !excluding.contains(component.id) {
            guard let device = design.library.devices.first(where: { $0.key == component.device }),
                  let symbol = design.library.symbols.first(where: { $0.key == device.symbol }) else { continue }
            for pin in symbol.pins {
                let ref = PinReference(componentID: component.id, pinID: pin.id)
                let connection = design.connections.first { $0.pin == ref }
                let subject = "\(component.reference).\(pin.name)"
                if connection == nil && pin.electricalType != .noConnect {
                    var issue = ElectronicsIssue("unconnected_pin", subject, "Pin senza rete né marcatore NC.", severity: .warning)
                    issue.subjectIDs = [component.id, pin.id]; issues.append(issue)
                }
                if let netID = connection?.netID {
                    if pin.electricalType == .noConnect {
                        var issue = ElectronicsIssue("nc_pin_connected", subject, "Pin NC collegato a una rete.")
                        issue.subjectIDs = [component.id, pin.id, netID]; issues.append(issue)
                    }
                    if pin.electricalType == .output || pin.electricalType == .powerOutput {
                        drivers[netID, default: []].append((subject, component.id, pin.id))
                    }
                }
            }
        }
        for net in design.nets where (drivers[net.id]?.count ?? 0) > 1 {
            let subjects = drivers[net.id]!.sorted { $0.name < $1.name }
            var issue = ElectronicsIssue("multiple_drivers", net.name, "Più uscite sulla rete: \(subjects.map(\.name).joined(separator: ", ")).")
            issue.subjectIDs = [net.id] + subjects.flatMap { [$0.component, $0.pin] }; issues.append(issue)
        }
        issues += ElectronicsSchematic.electricalIssues(design, excluding: excluding)
        return ElectronicsSchematic.locatedIssues(issues, design: design)
    }

    public static func requireIntegrity(_ design: ElectronicsDesign) throws {
        let issues = integrity(design)
        if !issues.isEmpty { throw ElectronicsFailure(issues) }
    }
}

extension String {
    func matches(_ pattern: String) -> Bool { range(of: pattern, options: .regularExpression) != nil }
}
