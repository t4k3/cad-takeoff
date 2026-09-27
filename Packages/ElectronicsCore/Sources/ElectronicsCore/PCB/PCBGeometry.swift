import Foundation

// Shared by connectivity, DRC and picking. No tessellation-dependent clearance calculations.
enum PCBGeometry {
    static let epsilon = 1e-8 // mm, numerical contact tolerance (not a manufacturing tolerance)
    static func distance(_ a: PCBPoint, _ b: PCBPoint) -> Double { hypot(a.x-b.x, a.y-b.y) }
    static func nearest(_ p: PCBPoint, _ a: PCBPoint, _ b: PCBPoint) -> PCBPoint {
        let x = b.x-a.x, y = b.y-a.y, length = x*x+y*y
        guard length > 0 else { return a }
        let t = max(0, min(1, ((p.x-a.x)*x+(p.y-a.y)*y)/length))
        return .init(a.x+t*x, a.y+t*y)
    }
    static func cross(_ a: PCBPoint, _ b: PCBPoint, _ c: PCBPoint) -> Double {
        (b.x-a.x)*(c.y-a.y)-(b.y-a.y)*(c.x-a.x)
    }
    static func edges(_ core: [PCBPoint]) -> [(PCBPoint, PCBPoint)] {
        if core.count == 1 { return [(core[0],core[0])] }
        if core.count == 2 { return [(core[0],core[1])] }
        return core.indices.map { (core[$0], core[($0+1)%core.count]) }
    }
    static func segmentDistance(_ a: PCBPoint, _ b: PCBPoint, _ c: PCBPoint, _ d: PCBPoint) -> Double {
        let abC = cross(a,b,c), abD = cross(a,b,d), cdA = cross(c,d,a), cdB = cross(c,d,b)
        if abC*abD < 0 && cdA*cdB < 0 { return 0 }
        return min(distance(a,nearest(a,c,d)), distance(b,nearest(b,c,d)),
                   distance(c,nearest(c,a,b)), distance(d,nearest(d,a,b)))
    }
    static func inside(_ p: PCBPoint, _ polygon: [PCBPoint]) -> Bool {
        guard polygon.count >= 3 else { return false }
        var result = false
        for (a,b) in edges(polygon) {
            if distance(p, nearest(p,a,b)) <= epsilon { return true }
            if (a.y > p.y) != (b.y > p.y), p.x < (b.x-a.x)*(p.y-a.y)/(b.y-a.y)+a.x { result.toggle() }
        }
        return result
    }
    static func coreDistance(_ a: [PCBPoint], _ b: [PCBPoint]) -> Double {
        if inside(a[0], b) || inside(b[0], a) { return 0 }
        return edges(a).flatMap { x in edges(b).map { y in segmentDistance(x.0,x.1,y.0,y.1) } }.min()!
    }
    static func gap(_ a: PCBCopperPrimitive, _ b: PCBCopperPrimitive) -> Double {
        var result = coreDistance(a.core,b.core)-a.radius-b.radius
        // Exclude the empty circular bore. A trace completely within it is not connected.
        for (hole, other) in [(a,b),(b,a)] {
            if let drill = hole.drillDiameter {
                let furthest = other.core.map { distance(hole.center,$0) }.max()! + other.radius
                result = max(result, drill/2-furthest)
            }
        }
        return result
    }
    static func pointDistance(_ point: PCBPoint, _ shape: PCBCopperPrimitive) -> Double {
        let outer = max(0, coreDistance([point], shape.core)-shape.radius)
        let inner = shape.drillDiameter.map { max(0, $0/2-distance(point,shape.center)) } ?? 0
        return max(outer, inner)
    }
    static func pad(_ pad: PlacedPad, layerCount: Int) -> PCBCopperPrimitive {
        let hx = pad.size.x/2, hy = pad.size.y/2
        let r: Double
        switch pad.shape { case .circle, .oval: r = min(hx,hy); case .rectangle: r = 0; case .roundedRectangle: r = pad.cornerRadius ?? 0 }
        let x = hx-r, y = hy-r
        let local: [PCBPoint]
        if x <= epsilon && y <= epsilon { local = [.init()] }
        else if x <= epsilon { local = [.init(0,-y),.init(0,y)] }
        else if y <= epsilon { local = [.init(-x,0),.init(x,0)] }
        else { local = [.init(-x,-y),.init(x,-y),.init(x,y),.init(-x,y)] }
        let angle = pad.rotationDegrees * .pi/180
        let core = local.map { PCBPoint(pad.center.x+cos(angle)*$0.x-sin(angle)*$0.y, pad.center.y+sin(angle)*$0.x+cos(angle)*$0.y) }
        return .init(item: .pad(componentID: pad.componentID, padID: pad.padID), netID: pad.netID,
                     layers: pad.drillDiameter != nil ? Array(0..<layerCount) : pad.copperSides.map { $0 == .top ? 0 : layerCount-1 },
                     core: core, radius: r, drillDiameter: pad.drillDiameter)
    }
}

struct PCBBox: Sendable {
    var minX: Double, minY: Double, maxX: Double, maxY: Double
    init(_ points: [PCBPoint], margin: Double = 0) {
        minX = points.map(\.x).min()!-margin; minY = points.map(\.y).min()!-margin
        maxX = points.map(\.x).max()!+margin; maxY = points.map(\.y).max()!+margin
    }
    init(_ a: Self, _ b: Self) {
        minX = min(a.minX,b.minX); minY = min(a.minY,b.minY); maxX = max(a.maxX,b.maxX); maxY = max(a.maxY,b.maxY)
    }
    func expanded(_ d: Double) -> Self { .init([.init(minX,minY),.init(maxX,maxY)], margin:d) }
    func intersects(_ b: Self) -> Bool { minX <= b.maxX && maxX >= b.minX && minY <= b.maxY && maxY >= b.minY }
}

/// Immutable median BVH; reused for DRC broad phase and cursor queries.
struct PCBIndex: Sendable {
    struct Node: Sendable { var box: PCBBox; var left: Int?; var right: Int?; var items: [Int] }
    var nodes: [Node] = []
    init(_ primitives: [PCBCopperPrimitive]) throws {
        try self.init(boxes: primitives.map { PCBBox($0.core, margin:$0.radius) })
    }
    init(boxes: [PCBBox]) throws {
        func build(_ ids: [Int]) throws -> Int {
            try Task.checkCancellation()
            let box = ids.dropFirst().reduce(boxes[ids[0]]) { PCBBox($0,boxes[$1]) }
            let i = nodes.count; nodes.append(.init(box: box, items: []))
            if ids.count <= 8 { nodes[i].items = ids; return i }
            let horizontal = box.maxX-box.minX >= box.maxY-box.minY
            let ordered = ids.sorted { a,b in
                let x = horizontal ? boxes[a].minX+boxes[a].maxX : boxes[a].minY+boxes[a].maxY
                let y = horizontal ? boxes[b].minX+boxes[b].maxX : boxes[b].minY+boxes[b].maxY
                return x == y ? a < b : x < y
            }
            let half = ordered.count/2
            nodes[i].left = try build(Array(ordered[..<half])); nodes[i].right = try build(Array(ordered[half...]))
            return i
        }
        if !boxes.isEmpty { _ = try build(Array(boxes.indices)) }
    }
    func query(_ box: PCBBox) -> [Int] {
        guard !nodes.isEmpty else { return [] }
        var stack = [0], result: [Int] = []
        while let i = stack.popLast() {
            let node = nodes[i]; guard node.box.intersects(box) else { continue }
            result += node.items
            if let a = node.left { stack.append(a) }; if let b = node.right { stack.append(b) }
        }
        return result.sorted()
    }
}
