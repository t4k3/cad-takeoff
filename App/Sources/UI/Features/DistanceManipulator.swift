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
    /// The arrow points the way the value grows (extrusion height) instead of back out of the
    /// material (chamfer/round).
    var pointsAlong = false
    /// Unit direction of the drawn arrow.
    var arrowDirection: Vec3 { pointsAlong ? inward.normalized : -inward.normalized }
    func tip(length: Double) -> Vec3 { handle + arrowDirection * length }
    private(set) var isDragging = false
    @ObservationIgnored var onChange: (Double) -> Void = { _ in }
    /// Value at the moment the drag started and where the grab happened on the axis.
    @ObservationIgnored private var grab: (value: Double, point: Vec3, along: Vec3, forward: Vec3)?

    init(origin: Vec3, inward: Vec3, factor: Double, value: Double, range: ClosedRange<Double>, label: String) {
        self.origin = origin; self.inward = inward; self.factor = factor; self.value = value; self.range = range; self.label = label
    }

    var handle: Vec3 { origin + inward * (value * factor) }

    private var accent: SIMD3<Float> { isHot || isDragging ? SIMD3(1.0, 0.6, 0.12) : SIMD3(0.16, 0.52, 1.0) }

    /// Thin guide from the edge to the handle: shows what the value measures.
    func overlay() -> [(SIMD3<Float>, SIMD3<Float>, SIMD4<Float>)] {
        [(f(origin), f(handle), SIMD4(accent, 0.8))]
    }

    /// Solid arrow, Fusion style: a ball on the handle, a shaft and a cone pointing outward,
    /// `length` mm long (the caller keeps it a constant size on screen).
    func mesh(length: Double) -> GizmoMesh {
        let dir = arrowDirection
        let helper = abs(dir.z) < 0.9 ? Vec3(0, 0, 1) : Vec3(1, 0, 0)
        let u = helper.cross(dir).normalized, v = dir.cross(u)
        let n = 24
        func ring(_ k: Int) -> Vec3 { let t = Double(k) / Double(n) * 2 * .pi; return u * cos(t) + v * sin(t) }
        var out: [(SIMD3<Float>, SIMD3<Float>)] = []
        func tri(_ a: (Vec3, Vec3), _ b: (Vec3, Vec3), _ c: (Vec3, Vec3)) {
            for p in [a, b, c] { out.append((f(p.0), f(p.1))) }
        }
        let base = handle
        let ball = length * 0.08, shaft = length * 0.032, coneRadius = length * 0.11, coneLength = length * 0.3
        let coneStart = base + dir * (length - coneLength), tip = base + dir * length
        // Shaft.
        for k in 0..<n {
            let r0 = ring(k), r1 = ring(k + 1)
            let a = base + r0 * shaft, b = base + r1 * shaft, c = coneStart + r1 * shaft, d = coneStart + r0 * shaft
            tri((a, r0), (b, r1), (c, r1)); tri((a, r0), (c, r1), (d, r0))
        }
        // Cone and its base.
        for k in 0..<n {
            let r0 = ring(k), r1 = ring(k + 1)
            let n0 = (r0 * coneLength + dir * coneRadius).normalized, n1 = (r1 * coneLength + dir * coneRadius).normalized
            let nt = (r0 + r1).normalized * coneLength + dir * coneRadius
            tri((coneStart + r0 * coneRadius, n0), (coneStart + r1 * coneRadius, n1), (tip, nt.normalized))
            tri((coneStart, -dir), (coneStart + r1 * coneRadius, -dir), (coneStart + r0 * coneRadius, -dir))
        }
        // Ball on the handle.
        let rows = 10
        func sphere(_ i: Int, _ k: Int) -> Vec3 {
            let phi = Double(i) / Double(rows) * .pi
            return dir * cos(phi) + ring(k) * sin(phi)
        }
        for i in 0..<rows {
            for k in 0..<n {
                let a = sphere(i, k), b = sphere(i + 1, k), c = sphere(i + 1, k + 1), d = sphere(i, k + 1)
                tri((base + a * ball, a), (base + b * ball, b), (base + c * ball, c))
                tri((base + a * ball, a), (base + c * ball, c), (base + d * ball, d))
            }
        }
        return GizmoMesh(vertices: out, color: SIMD4(accent, isHot || isDragging ? 0.45 : 0.3))
    }

    /// Screen-space hit test against the arrow; `tolerance(d)` = mm per few points at distance d.
    func hits(_ ray: Ray, length: Double, tolerance: (Double) -> Double) -> Bool {
        let a = handle, b = tip(length: length)
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
