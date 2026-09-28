import Foundation

public struct ManufacturingBOMEntry: Codable, Equatable, Sendable {
    public var reference: String
    public var value: String
    public var footprint: String
    public var lcscPartNumber: String?
    public var fitted: Bool
    public init(reference: String, value: String, footprint: String, lcscPartNumber: String? = nil, fitted: Bool = true) {
        self.reference = reference; self.value = value; self.footprint = footprint
        self.lcscPartNumber = lcscPartNumber; self.fitted = fitted
    }
}

public struct ManufacturingPlacement: Codable, Equatable, Sendable {
    public var reference: String
    public var position: PCBPoint
    public var rotationDegrees: Double
    public var side: BoardSide
    public init(reference: String, position: PCBPoint, rotationDegrees: Double, side: BoardSide) {
        self.reference = reference; self.position = position; self.rotationDegrees = rotationDegrees; self.side = side
    }
}

/// Strict UTF-8 CSV reader for BOM and assembly positions, in millimetres.
/// Retains source coordinates and rotations; it never guesses an origin, mirrors a side or changes units.
public enum ManufacturingTables {
    public static func bom(_ data: Data) throws -> [ManufacturingBOMEntry] {
        let table = try CSV(data: data)
        let refs = try table.column(["designator", "designators", "reference", "references", "ref", "refs"])
        let footprint = try table.column(["footprint", "package"])
        let value = try table.column(["value", "comment"])
        let lcsc = try table.optionalColumn(["lcscpart#", "lcscpartnumber", "lcscpart", "lcsc", "jlcpcbpart#", "jlcpcbpartnumber"])
        let quantity = try table.optionalColumn(["quantity", "qty"])
        let dnp = try table.optionalColumn(["dnp", "donotpopulate", "donotplace", "donotfit"])
        let fitted = try table.optionalColumn(["fitted", "populate", "populated", "assemble", "assembled"])
        var result: [ManufacturingBOMEntry] = [], seen = Set<String>()
        for (offset, row) in table.rows.enumerated() {
            try Task.checkCancellation()
            let subject = "BOM riga \(offset + 2)"
            let references = row[refs].split(whereSeparator: { $0 == "," || $0 == ";" || $0.isWhitespace }).map(String.init)
            guard !references.isEmpty, references.count <= 10_000, result.count + references.count <= 10_000 else {
                throw failure(subject, "Riferimenti mancanti o oltre il limite di 10.000 componenti.")
            }
            if let quantity {
                let text = trimmed(row[quantity])
                guard text.allSatisfy(\.isNumber), let count = Int(text), count == references.count else {
                    throw failure(subject, "La quantità deve corrispondere al numero di riferimenti della riga.")
                }
            }
            let footprintName = trimmed(row[footprint])
            guard !footprintName.isEmpty else { throw failure(subject, "Impronta mancante.") }
            let markedDNP = try dnp.map { try boolean(row[$0], subject: subject, kind: "DNP") }
            let markedFitted = try fitted.map { try boolean(row[$0], subject: subject, kind: "Fitted") }
            if let markedDNP, let markedFitted, markedDNP == markedFitted {
                throw failure(subject, "Le colonne DNP e Fitted sono in contraddizione.")
            }
            let isFitted = markedFitted ?? !(markedDNP ?? false)
            let part = lcsc.map { trimmed(row[$0]) }.flatMap { $0.isEmpty ? nil : $0 }
            if let part, !part.matches("^[Cc][0-9]+$") { throw failure(subject, "Codice LCSC non valido: atteso C seguito da cifre.") }
            for reference in references {
                try validateReference(reference, seen: &seen, subject: subject)
                result.append(.init(reference: reference, value: trimmed(row[value]), footprint: footprintName,
                                    lcscPartNumber: part?.uppercased(), fitted: isFitted))
            }
        }
        return result
    }

    public static func positions(_ data: Data) throws -> [ManufacturingPlacement] {
        let table = try CSV(data: data)
        let reference = try table.column(["designator", "reference", "ref"])
        let x = try table.column(["midx", "midx(mm)", "centerx", "centerx(mm)", "posx", "x"])
        let y = try table.column(["midy", "midy(mm)", "centery", "centery(mm)", "posy", "y"])
        let rotation = try table.column(["rotation", "rotation(deg)", "rot", "angle"])
        let side = try table.column(["layer", "side"])
        let units = try table.optionalColumn(["unit", "units"])
        var result: [ManufacturingPlacement] = [], seen = Set<String>()
        guard table.rows.count <= 10_000 else { throw failure("CPL", "Oltre il limite di 10.000 posizionamenti.") }
        for (offset, row) in table.rows.enumerated() {
            try Task.checkCancellation()
            let subject = "CPL riga \(offset + 2)", ref = trimmed(row[reference])
            try validateReference(ref, seen: &seen, subject: subject)
            if let units, !["mm", "millimeter", "millimeters", "millimetre", "millimetres"].contains(trimmed(row[units]).lowercased()) {
                throw failure(subject, "Unità non supportata: esportare le posizioni in millimetri.")
            }
            let boardSide: BoardSide
            switch trimmed(row[side]).lowercased() {
            case "top", "t", "front": boardSide = .top
            case "bottom", "b", "back": boardSide = .bottom
            default: throw failure(subject, "Lato non riconosciuto: indicare top o bottom.")
            }
            result.append(.init(reference: ref,
                position: .init(try number(row[x], millimetres: true, subject: subject),
                                try number(row[y], millimetres: true, subject: subject)),
                rotationDegrees: try number(row[rotation], millimetres: false, subject: subject), side: boardSide))
        }
        return result
    }

    private static func number(_ text: String, millimetres: Bool, subject: String) throws -> Double {
        var text = trimmed(text).lowercased()
        if millimetres, text.hasSuffix("mm") { text = trimmed(String(text.dropLast(2))) }
        guard !text.isEmpty, text.matches("^[+-]?(?:[0-9]+(?:\\.[0-9]*)?|\\.[0-9]+)(?:e[+-]?[0-9]+)?$"),
              let value = Double(text), value.isFinite, abs(value) <= 1_000_000 else {
            throw failure(subject, "Coordinata o angolo non valido: usare numeri finiti, coordinate in mm e punto decimale.")
        }
        return value
    }
    private static func boolean(_ text: String, subject: String, kind: String) throws -> Bool {
        switch trimmed(text).lowercased() {
        case "1", "true", "yes", "y", "si", "sì": return true
        case "0", "false", "no", "n": return false
        case "dnp", "dnf", "not fitted", "not populated", "omit", "omitted": return kind == "DNP"
        case "fitted", "populated", "fit", "populate": return kind != "DNP"
        default: throw failure(subject, "Valore \(kind) non riconosciuto: specificare true/false, yes/no oppure 1/0.")
        }
    }
    private static func validateReference(_ reference: String, seen: inout Set<String>, subject: String) throws {
        guard reference.matches("^[A-Za-z][A-Za-z0-9_.-]{0,63}$") else {
            throw failure(subject, "Riferimento componente non valido.")
        }
        guard seen.insert(reference.uppercased()).inserted else { throw failure(subject, "Riferimento duplicato: \(reference).") }
    }
    private static func trimmed(_ text: String) -> String { text.trimmingCharacters(in: .whitespacesAndNewlines) }
    private static func failure(_ subject: String, _ message: String) -> ElectronicsFailure {
        .init([.init("manufacturing_csv", subject, message)])
    }

    private struct CSV {
        let headers: [String]
        let rows: [[String]]
        init(data: Data) throws {
            guard !data.isEmpty, data.count <= 16 * 1024 * 1024,
                  let decoded = String(data: data, encoding: .utf8), !decoded.contains("\0") else {
                throw failure("CSV", "File non UTF-8, vuoto o oltre 16 MiB.")
            }
            let text = decoded.hasPrefix("\u{feff}") ? String(decoded.dropFirst()) : decoded
            let bytes = Array(text.utf8)
            var quoted = false, commas = 0, semicolons = 0, index = 0, hasHeaderContent = false
            while index < bytes.count {
                let byte = bytes[index]
                if byte == 34 {
                    if quoted && index + 1 < bytes.count && bytes[index + 1] == 34 { index += 1 }
                    else { quoted.toggle() }
                } else if !quoted {
                    if byte == 10 || byte == 13 {
                        if hasHeaderContent { break }
                        index += 1; continue
                    }
                    if byte == 44 { commas += 1 }
                    if byte == 59 { semicolons += 1 }
                }
                if byte != 32 && byte != 9 { hasHeaderContent = true }
                index += 1
            }
            let delimiter: UInt8 = semicolons > commas ? 59 : 44
            var records: [[String]] = [], row: [String] = [], field: [UInt8] = []
            // 0 = unquoted/start, 1 = quoted, 2 = closing quote.
            var state = 0
            func flushField() throws {
                guard let string = String(bytes: field, encoding: .utf8) else { throw failure("CSV", "Campo non UTF-8.") }
                row.append(string); field.removeAll(keepingCapacity: true); state = 0
                guard row.count <= 64 else { throw failure("CSV", "Oltre 64 colonne.") }
            }
            func flushRow() throws {
                try flushField()
                if !row.allSatisfy({ trimmed($0).isEmpty }) { records.append(row) }
                row.removeAll(keepingCapacity: true)
                guard records.count <= 10_001 else { throw failure("CSV", "Oltre 10.000 righe.") }
            }
            index = 0
            while index < bytes.count {
                if index % 65_536 == 0 { try Task.checkCancellation() }
                let byte = bytes[index]
                if state == 1 {
                    if byte == 34 {
                        if index + 1 < bytes.count && bytes[index + 1] == 34 { field.append(34); index += 1 }
                        else { state = 2 }
                    } else { field.append(byte) }
                } else if byte == delimiter {
                    try flushField()
                } else if byte == 10 || byte == 13 {
                    try flushRow()
                    if byte == 13 && index + 1 < bytes.count && bytes[index + 1] == 10 { index += 1 }
                } else if byte == 34 && state == 0 && field.isEmpty {
                    state = 1
                } else {
                    guard state == 0 && byte != 34 else { throw failure("CSV", "Virgolette CSV non valide.") }
                    field.append(byte)
                }
                guard field.count <= 65_536 else { throw failure("CSV", "Campo oltre 64 KiB.") }
                index += 1
            }
            guard state != 1 else { throw failure("CSV", "Campo tra virgolette non terminato.") }
            if !field.isEmpty || !row.isEmpty || state == 2 { try flushRow() }
            guard records.count >= 2 else { throw failure("CSV", "Intestazione o righe dati mancanti.") }
            let names = records[0].map { Self.normalized($0) }
            guard !names.contains(""), Set(names).count == names.count,
                  records.dropFirst().allSatisfy({ $0.count == names.count }) else {
                throw failure("CSV", "Colonne duplicate, senza nome o righe con numero di campi diverso dall’intestazione.")
            }
            headers = names; rows = Array(records.dropFirst())
        }
        func optionalColumn(_ aliases: [String]) throws -> Int? {
            let found = headers.indices.filter { aliases.contains(headers[$0]) }
            guard found.count <= 1 else { throw failure("CSV", "Più colonne indicano lo stesso dato: \(aliases[0]).") }
            return found.first
        }
        func column(_ aliases: [String]) throws -> Int {
            guard let index = try optionalColumn(aliases) else { throw failure("CSV", "Colonna obbligatoria mancante: \(aliases[0]).") }
            return index
        }
        private static func normalized(_ text: String) -> String {
            trimmed(text).lowercased().filter { !$0.isWhitespace && $0 != "_" && $0 != "-" }
        }
    }
}
