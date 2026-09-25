import Foundation

/// Seed implementation for one convex profile. This is not a B-rep CAD kernel.
public enum PrimitiveMesher {
    public static func build(_ model: CADModel) throws -> Mesh {
        try model.validate()
        let ring: [Vector3]
        switch model.profile {
        case .rectangle:
            let x = model.width / 2, y = model.depth / 2
            ring = [.init(-x,-y,0), .init(x,-y,0), .init(x,y,0), .init(-x,y,0)]
        case .circle:
            ring = (0..<model.segments).map { index in
                let angle = Double(index) * 2 * .pi / Double(model.segments)
                return .init(cos(angle) * model.width / 2, sin(angle) * model.width / 2, 0)
            }
        }
        let n = ring.count
        var vertices = ring + ring.map { Vector3($0.x, $0.y, model.height) }
        vertices.append(.init(0,0,0))
        vertices.append(.init(0,0,model.height))
        var triangles: [Triangle] = []
        for i in 0..<n {
            let j = (i + 1) % n
            triangles.append(contentsOf: [
                .init(2*n, j, i), .init(2*n+1, i+n, j+n),
                .init(i, j, j+n), .init(i, j+n, i+n)
            ])
        }
        let mesh = Mesh(vertices: vertices, triangles: triangles)
        try mesh.validateClosed()
        return mesh
    }
}

