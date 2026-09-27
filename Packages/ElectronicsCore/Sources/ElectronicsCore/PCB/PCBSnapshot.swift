import Foundation

public struct PCBHit: Equatable, Sendable {
    public var item: PCBItem
    public var netID: UUID?
    public var position: PCBPoint
    public var distance: Double
}
public struct PCBSnapTarget: Equatable, Sendable {
    public init(kind: Kind, item: PCBItem?, netID: UUID?, position: PCBPoint, distance: Double) {
        self.kind = kind; self.item = item; self.netID = netID; self.position = position; self.distance = distance
    }
    public enum Kind: Int, Sendable { case pad, via, endpoint, track, grid }
    public var kind: Kind
    public var item: PCBItem?
    public var netID: UUID?
    public var position: PCBPoint
    public var distance: Double
}
public struct PCBSnapshot: Sendable {
    public let designID: UUID
    public let revision: UInt64
    public let layerCount: Int
    public let primitives: [PCBCopperPrimitive]
    public let board: BoardConnectivity
    public let issues: [ElectronicsIssue]
    let index: PCBIndex

    public func pick(point: PCBPoint, tolerance: Double, layer: Int? = nil) -> [PCBHit] {
        guard ElectronicsGeometry.valid(point), tolerance.isFinite, tolerance >= 0 else { return [] }
        var hits: [PCBItem: PCBHit] = [:]
        for i in index.query(.init([point], margin:tolerance)) {
            let p = primitives[i]; if let layer, !p.layers.contains(layer) { continue }
            let d = PCBGeometry.pointDistance(point,p)
            guard d <= tolerance else { continue }
            let position = p.core.count == 2 ? PCBGeometry.nearest(point,p.core[0],p.core[1]) : p.center
            if hits[p.item].map({ $0.distance <= d }) != true { hits[p.item] = .init(item:p.item,netID:p.netID,position:position,distance:d) }
        }
        return hits.values.sorted { $0.distance == $1.distance ? $0.item.key < $1.item.key : $0.distance < $1.distance }
    }
    public func snapTargets(near point: PCBPoint, radius: Double, layer: Int, netID: UUID? = nil, grid: Double? = nil) -> [PCBSnapTarget] {
        guard ElectronicsGeometry.valid(point), radius.isFinite, radius >= 0, (0..<layerCount).contains(layer) else { return [] }
        var targets: [PCBSnapTarget] = []
        func add(_ kind: PCBSnapTarget.Kind, _ p: PCBPoint, _ primitive: PCBCopperPrimitive?) {
            let d = PCBGeometry.distance(point,p)
            guard d <= radius else { return }
            let t = PCBSnapTarget(kind:kind,item:primitive?.item,netID:primitive?.netID,position:p,distance:d)
            if !targets.contains(t) { targets.append(t) }
        }
        for i in index.query(.init([point], margin:radius)) {
            let p = primitives[i]
            guard p.layers.contains(layer), netID == nil || p.netID == netID else { continue }
            switch p.item {
            case .pad: add(.pad,p.center,p)
            case .via: add(.via,p.center,p)
            case .track:
                for v in p.core { add(.endpoint,v,p) }
                add(.track,PCBGeometry.nearest(point,p.core[0],p.core[1]),p)
            }
        }
        if let grid, let p = ElectronicsPCB.gridPoint(point,spacing:grid) { add(.grid,p,nil) }
        return targets.sorted {
            if $0.kind != $1.kind { return $0.kind.rawValue < $1.kind.rawValue }
            if $0.distance != $1.distance { return $0.distance < $1.distance }
            if $0.item != $1.item { return ($0.item?.key ?? "") < ($1.item?.key ?? "") }
            return $0.position.x == $1.position.x ? $0.position.y < $1.position.y : $0.position.x < $1.position.x
        }
    }
}

extension ElectronicsPCB {
    public static func snapshot(_ document: ElectronicsDocument) throws -> PCBSnapshot {
        try snapshot(design:document.design,revision:document.revision)
    }
    public static func snapshot(design: ElectronicsDesign, revision: UInt64) throws -> PCBSnapshot {
        try Task.checkCancellation()
        let base = try ElectronicsConnectivity.unroutedSnapshot(design)
        let copper = design.board.copper ?? .init(), rules = copper.rules
        var primitives = base.pads.map { PCBGeometry.pad($0,layerCount:copper.layerCount) }
        for t in copper.tracks.sorted(by: { $0.id.uuidString < $1.id.uuidString }) {
            for (a,b) in zip(t.points,t.points.dropFirst()) {
                primitives.append(.init(item:.track(t.id),netID:t.netID,layers:[t.layer],core:[a,b],radius:t.width/2))
            }
        }
        for v in copper.vias.sorted(by: { $0.id.uuidString < $1.id.uuidString }) {
            primitives.append(.init(item:.via(v.id),netID:v.netID,layers:Array(0..<copper.layerCount),core:[v.position],radius:v.diameter/2,drillDiameter:v.drill))
        }
        let index = try PCBIndex(primitives)
        var issues: [ElectronicsIssue] = [], issueKeys = Set<String>()
        func add(_ code: String, _ message: String, _ items: [PCBItem], _ point: PCBPoint, severity: ElectronicsIssue.Severity = .error) {
            let key = code+items.map(\.key).sorted().joined(separator:"|")
            guard issueKeys.insert(key).inserted else { return }
            var issue = ElectronicsIssue(code,"PCB",message,severity:severity)
            issue.subjectIDs = items.flatMap(\.subjectIDs); issue.position = point; issues.append(issue)
        }
        var parent = Array(primitives.indices)
        func root(_ i: Int) -> Int {
            var r = i
            while parent[r] != r { r = parent[r] }
            var k = i
            while parent[k] != k { let next = parent[k]; parent[k] = r; k = next }
            return r
        }
        func union(_ a: Int, _ b: Int) { let x = root(a), y = root(b); parent[max(x,y)] = min(x,y) }
        let padPins = Dictionary(uniqueKeysWithValues:base.pads.map { (PCBItem.pad(componentID:$0.componentID,padID:$0.padID), PinReference(componentID:$0.componentID,pinID:$0.pinID)) })
        for i in primitives.indices {
            try Task.checkCancellation()
            let a = primitives[i]
            let outside = a.core.contains { !PCBGeometry.inside($0,design.board.outline) }
            let boundary = PCBGeometry.edges(a.core).flatMap { edge in PCBGeometry.edges(design.board.outline).map { PCBGeometry.segmentDistance(edge.0,edge.1,$0.0,$0.1) } }.min()!
            if outside || boundary+PCBGeometry.epsilon < a.radius+rules.edgeClearance {
                add("pcb_edge_clearance","Rame fuori scheda o a meno di \(rules.edgeClearance) mm dal bordo: spostarlo verso l’interno.",[a.item],a.center)
            }
            if let drill = a.drillDiameter {
                if drill+PCBGeometry.epsilon < rules.minimumDrill { add("pcb_drill","Foro da \(drill) mm, minimo \(rules.minimumDrill) mm: aumentare la foratura.",[a.item],a.center) }
                let ring: Double
                if case .pad = a.item, let p = base.pads.first(where: { $0.padID == a.item.subjectIDs.last && $0.componentID == a.item.subjectIDs.first }) { ring = (min(p.size.x,p.size.y)-drill)/2 }
                else { ring = a.radius-drill/2 }
                if ring+PCBGeometry.epsilon < rules.minimumAnnularRing { add("pcb_annular_ring","Anello anulare da \(String(format: "%.3f", ring)) mm, minimo \(rules.minimumAnnularRing) mm: aumentare il rame intorno al foro.",[a.item],a.center) }
            }
            if case .track = a.item, 2*a.radius+PCBGeometry.epsilon < rules.minimumTrackWidth { add("pcb_track_width","Pista larga \(2*a.radius) mm, minimo \(rules.minimumTrackWidth) mm: aumentare la larghezza.",[a.item],a.center) }
            for j in index.query(PCBBox(a.core,margin:a.radius+rules.clearance)) where j > i {
                let b = primitives[j]
                guard !Set(a.layers).isDisjoint(with:b.layers) else { continue }
                if a.item == b.item { union(i,j); continue }
                let sameSignal = (a.netID != nil && a.netID == b.netID) || (padPins[a.item] != nil && padPins[a.item] == padPins[b.item])
                let gap = PCBGeometry.gap(a,b)
                if sameSignal {
                    if gap <= PCBGeometry.epsilon { union(i,j) }
                } else if gap <= PCBGeometry.epsilon {
                    add("pcb_short","Contatto fra reti diverse o piazzole senza rete: separare il rame o correggere lo schema.",[a.item,b.item],.init((a.center.x+b.center.x)/2,(a.center.y+b.center.y)/2))
                } else if gap+PCBGeometry.epsilon < rules.clearance {
                    add("pcb_clearance","Distanza \(String(format: "%.3f", gap)) mm, minimo \(rules.clearance) mm: allontanare il rame.",[a.item,b.item],.init((a.center.x+b.center.x)/2,(a.center.y+b.center.y)/2))
                }
                if let da = a.drillDiameter, let db = b.drillDiameter,
                   PCBGeometry.distance(a.center,b.center)-(da+db)/2+PCBGeometry.epsilon < rules.clearance {
                    add("pcb_hole_clearance","Forature troppo vicine, anche se della stessa rete.",[a.item,b.item],a.center)
                }
            }
        }
        let roots = primitives.indices.map { root($0) }
        let padRoots = Set(base.pads.indices.map { roots[$0] })
        for i in primitives.indices where !padRoots.contains(roots[i]) {
            add("pcb_floating_copper","Rame non collegato fisicamente ad alcuna piazzola.",[primitives[i].item],primitives[i].center,severity:.warning)
        }
        var airwires: [Airwire] = []
        for net in design.nets.sorted(by: { $0.id.uuidString < $1.id.uuidString }) {
            let members = base.pads.indices.filter { base.pads[$0].netID == net.id }
            guard let first = members.first else { continue }
            var reached: Set<Int> = [], newlyReached = members.filter { roots[$0] == roots[first] }
            var best: [Int: (distance: Double, from: Int)] = [:]
            while !newlyReached.isEmpty {
                try Task.checkCancellation()
                reached.formUnion(newlyReached)
                for a in newlyReached {
                    for b in members where !reached.contains(b) {
                        let d = PCBGeometry.distance(base.pads[a].center,base.pads[b].center)
                        if best[b] == nil || d < best[b]!.distance { best[b] = (d,a) }
                    }
                }
                guard let next = members.filter({ !reached.contains($0) }).min(by: { a,b in best[a]!.distance == best[b]!.distance ? a < b : best[a]!.distance < best[b]!.distance }) else { break }
                let a = base.pads[best[next]!.from], b = base.pads[next]
                airwires.append(.init(netID:net.id,fromComponent:a.componentID,fromPad:a.padID,toComponent:b.componentID,toPad:b.padID,from:a.center,to:b.center))
                add("pcb_unrouted","Collegamento ancora da sbrogliare.",[.pad(componentID:a.componentID,padID:a.padID),.pad(componentID:b.componentID,padID:b.padID)],a.center,severity:.warning)
                newlyReached = members.filter { !reached.contains($0) && roots[$0] == roots[next] }
            }
        }
        return .init(designID:design.id,revision:revision,layerCount:copper.layerCount,primitives:primitives,
                     board:.init(pads:base.pads,airwires:airwires,unplacedComponents:base.unplacedComponents),issues:issues,index:index)
    }
}
