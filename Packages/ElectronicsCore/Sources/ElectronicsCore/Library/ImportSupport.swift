import Foundation
import CryptoKit

public struct LibraryImportContext: Codable, Equatable, Sendable {
    public var key: LibraryRevision
    public var source: LibrarySource
    /// Supplied deliberately: neither external format guarantees a physical pick-up centroid.
    public var assemblyCentroid: PCBPoint
    public init(key: LibraryRevision, source: LibrarySource, assemblyCentroid: PCBPoint = .init()) {
        self.key = key; self.source = source; self.assemblyCentroid = assemblyCentroid
    }
}

/// Preview only. Source bytes and diagnostics accompany the proposed library, until an explicit
/// command confirms the supported subset. No disk/network I/O or project mutation in importers.
public struct LibraryImportResult: Codable, Equatable, Sendable {
    public var library: ElectronicsLibrary
    public var issues: [ElectronicsIssue]
    public var format: String
    public var originalSource: String
    public var sourceSHA256: String
}

enum LibraryImportSupport {
    static func text(_ data: Data) throws -> String {
        guard data.count <= 16 * 1024 * 1024 else { throw error("import_too_large", "file", "File oltre 16 MiB: suddividere la libreria.") }
        guard let text = String(data: data, encoding: .utf8), !text.contains("\0") else {
            throw error("invalid_encoding", "file", "File non UTF-8 o contenente byte nulli: esportare nuovamente.")
        }
        return text
    }
    static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    /// UUID v8 with a SHA-256-derived payload, scoped to a library identity, independent of revision.
    static func id(_ root: UUID, _ path: String) -> UUID {
        var bytes = Array(SHA256.hash(data: Data((root.uuidString + "\0" + path).utf8)).prefix(16))
        bytes[6] = (bytes[6] & 0x0f) | 0x80; bytes[8] = (bytes[8] & 0x3f) | 0x80
        return UUID(uuid: (bytes[0],bytes[1],bytes[2],bytes[3],bytes[4],bytes[5],bytes[6],bytes[7],bytes[8],bytes[9],bytes[10],bytes[11],bytes[12],bytes[13],bytes[14],bytes[15]))
    }
    static func error(_ code: String, _ subject: String, _ message: String, id: UUID? = nil) -> ElectronicsFailure {
        var issue = ElectronicsIssue(code, subject, message)
        issue.subjectIDs = id.map { [$0] }; return ElectronicsFailure([issue])
    }
    static func result(library: ElectronicsLibrary, issues: [ElectronicsIssue], format: String,
                       original: String) throws -> LibraryImportResult {
        try ElectronicsValidation.requireLibrary(library)
        let ids = library.symbols.map(\.key.id) + library.footprints.map(\.key.id)
        let attributed = issues.map { issue in
            var issue = issue
            if issue.subjectIDs == nil { issue.subjectIDs = ids }
            return issue
        }
        return .init(library: library, issues: attributed, format: format, originalSource: original, sourceSHA256: digest(Data(original.utf8)))
    }
}

extension ElectronicsValidation {
    /// Reuses the domain validation; the temporary empty board never escapes this boundary.
    public static func requireLibrary(_ library: ElectronicsLibrary) throws {
        let design = ElectronicsDesign(id: UUID(uuidString: "00000000-0000-0000-0000-000000000000")!, name: "Library validation", library: library,
                                       board: .init(outline: [.init(0,0), .init(1,0), .init(0,1)]))
        try requireIntegrity(design)
    }
}
