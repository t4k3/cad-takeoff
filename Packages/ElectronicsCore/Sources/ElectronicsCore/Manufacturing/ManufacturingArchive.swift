import Foundation
import CElectronicsArchive

public struct ManufacturingInputFile: Codable, Equatable, Sendable {
    public var name: String
    public var data: Data
    public init(name: String, data: Data) { self.name = name; self.data = data }
}

/// In-memory ZIP reader. No files are created and no external process is executed.
/// Supports stored/DEFLATE ZIP32 with UTF-8 names, including signed/unsigned data descriptors.
public enum ManufacturingArchive {
    public static func read(_ data: Data) throws -> [ManufacturingInputFile] {
        guard data.count >= 22, data.count <= 64 * 1024 * 1024 else {
            throw failure("Dimensione ZIP non valida (limite 64 MiB).")
        }
        let bytes = Array(data)
        func u16(_ p: Int) -> Int { Int(bytes[p]) | Int(bytes[p + 1]) << 8 }
        func u32(_ p: Int) -> Int { u16(p) | u16(p + 2) << 16 }
        func extra(_ start: Int, _ count: Int) throws {
            var p = start
            while p < start + count {
                guard p + 4 <= start + count else { throw failure("Campi extra ZIP troncati.") }
                let tag = u16(p), size = u16(p + 2)
                guard tag != 1, p + 4 + size <= start + count else {
                    throw failure("ZIP64 o campi extra non validi: esportare un archivio ZIP standard.")
                }
                p += 4 + size
            }
        }
        var end: Int?
        for p in stride(from: bytes.count - 22, through: max(0, bytes.count - 22 - 65_535), by: -1) {
            if u32(p) == 0x06054b50, p + 22 + u16(p + 20) == bytes.count { end = p; break }
        }
        guard let end, u16(end + 4) == 0, u16(end + 6) == 0,
              u16(end + 8) == u16(end + 10), (1...256).contains(u16(end + 10)),
              u32(end + 12) != 0xffff_ffff, u32(end + 16) != 0xffff_ffff else {
            throw failure("Indice ZIP mancante, ZIP64, multidisco o numero di file oltre 256.")
        }
        let centralStart = u32(end + 16), centralSize = u32(end + 12)
        guard centralStart + centralSize == end else { throw failure("Indice ZIP incoerente.") }
        var cursor = centralStart, total = 0
        var result: [ManufacturingInputFile] = [], paths = Set<String>(), ranges: [Range<Int>] = []
        for _ in 0..<u16(end + 10) {
            try Task.checkCancellation()
            guard cursor + 46 <= end, u32(cursor) == 0x02014b50 else { throw failure("Voce ZIP troncata.") }
            let flags = u16(cursor + 8), method = u16(cursor + 10), crc = u32(cursor + 16)
            let packed = u32(cursor + 20), unpacked = u32(cursor + 24)
            let nameSize = u16(cursor + 28), extraSize = u16(cursor + 30), commentSize = u16(cursor + 32)
            let local = u32(cursor + 42), attributes = u32(cursor + 38)
            guard flags & ~0x080e == 0, method == 0 || method == 8,
                  method != 0 || flags & 6 == 0, u16(cursor + 34) == 0,
                  packed != 0xffff_ffff, unpacked <= 32 * 1024 * 1024,
                  total + unpacked <= 128 * 1024 * 1024,
                  unpacked <= max(1_048_576, packed * 1_000), local != 0xffff_ffff,
                  cursor + 46 + nameSize + extraSize + commentSize <= end else {
                throw failure("ZIP cifrato, formato non supportato o limiti di decompressione superati.")
            }
            let rawName = Array(bytes[(cursor + 46)..<(cursor + 46 + nameSize)])
            guard let name = String(bytes: rawName, encoding: .utf8), !name.isEmpty,
                  name.utf8.count <= 1024, !name.contains("\\"), !name.contains(":"), !name.hasPrefix("/"),
                  !name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
                throw failure("Nome file ZIP non UTF-8 o non sicuro.")
            }
            let isDirectory = name.hasSuffix("/")
            let components = (isDirectory ? String(name.dropLast()) : name).split(separator: "/", omittingEmptySubsequences: false)
            let canonical = components.joined(separator: "/").precomposedStringWithCanonicalMapping.lowercased()
            let mode = (attributes >> 16) & 0xf000
            guard components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }),
                  paths.insert(canonical).inserted,
                  mode == 0 || mode == 0x8000 || (mode == 0x4000 && isDirectory),
                  !isDirectory || unpacked == 0 else {
                throw failure("Percorso ZIP duplicato, collegamento o percorso non sicuro.")
            }
            try extra(cursor + 46 + nameSize, extraSize)
            guard local + 30 <= centralStart, u32(local) == 0x04034b50,
                  u16(local + 6) == flags, u16(local + 8) == method, u16(local + 26) == nameSize else {
                throw failure("Intestazione locale ZIP incoerente.")
            }
            let localExtraSize = u16(local + 28), payload = local + 30 + nameSize + localExtraSize
            guard payload + packed <= centralStart,
                  Array(bytes[(local + 30)..<(local + 30 + nameSize)]) == rawName else {
                throw failure("Dati ZIP troncati o nome locale incoerente.")
            }
            try extra(local + 30 + nameSize, localExtraSize)
            let descriptor = flags & 8 != 0
            guard descriptor || (u32(local + 14) == crc && u32(local + 18) == packed && u32(local + 22) == unpacked) else {
                throw failure("CRC o dimensioni ZIP locali incoerenti.")
            }
            var recordEnd = payload + packed
            if descriptor {
                guard [0, crc].contains(u32(local + 14)), [0, packed].contains(u32(local + 18)),
                      [0, unpacked].contains(u32(local + 22)), recordEnd + 12 <= centralStart else {
                    throw failure("Descrittore ZIP mancante o incoerente.")
                }
                // An unsigned descriptor's CRC can itself equal the optional signature.
                let candidates = u32(recordEnd) == 0x08074b50 ? [recordEnd + 4, recordEnd] : [recordEnd]
                guard let start = candidates.first(where: {
                    $0 + 12 <= centralStart && u32($0) == crc && u32($0 + 4) == packed && u32($0 + 8) == unpacked
                }) else {
                    throw failure("Descrittore ZIP incoerente.")
                }
                recordEnd = start + 12
            }
            let range = local..<recordEnd
            guard !ranges.contains(where: { $0.overlaps(range) }) else { throw failure("Voci ZIP sovrapposte.") }
            ranges.append(range)
            let content: Data
            if method == 0 {
                guard packed == unpacked else { throw failure("Dimensioni ZIP non compresso incoerenti.") }
                content = Data(bytes[payload..<(payload + packed)])
            } else {
                var output = [UInt8](repeating: 0, count: unpacked + 1)
                let valid = bytes.withUnsafeBufferPointer { input in
                    output.withUnsafeMutableBufferPointer { out in
                        electronics_inflate_raw(input.baseAddress!.advanced(by: payload), packed, out.baseAddress!, unpacked)
                    }
                }
                guard valid != 0 else { throw failure("Flusso DEFLATE non valido o dimensione incoerente.") }
                content = Data(output.prefix(unpacked))
            }
            let actualCRC = content.withUnsafeBytes { raw in electronics_crc32(raw.bindMemory(to: UInt8.self).baseAddress, content.count) }
            guard actualCRC == UInt32(crc) else { throw failure("CRC ZIP non valido: riscaricare il pacchetto.") }
            total += unpacked
            if !isDirectory { result.append(.init(name: name, data: content)) }
            cursor += 46 + nameSize + extraSize + commentSize
        }
        guard cursor == end, !result.isEmpty else { throw failure("Indice ZIP incoerente o archivio senza file.") }
        return result.sorted { $0.name < $1.name }
    }

    private static func failure(_ message: String) -> ElectronicsFailure {
        .init([.init("manufacturing_archive", "ZIP", message)])
    }
}
