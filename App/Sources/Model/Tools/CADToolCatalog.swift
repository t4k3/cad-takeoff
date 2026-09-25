import Foundation

/// The same catalogue is consumed by both MCP and in-app providers.
enum CADToolCatalog {
    static let tools: [ToolSpec] = {
        let number: JSONValue = ["type": "number", "minimum": 0.01, "maximum": 100000,
                                 "description": "Dimension in millimetres, finite and positive."]
        let coordinate: JSONValue = ["type": "number", "minimum": -100000, "maximum": 100000]
        let point: JSONValue = object(["x": coordinate, "y": coordinate], required: ["x", "y"])
        let position = object(["x": coordinate, "y": coordinate, "z": coordinate], required: ["x", "y", "z"])
        let points: JSONValue = ["type": "array", "items": point, "minItems": 3, "maxItems": 128,
                                "description": "Ordered vertices of one simple XY polygon, no holes. Implicit closure: do not repeat the first vertex. CW or CCW accepted."]
        let id: JSONValue = ["type": "string", "format": "uuid", "description": "Exact feature ID returned by list_features; never guess."]
        let revision: JSONValue = ["type": "string", "description": "Exact revision from the latest result or scene_info. Stale edits are rejected; reread before retrying."]
        let name: JSONValue = ["type": "string", "minLength": 1, "maxLength": 160]
        let color: JSONValue = ["type": "string", "pattern": "^#[0-9a-fA-F]{6}$", "description": "Opaque sRGB part colour #RRGGBB, e.g. #E53935. Preserved in 3MF; not an AMS slot or filament recipe."]
        func tool(_ key: String, _ title: String, _ description: String, _ properties: [String: JSONValue] = [:],
                  required: [String] = [], write: Bool = false) -> ToolSpec {
            var p = properties
            if write { p["expected_revision"] = revision }
            return ToolSpec(name: key, title: title,
                description: description + " Units: mm, right-handed Z-up. " + (write ? "One undo step per successful change. Call scene_info first; sequence writes, using each returned revision." : "Read-only; returns current revision."),
                inputSchema: object(p, required: required + (write ? ["expected_revision"] : [])), isReadOnly: !write)
        }
        let common: [String: JSONValue] = ["name": name, "position": position, "color": color]
        func fields(_ extra: [String: JSONValue]) -> [String: JSONValue] { common.merging(extra) { _, b in b } }
        return [
            tool("scene_info", "Informazioni scena", "Use before modelling to inspect bounds, feature count, mesh volume and available undo. The scene is a collection of independent solids, NOT a boolean union; overlaps may double-count volume."),
            tool("list_features", "Elenco geometrie", "List all features, including hidden ones, their IDs, kinds, dimensions, positions, visibility and sRGB colours."),
            tool("get_feature", "Leggi geometria", "Read parameters of an existing feature before changing it.", ["feature_id": id], required: ["feature_id"]),
            tool("add_box", "Crea parallelepipedo", "Create a separate box centred on position.x/y, bottom at position.z (default origin). Example dimensions width=40 depth=30 height=5. Does not cut, merge, or create sheet metal.", fields(["width": number, "depth": number, "height": number]), required: ["width", "depth", "height"], write: true),
            tool("add_cylinder", "Crea cilindro", "Create a separate 64-segment cylinder, axis +Z, centre at position.x/y and bottom at position.z. Radius, not diameter. No holes or boolean subtraction.", fields(["radius": number, "height": number]), required: ["radius", "height"], write: true),
            tool("add_extrude", "Estrudi profilo", "Extrude one simple XY polygon toward +Z. Position translates the resulting solid; default origin. Concave profiles supported, holes and self-intersections unsupported.", fields(["points": points, "height": number]), required: ["points", "height"], write: true),
            tool("update_feature", "Modifica geometria", "Update only supplied fields of an existing feature, retaining its ID and kind. width/depth only box, radius only cylinder, points only extrude, height all. No change of kind.", fields(["feature_id": id, "width": number, "depth": number, "height": number, "radius": number, "points": points]), required: ["feature_id"], write: true),
            tool("delete_feature", "Elimina geometria", "Delete exactly one identified feature. Undo can restore it.", ["feature_id": id], required: ["feature_id"], write: true),
            tool("set_visibility", "Visibilità geometria", "Show/hide one feature. Hidden features are omitted from scene mesh and whole-scene export.", ["feature_id": id, "visible": ["type": "boolean"]], required: ["feature_id", "visible"], write: true),
            tool("set_color", "Colore parte", "Set a whole part's opaque sRGB colour without changing geometry. Persisted in the design and 3MF. Filament assignment must be checked in the slicer.", ["feature_id": id, "color": color], required: ["feature_id", "color"], write: true),
            tool("export_stl", "Esporta STL", "Return binary STL as base64, never write arbitrary files. Optional feature_id exports that feature even if hidden; otherwise visible scene. Independent solids are concatenated, not boolean-unioned; closure does not certify manufacturability. Coordinates in mm; STL has no unit metadata.", ["feature_id": id]),
            tool("export_3mf", "Esporta 3MF a colori", "Return 3MF as base64 with named separate parts, relative placement, mm and sRGB part colours. Optional feature_id includes that feature even if hidden; otherwise visible parts. No printer profile, AMS mapping, G-code or boolean union. Check filament assignment in Bambu Studio/OrcaSlicer.", ["feature_id": id]),
            tool("undo", "Annulla assistente", "Undo the latest assistant mutation if there have been no intervening manual edits. This is session undo, not persistent parametric history.", write: true),
            tool("redo", "Ripeti assistente", "Redo the latest undone assistant mutation. A new edit clears redo.", write: true)
        ]
    }()

    private static func object(_ properties: [String: JSONValue], required: [String]) -> JSONValue {
        ["type": "object", "properties": .object(properties), "required": .array(required.map(JSONValue.string)), "additionalProperties": false]
    }
}
