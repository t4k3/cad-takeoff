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
            default: throw CADToolFailure("Comando non supportato.")
            }
            let f = Feature(name: try args["name"].map { _ in try string(args, "name") } ?? "\(title) \(next.features.count + 1)",
                            kind: kind, position: try position(args) ?? .zero,
                            color: try args["color"].map { _ in try color(args) } ?? .defaultColor,
                            operation: name == "add_hole" ? .cut : (try operation(args) ?? .newBody))
            try CADToolValidation.feature(f)
            try CADToolValidation.mesh(f.buildMesh())
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
                case .hole, .chamfer:
                    legal = []   // re-create with add_hole/add_chamfer or edit in the app
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
        return result(statusMessage, ["changed": true, "feature_id": .string(changed.uuidString)], changed: [changed])
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
        let report = mesh.isEmpty ? nil : MeshValidator.validate(mesh)
        return result("Scena in millimetri, Z verso l'alto", [
            "units": "mm", "up_axis": "Z", "feature_count": .number(Double(document.features.count)),
            "visible_count": .number(Double(visible.count)), "triangles": .number(Double(mesh.triangleCount)),
            "mesh_volume_mm3": .number(mesh.volume), "bounds": bounds(mesh.bounds),
            "edge_closed": report.map { .bool($0.isWatertight) } ?? .null,
            "body_count": .number(Double(bodies.count)),
            "issues": .array(issues.map { ["feature_id": .string($0.featureID.uuidString), "message": .string($0.message)] }),
            "warning": "Corpi separati non si fondono tra loro: usa operation join per unirli. La chiusura dei bordi non certifica la stampabilità.",
            "capabilities": ["box", "cylinder", "simple_polygon_extrude", "boolean_join_cut_intersect", "hole", "chamfer",
                             "parameter_update", "timeline_rollback_suppress", "session_undo", "stl", "part_color", "3mf"],
            "unavailable": ["fillet", "modeled_thread", "concave_chamfer", "sheet_metal_ui", "assemblies", "step", "dxf"]
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
        }
        return .object(value)
    }
    private func vector(_ p: Vec3) -> JSONValue { ["x": .number(p.x), "y": .number(p.y), "z": .number(p.z)] }
    private func bounds(_ b: BoundingBox?) -> JSONValue {
        guard let b else { return .null }
        return ["min": vector(b.min), "max": vector(b.max), "size": vector(b.size)]
    }
    private func index(_ args: [String: JSONValue]) throws -> Int {
        guard let id = UUID(uuidString: try string(args, "feature_id")), let i = document.features.firstIndex(where: { $0.id == id }) else {
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
        let messages = DesignEvaluator.evaluate(next, revision: "check").issues.filter { $0.featureID == f.id }.map(\.message)
        let failed = Set(messages).count == 1 && messages.count >= refs.count || messages.contains { $0.contains("senza effetto") }
        if failed { throw CADToolFailure("Smusso non applicabile: \(messages.first ?? "nessuno spigolo modificato").") }
        return (f, (refs.count, Array(Set(messages)).sorted()))
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
