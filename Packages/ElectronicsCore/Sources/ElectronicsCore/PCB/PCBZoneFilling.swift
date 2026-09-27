import Foundation

enum PCBZoneFilling {
    static let guardBand = 1e-6 // mm, makes keepout boundaries/drill bores strictly excluded
    static func primitives(design: ElectronicsDesign, copper: [PCBCopperPrimitive], rules: [UUID:PCBDesignRules]) throws -> [PCBCopperPrimitive] {
        let model = design.board.copper ?? .init()
        var result: [PCBCopperPrimitive] = []
        for zone in model.zones.sorted(by: { $0.id.uuidString < $1.id.uuidString }) {
            try Task.checkCancellation()
            let rule = rules[zone.netID] ?? model.rules
            let bounds = PCBBox(zone.outline)
            var obstacles: [[PCBPoint]] = []
            var edgeCount = zone.outline.count + design.board.outline.count
            func append(_ polygon: [PCBPoint]) throws {
                guard PCBBox(polygon).intersects(bounds) else { return }
                edgeCount += polygon.count
                guard edgeCount <= 8_000 else { throw PCBPolygonFill.tooComplex() }
                obstacles.append(polygon)
            }
            func exclude(_ polygon: [PCBPoint], margin: Double) throws {
                guard PCBBox(polygon,margin:margin+0.006).intersects(bounds) else { return }
                try append(polygon)
                for (a,b) in PCBGeometry.edges(polygon) {
                    try append(PCBPolygonFill.expandedConvex([a,b],radius:margin))
                }
            }
            for (a,b) in PCBGeometry.edges(design.board.outline) {
                if PCBBox([a,b],margin:rule.edgeClearance+0.006).intersects(bounds) {
                    try append(PCBPolygonFill.expandedConvex([a,b],radius:rule.edgeClearance+guardBand))
                }
            }
            for p in copper where p.layers.contains(zone.layer) {
                try Task.checkCancellation()
                if p.netID != zone.netID {
                    let clearance = max(rule.clearance,p.netID.flatMap { rules[$0]?.clearance } ?? model.rules.clearance)
                    if PCBBox(p.core,margin:p.radius+clearance+0.006).intersects(bounds) {
                        try append(PCBPolygonFill.expandedConvex(p.core,radius:p.radius+clearance+guardBand))
                    }
                } else if let hole = p.drillDiameter {
                    if PCBBox([p.center],margin:hole/2+0.006).intersects(bounds) {
                        try append(PCBPolygonFill.expandedConvex([p.center],radius:hole/2+guardBand))
                    }
                }
            }
            for keepout in model.keepouts where keepout.zones && keepout.layers.contains(zone.layer) {
                try exclude(keepout.outline,margin:guardBand)
            }
            for other in model.zones where other.netID != zone.netID && other.layer == zone.layer {
                try exclude(other.outline,margin:max(rule.clearance,rules[other.netID]?.clearance ?? model.rules.clearance)+guardBand)
            }
            let cells = try PCBPolygonFill.cells(subject:zone.outline,board:design.board.outline,obstacles:obstacles)
            result += cells.map { .init(item:.zone(zone.id),netID:zone.netID,layers:[zone.layer],core:$0,radius:0) }
            guard result.count <= 30_000 else { throw PCBPolygonFill.tooComplex() }
        }
        return result
    }
}
