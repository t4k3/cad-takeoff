import CADCore
import SwiftUI

/// "Premi/Tira" (Fusion's Press Pull, key Q): click a planar face, drag its arrow or type the
/// distance. The top/bottom of an extrusion, box or cylinder changes that feature's height; any
/// other face is extruded (joined when pulled, cut when pushed). Live preview; OK = one undo step.
@MainActor
enum PressPullCommand {
    static func start(workspace: WorkspaceState, model: DesignModel) -> CommandSession {
        workspace.selectionFilter = .face
        workspace.geoSelection.removeAll { if case .face = $0.kind { false } else { true } }
        // Every click adds or removes a face (no ⇧ needed), as for the areas in Estrudi.
        workspace.edgePicking = true
        var plans: [PressPull.Plan] = []
        var faceIDs: [FaceID] = []
        weak var session: CommandSession?

        func faces() -> [(FaceID, BodySnapshot)] {
            let bodies = model.evaluation().bodies
            return workspace.geoSelection.compactMap { ref in
                guard case let .face(id) = ref.kind, let b = bodies.first(where: { $0.id == ref.feature }) else { return nil }
                return (id, b.snapshot)
            }
        }
        func distance(_ f: [CommandField]) -> Double { f.first { $0.id == "d" }?.number ?? 0 }

        /// Picked faces → plans and the arrow (on the first movable face).
        func choose() {
            let picked = faces()
            var movable: [(FaceID, BodySnapshot, PressPull.Plan)] = []
            var fixed = 0
            for (id, snap) in picked {
                if let plan = PressPull.plan(face: id, in: snap, document: model.document) { movable.append((id, snap, plan)) } else { fixed += 1 }
            }
            plans = movable.map(\.2)
            faceIDs = movable.map(\.0)
            session?.update("face") { $0.value = .references(picked.map { "\($0.0)" }) }
            var notes: [String] = []
            let heights = Set(plans.compactMap { if case let .height(id, _, _) = $0 { id } else { nil } })
            let names = heights.compactMap { id in model.document.features.first { $0.id == id }?.name }.sorted()
            if !names.isEmpty { notes.append("Cambia l'altezza di " + names.map { "«\($0)»" }.joined(separator: ", ") + ".") }
            let offsets = plans.filter { if case .offset = $0 { true } else { false } }.count
            if offsets > 0 { notes.append(offsets == 1 ? "1 faccia estrusa (tirando si unisce, spingendo taglia)." : "\(offsets) facce estruse (tirando si uniscono, spingendo tagliano).") }
            if fixed > 0 { notes.append("\(fixed) facc\(fixed == 1 ? "ia curva o complessa ignorata" : "e curve o complesse ignorate").") }
            if picked.isEmpty { notes = ["Clicca le facce piane da spostare: ogni clic aggiunge o toglie."] }
            session?.update("what") { $0.label = notes.joined(separator: " ") }
            guard let (id, snap, _) = movable.first, let frame = PressPull.frame(of: id, in: snap) else { workspace.manipulator = nil; return }
            if let m = workspace.manipulator {
                m.origin = frame.centre; m.inward = frame.normal
            } else {
                let arrow = DistanceManipulator(origin: frame.centre, inward: frame.normal, factor: 1,
                                                value: session.map { distance($0.fields) } ?? 0, range: -10_000...10_000, label: "D")
                arrow.pointsAlong = true
                arrow.onChange = { v in session?.update("d") { $0.value = .number(v) } }
                workspace.manipulator = arrow
            }
            if let session { preview(session.fields) }
        }

        /// Heights together with extruded faces: the extruded ones are re-read on the raised part
        /// (no step); otherwise the plans apply as they are (fast while dragging).
        func moved(_ d: Double, name: String = "Premi/Tira") throws -> (CADDocument, [UUID]) {
            let mixed = plans.contains { if case .height = $0 { true } else { false } } && plans.contains { if case .offset = $0 { true } else { false } }
            return mixed ? try PressPull.move(faces: faceIDs, distance: d, in: model.document, components: model.componentResolver, name: name)
                         : try PressPull.apply(plans, distance: d, to: model.document, name: name)
        }

        func preview(_ f: [CommandField]) {
            let d = distance(f)
            if let m = workspace.manipulator, !m.isDragging { m.value = d }
            guard !plans.isEmpty, abs(d) > 1e-9, let (doc, _) = try? moved(d) else {
                workspace.requestPreview(nil); return
            }
            workspace.requestPreview(doc)
        }

        func finish() {
            workspace.onGeoSelectionChange = nil
            workspace.edgePicking = false
            workspace.manipulator = nil
            workspace.requestPreview(nil)
        }

        let created = CommandSession(
            title: "Premi/Tira", symbol: "arrow.up.and.down.square",
            fields: [
                .init(id: "face", label: "Facce", kind: .reference(prompt: "Clicca le facce", maxCount: 100), value: .references([]),
                      help: "Ogni clic aggiunge o toglie una faccia. Sopra/sotto di un'estrusione cambia la sua altezza; le altre facce si estrudono"),
                .init(id: "d", label: "Distanza", kind: .length(-10_000...10_000), value: .number(0),
                      help: "Positiva = tira fuori, negativa = spingi dentro; ogni faccia lungo la sua normale. Puoi anche trascinare la freccia o cliccare l'etichetta"),
                .init(id: "what", label: "Clicca le facce piane da spostare: ogni clic aggiunge o toglie.", kind: .note(warning: false), value: .flag(false)),
            ],
            onPreview: preview,
            onCommit: { f in
                defer { finish() }
                let d = distance(f)
                guard !plans.isEmpty else { model.statusMessage = "Scegli almeno una faccia piana."; return }
                guard abs(d) > 1e-9 else { model.statusMessage = "Distanza nulla: trascina la freccia o scrivi la distanza."; return }
                do {
                    let name = (d > 0 ? "Tira \(fmt(d)) mm" : "Spingi \(fmt(-d)) mm") + (plans.count > 1 ? " (\(plans.count) facce)" : "")
                    let (doc, ids) = try moved(d, name: name)
                    model.edit(name, selected: .some(ids.first), changed: ids) { $0 = doc }
                    workspace.geoSelection = []
                } catch {
                    model.statusMessage = "Premi/Tira: \(error.localizedDescription)"
                }
            },
            onCancel: { finish() })
        session = created
        workspace.onGeoSelectionChange = { choose() }
        choose()
        return created
    }
}
