import Foundation

/// Independent of the renderer. Curved legend graphics are flattened to <= 0.002 mm sagitta.
enum FabricationGeometry {
    static func object(_ p: PCBCopperPrimitive, kind: FabricationObject.Kind = .flash) -> FabricationObject {
        .init(kind:kind,subjectIDs:p.item.subjectIDs,core:p.core,radius:p.radius)
    }
    static func pad(_ p: PlacedPad, margin: Double) -> FabricationObject? {
        var pad = p
        pad.size = .init(p.size.x+2*margin,p.size.y+2*margin)
        guard min(pad.size.x,pad.size.y) >= 0.001 else { return nil }
        // Parallel-sided pad enlargement/reduction; preserve its shape family.
        if let radius = p.cornerRadius { pad.cornerRadius = max(0,min(radius+margin,min(pad.size.x,pad.size.y)/2)) }
        return object(PCBGeometry.pad(pad,layerCount:2))
    }
    static func graphic(_ g: LibraryGraphic, placement: ComponentPlacement) throws -> [FabricationObject] {
        let ids = [placement.componentID,g.id]
        func make(_ points: [PCBPoint], filled: Bool = false) -> FabricationObject {
            .init(kind:filled ? .region : .stroke,subjectIDs:ids,
                  core:points.map { ElectronicsGeometry.boardPoint($0,placement:placement) },radius:filled ? 0 : g.strokeWidth/2)
        }
        func area(_ points: [PCBPoint]) -> [FabricationObject] {
            let boundary = points.last == points.first ? Array(points.dropLast()) : points
            var result = [make(boundary,filled:true)]
            if g.strokeWidth > 0 { result.append(make(boundary+[boundary[0]])) }
            return result
        }
        let p = g.points
        switch g.kind {
        case .line, .polyline:
            if g.filled { guard ElectronicsGeometry.simplePolygon(p) else { throw failure(ids) }; return area(p) }
            guard zip(p,p.dropFirst()).allSatisfy({ PCBGeometry.distance($0,$1) >= 0.00001 }) else { throw failure(ids) }
            return [make(p)]
        case .rectangle:
            let points: [PCBPoint] = [p[0],.init(p[1].x,p[0].y),p[1],.init(p[0].x,p[1].y)]
            guard ElectronicsGeometry.simplePolygon(points) else { throw failure(ids) }
            return g.filled ? area(points) : [make(points+[points[0]])]
        case .circle:
            let radius = PCBGeometry.distance(p[0],p[1])
            guard radius >= 0.001 else { throw failure(ids) }
            let points = try arc(center:p[0],radius:radius,start:0,sweep:2 * .pi,ids:ids)
            return g.filled ? area(points) : [make(points)]
        case .arc:
            guard !g.filled else { throw failure(ids) }
            let a = p[0], b = p[1], c = p[2], denominator = 2*PCBGeometry.cross(a,b,c)
            guard abs(denominator) > 1e-10 else { throw failure(ids) }
            let u = PCBPoint(b.x-a.x,b.y-a.y), v = PCBPoint(c.x-a.x,c.y-a.y)
            let u2 = u.x*u.x+u.y*u.y, v2 = v.x*v.x+v.y*v.y
            let center = PCBPoint(a.x+(u2*v.y-v2*u.y)/denominator,a.y+(u.x*v2-v.x*u2)/denominator)
            let start = atan2(a.y-center.y,a.x-center.x), end = atan2(c.y-center.y,c.x-center.x)
            var sweep = end-start
            if denominator > 0 { while sweep <= 0 { sweep += 2 * .pi } }
            else { while sweep >= 0 { sweep -= 2 * .pi } }
            var points = try arc(center:center,radius:PCBGeometry.distance(a,center),start:start,sweep:sweep,ids:ids)
            points[0] = a; points[points.count-1] = c
            return [make(points)]
        }
    }
    static func arc(center: PCBPoint, radius: Double, start: Double, sweep: Double, ids: [UUID]) throws -> [PCBPoint] {
        guard radius.isFinite, radius >= 0.001 else { throw failure(ids) }
        let step = min(.pi/8,2*acos(max(-1,min(1,1-0.002/radius))))
        guard step.isFinite, step > 0 else { throw failure(ids) }
        let count = ceil(abs(sweep)/step)
        guard count <= 8192 else { throw failure(ids) }
        return (0...Int(count)).map { i in
            let a = start+sweep*Double(i)/count
            return .init(center.x+radius*cos(a),center.y+radius*sin(a))
        }
    }
    static func failure(_ ids: [UUID]) -> ElectronicsFailure {
        issue("fabrication_graphic","Serigrafia degenere, troppo complessa o riempimento non supportato: correggere la libreria.",ids)
    }
    static func issue(_ code: String, _ message: String, _ ids: [UUID] = [], _ position: PCBPoint? = nil) -> ElectronicsFailure {
        var value = ElectronicsIssue(code,"Produzione",message)
        value.subjectIDs = ids; value.position = position
        return .init([value])
    }
    static func parts(_ object: FabricationObject) -> [PCBCopperPrimitive] {
        if object.kind != .stroke { return [object.copper] }
        return zip(object.core,object.core.dropFirst()).map { a,b in
            .init(item:.track(object.subjectIDs[0]),netID:nil,layers:[0],core:[a,b],radius:object.radius)
        }
    }
}
