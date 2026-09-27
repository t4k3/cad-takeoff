import Foundation

/// Rebuilds a Fusion 360 design as an editable CAD Takeoff history: user parameters, sketches
/// with their constraints and dimensions (expressions kept), extrusions and revolutions linked to
/// the sketches, fillets, chamfers, holes and shells. Every rebuilt body is checked against the
/// one Fusion made (volume and size): a body that does not match — made with a feature not
/// converted yet — comes in as its mesh instead, so nothing is ever lost or wrong.
public enum FusionImport {
    public struct Report: Sendable, Equatable {
        /// Bodies rebuilt from the history (editable), and those brought in as meshes.
        public var editable: [String] = []
        public var meshes: [String] = []
        /// Features not converted (name: reason).
        public var skipped: [String] = []

        public var summary: String {
            var s = "Da Fusion: \(editable.count) corp\(editable.count == 1 ? "o" : "i") modificabil\(editable.count == 1 ? "e" : "i")"
            if !meshes.isEmpty { s += ", \(meshes.count) come mesh (" + meshes.joined(separator: ", ") + ")" }
            if !skipped.isEmpty { s += " · non convertiti: " + skipped.prefix(4).joined(separator: "; ") + (skipped.count > 4 ? "…" : "") }
            return s
        }
    }

    /// `meshes`: the .ftk's imported-mesh steps (the bodies as Fusion made them), by index.
    public static func convert(_ t: FusionTimeline, meshes: [Feature]) -> (CADDocument, Report) {
        var report = Report()
        var doc = CADDocument()

        // Parameters: user ones with their expressions (units dropped: mm and degrees).
        let byName = Dictionary(t.parameters.map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a })
        let users = t.parameters.filter(\.isUser)
        var values: [String: Double] = [:]
        for p in users where Formula.isValidName(p.name) { values[p.name] = p.value }
        func expression(_ text: String?, _ value: Double) -> String? {
            guard let text else { return nil }
            return translate(text, value: value, parameters: byName, users: values)
        }
        doc.parameters = users.filter { Formula.isValidName($0.name) }.map { p in
            UserParameter(name: p.name, expression: translate(p.expression, value: p.value, parameters: byName, users: values, keepPlain: true)
                          ?? number(p.value), comment: p.comment ?? "")
        }
        if (try? CADDocument.values(of: doc.parameters)) == nil {
            doc.parameters = users.filter { Formula.isValidName($0.name) }.map { UserParameter(name: $0.name, expression: number($0.value), comment: $0.comment ?? "") }
        }

        // Sketches.
        var sketches: [String: BuiltSketch] = [:]
        for fs in t.sketches { sketches[fs.id] = build(fs, expression: expression) }
        var placed = Set<String>()
        func useSketch(_ id: String) {
            guard !placed.contains(id), let s = sketches[id] else { return }
            placed.insert(id)
            doc.timeline.append(TimelineItem(.sketch(s.sketch)))
        }

        // Features, in history order.
        for f in t.features {
            do {
                switch f.type {
                case "extrude", "revolve":
                    let (sid, sketchID, added) = try profileFeatures(f, sketches: sketches, expression: expression)
                    useSketch(sid)
                    for (feature, seeds) in added {
                        doc.timeline.append(TimelineItem(.feature(feature)))
                        doc.sketchLinks.append(SketchLink(featureID: feature.id, sketchID: sketchID, shapeID: UUID(), seeds: seeds))
                    }
                case "fillet", "chamfer": try addEdgeFeature(f, doc: &doc, expression: expression)
                case "hole": try addHole(f, doc: &doc)
                case "shell": try addShell(f, doc: &doc)
                default: throw Skip("tipo \(f.type) non ancora convertito")
                }
            } catch let skip as Skip {
                report.skipped.append("\(f.name): \(skip.reason)")
            } catch {
                report.skipped.append("\(f.name): \(error.localizedDescription)")
            }
        }
        for s in t.sketches { useSketch(s.id) }   // sketches no feature used, at the end

        // Check every body against Fusion's; the ones that differ come in as meshes.
        let built = DesignEvaluator.evaluate(doc, revision: "fusion").bodies
        var matched = Set<UUID>()
        var fallbacks: [Feature] = []
        for body in t.bodies {
            if let b = built.first(where: { !matched.contains($0.id) && same(body, $0.mesh) }) {
                matched.insert(b.id)
                if let i = doc.features.firstIndex(where: { $0.id == b.id }) {
                    doc.features[i].name = body.name
                    if let m = body.mesh, meshes.indices.contains(m) { doc.features[i].color = meshes[m].color }
                }
                report.editable.append(body.name)
            } else if let m = body.mesh, meshes.indices.contains(m) {
                fallbacks.append(meshes[m])
                report.meshes.append(body.name)
            }
        }
        // Rebuilt bodies that match nothing are kept, hidden, to be looked at.
        for b in built where !matched.contains(b.id) {
            if let i = doc.features.firstIndex(where: { $0.id == b.id }) {
                doc.features[i].isVisible = false
                doc.features[i].name = "⚠︎ " + doc.features[i].name + " (diverso da Fusion)"
            }
        }
        for m in fallbacks { doc.timeline.append(TimelineItem(.feature(m))) }
        return (doc, report)
    }

    struct Skip: Error { let reason: String; init(_ r: String) { reason = r } }

    // MARK: Expressions

    /// A Fusion expression in CAD Takeoff's terms: units dropped or turned into factors, model
    /// parameters (d1…) replaced by their own expressions; nil unless it still gives `value` and
    /// names a user parameter (`keepPlain`: also plain numbers).
    static func translate(_ text: String, value: Double, parameters: [String: FusionTimeline.Parameter], users: [String: Double],
                          keepPlain: Bool = false, depth: Int = 0) -> String? {
        guard depth < 8 else { return nil }
        let factors: [String: String] = ["mm": "", "cm": "* 10", "m": "* 1000", "in": "* 25.4", "ft": "* 304.8", "deg": "", "rad": "* 180 / pi"]
        let functions: Set<String> = ["sqrt", "min", "max", "round", "pi", "sin", "cos", "tan", "abs", "floor", "ceil"]
        var out = "", i = text.startIndex
        while i < text.endIndex {
            let ch = text[i]
            if ch.isLetter || ch == "_" {
                var j = i
                while j < text.endIndex, text[j].isLetter || text[j].isNumber || text[j] == "_" { j = text.index(after: j) }
                let word = String(text[i..<j])
                if let f = factors[word] { out += f.isEmpty ? "" : " " + f }
                else if users[word] != nil || functions.contains(word) { out += word }
                else if let p = parameters[word] {
                    guard let inner = translate(p.expression, value: p.value, parameters: parameters, users: users, keepPlain: true, depth: depth + 1)
                    else { out += "(" + number(p.value) + ")"; i = j; continue }
                    out += "(" + inner + ")"
                } else { return nil }
                i = j
            } else {
                out.append(ch); i = text.index(after: i)
            }
        }
        let clean = out.split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ")
        guard let v = try? Formula.evaluate(clean, users), abs(v - value) <= 1e-6 * max(1, abs(value)) else { return nil }
        if !keepPlain, Formula.names(in: clean).allSatisfy({ !users.keys.contains($0) }) { return nil }
        return clean
    }

    static func number(_ v: Double) -> String {
        var s = String(format: "%.6f", v)
        while s.hasSuffix("0") { s.removeLast() }
        if s.hasSuffix(".") { s.removeLast() }
        return s
    }

    // MARK: Sketches

    struct BuiltSketch {
        var sketch: Sketch
        var curves: [String: (id: UUID, type: String)]
        var points: [String: SketchRef]
        var profiles: [String: Vec2]
    }

    static func v3(_ a: [Double]) -> Vec3 { a.count >= 3 ? Vec3(a[0], a[1], a[2]) : .zero }
    static func v2(_ a: [Double]) -> Vec2 { a.count >= 2 ? Vec2(a[0], a[1]) : Vec2(0, 0) }

    static func build(_ fs: FusionTimeline.Sketch, expression: (String?, Double) -> String?) -> BuiltSketch {
        let plane = SketchPlane(origin: v3(fs.origin), xAxis: v3(fs.xAxis).normalized, yAxis: v3(fs.yAxis).normalized)
        let at = Dictionary(fs.points.map { ($0.id, Vec2($0.x, $0.y)) }, uniquingKeysWith: { a, _ in a })
        var shapes: [SketchShape] = []
        var roles: [String: [SketchRef]] = [:]
        var curves: [String: (id: UUID, type: String)] = [:]
        for c in fs.curves {
            let id = UUID()
            var kind: SketchShape.Kind?
            switch c.type {
            case "line":
                if let s = c.start, let e = c.end, let a = at[s], let b = at[e] {
                    kind = .polyline([a, b], closed: false)
                    roles[s, default: []].append(.point(id, 0)); roles[e, default: []].append(.point(id, 1))
                }
            case "circle":
                if let cc = c.center, let o = at[cc], let r = c.radius, r > 0 {
                    kind = .circle(center: o, radius: r)
                    roles[cc, default: []].append(.point(id, 0))
                }
            case "arc":
                if let cc = c.center, let s = c.start, let e = c.end, let o = at[cc], let a = at[s], let b = at[e] {
                    let r = c.radius ?? (a - o).length
                    kind = .arc(center: o, radius: r, start: atan2(a.y - o.y, a.x - o.x), end: atan2(b.y - o.y, b.x - o.x))
                    roles[cc, default: []].append(.point(id, 0)); roles[s, default: []].append(.point(id, 1)); roles[e, default: []].append(.point(id, 2))
                }
            case "spline":
                let ids = c.points ?? []
                let pts = ids.compactMap { at[$0] }
                if pts.count >= 2, pts.count == ids.count {
                    kind = .spline(points: pts, closed: c.closed ?? false)
                    for (k, p) in ids.enumerated() { roles[p, default: []].append(.point(id, k)) }
                }
            default:
                if let pl = c.polyline, pl.count >= 2 { kind = .polyline(pl.map(v2), closed: c.closed ?? false) }
            }
            guard let kind else { continue }
            shapes.append(SketchShape(id: id, kind: kind, isConstruction: c.construction ?? false))
            curves[c.id] = (id, c.type)
        }
        var sketch = Sketch(name: fs.name, plane: plane, shapes: shapes)
        let points = roles.compactMapValues(\.first)

        func curveRef(_ key: String?) -> SketchRef? {
            guard let key, let c = curves[key] else { return nil }
            switch c.type {
            case "line": return .segment(c.id, 0)
            case "circle", "arc": return .circle(c.id, 0)
            default: return nil
            }
        }
        func pointRef(_ key: String?) -> SketchRef? { key.flatMap { points[$0] } }
        func isLine(_ key: String?) -> Bool { key.flatMap { curves[$0]?.type } == "line" }
        func isRound(_ key: String?) -> Bool { ["circle", "arc"].contains(key.flatMap { curves[$0]?.type } ?? "") }

        var wanted: [SketchConstraint] = []
        // Curves sharing a point in Fusion: coincident here (each shape owns its points).
        for list in roles.values where list.count > 1 {
            for r in list.dropFirst() { wanted.append(SketchConstraint(.coincident(list[0], r))) }
        }
        for c in fs.constraints ?? [] {
            var kind: SketchConstraintKind?
            switch c.type {
            case "horizontal": kind = curveRef(c.a).map { .horizontal($0) }
            case "vertical": kind = curveRef(c.a).map { .vertical($0) }
            case "coincident":
                if let p = pointRef(c.a) {
                    if let q = pointRef(c.b) { kind = .coincident(p, q) }
                    else if isLine(c.b), let l = curveRef(c.b) { kind = .pointOnLine(p, l) }
                    else if isRound(c.b), let k = curveRef(c.b) { kind = .pointOnCircle(p, k) }
                }
            case "parallel": if let a = curveRef(c.a), let b = curveRef(c.b) { kind = .parallel(a, b) }
            case "perpendicular": if let a = curveRef(c.a), let b = curveRef(c.b) { kind = .perpendicular(a, b) }
            case "tangent": if let a = curveRef(c.a), let b = curveRef(c.b) { kind = .tangent(a, b) }
            case "equal": if let a = curveRef(c.a), let b = curveRef(c.b) { kind = .equal(a, b) }
            case "concentric": if let a = curveRef(c.a), let b = curveRef(c.b) { kind = .concentric(a, b) }
            case "midpoint": if let p = pointRef(c.a), isLine(c.b), let l = curveRef(c.b) { kind = .midpoint(p, l) }
            case "symmetry": if let p = pointRef(c.a), let q = pointRef(c.b), isLine(c.c), let l = curveRef(c.c) { kind = .symmetric(p, q, l) }
            default: break
            }
            if let kind { wanted.append(SketchConstraint(kind)) }
        }
        for p in fs.points where p.fixed == true {
            if let r = pointRef(p.id) { wanted.append(SketchConstraint(.fix(r, Vec2(p.x, p.y)))) }
        }
        for d in fs.dimensions ?? [] {
            var kind: SketchConstraintKind?
            switch d.type {
            case "distance":
                if let p = pointRef(d.a), let q = pointRef(d.b) { kind = .distance(p, q, d.value) }
                else if let p = pointRef(d.a) ?? pointRef(d.b), let l = isLine(d.a) ? curveRef(d.a) : (isLine(d.b) ? curveRef(d.b) : nil) { kind = .distance(p, l, d.value) }
                else if d.b == nil, isLine(d.a), let l = curveRef(d.a) { kind = .length(l, d.value) }
                else if isLine(d.a), isLine(d.b), let l = curveRef(d.a), let m = curveRef(d.b) { kind = .distance(l, m, d.value) }
            case "horizontal", "vertical":
                var p = pointRef(d.a), q = pointRef(d.b)
                if d.b == nil, isLine(d.a), let c = curves[d.a] { p = .point(c.id, 0); q = .point(c.id, 1) }
                if let p, let q { kind = d.type == "horizontal" ? .horizontalDistance(p, q, d.value) : .verticalDistance(p, q, d.value) }
            case "diameter": kind = curveRef(d.a).map { .diameter($0, d.value) }
            case "radius": kind = curveRef(d.a).map { .radius($0, d.value) }
            case "angle": if let a = curveRef(d.a), let b = curveRef(d.b) { kind = .angle(a, b, d.value) }
            default: break
            }
            if let kind { wanted.append(SketchConstraint(kind, expression: expression(d.expression, d.value))) }
        }
        // Only what the drawing as Fusion solved it already satisfies (an angle measured the other
        // way round, a dimension this solver reads differently, is left out rather than bending it).
        let reference = sketch.shapes
        var all = sketch
        all.constraints = wanted
        if all.solve(), close(all.shapes, reference) {
            sketch.constraints = wanted
        } else {
            for c in wanted {
                var trial = sketch
                trial.constraints.append(c)
                if trial.solve(), close(trial.shapes, reference) { sketch.constraints.append(c) }
            }
        }
        sketch.shapes = reference

        // Profiles: the face of the arrangement with the same area and extent.
        var profiles: [String: Vec2] = [:]
        let faces = sketch.faces
        for p in fs.profiles ?? [] {
            let lo = v2(p.min), hi = v2(p.max), size = max((hi - lo).length, 1)
            let face = faces.first { f in
                let xs = f.outline.map(\.x), ys = f.outline.map(\.y)
                guard let fx0 = xs.min(), let fx1 = xs.max(), let fy0 = ys.min(), let fy1 = ys.max() else { return false }
                let tol = 2e-3 * size + 1e-2
                return abs(f.area - p.area) <= 2e-3 * p.area + 1e-2
                    && abs(fx0 - lo.x) < tol && abs(fx1 - hi.x) < tol && abs(fy0 - lo.y) < tol && abs(fy1 - hi.y) < tol
            }
            if let face { profiles[p.id] = face.seed }
        }
        return BuiltSketch(sketch: sketch, curves: curves, points: points, profiles: profiles)
    }

    static func close(_ a: [SketchShape], _ b: [SketchShape]) -> Bool {
        guard a.count == b.count else { return false }
        for (s, t) in zip(a, b) {
            for i in 0..<max(s.pointCount, 1) {
                guard let p = s.point(i), let q = t.point(i) else { continue }
                if (p - q).length > 1e-4 { return false }
            }
            if let c = s.circle(0), let d = t.circle(0), abs(c.radius - d.radius) > 1e-4 { return false }
        }
        return true
    }

    // MARK: Features

    static func operation(_ text: String?) throws -> BooleanOperation {
        switch text ?? "newBody" {
        case "newBody": return .newBody
        case "join": return .join
        case "cut": return .cut
        default: throw Skip("operazione \(text ?? "") non supportata")
        }
    }

    /// An extrusion or revolution: one solid per area (disjoint areas are separate bodies), each
    /// with the points that find its area again when the sketch changes.
    static func profileFeatures(_ f: FusionTimeline.Feature, sketches: [String: BuiltSketch],
                                expression: (String?, Double) -> String?) throws -> (String, UUID, [(Feature, [Vec2])]) {
        let keys = f.profiles ?? []
        let sketchIDs = Set(keys.map { String($0.split(separator: "/").first ?? "") })
        guard sketchIDs.count == 1, let sid = sketchIDs.first, let built = sketches[sid] else { throw Skip("profili da più schizzi o mancanti") }
        let seeds = keys.compactMap { built.profiles[String($0.split(separator: "/").dropFirst().joined(separator: "/"))] }
        guard seeds.count == keys.count, !seeds.isEmpty else { throw Skip("profilo non ritrovato nello schizzo") }
        let op = try operation(f.operation)
        let sketch = built.sketch
        let areas = sketch.areas(seeds: seeds)
        guard !areas.isEmpty else { throw Skip("profilo non chiuso") }
        var added: [(Feature, [Vec2])] = []
        for area in areas {
            let own = seeds.filter { area.contains($0) }
            var feature: Feature
            if f.type == "extrude" {
                guard let e = f.extent else { throw Skip("estensione mancante") }
                var height = abs(e.distance ?? 10)
                var reversed = (e.reversed ?? false) != ((e.distance ?? 0) < 0)
                var symmetric = false, through = false
                switch e.type {
                case "distance": break
                case "symmetric": symmetric = true
                case "through": through = true; height = 10; reversed = e.reversed ?? false
                default: throw Skip("estensione «\(e.type)» non ancora convertita")
                }
                guard height > 1e-6 else { throw Skip("altezza nulla") }
                let onXY = sketch.plane.isXY && !reversed
                feature = Feature(name: f.name, kind: .extrude(profile: Profile2D(points: area.outline), height: height), operation: op,
                                  placement: onXY ? nil : FeaturePlacement(plane: sketch.plane, reversed: reversed),
                                  holes: area.holes.map { Profile2D(points: $0) })
                feature.keyProfile(from: sketch)
                feature.symmetric = symmetric
                feature.throughAll = through
                feature.taper = e.taper ?? 0
                if !through, let x = expression(e.expression, height) { feature.expressions["height"] = x }
            } else {
                guard let axis = f.axis else { throw Skip("asse mancante") }
                var start: Vec2, end: Vec2, ref: SketchRef?
                if let key = axis.curve, let c = built.curves[key], c.type == "line",
                   let seg = sketch.shapes.first(where: { $0.id == c.id })?.segment(0) {
                    (start, end, ref) = (seg.0, seg.1, .segment(c.id, 0))
                } else if let o = axis.origin, let d = axis.direction {
                    let p0 = v3(o), p1 = v3(o) + v3(d).normalized * 10
                    let n = sketch.plane.normal
                    guard abs((p0 - sketch.plane.origin).dot(n)) < 1e-4, abs(v3(d).normalized.dot(n)) < 1e-6 else { throw Skip("asse fuori dal piano dello schizzo") }
                    (start, end, ref) = (sketch.plane.local(p0), sketch.plane.local(p1), nil)
                } else { throw Skip("asse non riconosciuto") }
                let spec = RevolveSpec(profile: Profile2D(points: area.outline), plane: sketch.plane, axisStart: start, axisEnd: end, axisRef: ref,
                                       angle: min(abs(f.angle ?? 360), 360), reversed: (f.angle ?? 360) < 0)
                feature = Feature(name: f.name, kind: .revolve(spec), operation: op, holes: area.holes.map { Profile2D(points: $0) })
            }
            added.append((feature, own.isEmpty ? [area.seed] : own))
        }
        return (sid, sketch.id, added)
    }

    /// Fillets and chamfers: each edge found again on the bodies built so far, by its points.
    static func addEdgeFeature(_ f: FusionTimeline.Feature, doc: inout CADDocument, expression: (String?, Double) -> String?) throws {
        guard let size = f.size, size > 0, let edges = f.edges, !edges.isEmpty else { throw Skip("spigoli o misura mancanti") }
        let bodies = DesignEvaluator.evaluate(doc, revision: "fusion-edges").bodies
        var refs: [EdgeRef] = []
        for samples in edges {
            let pts = samples.map(v3)
            guard let mid = pts.dropFirst(pts.count / 2).first else { continue }
            let found = bodies.lazy.flatMap(\.snapshot.edges).first { e in
                e.faces.count == 2 && pts.allSatisfy { p in distance(p, to: e.polyline) < 0.02 }
            }
            guard let e = found else { throw Skip("spigolo non ritrovato") }
            refs.append(EdgeRef(faces: e.faces, point: closest(mid, on: e.polyline)))
        }
        let spec = ChamferSpec(edges: refs, profile: f.type == "fillet" ? .round : .flat, distance: size)
        doc.timeline.append(TimelineItem(.feature(Feature(name: f.name, kind: .chamfer(spec)))))
    }

    static func addHole(_ f: FusionTimeline.Feature, doc: inout CADDocument) throws {
        guard let centers = f.centers, !centers.isEmpty, let d = f.diameter, d > 0 else { throw Skip("foro senza posizione o diametro") }
        let dir = f.direction.map(v3)?.normalized ?? Vec3(0, 0, -1)
        let spec = HoleSpec(centers: centers.map(v3), direction: dir, style: .simple, fit: .manual, size: nil, diameter: d, depth: f.depth)
        doc.timeline.append(TimelineItem(.feature(Feature(name: f.name, kind: .hole(spec)))))
    }

    static func addShell(_ f: FusionTimeline.Feature, doc: inout CADDocument) throws {
        guard let t = f.size, t > 0 else { throw Skip("spessore mancante") }
        let bodies = DesignEvaluator.evaluate(doc, revision: "fusion-shell").bodies
        var body: UUID?
        var open: [FaceID] = []
        for pair in f.faces ?? [] {
            guard pair.count == 2 else { continue }
            let p = v3(pair[0]), n = v3(pair[1]).normalized
            var hit: (UUID, FaceID)?
            for b in bodies {
                for face in b.snapshot.faces {
                    guard let (o, m) = b.snapshot.flatPlane(of: face.id), m.dot(n) > 0.999, abs((p - o).dot(m)) < 0.01 else { continue }
                    if b.snapshot.contains(p, onFace: face.id) { hit = (b.id, face.id); break }
                }
                if hit != nil { break }
            }
            guard let (bid, fid) = hit, body == nil || body == bid else { throw Skip("faccia aperta non ritrovata") }
            body = bid; open.append(fid)
        }
        guard let target = body ?? bodies.last?.id else { throw Skip("corpo da svuotare non trovato") }
        doc.timeline.append(TimelineItem(.feature(Feature(name: f.name, kind: .shell(ShellSpec(body: target, thickness: t, openFaces: open))))))
    }

    // MARK: Geometry

    static func closest(_ p: Vec3, on line: [Vec3]) -> Vec3 {
        var best = line.first ?? p, d = Double.infinity
        for (a, b) in zip(line, line.dropFirst()) {
            let ab = b - a, l2 = ab.dot(ab)
            let t = l2 > 0 ? max(0, min(1, (p - a).dot(ab) / l2)) : 0
            let q = a + ab * t
            if (q - p).length < d { d = (q - p).length; best = q }
        }
        return best
    }

    static func distance(_ p: Vec3, to line: [Vec3]) -> Double { (closest(p, on: line) - p).length }

    /// Same body as Fusion's: volume within 0.5 % and the same extent within 0.05 mm (or 0.2 %).
    static func same(_ b: FusionTimeline.Body, _ mesh: Mesh) -> Bool {
        guard let box = mesh.bounds else { return false }
        let lo = v3(b.min), hi = v3(b.max)
        let tol = max(0.05, 2e-3 * (hi - lo).length)
        return abs(mesh.volume - b.volume) <= max(5e-3 * b.volume, 1)
            && (box.min - lo).length < tol && (box.max - hi).length < tol
    }
}

extension BodySnapshot {
    /// The point lies on the face (within 0.01 mm of one of its triangles).
    func contains(_ p: Vec3, onFace id: FaceID) -> Bool {
        guard let f = faces.firstIndex(where: { $0.id == id }) else { return false }
        for t in 0..<triangleFace.count where Int(triangleFace[t]) == f {
            let a = positions[Int(triangles[t * 3])], b = positions[Int(triangles[t * 3 + 1])], c = positions[Int(triangles[t * 3 + 2])]
            let n = (b - a).cross(c - a)
            guard n.length > 1e-12 else { continue }
            let k = n.normalized
            guard abs((p - a).dot(k)) < 0.01 else { continue }
            let q = p - k * (p - a).dot(k)
            func side(_ u: Vec3, _ v: Vec3) -> Double { (v - u).cross(q - u).dot(k) }
            if side(a, b) >= -1e-9, side(b, c) >= -1e-9, side(c, a) >= -1e-9 { return true }
        }
        return false
    }
}
