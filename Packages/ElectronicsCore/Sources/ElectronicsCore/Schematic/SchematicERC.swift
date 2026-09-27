import Foundation

extension ElectronicsSchematic {
    static func electricalIssues(_ design: ElectronicsDesign, excluding: Set<UUID>) -> [ElectronicsIssue] {
        guard let schema = design.schematic else { return [] }
        var issues: [ElectronicsIssue] = []
        let placed = Set(schema.sheets.flatMap { $0.symbols.map(\.componentID) })
        var pinsByNet: [UUID: [(PinReference, SymbolPin)]] = [:]
        let connections = Dictionary(uniqueKeysWithValues: design.connections.map { ($0.pin, $0) })
        for component in design.components where !excluding.contains(component.id) {
            if !placed.contains(component.id) {
                var issue = ElectronicsIssue("symbol_not_placed", component.reference, "Simbolo non posizionato nello schema.", severity: .warning)
                issue.subjectIDs = [component.id]; issues.append(issue)
            }
            for pin in definition(component.id, design: design)?.pins ?? [] {
                let reference = PinReference(componentID: component.id,pinID: pin.id)
                if let net = connections[reference]?.netID { pinsByNet[net,default: []].append((reference,pin)) }
            }
        }
        for net in design.nets {
            let pins = pinsByNet[net.id,default: []]
            if pins.count == 1 {
                var issue = ElectronicsIssue("single_pin_net",net.name,"La rete contiene un solo pin: verificare il collegamento.",severity: .warning)
                issue.subjectIDs = [net.id,pins[0].0.componentID,pins[0].0.pinID]; issues.append(issue)
            }
            let driven = pins.contains { [.output,.powerOutput,.bidirectional,.triState,.openDrain,.openCollector,.openEmitter].contains($0.1.electricalType) }
            let powered = pins.contains { $0.1.electricalType == .powerOutput }
            for (ref,pin) in pins {
                if (pin.electricalType == .input && !driven) || (pin.electricalType == .powerInput && !powered) {
                    let power = pin.electricalType == .powerInput
                    var issue = ElectronicsIssue(power ? "undriven_power" : "undriven_input",net.name,
                        power ? "Pin di alimentazione senza sorgente dichiarata: verificare il circuito; un’etichetta non è una sorgente." : "Ingresso senza uscita che piloti la rete: verificare il circuito.",severity: .warning)
                    issue.subjectIDs = [ref.componentID,ref.pinID,net.id]; issues.append(issue)
                }
            }
        }
        for sheet in schema.sheets {
            for j in sheet.junctions {
                let count = sheet.wires.filter { $0.start == .junction(j.id) || $0.end == .junction(j.id) }.count
                let labeled = sheet.labels.contains { $0.terminal == .junction(j.id) }
                if count == 0 || (count == 1 && !labeled) {
                    var issue = ElectronicsIssue("dangling_junction",sheet.name,"Giunzione o estremità di filo senza prosecuzione.",severity: .warning)
                    issue.subjectIDs = [sheet.id,j.id]; issue.position = j.position; issues.append(issue)
                }
            }
        }
        return issues
    }

    static func locatedIssues(_ issues: [ElectronicsIssue], design: ElectronicsDesign) -> [ElectronicsIssue] {
        guard let schema = design.schematic else { return issues }
        return issues.map { issue in
            guard issue.position == nil, let ids = issue.subjectIDs else { return issue }
            for sheet in schema.sheets {
                for instance in sheet.symbols where ids.contains(instance.componentID) {
                    var result = issue
                    if let pin = definition(instance.componentID,design: design)?.pins.first(where: { ids.contains($0.id) }), let local = pin.position {
                        result.position = point(local,symbol: instance)
                    } else { result.position = instance.position }
                    return result
                }
            }
            return issue
        }
    }
}
