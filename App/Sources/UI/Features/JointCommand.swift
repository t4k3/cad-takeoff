import CADCore
import SwiftUI

/// «Giunto» (Fusion's Joint): click where the moving part grips (the rim of its hole or shaft, a
/// face), then where it goes on the other part; choose rigid, rotation or sliding and the angle or
/// travel. The first part moves; live preview; one undo step.
@MainActor
enum JointCommand {
    /// Drag handle for the joint's value, at its axis on the fixed part: an arrow along the axis
    /// for the travel (sliding), or across it, a little off the axis, for the angle (1° = the
    /// arc length at that radius).
    static func manipulator(kind: JointSpec.Kind, origin: Vec3, axis: Vec3, angle: Double, offset: Double,
                            reach: Double, session: @escaping () -> CommandSession?) -> DistanceManipulator {
        let k = axis.normalized
        if kind == .slider {
            let m = DistanceManipulator(origin: origin, inward: k, factor: 1, value: offset, range: -10_000...10_000, label: "Corsa")
            m.pointsAlong = true
            m.onChange = { v in session()?.update("offset") { $0.value = .number(v) } }
            return m
        }
        let helper = abs(k.z) < 0.9 ? Vec3(0, 0, 1) : Vec3(1, 0, 0)
        let radial = helper.cross(k).normalized, r = max(reach, 5)
        let m = DistanceManipulator(origin: origin + radial * r, inward: k.cross(radial), factor: r * .pi / 180, value: angle,
                                    range: -360...360, label: "Angolo")
        m.pointsAlong = true
        m.onChange = { v in session()?.update("angle") { $0.value = .number((v * 10).rounded() / 10) } }
        return m
    }

    /// Where the joint turns or slides now, in the world: the fixed part's grip.
    static func frame(_ spec: JointSpec, bodies: [DesignEvaluator.Body]) -> (origin: Vec3, axis: Vec3) {
        let fixed = spec.fixed.flatMap { id in bodies.first { $0.id == id }?.placement }
        let o = fixed.map { $0.point(spec.fixedOrigin) } ?? spec.fixedOrigin
        let a = (fixed.map { $0.direction(spec.fixedAxis) } ?? spec.fixedAxis).normalized
        return (o, spec.flip ? -a : a)
    }

    /// Size of a part, for the angle handle's radius.
    static func reach(_ id: UUID, bodies: [DesignEvaluator.Body]) -> Double {
        guard let b = bodies.first(where: { $0.id == id })?.mesh.bounds else { return 20 }
        return max((b.max - b.min).length / 3, 8)
    }

    static func start(workspace: WorkspaceState, model: DesignModel) -> CommandSession {
        workspace.selectionFilter = .edge
        workspace.geoSelection = []
        workspace.edgePicking = true
        weak var session: CommandSession?

        /// The two grips: body and world frame, from the picked edges or faces (two bodies).
        func grips() -> [(body: DesignEvaluator.Body, origin: Vec3, axis: Vec3)] {
            let bodies = model.evaluation().bodies
            var out: [(DesignEvaluator.Body, Vec3, Vec3)] = []
            for ref in workspace.geoSelection {
                guard let b = bodies.first(where: { $0.id == ref.feature }), !out.contains(where: { $0.0.id == b.id }) else { continue }
                let frame: (origin: Vec3, axis: Vec3)?
                switch ref.kind {
                case let .edge(id): frame = b.snapshot.edges.first { $0.id == id }.flatMap(JointFrame.from(edge:))
                case let .face(id): frame = JointFrame.from(face: id, in: b.snapshot)
                }
                if let frame { out.append((b, frame.origin, frame.axis)) }
                if out.count == 2 { break }
            }
            return out
        }
        func feature(_ f: [CommandField]) -> Feature? {
            let g = grips()
            guard g.count == 2 else { return nil }
            let kind: JointSpec.Kind = if case let .index(i)? = f.first(where: { $0.id == "kind" })?.value { JointSpec.Kind.allCases[i] } else { .revolute }
            let flip = if case let .flag(b)? = f.first(where: { $0.id == "flip" })?.value { b } else { false }
            // Points and axes in each part's own coordinates, so the joint follows the parts.
            let m = g[0].body.placement.inverse, x = g[1].body.placement.inverse
            let spec = JointSpec(kind: kind, moving: g[0].body.id, movingOrigin: m.point(g[0].origin), movingAxis: m.direction(g[0].axis),
                                 fixed: g[1].body.id, fixedOrigin: x.point(g[1].origin), fixedAxis: x.direction(g[1].axis),
                                 angle: f.first { $0.id == "angle" }?.number ?? 0, offset: f.first { $0.id == "offset" }?.number ?? 0, flip: flip)
            return Feature(name: "Giunto \(model.document.features.count + 1)", kind: .joint(spec))
        }
        func preview(_ f: [CommandField]) {
            let g = grips()
            let names = g.map { $0.body.source.name }
            session?.update("what") {
                $0.label = switch g.count {
                case 0: "Clicca dove si aggancia il pezzo che si muove (il bordo del foro o dell'albero, o una faccia)."
                case 1: "«\(names[0])» si muove: ora clicca dove va, sull'altro pezzo."
                default: "«\(names[0])» → «\(names[1])»"
                }
            }
            guard let joint = feature(f), case let .joint(spec) = joint.kind else {
                workspace.manipulator = nil
                workspace.requestPreview(nil); return
            }
            var doc = model.document
            doc.features.append(joint)
            workspace.requestPreview(doc)
            // The drag handle for the value, on the fixed part.
            let bodies = model.evaluation().bodies
            let at = frame(spec, bodies: bodies)
            let slides = spec.kind == .slider
            if let m = workspace.manipulator, m.label == (slides ? "Corsa" : "Angolo") {
                if !m.isDragging { m.value = slides ? spec.offset : spec.angle }
            } else {
                workspace.manipulator = manipulator(kind: spec.kind, origin: at.origin, axis: at.axis, angle: spec.angle, offset: spec.offset,
                                                    reach: reach(spec.moving, bodies: bodies), session: { session })
            }
        }
        func finish() {
            workspace.onGeoSelectionChange = nil
            workspace.edgePicking = false
            workspace.manipulator = nil
            workspace.requestPreview(nil)
        }
        let created = CommandSession(
            title: "Giunto", symbol: "link",
            fields: [
                .init(id: "what", label: "", kind: .note(warning: false), value: .flag(false)),
                .init(id: "kind", label: "Tipo", kind: .choice(JointSpec.Kind.allCases.map(\.label)), value: .index(1),
                      help: "Rigido: fermo. Rotazione: gira attorno all'asse. Scorrimento: scorre lungo l'asse. Cilindrico: tutte e due"),
                .init(id: "angle", label: "Angolo", kind: .angle(-360...360), value: .number(0)),
                .init(id: "offset", label: "Corsa", kind: .length(-10_000...10_000), value: .number(0), help: "Per scorrimento e cilindrico"),
                .init(id: "flip", label: "Inverti verso", kind: .toggle, value: .flag(false), help: "Il pezzo dall'altra parte dell'asse"),
            ],
            onPreview: preview,
            onCommit: { f in
                defer { finish() }
                guard let joint = feature(f) else { model.statusMessage = "Clicca due punti su due pezzi diversi."; return }
                model.edit("Giunto", selected: .some(joint.id), changed: [joint.id]) { $0.features.append(joint) }
                workspace.geoSelection = []
            },
            onCancel: { finish() })
        session = created
        workspace.onGeoSelectionChange = { preview(created.fields) }
        preview(created.fields)
        return created
    }

    /// An existing joint: its type, angle, travel and side (the grips stay).
    static func edit(_ original: Feature, model: DesignModel, workspace: WorkspaceState) -> CommandSession? {
        guard case let .joint(spec) = original.kind else { return nil }
        weak var session: CommandSession?
        func handle(_ s: JointSpec) {
            let slides = s.kind == .slider
            if let m = workspace.manipulator, m.label == (slides ? "Corsa" : "Angolo") {
                if !m.isDragging { m.value = slides ? s.offset : s.angle }
                return
            }
            let bodies = model.evaluation().bodies
            let at = frame(s, bodies: bodies)
            workspace.manipulator = manipulator(kind: s.kind, origin: at.origin, axis: at.axis, angle: s.angle, offset: s.offset,
                                                reach: reach(s.moving, bodies: bodies), session: { session })
        }
        func apply(_ f: [CommandField]) {
            guard let i = model.document.features.firstIndex(where: { $0.id == original.id }) else { return }
            var s = spec
            if case let .index(k)? = f.first(where: { $0.id == "kind" })?.value { s.kind = JointSpec.Kind.allCases[k] }
            s.angle = f.first { $0.id == "angle" }?.number ?? s.angle
            s.offset = f.first { $0.id == "offset" }?.number ?? s.offset
            if case let .flag(b)? = f.first(where: { $0.id == "flip" })?.value { s.flip = b }
            model.document.features[i].kind = .joint(s)
            handle(s)
        }
        let created = CommandSession(
            title: "Modifica \(original.name)", symbol: "link",
            fields: [.init(id: "kind", label: "Tipo", kind: .choice(JointSpec.Kind.allCases.map(\.label)), value: .index(JointSpec.Kind.allCases.firstIndex(of: spec.kind) ?? 1)),
                     .init(id: "angle", label: "Angolo", kind: .angle(-360...360), value: .number(spec.angle)),
                     .init(id: "offset", label: "Corsa", kind: .length(-10_000...10_000), value: .number(spec.offset)),
                     .init(id: "flip", label: "Inverti verso", kind: .toggle, value: .flag(spec.flip))],
            onPreview: apply, onCommit: { f in apply(f); workspace.manipulator = nil },
            onCancel: {
                workspace.manipulator = nil
                if let i = model.document.features.firstIndex(where: { $0.id == original.id }) { model.document.features[i] = original }
            })
        session = created
        handle(spec)
        return created
    }
}
