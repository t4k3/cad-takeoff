import Foundation

public enum ElectronicsPCB {
    static func failure(_ code: String, _ message: String, _ ids: [UUID] = []) -> ElectronicsFailure {
        var issue = ElectronicsIssue(code, "PCB", message); issue.subjectIDs = ids
        return .init([issue])
    }
    static func integrity(_ design: ElectronicsDesign) -> [ElectronicsIssue] {
        guard let copper = design.board.copper else { return [] }
        var issues: [ElectronicsIssue] = []
        func add(_ code: String, _ message: String, _ ids: [UUID] = []) { issues += failure(code,message,ids).issues }
        if !(2...32).contains(copper.layerCount) || copper.layerCount % 2 != 0 { add("invalid_copper_layers", "Numero di strati rame atteso: pari, da 2 a 32.") }
        let rules = copper.rules
        if ![rules.clearance,rules.edgeClearance,rules.minimumTrackWidth,rules.minimumDrill,rules.minimumAnnularRing].allSatisfy({ ElectronicsGeometry.valid($0) && $0 > 0 }) {
            add("invalid_pcb_rules", "Distanze, larghezze e forature minime devono essere positive e finite.")
        }
        let ids = copper.tracks.map(\.id)+copper.vias.map(\.id)
        let foreign = Set(design.components.map(\.id)+design.nets.map(\.id)+design.library.footprints.flatMap { $0.pads.map(\.id) })
        if Set(ids).count != ids.count || !Set(ids).isDisjoint(with:foreign) { add("duplicate_copper_identity", "Identità del rame duplicate o condivise con altri oggetti.") }
        let nets = Set(design.nets.map(\.id))
        for t in copper.tracks {
            if !nets.contains(t.netID) { add("dangling_copper_net", "La pista riferisce una rete inesistente.", [t.id,t.netID]) }
            if t.layer < 0 || t.layer >= copper.layerCount { add("invalid_track_layer", "Strato della pista inesistente.", [t.id]) }
            if !ElectronicsGeometry.valid(t.width) || t.width <= 0 || t.points.count < 2 || t.points.count > 10000 ||
                !t.points.allSatisfy(ElectronicsGeometry.valid) || zip(t.points,t.points.dropFirst()).contains(where: { PCBGeometry.distance($0,$1) <= PCBGeometry.epsilon }) {
                add("invalid_track", "Pista con larghezza, punti o segmenti non validi.", [t.id])
            }
        }
        for v in copper.vias {
            if !nets.contains(v.netID) { add("dangling_copper_net", "La via riferisce una rete inesistente.", [v.id,v.netID]) }
            if !ElectronicsGeometry.valid(v.position) || !ElectronicsGeometry.valid(v.diameter) || !ElectronicsGeometry.valid(v.drill) || v.drill <= 0 || v.diameter <= v.drill {
                add("invalid_via", "Via con posizione o anello anulare non valido.", [v.id])
            }
        }
        return issues
    }
    static func mutate(_ command: PCBCommand, design: inout ElectronicsDesign, depth: Int = 0, count: inout Int) throws {
        count += 1
        guard depth < 16, count <= 1000 else { throw failure("pcb_batch_limit", "Troppi comandi nella stessa operazione.") }
        try Task.checkCancellation()
        if case .batch(let commands) = command {
            for c in commands { try mutate(c, design:&design, depth:depth+1, count:&count) }
            return
        }
        var copper = design.board.copper ?? .init()
        switch command {
        case .addTrack(let t):
            guard !copper.tracks.contains(where: { $0.id == t.id }) else { throw failure("track_exists", "Pista già presente.", [t.id]) }
            copper.tracks.append(t)
        case .updateTrack(let t):
            guard let i = copper.tracks.firstIndex(where: { $0.id == t.id }) else { throw failure("track_missing", "Pista inesistente.", [t.id]) }
            copper.tracks[i] = t
        case .removeTrack(let id):
            guard copper.tracks.contains(where: { $0.id == id }) else { throw failure("track_missing", "Pista inesistente.", [id]) }
            copper.tracks.removeAll { $0.id == id }
        case .addVia(let v):
            guard !copper.vias.contains(where: { $0.id == v.id }) else { throw failure("via_exists", "Via già presente.", [v.id]) }
            copper.vias.append(v)
        case .updateVia(let v):
            guard let i = copper.vias.firstIndex(where: { $0.id == v.id }) else { throw failure("via_missing", "Via inesistente.", [v.id]) }
            copper.vias[i] = v
        case .removeVia(let id):
            guard copper.vias.contains(where: { $0.id == id }) else { throw failure("via_missing", "Via inesistente.", [id]) }
            copper.vias.removeAll { $0.id == id }
        case let .configure(layers,rules):
            // Existing copper must retain its physical layer; bottom pads would move too.
            if layers != copper.layerCount && (!copper.tracks.isEmpty || !copper.vias.isEmpty) {
                throw failure("occupied_stackup", "Rimuovere il rame prima di cambiare il numero di strati.")
            }
            copper.layerCount = layers; copper.rules = rules
        case .batch: break
        }
        design.board.copper = copper
    }
    static func blockingIssues(before: ElectronicsDesign, after: ElectronicsDesign, issues: [ElectronicsIssue]) -> [ElectronicsIssue] {
        let old = before.board.copper ?? .init(), new = after.board.copper ?? .init()
        let changed = Set(new.tracks.filter { !old.tracks.contains($0) }.map(\.id) + new.vias.filter { !old.vias.contains($0) }.map(\.id))
        // Configuring rules diagnoses an existing board without preventing its repair.
        return issues.filter { $0.severity == .error && !changed.isDisjoint(with:$0.subjectIDs ?? []) }
    }
    /// Removes duplicate points and forward collinear bends; never removes a reversal.
    public static func simplifiedPoints(_ points: [PCBPoint]) -> [PCBPoint] {
        guard points.allSatisfy(ElectronicsGeometry.valid) else { return [] }
        var result: [PCBPoint] = []
        for p in points where result.last.map({ PCBGeometry.distance($0,p) > PCBGeometry.epsilon }) ?? true {
            if result.count >= 2 {
                let a = result[result.count-2], b = result[result.count-1]
                let cross = PCBGeometry.cross(a,b,p)
                let dot = (b.x-a.x)*(p.x-b.x)+(b.y-a.y)*(p.y-b.y)
                if abs(cross) <= PCBGeometry.epsilon, dot > 0 { result[result.count-1] = p; continue }
            }
            result.append(p)
        }
        return result
    }
    public static func gridPoint(_ point: PCBPoint, spacing: Double) -> PCBPoint? {
        guard ElectronicsGeometry.valid(point), spacing.isFinite, spacing > 0 else { return nil }
        let p = PCBPoint((point.x/spacing).rounded()*spacing,(point.y/spacing).rounded()*spacing)
        return ElectronicsGeometry.valid(p) ? p : nil
    }
    /// Deterministic octilinear leg. Obstacles are diagnosed; no automatic shove or walkaround.
    public static func routePoints(from a: PCBPoint, to b: PCBPoint, diagonalFirst: Bool = true) -> [PCBPoint] {
        guard ElectronicsGeometry.valid(a), ElectronicsGeometry.valid(b) else { return [] }
        let x = b.x-a.x, y = b.y-a.y, step = min(abs(x),abs(y))
        let dx = x < 0 ? -step : step, dy = y < 0 ? -step : step
        let middle = diagonalFirst ? PCBPoint(a.x+dx,a.y+dy) : PCBPoint(b.x-dx,b.y-dy)
        var result = [a]
        for p in [middle,b] where PCBGeometry.distance(result.last!,p) > PCBGeometry.epsilon { result.append(p) }
        return result
    }
}
