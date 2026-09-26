import CADCore
import QuartzCore
import Foundation
import Observation
import simd

/// Orbit camera around a target, Z-up (CADCore convention). Observable so overlays
/// such as the ViewCube follow it. Angles in radians, distances in millimetres.
@MainActor
@Observable
final class CameraController {
    enum Projection: String { case perspective, orthographic }

    struct Pose: Equatable {
        var target: SIMD3<Float>
        var yaw: Float       // around Z, 0 = looking from +X
        var pitch: Float     // elevation, +π/2 = from above
        var distance: Float
    }

    /// Named views, as on the ViewCube.
    enum StandardView: String, CaseIterable {
        case top = "Sopra", bottom = "Sotto", front = "Fronte", back = "Retro", right = "Destra", left = "Sinistra", home = "Home"

        var angles: (yaw: Float, pitch: Float) {
            switch self {
            case .top: (-.pi / 2, .pi / 2 - 0.0001)
            case .bottom: (-.pi / 2, -.pi / 2 + 0.0001)
            case .front: (-.pi / 2, 0)
            case .back: (.pi / 2, 0)
            case .right: (0, 0)
            case .left: (.pi, 0)
            case .home: (-.pi / 4 - 0.35, 0.55)
            }
        }
    }

    private(set) var pose = Pose(target: .zero, yaw: StandardView.home.angles.yaw,
                                 pitch: StandardView.home.angles.pitch, distance: 260)
    var projection: Projection = .perspective
    let fovY: Float = 35 * .pi / 180

    private var animation: (from: Pose, to: Pose, start: CFTimeInterval, duration: CFTimeInterval)?
    @ObservationIgnored private var timer: Timer?
    var isAnimating: Bool { animation != nil }
    /// Called on every camera change driven by an animation (the view redraws).
    @ObservationIgnored var onAnimationFrame: () -> Void = {}

    // MARK: Derived

    var eye: SIMD3<Float> {
        let p = pose
        let dir = SIMD3(cos(p.pitch) * cos(p.yaw), cos(p.pitch) * sin(p.yaw), sin(p.pitch))
        return p.target + dir * p.distance
    }

    var forward: SIMD3<Float> { simd_normalize(pose.target - eye) }

    /// Screen right and up in world space. Derived from the yaw, so they stay well defined looking
    /// straight down or up (Sopra/Sotto), and shared by drawing and by mouse rays and pans: if they
    /// disagreed, clicks and drags would come out mirrored in some views.
    var basis: (right: SIMD3<Float>, up: SIMD3<Float>) {
        let right = SIMD3(-sin(pose.yaw), cos(pose.yaw), 0)
        return (right, simd_cross(right, forward))
    }

    var viewMatrix: simd_float4x4 { .lookAt(eye: eye, target: pose.target, up: basis.up) }

    /// Rotation-only part of the view, used by the ViewCube.
    var rotationMatrix: simd_float3x3 {
        let v = viewMatrix
        return simd_float3x3(columns: (SIMD3(v.columns.0.x, v.columns.0.y, v.columns.0.z),
                                       SIMD3(v.columns.1.x, v.columns.1.y, v.columns.1.z),
                                       SIMD3(v.columns.2.x, v.columns.2.y, v.columns.2.z)))
    }

    func projectionMatrix(aspect: Float) -> simd_float4x4 {
        let near = max(pose.distance * 0.01, 0.05), far = pose.distance * 20 + 5000
        switch projection {
        case .perspective: return .perspective(fovY: fovY, aspect: aspect, near: near, far: far)
        case .orthographic:
            return .orthographic(halfHeight: pose.distance * tan(fovY / 2), aspect: aspect, near: -far, far: far)
        }
    }

    /// Ray through a point in view coordinates (points, origin top-left).
    func ray(at point: CGPoint, in size: CGSize) -> Ray {
        let aspect = Float(size.width / max(size.height, 1))
        let ndc = SIMD2(Float(point.x / size.width) * 2 - 1, 1 - Float(point.y / size.height) * 2)
        let f = forward
        let (right, up) = basis
        let halfH = tan(fovY / 2)
        switch projection {
        case .perspective:
            let dir = simd_normalize(f + right * ndc.x * halfH * aspect + up * ndc.y * halfH)
            return Ray(origin: eye, direction: dir)
        case .orthographic:
            let h = pose.distance * halfH
            return Ray(origin: eye + right * ndc.x * h * aspect + up * ndc.y * h, direction: f)
        }
    }

    // MARK: Interaction

    func orbit(dx: Float, dy: Float) {
        stopAnimation()
        pose.yaw -= dx * 0.008
        pose.pitch = min(.pi / 2 - 0.0001, max(-.pi / 2 + 0.0001, pose.pitch + dy * 0.008))
    }

    /// Pan by a screen delta (points) so the grabbed point stays under the cursor.
    func pan(dx: Float, dy: Float, viewHeight: Float) {
        stopAnimation()
        let (right, up) = basis
        let mmPerPoint = 2 * pose.distance * tan(fovY / 2) / max(viewHeight, 1)
        pose.target += (-right * dx + up * dy) * mmPerPoint
    }

    /// Zoom by `factor` (<1 = closer) keeping the point under the cursor fixed.
    func zoom(factor: Float, towards point: CGPoint?, in size: CGSize) {
        stopAnimation()
        let newDistance = min(max(pose.distance * factor, 2), 20_000)
        if let point, let hit = ray(at: point, in: size).intersect(planePoint: pose.target, normal: forward) {
            pose.target += (hit - pose.target) * (1 - newDistance / pose.distance)
        }
        pose.distance = newDistance
    }

    func show(_ view: StandardView, bounds: BoundingBox?) {
        var to = pose
        (to.yaw, to.pitch) = view.angles
        if view == .home, let bounds { to = framing(bounds, yaw: to.yaw, pitch: to.pitch) }
        // Take the short way round.
        while to.yaw - pose.yaw > .pi { to.yaw -= 2 * .pi }
        while pose.yaw - to.yaw > .pi { to.yaw += 2 * .pi }
        animate(to: to)
    }

    /// Looks straight at a plane (sketch on a face): view along −normal, the plane's X to the right.
    func look(at plane: SketchPlane, target: Vec3?) {
        var to = pose
        let n = plane.normal
        if abs(n.z) > 0.999 {
            (to.yaw, to.pitch) = (n.z > 0 ? StandardView.top : StandardView.bottom).angles
        } else {
            to.yaw = atan2(Float(n.y), Float(n.x))
            to.pitch = asin(Float(max(-1, min(1, n.z))))
        }
        if let target { to.target = SIMD3(Float(target.x), Float(target.y), Float(target.z)) }
        while to.yaw - pose.yaw > .pi { to.yaw -= 2 * .pi }
        while pose.yaw - to.yaw > .pi { to.yaw += 2 * .pi }
        animate(to: to)
    }

    func fit(_ bounds: BoundingBox?) {
        guard let bounds else { return }
        animate(to: framing(bounds, yaw: pose.yaw, pitch: pose.pitch))
    }

    func setOrientation(yaw: Float, pitch: Float) {
        var to = pose
        to.yaw = yaw; to.pitch = pitch
        while to.yaw - pose.yaw > .pi { to.yaw -= 2 * .pi }
        while pose.yaw - to.yaw > .pi { to.yaw += 2 * .pi }
        animate(to: to)
    }

    private func framing(_ b: BoundingBox, yaw: Float, pitch: Float) -> Pose {
        let c = b.center, s = b.size
        let radius = max(Float((s.x * s.x + s.y * s.y + s.z * s.z).squareRoot()) / 2, 5)
        return Pose(target: SIMD3(Float(c.x), Float(c.y), Float(c.z)), yaw: yaw, pitch: pitch,
                    distance: radius / sin(fovY / 2) * 1.15)
    }

    // MARK: Animation

    private func animate(to target: Pose) {
        animation = (pose, target, CACurrentMediaTime(), 0.35)
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let running = self.tick()
                self.onAnimationFrame()
                if !running { self.timer?.invalidate(); self.timer = nil }
            }
        }
    }

    private func stopAnimation() {
        animation = nil
        timer?.invalidate()
        timer = nil
    }

    /// Advances the animation; returns true while still running.
    @discardableResult
    func tick() -> Bool {
        guard let a = animation else { return false }
        let t = Float(min((CACurrentMediaTime() - a.start) / a.duration, 1))
        let e = t < 0.5 ? 4 * t * t * t : 1 - pow(-2 * t + 2, 3) / 2   // easeInOutCubic
        pose = Pose(target: simd_mix(a.from.target, a.to.target, SIMD3(repeating: e)),
                    yaw: a.from.yaw + (a.to.yaw - a.from.yaw) * e,
                    pitch: a.from.pitch + (a.to.pitch - a.from.pitch) * e,
                    distance: a.from.distance + (a.to.distance - a.from.distance) * e)
        if t >= 1 { animation = nil }
        return animation != nil
    }
}
