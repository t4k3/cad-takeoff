import CADCore
import Foundation
import simd

/// The mouse ray must land where the renderer draws: for every orientation, including looking
/// from below (Sotto), the ray through a screen point projects back onto that same point, and a
/// pan moves the scene with the mouse.
@main
struct CameraTests {
    @MainActor static func main() {
        var checks = 0
        func expect(_ c: Bool, _ msg: String) { checks += 1; precondition(c, msg) }
        let size = CGSize(width: 800, height: 500)
        let aspect = Float(size.width / size.height)

        func screen(_ cam: CameraController, _ p: SIMD3<Float>) -> CGPoint {
            let clip = cam.projectionMatrix(aspect: aspect) * cam.viewMatrix * SIMD4(p, 1)
            let ndc = SIMD2(clip.x, clip.y) / clip.w
            return CGPoint(x: CGFloat((ndc.x + 1) / 2) * size.width, y: CGFloat((1 - ndc.y) / 2) * size.height)
        }

        for projection in [CameraController.Projection.perspective, .orthographic] {
            for view in CameraController.StandardView.allCases {
                for extraPitch: Float in [0, -0.3, 0.3] {
                    let cam = CameraController()
                    cam.projection = projection
                    let (yaw, pitch) = view.angles
                    cam.setOrientation(yaw: yaw + 0.2, pitch: min(max(pitch + extraPitch, -.pi / 2 + 0.0001), .pi / 2 - 0.0001))
                    while cam.tick() {}
                    cam.orbit(dx: 0, dy: 0)
                    for q in [CGPoint(x: 100, y: 80), CGPoint(x: 650, y: 420), CGPoint(x: 400, y: 250)] {
                        let r = cam.ray(at: q, in: size)
                        let back = screen(cam, r.origin + r.direction * 120)
                        expect(hypot(back.x - q.x, back.y - q.y) < 0.5,
                               "\(projection) \(view) \(extraPitch): ray at \(q) projects to \(back)")
                    }
                    // Pan right by 50 pt: the target point follows the mouse to the right.
                    let before = screen(cam, .zero)
                    cam.pan(dx: 50, dy: 0, viewHeight: Float(size.height))
                    let after = screen(cam, .zero)
                    expect(after.x - before.x > 20, "\(projection) \(view): pan follows the mouse (\(after.x - before.x))")
                }
            }
        }
        // Orbit (Ross 28/09): the part follows the mouse — dragging up turns it upwards (the eye
        // goes down), dragging right turns the part right.
        let cam = CameraController()
        let before = cam.pose
        cam.orbit(dx: 0, dy: -20)
        expect(cam.pose.pitch < before.pitch, "drag up turns the part upwards (eye lower)")
        cam.orbit(dx: 20, dy: 0)
        expect(cam.pose.yaw < before.yaw, "drag right orbits the eye to the left")
        print("PASS: camera rays and pans match the drawn view in all orientations (\(checks) checks)")
    }
}
