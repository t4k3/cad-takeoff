import CADCore
import simd

/// PROVISIONAL (T72): faces and edges derived from today's triangle meshes, used only to
/// highlight and measure in the viewport. Indices are not persistent references and are
/// never sent to the Model. Replaced by the kernel snapshot (T30: FaceID/EdgeID) when available.
struct DerivedTopology {
    struct Face {
        var triangles: [Int] = []
        var area = 0.0
        /// Plane normal when every triangle shares it (planar face), nil for curved regions.
        var planeNormal: Vec3?
        var isPlanar: Bool { planeNormal != nil }
    }

    struct Edge {
        var segments: [(Vec3, Vec3)] = []
        var faces: (Int, Int?)
        var length: Double { segments.reduce(0) { $0 + ($1.1 - $1.0).length } }
    }

    private(set) var faces: [Face] = []
    private(set) var edges: [Edge] = []
    private(set) var triangleFace: [Int] = []

    /// Triangles whose normals differ by less than this are merged into one smooth face
    /// (a 64-segment cylinder wall becomes a single face, like in a real CAD).
    static let smoothAngle = 12.0 * .pi / 180

    init(_ mesh: Mesh) {
        let n = mesh.triangleCount
        guard n > 0 else { return }
        // Weld vertices by position so adjacency works across un-shared vertices.
        var weld: [Vec3: Int] = [:]
        let ids = mesh.vertices.map { v -> Int in
            if let i = weld[v] { return i }
            weld[v] = weld.count
            return weld.count - 1
        }
        let position = Dictionary(uniqueKeysWithValues: weld.map { ($0.value, $0.key) })
        let normals = (0..<n).map { mesh.normal(ofTriangle: $0) }
        struct Key: Hashable { let a: Int, b: Int }
        var edgeTris: [Key: [Int]] = [:]
        for t in 0..<n {
            for k in 0..<3 {
                let a = ids[Int(mesh.indices[t * 3 + k])], b = ids[Int(mesh.indices[t * 3 + (k + 1) % 3])]
                edgeTris[Key(a: min(a, b), b: max(a, b)), default: []].append(t)
            }
        }
        var neighbours = [[Int]](repeating: [], count: n)
        for tris in edgeTris.values where tris.count == 2 {
            neighbours[tris[0]].append(tris[1]); neighbours[tris[1]].append(tris[0])
        }

        // Flood fill: planar faces first (exact normal match), then smooth regions.
        triangleFace = [Int](repeating: -1, count: n)
        let cosSmooth = cos(Self.smoothAngle)
        for seed in 0..<n where triangleFace[seed] < 0 {
            let f = faces.count
            var face = Face()
            var stack = [seed]
            triangleFace[seed] = f
            var planar = true
            while let t = stack.popLast() {
                face.triangles.append(t)
                let (a, b, c) = mesh.triangle(t)
                face.area += (b - a).cross(c - a).length / 2
                if normals[t].dot(normals[seed]) < 0.99999 { planar = false }
                for u in neighbours[t] where triangleFace[u] < 0 && normals[u].dot(normals[t]) > cosSmooth {
                    triangleFace[u] = f
                    stack.append(u)
                }
            }
            face.planeNormal = planar ? normals[seed] : nil
            faces.append(face)
        }

        // Sharp edges: mesh edges between different faces, or open boundaries; grouped by face pair.
        var grouped: [Key: Edge] = [:]
        for (key, tris) in edgeTris {
            let f0 = triangleFace[tris[0]]
            let f1: Int? = tris.count > 1 ? triangleFace[tris[1]] : nil
            guard f1 != f0 else { continue }
            let pair = Key(a: min(f0, f1 ?? -1), b: max(f0, f1 ?? -1))
            let seg = (position[key.a]!, position[key.b]!)
            grouped[pair, default: Edge(faces: (f0, f1))].segments.append(seg)
        }
        edges = Self.splitDisconnected(Array(grouped.values))
    }

    /// Two faces can meet along separate chains (e.g. a slot): split them into distinct edges.
    private static func splitDisconnected(_ edges: [Edge]) -> [Edge] {
        edges.flatMap { e -> [Edge] in
            var remaining = e.segments
            var chains: [Edge] = []
            while let first = remaining.popLast() {
                var chain = [first]
                var ends = [first.0, first.1]
                var grew = true
                while grew {
                    grew = false
                    if let i = remaining.firstIndex(where: { ends.contains($0.0) || ends.contains($0.1) }) {
                        let s = remaining.remove(at: i)
                        chain.append(s); ends += [s.0, s.1]; grew = true
                    }
                }
                chains.append(Edge(segments: chain, faces: e.faces))
            }
            return chains
        }
    }
}
