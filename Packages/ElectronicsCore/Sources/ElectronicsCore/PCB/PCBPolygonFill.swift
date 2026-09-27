import Foundation

/// Native vertical decomposition of (subject ∩ board) minus a union of polygons.
/// Events include every vertex and segment intersection: edge ordering cannot change
/// inside a slab. No raster grid, centre-sampling of cells, or convex-hull filling of holes.
enum PCBPolygonFill {
    struct Edge {
        let a: PCBPoint, b: PCBPoint
        let polygon: Int
        func y(_ x: Double) -> Double { a.y + (b.y-a.y) * ((x-a.x)/(b.x-a.x)) }
    }
    static func cells(subject: [PCBPoint], board: [PCBPoint], obstacles: [[PCBPoint]]) throws -> [[PCBPoint]] {
        try cells(groups:[[subject],[board]],obstacles:obstacles)
    }
    /// Intersection of groups; each group is a union. Used for dilation of a decomposed
    /// region without treating its internal cell boundaries as physical boundaries.
    static func cells(groups: [[[PCBPoint]]], obstacles: [[PCBPoint]]) throws -> [[PCBPoint]] {
        guard !groups.isEmpty, groups.allSatisfy({ !$0.isEmpty }) else { return [] }
        let bounds = PCBBox(groups[0].flatMap { $0 })
        let groupForPolygon = groups.enumerated().flatMap { n,group in group.map { _ in n } }
        let positiveCount = groupForPolygon.count
        let polygons = groups.flatMap { $0 } + obstacles.filter { PCBBox($0).intersects(bounds) }
        let edges = polygons.enumerated().flatMap { p,points in PCBGeometry.edges(points).map { Edge(a:$0.0,b:$0.1,polygon:p) } }
        guard edges.count <= 32_000 else { throw tooComplex() }
        let index = try PCBIndex(boxes:edges.map { PCBBox([$0.a,$0.b]) })
        var events = edges.flatMap { [$0.a.x,$0.b.x] }.filter { $0 >= bounds.minX && $0 <= bounds.maxX }
        var work = 0
        for i in edges.indices {
            try Task.checkCancellation()
            let a = edges[i], rx = a.b.x-a.a.x, ry = a.b.y-a.a.y
            for j in index.query(PCBBox([a.a,a.b])) where j > i {
                work += 1; if work > 4_000_000 { throw tooComplex() }
                let b = edges[j], sx = b.b.x-b.a.x, sy = b.b.y-b.a.y
                let den = rx*sy-ry*sx
                if den == 0 { continue } // parallel/collinear: endpoints already partition the overlap
                let qx = b.a.x-a.a.x, qy = b.a.y-a.a.y
                let t = (qx*sy-qy*sx)/den, u = (qx*ry-qy*rx)/den
                if t > 0 && t < 1 && u > 0 && u < 1 {
                    let x = a.a.x+t*rx
                    if x >= bounds.minX && x <= bounds.maxX { events.append(x) }
                }
            }
        }
        events.sort()
        // Never coalesce distinct x events: even a narrow slab can separate two nets.
        var xs: [Double] = []
        for x in events where xs.last != x { xs.append(x) }
        let starting = edges.indices.sorted { min(edges[$0].a.x,edges[$0].b.x) < min(edges[$1].a.x,edges[$1].b.x) }
        var active = Set<Int>(), next = 0, sweepWork = 0
        var result: [[PCBPoint]] = []
        for (left,right) in zip(xs,xs.dropFirst()) {
            try Task.checkCancellation()
            let middle = left+(right-left)/2
            if middle == left || middle == right { continue }
            while next < starting.count, min(edges[starting[next]].a.x,edges[starting[next]].b.x) < middle {
                active.insert(starting[next]); next += 1
            }
            active = active.filter { max(edges[$0].a.x,edges[$0].b.x) > middle }
            sweepWork += active.count
            guard sweepWork <= 24_000_000 else { throw tooComplex() }
            let crossings = active.sorted {
                let a = edges[$0].y(middle), b = edges[$1].y(middle)
                return a == b ? $0 < $1 : a < b
            }
            var inside = Array(repeating:false,count:polygons.count)
            var counts = Array(repeating:0,count:groups.count)
            var exclusions = 0, start: Int?, k = 0
            while k < crossings.count {
                let first = crossings[k], y = edges[first].y(middle)
                let wasFilled = counts.allSatisfy { $0 > 0 } && exclusions == 0
                repeat {
                    let p = edges[crossings[k]].polygon
                    inside[p].toggle()
                    if p >= positiveCount { exclusions += inside[p] ? 1 : -1 }
                    else { counts[groupForPolygon[p]] += inside[p] ? 1 : -1 }
                    k += 1
                } while k < crossings.count && edges[crossings[k]].y(middle) == y
                let filled = counts.allSatisfy { $0 > 0 } && exclusions == 0
                if !wasFilled && filled { start = first }
                if wasFilled && !filled, let lower = start {
                    let l0 = edges[lower].y(left), l1 = edges[lower].y(right)
                    let h0 = edges[first].y(left), h1 = edges[first].y(right)
                    // A negative gap beyond roundoff means the event partition is invalid.
                    guard h0 >= l0-1e-7, h1 >= l1-1e-7 else { throw tooComplex() }
                    let points = [PCBPoint(left,l0),.init(right,l1),.init(right,max(l1,h1)),.init(left,max(l0,h0))]
                    var cell: [PCBPoint] = []
                    for point in points where cell.last != point { cell.append(point) }
                    if cell.first == cell.last { cell.removeLast() }
                    if cell.count >= 3 && area(cell) > 1e-14 { result.append(cell) }
                    if result.count > 30_000 { throw tooComplex() }
                    start = nil
                }
            }
        }
        return result
    }
    static func area(_ p: [PCBPoint]) -> Double {
        // Translate to a local origin to avoid cancellation on boards far from (0,0).
        guard let origin = p.first else { return 0 }
        return abs(PCBGeometry.edges(p).reduce(0) { $0 + ($1.0.x-origin.x)*($1.1.y-origin.y)-($1.1.x-origin.x)*($1.0.y-origin.y) })/2
    }
    static func tooComplex() -> ElectronicsFailure {
        ElectronicsPCB.failure("zone_fill_complexity", "Riempimento troppo complesso: suddividere il piano o ridurre i contorni. Nessun rame parziale è stato applicato.")
    }
    /// A circumscribed polygon, so approximating a circular obstacle can only REMOVE
    /// extra copper. Radial overcut <= 0.005 mm; never undercut a required clearance.
    static func expandedConvex(_ core: [PCBPoint], radius: Double, symmetric: Bool = false) throws -> [PCBPoint] {
        if radius <= 0 { return core }
        var count = max(16,Int(ceil(Double.pi/acos(radius/(radius+0.005)))))
        if symmetric && count % 2 != 0 { count += 1 }
        guard count <= 512 else { throw tooComplex() }
        let r = radius/cos(.pi/Double(count))
        let ring = (0..<count).map { i in PCBPoint(r*cos(2 * .pi * Double(i)/Double(count)), r*sin(2 * .pi * Double(i)/Double(count))) }
        return hull(core.flatMap { p in ring.map { .init(p.x+$0.x,p.y+$0.y) } })
    }
    static func hull(_ points: [PCBPoint]) -> [PCBPoint] {
        let sorted = points.sorted { $0.x == $1.x ? $0.y < $1.y : $0.x < $1.x }
        var unique: [PCBPoint] = []
        for p in sorted where unique.last != p { unique.append(p) }
        if unique.count <= 2 { return unique }
        func chain(_ points: [PCBPoint]) -> [PCBPoint] {
            var result: [PCBPoint] = []
            for p in points {
                while result.count >= 2 && PCBGeometry.cross(result[result.count-2],result.last!,p) <= 0 { result.removeLast() }
                result.append(p)
            }
            return result
        }
        return Array(chain(unique).dropLast()) + Array(chain(Array(unique.reversed())).dropLast())
    }
}
