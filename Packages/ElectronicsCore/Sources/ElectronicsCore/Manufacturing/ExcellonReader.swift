import Foundation

/// XNC/Excellon subset with explicit decimal coordinates and units, round hits and
/// straight slots (G85 or G00/M15/G01/M16). Fixed-point, repeat patterns, offsets,
/// incremental coordinates and circular routs are rejected instead of guessed.
public enum ExcellonReader {
    public static func read(_ data: Data, name: String) throws -> [ManufacturingDrill] {
        try Task.checkCancellation()
        let text = try LibraryImportSupport.text(data)
        var parser = ExcellonParser(name: name, root: ManufacturingReadSupport.root(data, name))
        return try parser.read(text)
    }
}

private struct ExcellonParser {
    struct Tool { let diameter: Double; let plated: Bool }
    let name: String
    let root: UUID
    var tools: [Int: Tool] = [:]
    var selected: Int?
    var unit: Double?
    var filePlated: Bool?
    var toolPlated: Bool?
    var current: PCBPoint?
    var routing = false
    var toolDown = false
    var started = false
    var headerEnded = false
    var ended = false
    var decimalFormat = false
    var drills: [ManufacturingDrill] = []
    func fail(_ message: String) -> ElectronicsFailure { ManufacturingReadSupport.error(name, message) }

    mutating func read(_ text: String) throws -> [ManufacturingDrill] {
        let lower = name.lowercased()
        if lower.contains("npth") || lower.contains("nonplated") { filePlated = false }
        else if lower.contains("pth") || lower.contains("plated") { filePlated = true }
        // Explicit decimal point in a body coordinate or an explicit KiCad decimal declaration.
        // Never infer fixed-point precision from a file name or from the physical board size.
        decimalFormat = text.contains("/ decimal}") || text.contains("/ decimal }")
        let lines = text.components(separatedBy: .newlines)
        guard lines.count <= 500_000 else { throw fail("Troppi comandi di foratura.") }
        for line in lines where !line.hasPrefix(";") {
            try Task.checkCancellation()
            if line.range(of: "[XY][+-]?[0-9]*\\.[0-9]*", options: .regularExpression) != nil { decimalFormat = true; break }
        }
        for raw in lines {
            try Task.checkCancellation()
            let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty { continue }
            if line.hasPrefix(";") { try comment(line); continue }
            guard !ended else { throw fail("Dati dopo M30.") }
            if line == "M48" {
                guard !started else { throw fail("Intestazione di foratura duplicata.") }; started = true; continue
            }
            guard started else { throw fail("Intestazione M48 mancante.") }
            if line == "METRIC" || line == "INCH" {
                guard unit == nil, !headerEnded else { throw fail("Unità di foratura ridefinite.") }
                unit = line == "METRIC" ? 1 : 25.4; continue
            }
            if line == "FMAT,2" { guard !headerEnded else { throw fail("FMAT fuori intestazione.") }; continue }
            if line == "%" || line == "M95" {
                guard unit != nil, !headerEnded else { throw fail("Fine intestazione non valida.") }; headerEnded = true; continue
            }
            if line.hasPrefix("T") { try tool(line); continue }
            guard headerEnded else { throw fail("Comando non supportato nell'intestazione di foratura: \(line.prefix(80)).") }
            if line == "M30" { guard !toolDown else { throw fail("Fine file con utensile abbassato.") }; ended = true; continue }
            if line == "G90" { continue }
            if line == "G05" || line == "G5" { guard !toolDown else { throw fail("Cambio modalità con utensile abbassato.") }; routing = false; continue }
            if line == "M15" { guard routing, current != nil, selected != nil, !toolDown else { throw fail("M15 senza percorso/utensile valido.") }; toolDown = true; continue }
            if line == "M16" || line == "M17" { guard routing, toolDown else { throw fail("Utensile già sollevato.") }; toolDown = false; continue }
            if let range = line.range(of: "G85") {
                guard !routing, !toolDown, line[range.upperBound...].range(of: "G85") == nil else { throw fail("Asola G85 non valida.") }
                let startText = String(line[..<range.lowerBound]), endText = String(line[range.upperBound...])
                let start = try startText.isEmpty ? requirePosition() : point(startText)
                current = start; let end = try point(endText); try append(start, end: end); current = end; continue
            }
            if line.hasPrefix("G00") || line.hasPrefix("G0X") || line.hasPrefix("G0Y") {
                guard !toolDown else { throw fail("Spostamento rapido con utensile abbassato.") }
                let remainder = String(line.dropFirst(line.hasPrefix("G00") ? 3 : 2))
                routing = true; if !remainder.isEmpty { current = try point(remainder) }; continue
            }
            if line.hasPrefix("G01") || line.hasPrefix("G1X") || line.hasPrefix("G1Y") {
                guard routing, toolDown else { throw fail("Fresatura senza utensile abbassato.") }
                let end = try point(String(line.dropFirst(line.hasPrefix("G01") ? 3 : 2)))
                try append(requirePosition(), end: end); current = end; continue
            }
            if line.hasPrefix("X") || line.hasPrefix("Y") {
                guard !routing else { throw fail("Fresatura modale senza G01 esplicito non supportata.") }
                let p = try point(line); try append(p); current = p; continue
            }
            throw fail("Comando Excellon non supportato: \(line.prefix(100)). Usare coordinate decimali assolute, fori o asole lineari.")
        }
        guard started, headerEnded, ended, unit != nil else { throw fail("File forature incompleto.") }
        return drills
    }

    mutating func comment(_ line: String) throws {
        guard let r = line.range(of: "#@!") else { return }
        let attribute = line[r.upperBound...].trimmingCharacters(in: .whitespaces)
        let values = attribute.split(separator: ",").map(String.init)
        if values.first == "TF.FileFunction" {
            guard !headerEnded, values.count >= 2 else { throw fail("Attributo di metallizzazione non valido.") }
            if values[1] == "Plated" { filePlated = true }
            else if values[1] == "NonPlated" { filePlated = false }
            else { throw fail("File forature a metallizzazione mista/non dichiarata non supportato.") }
        }
        if values.first == "TA.AperFunction" {
            if values.contains("NonPlated") { toolPlated = false }
            else if values.contains("Plated") { toolPlated = true }
            else { toolPlated = nil }
        }
        if values.first == "TD" || values.first == "TD.AperFunction" { toolPlated = nil }
    }

    mutating func tool(_ line: String) throws {
        let fields = try ManufacturingReadSupport.fields(line, allowed: "TC", name: name)
        guard let first = fields.first, first.0 == "T", let number = Int(first.1), number > 0 else { throw fail("Numero utensile non valido.") }
        if fields.count == 2 {
            guard !headerEnded, fields[1].0 == "C", tools[number] == nil, tools.count < 4096, let unit else { throw fail("Definizione utensile non valida o duplicata.") }
            let diameter = try ManufacturingReadSupport.number(fields[1].1, name: name) * unit
            try ManufacturingReadSupport.positive(diameter, name: name)
            guard let plated = toolPlated ?? filePlated else { throw fail("Metallizzazione non dichiarata: servono attributi PTH/NPTH o un nome file esplicito.") }
            tools[number] = .init(diameter: diameter, plated: plated)
        } else {
            guard fields.count == 1, headerEnded, tools[number] != nil, !toolDown else { throw fail("Selezione utensile non valida.") }
            selected = number
        }
    }

    func requirePosition() throws -> PCBPoint {
        guard let current else { throw fail("Posizione iniziale mancante.") }; return current
    }
    func point(_ text: String) throws -> PCBPoint {
        guard let unit, decimalFormat, !text.isEmpty else { throw fail("Formato coordinate ambiguo: esportare Excellon con punto decimale esplicito.") }
        var p = current ?? .init(); var seen: Set<Character> = []
        for (key, value) in try ManufacturingReadSupport.fields(text, allowed: "XY", name: name) {
            guard seen.insert(key).inserted else { throw fail("Coordinata di foratura duplicata.") }
            let n = try ManufacturingReadSupport.number(value, name: name) * unit
            if key == "X" { p.x = n } else { p.y = n }
        }
        guard current != nil || seen.count == 2 else { throw fail("Prima posizione di foratura incompleta.") }
        try ManufacturingReadSupport.point(p, name: name); return p
    }
    mutating func append(_ position: PCBPoint, end: PCBPoint? = nil) throws {
        guard let selected, let tool = tools[selected], drills.count < 200_000 else { throw fail("Foratura senza utensile o oltre il limite di 200.000 fori.") }
        if let end, end == position { throw fail("Asola senza lunghezza.") }
        drills.append(.init(id: LibraryImportSupport.id(root, "drill/\(drills.count)"), position: position, end: end,
                            diameter: tool.diameter, isPlated: tool.plated))
    }
}
