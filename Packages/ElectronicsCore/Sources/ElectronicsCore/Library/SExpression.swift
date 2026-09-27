import Foundation

struct SExpression {
    var atom: String?
    var children: [SExpression] = []
    var line: Int
    var name: String { children.first?.atom ?? "" }
    func all(_ key: String) -> [Self] { children.filter { $0.atom == nil && $0.name == key } }
    func one(_ key: String, required: Bool = false) throws -> Self? {
        let found = all(key)
        guard found.count <= 1, !required || found.count == 1 else { throw invalid("Campo \(key) mancante o ripetuto.") }
        return found.first
    }
    func value(_ index: Int) throws -> String {
        guard children.indices.contains(index), let text = children[index].atom else { throw invalid("Valore mancante o non scalare.") }
        return text
    }
    func number(_ index: Int) throws -> Double {
        guard let n = Double(try value(index)), n.isFinite else { throw invalid("Numero non valido.") }
        return n
    }
    func point(ySign: Double = 1) throws -> PCBPoint { try PCBPoint(number(1), ySign * number(2)) }
    func allowed(_ names: Set<String>) throws {
        for child in children where child.atom == nil && !names.contains(child.name) {
            throw child.invalid("Costrutto \(child.name) non supportato: nessuna conversione approssimata eseguita.", code: "unsupported_construct")
        }
    }
    func invalid(_ message: String, code: String = "invalid_sexpression") -> ElectronicsFailure {
        LibraryImportSupport.error(code, "\(name), riga \(line)", message + " Controllare il file sorgente.")
    }
}

struct SExpressionReader {
    private var bytes: [UInt8]
    private var index = 0
    private var line = 1
    private var nodes = 0
    init(_ text: String) { bytes = Array(text.utf8) }
    mutating func read() throws -> SExpression {
        skip()
        let root = try node(depth: 0)
        skip()
        guard index == bytes.count, root.atom == nil else { throw error("Un solo documento tra parentesi è richiesto.") }
        return root
    }
    private mutating func node(depth: Int) throws -> SExpression {
        nodes += 1
        if nodes % 1024 == 0 { try Task.checkCancellation() }
        guard depth <= 64, nodes <= 500_000 else { throw error("Struttura troppo profonda o troppo grande.") }
        skip()
        guard index < bytes.count else { throw error("Documento interrotto.") }
        let startLine = line
        if bytes[index] == 40 {
            index += 1; var children: [SExpression] = []
            while true {
                skip(); guard index < bytes.count else { throw error("Parentesi finale mancante.") }
                if bytes[index] == 41 { index += 1; break }
                children.append(try node(depth: depth + 1))
            }
            guard children.first?.atom != nil else { throw error("Nome del costrutto mancante.") }
            return .init(children: children, line: startLine)
        }
        guard bytes[index] != 41 else { throw error("Parentesi finale inattesa.") }
        if bytes[index] == 34 {
            index += 1; var text: [UInt8] = []
            while index < bytes.count {
                let c = bytes[index]; index += 1
                if c == 34 { return .init(atom: String(decoding: text, as: UTF8.self), line: startLine) }
                if c == 92 {
                    guard index < bytes.count else { throw error("Escape interrotto.") }
                    let escaped = bytes[index]; index += 1
                    switch escaped {
                    case 34, 92: text.append(escaped)
                    case 110: text.append(10)
                    case 114: text.append(13)
                    case 116: text.append(9)
                    default: throw error("Escape non riconosciuto.")
                    }
                } else { text.append(c); if c == 10 { line += 1 } }
            }
            throw error("Stringa senza virgolette finali.")
        }
        let start = index
        while index < bytes.count && ![9, 10, 13, 32, 40, 41, 59].contains(bytes[index]) {
            guard bytes[index] != 34 else { throw error("Virgolette in un valore non delimitato.") }
            index += 1
        }
        guard index > start else { throw error("Valore vuoto.") }
        return .init(atom: String(decoding: bytes[start..<index], as: UTF8.self), line: startLine)
    }
    private mutating func skip() {
        while index < bytes.count {
            if bytes[index] == 59 { while index < bytes.count && bytes[index] != 10 { index += 1 } }
            guard index < bytes.count else { return }
            switch bytes[index] {
            case 10: line += 1; index += 1
            case 9, 13, 32: index += 1
            default: return
            }
        }
    }
    private func error(_ message: String) -> ElectronicsFailure {
        LibraryImportSupport.error("invalid_sexpression", "riga \(line)", message + " Esportare nuovamente il file KiCad.")
    }
}
