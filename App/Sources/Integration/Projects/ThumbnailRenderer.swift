import AppKit
import CADCore
import simd

/// Small isometric, flat-shaded preview of a design (painter's algorithm in Core Graphics),
/// saved next to the design for the Home dashboard. No GPU, works off-screen.
enum ThumbnailRenderer {
    static func png(for document: CADDocument, size: CGSize = CGSize(width: 360, height: 270)) -> Data? {
        let parts = document.features.filter(\.isVisible).map { ($0.buildMesh(), $0.color) }
        guard parts.contains(where: { !$0.0.isEmpty }) else { return nil }

        // Home-like view direction (from front-right, above), Z up.
        let yaw = -Double.pi / 4 - 0.35, pitch = 0.55
        let toEye = SIMD3(cos(pitch) * cos(yaw), cos(pitch) * sin(yaw), sin(pitch))
        let right = simd_normalize(simd_cross(SIMD3<Double>(0, 0, 1), toEye))
        let up = simd_cross(toEye, right)
        let light = simd_normalize(toEye + right * 0.4 + SIMD3(0, 0, 0.6))

        struct Tri { var p: [CGPoint]; var depth: Double; var color: CGColor }
        var tris: [Tri] = []
        var minX = Double.infinity, maxX = -Double.infinity, minY = Double.infinity, maxY = -Double.infinity
        for (mesh, color) in parts {
            for t in 0..<mesh.triangleCount {
                let (a, b, c) = mesh.triangle(t)
                let n = mesh.normal(ofTriangle: t)
                let nn = SIMD3(n.x, n.y, n.z)
                guard simd_dot(nn, toEye) > 0 else { continue } // back face
                let pts = [a, b, c].map { v -> CGPoint in
                    let w = SIMD3(v.x, v.y, v.z)
                    let x = simd_dot(w, right), y = simd_dot(w, up)
                    minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
                    return CGPoint(x: x, y: y)
                }
                let centroid = (SIMD3(a.x, a.y, a.z) + SIMD3(b.x, b.y, b.z) + SIMD3(c.x, c.y, c.z)) / 3
                let shade = 0.45 + 0.55 * max(0, simd_dot(nn, light))
                let cg = CGColor(srgbRed: Double(color.red) / 255 * shade, green: Double(color.green) / 255 * shade,
                                 blue: Double(color.blue) / 255 * shade, alpha: 1)
                tris.append(Tri(p: pts, depth: simd_dot(centroid, toEye), color: cg))
            }
        }
        guard !tris.isEmpty, maxX > minX || maxY > minY else { return nil }

        let scale = min((size.width * 0.84) / max(maxX - minX, 1e-6), (size.height * 0.84) / max(maxY - minY, 1e-6))
        let ox = size.width / 2 - (minX + maxX) / 2 * scale, oy = size.height / 2 - (minY + maxY) / 2 * scale
        guard let ctx = CGContext(data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8,
                                  bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.setLineJoin(.round)
        for t in tris.sorted(by: { $0.depth < $1.depth }) { // far to near
            let path = CGMutablePath()
            path.addLines(between: t.p.map { CGPoint(x: $0.x * scale + ox, y: $0.y * scale + oy) })
            path.closeSubpath()
            ctx.addPath(path); ctx.setFillColor(t.color); ctx.fillPath()
            ctx.addPath(path); ctx.setStrokeColor(t.color); ctx.setLineWidth(1.1); ctx.strokePath() // hide seams between triangles
        }
        guard let image = ctx.makeImage() else { return nil }
        return NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
    }
}
