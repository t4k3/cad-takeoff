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
        func symmetric(_ f: [CommandField]) -> Bool {
            if case .index(1)? = f.first(where: { $0.id == "extent" })?.value { return true }
            return false
        }
        func reversed(_ f: [CommandField]) -> Bool {
            if case let .index(i)? = f.first(where: { $0.id == "dir" })?.value { return onFace && i == 1 }
            return false
        }
        var lastOp = BooleanOperation.newBody
        var toFace: FaceID?
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
            sketch.onFacePick = nil
            sketch.previewSymmetric = false
            sketch.previewTaper = 0
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
                           help: (onFace ? "Profondità dalla faccia" : "Altezza dell'estrusione verso +Z") + " · anche un'espressione dei Parametri",
                           acceptsExpression: true),
                     .init(id: "extent", label: "Estensione", kind: .choice(["Una direzione", "Simmetrica", "Passante", "Fino a faccia"]), value: .index(0),
                           help: "Simmetrica: metà distanza da ogni parte del piano dello schizzo. Passante: attraversa tutti i corpi (anche se poi crescono). Fino a faccia: arriva al piano di una faccia del pezzo"),
                     .init(id: "toFace", label: "Faccia", kind: .reference(prompt: "Clicca la faccia", maxCount: 1), value: .references([]),
                           help: "La faccia piana a cui arriva l'estrusione (la segue se il pezzo cambia)", isHidden: true),
                     .init(id: "taper", label: "Sformo", kind: .angle(-60...60), value: .number(0),
                           help: "Angolo delle pareti: positivo le stringe allontanandosi dallo schizzo (sformo per stampi), negativo le allarga"),
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
                // «Fino a faccia»: the face field appears and takes the clicks.
                let wantsFace: Bool = if case .index(3)? = f.first(where: { $0.id == "extent" })?.value { true } else { false }
                if session?.fields.first(where: { $0.id == "toFace" })?.isHidden == wantsFace {
                    session?.update("toFace") { $0.isHidden = !wantsFace }
                    session?.activeReference = wantsFace && toFace == nil ? "toFace" : (wantsFace ? nil : session?.activeReference)
                }
                sketch.previewSymmetric = symmetric(f)
                sketch.previewTaper = f.first { $0.id == "taper" }?.number ?? 0
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
                let heightExpression = f.first { $0.id == "h" }?.expression
                let op = operation(f)
                let seeds = sketch.selectedSeeds
                let areas = sketch.pickedAreas
                finish()
                guard !areas.isEmpty else { model.statusMessage = "Clicca almeno un'area da estrudere."; return }
                let placement = onFace ? FeaturePlacement(plane: sketch.sketch.plane, reversed: reversed(f)) : nil
                // One solid per area (disjoint areas are separate bodies, as in Fusion).
                var features: [Feature] = []
                for area in areas {
                    var feature = Feature(name: (op == .cut ? "Taglio " : "Estrusione ") + "\(model.document.features.count + features.count + 1)",
                                          kind: .extrude(profile: Profile2D(points: area.outline), height: height), operation: op, placement: placement,
                                          holes: area.holes.map { Profile2D(points: $0) })
                    if let heightExpression { feature.expressions["height"] = heightExpression }
                    feature.keyProfile(from: sketch.sketch)
                    feature.symmetric = symmetric(f)
                    if case .index(2)? = f.first(where: { $0.id == "extent" })?.value { feature.throughAll = true }
                    if case .index(3)? = f.first(where: { $0.id == "extent" })?.value, let face = toFace { feature.untilFace = face }
                    feature.taper = f.first { $0.id == "taper" }?.number ?? 0
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
        created.parameterValues = sketch.parameterValues
        sketch.onFacePick = { [weak created] id in
            guard let created else { return }
            toFace = id
            created.update("toFace") { $0.value = .references([id.rawValue]) }
            created.activeReference = nil
            // The height the face gives, shown in the distance field.
            let plane = sketch.sketch.plane
            if let body = model.evaluation().bodies.first(where: { $0.snapshot.faces.contains { $0.id == id } }),
               case let .plane(o, _)? = body.snapshot.faces.first(where: { $0.id == id })?.surface {
                let d = (o - plane.origin).dot(plane.normal)
                if abs(d) > 1e-6 { created.update("h") { $0.value = .number(abs(d)) } }
            }
        }
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

extension SketchCommands {
    /// «Rivoluzione» from sketch profiles, as in Fusion: click the areas, then the axis line (a
    /// construction line is picked by itself when it is the only one); angle, direction and
    /// operation, with a wireframe preview. OK adds the solids linked to the sketch.
    static func revolve(sketch: SketchSession, model: DesignModel, workspace: WorkspaceState) -> CommandSession? {
        guard !sketch.faces.isEmpty else { return nil }
        if let shape = sketch.extrudeCandidate {
            let inside = sketch.faces.filter { SketchArrangement.inside($0.seed, shape.outline) }
            sketch.selectedSeeds = inside.max(by: { $0.area < $1.area }).map { [$0.seed] } ?? []
        } else {
            sketch.selectedSeeds = []
        }
        sketch.pickingRegions = true
        // The only construction line (the usual centre line) is the axis to start with.
        let construction = sketch.shapes.filter { $0.isConstruction && $0.segmentCount == 1 }
        var axis: SketchRef? = construction.count == 1 ? .segment(construction[0].id, 0) : nil
        weak var session: CommandSession?
        func axisLabel() -> CommandField.Value { .references(axis.map { _ in ["asse"] } ?? []) }
        func angle(_ f: [CommandField]) -> Double { f.first { $0.id == "angle" }?.number ?? 360 }
        func reversed(_ f: [CommandField]) -> Bool { if case let .flag(b)? = f.first(where: { $0.id == "rev" })?.value { b } else { false } }
        func operation(_ f: [CommandField]) -> BooleanOperation {
            if case let .index(i)? = f.first(where: { $0.id == "op" })?.value { return BooleanOperation.allCases[i] }
            return .newBody
        }
        func preview(_ f: [CommandField]) {
            guard let axis, case let .segment(id, j) = axis, let (a, b) = sketch.shape(id)?.segment(j) else { sketch.revolvePreview = nil; return }
            sketch.revolvePreview = .init(axisStart: a, axisEnd: b, angle: angle(f), reversed: reversed(f), isCut: operation(f) == .cut)
        }
        func finish() {
            sketch.pickingRegions = false
            sketch.selectedSeeds = []
            sketch.onRegionsChange = {}
            sketch.onAxisPick = nil
            sketch.revolvePreview = nil
        }
        let created = CommandSession(
            title: "Rivoluzione", symbol: "arrow.triangle.2.circlepath",
            fields: [.init(id: "areas", label: "Profili", kind: .reference(prompt: "Clicca le aree", maxCount: 500),
                           value: .references(sketch.pickedAreas.map { "\($0.seed)" }),
                           help: "Clicca un'area per aggiungerla o toglierla"),
                     .init(id: "axis", label: "Asse", kind: .reference(prompt: "Clicca la linea d'asse", maxCount: 1), value: axisLabel(),
                           help: "Una linea dello schizzo (meglio di costruzione): il profilo le gira intorno"),
                     .init(id: "angle", label: "Angolo", kind: .angle(0.1...360), value: .number(360), help: "360° = giro completo"),
                     .init(id: "rev", label: "Verso opposto", kind: .toggle, value: .flag(false)),
                     .init(id: "op", label: "Operazione", kind: .choice(BooleanOperation.allCases.map(\.label)), value: .index(0),
                           help: "Nuovo corpo, oppure unisci/taglia/interseca i corpi che tocca")],
            onPreview: preview,
            onCommit: { f in
                let seeds = sketch.selectedSeeds, areas = sketch.pickedAreas
                let picked = axis
                finish()
                guard !areas.isEmpty else { model.statusMessage = "Clicca almeno un'area."; return }
                guard let picked, case let .segment(id, j) = picked, let (a, b) = sketch.shape(id)?.segment(j) else {
                    model.statusMessage = "Clicca la linea d'asse."; return
                }
                let op = operation(f)
                let plane = sketch.sketch.plane
                var features: [Feature] = []
                for area in areas {
                    let spec = RevolveSpec(profile: Profile2D(points: area.outline), plane: plane, axisStart: a, axisEnd: b, axisRef: picked,
                                           angle: angle(f), reversed: reversed(f))
                    let feature = Feature(name: (op == .cut ? "Taglio " : "Rivoluzione ") + "\(model.document.features.count + features.count + 1)",
                                          kind: .revolve(spec), operation: op, holes: area.holes.map { Profile2D(points: $0) })
                    do {
                        try CADToolValidation.feature(feature)
                    } catch {
                        model.statusMessage = "Rivoluzione non riuscita: \(error.localizedDescription)"
                        return
                    }
                    features.append(feature)
                }
                let saved = sketch.sketch
                model.edit("Rivoluzione", selected: .some(features[0].id), changed: features.map(\.id)) { doc in
                    doc.upsert(saved)
                    for (feature, area) in zip(features, areas) {
                        doc.features.append(feature)
                        let own = seeds.filter { area.contains($0) }
                        doc.sketchLinks.append(SketchLink(featureID: feature.id, sketchID: saved.id, shapeID: UUID(),
                                                          seeds: own.isEmpty ? [area.seed] : own))
                    }
                }
                model.statusMessage = "Rivoluzione creata — ⌘Z per annullare"
                workspace.exitSketch()
            },
            onCancel: { finish() })
        session = created
        sketch.onRegionsChange = { [weak created] in
            guard let created else { return }
            created.update("areas") { $0.value = .references(sketch.pickedAreas.map { "\($0.seed)" }) }
        }
        sketch.onAxisPick = { [weak created] ref in
            guard let created else { return }
            axis = ref
            created.update("axis") { $0.value = axisLabel() }
            created.activeReference = sketch.pickedAreas.isEmpty ? "areas" : nil
            preview(created.fields)
        }
        if axis != nil { created.activeReference = sketch.pickedAreas.isEmpty ? "areas" : nil }
        preview(created.fields)
        _ = session
        workspace.viewRequest = .home
        return created
    }
}
