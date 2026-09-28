import Foundation

/// Closed substrate mesh from profile centre lines and actual drill/slot boundaries.
/// Vertical decomposition shares every boundary split before adding walls, including
/// splits caused by another hole. This prevents the T-junctions produced by independent
/// top-face and wall triangulation. No bounding-box substitute is returned on failure.
enum ManufacturingAssemblyBoard {
    private static let grid = 1e-8
    private static let epsilon = 1e-7

    static func parts(package: ManufacturingPackage, thickness: Double) throws -> [ManufacturingAssemblyPart] {
        guard thickness.isFinite, thickness > 0, thickness <= 100 else {
            throw failure(package, "Spessore non valido per il substrato 3D.")
        }
        guard let profile = package.layers.first(where: { $0.kind == .profile }) else {
            throw failure(package, "Contorno Gerber assente: impossibile costruire il substrato 3D.")
        }
        var loops = try profileLoops(profile, package: package)
        try validate(loops, package: package)
        let profileCount = loops.count
        guard package.drills.count <= 2_000 else { throw failure(package, "Oltre 2.000 forature: substrato 3D non generato.") }
        for drill in package.drills {
            try Task.checkCancellation()
            let hole = try drillLoop(drill, package: package)
            // With disjoint boundaries, one point determines the containment of the loop.
            let depth = loops.prefix(profileCount).filter { contains(hole.points[0], in: $0.points) }.count
            guard depth % 2 == 1 else {
                throw failure(package, "Una foratura è fuori dal materiale del contorno: verificare il Gerber e i fori.", [drill.id])
            }
            for other in loops.dropFirst(profileCount) {
                guard !contains(hole.points[0], in: other.points), !contains(other.points[0], in: hole.points) else {
                    throw failure(package, "Forature sovrapposte o contenute l’una nell’altra: unione 3D non supportata.", [drill.id])
                }
            }
            loops.append(hole)
        }
        guard loops.reduce(0, { $0 + $1.points.count }) <= 24_000 else {
            throw failure(package, "Contorno e forature troppo complessi per il substrato 3D.")
        }
        try validate(loops, package: package)
        let planar = try triangulate(loops, package: package)
        let n = planar.points.count
        var vertices = planar.points.map { PCBPoint3($0.x, $0.y, 0) }
        vertices += planar.points.map { PCBPoint3($0.x, $0.y, thickness) }
        var triangles: [Int] = []
        triangles.reserveCapacity(planar.triangles.count * 2 + planar.boundary.count * 6)
        for start in stride(from: 0, to: planar.triangles.count, by: 3) {
            let a = planar.triangles[start], b = planar.triangles[start + 1], c = planar.triangles[start + 2]
            triangles += [a, c, b, a + n, b + n, c + n]
        }
        for edge in planar.boundary {
            triangles += [edge.a, edge.b, edge.b + n, edge.a, edge.b + n, edge.a + n]
        }
        return [.init(id: "substrate", material: .substrate, vertices: vertices, indices: triangles)]
    }

    private struct Key: Hashable, Comparable {
        let x: Int64
        let y: Int64
        init(_ p: PCBPoint) { x = Int64((p.x / grid).rounded()); y = Int64((p.y / grid).rounded()) }
        var point: PCBPoint { .init(Double(x) * grid, Double(y) * grid) }
        static func < (a: Self, b: Self) -> Bool { a.x == b.x ? a.y < b.y : a.x < b.x }
    }
    private struct Segment {
        let a: PCBPoint
        let b: PCBPoint
        var minX: Double { min(a.x, b.x) }
        var maxX: Double { max(a.x, b.x) }
        func y(at x: Double) -> Double { a.y + (b.y - a.y) * ((x - a.x) / (b.x - a.x)) }
    }
    private struct Loop {
        let points: [PCBPoint]
        let minX: Double
        let maxX: Double
        let minY: Double
        let maxY: Double
        init(_ points: [PCBPoint]) {
            self.points = points
            minX = points.map(\.x).min()!; maxX = points.map(\.x).max()!
            minY = points.map(\.y).min()!; maxY = points.map(\.y).max()!
        }
        var segments: [Segment] { points.indices.map { .init(a: points[$0], b: points[($0 + 1) % points.count]) } }
        func overlaps(_ other: Self) -> Bool {
            maxX + epsilon >= other.minX && other.maxX + epsilon >= minX && maxY + epsilon >= other.minY && other.maxY + epsilon >= minY
        }
    }

    private static func profileLoops(_ profile: ManufacturingLayer, package: ManufacturingPackage) throws -> [Loop] {
        var edges: [(Key, Key)] = []
        for primitive in profile.primitives {
            try Task.checkCancellation()
            guard primitive.isDark, primitive.shapes.count == 1, let shape = primitive.shapes.first, shape.isDark,
                  shape.radius.isFinite, shape.radius >= 0 else {
                throw failure(package, "Il contorno usa sottrazioni o aperture composte non supportate in 3D.", [primitive.id])
            }
            for contour in shape.contours {
                guard contour.count >= 2, contour.allSatisfy(ElectronicsGeometry.valid) else {
                    throw failure(package, "Contorno 3D senza una linea di taglio ricostruibile.", [primitive.id])
                }
                var keys = contour.map(Key.init)
                if shape.radius == 0, keys.last != keys.first { keys.append(keys[0]) }
                for (a, b) in zip(keys, keys.dropFirst()) {
                    guard a != b else { throw failure(package, "Contorno 3D con segmenti nulli o sotto risoluzione.", [primitive.id]) }
                    edges.append((a, b))
                }
            }
        }
        guard !edges.isEmpty, edges.count <= 8_192 else { throw failure(package, "Contorno vuoto o oltre 8.192 segmenti.") }
        var adjacency: [Key: [Int]] = [:]
        for (i, edge) in edges.enumerated() { adjacency[edge.0, default: []].append(i); adjacency[edge.1, default: []].append(i) }
        guard adjacency.values.allSatisfy({ $0.count == 2 }) else {
            throw failure(package, "Il contorno è aperto, ramificato o duplicato: correggere le linee di taglio prima del 3D.")
        }
        var used = Set<Int>(), result: [Loop] = []
        for first in edges.indices where !used.contains(first) {
            let start = min(edges[first].0, edges[first].1)
            var current = start, points: [PCBPoint] = []
            repeat {
                points.append(current.point)
                guard let nextEdge = adjacency[current]?.first(where: { !used.contains($0) }) else {
                    throw failure(package, "Le linee del contorno non formano anelli chiusi indipendenti.")
                }
                used.insert(nextEdge)
                current = edges[nextEdge].0 == current ? edges[nextEdge].1 : edges[nextEdge].0
            } while current != start
            guard points.count >= 3 else { throw failure(package, "Anello del contorno degenere.") }
            result.append(Loop(points))
        }
        return result
    }

    private static func drillLoop(_ drill: ManufacturingDrill, package: ManufacturingPackage) throws -> Loop {
        guard ElectronicsGeometry.valid(drill.position), drill.end.map(ElectronicsGeometry.valid) ?? true,
              drill.diameter.isFinite, drill.diameter > 0, drill.diameter <= 1_000 else {
            throw failure(package, "Foratura non valida per il substrato 3D.", [drill.id])
        }
        let radius = drill.diameter / 2
        // Inscribed polygons, <= 0.01 mm maximum radial sag, at least 32 facets.
        let needed = Int(ceil(Double.pi / acos(max(-1, min(1, 1 - 0.01 / radius)))))
        let segments = max(32, ((needed + 3) / 4) * 4)
        guard segments <= 512 else { throw failure(package, "Foro troppo grande per la precisione 3D disponibile.", [drill.id]) }
        var points: [PCBPoint] = []
        if let end = drill.end, hypot(end.x - drill.position.x, end.y - drill.position.y) > epsilon {
            let angle = atan2(end.y - drill.position.y, end.x - drill.position.x)
            for (center, start) in [(end, angle - .pi / 2), (drill.position, angle + .pi / 2)] {
                for i in 0...segments / 2 {
                    let a = start + Double(i) * 2 * .pi / Double(segments)
                    points.append(.init(center.x + radius * cos(a), center.y + radius * sin(a)))
                }
            }
        } else {
            for i in 0..<segments {
                let a = Double(i) * 2 * .pi / Double(segments)
                points.append(.init(drill.position.x + radius * cos(a), drill.position.y + radius * sin(a)))
            }
        }
        return Loop(points.map { Key($0).point })
    }

    private static func validate(_ loops: [Loop], package: ManufacturingPackage) throws {
        var comparisons = 0
        for (i, loop) in loops.enumerated() {
            try Task.checkCancellation()
            guard abs(area(loop.points)) > epsilon * epsilon else { throw failure(package, "Anello di taglio con area nulla.") }
            let edges = loop.segments
            for a in edges.indices {
                if a % 64 == 0 { try Task.checkCancellation() }
                comparisons += edges.count - a - 1
                guard comparisons <= 50_000_000 else { throw failure(package, "Verifica dei contorni oltre il limite di complessità 3D.") }
                guard hypot(edges[a].b.x - edges[a].a.x, edges[a].b.y - edges[a].a.y) > grid / 2 else {
                    throw failure(package, "Contorno o foro sotto la risoluzione geometrica 3D.")
                }
                for b in (a + 1)..<edges.count where b != a + 1 && !(a == 0 && b == edges.count - 1) {
                    if intersects(edges[a], edges[b]) { throw failure(package, "Contorno auto-intersecante o a contatto con sé stesso.") }
                }
            }
            for other in loops.dropFirst(i + 1) where loop.overlaps(other) {
                let otherEdges = other.segments
                for (index, a) in edges.enumerated() {
                    if index % 64 == 0 { try Task.checkCancellation() }
                    comparisons += otherEdges.count
                    guard comparisons <= 50_000_000 else { throw failure(package, "Verifica dei contorni oltre il limite di complessità 3D.") }
                    for b in otherEdges where intersects(a, b) {
                        throw failure(package, "Contorni o forature a contatto/sovrapposti: unione 3D non supportata.")
                    }
                }
            }
        }
    }
    private static func cross(_ a: PCBPoint, _ b: PCBPoint, _ c: PCBPoint) -> Double {
        (b.x - a.x) * (c.y - a.y) - (b.y - a.y) * (c.x - a.x)
    }
    private static func area(_ points: [PCBPoint]) -> Double {
        let origin = points[0]
        return (1..<(points.count - 1)).reduce(0) { $0 + cross(origin, points[$1], points[$1 + 1]) } / 2
    }
    private static func intersects(_ a: Segment, _ b: Segment) -> Bool {
        guard a.maxX + epsilon >= b.minX, b.maxX + epsilon >= a.minX,
              max(a.a.y, a.b.y) + epsilon >= min(b.a.y, b.b.y),
              max(b.a.y, b.b.y) + epsilon >= min(a.a.y, a.b.y) else { return false }
        let c1 = cross(a.a, a.b, b.a), c2 = cross(a.a, a.b, b.b)
        let c3 = cross(b.a, b.b, a.a), c4 = cross(b.a, b.b, a.b)
        let toleranceA = epsilon * max(1, hypot(a.b.x - a.a.x, a.b.y - a.a.y))
        let toleranceB = epsilon * max(1, hypot(b.b.x - b.a.x, b.b.y - b.a.y))
        return min(c1, c2) <= toleranceA && max(c1, c2) >= -toleranceA &&
               min(c3, c4) <= toleranceB && max(c3, c4) >= -toleranceB
    }
    private static func contains(_ p: PCBPoint, in loop: [PCBPoint]) -> Bool {
        var inside = false
        for i in loop.indices {
            let a = loop[i], b = loop[(i + 1) % loop.count]
            if (a.y > p.y) != (b.y > p.y), p.x < a.x + (b.x - a.x) * (p.y - a.y) / (b.y - a.y) { inside.toggle() }
        }
        return inside
    }

    private struct EdgeKey: Hashable {
        let low: Int
        let high: Int
        init(_ a: Int, _ b: Int) { low = min(a, b); high = max(a, b) }
    }
    private struct Edge { let a: Int; let b: Int }
    private struct Planar { let points: [PCBPoint]; let triangles: [Int]; let boundary: [Edge] }

    private static func triangulate(_ loops: [Loop], package: ManufacturingPackage) throws -> Planar {
        let segments = loops.flatMap(\.segments)
        let xs = Set(loops.flatMap(\.points).map { Key($0).x }).sorted()
        guard xs.count >= 2, xs.count <= 6_000 else { throw failure(package, "Suddivisione del substrato troppo complessa.") }
        var ys: [[Int64]] = []
        for keyX in xs {
            try Task.checkCancellation()
            let x = Double(keyX) * grid
            var intersections = Set<Int64>()
            for edge in segments where x >= edge.minX - grid / 2 && x <= edge.maxX + grid / 2 {
                if abs(edge.b.x - edge.a.x) < grid / 2 {
                    intersections.insert(Key(edge.a).y); intersections.insert(Key(edge.b).y)
                } else { intersections.insert(Key(.init(x, edge.y(at: x))).y) }
            }
            ys.append(intersections.sorted())
        }
        var points: [PCBPoint] = [], indices: [Int] = [], vertexMap: [Key: Int] = [:]
        var meshEdges: [EdgeKey: (edge: Edge, count: Int)] = [:]
        func vertex(_ key: Key) -> Int {
            if let i = vertexMap[key] { return i }
            let i = points.count; points.append(key.point); vertexMap[key] = i; return i
        }
        func triangle(_ a: Int, _ b: Int, _ c: Int) throws {
            guard cross(points[a], points[b], points[c]) > 0 else { throw failure(package, "Triangolo del substrato degenere: contorni troppo vicini.") }
            indices += [a, b, c]
            for (u, v) in [(a,b), (b,c), (c,a)] {
                let key = EdgeKey(u, v)
                if let old = meshEdges[key] {
                    guard old.count == 1, old.edge.a == v, old.edge.b == u else {
                        throw failure(package, "Triangolazione del substrato non manifold.")
                    }
                    meshEdges[key] = (old.edge, 2)
                } else { meshEdges[key] = (.init(a: u, b: v), 1) }
            }
        }
        for i in 0..<(xs.count - 1) {
            try Task.checkCancellation()
            let left = Double(xs[i]) * grid, right = Double(xs[i + 1]) * grid, middle = (left + right) / 2
            let crossings = segments.filter { $0.minX < middle && middle < $0.maxX }.sorted { $0.y(at: middle) < $1.y(at: middle) }
            guard crossings.count % 2 == 0 else { throw failure(package, "Il contorno non delimita regioni chiuse del substrato.") }
            for n in stride(from: 0, to: crossings.count, by: 2) {
                let low = crossings[n], high = crossings[n + 1]
                let a = Key(.init(left, low.y(at: left))), b = Key(.init(right, low.y(at: right)))
                let c = Key(.init(right, high.y(at: right))), d = Key(.init(left, high.y(at: left)))
                var perimeter: [Key] = []
                func append(_ key: Key) { if perimeter.last != key { perimeter.append(key) } }
                append(a); append(b)
                for y in ys[i + 1] where y > b.y && y < c.y { append(Key(.init(right, Double(y) * grid))) }
                append(c); append(d)
                for y in ys[i].reversed() where y > a.y && y < d.y { append(Key(.init(left, Double(y) * grid))) }
                if perimeter.last == perimeter.first { perimeter.removeLast() }
                guard perimeter.count >= 3 else { throw failure(package, "Regione del substrato sotto risoluzione.") }
                let centre = points.count
                points.append(.init(middle, (a.point.y + b.point.y + c.point.y + d.point.y) / 4))
                let ids = perimeter.map(vertex)
                for j in ids.indices { try triangle(centre, ids[j], ids[(j + 1) % ids.count]) }
                guard points.count <= 500_000, indices.count <= 3_000_000 else { throw failure(package, "Mesh del substrato oltre il limite di complessità.") }
            }
        }
        guard !indices.isEmpty else { throw failure(package, "Nessun materiale nel contorno del substrato.") }
        var boundary: [Edge] = []
        for record in meshEdges.values where record.count == 1 { boundary.append(record.edge) }
        boundary.sort { first, second in
            if first.a == second.a { return first.b < second.b }
            return first.a < second.a
        }
        var incoming: [Int: Int] = [:], outgoing: [Int: Int] = [:]
        for edge in boundary { outgoing[edge.a, default: 0] += 1; incoming[edge.b, default: 0] += 1 }
        guard incoming == outgoing, incoming.values.allSatisfy({ $0 == 1 }) else {
            throw failure(package, "Il bordo della triangolazione non forma anelli manifold chiusi.")
        }
        return .init(points: points, triangles: indices, boundary: boundary)
    }

    private static func failure(_ package: ManufacturingPackage, _ message: String, _ subjects: [UUID] = []) -> ElectronicsFailure {
        var issue = ElectronicsIssue("manufacturing_board_mesh", "Substrato 3D", message)
        issue.subjectIDs = subjects.isEmpty ? [package.id] : subjects
        return .init([issue])
    }
}
