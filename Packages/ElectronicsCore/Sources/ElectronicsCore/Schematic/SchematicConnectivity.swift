import Foundation

public enum ElectronicsSchematic {
    public static func point(_ local: PCBPoint, symbol: SchematicSymbol) -> PCBPoint {
        let a = ElectronicsGeometry.normalizedDegrees(symbol.rotationDegrees) * .pi / 180
        let x = symbol.mirrored ? -local.x : local.x
        return .init(symbol.position.x + cos(a) * x - sin(a) * local.y,
                     symbol.position.y + sin(a) * x + cos(a) * local.y)
    }

    public static func terminalPosition(_ terminal: SchematicTerminal, sheet: SchematicSheet,
                                        design: ElectronicsDesign) throws -> PCBPoint {
        switch terminal {
        case .junction(let id):
            guard let j = sheet.junctions.first(where: { $0.id == id }) else {
                throw error("missing_junction", "Giunzione assente dal foglio: aggiornare il collegamento.", [sheet.id, id])
            }
            return j.position
        case .pin(let reference):
            guard let instance = sheet.symbols.first(where: { $0.componentID == reference.componentID }),
                  let definition = definition(reference.componentID, design: design),
                  let pin = definition.pins.first(where: { $0.id == reference.pinID }), let p = pin.position else {
                throw error("missing_schematic_pin", "Pin assente o privo di posizione: posizionare il simbolo con una libreria geometrica valida.", [sheet.id] + terminal.subjectIDs)
            }
            return point(p, symbol: instance)
        }
    }

    public static func wirePoints(_ wire: SchematicWire, sheet: SchematicSheet,
                                  design: ElectronicsDesign) throws -> [PCBPoint] {
        try [terminalPosition(wire.start, sheet: sheet, design: design)] + wire.bends +
            [terminalPosition(wire.end, sheet: sheet, design: design)]
    }

    static func definition(_ componentID: UUID, design: ElectronicsDesign) -> SymbolDefinition? {
        guard let c = design.components.first(where: { $0.id == componentID }),
              let d = design.library.devices.first(where: { $0.key == c.device }) else { return nil }
        return design.library.symbols.first { $0.key == d.symbol }
    }

    static func error(_ code: String, _ message: String, _ ids: [UUID], at position: PCBPoint? = nil) -> ElectronicsFailure {
        var issue = ElectronicsIssue(code, "Schema", message)
        issue.subjectIDs = ids; issue.position = position
        return ElectronicsFailure([issue])
    }

    /// Validates the drawing without consulting its cached net projection. Never traps on bad files.
    static func requireStructure(_ design: ElectronicsDesign, _ schematic: SchematicCircuit) throws {
        func unique<T: Hashable>(_ ids: [T], _ subject: [UUID]) throws {
            guard Set(ids).count == ids.count else { throw error("duplicate_schematic_identity", "Identità dello schema duplicate: correggere il documento.", subject) }
        }
        let sheets = schematic.sheets
        try unique(sheets.map(\.id), sheets.map(\.id))
        try unique(sheets.flatMap { $0.symbols.map(\.componentID) }, [])
        let allIDs = sheets.flatMap { [$0.id] + $0.junctions.map(\.id) + $0.wires.map(\.id) + $0.labels.map(\.id) }
        try unique(allIDs, [])
        try unique(schematic.directConnections.map(\.pin), [])
        try unique(schematic.wireNets.map(\.wireID), [])
        try unique(schematic.generatedNetIDs, [])
        try unique(schematic.namedNetIDs, [])
        let netIDs = Set(design.nets.map(\.id))
        guard Set(schematic.namedNetIDs).isSubset(of: netIDs) else { throw error("missing_named_net", "Rete nominata assente.", schematic.namedNetIDs) }
        for c in schematic.directConnections {
            guard let symbol = definition(c.pin.componentID, design: design), symbol.pins.contains(where: { $0.id == c.pin.pinID }),
                  c.netID.map(netIDs.contains) ?? true else {
                throw error("invalid_direct_connection", "Collegamento logico indipendente non valido: controllare pin e rete.", [c.pin.componentID, c.pin.pinID])
            }
        }
        for sheet in sheets {
            guard !sheet.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw error("missing_sheet_name", "Dare un nome al foglio.", [sheet.id])
            }
            var seen: Set<UUID> = [sheet.id]; var parent = sheet.parentID
            while let id = parent {
                guard seen.insert(id).inserted, let ancestor = sheets.first(where: { $0.id == id }) else {
                    throw error("invalid_sheet_hierarchy", "Gerarchia dei fogli circolare o incompleta.", [sheet.id, id])
                }
                parent = ancestor.parentID
            }
            for instance in sheet.symbols {
                guard ElectronicsGeometry.valid(instance.position), ElectronicsGeometry.validAngle(instance.rotationDegrees),
                      let symbol = definition(instance.componentID, design: design),
                      !symbol.pins.isEmpty, symbol.pins.allSatisfy({ $0.position.map(ElectronicsGeometry.valid) == true }) else {
                    throw error("invalid_schematic_symbol", "Simbolo o posizione non validi: importare una libreria con posizioni dei pin.", [sheet.id, instance.componentID])
                }
            }
            for j in sheet.junctions where !ElectronicsGeometry.valid(j.position) {
                throw error("invalid_junction", "Posizione della giunzione non valida.", [sheet.id, j.id])
            }
            for wire in sheet.wires {
                guard wire.start != wire.end, wire.bends.count <= 10_000 else {
                    throw error("invalid_wire", "Un filo deve collegare due terminali distinti con un percorso valido.", [sheet.id, wire.id])
                }
                let points = try wirePoints(wire, sheet: sheet, design: design)
                guard points.allSatisfy(ElectronicsGeometry.valid), zip(points, points.dropFirst()).contains(where: { distance($0, $1) > 1e-8 }) else {
                    throw error("invalid_wire_geometry", "Il filo ha lunghezza nulla o coordinate non valide.", [sheet.id, wire.id])
                }
            }
            for label in sheet.labels {
                guard netIDs.contains(label.netID), ElectronicsGeometry.valid(label.offset) else {
                    throw error("invalid_label", "Etichetta senza rete o con posizione non valida.", [sheet.id, label.id, label.netID])
                }
                _ = try terminalPosition(label.terminal, sheet: sheet, design: design)
            }
        }
    }

    /// Rebuilds electrical connectivity from explicit graph edges; old auto-net IDs are retained
    /// where possible. Splits receive a new deterministic identity, independent of preview order.
    static func reconcile(_ design: inout ElectronicsDesign) throws {
        guard var schematic = design.schematic else { return }
        try requireStructure(design, schematic)
        var parent: [SchematicTerminal: SchematicTerminal] = [:]
        func root(_ t: SchematicTerminal) -> SchematicTerminal {
            var r = t
            while let p = parent[r], p != r { r = p }
            var q = t
            while let p = parent[q], p != q { parent[q] = r; q = p }
            return r
        }
        func insert(_ t: SchematicTerminal) { if parent[t] == nil { parent[t] = t } }
        let wires = schematic.sheets.flatMap(\.wires).sorted { $0.id.uuidString < $1.id.uuidString }
        let labels = schematic.sheets.flatMap(\.labels)
        for wire in wires {
            insert(wire.start); insert(wire.end)
            let a = root(wire.start), b = root(wire.end)
            if a != b { if a.sortKey < b.sortKey { parent[b] = a } else { parent[a] = b } }
        }
        for label in labels { insert(label.terminal) }
        var groups: [SchematicTerminal: [SchematicTerminal]] = [:]
        for t in Array(parent.keys) { groups[root(t), default: []].append(t) }
        var groupWires: [SchematicTerminal: [SchematicWire]] = [:]
        for wire in wires { groupWires[root(wire.start), default: []].append(wire) }
        var groupLabels: [SchematicTerminal: [SchematicLabel]] = [:]
        for label in labels { groupLabels[root(label.terminal), default: []].append(label) }
        let oldMapping = Dictionary(uniqueKeysWithValues: schematic.wireNets.map { ($0.wireID, $0.netID) })
        let oldGenerated = Set(schematic.generatedNetIDs)
        var connections = Dictionary(uniqueKeysWithValues: schematic.directConnections.map { ($0.pin, $0) })
        var mapping: [SchematicWireNet] = [], generated: Set<UUID> = [], used: Set<UUID> = []
        // Groups with labels/direct bindings go first, so their explicitly chosen IDs win.
        func hardNets(_ terminals: [SchematicTerminal], _ group: SchematicTerminal) -> Set<UUID> {
            var result = Set(groupLabels[group, default: []].map(\.netID))
            result.formUnion(groupWires[group, default: []].compactMap { oldMapping[$0.id] }.filter { schematic.namedNetIDs.contains($0) })
            for t in terminals { if case .pin(let p) = t, let n = connections[p]?.netID { result.insert(n) } }
            return result
        }
        let ordered = groups.keys.sorted { a, b in
            let ah = !hardNets(groups[a]!, a).isEmpty, bh = !hardNets(groups[b]!, b).isEmpty
            return ah != bh ? ah : a.sortKey < b.sortKey
        }
        for group in ordered {
            let terminals = groups[group]!.sorted { $0.sortKey < $1.sortKey }
            let members = groupWires[group, default: []]
            let hard = hardNets(terminals, group)
            guard hard.count <= 1 else {
                throw error("schematic_net_conflict", "Il filo unisce reti nominate diverse: correggere le etichette o i collegamenti logici prima di unirle.",
                            terminals.flatMap(\.subjectIDs) + hard.sorted { $0.uuidString < $1.uuidString })
            }
            let candidates = Set(members.compactMap { oldMapping[$0.id] }).intersection(oldGenerated).subtracting(used)
            let netID: UUID
            if let explicit = hard.first { netID = explicit }
            else if let existing = candidates.sorted(by: { $0.uuidString < $1.uuidString }).first, design.nets.contains(where: { $0.id == existing }) { netID = existing; generated.insert(existing) }
            else {
                let seed = members.first?.id.uuidString ?? group.sortKey
                var counter = 0
                var id = LibraryImportSupport.id(design.id, "schematic/net/\(seed)/\(counter)")
                while used.contains(id) || (design.nets.contains(where: { $0.id == id }) && !oldGenerated.contains(id)) {
                    counter += 1; id = LibraryImportSupport.id(design.id, "schematic/net/\(seed)/\(counter)")
                }
                netID = id; generated.insert(id)
                if !design.nets.contains(where: { $0.id == id }) {
                    let names = Set(design.nets.map(\.name)); var i = 1
                    while names.contains("N\(i)") { i += 1 }
                    design.nets.append(.init(id: id, name: "N\(i)"))
                }
            }
            if oldGenerated.contains(netID) { generated.insert(netID) }
            used.insert(netID)
            mapping += members.map { .init(wireID: $0.id, netID: netID) }
            for terminal in terminals {
                guard case .pin(let pin) = terminal else { continue }
                if let existing = connections[pin], existing.netID == nil {
                    throw error("schematic_nc_conflict", "Pin marcato NC: rimuovere esplicitamente il marcatore prima di disegnare il filo.", [pin.componentID, pin.pinID])
                }
                connections[pin] = .init(pin: pin, netID: netID)
            }
        }
        let explicitlyUsed = Set(schematic.directConnections.compactMap(\.netID) + labels.map(\.netID) + schematic.namedNetIDs)
        design.nets.removeAll { oldGenerated.contains($0.id) && !used.contains($0.id) && !explicitlyUsed.contains($0.id) }
        generated.formUnion(oldGenerated.intersection(explicitlyUsed))
        schematic.generatedNetIDs = generated.sorted { $0.uuidString < $1.uuidString }
        schematic.wireNets = mapping.sorted { $0.wireID.uuidString < $1.wireID.uuidString }
        design.schematic = schematic
        design.connections = connections.values.sorted { SchematicTerminal.pin($0.pin).sortKey < SchematicTerminal.pin($1.pin).sortKey }
    }

    static func integrity(_ design: ElectronicsDesign) -> [ElectronicsIssue] {
        guard let schema = design.schematic else { return [] }
        do {
            try requireStructure(design, schema)
            var rebuilt = design; try reconcile(&rebuilt)
            guard rebuilt.connections == design.connections, rebuilt.nets == design.nets,
                  rebuilt.schematic == schema else {
                throw error("stale_schematic_connectivity", "Le connessioni salvate non corrispondono allo schema: ricostruire tramite i comandi del motore.", [])
            }
            return []
        } catch let failure as ElectronicsFailure { return failure.issues }
        catch { return [.init("invalid_schematic", "Schema", "Schema non valido.")] }
    }

    static func distance(_ a: PCBPoint, _ b: PCBPoint) -> Double { hypot(a.x - b.x, a.y - b.y) }
    static func segmentDistance(_ p: PCBPoint, _ a: PCBPoint, _ b: PCBPoint) -> (distance: Double, point: PCBPoint) {
        let dx = b.x-a.x, dy = b.y-a.y, square = dx*dx + dy*dy
        let t = square == 0 ? 0 : max(0, min(1, ((p.x-a.x)*dx + (p.y-a.y)*dy)/square))
        let q = PCBPoint(a.x + t*dx, a.y + t*dy)
        return (distance(p,q), q)
    }
}
