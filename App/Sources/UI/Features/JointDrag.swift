import CADCore
import Foundation
import simd

/// Dragging a jointed part (Fusion's «drag»): the selected part turns about its joint's axis
/// (rotation, cylindrical) or slides along it (sliding; cylindrical with ⌥), following the mouse.
/// Live preview; one undo step on release. Only the selected part drags, so dragging elsewhere
/// still orbits the view.
@MainActor
final class JointDrag {
    let joint: Feature
    private var spec: JointSpec
    private let slides: Bool
    private let origin: Vec3, axis: Vec3
    /// Where the drag started: the angle of the mouse about the axis, or its place along it.
    private let start: Double
    private let startValue: Double
    private(set) var value: Double

    /// The last joint that moves `body` and lets it move (not rigid).
    static func joint(moving body: UUID, in doc: CADDocument) -> Feature? {
        doc.features.last { f in
            if case let .joint(s) = f.kind { s.moving == body && s.kind != .rigid } else { false }
        }
    }

    init?(body: UUID, ray: Ray, model: DesignModel, slide: Bool) {
        guard let joint = Self.joint(moving: body, in: model.document), case let .joint(spec) = joint.kind else { return nil }
        self.joint = joint
        self.spec = spec
        slides = spec.kind == .slider || (spec.kind == .cylindrical && slide)
        let at = JointCommand.frame(spec, bodies: model.evaluation().bodies)
        origin = at.origin; axis = at.axis
        startValue = slides ? spec.offset : spec.angle
        value = startValue
        guard let s = Self.measure(ray, origin: at.origin, axis: at.axis, slides: slides) else { return nil }
        start = s
    }

    /// The mouse about the axis (degrees) or along it (mm).
    private static func measure(_ ray: Ray, origin: Vec3, axis: Vec3, slides: Bool) -> Double? {
        let o = SIMD3<Double>(ray.origin), d = simd_normalize(SIMD3<Double>(ray.direction))
        let c = SIMD3(origin.x, origin.y, origin.z), k = simd_normalize(SIMD3(axis.x, axis.y, axis.z))
        if slides {
            // Closest point of the axis line to the ray: its place along the axis.
            let w = o - c, b = simd_dot(d, k), denom = 1 - b * b
            guard denom > 1e-6 else { return nil }
            return (simd_dot(k, w) - b * simd_dot(d, w)) / denom
        }
        // The ray on the plane across the axis through its origin: the angle there.
        let dn = simd_dot(d, k)
        guard abs(dn) > 1e-4 else { return nil }
        let q = o + d * (simd_dot(c - o, k) / dn) - c
        let helper = abs(k.z) < 0.9 ? SIMD3<Double>(0, 0, 1) : SIMD3<Double>(1, 0, 0)
        let e1 = simd_normalize(simd_cross(helper, k)), e2 = simd_cross(k, e1)
        return atan2(simd_dot(q, e2), simd_dot(q, e1)) * 180 / .pi
    }

    /// The joint with the dragged value, for the preview (1° or 0,5 mm steps).
    func move(_ ray: Ray, model: DesignModel) -> CADDocument? {
        guard let now = Self.measure(ray, origin: origin, axis: axis, slides: slides) else { return nil }
        var delta = now - start
        if !slides { delta = (delta + 540).truncatingRemainder(dividingBy: 360) - 180 }   // the short way round
        let next = slides ? ((startValue + delta) * 2).rounded() / 2 : (startValue + delta).rounded()
        value = next
        if slides { spec.offset = next } else { spec.angle = next }
        return document(model)
    }

    var label: String {
        slides ? "\(joint.name): corsa \(SheetMetalCommand.mm(value)) mm" : "\(joint.name): \(Int(value))°"
    }

    /// Release: one undo step (nothing if it did not move).
    func commit(model: DesignModel) {
        guard value != startValue, let doc = document(model) else { return }
        model.edit("Muovi \(joint.name)", changed: [joint.id]) { $0 = doc }
    }

    /// The design with the joint at the dragged value.
    private func document(_ model: DesignModel) -> CADDocument? {
        var doc = model.document
        guard let i = doc.features.firstIndex(where: { $0.id == joint.id }) else { return nil }
        doc.features[i].kind = .joint(spec)
        return doc
    }
}
