import Foundation
import CADCore

extension DesignModel: CADToolProvider {
    var tools: [ToolSpec] { CADToolCatalog.tools }

    func call(_ name: String, arguments: JSONValue) async -> ToolResult {
        do {
            try Task.checkCancellation()
            guard let spec = tools.first(where: { $0.name == name }) else { throw CADToolFailure("Strumento non disponibile: \(name). Leggere tools/list.") }
            guard case let .object(args) = arguments,
                  case let .object(properties)? = spec.inputSchema["properties"] else { throw CADToolFailure("Gli argomenti devono essere un oggetto JSON.") }
            let unknown = Set(args.keys).subtracting(properties.keys)
            guard unknown.isEmpty else { throw CADToolFailure("Parametri sconosciuti: \(unknown.sorted().joined(separator: ", ")).") }
            for key in spec.inputSchema["required"]?.array?.compactMap(\.string) ?? [] {
                guard args[key] != nil else { throw CADToolFailure("Parametro richiesto: \(key).") }
            }
            if !spec.isReadOnly {
                guard try string(args, "expected_revision") == designRevision else {
                    throw CADToolFailure("Conflitto di revisione: la scena è cambiata. Rileggere scene_info e ricalcolare la modifica.")
                }
            }
            switch name {
            case "list_features":
                return result("\(document.features.count) geometrie", ["features": .array(document.features.map(describe))])
            case "get_feature":
                return result("Parametri geometria", ["feature": describe(document.features[try index(args)])])
            case "list_sketches": return try listSketches()
            case "get_sketch": return try getSketch(args)
            case "scene_info": return try sceneInfo()
            case "export_stl": return try export(args)
            case "export_3mf": return try export3MF(args)
            case "export_step": return try exportSTEP(args)
            case "export_drawing": return try exportDrawing(args)
            case "list_parameters":
                let values = try? document.parameterValues()
                return result("\(document.parameters.count) parametri", ["parameters": .array(document.parameters.map { p in
                    ["name": .string(p.name), "expression": .string(p.expression), "comment": .string(p.comment),
                     "value": values?[p.name].map { .number($0) } ?? .null] })])
            case "set_parameters":
                var list = document.parameters
                let removed = Set(args["remove"]?.array?.compactMap(\.string) ?? [])
                list.removeAll { removed.contains($0.name) }
                for item in args["parameters"]?.array ?? [] {
                    guard let n = item["name"]?.string, let e = item["expression"]?.string else { throw CADToolFailure("Ogni parametro vuole name ed expression.") }
                    if let i = list.firstIndex(where: { $0.name == n }) {
                        list[i].expression = e
                        if let c = item["comment"]?.string { list[i].comment = c }
                    } else {
                        list.append(UserParameter(name: n, expression: e, comment: item["comment"]?.string ?? ""))
                    }
                }
                do { try setParameters(list, title: "Assistente: parametri") } catch { throw CADToolFailure(error.localizedDescription) }
                let values = try document.parameterValues()
                return result("Parametri aggiornati", ["changed": true, "parameters": .array(document.parameters.map { p in
                    ["name": .string(p.name), "expression": .string(p.expression), "value": values[p.name].map { .number($0) } ?? .null] })])
            case "list_project_designs":
                let paths = projectDesigns?() ?? []
                return result("\(paths.count) disegni nel progetto", ["designs": .array(paths.map { p in
                    ["path": .string(p), "name": .string(ComponentRef(path: p).partName)] })])
            case "bill_of_materials":
                let rows = billOfMaterials()
                return result("\(rows.count) righe di distinta", ["rows": .array(rows.enumerated().map { i, r in
                    ["position": .number(Double(i + 1)), "name": .string(r.name), "quantity": .number(Double(r.quantity)),
                     "material": .string(r.material), "volume_mm3": .number(r.volume),
                     "mass_kg": r.mass.map { .number($0) } ?? .null, "path": .string(r.path)] })])
            case "export_flat_dxf":
                let id = args["feature_id"] == nil ? nil : document.features[try index(args)].id
                let (name, dxf) = try flatPatternDXF(id)
                let data = Data(dxf.utf8)
                let part = sheetParts().first { $0.feature.name == name }
                return result("DXF dello sviluppo pronto", [
                    "filename": .string("\(name) - sviluppo.dxf"), "mime_type": "image/vnd.dxf", "encoding": "base64",
                    "data": .string(data.base64EncodedString()), "bytes": .number(Double(data.count)), "coordinate_units": "mm",
                    "holes": .number(Double(part?.flat.holes.count ?? 0)), "cutouts": .number(Double(part?.flat.cutouts.count ?? 0)), "skipped_holes": .number(Double(part?.skippedHoles ?? 0))
                ])
            case "undo": return try restore(redo: false)
            case "redo": return try restore(redo: true)
            default: return try mutate(name, args: args, title: spec.title)
            }
        } catch {
            return result(error.localizedDescription, ["error": .string(error.localizedDescription)], error: true)
        }
    }

    private func mutate(_ name: String, args: [String: JSONValue], title: String) throws -> ToolResult {
        var next = document
        var selected = selection
        let changed: UUID
        if name == "add_sketch" { return try addSketch(args, title: title) }
        if name == "extrude_sketch" { return try extrudeSketch(args, title: title) }
        if name == "add_chamfer" {
            let (f, warnings) = try chamfer(args, title: title)
            next.features.append(f)
            commitEdit(next, selected: selected, title: "Assistente: \(title)", changed: [f.id])
            var fields: [String: JSONValue] = ["changed": true, "feature_id": .string(f.id.uuidString), "edge_count": .number(Double(warnings.edges))]
            if !warnings.messages.isEmpty { fields["warnings"] = .array(warnings.messages.map { .string($0) }) }
            return result(statusMessage, fields, changed: [f.id])
        }
        if name.hasPrefix("add_") {
            guard next.features.count < 256 else { throw CADToolFailure("Limite prototipo: 256 geometrie per documento.") }
            let kind: Feature.Kind
            switch name {
            case "add_box": kind = .box(width: try number(args, "width"), depth: try number(args, "depth"), height: try number(args, "height"))
            case "add_cylinder": kind = .cylinder(radius: try number(args, "radius"), height: try number(args, "height"))
            case "add_extrude": kind = .extrude(profile: Profile2D(points: try points(args)), height: try number(args, "height"))
            case "add_hole": kind = .hole(try holeSpec(args))
            case "add_sheet_metal": kind = .sheetMetal(try sheetSpec(args))
            case "add_pattern": kind = .pattern(try patternSpec(args))
            case "add_component":
                let path = try string(args, "path")
                guard componentResolver?(path) != nil else { throw CADToolFailure("Disegno non trovato: \(path). Usa list_project_designs.") }
                var rotation = Vec3.zero
                if let r = args["rotation"], let x = r["x"]?.number, let y = r["y"]?.number, let z = r["z"]?.number { rotation = Vec3(x, y, z) }
                kind = .component(ComponentRef(path: path, rotation: rotation))
            case "add_split":
                let source = document.features[try index(args, key: "body_feature_id")].id
                guard let plane = PatternSpec.MirrorPlane(rawValue: try string(args, "plane")) else { throw CADToolFailure("plane: yz, xz o xy.") }
                let keep = args["keep"] == nil ? SplitSpec.Keep.both : (SplitSpec.Keep(rawValue: try string(args, "keep")) ?? .both)
                kind = .split(SplitSpec(body: source, plane: plane, offset: try number(args, "offset"), keep: keep))
            default: throw CADToolFailure("Comando non supportato.")
            }
            var placement: FeaturePlacement?
            if name == "add_extrude", let fp = args["face_point"], let fn = args["face_normal"] {
                guard let px = fp["x"]?.number, let py = fp["y"]?.number, let pz = fp["z"]?.number,
                      let nx = fn["x"]?.number, let ny = fn["y"]?.number, let nz = fn["z"]?.number, Vec3(nx, ny, nz).length > 0.5 else {
                    throw CADToolFailure("face_point e face_normal: vettori {x,y,z}.")
                }
                placement = FeaturePlacement(plane: SketchPlane.onFace(point: Vec3(px, py, pz), normal: Vec3(nx, ny, nz)),
                                             reversed: args["into_part"]?.bool ?? false)
            }
            var defaultName = "\(title) \(next.features.count + 1)"
            if case let .component(ref) = kind { defaultName = ref.partName }
            let f = Feature(name: try args["name"].map { _ in try string(args, "name") } ?? defaultName,
                            kind: kind, position: try position(args) ?? .zero,
                            color: try args["color"].map { _ in try color(args) }
                                ?? (name == "add_sheet_metal" ? PartColor(hex: "#7F8B97")! : .defaultColor),
                            operation: name == "add_hole" ? .cut : (try operation(args) ?? .newBody),
                            placement: placement)
            try CADToolValidation.feature(f)
            if f.kind.actsOnBodies {
                // Copies exist only on the evaluated body: check the evaluation instead of a mesh.
                var check = next
                check.features.append(f)
                if let issue = DesignEvaluator.evaluate(check, revision: "check", components: componentResolver).issues.first(where: { $0.featureID == f.id }) {
                    throw CADToolFailure(issue.message)
                }
            } else {
                try CADToolValidation.mesh(f.buildMesh())
            }
            next.features.append(f); changed = f.id; selected = f.id
        } else {
            let i = try index(args)
            changed = next.features[i].id
            switch name {
            case "delete_feature": next.features.remove(at: i); if selected == changed { selected = nil }
            case "set_color": next.features[i].color = try color(args)
            case "set_visibility":
                guard let visible = args["visible"]?.bool else { throw CADToolFailure("visible deve essere booleano.") }
                next.features[i].isVisible = visible
            case "update_feature":
                var f = next.features[i]
                if args["name"] != nil { f.name = try string(args, "name") }
                if args["color"] != nil { f.color = try color(args) }
                if let p = try position(args) { f.position = p }
                if let op = try operation(args) { f.operation = op }
                let legal: Set<String>
                switch f.kind {
                case let .box(w, d, h):
                    legal = ["width", "depth", "height"]
                    f.kind = .box(width: try optionalNumber(args, "width", w), depth: try optionalNumber(args, "depth", d), height: try optionalNumber(args, "height", h))
                case let .cylinder(r, h):
                    legal = ["radius", "height"]
                    f.kind = .cylinder(radius: try optionalNumber(args, "radius", r), height: try optionalNumber(args, "height", h))
                case .hole, .chamfer, .sheetMetal, .component, .importedMesh, .pattern, .split, .combine, .thread:
                    legal = []   // re-create with add_hole/add_chamfer/add_sheet_metal or edit in the app
                case var .joint(spec):
                    legal = ["angle", "offset"]
                    spec.angle = try optionalNumber(args, "angle", spec.angle)
                    if args["offset"] != nil { spec.offset = args["offset"]?.number ?? spec.offset }
                    f.kind = .joint(spec)
                case var .move(spec):
                    legal = ["angle"]
                    spec.angle = try optionalNumber(args, "angle", spec.angle)
                    f.kind = .move(spec)
                case var .shell(spec):
                    legal = ["thickness"]
                    spec.thickness = try optionalNumber(args, "thickness", spec.thickness)
                    f.kind = .shell(spec)
                case var .revolve(spec):
                    legal = ["angle"]
                    spec.angle = try optionalNumber(args, "angle", spec.angle)
                    f.kind = .revolve(spec)
                case let .extrude(p, h):
                    legal = ["points", "height"]
                    f.kind = .extrude(profile: args["points"] == nil ? p : Profile2D(points: try points(args)), height: try optionalNumber(args, "height", h))
                }
                let supplied = Set(args.keys).subtracting(["name", "position", "color", "operation", "feature_id", "expected_revision"])
                guard supplied.isSubset(of: legal) else { throw CADToolFailure("Parametro non applicabile al tipo di geometria selezionato.") }
                try CADToolValidation.feature(f)
                try CADToolValidation.mesh(f.buildMesh())
                next.features[i] = f; selected = f.id
            default: throw CADToolFailure("Comando non supportato.")
            }
        }
        guard next != document else { return result("Nessuna modifica necessaria", ["changed": false]) }
        commitEdit(next, selected: selected, title: "Assistente: \(title)", changed: [changed])
        var fields: [String: JSONValue] = ["changed": true, "feature_id": .string(changed.uuidString)]
        if let f = next.features.first(where: { $0.id == changed }), case let .sheetMetal(spec) = f.kind,
           let build = try? SheetMetalGeometry.build(spec, featureID: f.id, position: f.position) {
            fields["inside_radius"] = .number(build.rule.insideRadius)
            fields["k_factor"] = .number(build.rule.kFactor)
            fields["flat_size"] = ["x": .number(build.flat.size.width), "y": .number(build.flat.size.height)]
            fields["warnings"] = .array(build.warnings.map { .string($0) })
        }
        return result(statusMessage, fields, changed: [changed])
    }

    /// The assistant may only undo/redo its own steps: a change made by the user is never undone by it.
    private func restore(redo: Bool) throws -> ToolResult {
        let author = redo ? nextRedoAuthor : lastEditAuthor
        guard let author else {
            throw CADToolFailure(redo ? "Nessuna operazione da ripetere." : "Nessuna operazione da annullare.")
        }
        guard author == .assistant else {
            throw CADToolFailure(redo ? "L'operazione da ripetere è dell'utente: usa ⌘⇧Z nell'app."
                                      : "L'ultima modifica è stata fatta dall'utente: l'assistente non la annulla.")
        }
        guard let entry = redo ? self.redo() : self.undo() else { throw CADToolFailure("Nessuna operazione.") }
        return result(statusMessage, ["changed": true], changed: entry.changed)
    }

    private func sceneInfo() throws -> ToolResult {
        let (bodies, issues) = evaluation()
        let visible = bodies.filter(\.isVisible)
        let mesh = Mesh.merged(visible.map(\.mesh))
        // Each body on its own: overlapping separate bodies share edges in a merged mesh, which
        // would read as "open" although every body is closed.
        let open = visible.filter { !$0.mesh.isEmpty && !MeshValidator.validate($0.mesh).isWatertight }
        return result("Scena in millimetri, Z verso l'alto", [
            "units": "mm", "up_axis": "Z", "feature_count": .number(Double(document.features.count)),
            "visible_count": .number(Double(visible.count)), "triangles": .number(Double(mesh.triangleCount)),
            "mesh_volume_mm3": .number(mesh.volume), "bounds": bounds(mesh.bounds),
            "edge_closed": visible.isEmpty ? .null : .bool(open.isEmpty),
            "open_bodies": .array(open.map { .string($0.source.name) }),
            "body_count": .number(Double(bodies.count)),
            "issues": .array(issues.map { ["feature_id": .string($0.featureID.uuidString), "message": .string($0.message)] }),
            "warning": "Corpi separati non si fondono tra loro: usa operation join per unirli. La chiusura dei bordi non certifica la stampabilità.",
            "capabilities": ["box", "cylinder", "simple_polygon_extrude", "boolean_join_cut_intersect", "hole", "chamfer", "fillet", "sheet_metal",
                             "parameter_update", "timeline_rollback_suppress", "session_undo", "stl", "part_color", "3mf"],
            "unavailable": ["modeled_thread", "step"]
        ])
    }

    private func export(_ args: [String: JSONValue]) throws -> ToolResult {
        let all = exportEvaluation(fine: args["quality"]?.string != "normal").bodies
        let bodies: [DesignEvaluator.Body]
        if args["feature_id"] != nil {
            let id = document.features[try index(args)].id
            guard let b = all.first(where: { $0.id == id }) else { throw CADToolFailure("Questa operazione non crea un corpo: esporta il corpo che modifica.") }
            bodies = [b]
        } else { bodies = all.filter(\.isVisible) }
        guard !bodies.isEmpty else { throw CADToolFailure("Niente da esportare.") }
        for b in bodies { try CADToolValidation.mesh(b.mesh) }
        let mesh = Mesh.merged(bodies.map(\.mesh))
        // STL stores Float32. Validate the actual quantized geometry before promising a closed export.
        let floatMesh = Mesh(vertices: mesh.vertices.map { Vec3(Double(Float($0.x)), Double(Float($0.y)), Double(Float($0.z))) }, indices: mesh.indices)
        try CADToolValidation.mesh(floatMesh)
        let data = STLExporter.binary(floatMesh)
        guard data.count <= 8 * 1024 * 1024 else { throw CADToolFailure("Export troppo grande per la chat (8 MiB). Usare il pannello esportazione.") }
        return result("STL binario pronto; \(mesh.triangleCount) triangoli", [
            "filename": "Design.stl", "mime_type": "model/stl", "encoding": "base64", "data": .string(data.base64EncodedString()),
            "bytes": .number(Double(data.count)), "coordinate_units": "mm",
            "warning": "STL senza metadati unità. Solidi concatenati: non è stata eseguita una unione booleana."
        ])
    }

    private func exportDrawing(_ args: [String: JSONValue]) throws -> ToolResult {
        let bodies = evaluation().bodies.filter(\.isVisible).map { (mesh: $0.mesh, snapshot: $0.snapshot) }
        guard !bodies.isEmpty else { throw CADToolFailure("Niente da disegnare.") }
        let title = args["title"]?.string ?? "Tavola"
        let format = SheetFormat(rawValue: args["format"]?.string ?? "A4") ?? .a4
        let sheet: DrawingSheet
        do { sheet = try TechnicalDrawing.make(bodies, info: .init(title: title, material: args["material"]?.string ?? ""), format: format,
                                                section: args["section"]?.bool ?? false, dimensions: drawingDimensions(), annotations: document.drawing) }
        catch { throw CADToolFailure(error.localizedDescription) }
        let data = PDFWriter.pdf(sheet)
        let scale = sheet.texts.first { t in TechnicalDrawing.scales.contains { $0.1 == t.text } }?.text ?? "?"
        return result("Tavola \(format.rawValue) in scala \(scale)", [
            "filename": .string(title + ".pdf"), "mime_type": "application/pdf", "encoding": "base64", "data": .string(data.base64EncodedString()),
            "bytes": .number(Double(data.count)), "scale": .string(scale),
        ])
    }

    private func exportSTEP(_ args: [String: JSONValue]) throws -> ToolResult {
        let all = evaluation().bodies
        let bodies: [DesignEvaluator.Body]
        if args["feature_id"] != nil {
            let id = document.features[try index(args)].id
            guard let b = all.first(where: { $0.id == id }) else { throw CADToolFailure("Questa operazione non crea un corpo: esporta il corpo che modifica.") }
            bodies = [b]
        } else { bodies = all.filter(\.isVisible) }
        guard !bodies.isEmpty else { throw CADToolFailure("Niente da esportare.") }
        let parts = bodies.map { STEPExporter.Part(name: $0.source.name, mesh: $0.mesh, snapshot: $0.snapshot, color: $0.source.color) }
        let data: Data
        do { data = Data(try STEPExporter.export(parts).utf8) } catch { throw CADToolFailure(error.localizedDescription) }
        guard data.count <= 8 * 1024 * 1024 else { throw CADToolFailure("Export troppo grande per la chat (8 MiB). Usare il pannello esportazione.") }
        return result("STEP AP214 pronto; \(parts.count) solidi", [
            "filename": "Design.step", "mime_type": "model/step", "encoding": "base64", "data": .string(data.base64EncodedString()),
            "bytes": .number(Double(data.count)), "coordinate_units": "mm",
            "warning": "Facce piane esatte, superfici curve sfaccettate."
        ])
    }

    private func result(_ text: String, _ fields: [String: JSONValue], error: Bool = false, changed: [UUID] = []) -> ToolResult {
        var data = fields
        data["revision"] = .string(designRevision)
        data["can_undo"] = .bool(lastEditAuthor == .assistant)
        data["can_redo"] = .bool(nextRedoAuthor == .assistant)
        data["undo_title"] = lastEditAuthor == .assistant ? (undoTitle.map { .string($0) } ?? .null) : .null
        return ToolResult(text: text, structured: .object(data), isError: error, changedFeatures: changed)
    }

    private func export3MF(_ args: [String: JSONValue]) throws -> ToolResult {
        let id = args["feature_id"] == nil ? nil : document.features[try index(args)].id
        let data = try export3MFData(featureID: id, fine: args["quality"]?.string != "normal")
        guard data.count <= 8 * 1024 * 1024 else { throw CADToolFailure("Export troppo grande per la chat (8 MiB). Usare il pannello esportazione.") }
        return result("3MF pronto: parti separate con colori sRGB", [
            "filename": "Design.3mf", "mime_type": "model/3mf", "encoding": "base64", "data": .string(data.base64EncodedString()),
            "bytes": .number(Double(data.count)), "coordinate_units": "mm",
            "warning": "Colori per parte, senza profili stampante o G-code. Verificare l'assegnazione ai filamenti in Bambu Studio/OrcaSlicer. Nessuna unione booleana."
        ])
    }

    private func describe(_ f: Feature) -> JSONValue {
        var value: [String: JSONValue] = ["id": .string(f.id.uuidString), "name": .string(f.name), "position": vector(f.position), "visible": .bool(f.isVisible), "color": .string(f.color.hex), "operation": .string(f.operation.rawValue)]
        // Where its body is and how big (an imported part has no dimensions of its own).
        if let body = evaluation().bodies.first(where: { $0.id == f.id }), let b = body.mesh.bounds { value["bounds"] = bounds(b) }
        switch f.kind {
        case let .box(w, d, h): value.merge(["kind": "box", "width": .number(w), "depth": .number(d), "height": .number(h)]) { _, b in b }
        case let .cylinder(r, h): value.merge(["kind": "cylinder", "radius": .number(r), "height": .number(h)]) { _, b in b }
        case let .extrude(p, h): value.merge(["kind": "extrude", "points": .array(p.points.map { ["x": .number($0.x), "y": .number($0.y)] }), "height": .number(h)]) { _, b in b }
        case let .hole(s):
            let size: JSONValue = s.size.map { JSONValue.string($0) } ?? JSONValue.null
            let depth: JSONValue = s.depth.map { JSONValue.number($0) } ?? JSONValue.string("through")
            let centers = JSONValue.array(s.centers.map(vector))
            value["kind"] = "hole"
            value["summary"] = .string(s.summary)
            value["style"] = .string(s.style.rawValue)
            value["fit"] = .string(s.fit.rawValue)
            value["size"] = size
            value["bore_diameter"] = .number(s.boreDiameter)
            value["depth"] = depth
            value["centers"] = centers
            value["direction"] = vector(s.direction)
        case let .chamfer(s):
            value["kind"] = "chamfer"
            value["profile"] = .string(s.profile.rawValue)
            value["summary"] = .string(s.title)
            value["mode"] = .string(s.mode.rawValue)
            value["distance"] = .number(s.distance)
            if s.mode == .twoDistances { value["distance2"] = .number(s.distance2) }
            if s.mode == .distanceAngle { value["angle"] = .number(s.angle) }
            value["edge_count"] = .number(Double(s.edges.count))
        case let .split(sp):
            value["kind"] = "split"
            value["body_feature_id"] = .string(sp.body.uuidString)
            value["plane"] = .string(sp.plane.rawValue)
            value["offset"] = .number(sp.offset)
            value["keep"] = .string(sp.keep.rawValue)
        case let .pattern(p):
            value["kind"] = p.kind == .mirror ? "mirror" : "pattern"
            value["pattern"] = .string(p.kind.rawValue)
            value["body_feature_id"] = .string(p.body.uuidString)
            value["join"] = .bool(p.join)
        case let .importedMesh(m):
            value["kind"] = "imported_mesh"
            value["source"] = .string(m.source)
            value["triangles"] = .number(Double(m.mesh.triangleCount))
        case let .component(c):
            value["kind"] = "component"
            value["path"] = .string(c.path)
            value["rotation_deg"] = vector(c.rotation)
        case let .sheetMetal(s):
            value["kind"] = "sheet_metal"
            value["summary"] = .string(s.summary)
            value["material"] = .string(s.material)
            value["thickness"] = .number(s.thickness)
            value["width"] = .number(s.width)
            value["depth"] = .number(s.depth)
            if let rule = try? s.rule() {
                value["inside_radius"] = .number(rule.insideRadius)
                value["k_factor"] = .number(rule.kFactor)
                value["v_die"] = .number(rule.vDie)
                value["minimum_flange"] = .number(rule.minimumFlange)
            }
            func describe(_ f: SheetFlange) -> JSONValue {
                var flange: [String: JSONValue] = ["length": .number(f.length), "angle": .number(f.angle),
                                                   "direction": .string(f.direction.rawValue), "reference": .string(f.reference.rawValue)]
                if let lip = f.lip {
                    flange["lip"] = ["length": .number(lip.length), "angle": .number(lip.angle), "side": .string(lip.inward ? "in" : "out")]
                }
                return .object(flange)
            }
            var flanges: [String: JSONValue] = [:]
            if let outline = s.outline {
                // Free-form base: its points, and the flanges by side number (1-based, as outline_sides).
                value["outline"] = .array(outline.map { ["x": .number($0.x), "y": .number($0.y)] })
                for sf in s.sideFlanges ?? [] { flanges[String(sf.side + 1)] = describe(sf.flange) }
            } else {
                for e in SheetEdge.allCases { if let f = s[e] { flanges[e.rawValue] = describe(f) } }
            }
            value["flanges"] = .object(flanges)
            if let build = try? SheetMetalGeometry.build(s, featureID: f.id, position: f.position) {
                value["flat_size"] = ["x": .number(build.flat.size.width), "y": .number(build.flat.size.height)]
                value["warnings"] = .array(build.warnings.map { .string($0) })
            }
        case let .thread(t):
            value["kind"] = "thread"
            value["face_id"] = .string(t.face.rawValue)
            value["size"] = t.size.map { .string($0) } ?? .null
            value["print_allowance"] = .number(t.printAllowance)
        case let .combine(c):
            value["kind"] = "combine"
            value["operation"] = .string(c.operation.rawValue)
            value["target_feature_id"] = .string(c.target.uuidString)
            value["tool_feature_ids"] = .array(c.tools.map { .string($0.uuidString) })
            value["keep_tools"] = .bool(c.keepTools)
        case let .joint(j):
            value["kind"] = "joint"
            value["joint_type"] = .string(j.kind.rawValue)
            value["moving_feature_id"] = .string(j.moving.uuidString)
            value["fixed_feature_id"] = j.fixed.map { .string($0.uuidString) } ?? .null
            value["angle"] = .number(j.angle)
            value["offset"] = .number(j.offset)
        case let .move(m):
            value["kind"] = "move"
            value["translation"] = vector(m.translation)
            value["axis"] = vector(m.axis)
            value["angle"] = .number(m.angle)
            value["bodies"] = .array(m.bodies.map { .string($0.uuidString) })
        case let .shell(s):
            value["kind"] = "shell"
            value["thickness"] = .number(s.thickness)
            value["open_faces"] = .number(Double(s.openFaces.count))
            value["body_feature_id"] = .string(s.body.uuidString)
        case let .revolve(r):
            value["kind"] = "revolve"
            value["angle"] = .number(r.angle)
            value["profile_points"] = .number(Double(r.profile.points.count))
            value["holes"] = .number(Double(f.holes.count))
            value["axis"] = ["start": ["x": .number(r.axisStart.x), "y": .number(r.axisStart.y)], "end": ["x": .number(r.axisEnd.x), "y": .number(r.axisEnd.y)]]
        }
        return .object(value)
    }
    private func vector(_ p: Vec3) -> JSONValue { ["x": .number(p.x), "y": .number(p.y), "z": .number(p.z)] }
    private func bounds(_ b: BoundingBox?) -> JSONValue {
        guard let b else { return .null }
        return ["min": vector(b.min), "max": vector(b.max), "size": vector(b.size)]
    }
    private func index(_ args: [String: JSONValue], key: String = "feature_id") throws -> Int {
        guard let id = UUID(uuidString: try string(args, key)), let i = document.features.firstIndex(where: { $0.id == id }) else {
            throw CADToolFailure("Geometria non trovata: rileggere list_features.")
        }
        return i
    }
    private func string(_ args: [String: JSONValue], _ key: String) throws -> String {
        guard let value = args[key]?.string else { throw CADToolFailure("\(key) deve essere una stringa.") }
        return value
    }
    private func number(_ args: [String: JSONValue], _ key: String) throws -> Double {
        guard let value = args[key]?.number, value.isFinite else { throw CADToolFailure("\(key) deve essere un numero finito.") }
        return value
    }
    private func optionalNumber(_ args: [String: JSONValue], _ key: String, _ fallback: Double) throws -> Double {
        args[key] == nil ? fallback : try number(args, key)
    }
    private func operation(_ args: [String: JSONValue]) throws -> BooleanOperation? {
        guard args["operation"] != nil else { return nil }
        guard let op = BooleanOperation(rawValue: try string(args, "operation")) else {
            throw CADToolFailure("operation deve essere newBody, join, cut o intersect.")
        }
        return op
    }

    /// Chamfer on a body's edges picked by a simple rule (the assistant cannot click edges).
    private func chamfer(_ args: [String: JSONValue], title: String) throws -> (Feature, (edges: Int, messages: [String])) {
        guard document.features.count < 256 else { throw CADToolFailure("Limite prototipo: 256 geometrie per documento.") }
        let target = document.features[try index(args)].id
        guard let body = evaluation().bodies.first(where: { $0.id == target }) else {
            throw CADToolFailure("Questa geometria non crea un corpo attivo: indica la geometria che ha creato il corpo.")
        }
        let zs = body.snapshot.positions.map(\.z)
        let (lo, hi) = (zs.min() ?? 0, zs.max() ?? 0)
        let rule = try string(args, "edges")
        let picked = body.snapshot.edges.filter { e in
            switch rule {
            case "all": return true
            case "top": return e.polyline.allSatisfy { abs($0.z - hi) < 1e-6 }
            case "bottom": return e.polyline.allSatisfy { abs($0.z - lo) < 1e-6 }
            case "vertical":
                guard let a = e.polyline.first, let b = e.polyline.last, (b - a).length > 1e-6 else { return false }
                return abs((b - a).normalized.z) > 1 - 1e-9
            default: return false
            }
        }
        guard ["all", "top", "bottom", "vertical"].contains(rule) else { throw CADToolFailure("edges: all, top, bottom o vertical.") }
        let refs = picked.compactMap(EdgeRef.init)
        guard !refs.isEmpty else { throw CADToolFailure("Nessuno spigolo corrisponde a «\(rule)» su questo corpo.") }
        var spec = ChamferSpec(edges: Array(refs.prefix(500)))
        if args["mode"] != nil {
            guard let m = ChamferSpec.Mode(rawValue: try string(args, "mode")) else { throw CADToolFailure("mode: equalDistance, twoDistances o distanceAngle.") }
            spec.mode = m
        }
        if args["profile"] != nil {
            guard let pr = ChamferSpec.Profile(rawValue: try string(args, "profile")) else { throw CADToolFailure("profile: flat o round.") }
            spec.profile = pr
        }
        spec.distance = try number(args, "distance")
        spec.distance2 = try optionalNumber(args, "distance2", spec.distance)
        spec.angle = try optionalNumber(args, "angle", 45)
        let f = Feature(name: try args["name"].map { _ in try string(args, "name") } ?? spec.title,
                        kind: .chamfer(spec), operation: .cut)
        try CADToolValidation.feature(f)
        var next = document
        next.features.append(f)
        let messages = DesignEvaluator.evaluate(next, revision: "check", components: componentResolver).issues.filter { $0.featureID == f.id }.map(\.message)
        let failed = Set(messages).count == 1 && messages.count >= refs.count || messages.contains { $0.contains("senza effetto") }
        if failed { throw CADToolFailure("Smusso non applicabile: \(messages.first ?? "nessuno spigolo modificato").") }
        return (f, (refs.count, Array(Set(messages)).sorted()))
    }

    private func patternSpec(_ args: [String: JSONValue]) throws -> PatternSpec {
        let source = document.features[try index(args, key: "body_feature_id")].id
        guard evaluation().bodies.contains(where: { $0.id == source }) else { throw CADToolFailure("body_feature_id deve indicare una geometria che crea un corpo.") }
        guard let kind = PatternSpec.Kind(rawValue: try string(args, "kind")) else { throw CADToolFailure("kind: rectangular, circular o mirror.") }
        var s = PatternSpec(body: source, kind: kind)
        s.countX = Int(try optionalNumber(args, "count_x", 1)); s.spacingX = try optionalNumber(args, "spacing_x", 0)
        s.countY = Int(try optionalNumber(args, "count_y", 1)); s.spacingY = try optionalNumber(args, "spacing_y", 0)
        s.count = Int(try optionalNumber(args, "count", 6)); s.angle = try optionalNumber(args, "angle", 360)
        if let c = args["center"], let x = c["x"]?.number, let y = c["y"]?.number { s.center = Vec3(x, y, 0) }
        if args["plane"] != nil {
            guard let p = PatternSpec.MirrorPlane(rawValue: try string(args, "plane")) else { throw CADToolFailure("plane: yz, xz o xy.") }
            s.plane = p
        }
        s.offset = try optionalNumber(args, "offset", 0)
        s.join = args["join"]?.bool ?? false
        return s
    }

    private func sheetSpec(_ args: [String: JSONValue]) throws -> SheetMetalSpec {
        let material = try string(args, "material")
        guard let m = SheetMaterial.named(material) else {
            throw CADToolFailure("material: uno di \(SheetMaterial.all.map(\.id).joined(separator: ", ")).")
        }
        let t = try number(args, "thickness")
        guard m.thicknesses.contains(where: { abs($0 - t) < 1e-9 }) else {
            throw CADToolFailure("Spessore non commerciale per \(m.name): usa \(m.thicknesses.map { String($0) }.joined(separator: ", ")) mm.")
        }
        var spec: SheetMetalSpec
        if let list = args["outline"]?.array {
            let outline = try list.map { v -> Vec2 in
                guard let x = v["x"]?.number, let y = v["y"]?.number else { throw CADToolFailure("outline: punti {x,y} in mm.") }
                return Vec2(x, y)
            }
            guard outline.count >= 3 else { throw CADToolFailure("outline: almeno 3 punti.") }
            spec = SheetMetalSpec(material: m.id, thickness: t, outline: outline)
        } else {
            spec = SheetMetalSpec(material: m.id, thickness: t, width: try number(args, "width"), depth: try number(args, "depth"))
        }
        if args["inside_radius"] != nil { spec.radiusOverride = try number(args, "inside_radius") }
        if args["corners"] != nil {
            guard let style = SheetCornerStyle(rawValue: try string(args, "corners")) else { throw CADToolFailure("corners: open o closed.") }
            spec.corners = style
        }
        if args["corner_gap"] != nil { spec.cornerGap = try number(args, "corner_gap") }
        let sideNumbers = args["outline_sides"]?.array
        if spec.outline != nil, args["flange_sides"] != nil { throw CADToolFailure("Con outline usa outline_sides (numeri dei lati), non flange_sides.") }
        if spec.outline == nil, sideNumbers != nil { throw CADToolFailure("outline_sides vale solo con outline.") }
        if let list = args["flange_sides"]?.array ?? sideNumbers {
            let direction: SheetBendDirection = args["flange_direction"] == nil ? .up
                : (SheetBendDirection(rawValue: try string(args, "flange_direction")) ?? .up)
            let reference: SheetFlangeReference = args["flange_reference"] == nil ? .outside
                : (SheetFlangeReference(rawValue: try string(args, "flange_reference")) ?? .outside)
            var flange = SheetFlange(length: try number(args, "flange_length"),
                                     angle: try optionalNumber(args, "flange_angle", 90), direction: direction, reference: reference)
            if args["lip_length"] != nil {
                let side = args["lip_side"] == nil ? "in" : try string(args, "lip_side")
                guard side == "in" || side == "out" else { throw CADToolFailure("lip_side: in o out.") }
                flange.lip = SheetLip(length: try number(args, "lip_length"), angle: try optionalNumber(args, "lip_angle", 90), inward: side == "in")
            }
            if let outline = spec.outline {
                spec.sideFlanges = try list.map { v in
                    guard let k = v.number, k == k.rounded(), (1...Double(outline.count)).contains(k) else {
                        throw CADToolFailure("outline_sides: numeri da 1 a \(outline.count).")
                    }
                    return SheetSideFlange(side: Int(k) - 1, flange: flange)
                }
            } else {
                for side in list {
                    guard let raw = side.string, let e = SheetEdge(rawValue: raw) else { throw CADToolFailure("flange_sides: front, right, back, left.") }
                    spec[e] = flange
                }
            }
        }
        return spec
    }

    private func holeSpec(_ args: [String: JSONValue]) throws -> HoleSpec {
        guard let list = args["centers"]?.array, !list.isEmpty else { throw CADToolFailure("centers: almeno un punto {x,y,z}.") }
        let centers = try list.map { v -> Vec3 in
            guard let x = v["x"]?.number, let y = v["y"]?.number, let z = v["z"]?.number else { throw CADToolFailure("centers: punti {x,y,z} in mm.") }
            return Vec3(x, y, z)
        }
        var dir = Vec3(0, 0, -1)
        if let d = args["direction"] {
            guard let x = d["x"]?.number, let y = d["y"]?.number, let z = d["z"]?.number, Vec3(x, y, z).length > 0.5 else {
                throw CADToolFailure("direction: vettore {x,y,z} non nullo.")
            }
            dir = Vec3(x, y, z).normalized
        }
        func pick<T: RawRepresentable>(_ key: String, _ fallback: T) throws -> T where T.RawValue == String {
            guard args[key] != nil else { return fallback }
            guard let v = T(rawValue: try string(args, key)) else { throw CADToolFailure("\(key): valore non valido.") }
            return v
        }
        let fit: HoleSpec.Fit = try pick("fit", .clearance)
        return HoleSpec(centers: centers, direction: dir, style: try pick("style", .simple), fit: fit,
                        size: fit == .manual ? nil : (args["size"] == nil ? "M3" : try string(args, "size")),
                        diameter: args["diameter"] == nil ? 3 : try number(args, "diameter"),
                        depth: args["depth"] == nil ? nil : try number(args, "depth"),
                        printAllowance: args["print_allowance"]?.number ?? 0)
    }

    private func color(_ args: [String: JSONValue]) throws -> PartColor {
        guard let color = PartColor(hex: try string(args, "color")) else {
            throw CADToolFailure("color deve essere un colore sRGB opaco nel formato #RRGGBB.")
        }
        return color
    }
    private func position(_ args: [String: JSONValue]) throws -> Vec3? {
        guard let value = args["position"] else { return nil }
        guard case let .object(p) = value, Set(p.keys) == ["x", "y", "z"] else { throw CADToolFailure("position deve contenere esattamente x, y, z.") }
        return try Vec3(number(p, "x"), number(p, "y"), number(p, "z"))
    }
    private func points(_ args: [String: JSONValue]) throws -> [Vec2] {
        guard let list = args["points"]?.array, (3...128).contains(list.count) else { throw CADToolFailure("points deve contenere 3–128 punti XY.") }
        let p = try list.map { v -> Vec2 in
            guard case let .object(o) = v, Set(o.keys) == ["x", "y"] else { throw CADToolFailure("Ogni punto richiede solo x, y.") }
            return try Vec2(number(o, "x"), number(o, "y"))
        }
        try CADToolValidation.profile(p)
        return p
    }

    // —— 草图 ——

    private func listSketches() throws -> ToolResult {
        let sketches = document.sketches
        return result("\(sketches.count) schizzi", ["count": .number(Double(sketches.count)), "sketches": .array(sketches.map { s -> JSONValue in
            ["id": .string(s.id.uuidString), "name": .string(s.name), "plane": planeJSON(s.plane),
             "origin": vector(s.plane.origin), "normal": vector(s.plane.normal), "visible": .bool(s.isVisible),
             "shape_count": .number(Double(s.shapes.count)), "closed_count": .number(Double(s.profiles.count)),
             "area": .number(sketchArea(s))]
        })])
    }

    private func getSketch(_ args: [String: JSONValue]) throws -> ToolResult {
        let sketch = document.sketches[try sketchIndex(args)]
        var value: [String: JSONValue] = ["id": .string(sketch.id.uuidString), "name": .string(sketch.name),
                                          "plane": planeJSON(sketch.plane), "origin": vector(sketch.plane.origin),
                                          "normal": vector(sketch.plane.normal), "visible": .bool(sketch.isVisible),
                                          "area": .number(sketchArea(sketch)),
                                          "length": .number(sketch.shapes.reduce(0) { $0 + $1.length }),
                                          "shapes": .array(sketch.shapes.map(shapeJSON))]
        value["regions"] = .array(sketch.regions.map { r -> JSONValue in
            ["shape_id": .string(r.shapeID.uuidString),
             "hole_shape_ids": .array(r.holeShapeIDs.map { .string($0.uuidString) }),
             "area": .number(regionArea(sketch, r)),
             "holes": .array(r.holeShapeIDs.map { id -> JSONValue in
                 ["shape_id": .string(id.uuidString),
                  "area": .number(sketch.shapes.first { $0.id == id }?.area ?? 0)]
             })]
        })
        return result("Schizzo: \(sketch.name)", ["sketch": .object(value)])
    }

    private func addSketch(_ args: [String: JSONValue], title: String) throws -> ToolResult {
        let list = args["shapes"]?.array ?? []
        guard (1...256).contains(list.count) else { throw CADToolFailure("shapes: 1–256 entità.") }
        // Every shape is parsed before the document is touched: a bad one changes nothing.
        let shapes = try list.map { try sketchShape($0) }
        let hasPlaneInfo = args["plane"] != nil || args["face_point"] != nil || args["face_normal"] != nil || args["offset"] != nil
        let requested = hasPlaneInfo ? try sketchPlane(args) : nil
        var next = document
        let sketch: Sketch
        if args["sketch_id"] != nil {
            guard let id = UUID(uuidString: try string(args, "sketch_id")) else { throw CADToolFailure("sketch_id: UUID non valido.") }
            guard let i = next.sketches.firstIndex(where: { $0.id == id }) else { throw CADToolFailure("Schizzo non trovato: rileggere list_sketches.") }
            var edited = next.sketches[i]
            if let requested, requested != edited.plane {
                throw CADToolFailure("Lo schizzo esiste già su un altro piano; creane uno nuovo.")
            }
            if args["replace"]?.bool == true {
                edited.shapes = []
                edited.solve()
            }
            edited.shapes.append(contentsOf: shapes)
            if let visible = args["visible"]?.bool { edited.isVisible = visible }
            next.upsert(edited)
            next.regenerate(from: edited)
            sketch = edited
        } else {
            let made = Sketch(name: try args["name"].map { _ in try string(args, "name") } ?? nextSketchName(),
                              plane: requested ?? .xy, shapes: shapes, isVisible: args["visible"]?.bool ?? true)
            next.upsert(made)
            sketch = made
        }
        commitEdit(next, selected: .some(sketch.id), title: "Assistente: \(title)", changed: [])
        return result("\(sketch.name): \(sketch.shapes.count) entità", [
            "changed": true, "sketch_id": .string(sketch.id.uuidString), "name": .string(sketch.name),
            "shape_ids": .array(shapes.map { .string($0.id.uuidString) }),
            "shape_count": .number(Double(sketch.shapes.count))
        ])
    }

    private func extrudeSketch(_ args: [String: JSONValue], title: String) throws -> ToolResult {
        let sketch = document.sketches[try sketchIndex(args)]
        let regions = sketch.regions
        let shape: SketchShape
        if args["shape_id"] != nil {
            guard let id = UUID(uuidString: try string(args, "shape_id")) else { throw CADToolFailure("shape_id: UUID non valido.") }
            guard let s = sketch.shapes.first(where: { $0.id == id }) else {
                throw CADToolFailure("Entità non trovata in questo schizzo: usare gli ID di get_sketch.")
            }
            guard s.profile != nil else { throw CADToolFailure("L'entità non è un profilo chiuso (o è di costruzione): sceglierne una dagli ID di get_sketch.") }
            shape = s
        } else {
            let candidates = regions.filter { !$0.outline.isEmpty }
            guard candidates.count == 1, let region = candidates.first,
                  let s = sketch.shapes.first(where: { $0.id == region.shapeID }) else {
                if candidates.isEmpty { throw CADToolFailure("Nessun profilo chiuso nello schizzo.") }
                throw CADToolFailure("Lo schizzo ha più profili chiusi: indica shape_id (\(candidates.map { $0.shapeID.uuidString }.joined(separator: ", ")).")
            }
            shape = s
        }
        guard let profile = shape.profile else { throw CADToolFailure("L'entità non è un profilo chiuso.") }
        let region = regions.first { $0.shapeID == shape.id }
        let holes = region?.holes.map { Profile2D(points: $0) } ?? []
        let height = try number(args, "height")
        try CADToolValidation.dimension(height)
        let reversed = args["reversed"]?.bool ?? false
        var next = document
        guard next.features.count < 256 else { throw CADToolFailure("Limite prototipo: 256 geometrie per documento.") }
        // A plane exactly on the print bed starts at Z=0 without a placement; anything else
        // (on a face, offset, XZ/YZ, reversed) is built on the sketch plane.
        let placement: FeaturePlacement? = (sketch.plane.isXY && !reversed)
            ? nil : FeaturePlacement(plane: sketch.plane, reversed: reversed)
        var feature = Feature(name: try args["name"].map { _ in try string(args, "name") } ?? nextExtrudeName(),
                              kind: .extrude(profile: profile, height: height),
                              color: try args["color"].map { _ in try color(args) } ?? .defaultColor,
                              operation: try operation(args) ?? .newBody,
                              placement: placement, holes: holes)
        feature.keyProfile(from: sketch)
        try CADToolValidation.feature(feature)
        try CADToolValidation.mesh(feature.buildMesh())
        next.features.append(feature)
        next.sketchLinks.append(SketchLink(featureID: feature.id, sketchID: sketch.id, shapeID: shape.id,
                                           holeShapeIDs: region?.holeShapeIDs ?? []))
        commitEdit(next, selected: .some(feature.id), title: "Assistente: \(title)", changed: [feature.id])
        return result("\(feature.name): estrusione da \(sketch.name)", [
            "changed": true, "feature_id": .string(feature.id.uuidString), "name": .string(feature.name),
            "height": .number(height), "hole_count": .number(Double(holes.count))
        ], changed: [feature.id])
    }

    private func sketchIndex(_ args: [String: JSONValue]) throws -> Int {
        guard let id = UUID(uuidString: try string(args, "sketch_id")),
              let i = document.sketches.firstIndex(where: { $0.id == id }) else {
            throw CADToolFailure("Schizzo non trovato: rileggere list_sketches.")
        }
        return i
    }

    private func vec2JSON(_ p: Vec2) -> JSONValue { ["x": .number(p.x), "y": .number(p.y)] }

    private func shapeJSON(_ s: SketchShape) -> JSONValue {
        var value: [String: JSONValue] = ["id": .string(s.id.uuidString), "kind": .string(shapeKindName(s.kind)),
                                          "construction": .bool(s.isConstruction), "closed": .bool(s.isClosed),
                                          "area": .number(s.area)]
        switch s.kind {
        case let .polyline(p, closed):
            value["points"] = .array(p.map(vec2JSON)); value["closed"] = .bool(closed)
        case let .rectangle(c, w, h):
            value["corner"] = vec2JSON(c); value["width"] = .number(w); value["height"] = .number(h)
        case let .circle(c, r):
            value["center"] = vec2JSON(c); value["radius"] = .number(r)
        case let .polygon(c, r, n, rot, circ):
            value["center"] = vec2JSON(c); value["radius"] = .number(r); value["sides"] = .number(Double(n))
            value["rotation"] = .number(rot * 180 / .pi); value["circumscribed"] = .bool(circ)
        case let .slot(a, b, w):
            value["start"] = vec2JSON(a); value["end"] = vec2JSON(b); value["width"] = .number(w)
        case let .arc(c, r, a0, a1):
            value["center"] = vec2JSON(c); value["radius"] = .number(r)
            value["start_angle"] = .number(a0 * 180 / .pi); value["end_angle"] = .number(a1 * 180 / .pi)
        case let .spline(p, closed):
            value["points"] = .array(p.map(vec2JSON)); value["closed"] = .bool(closed)
        case let .bezier(s, c1, c2, e):
            value["start"] = vec2JSON(s); value["control1"] = vec2JSON(c1)
            value["control2"] = vec2JSON(c2); value["end"] = vec2JSON(e)
        case let .point3D(p):
            value["position"] = vector(p)
        case let .line3D(a, b):
            value["start"] = vector(a); value["end"] = vector(b)
        case let .workplane(o, x, p):
            value["origin"] = vector(o); value["x_axis_point"] = vector(x); value["plane_point"] = vector(p)
        }
        return .object(value)
    }

    private func shapeKindName(_ kind: SketchShape.Kind) -> String {
        switch kind {
        case let .polyline(p, closed): closed ? "polyline" : (p.count == 2 ? "line" : "polyline")
        case .rectangle: "rectangle"
        case .circle: "circle"
        case .polygon: "polygon"
        case .slot: "slot"
        case .arc: "arc"
        case .spline: "spline"
        case .bezier: "bezier"
        case .point3D: "point3D"
        case .line3D: "line3D"
        case .workplane: "workplane"
        }
    }

    private func sketchShape(_ json: JSONValue) throws -> SketchShape {
        func point(_ key: String) throws -> Vec2 {
            guard let x = json[key]?["x"]?.number, let y = json[key]?["y"]?.number else {
                throw CADToolFailure("\(key): punto {x,y} in mm.")
            }
            try CADToolValidation.coordinate(x); try CADToolValidation.coordinate(y)
            return Vec2(x, y)
        }
        func raw(_ key: String) throws -> Double {
            guard let v = json[key]?.number, v.isFinite else { throw CADToolFailure("\(key) deve essere un numero finito.") }
            return v
        }
        func size(_ key: String) throws -> Double {
            let v = try raw(key)
            try CADToolValidation.dimension(v)
            return v
        }
        func degrees(_ key: String) throws -> Double {
            let v = try raw(key)
            guard (-360...360).contains(v) else { throw CADToolFailure("\(key): angolo in gradi tra -360 e 360.") }
            return v * .pi / 180
        }
        func points(_ key: String) throws -> [Vec2] {
            guard let list = json[key]?.array else { throw CADToolFailure("\(key): punti {x,y} in mm.") }
            guard (2...256).contains(list.count) else { throw CADToolFailure("\(key): 2–256 punti {x,y}.") }
            var out: [Vec2] = []
            for v in list {
                guard let x = v["x"]?.number, let y = v["y"]?.number else { throw CADToolFailure("\(key): ogni punto richiede x e y.") }
                try CADToolValidation.coordinate(x); try CADToolValidation.coordinate(y)
                out.append(Vec2(x, y))
            }
            return out
        }
        guard let kind = json["kind"]?.string else { throw CADToolFailure("Ogni entità richiede kind.") }
        let shapeKind: SketchShape.Kind
        switch kind {
        case "line":
            let p = try points("points")
            guard p.count == 2 else { throw CADToolFailure("line: esattamente 2 punti.") }
            shapeKind = .polyline(p, closed: false)
        case "polyline":
            shapeKind = .polyline(try points("points"), closed: json["closed"]?.bool ?? false)
        case "spline":
            shapeKind = .spline(points: try points("points"), closed: json["closed"]?.bool ?? false)
        case "rectangle":
            var corner = try point("corner")
            var w = try raw("width"), h = try raw("height")
            if w < 0 { corner.x += w; w = -w }
            if h < 0 { corner.y += h; h = -h }
            try CADToolValidation.dimension(w); try CADToolValidation.dimension(h)
            shapeKind = .rectangle(corner: corner, width: w, height: h)
        case "circle":
            shapeKind = .circle(center: try point("center"), radius: try size("radius"))
        case "polygon":
            let rawSides = try raw("sides")
            guard rawSides == rawSides.rounded(), (3...64).contains(rawSides) else {
                throw CADToolFailure("polygon: sides tra 3 e 64.")
            }
            shapeKind = .polygon(center: try point("center"), radius: try size("radius"), sides: Int(rawSides),
                                 rotation: json["rotation"] == nil ? 0 : try degrees("rotation"),
                                 circumscribed: json["circumscribed"]?.bool ?? false)
        case "slot":
            shapeKind = .slot(start: try point("start"), end: try point("end"), width: try size("width"))
        case "arc":
            shapeKind = .arc(center: try point("center"), radius: try size("radius"),
                             start: try degrees("start_angle"), end: try degrees("end_angle"))
        case "bezier":
            shapeKind = .bezier(start: try point("start"), control1: try point("control1"),
                                control2: try point("control2"), end: try point("end"))
        default:
            throw CADToolFailure("kind: line, polyline, spline, rectangle, circle, polygon, slot, arc o bezier.")
        }
        return SketchShape(kind: shapeKind, isConstruction: json["construction"]?.bool ?? false)
    }

    private func sketchPlane(_ args: [String: JSONValue]) throws -> SketchPlane {
        if args["face_point"] != nil || args["face_normal"] != nil {
            guard let fp = args["face_point"], let fn = args["face_normal"] else {
                throw CADToolFailure("face_point e face_normal vanno insieme.")
            }
            guard let px = fp["x"]?.number, let py = fp["y"]?.number, let pz = fp["z"]?.number,
                  let nx = fn["x"]?.number, let ny = fn["y"]?.number, let nz = fn["z"]?.number,
                  Vec3(nx, ny, nz).length > 0.5 else {
                throw CADToolFailure("face_point e face_normal: vettori {x,y,z}, normale non nulla.")
            }
            for v in [px, py, pz] { try CADToolValidation.coordinate(v) }
            return SketchPlane.onFace(point: Vec3(px, py, pz), normal: Vec3(nx, ny, nz))
        }
        let plane: SketchPlane
        switch args["plane"]?.string ?? "xy" {
        case "xy": plane = .xy
        case "xz": plane = .xz
        case "yz": plane = .yz
        default: throw CADToolFailure("plane: xy, xz o yz.")
        }
        guard let offset = args["offset"]?.number else { return plane }
        guard offset.isFinite, abs(offset) <= 100000 else { throw CADToolFailure("offset: numero finito entro ±100000 mm.") }
        return offset == 0 ? plane : plane.offset(by: offset)
    }

    private func planeJSON(_ p: SketchPlane) -> JSONValue {
        if p == .xy { return "XY" }
        if p == .xz { return "XZ" }
        if p == .yz { return "YZ" }
        return "custom"
    }

    /// Area covered by the sketch's closed regions, holes subtracted.
    private func sketchArea(_ sketch: Sketch) -> Double {
        sketch.regions.reduce(0) { $0 + regionArea(sketch, $1) }
    }

    private func regionArea(_ sketch: Sketch, _ region: SketchRegion) -> Double {
        let outer = sketch.shapes.first { $0.id == region.shapeID }?.area ?? abs(Profile2D(points: region.outline).area)
        let holes = region.holeShapeIDs.compactMap { id in sketch.shapes.first { $0.id == id }?.area }.reduce(0, +)
        return max(0, outer - holes)
    }

    private func nextSketchName() -> String {
        let n = (document.sketches.compactMap { Int($0.name.replacingOccurrences(of: "Schizzo ", with: "")) }.max() ?? 0) + 1
        return "Schizzo \(n)"
    }

    private func nextExtrudeName() -> String {
        let n = (document.features.compactMap { Int($0.name.replacingOccurrences(of: "Estrusione ", with: "")) }.max() ?? 0) + 1
        return "Estrusione \(n)"
    }
}

extension Feature.Kind {
    /// Features that change or copy bodies made earlier (no mesh of their own to validate).
    var actsOnBodies: Bool {
        switch self {
        case .pattern, .split, .component, .shell, .move, .joint, .combine, .thread: true
        default: false
        }
    }
}
