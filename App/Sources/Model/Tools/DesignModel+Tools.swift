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
                    "holes": .number(Double(part?.flat.holes.count ?? 0)), "skipped_holes": .number(Double(part?.skippedHoles ?? 0))
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
                case .hole, .chamfer, .sheetMetal, .component, .importedMesh, .pattern, .split:
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
        let all = evaluation().bodies
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
                                                section: args["section"]?.bool ?? false) }
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
        let data = try export3MFData(featureID: id)
        guard data.count <= 8 * 1024 * 1024 else { throw CADToolFailure("Export troppo grande per la chat (8 MiB). Usare il pannello esportazione.") }
        return result("3MF pronto: parti separate con colori sRGB", [
            "filename": "Design.3mf", "mime_type": "model/3mf", "encoding": "base64", "data": .string(data.base64EncodedString()),
            "bytes": .number(Double(data.count)), "coordinate_units": "mm",
            "warning": "Colori per parte, senza profili stampante o G-code. Verificare l'assegnazione ai filamenti in Bambu Studio/OrcaSlicer. Nessuna unione booleana."
        ])
    }

    private func describe(_ f: Feature) -> JSONValue {
        var value: [String: JSONValue] = ["id": .string(f.id.uuidString), "name": .string(f.name), "position": vector(f.position), "visible": .bool(f.isVisible), "color": .string(f.color.hex), "operation": .string(f.operation.rawValue)]
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
            var flanges: [String: JSONValue] = [:]
            for e in SheetEdge.allCases {
                if let f = s[e] {
                    var flange: [String: JSONValue] = ["length": .number(f.length), "angle": .number(f.angle),
                                                       "direction": .string(f.direction.rawValue), "reference": .string(f.reference.rawValue)]
                    if let lip = f.lip {
                        flange["lip"] = ["length": .number(lip.length), "angle": .number(lip.angle), "side": .string(lip.inward ? "in" : "out")]
                    }
                    flanges[e.rawValue] = .object(flange)
                }
            }
            value["flanges"] = .object(flanges)
            if let build = try? SheetMetalGeometry.build(s, featureID: f.id, position: f.position) {
                value["flat_size"] = ["x": .number(build.flat.size.width), "y": .number(build.flat.size.height)]
                value["warnings"] = .array(build.warnings.map { .string($0) })
            }
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
        var spec = SheetMetalSpec(material: m.id, thickness: t, width: try number(args, "width"), depth: try number(args, "depth"))
        if args["inside_radius"] != nil { spec.radiusOverride = try number(args, "inside_radius") }
        if args["corners"] != nil {
            guard let style = SheetCornerStyle(rawValue: try string(args, "corners")) else { throw CADToolFailure("corners: open o closed.") }
            spec.corners = style
        }
        if args["corner_gap"] != nil { spec.cornerGap = try number(args, "corner_gap") }
        if let list = args["flange_sides"]?.array {
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
            for side in list {
                guard let raw = side.string, let e = SheetEdge(rawValue: raw) else { throw CADToolFailure("flange_sides: front, right, back, left.") }
                spec[e] = flange
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
        guard fit != .modeledThread else { throw CADToolFailure("Filetto modellato non ancora disponibile: usa tapped o heatInsert.") }
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
}

extension Feature.Kind {
    /// Features that change or copy bodies made earlier (no mesh of their own to validate).
    var actsOnBodies: Bool {
        switch self {
        case .pattern, .split, .component, .shell, .move, .joint: true
        default: false
        }
    }
}
