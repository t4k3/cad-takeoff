import CADCore
import Observation
import simd
import SwiftUI

/// Fusion-style drag arrow for one length value (chamfer distance, round radius…).
/// The arrow sits where the value puts it along `inward` and points back out; dragging it
/// along its axis changes the value.
@MainActor
@Observable
final class DistanceManipulator {
    var origin: Vec3
    /// Unit direction in which a larger value moves the handle.
    var inward: Vec3
    /// Handle offset per unit of value.
    var factor: Double
    var value: Double
    var range: ClosedRange<Double>
    var label: String
    var isHot = false
    private(set) var isDragging = false
    @ObservationIgnored var onChange: (Double) -> Void = { _ in }
    /// Value at the moment the drag started and where the grab happened on the axis.
    @ObservationIgnored private var grab: (value: Double, point: Vec3, along: Vec3, forward: Vec3)?

    init(origin: Vec3, inward: Vec3, factor: Double, value: Double, range: ClosedRange<Double>, label: String) {
        self.origin = origin; self.inward = inward; self.factor = factor; self.value = value; self.range = range; self.label = label
    }

    var handle: Vec3 { origin + inward * (value * factor) }

    /// Arrow from the handle outward, `length` mm long (constant size on screen).
    func overlay(length: Double) -> [(SIMD3<Float>, SIMD3<Float>, SIMD4<Float>)] {
        let colour: SIMD4<Float> = isHot || isDragging ? SIMD4(1, 0.78, 0.2, 1) : SIMD4(0.2, 0.62, 1, 1)
        let base = handle, tip = handle - inward * length
        let helper = abs(inward.z) < 0.9 ? Vec3(0, 0, 1) : Vec3(1, 0, 0)
        let u = helper.cross(inward).normalized, v = inward.cross(u)
        let head = length * 0.28
        var out = [(f(base), f(tip), colour)]
        for k in 0..<8 {
            let t = Double(k) / 8 * 2 * .pi
            let rim = tip + inward * head + (u * cos(t) + v * sin(t)) * (head * 0.4)
            out.append((f(tip), f(rim), colour))
        }
        // Small bar at the base: the point that measures the value.
        out.append((f(base - u * head * 0.4), f(base + u * head * 0.4), colour))
        return out
    }

    /// Screen-space hit test against the arrow; `tolerance(d)` = mm per few points at distance d.
    func hits(_ ray: Ray, length: Double, tolerance: (Double) -> Double) -> Bool {
        let a = handle, b = handle - inward * length
        let ro = Vec3(Double(ray.origin.x), Double(ray.origin.y), Double(ray.origin.z))
        let rd = Vec3(Double(ray.direction.x), Double(ray.direction.y), Double(ray.direction.z)).normalized
        for k in 0...12 {
            let p = a + (b - a) * (Double(k) / 12)
            let w = p - ro, t = w.dot(rd)
            guard t > 0 else { continue }
            if (w - rd * t).length <= tolerance(t) { return true }
        }
        return false
    }

    /// Drags are measured on the plane facing the camera through the handle, along the arrow's
    /// on-screen direction: the value follows the mouse at the same rate whatever the arrow's
    /// angle to the view (an arrow pointing at the camera would otherwise jump centimetres).
    func beginDrag(_ ray: Ray, viewDirection: SIMD3<Float>) {
        let forward = Vec3(Double(viewDirection.x), Double(viewDirection.y), Double(viewDirection.z)).normalized
        var along = inward - forward * inward.dot(forward)
        if along.length < 0.05 { along = forward.cross(Vec3(0, 0, 1)).cross(forward) }   // arrow at the camera
        guard let p = hit(ray, forward) else { return }
        isDragging = true
        grab = (value, p, along.normalized, forward)
    }

    func drag(_ ray: Ray) {
        guard let grab, factor > 1e-9, let p = hit(ray, grab.forward) else { return }
        var next = grab.value + (p - grab.point).dot(grab.along) / factor
        next = (next * 10).rounded() / 10                     // 0.1 mm steps
        next = min(max(next, range.lowerBound), range.upperBound)
        if next != value { value = next; onChange(next) }
    }

    func endDrag() { isDragging = false; grab = nil }

    /// Ray hit on the camera-facing plane through the handle.
    private func hit(_ ray: Ray, _ forward: Vec3) -> Vec3? {
        let ro = Vec3(Double(ray.origin.x), Double(ray.origin.y), Double(ray.origin.z))
        let rd = Vec3(Double(ray.direction.x), Double(ray.direction.y), Double(ray.direction.z)).normalized
        let den = rd.dot(forward)
        guard abs(den) > 1e-9 else { return nil }
        let t = (handleAtGrab - ro).dot(forward) / den
        return ro + rd * t
    }

    /// The plane stays where the drag started (the handle itself moves while dragging).
    private var handleAtGrab: Vec3 { grab.map { origin + inward * ($0.value * factor) } ?? handle }

    private func f(_ p: Vec3) -> SIMD3<Float> { SIMD3(Float(p.x), Float(p.y), Float(p.z)) }
}
