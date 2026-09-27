import Foundation

/// Assembly check (Fusion's Interference): the bodies that overlap, and by how much. Bodies that
/// only touch (a part resting on another) do not count.
public enum Interference {
    public struct Clash: Sendable, Identifiable {
        public var id: String { "\(a)-\(b)" }
        public let a: UUID, b: UUID
        /// Overlapping volume in mm³ and the middle of the overlap.
        public let volume: Double
        public let centre: Vec3
        /// The overlap itself (to show it).
        public let mesh: Mesh
    }

    public static func check(_ bodies: [DesignEvaluator.Body], minimumVolume: Double = 1e-3) -> [Clash] {
        func box(_ m: Mesh) -> (Vec3, Vec3)? {
            guard let f = m.vertices.first else { return nil }
            var lo = f, hi = f
            for p in m.vertices { lo = Vec3(min(lo.x, p.x), min(lo.y, p.y), min(lo.z, p.z)); hi = Vec3(max(hi.x, p.x), max(hi.y, p.y), max(hi.z, p.z)) }
            return (lo, hi)
        }
        let boxes = bodies.map { box($0.mesh) }
        var out: [Clash] = []
        for i in bodies.indices {
            for j in bodies.indices where j > i {
                guard let (a0, a1) = boxes[i], let (b0, b1) = boxes[j] else { continue }
                // Boxes that only touch cannot overlap in volume.
                let eps = 1e-6
                guard a0.x < b1.x - eps, b0.x < a1.x - eps, a0.y < b1.y - eps, b0.y < a1.y - eps, a0.z < b1.z - eps, b0.z < a1.z - eps else { continue }
                let common = CSGSolid(bodies[i].snapshot).intersecting(CSGSolid(bodies[j].snapshot))
                guard !common.isEmpty else { continue }
                let mesh = common.triangulated().mesh
                let v = mesh.volume
                guard v > minimumVolume, let (c0, c1) = box(mesh) else { continue }
                out.append(Clash(a: bodies[i].id, b: bodies[j].id, volume: v, centre: (c0 + c1) * 0.5, mesh: mesh))
            }
        }
        return out.sorted { $0.volume > $1.volume }
    }
}
