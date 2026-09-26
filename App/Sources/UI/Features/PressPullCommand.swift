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
        var plan: PressPull.Plan?
        weak var session: CommandSession?

        func pickedFace() -> (GeoRef, BodySnapshot)? {
            let bodies = model.evaluation().bodies
            for ref in workspace.geoSelection.reversed() {
                guard case .face = ref.kind, let b = bodies.first(where: { $0.id == ref.feature }) else { continue }
                return (ref, b.snapshot)
            }
            return nil
        }
        func distance(_ f: [CommandField]) -> Double { f.first { $0.id == "d" }?.number ?? 0 }

        /// Face → plan and arrow (called when the picked face changes).
        func choose() {
            // One face at a time: the last one clicked.
            if workspace.geoSelection.count > 1, let last = workspace.geoSelection.last { workspace.geoSelection = [last]; return }
            guard let (ref, snapshot) = pickedFace(), case let .face(id) = ref.kind,
                  let frame = PressPull.frame(of: id, in: snapshot) else {
                plan = nil; workspace.manipulator = nil
                session?.update("face") { $0.value = .references([]) }
                session?.update("what") { $0.label = "Clicca una faccia piana del pezzo." }
                return
            }
            plan = PressPull.plan(face: id, in: snapshot, document: model.document)
            session?.update("face") { $0.value = .references(["\(id)"]) }
            let what: String
            switch plan {
            case let .height(fid, _, _)?:
                let name = model.document.features.first { $0.id == fid }?.name ?? "feature"
                what = "Cambia l'altezza di «\(name)»."
            case .offset?: what = "Estrude la faccia: tirando si unisce al pezzo, spingendo taglia."
            case nil: what = "Questa faccia non si può spostare (curva o contorno troppo complesso)."
            }
            session?.update("what") { $0.label = what }
            guard plan != nil else { workspace.manipulator = nil; return }
            let arrow = DistanceManipulator(origin: frame.centre, inward: frame.normal, factor: 1,
                                            value: session.map { distance($0.fields) } ?? 0, range: -10_000...10_000, label: "D")
            arrow.pointsAlong = true
            arrow.onChange = { v in session?.update("d") { $0.value = .number(v) } }
            workspace.manipulator = arrow
        }

        func preview(_ f: [CommandField]) {
            let d = distance(f)
            if let m = workspace.manipulator, !m.isDragging { m.value = d }
            guard let plan, abs(d) > 1e-9, let (doc, _) = try? PressPull.apply(plan, distance: d, to: model.document) else {
                workspace.requestPreview(nil); return
            }
            workspace.requestPreview(doc)
        }

        func finish() {
            workspace.onGeoSelectionChange = nil
            workspace.manipulator = nil
            workspace.requestPreview(nil)
        }

        let created = CommandSession(
            title: "Premi/Tira", symbol: "arrow.up.and.down.square",
            fields: [
                .init(id: "face", label: "Faccia", kind: .reference(prompt: "Clicca una faccia", maxCount: 1), value: .references([]),
                      help: "La faccia sopra o sotto di un'estrusione cambia la sua altezza; le altre facce si estrudono"),
                .init(id: "d", label: "Distanza", kind: .length(-10_000...10_000), value: .number(0),
                      help: "Positiva = tira fuori, negativa = spingi dentro. Puoi anche trascinare la freccia o cliccare l'etichetta"),
                .init(id: "what", label: "Clicca una faccia piana del pezzo.", kind: .note(warning: false), value: .flag(false)),
            ],
            onPreview: preview,
            onCommit: { f in
                defer { finish() }
                let d = distance(f)
                guard let plan else { model.statusMessage = "Scegli una faccia piana."; return }
                guard abs(d) > 1e-9 else { model.statusMessage = "Distanza nulla: trascina la freccia o scrivi la distanza."; return }
                do {
                    let name = d > 0 ? "Tira \(fmt(d)) mm" : "Spingi \(fmt(-d)) mm"
                    let (doc, id) = try PressPull.apply(plan, distance: d, to: model.document, name: name)
                    model.edit(name, selected: .some(id), changed: [id]) { $0 = doc }
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
