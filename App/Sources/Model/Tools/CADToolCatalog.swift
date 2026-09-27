import CADCore
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
        let operation: JSONValue = ["type": "string", "enum": ["newBody", "join", "cut", "intersect"],
                                    "description": "newBody (default): separate body. join: merge with the bodies it touches. cut: remove its volume from the bodies it touches (holes, pockets, slots: e.g. a cylinder with operation cut through a plate). intersect: keep only the overlap."]
        let common: [String: JSONValue] = ["name": name, "position": position, "color": color, "operation": operation]
        func fields(_ extra: [String: JSONValue]) -> [String: JSONValue] { common.merging(extra) { _, b in b } }
        return [
            tool("scene_info", "Informazioni scena", "Use before modelling to inspect bounds, feature count, mesh volume and available undo. The scene is a collection of independent solids, NOT a boolean union; overlaps may double-count volume."),
            tool("list_features", "Elenco geometrie", "List all features, including hidden ones, their IDs, kinds, dimensions, positions, visibility and sRGB colours."),
            tool("get_feature", "Leggi geometria", "Read parameters of an existing feature before changing it.", ["feature_id": id], required: ["feature_id"]),
            tool("add_box", "Crea parallelepipedo", "Create a box centred on position.x/y, bottom at position.z (default origin). Example width=40 depth=30 height=5. Use operation to join/cut/intersect with touching bodies.", fields(["width": number, "depth": number, "height": number]), required: ["width", "depth", "height"], write: true),
            tool("add_cylinder", "Crea cilindro", "Create a 64-segment cylinder, axis +Z, centre at position.x/y and bottom at position.z. Radius, not diameter. For a through hole use operation cut with a height exceeding the plate and a start below it.", fields(["radius": number, "height": number]), required: ["radius", "height"], write: true),
            tool("add_extrude", "Estrudi profilo", "Extrude one simple polygon. Default: XY plane toward +Z. To sketch on a face give face_point (any point on the planar face) and face_normal (its outward normal): the points are then in the face's own 2D coordinates (on a horizontal face they equal world X/Y; on a vertical face X runs horizontally and Y is height above world Z 0), and into_part true extrudes into the part (use with operation cut for pockets and slots), false outward (bosses, with join). Position translates the result. Concave profiles supported; no holes in the profile (cut them with operation cut).",
                 fields(["points": points, "height": number, "face_point": position, "face_normal": position, "into_part": ["type": "boolean"]]),
                 required: ["points", "height"], write: true),
            tool("add_hole", "Crea foro", "Drill holes (always removes material) on a planar face. centers: points ON the start face (world mm), direction: into the material (default {0,0,-1}, i.e. drilling down from a top face). style: simple | counterbore | countersink. fit: clearance (screw passes, default) | tapped (tap-drill for threading/self-tapping) | heatInsert (hole for heat-set threaded inserts) | manual (use diameter). size: M2, M2.5, M3, M4, M5, M6, M8, M10, M12. depth in mm, omit for through-all. print_allowance: mm added to diameters (FDM holes print small; 0.1–0.3 typical). Example: 4 M3 counterbored holes at the corners of a 40×30×5 plate at z=5.",
                 ["centers": ["type": "array", "minItems": 1, "maxItems": 200, "items": position],
                  "direction": position,
                  "style": ["type": "string", "enum": ["simple", "counterbore", "countersink"]],
                  "fit": ["type": "string", "enum": ["clearance", "tapped", "heatInsert", "manual"]],
                  "size": ["type": "string", "enum": .array(MetricScrew.all.map { .string($0.name) })],
                  "diameter": number, "depth": number,
                  "print_allowance": ["type": "number", "minimum": 0, "maximum": 2],
                  "name": name, "color": color],
                 required: ["centers"], write: true),
            tool("add_sheet_metal", "Crea lamiera piegata", "Create a bent sheet-metal part: rectangular base plate with flanges on some sides, bent with the material's press-brake rule (air bending with standard V die, inside radius from the die, K-factor per DIN 6935). width/depth: OUTSIDE footprint in X/Y. material: dc01 (cold-rolled steel), dx51d (galvanised), s235 (hot-rolled, 2–10 mm), aisi304, aisi316 (stainless), al5754 (bendable aluminium), al6082 (T6, needs r ≥ 3t), cuzn37 (brass), cu (copper). thickness must be a commercial one for the material (e.g. dc01: 0.5, 0.6, 0.8, 1, 1.2, 1.5, 2, 2.5, 3). flange_sides: any of front (−Y), right (+X), back (+Y), left (−X); flange_length measured per flange_reference (outside = overall height, default). corners: open (default: a notch at each corner) or closed (box: front/back walls cover the corners, left/right walls butt against them with corner_gap mm clearance, default 0.2; square relief in the flat pattern; only between 90° flanges bent the same way). Omit inside_radius to use the workshop table. The result lists warnings (flange shorter than the press-brake minimum…). Example: U channel dc01 2 mm, width 100, depth 40, flange_sides [front, back], flange_length 25; box: all four sides, corners closed.",
                 ["material": ["type": "string", "enum": .array(SheetMaterial.all.map { .string($0.id) })],
                  "thickness": ["type": "number", "minimum": 0.1, "maximum": 30],
                  "width": number, "depth": number,
                  "flange_sides": ["type": "array", "items": ["type": "string", "enum": ["front", "right", "back", "left"]], "maxItems": 4],
                  "flange_length": number,
                  "flange_angle": ["type": "number", "minimum": 5, "maximum": 135],
                  "flange_direction": ["type": "string", "enum": ["up", "down"]],
                  "flange_reference": ["type": "string", "enum": ["outside", "inside", "tangent"]],
                  "inside_radius": number,
                  "corners": ["type": "string", "enum": ["open", "closed"]],
                  "corner_gap": ["type": "number", "minimum": 0, "maximum": 5],
                  "name": name, "position": position, "color": color],
                 required: ["material", "thickness", "width", "depth"], write: true),
            tool("add_pattern", "Serie o specchio", "Copy a body: kind rectangular (count_x × count_y including the original, spacing_x/spacing_y in mm), circular (count including the original, angle total degrees, 360 = evenly all round, around a vertical axis at center {x,y}) or mirror (plane yz/xz/xy at offset = the coordinate of the plane along the mirrored axis). body_feature_id: the feature that created the body (list_features). join true merges the copies into that body (symmetric parts: model half, mirror about the middle face), false makes one new body with all copies.",
                 ["body_feature_id": id,
                  "kind": ["type": "string", "enum": ["rectangular", "circular", "mirror"]],
                  "count_x": ["type": "integer", "minimum": 1, "maximum": 100], "spacing_x": ["type": "number"],
                  "count_y": ["type": "integer", "minimum": 1, "maximum": 100], "spacing_y": ["type": "number"],
                  "count": ["type": "integer", "minimum": 2, "maximum": 360], "angle": ["type": "number", "minimum": -360, "maximum": 360],
                  "center": point, "plane": ["type": "string", "enum": ["yz", "xz", "xy"]], "offset": ["type": "number"],
                  "join": ["type": "boolean"], "name": name, "color": color],
                 required: ["body_feature_id", "kind"], write: true),
            tool("add_split", "Dividi corpo", "Cut a body in two with a plane parallel to yz, xz or xy at offset (the plane's coordinate along X, Y or Z). keep: both (default: the original keeps the negative side, the positive side becomes a new body), positive or negative. Typical use: split a part taller or larger than the print bed.",
                 ["body_feature_id": id, "plane": ["type": "string", "enum": ["yz", "xz", "xy"]], "offset": ["type": "number"],
                  "keep": ["type": "string", "enum": ["both", "positive", "negative"]], "name": name, "color": color],
                 required: ["body_feature_id", "plane", "offset"], write: true),
            tool("list_project_designs", "Disegni del progetto", "List the designs (.ftk) in the project library, with the path to use in add_component."),
            tool("add_component", "Inserisci componente", "Insert another design of the project into this one as an assembly component (linked: it follows the part's changes). path from list_project_designs; position translates it (mm); rotation {x,y,z} in degrees about the world axes, applied X then Y then Z before the position.",
                 ["path": ["type": "string", "minLength": 1], "position": position, "rotation": position, "name": name, "color": color],
                 required: ["path"], write: true),
            tool("bill_of_materials", "Distinta base", "Bill of materials of the assembly: one row per inserted part with quantity, sheet material, volume per piece and mass per piece when the material is known."),
            tool("add_chamfer", "Smussa o raccorda spigoli", "Chamfer (bevel) or round (fillet) edges of an existing body. feature_id: the feature that created the body (from list_features). edges: all | top | bottom | vertical (top/bottom = edges lying at the body's highest/lowest Z; vertical = straight edges parallel to Z). Straight edges between planar faces and circular rims of cylinders and holes are supported, convex (material removed) and concave inside corners (material added: e.g. a round at the root of a boss or wall strengthens printed parts). mode: equalDistance (default, uses distance) | twoDistances (distance and distance2) | distanceAngle (distance and angle in degrees). profile: flat (default, chamfer) | round (constant-radius fillet; distance is the radius, mode ignored). Example: 1 mm chamfer on the top edges of a plate; round the vertical edges of a box with radius 3.",
                 ["feature_id": id,
                  "profile": ["type": "string", "enum": ["flat", "round"]],
                  "edges": ["type": "string", "enum": ["all", "top", "bottom", "vertical"]],
                  "mode": ["type": "string", "enum": .array(ChamferSpec.Mode.allCases.map { .string($0.rawValue) })],
                  "distance": ["type": "number", "minimum": 0.01, "maximum": 1000],
                  "distance2": ["type": "number", "minimum": 0.01, "maximum": 1000],
                  "angle": ["type": "number", "minimum": 1, "maximum": 89],
                  "name": name],
                 required: ["feature_id", "edges", "distance"], write: true),
            tool("update_feature", "Modifica geometria", "Update only supplied fields of an existing feature, retaining its ID and kind. width/depth only box, radius only cylinder, points only extrude, height all. No change of kind.", fields(["feature_id": id, "width": number, "depth": number, "height": number, "radius": number, "points": points]), required: ["feature_id"], write: true),
            tool("delete_feature", "Elimina geometria", "Delete exactly one identified feature. Undo can restore it.", ["feature_id": id], required: ["feature_id"], write: true),
            tool("set_visibility", "Visibilità geometria", "Show/hide one feature. Hidden features are omitted from scene mesh and whole-scene export.", ["feature_id": id, "visible": ["type": "boolean"]], required: ["feature_id", "visible"], write: true),
            tool("set_color", "Colore parte", "Set a whole part's opaque sRGB colour without changing geometry. Persisted in the design and 3MF. Filament assignment must be checked in the slicer.", ["feature_id": id, "color": color], required: ["feature_id", "color"], write: true),
            tool("export_stl", "Esporta STL", "Return binary STL as base64, never write arbitrary files. Optional feature_id exports that feature even if hidden; otherwise visible scene. Independent solids are concatenated, not boolean-unioned; closure does not certify manufacturability. Coordinates in mm; STL has no unit metadata.", ["feature_id": id]),
            tool("export_3mf", "Esporta 3MF a colori", "Return 3MF as base64 with named separate parts, relative placement, mm and sRGB part colours. Optional feature_id includes that feature even if hidden; otherwise visible parts. No printer profile, AMS mapping, G-code or boolean union. Check filament assignment in Bambu Studio/OrcaSlicer.", ["feature_id": id]),
            tool("export_step", "Esporta STEP", "Return STEP AP214 (ISO 10303-21) text as base64, mm: one manifold solid per visible body with its colour; planar faces exact, curved faces as facets. Optional feature_id exports that feature's body even if hidden. For suppliers, CNC/CAM and other CAD.", ["feature_id": id]),
            tool("export_drawing", "Tavola tecnica", "Return a technical drawing of the visible bodies as a one-page PDF (base64): ISO first-angle front, top and left views with hidden lines dashed, an isometric view, overall dimensions, hole diameters and centre lines, title block. title: the drawing's name; material: optional; format: A4 (default) or A3.", ["title": ["type": "string"], "material": ["type": "string"], "format": ["type": "string", "enum": ["A4", "A3"]]]),
            tool("export_flat_dxf", "Esporta sviluppo DXF", "Return the flat pattern of a sheet-metal part as ASCII DXF (base64), mm: closed outline and round holes on layer CUT, bend lines on BEND_UP/BEND_DOWN, bend-zone tangents on BEND_TANGENT, material/radius/K in comments. Holes drilled into the folded part are unfolded when they are on the plate or on a flange's straight part. feature_id: the sheet-metal feature (optional when there is only one).", ["feature_id": id]),
            tool("undo", "Annulla assistente", "Undo the latest change if it was made by the assistant; a change made by the user is never undone. Session undo, not persistent parametric history.", write: true),
            tool("redo", "Ripeti assistente", "Redo the latest undone assistant change. A new edit clears redo.", write: true)
        ]
    }()

    private static func object(_ properties: [String: JSONValue], required: [String]) -> JSONValue {
        ["type": "object", "properties": .object(properties), "required": .array(required.map(JSONValue.string)), "additionalProperties": false]
    }
}
