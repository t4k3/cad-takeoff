import Foundation

extension ElectronicsPCB {
    static func ruleIntegrity(_ copper: PCBCopper, nets: Set<UUID>) -> [ElectronicsIssue] {
        var issues: [ElectronicsIssue] = []
        func add(_ code: String, _ message: String, _ ids: [UUID]) { issues += failure(code, message, ids).issues }
        var names = Set<String>(), assigned = Set<UUID>()
        for n in copper.netClasses {
            let name = n.name.trimmingCharacters(in: .whitespacesAndNewlines)
            if name.isEmpty || name.count > 128 || !names.insert(name.lowercased()).inserted {
                add("invalid_net_class_name", "Usare nomi di classe distinti e non vuoti, fino a 128 caratteri.", [n.id])
            }
            let c = n.constraints, r = n.routing
            if ![c.clearance,c.minimumTrackWidth,c.minimumDrill,c.minimumAnnularRing].compactMap({ $0 }).allSatisfy({ ElectronicsGeometry.valid($0) && $0 > 0 }) ||
                ![r.trackWidth,r.viaDiameter,r.viaDrill].allSatisfy({ ElectronicsGeometry.valid($0) && $0 > 0 }) || r.viaDiameter <= r.viaDrill {
                add("invalid_net_class_rules", "Minimi e dimensioni della classe devono essere positivi e finiti, con diametro via maggiore del foro.", [n.id])
            }
            let effective = resolve(copper.rules, netClass:n)
            if ![effective.routing.trackWidth,effective.routing.viaDrill,effective.routing.viaDiameter].allSatisfy(ElectronicsGeometry.valid) {
                add("invalid_net_class_rules", "Le dimensioni risolte della classe superano il campo supportato.", [n.id])
            }
            if !Set(n.netIDs).isSubset(of:nets) { add("dangling_class_net", "La classe riferisce una rete inesistente.", [n.id]+n.netIDs.filter { !nets.contains($0) }) }
            for net in n.netIDs where !assigned.insert(net).inserted { add("ambiguous_net_class", "Ogni rete può comparire una sola volta e in una sola classe.", [n.id,net]) }
        }
        for k in copper.keepouts {
            if k.name.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty || k.name.count > 128 ||
                k.outline.count > 1024 || !ElectronicsGeometry.simplePolygon(k.outline) {
                add("invalid_keepout", "Area vietata: indicare un nome e un contorno semplice, non degenere, con 3–1024 vertici.", [k.id])
            }
            if k.layers.isEmpty || Set(k.layers).count != k.layers.count || k.layers.contains(where: { $0 < 0 || $0 >= copper.layerCount }) {
                add("invalid_keepout_layers", "Scegliere almeno uno strato esistente, senza duplicati.", [k.id])
            }
            if !k.tracks && !k.vias && !k.pads { add("empty_keepout_rules", "Vietare almeno un tipo di oggetto: piste, via o piazzole.", [k.id]) }
        }
        return issues
    }
}
