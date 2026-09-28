import ElectronicsCore
import Foundation
import simd

/// The assembled board as flat-shaded triangle batches, in the engine's frame (mm, Z up, board
/// bottom z = 0): the drilled substrate split into its top face, bottom face and edges (the top
/// and bottom carry the finished-board picture as UVs over the board outline), and each
/// component's parts by material. No RealityKit here: the 3D view turns batches into entities,
/// the tests read them.
struct AssemblyMesh {
    enum Look: Hashable {
        case boardTop, boardBottom, boardEdge
        case part(ManufacturingAssemblyMaterial)
        /// A component without a model: a small marker at its CPL centre, never a body.
        case missing
    }

    struct Batch {
        var look: Look
        var component: UUID?
        var positions: [SIMD3<Float>] = []
        var normals: [SIMD3<Float>] = []
        var uvs: [SIMD2<Float>] = []
        var triangleCount: Int { positions.count / 3 }
    }

    var batches: [Batch]
    var minimum: SIMD3<Float>
    var maximum: SIMD3<Float>

    init(_ snapshot: ManufacturingAssemblySnapshot, outline bounds: ManufacturingBounds) {
        let lo = SIMD2(Float(bounds.minimum.x), Float(bounds.minimum.y))
        let size = SIMD2(Float(max(bounds.width, 1e-3)), Float(max(bounds.height, 1e-3)))
        var top = Batch(look: .boardTop), bottom = Batch(look: .boardBottom), edge = Batch(look: .boardEdge)
        for part in snapshot.boardParts {
            Self.triangles(part) { a, b, c, n in
                // RealityKit samples v = 0 at the picture's BOTTOM row, which is the board's smallest
                // y (the picture's top row is the largest y): v grows with y (T111 QA, it was flipped).
                func uv(_ p: SIMD3<Float>) -> SIMD2<Float> { SIMD2((p.x - lo.x) / size.x, (p.y - lo.y) / size.y) }
                if n.z > 0.9 { top.add(a, b, c, n, uv(a), uv(b), uv(c)) }
                else if n.z < -0.9 { bottom.add(a, b, c, n, uv(a), uv(b), uv(c)) }
                else { edge.add(a, b, c, n) }
            }
        }
        var batches = [top, bottom, edge].filter { !$0.positions.isEmpty }
        let t = Float(snapshot.boardThickness)
        for instance in snapshot.instances { batches += Self.batches(instance, thickness: t) }
        self.batches = batches
        var mn = SIMD3<Float>(repeating: .infinity), mx = SIMD3<Float>(repeating: -.infinity)
        for b in batches { for p in b.positions { mn = simd_min(mn, p); mx = simd_max(mx, p) } }
        if mn.x > mx.x { mn = SIMD3(lo, 0); mx = SIMD3(lo + size, t) }
        minimum = mn; maximum = mx
    }

    /// The nearest component hit by a ray (its parts, or its marker), for clicks in 3D. The
    /// drilled substrate hides what is behind it (a ray through a real hole passes).
    func pick(origin: SIMD3<Float>, direction: SIMD3<Float>, visible: (UUID) -> Bool) -> UUID? {
        var best: (id: UUID?, distance: Float)?
        for b in batches {
            if let id = b.component, !visible(id) { continue }
            var i = 0
            while i + 2 < b.positions.count {
                if let d = Self.intersect(origin, direction, b.positions[i], b.positions[i + 1], b.positions[i + 2]),
                   d < (best?.distance ?? .infinity) { best = (b.component, d) }
                i += 3
            }
        }
        return best?.id ?? nil
    }

    /// The component's batches replaced (the one being aligned, as previewed): picking follows
    /// what is shown.
    mutating func replace(_ id: UUID, with new: [Batch]) {
        batches.removeAll { $0.component == id }
        batches += new
    }

    // MARK: Building

    /// One component: its parts by material, or — without a model — a small marker at its CPL
    /// centre on its side of the board (nothing when it has no position).
    static func batches(_ instance: ManufacturingAssemblyInstance, thickness t: Float) -> [Batch] {
        if instance.parts.isEmpty {
            guard let p = instance.position else { return [] }
            var marker = Batch(look: .missing, component: instance.id)
            let z: Float = instance.side == .bottom ? -0.8 : t
            box(center: SIMD3(Float(p.x), Float(p.y), z + 0.4), half: 0.4, into: &marker)
            return [marker]
        }
        var byMaterial: [ManufacturingAssemblyMaterial: Batch] = [:]
        for part in instance.parts {
            triangles(part) { a, b, c, n in
                byMaterial[part.material, default: Batch(look: .part(part.material), component: instance.id)].add(a, b, c, n)
            }
        }
        return byMaterial.keys.sorted { $0.rawValue < $1.rawValue }.compactMap { byMaterial[$0] }
    }

    private static func triangles(_ part: ManufacturingAssemblyPart,
                                  _ body: (SIMD3<Float>, SIMD3<Float>, SIMD3<Float>, SIMD3<Float>) -> Void) {
        func f(_ p: PCBPoint3) -> SIMD3<Float> { SIMD3(Float(p.x), Float(p.y), Float(p.z)) }
        var i = 0
        while i + 2 < part.indices.count {
            let ia = part.indices[i], ib = part.indices[i + 1], ic = part.indices[i + 2]
            i += 3
            guard part.vertices.indices.contains(ia), part.vertices.indices.contains(ib), part.vertices.indices.contains(ic) else { continue }
            let a = f(part.vertices[ia]), b = f(part.vertices[ib]), c = f(part.vertices[ic])
            let cross = simd_cross(b - a, c - a)
            let length = simd_length(cross)
            guard length > 1e-12 else { continue }
            body(a, b, c, cross / length)
        }
    }

    private static func box(center: SIMD3<Float>, half: Float, into batch: inout Batch) {
        let s: [SIMD3<Float>] = [[-1, -1, -1], [1, -1, -1], [1, 1, -1], [-1, 1, -1], [-1, -1, 1], [1, -1, 1], [1, 1, 1], [-1, 1, 1]]
        let v = s.map { center + $0 * half }
        let faces = [[0, 3, 2, 1], [4, 5, 6, 7], [0, 1, 5, 4], [1, 2, 6, 5], [2, 3, 7, 6], [3, 0, 4, 7]]
        for q in faces {
            let n = simd_normalize(simd_cross(v[q[1]] - v[q[0]], v[q[2]] - v[q[0]]))
            batch.add(v[q[0]], v[q[1]], v[q[2]], n)
            batch.add(v[q[0]], v[q[2]], v[q[3]], n)
        }
    }

    /// Möller–Trumbore, double-sided; the distance along the ray.
    private static func intersect(_ o: SIMD3<Float>, _ d: SIMD3<Float>, _ a: SIMD3<Float>, _ b: SIMD3<Float>, _ c: SIMD3<Float>) -> Float? {
        let e1 = b - a, e2 = c - a
        let p = simd_cross(d, e2), det = simd_dot(e1, p)
        guard abs(det) > 1e-9 else { return nil }
        let inv = 1 / det, s = o - a
        let u = simd_dot(s, p) * inv
        guard u >= 0, u <= 1 else { return nil }
        let q = simd_cross(s, e1), v = simd_dot(d, q) * inv
        guard v >= 0, u + v <= 1 else { return nil }
        let t = simd_dot(e2, q) * inv
        return t > 1e-4 ? t : nil
    }
}

extension AssemblyMesh.Batch {
    mutating func add(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ c: SIMD3<Float>, _ n: SIMD3<Float>,
                      _ ua: SIMD2<Float>? = nil, _ ub: SIMD2<Float>? = nil, _ uc: SIMD2<Float>? = nil) {
        positions += [a, b, c]; normals += [n, n, n]
        if let ua, let ub, let uc { uvs += [ua, ub, uc] }
    }
}
