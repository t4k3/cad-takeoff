import Foundation

/// Native snapshots, usable for a before/after preview without reconstructing geometry in the UI.
public enum LibraryDefinition: Codable, Equatable, Sendable {
    case symbol(SymbolDefinition)
    case footprint(FootprintDefinition)
    case device(DeviceDefinition)

    public enum Kind: String, Codable, Hashable, Sendable { case symbol, footprint, device }
    public var kind: Kind {
        switch self { case .symbol: .symbol; case .footprint: .footprint; case .device: .device }
    }
    public var key: LibraryRevision {
        switch self { case .symbol(let v): v.key; case .footprint(let v): v.key; case .device(let v): v.key }
    }
}

public struct LibraryEntityChange<Value: Codable & Equatable & Sendable>: Codable, Equatable, Sendable {
    public let id: UUID
    public let before: Value?
    public let after: Value?
    public enum Kind: String, Codable, Sendable { case added, removed, modified }
    public var kind: Kind { before == nil ? .added : (after == nil ? .removed : .modified) }
}

public enum LibraryChangedField: String, Codable, Sendable {
    case definition, name, source, properties, pins, pads, graphics, assemblyCentroid, model3D
    case manufacturer, manufacturerPartNumber, symbol, footprint, pinMap, supplier
}

/// One explicit comparison with one existing revision. Several pinned revisions produce several
/// reports: a component using revision 1 is never described with a diff from revision 2.
public struct LibraryRevisionDiff: Codable, Equatable, Sendable {
    public let before: LibraryDefinition?
    public let after: LibraryDefinition
    public let changedFields: [LibraryChangedField]
    public let pins: [LibraryEntityChange<SymbolPin>]
    public let pads: [LibraryEntityChange<FootprintPad>]
    public let graphics: [LibraryEntityChange<LibraryGraphic>]
    /// Existing components pinned directly or through their device to exactly `before.key`.
    /// This is review impact, not a list of components changed by importing the new revision.
    public let affectedComponentIDs: [UUID]
    public var isOlderRevision: Bool { before.map { after.key.revision < $0.key.revision } ?? false }
}

/// Pure comparison of an append-only library proposal. It does not authorize replacement,
/// infer electrical equivalence, update pins/nets/copper, or read files/network/the clock.
public enum ElectronicsLibraryComparison {
    private struct Identity: Hashable {
        let kind: LibraryDefinition.Kind
        let key: LibraryRevision
    }
    private struct Family: Hashable {
        let kind: LibraryDefinition.Kind
        let id: UUID
    }
    public static func compare(current: ElectronicsDesign, proposedLibrary: ElectronicsLibrary) throws -> [LibraryRevisionDiff] {
        try Task.checkCancellation()
        try ElectronicsValidation.requireIntegrity(current)
        var proposed = current; proposed.library = proposedLibrary
        try ElectronicsValidation.requireIntegrity(proposed)
        let old = definitions(current.library), new = definitions(proposedLibrary)
        let oldIndex = Dictionary(uniqueKeysWithValues: old.map { (Identity(kind: $0.kind, key: $0.key), $0) })
        let newIndex = Dictionary(uniqueKeysWithValues: new.map { (Identity(kind: $0.kind, key: $0.key), $0) })
        let families = Dictionary(grouping: old, by: { Family(kind: $0.kind, id: $0.key.id) })
        let devices = Dictionary(uniqueKeysWithValues: current.library.devices.map { ($0.key, $0) })
        var usage: [Identity: [UUID]] = [:]
        for component in current.components {
            try Task.checkCancellation()
            guard let device = devices[component.device] else { continue } // Integrity checked above.
            usage[.init(kind: .device, key: device.key), default: []].append(component.id)
            usage[.init(kind: .symbol, key: device.symbol), default: []].append(component.id)
            usage[.init(kind: .footprint, key: device.footprint), default: []].append(component.id)
        }
        // An identity/revision remains immutable, including revisions currently unused by a part.
        for value in old {
            try Task.checkCancellation()
            guard newIndex[.init(kind: value.kind, key: value.key)] == value else {
                throw LibraryImportSupport.error("library_revision_conflict", value.key.id.uuidString,
                    "Una revisione esistente è stata rimossa o modificata: aggiungere una nuova revisione.", id: value.key.id)
            }
        }
        var result: [LibraryRevisionDiff] = []
        for value in new {
            try Task.checkCancellation()
            guard oldIndex[.init(kind: value.kind, key: value.key)] == nil else { continue }
            let previous = families[.init(kind: value.kind, id: value.key.id)] ?? []
            if previous.isEmpty { result.append(diff(nil, value, usedBy: [])) }
            else {
                for baseline in previous {
                    try Task.checkCancellation()
                    let affected = usage[.init(kind: baseline.kind, key: baseline.key)] ?? []
                    result.append(diff(baseline, value, usedBy: affected.sorted { $0.uuidString < $1.uuidString }))
                }
            }
        }
        return result
    }

    private static func definitions(_ library: ElectronicsLibrary) -> [LibraryDefinition] {
        (library.symbols.map(LibraryDefinition.symbol) + library.footprints.map(LibraryDefinition.footprint)
         + library.devices.map(LibraryDefinition.device)).sorted {
            if $0.kind.rawValue != $1.kind.rawValue { return $0.kind.rawValue < $1.kind.rawValue }
            if $0.key.id != $1.key.id { return $0.key.id.uuidString < $1.key.id.uuidString }
            return $0.key.revision < $1.key.revision
        }
    }

    private static func entities<T: Codable & Equatable & Sendable>(_ before: [T], _ after: [T], id: KeyPath<T, UUID>) -> [LibraryEntityChange<T>] {
        // Integrity validation precedes every call, so duplicate IDs cannot trap the dictionary.
        let a = Dictionary(uniqueKeysWithValues: before.map { ($0[keyPath: id], $0) })
        let b = Dictionary(uniqueKeysWithValues: after.map { ($0[keyPath: id], $0) })
        return Set(a.keys).union(b.keys).sorted { $0.uuidString < $1.uuidString }.compactMap { key in
            a[key] == b[key] ? nil : .init(id: key, before: a[key], after: b[key])
        }
    }

    private static func diff(_ before: LibraryDefinition?, _ after: LibraryDefinition, usedBy: [UUID]) -> LibraryRevisionDiff {
        var fields: [LibraryChangedField] = []
        var pins: [LibraryEntityChange<SymbolPin>] = []
        var pads: [LibraryEntityChange<FootprintPad>] = []
        var graphics: [LibraryEntityChange<LibraryGraphic>] = []
        func change<T: Equatable>(_ field: LibraryChangedField, _ a: T, _ b: T) { if a != b { fields.append(field) } }
        switch (before, after) {
        case let (.symbol(a)?, .symbol(b)):
            change(.name, a.name, b.name); change(.source, a.source, b.source)
            change(.properties, a.properties ?? [:], b.properties ?? [:])
            pins = entities(a.pins, b.pins, id: \.id)
            graphics = entities(a.graphics ?? [], b.graphics ?? [], id: \.id)
        case let (.footprint(a)?, .footprint(b)):
            change(.name, a.name, b.name); change(.source, a.source, b.source)
            change(.properties, a.properties ?? [:], b.properties ?? [:])
            change(.assemblyCentroid, a.assemblyCentroid, b.assemblyCentroid); change(.model3D, a.model3D, b.model3D)
            pads = entities(a.pads, b.pads, id: \.id)
            graphics = entities(a.graphics ?? [], b.graphics ?? [], id: \.id)
        case let (.device(a)?, .device(b)):
            change(.manufacturer, a.manufacturer, b.manufacturer)
            change(.manufacturerPartNumber, a.manufacturerPartNumber, b.manufacturerPartNumber)
            change(.symbol, a.symbol, b.symbol); change(.footprint, a.footprint, b.footprint)
            func mappings(_ v: [PinPadMapping]) -> [String] { v.map { $0.pinID.uuidString + "/" + $0.padID.uuidString }.sorted() }
            change(.pinMap, mappings(a.pinMap), mappings(b.pinMap)); change(.supplier, a.jlc, b.jlc)
        case let (nil, .symbol(b)):
            fields = [.definition]; pins = entities([], b.pins, id: \.id); graphics = entities([], b.graphics ?? [], id: \.id)
        case let (nil, .footprint(b)):
            fields = [.definition]; pads = entities([], b.pads, id: \.id); graphics = entities([], b.graphics ?? [], id: \.id)
        case (nil, .device): fields = [.definition]
        default: preconditionFailure("Comparison pairs must have the same definition kind")
        }
        if !pins.isEmpty { fields.append(.pins) }; if !pads.isEmpty { fields.append(.pads) }
        if !graphics.isEmpty { fields.append(.graphics) }
        return .init(before: before, after: after, changedFields: fields, pins: pins, pads: pads,
                     graphics: graphics, affectedComponentIDs: usedBy)
    }
}
