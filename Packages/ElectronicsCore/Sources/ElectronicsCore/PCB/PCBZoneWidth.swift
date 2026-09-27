import Foundation

/// Morphological opening with a symmetric circumscribed polygonal disk. Erosion uses
/// the UNION of obstacles, never individual positive cells; decomposition seams must
/// not remove good copper. The final intersection cannot violate the original clearance.
enum PCBZoneWidth {
    struct Result {
        let cells: [[PCBPoint]]
        let removedArea: Double
        let necks: [PCBPoint]
    }
    static func filter(zone: PCBZone, board: [PCBPoint], obstacles: [[PCBPoint]], raw: [[PCBPoint]]) throws -> Result {
        guard zone.minimumWidth > 0, !raw.isEmpty else { return .init(cells:raw,removedArea:0,necks:[]) }
        let r = zone.minimumWidth/2
        var expanded: [[PCBPoint]] = []
        for p in obstacles {
            try Task.checkCancellation()
            let convex = PCBGeometry.edges(p).indices.allSatisfy { i in
                PCBGeometry.cross(p[i],p[(i+1)%p.count],p[(i+2)%p.count]) >= -1e-12
            }
            if convex { expanded.append(try PCBPolygonFill.expandedConvex(p,radius:r,symmetric:true)) }
            else {
                expanded.append(p)
                for (a,b) in PCBGeometry.edges(p) { expanded.append(try PCBPolygonFill.expandedConvex([a,b],radius:r,symmetric:true)) }
            }
        }
        for p in [zone.outline,board] {
            for (a,b) in PCBGeometry.edges(p) { expanded.append(try PCBPolygonFill.expandedConvex([a,b],radius:r,symmetric:true)) }
        }
        let eroded = try coalesced(PCBPolygonFill.cells(subject:zone.outline,board:board,obstacles:expanded))
        let grown = try eroded.map { try PCBPolygonFill.expandedConvex($0,radius:r,symmetric:true) }
        let final = try coalesced(PCBPolygonFill.cells(groups:[[zone.outline],[board],grown],obstacles:obstacles))
        // Opening removes long thin bridges. A short pinch can survive dilation: flag
        // components which reconnect despite having no path with the requested clearance.
        // This is a width-of-path test, not a measurement of the arbitrary cell edges.
        let eRoots = try components(eroded), fRoots = try components(final)
        let fIndex = try PCBIndex(boxes:final.map { PCBBox($0) })
        var seeds: [Int:Set<Int>] = [:], witnesses: [Int:PCBPoint] = [:]
        for i in eroded.indices {
            try Task.checkCancellation()
            for j in fIndex.query(PCBBox(eroded[i])) where PCBGeometry.coreDistance(eroded[i],final[j]) <= PCBGeometry.epsilon {
                seeds[fRoots[j],default:[]].insert(eRoots[i]); witnesses[fRoots[j]] = eroded[i][0]
            }
        }
        let necks = seeds.keys.sorted().filter { seeds[$0]!.count > 1 }.compactMap { witnesses[$0] }
        return .init(cells:final,removedArea:max(0,raw.map(PCBPolygonFill.area).reduce(0,+)-final.map(PCBPolygonFill.area).reduce(0,+)),necks:necks)
    }
    /// Adjacent disjoint convex cells may be replaced by their hull ONLY when its area
    /// equals their sum. This removes decomposition seams before dilation, avoiding a
    /// quadratic arrangement of almost identical rounded rectangles. No hull of a hole
    /// or concavity is substituted. Tolerance is below the electrical contact tolerance.
    static func coalesced(_ input: [[PCBPoint]]) throws -> [[PCBPoint]] {
        var cells = input, work = 0
        for _ in 0..<32 {
            try Task.checkCancellation()
            let index = try PCBIndex(boxes:cells.map { PCBBox($0) })
            var removed = Set<Int>(), changed = false
            for i in cells.indices where !removed.contains(i) {
                for j in index.query(PCBBox(cells[i],margin:1e-10)).sorted() where j > i && !removed.contains(j) {
                    work += 1; guard work < 4_000_000 else { throw PCBPolygonFill.tooComplex() }
                    if PCBGeometry.coreDistance(cells[i],cells[j]) > 1e-10 { continue }
                    let a = PCBPolygonFill.area(cells[i])+PCBPolygonFill.area(cells[j])
                    let hull = PCBPolygonFill.hull(cells[i]+cells[j])
                    if abs(PCBPolygonFill.area(hull)-a) <= 1e-12 * max(1,a) {
                        cells[i] = hull; removed.insert(j); changed = true
                    }
                }
            }
            cells = cells.indices.filter { !removed.contains($0) }.map { cells[$0] }
            if !changed { break }
        }
        return cells
    }
    static func components(_ cells: [[PCBPoint]]) throws -> [Int] {
        guard !cells.isEmpty else { return [] }
        let index = try PCBIndex(boxes:cells.map { PCBBox($0) })
        var parent = Array(cells.indices)
        func root(_ i: Int) -> Int {
            var x = i
            while parent[x] != x { x = parent[x] }
            var y = i
            while parent[y] != y { let n = parent[y]; parent[y] = x; y = n }
            return x
        }
        var work = 0
        for i in cells.indices {
            try Task.checkCancellation()
            for j in index.query(PCBBox(cells[i],margin:PCBGeometry.epsilon)) where j > i {
                work += 1; guard work <= 4_000_000 else { throw PCBPolygonFill.tooComplex() }
                if PCBGeometry.coreDistance(cells[i],cells[j]) <= PCBGeometry.epsilon {
                    let a = root(i), b = root(j); parent[max(a,b)] = min(a,b)
                }
            }
        }
        return cells.indices.map { root($0) }
    }
}
