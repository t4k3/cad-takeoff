import Foundation

/// Commands carry concrete identities: a preview and its confirmation must reuse the same value.
public enum ElectronicsCommand: Codable, Equatable, Sendable {
    case library(ElectronicsLibraryCommand)
    case addComponent(component: CircuitComponent, placement: ComponentPlacement, library: ElectronicsLibrary)
    case updateComponent(CircuitComponent)
    case removeComponent(UUID)
    case moveComponent(id: UUID, to: PCBPoint)
    case rotateComponent(id: UUID, by: Double)
    case setComponentSide(id: UUID, side: BoardSide)
    case flipComponent(UUID)
    case setBoard(outline: [PCBPoint], thickness: Double, assemblyOrigin: PCBPoint)
    case addNet(CircuitNet)
    case renameNet(id: UUID, name: String)
    case removeNet(UUID)
    case connect(pins: [PinReference], net: CircuitNet)
    case disconnect([PinReference])
    case markNoConnect([PinReference])

    public var title: String {
        switch self {
        case .library(let command): command.title
        case .addComponent: "Inserisci componente"
        case .updateComponent: "Modifica componente"
        case .removeComponent: "Elimina componente"
        case .moveComponent: "Sposta componente"
        case .rotateComponent: "Ruota componente"
        case .setComponentSide, .flipComponent: "Cambia lato"
        case .setBoard: "Modifica scheda"
        case .addNet: "Crea rete"
        case .renameNet: "Rinomina rete"
        case .removeNet: "Elimina rete"
        case .connect: "Collega pin"
        case .disconnect: "Scollega pin"
        case .markNoConnect: "Segna pin non collegato"
        }
    }
}

public struct ElectronicsCommandPreview: Sendable {
    public let baseRevision: UInt64
    public let design: ElectronicsDesign
    public let board: BoardConnectivity
    public let issues: [ElectronicsIssue]
}

public struct ElectronicsPin: Equatable, Sendable {
    public let reference: PinReference
    public let number: String
    public let name: String
    public let electricalType: PinElectricalType
    public let netID: UUID?
    public let explicitlyUnconnected: Bool
}

extension ElectronicsDocument {
    public static func empty(name: String = "Nuovo circuito",
                             outline: [PCBPoint] = [.init(0,0), .init(50,0), .init(50,30), .init(0,30)]) throws -> Self {
        try .init(design: .init(name: name, library: .init(), board: .init(outline: outline)))
    }
}

public enum ElectronicsCommands {
    public static func preview(_ command: ElectronicsCommand, document: ElectronicsDocument,
                               expectedRevision: UInt64) throws -> ElectronicsCommandPreview {
        var candidate = document
        try apply(command, to: &candidate, expectedRevision: expectedRevision)
        let importIssues: [ElectronicsIssue]
        if case .library(.importLibrary(let bundle)) = command { importIssues = bundle.issues } else { importIssues = [] }
        return try .init(baseRevision: document.revision, design: candidate.design,
                         board: ElectronicsConnectivity.snapshot(candidate.design),
                         issues: importIssues + ElectronicsValidation.electrical(candidate.design) + genericIssues(candidate.design))
    }

    /// Mutates only through the document transaction. Invalid commands, missing subjects or
    /// revision mismatches leave library, circuit, board and persistent history untouched.
    public static func apply(_ command: ElectronicsCommand, to document: inout ElectronicsDocument,
                             expectedRevision: UInt64) throws {
        if case .library(let library) = command {
            try ElectronicsLibraryCommands.apply(library, to: &document, expectedRevision: expectedRevision)
            return
        }
        try document.edit(title: command.title, expectedRevision: expectedRevision) { design in
            switch command {
            case .library: break // Dispatched above, preserving exactly one transaction.
            case let .addComponent(component, placement, library):
                guard placement.componentID == component.id else {
                    throw failure("placement_component_mismatch", "Il posizionamento appartiene a un altro componente.", [component.id, placement.componentID])
                }
                guard !design.components.contains(where: { $0.id == component.id }) else {
                    throw failure("component_exists", "Componente già presente: scegliere un’identità nuova.", [component.id])
                }
                try merge(library.symbols, into: &design.library.symbols, key: \.key)
                try merge(library.footprints, into: &design.library.footprints, key: \.key)
                try merge(library.devices, into: &design.library.devices, key: \.key)
                design.components.append(component)
                design.board.placements.append(placement)
            case .updateComponent(let component):
                let index = try componentIndex(component.id, in: design)
                // A device change with stale pin references is refused by integrity validation.
                design.components[index] = component
            case .removeComponent(let id):
                let index = try componentIndex(id, in: design)
                design.components.remove(at: index)
                design.board.placements.removeAll { $0.componentID == id }
                design.connections.removeAll { $0.pin.componentID == id }
                for i in design.variants.indices { design.variants[i].excludedComponents.removeAll { $0 == id } }
            case let .moveComponent(id, point):
                let index = try placementIndex(id, in: design)
                design.board.placements[index].position = point
            case let .rotateComponent(id, degrees):
                let index = try placementIndex(id, in: design)
                guard ElectronicsGeometry.validAngle(degrees) else {
                    throw failure("invalid_rotation", "Angolo non valido: inserire un numero finito in gradi.", [id])
                }
                design.board.placements[index].rotationDegrees = ElectronicsGeometry.normalizedDegrees(design.board.placements[index].rotationDegrees + degrees)
            case let .setComponentSide(id, side):
                let index = try placementIndex(id, in: design)
                design.board.placements[index].side = side
            case .flipComponent(let id):
                let index = try placementIndex(id, in: design)
                design.board.placements[index].side = design.board.placements[index].side == .top ? .bottom : .top
            case let .setBoard(outline, thickness, origin):
                design.board.outline = outline; design.board.thickness = thickness; design.board.assemblyOrigin = origin
            case .addNet(let net):
                guard !design.nets.contains(where: { $0.id == net.id }) else {
                    throw failure("net_exists", "Rete già presente: selezionarla oppure crearne una nuova.", [net.id])
                }
                design.nets.append(net)
            case let .renameNet(id, name):
                let index = try netIndex(id, in: design)
                design.nets[index].name = name
            case .removeNet(let id):
                let index = try netIndex(id, in: design)
                design.nets.remove(at: index)
                design.connections.removeAll { $0.netID == id }
            case let .connect(pins, net):
                try requirePins(pins, in: design)
                if let existing = design.nets.first(where: { $0.id == net.id }) {
                    guard existing == net else { throw failure("net_definition_conflict", "La rete è cambiata: rileggere nome e identità prima di collegare.", [net.id]) }
                } else { design.nets.append(net) }
                for pin in pins {
                    if let existing = design.connections.first(where: { $0.pin == pin }), let oldNet = existing.netID, oldNet != net.id {
                        throw failure("pin_already_connected", "Pin già collegato a un’altra rete: scollegarlo esplicitamente prima di riassegnarlo.", [pin.componentID, pin.pinID, oldNet, net.id])
                    }
                }
                replaceConnections(pins, netID: net.id, in: &design)
            case .disconnect(let pins):
                try requirePins(pins, in: design)
                let selected = Set(pins)
                design.connections.removeAll { selected.contains($0.pin) }
            case .markNoConnect(let pins):
                try requirePins(pins, in: design)
                guard !design.connections.contains(where: { pins.contains($0.pin) && $0.netID != nil }) else {
                    throw failure("connected_pin_nc", "Un pin collegato non può diventare NC implicitamente: scollegarlo prima.", pins.flatMap { [$0.componentID, $0.pinID] })
                }
                replaceConnections(pins, netID: nil, in: &design)
            }
        }
    }

    public static func nextReference(prefix: String, in design: ElectronicsDesign) -> String {
        let safePrefix = prefix.matches("^[A-Za-z][A-Za-z0-9_]*$") ? prefix : "U"
        let used = Set(design.components.map { $0.reference.uppercased() })
        var next = 1
        while used.contains((safePrefix + String(next)).uppercased()) { next += 1 }
        return safePrefix + String(next)
    }

    public static func pins(of componentID: UUID, in design: ElectronicsDesign) throws -> [ElectronicsPin] {
        let component = design.components[try componentIndex(componentID, in: design)]
        guard let device = design.library.devices.first(where: { $0.key == component.device }),
              let symbol = design.library.symbols.first(where: { $0.key == device.symbol }) else {
            throw failure("missing_device_revision", "Libreria del componente incompleta: importare la revisione richiesta.", [componentID])
        }
        return symbol.pins.map { pin in
            let reference = PinReference(componentID: componentID, pinID: pin.id)
            let connection = design.connections.first { $0.pin == reference }
            return .init(reference: reference, number: pin.number ?? pin.name, name: pin.name, electricalType: pin.electricalType,
                         netID: connection?.netID, explicitlyUnconnected: connection != nil && connection?.netID == nil)
        }
    }

    /// Generic templates are usable design data, but not qualified manufacturer parts.
    public static func genericIssues(_ design: ElectronicsDesign) -> [ElectronicsIssue] {
        design.components.compactMap { component in
            guard let device = design.library.devices.first(where: { $0.key == component.device }),
                  let footprint = design.library.footprints.first(where: { $0.key == device.footprint }),
                  footprint.properties?["qualification"] == "generic-unverified" else { return nil }
            var issue = ElectronicsIssue("generic_component", component.reference, "Componente generico: verificare impronta e piedinatura sul datasheet prima della produzione.", severity: .warning)
            issue.subjectIDs = [component.id]; return issue
        }
    }

    private static func componentIndex(_ id: UUID, in design: ElectronicsDesign) throws -> Int {
        guard let i = design.components.firstIndex(where: { $0.id == id }) else {
            throw failure("component_missing", "Componente non più presente: aggiornare la selezione.", [id])
        }; return i
    }
    private static func placementIndex(_ id: UUID, in design: ElectronicsDesign) throws -> Int {
        _ = try componentIndex(id, in: design)
        guard let i = design.board.placements.firstIndex(where: { $0.componentID == id }) else {
            throw failure("placement_missing", "Il componente non è posizionato sulla scheda.", [id])
        }; return i
    }
    private static func netIndex(_ id: UUID, in design: ElectronicsDesign) throws -> Int {
        guard let i = design.nets.firstIndex(where: { $0.id == id }) else {
            throw failure("net_missing", "Rete non più presente: aggiornare la selezione.", [id])
        }; return i
    }
    private static func requirePins(_ pins: [PinReference], in design: ElectronicsDesign) throws {
        guard !pins.isEmpty, Set(pins).count == pins.count else {
            throw failure("invalid_pin_selection", "Selezionare pin distinti da collegare o scollegare.", pins.flatMap { [$0.componentID, $0.pinID] })
        }
        for pin in pins {
            guard try self.pins(of: pin.componentID, in: design).contains(where: { $0.reference == pin }) else {
                throw failure("pin_missing", "Pin non più presente: aggiornare la selezione.", [pin.componentID, pin.pinID])
            }
        }
    }
    private static func replaceConnections(_ pins: [PinReference], netID: UUID?, in design: inout ElectronicsDesign) {
        // Updating in place keeps a repeated command a true no-op, including array ordering.
        for pin in pins {
            if let index = design.connections.firstIndex(where: { $0.pin == pin }) {
                design.connections[index].netID = netID
            } else { design.connections.append(.init(pin: pin, netID: netID)) }
        }
    }
    private static func merge<T: Equatable>(_ items: [T], into target: inout [T], key: KeyPath<T, LibraryRevision>) throws {
        for item in items {
            if let previous = target.first(where: { $0[keyPath: key] == item[keyPath: key] }) {
                guard previous == item else { throw failure("library_revision_conflict", "Revisione di libreria diversa da quella già presente: aggiornare esplicitamente la libreria.", [item[keyPath: key].id]) }
            } else { target.append(item) }
        }
    }
    private static func failure(_ code: String, _ message: String, _ ids: [UUID]) -> ElectronicsFailure {
        var issue = ElectronicsIssue(code, "Circuiti", message); issue.subjectIDs = ids
        return ElectronicsFailure([issue])
    }
}
