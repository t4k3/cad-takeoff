import Foundation

/// STEP AP214 (ISO 10303-21, «automotive design») writer: one manifold solid B-rep per body, in
/// millimetres, with the body's colour. Every plane of the part is one face with its outline and
/// holes; curved surfaces are written as their facets (the mesh's own planar pieces), which every
/// CAD and CAM program reads.
public enum STEPExporter {
    public struct Part {
        public var name: String
        public var mesh: Mesh
        public var snapshot: BodySnapshot
        public var color: PartColor

        public init(name: String, mesh: Mesh, snapshot: BodySnapshot, color: PartColor) {
            self.name = name; self.mesh = mesh; self.snapshot = snapshot; self.color = color
        }
    }

    /// The evaluated, visible bodies of a design.
    public static func parts(of document: CADDocument, components: DesignEvaluator.ComponentResolver? = nil) -> [Part] {
        DesignEvaluator.evaluate(document, revision: "step", components: components).bodies.filter(\.isVisible).map {
            Part(name: $0.source.name, mesh: $0.mesh, snapshot: $0.snapshot, color: $0.source.color)
        }
    }

    public static func export(_ parts: [Part], name: String = "Design", date: Date = Date()) throws -> String {
        guard !parts.isEmpty else { throw KernelError.invalidParameter("STEP: nessun corpo visibile da esportare") }
        var w = Writer()
        let stamp = ISO8601DateFormatter().string(from: date)
        // Product structure and units.
        let appContext = w.add("APPLICATION_CONTEXT('core data for automotive mechanical design processes')")
        w.add("APPLICATION_PROTOCOL_DEFINITION('international standard','automotive_design',2000,\(appContext))")
        let productContext = w.add("PRODUCT_CONTEXT('',\(appContext),'mechanical')")
        let product = w.add("PRODUCT(\(w.text(name)),\(w.text(name)),'',(\(productContext)))")
        w.add("PRODUCT_RELATED_PRODUCT_CATEGORY('part',$,(\(product)))")
        let formation = w.add("PRODUCT_DEFINITION_FORMATION('','',\(product))")
        let definitionContext = w.add("PRODUCT_DEFINITION_CONTEXT('part definition',\(appContext),'design')")
        let definition = w.add("PRODUCT_DEFINITION('design','',\(formation),\(definitionContext))")
        let shape = w.add("PRODUCT_DEFINITION_SHAPE('','',\(definition))")
        let length = w.add("(LENGTH_UNIT()NAMED_UNIT(*)SI_UNIT(.MILLI.,.METRE.))")
        let angle = w.add("(NAMED_UNIT(*)PLANE_ANGLE_UNIT()SI_UNIT($,.RADIAN.))")
        let solidAngle = w.add("(NAMED_UNIT(*)SI_UNIT($,.STERADIAN.)SOLID_ANGLE_UNIT())")
        let uncertainty = w.add("UNCERTAINTY_MEASURE_WITH_UNIT(LENGTH_MEASURE(1.E-05),\(length),'distance_accuracy_value','confusion accuracy')")
        let context = w.add("(GEOMETRIC_REPRESENTATION_CONTEXT(3)GLOBAL_UNCERTAINTY_ASSIGNED_CONTEXT((\(uncertainty)))GLOBAL_UNIT_ASSIGNED_CONTEXT((\(length),\(angle),\(solidAngle)))REPRESENTATION_CONTEXT('Context3D','3D Context with UNIT and UNCERTAINTY'))")
        let origin = w.placement(Vec3.zero, normal: Vec3(0, 0, 1), reference: Vec3(1, 0, 0))

        var solids: [String] = [], styled: [String] = []
        for part in parts {
            // Exact planes and cylinders where the body allows it, else every face as facets.
            let brep: String
            var trial = w
            if let exact = try? exactSolid(part, into: &trial) { w = trial; brep = exact } else { brep = try solid(part, into: &w) }
            solids.append(brep)
            let c = part.color
            let colour = w.add("COLOUR_RGB('',\(w.real(Double(c.red) / 255)),\(w.real(Double(c.green) / 255)),\(w.real(Double(c.blue) / 255)))")
            let fillColour = w.add("FILL_AREA_STYLE_COLOUR('',\(colour))")
            let fill = w.add("FILL_AREA_STYLE('',(\(fillColour)))")
            let area = w.add("SURFACE_STYLE_FILL_AREA(\(fill))")
            let side = w.add("SURFACE_SIDE_STYLE('',(\(area)))")
            let usage = w.add("SURFACE_STYLE_USAGE(.BOTH.,\(side))")
            let assignment = w.add("PRESENTATION_STYLE_ASSIGNMENT((\(usage)))")
            styled.append(w.add("STYLED_ITEM('colour',(\(assignment)),\(brep))"))
        }
        let representation = w.add("ADVANCED_BREP_SHAPE_REPRESENTATION(\(w.text(name)),(\(([origin] + solids).joined(separator: ","))),\(context))")
        w.add("SHAPE_DEFINITION_REPRESENTATION(\(shape),\(representation))")
        w.add("MECHANICAL_DESIGN_GEOMETRIC_PRESENTATION_REPRESENTATION('',(\(styled.joined(separator: ","))),\(context))")

        let fileName = name.replacingOccurrences(of: "'", with: "") + ".step"
        return """
        ISO-10303-21;
        HEADER;
        FILE_DESCRIPTION(('CAD Takeoff'),'2;1');
        FILE_NAME(\(w.text(fileName)),'\(stamp)',(''),(''),'CAD Takeoff','CAD Takeoff','');
        FILE_SCHEMA(('AUTOMOTIVE_DESIGN { 1 0 10303 214 1 1 1 1 }'));
        ENDSEC;
        DATA;
        \(w.lines.joined(separator: "\n"))
        ENDSEC;
        END-ISO-10303-21;

        """
    }

    // MARK: One body

    private static func solid(_ part: Part, into w: inout Writer) throws -> String {
        let s = part.snapshot
        // Weld the shading-split positions back into shared vertices.
        var index: [SIMD3<Int64>: Int] = [:]
        var points: [Vec3] = []
        func key(_ p: Vec3) -> SIMD3<Int64> { SIMD3(Int64((p.x * 1e7).rounded()), Int64((p.y * 1e7).rounded()), Int64((p.z * 1e7).rounded())) }
        let corner = s.triangles.map { i -> Int in
            let p = s.positions[Int(i)], k = key(p)
            if let v = index[k] { return v }
            points.append(p); index[k] = points.count - 1
            return points.count - 1
        }
        let count = corner.count / 3
        // Triangles grouped into planar pieces: one per plane face, per facet plane on curved ones.
        struct PieceKey: Hashable { let face: Int; let n: SIMD3<Int64>; let d: Int64 }
        var pieces: [PieceKey: [Int]] = [:], order: [PieceKey] = [], normals: [PieceKey: Vec3] = [:]
        for t in 0..<count {
            let a = points[corner[t * 3]], b = points[corner[t * 3 + 1]], c = points[corner[t * 3 + 2]]
            let cross = (b - a).cross(c - a)
            guard cross.length > 1e-14, Set([corner[t * 3], corner[t * 3 + 1], corner[t * 3 + 2]]).count == 3 else { continue }
            let f = Int(s.triangleFace[t])
            let pk: PieceKey
            if case let .plane(_, n) = s.faces[f].surface {
                pk = PieceKey(face: f, n: .zero, d: 0)
                normals[pk] = n.normalized
            } else {
                let n = cross.normalized
                pk = PieceKey(face: f, n: SIMD3(Int64((n.x * 1e5).rounded()), Int64((n.y * 1e5).rounded()), Int64((n.z * 1e5).rounded())),
                              d: Int64((n.dot(a) * 1e4).rounded()))
                if normals[pk] == nil { normals[pk] = n }
            }
            if pieces[pk] == nil { order.append(pk) }
            pieces[pk, default: []].append(t)
        }

        var vertexIDs: [Int: String] = [:]
        func vertex(_ v: Int) -> String {
            if let id = vertexIDs[v] { return id }
            let id = w.add("VERTEX_POINT('',\(w.point(points[v])))")
            vertexIDs[v] = id
            return id
        }
        struct EdgeKey: Hashable { let a: Int, b: Int }
        var edgeIDs: [EdgeKey: String] = [:]
        func oriented(_ a: Int, _ b: Int) -> String {
            let k = EdgeKey(a: min(a, b), b: max(a, b))
            let curve: String
            if let id = edgeIDs[k] { curve = id } else {
                let p = points[k.a], q = points[k.b]
                let line = w.add("LINE('',\(w.point(p)),\(w.add("VECTOR('',\(w.direction((q - p).normalized)),\(w.real((q - p).length)))")))")
                curve = w.add("EDGE_CURVE('',\(vertex(k.a)),\(vertex(k.b)),\(line),.T.)")
                edgeIDs[k] = curve
            }
            return w.add("ORIENTED_EDGE('',*,*,\(curve),\(a == k.a ? ".T." : ".F."))")
        }

        var faces: [String] = []
        for pk in order {
            let tris = pieces[pk]!
            let normal = normals[pk]!
            // Boundary: directed edges whose reverse is not in the piece; chained into loops.
            var directed = Set<EdgeKey>()
            for t in tris { for k in 0..<3 { directed.insert(EdgeKey(a: corner[t * 3 + k], b: corner[t * 3 + (k + 1) % 3])) } }
            var next: [Int: [Int]] = [:]
            for e in directed where !directed.contains(EdgeKey(a: e.b, b: e.a)) { next[e.a, default: []].append(e.b) }
            var loops: [[Int]] = []
            while let start = next.keys.sorted().first {
                var loop = [start]
                var at = start
                while true {
                    guard var outs = next[at], let to = outs.popLast() else { break }
                    next[at] = outs.isEmpty ? nil : outs
                    if to == start { break }
                    loop.append(to)
                    at = to
                    if loop.count > points.count + 1 { throw KernelError.invalidTopology("STEP: contorno di faccia non chiuso") }
                }
                if loop.count >= 3 { loops.append(loop) }
            }
            guard !loops.isEmpty else { continue }
            // Outer outlines turn counter-clockwise about the normal, holes the other way.
            let helper = abs(normal.z) < 0.9 ? Vec3(0, 0, 1) : Vec3(1, 0, 0)
            let u = helper.cross(normal).normalized, v = normal.cross(u)
            func flat(_ loop: [Int]) -> [Vec2] { loop.map { Vec2(points[$0].dot(u), points[$0].dot(v)) } }
            func area(_ p: [Vec2]) -> Double {
                var a = 0.0
                for i in p.indices { let q = p[i], r = p[(i + 1) % p.count]; a += q.x * r.y - r.x * q.y }
                return a / 2
            }
            let outers = loops.filter { area(flat($0)) > 0 }, holes = loops.filter { area(flat($0)) <= 0 }
            var holesOf = [[[Int]]](repeating: [], count: outers.count)
            for h in holes {
                let probe = flat(h)[0]
                let host = outers.indices.filter { SketchArrangement.inside(probe, flat(outers[$0])) }
                    .min { area(flat(outers[$0])) < area(flat(outers[$1])) } ?? outers.indices.first
                if let host { holesOf[host].append(h) }
            }
            for (k, outer) in outers.enumerated() {
                func loopEntity(_ l: [Int]) -> String {
                    let edges = l.indices.map { oriented(l[$0], l[($0 + 1) % l.count]) }
                    return w.add("EDGE_LOOP('',(\(edges.joined(separator: ","))))")
                }
                var bounds = [w.add("FACE_OUTER_BOUND('',\(loopEntity(outer)),.T.)")]
                for h in holesOf[k] { bounds.append(w.add("FACE_BOUND('',\(loopEntity(h)),.T.)")) }
                let plane = w.add("PLANE('',\(w.placement(points[outer[0]], normal: normal, reference: u)))")
                faces.append(w.add("ADVANCED_FACE('',(\(bounds.joined(separator: ","))),\(plane),.T.)"))
            }
        }
        guard !faces.isEmpty else { throw KernelError.invalidTopology("STEP: corpo «\(part.name)» vuoto") }
        let shell = w.add("CLOSED_SHELL('',(\(faces.joined(separator: ","))))")
        return w.add("MANIFOLD_SOLID_BREP(\(w.text(part.name)),\(shell))")
    }

    // MARK: Entities

    struct Writer {
        var lines: [String] = []
        @discardableResult
        mutating func add(_ entity: String) -> String {
            lines.append("#\(lines.count + 1)=\(entity);")
            return "#\(lines.count)"
        }
        func text(_ s: String) -> String {
            // Apostrophes doubled; non-ASCII letters written as \X2\…\X0\ (ISO 10303-21).
            var out = ""
            for ch in s.unicodeScalars {
                if ch == "'" { out += "''" } else if ch == "\\" { out += "\\\\" }
                else if ch.isASCII { out.unicodeScalars.append(ch) }
                else { out += "\\X2\\" + String(format: "%04X", ch.value) + "\\X0\\" }
            }
            return "'" + out + "'"
        }
        func real(_ x: Double) -> String {
            let v = abs(x) < 1e-12 ? 0 : x
            if v == v.rounded(), abs(v) < 1e15 { return String(format: "%.0f.", v) }
            var s = String(format: "%.12G", v)
            if !s.contains(".") {
                if let e = s.firstIndex(of: "E") { s.insert(".", at: e) } else { s += "." }
            }
            return s
        }
        mutating func point(_ p: Vec3) -> String { add("CARTESIAN_POINT('',(\(real(p.x)),\(real(p.y)),\(real(p.z))))") }
        mutating func direction(_ d: Vec3) -> String { add("DIRECTION('',(\(real(d.x)),\(real(d.y)),\(real(d.z))))") }
        mutating func placement(_ p: Vec3, normal: Vec3, reference: Vec3) -> String {
            let o = point(p), n = direction(normal), r = direction(reference)
            return add("AXIS2_PLACEMENT_3D('',\(o),\(n),\(r))")
        }
    }
}
