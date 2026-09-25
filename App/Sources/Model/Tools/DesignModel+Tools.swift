import Foundation
import CADCore

struct AssistantHistory {
    struct Entry {
        let before: CADDocument
        let after: CADDocument
        let selectionBefore: UUID?
        let selectionAfter: UUID?
        let title: String
        let changed: [UUID]
    }
    var undo: [Entry] = []
    var redo: [Entry] = []
}

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
        if name.hasPrefix("add_") {
            guard next.features.count < 256 else { throw CADToolFailure("Limite prototipo: 256 geometrie per documento.") }
            let kind: Feature.Kind
            switch name {
            case "add_box": kind = .box(width: try number(args, "width"), depth: try number(args, "depth"), height: try number(args, "height"))
            case "add_cylinder": kind = .cylinder(radius: try number(args, "radius"), height: try number(args, "height"))
            case "add_extrude": kind = .extrude(profile: Profile2D(points: try points(args)), height: try number(args, "height"))
            default: throw CADToolFailure("Comando non supportato.")
            }
            let f = Feature(name: try args["name"].map { _ in try string(args, "name") } ?? "\(title) \(next.features.count + 1)",
                            kind: kind, position: try position(args) ?? .zero)
            try CADToolValidation.feature(f)
            try CADToolValidation.mesh(f.buildMesh())
            next.features.append(f); changed = f.id; selected = f.id
        } else {
            let i = try index(args)
            changed = next.features[i].id
            switch name {
            case "delete_feature": next.features.remove(at: i); if selected == changed { selected = nil }
            case "set_visibility":
                guard let visible = args["visible"]?.bool else { throw CADToolFailure("visible deve essere booleano.") }
                next.features[i].isVisible = visible
            case "update_feature":
                var f = next.features[i]
                if args["name"] != nil { f.name = try string(args, "name") }
                if let p = try position(args) { f.position = p }
                let legal: Set<String>
                switch f.kind {
                case let .box(w, d, h):
                    legal = ["width", "depth", "height"]
                    f.kind = .box(width: try optionalNumber(args, "width", w), depth: try optionalNumber(args, "depth", d), height: try optionalNumber(args, "height", h))
                case let .cylinder(r, h):
                    legal = ["radius", "height"]
                    f.kind = .cylinder(radius: try optionalNumber(args, "radius", r), height: try optionalNumber(args, "height", h))
                case let .extrude(p, h):
                    legal = ["points", "height"]
                    f.kind = .extrude(profile: args["points"] == nil ? p : Profile2D(points: try points(args)), height: try optionalNumber(args, "height", h))
                }
                let supplied = Set(args.keys).subtracting(["name", "position", "feature_id", "expected_revision"])
                guard supplied.isSubset(of: legal) else { throw CADToolFailure("Parametro non applicabile al tipo di geometria selezionato.") }
                try CADToolValidation.feature(f)
                try CADToolValidation.mesh(f.buildMesh())
                next.features[i] = f; selected = f.id
            default: throw CADToolFailure("Comando non supportato.")
            }
        }
        guard next != document else { return result("Nessuna modifica necessaria", ["changed": false]) }
        let entry = AssistantHistory.Entry(before: document, after: next, selectionBefore: selection,
                                           selectionAfter: selected, title: "Assistente: \(title)", changed: [changed])
        applyingAssistantChange = true
        document = next; selection = selected
        applyingAssistantChange = false
        assistantHistory.undo.append(entry)
        if assistantHistory.undo.count > 50 { assistantHistory.undo.removeFirst() }
        assistantHistory.redo.removeAll()
        statusMessage = entry.title
        return result(entry.title, ["changed": true, "feature_id": .string(changed.uuidString)], changed: [changed])
    }

    private func restore(redo: Bool) throws -> ToolResult {
        guard let entry = redo ? assistantHistory.redo.last : assistantHistory.undo.last else {
            throw CADToolFailure(redo ? "Nessuna operazione da ripetere." : "Nessuna operazione assistente da annullare; una modifica manuale azzera questa cronologia.")
        }
        guard document == (redo ? entry.before : entry.after) else { throw CADToolFailure("Documento cambiato: annullamento non applicabile.") }
        applyingAssistantChange = true
        document = redo ? entry.after : entry.before
        selection = redo ? entry.selectionAfter : entry.selectionBefore
        applyingAssistantChange = false
        if redo { assistantHistory.redo.removeLast(); assistantHistory.undo.append(entry) }
        else { assistantHistory.undo.removeLast(); assistantHistory.redo.append(entry) }
        statusMessage = (redo ? "Ripetuto: " : "Annullato: ") + entry.title
        return result(statusMessage, ["changed": true], changed: entry.changed)
    }

    private func sceneInfo() throws -> ToolResult {
        let visible = document.features.filter(\.isVisible)
        var meshes: [Mesh] = []
        for f in visible { try CADToolValidation.feature(f); let m = f.buildMesh(); try CADToolValidation.mesh(m); meshes.append(m) }
        let mesh = Mesh.merged(meshes)
        let report = mesh.isEmpty ? nil : MeshValidator.validate(mesh)
        return result("Scena in millimetri, Z verso l'alto", [
            "units": "mm", "up_axis": "Z", "feature_count": .number(Double(document.features.count)),
            "visible_count": .number(Double(visible.count)), "triangles": .number(Double(mesh.triangleCount)),
            "mesh_volume_mm3": .number(mesh.volume), "bounds": bounds(mesh.bounds),
            "edge_closed": report.map { .bool($0.isWatertight) } ?? .null,
            "warning": "Solidi indipendenti: volume sommato, nessuna unione booleana; chiusura dei bordi non certifica stampabilità.",
            "capabilities": ["box", "cylinder", "simple_polygon_extrude", "parameter_update", "session_undo", "stl"],
            "unavailable": ["boolean", "persistent_parametric_history", "sheet_metal", "assemblies", "step", "dxf"]
        ])
    }

    private func export(_ args: [String: JSONValue]) throws -> ToolResult {
        let features = args["feature_id"] == nil ? document.features.filter(\.isVisible) : [document.features[try index(args)]]
        guard !features.isEmpty else { throw CADToolFailure("Niente da esportare.") }
        var meshes: [Mesh] = []
        for f in features { try CADToolValidation.feature(f); let m = f.buildMesh(); try CADToolValidation.mesh(m); meshes.append(m) }
        let mesh = Mesh.merged(meshes)
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
        data["can_undo"] = .bool(!assistantHistory.undo.isEmpty)
        data["can_redo"] = .bool(!assistantHistory.redo.isEmpty)
        data["undo_title"] = assistantHistory.undo.last.map { .string($0.title) } ?? .null
        return ToolResult(text: text, structured: .object(data), isError: error, changedFeatures: changed)
    }

    private func describe(_ f: Feature) -> JSONValue {
        var value: [String: JSONValue] = ["id": .string(f.id.uuidString), "name": .string(f.name), "position": vector(f.position), "visible": .bool(f.isVisible)]
        switch f.kind {
        case let .box(w, d, h): value.merge(["kind": "box", "width": .number(w), "depth": .number(d), "height": .number(h)]) { _, b in b }
        case let .cylinder(r, h): value.merge(["kind": "cylinder", "radius": .number(r), "height": .number(h)]) { _, b in b }
        case let .extrude(p, h): value.merge(["kind": "extrude", "points": .array(p.points.map { ["x": .number($0.x), "y": .number($0.y)] }), "height": .number(h)]) { _, b in b }
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
