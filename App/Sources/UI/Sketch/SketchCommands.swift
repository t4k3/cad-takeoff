import CADCore
import SwiftUI

/// "Estrudi" from sketch profiles, as in Fusion: click the areas to extrude (the ring between two
/// circles keeps its hole; neighbouring areas merge), distance with wireframe preview; OK adds the
/// validated solids, saves the sketch and links them in one undoable step.
@MainActor
enum SketchCommands {
    static func extrude(sketch: SketchSession, model: DesignModel, workspace: WorkspaceState) -> CommandSession? {
        let allFaces = sketch.faces
        guard !allFaces.isEmpty else { return nil }
        // Starts from the selected (or only) closed shape's area; clicks add or remove areas.
        // Starts from the selected (or only) closed shape: its largest face (a ring for a circle
        // with another inside, the whole shape otherwise).
        if let shape = sketch.extrudeCandidate {
            let inside = allFaces.filter { SketchArrangement.inside($0.seed, shape.outline) }
            sketch.selectedSeeds = inside.max(by: { $0.area < $1.area }).map { [$0.seed] } ?? []
        } else {
            sketch.selectedSeeds = []
        }
        sketch.pickingRegions = true
        sketch.previewHeight = 10
        sketch.previewReversed = false
        let onFace = !sketch.sketch.plane.isXY
        func operation(_ f: [CommandField]) -> BooleanOperation {
            if case let .index(i)? = f.first(where: { $0.id == "op" })?.value { return BooleanOperation.allCases[i] }
            return .newBody
        }
        func reversed(_ f: [CommandField]) -> Bool {
            if case let .index(i)? = f.first(where: { $0.id == "dir" })?.value { return onFace && i == 1 }
            return false
        }
        var lastOp = BooleanOperation.newBody
        weak var session: CommandSession?
        // Arrow at the first area's centre, pointing out along the plane's normal.
        let plane = sketch.sketch.plane, normal = plane.normal
        func arrowOrigin() -> Vec3 {
            let outline = sketch.pickedAreas.first?.outline ?? sketch.faces.first?.outline ?? []
            return plane.world(Vec2(outline.map(\.x).reduce(0, +) / Double(max(outline.count, 1)),
                                    outline.map(\.y).reduce(0, +) / Double(max(outline.count, 1))))
        }
        func areasLabel() -> CommandField.Value {
            .references(sketch.pickedAreas.map { "\($0.seed)" })
        }
        let arrow = DistanceManipulator(origin: arrowOrigin(), inward: normal, factor: 1, value: 10, range: 0.1...10_000, label: "H")
        arrow.pointsAlong = true
        arrow.onChange = { v in
            guard let i = session?.fields.firstIndex(where: { $0.id == "h" }) else { return }
            session?.fields[i].value = .number(v)
        }
        workspace.manipulator = arrow
        // Seen from above the arrow points at the camera: turn to a 3/4 view, as Fusion does.
        workspace.viewRequest = .home
        func finish() {
            sketch.previewHeight = nil
            sketch.pickingRegions = false
            sketch.selectedSeeds = []
            sketch.onRegionsChange = {}
            workspace.manipulator = nil
        }
        let created = CommandSession(
            title: "Estrudi", symbol: "square.stack.3d.up",
            fields: [.init(id: "areas", label: "Profili", kind: .reference(prompt: "Clicca le aree da estrudere", maxCount: 500), value: areasLabel(),
                           help: "Clicca un'area per aggiungerla o toglierla: l'anello tra due cerchi lascia il foro, aree vicine si uniscono"),
                     .init(id: "h", label: "Distanza", kind: .length(0.01...10000), value: .number(10),
                           help: onFace ? "Profondità dalla faccia" : "Altezza dell'estrusione verso +Z"),
                     .init(id: "op", label: "Operazione", kind: .choice(BooleanOperation.allCases.map(\.label)), value: .index(0),
                           help: "Nuovo corpo, oppure unisci/taglia/interseca i corpi che tocca"),
                     .init(id: "dir", label: "Direzione", kind: .choice(["Fuori dalla faccia", "Dentro il pezzo"]), value: .index(0),
                           help: "Su una faccia: un taglio va dentro il pezzo, un'unione verso l'esterno", isHidden: !onFace)],
            onPreview: { f in
                let op = operation(f)
                // Switching to «Taglia» on a face flips the direction into the part (once).
                if onFace, op == .cut, lastOp != .cut, case .index(0)? = f.first(where: { $0.id == "dir" })?.value {
                    lastOp = op
                    session?.update("dir") { $0.value = .index(1) }
                    return
                }
                lastOp = op
                sketch.previewHeight = f.first { $0.id == "h" }?.number
                sketch.previewIsCut = op == .cut
                sketch.previewReversed = reversed(f)
                // Drag arrow on the profile, along the extrusion.
                if let m = workspace.manipulator {
                    m.inward = normal * (reversed(f) ? -1 : 1)
                    if !m.isDragging, let h = f.first(where: { $0.id == "h" })?.number { m.value = h }
                }
            },
            onCommit: { f in
                let height = f.first { $0.id == "h" }?.number ?? 10
                let op = operation(f)
                let seeds = sketch.selectedSeeds
                let areas = sketch.pickedAreas
                finish()
                guard !areas.isEmpty else { model.statusMessage = "Clicca almeno un'area da estrudere."; return }
                let placement = onFace ? FeaturePlacement(plane: sketch.sketch.plane, reversed: reversed(f)) : nil
                // One solid per area (disjoint areas are separate bodies, as in Fusion).
                var features: [Feature] = []
                for area in areas {
                    let feature = Feature(name: (op == .cut ? "Taglio " : "Estrusione ") + "\(model.document.features.count + features.count + 1)",
                                          kind: .extrude(profile: Profile2D(points: area.outline), height: height), operation: op, placement: placement,
                                          holes: area.holes.map { Profile2D(points: $0) })
                    do {
                        try CADToolValidation.feature(feature)
                    } catch {
                        model.statusMessage = "Estrusione non riuscita: \(error.localizedDescription)"
                        return
                    }
                    features.append(feature)
                }
                // One undo step: saves the sketch, adds the solids and links them to their shapes.
                let saved = sketch.sketch
                let what = areas.count == 1 ? "profilo" : "\(areas.count) profili"
                model.edit((op == .newBody ? "Estrudi " : op.label + ": ") + what, selected: .some(features[0].id), changed: features.map(\.id)) { doc in
                    doc.upsert(saved)
                    for (feature, area) in zip(features, areas) {
                        doc.features.append(feature)
                        // The face is found again from the points picked inside it.
                        let own = seeds.filter { area.contains($0) }
                        doc.sketchLinks.append(SketchLink(featureID: feature.id, sketchID: saved.id, shapeID: UUID(),
                                                          seeds: own.isEmpty ? [area.seed] : own))
                    }
                }
                model.statusMessage = "Estrusione creata (\(fmt(height)) mm) — ⌘Z per annullare"
                workspace.exitSketch()
            },
            onCancel: { finish() })
        session = created
        // Picking an area updates the count, the arrow's place and the preview.
        sketch.onRegionsChange = { [weak created] in
            guard let created else { return }
            created.update("areas") { $0.value = areasLabel() }
            workspace.manipulator?.origin = arrowOrigin()
        }
        return created
    }
}
