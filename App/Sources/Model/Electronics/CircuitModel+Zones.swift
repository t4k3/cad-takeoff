import ElectronicsCore
import Foundation

/// Copper planes of «Circuiti» (Codex's engine, docs/electronics/PCB_ZONES.md): an outline on one
/// layer filled by the engine with one net's copper, clear of other nets, holes, the board edge
/// and keepouts, joined solidly (no thermal reliefs yet). The UI never computes the fill: it
/// shows the engine's cells, previews each change before confirming it (same identity, same
/// command) and selects a plane by its outline, filled or not.
extension CircuitModel {
    var zones: [PCBZone] { design?.board.copper?.zones ?? [] }
    func zone(_ id: UUID) -> PCBZone? { zones.first { $0.id == id } }
    /// The engine's fill of a plane (current drawing only).
    func zoneFill(_ id: UUID) -> PCBZoneFill? { pcbIsCurrent ? pcb?.zones.first { $0.zone.id == id } : nil }

    /// A plane being drawn: identity and base revision for the whole session, net, layer, points.
    struct ZoneDraft: Equatable {
        var id = UUID()
        var baseRevision: UInt64
        var name: String
        var netID: UUID?
        var layer: Int
        var removeIslands = true
        var points: [PCBPoint] = []

        /// The outline with `next` (the mouse) as last point; two points: the rectangle between them.
        func outline(with next: PCBPoint? = nil) -> [PCBPoint]? {
            let repeated = next.map { n in [points.first, points.last].contains { $0.map { CircuitModel.distance($0, n) < 1e-6 } ?? false } } ?? true
            let pts = points + (repeated ? [] : [next!])
            if pts.count == 2 { return ElectronicsPCB.keepoutRectangle(from: pts[0], to: pts[1]) }
            return pts.count >= 3 ? pts : nil
        }
        func plane(with next: PCBPoint? = nil) -> PCBZone? {
            guard let netID, let outline = outline(with: next) else { return nil }
            return PCBZone(id: id, name: name, netID: netID, layer: layer, outline: outline, removeIslands: removeIslands)
        }
    }

    /// Piano: a click adds a point (on a keepout's or plane's corner, else the grid); a click on
    /// the first point closes it. The net: the one of the copper under the first click, else the
    /// one chosen last, else GND if there is one.
    func zoneClick(at p: PCBPoint, tolerance: Double) async {
        guard !pcbBusy else { return }
        let q = keepoutPoint(near: p, tolerance: tolerance)
        if zoneDraft == nil && keepoutDraft == nil { yieldOpen() }
        var d = zoneDraft ?? ZoneDraft(baseRevision: document?.revision ?? 0, name: "Piano di rame \(zones.count + 1)",
                                       netID: nil, layer: activeLayer, removeIslands: zoneRemoveIslands)
        if d.points.isEmpty {
            let under = pcbIsCurrent ? pcb?.pick(point: p, tolerance: tolerance, layer: activeLayer).first { $0.netID != nil }?.netID : nil
            d.netID = under ?? zoneNet ?? design?.nets.first { $0.name.uppercased() == "GND" }?.id
        }
        if d.points.count >= 3, Self.distance(q, d.points[0]) <= tolerance { zoneDraft = d; await finishZone(); return }
        // A second click on the last point (a double click) closes it: two points make the rectangle.
        if let last = d.points.last, Self.distance(last, q) < 1e-6 {
            if d.points.count >= 2 { await finishZone() }
            return
        }
        d.points.append(q)
        zoneDraft = d
        checkRule(d.plane().map { .addZone($0) })
    }

    /// The net of the planes being drawn (chosen in the bar), remembered for the next one.
    var zoneNet: UUID? {
        get { zoneDraft?.netID ?? lastZoneNet }
        set {
            lastZoneNet = newValue
            guard var d = zoneDraft else { return }
            d.netID = newValue
            zoneDraft = d
            checkRule(d.plane().map { .addZone($0) })
        }
    }

    func setDraftRemoveIslands(_ on: Bool) {
        zoneRemoveIslands = on
        guard var d = zoneDraft else { return }
        d.removeIslands = on
        zoneDraft = d
        checkRule(d.plane().map { .addZone($0) })
    }

    func previewZone(to p: PCBPoint, tolerance: Double) {
        guard let d = zoneDraft else { return }
        checkRule(d.plane(with: keepoutPoint(near: p, tolerance: tolerance)).map { .addZone($0) })
    }

    /// Invio: the plane as drawn, with its previewed identity, at the revision it was drawn on.
    @discardableResult
    func finishZone() async -> Bool {
        guard let d = zoneDraft else { return false }
        guard d.netID != nil else { report("Piano di rame: scegli la rete (in basso) prima di chiuderlo."); return false }
        guard let plane = d.plane() else { report("Piano di rame: clicca almeno i due angoli opposti di un rettangolo, o tre punti."); return false }
        guard await runPCB(.addZone(plane), expectedRevision: d.baseRevision) else { return false }
        if zoneDraft?.id == d.id { zoneDraft = nil; ruleCheck = nil }
        selection = nil; copperSelection = nil; keepoutSelection = nil
        zoneSelection = plane.id
        let net = design?.nets.first { $0.id == plane.netID }?.name ?? "?"
        report("\(plane.name): rete \(net) su \(layerName(plane.layer)), collegamento pieno")
        return true
    }

    func undoZonePoint() {
        guard var d = zoneDraft, !d.points.isEmpty else { return }
        d.points.removeLast()
        zoneDraft = d.points.isEmpty ? nil : d
        checkRule(zoneDraft?.plane().map { .addZone($0) })
    }

    /// The plane whose outline is under a point (filled or empty; the layer being drawn on first).
    func zoneHit(at p: PCBPoint, tolerance: Double) -> PCBZoneHit? {
        guard pcbIsCurrent, let s = pcb else { return nil }
        return s.pickZones(point: p, tolerance: tolerance, layer: activeLayer).first ?? s.pickZones(point: p, tolerance: tolerance).first
    }

    @discardableResult
    func updateZone(_ z: PCBZone) async -> Bool {
        guard zone(z.id) != z else { return true }
        return await runPCB(.updateZone(z))
    }

    func moveZone(_ id: UUID, by offset: PCBPoint) async {
        guard offset.x != 0 || offset.y != 0 else { return }
        await runPCB(.moveZone(id: id, offset: offset))
        ruleCheck = nil
    }

    func removeZone(_ id: UUID) async {
        if await runPCB(.removeZone(id)) { zoneSelection = nil }
    }
}
