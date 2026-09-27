import Foundation

public struct FaceID: RawRepresentable, Hashable, Codable, Sendable {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
}

public struct EdgeID: RawRepresentable, Hashable, Codable, Sendable {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
}

public struct VertexID: RawRepresentable, Hashable, Codable, Sendable {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
}

/// World coordinates in mm, unit directions, Z up. Cylinder describes the source
/// surface of a faceted approximation; it is not an exact analytic B-rep surface.
public enum SurfaceDescriptor: Equatable, Sendable {
    case plane(origin: Vec3, normal: Vec3)
    case cylinder(axisOrigin: Vec3, axisDirection: Vec3, radius: Double)
    /// Cone (countersinks): radius grows from the apex along `axisDirection` with the given half angle.
    case cone(apex: Vec3, axisDirection: Vec3, halfAngle: Double)
    /// Torus (rounds on circular edges): tube of `minorRadius` around a circle of `majorRadius`
    /// centred on `center`, perpendicular to `axisDirection`.
    case torus(center: Vec3, axisDirection: Vec3, majorRadius: Double, minorRadius: Double)
    /// Sphere (the ball where three rounds meet at a corner).
    case sphere(center: Vec3, radius: Double)
    /// Imported mesh region that is not a plane (no exact description).
    case freeform
}

extension SurfaceDescriptor {
    /// The same surface moved by a rigid motion (or mirror image) given on points and directions.
    public func mapped(point: (Vec3) -> Vec3, direction: (Vec3) -> Vec3) -> SurfaceDescriptor {
        switch self {
        case let .plane(o, n): .plane(origin: point(o), normal: direction(n))
        case let .cylinder(o, a, r): .cylinder(axisOrigin: point(o), axisDirection: direction(a), radius: r)
        case let .cone(apex, a, h): .cone(apex: point(apex), axisDirection: direction(a), halfAngle: h)
        case let .torus(c, a, R, r): .torus(center: point(c), axisDirection: direction(a), majorRadius: R, minorRadius: r)
        case let .sphere(c, r): .sphere(center: point(c), radius: r)
        case .freeform: .freeform
        }
    }
}

public enum KernelError: Error, LocalizedError, Equatable, Sendable {
    case invalidParameter(String)
    case invalidProfile(String)
    case invalidTopology(String)

    public var errorDescription: String? {
        switch self {
        case .invalidParameter(let detail): "Parametro geometrico non valido: \(detail)"
        case .invalidProfile(let detail): "Profilo non valido: \(detail)"
        case .invalidTopology(let detail): "Topologia non valida: \(detail)"
        }
    }
}

public struct BRepVertex: Equatable, Sendable {
    public let id: VertexID
    public let position: Vec3
}

/// Indices address arrays on the owning BRepBody. Every edge has two opposite uses.
public struct BRepHalfEdge: Equatable, Sendable {
    public let origin: Int
    public let destination: Int
    public let edge: Int
    public let face: Int
    public let next: Int
    public let twin: Int
}

public struct BRepEdge: Equatable, Sendable {
    public let id: EdgeID
    public let startVertex: Int
    public let endVertex: Int
    public let halfEdges: [Int]
    /// Nil for internal facet boundaries on the cylindrical side.
    public let selectionID: EdgeID?
}

public struct BRepFace: Equatable, Sendable {
    public let id: FaceID
    /// One ordered outer loop. Holes and multiple shells are not supported yet.
    public let halfEdges: [Int]
    public let origin: Vec3
    public let normal: Vec3
    public let selectionID: FaceID
    public let sourceSurface: SurfaceDescriptor
}

/// Immutable, single-shell planar B-rep built from supported feature parameters.
/// Triangles are a derived cache, not the source of face/edge identity.
public struct BRepBody: Sendable {
    public let id: UUID
    public let vertices: [BRepVertex]
    public let edges: [BRepEdge]
    public let halfEdges: [BRepHalfEdge]
    public let faces: [BRepFace]
    /// Radial sagitta for a faceted cylinder; zero for supported planar primitives.
    public let maximumSurfaceDeviation: Double
    let faceTriangles: [[UInt32]]

    public var mesh: Mesh {
        Mesh(vertices: vertices.map(\.position), indices: faceTriangles.flatMap { $0 })
    }

    /// Checks incidence, loop orientation, planarity, triangulation and positive volume.
    /// It is not an arbitrary B-rep self-intersection/Boolean certification.
    public func validate() throws {
        func require(_ test: Bool, _ detail: String) throws {
            if !test { throw KernelError.invalidTopology(detail) }
        }
        try require(vertices.count >= 4 && faces.count >= 4, "solido vuoto")
        try require(Set(vertices.map(\.id)).count == vertices.count, "ID vertice duplicato")
        try require(Set(edges.map(\.id)).count == edges.count, "ID spigolo duplicato")
        try require(Set(faces.map(\.id)).count == faces.count, "ID faccia duplicato")
        try require(vertices.allSatisfy { $0.position.isFinite }, "coordinate non finite")
        try require(vertices.count - edges.count + faces.count == 2, "guscio semplice non chiuso")
        try require(halfEdges.count == edges.count * 2 && faceTriangles.count == faces.count, "incidenze incomplete")
        var visited = Set<Int>()
        for (f, face) in faces.enumerated() {
            try require(face.halfEdges.count >= 3, "contorno troppo corto")
            try require(face.origin.isFinite && face.normal.isFinite && abs(face.normal.length - 1) < 1e-8, "piano non valido")
            for (k, h) in face.halfEdges.enumerated() {
                try require(halfEdges.indices.contains(h), "indice coedge fuori limite")
                let use = halfEdges[h]
                try require(vertices.indices.contains(use.origin) && vertices.indices.contains(use.destination), "indice vertice fuori limite")
                try require(edges.indices.contains(use.edge) && halfEdges.indices.contains(use.twin), "indice adiacenza fuori limite")
                try require(use.face == f && use.next == face.halfEdges[(k + 1) % face.halfEdges.count], "ciclo faccia incoerente")
                try require(halfEdges.indices.contains(use.next), "indice next fuori limite")
                try require(use.destination == halfEdges[use.next].origin, "contorno aperto")
                let twin = halfEdges[use.twin]
                try require(twin.twin == h && twin.edge == use.edge && twin.face != f && twin.origin == use.destination && twin.destination == use.origin, "coedge non opposti")
                try require(visited.insert(h).inserted, "coedge usato due volte")
                try require(abs((vertices[use.origin].position - face.origin).dot(face.normal)) < 1e-7, "faccia non piana")
            }
            let triangles = faceTriangles[f]
            try require(triangles.count == (face.halfEdges.count - 2) * 3, "triangolazione incompleta")
            let boundary = Set(face.halfEdges.map { halfEdges[$0].origin })
            try require(triangles.allSatisfy { vertices.indices.contains(Int($0)) && boundary.contains(Int($0)) }, "triangolo fuori contorno")
            for t in stride(from: 0, to: triangles.count, by: 3) {
                let a = vertices[Int(triangles[t])].position
                let b = vertices[Int(triangles[t + 1])].position
                let c = vertices[Int(triangles[t + 2])].position
                try require((b - a).cross(c - a).dot(face.normal) > 1e-10, "triangolo degenere o invertito")
            }
        }
        try require(visited.count == halfEdges.count, "coedge orfano")
        for (e, edge) in edges.enumerated() {
            try require(vertices.indices.contains(edge.startVertex) && vertices.indices.contains(edge.endVertex) && edge.startVertex != edge.endVertex, "spigolo non valido")
            try require(edge.halfEdges.count == 2 && Set(edge.halfEdges).count == 2, "spigolo non manifold")
            for h in edge.halfEdges {
                try require(halfEdges.indices.contains(h), "uso spigolo fuori limite")
                let use = halfEdges[h]
                try require(use.edge == e && Set([use.origin, use.destination]) == Set([edge.startVertex, edge.endVertex]), "incidenza spigolo incoerente")
            }
        }
        // Shift the volume calculation to avoid cancellation far from the world origin.
        let local = mesh.translated(by: -vertices[0].position)
        try require(local.volume.isFinite && local.volume > 1e-10, "volume non positivo")
    }
}

extension Vec3 {
    var isFinite: Bool { x.isFinite && y.isFinite && z.isFinite }
}
