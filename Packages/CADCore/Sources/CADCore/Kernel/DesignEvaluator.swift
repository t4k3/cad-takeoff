import CryptoKit
import Foundation

/// Runs the active history in order and produces the bodies of the design (phase 3, T84).
/// A `newBody` feature starts a body; `join`, `cut`, `intersect` modify the bodies they touch.
/// Bodies never touched by a boolean keep the kernel's exact snapshot (same face/edge IDs).
public enum DesignEvaluator {
    public struct Body: Sendable {
        /// ID of the feature that created the body (name, colour and visibility come from it).
        public let id: UUID
        public let source: Feature
        /// Features that modified the body after its creation, in order.
        public let modifiedBy: [UUID]
        public let mesh: Mesh
        public let snapshot: BodySnapshot
        /// Where the body's own coordinates are in the design (its placement, then any Sposta or
        /// joint): joints store their points in own coordinates through its inverse.
        public var placement: RigidMotion = .identity
        public var isVisible: Bool { source.isVisible }
    }

    public struct Issue: Sendable, Equatable {
        public let featureID: UUID
        public let message: String
    }

    /// Reads a component's design by its library path (the app provides it; nil = not found).
    public typealias ComponentResolver = @Sendable (String) -> CADDocument?

    /// `cache`: reuse the state after an unchanged prefix of the history (editing the last steps
    /// or previewing a new one does not recompute the earlier booleans).
    /// `progress(done, total)`: history steps evaluated so far (for a progress bar while opening).
    public static func evaluate(_ doc: CADDocument, revision: String, components: ComponentResolver? = nil,
                                cache: EvaluationCache? = nil,
                                progress: (@Sendable (Int, Int) -> Void)? = nil) -> (bodies: [Body], issues: [Issue]) {
        evaluate(doc, revision: revision, components: components, depth: 0, cache: cache, progress: progress)
    }

    /// A body while the history runs.
    struct Work: Sendable {
        var source: Feature; var snapshot: BodySnapshot; var solid: CSGSolid?; var mesh: Mesh; var modifiedBy: [UUID]
        /// Rigid motion applied after the source placed it (Sposta, giunti): where its own
        /// coordinates are now is `motion` after the source's placement.
        var motion: RigidMotion = .identity
    }

    private static func evaluate(_ doc: CADDocument, revision: String, components: ComponentResolver?, depth: Int,
                                 cache: EvaluationCache? = nil,
                                 progress: (@Sendable (Int, Int) -> Void)? = nil) -> (bodies: [Body], issues: [Issue]) {
        var bodies: [Work] = []
        var issues: [Issue] = []
        let features = doc.activeFeatures
        // A damaged file with the same ID twice: exclude every copy, never guess which one is meant.
        let counts = Dictionary(grouping: features, by: \.id).mapValues(\.count)
        var reported = Set<UUID>()
        // Prefix keys (every step and, for components, the file it reads) and the longest cached prefix.
        // (Not for a damaged file with duplicate IDs: excluding them depends on the whole history.)
        let cacheable = cache != nil && counts.values.allSatisfy { $0 == 1 }
        let keys = cacheable ? EvaluationCache.prefixKeys(features, components: components) : []
        var start = 0
        if cacheable, let cache, let (k, state) = cache.longestPrefix(keys) {
            bodies = state.bodies; issues = state.issues; reported = state.reported; start = k + 1
        }
        for (k, original) in features.enumerated() where k >= start {
            progress?(k, features.count)
            let feature = throughAll(original, bodies: bodies)
            defer { if let cache, k < keys.count { cache.store(keys[k], .init(bodies: bodies, issues: issues, reported: reported)) } }
            guard counts[feature.id] == 1 else {
                if reported.insert(feature.id).inserted {
                    issues.append(.init(featureID: feature.id, message: "Identificatore di parte duplicato nel documento."))
                }
                continue
            }
            if case let .hole(spec) = feature.kind {
                do { try spec.validate() } catch {
                    issues.append(.init(featureID: feature.id, message: error.localizedDescription)); continue
                }
                // Through-all depth: how far the bodies extend along the hole axis past the start
                // face, plus 1 mm. Kept tight: very long skinny tool faces hurt BSP precision.
                let axis = spec.direction.normalized
                var reach = 1.0
                for box in bodies.compactMap({ bounds($0.snapshot) }) {
                    for c in spec.centers {
                        for x in [box.min.x, box.max.x] { for y in [box.min.y, box.max.y] { for z in [box.min.z, box.max.z] {
                            reach = max(reach, (Vec3(x, y, z) - c).dot(axis) + 1)
                        } } }
                    }
                }
                let tool = HoleGeometry.solid(spec, featureID: feature.id, throughDepth: reach)
                let toolBox = bounds(tool)
                let touched = bodies.indices.filter { overlaps(bounds(bodies[$0].snapshot), toolBox) }
                if touched.isEmpty {
                    issues.append(.init(featureID: feature.id, message: "Foro senza effetto: non tocca nessun corpo."))
                }
                for i in touched.reversed() {
                    let solid = solidOf(bodies[i]).subtracting(tool)
                    if solid.isEmpty { bodies.remove(at: i) } else { bodies[i] = rebuilt(bodies[i], solid, by: feature.id, revision: revision) }
                }
                continue
            }
            if case let .chamfer(spec) = feature.kind {
                do { try spec.validate() } catch {
                    issues.append(.init(featureID: feature.id, message: error.localizedDescription)); continue
                }
                // Each edge belongs to the body that still has it (faces keep their IDs through booleans).
                var perBody: [Int: [(Int, EdgeInfo)]] = [:]
                var missing = 0
                for (k, ref) in spec.edges.enumerated() {
                    if let hit = bodies.indices.lazy.compactMap({ i in ChamferGeometry.resolve(ref, in: bodies[i].snapshot).map { (i, $0) } }).first {
                        perBody[hit.0, default: []].append((k, hit.1))
                    } else { missing += 1 }
                }
                if missing > 0 {
                    issues.append(.init(featureID: feature.id, message: missing == spec.edges.count
                        ? "Smusso senza effetto: gli spigoli scelti non esistono più (la geometria è cambiata)."
                        : "Smusso: \(missing) spigoli su \(spec.edges.count) non esistono più."))
                }
                for i in perBody.keys.sorted(by: >) {
                    // Convex edges: material removed; concave (inside corners): material added.
                    var remove: CSGSolid?, add: CSGSolid?
                    for (k, edge) in perBody[i]! where !ChamferGeometry.isNearlyFlat(edge, in: bodies[i].snapshot, spec: spec) {
                        do {
                            let t = try ChamferGeometry.tool(for: edge, ref: spec.edges[k], spec: spec, snapshot: bodies[i].snapshot,
                                                             featureID: feature.id, index: k)
                            if t.adds { add = add.map { $0.union(t.solid) } ?? t.solid }
                            else { remove = remove.map { $0.union(t.solid) } ?? t.solid }
                        } catch {
                            issues.append(.init(featureID: feature.id, message: error.localizedDescription))
                        }
                    }
                    guard remove != nil || add != nil else { continue }
                    var solid = solidOf(bodies[i])
                    if let remove { solid = solid.subtracting(remove) }
                    // Square corners where three rounds meet: a ball, as in Fusion.
                    if let corners = ChamferGeometry.cornerTool(edges: perBody[i]!.map(\.1), spec: spec, snapshot: bodies[i].snapshot, featureID: feature.id) {
                        solid = solid.subtracting(corners)
                    }
                    if let add { solid = solid.union(add) }
                    if solid.isEmpty { bodies.remove(at: i) } else { bodies[i] = rebuilt(bodies[i], solid, by: feature.id, revision: revision) }
                }
                continue
            }
            if case let .move(spec) = feature.kind {
                do { try spec.validate() } catch {
                    issues.append(.init(featureID: feature.id, message: error.localizedDescription)); continue
                }
                let targets = bodies.indices.filter { spec.bodies.contains(bodies[$0].source.id) }
                guard !targets.isEmpty else {
                    issues.append(.init(featureID: feature.id, message: "Sposta: i corpi scelti non esistono (devono venire prima nella timeline)."))
                    continue
                }
                // Pivot: the centre of all the moved bodies together.
                let boxes = targets.compactMap { bounds(bodies[$0].snapshot) }
                let centre = spec.pivot ?? boxes.dropFirst().reduce(boxes.first!) { a, b in
                    BoundingBox(min: Vec3(Swift.min(a.min.x, b.min.x), Swift.min(a.min.y, b.min.y), Swift.min(a.min.z, b.min.z)),
                                max: Vec3(Swift.max(a.max.x, b.max.x), Swift.max(a.max.y, b.max.y), Swift.max(a.max.z, b.max.z)))
                }.center
                let (point, direction) = spec.transform(pivot: centre)
                let motion = RigidMotion(c0: direction(Vec3(1, 0, 0)), c1: direction(Vec3(0, 1, 0)), c2: direction(Vec3(0, 0, 1)), t: point(.zero))
                for i in targets { bodies[i] = moved(bodies[i], by: motion, feature: feature.id, revision: revision) }
                continue
            }
            if case let .joint(spec) = feature.kind {
                do { try spec.validate() } catch {
                    issues.append(.init(featureID: feature.id, message: error.localizedDescription)); continue
                }
                guard let b = bodies.firstIndex(where: { $0.source.id == spec.moving }) else {
                    issues.append(.init(featureID: feature.id, message: "Giunto: il pezzo da unire non esiste (deve venire prima nella timeline)."))
                    continue
                }
                var fixedNow: RigidMotion?
                if let fixed = spec.fixed {
                    guard let f = bodies.first(where: { $0.source.id == fixed }) else {
                        issues.append(.init(featureID: feature.id, message: "Giunto: il pezzo di riferimento non esiste (deve venire prima nella timeline)."))
                        continue
                    }
                    fixedNow = f.motion.after(f.source.placementMotion)
                }
                let w = bodies[b]
                let motion = spec.motion(movingNow: w.motion.after(w.source.placementMotion), fixedNow: fixedNow)
                bodies[b] = moved(w, by: motion, feature: feature.id, revision: revision)
                continue
            }
            if case let .combine(spec) = feature.kind {
                do { try spec.validate() } catch {
                    issues.append(.init(featureID: feature.id, message: error.localizedDescription)); continue
                }
                guard let target = bodies.firstIndex(where: { $0.source.id == spec.target }) else {
                    issues.append(.init(featureID: feature.id, message: "Combina: il corpo obiettivo non esiste (deve venire prima nella timeline)."))
                    continue
                }
                let tools = bodies.indices.filter { spec.tools.contains(bodies[$0].source.id) }
                guard !tools.isEmpty else {
                    issues.append(.init(featureID: feature.id, message: "Combina: i corpi strumento non esistono (devono venire prima nella timeline)."))
                    continue
                }
                if tools.count < spec.tools.count {
                    issues.append(.init(featureID: feature.id, message: "Combina: \(spec.tools.count - tools.count) corpi strumento non esistono più."))
                }
                var solid = solidOf(bodies[target])
                for i in tools {
                    let tool = solidOf(bodies[i])
                    switch spec.operation {
                    case .join: solid = solid.union(tool)
                    case .cut: solid = solid.subtracting(tool)
                    case .intersect: solid = solid.intersecting(tool)
                    }
                }
                let result = rebuilt(bodies[target], solid, by: feature.id, revision: revision)
                let empty = solid.isEmpty
                let removed = (spec.keepTools ? [] : tools) + (empty ? [target] : [])
                if !empty { bodies[target] = result }
                for i in removed.sorted(by: >) { bodies.remove(at: i) }
                if empty { issues.append(.init(featureID: feature.id, message: "Combina: non resta niente del corpo obiettivo.")) }
                continue
            }
            if case let .shell(spec) = feature.kind {
                // The body with the open faces (they keep their IDs through booleans), else the named one.
                let i = spec.openFaces.first.flatMap { face in bodies.firstIndex { $0.snapshot.faces.contains { $0.id == face } } }
                    ?? bodies.firstIndex { $0.source.id == spec.body }
                guard let i else {
                    issues.append(.init(featureID: feature.id, message: "Guscio: il corpo o le facce scelte non esistono più."))
                    continue
                }
                do {
                    let cavity = try ShellGeometry.cavity(of: bodies[i].snapshot, spec: spec, featureID: feature.id)
                    let solid = solidOf(bodies[i]).subtracting(cavity)
                    if solid.isEmpty { bodies.remove(at: i) } else { bodies[i] = rebuilt(bodies[i], solid, by: feature.id, revision: revision) }
                } catch {
                    issues.append(.init(featureID: feature.id, message: error.localizedDescription))
                }
                continue
            }
            if case let .split(spec) = feature.kind {
                guard spec.offset.isFinite, let i = bodies.firstIndex(where: { $0.source.id == spec.body }),
                      let box = bounds(bodies[i].snapshot) else {
                    issues.append(.init(featureID: feature.id, message: "Dividi: il corpo da dividere non esiste (deve venire prima nella timeline)."))
                    continue
                }
                let n = spec.axis
                let lo = box.min.dot(n), hi = box.max.dot(n)
                guard spec.offset > lo + 1e-6, spec.offset < hi - 1e-6 else {
                    issues.append(.init(featureID: feature.id, message: "Dividi: il piano non attraversa il corpo (va tra \(String(format: "%.1f", lo)) e \(String(format: "%.1f", hi)) mm)."))
                    continue
                }
                // Half-space as a box beyond the body on the positive side of the plane.
                let pad = 10.0
                var a = box.min - Vec3(pad, pad, pad), b = box.max + Vec3(pad, pad, pad)
                switch spec.plane {
                case .yz: a.x = spec.offset
                case .xz: a.y = spec.offset
                case .xy: a.z = spec.offset
                }
                let halfSpace = CSGSolid(boxSolid(a, b, prefix: "split:\(feature.id.uuidString)"))
                let whole = solidOf(bodies[i])
                let positive = whole.intersecting(halfSpace), negative = whole.subtracting(halfSpace)
                switch spec.keep {
                case .negative:
                    bodies[i] = rebuilt(bodies[i], negative, by: feature.id, revision: revision)
                case .positive:
                    bodies[i] = rebuilt(bodies[i], positive, by: feature.id, revision: revision)
                case .both:
                    bodies[i] = rebuilt(bodies[i], negative, by: feature.id, revision: revision)
                    let (mesh, triFace) = positive.triangulated()
                    bodies.append(Work(source: feature, snapshot: snapshot(of: positive, mesh: mesh, triangleFace: triFace, bodyID: feature.id, revision: revision),
                                       solid: positive, mesh: mesh, modifiedBy: []))
                }
                continue
            }
            if case let .pattern(spec) = feature.kind {
                do { try spec.validate() } catch {
                    issues.append(.init(featureID: feature.id, message: error.localizedDescription)); continue
                }
                guard let i = bodies.firstIndex(where: { $0.source.id == spec.body }) else {
                    // A pattern of a feature (a row of holes, cuts or bosses): its tool repeated
                    // with its own operation on the bodies it reaches.
                    if let source = features.prefix(k).first(where: { $0.id == spec.body }),
                       let tool = toolSolid(of: source, bodies: bodies, revision: revision) {
                        let (copies, reflect) = spec.transforms()
                        var all: CSGSolid?
                        for (c, t) in copies.enumerated() {
                            let piece = tool.transformed(point: t.point, direction: t.direction, reflect: reflect, prefix: "pat:\(feature.id.uuidString)/\(c)/")
                            all = all.map { $0.union(piece) } ?? piece
                        }
                        guard let all, !all.isEmpty else { continue }
                        let op: BooleanOperation = if case .hole = source.kind { .cut } else { source.operation }
                        let toolBox = bounds(all)
                        let touched = bodies.indices.filter { overlaps(bounds(bodies[$0].snapshot), toolBox) }
                        switch op {
                        case .join:
                            if let first = touched.first {
                                var solid = solidOf(bodies[first]).union(all)
                                for other in touched.dropFirst() { solid = solid.union(solidOf(bodies[other])) }
                                bodies[first] = rebuilt(bodies[first], solid, by: feature.id, revision: revision)
                                for other in touched.dropFirst().reversed() { bodies.remove(at: other) }
                            }
                        case .cut, .intersect:
                            for b in touched.reversed() {
                                let solid = op == .cut ? solidOf(bodies[b]).subtracting(all) : solidOf(bodies[b]).intersecting(all)
                                if solid.isEmpty { bodies.remove(at: b) } else { bodies[b] = rebuilt(bodies[b], solid, by: feature.id, revision: revision) }
                            }
                        case .newBody:
                            break
                        }
                        continue
                    }
                    issues.append(.init(featureID: feature.id, message: "\(spec.kind.label): il corpo da copiare non esiste (deve venire prima nella timeline)."))
                    continue
                }
                let source = bodies[i]
                let (copies, reflect) = spec.transforms()
                let placed = copies.enumerated().map { k, t in
                    Placed(mesh: source.mesh, snapshot: source.snapshot, prefix: "pat:\(feature.id.uuidString)/\(k)/",
                           point: t.point, direction: t.direction, reflect: reflect)
                }
                if spec.join {
                    // Joined to the original: one boolean union.
                    let copiesSolid = CSGSolid(merged(placed, bodyID: source.source.id, revision: revision).snapshot)
                    bodies[i] = rebuilt(bodies[i], solidOf(source).union(copiesSolid), by: feature.id, revision: revision)
                } else {
                    // One new body; overlapping copies are united so the result stays a clean solid.
                    let boxes = placed.map { p in bounds(BodySnapshot(bodyID: feature.id, revision: "", positions: p.snapshot.positions.map(p.point),
                                                                      normals: [], triangles: [], triangleFace: [], triangleTopologyFace: [],
                                                                      faces: [], edges: [], maximumSurfaceDeviation: 0)) }
                    let overlapping = boxes.indices.contains { a in boxes.indices.contains { b in a < b && overlaps(boxes[a], boxes[b]) } }
                    if overlapping {
                        var solid: CSGSolid?
                        for p in placed {
                            let piece = CSGSolid(merged([p], bodyID: feature.id, revision: revision).snapshot)
                            solid = solid.map { $0.union(piece) } ?? piece
                        }
                        let (mesh, triFace) = solid!.triangulated()
                        bodies.append(Work(source: feature, snapshot: snapshot(of: solid!, mesh: mesh, triangleFace: triFace, bodyID: feature.id, revision: revision),
                                           solid: solid, mesh: mesh, modifiedBy: []))
                    } else {
                        let m = merged(placed, bodyID: feature.id, revision: revision)
                        bodies.append(Work(source: feature, snapshot: m.snapshot, solid: nil, mesh: m.mesh, modifiedBy: []))
                    }
                }
                continue
            }
            // The feature's own solid: exact kernel B-rep for primitives, CSG for sheet metal,
            // the referenced design for a component.
            let fresh: Work
            if case let .component(ref) = feature.kind {
                guard depth < 8 else {
                    issues.append(.init(featureID: feature.id, message: "Componente «\(ref.partName)»: riferimento circolare o annidato troppo in profondità."))
                    continue
                }
                guard let child = components?(ref.path) else {
                    issues.append(.init(featureID: feature.id, message: "Componente non trovato: \(ref.path)"))
                    continue
                }
                let result = evaluate(child, revision: revision, components: components, depth: depth + 1)
                // Problems inside the part surface on the component (circular references included).
                if let first = result.issues.first {
                    issues.append(.init(featureID: feature.id, message: first.message.hasPrefix("Componente")
                        ? first.message : "Nel componente «\(ref.partName)»: \(first.message)"))
                }
                let inner = result.bodies.filter(\.isVisible)
                guard !inner.isEmpty else {
                    if result.issues.isEmpty {
                        issues.append(.init(featureID: feature.id, message: "Il componente «\(ref.partName)» non ha corpi visibili."))
                    }
                    continue
                }
                let placed = placeComponent(inner, ref: ref, position: feature.position, bodyID: feature.id, revision: revision)
                fresh = Work(source: feature, snapshot: placed.snapshot, solid: nil, mesh: placed.mesh, modifiedBy: [])
            } else if case let .importedMesh(imported) = feature.kind {
                var (solid, mesh, triFace) = MeshFaces.faces(imported.mesh.translated(by: feature.position), featureID: feature.id)
                // Seams with duplicated vertices: the full clean-up welds them (slow, so only then).
                if !MeshValidator.validate(mesh).isWatertight { (mesh, triFace) = solid.triangulated() }
                if !MeshValidator.validate(mesh).isWatertight {
                    issues.append(.init(featureID: feature.id, message: "Mesh importata non chiusa: si vede e si esporta, ma fori e tagli potrebbero non riuscire."))
                }
                fresh = Work(source: feature, snapshot: snapshot(of: solid, mesh: mesh, triangleFace: triFace, bodyID: feature.id, revision: revision),
                             solid: solid, mesh: mesh, modifiedBy: [])
            } else if case let .sheetMetal(spec) = feature.kind {
                let solid: CSGSolid
                do { solid = try SheetMetalGeometry.build(spec, featureID: feature.id, position: feature.position).folded } catch {
                    issues.append(.init(featureID: feature.id, message: error.localizedDescription)); continue
                }
                let (mesh, triFace) = solid.triangulated()
                fresh = Work(source: feature, snapshot: snapshot(of: solid, mesh: mesh, triangleFace: triFace, bodyID: feature.id, revision: revision),
                             solid: solid, mesh: mesh, modifiedBy: [])
            } else if case let .revolve(spec) = feature.kind {
                let solid: CSGSolid
                do { solid = try Revolve.build(spec, holes: feature.holes, featureID: feature.id, position: feature.position) } catch {
                    issues.append(.init(featureID: feature.id, message: error.localizedDescription)); continue
                }
                let (mesh, triFace) = solid.triangulated()
                fresh = Work(source: feature, snapshot: snapshot(of: solid, mesh: mesh, triangleFace: triFace, bodyID: feature.id, revision: revision),
                             solid: solid, mesh: mesh, modifiedBy: [])
            } else if !feature.holes.isEmpty {
                let solid: CSGSolid
                do { solid = try PrimitiveKernel.solidWithHoles(feature, revision: revision) } catch {
                    issues.append(.init(featureID: feature.id, message: error.localizedDescription)); continue
                }
                let (mesh, triFace) = solid.triangulated()
                fresh = Work(source: feature, snapshot: snapshot(of: solid, mesh: mesh, triangleFace: triFace, bodyID: feature.id, revision: revision),
                             solid: solid, mesh: mesh, modifiedBy: [])
            } else {
                let brep: BRepBody
                do { brep = try PrimitiveKernel.build(feature) } catch {
                    issues.append(.init(featureID: feature.id, message: error.localizedDescription)); continue
                }
                fresh = Work(source: feature, snapshot: brep.snapshot(revision: revision), solid: nil, mesh: brep.mesh, modifiedBy: [])
            }
            let snap = fresh.snapshot
            guard feature.operation != .newBody else { bodies.append(fresh); continue }
            let tool = solidOf(fresh)
            let toolBox = bounds(snap)
            let touched = bodies.indices.filter { overlaps(bounds(bodies[$0].snapshot), toolBox) }
            switch feature.operation {
            case .newBody:
                break
            case .join:
                guard let first = touched.first else {
                    // Touches nothing: behaves like a new body (as in Fusion).
                    bodies.append(fresh)
                    continue
                }
                var solid = solidOf(bodies[first]).union(tool)
                for other in touched.dropFirst() { solid = solid.union(solidOf(bodies[other])) }
                bodies[first] = rebuilt(bodies[first], solid, by: feature.id, revision: revision)
                for other in touched.dropFirst().reversed() { bodies.remove(at: other) }
            case .cut, .intersect:
                if touched.isEmpty {
                    issues.append(.init(featureID: feature.id, message: feature.operation == .cut
                        ? "Taglio senza effetto: non tocca nessun corpo." : "Intersezione senza effetto: non tocca nessun corpo."))
                }
                for i in touched.reversed() {
                    let before = solidOf(bodies[i])
                    let solid = feature.operation == .cut ? before.subtracting(tool) : before.intersecting(tool)
                    if solid.isEmpty { bodies.remove(at: i) } else { bodies[i] = rebuilt(bodies[i], solid, by: feature.id, revision: revision) }
                }
            }
        }
        // Bodies reused from the cache carry the revision they were computed at: stamp the current one.
        let out = bodies.map { Body(id: $0.source.id, source: $0.source, modifiedBy: $0.modifiedBy, mesh: $0.mesh,
                                    snapshot: $0.snapshot.revision == revision ? $0.snapshot : $0.snapshot.stamped(revision),
                                    placement: $0.motion.after($0.source.placementMotion)) }
        return (out, issues)

        func solidOf(_ w: Work) -> CSGSolid { w.solid ?? CSGSolid(w.snapshot) }
        /// An extrusion «through all»: its height reaches 1 mm past every body before it, along the
        /// extrusion (both ways when symmetric).
        func throughAll(_ f: Feature, bodies: [Work]) -> Feature {
            guard f.throughAll || f.untilFace != nil, case let .extrude(profile, height) = f.kind else { return f }
            let base: Vec3, dir: Vec3
            if let p = f.placement { base = p.plane.origin + f.position; dir = p.reversed ? -p.plane.normal : p.plane.normal }
            else { base = f.position; dir = Vec3(0, 0, 1) }
            // Up to a face: the distance from the sketch plane to that plane, along the extrusion.
            if let target = f.untilFace {
                for b in bodies {
                    guard let face = b.snapshot.faces.first(where: { $0.id == target }), case let .plane(o, _) = face.surface else { continue }
                    let d = (o - base).dot(dir)
                    var g = f
                    if d > 1e-6 { g.kind = .extrude(profile: profile, height: d) }
                    return g
                }
                return f
            }
            var reach = 0.0
            for box in bodies.compactMap({ bounds($0.snapshot) }) {
                for x in [box.min.x, box.max.x] { for y in [box.min.y, box.max.y] { for z in [box.min.z, box.max.z] {
                    let d = (Vec3(x, y, z) - base).dot(dir)
                    reach = max(reach, f.symmetric ? 2 * abs(d) : d)
                } } }
            }
            var g = f
            g.kind = .extrude(profile: profile, height: reach > 0 ? reach + (f.symmetric ? 2 : 1) : height)
            return g
        }
        /// The solid a feature adds or removes (for patterns of features): holes through the
        /// bodies there are now, other features as built.
        func toolSolid(of f: Feature, bodies: [Work], revision: String) -> CSGSolid? {
            if case let .hole(spec) = f.kind {
                let axis = spec.direction.normalized
                var reach = 1.0
                for box in bodies.compactMap({ bounds($0.snapshot) }) {
                    for c in spec.centers {
                        for x in [box.min.x, box.max.x] { for y in [box.min.y, box.max.y] { for z in [box.min.z, box.max.z] {
                            reach = max(reach, (Vec3(x, y, z) - c).dot(axis) + 1)
                        } } }
                    }
                }
                return HoleGeometry.solid(spec, featureID: f.id, throughDepth: reach)
            }
            guard f.operation != .newBody else { return nil }
            if case let .revolve(spec) = f.kind { return try? Revolve.build(spec, holes: f.holes, featureID: f.id, position: f.position) }
            if !f.holes.isEmpty { return try? PrimitiveKernel.solidWithHoles(f, revision: revision) }
            return (try? PrimitiveKernel.build(f)).map { CSGSolid($0.snapshot(revision: revision)) }
        }
        /// The body moved rigidly (IDs kept); its motion remembered for later joints.
        func moved(_ w: Work, by motion: RigidMotion, feature id: UUID, revision: String) -> Work {
            let m = merged([Placed(mesh: w.mesh, snapshot: w.snapshot, prefix: "", point: motion.point, direction: motion.direction, reflect: false)],
                           bodyID: w.source.id, revision: revision)
            return Work(source: w.source, snapshot: m.snapshot, solid: nil, mesh: m.mesh, modifiedBy: w.modifiedBy + [id], motion: motion.after(w.motion))
        }
        func rebuilt(_ w: Work, _ solid: CSGSolid, by id: UUID, revision: String) -> Work {
            let (mesh, triFace) = solid.triangulated()
            return Work(source: w.source, snapshot: snapshot(of: solid, mesh: mesh, triangleFace: triFace, bodyID: w.source.id, revision: revision),
                        solid: solid, mesh: mesh, modifiedBy: w.modifiedBy + [id], motion: w.motion)
        }
    }

    /// Axis-aligned box as a snapshot with one named face per side (the cut face is a plane).
    static func boxSolid(_ a: Vec3, _ b: Vec3, prefix: String) -> BodySnapshot {
        let f = Feature(name: "box", kind: .box(width: b.x - a.x, depth: b.y - a.y, height: b.z - a.z),
                        position: Vec3((a.x + b.x) / 2, (a.y + b.y) / 2, a.z))
        let snap = (try? PrimitiveKernel.build(f))!.snapshot(revision: "")
        // Rename the faces so they cannot collide with the body's own.
        let faces = snap.faces.map { FaceInfo(id: FaceID(rawValue: prefix + "/" + ($0.id.rawValue.split(separator: "/").last.map(String.init) ?? "f")),
                                              surface: $0.surface, area: $0.area, topologyFaceIDs: []) }
        return BodySnapshot(bodyID: snap.bodyID, revision: "", positions: snap.positions, normals: snap.normals, triangles: snap.triangles,
                            triangleFace: snap.triangleFace, triangleTopologyFace: snap.triangleTopologyFace, faces: faces, edges: [],
                            maximumSurfaceDeviation: 0)
    }

    // MARK: Components

    /// The component's bodies moved into place and merged into one body (faces keep their IDs,
    /// prefixed per inner body so they stay unique).
    static func placeComponent(_ inner: [Body], ref: ComponentRef, position: Vec3, bodyID: UUID, revision: String) -> (mesh: Mesh, snapshot: BodySnapshot) {
        merged(inner.map { b in
            Placed(mesh: b.mesh, snapshot: b.snapshot, prefix: "comp:\(b.id.uuidString)/",
                   point: { ref.rotate($0) + position }, direction: { ref.rotate($0) }, reflect: false)
        }, bodyID: bodyID, revision: revision)
    }

    /// One body's geometry moved by a rigid motion (a reflection flips the winding).
    struct Placed {
        let mesh: Mesh
        let snapshot: BodySnapshot
        /// Keeps face and edge IDs unique among the merged copies.
        let prefix: String
        let point: (Vec3) -> Vec3
        let direction: (Vec3) -> Vec3
        let reflect: Bool
    }

    /// Several placed bodies merged into one body (exact surfaces moved along).
    static func merged(_ parts: [Placed], bodyID: UUID, revision: String) -> (mesh: Mesh, snapshot: BodySnapshot) {
        var mesh = Mesh()
        var positions: [Vec3] = [], normals: [Vec3] = [], triangles: [UInt32] = [], triangleFace: [UInt32] = []
        var topology: [FaceID] = [], faces: [FaceInfo] = [], edges: [EdgeInfo] = []
        var deviation = 0.0
        for part in parts {
            let point = part.point, direction = part.direction
            func surface(_ s: SurfaceDescriptor) -> SurfaceDescriptor {
                switch s {
                case let .plane(o, n): .plane(origin: point(o), normal: direction(n))
                case let .cylinder(o, a, r): .cylinder(axisOrigin: point(o), axisDirection: direction(a), radius: r)
                case let .cone(apex, a, h): .cone(apex: point(apex), axisDirection: direction(a), halfAngle: h)
                case .freeform: .freeform
                case let .torus(c, a, R, r): .torus(center: point(c), axisDirection: direction(a), majorRadius: R, minorRadius: r)
                case let .sphere(c, r): .sphere(center: point(c), radius: r)
                }
            }
            func fid(_ f: FaceID) -> FaceID { FaceID(rawValue: part.prefix + f.rawValue) }
            // A mirror image turns the triangles inside out unless their order is reversed.
            func wound(_ idx: [UInt32], offset: UInt32) -> [UInt32] {
                guard part.reflect else { return idx.map { $0 + offset } }
                var out = idx
                for t in 0..<(idx.count / 3) { out[t * 3 + 1] = idx[t * 3 + 2]; out[t * 3 + 2] = idx[t * 3 + 1] }
                return out.map { $0 + offset }
            }
            let base = UInt32(mesh.vertices.count)
            mesh.vertices += part.mesh.vertices.map(point)
            mesh.indices += wound(part.mesh.indices, offset: base)
            let s = part.snapshot
            let p0 = UInt32(positions.count), f0 = UInt32(faces.count)
            positions += s.positions.map(point)
            normals += s.normals.map(direction)
            triangles += wound(s.triangles, offset: p0)
            triangleFace += s.triangleFace.map { $0 + f0 }
            topology += s.triangleTopologyFace.map(fid)
            faces += s.faces.map { FaceInfo(id: fid($0.id), surface: surface($0.surface), area: $0.area, topologyFaceIDs: $0.topologyFaceIDs.map(fid)) }
            edges += s.edges.map { e in
                EdgeInfo(id: EdgeID(rawValue: part.prefix + e.id.rawValue), polyline: e.polyline.map(point), isSharp: e.isSharp,
                         faces: e.faces.map(fid), topologyEdgeIDs: e.topologyEdgeIDs.map { EdgeID(rawValue: part.prefix + $0.rawValue) },
                         curve: e.curve?.mapped(point: point, direction: direction))
            }
            deviation = max(deviation, s.maximumSurfaceDeviation)
        }
        return (mesh, BodySnapshot(bodyID: bodyID, revision: revision, positions: positions, normals: normals, triangles: triangles,
                                   triangleFace: triangleFace, triangleTopologyFace: topology, faces: faces, edges: edges,
                                   maximumSurfaceDeviation: deviation))
    }

    // MARK: Snapshot of a boolean result

    /// Renderer/selection data for a CSG result: faces keep the IDs and exact surfaces of the
    /// faces they came from; edges are the boundaries between different faces.
    static func snapshot(of solid: CSGSolid, mesh: Mesh, triangleFace: [Int], bodyID: UUID, revision: String) -> BodySnapshot {
        // Faces actually present, in first-use order.
        var faceOrder: [Int] = [], faceSlot: [Int: Int] = [:]
        for f in triangleFace where faceSlot[f] == nil { faceSlot[f] = faceOrder.count; faceOrder.append(f) }
        var areas = [Double](repeating: 0, count: faceOrder.count)
        var positions: [Vec3] = [], normals: [Vec3] = [], tris: [UInt32] = [], triFace: [UInt32] = []
        for t in 0..<mesh.triangleCount {
            let (a, b, c) = mesh.triangle(t)
            let slot = faceSlot[triangleFace[t]]!
            let face = solid.faces[triangleFace[t]]
            areas[slot] += (b - a).cross(c - a).length / 2
            let flat = (b - a).cross(c - a).normalized
            for v in [a, b, c] {
                tris.append(UInt32(positions.count))
                positions.append(v)
                normals.append(smoothNormal(face, at: v) ?? flat)
            }
            triFace.append(UInt32(slot))
        }
        let infos = faceOrder.enumerated().map { slot, f -> FaceInfo in
            let face = solid.faces[f]
            return FaceInfo(id: face.flipped ? FaceID(rawValue: face.id.rawValue + "/inv") : face.id,
                            surface: surface(face), area: areas[slot], topologyFaceIDs: [])
        }
        let edges = boundaryEdges(mesh: mesh, triangleFace: triangleFace.map { faceSlot[$0]! }, faces: infos, bodyID: bodyID)
        return BodySnapshot(bodyID: bodyID, revision: revision, positions: positions, normals: normals, triangles: tris,
                            triangleFace: triFace, triangleTopologyFace: triFace.map { infos[Int($0)].id },
                            faces: infos, edges: edges, maximumSurfaceDeviation: 0)
    }

    private static func surface(_ f: CSGFace) -> SurfaceDescriptor {
        switch f.surface {
        case let .plane(o, n): .plane(origin: o, normal: f.flipped ? -n : n)
        case .cylinder, .cone, .torus, .sphere, .freeform: f.surface
        }
    }

    private static func smoothNormal(_ f: CSGFace, at p: Vec3) -> Vec3? {
        switch f.surface {
        case let .cylinder(o, axis, _):
            let d = p - o
            let radial = (d - axis * d.dot(axis)).normalized
            return f.flipped ? -radial : radial
        case let .cone(apex, axis, half):
            let d = p - apex
            let radial = (d - axis * d.dot(axis)).normalized
            let n = (radial * cos(half) - axis * sin(half)).normalized
            return f.flipped ? -n : n
        case let .torus(centre, axis, major, _):
            let d = p - centre
            let ring = centre + (d - axis * d.dot(axis)).normalized * major
            let n = (p - ring).normalized
            return f.flipped ? -n : n
        case let .sphere(c, _):
            let n = (p - c).normalized
            return f.flipped ? -n : n
        case .plane, .freeform:
            return nil
        }
    }

    /// Edges between triangles of different faces, chained into polylines per face pair.
    private static func boundaryEdges(mesh: Mesh, triangleFace: [Int], faces: [FaceInfo], bodyID: UUID) -> [EdgeInfo] {
        struct Key: Hashable { let a: UInt32, b: UInt32 }
        var owners: [Key: [Int]] = [:]
        for t in 0..<mesh.triangleCount {
            for k in 0..<3 {
                let a = mesh.indices[t * 3 + k], b = mesh.indices[t * 3 + (k + 1) % 3]
                owners[Key(a: min(a, b), b: max(a, b)), default: []].append(t)
            }
        }
        var byPair: [[Int]: [(UInt32, UInt32)]] = [:]
        for (k, ts) in owners {
            let fs = Set(ts.map { triangleFace[$0] })
            guard fs.count > 1 else { continue }
            // Coplanar faces from different features (e.g. a rib joined flush with a plate) read
            // as one surface: no visible edge between them.
            if fs.count == 2, case let .plane(o1, n1)? = faces[safe: fs.first!]?.surface,
               case let .plane(o2, n2)? = faces[safe: fs.dropFirst().first!]?.surface,
               n1.dot(n2) > 1 - 1e-9, abs((o2 - o1).dot(n1)) < 1e-6 { continue }
            byPair[fs.sorted(), default: []].append((k.a, k.b))
        }
        var edges: [EdgeInfo] = []
        for (pair, segments) in byPair.sorted(by: { $0.key.lexicographicallyPrecedes($1.key) }) {
            for (n, chain) in chains(segments).enumerated() {
                let ids = pair.map { faces[$0].id }
                let id = EdgeID(rawValue: ids.map(\.rawValue).joined(separator: "|") + "#\(n)")
                let polyline = chain.map { mesh.vertices[Int($0)] }
                edges.append(EdgeInfo(id: id, polyline: polyline, isSharp: true, faces: ids, topologyEdgeIDs: [],
                                      curve: EdgeCurve.between(faces[pair[0]].surface, faces[pair[1]].surface, polyline: polyline)))
            }
        }
        return edges
    }

    /// Orders segments into connected polylines (closed loops repeat the first point).
    private static func chains(_ segments: [(UInt32, UInt32)]) -> [[UInt32]] {
        var adjacency: [UInt32: [UInt32]] = [:]
        for (a, b) in segments { adjacency[a, default: []].append(b); adjacency[b, default: []].append(a) }
        var used = Set<[UInt32]>()
        func mark(_ a: UInt32, _ b: UInt32) { used.insert([min(a, b), max(a, b)]) }
        func isUsed(_ a: UInt32, _ b: UInt32) -> Bool { used.contains([min(a, b), max(a, b)]) }
        var out: [[UInt32]] = []
        // Start from chain ends first (open chains), then remaining loops.
        let starts = adjacency.keys.sorted { (adjacency[$0]!.count == 1 ? 0 : 1, $0) < (adjacency[$1]!.count == 1 ? 0 : 1, $1) }
        for s in starts {
            for n in adjacency[s]! where !isUsed(s, n) {
                var chain = [s, n]; mark(s, n)
                var cur = n
                while let next = adjacency[cur]?.first(where: { !isUsed(cur, $0) }) {
                    chain.append(next); mark(cur, next); cur = next
                }
                out.append(chain)
            }
        }
        return out
    }

    private static func bounds(_ s: BodySnapshot) -> BoundingBox? {
        guard var lo = s.positions.first else { return nil }
        var hi = lo
        for p in s.positions {
            lo = Vec3(min(lo.x, p.x), min(lo.y, p.y), min(lo.z, p.z))
            hi = Vec3(max(hi.x, p.x), max(hi.y, p.y), max(hi.z, p.z))
        }
        return BoundingBox(min: lo, max: hi)
    }

    private static func bounds(_ s: CSGSolid) -> BoundingBox? {
        let pts = s.polygons.flatMap(\.vertices)
        guard var lo = pts.first else { return nil }
        var hi = lo
        for p in pts {
            lo = Vec3(min(lo.x, p.x), min(lo.y, p.y), min(lo.z, p.z))
            hi = Vec3(max(hi.x, p.x), max(hi.y, p.y), max(hi.z, p.z))
        }
        return BoundingBox(min: lo, max: hi)
    }

    private static func overlaps(_ a: BoundingBox?, _ b: BoundingBox?) -> Bool {
        guard let a, let b else { return false }
        let e = 1e-6
        return a.min.x <= b.max.x + e && b.min.x <= a.max.x + e && a.min.y <= b.max.y + e
            && b.min.y <= a.max.y + e && a.min.z <= b.max.z + e && b.min.z <= a.max.z + e
    }
}

extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}

extension CSGSolid {
    /// Closed mesh and renderer snapshot of a solid (faces keep their IDs and surfaces).
    public func bodySnapshot(bodyID: UUID, revision: String) -> (mesh: Mesh, snapshot: BodySnapshot) {
        let (mesh, triFace) = triangulated()
        return (mesh, DesignEvaluator.snapshot(of: self, mesh: mesh, triangleFace: triFace, bodyID: bodyID, revision: revision))
    }
}

/// States of the history after each step, keyed by a digest of the steps so far (T90).
/// Thread-safe: the model and the background previews share it.
public final class EvaluationCache: @unchecked Sendable {
    struct State: Sendable {
        let bodies: [DesignEvaluator.Work]
        let issues: [DesignEvaluator.Issue]
        let reported: Set<UUID>
    }

    private let lock = NSLock()
    private var states: [String: State] = [:]
    private var order: [String] = []
    private let capacity: Int

    public init(capacity: Int = 24) { self.capacity = capacity }

    static func prefixKeys(_ features: [Feature], components: DesignEvaluator.ComponentResolver?) -> [String] {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        var digest = SHA256()
        // The same history at another tessellation is another state.
        digest.update(data: Data("tessellation \(Tessellation.factor)".utf8))
        return features.map { f in
            digest.update(data: (try? encoder.encode(f)) ?? Data(f.id.uuidString.utf8))
            // A component's content is its file: a changed part invalidates what follows.
            if case let .component(ref) = f.kind, let child = components?(ref.path) {
                digest.update(data: (try? child.encoded()) ?? Data())
            }
            return digest.finalizedHex
        }
    }

    func longestPrefix(_ keys: [String]) -> (Int, State)? {
        lock.lock(); defer { lock.unlock() }
        for k in keys.indices.reversed() { if let s = states[keys[k]] { return (k, s) } }
        return nil
    }

    func store(_ key: String, _ state: State) {
        lock.lock(); defer { lock.unlock() }
        if states[key] == nil {
            order.append(key)
            if order.count > capacity { states[order.removeFirst()] = nil }
        }
        states[key] = state
    }
}

private extension SHA256 {
    var finalizedHex: String { self.finalize().map { String(format: "%02x", $0) }.joined() }
}

extension BodySnapshot {
    func stamped(_ revision: String) -> BodySnapshot {
        BodySnapshot(bodyID: bodyID, revision: revision, positions: positions, normals: normals, triangles: triangles,
                     triangleFace: triangleFace, triangleTopologyFace: triangleTopologyFace, faces: faces, edges: edges,
                     maximumSurfaceDeviation: maximumSurfaceDeviation)
    }
}
