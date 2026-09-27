import Foundation

extension ElectronicsSchematic {
    static func mutate(_ command: SchematicCommand, design: inout ElectronicsDesign, depth: Int = 0) throws {
        guard depth < 16 else { throw error("schematic_batch_depth", "Troppe modifiche annidate: suddividere il comando.", []) }
        if design.schematic == nil { design.schematic = .init(directConnections: design.connections) }
        if case .batch(let commands) = command {
            guard commands.count <= 1000 else { throw error("schematic_batch_size", "Troppe modifiche: suddividere il comando.", []) }
            for child in commands { try mutate(child, design: &design, depth: depth + 1) }
            return
        }
        var schema = design.schematic!
        func sheetIndex(_ id: UUID) throws -> Int {
            guard let i = schema.sheets.firstIndex(where: { $0.id == id }) else { throw error("sheet_missing", "Foglio assente: aggiornare la selezione.", [id]) }
            return i
        }
        func symbolIndex(_ id: UUID) throws -> (Int, Int) {
            for (s, sheet) in schema.sheets.enumerated() {
                if let i = sheet.symbols.firstIndex(where: { $0.componentID == id }) { return (s, i) }
            }
            throw error("symbol_missing", "Simbolo assente: posizionarlo sul foglio.", [id])
        }
        func wireIndex(_ id: UUID) throws -> (Int, Int) {
            for (s, sheet) in schema.sheets.enumerated() {
                if let i = sheet.wires.firstIndex(where: { $0.id == id }) { return (s, i) }
            }
            throw error("wire_missing", "Filo assente: aggiornare la selezione.", [id])
        }
        func junctionIndex(_ id: UUID) throws -> (Int, Int) {
            for (s, sheet) in schema.sheets.enumerated() {
                if let i = sheet.junctions.firstIndex(where: { $0.id == id }) { return (s, i) }
            }
            throw error("junction_missing", "Giunzione assente: aggiornare la selezione.", [id])
        }
        switch command {
        case .addSheet(let sheet): schema.sheets.append(sheet)
        case let .renameSheet(id, name): schema.sheets[try sheetIndex(id)].name = name
        case .removeSheet(let id):
            let i = try sheetIndex(id)
            guard !schema.sheets.contains(where: { $0.parentID == id }) else {
                throw error("sheet_has_children", "Il foglio contiene sottofogli: spostarli o rimuoverli prima.", [id])
            }
            schema.sheets.remove(at: i)
        case let .placeSymbol(sheetID, symbol): schema.sheets[try sheetIndex(sheetID)].symbols.append(symbol)
        case let .moveSymbol(id, point):
            let (s, i) = try symbolIndex(id); schema.sheets[s].symbols[i].position = point
        case let .rotateSymbol(id, degrees):
            guard ElectronicsGeometry.validAngle(degrees) else { throw error("invalid_rotation", "Angolo non valido.", [id]) }
            let (s, i) = try symbolIndex(id)
            schema.sheets[s].symbols[i].rotationDegrees = ElectronicsGeometry.normalizedDegrees(schema.sheets[s].symbols[i].rotationDegrees + degrees)
        case .mirrorSymbol(let id):
            let (s, i) = try symbolIndex(id); schema.sheets[s].symbols[i].mirrored.toggle()
        case .removeSymbol(let id):
            _ = try symbolIndex(id); removeSymbols([id], from: &schema)
        case let .addJunction(sheetID, junction): schema.sheets[try sheetIndex(sheetID)].junctions.append(junction)
        case let .moveJunction(id, point):
            let (s, i) = try junctionIndex(id); schema.sheets[s].junctions[i].position = point
        case .removeJunction(let id):
            let (s, i) = try junctionIndex(id)
            schema.sheets[s].junctions.remove(at: i)
            schema.sheets[s].wires.removeAll { $0.start == .junction(id) || $0.end == .junction(id) }
            schema.sheets[s].labels.removeAll { $0.terminal == .junction(id) }
        case let .addWire(sheetID, wire): schema.sheets[try sheetIndex(sheetID)].wires.append(wire)
        case let .setWireBends(id, bends):
            let (s, i) = try wireIndex(id); schema.sheets[s].wires[i].bends = bends
        case .removeWire(let id):
            let (s, i) = try wireIndex(id); schema.sheets[s].wires.remove(at: i)
        case let .splitWire(id, junction, newID):
            let (s, i) = try wireIndex(id), old = schema.sheets[s].wires[i]
            let points = try wirePoints(old, sheet: schema.sheets[s], design: design)
            guard newID != id, distance(junction.position, points.first!) > 1e-7,
                  distance(junction.position, points.last!) > 1e-7,
                  let segment = (0..<(points.count-1)).first(where: { segmentDistance(junction.position, points[$0], points[$0+1]).distance <= 1e-7 }) else {
                throw error("split_point_not_on_wire", "Posizionare la giunzione lungo il filo, lontano dai suoi estremi.", [id, junction.id], at: junction.position)
            }
            if let existing = schema.sheets[s].junctions.first(where: { $0.id == junction.id }) {
                guard existing == junction else { throw error("junction_conflict", "La giunzione esistente ha una posizione diversa.", [junction.id]) }
            } else { schema.sheets[s].junctions.append(junction) }
            let firstBends = Array(points[1..<(segment+1)]).filter { distance($0, junction.position) > 1e-7 }
            let secondBends = Array(points[(segment+1)..<(points.count-1)]).filter { distance($0, junction.position) > 1e-7 }
            schema.sheets[s].wires[i] = .init(id: id, start: old.start, end: .junction(junction.id), bends: firstBends)
            schema.sheets[s].wires.append(.init(id: newID, start: .junction(junction.id), end: old.end, bends: secondBends))
            if let binding = schema.wireNets.first(where: { $0.wireID == id }) { schema.wireNets.append(.init(wireID: newID, netID: binding.netID)) }
        case let .addLabel(sheetID, label, net):
            guard label.netID == net.id else { throw error("label_net_mismatch", "Etichetta e rete hanno identità diverse.", [label.id, net.id]) }
            if let old = design.nets.first(where: { $0.id == net.id }) {
                guard old == net else { throw error("net_definition_conflict", "La rete è cambiata: rileggere prima di aggiungere l’etichetta.", [net.id]) }
            } else { design.nets.append(net) }
            schema.sheets[try sheetIndex(sheetID)].labels.append(label)
        case .removeLabel(let id):
            guard let s = schema.sheets.firstIndex(where: { $0.labels.contains { $0.id == id } }) else { throw error("label_missing", "Etichetta assente.", [id]) }
            schema.sheets[s].labels.removeAll { $0.id == id }
        case .batch: break
        }
        design.schematic = schema
    }

    static func removeSymbols(_ ids: Set<UUID>, from schema: inout SchematicCircuit) {
        func affected(_ terminal: SchematicTerminal) -> Bool {
            if case .pin(let pin) = terminal { return ids.contains(pin.componentID) }; return false
        }
        for s in schema.sheets.indices {
            schema.sheets[s].symbols.removeAll { ids.contains($0.componentID) }
            schema.sheets[s].wires.removeAll { affected($0.start) || affected($0.end) }
            schema.sheets[s].labels.removeAll { affected($0.terminal) }
        }
    }
}

extension ElectronicsDesign {
    /// Commands edit the independent netlist; reconcile overlays schematic connectivity afterward.
    var directConnections: [PinConnection] {
        get { schematic?.directConnections ?? connections }
        set { if schematic != nil { schematic!.directConnections = newValue } else { connections = newValue } }
    }
}
