import Metal
import simd

/// The viewport's shaders compile (they are built at runtime, so the app build does not check
/// them), every entry point exists, and the section plane cuts bodies: rendered off screen.
@main
struct ShaderTests {
    struct Frame { var viewProjection: simd_float4x4; var eye: SIMD4<Float>; var lightDir: SIMD4<Float>; var clip: SIMD4<Float> }
    struct MeshVertex { var position: SIMD4<Float>; var normal: SIMD4<Float> }

    static func main() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { print("SKIP: nessun dispositivo Metal"); return }
        let library = try device.makeLibrary(source: ShaderSource.code, options: nil)
        for name in ["meshVertex", "gizmoVertex", "meshFragment", "lineVertex", "thickLineVertex", "lineFragment", "edgeFragment"] {
            guard library.makeFunction(name: name) != nil else { fatalError("manca la funzione \(name)") }
        }
        let d = MTLRenderPipelineDescriptor()
        d.vertexFunction = library.makeFunction(name: "meshVertex")
        d.fragmentFunction = library.makeFunction(name: "meshFragment")
        d.colorAttachments[0].pixelFormat = .bgra8Unorm
        let pipeline = try device.makeRenderPipelineState(descriptor: d)

        /// Renders a square filling the view (normal towards the eye, or away) and returns the
        /// 8×8 pixels (BGRA).
        func render(clip: SIMD4<Float>, facing: Float) -> [UInt8] {
            let size = 8
            let td = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: size, height: size, mipmapped: false)
            td.usage = [.renderTarget]
            td.storageMode = .shared
            let target = device.makeTexture(descriptor: td)!
            let pass = MTLRenderPassDescriptor()
            pass.colorAttachments[0].texture = target
            pass.colorAttachments[0].loadAction = .clear
            pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
            pass.colorAttachments[0].storeAction = .store
            let queue = device.makeCommandQueue()!, command = queue.makeCommandBuffer()!
            let enc = command.makeRenderCommandEncoder(descriptor: pass)!
            var frame = Frame(viewProjection: matrix_identity_float4x4, eye: SIMD4(0, 0, -5, 100), lightDir: SIMD4(0, 0, -1, 0), clip: clip)
            let n = SIMD4<Float>(0, 0, -facing, 0)
            let corners: [SIMD2<Float>] = [SIMD2(-1, -1), SIMD2(1, -1), SIMD2(1, 1), SIMD2(-1, -1), SIMD2(1, 1), SIMD2(-1, 1)]
            let v = corners.map { MeshVertex(position: SIMD4($0.x, $0.y, 0.5, 1), normal: n) }
            var draw = SIMD4<Float>(0.5, 0.5, 0.5, 0)
            enc.setRenderPipelineState(pipeline)
            enc.setVertexBytes(v, length: MemoryLayout<MeshVertex>.stride * v.count, index: 0)
            enc.setVertexBytes(&frame, length: MemoryLayout<Frame>.stride, index: 1)
            enc.setFragmentBytes(&frame, length: MemoryLayout<Frame>.stride, index: 1)
            enc.setFragmentBytes(&draw, length: MemoryLayout<SIMD4<Float>>.stride, index: 2)
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: v.count)
            enc.endEncoding()
            command.commit(); command.waitUntilCompleted()
            var out = [UInt8](repeating: 0, count: size * size * 4)
            target.getBytes(&out, bytesPerRow: size * 4, from: MTLRegionMake2D(0, 0, size, size), mipmapLevel: 0)
            return out
        }
        func pixel(_ p: [UInt8], _ x: Int, _ y: Int) -> (b: UInt8, g: UInt8, r: UInt8) { let i = (y * 8 + x) * 4; return (p[i], p[i + 1], p[i + 2]) }
        var failures = 0
        func check(_ ok: Bool, _ what: String) { if !ok { failures += 1; print("FALLITO: \(what)") } }

        let whole = render(clip: .zero, facing: 1)
        check(pixel(whole, 1, 4).r > 40 && pixel(whole, 6, 4).r > 40, "senza sezione il quadrato è pieno")
        // Cut away x > 0: the right half is background.
        let cut = render(clip: SIMD4(1, 0, 0, 0), facing: 1)
        check(pixel(cut, 1, 4).r > 40, "a sinistra del piano resta il pezzo")
        check(pixel(cut, 6, 4) == (0, 0, 0), "a destra del piano il pezzo è tagliato via")
        // The inside seen through the cut: the flat section colour (warm), not the body grey.
        let inside = render(clip: SIMD4(1, 0, 0, 0), facing: -1)
        let p = pixel(inside, 1, 4)
        check(p.r > p.b + 30, "l'interno visto dalla sezione ha il colore del taglio")
        if failures > 0 { fatalError("\(failures) verifiche fallite") }
        print("OK: shader compilati, sezione verificata")
    }
}
