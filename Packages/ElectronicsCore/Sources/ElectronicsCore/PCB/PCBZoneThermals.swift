import Foundation

enum PCBZoneThermals {
    struct Candidate {
        let pad: PlacedPad
        let bands: [[PCBPoint]]
    }
    struct Cutout {
        let obstacles: [[PCBPoint]]
        let candidate: Candidate?
    }
    static func cutout(pad: PlacedPad, primitive: PCBCopperPrimitive, zone: PCBZone) throws -> Cutout {
        let thermal = zone.connection == .thermal || (zone.connection == .thermalThroughHole && pad.drillDiameter != nil)
        guard thermal || zone.connection == .none else { return .init(obstacles:[],candidate:nil) }
        let outer = try PCBPolygonFill.expandedConvex(primitive.core,radius:primitive.radius+zone.thermalGap+PCBZoneFilling.guardBand)
        guard thermal else { return .init(obstacles:[outer],candidate:nil) }
        let far = outer.map { PCBGeometry.distance($0,pad.center) }.max()! + 0.02
        var bands: [[PCBPoint]] = []
        let baseAngle = (pad.rotationDegrees+zone.thermalAngleDegrees) * .pi/180
        func clean(_ x: Double) -> Double { abs(x) < 1e-14 ? 0 : x }
        let axis = PCBPoint(clean(cos(baseAngle)),clean(sin(baseAngle)))
        let perpendicular = PCBPoint(-axis.y,axis.x)
        var padOuter = primitive; padOuter.drillDiameter = nil
        for n in 0..<4 {
            let u: PCBPoint = switch n { case 0: axis; case 1: perpendicular; case 2: .init(-axis.x,-axis.y); default: .init(-perpendicular.x,-perpendicular.y) }
            let v = PCBPoint(-u.y,u.x)
            func point(_ t: Double, _ s: Double) -> PCBPoint { .init(pad.center.x+u.x*t+v.x*s,pad.center.y+u.y*t+v.y*s) }
            func rectangle(_ start: Double, _ end: Double, _ half: Double) -> [PCBPoint] {
                [point(start,-half),point(end,-half),point(end,half),point(start,half)]
            }
            let half = zone.thermalSpokeWidth/2
            // Both sides of the spoke must actually meet the pad. A wide band touching
            // a tiny pad with its centre only is not a full-width thermal connection.
            func exit(_ s: Double) -> Double? {
                guard PCBGeometry.pointDistance(point(0,s),padOuter) <= PCBGeometry.epsilon else { return nil }
                var a = 0.0, b = far
                for _ in 0..<60 {
                    let m = (a+b)/2
                    if PCBGeometry.pointDistance(point(m,s),padOuter) <= PCBGeometry.epsilon { a = m } else { b = m }
                }
                return a
            }
            if let a = exit(-half), let b = exit(half) {
                let start = max(0,min(a,b)-1e-6)
                let end = outer.map { ($0.x-pad.center.x)*u.x+($0.y-pad.center.y)*u.y }.max()! + 1e-5
                bands.append(rectangle(start,end,max(half-1e-7,half*0.999999)))
            }
        }
        // These exclusions (gap minus four bands) join all other obstacles before
        // filling. Adding a spoke never restores foreign copper, a bore, or a keepout.
        func clip(_ polygon: [PCBPoint], normal: PCBPoint) -> [PCBPoint] {
            guard !polygon.isEmpty else { return [] }
            func signed(_ p: PCBPoint) -> Double { (p.x-pad.center.x)*normal.x+(p.y-pad.center.y)*normal.y-zone.thermalSpokeWidth/2 }
            var result: [PCBPoint] = []
            for (a,b) in PCBGeometry.edges(polygon) {
                let da = signed(a), db = signed(b)
                if da >= 0 { result.append(a) }
                if (da < 0) != (db < 0) {
                    let t = da/(da-db); result.append(.init(a.x+t*(b.x-a.x),a.y+t*(b.y-a.y)))
                }
            }
            return result
        }
        var exclusions: [[PCBPoint]] = []
        for x in [-1.0,1.0] { for y in [-1.0,1.0] {
            let p = clip(clip(outer,normal:.init(x*axis.x,x*axis.y)),normal:.init(y*perpendicular.x,y*perpendicular.y))
            if p.count >= 3, PCBPolygonFill.area(p) > 1e-14 { exclusions.append(p) }
        } }
        return .init(obstacles:exclusions,candidate:.init(pad:pad,bands:bands))
    }
    static func resolve(_ candidates: [Candidate], cells: [[PCBPoint]]) throws -> [PCBZoneThermal] {
        let index = try PCBIndex(boxes:cells.map { PCBBox($0) })
        return try candidates.map { c in
            var count = 0
            for band in c.bands {
                try Task.checkCancellation()
                let covering = index.query(PCBBox(band)).map { cells[$0] }
                let missing = try PCBPolygonFill.cells(subject:band,board:band,obstacles:covering)
                if missing.map(PCBPolygonFill.area).reduce(0,+) <= 1e-10 * max(1,PCBPolygonFill.area(band)) { count += 1 }
            }
            return .init(componentID:c.pad.componentID,padID:c.pad.padID,position:c.pad.center,connectedSpokes:count)
        }
    }
}
