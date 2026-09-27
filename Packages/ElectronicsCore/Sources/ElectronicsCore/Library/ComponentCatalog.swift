import Foundation

public struct CatalogColumns: Codable, Equatable, Sendable {
    public var partNumber = "LCSC Part #"
    public var manufacturer = "Manufacturer"
    public var mpn = "MPN"
    public var package = "Package"
    public var description = "Description"
    public var stock: String? = "Stock"
    public var datasheet: String? = "Datasheet"
    public init() {}
}

public struct SupplierCatalogPart: Codable, Equatable, Sendable {
    public var partNumber: String
    public var manufacturer: String
    public var manufacturerPartNumber: String
    public var package: String
    public var description: String
    public var stock: Int?
    public var datasheet: String?
    public var attributes: [String: String]
}

/// An offline observation, never a claim of live stock or validated electrical equivalence.
/// Networking/authentication is a separate adapter, not an implicit side effect of search.
public struct SupplierCatalogSnapshot: Codable, Equatable, Sendable {
    public let formatVersion: Int
    public let sourceReference: String
    public let observedAt: Date
    public let sourceSHA256: String
    public let parts: [SupplierCatalogPart]

    init(formatVersion: Int, sourceReference: String, observedAt: Date, sourceSHA256: String, parts: [SupplierCatalogPart]) throws {
        self.formatVersion = formatVersion; self.sourceReference = sourceReference; self.observedAt = observedAt
        self.sourceSHA256 = sourceSHA256; self.parts = parts
        guard formatVersion == 1, !sourceReference.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              observedAt.timeIntervalSince1970.isFinite, sourceSHA256.matches("^[0-9a-f]{64}$"),
              Set(parts.map(\.partNumber)).count == parts.count,
              parts.allSatisfy({ p in
                  p.partNumber.matches("^C[0-9]+$") && (p.stock == nil || p.stock! >= 0) &&
                  [p.manufacturer, p.manufacturerPartNumber, p.package].allSatisfy { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
              }) else {
            throw LibraryImportSupport.error("invalid_catalog_snapshot", "catalogo", "Catalogo salvato non valido o versione non supportata: importare nuovamente i dati.")
        }
    }

    private enum CodingKeys: String, CodingKey { case formatVersion, sourceReference, observedAt, sourceSHA256, parts }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(formatVersion: c.decode(Int.self, forKey: .formatVersion), sourceReference: c.decode(String.self, forKey: .sourceReference),
                      observedAt: c.decode(Date.self, forKey: .observedAt), sourceSHA256: c.decode(String.self, forKey: .sourceSHA256),
                      parts: c.decode([SupplierCatalogPart].self, forKey: .parts))
    }

    public func search(_ query: String, availableOnly: Bool = false, limit: Int = 50) -> [SupplierCatalogPart] {
        let q = normalized(query.trimmingCharacters(in: .whitespacesAndNewlines))
        func rank(_ p: SupplierCatalogPart) -> Int {
            [p.partNumber, p.manufacturerPartNumber].contains { normalized($0) == q } ? 0 : 1
        }
        return Array(parts.filter { p in
            (!availableOnly || (p.stock ?? 0) > 0) && (q.isEmpty || [p.partNumber, p.manufacturer,
                p.manufacturerPartNumber, p.package, p.description].contains { normalized($0).contains(q) })
        }.sorted { a,b in rank(a) == rank(b) ? a.partNumber < b.partNumber : rank(a) < rank(b) }.prefix(max(0, min(limit, 1000))))
    }

    public func observationIsOlder(than seconds: TimeInterval, at date: Date) -> Bool {
        date.timeIntervalSince(observedAt) > max(0, seconds)
    }

    /// Manufacturer and exact MPN must match. No footprint-name heuristic or automatic alternative.
    /// Side rotations remain unset until calibrated; selecting a catalog row cannot invent them.
    public func jlcPart(number: String, for device: DeviceDefinition) throws -> JLCAssemblyPart {
        guard let part = parts.first(where: { $0.partNumber == number }) else {
            throw LibraryImportSupport.error("catalog_part_missing", number, "Componente assente dall’osservazione del catalogo: aggiornare i dati.")
        }
        guard normalized(part.manufacturer) == normalized(device.manufacturer),
              part.manufacturerPartNumber == device.manufacturerPartNumber.trimmingCharacters(in: .whitespacesAndNewlines) else {
            throw LibraryImportSupport.error("catalog_identity_mismatch", number, "Produttore o MPN non corrispondono al dispositivo: verificare il componente esatto.")
        }
        return .init(partNumber: part.partNumber,
                     catalogReference: sourceReference + " | observed " + ISO8601DateFormatter().string(from: observedAt))
    }
    private func normalized(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
    }
}

public enum ComponentCatalogImporter {
    /// Caller provides provenance and acquisition time. Columns map an actual supplier export;
    /// the default names describe our normalized interchange CSV, not an undocumented JLC API.
    public static func csv(_ data: Data, columns: CatalogColumns = .init(), sourceReference: String,
                           observedAt: Date) throws -> SupplierCatalogSnapshot {
        guard !sourceReference.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              observedAt.timeIntervalSince1970.isFinite else {
            throw LibraryImportSupport.error("missing_catalog_provenance", "catalogo", "Specificare origine e data di acquisizione dei dati.")
        }
        var text = try LibraryImportSupport.text(data)
        if text.first == "\u{feff}" { text.removeFirst() }
        let rows = try CSVReader.read(text)
        guard let header = rows.first, Set(header).count == header.count else {
            throw LibraryImportSupport.error("invalid_csv_header", "catalogo", "Intestazioni mancanti o duplicate: verificare le colonne.")
        }
        let required = [columns.partNumber, columns.manufacturer, columns.mpn, columns.package, columns.description]
        guard Set(required).count == required.count, required.allSatisfy(header.contains) else {
            throw LibraryImportSupport.error("missing_catalog_columns", "catalogo", "Associare le colonne codice, produttore, MPN, package e descrizione.")
        }
        var parts: [SupplierCatalogPart] = []; var seen = Set<String>()
        for (index, row) in rows.dropFirst().enumerated() {
            if index % 1024 == 0 { try Task.checkCancellation() }
            guard row.count == header.count else { throw LibraryImportSupport.error("invalid_csv_row", "riga \(index+2)", "Numero di colonne diverso dall’intestazione.") }
            let record = Dictionary(uniqueKeysWithValues: zip(header, row))
            func value(_ column: String) -> String { record[column, default: ""].trimmingCharacters(in: .whitespacesAndNewlines) }
            let number = value(columns.partNumber).uppercased()
            guard number.matches("^C[0-9]+$"), seen.insert(number).inserted,
                  !value(columns.manufacturer).isEmpty, !value(columns.mpn).isEmpty, !value(columns.package).isEmpty else {
                throw LibraryImportSupport.error("invalid_catalog_part", "riga \(index+2)", "Codice non valido/duplicato o identità incompleta: correggere il catalogo.")
            }
            var stock: Int?
            if let column = columns.stock, let raw = record[column], !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                guard let parsed = Int(raw.trimmingCharacters(in: .whitespacesAndNewlines)), parsed >= 0 else {
                    throw LibraryImportSupport.error("invalid_catalog_stock", number, "Disponibilità non valida: usare un intero positivo o lasciare vuoto per sconosciuta.")
                }; stock = parsed
            }
            let datasheet = columns.datasheet.flatMap { record[$0] }.flatMap { $0.isEmpty ? nil : $0 }
            parts.append(.init(partNumber: number, manufacturer: value(columns.manufacturer), manufacturerPartNumber: value(columns.mpn),
                               package: value(columns.package), description: value(columns.description), stock: stock,
                               datasheet: datasheet, attributes: record))
        }
        return try .init(formatVersion: 1, sourceReference: sourceReference, observedAt: observedAt,
                     sourceSHA256: LibraryImportSupport.digest(data), parts: parts.sorted { $0.partNumber < $1.partNumber })
    }
}

enum CSVReader {
    static func read(_ text: String) throws -> [[String]] {
        let chars = Array(text); var i = 0; var rows: [[String]] = []; var row: [String] = []; var field = ""
        var quoted = false, closedQuote = false, started = false
        func failure() -> ElectronicsFailure { LibraryImportSupport.error("invalid_csv", "catalogo", "Virgolette o separatori CSV non validi: esportare come CSV standard con virgole.") }
        while i < chars.count {
            if i % 4096 == 0 { try Task.checkCancellation() }
            let c = chars[i]
            if quoted {
                if c == "\"" {
                    if i+1 < chars.count && chars[i+1] == "\"" { field.append("\""); i += 1 }
                    else { quoted = false; closedQuote = true }
                } else { field.append(c) }
            } else if c == "," {
                row.append(field); field = ""; closedQuote = false; started = false
            } else if c == "\n" || c == "\r" || c == "\r\n" {
                row.append(field); rows.append(row); row = []; field = ""; closedQuote = false; started = false
                if c == "\r", i+1 < chars.count, chars[i+1] == "\n" { i += 1 }
            } else if c == "\"" {
                guard !started && !closedQuote else { throw failure() }; quoted = true; started = true
            } else {
                guard !closedQuote else { throw failure() }; field.append(c); started = true
            }
            i += 1
        }
        guard !quoted else { throw failure() }
        if started || closedQuote || !field.isEmpty || !row.isEmpty { row.append(field); rows.append(row) }
        return rows
    }
}
