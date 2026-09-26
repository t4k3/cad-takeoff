import Foundation

// User parameters and expressions, as in Fusion's «Parametri»: named values (`larghezza = 40`)
// that dimensions and feature sizes can use (`larghezza / 2 + 3`). Lengths are millimetres,
// angles degrees; trigonometric functions take degrees.

public enum ExpressionError: Error, Equatable, LocalizedError {
    case syntax(String)
    case unknown(String)
    case cycle(String)
    case invalidName(String)
    case duplicate(String)

    public var errorDescription: String? {
        switch self {
        case let .syntax(s): "espressione non valida: \(s)"
        case let .unknown(n): "parametro sconosciuto «\(n)»"
        case let .cycle(n): "«\(n)» dipende da sé stesso"
        case let .invalidName(n): "nome non valido «\(n)»: lettere, cifre e _, senza spazi, non una funzione"
        case let .duplicate(n): "c'è già un parametro «\(n)»"
        }
    }
}

public enum Formula {
    static let functions: Set<String> = ["sqrt", "abs", "sin", "cos", "tan", "asin", "acos", "atan", "min", "max", "round", "floor", "ceil"]
    static let constants: [String: Double] = ["pi": .pi, "PI": .pi]

    /// Value of `text` with the given parameter values. Numbers may use a decimal comma (then
    /// function arguments are separated by ";" or ", " with a space); "mm" and "°"/"deg" after a
    /// number are accepted and ignored.
    public static func evaluate(_ text: String, _ values: [String: Double] = [:]) throws -> Double {
        var p = Parser(tokens: try tokenize(text), values: values)
        let v = try p.expression()
        guard p.atEnd else { throw ExpressionError.syntax("«\(p.rest)» in più") }
        guard v.isFinite else { throw ExpressionError.syntax("risultato non finito") }
        return v
    }

    /// Parameter names an expression uses.
    public static func names(in text: String) -> Set<String> {
        guard let tokens = try? tokenize(text) else { return [] }
        var out = Set<String>()
        for (i, t) in tokens.enumerated() {
            if case let .name(n) = t, constants[n] == nil {
                let isCall = i + 1 < tokens.count && tokens[i + 1] == .symbol("(")
                if !(isCall && functions.contains(n)) { out.insert(n) }
            }
        }
        return out
    }

    /// Whether `text` is a plain number (not an expression).
    public static func isNumber(_ text: String) -> Bool {
        guard let tokens = try? tokenize(text) else { return false }
        if tokens.count == 1, case .number = tokens[0] { return true }
        if tokens.count == 2, tokens[0] == .symbol("-"), case .number = tokens[1] { return true }
        return false
    }

    public static func isValidName(_ n: String) -> Bool {
        guard let f = n.unicodeScalars.first, CharacterSet.letters.contains(f) || f == "_" else { return false }
        return n.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) || $0 == "_" }
            && !functions.contains(n) && constants[n] == nil && !["mm", "deg"].contains(n)
    }

    // MARK: Tokens

    enum Token: Equatable {
        case number(Double)
        case name(String)
        case symbol(Character)
    }

    static func tokenize(_ text: String) throws -> [Token] {
        var out: [Token] = []
        let chars = Array(text)
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if c.isWhitespace { i += 1; continue }
            if c.isNumber || ((c == "." || c == ",") && i + 1 < chars.count && chars[i + 1].isNumber) {
                var s = ""
                while i < chars.count, chars[i].isNumber || ((chars[i] == "." || chars[i] == ",") && i + 1 < chars.count && chars[i + 1].isNumber) {
                    s.append(chars[i] == "," ? "." : chars[i]); i += 1
                }
                if i < chars.count, chars[i] == "e" || chars[i] == "E", i + 1 < chars.count,
                   chars[i + 1].isNumber || ((chars[i + 1] == "-" || chars[i + 1] == "+") && i + 2 < chars.count && chars[i + 2].isNumber) {
                    s.append("e"); i += 1
                    if chars[i] == "-" || chars[i] == "+" { s.append(chars[i]); i += 1 }
                    while i < chars.count, chars[i].isNumber { s.append(chars[i]); i += 1 }
                }
                guard let v = Double(s) else { throw ExpressionError.syntax("numero «\(s)»") }
                out.append(.number(v))
                // Units after a number: ignored (mm, °, deg).
                var j = i
                while j < chars.count, chars[j].isWhitespace { j += 1 }
                if j < chars.count, chars[j] == "°" { i = j + 1 }
                else if j + 1 < chars.count, String(chars[j...(j + 1)]) == "mm", !(j + 2 < chars.count && (chars[j + 2].isLetter || chars[j + 2] == "_")) { i = j + 2 }
                else if j + 2 < chars.count, String(chars[j...(j + 2)]) == "deg", !(j + 3 < chars.count && (chars[j + 3].isLetter || chars[j + 3] == "_")) { i = j + 3 }
                continue
            }
            if c.isLetter || c == "_" {
                var s = ""
                while i < chars.count, chars[i].isLetter || chars[i].isNumber || chars[i] == "_" { s.append(chars[i]); i += 1 }
                out.append(.name(s))
                continue
            }
            if "+-*/^(),;×÷".contains(c) {
                // A comma between two digits was taken as a decimal separator above; here it separates arguments.
                out.append(.symbol(c == "×" ? "*" : c == "÷" ? "/" : c == ";" ? "," : c))
                i += 1
                continue
            }
            throw ExpressionError.syntax("carattere «\(c)»")
        }
        guard !out.isEmpty else { throw ExpressionError.syntax("vuota") }
        return out
    }

    // MARK: Parser (recursive descent)

    struct Parser {
        let tokens: [Token]
        let values: [String: Double]
        var i = 0

        init(tokens: [Token], values: [String: Double]) { self.tokens = tokens; self.values = values }

        var atEnd: Bool { i >= tokens.count }
        var rest: String {
            tokens[i...].map { t -> String in
                switch t { case let .number(v): "\(v)"; case let .name(n): n; case let .symbol(c): String(c) }
            }.joined(separator: " ")
        }
        func peek(_ c: Character) -> Bool { !atEnd && tokens[i] == .symbol(c) }

        mutating func expression() throws -> Double {
            var v = try term()
            while peek("+") || peek("-") {
                let plus = peek("+"); i += 1
                let r = try term()
                v = plus ? v + r : v - r
            }
            return v
        }

        mutating func term() throws -> Double {
            var v = try unary()
            while peek("*") || peek("/") {
                let times = peek("*"); i += 1
                let r = try unary()
                if !times, r == 0 { throw ExpressionError.syntax("divisione per zero") }
                v = times ? v * r : v / r
            }
            return v
        }

        mutating func unary() throws -> Double {
            if peek("-") { i += 1; return -(try unary()) }
            if peek("+") { i += 1; return try unary() }
            return try power()
        }

        mutating func power() throws -> Double {
            let base = try primary()
            if peek("^") { i += 1; return pow(base, try unary()) }   // right-associative
            return base
        }

        mutating func primary() throws -> Double {
            guard !atEnd else { throw ExpressionError.syntax("manca un valore alla fine") }
            let t = tokens[i]
            i += 1
            switch t {
            case let .number(v):
                return v
            case .symbol("("):
                let v = try expression()
                guard peek(")") else { throw ExpressionError.syntax("manca «)»") }
                i += 1
                return v
            case let .name(n):
                if peek("("), Formula.functions.contains(n) {
                    i += 1
                    var args = [try expression()]
                    while peek(",") { i += 1; args.append(try expression()) }
                    guard peek(")") else { throw ExpressionError.syntax("manca «)» dopo \(n)(") }
                    i += 1
                    return try call(n, args)
                }
                if let v = values[n] { return v }
                if let v = Formula.constants[n] { return v }
                throw ExpressionError.unknown(n)
            case let .symbol(c):
                throw ExpressionError.syntax("«\(c)» fuori posto")
            }
        }

        func call(_ n: String, _ a: [Double]) throws -> Double {
            let rad = Double.pi / 180
            func one() throws -> Double {
                guard a.count == 1 else { throw ExpressionError.syntax("\(n) vuole un argomento") }
                return a[0]
            }
            switch n {
            case "sqrt": let x = try one(); guard x >= 0 else { throw ExpressionError.syntax("radice di un negativo") }; return x.squareRoot()
            case "abs": return abs(try one())
            case "sin": return sin(try one() * rad)
            case "cos": return cos(try one() * rad)
            case "tan": return tan(try one() * rad)
            case "asin": return asin(try one()) / rad
            case "acos": return acos(try one()) / rad
            case "atan": return atan(try one()) / rad
            case "round": return (try one()).rounded()
            case "floor": return (try one()).rounded(.down)
            case "ceil": return (try one()).rounded(.up)
            case "min", "max":
                guard !a.isEmpty else { throw ExpressionError.syntax("\(n) senza argomenti") }
                return n == "min" ? a.min()! : a.max()!
            default: throw ExpressionError.unknown(n)
            }
        }
    }
}

/// A named value of the design (Fusion's user parameter).
public struct UserParameter: Identifiable, Codable, Sendable, Equatable {
    public var id: UUID
    public var name: String
    /// A number or an expression of other parameters (e.g. "larghezza / 2").
    public var expression: String
    public var comment: String

    public init(id: UUID = UUID(), name: String, expression: String, comment: String = "") {
        self.id = id; self.name = name; self.expression = expression; self.comment = comment
    }
}

extension CADDocument {
    /// Values of the user parameters, each after the ones it uses. Throws on unknown names,
    /// cycles, invalid or duplicate names and bad expressions.
    public func parameterValues() throws -> [String: Double] {
        try Self.values(of: parameters)
    }

    public static func values(of parameters: [UserParameter]) throws -> [String: Double] {
        var byName: [String: UserParameter] = [:]
        for p in parameters {
            guard Formula.isValidName(p.name) else { throw ExpressionError.invalidName(p.name) }
            guard byName[p.name] == nil else { throw ExpressionError.duplicate(p.name) }
            byName[p.name] = p
        }
        var values: [String: Double] = [:]
        var visiting = Set<String>()
        func value(_ n: String) throws -> Double {
            if let v = values[n] { return v }
            guard let p = byName[n] else { throw ExpressionError.unknown(n) }
            guard visiting.insert(n).inserted else { throw ExpressionError.cycle(n) }
            for dep in Formula.names(in: p.expression) where byName[dep] != nil { _ = try value(dep) }
            let v = try Formula.evaluate(p.expression, values)
            visiting.remove(n)
            values[n] = v
            return v
        }
        for p in parameters { _ = try value(p.name) }
        return values
    }

    /// The design with every expression re-evaluated: sketch dimensions (then the sketch is
    /// re-solved) and feature sizes. Throws when an expression fails or a sketch cannot follow;
    /// returns the IDs of the sketches that changed (their extrusions need regenerating).
    public mutating func applyParameters() throws -> [UUID] {
        let values = try parameterValues()
        var changedSketches: [UUID] = []
        var sketches = self.sketches
        for k in sketches.indices {
            var s = sketches[k]
            var touched = false
            for i in s.constraints.indices {
                guard let e = s.constraints[i].expression, s.constraints[i].kind.value != nil else { continue }
                let v = try Formula.evaluate(e, values)
                if s.constraints[i].kind.value != v { s.constraints[i].kind = s.constraints[i].kind.with(value: v); touched = true }
            }
            guard touched else { continue }
            guard s.solve() else { throw ExpressionError.syntax("lo schizzo «\(s.name)» non riesce a rispettare le nuove quote") }
            sketches[k] = s
            changedSketches.append(s.id)
        }
        if !changedSketches.isEmpty { self.sketches = sketches }
        var features = self.features
        var featuresChanged = false
        for k in features.indices where !features[k].expressions.isEmpty {
            var f = features[k]
            for (key, e) in f.expressions { f.setSize(key, try Formula.evaluate(e, values)) }
            if f != features[k] { features[k] = f; featuresChanged = true }
        }
        if featuresChanged { self.features = features }
        return changedSketches
    }
}

extension CADDocument {
    /// Drops the expressions that no longer give their size or dimension (changed by hand: the
    /// typed value wins over the expression, as in Fusion). Returns whether any went.
    @discardableResult
    public mutating func dropStaleExpressions() -> Bool {
        let hasAny = features.contains { !$0.expressions.isEmpty } || sketches.contains { $0.constraints.contains { $0.expression != nil } }
        guard hasAny, let values = try? parameterValues() else { return false }
        func stale(_ e: String, _ v: Double?) -> Bool {
            guard let v, let x = try? Formula.evaluate(e, values) else { return false }
            return abs(x - v) > 1e-9 * max(1, abs(v))
        }
        var dropped = false
        var fs = features
        for k in fs.indices {
            for (key, e) in fs[k].expressions where stale(e, fs[k].size(key)) { fs[k].expressions[key] = nil; dropped = true }
        }
        var ss = sketches
        for k in ss.indices {
            for i in ss[k].constraints.indices {
                if let e = ss[k].constraints[i].expression, stale(e, ss[k].constraints[i].kind.value) {
                    ss[k].constraints[i].expression = nil; dropped = true
                }
            }
        }
        if dropped { features = fs; sketches = ss }
        return dropped
    }
}

extension Feature {
    /// Sizes an expression can drive, by key.
    public static let sizeKeys = ["width", "depth", "height", "radius"]

    public func size(_ key: String) -> Double? {
        switch (kind, key) {
        case let (.box(w, _, _), "width"): w
        case let (.box(_, d, _), "depth"): d
        case let (.box(_, _, h), "height"): h
        case let (.cylinder(r, _), "radius"): r
        case let (.cylinder(_, h), "height"): h
        case let (.extrude(_, h), "height"): h
        default: nil
        }
    }

    public mutating func setSize(_ key: String, _ v: Double) {
        switch (kind, key) {
        case let (.box(_, d, h), "width"): kind = .box(width: v, depth: d, height: h)
        case let (.box(w, _, h), "depth"): kind = .box(width: w, depth: v, height: h)
        case let (.box(w, d, _), "height"): kind = .box(width: w, depth: d, height: v)
        case let (.cylinder(_, h), "radius"): kind = .cylinder(radius: v, height: h)
        case let (.cylinder(r, _), "height"): kind = .cylinder(radius: r, height: v)
        case let (.extrude(p, _), "height"): kind = .extrude(profile: p, height: v)
        default: break
        }
    }
}
