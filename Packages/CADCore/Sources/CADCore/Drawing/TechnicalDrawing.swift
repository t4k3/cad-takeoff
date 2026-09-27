import Foundation

/// A 2D technical drawing sheet (mm, origin bottom-left): what the PDF and DXF writers draw.
public struct DrawingSheet: Sendable {
    public enum Style: String, Sendable { case visible, hidden, thin, border, center }
    public struct Line: Sendable { public var a: Vec2, b: Vec2; public var style: Style }
    public struct Text: Sendable {
        public enum Align: Sendable { case left, center, right }
        public var at: Vec2; public var text: String; public var size: Double; public var align: Align
        public var angle: Double = 0
    }
    public var width: Double, height: Double
    public var lines: [Line] = []
    public var texts: [Text] = []
    /// Filled triangles (arrowheads).
    public var arrows: [[Vec2]] = []
}

public enum SheetFormat: String, CaseIterable, Sendable {
    case a4 = "A4", a3 = "A3"
    /// Landscape size in mm.
    public var size: (Double, Double) { self == .a4 ? (297, 210) : (420, 297) }
}

/// First-angle (ISO E) orthographic views with hidden lines, an isometric view, overall
/// dimensions and a title block.
public enum TechnicalDrawing {
    public struct Info: Sendable {
        public var title: String
        public var material: String = ""
        public var author: String = ""
        public var date: Date = Date()
        public init(title: String, material: String = "", author: String = "", date: Date = Date()) {
            self.title = title; self.material = material; self.author = author; self.date = date
        }
    }

    /// A view direction: the viewer looks along `look`, with `up` up the sheet.
    struct View { let look: Vec3; let up: Vec3; var right: Vec3 { look.cross(up).normalized } }

    public static let scales: [(Double, String)] = [
        (10, "10:1"), (5, "5:1"), (2, "2:1"), (1, "1:1"), (0.5, "1:2"), (0.2, "1:5"), (0.1, "1:10"), (0.05, "1:20"), (0.02, "1:50"), (0.01, "1:100"),
    ]

    /// `section`: the front view is the section A–A through the middle of the part (hatched cut
    /// faces, no hidden lines), with the cutting line in the view from above.
    public static func make(_ bodies: [(mesh: Mesh, snapshot: BodySnapshot)], info: Info, format: SheetFormat = .a4,
                            section: Bool = false) throws -> DrawingSheet {
        let model = Model(bodies)
        guard let box = model.bounds else { throw KernelError.invalidParameter("disegno: nessun corpo visibile") }
        let (W, H) = format.size
        var sheet = DrawingSheet(width: W, height: H)
        // Frame: 20 mm binding margin on the left, 10 elsewhere; title block bottom right.
        let frame = (x0: 20.0, y0: 10.0, x1: W - 10, y1: H - 10)
        rect(&sheet, frame.x0, frame.y0, frame.x1, frame.y1, .border)
        let titleW = 180.0, titleH = 36.0

        let front = View(look: Vec3(0, 1, 0), up: Vec3(0, 0, 1))
        let top = View(look: Vec3(0, 0, -1), up: Vec3(0, 1, 0))
        let left = View(look: Vec3(1, 0, 0), up: Vec3(0, 0, 1))
        let iso = View(look: Vec3(-1, 1, -1).normalized, up: (Vec3(0, 0, 1) - Vec3(-1, 1, -1).normalized * Vec3(-1, 1, -1).normalized.z).normalized)
        func extent(_ v: View) -> (min: Vec2, max: Vec2) {
            let c = box.corners.map { Vec2($0.dot(v.right), $0.dot(v.up)) }
            return (Vec2(c.map(\.x).min()!, c.map(\.y).min()!), Vec2(c.map(\.x).max()!, c.map(\.y).max()!))
        }
        let ef = extent(front), et = extent(top), el = extent(left), ei = extent(iso)
        func w(_ e: (min: Vec2, max: Vec2)) -> Double { e.max.x - e.min.x }
        func h(_ e: (min: Vec2, max: Vec2)) -> Double { e.max.y - e.min.y }
        // Largest standard scale that fits, trying two layouts: the isometric in a third column,
        // or beside the view from above (second row).
        let gap = 18.0
        let availW = frame.x1 - frame.x0 - 4 * gap, availH = frame.y1 - frame.y0 - titleH - 3 * gap
        let row1 = max(h(ef), h(el))
        // Heights where the part steps (horizontal edges seen from the front): dimensioned from the
        // bottom on the right of the front view, so each needs a little room there.
        let levels: [Double] = {
            var zs = Set<Int64>()
            for seg in model.edges(for: front, hidden: true) where abs(seg.a.y - seg.b.y) < 1e-6 && abs(seg.a.x - seg.b.x) > 1e-6 {
                zs.insert(Int64((seg.a.y * 100).rounded()))
            }
            let all = zs.map { Double($0) / 100 }.filter { $0 > ef.min.y + 0.05 && $0 < ef.max.y - 0.05 }.sorted()
            return all.count <= 6 ? all : []
        }()
        let levelRoom = levels.isEmpty ? 0.0 : 6 * Double(levels.count) + 4
        let fitColumn = min((availW - levelRoom) / max(w(ef) + w(el) + w(ei), 1e-6), availH / max(row1 + max(h(et), 1), 1e-6))
        let fitRow = min((availW + gap - levelRoom) / max(max(w(ef) + w(el), w(et) + w(ei)), 1e-6), availH / max(row1 + max(h(et), h(ei)), 1e-6))
        let isoBelow = fitRow > fitColumn
        guard let (scale, label) = scales.first(where: { $0.0 <= max(fitColumn, fitRow) }) else { throw KernelError.invalidParameter("disegno: pezzo troppo grande per il foglio") }

        // Placement: front top-left, the view from the left on its right, from above below it
        // (first angle); the isometric in the right column or right of the view from above.
        let rowTop = frame.y1 - gap - row1 * scale
        let colFront = frame.x0 + gap
        let colLeft = colFront + w(ef) * scale + gap + levelRoom
        let colIso = isoBelow ? colFront + w(et) * scale + gap : colLeft + w(el) * scale + gap
        func place(_ v: View, _ e: (min: Vec2, max: Vec2), at origin: Vec2) -> (Vec2) -> Vec2 {
            { p in Vec2(origin.x + (p.x - e.min.x) * scale, origin.y + (p.y - e.min.y) * scale) }
        }
        let frontAt = place(front, ef, at: Vec2(colFront, rowTop))
        let leftAt = place(left, el, at: Vec2(colLeft, rowTop))
        let topAt = place(top, et, at: Vec2(colFront, rowTop - gap - h(et) * scale))
        let isoAt = place(iso, ei, at: isoBelow ? Vec2(colIso, rowTop - gap - h(ei) * scale) : Vec2(colIso, rowTop + (row1 - h(ei)) * scale))
        for (v, at) in [(front, frontAt), (left, leftAt), (top, topAt), (iso, isoAt)] where !(section && v.look == front.look) {
            for seg in model.edges(for: v, hidden: v.look != iso.look) {
                sheet.lines.append(.init(a: at(seg.a), b: at(seg.b), style: seg.visible ? .visible : .hidden))
            }
        }
        if section {
            // The half towards the viewer taken away; what is left seen from the front.
            let yc = (box.min.y + box.max.y) / 2, pad = 10.0
            let size = box.max - box.min
            let tool = Feature(name: "sezione", kind: .box(width: size.x + 2 * pad, depth: yc - box.min.y + pad, height: size.z + 2 * pad),
                               position: Vec3((box.min.x + box.max.x) / 2, (box.min.y - pad + yc) / 2, box.min.z - pad))
            let toolSolid = CSGSolid(try PrimitiveKernel.build(tool).snapshot(revision: "section"))
            let cut: [(mesh: Mesh, snapshot: BodySnapshot)] = bodies.compactMap { b in
                let solid = CSGSolid(b.snapshot).subtracting(toolSolid)
                guard !solid.isEmpty else { return nil }
                let (mesh, triFace) = solid.triangulated()
                return (mesh, DesignEvaluator.snapshot(of: solid, mesh: mesh, triangleFace: triFace, bodyID: b.snapshot.bodyID, revision: "section"))
            }
            let cutModel = Model(cut)
            for seg in cutModel.edges(for: front, hidden: false) where seg.visible {
                sheet.lines.append(.init(a: frontAt(seg.a), b: frontAt(seg.b), style: .visible))
            }
            for h in cutModel.hatch(plane: yc, view: front, spacing: 2.5 / scale) {
                sheet.lines.append(.init(a: frontAt(h.0), b: frontAt(h.1), style: .thin))
            }
            // Title under the view, cutting line in the view from above (arrows: looking direction).
            let above = frontAt(Vec2((ef.min.x + ef.max.x) / 2, ef.max.y))
            sheet.texts.append(.init(at: above + Vec2(0, 5), text: "SEZIONE A-A", size: 3.5, align: .center))
            let l0 = topAt(Vec2(et.min.x, yc)) - Vec2(6, 0), l1 = topAt(Vec2(et.max.x, yc)) + Vec2(6, 0)
            sheet.lines.append(.init(a: l0, b: l1, style: .center))
            for end in [l0, l1] {
                sheet.lines.append(.init(a: end, b: end + Vec2(0, 5), style: .visible))
                arrow(&sheet, tip: end + Vec2(0, 7), from: end + Vec2(0, 2))
                sheet.texts.append(.init(at: end + Vec2(end.x < l1.x ? -3 : 3, 1), text: "A", size: 3.5, align: .center))
            }
        }
        // Overall dimensions: width and height on the front, depth on the view from the left.
        let size = box.max - box.min
        dimension(&sheet, from: frontAt(Vec2(ef.min.x, ef.min.y)), to: frontAt(Vec2(ef.max.x, ef.min.y)), offset: -8, value: size.x)
        dimension(&sheet, from: frontAt(Vec2(ef.min.x, ef.min.y)), to: frontAt(Vec2(ef.min.x, ef.max.y)), offset: 8, value: size.z)
        for (k, z) in levels.enumerated() {
            dimension(&sheet, from: frontAt(Vec2(ef.max.x, ef.min.y)), to: frontAt(Vec2(ef.max.x, z)), offset: -(8 + 6 * Double(k)), value: z - ef.min.y)
        }
        dimension(&sheet, from: leftAt(Vec2(el.min.x, el.min.y)), to: leftAt(Vec2(el.max.x, el.min.y)), offset: -8, value: size.y)
        // Round holes and bosses seen end-on from above: their diameters.
        // Centre lines: a cross on every circle seen end-on in the top view.
        let circles = model.circles(for: top)
        for c in circles {
            let centre = topAt(c.centre), r = c.radius * scale + 2
            sheet.lines.append(.init(a: centre - Vec2(r, 0), b: centre + Vec2(r, 0), style: .center))
            sheet.lines.append(.init(a: centre - Vec2(0, r), b: centre + Vec2(0, r), style: .center))
        }
        // Their axes in the front and side views (vertical, over the part's height).
        for c in circles {
            let world = Vec3(c.centre.x * top.right.x, c.centre.y * top.up.y, 0)
            // Looking down, depth is −z.
            let zs = c.depth.lowerBound == c.depth.upperBound ? (box.min.z, box.max.z) : (-c.depth.upperBound, -c.depth.lowerBound)
            for (v, at) in [(front, frontAt), (left, leftAt)] {
                let x = world.x * v.right.x + world.y * v.right.y
                sheet.lines.append(.init(a: at(Vec2(x, zs.0)) - Vec2(0, 2), b: at(Vec2(x, zs.1)) + Vec2(0, 2), style: .center))
            }
        }
        // Holes go in the hole table; the leaders are for the rest (bosses, shafts).
        // A hole: empty just inside its rim, material just outside (a shaft or a groove the reverse;
        // the centre alone would fool a bush, empty on its axis).
        let holes = circles.filter { c in
            let z = -(c.depth.lowerBound + c.depth.upperBound) / 2
            let dir = Vec2(cos(0.65), sin(0.65)), step = min(0.2, 0.05 * c.radius)
            let inner = c.centre + dir * (c.radius - step), outer = c.centre + dir * (c.radius + step)
            return !model.contains(Vec3(inner.x, inner.y, z)) && model.contains(Vec3(outer.x, outer.y, z))
        }.sorted { ($0.centre.y, $0.centre.x) < ($1.centre.y, $1.centre.x) }
        let tabled = !holes.isEmpty && holes.count <= 26
        var labelled: [Vec2] = []
        let shown = Array(circles.filter { c in !(tabled && holes.contains { ($0.centre - c.centre).length < 1e-9 && $0.radius == c.radius }) }.prefix(8))
        for c in shown {
            let centre = topAt(c.centre), r = c.radius * scale
            // Circles on the same centre (a bore, a groove, a counterbore): leaders fanned out on
            // alternate sides, all ending outside the largest of them.
            let before = labelled.filter { ($0 - centre).length < 1e-3 }.count
            labelled.append(centre)
            let outer = shown.filter { (topAt($0.centre) - centre).length < 1e-3 }.map(\.radius).max()! * scale
            let angles = [45.0, 135, 20, 160, 70, 110, 0, 180]
            let a = angles[before % angles.count] * .pi / 180
            let dir = Vec2(cos(a), sin(a))
            let tip = centre + dir * r, knee = centre + dir * (outer + 6 + Double(before / 2) * 5)
            let right = dir.x >= 0
            sheet.lines.append(.init(a: tip, b: knee, style: .thin))
            sheet.lines.append(.init(a: knee, b: knee + Vec2(right ? 12 : -12, 0), style: .thin))
            arrow(&sheet, tip: tip, from: knee)
            sheet.texts.append(.init(at: knee + Vec2(right ? 1 : -1, 1), text: "Ø" + number(2 * c.radius), size: 3.2, align: right ? .left : .right))
        }
        titleBlock(&sheet, x1: frame.x1, y0: frame.y0, width: titleW, height: titleH, info: info, scale: label, format: format)
        // Hole table (for the workshop and CNC): holes seen from above, lettered on the view, with
        // X/Y from the part's lower-left corner and the diameter.
        if tabled {
            // Bottom left, beside the title block.
            let rowH = 5.0, cols = [12.0, 20, 20, 20], width = cols.reduce(0, +)
            let x0 = frame.x0 + 4, tableTop = frame.y0 + 4 + rowH * Double(holes.count + 1)
            let cells = [["Foro", "X", "Y", "Ø"]] + holes.enumerated().map { k, c in
                ["F\(k + 1)", number(c.centre.x - box.min.x), number(c.centre.y - box.min.y), number(2 * c.radius)]
            }
            for (r, row) in cells.enumerated() {
                let y = tableTop - rowH * Double(r + 1)
                var x = x0
                for (k, text) in row.enumerated() {
                    sheet.texts.append(.init(at: Vec2(x + cols[k] / 2, y + 1.4), text: text, size: r == 0 ? 2.5 : 2.8, align: .center))
                    x += cols[k]
                }
                sheet.lines.append(.init(a: Vec2(x0, y), b: Vec2(x0 + width, y), style: r == 0 ? .visible : .thin))
            }
            rect(&sheet, x0, tableTop - rowH * Double(cells.count), x0 + width, tableTop, .visible)
            var x = x0
            for w in cols.dropLast() { x += w; sheet.lines.append(.init(a: Vec2(x, tableTop - rowH * Double(cells.count)), b: Vec2(x, tableTop), style: .thin)) }
            // Letters beside each hole, and the origin marked at the corner.
            for (k, c) in holes.enumerated() {
                let at = topAt(c.centre) + Vec2(-c.radius * scale - 1.5, c.radius * scale * 0.7 + 1)
                sheet.texts.append(.init(at: at, text: "F\(k + 1)", size: 3, align: .right))
            }
            let corner = topAt(Vec2(box.min.x * top.right.x, box.min.y * top.up.y))
            sheet.texts.append(.init(at: corner + Vec2(-1.5, -4), text: "0,0", size: 2.5, align: .right))
        }
        return sheet
    }

    // MARK: Model and hidden lines

    struct Model {
        var points: [Vec3] = []
        var tris: [(v: [Int], face: Int, normal: Vec3)] = []
        var edgeTris: [SIMD2<Int>: [Int]] = [:]
        var bounds: (min: Vec3, max: Vec3, corners: [Vec3])?

        init(_ bodies: [(mesh: Mesh, snapshot: BodySnapshot)]) {
            var index: [SIMD3<Int64>: Int] = [:]
            var faceBase = 0
            for (_, s) in bodies {
                func key(_ p: Vec3) -> SIMD3<Int64> { SIMD3(Int64((p.x * 1e6).rounded()), Int64((p.y * 1e6).rounded()), Int64((p.z * 1e6).rounded())) }
                let corner = s.triangles.map { i -> Int in
                    let p = s.positions[Int(i)], k = key(p)
                    if let v = index[k] { return v }
                    points.append(p); index[k] = points.count - 1
                    return points.count - 1
                }
                for t in 0..<(corner.count / 3) {
                    let v = [corner[t * 3], corner[t * 3 + 1], corner[t * 3 + 2]]
                    guard Set(v).count == 3 else { continue }
                    let n = (points[v[1]] - points[v[0]]).cross(points[v[2]] - points[v[0]])
                    guard n.length > 1e-14 else { continue }
                    tris.append((v, faceBase + Int(s.triangleFace[t]), n.normalized))
                }
                faceBase += s.faces.count
            }
            for (t, tri) in tris.enumerated() {
                for k in 0..<3 { let a = tri.v[k], b = tri.v[(k + 1) % 3]; edgeTris[SIMD2(min(a, b), max(a, b)), default: []].append(t) }
            }
            guard let first = points.first else { return }
            var lo = first, hi = first
            for p in points { lo = Vec3(min(lo.x, p.x), min(lo.y, p.y), min(lo.z, p.z)); hi = Vec3(max(hi.x, p.x), max(hi.y, p.y), max(hi.z, p.z)) }
            let corners = [0, 1].flatMap { i in [0, 1].flatMap { j in [0, 1].map { k in Vec3(i == 0 ? lo.x : hi.x, j == 0 ? lo.y : hi.y, k == 0 ? lo.z : hi.z) } } }
            bounds = (lo, hi, corners)
        }

        /// Projected edges (view coordinates, mm): creases between faces that meet at an angle,
        /// and outlines of curved faces; split into visible and hidden runs.
        func edges(for view: View, hidden: Bool) -> [(a: Vec2, b: Vec2, visible: Bool)] {
            let r = view.right, u = view.up, d = view.look
            func p2(_ p: Vec3) -> Vec2 { Vec2(p.dot(r), p.dot(u)) }
            let size = bounds.map { ($0.max - $0.min).length } ?? 1
            // Occluders, binned by their projected box.
            let grid = TriangleGrid(tris.indices.map { t in tris[t].v.map { p2(points[$0]) } })
            var out: [(Vec2, Vec2, Bool)] = []
            for (e, ts) in edgeTris where ts.count == 2 {
                let t1 = tris[ts[0]], t2 = tris[ts[1]]
                let f1 = t1.normal.dot(d) < 0, f2 = t2.normal.dot(d) < 0
                let crease = t1.face != t2.face && t1.normal.dot(t2.normal) < cos(12 * Double.pi / 180)
                let outline = f1 != f2 && t1.normal.dot(t2.normal) > 0.5   // smooth fold facing away
                guard crease || outline else { continue }
                let a = points[e.x], b = points[e.y]
                // Visibility along the edge, sampled.
                let length = (p2(b) - p2(a)).length
                let n = max(2, min(200, Int(length / max(size / 300, 1e-3)) + 1))
                var states: [Bool] = []
                for i in 0...n {
                    let t = (Double(i) + 0.5) / Double(n + 1)
                    let q = a + (b - a) * t
                    states.append(!grid.occludes(p2(q), depth: q.dot(d), ignoring: Set(ts), tris: tris, points: points, look: d, eps: 1e-6 * size + 1e-5))
                }
                if !hidden && !states.contains(true) { continue }
                var start = 0
                for i in 1...states.count {
                    if i == states.count || states[i] != states[start] {
                        let t0 = Double(start) / Double(states.count), t1v = Double(i) / Double(states.count)
                        if states[start] || hidden {
                            out.append((p2(a + (b - a) * t0), p2(a + (b - a) * t1v), states[start]))
                        }
                        start = i
                    }
                }
            }
            return merged(out)
        }

        /// Circles seen end-on (holes and bosses square to the view), from the model's rims.
        func circles(for view: View) -> [(centre: Vec2, radius: Double, depth: ClosedRange<Double>)] {
            // Closed crease loops whose points are co-circular in the view plane.
            let r = view.right, u = view.up
            var adjacency: [Int: [Int]] = [:]
            for (e, ts) in edgeTris where ts.count == 2 && tris[ts[0]].face != tris[ts[1]].face {
                let n1 = tris[ts[0]].normal, n2 = tris[ts[1]].normal
                guard n1.dot(n2) < cos(12 * Double.pi / 180) else { continue }
                // Rims lie in a plane square to the view.
                guard abs((points[e.x] - points[e.y]).dot(view.look)) < 1e-6 else { continue }
                adjacency[e.x, default: []].append(e.y); adjacency[e.y, default: []].append(e.x)
            }
            var seen = Set<Int>(), out: [(Vec2, Double, ClosedRange<Double>)] = []
            for start in adjacency.keys.sorted() where !seen.contains(start) && adjacency[start]!.count == 2 {
                var loop = [start], prev = start, at = adjacency[start]![0]
                seen.insert(start)
                while at != start, let next = adjacency[at], next.count == 2, loop.count < 10_000 {
                    loop.append(at); seen.insert(at)
                    let n = next[0] == prev ? next[1] : next[0]
                    prev = at; at = n
                }
                guard at == start, loop.count >= 12 else { continue }
                let flat = loop.map { Vec2(points[$0].dot(r), points[$0].dot(u)) }
                guard let fit = PrimitiveKernel.fit(flat), flat.allSatisfy({ abs(($0 - fit.c).length - fit.r) < 0.02 * fit.r + 1e-3 }) else { continue }
                // The true radius: the facets' corners are on the circle, points the booleans added
                // on their chords are inside it.
                let radius = flat.map { ($0 - fit.c).length }.max()!
                // The same circle seen through the part (top and bottom rim of a hole): once, with
                // the depth it spans.
                let depth = points[loop[0]].dot(view.look)
                if let i = out.firstIndex(where: { ($0.0 - fit.c).length < 0.02 * radius + 1e-3 && abs($0.1 - radius) < 0.02 * radius + 1e-3 }) {
                    out[i].2 = min(out[i].2.lowerBound, depth)...max(out[i].2.upperBound, depth)
                } else { out.append((fit.c, radius, depth...depth)) }
            }
            return out.sorted { $0.1 > $1.1 }
        }

        /// 45° hatching of the faces lying on the plane y = `plane` and facing the viewer (a cut).
        func hatch(plane: Double, view: View, spacing: Double) -> [(Vec2, Vec2)] {
            let r = view.right, u = view.up
            func p2(_ p: Vec3) -> Vec2 { Vec2(p.dot(r), p.dot(u)) }
            let n = Vec2(-1, 1).normalized, dir = Vec2(1, 1).normalized
            var segs: [(Vec2, Vec2, Bool)] = []
            for tri in tris where tri.normal.dot(view.look) < -0.999 && tri.v.allSatisfy({ abs(points[$0].y - plane) < 1e-6 }) {
                let q = tri.v.map { p2(points[$0]) }
                let c = q.map { $0.dot(n) }
                guard let lo = c.min(), let hi = c.max(), hi - lo > 1e-12 else { continue }
                var k = (lo / spacing).rounded(.up)
                while k * spacing <= hi {
                    let level = k * spacing
                    // Where the line n·p = level crosses the triangle's sides.
                    var hits: [Vec2] = []
                    for i in 0..<3 {
                        let a = q[i], b = q[(i + 1) % 3], ca = c[i], cb = c[(i + 1) % 3]
                        if (ca - level) * (cb - level) <= 0, abs(cb - ca) > 1e-12 { hits.append(a + (b - a) * ((level - ca) / (cb - ca))) }
                    }
                    if hits.count >= 2 {
                        let sorted = hits.sorted { $0.dot(dir) < $1.dot(dir) }
                        if (sorted.last! - sorted.first!).length > 1e-9 { segs.append((sorted.first!, sorted.last!, true)) }
                    }
                    k += 1
                }
            }
            return merged(segs).map { ($0.a, $0.b) }
        }

        /// Whether a point is inside the solid (ray parity along a slanted direction).
        func contains(_ p: Vec3) -> Bool {
            let d = Vec3(0.5773, 0.5774, 0.5775).normalized
            var hits = 0
            for t in tris {
                let a = points[t.v[0]], b = points[t.v[1]], c = points[t.v[2]]
                let e1 = b - a, e2 = c - a, q = d.cross(e2), det = e1.dot(q)
                guard abs(det) > 1e-14 else { continue }
                let f = 1 / det, w = p - a, u = w.dot(q) * f
                guard u >= 0, u <= 1 else { continue }
                let r = w.cross(e1), v = d.dot(r) * f
                guard v >= 0, u + v <= 1 else { continue }
                if e2.dot(r) * f > 1e-9 { hits += 1 }
            }
            return hits % 2 == 1
        }

        /// Collinear touching runs of the same kind joined (fewer, cleaner lines).
        private func merged(_ segs: [(Vec2, Vec2, Bool)]) -> [(a: Vec2, b: Vec2, visible: Bool)] {
            var out: [(a: Vec2, b: Vec2, visible: Bool)] = []
            var byKey: [SIMD4<Int64>: [Int]] = [:]
            for (a, b, v) in segs {
                guard (b - a).length > 1e-9 else { continue }
                var d = (b - a).normalized
                if d.x < -1e-12 || (abs(d.x) < 1e-12 && d.y < 0) { d = Vec2(-d.x, -d.y) }
                let c = d.cross(a)   // offset of the line
                let key = SIMD4(Int64((d.x * 1e6).rounded()), Int64((d.y * 1e6).rounded()), Int64((c * 1e4).rounded()), v ? 1 : 0)
                byKey[key, default: []].append(out.count)
                out.append((a, b, v))
            }
            var result: [(a: Vec2, b: Vec2, visible: Bool)] = []
            for (_, ids) in byKey {
                let d0 = (out[ids[0]].b - out[ids[0]].a).normalized
                var runs = ids.map { i -> (Double, Double, Vec2, Vec2) in
                    let s = out[i]
                    let ta = s.a.dot(d0), tb = s.b.dot(d0)
                    return ta < tb ? (ta, tb, s.a, s.b) : (tb, ta, s.b, s.a)
                }.sorted { $0.0 < $1.0 }
                var current = runs.removeFirst()
                for r in runs {
                    if r.0 <= current.1 + 1e-6 { if r.1 > current.1 { current.1 = r.1; current.3 = r.3 } } else {
                        result.append((current.2, current.3, out[ids[0]].visible)); current = r
                    }
                }
                result.append((current.2, current.3, out[ids[0]].visible))
            }
            return result
        }
    }

    /// Projected triangles binned on a grid, for occlusion tests.
    struct TriangleGrid {
        let tris2: [[Vec2]]
        var cells: [SIMD2<Int>: [Int]] = [:]
        let lo: Vec2, cell: Double
        init(_ tris2: [[Vec2]]) {
            self.tris2 = tris2
            let all = tris2.flatMap { $0 }
            lo = Vec2(all.map(\.x).min() ?? 0, all.map(\.y).min() ?? 0)
            let hi = Vec2(all.map(\.x).max() ?? 1, all.map(\.y).max() ?? 1)
            cell = max(max(hi.x - lo.x, hi.y - lo.y) / 64, 1e-3)
            for (t, p) in tris2.enumerated() {
                let x0 = Int(((p.map(\.x).min()! - lo.x) / cell).rounded(.down)), x1 = Int(((p.map(\.x).max()! - lo.x) / cell).rounded(.down))
                let y0 = Int(((p.map(\.y).min()! - lo.y) / cell).rounded(.down)), y1 = Int(((p.map(\.y).max()! - lo.y) / cell).rounded(.down))
                for x in x0...x1 { for y in y0...y1 { cells[SIMD2(x, y), default: []].append(t) } }
            }
        }
        func occludes(_ q: Vec2, depth: Double, ignoring: Set<Int>, tris: [(v: [Int], face: Int, normal: Vec3)], points: [Vec3], look: Vec3, eps: Double) -> Bool {
            let key = SIMD2(Int(((q.x - lo.x) / cell).rounded(.down)), Int(((q.y - lo.y) / cell).rounded(.down)))
            for t in cells[key] ?? [] where !ignoring.contains(t) {
                let p = tris2[t]
                // Barycentric coordinates of q in the projected triangle.
                let v0 = p[1] - p[0], v1 = p[2] - p[0], v2 = q - p[0]
                let den = v0.cross(v1)
                guard abs(den) > 1e-14 else { continue }
                let b1 = v2.cross(v1) / den, b2 = v0.cross(v2) / den, b0 = 1 - b1 - b2
                let inside = -1e-9
                guard b0 > inside, b1 > inside, b2 > inside else { continue }
                let v = tris[t].v
                let z = points[v[0]].dot(look) * b0 + points[v[1]].dot(look) * b1 + points[v[2]].dot(look) * b2
                if z < depth - eps { return true }
            }
            return false
        }
    }

    // MARK: Annotations

    static func number(_ v: Double) -> String {
        let r = (v * 100).rounded() / 100
        return r == r.rounded() ? String(format: "%.0f", r) : String(format: "%.2f", r).replacingOccurrences(of: "0$", with: "", options: .regularExpression).replacingOccurrences(of: ".", with: ",")
    }

    static func rect(_ s: inout DrawingSheet, _ x0: Double, _ y0: Double, _ x1: Double, _ y1: Double, _ style: DrawingSheet.Style) {
        let p = [Vec2(x0, y0), Vec2(x1, y0), Vec2(x1, y1), Vec2(x0, y1)]
        for i in 0..<4 { s.lines.append(.init(a: p[i], b: p[(i + 1) % 4], style: style)) }
    }

    static func arrow(_ s: inout DrawingSheet, tip: Vec2, from: Vec2) {
        let d = (tip - from).normalized, n = Vec2(-d.y, d.x)
        s.arrows.append([tip, tip - d * 3 + n * 0.6, tip - d * 3 - n * 0.6])
    }

    /// Linear dimension between two sheet points, its line `offset` mm to the left of a→b.
    static func dimension(_ s: inout DrawingSheet, from a: Vec2, to b: Vec2, offset: Double, value: Double) {
        let d = (b - a).normalized, n = Vec2(-d.y, d.x) * (offset < 0 ? -1 : 1)
        let o = abs(offset)
        let a1 = a + n * o, b1 = b + n * o
        s.lines.append(.init(a: a + n * 1.5, b: a + n * (o + 2), style: .thin))
        s.lines.append(.init(a: b + n * 1.5, b: b + n * (o + 2), style: .thin))
        s.lines.append(.init(a: a1, b: b1, style: .thin))
        arrow(&s, tip: a1, from: b1)
        arrow(&s, tip: b1, from: a1)
        var angle = atan2(d.y, d.x) * 180 / .pi
        if angle > 90 || angle <= -90 { angle += 180 }
        // Text above its line, as read (ISO 129).
        let up = Vec2(-sin(angle * .pi / 180), cos(angle * .pi / 180))
        s.texts.append(.init(at: (a1 + b1) * 0.5 + up * 1.0, text: number(value), size: 3.5, align: .center, angle: angle))
    }

    static func titleBlock(_ s: inout DrawingSheet, x1: Double, y0: Double, width: Double, height: Double, info: Info, scale: String, format: SheetFormat) {
        let x0 = x1 - width, y1 = y0 + height
        rect(&s, x0, y0, x1, y1, .border)
        let row = height / 3
        for k in 1...2 { s.lines.append(.init(a: Vec2(x0, y0 + row * Double(k)), b: Vec2(x1, y0 + row * Double(k)), style: .visible)) }
        let c1 = x0 + 110, c2 = x0 + 145
        s.lines.append(.init(a: Vec2(c1, y0), b: Vec2(c1, y1 - row), style: .visible))
        s.lines.append(.init(a: Vec2(c2, y0), b: Vec2(c2, y1 - row), style: .visible))
        func label(_ t: String, _ x: Double, _ y: Double) { s.texts.append(.init(at: Vec2(x + 1.5, y + row - 3.2), text: t, size: 2, align: .left)) }
        func value(_ t: String, _ x: Double, _ y: Double, size: Double = 3.5) { s.texts.append(.init(at: Vec2(x + 2, y + 2), text: t, size: size, align: .left)) }
        let df = DateFormatter(); df.dateFormat = "dd/MM/yyyy"
        label("Denominazione", x0, y1 - row); value(info.title, x0, y1 - row, size: 5)
        label("Materiale", x0, y0 + row); value(info.material.isEmpty ? "—" : info.material, x0, y0 + row)
        label("Disegnato da", x0, y0); value(info.author.isEmpty ? "CAD Takeoff" : info.author, x0, y0)
        label("Scala", c1, y0 + row); value(scale, c1, y0 + row)
        label("Data", c1, y0); value(df.string(from: info.date), c1, y0, size: 3)
        label("Formato", c2, y0 + row); value(format.rawValue, c2, y0 + row)
        label("Proiezione", c2, y0)
        // ISO E (first angle) symbol: truncated cone seen from the side and from its end.
        let sx = c2 + 5, sy = y0 + 1.5
        let cone = [Vec2(sx, sy + 1), Vec2(sx + 10, sy + 0), Vec2(sx + 10, sy + 6), Vec2(sx, sy + 5)]
        for i in 0..<4 { s.lines.append(.init(a: cone[i], b: cone[(i + 1) % 4], style: .visible)) }
        let cc = Vec2(sx + 17, sy + 3)
        for (r, style) in [(3.0, DrawingSheet.Style.visible), (2.0, .visible)] {
            for k in 0..<24 {
                let t0 = Double(k) / 24 * 2 * .pi, t1 = Double(k + 1) / 24 * 2 * .pi
                s.lines.append(.init(a: cc + Vec2(cos(t0), sin(t0)) * r, b: cc + Vec2(cos(t1), sin(t1)) * r, style: style))
            }
        }
        s.texts.append(.init(at: Vec2(x1 - 2, y1 - row + 2), text: "CAD Takeoff", size: 2.5, align: .right))
    }
}

extension Vec2 {
    public var normalized: Vec2 { let l = length; return l > 0 ? Vec2(x / l, y / l) : self }
}
