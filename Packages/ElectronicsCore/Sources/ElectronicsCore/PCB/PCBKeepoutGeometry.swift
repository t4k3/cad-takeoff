import Foundation

extension PCBGeometry {
    static func keepoutIntersects(_ area: PCBKeepout, _ copper: PCBCopperPrimitive) -> Bool {
        // Simple polygons may be concave: coreDistance uses containment and all edges,
        // never their bounding boxes or convex hull. A bore contains no copper.
        let region = PCBCopperPrimitive(item:copper.item,netID:nil,layers:area.layers,core:area.outline,radius:0)
        return gap(copper,region) <= epsilon
    }

    static func keepoutContact(_ area: PCBKeepout, _ copper: PCBCopperPrimitive) -> PCBPoint {
        if let vertex = area.outline.first(where: { pointDistance($0,copper) <= epsilon }) { return vertex }
        if copper.drillDiameter == nil, let vertex = copper.core.first(where: { inside($0,area.outline) }) { return vertex }
        var best = (distance: Double.infinity, point: copper.center)
        for (a,b) in edges(copper.core) {
            for (c,d) in edges(area.outline) {
                let crossCD = cross(.init(), .init(b.x-a.x,b.y-a.y), .init(d.x-c.x,d.y-c.y))
                if abs(crossCD) > epsilon {
                    let t = cross(.init(),.init(c.x-a.x,c.y-a.y),.init(d.x-c.x,d.y-c.y))/crossCD
                    let u = cross(.init(),.init(c.x-a.x,c.y-a.y),.init(b.x-a.x,b.y-a.y))/crossCD
                    if (0...1).contains(t), (0...1).contains(u) { return .init(a.x+t*(b.x-a.x),a.y+t*(b.y-a.y)) }
                }
                for (x,y) in [(a,nearest(a,c,d)),(b,nearest(b,c,d)),(nearest(c,a,b),c),(nearest(d,a,b),d)] {
                    let gap = distance(x,y)
                    if gap < best.distance { best = (gap,y) }
                }
            }
        }
        return best.point
    }
}

extension PCBSnapshot {
    public func pickKeepouts(point: PCBPoint, tolerance: Double, layer: Int? = nil) -> [PCBKeepoutHit] {
        guard ElectronicsGeometry.valid(point), tolerance.isFinite, tolerance >= 0 else { return [] }
        var result: [PCBKeepoutHit] = []
        for i in keepoutIndex.query(.init([point], margin:tolerance)) {
            let k = keepouts[i]
            if let layer, !k.layers.contains(layer) { continue }
            let nearest = PCBGeometry.edges(k.outline).map { PCBGeometry.nearest(point,$0.0,$0.1) }
                .min { PCBGeometry.distance(point,$0) < PCBGeometry.distance(point,$1) }!
            let inside = PCBGeometry.inside(point,k.outline)
            let distance = inside ? 0 : PCBGeometry.distance(point,nearest)
            if distance <= tolerance { result.append(.init(id:k.id,position:inside ? point : nearest,distance:distance)) }
        }
        return result.sorted { $0.distance == $1.distance ? $0.id.uuidString < $1.id.uuidString : $0.distance < $1.distance }
    }
    public func keepoutSnapTargets(near point: PCBPoint, radius: Double, layer: Int) -> [PCBKeepoutSnapTarget] {
        guard ElectronicsGeometry.valid(point), radius.isFinite, radius >= 0, (0..<layerCount).contains(layer) else { return [] }
        var result: [PCBKeepoutSnapTarget] = []
        for i in keepoutIndex.query(.init([point],margin:radius)) {
            let k = keepouts[i]; guard k.layers.contains(layer) else { continue }
            func add(_ p: PCBPoint, _ kind: PCBKeepoutSnapTarget.Kind) {
                let distance = PCBGeometry.distance(point,p)
                if distance <= radius {
                    let target = PCBKeepoutSnapTarget(id:k.id,kind:kind,position:p,distance:distance)
                    if !result.contains(target) { result.append(target) }
                }
            }
            for p in k.outline { add(p,.vertex) }
            for (a,b) in PCBGeometry.edges(k.outline) { add(PCBGeometry.nearest(point,a,b),.edge) }
        }
        return result.sorted {
            if $0.kind != $1.kind { return $0.kind.rawValue < $1.kind.rawValue }
            if $0.distance != $1.distance { return $0.distance < $1.distance }
            if $0.id != $1.id { return $0.id.uuidString < $1.id.uuidString }
            return $0.position.x == $1.position.x ? $0.position.y < $1.position.y : $0.position.x < $1.position.x
        }
    }
}
