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
    public let keepouts: [PCBKeepout]
    public let zones: [PCBZoneFill]
    public let board: BoardConnectivity
    public let issues: [ElectronicsIssue]
    let index: PCBIndex
    let keepoutIndex: PCBIndex
    let zoneIndex: PCBIndex

    public func pick(point: PCBPoint, tolerance: Double, layer: Int? = nil) -> [PCBHit] {
        guard ElectronicsGeometry.valid(point), tolerance.isFinite, tolerance >= 0 else { return [] }
        var hits: [PCBItem: PCBHit] = [:]
        for i in index.query(.init([point], margin:tolerance)) {
            let p = primitives[i]; if let layer, !p.layers.contains(layer) { continue }
            let d = PCBGeometry.pointDistance(point,p)
            guard d <= tolerance else { continue }
            let position: PCBPoint
            if case .zone = p.item {
                position = PCBGeometry.inside(point,p.core) ? point : PCBGeometry.edges(p.core).map { PCBGeometry.nearest(point,$0.0,$0.1) }.min { PCBGeometry.distance(point,$0) < PCBGeometry.distance(point,$1) }!
            } else { position = p.core.count == 2 ? PCBGeometry.nearest(point,p.core[0],p.core[1]) : p.center }
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
            case .zone:
                // Inside filled copper is a valid routing target, never the outline of an empty island.
                if PCBGeometry.inside(point,p.core) { add(.track,point,p) }
                else {
                    for (a,b) in PCBGeometry.edges(p.core) { add(.track,PCBGeometry.nearest(point,a,b),p) }
                }
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
        let copper = design.board.copper ?? .init()
        let classByNet = Dictionary(uniqueKeysWithValues: copper.netClasses.flatMap { c in c.netIDs.map { ($0,c) } })
        let rulesByNet = Dictionary(uniqueKeysWithValues: design.nets.map { ($0.id, resolve(copper.rules, netClass:classByNet[$0.id]).rules) })
        let maximumClearance = rulesByNet.values.map(\.clearance).max() ?? copper.rules.clearance
        let keepouts = copper.keepouts.sorted { $0.id.uuidString < $1.id.uuidString }
        let keepoutIndex = try PCBIndex(boxes:keepouts.map { PCBBox($0.outline) })
        var primitives = base.pads.map { PCBGeometry.pad($0,layerCount:copper.layerCount) }
        for t in copper.tracks.sorted(by: { $0.id.uuidString < $1.id.uuidString }) {
            for (a,b) in zip(t.points,t.points.dropFirst()) {
                primitives.append(.init(item:.track(t.id),netID:t.netID,layers:[t.layer],core:[a,b],radius:t.width/2))
            }
        }
        for v in copper.vias.sorted(by: { $0.id.uuidString < $1.id.uuidString }) {
            primitives.append(.init(item:.via(v.id),netID:v.netID,layers:Array(0..<copper.layerCount),core:[v.position],radius:v.diameter/2,drillDiameter:v.drill))
        }
        let filled = try PCBZoneFilling.fill(design:design,copper:primitives,pads:base.pads,rules:rulesByNet)
        primitives += filled.primitives
        let index = try PCBIndex(primitives)
        var issues: [ElectronicsIssue] = [], issueKeys = Set<String>()
        if design.manufacturing != nil {
            issues.append(.init("manufacturing_drc_unavailable", "Scheda importata", "DRC nativo non disponibile sui Gerber importati: le reti sono attributi del file di produzione.", severity: .warning))
        }
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
            let rules = a.netID.flatMap { rulesByNet[$0] } ?? copper.rules
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
            for k in keepoutIndex.query(PCBBox(a.core,margin:a.radius+PCBGeometry.epsilon)) {
                let area = keepouts[k]
                guard area.excludes(a.item), !Set(area.layers).isDisjoint(with:a.layers),
                      PCBGeometry.keepoutIntersects(area,a) else { continue }
                let key = "pcb_keepout/" + area.id.uuidString + a.item.key
                if issueKeys.insert(key).inserted {
                    var issue = ElectronicsIssue("pcb_keepout", "PCB", "Rame nell’area vietata «\(area.name)»: spostarlo fuori dal contorno o modificare la regola.")
                    issue.subjectIDs = a.item.subjectIDs + [area.id]
                    issue.position = PCBGeometry.keepoutContact(area,a)
                    issues.append(issue)
                }
            }
            for j in index.query(PCBBox(a.core,margin:a.radius+maximumClearance)) where j > i {
                let b = primitives[j]
                let pairClearance = max(rules.clearance, b.netID.flatMap { rulesByNet[$0]?.clearance } ?? copper.rules.clearance)
                guard !Set(a.layers).isDisjoint(with:b.layers) else { continue }
                if a.item == b.item {
                    if case .zone = a.item {
                        if PCBGeometry.gap(a,b) <= PCBGeometry.epsilon { union(i,j) }
                    } else { union(i,j) }
                    continue
                }
                let sameSignal = (a.netID != nil && a.netID == b.netID) || (padPins[a.item] != nil && padPins[a.item] == padPins[b.item])
                let gap = PCBGeometry.gap(a,b)
                if sameSignal {
                    if gap <= PCBGeometry.epsilon { union(i,j) }
                } else if gap <= PCBGeometry.epsilon {
                    add("pcb_short","Contatto fra reti diverse o piazzole senza rete: separare il rame o correggere lo schema.",[a.item,b.item],.init((a.center.x+b.center.x)/2,(a.center.y+b.center.y)/2))
                } else if gap+PCBGeometry.epsilon < pairClearance {
                    add("pcb_clearance","Distanza \(String(format: "%.3f", gap)) mm, minimo \(pairClearance) mm: allontanare il rame.",[a.item,b.item],.init((a.center.x+b.center.x)/2,(a.center.y+b.center.y)/2))
                }
                if let da = a.drillDiameter, let db = b.drillDiameter,
                   PCBGeometry.distance(a.center,b.center)-(da+db)/2+PCBGeometry.epsilon < copper.rules.clearance {
                    add("pcb_hole_clearance","Forature troppo vicine, anche se della stessa rete.",[a.item,b.item],a.center)
                }
            }
        }
        let roots = primitives.indices.map { root($0) }
        let padRoots = Set(base.pads.indices.map { roots[$0] })
        let zoneModels = Dictionary(uniqueKeysWithValues:copper.zones.map { ($0.id,$0) })
        let removed = Set(primitives.indices.filter { i in
            guard case .zone(let id) = primitives[i].item else { return false }
            return zoneModels[id]?.removeIslands == true && !padRoots.contains(roots[i])
        })
        var zoneFills: [PCBZoneFill] = []
        for zone in copper.zones.sorted(by: { $0.id.uuidString < $1.id.uuidString }) {
            let all = primitives.indices.filter { primitives[$0].item == .zone(zone.id) }
            let kept = all.filter { !removed.contains($0) }
            let cells = kept.map { primitives[$0].core }
            let detail = filled.details[zone.id]!
            let thermals = try PCBZoneThermals.resolve(detail.candidates,cells:cells)
            zoneFills.append(.init(zone:zone,cells:cells,islandCount:Set(kept.map { roots[$0] }).count,
                                  removedIslandCount:Set(all.filter { removed.contains($0) }.map { roots[$0] }).count,
                                  area:cells.map(PCBPolygonFill.area).reduce(0,+),thermals:thermals,removedNarrowArea:detail.removedNarrowArea))
            for thermal in thermals {
                let items: [PCBItem] = [.zone(zone.id),.pad(componentID:thermal.componentID,padID:thermal.padID)]
                if thermal.connectedSpokes < zone.minimumSpokes {
                    add("pcb_thermal_starved","Termica con \(thermal.connectedSpokes) raggi completi, minimo \(zone.minimumSpokes): spostare gli ostacoli o modificare angolo e dimensioni.",items,thermal.position)
                }
                let minimum = max(zone.minimumWidth,rulesByNet[zone.netID]?.minimumTrackWidth ?? copper.rules.minimumTrackWidth)
                if zone.thermalSpokeWidth+PCBGeometry.epsilon < minimum {
                    add("pcb_thermal_width","Ponticelli da \(zone.thermalSpokeWidth) mm, minimo \(minimum) mm: aumentare la larghezza.",items,thermal.position)
                }
            }
            if let point = detail.necks.first, !cells.isEmpty {
                add("pcb_zone_neck","Il piano contiene un collo senza un percorso largo \(zone.minimumWidth) mm: allargare il rame o spostare gli ostacoli.",[.zone(zone.id)],point)
            }
            if cells.isEmpty {
                add("pcb_zone_empty","Piano «\(zone.name)» senza rame: controllare contorno, strato, ostacoli e collegamento a una piazzola della rete.",[.zone(zone.id)],zone.outline[0],severity:.warning)
            }
        }
        for i in primitives.indices where !padRoots.contains(roots[i]) {
            if removed.contains(i) { continue }
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
        let retained = primitives.indices.filter { !removed.contains($0) }.map { primitives[$0] }
        return .init(designID:design.id,revision:revision,layerCount:copper.layerCount,primitives:retained,keepouts:keepouts,zones:zoneFills,
                     board:.init(pads:base.pads,airwires:airwires,unplacedComponents:base.unplacedComponents),issues:issues,
                     index:removed.isEmpty ? index : try PCBIndex(retained),keepoutIndex:keepoutIndex,zoneIndex:try PCBIndex(boxes:zoneFills.map { PCBBox($0.zone.outline) }))
    }
}
