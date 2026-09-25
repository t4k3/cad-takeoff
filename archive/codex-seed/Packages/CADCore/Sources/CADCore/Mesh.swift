import Foundation

public struct Vector3: Equatable, Sendable {
    public var x: Double
    public var y: Double
    public var z: Double
    public init(_ x: Double, _ y: Double, _ z: Double) { self.x = x; self.y = y; self.z = z }
    public static func - (a: Self, b: Self) -> Self { .init(a.x-b.x, a.y-b.y, a.z-b.z) }
    public func cross(_ b: Self) -> Self { .init(y*b.z-z*b.y, z*b.x-x*b.z, x*b.y-y*b.x) }
    public func dot(_ b: Self) -> Double { x*b.x + y*b.y + z*b.z }
    public var length: Double { sqrt(dot(self)) }
    public var normalized: Self { .init(x/length, y/length, z/length) }
}

public struct Triangle: Sendable {
    public let a: Int
    public let b: Int
    public let c: Int
    public init(_ a: Int, _ b: Int, _ c: Int) { self.a = a; self.b = b; self.c = c }
}

public struct Mesh: Sendable {
    public var vertices: [Vector3]
    public var triangles: [Triangle]
    public init(vertices: [Vector3], triangles: [Triangle]) {
        self.vertices = vertices; self.triangles = triangles
    }

    public var signedVolume: Double {
        triangles.reduce(0) { $0 + vertices[$1.a].dot(vertices[$1.b].cross(vertices[$1.c])) / 6 }
    }

    /// Topological checks for the generated convex solids; not a self-intersection detector.
    public func validateClosed() throws {
        guard !triangles.isEmpty, vertices.allSatisfy({ $0.x.isFinite && $0.y.isFinite && $0.z.isFinite }) else {
            throw CADError.invalid("Mesh vuota o coordinate non finite.")
        }
        struct Edge: Hashable { let low: Int; let high: Int }
        var edges: [Edge: (count: Int, orientation: Int)] = [:]
        for triangle in triangles {
            let indices = [triangle.a, triangle.b, triangle.c]
            guard indices.allSatisfy(vertices.indices.contains) else {
                throw CADError.invalid("Indice della mesh non valido.")
            }
            let normal = (vertices[triangle.b] - vertices[triangle.a]).cross(vertices[triangle.c] - vertices[triangle.a])
            guard normal.length > 1e-12 else { throw CADError.invalid("Triangolo degenere.") }
            for (a, b) in [(triangle.a, triangle.b), (triangle.b, triangle.c), (triangle.c, triangle.a)] {
                let key = Edge(low: min(a,b), high: max(a,b))
                let old = edges[key, default: (0, 0)]
                edges[key] = (old.count + 1, old.orientation + (a < b ? 1 : -1))
            }
        }
        guard edges.values.allSatisfy({ $0.count == 2 && $0.orientation == 0 }), signedVolume > 0 else {
            throw CADError.invalid("La mesh non è chiusa o ha orientamento incoerente.")
        }
    }
}

