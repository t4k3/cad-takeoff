import Metal
import simd

/// The viewport's shaders compile with the Metal compiler (the app bundles default.metallib),
/// every entry point exists, and the section plane cuts bodies: rendered off screen.
@main
struct ShaderTests {
    struct Frame { var viewProjection: simd_float4x4; var eye: SIMD4<Float>; var lightDir: SIMD4<Float>; var clip: SIMD4<Float> }
    struct MeshVertex { var position: SIMD4<Float>; var normal: SIMD4<Float> }

    static func main() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { print("SKIP: nessun dispositivo Metal"); return }
        guard CommandLine.arguments.count > 1 else { fatalError("USO: shader-tests <default.metallib>") }
        let library = try device.makeLibrary(URL: URL(fileURLWithPath: CommandLine.arguments[1]))
        for name in ["meshVertex", "gizmoVertex", "meshFragment", "lineVertex", "thickLineVertex", "lineFragment", "edgeFragment",
                     "textVertex", "textFragment", "labelBackgroundVertex", "labelBackgroundFragment",
                     "pickVertex", "pickFragment"] {
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

        // The label box: six vertex numbers make both triangles of the quad, so the whole box
        // is painted (not just one half).
        struct LabelBox { var origin: SIMD2<Float>; var size: SIMD2<Float>; var fill: SIMD4<Float>; var border: SIMD4<Float>; var params: SIMD4<Float> }
        func labelBox() throws -> [UInt8] {
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
            let d = MTLRenderPipelineDescriptor()
            d.vertexFunction = library.makeFunction(name: "labelBackgroundVertex")
            d.fragmentFunction = library.makeFunction(name: "labelBackgroundFragment")
            d.colorAttachments[0].pixelFormat = .bgra8Unorm
            enc.setRenderPipelineState(try device.makeRenderPipelineState(descriptor: d))
            var box = LabelBox(origin: SIMD2(0.5, 0.5), size: SIMD2(7, 7), fill: SIMD4(1, 0, 0, 1), border: .zero, params: .zero)
            var viewport = SIMD2<Float>(8, 8)
            enc.setVertexBytes(&box, length: MemoryLayout<LabelBox>.stride, index: 0)
            enc.setVertexBytes(&viewport, length: MemoryLayout<SIMD2<Float>>.stride, index: 3)
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6, instanceCount: 1)
            enc.endEncoding()
            command.commit(); command.waitUntilCompleted()
            var out = [UInt8](repeating: 0, count: size * size * 4)
            target.getBytes(&out, bytesPerRow: size * 4, from: MTLRegionMake2D(0, 0, size, size), mipmapLevel: 0)
            return out
        }
        let label = try labelBox()
        check(pixel(label, 1, 1).r > 60 && pixel(label, 6, 6).r > 60, "il riquadro dell'etichetta è pieno in ogni angolo")

        // GPU picking: one pixel of identity. The app shifts the projection so the click ray is
        // the centre of the 1×1 target; the read-back carries body, triangle and ray parameter.
        struct PickUniforms { var viewProjection: simd_float4x4; var rayOrigin: SIMD4<Float>; var rayDirection: SIMD4<Float> }
        struct PickDraw { var feature: UInt32 }
        func pickPass(shift: SIMD2<Float>) throws -> (ids: SIMD4<UInt32>, distance: Float) {
            func texture(_ format: MTLPixelFormat, _ storage: MTLStorageMode) -> MTLTexture {
                let td = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: 1, height: 1, mipmapped: false)
                td.usage = .renderTarget
                td.storageMode = storage
                return device.makeTexture(descriptor: td)!
            }
            let idsTexture = texture(.rgba32Uint, .shared), distTexture = texture(.r32Float, .shared)
            let depthTexture = texture(.depth32Float, .private)
            let pass = MTLRenderPassDescriptor()
            pass.colorAttachments[0].texture = idsTexture
            pass.colorAttachments[0].loadAction = .clear
            pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
            pass.colorAttachments[0].storeAction = .store
            pass.colorAttachments[1].texture = distTexture
            pass.colorAttachments[1].loadAction = .clear
            pass.colorAttachments[1].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
            pass.colorAttachments[1].storeAction = .store
            pass.depthAttachment.texture = depthTexture
            pass.depthAttachment.loadAction = .clear
            pass.depthAttachment.clearDepth = 1
            pass.depthAttachment.storeAction = .dontCare
            let pd = MTLRenderPipelineDescriptor()
            pd.vertexFunction = library.makeFunction(name: "pickVertex")
            pd.fragmentFunction = library.makeFunction(name: "pickFragment")
            pd.colorAttachments[0].pixelFormat = .rgba32Uint
            pd.colorAttachments[1].pixelFormat = .r32Float
            pd.depthAttachmentPixelFormat = .depth32Float
            let pipeline = try device.makeRenderPipelineState(descriptor: pd)
            let queue = device.makeCommandQueue()!, command = queue.makeCommandBuffer()!
            let enc = command.makeRenderCommandEncoder(descriptor: pass)!
            // Two triangles around NDC (0.5, 0.5), seen from z = 5 towards −z.
            let corners: [SIMD2<Float>] = [SIMD2(0, 0), SIMD2(1, 0), SIMD2(1, 1), SIMD2(0, 0), SIMD2(1, 1), SIMD2(0, 1)]
            let v = corners.map { MeshVertex(position: SIMD4($0.x, $0.y, 0.5, 1), normal: SIMD4(0, 0, 1, 0)) }
            let shiftMatrix = simd_float4x4(columns: (SIMD4(1, 0, 0, 0), SIMD4(0, 1, 0, 0), SIMD4(0, 0, 1, 0),
                                                     SIMD4(-shift.x, -shift.y, 0, 1)))
            var uniforms = PickUniforms(viewProjection: shiftMatrix, rayOrigin: SIMD4(0, 0, 5, 0),
                                        rayDirection: SIMD4(0, 0, -1, 0))
            var draw = PickDraw(feature: 7)
            enc.setRenderPipelineState(pipeline)
            enc.setVertexBytes(v, length: MemoryLayout<MeshVertex>.stride * v.count, index: 0)
            enc.setVertexBytes(&uniforms, length: MemoryLayout<PickUniforms>.stride, index: 1)
            enc.setFragmentBytes(&uniforms, length: MemoryLayout<PickUniforms>.stride, index: 1)
            enc.setFragmentBytes(&draw, length: MemoryLayout<PickDraw>.stride, index: 2)
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: v.count)
            enc.endEncoding()
            command.commit(); command.waitUntilCompleted()
            var ids = SIMD4<UInt32>(repeating: 0), distance: Float = 0
            idsTexture.getBytes(&ids, bytesPerRow: 16, from: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0)
            distTexture.getBytes(&distance, bytesPerRow: 4, from: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0)
            return (ids, distance)
        }
        let hit = try pickPass(shift: SIMD2(0.5, 0.5))
        check(hit.ids.x == 7 && hit.ids.y == 0 && hit.ids.z == 1, "il pass di picking legge corpo e triangolo sotto il pixel")
        check(abs(hit.distance - 4.5) < 1e-4, "il pass di picking legge la distanza lungo il raggio")
        let miss = try pickPass(shift: SIMD2(1.5, 1.5))
        check(miss.ids.z == 0, "senza geometria sotto il raggio il pixel resta vuoto")

        if failures > 0 { fatalError("\(failures) verifiche fallite") }
        print("OK: shader compilati, sezione e picking verificati")
    }
}
