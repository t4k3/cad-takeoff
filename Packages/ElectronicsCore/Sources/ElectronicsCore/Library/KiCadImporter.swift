import Foundation

public enum KiCadLibraryImporter {
    public static func footprint(_ data: Data, context: LibraryImportContext) throws -> LibraryImportResult {
        let original = try LibraryImportSupport.text(data)
        var reader = SExpressionReader(original); let root = try reader.read()
        guard ["footprint", "module"].contains(root.name) else { throw root.invalid("File impronta .kicad_mod richiesto.") }
        try root.allowed(["version", "generator", "generator_version", "layer", "tedit", "descr", "tags", "attr", "property",
                          "fp_text", "fp_line", "fp_rect", "fp_circle", "fp_arc", "fp_poly", "pad", "model", "uuid",
                          "embedded_fonts"])
        if let layer = try root.one("layer"), try layer.value(1) != "F.Cu" {
            throw layer.invalid("Impronta non sul lato anteriore: esportare dalla libreria, non da una scheda.", code: "unsupported_side")
        }
        var source = context.source; source.contentSHA256 = LibraryImportSupport.digest(data)
        var footprint = FootprintDefinition(key: context.key, name: try root.value(1), pads: [],
                                            assemblyCentroid: context.assemblyCentroid, source: source)
        var issues: [ElectronicsIssue] = []
        if let attr = try root.one("attr") {
            let attributes = try attr.children.dropFirst().map { item -> String in
                guard let value = item.atom else { throw attr.invalid("Attributi impronta non validi.") }; return value
            }
            guard attributes.allSatisfy({ ["smd", "through_hole"].contains($0) }) else {
                throw attr.invalid("Esclusioni di assemblaggio o attributi speciali richiedono un supporto esplicito: controllare l’impronta.", code: "unsupported_component_policy")
            }
        }
        var countByNumber: [String: Int] = [:]
        for (i, node) in root.all("pad").enumerated() {
            try Task.checkCancellation()
            let number = try node.value(1)
            let occurrence = countByNumber[number, default: 0]; countByNumber[number] = occurrence + 1
            let sourceID = try node.one("uuid")?.value(1) ?? "\(number)/\(occurrence)"
            let id = LibraryImportSupport.id(context.key.id, "pad/" + sourceID)
            do { footprint.pads.append(try pad(node, id: id)) }
            catch let error as ElectronicsFailure {
                throw ElectronicsFailure(error.issues.map { var x = $0; x.subjectIDs = [id]; x.subject = "\(footprint.name), piazzola \(number), riga \(node.line)"; return x })
            }
            if i >= 100_000 { throw node.invalid("Troppe piazzole.") }
        }
        footprint.graphics = try graphics(root.children, context: context, footprint: true, issues: &issues)
        footprint.properties = try properties(root)
        if let description = try root.one("descr")?.value(1) { footprint.properties?["Description"] = description }
        if !root.all("model").isEmpty {
            issues.append(.init("unresolved_3d_model", footprint.name, "Riferimento 3D conservato nel sorgente: collegare e verificare il modello prima dell’assieme.", severity: .warning))
        }
        issues.append(.init("centroid_requires_review", footprint.name, "Verificare il centro di presa indicato: il formato impronta non lo certifica.", severity: .warning))
        return try LibraryImportSupport.result(library: .init(footprints: [footprint]), issues: issues,
                                               format: "kicad-footprint", original: original)
    }

    public static func symbol(_ data: Data, name: String, context: LibraryImportContext) throws -> LibraryImportResult {
        let original = try LibraryImportSupport.text(data)
        var reader = SExpressionReader(original); let root = try reader.read()
        guard root.name == "kicad_symbol_lib" else { throw root.invalid("Libreria simboli .kicad_sym richiesta.") }
        let definitions = root.all("symbol")
        var visited = Set<String>()
        func resolve(_ name: String, depth: Int = 0) throws -> [SExpression] {
            guard depth < 32, visited.insert(name).inserted else { throw root.invalid("Ereditarietà simboli circolare o troppo profonda.") }
            let matches = try definitions.filter { try $0.value(1) == name }
            guard matches.count == 1 else { throw root.invalid("Simbolo \(name) assente o ambiguo.") }
            let definition = matches[0]
            if let parent = try definition.one("extends") { return try resolve(parent.value(1), depth: depth + 1) + [definition] }
            return [definition]
        }
        let chain = try resolve(name)
        var props: [String: String] = [:]
        var units: [SExpression] = []
        var issues: [ElectronicsIssue] = []
        for item in chain {
            try item.allowed(["extends", "pin_names", "pin_numbers", "exclude_from_sim", "in_bom", "on_board", "property", "symbol", "embedded_fonts", "power"])
            props.merge(try properties(item)) { _, new in new }
            for flag in ["in_bom", "on_board"] {
                if let field = try item.one(flag), try field.value(1) != "yes" {
                    throw field.invalid("Simboli esclusi da BOM o scheda richiedono una politica esplicita: controllare il simbolo.", code: "unsupported_component_policy")
                }
            }
            if !item.all("symbol").isEmpty {
                guard units.isEmpty else { throw item.invalid("Sovrascrittura della geometria di un simbolo ereditato non ancora supportata.", code: "unsupported_symbol_override") }
                units = item.all("symbol")
            }
            if try item.one("pin_names") != nil || item.one("pin_numbers") != nil {
                issues.append(.init("source_pin_display", name, "Preferenze di visualizzazione dei pin conservate nel sorgente: verificare l’anteprima del simbolo.", severity: .warning))
            }
        }
        var source = context.source; source.contentSHA256 = LibraryImportSupport.digest(data)
        var result = SymbolDefinition(key: context.key, name: name, pins: [], source: source)
        var graphicNodes: [SExpression] = []
        for unit in units {
            let unitName = try unit.value(1), parts = unitName.split(separator: "_")
            guard parts.count >= 3, let u = Int(parts[parts.count - 2]), let style = Int(parts.last!), (0...1).contains(u), (0...1).contains(style) else {
                throw unit.invalid("Simboli multisezione o rappresentazioni alternative non ancora supportati.", code: "unsupported_symbol_unit")
            }
            for pin in unit.all("pin") {
                try pin.allowed(["at", "length", "name", "number", "hide"])
                let number = try pin.one("number", required: true)!.value(1)
                let label = try pin.one("name", required: true)!.value(1)
                let types: [String: PinElectricalType] = ["input": .input, "output": .output, "bidirectional": .bidirectional,
                    "tri_state": .triState, "passive": .passive, "free": .free, "unspecified": .unspecified,
                    "power_in": .powerInput, "power_out": .powerOutput, "open_collector": .openCollector,
                    "open_emitter": .openEmitter, "no_connect": .noConnect]
                guard let type = types[try pin.value(1)] else { throw pin.invalid("Tipo elettrico non riconosciuto.") }
                var item = SymbolPin(id: LibraryImportSupport.id(context.key.id, "pin/" + number), name: label == "~" ? number : label, electricalType: type)
                let at = try pin.one("at", required: true)!
                item.number = number; item.position = try at.point(); item.rotationDegrees = try at.number(3)
                item.length = try pin.one("length", required: true)!.number(1); item.graphicStyle = try pin.value(2); item.unit = u
                result.pins.append(item)
                if pin.children.contains(where: { $0.atom == "hide" || $0.name == "hide" }) {
                    issues.append(.init("source_hidden_pin", name, "Pin nascosto nel sorgente: il pin elettrico è importato; verificarne la presentazione.", severity: .warning))
                }
            }
            graphicNodes += unit.children.filter { $0.atom == nil && $0.name != "pin" }
        }
        result.graphics = try graphics(graphicNodes, context: context, footprint: false, issues: &issues)
        result.properties = props
        return try LibraryImportSupport.result(library: .init(symbols: [result]), issues: issues, format: "kicad-symbol", original: original)
    }

    private static func pad(_ n: SExpression, id: UUID) throws -> FootprintPad {
        try n.allowed(["at", "size", "drill", "layers", "roundrect_rratio", "uuid", "tstamp", "locked", "remove_unused_layers"])
        if let remove = try n.one("remove_unused_layers"), try remove.value(1) != "no" {
            throw remove.invalid("Rimozione selettiva del rame non supportata.", code: "unsupported_pad_layers")
        }
        let type = try n.value(2), shapeName = try n.value(3)
        guard ["smd", "thru_hole"].contains(type) else { throw n.invalid("Tipo piazzola \(type) non supportato.", code: "unsupported_pad") }
        let shapes: [String: PadShape] = ["rect": .rectangle, "circle": .circle, "oval": .oval, "roundrect": .roundedRectangle]
        guard let shape = shapes[shapeName] else { throw n.invalid("Forma piazzola \(shapeName) non supportata.", code: "unsupported_pad") }
        let at = try n.one("at", required: true)!, size = try n.one("size", required: true)!.point()
        let layers = try n.one("layers", required: true)!.children.dropFirst().map { child -> String in
            guard let atom = child.atom else { throw n.invalid("Lista strati non valida.") }; return atom
        }
        let copper = layers.filter { $0.hasSuffix(".Cu") }
        let permitted = type == "smd" ? ["F.Cu", "F.Mask", "F.Paste"] : ["*.Cu", "*.Mask", "F.Mask", "B.Mask"]
        guard Set(layers).count == layers.count, layers.allSatisfy(permitted.contains),
              (type == "smd" && copper == ["F.Cu"]) || (type == "thru_hole" && copper == ["*.Cu"]) else {
            throw n.invalid("Stack di rame non supportato per questa piazzola.", code: "unsupported_pad_layers")
        }
        var drill: Double?
        if let field = try n.one("drill") {
            guard type == "thru_hole", field.children.count == 2 else { throw field.invalid("Fori ovali o decentrati non ancora supportati.", code: "unsupported_drill") }
            drill = try field.number(1)
        } else if type == "thru_hole" { throw n.invalid("Diametro del foro passante mancante.") }
        var pad = FootprintPad(id: id, number: try n.value(1), center: try at.point(ySign: -1), size: size, shape: shape,
                               rotationDegrees: at.children.count > 3 ? try at.number(3) : 0, drillDiameter: drill)
        // KiCad footprint y grows downward, angles are already positive counter-clockwise.
        pad.sourceLayers = layers
        if shape == .roundedRectangle {
            let ratio = try n.one("roundrect_rratio", required: true)!.number(1)
            guard (0...0.5).contains(ratio) else { throw n.invalid("Rapporto del raggio fuori intervallo.") }
            pad.cornerRadius = ratio * min(size.x, size.y)
        }
        return pad
    }

    private static func properties(_ n: SExpression) throws -> [String: String] {
        var properties: [String: String] = [:]
        for p in n.all("property") {
            let key = try p.value(1)
            guard properties[key] == nil else { throw p.invalid("Proprietà \(key) ripetuta.") }
            properties[key] = try p.value(2)
        }
        return properties
    }

    private static func graphics(_ nodes: [SExpression], context: LibraryImportContext, footprint: Bool,
                                 issues: inout [ElectronicsIssue]) throws -> [LibraryGraphic] {
        var result: [LibraryGraphic] = []
        let sign = footprint ? -1.0 : 1.0
        let names: [String: LibraryGraphic.Kind] = ["fp_line": .line, "fp_rect": .rectangle, "fp_circle": .circle,
            "fp_arc": .arc, "fp_poly": .polyline, "rectangle": .rectangle, "circle": .circle, "arc": .arc, "polyline": .polyline]
        for (index, node) in nodes.enumerated() where node.atom == nil {
            let layer = try node.one("layer")?.value(1) ?? "symbol"
            if layer.hasSuffix(".Cu") { throw node.invalid("Grafica sul rame non ancora supportata: importazione interrotta.", code: "unsupported_copper_graphic") }
            guard let kind = names[node.name] else {
                let cosmetic = ["fp_text", "text", "bezier", "text_box"]
                if cosmetic.contains(node.name) {
                    issues.append(.init("source_graphic_not_rendered", node.name, "Elemento grafico conservato nel sorgente; visualizzazione non ancora disponibile.", severity: .warning))
                } else if !footprint { throw node.invalid("Grafica del simbolo non supportata.", code: "unsupported_construct") }
                continue
            }
            try node.allowed(["start", "mid", "end", "center", "radius", "pts", "stroke", "width", "layer", "fill", "uuid", "tstamp", "locked"])
            if let stroke = try node.one("stroke") {
                try stroke.allowed(["width", "type", "color"])
                if let type = try stroke.one("type")?.value(1), !["default", "solid"].contains(type) {
                    issues.append(.init("source_stroke_style", node.name, "Tratteggio conservato nel sorgente; geometria importata con tratto continuo.", severity: .warning))
                }
                if try stroke.one("color") != nil {
                    issues.append(.init("source_stroke_color", node.name, "Colore del sorgente conservato nel file originale; i colori a schermo sono definiti dalla UX.", severity: .warning))
                }
            }
            let points: [PCBPoint]
            switch kind {
            case .line, .rectangle: points = try [node.one("start", required: true)!.point(ySign: sign), node.one("end", required: true)!.point(ySign: sign)]
            case .circle:
                let c = try node.one("center", required: true)!.point(ySign: sign)
                if let end = try node.one("end") { points = try [c, end.point(ySign: sign)] }
                else { points = try [c, PCBPoint(c.x + node.one("radius", required: true)!.number(1), c.y)] }
            case .arc:
                guard try node.one("mid") != nil else { throw node.invalid("Arco KiCad legacy non supportato.", code: "unsupported_arc") }
                points = try [node.one("start", required: true)!.point(ySign: sign), node.one("mid", required: true)!.point(ySign: sign), node.one("end", required: true)!.point(ySign: sign)]
            case .polyline: points = try node.one("pts", required: true)!.all("xy").map { try $0.point(ySign: sign) }
            }
            let width = try node.one("stroke")?.one("width")?.number(1) ?? node.one("width")?.number(1) ?? 0
            let fill = try node.one("fill")
            let filled = try fill?.one("type")?.value(1) == "background" || fill?.one("type")?.value(1) == "outline" || fill?.children.last?.atom == "solid"
            let sourceID = try node.one("uuid")?.value(1) ?? "legacy/\(index)"
            result.append(.init(id: LibraryImportSupport.id(context.key.id, "graphic/" + sourceID), kind: kind, points: points,
                                layer: layer, strokeWidth: width, filled: filled))
        }
        return result
    }
}
