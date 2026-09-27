import ElectronicsCore
import Foundation

/// Net classes and keepout areas of «Circuiti» (Codex's engine, docs/electronics/PCB_RULES.md).
/// A class gives its nets tighter minima (checked by the DRC) and proposed track and via sizes
/// (used by Pista); a keepout forbids copper on its layers. All engine commands: one undo step
/// each, refused whole with the engine's reason. The UI shows the engine's resolved values and
/// never recomputes the DRC.
extension CircuitModel {
    var netClasses: [PCBNetClass] { design?.board.copper?.netClasses ?? [] }
    var keepouts: [PCBKeepout] { design?.board.copper?.keepouts ?? [] }

    func netClass(of net: UUID) -> PCBNetClass? { netClasses.first { $0.netIDs.contains(net) } }
    func keepout(_ id: UUID) -> PCBKeepout? { keepouts.first { $0.id == id } }

    /// The rules the engine applies to a net (its class, or the board's).
    func resolvedRules(net: UUID?) -> PCBResolvedNetRules? {
        guard let d = design else { return nil }
        return try? ElectronicsPCB.resolvedRules(design: d, netID: net)
    }

    // MARK: Classes

    /// A new class («Potenza», «Segnale»…) with the board's rules until changed.
    @discardableResult
    func addNetClass(name: String) async -> UUID? {
        let clean = name.trimmingCharacters(in: .whitespaces)
        guard !clean.isEmpty else { report("Dai un nome alla classe."); return nil }
        let c = PCBNetClass(name: clean)
        return await runPCB(.addNetClass(c)) ? c.id : nil
    }

    /// The class's fields as edited, its nets as the document has them now (assignments are
    /// their own commands: an edit never takes nets out of the class).
    func edited(_ c: PCBNetClass) -> PCBNetClass? {
        guard let current = netClasses.first(where: { $0.id == c.id }) else { return nil }
        var merged = c
        merged.netIDs = current.netIDs
        return merged
    }

    /// Applica: at the revision the change was checked on, when given (else the current one).
    @discardableResult
    func updateNetClass(_ c: PCBNetClass, expectedRevision: UInt64? = nil) async -> Bool {
        guard let merged = edited(c) else { report("La classe non c'è più."); return false }
        guard netClasses.first(where: { $0.id == c.id }) != merged else { return true }
        return await runPCB(.updateNetClass(merged), expectedRevision: expectedRevision)
    }

    // MARK: Resolved rules per net

    struct NetRulesCache: Equatable {
        var designID: UUID
        var revision: UInt64
        var rules: [UUID: PCBResolvedNetRules]
    }

    /// The resolved rules of every net for the current revision, if computed.
    var currentNetRules: [UUID: PCBResolvedNetRules]? {
        guard let c = netRules, let doc = document, c.designID == doc.design.id, c.revision == doc.revision else { return nil }
        return c.rules
    }

    /// Computes them in the background when missing for this revision (the CLASSI panel asks);
    /// an invalid document leaves them missing (VERIFICHE says why).
    func refreshNetRules() {
        guard let doc = document, currentNetRules == nil else { return }
        netRulesTask?.cancel()
        let design = doc.design, revision = doc.revision, epoch = documentEpoch
        netRulesTask = Task { [weak self] in
            // One validation of the document, then every net (the engine's batch resolver).
            let rules = await Self.offMain { try? ElectronicsPCB.resolvedRules(design: design) }
            guard !Task.isCancelled, let self, let rules, self.documentEpoch == epoch, self.document?.revision == revision else { return }
            self.netRules = NetRulesCache(designID: design.id, revision: revision, rules: rules)
        }
    }

    func netRulesReady() async { await netRulesTask?.value }

    /// Its nets go back to the board's rules.
    func removeNetClass(_ id: UUID) async { await runPCB(.removeNetClass(id)) }

    /// Moves nets into a class (out of the one they were in); nil: back to the board's rules.
    @discardableResult
    func assign(nets: [UUID], to classID: UUID?) async -> Bool {
        guard !nets.isEmpty else { return true }
        return await runPCB(.assignNetClass(netIDs: nets, classID: classID))
    }

    // MARK: Checking a change before confirming it

    /// A rule change and the copper errors it would add (nil while the engine checks), or why
    /// the engine refuses it.
    struct RuleCheck: Equatable {
        var command: PCBCommand
        var revision: UInt64
        var newErrors: [ElectronicsIssue]?
        /// Errors the engine would refuse the change for (a new plane with its own errors).
        var blocking: [ElectronicsIssue]?
        var refusal: String?
        /// Every plane's fill as the engine computes it with the change (an area, a rule or a
        /// plane changes the planes around it): the drawing shows these instead, empty ones too.
        var fills: [PCBZoneFill]?
    }

    /// Previews `command` in the background: the errors it would add to the existing copper (a
    /// rule over copper is allowed, and shown before confirming). The same command is confirmed.
    func checkRule(_ command: PCBCommand?) {
        guard let command, let doc = document else { ruleCheckTask?.cancel(); ruleCheck = nil; return }
        if ruleCheck?.command == command, ruleCheck?.revision == doc.revision { return }
        ruleCheck = RuleCheck(command: command, revision: doc.revision)
        ruleCheckTask?.cancel()
        let before = pcbIsCurrent ? (pcb?.issues ?? []) : []
        ruleCheckTask = Task { [weak self] in
            let planes = !(doc.design.board.copper?.zones.isEmpty ?? true) || { if case .addZone = command { true } else { false } }()
            let result = await Self.offMain { () -> (errors: [ElectronicsIssue], blocking: [ElectronicsIssue], refusal: String?, fills: [PCBZoneFill]?) in
                do {
                    let preview = try ElectronicsCommands.preview(.pcb(command), document: doc, expectedRevision: doc.revision)
                    let errors = preview.issues.filter { e in
                        e.severity == .error && e.code.hasPrefix("pcb_")
                            && !before.contains { $0.code == e.code && $0.subjectIDs == e.subjectIDs }
                    }
                    let fills = planes ? (try? preview.pcbSnapshot())?.zones : nil
                    return (errors, preview.blockingIssues, nil, fills)
                } catch {
                    return ([], [], CircuitModel.describe(error), nil)
                }
            }
            guard !Task.isCancelled, let self, self.ruleCheck?.command == command, self.ruleCheck?.revision == doc.revision else { return }
            self.ruleCheck?.newErrors = result.errors
            self.ruleCheck?.blocking = result.blocking
            self.ruleCheck?.refusal = result.refusal
            self.ruleCheck?.fills = result.fills
        }
    }

    func ruleCheckReady() async { await ruleCheckTask?.value }

    // MARK: Keepouts

    /// An area being drawn: its identity and base revision for the whole session (the area
    /// previewed is the one confirmed), its points so far and its layers.
    struct KeepoutDraft: Equatable {
        var id = UUID()
        var baseRevision: UInt64
        var name: String
        var layers: [Int]
        var points: [PCBPoint] = []

        /// The outline with `next` (the mouse) as its last point: two points, the rectangle between them.
        func outline(with next: PCBPoint? = nil) -> [PCBPoint]? {
            // The mouse on the last point (just clicked) or on the first (to close) adds nothing.
            let repeated = next.map { n in [points.first, points.last].contains { $0.map { CircuitModel.distance($0, n) < 1e-6 } ?? false } } ?? true
            let pts = points + (repeated ? [] : [next!])
            if pts.count == 2 { return ElectronicsPCB.keepoutRectangle(from: pts[0], to: pts[1]) }
            return pts.count >= 3 ? pts : nil
        }
        func area(with next: PCBPoint? = nil) -> PCBKeepout? {
            outline(with: next).map { PCBKeepout(id: id, name: name, outline: $0, layers: layers) }
        }
    }

    /// Area vietata: a click adds a point (on a keepout's corner or side, else the 0,25 mm grid);
    /// a click on the first point closes it.
    func keepoutClick(at p: PCBPoint, tolerance: Double) async {
        guard !pcbBusy else { return }
        let q = keepoutPoint(near: p, tolerance: tolerance)
        var d = keepoutDraft ?? KeepoutDraft(baseRevision: document?.revision ?? 0, name: "Area vietata \(keepouts.count + 1)", layers: [activeLayer])
        if d.points.count >= 3, Self.distance(q, d.points[0]) <= tolerance { await finishKeepout(); return }
        // A second click on the last point (a double click) closes it: two points make the rectangle.
        if let last = d.points.last, Self.distance(last, q) < 1e-6 {
            if d.points.count >= 2 { await finishKeepout() }
            return
        }
        d.points.append(q)
        keepoutDraft = d
        checkRule(d.area().map { .addKeepout($0) })
    }

    /// The area with the mouse as its next point, checked by the engine before the click.
    func previewKeepout(to p: PCBPoint, tolerance: Double) {
        guard let d = keepoutDraft else { return }
        checkRule(d.area(with: keepoutPoint(near: p, tolerance: tolerance)).map { .addKeepout($0) })
    }

    func keepoutPoint(near p: PCBPoint, tolerance: Double) -> PCBPoint {
        if pcbIsCurrent, let hit = pcb?.keepoutSnapTargets(near: p, radius: tolerance, layer: activeLayer).first { return hit.position }
        return ElectronicsPCB.gridPoint(p, spacing: 0.25) ?? p
    }

    /// Tutti gli strati / only the one being drawn on, for the area being drawn.
    func setDraftLayers(all: Bool) {
        guard var d = keepoutDraft else { return }
        d.layers = all ? Array(0..<layerCount) : [activeLayer]
        keepoutDraft = d
        checkRule(d.area().map { .addKeepout($0) })
    }

    /// Invio: the outline as drawn — two points make the rectangle between them — with the
    /// identity it was previewed with, at the revision it was drawn on.
    @discardableResult
    func finishKeepout() async -> Bool {
        guard let d = keepoutDraft, let area = d.area() else {
            report("Area vietata: clicca almeno i due angoli opposti di un rettangolo, o tre punti.")
            return false
        }
        guard await runPCB(.addKeepout(area), expectedRevision: d.baseRevision) else { return false }
        if keepoutDraft?.id == d.id { keepoutDraft = nil; ruleCheck = nil }
        selection = nil; copperSelection = nil; zoneSelection = nil
        keepoutSelection = area.id
        let where_ = area.layers.count == layerCount ? "tutti gli strati" : area.layers.map(layerName).joined(separator: ", ")
        report("\(area.name) su \(where_): niente piste, via e piazzole")
        return true
    }

    func undoKeepoutPoint() {
        guard var d = keepoutDraft, !d.points.isEmpty else { return }
        d.points.removeLast()
        keepoutDraft = d.points.isEmpty ? nil : d
        checkRule(keepoutDraft?.area().map { .addKeepout($0) })
    }

    /// The keepout under a point (the layer being drawn on first).
    func keepoutHit(at p: PCBPoint, tolerance: Double) -> PCBKeepoutHit? {
        guard pcbIsCurrent, let s = pcb else { return nil }
        return s.pickKeepouts(point: p, tolerance: tolerance, layer: activeLayer).first ?? s.pickKeepouts(point: p, tolerance: tolerance).first
    }

    @discardableResult
    func updateKeepout(_ k: PCBKeepout) async -> Bool {
        guard keepout(k.id) != k else { return true }
        return await runPCB(.updateKeepout(k))
    }

    /// Sposta: previewed while dragging (checkRule), the same command on release.
    func moveKeepout(_ id: UUID, by offset: PCBPoint) async {
        guard offset.x != 0 || offset.y != 0 else { return }
        await runPCB(.moveKeepout(id: id, offset: offset))
        ruleCheck = nil
    }

    func removeKeepout(_ id: UUID) async {
        if await runPCB(.removeKeepout(id)) { keepoutSelection = nil }
    }
}
