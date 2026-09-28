import Foundation

/// A local mask operand. Contours at radius zero use even-odd fill. A single point with
/// radius is a disk; two points with radius form a capsule. Coordinates are mm, top view.
/// Apply operands IN ORDER to a transparent mask, dark = union, clear = subtraction.
public struct ManufacturingShape: Codable, Equatable, Sendable {
    public let contours: [[PCBPoint]]
    public let radius: Double
    public let isDark: Bool
    public init(contours: [[PCBPoint]], radius: Double, isDark: Bool = true) {
        self.contours = contours; self.radius = radius; self.isDark = isDark
    }
}

/// First composite shapes into a local mask, then apply that mask once to the layer.
/// Clear shapes inside an aperture never clear unrelated earlier layer objects.
public struct ManufacturingPrimitive: Codable, Equatable, Sendable {
    public let id: UUID
    public let shapes: [ManufacturingShape]
    public let isDark: Bool
    public let netName: String?
    public let componentReference: String?
    public let pinNumber: String?
    public init(id: UUID, shapes: [ManufacturingShape], isDark: Bool = true,
                netName: String? = nil, componentReference: String? = nil, pinNumber: String? = nil) {
        self.id = id; self.shapes = shapes; self.isDark = isDark
        self.netName = netName; self.componentReference = componentReference; self.pinNumber = pinNumber
    }
}

/// Primitive order is significant. Solder mask geometry denotes OPENINGS, as in FabricationLayer.
public struct ManufacturingLayer: Codable, Equatable, Sendable {
    public let id: UUID
    public let name: String
    public let kind: FabricationLayerKind
    public let primitives: [ManufacturingPrimitive]
    public init(id: UUID, name: String, kind: FabricationLayerKind, primitives: [ManufacturingPrimitive]) {
        self.id = id; self.name = name; self.kind = kind; self.primitives = primitives
    }
}

public struct ManufacturingDrill: Codable, Equatable, Sendable {
    public let id: UUID
    public let position: PCBPoint
    /// Non-nil for a straight slot, using the same circular tool diameter.
    public let end: PCBPoint?
    public let diameter: Double
    public let isPlated: Bool
    public init(id: UUID, position: PCBPoint, end: PCBPoint? = nil, diameter: Double, isPlated: Bool) {
        self.id = id; self.position = position; self.end = end
        self.diameter = diameter; self.isPlated = isPlated
    }
}

enum ManufacturingReadSupport {
    static let namespace = UUID(uuidString: "A3624776-E4C0-431C-AC83-9E47F5F387A7")!
    static func root(_ data: Data, _ name: String) -> UUID {
        LibraryImportSupport.id(namespace, name + "/" + LibraryImportSupport.digest(data))
    }
    static func error(_ name: String, _ message: String) -> ElectronicsFailure {
        LibraryImportSupport.error("manufacturing_unsupported_or_invalid", name, message)
    }
    static func number(_ string: String, name: String) throws -> Double {
        guard !string.isEmpty, string.utf8.count <= 64, let n = Double(string), n.isFinite, abs(n) <= 1_000_000 else {
            throw error(name, "Numero non valido o fuori limite: \(string.prefix(64)).")
        }
        return n
    }
    static func point(_ point: PCBPoint, name: String) throws {
        guard point.x.isFinite, point.y.isFinite, abs(point.x) <= 1_000_000, abs(point.y) <= 1_000_000 else {
            throw error(name, "Coordinate non finite o oltre il limite di 1.000.000 mm.")
        }
    }
    static func positive(_ value: Double, name: String) throws {
        guard value.isFinite, value > 0, value <= 100_000 else {
            throw error(name, "Dimensione non positiva o fuori limite.")
        }
    }
    static func fields(_ text: String, allowed: String, name: String) throws -> [(Character, String)] {
        let chars = Array(text); var index = 0; var result: [(Character, String)] = []
        while index < chars.count {
            let key = chars[index]; index += 1
            guard allowed.contains(key) else { throw error(name, "Comando non supportato: \(text.prefix(100)).") }
            let start = index
            while index < chars.count && (chars[index].isNumber || "+-.".contains(chars[index])) { index += 1 }
            guard index > start else { throw error(name, "Campo \(key) senza valore.") }
            result.append((key, String(chars[start..<index])))
        }
        return result
    }
    static func rotate(_ p: PCBPoint, _ degrees: Double) -> PCBPoint {
        let a = degrees * .pi / 180, c = cos(a), s = sin(a)
        return .init(p.x * c - p.y * s, p.x * s + p.y * c)
    }
}
