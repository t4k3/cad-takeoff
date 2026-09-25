import Foundation

public enum Operations {
    /// Linear extrusion of a profile along +Z. Produces a closed, outward-oriented solid.
    public static func extrude(_ profile: Profile2D, height: Double, baseZ: Double = 0) -> Mesh {
        let p = profile.points
        let n = p.count
        guard n >= 3, height > 0 else { return Mesh() }
        var mesh = Mesh()
        mesh.vertices = p.map { Vec3($0.x, $0.y, baseZ) } + p.map { Vec3($0.x, $0.y, baseZ + height) }

        for (a, b, c) in profile.triangulate() {
            // bottom faces down (reverse winding), top faces up
            mesh.indices += [UInt32(a), UInt32(c), UInt32(b)]
            mesh.indices += [UInt32(a + n), UInt32(b + n), UInt32(c + n)]
        }
        for i in 0..<n {
            let j = (i + 1) % n
            let b0 = UInt32(i), b1 = UInt32(j), t0 = UInt32(i + n), t1 = UInt32(j + n)
            mesh.indices += [b0, b1, t1, b0, t1, t0]
        }
        return mesh
    }
}

public enum Primitives {
    public static func box(width: Double, depth: Double, height: Double) -> Mesh {
        Operations.extrude(.rectangle(width: width, height: depth), height: height)
    }

    public static func cylinder(radius: Double, height: Double, segments: Int = 64) -> Mesh {
        Operations.extrude(.circle(radius: radius, segments: segments), height: height)
    }
}
