import SwiftUI
import simd

/// Orientation cube that follows the camera. Click a face to animate to that view.
struct ViewCube: View {
    let camera: CameraController
    var onSelect: (CameraController.StandardView) -> Void
    @State private var hoveredFace: CameraController.StandardView?

    private struct Face {
        let view: CameraController.StandardView
        let label: String
        let normal: SIMD3<Float>
        let corners: [SIMD3<Float>]
    }

    private static let faces: [Face] = {
        func quad(_ n: SIMD3<Float>) -> [SIMD3<Float>] {
            // Two axes perpendicular to n, corners in CCW order seen from outside.
            let u = abs(n.z) > 0.5 ? SIMD3<Float>(1, 0, 0) : SIMD3<Float>(0, 0, 1)
            let v = simd_cross(n, u)
            return [n - u - v, n + u - v, n + u + v, n - u + v]
        }
        return [
            Face(view: .top, label: "SOPRA", normal: SIMD3(0, 0, 1), corners: quad(SIMD3(0, 0, 1))),
            Face(view: .bottom, label: "SOTTO", normal: SIMD3(0, 0, -1), corners: quad(SIMD3(0, 0, -1))),
            Face(view: .front, label: "FRONTE", normal: SIMD3(0, -1, 0), corners: quad(SIMD3(0, -1, 0))),
            Face(view: .back, label: "RETRO", normal: SIMD3(0, 1, 0), corners: quad(SIMD3(0, 1, 0))),
            Face(view: .right, label: "DESTRA", normal: SIMD3(1, 0, 0), corners: quad(SIMD3(1, 0, 0))),
            Face(view: .left, label: "SINISTRA", normal: SIMD3(-1, 0, 0), corners: quad(SIMD3(-1, 0, 0))),
        ]
    }()

    private let size: CGFloat = 96

    var body: some View {
        let r = camera.rotationMatrix
        let visible = Self.faces
            .map { face -> (Face, Path, Float) in
                let pts = face.corners.map { project($0, r) }
                var path = Path()
                path.addLines(pts)
                path.closeSubpath()
                return (face, path, (r * face.normal).z)
            }
            .filter { $0.2 > 0.02 }
            .sorted { $0.2 < $1.2 }   // back to front

        VStack(spacing: 4) {
            Canvas { ctx, _ in
                for (face, path, facing) in visible {
                    let hovered = hoveredFace == face.view
                    let shade = 0.55 + 0.45 * Double(facing)
                    ctx.fill(path, with: .color(hovered ? Theme.Palette.accent.opacity(0.85)
                                                : Color(white: 0.93 * shade).opacity(0.94)))
                    ctx.stroke(path, with: .color(.black.opacity(0.35)), lineWidth: 1)
                    if facing > 0.35 {
                        let c = project(face.normal, r)
                        ctx.draw(Text(face.label)
                                    .font(.system(size: 9 * CGFloat(0.6 + 0.4 * facing), weight: .bold))
                                    .foregroundStyle(hovered ? .white : Color(white: 0.2)),
                                 at: c)
                    }
                }
                drawAxes(ctx, r)
            }
            .frame(width: size, height: size)
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                if case let .active(p) = phase {
                    hoveredFace = visible.reversed().first { $0.1.contains(p) }?.0.view
                } else { hoveredFace = nil }
            }
            .onTapGesture { p in
                if let face = visible.reversed().first(where: { $0.1.contains(p) })?.0 { onSelect(face.view) }
            }
            .help("Clicca una faccia per orientare la vista")

            Button { onSelect(.home) } label: { Label("Home", systemImage: "house.fill") }
                .buttonStyle(IconButtonStyle())
                .help("Vista iniziale")
        }
        .padding(6)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("ViewCube")
    }

    private func project(_ p: SIMD3<Float>, _ r: simd_float3x3) -> CGPoint {
        let v = r * p
        let scale = size * 0.3
        return CGPoint(x: size / 2 + CGFloat(v.x) * scale, y: size / 2 - CGFloat(v.y) * scale)
    }

    /// Small XYZ triad at the cube's back-left-bottom corner.
    private func drawAxes(_ ctx: GraphicsContext, _ r: simd_float3x3) {
        let origin = SIMD3<Float>(-1.25, -1.25, -1.25)
        for (axis, color) in [(SIMD3<Float>(1, 0, 0), Color.red), (SIMD3<Float>(0, 1, 0), Color.green), (SIMD3<Float>(0, 0, 1), Color.blue)] {
            var p = Path()
            p.move(to: project(origin, r))
            p.addLine(to: project(origin + axis * 0.9, r))
            ctx.stroke(p, with: .color(color.opacity(0.9)), lineWidth: 2)
        }
    }
}
