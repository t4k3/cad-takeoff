import ElectronicsCore
import Foundation

/// The copper of «Circuiti» (Codex's engine, docs/electronics/PCB.md): the board's drawing (the
/// engine's `PCBSnapshot`, kept per revision), the layers, and the Pista tool. Tracks and vias are
/// engine commands through preview/apply: the route under the mouse is previewed in the background
/// and shown as not confirmable when the engine's DRC would refuse it; nothing routes around
/// obstacles or moves other copper.
extension CircuitModel {
    /// A route being drawn: one run of points per layer, a via where the layer changes. Tracks
    /// and vias keep their identities for the whole session: the command confirmed is the one
    /// previewed.
    struct Route: Equatable {
        struct Run: Equatable { var id = UUID(); var layer: Int; var points: [PCBPoint] }
        struct Via: Equatable { var id = UUID(); var position: PCBPoint }
        var session = UUID()
        var netID: UUID
        var baseRevision: UInt64
        /// The net's rules as the engine resolves them (its class, or the board's): the minima
        /// to respect and the proposed track and via sizes.
        var rules: PCBResolvedNetRules
        var width: Double
        /// The layers of the copper the route starts from (an SMD pad: its side only).
        var startLayers: [Int]
        var runs: [Run]
        var vias: [Via] = []
        var layer: Int { runs[runs.count - 1].layer }
        var tip: PCBPoint { runs[runs.count - 1].points[runs[runs.count - 1].points.count - 1] }
        /// Something drawn yet (a leg on some layer).
        var hasLegs: Bool { runs.contains { $0.points.count > 1 } }
    }

    /// The leg from the route's tip to the mouse, and what the engine says of the route with it.
    struct RouteCheck: Equatable {
        /// What was checked: the route with the leg (session, layers, width, posture are in its
        /// points and runs), on which revision, towards which point.
        struct Key: Equatable { var candidate: Route; var revision: UInt64; var target: PCBPoint }
        var key: Key
        var target: PCBSnapTarget
        var leg: [PCBPoint]
        /// Errors the engine would refuse the route for (nil while the check runs).
        var blocking: [ElectronicsIssue]?
    }

    var layerCount: Int { design?.board.copper?.layerCount ?? 2 }
    var copperRules: PCBDesignRules { design?.board.copper?.rules ?? PCBDesignRules() }

    /// Sopra, Interno 1…, Sotto.
    func layerName(_ layer: Int) -> String {
        layer == 0 ? "Sopra" : layer == layerCount - 1 ? "Sotto" : "Interno \(layer)"
    }

    /// Components of the circuit not on the board yet (from the document itself: no waiting for
    /// the drawing).
    var unplacedComponents: [UUID] {
        guard let d = design else { return [] }
        let placed = Set(d.board.placements.map(\.componentID))
        return d.components.map(\.id).filter { !placed.contains($0) }.sorted { $0.uuidString < $1.uuidString }
    }

    // MARK: The drawing

    var pcbIsCurrent: Bool {
        guard let pcb, let doc = document else { return false }
        return pcb.designID == doc.design.id && pcb.revision == doc.revision
    }

    /// Another document: nothing of the previous one's drawings, route, checks or selections
    /// stays (a copy of a file has the same design and revision).
    func forgetDrawings() {
        documentEpoch += 1
        openRequest = nil   // an open still reading is overtaken
        cancelImport()      // a library preview belongs to the circuit it was made on
        pcbTask?.cancel(); pcb = nil
        routeCheckTask?.cancel(); route = nil; routeCheck = nil
        copperSelection = nil; issueMark = nil; activeLayer = 0
        keepoutDraft = nil; keepoutSelection = nil; zoneDraft = nil; zoneSelection = nil; ruleCheckTask?.cancel(); ruleCheck = nil
        netRulesTask?.cancel(); netRules = nil; showNetClasses = false
        schematicTask?.cancel(); schematic = nil
        ghostTask?.cancel(); ghostSession = nil; schematicGhost = []
        schematicSelection = nil; selection = nil
        tool = .select; schematicTool = .select
    }

    /// Rebuilds the copper drawing off the main thread when the document changed (the previous
    /// build is cancelled; a late one for an older revision is dropped).
    func refreshPCB() {
        guard let doc = document else { pcbTask?.cancel(); pcb = nil; return }
        if pcbIsCurrent { return }
        pcbTask?.cancel()
        let design = doc.design, revision = doc.revision, epoch = documentEpoch
        if activeLayer >= layerCount { activeLayer = 0 }
        pcbTask = Task { [weak self] in
            let built = await Self.offMain { try? ElectronicsPCB.snapshot(design: design, revision: revision) }
            guard !Task.isCancelled, let self, self.documentEpoch == epoch, self.document?.revision == revision,
                  self.document?.design.id == design.id else { return }
            self.pcb = built
        }
    }

    func pcbReady() async { await pcbTask?.value }

    // MARK: Pista

    /// A click with Pista: starts on a pad, via or track with a net; then each click adds a
    /// 45°/90° leg, and a click on copper of the same net ends the route there.
    func routeClick(at p: PCBPoint, tolerance: Double) async {
        guard !pcbBusy else { return }
        guard pcbIsCurrent, let snapshot = pcb else { report("Il disegno della scheda si sta aggiornando: riprova."); return }
        guard var r = route else { startRoute(at: p, tolerance: tolerance, in: snapshot); return }
        let target = routeTarget(near: p, tolerance: tolerance)
        let leg = ElectronicsPCB.routePoints(from: r.tip, to: target.position, diagonalFirst: diagonalFirst)
        guard leg.count > 1 else {
            // A click on the tip itself: ends there.
            if r.hasLegs { await finishRoute() }
            return
        }
        r.runs[r.runs.count - 1].points += leg.dropFirst()
        route = r
        routeCheck = nil
        if target.kind != .grid { await finishRoute() }
    }

    private func startRoute(at p: PCBPoint, tolerance: Double, in snapshot: PCBSnapshot) {
        // The layer being drawn on first (where top and bottom copper cross, the one in view).
        let onLayer = snapshot.pick(point: p, tolerance: tolerance, layer: activeLayer)
        let hits = onLayer.contains { $0.netID != nil } ? onLayer : snapshot.pick(point: p, tolerance: tolerance)
        guard !hits.isEmpty else { report("Comincia la pista da una piazzola, una via o una pista."); return }
        guard let hit = hits.first(where: { $0.netID != nil }), let net = hit.netID else {
            report("Questa piazzola non è su nessuna rete: collegala prima (nello schema o con Collega).")
            return
        }
        // Its layer: the one being drawn on if the copper is there, else the copper's own (an SMD pad underneath).
        let layers = snapshot.primitives.first { $0.item == hit.item }?.layers ?? [activeLayer]
        if !layers.contains(activeLayer), let own = layers.first { activeLayer = own }
        let start = snapshot.snapTargets(near: p, radius: tolerance, layer: activeLayer, netID: net)
            .first { $0.kind != .grid }?.position ?? hit.position
        guard let d = design, let rules = try? ElectronicsPCB.resolvedRules(design: d, netID: net) else {
            report("Regole della rete non disponibili: controlla le VERIFICHE.")
            return
        }
        route = Route(netID: net, baseRevision: document?.revision ?? 0, rules: rules, width: rules.routing.trackWidth,
                      startLayers: layers, runs: [.init(layer: activeLayer, points: [start])])
        routeCheck = nil
    }

    /// Where the next leg ends: copper of the route's net on its layer, else the 0,25 mm grid.
    func routeTarget(near p: PCBPoint, tolerance: Double) -> PCBSnapTarget {
        if let r = route, pcbIsCurrent, let hit = pcb?.snapTargets(near: p, radius: tolerance, layer: r.layer, netID: r.netID)
            .first(where: { $0.kind != .grid && Self.distance($0.position, r.tip) > 1e-6 }) {
            return hit
        }
        let q = ElectronicsPCB.gridPoint(p, spacing: 0.25) ?? p
        return PCBSnapTarget(kind: .grid, item: nil, netID: nil, position: q, distance: Self.distance(p, q))
    }

    /// The leg to the mouse, checked by the engine in the background (the last check wins).
    func previewLeg(to p: PCBPoint, tolerance: Double) {
        guard let r = route, let doc = document, pcbIsCurrent else { routeCheck = nil; return }
        let target = routeTarget(near: p, tolerance: tolerance)
        let leg = ElectronicsPCB.routePoints(from: r.tip, to: target.position, diagonalFirst: diagonalFirst)
        var candidate = r
        if leg.count > 1 { candidate.runs[candidate.runs.count - 1].points += leg.dropFirst() }
        let key = RouteCheck.Key(candidate: candidate, revision: doc.revision, target: target.position)
        if routeCheck?.key == key { return }
        routeCheck = RouteCheck(key: key, target: target, leg: leg, blocking: nil)
        routeCheckTask?.cancel()
        guard let command = routeCommand(candidate) else { routeCheck?.blocking = []; return }
        let base = r.baseRevision
        routeCheckTask = Task { [weak self] in
            let blocking = await Self.offMain { () -> [ElectronicsIssue]? in
                guard let preview = try? ElectronicsCommands.preview(.pcb(command), document: doc, expectedRevision: base) else { return nil }
                return preview.blockingIssues
            }
            guard !Task.isCancelled, let self, self.routeCheck?.key == key else { return }
            // A preview the engine cannot even build (e.g. a zero-length leg) is not confirmable either.
            self.routeCheck?.blocking = blocking ?? [ElectronicsIssue("pcb_preview", "PCB", "Pista non valida.")]
        }
    }

    func routeCheckReady() async { await routeCheckTask?.value }

    /// Via (V): a via at the tip, the route goes on on another layer (the opposite side, or the
    /// one chosen). Without a route, only the layer being drawn on changes.
    func switchLayer(to layer: Int? = nil) {
        let next = layer ?? (activeLayer == 0 ? layerCount - 1 : 0)
        guard (0..<layerCount).contains(next), next != activeLayer || route != nil else { return }
        activeLayer = next
        guard var r = route, r.layer != next else { return }
        let tip = r.tip, last = r.runs.count - 1
        if r.runs[last].points.count == 1, last > 0 {
            // Just after a via, nothing drawn yet: the same via reaches every layer.
            if r.runs[last - 1].layer == next { r.runs.removeLast(); r.vias.removeLast() } else { r.runs[last].layer = next }
        } else if r.runs[last].points.count == 1, r.startLayers.contains(next) {
            // At the start, on copper that is on that layer too (a through-hole pad, a via).
            r.runs[last].layer = next
        } else {
            // Otherwise the layers are joined only by a via (an SMD pad does not cross the board).
            r.vias.append(.init(position: tip))
            r.runs.append(.init(layer: next, points: [tip]))
        }
        route = r
        routeCheck = nil
    }

    /// Backspace: the last leg off (and the via before it); nothing left, no route.
    func undoLeg() {
        guard var r = route else { return }
        if r.runs[r.runs.count - 1].points.count > 1 {
            r.runs[r.runs.count - 1].points.removeLast()
        } else if r.runs.count > 1 {
            r.runs.removeLast(); r.vias.removeLast()
            activeLayer = r.layer
        } else {
            route = nil; routeCheck = nil; return
        }
        route = r
        routeCheck = nil
    }

    /// Enter or double-click: the route as drawn (tracks and vias in one undo step), if the
    /// engine takes it; refused, it stays to be corrected.
    @discardableResult
    func finishRoute() async -> Bool {
        guard let r = route else { return false }
        guard let command = routeCommand(r) else { route = nil; routeCheck = nil; return false }
        guard document?.revision == r.baseRevision else {
            route = nil; routeCheck = nil
            report("Il circuito è cambiato mentre tracciavi: ricomincia la pista.")
            return false
        }
        guard await runPCB(command, expectedRevision: r.baseRevision) else { return false }
        if route?.session == r.session { route = nil; routeCheck = nil }
        let name = design?.nets.first { $0.id == r.netID }?.name ?? "?"
        let length = r.runs.reduce(0.0) { sum, run in sum + zip(run.points, run.points.dropFirst()).reduce(0) { $0 + Self.distance($1.0, $1.1) } }
        report(String(format: "Pista sulla rete %@: %.1f mm", name, length) + (r.vias.isEmpty ? "" : ", \(r.vias.count) via"))
        return true
    }

    /// The engine command for a route: a track per layer run (collinear points merged), the vias.
    func routeCommand(_ r: Route) -> PCBCommand? {
        var commands: [PCBCommand] = []
        for run in r.runs {
            let pts = ElectronicsPCB.simplifiedPoints(run.points)
            if pts.count > 1 { commands.append(.addTrack(PCBTrack(id: run.id, netID: r.netID, layer: run.layer, width: r.width, points: pts))) }
        }
        let via = r.rules.routing
        for v in r.vias { commands.append(.addVia(PCBVia(id: v.id, netID: r.netID, position: v.position, diameter: via.viaDiameter, drill: via.viaDrill))) }
        guard !commands.isEmpty else { return nil }
        return commands.count == 1 ? commands[0] : .batch(commands)
    }

    nonisolated static func distance(_ a: PCBPoint, _ b: PCBPoint) -> Double { hypot(a.x - b.x, a.y - b.y) }

    // MARK: Tracks and vias

    /// The track or via under a point (the layer being drawn on first).
    func copperHit(at p: PCBPoint, tolerance: Double) -> PCBHit? {
        guard pcbIsCurrent, let s = pcb else { return nil }
        // Tracks and vias only (pads select their component, planes by their outline).
        func copper(_ hits: [PCBHit]) -> PCBHit? { hits.first { switch $0.item { case .track, .via: true; case .pad, .zone: false } } }
        return copper(s.pick(point: p, tolerance: tolerance, layer: activeLayer)) ?? copper(s.pick(point: p, tolerance: tolerance))
    }

    func track(_ id: UUID) -> PCBTrack? { design?.board.copper?.tracks.first { $0.id == id } }
    func via(_ id: UUID) -> PCBVia? { design?.board.copper?.vias.first { $0.id == id } }

    func removeCopper(_ item: PCBItem) async {
        let ok = switch item {
        case .track(let id): await runPCB(.removeTrack(id))
        case .via(let id): await runPCB(.removeVia(id))
        case .zone(let id): await runPCB(.removeZone(id))
        case .pad: false
        }
        if ok { copperSelection = nil }
    }

    func setWidth(_ width: Double, ofTrack id: UUID) async {
        guard var t = track(id), t.width != width else { return }
        t.width = width
        await runPCB(.updateTrack(t))
    }

    /// Strati e regole (Scheda): the engine refuses a new layer count while there is copper.
    @discardableResult
    func configureCopper(layerCount: Int, rules: PCBDesignRules) async -> Bool {
        guard layerCount != self.layerCount || rules != copperRules else { return true }
        return await runPCB(.configure(layerCount: layerCount, rules: rules))
    }

    /// The track widths offered from a minimum (the net's), the minimum first.
    static func trackWidths(from minimum: Double) -> [Double] {
        [minimum] + [0.2, 0.25, 0.3, 0.4, 0.5, 0.8, 1.0, 1.5, 2.0].filter { $0 > minimum + 1e-9 }
    }

    /// The minimum width of a track of `net` (its class, else the board's rule).
    func minimumTrackWidth(net: UUID) -> Double {
        guard let d = design, let r = try? ElectronicsPCB.resolvedRules(design: d, netID: net) else { return copperRules.minimumTrackWidth }
        return r.rules.minimumTrackWidth
    }
}
