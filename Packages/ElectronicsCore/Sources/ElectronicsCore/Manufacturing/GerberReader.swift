import Foundation

/// Native RS-274X/X2 reader. Absolute L/T coordinates, C/R/O/P and macro primitives
/// 1/4/5/20/21, regions, circular G75 arcs, object attributes and ordered polarity.
/// Arcs are tessellated with maximum sag 0.01 mm. Unsupported geometry is rejected.
/// No I/O; cancellation is checked while tokenizing and generating geometry.
public enum GerberReader {
    public static func read(_ data: Data, name: String) throws -> ManufacturingLayer? {
        try Task.checkCancellation()
        let text = try LibraryImportSupport.text(data)
        var parser = GerberParser(name: name, root: ManufacturingReadSupport.root(data, name))
        return try parser.read(text)
    }
}

private struct GerberParser {
    struct Aperture { var shapes: [ManufacturingShape]; var strokeRadius: Double? }
    let name: String
    let root: UUID
    var unit: Double?
    var format: (integer: Int, fraction: Int, trailing: Bool)?
    var apertures: [Int: Aperture] = [:]
    var macros: [String: [String]] = [:]
    var selected: Int?
    var current: PCBPoint?
    var operation: Int?
    var interpolation = 1
    var multiQuadrant = false
    var isDark = true
    var inRegion = false
    var contour: [PCBPoint] = []
    var contours: [[PCBPoint]] = []
    var attributes: [String: [String]] = [:]
    var fileFunction: String?
    var filePolarity: String?
    var primitives: [ManufacturingPrimitive] = []
    var pointCount = 0
    var aperturePointCount = 0
    var ended = false

    func fail(_ message: String) -> ElectronicsFailure { ManufacturingReadSupport.error(name, message) }
    mutating func read(_ text: String) throws -> ManufacturingLayer? {
        let chars = Array(text); var i = 0; var count = 0
        while i < chars.count {
            if chars[i].isWhitespace { i += 1; continue }
            try Task.checkCancellation(); count += 1
            guard count <= 500_000 else { throw fail("Troppi comandi Gerber (limite 500.000).") }
            guard !ended else { throw fail("Dati dopo il termine M02.") }
            if chars[i] == "%" {
                i += 1; let start = i
                while i < chars.count && chars[i] != "%" { i += 1 }
                guard i < chars.count else { throw fail("Blocco esteso Gerber non terminato.") }
                let block = String(chars[start..<i]); i += 1
                guard block.trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix("*") else { throw fail("Blocco esteso senza terminatore *.") }
                let parts = block.split(separator: "*", omittingEmptySubsequences: true).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                if let first = parts.first, first.hasPrefix("AM") {
                    let key = String(first.dropFirst(2))
                    guard !key.isEmpty, key.count <= 128, macros[key] == nil, parts.count <= 512 else { throw fail("Definizione macro duplicata o troppo grande.") }
                    macros[key] = Array(parts.dropFirst())
                } else {
                    for part in parts { try extended(part) }
                }
            } else {
                let start = i
                while i < chars.count && chars[i] != "*" { i += 1 }
                guard i < chars.count else { throw fail("Comando Gerber non terminato.") }
                let command = String(chars[start..<i]).trimmingCharacters(in: .whitespacesAndNewlines); i += 1
                if command.hasPrefix("G04") || command.hasPrefix("G4 ") {
                    if let r = command.range(of: "#@!") { try attribute(command[r.upperBound...].trimmingCharacters(in: .whitespaces)) }
                } else {
                    try ordinary(command.filter { !$0.isWhitespace })
                }
            }
        }
        guard ended, !inRegion else { throw fail("Gerber incompleto: manca M02 o la regione non è chiusa.") }
        guard unit != nil, format != nil else { throw fail("Gerber senza unità o formato coordinate esplicito.") }
        if fileFunction == "Drillmap" { return nil }
        let kind = try classify()
        if let polarity = filePolarity {
            let expected = (kind == .topMask || kind == .bottomMask) ? "Negative" : "Positive"
            guard polarity == expected else { throw fail("Polarità file \(polarity) non supportata per \(kind.rawValue).") }
        }
        return .init(id: root, name: name, kind: kind, primitives: primitives)
    }

    func classify() throws -> FabricationLayerKind {
        if let function = fileFunction {
            let parts = function.split(separator: ",").map(String.init)
            let top = parts.contains("Top"), bottom = parts.contains("Bot")
            switch parts.first {
            case "Copper":
                guard top != bottom, !parts.contains("Inr") else { throw fail("Strato rame interno o ambiguo non supportato.") }
                return top ? .topCopper : .bottomCopper
            case "Soldermask": if top != bottom { return top ? .topMask : .bottomMask }
            case "Paste": if top != bottom { return top ? .topPaste : .bottomPaste }
            case "Legend": if top != bottom { return top ? .topSilkscreen : .bottomSilkscreen }
            case "Profile": return .profile
            default: break
            }
            throw fail("Funzione Gerber non supportata: \(function).")
        }
        let lower = name.lowercased(), ext = (lower as NSString).pathExtension
        let extensions: [String: FabricationLayerKind] = ["gtl": .topCopper, "gbl": .bottomCopper,
            "gts": .topMask, "gbs": .bottomMask, "gtp": .topPaste, "gbp": .bottomPaste,
            "gto": .topSilkscreen, "gbo": .bottomSilkscreen, "gm1": .profile, "gko": .profile]
        if let kind = extensions[ext] { return kind }
        let aliases: [(String, FabricationLayerKind)] = [("-f_cu.", .topCopper), ("-b_cu.", .bottomCopper),
            ("-f_mask.", .topMask), ("-b_mask.", .bottomMask), ("-f_paste.", .topPaste), ("-b_paste.", .bottomPaste),
            ("-f_silkscreen.", .topSilkscreen), ("-b_silkscreen.", .bottomSilkscreen),
            ("-edge_cuts.", .profile), ("-profile.", .profile)]
        if let match = aliases.first(where: { lower.contains($0.0) }) { return match.1 }
        throw fail("Impossibile identificare lo strato: serve TF.FileFunction o un'estensione Gerber convenzionale.")
    }

    mutating func extended(_ command: String) throws {
        guard !inRegion else { throw fail("Comando esteso all'interno di una regione non supportato.") }
        if command.hasPrefix("TF") || command.hasPrefix("TA") || command.hasPrefix("TO") || command.hasPrefix("TD") {
            try attribute(command); return
        }
        let c = command.filter { !$0.isWhitespace }
        if c.hasPrefix("FS") {
            let a = Array(c)
            guard format == nil, a.count == 10, a[0] == "F", a[1] == "S", "LT".contains(a[2]), a[3] == "A",
                  a[4] == "X", a[7] == "Y", a[5] == a[8], a[6] == a[9],
                  let integer = a[5].wholeNumberValue, let fraction = a[6].wholeNumberValue,
                  (1...6).contains(integer), (1...7).contains(fraction) else {
                throw fail("Formato coordinate non supportato: richiesto FS assoluto, X/Y uguali, 1–6 cifre intere e 1–7 decimali.")
            }
            format = (integer, fraction, a[2] == "T"); return
        }
        if c == "MOMM" || c == "MOIN" {
            guard unit == nil else { throw fail("Unità Gerber ridefinite.") }
            unit = c == "MOMM" ? 1 : 25.4; return
        }
        if c == "LPD" || c == "LPC" { isDark = c == "LPD"; return }
        if c.hasPrefix("ADD") { try aperture(c); return }
        // SR/AB, mirroring, scaling and rotations cannot be silently discarded.
        throw fail("Comando Gerber non supportato: \(c.prefix(100)).")
    }

    mutating func attribute(_ command: String) throws {
        guard command.count <= 8192 else { throw fail("Attributo Gerber troppo grande.") }
        let family = String(command.prefix(2)), rest = String(command.dropFirst(2))
        let parts = rest.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
        guard let key = parts.first else { return }
        let values = try parts.dropFirst().map { try decodeAttribute($0) }
        switch family {
        case "TF":
            if key == ".FileFunction" {
                let value = values.joined(separator: ",")
                guard fileFunction == nil || fileFunction == value else { throw fail("Funzione file Gerber contraddittoria.") }
                fileFunction = value
            }
            if key == ".FilePolarity" {
                guard values.count == 1, ["Positive", "Negative"].contains(values[0]), filePolarity == nil || filePolarity == values[0] else { throw fail("Polarità file Gerber non valida.") }
                filePolarity = values[0]
            }
        case "TO":
            guard !inRegion else { throw fail("Attributi oggetto modificati dentro una regione.") }
            guard key != ".N" || values.count == 1 else { throw fail("Oggetto collegato a più reti non supportato: le reti non vengono troncate.") }
            guard key != ".C" || values.count == 1 else { throw fail("Riferimento componente Gerber non valido.") }
            guard key != ".P" || (2...3).contains(values.count) else { throw fail("Riferimento pin Gerber non valido.") }
            if key == ".N" || key == ".P" || key == ".C" { attributes[key] = values }
        case "TD":
            guard !inRegion else { throw fail("Attributi oggetto modificati dentro una regione.") }
            if key.isEmpty { attributes.removeAll() } else { attributes.removeValue(forKey: key) }
        case "TA": break // Aperture classification metadata does not alter geometry.
        default: throw fail("Attributo Gerber sconosciuto.")
        }
    }

    func decodeAttribute(_ value: String) throws -> String {
        let a = Array(value); var i = 0; var result = ""
        while i < a.count {
            if a[i] != "\\" { result.append(a[i]); i += 1; continue }
            guard i + 5 < a.count, a[i+1] == "u", let code = UInt32(String(a[(i+2)...(i+5)]), radix: 16), let scalar = UnicodeScalar(code) else {
                throw fail("Sequenza Unicode Gerber non valida.")
            }
            result.unicodeScalars.append(scalar); i += 6
        }
        return result
    }

    mutating func ordinary(_ command: String) throws {
        guard !command.isEmpty else { throw fail("Comando Gerber vuoto.") }
        let fields = try ManufacturingReadSupport.fields(command, allowed: "GDMXYIJ", name: name)
        var coordinates: [Character: String] = [:]; var d: Int?; var hasM = false
        for (key, value) in fields {
            if "XYIJ".contains(key) {
                guard coordinates[key] == nil else { throw fail("Coordinata duplicata nel comando.") }
                coordinates[key] = value
            } else {
                guard let number = Int(value), number >= 0 else { throw fail("Codice comando non intero.") }
                switch key {
                case "D": guard d == nil else { throw fail("Più operazioni D nello stesso comando.") }; d = number
                case "M": guard number == 2, fields.count == 1, !inRegion else { throw fail("Termine Gerber non valido.") }; hasM = true
                case "G":
                    switch number {
                    case 1, 2, 3: interpolation = number
                    case 75: multiQuadrant = true
                    case 36:
                        guard !inRegion, fields.count == 1 else { throw fail("Inizio regione non valido.") }
                        inRegion = true; contour = []; contours = []; return
                    case 37:
                        guard inRegion, fields.count == 1 else { throw fail("Fine regione non valida.") }
                        try closeContour(); guard !contours.isEmpty else { throw fail("Regione vuota.") }
                        // Ucamco 4.10.4.3: distinct region contours UNION, including nested
                        // contours. Only cut-ins within a single contour create a hole.
                        inRegion = false; try append(contours.map { .init(contours: [$0], radius: 0) }); contours = []; return
                    case 54: break // Historic aperture selection prefix; D still validated below.
                    default: throw fail("G\(number) non supportato; usare coordinate assolute e archi G75.")
                    }
                default: break
                }
            }
        }
        if hasM { ended = true; return }
        if let d, d >= 10 {
            guard coordinates.isEmpty, !inRegion, apertures[d] != nil else { throw fail("Selezione apertura non valida.") }
            selected = d; return
        }
        if let d {
            guard (1...3).contains(d) else { throw fail("Operazione D non supportata.") }
            operation = d
        }
        guard !coordinates.isEmpty || d != nil else { return }
        guard let op = operation else { throw fail("Operazione D non definita.") }
        var target = current ?? .init()
        if let x = coordinates["X"] { target.x = try coordinate(x) }
        if let y = coordinates["Y"] { target.y = try coordinate(y) }
        guard current != nil || (coordinates["X"] != nil && coordinates["Y"] != nil) else { throw fail("Posizione iniziale incompleta.") }
        try ManufacturingReadSupport.point(target, name: name)
        if op == 2 {
            guard coordinates["I"] == nil, coordinates["J"] == nil else { throw fail("Offset arco in uno spostamento.") }
            if inRegion { try closeContour(); contour = [target] }
            current = target; return
        }
        if op == 3 {
            guard !inRegion, coordinates["I"] == nil, coordinates["J"] == nil,
                  let selected, let a = apertures[selected] else { throw fail("Flash senza apertura o dentro una regione.") }
            let shapes = a.shapes.map { shape in ManufacturingShape(contours: shape.contours.map { $0.map { .init($0.x + target.x, $0.y + target.y) } }, radius: shape.radius, isDark: shape.isDark) }
            try append(shapes); current = target; return
        }
        guard let start = current else { throw fail("Disegno senza punto iniziale.") }
        let path: [PCBPoint]
        if interpolation == 1 {
            guard coordinates["I"] == nil, coordinates["J"] == nil else { throw fail("Offset arco con interpolazione lineare.") }
            path = [start, target]
        } else {
            guard multiQuadrant, coordinates["I"] != nil || coordinates["J"] != nil else { throw fail("Arco senza G75 o senza centro I/J.") }
            let offset = PCBPoint(try coordinates["I"].map(coordinate) ?? 0, try coordinates["J"].map(coordinate) ?? 0)
            path = try arc(from: start, to: target, offset: offset, clockwise: interpolation == 2)
        }
        if inRegion {
            guard !contour.isEmpty else { throw fail("Il contorno di una regione deve iniziare con D02.") }
            guard contour.count + path.count <= 250_000 else { throw fail("Contorno troppo complesso.") }
            contour.append(contentsOf: path.dropFirst())
        } else {
            guard let selected, let a = apertures[selected], let radius = a.strokeRadius else { throw fail("Tracciato con apertura non circolare o forata non supportato.") }
            var shapes: [ManufacturingShape] = []
            for index in 1..<path.count { shapes.append(.init(contours: [[path[index-1], path[index]]], radius: radius)) }
            try append(shapes)
        }
        current = target
    }

    func coordinate(_ text: String) throws -> Double {
        guard let f = format, let unit else { throw fail("Coordinate prima della dichiarazione di formato/unità.") }
        guard !text.contains("."), text.filter({ $0.isNumber }).count <= f.integer + f.fraction,
              let integer = Int64(text) else { throw fail("Coordinata Gerber non valida.") }
        let digits = text.filter { $0.isNumber }.count
        let trailing = f.trailing ? f.integer + f.fraction - digits : 0
        return Double(integer) * pow(10, Double(trailing - f.fraction)) * unit
    }

    mutating func closeContour() throws {
        guard !contour.isEmpty else { return }
        guard contour.count >= 4, let first = contour.first, let last = contour.last,
              hypot(first.x-last.x, first.y-last.y) <= 0.000_001 else { throw fail("Regione Gerber con contorno aperto o degenere.") }
        contour[contour.count-1] = first; contours.append(contour); contour = []
    }

    mutating func append(_ shapes: [ManufacturingShape]) throws {
        try Task.checkCancellation()
        guard !shapes.isEmpty, primitives.count < 200_000 else { throw fail("Geometria vuota o limite di 200.000 primitive superato.") }
        for shape in shapes {
            guard shape.radius.isFinite, shape.radius >= 0, shape.radius <= 100_000 else { throw fail("Raggio non valido.") }
            for contour in shape.contours { for p in contour { try ManufacturingReadSupport.point(p, name: name); pointCount += 1 } }
        }
        guard pointCount <= 2_000_000 else { throw fail("Limite di 2.000.000 punti Gerber superato.") }
        let pin = attributes[".P"]
        primitives.append(.init(id: LibraryImportSupport.id(root, "object/\(primitives.count)"), shapes: shapes, isDark: isDark,
                                netName: attributes[".N"]?.first, componentReference: pin?.first ?? attributes[".C"]?.first,
                                pinNumber: pin.flatMap { $0.count >= 2 ? $0[1] : nil }))
    }

    func arc(from start: PCBPoint, to end: PCBPoint, offset: PCBPoint, clockwise: Bool) throws -> [PCBPoint] {
        let center = PCBPoint(start.x + offset.x, start.y + offset.y), radius = hypot(offset.x, offset.y)
        try ManufacturingReadSupport.positive(radius, name: name)
        let endRadius = hypot(end.x-center.x, end.y-center.y)
        // Half the 0.01 mm budget is reserved for endpoint quantization, half for chords.
        guard abs(endRadius-radius) <= 0.005 else { throw fail("Arco Gerber con raggi iniziale/finale incoerenti.") }
        let firstAngle = atan2(start.y-center.y, start.x-center.x), lastAngle = atan2(end.y-center.y, end.x-center.x)
        var sweep = lastAngle - firstAngle
        if clockwise { while sweep >= 0 { sweep -= 2 * .pi } }
        else { while sweep <= 0 { sweep += 2 * .pi } }
        let step = min(.pi / 12, 2 * acos(max(-1, 1 - min(0.005, radius) / radius)))
        guard step.isFinite, step > 0 else { throw fail("Arco fuori precisione.") }
        let count = max(1, Int(ceil(abs(sweep) / step)))
        guard count <= 100_000 else { throw fail("Arco troppo complesso.") }
        var path = [start]
        for i in 1..<count {
            if i % 256 == 0 { try Task.checkCancellation() }
            let angle = firstAngle + sweep * Double(i) / Double(count)
            path.append(.init(center.x + radius*cos(angle), center.y + radius*sin(angle)))
        }
        path.append(end); return path
    }

    mutating func aperture(_ text: String) throws {
        guard let unit else { throw fail("Apertura prima delle unità.") }
        let a = Array(text.dropFirst(3)); var i = 0
        while i < a.count && a[i].isNumber { i += 1 }
        guard let number = Int(String(a[..<i])), number >= 10, apertures[number] == nil, apertures.count < 4096 else { throw fail("Numero apertura non valido, duplicato o oltre limite.") }
        let parts = String(a[i...]).split(separator: ",", omittingEmptySubsequences: false)
        guard parts.count <= 2, let rawTemplate = parts.first, !rawTemplate.isEmpty else { throw fail("Definizione apertura non valida.") }
        let template = String(rawTemplate)
        let values = try parts.count == 2 ? parts[1].split(separator: "X", omittingEmptySubsequences: false).map { try ManufacturingReadSupport.number(String($0), name: name) } : []
        var shapes: [ManufacturingShape] = []; var strokeRadius: Double?; var hole: Double?
        func positive(_ n: Double) throws { try ManufacturingReadSupport.positive(n, name: name) }
        func polygon(_ points: [PCBPoint], dark: Bool = true) -> ManufacturingShape { .init(contours: [points], radius: 0, isDark: dark) }
        switch template {
        case "C":
            guard (1...2).contains(values.count) else { throw fail("Apertura C: attesi diametro e foro opzionale.") }
            let diameter = values[0]*unit; try positive(diameter)
            shapes = [.init(contours: [[.init()]], radius: diameter/2)]
            hole = values.count == 2 ? values[1]*unit : nil
            if hole == nil || hole == 0 { strokeRadius = diameter/2 }
            if let hole, hole >= diameter { throw fail("Foro più grande dell'apertura.") }
        case "R", "O":
            guard (2...3).contains(values.count) else { throw fail("Apertura R/O non valida.") }
            let w = values[0]*unit, h = values[1]*unit; try positive(w); try positive(h)
            if template == "R" { shapes = [polygon([.init(-w/2,-h/2), .init(w/2,-h/2), .init(w/2,h/2), .init(-w/2,h/2)])] }
            else {
                let points: [PCBPoint] = w > h ? [.init(-(w-h)/2,0), .init((w-h)/2,0)] : [.init(0,-(h-w)/2), .init(0,(h-w)/2)]
                shapes = [.init(contours: [points], radius: min(w,h)/2)]
            }
            hole = values.count == 3 ? values[2]*unit : nil
            if let hole, hole >= min(w,h) { throw fail("Foro più grande dell'apertura.") }
        case "P":
            guard (2...4).contains(values.count), values[1].rounded() == values[1], (3...12).contains(values[1]) else { throw fail("Apertura poligonale non valida.") }
            let diameter = values[0]*unit; try positive(diameter)
            let n = Int(values[1]), rotation = values.count >= 3 ? values[2] : 0
            let points = (0..<n).map { k in let angle = (rotation + Double(k)*360/Double(n)) * .pi/180; return PCBPoint(diameter*cos(angle)/2, diameter*sin(angle)/2) }
            shapes = [polygon(points)]; hole = values.count == 4 ? values[3]*unit : nil
            if let hole, hole >= diameter*cos(.pi/Double(n)) { throw fail("Foro più grande dell'apertura.") }
        default:
            guard let macro = macros[template] else { throw fail("Macro apertura sconosciuta: \(template).") }
            shapes = try expand(macro, parameters: values, unit: unit)
        }
        if let hole, hole != 0 { try positive(hole); shapes.append(.init(contours: [[.init()]], radius: hole/2, isDark: false)) }
        guard !shapes.isEmpty else { throw fail("Apertura priva di geometria.") }
        for shape in shapes { for contour in shape.contours { for p in contour { try ManufacturingReadSupport.point(p, name: name) } } }
        aperturePointCount += shapes.reduce(0) { $0 + $1.contours.reduce(0) { $0 + $1.count } }
        guard aperturePointCount <= 200_000 else { throw fail("Definizioni aperture oltre il limite di 200.000 punti.") }
        apertures[number] = .init(shapes: shapes, strokeRadius: strokeRadius)
    }

    func expand(_ macro: [String], parameters: [Double], unit: Double) throws -> [ManufacturingShape] {
        var variables = Dictionary(uniqueKeysWithValues: parameters.enumerated().map { ($0.offset+1, $0.element) })
        var shapes: [ManufacturingShape] = []
        var vertices = 0
        for raw in macro {
            try Task.checkCancellation()
            if raw == "0" || raw.hasPrefix("0 ") { continue }
            let line = raw.filter { !$0.isWhitespace }
            if line.hasPrefix("$") {
                let pair = line.split(separator: "=", omittingEmptySubsequences: false)
                guard pair.count == 2, let index = Int(pair[0].dropFirst()), (1...4096).contains(index) else { throw fail("Assegnazione macro non valida.") }
                var expression = GerberExpression(text: String(pair[1]), variables: variables, name: name)
                variables[index] = try expression.evaluate(); continue
            }
            let fields = line.split(separator: ",", omittingEmptySubsequences: false)
            guard let first = fields.first, let code = Int(first) else { throw fail("Primitiva macro non valida.") }
            let v = try fields.dropFirst().map { field in var e = GerberExpression(text: String(field), variables: variables, name: name); return try e.evaluate() }
            guard let exposure = v.first, exposure == 0 || exposure == 1 else { throw fail("Esposizione macro diversa da 0/1.") }
            let dark = exposure == 1
            func p(_ x: Double, _ y: Double, _ angle: Double) -> PCBPoint { ManufacturingReadSupport.rotate(.init(x*unit,y*unit), angle) }
            switch code {
            case 1:
                guard v.count == 4 || v.count == 5 else { throw fail("Cerchio macro non valido.") }
                try ManufacturingReadSupport.positive(v[1]*unit, name: name)
                shapes.append(.init(contours: [[p(v[2],v[3],v.count == 5 ? v[4] : 0)]], radius: v[1]*unit/2, isDark: dark))
            case 4:
                guard v.count >= 10, v[1].rounded() == v[1], (3...5000).contains(v[1]) else { throw fail("Contorno macro non valido.") }
                let n = Int(v[1]); guard v.count == 2 + 2*(n+1) + 1 else { throw fail("Numero vertici macro incoerente.") }
                let angle = v[v.count-1]
                let points = (0...n).map { p(v[2+2*$0],v[3+2*$0],angle) }
                guard let first = points.first, let last = points.last, hypot(first.x-last.x,first.y-last.y) < 0.000_001 else { throw fail("Contorno macro non chiuso.") }
                shapes.append(.init(contours: [points], radius: 0, isDark: dark))
            case 20:
                guard v.count == 7 else { throw fail("Linea macro non valida.") }
                let width = v[1]*unit; try ManufacturingReadSupport.positive(width, name: name)
                let a = p(v[2],v[3],v[6]), b = p(v[4],v[5],v[6]), length = hypot(b.x-a.x,b.y-a.y)
                guard length > 0 else { throw fail("Linea macro senza lunghezza.") }
                let nx = -(b.y-a.y)*width/(2*length), ny = (b.x-a.x)*width/(2*length)
                shapes.append(.init(contours: [[.init(a.x+nx,a.y+ny), .init(b.x+nx,b.y+ny), .init(b.x-nx,b.y-ny), .init(a.x-nx,a.y-ny)]], radius: 0, isDark: dark))
            case 21:
                guard v.count == 6 else { throw fail("Rettangolo macro non valido.") }
                try ManufacturingReadSupport.positive(v[1]*unit, name: name); try ManufacturingReadSupport.positive(v[2]*unit, name: name)
                shapes.append(.init(contours: [[p(v[3]-v[1]/2,v[4]-v[2]/2,v[5]), p(v[3]+v[1]/2,v[4]-v[2]/2,v[5]), p(v[3]+v[1]/2,v[4]+v[2]/2,v[5]), p(v[3]-v[1]/2,v[4]+v[2]/2,v[5])]], radius: 0, isDark: dark))
            case 5:
                guard v.count == 6, v[1].rounded() == v[1], (3...12).contains(v[1]) else { throw fail("Poligono macro non valido.") }
                try ManufacturingReadSupport.positive(v[4]*unit, name: name)
                let n = Int(v[1]), points = (0..<n).map { k -> PCBPoint in let a = Double(k)*2*Double.pi/Double(n); return p(v[2]+v[4]*cos(a)/2,v[3]+v[4]*sin(a)/2,v[5]) }
                shapes.append(.init(contours: [points], radius: 0, isDark: dark))
            default: throw fail("Primitiva macro \(code) non supportata.")
            }
            vertices += shapes.last?.contours.reduce(0) { $0 + $1.count } ?? 0
            guard vertices <= 100_000 else { throw fail("Macro oltre il limite di 100.000 punti.") }
        }
        return shapes
    }
}

/// Small bounded arithmetic evaluator; no dynamic code execution or external parser.
private struct GerberExpression {
    let chars: [Character]
    let variables: [Int: Double]
    let name: String
    var index = 0
    var depth = 0
    init(text: String, variables: [Int: Double], name: String) { chars = Array(text); self.variables = variables; self.name = name }
    func fail() -> ElectronicsFailure { ManufacturingReadSupport.error(name, "Espressione macro non valida o troppo complessa.") }
    mutating func evaluate() throws -> Double {
        guard !chars.isEmpty, chars.count <= 512 else { throw fail() }
        let value = try sum(); guard index == chars.count, value.isFinite, abs(value) <= 1_000_000 else { throw fail() }; return value
    }
    mutating func sum() throws -> Double {
        var value = try product()
        while index < chars.count && (chars[index] == "+" || chars[index] == "-") {
            let op = chars[index]; index += 1; let rhs = try product(); value = op == "+" ? value+rhs : value-rhs
        }
        return value
    }
    mutating func product() throws -> Double {
        var value = try atom()
        while index < chars.count && "xX/".contains(chars[index]) {
            let op = chars[index]; index += 1; let rhs = try atom()
            if op == "/" { guard rhs != 0 else { throw fail() }; value /= rhs } else { value *= rhs }
        }
        return value
    }
    mutating func atom() throws -> Double {
        depth += 1; defer { depth -= 1 }; guard depth <= 32, index < chars.count else { throw fail() }
        if chars[index] == "+" || chars[index] == "-" { let negative = chars[index] == "-"; index += 1; let v = try atom(); return negative ? -v : v }
        if chars[index] == "(" { index += 1; let v = try sum(); guard index < chars.count && chars[index] == ")" else { throw fail() }; index += 1; return v }
        if chars[index] == "$" {
            index += 1; let start = index; while index < chars.count && chars[index].isNumber { index += 1 }
            guard let key = Int(String(chars[start..<index])), (1...4096).contains(key) else { throw fail() }
            return variables[key] ?? 0
        }
        let start = index; while index < chars.count && (chars[index].isNumber || chars[index] == ".") { index += 1 }
        guard start < index, let value = Double(String(chars[start..<index])), value.isFinite else { throw fail() }; return value
    }
}
