import Foundation

/// EasyEDA Standard standalone footprint JSON (docType=4), deliberately separate from Pro.
/// Source coordinates are 10 mil = 0.254 mm, independent of the canvas display unit.
public enum EasyEDAStandardImporter {
    public static func footprint(_ data: Data, name: String, context: LibraryImportContext) throws -> LibraryImportResult {
        let original = try LibraryImportSupport.text(data)
        let object: Any
        do { object = try JSONSerialization.jsonObject(with: data) }
        catch { throw problem("invalid_easyeda_json", name, "JSON interrotto o non valido: esportare nuovamente l’impronta EasyEDA Standard.") }
        guard let json = object as? [String: Any],
              let head = json["head"] as? [String: Any], let shapes = json["shape"] as? [String],
              scalar(head["docType"]) == "4" else {
            throw problem("unsupported_easyeda_document", "file", "Esportare un’impronta autonoma EasyEDA Standard (docType 4); schede complete e Pro non sono supportati.")
        }
        guard let x = Double(scalar(head["x"]) ?? ""), let y = Double(scalar(head["y"]) ?? ""), x.isFinite, y.isFinite else {
            throw problem("missing_source_origin", name, "Origine del componente mancante: esportare nuovamente l’impronta.")
        }
        func point(_ xValue: Double, _ yValue: Double) -> PCBPoint { .init((xValue - x) * 0.254, (y - yValue) * 0.254) }
        var source = context.source; source.contentSHA256 = LibraryImportSupport.digest(data)
        var footprint = FootprintDefinition(key: context.key, name: name, pads: [], assemblyCentroid: context.assemblyCentroid, source: source)
        var graphics: [LibraryGraphic] = [], issues: [ElectronicsIssue] = []
        let graphicLayers = ["3": "F.SilkS", "4": "B.SilkS", "12": "Dwgs.User", "13": "F.Fab"]
        for (index, shape) in shapes.enumerated() {
            try Task.checkCancellation()
            let f = shape.components(separatedBy: "~")
            func field(_ i: Int) throws -> String {
                guard f.indices.contains(i) else { throw problem("invalid_easyeda_shape", name, "Elemento \(index + 1) interrotto: riesportare il file.") }
                return f[i]
            }
            func number(_ i: Int) throws -> Double {
                guard let n = Double(try field(i)), n.isFinite else { throw problem("invalid_easyeda_number", name, "Numero non valido nell’elemento \(index + 1).") }
                return n
            }
            switch f.first {
            case "PAD":
                let layer = try field(6), sourceID = try field(12)
                guard !sourceID.isEmpty else { throw problem("missing_source_identity", name, "Identità della piazzola mancante.") }
                let id = LibraryImportSupport.id(context.key.id, "pad/" + sourceID)
                guard layer == "1", try number(9) == 0 else {
                    throw LibraryImportSupport.error("unsupported_easyeda_pad", name, "Per ora importare piazzole SMD sul lato superiore; fori e altri stack richiedono verifica del formato.", id: id)
                }
                guard try field(7).isEmpty else { throw problem("pad_has_net", name, "Piazzola già assegnata a una rete: esportare una libreria, non un’istanza PCB.") }
                let width = try number(4) * 0.254, height = try number(5) * 0.254
                let kind: PadShape
                switch try field(1) {
                case "RECT": kind = .rectangle
                case "ELLIPSE" where abs(width - height) < 1e-9: kind = .circle
                case "OVAL": kind = .oval
                default: throw LibraryImportSupport.error("unsupported_easyeda_pad", name, "Forma piazzola non supportata senza approssimazioni.", id: id)
                }
                let rotation = ElectronicsGeometry.normalizedDegrees(try number(11))
                guard rotation.truncatingRemainder(dividingBy: 90) == 0 else {
                    throw LibraryImportSupport.error("unsupported_easyeda_rotation", name, "Piazzole oblique da verificare: il primo importatore supporta angoli multipli di 90°.", id: id)
                }
                // Advanced hole, slot and mask expansions must not be silently discarded.
                for i in [13, 14, 17, 18] where f.indices.contains(i) && !f[i].isEmpty && f[i] != "0" {
                    throw problem("unsupported_easyeda_pad", name, "Fori/asole o espansioni di maschera personalizzate non supportati.")
                }
                let center = try point(number(2), number(3))
                if !(try field(10)).isEmpty {
                    // RECT outlines may be redundant, but custom outlines must be checked rather than lost.
                    let values = try field(10).split(whereSeparator: { $0 == " " || $0 == "," }).map { Double($0) }
                    guard kind == .rectangle, values.count == 8, values.allSatisfy({ $0?.isFinite == true }) else {
                        throw problem("unsupported_easyeda_outline", name, "Contorno personalizzato della piazzola non supportato.")
                    }
                    let halfX = (rotation == 90 || rotation == 270 ? height : width) / 2
                    let halfY = (rotation == 90 || rotation == 270 ? width : height) / 2
                    let expected = [PCBPoint(center.x-halfX,center.y-halfY), .init(center.x+halfX,center.y-halfY),
                                    .init(center.x+halfX,center.y+halfY), .init(center.x-halfX,center.y+halfY)]
                    let actual = stride(from: 0, to: 8, by: 2).map { point(values[$0]!, values[$0+1]!) }
                    guard expected.allSatisfy({ p in actual.contains { hypot(p.x-$0.x,p.y-$0.y) < 1e-5 } }) else {
                        throw problem("unsupported_easyeda_outline", name, "Contorno diverso dalla piazzola rettangolare dichiarata: controllare la libreria.")
                    }
                }
                var pad = FootprintPad(id: id, number: try field(8), center: center, size: .init(width, height), shape: kind, rotationDegrees: rotation)
                pad.sourceLayers = ["F.Cu", "F.Mask", "F.Paste"]; footprint.pads.append(pad)
            case "TRACK":
                guard let layer = graphicLayers[try field(2)], try field(3).isEmpty else {
                    throw problem("unsupported_copper_graphic", name, "Traccia o geometria sul rame: il file non è una semplice impronta supportata.")
                }
                let values = try field(4).split(whereSeparator: { $0 == " " || $0 == "," }).map { Double($0) }
                guard values.count >= 4, values.count % 2 == 0, values.allSatisfy({ $0?.isFinite == true }) else { throw problem("invalid_easyeda_shape", name, "Polilinea non valida.") }
                let points = stride(from: 0, to: values.count, by: 2).map { point(values[$0]!, values[$0+1]!) }
                graphics.append(.init(id: LibraryImportSupport.id(context.key.id, "graphic/" + (try field(5))), kind: .polyline,
                                      points: points, layer: layer, strokeWidth: try number(1) * 0.254))
            case "TEXT":
                guard graphicLayers[try field(7)] != nil else { throw problem("unsupported_copper_graphic", name, "Testo sul rame non supportato.") }
                issues.append(.init("source_graphic_not_rendered", name, "Testo conservato nel sorgente; visualizzazione non ancora disponibile.", severity: .warning))
            case "SVGNODE":
                issues.append(.init("unresolved_3d_model", name, "Riferimento 3D conservato nel sorgente: collegare il modello verificato.", severity: .warning))
            default: throw problem("unsupported_easyeda_shape", name, "Elemento \(f.first ?? "?") non supportato: importazione interrotta senza modificare il progetto.")
            }
        }
        footprint.graphics = graphics
        if let props = head["c_para"] as? [String: Any] {
            footprint.properties = props.compactMapValues(scalar)
        }
        issues.append(.init("centroid_requires_review", name, "Verificare il centro di presa indicato prima dell’assemblaggio.", severity: .warning))
        return try LibraryImportSupport.result(library: .init(footprints: [footprint]), issues: issues, format: "easyeda-standard-footprint", original: original)
    }
    private static func scalar(_ value: Any?) -> String? {
        if let value = value as? String { return value }
        if let value = value as? NSNumber { return value.stringValue }
        return nil
    }
    private static func problem(_ code: String, _ subject: String, _ message: String) -> ElectronicsFailure {
        LibraryImportSupport.error(code, subject, message)
    }
}
